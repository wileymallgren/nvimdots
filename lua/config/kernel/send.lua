-- Send code from the buffer to its kernel; the console shows it and its
-- output. In R / Python scripts the kernel is the script's language; in
-- notebooks it is the chunk's (the code is limited to the chunk).
--   line       the whole statement on the cursor line (a multi-line call or
--              pipe chain is sent complete, found with treesitter)
--   selection  the visual selection (lines or characters)
--   paragraph  from the cursor down to the next blank line
--   fun        the top-level statement around the cursor (a function
--              definition, say)
--   file       the whole buffer (R / Python scripts)

local session = require("config.kernel.session")
local chunks = require("config.kernel.chunks")

local M = {}

-- Nodes whose children are separate statements
local BLOCKS = { program = true, module = true, braced_expression = true, brace_list = true, block = true }
local ROOTS = { program = true, module = true }

-- 0-based first and last row of the statement on `row`; `top` climbs to the
-- top-level one (through function bodies).
local function statement_rows(buf, row, top)
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  local col = line:find("%S")
  local ok, parser = pcall(vim.treesitter.get_parser, buf)
  if not col or not ok or not parser then
    return row, row
  end
  col = col - 1
  parser:parse({ row, row + 1 })
  local node = parser:named_node_for_range({ row, col, row, col }, { ignore_injections = false })
  if not node or ROOTS[node:type()] then
    return row, row
  end
  local stop = top and ROOTS or BLOCKS
  while node:parent() and not stop[node:parent():type()] do
    node = node:parent()
  end
  local sr, _, er, ec = node:range()
  if ec == 0 and er > sr then
    er = er - 1
  end
  return math.min(sr, row), math.max(er, row)
end

-- Remove the indentation all `lines` share (python needs it).
local function dedent(lines)
  local min
  for _, l in ipairs(lines) do
    if l:find("%S") then
      local n = #l:match("^%s*")
      min = math.min(min or n, n)
    end
  end
  if not min or min == 0 then
    return lines
  end
  return vim.tbl_map(function(l)
    return l:sub(min + 1)
  end, lines)
end

-- Language and allowed 1-based line range for code at `lnum`, or nil after
-- telling the user.
local function context(lnum)
  local lang = chunks.lang_at(lnum)
  if not lang then
    vim.notify("Not in R or Python code", vim.log.levels.WARN)
    return
  end
  if vim.bo.filetype == "r" or vim.bo.filetype == "python" then
    return lang, 1, vim.api.nvim_buf_line_count(0)
  end
  local c = chunks.at(lnum)
  return lang, c.s + 1, c.e - 1
end

-- Run `lines` of `lang` code in its kernel (starting it if needed).
function M.run(lang, lines, opts)
  lines = dedent(lines)
  while #lines > 0 and not lines[#lines]:find("%S") do
    table.remove(lines)
  end
  if #lines == 0 then
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  local k = session.ensure(lang, buf)
  if k then
    session.execute(k, table.concat(lines, "\n"), vim.tbl_extend("keep", opts or {}, { source = "send" }))
  end
end

-- Move to the first non-blank line after `lnum` (1-based), within `last`.
local function move_below(lnum, last)
  local n = lnum + 1
  while n < last and not (vim.fn.getline(n):find("%S")) do
    n = n + 1
  end
  vim.api.nvim_win_set_cursor(0, { math.min(n, vim.api.nvim_buf_line_count(0)), 0 })
end

local function send_rows(lang, first, last, s, e, move)
  first, last = math.max(first, s), math.min(last, e)
  M.run(lang, vim.api.nvim_buf_get_lines(0, first - 1, last, false))
  if move then
    move_below(last, e + 1)
  end
end

function M.line(move)
  local lnum = vim.fn.line(".")
  local lang, s, e = context(lnum)
  if not lang then
    return
  end
  local sr, er = statement_rows(0, lnum - 1)
  send_rows(lang, sr + 1, er + 1, s, e, move)
end

function M.fun()
  local lnum = vim.fn.line(".")
  local lang, s, e = context(lnum)
  if not lang then
    return
  end
  local sr, er = statement_rows(0, lnum - 1, true)
  send_rows(lang, sr + 1, er + 1, s, e)
end

function M.paragraph(move)
  local lnum = vim.fn.line(".")
  local lang, s, e = context(lnum)
  if not lang then
    return
  end
  local last = lnum
  while last < e and vim.fn.getline(last + 1):find("%S") do
    last = last + 1
  end
  send_rows(lang, lnum, last, s, e, move)
end

-- Call from a visual-mode mapping.
function M.selection(move)
  vim.cmd("normal! \27") -- leave visual mode so '< and '> are set
  local p1, p2 = vim.fn.getpos("'<"), vim.fn.getpos("'>")
  local lang, s, e = context(p1[2])
  if not lang then
    return
  end
  local mode = vim.fn.visualmode()
  if mode == "V" or mode == "\22" then
    send_rows(lang, p1[2], p2[2], s, e, move)
  else
    M.run(lang, vim.fn.getregion(p1, p2, { type = mode }))
    if move then
      move_below(p2[2], e + 1)
    end
  end
end

function M.file()
  local ft = vim.bo.filetype
  if ft == "r" or ft == "python" then
    M.run(ft, vim.api.nvim_buf_get_lines(0, 0, -1, false))
  end
end

return M
