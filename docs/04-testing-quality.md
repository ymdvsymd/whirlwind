# Testing, Quality & Build System

## エグゼクティブサマリー

- **テストファイル数**: 16 (MoonBit 14 + TypeScript 2)
- **テストケース総数**: 289 (MoonBit 273 + Node.js 16)
- **品質スコア**: 8.5/10
- **最終更新**: 2026-03-22 (v0.9.1)

---

## 1. テストファイル一覧

### MoonBit テスト (14ファイル, ~3,350行)

| ファイル | 行数 | ケース数 | テスト対象 |
|---------|------|---------|----------|
| src/agent/agent_test.mbt | 516 | 30 | MockBackend, イベント解析, OutputLineBuffer |
| src/cli/cli_test.mbt | 402 | 19 | CLI引数パース, フラグ解析 |
| src/review/review_test.mbt | 345 | 26 | 3観点レビュー, 評決パース, 多言語, バックエンド障害伝播 |
| src/orchestrator/orchestrator_test.mbt | 365 | 10 | フェーズ遷移, イテレーション, reworkデータ保持 |
| src/ralph/ralph_loop_test.mbt | ~550 | 12 | 自律ループ, フィードバックルーティング(5テスト追加), reworkプロンプト検証 |
| src/ralph/milestone_test.mbt | 205 | 13 | マイルストーン管理, JSON永続化 |
| src/config/config_test.mbt | 279 | 22 | 設定パース, バリデーション |
| src/display/display_test.mbt | 167 | 22 | ツール表示, テキスト整形 |
| src/types/types_test.mbt | 155 | 14 | 型定義, enum to_string |
| src/tui/tui_test.mbt | 143 | 9 | TUI状態, コールバック |
| src/spawn/line_buffer_test.mbt | 103 | 10 | 行バッファ, CRLF |
| src/ralph/verifier_test.mbt | 95 | 7 | 検証結果パース |
| src/task/task_test.mbt | 89 | 8 | タスク管理, テキストパース |
| src/ralph/planner_test.mbt | 64 | 4 | 計画生成, WAVEパース |

### TypeScript テスト (2ファイル, ~140行)

| ファイル | 行数 | ケース数 | テスト対象 |
|---------|------|---------|----------|
| sdk/agent-runner.test.mjs | 70 | 2 | アダプター実行フロー |
| sdk/codex-normalizer.test.mjs | 70 | 8 | Codex->Claude正規化（全 normalizer 関数） |

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
| task | 高 | A | ID生成・状態遷移完全 |
| spawn (line_buffer) | 高 | A | エッジケース豊富 |
| review | 中-高 | A- | 3観点 + マージ + 多言語 |
| orchestrator | 中-高 | A- | フェーズ遷移 + 失敗回復 |
| ralph | 高 | A- | 状態マシン + フィードバックルーティング + rework cycle |
| types | 中 | B | enum show のみ |
| tui | 中 | B | 状態 + コールバック (render詳細不足) |
| sdk | 低-中 | C+ | アダプター基本フローのみ |

### テストされていない領域

1. **FFI境界**: ffi_js.mbt のJavaScript関数
2. **実際のSDK実行**: SubprocessBackend の実動作
3. **ファイルI/O**: review markdown生成、milestone JSON永続化
4. **大規模シナリオ**: 100+ タスク、並列エージェント
5. **TUIレンダリング詳細**: VNode描画の実際の出力（smoke test のみ: `output.length() > 0`）
6. **SDKアダプター**: claude-adapter.mjs, codex-adapter.mjs にテストファイルなし
7. **cmd/app/main.mbt**: アプリケーションエントリーポイントにテストなし

---

## 4. ビルドシステム

### justfile ターゲット

| Target | 依存 | コマンド | 説明 |
|--------|------|---------|------|
| default | check, test | - | 型チェック + テスト |
| setup | - | npm install | 依存インストール |
| check | - | npm run build:sdk && moon check --target js | 型チェック |
| test | - | npm run build:sdk && node --test && moon test | テスト実行 |
| build | - | npm run build:sdk && moon build --target js | アプリビルド |
| pack | build | bin/whirlwind.js 生成 | shebang付き実行可能ファイル |
| publish | pack | npm publish --access public | npm公開 |
| run | build | node app.js | ローカル実行 |
| clean | - | moon clean | キャッシュクリア |
| fmt | - | moon fmt | コードフォーマット |

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

- `moon.mod.json`: 0.5.0 (MoonBit パッケージ)
- `package.json`: 0.9.1 (npm パッケージ: @ymdvsymd/whirlwind)
- 注: MoonBit パッケージと npm パッケージのバージョンが異なる

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

1. **Verifier サイレント承認バグ修正**: バックエンド障害時に `Approved` を返す問題（`verifier.mbt:107`）。Review モジュールでは修正済みの同一パターン。1行修正 + 1テスト追加で対応可能。
2. **SDK統合テスト追加**: Claude/Codex adapter の実動作テスト

### 優先度: 中

3. **TUIレンダリングテスト**: render_app の出力検証（現在 `length() > 0` のみ）
4. **CI/CDパイプライン**: GitHub Actions で `just test` を自動実行
5. **dead code 整理**: `MockBackend::failing()` が未使用（`FailingMockBackend` が代替）

### 優先度: 低

6. **大規模シナリオテスト**: 100+ タスク
7. **パフォーマンステスト**: ストリーミング処理のスループット
8. **リンター導入**: ESLint/Prettier for SDK TypeScript
