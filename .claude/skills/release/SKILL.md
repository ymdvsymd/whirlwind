---
name: release
description: >
  バージョンアップ → ビルド → コミット → push → npm パブリッシュの一連のリリースフローを実行。
  "release", "リリース", "パブリッシュ", "publish", "バージョンアップ", "version bump".
argument-hint: version_bump:バージョンバンプ種別 patch/minor/major。省略時は修正差分から推測。
---

# release: npm リリースフロー

## 引数

```
/release [patch|minor|major]
```

`$ARGUMENTS` のパース:
- 最初のトークンを `BUMP` とする（省略時は修正差分から推測）
- 有効な値: `patch`, `minor`, `major`
- 無効な値の場合はエラーメッセージを出して終了

## 実行手順

以下を**必ず順番に**実行すること。各ステップが失敗した場合は即座に停止してユーザーに報告する。

### Step 1: 事前チェック

1. ワーキングツリーが clean であることを確認:
   ```bash
   git diff --quiet && git diff --cached --quiet
   ```
   dirty な場合はエラーを出して終了（「先にコミットしてください」）

2. 現在のブランチが `main` であることを確認

### Step 2: バージョンアップ

1. `package.json` の現在のバージョンを読み取る
2. `BUMP` に従って新バージョンを算出する
3. `npm version $BUMP --no-git-tag-version` で package.json を更新
4. `npm install --package-lock-only` で package-lock.json を同期する
5. `moon.mod.json` の `"version"` フィールドも同じ新バージョンに更新する

### Step 3: ビルド

```bash
just pack
```

ビルドが失敗した場合は停止。

### Step 4: コミット

バージョン関連で変更されたファイルを**すべて**ステージングすること。
漏れを防ぐため、`git status` で未ステージのファイルがないことを確認する。

```bash
git add package.json package-lock.json moon.mod.json
git status --short  # 未ステージのファイルが残っていないことを確認
git commit -m "chore: bump version to $NEW_VERSION"
```

`package-lock.json` が変更されているのにステージングから漏れるケースが過去にあった。必ず確認すること。

### Step 5: Push

```bash
git push origin main
```

push が失敗した場合は停止。

### Step 6: パブリッシュ

```bash
just publish
```

パブリッシュが失敗または権限拒否された場合は、**必ずユーザーに未パブリッシュであることを明確に伝える**。
「手動で `npm publish --access public` を実行してください」と案内すること。
パブリッシュが完了していないのに完了報告をしてはならない。

### Step 7: 完了報告

以下を表示:
- 旧バージョン → 新バージョン
- npm パッケージ URL: `https://www.npmjs.com/package/@ymdvsymd/whirlwind`

## 関連スキル

- **bd-runner** — リリース前にチケットを消化する際に使用。bd-runner 完了後に release を実行することがある
