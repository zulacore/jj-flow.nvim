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

  -- pi-nvim RPC (needed by :JNew; :JFix additionally needs a live session)
  local REQUIRED_PROTOCOL = 1

  local ok, pi = pcall(require, 'pi-nvim')
  if not ok or type(pi) ~= 'table' or type(pi.complete) ~= 'function' then
    vim.health.error 'pi-nvim with RPC not found; :JNew cannot ask Pi for a description'
    return
  end
  vim.health.ok 'pi-nvim with RPC is available'

  local socket = pi.get_socket_path()
  if not socket then
    vim.health.warn 'no running Pi session for the current directory'
    return
  end
  vim.health.ok('Pi session: ' .. socket)

  -- Verify the RPC contract on the server side (protocol + required methods).
  local done, caps, cerr = false, nil, nil
  pi.capabilities(function(err, result)
    cerr = err
    caps = result
    done = true
  end, { timeout = 2000 })
  vim.wait(3000, function() return done end, 50)

  if not done then
    vim.health.error 'RPC did not answer within 2s'
    return
  end

  if cerr then
    vim.health.error(string.format('RPC capabilities failed: %s: %s', cerr.code, cerr.message))
    if cerr.code == 'unsupported_method' or (cerr.message or ''):find 'Unknown command type' then
      vim.health.info 'the running pi-nvim extension is older than this plugin; restart pi with a current extension'
    end
    return
  end

  if type(caps.protocol) == 'number' and caps.protocol >= REQUIRED_PROTOCOL then
    vim.health.ok(string.format('RPC protocol %s (requires >= %s)', tostring(caps.protocol), REQUIRED_PROTOCOL))
  else
    vim.health.error(string.format('RPC protocol %s is older than required (%s)', tostring(caps.protocol), REQUIRED_PROTOCOL))
  end

  local has_complete = false
  for _, method in ipairs(caps.methods or {}) do
    if method == 'llm.complete' then has_complete = true end
  end
  if has_complete then
    vim.health.ok 'llm.complete is available'
  else
    vim.health.error 'llm.complete is not available (old pi-nvim extension?)'
  end
end

return M
