# How AirGap works

AirGap is one menu-bar-only SwiftUI process (`LSUIElement`, no Dock icon). A 2-second timer drives everything, and all state lives in one JSON file.

The package has two targets:

- **`AirGapCore`** is pure Foundation and unit tested. It decides everything that can be decided without side effects: rule matching, limits, usage totals, grouping, sessions, themes, locks, page passes, and the assistant's prompts and schemas.
- **`AirGap`** is the app. It holds the side effects: the timer, AppleScript, spawning the assistant CLI, windows, the LaunchAgent and disk. `AppState` is the single store the views observe.

## The tick

Every 2 seconds `AppState.step()`:

1. **Locks.** `tickLocks()` applies queued lock changes that are due, drops locks that ended, and keeps the watchdog in step.
2. **Countdown.** The running session ends when its time is up.
3. **Observe.** It reads the frontmost app from `NSWorkspace`. For a supported browser, `BrowserBridge` reads the active tab's URL over AppleScript.
4. **Count.** A new activity key (`web:<host>` or `app:<bundle id>`) counts as an open. If there was input within the idle cutoff, 2 seconds are added to the day's usage, to every matching rule's daily counter (even for items the user stopped tracking, so limits still work), and to the running session.
5. **Decide.** `BlockEvaluator` returns a reason to block, or nil.
6. **Enforce.** A website's tab is replaced with a `data:` block page. An app is hidden and a floating card says why.
7. **Save.** Ticks save at most every 30 seconds; every other change saves at once, with an atomic write.

## Blocking

First match wins:

| # | Condition | Reason |
|---|-----------|--------|
| 1 | A session is running and the app is not always allowed, on the focus list, or briefly allowed | `.focusApp` |
| 2 | A session is running and the page's host is not on the focus list or briefly allowed | `.focus` |
| 3 | A rule matches and has no daily limit | `.rule` |
| 4 | A rule matches and today's time for it reached its limit | `.limitReached` |

How rules match:

- **site:** the host or any subdomain (`www.` stripped, lowercased).
- **page:** the same host and path, and every query parameter in the rule is present.
- **app:** the exact bundle id.

Browsers, Finder, System Settings and a few system screens are never hidden. A browser's sites are filtered instead.

## Focus sessions

```
           start                         time up / End
  idle ─────────────▶ running ───────────────────────▶ check-in ──▶ history
                       │   ▲
                 pause │   │ resume
                       ▼   │
                      paused
```

- Starting snapshots the focus list onto the session, so later edits don't rewrite history.
- A one-off session ended within its first minute is a false start and is dropped.
- History keeps the last 200 one-off sessions. Themed runs are never trimmed, because a theme's *Last time* and trend read them.
- There are two kinds of focus list: the usual one and one per theme. Every edit goes through `setFocusList()`, which writes to whichever list is active and mirrors it into the running session.

## Commitment locks

A `CommitmentLock` has a scope (session, theme or block list), an end date, a way out (delay or partner code), and a list of pending changes. `LockPolicy` answers which lock, if any, stands in front of an edit. Every guarded edit goes through `AppState.guarded(by:else:)`:

- With no lock, the edit runs.
- Under a delay lock, a loosening change is queued and takes effect after 24 hours or when the lock ends, whichever comes first.
- Under a partner lock, the app asks for the code. The right code applies the change at once.
- Anything else is refused. Tightening edits, like adding a rule, are never blocked.

While any lock is active:

- `AppDelegate` refuses the app's own Quit. Logout, restart and shutdown still go through.
- `Watchdog` installs a LaunchAgent (`~/Library/LaunchAgents/com.arberiii.airgap.watchdog.plist`). It runs a `/bin/sh` loop that reopens the app every 5 seconds if it isn't running, and exits once the last lock has ended. The agent is unloaded and removed when no lock remains.

## Browsers

`BrowserBridge` talks to Safari and Chromium browsers (Chrome, Brave, Edge, Arc, Vivaldi, Opera) over AppleScript. The block page is a self-contained `data:text/html` URL with every dynamic value HTML-escaped.

- **No assistant:** during focus the page offers an `airgap://allow?url=…&browser=…` link for a quick check. The scheme is registered in `Info.plist` and handled by an Apple Event handler in `AppState`. The handler accepts only http(s) pages and ignores the link when an assistant is set up.
- **With an assistant:** the page shows a page-pass form instead. Browsers won't open a custom scheme from a script, so the form writes its fields into the tab's title behind a marker. The next tick reads the title, but only while the tab is still showing a `data:` block page.

## Assistant

`AgentCoach` runs the user's own CLI outside any project, so no `CLAUDE.md` or `AGENTS.md` leaks in, with a 120-second timeout:

```
claude -p --model <haiku|sonnet|opus> --tools "" --strict-mcp-config --no-session-persistence \
       --setting-sources "" --output-format json --system-prompt <…> --json-schema <schema> <prompt>
codex exec --output-schema <file> …   # MCP servers, hooks, plugins and the shell tool off, read-only sandbox
```

`Coach`, in Core, builds each prompt, holds its JSON schema, and decodes the answer. It also filters a plan's suggested focus list: no blocked items, no past distractions, and only apps the user has.

## Screen time grouping

`UsageGrouping` folds rows for display only. A site joins an app with the same name (Slack and `app.slack.com`, Claude and `claude.ai`); browsers are excluded. *Group with…* and *Separate* override the automatic match. Rules, limits and the log never see groups.

## Keys

Usage, sessions, groups and the not-tracked list all key items the same way:

```
web:<normalized host>     web:youtube.com
app:<bundle id>           app:com.tinyspeck.slackmacgap
```

Day keys are local-calendar `yyyy-MM-dd` strings.
