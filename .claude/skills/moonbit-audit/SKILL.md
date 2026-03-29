---
name: moonbit-audit
description: >
  リポジトリ全体の MoonBit コードを rules/ と skills/ のナレッジに照合し、
  規約違反を検出してリファクタリングチケットを起票する。バグ発見時はユーザー確認後に起票。
  "moonbit-audit", "MoonBitチェック", "コード規約チェック", "moonbit lint", "MoonBit audit".
argument-hint: options:--priority=N --dry-run --module=name
origin: whirlwind
---

# moonbit-audit: MoonBit 規約チェック & チケット起票

## 引数

```
/moonbit-audit [--priority=<0-4>] [--dry-run] [--module=<name>]
```

- `--priority=<0-4>`: リファクタリングチケットのデフォルト優先度（デフォルト: 3）
- `--dry-run`: チケットを起票せず、検出結果のレポートのみ出力
- `--module=<name>`: 特定モジュールのみスキャン（例: `--module=agent`）

`$ARGUMENTS` の内容: `$ARGUMENTS`

---

## Phase 1: ナレッジ読込

以下のファイルを読み込み、チェックルールセットを構築する:

| ファイル | チェックカテゴリ |
|----------|----------------|
| `rules/moonbit-coding-style.md` | コーディングスタイル |
| `rules/moonbit-testing.md` | テスト規約 |
| `rules/moonbit-patterns.md` | パターン・イディオム |
| `rules/moonbit-security.md` | セキュリティ |
| `skills/moonbit-patterns/SKILL.md` | パターン詳細・アンチパターン |
| `skills/moonbit-testing/SKILL.md` | テスト詳細・TDD |

各ファイルからチェック項目を抽出し、以下の構造で `RULESET` を構築:

```
RULESET[category] = [
  { rule_id, description, severity(error|warning|info), check_method }
]
```

---

## Phase 2: ソーススキャン

### 2-1. 対象ファイルの収集

```
src/**/*.mbt
```

`--module=<name>` 指定時は `src/<name>/**/*.mbt` に限定。

テストファイル（`*_test.mbt`, `*_wbtest.mbt`）も対象とする。

### 2-2. 並列スキャン

モジュール数に応じて並列 Explore エージェントを起動:

- **3モジュール以下**: 1エージェントで全モジュールをスキャン
- **4モジュール以上**: 最大3エージェントに分割（各エージェントに担当モジュールとルールセットを渡す）

各エージェントへの指示:
- 担当モジュールの全 .mbt ファイルを Read で読み込む
- `RULESET` の各ルールに照合し、違反箇所を記録
- 結果を `FINDINGS` リストとして返す

---

## Phase 3: 違反分析

### チェック項目一覧

#### コーディングスタイル（moonbit-coding-style.md）

| チェック | 判定基準 | 分類 |
|---------|---------|------|
| 命名規則 | 関数: snake_case、型: PascalCase、定数: SCREAMING_SNAKE_CASE | refactoring |
| 可変性 | `let mut` の不要な使用（immutable で代替可能） | refactoring |
| エラーハンドリング | `suberror`/`raise`/`try!` の不使用、panic の直接使用 | bug候補 |
| ファイルサイズ | 800行超のソースファイル | refactoring |
| 定数宣言 | トップレベル以外での定数定義、非リテラル定数 | refactoring |
| ドキュメント | pub 関数に `///\|` コメントがない | refactoring |
| メソッド定義 | `Type::` プレフィックスなしのメソッド定義 | refactoring |

#### パターン（moonbit-patterns.md + skill）

| チェック | 判定基準 | 分類 |
|---------|---------|------|
| struct更新構文 | `...` (triple dot) の誤使用（正しくは `..`） | bug |
| ワイルドカード | enum match で `_` が新バリアント追加時の安全性を損なう | refactoring |
| Option処理 | `match` の多用（`map`/`or`/`bind` 等のコンビネータ推奨） | refactoring |
| Newtype不使用 | 型安全性が必要な場面で生の String/Int を使用 | refactoring |
| イテレータ | 命令型ループで代替可能な iter チェーン、またはその逆 | refactoring |
| sealed trait | `pub(open)` の過剰使用 | refactoring |

#### テスト（moonbit-testing.md + skill）

| チェック | 判定基準 | 分類 |
|---------|---------|------|
| テスト欠落 | ソースファイルに対応するテストファイルがない | refactoring |
| テスト命名 | `test "test_..."` 等の非記述的な名前 | refactoring |
| snapshot未活用 | 複雑な構造体の検証に `assert_eq` を使用（`inspect` 推奨） | refactoring |
| panic test | panic を検証するテストで名前が "panic" で始まっていない | bug候補 |

#### セキュリティ（moonbit-security.md）

| チェック | 判定基準 | 分類 |
|---------|---------|------|
| ハードコード値 | API キー、パスワード等の文字列リテラル | bug |
| 入力バリデーション | 外部入力を検証なしで使用 | bug候補 |
| エラー情報漏洩 | 内部詳細を含むエラーメッセージの外部公開 | bug候補 |

### 分類ルール

| 分類 | 条件 | チケットタイプ |
|------|------|--------------|
| `refactoring` | 規約違反・コード品質改善。動作に影響しない | `task` |
| `bug` | 確実にバグである問題（struct `...` 誤使用、ハードコード秘匿値等） | `bug` |
| `bug候補` | バグの可能性があるが文脈依存で判断が必要な問題 | `bug`（ユーザー確認後） |

---

## Phase 4: レポート生成 & バグ確認

### 4-1. レポート出力

```markdown
## MoonBit 規約チェックレポート

**スキャン対象**: src/ (N ファイル, M モジュール)
**検出数**: X件 (refactoring: A, bug: B, bug候補: C)

### 検出事項

#### [REFACTORING] <カテゴリ>: <概要>
- **ファイル**: `src/xxx/yyy.mbt:NN`
- **ルール**: <違反ルールの説明>
- **現状コード**: `<該当コード抜粋>`
- **推奨**: <修正方針>

#### [BUG] <概要>
- **ファイル**: `src/xxx/yyy.mbt:NN`
- **問題**: <バグの説明と根拠>
- **影響**: <実行時の影響>

#### [BUG?] <概要>
- **ファイル**: `src/xxx/yyy.mbt:NN`
- **問題**: <問題の説明>
- **判断が必要な理由**: <文脈依存である理由>
```

### 4-2. バグ確認フロー

`[BUG?]`（bug候補）について、ユーザーに確認を求める:

1. 全 bug候補を一覧表示（ファイル、行、問題の説明、根拠）
2. AskUserQuestion で各項目の判断を求める:
   - **起票する**: bug チケットとして起票
   - **refactoring に変更**: task チケットとして起票
   - **スキップ**: 起票しない
3. `[BUG]`（確実なバグ）についても一覧表示し、起票確認を求める
4. ユーザーの回答を `CONFIRMED_FINDINGS` に記録

`DRY_RUN=true` の場合、レポート出力で終了。

---

## Phase 5: チケット起票

`rules/bd-ticket-quality.md` の品質基準に従ってチケットを起票する。

### 5-1. チケットのグルーピング

関連する違反をまとめて1チケットにする:
- **同一パターンの違反**: 同じルール違反が複数ファイルにある場合 → 1チケット
- **同一モジュール内の軽微な違反**: 同モジュール内の info レベル → まとめて1チケット
- **個別性が高い違反**: bug、重大な規約違反 → 個別チケット

### 5-2. チケット作成

```bash
bd create --title="<タイトル>" \
          --description="<description テンプレートに従う>" \
          --type=<task|bug> \
          --priority=<DEFAULT_PRIORITY or ユーザー指定> \
          --acceptance="<AC>"
```

- `refactoring` → `--type=task`, `--priority=<DEFAULT_PRIORITY>`（デフォルト: 3）
- `bug` → `--type=bug`, `--priority=<ユーザー指定 or 2>`
- description には違反ファイル・行番号・修正方針を含める
- AC には品質ゲートに従い、機械検証可能な条件を含める

### 5-3. 品質ゲート適用

`rules/bd-ticket-quality.md` のエージェント実行可能性ゲートを適用:
- how（修正手順）が具体的でない → P4 に降格
- AC が機械検証不可能 → P4 に降格

---

## Phase 6: サマリー

```markdown
## moonbit-audit 結果サマリー

### スキャン統計
- 対象ファイル: N
- チェックルール: M
- 検出数: X (refactoring: A, bug: B)

### 起票チケット
| ID | タイトル | タイプ | 優先度 | カテゴリ |
|----|---------|--------|--------|---------|
| xxx-001 | ... | task | P3 | コーディングスタイル |
| xxx-002 | ... | bug | P2 | セキュリティ |

### スキップされた項目
| 概要 | 理由 |
|------|------|
| ... | ユーザー判断によりスキップ |

### 未チケット化の軽微事項
<info レベルでチケット化不要と判断した事項の一覧>
```

---

## エラーハンドリング

| シナリオ | アクション |
|---------|-----------|
| `src/` が存在しない | エラーメッセージを出して終了 |
| .mbt ファイルが 0 件 | 「スキャン対象なし」で正常終了 |
| `--module` で指定したモジュールが存在しない | エラー出力、利用可能なモジュール一覧を表示 |
| ナレッジファイルが見つからない | 警告出力、利用可能なルールのみでスキャン続行 |
| `bd` コマンドが利用不可 | チケット起票をスキップ、レポートのみ出力 |
| 検出事項が 0 件 | 「違反は検出されませんでした」と報告して正常終了 |

## 関連スキル

- **moonbit-patterns** — 規約チェックの参照元。moonbit-audit はこのパターン集に照合して違反を検出する
- **moonbit-testing** — テスト規約の参照元。テスト関連の違反検出に使用する
