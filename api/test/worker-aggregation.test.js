import test from "node:test";
import assert from "node:assert/strict";
import { updateAggregatedState } from "../src/worker-aggregation.js";

const aggregationConfig = {
  ruleVersion: "test-rule-1",
  confidenceThreshold: 0.8,
  consecutiveEvents: 1,
  maximumAgeMs: 7 * 24 * 60 * 60 * 1000,
  minimumAlertIntervalMs: 0,
  now: "2026-11-10T12:01:00.000Z",
};

function makeConnection(isTest) {
  const calls = [];
  return {
    calls,
    async query(sql, parameters = []) {
      calls.push({ sql, parameters });
      if (sql.includes("SELECT e.occurred_at")) {
        return [[{
          occurred_at: "2026-11-10 12:00:00.000",
          clock_suspect: false,
          crop: "mango",
          is_test: isTest,
          chat_id: "chat-1",
        }], []];
      }
      if (sql.includes("SELECT current_stage")) return [[], []];
      if (sql.includes("SELECT configuration")) return [[], []];
      return [{ affectedRows: 1 }, []];
    },
  };
}

async function updateState(connection, sourceId) {
  await updateAggregatedState(
    connection,
    { source_id: sourceId, event_id: "event-1", reprocessing: false },
    { classification: "maduro", confidence: 0.95 },
    aggregationConfig,
  );
}

test("persists test-source aggregation without inserting an alert", async () => {
  const connection = makeConnection(true);

  await updateState(connection, "test-source");

  assert.ok(connection.calls.some(({ sql }) => sql.includes("INSERT INTO monitoring_state_history")));
  assert.ok(connection.calls.some(({ sql }) => sql.includes("INSERT INTO aggregation_rule_versions")));
  const stateWrite = connection.calls.find(({ sql }) => sql.includes("INSERT INTO monitoring_states"));
  assert.ok(stateWrite);
  assert.ok(stateWrite.parameters.includes(aggregationConfig.ruleVersion));
  assert.equal(
    connection.calls.some(({ sql }) => sql.includes("INSERT IGNORE INTO monitoring_alerts")),
    false,
  );
});

test("preserves eligible alert insertion for normal sources", async () => {
  const connection = makeConnection(false);

  await updateState(connection, "normal-source");

  assert.ok(connection.calls.some(({ sql }) => sql.includes("INSERT IGNORE INTO monitoring_alerts")));
});