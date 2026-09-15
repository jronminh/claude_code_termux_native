#!/data/data/com.termux/files/usr/bin/bash
# Staged to ~/.claude/claude-native/doctor.sh by install.sh. One-shot
# diagnostic dump — run this first, before guessing, whenever something's
# broken. See README.md ("Manual verification").
#
# Usage:
#   doctor.sh          human-readable dump (default)
#   doctor.sh --json   same checks, one JSON object on stdout (needs jq)
#   doctor.sh --fix    run self-heal (same locked repair block autocheck.sh
#                      runs on every new shell) first, then the normal dump
JSON=0
FIX=0
for arg in "$@"; do
  case "$arg" in
    --json) JSON=1 ;;
    --fix) FIX=1 ;;
    *) echo "usage: doctor.sh [--json] [--fix]" >&2; exit 2 ;;
  esac
done

DOCTOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$HOME/.claude/claude-native/claude"
LD="$PREFIX/glibc/lib/ld-linux-aarch64.so.1"
WRAPPER="$PREFIX/bin/claude"

if [ "$FIX" = "1" ]; then
  if [ -f "$DOCTOR_DIR/autocheck.sh" ]; then
    bash "$DOCTOR_DIR/autocheck.sh"
  else
    echo "autocheck.sh not found next to doctor.sh — can't self-heal, showing diagnostics only." >&2
  fi
  [ "$JSON" = "1" ] || echo
fi

# emit KEY LABEL VALUE — text mode prints "== LABEL ==" + VALUE (which may
# be multi-line) exactly like before this was refactored; JSON mode just
# collects into R, keyed the same as the text section headers, and skips
# printing (JOBJ is built from R at the very end).
declare -A R
emit() {
  R["$1"]="$3"
  [ "$JSON" = "1" ] && return
  echo "$2"
  printf '%s\n' "$3"
}

emit arch "== arch ==" "$(uname -m)"

REPORTED_ABI=$(getprop ro.product.cpu.abi 2>/dev/null)
UNAME_ARCH=$(uname -m)
if [ -z "$REPORTED_ABI" ]; then
  ABI_MSG="getprop not available or no ro.product.cpu.abi — cannot cross-check"
elif [ "$REPORTED_ABI" = "arm64-v8a" ] && [ "$UNAME_ARCH" = "aarch64" ]; then
  ABI_MSG="ok: uname ($UNAME_ARCH) matches Android's reported ABI ($REPORTED_ABI)"
else
  ABI_MSG="MISMATCH: uname says $UNAME_ARCH but Android reports ABI $REPORTED_ABI — possible binary-translation layer (e.g. Chromebook/x86 ARM emulation); this repo's aarch64-only assumptions may not hold"
fi
emit abi_cross_check "== ABI cross-check (uname vs Android-reported) ==" "$ABI_MSG"

KVER=$(uname -r)
KMAJOR=$(printf '%s' "$KVER" | cut -d. -f1)
KMINOR=$(printf '%s' "$KVER" | cut -d. -f2)
if [ "$KMAJOR" -eq "$KMAJOR" ] 2>/dev/null && [ "$KMINOR" -eq "$KMINOR" ] 2>/dev/null \
   && { [ "$KMAJOR" -gt 5 ] || { [ "$KMAJOR" -eq 5 ] && [ "$KMINOR" -ge 11 ]; }; }; then
  if strings "$BIN" 2>/dev/null | grep -q BUN_FEATURE_FLAG_DISABLE_EPOLL_PWAIT2; then
    EPOLL_MSG="kernel $KVER is 5.11+ (would be at risk on an unpatched Bun)"$'\n'"ok: bundled Bun carries the upstream fix (flag string present in binary)"
  else
    EPOLL_MSG="kernel $KVER is 5.11+ (would be at risk on an unpatched Bun)"$'\n'"RISK: bundled Bun predates the fix (flag string absent) — see README.md \"Troubleshooting\" #9"
  fi
else
  EPOLL_MSG="ok: kernel $KVER is below the 5.11 risk threshold (moot regardless of Bun version)"
fi
emit epoll_risk "== kernel epoll_pwait2 risk (bun#32489, fixed upstream in bun#32490) ==" "$EPOLL_MSG"

emit prefix_home "== PREFIX / HOME ==" "$PREFIX"$'\n'"$HOME"

CLAUDE_PATH=$(command -v claude 2>/dev/null)
if [ -n "$CLAUDE_PATH" ]; then
  CLAUDE_ON_PATH_MSG="$CLAUDE_PATH"$'\n'"$(readlink -f "$CLAUDE_PATH")"
else
  CLAUDE_ON_PATH_MSG="not found on PATH"
fi
emit claude_on_path "== claude on PATH ==" "$CLAUDE_ON_PATH_MSG"

BIN_LS=$(ls -l "$BIN" 2>/dev/null)
emit binary "== binary ==" "${BIN_LS:-MISSING $BIN}"

emit file_type "== file type ==" "$(file "$BIN" 2>/dev/null)"

INTERP=$(patchelf --print-interpreter "$BIN" 2>/dev/null)
emit interpreter "== interpreter ==" "${INTERP:-not patched?}"

LOADER_LS=$(ls -l "$LD" 2>/dev/null)
emit loader "== loader exists? ==" "${LOADER_LS:-MISSING LOADER: $LD}"

LIBC_LS=$(ls "$PREFIX/glibc/lib/libc.so.6" 2>/dev/null)
emit libc "== libc.so.6 ==" "${LIBC_LS:-libc.so.6 not found}"

LEAKED=$(env | grep -i '^LD_')
emit leaked_ld_env "== leaked env LD_* ==" "${LEAKED:-clean}"

AUTOUPD=$(grep -s DISABLE_AUTOUPDATER "$WRAPPER" "$HOME/.claude/settings.json")
emit autoupdater_disabled "== autoupdater disabled? ==" "${AUTOUPD:-DISABLE_AUTOUPDATER NOT found — risk of being overwritten}"

SETTINGS_BAK="$HOME/.claude/settings.json.bak"
if [ -e "$SETTINGS_BAK" ]; then
  SETTINGS_BAK_MSG="backup exists: $SETTINGS_BAK ($(date -r "$SETTINGS_BAK" '+%Y-%m-%d %H:%M' 2>/dev/null))"$'\n'"restore with: cp $SETTINGS_BAK $HOME/.claude/settings.json"
else
  SETTINGS_BAK_MSG="no backup yet — one is taken automatically the next time install.sh, autocheck.sh, or uninstall.sh writes settings.json"
fi
emit settings_backup "== ~/.claude/settings.json backup ==" "$SETTINGS_BAK_MSG"

if command -v termux-notification >/dev/null 2>&1; then
  TERMUX_API_MSG="ok: termux-notification available — update-failure and repatch-escalation alerts will push a notification"
else
  TERMUX_API_MSG="not installed — update-failure/repatch-escalation alerts stay terminal-only. Optional: pkg install termux-api + install the Termux:API app from the same source as Termux itself"
fi
emit termux_api "== Termux:API notifications ==" "$TERMUX_API_MSG"

if grep -qs 'claude-code-termux-native:session-hooks' "$HOME/.claude/settings.json" 2>/dev/null; then
  SESSION_HOOKS_MSG="ok: wired (per-turn wake-lock + notifications) — installed with install.sh --with-notifications"
else
  SESSION_HOOKS_MSG="not wired — optional, opt-in. Run: bash install.sh --with-notifications (see README)"
fi
emit session_hooks "== Optional session hooks (wake-lock/notifications) ==" "$SESSION_HOOKS_MSG"

TT_VER=$(dpkg -s termux-tools 2>/dev/null | awk -F': ' '/^Version/{print $2}')
APT_SRC=$(cat "$PREFIX"/etc/apt/sources.list 2>/dev/null; cat "$PREFIX"/etc/apt/sources.list.d/*.list 2>/dev/null)
if printf '%s' "$APT_SRC" | grep -q 'termux\.dev'; then
  APT_MSG="ok: apt sources point at a current Termux mirror"
else
  APT_MSG="WARN: apt sources don't reference termux.dev — possible stale/Play-Store install (Play Store builds are frozen and unsupported; see README \"Troubleshooting\")"
fi
emit termux_freshness "== Termux build freshness ==" \
  "TERMUX_VERSION=${TERMUX_VERSION:-unset (older Termux, or var not exported — verify by hand)}"$'\n'"termux-tools=${TT_VER:-not found}"$'\n'"$APT_MSG"

GLIBC_VER=$(dpkg -s glibc 2>/dev/null | awk -F': ' '/^Version/{print $2}')
PATCHELF_VER=$(patchelf --version 2>/dev/null | awk '{print $2}')
CUR_VERSIONS="glibc=${GLIBC_VER:-?} patchelf=${PATCHELF_VER:-?}"
STATE="$HOME/.claude/claude-native/.doctor-last-versions"
LAST_VERSIONS=$(cat "$STATE" 2>/dev/null || true)
VERSIONS_MSG="$CUR_VERSIONS"
if [ -n "$LAST_VERSIONS" ] && [ "$LAST_VERSIONS" != "$CUR_VERSIONS" ]; then
  VERSIONS_MSG="$CUR_VERSIONS"$'\n'"CHANGED since last doctor.sh run (was: $LAST_VERSIONS) — re-verify the interpreter patch (trap #4)"
fi
printf '%s' "$CUR_VERSIONS" > "$STATE" 2>/dev/null
emit glibc_patchelf_versions "== glibc / patchelf versions (drift since last doctor.sh run) ==" "$VERSIONS_MSG"

MOUNT_LINE=$(awk -v h="$HOME" 'index(h, $2)==1 {print length($2), $0}' /proc/mounts 2>/dev/null | sort -n | tail -1)
if [ -z "$MOUNT_LINE" ]; then
  NOEXEC_MSG="could not determine mount options for \$HOME"
elif printf '%s' "$MOUNT_LINE" | grep -q noexec; then
  NOEXEC_MSG="RISK: \$HOME's filesystem is mounted noexec — binaries there cannot run"$'\n'"${MOUNT_LINE#* }"
else
  NOEXEC_MSG="ok: not noexec"
fi
emit home_noexec "== \$HOME mount options (noexec would break everything) ==" "$NOEXEC_MSG"

AVAIL_KB=$(df -Pk "$HOME" 2>/dev/null | awk 'NR==2{print $4}')
if [ -n "$AVAIL_KB" ]; then
  DISK_MSG="$((AVAIL_KB / 1024)) MiB available"
  [ "$AVAIL_KB" -lt 512000 ] && DISK_MSG="$DISK_MSG"$'\n'"WARN: under 500MiB free — the claude binary alone is ~330MB; a download/update may fail partway"
else
  DISK_MSG="could not determine free space"
fi
emit disk_space "== disk space free at \$HOME ==" "$DISK_MSG"

VER_OUT=$(claude --version 2>/dev/null)
if [ -z "$VER_OUT" ]; then
  VERSION_MSG="claude does not run — see items above"
else
  VER_STATE="$HOME/.claude/claude-native/.last-claude-version"
  PREV_SEEN="" LAST_SEEN=""
  if [ -f "$VER_STATE" ]; then
    PREV_SEEN=$(sed -n '1p' "$VER_STATE")
    LAST_SEEN=$(sed -n '2p' "$VER_STATE")
  fi
  VERSION_MSG="$VER_OUT"
  if [ -n "$LAST_SEEN" ] && [ "$LAST_SEEN" != "$VER_OUT" ]; then
    VERSION_MSG="$VER_OUT"$'\n'"UPDATED: claude binary changed since the last session-start check (was: $LAST_SEEN) — this session is running a different build than last time"
    PREV_SEEN="$LAST_SEEN"
  fi
  if [ -n "$LAST_SEEN" ] && [ "$LAST_SEEN" != "$VER_OUT" ] || [ -z "$LAST_SEEN" ]; then
    { printf '%s\n' "$PREV_SEEN"; printf '%s\n' "$VER_OUT"; } > "$VER_STATE" 2>/dev/null
  fi
fi
emit version "== version (recognizes a binary change since the last session-start check) ==" "$VERSION_MSG"

if [ "$JSON" = "1" ]; then
  JOBJ='{}'
  for key in "${!R[@]}"; do
    JOBJ=$(jq -cn --argjson o "$JOBJ" --arg k "$key" --arg v "${R[$key]}" '$o + {($k): $v}')
  done
  printf '%s\n' "$JOBJ"
fi
