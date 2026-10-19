-- otter.nvim: LSP (basedpyright, ruff) inside ```python chunks of markdown,
-- R Markdown, Quarto and notebooks. Completion reaches blink.cmp through its
-- normal `lsp` source. R chunks don't need it: r_language_server attaches to
-- rmd buffers directly. Activated when a buffer with a python chunk is opened
-- (or first saved with one).
local FILETYPES = { "markdown", "rmd", "quarto" }

local function has_python_chunk(buf)
  for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if l:match("^```+%s*{?%s*python") then
      return true
    end
  end
  return false
end

return {
  "jmbuhr/otter.nvim",
  ft = FILETYPES,
  dependencies = { "nvim-treesitter/nvim-treesitter" },
  opts = {},
  config = function(_, opts)
    local otter = require("otter")
    otter.setup(opts)

    local function activate(buf)
      if
        vim.api.nvim_buf_is_valid(buf)
        and vim.tbl_contains(FILETYPES, vim.bo[buf].filetype)
        and not vim.b[buf].otter_activated
        and has_python_chunk(buf)
      then
        vim.b[buf].otter_activated = true
        vim.api.nvim_buf_call(buf, function()
          otter.activate({ "python" })
        end)
      end
    end

    local group = vim.api.nvim_create_augroup("OtterActivate", { clear = true })
    vim.api.nvim_create_autocmd("FileType", {
      group = group,
      pattern = FILETYPES,
      callback = function(ev)
        activate(ev.buf)
      end,
    })
    vim.api.nvim_create_autocmd("BufWritePost", {
      group = group,
      callback = function(ev)
        activate(ev.buf)
      end,
    })
    -- The buffer that triggered loading this plugin already had its FileType
    activate(vim.api.nvim_get_current_buf())
  end,
}
