# TypeScript SDK & External Integration

## 1. SDK アーキテクチャ概要

`sdk/` 層はMoonBit（バックエンド）とNode.js間の統合層。
2つの異なるAIエージェントSDK（Claude Agent SDK, OpenAI Codex SDK）を
**アダプターパターン**で統一インターフェースに抽象化。

```
MoonBit (spawnSync)
  -> sdk/claude-runner.mts (or codex-runner.mts)
    -> agent-runner.mts (共通実行エンジン)
      -> claude-adapter.mts (or codex-adapter.mts)
        -> @anthropic-ai/claude-agent-sdk (or @openai/codex-sdk)
  <- stdout (JSONL events)
```

---

## 2. 共通インターフェース層

### 2.1 runner-io.mts

共通I/O:
- `writeJsonl(obj)`: 1行1JSONで stdout に出力
- `createLogger(tag)`: タグ付きメッセージを stderr に出力

### 2.2 agent-adapter.mts

```typescript
export type RunnerOptions = {
  prompt: string;
  cwd?: string;
  model?: string;
  systemPrompt?: string;
  sessionId?: string;
  threadId?: string;
};

export interface AgentAdapter<RawEvent> {
  tag: string;
  start(opts: RunnerOptions): Promise<AdapterStartResult<RawEvent>>;
  emit(raw: RawEvent, sessionId: string): readonly AdapterEmission[];
}

export type AdapterStartResult<RawEvent> = {
  sessionId: string;
  stream: AsyncIterable<RawEvent>;
  initEvents?: readonly unknown[];
  initLogs?: readonly string[];
};

export type AdapterEmission = {
  event?: unknown;
  log?: string;
};
```

### 2.3 agent-runner.mts

```typescript
export async function runAdapter<RawEvent>(
  adapter: AgentAdapter<RawEvent>,
  opts: RunnerOptions,
  io?: AdapterIO,
): Promise<void>
```

実行フロー:
1. `adapter.start(opts)` -> ストリーム開始
2. `initEvents` と `initLogs` を先行出力
3. `for await (raw of stream)` -> `adapter.emit(raw)` で変換
4. 変換結果 `{event, log}` を出力

---

## 3. Claude Agent SDK 統合

### claude-adapter.mts

SDKオプション:
```typescript
const queryOpts = {
  includePartialMessages: true,
  permissionMode: "bypassPermissions",
  allowDangerouslySkipPermissions: true,
  cwd: opts.cwd || process.cwd(),
};
```

### イベント変換マッピング

| Claude イベント型 | 変換処理 |
|---|---|
| `type: "system"` | セッション初期化 (model, session_id) |
| `type: "stream_event"` | content_block_start解析 (tool_use, thinking, text) |
| `type: "assistant"` | tool_use コンテンツ解析 |
| `type: "result"` | コスト、実行時間、トークン使用量抽出 |

### claude-runner.mts

```typescript
import { runAdapterFromArgv } from "./agent-runner.mjs";
import { createClaudeAdapter } from "./claude-adapter.mjs";
await runAdapterFromArgv(createClaudeAdapter());
```

---

## 4. Codex SDK 統合

### codex-adapter.mts

```typescript
const threadOpts = {
  model: opts.model || undefined,
  workingDirectory: opts.cwd || process.cwd(),
  approvalPolicy: "never",  // 自動承認
};

// スレッド新規作成 or 再開
const thread = opts.threadId
  ? client.resumeThread(threadId, threadOpts)
  : client.startThread(threadOpts);
```

### codex-normalizer.mts (正規化層)

Codex のネイティブイベントを Claude 互換フォーマットに変換:

**item.started:**

| Codex型 | 変換後 |
|---|---|
| `command_execution` | `{type: "assistant", ..., tool_use name: "Bash"}` |
| `file_change` | `{type: "assistant", ..., tool_use name: "Edit"}` |
| `mcp_tool_call` | `{type: "assistant", ..., tool_use name: server_name}` |
| `agent_message` | `{type: "content_block_start", type: "text"}` |
| `reasoning` | `{type: "content_block_start", type: "thinking"}` |

**item.completed:**

| Codex型 | 結果イベント |
|---|---|
| `command_execution` | `{type: "tool_result", tool_name: "Bash", content: output}` |
| `file_change` | `{type: "tool_result", tool_name: "Edit"}` |
| `mcp_tool_call` | `{type: "tool_result", tool_name: server_name}` |
| `agent_message` | `{type: "assistant", message: {content: [text]}}` |

**ターン完了:**
```typescript
{
  type: "result",
  subtype: "success",
  session_id: threadId,
  usage: {
    input_tokens,
    output_tokens,
    cache_read_input_tokens,    // cached_input_tokens を変換
    cache_creation_input_tokens: 0
  }
}
```

---

## 5. FFIブリッジ

### 5.1 SDK実行 FFI (agent/sdk_js.mbt)

```moonbit
pub fn run_claude_sdk(opts_json: String) -> String {
  js_run_sdk("claude-runner.mjs", opts_json)
}

pub fn run_codex_sdk(opts_json: String) -> String {
  js_run_sdk("codex-runner.mjs", opts_json)
}
```

JavaScript実装:
```javascript
const result = spawnSync(process.execPath, [runnerPath, optsJson], {
  encoding: 'utf-8',
  stdio: ['pipe', 'pipe', 'inherit'],
  maxBuffer: 100 * 1024 * 1024,  // 100 MB
  timeout: 600000,               // 10分
});
```

特性:
- **同期実行** (spawnSync): MoonBit から結果を同期的に取得
- **stdout のみキャプチャ**: JSONL イベントストリーム
- **stderr は inherited**: リアルタイムログが親プロセスに流れる

### 5.2 アプリケーション FFI (cmd/app/ffi_js.mbt)

**stdin-watcher 起動:**
- `spawn(process.execPath, [watcherPath])` で別プロセス起動
- `watcher.unref()` で親プロセス終了時も動作

**interrupt チェック:**
- `.whirlwind/interrupt.txt` を読み込み
- 内容があれば消費済みマークしてreturn

---

## 6. ストリーミングプロトコル (JSONL)

```json
{"type":"system","subtype":"init","session_id":"s-123","model":"claude-3-5-sonnet"}
{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"text"}}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"bash","input":{"command":"ls"}}]}}
{"type":"tool_result","tool_name":"bash","content":"file1.txt\nfile2.txt"}
{"type":"result","subtype":"success","session_id":"s-123","usage":{"input_tokens":1500,"output_tokens":250}}
```

---

## 7. stdin-watcher

ユーザー入力をファイル経由で非同期キューイング:

```javascript
const rl = createInterface({ input: process.stdin, terminal: true });
rl.on('line', (line) => {
  const trimmed = line.trim();
  if (trimmed) {
    appendFileSync(INTERRUPT_FILE, trimmed + '\n', 'utf-8');
    process.stderr.write(`\x1b[33m[USER] Queued: ${trimmed}\x1b[0m\n`);
  }
});
```

interrupt ファイル: `.whirlwind/interrupt.txt`

---

## 8. エラーハンドリング

### FFI レベル

```javascript
if (result.error) return 'ERROR: ' + result.error.message;
if (result.status !== 0 && !result.stdout) return 'ERROR: exit code ' + result.status;
```

非ゼロ終了コード かつ stdout が空の場合のみエラー扱い。
stdout がある場合は部分実行として処理。

### Codex 正規化レベル

```typescript
export function normalizeTurnFailed(event, sessionId) {
  return {
    type: "result",
    subtype: "error",
    is_error: true,
    result: event?.error?.message || "Turn failed",
  };
}
```

---

## 9. TypeScript コンパイル設定

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "strict": true,
    "skipLibCheck": true
  },
  "include": ["sdk/*.mts"]
}
```

- `.mts` のみコンパイル対象
- strict mode で型安全性を強制
- NodeNext により import 自動解決

---

## 10. 設計パターンまとめ

| パターン | 実装箇所 | 効果 |
|---|---|---|
| **アダプター** | AgentAdapter\<RawEvent\> | SDK間の抽象化 |
| **ファクトリ** | createClaudeAdapter() | 具体アダプタの生成 |
| **テンプレートメソッド** | runAdapter() | フロー制御の統一 |
| **イテレータ** | AsyncIterable\<RawEvent\> | ストリーム処理 |
| **正規化** | codex-normalizer | Codex -> Claude 変換 |

### 拡張ポイント

1. **新SDK追加**: `AgentAdapter<NewSDKEvent>` を実装
2. **正規化ルール**: codex-normalizer に新ケース追加
3. **カスタムI/O**: AdapterIO を実装し runAdapter に渡す

### 制限事項

- 同期FFI: MoonBit側は spawnSync 待機
- タイムアウト固定: 10分（カスタマイズ不可）
- initEvents が `unknown[]` により部分的な型消去
