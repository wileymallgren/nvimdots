-- lua_ls knowledge of the Neovim runtime and installed plugins, loaded only
-- for the libraries a file actually requires. Completion reaches blink.cmp
-- through the `lazydev` source (completion.lua).
return {
  "folke/lazydev.nvim",
  ft = "lua",
  opts = {
    library = {
      { path = "${3rd}/luv/library", words = { "vim%.uv" } },
    },
  },
}
