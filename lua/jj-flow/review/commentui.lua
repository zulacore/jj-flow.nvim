-- Comment input for the review UI.
--
-- A small, self-contained floating editor. It deliberately avoids nui.nvim (the
-- plugin has no UI dependency): a scratch buffer, one float, a handful of
-- keymaps.
--
-- The keymaps are configurable through `review_keymaps`:
--
--   comment_cycle   <Tab>   cycle the comment type (issue -> suggestion -> note)
--   comment_submit  <C-s>   save
--   comment_cancel  <Esc>   cancel
--
-- The border title always shows the current type and the active keys so the
-- selector is visible without occupying a buffer line.

local M = {}

local highlights = require 'jj-flow.review.highlights'
local config = require 'jj-flow.config'

---@type string[]
local TYPE_ORDER = { 'issue', 'suggestion', 'note' }

---@param key string|false|nil
---@return string|nil
local function key_hint(key)
  if type(key) ~= 'string' or key == '' then return nil end
  return (key:gsub('^<(.+)>$', '%1'))
end

---Open the comment editor.
---
---`on_submit` receives the chosen type and the non-empty text. It is not called
---when the editor is cancelled or left empty.
---@param opts { type?: string, text?: string }
---@param on_submit fun(type: string, text: string)
function M.open(opts, on_submit)
  opts = opts or {}

  -- A visual-mode mapping may invoke this before the selection is torn down.
  -- Leave visual mode synchronously so the float and its buffer start clean.
  local mode = vim.fn.mode()
  if mode == 'v' or mode == 'V' or mode == '\22' then vim.cmd 'normal! \27' end

  local cfg = config.get()
  local km = cfg.review_keymaps
  local type_index = 1
  for i, t in ipairs(TYPE_ORDER) do
    if t == opts.type then type_index = i end
  end

  local prev_win = vim.api.nvim_get_current_win()

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false

  local width = math.max(20, math.min(cfg.review_comment_width, vim.o.columns - 4))
  local height = math.max(3, math.min(cfg.review_comment_height, vim.o.lines - 4))
  local row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1)
  local col = math.max(0, math.floor((vim.o.columns - width) / 2))

  ---@type vim.api.keyset.win_config
  local win_config = {
    relative = 'editor',
    width = width,
    height = height,
    row = row,
    col = col,
    style = 'minimal',
    border = 'rounded',
    title = ' ',
    title_pos = 'center',
  }

  local win = vim.api.nvim_open_win(buf, true, win_config)

  local function set_title()
    local info = highlights.comment_types[TYPE_ORDER[type_index]]
    local parts = { info.name }
    local cycle_hint = key_hint(km.comment_cycle)
    local submit_hint = key_hint(km.comment_submit)
    if cycle_hint then parts[#parts + 1] = cycle_hint .. ' type' end
    if submit_hint then parts[#parts + 1] = submit_hint .. ' save' end
    win_config.title = ' ' .. table.concat(parts, '  ·  ') .. ' '
    pcall(vim.api.nvim_win_set_config, win, win_config)
  end

  local closed = false
  local function close()
    if closed then return end
    closed = true
    if vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
    if vim.api.nvim_buf_is_valid(buf) then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
    vim.schedule(function()
      if vim.api.nvim_win_is_valid(prev_win) then vim.api.nvim_set_current_win(prev_win) end
      vim.cmd 'stopinsert'
    end)
  end

  local function get_text()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    return (table.concat(lines, '\n'):gsub('%s+$', ''))
  end

  local function submit()
    local text = get_text()
    if text == '' then
      close()
      return
    end
    local chosen = TYPE_ORDER[type_index]
    close()
    on_submit(chosen, text)
  end

  local function cycle()
    type_index = type_index % #TYPE_ORDER + 1
    set_title()
  end

  local map_opts = { buffer = buf, silent = true, nowait = true }
  local function map_key(lhs, rhs)
    if type(lhs) == 'string' and lhs ~= '' then vim.keymap.set({ 'i', 'n' }, lhs, rhs, map_opts) end
  end

  map_key(km.comment_cycle, cycle)
  map_key(km.comment_submit, submit)
  map_key(km.comment_cancel, close)
  -- Non-configurable conveniences.
  vim.keymap.set('n', '<CR>', submit, map_opts)
  vim.keymap.set('i', '<C-c>', close, map_opts)

  if opts.text and opts.text ~= '' then vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(opts.text, '\n')) end

  set_title()
  vim.cmd 'startinsert'
end

return M
