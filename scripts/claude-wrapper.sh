#!/data/data/com.termux/files/usr/bin/bash
# Installed to $PREFIX/bin/claude by install.sh.
# Every line here works around a specific Bionic/glibc conflict — see
# README.md ("Troubleshooting") before changing anything.
unset LD_PRELOAD
export TMPDIR="$HOME/.cache/claude-tmp"
mkdir -p "$TMPDIR"
export USE_BUILTIN_RIPGREP=0
export DISABLE_AUTOUPDATER=1
export CLAUDE_CODE_EXECPATH="$HOME/.claude/claude-native/claude"
# Belt-and-suspenders for trap #9 (oven-sh/bun#32489): forces the same safe
# epoll_pwait path the upstream fix (bun#32490) already takes by default on
# Bun builds that include it, and protects any older bundled Bun that
# predates it. Harmless either way.
export BUN_FEATURE_FLAG_DISABLE_EPOLL_PWAIT2=1

# Prefer exec'ing the patched binary directly (no explicit ld-linux
# invocation): the kernel then records the binary itself, not ld-linux, as
# the process's exe_file. That matters because Claude reads process.execPath
# (Node/Bun readlink /proc/self/exe under the hood) and overwrites
# CLAUDE_CODE_EXECPATH with it before re-exec'ing embedded tools like grep —
# see trap #8 in CLAUDE.md.template. Going through ld-linux made that
# overwritten value point at ld-linux itself, breaking every grep/find call
# inside the Bash tool regardless of restarts. This only works if the glibc
# runtime is already registered in ld.so.cache (confirmed true here); on an
# install where it isn't, fall back to the explicit --library-path form.
if "$HOME/.claude/claude-native/claude" --version >/dev/null 2>&1; then
  exec "$HOME/.claude/claude-native/claude" "$@"
else
  exec "$PREFIX/glibc/lib/ld-linux-aarch64.so.1" \
    --library-path "$PREFIX/glibc/lib" \
    "$HOME/.claude/claude-native/claude" "$@"
fi
