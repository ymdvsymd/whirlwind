---
paths:
  - "**/*.mbt"
---
# MoonBit セキュリティ

> このファイルは [common/security.md](../common/security.md) を MoonBit 向けに拡張する。

## シークレット管理

- API キー、トークン、認証情報をソースコードにハードコードしない
- **MoonBit の標準ライブラリには環境変数アクセス関数がない** — FFI 経由または JS バックエンドでの外部連携が必要
- 設定ファイルまたはホスト提供のインポート関数を通じてシークレットを受け取る
- `.env` ファイルは `.gitignore` に含める

```moonbit
// 悪い — ハードコードされたシークレット
const API_KEY = "sk-abc123..."

// 良い — 外部から注入された設定を使用
pub(all) struct AppConfig {
  api_key : String
  database_url : String
}

// 起動時にバリデーション
fn validate_config(config : AppConfig) -> Unit raise Failure {
  guard config.api_key != "" else {
    raise Failure::Failure("API_KEY must be set")
  }
  guard config.database_url != "" else {
    raise Failure::Failure("DATABASE_URL must be set")
  }
}
```

## 入力バリデーション

- システム境界ですべてのユーザー入力をバリデーションする
- 型システムを活用して不変条件を強制する（Newtype パターン）
- **parse, don't validate** — 非構造化データを境界で型付き構造体に変換する
- 不正な入力は明確なエラーメッセージで拒否する

```moonbit
// parse, don't validate — 不正な状態は表現不可能にする
suberror ValidationError {
  InvalidEmail(String)
  TooLong(String)
}

pub(all) struct Email(String)

pub fn Email::parse(input : String) -> Email raise ValidationError {
  let trimmed = input.trim(" ")
  guard trimmed.contains("@") else {
    raise ValidationError::InvalidEmail(input)
  }
  guard trimmed.length() <= 254 else {
    raise ValidationError::TooLong(input)
  }
  Email(trimmed)
}

pub fn Email::as_string(self : Email) -> String {
  self.0
}
```

## guard による早期リターンバリデーション

`guard` 構文で前提条件を宣言的に検証する:

```moonbit
fn process_request(request : Request) -> Response raise Failure {
  // guard + is でパターンマッチ＆束縛
  guard request.get_header("Authorization") is Some(token) else {
    raise Failure::Failure("Authorization header required")
  }
  guard request.body.length() > 0 else {
    raise Failure::Failure("Request body must not be empty")
  }
  // token と request.body がここで利用可能
  handle_authenticated(token, request.body)
}
```

## エラーメッセージの情報漏洩防止

- 内部パス、スタックトレース、データベースエラーを API レスポンスに露出させない
- 詳細なエラーはサーバーサイドでログに記録し、クライアントには汎用メッセージを返す

```moonbit
fn handle_request(id : Int) -> ApiResponse {
  match try? order_service.find_by_id(id) {
    Ok(order) => ApiResponse::Ok(data=order.to_json().stringify())
    Err(_) => {
      // 詳細エラーはログに出力（クライアントには返さない）
      println("Error fetching order \{id}")
      ApiResponse::Error(message="Internal server error")
    }
  }
}
```

## 依存パッケージのセキュリティ

- `moon tree` で依存ツリーを確認し、不要な推移的依存を把握する
- 依存パッケージの追加前にソースを確認する（`mooncakes.io` でパッケージ内容を確認）
- 依存数を最小限に保つ — 追加前に本当に必要か評価する

```bash
# 依存ツリーを表示
moon tree

# パッケージの追加・削除
moon add username/package
moon remove package
```

## 参照

詳細は skill: `moonbit-patterns` を参照（Newtype パターン、エラー処理パターン）。
セキュリティの一般的なチェックリストは skill: `security-review` を参照。
