# claude-code-termux-native

[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
![Platform](https://img.shields.io/badge/platform-Termux%20%7C%20Android%20aarch64-3DDC84)
![Shell](https://img.shields.io/badge/shell-bash-4EAA25?logo=gnubash&logoColor=white)

Patches Claude Code's official `linux-arm64` binary to link against **Termux's own glibc** instead of Android's Bionic libc — so it runs natively on Android. No `proot-distro`, no Ubuntu chroot, no emulation layer.

> Unofficial, community project — not affiliated with or endorsed by Anthropic. Ships no binary: `install.sh` downloads it at install time from Anthropic's own `downloads.claude.ai`, the same endpoint the official installer uses, and verifies its SHA-256 against Anthropic's manifest before ever running it.

![install.sh running in Termux, all 8 steps completing successfully](assets/demo.gif)

## Why this exists

Anthropic ships `linux-arm64`, not `android-arm64`. Termux runs on Bionic, which that binary can't link against — but Termux also ships a real glibc (`glibc-repo`/`glibc-runner`) for exactly this situation.

The trick: `patchelf --set-interpreter` the binary's ELF interpreter to Termux's `ld-linux-aarch64.so.1`, then invoke it so it gets Termux's glibc libraries **without leaking a glibc environment into the Bionic processes Claude Code itself spawns** (its own Bash tool, `rg`, etc.). That constraint drives most of this repo's complexity — see [Troubleshooting](#troubleshooting).

## Install

```sh
git clone https://github.com/jronminh/claude_code_termux_native.git ~/claude-code-termux-native
cd ~/claude-code-termux-native
bash install.sh
```

Idempotent — safe to re-run any time, e.g. after a Termux/glibc upgrade. Then open a **new** Termux session (or `exec bash`) and run:

```sh
claude
```

### What `install.sh` does

1. Checks you're on `aarch64` Termux.
2. Installs/upgrades `glibc-repo`, `glibc`, `patchelf`, `jq`, `curl`, `ripgrep`, `coreutils`.
3. Stages `autocheck.sh` / `update.sh` / `doctor.sh` into `~/.claude/claude-native/`.
4. Runs `update.sh` to download, verify, patch, and install the `claude` binary — the same path every later update uses.
5. Installs `claude` and `termux-update-claude` into `$PREFIX/bin`.
6. Hooks `autocheck.sh` into `~/.bashrc` (self-heal + silent update-check on every new shell).
7. Sets `DISABLE_AUTOUPDATER=1` in `~/.claude/settings.json` so Claude Code's own updater can't overwrite the patched binary.
8. Merges [`CLAUDE.md.template`](CLAUDE.md.template) into your global `~/.claude/CLAUDE.md`, between `<!-- claude-code-termux-native:begin/end -->` markers — so claude itself knows about this environment from the start of every session, on every project. Appends if you have your own content there; updates in place (never duplicates) on a later install. `uninstall.sh` removes just that section.

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

To change how any of this works, edit `scripts/` **in this repo** and re-run `install.sh` — don't hand-edit the installed copies under `~/.claude/claude-native/`; a future re-run overwrites them silently.

## Extra features (beyond a bare install)

- **Self-heal on every new shell** (`autocheck.sh`): fixes the execute bit, re-patches the interpreter if an unpatched build overwrote it, re-adds `DISABLE_AUTOUPDATER` if it went missing, warns (without auto-editing) if the wrapper regressed to setting `LD_LIBRARY_PATH` via env. Silent when clean; only runs on interactive shell startup, never inside a Claude-spawned Bash-tool shell.
- **Locking**: self-heal and `update.sh`'s install step share one `flock`, so two Termux tabs open at once can't corrupt the binary racing each other.
- **Repatch-frequency escalation**: 2+ re-patches in 24h escalates from a quiet fix notice to an explicit warning that `DISABLE_AUTOUPDATER` isn't actually holding.
- **Update / rollback**: `termux-update-claude` downloads → verifies SHA-256 → patches → installs, swapping in the new binary only after every check passes, with automatic retry/resume if the connection drops mid-download. `--rollback` restores the previous binary (kept as `claude.prev`; a rejected build is kept as `claude.rejected`, not deleted).
- **`doctor.sh`**: one-shot diagnostic dump (arch, kernel `epoll_pwait2` risk check, paths, binary/interpreter state, leaked `LD_*` env, autoupdater-disabled check, `--version`) — run this first, before guessing.

## Troubleshooting

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
| 9 | `claude` segfaults immediately on launch, no useful error | Android's seccomp policy allows the older `epoll_pwait` syscall but often still blocks the newer `epoll_pwait2` (added in Linux 5.11) even on kernels well past that version — the allowlist is curated per-syscall, not auto-updated for every syscall a new kernel happens to add. `claude`'s bundled Bun calls it anyway, gets `ENOSYS`, and its event loop (`bun-usockets`) doesn't check for that failure — a null-pointer dereference follows. Confirmed in the wild on an OPPO CPH2499, Android 16, kernel 5.15.180. **The kernel version is fixed at the device's original manufacture** (Android's KMI ties vendor kernel modules to one specific kernel build) and does not change on an OS upgrade — a phone can show "Android 16" in Settings while still running the kernel it shipped with years earlier on Android 12. So the Android version shown in Settings tells you nothing here; only the real kernel does. | Check with `bash doctor.sh` or `uname -r` by hand (risk zone: 5.11+). **Not fixable within this repo** — would need an LD_PRELOAD shim intercepting syscall 441 (`epoll_pwait2` on aarch64) and redirecting it to `epoll_pwait`, real systems programming, not a bash fix. Upstream is closed as "not planned": [oven-sh/bun#32489](https://github.com/oven-sh/bun/issues/32489). [gtbuchanan/claude-code-termux](https://github.com/gtbuchanan/claude-code-termux) ships a working shim if you hit this. `install.sh`/`doctor.sh` only warn — they detect the risk, they don't fix it. |

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

A currently-running `claude` session can't hot-swap its own binary — quit and reopen after updating.

## Uninstall

```sh
cd ~/claude-code-termux-native   # wherever you cloned it
bash uninstall.sh          # keeps the downloaded binary cached
bash uninstall.sh --full   # also deletes the cached binary
```

Removes `claude` / `termux-update-claude`, the `~/.bashrc` hook, `DISABLE_AUTOUPDATER`, the self-repair scripts, and our section of `~/.claude/CLAUDE.md` (only what's between its markers — anything else in that file is untouched). Keeps the ~300MB binary + `manifest.json` cached by default so a future install skips the download; `--full` wipes that too.

Either way, it leaves the Termux packages (`glibc`, `patchelf`, `jq`, `ripgrep`, ...) and the cloned repo directory alone — neither is exclusively this project's to remove; `uninstall.sh` prints the command if you want them gone too.

## Contributing

The issues and fixes above came from real breakage, not speculation. Hit a new one on a different Termux/glibc version? A PR adding it to the table (symptom → cause → fix) is exactly the contribution this repo wants.

## License

MIT for the scripts — see [LICENSE](LICENSE). The `claude` binary is downloaded from, and remains the property of, Anthropic, under [its own terms](https://www.anthropic.com/legal).
