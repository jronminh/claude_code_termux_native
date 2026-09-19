---
name: adb-bridge
description: Gives Claude direct sight of, and control over, the ENTIRE Android screen (not just Termux) via a self-paired wireless ADB connection — screenshots, exact-coordinate UI dumps, tap/swipe input injection, and full-system logcat. Use when termux-api/Termux's own tools can't see enough to debug or drive something (a permission dialog, an app-install prompt, an OEM-specific settings screen, any UI state or system log Termux's own restricted view can't reach). Opt-in and security-sensitive (adb shell runs at the `shell` UID) — read "Security posture" before pairing or running any command here.
---

<!-- Installed and kept in sync by claude-code-termux-native's install.sh
     (only with --with-adb-bridge) from skills/adb-bridge/SKILL.md in that
     repo. A future install.sh run overwrites this file whole — don't
     hand-edit it; fix the repo copy instead, then re-run install.sh. -->

# adb-bridge

## Security posture — read this before doing anything else

`adb shell` on a wireless-debugging connection runs at the `shell` UID —
broad system visibility (full logcat, on-screen content via screencap,
synthetic tap/swipe/type anywhere, including other apps), not scoped to
Termux. A pairing **persists until the user revokes it** in Developer
options — it is not a one-shot grant.

- **Ask before starting a NEW pairing.** Run `status` first (below) — if
  already connected, reuse it instead of re-pairing. If not connected and
  you think this capability would help, explain why and get explicit
  confirmation before walking the user through Developer options; this is
  a real security decision, not a default to reach for.
- **Never wire screenshot/dump/tap/logcat into a background or per-turn
  hook.** Every use must be a deliberate, visible action tied to a
  specific need in the conversation (e.g. "let me look at what's on
  screen to see why that install failed") — contrast with the wake-lock/
  battery-context session hooks, which run silently every turn by design.
  This capability must never do that.
- **When finished, remind the user to turn off Wireless debugging** in
  Developer options. Nothing here can toggle that setting itself — it's a
  system setting, not something a script/hook can flip. `adb-bridge.sh
  status` / `doctor.sh` report live connection state; the opt-in Stop hook
  (`install.sh --with-adb-bridge`) also nags at end-of-session if a device
  is still connected.
- A `tap`/`swipe` is a real action on the live device, same trust level as
  a shell command. Driving through a multi-step debug flow autonomously is
  fine; leave the final tap of anything truly consequential (confirming an
  app install, a payment, a destructive dialog) for the human to do by
  hand — Claude Code's own auto-mode classifier already blocks some of
  these, but don't rely on that alone; use judgment.

## Pairing (self-paired to the same device, no computer needed)

The ADB daemon listens on `127.0.0.1:<port>` once Wireless debugging is
on, so pairing happens entirely on-device:

1. `pkg install android-tools` (adds `adb`; `adb-bridge.sh` itself is
   already staged at `~/.claude/claude-native/adb-bridge.sh` if installed
   with `--with-adb-bridge`).
2. On-device: **Settings → Developer options → Wireless debugging** (if
   Developer options isn't visible yet: Settings → About phone → tap
   **Build number** ~7 times) → tap the **Wireless debugging** row itself
   (not its toggle) → **"Pair device with pairing code"**. This shows a
   **6-digit code** and an `ip:port` (pairing port — temporary).
3. `adb pair 127.0.0.1:<pairing-port> <6-digit-code>` → "Successfully paired".
4. Back on the main Wireless debugging screen, a **different** `ip:port`
   is shown (the real debug port) → `adb connect 127.0.0.1:<debug-port>`.
5. Confirm: `~/.claude/claude-native/adb-bridge.sh status`.

If the user reads a code/IP with a typo (easy to misread on a small
screen — `1.288:33111` for `192.168.1.228:33111` has happened), cross-
check the IP against `termux-wifi-connectioninfo` or `ip addr` before
retrying pairing.

## Commands (`~/.claude/claude-native/adb-bridge.sh`)

| Command | What it does |
| :--- | :--- |
| `status [--json]` | connected? which device? — always check this first |
| `screenshot [PATH]` | screencap, pulled locally, prints the path — `Read` it directly (Claude is multimodal) |
| `dump [PATH]` | `uiautomator dump`, pulled locally — XML with exact `bounds="[x1,y1][x2,y2]"` per element |
| `tap X Y` | `input tap` at exact coordinates |
| `swipe X1 Y1 X2 Y2 [MS]` | `input swipe` |
| `logcat [LINES]` | last LINES of the full system log (default 500), one-shot |
| `logcat-clear` | clear the log buffer — do this before reproducing an issue, then `logcat` to see only the new entries |
| `nag` | internal — used by the opt-in Stop hook, not for interactive use |

## Workflow that actually works

- **Don't compute tap coordinates from a screenshot's displayed/scaled
  size.** A screenshot is often shown scaled down from the real
  resolution (e.g. 923×2000 displayed vs 1080×2340 real — a ~1.17×
  factor); a small arithmetic slip lands the tap outside the intended
  element. This exact mistake once dismissed a bottom-sheet dialog by
  tapping ~600px off target. Prefer: `dump` → read the `bounds=` for the
  target element → compute its center → `tap` there. Use a screenshot for
  the broad "what's on screen" picture, `dump` for the precise coordinate.
- **If an action doesn't produce the expected UI change, check `logcat`
  before taking another screenshot.** In the incident that motivated this
  skill, the screen alone looked like "nothing happened" after a tap, but
  `logcat` revealed the real cause immediately (an app crash with a full
  stack trace) — something no screenshot could show.
- Termux's own `logcat`/`screencap` are restricted to `root`/`system`/
  `shell` UIDs and fail silently or with a generic error from Termux's own
  (unprivileged app-UID) shell — this is precisely the gap `adb shell`
  closes, since the ADB daemon itself runs as `shell`.

## Further reading

`notes/termux-features-research.md` section "4b" has the full incident
write-up this skill was extracted from (a real Termux:Widget install
failure debugged live via this exact toolchain), including the actual
root cause it uncovered and the reasoning behind the security-posture
rules above.
