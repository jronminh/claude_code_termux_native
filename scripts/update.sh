#!/data/data/com.termux/files/usr/bin/bash
# Staged to ~/.claude/claude-native/update.sh by install.sh (and by
# install.sh's own first run, to download the initial binary). Invoked as
# `termux-update-claude` by hand, or with --check-only from autocheck.sh
# on every new shell. See README.md ("Update / rollback").
set -uo pipefail

BASE=https://downloads.claude.ai/claude-code-releases
DEST="$HOME/.claude/claude-native"
DEST_SHOW="${DEST/#$HOME/\~}"  # display-only, shortened form of $DEST
LD="$PREFIX/glibc/lib/ld-linux-aarch64.so.1"
LOCKFILE="$DEST/.claude-native.lock"
DOWNLOAD_OPTS=(--connect-timeout 5 --max-time 60)
# The claude binary is ~300MB. A flat --max-time is wrong for it on a slow
# mobile link — it aborts a download that's merely slow, not dead. Use
# --speed-limit/--speed-time instead: only abort if throughput actually
# stalls (stays below 1KB/s for 30s straight), no matter how long the
# whole transfer takes otherwise.
#
# --retry-all-errors --retry 5 -C -: a flaky mobile link can drop the
# connection outright (curl exit 56, "Recv failure") partway through a
# 300MB transfer — not one of the handful of "transient" codes --retry
# alone treats as retryable, so --retry-all-errors is needed to actually
# retry on it. -C - resumes from the bytes already on disk instead of
# restarting from zero, so a drop at 250MB costs seconds, not minutes.
BIN_DOWNLOAD_OPTS=(--connect-timeout 5 --speed-limit 1024 --speed-time 30 --retry 5 --retry-delay 3 --retry-all-errors -C -)
tmp=""

if [ "${1:-}" = "--rollback" ]; then
  if [ ! -e "$DEST/claude.prev" ]; then
    echo "No backup found at $DEST_SHOW/claude.prev — nothing to roll back to." >&2
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
  local logfile; logfile="$DEST/update-fail-$(date +%Y%m%d-%H%M%S).log"
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

# The binary is ~300MB, which can take minutes on a slow link. run() would
# hide all output until it's done, which looks indistinguishable from
# hung. Download in the background instead and print how much of $dest has
# landed on disk so far, so a slow-but-alive transfer is visibly different
# from a stuck one.
download_binary() {
  local url="$1" dest="$2"
  local errlog; errlog=$(mktemp)
  curl -fSL "${BIN_DOWNLOAD_OPTS[@]}" -o "$dest" "$url" >"$errlog" 2>&1 &
  local pid=$! start
  start=$(date +%s)
  while kill -0 "$pid" 2>/dev/null; do
    local size=0 mb elapsed
    [ -f "$dest" ] && size=$(wc -c < "$dest" 2>/dev/null)
    mb=$(( ${size:-0} / 1048576 ))
    elapsed=$(( $(date +%s) - start ))
    printf '\r  downloading claude binary... %dMB (%ds)   ' "$mb" "$elapsed"
    sleep 1
  done
  wait "$pid"; local rc=$?
  printf '\r%*s\r' 50 ''
  if [ $rc -ne 0 ]; then
    report_fail "download linux-arm64 binary" "Command: curl -fSL ${BIN_DOWNLOAD_OPTS[*]} -o $dest $url
Exit code: $rc
Output:
$(cat "$errlog")"
  fi
  rm -f "$errlog"
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

download_binary "$BASE/$VER/linux-arm64/claude" "$tmp/claude"
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
echo "Previous binary kept at $DEST_SHOW/claude.prev — roll back with: termux-update-claude --rollback"
echo "Quit the running claude session and reopen it to use the new version."
