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
---@field empty boolean
---@field description string
---@field change_id string|nil
---@field commit_id string|nil
---@field parent_commit_id string|nil

---Read the state of a revision (defaults to `@`).
---@param rev? string
---@return jj-flow.ChangeInfo|nil info
---@return string|nil err
function M.change_info(rev)
  rev = rev or '@'

  local empty_res = run { 'log', '--no-graph', '-r', rev, '-T', 'empty', '--quiet' }
  if not empty_res or empty_res.code ~= 0 then return nil, 'could not read change state: ' .. (empty_res and empty_res.stderr or 'jj failed') end

  local desc_res = run { 'log', '--no-graph', '-r', rev, '-T', 'description', '--quiet' }
  if not desc_res or desc_res.code ~= 0 then return nil, 'could not read change description: ' .. (desc_res and desc_res.stderr or 'jj failed') end

  local change_res = run { 'log', '--no-graph', '-r', rev, '-T', 'change_id', '--quiet' }
  local id_res = run { 'log', '--no-graph', '-r', rev, '-T', 'commit_id', '--quiet' }
  local parent_res = run { 'log', '--no-graph', '-r', rev .. '-', '-T', 'commit_id', '--quiet' }

  return {
    empty = vim.trim(empty_res.stdout) == 'true',
    description = vim.trim(desc_res.stdout or ''),
    change_id = change_res and change_res.code == 0 and vim.trim(change_res.stdout) or nil,
    commit_id = id_res and id_res.code == 0 and vim.trim(id_res.stdout) or nil,
    parent_commit_id = parent_res and parent_res.code == 0 and vim.trim(parent_res.stdout) or nil,
  }
end

---Return the unified diff of a revision (defaults to `@`).
---@param rev? string
---@return string|nil diff
---@return string|nil err
function M.diff(rev)
  rev = rev or '@'
  local result = run { 'diff', '-r', rev, '--git' }
  if not result or result.code ~= 0 then return nil, 'jj diff failed: ' .. (result and result.stderr or 'unknown error') end
  return result.stdout
end

---@param rev string
---@param message string
---@return boolean ok
---@return string|nil err
function M.describe(rev, message)
  local result = run { 'describe', '-r', rev, '-m', message }
  if not result or result.code ~= 0 then return false, 'jj describe failed: ' .. (result and result.stderr or 'unknown error') end
  return true
end

---Create a new change. When `rev` is given the new change is created on top
---of that revision instead of the current `@`, pinning the operation to a
---change captured earlier.
---@param rev? string
---@return boolean ok
---@return string|nil err
function M.new(rev)
  local args = { 'new' }
  if rev and rev ~= '' then table.insert(args, rev) end

  local result = run(args)
  if not result or result.code ~= 0 then return false, 'jj new failed: ' .. (result and result.stderr or 'unknown error') end
  return true
end

---Abandon a single revision (defaults to `@`). Jujutsu gives the working copy
---a new empty commit on the same parent(s); parents are not touched.
---@param rev? string
---@return boolean ok
---@return string|nil err
function M.abandon(rev)
  local result = run { 'abandon', rev or '@' }
  if not result or result.code ~= 0 then return false, 'jj abandon failed: ' .. (result and result.stderr or 'unknown error') end
  return true
end

return M
