-- Where is the cursor, for completion (lua/plugins/completion.lua)?
--
--  * M.region() -> { kind, lang }: kind is "comment", "string", "math",
--    "yaml", "prose" or "code"; lang is the treesitter language there, so an
--    R chunk in an Rmd reports "r", not "markdown".
--  * M.file_arg() -> { base_dir, exts, typed } when the cursor is in the
--    file-name argument of a call like read.csv("…") or pd.read_csv("…"), a
--    markdown link / image target, or a YAML file key (bibliography: …).
--    Used by the file-name source (lua/config/cmp-file-args.lua).
--  * M.open_calls() / M.given_args(): the calls the cursor is inside, and
--    the argument names already written in the innermost one.
--  * M.word_langs(): where each word of the buffer appears (prose, r, …).
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

-- dplyr/tidyr verbs whose arguments are columns of the data frame (first
-- argument or piped in). Used by the columns source (lua/config/cmp-columns.lua).
M.data_verbs = {
  "select",
  "rename",
  "mutate",
  "filter",
  "arrange",
  "group_by",
  "summarise",
  "summarize",
  "distinct",
  "count",
  "pull",
  "relocate",
  "transmute",
  "slice_max",
  "slice_min",
  "pivot_longer",
  "pivot_wider",
  "unite",
  "separate",
  "drop_na",
  "fill",
  "nest",
}

-- File keys in a YAML header -> extensions
local YAML_FILE_KEYS = {
  bibliography = { "bib", "json", "yaml" },
  csl = { "csl" },
  css = { "css" },
  in_header = ANY,
  before_body = ANY,
  after_body = ANY,
  reference_docx = { "docx" },
  template = ANY,
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
function M.base_dir(buf, fname)
  if fname == "here" then
    return vim.fs.root(buf, { ".here", ".git" }) or vim.fn.getcwd()
  end
  if require("config.rmd-latex-hl").handles(buf) then
    return vim.fs.dirname(vim.api.nvim_buf_get_name(buf))
  end
  return vim.fn.getcwd()
end

-- Markdown link / image targets and YAML file keys, in documents
local function doc_file_arg(buf, line, col)
  if not require("config.rmd-latex-hl").handles(buf) then
    return nil
  end
  local before = line:sub(1, col)
  local lang = lang_at(buf)
  local exts, start
  if lang == "markdown" or lang == "markdown_inline" then
    local bang
    bang, start = before:match("(!?)%[[^%]]*%]%(()[^)%s]*$")
    exts = bang == "!" and IMAGES or ANY
  elseif lang == "yaml" then
    local key
    key, start = before:match("^%s*([%w_]+):%s*[\"']?()[^\"']*$")
    exts = key and YAML_FILE_KEYS[key]
  end
  if not (start and exts) then
    return nil
  end
  return {
    base_dir = vim.fs.dirname(vim.api.nvim_buf_get_name(buf)),
    exts = exts,
    typed = before:sub(start),
  }
end

function M.file_arg(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local row, col = cursor()
  local line = vim.api.nvim_get_current_line()
  local doc = doc_file_arg(buf, line, col)
  if doc then
    return doc
  end
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
    base_dir = M.base_dir(buf, fname),
    exts = exts,
    typed = line:sub(start_col + 1, col), -- text after the quote, up to the cursor
  }
end

-- The text from up to `max_lines` lines back to the cursor, with string
-- contents blanked so their brackets, commas and `=` don't count
local function text_before_cursor(max_lines)
  local row, col = cursor()
  local lines = vim.api.nvim_buf_get_lines(0, math.max(0, row - max_lines), row + 1, false)
  lines[#lines] = lines[#lines]:sub(1, col)
  local text = table.concat(lines, "\n")
  return (text:gsub('"[^"\n]*"', '""'):gsub("'[^'\n]*'", "''"))
end

local OPENERS, CLOSERS = { ["("] = true, ["["] = true, ["{"] = true }, { [")"] = true, ["]"] = true, ["}"] = true }

-- Calls the cursor is inside, innermost first: { name, before, args },
-- where `name` is the function (without `pkg::`), `before` the text before
-- it and `args` the text from its `(` to the cursor. Plain text, because
-- the code being typed usually doesn't parse yet.
function M.open_calls()
  local text = text_before_cursor(30)
  local calls, depth = {}, 0
  for i = #text, 1, -1 do
    local ch = text:sub(i, i)
    if CLOSERS[ch] then
      depth = depth + 1
    elseif OPENERS[ch] then
      if depth > 0 then
        depth = depth - 1
      elseif ch == "(" then
        local head = text:sub(1, i - 1)
        local name = head:match("([%a._][%w._]*)%s*$")
        if name then
          calls[#calls + 1] = {
            name = name,
            before = head:sub(1, #head - #head:match("[%w._:]*%s*$")),
            args = text:sub(i + 1),
          }
        end
      end
    end
  end
  return calls
end

-- `args` text with everything inside nested brackets removed
local function top_level(args)
  local out, depth = {}, 0
  for ch in args:gmatch(".") do
    if OPENERS[ch] then
      depth = depth + 1
    elseif CLOSERS[ch] then
      depth = depth - 1
    elseif depth == 0 then
      out[#out + 1] = ch
    end
  end
  return table.concat(out)
end
M.top_level = top_level

-- Names of the arguments already given (`name =`) in the innermost call,
-- not counting the one being typed
function M.given_args()
  local call = M.open_calls()[1]
  local names = {}
  if not call then
    return names
  end
  local done = top_level(call.args):gsub("[^,]*$", "") -- drop the argument being typed
  for name in ("," .. done):gmatch(",%s*([%a._][%w._]*)%s*=[^=]") do
    names[name] = true
  end
  return names
end

-- word -> { [lang] = true } for every word in the buffer's prose ("prose"),
-- YAML header ("yaml") and code (identifiers and strings, per language).
-- Rebuilt at most once a second while typing; words that aren't in it yet
-- (just typed) are unknown, and callers keep them.
local WORD_QUERIES = {
  markdown_inline = "(inline) @w",
  yaml = "(flow_node) @w",
  default = "[(identifier) (string)] @w",
}
local word_cache = {}
function M.word_langs(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local tick, now = vim.b[buf].changedtick, vim.uv.now()
  local c = word_cache[buf]
  if c and (c.tick == tick or now - c.time < 1000) then
    return c.where
  end
  local where = {}
  local ok, parser = pcall(vim.treesitter.get_parser, buf, nil, { error = false })
  if ok and parser then
    parser:for_each_tree(function(tree, ltree)
      local lang = ltree:lang()
      if lang == "markdown" or lang == "latex" then
        return
      end
      local qok, query = pcall(vim.treesitter.query.parse, lang, WORD_QUERIES[lang] or WORD_QUERIES.default)
      if not qok then
        return
      end
      local key = lang == "markdown_inline" and "prose" or lang
      for _, node in query:iter_captures(tree:root(), buf) do
        for word in vim.treesitter.get_node_text(node, buf):gmatch("[%w_][%w_%-]*") do
          where[word] = where[word] or {}
          where[word][key] = true
        end
      end
    end)
  end
  word_cache[buf] = { tick = tick, time = now, where = where }
  return where
end

return M
