#!/usr/bin/env bash
# fm-watchdog-install.sh - install/uninstall the launchd beacon watchdog for one home.
#
# Stamps launchd/com.firstmate.watcher-watchdog.plist with this home's real
# absolute paths and a per-home unique label, then loads it as a per-user
# LaunchAgent so bin/fm-watchdog-check.sh re-arms a silently-dead watcher on a
# timer, independent of any harness turn cadence (docs/watcher-watchdog.md).
#
# Usage:
#   FM_HOME=<home> bin/fm-watchdog-install.sh install    # default verb
#   FM_HOME=<home> bin/fm-watchdog-install.sh uninstall
#   FM_HOME=<home> bin/fm-watchdog-install.sh status
#
# FM_HOME defaults to this repo root. The stamped agent carries FM_HOME, the
# installing user's PATH, and a label derived from that path, so several
# firstmate homes under one macOS user do not collide. install is idempotent
# (it reloads the current plist). It fails loud (nonzero) when launchctl is
# unavailable - i.e. on non-macOS - rather than silently misinstall a
# LaunchAgent that can never run.
#
# launchd starts agents on a minimal PATH (/usr/bin:/bin:/usr/sbin:/sbin), where
# a Homebrew jq/git is invisible; the checker's scope gate and the armed
# watcher's X-mode poll both need the user's real PATH, so it is stamped in.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
TEMPLATE="$FM_ROOT/launchd/com.firstmate.watcher-watchdog.plist"
CHECKER="$SCRIPT_DIR/fm-watchdog-check.sh"
LAUNCH_AGENTS="${HOME}/Library/LaunchAgents"

die() {
  printf 'fm-watchdog-install.sh: %s\n' "$*" >&2
  exit 1
}

command -v launchctl >/dev/null 2>&1 || die "launchctl not found; the watchdog LaunchAgent is macOS-only"
[ -f "$TEMPLATE" ] || die "missing plist template: $TEMPLATE"
[ -x "$CHECKER" ] || die "missing or non-executable checker: $CHECKER"
[ -d "$FM_HOME" ] || die "FM_HOME does not exist: $FM_HOME"

FM_HOME_ABS=$(cd "$FM_HOME" 2>/dev/null && pwd -P) || die "cannot resolve FM_HOME: $FM_HOME"

# A per-home label fragment: the absolute home path reduced to [A-Za-z0-9], with
# runs of other characters collapsed to a single dash. Keeps several homes under
# one user distinct without a path that launchd Labels cannot hold.
home_slug() {
  local slug
  slug=$(printf '%s' "$FM_HOME_ABS" | LC_ALL=C tr -cs 'A-Za-z0-9' '-' | sed 's/^-*//; s/-*$//')
  [ -n "$slug" ] || slug=default
  printf '%s\n' "$slug"
}

LABEL="com.firstmate.watcher-watchdog.$(home_slug)"
PLIST="$LAUNCH_AGENTS/$LABEL.plist"
DOMAIN="gui/$(id -u)"

# Escape a value for the replacement side of sed -e "s|@@X@@|VALUE|g": backslash,
# ampersand, and the | delimiter are all special there.
sed_escape() {
  printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'
}

AGENT_PATH="${PATH:-/usr/bin:/bin:/usr/sbin:/sbin}"

stamp_plist() {
  mkdir -p "$LAUNCH_AGENTS" || die "cannot create $LAUNCH_AGENTS"
  local tmp
  tmp="$PLIST.tmp.$$"
  sed -e "s|@@LABEL@@|$(sed_escape "$LABEL")|g" \
      -e "s|@@CHECKER@@|$(sed_escape "$CHECKER")|g" \
      -e "s|@@FM_HOME@@|$(sed_escape "$FM_HOME_ABS")|g" \
      -e "s|@@PATH@@|$(sed_escape "$AGENT_PATH")|g" \
      "$TEMPLATE" > "$tmp" 2>/dev/null || { rm -f "$tmp"; die "failed to stamp plist"; }
  mv -f "$tmp" "$PLIST" || { rm -f "$tmp"; die "failed to write $PLIST"; }
}

unload_agent() {
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null \
    || launchctl unload -w "$PLIST" 2>/dev/null \
    || true
}

load_agent() {
  # Prefer the modern API; fall back to the legacy subcommand on older macOS or
  # when bootstrap reports the service already bootstrapped.
  if launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null; then
    return 0
  fi
  launchctl load -w "$PLIST" 2>/dev/null
}

is_loaded() {
  launchctl list "$LABEL" >/dev/null 2>&1
}

do_install() {
  stamp_plist
  # Reload so the currently-loaded agent always matches the stamped plist.
  unload_agent
  if ! load_agent; then
    die "launchctl refused to load $PLIST; inspect with: launchctl print $DOMAIN/$LABEL"
  fi
  printf 'watchdog: installed and loaded label=%s home=%s\n' "$LABEL" "$FM_HOME_ABS"
  printf 'watchdog: status with: FM_HOME=%s bin/fm-watchdog-install.sh status\n' "$FM_HOME_ABS"
}

do_uninstall() {
  unload_agent
  rm -f "$PLIST" 2>/dev/null || true
  printf 'watchdog: uninstalled label=%s home=%s\n' "$LABEL" "$FM_HOME_ABS"
}

do_status() {
  printf 'watchdog home:  %s\n' "$FM_HOME_ABS"
  printf 'watchdog label: %s\n' "$LABEL"
  if [ -f "$PLIST" ]; then
    printf 'watchdog plist: %s (present)\n' "$PLIST"
  else
    printf 'watchdog plist: %s (absent)\n' "$PLIST"
  fi
  if is_loaded; then
    printf 'watchdog loaded: yes\n'
  else
    printf 'watchdog loaded: no\n'
  fi
}

case "${1:-install}" in
  install) do_install ;;
  uninstall) do_uninstall ;;
  status) do_status ;;
  *) die "usage: fm-watchdog-install.sh [install|uninstall|status]" ;;
esac
