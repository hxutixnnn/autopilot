# The bin/ toolbelt

The autopilot drives these; interactive entrypoints work by hand too, while `*-lib.sh` files are sourced helpers.
Each row is one purpose clause only: the script's own header comment is the authoritative description of its behavior, flags, and contracts, so read the header before first use.
If you have changed away from the autopilot home in an interactive shell, invoke these scripts by absolute path through the repo's `bin/` directory; the scripts self-locate internally after they start.
The shared no-mistakes gate refusal for fleet lifecycle entrypoints is summarized in [architecture.md](architecture.md#no-mistakes-gate-authority-boundary), while `docs/sessionstart-nudge.md` covers the silent hook-nudge use; `ap-gate-refuse-lib.sh`'s header owns its exact contract.

| Script                   | Purpose                                                                              |
| ------------------------ | ------------------------------------------------------------------------------------ |
| `ap-session-start.sh`    | Compose lock, bootstrap, and wake drain into the single ordered session-start digest |
| `ap-sessionstart-nudge.sh` | Print the native session-start hook nudge when the primary has not already run the digest |
| `ap-operational-input.sh` | Construct and parse the canonical cross-language operational-input protocol |
| `ap-bootstrap.sh`        | Detect toolchain and fleet problems, run the locked session-start sweeps, and install approved tools |
| `ap-fleet-sync.sh`       | Refresh project clones with safe fast-forwards, self-heals, `STUCK:` reports, branch pruning, and bounded recovery from an orphaned `.git/packed-refs.lock` |
| `ap-fleet-snapshot.sh`   | Print the read-only structured fleet snapshot JSON (schema `ap-fleet-snapshot.v1`)   |
| `ap-fleet-view.sh`       | Render the fleet snapshot as a human Markdown view                                   |
| `ap-bearings-snapshot.sh` | Project the fleet snapshot to the compact TOON bearings view; local-only unless `--include-prs` |
| `ap-update.sh`           | Fast-forward-only self-update of autopilot and copilot homes from origin          |
| `ap-backlog-handoff.sh`  | Validate and delegate queued backlog-item moves into a copilot home               |
| `ap-decision-hold.sh`    | Create, verify, complete, and resolve durable pilot-held decisions                 |
| `ap-brief.sh`            | Scaffold flight, recon, copilot-charter, and Herdr-lab briefs                       |
| `ap-herdr-lab.sh`        | Provision and guardedly operate an isolated, never-default Herdr lab session         |
| `ap-install-herdr.sh`    | Install CI's exact-version Herdr pin with official asset URL, SHA-256, and protocol checks |
| `ap-install-treehouse.sh`| Install CI's exact-version Treehouse pin for real-Herdr E2E that needs spawn worktrees |
| `ap-herdr-ci-cleanup.sh` | Snapshot and tear down only job-owned `ap-lab-*` sessions in the Herdr CI lane       |
| `ap-test-run.sh`         | Behavior-test runner: selection, portable lanes, proven-isolated `--jobs`, coverage guard, timing/JSON |
| `ap-test-isolation-proof.sh` | Concurrent isolation proof and proven-isolated candidate set owner |
| `ap-ensure-agents-md.sh` | Ensure a project's real `AGENTS.md`, its `CLAUDE.md` symlink, and the canonical self-governance section |
| `ap-guard.sh`            | Warn on primary-checkout tangles, pending queued wakes, and stale watcher liveness   |
| `ap-primary-scope-lib.sh` | Shared marker-or-plain-checkout primary-home predicate for tracked hooks             |
| `ap-session-lock-lib.sh` | Shared session-lock harness identity (ancestry walk and holder liveness) for ap-lock.sh and the Claude Stop auto-arm |
| `ap-claude-stop-autoarm.sh` | Claude Stop `asyncRewake` hook owning tokenless watcher continuity with single-flight exit-2 rewake (docs/watcher-continuity.md) |
| `ap-turnend-guard.sh`    | Shared primary turn-end guard predicate so no turn ends blind (docs/turnend-guard.md) |
| `ap-turnend-guard-grok.sh` | Grok Stop-hook adapter for the primary turn-end guard                              |
| `ap-kimi-turnend-hook.sh` | Surgically install or remove Kimi's guarded global flight crew turn-end hook                |
| `ap-arm-pretool-check.sh` | Stable PreToolUse transport for the watcher-arm command policy (docs/arm-pretool-check.md) |
| `ap-arm-command-policy.mjs` | Semantic owner of the watcher-arm PreToolUse policy (docs/arm-pretool-check.md)   |
| `ap-subagent-pretool-check.sh` | Primary-home delegation-shape PreToolUse guard (docs/subagent-guard.md) |
| `ap-supervision-instructions.sh` | Render the session-start primary-harness supervision block or the one-line repair instruction |
| `ap-home-seed.sh`        | Transactionally provision a copilot home and maintain `data/copilots.md`       |
| `ap-spawn.sh`            | Spawn flight crew members, recon tasks, `id=repo` batches, and copilots on the resolved harness and runtime backend |
| `ap-backend.sh`          | Runtime-backend selection, meta helpers, selector resolution, and operation dispatch |
| `ap-backend-hometag-lib.sh` | Shared per-installation home-tag derivation for zellij tab and cmux workspace titles |
| `ap-composer-lib.sh`     | Single fleet-wide owner of composer-content classification for all backends          |
| `backends/tmux.sh`       | Verified tmux session-provider adapter                                               |
| `backends/herdr.sh`      | Experimental herdr session-provider adapter                                          |
| `backends/zellij.sh`     | Experimental zellij session-provider adapter                                         |
| `backends/orca.sh`       | Experimental Orca backend adapter owning both worktree and terminal                  |
| `backends/cmux.sh`       | Experimental cmux session-provider adapter                                           |
| `ap-config-push.sh`      | Push declared inherited local material to live copilots mid-session and send a pointer to the literal-content config reread when config changed |
| `ap-project-mode.sh`     | Resolve a project's delivery mode and `+yolo` flag from `data/projects.md`           |
| `ap-merge-local.sh`      | Fast-forward a `local-only` project's local default branch after approval            |
| `ap-review-diff.sh`      | Review a flight crew member branch or resolved PR head against the authoritative base          |
| `ap-marker-lib.sh`       | Compatibility entry point for the from-autopilot carrier owned by `ap-operational-input.sh` |
| `ap-pending-reply-lib.sh` | Parent-owned copilot pending-reply expectations, recovery, and one-shot escalation |
| `ap-copilot-report.sh` | Optional helper to append a correlated parent status or document-pointer report       |
| `ap-gate-refuse-lib.sh`  | Shared no-mistakes gate-context refusal for fleet lifecycle entrypoints               |
| `ap-watch-arm.sh`        | Verified home-scoped watcher arm wrapper with loud cycle endings and bounded lifecycle ledger |
| `ap-watch-checkpoint.sh` | Run one bounded foreground watcher checkpoint for Codex-style supervision            |
| `ap-watch.sh`            | Singleton-safe always-on watcher: absorb benign wakes, queue and exit on actionable ones |
| `ap-afk-start.sh`        | Run the common sourceable away-mode daemon entry in the foreground                      |
| `ap-afk-launch.sh`       | Own away-mode entry, exit, rollback, and any backend terminal lifecycle                 |
| `ap-afk-return.sh`       | Own deterministic return shutdown, catch-up evidence, and the autopilot-actionable blocker gate |
| `ap-supervisor-target-lib.sh` | Resolve the shared supervisor target and backend for the daemon and launcher       |
| `ap-supervise-daemon.sh` | Presence-gated away-mode sub-supervisor: self-handle routine wakes, guard injection by the detected primary harness, escalate batched digests, alert on failed delivery |
| `ap-flight-crew-state.sh`       | Print one deterministic current-state line for a flight crew                                |
| `ap-tangle-lib.sh`       | Shared default-branch resolution and primary-checkout tangle classification          |
| `ap-supervision-lib.sh`  | Shared in-flight-work-without-fresh-watcher-beacon predicate                         |
| `ap-ff-lib.sh`           | Shared guarded fast-forward helper for origin pulls and local copilot syncs       |
| `ap-lock-lib.sh`         | Shared "is this git lock provably abandoned?" proof used by teardown and fleet-sync   |
| `ap-config-inherit-lib.sh` | Shared primary-to-copilot inherited local-material propagation and config-reread delivery |
| `ap-tasks-axi-lib.sh`    | Shared backlog-backend selector and `tasks-axi` compatibility probe                  |
| `ap-quota-axi-lib.sh`    | Shared `quota-axi` compatibility floor for the bootstrap diagnostic                  |
| `ap-vendor-auth-probe.sh`| Run one hard-bounded, non-destructive authentication probe of a named vendor CLI and report the fact |
| `ap-wake-drain.sh`       | Atomically drain queued watcher wakes, emit bounded best-effort status-event annotations, then assert watcher liveness |
| `ap-wake-lib.sh`         | Shared durable wake queue, portable locks, and watcher identity/health helpers       |
| `ap-classify-lib.sh`     | Shared pilot-relevant and declared-external-wait wake classification vocabulary    |
| `ap-send.sh`             | Send one verified literal line or supported key through the target's recorded backend |
| `ap-busy-lib.sh`         | Single owner of the semantic busy-state contract: verdicts, source attribution, and per-harness sources |
| `ap-busy-event.sh`       | The only writer of a task's semantic busy-state record; arms an incarnation and applies lifecycle events |
| `ap-tmux-lib.sh`         | Shared tmux pane primitives for composer capture, verified submit, and the submit-time busy check |
| `ap-peek.sh`             | Print a bounded tail of a flight crew member endpoint                                          |
| `ap-check-register.sh`   | Bind an intentional custom watcher check to its current bytes                       |
| `ap-check-lib.sh`        | Validate custom-check registrations and prepare private execution snapshots          |
| `ap-pr-lib.sh`           | Own canonical task and PR validation plus private atomic PR-poll publication and identity-bound retirement |
| `ap-pr-poll.sh`          | Provide the byte-static watcher program for validated PR/MR-poll sidecars           |
| `ap-pr-check-migrate.sh` | Quarantine older task polls without execution and rebuild only canonical polls       |
| `ap-pr-check.sh`         | Record validated `pr=` and `pr_head=` values, then atomically arm a static merge poll |
| `ap-pr-merge.sh`         | Record PR metadata, then merge a task's canonical full GitHub URL                    |
| `ap-promote.sh`          | Promote a recon task in place to a protected flight task                               |
| `ap-teardown.sh`         | Fail-closed teardown: return landed flight worktrees, require completed recon deliverables, retire copilot homes |
| `ap-harness.sh`          | Detect the running harness and resolve flight crew or copilot harness, model, and effort |
| `ap-lock.sh`             | Per-home autopilot session lock                                                      |
