-- Neovim -> Pi bridge for jj-flow, built on pi-nvim's RPC.
--
-- jj-flow has no Pi extension of its own. It uses pi-nvim's `llm.complete`
-- primitive, which runs an isolated model call in the running Pi session
-- (same process, same model and credentials, no tools).

local M = {}

local config = require 'jj-flow.config'

local SYSTEM_PROMPT = table.concat({
  'You write concise Jujutsu change descriptions.',
  'You receive the unified diff of a single change.',
  'Return ONLY a short, precise description of the purpose of the change.',
  'Rules:',
  '- One line.',
  '- Describe intent and purpose, not a list of files.',
  '- No markdown, no code fences, no quotes, no bullet or numbering prefixes.',
  '- Do not mention the diff, files, or that you are an AI.',
  '- Output nothing else.',
}, '\n')

---Check that pi-nvim (with RPC) and a live Pi session are available.
---@return boolean ok
---@return string|nil err
function M.available()
  local ok, pi = pcall(require, 'pi-nvim')
  if not ok or type(pi) ~= 'table' or type(pi.complete) ~= 'function' then
    return false, 'pi-nvim is not installed (or is too old; llm.complete is required)'
  end
  if not pi.get_socket_path() then return false, 'no running Pi session found for this project' end
  return true
end

---@param text string
---@return string
local function truncate_diff(text)
  local max = config.get().max_diff_chars
  if max and #text > max then return text:sub(1, max) .. '\n... [diff truncated by jj-flow]' end
  return text
end

---Ask the running Pi session for a description of `diff`.
---
---`cb` is always invoked on the main loop, exactly once, with either an error
---string or a non-empty description.
---
---@param diff string
---@param cb fun(err: string|nil, description: string|nil)
function M.describe(diff, cb)
  local ok, pi = pcall(require, 'pi-nvim')
  if not ok or type(pi) ~= 'table' or type(pi.complete) ~= 'function' then
    cb 'pi-nvim is not installed (or is too old; llm.complete is required)'
    return
  end

  pi.complete({
    systemPrompt = SYSTEM_PROMPT,
    messages = {
      { role = 'user', content = 'Diff of the current change (@):\n\n' .. truncate_diff(diff) },
    },
  }, function(err, result)
    if err then
      cb(string.format('%s: %s', err.code or 'error', err.message or 'unknown error'))
      return
    end

    local text = result and result.text
    if type(text) ~= 'string' or vim.trim(text) == '' then
      cb 'Pi returned an empty description'
      return
    end

    cb(nil, text)
  end, { timeout = config.get().pi_timeout_ms })
end

---Hand a whole review to the running Pi session.
---
---Unlike `describe`, this must reach the interactive session (with tools) so Pi
---can edit the working copy. `pi-nvim`'s prompt channel is fire-and-forget: the
---callback only reports whether the message was accepted, not the agent's
---result.
---@param prompt string
---@param cb fun(err: string|nil)
function M.fix(prompt, cb)
  local ok, pi = pcall(require, 'pi-nvim')
  if not ok or type(pi) ~= 'table' or type(pi.send_raw) ~= 'function' then
    cb 'pi-nvim is not installed (or is too old; send_raw is required)'
    return
  end

  local done = false
  pi.send_raw({ type = 'prompt', message = prompt }, function(err, response)
    if done then return end
    done = true

    if err then
      cb(tostring(err))
      return
    end
    if type(response) ~= 'table' or response.ok ~= true then
      cb('Pi did not accept the review: ' .. vim.inspect(response))
      return
    end
    cb(nil)
  end)
end

return M
