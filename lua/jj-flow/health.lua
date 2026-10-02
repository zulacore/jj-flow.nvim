local M = {}

function M.check()
  vim.health.start 'jj-flow'

  -- jj
  if vim.fn.executable 'jj' == 1 then
    vim.health.ok('`jj` found on PATH: ' .. vim.trim(vim.fn.system { 'jj', '--version' }))
  else
    vim.health.error '`jj` not found on PATH'
  end

  local jj = require 'jj-flow.jj'
  if not jj.is_repo() then
    vim.health.warn 'the current directory is not inside a jj repository'
  else
    vim.health.ok 'inside a jj repository'

    -- The review UI is Jujutsu-native, so the only thing worth checking is
    -- that the change of @ can actually be read.
    local backend = require 'jj-flow.review.backend'
    local model, err = backend.build()
    if model then
      vim.health.ok(string.format('review backend: %d file(s) changed in @', #model.files))
    else
      vim.health.warn('review backend: ' .. tostring(err))
    end
  end

  -- pi-nvim prompt channel (needed by :JFix)
  local ok, pi = pcall(require, 'pi-nvim')
  if not ok or type(pi) ~= 'table' or type(pi.send_raw) ~= 'function' or type(pi.get_socket_path) ~= 'function' then
    vim.health.error 'pi-nvim with prompt support not found; :JFix cannot send review feedback'
    return
  end
  vim.health.ok 'pi-nvim prompt support is available'

  local socket = pi.get_socket_path()
  if not socket then
    vim.health.warn 'no running Pi session for the current directory'
    return
  end
  vim.health.ok('Pi session: ' .. socket)
end

return M
