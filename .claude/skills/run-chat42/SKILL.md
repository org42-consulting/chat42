---
name: run-chat42
description: Build, launch, drive, and screenshot Chat42, the native macOS SwiftUI chat app. Use when asked to run, start, launch, screenshot, smoke-test, or manually verify Chat42 — or to confirm a change works in the real app rather than only in tests.
---

# Running Chat42

Chat42 is a **native macOS SwiftUI app**. None of the usual agent harnesses apply:
there is no Electron main process for Playwright, no DOM for `chromium-cli`, and no
xvfb — this runs on a real macOS session with a real display.

The handle is `.claude/skills/run-chat42/driver.sh`, which wraps `open`,
AppleScript/System Events, and `screencapture`. **Use the driver rather than raw
`osascript`** — it encodes several traps that will otherwise cost you an hour (see
Gotchas).

All paths below are relative to the repo root.

## Prerequisites

macOS with the Xcode Command Line Tools. Xcode itself is not required.

```sh
swift --version          # must be 6.0+ (swift-jinja needs tools-version 6.0)
python3 --version        # for the mock backend
```

Swift 6.0 is a hard floor: `mlx-swift-examples` pulls `swift-jinja`, whose manifest
declares tools-version 6.0, and `swift format` only ships with the toolchain from
6.0. An older Xcode fails at dependency resolution, not at compile.

## Build

```sh
./.claude/skills/run-chat42/driver.sh build     # wraps ./build.sh
```

Produces `build/Chat42.app`, signed with a Developer ID if one is in the keychain
and ad-hoc otherwise.

## Run — agent path

```sh
D=.claude/skills/run-chat42/driver.sh

$D backup          # ALWAYS FIRST — snapshots the user's real conversations + settings
$D mock-start      # recording Ollama stand-in; points the app at it
$D launch          # kills stale copies, launches THIS bundle by absolute path
```

Then drive it. Everything below is a real transcript from this machine:

```sh
$D menuitems Model                 # -> Ollama, MLX, Gateway, ..., Regenerate
$D menu Model Ollama               # switch backend
$D shortcut n command              # ⌘N new chat
$D send "driver smoke test"        # type + Return
$D requests                        # what the app actually put on the wire
```

```
1 request(s) recorded
--- request 1  model=mock:latest  num_ctx=8192
    [system] 'You are a helpful AI assistant.'
    [user] 'driver smoke test'
```

Nested menus and screenshots:

```sh
$D menuitems File "New Chat from Preset"          # -> Code reviewer, Translate to Dutch, Commit message
$D submenu File "New Chat from Preset" "Code reviewer"
$D send "check this for bugs"
$D shot driver-verification                        # -> /tmp/chat42-shots/driver-verification.png (900x652)
```

**Look at the screenshot.** A blank frame means the app never drew — usually a modal
dialog (see Gotchas).

When finished:

```sh
$D restore         # quits app, puts conversations.json + ollamaBaseURL back, stops mock
```

### Asserting on behaviour

`$D requests` is the highest-value check. Chat42's job is to put the right things in
the request; whether a model then answers well is not its job. Assert on the payload,
not on model output — that is also why the mock exists rather than a real model.

For the same checks as a repeatable test suite, see `Tests/Chat42Tests/LivePipelineTests.swift`:

```sh
./scripts/mock-ollama.py --port 11500 --record /tmp/ollama-requests.jsonl &
CHAT42_MOCK_OLLAMA=http://127.0.0.1:11500 swift test --filter LivePipelineTests
```

## Run — human path

```sh
open -a "$PWD/build/Chat42.app"
```

Use the absolute path, never `open -b com.chat42.Chat42` — see Gotchas.

## Test

```sh
swift test                                                    # 81 tests, 5 skipped without the mock
swift format lint --recursive --strict Chat42/Sources Tests
./scripts/check-localization.sh
```

## Gotchas

**`tell application "Chat42"` launches the wrong app.** AppleScript resolves by
*name* and will start `/Applications/Chat42.app` — a different, older build — giving
you two instances and screenshots of code you did not just write. It cost real
confusion here: a Settings window appeared to be missing a feature that was in fact
present in the build under test. Always address by absolute path (`open -a "$PWD/build/Chat42.app"`)
or by pid. The driver does this throughout.

**Synthetic mouse clicks do not work.** `click at {x,y}` fails with
`osascript is not allowed assistive access (-25211)` unless the terminal has
Accessibility permission. What *does* work without it: `keystroke`, `key code`,
window `set position` / `set size`, and clicking **menu items** (an AX press, not a
synthetic event). So reach everything through menus and the keyboard — that is why
the driver has `menu`/`submenu`/`shortcut` but no `click`.

**`size of window 1 as text` returns garbage.** `{900, 652}` coerces to the string
`"900652"`, and `item 1 of (size of window 1)` errors with `-1700` because the
coercion binds to the whole expression. The form that works is to assign first:

```applescript
set s to size of window 1
return ((item 1 of s) as text) & "," & ((item 2 of s) as text)
```

**Screenshot the window where you put it, not where it says it is.** On a
multi-display setup, capturing `-R` at the window's *reported* position lands on the
wrong screen. `$D shot` moves the window to a known origin first, then captures
there.

**A modal keychain dialog can hide the whole app.** If `$D windows` reports nothing
but `$D health` shows the process alive, look at the screen: a SecurityAgent prompt
("Chat42 wants to use your confidential information") blocks it. It is
**deliberately not scriptable** — you cannot dismiss it with System Events, a human
must click it. It appears whenever the keychain ACL does not match the running
binary, which includes **every ad-hoc rebuild**, since each build has a new cdhash.
Choosing Deny is harmless for testing: the app just runs without a gateway API key.

**The app remembers its backend.** `activeBackend` is persisted, so it may reopen on
Gateway and never touch your mock Ollama — a send will fail with
`Error: Authentication failed` instead. Run `$D menu Model Ollama` after launching.

**Ollama with zero models pulled answers nothing.** `/api/tags` returns an empty
list, so no model can be selected and nothing sends. Use `$D mock-start` rather than
pulling a multi-gigabyte model.

**Driving the app writes to the user's real data.** `AppState` persists to
`~/Library/Application Support/Chat42/conversations.json`, and `LivePipelineTests`
constructs a real `AppState`. Run `$D backup` first and `$D restore` after, or you
will leave test conversations in someone's history.

**`backup` keeps the first snapshot; it does not re-take one.** This is deliberate
and was a real bug here: calling `backup` a second time mid-session overwrote the
clean snapshot with the dirty state, so `restore` faithfully put the test
conversations *back*. `mock-start` likewise refuses to record the mock URL as the
"original", which otherwise left the app pointed at a dead server after restore.
`restore` consumes the snapshot so the next session starts fresh. Use
`$D backup --force` only when you actually want to re-snapshot. Verify a clean
round-trip by comparing before/after:

```sh
python3 -c "import json,os;p=os.path.expanduser('~/Library/Application Support/Chat42/conversations.json');print(len(json.load(open(p))),'conv')"
defaults read com.chat42.Chat42 ollamaBaseURL
```

**Localized strings resolve differently in tests.** `String(localized:)` returns the
raw key (`default.system_prompt`) under `swift test`, because the test target has no
`.lproj` bundle — `build.sh` copies those into the `.app`. In the running app it
resolves correctly. Don't chase it as a bug; do rely on `check-localization.sh`
instead of unit tests for translation coverage.

**Entitlements plists must not contain XML comments.** `codesign` parses them with
`AMFIUnserializeXML`, which rejects comments and fails the build with
`syntax error near line N` — even though `plutil -lint` passes. Documentation for
those files lives in `Chat42/ENTITLEMENTS.md`.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `❌ Chat42 is not running` | `$D launch`. If it exits immediately, `$D health` for crash reports. |
| `$D windows` prints nothing, process alive | Modal keychain dialog — look at the screen, click Deny. |
| Screenshot is of Slack/another app | Something stole focus. `$D shot` re-fronts first; if it persists, close the offender. |
| Two Chat42 icons in the Dock | A stale `/Applications/Chat42.app` got launched by name. `pkill -x Chat42`, relaunch via `$D launch`. |
| `$D requests` shows 0 after sending | App is on the Gateway backend. `$D menu Model Ollama`. |
| `mock did not come up` | Port busy: `lsof -nP -iTCP:11500 -sTCP:LISTEN`, then `$D mock-stop`. |
| `error: Dependencies could not be resolved ... swift-jinja ... tools version (6.0)` | Toolchain older than Swift 6.0. `sudo xcode-select -s` a newer Xcode. |
| `unable to invoke subcommand: swift-format` | Same cause — `swift format` ships with Swift 6.0+. |
