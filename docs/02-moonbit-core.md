# MoonBit Core Logic - 全モジュール実装詳細

## 1. src/types/ - 型定義モジュール

依存: なし（全モジュールの基盤）

### 主要型

**エージェント関連:**
- `AgentKind` (enum): ClaudeCode | Codex | Api | Mock
- `AgentRole` (enum): Dev | Review | Orchestrator | Planner | Verifier
- `AgentStatus` (enum): Idle | Running | Completed | Failed(String) | Aborted
- `AgentConfig` (struct): id, kind, role, model, system_prompt, working_dir, max_iterations

**タスク・セッション:**
- `TaskStatus` (enum): Pending | InProgress(String) | Done | Failed(String)
- `Task` (struct): id, description, parent_id, mut status, mut result, mut review
- `Session` (struct): user_task, agents[], tasks[], current_phase, status
- `ReviewResult` (struct): reviewer_id, verdict, summary, file_path
- `ReviewVerdict` (enum): Approved | NeedsChanges(Array[String]) | Rejected(String)

**Ralph ループ:**
- `MilestoneStatus` (enum): Pending | InProgress | Done | Failed(String)
- `Milestone` (struct): id, goal, status, tasks[], current_wave
- `RalphTask` (struct): id, description, wave, status, result, plan_doc
- `RalphPhase` (enum): LoadingMilestones | Planning(String) | ExecutingWave(String, Int) | Verifying(String, Int) | Reworking(String, Int) | MilestoneComplete(String) | AllComplete
- `VerifierVerdict` (enum): Approved | NeedsRework(Array[String]) | MilestoneFailed(String)

**イベント・コールバック:**
- `AgentEvent` (enum): OutputLine | Info | ToolCall | ToolResult | SubAgentStart/End | StatusChange | SessionId | Usage
- `OrchestratorCallbacks` (struct): 11個のコールバック関数フィールド

---

## 2. src/task/ - タスク管理

依存: types

### TaskManager

- `new()` -> TaskManager
- `add_task(description, parent_id?)` -> Task (ID自動採番: task-1, task-2, ...)
- `parse_tasks(text, parent_id?)` -> Array[Task] (番号付き/箇条書きリストをパース)
- `get_task(id)` -> Task?
- `get_pending()` -> Array[Task]
- `get_completed()` -> Array[Task]
- `assign_next(agent_id)` -> Task? (ラウンドロビン割り当て)
- `completed_count()` -> Int
- `all_done()` -> Bool

### Task 状態遷移

```
Pending -> InProgress(agent_id) -> Done | Failed(error)
```

### テキストパース

- "1. ", "- ", "* " プレフィックスを自動削除
- 空行スキップ
- 各行を独立したTaskとして生成

---

## 3. src/agent/ - エージェント抽象化層

依存: types, llm/*, json

### AgentBackend trait

```moonbit
pub(open) trait AgentBackend {
  run(Self, task: String, system_prompt: String,
      on_output: (AgentEvent) -> Unit) -> AgentResult
  name(Self) -> String
  set_session_id(Self, String) -> Unit
  get_session_id(Self) -> String
}
```

### 3つの実装

**SubprocessBackend** (ClaudeCode/Codex):
- Claude Agent SDK / Codex SDK をサブプロセスで起動
- JSONL イベント形式でパース: system, assistant, stream_event, tool_result, result
- session_id で再開可能
- トークン使用量・コスト追跡

**ApiBackend** (Anthropic/OpenAI API):
- `@llm.BoxedProvider` を使用してモデル切り替え
- `stream()` で実行、TextDelta/Error イベント処理
- OutputLineBuffer で行単位バッファリング

**MockBackend** (テスト用):
- 固定応答またはパターンマッチング応答 (`add_response(keyword, response)`)
- 呼び出し履歴追跡 (`get_history()`)
- `FailingMockBackend`: 常にFailed(msg)を返す

### OutputLineBuffer

テキストチャンクを行単位に変換:
- `push(chunk)`: \n 境界で OutputLine イベント発火
- `flush()`: 残り行を最終イベント化
- CRLF (\r\n) サポート

### parse_events.mbt

JSONL イベントのパース関数群:
- `parse_tool_calls()`: tool_use ブロック抽出
- `parse_tool_result()`: name/content 抽出
- `parse_system_event()`: init イベント (model, tools count)
- `parse_content_block_start()`: "Using tool: X", "Thinking...", "Generating..."
- `parse_sdk_result_event()`: 費用、実行時間、トークン統計

### factory.mbt

設定 -> 具体的バックエンドの生成を一元化:
```moonbit
pub fn create_backend(config: AgentConfig) -> BoxedBackend
```

---

## 4. src/orchestrator/ - オーケストレーション

依存: types, agent, task, review, config

> **⚠️ 注意:** このモジュールは `Orchestrator::run()` メソッドを定義しているが、
> 現在のランタイムパス (`run_repl()`) からは**呼ばれていない**。
> 通常モードは `cmd/app/main.mbt` 内の `run_repl()` が `run_dev()` / `run_review()` を
> `while true` ループで直接呼び出している。
> `OrchestratorCallbacks` 型のみ Ralph モードから参照されている。

### Orchestrator 構造

```moonbit
pub struct Orchestrator {
  config: ProjectConfig
  task_manager: TaskManager
  review_agent: ReviewAgent?
  backends: Map[String, BoxedBackend]
  callbacks: OrchestratorCallbacks
  mut review_cycles: Int
}
```

### 実行フロー (run) - 現在未使用

以下の 6 フェーズ制御は定義されているが、`run_repl()` からは呼ばれない:

1. **Decomposing**: Dev エージェントでタスク分解、parse_tasks()で解析
2. **Assigning**: ラウンドロビン割り当て
3. **Executing**: InProgressタスクをbackend.run()で実行
4. **Reviewing**: ReviewAgent::review()で3視点レビュー
5. **Iterating**: NeedsChanges -> フィードバック付き再実行 -> 再レビュー
6. **Finalizing**: session.status = Completed

### 制御パラメータ

- `max_review_cycles`: レビュー繰り返し上限 (default: 3)
- `review_interval`: レビュー間隔

### 失敗時の保護

- Decompose失敗: 元タスクをそのまま使用
- Rework前にreviewデータ保存、失敗時に復元

### 実際の通常モード実行 (run_repl)

`cmd/app/main.mbt` の `run_repl()` が通常モードの実体:
- `while true` 無限ループで `run_dev()` → `run_review()` を繰り返す
- `review_interval` で N 回 dev 後に 1 回 review
- Approved 後は `build_next_task()` で自動的に次タスクを生成して継続
- Rejected 時は `check_interrupt()` でユーザー入力をポーリング待ち
- 終了は **Ctrl+C のみ**

---

## 5. src/review/ - レビューエージェント

依存: types, agent

### 3つのレビュー観点

| 観点 | 評価項目 |
|------|---------|
| CodeQuality | 可読性、命名規約、関心の分離、エラーハンドリング、テストカバレッジ |
| Performance | 時間/空間計算量、メモリ確保、N+1 クエリ、キャッシング |
| Security | 入力バリデーション、インジェクション、認証/認可、機密データ |

### 評決パース

XMLタグベース:
- `<approved>` -> Approved
- `<needs_changes>item1, item2</needs_changes>` -> NeedsChanges(["item1", "item2"])
- `<rejected>reason</rejected>` -> Rejected(reason)

### マージロジック

- 最初のRejected -> 全体Rejected (短絡評価)
- それ以外 -> 全NeedsChangesを統合
- 全Approved -> Approved

### 多言語対応

- `lang="en"`: "Review Focus: Code Quality"
- `lang="ja"`: "レビュー観点: コード品質"

---

## 6. src/ralph/ - Ralph自律開発ループ

依存: types, agent, config, json

### 6.1 RalphLoop (ralph_loop.mbt)

状態マシン:
```
LoadingMilestones -> Planning(m_id) -> ExecutingWave(m_id, wave)
  -> Verifying(m_id, wave) -> (Reworking -> Verifying)*
  -> MilestoneComplete(m_id) -> AllComplete
```

**フィードバックルーティング (v0.6.0):**

`rework_tasks()` はターゲット指定のフィードバック配信を実装:
- `strip_task_feedback_prefix()`: タスクIDプレフィクス除去
- フィードバック項目がタスクIDにマッチ → ターゲット指定モード
- マッチなし → ブロードキャストモード（全Done タスクにフォールバック）
- リワークプロンプト: `task.description + "\n\nFeedback from verifier:\n" + feedback_str`

### 6.2 PlannerAgent (planner.mbt)

マイルストーン -> Waveごとのタスクリスト生成

出力フォーマット:
```
WAVE 0:
1. First task description
2. Second task description

WAVE 1:
1. Task that depends on wave 0
```

### 6.3 VerifierAgent (verifier.mbt)

Wave の実行結果を検証

判定タグ:
- `<wave_approved>` -> Approved
- `<needs_rework>task_id: reason</needs_rework>` -> NeedsRework
- `<milestone_failed>reason</milestone_failed>` -> MilestoneFailed

### 6.4 MilestoneManager (milestone.mbt)

- JSON シリアライズ (milestones.json 永続化)
- `parse_planner_output()`: WAVE テキスト解析
- `gen_task_id()`: m1-t1, m1-t2, ... 自動採番
- Wave 管理: `get_wave_tasks()`, `has_undone_tasks()`, `next_wave_number()`
- ID復旧: ロード時に max(task_id) から next_task_id を復元

---

## 7. src/cli/ - CLIパース

依存: types, config

### CliCommand enum

```moonbit
pub enum CliCommand {
  Run(config_path~, plan_path~, dev_kind~, review_kind~,
      review_interval~, rlm~, ralph~, lang~, warnings~)
  Validate(String?)
  Help
}
```

### サポートフラグ

| フラグ | 値 | 説明 |
|--------|-----|------|
| `--config=PATH` | ファイルパス | 設定ファイル |
| `--dev=KIND` | claude-code/codex/api/mock | Dev エージェント種 |
| `--review=KIND` | 同上 | Review エージェント種 |
| `--review-interval=N` | 整数 | N回のdev後にreview |
| `--rlm` | フラグ | Improvement Loop Mode |
| `--ralph` | フラグ | Ralph Loop モード |
| `--lang=LANG` | auto/ja/en | レビュー言語 |

### apply_overrides()

CLI フラグを ProjectConfig にマージ

---

## 8. src/config/ - 設定パース・バリデーション

依存: types

### ProjectConfig

```moonbit
pub struct ProjectConfig {
  project_dir: String          // default: "."
  review_dir: String           // default: "docs/reviews"
  max_review_cycles: Int       // default: 3
  review_interval: Int         // default: 1
  agents: Array[AgentConfig]
  parse_warnings: Array[String]
  ralph_enabled: Bool          // default: false
  milestones_path: String?     // default: ".tornado/milestones.json"
  max_rework_attempts: Int     // default: 3
}
```

### バリデーション

- エージェントID重複チェック
- Devエージェント必須
- ralph_enabled時、Plannerエージェント必須
- unknown kind/role -> Warning + デフォルト値(Mock/Dev)

### プリセット

- `preset_default()`: Dev(ClaudeCode) + Reviewer(Codex)
- `preset_ralph()`: Planner(CC) + Builder(CC) + Verifier(Codex)

---

## 9. src/display/ - 表示フォーマット

依存: json

### ユーティリティ

- `truncate(s, max)`: 長さ制限 + "..." サフィックス
- `count_lines(s)`: \n カウント (末尾 \n は除外)

### ツール表示

| ツール | 表示形式 |
|--------|---------|
| Read | `Read(file_path)` |
| Edit | `Edit(path)\n old: ...\n new: ...` |
| Write | `Write(path, N chars)` |
| Bash | `Bash(command)` |
| Glob | `Glob(pattern)` |
| Grep | `Grep(pattern in path)` |
| Task | `Task(agent_type: description)` |

---

## 10. src/tui/ - TUI状態管理

依存: types, tui/vnode

### TuiState

```moonbit
pub struct TuiState {
  sessions: Map[String, Session]
  mut active_session_id: String?
  mut active_tab: Int
  agent_logs: Map[String, Array[String]]
  phase_log: Array[String]
}
```

### コールバック統合

`make_callbacks()` で OrchestratorCallbacks を生成:
- on_agent_output -> agent_logs に追記
- on_phase_change -> phase_log に追記
- on_task_start/assign/complete -> 適切なログに記録

### レンダリング

- `render_header()`: session ID, phase, agent count
- `render_tabs()`: タブバー (active_tab ハイライト)
- `render_agent_panel()`: agent info + 最後の20行ログ
- `render_status_bar()`: Progress X/N + session.status
- `render_app()`: 全体レイアウト (VirtualDOM)

---

## 11. src/spawn/ - プロセス起動

依存: なし

### spawn_lines()

プロセス起動 -> stdout行ごとコールバック:
```
spawn_lines(program, args, on_line, on_error, on_done)
```

### LineBuffer

- `push(chunk)`: \n 検出時に完全行を on_line() で発火
- `flush()`: 残り (不完全行) を最終イベント化
- CRLF 対応: \r\n -> \n に正規化

---

## MoonBit 実装上の特性

### パターンマッチング中心

全 enum に対して網羅的なパターンマッチングを適用。
コンパイラが未処理の variant を検出。

### 可変性の局所化

`mut` フィールド (task.status, milestone.status) で状態遷移。
Task::assign(), Task::complete() は mutable オブジェクト操作。

### StringBuilder 多用

プロンプト構築、JSON生成に StringBuilder を活用。

### Map による動的ディスパッチ

`Map[String, BoxedBackend]` でエージェント管理。
agent_id でバックエンドを O(1) ルックアップ。

### raise Failure

設定パースなどの回復不能エラーに `raise Failure` を使用:
```moonbit
pub fn from_json_string(s: String) -> ProjectConfig raise Failure
```
