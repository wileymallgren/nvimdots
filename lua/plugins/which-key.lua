-- Group labels and icons. Icons need a Nerd Font; which-key also picks icons
-- for many other keymaps automatically from their descriptions.
return {
  {
    "folke/which-key.nvim",
    event = "VeryLazy",
    opts = {
      win = {
        border = "rounded", -- explicit: which-key defaults this to "none", ignoring vim.o.winborder
      },
      layout = {
        width = { min = 0 },
      },
      preset = "helix",
      title_pos = "bottom",
      spec = {
        -- Groups
        { "<leader>f", group = "Find", icon = { icon = "", color = "green" } },
        { "<leader>g", group = "Git", icon = { cat = "filetype", name = "git" } },
        { "<leader>r", group = "Render LaTeX / markdown", icon = { cat = "filetype", name = "tex" } },
        { "<leader>rl", group = "LaTeX only", icon = { cat = "filetype", name = "tex" } },
        { "<leader>t", group = "Terminal", icon = { icon = "", color = "red" } },
        { "<leader>R", group = "Remote", icon = { icon = "", color = "blue" } },
        { "<leader>c", group = "Code / cwd", icon = { icon = "", color = "orange" } },
        { "<localleader>m", group = "Molten (R chunks)", icon = { cat = "filetype", name = "r" } },
        { "<localleader>k", group = "Knit", icon = { cat = "extension", name = "rmd" } },
        -- Render (lua/config/tex-preview.lua)
        { "<leader>rp", mode = { "n", "v" }, icon = { icon = "", color = "azure" } },
        { "<leader>rm", mode = { "n", "v" }, icon = { cat = "filetype", name = "markdown" } },
        { "<leader>ra", icon = { cat = "filetype", name = "tex" } },
        { "<leader>rs", icon = { cat = "filetype", name = "tex" } },
        { "<leader>rla", icon = { cat = "filetype", name = "tex" } },
        { "<leader>rls", icon = { cat = "filetype", name = "tex" } },
        { "<leader>rr", icon = { icon = "", color = "yellow" } },
        { "<leader>rw", icon = { icon = "", color = "yellow" } },
        { "<leader>rx", icon = { icon = "", color = "red" } },
        { "<leader>rc", icon = { icon = "", color = "red" } },
        { "<leader>r+", icon = { icon = "", color = "green" } },
        { "<leader>r-", icon = { icon = "", color = "green" } },
        { "<leader>rt", icon = { icon = "", color = "purple" } },
        { "<leader>ro", icon = { cat = "extension", name = "pdf" } },
        { "<leader>re", icon = { icon = "", color = "grey" } },
        -- Everything else
        { "<leader>e", icon = { icon = "", color = "cyan" } },
        { "<leader>m", icon = { icon = "", color = "cyan" } },
        { "<leader>y", mode = { "n", "x" }, icon = { icon = "", color = "yellow" } },
        { "<leader>d", mode = { "n", "x" }, icon = { icon = "", color = "yellow" } },
        { "<leader>cd", icon = { icon = "", color = "blue" } },
        { "<leader>cc", icon = { icon = "", color = "cyan" } },
        { "<leader>cv", icon = { cat = "filetype", name = "csv" } },
        { "<leader>a", icon = { icon = "", color = "purple" } },
        { "<leader>A", icon = { icon = "", color = "purple" } },
      },
    },
  },
}
