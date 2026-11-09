import fs from "node:fs/promises";
import path from "node:path";
import mysql from "mysql2/promise";
import { databaseConfig } from "./database.js";
import { migrate } from "./migrate.js";

const rawRoot = process.env.RAW_DATA_DIR ?? "/app/uploads";
const rawRetentionDays = Number.parseInt(process.env.RAW_RETENTION_DAYS ?? "90", 10);
const derivedRetentionDays = Number.parseInt(
  process.env.DERIVED_RETENTION_DAYS ?? "365",
  10,
);

if (!Number.isInteger(rawRetentionDays) || rawRetentionDays < 1) {
  throw new Error("RAW_RETENTION_DAYS must be a positive integer");
}
if (!Number.isInteger(derivedRetentionDays) || derivedRetentionDays < 1) {
  throw new Error("DERIVED_RETENTION_DAYS must be a positive integer");
}

await migrate();
const pool = mysql.createPool(databaseConfig(2));

function rawPath(storagePath) {
  const resolvedRoot = path.resolve(rawRoot);
  const resolvedPath = path.resolve(resolvedRoot, storagePath);
  if (!resolvedPath.startsWith(`${resolvedRoot}${path.sep}`)) {
    throw new Error("invalid_storage_path");
  }
  return resolvedPath;
}

async function deleteRawFiles() {
  const [rows] = await pool.query(
    `SELECT e.source_id, e.event_id, r.storage_path
       FROM monitoring_events e
       JOIN raw_files r
         ON r.source_id = e.source_id AND r.event_id = e.event_id
      WHERE e.retention_hold = FALSE
        AND e.raw_deleted_at IS NULL
        AND e.received_at < DATE_SUB(UTC_TIMESTAMP(3), INTERVAL ? DAY)`,
    [rawRetentionDays],
  );
  let deleted = 0;
  for (const row of rows) {
    await fs.rm(rawPath(row.storage_path), { force: true });
    await pool.query(
      `UPDATE monitoring_events
          SET raw_deleted_at = UTC_TIMESTAMP(3)
        WHERE source_id = ? AND event_id = ? AND raw_deleted_at IS NULL`,
      [row.source_id, row.event_id],
    );
    await pool.query(
      `UPDATE raw_files
          SET storage_path = NULL
        WHERE source_id = ? AND event_id = ?`,
      [row.source_id, row.event_id],
    );
    deleted += 1;
  }
  return deleted;
}

async function deleteDerivedData() {
  const [result] = await pool.query(
    `UPDATE monitoring_events
        SET derived_data = NULL,
            current_result_run_id = NULL,
            derived_deleted_at = UTC_TIMESTAMP(3)
      WHERE derived_deleted_at IS NULL
        AND received_at < DATE_SUB(UTC_TIMESTAMP(3), INTERVAL ? DAY)`,
    [derivedRetentionDays],
  );
  await pool.query(
    `DELETE ar
       FROM analysis_runs ar
       JOIN monitoring_events e
         ON e.source_id = ar.source_id AND e.event_id = ar.event_id
      WHERE e.derived_deleted_at IS NOT NULL`,
  );
  await pool.query(
    `DELETE FROM audit_log
      WHERE occurred_at < DATE_SUB(UTC_TIMESTAMP(3), INTERVAL ? DAY)`,
    [derivedRetentionDays],
  );
  await pool.query(
    `DELETE FROM monitoring_alerts
      WHERE created_at < DATE_SUB(UTC_TIMESTAMP(3), INTERVAL ? DAY)`,
    [derivedRetentionDays],
  );
  return result.affectedRows;
}

try {
  const rawDeleted = await deleteRawFiles();
  const derivedDeleted = await deleteDerivedData();
  console.log(JSON.stringify({
    event: "retention_completed",
    raw_deleted: rawDeleted,
    derived_deleted: derivedDeleted,
  }));
} finally {
  await pool.end();
}
