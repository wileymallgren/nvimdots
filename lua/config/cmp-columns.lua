-- blink.cmp source: column names of data frames read from files in this
-- buffer, without a running R session or Python kernel. After
--
--   df <- read.csv("data/cars.csv")        df = pd.read_csv("data/cars.csv")
--
-- the header of data/cars.csv is read and `df$`, `df[["`, `df |> select(`,
-- `ggplot(df, aes(`, `df["`, `df.groupby("` and `df.` offer its columns.
-- Frames made from another one (`d2 <- df |> mutate(kpl = …)`) get its
-- columns, plus the ones mutate/summarise/rename create. With R running,
-- R.nvim's own column items replace these (see source:enabled()).

local context = require("config.cmp-context")

local source = {}

function source.new()
  return setmetatable({}, { __index = source })
end

-- `$` in R, `.` in Python (df.col); quotes and `[` for df["col"]
function source:get_trigger_characters()
  local lang = context.region().lang
  return lang == "r" and { "$", '"', "'", "[" } or lang == "python" and { ".", '"', "'", "[" } or {}
end

-- Functions that read a delimited text file with a header row
local READERS = {}
for _, name in ipairs({
  "read.csv",
  "read.csv2",
  "read.delim",
  "read.delim2",
  "read.table",
  "read_csv",
  "read_csv2",
  "read_tsv",
  "read_delim",
  "read_table",
  "fread",
  "vroom",
}) do
  READERS[name] = true
end

-- Verbs that change which columns come out
local NEW_COLUMNS = { mutate = true, transmute = true, rename = true }
local SUMMARISE = { summarise = true, summarize = true, count = true, reframe = true }

local verbs = {}
for _, v in ipairs(context.data_verbs) do
  verbs[v] = true
end

-- Split one line of a delimited file, handling "quoted, fields"
local function split(line, delim)
  local fields, field, quoted = {}, {}, false
  for ch in (line .. delim):gmatch(".") do
    if ch == '"' then
      quoted = not quoted
    elseif ch == delim and not quoted then
      fields[#fields + 1] = vim.trim(table.concat(field))
      field = {}
    else
      field[#field + 1] = ch
    end
  end
  return fields
end

-- path -> { mtime, columns = { { name, example } } }
local header_cache = {}
local function read_header(path)
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= "file" then
    return nil
  end
  local c = header_cache[path]
  if c and c.mtime == stat.mtime.sec then
    return c.columns
  end
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local header = (f:read("*l") or ""):gsub("^\239\187\191", ""):gsub("\r$", "") -- no BOM / CR
  local first = (f:read("*l") or ""):gsub("\r$", "")
  f:close()
  -- Delimiter: the most common of tab, comma and semicolon; else whitespace
  local delim, most = nil, 0
  for _, d in ipairs({ "\t", ",", ";" }) do
    local n = select(2, header:gsub(d, ""))
    if n > most then
      delim, most = d, n
    end
  end
  local names, values
  if delim then
    names, values = split(header, delim), split(first, delim)
  else
    names, values = vim.split(vim.trim(header), "%s+"), vim.split(vim.trim(first), "%s+")
  end
  local columns = {}
  for i, name in ipairs(names) do
    if name ~= "" then
      columns[#columns + 1] = { name = name, example = values[i] }
    end
  end
  header_cache[path] = { mtime = stat.mtime.sec, columns = columns }
  return columns
end

-- The file a read call's text (after the `(`) names, or nil
local function file_of(buf, args)
  local path = args:match("^%s*[rf]?[\"']([^\"']+)[\"']") or args:match("^%s*file%s*=%s*[\"']([^\"']+)[\"']")
  if path then
    return vim.fs.joinpath(context.base_dir(buf, "read_csv"), path)
  end
  -- here("data", "cars.csv") / here::here("data/cars.csv"): from the project root
  local inner = args:match("^%s*here::here%((.-)%)") or args:match("^%s*here%((.-)%)")
  if inner then
    local parts = {}
    for p in inner:gmatch("[\"']([^\"']+)[\"']") do
      parts[#parts + 1] = p
    end
    return #parts > 0 and vim.fs.joinpath(context.base_dir(buf, "here"), unpack(parts)) or nil
  end
end

local function copy(cols)
  return vim.deepcopy(cols or {})
end

local function add(cols, name)
  for _, c in ipairs(cols) do
    if c.name == name then
      return
    end
  end
  cols[#cols + 1] = { name = name }
end

-- `name =` arguments at the top level of each `verb(…)` in `stmt`
local function verb_args(stmt, verb)
  local out = {}
  for args in stmt:gmatch("%f[%w._]" .. verb .. "%s*(%b())") do
    local top = context.top_level(args:sub(2, -2))
    for _, part in ipairs(vim.split(top, ",")) do
      out[#out + 1] = vim.trim(part)
    end
  end
  return out
end

-- Columns after a pipe chain that starts from `cols`
local function apply_verbs(stmt, cols)
  local summarised = false
  for verb in pairs(SUMMARISE) do
    if stmt:find("%f[%w._]" .. verb .. "%s*%(") then
      summarised = true
    end
  end
  if summarised then
    local out = {}
    for _, arg in ipairs(verb_args(stmt, "group_by")) do
      if arg:match("^[%a._][%w._]*$") then
        add(out, arg)
      end
    end
    for verb in pairs(SUMMARISE) do
      for _, arg in ipairs(verb_args(stmt, verb)) do
        local name = arg:match("^([%a._][%w._]*)%s*=[^=]")
        if name then
          add(out, name)
        elseif verb == "count" and arg:match("^[%a._][%w._]*$") then
          add(out, arg)
        end
      end
    end
    if stmt:find("%f[%w._]count%s*%(") then
      add(out, "n")
    end
    return out
  end
  -- select(a, b, c) with plain names only: exactly those
  local selected = verb_args(stmt, "select")
  if #selected > 0 then
    local plain = vim.tbl_filter(function(a)
      return a:match("^[%a._][%w._]*$") ~= nil
    end, selected)
    if #plain == #selected then
      local keep = {}
      for _, name in ipairs(plain) do
        local found = vim.tbl_filter(function(c)
          return c.name == name
        end, cols)[1]
        keep[#keep + 1] = found or { name = name }
      end
      cols = keep
    end
  end
  for verb in pairs(NEW_COLUMNS) do
    for _, arg in ipairs(verb_args(stmt, verb)) do
      local name, old = arg:match("^([%a._][%w._]*)%s*=%s*([%a._][%w._]*)%s*$")
      if verb == "rename" and name then
        for _, c in ipairs(cols) do
          if c.name == old then
            c.name = name
          end
        end
      else
        name = arg:match("^([%a._][%w._]*)%s*=[^=]")
        if name then
          add(cols, name)
        end
      end
    end
  end
  return cols
end

-- Statements of `lang` code from the top of the buffer to the cursor line,
-- pipe chains joined into one. In documents, only chunks in `lang`.
local function statements(buf, lang, last_row)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, last_row, false)
  local doc = require("config.rmd-latex-hl").handles(buf)
  local in_chunk = not doc
  local out, cur = {}, nil
  for _, line in ipairs(lines) do
    if doc then
      local fence_lang = line:match("^%s*```+%s*{?%s*([%w_]+)")
      if fence_lang then
        in_chunk = fence_lang:lower() == lang
        line = nil
      elseif line:match("^%s*```") then
        in_chunk = false
        line = nil
      end
    end
    if line and in_chunk then
      line = line:gsub("^%s*#.*$", ""):gsub("%s#.*$", "")
      cur = cur and (cur .. " " .. line) or line
      local open = select(2, cur:gsub("[%(%[{]", "")) - select(2, cur:gsub("[%)%]}]", ""))
      if open <= 0 and not line:match("[|>%%+,%(=-]%s*$") then
        out[#out + 1] = cur
        cur = nil
      end
    end
  end
  if cur then
    out[#out + 1] = cur
  end
  return out
end

-- name -> columns, for the frames defined above the cursor
local frames_cache = {}
local function frames(buf, lang)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local key = table.concat({ buf, lang, row, vim.b[buf].changedtick }, ":")
  if frames_cache.key == key then
    return frames_cache.value
  end
  local out = {}
  for _, stmt in ipairs(statements(buf, lang, row - 1)) do
    local name, rhs = stmt:match("^%s*([%a._][%w._]*)%s*<%-%s*(.*)$")
    if not name then
      name, rhs = stmt:match("^%s*([%a_][%w_]*)%s*=[^=]%s*(.*)$")
    end
    if name then
      local fn, args = rhs:match("^([%w._:]+)%s*%((.*)$")
      local short = fn and (fn:match("::(.*)$") or fn)
      if short and not READERS[short] then
        short = short:match("[^.]+$") -- pd.read_csv
      end
      -- y <- x |> …, y <- x, y = x.query(…), y = x[…]
      local first = rhs:match("^[%a._][%w._]*")
      if first and not out[first] then
        first = first:match("^[^.]+") -- Python: x.query -> x
      end
      local rest = first and rhs:sub(#first + 1) or ""
      local first_arg = args and args:match("^%s*([%a._][%w._]*)%s*[,)]")
      if short and READERS[short] then
        local path = file_of(buf, args)
        local cols = path and read_header(path)
        out[name] = cols and apply_verbs(rhs, copy(cols)) or nil
      elseif first and out[first] and (rest:match("^%s*[|%%.%[]") or rest:match("^%s*$")) then
        out[name] = apply_verbs(rhs, copy(out[first]))
      elseif first_arg and out[first_arg] then -- filter(df, …), pd.merge(df, …)
        out[name] = apply_verbs(rhs, copy(out[first_arg]))
      end
    end
    -- df$new <- …, df[["new"]] <- …, df["new"] = …
    local df, col = stmt:match("^%s*([%a._][%w._]*)%$([%a._][%w._]*)%s*<%-")
    if not df then
      local target = "^%s*([%a._][%w._]*)%[%[?%s*[\"']([^\"']+)[\"']%s*%]%]?%s*"
      df, col = stmt:match(target .. "<%-")
      if not df then
        df, col = stmt:match(target .. "=[^=]")
      end
    end
    if df and out[df] then
      add(out[df], col)
    end
  end
  frames_cache.key, frames_cache.value = key, out
  return out
end

-- Start of an unclosed string before the cursor: index of its quote
local function open_quote(before)
  local quote, at
  for i = 1, #before do
    local ch = before:sub(i, i)
    if quote then
      if ch == quote and before:sub(i - 1, i - 1) ~= "\\" then
        quote = nil
      end
    elseif ch == '"' or ch == "'" then
      quote, at = ch, i
    end
  end
  return quote and at or nil
end

-- The data frame a pipe chain starts from, given the text before the
-- current step: `df |> filter(x > 1) |>` -> df. Steps are walked back
-- from the end: drop the pipe, then the call before it, and so on.
local function chain_root(text)
  local t = text
  for _ = 1, 50 do
    local stripped = t:gsub("%s*|>%s*$", ""):gsub("%s*%%>%%%s*$", "")
    if stripped == t then
      return nil -- not piped
    end
    t = stripped
    if t:sub(-1) ~= ")" then
      return t:match("([%a._][%w._]*)%s*$")
    end
    local depth, i = 0, #t
    while i > 0 do
      local ch = t:sub(i, i)
      depth = depth + (ch == ")" and 1 or ch == "(" and -1 or 0)
      if depth == 0 then
        break
      end
      i = i - 1
    end
    t = t:sub(1, i - 1):gsub("[%w._:]+%s*$", "")
  end
end

-- { df, partial, quoted } for the cursor, or nil
local function find_context(lang, before)
  local q = open_quote(before)
  if q then
    local pre, partial = before:sub(1, q - 1), before:sub(q + 1)
    local df = pre:match("([%a._][%w._]*)%[%[?[^%[%]]*$") -- df["  df[["  df[, "
    if not df and lang == "python" then
      df = pre:match("([%a_][%w_]*)%.[%a_][%w_]*%([^()]*$") -- df.groupby("
    end
    return df and { df = df, partial = partial, quoted = true }
  end
  if lang == "r" then
    local df, partial = before:match("([%a._][%w._]*)%$([%w._]*)$")
    if df then
      return { df = df, partial = partial, dollar = true }
    end
    -- Inside a data verb or aes(): the frame it works on
    partial = before:match("[%w._]*$")
    for _, call in ipairs(context.open_calls()) do
      local name = call.name:match("[^:]+$")
      if verbs[name] then
        local first = call.args:match("^%s*([%a._][%w._]*)%s*,")
        local root = chain_root(call.before) or first
        if root then
          return { df = root, partial = partial }
        end
      elseif name == "aes" then
        -- The last ggplot( before it: ggplot(df, aes(, ggplot(data = df,
        -- ggplot(df) + geom_point(aes(, df |> ggplot(aes(
        local pos
        for p in call.before:gmatch("()ggplot%s*%(") do
          pos = p
        end
        if pos then
          local args = call.before:sub(pos):match("^ggplot%s*%((.*)$")
          local root = args:match("^%s*data%s*=%s*([%a._][%w._]*)")
            or args:match("^%s*([%a._][%w._]*)%s*[,)]")
            or chain_root(call.before:sub(1, pos - 1))
          if root then
            return { df = root, partial = partial }
          end
        end
      end
    end
  elseif lang == "python" then
    local df, partial = before:match("([%a_][%w_]*)%.([%w_]*)$")
    if df then
      return { df = df, partial = partial, attribute = true }
    end
  end
end

-- R code with R running gets the columns from R.nvim instead (it knows
-- every frame in the session, not only ones read from files)
function source:enabled()
  local lang = context.region().lang
  return lang == "python" or (lang == "r" and (vim.g.R_Nvim_status or 0) < 7)
end

local EMPTY = { items = {}, is_incomplete_forward = false, is_incomplete_backward = false }

-- Columns for the cursor: cols, context, lang (or nil)
local function lookup(ctx)
  if not source.enabled() then
    return nil
  end
  local lang = context.region(ctx.bufnr).lang
  local before = ctx.line:sub(1, ctx.cursor[2])
  local found = find_context(lang, before)
  local cols = found and frames(ctx.bufnr, lang)[found.df]
  if cols then
    return cols, found, lang
  end
end

-- For the LSP transform in completion.lua: where columns are known, the
-- names they replace. `only` = after df$ or in df["…"], where nothing but a
-- column fits, so the language server's guesses can go.
function source.known_here(ctx)
  local cols, found = lookup(ctx)
  if not cols then
    return nil
  end
  local names = {}
  for _, c in ipairs(cols) do
    names[c.name] = true
  end
  return { names = names, only = found.dollar or found.quoted }
end

function source:get_completions(ctx, callback)
  local cols, found, lang = lookup(ctx)
  if not cols then
    return callback(EMPTY)
  end
  local row, col = ctx.cursor[1] - 1, ctx.cursor[2]
  local range = { start = { line = row, character = col - #found.partial }, ["end"] = { line = row, character = col } }
  local kind = require("blink.cmp.types").CompletionItemKind.Field
  local items = {}
  for i, c in ipairs(cols) do
    local syntactic = c.name:match("^[%a._][%w._]*$") and not c.name:match("^[.]%d")
    if not (found.attribute and not c.name:match("^[%a_][%w_]*$")) then
      local text = c.name
      if lang == "r" and not found.quoted and not syntactic then
        text = "`" .. c.name .. "`"
      end
      items[#items + 1] = {
        label = c.name,
        kind = kind,
        filterText = c.name,
        labelDetails = c.example and { description = c.example:sub(1, 20) } or nil,
        documentation = "Column of `" .. found.df .. "`",
        textEdit = { newText = text, range = range },
        sortText = string.format("%04d", i), -- file order
      }
    end
  end
  callback({ items = items, is_incomplete_forward = false, is_incomplete_backward = false })
end

return source
