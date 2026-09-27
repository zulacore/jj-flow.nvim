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
    local root = vim.fn.systemlist({ 'jj', 'root' })[1]
    if root and vim.uv.fs_stat(root .. '/.git') then
      vim.health.ok 'repository is colocated (has .git)'
    else
      vim.health.warn 'repository is not colocated; :JReview needs CodeDiff, which is Git-based'
    end
  end

  -- CodeDiff
  if vim.fn.exists ':CodeDiff' == 2 then
    vim.health.ok 'codediff.nvim is available'
  else
    vim.health.warn 'codediff.nvim not found; :JReview needs it'
  end

  -- jj.nvim (optional)
  if pcall(require, 'jj.diff') then
    vim.health.info 'jj.nvim found; :JReview reuses its CodeDiff backend'
  else
    vim.health.info 'jj.nvim not found; :JReview calls CodeDiff directly'
  end

  -- pi-nvim RPC (needed by :JNew)
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
