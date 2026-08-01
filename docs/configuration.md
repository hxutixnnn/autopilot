# Configuration

The files and environment variables you set to operate autopilot.

## Orchestrator behavior (AGENTS.md)

The shared orchestrator behavior lives in [`AGENTS.md`](../AGENTS.md) - edit it like any prompt when the fleet is empty, or dispatch shared-repo edits to a flight crew member while tasks are in flight.

## Operational home layout and state

This section is the single owner of the top-level operational-home layout; producer script headers and their help own exact child-file fields and mutation contracts.
The tracked code root contains the shared instruction, skill, documentation, workflow, and `bin/` surfaces, while each effective `AP_HOME` contains private operational directories.
`data/` holds durable private fleet records such as the project and copilot registries, pilot preferences, optional shared pilot preferences, learnings, backlog, briefs, and recon reports.
`config/` holds local gitignored operating choices, and `projects/` holds the local project clones that Autopilot reads but changes only through the narrow guarded and concrete pilot-approved exceptions in `AGENTS.md`.

`bin/ap-spawn.sh` owns the base task-metadata fields it emits, while the runtime-backend section below owns backend-specific fields and selector interpretation.
The producing PR helpers own the fields they append, `bin/ap-classify-lib.sh` owns status-event vocabulary, and `bin/ap-flight-crew-state.sh` owns current-state reconciliation.
Wake, watcher, and away-mode state mechanics remain with their named scripts and reference sections rather than being duplicated into one exhaustive state tree here.

`bin/ap-session-start.sh`'s header is the single owner of session-start ordering, composed commands, digest contents, and the digest's startup mechanism.
`docs/sessionstart-nudge.md` owns the native session-open adapter mechanics that nudge the digest command.
`AGENTS.md` retains the run-once and read-once operator rules, lock-refusal safety, installation consent, and direct-report recovery boundaries because those facts apply at every session start.
Ordinary dead-direct-report recovery is owned by `stuck-flight-crew-recovery`, while persistent-copilot recovery is owned by `copilot-provisioning`.

## Pi Calm preference (config/calm)

The Pi Calm extension stores the pilot's home-local presentation choice in gitignored `config/calm` under the effective Autopilot home, resolved from `AP_HOME`, then `AP_ROOT_OVERRIDE`, then the tracked code root derived from the extension path, or under `AP_CONFIG_OVERRIDE` when that test and specialized-setup override is present.
The only values it writes are `on` and `off`, each followed by one newline; an absent, unreadable, or unrecognized value defaults to off.
The `/calm` command replaces the file atomically before changing live presentation, so a failed write leaves the current choice unchanged rather than claiming persistence.
The extension reloads this preference on every Pi `session_start`, including startup, new, resume, fork, and reload reasons.
This preference is local to each Autopilot home and is not part of copilot inherited configuration.

## Backlog backend (.tasks.toml / config/backlog-backend)

The tracked `.tasks.toml` pins the default `tasks-axi` markdown backend to `data/backlog.md`, with `done_keep = 10` and an archive at `data/done-archive.md`.
When the default backend is selected and compatible `tasks-axi` is on `PATH`, autopilot uses its verbs for routine backlog mutations.
Copilot handoffs are separate and unconditional: `ap-backlog-handoff.sh` keeps only its own fleet-level validation and always delegates the item move to `tasks-axi mv`, the single owner of the backlog format.
It moves in-scope `## Queued` items only and refuses `## In flight` and historical `## Done` records, which stay with their home for pruning or archiving.
Handoff item bodies must use at least two leading spaces, and the helper refuses a selected item with a single-space or tab-indented continuation rather than risk orphaning it.
Because bootstrap requires `tasks-axi` on `PATH` on every profile, that delegation works fleet-wide, and the `config/backlog-backend=manual` knob governs autopilot's own hand-editing of its backlog, not this validated helper.
Compatible means the shared bootstrap probe accepts `tasks-axi --version` as 0.1.1 or newer, `tasks-axi update --help` exposes `--archive-body`, and `tasks-axi mv --help` exposes `[<id>...]` for the atomic multi-ID move introduced in 0.2.2 and required by handoff delegation.
That sentence is the single owner of the tasks-axi compatibility definition; every other document points here instead of restating the version gates.
Bootstrap requires compatible `tasks-axi` on every profile; see "Toolchain" below for missing-tool reporting and silent default-backend behavior.
Set the local, gitignored `config/backlog-backend` file to `manual` to force manual backlog editing and suppress the verbose `BOOTSTRAP_INFO: tasks-axi available` fact, not missing-tool reporting.
Absent or `tasks-axi` selects the default tasks-axi backend.
The file format is unchanged in both modes; tasks-axi and manual edits produce the same `## In flight`, `## Queued`, and `## Done` sections.

## Runtime backend (config/backend / AP_BACKEND)

For spawn-capable adapters, the runtime session-provider backend controls where task windows/endpoints are created, captured, sent to, watched, and killed.
`tmux` is the verified reference backend (see [`docs/tmux-backend.md`](tmux-backend.md)); `herdr`, `zellij`, `orca`, and `cmux` are experimental spawn backends (see [`docs/herdr-backend.md`](herdr-backend.md), [`docs/zellij-backend.md`](zellij-backend.md), [`docs/orca-backend.md`](orca-backend.md), and [`docs/cmux-backend.md`](cmux-backend.md)).
Treehouse remains the worktree provider for tmux, herdr, zellij, and cmux, since herdr, zellij, and cmux are session providers only; Orca provides both the task worktree and terminal endpoint.
New spawns choose the backend in this order: an explicit `--backend` flag autopilot passes when it spawns a task, then `AP_BACKEND`, then the first non-empty line of local gitignored `config/backend`, then runtime auto-detection from `$TMUX`, `HERDR_ENV=1`, or cmux runtime signals, then default `tmux`.
If more than one runtime marker is present, detection resolves innermost-first: `$TMUX` is checked before `HERDR_ENV=1`, which is checked before cmux's primary `CMUX_WORKSPACE_ID` marker and its documented fallback signals - tmux or herdr started from inside a cmux terminal is the innermost, currently-executing layer, while cmux itself (a terminal application, not a nestable multiplexer) is always checked last.
See [`docs/cmux-backend.md`](cmux-backend.md#runtime-detection) for why cmux can be selected when `CMUX_WORKSPACE_ID` is absent.
Auto-detected herdr or cmux prints a stderr notice naming `config/backend` and `--backend tmux` as opt-outs; auto-detected tmux stays silent to preserve existing default behavior.
Zellij and Orca are never auto-detected; select them by putting the name in a local `config/backend` file, by exporting `AP_BACKEND=<name>`, or by telling the autopilot in chat.
Any value other than `tmux`, `herdr`, `zellij`, `orca`, or `cmux` is rejected until another adapter is implemented and verified.
`ap-spawn.sh` accepts `tmux`, `herdr`, `zellij`, `orca`, and `cmux` for flight and recon tasks; `backend=orca` and `backend=cmux` both still refuse `--copilot` until copilot launch semantics are designed for each.
`codex-app` is not an accepted runtime backend yet; [`docs/codex-app-backend.md`](codex-app-backend.md) owns the Codex App boundary.
The session-start copilot liveness sweep uses the recovery-grade `ap_backend_agent_state` classifier where verified.
The comment above that function in `bin/ap-backend.sh` is the single owner of its detailed state contract and recovery authorization.
The compatibility helper `ap_backend_agent_alive` continues to collapse those detailed results to `alive`, `dead`, or `unknown` for older callers.
A herdr spawn additionally version-gates against the installed `herdr` binary's protocol and requires `jq`, refusing loudly on an incompatible or missing installation.
A zellij spawn additionally version-gates against the installed `zellij` binary's version and requires `jq`, refusing loudly when either is missing or the version is older than 0.44.
A cmux spawn additionally version-gates against the installed `cmux` binary's version, requires `jq`, and requires the control socket to be reachable and accessible (see [`docs/cmux-backend.md`](cmux-backend.md) "Setup" for the one-time socket-access configuration this needs; Automation mode is the recommended socket control mode, with Password mode supported via `config/cmux-socket-password`), refusing loudly and non-retryably on a `cmuxOnly`/unauthenticated socket.
A backend spawn refusal from a missing dependency, version gate, or unauthenticated socket is terminal for that selected backend; autopilot surfaces it as a blocker instead of silently retrying another backend.
Task meta records `backend=` only for a non-default backend; an absent `backend=` means `tmux`, preserving existing default-path meta files.
Every new task records `endpoint_task_id=` as the cleanup binding between the metadata filename and its opaque runtime endpoint.
A herdr task additionally records `herdr_session=`, `herdr_workspace_id=`, `herdr_tab_id=`, and `herdr_pane_id=`.
A zellij task additionally records `zellij_session=`, `zellij_tab_id=`, and `zellij_pane_id=`.
An Orca task additionally records `orca_worktree_id=` and `terminal=`, with `window=ap-<id>` kept as the shared autopilot alias.
A cmux task additionally records `cmux_workspace_id=` and `cmux_surface_id=`.
Task selectors for `ap-peek.sh`, `ap-send.sh`, and `ap-flight-crew-state.sh` resolve centrally through `ap_backend_resolve_selector`.
A selector containing `:` is passed through as an explicit backend endpoint escape hatch.
Otherwise an exact task id matching `state/<id>.meta` wins before the legacy `ap-<id>` label fallback, so task ids that themselves start with `ap-` route to their own metadata instead of being stripped.
A metadata-routed selector returns the recorded backend target (`terminal=` for Orca, otherwise `window=`), and matching explicit targets can still recover the recorded backend when metadata contains the same endpoint.
Only metadata-routed task selectors carry copilot-marker and Codex-harness context; explicit endpoint escape hatches do not.
These five sentences are the single owner of the task-selector vocabulary; backend guides and other documents point here instead of restating the resolution order.
`ap-teardown.sh <id>` takes a task id directly and validates the complete metadata-only endpoint identity before any runtime dispatch or cleanup mutation.
Missing, empty, duplicate, malformed, backend-inconsistent, or task-mismatched endpoint records are preserved and refused.
Legacy tmux metadata remains cleanup-compatible when its exact window name is `ap-<id>`; opaque non-tmux endpoints require their recorded `endpoint_task_id=` binding.
`AP_HOME` determines Herdr's home label: the primary home uses `autopilot`, and a copilot home marked by `.ap-copilot-home` uses `copilot-<copilot-id>`.
[`herdr-backend.md`](herdr-backend.md#watching-and-task-containers) owns launcher-bound workspace placement, the label-only fallback, collision handling, and recovery behavior.
The optional local `config/herdr-presentation-spaces` presence flag instead enables Herdr's default-off disposable single-task visual projection; [Optional presentation spaces](herdr-backend.md#optional-presentation-spaces) owns its behavior, safety limits, recovery contract, and narrow locked session-start cleanup of exact restored idle-shell children.
The flag is default-off and inherited into copilot homes under the primary-authoritative contract owned by [`copilot-provisioning`](../.agents/skills/copilot-provisioning/SKILL.md).
For normal herdr operations, `HERDR_SESSION` selects the named session, but destructive test cleanup must not rely on `HERDR_SESSION` alone.
Use the explicit guarded cleanup path described in [`docs/herdr-backend.md`](herdr-backend.md) instead of `herdr server stop`.
For normal zellij operations, `AP_ZELLIJ_SESSION` selects the named session and defaults to `autopilot`.
Zellij has no per-home workspace split: primary and copilot tasks share that one session, and visible tab titles are scoped by the active `AP_HOME` readable label plus a short hash of the resolved `AP_ROOT` path as `ap-<home-label>-<id>`.
Use the guarded cleanup path described in [`docs/zellij-backend.md`](zellij-backend.md) instead of `kill-all-sessions` or `delete-all-sessions`.
cmux has no session layer at all - one workspace per task, in whatever cmux window is open - and its socket password (when configured) is read from local, gitignored `config/cmux-socket-password` under the effective config directory, never committed.
The caller-facing label remains `ap-<id>`, but the actual cmux workspace title is scoped by the active `AP_HOME` readable label plus a short hash of the resolved `AP_ROOT` path as `ap-<home-label>-<id>`.
Test cleanup must use the guarded path in [`docs/cmux-backend.md`](cmux-backend.md#current-operation-and-safety), never enumerate-and-close every workspace.
`config/backend` is inherited into copilot homes under the primary-authoritative contract owned by [`copilot-provisioning`](../.agents/skills/copilot-provisioning/SKILL.md).

## Away-mode supervisor backend (AP_SUPERVISOR_BACKEND / AP_SUPERVISOR_TARGET)

The `/afk` sub-supervisor injects escalation digests into autopilot's own pane independently of where new task endpoints are spawned.
It currently supports only `tmux` and `herdr` supervisor panes.
Set `AP_SUPERVISOR_BACKEND=tmux|herdr` and `AP_SUPERVISOR_TARGET=<target>` to override both axes explicitly; for herdr the target is `"<session>:<pane-id>"`.
Without overrides, backend detection uses `$TMUX_PANE` first, then `HERDR_ENV=1` with `HERDR_PANE_ID`, then falls back to `tmux`.
That keeps a tmux pane nested inside herdr on the tmux transport, matching the runtime backend's innermost-first rule.
Target detection uses `AP_SUPERVISOR_TARGET`, then `$TMUX_PANE`, then `"${HERDR_SESSION:-default}:${HERDR_PANE_ID}"` under herdr, then the legacy `autopilot:0` tmux fallback with a warning.
Selecting any other supervisor backend, including `zellij`, `orca`, or `cmux`, refuses at daemon startup instead of trying tmux injection primitives against a non-tmux pane.

## Away-mode wedge alarm channels (config/wedge-alarm)

When away-mode injection wedges past `AP_MAX_DEFER_SECS`, the sub-supervisor raises a loud, rate-limited alarm.
Beyond the durable `state/.subsuper-inject-wedged` marker and the tmux status-line flash, it attempts a configured backend-independent active alert that can reach the pilot even when every pane and its backend status-line is unreadable.
`config/wedge-alarm` (local, gitignored) lists channel directives, one per non-empty, non-comment line; every listed non-`off` channel fires, best-effort.
`AP_WEDGE_ALARM_CHANNEL` overrides the file with a single directive.
Directives are `off` (a position-independent kill switch that disables every active alert), `auto`/`default`, `osascript` (macOS Notification Center banner), `herdr` (herdr UI notification), and `command:<cmd>` (run `<cmd>` via `sh -c`, summary on `$1` and stdin).
An absent file means `auto`, i.e. default-on on macOS: the alarm exists precisely so a wedged away-mode primary is never silent, and it fires at most once per max-defer window after a genuine wedge.
A missing or failing channel logs and falls through to the next, never crashing the daemon.
See [`wedge-alarm.md`](wedge-alarm.md) for the current channel reference, [`verification/supervision.md`](verification/supervision.md#wedge-alarm-channels) for active evidence, and [`examples/wedge-alarm`](examples/wedge-alarm) for a copyable config.

## Gate defaults (.no-mistakes.yaml)

The tracked `.no-mistakes.yaml` keeps test evidence outside the repo and pins `commands.lint` to `bin/ap-lint.sh` so local lint matches CI.
That evidence policy is specific to the autopilot repo: target projects may legitimately commit `.no-mistakes/evidence/` from their own no-mistakes pipeline, but autopilot keeps `.no-mistakes/` local and CI rejects tracked entries under that path.
It does not set `commands.test` to a complete `tests/*.test.sh` walk.
See [CONTRIBUTING.md](../CONTRIBUTING.md) for the autopilot-specific local test policy and entry points.
Portable shard evidence and coverage rules are in [ap-test-portable-shards.md](ap-test-portable-shards.md); [herdr-backend.md](herdr-backend.md#destructive-lab-safety) owns the real-Herdr lane's isolation boundary, and [runtime-backends.md](verification/runtime-backends.md#herdr) owns active evidence.

## Pilot Preferences (data/pilot.md / data/pilot-shared.md)

Domain-local preferences for one pilot's fleet live locally in each home's `data/pilot.md`; it is gitignored and printed in the session-start context digest after `data/projects.md` and optional `data/copilots.md`.
Before changing it, inspect the current file and rewrite or prune the matching bullet in place; add a new bullet only for a genuinely new durable preference.
Shared pilot preferences that apply across copilot domains live only in the primary home's optional `data/pilot-shared.md`.
`copilot-provisioning` owns its propagation contract, including the required header, read-only copilot copies, quarantine diagnostics, and the rollout rule that existing homes trim `data/pilot.md` by hand after first propagation rather than deleting private content automatically.

## Operational learnings (data/learnings.md)

Fleet-local operational facts and gotchas live locally in `data/learnings.md`; it is gitignored and printed after the pilot-preference files in the session-start context digest.
The file is created lazily on first learning and follows the same dated, evidence-backed, curated style as `data/pilot.md`: inspect the current file first, then rewrite or prune stale entries instead of appending forever.
There is no shared learnings file by pilot decision.

## Startup memory budget (config/startup-memory-budget)

`config/startup-memory-budget` is the primary-authoritative per-home allowance for the startup prompt-memory surface: `data/pilot.md`, `data/pilot-shared.md`, and `data/learnings.md` together.
The locked mutable bootstrap path materializes its visible default of `7500` estimated tokens in a primary home when the file is absent.
To select another allowance, replace the primary home's file with one valid positive value in the exact format below; the next locked bootstrap convergence or `bin/ap-config-push.sh` propagates it to registered copilots.
A copilot does not create an independent default and instead receives the primary value through the inherited-local-material contract in [`copilot-provisioning`](../.agents/skills/copilot-provisioning/SKILL.md).
The file must be one positive base-10 integer followed by exactly one newline in a regular, single-linked file beneath a non-symlinked `config/` directory.
Malformed, multi-line, symlinked, hardlinked, special, or otherwise unsafe values are rejected rather than treated as a default.
Use `bin/ap-startup-memory-budget.sh read` to validate and print the effective value, or `bin/ap-startup-memory-budget.sh report` to account for the three files.
The stable local estimate is `ceil(UTF-8 bytes / 3)` per file, a conservative portable approximation rather than a provider-exact tokenizer.
An inherited `data/pilot-shared.md` counts in a copilot's total but remains primary-owned and read-only there.
The internal `/stow` skill curates only the editable local files in that case and reports the primary-owned shared file as a concrete exception if it alone exceeds the budget.
The helper's header owns exact parsing, publication, and report output mechanics.

## Copilot routes (data/copilots.md)

Persistent copilot routes live locally in `data/copilots.md`.
The concise single-line route contract is owned by the [`copilot-provisioning` skill](../.agents/skills/copilot-provisioning/SKILL.md#routing-table), including the parser-compatible fields, one-sentence summary requirement, `home:` pointer to the seeded charter, and limit on extra registry prose.
`ap-home-seed.sh validate` refuses duplicate ids, duplicate homes, and nested or overlapping homes.
The main autopilot routes by reading those scopes with judgment; the project list is provisioning data, not exclusive ownership.
Use `ap-home-seed.sh <id> - {<project>...|--no-projects}` to lease a fresh autopilot worktree for the copilot home.
Use the deliberate `--no-projects` signal only for an autopilot-repo domain that needs no separate project clones.
It cannot be combined with a project list, and omitting both still fails loudly.
A project-less seed requires no existing project clones or `data/projects.md` entries in the home, so it refuses a populated-home conversion without changing that home.
A preexisting project-bearing charter is also refused until it is re-scaffolded with `--no-projects` or removed.
The lease is held under the copilot id until explicit retirement or seed rollback returns it, so normal restarts do not free or recycle the home.
Teardown of a leased home fails closed if `treehouse return` cannot release the lease; plain-clone homes with no treehouse pool slot are removed directly.
Copilot routes cover `no-mistakes` and `direct-PR` projects; `local-only` projects remain main-autopilot work.
For `no-mistakes` projects, seeding initializes only projects newly cloned into a copilot home and refuses to mutate a preexisting clone that is not already initialized.
After creating a copilot, move existing main-backlog queued items that you have judged in-scope with `ap-backlog-handoff.sh <copilot-id> <item-key>...`; it is idempotent and refuses In flight, Done, or non-copilot homes.
Set `AP_COPILOT_CHARTER` to seed from inline charter text when no filled charter brief exists; set `AP_COPILOT_SCOPE` when the routing scope should differ from the charter text.
The seeded home's `data/charter.md` owns the standard copilot lifecycle and escalation contract; the route file points to it through the existing `home:` field instead of adding another pointer.
Each seed writes an `.ap-copilot-home` identity marker at the home root.
The tracked root `.gitignore` ignores that marker, so validation can read it without making a freshly seeded home appear dirty to porcelain-based safety checks.
This does not relax protection for any other untracked file.
An existing linked-worktree home that predates this rule advances through its marker-only state during its next bootstrap or spawn local sync, after which Git ignores the marker normally.
A standalone-clone home cannot receive a primary-local commit through that no-fetch sync, so it receives the rule through `/updateautopilot`'s origin refresh instead.

## AP_HOME

`AP_HOME` selects the operational home for one autopilot instance.
When it is unset, most scripts use the repo root as the home; when it is set, scripts still run from this repo's `bin/`, but `state/`, `data/`, `config/`, and `projects/` come from `$AP_HOME`.
`AP_ROOT_OVERRIDE` overrides the autopilot repo root used by scripts, including the primary checkout watched by the worktree-tangle guard.
When `AP_HOME` is unset, it also behaves as the old whole-root override.
`bin/ap-send.sh` is intentionally stricter than that general fallback: it requires `AP_HOME` to be set before resolving a target, so operator steers cannot silently resolve against the wrong home.
`AP_STATE_OVERRIDE`, `AP_DATA_OVERRIDE`, `AP_PROJECTS_OVERRIDE`, and `AP_CONFIG_OVERRIDE` override individual operational directories for tests and specialized harness setup.
Before `ap-brief.sh`, `ap-spawn.sh`, or `ap-afk-launch.sh` persists a path or passes it to another process, it resolves each applicable relative `AP_HOME`, `AP_STATE_OVERRIDE`, or `AP_DATA_OVERRIDE` directory against the caller's working directory, preserves absolute spellings unchanged, and rejects an unresolvable relative directory with the offending variable named.
For the herdr backend, `AP_HOME` also determines the workspace label used by the adapter.
For the zellij backend, `AP_HOME` does not split containers, but it determines the readable home prefix embedded in visible tab titles; use `AP_ZELLIJ_SESSION` when a separate zellij session is needed.
The full zellij home label also includes a short hash of the resolved `AP_ROOT` path.
For the cmux backend, `AP_CONFIG_OVERRIDE` overrides where `config/cmux-socket-password` is read from, while `AP_HOME` determines the default config path and readable home prefix embedded in workspace titles.
The full cmux home label also includes a short hash of the resolved `AP_ROOT` path, and there is no per-home container split.

## Harness support

claude, codex, opencode, pi, pi-signed, grok, and kimi are empirically verified for flight crew member and copilot launches; [README requirements](../README.md#requirements) own the set supported for the primary session.
New harnesses get verified through a supervised trial task before joining the set.
The verified adapter knowledge - each harness's busy-state source, interrupt and exit commands, skill-invocation syntax, and per-harness quirks - lives in [`.agents/skills/harness-adapters/SKILL.md`](../.agents/skills/harness-adapters/SKILL.md).
Launch mechanics, including the verified command templates, live in [`bin/ap-spawn.sh`](../bin/ap-spawn.sh).
Enabled primary-session turn-end guard integrations are tracked as repo-level hook files and documented in [`docs/turnend-guard.md`](turnend-guard.md).
Kimi remains outside the primary turn-end guard integrations; [`docs/turnend-guard.md`](turnend-guard.md#compatibility-limits) owns its separate pilot-approved flight crew wake hook.
Primary-session watcher wake protocols are rendered at session start by [`bin/ap-supervision-instructions.sh`](../bin/ap-supervision-instructions.sh) from [`docs/supervision-protocols/`](supervision-protocols/).
Claude's Stop `asyncRewake` hook owns tokenless re-arm cycles, Grok uses background-notify cycles, Codex uses bounded foreground checkpoints, Pi and pi-signed use the same two tracked primary extensions, and OpenCode uses its TUI plugin.
`config/flight-crew-harness` is a local, gitignored file containing one adapter name for flight crew member and recon launches.
When pi-signed is selected, Autopilot launches the executable named `pi-signed` from `PATH` with `AP_PI_HARNESS=pi-signed` and refuses the launch if it is unavailable rather than falling back to pi.
Plain Pi launches set `AP_PI_HARNESS=pi`, so a signed primary's environment cannot relabel a plain Pi worker.
When it is absent or contains `default`, flight crew members mirror the autopilot's own harness.
`config/copilot-harness` is a separate local, gitignored file containing the adapter the primary uses to launch copilot agents, optionally followed by model and effort tokens on the same line.
The first non-empty, non-comment line is parsed as `<harness> [<model>] [<effort>]`.
A bare `<harness>` preserves the previous behavior: harness only, with no model or effort launch flag.
When the harness token is absent or `default`, copilot launch falls back through `config/flight-crew-harness` and then the primary's own harness, and no model or effort is read from that file.
`ap-harness.sh copilot-model` and `ap-harness.sh copilot-effort` expose only the optional tokens from `config/copilot-harness`; `config/flight-crew-harness` remains a bare adapter-name file.
An explicit harness argument to `ap-spawn.sh` still overrides either config file for that spawn only.
An explicit `--model` or `--effort` overrides the matching token from `config/copilot-harness`; an explicit harness or raw launch command starts with clean model and effort defaults unless those flags are also passed.
When `config/flight-crew-dispatch.json` exists, flight crew member and recon spawns require an explicit resolved harness instead of automatically falling back to `config/flight-crew-harness`.
The inherited-local-material contract is owned by [`copilot-provisioning`](../.agents/skills/copilot-provisioning/SKILL.md); its harness-relevant consequence is that a copilot's own flight crew members use the primary's dispatch profiles and static harness value.
Those inherited values are defaults and rules only; `ap-spawn` still permits a consciously chosen explicit runtime outside the config.
`config/copilot-harness` is not inherited because copilots do not launch copilots.
For grok, `ap-spawn.sh` installs one autopilot-owned global turn-end hook under `$GROK_HOME/hooks/`, or `~/.grok/hooks/` when `GROK_HOME` is unset, and drops a per-task `.ap-grok-turnend` pointer in the worktree, with teardown removing the task token and pointer.
For Kimi crews, `ap-spawn.sh` runs `ap-kimi-turnend-hook.sh install`, drops a per-task `.ap-kimi-turnend` pointer in the worktree, and records the matching private registry token for teardown.
Kimi continues to use the pilot's normal Kimi home, including the existing config, skills, and memory; Autopilot does not create an isolated Kimi home.
The Kimi installer requires an existing regular non-symlink `~/.kimi-code/config.toml`, `python3` with `tomllib`, and `jq`; it validates but never serializes the pilot's TOML and refuses before writing when the config is missing, malformed, or surprising or when either tool requirement is unavailable.
Its `remove` action excises only the marker-delimited Autopilot region and removes Autopilot's hook files.
For Pi and pi-signed copilot launches, `ap-spawn.sh` starts the selected executable with `-e` pointed at the copilot home's own tracked `.pi/extensions/ap-primary-pi-watch.ts` and `.pi/extensions/ap-primary-turnend-guard.ts`, both already present from the copilot home's git worktree.

## Flight crew dispatch profiles (config/flight-crew-dispatch.json)

`config/flight-crew-dispatch.json` is an optional local, gitignored file containing natural-language rules that autopilot reads before dispatching a flight crew member or recon.
The shell scripts do not match those rules; autopilot chooses the best matching rule with judgment, resolves its profile object or array under the operating contract in `AGENTS.md` section 4 and `quota-array-dispatch`, and passes only concrete `--harness`, `--model`, and `--effort` flags to `ap-spawn.sh`.
When the file exists, `ap-spawn.sh` enforces that contract by refusing flight crew member and recon spawns that lack an explicit harness (`--harness`, a positional adapter, or a raw launch command).
Batch spawns satisfy the same requirement with a shared `--harness`.
Copilot spawns are exempt and still resolve through `config/copilot-harness` and its optional model and effort tokens.
This section is the single owner of the canonical schema and its per-field semantics.
`AGENTS.md` section 4 owns the always-loaded dispatch intake boundary, and `quota-array-dispatch` owns the pace-aware profile-array selection procedure.

```json
{
  "rules": [
    {
      "when": "<natural-language condition describing a kind of task>",
      "use": [
        { "harness": "<adapter>", "model": "<optional model>", "effort": "<low|medium|high|xhigh|max, optional>" }
      ],
      "why": "<optional rationale that helps autopilot choose>"
    }
  ],
  "default": [
    { "harness": "<adapter>", "model": "<optional model>", "effort": "<optional effort>" }
  ]
}
```

Per rule, `when` and `use` are required.
Both `use` and the optional top-level `default` accept either one profile object or a non-empty array of profile objects.
The single-object form stays fully backward-compatible, and every profile needs `harness`.
Profile `model` and `effort` fields and rule `why` are optional.
An omitted model or effort means the selected harness uses its own default for that axis.
Every profile array is an implicit quota-aware choice resolved through `quota-array-dispatch`.
If no dispatch rule fits, autopilot resolves `default` through the same object-or-array path before falling back to `config/flight-crew-harness`.
If a selected profile carries an effort value the chosen harness does not accept, `ap-spawn.sh` records the requested `effort=` in task meta for traceability but omits the launch flag, and bootstrap reports the invalid harness/effort pair as a `FLIGHT_CREW_DISPATCH` diagnostic when it is visible in the file.
See [`docs/examples/flight-crew-dispatch.json`](examples/flight-crew-dispatch.json) for a starting point to copy into local `config/flight-crew-dispatch.json`.
When the file exists, bootstrap validates it with `jq`.
Valid files stay silent by default; with `AP_BOOTSTRAP_VERBOSE_FACTS=1`, bootstrap emits `BOOTSTRAP_INFO: flight crew dispatch active config/flight-crew-dispatch.json`, one `BOOTSTRAP_INFO:` fact per rule, and one fact for the optional default profile set.
Malformed JSON, an empty or malformed rule/default array, an unverified harness, or an effort value unsupported by that harness is reported as `FLIGHT_CREW_DISPATCH: invalid config/flight-crew-dispatch.json - ...`; missing `jq` is reported through the normal `MISSING: jq` install-consent flow.
While the file remains present, no flight crew member or recon spawn may proceed without an explicit resolved harness; malformed configuration must be reported and corrected rather than selected around.
Copilot homes inherit this file from the primary, so a copilot's own flight crew members apply the same dispatch profile behavior.

## Toolchain

On session start the autopilot detects what its required toolchain is missing or too old and lists each problem with either an exact install command or manual instructions.
It installs automatically supported tools only after you say go; manual-only tools remain for you to install from the printed instructions.
Required tools come in two parts: a universal toolchain every home needs regardless of backend, and a per-backend delta that follows the runtime backend actually resolved for this home.
The universal toolchain is node, git, gh with GitHub auth via `gh auth login`, no-mistakes v1.31.2 or newer, gh-axi, chrome-devtools-axi, lavish-axi, compatible tasks-axi per "Backlog backend" above, and quota-axi v0.1.16 or newer.
This section is the single owner of that universal toolchain list; backend guides' prerequisites point here and add only their backend-specific tools.
In that list, no-mistakes runs the validation pipeline, gh-axi, chrome-devtools-axi, and lavish-axi cover GitHub, browser, and rich-review operations, and tasks-axi plus quota-axi back backlog mutations and quota-aware array dispatch.
The per-backend delta is required only for the backend resolved from `AP_BACKEND`, then `config/backend`, then runtime auto-detection, then default `tmux`, so a home is never told to install a tool an inactive backend or feature would need.
That delta is owned in code by `ap_backend_required_tools` in `bin/ap-backend.sh`: the resolved backend's own session-provider CLI (`tmux`, `herdr`, `zellij`, `orca`, or `cmux`), `jq` for the JSON-emitting experimental adapters (`herdr`, `zellij`, `cmux`) whose spawn and liveness paths parse the backend's JSON output, and the `treehouse` worktree provider for every session-provider-only backend (`tmux`, `herdr`, `zellij`, `cmux`).
Backend tool availability uses the adapter's own executable resolver, so bootstrap and spawn agree on supported non-`PATH` locations such as cmux's bundled CLI.
An unknown resolved backend emits `BACKEND_INVALID` and blocks dispatch instead of silently dropping its dependency delta or falling back to tmux.
Orca provides both the task worktree and terminal endpoint (see "Runtime backend" above), so `backend=orca` requires only `orca` on top of the universal toolchain and skips both `treehouse` and every other backend's session CLI.
A herdr, zellij, or cmux home is therefore never told `tmux` is missing, and the `treehouse` durable-lease upgrade check runs only for the backends that actually use treehouse.
When `config/flight-crew-dispatch.json` exists, bootstrap also requires `jq` for dispatch profile validation.
`tasks-axi` and `quota-axi` are required bootstrap tools in every profile, the same class as `lavish-axi`.
An absent or incompatible `tasks-axi` reports `MISSING: tasks-axi (install: npm install -g tasks-axi)`; when `config/backlog-backend` is not `manual` and compatible `tasks-axi` is on `PATH`, bootstrap stays silent and autopilot uses its verbs for routine backlog mutations, otherwise it hand-edits `data/backlog.md` until installation is approved and completed.
An absent or too-old `quota-axi` reports `MISSING: quota-axi (install: npm install -g quota-axi)`; autopilot cannot resolve a profile array without a compatible binary.
That floor exists because it is the first build reporting per-credential auth sources, without which a candidate cannot be judged against the authentication surface it actually uses.
Bootstrap also reports a `TANGLE:` line when `AP_ROOT` is on a named non-default branch; follow the printed checkout remediation rather than treating it as an installable tool problem.
In a read-only session that did not get the fleet lock, the same line is advisory and omits the checkout command.
The locked session-start bootstrap step also runs a best-effort project clone refresh through `ap-fleet-sync.sh`.
It emits `FLEET_SYNC:` for skipped refreshes that may matter, recovered self-heals, and `STUCK:` alarms.
Normal completed runs keep local-only and no-origin skips silent.
If bootstrap kills a timed-out refresh, it replays any completed `ap-fleet-sync.sh` output before the aggregate timeout skip so no finished result is lost.
A killed refresh (or a teardown process kill) can leave an orphaned `.git/packed-refs.lock` in a clone, which makes the next refresh's fetch fail with Git's `Unable to create '...packed-refs.lock': File exists`.
On that signature only, `ap-fleet-sync.sh` retries the fetch with a bounded wait for the lock to self-clear, then removes the lock and retries once more only when it can prove the lock stale, exactly like the `ap-teardown.sh` `index.lock` recovery.
It never removes a live lock, leaves any other failure shape untouched, and prints every wait, retry, and removal to stderr plus a one-line `recovered:` summary to stdout on success so that this session-start relay still surfaces the recovery.
The locked session-start bootstrap step also runs the guarded local copilot sync for recorded live copilot homes, then propagates declared inherited local material into each validated live home.
It emits `COPILOT_SYNC:` only when a home was skipped for an actionable sync reason, inheritance failed, or a divergent shared pilot-preference copy was quarantined.
When a running home advances and its loaded instruction surface (`AGENTS.md`, `bin/`, or `.agents/skills/`) changed, bootstrap sends the re-read nudge itself through the stable `ap-<id>` selector and reports the exact completed send as `BOOTSTRAP_INFO:`.
If that send fails, bootstrap keeps an idempotent retry marker and emits `NUDGE_COPILOTS:` with the failure reason.
The same bootstrap run emits `COPILOT_LIVENESS:` only when a registered copilot is skipped or its relaunch fails; already-live and successfully relaunched copilots are handled silently.
For a mid-session inherited local-material edit where tracked-file sync is not needed, run `bin/ap-config-push.sh`.
It uses the same live copilot discovery and propagation helper as bootstrap, prints each live home's `flight-crew-dispatch.json`, `flight-crew-harness`, `backlog-backend`, `backend`, `herdr-presentation-spaces`, `startup-memory-budget`, and `data/pilot-shared.md` result as `pushed`, `unchanged`, `skipped`, or `error`, and exits non-zero for real propagation errors or config-reread send failures.
When an allowlisted config item changes for an already-running home, it sends the literal-content reread pointer described in [`copilot-provisioning`](../.agents/skills/copilot-provisioning/SKILL.md); unchanged allowlisted config sends no pointer unless a previous delivery is pending.
The locked bootstrap inheritance pass uses the same per-home changed-set and reread path for already-running homes; see `copilot-provisioning` for the single contract owner.
That live discovery starts from `state/*.meta` records with `kind=copilot`; `data/copilots.md` only backfills `home=` for older or incomplete meta records.
Skipped items, such as a destination checkout that does not yet gitignore the item, are visible warnings but not hard failures.

## Environment variables

Runtime tuning via environment variables (defaults shown):

```sh
AP_HOME=                 # optional operational home for most scripts, unset means this repo root; ap-send requires it explicitly
AP_ROOT_OVERRIDE=        # override autopilot repo root, tangle-guard target, and zellij/cmux home-title hash; also legacy whole-root override when AP_HOME is unset
AP_STATE_OVERRIDE=       # alternate state dir, mainly for tests
AP_DATA_OVERRIDE=        # alternate data dir, mainly for tests
AP_PROJECTS_OVERRIDE=    # alternate projects dir, mainly for tests
AP_CONFIG_OVERRIDE=      # alternate config dir, mainly for tests
AP_PROC_ROOT_OVERRIDE=   # alternate /proc root for the Linux process-identity read in ap-wake-lib.sh, mainly for tests
AP_BACKEND=             # optional runtime backend override for new spawns; tmux/herdr/zellij/orca/cmux support flight/recon spawns, codex-app is not accepted
HERDR_SESSION=default  # herdr-only: named session for normal backend ops; not enough for destructive cleanup (docs/herdr-backend.md)
AP_BACKEND_HERDR_COMPOSER_LINES=20  # herdr-only: tail lines scanned by composer-state guard/fallback paths; idle-baseline submit confirmation uses agent-state
AP_BACKEND_HERDR_IDLE_RE='^Type a message\.\.\.$'  # herdr-only: empty-composer placeholder regex after shared ghost extraction plus border and prompt stripping
AP_BACKEND_HERDR_BARE_PROMPT_RE='^(❯|›)'  # herdr-only: verified agent glyphs recognized as an UNBORDERED (bare) composer row, e.g. Claude's ❯ or Codex's ›; an alternation, not a `[...]` bracket expression, so a C-locale byte-decomposed match can never misfire on an unrelated multibyte glyph; shell glyphs remain unknown rather than empty, and de-emphasised ghost/placeholder text reads empty through shared ap_composer_strip_ghost (docs/herdr-backend.md "Composer and injection safety")
AP_BACKEND_HERDR_PI_COMPOSER_MAX_LINES=8  # herdr-only: maximum rows admitted between Pi's native-identity-corroborated separator pair; taller or ambiguous candidates stay unknown (docs/herdr-backend.md "Composer and injection safety")
AP_BACKEND_HERDR_SUBMIT_POLLS=6  # herdr-only: agent-state samples spread across each Enter attempt's budget when confirming a submit (docs/herdr-backend.md "Current transport behavior")
AP_BACKEND_HERDR_SUBMIT_MIN_SLEEP=0.6  # herdr-only: minimum per-Enter confirmation budget before polling agent-state after an idle baseline
AP_BACKEND_ORCA_COMPOSER_LINES=200  # orca-only: terminal-read lines scanned to locate the composer row for submit verification
AP_BACKEND_ORCA_IDLE_RE='^Type a message\.\.\.$'  # orca-only: empty-composer placeholder regex after border/prompt stripping
AP_ZELLIJ_SESSION=autopilot  # zellij-only: named session for normal backend ops and test isolation (docs/zellij-backend.md)
AP_BACKEND_CMUX_COMPOSER_LINES=20  # cmux-only: tail lines scanned to locate the composer row for submit verification
AP_BACKEND_CMUX_IDLE_RE='^Type a message\.\.\.$'  # cmux-only: empty-composer placeholder regex after border/prompt stripping
CMUX_SOCKET_PASSWORD=   # cmux-only: socket password fallback when config/cmux-socket-password is absent (docs/cmux-backend.md)
AP_SESSION_START_STATUS_TAIL=5   # state/*.status lines printed per task in the session-start digest
AP_BOOTSTRAP_DETECT_ONLY=0   # internal/read-only session-start mode: skip bootstrap's mutating sweeps and print advisory TANGLE wording
AP_GUARD_READ_ONLY=0    # internal/read-only guard mode: keep alarms but suppress drain, supervision repair, and checkout repair commands
AP_GUARD_CONTINUE_LINE='This is a supervision warning only; the guarded operation WILL still run.'   # banner continuation line; ap-send.sh overrides it to name the requested message specifically
AP_POLL=15              # seconds between watcher poll cycles
AP_HEARTBEAT=600        # base seconds between heartbeat scans; no-change heartbeats are absorbed while idle
AP_HEARTBEAT_MAX=7200   # heartbeat backoff cap
AP_CHECK_TIMEOUT=30     # seconds allowed per slow check script
AP_CODEX_WATCH_CHECKPOINT=180   # seconds per foreground watcher checkpoint in Codex primary supervision
AP_FLIGHT_CREW_STATE_NM_TIMEOUT=10   # seconds allowed per no-mistakes query inside ap-flight-crew-state.sh
AP_FLIGHT_CREW_STATE_RUNS_LIMIT=200  # recent no-mistakes run rows scanned when axi status cannot be attributed to the current code
AP_FLIGHT_CREW_STATE_BIN=bin/ap-flight-crew-state.sh   # test override for the current-state reader used by working/paused watcher triage
AP_LOCK_STALE_AFTER=2   # seconds before dead-pid lock records can be reclaimed; mid-acquire locks keep at least 2s grace
AP_GUARD_GRACE=300      # seconds before guard warnings, arm health checks, and the primary turn-end guard treat a watcher beacon as stale
AP_CLAUDE_AUTOARM_SYNC_WAIT_MS=800   # milliseconds the --claude turn-end guard waits for the Stop auto-arm's claim, health, or fresh rewake epoch before re-blocking
AP_CLAUDE_AUTOARM_EPOCH_FRESH=15   # seconds a recorded auto-arm rewake outcome counts as this event epoch's owned recovery
AP_CLAUDE_TURNEND_BLOCK_BUDGET=3   # consecutive --claude guard re-blocks before a degraded allow; safely below Claude Code's 8-block override
AP_ARM_CONFIRM_TIMEOUT=10   # seconds ap-watch-arm waits to confirm a fresh watcher before reporting FAILED; default 30 on Git Bash/MSYS
AP_ARM_ATTACH_POLL=0.5  # seconds between checks while ap-watch-arm is attached to an existing healthy watcher cycle
AP_OPENCODE_ARM_READY_TIMEOUT_MS=12000   # milliseconds the OpenCode primary watcher plugin waits for an arm attempt to report started, healthy, wake, or failure; default 35000 on Windows to stay above the MSYS confirm budget
AP_PI_ARM_READY_TIMEOUT_MS=12000   # milliseconds the Pi watcher extension waits for a successor arm to report started or attached; default 35000 on Windows to stay above the MSYS confirm budget
AP_WATCH_ARM_RETIRE_TIMEOUT_MS=1000   # milliseconds Pi/OpenCode wait for an unready successor arm to exit before abandoning retries
AP_WATCH_REARM_RETRY_BASE_MS=250   # Pi/OpenCode adapter base delay for continuity restoration retries
AP_WATCH_REARM_RETRY_MAX_MS=4000   # Pi/OpenCode adapter cap for exponential continuity retry delay
AP_WATCH_REARM_RETRY_LIMIT=5   # Pi/OpenCode adapter launch-failure retries before surfacing restoration failure
AP_WATCH_CYCLE_LOG_MAX_BYTES=262144   # size cap for the arm-owned watcher lifecycle ledger
AP_WATCH_CYCLE_LOG_KEEP_LINES=1000   # newest complete lifecycle rows considered when the ledger is capped
AP_WATCHER_STALE_GRACE=300   # defaults to AP_GUARD_GRACE; seconds a live watcher lock may have a stale beacon before re-arm errors
AP_SIGNAL_GRACE=30      # seconds to coalesce nearby status and turn-end signals into one wake
AP_PILOT_RE='done:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged'   # pilot-relevant status regex; nonterminal progress verbs remain excluded even when their prose matches
AP_CLASSIFY_PAUSED_VERB=paused     # leading status verb for a declared external wait; excluded from AP_PILOT_RE and distinct from blocked
AP_STALE_ESCALATE_SECS=240         # idle seconds before a provably-working stale pane escalates; stale panes whose flight crew is not provably working surface immediately unless they declare the pause verb
AP_BUSY_TURN_MAX_SECS=3600         # maximum age of a busy pane's latest state/<id>.turn-ended marker, or its state/<id>.meta spawn record before any turn completes, before the same wedge escalation used for a provably-working non-busy stale takes over; inspection-only, never an automatic interrupt or restart
AP_PAUSE_RESURFACE_SECS=3600       # seconds before an idle declared external wait re-surfaces for a recheck in the watcher or away-mode daemon
AP_WEDGE_DEMAND_INSPECT_COUNT=3    # consecutive provably-working stale escalations on the same unchanged pane before demand-deep-inspection is added
AP_WATCH_TRIAGE_LOG_MAX_BYTES=262144   # size cap for the watcher's absorbed-wake debug log
AP_FLEET_SYNC_BOOTSTRAP_TIMEOUT=     # optional seconds allowed for bootstrap's best-effort clone refresh; unset/blank defaults to max(20, 5 + 3 * origin-backed-project-count)
AP_FLEET_PRUNE=1        # set to 0 to skip pruning local branches whose upstream is gone
AP_STALE_WORKTREE_LOCK_AGE_SECS=30       # min mtime age before ap-teardown.sh treats a leftover worktree git index.lock as provably stale
AP_TREEHOUSE_RETURN_LOCK_RETRIES=3        # retries after a treehouse return fails on the transient git index.lock signature
AP_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=1 # seconds ap-teardown.sh waits before each retry after that signature
AP_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=   # legacy alias for AP_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS when the new variable is unset
AP_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=3        # fetch retries after ap-fleet-sync.sh hits the orphaned .git/packed-refs.lock signature
AP_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=1 # seconds ap-fleet-sync.sh waits before each of those retries
AP_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS=30       # min mtime age before ap-fleet-sync.sh treats a leftover packed-refs.lock as provably stale
AP_BUSY_REGEX=          # optional override for rendered delivery guards and Grok's isolated task-state fallback; converted worker state ignores it
AP_COMPOSER_IDLE_RE=    # optional empty-composer regex, applied after ghost and border stripping
AP_COMPOSER_GHOST_LUMA_MAX=128   # fleet-wide: max perceived luminance (0.299R+0.587G+0.114B, 0-255) for a TRUECOLOR foreground to count as de-emphasised ghost/placeholder text and be stripped; dim/faint (SGR 2) is stripped regardless. Assumes a dark terminal theme (bin/ap-composer-lib.sh's ap_composer_strip_ghost, shared by the tmux and herdr composer readers)
GROK_HOME=              # optional Grok config home for autopilot's global grok turn-end hook; defaults to ~/.grok
AP_SEND_RETRIES=3       # ap-send Enter-retry attempts after typing the line once
AP_SEND_SLEEP=0.4       # seconds between ap-send submit checks
AP_SEND_SETTLE=1        # seconds ap-send waits after a successful text submit; 0 disables
AP_PENDING_REPLY_GRACE_SECS=120   # seconds after marked-request delivery before a completed turn without a correlated parent report is eligible for its one recovery repost
# sub-supervisor (bin/ap-supervise-daemon.sh); presence-gated via /afk
AP_SUPERVISOR_BACKEND=             # optional supervisor pane backend override; tmux/herdr only, otherwise detects $TMUX_PANE then HERDR_ENV/HERDR_PANE_ID before tmux fallback
AP_SUPERVISOR_TARGET=              # optional supervisor pane target override; tmux target or herdr <session>:<pane-id>, otherwise auto-detected
AP_INJECT_SKIP=heartbeat           # |-prefixes force-self-handled bypassing classification; empty disables
AP_ESCALATE_BATCH_SECS=90          # buffer window for batched escalation digests; 0 = flush immediately
AP_MAX_DEFER_SECS=300              # max buffered escalation age before retry plus wedge alarm; 0 disables
AP_WEDGE_ALARM_CHANNEL=            # override config/wedge-alarm with one active-alert directive for the wedge alarm; off|auto|osascript|herdr|command:<cmd>; absent = auto (macOS -> an OS notification)
AP_WEDGE_ALARM_EXEC=              # notifier seam: route every channel (osascript, herdr, command:) through this command as `<cmd> <channel> <summary>`; "discard" fires nothing; unset in production; the daemon defaults it to "discard" when sourced so no test posts a real notification (docs/wedge-alarm.md)
AP_WEDGE_ALARM_TIMEOUT_SECS=10    # maximum seconds for each osascript, herdr, override, or command: notifier before its watchdog terminates it and continues to the next channel; invalid or zero values use 10
AP_INJECT_FAIL_SLEEP=30            # seconds to back off when the supervisor pane is unavailable
AP_INJECT_CONFIRM_RETRIES=3        # daemon Enter-retry attempts after typing a digest once
AP_INJECT_CONFIRM_SLEEP=0.5        # seconds between daemon submit checks
AP_HEARTBEAT_SCAN_SECS=300         # cadence of the catch-all status scan for missed pilot verbs
AP_HOUSEKEEPING_TICK=15            # seconds between batch-flush, stale/pause-recheck, and scan passes
AP_CRASH_THRESHOLD=10              # watcher crashes allowed inside AP_CRASH_WINDOW before daemon backoff
AP_CRASH_WINDOW=60                 # seconds in the crash-loop detection window
AP_CRASH_BACKOFF=60                # seconds to wait after crossing the crash threshold
AP_CRASH_NORMAL_SLEEP=5            # seconds to wait after an isolated watcher crash
AP_LOG_MAX_BYTES=1048576           # daemon log size that triggers trimming
AP_LOG_KEEP_LINES=2000             # daemon log lines kept when trimming
```

`ap-teardown.sh` retries only Git's `Unable to create '...index.lock': File exists` return failure up to `AP_TREEHOUSE_RETURN_LOCK_RETRIES` times.
`AP_TREEHOUSE_RETURN_LOCK_RETRIES` accepts a nonnegative integer, and an unset, blank, or invalid value uses the default of 3.
`AP_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS` accepts nonnegative whole or fractional seconds between attempts.
When it is unset or blank, `AP_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS` remains a compatible fallback, and a blank fallback uses the 1-second default.
An invalid nonblank wait falls back to 1 second rather than interrupting teardown.
Teardown never removes a lock during the retry window, and after that window it attempts stale-lock cleanup only for a still-present lock that passes the configured age and live-holder checks.

`ap-fleet-sync.sh` applies the same shape to an orphaned `.git/packed-refs.lock`: it retries only Git's `Unable to create '...packed-refs.lock': File exists` fetch failure up to `AP_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES` times (nonnegative integer; unset, blank, or invalid uses the default of 3), waiting `AP_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS` seconds (nonnegative whole or fractional; invalid falls back to 1 second) before each.
Only after those retries exhaust does it remove the lock, and only when it is provably stale - still present, mtime age at least `AP_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS` (default 30), and no `lsof` holder of the lock file or of the clone worktree itself (a live `git` keeps that as its cwd even in the window after it closes the lock and before it exits).
A live lock, a missing `lsof`, any failed check, or any other fetch failure keeps today's behavior.
Every wait, retry, and removal is printed to stderr, and a successful recovery also prints one `recovered:` summary line to stdout so a session-start refresh - which discards fleet-sync stderr and relays only stdout - still surfaces it.
The shared staleness proof lives in `bin/ap-lock-lib.sh`, which both `ap-teardown.sh` and `ap-fleet-sync.sh` use.
