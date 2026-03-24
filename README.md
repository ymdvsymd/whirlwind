# whirlwind

Multi-agent development orchestrator — milestone-driven autonomous development with Planner, Builder, and Verifier agents.

## Quick start

1. Create a `milestones.json` (see format below)
2. Run whirlwind:

```bash
npx -y @ymdvsymd/whirlwind --milestones=./milestones.json
```

## milestones.json

whirlwind requires a `milestones.json` file that defines what to build. Without it, the tool exits immediately.

```json
{
  "brief": "Background context for the project and what needs to be done",
  "milestones": [
    {
      "id": "m1",
      "goal": "Implement feature X\n\n### Step 1: ...\n### Step 2: ...",
      "status": "pending",
      "summary": "",
      "tasks": []
    }
  ]
}
```

| Field | Type | Description |
|-------|------|-------------|
| `brief` | string | Project context — background, target files, design decisions |
| `milestones[].id` | string | Milestone ID (`m1`, `m2`, ...) |
| `milestones[].goal` | string | Full implementation details — file paths, code examples, steps |
| `milestones[].status` | string | `"pending"` / `"done"` |
| `milestones[].summary` | string | Populated by whirlwind on completion |
| `milestones[].tasks` | array | Populated by whirlwind during execution |

Default path: `.whirlwind/milestones.json` (override with `--milestones=PATH`).

## Usage

### Pattern 1: Run with `npx`

```bash
npx -y @ymdvsymd/whirlwind --milestones=./milestones.json

# with config file
npx -y @ymdvsymd/whirlwind --config=./whirlwind.json --milestones=./milestones.json

# override agent kinds
npx -y @ymdvsymd/whirlwind --milestones=./milestones.json --builder=codex --verifier=claude-code

# override models
npx -y @ymdvsymd/whirlwind --milestones=./milestones.json --planner-model=sonnet --builder-model=opus

# validate config
npx -y @ymdvsymd/whirlwind validate ./whirlwind.json
```

### Pattern 2: Install globally with `npm i -g`

```bash
npm i -g @ymdvsymd/whirlwind

whirlwind --milestones=./milestones.json

# with config file
whirlwind --config=./whirlwind.json --milestones=./milestones.json

# override agent kinds
whirlwind --milestones=./milestones.json --builder=codex --lang=ja

# override models
whirlwind --milestones=./milestones.json --planner-model=sonnet --verifier-model=haiku

# validate config
whirlwind validate ./whirlwind.json
```

## CLI flags

| Flag | Description |
|------|-------------|
| `--milestones=PATH` | Milestones JSON file path (default: `.whirlwind/milestones.json`) |
| `--config=PATH` | Config file path |
| `--planner=KIND` | Override planner agent kind |
| `--builder=KIND` | Override builder agent kind |
| `--verifier=KIND` | Override verifier agent kind |
| `--planner-model=MODEL` | Override planner model (default: `opus` for claude-code) |
| `--builder-model=MODEL` | Override builder model (default: `opus` for claude-code) |
| `--verifier-model=MODEL` | Override verifier model (default: `sonnet` for claude-code) |
| `--lang=LANG` | Review language (`auto`/`ja`/`en`) |
| `--log=PATH` | Log file path |

## Agent kind options

- `claude` / `claude-code`
- `codex`
- `mock`

## Model defaults

When using `claude-code` kind, models default to:

| Role | Default model |
|------|---------------|
| Planner | `opus` |
| Builder | `opus` |
| Verifier | `sonnet` |

Model aliases (`opus`, `sonnet`, `haiku`) resolve to the latest version automatically. You can also specify exact model IDs like `claude-sonnet-4-6`.
