---
name: log-audit
description: >
  whirlwind実行ログを分析し、バグ・パフォーマンスボトルネックを検出してbdチケットを起票する。
  最新の.runsログを自動検出、またはパス指定可。タイムライン構築→異常検出→レポート→チケット起票。
  "log-audit", "ログ分析", "バグ検出", "ログレビュー", "run分析", "audit log", "analyze log".
argument-hint: log_path:whirlwind.logのパス（省略時は.runs/内の最新ログを自動検出）
origin: whirlwind
---

# log-audit

## 引数

```
/log-audit [<path-to-whirlwind.log>] [--priority=<0-4>] [--dry-run]
```

- `<path-to-whirlwind.log>`: 分析対象のログファイルパス。省略時は `.runs/` 内の最新 `whirlwind.log` を自動検出
- `--priority=<0-4>`: 起票するチケットのデフォルト優先度（デフォルト: 2）
- `--dry-run`: チケットを起票せず、検出結果のレポートのみ出力

`$ARGUMENTS` の内容: `$ARGUMENTS`

---

## Phase 1: ログファイル特定

1. `$ARGUMENTS` を解析する:
   - 最初の `--` で始まらないトークンを `LOG_PATH` とする
   - `--priority=<value>` があれば `DEFAULT_PRIORITY` に格納（デフォルト: 2）
   - `--dry-run` があれば `DRY_RUN=true`

2. `LOG_PATH` が未指定の場合、最新ログを自動検出:

   ```bash
   ls -dt .runs/*/whirlwind.log 2>/dev/null | head -1
   ```

---

## Phase 2: タイムライン構築

### 2-1. セッション一覧の抽出

`[INFO] Session initialized:` 行からセッション情報を抽出:
- タイムスタンプ
- model 名
- tools 数
- ロール（planner / builder / verifier — 直前の context から判定）

### 2-2. Result 行の解析

`[INFO] Result:` 行から以下を抽出:
- success / failure
- cost（$金額）
- duration（秒）
- api 時間（秒）
- turns 数
- tokens（input / output / cache_read）

### 2-3. タイムラインテーブルの構築

以下の情報をフェーズごとに整理する:
- Planner: 起動→完了の所要時間、コスト
- Builder Wave N: 各タスクの並列実行時間、トークン量
- Verifier: 各観点（CodeQuality / Performance / Security / GoalAlignment）の所要時間、コスト
- 全体の開始→完了時間

---

## Phase 3: 異常検出

### 3-1. `[BUG]` タイムスタンプ異常

- 同一セッション内の全イベントが同じタイムスタンプ → 「ログタイムスタンプバッチング」
- タイムスタンプが逆順になっている → 「タイムスタンプ逆転」

### 3-2. `[BUG]` 計測値の不整合

- `api > duration` → 「API時間が壁時計時間を超過」
- `cost` が負値または異常に大きい → 「コスト異常値」
- `turns` が 0 なのに result が success → 「ターン数不整合」

### 3-3. `[BUG]` ビルダー間衝突

- 同一 Wave 内の複数ビルダーが同じファイルを編集した痕跡を検出:
  - `[OUT] [builder]` の出力に同一ファイルパスへの変更言及が複数タスクで出現
  - 「revert」「reverted」「undo」等のキーワードを含む出力

### 3-4. `[PERF]` トークン効率

- Input tokens が 500K を超えるビルダーセッション → 「過大な入力トークン」
- Output / Input 比率が 1:100 以下 → 「極端な入出力比」
- cache_read 率が 90% 以上 → 情報として記録（異常ではないが注意）

### 3-5. `[PERF]` コスト異常

- 同種 Verifier 観点間でコストが 2 倍以上乖離 → 「Verifier コスト不均衡」
- Planner のコストが全体の 30% 超 → 「Planner コスト比率過大」

### 3-6. `[BUG]` 機能面

- `[OUT] [builder]` に「failed」「failure」「error」を含むが Result は success → 「偽成功の可能性」
- Verifier が問題を検出しつつ `<wave_approved>` を出力 → 「問題検出後の無条件承認」
- 「pre-existing」「unrelated」等で既存バグを報告しつつスキップ → 「既存バグの放置」

---

## Phase 4: レポート出力

```markdown
## whirlwind ログ分析レポート

**ログ**: <ファイルパス>
**実行時間**: <開始> → <終了> (合計 X分Y秒)
**総コスト**: $X.XX (planner: $X.XX, builder: N/A, verifier: $X.XX)

### タイムライン
| 時刻 | イベント | 所要時間 |
|------|---------|---------|

### 検出事項 (N件)

#### [BUG] タイトル (重大度: 高/中/低)
- **現象**: ...
- **該当行**: line XX-YY
- **推奨優先度**: P1

#### [PERF] タイトル
- **現象**: ...
- **数値**: ...

### トークン使用量サマリー
| タスク | Input | Output | Cache率 |
|--------|-------|--------|---------|
```

---

## Phase 5: 依存関係分析

`rules/bd-dependency-protocol.md` のプロトコルに従う。

### 5-1. 既存チケットスキャン

```bash
bd list --status=open
bd list --status=in_progress
```

既存チケットとの重複・依存を確認する。特に:
- 同一ログ行番号を参照する既存 bug チケット → 重複候補
- 同一コンポーネント（planner / builder / verifier）の既存チケット → 依存候補

### 5-2. Intra-batch 依存の分析

Phase 6 で起票する [BUG] と [PERF] チケット間の依存:
- 同一 root cause から派生する [BUG] 同士 → root cause 修正チケットが先
- [BUG] が修正されないと [PERF] 改善の効果が不明 → [BUG] が [PERF] をブロック
- 同一コンポーネントの複数 [BUG] → 基盤寄りの修正が先

分析結果を `DEPENDENCY_PLAN` に格納。

`DRY_RUN=true` の場合、依存分析結果をレポートに含める。

---

## Phase 6: チケット起票

### 6-0. チケット品質ゲート

チケット起票前に、各検出事項を以下の 2 つのゲートで評価する。

#### ゲート 1: エージェント実行可能性（P4 強制ルール）

`rules/bd-ticket-quality.md` の品質ゲートに従う。P4 に降格された項目にはレポートで `[注意] P4降格: エージェント実行不可` と注記する。

#### ゲート 2: プロダクト非依存ルール

how（description 内の修正方針）には、**分析対象ログを出力したプロダクト固有の技術スタック・ツール・設定に依存した内容を含めてはならない**。

- **禁止例**: `just live` の実行制御、`moon.pkg.json` の設定変更、プロンプトへの特定ツール名（`just`, `moon`, `npm` 等）の埋め込み、プロダクト側の CI/CD 設定変更
- **許可範囲**: whirlwind フレームワーク自体のコード（`src/`, `sdk/`）に閉じた修正のみ
- **例外処理**: プロダクト固有の修正しか解決策がない場合は、`P4` チケットとして起票を提案し、ユーザー判断に委ねる。レポートには `[注意] P4提案: プロダクト固有の修正が必要` と注記する

---

1. ユーザーに検出事項一覧を提示し、チケット化する項目の確認を求める:
   - 各項目の推奨優先度を表示
   - ユーザーが優先度を変更可能
   - ユーザーが除外する項目を選択可能

2. 確認後、`bd create` で一括起票:

   ```bash
   bd create --title="<タイトル>" --description="<詳細>" --type=bug --priority=<N> --acceptance="<AC>"
   ```

   - `[BUG]` タグ → `--type=bug`
   - `[PERF]` タグ → `--type=task`（改善タスク）
   - description と AC は `rules/bd-ticket-quality.md` のテンプレート・要件に従う
   - description にはログの該当行番号、再現手順を追加で含める
   - `[PERF]` の AC には改善の数値目標を含める（例: 「Input tokens が 300K 以下に削減されること」）

3. 起票結果のサマリーを表示:

   ```markdown
   ### 起票済みチケット
   | ID | タイトル | 優先度 | タイプ | AC | 依存 |
   |----|---------|--------|--------|-----|------|
   | whirlwind-xxx | ... | P1 | bug | リグレッションテスト追加・パス | |
   ```

4. **依存関係の設定**:

   `DEPENDENCY_PLAN` に基づいてユーザーに確認テーブルを表示する（`rules/bd-dependency-protocol.md` Step 4 形式）。

   承認後:

   ```bash
   bd dep add <blocked-id> <blocking-id>
   ```

   依存関係がある場合、notes に依存先チケット ID と理由を記載する。

---

## エラーハンドリング

- ログファイルが見つからない → エラーメッセージを出して終了
- ログが空 or 不正な形式 → 「解析不可」としてエラー出力
- `bd` コマンドが利用不可 → チケット起票をスキップし、レポートのみ出力
- 異常が 0 件 → 「異常は検出されませんでした」と報告して正常終了

## 関連スキル

- **bd-detail** — チケット精緻化時の依存関係分析。log-audit で起票後に依存を見直す場合に使用する
- **bd-runner** — log-audit の前段。bd-runner の実行ログを log-audit で分析する
- **ralph-whirlwind** — whirlwind 実行後のログを log-audit で分析する
- **plan-to-beads** — log-audit で検出したバグをチケット起票する際の実行チェーンの起点
