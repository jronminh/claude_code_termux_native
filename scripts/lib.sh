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
