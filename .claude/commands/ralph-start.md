---
description: 'Convert a plan file (Markdown) to tornado Ralph mode input files and launch tornado'
arguments: plan_file:計画ファイル(Markdown)のパス
---

# ralph-start: 計画ファイル -> tornado Ralph モード起動

計画ファイル（Markdown）を tornado の Ralph モードに必要な `tornado.json` + `milestones.json` に変換し、tornado を起動するコマンド。

## 引数

```
/ralph-start <plan-file.md> [--dev=<kind>] [--verifier=<kind>]
```

`$ARGUMENTS` の内容: `$ARGUMENTS`

## 実行手順

以下の Phase 1〜4 を**必ず順番に**実行すること。

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

### Phase 2: 計画ファイル -> マイルストーン + タスク変換

計画ファイルの Markdown を以下の規則でパースする。

**重要: 計画ファイルが日本語の場合、英語に翻訳してからタスク化する。**

- `description` 内の Task / Acceptance Criteria / Plan Context はすべて英語で記述する
- `goal` フィールドも英語にする
- コード内の識別子やファイルパスはそのまま保持する

#### パース規則

| Markdown 要素               | 変換先                                                |
| --------------------------- | ----------------------------------------------------- |
| `# 見出し` (最初のH1)       | プロジェクト名（ディレクトリ名に使用）                |
| `## 見出し`                 | マイルストーンの `goal`（後述の goal 構成規則に従う） |
| `##` がない場合             | ファイル全体を1マイルストーンとして扱う               |
| `-` / `*` / `N.` リスト項目 | タスクの `description`                                |
| `###` サブ見出し            | 同一マイルストーン内の Wave 区切り（wave を +1）      |

#### goal の構成規則（Verifier 検証精度向上のため）

`goal` は Verifier エージェントが Wave 検証時に参照する。
Verifier は `task.description` を受け取らないため、`goal` が検証の主要な文脈となる。

各マイルストーンの `goal` は以下の構成で生成すること。**英語で記述する。**

```
<## 見出しから取得した目標テキスト（英語）>

---
## Plan Context
<計画ファイルの全内容（英語に翻訳）>
```

- `## 見出し` のテキストを英語に翻訳して先頭に置く
- `---` セパレータの後に `## Plan Context` として計画ファイル全文の英語訳を付加する
- これにより Verifier が「タスク結果がプラン全体の意図に合っているか」を正確に判断できる

#### ディレクトリ名の生成

- 最初の `# 見出し` のテキストを**英語に翻訳して**タイトルとする（なければファイル名のベースネーム）
- 小文字化、スペース/アンダースコアをハイフンに変換、英数字とハイフン以外を除去、50文字以内に切り詰め
- 出力ディレクトリ: `{repo_root}/.history/{yyyy-mm-dd}_{kebab-case-name}/`

#### タスク ID 命名規則

- マイルストーン `m1` のタスク: `m1-t1`, `m1-t2`, ...
- マイルストーン `m2` のタスク: `m2-t1`, `m2-t2`, ...

#### description の拡張（最重要）

`description` は Builder (Codex/Claude Code) に渡される**唯一の入力**である。
system_prompt は空、milestone の goal も Builder には渡されない。

> **Note:** 計画ファイルの全文コンテキストは `goal` と `description` の両方に含まれる。
>
> - `goal` 側: Verifier が Wave 検証時に参照（Builder は参照しない）
> - `description` 側: Builder が実装時に参照（Verifier は参照しない）
> - 将来 Tornado 本体が修正され Builder に goal が渡されるようになれば、description 側の Plan Context は削除可能

各タスクの `description` は以下の3セクションで構成すること。**すべて英語で記述する**（計画ファイルが日本語の場合は翻訳する）。

##### 1. Task（実装指示）

- 曖昧な項目は具体的な実装指示に書き換える
- ファイルパス、期待する動作、実装の詳細を含める
- Claude Code に直接指示するのと同じ粒度で書く

##### 2. Acceptance Criteria（受け入れ条件）

Builder エージェントが**タスク完了後に自分自身で検証可能**な条件を必ず含める。
条件は以下の3種類のみ。曖昧な条件は禁止。

- **File exists**: `- [ ] File exists: <path>`
- **Contains**: `- [ ] <path> contains: <expected content>`
- **Command**: `- [ ] Run: <command> → <expected result>`

##### 3. Plan Context

計画ファイルの全内容を**英語に翻訳して**埋め込む。

##### description テンプレート

```
## Task
<concrete implementation instructions in English>

## Acceptance Criteria
- [ ] File exists: <path>
- [ ] <path> contains: <expected content>
- [ ] Run: <command> → <expected result>

---
## Plan Context
<full plan file content, translated to English>
```

---

### Phase 3: 出力ファイル生成

出力ディレクトリを作成し、2つのファイルを書き出す。

#### 3-1. milestones.json

```json
{
  "milestones": [
    {
      "id": "m1",
      "goal": "Goal text from ## heading (in English)\n\n---\n## Plan Context\n<full plan file content, translated to English>",
      "status": "pending",
      "current_wave": 0,
      "tasks": [
        {
          "id": "m1-t1",
          "description": "## Task\n<concrete instructions in English>\n\n## Acceptance Criteria\n- [ ] File exists: <path>\n- [ ] <path> contains: <expected content>\n- [ ] Run: <command> → <expected result>\n\n---\n## Plan Context\n...",
          "wave": 0,
          "status": "pending",
          "result": null,
          "plan_doc": null
        }
      ]
    }
  ]
}
```

#### 3-2. tornado.json

`milestones_path` は**絶対パス**で指定すること（tornado は process.cwd() で動作するため）。

```json
{
  "ralph_enabled": true,
  "milestones_path": "<絶対パス>/.history/{date}_{name}/milestones.json",
  "review_dir": ".history/{date}_{name}",
  "max_rework_attempts": 3,
  "agents": [
    {
      "id": "planner",
      "kind": "mock",
      "role": "planner",
      "max_iterations": 1
    },
    {
      "id": "builder",
      "kind": "<DEV_KIND>",
      "role": "dev",
      "max_iterations": 10
    },
    {
      "id": "verifier",
      "kind": "<VERIFIER_KIND>",
      "role": "verifier",
      "max_iterations": 5
    }
  ]
}
```

注意:

- Planner は `"kind": "mock"` 固定（バリデーション通過用。tasks が事前定義済みなので実行されない）
- Builder の kind は `DEV_KIND`（デフォルト: `codex`）
- Verifier の kind は `VERIFIER_KIND`（デフォルト: `claude-code`）

---

### Phase 4: 検証・起動

1. **JSON バリデーション**: 生成した両ファイルを `jq .` で検証

2. **サマリー表示**: 以下の情報を表示する

   ```
   === Ralph Start ===
   Plan file:    <plan-file.md>
   Output dir:   .history/{date}_{name}/
   Milestones:   N 個
   Total tasks:  N 個
   Builder:      <DEV_KIND>
   Verifier:     <VERIFIER_KIND>

   Milestones:
     m1: <goal の先頭行（見出しテキスト）> (N tasks, M waves)
     m2: <goal の先頭行（見出しテキスト）> (N tasks, M waves)
     ...
   ```

3. **tornado 起動**:

   ```bash
   npx -y @mizchi/tornado --ralph --config=<tornado.json の絶対パス> --lang=ja
   ```

---

## エラーハンドリング

- 計画ファイルが見つからない場合 -> エラーメッセージを出して終了
- 計画ファイルにリスト項目が1つもない場合 -> エラーメッセージを出して終了
- `--dev` / `--verifier` に無効な値が指定された場合 -> エラーメッセージを出して終了
  - 有効な値: `claude-code`, `claude`, `claudecode`, `codex`, `api`, `mock`
- JSON バリデーション失敗 -> エラーメッセージを出して終了（ファイルは残す）
