# Research notes: Termux:API + keybindings feature ideas

Scratch notes from a research session, kept for reference before implementing.
**Not committed on purpose** — working notes, not a deliverable.

## 1. Termux:API command survey

Ran directly on-device (`--help` / reading the wrapper scripts under `$PREFIX/bin/termux-*`).

### Needs only Termux itself (no Termux:API app required)

- **`termux-wake-lock` / `termux-wake-unlock`** — calls `am startservice --user ... -a com.termux.service_wake_lock com.termux/com.termux.app.TermuxService` directly. Works with bare Termux, no separate app install. Highest-value, lowest-friction feature candidate.

### Needs the Termux:API app + `pkg install termux-api`

- **`termux-notification`** — full flag set confirmed via `--help`:
  `-i/--id` (update/replace by id), `--ongoing` (pin), `--button1/2/3` + `--button1-action` (tappable actions), `--vibrate pattern`, `--priority`, `--channel`, `--group`, `-c/--content` (or stdin). Enough to build a "Claude is working... -> done" notification that updates in place.
- **`termux-vibrate`** — `termux-vibrate [-d duration_ms] [-f force]`. Trivial wrapper around `Vibrate` broadcast.
- **`termux-tts-speak`** — `[-e engine] [-l lang] [-p pitch] [-r rate] [-s stream] [text]`, reads stdin if no args. Could read a short spoken summary aloud.
- **`termux-clipboard-set`** — reads stdin or args, sets system clipboard.
- **`termux-storage-get`** / **`termux-saf-*`** — `termux-saf-managedir` requires an **interactive system file picker** (user must tap through a dialog) — not usable from a non-interactive hook. For writing output somewhere visible to other Android apps, `termux-setup-storage` (one-time grant, creates `~/storage/downloads` etc.) is the practical option, not SAF.

### Not worth pursuing

- `termux-dialog` inside a hook — hooks that need to answer before Claude continues could hang the session; too risky.
- camera/sensor/telephony/nfc/torch/infrared — no real use case for a coding CLI.

## 2. Claude Code hooks — verified facts

**Source of truth:** fetched directly from `https://code.claude.com/docs/en/hooks` (redirected from `docs.claude.com/en/docs/claude-code/hooks`) via two separate WebFetch calls, quotes below are as returned.

⚠️ A background research *subagent* was asked to look this up first and its output was **flagged by the harness for containing instruction-shaped content matching "bypass-permissions"** — likely a prompt-injection encountered while it browsed. That report is **not used** as a source below; everything here was re-verified directly against the docs.

### Confirmed real

- Event list (33 total) does include `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `Stop`, `Notification` — the ones relevant to this feature.
- `Notification` fires with a `notification_type` of: `permission_prompt`, `idle_prompt`, `auth_success`, `elicitation_dialog`, `elicitation_url_dialog`, `elicitation_complete`, `elicitation_response`, `agent_needs_input`, `agent_completed`, `quota_auto_resume_fired`, `quota_auto_resume_stale`, `quota_auto_resume_disabled`.
- Common input fields across hooks: `session_id`, `prompt_id`, `transcript_path`, `cwd`, `scratchpad_dir`, `permission_mode`, `hook_event_name` (+ `agent_id`/`agent_type` in subagent contexts). Only `SessionStart` can also receive a `model` field (not always present).
- Exit codes: `0` = success (for `UserPromptSubmit`/`UserPromptExpansion`/`SessionStart`/`PostModelSwitch` only, plain stdout text is fed back to Claude as context; other events just log stdout to debug log). `2` = blocks — meaning is event-specific: on `Stop` it "prevents Claude from stopping, continues the conversation"; on `UserPromptSubmit` it "blocks prompt processing and erases the prompt". Any other code = non-blocking error, action proceeds.
- Matcher syntax: `"*"` / `""` / omitted = match all; string of letters/digits/`_-, |` = exact match or `|`/`,`-separated list; anything else = unanchored JS regex.
- Timeout defaults: 600s for `command`/`http`/`mcp_tool`; lowered to 30s on `UserPromptSubmit`/`PreModelSwitch`/`PostModelSwitch`; 10s on `MessageDisplay`. **`SessionEnd` hooks share one 1.5s total budget**, extendable up to 60s only by setting a longer per-hook `timeout`.
- All matching hooks for one event run **in parallel**, not sequentially. The same handler defined in multiple settings files runs once.
- `async` (bool) and `asyncRewake` (bool) are real fields on a `command` hook: `async: true` runs it in the background without blocking; `asyncRewake: true` additionally wakes Claude with the hook's stderr/stdout as a system reminder if it later exits with code 2.

### Claimed by the (untrusted) subagent report but NOT found in the real docs — do not rely on these

- A `stop_hook_active` loop-guard field on the `Stop` hook's stdin — **not mentioned anywhere** in the real docs.
- A `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP` environment variable to raise an "8 consecutive block" cap — **fabricated**, does not exist.
- A full worked JSON stdin example for `Notification` — the real docs don't show one; the subagent invented a plausible-looking one.

**Design implication:** since there's no confirmed anti-loop mechanism for a blocking `Stop` hook, our hooks must **never return exit code 2** — always exit 0 (or a non-2 non-zero code, treated as a harmless non-blocking error) so there's zero chance of stalling a turn.

### More findings from a later session (2026-09-16) — output/rewrite fields, systemMessage

Method this time: `strings -a ~/.claude/claude-native/claude | grep ...` against the live ~207MB Bun-bundled binary (real minified schema defs, `c({hookEventName:C("...")...})` calls) first, then cross-checked against `https://code.claude.com/docs/en/hooks` via WebFetch/WebSearch (page kept truncating on fetch — only got partial confirmation, not the full per-event reference).

**Confirmed real (binary + docs agree):**

- `PreToolUse` can return `updatedInput` (rewrite the tool's input before it runs) alongside `permissionDecision`/`permissionDecisionReason`/`additionalContext`. **Verified working live**: a test hook appended `; echo MARKER` to a Bash command via `updatedInput: {command: ...}` and the marker actually executed — the rewrite is real and takes effect.
- `PostToolUse` can return `updatedToolOutput` (*"Replaces the tool output before it is sent to the model"*) and `updatedMCPToolOutput` (MCP-only variant), plus `classifierContext` (auto-mode permission classifier hint, 2000 UTF-16 code unit cap, sync-only, explicitly documented as insecure to fill with untrusted tool output). Docs example:
  ```json
  {"hookSpecificOutput": {"hookEventName": "PostToolUse", "updatedToolOutput": "..."}}
  ```
  **Live test was inconclusive** — set this field via a temp hook, but the original (unmodified) Bash output still showed up both to the model and in the stored transcript. Most likely cause: two `PostToolUse` hooks matching `Bash` ran in parallel at the same time (the pre-existing `.*` context-monitor hook + the test hook) and the merge dropped/ignored the rewrite — never got to re-test in isolation (session moved on). **Don't trust this field works until re-tested with exactly one PostToolUse hook active for the matcher.**
- Full hook event list, more complete than the "33 total" figure from the earlier research above — binary strings turned up (beyond the ones already listed): `PostToolUseFailure`, `PostToolBatch`, `UserPromptExpansion`, `PreModelSwitch`/`PostModelSwitch` (`permissionDecision: allow/deny/ask`, *"Same contract as PreToolUse: allow proceeds (skipping the interactive cache-miss confirm), deny cancels the switch, ask asks the user to confirm"*), `PermissionRequest`, `PermissionDenied`, `CwdChanged`/`FileChanged` (`watchPaths`), `MessageDisplay` (`displayContent` — *"Text displayed in place of the delta. Omit to display the original."*, i.e. can override what streams to the terminal without changing what the model actually received), `Elicitation`/`ElicitationResult`, `WorktreeCreate`, `Setup`.
- Top-level fields (siblings of `hookSpecificOutput`, apply across many event types): `systemMessage` (*"Warning message shown to the user"*), `decision` (`"approve"`/`"block"`, independent of the PreToolUse-only `permissionDecision`), `reason`, `terminalSequence` (*"A terminal escape sequence (e.g. OSC 9 / OSC 777 desktop-notification) for Claude Code to emit"* — real OS-level desktop notification trigger).
- When multiple hooks return conflicting `permissionDecision` for the same event, priority is `{allow: 1, ask: 2, deny: 3}` — **strictest wins**, not last-hook-wins.
- Real `settings.json` keys confirmed via the schema-validation error dump (triggered by an invalid edit, which dumped the full JSON Schema — an expensive ~70k-token way to learn this, don't repeat that): `autoCompactWindow` (int, 100000–1000000), `bashOutputMaxChars` (default 30000, clamps 4000–128000), `promptCacheTtl`/`subagentPromptCacheTtl` (`"5m"`/`"1h"`), `skillListingMaxDescChars` (default 1536 — a prior binary-strings-only pass in a different research thread wrongly concluded this key doesn't exist; it does, the grep pattern just missed it), `switchModelsOnFlag` (bool, real), `effortLevel`/`maxEffortLevel` (`low`/`medium`/`high`/`xhigh`/`max`), `ultracode` (bool, session-scoped), `axScreenReader`.

**Tested live and found NOT to work here — `systemMessage` does not render:**

Built a throwaway hook (`if: "Bash(echo SYSTEMMSGTEST*)"` filter so it only fired on one deliberate command, removed immediately after) that returned a distinctive `systemMessage` string with `permissionDecision: "allow"`. **Nothing appeared anywhere visible** — confirmed with the user directly, who was using the native Termux app (not Remote Control, not Claude Desktop, so `anthropics/claude-code#77518` — *"Desktop app and remote-control sessions never render hook systemMessage"* — doesn't apply here). Root cause not confirmed (docs truncated before the per-event systemMessage rules); leading unverified hypothesis is that `systemMessage` may only render alongside a blocking `permissionDecision` (`deny`/`ask`), not `allow`/unset, since every documented example pairs it with `deny`. **Practical takeaway: for this install, don't rely on `systemMessage` to reach the user — use `additionalContext` and have CLAUDE.md instruct the model to relay it instead** (confirmed working reliably, many times, all session).

### Session 2026-09-16 (cont'd) — `WebFetch` against `code.claude.com/docs/en/hooks`, anchor-by-anchor

The full page still truncates on a single fetch, but fetching individual `#anchor` sections (`#pretooluse`, `#posttooluse`, `#notification`, `#stop`) got clean per-event tables where the whole-page fetch didn't. Each fetch used a small fast model to read+summarize the page, so treat markdown **tables it reproduced verbatim as high confidence**; prose paragraphs with no quoted table (one exception below) as lower confidence.

**Correction to the "systemMessage doesn't render" finding above:** it wasn't broken — the test's expectation was wrong. Docs are explicit that `systemMessage` targets **Claude**, not the human user, and behavior differs per event:
- `PreToolUse`: *"A message to show Claude in the transcript. Claude Code shows this on most events; see each event's section for where it appears"*
- `PostToolUse`: *"Message shown to Claude as a system reminder"*
- `Stop`: *"Message shown to Claude in the system context, visible in the transcript. Use this to give Claude feedback on its response so it can act on it in the next turn"*
- `Notification`: *"Plain text or Markdown message for Claude to see and act on. Claude reads this on every exit code except 2. Not shown in the transcript; stays private to Claude"*

So our earlier PreToolUse test (distinctive `systemMessage` string, nothing appeared to the human user) likely *did* reach the model as transcript/context — we just checked the wrong surface (human-visible UI) instead of the model's context. **Practical takeaway is unchanged** (still use `additionalContext` + CLAUDE.md relay for anything that must reach the human), but the root cause is now understood rather than a hypothesis.

**`PostToolUse` full JSON output table (confirmed, verbatim):**

| Field | Description |
| :---- | :---------- |
| `hookSpecificOutput.additionalContext` | Additional context to show Claude about the tool result |
| `hookSpecificOutput.updatedToolOutput` | Modified tool output for Claude to see. Replace `content` with your updated text, keep other fields like `truncated` and `error` as-is. For MCP tools, use `updatedMCPToolOutput` instead |
| `hookSpecificOutput.updatedMCPToolOutput` | For MCP tools only: modified tool output, `content` field |
| `hookSpecificOutput.classifierContext` | Context for the permission classifier, to help it decide on future similar tool calls |
| `systemMessage` | Message shown to Claude as a system reminder |
| `terminalSequence` | ANSI/OSC sequence for notifications |

This confirms `updatedToolOutput` is real (matches the earlier binary-strings finding) — our live test was inconclusive due to a parallel-hook merge issue, not because the field doesn't exist.

**`PreToolUse` full JSON output table (confirmed, verbatim) — note `permissionDecision` is documented here as only `"allow"`/`"deny"`, no `"ask"`:**

| Field | Description |
| :---- | :---------- |
| `permissionDecision` | `"allow"` or `"deny"`. Controls whether the tool call proceeds |
| `permissionDecisionReason` | Explanation for the decision, shown to Claude when denied |
| `updatedInput` | Modified tool input, matched against the tool's schema; on validation failure the hook is reported as an error and the original input is used |
| `additionalContext` | Sent to Claude about the tool call/result, appended whether the call proceeds or is denied |

This conflicts with the earlier "three-way priority `{allow:1, ask:2, deny:3}`" note (source: binary strings) — docs for this specific table only show two values. Possible explanations: `"ask"` is valid but omitted from this particular table, or it applies at a different layer (interactive permission system) rather than as a hook return value. **Unresolved — don't assume `"ask"` is a valid `permissionDecision` return value from a `PreToolUse` hook without testing.**

**`Stop` section — new finding, confidence caveat below:** the stdin JSON example fetched this time **does include** `"stop_hook_active": true`, directly contradicting the earlier "fabricated, not mentioned anywhere" verdict. The fetch also returned prose (not a quoted table) claiming *"Claude Code enforces a cap on consecutive Stop hook blocks... the exact threshold and behavior... is managed to prevent runaway blocking scenarios"* — this paragraph reads as the summarizing model's paraphrase, not a verbatim quote (it hedges and never states a number), so **treat the existence of a cap as plausible but unconfirmed**; treat `stop_hook_active` in the stdin example as likely real since it appeared in a concrete JSON code block, same reproduction pattern as everything else confirmed above.

**Design implication revisited:** given `stop_hook_active` is probably real after all, a `Stop` hook *could* check it to detect it's already in a loop — but our `session-hooks.sh` doesn't need this since `cmd_stop` never returns exit 2 in the first place (it only fires `termux-wake-unlock` / a notification, never blocks). No change needed to the shipped hook; noting this only so a future blocking-Stop-hook feature doesn't have to re-derive it.

## 3. Keybindings (`~/.claude/keybindings.json`) — via the `keybindings-help` skill

Full reference loaded (contexts, actions, reserved/non-rebindable keys) — see skill output earlier in session for the complete action table if needed again.

Key findings that corrected earlier (wrong) assumptions:

- `chat:newline` default is **`ctrl+j`**, not Shift+Enter/Option+Enter — the "soft keyboard can't send Shift+Enter" concern doesn't apply.
- Termux's default extra-keys row already surfaces ESC/TAB/CTRL/ALT as single taps, so `escape`-bound actions (`chat:cancel`, `autocomplete:dismiss`, `help:dismiss`, ...) are not actually painful.
- Docs state `alt`/`opt`/`option` and `meta`/`cmd`/`command` are "identical in terminals" — so `meta+p` / `meta+o` / `meta+t` / `meta+w` / `cmd+k` bindings are all reachable via Termux's plain **ALT** extra-key, despite the "cmd" naming suggesting a Mac-only key. This is a documentation gap, not a real defect.
- `ctrl+c`, `ctrl+d`, `ctrl+m`, `ctrl+[`, `ctrl+i`, `ctrl+h` are hardcoded/non-rebindable — the "Ctrl needs a toggle tap" friction is inherent to all terminal apps on Termux, not fixable here.

Real friction found:

1. **Two-stage `ctrl+x <key>` chords with no single-key fallback**: `chat:killAgents` (`ctrl+x ctrl+k`), `abovePrompt:toggle` (`ctrl+x ctrl+a`), `abovePrompt:focus` (`ctrl+x tab`), `pane:grow`/`pane:shrink` (`ctrl+x left/right/up/down`), `app:cycleDiffBase` (`ctrl+x b`). Chaining two Ctrl-toggle chords inside the 1s timeout on a touchscreen is the worst UX in the whole binding table. (Contrast: `task:background` and `chat:externalEditor` already ship a plain single-chord fallback alongside their `ctrl+x ...` form — those are fine as-is.)
2. **`task:background`'s plain `ctrl+b` fallback conflicts with tmux's default prefix key** — relevant because Termux users commonly run `tmux` for split panes/multiple sessions (Termux itself has no native tabs).

## 4a. Second survey pass (session 2026-09-17) — new integration ideas

After A-E below were already implemented, ran a second on-device survey
specifically for **new** Termux/Android bridges not covered above. Command
list confirmed via `ls "$PREFIX/bin/" | grep '^termux-'` (`termux-api`
package already installed on this device) plus targeted `--help` reads.

**New commands found, not in section 1's original survey:**

- `termux-job-scheduler` — real Android `JobScheduler`, not a plain-cron
  wrapper. `-s/--script path` (a script FILE, not an arbitrary command
  line — no argument-passing mechanism, confirmed by reading the wrapper
  at `$PREFIX/bin/termux-job-scheduler`: it only ever sends `--es script
  <path>` as an intent extra), `--job-id int` (**must be an int, not a
  name** — overwrites any previous job with the same id), `--period-ms`
  (Android clamps periodic jobs to a 15-minute/900000ms minimum since
  Android N, confirmed in the tool's own `--help`), `--battery-not-low`
  (default **true** — Android itself won't even start the job on low
  battery, no app-level logic needed for that part), `--charging`,
  `--network`, `--persisted` (survive reboot). Solves a real gap: a plain
  background loop/cron job gets killed by Android's Doze the moment the
  screen locks; JobScheduler actually wakes the device for it. Directly
  relevant to the `loop`/`schedule` Claude Code skills on a phone.
- `termux-battery-status` — confirmed real JSON on this device (23%
  discharging at the time): `percentage`, `status`
  (`CHARGING`/`DISCHARGING`/`FULL`/...), `plugged`, `health`,
  `temperature`, `voltage`, etc.
- `termux-share <path>` / `termux-open <path-or-url>` — share sheet /
  default-app-open, both plain 1-arg commands, no output to parse.
- `termux-toast`, `termux-speech-to-text`, `termux-brightness` — surveyed,
  not pursued this round (toast is strictly weaker than the notification
  hook already in use; the other two are real feature ideas for later, not
  discarded — see "Not yet pursued" below).
- Checked for `~/.shortcuts` (Termux:Widget) and `~/.termux/boot`
  (Termux:Boot) on this device: **neither exists yet** — not set up, and
  not built this round (job-scheduler covers the "run something
  periodically" need without needing a home-screen widget or a boot
  script).

**Implemented this session** (see `## Status of features discussed this
session` in `planned-features-and-seo.md` for the commit-level record):

1. **Battery-aware `UserPromptSubmit` context** — `session-hooks.sh`'s
   `battery_context()`. Below 20% and not charging → plain stdout text
   (confirmed in section 2 above: `UserPromptSubmit`'s stdout is fed back
   to Claude as context) so **Claude** becomes aware, not a
   human-facing notification. `timeout 3` caps the call so a missing/
   ungranted Termux:API app can't delay every prompt.
   Tested live against this device's real battery (23%/22% discharging —
   correctly silent, both above the 20% threshold) and against a faked
   15%-discharging / 15%-charging `termux-battery-status` (correctly
   fires / stays silent respectively).
2. **`termux-claude-job`** (`scripts/claude-job.sh` +
   `scripts/claude-job-runner.sh`) — `add`/`list`/`remove`/`run`/`log` CLI
   over `termux-job-scheduler`. Job-id is `cksum(name) % 2000000000`
   (deterministic from the name, avoids needing a persisted counter file
   or int32 overflow). Each scheduled job is a tiny generated stub script
   (`~/.claude/claude-native/jobs/<name>.sh`, since JobScheduler needs one
   script path per job) that just `exec`s the shared runner with the job
   name as its one argument. **The runner reuses `session-hooks.sh
   submit`/`stop` directly** (piping a synthetic `{"session_id":
   "job-<name>-<pid>", "cwd": ...}` into it) rather than calling
   `termux-wake-lock`/`-unlock` itself — this was a deliberate fix during
   implementation: a naive direct call would have reintroduced the exact
   cross-session wake-lock race that `session-hooks.sh` itself was just
   fixed for (global, non-ref-counted lock — see the two-bug-fix commit
   `398fda8`). Tested end-to-end in a fully sandboxed fake `$HOME`+`$PREFIX`
   (fake `claude`/`termux-wake-lock`/`-unlock`/`-notification`/
   `termux-job-scheduler` binaries): `add` generates the right JSON/stub/
   job-id and calls `termux-job-scheduler` with the right flags, the
   15-min clamp warning fires correctly on a sub-threshold `--period-ms`,
   `list`/`remove` round-trip correctly, and the runner correctly
   delegates wake-lock/notification through `session-hooks.sh` and logs
   prompt/cwd/exit-code/duration.
   `uninstall.sh` cancels jobs by their specific job-id, **not**
   `--cancel-all` — caught during implementation that `--cancel-all` has
   no per-app namespacing in `termux-job-scheduler` and would cancel any
   *unrelated* job scheduled by another tool on the same device.
3. **`termux-open`/`termux-share`** — deliberately **not** wrapped in a
   new script (they're already clean 1-arg system commands once
   `termux-api` is installed). The actual feature is
   `CLAUDE.md.template` documenting when to reach for them, so Claude
   proactively offers `termux-open <path>` / `termux-share <path>` for a
   produced artifact instead of only printing its path.

**Not yet pursued** (real ideas, intentionally deferred, not discarded):
- `termux-speech-to-text` for voice-dictated prompts — a real fit given
  the keybindings research above already documented phone-keyboard
  friction, but a distinct-enough feature (needs its own UX: how does a
  dictated result get into Claude's input?) to scope separately.
- Termux:Widget (`~/.shortcuts/*.sh`) home-screen shortcuts — natural
  companion to `termux-claude-job` (one-tap "run this job now" or "open
  Termux + resume session X"), not built since it needs a design decision
  (what should a shortcut actually DO — resume last session? run a named
  job? prompt for one?) rather than a mechanical wrap.
- Termux:Boot (`~/.termux/boot/*.sh`) — would only matter once
  `--persisted true` jobs are common enough that "did they survive my
  last reboot" becomes a real question; not needed for `termux-claude-job`
  itself (Android's own `--persisted` flag already handles reboot
  survival without a boot script).

## 4. Proposed designs (not yet implemented)

### A. Per-turn wake-lock (highest value, lowest friction)
- `UserPromptSubmit` hook → `termux-wake-lock`
- `Stop` hook → `termux-wake-unlock`
- Both `command` type, synchronous, always exit 0, best-effort (`command -v termux-wake-lock || exit 0`, same pattern as the existing `notify()` helper in `update.sh`/`autocheck.sh`).
- Reuses no Termux:API app dependency at all.

### B. Important-moment notifications
- `Notification` hook, matcher `permission_prompt|idle_prompt|agent_needs_input|agent_completed`, `async: true`, calls `termux-notification` via the existing `notify()`-style helper.

### C. Long-task-finished notification
- `UserPromptSubmit` writes a timestamp to a session-scoped temp file (keyed by `session_id`).
- `Stop` reads it back, diffs elapsed time, only notifies if over a threshold (e.g. 60s).
- No dependency on any (unverified) loop-guard field — hook never blocks, always exits 0.

### D. Termux-friendly keybindings profile
- Ship an opt-in `keybindings.json.template`, merged like `CLAUDE.md.template` (upsert-by-marker), adding single-key fallbacks for the chord-only actions in finding #1 above, plus a README note about the tmux `ctrl+b` conflict and the ALT=Meta equivalence.
- Opt-in (asked during `install.sh`, not auto-applied) since it changes personal editing behavior rather than fixing a broken execution path.

### E. Rollout stance
Both the notification/wake-lock hooks (B, C) and the keybindings profile (D) should be **opt-in** via an `install.sh` prompt, not silently wired into every install by default — unlike the `doctor.sh` `SessionStart` hook, these change day-to-day interactive behavior rather than fixing the core execution problem this repo exists to solve.
