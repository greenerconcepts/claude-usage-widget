---
name: claude-usage-widget
description: Build, install, fix, or customize the native macOS Claude usage widget (menu bar + floating glass panel showing session/weekly/per-model usage percentages with reset times). Use when the user asks to build or install the Claude usage widget, rebuild it on a new Mac, troubleshoot missing gauges, or change its look.
---

# Claude Usage Widget — build & install skill

You are setting up a native macOS widget that shows Claude plan usage: a menu bar item with three colored percentages, plus a draggable frosted-glass panel with bars and reset times. Everything needed is in this folder: `Sources/main.swift`, `build.sh`, `install.sh`.

## Quick path (works on any Mac with Xcode CLT)

1. `./install.sh` — builds from source with swiftc, installs to `/Applications/Claude Usage.app`, launches it. If `swiftc` is missing, have the user run `xcode-select --install` first.
2. The widget immediately shows **session** and **weekly all-models** percentages if the Claude desktop app is installed (it reads the app's local cache — see Data sources).
3. For the **per-model gauge (e.g. Fable) and exact reset times**, a Claude Code CLI sign-in must exist in the Keychain. If `security find-generic-password -s "Claude Code-credentials" -w` has no `claudeAiOauth` key: have the user run `claude` (install via `npm i -g @anthropic-ai/claude-code` if needed), choose "Claude account with subscription", authorize in the browser. Verify the key exists afterward — a user can *think* they signed in when the browser step never completed.
4. Menu bar ✳ → Refresh Now. macOS will ask to access "Claude Code-credentials" — user clicks **Always Allow**.

## Data sources (priority order — this is the hard-won knowledge)

1. **Usage API** — `GET https://api.anthropic.com/api/oauth/usage` with headers `Authorization: Bearer <accessToken>` and `anthropic-beta: oauth-2025-04-20`. The token lives in Keychain generic password, service `"Claude Code-credentials"`, JSON key `claudeAiOauth.accessToken`.
   - Parse the **`limits` array**, not the legacy top-level keys (those are often null): entries have `kind` (`"session"`, `"weekly_all"`, `"weekly_scoped"`), `percent` (int), `resets_at` (ISO8601 with microseconds — trim to milliseconds before parsing), and for `weekly_scoped` a `scope.model.display_name` (e.g. "Fable").
   - **READ-ONLY. Never refresh or rewrite this token.** Refresh tokens are single-use; if the widget refreshes, Claude Code's own refresh is rejected and the user gets logged out (this happened — repeatedly). Claude Code keeps itself logged in; the widget only reads. If the token is expired or the API returns 401, fall back to the local cache and wait.
2. **Desktop app cache** — `~/Library/Application Support/Claude/plan-usage-history.json`: `samples[].u.fh` = session %, `.sd` = weekly %. Sampled ~every 15 min while the app runs. Weekly reset time can be inferred from big drops in `sd` (resets happen at :59 — snap detected drop down to the previous :59).
3. **Session logs** — `~/.claude/projects/**/*.jsonl`: lines with `message.usage` carry a `timestamp`; 5-hour session windows open at the top of the hour of the first message after the prior window ends. Used only to estimate the session reset time when the API is unavailable. Read incrementally (track byte offsets, only complete lines).

## macOS gotchas that will bite you

- **Rounded corners on a blurred panel**: `layer.cornerRadius` does NOT clip `NSVisualEffectView`'s behind-window blur — the backdrop stays square. Use `maskImage` (a stretchable rounded-rect NSImage with capInsets).
- **Menu bar app**: `LSUIElement=true` in Info.plist + `NSApp.setActivationPolicy(.accessory)`.
- **Panel behavior**: borderless `NSPanel` with `.nonactivatingPanel`, `isFloatingPanel`, `level = .floating`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`, `canBecomeKey = false`.
- **Moving and resizing must both be explicit.** Borderless windows get NO automatic resize handling (`.resizable` in the style mask does nothing), and `isMovableByWindowBackground` silently stops working once an overlay view sits above the content. The `ResizeOverlay` view handles everything: clicks on edge/corner bands (~10pt) resize with manual frame math; clicks anywhere else on the card call `NSWindow.performDrag(with:)` for a native window move (works across screens). Cursor feedback additionally requires the private WindowServer flag `SetsCursorInBackground` (see `enableBackgroundCursor()`) because macOS ignores cursor changes from never-key windows.
- **Ad-hoc codesigning** (`codesign --force --sign -`): every rebuild is a "new app" to the Keychain, so the credentials prompt reappears after each rebuild. Expected; user clicks Always Allow again.
- **Efficiency**: FSEvents on the two data directories + a 60s UI timer + API poll at most every 5 min. Verified: 0.0% CPU idle, ~30 MB RSS.
- If screenshot/permission tooling can't find the app by name, Spotlight indexing may be off — the app still works; verify via `pgrep -x ClaudeUsage`.

## Verification checklist

1. `pgrep -x ClaudeUsage` → running.
2. Menu bar shows three percentages (or – for gauges not yet available).
3. Panel shows bars with reset times ("Resets 11:39 AM" / "Resets Mon 8:59 AM") matching the Claude app's Settings → Usage screen.
4. `ps -o pcpu,rss -p $(pgrep -x ClaudeUsage)` → ~0.0 CPU when idle.
5. No secrets in logs: `log show --predicate 'process == "ClaudeUsage"' --last 10m | grep -ci token` → 0.

## Customization pointers (Sources/main.swift)

- Colors: `Palette` enum (terracotta/ochre/sage; orange ≥70%, red ≥90%).
- Layout: `UsagePanel.init` — two equal columns (session+weekly left, model right).
- Poll cadences: `applicationDidFinishLaunching` (60s timer, 300s API gate).
- Default dock position: bottom-left of the main screen; frame persists in UserDefaults key `panelFrame3`.
