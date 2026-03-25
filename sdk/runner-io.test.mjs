import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

import { createLogger, formatResultLog } from "./runner-io.mjs";

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

// whirlwind-08x: createLogger writes to log file when WHIRLWIND_LOG_FILE is set
test("createLogger writes to log file when WHIRLWIND_LOG_FILE is set (whirlwind-08x)", () => {
  const logFile = path.join(os.tmpdir(), `whirlwind-test-${Date.now()}.log`);
  const origEnv = process.env.WHIRLWIND_LOG_FILE;
  try {
    process.env.WHIRLWIND_LOG_FILE = logFile;
    const stderrChunks = [];
    const fakeStderr = { write: (chunk) => stderrChunks.push(chunk) };
    const log = createLogger("Claude", fakeStderr);

    log("Task started: do something");
    log("Result: success");

    // Verify stderr still receives messages
    assert.equal(stderrChunks.length, 2);
    assert.match(stderrChunks[0], /\[Claude\] Task started: do something\n/);
    assert.match(stderrChunks[1], /\[Claude\] Result: success\n/);

    // Verify log file contains the same messages
    const content = fs.readFileSync(logFile, "utf-8");
    assert.match(content, /\[Claude\] Task started: do something/);
    assert.match(content, /\[Claude\] Result: success/);
  } finally {
    process.env.WHIRLWIND_LOG_FILE = origEnv || "";
    if (origEnv === undefined) delete process.env.WHIRLWIND_LOG_FILE;
    try {
      fs.unlinkSync(logFile);
    } catch {}
  }
});

// whirlwind-08x: createLogger does NOT write to file when WHIRLWIND_LOG_FILE is unset
test("createLogger does not write to file when WHIRLWIND_LOG_FILE is unset (whirlwind-08x)", () => {
  const origEnv = process.env.WHIRLWIND_LOG_FILE;
  try {
    delete process.env.WHIRLWIND_LOG_FILE;
    const stderrChunks = [];
    const fakeStderr = { write: (chunk) => stderrChunks.push(chunk) };
    const log = createLogger("Claude", fakeStderr);

    log("some message");

    // Stderr still works
    assert.equal(stderrChunks.length, 1);
    assert.match(stderrChunks[0], /\[Claude\] some message\n/);
  } finally {
    if (origEnv !== undefined) process.env.WHIRLWIND_LOG_FILE = origEnv;
  }
});
