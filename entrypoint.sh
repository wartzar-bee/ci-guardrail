#!/usr/bin/env bash
# wartzar-bee CI Cost Guardrail — entrypoint
# Runs tokenscope on HEAD vs BASE, computes delta, posts PR comment, optionally blocks.
# minimal: static-analysis cost estimate only (no live run); upgrade path -> live sandbox run
set -euo pipefail

THRESHOLD_PCT="${INPUT_THRESHOLD_PCT:-20}"
WORKING_DIR="${INPUT_WORKING_DIR:-.}"
BASE_REF="${INPUT_BASE_REF:-}"
PRICE_PER_1M="${INPUT_PRICE_PER_1M:-3.00}"

# Resolve base ref
if [[ -z "$BASE_REF" ]]; then
  BASE_REF="${GITHUB_BASE_REF:-main}"
fi

echo "::group::wartzar-bee cost guardrail"
echo "Working dir : $WORKING_DIR"
echo "Base ref    : $BASE_REF"
echo "Threshold   : ${THRESHOLD_PCT}%"

# Run a tokenscope scan and ALWAYS emit valid JSON. tokenscope <0.2.3 lacks the `scan`
# engine and answers with a non-JSON "Not found: scan" line on stdout while exiting 0 —
# which would crash the downstream json.load under `set -e`. Fall back to an empty result
# so the guardrail degrades gracefully instead of failing the user's build cryptically.
scan_json() {
  local out
  out=$(tokenscope scan --json --dir "$1" 2>/dev/null || true)
  if echo "$out" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
    printf '%s' "$out"
  else
    printf '%s' '{"total_tokens":0,"files":[]}'
  fi
}

# Scan HEAD (capture raw once so we can both validate the JSON and detect a tokenscope
# that lacks the scan engine — that way the comment can explain *why* cost is 0 instead
# of silently misreporting it). This is a single scan, so the base-scan ordering below is
# unchanged.
HEAD_RAW=$(tokenscope scan --json --dir "$WORKING_DIR" 2>/dev/null || true)
SCAN_SUPPORTED="true"
if echo "$HEAD_RAW" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if isinstance(d.get('total_tokens'),(int,float)) else 1)" 2>/dev/null; then
  HEAD_JSON="$HEAD_RAW"
else
  SCAN_SUPPORTED="false"
  HEAD_JSON='{"total_tokens":0,"files":[]}'
  echo "::warning::tokenscope scan engine unavailable (requires @wartzar-bee/tokenscope>=0.2.3). Reported cost will be 0 — set the 'tokenscope-version' input to a version with the scan engine."
fi
HEAD_TOKENS=$(echo "$HEAD_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('total_tokens',0))")

# Token counts are interpolated into inline python below, and they come from a JSON document
# produced while scanning a contributor's files. Pin them to integers at the boundary so a
# non-numeric value can never reach a python source string.
[[ "$HEAD_TOKENS" =~ ^[0-9]+$ ]] || HEAD_TOKENS=0
[[ "$THRESHOLD_PCT" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || THRESHOLD_PCT=20
[[ "$PRICE_PER_1M" =~ ^[0-9]+(\.[0-9]+)?$ ]] || PRICE_PER_1M=3.00

# Scan BASE: fetch, stash, checkout base files, scan, restore
git fetch --depth=1 origin "$BASE_REF" 2>/dev/null || true
git stash 2>/dev/null || true
git checkout "origin/$BASE_REF" -- "$WORKING_DIR" 2>/dev/null || true
BASE_JSON=$(scan_json "$WORKING_DIR")
git checkout HEAD -- "$WORKING_DIR" 2>/dev/null || true
git stash pop 2>/dev/null || true

BASE_TOKENS=$(echo "$BASE_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('total_tokens',0))")
[[ "$BASE_TOKENS" =~ ^[0-9]+$ ]] || BASE_TOKENS=0

# Compute delta %
DELTA_PCT=$(python3 -c "
base=int('$BASE_TOKENS'); head=int('$HEAD_TOKENS')
pct = 0.0 if base == 0 else (head - base) / base * 100
print(f'{pct:.1f}')
")

# Convert the token delta into an estimated dollar delta at PRICE_PER_1M.
# This makes the guardrail speak the language teams budget in ($), not just tokens.
USD_LINE=$(PRICE="$PRICE_PER_1M" BT="$BASE_TOKENS" HT="$HEAD_TOKENS" python3 -c "
import os
price = float(os.environ['PRICE'])
base = int(os.environ['BT']); head = int(os.environ['HT'])
bu = base / 1_000_000 * price
hu = head / 1_000_000 * price
du = hu - bu
print(f'{bu:.4f}|{hu:.4f}|{du:.4f}')
" 2>/dev/null || echo "0.0000|0.0000|0.0000")
BASE_USD="${USD_LINE%%|*}"
USD_REST="${USD_LINE#*|}"
HEAD_USD="${USD_REST%%|*}"
DELTA_USD="${USD_REST#*|}"

# Signed, $-prefixed delta for the comment (e.g. +$0.0069 / -$0.0042)
if [[ "$DELTA_USD" == -* ]]; then
  DELTA_USD_SIGNED="-\$${DELTA_USD#-}"
else
  DELTA_USD_SIGNED="+\$${DELTA_USD}"
fi

echo "Base tokens : $BASE_TOKENS"
echo "Head tokens : $HEAD_TOKENS"
echo "Delta       : ${DELTA_PCT}% (${DELTA_USD_SIGNED})"

# Set step outputs
echo "cost-delta-pct=${DELTA_PCT}"     >> "$GITHUB_OUTPUT"
echo "cost-delta-usd=${DELTA_USD}"     >> "$GITHUB_OUTPUT"
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

# Build per-file cost-INCREASE table (base→head delta per path) — the "responsible files".
# This is what makes the comment actionable: it points at the files that grew, not just the big ones.
DELTA_FILES=$(HEAD_JSON="$HEAD_JSON" BASE_JSON="$BASE_JSON" python3 -c "
import os, json
head = json.loads(os.environ.get('HEAD_JSON') or '{}')
base = json.loads(os.environ.get('BASE_JSON') or '{}')
def by_path(d):
    m = {}
    for f in d.get('files', []):
        p = f.get('path')
        if p is not None:
            m[p] = m.get(p, 0) + int(f.get('tokens', 0) or 0)
    return m
h = by_path(head); b = by_path(base)
rows_data = []
for p, ht in h.items():
    bt = b.get(p, 0)
    delta = ht - bt
    if delta > 0:
        rows_data.append((p, bt, ht, delta))
rows_data.sort(key=lambda r: r[3], reverse=True)
rows_data = rows_data[:5]
if not rows_data:
    print('_No file increased in token cost._')
else:
    out = ['| File | Base | Head | Δ |', '|------|-----:|-----:|----:|']
    for p, bt, ht, dt in rows_data:
        tag = ' (new)' if bt == 0 else ''
        out.append(f'| \`{p}\`{tag} | {bt:,} | {ht:,} | **+{dt:,}** |')
    print('\n'.join(out))
" 2>/dev/null || echo "_File delta unavailable._")

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

SCAN_WARN=""
if [[ "$SCAN_SUPPORTED" == "false" ]]; then
  SCAN_WARN="> ⚠️ **tokenscope scan engine unavailable** — the figures below are **not real** (reported as 0). Update \`@wartzar-bee/tokenscope\` to **≥0.2.3**, or set the \`tokenscope-version\` input to a version with the scan engine, to get accurate cost estimates.

"
fi

COMMENT="## ${EMOJI} wartzar-bee Cost Guardrail

${SCAN_WARN}| Metric | Value |
|--------|-------|
| Base branch tokens | ${BASE_FMT} |
| This PR tokens | ${HEAD_FMT} |
| Delta | **${DELTA_PCT}%** (**${DELTA_USD_SIGNED}**) |
| Threshold | ${THRESHOLD_PCT}% |

<sub>💵 Cost estimated at \$${PRICE_PER_1M}/1M tokens — set \`price-per-1m-tokens\` to your model's price for an accurate figure.</sub>

### Biggest cost increases (responsible files)
${DELTA_FILES}

### Top token consumers (HEAD)
${TOP_FILES}${BLOCK_MSG}

<sub>Powered by [wartzar-bee/tokenscope](https://github.com/wartzar-bee/tokenscope) · [cost-guardrail docs](https://github.com/wartzar-bee/ci-guardrail)</sub>"

# Optionally dump the comment body to a file (debugging + local inspection + tests)
if [[ -n "${GUARDRAIL_COMMENT_FILE:-}" ]]; then
  printf '%s' "$COMMENT" > "$GUARDRAIL_COMMENT_FILE"
fi

# Render the same report into the GitHub Actions run summary ($GITHUB_STEP_SUMMARY).
# The runner sets this on EVERY event, so the cost table shows in the Actions UI even
# when there is no PR to comment on (push, workflow_dispatch, schedule) — widening where
# the guardrail's value is visible without depending on a PR context.
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  printf '%s\n' "$COMMENT" >> "$GITHUB_STEP_SUMMARY"
fi

# Resolve the PR number. GitHub does NOT export a GITHUB_EVENT_PULL_REQUEST_NUMBER variable — the
# authoritative source is the event payload at $GITHUB_EVENT_PATH, with refs/pull/<N>/merge as a
# fallback. Relying on the non-existent variable alone meant the comment was NEVER posted on a real
# pull_request run; the action silently reported "not in a PR context" on every PR.
PR_NUMBER="${GITHUB_EVENT_PULL_REQUEST_NUMBER:-${PR_NUMBER:-}}"

if [[ -z "$PR_NUMBER" && -n "${GITHUB_EVENT_PATH:-}" && -f "${GITHUB_EVENT_PATH}" ]]; then
  PR_NUMBER=$(python3 -c "
import json, os, sys
try:
    ev = json.load(open(os.environ['GITHUB_EVENT_PATH']))
except Exception:
    sys.exit(0)
n = (ev.get('pull_request') or {}).get('number')
if n is None:
    # issue_comment on a PR carries the number under .issue with a .pull_request marker
    issue = ev.get('issue') or {}
    if issue.get('pull_request') is not None:
        n = issue.get('number')
print(n if isinstance(n, int) else '')
" 2>/dev/null || true)
fi

# Last resort: on pull_request events GITHUB_REF is refs/pull/<N>/merge
if [[ -z "$PR_NUMBER" && "${GITHUB_REF:-}" =~ ^refs/pull/([0-9]+)/ ]]; then
  PR_NUMBER="${BASH_REMATCH[1]}"
fi

[[ "$PR_NUMBER" =~ ^[0-9]+$ ]] || PR_NUMBER=""

# Post PR comment (idempotent — delete old, post new)
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
