import test from "node:test";
import assert from "node:assert/strict";
import { buildAlertCandidate } from "../src/alerts.js";

test("creates a pending maduro alert for a real-source transition", () => {
  const alert = buildAlertCandidate({
    sourceId: "source-1",
    crop: "mango",
    eventId: "event-1",
    occurredAt: "2026-11-08T22:00:00.000Z",
    transition: { fromStage: "verde", toStage: "maduro", episodeSeq: 2 },
    chatId: "12345",
    isTest: false,
  });

  assert.deepEqual(alert, {
    sourceId: "source-1",
    crop: "mango",
    eventId: "event-1",
    occurredAt: "2026-11-08T22:00:00.000Z",
    fromStage: "verde",
    toStage: "maduro",
    episodeSeq: 2,
    chatId: "12345",
    status: "pending",
  });
});

test("does not create alerts for a qualifying transition from a test source", () => {
  const transition = { fromStage: "verde", toStage: "maduro", episodeSeq: 3 };
  assert.equal(buildAlertCandidate({
    sourceId: "source-1",
    crop: "mango",
    eventId: "event-1",
    occurredAt: "2026-11-08T22:00:00.000Z",
    transition,
    chatId: "12345",
    isTest: true,
  }), null);
});

test("does not create alerts for other transitions", () => {
  const transition = { fromStage: "maduro", toStage: "otro", episodeSeq: 3 };
  assert.equal(buildAlertCandidate({
    sourceId: "source-1",
    crop: "mango",
    eventId: "event-1",
    occurredAt: "2026-11-08T22:00:00.000Z",
    transition,
    chatId: "12345",
    isTest: false,
  }), null);
});
