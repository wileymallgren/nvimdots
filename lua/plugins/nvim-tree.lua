-- Sidebar file tree. (oil.nvim is the default directory browser on `-`.)
return {
  "nvim-tree/nvim-tree.lua",
  dependencies = { "nvim-tree/nvim-web-devicons" },
  keys = {
    {
      "<leader>e",
      function()
        require("nvim-tree.api").tree.toggle()
      end,
      desc = "Toggle file tree",
    },
  },
  opts = {},
}
