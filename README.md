# AI Usage Menu Bar

One lightweight macOS menu-bar app that shows **both** your Claude Code usage
**and** your Codex usage, side by side — live percentages, reset timers, and a
detailed dropdown for each. It merges two single-purpose utilities into a single
status item:

- **Claude Code usage** — reads the Claude Code keychain login and the Anthropic
  OAuth usage API (`/api/oauth/usage`), with automatic token refresh, a
  rate-limit cool-down, and a persisted last-good snapshot so the bar never
  flashes blank.
- **Codex usage** — reads the Codex app-server
  (`codex app-server --stdio` → `account/rateLimits/read`), falling back to the
  most recent `token_count` snapshot in `~/.codex/sessions/*.jsonl` when the
  app-server is unavailable.

```
 ☀ 98%   ◐ 100%
└Claude┘ └Codex┘
```

## Menu bar

The status item renders a compact readout per provider: the provider icon plus
its `% left` (or `% used`). The readout turns **orange at 75% used and red at
90%**, so a glance tells you when you're close to a limit. A click (left or
right) opens the dropdown:

- **Claude Code** — 5h and 7d usage as severity-colored progress bars, a 24h
  history sparkline, Weekly Opus/Sonnet breakdowns and pay-as-you-go extra
  usage when present, reset time, plan pill, last-updated.
- **Codex** — its real rate-limit windows (labeled from the actual window
  durations, e.g. 5h/7d) as progress bars, a 24h sparkline, credits / credit
  resets / monthly limit when present, reset time, plan pill, source
  (app-server vs. offline JSONL), last-updated.

## Usage alerts

macOS notifications fire once when a tracked window crosses **80%** used and
again at **95%**, then re-arm after the window resets. Toggle under
`Settings → Usage Alerts`.

## Settings (in the dropdown)

- **Show Percentage / Show Battery** — number, or a battery glyph per provider.
- **% Left / % Used** — which metric the bar and summaries show.
- **In Bar: Claude / In Bar: Codex** — toggle either provider out of the bar
  (e.g. show only Codex) while keeping its detail in the menu.
- **Claude Window: Session (5h) / Weekly (7d)** and **Codex Window: Daily /
  Weekly** — which window each provider's bar percentage tracks.
- **Show Reset Time / Show Countdown** and **Show Time In Menu Bar** — append
  the soonest reset across shown providers to the bar.
- **Usage Alerts** — enable/disable the 80%/95% notifications.
- **Refresh Every** — 30s / 1m / 3m / 5m (default 5m).
- **Launch at Login** — via `SMAppService` (macOS 13+).
- **Open Dashboard** — jump to claude.ai usage settings or chatgpt.com/codex.

## Build & install

```sh
# Build a universal (arm64 + x86_64) .app under .build/release/
bash scripts/build.sh

# Or build, copy to /Applications, and launch:
bash scripts/install.sh

# Remove it:
bash scripts/uninstall.sh
```

Requires macOS 13+ and the Xcode command-line tools (`clang`). No third-party
dependencies — a single Objective-C source file linked against Cocoa,
ServiceManagement, and Security.

## How it reads your data (and what it never does)

- Claude credentials are read from the `Claude Code-credentials` keychain item,
  exactly like the Claude Code CLI. Refreshed tokens are written back to the
  same item so the CLI and this app stay in sync. Nothing is sent anywhere
  except Anthropic's own OAuth/usage endpoints.
- Codex data is read locally — from the Codex app-server you already have
  installed, or from your own session logs. No Codex credentials are read or
  transmitted.

Both engines fail soft: if one provider is unavailable, the other still shows,
and the unavailable one reports the reason in its dropdown section.

## Credits

Combines and reimplements two utilities by
[@diegocp01](https://github.com/diegocp01):
[top_bar_claude_code_usage](https://github.com/diegocp01/top_bar_claude_code_usage)
and
[top_bar_codex_credits](https://github.com/diegocp01/top_bar_codex_credits).
