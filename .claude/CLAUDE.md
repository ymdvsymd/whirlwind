# Whirlwind — AI エージェント指示書

## アーキテクチャ
- **MoonBit** コア: `src/` (ビルド: `moon build/test/fmt`)
- **TypeScript** SDK: `sdk/` (ビルド: `tsc`)
- **CLI**: `src/cmd/app/` — MoonBit アプリを JS にコンパイル
- **ドキュメント**: `docs/` (番号付きガイド), `docs/adrs/` (ADR)

## ビルド・テスト
`just` (参照: `justfile`) と `moon` (MoonBit ツールチェイン) を使用。
```
just test      # ユニットテスト (SDK + MoonBit)
just mock      # E2E (モックサーバー)
just live      # E2E (実サーバー)
just coverage  # SDK テストカバレッジ
just fmt       # MoonBit フォーマット
```

## 品質ルール
- コミット前に `just test` を実行すること
- `moon fmt` と `npx prettier --write` でフォーマット
- テスト以外のファイルで `console.log` 禁止 (hook で強制)

## 課題管理
**bd (beads)** を使用。`bd prime` でワークフローとコマンドの詳細を確認。

## セッション完了手順
1. 残作業を bd チケットとして起票
2. 品質ゲート実行: `just test`
3. チケットのステータス更新・完了分をクローズ
4. プッシュ: `git pull --rebase && bd dolt push && git push`
5. `git status` が "up to date with origin" であることを確認

## ルール一覧
詳細な規約は `.claude/rules/` 配下に定義されている。

| ファイル | 概要 |
|---|---|
| `rules/build-and-test.md` | ビルド・テスト規約 — just コマンド必須、live 結合テスト必須、バグ修正時リグレッションテスト必須 |
| `rules/planning.md` | 計画作成規約 — Plan mode 出力規約、計画ファイルに live 結合テストを含める |
| `rules/bd-workflow.md` | bd チケット運用規約 — 計画のチケット登録、結合テストバグのチケット起票 |
| `rules/research.md` | 技術調査規約 — ref MCP ツールの併用 |
