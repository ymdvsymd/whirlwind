---
name: bd-detail
description: >
  bdチケットを分析し、不足フィールドの補完・description の構造化・acceptance criteria 追加等を行う精緻化スキル。
  コードベースと技術ドキュメントを調査して修正対象ファイル・原因・修正方針を特定し、差分表示でユーザー確認後に更新。
  "bd-detail", "チケット精緻化", "チケット詳細化", "ticket detail", "ticket elaborate", "detail ticket".
argument-hint: ticket_id:bdチケットID。複数指定可
origin: whirlwind
---

# bd-detail: bd チケット精緻化

## 引数

```
/bd-detail <ticket-id> [<ticket-id2> ...] [--skip-codebase] [--dry-run]
```

- `<ticket-id>`: 精緻化対象の bd チケット ID。1つ以上必須
- `--skip-codebase`: コードベース調査（Phase 3）をスキップ。非コード系チケット（docs, CI 等）向け
- `--dry-run`: 提案内容を表示するのみ。チケットは更新しない

`$ARGUMENTS` の内容: `$ARGUMENTS`

---

## Phase 1: チケット取得と現状分析

1. `$ARGUMENTS` を解析する:
   - `--` で始まらないトークンを `TICKET_IDS` リストに格納
   - `--skip-codebase` があれば `SKIP_CODEBASE=true`
   - `--dry-run` があれば `DRY_RUN=true`

2. `TICKET_IDS` が空なら、エラーメッセージを出して終了:
   ```
   エラー: チケットIDを1つ以上指定してください。
   使用例: /bd-detail whirlwind-xxx
   ```

3. 各チケットを順次処理する。以下の Phase 2〜6 を各チケットに対して繰り返す。

4. チケット情報を取得:

   ```bash
   bd show <ticket-id> --json
   ```

   チケットが存在しない場合はエラーを出力し、次のチケットへスキップ。

5. 追加フィールドを取得:

   ```bash
   bd sql "SELECT acceptance_criteria, notes, design FROM issues WHERE id='<ticket-id>'"
   bd label list <ticket-id>
   bd comments <ticket-id>
   ```

6. 以下のフィールドを記録:
   - `TITLE` — タイトル
   - `DESCRIPTION` — 説明
   - `ACCEPTANCE_CRITERIA` — 受け入れ基準
   - `NOTES` — 備考
   - `DESIGN` — 設計メモ
   - `LABELS` — ラベル一覧
   - `COMMENTS` — コメント一覧
   - `TYPE` — チケット種別（bug / feature / task 等）
   - `PRIORITY` — 優先度
   - `STATUS` — ステータス

7. ステータスが `closed` または `deferred` の場合、ユーザーに警告:
   ```
   警告: このチケットは <STATUS> です。精緻化を続行しますか？
   ```
   ユーザーが拒否したら次のチケットへスキップ。

---

## Phase 2: 不足・不備の判定

品質基準: `rules/bd-ticket-quality.md` に定義された共通基準に従う。「すぐ実装着手できる精度で作成すること。description（原因・修正方針・修正対象ファイル）、acceptance criteria、notesを必ず含める。曖昧なチケットは禁止。」

各フィールドを以下の基準で評価する:

### description

| 判定 | 条件 |
|------|------|
| `MISSING` | 空または未設定 |
| `NEEDS_STRUCTURE` | 内容はあるが構造化セクション（`## 原因` / `## 修正方針` / `## 修正対象ファイル` 等）がない |
| `OK` | 構造化セクションが存在し、具体的な内容がある |

### acceptance_criteria

| 判定 | 条件 |
|------|------|
| `MISSING` | 空または未設定 |
| `NEEDS_IMPROVEMENT` | 2項目未満、または機械検証不可能な曖昧表現（「正しく動作する」等） |
| `OK` | 2項目以上で、各項目が機械的に検証可能 |

### notes

| 判定 | 条件 |
|------|------|
| `MISSING` | 空または未設定 |
| `OK` | 内容がある |

### design

| 判定 | 条件 |
|------|------|
| `OPTIONAL_MISSING` | 空だが、単純なチケットなので不要と判断 |
| `RECOMMENDED` | 空で、かつ複数モジュールにまたがる or アーキテクチャ判断が必要 |
| `OK` | 内容がある |

### 判定結果

`GAPS` リストを構築し、`MISSING` / `NEEDS_STRUCTURE` / `NEEDS_IMPROVEMENT` / `RECOMMENDED` のフィールドを記録。

全フィールドが `OK` の場合:
```
このチケットは既に十分な精度で記述されています: <ticket-id>
```
次のチケットへスキップ（バッチモード）、または終了。

---

## Phase 3: 調査

コードベース調査と技術調査を行い、提案の根拠となる情報を収集する。

`SKIP_CODEBASE=true` の場合、コードベース調査をスキップし、技術調査のみ実施する。

### 3-1. コードベース調査

1. 既存の title と description からキーワードを抽出:
   - ファイルパス（例: `src/config/config.mbt`）
   - モジュール名（例: `ralph`, `agent`, `cli`）
   - 関数名・型名
   - エラーメッセージ

2. コードベースを検索:
   - `Grep` ツール: キーワード、エラー文字列を検索
   - `Glob` ツール: 関連モジュールのファイルを検索
   - `Read` ツール: 主要ファイルを読んでコンテキストを把握

3. bug チケットの場合:
   - 根本原因の推定箇所を特定
   - コードパスをトレース
   - 関連テストファイルを記録

4. feature / task チケットの場合:
   - 変更が必要なファイルを特定
   - 既存パターンの確認
   - テストファイルの規約を確認

5. 収集結果を `CODEBASE_CONTEXT` に格納:
   - `TARGET_FILES`: 修正対象ファイル一覧（行番号付き）
   - `CAUSE_ANALYSIS`: 原因分析（bug）または実装アプローチ（feature/task）
   - `FIX_APPROACH`: 具体的な修正手順
   - `RELATED_TESTS`: 関連テストファイル
   - `PATTERNS`: 参考にすべきコーディングパターン

### 3-2. 技術調査

コードベース調査だけでは情報が不十分と判断した場合（外部ライブラリの使い方、言語仕様の確認、ベストプラクティスの参照等）、以下を**並列で**実施:

- `mcp__claude_ai_Ref__ref_search_documentation` / `mcp__claude_ai_Ref__ref_read_url` で技術ドキュメントを確認
- `WebSearch` で補足情報を検索

技術調査の結果を `TECH_CONTEXT` に格納。

### 3-3. 調査不要の判断

以下の場合、調査結果なしでも Phase 4 に進む:
- `SKIP_CODEBASE=true` で、description に既に十分な情報がある
- チケットの内容が非技術的（ドキュメント更新、CI 設定等）

---

## Phase 4: 不明点の解消

Phase 3 の調査結果を踏まえ、提案の生成に必要な判断で**自信が持てない点**をユーザーに確認する。

### 確認が必要なケース

- 修正方針が複数あり、どちらが適切か判断できない
- 影響範囲が不明確で、修正対象ファイルの絞り込みに確信が持てない
- チケットの意図が曖昧で、複数の解釈が可能
- 技術的な制約により方針の選択が分かれる

### 確認のフォーマット

ユーザーに以下を提示する:

```markdown
## 確認事項: <ticket-id>

### <質問>

**コンテキスト:**
<判断に必要な背景情報。該当コードの抜粋、関連チケット、技術的制約を含める>

**選択肢:**
1. **<方針A>**: <説明>
   - メリット: ...
   - デメリット: ...
2. **<方針B>**: <説明>
   - メリット: ...
   - デメリット: ...

どちらを採用しますか？
```

### 確認不要の場合

調査結果から方針が一意に定まる場合は、Phase 5 に直接進む。ただし Phase 5 の提案表示時に、採用した方針の根拠を明示する。

---

## Phase 5: 提案生成と差分表示

`GAPS` に記録された各フィールドについて、提案内容を生成する。description テンプレートと AC 要件は `rules/bd-ticket-quality.md` の共通基準に従う。

### description の生成

既存の description に有用な内容がある場合は保持し、構造化して拡充する。

**bug チケットのテンプレート:**

```markdown
## 原因
<CODEBASE_CONTEXT.CAUSE_ANALYSIS を元に、具体的なファイル:行番号を参照して記述>

## 修正方針
1. <具体的な修正ステップ>
2. <具体的な修正ステップ>

## 修正対象ファイル
- `<file-path>` — <変更概要>
- `<file-path>` — <変更概要>
```

**feature / task チケットのテンプレート:**

```markdown
## 概要
<チケットの目的と背景>

## 実装方針
1. <具体的な実装ステップ>
2. <具体的な実装ステップ>

## 対象ファイル
- `<file-path>` — <変更概要>
- `<file-path>` — <変更概要>
```

### acceptance_criteria の生成

各項目は以下の条件を満たすこと:
- 単一の、機械的に検証可能な条件
- 末尾は「こと」パターン（例: 「just test が全件パスすること」）
- bug チケット: リグレッションテスト基準を含める
- feature/task チケット: 機能の検証基準を含める
- 必ず「just test が全件パスすること」を含める
- ランタイム動作に影響する変更（MoonBit `src/` や SDK `sdk/` のコード変更）の場合、「just live が全件パスすること」も必ず含める。ドキュメント・CI・スキル定義のみの変更では不要

### notes の生成

以下の情報を含める:
- 発見の経緯（コメントやラベルから推定できる場合）
- 関連チケットや依存関係
- 実装時の注意事項
- 調査で得た技術的知見（`TECH_CONTEXT` から）

### design の生成

`GAPS` で `RECOMMENDED` と判定された場合のみ生成:
- アーキテクチャ上の判断ポイント
- 代替案の検討結果（Phase 4 でユーザーが選択した方針を反映）
- モジュール間の影響

### 差分表示フォーマット

```markdown
## bd-detail: チケット精緻化提案

### <ticket-id>: <title>
**種別**: <TYPE> | **優先度**: P<PRIORITY> | **ステータス**: <STATUS>

---

#### description
**根拠**: <この提案の根拠。調査で参照したコード箇所、ドキュメント等を簡潔に記載>

--- 現在 ---
<現在の description。未設定なら "(未設定)">

+++ 提案 +++
<提案する description>

---

#### acceptance_criteria
**根拠**: <AC を設定した理由・基準>

--- 現在 ---
<現在の AC。未設定なら "(未設定)">

+++ 提案 +++
<提案する AC>

---

#### notes
**根拠**: <notes に含めた情報のソース>

--- 現在 ---
<現在の notes。未設定なら "(未設定)">

+++ 提案 +++
<提案する notes>

---

#### design
--- 現在 ---
<現在の design。未設定なら "(未設定)">

+++ 提案 +++
<提案する design。変更不要なら "(変更なし)">
```

変更がないフィールドは表示しない。

---

## Phase 6: ユーザー確認と更新

### 確認プロンプト

```
上記の提案を確認してください:
- OK: 全フィールドを更新
- 部分承認: 更新するフィールドを指定（例: "description と AC のみ"）
- 編集: 修正箇所を指示（例: "AC の 3 番目を削除して"）
- 却下: 更新せずスキップ
```

### 応答ハンドリング

| ユーザー応答 | アクション |
|------------|-----------|
| OK | 全フィールドを `bd update` で更新 |
| 部分承認 | 指定フィールドのみ更新 |
| 編集指示 | 指定箇所を修正し、該当フィールドの差分を再表示 → 再度確認 |
| 却下 | このチケットをスキップ。バッチモードなら次のチケットへ |

### 更新実行

承認されたフィールドのみ `bd update` で更新する。不要なフィールドの上書きはしない:

```bash
bd update <ticket-id> --description "<approved_description>"
bd update <ticket-id> --acceptance "<approved_ac>"
```

notes について:
- 既存の notes がある場合: `--append-notes` で追記
- 既存の notes がない場合: `--notes` で新規設定

design について:
- `--design "<approved_design>"`

### 更新確認

```bash
bd show <ticket-id>
```

結果を表示:

```markdown
### 更新完了: <ticket-id>

| フィールド | 更新 |
|-----------|------|
| description | o |
| acceptance_criteria | o |
| notes | o |
| design | - |
```

`DRY_RUN=true` の場合、更新は実行せず Phase 5 の差分表示で終了。

### バッチモード

複数チケット指定時は、1チケットの更新完了後に次のチケットの Phase 2 に進む。

全チケット完了後にサマリーを表示:

```markdown
### 精緻化サマリー

| チケット | タイトル | 結果 |
|---------|---------|------|
| whirlwind-xxx | ... | 更新完了 (description, AC, notes) |
| whirlwind-yyy | ... | 精緻化不要 |
| whirlwind-zzz | ... | 却下 |
```

---

## エラーハンドリング

| シナリオ | アクション |
|---------|-----------|
| チケットIDが見つからない | エラー出力、バッチモードなら次のチケットへ |
| チケットが closed / deferred | 警告しユーザーに続行確認 |
| `bd update` が失敗 | エラー表示、手動更新コマンドを提示 |
| `--skip-codebase` で description も空 | title のみから生成、精度が低い旨を警告 |
| 全フィールドが既に十分 | 「精緻化不要」と報告しスキップ |
| コードベース検索で結果なし | title / 既存内容のみから生成、制限事項を notes に記載 |

## 関連スキル

- **bd-runner** — 精緻化したチケットを自動実行するオーケストレーター。bd-detail で品質を上げた後に bd-runner で消化する
- **plan-to-beads** — 計画からチケットを一括起票。起票後に bd-detail で個別チケットを精緻化する
