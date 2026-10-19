return {
  "stevearc/conform.nvim",
  cmd = { "ConformInfo" },
  keys = {
    {
      "<leader>cc",
      function()
        require("conform").format({ async = true, lsp_format = "fallback" })
      end,
      desc = "Format buffer",
    },
  },
  opts = {
    formatters_by_ft = {
      lua = { "stylua" },
      python = { "ruff_format", "ruff_organize_imports" },
      rust = { "rustfmt" },
      go = { "gofmt", "goimports" },
      javascript = { "prettier" },
      typescript = { "prettier" },
      javascriptreact = { "prettier" },
      typescriptreact = { "prettier" },
      json = { "prettier" },
      yaml = { "prettier" },
      -- "injected" formats the code inside ``` chunks with the formatters
      -- below (python: ruff, r: styler). Notebooks (.ipynb opened as markdown
      -- by jupytext) skip prettier so the jupytext header is left alone.
      markdown = function(buf)
        if vim.api.nvim_buf_get_name(buf):match("%.ipynb$") then
          return { "injected" }
        end
        return { "prettier", "injected" }
      end,
      rmd = { "injected" },
      quarto = { "injected" },
      html = { "prettier" },
      css = { "prettier" },
      toml = { "prettier" },
      c = { "clang_format" },
      cpp = { "clang_format" },
      java = { "google_java_format" },
      sql = { "sqlfluff" },
      r = { "styler" },
    },
    formatters = {
      injected = {
        -- A chunk the formatter can't parse (e.g. `%matplotlib inline`) is
        -- left as is instead of failing the whole buffer
        options = { ignore_errors = true },
      },
    },
  },
}
