import { appendFileSync } from "node:fs";
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
export const { nowTimestamp, } = require("./now-timestamp.cjs");
export function stampEvent(event) {
    if (event != null && typeof event === "object") {
        return { ...event, _whirlwind_ts: nowTimestamp() };
    }
    return event;
}
export function writeJsonl(event, stream = process.stdout) {
    stream.write(`${JSON.stringify(event)}\n`);
}
export function createLogger(tag, stream = process.stderr) {
    return function log(message) {
        const line = `[${tag}] ${message}\n`;
        stream.write(line);
        const logFile = process.env.WHIRLWIND_LOG_FILE;
        if (logFile) {
            try {
                appendFileSync(logFile, line);
            }
            catch {
                // Silently ignore file write errors to avoid breaking the runner
            }
        }
    };
}
export function truncate(value, max = 80) {
    return String(value || "").slice(0, max);
}
export function collapseWhitespace(value) {
    return String(value || "")
        .replace(/\s+/g, " ")
        .trim();
}
export function formatResultLog({ subtype, costUsd, durationMs, inputTokens, outputTokens, cachedTokens, }) {
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
