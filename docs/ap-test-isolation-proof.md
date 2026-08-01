# Autopilot test isolation proof

This record is the concurrent isolation proof for the portable parallel candidate set.
`bin/ap-test-isolation-proof.sh` is the authoritative harness and `docs/ap-test-isolation-proof.json` is the machine-readable result.
`bin/ap-test-run.sh` owns the production lane partition.

## Verification

- Date: 2026-07-29
- Command: `bin/ap-test-isolation-proof.sh --jobs 4 --json /tmp/ap-source-content-test-cleanup-r1-isolation.json`
- Result: `AP_ISOLATION_SUMMARY total=24 failed=0 concurrency=4 duration_ms=149010`

| Field | Value |
|---|---|
| `run_id` | `ap-isolation-1785367157179-18165` |
| `started_at` | `2026-07-29T23:19:17Z` |
| `finished_at` | `2026-07-29T23:21:46Z` |
| concurrency | 4 |
| candidates | 24 |
| failed | 0 |
| wall duration | 149010 ms |

## Candidate set

- `tests/ap-arm-pretool-check.test.sh`
- `tests/ap-backend-herdr.test.sh`
- `tests/ap-brief.test.sh`
- `tests/ap-cd-pretool-check.test.sh`
- `tests/ap-composer-ghost.test.sh`
- `tests/ap-composer-lib.test.sh`
- `tests/ap-flight-crew-state.test.sh`
- `tests/ap-decision-hold-lifecycle.test.sh`
- `tests/ap-ensure-agents-md.test.sh`
- `tests/ap-grok-harness.test.sh`
- `tests/ap-herdr-lab.test.sh`
- `tests/ap-lint.test.sh`
- `tests/ap-pi-primary-types.test.sh`
- `tests/ap-pr-merge.test.sh`
- `tests/ap-review-diff.test.sh`
- `tests/ap-send-popup-settle.test.sh`
- `tests/ap-send-settle.test.sh`
- `tests/ap-send-strict.test.sh`
- `tests/ap-spawn-batch.test.sh`
- `tests/ap-supervision-instructions.test.sh`
- `tests/ap-test-run.test.sh`
- `tests/ap-tmux-submit-busy.test.sh`
- `tests/ap-transition-lib.test.sh`

## Durations

| duration_ms | exit | worker | script |
|---:|---:|---:|---|
| 48294 | 0 | 2 | `tests/ap-backend-herdr.test.sh` |
| 46788 | 0 | 1 | `tests/ap-arm-pretool-check.test.sh` |
| 34207 | 0 | 4 | `tests/ap-cd-pretool-check.test.sh` |
| 30771 | 0 | 8 | `tests/ap-decision-hold-lifecycle.test.sh` |
| 25365 | 0 | 7 | `tests/ap-flight-crew-state.test.sh` |
| 15674 | 0 | 21 | `tests/ap-test-run.test.sh` |
| 15422 | 0 | 11 | `tests/ap-herdr-lab.test.sh` |
| 9065 | 0 | 5 | `tests/ap-composer-ghost.test.sh` |
| 8564 | 0 | 14 | `tests/ap-pr-merge.test.sh` |
| 6251 | 0 | 10 | `tests/ap-grok-harness.test.sh` |
| 5644 | 0 | 16 | `tests/ap-send-popup-settle.test.sh` |
| 5237 | 0 | 12 | `tests/ap-lint.test.sh` |
| 4816 | 0 | 22 | `tests/ap-tmux-submit-busy.test.sh` |
| 2945 | 0 | 13 | `tests/ap-pi-primary-types.test.sh` |
| 2911 | 0 | 17 | `tests/ap-send-settle.test.sh` |
| 2875 | 0 | 15 | `tests/ap-review-diff.test.sh` |
| 2747 | 0 | 18 | `tests/ap-send-strict.test.sh` |
| 2224 | 0 | 3 | `tests/ap-brief.test.sh` |
| 855 | 0 | 19 | `tests/ap-spawn-batch.test.sh` |
| 703 | 0 | 20 | `tests/ap-supervision-instructions.test.sh` |
| 581 | 0 | 9 | `tests/ap-ensure-agents-md.test.sh` |
| 248 | 0 | 23 | `tests/ap-transition-lib.test.sh` |
| 64 | 0 | 6 | `tests/ap-composer-lib.test.sh` |

## Scope

Each worker used a separate mode-`0700` temporary root and private `TMPDIR` and `TMP`.
The harness cleared ambient `AP_HOME` and `AP_*_OVERRIDE` values for every worker and verified that global Git configuration was unchanged.
A candidate failure fails the aggregate run and requires investigation rather than a retry.

## Re-run

```sh
bin/ap-test-isolation-proof.sh --list
bin/ap-test-isolation-proof.sh --jobs 4 --json /tmp/ap-isolation-proof.json
bin/ap-test-run.sh --check-coverage
```
