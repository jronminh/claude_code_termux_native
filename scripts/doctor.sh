#!/data/data/com.termux/files/usr/bin/bash
BIN="$HOME/.claude/claude-native/claude"
LD="$PREFIX/glibc/lib/ld-linux-aarch64.so.1"

echo "== arch ==";              uname -m
echo "== PREFIX / HOME ==";     echo "$PREFIX"; echo "$HOME"
echo "== claude on PATH ==";    command -v claude && readlink -f "$(command -v claude)"
echo "== binary ==";            ls -l "$BIN" 2>/dev/null || echo "MISSING $BIN"
echo "== file type ==";         file "$BIN" 2>/dev/null
echo "== interpreter ==";       patchelf --print-interpreter "$BIN" 2>/dev/null || echo "not patched?"
echo "== loader exists? ==";    ls -l "$LD" 2>/dev/null || echo "MISSING LOADER: $LD"
echo "== libc.so.6 ==";         ls "$PREFIX/glibc/lib/libc.so.6" 2>/dev/null || echo "libc.so.6 not found"
echo "== leaked env LD_* ==";   env | grep -i '^LD_' || echo "clean"
echo "== autoupdater disabled? =="; grep -s DISABLE_AUTOUPDATER "$HOME/.bashrc" "$HOME/.claude/settings.json" || echo "DISABLE_AUTOUPDATER NOT found — risk of being overwritten"
echo "== version ==";           claude --version 2>/dev/null || echo "claude does not run — see items above"
