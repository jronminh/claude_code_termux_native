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
TOTAL=10
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
  if [ -e "$settings" ]; then
    cp -f "$settings" "$settings.bak"
  else
    echo '{}' > "$settings"
  fi
  local tmp; tmp=$(mktemp)
  jq '.env.DISABLE_AUTOUPDATER = "1"' "$settings" > "$tmp" && mv "$tmp" "$settings"
}

# Upsert-by-marker: drops any existing SessionStart entry carrying our
# marker (so a later install.sh run picks up a changed doctor_hook_command
# instead of leaving a stale copy behind), then appends the current one.
# Leaves every other hook the user has configured — SessionStart or
# otherwise — untouched.
install_doctor_hook() {
  mkdir -p "$HOME/.claude"
  local settings="$HOME/.claude/settings.json"
  if [ -e "$settings" ]; then
    cp -f "$settings" "$settings.bak"
  else
    echo '{}' > "$settings"
  fi
  local cmd tmp
  cmd=$(doctor_hook_command)
  tmp=$(mktemp)
  jq --arg cmd "$cmd" --arg marker "$DOCTOR_HOOK_MARKER" '
    .hooks = ((.hooks // {}) + {
      SessionStart: (
        ((.hooks.SessionStart // [])
          | map(select(((.hooks // []) | map(.command // "") | any(test($marker))) | not)))
        + [{"hooks": [{"type": "command", "command": $cmd, "timeout": 15, "statusMessage": "Running termux-doctor sanity check..."}]}]
      )
    })
  ' "$settings" > "$tmp" && mv "$tmp" "$settings"
}

install_claude_md() {
  claude_md_upsert "$REPO_DIR/CLAUDE.md.template" "$HOME/.claude/CLAUDE.md"
}

install_skill() {
  local dir="$HOME/.claude/skills/termux-doctor"
  mkdir -p "$dir"
  install -m 600 "$REPO_DIR/skills/termux-doctor/SKILL.md" "$dir/SKILL.md"
}

echo "${BOLD}claude-code-termux-native${RESET} — installing Claude Code natively on Termux"
echo

step "checking platform"                                    check_platform
step "installing Termux packages"                           install_packages
step "staging self-repair scripts at $(shortp "$DEST")"     stage_scripts

# update.sh's own output is shown un-suppressed, printed BEFORE this step's
# banner (unlike every other step): it prints its own clear one-line status
# ("Already on the latest version" / "Update successful: ...") and, on an
# actual download, live progress that can run for minutes — none of which
# should be hidden in the log like a normal step()'s output. Reusing
# update.sh here also means the very first install and every later update
# go through the exact same, already-tested download/verify/patch path.
N=$((N + 1))
bash "$DEST/update.sh" || fail "initial download/patch failed — run: bash $(shortp "$DEST")/doctor.sh"
step_banner "downloading and patching the claude binary"
printf '%sok%s\n' "$GREEN" "$RESET"

step "installing wrapper + termux-update-claude"            install_wrapper
step "wiring autocheck.sh into ~/.bashrc"                    wire_bashrc
step "disabling the in-process autoupdater"                  disable_autoupdater
step "wiring doctor.sh into a SessionStart hook"              install_doctor_hook
step "installing environment notes into ~/.claude/CLAUDE.md" install_claude_md
step "installing the termux-doctor skill"                    install_skill

rm -f "$LOG"
trap - ERR
echo
echo "${GREEN}${BOLD}install complete${RESET}"
echo "  ${DIM}1.${RESET} open a NEW Termux session (or run: exec bash)"
echo "  ${DIM}2.${RESET} run: ${BOLD}claude${RESET}"
echo
printf '  %-18s: %s\n' "verify anytime"    "${DIM}bash $(shortp "$DEST")/doctor.sh${RESET}"
printf '  %-18s: %s\n' "check for updates" "${DIM}termux-update-claude${RESET}"
printf '  %-18s: %s\n' "uninstall"         "${DIM}bash $(shortp "$REPO_DIR")/uninstall.sh${RESET}"
echo
echo "  Environment notes were also added to ~/.claude/CLAUDE.md, and the"
echo "  termux-doctor skill was installed, so claude recognizes this setup"
echo "  (and its quirks) and knows how to self-diagnose from now on."

if kernel_is_risky && ! epoll_fix_present "$DEST/claude"; then
  echo
  echo "${DIM}note:${RESET} kernel $(uname -r) is 5.11+, and this build of claude predates"
  echo "  the upstream fix for a Bun TLS-fault crash on epoll_pwait2 (bun#32490) —"
  echo "  claude may segfault right at launch on some devices. The wrapper already"
  echo "  sets BUN_FEATURE_FLAG_DISABLE_EPOLL_PWAIT2=1 as a workaround; if it still"
  echo "  crashes, see README.md (\"Troubleshooting\" #9) or"
  echo "  https://github.com/gtbuchanan/claude-code-termux, which ships an LD_PRELOAD shim."
fi
