import Busboy from "busboy";
import crypto from "node:crypto";
import fs from "node:fs";
import fsp from "node:fs/promises";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import mysql from "mysql2/promise";

const port = Number.parseInt(process.env.API_PORT ?? "3000", 10);
const maxUploadBytes = 10 * 1024 * 1024;
const rawRoot = process.env.RAW_DATA_DIR ?? "/app/uploads";
const pool = mysql.createPool({
  host: process.env.DB_HOST ?? "db",
  port: Number.parseInt(process.env.DB_PORT ?? "3306", 10),
  database: process.env.DB_NAME ?? "chromat",
  user: process.env.DB_USER ?? "chromat_user",
  password: process.env.DB_PASSWORD,
  connectionLimit: 4,
  enableKeepAlive: true,
  dateStrings: true,
});
const rateBuckets = new Map();

function sendJson(response, statusCode, body, headers = {}) {
  const payload = JSON.stringify(body);
  response.writeHead(statusCode, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(payload),
    ...headers,
  });
  response.end(payload);
}

function errorResponse(response, statusCode, error, message, headers = {}) {
  sendJson(response, statusCode, { error, message }, headers);
}

function parseBearerToken(request) {
  const authorization = request.headers.authorization ?? "";
  const match = authorization.match(/^Bearer ([A-Za-z0-9_-]+)$/);
  return match?.[1] ?? null;
}

function consumeRateLimit(key) {
  const now = Date.now();
  const windowMs = 60_000;
  const limit = 120;
  const bucket = rateBuckets.get(key);
  if (!bucket || now - bucket.startedAt >= windowMs) {
    rateBuckets.set(key, { startedAt: now, count: 1 });
    return true;
  }
  bucket.count += 1;
  return bucket.count <= limit;
}

async function authenticate(request, response) {
  const token = parseBearerToken(request);
  if (!token) {
    errorResponse(response, 401, "unauthorized", "Bearer API key required");
    return null;
  }

  const prefix = token.slice(0, 20);
  if (!consumeRateLimit(`${request.socket.remoteAddress ?? "unknown"}:${prefix}`)) {
    errorResponse(
      response,
      429,
      "rate_limited",
      "Request rate limit exceeded",
      { "retry-after": "60" },
    );
    return null;
  }

  const [rows] = await pool.query(
    "SELECT source_id, api_key_hash FROM monitoring_sources WHERE api_key_prefix = ? AND status = 'active' LIMIT 1",
    [prefix],
  );
  const source = rows[0];
  const tokenHash = crypto.createHash("sha256").update(token).digest();
  if (
    !source ||
    source.api_key_hash.length !== tokenHash.length ||
    !crypto.timingSafeEqual(source.api_key_hash, tokenHash)
  ) {
    errorResponse(response, 401, "unauthorized", "Invalid API key");
    return null;
  }
  return source.source_id;
}

function parseTimestamp(value) {
  if (
    typeof value !== "string" ||
    !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(value)
  ) {
    return null;
  }
  const timestamp = new Date(value);
  return Number.isNaN(timestamp.getTime()) ? null : timestamp;
}

function toMysqlTimestamp(timestamp) {
  return timestamp.toISOString().replace("T", " ").replace("Z", "");
}

function mysqlToIso(value) {
  if (value instanceof Date) return value.toISOString();
  return `${value.replace(" ", "T")}Z`;
}

function isUuidV4(value) {
  return (
    typeof value === "string" &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(
      value,
    )
  );
}

function isClockSuspect(occurredAt, receivedAt) {
  const difference = occurredAt.getTime() - receivedAt.getTime();
  return difference > 5 * 60_000 || difference < -(7 * 24 * 60 * 60_000);
}

async function parseMultipart(request) {
  const contentLength = Number.parseInt(request.headers["content-length"] ?? "", 10);
  if (Number.isFinite(contentLength) && contentLength > maxUploadBytes) {
    const error = new Error("upload_too_large");
    error.statusCode = 413;
    throw error;
  }
  if (!/^multipart\/form-data(?:;|$)/i.test(request.headers["content-type"] ?? "")) {
    const error = new Error("unsupported_media_type");
    error.statusCode = 415;
    throw error;
  }

  const temporaryPath = path.join(os.tmpdir(), `chromat-${crypto.randomUUID()}`);
  const metadataParts = [];
  let metadata;
  let image;
  let parser;
  let fileError;
  let fileDone = Promise.resolve();

  try {
    parser = Busboy({
      headers: request.headers,
      limits: { fileSize: maxUploadBytes, files: 1, fields: 4 },
    });

    const parsed = new Promise((resolve, reject) => {
      parser.on("field", (name, value) => {
        if (name === "metadata") metadataParts.push(value);
      });
      parser.on("file", (name, file, info) => {
        if (name !== "image") {
          file.resume();
          return;
        }
        fileDone = new Promise((resolve, reject) => {
          const digest = crypto.createHash("sha256");
          let byteSize = 0;
          const output = fs.createWriteStream(temporaryPath, { mode: 0o600 });
          file.on("data", (chunk) => {
            byteSize += chunk.length;
            digest.update(chunk);
          });
          file.on("limit", () => {
            fileError = Object.assign(new Error("upload_too_large"), {
              statusCode: 413,
            });
            file.resume();
            output.destroy();
          });
          output.on("error", reject);
          output.on("close", () => {
            if (fileError) {
              reject(fileError);
              return;
            }
            image = {
              mediaType: info.mimeType,
              byteSize,
              sha256: digest.digest("hex"),
            };
            resolve();
          });
          file.pipe(output);
        });
      });
      parser.on("error", reject);
      parser.on("close", () => fileDone.then(resolve, reject));
    });

    request.pipe(parser);
    await parsed;
    if (metadataParts.length !== 1 || !image) {
      const error = new Error("invalid_multipart");
      error.statusCode = 400;
      throw error;
    }
    try {
      metadata = JSON.parse(metadataParts[0]);
    } catch {
      const error = new Error("invalid_metadata");
      error.statusCode = 400;
      throw error;
    }
    if (!metadata || typeof metadata !== "object" || Array.isArray(metadata)) {
      throw Object.assign(new Error("invalid_metadata"), { statusCode: 400 });
    }
    if (!["image/jpeg", "image/png"].includes(image.mediaType)) {
      const error = new Error("unsupported_media_type");
      error.statusCode = 415;
      throw error;
    }
    return { metadata, image, temporaryPath };
  } catch (error) {
    await fsp.rm(temporaryPath, { force: true });
    throw error;
  }
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

async function ingestEvent(request, response, sourceId) {
  let upload;
  try {
    upload = await parseMultipart(request);
    const { metadata, image } = upload;
    if (!isUuidV4(metadata.event_id)) {
      throw Object.assign(new Error("invalid_event_id"), { statusCode: 422 });
    }
    const occurredAt = parseTimestamp(metadata.occurred_at);
    if (!occurredAt) {
      throw Object.assign(new Error("invalid_occurred_at"), { statusCode: 422 });
    }
    if (
      metadata.temperature_c !== undefined &&
      typeof metadata.temperature_c !== "number"
    ) {
      throw Object.assign(new Error("invalid_temperature"), { statusCode: 422 });
    }
    if (
      metadata.humidity_rh !== undefined &&
      typeof metadata.humidity_rh !== "number"
    ) {
      throw Object.assign(new Error("invalid_humidity"), { statusCode: 422 });
    }

    const receivedAt = new Date();
    const eventId = metadata.event_id.toLowerCase();
    const extension = image.mediaType === "image/png" ? "png" : "jpg";
    const relativePath = path.join("raw", sourceId, `${eventId}.${extension}`);
    const absolutePath = path.join(rawRoot, relativePath);
    await fsp.mkdir(path.dirname(absolutePath), { recursive: true, mode: 0o700 });

    const connection = await pool.getConnection();
    let transactionStarted = false;
    try {
      await connection.beginTransaction();
      transactionStarted = true;
      const [existingRows] = await connection.query(
        "SELECT status, image_sha256, received_at FROM monitoring_events WHERE source_id = ? AND event_id = ? FOR UPDATE",
        [sourceId, eventId],
      );
      if (existingRows.length > 0) {
        const existing = existingRows[0];
        await connection.rollback();
        await fsp.rm(upload.temporaryPath, { force: true });
        if (existing.image_sha256 !== image.sha256) {
          errorResponse(
            response,
            409,
            "event_conflict",
            "event_id already exists with a different image",
          );
          return;
        }
        const statusCode = ["pending", "processing"].includes(existing.status)
          ? 202
          : 200;
        sendJson(response, statusCode, {
          event_id: eventId,
          status: existing.status,
          received_at: mysqlToIso(existing.received_at),
          status_url: `/api/v1/events/${eventId}`,
        });
        return;
      }

      await fsp.rename(upload.temporaryPath, absolutePath);
      const receivedMysql = toMysqlTimestamp(receivedAt);
      await connection.query(
        `INSERT INTO monitoring_events
          (source_id, event_id, occurred_at, received_at, clock_suspect, status,
           temperature_c, humidity_rh, image_sha256, created_at)
         VALUES (?, ?, ?, ?, ?, 'pending', ?, ?, ?, ?)`,
        [
          sourceId,
          eventId,
          toMysqlTimestamp(occurredAt),
          receivedMysql,
          isClockSuspect(occurredAt, receivedAt),
          metadata.temperature_c ?? null,
          metadata.humidity_rh ?? null,
          image.sha256,
          receivedMysql,
        ],
      );
      await connection.query(
        `INSERT INTO raw_files
          (source_id, event_id, storage_path, media_type, byte_size, sha256, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?)`,
        [
          sourceId,
          eventId,
          relativePath,
          image.mediaType,
          image.byteSize,
          image.sha256,
          receivedMysql,
        ],
      );
      await connection.query(
        `INSERT INTO jobs
          (source_id, event_id, state, attempts, available_at, created_at)
         VALUES (?, ?, 'queued', 0, ?, ?)`,
        [sourceId, eventId, receivedMysql, receivedMysql],
      );
      await connection.commit();
      sendJson(response, 202, {
        event_id: eventId,
        status: "pending",
        received_at: receivedAt.toISOString(),
        status_url: `/api/v1/events/${eventId}`,
      });
    } catch (error) {
      if (transactionStarted) await connection.rollback();
      await fsp.rm(absolutePath, { force: true });
      throw error;
    } finally {
      connection.release();
    }
  } catch (error) {
    if (upload?.temporaryPath) {
      await fsp.rm(upload.temporaryPath, { force: true });
    }
    const statusCode = error.statusCode ?? 500;
    if (statusCode === 500) {
      console.error(JSON.stringify({ event: "event_ingestion_failed", error: error.message }));
      errorResponse(response, 500, "internal_error", "Unable to persist event");
    } else {
      errorResponse(response, statusCode, error.message, "Invalid monitoring event");
    }
  }
}

async function getEvent(request, response, sourceId, eventId) {
  const [rows] = await pool.query(
    `SELECT e.event_id, e.occurred_at, e.received_at, e.clock_suspect, e.status,
            e.temperature_c, e.humidity_rh, r.storage_path, r.media_type, r.byte_size,
            r.sha256
       FROM monitoring_events e
       JOIN raw_files r ON r.source_id = e.source_id AND r.event_id = e.event_id
      WHERE e.source_id = ? AND e.event_id = ?`,
    [sourceId, eventId],
  );
  if (rows.length === 0) {
    errorResponse(response, 404, "not_found", "Event not found");
    return;
  }
  const event = rows[0];
  sendJson(response, 200, {
    event_id: event.event_id,
    status: event.status,
    occurred_at: mysqlToIso(event.occurred_at),
    received_at: mysqlToIso(event.received_at),
    clock_suspect: Boolean(event.clock_suspect),
    temperature_c: event.temperature_c,
    humidity_rh: event.humidity_rh,
    raw_file: {
      media_type: event.media_type,
      byte_size: Number(event.byte_size),
      sha256: event.sha256,
    },
  });
}

const server = http.createServer(async (request, response) => {
  try {
    if (request.method === "GET" && request.url === "/health/live") {
      sendJson(response, 200, { status: "ok" });
      return;
    }
    if (request.method === "GET" && request.url === "/health/ready") {
      const ready = await isDatabaseReady();
      sendJson(response, ready ? 200 : 503, {
        status: ready ? "ready" : "not_ready",
      });
      return;
    }
    if (request.method === "GET" && request.url === "/") {
      sendJson(response, 200, { service: "chromat-api" });
      return;
    }

    const parsedUrl = new URL(request.url, `http://${request.headers.host}`);
    const eventMatch = parsedUrl.pathname.match(
      /^\/api\/v1\/events\/([0-9a-f-]{36})$/i,
    );
    const isIngestion = request.method === "POST" && parsedUrl.pathname === "/api/v1/events";
    if (!isIngestion && !(request.method === "GET" && eventMatch)) {
      errorResponse(response, 404, "not_found", "Route not found");
      return;
    }
    const sourceId = await authenticate(request, response);
    if (!sourceId) return;
    if (isIngestion) {
      await ingestEvent(request, response, sourceId);
    } else if (isUuidV4(eventMatch[1])) {
      await getEvent(request, response, sourceId, eventMatch[1].toLowerCase());
    } else {
      errorResponse(response, 404, "not_found", "Event not found");
    }
  } catch (error) {
    console.error(JSON.stringify({ event: "request_failed", error: error.message }));
    errorResponse(response, 503, "not_ready", "Service is not ready");
  }
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
