return {
  {
    "catppuccin/nvim",
    name = "catppuccin",
    priority = 1000,
    opts = {
      flavour = "mocha",
      custom_highlights = function(colors)
        return {
          -- Floats use the editor background with a blue border
          NormalFloat = { bg = colors.base },
          FloatBorder = { bg = colors.base, fg = colors.blue },
          FloatShadow = { bg = colors.base, blend = 0 },
          FloatShadowThrough = { bg = colors.base, blend = 0 },
          -- blink.cmp menu / docs / signature windows too
          BlinkCmpMenu = { bg = colors.base },
          BlinkCmpMenuBorder = { bg = colors.base, fg = colors.blue },
          BlinkCmpDoc = { bg = colors.base },
          BlinkCmpDocBorder = { bg = colors.base, fg = colors.blue },
          BlinkCmpSignatureHelp = { bg = colors.base },
          BlinkCmpSignatureHelpBorder = { bg = colors.base, fg = colors.blue },
          DiagnosticUnderlineError = { undercurl = true, sp = colors.red },
          -- nvim-tree uses the editor background (catppuccin defaults it to the darker mantle),
          -- with a normal split line so the tree doesn't blend into the buffer
          NvimTreeNormal = { fg = colors.text, bg = colors.base },
          NvimTreeWinSeparator = { fg = colors.crust, bg = colors.base },
        }
      end,
    },
    config = function(_, opts)
      require("catppuccin").setup(opts)
      vim.cmd.colorscheme("catppuccin")
    end,
  },
  {
    -- Colours the cursor line number by the current mode
    "mawkler/modicator.nvim",
    dependencies = "catppuccin",
    opts = {
      -- Needs cursorline, number and termguicolors, all set in lua/config/options.lua
      show_warnings = false,
    },
  },
}
