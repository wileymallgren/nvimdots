return {
  "nvim-treesitter/nvim-treesitter",
  branch = "main",
  lazy = false,
  build = ":TSUpdate",

  -- NOTE: the `main` branch no longer reads `opts.ensure_installed`,
  -- `opts.highlight` or `opts.indent` (those were the old `master` API), so
  -- installing parsers and starting highlighting is done explicitly below.
  config = function()
    local ts = require("nvim-treesitter")
    ts.setup({})

    -- Installs are async; parsers that are already installed are skipped.
    -- New parsers need a C compiler. `latex` is generated from its grammar,
    -- which needs tree-sitter-cli >= 0.26.1 (ABI 15). Older CLIs (e.g. on a
    -- remote server) abort with "can only generate parsers with ABI version
    -- 13 - 14, not 15", so latex is skipped there instead of erroring on
    -- every start.
    local function ts_cli_ok()
      if vim.fn.executable("tree-sitter") ~= 1 then
        return false
      end
      local r = vim.system({ "tree-sitter", "--version" }, { text = true }):wait()
      local maj, min, pat = (r.stdout or ""):match("(%d+)%.(%d+)%.(%d+)")
      if not maj then
        return false
      end
      maj, min, pat = tonumber(maj), tonumber(min), tonumber(pat)
      return maj > 0 or min > 26 or (min == 26 and pat >= 1)
    end

    local parsers = {
      "lua",
      "vim",
      "vimdoc",
      "bash",
      "json",
      "yaml",
      "markdown",
      "markdown_inline",
      "latex", -- LaTeX inside $...$, $$...$$ and raw \begin{...} blocks
      "python",
      "javascript",
      "typescript",
      "tsx",
      "html",
      "css",
      "rust",
      "go",
      "r",
      "cpp",
      "c",
      "java",
      "toml",
      "dockerfile",
      "sql",
      "regex",
      "julia",
    }
    if not ts_cli_ok() then
      parsers = vim.tbl_filter(function(l)
        return l ~= "latex"
      end, parsers)
      vim.schedule(function()
        vim.notify(
          "tree-sitter-cli < 0.26.1 or missing: skipping the latex parser (upgrade the CLI to enable it)",
          vim.log.levels.WARN
        )
      end)
    end
    ts.install(parsers)

    -- Rmd / Quarto are parsed with the markdown parsers
    vim.treesitter.language.register("markdown", { "rmd", "quarto" })

    -- Start treesitter highlighting for every filetype that has a parser
    vim.api.nvim_create_autocmd("FileType", {
      callback = function(args)
        local lang = vim.treesitter.language.get_lang(args.match) or args.match
        pcall(vim.treesitter.start, args.buf, lang) -- no-op if no parser
      end,
    })
  end,
}
