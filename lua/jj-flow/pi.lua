-- Neovim -> Pi bridge for jj-flow, built on pi-nvim's RPC.
--
-- jj-flow has no Pi extension of its own. It sends review feedback to the
-- interactive Pi session through pi-nvim.

local M = {}

---Check that pi-nvim (with RPC) and a live Pi session are available.
---@return boolean ok
---@return string|nil err
function M.available()
  local ok, pi = pcall(require, 'pi-nvim')
  if not ok or type(pi) ~= 'table' or type(pi.send_raw) ~= 'function' or type(pi.get_socket_path) ~= 'function' then
    return false, 'pi-nvim is not installed (or is too old; send_raw is required)'
  end
  if not pi.get_socket_path() then return false, 'no running Pi session found for this project' end
  return true
end

---Hand a whole review to the running Pi session.
---
---This must reach the interactive session (with tools) so Pi can edit the
---working copy. `pi-nvim`'s prompt channel is fire-and-forget: the
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
