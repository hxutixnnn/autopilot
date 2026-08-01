#!/usr/bin/env bash
# Contract tests for Captain direct address without renaming the pilot role.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

assert_grep 'Address the user as "Captain" at least once in every response.' "$ROOT/AGENTS.md" \
  "mandatory Captain address contract is missing"
assert_grep 'reply exactly `Captain, flight-ready.`' "$ROOT/AGENTS.md" \
  "routine no-action response does not address Captain"
if grep -F 'reply exactly `Pilot, flight-ready.`' "$ROOT/AGENTS.md" >/dev/null; then
  fail "legacy routine direct address remains"
fi

assert_grep '"Captain, away mode is active;' "$ROOT/.agents/skills/afk/SKILL.md" \
  "away-mode acknowledgement does not address Captain"
assert_grep 'direct address as "Captain"' "$ROOT/.agents/skills/bearings/SKILL.md" \
  "bearings response contract does not address Captain"
assert_grep '"Captain, autopilot and both copilots are now on the latest."' \
  "$ROOT/.agents/skills/updateautopilot/SKILL.md" \
  "update response example does not address Captain"
assert_grep 'PR ready for review, Captain:' "$ROOT/README.md" \
  "public response example does not address Captain"

assert_grep 'data/pilot.md' "$ROOT/AGENTS.md" \
  "domain-local pilot preference schema was renamed"
assert_grep 'data/pilot-shared.md' "$ROOT/AGENTS.md" \
  "shared pilot preference schema was renamed"
assert_grep 'The user is the pilot.' "$ROOT/AGENTS.md" \
  "semantic pilot role was renamed"
assert_grep 'pilot approval remain authoritative' "$ROOT/AGENTS.md" \
  "pilot approval terminology was renamed"
assert_grep 'All flight crew member communication flows through autopilot.' "$ROOT/AGENTS.md" \
  "worker-to-user communication boundary was weakened"

pass "Captain direct-address surfaces preserve pilot semantics and worker boundaries"
