import Busboy from "busboy";
import crypto from "node:crypto";
import fs from "node:fs";
import fsp from "node:fs/promises";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import argon2 from "argon2";
import mysql from "mysql2/promise";
import { migrate } from "./migrate.js";
import { mysqlToIso, toMysqlTimestamp } from "./time.js";

const port = Number.parseInt(process.env.API_PORT ?? "3000", 10);
const maxUploadBytes = Number.parseInt(
  process.env.UPLOAD_MAX_BYTES ?? `${10 * 1024 * 1024}`,
  10,
);
const rawRoot = process.env.RAW_DATA_DIR ?? "/app/uploads";
const maintenanceMarker = path.join(rawRoot, ".maintenance");
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
const loginBuckets = new Map();

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

function parseCookies(request) {
  return Object.fromEntries(
    (request.headers.cookie ?? "")
      .split(";")
      .map((part) => part.trim().split("="))
      .filter(([name, value]) => name && value)
      .map(([name, ...value]) => [name, value.join("=")]),
  );
}

function parseJsonBody(request) {
  return new Promise((resolve, reject) => {
    let body = "";
    request.setEncoding("utf8");
    request.on("data", (chunk) => {
      body += chunk;
      if (body.length > 32_768) reject(Object.assign(new Error("body_too_large"), { statusCode: 413 }));
    });
    request.on("end", () => {
      try {
        resolve(JSON.parse(body));
      } catch {
        reject(Object.assign(new Error("invalid_json"), { statusCode: 400 }));
      }
    });
    request.on("error", reject);
  });
}

async function listSourceEvents(response, sourceId) {
  const [rows] = await pool.query(
    `SELECT e.event_id, e.occurred_at, e.received_at, e.processed_at,
            e.clock_suspect, e.status, e.crop, e.derived_data,
            ar.run_id, ar.algorithm, ar.algorithm_version, ar.model_version,
            ar.model_sha256, ar.started_at, ar.completed_at, ar.result
       FROM monitoring_events e
       LEFT JOIN analysis_runs ar ON ar.run_id = e.current_result_run_id
      WHERE e.source_id = ?
      ORDER BY e.occurred_at DESC
      LIMIT 100`,
    [sourceId],
  );
  sendJson(response, 200, {
    events: rows.map((event) => ({
      event_id: event.event_id,
      occurred_at: mysqlToIso(event.occurred_at),
      received_at: mysqlToIso(event.received_at),
      processed_at: event.processed_at ? mysqlToIso(event.processed_at) : null,
      clock_suspect: Boolean(event.clock_suspect),
      status: event.status,
      crop: event.crop,
      current_result: event.run_id
        ? {
            run_id: Number(event.run_id),
            algorithm: event.algorithm,
            algorithm_version: event.algorithm_version,
            model_version: event.model_version,
            model_sha256: event.model_sha256,
            started_at: mysqlToIso(event.started_at),
            completed_at: mysqlToIso(event.completed_at),
            result: event.result,
          }
        : null,
    })),
  });
}

async function adminListSourceEvents(request, response, sourceId) {
  const session = await authenticateAdmin(request, response);
  if (!session) return;
  const [sources] = await pool.query(
    "SELECT 1 FROM monitoring_sources WHERE source_id = ? LIMIT 1",
    [sourceId],
  );
  if (sources.length !== 1) {
    errorResponse(response, 404, "not_found", "Source not found");
    return;
  }
  await listSourceEvents(response, sourceId);
}

async function audit(action, request, operatorId = null, metadata = null) {
  await pool.query(
    `INSERT INTO audit_log
      (occurred_at, action, operator_id, request_ip, metadata)
     VALUES (UTC_TIMESTAMP(3), ?, ?, ?, ?)`,
    [
      action,
      operatorId,
      request.socket.remoteAddress ?? null,
      metadata ? JSON.stringify(metadata) : null,
    ],
  );
}

function consumeLoginLimit(request) {
  const key = request.socket.remoteAddress ?? "unknown";
  const now = Date.now();
  const bucket = loginBuckets.get(key);
  if (!bucket || now - bucket.startedAt >= 15 * 60_000) {
    loginBuckets.set(key, { startedAt: now, count: 1 });
    return true;
  }
  bucket.count += 1;
  return bucket.count <= 10;
}

async function authenticateAdmin(request, response) {
  const token = parseCookies(request).chromat_session;
  if (!token) {
    await audit("admin_access_denied", request);
    errorResponse(response, 401, "unauthorized", "Administrative session required");
    return null;
  }
  const tokenHash = crypto.createHash("sha256").update(token).digest();
  const [rows] = await pool.query(
    `SELECT s.session_id, s.operator_id, s.csrf_hash, o.username
       FROM admin_sessions s
       JOIN operators o ON o.operator_id = s.operator_id
      WHERE s.token_hash = ? AND s.revoked_at IS NULL
        AND s.expires_at > UTC_TIMESTAMP(3) AND o.status = 'active'
      LIMIT 1`,
    [tokenHash],
  );
  if (rows.length === 0) {
    await audit("admin_access_denied", request);
    errorResponse(response, 401, "unauthorized", "Administrative session required");
    return null;
  }
  return { ...rows[0], tokenHash };
}

async function requireCsrf(request, response, session) {
  const token = request.headers["x-csrf-token"];
  const tokenHash = token
    ? crypto.createHash("sha256").update(token).digest()
    : null;
  if (
    !tokenHash ||
    session.csrf_hash.length !== tokenHash.length ||
    !crypto.timingSafeEqual(session.csrf_hash, tokenHash)
  ) {
    await audit("csrf_rejected", request, session.operator_id);
    errorResponse(response, 403, "csrf_required", "Valid CSRF token required");
    return false;
  }
  return true;
}

async function adminLogin(request, response) {
  if (!consumeLoginLimit(request)) {
    await audit("login_rate_limited", request);
    errorResponse(response, 429, "rate_limited", "Login rate limit exceeded", {
      "retry-after": "900",
    });
    return;
  }
  let credentials;
  try {
    credentials = await parseJsonBody(request);
  } catch (error) {
    errorResponse(response, error.statusCode ?? 400, error.message, "Invalid login request");
    return;
  }
  const username = typeof credentials.username === "string" ? credentials.username : "";
  const password = typeof credentials.password === "string" ? credentials.password : "";
  const [rows] = await pool.query(
    "SELECT operator_id, username, password_hash FROM operators WHERE username = ? AND status = 'active' LIMIT 1",
    [username],
  );
  const operator = rows[0];
  const valid = operator
    ? await argon2.verify(operator.password_hash, password)
    : false;
  if (!valid) {
    await audit("login_failed", request, operator?.operator_id ?? null);
    errorResponse(response, 401, "unauthorized", "Invalid credentials");
    return;
  }

  const sessionToken = crypto.randomBytes(32).toString("base64url");
  const csrfToken = crypto.randomBytes(32).toString("base64url");
  await pool.query(
    `INSERT INTO admin_sessions
      (session_id, operator_id, token_hash, csrf_hash, expires_at, created_at)
     VALUES (?, ?, ?, ?, DATE_ADD(UTC_TIMESTAMP(3), INTERVAL 8 HOUR), UTC_TIMESTAMP(3))`,
    [
      crypto.randomUUID(),
      operator.operator_id,
      crypto.createHash("sha256").update(sessionToken).digest(),
      crypto.createHash("sha256").update(csrfToken).digest(),
    ],
  );
  await pool.query(
    "UPDATE operators SET last_login_at = UTC_TIMESTAMP(3) WHERE operator_id = ?",
    [operator.operator_id],
  );
  await audit("login_succeeded", request, operator.operator_id);
  sendJson(
    response,
    200,
    { operator: { username: operator.username }, csrf_token: csrfToken },
    {
      "set-cookie": "chromat_session=" +
        `${sessionToken}; Max-Age=28800; Path=/api/v1/admin; Secure; HttpOnly; SameSite=Strict`,
    },
  );
}

async function adminLogout(request, response) {
  const session = await authenticateAdmin(request, response);
  if (!session || !(await requireCsrf(request, response, session))) return;
  await pool.query(
    "UPDATE admin_sessions SET revoked_at = UTC_TIMESTAMP(3) WHERE session_id = ?",
    [session.session_id],
  );
  await audit("logout", request, session.operator_id);
  response.writeHead(204, {
    "set-cookie": "chromat_session=; Max-Age=0; Path=/api/v1/admin; Secure; HttpOnly; SameSite=Strict",
  });
  response.end();
}

async function adminAudit(request, response) {
  const session = await authenticateAdmin(request, response);
  if (!session) return;
  const [rows] = await pool.query(
    `SELECT occurred_at, action, operator_id, request_ip, metadata
       FROM audit_log ORDER BY audit_id DESC LIMIT 100`,
  );
  sendJson(response, 200, {
    entries: rows.map((row) => ({
      occurred_at: mysqlToIso(row.occurred_at),
      action: row.action,
      operator_id: row.operator_id,
      request_ip: row.request_ip,
      metadata: row.metadata,
    })),
  });
}

async function adminDownloadRaw(request, response, sourceId, eventId) {
  const session = await adminSessionWithCsrf(request, response);
  if (!session) return;
  const [rows] = await pool.query(
    `SELECT r.storage_path, r.media_type, r.byte_size
       FROM raw_files r
      WHERE r.source_id = ? AND r.event_id = ? AND r.storage_path IS NOT NULL
      LIMIT 1`,
    [sourceId, eventId],
  );
  if (rows.length === 0) {
    await audit("raw_access_denied", request, session.operator_id, {
      source_id: sourceId,
      event_id: eventId,
    });
    errorResponse(response, 404, "not_found", "Raw data not found");
    return;
  }

  const rawPath = path.resolve(rawRoot, rows[0].storage_path);
  const rawRootPath = `${path.resolve(rawRoot)}${path.sep}`;
  if (!rawPath.startsWith(rawRootPath)) {
    await audit("raw_access_denied", request, session.operator_id, {
      source_id: sourceId,
      event_id: eventId,
      reason: "invalid_storage_path",
    });
    errorResponse(response, 500, "internal_error", "Invalid raw data path");
    return;
  }

  try {
    await fsp.access(rawPath, fs.constants.R_OK);
  } catch {
    await audit("raw_access_missing", request, session.operator_id, {
      source_id: sourceId,
      event_id: eventId,
    });
    errorResponse(response, 404, "not_found", "Raw data not found");
    return;
  }

  await audit("raw_download_started", request, session.operator_id, {
    source_id: sourceId,
    event_id: eventId,
  });
  response.writeHead(200, {
    "content-type": rows[0].media_type,
    "content-length": rows[0].byte_size,
    "content-disposition": `attachment; filename="${eventId}"`,
    "cache-control": "no-store",
  });
  const stream = fs.createReadStream(rawPath);
  let completed = false;
  response.once("finish", () => {
    completed = true;
    audit("raw_downloaded", request, session.operator_id, {
      source_id: sourceId,
      event_id: eventId,
    }).catch((error) => console.error(JSON.stringify({
      event: "raw_download_audit_failed",
      source_id: sourceId,
      event_id: eventId,
      error: error.message,
    })));
  });
  response.once("close", () => {
    if (!completed) {
      audit("raw_download_failed", request, session.operator_id, {
        source_id: sourceId,
        event_id: eventId,
      }).catch((error) => console.error(JSON.stringify({
        event: "raw_download_audit_failed",
        source_id: sourceId,
        event_id: eventId,
        error: error.message,
      })));
    }
  });
  stream.on("error", () => {
    if (!response.headersSent) {
      errorResponse(response, 404, "not_found", "Raw data not found");
    } else {
      response.destroy();
    }
  });
  stream.pipe(response);
}

function createSourceKey() {
  const apiKey = `chm_${crypto.randomBytes(32).toString("base64url")}`;
  return {
    apiKey,
    prefix: apiKey.slice(0, 20),
    hash: crypto.createHash("sha256").update(apiKey).digest(),
  };
}

async function adminSessionWithCsrf(request, response) {
  const session = await authenticateAdmin(request, response);
  if (!session || !(await requireCsrf(request, response, session))) return null;
  return session;
}

async function adminCreateSource(request, response) {
  const session = await adminSessionWithCsrf(request, response);
  if (!session) return;
  const body = await parseJsonBody(request);
  if (
    typeof body.name !== "string" ||
    typeof body.crop !== "string" ||
    typeof body.is_test !== "boolean"
  ) {
    errorResponse(response, 422, "invalid_source", "name, crop and is_test are required");
    return;
  }
  const sourceId = crypto.randomUUID();
  const key = createSourceKey();
  const connection = await pool.getConnection();
  try {
    await connection.beginTransaction();
    await connection.query(
      `INSERT INTO monitoring_sources
        (source_id, name, api_key_prefix, api_key_hash, crop, is_test,
         alert_chat_id, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, UTC_TIMESTAMP(3))`,
      [
        sourceId,
        body.name,
        key.prefix,
        key.hash,
        body.crop,
        body.is_test,
        body.chat_id ?? null,
      ],
    );
    await connection.query(
      `INSERT INTO monitoring_source_keys
        (key_id, source_id, api_key_prefix, api_key_hash, created_at)
       VALUES (?, ?, ?, ?, UTC_TIMESTAMP(3))`,
      [crypto.randomUUID(), sourceId, key.prefix, key.hash],
    );
    if (body.chat_id) {
      await connection.query(
        `INSERT INTO monitoring_source_alerts
          (source_id, crop, chat_id, created_at)
         VALUES (?, ?, ?, UTC_TIMESTAMP(3))`,
        [sourceId, body.crop, body.chat_id],
      );
    }
    await connection.commit();
  } catch (error) {
    await connection.rollback();
    throw error;
  } finally {
    connection.release();
  }
  await audit("source_created", request, session.operator_id, {
    source_id: sourceId,
    is_test: body.is_test,
  });
  sendJson(response, 201, {
    source_id: sourceId,
    name: body.name,
    crop: body.crop,
    is_test: body.is_test,
    status: "active",
    api_key: key.apiKey,
  });
}

async function adminListSources(request, response) {
  const session = await authenticateAdmin(request, response);
  if (!session) return;
  const [rows] = await pool.query(
    `SELECT source_id, name, crop, is_test, status, alert_chat_id, created_at, revoked_at
       FROM monitoring_sources ORDER BY created_at`,
  );
  sendJson(response, 200, {
    sources: rows.map((row) => ({
      source_id: row.source_id,
      name: row.name,
      crop: row.crop,
      is_test: Boolean(row.is_test),
      status: row.status,
      has_chat_id: Boolean(row.alert_chat_id),
      created_at: mysqlToIso(row.created_at),
      revoked_at: row.revoked_at ? mysqlToIso(row.revoked_at) : null,
    })),
  });
}

async function adminUpdateSource(request, response, sourceId) {
  const session = await adminSessionWithCsrf(request, response);
  if (!session) return;
  const body = await parseJsonBody(request);
  const updates = [];
  const values = [];
  if (typeof body.status === "string" && ["active", "paused", "revoked"].includes(body.status)) {
    updates.push("status = ?", "revoked_at = IF(? = 'revoked', UTC_TIMESTAMP(3), NULL)");
    values.push(body.status, body.status);
  }
  if (typeof body.crop === "string") {
    updates.push("crop = ?");
    values.push(body.crop);
  }
  if (typeof body.chat_id === "string" || body.chat_id === null) {
    updates.push("alert_chat_id = ?");
    values.push(body.chat_id);
  }
  if (updates.length === 0) {
    errorResponse(response, 422, "invalid_source_update", "No valid source fields");
    return;
  }
  values.push(sourceId);
  const [result] = await pool.query(
    `UPDATE monitoring_sources SET ${updates.join(", ")} WHERE source_id = ?`,
    values,
  );
  if (result.affectedRows !== 1) {
    errorResponse(response, 404, "not_found", "Source not found");
    return;
  }
  if (body.chat_id !== undefined) {
    const [sourceRows] = await pool.query(
      "SELECT crop FROM monitoring_sources WHERE source_id = ?",
      [sourceId],
    );
    const crop = body.crop ?? sourceRows[0]?.crop;
    if (crop) {
      if (body.chat_id === null) {
        await pool.query(
          "DELETE FROM monitoring_source_alerts WHERE source_id = ? AND crop = ?",
          [sourceId, crop],
        );
      } else {
        await pool.query(
          `INSERT INTO monitoring_source_alerts
            (source_id, crop, chat_id, created_at)
           VALUES (?, ?, ?, UTC_TIMESTAMP(3))
           ON DUPLICATE KEY UPDATE chat_id = VALUES(chat_id)`,
          [sourceId, crop, body.chat_id],
        );
      }
    }
  }
  await audit("source_updated", request, session.operator_id, {
    source_id: sourceId,
    status: body.status ?? undefined,
  });
  sendJson(response, 200, { source_id: sourceId, updated: true });
}

async function adminRotateSourceKey(request, response, sourceId) {
  const session = await adminSessionWithCsrf(request, response);
  if (!session) return;
  const body = await parseJsonBody(request);
  const coexistSeconds = body.coexist_seconds === undefined
    ? 0
    : Number.parseInt(body.coexist_seconds, 10);
  if (!Number.isInteger(coexistSeconds) || coexistSeconds < 0 || coexistSeconds > 86_400) {
    errorResponse(response, 422, "invalid_coexistence", "coexist_seconds must be 0..86400");
    return;
  }
  const key = createSourceKey();
  const connection = await pool.getConnection();
  try {
    await connection.beginTransaction();
    const [sources] = await connection.query(
      "SELECT source_id FROM monitoring_sources WHERE source_id = ? FOR UPDATE",
      [sourceId],
    );
    if (sources.length !== 1) {
      await connection.rollback();
      errorResponse(response, 404, "not_found", "Source not found");
      return;
    }
    await connection.query(
      `UPDATE monitoring_source_keys
          SET expires_at = IF(? > 0, DATE_ADD(UTC_TIMESTAMP(3), INTERVAL ? SECOND), UTC_TIMESTAMP(3))
        WHERE source_id = ? AND revoked_at IS NULL AND expires_at IS NULL`,
      [coexistSeconds, coexistSeconds, sourceId],
    );
    await connection.query(
      `INSERT INTO monitoring_source_keys
        (key_id, source_id, api_key_prefix, api_key_hash, created_at)
       VALUES (?, ?, ?, ?, UTC_TIMESTAMP(3))`,
      [crypto.randomUUID(), sourceId, key.prefix, key.hash],
    );
    await connection.commit();
  } catch (error) {
    await connection.rollback();
    throw error;
  } finally {
    connection.release();
  }
  await audit("source_key_rotated", request, session.operator_id, {
    source_id: sourceId,
    coexist_seconds: coexistSeconds,
  });
  sendJson(response, 201, { source_id: sourceId, api_key: key.apiKey });
}

async function adminCreateProducer(request, response) {
  const session = await adminSessionWithCsrf(request, response);
  if (!session) return;
  const body = await parseJsonBody(request);
  if (typeof body.username !== "string" || typeof body.password !== "string") {
    errorResponse(response, 422, "invalid_producer", "username and password are required");
    return;
  }
  const producerId = crypto.randomUUID();
  await pool.query(
    `INSERT INTO producer_accounts
      (producer_id, username, password_hash, created_at)
     VALUES (?, ?, ?, UTC_TIMESTAMP(3))`,
    [producerId, body.username, await argon2.hash(body.password, { type: argon2.argon2id })],
  );
  await audit("producer_created", request, session.operator_id, { producer_id: producerId });
  sendJson(response, 201, { producer_id: producerId, username: body.username });
}

async function adminAssignProducer(request, response, producerId) {
  const session = await adminSessionWithCsrf(request, response);
  if (!session) return;
  const body = await parseJsonBody(request);
  if (typeof body.source_id !== "string") {
    errorResponse(response, 422, "invalid_assignment", "source_id is required");
    return;
  }
  await pool.query(
    `INSERT INTO producer_source_assignments
      (producer_id, source_id, permission, created_at)
     VALUES (?, ?, 'read', UTC_TIMESTAMP(3))`,
    [producerId, body.source_id],
  );
  await audit("producer_source_assigned", request, session.operator_id, {
    producer_id: producerId,
    source_id: body.source_id,
  });
  sendJson(response, 201, { producer_id: producerId, source_id: body.source_id, permission: "read" });
}

async function authenticateProducer(request, response) {
  const token = parseCookies(request).chromat_producer;
  if (!token) {
    errorResponse(response, 401, "unauthorized", "Producer session required");
    return null;
  }
  const [rows] = await pool.query(
    `SELECT s.session_id, s.producer_id
       FROM producer_sessions s
       JOIN producer_accounts p ON p.producer_id = s.producer_id
      WHERE s.token_hash = ? AND s.revoked_at IS NULL
        AND s.expires_at > UTC_TIMESTAMP(3) AND p.status = 'active'
      LIMIT 1`,
    [crypto.createHash("sha256").update(token).digest()],
  );
  if (rows.length === 0) {
    errorResponse(response, 401, "unauthorized", "Producer session required");
    return null;
  }
  return rows[0];
}

async function producerLogin(request, response) {
  let credentials;
  try {
    credentials = await parseJsonBody(request);
  } catch (error) {
    errorResponse(response, error.statusCode ?? 400, error.message, "Invalid login request");
    return;
  }
  const [rows] = await pool.query(
    "SELECT producer_id, username, password_hash FROM producer_accounts WHERE username = ? AND status = 'active' LIMIT 1",
    [credentials.username],
  );
  const producer = rows[0];
  if (!producer || !(await argon2.verify(producer.password_hash, credentials.password ?? ""))) {
    errorResponse(response, 401, "unauthorized", "Invalid credentials");
    return;
  }
  const token = crypto.randomBytes(32).toString("base64url");
  await pool.query(
    `INSERT INTO producer_sessions
      (session_id, producer_id, token_hash, expires_at, created_at)
     VALUES (?, ?, ?, DATE_ADD(UTC_TIMESTAMP(3), INTERVAL 8 HOUR), UTC_TIMESTAMP(3))`,
    [
      crypto.randomUUID(),
      producer.producer_id,
      crypto.createHash("sha256").update(token).digest(),
    ],
  );
  sendJson(response, 200, { producer: { username: producer.username } }, {
    "set-cookie": `chromat_producer=${token}; Max-Age=28800; Path=/api/v1/producer; Secure; HttpOnly; SameSite=Strict`,
  });
}

async function producerLogout(request, response) {
  const session = await authenticateProducer(request, response);
  if (!session) return;
  await pool.query(
    "UPDATE producer_sessions SET revoked_at = UTC_TIMESTAMP(3) WHERE session_id = ?",
    [session.session_id],
  );
  response.writeHead(204, {
    "set-cookie": "chromat_producer=; Max-Age=0; Path=/api/v1/producer; Secure; HttpOnly; SameSite=Strict",
  });
  response.end();
}

async function producerSources(request, response) {
  const session = await authenticateProducer(request, response);
  if (!session) return;
  const [rows] = await pool.query(
    `SELECT s.source_id, s.name, s.crop, s.is_test, s.status
       FROM producer_source_assignments a
       JOIN monitoring_sources s ON s.source_id = a.source_id
      WHERE a.producer_id = ? AND s.status = 'active'
      ORDER BY s.name`,
    [session.producer_id],
  );
  sendJson(response, 200, {
    sources: rows.map((row) => ({
      source_id: row.source_id,
      name: row.name,
      crop: row.crop,
      is_test: Boolean(row.is_test),
      status: row.status,
    })),
  });
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
    `SELECT s.source_id, k.api_key_hash
       FROM monitoring_source_keys k
       JOIN monitoring_sources s ON s.source_id = k.source_id
      WHERE k.api_key_prefix = ? AND k.revoked_at IS NULL
        AND (k.expires_at IS NULL OR k.expires_at > UTC_TIMESTAMP(3))
        AND s.status = 'active'
      LIMIT 1`,
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

async function isMaintenanceActive() {
  try {
    await fsp.access(maintenanceMarker, fs.constants.F_OK);
    return true;
  } catch (error) {
    if (error.code === "ENOENT") return false;
    throw error;
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
           crop, temperature_c, humidity_rh, image_sha256, created_at)
         SELECT ?, ?, ?, ?, ?, 'pending', crop, ?, ?, ?, ?
           FROM monitoring_sources WHERE source_id = ?`,
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
          sourceId,
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
    `SELECT e.event_id, e.occurred_at, e.received_at, e.processed_at,
            e.clock_suspect, e.status, e.crop, e.derived_data,
            ar.run_id, ar.algorithm, ar.algorithm_version, ar.model_version,
            ar.model_sha256, ar.started_at, ar.completed_at, ar.result,
            (SELECT COUNT(*) FROM analysis_runs ar_count
              WHERE ar_count.source_id = e.source_id
                AND ar_count.event_id = e.event_id) AS analysis_runs_count,
            e.temperature_c, e.humidity_rh, r.storage_path, r.media_type, r.byte_size,
            r.sha256
       FROM monitoring_events e
       LEFT JOIN raw_files r ON r.source_id = e.source_id AND r.event_id = e.event_id
       LEFT JOIN analysis_runs ar ON ar.run_id = e.current_result_run_id
      WHERE e.source_id = ? AND e.event_id = ?`,
    [sourceId, eventId],
  );
  if (rows.length === 0) {
    await audit("event_access_denied", request, null, { event_id: eventId });
    errorResponse(response, 404, "not_found", "Event not found");
    return;
  }
  const event = rows[0];
  const [analysisRows] = await pool.query(
    `SELECT run_id, algorithm, algorithm_version, model_version, model_sha256,
            started_at, completed_at, status, result, error_message
       FROM analysis_runs
      WHERE source_id = ? AND event_id = ?
      ORDER BY run_id`,
    [sourceId, eventId],
  );
  const analysisRuns = analysisRows.map((run) => ({
    run_id: Number(run.run_id),
    algorithm: run.algorithm,
    algorithm_version: run.algorithm_version,
    model_version: run.model_version,
    model_sha256: run.model_sha256,
    started_at: mysqlToIso(run.started_at),
    completed_at: run.completed_at ? mysqlToIso(run.completed_at) : null,
    status: run.status,
    result: run.result,
    error_message: run.error_message,
  }));
  const comparison = Object.fromEntries(
    analysisRuns.map((run) => [run.algorithm, run.result]),
  );
  sendJson(response, 200, {
    event_id: event.event_id,
    status: event.status,
    occurred_at: mysqlToIso(event.occurred_at),
    received_at: mysqlToIso(event.received_at),
    processed_at: event.processed_at ? mysqlToIso(event.processed_at) : null,
    clock_suspect: Boolean(event.clock_suspect),
    crop: event.crop,
    derived_data: event.derived_data,
    current_result: event.run_id
      ? {
          run_id: Number(event.run_id),
          algorithm: event.algorithm,
          algorithm_version: event.algorithm_version,
          model_version: event.model_version,
          model_sha256: event.model_sha256,
          started_at: mysqlToIso(event.started_at),
          completed_at: mysqlToIso(event.completed_at),
          result: event.result,
        }
      : null,
    analysis_runs_count: Number(event.analysis_runs_count),
    analysis_runs: analysisRuns,
    comparison,
    temperature_c: event.temperature_c,
    humidity_rh: event.humidity_rh,
    raw_file: event.sha256
      ? {
          available: Boolean(event.storage_path),
          media_type: event.media_type,
          byte_size: Number(event.byte_size),
          sha256: event.sha256,
        }
      : null,
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
    if (request.method === "POST" && parsedUrl.pathname === "/api/v1/admin/login") {
      await adminLogin(request, response);
      return;
    }
    if (request.method === "POST" && parsedUrl.pathname === "/api/v1/admin/logout") {
      await adminLogout(request, response);
      return;
    }
    if (request.method === "GET" && parsedUrl.pathname === "/api/v1/admin/audit") {
      await adminAudit(request, response);
      return;
    }
    const rawDownloadMatch = parsedUrl.pathname.match(
      /^\/api\/v1\/admin\/sources\/([0-9a-f-]{36})\/events\/([0-9a-f-]{36})\/raw$/i,
    );
    if (
      request.method === "GET" &&
      rawDownloadMatch &&
      isUuidV4(rawDownloadMatch[1]) &&
      isUuidV4(rawDownloadMatch[2])
    ) {
      await adminDownloadRaw(
        request,
        response,
        rawDownloadMatch[1].toLowerCase(),
        rawDownloadMatch[2].toLowerCase(),
      );
      return;
    }
    if (request.method === "POST" && parsedUrl.pathname === "/api/v1/admin/sources") {
      await adminCreateSource(request, response);
      return;
    }
    if (request.method === "GET" && parsedUrl.pathname === "/api/v1/admin/sources") {
      await adminListSources(request, response);
      return;
    }
    const sourceAdminMatch = parsedUrl.pathname.match(
      /^\/api\/v1\/admin\/sources\/([0-9a-f-]{36})(?:\/(keys))?$/,
    );
    if (sourceAdminMatch && isUuidV4(sourceAdminMatch[1])) {
      const sourceId = sourceAdminMatch[1].toLowerCase();
      if (request.method === "PATCH" && !sourceAdminMatch[2]) {
        await adminUpdateSource(request, response, sourceId);
        return;
      }
      if (request.method === "POST" && sourceAdminMatch[2] === "keys") {
        await adminRotateSourceKey(request, response, sourceId);
        return;
      }
    }
    const adminSourceEventsMatch = parsedUrl.pathname.match(
      /^\/api\/v1\/admin\/sources\/([0-9a-f-]{36})\/events$/i,
    );
    if (
      request.method === "GET" &&
      adminSourceEventsMatch &&
      isUuidV4(adminSourceEventsMatch[1])
    ) {
      await adminListSourceEvents(
        request,
        response,
        adminSourceEventsMatch[1].toLowerCase(),
      );
      return;
    }
    if (request.method === "POST" && parsedUrl.pathname === "/api/v1/admin/producers") {
      await adminCreateProducer(request, response);
      return;
    }
    if (request.method === "POST" && parsedUrl.pathname === "/api/v1/producer/login") {
      await producerLogin(request, response);
      return;
    }
    if (request.method === "POST" && parsedUrl.pathname === "/api/v1/producer/logout") {
      await producerLogout(request, response);
      return;
    }
    if (request.method === "GET" && parsedUrl.pathname === "/api/v1/producer/sources") {
      await producerSources(request, response);
      return;
    }
    const producerSourceEventsMatch = parsedUrl.pathname.match(
      /^\/api\/v1\/producer\/sources\/([0-9a-f-]{36})\/events$/i,
    );
    if (
      request.method === "GET" &&
      producerSourceEventsMatch &&
      isUuidV4(producerSourceEventsMatch[1])
    ) {
      const session = await authenticateProducer(request, response);
      if (!session) return;
      const sourceId = producerSourceEventsMatch[1].toLowerCase();
      const [assignment] = await pool.query(
        `SELECT 1 FROM producer_source_assignments
          WHERE producer_id = ? AND source_id = ? AND permission = 'read'`,
        [session.producer_id, sourceId],
      );
      if (assignment.length !== 1) {
        errorResponse(response, 404, "not_found", "Source not found");
        return;
      }
      await listSourceEvents(response, sourceId);
      return;
    }
    const producerEventMatch = parsedUrl.pathname.match(
      /^\/api\/v1\/producer\/sources\/([0-9a-f-]{36})\/events\/([0-9a-f-]{36})$/,
    );
    if (
      request.method === "GET" &&
      producerEventMatch &&
      isUuidV4(producerEventMatch[1]) &&
      isUuidV4(producerEventMatch[2])
    ) {
      const session = await authenticateProducer(request, response);
      if (!session) return;
      const [assignment] = await pool.query(
        `SELECT 1 FROM producer_source_assignments
          WHERE producer_id = ? AND source_id = ? AND permission = 'read'`,
        [session.producer_id, producerEventMatch[1].toLowerCase()],
      );
      if (assignment.length !== 1) {
        await audit("producer_access_denied", request, null, {
          source_id: producerEventMatch[1].toLowerCase(),
          event_id: producerEventMatch[2].toLowerCase(),
        });
        errorResponse(response, 404, "not_found", "Event not found");
        return;
      }
      await getEvent(
        request,
        response,
        producerEventMatch[1].toLowerCase(),
        producerEventMatch[2].toLowerCase(),
      );
      return;
    }
    const producerAssignmentMatch = parsedUrl.pathname.match(
      /^\/api\/v1\/admin\/producers\/([0-9a-f-]{36})\/sources$/,
    );
    if (
      request.method === "POST" &&
      producerAssignmentMatch &&
      isUuidV4(producerAssignmentMatch[1])
    ) {
      await adminAssignProducer(request, response, producerAssignmentMatch[1].toLowerCase());
      return;
    }
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
    if (isIngestion && await isMaintenanceActive()) {
      errorResponse(response, 503, "maintenance", "Ingestion is temporarily paused", {
        "retry-after": "60",
      });
      return;
    }
    if (isIngestion) {
      await ingestEvent(request, response, sourceId);
    } else if (isUuidV4(eventMatch[1])) {
      await getEvent(request, response, sourceId, eventMatch[1].toLowerCase());
    } else {
      errorResponse(response, 404, "not_found", "Event not found");
    }
  } catch (error) {
    console.error(JSON.stringify({ event: "request_failed", error: error.message }));
    const statusCode = error.statusCode ?? (error.code === "ER_DUP_ENTRY" ? 409 : 503);
    errorResponse(
      response,
      statusCode,
      statusCode === 503 ? "not_ready" : error.message,
      statusCode === 503 ? "Service is not ready" : "Invalid request",
    );
  }
});

async function start() {
  await migrate();
  server.listen(port, "0.0.0.0", () => {
    console.log(JSON.stringify({ event: "api_started", port }));
  });
}

start().catch((error) => {
  console.error(JSON.stringify({ event: "api_start_failed", error: error.message }));
  process.exit(1);
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
