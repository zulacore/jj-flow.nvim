# jj-flow.nvim

A small manual review workflow for Jujutsu (`jj`) + CodeDiff + Pi.

The idea is to control checkpoints by hand:

```
:JNew
   ↓
Pi works on the current change @
   ↓
:JReview
   ↓
CodeDiff shows exactly @
   ↓
┌─────────────────┬─────────────────┐
│ I like it       │ I don't like it │
│                 │                 │
:JNew            Pi keeps working
                  on the same @
```

And if you want to throw the current work away:

```
:JAbandon
```

Pi does **not** run `jj new`, `jj abandon`, `jj squash`, or `jj rebase`. It only
produces text when `:JNew` asks for it.

---

## Commands

| Command | What it does |
|---|---|
| `:JReview` | Opens CodeDiff with the exact diff of change `@`. |
| `:JNew` | If `@` is empty, does nothing. If it already has a description, just runs `jj new`. If it has content and no description, asks Pi for a description, runs `jj describe -r <change_id> -m "..."`, then `jj new <change_id>`. The `change_id` of `@` is captured before calling Pi, so a concurrent external `jj new` cannot make the description land on a different change. |
| `:JNew!` | Escape hatch: plain `jj new`, no Pi involved. |
| `:JAbandon` | `jj abandon @`. Discards only the current change; parents and already-accepted changes are left intact. Asks for confirmation (configurable). |

An empty `@` **never** creates another empty change.
An existing description is **never** modified.
While Pi is working, `:JNew` remains pinned to the `change_id` captured at the
start. If `@` moves externally in the meantime, `:JNew` aborts and leaves the
repository untouched (no description, no new change).

---

## Installation

Dependencies:

- `jj` on `PATH`.
- [codediff.nvim](https://github.com/esmuellert/codediff.nvim) (`:CodeDiff`).
- [pi-nvim](https://github.com/zulacore/pi-nvim) on the Neovim side, with its
  RPC extension loaded in the running Pi session (`llm.complete`).
- Optional: [jj.nvim](https://github.com/NicolasGB/jj.nvim). If present,
  `:JReview` reuses its CodeDiff backend.

The repository must be a **colocated** jj repository (with a `.git` directory):
`:JReview` renders through CodeDiff, which is Git-based.

### Neovim

```lua
vim.pack.add {
  { name = 'pi-nvim', src = 'https://github.com/zulacore/pi-nvim' },
  { name = 'jj-flow.nvim', src = 'https://github.com/<your-user>/jj-flow.nvim' },
}
require('pi-nvim').setup()
require('jj-flow').setup()
```

For local development:

```lua
vim.opt.runtimepath:prepend('/path/to/pi-nvim')
vim.opt.runtimepath:prepend('/path/to/jj-flow.nvim')
require('pi-nvim').setup()
require('jj-flow').setup()
```

### Pi

`jj-flow` has no Pi extension of its own. It uses `pi-nvim`'s `llm.complete`
primitive, so the running Pi session must have `pi-nvim`'s extension loaded.
See pi-nvim's README for how to install it.

If the RPC primitive is not available, `:JNew` detects it and aborts **without
touching the repository**.

---

## Configuration

```lua
require('jj-flow').setup {
  pi_timeout_ms = 60000,      -- how long to wait for Pi's description
  review_backend = 'auto',    -- 'auto' | 'jj.nvim' | 'codediff'
  confirm_abandon = true,     -- confirm before :JAbandon
  max_diff_chars = 120000,    -- cap on the diff sent to Pi
}
```

---

## Health

```vim
:checkhealth jj-flow
```

Checks `jj`, the current repository (and that it is colocated), CodeDiff,
`jj.nvim` (optional), and the `pi-nvim` RPC contract (protocol + `llm.complete`).

---

## Architecture

jj-flow is a thin workflow layer. It does not talk to the model itself and has
no Pi extension; it composes `pi-nvim`'s infrastructure primitives.

```
Neovim (jj-flow)                          Pi (pi-nvim extension)
  :JNew
    │  capture change_id of @
    │  jj diff -r <change_id> --git
    │  pi-nvim.complete({ systemPrompt, messages })  ──►  llm.complete
    │                                                     (isolated, no tools)
    │  ◄─────────────────────────────────────────────  { text, model }
    │  verify @ is still <change_id> (abort if not)
    ▼
  jj describe -r <change_id> -m "<text>" ; jj new <change_id>
```

- `pi-nvim` owns the socket, session discovery, and the RPC protocol.
- jj-flow owns the business rule: what to ask and how to turn the answer into a
  `jj describe`.
- The completion runs in the same Pi process, with the same model and
  credentials, no tools, and isolated from the conversation transcript. The diff
  is the source of truth.

### The `:JNew` description flow

```
:JNew
  → jj log -T change_id    capture the change_id of @
  → jj log -T empty        is @ empty?
       yes → notify and stop (no empty changes created)
       no  → jj log -T description
              has a description?
                yes → jj new <change_id>
                no  → jj diff -r <change_id> --git   (source of truth)
                     → pi-nvim.complete({ systemPrompt, messages })
                     → pi-nvim llm.complete (isolated, no tools)
                     → { text }
                     → verify @ is still <change_id> (abort if not)
                     → jj describe -r <change_id> -m "<text>"
                     → jj new <change_id>
```

The real diff (`jj diff -r <change_id> --git`) travels in the payload. The
change id is captured before the model call and re-checked before writing, so
the description is grounded on the diff of the change it will actually be
applied to, not on a `@` that may have moved.

### How the diff of `@` is obtained

- `:JNew` uses `jj diff -r <change_id> --git` and sends it to Pi, where
  `<change_id>` is captured once at the start of the command. All later `jj`
  writes target that same change, never the moving `@` symbol.
- `:JReview` **never** compares the working tree against Git HEAD. It compares
  the working tree against `@-` (the parent of the current change), which is
  exactly `@`:
  - with `jj.nvim`: `require('jj.diff').open('revision', { rev='@', backend='codediff' })`;
  - without `jj.nvim`: `:CodeDiff <commit_id of @->`.

When `@-` is the root commit (the very first change), Git has no object for it
(jj reports it as all zeroes). In that case jj-flow diffs against Git's empty
tree, so the first change is shown correctly as newly added files.

### What happens if Pi fails

Timeout, broken socket, model error, or empty description → **neither
`jj describe` nor `jj new` runs**. The repository stays untouched and a clear
error is shown. The repository is only modified after a valid description.

---

## Files

```
jj-flow.nvim/
└── lua/jj-flow/
    ├── init.lua       setup, commands, the :JNew / :JAbandon flow
    ├── config.lua     configuration
    ├── jj.lua         minimal jj CLI wrapper
    ├── review.lua     :JReview (jj.nvim or direct CodeDiff)
    └── pi.lua         pi-nvim wrapper (system prompt + llm.complete)
```

---

## Known limitations

- The description is generated in an isolated model call (same process, same
  model, diff as the source of truth). It deliberately does not reuse the
  conversation history.
- Session selection is `pi-nvim`'s (`:PiSessions`); jj-flow uses the session for
  the current directory.
- If Pi is mid-turn, the request is still served immediately; the timeout guards
  against any hang.
- `:JNew` does not retry: if it fails, run it again by hand.
