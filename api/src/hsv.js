import fs from "node:fs/promises";
import jpeg from "jpeg-js";
import { PNG } from "pngjs";

function rgbToHsv(red, green, blue) {
  const r = red / 255;
  const g = green / 255;
  const b = blue / 255;
  const max = Math.max(r, g, b);
  const min = Math.min(r, g, b);
  const delta = max - min;
  let hue = 0;

  if (delta !== 0) {
    if (max === r) hue = 60 * (((g - b) / delta) % 6);
    else if (max === g) hue = 60 * ((b - r) / delta + 2);
    else hue = 60 * ((r - g) / delta + 4);
  }
  if (hue < 0) hue += 360;
  return { hue, saturation: max === 0 ? 0 : delta / max, value: max };
}

function averageHsv(data) {
  let red = 0;
  let green = 0;
  let blue = 0;
  const pixels = data.length / 4;
  for (let index = 0; index < data.length; index += 4) {
    red += data[index];
    green += data[index + 1];
    blue += data[index + 2];
  }
  return rgbToHsv(red / pixels, green / pixels, blue / pixels);
}

function classify(hsv) {
  if (hsv.saturation < 0.2 || hsv.value < 0.15) return "uncertain";
  if (hsv.hue >= 35 && hsv.hue < 95) return "green";
  if (hsv.hue >= 15 && hsv.hue < 35) return "yellow";
  return "other";
}

export async function classifyHsv(filePath) {
  const bytes = await fs.readFile(filePath);
  let hsv;
  try {
    if (bytes.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))) {
      hsv = averageHsv(PNG.sync.read(bytes).data);
    } else {
      hsv = averageHsv(jpeg.decode(bytes, { useTArray: true }).data);
    }
  } catch {
    throw Object.assign(new Error("invalid_image"), { permanent: true });
  }

  return {
    algorithm: "hsv",
    algorithm_version: "1",
    hue: Number(hsv.hue.toFixed(4)),
    saturation: Number(hsv.saturation.toFixed(4)),
    value: Number(hsv.value.toFixed(4)),
    classification: classify(hsv),
    confidence: 1,
  };
}
