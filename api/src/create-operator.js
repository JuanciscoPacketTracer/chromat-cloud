import fs from "node:fs/promises";
import crypto from "node:crypto";
import argon2 from "argon2";
import mysql from "mysql2/promise";
import { migrate } from "./migrate.js";

const username = process.argv[2];
const passwordFile = process.env.OPERATOR_PASSWORD_FILE;
if (!username || !passwordFile) {
  console.error("Usage: OPERATOR_PASSWORD_FILE=/run/secrets/password npm run create-operator -- <username>");
  process.exit(2);
}

const password = (await fs.readFile(passwordFile, "utf8")).trim();
if (!password) {
  console.error("Operator password file is empty");
  process.exit(2);
}

await migrate();
const pool = mysql.createPool({
  host: process.env.DB_HOST ?? "db",
  port: Number.parseInt(process.env.DB_PORT ?? "3306", 10),
  database: process.env.DB_NAME ?? "chromat",
  user: process.env.DB_USER ?? "chromat_user",
  password: process.env.DB_PASSWORD,
  dateStrings: true,
});
const connection = await pool.getConnection();
try {
  const [lockRows] = await connection.query(
    "SELECT GET_LOCK('chromat_first_operator', 30) AS acquired",
  );
  if (Number(lockRows[0]?.acquired) !== 1) {
    throw new Error("operator_creation_lock_timeout");
  }
  const [countRows] = await connection.query("SELECT COUNT(*) AS count FROM operators");
  if (Number(countRows[0].count) !== 0) {
    throw new Error("first_operator_already_exists");
  }
  await connection.query(
    `INSERT INTO operators
      (operator_id, username, password_hash, created_at)
     VALUES (?, ?, ?, UTC_TIMESTAMP(3))`,
    [crypto.randomUUID(), username, await argon2.hash(password, { type: argon2.argon2id })],
  );
  console.log(`Created operator: ${username}`);
} finally {
  await connection.query("SELECT RELEASE_LOCK('chromat_first_operator')");
  connection.release();
  await pool.end();
}
