# jj-flow.nvim

A small manual review workflow for Jujutsu (`jj`) + Pi.

The idea is to control checkpoints by hand:

```
trabajo sobre @
   ↓
:JReview
   ↓
reviso el diff y acumulo comentarios
(issue / suggestion / note, en línea o rango)
   ↓
:JFix
   ↓
Pi recibe TODOS los comentarios en una sola petición
   ↓
Pi modifica @
   ↓
:JReview  (la review anterior queda stale)
   ↓
si está correcto → :JNew
```

And if you want to throw the current work away:

```
:JAbandon
```

Pi does **not** run `jj new`, `jj abandon`, `jj squash`, or `jj rebase`. It only
modifies the working copy when `:JFix` sends it review feedback, and only
produces text when `:JNew` asks for a description.

During `:JReview` the diff is a snapshot: comments are anchored to the
`commit_id` captured when the review opened. `:JFix` refuses to send feedback if
`@` has moved or been rewritten since.

`:JReview` no longer depends on `codediff.nvim`. It is a small, self-contained,
Jujutsu-native review tab. It does not need a colocated Git repository and never
reads the Git index.

---

## Commands

| Command | What it does |
|---|---|
| `:JReview` | Opens a side-by-side review tab with the exact diff of change `@`. Add inline comments, then send them all to Pi with `:JFix`. |
| `:JFix` | With a review open, sends every comment to the running Pi session in one request, then closes the review. Pi edits `@`; the review is intentionally not kept. |
| `:JNextDiff` / `:JPrevDiff` | Jump to the next / previous difference in the open review. |
| `:JNextComment` / `:JPrevComment` | Jump to the next / previous review comment. |
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
  RPC extension loaded in the running Pi session. Description (`:JNew`) uses
  `llm.complete`; review fixes (`:JFix`) use the interactive prompt channel.

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

`jj-flow` has no Pi extension of its own. `:JNew` uses `pi-nvim`'s
`llm.complete` primitive (isolated, no tools) to describe a change, and `:JFix`
sends one prompt to the interactive session so Pi can edit the working copy. The
running Pi session must have `pi-nvim`'s extension loaded. See pi-nvim's README
for how to install it.

If the RPC primitive is not available, `:JNew` detects it and aborts **without
touching the repository**; `:JFix` refuses to send and leaves the review open.

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
- inline review comments: sign, line/range highlight and a virtual-line box,
  kept aligned across both panes;
- hunk, file and comment navigation;
- `gC` folds the unchanged regions (compact mode);
- the review buffers are restricted to the keys below, `<Esc>`, `j`/`k`/arrows
  and `v`/`V` (needed for range selection); any other builtin or plugin key is
  a no-op. The comment input keeps normal typing;
- `q` closes the whole session cleanly.

### Keymaps

Every review key is buffer-local to the review tab: jj-flow defines no global
mapping, so nothing leaks into your normal files. All of them live in
`review_keymaps` and can be changed, or disabled with `false`, from `setup()`.

Defaults:

| Config key | Default | Action |
|---|---|---|
| `next_pane` | `<Tab>` | Focus the next pane (explorer → `@-` → `@`, wrapping). |
| `prev_pane` | `<S-Tab>` | Focus the previous pane. |
| `next_file` | `]f` | Next file. |
| `prev_file` | `[f` | Previous file. |
| `next_diff` | `]c` | Next hunk / difference (crosses files at the edges). |
| `prev_diff` | `[c` | Previous hunk / difference. |
| `add` | `gc` | Add a line comment (normal) or a range comment (visual). |
| `add_file` | `gf` | Add a comment on the whole file. |
| `edit` | `ge` | Edit the comment under the cursor. |
| `open` | `<CR>` | Edit the comment under the cursor; in the explorer, open the selected file and focus `@`. |
| `delete` | `gd` | Delete the comment under the cursor. |
| `list` | `gl` | List every comment and jump to one. |
| `next` | `]n` | Next comment (crosses files, wraps). |
| `prev` | `[n` | Previous comment. |
| `compact` | `gC` | Toggle compact mode (fold unchanged regions). |
| `close` | `q` | Close the review. |
| `exit` | `<Esc>` | Close the review. |
| `fix` | `<leader>f` | Send the whole review to Pi (`:JFix`) and close it. |
| `comment_cycle` | `<Tab>` | Cycle the comment type in the input float. |
| `comment_submit` | `<C-s>` | Save the comment. |
| `comment_cancel` | `<Esc>` | Cancel the comment. |

A few keys are deliberately not configurable, because the strict key isolation
needs them:

- `j`, `k`, `<Up>`, `<Down>` move within the focused pane;
- `v`/`V` start a visual selection (needed for `gc` range comments);
- `:` opens the command line, so `:JFix`, `:JNextDiff`, ... stay usable.

Everything else, builtin or plugin, is a no-op inside the review buffers (see
`review_isolate_keymaps`). The comment input float is a normal buffer and keeps
your regular editing keys.

Changing or disabling keys:

```lua
require('jj-flow').setup {
  review_keymaps = {
    add = '<leader>cc', -- remap the line-comment key
    add_file = 'gF',    -- remap the file-comment key
    compact = false,    -- disable the compact toggle
    close = false,      -- `q` does nothing; use `exit` instead
  },
}
```

The `:JNextDiff`, `:JPrevDiff`, `:JNextComment` and `:JPrevComment` commands run
the same actions as `next_diff`, `prev_diff`, `next` and `prev`. Map them
globally with `vim.keymap.set` if you also want them outside the review.

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
  review_comment_width = 60,    -- width of the comment input float
  review_comment_height = 8,    -- height of the comment input float
  review_isolate_keymaps = true, -- drop the user's global keymaps in the review buffers

  -- Buffer-local keymaps used inside the review tab. The full list with its
  -- default keys and actions is in the "Keymaps" section above. Set any key
  -- to false to disable it; these are only defined in the plugin's own
  -- scratch buffers, never globally.
  review_keymaps = {
    add = 'gc',
    add_file = 'gf',
    edit = 'ge',
    open = '<CR>',
    close = 'q',
    exit = '<Esc>',
    fix = '<leader>f',
    delete = 'gd',
    list = 'gl',
    next_file = ']f',
    prev_file = '[f',
    next_diff = ']c',
    prev_diff = '[c',
    next = ']n',
    prev = '[n',
    next_pane = '<Tab>',
    prev_pane = '<S-Tab>',
    compact = 'gC',
    comment_submit = '<C-s>',
    comment_cancel = '<Esc>',
    comment_cycle = '<Tab>',
  },
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
no Pi extension; it composes `pi-nvim`'s infrastructure primitives:

- `llm.complete` (isolated, no tools) to describe a change for `:JNew`;
- `prompt` (fire-and-forget turn in the interactive session, with tools) to make
  Pi address a review for `:JFix`.

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
    │  jj log -T change_id/commit_id -> immutable snapshot ids
    │  jj file show -r @- -- PATH  -> original content
    │  jj file show -r @  -- PATH  -> modified content
    ▼
review model { files, snapshot, get_original, get_modified }
    ▼
review UI / renderer (review, review.render, review.explorer, review.diff, ...)
    ▼
comments (review.comments)  -> sign + line/range highlight + virtual-line box
```

The renderer is independent of Jujutsu. `:JReview` compares `@` against `@-`
exactly, which is what `jj diff -r @` shows. When `@-` is the root commit,
`jj file show -r @-` simply reports no such path, so a first change is shown
correctly as newly added files.

Comments are session-only. A comment stores `file`, `line`, optional
`line_end`, `side` (`base` = `@-`, `current` = `@`), `type`
(`issue`/`suggestion`/`note`) and `text`. Rendering adds a sign, a highlight and
a box of virtual lines; because virtual lines add screen rows, the opposite pane
gets the same number of blank virtual rows (keyed by the diff's display
position) so the native `scrollbind` stays aligned.

### The `:JFix` data flow

```
:JFix
  → pi-nvim.available()            is there a live session?
  → jj log -T commit_id            is @ still the reviewed snapshot?
       no  → abort (review is stale; run :JReview again)
       yes → review.feedback.build(session)
              → numbered [ISSUE]/[SUGGESTION]/[NOTE] list, each with file,
                line range, side and the quoted code it refers to
              → pi-nvim.send_raw({ type = 'prompt', message = ... })
              → close the review and discard its comments
```

The prompt is explicit about the division of labour: Pi must make the changes in
the working tree and must **not** create, abandon, squash, rebase, describe or
`jj new`. Comments written on the `base` side are still to be resolved against
the current working copy, and the instruction says so. One request is sent for
the whole review; jj-flow never calls Pi once per comment.

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
    ├── init.lua              setup, commands, the :JReview / :JFix / :JNew flow
    ├── config.lua            configuration
    ├── jj.lua                minimal jj CLI wrapper
    ├── review.lua            :JReview session, layout and teardown
    ├── review/
    │   ├── backend.lua       Jujutsu-native review model (the only jj caller)
    │   ├── diff.lua          line/char diff + alignment model
    │   ├── render.lua        side-by-side rendering, highlights, scrollbind
    │   ├── explorer.lua      file list
    │   ├── compact.lua       folding of unchanged regions
    │   ├── highlights.lua    highlight groups and comment namespaces
    │   ├── comments.lua      comment model, rendering, navigation and list UI
    │   ├── commentui.lua     floating comment input (type + text)
    │   └── feedback.lua      review comments -> prompt text for Pi
    └── pi.lua                pi-nvim wrapper (describe + fix)
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
- Review comments are **not persisted**: they live only while the review tab is
  open. `:JFix` closes the review on purpose, so re-review from scratch after Pi
  edits `@`.
- Comments are not rebased across rewrites. If `@` changes while a review is
  open, `:JFix` detects it and aborts instead of applying feedback to the wrong
  lines.
