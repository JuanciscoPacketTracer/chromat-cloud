import test from "node:test";
import assert from "node:assert/strict";
import { filterEvents, measurement, readOfficialResult, summarizeEvents } from "../../web/public/app.js";

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

test("mediciones opcionales distinguen cero, ausencia y valores no válidos", () => {
  assert.equal(measurement(0, "°C"), "0 °C");
  assert.equal(measurement(-3.25, "°C"), "-3.25 °C");
  assert.equal(measurement(72.5, "% HR"), "72.5 % HR");
  assert.equal(measurement(null, "°C"), "Sin medición");
  assert.equal(measurement(undefined, "% HR"), "Sin medición");
  for (const value of ["", "25", NaN, Infinity, {}]) {
    assert.equal(measurement(value, "°C"), "Medición no válida");
  }
});

test("resumen y filtros solo cuentan los eventos consultados sin alterar sus datos", () => {
  const events = [
    { event_id: "AB-1", status: "completed" }, { event_id: "ab-2", status: "pending" },
    { event_id: "cd-1", status: "processing" }, { event_id: "cd-2", status: "failed" },
  ];
  assert.deepEqual(summarizeEvents(events), { total: 4, completed: 1, waiting: 2, failed: 1 });
  assert.deepEqual(summarizeEvents([]), { total: 0, completed: 0, waiting: 0, failed: 0 });
  assert.deepEqual(filterEvents(events, "all", " AB-"), events.slice(0, 2));
  assert.deepEqual(filterEvents(events, "completed", "ab"), [events[0]]);
  assert.deepEqual(filterEvents(events, "failed", "ab"), []);
  assert.equal(events.length, 4);
});
