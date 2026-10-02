-- jj-flow.nvim: a small manual review workflow for Jujutsu + Pi.
--
--   :JReview   show exactly the current change (@) in the review UI
--   :JFix      send every review comment to Pi and close the review
--   :JRestore  discard the file changes in @ without abandoning the change

local M = {}

local config = require 'jj-flow.config'
local jj = require 'jj-flow.jj'
local review = require 'jj-flow.review'
local pi = require 'jj-flow.pi'

---@param msg string
---@param level? integer
local function notify(msg, level) vim.notify('[jj-flow] ' .. msg, level or vim.log.levels.INFO) end

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

---Run `fn` against the review of the current tab, or explain that there is
---none. Shared by the jump commands.
---@param fn fun(session: jj-flow.ReviewSession)
local function with_review(fn)
  local session = review.current()
  if not session then
    notify('no open review; run :JReview first', vim.log.levels.WARN)
    return
  end
  fn(session)
end

function M.next_diff()
  with_review(function(session) require('jj-flow.review.render').next_hunk(session, 1) end)
end

function M.prev_diff()
  with_review(function(session) require('jj-flow.review.render').next_hunk(session, -1) end)
end

function M.next_comment()
  with_review(function(session) require('jj-flow.review.comments').goto_comment(session, 1) end)
end

function M.prev_comment()
  with_review(function(session) require('jj-flow.review.comments').goto_comment(session, -1) end)
end

---Send every comment of the open review to Pi in one request, then close the
---review and discard its comments. Pi is expected to modify the working copy,
---which makes the reviewed snapshot stale by construction.
function M.fix()
  if not ensure_repo() then return end

  local session = review.current()
  if not session then
    notify('no open review; run :JReview first', vim.log.levels.WARN)
    return
  end

  local feedback = require 'jj-flow.review.feedback'
  local prompt, build_err = feedback.build(session)
  if not prompt then
    notify(build_err or 'could not build the review', vim.log.levels.WARN)
    return
  end

  -- Comments are anchored to the snapshot that was reviewed. If @ moved
  -- externally (or was rewritten), applying the feedback would point at lines
  -- that no longer mean what the comment said.
  local snapshot = session.model.snapshot or {}
  local info, info_err = jj.change_info '@'
  if not info then
    notify('could not re-check @ before applying the review: ' .. tostring(info_err), vim.log.levels.ERROR)
    return
  end
  if snapshot.commit_id and info.commit_id and info.commit_id ~= snapshot.commit_id then
    notify('the reviewed change (@) has changed since this review started; run :JReview again', vim.log.levels.WARN)
    return
  end

  local available, avail_err = pi.available()
  if not available then
    notify('cannot send the review: ' .. tostring(avail_err), vim.log.levels.ERROR)
    return
  end

  local comments = require 'jj-flow.review.comments'
  notify(string.format('sending %d comment(s) to Pi ...', comments.count(session)))

  pi.fix(prompt, function(err)
    if err then
      notify('could not send the review: ' .. tostring(err), vim.log.levels.ERROR)
      return
    end

    -- Pi will edit @. The review is deliberately not kept alive: its comments
    -- reference the previous snapshot and rebasing them automatically is out of
    -- scope, so the user re-reviews from scratch.
    review.close_session(session)
    notify 'review sent to Pi; run :JReview again when it finishes'
  end)
end

function M.restore()
  if not ensure_repo() then return end

  local root, root_err = jj.root()
  if not root then
    notify(root_err, vim.log.levels.ERROR)
    return
  end

  local modified = {}
  local prefix = root .. '/'
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == '' and vim.bo[buf].modified then
      local name = vim.api.nvim_buf_get_name(buf)
      local path = name ~= '' and vim.fs.normalize(vim.fn.fnamemodify(name, ':p')) or ''
      if path == root or vim.startswith(path, prefix) then modified[#modified + 1] = vim.fn.fnamemodify(path, ':.') end
    end
  end

  if #modified > 0 then
    notify('save or discard modified buffers before restoring: ' .. table.concat(modified, ', '), vim.log.levels.WARN)
    return
  end

  if config.get().confirm_restore then
    local choice = vim.fn.confirm('Restore all file changes in the current Jujutsu change (@)?', '&Yes\n&No', 2)
    if choice ~= 1 then
      notify 'restore cancelled'
      return
    end
  end

  local ok, err = jj.restore()
  if not ok then
    notify(err, vim.log.levels.ERROR)
    return
  end

  vim.cmd 'checktime'
  notify 'restored all file changes in @'
end

---@param opts? jj-flow.Config
function M.setup(opts)
  config.setup(opts)

  vim.api.nvim_create_user_command('JReview', M.review, {
    desc = 'Review the current Jujutsu change (@) in the review UI',
  })

  vim.api.nvim_create_user_command('JFix', M.fix, {
    desc = 'Send all review comments to Pi and close the review',
  })

  vim.api.nvim_create_user_command('JNextDiff', M.next_diff, {
    desc = 'Jump to the next difference in the current review',
  })

  vim.api.nvim_create_user_command('JPrevDiff', M.prev_diff, {
    desc = 'Jump to the previous difference in the current review',
  })

  vim.api.nvim_create_user_command('JNextComment', M.next_comment, {
    desc = 'Jump to the next review comment',
  })

  vim.api.nvim_create_user_command('JPrevComment', M.prev_comment, {
    desc = 'Jump to the previous review comment',
  })

  vim.api.nvim_create_user_command('JRestore', M.restore, {
    desc = 'Restore all file changes in the current Jujutsu change (@)',
  })
end

return M
