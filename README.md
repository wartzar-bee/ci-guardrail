# wartzar-bee CI Cost Guardrail

[![GitHub Marketplace](https://img.shields.io/badge/Marketplace-CI%20Cost%20Guardrail-blue?logo=github)](https://github.com/marketplace/actions/wartzar-bee-ci-cost-guardrail)
[![npm: tokenscope](https://img.shields.io/npm/dm/@wartzar-bee/tokenscope?label=tokenscope%20installs&color=orange)](https://www.npmjs.com/package/@wartzar-bee/tokenscope)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

> A GitHub Action that predicts a PR's token-cost delta, comments on the responsible lines, and can block the build on a policy.
> Powered by [@wartzar-bee/tokenscope](https://github.com/wartzar-bee/tokenscope).

## Why

Every agent PR is a potential cost regression. This action catches them before they ship:

- **Scans HEAD vs BASE** — estimates total token cost of your agent code on both branches
- **Posts a PR comment** with the delta and the top token consumers (exact files)
- **Blocks the build** if cost increases beyond your threshold (configurable, default 20%)
- **Idempotent** — updates the same comment on each push, no spam

## Quick start

Add this to `.github/workflows/cost-guardrail.yml`:

    name: Cost Guardrail
    on: [pull_request]

    jobs:
      cost-check:
        runs-on: ubuntu-latest
        permissions:
          pull-requests: write   # needed to post the comment
        steps:
          - uses: actions/checkout@v4
            with:
              fetch-depth: 0

          - uses: wartzar-bee/ci-guardrail@v1
            with:
              github-token: ${{ secrets.GITHUB_TOKEN }}
              threshold-pct: 20        # block if tokens grow >20% vs base
              working-directory: .     # where your agent code lives

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `github-token` | yes | — | GitHub token for posting PR comments |
| `threshold-pct` | no | `20` | Block build if token cost grows by more than this %. Set `0` for report-only mode. |
| `base-ref` | no | PR base / `main` | Branch to compare against |
| `working-directory` | no | `.` | Directory containing agent code to analyse |
| `tokenscope-version` | no | `latest` | Pin a specific `@wartzar-bee/tokenscope` version |

## Outputs

| Output | Description |
|--------|-------------|
| `cost-delta-pct` | Token cost change as a percentage (positive = regression) |
| `head-cost-tokens` | Estimated tokens for the PR branch |
| `base-cost-tokens` | Estimated tokens for the base branch |
| `blocked` | `"true"` if the build was blocked |

## Example PR comment

    ## 🚨 wartzar-bee Cost Guardrail

    | Metric          | Value      |
    |-----------------|------------|
    | Base tokens     | 12,400     |
    | This PR tokens  | 16,200     |
    | Delta           | **+30.6%** |
    | Threshold       | 20%        |

    ### Top token consumers (HEAD)
    | File                      | Tokens |
    |---------------------------|--------|
    | src/agent/prompts.ts      | 8,100  |
    | src/agent/context.ts      | 4,200  |
    | src/tools/search.ts       | 3,900  |

    > ⛔ Build blocked — cost regression exceeds the 20% threshold.
    > Reduce prompt size, add caching, or raise the threshold if intentional.

## Report-only mode

Set `threshold-pct: 0` to always post the comment but never block:

    - uses: wartzar-bee/ci-guardrail@v1
      with:
        github-token: ${{ secrets.GITHUB_TOKEN }}
        threshold-pct: 0   # report only, never block

## How it works

1. Runs `tokenscope scan --json` on the HEAD branch
2. Fetches the base branch and runs the same scan
3. Computes the delta percentage
4. Posts (or updates) a PR comment with the breakdown
5. Exits non-zero if delta exceeds `threshold-pct` (and threshold > 0)

## Requirements

- Node.js 20+ (set up automatically by the action)
- `@wartzar-bee/tokenscope` (installed automatically)

## License

MIT — [wartzar-bee](https://github.com/wartzar-bee)
