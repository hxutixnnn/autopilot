# Decision hold lifecycle mechanism

The normative policy is owned by `.agents/skills/decision-hold-lifecycle/SKILL.md` and is not restated here.
This document records the deterministic mechanism, structured surfaces, and privacy-safe regression evidence.

## Mechanism

`bin/ap-decision-hold.sh` is the only lifecycle command for an investigation or visual review's unresolved pilot decisions.
The command runs tasks-axi in the active `AP_HOME`, so the existing backlog remains the only durable work database and a copilot-owned decision stays in the copilot home.
It never reads report bodies, review artifacts, terminal output, or chat.

The `hold` subcommand maps an originating work id and stable decision key to `<origin-id>-decision-<decision-key>`.
It creates a kind `pilot` backlog item when absent and uses tasks-axi's neutral external scheduling hold on every retry while retaining kind `pilot` as the Autopilot-owned decision identity.
It rejects an identity collision, a changed title, and attempts to reopen an already resolved identity.

The `complete` subcommand unions the reviewed keys into `decision_keys=` and appends `decisions_reviewed=1` while originating task metadata is live.
A post-teardown visual review can complete against the surviving report and durable holds without recreating volatile task metadata.
It accepts `--none` as an explicit semantic inventory result, not as inferred absence.
It verifies every listed identity against tasks-axi before recording completion.
For an open keyed status decision, it appends a `pilot-held [key=<key>]: ...` transfer event only after the matching backlog hold is durable.
`bin/ap-classify-lib.sh` recognizes that transfer as closing the live status copy without claiming that the pilot has answered it.

Recon teardown calls the script's read-only `verify` subcommand after checking for the report and before removing any source state.
The `--force` path remains the explicit pilot-approved discard escape hatch.

The `resolve` subcommand requires a decision file and at least one existing dependent task whose structured `blocked-by` edge points to the hold.
It records the decision digest and routed task identities as a retry identity in the hold body, clears each dependency edge through tasks-axi, and marks the hold Done only after those writes succeed.
An exact retry can finish a partial routing operation, while a changed decision or routed-task set is rejected.
A failed intermediate step leaves the hold open.

## Structured read surfaces

`bin/ap-fleet-snapshot.sh` parses canonical tasks-axi `(hold: ...)` and neutral `(hold-kind: external)` metadata on kind `pilot` tasks alongside existing backlog fields.
It resolves every repeated `blocked-by:` edge against structured Done records, keeps missing blockers unresolved, and classifies only an unblocked pilot hold as actionable.
Its copilot-home summary classifies an actionable pilot hold as `pilot_decision` and preserves blocked pilot holds as queued work in the owning home.

`bin/ap-bearings-snapshot.sh` projects actionable pilot holds into `decisions_open` and leaves blocked pilot holds in ordinary queued gates.
It excludes completed kind `pilot` records from Recently Landed.
The projection remains read-only and does not inspect historical prose.

## Verification record

Verification date: 2026-07-14.
Additional quoted `blocked_by` regression verification date: 2026-07-17.
Plural blocker-readiness and mixed-home projection verification date: 2026-07-22.

The focused end-to-end regression uses only synthetic `sample` identities and decision text.
It begins with a completed investigation and visual review whose genuine unresolved choice exists only in the report.
The initial Bearings snapshot correctly has no open decision, and the new teardown gate refuses to erase the source.
A later regression covers tasks-axi's quoted multi-entry `blocked_by` output so `resolve` matches the first, middle, and last ids and rejects a genuinely absent id.

The final verification commands and their exact summarized outputs follow.

```text
$ bash tests/ap-decision-hold-lifecycle.test.sh
ok - report-only unresolved decision is reproduced and completion refuses before loss
ok - non-forced recon teardown always requires durable inventory verification
ok - pilot holds are idempotent, distinct, teardown-safe, Bearings-visible, and durably routed before close
ok - completion and verification validate origins before constructing paths
ok - ended visual review follows the same decision-hold completion owner
ok - resolved findings and decision-like prose do not create false holds
ok - terminal single-owner stale status decisions do not block empty inventory
ok - main-home and copilot-home pilot holds remain correctly routed
ok - resolve matches first/middle/last in quoted blocked_by and rejects a genuinely absent id

$ bash tests/ap-fleet-snapshot-view.test.sh
ok - backlog normalization preserves strict roles and resolves every blocker compatibly
ok - durable pilot-held transfer closes the duplicate live status decision
ok - snapshot parses tasks-axi rows and respects operational overrides

$ bash tests/ap-bearings-snapshot.test.sh
ok - a completed recon with decision-like report prose is a pointer, not pending
ok - action-free items (working/done/queued/landed) do not leak into Pilot's Call
ok - mixed copilot roles, partial state, and pilot readiness project independently
ok - main and copilot pilot actionability use the same blocker readiness

$ bash tests/ap-brief.test.sh
ok - ap-brief.sh: investigation and visual-review completions load the shared decision policy

$ bash tests/ap-teardown.test.sh
all teardown safety cases passed

$ bin/ap-lint.sh
ap-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)

$ git diff --check
(no output)

$ for test_script in tests/*.test.sh; do bash "$test_script"; done
ALL 71 TEST SCRIPTS PASSED
```
