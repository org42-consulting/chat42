#!/usr/bin/env bash
# driver.sh — launch and drive Chat42.app programmatically.
#
# Chat42 is a native macOS SwiftUI app, so none of the usual agent harnesses
# apply: there is no Electron main process to attach Playwright to, no DOM for
# chromium-cli, and no xvfb (we are on a real macOS session with a real display).
# The handle we do have is AppleScript/System Events plus `screencapture`.
#
# Two hard-won constraints shape everything below:
#
#   1. NEVER `tell application "Chat42"`. AppleScript resolves that by NAME and
#      will happily launch a *different* copy — /Applications/Chat42.app — giving
#      you two instances and screenshots of the wrong build. Always launch and
#      address the bundle by absolute path / pid.
#
#   2. Synthetic mouse clicks DO NOT WORK. `click at {x,y}` fails with
#      "osascript is not allowed assistive access (-25211)" unless the terminal
#      has Accessibility permission. Keystrokes, menu-item clicks (an AX action,
#      not a synthetic event), and window move/resize DO work without it. So the
#      driver reaches everything through menus and the keyboard.
#
# Usage:  ./.claude/skills/run-chat42/driver.sh <command> [args]
# Run     ./.claude/skills/run-chat42/driver.sh help   for the command list.

set -euo pipefail

UNIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
APP="${UNIT}/build/Chat42.app"
BUNDLE_ID="com.chat42.Chat42"
SHOTS="${CHAT42_SHOTS:-/tmp/chat42-shots}"
MOCK_PORT="${CHAT42_MOCK_PORT:-11500}"
MOCK_RECORD="${CHAT42_MOCK_RECORD:-/tmp/ollama-requests.jsonl}"
STATE_DIR="/tmp/chat42-driver-state"
STORE="${HOME}/Library/Application Support/Chat42/conversations.json"

mkdir -p "${SHOTS}" "${STATE_DIR}"

die() { echo "❌ $*" >&2; exit 1; }

app_pid() { pgrep -x Chat42 | head -1; }

require_running() {
  local pid
  pid="$(app_pid || true)"
  [ -n "${pid}" ] || die "Chat42 is not running. Run: $0 launch"
  echo "${pid}"
}

# Run an AppleScript against the running instance, addressed by pid so a stale
# /Applications copy can never be targeted by accident.
osa_proc() {
  local pid script
  pid="$(require_running)"
  script="$1"
  osascript <<APPLESCRIPT
tell application "System Events"
  tell (first process whose unix id is ${pid})
${script}
  end tell
end tell
APPLESCRIPT
}

cmd_build() {
  echo "Building ${APP} ..."
  (cd "${UNIT}" && ./build.sh) | tail -3
}

cmd_launch() {
  [ -d "${APP}" ] || die "${APP} not found. Run: $0 build"
  pkill -x Chat42 2>/dev/null || true
  sleep 1
  # `open -a <absolute path>` — not `open -b <bundle id>`, and never
  # `tell application "Chat42"`, both of which can resolve to another copy.
  open -a "${APP}"
  for _ in $(seq 1 20); do
    sleep 0.5
    [ -n "$(app_pid || true)" ] && break
  done
  local pid
  pid="$(app_pid || true)"
  [ -n "${pid}" ] || die "app did not start"
  sleep 3
  echo "launched pid=${pid} from $(ps -o command= -p "${pid}" | head -1)"
  cmd_windows
}

cmd_front() {
  local pid
  pid="$(require_running)"
  osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is ${pid}) to true"
  sleep 1
}

cmd_windows() {
  osa_proc '    set out to {}
    repeat with i from 1 to (count of windows)
      set end of out to (i as text) & ": " & (name of window i) & " " & (position of window i as text) & " " & (size of window i as text)
    end repeat
    return out' || echo "(no windows — the app may be blocked on a modal dialog; see Gotchas)"
}

# Screenshot the app window. The window is MOVED to a known origin first: reading
# its reported position and capturing there gives the wrong region on a
# multi-display setup, but capturing a region you just placed it in is reliable.
cmd_shot() {
  local name="${1:-shot}" idx="${2:-1}" x=80 y=100
  cmd_front
  osa_proc "    set position of window ${idx} to {${x}, ${y}}" >/dev/null
  sleep 1
  # Two traps here. `size of window N as text` concatenates {900, 652} into
  # "900652", and `item 1 of (size of window N)` errors (-1700) because the
  # coercion binds to the whole expression. Assigning to a variable first, then
  # indexing it, is the form that works.
  local dims w h
  dims="$(osa_proc "    set s to size of window ${idx}
    return ((item 1 of s) as text) & \",\" & ((item 2 of s) as text)")"
  w="${dims%%,*}"
  h="${dims##*,}"
  screencapture -x -o -R "${x},${y},${w},${h}" "${SHOTS}/${name}.png"
  echo "${SHOTS}/${name}.png (${w}x${h})"
}

cmd_fullshot() {
  local name="${1:-full}"
  cmd_front
  screencapture -x -o "${SHOTS}/${name}.png"
  echo "${SHOTS}/${name}.png"
}

cmd_type() {
  [ $# -ge 1 ] || die "usage: $0 type <text>"
  cmd_front
  osascript -e "tell application \"System Events\" to keystroke \"$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')\""
}

# Type then Return (key code 36) — the app's send shortcut.
cmd_send() {
  [ $# -ge 1 ] || die "usage: $0 send <text>"
  cmd_type "$1"
  sleep 0.5
  osascript -e 'tell application "System Events" to key code 36'
  sleep 3
}

cmd_key() {
  [ $# -ge 1 ] || die "usage: $0 key <keycode>   (36=Return 51=Delete 53=Esc)"
  cmd_front
  osascript -e "tell application \"System Events\" to key code $1"
}

cmd_shortcut() {
  [ $# -ge 1 ] || die "usage: $0 shortcut <char> [command|shift|option|control]..."
  local ch="$1"; shift
  local mods=""
  for m in "$@"; do mods="${mods}${m} down, "; done
  mods="${mods%, }"
  cmd_front
  if [ -n "${mods}" ]; then
    osascript -e "tell application \"System Events\" to keystroke \"${ch}\" using {${mods}}"
  else
    osascript -e "tell application \"System Events\" to keystroke \"${ch}\""
  fi
  sleep 1
}

# Menu items are clicked through the accessibility API (an AXPress action), which
# works even though synthetic mouse events do not.
cmd_menu() {
  [ $# -ge 2 ] || die "usage: $0 menu <MenuBarItem> <MenuItem>"
  cmd_front
  osa_proc "    click menu item \"$2\" of menu 1 of menu bar item \"$1\" of menu bar 1" >/dev/null
  sleep 1
  echo "clicked $1 > $2"
}

cmd_submenu() {
  [ $# -ge 3 ] || die "usage: $0 submenu <MenuBarItem> <MenuItem> <SubItem>"
  cmd_front
  osa_proc "    click menu item \"$3\" of menu 1 of menu item \"$2\" of menu 1 of menu bar item \"$1\" of menu bar 1" >/dev/null
  sleep 1
  echo "clicked $1 > $2 > $3"
}

cmd_menuitems() {
  [ $# -ge 1 ] || die "usage: $0 menuitems <MenuBarItem> [MenuItem]"
  if [ $# -ge 2 ]; then
    osa_proc "    return name of every menu item of menu 1 of menu item \"$2\" of menu 1 of menu bar item \"$1\" of menu bar 1"
  else
    osa_proc "    return name of every menu item of menu 1 of menu bar item \"$1\" of menu bar 1"
  fi
}

# --- Mock backend ----------------------------------------------------------
#
# Ollama with zero models pulled cannot answer anything, and a real model makes
# assertions fuzzy ("was the document in context, or did the model just guess?").
# The mock records exactly what Chat42 sent, which is the thing worth asserting.

cmd_mock_start() {
  pkill -f mock-ollama.py 2>/dev/null || true
  : > "${MOCK_RECORD}"
  nohup python3 "${UNIT}/scripts/mock-ollama.py" --port "${MOCK_PORT}" --record "${MOCK_RECORD}" \
    > /tmp/mock-ollama.log 2>&1 &
  # Poll rather than sleep-then-check: a single probe after a fixed sleep is
  # racy, and this failed intermittently on exactly that.
  local up=0
  for _ in $(seq 1 20); do
    if curl -sf --max-time 2 "http://127.0.0.1:${MOCK_PORT}/api/tags" >/dev/null 2>&1; then
      up=1; break
    fi
    sleep 0.5
  done
  [ "${up}" = 1 ] || die "mock did not come up; see /tmp/mock-ollama.log"
  # Point the app at it. Save the outgoing value first so `restore` can undo it.
  save_ollama_url
  defaults write "${BUNDLE_ID}" ollamaBaseURL -string "http://127.0.0.1:${MOCK_PORT}"
  echo "mock on :${MOCK_PORT}, recording ${MOCK_RECORD}; app pointed at it (relaunch to pick up)"
}

cmd_mock_stop() {
  pkill -f mock-ollama.py 2>/dev/null && echo "mock stopped" || echo "mock not running"
}

cmd_requests() {
  [ -f "${MOCK_RECORD}" ] || { echo "no recording at ${MOCK_RECORD}"; return; }
  python3 - "$MOCK_RECORD" <<'PY'
import json, sys
path = sys.argv[1]
lines = [l for l in open(path) if l.strip()]
print(f"{len(lines)} request(s) recorded")
for i, line in enumerate(lines, 1):
    r = json.loads(line)
    opts = r.get("options") or {}
    print(f"--- request {i}  model={r.get('model')}  num_ctx={opts.get('num_ctx')}")
    for m in r.get("messages", []):
        print(f"    [{m.get('role')}] {m.get('content','')!r}")
PY
}

# --- User-data protection --------------------------------------------------
#
# Driving the app (or the LivePipelineTests, which construct a real AppState)
# writes into the user's real conversation store and defaults. Snapshot first.

# The FIRST snapshot wins. Re-running backup mid-session used to overwrite the
# clean snapshot with the dirty state — test conversations and the mock URL — so
# restore then faithfully put the mess back. Use `backup --force` to re-snapshot
# deliberately.
cmd_backup() {
  local force="${1:-}"
  if [ -f "${STATE_DIR}/conversations.json" ] && [ "${force}" != "--force" ]; then
    echo "snapshot already exists (from $(date -r "${STATE_DIR}/conversations.json" '+%H:%M:%S')); keeping it. Use: $0 backup --force to replace"
    return 0
  fi
  [ -f "${STORE}" ] && cp "${STORE}" "${STATE_DIR}/conversations.json" && echo "backed up conversations.json" || echo "no store to back up"
  save_ollama_url
}

# Never record the mock as the "original" URL — that is how restore ended up
# leaving the app pointed at a server that is no longer running.
save_ollama_url() {
  local current
  current="$(defaults read "${BUNDLE_ID}" ollamaBaseURL 2>/dev/null || true)"
  case "${current}" in
    *":${MOCK_PORT}"*) echo "  (current URL is the mock; keeping previously saved original)" ;;
    "") : > "${STATE_DIR}/ollamaBaseURL" ;;
    *) printf '%s' "${current}" > "${STATE_DIR}/ollamaBaseURL" ;;
  esac
}

cmd_restore() {
  cmd_quit || true
  sleep 2
  if [ -f "${STATE_DIR}/conversations.json" ]; then
    cp "${STATE_DIR}/conversations.json" "${STORE}"
    echo "restored conversations.json"
  fi
  if [ -s "${STATE_DIR}/ollamaBaseURL" ]; then
    defaults write "${BUNDLE_ID}" ollamaBaseURL -string "$(cat "${STATE_DIR}/ollamaBaseURL")"
    echo "restored ollamaBaseURL=$(cat "${STATE_DIR}/ollamaBaseURL")"
  fi
  cmd_mock_stop
  # Consume the snapshot, so the next session's `backup` takes a fresh one.
  rm -f "${STATE_DIR}/conversations.json" "${STATE_DIR}/ollamaBaseURL"
}

cmd_quit() {
  local pid
  pid="$(app_pid || true)"
  [ -n "${pid}" ] || { echo "not running"; return 0; }
  osascript -e "tell application \"System Events\" to tell (first process whose unix id is ${pid}) to quit" 2>/dev/null || true
  sleep 2
  pkill -x Chat42 2>/dev/null || true
  echo "quit"
}

cmd_health() {
  local pid
  pid="$(app_pid || true)"
  if [ -n "${pid}" ]; then
    echo "running pid=${pid}: $(ps -o command= -p "${pid}" | head -1)"
  else
    echo "not running"
  fi
  local crashes
  crashes="$(find "${HOME}/Library/Logs/DiagnosticReports" -name 'Chat42*' -newermt '-10 minutes' 2>/dev/null | head -3)"
  [ -n "${crashes}" ] && echo "RECENT CRASH REPORTS:" && echo "${crashes}" || echo "no recent crash reports"
}

cmd_help() {
  sed -n '3,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

Commands:
  build                       ./build.sh -> build/Chat42.app
  launch                      kill stale copies, launch THIS bundle by path
  quit                        quit the app
  health                      pid, bundle path, recent crash reports
  windows                     list windows with position/size

  shot <name> [winIndex]      move window to a known origin, capture it
  fullshot <name>             whole-screen capture

  type <text>                 keystroke into the focused field
  send <text>                 type + Return (sends a message)
  key <keycode>               36=Return 51=Delete 53=Esc
  shortcut <c> [mods...]      e.g. shortcut n command    (⌘N)
                                   shortcut f command    (⌘F focus search)

  menuitems <Menu> [Item]     list a menu's (or submenu's) items
  menu <Menu> <Item>          click a menu item
  submenu <Menu> <Item> <Sub> click a nested item

  mock-start / mock-stop      recording Ollama stand-in; points app at it
  requests                    dump what the app actually sent

  backup / restore            protect (and put back) the user's real data
EOF
}

case "${1:-help}" in
  build) shift; cmd_build "$@" ;;
  launch) shift; cmd_launch "$@" ;;
  quit) shift; cmd_quit "$@" ;;
  health) shift; cmd_health "$@" ;;
  windows) shift; cmd_windows "$@" ;;
  front) shift; cmd_front "$@" ;;
  shot) shift; cmd_shot "$@" ;;
  fullshot) shift; cmd_fullshot "$@" ;;
  type) shift; cmd_type "$@" ;;
  send) shift; cmd_send "$@" ;;
  key) shift; cmd_key "$@" ;;
  shortcut) shift; cmd_shortcut "$@" ;;
  menu) shift; cmd_menu "$@" ;;
  submenu) shift; cmd_submenu "$@" ;;
  menuitems) shift; cmd_menuitems "$@" ;;
  mock-start) shift; cmd_mock_start "$@" ;;
  mock-stop) shift; cmd_mock_stop "$@" ;;
  requests) shift; cmd_requests "$@" ;;
  backup) shift; cmd_backup "$@" ;;
  restore) shift; cmd_restore "$@" ;;
  help|-h|--help) cmd_help ;;
  *) die "unknown command: $1 (try: $0 help)" ;;
esac
