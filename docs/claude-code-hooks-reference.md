# Claude Code hooks — verified reference

Distilled from `notes/termux-features-research.md` (development log, keeps
the messy chronological version — corrections, dead ends, and all — for
whoever wants the full methodology). This file states current best
understanding only, organized by topic instead of by session. Useful
beyond this repo: nothing here is Termux-specific, it's general Claude
Code hook behavior this project happened to need to verify carefully
because a broken hook here can break the whole install.

**Confidence markers**: ✅ confirmed (docs quote or live test, or both) ·
⚠️ plausible but not directly confirmed · ❌ checked and found false.
Re-verify against `https://code.claude.com/docs/en/hooks` before relying
on anything marked ⚠️ for something consequential.

## Event list

✅ At least 33 events exist; ones actually used by this repo's own hooks:
`SessionStart`, `SessionEnd`, `UserPromptSubmit`, `Stop`, `Notification`.

✅ Others confirmed to exist (found via `strings` against the bundled Bun
binary, cross-referenced with docs): `PreToolUse`, `PostToolUse`,
`PostToolUseFailure`, `PostToolBatch`, `UserPromptExpansion`,
`PreModelSwitch`/`PostModelSwitch`, `PermissionRequest`,
`PermissionDenied`, `CwdChanged`/`FileChanged`, `MessageDisplay`,
`Elicitation`/`ElicitationResult`, `WorktreeCreate`, `Setup`.

✅ `Notification` fires with `notification_type` one of:
`permission_prompt`, `idle_prompt`, `auth_success`, `elicitation_dialog`,
`elicitation_url_dialog`, `elicitation_complete`, `elicitation_response`,
`agent_needs_input`, `agent_completed`, `quota_auto_resume_fired`,
`quota_auto_resume_stale`, `quota_auto_resume_disabled`.

## Input (stdin) fields

✅ Common across hooks: `session_id`, `prompt_id`, `transcript_path`,
`cwd`, `scratchpad_dir`, `permission_mode`, `hook_event_name` (+
`agent_id`/`agent_type` in subagent contexts). Only `SessionStart` can
also carry `model` (not always present).

⚠️ `Stop`'s stdin JSON example includes `stop_hook_active: true` (a
loop-guard flag) — seen in a docs code block, not exhaustively tested. An
earlier pass had flagged this as fabricated based on an untrusted
subagent's report; a later direct docs fetch reproduced it in a quoted
JSON example, which is the more reliable source. Treat as likely real.

❌ A `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP` env var, and a hard documented
number for "how many consecutive Stop blocks before Claude Code stops
honoring them" — both were an untrusted subagent's invention, not in the
real docs. A cap on consecutive `Stop` blocks is separately ⚠️ plausible
(docs prose mentions one exists, without a verbatim number) — don't
depend on a specific threshold.

## Exit codes

✅ `0`: for `UserPromptSubmit`/`UserPromptExpansion`/`SessionStart`/
`PostModelSwitch` only, plain stdout text is fed back to Claude as
context. For every other event, stdout on exit 0 just goes to the debug
log — not fed to the model.

✅ `2`: blocks, meaning is event-specific — on `Stop` it "prevents Claude
from stopping, continues the conversation"; on `UserPromptSubmit` it
"blocks prompt processing and erases the prompt".

✅ Any other code: non-blocking error, the action proceeds anyway.

**Design rule this repo follows**: since there's no confirmed, generally
reliable anti-loop mechanism for a blocking `Stop` hook, none of this
repo's own hooks ever return exit code 2 — always 0, or a non-2 nonzero
code (harmless non-blocking error). Zero chance of stalling a turn.

## Matchers, timeouts, concurrency

✅ Matcher syntax: `"*"` / `""` / omitted = match all; a string of
letters/digits/`_-, |` = exact match or a `|`/`,`-separated list; anything
else = an unanchored JS regex.

✅ Timeout defaults: 600s for `command`/`http`/`mcp_tool` hooks; lowered
to 30s for `UserPromptSubmit`/`PreModelSwitch`/`PostModelSwitch`; 10s for
`MessageDisplay`. `SessionEnd` hooks share ONE 1.5s total budget across
all of them, extendable up to 60s only by setting a longer per-hook
`timeout`.

✅ All hooks matching one event run in **parallel**, not sequentially.
The same handler defined in multiple settings files runs only once.

✅ `async: true` on a `command` hook runs it in the background without
blocking the turn. `asyncRewake: true` additionally wakes Claude with the
hook's stderr/stdout as a system reminder if it later exits with code 2.

## `systemMessage` vs `additionalContext` — where each one actually goes

This was the single most expensive-to-learn fact in this repo's hook
work (see the notes file for the two rounds it took to get right).

✅ **Neither field reaches the human user's visible UI directly** for any
event tested here. Both are messages **to Claude**, delivered differently
per event:

- `PreToolUse` `systemMessage`: "A message to show Claude in the
  transcript."
- `PostToolUse` `systemMessage`: "Message shown to Claude as a system
  reminder."
- `Stop` `systemMessage`: "Message shown to Claude in the system context,
  visible in the transcript. Use this to give Claude feedback on its
  response so it can act on it in the next turn."
- `Notification` `systemMessage`(-equivalent field): "Plain text or
  Markdown message for Claude to see and act on. Claude reads this on
  every exit code except 2. Not shown in the transcript; stays private to
  Claude."

✅ **Practical rule**: to get something to the *human*, don't rely on
`systemMessage` alone. Use `hookSpecificOutput.additionalContext` and
have `CLAUDE.md` explicitly instruct the model to relay it back to the
user in its own reply. This is what every hook in this repo does (see
`doctor_hook_command`/`adb_bridge_stop_hook_command` in
`scripts/feature-hooks.sh`/`scripts/lib.sh`). Setting both fields
together is harmless redundancy, not a conflict.

## Per-event output fields (verbatim from docs, high confidence)

**`PreToolUse`** — note only two `permissionDecision` values are
documented here (`"ask"` may exist at a different layer, ⚠️ unconfirmed
as a valid hook return value):

| Field | Description |
| :---- | :---------- |
| `permissionDecision` | `"allow"` or `"deny"` — controls whether the tool call proceeds |
| `permissionDecisionReason` | Explanation shown to Claude when denied |
| `updatedInput` | Modified tool input, matched against the tool's schema; validation failure → hook reported as error, original input used. ✅ verified live: a test hook appended `; echo MARKER` via `updatedInput.command` and it actually executed |
| `additionalContext` | Sent to Claude about the tool call/result, appended whether the call proceeds or is denied |

**`PostToolUse`**:

| Field | Description |
| :---- | :---------- |
| `hookSpecificOutput.additionalContext` | Additional context to show Claude about the tool result |
| `hookSpecificOutput.updatedToolOutput` | Replaces the tool output before it reaches the model. ⚠️ live test was inconclusive (two parallel `PostToolUse` hooks on the same matcher likely caused a merge conflict) — don't trust until re-tested in isolation |
| `hookSpecificOutput.updatedMCPToolOutput` | MCP-tool variant of the above |
| `hookSpecificOutput.classifierContext` | Hint for the auto-mode permission classifier. Docs explicitly warn this is insecure to fill with untrusted tool output |
| `systemMessage` | Shown to Claude as a system reminder |
| `terminalSequence` | ANSI/OSC sequence (e.g. OSC 9/777 desktop notification) for Claude Code to emit — a real OS-level notification trigger |

**Cross-event, top-level fields**: `systemMessage`, `decision`
(`"approve"`/`"block"`, independent of `PreToolUse`'s `permissionDecision`),
`reason`, `terminalSequence`.

✅ When multiple hooks return conflicting `permissionDecision` for the
same event: priority is `{allow: 1, ask: 2, deny: 3}` — strictest wins,
not last-hook-wins.

## `settings.json` keys (confirmed to exist)

Found via a schema-validation error dump — an expensive (~70k token) way
to learn this; don't repeat that method, just trust this list or check
the current schema directly if in doubt: `autoCompactWindow` (int,
100000–1000000), `bashOutputMaxChars` (default 30000, clamps
4000–128000), `promptCacheTtl`/`subagentPromptCacheTtl` (`"5m"`/`"1h"`),
`skillListingMaxDescChars` (default 1536), `switchModelsOnFlag` (bool),
`effortLevel`/`maxEffortLevel` (`low`/`medium`/`high`/`xhigh`/`max`),
`ultracode` (bool, session-scoped), `axScreenReader`.

## A cautionary tale worth keeping in mind

A background research *subagent* asked to look up hook behavior had its
report **flagged by the harness for containing instruction-shaped content
matching "bypass-permissions"** — almost certainly a prompt injection
encountered while it browsed. That entire report was discarded and
everything above was re-verified directly against the real docs and/or
live tests instead. Treat any single unverified source (including a
research subagent's own summary) as suspect until cross-checked.
