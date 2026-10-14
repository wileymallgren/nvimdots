-- Leader keys must be set before lazy.nvim loads so plugin mappings use them.
vim.g.mapleader = " "
vim.g.maplocalleader = "\\"

-- Give every floating window (Lazy, Telescope, LSP hover, diagnostics, etc.)
-- a visible border by default.
vim.o.winborder = "rounded"

vim.o.number = true
vim.o.relativenumber = true
vim.o.tabstop = 4
vim.o.shiftwidth = 4 -- indent size for >>, <<, and auto-indent
vim.o.softtabstop = 4 -- Tab/Backspace act like 4 spaces
vim.o.expandtab = true -- insert spaces instead of literal tab characters
vim.o.signcolumn = "yes"
vim.o.undofile = true
vim.o.updatetime = 250
vim.o.scrolloff = 8
vim.o.cursorline = true
vim.o.termguicolors = true
vim.o.confirm = true
vim.o.inccommand = "split"

-- Soft wrapping
vim.o.wrap = true
vim.o.linebreak = true -- break at word boundaries, not mid-word
vim.o.breakindent = true -- wrapped lines keep the original line's indentation
vim.o.breakindentopt = "shift:2,sbr" -- indent continuations 2 extra spaces; put showbreak after the indent
vim.o.showbreak = "↪ " -- visual marker on continuation lines
vim.o.smoothscroll = true -- scroll by screen line instead of skipping whole wrapped lines

-- Case-insensitive searching UNLESS \C or one or more capital letters in the search term
vim.o.ignorecase = true
vim.o.smartcase = true

-- Configure how new splits should be opened
vim.o.splitright = true
vim.o.splitbelow = true
