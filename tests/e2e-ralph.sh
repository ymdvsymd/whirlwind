#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-mock}"   # "mock" or "live"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

case "$MODE" in
  mock)
    PLANNER_KIND="mock"
    BUILDER_KIND="mock"
    VERIFIER_KIND="mock"
    BRIEF='Fix bugs and add tests'
    ;;
  live)
    PLANNER_KIND="claude-code"
    BUILDER_KIND="codex"
    VERIFIER_KIND="claude-code"
    ;;
  *)
    echo "Usage: $0 [mock|live]" >&2
    exit 1
    ;;
esac

build_live_brief() {
  local plan_file="$1"
  node -e '
    const fs = require("fs");
    const path = process.argv[1];
    const text = fs.readFileSync(path, "utf8");
    const lines = text.split(/\r?\n/);
    let section = "";
    const parts = [];
    for (const line of lines) {
      if (/^##\s+/.test(line)) {
        section = line.replace(/^##\s+/, "").trim().toLowerCase();
        continue;
      }
      if (!line.trim()) continue;
      if (section === "goals" || section === "constraints") {
        parts.push(line.replace(/^[-*]\s*/, "").trim());
      }
    }
    process.stdout.write(parts.join("\n"));
  ' "$plan_file"
}

cd "$ROOT_DIR"
if command -v just >/dev/null 2>&1; then
  just pack >/dev/null
else
  npm run -s build:sdk >/dev/null
  moon build --target js src/cmd/app >/dev/null
  mkdir -p bin
  {
    echo '#!/usr/bin/env node'
    cat _build/js/debug/build/cmd/app/app.js
  } >bin/tornado.js
  chmod +x bin/tornado.js
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
LOG_FILE="$TMP_DIR/tornado.log"

# Initialize git repo in temp dir (required by Codex SDK for file operations)
git init -q "$TMP_DIR"

if [ "$MODE" = "live" ]; then
  cat >"$TMP_DIR/plan.md" <<'EOF'
# Ralph e2e plan

## Goals
- Create a minimal Node.js hello-world project with one source file and one test file

## Constraints
- Each milestone should require at most 2 tasks in a single wave
- Do not install any npm packages
EOF
  BRIEF="$(build_live_brief "$TMP_DIR/plan.md")"
fi

cat >"$TMP_DIR/tornado.json" <<EOF
{
  "project_dir": ".",
  "review_dir": "docs/reviews",
  "max_review_cycles": 3,
  "review_interval": 1,
  "ralph_enabled": true,
  "milestones_path": "milestones.json",
  "max_rework_attempts": 2,
  "agents": [
    {
      "id": "planner",
      "kind": "$PLANNER_KIND",
      "role": "planner",
      "working_dir": ".",
      "max_iterations": 10
    },
    {
      "id": "builder",
      "kind": "$BUILDER_KIND",
      "role": "builder",
      "working_dir": ".",
      "max_iterations": 10
    },
    {
      "id": "verifier",
      "kind": "$VERIFIER_KIND",
      "role": "verifier",
      "working_dir": ".",
      "max_iterations": 5
    }
  ]
}
EOF

cat >"$TMP_DIR/milestones.json" <<EOF
{
  "brief": $(node -p 'JSON.stringify(process.argv[1])' "$BRIEF"),
  "milestones": [
    {
      "id": "m1",
      "goal": "Create src/hello.js that exports a greet(name) function returning 'Hello, <name>!'",
      "status": "pending",
      "summary": "",
      "tasks": []
    },
    {
      "id": "m2",
      "goal": "Create tests/hello.test.js that uses Node assert to test greet('World') === 'Hello, World!'",
      "status": "pending",
      "summary": "",
      "tasks": []
    },
    {
      "id": "m3",
      "goal": "Run 'node tests/hello.test.js' and verify it exits with code 0",
      "status": "pending",
      "summary": "",
      "tasks": []
    }
  ]
}
EOF

cd "$TMP_DIR"
# Unset CLAUDECODE to allow Claude Agent SDK to spawn Claude Code subprocesses
# (prevents "nested session" error when running inside a Claude Code session)
unset CLAUDECODE
if [ "$MODE" = "mock" ]; then
  OUTPUT="$(node "$ROOT_DIR/bin/tornado.js" --ralph --config=tornado.json --log="$LOG_FILE" 2>&1)"
else
  OUTPUT="$(node "$ROOT_DIR/bin/tornado.js" --ralph --config=tornado.json --log="$LOG_FILE" 2>&1)"
fi

printf '%s\n' "$OUTPUT"

assert_contains() {
  local needle="$1"
  if ! printf '%s\n' "$OUTPUT" | grep -Fq "$needle"; then
    echo "FAIL: expected output to contain: $needle" >&2
    exit 1
  fi
}

assert_file_contains() {
  local file="$1"
  local needle="$2"
  if ! grep -Fq "$needle" "$file"; then
    echo "FAIL: expected $file to contain: $needle" >&2
    exit 1
  fi
}

assert_milestone_summary_non_empty() {
  local file="$1"
  local milestone_id="$2"
  node -e '
    const fs = require("fs");
    const file = process.argv[1];
    const milestoneId = process.argv[2];
    const data = JSON.parse(fs.readFileSync(file, "utf8"));
    const milestone = (data.milestones || []).find((m) => m.id === milestoneId);
    if (!milestone) {
      console.error(`FAIL: milestone not found: ${milestoneId}`);
      process.exit(1);
    }
    if (typeof milestone.summary !== "string" || milestone.summary.trim() === "") {
      console.error(`FAIL: expected non-empty summary for ${milestoneId}`);
      process.exit(1);
    }
  ' "$file" "$milestone_id"
}

assert_contains "Milestone m1 complete"
assert_contains "Milestone m2 complete"
assert_contains "Milestone m3 complete"
assert_contains "Milestones saved to milestones.json"

assert_milestone_summary_non_empty "$TMP_DIR/milestones.json" "m1"
assert_milestone_summary_non_empty "$TMP_DIR/milestones.json" "m2"

if [ ! -f "$LOG_FILE" ]; then
  echo "FAIL: expected log file to exist: $LOG_FILE" >&2
  exit 1
fi

if grep -P '\x1b\[' "$LOG_FILE" 2>/dev/null; then
  echo "FAIL: log file contains ANSI escape codes" >&2
  exit 1
fi

assert_file_contains "$LOG_FILE" "Milestone m1 complete"
assert_file_contains "$LOG_FILE" "Milestone m2 complete"
assert_file_contains "$LOG_FILE" "Milestone m3 complete"

echo "PASS: All e2e assertions passed ($MODE)"
