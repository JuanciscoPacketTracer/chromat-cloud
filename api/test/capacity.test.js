import test from "node:test";
import assert from "node:assert/strict";
import { isBelowFreeSpaceThreshold } from "../src/capacity.js";

test("detects when free storage is below the ingestion threshold", () => {
  assert.equal(
    isBelowFreeSpaceThreshold({ availableBytes: 19, totalBytes: 100 }, 20),
    true,
  );
  assert.equal(
    isBelowFreeSpaceThreshold({ availableBytes: 20, totalBytes: 100 }, 20),
    false,
  );
});
