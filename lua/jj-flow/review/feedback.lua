-- Turn a review session's comments into instructions for Pi.
--
-- This module is pure: it reads the comment store and the review model (to quote
-- the actual code the comment is anchored on) and produces text. It never talks
-- to Pi; that lives in `jj-flow.pi`.
--
-- `pi-nvim`'s prompt channel accepts plain text, so the structure is serialized
-- here. Each comment still carries file/line/side/type explicitly, and the code
-- it refers to is quoted so a 'base' anchor is unambiguous after `@` has been
-- rewritten.

local M = {}

local comments = require 'jj-flow.review.comments'
local highlights = require 'jj-flow.review.highlights'

---Maximum number of code lines quoted under a comment.
local MAX_QUOTE_LINES = 12

---@param session jj-flow.ReviewSession
---@param comment jj-flow.ReviewComment
---@return string[]
local function source_lines(session, comment)
  if comment.side == 'base' then return session.model.get_original(comment.file) or {} end
  return session.model.get_modified(comment.file) or {}
end

---@param session jj-flow.ReviewSession
---@param comment jj-flow.ReviewComment
---@return string
local function location(comment)
  if comment.line == 0 then return comment.file end
  if comment.line_end and comment.line_end ~= comment.line then return string.format('%s:%d-%d', comment.file, comment.line, comment.line_end) end
  return string.format('%s:%d', comment.file, comment.line)
end

---@param session jj-flow.ReviewSession
---@param comment jj-flow.ReviewComment
---@return string[]
local function quote(session, comment)
  -- A file-level comment refers to the whole file; quoting it would swamp the
  -- prompt, so it is left to the path alone.
  if comment.line == 0 then return {} end

  local lines = source_lines(session, comment)
  local first = comment.line
  local last = math.min(comment.line_end or comment.line, first + MAX_QUOTE_LINES - 1)

  local out = {}
  for line = first, last do
    local text = lines[line]
    if text == nil then break end
    out[#out + 1] = '   > ' .. text
  end
  return out
end

---Build the text sent to Pi for the whole review.
---
---@param session jj-flow.ReviewSession
---@return string|nil prompt
---@return string|nil err
function M.build(session)
  local all = comments.all(session)
  if #all == 0 then return nil, 'there are no comments to send' end

  local lines = {
    'You are addressing a code review of the current Jujutsu change (@).',
    '',
    'Resolve all actionable review comments below.',
    '[NOTE] comments are context only: let them inform the changes, do not',
    'invent work for them.',
    '',
    'The working copy is the current Jujutsu change. Some comments are anchored',
    'on the base side of the diff (before the change) or on code that was',
    'deleted. Even then, make the required changes in the current working copy.',
    '',
  }

  for index, comment in ipairs(all) do
    local info = highlights.comment_types[comment.type] or highlights.comment_types.note
    lines[#lines + 1] = string.format('%d. [%s] %s (%s)', index, info.name, location(comment), comment.side)

    local quoted = quote(session, comment)
    if #quoted > 0 then
      lines[#lines + 1] = comment.side == 'base' and '   base code:' or '   current code:'
      vim.list_extend(lines, quoted)
    end

    for _, text_line in ipairs(vim.split(comment.text, '\n', { plain = true })) do
      lines[#lines + 1] = '   ' .. text_line
    end
    lines[#lines + 1] = ''
  end

  vim.list_extend(lines, {
    'Make the required changes in the working tree.',
    '',
    'Do not create, abandon, squash, rebase, describe or otherwise modify',
    'Jujutsu history.',
    '',
    'Do not run `jj new`.',
    '',
    'The human controls the Jujutsu workflow.',
    '',
    'After modifying the code, verify the implementation appropriately.',
  })

  return table.concat(lines, '\n')
end

return M
