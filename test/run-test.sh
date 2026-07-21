#!/usr/bin/env bash
# wartzar-bee CI Cost Guardrail — integration test
# Mocks tokenscope + git, runs entrypoint.sh, asserts outputs + exit codes.
# Usage: bash test/run-test.sh   (from any directory)
# Requires: bash, python3
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARDRAIL_DIR="$(dirname "$SCRIPT_DIR")"
ENTRYPOINT="$GUARDRAIL_DIR/entrypoint.sh"

PASS=0
FAIL=0

# ── colour helpers ────────────────────────────────────────────────────────────
green() { echo -e "\033[32m✓ $*\033[0m"; }
red()   { echo -e "\033[31m✗ $*\033[0m"; }

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    green "$label"
    (( PASS++ )) || true
  else
    red "$label — expected '$expected', got '$actual'"
    (( FAIL++ )) || true
  fi
}

assert_exit() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    green "$label"
    (( PASS++ )) || true
  else
    red "$label — expected exit $expected, got $actual"
    (( FAIL++ )) || true
  fi
}

# ── mock bin dir ──────────────────────────────────────────────────────────────
MOCK_BIN="$(mktemp -d)"
trap 'rm -rf "$MOCK_BIN"' EXIT
export PATH="$MOCK_BIN:$PATH"

# Mock git: swallow all calls (fetch/stash/checkout not needed for unit test)
cat > "$MOCK_BIN/git" <<'GITEOF'
#!/usr/bin/env bash
exit 0
GITEOF
chmod +x "$MOCK_BIN/git"

# write_mock_tokenscope HEAD_TOKENS BASE_TOKENS
# First invocation returns HEAD json; second returns BASE json.
write_mock_tokenscope() {
  local head_tokens="$1" base_tokens="$2"
  # Use a per-test counter file keyed by PID
  local counter_file="${TMPDIR:-/tmp}/.ts_mock_count_$$"
  rm -f "$counter_file"
  cat > "$MOCK_BIN/tokenscope" <<MOCK
#!/usr/bin/env bash
COUNTER_FILE="${counter_file}"
COUNT=\$(cat "\$COUNTER_FILE" 2>/dev/null || echo 0)
COUNT=\$(( COUNT + 1 ))
echo "\$COUNT" > "\$COUNTER_FILE"
if [[ "\$COUNT" -eq 1 ]]; then
  echo '{"total_tokens":${head_tokens},"files":[{"path":"agent/prompt.py","tokens":${head_tokens}}]}'
else
  echo '{"total_tokens":${base_tokens},"files":[{"path":"agent/prompt.py","tokens":${base_tokens}}]}'
fi
MOCK
  chmod +x "$MOCK_BIN/tokenscope"
}

# run_guardrail HEAD BASE THRESHOLD → sets LAST_EXIT, LAST_OUTPUT_FILE
run_guardrail() {
  local head_tokens="$1" base_tokens="$2" threshold="$3"
  write_mock_tokenscope "$head_tokens" "$base_tokens"

  LAST_OUTPUT_FILE="$(mktemp)"
  set +e
  env \
    INPUT_THRESHOLD_PCT="$threshold" \
    INPUT_WORKING_DIR="." \
    INPUT_BASE_REF="main" \
    GITHUB_BASE_REF="main" \
    GITHUB_OUTPUT="$LAST_OUTPUT_FILE" \
    GITHUB_REPOSITORY="" \
    GITHUB_TOKEN="" \
    PR_NUMBER="" \
    bash "$ENTRYPOINT" > /dev/null 2>&1
  LAST_EXIT=$?
  set -e
}

read_output() {
  # read_output KEY from LAST_OUTPUT_FILE
  grep "^$1=" "$LAST_OUTPUT_FILE" 2>/dev/null | tail -1 | cut -d= -f2-
}

# ── TEST 1: no regression (head == base) ─────────────────────────────────────
echo ""
echo "=== TEST 1: no regression (head=1000, base=1000, threshold=20%) ==="
run_guardrail 1000 1000 20
assert_exit "exit code 0 (pass)"  "0" "$LAST_EXIT"
assert_eq   "delta = 0.0%"        "0.0" "$(read_output cost-delta-pct)"
assert_eq   "head-cost-tokens"    "1000" "$(read_output head-cost-tokens)"
assert_eq   "base-cost-tokens"    "1000" "$(read_output base-cost-tokens)"
assert_eq   "blocked = false"     "false" "$(read_output blocked)"

# ── TEST 2: small regression under threshold ──────────────────────────────────
echo ""
echo "=== TEST 2: small regression (head=1100, base=1000, threshold=20%) ==="
run_guardrail 1100 1000 20
assert_exit "exit code 0 (pass)"  "0" "$LAST_EXIT"
assert_eq   "delta = 10.0%"       "10.0" "$(read_output cost-delta-pct)"
assert_eq   "blocked = false"     "false" "$(read_output blocked)"

# ── TEST 3: regression OVER threshold → blocked ───────────────────────────────
echo ""
echo "=== TEST 3: regression over threshold (head=1300, base=1000, threshold=20%) ==="
run_guardrail 1300 1000 20
assert_exit "exit code 1 (blocked)" "1" "$LAST_EXIT"
assert_eq   "delta = 30.0%"         "30.0" "$(read_output cost-delta-pct)"
assert_eq   "blocked = true"        "true" "$(read_output blocked)"

# ── TEST 4: threshold=0 → report-only, never blocks ──────────────────────────
echo ""
echo "=== TEST 4: threshold=0 (report-only, head=5000, base=100) ==="
run_guardrail 5000 100 0
assert_exit "exit code 0 (report-only)" "0" "$LAST_EXIT"
assert_eq   "blocked = false"           "false" "$(read_output blocked)"

# ── TEST 5: base=0 (new project, no base scan) ───────────────────────────────
echo ""
echo "=== TEST 5: base=0 (new project baseline) ==="
run_guardrail 500 0 20
assert_exit "exit code 0 (base=0 → delta=0)" "0" "$LAST_EXIT"
assert_eq   "delta = 0.0%"                    "0.0" "$(read_output cost-delta-pct)"
assert_eq   "blocked = false"                 "false" "$(read_output blocked)"

# ── TEST 6: improvement (head < base) → always passes ────────────────────────
echo ""
echo "=== TEST 6: improvement (head=800, base=1000, threshold=20%) ==="
run_guardrail 800 1000 20
assert_exit "exit code 0 (improvement)" "0" "$LAST_EXIT"
assert_eq   "blocked = false"           "false" "$(read_output blocked)"

# ── summary ──────────────────────────────────────────────────────────────────
echo ""
echo "────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
echo "────────────────────────────────────────"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
echo "All tests passed."
