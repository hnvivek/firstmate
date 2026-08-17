#!/usr/bin/env bash
# Behavior tests for the launchd beacon watchdog checker
# (bin/fm-watchdog-check.sh, launchd/com.firstmate.watcher-watchdog.plist,
# bin/fm-watchdog-install.sh, docs/watcher-watchdog.md).
#
# The checker runs launchd-spawned, OUTSIDE any harness process tree, so unlike
# the Claude Stop auto-arm it gates on a LIVE session-lock holder rather than its
# own ancestry. These tests run the real checker against a hermetic fixture home:
# a plain git checkout with the checker and its sourced libs copied in, a fake
# fm-watch-arm.sh that records when it ran, and a fake-claude symlink pid written
# into state/.lock to stand in for a live firstmate session. No real watcher,
# model, fleet state, or launchd agent is touched.
# shellcheck disable=SC2016 # single quotes are deliberate: $FM_HOME expands inside the fake harness child
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECKER="$ROOT/bin/fm-watchdog-check.sh"
INSTALLER="$ROOT/bin/fm-watchdog-install.sh"
PLIST_TEMPLATE="$ROOT/launchd/com.firstmate.watcher-watchdog.plist"

TMP_ROOT=$(fm_test_tmproot fm-watchdog-check)
fm_git_identity fmtest fmtest@example.invalid

FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
ln -s /bin/bash "$FAKEBIN/claude"
FAKE_CLAUDE="$FAKEBIN/claude"

# Copy the checker and its sourced dependencies into a fixture checkout so the
# checker's SCRIPT_DIR resolves to the fixture bin and it runs the fixture's
# fake fm-watch-arm.sh, never the real arm.
install_watchdog_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-watchdog-check.sh" "$dir/bin/fm-watchdog-check.sh"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$dir/bin/fm-primary-scope-lib.sh"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$dir/bin/fm-supervision-lib.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/fm-wake-lib.sh"
  cp "$ROOT/bin/fm-session-lock-lib.sh" "$dir/bin/fm-session-lock-lib.sh"
  cp "$ROOT/bin/fm-cursor-lib.sh" "$dir/bin/fm-cursor-lib.sh"
  chmod +x "$dir/bin/fm-watchdog-check.sh"
}

make_primary_dir() {
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_watchdog_scripts "$dir"
  printf '%s\n' "$dir"
}

# A genuine linked git worktree (git-dir != git-common-dir): the crewmate/scout
# shape, which must keep the checker inert (not a primary home).
make_crewmate_worktree_dir() {
  local base=$1 dir=$2
  fm_git_worktree "$base" "$dir" fm/watchdog-test-branch
  mkdir -p "$dir/state"
  : > "$dir/AGENTS.md"
  install_watchdog_scripts "$dir"
  printf '%s\n' "$dir"
}

# Run the checker against fixture $1; exit code on stdout of the caller.
run_checker() {
  local dir=$1
  FM_HOME="$dir" bash "$dir/bin/fm-watchdog-check.sh" >/dev/null 2>&1
}

# Background a fake-claude process and record it as the fixture's live session
# owner. Echoes the pid; the caller kills it when done.
start_session_owner() {
  local dir=$1 pid
  # Redirect the backgrounded owner's fds so it does not inherit this call's
  # stdout pipe when invoked under command substitution, which would otherwise
  # keep owner=$(...) open until the sleeper exits.
  "$FAKE_CLAUDE" -c 'sleep 300; :' >/dev/null 2>&1 &
  pid=$!
  printf '%s\n' "$pid" > "$dir/state/.lock"
  printf '%s\n' "$pid"
}

# Fake arm variants, installed as <dir>/bin/fm-watch-arm.sh.
write_arm_fixture() {
  local dir=$1 kind=$2
  case "$kind" in
    actionable)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "$FM_HOME/state/arm-ran"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'signal: fixture done\n'
exit 0
SH
      ;;
    slow-actionable)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "$FM_HOME/state/arm-ran"
sleep 2
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'signal: fixture done\n'
exit 0
SH
      ;;
    *)
      echo "unknown arm fixture: $kind" >&2
      return 2
      ;;
  esac
  chmod +x "$dir/bin/fm-watch-arm.sh"
}

# --- re-arm when the beacon is stale and every gate passes --------------------

test_re_arms_when_beacon_absent_and_gates_pass() {
  local dir owner status
  dir=$(make_primary_dir "$TMP_ROOT/stale-absent")
  : > "$dir/state/task.meta"
  owner=$(start_session_owner "$dir")
  write_arm_fixture "$dir" actionable
  run_checker "$dir"; status=$?
  kill "$owner" 2>/dev/null || true; wait "$owner" 2>/dev/null || true
  expect_code 0 "$status" "checker must exit 0 even when it arms (no launchd rewake)"
  [ -e "$dir/state/arm-ran" ] || fail "checker did not re-arm a stale beacon with all gates passing"
  [ ! -e "$dir/state/.claude-autoarm.lock" ] || fail "checker left the single-flight owner lock held"
  [ ! -e "$dir/state/.claude-autoarm-epoch" ] || fail "checker must not write the auto-arm epoch ledger"
  pass "watchdog: re-arms when the beacon is absent and every gate passes"
}

test_re_arms_when_beacon_mtime_past_grace() {
  local dir owner status
  dir=$(make_primary_dir "$TMP_ROOT/stale-old")
  : > "$dir/state/task.meta"
  owner=$(start_session_owner "$dir")
  : > "$dir/state/.last-watcher-beat"
  # mtime far in the past: well beyond the 300s grace window.
  touch -t 197001010000 "$dir/state/.last-watcher-beat"
  write_arm_fixture "$dir" actionable
  run_checker "$dir"; status=$?
  kill "$owner" 2>/dev/null || true; wait "$owner" 2>/dev/null || true
  expect_code 0 "$status" "checker must exit 0 when it arms"
  [ -e "$dir/state/arm-ran" ] || fail "checker did not re-arm an old beacon with all gates passing"
  pass "watchdog: re-arms when the beacon mtime is past the grace window"
}

# --- no-op when the beacon is fresh -------------------------------------------

test_noop_when_beacon_fresh() {
  local dir owner status
  dir=$(make_primary_dir "$TMP_ROOT/fresh")
  : > "$dir/state/task.meta"
  owner=$(start_session_owner "$dir")
  touch "$dir/state/.last-watcher-beat"
  write_arm_fixture "$dir" actionable
  run_checker "$dir"; status=$?
  kill "$owner" 2>/dev/null || true; wait "$owner" 2>/dev/null || true
  expect_code 0 "$status" "checker must exit 0 with a fresh beacon"
  [ ! -e "$dir/state/arm-ran" ] || fail "checker re-armed despite a fresh beacon"
  [ ! -e "$dir/state/.claude-autoarm.lock" ] || fail "checker touched the single-flight lock with a fresh beacon"
  pass "watchdog: no-ops when the beacon is fresh"
}

# --- no-op when a gate fails --------------------------------------------------

test_noop_when_idle() {
  local dir owner status
  dir=$(make_primary_dir "$TMP_ROOT/idle")
  owner=$(start_session_owner "$dir")
  write_arm_fixture "$dir" actionable
  run_checker "$dir"; status=$?
  kill "$owner" 2>/dev/null || true; wait "$owner" 2>/dev/null || true
  expect_code 0 "$status" "checker must exit 0 with nothing in flight"
  [ ! -e "$dir/state/arm-ran" ] || fail "checker armed an idle home"
  pass "watchdog: no-op when no work is in flight"
}

test_noop_when_afk() {
  local dir owner status
  dir=$(make_primary_dir "$TMP_ROOT/afk")
  : > "$dir/state/task.meta"
  owner=$(start_session_owner "$dir")
  : > "$dir/state/.afk"
  write_arm_fixture "$dir" actionable
  run_checker "$dir"; status=$?
  kill "$owner" 2>/dev/null || true; wait "$owner" 2>/dev/null || true
  expect_code 0 "$status" "checker must exit 0 while away mode owns triage"
  [ ! -e "$dir/state/arm-ran" ] || fail "checker armed while state/.afk existed"
  pass "watchdog: no-op while AFK owns supervision"
}

test_noop_when_no_live_session_lock() {
  local dir status
  dir=$(make_primary_dir "$TMP_ROOT/no-session")
  : > "$dir/state/task.meta"
  # No state/.lock at all: no firstmate session owns the home.
  write_arm_fixture "$dir" actionable
  run_checker "$dir"; status=$?
  expect_code 0 "$status" "checker must exit 0 with no session lock"
  [ ! -e "$dir/state/arm-ran" ] || fail "checker armed with no live session lock"

  # A non-harness live pid in .lock is not a firstmate session owner.
  sleep 300 &
  local sleeper=$!
  printf '%s\n' "$sleeper" > "$dir/state/.lock"
  run_checker "$dir"; status=$?
  kill "$sleeper" 2>/dev/null || true; wait "$sleeper" 2>/dev/null || true
  expect_code 0 "$status" "checker must exit 0 when the lock holder is not a harness"
  [ ! -e "$dir/state/arm-ran" ] || fail "checker armed for a non-harness lock holder"
  pass "watchdog: no-op unless a live harness holds the session lock"
}

test_noop_in_child_worktree() {
  local base dir status
  base="$TMP_ROOT/crew-base"
  dir="$TMP_ROOT/crew-wt"
  make_crewmate_worktree_dir "$base" "$dir" >/dev/null
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  run_checker "$dir"; status=$?
  expect_code 0 "$status" "checker must stay inert in a child task worktree"
  [ ! -e "$dir/state/arm-ran" ] || fail "checker armed inside a child worktree"
  pass "watchdog: inert in a linked child worktree even when in-flight"
}

# --- single-flight: never double-arm with the Stop hook or a prior tick -------

test_noop_when_single_flight_lock_held() {
  local dir owner status
  dir=$(make_primary_dir "$TMP_ROOT/held")
  : > "$dir/state/task.meta"
  owner=$(start_session_owner "$dir")
  write_arm_fixture "$dir" actionable
  # Acquire the same owner lock the Stop auto-arm uses, held by THIS process.
  FM_HOME="$dir" . "$ROOT/bin/fm-wake-lib.sh"
  fm_lock_try_acquire "$dir/state/.claude-autoarm.lock" \
    || { kill "$owner" 2>/dev/null || true; fail "test could not pre-acquire the single-flight lock"; }
  run_checker "$dir"; status=$?
  fm_lock_release "$dir/state/.claude-autoarm.lock"
  kill "$owner" 2>/dev/null || true; wait "$owner" 2>/dev/null || true
  expect_code 0 "$status" "checker must exit 0 when the single-flight lock is held"
  [ ! -e "$dir/state/arm-ran" ] || fail "checker armed while another owner held the single-flight lock"
  pass "watchdog: no-op while the single-flight owner lock is held by another arm"
}

test_second_tick_noops_while_first_arms() {
  local dir owner pid status rc2 count i
  dir=$(make_primary_dir "$TMP_ROOT/concurrent")
  : > "$dir/state/task.meta"
  owner=$(start_session_owner "$dir")
  write_arm_fixture "$dir" slow-actionable
  # First tick: acquires the lock and blocks on the slow arm.
  FM_HOME="$dir" bash "$dir/bin/fm-watchdog-check.sh" >/dev/null 2>&1 &
  pid=$!
  i=0
  while [ "$i" -lt 60 ] && [ ! -e "$dir/state/.claude-autoarm.lock" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -e "$dir/state/.claude-autoarm.lock" ] || { kill "$pid" 2>/dev/null || true; kill "$owner" 2>/dev/null || true; fail "first tick did not acquire the single-flight lock"; }
  # Second tick while the first still holds the lock: must no-op without arming.
  FM_HOME="$dir" bash "$dir/bin/fm-watchdog-check.sh" >/dev/null 2>&1; rc2=$?
  wait "$pid" 2>/dev/null || true
  kill "$owner" 2>/dev/null || true; wait "$owner" 2>/dev/null || true
  expect_code 0 "$rc2" "a concurrent tick must exit 0 without error"
  count=$(wc -l < "$dir/state/arm-ran" 2>/dev/null | tr -d ' ')
  [ "${count:-0}" -eq 1 ] || fail "concurrent ticks must arm exactly once, saw ${count:-0}"
  pass "watchdog: a second timer tick never double-arms while the first holds the lock"
}

# --- installer + plist template contract --------------------------------------

test_installer_is_macos_only_idempotent_and_per_home() {
  [ -x "$INSTALLER" ] || fail "fm-watchdog-install.sh must be executable"
  assert_grep 'launchctl not found' "$INSTALLER" \
    "installer must fail loud when launchctl is unavailable (non-macOS)"
  assert_grep 'command -v launchctl' "$INSTALLER" \
    "installer must detect launchctl before installing"
  assert_grep 'do_uninstall' "$INSTALLER" "installer must support uninstall"
  assert_grep 'do_status' "$INSTALLER" "installer must support status"
  assert_grep 'home_slug' "$INSTALLER" \
    "installer must derive a per-home label so homes under one user do not collide"
  # install reloads (unload then load) so the loaded agent always matches the
  # stamped plist - idempotent across re-runs.
  assert_grep 'unload_agent' "$INSTALLER" "installer must reload the agent idempotently"
  assert_grep 'com.firstmate.watcher-watchdog.' "$INSTALLER" \
    "installer label must be namespaced under com.firstmate.watcher-watchdog"
  pass "installer: macOS-only guard, install/uninstall/status, idempotent reload, per-home label"
}

test_plist_template_matches_checker_contract() {
  [ -f "$PLIST_TEMPLATE" ] || fail "missing plist template"
  assert_grep '@@LABEL@@' "$PLIST_TEMPLATE" "template must carry a stamped Label placeholder"
  assert_grep '@@CHECKER@@' "$PLIST_TEMPLATE" "template must carry a stamped checker path placeholder"
  assert_grep '@@FM_HOME@@' "$PLIST_TEMPLATE" "template must carry a stamped FM_HOME placeholder"
  assert_grep '@@PATH@@' "$PLIST_TEMPLATE" "template must carry a stamped PATH placeholder"
  assert_grep '<key>RunAtLoad</key>' "$PLIST_TEMPLATE" "agent must run at load (boot/login)"
  assert_grep '<true/>' "$PLIST_TEMPLATE" "RunAtLoad must be true"
  assert_grep '<key>StartInterval</key>' "$PLIST_TEMPLATE" "agent must define a timer interval"
  assert_grep '<integer>90</integer>' "$PLIST_TEMPLATE" "agent interval must be the short ~90s watchdog cadence"
  assert_grep '<key>FM_HOME</key>' "$PLIST_TEMPLATE" "agent must pass FM_HOME to the checker"
  assert_grep '<key>PATH</key>' "$PLIST_TEMPLATE" \
    "agent must carry a full PATH; launchd's minimal one hides Homebrew jq/git"
  # The template invokes the checker via the @@CHECKER@@ placeholder; the
  # installer owns binding that placeholder to bin/fm-watchdog-check.sh.
  assert_grep 'fm-watchdog-check.sh' "$INSTALLER" "installer must stamp the real checker path"
  assert_grep '@@PATH@@' "$INSTALLER" "installer must stamp the user PATH into the agent"
  pass "plist template: stamped placeholders, RunAtLoad, 90s StartInterval, FM_HOME+PATH, checker"
}

test_settings_and_lint_wire_watchdog_into_repo() {
  # The checker never exits 2 and never writes the beacon: a launchd agent's
  # exit carries no rewake, and only the watcher may touch the beacon.
  assert_no_grep 'exit 2' "$CHECKER" "checker must never exit 2 (no launchd rewake exists)"
  assert_grep 'fm-watch-arm.sh' "$CHECKER" "checker must foreground the real arm wrapper"
  assert_no_grep 'watch-arm.sh &"' "$CHECKER" "checker must never background the arm with shell &"
  assert_grep 'fm_lock_try_acquire "$OWNER_LOCK"' "$CHECKER" "checker must honor the shared single-flight owner lock"
  assert_grep 'fm_primary_scope_matches' "$CHECKER" "checker must apply the primary-scope gate"
  assert_grep 'fm_supervision_needed' "$CHECKER" "checker must apply the supervision-need gate"
  assert_grep 'state/.afk' "$CHECKER" "checker must defer to away mode"
  pass "checker: foreground arm, single-flight, scope/need/afk gates, never exit 2"
}

test_re_arms_when_beacon_absent_and_gates_pass
test_re_arms_when_beacon_mtime_past_grace
test_noop_when_beacon_fresh
test_noop_when_idle
test_noop_when_afk
test_noop_when_no_live_session_lock
test_noop_in_child_worktree
test_noop_when_single_flight_lock_held
test_second_tick_noops_while_first_arms
test_installer_is_macos_only_idempotent_and_per_home
test_plist_template_matches_checker_contract
test_settings_and_lint_wire_watchdog_into_repo
