-- Kernel indicator (lua/config/kernel/): one entry per running kernel, R's
-- or Python's icon, "…" while it starts or runs code, "(hidden)" when its
-- console is hidden (<localleader>rH). Empty (hidden by lualine) otherwise.
local KERNEL_ICONS = { r = "󰟔 R", python = " Py" }
local function kernel_status()
  if not package.loaded["config.kernel.session"] then
    return ""
  end
  local parts = {}
  for _, k in ipairs(require("config.kernel.session").list()) do
    local text = KERNEL_ICONS[k.lang] or k.label
    if k.state == "starting" or k.state == "busy" then
      text = text .. "…"
    elseif not require("config.kernel.console").visible(k) then
      text = text .. " (hidden)"
    end
    parts[#parts + 1] = text
  end
  table.sort(parts)
  return table.concat(parts, "  ")
end

-- Diff counts from gitsigns (already computed for the sign column) instead of
-- lualine running its own `git diff`.
local function gitsigns_diff()
  local d = vim.b.gitsigns_status_dict
  if d then
    return { added = d.added, modified = d.changed, removed = d.removed }
  end
end

-- The window a tab is "on": its current one, or while a float (Telescope,
-- which-key, ...) has focus, the window it was opened from.
local function tab_window(tab)
  local win = vim.api.nvim_tabpage_get_win(tab.tabId)
  local function is_float(w)
    return vim.api.nvim_win_get_config(w).relative ~= ""
  end
  if not is_float(win) then
    return win, false
  end
  local prev = vim.fn.win_getid(vim.fn.tabpagewinnr(tab.tabnr, "#"), tab.tabnr)
  if prev ~= 0 and not is_float(prev) then
    return prev, true
  end
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tab.tabId)) do
    if not is_float(w) then
      return w, true
    end
  end
  return win, false
end

-- Tab label: number, file icon, name, and a dot if the tab's current buffer
-- has unsaved changes. A data frame opened with <localleader>rv
-- (lua/config/r-view-df.lua) shows the object's name instead of its .tsv file.
local function tab_label(name, tab)
  local win, from_float = tab_window(tab)
  local buf = vim.api.nvim_win_get_buf(win)
  if from_float then -- lualine named the tab after the float's buffer
    local file = vim.api.nvim_buf_get_name(buf)
    if vim.bo[buf].buftype == "terminal" then
      name = file:match("term:.*:(%a+)") or vim.fn.fnamemodify(vim.env.SHELL, ":t")
    else
      name = file == "" and "[No Name]" or vim.fn.fnamemodify(file, ":t")
    end
  end
  local icon
  if vim.b[buf].r_df_name then
    icon, name = "󰓫", vim.b[buf].r_df_name
  elseif vim.bo[buf].buftype == "terminal" then
    icon = ""
  else
    icon = require("nvim-web-devicons").get_icon(name, nil, { default = true })
  end
  local label = ("%d %s %s"):format(tab.tabnr, icon, name)
  return vim.bo[buf].modified and label .. " ●" or label
end

return {
  {
    "nvim-lualine/lualine.nvim",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    config = function()
      require("lualine").setup({
        options = {
          icons_enabled = true,
          theme = "auto",
          component_separators = { left = "", right = "" },
          section_separators = { left = "", right = "" },
          disabled_filetypes = {
            statusline = { "alpha", "dashboard" }, -- Hides lualine on alpha dashboard
            winbar = {},
          },
          always_divide_middle = true,
          globalstatus = true,
          always_show_tabline = true, -- even with a single tab
        },
        sections = {
          lualine_a = { "mode" },
          lualine_b = { "branch", { "diff", source = gitsigns_diff }, "diagnostics" },
          lualine_c = { "filename" },
          lualine_x = {
            -- Shown only inside a remote-nvim session (the remote sets this global)
            {
              function()
                return "󰒍 remote"
              end,
              cond = function()
                return vim.g.remote_neovim_host == true
              end,
              color = "DiagnosticError",
            },
            { kernel_status, color = "Function" },
            "encoding",
            "fileformat",
            "filetype",
          },
          lualine_y = { "progress" },
          lualine_z = {
            "location",
          },
        },
        inactive_sections = {
          lualine_a = {},
          lualine_b = {},
          lualine_c = { "filename" },
          lualine_x = { "location" },
          lualine_y = {},
          lualine_z = {},
        },
        tabline = {
          lualine_a = {
            {
              "tabs",
              mode = 1, -- name only; tab_label adds the number
              max_length = function()
                return vim.o.columns
              end,
              show_modified_status = false, -- tab_label shows it
              fmt = tab_label,
            },
          },
        },
        winbar = {},
        inactive_winbar = {},
        extensions = {},
      })
    end,
  },
}
