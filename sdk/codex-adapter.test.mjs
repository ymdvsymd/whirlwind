import test from "node:test";
import assert from "node:assert/strict";

import { createCodexAdapter } from "./codex-adapter.mjs";

test("createCodexAdapter passes systemPrompt as developer_instructions", async () => {
  const constructed = [];
  const fakeThread = {
    id: "thread-1",
    async runStreamed() {
      return { events: emptyAsync() };
    },
  };

  class FakeCodex {
    constructor(opts) {
      constructed.push(opts);
    }

    startThread(opts) {
      assert.equal(opts.workingDirectory, process.cwd());
      return fakeThread;
    }

    resumeThread() {
      throw new Error("resumeThread should not be called");
    }
  }

  const adapter = createCodexAdapter({ CodexClient: FakeCodex });
  const result = await adapter.start({
    prompt: "Implement auth",
    systemPrompt: "Follow the brief",
  });

  assert.deepEqual(constructed, [
    { config: { developer_instructions: "Follow the brief" } },
  ]);
  assert.equal(result.sessionId, "thread-1");
});

test("createCodexAdapter creates Codex with no config when systemPrompt is absent", async () => {
  const constructed = [];
  const fakeThread = {
    id: "thread-2",
    async runStreamed() {
      return { events: emptyAsync() };
    },
  };

  class FakeCodex {
    constructor(opts) {
      constructed.push(opts);
    }

    startThread() {
      return fakeThread;
    }

    resumeThread() {
      throw new Error("resumeThread should not be called");
    }
  }

  const adapter = createCodexAdapter({ CodexClient: FakeCodex });
  const result = await adapter.start({
    prompt: "Implement auth",
  });

  assert.deepEqual(constructed, [undefined]);
  assert.equal(result.sessionId, "thread-2");
});

test("createCodexAdapter passes sandboxMode danger-full-access to startThread", async () => {
  let threadOpts;
  const fakeThread = {
    id: "thread-3",
    async runStreamed() {
      return { events: emptyAsync() };
    },
  };

  class FakeCodex {
    constructor() {}

    startThread(opts) {
      threadOpts = opts;
      return fakeThread;
    }

    resumeThread() {
      throw new Error("resumeThread should not be called");
    }
  }

  const adapter = createCodexAdapter({ CodexClient: FakeCodex });
  await adapter.start({ prompt: "Test task" });

  assert.equal(threadOpts.sandboxMode, "danger-full-access");
  assert.equal(threadOpts.skipGitRepoCheck, undefined);
});

test("initLogs for new thread contains starting message then thread id", async () => {
  const fakeThread = {
    id: "thread-new",
    async runStreamed() {
      return { events: emptyAsync() };
    },
  };

  class FakeCodex {
    constructor() {}
    startThread() {
      return fakeThread;
    }
    resumeThread() {
      throw new Error("resumeThread should not be called");
    }
  }

  const adapter = createCodexAdapter({ CodexClient: FakeCodex });
  const result = await adapter.start({ prompt: "hello" });

  assert.deepEqual(result.initLogs, [
    "Starting new thread",
    "Thread: thread-new",
  ]);
});

test("initLogs for resumed thread contains resuming message then thread id", async () => {
  const fakeThread = {
    id: "thread-existing",
    async runStreamed() {
      return { events: emptyAsync() };
    },
  };

  class FakeCodex {
    constructor() {}
    startThread() {
      throw new Error("startThread should not be called");
    }
    resumeThread() {
      return fakeThread;
    }
  }

  const adapter = createCodexAdapter({ CodexClient: FakeCodex });
  const result = await adapter.start({
    prompt: "continue",
    threadId: "thread-existing",
  });

  assert.deepEqual(result.initLogs, [
    "Resuming thread: thread-existing",
    "Thread: thread-existing",
  ]);
});

async function* emptyAsync() {}
