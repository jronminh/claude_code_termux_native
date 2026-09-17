#!/data/data/com.termux/files/usr/bin/bash
# Migrates a Termux install of Claude Code still on the old plain-npm/JS
# path (pre-v2.1.113, before Anthropic dropped the JS fallback — see
# github.com/anthropics/claude-code#50270) onto this repo's patched-native
# install. Detects the old install, backs it aside (never deletes), then
# delegates to install.sh for the actual native setup.
#
# ~/.claude/ (settings.json, session transcripts, CLAUDE.md, auth) is
# never touched by this script — only by install.sh's own idempotent
# upserts, exactly as they already behave on a re-run against a populated
# directory. Only the `claude` launcher mechanism changes.
set -uo pipefail

REMOVE_NPM=0
ASSUME_YES=0
FORWARD_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --remove-npm-install) REMOVE_NPM=1 ;;
    --yes) ASSUME_YES=1 ;;
    --with-notifications) FORWARD_ARGS+=("$arg") ;;
    *)
      echo "usage: migrate.sh [--remove-npm-install] [--yes] [--with-notifications]" >&2
      exit 2
      ;;
  esac
done

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="migrate.sh"
TOTAL=1
# shellcheck source=scripts/lib.sh
source "$REPO_DIR/scripts/lib.sh"

echo "${BOLD}claude-code-termux-native${RESET} — migrating to the patched-native install"
echo

step "checking platform" check_platform

# Overridable for testing (see README "Migrating from a plain npm
# install") — never override this on a real run.
CLAUDE_PATH="${MIGRATE_CLAUDE_PATH:-$(command -v claude 2>/dev/null || true)}"

if [ -z "$CLAUDE_PATH" ]; then
  echo "No existing claude install detected on PATH — nothing to migrate."
  echo "Run: bash install.sh"
  exit 0
fi

RESOLVED="$(readlink -f "$CLAUDE_PATH" 2>/dev/null || echo "$CLAUDE_PATH")"

# Already this repo's own wrapper? (marker comment from claude-wrapper.sh)
if [ "$RESOLVED" = "$PREFIX/bin/claude" ] && grep -qF '# Installed to $PREFIX/bin/claude by install.sh.' "$RESOLVED" 2>/dev/null; then
  echo "Already migrated — $RESOLVED is this repo's own patched wrapper."
  echo "Nothing to do here. Use termux-update-claude / doctor.sh instead."
  exit 0
fi

# ELF magic-byte check — od, not grep -P, to sidestep the grep/-G trap
# this repo's own README documents (Troubleshooting #8).
MAGIC=$(od -An -tx1 -N4 "$RESOLVED" 2>/dev/null | tr -d ' \n')
if [ "$MAGIC" = "7f454c46" ]; then
  echo "Found a native/patched claude at $RESOLVED, but it isn't this repo's wrapper."
  echo "Not touching it — if it's from a different fork or tool, handle it yourself first."
  exit 0
fi

FIRST_LINE=$(head -c 200 "$RESOLVED" 2>/dev/null | head -1)
case "$FIRST_LINE" in
  '#!'*node*) : ;;
  *)
    echo "Found $RESOLVED, but it's neither a native binary nor a Node-shebang"
    echo "script — can't classify it safely. Not touching it."
    echo "Handle it manually, then run: bash install.sh"
    exit 0
    ;;
esac

NPM_PKG=""
NPM_CORROBORATED=0
case "$RESOLVED" in
  "$PREFIX"/lib/node_modules/*)
    if NPM_LS_OUT=$(npm ls -g @anthropic-ai/claude-code --depth=0 2>/dev/null) && [ -n "$NPM_LS_OUT" ]; then
      NPM_PKG="@anthropic-ai/claude-code"
      NPM_CORROBORATED=1
    fi
    ;;
esac

if [ "$NPM_CORROBORATED" = "1" ]; then
  echo "Detected an old plain-npm Claude Code install ($NPM_PKG) at:"
else
  echo "$RESOLVED looks like an old Node-based claude script, but couldn't"
  echo "confirm it via npm (it may be installed a different way):"
fi
echo "  $RESOLVED"
echo
echo "This is the pre-native-binary path — Anthropic dropped it at v2.1.113+"
echo "(github.com/anthropics/claude-code#50270). Migrating backs this up"
echo "(never deletes) and installs this repo's patched-native binary instead."
echo "Your ~/.claude/ (settings, sessions, CLAUDE.md, auth) is not touched."
echo

if [ "$ASSUME_YES" != "1" ]; then
  printf "Proceed? [y/N] "
  read -r REPLY
  case "$REPLY" in
    y | Y | yes | YES) ;;
    *)
      echo "Aborted — nothing changed."
      exit 0
      ;;
  esac
fi

# Back up $CLAUDE_PATH (what's actually on PATH — often a symlink into
# node_modules/.bin/), not $RESOLVED — renaming the symlink removes
# `claude` from PATH resolution while leaving the npm package's real
# files under node_modules untouched, so a later `npm uninstall` still
# works normally and this is trivially reversible either way.
BACKUP="$CLAUDE_PATH.pre-migrate-native.$(date +%Y%m%d%H%M%S)"
mv "$CLAUDE_PATH" "$BACKUP"
echo "Backed up old claude to: $BACKUP"

if [ "$NPM_CORROBORATED" = "1" ]; then
  if [ "$REMOVE_NPM" = "1" ]; then
    echo "Removing npm package $NPM_PKG..."
    npm uninstall -g "$NPM_PKG" || echo "warning: npm uninstall failed — remove it yourself: npm uninstall -g $NPM_PKG" >&2
  else
    echo "Not removing the npm package automatically. To clean it up yourself:"
    echo "  npm uninstall -g $NPM_PKG"
  fi
else
  echo "Couldn't confirm an npm package to remove — if there is one, remove it yourself."
fi

echo
echo "Handing off to install.sh..."
echo
exec bash "$REPO_DIR/install.sh" "${FORWARD_ARGS[@]}"
