---
name: moonbit-testing
description: >
  MoonBitテストパターン — ユニットテスト、スナップショットテスト、ベンチマーク、カバレッジ。TDD方法論に準拠。
  MoonBitのテスト作成・TDDワークフロー・カバレッジ計測時に使う。
  "moonbit-testing", "MoonBitテスト", "MoonBit TDD", "moonbit test", "moonbit coverage", "スナップショットテスト".
origin: ECC
---

# MoonBit テストパターン

信頼性が高く保守しやすいテストを TDD 方法論に沿って書くための包括的なパターン集。

## いつ使うか

- MoonBit の新規関数、メソッド、トレイトを書くとき
- 既存コードにテストカバレッジを追加するとき
- パフォーマンスクリティカルなコードのベンチマークを作成するとき
- TDD ワークフローで MoonBit プロジェクトを開発するとき

## 仕組み

1. **対象コードを特定** — テストする関数、トレイト、モジュールを決める
2. **テストを書く** — `test "name" { ... }` ブロックで `assert_eq` / `inspect` を使う
3. **テスト実行（RED）** — テストが期待通りに失敗することを確認
4. **実装（GREEN）** — テストを通す最小限のコードを書く
5. **リファクタリング** — テストを緑に保ちながらコードを改善
6. **カバレッジ確認** — `moon test --enable-coverage` で 80%+ を目指す

## TDD ワークフロー

### RED-GREEN-REFACTOR サイクル

```
RED     → 失敗するテストを先に書く
GREEN   → テストを通す最小限の実装を書く
REFACTOR → テストを緑に保ちながらコードを改善
REPEAT  → 次の要件に進む
```

### MoonBit での TDD ステップ

```moonbit
// RED: テストを先に書く。実装は abort で仮置き
pub fn add(a : Int, b : Int) -> Int {
  abort("todo")
}

test "add returns sum" {
  assert_eq(add(2, 3), 5)
}
// moon test → abort で失敗
```

```moonbit
// GREEN: 最小限の実装に置き換え
pub fn add(a : Int, b : Int) -> Int {
  a + b
}
// moon test → 成功。次に REFACTOR → REPEAT
```

## ユニットテスト

### テストブロック

テスト本体の型は `Unit!Error` — raising 関数を `try` なしで直接呼べる:

```moonbit
test "User::new creates user with valid email" {
  let user = try! User::new("Alice", "alice@example.com")
  assert_eq(user.name, "Alice")
  assert_eq(user.email, "alice@example.com")
}

test "User::new rejects invalid email" {
  let result = try? User::new("Bob", "not-an-email")
  assert_true(result.is_err())
}
```

### アサーション関数

4つの組込みアサーション + スナップショット:

```moonbit
// 等値チェック
assert_eq(2 + 2, 4)
assert_not_eq(2 + 2, 5)

// 真偽チェック
assert_true([1, 2, 3].contains(2))
assert_false(list.is_empty())

// カスタムメッセージ付き
assert_eq(actual, expected, msg="expected \{expected} but got \{actual}")

// スナップショットテスト（値の文字列表現を比較）
inspect([1, 2, 3], content="[1, 2, 3]")
```

## スナップショットテスト

### `inspect` と `moon test --update`

`inspect()` は `Show` トレイトを実装した値の文字列表現を期待値と比較する:

```moonbit
test "snapshot" {
  inspect([1, 2, 3], content="[1, 2, 3]")
}

// content を省略して書き、moon test -u で自動挿入
test "auto-fill" {
  inspect(compute_result())
  // moon test -u 実行後:
  // inspect(compute_result(), content="expected output here")
}
```

複数行の値は `#|` プレフィックスで更新される:

```moonbit
test "multiline snapshot" {
  inspect(matrix(3), content=
    #|XXX
    #|XXX
    #|XXX
  )
}
```

## エラーとパニックのテスト

### Result テスト

```moonbit
test "parse returns error for invalid input" {
  let result = try? parse_config("}{invalid")
  assert_true(result.is_err())
}

test "parse succeeds for valid input" {
  let config = try! parse_config("{\"port\": 8080}")
  assert_eq(config.port, 8080)
}
```

### パニックテスト

テスト名が `"panic"` で始まると、パニック発生時にテスト**成功**:

```moonbit
test "panic on empty input" {
  process([])  // パニックが発生 → テスト成功
}

test "panic division by zero" {
  let _ = 1 / 0
}
```

## テスト構成

### ブラックボックス vs ホワイトボックス

```text
my_package/
├── types.mbt              # 実装コード
├── types_test.mbt         # ブラックボックス（公開APIのみ）
├── types_wbtest.mbt       # ホワイトボックス（全メンバー）
└── moon.pkg.json
```

- `*_test.mbt` — 公開 API のみアクセス。`moon.pkg.json` の `test-import` でインポート
- `*_wbtest.mbt` — 全メンバーにアクセス。`wbtest-import` でインポート
- インライン `test { }` — 任意の `.mbt` ファイル内。ホワイトボックス

**推奨**: 通常はブラックボックステスト (`*_test.mbt`) を使う。内部状態の検証が必要な場合のみホワイトボックス (`*_wbtest.mbt`) を使う。

### テストヘルパー

パラメータ化テスト用のヘルパー関数を作成する:

```moonbit
// テストヘルパー — デフォルト値で簡潔に生成
fn make_task(id : String) -> @types.Task {
  @types.Task::new(id, "test task for \{id}")
}

test "task creation" {
  let t = make_task("t1")
  inspect(t.status, content="Pending")
}

test "multiple tasks" {
  let tasks = ["t1", "t2", "t3"].map(make_task)
  assert_eq(tasks.length(), 3)
  for task in tasks {
    assert_eq(task.status, @types.TaskStatus::Pending)
  }
}
```

### 表形式テスト

ヘルパー関数とループでパラメータ化テストを実現:

```moonbit
test "string length cases" {
  let cases : Array[(String, Int)] = [
    ("hello", 5),
    ("", 0),
    ("moonbit", 7),
  ]
  for input, expected in cases {
    assert_eq(
      input.length(),
      expected,
      msg="expected length \{expected} for \"\{input}\"",
    )
  }
}
```

## ベンチマーク

### `moon bench` + `@bench.T`

```moonbit
test "fib benchmark" (b : @bench.T) {
  b.bench(fn() { b.keep(fib(20)) })
}

// 名前付きベンチマーク（比較用）
test "sort benchmark" (b : @bench.T) {
  b.bench(fn() {
    let arr = [5, 3, 1, 4, 2]
    b.keep(arr.sort())
  }, name="sort_5_elements")
}
```

- `b.bench(fn() { ... })` — 自動反復回数で関数を実行
- `b.keep(value)` — コンパイラによる最適化除去を防止（純粋計算に必須）

出力形式: `time (mean +/- sigma) range (min ... max) in N x M runs`

## カバレッジ

### カバレッジ計測

```bash
# カバレッジ有効化してテスト実行
moon test --enable-coverage

# レポート生成
moon coverage report -f summary     # テキストサマリ
moon coverage report -f html        # HTML レポート（_coverage/）
moon coverage report -f cobertura   # CI 連携用 XML
moon coverage report -f coveralls   # CodeCov/Coveralls 用 JSON

# クリーンアップ
moon coverage clean
```

### カバレッジスキップ

```moonbit
/// @coverage.skip
fn debug_only_function() -> Unit {
  // カバレッジ計測から除外
}
```

### カバレッジ目標

| コード種別 | 目標 |
|-----------|------|
| クリティカルなビジネスロジック | 100% |
| 公開 API | 90%+ |
| 一般コード | 80%+ |
| 生成コード / FFI | 除外 |

## テストコマンド

```bash
moon test                         # 全テスト実行
moon test -p package_name         # パッケージ指定
moon test -p pkg -f file_name     # ファイル指定（-p 必須）
moon test -F "pattern*"           # テスト名 glob フィルタ
moon test -i 0-2                  # インデックス範囲指定
moon test -u                      # スナップショット自動更新
moon test --doc                   # ドキュメントテスト
moon test --no-parallelize        # 逐次実行
moon test --enable-coverage       # カバレッジ有効化
moon bench                        # ベンチマーク実行
```

## ベストプラクティス

**やるべきこと:**
- テストを先に書く（TDD）
- 実装ではなく振る舞いをテストする
- シナリオを説明する記述的なテスト名を付ける
- `assert_eq` を優先（`assert_true` よりエラーメッセージが分かりやすい）
- テストを独立させる — 共有ミュータブル状態を持たない
- `inspect()` + `moon test -u` でスナップショットテストを活用
- ブラックボックステスト (`*_test.mbt`) をデフォルトにする

**やってはいけないこと:**
- `panic()` テストできる場合に `Result` のエラーパスをスキップしない
- 全てをモックしない — 統合テストが適切な場合はそちらを優先
- フレーキーなテストを無視しない — 修正するか隔離する
- テスト内で `sleep()` を使わない
- エラーパスのテストを省略しない

## CI 統合（whirlwind 向け）

whirlwind では `just` コマンド経由でテストを実行する:

```bash
just test        # ユニットテスト（SDK + MoonBit）
just check       # 型チェック（moon check + tsc）
just mock        # E2E モックテスト
just live        # E2E 実環境テスト
just coverage    # カバレッジ分析
just fmt         # コード整形
```

**覚えておくこと**: テストはドキュメントである。コードの使い方を示す。明確に書き、最新の状態を保つこと。

## 関連スキル

- **moonbit-patterns** — コーディングパターンの参照。moonbit-testing と併用して実装とテストの両面をカバーする
- **moonbit-audit** — moonbit-testing のテスト規約に照合してテスト品質をチェックし、違反をチケット起票する
