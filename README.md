# jj-flow.nvim

A small manual review workflow for Jujutsu (`jj`) + Pi.

The idea is to control checkpoints by hand:

```
:JNew
   ↓
Pi works on the current change @
   ↓
:JReview
   ↓
the review tab shows exactly @
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

`:JReview` no longer depends on `codediff.nvim`. It is a small, self-contained,
Jujutsu-native review tab. It does not need a colocated Git repository and never
reads the Git index.

---

## Commands

| Command | What it does |
|---|---|
| `:JReview` | Opens a side-by-side review tab with the exact diff of change `@`. |
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
- [pi-nvim](https://github.com/zulacore/pi-nvim) on the Neovim side, with its
  RPC extension loaded in the running Pi session (`llm.complete`).

No Git and no diff plugin: the review UI is built into `jj-flow`.

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

## The review tab

`:JReview` opens a dedicated tab:

```
┌──────────────────────┬─────────────────────┬─────────────────────┐
│ Changes              │ @-                  │ @                   │
│                      │                     │                     │
│ M init.lua           │ old code            │ new code            │
│ M review.lua    ←    │                     │                     │
│ A session.lua        │      diff           │      diff           │
│ D jj.lua             │                     │                     │
│                      │                     │                     │
└──────────────────────┴─────────────────────┴─────────────────────┘
```

What it does:

- dedicated review tab with an explorer of the files changed in `@`;
- the first file is selected automatically;
- side-by-side diff of `@-` (left) and `@` (right);
- virtual, read-only buffers with Tree-sitter (or `syntax`) highlighting;
- line-level and character-level change highlighting;
- aligned panes: filler rows are inserted on the shorter side of each hunk and
  the panes are bound with native `scrollbind`;
- hunk and file navigation;
- `gc` folds the unchanged regions (compact mode);
- `q` closes the whole session cleanly.

### Keymaps

| Key | Action |
|---|---|
| `q` | Close the review tab and release its buffers. |
| `]c` / `[c` | Next / previous hunk (crosses into the next/previous file at the edges). |
| `]f` / `[f` | Next / previous file. |
| `gc` | Toggle compact mode (fold unchanged regions). |
| `j` / `k` (explorer) | Move the selection and open the file. |
| `<CR>` / `l` (explorer) | Open the selected file. |

### How the diff is rendered

The renderer only sees a review model:

```lua
review.open({
  files = files,             -- { { path, status } }
  get_original = function(path) ... end,  -- lines in @-
  get_modified = function(path) ... end,  -- lines in @
})
```

It never runs `jj`. The Jujutsu backend (`review.backend`) is the only module
that talks to the CLI, so the UI can be pointed at any source that can produce
that model.

Line-level differences come from Neovim's own `vim.diff` (histogram).
Character-level highlighting is computed per paired line by diffing the two
lines split into characters. Alignment fillers keep corresponding lines on the
same screen row under `scrollbind`.

This is intentionally not the VS Code C/FFI engine that CodeDiff uses. The
practical difference is inside large, multi-line replacement blocks: without the
engine's `inner_changes`, lines are paired positionally within a hunk. For
normal source changes the result is visually equivalent; for large rewrites of
many consecutive lines the intra-hunk pairing can be less precise. The rest of
the experience (side-by-side, char highlights, alignment, folds, navigation)
is preserved. See [ATTRIBUTION.md](ATTRIBUTION.md).

---

## Configuration

```lua
require('jj-flow').setup {
  pi_timeout_ms = 60000,        -- how long to wait for Pi's description
  confirm_abandon = true,       -- confirm before :JAbandon
  max_diff_chars = 120000,      -- cap on the diff sent to Pi

  review_explorer_width = 32,   -- width of the review file list
  review_compact = false,       -- start the review with folds enabled
  review_context_lines = 3,     -- context kept around hunks in compact mode
}
```

---

## Health

```vim
:checkhealth jj-flow
```

Checks `jj`, the current repository, that the change of `@` can be read, and the
`pi-nvim` RPC contract (protocol + `llm.complete`).

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

### The `:JReview` data flow

```
Jujutsu backend (review.backend)
    │  jj diff -r @ --summary      -> file list + A/M/D
    │  jj file show -r @- -- PATH  -> original content
    │  jj file show -r @  -- PATH  -> modified content
    ▼
review model { files, get_original, get_modified }
    ▼
review UI / renderer (review, review.render, review.explorer, review.diff, ...)
```

The renderer is independent of Jujutsu. `:JReview` compares `@` against `@-`
exactly, which is what `jj diff -r @` shows. When `@-` is the root commit,
`jj file show -r @-` simply reports no such path, so a first change is shown
correctly as newly added files.

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

### What happens if Pi fails

Timeout, broken socket, model error, or empty description → **neither
`jj describe` nor `jj new` runs**. The repository stays untouched and a clear
error is shown. The repository is only modified after a valid description.

---

## Files

```
jj-flow.nvim/
└── lua/jj-flow/
    ├── init.lua              setup, commands, the :JNew / :JAbandon flow
    ├── config.lua            configuration
    ├── jj.lua                minimal jj CLI wrapper
    ├── review.lua            :JReview session, layout and teardown
    ├── review/
    │   ├── backend.lua       Jujutsu-native review model (the only jj caller)
    │   ├── diff.lua          line/char diff + alignment model
    │   ├── render.lua        side-by-side rendering, highlights, scrollbind
    │   ├── explorer.lua      file list
    │   ├── compact.lua       folding of unchanged regions
    │   └── highlights.lua    highlight groups
    └── pi.lua                pi-nvim wrapper (system prompt + llm.complete)
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
- Reports renames as an add plus a delete (that is what `jj diff --summary`
  reports).
- Compact mode folds each pane independently; opening a fold on one side does
  not mirror it to the other.
