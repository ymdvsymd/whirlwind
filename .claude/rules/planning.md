# 計画作成規約

## Plan mode 出力規約

- Plan mode で計画を作成する際は、計画ファイルのパスを必ず明示すること。
- 例: `計画ファイル: ~/.claude/plans/xxx.md`
  （`~` はユーザーのホームディレクトリの絶対パスに展開して出力すること）

## 計画ファイルに live 結合テストを含める

計画ファイル作成時、検証セクション（Verification Steps 等）には `just live`（実エージェントを使った結合テスト）を必ず含めること。`just test` と `just mock` だけでは不十分。

mock テストだけでは実エージェント環境での問題（CLAUDECODE 環境変数問題等）を検出できない。/ralph-tornado 実行時のマイルストーンにも含める。
