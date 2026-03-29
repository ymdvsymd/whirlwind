---
paths:
  - "**/*.mbt"
  - "**/moon.pkg.json"
  - "**/moon.pkg"
---
# MoonBit フック

> このファイルは [common/hooks.md](../common/hooks.md) を MoonBit 向けに拡張する。

## PostToolUse フック

`~/.claude/settings.json` で設定する:

- **`moon fmt`**: `.mbt` ファイル編集後に自動整形
- **`moon check`**: `.mbt` ファイル編集後に型検査+lint（コンパイルエラーの早期検出）

## whirlwind 既存フックとの関係

whirlwind には以下の MoonBit 用フックが既に設定されている:

- `post-edit-moonbit-fmt.sh` — 編集後の自動フォーマット
- `post-edit-moonbit-check.sh` — 編集後の型チェック

これらが正しく動作していれば、追加のフック設定は不要。フックが無効な場合や新規環境では、以下を `settings.json` の `hooks` セクションに追加する:

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "moon fmt",
            "description": "MoonBit auto-format"
          }
        ]
      }
    ]
  }
}
```
