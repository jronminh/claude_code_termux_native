# Keybindings — research notes behind `keybindings.json.template`

The *what* (which keys are rebound and to what) is documented in
`README.md`'s "Termux-friendly keybindings" bullet. This file is the
*why* — JSON has no comment syntax to hang that reasoning off of inside
`keybindings.json.template` itself, so it lives here instead. Full action
reference: the `keybindings-help` skill (built into Claude Code, not part
of this repo) — invoke it directly for the complete context/action table
rather than expecting this file to reproduce all of it.

## Corrections to assumptions that turned out wrong

- `chat:newline`'s default is **`ctrl+j`**, not Shift+Enter/Option+Enter
  — "the soft keyboard can't send Shift+Enter" was never actually a
  problem for this specific binding.
- Termux's default extra-keys row already surfaces ESC/TAB/CTRL/ALT as
  single taps, so `escape`-bound actions (`chat:cancel`,
  `autocomplete:dismiss`, `help:dismiss`, ...) were never actually painful
  on a touchscreen — no rebind needed for those.
- Docs state `alt`/`opt`/`option` and `meta`/`cmd`/`command` are
  "identical in terminals" — so bindings written as `meta+p`/`meta+o`/
  `meta+t`/`meta+w`/`cmd+k` are all reachable via Termux's plain **ALT**
  extra-key, despite the "cmd" naming suggesting a Mac-only key. A
  documentation-clarity gap, not a real defect — don't assume a `cmd+`/
  `meta+` binding is unreachable on Termux before checking this.
- `ctrl+c`, `ctrl+d`, `ctrl+m`, `ctrl+[`, `ctrl+i`, `ctrl+h` are
  hardcoded/non-rebindable in Claude Code itself. The "Ctrl needs a
  toggle-tap first" friction on Termux's extra-keys row is inherent to
  every terminal app there, not something fixable from this repo.

## Real friction this repo's rebinds actually address

1. **Two-stage `ctrl+x <key>` chords with no single-key fallback** were
   the worst touchscreen UX in the whole default binding table:
   `chat:killAgents` (`ctrl+x ctrl+k`), `abovePrompt:toggle`
   (`ctrl+x ctrl+a`), `abovePrompt:focus` (`ctrl+x tab`),
   `pane:grow`/`pane:shrink` (`ctrl+x left/right/up/down`),
   `app:cycleDiffBase` (`ctrl+x b`). Chaining two Ctrl-toggle chords
   inside Claude Code's 1-second chord timeout, on a touchscreen extra-
   keys row, is genuinely hard to land reliably. (By contrast,
   `task:background` and `chat:externalEditor` already ship a plain
   single-chord fallback alongside their `ctrl+x ...` form in Claude Code
   itself — those needed no rebind.)
2. **`task:background`'s plain `ctrl+b` fallback conflicts with tmux's
   default prefix key** — directly relevant here because Termux users
   commonly run `tmux` for split panes/multiple sessions (Termux itself
   has no native tabs), so `ctrl+b` was already spoken for on a
   meaningful fraction of setups this repo targets.
3. **`ctrl+s` risks being read as terminal XOFF flow control**, freezing
   output until `ctrl+q` — a real (if rare) footgun worth designing
   around rather than leaving as the default for `chat:stash`.

These three are exactly what `keybindings.json.template`'s `alt+key`
alternatives (and the `ctrl+x ctrl+s` replacement for plain `ctrl+s`)
were chosen to fix — see the template file itself for the current
bindings, and README for the up-to-date list of what maps to what.
