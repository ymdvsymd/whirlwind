#!/usr/bin/env bash
# ============================================================
# whirlwind E2E test runner
#
# Modes:
#   mock        — mock agents, --plan full DAG 実行 (DEPENDS_ON形式 + DAGディスパッチ検証)
#   live        — real agents, --plan full 実行
#   live --dry-run              — real agents, plan 変換のみ (LLM 分類あり)
#   mock-flags  — mock agents, CLI フラグ経由 (--milestones パス)
#   live-flags  — real agents, CLI フラグ経由 (--milestones パス)
#
# Examples:
#   just mock                              # mock full DAG execution (CI 向け)
#   just live                              # plan full 実行
#   just live -- --dry-run                 # plan 変換のみ (LLM 分類)
# ============================================================
set -euo pipefail
MODE="${1:-mock}"   # "mock", "live", "mock-flags", "live-flags"
shift || true
EXTRA_ARGS=("$@")  # live モードで --dry-run 等を渡す

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

case "$MODE" in
  mock|mock-flags)
    PLANNER_KIND="mock"
    BUILDER_KIND="mock"
    VERIFIER_KIND="mock"
    ;;
  live|live-flags)
    PLANNER_KIND="claude-code"
    BUILDER_KIND="codex"
    VERIFIER_KIND="claude-code"
    ;;
  *)
    echo "Usage: $0 [mock|live|mock-flags|live-flags]" >&2
    exit 1
    ;;
esac

# --- EXTRA_ARGS helper (live モードで --dry-run の有無を判定) ---
has_arg_exact() {
  local expected="$1"
  local arg
  for arg in "${EXTRA_ARGS[@]}"; do
    if [[ "$arg" == "$expected" ]]; then
      return 0
    fi
  done
  return 1
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
  } >bin/whirlwind.js
  chmod +x bin/whirlwind.js
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
LOG_FILE="$TMP_DIR/whirlwind.log"
OUTPUT_FILE="$TMP_DIR/whirlwind.stdout.log"

# Initialize git repo in temp dir (required by Codex SDK for file operations)
git init -q "$TMP_DIR"

# --- テスト入力ファイルの生成 ---
# mock/live: shared plan.md → --plan で変換・実行
# *-flags:   milestones.json → --milestones で直接実行

# Shared plan.md for mock and live modes
if [ "$MODE" = "mock" ] || [ "$MODE" = "live" ]; then
  cat >"$TMP_DIR/plan.md" <<'EOF'
# Ralph e2e plan

Create a minimal Node.js hello-world project with one source file and one test file.
Do not install any npm packages.

## Step 1: Create hello module and tests
Create src/hello.js exporting greet(name) that returns 'Hello, <name>!' and create tests/hello.test.js using Node assert to verify greet('World') === 'Hello, World!'

## Step 2: Run tests and verify
Run 'node tests/hello.test.js' and verify it exits with code 0 with no assertion errors
EOF
fi

# milestones.json for *-flags modes (tests --milestones code path)
if [ "$MODE" = "mock-flags" ] || [ "$MODE" = "live-flags" ]; then
  cat >"$TMP_DIR/milestones.json" <<'EOF'
{
  "brief": "Create a minimal Node.js hello-world project with one source file and one test file.\nDo not install any npm packages.",
  "milestones": [
    {
      "id": "m1",
      "goal": "Create src/hello.js exporting greet(name) that returns 'Hello, <name>!' and create tests/hello.test.js using Node assert to verify greet('World') === 'Hello, World!'",
      "status": "pending",
      "summary": "",
      "tasks": []
    },
    {
      "id": "m2",
      "goal": "Run 'node tests/hello.test.js' and verify it exits with code 0 with no assertion errors",
      "status": "pending",
      "summary": "",
      "tasks": []
    }
  ]
}
EOF
fi

cd "$TMP_DIR"
# Unset CLAUDECODE to allow Claude Agent SDK to spawn Claude Code subprocesses
# (prevents "nested session" error when running inside a Claude Code session)
unset CLAUDECODE

# --- 実行 ---
# mock:       --plan full DAG 実行 (mock agents で DEPENDS_ON→DAG dispatch 検証)
# live:       --plan + EXTRA_ARGS (--dry-run 渡せば変換のみ、なければ full 実行)
# *-flags:    CLI フラグで直接 milestones を指定
set +e
case "$MODE" in
  mock)
    node "$ROOT_DIR/bin/whirlwind.js" --plan="$TMP_DIR/plan.md" --planner="$PLANNER_KIND" --builder="$BUILDER_KIND" --verifier="$VERIFIER_KIND" --log="$LOG_FILE" 2>&1 | tee "$OUTPUT_FILE"
    CMD_STATUS=${PIPESTATUS[0]}
    ;;
  live)
    node "$ROOT_DIR/bin/whirlwind.js" --plan="$TMP_DIR/plan.md" --planner="$PLANNER_KIND" --builder="$BUILDER_KIND" --verifier="$VERIFIER_KIND" --log="$LOG_FILE" "${EXTRA_ARGS[@]}" 2>&1 | tee "$OUTPUT_FILE"
    CMD_STATUS=${PIPESTATUS[0]}
    ;;
  mock-flags|live-flags)
    node "$ROOT_DIR/bin/whirlwind.js" --planner="$PLANNER_KIND" --builder="$BUILDER_KIND" --verifier="$VERIFIER_KIND" --milestones=milestones.json --log="$LOG_FILE" 2>&1 | tee "$OUTPUT_FILE"
    CMD_STATUS=${PIPESTATUS[0]}
    ;;
esac
set -e

OUTPUT="$(cat "$OUTPUT_FILE")"

# live + --dry-run の組み合わせはアサーションを dry-run 系に切り替える
IS_DRY_RUN=false
if [ "$MODE" = "live" ] && has_arg_exact "--dry-run"; then
  IS_DRY_RUN=true
fi

if [ "$CMD_STATUS" -ne 0 ]; then
  echo "FAIL: whirlwind exited with code $CMD_STATUS" >&2
  exit "$CMD_STATUS"
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

assert_pending_milestone_exists() {
  local file="$1"
  node -e '
    const fs = require("fs");
    const file = process.argv[1];
    const data = JSON.parse(fs.readFileSync(file, "utf8"));
    if (typeof data.brief !== "string" || data.brief.trim() === "") {
      console.error("FAIL: expected non-empty brief");
      process.exit(1);
    }
    if (!Array.isArray(data.milestones) || data.milestones.length === 0) {
      console.error("FAIL: expected at least one milestone");
      process.exit(1);
    }
    if (!data.milestones.some((m) => m && m.status === "pending")) {
      console.error("FAIL: expected at least one pending milestone");
      process.exit(1);
    }
  ' "$file"
}

# --- アサーション ---
# USES_PLAN_MODE: mock, live → .runs/ 下の milestones.json を検証
# IS_DRY_RUN:     mock, live+--dry-run → pending milestones を検証
USES_PLAN_MODE=false
case "$MODE" in
  mock|live) USES_PLAN_MODE=true ;;
esac

if [ "$USES_PLAN_MODE" = true ]; then
  # --plan mode: milestones.json は .runs/ 下に生成される
  RUN_MILESTONES="$(find "$TMP_DIR/.runs" -name milestones.json -print -quit 2>/dev/null || true)"
  if [ -z "$RUN_MILESTONES" ]; then
    echo "FAIL: expected generated milestones.json under $TMP_DIR/.runs" >&2
    exit 1
  fi
  assert_file_contains "$LOG_FILE" "Generated milestones at .runs/"
  if [ "$IS_DRY_RUN" = true ]; then
    assert_pending_milestone_exists "$RUN_MILESTONES"
    assert_contains "Dry-run complete"
  else
    assert_contains "Milestone m1 complete"
    assert_contains "Milestone m2 complete"
    assert_file_contains "$LOG_FILE" "Milestone m1 complete"
    assert_file_contains "$LOG_FILE" "Milestone m2 complete"
    assert_milestone_summary_non_empty "$RUN_MILESTONES" "m1"
  fi
else
  # *-flags mode: milestones.json は $TMP_DIR 直下
  assert_contains "Milestone m1 complete"
  assert_contains "Milestone m2 complete"
  assert_contains "Milestones saved to milestones.json"
  assert_file_contains "$LOG_FILE" "Milestone m1 complete"
  assert_file_contains "$LOG_FILE" "Milestone m2 complete"
  assert_milestone_summary_non_empty "$TMP_DIR/milestones.json" "m1"
fi

if [ ! -f "$LOG_FILE" ]; then
  echo "FAIL: expected log file to exist: $LOG_FILE" >&2
  exit 1
fi

if grep -P '\x1b\[' "$LOG_FILE" 2>/dev/null; then
  echo "FAIL: log file contains ANSI escape codes" >&2
  exit 1
fi

if { [ "$MODE" = "live" ] || [ "$MODE" = "live-flags" ]; } && [ "$IS_DRY_RUN" != true ]; then
  assert_contains "SCOPE:"
  assert_file_contains "$LOG_FILE" "SCOPE:"
fi

# --- DAG execution assertions (mock mode: full DAG dispatch 検証) ---
if [ "$MODE" = "mock" ]; then
  # DAG dispatch was used (not wave-based)
  assert_file_contains "$LOG_FILE" "Executing DAG for"
  # Tasks were dispatched with batch tracking
  assert_file_contains "$LOG_FILE" "Dispatching task"
  assert_file_contains "$LOG_FILE" "batch:"
fi

echo "PASS: All e2e assertions passed ($MODE)"
