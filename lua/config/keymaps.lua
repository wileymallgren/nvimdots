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
