import crypto from "node:crypto";
import mysql from "mysql2/promise";
import { classifyHsv } from "./hsv.js";
import { migrate } from "./migrate.js";
import { mysqlToIso, toMysqlTimestamp } from "./time.js";

const leaseSeconds = Number.parseInt(process.env.WORKER_LEASE_SECONDS ?? "30", 10);
const pollMs = Number.parseInt(process.env.WORKER_POLL_MS ?? "1000", 10);
const processingDelayMs = Number.parseInt(
  process.env.WORKER_PROCESSING_DELAY_MS ?? "0",
  10,
);
const workerId = `${process.env.HOSTNAME ?? "worker"}-${crypto.randomUUID()}`;
const rawRoot = process.env.RAW_DATA_DIR ?? "/app/uploads";
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

async function claimJob() {
  const connection = await pool.getConnection();
  try {
    await connection.beginTransaction();
    await connection.query(
      `UPDATE jobs j
         JOIN monitoring_events e
           ON e.source_id = j.source_id AND e.event_id = j.event_id
          SET j.state = 'failed', j.lease_owner = NULL,
              j.lease_expires_at = NULL, j.updated_at = UTC_TIMESTAMP(3),
              j.last_error = 'lease expired after maximum attempts',
              e.status = 'failed'
        WHERE j.state = 'leased' AND j.attempts >= 3
          AND j.lease_expires_at < UTC_TIMESTAMP(3)`,
    );
    const [rows] = await connection.query(
      `SELECT j.source_id, j.event_id, j.attempts, r.storage_path
         FROM jobs j
         JOIN raw_files r ON r.source_id = j.source_id AND r.event_id = j.event_id
        WHERE (j.state = 'queued' AND j.attempts < 3 AND j.available_at <= UTC_TIMESTAMP(3))
           OR (j.state = 'leased' AND j.attempts < 3 AND j.lease_expires_at < UTC_TIMESTAMP(3))
        ORDER BY j.available_at, j.created_at
        LIMIT 1
        FOR UPDATE SKIP LOCKED`,
    );
    if (rows.length === 0) {
      await connection.rollback();
      return null;
    }

    const job = rows[0];
    await connection.query(
      `UPDATE analysis_runs
          SET status = 'failed', completed_at = UTC_TIMESTAMP(3),
              error_message = 'lease expired before completion'
        WHERE source_id = ? AND event_id = ? AND status = 'running'`,
      [job.source_id, job.event_id],
    );
    const attempts = Number(job.attempts) + 1;
    await connection.query(
      `UPDATE jobs
          SET state = 'leased', attempts = ?, lease_owner = ?,
              lease_expires_at = DATE_ADD(UTC_TIMESTAMP(3), INTERVAL ? SECOND),
              updated_at = UTC_TIMESTAMP(3), last_error = NULL
        WHERE source_id = ? AND event_id = ?`,
      [attempts, workerId, leaseSeconds, job.source_id, job.event_id],
    );
    await connection.query(
      `UPDATE monitoring_events SET status = 'processing'
        WHERE source_id = ? AND event_id = ?`,
      [job.source_id, job.event_id],
    );
    await connection.commit();
    return { ...job, attempts, leaseOwner: workerId };
  } catch (error) {
    await connection.rollback();
    throw error;
  } finally {
    connection.release();
  }
}

async function heartbeat(job) {
  await pool.query(
    `UPDATE jobs
        SET lease_expires_at = DATE_ADD(UTC_TIMESTAMP(3), INTERVAL ? SECOND),
            updated_at = UTC_TIMESTAMP(3)
      WHERE source_id = ? AND event_id = ? AND state = 'leased' AND lease_owner = ?`,
    [leaseSeconds, job.source_id, job.event_id, job.leaseOwner],
  );
}

async function completeJob(job, result, startedAt) {
  const connection = await pool.getConnection();
  try {
    await connection.beginTransaction();
    const completedAt = new Date();
    const [update] = await connection.query(
      `UPDATE jobs SET state = 'done', lease_owner = NULL, lease_expires_at = NULL,
              updated_at = ?, last_error = NULL
        WHERE source_id = ? AND event_id = ? AND state = 'leased' AND lease_owner = ?`,
      [toMysqlTimestamp(completedAt), job.source_id, job.event_id, job.leaseOwner],
    );
    if (update.affectedRows !== 1) {
      await connection.rollback();
      return;
    }
    const [run] = await connection.query(
      `INSERT INTO analysis_runs
        (source_id, event_id, algorithm, algorithm_version, started_at,
         completed_at, status, result)
       VALUES (?, ?, 'hsv', '1', ?, ?, 'completed', ?)`,
      [
        job.source_id,
        job.event_id,
        toMysqlTimestamp(startedAt),
        toMysqlTimestamp(completedAt),
        JSON.stringify(result),
      ],
    );
    await connection.query(
      `UPDATE monitoring_events
          SET status = 'completed', processed_at = ?, derived_data = ?,
              current_result_run_id = ?
        WHERE source_id = ? AND event_id = ?`,
      [
        toMysqlTimestamp(completedAt),
        JSON.stringify(result),
        run.insertId,
        job.source_id,
        job.event_id,
      ],
    );
    await connection.commit();
    console.log(JSON.stringify({
      event: "job_completed",
      source_id: job.source_id,
      event_id: job.event_id,
      processed_at: mysqlToIso(toMysqlTimestamp(completedAt)),
    }));
  } catch (error) {
    await connection.rollback();
    throw error;
  } finally {
    connection.release();
  }
}

async function failJob(job, error) {
  const connection = await pool.getConnection();
  try {
    await connection.beginTransaction();
    const permanent = error.permanent === true;
    const exhausted = job.attempts >= 3;
    const failed = permanent || exhausted;
    const delayMinutes = job.attempts === 1 ? 1 : 5;
    const [update] = await connection.query(
      `UPDATE jobs
          SET state = ?, available_at = DATE_ADD(UTC_TIMESTAMP(3), INTERVAL ? MINUTE),
              lease_owner = NULL, lease_expires_at = NULL, last_error = ?,
              updated_at = UTC_TIMESTAMP(3)
        WHERE source_id = ? AND event_id = ? AND state = 'leased' AND lease_owner = ?`,
      [
        failed ? "failed" : "queued",
        failed ? 0 : delayMinutes,
        error.message.slice(0, 255),
        job.source_id,
        job.event_id,
        job.leaseOwner,
      ],
    );
    if (update.affectedRows !== 1) {
      await connection.rollback();
      return;
    }
    await connection.query(
      `INSERT INTO analysis_runs
        (source_id, event_id, algorithm, algorithm_version, started_at,
         completed_at, status, error_message)
       VALUES (?, ?, 'hsv', '1', ?, UTC_TIMESTAMP(3), 'failed', ?)`,
      [
        job.source_id,
        job.event_id,
        toMysqlTimestamp(new Date()),
        error.message.slice(0, 255),
      ],
    );
    if (failed) {
      await connection.query(
        `UPDATE monitoring_events SET status = 'failed'
          WHERE source_id = ? AND event_id = ?`,
        [job.source_id, job.event_id],
      );
    }
    await connection.commit();
  } catch (transactionError) {
    await connection.rollback();
    throw transactionError;
  } finally {
    connection.release();
  }
}

async function processJob(job) {
  const startedAt = new Date();
  const heartbeatTimer = setInterval(() => {
    heartbeat(job).catch((error) => console.error(JSON.stringify({
      event: "job_heartbeat_failed",
      error: error.message,
    })));
  }, Math.max(1000, Math.floor((leaseSeconds * 1000) / 3)));
  try {
    if (processingDelayMs > 0) await sleep(processingDelayMs);
    const result = await classifyHsv(`${rawRoot}/${job.storage_path}`);
    await completeJob(job, result, startedAt);
  } catch (error) {
    await failJob(job, error);
    console.error(JSON.stringify({
      event: "job_failed",
      source_id: job.source_id,
      event_id: job.event_id,
      attempts: job.attempts,
      error: error.message,
    }));
  } finally {
    clearInterval(heartbeatTimer);
  }
}

async function run() {
  await migrate();
  console.log(JSON.stringify({ event: "worker_started", worker_id: workerId }));
  while (true) {
    const job = await claimJob();
    if (job) await processJob(job);
    else await sleep(pollMs);
  }
}

run().catch(async (error) => {
  console.error(JSON.stringify({ event: "worker_stopped", error: error.message }));
  await pool.end();
  process.exit(1);
});
