-- R integration (console, object browser, send code). Needs R in PATH.
return {
  "R-nvim/R.nvim",
  lazy = false,
  main = "r",
  opts = {
    R_args = { "--no-save", "--no-restore", "-q" },
    min_editor_width = 32,
  },
}
