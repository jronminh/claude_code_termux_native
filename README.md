# claude-code-termux-native

Run [Claude Code](https://claude.com/claude-code) **natively** on Termux/Android — no `proot-distro`, no Ubuntu chroot, no emulation layer. It runs Anthropic's official `linux-arm64` build directly on top of Android, by patching the binary to load through Termux's glibc instead of Android's Bionic libc.

> **Unofficial, community project.** Not affiliated with or endorsed by Anthropic. This repo contains only shell scripts — it does not ship or redistribute the `claude` binary. `install.sh` downloads it at install time straight from Anthropic's own distribution endpoint (`downloads.claude.ai`), the same one the official installer uses, and verifies its SHA-256 against Anthropic's own manifest before ever running it.

## Why this exists

Anthropic publishes a `linux-arm64` build of Claude Code, but no `android-arm64` build. Termux runs on Android's Bionic libc, which that `linux-arm64` binary can't link against directly. Termux separately ships a real glibc (via `glibc-repo`/`glibc-runner`) specifically so glibc-linked Linux binaries can run underneath it.

The trick: patch the binary's ELF interpreter (`patchelf --set-interpreter`) to point at Termux's `ld-linux-aarch64.so.1`, and invoke it in a way that gives it Termux's glibc libraries **without leaking a glibc environment into the Bionic processes Claude Code itself spawns** (its own Bash tool, `rg`, etc.). That last constraint is what most of this repo's complexity is about — see [Traps encountered](#traps-encountered) below.

## Install

```sh
git clone https://github.com/jronminh/claude_code_termux_native.git ~/claude-code-termux-native
cd ~/claude-code-termux-native
bash install.sh
```

Run once. It's idempotent, so re-running it (e.g. after a Termux/glibc upgrade) is safe and just re-verifies/re-applies everything.

Then **open a new Termux session** (or `exec bash`) and run:

```sh
claude
```

### What `install.sh` does

1. Verifies you're on `aarch64` Termux.
2. Installs/upgrades `glibc-repo`, `glibc`, `patchelf`, `jq`, `curl`, `ripgrep`, `coreutils`.
3. Stages `scripts/autocheck.sh`, `scripts/update.sh`, `scripts/doctor.sh` into `~/.claude/claude-native/`.
4. Runs `update.sh` once to download the current `claude` binary + manifest, verify its checksum, patch its interpreter, and install it — the exact same code path used for every later update.
5. Installs the wrapper as `$PREFIX/bin/claude` and `termux-update-claude` as `$PREFIX/bin/termux-update-claude`.
6. Adds `source ~/.claude/claude-native/autocheck.sh` to `~/.bashrc` (self-heal + silent update-check on every new shell).
7. Sets `DISABLE_AUTOUPDATER=1` in `~/.claude/settings.json` so Claude Code's own in-process updater never overwrites the patched binary with an unpatched one.
8. Installs [`CLAUDE.md.template`](CLAUDE.md.template) into your **global** `~/.claude/CLAUDE.md`, so claude itself reads about this environment — the traps table below, in Claude's own words — at the start of every session, on every project, without you having to explain it or hit the same failure mode twice. It's inserted between `<!-- claude-code-termux-native:begin/end -->` markers: if that file already has your own content, it's left alone and our section is appended; if you already have our section (from a previous install), it's replaced in place, never duplicated. `uninstall.sh` removes just that section the same way.

## Layout after install

```
~/.claude/claude-native/
  claude              # patched linux-arm64 binary
  manifest.json        # from Anthropic, used to verify checksums on update
  autocheck.sh          # self-heal, runs on every new Termux shell via .bashrc
  update.sh             # download/verify/patch/install + rollback
  doctor.sh             # diagnostic dump — run this first when something's broken
  .claude-native.lock    # flock used by autocheck.sh and update.sh so they never race
  .repatch-history       # timestamps of automatic re-patches (see below)

$PREFIX/bin/claude               # wrapper — what actually runs when you type `claude`
$PREFIX/bin/termux-update-claude # manual update/rollback command

~/.claude/CLAUDE.md              # our section lives inside begin/end markers; rest of the file is yours
```

If you need to change how any of this works, edit the copy under `scripts/` **in this repo** and re-run `install.sh` — don't hand-edit the installed copies under `~/.claude/claude-native/`, since a future re-run (or `git pull` + re-run) would overwrite them silently.

## Extra features (beyond a bare install)

- **Self-heal on every new shell** (`autocheck.sh`): re-adds the execute bit, re-patches the interpreter if something (usually the in-process autoupdater) overwrote it with an unpatched build, re-adds `DISABLE_AUTOUPDATER` if it went missing, warns (without auto-editing) if the wrapper regressed to setting `LD_LIBRARY_PATH` via an environment variable. Silent when there's nothing to fix; only runs on interactive shell startup, never inside a Claude-spawned Bash-tool shell.
- **Locking**: self-heal and `update.sh`'s install step share one `flock`, so two Termux tabs open at once can't corrupt the binary racing each other — the loser just waits and backs off.
- **Repatch-frequency escalation**: if the interpreter needs re-patching 2+ times in 24h, `autocheck.sh` escalates to an explicit warning that `DISABLE_AUTOUPDATER` may not actually be holding, instead of silently patching forever with no signal something upstream keeps breaking.
- **Update / rollback**: `termux-update-claude` checks for and applies updates (download → verify SHA-256 against the manifest → patch → install, only swapping in the new binary after every check passes). `termux-update-claude --rollback` restores the previous binary, keeping the rejected build aside as `claude.rejected` instead of deleting it.
- **`doctor.sh`**: one-shot diagnostic dump (arch, paths, binary/interpreter state, leaked `LD_*` env, autoupdater-disabled check, `--version`) — run this first, before guessing, whenever something's broken.

## Traps encountered

Symptom → cause → fix, for the failure modes hit while building this.

| # | Symptom | Cause | Fix |
|---|---|---|---|
| 1 | Any Bionic command (`mkdir`, `ls`, and *especially* the bash Claude Code spawns for its own Bash tool) dies with `bad ELF magic: 2f2a2047` / `CANNOT LINK EXECUTABLE ... bash` | `LD_LIBRARY_PATH` was set via an environment variable (even `env LD_LIBRARY_PATH=... exec claude`) — it leaks into every child process, and Bionic's linker loads glibc's `libc.so` by mistake | Never set it via env. Invoke the linker with `--library-path` on the command line instead — that only applies to the one `exec`, never leaks. After fixing, fully quit and reopen Termux; a running session already inherited the bad env. |
| 2 | `Permission denied` / `cannot execute: Success` running the binary | Missing execute bit after download/patch (the "Success" line is just a stale errno being misprinted) | `chmod +x` |
| 3 | `grep`/`rg` dies mid-session with `invalid ELF header` | Bionic's `LD_PRELOAD` (preloaded by Termux by default) leaked into a glibc process | `unset LD_PRELOAD` in the wrapper; never put `env.LD_PRELOAD` in `settings.json` |
| 4 | `cannot execute` / interpreter not found, or it points at `/lib/ld-linux-aarch64.so.1` | Binary was never patched, or got overwritten by an unpatched build (usually the in-process autoupdater) | Re-run `patchelf --set-interpreter`, then `chmod +x` (this is exactly what `autocheck.sh` automates) |
| 5 | claude exits immediately with "native binary not installed" | You have Anthropic's newer binary-distribution mechanism, which has no Android target | You need a patched `linux-arm64` build specifically, not one from `npm`/`claude install` |
| 6 | Segfault right after `patchelf` | Some glibc binaries don't tolerate patching | Fallback: don't patch it, run via `grun <binary>` instead (it unsets `LD_PRELOAD` and sets the library path itself) |
| 7 | Write errors to `/tmp` / `EACCES` at runtime | Android has no `/tmp`, and `TMPDIR` isn't set/doesn't exist | Export a writable `TMPDIR` (e.g. `~/.cache/claude-tmp`) and `mkdir -p` it |
| 8 | Bare `grep` inside a Claude Code Bash-tool call fails with `-G: error while loading shared libraries: -G: cannot open shared object file` (real `command grep`/`rg` still work) | Claude Code injects a `grep` shell function into every shell it spawns that re-invokes *itself* as a hidden ripgrep-like "ugrep" personality: `exec -a ugrep "$CLAUDE_CODE_EXECPATH" -G ...`. On a patched setup, the process's self-detected exec path is whatever was actually `execve()`'d last — the `ld-linux` interpreter, not the `claude` binary, because the wrapper's last line is `exec ld-linux --library-path ... claude`. So the function ends up running the raw linker with grep-style flags, which it can't parse. | Export `CLAUDE_CODE_EXECPATH` to the real binary path in the wrapper. This works because the patched ELF can be `exec`'d directly — Termux's `ld.so.cache` already lists the glibc lib dir as a system search path, so no `--library-path` flag is needed for a direct `execve` — and because it's a real ELF (not a script), `exec -a ugrep <binary> ...` preserves the custom `argv[0]` through the kernel's automatic interpreter dispatch, unlike routing through a wrapper *script* (shebang handling discards a custom `argv[0]` before the interpreter script ever sees it). |

## Manual verification

```sh
uname -m                                            # expect: aarch64
echo "$PREFIX"; echo "$HOME"
command -v claude; readlink -f "$(command -v claude)"
file ~/.claude/claude-native/claude
patchelf --print-interpreter ~/.claude/claude-native/claude
ls -l "$PREFIX/glibc/lib/ld-linux-aarch64.so.1"
env | grep -i '^LD_'
bash ~/.claude/claude-native/doctor.sh
```

## Updating

```sh
termux-update-claude              # check for + apply an update
termux-update-claude --rollback   # revert to the previously installed binary
```

Note: a currently-running `claude` session cannot hot-swap its own binary. Quit and reopen after updating.

## Uninstall

```sh
cd ~/claude-code-termux-native   # wherever you cloned it
bash uninstall.sh          # keeps the downloaded binary cached
bash uninstall.sh --full   # also deletes the cached binary
```

Removes the `claude`/`termux-update-claude` commands, the `~/.bashrc` hook, the `DISABLE_AUTOUPDATER` setting, the self-repair scripts, and our section from `~/.claude/CLAUDE.md` (only what's between its markers — anything else you have in that file is untouched). By default it leaves the downloaded `claude` binary and `manifest.json` cached under `~/.claude/claude-native/`, since that's a ~300MB download — a future `install.sh` run will reuse it instead of fetching it again. Pass `--full` to wipe that cache too.

Either way, it deliberately leaves alone the Termux packages `install.sh` installed (`glibc`, `patchelf`, `jq`, `ripgrep`, ...) — those are shared with the rest of Termux, not exclusively this project's to remove — and the cloned repo directory itself, which `uninstall.sh` tells you how to delete by hand if you want it gone too.

## Contributing

Traps and fixes here came from real breakage, not speculation. If you hit a new one on a different Termux/glibc version, a PR adding it to the table (symptom → cause → fix) is exactly the kind of contribution this repo wants.

## License

MIT — see [LICENSE](LICENSE). Applies to the scripts in this repo only; the `claude` binary itself is downloaded from and remains the property of Anthropic, subject to [its own license/terms](https://www.anthropic.com/legal).
