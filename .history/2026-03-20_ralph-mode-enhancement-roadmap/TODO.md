# Ralph モード強化ロードマップ

**作成日**: 2026-03-20
**調査背景**: 7つの専門エージェント + 3つの追加調査エージェントによるコードベース徹底調査

---

## 優先度: HIGH

### 1. Verifier サイレント承認バグ修正

**問題**: `verifier.mbt:107` — Verifier バックエンドが障害を起こした場合（レートリミット、ネットワークエラー、クラッシュ等）、黙って `Approved` を返す。Review モジュールでは同一パターンが修正済み（障害時は `Rejected` を返す）。

**スコープ**: コード1行修正 + テスト1件追加

**対象ファイル**:
- `src/ralph/verifier.mbt:107` — `_ => Approved` を `_ => MilestoneFailed("Verifier backend failed: {err}")` に変更
- `src/ralph/verifier_test.mbt` — Review モジュールの `review_perspective propagates backend failure instead of silent approval` に相当するテストを追加

**HIGH の理由**: 検証なしで Wave が承認される = サイレントな品質低下。実質的にバグ。

---

## 優先度: MEDIUM

### 3. Ralph resume 機能（current_wave の活用）

**問題**: `Milestone` 構造体の `current_wave` フィールドは JSON にシリアライズ/デシリアライズされるが、**ランタイムで一度も読み書きされていない**（dead code）。Ralph モードには通常モードのようなインタラクティブ resume がなく、実行中にクラッシュすると Wave 全体が最初からやり直しになる。

**調査結果**:
- `current_wave` は `run_wave()` で更新されず、`run_milestone()` でも読まれない
- Wave 追跡は `next_wave_number()` でタスク状態から動的に算出（current_wave 不要）
- 通常モードの resume: `.tornado/session.json` + インタラクティブプロンプト + エージェントセッション復元
- Ralph の resume: マイルストーンレベルのみ（pending/in_progress ステータス）

**Option A: フィールド削除（最小対応）**
- resume が優先でなければ `current_wave` を Milestone 構造体・JSON スキーマから削除
- dead code の除去

**Option B: 本格 resume 実装（推奨）**
1. `src/ralph/ralph_loop.mbt` — `run_wave()` で `milestone.current_wave = wave` を更新
2. `src/ralph/ralph_loop.mbt` — resume 時に Done タスクをスキップ:
   ```moonbit
   for task in tasks {
     match task.status { Done => continue; _ => run_task(task) }
   }
   ```
3. `src/cmd/app/main.mbt` — Ralph 用 resume プロンプト追加:
   ```
   // milestones.json に in_progress マイルストーンがあれば
   // "Milestone M1, Wave W2 から再開しますか？ [Y/n]"
   ```
4. `src/ralph/milestone.mbt` — Wave 完了ごとにマイルストーン状態を保存（ループ終了時だけでなく）

---

### 4. バージョン整合（moon.mod.json）

**問題**: `moon.mod.json` v0.5.0（モジュール名 `mizchi/tornado`）と `package.json` v0.6.0（`@ymdvsymd/tornado`）でバージョンが乖離。moon.mod.json のリポジトリ URL も旧組織（`github.com/mizchi/tornado`）のまま。

**調査結果**:
- MoonBit (mooncakes.io) と npm は独立したエコシステム — バージョン連動の仕組みなし
- `.mooncakes/` ディレクトリ + `.moon-lock` が存在 — mooncakes.io に公開済み
- コード内でバージョン番号を参照する箇所なし — 機能的な影響ゼロ
- `mizchi/tornado` は MoonBit 内部のモジュール名、npm 配布名とは別

**実装**:
- `moon.mod.json` — バージョンを 0.6.0 に更新、リポジトリ URL を `github.com/ymdvsymd/tornado` に修正
- 検討: モジュール名を `ymdvsymd/tornado` に変更（mooncakes.io の再公開が必要になる可能性）
- 公開手順のドキュメント化（どのバージョンファイルをいつ更新するか）

---

## 優先度: LOW（実装不要 / 将来検討）

### 5. review_interval の Ralph モード対応 — 実装しない

**調査結論**: アーキテクチャの不一致。実装すべきでない。

**根拠**:
- 通常モード: `review_interval=N` = 「N回 dev してから1回 review」= バッチングパラダイム
- Ralph モード: 毎 Wave を検証 = 品質ゲートパラダイム
- Wave 検証のスキップは Ralph の存在意義（検証済みマイルストーン）を否定する
- コスト節約は微小（~$0.007/マイルストーン）
- 実装の複雑さ・リスクが利益を大幅に上回る

**対応**:
- `ralph_loop.mbt` に `review_interval` を意図的に使用していない理由のコードコメントを追加
- オプション: `preset_ralph()` から `review_interval` を削除して混乱を回避
- **Ralph を速く/安くしたいユーザーへの代替案**:
  - `max_rework_attempts` を 1-2 に減らす
  - Verifier に安価なモデルを使う（エージェント設定で変更可能）
  - 検証頻度を下げたいなら通常モード + `--review-interval=5` を使用

### 6. マイルストーンの動的追加/削除 — 将来検討

現在は実行前に JSON で事前定義が必要。長期実行プロジェクトでは有用だが、複雑さが大きい。
明確なユーザー需要が出るまで保留。

---

## 参考: Dead Code / クリーンアップ候補

| 対象                              | 場所                            | 状態                                                               |
| --------------------------------- | ------------------------------- | ------------------------------------------------------------------ |
| `plan_doc` フィールド (RalphTask) | `types.mbt`                     | どこからも読まれていない — 削除 or 実装                            |
| `MockBackend::failing()`          | `agent/mock.mbt:72`             | 未使用 — `FailingMockBackend` が代替                               |
| `Orchestrator::run()`             | `orchestrator/orchestrator.mbt` | ランタイムから呼ばれていない — ライブラリ API として文書化 or 削除 |
| `spawn/` モジュール               | `src/spawn/`                    | 他モジュールからインポートなし — 将来の非同期基盤                  |
