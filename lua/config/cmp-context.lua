-- Where is the cursor, for completion (lua/plugins/completion.lua)?
--
--  * M.region() -> { kind, lang }: kind is "comment", "string", "math",
--    "yaml", "prose" or "code"; lang is the treesitter language there, so an
--    R chunk in an Rmd reports "r", not "markdown".
--  * M.file_arg() -> { base_dir, exts, typed } when the cursor is in the
--    file-name argument of a call like read.csv("…") or pd.read_csv("…").
--    Used by the file-name source (lua/config/cmp-file-args.lua).
--
-- Everything reads the trees the highlighter has already parsed (no parse()),
-- so it stays cheap on large files.

local M = {}

-- Function name -> allowed file extensions (true = any file). Names are
-- matched without `pkg::` / `module.` prefixes. Add your own here.
local DATA = { "csv", "tsv", "txt" }
local IMAGES = { "png", "jpg", "jpeg", "pdf", "svg" }
local ANY = true
M.file_functions = {
  -- R
  ["read.csv"] = DATA,
  ["read.csv2"] = DATA,
  ["read.delim"] = DATA,
  ["read.table"] = DATA,
  read_csv = DATA, -- also pandas
  read_tsv = DATA,
  read_delim = DATA,
  fread = DATA,
  readRDS = { "rds" },
  read_rds = { "rds" },
  load = { "rda", "RData", "npy", "npz" }, -- R load() / numpy load()
  source = { "R" },
  read_excel = { "xlsx", "xls" }, -- also pandas
  read_xlsx = { "xlsx" },
  read_xls = { "xls" },
  read_parquet = { "parquet" }, -- also pandas
  fromJSON = { "json" },
  read_json = { "json" }, -- also pandas
  include_graphics = IMAGES,
  readLines = ANY,
  file = ANY,
  ["file.exists"] = ANY,
  saveRDS = ANY,
  ["write.csv"] = ANY,
  write_csv = ANY,
  ggsave = ANY,
  here = ANY,
  -- Python
  read_table = DATA,
  read_pickle = { "pkl", "pickle" },
  loadtxt = DATA,
  genfromtxt = DATA,
  imread = IMAGES,
  open = ANY, -- also Image.open
  Path = ANY,
  exists = ANY,
  savefig = ANY,
  to_csv = ANY,
}

-- Named arguments that take the file name (any position)
local FILE_ARG_NAMES =
  { file = true, path = true, filename = true, fname = true, con = true, filepath_or_buffer = true }

local function cursor()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  return row - 1, col -- 0-based row, byte column of the cursor
end

-- Node just before the cursor, looking into injected languages (chunks)
local function node_before_cursor(buf)
  local row, col = cursor()
  local ok, node = pcall(vim.treesitter.get_node, {
    bufnr = buf,
    pos = { row, math.max(col - 1, 0) },
    ignore_injections = false,
  })
  return ok and node or nil
end

local function lang_at(buf)
  local ok, parser = pcall(vim.treesitter.get_parser, buf, nil, { error = false })
  if not ok or not parser then
    return vim.bo[buf].filetype
  end
  local row, col = cursor()
  local c = math.max(col - 1, 0)
  return parser:language_for_range({ row, c, row, c }):lang()
end

local function find_up(node, pred)
  while node do
    if pred(node) then
      return node
    end
    node = node:parent()
  end
end

local function is_string(node)
  local t = node:type()
  return t == "string" or t == "string_content"
end

-- Unclosed $ before the cursor on this line (maths still being typed). Uses
-- pandoc's rules, so prices aren't maths: a $ opens only when followed by
-- something other than a space or digit ($x, $\alpha, not $5), and closes
-- only after a non-space and when not followed by a digit.
local function open_dollar(buf)
  local row, col = cursor()
  local masked = require("config.rmd-latex-hl").masked_lines(buf)[row + 1] or ""
  local before = masked:sub(1, col):gsub("\\%$", "  "):gsub("%$%$", "  ")
  local open = false
  for pos in before:gmatch("()%$") do
    local prev, next = before:sub(pos - 1, pos - 1), before:sub(pos + 1, pos + 1)
    if not open then
      open = not next:match("^[%s%d]$")
    elseif prev:match("%S") and not next:match("%d") then
      open = false
    end
  end
  return open
end

function M.region(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local lang = lang_at(buf)
  local node = node_before_cursor(buf)
  if find_up(node, function(n)
    return n:type():find("comment") ~= nil
  end) then
    return { kind = "comment", lang = lang }
  end

  local hl = require("config.rmd-latex-hl")
  if hl.handles(buf) then
    local row, col = cursor()
    if lang == "latex" or hl.in_math(buf, row + 1, math.max(col, 1)) or open_dollar(buf) then
      return { kind = "math", lang = "latex" }
    end
    if lang == "yaml" then
      return { kind = "yaml", lang = lang }
    end
    if lang == "markdown" or lang == "markdown_inline" then
      return { kind = "prose", lang = lang }
    end
  end

  if find_up(node, is_string) then
    return { kind = "string", lang = lang }
  end
  return { kind = "code", lang = lang }
end

-- Name of the called function, without `pkg::` or `module.` prefixes
local function call_name(call, buf)
  local fn = call:field("function")[1]
  if not fn then
    return nil
  end
  local t = fn:type()
  if t == "namespace_operator" then
    fn = fn:field("rhs")[1]
  elseif t == "attribute" then
    fn = fn:field("attribute")[1]
  end
  return fn and vim.treesitter.get_node_text(fn, buf)
end

-- Is `str` (a string node) the file argument of its call? Returns the call.
local function file_arg_call(str, buf)
  local parent = str:parent()
  if not parent then
    return nil
  end
  -- R: (call arguments: (arguments (argument name? value: (string))))
  if parent:type() == "argument" then
    local name = parent:field("name")[1]
    local args = parent:parent()
    local call = args and args:parent()
    if not (call and call:type() == "call") then
      return nil
    end
    if name then
      return FILE_ARG_NAMES[vim.treesitter.get_node_text(name, buf)] and call or nil
    end
    for arg in args:iter_children() do
      if arg:type() == "argument" and not arg:field("name")[1] then
        return arg:id() == parent:id() and call or nil -- first positional only
      end
    end
  -- Python: (call arguments: (argument_list (string) (keyword_argument name: value:)))
  elseif parent:type() == "keyword_argument" then
    local name = parent:field("name")[1]
    local call = parent:parent() and parent:parent():parent()
    if call and call:type() == "call" and name and FILE_ARG_NAMES[vim.treesitter.get_node_text(name, buf)] then
      return call
    end
  elseif parent:type() == "argument_list" then
    local call = parent:parent()
    for arg in parent:iter_children() do
      if arg:named() and arg:type() ~= "comment" then
        return arg:id() == str:id() and call or nil -- first positional only
      end
    end
  end
end

-- Relative paths in documents/notebooks resolve where knitr/Jupyter run
-- them (the file's folder); in scripts, from the project you opened.
local function base_dir(buf, fname)
  if fname == "here" then
    return vim.fs.root(buf, { ".here", ".git" }) or vim.fn.getcwd()
  end
  if require("config.rmd-latex-hl").handles(buf) then
    return vim.fs.dirname(vim.api.nvim_buf_get_name(buf))
  end
  return vim.fn.getcwd()
end

function M.file_arg(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local row, col = cursor()
  local line = vim.api.nvim_get_current_line()
  local str = find_up(node_before_cursor(buf), function(n)
    return n:type() == "string"
  end)
  local fname, start_col
  if str then
    local call = file_arg_call(str, buf)
    fname = call and call_name(call, buf)
    local sr, sc = str:range()
    if sr ~= row then
      return nil
    end
    -- skip the opening quote (and a Python prefix like f"/r")
    start_col = (line:find("[\"']", sc + 1) or sc + 1)
  else
    -- Unclosed string the parser can't make sense of yet: read.csv("da
    local name, quote = line:sub(1, col):match("([%w_%.]+)%(%s*()[\"'][^\"']*$")
    if not name then
      return nil
    end
    -- keep R names with dots (read.csv); otherwise drop `pd.` etc.
    fname = M.file_functions[name] and name or name:match("[^%.]+$")
    start_col = quote
  end
  local exts = fname and M.file_functions[fname]
  if not exts then
    return nil
  end
  return {
    base_dir = base_dir(buf, fname),
    exts = exts,
    typed = line:sub(start_col + 1, col), -- text after the quote, up to the cursor
  }
end

return M
