import { Codex } from "@openai/codex-sdk";
import {
  formatItemCompleteLog,
  formatItemStartLog,
  formatItemUpdateLog,
  getCodexItemId,
  formatTurnCompletedLog,
  formatTurnFailedLog,
  normalizeItemComplete,
  normalizeItemStart,
  normalizeTurnCompleted,
  normalizeTurnFailed,
} from "./codex-normalizer.mjs";
export function createCodexAdapter(deps = {}) {
  const lastItemLogs = new Map();
  return {
    tag: "Codex",
    async start(opts) {
      const codexClientOpts = opts.systemPrompt
        ? { config: { developer_instructions: opts.systemPrompt } }
        : undefined;
      const client = new (deps.CodexClient || Codex)(codexClientOpts);
      const threadOpts = {
        model: opts.model || undefined,
        workingDirectory: opts.cwd || process.cwd(),
        approvalPolicy: "never",
        sandboxMode: "workspace-write",
      };
      const { thread, log } = opts.threadId
        ? resumeThread(client, opts.threadId, threadOpts)
        : startThread(client, threadOpts);
      const logs = [log, `Thread: ${thread.id}`];
      const run = await thread.runStreamed(opts.prompt);
      return {
        sessionId: thread.id,
        initEvents: [
          {
            type: "system",
            subtype: "init",
            session_id: thread.id,
            model: opts.model || "default",
          },
        ],
        initLogs: logs,
        stream: run.events,
      };
    },
    emit(raw, sessionId) {
      switch (raw.type) {
        case "item.started":
          return emitItemStart(raw.item, lastItemLogs);
        case "item.updated":
          return emitItemUpdate(raw.item, lastItemLogs);
        case "item.completed":
          return emitItemComplete(raw.item, lastItemLogs);
        case "turn.started":
          return [{ log: "Turn started" }];
        case "turn.completed": {
          const resultEvent = normalizeTurnCompleted(raw, sessionId);
          return [{ event: resultEvent, log: formatTurnCompletedLog(raw) }];
        }
        case "turn.failed": {
          const errorEvent = normalizeTurnFailed(raw, sessionId);
          return [{ event: errorEvent, log: formatTurnFailedLog(raw) }];
        }
        case "error":
          return raw.message ? [{ log: `Error: ${raw.message}` }] : [];
        default:
          return [];
      }
    },
  };
}
function resumeThread(client, threadId, opts) {
  return {
    thread: client.resumeThread(threadId, opts),
    log: `Resuming thread: ${threadId}`,
  };
}
function startThread(client, opts) {
  return { thread: client.startThread(opts), log: "Starting new thread" };
}
function emitItemStart(item, lastItemLogs) {
  const normalized = normalizeItemStart(item || {});
  const display =
    typeof normalized?._display === "string"
      ? normalized._display
      : formatItemStartLog(item || {}) || item?.type || "item.started";
  return buildItemEmissions(item, normalized, display, lastItemLogs);
}
function emitItemUpdate(item, lastItemLogs) {
  const display = formatItemUpdateLog(item || {});
  return buildItemEmissions(item, undefined, display, lastItemLogs);
}
function emitItemComplete(item, lastItemLogs) {
  const normalized = normalizeItemComplete(item || {});
  const display =
    typeof normalized?._display === "string"
      ? normalized._display
      : formatItemCompleteLog(item || {}) || item?.type || "item.completed";
  const emissions = buildItemEmissions(
    item,
    normalized,
    display ? `Done: ${display}` : null,
    lastItemLogs,
  );
  const itemId = getCodexItemId(item || {});
  if (itemId) {
    lastItemLogs.delete(itemId);
  }
  return emissions;
}
function buildItemEmissions(item, event, log, lastItemLogs) {
  const emissions = [];
  if (event !== undefined) {
    emissions.push({ event });
  }
  const itemId = getCodexItemId(item || {});
  if (log) {
    if (!itemId || lastItemLogs.get(itemId) !== log) {
      emissions.push({ log });
      if (itemId) {
        lastItemLogs.set(itemId, log);
      }
    }
  }
  return emissions;
}
