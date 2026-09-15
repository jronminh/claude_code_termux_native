# shellcheck shell=bash
# Shared helpers for install.sh / uninstall.sh — colored, numbered step
# banners with noisy command output suppressed to a log unless it fails.
# Meant to be sourced, not executed directly (no shebang, on purpose).
#
# Caller must set REPO_DIR, SCRIPT_NAME, and TOTAL before sourcing.

: "${LOG:=$(mktemp)}"
N=0

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'
  BLUE=$'\033[34m'; RESET=$'\033[0m'
else
  BOLD=''; DIM=''; RED=''; GREEN=''; BLUE=''; RESET=''
fi

on_err() {
  echo >&2
  echo "${RED}${BOLD}${SCRIPT_NAME} failed${RESET} at line $1" >&2
  echo "${DIM}  see the last output above, or the full log at: $LOG${RESET}" >&2
}
trap 'on_err $LINENO' ERR

fail() { echo "${RED}${BOLD}$*${RESET}" >&2; exit 1; }

# kernel_is_risky — true (exit 0) if the running kernel is >= 5.11. NOT a
# seccomp block: strace on a real crash shows no epoll_pwait2 syscall entry
# before the SIGSEGV. Bun's kernel-version gate decides at that threshold
# whether to attempt epoll_pwait2 at all, and routing that attempt through
# glibc's generic syscall() wrapper — in this patched-ELF/glibc-runner
# environment — faults on a TLS access before the syscall instruction ever
# runs. Fixed upstream in oven-sh/bun#32490 (raw-asm syscall, an
# "-android" release-string gate, and BUN_FEATURE_FLAG_DISABLE_EPOLL_PWAIT2).
# So this function alone only tells you the kernel is in the risk *zone* —
# pair it with epoll_fix_present() to know whether the installed binary
# actually needs to worry about it. See README ("Troubleshooting" #9).
# Kernel version is fixed at the device's original manufacture (Android's
# KMI ties vendor kernel modules to one kernel build), so an OS upgrade via
# OTA does NOT change it — the Android version shown in Settings tells you
# nothing here; only the real kernel does.
kernel_is_risky() {
  local kver kmajor kminor
  kver=$(uname -r)
  kmajor=$(printf '%s' "$kver" | cut -d. -f1)
  kminor=$(printf '%s' "$kver" | cut -d. -f2)
  [ "$kmajor" -eq "$kmajor" ] 2>/dev/null || return 1
  [ "$kminor" -eq "$kminor" ] 2>/dev/null || return 1
  [ "$kmajor" -gt 5 ] || { [ "$kmajor" -eq 5 ] && [ "$kminor" -ge 11 ]; }
}

# epoll_fix_present BINARY — true if BINARY carries the upstream fix for
# the epoll_pwait2 TLS-fault crash (oven-sh/bun#32490): the feature-flag
# string is only linked in on a Bun build that has the fix.
epoll_fix_present() {
  strings "$1" 2>/dev/null | grep -q BUN_FEATURE_FLAG_DISABLE_EPOLL_PWAIT2
}

# Markers delimiting our managed block inside the user's global
# ~/.claude/CLAUDE.md, which may contain unrelated content of their own
# above/below it that must never be touched.
CLAUDE_MD_BEGIN="<!-- claude-code-termux-native:begin -->"
CLAUDE_MD_END="<!-- claude-code-termux-native:end -->"

# claude_md_upsert TEMPLATE_FILE TARGET_FILE — insert TEMPLATE_FILE's
# content into TARGET_FILE if our markers aren't there yet, or replace the
# existing marked block in place if they are. Never touches anything
# outside the markers.
claude_md_upsert() {
  local tmpl="$1" target="$2"
  mkdir -p "$(dirname "$target")"
  touch "$target"
  if grep -qF "$CLAUDE_MD_BEGIN" "$target"; then
    awk -v begin="$CLAUDE_MD_BEGIN" -v end="$CLAUDE_MD_END" -v tmpl="$tmpl" '
      $0 == begin { while ((getline line < tmpl) > 0) print line; close(tmpl); skip=1; next }
      $0 == end   { skip=0; next }
      skip        { next }
      { print }
    ' "$target" > "$target.tmp" && mv "$target.tmp" "$target"
  else
    { [ -s "$target" ] && printf '\n'; cat "$tmpl"; } >> "$target"
  fi
}

# claude_md_remove TARGET_FILE — remove our marked block from TARGET_FILE
# if present; no-op otherwise. Never touches anything outside the markers.
claude_md_remove() {
  local target="$1"
  [ -e "$target" ] || return 0
  grep -qF "$CLAUDE_MD_BEGIN" "$target" || return 0
  awk -v begin="$CLAUDE_MD_BEGIN" -v end="$CLAUDE_MD_END" '
    $0 == begin { skip=1; next }
    $0 == end   { skip=0; next }
    skip        { next }
    { print }
  ' "$target" > "$target.tmp" && mv "$target.tmp" "$target"
}

# Marker embedded as a leading comment in the doctor-hook's SessionStart
# command, so install.sh/uninstall.sh can find and replace/remove exactly
# our entry via jq (`test($marker)` on the command string) without
# touching any other SessionStart hooks the user has of their own.
DOCTOR_HOOK_MARKER="claude-code-termux-native:doctor-hook"

# doctor_hook_command — the SessionStart hook body: runs doctor.sh, stays
# silent when everything's "ok:", and only surfaces a systemMessage +
# additionalContext (the full dump) when it spots one of doctor.sh's own
# problem-vocabulary tokens (MISMATCH:/RISK:/WARN:/MISSING/"not found"/
# "not patched?"/"could not determine") or its neutral recognition token
# (UPDATED: — the claude binary is a different build than last session,
# see doctor.sh's version-state block). autocheck.sh runs standalone on
# the installed machine with no access to this file, so it carries its own
# copy of this same heredoc — keep the two in sync by hand if this changes.
doctor_hook_command() {
  cat <<'EOF'
# claude-code-termux-native:doctor-hook
OUT=$(bash ~/.claude/claude-native/doctor.sh 2>&1); if printf '%s' "$OUT" | grep -qE 'MISMATCH:|RISK:|WARN:|MISSING|not found|not patched\?|could not determine|UPDATED:'; then jq -n --arg out "$OUT" '{systemMessage: "termux-doctor has something to report at session start — run bash ~/.claude/claude-native/doctor.sh to see it, or invoke the termux-doctor skill", hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $out}}'; fi
EOF
}

# shortp PATH — shorten an absolute path for display: $HOME -> ~, $PREFIX ->
# the literal string "$PREFIX" (the usual Termux convention). Only for
# printing; never use the result for actual file operations.
shortp() {
  local p="$1"
  # The literal ~ and $PREFIX below are the intended output (display
  # placeholders), not paths/variables meant to expand.
  # shellcheck disable=SC2088,SC2016
  case "$p" in
    "$HOME") printf '~' ;;
    "$HOME"/*) printf '~/%s' "${p#"$HOME"/}" ;;
    "$PREFIX"/*) printf '$PREFIX/%s' "${p#"$PREFIX"/}" ;;
    *) printf '%s' "$p" ;;
  esac
}

# Fixed width so the "ok"/"FAILED" column lines up across steps regardless
# of how long each step's description is.
STEP_DESC_WIDTH=62

# step_banner "description" — print just the "[n/N] description ...." part
# (dot-filled to STEP_DESC_WIDTH), no trailing newline, no ok/FAILED. For
# steps whose command needs to print its own live output before the
# ok/FAILED verdict shows — see install.sh's binary-download step.
step_banner() {
  local desc="$1"
  local pad=$(( STEP_DESC_WIDTH - ${#desc} ))
  [ "$pad" -lt 1 ] && pad=1
  local dots; dots=$(printf '%*s' "$pad" '' | tr ' ' '.')
  printf '%s[%d/%d]%s %s %s%s%s ' "${BLUE}${BOLD}" "$N" "$TOTAL" "$RESET" "$desc" "$DIM" "$dots" "$RESET"
}

# step "description" cmd [args...]
step() {
  N=$((N + 1))
  local desc="$1"; shift
  step_banner "$desc"
  if "$@" >>"$LOG" 2>&1; then
    printf '%sok%s\n' "$GREEN" "$RESET"
  else
    local rc=$?
    printf '%sFAILED%s\n' "$RED" "$RESET"
    echo "${DIM}--- last 30 lines of $LOG ---${RESET}"
    tail -n 30 "$LOG"
    echo "${DIM}-----------------------------${RESET}"
    exit "$rc"
  fi
}
