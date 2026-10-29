-- Code chunks in R Markdown / Quarto / markdown (and .ipynb via jupytext)
-- get a background (the colorscheme's CursorColumn colour, fences included)
-- and their language right-aligned on the opening fence. Chunks with
-- eval=FALSE / `#| eval: false` are drawn in the comment colour. (R.nvim did
-- this before lua/config/kernel/ replaced it.) The `#| key: value` chunk
-- options are highlighted as YAML by queries/{r,python}/injections.scm.

local chunks = require("config.kernel.chunks")

local M = {}

local ns = vim.api.nvim_create_namespace("chunk-hl")

local function set_highlights()
  local bg = vim.api.nvim_get_hl(0, { name = "CursorColumn", link = false }).bg
  local comment = vim.api.nvim_get_hl(0, { name = "Comment", link = false }).fg
  vim.api.nvim_set_hl(0, "CodeChunk", { bg = bg })
  vim.api.nvim_set_hl(0, "CodeChunkSkipped", { bg = bg, fg = comment })
end

function M.highlight(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_buf_call(buf, function()
    for _, c in ipairs(chunks.find(buf)) do
      local hl = chunks.is_skipped(c) and "CodeChunkSkipped" or "CodeChunk"
      vim.api.nvim_buf_set_extmark(buf, ns, c.s - 1, 0, {
        end_row = c.e,
        end_col = 0,
        hl_group = hl,
        hl_eol = true,
        virt_text = c.lang ~= "" and { { c.header:match("^```+%s*{?%s*([%w_]+)") .. " ", { hl, "Title" } } } or nil,
        virt_text_pos = "right_align",
      })
    end
  end)
end

function M.setup()
  set_highlights()
  local group = vim.api.nvim_create_augroup("ChunkHl", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = set_highlights })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = vim.tbl_keys(chunks.NOTEBOOK_FT),
    callback = function(ev)
      M.highlight(ev.buf)
      vim.api.nvim_clear_autocmds({ group = group, buffer = ev.buf })
      vim.api.nvim_create_autocmd({ "BufEnter", "InsertLeave", "TextChanged" }, {
        group = group,
        buffer = ev.buf,
        callback = function()
          M.highlight(ev.buf)
        end,
      })
    end,
  })
end

return M
