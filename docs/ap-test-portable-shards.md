# Autopilot portable test shards

`bin/ap-test-run.sh` owns portable lane composition and execution.
`bin/ap-test-isolation-proof.sh` owns the proven-isolated candidate set.

## Verification inputs

The current candidate timings came from the 2026-07-29 concurrent proof recorded in [ap-test-isolation-proof.md](ap-test-isolation-proof.md).
The proof ran 24 candidates with four workers and no failures.

| duration_ms | script |
|---:|---|
| 48294 | `tests/ap-backend-herdr.test.sh` |
| 46788 | `tests/ap-arm-pretool-check.test.sh` |
| 34207 | `tests/ap-cd-pretool-check.test.sh` |
| 30771 | `tests/ap-decision-hold-lifecycle.test.sh` |
| 25365 | `tests/ap-flight-crew-state.test.sh` |
| 15674 | `tests/ap-test-run.test.sh` |
| 15422 | `tests/ap-herdr-lab.test.sh` |
| 9065 | `tests/ap-composer-ghost.test.sh` |
| 8564 | `tests/ap-pr-merge.test.sh` |
| 6251 | `tests/ap-grok-harness.test.sh` |
| 5644 | `tests/ap-send-popup-settle.test.sh` |
| 5237 | `tests/ap-lint.test.sh` |
| 4816 | `tests/ap-tmux-submit-busy.test.sh` |
| 2945 | `tests/ap-pi-primary-types.test.sh` |
| 2911 | `tests/ap-send-settle.test.sh` |
| 2875 | `tests/ap-review-diff.test.sh` |
| 2747 | `tests/ap-send-strict.test.sh` |
| 2224 | `tests/ap-brief.test.sh` |
| 855 | `tests/ap-spawn-batch.test.sh` |
| 703 | `tests/ap-supervision-instructions.test.sh` |
| 581 | `tests/ap-ensure-agents-md.test.sh` |
| 248 | `tests/ap-transition-lib.test.sh` |
| 64 | `tests/ap-composer-lib.test.sh` |

## Parallel lanes

The two parallel lanes use longest-processing-time assignment from those measured durations.

| Lane | Script count | Estimated duration |
|---|---:|---:|
| `portable-parallel-1` | 11 | 162436 ms (~162.4 s) |
| `portable-parallel-2` | 13 | 162754 ms (~162.8 s) |
| imbalance | | 318 ms |

`bin/ap-test-run.sh` contains the exact ordered memberships in `list_portable_parallel_1` and `list_portable_parallel_2`.

## Portable serial remainder

`portable-serial` includes every `tests/*.test.sh` that is neither proven-isolated nor `real-herdr-gated`.
It keeps watcher, lock, AFK, real tmux, daemon, copilot lifecycle, bootstrap, live-harness opt-in, GUI-backend, and other unproven work serial.

## Coverage guard

`bin/ap-test-run.sh --check-coverage` verifies that both parallel lanes partition the proven-isolated set.
It also verifies that the parallel lanes, portable serial lane, and real-Herdr family are disjoint and cover every `tests/*.test.sh` script.

## Timing artifacts

Portable shards, the portable serial lane, and the Herdr lane upload runner-generated timing JSON.
`bin/ap-test-run.sh --aggregate-json` creates the combined summary artifact.
`.github/workflows/ci.yml` owns the exact artifact names and aggregation wiring.

## Local entry points

[CONTRIBUTING.md](../CONTRIBUTING.md) owns the local test policy and common entry points.
`bin/ap-test-run.sh --help` owns exact lane names, selection flags, and bounded `--jobs` mechanics.

## Timeouts

| Job | timeout-minutes | Rationale |
|---|---:|---|
| portable parallel 1/2 | 10 | The measured shard sums are about three minutes and the timeout is a hang tripwire. |
| portable serial | 20 | The serial remainder needs a larger hang tripwire. |
| Herdr | 40 | The real-Herdr lane keeps its dedicated timeout. |

Timeouts are hang tripwires rather than expected healthy durations.
