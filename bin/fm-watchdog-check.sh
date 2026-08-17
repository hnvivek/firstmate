#!/usr/bin/env bash
# fm-watchdog-check.sh - turn-independent beacon watchdog for watcher continuity.
#
# A continuity backstop that does NOT depend on any harness turn cadence. The
# Claude Stop asyncRewake auto-arm (bin/fm-claude-stop-autoarm.sh) restores a
# watcher only while Claude is turning; a watcher that dies silently during an
# idle gap raises no exit-2 wake, so nothing re-arms it and state/.last-watcher-beat
# goes stale while the home sits blind for hours. This checker runs on a launchd
# timer (launchd/com.firstmate.watcher-watchdog.plist, installed by
# bin/fm-watchdog-install.sh), independent of Claude's turns and surviving
# firstmate restarts and reboots, and re-arms the watcher exactly when it would
# otherwise stay dead. See docs/watcher-watchdog.md for the full mechanism.
#
# It applies the SAME gates the Stop auto-arm uses, so it never arms an idle,
# away, or unowned home, and it never double-arms:
#   - Scope: only a genuine primary checkout (or marked secondmate home) with
#     AGENTS.md, bin/, and the effective state dir - the fm-primary-scope gate,
#     identical to the Stop auto-arm and fm-turnend-guard.sh.
#   - Need: only while work is in flight (state/*.meta) or an X-mode relay poll
#     (state/x-watch.check.sh) needs a watcher; an idle home exits 0.
#   - AFK: while state/.afk exists the away daemon owns the watcher; exit 0.
#   - Session: only while THIS home holds a live session lock (state/.lock names
#     a live harness pid). Unlike the Stop auto-arm, launchd launches this
#     checker OUTSIDE any harness process tree, so it cannot prove it descends
#     from the lock owner; it instead confirms a live firstmate session still
#     owns the home and never reclaims a stale lock itself - a restarted session
#     re-acquires its own.
#   - Beacon: only when state/.last-watcher-beat is older than the grace window,
#     i.e. no fresh watcher is keeping the home supervised. A fresh beacon means
#     the Stop auto-arm or an attached arm already supervises the home, so this
#     exits 0 without even touching the single-flight lock.
#   - Single-flight: acquire the SAME owner lock the Stop auto-arm uses
#     (state/.claude-autoarm.lock). If another arm - the Stop hook or a prior
#     checker tick still foregrounding an arm cycle - holds it with a live owner,
#     exit 0. Only one arm ever runs per home, across the hook and this watchdog.
#
# When every gate passes it foregrounds bin/fm-watch-arm.sh (NEVER shell &),
# exactly as the Stop auto-arm does, holding the owner lock for the arm cycle's
# lifetime and releasing it on exit. The arm forks the watcher as its tracked
# child, so this checker staying foregrounded for the cycle is what keeps the
# watcher (and its fresh beacon) alive between Claude turns.
#
# This checker does NOT write outcome=rewake to the epoch ledger. That outcome
# lets the synchronous Stop guard (bin/fm-turnend-guard.sh --claude) allow a stop
# WITHOUT a Claude continuation, and a launchd arm produces no Claude
# continuation, so a rewake outcome here would falsely suppress one. The guard
# already recognizes a live owner-lock pid as "recovery owned", which is the
# correct signal while this checker holds the lock.
#
# Only the watcher process (bin/fm-watch.sh) ever touches state/.last-watcher-beat;
# this checker only reads its age and never writes the beacon.
#
# Exit 0 in every non-arming case and after an arm cycle completes. It never
# exits 2: a launchd agent's exit code carries no harness rewake, so there is no
# rewake to signal. The outcome is observable via the beacon going fresh and the
# arm's bounded cycle ledger (state/.watch-cycle-exits.log).
#
# Usage:
#   FM_HOME=<home> bin/fm-watchdog-check.sh
# Grace honors FM_GUARD_GRACE (default 300), matching the arm and guard layers.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
GRACE=${FM_GUARD_GRACE:-300}
BEAT="$STATE/.last-watcher-beat"
OWNER_LOCK="$STATE/.claude-autoarm.lock"
WATCH_ARM="$SCRIPT_DIR/fm-watch-arm.sh"
case "$GRACE" in ''|*[!0-9]*) GRACE=300 ;; esac

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

# --- scope: genuine primary home only -----------------------------------------
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

# --- need: in-flight work or an X-mode relay poll -----------------------------
fm_supervision_needed "$STATE" "$GRACE" || exit 0

# --- AFK: the away daemon owns the watcher and triage -------------------------
[ -e "$STATE/.afk" ] && exit 0

# --- session: a live firstmate session must still own this home ---------------
# launchd launched us outside any harness process tree, so we cannot prove we
# descend from the lock owner the way the Stop auto-arm does. Confirm only that a
# live harness still holds state/.lock; never reclaim a stale lock here.
session_lock_live() {
  local lock_pid
  [ -f "$STATE/.lock" ] || return 1
  lock_pid=$(cat "$STATE/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  fm_harness_pid_alive "$lock_pid"
}
session_lock_live || exit 0

# --- beacon: only act when no fresh watcher supervises the home ----------------
beacon_age=$(fm_path_age "$BEAT")
[ "$beacon_age" -ge "$GRACE" ] || exit 0

# --- single-flight: the same owner lock the Stop auto-arm uses -----------------
# A live holder (the Stop hook or a prior checker tick foregrounding an arm) means
# recovery is already under way; step aside rather than double-arm.
fm_lock_try_acquire "$OWNER_LOCK" || exit 0
if ! fm_lock_set_role "$OWNER_LOCK" autoarm; then
  fm_lock_release "$OWNER_LOCK"
  exit 0
fi
trap 'fm_lock_release "$OWNER_LOCK"' EXIT

# X mode cadence: source the generated config so an X instance polls at its
# 30s cadence (fm-bootstrap.sh x_mode_setup contract), matching the Stop
# auto-arm. Without it the forked watcher would run at the 300s default.
# shellcheck source=/dev/null
[ -f "$CONFIG/x-mode.env" ] && . "$CONFIG/x-mode.env"

# --- foreground the real arm wrapper (NEVER shell &) --------------------------
# Blocks for the arm cycle, which is exactly what keeps a watcher (and its fresh
# beacon) alive between Claude turns. Subsequent timer ticks see the owner lock
# held and no-op.
"$WATCH_ARM" >/dev/null 2>&1

# The arm's outcome is recorded in its cycle ledger and the beacon it refreshed;
# a launchd exit carries no harness rewake, so always settle at exit 0.
exit 0
