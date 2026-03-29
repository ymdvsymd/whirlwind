---
paths:
  - "**/*.mbt"
  - "**/moon.pkg.json"
  - "**/moon.pkg"
---
# MoonBit コーディングスタイル

> このファイルは [common/coding-style.md](../common/coding-style.md) を MoonBit 向けに拡張する。

## フォーマットとリント

- **`moon fmt`** でコード整形 — コミット前に必ず実行（`--check` で検証のみ）
- **`moon check`** で型検査+lint — 統合チェッカー（Rust の `cargo clippy` + `cargo check` に相当）
- `moon check -d` で警告をエラーとして扱う
- 2スペースインデント（moon fmt デフォルト）

## 不変性

MoonBit の変数はデフォルト不変 — これを活用する:

- `let` をデフォルトで使う。`let mut` は変更が必須の場合のみ
- 構造体フィールドも同様 — `mut` は本当に必要な場合のみ
- 新しい値を返すことを優先し、既存値の書き換えを避ける

```moonbit
// 良い — 不変デフォルト、新しい値を返す
fn normalize(input : String) -> String {
  if input.contains(" ") {
    input.replace(" ", "_")
  } else {
    input
  }
}

// 悪い — 不必要な可変変数
fn normalize_bad(input : String) -> String {
  let mut result = input
  result = result.replace(" ", "_")
  result
}
```

## 命名規則

MoonBit の標準規約に従う:
- `snake_case`: 関数、メソッド、変数、パッケージ名
- `PascalCase`: 型、トレイト、enum、enum バリアント
- `SCREAMING_SNAKE_CASE`: 定数（`const`）

```moonbit
const MAX_RETRIES = 3

pub(all) struct UserProfile {
  user_name : String
  email : String
}

fn validate_email(input : String) -> Bool {
  input.contains("@")
}
```

## 定数宣言

- `const NAME = literal` — トップレベルのみ、リテラル値のみ
- `[1, 2]` や `1 + 1` 等の式は不可。計算値は `let` を使う

## エラー処理

- `suberror` でカスタムエラー型を定義する（**`type!` は非推奨**）
- `raise` でエラーを発生、`try { } catch { }` でキャッチ
- `try!` で再raise（Rust の `?` に最も近い）
- `try?` で `Result[T, Error]` に変換
- raising 関数内で別の raising 関数を呼ぶと自動的に再raise
- 本番コードで `panic()` を直接使わない

```moonbit
// カスタムエラー型（suberror で定義）
suberror ConfigError {
  IoError(String)
  ParseError(String)
}

// エラーを raise する関数
fn load_config(path : String) -> Config raise ConfigError {
  let content = try! read_file(path)  // try! で再raise（Rust の ? 相当）
  parse_config(content)
}

// try/catch でエラーをハンドリング
fn main {
  try {
    let config = load_config("app.toml")
    run(config)
  } catch {
    ConfigError::IoError(msg) => println("IO error: \{msg}")
    ConfigError::ParseError(msg) => println("Parse error: \{msg}")
  }
}

// try? で Result に変換
fn safe_load(path : String) -> Result[Config, Error] {
  try? load_config(path)
}
```

## イテレータ

イテレータチェーンを優先し、命令的ループは複雑な制御フローに使う:

```moonbit
// 良い — 宣言的で合成可能
let active_emails : Array[String] = users.iter()
  .filter(fn(u) { u.is_active })
  .map(fn(u) { u.email })
  .collect()

// 良い — for..in ループ（インデックス付き）
for i, user in users {
  println("\{i}: \{user.name}")
}
```

## モジュール構成

ドメインごとにパッケージを整理する:

```text
src/
├── cmd/app/         # エントリポイント
│   ├── app.mbt
│   └── moon.pkg.json
├── types/           # 型定義
│   ├── types.mbt
│   └── moon.pkg.json
├── config/          # 設定
│   ├── config.mbt
│   └── moon.pkg.json
└── agent/           # ドメインロジック
    ├── agent.mbt
    ├── agent_test.mbt
    └── moon.pkg.json
```

パッケージ間の参照は `@pkg_name.function()` または `@pkg_name.Type::method()` で行う。

## 可視性

MoonBit は型に対して4段階の可視性を持つ:

| 修飾子 | 意味 |
|--------|------|
| `priv` | パッケージ外から完全に不可視 |
| (修飾子なし) | 抽象 — 型名のみ可視、内部構造は隠蔽 |
| `pub` | 読み取り専用 — フィールド参照可だが構築・変更不可 |
| `pub(all)` | 完全公開 — 構築・参照・変更すべて可 |

- デフォルトは private。**公開APIのみ `pub` または `pub(all)` にする**
- 外部パッケージから構築させたい構造体は `pub(all)`
- トレイトの外部実装を許可する場合は `pub(open) trait`

```moonbit
// 良い — 必要最小限の公開
pub(all) struct Task {
  id : String
  description : String
  mut status : TaskStatus
}

// 良い — 外部実装を許可するトレイト
pub(open) trait Formatter {
  format(Self, String) -> String
}

// 良い — 外部実装を禁止するトレイト（sealed）
pub trait Validator {
  validate(Self) -> Bool
}
```

## メソッド定義

メソッドは `fn Type::method(self : Type)` の形式で定義する:

```moonbit
// 正しい — Type:: プレフィックスが正式
fn Task::is_pending(self : Task) -> Bool {
  match self.status {
    Pending => true
    _ => false
  }
}

// fn is_pending(self : Task) -> Bool も動作するが非推奨
```

## ドキュメントコメント

`///|` 形式を使う:

```moonbit
///|
/// タスクを新規作成する
pub fn Task::new(id : String, description : String) -> Task {
  { id, description, status: Pending, result: None }
}
```

## 参照

詳細は skill: `moonbit-patterns` を参照。
