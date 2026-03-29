---
name: sync-docs
description: >
  docs/ と README.md をコードベースの最新状態に同期する。
  git diff でコード変更を検出し、影響ドキュメントを特定、最小限の正確な更新を行う。
  コード変更後のドキュメント更新、バージョン不一致の修正、struct/enum 定義の反映に使う。
  "sync-docs", "ドキュメント同期", "doc sync", "update docs", "ドキュメント更新",
  "docs outdated", "README更新", "ドキュメントとコードの乖離".
argument-hint: "[--target=<doc>] [--dry-run] [--full] [--since=<commit>]"
origin: whirlwind
---

# sync-docs: ドキュメント同期

docs/ と README.md をコードの最新状態に合わせて更新する。
ドキュメントのスタイルと構造を保ちつつ、コードとの乖離を最小限の編集で解消する。

## 引数

```
/sync-docs [--target=<filename>] [--dry-run] [--full] [--since=<commit>]
```

- `--target=<filename>`: 特定ファイルのみ更新（例: `02-moonbit-core.md`, `README.md`）
- `--dry-run`: 影響分析レポートのみ出力。ファイル編集は行わない
- `--full`: 変更検出をスキップし全ドキュメントを同期
- `--since=<commit>`: 変更検出の起点コミットを指定（デフォルト: docs/ を最後に変更したコミット）

`$ARGUMENTS` の内容: `$ARGUMENTS`

---

## Phase 1: Change Detection

コードがドキュメントより先に進んでいる部分を特定する。

### 1-1. 基点コミットの特定

`--since` が指定されていればそれを使う。なければ:

```bash
git log -1 --format="%H" -- docs/ README.md
```

### 1-2. コード差分の取得

```bash
git diff <base>..HEAD --name-status -- src/ sdk/ justfile package.json moon.mod.json
```

### 1-3. 変更の分類

差分を以下のカテゴリに分類する:

| カテゴリ | 検出方法 | 例 |
|---------|---------|-----|
| 型定義変更 | `struct`, `enum`, `type` の追加・変更・削除 | Milestone に perspectives フィールド追加 |
| 関数シグネチャ変更 | `pub fn` の追加・変更・削除 | 新しい public 関数 |
| 新規ファイル | git status: A (added) | 新モジュール追加 |
| 削除ファイル | git status: D (deleted) | モジュール削除 |
| ファイル分割/統合 | 同一ディレクトリ内の A + D の組み合わせ | ralph_loop.mbt の分割 |
| SDK インターフェース変更 | `.mts` の export 型・関数変更 | AgentAdapter 変更 |
| ビルド/設定変更 | justfile, package.json, moon.mod.json | バージョンバンプ |

`--full` の場合はこの Phase をスキップし、全ドキュメントを対象とする。

---

## Phase 2: Doc Impact Analysis

Phase 1 で検出した変更ファイルについて、各ドキュメント内を動的にスキャンし、影響箇所を特定する。
静的なマッピングテーブルは使わない。ドキュメント自体が参照しているコードパスを直接検索する。

### 2-1. ドキュメント内のコード参照を抽出

各ドキュメント（`docs/*.md` + `README.md`）を Read し、以下のパターンを Grep で抽出:

- ファイルパス参照: `src/...`, `sdk/...`, バッククォート内のパス
- 型名参照: struct 名、enum 名、trait 名（`AgentKind`, `RalphLoop` 等）
- 関数名参照: `parse_cli_args()`, `preset_ralph()` 等
- バージョン文字列: `0.x.x` パターン
- 統計値: 「N 個のモジュール」「N ファイル」「N テスト」等の数値表現

### 2-2. 変更ファイルとの突合

Phase 1 の変更ファイルリストと、各ドキュメントが参照するファイル・型・関数を突合する。
一致があれば影響ありと判定。

### 2-3. 影響分析テーブルを構築

```markdown
## 影響分析

| 変更ファイル | 変更種別 | 影響ドキュメント | 影響セクション |
|------------|---------|---------------|-------------|
| src/types/types.mbt | Milestone に perspectives 追加 | 02-moonbit-core.md | Milestone 型定義 |
| src/ralph/ralph_loop.mbt | ファイル分割 | 01-architecture.md, 02-moonbit-core.md | モジュール構成 |
| package.json | バージョン 0.3.0→0.3.1 | 00-overview.md, README.md | バージョン表記 |
```

`--dry-run` の場合はこのテーブルを出力して終了する。

`--target` が指定されている場合は、そのファイルに関連する変更のみに絞る。

---

## Phase 3: Current Code Verification

影響セクションごとに、実際のコードを Read/Grep で読み取り「現在の真実」を確認する。
ドキュメントの既存テキストを鵜呑みにしない。必ずコードから事実を確認する。

確認項目:

1. **型定義**: `Grep` で `pub struct`, `pub enum`, `pub type` を検索し、フィールド・バリアントを確認
2. **関数シグネチャ**: `Grep` で `pub fn` を検索し、引数・戻り値を確認
3. **モジュール構成**: `Glob` で `src/**/*.mbt` を検索し、ファイル一覧を確認
4. **テストファイル数**: `Glob` で `*_test.mbt` と `*.test.mjs` を検索しカウント
5. **バージョン**: `Read` で `package.json` と `moon.mod.json` のバージョンを確認
6. **SDK エクスポート**: `Grep` で `export` を検索し、公開 API を確認
7. **justfile ターゲット**: `Read` で justfile を読み、ビルドコマンドを確認

各項目について `CHANGES` リストを構築:

```
{ doc_file, section, what_changed, current_code_truth }
```

---

## Phase 4: Doc Updates

`CHANGES` リストに基づき、各ドキュメントを更新する。

### 更新ルール

- **スタイル保持**: 見出しレベル、テーブル形式、コードブロック言語、日本語/英語の使い分けを既存に合わせる
- **最小編集**: 変更が必要な行・セクションのみ Edit する。全体の書き直しは行わない
- **新規セクション追加**: 新機能やモジュールは、既存の構造に倣って適切な位置に挿入する
- **統計値更新**: ファイル数、テスト数、行数は Glob/wc で再カウントした値に更新する
- **バージョン番号**: 全ドキュメントで一貫して最新バージョンに更新する
- **コードスニペット**: ドキュメント内のコード例が擬似コードや簡略版の場合はそのスタイルを維持する。リテラルコピーの場合は実コードに合わせる

### 更新順序

1. `docs/00-overview.md` — バージョン、ファイル数、品質スコア
2. `docs/01-architecture.md` — モジュールグラフ、レイヤー構成
3. `docs/02-moonbit-core.md` — 型定義、API、モジュール詳細
4. `docs/03-sdk-integration.md` — SDK インターフェース、アダプター
5. `docs/04-testing-quality.md` — テストインベントリ、カバレッジ、ビルド
6. `docs/05-workflow-ralph.md` — CLI フラグ、設定スキーマ、ワークフロー
7. `docs/06-harness-infrastructure.md` — フック、CI、eval ハーネス
8. `README.md` — CLI フラグ、エージェント種別、デフォルト値

### 更新対象外（手動確認推奨としてフラグ）

- **主観的評価**: 品質スコア、アーキテクチャ評価
- **説明文の意図変更**: コード変更に伴い説明の意味が変わるケース
- **図・ダイアグラム**: ASCII アートやフローチャート

---

## Phase 5: Accuracy Cross-Check

更新後のドキュメントが正確であることを検証する。

1. **コードスニペット検証**: ドキュメント内の `struct`, `enum`, `fn` 定義を Grep で実コードと照合
2. **数値検証**: ファイル数、テスト数、モジュール数を Glob で再カウントし一致を確認
3. **バージョン一貫性**: 全ドキュメントのバージョン表記が `package.json` と一致することを確認
4. **リンク検証**: ドキュメント間の相互参照（`docs/01-architecture.md` 等）が有効であることを確認

不一致が見つかった場合は Phase 4 に戻って修正する。

---

## Phase 6: Summary Report

更新結果を報告する。

```markdown
## sync-docs 完了

| ドキュメント | 更新セクション数 | 主な変更 |
|------------|--------------|---------|
| 02-moonbit-core.md | 3 | struct 追加、API 更新 |
| README.md | 1 | CLI flag 追加 |

### 未更新（手動確認推奨）
- 00-overview.md: 品質スコア（主観的評価のため自動更新対象外）

### 検証結果
- コードスニペット: N/N 件一致
- 数値: N/N 件一致
- バージョン: 一貫性 OK
```
