# Claude Usage Widget for macOS

A sleek, native macOS widget that shows your Claude plan usage at a glance — in your menu bar and in a draggable frosted-glass panel you can dock anywhere.

**Menu bar:** three colored percentages — current session · weekly (all models) · weekly (top model, e.g. Fable).
**Panel:** the same three gauges with progress bars and exact reset times in your local timezone, matching Claude's own Usage screen.

- 100% native Swift/AppKit — no Electron, no dependencies, ~1 MB
- 0% CPU while idle, ~30 MB memory
- Updates automatically (file events + a light 5-minute API poll)
- Bars and numbers turn orange at 70%, red at 90%
- Drag it anywhere, stretch it to any width; it remembers its spot
- Optional Start-at-Login from the menu bar menu

## Install (2 minutes)

Requirements: macOS 13+, Xcode Command Line Tools (`xcode-select --install`), and a Claude subscription.

```bash
git clone https://github.com/maxmazur/claude-usage-widget.git
cd claude-usage-widget
./install.sh
```

That's it for the session + all-models gauges if you use the Claude desktop app.

**To enable the per-model gauge (Fable) and exact reset times**, the widget needs a Claude Code sign-in saved in your Keychain — one time:

```bash
npm install -g @anthropic-ai/claude-code   # skip if you already use Claude Code CLI
claude   # choose "Claude account with subscription", authorize in browser
```

Then click the ✳ sparkle in your menu bar → **Refresh Now**. When macOS asks whether Claude Usage may access "Claude Code-credentials", click **Always Allow**.

### Or let Claude Code install it for you

Paste this into Claude Code:

> Clone https://github.com/maxmazur/claude-usage-widget and set it up on my Mac. Follow the repo's SKILL.md.

## How it works

The widget reads three sources, best available wins:

1. **Anthropic's usage API** (`api.anthropic.com/api/oauth/usage`) — the exact percentages and reset timestamps the Claude app shows, including per-model weekly limits. Authenticated with your own Claude Code OAuth token from the macOS Keychain; the widget auto-refreshes the token and keeps the CLI's copy in sync.
2. **The Claude desktop app's local usage cache** (`~/Library/Application Support/Claude/plan-usage-history.json`) — session + weekly percentages, no sign-in needed.
3. **Claude Code's local session logs** (`~/.claude/projects/*.jsonl`) — used to estimate when your 5-hour session window resets.

## Privacy & security

- Your token never leaves your Mac except to call Anthropic's own API over HTTPS.
- Nothing is logged, stored, or sent anywhere else. No analytics, no third-party servers.
- You build the app from source on your own machine — no prebuilt binaries to trust.
- Read it yourself: it's one Swift file, [Sources/main.swift](Sources/main.swift).

## Uninstall

```bash
./uninstall.sh
```

## License

MIT — see [LICENSE](LICENSE).
