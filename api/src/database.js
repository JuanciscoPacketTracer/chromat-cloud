import fs from "node:fs";

function readRequiredSecret(name) {
  const file = process.env[`${name}_FILE`];
  if (!file) {
    throw new Error(`${name}_FILE is required`);
  }
  const value = fs.readFileSync(file, "utf8").trim();
  if (!value) {
    throw new Error(`${name}_FILE must not be empty`);
  }
  return value;
}

export function databaseConfig(connectionLimit) {
  return {
    host: process.env.DB_HOST ?? "db",
    port: Number.parseInt(process.env.DB_PORT ?? "3306", 10),
    database: process.env.DB_NAME ?? "chromat",
    user: process.env.DB_USER ?? "chromat_user",
    password: readRequiredSecret("DB_PASSWORD"),
    connectionLimit,
    dateStrings: true,
  };
}
