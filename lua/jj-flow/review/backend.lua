-- Jujutsu-native data source for the review UI.
--
-- This is the only module in the review package that talks to `jj`. It exposes
-- a small, renderer-agnostic model:
--
--   {
--     files = { { path, status }, ... },   -- files changed in @
--     root  = "/abs/repo/root",
--     get_original = function(path) -> lines in @-  end,
--     get_modified = function(path) -> lines in @   end,
--   }
--
-- The renderer never runs a jj command and never assumes a colocated Git
-- repository: the whole change is read from Jujutsu's own store.

local M = {}

local jj = require 'jj-flow.jj'

---@class jj-flow.ReviewFile
---@field path string Repository-relative path.
---@field status string Single-letter status from `jj diff --summary` (A/M/D/...).

---@class jj-flow.ReviewModel
---@field files jj-flow.ReviewFile[]
---@field root string
---@field get_original fun(path: string): string[]
---@field get_modified fun(path: string): string[]

---Turn raw `jj file show` stdout into buffer lines.
---
---`vim.system` hands us the whole file; split it back into lines. A binary
---file is replaced by a single notice because source highlighting and diffing
---do not apply to it.
---@param stdout string|nil
---@return string[]
local function stdout_to_lines(stdout)
  if stdout == nil or stdout == '' then return { '' } end
  if stdout:find('\0', 1, true) then return { '[binary file not shown]' } end

  local lines = vim.split(stdout, '\n', { plain = true })
  -- `vim.split` keeps the empty string produced by a trailing newline.
  if lines[#lines] == '' then table.remove(lines) end
  if #lines == 0 then lines = { '' } end
  return lines
end

---Read a path at a revision. A missing path is not an error: an added file has
---no content in `@-` and a deleted file has none in `@`, and an empty side is
---exactly what the diff needs.
---@param rev string
---@param path string
---@return string[]
local function read(rev, path)
  local result = jj.run { 'file', 'show', '-r', rev, '--', path }
  if not result or result.code ~= 0 then return { '' } end
  return stdout_to_lines(result.stdout)
end

---Build a review model for the current change `@`.
---@return jj-flow.ReviewModel|nil model
---@return string|nil err
function M.build()
  local root_result = jj.run { 'root' }
  if not root_result or root_result.code ~= 0 then return nil, 'not inside a Jujutsu repository' end
  local root = vim.trim(root_result.stdout or '')

  -- `jj diff -r @ --summary` is Jujutsu's own view of the change: one line per
  -- file, `<status> <path>`. It compares `@` against its parent, so it is the
  -- exact diff `:JReview` promises, without Git and without the working tree
  -- being compared to HEAD.
  local result = jj.run { 'diff', '-r', '@', '--summary' }
  if not result or result.code ~= 0 then return nil, 'could not list the changes in @: ' .. (result and result.stderr or 'jj failed') end

  local files = {}
  for line in (result.stdout or ''):gmatch '[^\n]+' do
    local status, path = line:match '^(%a+)%s+(.+)$'
    if status and path then files[#files + 1] = { path = vim.trim(path), status = status:sub(1, 1) } end
  end

  -- `jj file show` re-snapshots and can be called twice per file as the user
  -- navigates; cache by revision + path so a review session stays responsive.
  local cache = {}
  local function cached(rev, path)
    local key = rev .. '\0' .. path
    if cache[key] == nil then cache[key] = read(rev, path) end
    return cache[key]
  end

  return {
    files = files,
    root = root,
    get_original = function(path) return cached('@-', path) end,
    get_modified = function(path) return cached('@', path) end,
  }
end

return M
