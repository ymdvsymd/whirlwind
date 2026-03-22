# Testing, Quality & Build System

## エグゼクティブサマリー

- **テストファイル数**: 19 (MoonBit 13 + TypeScript 6)
- **テストケース総数**: 362 (MoonBit 328 + Node.js 34)
- **品質スコア**: 8.5/10
- **最終更新**: 2026-03-22 (v0.1.0)

---

## 1. テストファイル一覧

### MoonBit テスト (13ファイル, ~5,438行)

| ファイル | 行数 | ケース数 | テスト対象 |
|---------|------|---------|----------|
| src/ralph/ralph_loop_test.mbt | 1,878 | 40 | 自律ループ, フィードバックルーティング, reworkプロンプト検証 |
| src/agent/agent_test.mbt | 742 | 53 | MockBackend, イベント解析, OutputLineBuffer |
| src/ralph/milestone_test.mbt | 502 | 23 | マイルストーン管理, JSON永続化 |
| src/cmd/helpers/helpers_test.mbt | 338 | 36 | ヘルパー関数 |
| src/types/types_test.mbt | 327 | 23 | 型定義, enum to_string |
| src/review/review_test.mbt | 318 | 25 | 3観点レビュー, 評決パース, 多言語, バックエンド障害伝播 |
| src/ralph/verifier_test.mbt | 292 | 20 | 検証結果パース |
| src/config/config_test.mbt | 289 | 21 | 設定パース, バリデーション |
| src/cli/cli_test.mbt | 238 | 18 | CLI引数パース, フラグ解析 |
| src/util/util_test.mbt | 198 | 27 | 汎用ユーティリティ |
| src/display/display_test.mbt | 196 | 30 | ツール表示, テキスト整形 |
| src/ralph/planner_test.mbt | 66 | 4 | 計画生成, WAVEパース |
| src/prompts/prompts_test.mbt | 54 | 8 | プロンプトテンプレート |

### TypeScript テスト (6ファイル, ~916行)

| ファイル | 行数 | ケース数 | テスト対象 |
|---------|------|---------|----------|
| sdk/claude-adapter.test.mjs | 369 | 5 | Claude Agent SDK アダプター |
| sdk/agent-runner.test.mjs | 171 | 6 | アダプター実行フロー |
| sdk/codex-adapter.test.mjs | 160 | 5 | Codex SDK アダプター |
| sdk/codex-normalizer.test.mjs | 135 | 11 | Codex->Claude正規化（全 normalizer 関数） |
| sdk/runner-io.test.mjs | 64 | 6 | 共通I/Oユーティリティ |
| sdk/shebang.test.mjs | 17 | 1 | shebang 行検証 |

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
| 複合条件 | ralph_enabled && no planner (invalid) |

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

- `moon.mod.json`: 0.1.0 (MoonBit パッケージ)
- `package.json`: 0.1.0 (npm パッケージ: @ymdvsymd/whirlwind)

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
