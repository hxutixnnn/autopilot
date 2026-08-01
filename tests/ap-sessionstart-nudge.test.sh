#!/usr/bin/env bash
# Behavior and tracked-registration tests for the native session-start nudge.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset NO_MISTAKES_GATE

TMP_ROOT=$(ap_test_tmproot ap-sessionstart-nudge)
NUDGE="$ROOT/bin/ap-sessionstart-nudge.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/ap-operational-input.sh"
NUDGE_TEXT="Run \`bin/ap-session-start.sh\` now, exactly once, before executing any other instructions."
ap_operational_input_encode session-start "$NUDGE_TEXT" NUDGE_LINE \
  || fail "could not construct expected session-start nudge"
ap_git_identity fmtest fmtest@example.invalid

make_primary() {
  local dir=$1
  mkdir -p "$dir/bin" "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
}

run_nudge() {
  local root=$1
  AP_GATE_REFUSE_BYPASS=0 AP_ROOT_OVERRIDE="$root" AP_HOME="$root" "$NUDGE"
}

expect_silent_zero() {
  local label=$1
  shift
  local out status=0
  out=$("$@" 2>&1) || status=$?
  expect_code 0 "$status" "$label must exit 0"
  [ -z "$out" ] || fail "$label must be silent, got: $out"
}

test_genuine_primary_nudges() {
  local root="$TMP_ROOT/primary" out prefix_hex status=0
  make_primary "$root"
  out=$(run_nudge "$root") || status=$?
  expect_code 0 "$status" "genuine primary nudge"
  [ "$out" = "$NUDGE_LINE" ] || fail "genuine primary printed unexpected output: $out"
  prefix_hex=$(printf '%s' "$out" | head -c 3 | od -An -tx1 | tr -d ' \n')
  [ "$prefix_hex" = e281a3 ] || fail "genuine primary nudge lost its U+2063 operational marker: $prefix_hex"
  pass "ap-sessionstart-nudge: a genuine primary gets one explicitly marked instruction line"
}

test_gate_env_is_silent() {
  local root="$TMP_ROOT/gate-env"
  make_primary "$root"
  expect_silent_zero "gate env nudge" env NO_MISTAKES_GATE=1 AP_GATE_REFUSE_BYPASS=0 \
    AP_ROOT_OVERRIDE="$root" AP_HOME="$root" "$NUDGE"
  pass "ap-sessionstart-nudge: NO_MISTAKES_GATE is silent"
}

test_gate_common_dir_is_silent() {
  local source="$TMP_ROOT/gate-source" bare="$TMP_ROOT/.no-mistakes/repos/gate.git"
  local root="$TMP_ROOT/gate-worktree"
  ap_git_init_commit "$source"
  mkdir -p "$(dirname "$bare")"
  git clone --quiet --bare "$source" "$bare"
  git --git-dir="$bare" worktree add --quiet -b gate-test "$root" HEAD
  mkdir -p "$root/bin" "$root/state"
  : > "$root/AGENTS.md"
  printf 'gate-test\n' > "$root/.ap-copilot-home"
  expect_silent_zero "gate common-dir nudge" env AP_GATE_REFUSE_BYPASS=0 \
    AP_ROOT_OVERRIDE="$root" AP_HOME="$root" "$NUDGE"
  pass "ap-sessionstart-nudge: .no-mistakes gate common-dir is silent"
}

test_unmarked_linked_worktree_is_silent() {
  local base="$TMP_ROOT/worktree-base" root="$TMP_ROOT/worktree-child"
  ap_git_worktree "$base" "$root" ap/sessionstart-linked
  mkdir -p "$root/bin" "$root/state"
  : > "$root/AGENTS.md"
  expect_silent_zero "linked worktree nudge" run_nudge "$root"
  pass "ap-sessionstart-nudge: an unmarked linked task worktree is silent"
}

test_linked_copilot_primary_nudges() {
  local base="$TMP_ROOT/copilot-base" root="$TMP_ROOT/copilot-home" out status=0
  ap_git_worktree "$base" "$root" ap/sessionstart-copilot
  mkdir -p "$root/bin" "$root/state"
  : > "$root/AGENTS.md"
  printf 'sessionstart-copilot\n' > "$root/.ap-copilot-home"
  out=$(run_nudge "$root") || status=$?
  expect_code 0 "$status" "linked copilot nudge"
  [ "$out" = "$NUDGE_LINE" ] || fail "linked copilot printed unexpected output: $out"
  pass "ap-sessionstart-nudge: a marked linked copilot home is a primary"
}

test_missing_state_is_silent() {
  local root="$TMP_ROOT/missing-state"
  make_primary "$root"
  rmdir "$root/state"
  expect_silent_zero "missing state nudge" run_nudge "$root"
  pass "ap-sessionstart-nudge: a checkout without state is silent"
}

test_owned_lock_is_silent() {
  local root="$TMP_ROOT/already-ran"
  make_primary "$root"
  printf '%s\n' "$$" > "$root/state/.lock"
  expect_silent_zero "owned lock nudge" run_nudge "$root"
  pass "ap-sessionstart-nudge: a lock holder in process ancestry is already run"
}

test_opencode_plugin_delivers_exact_nudge_once() {
  local root="$TMP_ROOT/opencode-primary" out status=0
  make_primary "$root"
  cp "$ROOT/bin/ap-sessionstart-nudge.sh" "$ROOT/bin/ap-primary-scope-lib.sh" \
    "$ROOT/bin/ap-gate-refuse-lib.sh" "$ROOT/bin/ap-operational-input.sh" "$root/bin/"
  chmod +x "$root/bin/ap-sessionstart-nudge.sh"
  out=$(PLUGIN="$ROOT/.opencode/plugins/ap-primary-sessionstart-nudge.js" \
    WORKTREE="$root" EXPECTED="$NUDGE_LINE" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const prompts = [];
const client = {
  session: {
    promptAsync: async (request) => {
      prompts.push(request.body.parts[0].text);
    },
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const hooks = await mod.AutopilotPrimarySessionstartNudge({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
const event = {
  type: "session.created",
  properties: { sessionID: "session-nudge-test", info: { id: "session-nudge-test" } },
};
await hooks.event({ event });
await hooks.event({ event });
if (prompts.length !== 1) throw new Error(`expected one prompt, got ${prompts.length}`);
if (prompts[0] !== process.env.EXPECTED) throw new Error(`unexpected prompt: ${prompts[0]}`);
EOF
  ) || status=$?
  expect_code 0 "$status" "OpenCode exact nudge delivery"
  [ -z "$out" ] || fail "OpenCode exact nudge delivery printed output: $out"
  pass "OpenCode session.created delivers the exact wrapper nudge once per session"
}

test_genuine_primary_nudges
test_gate_env_is_silent
test_gate_common_dir_is_silent
test_unmarked_linked_worktree_is_silent
test_linked_copilot_primary_nudges
test_missing_state_is_silent
test_owned_lock_is_silent
test_opencode_plugin_delivers_exact_nudge_once
