# whirlwind

Multi-agent development orchestrator with TUI.

## Usage

### Pattern 1: Run with `npx`

```bash
# run from a plan file (first positional arg must be an existing file)
npx -y @ymdvsymd/whirlwind ./plan.md --dev=codex --review=claude

# run with explicit config
npx -y @ymdvsymd/whirlwind --config=./whirlwind.json --dev=codex --review=claude

# validate config
npx -y @ymdvsymd/whirlwind validate ./whirlwind.json
```

### Pattern 2: Install globally with `npm i -g`

```bash
npm i -g @ymdvsymd/whirlwind

# run from a plan file
whirlwind ./plan.md --dev=codex --review=claude

# run with explicit config
whirlwind --config=./whirlwind.json --dev=codex --review=claude

# validate config
whirlwind validate ./whirlwind.json
```

### Pattern 3: Ralph mode (milestone-driven autonomous development)

```bash
# run with default preset (Planner + Builder + Verifier)
whirlwind --ralph

# run with config file
whirlwind --ralph --config=./whirlwind.json

# override builder kind
whirlwind --ralph --dev=codex --lang=ja
```

## Agent kind options

- `claude` / `claude-code`
- `codex`
- `api`
- `mock`
