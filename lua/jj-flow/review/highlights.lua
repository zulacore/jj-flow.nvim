-- Highlight groups and namespaces for the review UI.
--
-- Colors are derived from the active colorscheme's own Diff* groups so the
-- review follows the user's theme, then brightened for the character-level
-- highlights. `setup()` is idempotent and re-runs on `ColorScheme`.

local M = {}

M.ns_highlight = vim.api.nvim_create_namespace 'jj-flow-review-highlight'
M.ns_filler = vim.api.nvim_create_namespace 'jj-flow-review-filler'
M.ns_explorer = vim.api.nvim_create_namespace 'jj-flow-review-explorer'

---@param color number|nil
---@param factor number
---@return number|nil
local function adjust(color, factor)
  if not color then return nil end
  local r = math.floor(color / 65536) % 256
  local g = math.floor(color / 256) % 256
  local b = color % 256
  r = math.min(255, math.floor(r * factor))
  g = math.min(255, math.floor(g * factor))
  b = math.min(255, math.floor(b * factor))
  return r * 65536 + g * 256 + b
end

---Background a highlight group actually renders with.
---
---Some schemes define `DiffAdd`/`DiffDelete` with `reverse = true`; the renderer
---swaps fg and bg at draw time, so read the effective value.
---@param name string
---@param fallback number
---@return number
local function effective_bg(name, fallback)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  if not ok or not hl then return fallback end
  local bg = hl.reverse and hl.fg or hl.bg
  return bg or fallback
end

function M.setup()
  local insert_bg = effective_bg('DiffAdd', 0x1d3042)
  local delete_bg = effective_bg('DiffDelete', 0x351d2b)
  local brightness = vim.o.background == 'light' and 0.92 or 1.35

  -- Always set the diff-local groups: they are the review's own namespace and
  -- should track the colorscheme, not freeze to whatever was active first.
  vim.api.nvim_set_hl(0, 'JjFlowLineInsert', { bg = insert_bg })
  vim.api.nvim_set_hl(0, 'JjFlowLineDelete', { bg = delete_bg })
  vim.api.nvim_set_hl(0, 'JjFlowCharInsert', { bg = adjust(insert_bg, brightness) or 0x2a4556 })
  vim.api.nvim_set_hl(0, 'JjFlowCharDelete', { bg = adjust(delete_bg, brightness) or 0x4b2a3d })

  -- Fillers and cursor/selection chrome can be overridden before setup.
  vim.api.nvim_set_hl(0, 'JjFlowFiller', { fg = '#3c3c3c', default = true })
  vim.api.nvim_set_hl(0, 'JjFlowExplorerHeader', { link = 'Title', default = true })
  vim.api.nvim_set_hl(0, 'JjFlowExplorerSelected', { link = 'Visual', default = true })
  vim.api.nvim_set_hl(0, 'JjFlowStatusAdded', { link = 'DiagnosticOk', default = true })
  vim.api.nvim_set_hl(0, 'JjFlowStatusModified', { link = 'DiagnosticWarn', default = true })
  vim.api.nvim_set_hl(0, 'JjFlowStatusDeleted', { link = 'DiagnosticError', default = true })

  if not M._autocmd then
    M._autocmd = vim.api.nvim_create_augroup('jj_flow_review_highlights', { clear = true })
    vim.api.nvim_create_autocmd('ColorScheme', {
      group = M._autocmd,
      callback = function() M.setup() end,
    })
  end
end

return M
