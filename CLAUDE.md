# claude-usage-monitor — repo instructions

Personal, local-only macOS menu-bar app showing Claude subscription usage. One machine,
one user. Not a product; no distribution/notarization concerns.

## Stack

- **Swift 6 / SwiftUI**, SPM executable target (no `.xcodeproj` — `Package.swift` opens
  in Xcode and builds from CLI). `build.sh` wraps the binary into an `LSUIElement` `.app`.
- No third-party Swift packages. Runtime deps: `security` (system), `ccusage` + `node`
  (Homebrew), the Claude Code keychain credential.

## Data sources (don't confuse them)

1. **Official** `GET https://api.anthropic.com/api/oauth/usage` (header
   `anthropic-beta: oauth-2025-04-20`, Bearer = Claude Code OAuth token). Source of truth
   for subscription windows: `limits[]` (session / weekly_all / weekly_scoped), each with
   `percent`, `severity`, `resets_at`, `scope.model`. **Render `limits[]` data-driven** —
   don't hardcode window kinds; new ones should just appear.
2. **ccusage** (`zsh -lc 'ccusage blocks --active --json'`) — detail only (tokens, burn
   rate, projection). Its `$` is API-equivalent pricing, NOT the plan bill. Best-effort:
   the app must still work if ccusage is missing.

## Conventions

- Double-quoted strings, function-style SwiftUI views.
- The OAuth token is read fresh from the keychain every poll, never cached, never logged.
  It is sent only to `api.anthropic.com`. Treat it as a secret.
- GUI apps get a minimal PATH — always resolve external tools by absolute path or via a
  login shell (`/bin/zsh -lc …`). This is why ccusage runs through zsh.
- Dates: the endpoint returns ISO-8601 with 6-digit fractional seconds + offset; decode
  via the lenient `JSON.decoder` in Models.swift.
- **Commits:** stage + commit + push at the end of a working session without asking —
  standing authorization. Author stays Bryant (@zataara); never self-author.

## Build

```sh
./build.sh && open ClaudeUsageMonitor.app
```
