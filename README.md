# tornado

Multi-agent development orchestrator with TUI.

## Usage

### Pattern 1: Run with `npx`

```bash
# run from a plan file (first positional arg must be an existing file)
npx -y @ymdvsymd/tornado ./plan.md --dev=codex --review=claude

# run with explicit config
npx -y @ymdvsymd/tornado --config=./tornado.json --dev=codex --review=claude

# validate config
npx -y @ymdvsymd/tornado validate ./tornado.json
```

### Pattern 2: Install globally with `npm i -g`

```bash
npm i -g @ymdvsymd/tornado

# run from a plan file
tornado ./plan.md --dev=codex --review=claude

# run with explicit config
tornado --config=./tornado.json --dev=codex --review=claude

# validate config
tornado validate ./tornado.json
```

### Pattern 3: Ralph mode (milestone-driven autonomous development)

```bash
# run with default preset (Planner + Builder + Verifier)
tornado --ralph

# run with config file
tornado --ralph --config=./tornado.json

# override builder kind
tornado --ralph --dev=codex --lang=ja
```

## Agent kind options

- `claude` / `claude-code`
- `codex`
- `api`
- `mock`
