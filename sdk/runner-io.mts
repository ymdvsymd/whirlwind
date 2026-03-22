import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
export const {
  nowTimestamp,
}: { nowTimestamp: () => string } = require("./now-timestamp.cjs");

export function stampEvent(event: unknown): unknown {
  if (event != null && typeof event === "object") {
    return { ...event, _whirlwind_ts: nowTimestamp() };
  }
  return event;
}

export function writeJsonl(
  event: unknown,
  stream: NodeJS.WritableStream = process.stdout,
): void {
  stream.write(`${JSON.stringify(event)}\n`);
}

export function createLogger(
  tag: string,
  stream: NodeJS.WritableStream = process.stderr,
): (message: string) => void {
  return function log(message: string): void {
    stream.write(`[${tag}] ${message}\n`);
  };
}

export function truncate(value: unknown, max = 80): string {
  return String(value || "").slice(0, max);
}

export function collapseWhitespace(value: unknown): string {
  return String(value || "")
    .replace(/\s+/g, " ")
    .trim();
}

export type ResultLogInfo = {
  subtype: string;
  costUsd?: number;
  durationMs?: number;
  inputTokens?: number;
  outputTokens?: number;
  cachedTokens?: number;
};

export function formatResultLog({
  subtype,
  costUsd,
  durationMs,
  inputTokens,
  outputTokens,
  cachedTokens,
}: ResultLogInfo): string {
  const parts = [`Result: ${subtype}`];
  if (costUsd) {
    parts.push(`cost=$${costUsd.toFixed(4)}`);
  }
  if (durationMs) {
    parts.push(`${(durationMs / 1000).toFixed(1)}s`);
  }
  if (inputTokens || outputTokens) {
    parts.push(`${inputTokens || 0}in/${outputTokens || 0}out`);
    if (cachedTokens) {
      parts.push(`cached=${cachedTokens}`);
    }
  }
  return parts.join(", ");
}
