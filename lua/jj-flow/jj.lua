-- Thin wrapper around the `jj` CLI.
--
-- Only the operations needed by the workflow live here. This is intentionally
-- not a general Jujutsu client.

local M = {}

---@param args string[]
---@return table|nil result
---@return string|nil err
local function run(args)
  local cmd = { 'jj' }
  vim.list_extend(cmd, args)

  local ok, result = pcall(function() return vim.system(cmd, { text = true, cwd = vim.fn.getcwd() }):wait() end)

  if not ok then return nil, tostring(result) end
  return result, nil
end

---@return boolean
function M.is_repo()
  local result = run { 'root' }
  return result ~= nil and result.code == 0
end

---Run a raw `jj` command.
---
---Exposed for callers that need a primitive this wrapper does not model (the
---review backend, for instance). Prefer the named helpers above when one fits.
---@param args string[]
---@return table|nil result `{ code, stdout, stderr }` from `vim.system`
---@return string|nil err
function M.run(args) return run(args) end

---@class jj-flow.ChangeInfo
---@field change_id string|nil
---@field commit_id string|nil
---@field parent_commit_id string|nil

---@return string|nil root
---@return string|nil err
function M.root()
  local result = run { 'root' }
  if not result or result.code ~= 0 then return nil, 'jj root failed: ' .. (result and result.stderr or 'unknown error') end
  return vim.fs.normalize(vim.trim(result.stdout or '')), nil
end

---Read the state of a revision (defaults to `@`).
---@param rev? string
---@return jj-flow.ChangeInfo|nil info
---@return string|nil err
function M.change_info(rev)
  rev = rev or '@'

  local change_res = run { 'log', '--no-graph', '-r', rev, '-T', 'change_id', '--quiet' }
  local id_res = run { 'log', '--no-graph', '-r', rev, '-T', 'commit_id', '--quiet' }
  local parent_res = run { 'log', '--no-graph', '-r', rev .. '-', '-T', 'commit_id', '--quiet' }

  return {
    change_id = change_res and change_res.code == 0 and vim.trim(change_res.stdout) or nil,
    commit_id = id_res and id_res.code == 0 and vim.trim(id_res.stdout) or nil,
    parent_commit_id = parent_res and parent_res.code == 0 and vim.trim(parent_res.stdout) or nil,
  }
end

---Restore every path in the working-copy change from its parent(s), preserving
---the current change identity and metadata.
---@return boolean ok
---@return string|nil err
function M.restore()
  local result = run { 'restore' }
  if not result or result.code ~= 0 then return false, 'jj restore failed: ' .. (result and result.stderr or 'unknown error') end
  return true
end

return M
