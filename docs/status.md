# Status

_Living status doc. Update the date + "Current state" whenever you touch the repo._

**Last touched:** 2026-07-08 · **Version:** 0.1.0 · **State:** working, in daily use.

## Current state

A native macOS menu-bar app showing Claude subscription usage. Built and verified against
live data. Menu bar shows the Claude sunburst mark + `<5h%> · <weekly%>`; clicking opens a
popover with all rate-limit windows, an overage/credit bar, and ccusage session detail.

- Focal data: official endpoint `GET api.anthropic.com/api/oauth/usage` (OAuth bearer from
  keychain) → `limits[]` (session / weekly_all / weekly_scoped), each `percent` + `resets_at`.
- Detail data: `ccusage blocks --active --json` (best-effort; degrades gracefully if absent).
- Auto-refresh every 5 min (configurable in the popover) + manual refresh.

## Run / verify

```sh
./build.sh                                   # compile + bundle ClaudeUsageMonitor.app
./.build/release/ClaudeUsageMonitor --selftest   # headless: keychain→endpoint→decode→ccusage
./.build/release/ClaudeUsageMonitor --snapshot out.png   # render popover + label to PNGs
```

`--selftest` and `--snapshot` are the fast ways to confirm the data pipeline and UI without
opening the menu bar (which is awkward to inspect on a notched display). If `--selftest` is
green, the app works; any UI oddity is cosmetic.

## Auto-start

Installed copy lives at `/Applications/ClaudeUsageMonitor.app`. A user LaunchAgent starts it
at every login:

- `~/Library/LaunchAgents/codes.bryant.ClaudeUsageMonitor.plist` (`RunAtLoad`)
- Reload after reinstalling: `launchctl bootout gui/$(id -u)/codes.bryant.ClaudeUsageMonitor 2>/dev/null; launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/codes.bryant.ClaudeUsageMonitor.plist`
- Stop autostart: `launchctl bootout gui/$(id -u)/codes.bryant.ClaudeUsageMonitor`

To ship a change to the running app: `./build.sh && cp -R ClaudeUsageMonitor.app /Applications/`
then quit + relaunch (or log out/in).

## Known issues / limitations

- **Menu-bar crowding on notched displays.** With a long-menu app frontmost + many status
  items, macOS can hide the item behind the notch. Remedy: a bar manager (Ice/Bartender) or
  ⌘-drag to reposition. Not a code bug.
- **Token lifecycle.** The app reads the current OAuth token from the keychain each poll. If
  it's expired and Claude Code hasn't refreshed it, the usage call 401s and the popover shows
  a reauth banner (last-good values retained). Fix: open Claude Code to refresh.
- **ccusage `$` is API-equivalent**, not the Max-plan bill. Labeled as such.

## Backlog / next ideas

- Historical snapshots + a mini weekly trend sparkline (persist each poll to disk).
- Notification when the 5h window nears 100% (avoid idling into a throttle mid-task).
- Optional: per-model weekly bars only when present (already data-driven).
- Replace ad-hoc signing with a proper cert if it ever needs to leave this machine.

## Resume checklist (cold start)

1. `git pull` (GitHub is the backup — see root README for remote).
2. `./.build/release/ClaudeUsageMonitor --selftest` — is the pipeline still green? (Endpoint
   or JSON shape may have drifted; see decisions.md for the schema.)
3. `./build.sh && open ClaudeUsageMonitor.app` — sanity-check the UI.
4. Pick from the backlog above.
