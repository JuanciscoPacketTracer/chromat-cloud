import test from "node:test";
import assert from "node:assert/strict";
import {
  buildTelegramMessage,
  classifyTelegramResponse,
} from "../src/telegram.js";

test("formats the alert without credentials or images", () => {
  const message = buildTelegramMessage({
    sourceName: "Invernadero norte",
    crop: "mango",
    eventId: "event-1",
    fromStage: "verde",
    toStage: "maduro",
    occurredAt: "2026-11-08T22:00:00.000Z",
    panelUrl: "https://chromat.lan/panel/",
  });

  assert.match(message, /Invernadero norte/);
  assert.match(message, /mango/);
  assert.match(message, /verde.*maduro/s);
  assert.match(message, /event-1/);
  assert.match(message, /https:\/\/chromat\.lan\/panel\//);
  assert.doesNotMatch(message, /token|image|password/i);
});

test("classifies Telegram retry and permanent responses", () => {
  assert.deepEqual(classifyTelegramResponse(200, { ok: true }), { kind: "sent" });
  assert.deepEqual(
    classifyTelegramResponse(429, { ok: false, parameters: { retry_after: 17 } }),
    { kind: "retry", retryAfterSeconds: 17, error: "telegram_rate_limited" },
  );
  assert.deepEqual(
    classifyTelegramResponse(400, { ok: false, description: "chat not found" }),
    { kind: "permanent", error: "chat not found" },
  );
});
