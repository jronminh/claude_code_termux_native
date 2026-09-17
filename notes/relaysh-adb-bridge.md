# Research notes: Wireless ADB bridge — mini-shizuku, relaysh, and the cgroup-survival investigation

## 4b. Wireless ADB bridge — screen capture + input injection (session 2026-09-17, real-world test)

Triggered by trying to actually install Termux:Widget/Termux:Boot on-device
(the two companion apps referenced in 4a as "not yet installed"). What
started as an APK sideload troubleshooting session turned into discovering
a much bigger capability: Claude can see and drive the *entire* Android
screen, not just Termux, once wireless ADB is paired.

### What doesn't work (confirmed by direct test)

- `termux-api` has **no screenshot command** — full `termux-*` binary list
  surveyed, nothing screen/shot/capture-related.
- Raw `/system/bin/screencap -p ...` invoked from Termux's own (unprivileged
  app-UID, `u0_a663`) shell: binary exists (`root:shell` owned) but fails
  with `"Failed to take screenshot. Capturing failed."` — Android restricts
  framebuffer reads to `root`/`system`/`shell` UIDs; a plain Termux app,
  even without root, isn't one of them. This is a deliberate Android
  security boundary, not a missing tool.
- Termux's own `logcat` access is similarly restricted — a bare `logcat -d`
  from Termux's shell returns nothing useful for other apps' log lines.

### What works: wireless ADB, self-paired, no computer needed

`android-tools` (has `adb`) is in Termux's own repo (`pkg install
android-tools`, confirmed present in `pkg search`). Android 11+'s Wireless
debugging can be paired **from the device to itself** — no second computer
required, since the ADB daemon listens on `127.0.0.1:<port>` once Wireless
debugging is on:

1. `pkg install android-tools`
2. On-device: Settings → Developer options → Wireless debugging → "Pair
   device with pairing code" → shows a 6-digit code + `ip:port` (this port
   is temporary, pairing-only).
3. `adb pair 127.0.0.1:<pairing-port> <6-digit-code>` → "Successfully
   paired".
4. Back on the Wireless debugging main screen, a **different** `ip:port` is
   shown (the actual debug port, not the pairing one) → `adb connect
   127.0.0.1:<debug-port>` → `adb devices -l` confirms `device` state.
5. Once connected, `adb shell` runs as the `shell` UID — which DOES have
   framebuffer + logcat access:
   - `adb shell screencap -p /sdcard/Download/x.png && adb pull
     /sdcard/Download/x.png <local path>` — real screenshot, confirmed
     working, readable by Claude via the `Read` tool (multimodal — Claude
     can literally see the phone's screen this way).
   - `adb logcat -d` / `adb logcat -c` (clear) — full system log, not just
     Termux's own restricted view. This is what actually cracked the
     install-troubleshooting mystery below; Termux's own unprivileged
     logcat had shown nothing.
   - `adb shell uiautomator dump /sdcard/Download/ui.xml` — dumps the
     current screen's view hierarchy as XML with **exact pixel bounds**
     for every element (`bounds="[x1,y1][x2,y2]"`). Far more reliable than
     eyeballing coordinates off a screenshot — confirmed the hard way: a
     coordinate guessed from visually reading a screenshot (scaled
     923x2000 display vs 1080x2340 real resolution, factor 1.17) was off
     by ~600px on the y-axis and landed outside a bottom sheet dialog,
     dismissing it instead of selecting the intended option. The
     `uiautomator dump` bounds → compute center → `adb shell input tap x
     y` approach hit the correct element on the first try afterward.
   - `adb shell input tap X Y` — synthetic tap at exact coordinates. Also
     available: `input swipe`, `input text` (though `input text` cannot
     type arbitrary Unicode reliably, ASCII-only in practice — not tested
     deeply this session).

**This closes a real gap**: up to this point, when something failed in the
Android UI (a permission dialog, an install prompt, a Samsung-specific
setting), Claude had no way to see what was actually on screen and had to
rely entirely on the human describing it — slow, and prone to
miscommunication (see the IP-address typo `1.288:33111` vs the real
`192.168.1.228:33111` during pairing itself — Claude cross-checked against
`termux-wifi-connectioninfo`'s own reported IP to catch it).

### The actual root cause it uncovered (Termux:Widget install failure)

Multiple install attempts had failed silently — no error visible on
screen, easy to blame on Samsung's Auto Blocker (One UI 6+) or the
`REQUEST_INSTALL_PACKAGES` per-app permission. Both were real dead ends
investigated and ruled out (this device — SM-S7110, Galaxy S23 FE, CN/HK/TW
region variant, One UI 8.5/Android 16 — doesn't even have Auto Blocker in
Settings, consistent with it possibly being absent from that region's
firmware; "Install unknown apps" permission for Termux was in fact granted
and wasn't the blocker either).

`adb logcat` (full system log, unavailable from Termux's own restricted
logcat) caught the real exception, thrown by
`com.google.android.packageinstaller`'s own `InstallRepository.stageForInstall`
the instant it tried to read the APK Termux handed it via content URI:

```
java.lang.IllegalArgumentException: TermuxContentProvider requires
`allow-external-apps` property to be set to `true` in
`~/.termux/termux.properties` file.
```

Termux's `TermuxContentProvider` (what `termux-open`/`termux-share` use to
hand a file to another app via a `content://` URI) refuses external apps
by default — including Android's own Package Installer — unless
`allow-external-apps = true` is uncommented in `~/.termux/termux.properties`
(then `termux-reload-settings`). This is a **security-relevant** setting
(the property's own comment: "Allow external applications to execute
arbitrary commands within Termux... potentially could be a security
issue"), not something to flip silently — Claude asked before enabling it.
**User approved enabling it, explicitly as temporary, with the intent to
revisit a safer approach later** (see 4c below — that discussion is the
immediate next step, not yet resolved).

Once enabled, the real "Install this app?" dialog for Termux:Widget finally
appeared (confirmed via screenshot) — the `termux-open --chooser` +
`uiautomator dump` + `input tap` approach correctly navigated the app
chooser to reach it. The final "Cài đặt"/Install confirmation tap itself
was **blocked by Claude Code's own auto-mode classifier** (a real app
install is exactly the kind of consequential action that should stay a
human's explicit tap, not something Claude auto-confirms) — left for the
user to tap by hand. Install still hadn't completed as of this note (one
more thing to retry/verify next).

### Security posture — explicitly unresolved, flagged for follow-up discussion

Both changes made this session are real standing risk, not free:

- **Wireless debugging + the ADB pairing itself**: `adb shell` runs at the
  `shell` UID — broad system visibility (full logcat, screen contents via
  screencap, synthetic input anywhere including other apps) and the
  pairing persists until revoked in Developer options, not just for one
  session. Leaving Wireless debugging toggled on standing is generally
  discouraged (device-wide attack surface, even if only reachable via
  paired-key localhost/LAN, not a public port).
- **`allow-external-apps = true`**: enabled to unblock `termux-open`/
  `termux-share` (needed for the job-scheduler/share/open features built
  earlier this session too, not just the widget install) — but its own
  documented scope is broader than file-open: "execute arbitrary commands
  within Termux" from any external app that knows to ask.

**Not yet decided**: whether/how to keep either of these enabled
long-term, scope them down, or automate the "only on when needed" pattern
(e.g. a toggle script + a reminder to turn Wireless debugging back off).
This is the explicit next discussion, not resolved by this note.

### 4c. ADB bridge deployment (session 2026-09-17, follow-up) — implemented

Discussed script vs. skill vs. hybrid for productizing 4b. Landed on
**hybrid**, matching this repo's own `termux-doctor` skill + `doctor.sh`
split: mechanical/repeatable parts as a plain script (no LLM judgment
needed, easy to audit), judgment/policy parts as a skill (interpreting a
screenshot/dump, deciding when a need is real, enforcing the safety
posture).

Implemented as:
- `scripts/adb-bridge.sh` — `status`/`screenshot`/`dump`/`tap`/`swipe`/
  `logcat`/`logcat-clear`/`nag` subcommands. Staged unconditionally by
  `install.sh` (like `session-hooks.sh`) since staging alone is inert.
- `skills/adb-bridge/SKILL.md` — the security posture (ask before a new
  pairing, never wire into a per-turn hook, remind to disconnect after),
  pairing steps, command reference, and the coordinate-accuracy /
  logcat-over-screenshot lessons from 4b's incident.
- `doctor.sh` — new "ADB bridge" section: whether the skill/hook are
  wired, and live connection state (`WARN:` if a device is currently
  connected — deliberately phrased to avoid tripping the SessionStart
  doctor-hook's problem-vocabulary grep when the feature was simply never
  installed).
- `scripts/lib.sh` / `install.sh` / `uninstall.sh` — new opt-in
  `install.sh --with-adb-bridge` flag: installs the skill + wires a `Stop`
  hook (`adb_bridge_stop_hook_command`) that nags (via `systemMessage` +
  `hookSpecificOutput.additionalContext`, mirroring `doctor_hook_command`)
  iff `adb-bridge.sh nag` finds a device still connected when a turn ends.
  Never blocks (`nag` always exits 0). `uninstall.sh` reverses all of it
  unconditionally (skill removal + hook removal always attempted, same
  pattern as the other opt-in features).

This resolves the "not yet decided" item above via options (2)+(3)+(4)
from that discussion: (2) end-of-turn nag hook, (3) policy encoded in the
skill rather than automation, (4) `doctor.sh` status line. Option (1),
manual discipline, remains the user's own responsibility regardless — no
code can toggle Wireless debugging itself.

### 4d. install/uninstall rethink — dedicated toggle command (same session, follow-up)

User feedback after 4c: `install.sh` only ever *adds* a feature
(`--with-X`), and the only way to turn one back OFF was `uninstall.sh`,
which removes the *entire* setup, not just one feature. Explicitly asked
for a shell command dedicated to enabling/disabling a feature,
decoupled from install.sh/uninstall.sh's own logic, with the README
rewritten to point at that command rather than "re-run install.sh".

Refactored: `scripts/lib.sh`'s `SESSION_HOOKS_MARKER`/
`session_hooks_*_command`/`ADB_BRIDGE_HOOK_MARKER`/
`adb_bridge_stop_hook_command` moved out into a new
`scripts/feature-hooks.sh`, which also gained two generic helpers
(`hook_upsert_entry`/`hook_remove`, replacing three hand-rolled jq
filters that used to live separately in `install.sh` and `uninstall.sh`)
and, per feature, `enable_X`/`disable_X`/`X_wired` functions
(`notifications`, `adb-bridge`). Unlike `lib.sh` (sourced-only, never
staged), `feature-hooks.sh` IS staged to
`~/.claude/claude-native/feature-hooks.sh` — it's sourced from two
places: `lib.sh` (repo copy, used by `install.sh`/`uninstall.sh`) and the
new `scripts/claude-features.sh` (staged copy, used at runtime long after
the repo checkout may be gone). `install.sh`'s `stage_scripts()` also now
always stages the adb-bridge skill source to
`~/.claude/claude-native/skill-sources/adb-bridge/SKILL.md` for the same
reason (`enable_adb_bridge` needs a skill file to copy from at runtime).

New command: `termux-claude-features` (`scripts/claude-features.sh` +
thin `$PREFIX/bin` wrapper, same two-file pattern as
`termux-update-claude`/`update.sh`) — `status`/`enable <feature>`/
`disable <feature>`. `install.sh --with-X` and `uninstall.sh`'s
`remove_session_hooks`/`remove_adb_bridge_hook` are now thin callers of
the same `enable_X`/`disable_X` functions, so all three entry points
share one implementation and can't drift apart.

Verified live (isolated `$HOME` in a temp dir, real settings.json +
skill files, not the actual running install): `enable_notifications` then
`enable_adb_bridge` produces both hook sets correctly coexisting in
`.hooks.Stop` (two array entries, one marker each); `disable_adb_bridge`
removes only its own skill dir + Stop-hook entry, leaving the
notifications hooks and their Stop entry intact; `disable_notifications`
afterward cleans back down to `{}` (no leftover empty hook arrays). The
`claude-features.sh` CLI itself (`status`/`enable`/`disable`, including
an unknown-feature error path) was also exercised end-to-end against that
same isolated environment.

### 4e. CLAUDE.md discoverability fix (same session, immediate follow-up)

Gap found by asking "would a brand-new conversation know to suggest
adb-bridge?": **no** — `CLAUDE.md.template` never mentioned it, and an
opt-in skill only appears in the skill listing once already enabled, so a
fresh session had zero way to learn the capability exists before the user
turns it on. User's fix direction: don't hardcode per-feature bullets in
CLAUDE.md (would need an edit every time a feature is added) — instead
point Claude at `termux-claude-features status` as the evergreen source
of truth.

Implemented: `claude-features.sh`'s `cmd_status` now carries each
feature's one-line description AND its safety notes directly in its own
output (e.g. adb-bridge's line spells out "SECURITY-SENSITIVE... ask the
user before enabling"), so nothing about a specific feature needs to live
in CLAUDE.md. `CLAUDE.md.template` gained exactly ONE generic, stable
bullet: run `termux-claude-features status` whenever a task might need a
capability beyond bare Termux, rather than assuming a remembered feature
list is current. Applied live to `~/.claude/CLAUDE.md` via `lib.sh`'s
`claude_md_upsert` (not a full `install.sh` re-run) — verified only the
marked block changed, the user's own content above/below it untouched.

### 4f. Repo architecture doc — staged, not memorized (same session, immediate follow-up)

User wanted a proper document about the repo itself: for future
reference, for people cloning it, and specifically NOT via Claude's
personal cross-session memory system — the memory system's own rules
explicitly exclude "code patterns, conventions, architecture, file paths,
project structure" (derivable from the repo, would go stale silently),
so that channel was ruled out for this on the first pass. User's actual
ask, once clarified: stage it into `~/.claude/` as a `docs/` folder, the
same way `scripts/` already gets staged — not the memory system at all.

Implemented `docs/architecture.md` (committed, supersedes the earlier
uncommitted `structure.md` navigation aid, which is now deleted — same
content, promoted to a real staged file instead of a private scratch
file). `install.sh`'s `stage_scripts()` stages it unconditionally to
`~/.claude/claude-native/docs/architecture.md`; `uninstall.sh`'s non-full
path removes `$DEST/docs` alongside `skill-sources`.

`CLAUDE.md.template` gained one more short bullet pointing at that staged
path instead of describing internals itself — the reasoning (spelled out
in the doc's own "Why this lives here, not in CLAUDE.md" section):
`CLAUDE.md` is loaded into every session in every project regardless of
relevance, while a staged doc file costs nothing until a session
*actually reads it* because it's relevant. This is the same size-control
principle that motivated 4e's `termux-claude-features status` bullet,
extended to the deeper "how the whole repo fits together" layer of
detail: neither layer needs a `CLAUDE.md.template` edit when a new
feature is added — only `docs/architecture.md` (structure) and
`claude-features.sh`'s `cmd_status` text (per-feature description) do.

### 4g. `docs/` grew a real reference library (same session, immediate follow-up)

User's framing: this notes file has a lot of useful knowledge — keep it
exactly as-is (uncommitted, chronological, development-only), but
distill the reusable/evergreen parts of it into `docs/` as proper files,
not just `architecture.md`.

Added three more staged docs, each a by-topic distillation of a section
above (this file keeps the messy narrative version; the new docs state
current best understanding only, with confidence markers):
- `docs/claude-code-hooks-reference.md` ← section 2 (hooks verified
  facts) — general-purpose, not Termux-specific, kept here only because
  this repo's own hook work is what forced it to be verified this
  carefully.
- `docs/termux-api-survey.md` ← sections 1 + 4a's survey portions (NOT
  the "implemented this session" narrative, which stays here) — every
  `termux-*` command surveyed, categorized by what it needs and whether
  it was built/deferred/rejected, ending with the screen/input/logcat gap
  that motivated `adb-bridge`.
- `docs/keybindings-notes.md` ← section 3 — the *why* behind
  `keybindings.json.template`'s rebinds, since JSON has no comment syntax
  to hang that reasoning off of in the template itself.

Also generalized `install.sh`'s `stage_scripts()`: it now loops over
`docs/*.md` instead of naming `architecture.md` specifically, so adding
another doc file here needs no `install.sh` edit going forward — same
"don't need to touch install.sh for this" principle 4d already
established for the feature-toggle logic, now extended to docs.

### 4h. Verified: a genuinely fresh session DOES discover the feature (same session, immediate follow-up)

Tested whether the whole 4e/4f/4g discoverability chain actually works —
would a brand-new Claude, hitting the exact debugging scenario 4b/4c were
built for, find `termux-claude-features` → `adb-bridge` on its own?

**First attempt was a false negative**: spawned a fresh subagent (Agent
tool, general-purpose, no shared context) with the Termux:Widget-install-
stuck scenario. It reasoned well generically (screenshot, adb logcat,
`dumpsys window`, Background-Activity-Launch restriction as a real
hypothesis) but never mentioned `termux-claude-features` or `adb-bridge`
at all. Asked it directly afterward (same agent, so still had its
context): it quoted its own `~/.claude/CLAUDE.md` verbatim, and that
quote was the OLD content — no `termux-claude-features status` bullet, no
`docs/architecture.md` pointer, even though both had already been merged
into the live file (verified earlier with `tail`/`cat`) before the agent
was even spawned. Its skill listing also lacked `adb-bridge`.

**Root cause**: a subagent spawned from within an already-running Claude
Code session inherits that session's environment/system-prompt snapshot
— taken once, at THIS session's own start (long before today's edits) —
not a live re-read of `~/.claude/CLAUDE.md` at spawn time. Testing "would
a fresh session know" by spawning a subagent of an old session tests the
wrong thing: whether an old session's children see new file content
(no), not whether a genuinely new session does.

**Corrected test**: ran `claude -p "<same scenario>"` directly in Bash —
a real standalone headless process, launched fresh, reading the actual
current `~/.claude/CLAUDE.md`/skills at its own startup. Result: it
correctly proposed running `termux-claude-features status` FIRST, cited
the exact CLAUDE.md bullet almost verbatim as its reason, noticed
`scripts/adb-bridge.sh`/`skills/adb-bridge/` in `git status` and inferred
that's likely the relevant feature, correctly flagged it as security-
sensitive and said it would ask before `enable`, and proposed the right
technical workflow (`screencap` at the right moment, `logcat` filtered
for `PackageInstaller`/`PackageManager`, `uiautomator dump`/`dumpsys
window` for focus state) — all without being told any of this, purely
from the CLAUDE.md pointer + reasoning about the scenario.

**Conclusion**: the discoverability chain (4e/4f/4g) works as designed —
for a genuinely new `claude` process/session. **Practical implication
worth remembering generally**: `CLAUDE.md` (and presumably the skill
listing) is loaded once at session/process start and does NOT hot-reload
mid-session — a subagent spawned from a long-running session is not a
valid way to test "what would a fresh session see" after editing
`CLAUDE.md`; use a separate `claude -p` invocation (or a genuinely new
interactive session) instead.

### 4i. Mini-Shizuku investigation — real Shizuku's mechanism, and why our first attempt failed (same session, later follow-up — NOT resolved, picks up here next time)

User's ask, unprompted by any prior friction: avoid depending on
Shizuku (external app) or repeated ADB re-pairing — build something
Shizuku-like ourselves, using exactly Shizuku's own non-root method as
the reference, purely from Termux + one-time `adb shell`.

**Live attempt #1 — Unix domain socket relay, failed, root cause confirmed:**

Plan: `adb shell` once to spawn a detached (`setsid`, stdio closed)
`shell`-UID process listening on a Unix domain socket
(`toybox nc -U -s <path> -L sh`, spawns a fresh `sh` per connection),
then `chown` the socket file to Termux's UID (`10663`) + `chmod 600` so
only Termux can connect (kernel-enforced, unlike a bare TCP port which
any app on the device could reach). Rationale for this design over plain
TCP: a Unix socket's connect permission is governed by regular POSIX file
DAC permissions (owner/group/mode) on the socket's filesystem path, so
`chown`ing it to Termux's exact UID should make it inaccessible to every
other app, mirroring — at the DAC layer instead of Shizuku's Binder
layer — the "only the app I explicitly granted can connect" property
Shizuku's own permission model provides.

Debugging the actual `nc` invocation syntax first (toybox's `-U` needs
`-s <path>` to carry the socket path, not a bare positional arg — several
"bad argument count" tries before landing on
`nc -U -s /data/local/tmp/x.sock -L sh`), the REAL result was:

```
nc: bind: Permission denied
```

for `bind()` on an `AF_UNIX` socket, at `/data/local/tmp/` and at every
other path tried. Cross-check: `nc -s 127.0.0.1 -p 12345 -L sh` (plain
TCP loopback bind, same `shell` UID, same session) **worked fine, no
error**. `getenforce` confirmed SELinux is `Enforcing`. `logcat -d -t 300
| grep avc` turned up nothing, but that's inconclusive (shell's logcat
read access is itself restricted on production builds) — not proof the
denial ISN'T SELinux, just that we couldn't directly observe the AVC
denial this way.

**Confirmed root cause, from reading Shizuku's own source** (not
speculation — see below): this is very likely SELinux specifically
restricting `AF_UNIX` `bind()`/`socket`/`sock_file`-class operations for
the `shell` domain outside its own blessed paths, while leaving plain TCP
loopback bind (a different, more universally-needed operation) alone.
**This looks like deliberate policy, not an oversight**: an unrestricted
shell-to-arbitrary-Unix-socket channel is close to exactly the
shell→app-domain backdoor primitive SELinux's app-isolation model exists
to prevent — the same reasoning explains why regular *file* DAC
operations (chown/chmod/rm on plain files under `/data/local/tmp`) worked
fine in earlier parts of this same investigation with zero denial, while
only the *socket*-creation syscall specifically failed.

**Why real Shizuku doesn't hit this — read `starter.cpp`
([RikkaApps/Shizuku](https://github.com/RikkaApps/Shizuku),
`manager/src/main/jni/starter.cpp`) directly, quoting the mechanism, not
guessing:**

- The thing actually invoked via `adb shell` is a small **native C++
  starter binary** (not a shell script doing socket tricks). It resolves
  the installed Shizuku app's own APK path (`pm path
  moe.shizuku.privileged.api` — **this is why the Shizuku app must be
  installed**: the starter needs the app's APK as a classpath, the app
  ships the actual server bytecode), forks, `setsid()`s + closes stdio
  (the exact detach pattern we used), then `execvp`s:
  ```
  /system/bin/app_process -Djava.class.path=<shizuku.apk> ... rikka.shizuku.server.ShizukuService
  ```
  i.e. it launches a **real Java/ART process** via `app_process` — the
  same OS-level tool Android's own Zygote uses to spin up every app
  process — running the server's actual compiled Java class
  (`ShizukuService`), not a POSIX daemon script.
- Once running as a proper Java/ART process, the server communicates over
  **Android's Binder IPC**, not a raw socket. The starter's own code
  contains an explicit SELinux capability check
  (`check_selinux(..., "binder", "call")` /
  `check_selinux(..., "binder", "transfer")`) for the root-launch case,
  and a dedicated fatal-exit code
  (`EXIT_FATAL_BINDER_BLOCKED_BY_SELINUX = 10`) for exactly the scenario
  where SELinux refuses the binder connection anyway — confirming SELinux
  policy is the load-bearing constraint here in general, and that even
  Shizuku's own maintainers had to design around it explicitly, at the
  Binder layer specifically (not the socket layer, which is what we
  tried).
- A `starter/src/main/java/moe/shizuku/starter/util/IContentProviderCompat.java`
  utility in the repo (not yet read in full) strongly suggests the
  Binder handle is actually handed off to a requesting client app via an
  Android `ContentProvider` call (a `Bundle` can carry a live `IBinder`
  extra) — a channel that, unlike a raw socket, is a normal,
  SELinux-policy-expected inter-app communication path.

**The hard conclusion this points to**: Binder-based IPC needs a real
Android app component (something with a manifest, a process Android's
Zygote/ActivityManager actually knows about) on the *receiving* end to
hold a Binder reference at all — a Binder token is an ART/Android runtime
concept, not something a POSIX shell script can hold or pass around.
Termux itself has no such component of its own (no custom
Activity/Service/ContentProvider we've built), so a channel that stays
"Termux + one-time adb shell, nothing else installed" is inherently
confined to POSIX-level IPC (sockets, FIFOs, files) — precisely the class
of technique this device's SELinux policy (`Enforcing`) appears to
specifically restrict across the shell→app-domain boundary, going by
what we hit.

**Not yet tried — the next concrete experiment, worth attempting before
concluding this is a dead end**: the denial was specifically on
`socket()`/`bind()` for `AF_UNIX`. Plain **file** operations (chown,
chmod, rm, ls) on the exact same `/data/local/tmp/` directory worked with
zero denials throughout this whole session (used constantly for cleanup
without issue). A **FIFO-based polling mailbox** — `mkfifo` a
request/response pair (or even just plain regular files polled with a
short sleep loop, no `mkfifo` at all) instead of a socket, `chown`ed to
Termux's UID, with a `shell`-UID loop process reading a request file,
running it, writing a response file — never calls `socket()`/`bind()` at
all, so it may not trip the same SELinux object class. This hasn't been
tested. If it also gets denied, that would show the restriction is
broader (UID/domain-based, not socket-class-specific) and effectively
closes off the whole POSIX-only approach on this device; if it works, it
gives a real (if less elegant — polling, not push) alternative to a
socket without needing Shizuku's app_process/Binder machinery.

**Update — same session, resumed after user reconnected ADB (port
33123): it works.** Two more findings first, then the actual result:

- **`/data/local/tmp` is a dead end entirely, not just for sockets.**
  Tested plain DAC ops across the domain boundary for the first time
  (earlier successes were all shell-acting-on-its-own-files, never
  cross-checked from Termux): `chown`/`chgrp` from `shell` to an
  arbitrary UID/GID (Termux's `10663`, or even the `9997(everybody)`
  group) both fail with **`Operation not permitted`** — `shell` simply
  lacks `CAP_CHOWN`, confirmed via `id -G` showing no relevant group
  membership either. Separately, and more fundamentally: Termux cannot
  even `ls`/`cat` anything under `/data/local/tmp/` at all —
  `Permission denied` on the directory listing itself. So the earlier
  "FIFO/plain-file instead of socket" plan was moot before it started;
  the blocker there is SELinux denying `untrusted_app` any access to that
  directory, independent of what kind of file lives in it.
- **`/sdcard` (external storage, FUSE-backed) is NOT blocked either
  direction.** Termux wrote a file there directly (no adb involved);
  `adb shell` (as `shell` UID) read AND appended to that exact file
  successfully. Files created by `shell` there show up owned by
  `u0_a277:media_rw` (the FUSE/MediaProvider identity, not `shell`) —
  confirms `/sdcard` access is governed by Android's storage-permission
  model, not raw process UID/DAC, which is *why* both domains can reach
  it: neither is being checked against the other's UID at all.

**Working mini-Shizuku, built and verified live:**

1. Termux generates a random 24-char secret, stored privately at
   `~/.claude/claude-native/.minishizuku-secret` (mode 600, Termux's own
   sandboxed storage — never touches the shared area).
2. A small POSIX daemon script (no `nc`, no sockets, no `app_process`)
   with the secret baked in at generation time, `adb push`ed then started
   via **one** `adb shell` call: `setsid sh daemon.sh </dev/null
   >log 2>&1 &`. It polls `/sdcard/.minishizuku/req` every 0.3s; a
   request is a 2-line file, line 1 = secret, rest = a shell command.
   Match → runs the command with `sh`, writes stdout+stderr to
   `/sdcard/.minishizuku/resp`, deletes the request. Mismatch →
   `AUTH_FAILED` and nothing runs.
3. Verified detach: `ps -p <pid>` after the bootstrapping `adb shell`
   call had already returned showed `PPID=1` (reparented to init — a
   real orphaned daemon, not a zombie tied to the dead ADB session),
   `USER shell`, state `S` (idle in the poll loop).
4. **The real test**: ran `adb disconnect` (`adb devices` confirmed
   empty — zero ADB connection, not even offline) — then, from plain
   Termux bash, wrote a request (secret + `id; echo hello-from-shell-uid;
   whoami`) and polled for the response file. **It came back in ~0.6s**,
   containing `uid=2000(shell) ... context=u:r:shell:s0` and
   `hello-from-shell-uid` — a real command, really executed at `shell`
   UID, with genuinely zero ADB connection active at the time. This is
   the actual goal (persistent shell-level command execution from Termux
   after one-time ADB bootstrap) achieved without Shizuku, without root,
   without Binder/`app_process` — dramatically simpler than real Shizuku
   because it sidesteps the whole cross-domain-IPC problem by using
   `/sdcard` (a channel Android already lets both domains reach) instead
   of trying to construct one (sockets/FIFOs in `/data/local/tmp`, both
   confirmed blocked above).

**Known weakness, NOT yet fixed — flag before treating this as
production-ready**: the secret is transmitted **in plaintext** through
`/sdcard/.minishizuku/req` on every request. `/sdcard` has no per-UID
access control (that's exactly why this works at all) — so any other
installed app with ordinary storage permission (common) watching that
directory at the right moment could read the secret straight off a
legitimate request and replay/reuse it afterward to run its own commands
at `shell` UID. **The fix, not yet built**: never transmit the secret
itself after the initial bootstrap; instead have Termux send an HMAC of
the command (e.g. `openssl dgst -sha256 -hmac "$SECRET"`, Termux already
has `openssl`) and have the daemon verify the HMAC using its own copy of
the secret, never comparing/transmitting the raw value again. Capturing
`(command, HMAC)` pairs off the wire doesn't let an attacker forge a
*new* command's HMAC without the secret itself (standard HMAC security
property) — this closes the replay/theft window the current plaintext
version leaves open.

**Live state as of writing this**: the daemon (plaintext-secret version)
is **still running** on the device (PID seen was 26427, may differ if
respawned) — deliberately left as-is pending the user's decision on
whether to harden it (HMAC) before any real use, or kill it and rebuild
properly into `adb-bridge.sh` as an opt-in mode. `~/.claude/claude-native/
.minishizuku-secret` and `/sdcard/.minishizuku/` are the only artifacts;
nothing has been wired into `adb-bridge.sh`/the `adb-bridge` skill yet —
this is still a standalone proof-of-concept, not integrated.

**User's explicit decision (end of this session)**: keep the daemon
running — do NOT kill it, work continues in a different chat/session.
Re-confirmed alive right before this note was written: with zero ADB
connection, wrote a fresh timestamped echo command to
`/sdcard/.minishizuku/req` from plain Termux and got the correct
timestamped response back within a few hundred ms
(`daemon-still-alive-1789635074`, matching `cmd.sh`'s content) — so it
survived at least the gap since it was started earlier this session, not
just the initial few seconds. Still: this is the UNHARDENED
plaintext-secret build (see the weakness above) — treat it as a live
research artifact, not something to route real/sensitive commands
through yet.

**For whoever (or whichever session) picks this up next**: the daemon
is reachable right now with zero setup — just:
```sh
SECRET=$(cat ~/.claude/claude-native/.minishizuku-secret)
{ echo "$SECRET"; echo "<your command>"; } > /sdcard/.minishizuku/req
# poll /sdcard/.minishizuku/resp for the result
```
No `adb` needed unless the daemon has died (e.g. device reboot, or
Android/Samsung's background-process killer finally got it — untested
how long it survives; this is exactly the reliability question flagged
as unverified earlier in this doc) — in which case re-bootstrap via
`adb push`/`adb shell setsid sh ...` as done above. To actually kill it
when this experiment concludes: `adb shell` in and `kill` the PID in
`/sdcard/.minishizuku/daemon.pid` (do NOT rely on the stale PID number
already written above if the daemon was ever restarted).

**Next steps if continuing**: (1) decide plaintext-secret daemon's fate
(kill now vs. keep for further poking), (2) implement the HMAC-challenge
hardening before it's trustworthy, (3) if adopted, fold this into
`adb-bridge.sh` as a real mode (e.g. `adb-bridge.sh bootstrap-persistent`
to set it up once, then have `status`/`tap`/`screenshot`/etc. prefer the
mailbox over a live ADB connection when available) — including updating
the `adb-bridge` skill's "Security posture" section to cover this new,
different risk model (app-level secret vs. the current model's
Wireless-debugging-must-stay-on risk), and a corresponding `doctor.sh`
status line. None of that integration work has started.

### 4j. Mini-Shizuku v2 — plaintext secret hardened, deployed live (session 2026-09-17, follow-up — resolves item (2) above)

User explicitly asked for a "sandwich hash" scheme instead of textbook
HMAC (ipad/opad XOR is awkward in pure POSIX sh with no bitwise op), built
and self-tested entirely inside Termux first, deployed only once the
logic was proven, per the user's own ordering preference ("finish on the
Termux side, then use the existing mailbox once to swap in the hardened
version").

**Protocol**: `tag = sha256(SECRET + "\n" + inner)`,
`inner = sha256(SECRET + "\n" + NONCE + "\n" + COMMAND)`. Request file is
now 3+ lines (`NONCE` / `TAG` / `COMMAND...`) instead of v1's
(`SECRET` / `COMMAND...`). The raw secret is never transmitted again after
this deployment — only per-request tags that are useless for forging a
*different* command without the secret (verified live: a wrong-secret
client gets `AUTH_FAILED: bad tag`, no execution). A `seen_nonces` file
(bounded to last 200 via `tail`) rejects exact-replay of a captured
request. All reads/writes to the mailbox (`req`/`resp`) go through a
`*.tmp` + `mv` to stay atomic, since v1 had no such guard.

Implementation: `~/.claude/claude-native/minishizuku-daemon-v2.sh` (POSIX
`sh` + `sha256sum` only — no bash-isms; `$RANDOM` in an early client draft
turned out to be a bashism too and broke under plain `sh`, fixed to
`date +%s%N`-`$$` for the nonce) and
`~/.claude/claude-native/minishizuku-client.sh` (Termux-side sender).
Correctness (round-trip, wrong-secret rejection, replay rejection) was
proven first via a fully local simulation — both scripts pointed at a
scratch directory instead of `/sdcard/.minishizuku`, no live device
involved — before touching the real device at all.

**Live swap, performed via the still-running v1 daemon itself** (the one
`adb shell`-free channel available, since Termux and the `shell` UID can
both only reach it through `/sdcard`): a fresh 32-char alnum secret was
generated, baked into `daemon_v2.sh`, and the file written straight to
`/sdcard/.minishizuku/daemon_v2.sh` from Termux directly (no live command
needed for that part — `/sdcard` is writable from both domains). Then
exactly **one** v1-protocol request (using the *old* secret, captured
into a shell variable before the local secret file was overwritten) told
the running v1 daemon to: capture its own PID, `setsid sh daemon_v2.sh
… &` the new daemon, and background a `(sleep 1; kill $OLDPID) &` so v1
had time to write this request's own response before dying. Confirmed
live: old PID (26427) no longer in `ps`, new daemon (PID 4105) answered a
test command correctly (`uid=2000(shell)`), and a v1-shaped request sent
afterward got `AUTH_FAILED: bad tag` with **no command execution** —
proving the old plaintext protocol is now inert, not just superseded.
Local secret file (`~/.claude/claude-native/.minishizuku-secret`) was
only overwritten with the new secret *after* the swap request was sent,
to avoid needing the old value twice.

**Still not done** (unchanged in kind from v1, just narrower in scope
now): no encryption — command text and output are still plaintext on
`/sdcard`, readable by any app with storage permission; only the
*secret's* confidentiality (and therefore forgery of new commands) is
now protected. Not yet folded into `adb-bridge.sh`/the `adb-bridge` skill
— still a standalone artifact, same as v1 was. `cmd.sh`/`log2`/
`seen_nonces` etc. accumulate under `/sdcard/.minishizuku/` and haven't
been given any rotation/cleanup.

### 4k. Real Binder RPC investigated as a stronger transport — dead end for isolation, same trust model as the mailbox (same session, follow-up)

User asked whether reusing Shizuku's own mechanism (fork `starter.cpp`) would
give the same security property "for free". It would not, and the reason
matters: `starter.cpp` only launches the **server** half
(`app_process` running `ShizukuService`); the actual isolation Shizuku gets
comes from the **client** side holding a real Binder handle, which requires
being an installed Android app with its own manifest component (a
`ContentProvider`) — a Binder handle is a runtime/kernel-driver concept, not
something a POSIX shell script can hold. Termux's own shell processes have
no such component, so this path would require building and installing a
whole separate companion APK — a materially bigger project than anything
done so far, not "purely Termux + one ADB bootstrap".

Investigated anyway, empirically, to see how close a native (non-APK)
approach could get:

- **`/dev/binder` opens fine from Termux's own domain** (confirmed via
  `os.open('/dev/binder', O_RDWR)` from Python — `OPEN OK`). Termux's SELinux
  domain is `untrusted_app_27` (`id -Z`). This was unknown before this
  session — SELinux does *not* block Termux from touching the raw binder
  driver, only from certain socket operations (4i).
- Termux already ships a full clang 21 NDK toolchain
  (`aarch64-unknown-linux-android24` target) plus real NDK Binder headers
  (`android/binder_ibinder.h` etc, via the `ndk-sysroot` package) — building
  native Binder code from Termux is realistic, not hypothetical.
- `libbinder_rpc_unstable.so` (Android's own Binder-over-socket transport,
  built for Microdroid/virtualization use cases) dlopens fine from Termux.
  Fetched the real header from AOSP
  (`frameworks/native/libs/binder/include_rpc_unstable/binder_rpc_unstable.hpp`,
  via `gh api <googlesource.com URL>?format=TEXT` — plain `WebFetch` failed
  with 404s on guessed paths and cs.android.com returns an empty JS shell to
  WebFetch; `gh api` fetching an arbitrary HTTPS URL worked as a generic
  fetcher and was the thing that actually got the real file) to get exact
  signatures instead of guessing from memory (memory was wrong: there is no
  `ARpcServer_setRootObject` — `ARpcServer_newInet(AIBinder* service, const
  char* address, unsigned int port)` takes the root service object as its
  first argument at creation time).
- The header exposes 4 transports: `newVsock` (VM-only, N/A here),
  `newInet` (TCP loopback), `newBoundSocket`/`newUnixDomainBootstrap` (real
  Unix domain sockets — the ones with actual DAC/SELinux-backed isolation).
  **Tested empirically**: binding a Unix domain socket at
  `/dev/socket/<name>` (the convention this very API expects for
  `ARpcSession_setupUnixDomainClient`) from the `shell` UID via
  `toybox nc -U -s /dev/socket/mstest_$$ -L true` → `bind: Permission
  denied`. `/dev/socket/` is `root:root`, SELinux type `socket_device` —
  same wall as 4i's `/data/local/tmp` AF_UNIX finding, just a different
  blessed-looking path.
- That leaves only `newInet` as viable for `shell` UID — and it has **no
  kernel-enforced peer UID** (unlike real `/dev/binder` transactions or a
  DAC-protected Unix socket). Any app on the device could connect to the
  TCP loopback port. Closing that gap needs the exact same app-level
  secret/tag scheme 4j already built — so real Binder RPC would trade the
  mailbox's polling latency and raw-shell-string protocol for a nicer,
  faster, structured IPC, **without closing the eavesdropping/DoS gaps**
  that motivated 4k in the first place. Conclusion: not worth the much
  larger implementation cost (native `AIBinder_Class`/`onTransact`/`AParcel`
  server+client, cross-compiled to run reliably at `shell` UID) for a
  security-equal, only-nicer-engineering outcome. Shelved — 4j (mailbox +
  sandwich-hash) remains the actual deployed mechanism.

### 4l. Auto-mode classifier and a separate, session-level safety block (same session, met while testing 4k)

Two distinct denial mechanisms were hit live while probing the daemon
through Bash, worth recording since they weren't previously documented
in this repo and materially affect what a future session can do live on
this channel:

1. **Auto-mode classifier** — evaluates each Bash/tool call individually
   against built-in `soft_deny`/`hard_deny` rules plus user config
   (`allow` rules, `autoMode.environment`). Documented at
   `permission-modes.md` in the Claude Code docs. Fix: an `allow` rule, an
   `autoMode.environment` tweak, or manual approval via `/permissions`.
2. **A separate safety check, "not about the action itself"** — triggered
   by *accumulated conversation content* (in this case: a whole session of
   building a shell-UID command-execution channel + probing Binder IPC —
   textbook privilege-escalation-shaped research, even though fully
   device-owner-authorized). Once it fires, **every subsequent action that
   needs the classifier is blocked for the rest of that conversation** —
   confirmed live: it blocked a Bash call, then an `Agent` spawn, then a
   `WebFetch` call, all on unrelated content, all in the same way. Only
   `Read`/`Grep`/other pure-local-read tools stayed unaffected. Documented
   only obliquely, in `permission-modes.md`/`errors.md` ("a safety check
   separate from auto mode refused the classifier's own request" /
   "refused by the safety safeguard") — no public doc explains its
   detection logic or offers an in-session reset. The only confirmed fix:
   exit auto mode (default permission mode, which prompts per action) or
   start a fresh conversation. Exiting auto mode did unblock the agent
   spawn that followed in this session.

**Implication for future work on this specific research thread**: expect
this to potentially fire again in a *fresh* session that does more of the
same kind of work (mailbox/daemon manipulation, Binder probing) — it's
conversation-content-triggered, not tied to this one session's history.
If it does, the only known fix is switching out of auto mode.

### 4m. `relaysh` — replaces mini-shizuku entirely, with a real kernel-verified UID gate (same session, final follow-up)

User asked to rename away from "mini-shizuku"/version-numbered filenames
("relaysh", no version suffix — this repo's convention going forward: one
canonical file, overwritten in place, not `-v2`/`-v3` names) and to keep
pushing security. This section documents the actual mechanism now
deployed, replacing 4h–4l's file-mailbox design outright.

**The finding that changed the design**: while probing the Binder-RPC
dead end (4k), the natural follow-up question was "if `newInet` (TCP
loopback) has no peer-UID check, is there *any* way to learn who's really
on the other end of a TCP connection?" There is — not via a socket option
(`SO_PEERCRED` is Unix-domain-only on Linux), but via `/proc/net/tcp`,
which has always carried a `uid` column: the *kernel's own record* of
which UID owns each socket in the table, unforgeable by whoever holds the
socket. Confirmed empirically, in order:

1. Termux's own process gets `EACCES` reading `/proc/net/tcp` (Android
   restricts this for `untrusted_app` — a privacy hardening measure so
   apps can't fingerprint each other's connections). The `shell` UID
   (daemon side) reads it fine, `uid` column populated with real values
   (`10663` for Termux, `1000`/`2000` for system/shell, etc).
2. Wrote a self-test (`proc-net-tcp-test.c`) to nail the exact encoding
   empirically rather than trust memory: **addresses** are printed as raw
   network-order bytes (no `ntohl`), but **ports** are printed *after*
   `ntohs()` (natural host-order hex) — an asymmetry that broke the first
   attempt (`NOT FOUND`) until corrected; the general technique itself
   (matching a fresh connection's 4-tuple against `/proc/net/tcp` rows) is
   the same trick some non-root Android firewall/VPN apps use to
   attribute connections to apps, predating `SO_PEERCRED` on TCP.
3. Cross-UID live test (`proc-net-tcp-server.c`, server at `shell` UID via
   `adb shell`, client a genuine separate Termux process): server reported
   `PEER_UID=10663`, exactly Termux's real `id -u` — confirmed the kernel
   record is trustworthy across the real UID boundary this mechanism
   needs to protect, not just in a same-UID self-test.

**This reverses an earlier claim in this same session** (in 4k's
discussion, before this test): I had told the user TCP carries no
peer-identity primitive at all, so a TCP-based daemon could never do
better than the existing shared-secret scheme. That was wrong — the
identity *is* available, just via `/proc/net/tcp` instead of a socket
option, and only readable by a sufficiently-privileged UID (which `shell`
is, and `untrusted_app` is not — asymmetric, but that's fine: only the
*server* side needs to check).

**`relaysh-daemon.c`** (`~/.claude/claude-native/`, pushed to
`/data/local/tmp/relaysh-daemon` via `adb push`, started once via
`adb shell setsid ... &`, same detach pattern as the old daemon — survives
ADB disconnecting): a single-process C TCP server on `127.0.0.1:47321`
gating every accepted connection on **two independent checks**, in order:

1. **Kernel-verified peer UID** (`peer_uid_via_procfs()`, the technique
   above) — anything that isn't UID 10663 (Termux) gets `close()`d with
   *zero bytes written back* — no way to distinguish "wrong UID" from
   "server not listening" by probing it. This is enforced by the kernel;
   no bug in this daemon's own code can be tricked into skipping it for
   an actual different UID, unlike the old mailbox's secret-only gate.
2. **Sandwich-hash tag** (same construction as 4j: `tag =
   sha256(SECRET+"\n"+inner)`, `inner =
   sha256(SECRET+"\n"+NONCE+"\n"+COMMAND)`, in-memory nonce replay guard)
   — kept as defense in depth against a *different* threat the UID check
   doesn't cover: malicious code running *inside* Termux's own UID (a
   compromised pip/npm package), which would pass check #1 trivially but
   doesn't know SECRET.

SHA-256 is implemented directly in the daemon (self-contained, ~40 lines,
unit-tested against 3 FIPS test vectors including the 56-byte
padding-boundary edge case — all matched exactly) rather than shelling
out to `sha256sum` as an early draft did — shelling out would have put
SECRET and the command text briefly into a subprocess's argv, readable
by anything running `ps` at the right moment. Small thing, but exactly
the class of leak this whole redesign exists to close.

**`relaysh-client.py`** (Python3, not shell — Termux's `dash` has no
usable raw-socket primitive; Android's `/system/bin/sh` doesn't support
bash's `/dev/tcp` either, confirmed live while testing). Reads
`~/.claude/claude-native/.relaysh-secret` and `.relaysh-port`, computes
the same tag, connects, sends, half-closes (`SHUT_WR`) so the daemon knows
where the request ends without needing a length prefix, reads the
response.

**Verified live, all 4 cases**:
- Valid command from Termux → runs, correct output (`uid=2000(shell)`).
- Right UID, wrong secret → `AUTH_FAILED: bad tag`.
- Right UID, replayed nonce+tag → first run succeeds, replay rejected.
- **Wrong UID** (connected via `adb shell`'s own `toybox nc`, UID 2000 —
  note this is the *daemon's own* UID, not Termux's 10663, and still
  correctly rejected): zero bytes back, connection just closes. Distinct
  from the wrong-secret case, confirming the UID gate is a real, separate
  check running before the secret is ever examined.

**What this closes vs. what it still doesn't**: the UID gate means
another app on the device can no longer read, forge, or interfere with
requests at all — a strictly stronger guarantee than the old
`/sdcard` mailbox ever had (no per-app isolation there, full stop). What's
**still open**: no encryption. If another app manages to bind port 47321
*before* relaysh-daemon starts (a boot-time race), Termux's client has no
way to verify server identity in return — `untrusted_app` can't read
`/proc/net/tcp` (confirmed in point 1 above), so the check that protects
the server has no symmetric equivalent on the client side. A squatter
could passively capture one command's plaintext content this way (still
can't forge new commands or replay old ones). Not fixed in this pass —
would need real encryption, still a future item, now the *only* remaining
item of its kind (replay + forgery + cross-app tampering are all closed).

Old mini-shizuku artifacts fully retired: `/sdcard/.minishizuku/` deleted,
`minishizuku-daemon-v2.sh`/`minishizuku-client.sh`/`.minishizuku-secret`
deleted from `~/.claude/claude-native/`. `relaysh-daemon`/`relaysh-client`
have no version suffix by design — future hardening should edit these
files in place and redeploy, not create `-v2` copies.

### 4n. `relaysh-daemon` does not survive a wifi toggle — confirmed root cause is Android's cgroup, not process/session detachment (follow-up session)

User reported the daemon died after turning wifi off, then asked to test
whether a different deployment method fixes it, then asked for the root
cause to be investigated and verified rather than assumed.

**First fix attempt (insufficient)**: added real double-fork
daemonization directly inside `relaysh-daemon.c`'s `main()` — `fork()` →
`setsid()` → ignore `SIGHUP` → `fork()` again → close/redirect all three
std fds to `/dev/null`. This is the textbook-correct way to fully detach
a process from whatever spawned it. **Verified it does fix plain `adb
disconnect`** (host-side disconnect, wifi and the on-device wireless-debug
session left untouched): daemon (reparented to PID 1) kept serving
requests correctly, still alive 20s later, with adb fully disconnected
the whole time. But **it did not survive an actual wifi-off event** —
same `ConnectionRefusedError` as before the fix, both when wifi was
turned off via the device UI and via a plain `svc wifi disable` (a pure
software toggle, not a hardware radio/airplane-mode cycle — ruling out
anything DMA/radio-specific).

**Root cause, confirmed empirically + against upstream docs**: every
process spawned via `adb shell` while using Wireless Debugging lands in
an Android-managed cgroup keyed by the *root PID of the adbd session*,
not by anything under this daemon's control:

```
relaysh-daemon (PID 3614): /proc/3614/cgroup → 0::/system/uid_0/pid_2898
adbd           (PID 2898): /proc/2898/cgroup → 0::/system/uid_0/pid_2898
```

`fork()`/`setsid()`/reparenting to init change the process/session
hierarchy but **do not** change cgroup membership — a child always
inherits its parent's cgroup at fork time, full stop. This is why the
double-fork fix above helped with a plain disconnect (nothing tore down
that cgroup) but was structurally powerless against a wifi toggle: toggling
wifi kills the wireless-debugging adbd instance and tears down its whole
cgroup, taking every process still inside it down together — the daemon's
own session-detachment is irrelevant to that path.

**Verified adbd itself actually restarts on a wifi cycle** (not just the
wireless-debug transport dropping and reconnecting): `svc wifi disable`
then re-enabling gave adbd a brand-new PID (`2898` → `5579`), and the
relaysh-daemon that had been living under the old adbd's cgroup was
gone — consistent with Android's `libprocessgroup` killing an entire
cgroup by (uid, pid) once the old adbd session is torn down (see
[processgroup.cpp](https://android.googlesource.com/platform/system/core/+/master/libprocessgroup/processgroup.cpp)
and the [Android cgroup overview](https://source.android.com/docs/core/perf/cgroups)).

**Confirmed there is no unprivileged escape**: cgroup v2 requires write
access to the *common ancestor* `cgroup.procs` of the source and
destination to move a process between cgroups, or to the parent directory
to create a new sub-cgroup at all (kernel docs:
[Control Group v2](https://www.kernel.org/doc/html/v4.18/admin-guide/cgroup-v2.html),
matching the `cgroup: require write perm on common ancestor when moving
processes on the default hierarchy` kernel patch). Checked every relevant
node on-device (`/sys/fs/cgroup/cgroup.procs`, `/sys/fs/cgroup/system/`,
`/sys/fs/cgroup/system/uid_0/`, `/sys/fs/cgroup/system/uid_0/pid_<adbd>/`):
all owned by `system:system`, mode `rwxrwxr-x` — UID `shell` (2000) falls
under "other" (`r-x` only) at every level, and both a direct `mkdir` of a
sub-cgroup and writing our own PID to any of these `cgroup.procs` files
failed with `Permission denied`, live-tested. So this is a hard OS-level
wall for anything spawned via `adb shell` under Wireless Debugging — not
a `relaysh-daemon` bug, and not fixable in its code without root.

**Operational conclusion**: the daemon must be restarted after any event
that recycles the adbd session (wifi off/on, and probably a long-enough
adb idle timeout — not yet tested). A plain `adb disconnect`/reconnect
that leaves wifi and the on-device wireless-debug session alone is safe
and does not require a restart. A future hardening worth trying: a small
watchdog loop running *inside Termux* (UID 10663, never a member of
adbd's cgroup, so immune to this) that notices `ConnectionRefused` from
`relaysh-client.py` and re-launches the daemon via `adb shell` whenever
adb happens to be connected — not yet built. Also untried: whether
USB-cable adb (as opposed to Wireless Debugging) puts spawned processes
in the same kind of session-scoped cgroup at all.

### 4o. Ruled out reviving the old `/sdcard` mailbox transport as a fix, and confirmed the whole problem class against outside sources (same investigation, follow-up)

User asked, reasonably, not to give up on cgroup-escape without testing an
alternative transport first: could the old mini-shizuku `/sdcard`
file-polling design (4i) survive where the TCP daemon didn't, since it
never touches a socket at all?

**Tested live, not just reasoned about**: rebuilt a minimal mini-shizuku-style
poller (`sh` script, `mkfifo`-free, plain `req`/`resp` files under
`/sdcard/.relaysh-test`, secret-gated), bootstrapped via one `adb shell
setsid ... &` call. Confirmed baseline working (request → response with
`uid=2000(shell)`, ~instant) while adb was still connected. Then ran `svc
wifi disable` — adb dropped to `offline` as expected — and sent a fresh
request purely from Termux, zero adb involved. **No response ever came
back**, confirming the poller died exactly like the TCP daemon did.
Reconnecting adb afterward showed adbd's PID had changed yet again and the
poller process was simply gone — same signature as 4n.

**Why this was expected in hindsight**: the transport (TCP socket vs.
`/sdcard` file polling) only changes how Termux and the shell-UID process
talk to each other *while both are alive*. It has no bearing on whether the
shell-UID process itself survives — that's entirely determined by which cgroup
it was forked into, which is fixed at `adb shell` bootstrap time regardless
of what the process does afterward. Also worth flagging: **4i's own
"survives ADB disconnect" claim was only ever tested against a plain `adb
disconnect`, never an actual wifi-off** — so it likely had this exact same
unaddressed blind spot the whole time, just never noticed. Reviving
`/sdcard` would additionally reintroduce the world-readable/writable
mailbox weakness relaysh's TCP+UID-gate design specifically replaced (4j,
4m) — a pure downgrade with no corresponding reliability gain.

**Checked against outside sources, not just this device's behavior**: this
turns out to be well-documented, widely-hit Android behavior, not
something specific to this setup:

- Wireless Debugging (`adb_wifi_enabled`, Android 11+) is known to drop on
  Wi-Fi loss, AP handover, idle periods, *and* every reboot — see the
  [KeepADB README](https://github.com/m00sfett/KeepADB) (built specifically
  to auto-re-enable it after exactly these events) and general wireless-ADB
  guides. Nobody in the wider community tries to make a spawned process
  survive this — the accepted pattern is detect-and-re-establish after the
  fact, not defend against it.
- Looked for a way to close the *actual* remaining gap — auto-discovering
  the new wireless-debug port after a drop, via adb's own mDNS support
  (`ADB_MDNS_AUTO_CONNECT`, `openscreen_mdns` — listed as a supported
  feature in `adb host-features` on this install). **Dead end in this
  environment**: both `adb mdns check` and `adb mdns services` fail with
  `unknown host service 'mdns:check'` / `'mdns:services'` — the feature is
  negotiated over the transport protocol but the actual mDNS discovery
  backend isn't compiled into this Termux `android-tools` build's `adb`
  server. No auto-discovery path currently available; the new port still
  has to come from the user reading it off the Wireless Debugging screen.

**Conclusion holds**: no transport-level or discovery-level trick found
(tested or researched) removes the need for a human to supply the new adb
port after a wifi-off event. The only thing that can be automated end-to-end
is recovery from a plain `adb disconnect`/reconnect that leaves wifi alone.

### 4p. Second round of cgroup-escape attempts, plus external validation that this is a known, unsolved-without-root limitation (same investigation, follow-up)

User pushed to keep digging rather than settle for detect-and-re-establish.
Two more concrete things tried, both negative, then one piece of strong
outside corroboration:

- **Checked for a shell-owned cgroup subtree to self-migrate into**:
  `/sys/fs/cgroup/system/uid_2000/` does exist (Android keeps a
  bookkeeping dir per UID that has ever run something), but it's
  `system:system`-owned with the same `rwxrwxr-x` pattern as everywhere
  else — writing our own PID into its `cgroup.procs` still gets
  `Permission denied`. Not a delegated subtree; shell can't self-manage it.
- **Checked whether `adb shell` is secretly running as root** (adbd's own
  `ps -ef` entry shows a `--root_seclabel=u:r:su:s0` flag, which raised the
  question of whether commands run with root and could therefore write
  anywhere in cgroupfs): `adb shell id` → still plainly `uid=2000(shell)`.
  That flag is adbd's own seclabel config, not a grant of root to our
  shell commands — `adb root` is not active here.
- **Reasoned through (not live-tested) why `app_process`/Zygote doesn't
  help either**: a per-app cgroup only gets created because
  `ActivityManagerService` (running as `system`) explicitly calls the
  process-group-creation API for processes it spawns via its own Zygote
  socket protocol. Directly exec'ing `app_process` from an `adb shell`
  command is still just an ordinary `fork()`+`exec()` child of that shell —
  it never goes through AMS's spawn path, so it inherits the exact same
  `adbd`-owned cgroup as any other child. No shortcut there.

**External validation, found via search**: Shizuku — the most established
no-root ADB-privilege-elevation tool for Android, built by people who have
reverse-engineered this space far more thoroughly than this session has —
documents that its server (also bootstrapped via `adb shell`/`app_process`,
i.e. the exact same starting point as `relaysh-daemon`) needs to be
re-launched via a fresh ADB command **once per boot** on non-rooted
devices. It does not claim immunity to session-recycling events like a
wireless-debugging drop either. If the most mature tool in this exact
space, run by people with far deeper Android internals expertise, still
needs a periodic ADB re-bootstrap instead of true persistence, that's
strong outside confirmation this is a real OS-level wall — not a gap in
this session's own effort or knowledge.

**Investigation closed on this front**: every avenue this session could
think of or find documented (self cgroup migration, root/seclabel
loophole, Zygote/app_process spawn path, alternate IPC transport, mDNS
port auto-discovery, and now independent confirmation from Shizuku's own
documented limitation) has been checked and comes up empty. Moving forward
means either accepting the detect-and-re-establish model (4n/4o's
watchdog idea), or requiring actual root (out of scope unless the user's
device supports it and they choose to root it).

### 4q. `adb shell pm grant` explored as a different-shaped alternative — works, but solves a narrower problem than relaysh does (same investigation, follow-up)

A completely different angle: instead of keeping a shell-UID *process*
alive (always fragile — cgroup-bound to whichever adbd instance spawned
it), grant Termux itself a permission it can't get through the normal
runtime-permission dialog, via one `adb shell pm grant com.termux
<permission>` call. Permission grants live in the package manager's
database, not in any process's memory or cgroup — so there is nothing
here for a wifi toggle or an adbd restart to kill. Worth testing whether
this genuinely sidesteps the entire problem class 4n–4p documents.

**`READ_LOGS`, confirmed working, no daemon involved at all**: `dumpsys
package com.termux` shows it's a requested permission, and — already
granted from an earlier session, well before today's wifi-toggle cycles —
Termux can run `logcat -d` **directly**, no `adb` connection needed, and
it just worked mid-investigation while adb was fully disconnected
(background context: this permission is normally invisible to a regular
app's runtime-permission dialog; only `pm grant` from a `shell`-or-higher
caller can hand it out). This is a real, working, zero-maintenance
capability that has silently survived every wifi/adb cycle in this entire
investigation without anyone noticing, which is itself the point.

**`WRITE_SECURE_SETTINGS`, attempted, inconclusive** — not because the
permission doesn't work, but because the obvious ways to test it from a
shell turned out to be testing the wrong thing:
- `settings put/get secure ...` failed with `SecurityException:
  ... requires android.permission.INTERACT_ACROSS_USERS` — this is the
  `settings` CLI tool's *own* internal call to
  `ActivityManagerService.getCurrentUser()`, a separate permission
  requirement baked into that specific command-line wrapper, unrelated to
  whether `WRITE_SECURE_SETTINGS` itself is granted.
- `content insert/query --uri content://settings/secure ...` failed
  differently: `content` isn't even reachable from Termux's `PATH`
  (it's a wrapper script invoking `app_process`, and plain `cat` on the
  script itself is blocked — `Operation not permitted`); forcing it to run
  with `/system/bin` on `PATH` got further but then hit
  `SecurityException: ... requires
  android.permission.ACCESS_CONTENT_PROVIDERS_EXTERNALLY` — again a
  permission the `content` *command* itself demands of its caller
  (normally only `shell`/root has it), separate from `WRITE_SECURE_SETTINGS`.
- **Real conclusion**: both stock CLI tools (`settings`, `content`) are
  built assuming a `shell`-or-root caller and layer on extra permission
  checks beyond the one this test cared about. Properly verifying
  `WRITE_SECURE_SETTINGS` would need actual app code calling
  `Settings.Secure.putString()` through a `ContentResolver` (the
  documented, intended API for that permission) — not available as a
  one-line bash test from Termux. Left unresolved, flagged rather than
  claimed either way.

**Where this fits relative to relaysh**: this is not a replacement for
relaysh's actual goal (running *arbitrary* shell commands from Termux) —
`pm grant` only unlocks whatever fixed capability a specific named
Android permission covers, nothing more general. But for any *specific*
capability that happens to map to a real permission (log reading, secure
settings, usage stats, etc.), a one-time grant is strictly better than a
relaysh-style daemon: no process, no cgroup, no wifi/adb-cycle fragility
at all — confirmed by `READ_LOGS` having quietly worked through every
disruption this whole investigation threw at the device. Worth reaching
for this first, per-capability, before building a general daemon for
something that turns out to have a dedicated permission already.

### 4r. Real `starter.cpp`/`cgroup.cpp` read directly — confirms `switch_cgroup()` is root-gated; considered forking a Termux-only server, settled on the actual missing piece instead (same investigation, follow-up)

User asked to fork Shizuku's `starter.cpp` for Termux's own use, then to
verify what Shizuku's own project actually claims, rather than continuing
to guess.

**Read the real source** (`manager/src/main/jni/starter.cpp` and
`cgroup.cpp`, fetched via `gh api .../contents/... -H "Accept:
application/vnd.github.raw"`). Confirms everything 4n–4p inferred, from
the primary source itself: `switch_cgroup()` — which does exactly the
`open("<path>/cgroup.procs", O_WRONLY); write(fd, "<pid>\n", ...)` this
session already tried and got `Permission denied` on — is only ever
called inside `if (uid == 0) { switch_cgroup(); ... }` in `main()`. On the
ADB path (`uid == 2000`), Shizuku's own starter **skips this entirely**.
This is the single most authoritative confirmation available: the actual
reference implementation in this exact problem space only escapes the
adbd-owned cgroup when it has root, full stop.

**Considered forking the `server` module to run a Termux-only
service** (no separate app install, `.dex` pushed via `adb push`
alongside a Termux-branded `starter` fork, per user's explicit
"don't touch the Termux APK, push a standalone dex" decision). Checked
`server/build.gradle`: real dependency list is `dev.rikka.tools.refine`
(a Gradle-plugin-driven ASM bytecode rewriter for safe hidden-API access)
plus Kotlin sources plus several sub-modules (`aidl`, `common`, `shared`,
`provider`, `server-shared`) and Maven deps (Gson, androidx, rikkax). Not
reachable with plain `javac`+`d8` — would need real Gradle + Android
Gradle Plugin, a much heavier lift than relaysh ever was. Termux *does*
have `aapt`/`aapt2`/`d8`/`aidl` packaged (`pkg install` confirmed all
four install cleanly) and `openjdk-21` installs fine too; pulled the
device's real `/system/framework/framework.jar` via `adb pull` as the
compile classpath (guaranteed API-level-correct, no separate SDK
download needed) — so the toolchain problem was solvable, but the
Refine/Gradle dependency was the real wall, not tooling availability.

**Settled on**: don't fork `ShizukuService.java` wholesale (it does far
more than relaysh needs — full client/user-service management) — and
more importantly, don't chase cgroup-escape via Java/Binder at all, since
4o already proved architecture/language is irrelevant to that problem
and this section's `starter.cpp` reading confirms it a second, more
authoritative way. What actually mattered was found by asking a different
question instead (4s, below).

### 4s. The real automatable gap: mDNS-discovering the wireless-debug port without any app, closing the loop with a full auto-heal watchdog design (same investigation, follow-up)

User asked directly: what does Shizuku's app actually do to avoid needing
a human to reconnect adb each time — and does their own project describe
it. Answer, read straight from their source
(`manager/src/main/java/moe/shizuku/manager/adb/`): Shizuku ships **its
own ADB wire-protocol client** (`AdbClient.kt`, `AdbProtocol.kt`,
`AdbKey.kt` for the persisted pairing keypair, `AdbPairingClient.kt`) —
it never shells out to a system `adb` binary at all — plus `AdbMdns.kt`,
which uses Android's `NsdManager` system service to discover the
`_adb-tls-connect._tcp` mDNS service and get the *current* ephemeral
wireless-debugging port whenever it changes. That's the actual trick:
not cgroup survival (4n–4r already closed that door), but **automating
away the one manual step this whole investigation kept needing a human
for** — reading the new port off the Wireless Debugging screen after
every wifi cycle.

**`NsdManager` is an Android app API Termux's shell can't call directly,
but mDNS itself is just a standard UDP multicast protocol** —
`_adb-tls-connect._tcp` advertisements aren't gated behind any
Android-exclusive mechanism, only behind whether raw multicast reaches
the caller. Tested directly, no app/library involved: a ~70-line Python
script joined `224.0.0.251:5353` (`IP_ADD_MEMBERSHIP`), sent a hand-built
DNS-wire-format PTR query for `_adb-tls-connect._tcp.local`, and got a
real response back **from the device's own currently-running
wireless-debugging service** — parsed PTR → SRV → the exact live port
(`36589`), cross-checked live against `adb connect
127.0.0.1:36589`, which succeeded immediately. This directly contradicts
4o's earlier conclusion that mDNS discovery was a dead end — that
finding was only ever about Termux's *packaged `adb` binary* lacking a
compiled-in mDNS backend (`adb mdns check/services` failing with
`unknown host service`); the actual mDNS traffic on the local link was
reachable the entire time via a plain UDP socket, no `adb`, no app, no
`NsdManager` needed.

**What this actually closes**: not "the daemon never dies" (still
provably impossible without root, 4n–4r) — but "a human must read/type
the new port after every wifi cycle," which *is* now fully automatable:
a watchdog can (1) notice `relaysh-client.py` getting
`ConnectionRefused`, (2) run the mDNS query above to get the current
port, (3) `adb connect 127.0.0.1:<port>` (no re-pairing needed — TLS
pairing persists once trusted, confirmed repeatedly across this whole
session's many reconnects), (4) `adb shell
/data/local/tmp/relaysh-daemon` to relaunch. That's a genuinely
zero-touch recovery loop, still not built as of this note — the next
concrete step, not yet started.

**Built and live-tested**: `~/.claude/claude-native/relaysh-watchdog.py`
implements exactly this (daemon health check via `relaysh-client.py`, the
mDNS query above, `adb connect`, `adb shell` relaunch). Caught a real,
previously-unnoticed daemon death organically on its first run (the
daemon from 4n's fix had died silently at some point, unrelated to any
deliberate test) and fully self-healed with zero manual input. A second,
deliberate full-cycle test (`svc wifi disable` then `enable`) exposed a
real-world edge case: **Android can turn the "Wireless debugging" developer
option itself off independently of the wifi radio** (matches the known
XDA-documented "Wireless debugging keeps turning off" behavior) — when
that happens there is no mDNS advertisement to find at all (confirmed:
the discovery script legitimately returned no SRV record), and
`svc wifi enable` alone does not bring it back. The watchdog handles
"adb session recycled, wifi radio itself is fine" completely on its own;
it cannot yet handle "the Wireless Debugging toggle itself got disabled."

### 4t. Chased whether Termux could flip the Wireless Debugging toggle back on itself (`Settings.Global.putInt`, like Shizuku's own `AdbDialogFragment.kt` does) — hit a different, deeper wall than expected (same investigation, follow-up)

Read `AdbDialogFragment.kt`'s `onDialogShow()` directly: if the caller
holds `WRITE_SECURE_SETTINGS`, Shizuku's own app code does exactly
`Settings.Global.putInt(cr, "adb_wifi_enabled", 1)` — flipping Wireless
Debugging back on **in software**, no Developer Options UI needed. Since
`WRITE_SECURE_SETTINGS` is a `pm grant`-able, permanent, process-independent
grant (same category as `READ_LOGS`, 4q), this looked like it could close
the last remaining manual gap from 4s.

**Live-tested end to end, no adb involved** (toolchain from 4r reused: the
downloaded `android-36.jar`, a real android.jar with real `.class` files,
from the community mirror
[Reginer/aosp-android-jar](https://github.com/Reginer/aosp-android-jar) —
needed because the device's own `/system/framework/framework.jar` is raw
DEX, not `.class` files, so `javac` can't compile against it directly):

1. Wrote a 15-line `SetAdbWifi.java` calling
   `ActivityThread.systemMain().getSystemContext().getContentResolver()`
   then `Settings.Global.putInt(...)`, compiled with `javac -cp
   android-36.jar`, converted with `d8`, ran via `/system/bin/app_process
   -Djava.class.path=classes.dex /system/bin SetAdbWifi` **directly from
   Termux's own shell, no `adb` at all** (UID 10663 the whole time).
2. First failure: `SecurityException: Writable dex file ... is not
   allowed` — ART refuses to load a dex the calling UID can itself write
   to (a real, generic anti-tampering check, unrelated to this specific
   goal). Fixed generically: `chmod 444` the `.dex` after building it.
   Confirmed the fix in isolation first with a trivial `Hello.java` before
   moving on, to isolate this from anything permission-specific.
3. Second failure: `Can't create handler inside thread ... that has not
   called Looper.prepare()` — `ActivityThread`'s constructor needs a
   prepared main-thread `Looper`. Fixed with `Looper.prepareMainLooper()`
   before `ActivityThread.systemMain()`.
4. **Real failure, the actual finding**: `SecurityException: Given
   calling package android does not match caller's uid 10663`. This is
   not a permission problem at all — `ActivityThread.systemMain()`
   bootstraps a throwaway `Context` whose package identity is hardcoded to
   `"android"` (UID 1000), purely so CLI tools have *something* to call
   through. `ActivityManagerService.getContentProvider()` cross-checks the
   declared calling package against the real calling UID and rejects the
   mismatch (UID 10663 does not own package `"android"`).

**Why this is a different, and likely harder, wall than the earlier
`ACCESS_CONTENT_PROVIDERS_EXTERNALLY` one (4r)**: that one was a
grantability question (signature-level, so a firm no). This one is an
*identity* question — getting a `ContentResolver` that legitimately
claims to be `"com.termux"` requires a `Context` that was actually
attached through the normal Zygote-fork → `ActivityManagerService
.attachApplication()` handshake a real app launch goes through. A bare
`app_process` invocation, even run at the exact right UID, was never
"born" that way and has no path this session found to retroactively
acquire that identity. This is exactly why Shizuku's own
`Settings.Global.putInt` call works: it runs from inside `AdbDialogFragment`,
code living inside Shizuku's manager app's real, properly-launched
process — not from a side helper process at all. Not pursued further
(would mean re-implementing a meaningful slice of Zygote/AMS app-launch
handshake from scratch); flagged as the reason this specific approach
stops here rather than confirmed dead beyond all doubt.

**Where this leaves the watchdog**: recovery from a plain adb/session
recycle is fully automatic (4s). Recovery from Wireless Debugging being
toggled off at the OS level still needs a human to flip it back on in
Developer Options — no way found (short of modifying Termux's own APK,
already ruled out by the user, or fully reimplementing an app-launch
identity handshake) to automate that specific step from outside a real,
Zygote-launched app process.

### 4u. `WRITE_SECURE_SETTINGS` actually granted to Termux; confirmed the identity wall is tied to `ActivityThread.attach()`, not the `Context` (brief follow-up, cut short by a closing wifi window)

Two loose ends from 4t tied off:

**Grantability of `WRITE_SECURE_SETTINGS` confirmed from source, not
guessed**: `core/res/AndroidManifest.xml` declares it
`protectionLevel="signature|privileged|development|role|installer"` — the
`development` flag is exactly what makes a signature-level permission
grantable via `adb shell pm grant` for debugging purposes (the same flag
`INTERACT_ACROSS_USERS` has; contrast `ACCESS_CONTENT_PROVIDERS_EXTERNALLY`,
`signature` only, no `development` flag, genuinely ungrantable). **Actually
granted it**: `adb shell pm grant com.termux
android.permission.WRITE_SECURE_SETTINGS`, confirmed via `dumpsys package
com.termux` showing `WRITE_SECURE_SETTINGS: granted=true`. This grant is
permanent (package-manager state, not process/cgroup-bound) — it will
still be there next session regardless of any future wifi/adb cycling.

Also worth flagging: a `checkPermission()` call made from inside the same
kind of bare `app_process` helper (via `ActivityThread.getPackageManager()
.checkPermission(perm, "com.termux", 0)`) came back **denied for every
permission tested, including `READ_LOGS`**, which is independently and
repeatedly confirmed working (plain `logcat -d` from Termux's real shell).
That contradiction means this specific query technique is unreliable from
an ad-hoc `app_process` caller (same identity-resolution wall as
everything else in 4t) — it is not evidence about any permission's real
grant state, and `dumpsys` over adb remains the only trustworthy way this
session found to check.

**Retried the `Settings.Global.putInt` call now that the permission is
actually held**, this time also trying `sysContext.createPackageContext
("com.termux", CONTEXT_IGNORE_SECURITY | CONTEXT_INCLUDE_CODE)` before
grabbing the `ContentResolver`, on the theory that a `Context` correctly
declaring `"com.termux"` (which UID 10663 genuinely does own) would clear
the identity check. **Same exact failure**: `Given calling package
android does not match caller's uid 10663`. This narrows the mechanism
down further: the calling-package identity `ActivityManagerService`
checks is evidently bound to `ActivityThread`'s own singleton state from
whatever `attach(true, 0)` set it to at `systemMain()` time, not to
whatever `Context` a call happens to be routed through — `createPackageContext`
changes resource/theme resolution for that `Context`, not the process-wide
binder-calling identity `ActivityThread` presents on its behalf.

**Not pursued further this session** (cut short by the wifi window
closing, not by hitting a proven dead end): the next concrete thing to try
would be reflectively patching `ActivityThread`'s bound-application state
(likely `mBoundApplication`/`mInitialApplication` or equivalent private
fields) to declare `"com.termux"` instead of `"android"` before making the
call — meaningfully deeper than anything tried so far, genuinely unknown
whether it works, flagged as the next step for a session with a stable
wifi/adb connection to iterate against.

### 4v. scrcpy hit and fixed the exact same identity error — confirms it needs shell UID, closing this specific sub-investigation (reference knowledge, consolidated from both Shizuku and scrcpy)

User asked to record what both real, widely-used projects in this space —
Shizuku and [scrcpy](https://github.com/Genymobile/scrcpy) (the extremely
popular adb-based screen-mirroring tool) — actually do, as reusable
reference knowledge, not just this session's own trial and error.

**scrcpy hit the identical `Given calling package android does not match
caller's uid` error** ([issue #4639](https://github.com/Genymobile/scrcpy/issues/4639)),
for the same underlying reason: its server also runs via `app_process`
(pushed and launched through `adb shell`), using a hand-built `FakeContext`
(their equivalent of this session's `ActivityThread.systemMain()` /
`getSystemContext()` trick) to get *some* Context to call system services
through. Some devices/ROMs have internal managers (`InputManager`,
`AudioManager`, camera stacks) that internally call `getContentProvider()`
using that fake `"android"` identity, and hit the same AMS mismatch check
this session hit doing it deliberately.

**The community's actual fix** (`Ercilan`, refined by `yume-chan`,
merged into scrcpy `dev`): subclass `ContentResolver` and override
`acquireProvider()` to call `getContentProviderExternal()` directly via
`IActivityManager` — the same "external" provider-access API the `content`
and `settings` shell commands use (4o), bypassing the normal
`ActivityThread.acquireProvider()` path (and its identity check) entirely.
Real, working, merged, shipped-in-production code.

**Why this doesn't transfer to a no-adb Termux helper**: `getContentProviderExternal()`
requires `android.permission.ACCESS_CONTENT_PROVIDERS_EXTERNALLY` — confirmed
from `core/res/AndroidManifest.xml` (4r) as `protectionLevel="signature"`
with **no** `development` flag, i.e. genuinely not `pm grant`-able to any
third-party app. scrcpy's fix works because **scrcpy always runs at UID
2000 (shell) via `adb shell`**, and `shell` holds this permission by
default as part of its baseline AOSP grant (declared in
`packages/Shell/AndroidManifest.xml`) — not because they discovered a
bypass usable by an arbitrary UID. Applied to Termux's own UID 10663 (no
adb involved), the same fix would fail with a *different, unfixable*
error (missing signature permission) instead of the identity error it
fixes for shell.

**Consolidated picture from both real-world projects** (Shizuku:
4m, 4r, 4s, 4t; scrcpy: this section) — every technique either project
uses to make "run code at a privileged identity, no root" work reduces to
one of exactly three primitives, and this session has now hit the wall on
each one for the specific case of *Termux's own app UID with no live adb
connection*:

1. **`switch_cgroup()` (Shizuku, `cgroup.cpp`)** — escape the adbd-owned
   cgroup so the server survives session churn. Root-gated in their own
   code (`if (uid == 0)`). Confirmed unavailable to UID 2000/10663 by
   direct `cgroup.procs` permission tests (4o, 4p).
2. **`AdbMdns`/`AdbClient` (Shizuku, `manager/.../adb/`)** — rediscover
   the ephemeral wireless-debug port and reconnect, no human needed.
   **This one worked** when reimplemented with a raw UDP mDNS query (4s)
   — no Android app API needed, just the standard protocol on the wire.
   `relaysh-watchdog.py` uses exactly this.
3. **`getContentProviderExternal()` (scrcpy; also what `content`/`settings`
   shell commands use, 4o)** — reach a system ContentProvider from a
   process AMS doesn't recognize as a real launched app. Gated by a
   signature-only permission with no `development` flag: works for shell
   UID (default grant), does not work for any third-party app UID
   (Termux included), confirmed from AOSP manifest source, independent of
   both this session's own tests and Shizuku's approach entirely.

Net effect: (2) is the one primitive of the three that a no-root, no-adb
Termux-side helper can actually use, and it's already built. (1) and (3)
are both root-or-shell-gated in the actual reference implementations that
invented them, not merely in this session's attempts — about as strong a
"this is genuinely not possible otherwise" signal as this investigation
is going to find.

### 4w. Built a real standalone helper APK for the `Settings.Global` trick — cleared the identity wall, hit Background Activity Launch restrictions, fixed with a `BroadcastReceiver` (same investigation, follow-up)

Revisited 4t/4u's dead end with a different framing: the identity check
that blocks a bare `app_process` helper only blocks processes AMS doesn't
recognize as a real launched app — so instead of trying to fake that
identity, build an actual tiny installed app that legitimately has one.
User explicitly scoped this to *not* touch Termux's own APK (consistent
with 4r's earlier decision) — a brand new, separate, minimal package
(`local.adbwifi.helper`) instead.

**Built entirely by hand in Termux, no Gradle** (`aapt`, `javac` against
the `android-36.jar` stub from 4r, `d8`, `apksigner` — all `pkg`-installable):
a one-`Activity` app requesting `WRITE_SECURE_SETTINGS`, self-signed with
a throwaway debug keystore (`keytool`). `adb install` (one-time, needs
adb) + `adb shell pm grant local.adbwifi.helper
android.permission.WRITE_SECURE_SETTINGS` (confirmed `granted=true` via
`dumpsys`, same as 4u's grant to Termux itself).

**First attempt — launch the Activity to run the code — hit a NEW wall,
not the 4t identity one**: `/system/bin/am start -n
local.adbwifi.helper/.MainActivity` still failed immediately with the
exact same `package com.android.shell does not belong to uid=10663` —
confirming the *system* `am` binary always hardcodes a shell/system
identity, no matter what it's asked to do, exactly like `content`/`settings`
(4o). **But Termux ships its own separate `am`** at
`$PREFIX/bin/am` (`com.termux.termuxam.Am`, confirmed via `logcat`'s
`Calling main entry com.termux.termuxam.Am`) — using *that* instead
produced **no identity exception at all**. Real progress: the identity
wall from 4t/4u is specifically an artifact of borrowed-system-context
CLI tools, not of installed apps as such — a properly installed,
Zygote-launched app (even one launched via Termux's own `am` re-implementation,
itself running with Termux's genuine identity) doesn't hit it.

**But the Activity never actually appeared to run**: no crash, but no
`Log.i`/`Log.e` line from our code either, and polling `ps -A`
immediately after the call (down to 50ms) never showed the target
process spawning at all — the launch was being silently swallowed
somewhere *before* process creation, not inside our code. Termux's `am`
also doesn't surface real errors (always prints `Starting: Intent {...}`
and exits 0 regardless of outcome — a fire-and-forget reimplementation,
not a full diagnostic tool), so this had to be reasoned out rather than
read off an exception.

**Diagnosis, confirmed against official docs**: Android's [Background
Activity Launch restrictions](https://developer.android.com/guide/components/activities/background-starts)
(since API 29) block `Context.startActivity()` calls originating from a
process with no visible UI and not otherwise exempted — exactly Termux's
`am` tool's situation (a short-lived background process, not a foreground
activity). The block happens inside `ActivityTaskManagerService` before
the target app process is ever created, which is precisely why nothing
showed up in `ps` or logcat for `local.adbwifi.helper` — matches the
symptom exactly.

**The fix, confirmed from the same Android docs**: a `BroadcastReceiver`
is an explicitly recognized exception — `onReceive()` runs without ever
calling `startActivity()`, so BAL doesn't apply to it at all. Added a
second component, `EnableReceiver` (a plain `<receiver>`, not an
`<activity>`), doing the identical `Settings.Global.putInt(...)` calls
directly inside `onReceive()`. Rebuilt and signed
(`app-signed.apk` in the scratchpad, source at
`adbwifihelper/src/local/adbwifi/helper/{MainActivity,EnableReceiver}.java`)
— **not yet tested end-to-end**, because wifi/adb dropped again right as
the build finished. Triggering it should be `am broadcast -a
local.adbwifi.helper.ENABLE -n
local.adbwifi.helper/.EnableReceiver` via Termux's own `am`, once wifi is
back — this is the concrete next thing to try, not a finished result.

**If this works, the full picture becomes**: one-time `adb install` +
`pm grant` bootstrap (needs adb once, same as granting Termux
`WRITE_SECURE_SETTINGS` in 4u) → from then on, Termux triggers this
receiver via its own `am broadcast` (no adb) whenever
`relaysh-watchdog.py` finds Wireless Debugging itself disabled → the
receiver flips `adb_wifi_enabled`/`adb_allowed_connection_time` back on
in software → `AdbMdns`-style discovery (4s) finds the now-live port →
normal watchdog recovery proceeds. The one caveat 4v-style reasoning
already flags: this can only ever fix the *toggle*, never a fully-off
wifi *radio* — Settings.Global writes don't power on hardware, so this
closes the "Wireless Debugging turned itself off while wifi stayed on"
gap specifically, not "wifi radio is off" (today's actual blocking state,
per the user's own device).

### 4x. Surveyed scrcpy's real `FakeContext`/`Workarounds`/`CleanUp` source directly — confirms 4v's read with much sharper detail, plus independent confirmation that process death on session end is treated as a given even by scrcpy's own maintainers

User asked for a proper look at the scrcpy repo itself, not just the one
GitHub issue thread. Read the actual shipped source
(`server/src/main/java/com/genymobile/scrcpy/{FakeContext,Workarounds,CleanUp}.java`).

**`FakeContext.java`, in full, is sharper than 4v's summary suggested.**
Key line: `PACKAGE_NAME = "com.android.shell"` — not `"android"`. scrcpy
runs at UID 2000 (always, via `adb shell`), and `com.android.shell` is
the package that *actually, legitimately* owns UID 2000. `getPackageName()`,
`getOpPackageName()`, and (API 31+) `getAttributionSource()` are all
overridden to declare this identity consistently — the last one explicitly
via `new AttributionSource.Builder(Process.SHELL_UID)`, hardcoding
Android's own special shell-UID constant. This is a *correct*
identity for their case, unlike this session's earlier attempt
declaring `"android"` (UID 0) while actually running at UID 10663 —
that specific mismatch was always going to fail no matter what.

**But this identity fix is not what makes `Settings`/`ContentProvider`
calls succeed** — `acquireProvider()` is *separately* overridden to call
`ServiceManager.getActivityManager().getContentProviderExternal(name, new
Binder())` unconditionally, i.e. still the `ACCESS_CONTENT_PROVIDERS_EXTERNALLY`-gated
"external" path from 4r/4v, not the normal identity-checked
`ActivityThread.acquireProvider()` this session kept hitting. Declaring
the correct package name and bypassing the identity-checked path entirely
are two *separate* fixes in `FakeContext`, easy to conflate. Net effect
unchanged from 4v: this only works because the real caller is UID 2000
with shell's default `ACCESS_CONTENT_PROVIDERS_EXTERNALLY` grant — every
piece of `FakeContext` is built around and only valid for that specific
UID, confirmed now at the individual-field level, not just at the
conclusion level.

**`Workarounds.getSystemContext()` is the exact same
`ActivityThread.getSystemContext()` reflection call this session used
directly** (4t) — confirms scrcpy's baseline bootstrap and this session's
are identical; `FakeContext` is a wrapper *around* that same starting
point, not a different one.

**`CleanUp.java`'s own doc comment**: *"Handle the cleanup of scrcpy,
even if the main process is killed... even on device disconnection
(which kills the scrcpy process)."* scrcpy's own maintainers state
plainly, as an accepted fact needing a workaround (a separate
short-lived cleanup thread/process to restore device state like display
power), that disconnection kills their server process. They do not treat
this as solvable — they design a small mitigation for its *consequences*
(leaving the display in a bad state) rather than trying to prevent the
death itself. This is a third independent real-world project (after this
session's own tests and Shizuku's source) treating "the process dies
when the adb session ends" as an unavoidable fact of life to route
around, never as a bug to fix.

### 4y. CONFIRMED WORKING: Termux re-enables Wireless Debugging itself, no adb, via the `EnableReceiver` broadcast (resolves 4w's open question)

4w left off with the `BroadcastReceiver` fix built but untested (wifi
dropped mid-build). Tested end to end once wifi came back, including a
detour: `am start`-ing the *Activity* still produced no observable
process at all, and initial belief this was still BAL turned out to be a
red herring — `dumpsys activity broadcasts` (over a reconnected adb)
showed the broadcast itself was actually `DELIVERED ... terminal +8ms ...
reason: remote app` every time, meaning `EnableReceiver` **was** running
successfully all along; the reason no `Log.i`/`Log.e` output was ever
seen in Termux's own `logcat -d` is that a third-party app's `READ_LOGS`
grant only exposes **that app's own UID's log lines** on this device —
not a system-wide view — so Termux was never going to see
`local.adbwifi.helper`'s log output no matter what, independent of
whether the code ran. Worth remembering next time `logcat` silence is
used as evidence of failure.

**Clean before/after proof, no ambiguity**: with adb connected, set
`adb_allowed_connection_time` to an arbitrary marker value (`555555`) via
`settings put global`; disconnected adb completely; triggered
`am broadcast -a local.adbwifi.helper.ENABLE -n
local.adbwifi.helper/.EnableReceiver` **from Termux, zero adb involved**;
reconnected adb afterward and read the value back — **`0`**, exactly
what `EnableReceiver.onReceive()` writes, and nothing Android does on its
own would coincidentally produce that exact value right after a
deliberately-set `555555`. Confirms unambiguously: Termux can flip
`adb_wifi_enabled`/`ADB_ENABLED`/`adb_allowed_connection_time` back on
in software, entirely on its own, once `local.adbwifi.helper` is
installed and granted `WRITE_SECURE_SETTINGS` (one-time `adb install` +
`adb shell pm grant`, same as 4w/4u).

**The actual mechanism, now fully worked out end to end**:
1. One-time setup (needs adb once): `adb install app-signed.apk` (source
   at `~/.../scratchpad/adbwifihelper/`, not checked into this repo —
   consider moving it in if this becomes a permanent fixture) + `adb
   shell pm grant local.adbwifi.helper android.permission.WRITE_SECURE_SETTINGS`.
2. Any time after that, fully adb-free: `am broadcast -a
   local.adbwifi.helper.ENABLE -n local.adbwifi.helper/.EnableReceiver`
   (Termux's own bundled `am`, not `/system/bin/am`) re-enables Wireless
   Debugging in software.
3. `relaysh-watchdog.py`'s existing mDNS discovery (4s) then finds the
   now-live port and proceeds with its normal `adb connect` + relaunch
   flow.

**What this does and does not close**: this fixes exactly the gap 4s/4t
identified — "Wireless Debugging turned itself off while wifi stayed
on" is now fully self-healing, no human needed at all. It does **not**
help when wifi *radio* itself is off (today's original blocker,
"chỉ còn mạng mobile") — `Settings.Global` writes flip a software flag,
they cannot power on hardware. That remains a hard, unavoidable
human-in-the-loop step (confirmed across 4n-4x from every angle this
session or the primary sources it read could find).

**Also fixed in passing**: the mDNS discovery script (4s) had a real bug
— it captured the *last* SRV record seen in any response, not
specifically one under `_adb-tls-connect._tcp`, and a response
containing an unrelated advertised service (`_nearbypresence._tcp`, seen
live on this device) silently returned that service's port instead.
Fixed by filtering to records whose name contains `_adb-tls-connect`
before extracting the port. `relaysh-watchdog.py`'s copy of this logic
should get the same fix before being relied on unattended — not yet
patched there as of this note.

**Not yet done**: wiring `relaysh-watchdog.py` to actually call this
broadcast when it detects Wireless Debugging is off (currently it only
tries mDNS discovery and gives up if nothing is found); applying the
mDNS parser bugfix to the watchdog's copy; deciding whether
`local.adbwifi.helper`'s source belongs in this repo permanently now
that it's a working, load-bearing piece rather than a one-off
experiment.

