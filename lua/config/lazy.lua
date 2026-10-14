-- Bootstrap lazy.nvim
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  local lazyrepo = "https://github.com/folke/lazy.nvim.git"
  local out = vim.fn.system({ "git", "clone", "--filter=blob:none", "--branch=stable", lazyrepo, lazypath })
  if vim.v.shell_error ~= 0 then
    vim.api.nvim_echo({
      { "Failed to clone lazy.nvim:\n", "ErrorMsg" },
      { out, "WarningMsg" },
      { "\nPress any key to exit..." },
    }, true, {})
    vim.fn.getchar()
    os.exit(1)
  end
end
vim.opt.rtp:prepend(lazypath)

-- mapleader / maplocalleader are set in lua/config/options.lua, which
-- init.lua loads before this file.

require("lazy").setup({
  spec = {
    { import = "plugins" },
  },
  -- colorscheme that will be used when installing plugins.
  install = { colorscheme = { "catppuccin", "habamax" } },
  -- automatically check for plugin updates
  checker = { enabled = true, notify = false },
  ui = {
    backdrop = 100, -- 100 = no dimming; lower it (e.g. 80-90) for a subtle effect
    border = "rounded", -- set explicitly: this version of lazy.nvim doesn't inherit vim.o.winborder
  },
})
