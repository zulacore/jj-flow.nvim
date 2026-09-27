-- jj-flow.nvim: a small manual review workflow for Jujutsu + Pi.
--
--   :JReview   show exactly the current change (@) in the review UI
--   :JNew      describe @ with Pi if needed, then start a new change
--   :JNew!     start a new change without asking Pi
--   :JAbandon  discard the current change (@) only

local M = {}

local config = require 'jj-flow.config'
local jj = require 'jj-flow.jj'
local review = require 'jj-flow.review'
local pi = require 'jj-flow.pi'

-- Guards against overlapping description requests.
local requesting = false

---@param msg string
---@param level? integer
local function notify(msg, level) vim.notify('[jj-flow] ' .. msg, level or vim.log.levels.INFO) end

---Turn a model response into a short, single-line description.
---@param text string|nil
---@return string
local function sanitize_description(text)
  if not text then return '' end

  local s = text:gsub('```[%w%-_]*', '')
  s = s:gsub('`', '')
  s = vim.trim(s)

  local first = s:match '[^\n]+' or ''
  first = vim.trim(first)
  first = first:gsub('^#+%s*', '')
  first = first:gsub('^[%-%*]%s+', '')
  first = first:gsub('^%d+[%.)]%s+', '')
  first = vim.trim(first)
  first = first:gsub('^"(.*)"$', '%1')
  first = vim.trim(first)

  if #first > 200 then first = vim.trim(first:sub(1, 200):gsub('%s+%S*$', '')) end
  return first
end

---@param change_id string
---@return string
local function short_change_id(change_id) return change_id:sub(1, 8) end

---@return boolean
local function ensure_repo()
  if vim.fn.executable 'jj' ~= 1 then
    notify('the `jj` executable was not found on PATH', vim.log.levels.ERROR)
    return false
  end
  if not jj.is_repo() then
    notify('not inside a Jujutsu repository', vim.log.levels.ERROR)
    return false
  end
  return true
end

function M.review()
  if not ensure_repo() then return end

  local backend = require 'jj-flow.review.backend'
  local model, model_err = backend.build()
  if not model then
    notify(model_err or 'could not build the review', vim.log.levels.ERROR)
    return
  end

  local ok, err = review.open(model)
  if not ok then notify(err or 'could not open the review', vim.log.levels.ERROR) end
end

function M.abandon()
  if not ensure_repo() then return end

  if config.get().confirm_abandon then
    local choice = vim.fn.confirm('Abandon the current Jujutsu change (@)? This discards its content.', '&Yes\n&No', 2)
    if choice ~= 1 then
      notify 'abandon cancelled'
      return
    end
  end

  local ok, err = jj.abandon '@'
  if not ok then
    notify(err, vim.log.levels.ERROR)
    return
  end
  notify 'abandoned @; the working copy is a new empty change'
end

function M.new_force()
  if not ensure_repo() then return end
  local ok, err = jj.new()
  if not ok then
    notify(err, vim.log.levels.ERROR)
    return
  end
  notify 'started a new change'
end

function M.new()
  if not ensure_repo() then return end

  if requesting then
    notify('already waiting for Pi to describe @', vim.log.levels.WARN)
    return
  end

  local info, err = jj.change_info '@'
  if not info then
    notify(err, vim.log.levels.ERROR)
    return
  end

  -- Pin every later operation to this change. `@` is a moving target: an
  -- external `jj new` (or any rewrite) while Pi is thinking must never cause
  -- the generated description to land on a different change.
  local change_id = info.change_id
  if not change_id or change_id == '' then
    notify('could not determine the change id of @', vim.log.levels.ERROR)
    return
  end

  -- Empty change: never build a chain of empty changes.
  if info.empty then
    notify 'change @ is empty; not creating another empty change'
    return
  end

  -- Already described: keep the description exactly as-is.
  if info.description ~= '' then
    local ok, new_err = jj.new(change_id)
    if not ok then
      notify(new_err, vim.log.levels.ERROR)
      return
    end
    notify 'started a new change (kept the existing description)'
    return
  end

  -- Content but no description: ask Pi, grounded on the real diff.
  local available, avail_err = pi.available()
  if not available then
    notify('cannot describe @ with Pi: ' .. tostring(avail_err), vim.log.levels.ERROR)
    return
  end

  local diff, diff_err = jj.diff(change_id)
  if not diff then
    notify(diff_err, vim.log.levels.ERROR)
    return
  end

  requesting = true
  notify 'asking Pi to describe @ ...'

  pi.describe(diff, function(req_err, description)
    requesting = false

    -- On any failure: leave the repository completely untouched.
    if req_err then
      notify('description failed: ' .. tostring(req_err) .. ' (no jj changes made)', vim.log.levels.ERROR)
      return
    end

    local clean = sanitize_description(description)
    if clean == '' then
      notify('Pi returned an empty description (no jj changes made)', vim.log.levels.ERROR)
      return
    end

    -- Pi may have taken seconds to answer. Re-check that `@` is still the
    -- change we diffed before touching the repository.
    local current, cur_err = jj.change_info '@'
    if not current then
      notify('could not re-check @ after Pi replied: ' .. tostring(cur_err) .. ' (no jj changes made)', vim.log.levels.ERROR)
      return
    end
    if current.change_id ~= change_id then
      notify(
        string.format(
          '@ changed while Pi was working (%s -> %s); no jj changes made',
          short_change_id(change_id),
          current.change_id and short_change_id(current.change_id) or 'unknown'
        ),
        vim.log.levels.WARN
      )
      return
    end

    local ok, describe_err = jj.describe(change_id, clean)
    if not ok then
      notify(describe_err, vim.log.levels.ERROR)
      return
    end

    local ok_new, new_err = jj.new(change_id)
    if not ok_new then
      notify(new_err, vim.log.levels.ERROR)
      return
    end

    notify('described @ as: ' .. clean)
  end)
end

---@param opts? jj-flow.Config
function M.setup(opts)
  config.setup(opts)

  vim.api.nvim_create_user_command('JReview', M.review, {
    desc = 'Review the current Jujutsu change (@) in the review UI',
  })

  vim.api.nvim_create_user_command('JNew', function(args)
    if args.bang then
      M.new_force()
    else
      M.new()
    end
  end, {
    bang = true,
    desc = 'Describe @ with Pi if needed, then start a new change (:JNew! skips Pi)',
  })

  vim.api.nvim_create_user_command('JAbandon', M.abandon, {
    desc = 'Abandon the current Jujutsu change (@)',
  })
end

return M
