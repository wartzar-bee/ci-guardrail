#!/usr/bin/env bash
# wartzar-bee CI Cost Guardrail — entrypoint
# Runs tokenscope on HEAD vs BASE, computes delta, posts PR comment, optionally blocks.
# minimal: static-analysis cost estimate only (no live run); upgrade path -> live sandbox run
set -euo pipefail

THRESHOLD_PCT="${INPUT_THRESHOLD_PCT:-20}"
WORKING_DIR="${INPUT_WORKING_DIR:-.}"
BASE_REF="${INPUT_BASE_REF:-}"

# Resolve base ref
if [[ -z "$BASE_REF" ]]; then
  BASE_REF="${GITHUB_BASE_REF:-main}"
fi

echo "::group::wartzar-bee cost guardrail"
echo "Working dir : $WORKING_DIR"
echo "Base ref    : $BASE_REF"
echo "Threshold   : ${THRESHOLD_PCT}%"

# Scan HEAD
HEAD_JSON=$(tokenscope scan --json --dir "$WORKING_DIR" 2>/dev/null || echo '{"total_tokens":0,"files":[]}')
HEAD_TOKENS=$(echo "$HEAD_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('total_tokens',0))")

# Scan BASE: fetch, stash, checkout base files, scan, restore
git fetch --depth=1 origin "$BASE_REF" 2>/dev/null || true
git stash 2>/dev/null || true
git checkout "origin/$BASE_REF" -- "$WORKING_DIR" 2>/dev/null || true
BASE_JSON=$(tokenscope scan --json --dir "$WORKING_DIR" 2>/dev/null || echo '{"total_tokens":0,"files":[]}')
git checkout HEAD -- "$WORKING_DIR" 2>/dev/null || true
git stash pop 2>/dev/null || true

BASE_TOKENS=$(echo "$BASE_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('total_tokens',0))")

# Compute delta %
DELTA_PCT=$(python3 -c "
base=int('$BASE_TOKENS'); head=int('$HEAD_TOKENS')
pct = 0.0 if base == 0 else (head - base) / base * 100
print(f'{pct:.1f}')
")

echo "Base tokens : $BASE_TOKENS"
echo "Head tokens : $HEAD_TOKENS"
echo "Delta       : ${DELTA_PCT}%"

# Set step outputs
echo "cost-delta-pct=${DELTA_PCT}"     >> "$GITHUB_OUTPUT"
echo "head-cost-tokens=${HEAD_TOKENS}" >> "$GITHUB_OUTPUT"
echo "base-cost-tokens=${BASE_TOKENS}" >> "$GITHUB_OUTPUT"

# Threshold check
BLOCKED="false"
THRESHOLD_BREACHED="false"
if python3 -c "import sys; pct=float('$DELTA_PCT'); thr=float('$THRESHOLD_PCT'); sys.exit(0 if pct > thr and thr > 0 else 1)" 2>/dev/null; then
  THRESHOLD_BREACHED="true"
  BLOCKED="true"
fi

# Build top-5 costliest files table
TOP_FILES=$(echo "$HEAD_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
files = sorted(d.get('files', []), key=lambda f: f.get('tokens', 0), reverse=True)[:5]
if not files:
    print('_No file-level data available._')
else:
    rows = ['| File | Tokens |', '|------|--------|']
    for f in files:
        rows.append(f'| \`{f[\"path\"]}\` | {f[\"tokens\"]:,} |')
    print('\n'.join(rows))
" 2>/dev/null || echo "_File breakdown unavailable._")

# Pick emoji
EMOJI="✅"
if [[ "$THRESHOLD_BREACHED" == "true" ]]; then
  EMOJI="🚨"
elif python3 -c "import sys; sys.exit(0 if float('$DELTA_PCT') > 5 else 1)" 2>/dev/null; then
  EMOJI="⚠️"
fi

BLOCK_MSG=""
if [[ "$THRESHOLD_BREACHED" == "true" ]]; then
  BLOCK_MSG="

> ⛔ **Build blocked** — cost regression exceeds the ${THRESHOLD_PCT}% threshold. Reduce prompt size, add caching, or raise the threshold if intentional."
fi

BASE_FMT=$(python3 -c "print(f'{int(\"$BASE_TOKENS\"):,}')")
HEAD_FMT=$(python3 -c "print(f'{int(\"$HEAD_TOKENS\"):,}')")

COMMENT="## ${EMOJI} wartzar-bee Cost Guardrail

| Metric | Value |
|--------|-------|
| Base branch tokens | ${BASE_FMT} |
| This PR tokens | ${HEAD_FMT} |
| Delta | **${DELTA_PCT}%** |
| Threshold | ${THRESHOLD_PCT}% |

### Top token consumers (HEAD)
${TOP_FILES}${BLOCK_MSG}

<sub>Powered by [wartzar-bee/tokenscope](https://github.com/wartzar-bee/tokenscope) · [cost-guardrail docs](https://github.com/wartzar-bee/ci-guardrail)</sub>"

# Post PR comment (idempotent — delete old, post new)
PR_NUMBER="${GITHUB_EVENT_PULL_REQUEST_NUMBER:-${PR_NUMBER:-}}"
if [[ -n "$PR_NUMBER" && -n "${GITHUB_REPOSITORY:-}" && -n "${GITHUB_TOKEN:-}" ]]; then
  # Find and delete previous guardrail comment
  EXISTING=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
    "https://api.github.com/repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments" \
    | python3 -c "
import sys, json
comments = json.load(sys.stdin)
for c in comments:
    if 'wartzar-bee Cost Guardrail' in c.get('body',''):
        print(c['id'])
        break
" 2>/dev/null || true)

  if [[ -n "$EXISTING" ]]; then
    curl -s -X DELETE -H "Authorization: token $GITHUB_TOKEN" \
      "https://api.github.com/repos/${GITHUB_REPOSITORY}/issues/comments/${EXISTING}" > /dev/null
  fi

  # Post new comment
  PAYLOAD=$(python3 -c "import json,sys; print(json.dumps({'body': sys.argv[1]}))" "$COMMENT")
  curl -s -X POST \
    -H "Authorization: token $GITHUB_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    "https://api.github.com/repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments" > /dev/null
  echo "PR comment posted."
else
  echo "Not in a PR context — skipping comment post."
fi

echo "blocked=${BLOCKED}" >> "$GITHUB_OUTPUT"
echo "::endgroup::"

# Block build if threshold breached
if [[ "$BLOCKED" == "true" ]]; then
  echo "::error::Cost regression ${DELTA_PCT}% exceeds threshold ${THRESHOLD_PCT}%. See PR comment for details."
  exit 1
fi

echo "Cost guardrail passed (delta=${DELTA_PCT}%, threshold=${THRESHOLD_PCT}%)."
