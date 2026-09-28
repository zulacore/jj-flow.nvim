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
local comments = require 'jj-flow.review.comments'

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
---@field comments jj-flow.ReviewComment[]
---@field next_comment_id integer
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

  -- The diff panes show comment signs.
  vim.wo[original_win].signcolumn = 'yes:1'
  vim.wo[modified_win].signcolumn = 'yes:1'

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

  comments.attach(session)

  sessions[tabpage] = session
  active = session

  -- Keymaps are buffer-local to the three scratch buffers, so they never leak
  -- into user files and vanish with the session.
  local function is_enabled(key) return key ~= nil and key ~= false and key ~= '' end
  local function map(buf, lhs, rhs, desc)
    if not is_enabled(lhs) then return end
    vim.keymap.set('n', lhs, rhs, { buffer = buf, silent = true, nowait = true, desc = desc })
  end
  local function map_visual(buf, lhs, rhs, desc)
    if not is_enabled(lhs) then return end
    vim.keymap.set('x', lhs, rhs, { buffer = buf, silent = true, nowait = true, desc = desc })
  end

  local km = cfg.review_keymaps

  -- Cycle focus between the explorer and the two diff panes, left to right.
  -- `<Tab>` moves forward, `<S-Tab>` backwards; both wrap around.
  local function focus_pane(dir)
    local wins = { explorer_win, original_win, modified_win }
    local current = vim.api.nvim_get_current_win()
    local index = 1
    for i, win in ipairs(wins) do
      if win == current then
        index = i
        break
      end
    end
    local target = ((index - 1 + dir) % #wins) + 1
    if vim.api.nvim_win_is_valid(wins[target]) then vim.api.nvim_set_current_win(wins[target]) end
  end

  -- `<CR>` on a commented line opens the editor. With no comment under the
  -- cursor it falls back to the builtin key, so the review still behaves like
  -- a normal buffer. In the explorer it opens the selected file and moves the
  -- focus to the `current` pane.
  local function open_selected_file()
    session.open_selected()
    if vim.api.nvim_win_is_valid(modified_win) then vim.api.nvim_set_current_win(modified_win) end
  end

  local function open_or_edit()
    if vim.api.nvim_get_current_buf() == explorer_buf then
      open_selected_file()
      return
    end
    if comments.at_cursor(session) then
      comments.edit_at_cursor(session)
      return
    end
    if is_enabled(km.open) then vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(km.open, true, false, true), 'n', false) end
  end

  -- The review buffers are a self-contained UI: only the review keys below,
  -- `<Esc>`, the vertical navigation keys (`j`, `k`, `<Up>`, `<Down>`) and `v`
  -- (to select a comment range) stay usable. Everything else, whether it is a
  -- builtin command or a global/plugin mapping, is turned into a no-op so it
  -- cannot act on the review by accident.
  --
  -- The comment input float is a separate buffer and is not restricted: typing
  -- there works normally.
  --
  -- Multi-key mappings need their prefix to remain unbound, otherwise `nowait`
  -- on the prefix would make `gc`, `]n`, ... unreachable.
  local our_keys = {
    km.close,
    km.exit,
    km.fix,
    km.next_diff,
    km.prev_diff,
    km.next_file,
    km.prev_file,
    km.next_pane,
    km.prev_pane,
    km.compact,
    km.next,
    km.prev,
    km.list,
    km.add,
    km.add_file,
    km.edit,
    km.delete,
    km.open,
    'j',
    'k',
    '<Down>',
    '<Up>',
  }

  ---@type table<string, boolean>
  local allowed = {}
  ---@type table<string, boolean>
  local prefixes = {}

  ---Resolve `<leader>`/`<localleader>` to their actual key so the first
  ---character can be kept free for the multi-key mapping.
  ---@param key string
  ---@return string
  local function expand_leader(key)
    local leader = vim.g.mapleader
    if type(leader) ~= 'string' or leader == '' then leader = '\\' end
    local localleader = vim.g.maplocalleader
    if type(localleader) ~= 'string' or localleader == '' then localleader = '\\' end
    key = key:gsub('<[Ll]eader>', function() return leader end)
    return (key:gsub('<[Ll]ocalleader>', function() return localleader end))
  end

  for _, key in ipairs(our_keys) do
    if type(key) == 'string' and key ~= '' then
      allowed[key] = true
      local expanded = expand_leader(key)
      if expanded:sub(1, 1) ~= '<' then
        for i = 1, #expanded - 1 do
          prefixes[expanded:sub(1, i)] = true
        end
      end
    end
  end
  -- Not configurable, but required to leave the review and to start a visual
  -- selection for a range comment.
  for _, key in ipairs { '<Esc>', 'v', 'V', ':' } do
    allowed[key] = true
  end

  local function restrict_keymaps(buf)
    if not cfg.review_isolate_keymaps then return end

    -- Every printable normal-mode key: builtin when it is part of the
    -- allowlist, a hard no-op otherwise.
    for byte = 32, 126 do
      local lhs = string.char(byte)
      if not prefixes[lhs] then
        local rhs = allowed[lhs] and lhs or '<Nop>'
        pcall(vim.keymap.set, 'n', lhs, rhs, { buffer = buf, noremap = true, silent = true, nowait = true })
      end
    end

    -- Keep the allowed special navigation keys on their builtin meaning even
    -- when a global mapping shadows them.
    for _, lhs in ipairs { '<Up>', '<Down>' } do
      pcall(vim.keymap.set, 'n', lhs, lhs, { buffer = buf, noremap = true, silent = true, nowait = true })
    end

    -- Neutralize every existing global mapping (special keys, `<leader>...`,
    -- `<C-...>`, `<Plug>...`, multi-key maps). Prefixes of our own mappings are
    -- left untouched so the multi-key mappings stay reachable.
    for _, mode in ipairs { 'n', 'v', 'x', 's', 'o', 'i' } do
      for _, mapping in ipairs(vim.api.nvim_get_keymap(mode)) do
        local lhs = mapping.lhs
        if lhs and lhs ~= '' and mapping.buffer ~= 1 and not allowed[lhs] and not prefixes[lhs] then
          pcall(vim.keymap.set, mode, lhs, '<Nop>', { buffer = buf, noremap = true, silent = true, nowait = true })
        end
      end
    end
  end

  for _, buf in ipairs { explorer_buf, original_buf, modified_buf } do
    restrict_keymaps(buf)
    map(buf, km.close, function() close_session(session) end, 'jj-flow: close review')
    map(buf, km.exit, function() close_session(session) end, 'jj-flow: close review')
    map(buf, km.fix, function() require('jj-flow').fix() end, 'jj-flow: fix review (JFix)')
    map(buf, km.next_diff, function() render.next_hunk(session, 1) end, 'jj-flow: next hunk')
    map(buf, km.prev_diff, function() render.next_hunk(session, -1) end, 'jj-flow: previous hunk')
    map(buf, km.next_file, function() session.select(session.index + 1) end, 'jj-flow: next file')
    map(buf, km.prev_file, function() session.select(session.index - 1) end, 'jj-flow: previous file')
    map(buf, km.next_pane, function() focus_pane(1) end, 'jj-flow: next pane')
    map(buf, km.prev_pane, function() focus_pane(-1) end, 'jj-flow: previous pane')
    map(buf, km.compact, function() compact.toggle(session) end, 'jj-flow: toggle compact')
    map(buf, km.next, function() comments.goto_comment(session, 1) end, 'jj-flow: next comment')
    map(buf, km.prev, function() comments.goto_comment(session, -1) end, 'jj-flow: previous comment')
    map(buf, km.list, function() comments.list(session) end, 'jj-flow: list comments')
    map(buf, km.add, function() comments.add_at_cursor(session) end, 'jj-flow: add comment')
    map(buf, km.add_file, function() comments.add_file_comment(session) end, 'jj-flow: file comment')
    map(buf, km.edit, function() comments.edit_at_cursor(session) end, 'jj-flow: edit comment')
    map(buf, km.open, open_or_edit, 'jj-flow: open / edit comment')
    map(buf, km.delete, function() comments.delete_at_cursor(session) end, 'jj-flow: delete comment')
    map_visual(buf, km.add, function()
      local first = vim.fn.line 'v'
      local last = vim.fn.line '.'
      comments.add_for_range(session, first, last)
    end, 'jj-flow: comment on selection')
  end
  map(explorer_buf, 'j', function() explorer.move(session, 1) end, 'jj-flow: next file')
  map(explorer_buf, 'k', function() explorer.move(session, -1) end, 'jj-flow: previous file')
  map(explorer_buf, '<Down>', function() explorer.move(session, 1) end, 'jj-flow: next file')
  map(explorer_buf, '<Up>', function() explorer.move(session, -1) end, 'jj-flow: previous file')

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

---Close a specific review session (used by :JFix after Pi accepts the review).
---@param session jj-flow.ReviewSession
function M.close_session(session)
  if session then
    close_session(session)
  else
    M.close()
  end
end

---The review session of the current tab, if any. Useful for integration and
---tests.
---@return jj-flow.ReviewSession|nil
function M.current() return sessions[vim.api.nvim_get_current_tabpage()] end

return M
