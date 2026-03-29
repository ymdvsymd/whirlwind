---
name: plan-to-beads
description: >
  計画ファイル(~/.claude/plans/)を解析し、各ステップをbdチケットとして一括起票する。
  構造化フォーマット（rules/planning.md 準拠）から直接マッピング。
  "plan-to-beads", "計画チケット化", "plan tickets", "bd create from plan", "計画をチケットに".
argument-hint: plan_name:計画ファイル名またはフルパス
origin: whirlwind
---

# plan-to-beads: 計画ファイルから bd チケット一括起票

## 引数

```
/plan-to-beads <plan-name> [--priority=<0-4>] [--needs-review] [--type=<task|feature>] [--dry-run]
```

- `<plan-name>`: `~/.claude/plans/` 内のファイル名（`.md` 省略可）またはフルパス
- `--priority=<0-4>`: 全ステップのデフォルト優先度（計画レベルメタデータより優先）
- `--needs-review`: 全チケットに `needs-review` ラベルを付与（計画レベルメタデータより優先）
- `--type=<task|feature>`: チケット種別のフォールバック（デフォルト: `task`）
- `--dry-run`: プレビューのみ、チケット作成なし

`$ARGUMENTS` の内容: `$ARGUMENTS`

## 前提: 計画フォーマット

計画ファイルは `rules/planning.md` の「bd チケット対応計画フォーマット」に準拠していること。

各ステップは以下の構造を持つ:

```markdown
## Step N: <タイトル>

- **Type**: task | feature | bug
- **Priority**: P0-P4
- **Target files**:
  - `<file-path>` -- <変更概要>
- **Depends on**: Step M | none

### 概要 | 原因
<内容>

### 実装方針 | 修正方針
<内容>

### AC
- <条件>
```

## オーケストレーション概要

1. **計画ファイル解決・読み込み** — パス解決、存在確認、内容読み込み
2. **ステップ抽出・バリデーション** — 構造化フォーマットからフィールド抽出、必須チェック
3. **プレビュー・確認** — 既存チケットスキャン、プレビューテーブル、ユーザー承認
4. **チケット作成・サマリー** — `bd create` + `bd dep add` + 完了報告

各フェーズを**必ず順番に**実行すること。

---

### Phase 1: 計画ファイル解決・読み込み

1. `$ARGUMENTS` を解析する:
   - 最初の `--` で始まらないトークンを `PLAN_NAME` とする
   - `--priority=<value>` があれば `CLI_PRIORITY` に格納（未指定なら未設定）
   - `--needs-review` があれば `CLI_NEEDS_REVIEW=true`（未指定なら未設定）
   - `--type=<value>` があれば `CLI_TYPE` に格納（デフォルト: `task`）
   - `--dry-run` があれば `DRY_RUN=true`
   - 引数が空、または `PLAN_NAME` が見つからない場合はエラーメッセージを出して終了

2. 計画ファイルのパスを解決:
   - `PLAN_NAME` が `/` で始まる → そのまま絶対パスとして使用
   - `PLAN_NAME` が `~` で始まる → ホームディレクトリに展開
   - それ以外 → `~/.claude/plans/<PLAN_NAME>` を構築
   - `.md` で終わらない場合は `.md` を付与
   - 結果を `PLAN_PATH` に格納

3. `PLAN_PATH` の存在を確認。存在しない場合:

   ```bash
   ls -1 ~/.claude/plans/*.md | tail -20
   ```

   利用可能な計画ファイル一覧を表示し、「計画ファイルが見つかりません: <PLAN_PATH>」と報告して終了。

4. 計画ファイルの全内容を読み込み、`PLAN_CONTENT` に格納する。

---

### Phase 2: ステップ抽出・バリデーション

#### 2-1. 計画レベルメタデータの抽出

`## Context` セクションから以下を検索:

- `Priority:\s*P?([0-4])` → `PLAN_PRIORITY` に格納
- `needs-review:\s*(yes|true|no|false)` → `PLAN_NEEDS_REVIEW` に格納

#### 2-2. 計画タイトルの抽出

最初の `# ` 見出しを `PLAN_TITLE` として記録する。

#### 2-3. コンテキストの抽出

`## Context` セクションの本文（メタデータ行を除く）を `PLAN_CONTEXT` として記録する。

#### 2-4. ステップ抽出

正規表現 `^##\s+Step\s+(\d+)[:：]\s*(.+)$` でステップ見出しを検出する。
コードブロック（` ``` ` 〜 ` ``` `）内の行はスキップする。

各マッチについて:
- `step_number`: キャプチャグループ1
- `title`: キャプチャグループ2
- `body`: この見出しから次の `## ` 見出しまでの本文

ステップ数が 0 の場合:
「計画からステップを抽出できませんでした。`rules/planning.md` の bd チケット対応計画フォーマットに準拠しているか確認してください。」と報告して終了。

#### 2-5. インラインメタデータの抽出

各ステップの `body` から以下を抽出:

| フィールド | パターン | 格納先 |
|-----------|---------|--------|
| Type | `^\s*-\s+\*\*Type\*\*:\s*(.+)$` | `STEPS[i].type` |
| Priority | `^\s*-\s+\*\*Priority\*\*:\s*P?([0-4])$` | `STEPS[i].priority` |
| Target files | `^\s*-\s+\` で始まるインデント行（`**Target files**:` の後） | `STEPS[i].target_files` |
| Depends on | `^\s*-\s+\*\*Depends on\*\*:\s*(.+)$` | `STEPS[i].depends_on` |

#### 2-6. サブセクションの抽出

各ステップの `body` から `### ` 見出しでサブセクションを分割:

- `### 概要` or `### 原因` → `STEPS[i].description_main`
- `### 実装方針` or `### 修正方針` → `STEPS[i].description_plan`
- `### AC` → `STEPS[i].ac`

#### 2-7. 有効値の決定

各ステップについて、以下の優先順で有効値を決定:

| フィールド | 優先順位 |
|-----------|---------|
| type | ステップ内 → `CLI_TYPE` → `task` |
| priority | ステップ内 → `CLI_PRIORITY` → `PLAN_PRIORITY` |
| needs-review | `CLI_NEEDS_REVIEW` → `PLAN_NEEDS_REVIEW` → `false` |

#### 2-8. 必須フィールドバリデーション

各ステップについて以下をチェック:

| フィールド | 条件 | エラー時の扱い |
|-----------|------|--------------|
| AC | `STEPS[i].ac` が空 | **エラー**: 「Step N の AC が未定義です」 |
| Priority | 有効優先度が未決定 | **確認**: ユーザーにデフォルト優先度を質問 |
| Target files | `STEPS[i].target_files` が空 | **警告**: プレビューに表示（起票は続行） |

AC が欠落しているステップが1つでもある場合:
「以下のステップに AC がありません。計画ファイルを修正するか、AC を入力してください。」と報告し、ステップ番号を一覧表示。`AskUserQuestion` で補足を求める。

---

### Phase 3: プレビュー・確認

#### 3-1. 既存チケットスキャン

`rules/bd-dependency-protocol.md` の Step 1-2 に従い、既存チケットとの重複・依存を確認する。

```bash
bd list --status=open
bd list --status=in_progress
```

各ステップのタイトルと対象ファイルを既存チケットと照合し:
- 重複候補 → `DUPLICATES` に格納
- 既存依存候補 → `CROSS_DEPS` に格納

重複候補がある場合、`rules/bd-dependency-protocol.md` Step 2 の形式でユーザーに確認する。

#### 3-2. プレビューテーブル

```markdown
## plan-to-beads 起票プレビュー

**計画**: <PLAN_TITLE>
**計画ファイル**: <PLAN_PATH>
**ステップ数**: <N>
**デフォルト優先度**: P<N>
**needs-review**: yes / no

| # | タイトル | Type | 優先度 | AC (要約) | Depends on | 備考 |
|---|---------|------|--------|-----------|------------|------|
| 1 | Step 1: ... | task | P2 | ... | - | |
| 2 | Step 2: ... | feature | P2 | ... | Step 1 | |
```

- `DRY_RUN=true` の場合: プレビューを表示して終了
- `DRY_RUN=false` の場合: 「この内容でチケットを起票しますか？ (yes/no)」

---

### Phase 4: チケット作成・サマリー

#### 4-1. チケット作成

`CREATED_IDS` マップ（step_number → ticket_id）を初期化する。

各 `STEPS[i]` について:

1. **description の構築**:

   ```
   ## コンテキスト
   <PLAN_CONTEXT の先頭 3 行>

   ## 概要（or 原因）
   <STEPS[i].description_main>

   ## 実装方針（or 修正方針）
   <STEPS[i].description_plan>

   ## 対象ファイル
   <STEPS[i].target_files>
   ```

2. **`bd create` の実行**:

   ```bash
   bd create --title="<STEPS[i].title>" \
     --description="<description>" \
     --type=<STEPS[i].type の有効値> \
     --priority=<STEPS[i].priority の有効値> \
     --acceptance="<STEPS[i].ac>" \
     --notes="計画: <PLAN_PATH>" \
     --labels=needs-review \
     --silent
   ```

   - `--labels=needs-review` は `needs-review=true` のステップのみ付与
   - `--silent` で出力されるチケットIDを `CREATED_IDS[i]` に記録

#### 4-2. 依存関係の設定

1. **計画内依存（Depends on フィールドから）**:

   各ステップの `STEPS[i].depends_on` を解析:
   - `Step M` の言及 → `bd dep add <CREATED_IDS[i]> <CREATED_IDS[M]>`
   - `none` → スキップ
   - 複数の依存（`Step M, Step K`）→ 各依存について `bd dep add` を実行

2. **既存チケットとの依存（Phase 3 の CROSS_DEPS から）**:

   ```bash
   bd dep add <CREATED_IDS[i]> <existing-id>
   ```

#### 4-3. エラー処理

| シナリオ | アクション |
|---------|----------|
| `bd create` 失敗 | エラーを記録し、そのステップをスキップして次へ続行 |
| `bd dep add` 失敗 | 警告を記録し、続行（チケットは作成済みだが未リンク） |

#### 4-4. 完了サマリー

```markdown
## plan-to-beads 起票完了

**計画**: <PLAN_TITLE>
**起票数**: <成功数> / <全ステップ数>

| # | チケットID | タイトル | Type | 優先度 | AC (要約) | 依存先 |
|---|-----------|---------|------|--------|-----------|--------|
| 1 | whirlwind-xxx | ... | task | P2 | ... | - |
| 2 | whirlwind-yyy | ... | feature | P2 | ... | whirlwind-xxx |

### 失敗（あれば）

| # | タイトル | エラー |
|---|---------|--------|

### 次のステップ

- `bd show <id>` で個別チケットの詳細確認
- `/bd-runner` でチケットを自動実行
```

失敗したステップがなければ「失敗」セクションは省略する。

---

## エラーハンドリング

| シナリオ | アクション |
|---------|----------|
| 引数が空 | 使用方法を表示して終了 |
| 計画ファイルが見つからない | 利用可能な計画ファイル一覧を表示して終了 |
| 計画ファイルが空 | 「計画ファイルが空です」と報告して終了 |
| ステップ抽出 0 件 | フォーマット準拠を促すメッセージを表示して終了 |
| AC 欠落 | 該当ステップを報告、ユーザーに補足を求める |
| `bd create` 失敗（個別） | エラーを記録、残りは続行、サマリーに表示 |
| `bd dep add` 失敗 | 警告を記録、続行 |
| ユーザーが確認で `no` | 「起票を中止しました」と報告して終了 |

## 関連スキル

- **bd-runner** — plan-to-beads で起票したチケットを自動実行するオーケストレーター
- **bd-detail** — 起票後のチケットを精緻化。plan-to-beads の起票内容が不十分な場合に補完する
- **log-audit** — 実行チェーンの終端。plan-to-beads → bd-runner → log-audit の流れでログを分析する
- **moonbit-audit** — コード規約チェックからのチケット起票。plan-to-beads と同じ依存関係プロトコルを使用する
