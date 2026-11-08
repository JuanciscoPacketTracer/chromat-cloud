import http from "node:http";
import mysql from "mysql2/promise";

const port = Number.parseInt(process.env.API_PORT ?? "3000", 10);
const pool = mysql.createPool({
  host: process.env.DB_HOST ?? "db",
  port: Number.parseInt(process.env.DB_PORT ?? "3306", 10),
  database: process.env.DB_NAME ?? "chromat",
  user: process.env.DB_USER ?? "chromat_user",
  password: process.env.DB_PASSWORD,
  connectionLimit: 4,
  enableKeepAlive: true,
});

function sendJson(response, statusCode, body) {
  const payload = JSON.stringify(body);
  response.writeHead(statusCode, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(payload),
  });
  response.end(payload);
}

async function isDatabaseReady() {
  const connection = await pool.getConnection();
  try {
    await connection.query("SELECT 1");
    const [rows] = await connection.query(
      "SELECT version FROM schema_migrations WHERE version = '001_initial' LIMIT 1",
    );
    return rows.length === 1;
  } finally {
    connection.release();
  }
}

const server = http.createServer(async (request, response) => {
  if (request.method !== "GET") {
    sendJson(response, 405, { error: "method_not_allowed" });
    return;
  }

  if (request.url === "/health/live") {
    sendJson(response, 200, { status: "ok" });
    return;
  }

  if (request.url === "/health/ready") {
    try {
      if (await isDatabaseReady()) {
        sendJson(response, 200, { status: "ready" });
      } else {
        sendJson(response, 503, { status: "not_ready" });
      }
    } catch {
      sendJson(response, 503, { status: "not_ready" });
    }
    return;
  }

  if (request.url === "/") {
    sendJson(response, 200, { service: "chromat-api" });
    return;
  }

  sendJson(response, 404, { error: "not_found" });
});

server.listen(port, "0.0.0.0", () => {
  console.log(JSON.stringify({ event: "api_started", port }));
});

async function shutdown(signal) {
  console.log(JSON.stringify({ event: "api_stopping", signal }));
  server.close(async () => {
    await pool.end();
    process.exit(0);
  });
}

process.once("SIGTERM", () => shutdown("SIGTERM"));
process.once("SIGINT", () => shutdown("SIGINT"));
