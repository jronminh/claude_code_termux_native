#!/data/data/com.termux/files/usr/bin/bash
# Removes everything install.sh created. Safe to re-run (every step is a
# no-op if there's nothing left to remove).
#
# Deliberately does NOT remove:
#   - the Termux packages install.sh installed (glibc, patchelf, jq,
#     ripgrep, ...) — they're shared with the rest of Termux, not
#     exclusively this project's to take away.
#   - this cloned repo directory — that's your call, see the final message.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="uninstall.sh"
TOTAL=4
# shellcheck source=scripts/lib.sh
source "$REPO_DIR/scripts/lib.sh"

DEST="$HOME/.claude/claude-native"
BIN_DIR="$PREFIX/bin"

remove_claude_native() {
  rm -rf "$DEST"
}

remove_wrapper() {
  rm -f "$BIN_DIR/claude" "$BIN_DIR/termux-update-claude"
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
  local tmp; tmp=$(mktemp)
  jq 'del(.env.DISABLE_AUTOUPDATER)' "$settings" > "$tmp" && mv "$tmp" "$settings"
}

echo "${BOLD}claude-code-termux-native${RESET} — uninstalling"
echo

step "removing ~/.claude/claude-native (binary + self-repair scripts)" remove_claude_native
step "removing claude + termux-update-claude from \$PREFIX/bin"       remove_wrapper
step "removing the autocheck hook from ~/.bashrc"                     remove_bashrc_hook
step "removing DISABLE_AUTOUPDATER from ~/.claude/settings.json"      remove_settings_key

rm -f "$LOG"
trap - ERR
echo
echo "${GREEN}${BOLD}✓ uninstall complete${RESET}"
echo "  claude-code-termux-native has been removed."
echo
echo "  Not touched (shared with the rest of Termux, not this project's to remove):"
echo "    - packages: glibc-repo, glibc, patchelf, jq, curl, ripgrep, git, gh"
echo "    - this cloned repo directory: ${DIM}$REPO_DIR${RESET}"
echo "      (remove it yourself if you're not planning to reinstall: rm -rf $REPO_DIR)"
echo
echo "  Open a NEW Termux session (or run: exec bash) so the removed wrapper/hook take effect."
