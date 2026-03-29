# 計画作成規約

## Plan mode 出力規約

- Plan mode で計画を作成する際は、計画ファイルのパスを必ず明示すること。
- 例: `計画ファイル: ~/.claude/plans/xxx.md`
  （`~` はユーザーのホームディレクトリの絶対パスに展開して出力すること）

## bd チケット対応計画フォーマット

Plan mode で作成する計画は、bd チケットのフィールドと1:1対応する構造化フォーマットを使用すること。これにより `/plan-to-beads` でのチケット化が機械的なマッピングで完了する。

### 計画レベルメタデータ

`## Context` セクション内に以下を記載する:

```markdown
## Context

Priority: P2
needs-review: no

<計画の背景・目的>
```

- `Priority`: 全ステップのデフォルト優先度（P0-P4）。ステップ個別の指定で上書き可能
- `needs-review`: チケットに needs-review ラベルを付与するか（yes/no）

### ステップフォーマット

各ステップは以下の構造で記述すること。

```markdown
## Step N: <簡潔なタイトル>

- **Type**: task | feature | bug
- **Priority**: P0-P4
- **Target files**:
  - `<file-path>` -- <変更概要>
- **Depends on**: Step M | none
```

#### feature / task のサブセクション

```markdown
### 概要
<目的と背景、1-3文>

### 実装方針
1. <具体的な実装ステップ>
2. <具体的な実装ステップ>

### AC
- <機械検証可能な条件（「こと」で終わる）>
- <機械検証可能な条件>
- `just test` がパスすること
```

#### bug のサブセクション

```markdown
### 原因
<具体的なファイル:行番号を参照して記述>

### 修正方針
1. <具体的な修正ステップ>

### AC
- <リグレッションテスト基準>
- `just test` がパスすること
```

### AC 要件

- 各ステップに `### AC` セクションを必ず含めること
- 2項目以上の機械検証可能な条件を記載すること
- `just test がパスすること` を必ず含めること
- ランタイムコード変更（`src/`, `sdk/`）の場合は `just live がパスすること` も含めること
- `.claude/`、`docs/`、CI 設定のみの変更では `just test` / `just live` は不要

### 依存関係

- `**Depends on**` で計画内の他ステップへの依存を明示すること
- 依存がない場合は `none` と記載すること
- `/plan-to-beads` はこのフィールドから `bd dep add` を実行する

### フォーマット例

```markdown
# SDK に retry ロジックを追加

計画ファイル: /Users/to.watanabe/.claude/plans/example.md

## Context

Priority: P2
needs-review: no

HTTP リクエストの一時的な失敗（429, 5xx）に対応するため、SDK に retry ロジックを追加する。

## Step 1: retry wrapper の実装

- **Type**: feature
- **Priority**: P2
- **Target files**:
  - `sdk/retry.ts` -- exponential backoff retry wrapper 新規作成
  - `sdk/client.ts` -- fetch 呼び出しを retry wrapper で wrap
- **Depends on**: none

### 概要
HTTP リクエストの一時的な失敗に対して exponential backoff で再試行する。

### 実装方針
1. `sdk/retry.ts` に retry wrapper 関数を作成
2. `sdk/client.ts` の fetch 呼び出しを wrap

### AC
- retry 付きリクエストが最大 3 回まで再試行すること
- 429 と 5xx のステータスコードで再試行すること
- `just test` がパスすること
- `just live` がパスすること

## Step 2: retry 設定の外部化

- **Type**: task
- **Priority**: P2
- **Target files**:
  - `sdk/config.ts` -- retry 設定（maxRetries, backoffMs）を追加
  - `sdk/retry.ts` -- config から設定を読み込み
- **Depends on**: Step 1

### 概要
retry のパラメータをハードコードからコンフィグに移行する。

### 実装方針
1. `sdk/config.ts` に retry 設定を追加
2. `sdk/retry.ts` で config を参照するように変更

### AC
- retry 設定が config から読み込まれること
- デフォルト値（maxRetries=3, backoffMs=1000）が設定されていること
- `just test` がパスすること
- `just live` がパスすること
```

## 計画ファイルに live 結合テストを含める

ランタイムコード（`src/`, `sdk/`）を変更する計画では、各ステップの AC に `just live がパスすること` を必ず含めること。`just test` と `just mock` だけでは不十分。

mock テストだけでは実エージェント環境での問題（CLAUDECODE 環境変数問題等）を検出できない。/ralph-whirlwind 実行時のマイルストーンにも含める。

### 適用除外

以下のみの変更では `just live` は不要:
- skill 定義（`.claude/skills/`）
- rule 定義（`.claude/rules/`）
- ドキュメント（`docs/`）
- CI/CD 設定
