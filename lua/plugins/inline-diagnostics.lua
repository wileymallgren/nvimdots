return {
  "rachartier/tiny-inline-diagnostic.nvim",
  event = "VeryLazy",
  config = function()
    local diag = require("tiny-inline-diagnostic")
    local S = vim.diagnostic.severity

    local only_errors = { S.ERROR }
    local all = { S.ERROR, S.WARN, S.INFO, S.HINT }
    local show_all = false -- off by default

    -- Neovim's built-in virtual_text is turned off in lsp.lua
    diag.setup({ options = { severity = only_errors } })

    vim.keymap.set("n", "<leader>k", function()
      show_all = not show_all
      diag.change_severities(show_all and all or only_errors)
      vim.notify("Inline non-error diagnostics: " .. (show_all and "on" or "off"))
    end, { desc = "Toggle inline non-error diagnostics" })
  end,
}
