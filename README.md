# AirGap

A macOS menu-bar app that tracks screen time, blocks distracting apps and websites, and runs focus sessions. Everything stays on your Mac.

## Features

- **Screen time** per app and per website, for today or the last 7 days, with a daily chart and how often you opened each one. Time stops counting after 2 minutes without input.
- **Block list**: a whole site (`youtube.com`, subdomains included), one page (`youtube.com/shorts`), or an app. Any rule can have a daily limit instead, so it only blocks once you've used up your minutes.
- **Focus sessions**: write what you'll get done, pick a length, and only the sites and apps on your focus list stay open. Each blocked item can be let through once per session for a quick check. A short check-in at the end asks how it went.
- **Themes**: save a session you repeat (inbox triage, reading the news) with its length, checklist and focus list. *Reading* themes are a hard cap: no pausing and no quick checks.
- **Commitment locks**: lock a session, a theme or the block list for up to 30 days. While locked, Quit is hidden and the app relaunches if it's killed. The only way out is the one you chose up front: a 24-hour delay, or a code someone else holds.
- **Assistant** (optional): if you have [Claude Code](https://claude.com/claude-code) or the [Codex CLI](https://github.com/openai/codex) installed, it can plan a session, reflect on it afterwards, summarize your screen time, sort apps into categories, and decide whether a blocked page is worth opening for the reason you type (up to 3 approved *page passes* a day).

Websites are read and blocked in Safari, Chrome, Brave, Edge, Arc, Vivaldi and Opera through AppleScript. Firefox has no scripting interface, so it isn't supported.

## Install

AirGap is built from source on your Mac. You need Apple's Command Line Tools (`install.sh` offers to install them).

```bash
git clone https://github.com/arberiii/air-gap.git
cd air-gap
./install.sh
```

This builds the app, copies it to `/Applications/AirGap.app` and opens it. To update, run `git pull && ./install.sh`.

The first time AirGap reads a browser's tab, macOS asks for permission (System Settings → Privacy & Security → Automation). Each build gets a new ad-hoc signature, so macOS asks again after an update; `install.sh` resets the old permission so the prompt shows up instead of failing silently.

## Privacy

There is no server, account or telemetry. State lives in `~/Library/Application Support/AirGap/state.json`; settings live in the app's user defaults.

Two things leave your Mac:

- **Favicons.** Website icons in the screen time list are fetched from Google's favicon service (`google.com/s2/favicons`), which sees the host names of the sites you visit. They're cached in `~/Library/Caches/AirGap/favicons`.
- **Assistant requests**, only if you turn the assistant on. AirGap runs your own `claude` or `codex` CLI, which sends the prompt to Anthropic or OpenAI under your account. Depending on the feature, a prompt contains your session intention and check-in notes, app and site names with time totals, your block and focus lists, and for page passes the page's address and title, the reason you typed, and today's earlier passes. The CLI runs outside any project, with no tools, MCP servers, hooks or project settings.

## Limits

- Browser tabs are polled every 2 seconds, so a blocked page can flash briefly before it's replaced.
- A lock is meant to hold against a tired self, not a determined one. Anyone with a terminal can unload the watchdog (`launchctl bootout gui/$UID/com.arberiii.airgap.watchdog`), edit `state.json`, or move the clock forward. Turning AirGap off under System Settings → Login Items also stops the watchdog once the app has been force-quit.
- A partner code is stored as a salted SHA-256 hash, which a short code doesn't protect for long against someone who can read `state.json`. Partners should use a fresh code, not a real PIN or password.

## Develop

```bash
swift test                          # unit tests for AirGapCore
scripts/build-app.sh                # build/AirGap.app for this Mac
scripts/build-app.sh --universal    # arm64 + x86_64 (needs Xcode)
open build/AirGap.app
```

`AirGapCore` holds the logic that can be tested without AppKit: rule matching, limits, usage, grouping, sessions, themes, locks and prompts. `AirGap` is the app around it. [ARCHITECTURE.md](ARCHITECTURE.md) explains how the pieces fit together.

## License

[MIT](LICENSE)
