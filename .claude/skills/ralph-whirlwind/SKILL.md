---
name: ralph-whirlwind
description: >
  Markdown計画ファイルを whirlwind CLI の `--plan` フラグで直接起動し、バックグラウンド実行と進捗監視を行う。
  責務は起動コマンドの組み立てと監視のみ。
  "ralph", "plan file", "launch whirlwind", "whirlwind monitoring", "background launch", "計画ファイルから起動".
argument-hint: plan_file:計画ファイルのパス
origin: whirlwind
---

# ralph-whirlwind: plan file から whirlwind 起動

## 引数

```
/ralph-whirlwind <plan-file.md> [--planner=<kind>] [--builder=<kind>] [--verifier=<kind>]
```

- `--planner=<kind>`: Planner agent kind。省略時は whirlwind CLI に渡さない
- `--builder=<kind>`: Builder agent kind。省略時は whirlwind CLI に渡さない
- `--verifier=<kind>`: Verifier agent kind。省略時は whirlwind CLI に渡さない

`$ARGUMENTS` の内容: `$ARGUMENTS`

## オーケストレーション概要

1. **入力検証** — 引数解析、ファイル確認、リポジトリルート取得
2. **whirlwind 起動** — `--plan` 付きの単一コマンドを組み立ててバックグラウンド実行
3. **進捗モニタリング** — `/loop 1m` で定期監視

各フェーズを**必ず順番に**実行すること。

---

### Phase 1: 入力検証

1. `$ARGUMENTS` を解析する:
   - 最初の `--` で始まらないトークンを `PLAN_FILE` とする
   - `--planner=<value>` があれば `PLANNER_KIND` に格納（省略時は未設定）
   - `--builder=<value>` があれば `BUILDER_KIND` に格納（省略時は未設定）
   - `--verifier=<value>` があれば `VERIFIER_KIND` に格納（省略時は未設定）
   - 引数が空、または `PLAN_FILE` が見つからない場合はエラーメッセージを出して終了

2. `PLAN_FILE` の存在を確認する（相対パスの場合は CWD からの解決）

3. リポジトリルートを取得:

   ```bash
   git rev-parse --show-toplevel
   ```

4. 絶対パスを確定する:
   - `REPO_ROOT` を基準に `PLAN_FILE` の絶対パスを解決し、`PLAN_FILE_ABS` に格納する
   - ログファイルパスを `LOG_PATH="$REPO_ROOT/.runs/whirlwind.log"` とする

---

### Phase 2: Whirlwind Launch

1. 実行コマンドを**1つだけ**組み立てる。変換処理や中間 JSON 生成は行わない。

   ```bash
   bin/whirlwind.js --plan=<PLAN_FILE_ABS> [--planner=<PLANNER_KIND>] [--builder=<BUILDER_KIND>] [--verifier=<VERIFIER_KIND>] --log=<LOG_PATH> --lang=en
   ```

2. 上記コマンドをバックグラウンドで起動する。
   - `--plan` に絶対パスを渡す
   - `--planner` / `--builder` / `--verifier` は、引数で指定された場合のみコマンドに含める。省略された kind のフラグは付与しない
   - `--log` は `REPO_ROOT/.runs/whirlwind.log` を使う
   - CLI 側が計画ファイルの解釈、マイルストーン変換、内部検証を担当する前提とする

3. 起動後、ユーザーにタスク ID と使用した planner/builder/verifier kind を共有する

---

### Phase 3: Progress Monitoring

whirlwind がバックグラウンドで実行中の間、`/loop` スキルを使って **1 分間隔** で進捗を監視する。

1. `/loop 1m` を起動し、以下のプロンプトを実行する:
   - `TaskOutput` でバックグラウンドの whirlwind タスク出力を取得
   - 最新の出力から進捗状況を要約してユーザーに共有
   - タスクが完了していたら `/loop` を停止

2. whirlwind 完了通知を受けたら最終結果を報告する。

---

## エラーハンドリング

- 計画ファイルが見つからない場合 → エラーメッセージを出して終了
- `--planner` / `--builder` / `--verifier` に無効な値が指定された場合 → エラーメッセージを出して終了
  - 有効な値: `claude-code`, `claude`, `claudecode`, `codex`, `api`, `mock`
- `git rev-parse --show-toplevel` に失敗した場合 → Git 管理下のリポジトリで実行するよう案内して終了
- バックグラウンド起動に失敗した場合 → 実行コマンドと失敗内容を表示して終了

## 関連スキル

- **log-audit** — ralph-whirlwind 実行後のログを分析し、バグやパフォーマンス問題を検出・チケット起票する
