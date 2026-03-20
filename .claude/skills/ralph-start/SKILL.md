---
name: ralph-start
description: >
  Markdown計画ファイルをtornado Ralphモードの入力に変換し、バックグラウンドで起動・監視するオーケストレーター。
  計画 → milestones.json + tornado.json 変換、起動、進捗監視を実行。
  "ralph", "計画ファイルから開発開始", "マイルストーン開発", "tornado起動", "plan file", "launch tornado".
arguments: plan_file:計画ファイル(Markdown)のパス
---

# ralph-start: 計画ファイル → tornado Ralph モード起動

## 引数

```
/ralph-start <plan-file.md> [--dev=<kind>] [--verifier=<kind>]
```

`$ARGUMENTS` の内容: `$ARGUMENTS`

## オーケストレーション概要

計画ファイル (Markdown) を tornado Ralph モードの入力に変換し、バックグラウンドで起動・監視する **5フェーズパイプライン**。

1. **入力検証** — 引数解析、ファイル確認、リポジトリルート取得
2. **計画→マイルストーン変換** — 英訳、パース、skeleton 生成
3. **出力ファイル生成** — Plan Context 注入、tornado.json 生成
4. **検証・起動** — JSON 検証、サマリー表示、バックグラウンド起動
5. **進捗モニタリング** — `/loop 1m` で定期監視

各フェーズを**必ず順番に**実行すること。

---

### Phase 1: 入力検証

1. `$ARGUMENTS` を解析する:
   - 最初の `--` で始まらないトークンを `PLAN_FILE` とする
   - `--dev=<value>` があれば `DEV_KIND` に格納（デフォルト: `codex`）
   - `--verifier=<value>` があれば `VERIFIER_KIND` に格納（デフォルト: `claude-code`）
   - 引数が空、または `PLAN_FILE` が見つからない場合はエラーメッセージを出して終了

2. `PLAN_FILE` の存在を確認する（相対パスの場合は CWD からの解決）

3. リポジトリルートを取得:

   ```bash
   git rev-parse --show-toplevel
   ```

4. `PLAN_FILE` を読み込む

---

### Phase 2: 計画ファイル → マイルストーン + タスク変換

**Step 1: 出力ディレクトリの作成と英訳版計画ファイルの生成**

1. ディレクトリ名を決定する（`references/parse-rules.md` のディレクトリ名生成規則に従う）
2. 出力ディレクトリを作成する
3. 計画ファイルの全内容を英語に翻訳し、出力ディレクトリに `plan-en.md` として書き出す。
   コード内の識別子やファイルパスはそのまま保持する。

以降の goal / description で参照する Plan Context はこのファイルの内容を使用する。

**Step 2: パースと変換**

Markdown を **`references/parse-rules.md`** の規則でパースする。

**重要: `goal`・`description`・ディレクトリ名はすべて英語で生成する。** 計画ファイルが日本語の場合は翻訳する。コード内の識別子やファイルパスはそのまま保持する。

パース規則・goal 構成規則・タスク ID 命名規則・description テンプレートの詳細は `references/parse-rules.md` を Read して参照すること。

---

### Phase 3: 出力ファイル生成

出力ディレクトリは Phase 2 Step 1 で作成済み。最終成果物は plan-en.md, milestones.json, tornado.json の3つ。

#### 3-1. milestones-skeleton.json（中間ファイル）

**`references/milestones-schema.md`** の JSON スキーマに従い、Plan Context **なし** の `milestones-skeleton.json` を生成する。

スキーマの詳細は `references/milestones-schema.md` を Read して参照すること。

#### 3-2. milestones.json（Plan Context 注入）

スクリプトで Verification Scope 指示と Plan Context を注入する:

```bash
node .claude/skills/ralph-start/scripts/inject-plan-context.js <output_dir>
```

> このスクリプトが以下を自動処理:
> - `goal` に Verification Scope + Plan Context を追加
> - `description` に Plan Context を追加
> - `milestones-skeleton.json` を削除

#### 3-3. tornado.json

**`references/tornado-config.md`** のテンプレートに従い生成する。

テンプレートとエージェント設定の詳細は `references/tornado-config.md` を Read して参照すること。

---

### Phase 4: 検証・起動

1. **JSON バリデーション**: 生成した両ファイルを `jq .` で検証

2. **サマリー表示**: Plan file, Output dir, Milestones数, Tasks数, Builder/Verifier種別, 各マイルストーンの goal先頭行・タスク数・Wave数を表示

3. **tornado 起動**（バックグラウンド）:

   Bash ツールで以下のコマンドを `run_in_background: true` で実行する:

   ```bash
   npx -y @ymdvsymd/tornado@latest --ralph --config=<tornado.json の絶対パス> --lang=ja
   ```

   起動後、ユーザーにタスク ID を共有する。

---

### Phase 5: 進捗モニタリング

tornado がバックグラウンドで実行中の間、`/loop` スキルを使って **1 分間隔** で進捗を監視する。

1. `/loop 1m` を起動し、以下のプロンプトを実行する:
   - `TaskOutput` でバックグラウンドの tornado タスク出力を取得
   - 最新の出力から進捗状況（現在のマイルストーン、Wave、タスク状態）を要約してユーザーに共有
   - タスクが完了していたら `/loop` を停止

2. tornado 完了通知を受けたら最終結果を報告する。

---

## エラーハンドリング

- 計画ファイルが見つからない場合 → エラーメッセージを出して終了
- 計画ファイルにリスト項目が1つもない場合 → エラーメッセージを出して終了
- `--dev` / `--verifier` に無効な値が指定された場合 → エラーメッセージを出して終了
  - 有効な値: `claude-code`, `claude`, `claudecode`, `codex`, `api`, `mock`
- JSON バリデーション失敗 → エラーメッセージを出して終了（ファイルは残す）
- スクリプト実行失敗 → エラーメッセージを出して終了（中間ファイルは残す）
