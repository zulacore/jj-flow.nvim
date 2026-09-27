-- Side-by-side renderer for the review tab.
--
-- Owns the two diff panes: buffer contents, Tree-sitter, line/character
-- highlights, alignment fillers, scroll binding and hunk navigation. It reads
-- only the review model (`get_original`/`get_modified`) and the diff model; it
-- never runs jj.

local M = {}

local highlights = require 'jj-flow.review.highlights'
local diff_module = require 'jj-flow.review.diff'
local compact = require 'jj-flow.review.compact'
local comments = require 'jj-flow.review.comments'

local ns_highlight = highlights.ns_highlight
local ns_filler = highlights.ns_filler

---Fill a pane with generated (read-only) content and start syntax highlighting.
---The filetype is never set, so LSPs do not attach to a scratch buffer; only
---Tree-sitter (or the syntax file as a fallback) is enabled.
---@param buf integer
---@param lines string[]
---@param path string
local function set_content(buf, lines, path)
  local value = #lines > 0 and lines or { '' }

  vim.bo[buf].modifiable = true
  vim.bo[buf].readonly = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, value)
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true

  pcall(vim.treesitter.stop, buf)
  vim.bo[buf].syntax = ''

  local filetype = vim.filetype.match { filename = path, buf = buf }
  if not filetype then return end
  local lang = vim.treesitter.language.get_lang(filetype) or filetype
  if not pcall(vim.treesitter.start, buf, lang) then pcall(function() vim.bo[buf].syntax = filetype end) end
end

---@param buf integer
---@param first integer 1-based first line.
---@param count integer
---@param group string
local function line_highlight(buf, first, count, group)
  if count <= 0 then return end
  vim.api.nvim_buf_set_extmark(buf, ns_highlight, first - 1, 0, {
    end_row = first - 1 + count,
    end_col = 0,
    hl_group = group,
    hl_eol = true,
    priority = 100,
  })
end

---@param buf integer
---@param line integer 1-based.
---@param start_col integer|nil 0-based, inclusive.
---@param end_col integer|nil 0-based, exclusive.
---@param group string
local function char_highlight(buf, line, start_col, end_col, group)
  if not start_col or not end_col or end_col <= start_col then return end
  pcall(vim.api.nvim_buf_set_extmark, buf, ns_highlight, line - 1, start_col, {
    end_col = end_col,
    hl_group = group,
    priority = 200,
  })
end

---Place `count` filler rows after line `after` (1-based). `after <= 0` means
---above the first line.
---@param buf integer
---@param after integer
---@param count integer
local function place_filler(buf, after, count)
  if count <= 0 or not vim.api.nvim_buf_is_valid(buf) then return end
  local virt_lines = {}
  for i = 1, count do
    virt_lines[i] = { { '~', 'JjFlowFiller' } }
  end

  local row = after - 1
  local above = false
  if row < 0 then
    row = 0
    above = true
  end
  vim.api.nvim_buf_set_extmark(buf, ns_filler, row, 0, {
    virt_lines = virt_lines,
    virt_lines_above = above,
  })
end

---Apply line/character highlights and alignment fillers for a computed diff.
---@param session jj-flow.ReviewSession
---@param diff jj-flow.ReviewDiff
function M.apply_highlights(session, diff)
  local original, modified = session.original_buf, session.modified_buf
  vim.api.nvim_buf_clear_namespace(original, ns_highlight, 0, -1)
  vim.api.nvim_buf_clear_namespace(modified, ns_highlight, 0, -1)
  vim.api.nvim_buf_clear_namespace(original, ns_filler, 0, -1)
  vim.api.nvim_buf_clear_namespace(modified, ns_filler, 0, -1)

  for _, hunk in ipairs(diff.hunks) do
    if hunk.a_count > 0 then line_highlight(original, hunk.a_start, hunk.a_count, 'JjFlowLineDelete') end
    if hunk.b_count > 0 then line_highlight(modified, hunk.b_start, hunk.b_count, 'JjFlowLineInsert') end

    for _, pair in ipairs(hunk.pairs) do
      for _, change in ipairs(pair.changes) do
        char_highlight(original, pair.a_line, change.a_start, change.a_end, 'JjFlowCharDelete')
        char_highlight(modified, pair.b_line, change.b_start, change.b_end, 'JjFlowCharInsert')
      end
    end
  end

  for _, filler in ipairs(diff.a_fillers) do
    place_filler(original, filler.after, filler.count)
  end
  for _, filler in ipairs(diff.b_fillers) do
    place_filler(modified, filler.after, filler.count)
  end
end

---@param buf integer
---@param line integer
---@return integer
local function clamp(buf, line) return math.max(1, math.min(line, vim.api.nvim_buf_line_count(buf))) end

---Position the cursors on the requested hunk and establish native scrollbind.
---@param session jj-flow.ReviewSession
---@param diff jj-flow.ReviewDiff
function M.setup_view(session, diff)
  local original_win, modified_win = session.original_win, session.modified_win
  if not (vim.api.nvim_win_is_valid(original_win) and vim.api.nvim_win_is_valid(modified_win)) then return end

  vim.wo[original_win].scrollbind = false
  vim.wo[modified_win].scrollbind = false

  local landing = session.landing or 'first'
  session.landing = nil

  local hunk = diff.hunks[1]
  if landing == 'last' and #diff.hunks > 0 then hunk = diff.hunks[#diff.hunks] end
  local a_line = hunk and hunk.a_start or 1
  local b_line = hunk and hunk.b_start or 1

  vim.api.nvim_win_set_cursor(original_win, { clamp(session.original_buf, a_line), 0 })
  vim.api.nvim_win_set_cursor(modified_win, { clamp(session.modified_buf, b_line), 0 })

  vim.wo[original_win].scrollbind = true
  vim.wo[modified_win].scrollbind = true
  vim.api.nvim_win_call(modified_win, function()
    vim.cmd 'silent! syncbind'
    vim.cmd 'normal! zz'
  end)
end

---Render one file into the two panes.
---@param session jj-flow.ReviewSession
---@param path string
function M.render_file(session, path)
  local a_lines = session.model.get_original(path) or { '' }
  local b_lines = session.model.get_modified(path) or { '' }

  set_content(session.original_buf, a_lines, path)
  set_content(session.modified_buf, b_lines, path)

  local diff = diff_module.compute(a_lines, b_lines)
  session.diff = diff

  M.apply_highlights(session, diff)
  comments.render(session)
  compact.refresh(session)
  M.setup_view(session, diff)
end

---Move to the next (`dir > 0`) or previous (`dir < 0`) hunk. At the edge of the
---file, hop to the adjacent file.
---@param session jj-flow.ReviewSession
---@param dir integer
function M.next_hunk(session, dir)
  local diff = session.diff
  if not diff or #diff.hunks == 0 then
    session.landing = dir > 0 and 'first' or 'last'
    session.select(session.index + dir)
    return
  end

  local original_win, modified_win = session.original_win, session.modified_win
  local win = vim.api.nvim_get_current_win()
  if win ~= original_win and win ~= modified_win then
    win = modified_win
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_set_current_win(win) end
  end
  if not vim.api.nvim_win_is_valid(win) then return end

  local side = (vim.api.nvim_get_current_buf() == session.original_buf) and 'a' or 'b'
  local cursor = vim.api.nvim_win_get_cursor(win)[1]
  local target

  if dir > 0 then
    for _, hunk in ipairs(diff.hunks) do
      local line = side == 'a' and hunk.a_start or hunk.b_start
      if line > cursor then
        target = line
        break
      end
    end
  else
    for i = #diff.hunks, 1, -1 do
      local hunk = diff.hunks[i]
      local line = side == 'a' and hunk.a_start or hunk.b_start
      if line < cursor then
        target = line
        break
      end
    end
  end

  if not target then
    session.landing = dir > 0 and 'first' or 'last'
    session.select(session.index + dir)
    return
  end

  vim.api.nvim_win_set_cursor(win, { target, 0 })
  vim.api.nvim_win_call(win, function() vim.cmd 'normal! zz' end)
end

return M
