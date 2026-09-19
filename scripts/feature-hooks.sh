# shellcheck shell=bash
# Meant to be sourced, not executed directly (no shebang, on purpose) —
# same convention as lib.sh. Unlike lib.sh, this file IS staged to
# ~/.claude/claude-native/feature-hooks.sh by install.sh (unconditionally),
# because it's sourced from TWO different places:
#   1. scripts/lib.sh sources the REPO copy, so install.sh/uninstall.sh get
#      these functions at install/uninstall time (repo path known).
#   2. scripts/claude-features.sh sources the STAGED copy at
#      ~/.claude/claude-native/feature-hooks.sh, so the standalone
#      `termux-claude-features` command can enable/disable a feature long
#      after the repo checkout is gone, moved, or out of date.
# This is the ONE place that knows how to wire/unwire each opt-in
# feature's settings.json hooks (+ the adb-bridge skill file) — install.sh,
# uninstall.sh, and claude-features.sh all just call the functions below
# instead of each hand-rolling their own jq. Keep it self-contained: no
# dependency on anything else in lib.sh (colors, step banners, ...), since
# claude-features.sh sources ONLY this file, not the rest of lib.sh.

# hook_upsert_entry SETTINGS EVENT MARKER ENTRY_JSON — drops any existing
# entry in .hooks[EVENT] whose command matches MARKER (a regex, via jq
# `test()`), then appends ENTRY_JSON. Never touches entries for other
# events or other markers — safe to call repeatedly (re-run replaces,
# never duplicates) and safe alongside unrelated hooks the user configured
# by hand or via a different feature's marker.
hook_upsert_entry() {
  local settings="$1" event="$2" marker="$3" entry="$4"
  mkdir -p "$(dirname "$settings")"
  if [ -e "$settings" ]; then
    cp -f "$settings" "$settings.bak"
  else
    echo '{}' > "$settings"
  fi
  local tmp; tmp=$(mktemp)
  jq --argjson entry "$entry" --arg marker "$marker" --arg event "$event" '
    .hooks = ((.hooks // {}) + {
      ($event): (
        ((.hooks[$event] // [])
          | map(select(((.hooks // []) | map(.command // "") | any(test($marker))) | not)))
        + [$entry]
      )
    })
  ' "$settings" > "$tmp" && mv "$tmp" "$settings"
}

# hook_remove SETTINGS EVENT MARKER — inverse of hook_upsert_entry. No-op
# if SETTINGS or jq don't exist. Cleans up the now-empty EVENT array and
# .hooks object itself, same as install.sh's original per-feature removers
# did, so a fully-uninstalled settings.json doesn't accumulate empty `{}`s.
hook_remove() {
  local settings="$1" event="$2" marker="$3"
  [ -e "$settings" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  cp -f "$settings" "$settings.bak"
  local tmp; tmp=$(mktemp)
  jq --arg marker "$marker" --arg event "$event" '
    .hooks[$event] = ((.hooks[$event] // [])
      | map(select(((.hooks // []) | map(.command // "") | any(test($marker))) | not)))
    | if (.hooks[$event] | length) == 0 then del(.hooks[$event]) else . end
    | if ((.hooks // {}) | length) == 0 then del(.hooks) else . end
  ' "$settings" > "$tmp" && mv "$tmp" "$settings"
}

# --- notifications feature (session-hooks.sh: wake-lock + Termux:API notifications) ---

SESSION_HOOKS_MARKER="claude-code-termux-native:session-hooks"

session_hooks_submit_command() {
  cat <<'EOF'
# claude-code-termux-native:session-hooks
~/.claude/claude-native/session-hooks.sh submit
EOF
}

session_hooks_stop_command() {
  cat <<'EOF'
# claude-code-termux-native:session-hooks
~/.claude/claude-native/session-hooks.sh stop
EOF
}

session_hooks_notify_command() {
  cat <<'EOF'
# claude-code-termux-native:session-hooks
~/.claude/claude-native/session-hooks.sh notify
EOF
}

enable_notifications() {
  local settings="$HOME/.claude/settings.json"
  local submit stop notify
  submit=$(session_hooks_submit_command)
  stop=$(session_hooks_stop_command)
  notify=$(session_hooks_notify_command)
  hook_upsert_entry "$settings" UserPromptSubmit "$SESSION_HOOKS_MARKER" \
    "$(jq -n --arg cmd "$submit" '{"hooks":[{"type":"command","command":$cmd,"timeout":10}]}')"
  hook_upsert_entry "$settings" Stop "$SESSION_HOOKS_MARKER" \
    "$(jq -n --arg cmd "$stop" '{"hooks":[{"type":"command","command":$cmd,"timeout":10}]}')"
  hook_upsert_entry "$settings" Notification "$SESSION_HOOKS_MARKER" \
    "$(jq -n --arg cmd "$notify" '{"matcher":"permission_prompt|idle_prompt|agent_needs_input|agent_completed","hooks":[{"type":"command","command":$cmd,"async":true,"timeout":10}]}')"
}

disable_notifications() {
  local settings="$HOME/.claude/settings.json"
  hook_remove "$settings" UserPromptSubmit "$SESSION_HOOKS_MARKER"
  hook_remove "$settings" Stop "$SESSION_HOOKS_MARKER"
  hook_remove "$settings" Notification "$SESSION_HOOKS_MARKER"
}

notifications_wired() {
  grep -qs "$SESSION_HOOKS_MARKER" "$HOME/.claude/settings.json" 2>/dev/null
}

# --- adb-bridge feature (adb-bridge.sh + the adb-bridge skill) ---

ADB_BRIDGE_HOOK_MARKER="claude-code-termux-native:adb-bridge-hook"

adb_bridge_stop_hook_command() {
  cat <<'EOF'
# claude-code-termux-native:adb-bridge-hook
OUT=$(~/.claude/claude-native/adb-bridge.sh nag 2>/dev/null); if [ -n "$OUT" ]; then jq -n --arg out "$OUT" '{systemMessage: $out, hookSpecificOutput: {hookEventName: "Stop", additionalContext: $out}}'; fi
EOF
}

# enable_adb_bridge SKILL_SRC — SKILL_SRC is the adb-bridge SKILL.md to
# install: the repo's own copy when called from install.sh, or the copy
# install.sh staged at ~/.claude/claude-native/skill-sources/adb-bridge/
# SKILL.md when called from claude-features.sh (repo may be long gone).
enable_adb_bridge() {
  local skill_src="$1"
  [ -n "$skill_src" ] && [ -f "$skill_src" ] || {
    echo "adb-bridge skill source not found: ${skill_src:-<none given>}" >&2
    return 1
  }
  local dir="$HOME/.claude/skills/adb-bridge"
  mkdir -p "$dir"
  install -m 600 "$skill_src" "$dir/SKILL.md"
  local cmd; cmd=$(adb_bridge_stop_hook_command)
  hook_upsert_entry "$HOME/.claude/settings.json" Stop "$ADB_BRIDGE_HOOK_MARKER" \
    "$(jq -n --arg cmd "$cmd" '{"hooks":[{"type":"command","command":$cmd,"timeout":10}]}')"
}

disable_adb_bridge() {
  rm -rf "$HOME/.claude/skills/adb-bridge"
  hook_remove "$HOME/.claude/settings.json" Stop "$ADB_BRIDGE_HOOK_MARKER"
}

adb_bridge_wired() {
  grep -qs "$ADB_BRIDGE_HOOK_MARKER" "$HOME/.claude/settings.json" 2>/dev/null
}
