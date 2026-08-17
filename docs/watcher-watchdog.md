# Watcher watchdog (launchd beacon backstop)

A turn-independent continuity backstop for the watcher, layered above the existing continuity model in [watcher-continuity.md](watcher-continuity.md).
It exists for one gap: the Claude Stop `asyncRewake` auto-arm (`bin/fm-claude-stop-autoarm.sh`) restores a watcher only while Claude is turning, so a watcher that dies silently during an idle gap raises no exit-2 wake, nothing re-arms it, and `state/.last-watcher-beat` goes stale while the home sits blind.
A launchd timer runs the checker outside any harness turn cadence and re-arms exactly when the beacon has gone stale.
It is opt-in and macOS-only; nothing changes until the home installs the agent.

## Mechanism and ownership

`bin/fm-watchdog-check.sh` is the checker.
`launchd/com.firstmate.watcher-watchdog.plist` is a per-user LaunchAgent template that runs it with `RunAtLoad=true` and `StartInterval=90`, `FM_HOME` set to the target home, and `PATH` set to the installing user's PATH - launchd's own PATH is the minimal `/usr/bin:/bin:/usr/sbin:/sbin`, where a Homebrew `jq`/`git` is invisible, and the checker's scope gate and the armed watcher's X-mode poll both need them.
`bin/fm-watchdog-install.sh` stamps the template's `@@LABEL@@`, `@@CHECKER@@`, `@@FM_HOME@@`, and `@@PATH@@` placeholders with real absolute paths, the installing user's PATH, and a per-home unique label, then loads it from `~/Library/LaunchAgents`.

The checker applies the same gates the Stop auto-arm uses, so it never arms an idle, away, or unowned home, and it never double-arms:

- Scope - only a genuine primary checkout (or marked secondmate home); the `fm-primary-scope` gate, identical to the Stop auto-arm and `fm-turnend-guard.sh`.
- Need - only while work is in flight (`state/*.meta`) or an X-mode relay poll (`state/x-watch.check.sh`) needs a watcher.
- AFK - while `state/.afk` exists the away daemon owns the watcher.
- Session - only while this home holds a live session lock (`state/.lock` names a live harness pid).
- Beacon - only when `state/.last-watcher-beat` is older than the grace window, so a home already kept fresh by the Stop auto-arm is left alone.
- Single-flight - it acquires the same owner lock the Stop auto-arm uses (`state/.claude-autoarm.lock`); if another arm holds it, the checker steps aside.

When every gate passes it foregrounds `bin/fm-watch-arm.sh` (never shell `&`), holding the owner lock for the arm cycle and releasing it on exit.
Staying foregrounded for the cycle is what keeps the watcher - and its fresh beacon - alive between Claude turns; later timer ticks see the owner lock held and no-op.

The checker never writes `outcome=rewake` to the epoch ledger.
That outcome lets the synchronous Stop guard (`bin/fm-turnend-guard.sh --claude`) allow a stop without a Claude continuation, and a launchd arm produces no continuation, so a rewake outcome here would falsely suppress one.
The guard already recognizes a live owner-lock pid as recovery owned, which is the correct signal while the checker holds the lock.

Only the watcher process (`bin/fm-watch.sh`) ever touches the beacon; the checker only reads its age.

## Install, uninstall, and status

```sh
# Default home is this repo; set FM_HOME for a secondmate home.
FM_HOME=<home> bin/fm-watchdog-install.sh install     # stamp + load the agent
FM_HOME=<home> bin/fm-watchdog-install.sh status      # show label, plist, loaded state
FM_HOME=<home> bin/fm-watchdog-install.sh uninstall   # unload + remove the agent
```

Install is idempotent: it reloads the currently-stamped plist.
The installer fails loud (nonzero) when `launchctl` is unavailable, so it never silently misinstalls a LaunchAgent on a non-macOS host.

## The independence property

The checker runs on a launchd timer and at login/reboot, not on a Claude Stop event, so continuity survives firstmate restarts and reboots and does not depend on the model remembering a re-arm step.
The checker always exits 0: a launchd exit carries no harness rewake, so there is no reason to signal one.
Outcome is observable via the beacon going fresh and the arm's bounded cycle ledger (`state/.watch-cycle-exits.log`).

## Regression coverage

`tests/fm-watchdog-check.test.sh` runs the real checker against a hermetic fixture home and covers re-arm when the beacon is stale with every gate passing, no-op when the beacon is fresh or any gate fails (idle, AFK, no live session lock, child worktree), no-op while the single-flight lock is held, and never double-arming across concurrent timer ticks, plus the installer and plist-template contract.
