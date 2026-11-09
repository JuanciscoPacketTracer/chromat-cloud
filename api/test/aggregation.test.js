import test from "node:test";
import assert from "node:assert/strict";
import { applyObservation } from "../src/aggregation.js";

const config = {
  confidenceThreshold: 0.8,
  consecutiveEvents: 2,
  maximumAgeMs: 7 * 24 * 60 * 60 * 1000,
  now: "2026-11-08T20:00:00.000Z",
};

test("enters a stage after the configured consecutive observations", () => {
  let state = {};
  state = applyObservation(state, {
    classification: "maduro",
    confidence: 0.9,
    occurredAt: "2026-11-08T19:58:00.000Z",
  }, config).state;
  const result = applyObservation(state, {
    classification: "maduro",
    confidence: 0.95,
    occurredAt: "2026-11-08T19:59:00.000Z",
  }, config);

  assert.equal(result.transition.fromStage, null);
  assert.equal(result.transition.toStage, "maduro");
  assert.equal(result.state.episodeSeq, 1);
  assert.equal(result.state.historyEntry.currentStage, "maduro");
  assert.equal(result.state.historyEntry.episodeSeq, 1);
});

test("records each accepted observation for the aggregated history", () => {
  const result = applyObservation({}, {
    classification: "maduro",
    confidence: 0.9,
    occurredAt: "2026-11-08T19:58:00.000Z",
  }, { ...config, consecutiveEvents: 2 });

  assert.deepEqual(result.state.historyEntry, {
    classification: "maduro",
    confidence: 0.9,
    occurredAt: "2026-11-08T19:58:00.000Z",
    consecutiveStage: "maduro",
    consecutiveCount: 1,
    currentStage: null,
    episodeSeq: 0,
    transition: null,
  });
});

test("starts a new episode after leaving and re-entering a stage", () => {
  let state = {
    currentStage: "maduro",
    episodeSeq: 1,
    lastOccurredAt: "2026-11-08T19:00:00.000Z",
  };
  state = applyObservation(state, {
    classification: "verde",
    confidence: 0.9,
    occurredAt: "2026-11-08T19:10:00.000Z",
  }, { ...config, consecutiveEvents: 1 }).state;
  const result = applyObservation(state, {
    classification: "maduro",
    confidence: 0.9,
    occurredAt: "2026-11-08T19:20:00.000Z",
  }, { ...config, consecutiveEvents: 1 });

  assert.equal(result.transition.toStage, "maduro");
  assert.equal(result.state.episodeSeq, 3);
});

test("ignores suspicious, stale, and out-of-order observations", () => {
  const state = {
    currentStage: "verde",
    episodeSeq: 1,
    lastOccurredAt: "2026-11-08T19:00:00.000Z",
  };
  for (const observation of [
    {
      classification: "maduro",
      confidence: 0.99,
      occurredAt: "2026-11-08T18:59:00.000Z",
    },
    {
      classification: "maduro",
      confidence: 0.99,
      occurredAt: "2026-11-08T19:30:00.000Z",
      clockSuspect: true,
    },
    {
      classification: "maduro",
      confidence: 0.99,
      occurredAt: "2026-10-01T19:30:00.000Z",
    },
  ]) {
    const result = applyObservation(state, observation, config);
    assert.equal(result.accepted, false);
    assert.deepEqual(result.state, state);
  }
});
