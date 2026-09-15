# Shared helpers for install.sh / uninstall.sh — colored, numbered step
# banners with noisy command output suppressed to a log unless it fails.
# Meant to be sourced, not executed directly.
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

# shortp PATH — shorten an absolute path for display: $HOME -> ~, $PREFIX ->
# the literal string "$PREFIX" (the usual Termux convention). Only for
# printing; never use the result for actual file operations.
shortp() {
  local p="$1"
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

# step "description" cmd [args...]
step() {
  N=$((N + 1))
  local desc="$1"; shift
  local pad=$(( STEP_DESC_WIDTH - ${#desc} ))
  [ "$pad" -lt 1 ] && pad=1
  local dots; dots=$(printf '%*s' "$pad" '' | tr ' ' '.')
  printf '%s[%d/%d]%s %s %s%s%s ' "${BLUE}${BOLD}" "$N" "$TOTAL" "$RESET" "$desc" "$DIM" "$dots" "$RESET"
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
