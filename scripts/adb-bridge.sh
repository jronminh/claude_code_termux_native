#!/data/data/com.termux/files/usr/bin/bash
# Staged to ~/.claude/claude-native/adb-bridge.sh by install.sh
# (unconditionally — like session-hooks.sh, staging is harmless since
# nothing here runs on its own). The adb-bridge SKILL + the Stop-hook
# reminder below are only wired when install.sh runs with
# --with-adb-bridge: this is a security-sensitive, opt-in capability, not
# something to surface by default. See skills/adb-bridge/SKILL.md and
# notes/termux-features-research.md ("4b") for the full story and the
# security posture.
#
# Thin wrapper around wireless ADB, paired from the device to itself (no
# computer needed — see the skill for pairing steps). Every subcommand is
# read-only or a single explicit action; nothing here polls or loops.
#
# Usage:
#   adb-bridge.sh status [--json]     connection status
#   adb-bridge.sh screenshot [PATH]   screencap -> pulled to PATH (default:
#                                      a tmp file under $TMPDIR), path printed
#   adb-bridge.sh dump [PATH]         uiautomator dump -> pulled to PATH
#                                      (exact bounds="[x1,y1][x2,y2]" per
#                                      element — more reliable than
#                                      computing taps off a screenshot)
#   adb-bridge.sh tap X Y             adb shell input tap
#   adb-bridge.sh swipe X1 Y1 X2 Y2 [MS]   adb shell input swipe
#   adb-bridge.sh logcat [LINES]      last LINES of the system log (default
#                                      500), one-shot dump, does not follow
#   adb-bridge.sh logcat-clear        clear the log buffer (do this before
#                                      reproducing an issue, then `logcat`)
#   adb-bridge.sh nag                 prints one line iff a device is
#                                      connected right now, silent
#                                      otherwise — used by the opt-in Stop
#                                      hook, never fails
set -u

TIMEOUT=5
REMOTE_TMP_DIR=/sdcard/Download

adb_ok() { command -v adb >/dev/null 2>&1; }

# connected_device — prints the first connected device's serial and
# succeeds, or fails silently (no message) if adb is missing or nothing is
# in "device" state (as opposed to "unauthorized"/"offline").
connected_device() {
  adb_ok || return 1
  timeout "$TIMEOUT" adb devices 2>/dev/null | awk 'NR>1 && $2=="device"{print $1; found=1} END{exit !found}'
}

require_device() {
  connected_device >/dev/null || { echo "no adb device connected — see the adb-bridge skill to pair" >&2; return 1; }
}

cmd_status() {
  local json=0
  [ "${1:-}" = "--json" ] && json=1
  if ! adb_ok; then
    if [ "$json" = "1" ]; then jq -n '{installed:false, connected:false, device:null}'
    else echo "adb not installed — pkg install android-tools"; fi
    return 0
  fi
  local dev; dev=$(connected_device)
  if [ "$json" = "1" ]; then
    jq -n --arg dev "${dev:-}" '{installed:true, connected: ($dev != ""), device: (if $dev == "" then null else $dev end)}'
  elif [ -n "$dev" ]; then
    echo "connected: $dev"
  else
    echo "adb installed, not connected"
  fi
}

cmd_screenshot() {
  local out="${1:-}"
  [ -n "$out" ] || out="${TMPDIR:-/tmp}/adb-screenshot-$(date +%s).png"
  require_device || return 1
  local remote="$REMOTE_TMP_DIR/.adb-bridge-$$.png"
  timeout 20 adb shell screencap -p "$remote" || { echo "screencap failed" >&2; return 1; }
  timeout 20 adb pull "$remote" "$out" >/dev/null || { echo "adb pull failed" >&2; adb shell rm -f "$remote" 2>/dev/null; return 1; }
  adb shell rm -f "$remote" 2>/dev/null
  echo "$out"
}

cmd_dump() {
  local out="${1:-}"
  [ -n "$out" ] || out="${TMPDIR:-/tmp}/adb-dump-$(date +%s).xml"
  require_device || return 1
  local remote="$REMOTE_TMP_DIR/.adb-bridge-$$.xml"
  timeout 20 adb shell uiautomator dump "$remote" || { echo "uiautomator dump failed" >&2; return 1; }
  timeout 20 adb pull "$remote" "$out" >/dev/null || { echo "adb pull failed" >&2; adb shell rm -f "$remote" 2>/dev/null; return 1; }
  adb shell rm -f "$remote" 2>/dev/null
  echo "$out"
}

cmd_tap() {
  local x="${1:-}" y="${2:-}"
  [ -n "$x" ] && [ -n "$y" ] || { echo "usage: adb-bridge.sh tap X Y" >&2; return 2; }
  require_device || return 1
  timeout "$TIMEOUT" adb shell input tap "$x" "$y"
}

cmd_swipe() {
  local x1="${1:-}" y1="${2:-}" x2="${3:-}" y2="${4:-}" ms="${5:-300}"
  [ -n "$x1" ] && [ -n "$y1" ] && [ -n "$x2" ] && [ -n "$y2" ] || { echo "usage: adb-bridge.sh swipe X1 Y1 X2 Y2 [MS]" >&2; return 2; }
  require_device || return 1
  timeout "$TIMEOUT" adb shell input swipe "$x1" "$y1" "$x2" "$y2" "$ms"
}

cmd_logcat() {
  local n="${1:-500}"
  require_device || return 1
  timeout 15 adb logcat -d -t "$n"
}

cmd_logcat_clear() {
  require_device || return 1
  timeout 10 adb logcat -c
}

# nag — best-effort, NEVER fails (always returns 0): used by the opt-in
# Stop hook, so it must never risk stalling a turn. Prints exactly one line
# iff a device is connected right now, nothing otherwise.
cmd_nag() {
  local dev; dev=$(connected_device 2>/dev/null) || return 0
  [ -n "$dev" ] || return 0
  echo "ADB is still connected ($dev) — if you're done using the adb-bridge skill, turn off Wireless debugging in Developer options."
  return 0
}

case "${1:-}" in
  status)       shift; cmd_status "$@" ;;
  screenshot)   shift; cmd_screenshot "$@" ;;
  dump)         shift; cmd_dump "$@" ;;
  tap)          shift; cmd_tap "$@" ;;
  swipe)        shift; cmd_swipe "$@" ;;
  logcat)       shift; cmd_logcat "$@" ;;
  logcat-clear) shift; cmd_logcat_clear "$@" ;;
  nag)          shift; cmd_nag "$@" ;;
  *)
    echo "usage: adb-bridge.sh {status [--json]|screenshot [PATH]|dump [PATH]|tap X Y|swipe X1 Y1 X2 Y2 [MS]|logcat [LINES]|logcat-clear|nag}" >&2
    exit 2
    ;;
esac
