#!/data/data/com.termux/files/usr/bin/bash
BIN="$HOME/.claude/claude-native/claude"
LD="$PREFIX/glibc/lib/ld-linux-aarch64.so.1"
WRAPPER="$PREFIX/bin/claude"
SETTINGS="$HOME/.claude/settings.json"
LOCKFILE="$HOME/.claude/claude-native/.claude-native.lock"
HISTORY_FILE="$HOME/.claude/claude-native/.repatch-history"

unset LD_PRELOAD LD_LIBRARY_PATH

mkdir -p "$HOME/.cache/claude-tmp"

if [ ! -e "$LD" ]; then
  echo "[claude-native] MISSING loader $LD — glibc-runner may have changed its path. Run doctor.sh to re-probe." >&2
  return 0 2>/dev/null || exit 0
fi

if [ ! -e "$BIN" ]; then
  echo "[claude-native] MISSING binary $BIN — run ~/.claude/claude-native/update.sh to reinstall." >&2
  return 0 2>/dev/null || exit 0
fi

# Writes to $BIN/settings.json happen inside this locked block so a second
# Termux tab opened at the same time can't race with this one (or with
# update.sh's own install step, which takes the same lock).
(
  flock -w 5 202 || { echo "[claude-native] Another session is repairing the binary right now — skipping self-heal this time."; exit 0; }

  FIXED=0

  if [ ! -x "$BIN" ]; then
    chmod +x "$BIN" && FIXED=1
  fi

  CUR_INTERP=$(patchelf --print-interpreter "$BIN" 2>/dev/null || true)
  if [ "$CUR_INTERP" != "$LD" ]; then
    if patchelf --set-interpreter "$LD" "$BIN" 2>/dev/null; then
      chmod +x "$BIN"
      FIXED=1
      echo "[claude-native] Binary was overwritten with an unpatched build (usually by the autoupdater) — re-patched the interpreter automatically."

      date +%s >> "$HISTORY_FILE"
      tail -n 50 "$HISTORY_FILE" > "$HISTORY_FILE.tmp" 2>/dev/null && mv "$HISTORY_FILE.tmp" "$HISTORY_FILE"
      NOW=$(date +%s)
      RECENT=$(awk -v now="$NOW" '{ if (now - $1 < 86400) c++ } END { print c+0 }' "$HISTORY_FILE" 2>/dev/null)
      if [ "${RECENT:-0}" -ge 2 ] 2>/dev/null; then
        echo "[claude-native] WARNING: the binary has needed re-patching ${RECENT} times in the last 24h — DISABLE_AUTOUPDATER may not actually be holding. Check settings.json and whether the in-process updater is still active." >&2
      fi
    else
      echo "[claude-native] Binary could not be patched (may segfault on launch) — try grun or update.sh." >&2
    fi
  fi

  if [ -e "$SETTINGS" ] && command -v jq >/dev/null 2>&1; then
    HAS_FLAG=$(jq -r '.env.DISABLE_AUTOUPDATER // empty' "$SETTINGS" 2>/dev/null || true)
    if [ "$HAS_FLAG" != "1" ]; then
      settmp=$(mktemp)
      jq '.env.DISABLE_AUTOUPDATER = "1"' "$SETTINGS" > "$settmp" && mv "$settmp" "$SETTINGS"
      FIXED=1
      echo "[claude-native] DISABLE_AUTOUPDATER was missing from settings.json — re-added it automatically."
    fi
  fi

  if [ "$FIXED" = "1" ]; then
    echo "[claude-native] Auto-fixed. If claude is running in another session, quit and reopen it to pick up the fix."
  fi
) 202>"$LOCKFILE"

if grep -q 'LD_LIBRARY_PATH=' "$WRAPPER" 2>/dev/null; then
  echo "[claude-native] WARNING: wrapper $WRAPPER is setting LD_LIBRARY_PATH via an environment variable (trap #1 — will crash Bionic bash/rg). Needs a manual fix to --library-path." >&2
fi

if ! "$WRAPPER" --version >/dev/null 2>&1; then
  echo "[claude-native] claude still doesn't run after self-repair — run ~/.claude/claude-native/doctor.sh for details." >&2
fi

bash "$HOME/.claude/claude-native/update.sh" --check-only
