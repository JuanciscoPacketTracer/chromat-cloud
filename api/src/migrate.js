import fs from "node:fs/promises";
import path from "node:path";
import mysql from "mysql2/promise";
import { databaseConfig } from "./database.js";

const migrationRoot = process.env.MIGRATION_DIR ?? "/app/migrations";

export async function migrate() {
  const pool = mysql.createPool({
    ...databaseConfig(1),
    multipleStatements: true,
  });
  const connection = await pool.getConnection();
  try {
    const [lockRows] = await connection.query(
      "SELECT GET_LOCK('chromat_migrations', 30) AS acquired",
    );
    if (Number(lockRows[0]?.acquired) !== 1) {
      throw new Error("migration_lock_timeout");
    }
    const files = (await fs.readdir(migrationRoot))
      .filter((file) => /^\d+_.+\.sql$/.test(file))
      .sort();
    for (const file of files) {
      const version = file.slice(0, file.indexOf("_"));
      if (version === "001") {
        await connection.query(await fs.readFile(path.join(migrationRoot, file), "utf8"));
        continue;
      }
      const [rows] = await connection.query(
        "SELECT 1 FROM schema_migrations WHERE version = ? LIMIT 1",
        [`${version}_${file.slice(file.indexOf("_") + 1, -4)}`],
      );
      if (rows.length === 0) {
        await connection.query(await fs.readFile(path.join(migrationRoot, file), "utf8"));
      }
    }
    await connection.query("SELECT RELEASE_LOCK('chromat_migrations')");
  } finally {
    connection.release();
    await pool.end();
  }
}
