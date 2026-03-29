---
name: plan-to-beads
description: >
  計画ファイル(~/.claude/plans/)を解析し、各ステップをbdチケットとして一括起票する。
  優先度・needs-reviewの自動検出とACバリデーション、依存関係の設定、サマリー表示を行う。
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
- `--priority=<0-4>`: 全ステップのデフォルト優先度。省略かつ計画に記載なし → ユーザーに確認
- `--needs-review`: 全チケットに `needs-review` ラベルを付与。省略かつ計画に記載なし → ユーザーに確認
- `--type=<task|feature>`: チケット種別（デフォルト: `task`）
- `--dry-run`: プレビューのみ、チケット作成なし

`$ARGUMENTS` の内容: `$ARGUMENTS`

## オーケストレーション概要

1. **計画ファイル解決・読み込み** — パス解決、存在確認、内容読み込み
2. **ステップ解析** — 3パターンで計画からステップを抽出
3. **メタデータ解決** — 優先度・needs-review の検出、欠落時はユーザーに確認
4. **AC バリデーション** — 各ステップの AC が明確か検証、不十分ならユーザーに補足要求
5. **プレビュー・確認** — 起票内容のテーブル表示、ユーザー承認
6. **チケット作成** — `bd create` + `bd dep add` で依存関係設定
7. **完了サマリー** — 作成結果の一覧表示

各フェーズを**必ず順番に**実行すること。

---

### Phase 1: 計画ファイル解決・読み込み

1. `$ARGUMENTS` を解析する:
   - 最初の `--` で始まらないトークンを `PLAN_NAME` とする
   - `--priority=<value>` があれば `CLI_PRIORITY` に格納（未指定なら未設定）
   - `--needs-review` があれば `CLI_NEEDS_REVIEW=true`（未指定なら未設定）
   - `--type=<value>` があれば `TYPE` に格納（デフォルト: `task`）
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

### Phase 2: ステップ解析

計画ファイルからステップ（チケット化する単位）を抽出する。

#### 2-1. 除外セクションの特定

以下のセクション見出しはステップとして扱わない（メタデータセクション）:

- `Context` / `コンテキスト` / `背景`
- `検証` / `Verification` / `Verification Steps`
- `参照` / `参照ファイル` / `Critical Files` / `References`
- `設計` / `Design`
- `成果物` / `Output`
- `引数` / `Arguments`
- `エラーハンドリング` / `Error Handling`

#### 2-2. 計画タイトルの抽出

最初の `# ` 見出しを `PLAN_TITLE` として記録する。

#### 2-3. コンテキストの抽出

`## Context` セクション（または類似セクション名）の本文を `PLAN_CONTEXT` として記録する。
チケットの description に共通プレフィックスとして使用する。

#### 2-4. 検証セクションの抽出

`## 検証` / `## Verification` セクションの内容を `VERIFICATION_ITEMS` として記録する。
Phase 3.5 の AC 導出で使用する。

#### 2-5. ステップ抽出（3パターン、優先順位順に試行）

以下の3パターンを上から順に試行し、**最初にマッチしたパターン**を採用する。
コードブロック（` ``` ` 〜 ` ``` `）内の行はすべてスキップする。

**パターン A: `## Step N:` / `### Step N:` 見出し**

正規表現: `^#{2,3}\s+Step\s+(\d+)[:：]\s*(.+)$`

各マッチについて:
- `step_number`: キャプチャグループ1
- `title`: キャプチャグループ2
- `body`: この見出しから次の同レベル以上の見出し（または除外セクション）までの本文

**パターン B: `### N.` / `### N:` 番号付きサブセクション**

正規表現: `^#{2,3}\s+(\d+)[.：:]\s*(.+)$`

除外セクション見出しにマッチした行はスキップする。
各マッチについて:
- `step_number`: キャプチャグループ1
- `title`: キャプチャグループ2
- `body`: この見出しから次の番号付き見出し（または除外セクション）までの本文

**パターン C: トップレベル番号リスト**

正規表現: `^(\d+)\.\s+(.+)$`（行頭、コードブロック外、インデントなし）

メインコンテンツセクション（`## 変更内容`、`## Approach`、`## 実装ステップ` 等）内の番号リストのみ対象とする。
各マッチについて:
- `step_number`: キャプチャグループ1
- `title`: キャプチャグループ2
- `body`: 同じ行のタイトル以降 + 後続のインデント行（次の番号リスト項目まで）

#### 2-6. 抽出結果の記録

各ステップを以下の構造で `STEPS` リストに格納:

```
STEPS[i] = {
  step_number: <integer>,
  title: <string>,
  body: <string>,
  per_step_priority: <integer|null>,   # Phase 3 で検出
  per_step_needs_review: <bool|null>,  # Phase 3 で検出
  ac: <string|null>                    # Phase 3.5 で導出
}
```

抽出ステップ数が 0 の場合:
「計画からステップを抽出できませんでした。計画ファイルの形式を確認してください。」と報告して終了。

---

### Phase 3: メタデータ解決

#### 3-1. 優先度の検出

1. **グローバルアノテーション検出**: `PLAN_CONTENT` 全体から以下を検索:
   - `Priority:\s*P?([0-4])` （大文字小文字不問）
   - `優先度:\s*P?([0-4])`
   - マッチすれば `GLOBAL_PRIORITY` に格納

2. **ステップ内アノテーション検出**: 各 `STEPS[i].body` から同じパターンを検索:
   - マッチすれば `STEPS[i].per_step_priority` に格納

3. **有効優先度の決定**（各ステップについて、先勝ち）:
   a. `STEPS[i].per_step_priority`（ステップ内アノテーション）
   b. `CLI_PRIORITY`（CLI 引数）
   c. `GLOBAL_PRIORITY`（計画のグローバルアノテーション）
   d. **すべて未設定** → `PRIORITY_MISSING=true`

4. `PRIORITY_MISSING=true` の場合、ユーザーに確認:

   `AskUserQuestion` で質問:
   「計画に優先度の指定がありません。全ステップのデフォルト優先度を設定してください (0-4, 0=最高 4=バックログ):」

   回答を `DEFAULT_PRIORITY` に格納し、未設定のステップに適用する。

#### 3-2. needs-review の検出

1. **グローバルアノテーション検出**: `PLAN_CONTENT` 全体から以下を検索:
   - `needs-review:\s*(yes|true|はい)` → `GLOBAL_NEEDS_REVIEW=true`
   - `needs-review:\s*(no|false|いいえ)` → `GLOBAL_NEEDS_REVIEW=false`
   - `レビュー:\s*(必要|yes|true)` → `GLOBAL_NEEDS_REVIEW=true`
   - `レビュー:\s*(不要|no|false)` → `GLOBAL_NEEDS_REVIEW=false`

2. **ステップ内アノテーション検出**: 各 `STEPS[i].body` から同じパターンを検索。

3. **有効 needs-review の決定**（各ステップについて、先勝ち）:
   a. `STEPS[i].per_step_needs_review`
   b. `CLI_NEEDS_REVIEW`
   c. `GLOBAL_NEEDS_REVIEW`
   d. **すべて未設定** → `NEEDS_REVIEW_MISSING=true`

4. `NEEDS_REVIEW_MISSING=true` の場合、ユーザーに確認:

   `AskUserQuestion` で質問:
   「計画に needs-review の指定がありません。チケットに needs-review ラベルを付与しますか？ (yes/no):」

   回答を `DEFAULT_NEEDS_REVIEW` に格納し、未設定のステップに適用する。

---

### Phase 3.5: AC バリデーション

各ステップから明確な AC（Acceptance Criteria）を導出できるか検証する。

規約: 「bdチケット作成時は、すぐ実装着手できる精度で作成すること。AC を必ず含める。曖昧なチケットは禁止。」

#### 3.5-1. AC 自動導出

各 `STEPS[i]` について、以下のルールで AC を生成する:

1. **ステップ本文に検証可能な記述がある場合**:
   - コマンド実行（`just test`、`just live` 等）の言及 → 「`<command>` がパスすること」を AC に含める
   - ファイル変更の言及（`src/xxx.mbt` 等のパス） → 「`<file>` の該当箇所が更新されていること」
   - テスト追加の言及 → 「リグレッションテストが追加されパスすること」

2. **`VERIFICATION_ITEMS` との対応**:
   - ステップのタイトルやキーワードが `VERIFICATION_ITEMS` 内の項目と対応する場合、
     その検証項目の文言を AC に含める

3. **コード変更ステップの共通 AC**:
   - ステップ本文にファイルパスやコードブロックを含む場合:
     「変更対象ファイルの該当箇所が更新されていること」+「`just test` がパスすること」
   - ただし、変更対象ファイルが `.claude/`、`docs/`、または CI 設定のみの場合は `just test` / `just live` を AC に含めない

4. 上記で AC が生成できた場合 → `STEPS[i].ac` に格納

#### 3.5-2. AC 曖昧判定

以下のいずれかに該当するステップは AC が不十分と判定する:

- `STEPS[i].ac` が未生成（上記ルールでマッチなし）
- `STEPS[i].body` が 1 行以下で具体的な変更内容が読み取れない
- `STEPS[i].body` に「検討する」「調査する」「確認する」等のアクション不明確な動詞のみ含まれ、
  具体的な成果物（ファイル変更、テスト追加等）の言及がない
- 対象ファイルやモジュールの言及がまったくない

#### 3.5-3. 不十分な AC への対応

AC が不十分と判定されたステップがある場合:

1. 該当ステップの一覧を表示:

   ```markdown
   ## AC バリデーション警告

   以下のステップは AC が曖昧です。各ステップの完了条件を具体化してください:

   | # | タイトル | 理由 |
   |---|---------|------|
   | 2 | API エンドポイント設計 | 具体的な成果物の言及なし |
   | 4 | パフォーマンス検討 | アクション不明確（「検討する」のみ） |
   ```

2. `AskUserQuestion` で AC の補足を求める:
   「上記ステップの完了条件を補足してください。例: 'Step 2: OpenAPI spec が作成されていること, Step 4: レスポンス time < 200ms'。そのままで良い場合は 'ok' と回答してください:」

3. ユーザーの回答に応じた処理:
   - 補足が提供された → 該当ステップの `STEPS[i].ac` を更新
   - `ok` / そのまま → 警告付きでフォールバック AC を使用

4. **AC フォールバック値**（最低限）:
   - 変更対象が `.claude/`、`docs/`、または CI 設定のみの場合: 「ステップの記述内容が反映されていること」
   - それ以外: 「ステップの記述内容が実装され、`just test` がパスすること」

---

### Phase 4: プレビュー・ユーザー確認

起票内容のプレビューテーブルを表示する:

```markdown
## plan-to-beads 起票プレビュー

**計画**: <PLAN_TITLE>
**計画ファイル**: <PLAN_PATH>
**ステップ数**: <N>
**デフォルト優先度**: P<N>
**needs-review**: yes / no

| # | タイトル | 優先度 | needs-review | AC (要約) | 依存先 |
|---|---------|--------|-------------|-----------|--------|
| 1 | Step 1: ... | P2 | - | ... | - |
| 2 | Step 2: ... | P2 | yes | ... | Step 1 |
| 3 | Step 3: ... | P1 | - | ... | Step 2 |
```

- `DRY_RUN=true` の場合: プレビューを表示して終了（ユーザー確認なし）

- `DRY_RUN=false` の場合: ユーザーに確認を求める:
  「この内容でチケットを起票しますか？ (yes/no)」

  - `yes` → Phase 5 へ
  - `no` → 「起票を中止しました」と報告して終了

---

### Phase 5: チケット作成

各ステップを順番に bd チケットとして起票する。
`CREATED_IDS` マップ（step_number → ticket_id）を初期化する。

各 `STEPS[i]` について:

1. **description の構築**:

   ```
   ## コンテキスト
   <PLAN_CONTEXT の先頭 3 行>

   ## 内容
   <STEPS[i].body>
   ```

2. **`bd create` の実行**:

   ```bash
   bd create --title="<STEPS[i].title>" \
     --description="<description>" \
     --type=<TYPE> \
     --priority=<STEPS[i] の有効優先度> \
     --acceptance="<STEPS[i].ac>" \
     --notes="計画: <PLAN_PATH>" \
     --labels=needs-review \
     --silent
   ```

   - `--labels=needs-review` は `needs-review=true` のステップのみ付与
   - `needs-review=false` のステップでは `--labels` フラグ自体を省略
   - `--silent` で出力されるチケットIDを `CREATED_IDS[i]` に記録

3. **依存関係の設定**（2番目以降のステップ）:

   `i >= 2` の場合:

   ```bash
   bd dep add <CREATED_IDS[i]> <CREATED_IDS[i-1]>
   ```

   これにより Step N は Step N-1 に依存する（Step N-1 が Step N をブロックする）。

4. **エラー処理**:
   - `bd create` 失敗 → エラーを記録し、そのステップをスキップして次へ続行
   - `bd dep add` 失敗 → 警告を記録し、続行（チケットは作成済みだが依存関係なし）

---

### Phase 6: 完了サマリー

```markdown
## plan-to-beads 起票完了

**計画**: <PLAN_TITLE>
**起票数**: <成功数> / <全ステップ数>

| # | チケットID | タイトル | 優先度 | needs-review | AC (要約) | 依存先 |
|---|-----------|---------|--------|-------------|-----------|--------|
| 1 | whirlwind-xxx | ... | P2 | - | ... | - |
| 2 | whirlwind-yyy | ... | P2 | yes | ... | whirlwind-xxx |
| 3 | whirlwind-zzz | ... | P1 | - | ... | whirlwind-yyy |

### 失敗（あれば）

| # | タイトル | エラー |
|---|---------|--------|

### 次のステップ

- `bd show <id>` で個別チケットの詳細確認
- `bd update <id> --priority=<N>` で優先度変更
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
| ステップ抽出 0 件 | 「計画からステップを抽出できませんでした。計画ファイルの形式を確認してください」と報告して終了 |
| `bd create` 失敗（個別） | エラーを記録、残りのステップは続行、サマリーに失敗として表示 |
| `bd dep add` 失敗 | 警告を記録、続行（チケットは作成済みだが未リンク） |
| ユーザーが確認で `no` | 「起票を中止しました」と報告して終了 |
| 優先度の値が不正（0-4 以外） | 「優先度は 0-4 (P0-P4) で指定してください」と再度質問 |

## 関連スキル

- **bd-runner** — plan-to-beads で起票したチケットを自動実行するオーケストレーター
- **bd-detail** — 起票後のチケットを精緻化。plan-to-beads の起票内容が不十分な場合に補完する
- **log-audit** — 実行チェーンの終端。plan-to-beads → bd-runner → log-audit の流れでログを分析する
