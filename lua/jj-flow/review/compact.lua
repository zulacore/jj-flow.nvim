-- Compact mode: fold unchanged regions, keeping hunks plus a little context.
--
-- Folds are driven by `foldmethod=expr` and a per-window set of visible lines
-- computed from the current diff. Nothing here is jj- or Git-specific; it only
-- reads `session.diff`.

local M = {}

-- window id -> { [lnum] = true } for the lines that stay visible.
local visible_by_win = {}

---`foldexpr` entry point. Referenced from the window option as
---`v:lua.require'jj-flow.review.compact'.foldexpr()`.
---@return string
function M.foldexpr()
  local visible = visible_by_win[vim.api.nvim_get_current_win()]
  if not visible then return '0' end
  return visible[vim.v.lnum] and '0' or '1'
end

---@param diff jj-flow.ReviewDiff
---@param side 'a'|'b'
---@param line_count integer
---@param context integer
---@return table<integer, boolean>
local function compute_visible(diff, side, line_count, context)
  local visible = {}
  local function reveal(from, to)
    for line = math.max(1, from), math.min(line_count, to) do
      visible[line] = true
    end
  end

  for _, hunk in ipairs(diff.hunks) do
    local start = side == 'a' and hunk.a_start or hunk.b_start
    local count = side == 'a' and hunk.a_count or hunk.b_count
    if count <= 0 then
      reveal(start - context, start + context)
    else
      reveal(start - context, start + count - 1 + context)
    end
  end
  return visible
end

---@param session jj-flow.ReviewSession
local function apply(session)
  local diff = session.diff
  if not diff or #diff.hunks == 0 then
    M.disable(session)
    return
  end

  local panes = {
    { win = session.original_win, buf = session.original_buf, side = 'a' },
    { win = session.modified_win, buf = session.modified_buf, side = 'b' },
  }
  for _, pane in ipairs(panes) do
    if vim.api.nvim_win_is_valid(pane.win) and vim.api.nvim_buf_is_valid(pane.buf) then
      visible_by_win[pane.win] = compute_visible(diff, pane.side, vim.api.nvim_buf_line_count(pane.buf), session.context_lines)
      vim.wo[pane.win].foldmethod = 'expr'
      vim.wo[pane.win].foldexpr = "v:lua.require'jj-flow.review.compact'.foldexpr()"
      vim.wo[pane.win].foldenable = true
      vim.wo[pane.win].foldlevel = 0
      vim.wo[pane.win].foldminlines = 1
    end
  end
end

---@param session jj-flow.ReviewSession
function M.disable(session)
  for _, win in ipairs { session.original_win, session.modified_win } do
    if vim.api.nvim_win_is_valid(win) then
      visible_by_win[win] = nil
      vim.wo[win].foldmethod = 'manual'
      vim.wo[win].foldexpr = '0'
      vim.wo[win].foldenable = false
      vim.wo[win].foldlevel = 0
      vim.wo[win].foldminlines = 1
      pcall(vim.api.nvim_win_call, win, function() vim.cmd 'silent! normal! zE' end)
    end
  end
end

---Re-apply folds for the current diff according to the session preference.
---@param session jj-flow.ReviewSession
function M.refresh(session)
  if session.compact then
    apply(session)
  else
    M.disable(session)
  end
end

---@param session jj-flow.ReviewSession
function M.toggle(session)
  session.compact = not session.compact
  M.refresh(session)
  vim.notify('[jj-flow] compact ' .. (session.compact and 'on' or 'off'))
end

return M
