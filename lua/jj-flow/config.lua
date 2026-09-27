local M = {}

---@class jj-flow.Config
---@field pi_timeout_ms integer How long to wait for Pi's description before aborting.
---@field review_backend "auto"|"jj.nvim"|"codediff" Which review backend to use.
---@field confirm_abandon boolean Ask for confirmation before `:JAbandon`.
---@field max_diff_chars integer Cap on the diff sent to Pi (grounding payload).

M.defaults = {
  pi_timeout_ms = 60000,
  review_backend = 'auto',
  confirm_abandon = true,
  max_diff_chars = 120000,
}

local config = vim.deepcopy(M.defaults)

---@param opts? jj-flow.Config
function M.setup(opts) config = vim.tbl_deep_extend('force', config, opts or {}) end

---@return jj-flow.Config
function M.get() return config end

return M
