-- blink.cmp source: column names of data frames read from files in this
-- buffer, without a running R session or Python kernel. After
--
--   df <- read.csv("data/cars.csv")        df = pd.read_csv("data/cars.csv")
--
-- the header of data/cars.csv is read and `df$`, `df[["`, `df |> select(`,
-- `ggplot(df, aes(`, `df["`, `df.groupby("` and `df.` offer its columns.
-- Where a column is compared (`filter(species == "`, `df["sex"] == "`)
-- its values are offered instead (source.value_context).
-- Frames made from another one (`d2 <- df |> mutate(kpl = …)`) get its
-- columns, plus the ones mutate/summarise/rename create. With the R / Python
-- kernel running (lua/config/kernel/), the columns come from the session
-- instead, so every frame works, not only ones read from files.

local context = require("config.cmp-context")

local source = {}

function source.new()
  return setmetatable({}, { __index = source })
end

-- `$` in R, `.` in Python (df.col); quotes and `[` for df["col"]. Space
-- too, for the values after `sex == ` (blink blocks it everywhere else,
-- see show_on_blocked_trigger_characters in completion.lua)
function source:get_trigger_characters()
  local lang = context.region().lang
  return lang == "r" and { "$", '"', "'", "[", " " } or lang == "python" and { ".", '"', "'", "[", " " } or {}
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

-- One line's fields: split() when it has quotes, a plain split otherwise
-- (much faster on the thousands of lines read_values goes through)
local function fields(line, delim)
  if not delim then
    return vim.split(vim.trim(line), "%s+")
  elseif line:find('"', 1, true) then
    return split(line, delim)
  end
  local out = vim.split(line, delim, { plain = true })
  for i, f in ipairs(out) do
    out[i] = vim.trim(f)
  end
  return out
end

-- Delimiter of a header line: the most common of tab, comma and
-- semicolon; nil for whitespace
local function delimiter(header)
  local delim, most = nil, 0
  for _, d in ipairs({ "\t", ",", ";" }) do
    local n = select(2, header:gsub(d, ""))
    if n > most then
      delim, most = d, n
    end
  end
  return delim
end

-- path -> { mtime, columns = { { name, example, path, index } } }
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
  local delim = delimiter(header)
  local names, values = fields(header, delim), fields(first, delim)
  local columns = {}
  for i, name in ipairs(names) do
    if name ~= "" then
      -- path / index: where read_values finds this column's values
      columns[#columns + 1] = { name = name, example = values[i], path = path, index = i }
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

---------- Values of a column, where one is compared ----------
--
--   df |> filter(species == "|      ->  setosa  versicolor  virginica
--   filter(df, cyl %in% c(4, |       ->  8  4  6  (no quotes: numbers)
--   df$sex == "|   df[["sex"]] != |   df["sex"] == "|   df["sex"].isin(["|
--
-- From the running kernel (factor levels, or the distinct values when
-- there are few), else from the file the frame was read from.

local MAX_VALUES, MAX_NUMBERS = 50, 20
local MAX_ROWS, MAX_BYTES = 5000, 1024 * 1024

-- path -> { mtime, by_index = { [i] = { values = { { value, count } }, quote } | false } }
local values_cache = {}

local NUMBER = "^[%-%+]?%d*%.?%d+[eE]?[%-%+]?%d*$"
local MISSING = { [""] = true, NA = true, NaN = true, ["NULL"] = true, nan = true, None = true }

-- The distinct values of column `index` of the delimited file `path`, most
-- common first, or nil when it has too many (or the file can't be read).
-- Reads at most MAX_ROWS rows; each file once per change.
local function read_values(path, index)
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= "file" then
    return nil
  end
  local c = values_cache[path]
  if not (c and c.mtime == stat.mtime.sec) then
    c = { mtime = stat.mtime.sec, by_index = {} }
    values_cache[path] = c
    local f = io.open(path, "r")
    if not f then
      return nil
    end
    local header = (f:read("*l") or ""):gsub("^\239\187\191", ""):gsub("\r$", "")
    local delim = delimiter(header)
    local counts, bytes, rows = {}, 0, 0
    for line in f:lines() do
      rows, bytes = rows + 1, bytes + #line
      if rows > MAX_ROWS or bytes > MAX_BYTES then
        break
      end
      for i, v in ipairs(fields((line:gsub("\r$", "")), delim)) do
        local col = counts[i]
        if col == nil then
          col = { n = 0, seen = {} }
          counts[i] = col
        end
        if col and not MISSING[v] then
          if not col.seen[v] then
            col.n = col.n + 1
            col.seen[v] = 0
          end
          col.seen[v] = col.seen[v] + 1
          if col.n > MAX_VALUES then
            counts[i] = false -- too many to be choices
          end
        end
      end
    end
    f:close()
    for i, col in pairs(counts) do
      if col then
        local list, numeric, logical = {}, true, true
        for v, n in pairs(col.seen) do
          list[#list + 1] = { value = v, count = n }
          numeric = numeric and v:match(NUMBER) ~= nil
          logical = logical and (v == "TRUE" or v == "FALSE" or v == "True" or v == "False")
        end
        table.sort(list, function(a, b)
          return a.count > b.count or (a.count == b.count and a.value < b.value)
        end)
        if #list > 0 and not (numeric and #list > MAX_NUMBERS) then
          c.by_index[i] = { values = list, quote = not (numeric or logical) }
        end
      end
    end
  end
  return c.by_index[index] or nil
end

-- R: `col` in a data verb, `df$col`, df[["col"]]. Python: df["col"], df.col
local function compared(lang, lhs)
  if lang == "r" then
    local df, col = lhs:match("([%a._][%w._]*)%$`?([^`$]+)`?$")
    if df then
      return df, col
    end
    df, col = lhs:match("([%a._][%w._]*)%[%[%s*[\"']([^\"']+)[\"']%s*%]%]$")
    if df then
      return df, col
    end
    col = lhs:match("%f[%w._`]`([^`]+)`$") or lhs:match("%f[%w._]([%a._][%w._]*)$")
    if not col then
      return nil
    end
    -- The frame the verb works on (as find_context does for column names)
    for _, call in ipairs(context.open_calls()) do
      local name = call.name:match("[^:]+$")
      if verbs[name] then
        local first = call.args:match("^%s*([%a._][%w._]*)%s*,")
        local root = chain_root(call.before) or first
        if root then
          return root, col
        end
      end
    end
    return nil
  end
  local df, col = lhs:match("([%a_][%w_]*)%[%s*[\"']([^\"']+)[\"']%s*%]$")
  if not df then
    -- df.col only for a known data frame: not self.state, np.pi
    df, col = lhs:match("([%a_][%w_]*)%.([%a_][%w_]*)$")
    local known = df
      and (
        frames(vim.api.nvim_get_current_buf(), lang)[df]
        or require("config.cmp-slot").object_types(lang)[df] == "data"
      )
    if not known then
      return nil
    end
  end
  return df, col
end

-- { df, column, partial, quoted } where a value of a column goes, or nil
function source.value_context(lang, before)
  if lang ~= "r" and lang ~= "python" then
    return nil
  end
  local q = open_quote(before)
  local pre, partial
  if q then
    pre, partial = before:sub(1, q - 1), before:sub(q + 1)
  else
    partial = before:match("[%w._%-]*$")
    pre = before:sub(1, #before - #partial)
  end
  -- What's compared: `lhs ==`, `lhs !=`, `lhs %in% c(…, `, `lhs.isin([…, `
  local lhs = pre:match("^(.-)%s*[=!]=%s*$")
  if not lhs and lang == "r" then
    lhs = pre:match("^(.-)%s*%%in%%%s*c%([^()]*$")
    if lhs and not pre:match("%(%s*$") and not pre:match(",%s*$") then
      lhs = nil
    end
  elseif not lhs then
    lhs = pre:match("^(.-)%.isin%(%[[^%[%]]*$")
    if lhs and not pre:match("%[%s*$") and not pre:match(",%s*$") then
      lhs = nil
    end
  end
  if not lhs then
    return nil
  end
  -- Values already in the c(…) / isin([…]): not offered again
  local given = {}
  local list = pre:match("c%(([^()]*)$") or pre:match("isin%(%[([^%[%]]*)$")
  for v in (list or ""):gmatch("[^,]+") do
    given[vim.trim(v):gsub("^[\"']", ""):gsub("[\"']$", "")] = true
  end
  local df, column = compared(lang, lhs)
  if df then
    return { df = df, column = column, partial = partial, quoted = q ~= nil, given = given }
  end
end

local R_VALUES = [==[
local({
  if (is.data.frame(%s) && %s %%in%% names(%s)) {
    v <- %s[[%s]]
    cap <- if (is.factor(v)) 100 else if (is.numeric(v)) %d else %d
    # count first: table() of a long numeric column is slow
    n <- if (is.factor(v)) nlevels(v) else length(unique(v))
    if (n > 0 && n <= cap) {
      t <- if (is.factor(v)) table(v) else sort(table(v), decreasing = TRUE)
      cat(if (is.character(v) || is.factor(v)) "s" else "n", paste(names(t), t, sep = "\t"), sep = "\n")
    }
  }
})]==]

local PY_VALUES = [[
def __nvim_values():
    import pandas as pd
    s = %s[%s]
    if isinstance(s.dtype, pd.CategoricalDtype):
        vc = s.value_counts(sort=False)
        cap, quote = 100, s.cat.categories.dtype == object
    else:
        num = pd.api.types.is_numeric_dtype(s) and not pd.api.types.is_bool_dtype(s)
        cap, quote = (%d if num else %d), not (num or pd.api.types.is_bool_dtype(s))
        if s.nunique() > cap:
            return
        vc = s.value_counts()
    if 0 < len(vc) <= cap:
        print("s" if quote else "n")
        for v, n in vc.items():
            print(f"{v}\t{n}")
try:
    __nvim_values()
finally:
    del __nvim_values]]

-- "col" as a string literal of R / Python
local function literal(s)
  return '"' .. s:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

-- lang:df:col -> { result, time }, kept VALUES_MS
local values_kernel_cache = {}
local VALUES_MS = 2000

-- cb(result or nil): the kernel's values of df's column, as read_values
local function kernel_values(lang, df, column, cb)
  local key = table.concat({ lang, df, column }, ":")
  local hit = values_kernel_cache[key]
  if hit and vim.uv.now() - hit.time < VALUES_MS then
    return cb(hit.result)
  end
  local session = require("config.kernel.session")
  local k = session.find(lang, 0)
  if not k or k.state ~= "idle" then
    return cb(nil)
  end
  local col = literal(column)
  local code = lang == "r" and R_VALUES:format(df, col, df, df, col, MAX_NUMBERS, MAX_VALUES)
    or PY_VALUES:format(df, col, MAX_NUMBERS, MAX_VALUES)
  session.eval(k, code, function(text, ok)
    local result
    local kind, rest = (text or ""):match("^([sn])\n(.*)$")
    if ok and kind then
      result = { values = {}, quote = kind == "s" }
      for v, n in rest:gmatch("([^\t\n]*)\t(%d+)") do
        result.values[#result.values + 1] = { value = v, count = tonumber(n) }
      end
    end
    values_kernel_cache[key] = { result = result, time = vim.uv.now() }
    cb(result)
  end)
end

-- Items for a column's values
local function value_items(ctx, found, result)
  local row, col = ctx.cursor[1] - 1, ctx.cursor[2]
  local range = { start = { line = row, character = col - #found.partial }, ["end"] = { line = row, character = col } }
  local kind = require("blink.cmp.types").CompletionItemKind.EnumMember
  local items = {}
  for i, v in ipairs(result.values) do
    local text = v.value
    if result.quote and not found.quoted then
      text = '"' .. text:gsub('"', '\\"') .. '"'
    end
    if not found.given[v.value] then
      items[#items + 1] = {
        label = text,
        filterText = v.value,
        kind = kind,
        labelDetails = { description = ("×%d"):format(v.count) },
        documentation = ("Value of `%s` in `%s`"):format(found.column, found.df),
        textEdit = { newText = text, range = range },
        sortText = ("%04d"):format(i), -- most common first
      }
    end
  end
  return items
end

local function column_values(ctx, found, lang, callback)
  kernel_values(lang, found.df, found.column, function(result)
    if not result then
      local cols = frames(ctx.bufnr, lang)[found.df]
      for _, c in ipairs(cols or {}) do
        if c.name == found.column and c.path then
          result = read_values(c.path, c.index)
          break
        end
      end
    end
    callback({
      items = result and value_items(ctx, found, result) or {},
      -- in / out of quotes changes the items
      is_incomplete_forward = true,
      is_incomplete_backward = true,
    })
  end)
end

function source:enabled()
  local lang = context.region().lang
  return lang == "python" or lang == "r"
end

local EMPTY = { items = {}, is_incomplete_forward = false, is_incomplete_backward = false }

-- Columns of `df` in the running kernel, cached briefly: "lang:df" -> { cols, time }
local kernel_cache = {}
local CACHE_MS = 2000

local function cached_kernel_columns(lang, df)
  local hit = kernel_cache[lang .. ":" .. df]
  if hit and vim.uv.now() - hit.time < CACHE_MS then
    return hit
  end
end

-- cb(cols or nil): the kernel's columns of `df` (nil without an idle kernel
-- for `lang`, or when `df` isn't a data frame there).
local function kernel_columns(lang, df, cb)
  local hit = cached_kernel_columns(lang, df)
  if hit then
    return cb(hit.cols)
  end
  local session = require("config.kernel.session")
  local k = session.find(lang, 0)
  if not k or k.state ~= "idle" then
    return cb(nil)
  end
  local code = lang == "r" and ("if (is.data.frame(%s)) cat(names(%s), sep = '\\n')"):format(df, df)
    or ("print('\\n'.join(map(str, %s.columns)))"):format(df)
  session.eval(k, code, function(text, ok)
    local cols
    if ok and text:find("%S") then
      cols = {}
      for name in text:gmatch("[^\n]+") do
        cols[#cols + 1] = { name = name }
      end
    end
    kernel_cache[lang .. ":" .. df] = { cols = cols, time = vim.uv.now() }
    cb(cols)
  end)
end

-- The data frame context at the cursor: found, lang (or nil)
local function context_at(ctx)
  local lang = context.region(ctx.bufnr).lang
  if lang ~= "r" and lang ~= "python" then
    return nil
  end
  local found = find_context(lang, ctx.line:sub(1, ctx.cursor[2]))
  if found then
    return found, lang
  end
end

-- Columns for the cursor without waiting: the kernel's (if cached) or the
-- files'. Returns cols, context, lang (or nil).
local function lookup(ctx)
  local found, lang = context_at(ctx)
  if not found then
    return nil
  end
  local hit = cached_kernel_columns(lang, found.df)
  local cols = hit and hit.cols or frames(ctx.bufnr, lang)[found.df]
  if cols then
    return cols, found, lang
  end
end

-- Names of the data frames read from files in `buf` (`df <- read.csv(…)`),
-- for ranking them first where a data frame goes (completion.lua)
function source.frame_names(buf, lang)
  return frames(buf, lang)
end

-- For the LSP transform in completion.lua: where columns are known, the
-- names they replace. `only` = after df$ or in df["…"], where nothing but a
-- column fits, so the language server's guesses can go.
function source.known_here(ctx)
  -- (a column's values go here, not its name)
  if source.value_context(context.region(ctx.bufnr).lang, ctx.line:sub(1, ctx.cursor[2])) then
    return nil
  end
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
  local lang_here = context.region(ctx.bufnr).lang
  local compared_here = source.value_context(lang_here, ctx.line:sub(1, ctx.cursor[2]))
  if compared_here then
    return column_values(ctx, compared_here, lang_here, callback)
  end
  local found, lang = context_at(ctx)
  if not found then
    return callback(EMPTY)
  end
  kernel_columns(lang, found.df, function(kernel_cols)
    local cols = kernel_cols or frames(ctx.bufnr, lang)[found.df]
    if not cols then
      return callback(EMPTY)
    end
    source.items(ctx, cols, found, lang, callback)
  end)
end

function source.items(ctx, cols, found, lang, callback)
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
