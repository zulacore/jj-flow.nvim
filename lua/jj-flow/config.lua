local M = {}

---@class jj-flow.ReviewKeymaps
---@field add string|false Add a comment at the cursor / visual selection.
---@field add_file string|false Add a comment on the whole file.
---@field edit string|false Edit the comment under the cursor.
---@field open string|false Open/edit the comment under the cursor (or open the file in the explorer).
---@field close string|false Close the review.
---@field delete string|false Delete the comment under the cursor.
---@field list string|false List every comment of the session.
---@field next string|false Next comment.
---@field prev string|false Previous comment.
---@field next_pane string|false Focus the next review pane.
---@field prev_pane string|false Focus the previous review pane.
---@field compact string|false Toggle compact mode.
---@field comment_submit string|false Save the comment input.
---@field comment_cancel string|false Cancel the comment input.
---@field comment_cycle string|false Cycle the comment type.

---@class jj-flow.Config
---@field pi_timeout_ms integer How long to wait for Pi's description before aborting.
---@field confirm_abandon boolean Ask for confirmation before `:JAbandon`.
---@field max_diff_chars integer Cap on the diff sent to Pi (grounding payload).
---@field review_explorer_width integer Width of the review file list.
---@field review_compact boolean Start :JReview with unchanged regions folded.
---@field review_context_lines integer Context lines kept around each hunk in compact mode.
---@field review_comment_width integer Width of the comment input float.
---@field review_comment_height integer Height of the comment input float.
---@field review_isolate_keymaps boolean Neutralize non-jj-flow global keymaps in the review buffers.
---@field review_keymaps jj-flow.ReviewKeymaps Buffer-local review keymaps.

M.defaults = {
  pi_timeout_ms = 60000,
  confirm_abandon = true,
  max_diff_chars = 120000,
  review_explorer_width = 32,
  review_compact = false,
  review_context_lines = 3,
  review_comment_width = 60,
  review_comment_height = 8,
  review_isolate_keymaps = true,
  review_keymaps = {
    add = 'gc',
    add_file = 'gf',
    edit = 'ge',
    open = '<CR>',
    close = 'q',
    delete = 'gd',
    list = 'gl',
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

local config = vim.deepcopy(M.defaults)

---@param opts? jj-flow.Config
function M.setup(opts) config = vim.tbl_deep_extend('force', config, opts or {}) end

---@return jj-flow.Config
function M.get() return config end

return M
