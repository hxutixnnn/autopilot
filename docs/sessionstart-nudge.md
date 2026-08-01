# Native session-start nudge

AGENTS.md section 3 is the authoritative behavioral contract for session start.
The tracked native adapters inject one instruction and never run the digest, acquire the lock, perform bootstrap work, drain notifications, or arm supervision themselves.
The payload starts with U+2063 and the stable `AUTOPILOT_OP: ` label, carries the current `session-start` protocol kind, and retains exactly ``Run `bin/ap-session-start.sh` now, exactly once, before executing any other instructions.`` as its body.
The Radio check skill owns the rule that this marked operational input is never a pilot-authored session boundary, including its narrow legacy compatibility cases.

## Shared wrapper and safety

`bin/ap-sessionstart-nudge.sh` is the single command every harness adapter invokes.
It sources `bin/ap-gate-refuse-lib.sh` and stays silent for a no-mistakes gate agent identified by `NO_MISTAKES_GATE` or a `.no-mistakes/repos/*.git` git-common-dir.
It shares `bin/ap-primary-scope-lib.sh` with `bin/ap-turnend-guard.sh`, so the hooks use one primary-detection owner.
The Shared Predicate section of [`turnend-guard.md`](turnend-guard.md#shared-predicate) owns marker validation, plain-checkout detection, and required Autopilot-shaped paths.

Before printing, the wrapper reads `state/.lock` and walks at most eight parents from its own pid in its own separate, hard-coded loop, independent of `bin/ap-lock.sh`'s ancestry walk (`ap_harness_ancestry_pid()` in `bin/ap-session-lock-lib.sh`, which now walks up to sixteen parents and can extend past a claude-named match to a still-more-ancestral one) and of Pi's `lockOwnership()`.
If the lock names a live pid in that ancestry, session start already ran in this harness session and the wrapper stays silent.
Every path exits 0, including malformed state and adapter errors, because a Claude SessionStart exit 2 blocks session initialization.

## Harness transports

| Harness | Tracked transport | Current compatibility |
| --- | --- | --- |
| Claude | `.claude/settings.json` registers `SessionStart` for `startup`, `resume`, and `clear`, excludes `compact`, and invokes the wrapper through `CLAUDE_PROJECT_DIR`. | Native stdout context injection is supported. |
| Codex | `.codex/hooks.json` anchors to the hook process working directory, verifies an Autopilot-shaped hook-bearing root, and executes the wrapper. | Native stdout context injection is supported. |
| OpenCode | `.opencode/plugins/ap-primary-sessionstart-nudge.js` listens for `session.created`, runs once per session id, and calls `client.session.promptAsync` only when the wrapper prints a nudge. | Interactive TUI delivery is supported; headless `opencode run` is intentionally fail-open because the process can exit before the queued turn. |
| Pi / pi-signed | `.pi/extensions/ap-primary-turnend-guard.ts` handles `session_start` reasons `startup`, `new`, and `resume`, then injects the wrapper output with `pi.sendMessage`. | The custom message reaches model context without racing an initial positional prompt. |
| Grok | `.grok/hooks/ap-primary-sessionstart-nudge.json` registers a project `SessionStart` hook and invokes the wrapper through inline-defaulted `${GROK_WORKSPACE_ROOT:-}`. | The project hook runs when the checkout is trusted, but Grok currently discards hook stdout from model context, so this path is intentionally fail-open. |

The OpenCode nudge runs only on `session.created`.
The watcher-arm and turn-end plugins run later on `session.idle`, and the guard lets the watcher coordinator act first, so the plugins do not race for one lifecycle event.

Grok's guaranteed-loading alternative is a global token-guarded hook like the pattern used by `bin/ap-spawn.sh`.
That alternative expands trust and writes outside this repository, so Autopilot never installs it or grants folder trust automatically.

## Regression coverage

`tests/ap-sessionstart-nudge.test.sh` proves wrapper silence for both gate signals, an unmarked linked worktree, a missing state directory, and an already-owned lock.
It proves exact U+2063 `AUTOPILOT_OP:`-prefixed, `session-start`-typed one-line output for a plain primary and a marked linked copilot primary.
`tests/ap-pi-primary-live-e2e.test.sh` and `tests/ap-opencode-primary-live-e2e.test.sh` exercise native startup paths with first-message and later-message Radio check regressions.
`tests/ap-turnend-guard.test.sh`, `tests/ap-pi-watch-extension.test.sh`, and `tests/ap-daemon.test.sh` cover marked guard, monitoring, and away-mode delivery.

[`verification/supervision.md`](verification/supervision.md#native-session-start-delivery) records the active version-scoped transport evidence.
