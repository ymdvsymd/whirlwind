---
paths:
  - "**/*.mbt"
---
# MoonBit パターン

> このファイルは [common/patterns.md](../common/patterns.md) を MoonBit 向けに拡張する。

## トレイトによるリポジトリパターン

データアクセスをトレイトの背後にカプセル化する:

```moonbit
pub(open) trait OrderRepository {
  find_by_id(Self, Int) -> Order? raise Failure
  find_all(Self) -> Array[Order] raise Failure
  save(Self, Order) -> Order raise Failure
  delete(Self, Int) -> Unit raise Failure
}
```

具象実装がストレージの詳細（データベース、API、テスト用インメモリ等）を担当する。

## サービス層

ビジネスロジックをサービス構造体に集約し、依存をコンストラクタで注入する:

```moonbit
pub(all) struct OrderService {
  repo : &OrderRepository
  payment : &PaymentGateway
}

pub fn OrderService::new(
  repo : &OrderRepository,
  payment : &PaymentGateway,
) -> OrderService {
  { repo, payment }
}

pub fn OrderService::place_order(
  self : OrderService,
  request : CreateOrderRequest,
) -> OrderSummary raise Failure {
  let order = Order::from(request)
  try! self.payment.charge(order.total())
  let saved = try! self.repo.save(order)
  OrderSummary::from(saved)
}
```

トレイトオブジェクト `&Trait` で動的ディスパッチを実現する。

## Newtype パターン（型安全性）

引数の取り違えを防ぐためにラッパー型を使う:

```moonbit
pub(all) struct UserId(Int)
pub(all) struct OrderId(Int)

fn get_order(user : UserId, order : OrderId) -> Order raise Failure {
  // UserId と OrderId を間違えてもコンパイルエラーになる
  abort("todo")
}
```

タプル構造体のフィールドには `.0` でアクセスする。

## Enum ステートマシン

状態を enum でモデリングし、不正な状態を表現不可能にする:

```moonbit
pub(all) enum ConnectionState {
  Disconnected
  Connecting(attempt~ : Int)
  Connected(session_id~ : String)
  Failed(reason~ : String, retries~ : Int)
} derive(Show)

fn handle(state : ConnectionState) -> Unit {
  match state {
    Disconnected => connect()
    Connecting(attempt=attempt) if attempt > 3 => abort_connection()
    Connecting(..) => wait()
    Connected(session_id=sid) => use_session(sid)
    Failed(retries=r, ..) if r < 5 => retry()
    Failed(reason=r, ..) => log_failure(r)
  }
}
```

ビジネスクリティカルな enum にはワイルドカード `_` を使わず、全バリアントを網羅的にマッチする。

## 名前付き/オプション引数によるビルダーパターン代替

MoonBit の名前付き引数 (`label~`) とオプション引数 (`label?`) により、ビルダーパターンは多くの場合不要:

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

// 使用例: 任意の順序で指定可、オプション引数は省略可
let config = ServerConfig::new(port=8080, host="localhost")
let config2 = ServerConfig::new(host="0.0.0.0", port=443, max_connections=500)
```

## 構造体の更新

既存の構造体から一部フィールドを変更した新しい値を作るには `..` (ドット**2つ**) を使う:

```moonbit
let updated = { ..config, port: 9090 }
```

**注意**: JavaScript の `...` (ドット3つ) ではない。

## Sealed Traits

MoonBit のトレイトはデフォルトで sealed（外部実装不可）:

```moonbit
// pub trait = 外部パッケージから実装不可（sealed）
pub trait Format {
  encode(Self, Bytes) -> Bytes
}

// pub(open) trait = 外部パッケージからも実装可
pub(open) trait Plugin {
  name(Self) -> String
  execute(Self, String) -> String raise Failure
}
```

## API レスポンスエンベロープ

`derive(ToJson, FromJson)` で JSON シリアライゼーションを実現:

```moonbit
pub(all) enum ApiResponse {
  Ok(data~ : String)
  Error(message~ : String)
} derive(ToJson, FromJson, Show)
```

## 参照

詳細は skill: `moonbit-patterns` を参照。
