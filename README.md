# Claude Usage Monitor

Personal macOS menu-bar app that shows Claude subscription usage at a glance — built
for one machine, one user. Click the menu-bar item to see how much of your rate-limit
windows (**weekly**, plus **5-hour** on plans that still have one) you've consumed, which
plan you're on, plus rich session detail.

Goal-oriented: the intent is to *maximize* subscription utilization (land the weekly
window at ~100% before it resets), so weekly bars are colored by whether you're **on
pace** to fill them, not by how "dangerous" the level is.

## What it shows

**Focal — official rate-limit windows** (`GET api.anthropic.com/api/oauth/usage`):

- Menu-bar number adapts to the windows the endpoint returns: `<5h%> · <weekly%>` when a
  5-hour session window exists, `<weekly%>` when it doesn't (e.g. Ultra, since 2026-10),
  else the highest window. `…` = first load, `!` = error with no data, `—` = no windows.
- 5-hour session % + reset countdown, on plans that have one
- Plan badge in the popover header (`Ultra`, `Max`, `Pro`, `Team · Premium`, …) from
  `GET api.anthropic.com/api/oauth/profile` — the server's own `plan_display_name`
- Weekly (all models) % + reset, with a signed pace indicator (e.g. `20% ahead`,
  `7% behind`, `on pace`) — the gap between usage% and elapsed-time% of the window
- Per-model weekly caps when present (e.g. `Weekly · Opus`)
- Overage credit pool ($ used / cap)

**Detail — token accounting** (`ccusage blocks --active --json`):

- Burn rate (tokens/min, $/hr), tokens in/out, cache read
- Block total + projected total (tokens and API-equivalent $)
- Time remaining in the current activity block

## Data sources & why two

The official endpoint is the source of truth for *subscription* consumption (the % that
determines throttling and resets). ccusage parses `~/.claude/projects/**/*.jsonl` for
fine-grained token/cost detail the official endpoint doesn't expose. Its "$" is
**API-equivalent** pricing, not your plan bill — labeled as such.

## Requirements

- macOS 14+, full Xcode (Swift 6 toolchain)
- Claude Code signed in (OAuth token in the login keychain: `Claude Code-credentials`)
- `ccusage` on PATH (`brew install ccusage` or `npm i -g ccusage`) — optional; only the
  detail section degrades without it

## Build & run

```sh
./build.sh              # compiles + wraps into ClaudeUsageMonitor.app (ad-hoc signed)
open ClaudeUsageMonitor.app
```

Install + launch-at-login:

```sh
cp -R ClaudeUsageMonitor.app /Applications/
open /Applications/ClaudeUsageMonitor.app   # then toggle "Launch at login" in the popover
```

First run triggers a one-time Keychain prompt (the app reads the Claude Code OAuth
token to call the usage endpoint) — choose **Always Allow**. Gatekeeper: right-click →
Open the first time, or `xattr -dr com.apple.quarantine ClaudeUsageMonitor.app`.

## Auth model

The app reads the **current** OAuth token from your keychain on every poll (never
cached) and sends it only to `api.anthropic.com` — the same endpoint Claude Code's own
`/usage` command calls. When the token expires and Claude Code hasn't refreshed it, the
usage call returns 401 and the app surfaces a "reauth" banner while keeping the last
good values.

## Layout

```
Sources/ClaudeUsageMonitor/
  App.swift          MenuBarExtra scene + compact label
  PopoverView.swift  popover UI: data-driven limit bars, ccusage detail, footer
  Store.swift        @Observable refresh loop + timer + derived values
  Labeling.swift     pure menu-bar text selection + plan badge mapping (unit-tested)
  DataSources.swift  keychain token, usage endpoint, ccusage process
  Models.swift       Codable models + lenient ISO-8601 decoder
  Theme.swift        Claude palette (scheme-aware) + formatting
  LoginItem.swift    SMAppService launch-at-login wrapper
Tests/ClaudeUsageMonitorTests/  Swift Testing suites (`testgate run -- swift test`)
Resources/Info.plist LSUIElement agent app (no Dock icon)
build.sh             SPM build → .app bundle
```

## Non-goals

Not a product. No notarization, no multi-account, no distribution. Personal, local-only.
