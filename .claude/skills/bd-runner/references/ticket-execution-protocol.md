# チケット実行プロトコル（サブエージェント用）

## 前提

- プロジェクトは MoonBit + TypeScript で構成
- テスト: `just test`（ユニット）、`just live`（結合）
- フォーマット: `moon fmt`（MoonBit）、`npx prettier --write`（TypeScript/JS）
- チケット管理: `bd` コマンド

## 実行手順

### Step 1: チケット取得

**ステータス確認（実行前ガード）**:

```bash
bd show <TICKET_ID> --json
```

ステータスが `open` または `in_progress` でない場合（`closed`, `deferred`, `blocked` 等）、以下の結果を返して終了:
  ```
  STATUS: skipped
  TICKET_ID: <ticket-id>
  REASON: Ticket status is '<status>', not open/in_progress
  ```

ステータスが有効な場合、以下の claim 処理に続行する。

---

チケットが既に `in_progress`（前セッションからの復帰、`RESUMED=true`）の場合:
- claim をスキップする（既にアサイン済み）
- 前セッションの未コミット変更をリセットしてクリーンスタート:
  ```bash
  git checkout -- .
  ```

それ以外の場合:
```bash
bd update <TICKET_ID> --claim
```

claim 失敗時（既に他で作業中）はエラーを返して終了。

### Step 2: 問題理解

1. チケットのタイトルと説明を読む
2. acceptance criteria（AC）を確認し、完了条件を把握する
3. notes・design・comments に追加の指示や背景情報がないか確認する
4. 関連するソースファイルを特定する
5. 期待される動作と実際の動作を理解する
6. 影響範囲を把握する

### Step 3: TDD — 失敗するテストを先に書く

チケットの種別に応じてテストを作成する:

**bug チケットの場合**:
- バグを再現するリグレッションテストを書く
- テストはバグの存在を証明する（= 修正前は FAIL する）
- テスト名にチケットIDを含めることを推奨（例: `test "whirlwind-xxx: description"`）

**task / feature チケットの場合**:
- 期待される結果を検証するテストを書く
- 実装前の段階でテストが FAIL することを確認

テストファイルの配置:
- MoonBit: 対象モジュールの `*_test.mbt` ファイル
- TypeScript: 対象ファイルの `.test.mjs` ファイル

### Step 4: テスト失敗の確認

```bash
just test
```

新しいテストが期待通りに FAIL することを確認する。
既存テストが PASS していることも確認する（新テスト追加で既存が壊れていないか）。

### Step 5: 実装

- テストを通過させる最小限の変更を行う
- 既存のコードパターンと規約に従う
- 変更は対象の問題のみに限定する（スコープ外の改善はしない）

### Step 6: 全テスト通過の確認

```bash
just test
```

以下を確認:
- 新しいテストが PASS する
- 既存の全テストも PASS する（リグレッションなし）

テストが失敗する場合は修正を繰り返す。3回試行しても通過しない場合は失敗として報告する。

### Step 7: AC 検証

acceptance criteria（AC）が提供されている場合、コミット前に各項目を検証する:

1. AC の各項目を1つずつチェックする
2. 未達の項目がある場合は実装を追加修正する
3. 修正後は Step 6 に戻り全テスト通過を再確認する
4. 全 AC が満たされてから次のステップに進む

AC が提供されていない場合はこのステップをスキップする。

### Step 8: フォーマット

変更したファイルの種類に応じて実行:

```bash
# MoonBit ファイルを変更した場合
moon fmt

# TypeScript/JS ファイルを変更した場合
npx prettier --write <changed-files>
```

### Step 9: コミット

変更したファイルのみをステージングし、コミットする:

```bash
git add <specific-changed-files>
git commit -m "$(cat <<'EOF'
fix(<scope>): <description>

Resolves <TICKET_ID>
EOF
)"
```

コミットメッセージの規約:
- **type**: `fix`（bug）、`feat`（feature）、`refactor`（task）、`test`（テストのみ）
- **scope**: 変更対象のモジュール名（例: `ralph`, `agent`, `cli`, `sdk`）
- **description**: 変更内容の簡潔な説明
- **footer**: `Resolves <TICKET_ID>` で相互参照

### Step 10: 結果報告

以下の情報をオーケストレーターに返す:

```
STATUS: success | failure | skipped
TICKET_ID: <ticket-id>
COMMIT_HASH: <hash>  (成功時のみ)
FILES_CHANGED: <file1>, <file2>, ...
TEST_SUMMARY: <pass_count>/<total_count> tests passed
ERROR: <error details>  (失敗時のみ)
REASON: <skip reason>  (スキップ時のみ)
```

## 失敗時の処理

テスト作成や実装に失敗した場合:

1. 変更をすべて元に戻す:
   ```bash
   git checkout -- .
   ```

2. チケットのclaimを解除はしない（オーケストレーターが処理する）

3. 失敗理由を詳細に報告する（どのステップで、何が原因で失敗したか）
