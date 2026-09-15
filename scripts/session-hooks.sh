#!/data/data/com.termux/files/usr/bin/bash
# Staged to ~/.claude/claude-native/session-hooks.sh by install.sh, wired
# into ~/.claude/settings.json's UserPromptSubmit/Stop/Notification hooks
# only when install.sh is run with --with-notifications (opt-in — this
# changes day-to-day interactive behavior, unlike the doctor.sh hook).
# See README.md ("Extra features" -> "Session hooks").
#
# Every action here is best-effort and NEVER fails the hook: each
# subcommand always exits 0, since Claude Code's docs don't document any
# safe way to recover a blocked Stop hook and this repo isn't going to
# guess at one. No-ops silently if termux-wake-lock/termux-notification
# aren't installed.
set -u

STATE_DIR="${TMPDIR:-/tmp}/claude-code-termux-native"
mkdir -p "$STATE_DIR" 2>/dev/null || true

# Claude Code passes one JSON object on the hook's stdin; read it once.
INPUT=$(cat 2>/dev/null || true)

# field NAME — top-level string field from $INPUT, empty if missing or if
# jq isn't available (install.sh already depends on jq, but this script
# can be invoked by hand too).
field() {
  command -v jq >/dev/null 2>&1 || { printf ''; return 0; }
  printf '%s' "$INPUT" | jq -r --arg k "$1" '.[$k] // empty' 2>/dev/null
}

state_file() {
  local sid; sid=$(field session_id)
  printf '%s/%s.since' "$STATE_DIR" "${sid:-unknown}"
}

# Long-task-finished threshold, in seconds. A Stop fires after every turn,
# not just long ones, so this keeps short back-and-forth chat quiet.
THRESHOLD=60

cmd_submit() {
  command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock 2>/dev/null
  # Sweep state files from crashed/never-stopped sessions so STATE_DIR
  # doesn't grow unbounded.
  find "$STATE_DIR" -name '*.since' -mmin +1440 -delete 2>/dev/null
  date +%s > "$(state_file)" 2>/dev/null
  return 0
}

cmd_stop() {
  command -v termux-wake-unlock >/dev/null 2>&1 && termux-wake-unlock 2>/dev/null
  command -v termux-notification >/dev/null 2>&1 || return 0
  local f started now elapsed
  f=$(state_file)
  [ -f "$f" ] || return 0
  started=$(cat "$f" 2>/dev/null || echo 0)
  rm -f "$f" 2>/dev/null
  now=$(date +%s)
  elapsed=$(( now - started ))
  [ "$elapsed" -ge "$THRESHOLD" ] || return 0
  local cwd; cwd=$(field cwd)
  termux-notification \
    --id claude-task-done \
    --title "Claude Code finished" \
    --content "Task took ${elapsed}s${cwd:+ in $(basename "$cwd")}" \
    2>/dev/null
  return 0
}

cmd_notify() {
  command -v termux-notification >/dev/null 2>&1 || return 0
  local ntype content
  ntype=$(field notification_type)
  case "$ntype" in
    permission_prompt) content="Waiting for permission" ;;
    idle_prompt)       content="Waiting for you" ;;
    agent_needs_input) content="A background agent needs input" ;;
    agent_completed)   content="A background agent finished" ;;
    *)                 content="${ntype:-notification}" ;;
  esac
  termux-notification --id claude-notify --title "Claude Code" --content "$content" 2>/dev/null
  return 0
}

case "${1:-}" in
  submit) cmd_submit ;;
  stop)   cmd_stop ;;
  notify) cmd_notify ;;
esac
exit 0
