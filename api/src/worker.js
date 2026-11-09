import crypto from "node:crypto";
import fs from "node:fs/promises";
import mysql from "mysql2/promise";
import { classifyHsv } from "./hsv.js";
import { applyObservation } from "./aggregation.js";
import { buildAlertCandidate } from "./alerts.js";
import { migrate } from "./migrate.js";
import { mysqlToIso, toMysqlTimestamp } from "./time.js";

const leaseSeconds = Number.parseInt(process.env.WORKER_LEASE_SECONDS ?? "30", 10);
const pollMs = Number.parseInt(process.env.WORKER_POLL_MS ?? "1000", 10);
const processingDelayMs = Number.parseInt(
  process.env.WORKER_PROCESSING_DELAY_MS ?? "0",
  10,
);
const inferenceUrl = process.env.INFERENCE_URL ?? "http://inference:8000";
const inferenceModelVersion = process.env.INFERENCE_MODEL_VERSION;
const inferenceModelSha256 = process.env.INFERENCE_MODEL_SHA256;
const officialAlgorithm = process.env.OFFICIAL_ALGORITHM;
const aggregationConfig = {
  ruleVersion: process.env.AGGREGATION_RULE_VERSION ?? "1",
  confidenceThreshold: Number.parseFloat(
    process.env.AGGREGATION_CONFIDENCE_THRESHOLD ?? "0.8",
  ),
  consecutiveEvents: Number.parseInt(
    process.env.AGGREGATION_CONSECUTIVE_EVENTS ?? "3",
    10,
  ),
  maximumAgeMs: Number.parseInt(
    process.env.AGGREGATION_MAX_EVENT_AGE_MS ?? `${7 * 24 * 60 * 60 * 1000}`,
    10,
  ),
  minimumAlertIntervalMs: Number.parseInt(
    process.env.AGGREGATION_MIN_ALERT_INTERVAL_MS ?? "0",
    10,
  ),
};
if (!["hsv", "cnn"].includes(officialAlgorithm)) {
  throw new Error("OFFICIAL_ALGORITHM must be hsv or cnn");
}
const workerId = `${process.env.HOSTNAME ?? "worker"}-${crypto.randomUUID()}`;
const rawRoot = process.env.RAW_DATA_DIR ?? "/app/uploads";
const maintenanceMarker = `${rawRoot}/.maintenance`;
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
  try {
    await fs.access(maintenanceMarker);
    return null;
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
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
      `      SELECT j.source_id, j.event_id, j.attempts, j.reprocessing, r.storage_path
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

async function classifyCnn(job) {
  const image = await fs.readFile(`${rawRoot}/${job.storage_path}`);
  const inputSha256 = crypto.createHash("sha256").update(image).digest("hex");
  const response = await fetch(`${inferenceUrl}/v1/classify`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      event_id: job.event_id,
      raw_sha256: inputSha256,
      image_base64: image.toString("base64"),
    }),
  });
  const result = await response.json();
  if (!response.ok) {
    throw Object.assign(new Error(result.error ?? "inference_failed"), {
      permanent: response.status < 500,
    });
  }
  if (
    result.algorithm !== "cnn" ||
    result.model_version !== inferenceModelVersion ||
    result.model_sha256 !== inferenceModelSha256 ||
    result.input_sha256 !== inputSha256
  ) {
    throw Object.assign(new Error("inference_contract_mismatch"), {
      permanent: true,
    });
  }
  return result;
}

async function completeJob(job, results, startedAt) {
  const connection = await pool.getConnection();
  try {
    await connection.beginTransaction();
    const completedAt = new Date();
    const [update] = await connection.query(
      `UPDATE jobs SET state = 'done', reprocessing = FALSE,
              lease_owner = NULL, lease_expires_at = NULL,
              updated_at = ?, last_error = NULL
        WHERE source_id = ? AND event_id = ? AND state = 'leased' AND lease_owner = ?`,
      [toMysqlTimestamp(completedAt), job.source_id, job.event_id, job.leaseOwner],
    );
    if (update.affectedRows !== 1) {
      await connection.rollback();
      return;
    }
    const runIds = {};
    for (const result of results) {
      const [run] = await connection.query(
      `INSERT INTO analysis_runs
        (source_id, event_id, algorithm, algorithm_version, started_at,
         completed_at, status, model_version, model_sha256, result)
       VALUES (?, ?, ?, ?, ?, ?, 'completed', ?, ?, ?)`,
        [
          job.source_id,
          job.event_id,
          result.algorithm,
          result.algorithm_version,
          toMysqlTimestamp(startedAt),
          toMysqlTimestamp(completedAt),
          result.model_version ?? null,
          result.model_sha256 ?? null,
          JSON.stringify(result),
        ],
      );
      runIds[result.algorithm] = run.insertId;
    }
    const officialResult = results.find(
      (result) => result.algorithm === officialAlgorithm,
    );
    if (!officialResult) {
      throw Object.assign(new Error("official_algorithm_unavailable"), {
        permanent: true,
      });
    }
    await connection.query(
      `UPDATE monitoring_events
          SET status = 'completed', processed_at = ?, derived_data = ?,
              current_result_run_id = ?
        WHERE source_id = ? AND event_id = ?`,
      [
        toMysqlTimestamp(completedAt),
        JSON.stringify(officialResult),
        runIds[officialAlgorithm],
        job.source_id,
        job.event_id,
      ],
    );
    await updateAggregatedState(connection, job, officialResult);
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

  async function updateAggregatedState(connection, job, officialResult) {
    const [eventRows] = await connection.query(
      `SELECT e.occurred_at, e.clock_suspect, e.crop, s.is_test,
              a.chat_id
         FROM monitoring_events e
         JOIN monitoring_sources s ON s.source_id = e.source_id
         LEFT JOIN monitoring_source_alerts a
           ON a.source_id = e.source_id AND a.crop = e.crop
        WHERE e.source_id = ? AND e.event_id = ?
        FOR UPDATE`,
      [job.source_id, job.event_id],
    );
    const event = eventRows[0];
    if (!event) throw new Error("event_missing_for_aggregation");
    const [stateRows] = await connection.query(
      `SELECT current_stage, episode_seq, consecutive_stage, consecutive_count,
              last_occurred_at, last_confidence, aggregation_rule_version,
              aggregation_config, last_alert_at
         FROM monitoring_states
        WHERE source_id = ? AND crop = ?
        FOR UPDATE`,
      [job.source_id, event.crop],
    );
    const state = stateRows[0]
      ? {
          currentStage: stateRows[0].current_stage,
          episodeSeq: Number(stateRows[0].episode_seq),
          consecutiveStage: stateRows[0].consecutive_stage,
          consecutiveCount: Number(stateRows[0].consecutive_count),
          lastOccurredAt: stateRows[0].last_occurred_at
            ? mysqlToIso(stateRows[0].last_occurred_at)
            : null,
          lastConfidence: stateRows[0].last_confidence == null
            ? null
            : Number(stateRows[0].last_confidence),
          aggregationRuleVersion: stateRows[0].aggregation_rule_version,
          aggregationConfig: typeof stateRows[0].aggregation_config === "string"
            ? JSON.parse(stateRows[0].aggregation_config)
            : stateRows[0].aggregation_config,
          lastAlertAt: stateRows[0].last_alert_at
            ? mysqlToIso(stateRows[0].last_alert_at)
            : null,
        }
      : {};
    const result = applyObservation(
      state,
      {
        classification: officialResult.classification,
        confidence: officialResult.confidence,
        occurredAt: mysqlToIso(event.occurred_at),
        clockSuspect: Boolean(event.clock_suspect),
        isTest: Boolean(event.is_test),
        official: true,
        reprocessing: Boolean(job.reprocessing),
      },
      aggregationConfig,
    );
    if (!result.accepted) return;
    const historyEntry = result.state.historyEntry;
    await connection.query(
      `INSERT INTO monitoring_state_history
        (source_id, crop, event_id, occurred_at, classification, confidence,
         consecutive_stage, consecutive_count, current_stage, episode_seq,
         transition, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, UTC_TIMESTAMP(3))`,
      [
        job.source_id,
        event.crop,
        job.event_id,
        toMysqlTimestamp(new Date(historyEntry.occurredAt)),
        historyEntry.classification,
        historyEntry.confidence,
        historyEntry.consecutiveStage,
        historyEntry.consecutiveCount,
        historyEntry.currentStage,
        historyEntry.episodeSeq,
        historyEntry.transition ? JSON.stringify(historyEntry.transition) : null,
      ],
    );
    const configurationJson = JSON.stringify(aggregationConfig);
    const [ruleRows] = await connection.query(
      `SELECT configuration
         FROM aggregation_rule_versions
        WHERE rule_version = ?
        FOR UPDATE`,
      [aggregationConfig.ruleVersion],
    );
    if (ruleRows.length > 0) {
      const storedConfiguration = typeof ruleRows[0].configuration === "string"
        ? JSON.parse(ruleRows[0].configuration)
        : ruleRows[0].configuration;
      if (JSON.stringify(storedConfiguration) !== configurationJson) {
        throw new Error("aggregation_rule_version_mismatch");
      }
    } else {
      await connection.query(
        `INSERT INTO aggregation_rule_versions
          (rule_version, configuration, created_at)
         VALUES (?, ?, UTC_TIMESTAMP(3))`,
        [aggregationConfig.ruleVersion, configurationJson],
      );
    }
    await connection.query(
      `INSERT INTO monitoring_states
        (source_id, crop, current_stage, episode_seq, consecutive_stage,
         consecutive_count, last_occurred_at, last_confidence,
         aggregation_rule_version, aggregation_config, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, UTC_TIMESTAMP(3))
       ON DUPLICATE KEY UPDATE
         current_stage = VALUES(current_stage),
         episode_seq = VALUES(episode_seq),
         consecutive_stage = VALUES(consecutive_stage),
         consecutive_count = VALUES(consecutive_count),
         last_occurred_at = VALUES(last_occurred_at),
         last_confidence = VALUES(last_confidence),
         aggregation_rule_version = VALUES(aggregation_rule_version),
         aggregation_config = VALUES(aggregation_config),
         updated_at = VALUES(updated_at)`,
      [
        job.source_id,
        event.crop,
        result.state.currentStage ?? null,
        result.state.episodeSeq ?? 0,
        result.state.consecutiveStage ?? null,
        result.state.consecutiveCount ?? 0,
        result.state.lastOccurredAt
          ? toMysqlTimestamp(new Date(result.state.lastOccurredAt))
          : null,
        result.state.lastConfidence ?? null,
        aggregationConfig.ruleVersion,
        JSON.stringify(aggregationConfig),
      ],
    );
    const alert = buildAlertCandidate({
      sourceId: job.source_id,
      crop: event.crop,
      eventId: job.event_id,
      occurredAt: historyEntry.occurredAt,
      transition: historyEntry.transition,
      chatId: event.chat_id ?? null,
      isTest: Boolean(event.is_test),
    });
    if (alert) {
      const [alertInsert] = await connection.query(
        `INSERT IGNORE INTO monitoring_alerts
          (source_id, crop, event_id, from_stage, to_stage, episode_seq,
           chat_id, status, attempts, available_at, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', 0, UTC_TIMESTAMP(3),
                 UTC_TIMESTAMP(3))`,
        [
          alert.sourceId,
          alert.crop,
          alert.eventId,
          alert.fromStage,
          alert.toStage,
          alert.episodeSeq,
          alert.chatId,
        ],
      );
      if (alertInsert.affectedRows === 1) {
        await connection.query(
          `UPDATE monitoring_states
              SET last_alert_at = UTC_TIMESTAMP(3)
            WHERE source_id = ? AND crop = ?`,
          [job.source_id, event.crop],
        );
      }
    }
  }
}

async function failJob(job, error, algorithm) {
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
         completed_at, status, model_version, model_sha256, error_message)
       VALUES (?, ?, ?, ?, ?, UTC_TIMESTAMP(3), 'failed', ?, ?, ?)`,
      [
        job.source_id,
        job.event_id,
        algorithm,
        algorithm === "cnn" ? "contract-1" : "1",
        toMysqlTimestamp(new Date()),
        algorithm === "cnn" ? inferenceModelVersion : null,
        algorithm === "cnn" ? inferenceModelSha256 : null,
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
  let algorithm = "hsv";
  const heartbeatTimer = setInterval(() => {
    heartbeat(job).catch((error) => console.error(JSON.stringify({
      event: "job_heartbeat_failed",
      error: error.message,
    })));
  }, Math.max(1000, Math.floor((leaseSeconds * 1000) / 3)));
  try {
    if (processingDelayMs > 0) await sleep(processingDelayMs);
    const hsv = await classifyHsv(`${rawRoot}/${job.storage_path}`);
    algorithm = "cnn";
    const cnn = await classifyCnn(job);
    await completeJob(job, [hsv, cnn], startedAt);
  } catch (error) {
    await failJob(job, error, algorithm);
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
