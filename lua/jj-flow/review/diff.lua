-- Diff and alignment model for the review UI.
--
-- Pure data: no buffers, no windows, no jj. It answers two questions for the
-- renderer:
--
--   1. which line ranges differ (line-level hunks), and for paired lines which
--      character ranges differ inside them;
--   2. how many filler rows each side needs so that corresponding lines line up
--      under native 'scrollbind'.
--
-- Line-level diffing uses Neovim's C `vim.diff` (histogram). Character-level
-- highlighting is computed per paired line by reusing `vim.diff` on the two
-- lines split into individual characters.

local M = {}

-- Above this many bytes a line is diffed as a whole instead of character by
-- character. Guards against pathological (e.g. minified) lines.
local MAX_CHAR_LINE = 2000

-- Above this many paired lines in a single hunk, skip character refinement.
-- The hunk is still line-highlighted; this only bounds the per-line diff work
-- on a very large rewrite.
local MAX_CHAR_PAIRS = 1000

---Split a line into UTF-8 characters, also returning each character's 1-based
---byte offset. The diff needs character units; extmarks need byte columns.
---@param s string
---@return string[] chars
---@return integer[] byte_at
local function split_chars(s)
  local chars, byte_at = {}, {}
  local i, n = 1, #s
  while i <= n do
    local b = s:byte(i)
    local len = 1
    if b >= 0xF0 then
      len = 4
    elseif b >= 0xE0 then
      len = 3
    elseif b >= 0xC0 then
      len = 2
    end
    if i + len - 1 > n then len = n - i + 1 end
    chars[#chars + 1] = s:sub(i, i + len - 1)
    byte_at[#byte_at + 1] = i
    i = i + len
  end
  return chars, byte_at
end

---Convert a 1-based character range into 0-based byte columns `[start, end)`.
---Returns nil for an empty range (a pure insertion on this side).
---@param byte_at integer[]
---@param total integer Length of the line in bytes.
---@param index integer 1-based start character.
---@param count integer Number of characters.
---@return integer|nil start_col
---@return integer|nil end_col
local function byte_columns(byte_at, total, index, count)
  if count <= 0 then return nil, nil end
  local start_col = (byte_at[index] or (total + 1)) - 1
  local next_index = index + count
  local end_col = (byte_at[next_index] or (total + 1)) - 1
  return start_col, end_col
end

---Character-level differences between two lines.
---@param a string
---@param b string
---@return { a_start: integer, a_end: integer, b_start: integer, b_end: integer }[]
local function char_changes(a, b)
  if a == '' and b == '' then return {} end
  if #a > MAX_CHAR_LINE or #b > MAX_CHAR_LINE then return {} end

  local chars_a, bytes_a = split_chars(a)
  local chars_b, bytes_b = split_chars(b)
  local ok, indices = pcall(vim.diff, table.concat(chars_a, '\n'), table.concat(chars_b, '\n'), { result_type = 'indices' })
  if not ok or not indices then return {} end

  local changes = {}
  for _, idx in ipairs(indices) do
    local a_start, a_end = byte_columns(bytes_a, #a, idx[1], idx[2])
    local b_start, b_end = byte_columns(bytes_b, #b, idx[3], idx[4])
    if a_start or b_start then changes[#changes + 1] = { a_start = a_start, a_end = a_end, b_start = b_start, b_end = b_end } end
  end
  return changes
end

---@class jj-flow.DiffPair
---@field a_line integer Original buffer line (1-based).
---@field b_line integer Modified buffer line (1-based).
---@field changes { a_start: integer, a_end: integer, b_start: integer, b_end: integer }[]

---@class jj-flow.DiffHunk
---@field a_start integer First original line (1-based).
---@field a_count integer Number of original lines.
---@field b_start integer First modified line (1-based).
---@field b_count integer Number of modified lines.
---@field pairs jj-flow.DiffPair[]

---@class jj-flow.ReviewDiff
---@field hunks jj-flow.DiffHunk[]
---@field a_fillers { after: integer, count: integer }[] Fillers for the original side.
---@field b_fillers { after: integer, count: integer }[] Fillers for the modified side.

---True for a side that has no content. A missing/empty file is represented by
---the single empty line every Neovim buffer must have.
---@param lines string[]
---@return boolean
local function is_empty(lines) return #lines == 0 or (#lines == 1 and lines[1] == '') end

---Position to anchor fillers after, given a changed range. For an empty range
---`vim.diff` reports the line *before* the insertion point, so the anchor is
---`start` itself; otherwise it is the last line of the block.
---@param start integer
---@param count integer
---@return integer
local function filler_after(start, count)
  if count == 0 then return start end
  return start + count - 1
end

---Compute the review diff between the two sides.
---
---Fillers are placed at the end of the shorter side of each hunk, so the starts
---of the two blocks line up. `after` is a 1-based buffer line; `after == 0`
---means "above the first line".
---@param a_lines string[] Lines in `@-`.
---@param b_lines string[] Lines in `@`.
---@return jj-flow.ReviewDiff
function M.compute(a_lines, b_lines)
  -- Whole-file additions and deletions get a single hunk and no line pairing:
  -- everything is simply inserted/deleted. This also keeps the empty side from
  -- being treated as a changed blank line.
  local a_empty, b_empty = is_empty(a_lines), is_empty(b_lines)
  if a_empty and b_empty then return { hunks = {}, a_fillers = {}, b_fillers = {} } end
  if a_empty or b_empty then
    local a_count = a_empty and 0 or #a_lines
    local b_count = b_empty and 0 or #b_lines
    local a_fillers, b_fillers = {}, {}
    if a_count == 0 then
      a_fillers[1] = { after = 0, count = b_count }
    else
      b_fillers[1] = { after = 0, count = a_count }
    end
    return {
      hunks = { { a_start = 1, a_count = a_count, b_start = 1, b_count = b_count, pairs = {} } },
      a_fillers = a_fillers,
      b_fillers = b_fillers,
    }
  end

  -- The trailing newline makes the last line a real line terminator, which
  -- keeps an insertion at the end of a file from being mistaken for a change
  -- to the previous line.
  local a = table.concat(a_lines, '\n') .. '\n'
  local b = table.concat(b_lines, '\n') .. '\n'

  local ok, indices = pcall(vim.diff, a, b, { result_type = 'indices', algorithm = 'histogram' })
  if not ok or not indices then indices = {} end

  local hunks = {}
  for _, idx in ipairs(indices) do
    local a_start, a_count, b_start, b_count = idx[1], idx[2], idx[3], idx[4]
    local hunk = {
      a_start = a_start,
      a_count = a_count,
      b_start = b_start,
      b_count = b_count,
      pairs = {},
    }

    -- Pair lines positionally inside the hunk and refine each pair to
    -- character ranges. When one block is longer, the extra lines are only
    -- line-highlighted.
    local paired = math.min(a_count, b_count)
    if paired > MAX_CHAR_PAIRS then paired = 0 end
    for i = 1, paired do
      local a_line = a_start + i - 1
      local b_line = b_start + i - 1
      local changes = char_changes(a_lines[a_line] or '', b_lines[b_line] or '')
      if #changes > 0 then hunk.pairs[#hunk.pairs + 1] = { a_line = a_line, b_line = b_line, changes = changes } end
    end

    hunks[#hunks + 1] = hunk
  end

  local a_fillers, b_fillers = {}, {}
  for _, hunk in ipairs(hunks) do
    local delta = hunk.a_count - hunk.b_count
    if delta > 0 then
      -- Original has more lines: pad the modified block after it.
      b_fillers[#b_fillers + 1] = { after = filler_after(hunk.b_start, hunk.b_count), count = delta }
    elseif delta < 0 then
      a_fillers[#a_fillers + 1] = { after = filler_after(hunk.a_start, hunk.a_count), count = -delta }
    end
  end

  return { hunks = hunks, a_fillers = a_fillers, b_fillers = b_fillers }
end

return M
