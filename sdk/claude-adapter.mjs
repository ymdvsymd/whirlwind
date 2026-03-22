import { query } from "@anthropic-ai/claude-agent-sdk";
import { formatResultLog } from "./runner-io.mjs";
export function createClaudeAdapter() {
  return {
    tag: "Claude",
    async start(opts) {
      const queryOpts = buildQueryOptions(opts);
      return {
        sessionId: opts.sessionId || "",
        stream: query({
          prompt: opts.prompt,
          options: queryOpts,
        }),
      };
    },
    emit(raw) {
      const emissions = [{ event: raw }];
      const logs = extractLogs(raw);
      for (const line of logs) {
        emissions.push({ log: line });
      }
      return emissions;
    },
  };
}
function buildQueryOptions(opts) {
  const queryOptions = {
    includePartialMessages: true,
    permissionMode: "bypassPermissions",
    allowDangerouslySkipPermissions: true,
    cwd: opts.cwd || process.cwd(),
  };
  if (opts.sessionId) queryOptions.resume = opts.sessionId;
  if (opts.model) queryOptions.model = opts.model;
  if (opts.systemPrompt) queryOptions.systemPrompt = opts.systemPrompt;
  return queryOptions;
}
function extractLogs(message) {
  switch (message.type) {
    case "system":
      return extractSystemLog(message);
    case "stream_event":
      return extractStreamEventLog(message);
    case "assistant":
      return extractToolUseLog(message);
    case "result":
      return [claudeResultLog(message)];
    default:
      return [];
  }
}
function extractSystemLog(message) {
  if (message.subtype !== "init") return [];
  return [
    `Session init: model=${message.model || "unknown"}, session=${message.session_id || "new"}`,
  ];
}
function extractStreamEventLog(message) {
  const event = message.event;
  if (event?.type !== "content_block_start") return [];
  const block = event.content_block;
  if (block?.type === "tool_use") {
    return [`Tool: ${block.name}`];
  }
  if (block?.type === "thinking") {
    return ["Thinking..."];
  }
  if (block?.type === "text") {
    return ["Generating..."];
  }
  return [];
}
function extractToolUseLog(message) {
  const logs = [];
  const content = message.message?.content;
  if (!Array.isArray(content)) return logs;
  for (const block of content) {
    if (block.type !== "tool_use") continue;
    const inputPreview = JSON.stringify(block.input).slice(0, 100);
    logs.push(`${block.name}(${inputPreview})`);
  }
  return logs;
}
function claudeResultLog(message) {
  return formatResultLog({
    subtype: message.subtype || "unknown",
    costUsd: message.total_cost_usd,
    durationMs: message.duration_ms,
    inputTokens: message.usage?.input_tokens,
    outputTokens: message.usage?.output_tokens,
  });
}
