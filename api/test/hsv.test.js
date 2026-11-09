import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { PNG } from "pngjs";
import { classifyHsv } from "../src/hsv.js";

async function writePng(red, green, blue) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "chromat-hsv-"));
  const filePath = path.join(directory, "sample.png");
  const png = new PNG({ width: 1, height: 1 });
  png.data.set([red, green, blue, 255]);
  await fs.writeFile(filePath, PNG.sync.write(png));
  return filePath;
}

test("classifies a vivid yellow image as maduro with usable confidence", async () => {
  const filePath = await writePng(255, 128, 0);

  const result = await classifyHsv(filePath);

  assert.equal(result.classification, "maduro");
  assert.ok(result.confidence >= 0.8);
});

test("assigns low confidence to an uncertain image", async () => {
  const filePath = await writePng(128, 128, 128);

  const result = await classifyHsv(filePath);

  assert.equal(result.classification, "uncertain");
  assert.ok(result.confidence < 0.8);
});
