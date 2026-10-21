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
      -- (first argument or piped in), with R running. R.nvim's own four
      -- come first: it merges this list into its default by position.
      fun_data_1 = {
        "select",
        "rename",
        "mutate",
        "filter",
        "arrange",
        "group_by",
        "summarise",
        "summarize",
        "distinct",
        "count",
        "pull",
        "relocate",
        "transmute",
        "slice_max",
        "slice_min",
        "pivot_longer",
        "pivot_wider",
        "unite",
        "separate",
        "drop_na",
        "fill",
        "nest",
      },
    },
  },
}
