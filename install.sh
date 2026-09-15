#!/data/data/com.termux/files/usr/bin/bash
# Installs Claude Code natively on Termux/Android.
#
# What this actually does: downloads Anthropic's official linux-arm64
# build of the claude binary and patches its ELF interpreter to point at
# Termux's glibc (via glibc-runner), so the glibc-linked binary can run on
# top of Android's Bionic libc. This is a community workaround — Anthropic
# does not publish an android-arm64 build. See README.md for the full
# story of why each step below is necessary.
#
# Safe to re-run: every step is idempotent. To undo everything, see
# uninstall.sh.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="install.sh"
TOTAL=7
# shellcheck source=scripts/lib.sh
source "$REPO_DIR/scripts/lib.sh"

DEST="$HOME/.claude/claude-native"
BIN_DIR="$PREFIX/bin"
LD="$PREFIX/glibc/lib/ld-linux-aarch64.so.1"

check_platform() {
  [ "$(uname -m)" = "aarch64" ] || fail "this installer only supports aarch64 (found $(uname -m))"
  [ -n "${PREFIX:-}" ] && [ -n "${HOME:-}" ] || fail "doesn't look like Termux (PREFIX or HOME unset)"
  command -v pkg >/dev/null 2>&1 || fail "'pkg' not found — this installer is Termux-only"
}

install_packages() {
  # --force-confdef/--force-confold: this runs unattended (no TTY to answer
  # dpkg's "keep your modified conffile?" prompt), so auto-keep the existing
  # config instead of hanging/failing on upgrades like openssl's.
  local opts=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
  pkg install "${opts[@]}" glibc-repo &&
    pkg update -y &&
    pkg install "${opts[@]}" glibc patchelf jq curl ripgrep coreutils &&
    [ -e "$LD" ]
}

stage_scripts() {
  mkdir -p "$DEST"
  install -m 700 "$REPO_DIR/scripts/autocheck.sh" "$DEST/autocheck.sh"
  install -m 700 "$REPO_DIR/scripts/update.sh"    "$DEST/update.sh"
  install -m 700 "$REPO_DIR/scripts/doctor.sh"    "$DEST/doctor.sh"
}

install_wrapper() {
  install -m 700 "$REPO_DIR/scripts/claude-wrapper.sh" "$BIN_DIR/claude"
  install -m 700 "$REPO_DIR/scripts/termux-update-claude.sh" "$BIN_DIR/termux-update-claude"
}

wire_bashrc() {
  local bashrc="$HOME/.bashrc"
  touch "$bashrc"
  grep -qF 'claude-native/autocheck.sh' "$bashrc" ||
    printf '\nsource "%s/autocheck.sh"\n' "$DEST" >> "$bashrc"
}

disable_autoupdater() {
  mkdir -p "$HOME/.claude"
  local settings="$HOME/.claude/settings.json"
  [ -e "$settings" ] || echo '{}' > "$settings"
  local tmp; tmp=$(mktemp)
  jq '.env.DISABLE_AUTOUPDATER = "1"' "$settings" > "$tmp" && mv "$tmp" "$settings"
}

echo "${BOLD}claude-code-termux-native${RESET} — installing Claude Code natively on Termux"
echo

step "checking platform"                          check_platform
step "installing Termux packages"                 install_packages
step "staging self-repair scripts at $DEST"       stage_scripts

# Shown un-suppressed (not via step()): it prints its own clear one-line
# status ("Already on the latest version" / "Update successful: ..."), and
# reusing it here means the very first install and every later update go
# through the exact same, already-tested download/verify/patch path.
N=$((N + 1))
printf '%s[%d/%d]%s downloading and patching the claude binary ...\n' "${BLUE}${BOLD}" "$N" "$TOTAL" "$RESET"
bash "$DEST/update.sh" || fail "initial download/patch failed — run: bash $DEST/doctor.sh"

step "installing wrapper + termux-update-claude"  install_wrapper
step "wiring autocheck.sh into ~/.bashrc"          wire_bashrc
step "disabling the in-process autoupdater"        disable_autoupdater

rm -f "$LOG"
trap - ERR
echo
echo "${GREEN}${BOLD}✓ install complete${RESET}"
echo "  ${DIM}1.${RESET} open a NEW Termux session (or run: exec bash)"
echo "  ${DIM}2.${RESET} run: ${BOLD}claude${RESET}"
echo
echo "  verify anytime  : ${DIM}bash $DEST/doctor.sh${RESET}"
echo "  check for updates: ${DIM}termux-update-claude${RESET}"
echo "  uninstall        : ${DIM}bash $REPO_DIR/uninstall.sh${RESET}"
