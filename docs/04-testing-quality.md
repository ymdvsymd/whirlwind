# Testing, Quality & Build System

## エグゼクティブサマリー

- **テストファイル数**: 34 (MoonBit 28 + TypeScript 6)
- **テストケース総数**: 554 (MoonBit 516 + Node.js 38)
- **品質スコア**: 8.5/10
- **最終更新**: 2026-03-29 (v0.3.1)

---

## 1. テストファイル一覧

### MoonBit テスト (28ファイル, ~10,063行)

| ファイル | 行数 | ケース数 | テスト対象 |
|---------|------|---------|----------|
| src/ralph/ralph_loop_dag_e2e_test.mbt | 795 | 12 | DAG E2Eテスト |
| src/ralph/milestone_test.mbt | 798 | 34 | マイルストーン管理, JSON永続化 |
| src/agent/agent_test.mbt | 788 | 55 | MockBackend, イベント解析, OutputLineBuffer |
| src/ralph/ralph_loop_helpers_test.mbt | 773 | 28 | ヘルパー関数, イベント処理, ファイル競合検出 |
| src/ralph/ralph_loop_regression_test.mbt | 768 | 13 | リグレッションテスト |
| src/ralph/ralph_loop_verify_test.mbt | 737 | 15 | 検証, フィードバックルーティング, perspectives |
| src/ralph/ralph_loop_dag_test.mbt | 704 | 7 | DAGスケジューリング, スコープエッジ |
| src/cli/cli_test.mbt | 593 | 44 | CLI引数パース, フラグ解析 |
| src/ralph/ralph_loop_test.mbt | 583 | 15 | 自律ループ状態マシン |
| src/config/config_test.mbt | 407 | 28 | 設定パース, バリデーション |
| src/cmd/helpers/helpers_test.mbt | 338 | 36 | ヘルパー関数 |
| src/review/review_test.mbt | 318 | 25 | 3観点レビュー, 評決パース, 多言語, バックエンド障害伝播 |
| src/ralph/verifier_test.mbt | 299 | 20 | 検証結果パース |
| src/ralph/dag_test.mbt | 253 | 16 | DAGグラフ, トポロジカルソート |
| src/agent/parallel_test.mbt | 211 | 13 | 並列実行バックエンド |
| src/types/types_test.mbt | 206 | 19 | 型定義, enum to_string |
| src/util/util_test.mbt | 198 | 27 | 汎用ユーティリティ |
| src/display/display_test.mbt | 196 | 30 | ツール表示, テキスト整形 |
| src/ralph/ralph_loop_wbtest.mbt | 165 | 5 | ホワイトボックステスト |
| src/plan/converter_test.mbt | 160 | 7 | Plan→Milestone変換 |
| src/cmd/app/main_test.mbt | 141 | 3 | エントリーポイント |
| src/ralph/planner_test.mbt | 136 | 6 | 計画生成, WAVEパース |
| src/prompts/prompts_test.mbt | 108 | 15 | プロンプトテンプレート |
| src/plan/parser_test.mbt | 101 | 8 | Markdownパース |
| src/plan/llm_classifier_test.mbt | 87 | 9 | LLM分類 |
| src/agent/subprocess_test.mbt | 74 | 9 | サブプロセスバックエンド |
| src/plan/naming_test.mbt | 73 | 9 | タスクID・マイルストーンID生成 |
| src/plan/classifier_test.mbt | 53 | 8 | ヒューリスティック分類 |

### TypeScript テスト (6ファイル, ~1,019行)

| ファイル | 行数 | ケース数 | テスト対象 |
|---------|------|---------|----------|
| sdk/claude-adapter.test.mjs | 369 | 28 | Claude Agent SDK アダプター |
| sdk/agent-runner.test.mjs | 171 | 9 | アダプター実行フロー |
| sdk/runner-io.test.mjs | 167 | 10 | 共通I/Oユーティリティ |
| sdk/codex-adapter.test.mjs | 160 | 5 | Codex SDK アダプター |
| sdk/codex-normalizer.test.mjs | 135 | 11 | Codex->Claude正規化（全 normalizer 関数） |
| sdk/shebang.test.mjs | 17 | 2 | shebang 行検証 |

---

## 2. テスト手法

### 2.1 モック戦略

**MockBackend** (`src/agent/mock.mbt`):
- `default_response`: デフォルト固定応答
- `add_response(keyword, response)`: キーワードベースの条件付き応答
- `get_history()`: 呼び出し履歴の追跡
- `boxed()`: BoxedBackend への変換

**FailingMockBackend**:
- 常に StatusChange(Failed(msg)) を発火
- バックエンド障害のテストに使用

### 2.2 テストパターン

**Arrange-Act-Assert (AAA)**:
```moonbit
let mock = MockBackend::new(default_response="...")
let backend = mock.boxed()
let result = backend.run("task", "prompt", fn(_) { })
inspect(result.content, content="expected")
```

**Collector Pattern** (複合イベント検証):
```moonbit
struct EventCollector {
  infos: Array[String]
  tool_calls: Array[(String, String)]
  tool_results: Array[(String, String)]
  sub_starts: Array[(String, String)]
  sub_ends: Array[String]
}
```

**Helper Functions**:
- `make_ralph_config()`: Ralph設定プリセット
- `make_test_config()`: Orchestrator設定プリセット
- `make_backends()`: mock backend map構築

### 2.3 属性ベーステスト

| 属性 | 適用例 |
|------|-------|
| 境界値 | token=0, duration=0, review_interval=0 (invalid) |
| 等価分割 | lang: "ja"/"en"/"auto"/(invalid) |
| エッジケース | empty string, malformed JSON, missing fields |
| 状態遷移 | Task: Pending -> InProgress -> Done |
| 複合条件 | agents present && no planner (invalid) |

---

## 3. モジュール別カバレッジ分析

| モジュール | カバレッジ | 評価 | 備考 |
|-----------|----------|------|------|
| agent (event parse) | 高 | A | JSONL全イベント型カバー |
| cli | 高 | A | 全フラグ・コマンドカバー |
| config | 高 | A | バリデーション全ルールカバー |
| display | 高 | A | 全ツール表示カバー |
| cmd/helpers | 高 | A | ヘルパー関数カバー |
| util | 高 | A | 汎用ユーティリティカバー |
| review | 中-高 | A- | 3観点 + マージ + 多言語 |
| ralph | 高 | A- | 状態マシン + フィードバックルーティング + rework cycle |
| types | 中-高 | B+ | enum show + 各種型テスト |
| prompts | 中 | B | プロンプトテンプレート |
| sdk | 中-高 | B+ | claude/codex アダプター + normalizer + runner-io |

### テストされていない領域

1. **FFI境界**: ffi_js.mbt のJavaScript関数
2. **実際のSDK実行**: SubprocessBackend の実動作
3. **ファイルI/O**: review markdown生成、milestone JSON永続化
4. **大規模シナリオ**: 100+ タスク、並列エージェント
5. **cmd/app/main.mbt**: アプリケーションエントリーポイントにテストなし

---

## 4. ビルドシステム

### justfile ターゲット

| Target | 依存 | コマンド | 説明 |
|--------|------|---------|------|
| default | check, test | - | 型チェック + テスト |
| setup | - | npm install | 依存インストール |
| check | - | npm run build:sdk && moon check --target js | 型チェック |
| test | - | npm run build:sdk && node --test && moon test | テスト実行 |
| mock | pack | bash tests/e2e-ralph.sh mock | E2Eテスト (モックサーバー) |
| mock-flags | pack | bash tests/e2e-ralph.sh mock-flags | E2Eテスト (モック + フラグ) |
| live | pack | bash tests/e2e-ralph.sh live | E2Eテスト (実サーバー) |
| live-flags | pack | bash tests/e2e-ralph.sh live-flags | E2Eテスト (実サーバー + フラグ) |
| build | - | npm run build:sdk && moon build --target js | アプリビルド |
| pack | build | bin/whirlwind.js 生成 | shebang付き実行可能ファイル |
| publish | pack | npm publish --access public | npm公開 |
| run | build | node app.js | ローカル実行 |
| clean | - | moon clean | キャッシュクリア |
| coverage | - | npm run build:sdk && node --test --experimental-test-coverage | SDKテストカバレッジ |
| fmt | - | moon fmt | コードフォーマット |
| info | - | moon info | MoonBit プロジェクト情報 |

### ビルドパイプライン

```
1. npm run build:sdk
   TypeScript (.mts) -> JavaScript (.mjs)
   tsconfig.sdk.json: ES2022, strict, NodeNext

2. moon check --target js
   MoonBit 型チェック (JS ターゲット)

3. moon build --target js src/cmd/app
   MoonBit -> JavaScript コンパイル
   出力: _build/js/debug/build/cmd/app/app.js

4. pack
   shebang (#!/usr/bin/env node) + app.js -> bin/whirlwind.js

5. npm publish
   files: [bin/, sdk/] を npm に公開
```

### バージョン情報

- `moon.mod.json`: 0.3.1 (MoonBit パッケージ)
- `package.json`: 0.3.1 (npm パッケージ: @ymdvsymd/whirlwind)

---

## 5. テスト実行方法

```bash
# 全テスト実行
just test

# 個別実行
moon test --target js           # MoonBit テストのみ
node --test sdk/*.test.mjs      # TypeScript テストのみ

# 型チェックのみ
just check

# フォーマット
just fmt
```

---

## 6. .gitignore

```
_build/           # MoonBit build artifacts
bin/              # Compiled executables
.mooncakes/       # MoonBit package cache
.whirlwind/       # Runtime state/cache
target/           # Build output
node_modules/     # NPM dependencies
```

---

## 7. 品質改善の推奨事項

### 優先度: 高

1. **CI/CDパイプライン**: GitHub Actions で `just test` を自動実行

### 優先度: 中

2. **大規模シナリオテスト**: 100+ タスク
3. **パフォーマンステスト**: ストリーミング処理のスループット
