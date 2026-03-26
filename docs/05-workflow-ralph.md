# Whirlwind ワークフロー & Ralph 利用ガイド

## 1. 概要

Whirlwind はマイルストーン駆動の自律開発ループ (Ralph モード) で動作する。

| 項目           | 説明                                               |
| -------------- | -------------------------------------------------- |
| 終了条件       | 全マイルストーン完了で自動終了                     |
| タスク生成     | 事前定義 or Planner が生成                         |
| エージェント   | Planner + Builder + Verifier (3体)                 |
| 構造           | Milestone > Wave > Task の3層                      |
| レビュー       | マイルストーン単位の4観点検証                      |
| フィードバック | タスクID指定ルーティング                           |

---

## 2. Ralph クイックスタート

### Step 1: マイルストーンファイルを作成

```bash
mkdir -p .whirlwind
cat > .whirlwind/milestones.json << 'EOF'
{
  "milestones": [
    {
      "id": "m1",
      "goal": "Create a simple HTTP server with health check endpoint",
      "status": "pending",
      "tasks": []
    },
    {
      "id": "m2",
      "goal": "Add user CRUD endpoints with in-memory storage",
      "status": "pending",
      "tasks": []
    }
  ]
}
EOF
```

### Step 2: Ralph モードで実行

```bash
# プリセット構成で実行
whirlwind

# 設定ファイルを使って実行
whirlwind --config=whirlwind.json
```

### Step 3: 結果を確認

実行後、`.whirlwind/milestones.json` が更新され、各タスクの結果が記録される。

---

## 3. CLI 引数

### 基本コマンド

```bash
whirlwind [オプション...]
```

### 利用可能なオプション

| オプション              | 説明                                                              | デフォルト                               |
| ----------------------- | ----------------------------------------------------------------- | ---------------------------------------- |
| `--config=<path>`       | 設定ファイルのパス                                                | `whirlwind.json`（なければプリセット使用） |
| `--planner=<kind>`      | Planner エージェントの種類を上書き                                | `claude-code`                            |
| `--builder=<kind>`      | Builder エージェントの種類を上書き                                | `claude-code`                            |
| `--verifier=<kind>`     | Verifier エージェントの種類を上書き                               | `codex`                                  |
| `--milestones=<path>`   | マイルストーンファイルのパス                                      | `.whirlwind/milestones.json`             |
| `--lang=<auto\|ja\|en>` | エージェントの応答言語                                            | `auto`（環境変数 `LANG` から検出）       |
| `--log=<path>`          | ログファイルのパス                                                | なし                                     |

### エージェント種類 (`--planner`, `--builder`, `--verifier` に指定可能な値)

| 値                                      | 説明             |
| --------------------------------------- | ---------------- |
| `claude` / `claude-code` / `claudecode` | Claude Code      |
| `codex`                                 | OpenAI Codex     |
| `mock`                                  | テスト用モック   |

### マイルストーンファイルのパス指定

| 方法                                           | マイルストーンファイルのパス                                              |
| ---------------------------------------------- | ------------------------------------------------------------------------- |
| `whirlwind` (設定なし)                         | `.whirlwind/milestones.json` 固定                                           |
| `whirlwind --config=whirlwind.json`            | 設定ファイル内の `milestones_path`（省略時は `.whirlwind/milestones.json`） |
| `whirlwind --milestones=path/to/milestones.json` | CLI フラグで直接指定                                                      |

### 使用例

```bash
# 最小構成（プリセット使用、.whirlwind/milestones.json を読み込む）
whirlwind

# 設定ファイル指定（milestones_path もここで変更可能）
whirlwind --config=whirlwind.json

# エージェント種類を上書き
whirlwind --builder=codex --verifier=claude

# 日本語で応答
whirlwind --lang=ja

# フル指定
whirlwind --config=my-config.json --builder=codex --lang=ja
```

---

## 4. 設定ファイル (`whirlwind.json`)

`--config` を指定しない場合、カレントディレクトリの `whirlwind.json` を探す。
見つからなければ組み込みプリセット (`preset_ralph`) が使われる。

### 設定ロード順序

1. `--config=PATH` or デフォルト `whirlwind.json`
2. JSON パース -> ProjectConfig
3. `apply_overrides()` で CLI フラグ反映
4. `validate()` でエージェント構成チェック

### JSON フォーマット

```json
{
  "milestones_path": ".whirlwind/milestones.json",
  "max_rework_attempts": 3,
  "agents": [
    {
      "id": "planner",
      "kind": "claude-code",
      "role": "planner"
    },
    {
      "id": "builder",
      "kind": "claude-code",
      "role": "builder"
    },
    {
      "id": "verifier",
      "kind": "codex",
      "role": "verifier"
    }
  ]
}
```

### 設定フィールド一覧

| フィールド            | 型      | デフォルト | 説明                                                            |
| --------------------- | ------- | ---------- | --------------------------------------------------------------- |
| `milestones_path`     | string? | `null`     | マイルストーンファイルパス（省略時 `.whirlwind/milestones.json`） |
| `max_rework_attempts` | int     | `3`        | マイルストーン検証のリワーク最大回数                             |
| `max_review_cycles`   | int     | `3`        | レビューサイクル上限                                            |
| `review_interval`     | int     | `1`        | レビュー間隔                                                    |
| `agents`              | array   | `[]`       | エージェント設定の配列                                          |

### エージェント設定フィールド

| フィールド | 型      | デフォルト | 説明                                                       |
| ---------- | ------- | ---------- | ---------------------------------------------------------- |
| `id`       | string  | `""`       | エージェントの一意識別子                                   |
| `kind`     | string  | `"mock"`   | `"claude-code"` / `"codex"` / `"mock"`                     |
| `role`     | string  | `"builder"`| `"planner"` / `"builder"` / `"verifier"` / `"review"`      |
| `model`    | string? | `null`     | 使用モデル名（省略可）                                     |

### プリセット

**preset_ralph()**: デフォルト（`whirlwind.json` がない場合に使用）

| エージェント | ID         | Kind       | Role     |
| ------------ | ---------- | ---------- | -------- |
| Planner      | `planner`  | ClaudeCode | Planner  |
| Builder      | `builder`  | ClaudeCode | Dev      |
| Verifier     | `verifier` | Codex      | Verifier |

その他のデフォルト: `max_rework_attempts`: 3

**preset_default()**: Builder(ClaudeCode) + Reviewer(Codex)

### バリデーションルール

設定は起動時に検証される。以下の場合エラーになる:

- `agents` が空
- エージェント `id` が重複
- `Builder` ロールのエージェントが存在しない
- `Planner` ロールのエージェントが存在しない
- `review_interval` が 1 未満

---

## 5. マイルストーンファイル (`.whirlwind/milestones.json`)

Ralph モードの入力となるファイル。実行前に手動で作成する必要がある。

### JSON フォーマット

```json
{
  "milestones": [
    {
      "id": "m1",
      "goal": "認証システムを構築する",
      "status": "pending",
      "current_wave": 0,
      "tasks": []
    },
    {
      "id": "m2",
      "goal": "REST API エンドポイントを実装する",
      "status": "pending",
      "current_wave": 0,
      "tasks": []
    }
  ]
}
```

### マイルストーンフィールド

| フィールド     | 型     | 必須 | 説明                                                  |
| -------------- | ------ | ---- | ----------------------------------------------------- |
| `id`           | string | Yes  | マイルストーンの一意識別子（例: `"m1"`, `"m2"`）      |
| `goal`         | string | Yes  | マイルストーンの目標を自然言語で記述                  |
| `status`       | string | Yes  | `"pending"` / `"in_progress"` / `"done"` / `"failed"` |
| `current_wave` | int    | No   | 現在の Wave 番号（デフォルト: 0）                     |
| `tasks`        | array  | No   | タスクの配列（空の場合 Planner が自動生成）           |

### タスクフィールド

| フィールド    | 型      | 必須 | Builder に渡されるか  | 説明                                                                           |
| ------------- | ------- | ---- | --------------------- | ------------------------------------------------------------------------------ |
| `id`          | string  | Yes  | No                    | タスクID（例: `"m1-t1"`, `"m1-t2"`）。ログ表示と Verifier への結果紐付けに使用 |
| `description` | string  | Yes  | **Yes（唯一の入力）** | Builder の prompt としてそのまま渡される。後述の「description の書き方」を参照 |
| `wave`        | int     | Yes  | No                    | 所属する Wave 番号（0始まり）。実行順序制御に使用                              |
| `status`      | string  | Yes  | No                    | `"pending"` / `"in_progress"` / `"done"` / `"failed"`                          |
| `result`      | string? | No   | No（出力側）          | タスク実行結果（実行後に自動設定される）                                       |
| `plan_doc`    | string? | No   | No                    | 計画ドキュメント（**どこからも読まれておらず現在未使用**）                     |

### description の書き方

`description` は Builder（Claude Code / Codex）に**そのまま prompt として渡される主入力**である。
追加で、plan から抽出された `brief` が system prompt として渡される。

```moonbit
// ralph_loop.mbt — Builder 呼び出しのイメージ
let result = backend.run(
    task.description,                           // <- 実行対象タスク
    build_builder_system_prompt(brief),         // <- plan goals / constraints
    fn(e) { handle_event(self, bid, e) },
)
```

したがって、`description` 自体は依然として **Claude Code / Codex に直接指示するのと同じ粒度・具体性** で書く必要がある。

**良い例（具体的で実行可能）:**
```json
{
  "description": "src/db/schema.sql に users テーブルを作成してください。カラムは id (UUID, PK), email (VARCHAR, UNIQUE, NOT NULL), password_hash (VARCHAR, NOT NULL), created_at (TIMESTAMP) です。"
}
```

**悪い例（曖昧すぎる）:**
```json
{
  "description": "スキーマ作成"
}
```

> **Planner 自動生成との比較:** Planner が生成する description は WAVE テキストから
> パースされた1行テキスト（例: `"Create database schema"`）になる。
> 手動で tasks を定義する場合は、より詳細な指示を書けるメリットがある。

> **リワーク時の注意:** リワーク時は `task.description + "\n\nFeedback from verifier:\n" + feedback` が
> prompt になる。Verifier のフィードバックはタスクID指定でルーティングされるため、
> 各タスクは自身に関連するフィードバックのみ受け取る（v0.6.0）。

### 例: タスクを事前定義する場合

Planner を使わず、手動でタスクを定義することもできる:

```json
{
  "milestones": [
    {
      "id": "m1",
      "goal": "データベーススキーマを設計・実装する",
      "status": "pending",
      "current_wave": 0,
      "tasks": [
        {
          "id": "m1-t1",
          "description": "ユーザーテーブルのスキーマを作成",
          "wave": 0,
          "status": "pending"
        },
        {
          "id": "m1-t2",
          "description": "マイグレーションスクリプトを作成",
          "wave": 0,
          "status": "pending"
        },
        {
          "id": "m1-t3",
          "description": "API ハンドラーを実装",
          "wave": 1,
          "status": "pending"
        },
        {
          "id": "m1-t4",
          "description": "認証ミドルウェアを追加",
          "wave": 1,
          "status": "pending"
        }
      ]
    }
  ]
}
```

> **ポイント:** `tasks` が空の場合、Planner エージェントが `goal` を読み取って
> 自動的に WAVE 構造のタスクを生成する。事前にタスクを定義していれば
> Planner はスキップされる。

### 例: 最小構成

```json
{
  "milestones": [
    {
      "id": "m1",
      "goal": "Build a CLI tool that converts CSV files to JSON",
      "status": "pending",
      "tasks": []
    }
  ]
}
```

---

## 6. 3層構造: Milestone > Wave > Task

```
Milestone (目標単位)
  +-- Wave 0 (先行タスク群)
  |     +-- Task m1-t1
  |     +-- Task m1-t2
  +-- Wave 1 (Wave 0 の完了・検証後に実行されるタスク群)
  |     +-- Task m1-t3
  |     +-- Task m1-t4
  +-- Wave 2 ...
```

- **Milestone**: 達成すべき目標。複数定義でき、順番に処理される。
- **Layer**: DAG のトポロジカルレイヤー。依存が解決されたタスクが同一レイヤーに配置される。
- **Task**: 個別の実行単位。`depends_on` で明示的依存を宣言する。

### DAG スケジューリング

タスク間の依存は `depends_on` フィールドで宣言される。Kahn's アルゴリズムでレイヤーを計算し、依存が解決されたタスクからバッチ並列実行する。

**1. タスクの実行順序** (`ralph_loop.mbt`)

同一レイヤーのタスクは `@agent.run_parallel()` でバッチ並列実行される（`--max-in-flight` で同時実行数を制御、デフォルト 3）。レイヤー内の全タスク完了後に依存解決し、次のバッチを構成する。

**2. 検証のタイミング**

全タスク完了後に**マイルストーン単位の一括検証**を実行。4 観点（CodeQuality, Performance, Security, GoalAlignment）を並列で1回だけ実行する。

```
Layer 0 バッチ並列 → Layer 1 バッチ並列 → ... → 全タスク完了
→ マイルストーン検証 (4観点並列) → [NeedsRework なら rework → 再検証]
```

---

## 7. 実行フロー

### 7.1 起動シーケンス

```
1. CLI 解析
2. 設定ロード:
   a. --config 指定あり → ファイル読み込み
   b. --config 指定なし → preset_ralph() を使用
3. CLI オーバーライド適用: --planner, --builder, --verifier の値で agents の kind を上書き
4. 設定バリデーション
5. バックエンド生成: 各エージェントの kind に応じたバックエンドを作成
6. マイルストーンロード:
   a. milestones_path (デフォルト .whirlwind/milestones.json) を読み込み
   b. ファイルがなければ空のマネージャーを作成 → 警告表示して終了
7. RalphLoop 生成・実行
8. 完了後: マイルストーン状態を milestones_path に保存
```

### 7.2 ループ実行フロー

```
RalphLoop::run()
  |
  +-- 各 pending マイルストーンに対して:
  |     |
  |     +-- [Planning] tasks が空なら Planner を実行
  |     |     Planner が goal を WAVE 形式のタスクリストに分解
  |     |
  |     +-- milestone.status = InProgress
  |     |
  |     +-- 未完了タスクがある間:
  |     |     |
  |     |     +-- 最小 Wave 番号を取得
  |     |     |
  |     |     +-- [Executing] Wave 内の各タスクを Builder で実行
  |     |     |     各タスクの結果を記録
  |     |     |
  |     |     +-- [Verifying] Verifier が Wave 結果を検証
  |     |           |
  |     |           +-- Approved → 次の Wave へ
  |     |           +-- NeedsRework → リワーク実行 → 再検証
  |     |           |     (max_rework_attempts まで繰り返し)
  |     |           |     (超過時は強制承認)
  |     |           +-- MilestoneFailed → マイルストーン失敗、次へ
  |     |
  |     +-- 全 Wave 完了 → milestone.status = Done
  |
  +-- AllComplete (全マイルストーン処理完了)
```

### 7.3 アーキテクチャ図

```
CLI
  |
  parse_cli_args()
  |
  run_ralph()
    |-- Load config (whirlwind.json or preset_ralph)
    |-- apply_overrides() [--planner, --builder, --verifier]
    |-- Load milestones (.whirlwind/milestones.json)
    `-- RalphLoop::new()
          |-- backends[Planner, Builder, Verifier]
          |-- MilestoneManager
          `-- run()
                |-- LoadingMilestones
                |     `-- next_pending_milestone() loop
                |           `-- run_milestone(m)
                |                 |-- Planning (Planner agent)
                |                 |     `-- parse_planner_output() -> WAVE
                |                 `-- while has_undone_tasks()
                |                       `-- run_wave(wave_num)
                |                             |-- Executing (Builder agent)
                |                             |     `-- collect_wave_results()
                |                             `-- verify_wave() [recursive]
                |                                   |-- Verifying (Verifier agent)
                |                                   |-- Approved -> next wave
                |                                   |-- NeedsRework(items) -> Reworking
                |                                   |     `-- rework_tasks(feedback routing)
                |                                   |           |-- items にタスクID prefix あり
                |                                   |           |     -> 該当タスクのみリワーク
                |                                   |           `-- prefix なし
                |                                   |                 -> 全タスクにブロードキャスト
                |                                   |     `-- verify_wave(attempt+1)
                |                                   `-- MilestoneFailed -> stop
                `-- AllComplete
```

### 7.4 状態マシン

RalphLoop の状態遷移図は [01-architecture.md のセクション 4](./01-architecture.md) を参照。

---

## 8. 3大エージェントの動作

### 8.1 Planner エージェント

**役割:** マイルストーンの `goal` を具体的なタスクに分解する。

**入力プロンプト構造:**
```
System prompt:
- brief (plan goals + constraints)
- completed milestone summaries

User prompt:
You are a Planner agent. Respond in English.  (--lang=ja なら Japanese)

## Milestone
ID: m1
Goal: Build authentication system

## Instructions
Break down this milestone into concrete tasks grouped by waves.
Tasks in the same wave can be executed independently.
Tasks in later waves depend on earlier waves.

## Output Format
WAVE 0:
1. First task description
2. Second task description

WAVE 1:
1. Task that depends on wave 0
```

**出力パース規則:**
- `WAVE N:` / `wave N:` / `Wave N:` ヘッダーで Wave 番号を認識
- `1. 説明文` (番号付き) または `- 説明文` (箇条書き) でタスクを認識
- 空行は無視される

**出力例:**
```
WAVE 0:
1. Create database schema for users and sessions
2. Write migration scripts

WAVE 1:
1. Build API handlers for authentication endpoints
2. Add JWT middleware
```

→ 4タスク生成: Wave 0 に2タスク, Wave 1 に2タスク

### 8.2 Builder エージェント (Dev ロール)

**役割:** 個々のタスクを実行する。

**入力:** `task.description` がユーザープロンプトとして渡され、`brief` が system prompt として追加される。

**リワーク時の入力（v0.6.0 で改善）:**

```
task.description + "\n\nFeedback from verifier:\n" + "- フィードバック1\n- フィードバック2\n"
```

Verifier のフィードバックはタスクID指定でルーティングされる:
- `"m1-t1: fix error handling"` → タスク `m1-t1` のリワーク時のみ含まれる
- タスクIDプレフィクスがないフィードバック → 全タスクにブロードキャスト

### 8.3 Verifier エージェント

**役割:** マイルストーンの全タスク結果を検証する（v0.9.0 で Wave 単位からマイルストーン単位に変更）。

**入力プロンプト構造:**
```
You are a Verifier agent. Respond in English.

## Milestone
ID: m1
Goal: Build authentication system
Wave: 0

## Wave Results
### Task: m1-t1
(タスクの実行結果)

### Task: m1-t2
(タスクの実行結果)

## Instructions
Verify that all tasks in this wave were completed correctly.
Check code quality, correctness, and alignment with the milestone goal.

## Output Format
Use exactly one of these tags:
- <wave_approved> if all tasks pass verification
- <needs_rework>task_id: reason</needs_rework> for tasks that need fixes
- <milestone_failed>reason</milestone_failed> if the milestone cannot be achieved
```

**出力パース規則:**

| 出力タグ                                   | 判定               | 動作                       |
| ------------------------------------------ | ------------------ | -------------------------- |
| `<wave_approved>`                          | 承認               | 次の Wave へ進む           |
| `<needs_rework>...</needs_rework>`         | 要リワーク         | 失敗タスクを再実行         |
| `<milestone_failed>...</milestone_failed>` | 失敗               | マイルストーンを失敗とする |
| タグなし                                   | 承認（デフォルト） | 次の Wave へ進む           |

**`<needs_rework>` の内容フォーマット:**
```
<needs_rework>
m1-t1: エラーハンドリングを追加してください
m1-t2: テストが不足しています
</needs_rework>
```
改行区切りで複数のリワーク指示を記述できる。

---

## 8A. Planner のタスク分割メカニズム詳解

現在の Ralph は、skill と runtime を分担してタスク分割を行う。
skill はマイルストーン列と `brief` だけを準備し、実際の task / wave 分解は runtime の Planner AI が担当する。

```
Markdown plan
  → ralph-whirlwind skill
    → plan-en.md
    → brief 抽出
    → milestones.json を直接生成
       {
         "brief": "...",
         "milestones": [
           { "id": "m1", "goal": "...", "status": "pending", "summary": "", "tasks": [] }
         ]
       }
  → whirlwind
    → tasks が空の milestone ごとに Planner AI を実行
    → milestone 完了時に summary を生成して milestones.json に書き戻す
```

### 8A.1 `brief` の生成と注入

`brief` は plan 全体から抽出した「目標 + 制約」の要約で、milestones.json のトップレベルに保存される。

```json
{
  "brief": "Build the feature incrementally. Preserve the existing API shape. Add tests for changed behavior.",
  "milestones": [
    { "id": "m1", "goal": "...", "status": "pending", "summary": "", "tasks": [] }
  ]
}
```

runtime はこの `brief` を task description に埋め込まず、必要な agent の system prompt にだけ注入する。
つまり、各 task に plan 全文や補足文脈を複製する方式ではない。

### 8A.2 ralph-whirlwind skill の責務

`/ralph-whirlwind <plan.md>` は Markdown plan を以下の 3 つに変換する。

- `plan-en.md`: plan 全文の英訳版
- `milestones.json`: `brief` と milestone 配列
- `whirlwind.json`: planner / builder / verifier の設定

`references/parse-rules.md` のルールは最小限で、`#` はディレクトリ名、`##` は milestone に対応する。
list 項目や `###` は skill 側では解釈しない。各 milestone は `tasks: []` で初期化される。

`brief` は plan の Context / goals / constraints を短く抽出した背景情報で、Planner / Builder / Rework にだけ渡す。
plan 全文を各 task に複製しないため、旧方式のような task 数に比例したトークン増加を避けられる。

### 8A.3 runtime Planner AI の責務

runtime では `tasks` が空の milestone に対して Planner を実行する。
Planner は milestone goal に加え、`brief` と完了済み milestone の `summary` を system prompt として受け取る。

agent ごとの注入ポリシーは次のとおり。

| Agent      | system prompt に渡すもの              | 理由 |
| ---------- | ------------------------------------- | ---- |
| Planner    | `brief` + 完了済み milestone `summary` | task / wave 分解時に全体目標と既完了内容が必要 |
| Builder    | `brief` のみ                          | 実装の方向性は必要だが、過去 milestone の詳細は不要 |
| Verifier   | 何も渡さない                          | 背景情報がノイズになりやすく、過去に無限リワークの原因になった |
| Rework     | `brief` のみ                          | Builder と同じ。修正対象 task と制約だけで十分 |

重要なのは、`brief` や `summary` を task description へ埋め込まないことだ。
Planner / Builder / Rework には system prompt として渡し、Verifier には渡さない。

### 8A.4 milestone `summary` の動的蓄積

milestone 完了時、runtime はその milestone の完了 task description を連結して `summary` を生成する。
この `summary` は `milestones.json` に書き戻され、次の milestone の Planner 実行時にだけ利用される。

役割は次のとおり。

- 先行 milestone で何を実装済みかを Planner に伝える
- plan 全文の再注入なしで、進捗に沿った task 分割を可能にする
- Builder / Verifier の入力を不必要に膨らませない

つまり `summary` は静的な plan 抜粋ではなく、実行結果に応じて増えていく milestone 間の引き継ぎ情報である。

### 8A.5 `project_context` を導入しない理由

repository 情報を別の `project_context` として手動注入する設計は採用していない。

- Claude Code は `cwd` から `CLAUDE.md` を自動で読む
- Codex は `workingDirectory` から `AGENTS.md` を自動で読む
- 言語、フレームワーク、ディレクトリ構造は各 agent が実行時に探索できる
- 静的な project snapshot は実装途中のファイル追加・削除とずれやすい

このため、skill / runtime が追加で持つ文脈は `brief` と milestone `summary` に限定する。

静的な repository snapshot を別チャネルで持ち回るより、agent 自身が実行時の working directory を探索する方が実態に追従しやすい。

### 8A.6 実行モデル

Wave の意味自体は従来どおりで、Planner が `WAVE N:` 形式で task 群を返し、runtime がそれを構造化する。
違いは、Wave 構造を plan Markdown から人間が前もって埋めるのではなく、runtime Planner が現在の progress を見て都度生成する点にある。

---

## 9. エージェント間データ受け渡しとフィードバックルーティング

### 9.1 Planner -> Builder

WAVEテキスト形式:
```
WAVE 0:
1. Create database schema
2. Write migration scripts

WAVE 1:
1. Build API handlers
2. Add authentication
```

パース: `MilestoneManager::parse_planner_output()` が
WAVE ヘッダーと番号付き/箇条書きリストを解析

### 9.2 Builder -> Verifier

タスク結果の配列:
```
[(task_id: "m1-t1", result: "Schema creation output..."),
 (task_id: "m1-t2", result: "Migration output...")]
```

### 9.3 Verifier -> RalphLoop

XMLタグベース判定:
- `<wave_approved>` -> Approved
- `<needs_rework>m1-t1: fix error\nm1-t2: add validation</needs_rework>` -> NeedsRework
- `<milestone_failed>Architecture fundamentally flawed</milestone_failed>` -> Failed

### 9.4 RalphLoop -> Builder (リワーク時)

v0.6.0 でフィードバックルーティングを実装:

**フィードバックマッチング:** 各フィードバック項目がタスクIDプレフィクスを持つか判定
- `"m1-t1: fix error handling"` → タスク `m1-t1` にマッチ（コロン区切り）
- `"m1-t1 needs better validation"` → タスク `m1-t1` にマッチ（スペース区切り）

**ターゲット指定 vs ブロードキャスト:**
- いずれかのフィードバックがタスクIDにマッチ → マッチしたタスクのみ `Pending` にリセット
- どのフィードバックもタスクIDにマッチしない → 全 `Done` タスクを `Pending` にリセット（フォールバックブロードキャスト）

**プレフィクス除去:** `strip_task_feedback_prefix()` がタスクIDプレフィクスを除去
- `"m1-t1: fix error handling"` → `"fix error handling"`

**リワークプロンプト構築:**
```
task.description + "\n\nFeedback from verifier:\n" + "- feedback1\n- feedback2\n"
```

---

## 10. 制御パラメータと終了条件

### 10.1 制御パラメータ

| パラメータ                      | デフォルト | 効果                                              |
| ------------------------------- | ---------- | ------------------------------------------------- |
| `max_rework_attempts`           | 3          | Wave ごとのリワーク最大回数。超過すると強制承認。 |
| `max_iterations` (エージェント) | 10         | 各エージェント内部の反復上限                      |

### 10.2 終了条件

| レベル        | 終了条件                         | 動作                            |
| ------------- | -------------------------------- | ------------------------------- |
| Milestone     | next_pending_milestone() == None | AllComplete                     |
| Wave          | has_undone_tasks() == false      | MilestoneComplete               |
| Rework        | attempt >= max_rework_attempts   | 強制承認                        |
| Milestone失敗 | `<milestone_failed>` 検出        | milestone.status = Failed, 次へ |

### 10.3 リワーク動作の詳細

1. Verifier が `NeedsRework(items)` を返す（items は `["m1-t1: fix error", "m1-t2: add tests"]` 形式）
2. `rework_tasks()` がフィードバックをルーティング:
   - 各フィードバック項目のタスクIDプレフィクスを判定（`"m1-t1:"` or `"m1-t1 "` 形式）
   - マッチするタスクのみ `Pending` にリセット（ターゲット指定モード）
   - マッチするタスクがない場合は全 `Done` タスクを `Pending` にリセット（ブロードキャストモード）
3. 各タスクに対し、関連するフィードバックを含むリワークプロンプトで再実行
4. 再度 `verify_wave()` を呼び出し（attempt + 1）- **再帰呼び出し**
5. `attempt >= max_rework_attempts` の場合 → 強制承認（`true` を返す）
6. 再び `NeedsRework` なら上記を繰り返す

---

## 11. 永続化とレジューム

### JSON 形式 (.whirlwind/milestones.json)

```json
{
  "milestones": [
    {
      "id": "m1",
      "goal": "Build auth",
      "status": "done",
      "current_wave": 0,
      "tasks": [
        {
          "id": "m1-t1",
          "description": "Create schema",
          "wave": 0,
          "status": "done",
          "result": "Schema created successfully...",
          "plan_doc": null
        }
      ]
    }
  ]
}
```

### API

- `MilestoneManager::load_from_json()` でロード
- `MilestoneManager::to_json()` でシリアライズ
- ロード時に `max(task_id)` から `next_task_id` を復元

### レジューム

マイルストーンファイルにはタスクの `status` が保存されるため、
中断後に再実行すると `pending` / `in_progress` のマイルストーンから処理が再開される。

- `status: "done"` のマイルストーンはスキップされる
- `status: "failed"` のマイルストーンもスキップされる
- `status: "pending"` / `"in_progress"` のマイルストーンが処理対象

> **Note:** 途中で Ctrl+C した場合は保存されない可能性がある
> （`run()` 完了後に `write_file_sync` で保存するため）。

---

## 12. 設定ファイルサンプル集

### 最小構成（Planner + Builder のみ、Verifier なし）

```json
{

  "agents": [
    { "id": "planner", "kind": "claude-code", "role": "planner" },
    { "id": "builder", "kind": "claude-code", "role": "dev" }
  ]
}
```

> Verifier がない場合、Wave は自動承認される。

### フル構成（3エージェント + カスタム設定）

```json
{
  "project_dir": "/path/to/project",
  "review_dir": "docs/reviews",

  "milestones_path": "milestones/plan.json",
  "max_rework_attempts": 5,
  "agents": [
    {
      "id": "planner",
      "kind": "claude-code",
      "role": "planner",
      "system_prompt": "You are an expert software architect.",
      "max_iterations": 10
    },
    {
      "id": "builder",
      "kind": "claude-code",
      "role": "dev",
      "working_dir": ".",
      "max_iterations": 15
    },
    {
      "id": "verifier",
      "kind": "codex",
      "role": "verifier",
      "max_iterations": 5
    }
  ]
}
```

### Codex を Builder に使う構成

```json
{

  "agents": [
    { "id": "planner", "kind": "claude-code", "role": "planner" },
    { "id": "builder", "kind": "codex", "role": "dev" },
    { "id": "verifier", "kind": "claude-code", "role": "verifier" }
  ]
}
```

---

## 13. 既知の制限事項と残存課題

### 14.1 ~~Verifier フィードバックが Builder に渡されない~~ → v0.6.0 で解決済み

**v0.6.0 で実装完了。** `rework_tasks()` はターゲット指定のフィードバックルーティングを実装:

- Verifier の `NeedsRework` フィードバックはタスクID指定で各タスクにルーティング
- タスクIDプレフィクスがない汎用フィードバックは全タスクにブロードキャスト
- リワークプロンプト: `task.description + "\n\nFeedback from verifier:\n" + feedback`
- 5つのユニットテストで動作を検証済み（`ralph_loop_test.mbt`）

### 14.2 DAG バッチ並列実行

同一レイヤーのタスクは `@agent.run_parallel()` でバッチ並列実行される。`--max-in-flight=N` で同時実行数を制御（デフォルト 3）。単一タスクバッチではサーバーエラーリトライが自動適用される。

### 14.3 途中中断時の状態保存

マイルストーンの状態保存は `RalphLoop::run()` 完了後に行われるため、
Ctrl+C で中断した場合は途中結果が失われる可能性がある。

### 14.4 マイルストーンの動的追加・削除は未対応

実行中にマイルストーンを追加・削除することはできない。
事前にファイルで定義する必要がある。

### 14.5 `--review` オプションが Ralph モードで効かない

`apply_overrides()` は `Review` ロールのエージェントのみ `--review` で上書きする。
しかし Ralph モードの Verifier は `Verifier` ロールであり `Review` ロールではないため、
`--review` は素通りして無視される。

**根本原因: `Review` と `Verifier` は別のロール値である。**

```moonbit
// types.mbt — AgentRole の定義
pub(all) enum AgentRole {
  Builder
  Review
  Planner
  Verifier
}
```

`apply_overrides()` のマッチング自体は `Dev` も `Review` も同じ構造だが、
Ralph モードには `Review` ロールのエージェントが1つも存在しないため
`Review =>` のブランチを通るエージェントがいない:

```moonbit
// cli.mbt:59-72 — apply_overrides() 内のループ
for agent in config.agents {
    let kind = match agent.role {
      Dev    => dev_kind ...     // Builder (role=Dev) がここにマッチ → --dev で上書き
      Review => review_kind ...  // <- Ralph モードでは誰もここに来ない
      _      => agent.kind       // Planner (role=Planner), Verifier (role=Verifier) はここ
    }
}
```

Ralph プリセットの3エージェントがそれぞれどこにマッチするか:

```text
agent="planner"  (role=Planner)  → _ => agent.kind    変更なし
agent="builder"  (role=Dev)      → Dev => --dev の値   上書きされる
agent="verifier" (role=Verifier) → _ => agent.kind    変更なし
```

| エージェント | ロール   | `--dev`        | `--review`     |
| ------------ | -------- | -------------- | -------------- |
| Planner      | Planner  | 無視           | 無視           |
| Builder      | Dev      | **適用される** | 無視           |
| Verifier     | Verifier | 無視           | **無視される** |

**回避策:** Verifier（および Planner）の種類を変更するには設定ファイル (`whirlwind.json`) で直接指定する:

```json
{
  "agents": [
    { "id": "planner", "kind": "claude-code", "role": "planner" },
    { "id": "builder", "kind": "claude-code", "role": "dev" },
    { "id": "verifier", "kind": "claude-code", "role": "verifier" }
  ]
}
```

### 14.6 Ralph 固有の未使用設定項目

`review_interval` と `max_review_cycles` は設定ファイルに記述可能だが、現在のRalphモードでは使われない。

### 14.7 Verifier サイレント承認バグ

Verifier バックエンドが障害を起こした場合（レートリミット、ネットワークエラー、クラッシュ等）、
結果は `Approved` にフォールバックする（`verifier.mbt:107`）。
Review モジュールでは同様のバグが修正済み（`Rejected` を返すように変更）だが、
Verifier にはまだ適用されていない。

### 14.8 その他

- DAG バッチ並列実行: 依存解決済みタスクは `@agent.run_parallel()` でバッチ並列実行される（v0.3.0）。検証は全タスク完了後にマイルストーン単位で実行される
- `review_interval` が Config で定義されるが Ralph では未使用
- `current_wave` フィールドが resume 機能の準備か不明
- プログレッシブなマイルストーン追加/削除は未対応

---

## 14. 機能進化 (コミット履歴)

| Phase | コミット        | 日付       | 機能                                                           |
| ----- | --------------- | ---------- | -------------------------------------------------------------- |
| 1     | 54cab0c         | 2026-02-20 | 基盤: Orchestrator (Decompose -> Assign -> Execute -> Review)  |
| 2     | 2da99c4-4a0af97 | 2026-02-20 | 自律化: Iteration, 3-perspective review                        |
| 3     | b82f97d-cbea064 | 2026-02-20 | 改善: RLM mode, --lang                                         |
| 4     | f66a8cd         | 2026-03-02 | Ralph: Milestone-driven autonomous development                 |
| 5     | 9ef81d8-5fff019 | 2026-03-07 | ドキュメント: docs/00-06 作成                                  |
| 6     | e9063b4-825b08e | 2026-03-07 | ralph-whirlwind: skill 化とコンテキスト受け渡しの最適化          |
| 7     | 64b65b3         | 2026-03-20 | フィードバックルーティング: rework_tasks() に実装 + 5テスト    |
| 8     | 79ffad4         | 2026-03-20 | パッケージ名変更: @mizchi/whirlwind → @ymdvsymd/whirlwind (v0.6.0) |
| 9     | d10235a         | 2026-03-20 | ralph-whirlwind スキル化: コマンドから `.claude/skills/` へ移行  |
