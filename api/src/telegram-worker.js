import crypto from "node:crypto";
import fs from "node:fs/promises";
import mysql from "mysql2/promise";
import { migrate } from "./migrate.js";
import { buildTelegramMessage, classifyTelegramResponse } from "./telegram.js";

const pollMs = Number.parseInt(process.env.ALERT_POLL_MS ?? "1000", 10);
const leaseSeconds = Number.parseInt(process.env.ALERT_LEASE_SECONDS ?? "30", 10);
const maxAttempts = 3;
const panelUrl = process.env.PANEL_URL ?? "https://chromat.lan/panel/";
const tokenFile = process.env.TELEGRAM_BOT_TOKEN_FILE;
const workerId = `${process.env.HOSTNAME ?? "telegram-worker"}-${crypto.randomUUID()}`;

if (!tokenFile) throw new Error("TELEGRAM_BOT_TOKEN_FILE is required");

await migrate();
const token = (await fs.readFile(tokenFile, "utf8")).trim();
if (!token) throw new Error("telegram_bot_token_empty");

const pool = mysql.createPool({
  host: process.env.DB_HOST ?? "db",
  port: Number.parseInt(process.env.DB_PORT ?? "3306", 10),
  database: process.env.DB_NAME ?? "chromat",
  user: process.env.DB_USER ?? "chromat_user",
  password: process.env.DB_PASSWORD,
  connectionLimit: 2,
  dateStrings: true,
});

const sleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

async function claimAlert() {
  const connection = await pool.getConnection();
  try {
    await connection.beginTransaction();
    await connection.query(
      `UPDATE monitoring_alerts
          SET status = 'failed', lease_owner = NULL, lease_expires_at = NULL,
              last_error = 'maximum attempts exceeded'
        WHERE status = 'pending' AND attempts >= ?
          AND (lease_expires_at IS NULL OR lease_expires_at < UTC_TIMESTAMP(3))`,
      [maxAttempts],
    );
    const [rows] = await connection.query(
      `SELECT a.alert_id, a.attempts, a.chat_id, a.event_id, a.source_id,
              a.crop, a.from_stage, a.to_stage, a.episode_seq,
              e.occurred_at, s.name AS source_name
         FROM monitoring_alerts a
         JOIN monitoring_events e
           ON e.source_id = a.source_id AND e.event_id = a.event_id
         JOIN monitoring_sources s ON s.source_id = a.source_id
        WHERE a.status = 'pending'
          AND a.available_at <= UTC_TIMESTAMP(3)
          AND (a.lease_expires_at IS NULL OR a.lease_expires_at < UTC_TIMESTAMP(3))
        ORDER BY a.available_at, a.created_at
        LIMIT 1
        FOR UPDATE SKIP LOCKED`,
    );
    if (rows.length === 0) {
      await connection.rollback();
      return null;
    }
    const alert = rows[0];
    await connection.query(
      `UPDATE monitoring_alerts
          SET attempts = attempts + 1, lease_owner = ?,
              lease_expires_at = DATE_ADD(UTC_TIMESTAMP(3), INTERVAL ? SECOND)
        WHERE alert_id = ?`,
      [workerId, leaseSeconds, alert.alert_id],
    );
    await connection.commit();
    return { ...alert, attempts: Number(alert.attempts) + 1 };
  } catch (error) {
    await connection.rollback();
    throw error;
  } finally {
    connection.release();
  }
}

async function deliver(alert) {
  if (!alert.chat_id) {
    return { kind: "permanent", error: "telegram_chat_id_missing" };
  }
  const response = await fetch(
    `https://api.telegram.org/bot${token}/sendMessage`,
    {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        chat_id: alert.chat_id,
        text: buildTelegramMessage({
          sourceName: alert.source_name,
          crop: alert.crop,
          eventId: alert.event_id,
          fromStage: alert.from_stage,
          toStage: alert.to_stage,
          occurredAt: `${alert.occurred_at.replace(" ", "T")}Z`,
          panelUrl,
        }),
      }),
    },
  );
  let body;
  try {
    body = await response.json();
  } catch {
    body = {};
  }
  return classifyTelegramResponse(response.status, body);
}

async function finalize(alert, result) {
  const connection = await pool.getConnection();
  try {
    const retry = result.kind === "retry" && alert.attempts < maxAttempts;
    const delay = retry ? result.retryAfterSeconds : 0;
    await connection.query(
      `UPDATE monitoring_alerts
          SET status = ?, available_at = DATE_ADD(UTC_TIMESTAMP(3), INTERVAL ? SECOND),
              lease_owner = NULL, lease_expires_at = NULL, last_error = ?,
              sent_at = IF(? = 'sent', UTC_TIMESTAMP(3), sent_at)
        WHERE alert_id = ? AND status = 'pending' AND lease_owner = ?`,
      [
        result.kind === "sent" ? "sent" : retry ? "pending" : "failed",
        delay,
        result.kind === "sent" ? null : result.error,
        result.kind === "sent" ? "sent" : null,
        alert.alert_id,
        workerId,
      ],
    );
  } finally {
    connection.release();
  }
}

while (true) {
  const alert = await claimAlert();
  if (!alert) {
    await sleep(pollMs);
    continue;
  }
  try {
    const result = await deliver(alert);
    await finalize(alert, result);
    console.log(JSON.stringify({
      event: "telegram_alert_delivery",
      alert_id: Number(alert.alert_id),
      status: result.kind,
      attempts: alert.attempts,
    }));
  } catch (error) {
    const result = {
      kind: "retry",
      retryAfterSeconds: 60,
      error: error.message.slice(0, 255),
    };
    await finalize(alert, result);
    console.error(JSON.stringify({
      event: "telegram_alert_delivery_error",
      alert_id: Number(alert.alert_id),
      error: result.error,
    }));
  }
}
