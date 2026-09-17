#!/data/data/com.termux/files/usr/bin/bash
# Removes everything install.sh created. Safe to re-run (every step is a
# no-op if there's nothing left to remove).
#
# By default keeps the downloaded claude binary + manifest.json cached
# under ~/.claude/claude-native/, so a future install.sh doesn't have to
# re-download the ~300MB binary. Pass --full to wipe that too.
#
# Deliberately does NOT remove, with or without --full:
#   - the Termux packages install.sh installed (glibc, patchelf, jq,
#     ripgrep, ...) — they're shared with the rest of Termux, not
#     exclusively this project's to take away.
#   - this cloned repo directory — that's your call, see the final message.
set -euo pipefail

FULL=0
case "${1:-}" in
  "") ;;
  --full) FULL=1 ;;
  *) echo "usage: uninstall.sh [--full]" >&2; exit 2 ;;
esac

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="uninstall.sh"
TOTAL=10
# shellcheck source=scripts/lib.sh
source "$REPO_DIR/scripts/lib.sh"

DEST="$HOME/.claude/claude-native"
BIN_DIR="$PREFIX/bin"

remove_claude_native() {
  if [ "$FULL" = "1" ]; then
    rm -rf "$DEST"
  else
    # Keep claude/claude.prev/manifest.json* cached — they're the expensive
    # (~300MB) part to reproduce. Just clear out what made them "live".
    rm -f "$DEST"/autocheck.sh "$DEST"/update.sh "$DEST"/doctor.sh \
          "$DEST"/session-hooks.sh "$DEST"/claude-job-runner.sh \
          "$DEST"/.claude-native.lock "$DEST"/.repatch-history \
          "$DEST"/.doctor-last-versions "$DEST"/.pinned-version \
          "$DEST"/update-fail-*.log
  fi
}

remove_wrapper() {
  rm -f "$BIN_DIR/claude" "$BIN_DIR/termux-update-claude" "$BIN_DIR/termux-claude-job"
}

# Must run BEFORE remove_claude_native (--full) / remove_wrapper: cancels
# each job's real Android JobScheduler registration first, so nothing is
# left pointing at a stub script (~/.claude/claude-native/jobs/<name>.sh)
# that's about to disappear. Always removes the jobs/ dir (including
# --full-independent of the binary cache) since job definitions are live
# schedules, not an expensive-to-reproduce download like the binary is.
remove_scheduled_jobs() {
  if command -v termux-job-scheduler >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && [ -d "$DEST/jobs" ]; then
    local f id
    for f in "$DEST"/jobs/*.json; do
      [ -e "$f" ] || continue
      id=$(jq -r '.id' "$f" 2>/dev/null) || continue
      [ -n "$id" ] && termux-job-scheduler --cancel --job-id "$id" 2>/dev/null || true
    done
    # NOT --cancel-all: that would also cancel any unrelated
    # termux-job-scheduler job another tool on this device has scheduled —
    # termux-job-scheduler has no per-app job namespacing, so cancelling by
    # the specific job-id each of ours was registered under (same ids
    # `termux-claude-job` computes from the job name) is the only safe way
    # to remove exactly what we added.
  fi
  rm -rf "$DEST/jobs"
}

remove_bashrc_hook() {
  local bashrc="$HOME/.bashrc"
  [ -e "$bashrc" ] || return 0
  sed -i '\#claude-native/autocheck\.sh#d' "$bashrc"
}

remove_settings_key() {
  local settings="$HOME/.claude/settings.json"
  [ -e "$settings" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  cp -f "$settings" "$settings.bak"
  local tmp; tmp=$(mktemp)
  jq 'del(.env.DISABLE_AUTOUPDATER)' "$settings" > "$tmp" && mv "$tmp" "$settings"
}

remove_doctor_hook() {
  local settings="$HOME/.claude/settings.json"
  [ -e "$settings" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  cp -f "$settings" "$settings.bak"
  local tmp; tmp=$(mktemp)
  jq --arg marker "$DOCTOR_HOOK_MARKER" '
    .hooks.SessionStart = ((.hooks.SessionStart // [])
      | map(select(((.hooks // []) | map(.command // "") | any(test($marker))) | not)))
    | if (.hooks.SessionStart | length) == 0 then del(.hooks.SessionStart) else . end
    | if ((.hooks // {}) | length) == 0 then del(.hooks) else . end
  ' "$settings" > "$tmp" && mv "$tmp" "$settings"
}

remove_session_hooks() {
  local settings="$HOME/.claude/settings.json"
  [ -e "$settings" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  cp -f "$settings" "$settings.bak"
  local tmp; tmp=$(mktemp)
  jq --arg marker "$SESSION_HOOKS_MARKER" '
    def drop_ours(arr): arr | map(select(((.hooks // []) | map(.command // "") | any(test($marker))) | not));
    .hooks.UserPromptSubmit = drop_ours(.hooks.UserPromptSubmit // [])
    | .hooks.Stop = drop_ours(.hooks.Stop // [])
    | .hooks.Notification = drop_ours(.hooks.Notification // [])
    | if (.hooks.UserPromptSubmit | length) == 0 then del(.hooks.UserPromptSubmit) else . end
    | if (.hooks.Stop | length) == 0 then del(.hooks.Stop) else . end
    | if (.hooks.Notification | length) == 0 then del(.hooks.Notification) else . end
    | if ((.hooks // {}) | length) == 0 then del(.hooks) else . end
  ' "$settings" > "$tmp" && mv "$tmp" "$settings"
}

remove_claude_md() {
  claude_md_remove "$HOME/.claude/CLAUDE.md"
}

remove_skill() {
  rm -rf "$HOME/.claude/skills/termux-doctor"
}

# Must run BEFORE remove_claude_native: it reads $DEST/.keybindings-managed.json
# (written by install.sh's install_keybindings) to know exactly which
# bindings to strip back out of ~/.claude/keybindings.json, and
# remove_claude_native deletes that same file.
remove_keybindings() {
  keybindings_remove "$HOME/.claude/keybindings.json" "$DEST/.keybindings-managed.json"
}

echo "${BOLD}claude-code-termux-native${RESET} — uninstalling"
echo

step "removing Termux-friendly keybindings from ~/.claude/keybindings.json" remove_keybindings
step "cancelling scheduled claude jobs (termux-job-scheduler)"       remove_scheduled_jobs
if [ "$FULL" = "1" ]; then
  step "removing ~/.claude/claude-native (binary + everything in it)" remove_claude_native
else
  step "removing self-repair scripts (keeping the binary cached)"     remove_claude_native
fi
step "removing claude + termux-update-claude from \$PREFIX/bin"       remove_wrapper
step "removing the autocheck hook from ~/.bashrc"                     remove_bashrc_hook
step "removing DISABLE_AUTOUPDATER from ~/.claude/settings.json"      remove_settings_key
step "removing the doctor-hook SessionStart entry"                    remove_doctor_hook
step "removing the optional session hooks (wake-lock/notifications)"  remove_session_hooks
step "removing our section from ~/.claude/CLAUDE.md"                  remove_claude_md
step "removing the termux-doctor skill"                               remove_skill

rm -f "$LOG"
trap - ERR
echo
echo "${GREEN}${BOLD}uninstall complete${RESET}"
echo "  claude-code-termux-native has been removed, including the"
echo "  Termux-friendly keybindings merged into ~/.claude/keybindings.json."
echo
if [ "$FULL" = "1" ]; then
  echo "  The claude-native binary cache was also removed ($(shortp "$DEST"))."
  echo "  A future install.sh run will re-download the ~300MB binary."
else
  echo "  The binary stays cached at ${DIM}$(shortp "$DEST")/claude${RESET} —"
  echo "  a future install.sh run will reuse it instead of re-downloading ~300MB."
  echo "  Run ${BOLD}bash uninstall.sh --full${RESET} to remove that cache too."
fi
echo
echo "  Not touched (shared with the rest of Termux, not this project's to remove):"
echo "    - packages: glibc-repo, glibc, patchelf, jq, curl, ripgrep, git, gh"
echo "    - this cloned repo directory: ${DIM}$(shortp "$REPO_DIR")${RESET}"
echo "      (remove it yourself if you're not planning to reinstall: rm -rf $(shortp "$REPO_DIR"))"
echo
echo "  Open a NEW Termux session (or run: exec bash) so the removed wrapper/hook take effect."
