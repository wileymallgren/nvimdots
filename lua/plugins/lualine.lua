-- Molten kernel indicator: an icon while a kernel is attached to the current
-- buffer, and nothing (lualine hides empty components) otherwise.
local function molten_status()
  local ok, status = pcall(require, "molten.status")
  if not ok then
    return ""
  end
  local ok2, kernels = pcall(status.kernels)
  if not ok2 or kernels == nil or kernels == "" then
    return ""
  end
  return ""
end

-- Diff counts from gitsigns (already computed for the sign column) instead of
-- lualine running its own `git diff`.
local function gitsigns_diff()
  local d = vim.b.gitsigns_status_dict
  if d then
    return { added = d.added, modified = d.changed, removed = d.removed }
  end
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
            { molten_status, color = "Function" },
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
        tabline = {},
        winbar = {},
        inactive_winbar = {},
        extensions = {},
      })
    end,
  },
}
