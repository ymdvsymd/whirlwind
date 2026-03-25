import { query as sdkQuery } from "@anthropic-ai/claude-agent-sdk";
import { spawn } from "node:child_process";
import { truncate, collapseWhitespace } from "./runner-io.mjs";
const DEFAULT_QUERY_TIMEOUT_MS = 30_000;
export function createClaudeAdapter(deps = {}) {
  const state = {
    lastStatus: undefined,
    lastToolProgressById: new Map(),
    streamBlocks: new Map(),
  };
  const queryFn = deps.queryFn || ((opts) => sdkQuery(opts));
  const cliFallbackFn = deps.cliFallbackFn || defaultCliFallback;
  const timeoutMs = deps.queryTimeoutMs ?? DEFAULT_QUERY_TIMEOUT_MS;
  return {
    tag: "Claude",
    async start(opts) {
      const queryOpts = buildQueryOptions(opts);
      debugClaude(
        `start: cwd=${String(queryOpts.cwd || process.cwd())} model=${opts.model || "default"} resume=${opts.sessionId || "new"}`,
      );
      debugClaude("start: calling query() with timeout detection");
      const { stream, usedFallback } = await startWithTimeout(
        queryFn,
        cliFallbackFn,
        opts,
        queryOpts,
        timeoutMs,
      );
      const initLogs = [];
      if (usedFallback) {
        initLogs.push(
          `SDK query() timed out after ${timeoutMs}ms, falling back to CLI streaming`,
        );
      }
      debugClaude(`start: stream ready (fallback=${String(usedFallback)})`);
      return {
        sessionId: opts.sessionId || "",
        stream: withClaudeDebugStream(stream),
        initLogs: initLogs.length > 0 ? initLogs : undefined,
      };
    },
    emit(raw) {
      const emissions = [{ event: raw }];
      const logs = extractLogs(raw, state);
      for (const line of logs) {
        emissions.push({ log: line });
      }
      return emissions;
    },
  };
}
const claudeDebugEnabled = process.env.WHIRLWIND_DEBUG_CLAUDE === "1";
function withClaudeDebugStream(stream) {
  if (!claudeDebugEnabled) return stream;
  return {
    async *[Symbol.asyncIterator]() {
      let index = 0;
      debugClaude("stream: awaiting first event");
      for await (const item of stream) {
        index += 1;
        const summary =
          typeof item?.type === "string"
            ? item.type +
              (typeof item?.subtype === "string" ? `/${item.subtype}` : "")
            : "unknown";
        debugClaude(`stream: received event #${index} (${summary})`);
        yield item;
      }
      debugClaude(`stream: completed after ${index} events`);
    },
  };
}
function debugClaude(message) {
  if (!claudeDebugEnabled) return;
  process.stderr.write(`[ClaudeAdapterDebug] ${message}\n`);
}
async function startWithTimeout(
  queryFn,
  cliFallbackFn,
  opts,
  queryOpts,
  timeoutMs,
) {
  debugClaude("startWithTimeout: creating SDK stream");
  const sdkStream = queryFn({ prompt: opts.prompt, options: queryOpts });
  const iterator = sdkStream[Symbol.asyncIterator]();
  const firstResult = await raceFirstEvent(iterator, timeoutMs);
  if (firstResult.timedOut) {
    const reason = firstResult.error
      ? `SDK error: ${firstResult.error}`
      : `timeout after ${timeoutMs}ms`;
    debugClaude(`startWithTimeout: ${reason}, switching to CLI fallback`);
    if (typeof iterator.return === "function") {
      iterator.return(undefined).catch((err) => {
        debugClaude(`startWithTimeout: iterator cleanup failed: ${err}`);
      });
    }
    const fallbackStream = cliFallbackFn(opts, queryOpts);
    return { stream: fallbackStream, usedFallback: true };
  }
  debugClaude("startWithTimeout: first event received from SDK stream");
  const stream = prependEvent(firstResult.value, iterator);
  return { stream, usedFallback: false };
}
async function raceFirstEvent(iterator, timeoutMs) {
  return new Promise((resolve) => {
    let settled = false;
    const timer = setTimeout(() => {
      if (!settled) {
        settled = true;
        resolve({ timedOut: true });
      }
    }, timeoutMs);
    iterator
      .next()
      .then((result) => {
        if (!settled) {
          settled = true;
          clearTimeout(timer);
          if (result.done) {
            // Stream ended immediately with no events — treat as success (empty stream)
            resolve({ timedOut: false, value: undefined });
          } else {
            resolve({ timedOut: false, value: result.value });
          }
        }
      })
      .catch((err) => {
        if (!settled) {
          settled = true;
          clearTimeout(timer);
          debugClaude(`raceFirstEvent: SDK query() threw: ${err}`);
          resolve({ timedOut: true, error: err });
        }
      });
  });
}
async function* prependEvent(first, iterator) {
  if (first !== undefined) {
    yield first;
  }
  while (true) {
    const result = await iterator.next();
    if (result.done) break;
    yield result.value;
  }
}
function defaultCliFallback(opts, queryOpts) {
  const args = ["-p", opts.prompt, "--output-format", "stream-json"];
  if (opts.model) {
    args.push("--model", opts.model);
  }
  if (opts.sessionId) {
    args.push("--resume", opts.sessionId);
  }
  if (opts.systemPrompt) {
    args.push("--system-prompt", opts.systemPrompt);
  }
  if (queryOpts.allowDangerouslySkipPermissions) {
    args.push("--dangerously-skip-permissions");
  }
  const cwd = queryOpts.cwd;
  debugClaude(`CLI fallback: claude ${args.join(" ")}`);
  const child = spawn("claude", args, {
    cwd,
    stdio: ["ignore", "pipe", "ignore"],
  });
  return {
    async *[Symbol.asyncIterator]() {
      try {
        let buffer = "";
        const stdout = child.stdout;
        for await (const chunk of stdout) {
          buffer += chunk.toString();
          const lines = buffer.split("\n");
          buffer = lines.pop();
          for (const line of lines) {
            const trimmed = line.trim();
            if (!trimmed) continue;
            try {
              yield JSON.parse(trimmed);
            } catch {
              // Skip non-JSON lines
            }
          }
        }
        if (buffer.trim()) {
          try {
            yield JSON.parse(buffer.trim());
          } catch {
            // Skip non-JSON trailing content
          }
        }
        await new Promise((resolve) => {
          child.on("close", () => resolve());
        });
      } finally {
        if (!child.killed) {
          child.kill();
        }
      }
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
function extractLogs(message, state) {
  switch (message.type) {
    case "system":
      return extractSystemLog(message, state);
    case "stream_event":
      return extractStreamEventLog(message, state);
    case "assistant":
      return extractToolUseLog(message);
    case "tool_progress":
      return extractToolProgressLog(message, state);
    case "tool_use_summary":
      return extractToolUseSummaryLog(message);
    case "result":
      state.lastToolProgressById.clear();
      return [formatResultLog(message)];
    default:
      return [];
  }
}
function extractSystemLog(message, state) {
  switch (message.subtype) {
    case "init":
      return [
        `Session init: model=${message.model || "unknown"}, session=${message.session_id || "new"}`,
      ];
    case "status":
      return extractStatusLog(message, state);
    case "task_started":
      return [formatTaskStartedLog(message)];
    case "task_notification":
      return [formatTaskNotificationLog(message)];
    default:
      return [];
  }
}
function extractStreamEventLog(message, state) {
  const event = message.event;
  if (!event?.type) return [];
  switch (event.type) {
    case "content_block_start":
      return extractContentBlockStartLog(event, state);
    case "content_block_delta":
      return extractContentBlockDeltaLog(event, state);
    case "content_block_stop":
      return extractContentBlockStopLog(event, state);
    default:
      return [];
  }
}
function extractContentBlockStartLog(event, state) {
  const block = event.content_block;
  if (!block?.type) return [];
  const index = typeof event.index === "number" ? event.index : undefined;
  const streamBlock = createStreamBlockState(block);
  if (index !== undefined) {
    state.streamBlocks.set(index, streamBlock);
  }
  if (block.type === "tool_use") {
    const toolName = block.name || "unknown";
    const summary = summarizeToolInputForProgress(toolName, block.input);
    if (summary) {
      streamBlock.lastToolSummary = summary;
      return [`Tool: ${toolName}(${summary})`];
    }
    return [`Tool: ${toolName}`];
  }
  if (block.type === "thinking" || block.type === "text") {
    return emitTextProgressLog(streamBlock, block.type, true);
  }
  return [];
}
function extractContentBlockDeltaLog(event, state) {
  if (typeof event.index !== "number") return [];
  const block = state.streamBlocks.get(event.index);
  const delta = event.delta;
  if (!block || !delta?.type) return [];
  switch (delta.type) {
    case "thinking_delta":
      if (block.kind !== "thinking" || typeof delta.thinking !== "string") {
        return [];
      }
      block.text += delta.thinking;
      return emitTextProgressLog(block, "thinking");
    case "text_delta":
      if (block.kind !== "text" || typeof delta.text !== "string") {
        return [];
      }
      block.text += delta.text;
      return emitTextProgressLog(block, "text");
    case "input_json_delta":
      if (block.kind !== "tool_use" || typeof delta.partial_json !== "string") {
        return [];
      }
      block.json += delta.partial_json;
      return emitToolInputProgressLog(block);
    default:
      return [];
  }
}
function extractContentBlockStopLog(event, state) {
  if (typeof event.index !== "number") return [];
  const block = state.streamBlocks.get(event.index);
  if (!block) return [];
  state.streamBlocks.delete(event.index);
  if (block.kind === "thinking" || block.kind === "text") {
    return emitTextProgressLog(block, block.kind, true);
  }
  if (block.kind === "tool_use") {
    return emitToolInputProgressLog(block);
  }
  return [];
}
function createStreamBlockState(block) {
  return {
    kind: block.type || "",
    toolName: block.name || "",
    text: initialBlockText(block),
    json: "",
    lastPreview: "",
    lastToolSummary: "",
  };
}
function initialBlockText(block) {
  if (block.type === "thinking" && typeof block.thinking === "string") {
    return block.thinking;
  }
  if (block.type === "text" && typeof block.text === "string") {
    return block.text;
  }
  return "";
}
function emitTextProgressLog(block, kind, force = false) {
  const fullPreview = collapseWhitespace(block.text);
  if (!fullPreview) {
    return [];
  }
  const preview = force ? fullPreview : extractStableTextPreview(fullPreview);
  const display = extractTextProgressDelta(block.lastPreview, preview);
  if (!preview || !display) {
    return [];
  }
  if (!force && !shouldEmitTextProgress(block.lastPreview, preview)) {
    return [];
  }
  block.lastPreview = preview;
  const label = kind === "thinking" ? "Thinking" : "Generating";
  return [`${label}: ${truncate(display, 160)}`];
}
function extractTextProgressDelta(previous, next) {
  if (!next || next === previous) {
    return "";
  }
  if (!previous) {
    return next;
  }
  if (next.startsWith(previous)) {
    return next.slice(previous.length).trim();
  }
  return next;
}
function extractStableTextPreview(value) {
  const end = lastSentenceBoundary(value);
  if (end <= 0) return "";
  return value.slice(0, end).trim();
}
function lastSentenceBoundary(value) {
  for (let i = value.length - 1; i >= 0; i -= 1) {
    const ch = value[i];
    if (
      ch === "." ||
      ch === "!" ||
      ch === "?" ||
      ch === "。" ||
      ch === "！" ||
      ch === "？"
    ) {
      return i + 1;
    }
  }
  return 0;
}
function emitToolInputProgressLog(block) {
  const summary = summarizeToolJsonBuffer(block.toolName, block.json);
  if (!summary || summary === block.lastToolSummary) {
    return [];
  }
  block.lastToolSummary = summary;
  return [`Tool: ${block.toolName || "unknown"}(${summary})`];
}
function shouldEmitTextProgress(previous, next) {
  if (!previous) {
    return next.length >= 24 || hasSentenceBoundary(next);
  }
  const suffix = next.startsWith(previous) ? next.slice(previous.length) : next;
  return next.length - previous.length >= 48 || hasSentenceBoundary(suffix);
}
function hasSentenceBoundary(value) {
  return /[.!?。！？\n]/.test(value);
}
function summarizeToolJsonBuffer(toolName, json) {
  const parsed = parseJsonBuffer(json);
  if (parsed === undefined) return "";
  return summarizeToolInputForProgress(toolName, parsed);
}
function parseJsonBuffer(json) {
  const trimmed = json.trim();
  if (!trimmed) return undefined;
  try {
    return JSON.parse(trimmed);
  } catch {
    return undefined;
  }
}
function extractToolUseLog(message) {
  const logs = [];
  const content = message.message?.content;
  if (!Array.isArray(content)) return logs;
  for (const block of content) {
    if (block.type !== "tool_use") continue;
    const inputPreview = summarizeToolInput(block.name, block.input);
    logs.push(`${block.name}(${inputPreview})`);
  }
  return logs;
}
function extractStatusLog(message, state) {
  const nextStatus =
    message.status === null
      ? null
      : typeof message.status === "string"
        ? message.status
        : undefined;
  if (nextStatus === undefined || nextStatus === state.lastStatus) {
    return [];
  }
  state.lastStatus = nextStatus;
  if (nextStatus === null) {
    return ["Status: ready"];
  }
  return [`Status: ${nextStatus}`];
}
function extractToolProgressLog(message, state) {
  const elapsed = Math.floor(Number(message.elapsed_time_seconds || 0));
  if (elapsed <= 0) return [];
  const progressKey =
    message.tool_use_id || message.task_id || message.tool_name || "";
  const previous = state.lastToolProgressById.get(progressKey);
  if (!shouldEmitToolProgress(previous, elapsed)) {
    return [];
  }
  state.lastToolProgressById.set(progressKey, elapsed);
  return [`Tool progress: ${message.tool_name || "tool"} ${elapsed}s`];
}
function shouldEmitToolProgress(previous, elapsed) {
  if (previous === elapsed) return false;
  if (elapsed <= 2) return true;
  return elapsed % 5 === 0;
}
function extractToolUseSummaryLog(message) {
  const summary = collapseWhitespace(message.summary || "");
  if (!summary) return [];
  return [`Summary: ${truncate(summary, 120)}`];
}
function formatTaskStartedLog(message) {
  const taskId = message.task_id || "?";
  const desc = collapseWhitespace(message.description || "");
  const taskType = collapseWhitespace(message.task_type || "");
  const label = taskType ? `${taskType}/${taskId}` : taskId;
  return `Task started [${label}]: ${truncate(desc || "started", 120)}`;
}
function formatTaskNotificationLog(message) {
  const taskId = message.task_id || "?";
  const status = collapseWhitespace(message.status || "completed");
  const summary = collapseWhitespace(message.summary || "");
  if (summary) {
    return `Task ${status} [${taskId}]: ${truncate(summary, 120)}`;
  }
  return `Task ${status} [${taskId}]`;
}
function summarizeToolInput(toolName, input) {
  if (isRecord(input)) {
    if (toolName == "Task") {
      const subagent = firstString(input, ["subagent_type", "agent_type"]);
      const description = firstString(input, ["description", "prompt", "task"]);
      if (subagent && description) {
        return truncate(`${subagent}: ${description}`, 120);
      }
      if (description) return truncate(description, 120);
      if (subagent) return truncate(subagent, 120);
    }
    const command = firstString(input, ["command", "cmd"]);
    if (command) return truncate(command, 120);
    const path = firstString(input, ["file_path", "path"]);
    const pattern = firstString(input, ["pattern"]);
    const query = firstString(input, ["query", "q"]);
    const url = firstString(input, ["url"]);
    const description = firstString(input, ["description"]);
    if (path && pattern) return truncate(`${pattern} @ ${path}`, 120);
    if (path) return truncate(path, 120);
    if (pattern) return truncate(pattern, 120);
    if (query) return truncate(query, 120);
    if (url) return truncate(url, 120);
    if (description) return truncate(description, 120);
  }
  return truncate(JSON.stringify(input), 120);
}
function summarizeToolInputForProgress(toolName, input) {
  if (isRecord(input) && Object.keys(input).length === 0) {
    return "";
  }
  const summary = summarizeToolInput(toolName, input);
  if (summary === "{}" || summary === "[]" || summary === "null") {
    return "";
  }
  return summary;
}
function firstString(input, keys) {
  for (const key of keys) {
    const value = input[key];
    if (typeof value === "string" && collapseWhitespace(value)) {
      return collapseWhitespace(value);
    }
  }
  return "";
}
function isRecord(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
function formatResultLog(message) {
  const parts = [`Result: ${message.subtype}`];
  if (message.total_cost_usd) {
    parts.push(`cost=$${message.total_cost_usd.toFixed(4)}`);
  }
  if (message.duration_ms) {
    parts.push(`${(message.duration_ms / 1000).toFixed(1)}s`);
  }
  if (message.usage) {
    const { input_tokens, output_tokens } = message.usage;
    if (input_tokens || output_tokens) {
      parts.push(`${input_tokens || 0}in/${output_tokens || 0}out`);
    }
  }
  return parts.join(", ");
}
