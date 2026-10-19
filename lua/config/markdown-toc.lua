-- Markdown table of contents: pick a heading and jump to it.
--   <leader>fh     (markdown / rmd / quarto / notebooks) list headings
--   :MarkdownTOC   same, as a command
--
-- Headings come from the treesitter markdown tree, so `#` lines inside code
-- chunks are ignored and setext (=== / ---) headings are included. Shown in
-- Telescope with a preview; falls back to vim.ui.select if Telescope fails.

local M = {}

local FILETYPES = { "markdown", "rmd", "quarto" }

local function heading_text(node, bufnr)
  for child in node:iter_children() do
    local t = child:type()
    if t == "inline" or t == "paragraph" then
      return (vim.treesitter.get_node_text(child, bufnr):gsub("%s+", " "):gsub("^ ", ""):gsub("[ #]+$", ""))
    end
  end
  return ""
end

local function get_headings(bufnr)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "markdown")
  if not ok or not parser then
    return nil
  end
  local root = parser:parse()[1]:root()
  local query = vim.treesitter.query.parse("markdown", "[(atx_heading) (setext_heading)] @h")

  local headings = {}
  for _, node in query:iter_captures(root, bufnr) do
    local level
    for child in node:iter_children() do
      level = level or tonumber(child:type():match("^atx_h(%d)_marker$") or child:type():match("^setext_h(%d)_underline$"))
    end
    local row = node:start()
    local title = heading_text(node, bufnr)
    table.insert(headings, {
      level = level or 1,
      lnum = row + 1,
      title = title,
      display = string.rep("  ", (level or 1) - 1) .. string.rep("#", level or 1) .. " " .. title,
    })
  end
  return headings
end

local function jump(h)
  vim.api.nvim_win_set_cursor(0, { h.lnum, 0 })
  vim.cmd("normal! zz")
end

local function telescope_picker(bufnr, headings)
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values

  pickers
    .new({}, {
      prompt_title = "Markdown headings",
      finder = finders.new_table({
        results = headings,
        entry_maker = function(h)
          return {
            value = h,
            display = h.display,
            ordinal = h.title,
            bufnr = bufnr,
            filename = vim.api.nvim_buf_get_name(bufnr),
            lnum = h.lnum,
            col = 1,
          }
        end,
      }),
      sorter = conf.generic_sorter({}),
      previewer = conf.qflist_previewer({}),
    })
    :find()
end

function M.show()
  local bufnr = vim.api.nvim_get_current_buf()
  local headings = get_headings(bufnr)
  if not headings then
    vim.notify("Markdown TOC: no markdown treesitter parser for this buffer", vim.log.levels.WARN)
    return
  end
  if #headings == 0 then
    vim.notify("Markdown TOC: no headings found", vim.log.levels.INFO)
    return
  end

  local ok, err = pcall(telescope_picker, bufnr, headings)
  if ok then
    return
  end
  vim.notify("Markdown TOC: Telescope unavailable (" .. tostring(err) .. "), using vim.ui.select", vim.log.levels.DEBUG)
  vim.ui.select(headings, {
    prompt = "Markdown headings",
    format_item = function(h)
      return h.display
    end,
  }, function(h)
    if h then
      jump(h)
    end
  end)
end

function M.setup()
  vim.api.nvim_create_user_command("MarkdownTOC", M.show, { desc = "Pick a markdown heading and jump to it" })
  vim.api.nvim_create_autocmd("FileType", {
    group = vim.api.nvim_create_augroup("MarkdownTOC", { clear = true }),
    pattern = FILETYPES,
    callback = function(args)
      vim.keymap.set("n", "<leader>fh", M.show, { buffer = args.buf, desc = "Markdown headings (TOC)" })
    end,
  })
end

return M
