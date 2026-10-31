# Decisions & gotchas

Why the load-bearing parts are the way they are. Read before changing them.

## Data source: official endpoint over ccusage

The goal is to watch *subscription* consumption (5-hour + weekly %), to pace toward full
weekly utilization. ccusage can't answer that — it computes tokens/cost from local JSONL and
has no notion of the plan's ceiling. The official `GET api.anthropic.com/api/oauth/usage`
(found baked into the Claude Code binary) returns exactly that: a `limits[]` array of windows
with `percent`, `severity`, `resets_at`, and `scope.model`. So the endpoint is the focal
source; ccusage is demoted to the detail layer (burn rate, token counts, projection).

Render `limits[]` **data-driven** — don't hardcode window kinds. New windows just appear.

## Auth: keychain token, read fresh, never stored

The endpoint needs the Claude Code OAuth token. We read it from the login keychain
(`Claude Code-credentials`) via `/usr/bin/security` on **every poll** — never cached, never
logged — and send it only to `api.anthropic.com` (the same endpoint Claude Code's own
`/usage` calls). Reading fresh means Claude Code's own token refresh keeps us valid. No secret
ever lives in the source or on disk here.

## GUI PATH: shell out through a login shell

Apps launched from Finder/launchd get a minimal PATH and won't find `ccusage`/`node`
(Homebrew, `/opt/homebrew/bin`). So ccusage runs via `/bin/zsh -lc 'ccusage …'` to load a
login-shell PATH. `security` is called by absolute path for the same reason.

## Packaging: SPM + build.sh, not an .xcodeproj

A hand-written `.pbxproj` is fragile outside Xcode's GUI. `Package.swift` opens in Xcode and
builds from CLI; `build.sh` wraps the binary into an `LSUIElement` `.app` (menu-bar-only, no
Dock icon), ad-hoc signed (personal/local — no notarization).

## Menu-bar icon sizing: size the NSImage, and tight-crop it

Two traps, both learned the hard way:

1. **`MenuBarExtra` ignores a SwiftUI `.frame` on the label image.** The status item renders
   the `NSImage` at *its own* size. So the size must be set on the `NSImage` (see
   `ClaudeMark.menuBar`), not via SwiftUI modifiers — otherwise it renders at the intrinsic
   144pt and balloons past the bar.
2. **The source SVG has ~15% transparent padding**, so a naive size looked smaller than the
   Claude app's own mark. `tightTemplate` renders the mark, finds its opaque bounding box,
   crops the padding, and centers it in a square — so the size value maps to the actual glyph.
   Current: 18pt, tuned to match the Claude app's bar icon.

The mark is a template image (`isTemplate = true`) so it auto-tints to the bar in light/dark.
The popover uses the un-cropped `ClaudeMark.image` where SwiftUI `.frame` *does* work.

## Asset provenance

`Resources/claude-mark.svg` is the single-color Claude mark (sourced from a local Stream Deck
logo icon pack). Used only to make a personal, local utility recognizable in the bar — not
redistributed.

## Verification harness

`--selftest` (data pipeline) and `--snapshot` (renders popover + menu-bar label to PNG via
`ImageRenderer` under a real `NSApplication.run()` — required, or SwiftUI's main-thread
assertion trips) exist because the menu bar is hard to inspect on a notched display. Keep them
working; they're the fastest regression check.

## Menu-bar label: adaptive, not 5-hour-primary (2026-10-31)

In 2026-10 the usage endpoint stopped returning a 5-hour `session` window for Ultra
(formerly Max 20x): `five_hour: null`, `limits[]` = weekly only. The label was hard-wired to
the session % and fell back to the loading glyph `…` forever. Now `MenuBarText` (pure,
`Labeling.swift`) walks a priority list — `session` → `weekly_all` → highest remaining — so
tiers that keep the 5-hour window render exactly as before and tiers without it show weekly.
We never hardcode which tier has which window; the endpoint is the authority.

## Plan badge: profile endpoint over the keychain blob (2026-10-31)

The keychain credential carries `subscriptionType`, but it reads just `max` for both Max and
Ultra. `GET /api/oauth/profile` returns `organization.plan_display_name` ("Ultra"), the
server's own copy, so renames need no code change. Fallback: an `organization_type` lookup
table (`claude_team` → Team …; Team/Enterprise/Pro strings unverified) with raw title-cased
fallthrough, plus `seat_tier`. Only those plan fields are decoded — the response also holds
account PII we never model. Fetched on launch/manual refresh, else at most every 6 h; a
failure never touches `usageError`.
