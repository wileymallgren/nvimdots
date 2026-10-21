-- R integration (console, object browser, send code). Needs R in PATH.
return {
  "R-nvim/R.nvim",
  lazy = false,
  main = "r",
  opts = {
    R_args = { "--no-save", "--no-restore", "-q" },
    min_editor_width = 32,
    r_ls = {
      -- Functions whose arguments complete the columns of the data frame
      -- (first argument or piped in), with R running. The list is shared
      -- with the columns source in lua/config/cmp-context.lua.
      fun_data_1 = require("config.cmp-context").data_verbs,
    },
  },
}
