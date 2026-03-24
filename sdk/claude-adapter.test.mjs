import test from "node:test";
import assert from "node:assert/strict";

import { createClaudeAdapter } from "./claude-adapter.mjs";

test("createClaudeAdapter emits structured progress logs for Claude task lifecycle", () => {
  const adapter = createClaudeAdapter();

  const statusLogs = logsOf(
    adapter.emit({
      type: "system",
      subtype: "status",
      status: "compacting",
      session_id: "s-1",
    }),
  );
  assert.deepEqual(statusLogs, ["Status: compacting"]);

  const taskStartLogs = logsOf(
    adapter.emit({
      type: "system",
      subtype: "task_started",
      task_id: "task-1",
      task_type: "Explore",
      description: "scan the repository for agent event handlers",
      session_id: "s-1",
    }),
  );
  assert.deepEqual(taskStartLogs, [
    "Task started [Explore/task-1]: scan the repository for agent event handlers",
  ]);

  const taskDoneLogs = logsOf(
    adapter.emit({
      type: "system",
      subtype: "task_notification",
      task_id: "task-1",
      status: "completed",
      summary: "identified Claude/Codex adapter bottlenecks",
      session_id: "s-1",
    }),
  );
  assert.deepEqual(taskDoneLogs, [
    "Task completed [task-1]: identified Claude/Codex adapter bottlenecks",
  ]);
});

test("createClaudeAdapter summarizes tool input and throttles tool progress noise", () => {
  const adapter = createClaudeAdapter();

  const toolLogs = logsOf(
    adapter.emit({
      type: "assistant",
      message: {
        content: [
          {
            type: "tool_use",
            name: "Bash",
            input: { command: "npm test -- --watch=false" },
          },
          {
            type: "tool_use",
            name: "Task",
            input: {
              subagent_type: "Explore",
              description: "inspect codex item.updated events",
            },
          },
        ],
      },
      session_id: "s-1",
    }),
  );
  assert.deepEqual(toolLogs, [
    "Bash(npm test -- --watch=false)",
    "Task(Explore: inspect codex item.updated events)",
  ]);

  const progress1 = logsOf(
    adapter.emit({
      type: "tool_progress",
      tool_use_id: "tool-1",
      tool_name: "Bash",
      elapsed_time_seconds: 1,
      session_id: "s-1",
    }),
  );
  assert.deepEqual(progress1, ["Tool progress: Bash 1s"]);

  const progress3 = logsOf(
    adapter.emit({
      type: "tool_progress",
      tool_use_id: "tool-1",
      tool_name: "Bash",
      elapsed_time_seconds: 3,
      session_id: "s-1",
    }),
  );
  assert.deepEqual(progress3, []);

  const progress5 = logsOf(
    adapter.emit({
      type: "tool_progress",
      tool_use_id: "tool-1",
      tool_name: "Bash",
      elapsed_time_seconds: 5,
      session_id: "s-1",
    }),
  );
  assert.deepEqual(progress5, ["Tool progress: Bash 5s"]);
});

test("createClaudeAdapter emits detailed stream logs for thinking, generating, and Task input", () => {
  const adapter = createClaudeAdapter();

  const thinkingStart = logsOf(
    adapter.emit({
      type: "stream_event",
      event: {
        type: "content_block_start",
        index: 0,
        content_block: { type: "thinking" },
      },
      session_id: "s-1",
    }),
  );
  assert.deepEqual(thinkingStart, []);

  const thinkingDelta = logsOf(
    adapter.emit({
      type: "stream_event",
      event: {
        type: "content_block_delta",
        index: 0,
        delta: {
          type: "thinking_delta",
          thinking: "Analyzing packed u8 migration impact.",
        },
      },
      session_id: "s-1",
    }),
  );
  assert.deepEqual(thinkingDelta, [
    "Thinking: Analyzing packed u8 migration impact.",
  ]);

  const textDelta = logsOf(
    adapter.emit({
      type: "stream_event",
      event: {
        type: "content_block_start",
        index: 1,
        content_block: { type: "text" },
      },
      session_id: "s-1",
    }),
  ).concat(
    logsOf(
      adapter.emit({
        type: "stream_event",
        event: {
          type: "content_block_delta",
          index: 1,
          delta: {
            type: "text_delta",
            text: "検証は通りました。最後に変更点をまとめます。",
          },
        },
        session_id: "s-1",
      }),
    ),
  );
  assert.deepEqual(textDelta, [
    "Generating: 検証は通りました。最後に変更点をまとめます。",
  ]);

  const taskStart = logsOf(
    adapter.emit({
      type: "stream_event",
      event: {
        type: "content_block_start",
        index: 2,
        content_block: { type: "tool_use", name: "Task" },
      },
      session_id: "s-1",
    }),
  );
  assert.deepEqual(taskStart, ["Tool: Task"]);

  const taskDelta1 = logsOf(
    adapter.emit({
      type: "stream_event",
      event: {
        type: "content_block_delta",
        index: 2,
        delta: {
          type: "input_json_delta",
          partial_json: '{"subagent_type":"Explore"',
        },
      },
      session_id: "s-1",
    }),
  );
  assert.deepEqual(taskDelta1, []);

  const taskDelta2 = logsOf(
    adapter.emit({
      type: "stream_event",
      event: {
        type: "content_block_delta",
        index: 2,
        delta: {
          type: "input_json_delta",
          partial_json: ',"description":"inspect codex item.updated events"}',
        },
      },
      session_id: "s-1",
    }),
  );
  assert.deepEqual(taskDelta2, [
    "Tool: Task(Explore: inspect codex item.updated events)",
  ]);
});

test("createClaudeAdapter suppresses noisy partial thinking updates until text stabilizes", () => {
  const adapter = createClaudeAdapter();

  logsOf(
    adapter.emit({
      type: "stream_event",
      event: {
        type: "content_block_start",
        index: 3,
        content_block: { type: "thinking" },
      },
      session_id: "s-1",
    }),
  );

  const firstSentence = logsOf(
    adapter.emit({
      type: "stream_event",
      event: {
        type: "content_block_delta",
        index: 3,
        delta: {
          type: "thinking_delta",
          thinking: "The codebase has evolved significantly. There",
        },
      },
      session_id: "s-1",
    }),
  );
  assert.deepEqual(firstSentence, [
    "Thinking: The codebase has evolved significantly.",
  ]);

  const partialFollowup = logsOf(
    adapter.emit({
      type: "stream_event",
      event: {
        type: "content_block_delta",
        index: 3,
        delta: {
          type: "thinking_delta",
          thinking:
            " are 256 tests passing, and there are uncommitted changes in SDK adapter files",
        },
      },
      session_id: "s-1",
    }),
  );
  assert.deepEqual(partialFollowup, []);

  const secondSentence = logsOf(
    adapter.emit({
      type: "stream_event",
      event: {
        type: "content_block_delta",
        index: 3,
        delta: {
          type: "thinking_delta",
          thinking: ". Let me explore the current state of",
        },
      },
      session_id: "s-1",
    }),
  );
  assert.deepEqual(secondSentence, [
    "Thinking: There are 256 tests passing, and there are uncommitted changes in SDK adapter files.",
  ]);

  const stopLog = logsOf(
    adapter.emit({
      type: "stream_event",
      event: {
        type: "content_block_stop",
        index: 3,
      },
      session_id: "s-1",
    }),
  );
  assert.deepEqual(stopLog, ["Thinking: Let me explore the current state of"]);
});

test("createClaudeAdapter emits only the new generating suffix on stop", () => {
  const adapter = createClaudeAdapter();

  logsOf(
    adapter.emit({
      type: "stream_event",
      event: {
        type: "content_block_start",
        index: 4,
        content_block: { type: "text" },
      },
      session_id: "s-1",
    }),
  );

  const firstSentence = logsOf(
    adapter.emit({
      type: "stream_event",
      event: {
        type: "content_block_delta",
        index: 4,
        delta: {
          type: "text_delta",
          text: "Now I have a clear picture of all three bugs.",
        },
      },
      session_id: "s-1",
    }),
  );
  assert.deepEqual(firstSentence, [
    "Generating: Now I have a clear picture of all three bugs.",
  ]);

  const stopLog = logsOf(
    adapter.emit({
      type: "stream_event",
      event: {
        type: "content_block_delta",
        index: 4,
        delta: {
          type: "text_delta",
          text: " Let me implement all three fixes:",
        },
      },
      session_id: "s-1",
    }),
  ).concat(
    logsOf(
      adapter.emit({
        type: "stream_event",
        event: {
          type: "content_block_stop",
          index: 4,
        },
        session_id: "s-1",
      }),
    ),
  );
  assert.deepEqual(stopLog, ["Generating: Let me implement all three fixes:"]);
});

// whirlwind-964: query() hangs in sandbox — timeout and CLI fallback
test("whirlwind-964: start() falls back to CLI streaming when query() hangs past timeout", async () => {
  // Simulate query() that never yields (hangs forever)
  const hangingQuery = () => ({
    async *[Symbol.asyncIterator]() {
      await new Promise(() => {}); // never resolves
    },
  });

  const cliEvents = [
    { type: "system", subtype: "init", session_id: "cli-1" },
    { type: "result", subtype: "success" },
  ];

  const fakeCliFallback = (_opts) => ({
    async *[Symbol.asyncIterator]() {
      for (const event of cliEvents) {
        yield event;
      }
    },
  });

  const adapter = createClaudeAdapter({
    queryFn: hangingQuery,
    cliFallbackFn: fakeCliFallback,
    queryTimeoutMs: 100, // 100ms timeout for fast test
  });

  const result = await adapter.start({ prompt: "hello" });

  // Should get a working stream (the CLI fallback), not hang
  const collected = [];
  for await (const item of result.stream) {
    collected.push(item);
  }

  assert.ok(collected.length > 0, "should receive events from CLI fallback");
  assert.equal(collected[0].type, "system");
  assert.equal(collected[1].subtype, "success");
});

test("whirlwind-964: start() uses SDK query() when it yields events within timeout", async () => {
  const sdkEvents = [
    { type: "system", subtype: "init", session_id: "sdk-1" },
    { type: "result", subtype: "success" },
  ];

  const workingQuery = () => ({
    async *[Symbol.asyncIterator]() {
      for (const event of sdkEvents) {
        yield event;
      }
    },
  });

  const fakeCliFallback = () => {
    throw new Error("CLI fallback should not be called");
  };

  const adapter = createClaudeAdapter({
    queryFn: workingQuery,
    cliFallbackFn: fakeCliFallback,
    queryTimeoutMs: 500,
  });

  const result = await adapter.start({ prompt: "hello" });

  const collected = [];
  for await (const item of result.stream) {
    collected.push(item);
  }

  assert.equal(collected.length, 2);
  assert.equal(collected[0].session_id, "sdk-1");
});

test("whirlwind-964: start() initLogs includes fallback notice when query() times out", async () => {
  const hangingQuery = () => ({
    async *[Symbol.asyncIterator]() {
      await new Promise(() => {});
    },
  });

  const fakeCliFallback = (_opts) => ({
    async *[Symbol.asyncIterator]() {
      yield { type: "result", subtype: "success" };
    },
  });

  const adapter = createClaudeAdapter({
    queryFn: hangingQuery,
    cliFallbackFn: fakeCliFallback,
    queryTimeoutMs: 100,
  });

  const result = await adapter.start({ prompt: "hello" });

  assert.ok(
    result.initLogs && result.initLogs.length > 0,
    "should have init logs",
  );
  const fallbackLog = result.initLogs.find(
    (l) => l.includes("fallback") || l.includes("timeout") || l.includes("CLI"),
  );
  assert.ok(fallbackLog, "should include a log about CLI fallback");

  // Drain the stream
  for await (const _ of result.stream) {
  }
});

test("whirlwind-964: createClaudeAdapter without deps still exports the same emit behavior", () => {
  // Existing behavior must be preserved when no deps are passed
  const adapter = createClaudeAdapter();
  const emissions = adapter.emit({
    type: "system",
    subtype: "status",
    status: "compacting",
    session_id: "s-1",
  });
  const logs = logsOf(emissions);
  assert.deepEqual(logs, ["Status: compacting"]);
});

function logsOf(emissions) {
  return emissions.flatMap((emission) => (emission.log ? [emission.log] : []));
}
