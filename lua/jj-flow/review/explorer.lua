-- File explorer for the review tab: the "Changes" list on the left.
--
-- It renders the review model's file list with A/M/D statuses and keeps the
-- selection in sync with the session. It knows nothing about jj or Git.

local M = {}

local highlights = require 'jj-flow.review.highlights'

local STATUS_HL = {
  A = 'JjFlowStatusAdded',
  M = 'JjFlowStatusModified',
  D = 'JjFlowStatusDeleted',
}

---@param session jj-flow.ReviewSession
function M.create(session)
  local buf = session.explorer_buf
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'Changes' })
  vim.bo[buf].modifiable = false
end

---@param session jj-flow.ReviewSession
function M.render(session)
  local buf = session.explorer_buf
  if not vim.api.nvim_buf_is_valid(buf) then return end

  local lines = { 'Changes' }
  for _, file in ipairs(session.files) do
    lines[#lines + 1] = string.format(' %s %s', file.status, file.path)
  end

  local modifiable = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = modifiable

  vim.api.nvim_buf_clear_namespace(buf, highlights.ns_explorer, 0, -1)

  -- Header.
  vim.api.nvim_buf_set_extmark(buf, highlights.ns_explorer, 0, 0, {
    end_col = #lines[1],
    hl_group = 'JjFlowExplorerHeader',
  })

  for index, file in ipairs(session.files) do
    local row = index -- 0-based; row 0 is the header.
    if index == session.index then
      vim.api.nvim_buf_set_extmark(buf, highlights.ns_explorer, row, 0, {
        end_row = row + 1,
        end_col = 0,
        hl_group = 'JjFlowExplorerSelected',
        hl_eol = true,
        priority = 50,
      })
    end
    vim.api.nvim_buf_set_extmark(buf, highlights.ns_explorer, row, 1, {
      end_col = 1 + #file.status,
      hl_group = STATUS_HL[file.status] or 'Normal',
      priority = 100,
    })
  end

  if vim.api.nvim_win_is_valid(session.explorer_win) then pcall(vim.api.nvim_win_set_cursor, session.explorer_win, { session.index + 1, 0 }) end
end

---Move the selection by `delta` files, wrapping around, and open the result.
---@param session jj-flow.ReviewSession
---@param delta integer
function M.move(session, delta)
  local count = #session.files
  if count == 0 then return end
  local index = ((session.index - 1 + delta) % count) + 1
  session.select(index)
end

return M
