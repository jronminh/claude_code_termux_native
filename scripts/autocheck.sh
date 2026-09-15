#!/data/data/com.termux/files/usr/bin/bash
# Staged to ~/.claude/claude-native/autocheck.sh by install.sh, sourced from
# ~/.bashrc on every interactive shell. Self-heals silently, then hands off
# to update.sh --check-only. See README.md ("Self-check + self-heal").
BIN="$HOME/.claude/claude-native/claude"
LD="$PREFIX/glibc/lib/ld-linux-aarch64.so.1"
WRAPPER="$PREFIX/bin/claude"
SETTINGS="$HOME/.claude/settings.json"
LOCKFILE="$HOME/.claude/claude-native/.claude-native.lock"
HISTORY_FILE="$HOME/.claude/claude-native/.repatch-history"

# notify TITLE CONTENT — best-effort Termux:API push notification. Silent
# no-op if termux-api isn't installed (it's optional, not a dependency
# install.sh pulls in — most users won't have it).
notify() {
  command -v termux-notification >/dev/null 2>&1 || return 0
  termux-notification --title "$1" --content "$2" 2>/dev/null || true
}

unset LD_PRELOAD LD_LIBRARY_PATH

mkdir -p "$HOME/.cache/claude-tmp"

if [ ! -e "$LD" ]; then
  echo "MISSING loader $LD — glibc-runner may have changed its path. Run doctor.sh to re-probe." >&2
  return 0 2>/dev/null || exit 0
fi

if [ ! -e "$BIN" ]; then
  echo "MISSING binary $BIN — run ~/.claude/claude-native/update.sh to reinstall." >&2
  return 0 2>/dev/null || exit 0
fi

# Writes to $BIN/settings.json happen inside this locked block so a second
# Termux tab opened at the same time can't race with this one (or with
# update.sh's own install step, which takes the same lock).
(
  flock -w 5 202 || { echo "Another session is repairing the binary right now — skipping self-heal this time."; exit 0; }

  FIXED=0

  if [ ! -x "$BIN" ]; then
    chmod +x "$BIN" && FIXED=1
  fi

  CUR_INTERP=$(patchelf --print-interpreter "$BIN" 2>/dev/null || true)
  if [ "$CUR_INTERP" != "$LD" ]; then
    if patchelf --set-interpreter "$LD" "$BIN" 2>/dev/null; then
      chmod +x "$BIN"
      FIXED=1
      echo "Binary was overwritten with an unpatched build (usually by the autoupdater) — re-patched the interpreter automatically."

      date +%s >> "$HISTORY_FILE"
      tail -n 50 "$HISTORY_FILE" > "$HISTORY_FILE.tmp" 2>/dev/null && mv "$HISTORY_FILE.tmp" "$HISTORY_FILE"
      NOW=$(date +%s)
      RECENT=$(awk -v now="$NOW" '{ if (now - $1 < 86400) c++ } END { print c+0 }' "$HISTORY_FILE" 2>/dev/null)
      if [ "${RECENT:-0}" -ge 2 ] 2>/dev/null; then
        echo "WARNING: the binary has needed re-patching ${RECENT} times in the last 24h — DISABLE_AUTOUPDATER may not actually be holding. Check settings.json and whether the in-process updater is still active." >&2
        notify "claude-native: repeated re-patching" "Re-patched ${RECENT}x in 24h — DISABLE_AUTOUPDATER may not be holding. Run doctor.sh."
      fi
    else
      echo "Binary could not be patched (may segfault on launch) — try grun or update.sh." >&2
    fi
  fi

  if [ -e "$SETTINGS" ] && command -v jq >/dev/null 2>&1; then
    HAS_FLAG=$(jq -r '.env.DISABLE_AUTOUPDATER // empty' "$SETTINGS" 2>/dev/null || true)
    if [ "$HAS_FLAG" != "1" ]; then
      cp -f "$SETTINGS" "$SETTINGS.bak" 2>/dev/null
      settmp=$(mktemp)
      jq '.env.DISABLE_AUTOUPDATER = "1"' "$SETTINGS" > "$settmp" && mv "$settmp" "$SETTINGS"
      FIXED=1
      echo "DISABLE_AUTOUPDATER was missing from settings.json — re-added it automatically (previous version backed up to $SETTINGS.bak)."
    fi
  fi

  if [ "$FIXED" = "1" ]; then
    echo "Auto-fixed. If claude is running in another session, quit and reopen it to pick up the fix."
  fi
) 202>"$LOCKFILE"

if grep -q 'LD_LIBRARY_PATH=' "$WRAPPER" 2>/dev/null; then
  echo "WARNING: wrapper $WRAPPER is setting LD_LIBRARY_PATH via an environment variable (trap #1 — will crash Bionic bash/rg). Needs a manual fix to --library-path." >&2
fi

if ! "$WRAPPER" --version >/dev/null 2>&1; then
  echo "claude still doesn't run after self-repair — run ~/.claude/claude-native/doctor.sh for details." >&2
fi

bash "$HOME/.claude/claude-native/update.sh" --check-only
