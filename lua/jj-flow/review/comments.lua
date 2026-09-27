-- Review comments: model, session store, rendering, navigation and list UI.
--
-- Comments belong to a single :JReview session and live in `session.comments`.
-- They are never persisted and never touch jj. The fields are deliberately
-- small:
--
--   { id, file, line, line_end?, side = 'base'|'current', type, text }
--
-- `side` records the pane the comment was written on: 'base' is `@-` (the left,
-- reference pane) and 'current' is `@` (the right pane). Pi always resolves
-- feedback against the current working copy, so `feedback.lua` translates a
-- 'base' anchor into that instruction.
--
-- Rendering draws a sign, a line/range highlight and a virtual-line box. The
-- box adds screen rows, which would break the native `scrollbind` alignment of
-- the two panes; `M.render` compensates by adding the same number of blank
-- virtual rows on the opposite pane, keyed by the diff's display position.

local M = {}

local highlights = require 'jj-flow.review.highlights'
local commentui = require 'jj-flow.review.commentui'

local ns = highlights.ns_comment
local ns_pad = highlights.ns_comment_pad

local TYPES = highlights.comment_types
local TYPE_ORDER = { 'issue', 'suggestion', 'note' }

M.TYPES = TYPES
M.TYPE_ORDER = TYPE_ORDER

---@class jj-flow.ReviewComment
---@field id integer
---@field file string Repository-relative path.
---@field line integer 1-based line on `side`, or 0 for a file-level comment.
---@field line_end integer|nil Inclusive end line for a range comment.
---@field side 'base'|'current'
---@field type 'issue'|'suggestion'|'note'
---@field text string

---@param msg string
---@param level? integer
local function notify(msg, level) vim.notify('[jj-flow] ' .. msg, level or vim.log.levels.INFO) end

---@param session jj-flow.ReviewSession
---@return string|nil
local function current_file(session)
  local file = session.files and session.files[session.index]
  return file and file.path or nil
end

---The pane the cursor is in, mapped to the comment side. nil in any other
---window (explorer, floats).
---@param session jj-flow.ReviewSession
---@return 'base'|'current'|nil
local function pane_side(session)
  local buf = vim.api.nvim_get_current_buf()
  if buf == session.original_buf then return 'base' end
  if buf == session.modified_buf then return 'current' end
  return nil
end

---@param session jj-flow.ReviewSession
local function attach(session)
  session.comments = {}
  session.next_comment_id = 1
end

M.attach = attach

---Add a comment to the session.
---@param session jj-flow.ReviewSession
---@param spec { file: string, line: integer, line_end?: integer, side?: 'base'|'current', type?: string, text: string }
---@return jj-flow.ReviewComment
function M.add(session, spec)
  local line = spec.line
  local line_end = spec.line_end
  if line == 0 then
    -- File-level comment: never a range.
    line_end = nil
  elseif line_end and line_end < line then
    line, line_end = line_end, line
  end

  local id = session.next_comment_id or 1
  session.next_comment_id = id + 1

  local comment = {
    id = id,
    file = spec.file,
    line = line,
    line_end = (line_end and line_end ~= line) and line_end or nil,
    side = spec.side or 'current',
    type = TYPES[spec.type or ''] and spec.type or 'note',
    text = spec.text,
  }

  session.comments[#session.comments + 1] = comment
  return comment
end

---@param session jj-flow.ReviewSession
---@param id integer
---@return jj-flow.ReviewComment|nil
function M.get(session, id)
  for _, comment in ipairs(session.comments or {}) do
    if comment.id == id then return comment end
  end
  return nil
end

---Comments for a file, optionally filtered by side, sorted by line.
---@param session jj-flow.ReviewSession
---@param file string
---@param side? 'base'|'current'
---@return jj-flow.ReviewComment[]
function M.for_file(session, file, side)
  local out = {}
  for _, comment in ipairs(session.comments or {}) do
    if comment.file == file and (not side or comment.side == side) then out[#out + 1] = comment end
  end
  table.sort(out, function(a, b)
    if a.line ~= b.line then return a.line < b.line end
    return a.id < b.id
  end)
  return out
end

---Every comment, ordered by file position in the explorer and then by line.
---@param session jj-flow.ReviewSession
---@return jj-flow.ReviewComment[]
function M.all(session)
  local order = {}
  for index, file in ipairs(session.files or {}) do
    order[file.path] = index
  end

  local out = {}
  for _, comment in ipairs(session.comments or {}) do
    out[#out + 1] = comment
  end
  table.sort(out, function(a, b)
    local ai, bi = order[a.file] or math.huge, order[b.file] or math.huge
    if ai ~= bi then return ai < bi end
    if a.line ~= b.line then return a.line < b.line end
    return a.id < b.id
  end)
  return out
end

---@param session jj-flow.ReviewSession
---@param file string
---@return jj-flow.ReviewComment|nil
function M.file_comment(session, file)
  for _, comment in ipairs(session.comments or {}) do
    if comment.file == file and comment.line == 0 then return comment end
  end
  return nil
end

---@param session jj-flow.ReviewSession
---@return integer
function M.count(session) return #(session.comments or {}) end

---First comment whose range overlaps `[start_line, end_line]` on `side`.
---@param session jj-flow.ReviewSession
---@param file string
---@param start_line integer
---@param end_line integer
---@param side 'base'|'current'
---@return jj-flow.ReviewComment|nil
function M.overlapping(session, file, start_line, end_line, side)
  if start_line > end_line then
    start_line, end_line = end_line, start_line
  end
  for _, comment in ipairs(session.comments or {}) do
    if comment.file == file and comment.side == side then
      local c_end = comment.line_end or comment.line
      if comment.line <= end_line and c_end >= start_line then return comment end
    end
  end
  return nil
end

---@param session jj-flow.ReviewSession
---@param id integer
function M.remove(session, id)
  for i, comment in ipairs(session.comments or {}) do
    if comment.id == id then
      table.remove(session.comments, i)
      return true
    end
  end
  return false
end

---@param session jj-flow.ReviewSession
function M.clear(session)
  session.comments = {}
  session.next_comment_id = 1
end

---@param session jj-flow.ReviewSession
---@return jj-flow.ReviewComment|nil
function M.at_cursor(session)
  local side = pane_side(session)
  if not side then return nil end
  local file = current_file(session)
  if not file then return nil end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local comment = M.overlapping(session, file, line, line, side)
  if comment then return comment end
  -- A file-level comment is editable from the first line when there is no
  -- line comment there.
  if line == 1 then return M.file_comment(session, file) end
  return nil
end

-- ============================================================================
-- Add / edit / delete from the diff panes
-- ============================================================================

function M.add_at_cursor(session)
  local side = pane_side(session)
  if not side then
    notify('put the cursor on a diff pane to comment', vim.log.levels.WARN)
    return
  end
  local file = current_file(session)
  if not file then return end

  local line = vim.api.nvim_win_get_cursor(0)[1]
  if M.overlapping(session, file, line, line, side) then
    notify('there is already a comment on this line', vim.log.levels.WARN)
    return
  end

  commentui.open({ type = 'issue' }, function(ctype, text)
    M.add(session, { file = file, line = line, side = side, type = ctype, text = text })
    M.render(session)
    notify(string.format('added %s comment', ctype))
  end)
end

---Add a comment for a visual range. The caller passes the selection lines
---captured while still in visual mode; if omitted, the `'<`/`'>` marks are used.
---@param session jj-flow.ReviewSession
---@param first? integer
---@param last? integer
function M.add_for_range(session, first, last)
  local side = pane_side(session)
  if not side then
    notify('put the selection on a diff pane to comment', vim.log.levels.WARN)
    return
  end
  local file = current_file(session)
  if not file then return end

  first = first or vim.fn.line "'<"
  last = last or vim.fn.line "'>"
  if first == 0 or last == 0 then return end
  if first > last then
    first, last = last, first
  end

  if M.overlapping(session, file, first, last, side) then
    notify('there is already a comment in this range', vim.log.levels.WARN)
    return
  end

  commentui.open({ type = 'issue' }, function(ctype, text)
    M.add(session, { file = file, line = first, line_end = last, side = side, type = ctype, text = text })
    M.render(session)
    notify(string.format('added %s comment', ctype))
  end)
end

---Add a comment that applies to the whole current file. Allowed from a diff
---pane or from the explorer; from the explorer it defaults to the `current`
---side.
function M.add_file_comment(session)
  local buf = vim.api.nvim_get_current_buf()
  local side = pane_side(session) or (buf == session.explorer_buf and 'current') or nil
  if not side then
    notify('put the cursor on a reviewed file to comment on the whole file', vim.log.levels.WARN)
    return
  end
  local file = current_file(session)
  if not file then return end

  if M.file_comment(session, file) then
    notify('this file already has a comment; edit it instead', vim.log.levels.WARN)
    return
  end

  commentui.open({ type = 'issue' }, function(ctype, text)
    M.add(session, { file = file, line = 0, side = side, type = ctype, text = text })
    M.render(session)
    notify(string.format('added %s file comment', ctype))
  end)
end

function M.edit_at_cursor(session)
  local comment = M.at_cursor(session)
  if not comment then
    notify('no comment at the cursor', vim.log.levels.WARN)
    return
  end

  commentui.open({ type = comment.type, text = comment.text }, function(ctype, text)
    comment.type = ctype
    comment.text = text
    M.render(session)
    notify 'comment updated'
  end)
end

function M.delete_at_cursor(session)
  local comment = M.at_cursor(session)
  if not comment then
    notify('no comment at the cursor', vim.log.levels.WARN)
    return
  end

  vim.ui.select({ 'Delete', 'Cancel' }, { prompt = 'Delete this comment?' }, function(choice)
    if choice ~= 'Delete' then return end
    M.remove(session, comment.id)
    M.render(session)
    notify 'comment deleted'
  end)
end

-- ============================================================================
-- Rendering
-- ============================================================================

---Draw a bordered box for a comment, mirroring review.nvim's virtual-line
---presentation ([TYPE] header, content, closing border).
---@param text string
---@param type_name string
---@param hl string
---@return table[][] virt_lines
local function box(text, type_name, hl)
  local virt_lines = {}
  local text_lines = vim.split(text, '\n', { plain = true })

  local max_text_width = 0
  for _, line in ipairs(text_lines) do
    max_text_width = math.max(max_text_width, vim.fn.strdisplaywidth(line))
  end

  local header = '[' .. type_name .. ']'
  local content_width = math.max(max_text_width, 20)
  local top_dashes = math.max(1, content_width - vim.fn.strdisplaywidth(header) + 1)

  virt_lines[#virt_lines + 1] = { { '╭─' .. header .. string.rep('─', top_dashes) .. '╮', hl } }
  for _, line in ipairs(text_lines) do
    local padding = math.max(0, content_width - vim.fn.strdisplaywidth(line))
    virt_lines[#virt_lines + 1] = { { '│ ' .. line .. string.rep(' ', padding) .. ' │', hl } }
  end
  virt_lines[#virt_lines + 1] = { { '╰' .. string.rep('─', content_width + 2) .. '╯', hl } }

  return virt_lines
end

---Display index of each buffer line: how many display rows precede it once the
---diff's filler rows are taken into account. Two lines from opposite sides with
---the same index are aligned on screen.
---@param diff jj-flow.ReviewDiff|nil
---@param side 'a'|'b'
---@param line_count integer
---@return integer[]
local function display_indices(diff, side, line_count)
  local fillers = diff and (side == 'a' and diff.a_fillers or diff.b_fillers) or {}
  local extra = {}
  for _, filler in ipairs(fillers) do
    extra[filler.after] = (extra[filler.after] or 0) + filler.count
  end

  local indices = {}
  local cursor = extra[0] or 0
  for line = 1, line_count do
    indices[line] = cursor
    cursor = cursor + 1 + (extra[line] or 0)
  end
  return indices
end

---Buffer line to anchor a padding extmark on so it lands after display row `d`.
---`0` means "above the first line". When `d` falls inside a filler gap this
---returns the last real line before the gap.
---@param indices integer[]
---@param d integer
---@return integer
local function anchor_for_display(indices, d)
  local anchor = 0
  for line = 1, #indices do
    if indices[line] <= d then
      anchor = line
    else
      break
    end
  end
  return anchor
end

---Draw one comment on its pane and record its box height at the display index
---of its anchor line.
---@param session jj-flow.ReviewSession
---@param comment jj-flow.ReviewComment
---@param buf integer
---@param indices integer[]
---@param heights table<integer, integer>
local function draw(session, comment, buf, indices, heights)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local line_count = vim.api.nvim_buf_line_count(buf)
  if line_count == 0 then return end

  local info = TYPES[comment.type] or TYPES.note
  local virt_lines = box(comment.text, info.name, info.hl)

  if comment.line == 0 then
    -- File-level comment: draw the box above the first line.
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, 0, 0, {
      sign_text = info.sign,
      sign_hl_group = info.hl,
      priority = 150,
      virt_lines = virt_lines,
      virt_lines_above = true,
    })
    -- Display position just above the first line.
    heights[-1] = (heights[-1] or 0) + #virt_lines
    return
  end

  local start_line = math.max(1, math.min(comment.line, line_count))
  local end_line = math.max(1, math.min(comment.line_end or comment.line, line_count))
  local start_row = start_line - 1
  local end_row = end_line - 1

  local opts = { sign_text = info.sign, sign_hl_group = info.hl, priority = 150 }

  if start_row == end_row then
    opts.line_hl_group = info.line_hl
    opts.virt_lines = virt_lines
    opts.virt_lines_above = false
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, start_row, 0, opts)
  else
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, start_row, 0, vim.tbl_extend('force', opts, { line_hl_group = info.line_hl }))
    for row = start_row + 1, end_row - 1 do
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, 0, { line_hl_group = info.line_hl, priority = 150 })
    end
    pcall(
      vim.api.nvim_buf_set_extmark,
      buf,
      ns,
      end_row,
      0,
      vim.tbl_extend('force', opts, { line_hl_group = info.line_hl, virt_lines = virt_lines, virt_lines_above = false })
    )
  end

  local d = indices[end_line] or 0
  heights[d] = (heights[d] or 0) + #virt_lines
end

---@param buf integer
---@param indices integer[]
---@param heights table<integer, integer>
local function pad(buf, indices, heights)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  for d, count in pairs(heights) do
    local anchor = anchor_for_display(indices, d)
    local virt_lines = {}
    for i = 1, count do
      virt_lines[i] = { { '', 'Normal' } }
    end
    local row = anchor - 1
    local above = false
    if row < 0 then
      row = 0
      above = true
    end
    pcall(vim.api.nvim_buf_set_extmark, buf, ns_pad, row, 0, {
      virt_lines = virt_lines,
      virt_lines_above = above,
    })
  end
end

---Render the comments of the currently displayed file into both panes. Called
---by `review.render` after the diff highlights.
---@param session jj-flow.ReviewSession
function M.render(session)
  local a_buf, b_buf = session.original_buf, session.modified_buf
  if not (vim.api.nvim_buf_is_valid(a_buf) and vim.api.nvim_buf_is_valid(b_buf)) then return end

  vim.api.nvim_buf_clear_namespace(a_buf, ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(b_buf, ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(a_buf, ns_pad, 0, -1)
  vim.api.nvim_buf_clear_namespace(b_buf, ns_pad, 0, -1)

  local file = current_file(session)
  if not file then return end

  local a_count = vim.api.nvim_buf_line_count(a_buf)
  local b_count = vim.api.nvim_buf_line_count(b_buf)
  local a_indices = display_indices(session.diff, 'a', a_count)
  local b_indices = display_indices(session.diff, 'b', b_count)

  local a_heights, b_heights = {}, {}
  for _, comment in ipairs(M.for_file(session, file, 'base')) do
    draw(session, comment, a_buf, a_indices, a_heights)
  end
  for _, comment in ipairs(M.for_file(session, file, 'current')) do
    draw(session, comment, b_buf, b_indices, b_heights)
  end

  -- Keep both panes the same height at every display position: whichever side
  -- has fewer comment rows gets blank virtual rows, so `scrollbind` stays true.
  local a_pad, b_pad = {}, {}
  for d, a_height in pairs(a_heights) do
    local b_height = b_heights[d] or 0
    if a_height > b_height then b_pad[d] = a_height - b_height end
  end
  for d, b_height in pairs(b_heights) do
    local a_height = a_heights[d] or 0
    if b_height > a_height then a_pad[d] = b_height - a_height end
  end

  pad(b_buf, b_indices, b_pad)
  pad(a_buf, a_indices, a_pad)
end

-- ============================================================================
-- Navigation and list
-- ============================================================================

---@param session jj-flow.ReviewSession
---@param comment jj-flow.ReviewComment
function M.jump_to(session, comment)
  local target = nil
  for index, file in ipairs(session.files or {}) do
    if file.path == comment.file then
      target = index
      break
    end
  end
  if not target then return end

  if target ~= session.index then session.select(target) end

  local win = comment.side == 'base' and session.original_win or session.modified_win
  if not vim.api.nvim_win_is_valid(win) then return end
  vim.api.nvim_set_current_win(win)

  local buf = vim.api.nvim_win_get_buf(win)
  local line = math.max(1, math.min(comment.line, vim.api.nvim_buf_line_count(buf)))
  pcall(vim.api.nvim_win_set_cursor, win, { line, 0 })
  vim.api.nvim_win_call(win, function() pcall(vim.cmd, 'normal! zvzz') end)
end

---Move to the next (`dir > 0`) or previous comment, wrapping around and
---crossing files. The cursor need not be on a comment.
---@param session jj-flow.ReviewSession
---@param dir integer
function M.goto_comment(session, dir)
  local list = M.all(session)
  if #list == 0 then
    notify 'no comments in this review'
    return
  end

  local order = {}
  for index, file in ipairs(session.files or {}) do
    order[file.path] = index
  end

  local side = pane_side(session)
  local cursor_file = side and session.index or 0
  local cursor_line = side and vim.api.nvim_win_get_cursor(0)[1] or 0

  local target = nil
  if dir > 0 then
    for _, comment in ipairs(list) do
      local file_index = order[comment.file] or 0
      if file_index > cursor_file or (file_index == cursor_file and comment.line > cursor_line) then
        target = comment
        break
      end
    end
    target = target or list[1]
  else
    for i = #list, 1, -1 do
      local comment = list[i]
      local file_index = order[comment.file] or 0
      if file_index < cursor_file or (file_index == cursor_file and comment.line < cursor_line) then
        target = comment
        break
      end
    end
    target = target or list[#list]
  end

  M.jump_to(session, target)
end

---@param session jj-flow.ReviewSession
function M.list(session)
  local list = M.all(session)
  if #list == 0 then
    notify 'no comments in this review'
    return
  end

  local items = {}
  for _, comment in ipairs(list) do
    local info = TYPES[comment.type] or TYPES.note
    local location
    if comment.line == 0 then
      location = comment.file
    elseif comment.line_end then
      location = string.format('%s:%d-%d', comment.file, comment.line, comment.line_end)
    else
      location = string.format('%s:%d', comment.file, comment.line)
    end
    local text = (comment.text:gsub('\n', ' '))
    items[#items + 1] = {
      display = string.format('%s %s [%s] %s', info.sign, location, comment.side, text),
      comment = comment,
    }
  end

  vim.ui.select(items, {
    prompt = 'Review comments:',
    format_item = function(item) return item.display end,
  }, function(choice)
    if choice then M.jump_to(session, choice.comment) end
  end)
end

return M
