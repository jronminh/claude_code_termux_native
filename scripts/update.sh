#!/data/data/com.termux/files/usr/bin/bash
set -uo pipefail

BASE=https://downloads.claude.ai/claude-code-releases
DEST="$HOME/.claude/claude-native"
LD="$PREFIX/glibc/lib/ld-linux-aarch64.so.1"
LOCKFILE="$DEST/.claude-native.lock"
DOWNLOAD_OPTS=(--connect-timeout 5 --max-time 60)
# The claude binary is ~300MB. A flat --max-time is wrong for it on a slow
# mobile link — it aborts a download that's merely slow, not dead. Use
# --speed-limit/--speed-time instead: only abort if throughput actually
# stalls (stays below 1KB/s for 30s straight), no matter how long the
# whole transfer takes otherwise.
BIN_DOWNLOAD_OPTS=(--connect-timeout 5 --speed-limit 1024 --speed-time 30)
tmp=""

if [ "${1:-}" = "--rollback" ]; then
  if [ ! -e "$DEST/claude.prev" ]; then
    echo "No backup found at $DEST/claude.prev — nothing to roll back to." >&2
    exit 1
  fi
  exec 203>"$LOCKFILE"
  if ! flock -w 10 203; then
    echo "Another update/repair is in progress — try rollback again in a moment." >&2
    exit 1
  fi
  mv "$DEST/claude" "$DEST/claude.rejected" 2>/dev/null || true
  mv "$DEST/claude.prev" "$DEST/claude"
  [ -e "$DEST/manifest.json.prev" ] && mv "$DEST/manifest.json.prev" "$DEST/manifest.json"
  echo "Rolled back to the previous binary. Quit the running claude session and reopen it."
  exit 0
fi

CHECK_ONLY=0
[ "${1:-}" = "--check-only" ] && CHECK_ONLY=1

# --check-only: invoked automatically when Termux opens (autocheck.sh). Must
# be fast, silent on no-network/errors, and never download or install
# anything — just report whether a new version exists.
CHECK_OPTS=(--connect-timeout 3 --max-time 8)

report_fail() {
  local step="$1" detail="$2"
  if [ "$CHECK_ONLY" = "1" ]; then
    # check-only must not annoy the user with a full report every time
    # Termux opens without network — just one short line, then exit quietly.
    echo "Could not check for updates ($step) — skipping, terminal still works normally."
    exit 0
  fi
  local logfile="$DEST/update-fail-$(date +%Y%m%d-%H%M%S).log"
  {
    echo "=== claude-native update.sh FAILED ==="
    echo "Time      : $(date '+%Y-%m-%d %H:%M:%S %z')"
    echo "Failed at : $step"
    echo
    echo "--- Details ---"
    echo "$detail"
    echo
    echo "--- Relevant variables ---"
    echo "BASE=$BASE"
    echo "DEST=$DEST"
    echo "LD=$LD"
    echo "VER=${VER:-<not determined>}"
    echo "CURRENT=${CURRENT:-<not determined>}"
    echo
    echo "--- State of $DEST ---"
    ls -la "$DEST" 2>&1
    if [ -n "$tmp" ] && [ -d "$tmp" ]; then
      echo
      echo "--- State of temp dir $tmp ---"
      ls -la "$tmp" 2>&1
    fi
    echo
    echo "--- Disk space ---"
    df -h "$DEST" 2>&1
  } > "$logfile" 2>&1
  cat "$logfile" >&2
  echo "update.sh FAILED at step: $step" >&2
  echo "Full report saved to: $logfile" >&2
  [ -n "$tmp" ] && [ -d "$tmp" ] && rm -rf "$tmp"
  exit 1
}

run() {
  local desc="$1"; shift
  local out rc
  out=$("$@" 2>&1); rc=$?
  if [ $rc -ne 0 ]; then
    report_fail "$desc" "Command: $*
Exit code: $rc
Output:
$out"
  fi
  printf '%s' "$out"
}

[ -e "$LD" ] || report_fail "check loader" "Loader not found at $LD — glibc-runner may have changed its path. Run doctor.sh to re-probe."

if [ "$CHECK_ONLY" = "1" ]; then
  VER_OUT=$(curl -fsSL "${CHECK_OPTS[@]}" "$BASE/stable" 2>&1); VER_RC=$?
else
  VER_OUT=$(curl -fsSL "${DOWNLOAD_OPTS[@]}" "$BASE/stable" 2>&1); VER_RC=$?
fi
if [ $VER_RC -ne 0 ]; then
  report_fail "fetch latest version from $BASE/stable" "Command: curl -fsSL $BASE/stable
Exit code: $VER_RC
Output:
$VER_OUT"
fi
VER=$(printf '%s' "$VER_OUT" | tr -d '[:space:]')
[ -n "$VER" ] || report_fail "fetch latest version" "Server returned an empty string for $BASE/stable"

CURRENT=""
if [ -x "$DEST/claude" ] && [ -e "$LD" ]; then
  CURRENT=$("$LD" --library-path "$PREFIX/glibc/lib" "$DEST/claude" --version 2>/dev/null | awk '{print $1}')
fi

if [ "$CURRENT" = "$VER" ]; then
  [ "$CHECK_ONLY" = "1" ] || echo "Already on the latest version ($VER)."
  exit 0
fi

if [ "$CHECK_ONLY" = "1" ]; then
  echo "New version available: $VER. Run: termux-update-claude"
  exit 0
fi

echo "New version available: $VER. Downloading..."

# Locked from here on: this writes $DEST/claude, the same file autocheck.sh's
# self-heal may patchelf in place. Same lock file as autocheck.sh so the two
# never race each other.
exec 203>"$LOCKFILE"
if ! flock -w 10 203; then
  echo "Another update/repair is already running — try again in a moment." >&2
  exit 1
fi

tmp=$(mktemp -d)

run "download linux-arm64 binary" curl -fSL "${BIN_DOWNLOAD_OPTS[@]}" -o "$tmp/claude" "$BASE/$VER/linux-arm64/claude" >/dev/null
run "download manifest.json" curl -fSL "${DOWNLOAD_OPTS[@]}" -o "$tmp/manifest.json" "$BASE/$VER/manifest.json" >/dev/null

EXP=$(jq -r '.platforms["linux-arm64"].checksum' "$tmp/manifest.json" 2>/dev/null)
if [ -z "$EXP" ] || [ "$EXP" = "null" ]; then
  report_fail "read checksum from manifest.json" "Key .platforms[\"linux-arm64\"].checksum could not be read — the manifest structure may have changed.
manifest.json contents:
$(cat "$tmp/manifest.json" 2>&1)"
fi

ACTUAL=$(sha256sum "$tmp/claude" | awk '{print $1}')
if [ "$EXP" != "$ACTUAL" ]; then
  report_fail "verify checksum" "Expected: $EXP
Actual  : $ACTUAL"
fi

run "patchelf --set-interpreter" patchelf --set-interpreter "$LD" "$tmp/claude"
run "chmod +x" chmod +x "$tmp/claude"

[ -e "$DEST/claude" ] && run "back up previous binary" cp -p "$DEST/claude" "$DEST/claude.prev" >/dev/null
[ -e "$DEST/manifest.json" ] && run "back up previous manifest" cp -p "$DEST/manifest.json" "$DEST/manifest.json.prev" >/dev/null

run "install new binary" mv "$tmp/claude" "$DEST/claude"
run "install new manifest" mv "$tmp/manifest.json" "$DEST/manifest.json"
rm -rf "$tmp"
tmp=""

echo "Update successful: $VER."
echo "Previous binary kept at $DEST/claude.prev — roll back with: termux-update-claude --rollback"
echo "Quit the running claude session and reopen it to use the new version."
