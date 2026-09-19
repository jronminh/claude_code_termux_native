# Termux:API command survey

Every `termux-*` command actually surveyed on-device (`--help` reads,
wrapper-script inspection) while researching what this repo could build,
organized by category rather than by when it was looked at. See
`notes/termux-features-research.md` (sections 1 and 4a) for the session
narrative and what was ultimately implemented and why.

## Needs only bare Termux (no Termux:API app required)

- **`termux-wake-lock` / `termux-wake-unlock`** — calls `am startservice
  --user ... -a com.termux.service_wake_lock com.termux/com.termux.app.TermuxService`
  directly. No separate app install. Used by `scripts/session-hooks.sh`
  for the per-turn wake-lock feature.

## Needs `pkg install termux-api` + the separate Termux:API app installed

- **`termux-notification`** — full flag set: `-i/--id` (update/replace by
  id), `--ongoing` (pin), `--button1/2/3` + `--button1-action` (tappable
  actions run a shell command), `--vibrate <pattern>`, `--priority`,
  `--channel`, `--group`, `-c/--content` (or stdin). Used by
  `session-hooks.sh` for permission/idle/long-task notifications.
- **`termux-battery-status`** — JSON: `percentage`, `status`
  (`CHARGING`/`DISCHARGING`/`FULL`/...), `plugged`, `health`,
  `temperature`, `voltage`. Used by `session-hooks.sh`'s battery-aware
  context injection.
- **`termux-job-scheduler`** — real Android `JobScheduler`, not a plain
  cron wrapper. `-s/--script PATH` (a script FILE, not an arbitrary
  command line — confirmed by reading the wrapper: it only ever sends
  `--es script <path>` as an intent extra), `--job-id INT` (must be an
  int, not a name — overwrites any previous job with the same id),
  `--period-ms` (Android clamps periodic jobs to a 15-minute/900000ms
  minimum since Android N), `--battery-not-low` (default **true** —
  Android itself won't start the job on low battery, no app-level logic
  needed), `--charging`, `--network`, `--persisted` (survive reboot).
  Solves a real gap: a plain background loop/cron job gets killed by
  Android's Doze the moment the screen locks; JobScheduler actually wakes
  the device for it. Backs `termux-claude-job`
  (`scripts/claude-job.sh`/`claude-job-runner.sh`).
- **`termux-share <path>` / `termux-open <path-or-url>`** — native share
  sheet / default-app-open. Both plain 1-argument commands, no output to
  parse, fire-and-forget. Deliberately NOT wrapped in a script of their
  own — the actual feature is `CLAUDE.md.template` telling Claude to
  reach for them proactively instead of just printing a file path.
- **`termux-vibrate`** — `[-d duration_ms] [-f force]`. Trivial wrapper,
  surveyed, not built into anything yet.
- **`termux-tts-speak`** — `[-e engine] [-l lang] [-p pitch] [-r rate]
  [-s stream] [text]`, reads stdin if no args. Could read a short spoken
  summary aloud — surveyed, not built.
- **`termux-clipboard-set`** — reads stdin or args, sets the system
  clipboard. Surveyed, not built into anything yet.
- **`termux-storage-get` / `termux-saf-*`** — `termux-saf-managedir`
  requires an **interactive system file picker** (the user must tap
  through a dialog) — not usable from a non-interactive hook. For writing
  output somewhere visible to other Android apps, `termux-setup-storage`
  (one-time grant, creates `~/storage/downloads` etc.) is the practical
  option, not SAF.
- **`termux-toast`** — surveyed, deliberately not pursued: strictly
  weaker than the notification-based approach already in use (no
  persistence, no tap actions).
- **`termux-speech-to-text`** — surveyed, a real feature idea (voice
  dictation into a prompt) but intentionally deferred: needs its own UX
  design (how does the dictated result actually get into Claude's input
  box?) rather than being a mechanical wrap like the others.
- **`termux-brightness`** — surveyed, not pursued; no concrete use case
  identified yet.

## Checked for, found not present on the surveyed device

- `~/.shortcuts/*.sh` (Termux:Widget, home-screen shortcuts) and
  `~/.termux/boot/*.sh` (Termux:Boot, run-on-device-boot) — neither
  existed. Termux:Widget in particular needed a real companion app
  install (see `notes/termux-features-research.md` section 4b for the
  full sideload-troubleshooting saga this triggered, which is what
  discovered the ADB-bridge capability documented in the `adb-bridge`
  skill). Not built this round regardless: `termux-job-scheduler` already
  covers "run something periodically" without needing a home-screen
  widget, and `--persisted` jobs already survive reboot without a boot
  script — a widget/boot-script companion would need its own UX design
  (what should a one-tap shortcut actually DO?) before it's worth adding.

## Deliberately not pursued at all

- **`termux-dialog` from inside a hook** — a hook that blocks waiting for
  an interactive answer could hang the whole session; too risky to wire
  into anything automatic.
- **Camera / sensor / telephony / NFC / torch / infrared** commands — no
  real use case identified for a coding CLI.

## The actual screen/input gap these don't cover

None of the above can screenshot the Android screen, read another app's
logs, or inject a tap/swipe anywhere outside Termux itself — `termux-api`
has no screenshot command at all, and Termux's own `screencap`/`logcat`
are restricted to `root`/`system`/`shell` UIDs (a deliberate Android
security boundary, not a missing tool). That gap is what the separate
**`adb-bridge`** feature closes, via a self-paired wireless ADB
connection instead of `termux-api` — see the `adb-bridge` skill
(`skills/adb-bridge/SKILL.md`) and `notes/termux-features-research.md`
section 4b for how that was discovered and why it's opt-in/security-
sensitive rather than wired in by default like everything above.
