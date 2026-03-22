# MoonBit Core Logic - 全モジュール実装詳細

## 1. src/types/ - 型定義モジュール

依存: なし（全モジュールの基盤）

### 主要型

**エージェント関連:**
- `AgentKind` (enum): ClaudeCode | Codex | Mock
- `AgentRole` (enum): Builder | Review | Planner | Verifier
- `AgentStatus` (enum): Idle | Running | Completed | Failed(String)
- `AgentConfig` (struct): id, kind, role, model

**タスク・セッション:**
- `TaskStatus` (enum): Pending | InProgress(String) | Done | Failed(String)
- `Task` (struct): id, description, parent_id, mut status, mut result, mut review
- `Session` (struct): user_task, agents[], tasks[], current_phase, status
- `ReviewResult` (struct): reviewer_id, verdict, summary, file_path
- `ReviewVerdict` (enum): Approved | NeedsChanges(Array[String]) | Rejected(String)

**Ralph ループ:**
- `MilestoneStatus` (enum): Pending | InProgress | Done | Failed(String)
- `Milestone` (struct): id, goal, status, tasks[], summary
- `RalphTask` (struct): id, description, wave, status, result
- `RalphPhase` (enum): LoadingMilestones | Planning(String) | ExecutingWave(String, Int) | Verifying(String, Int) | Reworking(String, Int) | MilestoneComplete(String) | AllComplete
- `VerifierVerdict` (enum): Approved | NeedsRework(Array[String]) | MilestoneFailed(String)

**イベント・コールバック:**
- `AgentEvent` (enum): OutputLine | Info | ToolCall | ToolResult | SubAgentStart/End | StatusChange | SessionId | Usage
- `OrchestratorEvent` (enum): AgentOutput | AgentComplete | TaskStart | TaskComplete | TaskAssign | ReviewStart | ReviewComplete | PhaseChange | SessionComplete | Info
- `OrchestratorCallbacks` (struct): on_event (単一イベントリスナー) + on_save

---

## 2. src/agent/ - エージェント抽象化層

依存: types, json

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

### 2つの実装

**SubprocessBackend** (ClaudeCode/Codex):
- Claude Agent SDK / Codex SDK をサブプロセスで起動
- JSONL イベント形式でパース: system, assistant, stream_event, tool_result, result
- session_id で再開可能
- トークン使用量・コスト追跡

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

## 3. src/review/ - レビューエージェント

依存: types, agent, prompts, util

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

## 4. src/ralph/ - Ralph自律開発ループ

依存: types, agent, config, prompts, util, json

### 4.1 RalphLoop (ralph_loop.mbt)

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

### 4.2 PlannerAgent (planner.mbt)

マイルストーン -> Waveごとのタスクリスト生成

出力フォーマット:
```
WAVE 0:
1. First task description
2. Second task description

WAVE 1:
1. Task that depends on wave 0
```

### 4.3 VerifierAgent (verifier.mbt)

Wave の実行結果を検証

判定タグ:
- `<wave_approved>` -> Approved
- `<needs_rework>task_id: reason</needs_rework>` -> NeedsRework
- `<milestone_failed>reason</milestone_failed>` -> MilestoneFailed

### 4.4 MilestoneManager (milestone.mbt)

- JSON シリアライズ (milestones.json 永続化)
- `parse_planner_output()`: WAVE テキスト解析
- `gen_task_id()`: m1-t1, m1-t2, ... 自動採番
- Wave 管理: `get_wave_tasks()`, `has_undone_tasks()`, `next_wave_number()`
- ID復旧: ロード時に max(task_id) から next_task_id を復元

---

## 5. src/cli/ - CLIパース

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

## 6. src/config/ - 設定パース・バリデーション

依存: types, util, json

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
  milestones_path: String?     // default: ".whirlwind/milestones.json"
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

## 7. src/display/ - 表示フォーマット

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

## 8. src/prompts/ - プロンプトテンプレート

依存: なし

### チェックリスト生成

- `code_quality_checklist(lang)`: コード品質レビュー用チェックリスト
- `performance_checklist(lang)`: パフォーマンスレビュー用チェックリスト
- `security_checklist(lang)`: セキュリティレビュー用チェックリスト
- `goal_alignment_checklist(lang)`: 目標整合性レビュー用チェックリスト

各関数は `lang` 引数で日本語/英語を切り替え。

---

## 9. src/util/ - 汎用ユーティリティ

依存: json

### 文字列操作
- `extract_tag_content(text, tag_name)`: XMLタグ内のコンテンツ抽出
- `split_lines(s)`: 改行で分割
- `trim(s)`: 前後空白除去
- `join_strings(parts, sep)`: 文字列結合
- `json_escape(s)`: JSON文字列エスケープ
- `find_substring(haystack, needle)`: 部分文字列検索
- `find_substring_from(haystack, needle, from)`: 位置指定部分文字列検索
- `substring(s, start, end)`: 部分文字列抽出

### JSON ヘルパー
- `get_string(json, key, default)`: 文字列フィールド取得
- `get_int(json, key, default)`: 整数フィールド取得
- `get_bool(json, key, default)`: 真偽値フィールド取得
- `get_string_opt(json, key)`: オプショナル文字列フィールド取得

---

## 10. src/cmd/helpers/ - ヘルパー関数

依存: json

### 主要関数
- `resolve_lang(cli_lang, detect_fn)`: 言語設定の解決
- `extract_event_ts(...)`: イベントタイムスタンプの抽出
- `derive_archive_path(plan_path)`: アーカイブパス導出
- `join_dev_outputs(outputs)`: Dev出力の結合
- `build_cycle_summary(...)`: サイクルサマリー構築
- `build_plan_file_task(...)`: 計画ファイルからタスク構築
- `build_improvement_task(...)`: 改善タスク構築
- `session_to_json(state)` / `session_from_json(content)`: セッション永続化
- `find_agent_id(agents, role)`: ロールベースのエージェント検索

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
