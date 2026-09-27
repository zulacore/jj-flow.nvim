local M = {}

---@class jj-flow.Config
---@field pi_timeout_ms integer How long to wait for Pi's description before aborting.
---@field confirm_abandon boolean Ask for confirmation before `:JAbandon`.
---@field max_diff_chars integer Cap on the diff sent to Pi (grounding payload).
---@field review_explorer_width integer Width of the review file list.
---@field review_compact boolean Start :JReview with unchanged regions folded.
---@field review_context_lines integer Context lines kept around each hunk in compact mode.

M.defaults = {
  pi_timeout_ms = 60000,
  confirm_abandon = true,
  max_diff_chars = 120000,
  review_explorer_width = 32,
  review_compact = false,
  review_context_lines = 3,
}

local config = vim.deepcopy(M.defaults)

---@param opts? jj-flow.Config
function M.setup(opts) config = vim.tbl_deep_extend('force', config, opts or {}) end

---@return jj-flow.Config
function M.get() return config end

return M
