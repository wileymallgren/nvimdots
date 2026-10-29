-- Show a data frame saved as .tsv in a new tab laid out by csvview.nvim (the
-- header row stays at the top, lines don't wrap, the buffer is read-only).
-- Viewing the same file again reloads it in its window instead of opening a
-- second tab. The tab is labelled with the object's name (vim.b.r_df_name,
-- see lua/plugins/lualine.lua). Used by <localleader>rv (lua/config/kernel/objects.lua).

local M = {}

function M.open(path, name)
  -- resolve(): the buffer name has symlinks resolved (/var -> /private/var on macOS)
  local full = vim.fn.resolve(vim.fn.fnamemodify(path, ":p"))
  local win = vim.iter(vim.api.nvim_list_wins()):find(function(w)
    return vim.fn.resolve(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w))) == full
  end)
  if win then
    vim.api.nvim_set_current_win(win)
    vim.cmd.enew() -- wipes the old buffer (bufhidden=wipe)
    vim.cmd.edit(vim.fn.fnameescape(path))
  else
    vim.cmd.tabnew(vim.fn.fnameescape(path))
  end
  vim.bo.bufhidden = "wipe"
  vim.bo.modifiable = false
  vim.b.r_df_name = name or vim.fn.fnamemodify(path, ":t:r")
  vim.wo.wrap = false -- one row per line, scroll sideways for wide tables
  require("csvview").enable(0, { view = { header_lnum = 1 } })
end

return M
