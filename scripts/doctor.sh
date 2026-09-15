#!/data/data/com.termux/files/usr/bin/bash
# Staged to ~/.claude/claude-native/doctor.sh by install.sh. One-shot
# diagnostic dump — run this first, before guessing, whenever something's
# broken. See README.md ("Manual verification").
BIN="$HOME/.claude/claude-native/claude"
LD="$PREFIX/glibc/lib/ld-linux-aarch64.so.1"
WRAPPER="$PREFIX/bin/claude"

echo "== arch ==";              uname -m
echo "== kernel epoll_pwait2 risk (bun#32489, fixed upstream in bun#32490) =="
KVER=$(uname -r)
KMAJOR=$(printf '%s' "$KVER" | cut -d. -f1)
KMINOR=$(printf '%s' "$KVER" | cut -d. -f2)
if [ "$KMAJOR" -eq "$KMAJOR" ] 2>/dev/null && [ "$KMINOR" -eq "$KMINOR" ] 2>/dev/null \
   && { [ "$KMAJOR" -gt 5 ] || { [ "$KMAJOR" -eq 5 ] && [ "$KMINOR" -ge 11 ]; }; }; then
  echo "kernel $KVER is 5.11+ (would be at risk on an unpatched Bun)"
  if strings "$BIN" 2>/dev/null | grep -q BUN_FEATURE_FLAG_DISABLE_EPOLL_PWAIT2; then
    echo "ok: bundled Bun carries the upstream fix (flag string present in binary)"
  else
    echo "RISK: bundled Bun predates the fix (flag string absent) — see README.md \"Troubleshooting\""
  fi
else
  echo "ok: kernel $KVER is below the 5.11 risk threshold (moot regardless of Bun version)"
fi
echo "== PREFIX / HOME ==";     echo "$PREFIX"; echo "$HOME"
echo "== claude on PATH ==";    command -v claude && readlink -f "$(command -v claude)"
echo "== binary ==";            ls -l "$BIN" 2>/dev/null || echo "MISSING $BIN"
echo "== file type ==";         file "$BIN" 2>/dev/null
echo "== interpreter ==";       patchelf --print-interpreter "$BIN" 2>/dev/null || echo "not patched?"
echo "== loader exists? ==";    ls -l "$LD" 2>/dev/null || echo "MISSING LOADER: $LD"
echo "== libc.so.6 ==";         ls "$PREFIX/glibc/lib/libc.so.6" 2>/dev/null || echo "libc.so.6 not found"
echo "== leaked env LD_* ==";   env | grep -i '^LD_' || echo "clean"
echo "== autoupdater disabled? =="; grep -s DISABLE_AUTOUPDATER "$WRAPPER" "$HOME/.claude/settings.json" || echo "DISABLE_AUTOUPDATER NOT found — risk of being overwritten"
echo "== version ==";           claude --version 2>/dev/null || echo "claude does not run — see items above"
