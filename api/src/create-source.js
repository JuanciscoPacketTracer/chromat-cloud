import crypto from "node:crypto";
import mysql from "mysql2/promise";
import { toMysqlTimestamp } from "./time.js";

const nameIndex = process.argv.indexOf("--name");
const name = nameIndex >= 0 ? process.argv[nameIndex + 1] : null;
if (!name) {
  console.error("Usage: npm run create-source -- --name <name>");
  process.exit(2);
}

const sourceId = crypto.randomUUID();
const apiKey = `chm_${crypto.randomBytes(32).toString("base64url")}`;
const apiKeyPrefix = apiKey.slice(0, 20);
const apiKeyHash = crypto.createHash("sha256").update(apiKey).digest();
const mysqlTimestamp = toMysqlTimestamp(new Date());

const connection = await mysql.createConnection({
  host: process.env.DB_HOST ?? "db",
  port: Number.parseInt(process.env.DB_PORT ?? "3306", 10),
  database: process.env.DB_NAME ?? "chromat",
  user: process.env.DB_USER ?? "chromat_user",
  password: process.env.DB_PASSWORD,
});

try {
  await connection.execute(
    `INSERT INTO monitoring_sources
      (source_id, name, api_key_prefix, api_key_hash, created_at)
     VALUES (?, ?, ?, ?, ?)`,
    [sourceId, name, apiKeyPrefix, apiKeyHash, mysqlTimestamp],
  );
  await connection.execute(
    `INSERT INTO monitoring_source_keys
      (key_id, source_id, api_key_prefix, api_key_hash, created_at)
     VALUES (?, ?, ?, ?, ?)`,
    [crypto.randomUUID(), sourceId, apiKeyPrefix, apiKeyHash, mysqlTimestamp],
  );
  console.log(JSON.stringify({ source_id: sourceId, name, api_key: apiKey }));
} finally {
  await connection.end();
}
