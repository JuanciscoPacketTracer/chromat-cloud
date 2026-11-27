import test from "node:test";
import assert from "node:assert/strict";
import { readOfficialResult } from "../../web/public/app.js";

test("panel lee la clasificación oficial serializada por MariaDB o como objeto", () => {
  const result = { algorithm: "hsv", algorithm_version: "1", classification: "maduro", confidence: 0.8 };
  assert.deepEqual(readOfficialResult({ result: JSON.stringify(result) }), result);
  assert.deepEqual(readOfficialResult({ result }), result);
  assert.equal(readOfficialResult(null), null);
});

test("panel señala resultados oficiales inválidos en vez de llamarlos pendientes", () => {
  for (const result of ["{", "null", "[]", "{}", { classification: "" }]) {
    assert.throws(() => readOfficialResult({ result }), /resultado oficial/i);
  }
});
