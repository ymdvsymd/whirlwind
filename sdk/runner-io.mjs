function nowTimestamp() {
  const d = new Date();
  const h = String(d.getHours()).padStart(2, "0");
  const m = String(d.getMinutes()).padStart(2, "0");
  const s = String(d.getSeconds()).padStart(2, "0");
  return `${h}:${m}:${s}`;
}
export function stampEvent(event) {
  if (event != null && typeof event === "object") {
    return { ...event, _tornado_ts: nowTimestamp() };
  }
  return event;
}
export function writeJsonl(event, stream = process.stdout) {
  stream.write(`${JSON.stringify(event)}\n`);
}
export function createLogger(tag, stream = process.stderr) {
  return function log(message) {
    stream.write(`[${tag}] ${message}\n`);
  };
}
export function formatResultLog({
  subtype,
  costUsd,
  durationMs,
  inputTokens,
  outputTokens,
  cachedTokens,
}) {
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
