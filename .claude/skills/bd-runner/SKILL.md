---
name: bd-runner
description: >
  bdチケットを優先度ベースで自動ループ実行するオーケストレーター。
  readyチケットをTDDで実装し、並列実行・結合テスト・バグ起票・コミット・クローズまで一貫処理。
  "bd-runner", "チケット自動実行", "バグ一括修正", "ticket runner", "auto-fix", "チケット消化".
arguments: priority:優先度閾値(P0-P4、デフォルトP3)
---

# bd-runner: bd チケット自動実行オーケストレーター

## 引数

```
/bd-runner [P0-P4] [--sequential] [--dry-run] [--type=bug|task|feature]
```

- `P0-P4`: 優先度閾値。この優先度以下（数値として以下）のreadyチケットを実行。デフォルト: `P3`
- `--sequential`: 並列実行を無効化し、全チケットを直列で処理
- `--dry-run`: 実行計画を表示するのみ。コード変更なし
- `--type=<type>`: チケット種別でフィルタ（bug, task, feature）

`$ARGUMENTS` の内容: `$ARGUMENTS`

## オーケストレーション概要

1. **チケット収集・バッチ計画** — readyチケット取得、並列安全性分析、バッチ分割
2. **チケット実行** — TDD（テスト先行）で各チケットを修正・実装
3. **バッチオーケストレーション** — サブエージェント並列起動、バッチ毎 `just live`
4. **障害分離・バグ起票** — live失敗時のper-ticket isolation、P1でバグ起票
5. **クローズ・最終レポート** — commit hashでチケットクローズ、サマリー出力

各フェーズを**必ず順番に**実行すること。

---

### Phase 1: チケット収集・バッチ計画

1. `$ARGUMENTS` を解析する:
   - 最初の `P` で始まるトークン（P0〜P4）を `PRIORITY_THRESHOLD` とする（デフォルト: `3` = P3）
   - `--sequential` があれば `SEQUENTIAL=true`
   - `--dry-run` があれば `DRY_RUN=true`
   - `--type=<value>` があれば `TYPE_FILTER` に格納

2. readyチケットを取得:

   ```bash
   bd ready
   ```

3. 優先度フィルタ: `PRIORITY_THRESHOLD` 以下（P0が最高=0、P4が最低=4）のチケットのみ残す。
   `TYPE_FILTER` が指定されていれば種別でも絞り込む。

4. 対象チケットが 0 件の場合、「対象チケットなし」と報告して終了。

5. 各チケットの詳細を取得:

   ```bash
   bd show <ticket-id>
   ```

   タイトル、説明、種別、優先度を記録する。

6. **並列安全性の分析**（`SEQUENTIAL=true` の場合はスキップ、全て直列）:
   - 各チケットの説明から対象ファイルパス・モジュール名を抽出
   - 異なるモジュール/ディレクトリのチケット → 同一バッチ（並列可）
   - 同一ファイルに言及するチケット → 別バッチ（直列）
   - 判定不能 → 別バッチ（保守的に直列）

7. 実行計画を表示:

   ```markdown
   ## bd-runner 実行計画

   **優先度閾値**: P<N>
   **対象チケット数**: N
   **モード**: 並列 / 直列

   ### Batch 1 (並列)
   | ID | 優先度 | 種別 | タイトル |
   |----|--------|------|---------|
   | tornado-xxx | P1 | bug | ... |
   | tornado-yyy | P1 | bug | ... |

   ### Batch 2 (直列)
   | ID | 優先度 | 種別 | タイトル |
   |----|--------|------|---------|
   | tornado-zzz | P2 | task | ... |
   ```

8. `DRY_RUN=true` の場合、ここで終了。

---

### Phase 2: チケット実行（サブエージェント単位）

各チケットは `references/ticket-execution-protocol.md` の手順に従って実行する。

サブエージェントへのプロンプトには以下を含める:
- `references/ticket-execution-protocol.md` の全内容
- 対象チケットID
- チケットのタイトルと説明（`bd show` の出力）
- プロジェクトのテストコマンド: `just test`, `just live`

サブエージェントは以下を返す:
- 成功/失敗のステータス
- commit hash（成功時）
- 変更ファイル一覧
- テスト結果の要約
- エラー詳細（失敗時）

---

### Phase 3: バッチオーケストレーション

各バッチを順番に処理する:

1. **バッチ内チケットが 1 つ**:
   - サブエージェントを起動せず、Phase 2 の手順を直接実行する

2. **バッチ内チケットが 2 つ以上**:
   - 各チケットに対してサブエージェントを**並列起動**する:

     ```
     Agent tool（チケット毎に1つ）:
       subagent_type: "general-purpose"
       isolation: "worktree"
       mode: "bypassPermissions"
       prompt: <ticket-execution-protocol + チケット詳細>
     ```

   - 全サブエージェントの完了を待機する

3. **結果処理**:
   - 成功 → commit hash を記録
   - 失敗 → エラーを記録、チケットをスキップ扱い
   - worktree に変更がある場合 → worktree のブランチからメインブランチへマージ

4. **バッチ後結合テスト**:

   ```bash
   just test
   ```

   ユニットテスト通過を確認後:

   ```bash
   just live
   ```

   - **成功** → 次バッチへ進行
   - **失敗** → Phase 4（障害分離）へ移行

5. 全バッチ完了後 → Phase 5 へ

---

### Phase 4: 障害分離・バグ起票（バッチ `just live` 失敗時のみ）

バッチの `just live` が失敗した場合にのみ実行する。

1. **Per-ticket isolation**: バッチ内の各 commit を 1 つずつテスト:
   - バッチ内の全 commit を `git revert` で一旦戻す
   - 1 つずつ `git cherry-pick` して `just live` を実行
   - `just live` が失敗する commit が原因チケット

2. **原因チケットの処理**:
   - 原因 commit を revert する
   - チケットにノート追加:
     ```bash
     bd update <id> --notes="just live failure: <失敗内容の要約>"
     ```

3. **新規バグ起票**（P1 固定）:

   ```bash
   bd create --title="[bd-runner] <失敗の要約>" \
     --description="just live テスト失敗。元チケット: <ticket-id>\n\n失敗詳細:\n<エラー出力>" \
     --type=bug --priority=1
   ```

4. **ループ再実行判定**:
   - 新チケットが `PRIORITY_THRESHOLD` 以内 → 現バッチ完了後にループに追加
   - `ITERATION` カウンタをインクリメント
   - **サーキットブレーカー**: `ITERATION >= 5` で停止、残バグを報告して Phase 5 へ

5. 残りの成功 commit は維持し、次バッチへ進行

---

### Phase 5: クローズ・最終レポート

1. **成功チケットのクローズ**:

   各成功チケットに対して:

   ```bash
   bd close <id> --reason="Fixed in commit <hash>. Regression test added."
   ```

2. **失敗チケットのノート追加**:

   ```bash
   bd update <id> --notes="bd-runner attempt failed: <エラー要約>. Manual intervention required."
   ```

3. **最終サマリー表示**:

   ```markdown
   ## bd-runner 実行レポート

   **優先度閾値**: P<N>
   **イテレーション**: <N> / 5
   **処理チケット数**: <N>

   ### 完了
   | チケット | タイトル | Commit | テスト |
   |----------|---------|--------|--------|
   | tornado-xxx | ... | abc1234 | PASS |

   ### 失敗
   | チケット | タイトル | エラー |
   |----------|---------|--------|
   | tornado-yyy | ... | <要約> |

   ### 新規起票バグ
   | チケット | タイトル | 優先度 |
   |----------|---------|--------|
   | tornado-zzz | ... | P1 |

   ### テスト結果
   - `just test`: PASS / FAIL
   - `just live`: PASS / FAIL
   ```

---

## エラーハンドリング

| シナリオ | アクション |
|----------|-----------|
| `bd ready` が 0 件 | 「対象チケットなし」で終了 |
| `bd update --claim` 失敗 | スキップ、次のチケットへ |
| TDD テスト作成失敗 | チケットを失敗マーク、unclaim、次へ |
| 実装後 `just test` 失敗 | 変更を revert、失敗マーク、次へ |
| worktree マージ競合 | 手動解決フラグ、他バッチ続行 |
| `just live` 失敗 | Phase 4 で障害分離・バグ起票 |
| サーキットブレーカー発動（5回） | 残バグ報告して Phase 5 へ |
| サブエージェント タイムアウト | 失敗扱い、ノート追加、次へ |
