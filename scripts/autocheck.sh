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

# Kept in sync by hand with scripts/lib.sh's copy (install.sh/uninstall.sh
# source that file; this script is staged standalone and can't).
DOCTOR_HOOK_MARKER="claude-code-termux-native:doctor-hook"
doctor_hook_command() {
  cat <<'EOF'
# claude-code-termux-native:doctor-hook
OUT=$(bash ~/.claude/claude-native/doctor.sh 2>&1); if printf '%s' "$OUT" | grep -qE 'MISMATCH:|RISK:|WARN:|MISSING|not found|not patched\?|could not determine|UPDATED:'; then jq -n --arg out "$OUT" '{systemMessage: "termux-doctor has something to report at session start — run bash ~/.claude/claude-native/doctor.sh to see it, or invoke the termux-doctor skill", hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $out}}'; fi
EOF
}

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

# Hard incompatibility, not a patch-able bug: no binary can execute at all
# on a noexec $HOME. Loud and every shell until fixed — there's nothing to
# auto-heal here, unlike everything else in this file.
MOUNT_LINE=$(awk -v h="$HOME" 'index(h, $2)==1 {print length($2), $0}' /proc/mounts 2>/dev/null | sort -n | tail -1)
if printf '%s' "$MOUNT_LINE" | grep -q noexec; then
  echo "FATAL: \$HOME is mounted noexec — claude (or any binary) cannot execute here, patched or not. See README.md \"Troubleshooting\"." >&2
fi

# Informational, not fatal — Android's binary-translation layers (e.g. some
# Chromebooks/x86 emulation) can still run an aarch64 binary, so this alone
# doesn't mean it's broken, just that this repo's aarch64-only assumptions
# haven't been verified on this ABI.
REPORTED_ABI=$(getprop ro.product.cpu.abi 2>/dev/null)
if [ -n "$REPORTED_ABI" ] && [ "$REPORTED_ABI" != "arm64-v8a" ]; then
  echo "NOTE: Android reports CPU ABI '$REPORTED_ABI' (not arm64-v8a) — if claude misbehaves, this repo's aarch64-only assumptions may be why." >&2
fi

# trap #9 risk cache (see README "Troubleshooting" #9 and claude-wrapper.sh):
# update.sh refreshes this on every install/update; this is just a
# backfill for a binary that predates this cache existing at all. A
# `strings` scan of a ~300MB binary is too slow for the wrapper's hot path,
# but once per shell here is fine.
EPOLL_CACHE="$HOME/.claude/claude-native/.epoll-fix-cache"
if [ ! -e "$EPOLL_CACHE" ]; then
  if strings "$BIN" 2>/dev/null | grep -q BUN_FEATURE_FLAG_DISABLE_EPOLL_PWAIT2; then
    printf '1' > "$EPOLL_CACHE" 2>/dev/null
  else
    printf '0' > "$EPOLL_CACHE" 2>/dev/null
  fi
fi
if [ "$(cat "$EPOLL_CACHE" 2>/dev/null)" = "0" ]; then
  KVER=$(uname -r); KMAJOR=${KVER%%.*}; KREST=${KVER#*.}; KMINOR=${KREST%%.*}
  if { [ "$KMAJOR" -gt 5 ] 2>/dev/null || { [ "$KMAJOR" -eq 5 ] 2>/dev/null && [ "$KMINOR" -ge 11 ] 2>/dev/null; }; }; then
    echo "RISK: kernel $KVER is 5.11+ and the installed claude build predates the epoll_pwait2 fix — it may segfault once its event loop starts, even though it launches fine right now. Run doctor.sh, or: termux-update-claude" >&2
  fi
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

  if [ -e "$SETTINGS" ] && command -v jq >/dev/null 2>&1; then
    HAS_DOCTOR_HOOK=$(jq -r --arg marker "$DOCTOR_HOOK_MARKER" \
      '[.hooks.SessionStart[]?.hooks[]?.command // "" | test($marker)] | any' \
      "$SETTINGS" 2>/dev/null || echo false)
    if [ "$HAS_DOCTOR_HOOK" != "true" ]; then
      cp -f "$SETTINGS" "$SETTINGS.bak" 2>/dev/null
      settmp=$(mktemp)
      jq --arg cmd "$(doctor_hook_command)" --arg marker "$DOCTOR_HOOK_MARKER" '
        .hooks = ((.hooks // {}) + {
          SessionStart: (
            ((.hooks.SessionStart // [])
              | map(select(((.hooks // []) | map(.command // "") | any(test($marker))) | not)))
            + [{"hooks": [{"type": "command", "command": $cmd, "timeout": 15, "statusMessage": "Running termux-doctor sanity check..."}]}]
          )
        })
      ' "$SETTINGS" > "$settmp" && mv "$settmp" "$SETTINGS"
      FIXED=1
      echo "SessionStart doctor-hook was missing from settings.json — re-added it automatically (previous version backed up to $SETTINGS.bak)."
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
