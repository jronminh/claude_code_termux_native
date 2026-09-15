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
8. Wires `doctor.sh` into a `SessionStart` hook in `~/.claude/settings.json`, so the sanity check runs automatically at the start of every Claude Code session — silent when clean, only speaking up (via `additionalContext` + a warning) when it spots a real problem. Upserted by a marker comment in the hook command, so a later install.sh run replaces just our entry and never touches any other hooks you've configured yourself.
9. Merges [`CLAUDE.md.template`](CLAUDE.md.template) into your global `~/.claude/CLAUDE.md`, between `<!-- claude-code-termux-native:begin/end -->` markers — a short pointer so claude recognizes this environment from the start of every session, on every project. Appends if you have your own content there; updates in place (never duplicates) on a later install. `uninstall.sh` removes just that section.
10. Installs the [`termux-doctor`](skills/termux-doctor/SKILL.md) skill to `~/.claude/skills/termux-doctor/`. The CLAUDE.md pointer tells claude to invoke it whenever it hits a symptom from this setup (segfaults, bad ELF errors, grep/patchelf weirdness, ...) instead of guessing — the skill carries the full trap list and self-repair playbook, loaded only when actually relevant rather than in every conversation's context.

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
  .last-claude-version   # last two `claude --version` strings seen by doctor.sh (previous, current) — powers update recognition at session start

$PREFIX/bin/claude               # wrapper — what actually runs when you type `claude`
$PREFIX/bin/termux-update-claude # manual update/rollback command

~/.claude/CLAUDE.md              # our section lives inside begin/end markers; rest of the file is yours
~/.claude/skills/termux-doctor/SKILL.md   # full trap list + self-repair playbook, invoked on demand
```

To change how any of this works, edit `scripts/` **in this repo** and re-run `install.sh` — don't hand-edit the installed copies under `~/.claude/claude-native/`; a future re-run overwrites them silently.

## Extra features (beyond a bare install)

- **Self-heal on every new shell** (`autocheck.sh`): fixes the execute bit, re-patches the interpreter if an unpatched build overwrote it, re-adds `DISABLE_AUTOUPDATER` and the `doctor.sh` `SessionStart` hook if either went missing, warns (without auto-editing) if the wrapper regressed to setting `LD_LIBRARY_PATH` via env. Silent when clean; only runs on interactive shell startup, never inside a Claude-spawned Bash-tool shell.
- **`doctor.sh` `SessionStart` hook**: runs the sanity check automatically at the start of every Claude Code session (see `install.sh` step 8 above). Only checked for staleness by `autocheck.sh` on shell startup, not re-run there — running the actual check on every interactive shell would be redundant with the session-start run.
- **Update recognition**: `doctor.sh` remembers the last `claude --version` string it saw (in `.last-claude-version`, alongside the one before it). If the binary running *this* session is a different build than last session's — typically right after `termux-update-claude` — it reports an `UPDATED: ... (was: ...)` line. That's a neutral recognition signal, not a warning, but it's still wired through the same `SessionStart` hook, so claude sees it in context at the start of the session and (per the `CLAUDE.md` pointer) mentions the version change to you unprompted instead of only surfacing it if you happen to ask.
- **Locking**: self-heal and `update.sh`'s install step share one `flock`, so two Termux tabs open at once can't corrupt the binary racing each other.
- **Repatch-frequency escalation**: 2+ re-patches in 24h escalates from a quiet fix notice to an explicit warning that `DISABLE_AUTOUPDATER` isn't actually holding.
- **Update / rollback**: `termux-update-claude` downloads → verifies SHA-256 → patches → installs, swapping in the new binary only after every check passes, with automatic retry/resume if the connection drops mid-download. `--rollback` restores the previous binary (kept as `claude.prev`; a rejected build is kept as `claude.rejected`, not deleted).
- **`settings.json` backup**: every time `install.sh`, `autocheck.sh`, or `uninstall.sh` is about to change `~/.claude/settings.json` (the `DISABLE_AUTOUPDATER` key or the `doctor.sh` `SessionStart` hook), it backs up the current file to `settings.json.bak` first. Restore with `cp ~/.claude/settings.json.bak ~/.claude/settings.json`; `doctor.sh` reports whether a backup exists and when it was taken.
- **Termux:API notifications** (optional — `pkg install termux-api` + the Termux:API app, not installed by `install.sh`): if `termux-notification` is available, a real (non-check-only) update failure and a repatch-frequency escalation (2+ re-patches in 24h) each push a notification, so they're not missed in a backgrounded tab. `doctor.sh` reports whether this is wired up.
- **`doctor.sh`**: one-shot diagnostic dump — arch, an ABI cross-check (`uname -m` vs Android's reported ABI, catches binary-translation layers), kernel `epoll_pwait2` risk check (cross-checked against whether the *installed binary* actually carries the upstream fix, not just the kernel version), paths, binary/interpreter state, leaked `LD_*` env, autoupdater-disabled check, `settings.json` backup status, whether Termux:API notifications are wired up, Termux build freshness (`TERMUX_VERSION`, `termux-tools` version, apt mirror — flags a likely stale/Play-Store install), glibc/patchelf version drift since the last run, `$HOME` mount `noexec` check, free disk space, `--version` (plus whether it changed since the last session — see "Update recognition" above). Run this first, before guessing.
  - `doctor.sh --json` — the same checks as one JSON object (needs `jq`), for scripting.
  - `doctor.sh --fix` — runs the same locked self-heal block `autocheck.sh` runs on every new shell (chmod, re-patch, re-add `DISABLE_AUTOUPDATER`), then the normal dump, as an explicit on-demand command instead of only at shell startup.
- **`termux-doctor` skill**: the trap list, self-repair design, and golden rules above live in a Claude Code skill (`~/.claude/skills/termux-doctor/`) instead of bloating every session's context via CLAUDE.md — claude invokes it on demand when it recognizes a symptom from this setup.

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
| 8 | Bare `grep` inside a Claude Code Bash-tool call fails with `-G: error while loading shared libraries: -G: cannot open shared object file` (real `command grep`/`rg` still work) | Claude Code injects a `grep` shell function into every shell it spawns that re-invokes *itself* as a hidden ripgrep-like "ugrep" personality: `exec -a ugrep "$CLAUDE_CODE_EXECPATH" -G ...`. Claude reads `process.execPath` (a `readlink /proc/self/exe` under the hood) and overwrites `CLAUDE_CODE_EXECPATH` with it before that re-exec, regardless of what the wrapper exported at startup. If the wrapper's last line explicitly `exec`'d `ld-linux --library-path ... claude`, the kernel records *ld-linux* — not the `claude` binary — as the process's exe_file, so the overwritten value points at the linker, and the function ends up running it with grep-style flags, which it can't parse. | Have the wrapper `exec` the patched binary directly, with no explicit `ld-linux` invocation — the kernel then records the binary itself as exe_file, so `process.execPath` (and the re-exec) resolves correctly. This works because the patched ELF can be `exec`'d directly: Termux's `ld.so.cache` already lists the glibc lib dir as a system search path, so no `--library-path` flag is needed. Fall back to the old `ld-linux --library-path` form only if a preflight `--version` check shows direct-exec doesn't work on a given install. As with trap #1, a currently-running session already inherited the old value — fully quit and reopen Termux for the fix to take effect. |
| 9 | `claude` segfaults immediately on launch, no useful error | **Not a seccomp block.** `strace` on a real crash shows no `epoll_pwait`/`epoll_pwait2` syscall entry at all before the `SIGSEGV` — Bun's maintainer traced it to a TLS fault *inside glibc's generic `syscall()` wrapper itself*, triggered when Bun's kernel-version gate decides the kernel is 5.11+ and attempts `epoll_pwait2` through that wrapper. Confirmed in the wild on an OPPO CPH2499, Android 16, kernel 5.15.180. **The kernel version is fixed at the device's original manufacture** (Android's KMI ties vendor kernel modules to one specific kernel build) and does not change on an OS upgrade — a phone can show "Android 16" in Settings while still running the kernel it shipped with years earlier on Android 12. So the Android version shown in Settings tells you nothing here; only the real kernel does. | **Fixed upstream** in [oven-sh/bun#32490](https://github.com/oven-sh/bun/pull/32490): the syscall is now issued via raw inline asm (no generic wrapper, no TLS fault), the kernel-version gate also skips `epoll_pwait2` whenever the `uname` release string contains `-android`, and a `BUN_FEATURE_FLAG_DISABLE_EPOLL_PWAIT2=1` env var force-disables it. Whether *your* install is safe depends on the bundled Bun version, not just the kernel — `doctor.sh` checks for the fix (`strings claude \| grep BUN_FEATURE_FLAG_DISABLE_EPOLL_PWAIT2`) rather than assuming every 5.11+ kernel is unpatched. The wrapper also sets that env var unconditionally as a harmless belt-and-suspenders. If you still hit this on an old Claude Code build that predates the fix, [gtbuchanan/claude-code-termux](https://github.com/gtbuchanan/claude-code-termux) ships a working LD_PRELOAD shim. |

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

Removes `claude` / `termux-update-claude`, the `~/.bashrc` hook, `DISABLE_AUTOUPDATER`, the `doctor.sh` `SessionStart` hook, the self-repair scripts, the `termux-doctor` skill, and our section of `~/.claude/CLAUDE.md` (only what's between its markers — anything else in that file is untouched). Keeps the ~300MB binary + `manifest.json` cached by default so a future install skips the download; `--full` wipes that too.

Either way, it leaves the Termux packages (`glibc`, `patchelf`, `jq`, `ripgrep`, ...) and the cloned repo directory alone — neither is exclusively this project's to remove; `uninstall.sh` prints the command if you want them gone too.

## Contributing

The issues and fixes above came from real breakage, not speculation. Hit a new one on a different Termux/glibc version? A PR adding it to the table (symptom → cause → fix) is exactly the contribution this repo wants.

## License

MIT for the scripts — see [LICENSE](LICENSE). The `claude` binary is downloaded from, and remains the property of, Anthropic, under [its own terms](https://www.anthropic.com/legal).
