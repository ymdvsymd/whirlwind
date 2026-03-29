# Whirlwind - Multi-Agent Development Orchestrator: 総合調査報告

**初版調査日**: 2026-03-07
**最終更新日**: 2026-03-29
**調査手法**: 7つの専門エージェントによる並行多角的調査
**リポジトリ**: https://github.com/ymdvsymd/whirlwind
**バージョン**: 0.3.1 (npm: @ymdvsymd/whirlwind)

---

## プロジェクト概要

Whirlwind は **MoonBit** で実装されたマルチエージェント開発オーケストレーターです。
複数の AI エージェント（Claude Code, OpenAI Codex）を統合し、タスク分解・実行・レビュー・フィードバックの自律開発ループを実現します。

### 技術スタック

| 項目 | 技術 |
|------|------|
| コア言語 | MoonBit (JSターゲット) |
| SDK層 | TypeScript (ES2022) |
| 外部依存 | @anthropic-ai/claude-agent-sdk, @openai/codex-sdk |
| MoonBit依存 | moonbitlang/x |
| ビルド | moon + npm + justfile |
| ランタイム | Node.js >= 18 |
| 配布 | npm (@ymdvsymd/whirlwind) |

### 実行モード

**Ralph モード**: マイルストーン駆動自律開発（Planner → Builder → Verifier）。
全マイルストーン完了で自動終了。

---

## 調査ドキュメント一覧

| # | ファイル | 調査視点 | 内容 |
|---|---------|---------|------|
| 1 | [01-architecture.md](./01-architecture.md) | アーキテクチャ | モジュール依存関係、レイヤー構造、設計パターン、データフロー |
| 2 | [02-moonbit-core.md](./02-moonbit-core.md) | MoonBitコア | 全12モジュールの実装詳細、型定義、状態遷移、API |
| 3 | [03-sdk-integration.md](./03-sdk-integration.md) | SDK統合 | TypeScript SDK、Claude/Codex統合、FFIブリッジ、ストリーミング |
| 4 | [04-testing-quality.md](./04-testing-quality.md) | テスト品質 | 34テストファイル、約554テストケース、カバレッジ、ビルドシステム |
| 5 | [05-workflow-ralph.md](./05-workflow-ralph.md) | ワークフロー & Ralph利用ガイド | Ralph自律ループ、CLIオプション、設定、マイルストーン、3大エージェント、レビューサイクル |
| 6 | [06-harness-infrastructure.md](./06-harness-infrastructure.md) | ハーネス・インフラ | フック、CI、eval ハーネス |

---

## プロジェクト構造

```
whirlwind/
  moon.mod.json          # MoonBit パッケージ定義
  package.json           # npm パッケージ定義
  whirlwind.json         # デフォルト設定ファイル
  justfile               # ビルドタスク
  tsconfig.sdk.json      # TypeScript SDK 設定
  src/
    types/               # Layer 0: ドメイン型定義
    util/                # Layer 0: 汎用ユーティリティ
    config/              # Layer 1: 設定パース・バリデーション
    cli/                 # Layer 1: CLI引数パース
    display/             # Layer 1: 表示フォーマット
    prompts/             # Layer 1: プロンプトテンプレート
    agent/               # Layer 2: エージェント抽象化・実行
    review/              # Layer 2: 3観点レビュー
    ralph/               # Layer 3: マイルストーン駆動自律ループ
    plan/                # Layer 3: Plan Markdown パース・変換
    cmd/helpers/         # Layer 4: ヘルパー関数
    cmd/app/             # Layer 4: エントリーポイント・FFI
  sdk/
    runner-io.mts        # 共通I/O
    agent-adapter.mts    # アダプター抽象インターフェース
    agent-runner.mts     # 実行エンジン
    claude-adapter.mts   # Claude Agent SDK 統合
    claude-runner.mts    # Claude ランナー
    codex-adapter.mts    # Codex SDK 統合
    codex-runner.mts     # Codex ランナー
    codex-normalizer.mts # Codex→Claude 形式正規化
    parallel-runner.mts  # 並列実行ランナー
    stdin-watcher.mjs    # ユーザー入力監視
```

---

## 主要な調査所見

### 強み

1. **型安全な状態管理** - MoonBitの代数的データ型でコンパイル時に状態網羅性を保証
2. **AgentBackend trait** - 新エージェント種追加が容易なプラグイン設計
3. **統一ストリーミング** - Claude/Codexの異なるイベント形式をアダプターで統一
4. **4観点並列検証** - CodeQuality/Performance/Security/GoalAlignment の並列レビュー（v0.3.0）
5. **テストカバレッジ** - コアロジック中心に約554テストケース（34ファイル）
6. **明確なレイヤー分離** - types → config → agent → orchestrator → main
7. **Verifier フィードバック実装** - ターゲット指定のフィードバックルーティング
8. **ralph-whirlwind スキル** - 計画ファイルからマイルストーン変換・起動・監視を自動化
9. **DAGベースタスクスケジューリング** - depends_on による依存グラフでバッチ並列実行（v0.3.0）
10. **Plan Markdown 入力** - `--plan` フラグで Markdown 計画ファイルから直接実行（v0.3.0）
11. **回復性** - Builder の 5xx サーバーエラーリトライ、Verifier のサーキットブレーカー（v0.3.0）

### 改善余地

1. **タイムアウト固定** - FFI の10分タイムアウトが設定不可

### 品質スコア

| 領域 | 評価 |
|------|------|
| コア機能 (Agent, Config, CLI) | A |
| 複雑ロジック (Ralph, Orchestrator) | A |
| Ralph フィードバック | A- |
| SDK統合層 | B |
| TUI/表示 | B |
| テストカバレッジ | B+ |
| ドキュメント | B |
| 全体 | **8.5/10** |
