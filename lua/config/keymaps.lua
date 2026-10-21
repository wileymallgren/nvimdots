-- General keymaps. Plugin-specific mappings live in their plugin spec
-- (`keys = { ... }`) under lua/plugins/.

-- Disable mouse/trackpad scrolling (opinionated: remove this block to keep it)
for _, modifier in ipairs({ "", "S-", "C-" }) do
  for _, direction in ipairs({ "Up", "Down", "Left", "Right" }) do
    for _, mode in ipairs({ "", "i" }) do
      vim.keymap.set(mode, "<" .. modifier .. "ScrollWheel" .. direction .. ">", "<Nop>")
    end
  end
end

-- Clear highlights on search when pressing <Esc> in normal mode
--  See `:help hlsearch`
vim.keymap.set("n", "<Esc>", "<cmd>nohlsearch<CR>", { desc = "Clear search highlight" })

-- System clipboard yank and delete
vim.keymap.set({ "n", "x" }, "<leader>y", '"+y', { desc = "Copy to clipboard" })
vim.keymap.set({ "n", "x" }, "<leader>d", '"+d', { desc = "Delete to clipboard" })

-- Change directory to current file
vim.keymap.set("n", "<leader>cd", "<cmd>cd %:p:h<CR><cmd>pwd<CR>", { desc = "Change directory to current file" })

-- Accept LSP fixes (lintr via r_language_server, ruff). `gra` still opens the
-- full menu, including the "disable for this line" actions.
-- The servers only fix the diagnostics they're sent, and by default Neovim
-- sends just those under the cursor column, so pass them explicitly.
local function lsp_diagnostics(opts)
  local diags = {}
  for _, d in ipairs(vim.diagnostic.get(0, opts)) do
    diags[#diags + 1] = d.user_data and d.user_data.lsp or nil
  end
  return diags
end
vim.keymap.set("n", "<leader>ca", function()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  vim.lsp.buf.code_action({
    apply = true, -- no menu when there's exactly one preferred fix
    context = { only = { "quickfix" }, diagnostics = lsp_diagnostics({ lnum = line - 1 }) },
    range = { start = { line, 0 }, ["end"] = { line, #vim.api.nvim_get_current_line() } },
    filter = function(a)
      return a.isPreferred
    end,
  })
end, { desc = "Apply fix on this line" })
vim.keymap.set("n", "<leader>cA", function()
  local diags = lsp_diagnostics()
  vim.lsp.buf.code_action({
    apply = true,
    context = { only = { "source.fixAll" }, diagnostics = diags },
    range = { start = { 1, 0 }, ["end"] = { vim.api.nvim_buf_line_count(0), 0 } },
  })
end, { desc = "Fix all auto-fixable problems" })
