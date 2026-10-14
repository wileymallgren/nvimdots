return {
  "hat0uma/csvview.nvim",
  ft = { "csv", "tsv" },
  cmd = { "CsvViewEnable", "CsvViewDisable", "CsvViewToggle" },
  keys = {
    { "<leader>cv", "<cmd>CsvViewToggle<CR>", desc = "Toggle CSV column view" },
  },
  opts = {
    parser = { comments = { "#", "//" } },
    view = { display_mode = "border" }, -- "highlight" for a lighter look
    keymaps = {
      -- text objects: a field (if/af), jump between fields
      textobject_field_inner = { "if", mode = { "o", "x" } },
      textobject_field_outer = { "af", mode = { "o", "x" } },
      jump_next_field_end = { "<Tab>", mode = { "n", "v" } },
      jump_prev_field_end = { "<S-Tab>", mode = { "n", "v" } },
    },
  },
}
