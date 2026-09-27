-- `:JReview` renders exactly the current Jujutsu change (`@`).
--
-- Preferred path: reuse `jj.nvim`'s diff module with its CodeDiff backend
-- (`jj.diff.open("revision", { rev = "@", backend = "codediff" })`), which
-- compares the working copy against `@-`.
--
-- Fallback: invoke CodeDiff directly with `@-`'s commit id. This is the same
-- comparison jj.nvim performs, not a separate diff engine.

local M = {}

local config = require 'jj-flow.config'
local jj = require 'jj-flow.jj'

-- Git's universal empty-tree object. jj reports the root commit as all zeroes,
-- which Git rejects ("bad object"). Diffing against the empty tree is the
-- correct representation of the first change (every file appears as added).
local GIT_EMPTY_TREE = '4b825dc642cb6eb9a060e54bf8d69288fbee4904'

---@return boolean ok
local function open_with_jj_nvim()
  -- jj.nvim's CodeDiff backend silently does nothing when the `codediff` module
  -- is missing, so verify it up front before committing to this path.
  if not pcall(require, 'codediff') then return false end

  local ok_diff, jj_diff = pcall(require, 'jj.diff')
  if not ok_diff or type(jj_diff) ~= 'table' then return false end

  -- Make sure the codediff backend is registered. `setup({})` is idempotent and
  -- does not override the user's jj.nvim configuration.
  pcall(jj_diff.setup, {})

  local ok_open, err = pcall(jj_diff.open, 'revision', { rev = '@', backend = 'codediff' })
  if not ok_open then
    vim.notify('[jj-flow] jj.nvim CodeDiff failed: ' .. tostring(err), vim.log.levels.WARN)
    return false
  end
  return true
end

---@param rev string
---@return boolean ok
---@return string|nil err
local function open_with_codediff(rev)
  if vim.fn.exists ':CodeDiff' ~= 2 then return false, 'CodeDiff is not installed' end

  -- `CodeDiff <rev>` compares <rev> against the working tree. Passing `@-`
  -- gives exactly the diff of `@` (never working tree vs Git HEAD).
  vim.cmd('CodeDiff ' .. rev)
  return true
end

---@return boolean ok
---@return string|nil err
function M.open()
  local info, err = jj.change_info '@'
  if not info then return false, err end

  local parent = info.parent_commit_id
  if not parent or parent == '' then return false, 'could not resolve @-' end

  -- The root commit has no Git object. Use the empty tree instead. jj.nvim's
  -- codediff backend does not special-case this, so bypass it in that case.
  local is_root = parent:match '^0+$' ~= nil
  local rev = is_root and GIT_EMPTY_TREE or parent

  local backend = config.get().review_backend

  if backend == 'jj.nvim' then
    if not is_root and open_with_jj_nvim() then return true end
    return open_with_codediff(rev)
  end

  if backend == 'codediff' then return open_with_codediff(rev) end

  -- auto
  if not is_root and open_with_jj_nvim() then return true end
  return open_with_codediff(rev)
end

return M
