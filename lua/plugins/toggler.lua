return {
  "nguyenvukhang/nvim-toggler",
  keys = {
    {
      "<leader>i",
      function()
        require("nvim-toggler").toggle()
      end,
      mode = { "n", "v" },
      desc = "Toggle boolean",
    },
  },
  opts = {
    remove_default_keybinds = true,
  },
}
