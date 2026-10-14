-- toggleterm.nvim: persistent, toggleable terminals
--   <C-\>          toggle terminal (n/i/t modes; prefix a count, e.g. 2<C-\>, for terminal #2)
--   <leader>tt     floating terminal
--   <leader>th     horizontal split terminal
--   <leader>tv     vertical split terminal
--   <leader>tp     pick an open terminal
--   <leader>tl     send current line to terminal
--   <leader>ts     (visual) send selection to terminal
--   <Esc><Esc>     (terminal mode) back to normal mode
return {
  "akinsho/toggleterm.nvim",
  version = "*",
  cmd = { "ToggleTerm", "TermExec", "TermSelect", "ToggleTermToggleAll" },
  keys = {
    { [[<C-\>]], mode = { "n", "i" }, desc = "Toggle terminal" },
    { "<leader>tt", "<cmd>ToggleTerm direction=float<cr>", desc = "Float terminal" },
    { "<leader>th", "<cmd>ToggleTerm direction=horizontal<cr>", desc = "Horizontal terminal" },
    { "<leader>tv", "<cmd>ToggleTerm direction=vertical<cr>", desc = "Vertical terminal" },
    { "<leader>tp", "<cmd>TermSelect<cr>", desc = "Select terminal" },
    { "<leader>tl", "<cmd>ToggleTermSendCurrentLine<cr>", desc = "Send line to terminal" },
    { "<leader>ts", ":ToggleTermSendVisualSelection<cr>", mode = "v", desc = "Send selection to terminal" },
  },
  opts = {
    open_mapping = [[<C-\>]],
    direction = "float",
    size = function(term)
      if term.direction == "horizontal" then
        return 15
      elseif term.direction == "vertical" then
        return math.floor(vim.o.columns * 0.4)
      end
    end,
    shade_terminals = false,
    start_in_insert = true,
    insert_mappings = true, -- <C-\> works from insert mode
    terminal_mappings = true, -- <C-\> works from inside the terminal
    persist_size = true,
    persist_mode = true,
    close_on_exit = true,
    float_opts = {
      border = "rounded", -- match vim.o.winborder
      width = function()
        return math.floor(vim.o.columns * 0.85)
      end,
      height = function()
        return math.floor(vim.o.lines * 0.8)
      end,
      winblend = 0,
    },
    winbar = { enabled = false },
    highlights = {
      -- toggleterm links its border to Normal by default; use the theme's float border
      FloatBorder = { link = "FloatBorder" },
    },
  },
  config = function(_, opts)
    require("toggleterm").setup(opts)

    -- <C-\> is now the toggle key, which shadows Neovim's built-in <C-\><C-n>,
    -- so give toggleterm buffers another way back to normal mode.
    vim.api.nvim_create_autocmd("TermOpen", {
      pattern = "term://*toggleterm#*",
      callback = function(ev)
        vim.keymap.set("t", "<Esc><Esc>", [[<C-\><C-n>]], { buffer = ev.buf, desc = "Terminal normal mode" })
      end,
    })
  end,
}
