--`:JReview`: a self-contained code-review UI for the current Jujutsu change.
--
-- The UI is deliberately decoupled from Jujutsu. It is driven by a review model
-- with the shape produced by `jj-flow.review.backend`:
--
--   {
--     files = { { path, status } },
--     get_original = function(path) -> lines in @-  end,
--     get_modified = function(path) -> lines in @   end,
--   }
--
-- This module owns the session: the review tab, its three windows, file
-- selection, keymaps and teardown. Rendering lives in `review.render`,
-- the sidebar in `review.explorer`, the diff model in `review.diff` and folding
-- in `review.compact`.

local M = {}

local config = require 'jj-flow.config'
local explorer = require 'jj-flow.review.explorer'
local render = require 'jj-flow.review.render'
local highlights = require 'jj-flow.review.highlights'
local compact = require 'jj-flow.review.compact'

---@class jj-flow.ReviewSession
---@field model jj-flow.ReviewModel
---@field files jj-flow.ReviewFile[]
---@field tabpage integer
---@field explorer_win integer
---@field explorer_buf integer
---@field original_win integer
---@field original_buf integer
---@field modified_win integer
---@field modified_buf integer
---@field index integer
---@field diff jj-flow.ReviewDiff|nil
---@field compact boolean
---@field context_lines integer
---@field landing 'first'|'last'|nil
---@field closing boolean
---@field augroup string
---@field select fun(index: integer)

local sessions = {}
local active = nil

---Keep the explorer usable on narrow terminals without starving the diff panes.
---@param cfg jj-flow.Config
---@return integer
local function explorer_width(cfg) return math.max(20, math.min(cfg.review_explorer_width, vim.o.columns - 20)) end

---Tear down a review session: close its tab and delete its scratch buffers.
---Idempotent and re-entrancy-safe (TabClosed/WinClosed can fire because of the
---very teardown this performs).
---@param session jj-flow.ReviewSession
local function close_session(session)
  if not session or session.closing then return end
  session.closing = true

  sessions[session.tabpage] = nil
  if active == session then active = nil end
  pcall(vim.api.nvim_del_augroup_by_name, session.augroup)

  if vim.api.nvim_tabpage_is_valid(session.tabpage) then
    if #vim.api.nvim_list_tabpages() == 1 then vim.cmd 'tabnew' end
    local number = vim.api.nvim_tabpage_get_number(session.tabpage)
    pcall(vim.cmd, number .. 'tabclose!')
  end

  for _, buf in ipairs { session.explorer_buf, session.original_buf, session.modified_buf } do
    if vim.api.nvim_buf_is_valid(buf) then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
  end
end

---Open the review UI for `model`. If a review is already open, focus it.
---@param model jj-flow.ReviewModel
---@return boolean ok
---@return string|nil err
function M.open(model)
  highlights.setup()

  if active and vim.api.nvim_tabpage_is_valid(active.tabpage) then
    vim.api.nvim_set_current_tabpage(active.tabpage)
    return true
  end

  if not model or not model.files or #model.files == 0 then return false, 'the current change (@) has no modified files' end

  local cfg = config.get()

  vim.cmd 'tabnew'
  local tabpage = vim.api.nvim_get_current_tabpage()
  local placeholder = vim.api.nvim_get_current_buf()

  -- Explorer on the left; original (@-) and modified (@) to its right.
  local explorer_win = vim.api.nvim_get_current_win()
  local explorer_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(explorer_win, explorer_buf)

  vim.cmd 'rightbelow vsplit'
  local original_win = vim.api.nvim_get_current_win()
  local original_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(original_win, original_buf)

  vim.cmd 'rightbelow vsplit'
  local modified_win = vim.api.nvim_get_current_win()
  local modified_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(modified_win, modified_buf)

  if vim.api.nvim_buf_is_valid(placeholder) then pcall(vim.api.nvim_buf_delete, placeholder, { force = true }) end

  for _, buf in ipairs { explorer_buf, original_buf, modified_buf } do
    vim.bo[buf].buftype = 'nofile'
    vim.bo[buf].bufhidden = 'hide'
    vim.bo[buf].swapfile = false
  end
  vim.bo[explorer_buf].modifiable = false

  local function pane_options(win)
    vim.wo[win].wrap = false
    vim.wo[win].list = false
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = 'no'
    vim.wo[win].foldcolumn = '0'
    vim.wo[win].spell = false
    vim.wo[win].cursorline = true
    vim.wo[win].winbar = ''
  end
  pane_options(original_win)
  pane_options(modified_win)
  pane_options(explorer_win)
  vim.wo[explorer_win].winfixwidth = true

  ---@type jj-flow.ReviewSession
  local session = {
    model = model,
    files = model.files,
    tabpage = tabpage,
    explorer_win = explorer_win,
    explorer_buf = explorer_buf,
    original_win = original_win,
    original_buf = original_buf,
    modified_win = modified_win,
    modified_buf = modified_buf,
    index = 1,
    diff = nil,
    compact = cfg.review_compact,
    context_lines = cfg.review_context_lines,
    landing = nil,
    closing = false,
    augroup = 'jj_flow_review_' .. tabpage,
  }

  function session.select(index)
    local count = #session.files
    if count == 0 then return end
    session.index = ((index - 1) % count) + 1
    explorer.render(session)
    render.render_file(session, session.files[session.index].path)
  end

  function session.open_selected() session.select(session.index) end

  sessions[tabpage] = session
  active = session

  -- Keymaps are buffer-local to the three scratch buffers, so they never leak
  -- into user files and vanish with the session.
  local function map(buf, lhs, rhs, desc) vim.keymap.set('n', lhs, rhs, { buffer = buf, silent = true, nowait = true, desc = desc }) end
  for _, buf in ipairs { explorer_buf, original_buf, modified_buf } do
    map(buf, 'q', function() close_session(session) end, 'jj-flow: close review')
    map(buf, ']c', function() render.next_hunk(session, 1) end, 'jj-flow: next hunk')
    map(buf, '[c', function() render.next_hunk(session, -1) end, 'jj-flow: previous hunk')
    map(buf, ']f', function() session.select(session.index + 1) end, 'jj-flow: next file')
    map(buf, '[f', function() session.select(session.index - 1) end, 'jj-flow: previous file')
    map(buf, 'gc', function() compact.toggle(session) end, 'jj-flow: toggle compact')
  end
  map(explorer_buf, 'j', function() explorer.move(session, 1) end, 'jj-flow: next file')
  map(explorer_buf, 'k', function() explorer.move(session, -1) end, 'jj-flow: previous file')
  map(explorer_buf, '<Down>', function() explorer.move(session, 1) end, 'jj-flow: next file')
  map(explorer_buf, '<Up>', function() explorer.move(session, -1) end, 'jj-flow: previous file')
  map(explorer_buf, '<CR>', function() session.open_selected() end, 'jj-flow: open file')
  map(explorer_buf, 'l', function() session.open_selected() end, 'jj-flow: open file')

  -- Layout: fixed explorer, the two diff panes share the rest.
  vim.api.nvim_win_set_width(explorer_win, explorer_width(cfg))
  vim.cmd 'wincmd ='
  vim.api.nvim_win_set_width(explorer_win, explorer_width(cfg))

  local group = vim.api.nvim_create_augroup(session.augroup, { clear = true })
  vim.api.nvim_create_autocmd('TabClosed', {
    group = group,
    callback = function() close_session(session) end,
  })
  vim.api.nvim_create_autocmd('WinClosed', {
    group = group,
    callback = function(args)
      local win = tonumber(args.match)
      if win == explorer_win or win == original_win or win == modified_win then vim.schedule(function() close_session(session) end) end
    end,
  })
  vim.api.nvim_create_autocmd('VimResized', {
    group = group,
    callback = function()
      if vim.api.nvim_win_is_valid(explorer_win) then vim.api.nvim_win_set_width(explorer_win, explorer_width(cfg)) end
    end,
  })

  explorer.create(session)
  session.select(1)

  if vim.api.nvim_win_is_valid(modified_win) then vim.api.nvim_set_current_win(modified_win) end

  return true
end

---Close the review session of the current tab, if any.
function M.close()
  local session = sessions[vim.api.nvim_get_current_tabpage()] or active
  if session then close_session(session) end
end

---The review session of the current tab, if any. Useful for integration and
---tests.
---@return jj-flow.ReviewSession|nil
function M.current() return sessions[vim.api.nvim_get_current_tabpage()] end

return M
