#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

cat >"$TMP_DIR/tornado.json" <<'EOF'
{
  "project_dir": ".",
  "review_dir": "docs/reviews",
  "max_review_cycles": 3,
  "review_interval": 1,
  "ralph_enabled": true,
  "milestones_path": "milestones.json",
  "max_rework_attempts": 3,
  "agents": [
    {
      "id": "planner",
      "kind": "mock",
      "role": "planner",
      "working_dir": ".",
      "max_iterations": 1
    },
    {
      "id": "builder",
      "kind": "codex",
      "role": "builder",
      "working_dir": ".",
      "max_iterations": 10
    },
    {
      "id": "verifier",
      "kind": "claude-code",
      "role": "verifier",
      "working_dir": ".",
      "max_iterations": 5
    }
  ]
}
EOF

cat >"$TMP_DIR/milestones.json" <<'EOF'
{
  "milestones": [
    {
      "id": "m1",
      "goal": "Create project scaffolding. Wave 0 creates the README. Wave 1 will add integration tests in a later pass by creating a LICENSE file. Do not verify wave 1 work during wave 0 verification.",
      "status": "pending",
      "tasks": [
        {
          "id": "m1-t1",
          "description": "Create a file named README.md with the content: # Test Project\n\nThis is a test project.",
          "wave": 0,
          "status": "pending"
        },
        {
          "id": "m1-t2",
          "description": "Create a file named LICENSE with the content: MIT License",
          "wave": 1,
          "status": "pending"
        }
      ]
    }
  ]
}
EOF

cd "$TMP_DIR"
OUTPUT="$(node "$ROOT_DIR/bin/tornado.js" --ralph --config=tornado.json 2>&1)" || true

printf '%s\n' "$OUTPUT"

assert_contains() {
  local needle="$1"
  if ! printf '%s\n' "$OUTPUT" | grep -Fq "$needle"; then
    echo "FAIL: expected output to contain: $needle" >&2
    exit 1
  fi
}

assert_contains "Verifying perspective: CodeQuality"
assert_contains "Verifying perspective: Performance"
assert_contains "Verifying perspective: Security"
assert_contains "Verifying perspective: GoalAlignment"
assert_contains "Wave 0 approved"
assert_contains "Wave 1 approved"
assert_contains "Milestone m1 complete"

echo "PASS: All live e2e assertions passed"
