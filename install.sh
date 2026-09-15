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
# Safe to re-run: every step is idempotent.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/.claude/claude-native"
BIN_DIR="$PREFIX/bin"
LD="$PREFIX/glibc/lib/ld-linux-aarch64.so.1"

fail() { echo "[install] FAILED: $*" >&2; exit 1; }
step() { echo "[install] $*"; }

step "checking platform..."
[ "$(uname -m)" = "aarch64" ] || fail "this installer only supports aarch64 (found $(uname -m))"
[ -n "${PREFIX:-}" ] && [ -n "${HOME:-}" ] || fail "doesn't look like Termux (PREFIX or HOME unset)"
command -v pkg >/dev/null 2>&1 || fail "'pkg' not found — this installer is Termux-only"

step "installing/upgrading required Termux packages (glibc-repo, glibc, patchelf, jq, curl, ripgrep)..."
# --force-confdef/--force-confold: this runs unattended (no TTY to answer
# dpkg's "keep your modified conffile?" prompt), so auto-keep the existing
# config instead of hanging/failing on upgrades like openssl's.
PKG_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
pkg install "${PKG_OPTS[@]}" glibc-repo
pkg update -y
pkg install "${PKG_OPTS[@]}" glibc patchelf jq curl ripgrep coreutils

[ -e "$LD" ] || fail "glibc loader not found at $LD after installing glibc-repo/glibc — see README troubleshooting"

step "staging self-repair scripts at $DEST ..."
mkdir -p "$DEST"
install -m 700 "$REPO_DIR/scripts/autocheck.sh" "$DEST/autocheck.sh"
install -m 700 "$REPO_DIR/scripts/update.sh"    "$DEST/update.sh"
install -m 700 "$REPO_DIR/scripts/doctor.sh"    "$DEST/doctor.sh"

step "downloading and patching the claude binary (this reuses update.sh, so the very first install and every later update go through the exact same, already-tested path)..."
bash "$DEST/update.sh" || fail "initial download/patch failed — see the log printed above, or run: bash $DEST/doctor.sh"

step "installing wrapper at $BIN_DIR/claude ..."
install -m 700 "$REPO_DIR/scripts/claude-wrapper.sh" "$BIN_DIR/claude"

step "installing termux-update-claude at $BIN_DIR/termux-update-claude ..."
install -m 700 "$REPO_DIR/scripts/termux-update-claude.sh" "$BIN_DIR/termux-update-claude"

step "wiring autocheck.sh into ~/.bashrc (self-heal + update-check on every new shell)..."
BASHRC="$HOME/.bashrc"
touch "$BASHRC"
if ! grep -qF 'claude-native/autocheck.sh' "$BASHRC"; then
  printf '\nsource "%s/autocheck.sh"\n' "$DEST" >> "$BASHRC"
fi

step "ensuring DISABLE_AUTOUPDATER=1 in ~/.claude/settings.json (blocks the in-process updater from overwriting the patched binary)..."
mkdir -p "$HOME/.claude"
SETTINGS="$HOME/.claude/settings.json"
[ -e "$SETTINGS" ] || echo '{}' > "$SETTINGS"
settmp=$(mktemp)
jq '.env.DISABLE_AUTOUPDATER = "1"' "$SETTINGS" > "$settmp" && mv "$settmp" "$SETTINGS"

echo
step "done."
echo "    Open a NEW Termux session (or run: exec bash) so the wrapper and"
echo "    autocheck hook take effect, then run: claude"
echo "    Verify the install anytime with: bash $DEST/doctor.sh"
echo "    Check for/apply updates by hand with: termux-update-claude"
