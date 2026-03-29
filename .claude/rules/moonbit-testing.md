---
paths:
  - "**/*.mbt"
  - "**/*_test.mbt"
  - "**/*_wbtest.mbt"
---
# MoonBit テスト

> このファイルは [common/testing.md](../common/testing.md) を MoonBit 向けに拡張する。

## テストフレームワーク

MoonBit はテストが**言語に組込み**:
- `test "name" { ... }` ブロック — テスト本体は `Unit!Error` 型（raising 関数を直接呼べる）
- `assert_eq(a, b)` / `assert_not_eq(a, b)` — 等値チェック（`msg=` で独自メッセージ可）
- `assert_true(cond)` / `assert_false(cond)` — 真偽チェック
- `inspect(obj, content="expected")` — スナップショットテスト

## テスト構成

```text
my_package/
├── types.mbt              # 実装コード（インラインテスト可）
├── types_test.mbt         # ブラックボックステスト（公開APIのみ）
├── types_wbtest.mbt       # ホワイトボックステスト（全メンバー）
└── moon.pkg.json          # test-import / wbtest-import を宣言
```

| ファイル | 種別 | アクセス範囲 | インポート設定 |
|---------|------|-------------|---------------|
| `*_test.mbt` | ブラックボックス | 公開APIのみ | `test-import` |
| `*_wbtest.mbt` | ホワイトボックス | 全メンバー | `wbtest-import` |
| `*.mbt` 内 `test { }` | インライン（WB） | 全メンバー | `import` |

## ユニットテストパターン

```moonbit
test "Task::new creates pending task" {
  let t = @types.Task::new("t1", "do something")
  inspect(t.status, content="Pending")
  inspect(t.result, content="None")
}

test "rejects invalid email" {
  let result = try? Email::parse("not-an-email")
  assert_true(result.is_err())
}

test "word count" {
  assert_eq(word_count("hello world"), 2)
  assert_not_eq(word_count("hello world"), 0)
}
```

## スナップショットテスト

`inspect()` は値の文字列表現を期待値と比較する。`content` を省略して `moon test --update` (`-u`) で自動挿入:

```moonbit
test "snapshot example" {
  let arr = [1, 2, 3]
  inspect(arr, content="[1, 2, 3]")
}

// 初回は content を省略して書ける
test "auto-fill snapshot" {
  inspect(compute_result())
  // `moon test -u` 実行後、content が自動挿入される
}
```

## パニックテスト

テスト名が `"panic"` で始まるテストは、パニックが発生すると**成功**:

```moonbit
test "panic division by zero" {
  let _ = 1 / 0  // パニックが発生 → テスト成功
}
```

## カスタムメッセージ付きアサーション

全アサーション関数は `msg=` 引数を受け取る:

```moonbit
test "with custom message" {
  assert_eq(actual, expected, msg="expected \{expected} but got \{actual}")
  assert_true(list.length() > 0, msg="list should not be empty")
}
```

## テスト命名規則

シナリオを説明する記述的な名前を使う:
- `"Task::new creates pending task"`
- `"rejects order when insufficient stock"`
- `"returns None when not found"`

## カバレッジ

- `moon test --enable-coverage` でカバレッジ計測を有効化
- `moon coverage report -f summary|html|cobertura|coveralls` でレポート生成
- `/// @coverage.skip` プラグマで特定関数をスキップ

```bash
moon test --enable-coverage
moon coverage report -f summary    # テキストサマリ
moon coverage report -f html       # HTML レポート（_coverage/）
moon coverage clean                # カバレッジ成果物をクリーン
```

### カバレッジ目標

| コード種別 | 目標 |
|-----------|------|
| クリティカルなビジネスロジック | 100% |
| 公開API | 90%+ |
| 一般コード | 80%+ |
| 生成コード / FFI バインディング | 除外 |

## ベンチマーク

`moon bench` + `@bench.T` パラメータで組込みベンチマーク:

```moonbit
test "fib benchmark" (b : @bench.T) {
  b.bench(fn() { b.keep(fib(20)) })
}
```

- `b.bench(fn() { ... })` — 自動反復回数で関数を実行
- `b.keep(value)` — コンパイラによる最適化除去を防止

## テストコマンド

```bash
moon test                        # 全テスト実行
moon test -p pkg_name            # パッケージ指定
moon test -p pkg_name -f file    # ファイル指定（-p 必須）
moon test -F "pattern*"          # テスト名 glob フィルタ
moon test -i 0-2                 # インデックス範囲
moon test -u                     # スナップショット自動更新
moon test --doc                  # ドキュメントテスト
moon test --no-parallelize       # 逐次実行
```

## 参照

詳細は skill: `moonbit-testing` を参照（TDD ワークフロー、テストヘルパー、ベンチマーク詳細）。
