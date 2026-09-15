#!/data/data/com.termux/files/usr/bin/bash
# Installed to $PREFIX/bin/claude by install.sh.
# Every line here works around a specific Bionic/glibc conflict — see
# README.md ("Traps encountered") before changing anything.
unset LD_PRELOAD
export TMPDIR="$HOME/.cache/claude-tmp"
mkdir -p "$TMPDIR"
export USE_BUILTIN_RIPGREP=0
export DISABLE_AUTOUPDATER=1
export CLAUDE_CODE_EXECPATH="$HOME/.claude/claude-native/claude"
exec "$PREFIX/glibc/lib/ld-linux-aarch64.so.1" \
  --library-path "$PREFIX/glibc/lib" \
  "$HOME/.claude/claude-native/claude" "$@"
