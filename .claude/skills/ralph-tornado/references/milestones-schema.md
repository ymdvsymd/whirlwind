# milestones-skeleton.json スキーマ

`milestones-skeleton.json` は Plan Context **なし** の中間ファイル。
`scripts/inject-plan-context.js` が Verification Scope と Plan Context を注入して `milestones.json` を生成する。

## JSON 構造

```json
{
  "milestones": [
    {
      "id": "m1",
      "goal": "Goal text from ## heading (in English)",
      "status": "pending",
      "tasks": [
        {
          "id": "m1-t1",
          "description": "## Task\n<concrete instructions in English>\n\n## Acceptance Criteria\n- [ ] File exists: <path>\n- [ ] <path> contains: <expected content>\n- [ ] Run: <command> → <expected result>",
          "wave": 0,
          "status": "pending",
          "result": null,
          "plan_doc": null
        }
      ]
    }
  ]
}
```

## フィールド定義

### milestone

| フィールド | 型     | 説明 |
|-----------|--------|------|
| `id`      | string | `m{連番}` 形式（例: `m1`, `m2`） |
| `goal`    | string | `## 見出し` テキスト（英語） |
| `status`  | string | 固定値: `"pending"` |
| `tasks`   | array  | タスク配列 |

### task

| フィールド    | 型          | 説明 |
|--------------|-------------|------|
| `id`         | string      | `{milestone_id}-t{連番}` 形式（例: `m1-t1`） |
| `description`| string      | description テンプレートに従った実装指示（英語） |
| `wave`       | number      | Wave 番号（0始まり、`###` で +1） |
| `status`     | string      | 固定値: `"pending"` |
| `result`     | null        | 固定値: `null` |
| `plan_doc`   | null        | 固定値: `null` |

## skeleton 固有の注記

- `goal` に Verification Scope・Plan Context は含めない（`inject-plan-context.js` が後で注入）
- `description` に Plan Context は含めない（同上）
- `wave` は `###` サブ見出しの出現ごとに +1（初期値 0）
