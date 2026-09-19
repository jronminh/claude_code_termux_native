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

WITH_NOTIFICATIONS=0
WITH_ADB_BRIDGE=0
for arg in "$@"; do
  case "$arg" in
    --with-notifications) WITH_NOTIFICATIONS=1 ;;
    --with-adb-bridge) WITH_ADB_BRIDGE=1 ;;
    *) echo "usage: install.sh [--with-notifications] [--with-adb-bridge]" >&2; exit 2 ;;
  esac
done

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="install.sh"
TOTAL=11
[ "$WITH_NOTIFICATIONS" = "1" ] && TOTAL=$((TOTAL + 1))
[ "$WITH_ADB_BRIDGE" = "1" ] && TOTAL=$((TOTAL + 1))
# shellcheck source=scripts/lib.sh
source "$REPO_DIR/scripts/lib.sh"

DEST="$HOME/.claude/claude-native"
BIN_DIR="$PREFIX/bin"
LD="$PREFIX/glibc/lib/ld-linux-aarch64.so.1"

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
  install -m 700 "$REPO_DIR/scripts/autocheck.sh"          "$DEST/autocheck.sh"
  install -m 700 "$REPO_DIR/scripts/update.sh"              "$DEST/update.sh"
  install -m 700 "$REPO_DIR/scripts/doctor.sh"              "$DEST/doctor.sh"
  install -m 700 "$REPO_DIR/scripts/session-hooks.sh"       "$DEST/session-hooks.sh"
  install -m 700 "$REPO_DIR/scripts/claude-job-runner.sh"   "$DEST/claude-job-runner.sh"
  install -m 700 "$REPO_DIR/scripts/adb-bridge.sh"          "$DEST/adb-bridge.sh"
  install -m 700 "$REPO_DIR/scripts/feature-hooks.sh"       "$DEST/feature-hooks.sh"
  install -m 700 "$REPO_DIR/scripts/claude-features.sh"     "$DEST/claude-features.sh"
  # Skill sources for features that install a skill (currently just
  # adb-bridge): staged unconditionally, same reasoning as adb-bridge.sh
  # itself, so `termux-claude-features enable adb-bridge` works later even
  # if --with-adb-bridge wasn't passed at install time (or the repo
  # checkout this ran from is long gone by then).
  mkdir -p "$DEST/skill-sources/adb-bridge"
  install -m 600 "$REPO_DIR/skills/adb-bridge/SKILL.md" "$DEST/skill-sources/adb-bridge/SKILL.md"
  # docs/ — staged so this detail is available on-device (read on demand,
  # zero token cost unless actually read) without needing the repo
  # checkout. CLAUDE.md.template points at docs/architecture.md instead of
  # growing itself; every *.md here is staged generically so adding a new
  # doc file to the repo never needs an install.sh edit.
  mkdir -p "$DEST/docs"
  for f in "$REPO_DIR"/docs/*.md; do
    install -m 600 "$f" "$DEST/docs/$(basename "$f")"
  done
}

install_wrapper() {
  install -m 700 "$REPO_DIR/scripts/claude-wrapper.sh" "$BIN_DIR/claude"
  install -m 700 "$REPO_DIR/scripts/termux-update-claude.sh" "$BIN_DIR/termux-update-claude"
  install -m 700 "$REPO_DIR/scripts/claude-job.sh" "$BIN_DIR/termux-claude-job"
  install -m 700 "$REPO_DIR/scripts/termux-claude-features.sh" "$BIN_DIR/termux-claude-features"
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

# Thin wrappers around feature-hooks.sh's enable_X functions (sourced via
# lib.sh -> scripts/feature-hooks.sh) — the same functions
# `termux-claude-features enable/disable` calls at runtime, so install.sh
# --with-X and the standalone command never drift apart. install.sh's own
# job here is only to back up settings.json first, same as every other
# settings.json-touching step in this file.
install_session_hooks() {
  enable_notifications
}

# Opt-in only (security-sensitive — see skills/adb-bridge/SKILL.md
# "Security posture"). adb-bridge.sh itself is always staged by
# stage_scripts regardless of this flag — staging alone is inert.
install_adb_bridge() {
  enable_adb_bridge "$REPO_DIR/skills/adb-bridge/SKILL.md"
}

install_claude_md() {
  claude_md_upsert "$REPO_DIR/CLAUDE.md.template" "$HOME/.claude/CLAUDE.md"
}

install_skill() {
  local dir="$HOME/.claude/skills/termux-doctor"
  mkdir -p "$dir"
  install -m 600 "$REPO_DIR/skills/termux-doctor/SKILL.md" "$dir/SKILL.md"
}

# Merges keybindings.json.template into ~/.claude/keybindings.json: a set
# of Termux-friendly rebinds for actions whose only default binding needs
# Shift (unreachable — Termux's extra-keys row has no Shift key) or a
# ctrl+x-prefixed two-tap chord, replaced/supplemented with single alt+key
# taps (alt reads as a plain, always-tappable extra key). See README.md
# ("Extra features" -> "Termux-friendly keybindings") for the full list
# and rationale. Not opt-in, unlike the other features below — this one's
# on by default.
install_keybindings() {
  keybindings_upsert "$REPO_DIR/keybindings.json.template" \
    "$HOME/.claude/keybindings.json" \
    "$DEST/.keybindings-managed.json"
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
step "merging Termux-friendly keybindings"                    install_keybindings
if [ "$WITH_NOTIFICATIONS" = "1" ]; then
  step "wiring optional Termux:API session hooks"               install_session_hooks
fi
if [ "$WITH_ADB_BRIDGE" = "1" ]; then
  step "wiring optional ADB bridge (skill + Stop-hook reminder)" install_adb_bridge
fi

rm -f "$LOG"
trap - ERR
echo
echo "${GREEN}${BOLD}install complete${RESET}"
echo "  ${DIM}1.${RESET} open a NEW Termux session (or run: exec bash)"
echo "  ${DIM}2.${RESET} run: ${BOLD}claude${RESET}"
echo
printf '  %-18s: %s\n' "verify anytime"    "${DIM}bash $(shortp "$DEST")/doctor.sh${RESET}"
printf '  %-18s: %s\n' "check for updates" "${DIM}termux-update-claude${RESET}"
printf '  %-18s: %s\n' "schedule a job"    "${DIM}termux-claude-job add <name> --prompt \"...\" --period-ms 900000${RESET}"
printf '  %-18s: %s\n' "toggle a feature"  "${DIM}termux-claude-features {status|enable|disable} <feature>${RESET}"
printf '  %-18s: %s\n' "uninstall"         "${DIM}bash $(shortp "$REPO_DIR")/uninstall.sh${RESET}"
echo
echo "  Environment notes were also added to ~/.claude/CLAUDE.md, and the"
echo "  termux-doctor skill was installed, so claude recognizes this setup"
echo "  (and its quirks) and knows how to self-diagnose from now on."
echo
echo "  A set of Termux-friendly keybindings was merged into"
echo "  ~/.claude/keybindings.json (alt+key alternatives for the actions"
echo "  whose only default needs Shift or a ctrl+x chord — see README)."

if [ "$WITH_NOTIFICATIONS" = "1" ]; then
  echo
  echo "  Session hooks were wired: a per-turn Termux wake-lock, plus"
  echo "  termux-notification alerts for permission/idle prompts and"
  echo "  long-finished tasks (needs the Termux:API app + termux-api for the"
  echo "  notifications; the wake-lock works with bare Termux either way)."
  echo "  Turn off anytime: ${BOLD}termux-claude-features disable notifications${RESET}."
else
  echo
  echo "  Tip: ${BOLD}termux-claude-features enable notifications${RESET} wires an optional"
  echo "  per-turn Termux wake-lock and Termux:API notifications (see README) —"
  echo "  no need to re-run install.sh for this."
fi

if [ "$WITH_ADB_BRIDGE" = "1" ]; then
  echo
  echo "  The adb-bridge skill was installed, and a Stop hook now reminds you"
  echo "  if a wireless ADB device is still connected when a turn ends. This is"
  echo "  security-sensitive (adb shell runs at the shell UID) — see the skill's"
  echo "  \"Security posture\" section before pairing a device."
  echo "  Turn off anytime: ${BOLD}termux-claude-features disable adb-bridge${RESET}."
else
  echo
  echo "  Tip: ${BOLD}termux-claude-features enable adb-bridge${RESET} lets Claude see and"
  echo "  drive the full Android screen via self-paired wireless ADB (screenshots,"
  echo "  exact-coordinate taps, full-system logcat) — opt-in, security-sensitive,"
  echo "  see README. No need to re-run install.sh for this."
fi

if kernel_is_risky && ! epoll_fix_present "$DEST/claude"; then
  echo
  echo "${DIM}note:${RESET} kernel $(uname -r) is 5.11+, and this build of claude predates"
  echo "  the upstream fix for a Bun TLS-fault crash on epoll_pwait2 (bun#32490) —"
  echo "  claude may segfault right at launch on some devices. The wrapper already"
  echo "  sets BUN_FEATURE_FLAG_DISABLE_EPOLL_PWAIT2=1 as a workaround; if it still"
  echo "  crashes, see README.md (\"Troubleshooting\" #9) or"
  echo "  https://github.com/gtbuchanan/claude-code-termux, which ships an LD_PRELOAD shim."
fi
