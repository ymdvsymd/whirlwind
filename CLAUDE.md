# Whirlwind — AI Agent Instructions

## Architecture
- **MoonBit** core: `src/` (build: `moon build/test/fmt`)
- **TypeScript** SDK: `sdk/` (build: `tsc`)
- **CLI**: `src/cmd/app/` — MoonBit app compiled to JS
- **Docs**: `docs/` (numbered guides), `docs/adrs/` (ADRs)

## Build & Test
Uses `just` (see `justfile`) and `moon` (MoonBit toolchain).
```
just test      # unit tests (SDK + MoonBit)
just mock      # E2E with mock server
just live      # E2E with live server
just coverage  # SDK test coverage
just fmt       # MoonBit format
```

## Quality Rules
- Run `just test` before committing
- Run `moon fmt` and `npx prettier --write` for formatting
- No `console.log` in non-test files (enforced by hook)

## Issue Tracking
Uses **bd (beads)**. Run `bd prime` for full workflow and commands.

## Session Completion
1. File issues for remaining work (`bd`)
2. Run quality gates: `just test`
3. Update issue status, close finished work
4. Push: `git pull --rebase && bd dolt push && git push`
5. Verify `git status` shows "up to date with origin"
