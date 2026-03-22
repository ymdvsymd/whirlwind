import test from "node:test";
import assert from "node:assert/strict";

import { formatResultLog } from "./runner-io.mjs";

test("formatResultLog with subtype only", () => {
  const result = formatResultLog({ subtype: "success" });
  assert.equal(result, "Result: success");
});

test("formatResultLog with cost and duration", () => {
  const result = formatResultLog({
    subtype: "success",
    costUsd: 0.0123,
    durationMs: 4500,
  });
  assert.equal(result, "Result: success, cost=$0.0123, 4.5s");
});

test("formatResultLog with token usage", () => {
  const result = formatResultLog({
    subtype: "success",
    inputTokens: 100,
    outputTokens: 50,
  });
  assert.equal(result, "Result: success, 100in/50out");
});

test("formatResultLog with cached tokens", () => {
  const result = formatResultLog({
    subtype: "success",
    inputTokens: 100,
    outputTokens: 50,
    cachedTokens: 80,
  });
  assert.equal(result, "Result: success, 100in/50out, cached=80");
});

test("formatResultLog with all fields", () => {
  const result = formatResultLog({
    subtype: "error",
    costUsd: 0.05,
    durationMs: 12000,
    inputTokens: 200,
    outputTokens: 100,
    cachedTokens: 150,
  });
  assert.equal(
    result,
    "Result: error, cost=$0.0500, 12.0s, 200in/100out, cached=150",
  );
});

test("formatResultLog omits zero-value optional fields", () => {
  const result = formatResultLog({
    subtype: "success",
    costUsd: 0,
    durationMs: 0,
    inputTokens: 0,
    outputTokens: 0,
    cachedTokens: 0,
  });
  assert.equal(result, "Result: success");
});
