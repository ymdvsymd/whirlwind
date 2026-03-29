---
name: moonbit-patterns
description: >
  MoonBitのイディオマティックパターン、エラー処理、トレイト、非同期、開発ベストプラクティス。安全で保守性の高いアプリケーション構築のための参照文献。
  MoonBitコードの新規作成・レビュー・リファクタリング時に使う。
  "moonbit-patterns", "MoonBitパターン", "MoonBit書き方", "moonbit idiom", "moonbit best practice", "MoonBit開発".
origin: ECC
---

# MoonBit 開発パターン

MoonBit のイディオマティックなパターンとベストプラクティス。安全で高パフォーマンスかつ保守性の高いアプリケーション構築のための参照文献。

## いつ使うか

- MoonBit の新規コードを書くとき
- MoonBit コードをレビューするとき
- 既存の MoonBit コードをリファクタリングするとき
- パッケージ構造やモジュール設計を検討するとき

## 仕組み

このスキルは MoonBit の主要領域にわたるイディオマティックな規約を強制する: GC ベースのメモリ管理を前提とした効率的なデータモデリング、`suberror`/`raise`/`try!` によるエラー伝播、enum と網羅的パターンマッチで不正な状態を表現不可能にする設計、トレイトとジェネリクスによるゼロコスト抽象化、`async` による単一スレッド構造化並行性、パッケージスコープの可視性制御。

## 基本原則

### 1. 不変デフォルト

MoonBit の変数はデフォルト不変。これを活用する。

```moonbit
// 良い — 不変。変更が必要なら新しい値を返す
fn increment(counter : Int) -> Int {
  counter + 1
}

// 良い — 構造体更新で新しい値を生成（ドット2つ）
fn with_status(task : Task, status : TaskStatus) -> Task {
  { ..task, status }
}

// 悪い — 不必要な可変変数
fn increment_bad() -> Int {
  let mut x = 0
  x = x + 1
  x
}
```

## エラー処理

### `suberror` でカスタムエラー型を定義する

```moonbit
// suberror で構造化エラー型を定義（type! は非推奨）
suberror StorageError {
  NotFound(String)
  ConnectionFailed(String)
  InvalidData(String)
}
```

### `raise` と `try!` によるエラー伝播

```moonbit
// raise でエラーを発生
fn find_by_id(self : Store, id : String) -> Record raise StorageError {
  guard self.data.get(id) is Some(record) else {
    raise StorageError::NotFound(id)
  }
  record
}

// try! で再raise（Rust の ? に最も近い）
fn get_and_process(store : Store, id : String) -> String raise StorageError {
  let record = try! store.find_by_id(id)
  record.to_string()
}

// try? で Result に変換
fn safe_find(store : Store, id : String) -> Result[Record, Error] {
  try? store.find_by_id(id)
}
```

### `try/catch` と `catch!`

```moonbit
// try/catch で個別にハンドリング
fn handle_request(store : Store, id : String) -> Response {
  try {
    let record = store.find_by_id(id)
    Response::ok(record.to_string())
  } catch {
    StorageError::NotFound(id) => Response::not_found("Record \{id} not found")
    _ => Response::internal_error("Internal server error")
  }
}

// catch! — 未マッチのエラーは自動再raise
fn process(store : Store, id : String) -> String raise Failure {
  try {
    store.find_by_id(id).to_string()
  } catch! {
    StorageError::NotFound(id) => "default_\{id}"
    // StorageError::ConnectionFailed 等は自動的に再raise
  }
}
```

### `Option` コンビネータ

```moonbit
// 良い — コンビネータチェーン
fn find_user_email(users : Array[User], id : Int) -> String? {
  users.iter()
    .find(fn(u) { u.id == id })
    .map(fn(u) { u.email })
}

// 悪い — 深いネストのマッチ
fn find_user_email_bad(users : Array[User], id : Int) -> String? {
  match users.iter().find(fn(u) { u.id == id }) {
    Some(user) => Some(user.email)
    None => None
  }
}
```

## Enum とパターンマッチ

### 状態を Enum でモデリング

```moonbit
// 良い — 不正な状態は表現不可能
pub(all) enum TaskStatus {
  Pending
  InProgress(agent_id~ : String)
  Done
  Failed(reason~ : String)
} derive(Show, Eq)

fn handle_task(status : TaskStatus) -> Unit {
  match status {
    Pending => assign_agent()
    InProgress(agent_id=aid) => monitor(aid)
    Done => archive()
    Failed(reason=r) => retry_or_escalate(r)
  }
}
```

### 網羅的マッチ — ビジネスロジックにワイルドカード禁止

```moonbit
// 良い — 全バリアントを明示的にハンドル
match command {
  Start => start_service()
  Stop => stop_service()
  Restart => restart_service()
  // 新バリアント追加時にコンパイルエラーで気付ける
}

// 悪い — ワイルドカードが新バリアントを隠す
match command {
  Start => start_service()
  _ => {}  // Stop, Restart, 将来のバリアントを黙って無視
}
```

## トレイトとジェネリクス

### ジェネリック入力、具体的出力

```moonbit
// 良い — ジェネリック入力、具体的な戻り値型
fn[T : Show] format_item(item : T) -> String {
  item.to_string()
}

// 良い — 複数のトレイト境界
fn[T : Eq + Show] find_index(array : Array[T], target : T) -> Int? {
  for i, elem in array {
    if elem == target {
      return Some(i)
    }
  }
  None
}
```

### トレイトオブジェクトによる動的ディスパッチ

```moonbit
// 異種コレクションやプラグインシステムに使用
pub(open) trait Handler {
  handle(Self, Request) -> Response raise Failure
}

pub(all) struct Router {
  handlers : Array[&Handler]
}
```

### Newtype パターンで型安全性を確保

```moonbit
// 良い — 引数の取り違えを型レベルで防止
pub(all) struct UserId(Int)
pub(all) struct OrderId(Int)

fn get_order(user : UserId, order : OrderId) -> Order raise Failure {
  abort("todo")
}

// 悪い — 引数の入れ替えミスが検出されない
fn get_order_bad(user_id : Int, order_id : Int) -> Order raise Failure {
  abort("todo")
}
```

## 構造体とデータモデリング

### 名前付き/オプション引数でビルダーパターンを代替

```moonbit
pub(all) struct ServerConfig {
  host : String
  port : Int
  max_connections : Int
}

pub fn ServerConfig::new(
  host~ : String,
  port~ : Int,
  max_connections? : Int = 100,
) -> ServerConfig {
  { host, port, max_connections }
}

// 使用: ServerConfig::new(host="localhost", port=8080)
// 使用: ServerConfig::new(host="0.0.0.0", port=443, max_connections=500)
```

### 構造体更新（ドット2つ `..`）

```moonbit
let updated = { ..config, port: 9090 }
```

## イテレータとコレクション

### イテレータチェーンを優先

```moonbit
// 良い — 宣言的、遅延評価、合成可能
let active_names : Array[String] = users.iter()
  .filter(fn(u) { u.is_active })
  .map(fn(u) { u.name })
  .collect()

// for..in ループ（インデックス付き）
for i, item in items {
  println("\{i}: \{item}")
}

// for..in ループ（Map のキー・値）
for k, v in map {
  println("\{k} = \{v}")
}
```

MoonBit の外部イテレータは**単一パス**（一度だけ走査可能）。

## 非同期処理

MoonBit は**単一スレッド・マルチタスク**モデル（Node.js に類似）。`await` キーワードはなく、非同期呼出はコンパイラが自動推論する。

```moonbit
// async 関数の定義
async fn fetch_data(url : String) -> String raise Failure {
  let (response, _) = @http.get(url)
  response.body
}

// 構造化並行性 — タスクグループ
async fn fetch_all(urls : Array[String]) -> Array[String] raise Failure {
  let results = Array::new()
  @async.with_task_group(fn(group) {
    for url in urls {
      group.spawn_bg(fn() {
        let data = fetch_data(url)
        results.push(data)
      })
    }
  })
  results
}
```

**注意**: マルチスレッドは存在しない。ロック・競合状態の心配は不要だが、CPU バウンドな処理の並列化はできない。

## パッケージ構成

### `moon.pkg.json` によるインポート管理

```json
{
  "import": [
    "ymdvsymd/whirlwind/types",
    { "path": "ymdvsymd/whirlwind/util", "alias": "util" }
  ],
  "test-import": [
    "ymdvsymd/whirlwind/types"
  ]
}
```

### 再エクスポート

```moonbit
pub using @types::{Task, TaskStatus, AgentConfig}
```

### 可視性の使い分け

```moonbit
// 外部パッケージから構築させる型 → pub(all)
pub(all) struct Task { ... }

// 名前は見えるが内部構造は隠す → 修飾子なし
struct InternalState { ... }

// 外部パッケージから実装可能なトレイト → pub(open)
pub(open) trait Plugin { ... }

// 外部パッケージから実装不可なトレイト → pub
pub trait CoreService { ... }
```

## derive 一覧

利用可能な derive:

| derive | 用途 |
|--------|------|
| `Show` | 文字列表現（デバッグ出力。**`Debug` は存在しない**） |
| `Eq` | 等値比較 |
| `Compare` | 順序比較（`Eq` を拡張） |
| `Hash` | ハッシュ値（HashMap/HashSet 用） |
| `Default` | デフォルト値の生成 |
| `FromJson` | JSON デシリアライゼーション |
| `ToJson` | JSON シリアライゼーション |
| `Arbitrary` | ランダム値生成 |

```moonbit
pub(all) struct User {
  id : Int
  name : String
  email : String
} derive(Show, Eq, Hash, ToJson, FromJson)
```

## ツール連携コマンド

```bash
# ビルドとチェック
moon build                        # ビルド
moon check                        # 型検査+lint（clippy+check 相当）
moon check -d                     # 警告をエラーとして扱う
moon fmt                          # コード整形
moon fmt --check                  # 整形チェックのみ

# テスト
moon test                         # 全テスト
moon test -p package              # パッケージ指定
moon test -F "pattern*"           # 名前フィルタ
moon test -u                      # スナップショット更新

# 依存管理
moon add username/package         # パッケージ追加
moon tree                         # 依存ツリー表示
moon update                       # パッケージインデックス更新

# ドキュメント
moon doc --serve                  # ドキュメントサーバー起動
```

## クイックリファレンス: MoonBit イディオム

| イディオム | 説明 |
|-----------|------|
| 不変デフォルト | `let` で宣言。`let mut` は本当に必要な場合のみ |
| 不正な状態を表現不可能に | enum で有効な状態のみモデリング |
| `try!` でエラー伝播 | raising 関数の戻り値を再raise（Rust の `?` 相当） |
| parse, don't validate | 非構造化データを境界で型付き構造体に変換 |
| Newtype で型安全性 | プリミティブをラップして引数取り違えを防止 |
| イテレータチェーン優先 | 宣言的チェーンはループより明確で効率的 |
| 網羅的マッチ | ビジネスクリティカルな enum にワイルドカード `_` 禁止 |
| `pub(all)` は最小限 | 外部構築が必要な型のみ。デフォルトは private |
| `fn Type::method` | メソッドには `Type::` プレフィックスを付ける |
| `{ ..record, field: value }` | 構造体更新はドット2つ（`...` ではない） |

## アンチパターン

```moonbit
// 悪い — 本番コードで panic() を直接使用
let value = map.get("key").unwrap()  // Option の unwrap は存在しない
// 代わりに match か guard is Some(...) を使う

// 悪い — Option を未処理のまま放置
let _ = find_user(id)  // 戻り値を捨てている

// 悪い — ワイルドカードでビジネスロジックの enum をキャッチ
match status {
  Done => archive()
  _ => {}  // 他のバリアントを黙って無視
}

// 悪い — Type:: プレフィックスなしのメソッド定義
fn method(self : MyType) -> Unit { ... }
// → fn MyType::method(self : MyType) -> Unit { ... } を使う

// 悪い — ドット3つの構造体更新
let updated = { ...record, field: value }  // コンパイルエラー
// → { ..record, field: value } を使う（ドット2つ）
```

**覚えておくこと**: MoonBit は GC 管理なので所有権・ライフタイムの心配は不要。その代わり、型システム（Newtype、enum、トレイト）を最大限活用して安全性を確保する。

## 関連スキル

- **moonbit-testing** — テストパターンの参照。moonbit-patterns と併用して実装とテストの両面をカバーする
- **moonbit-audit** — moonbit-patterns の規約に照合してコードベース全体をチェックし、違反をチケット起票する
