-- What goes at the cursor in R / Python code, so completion can offer the
-- right kind of thing (lua/plugins/completion.lua):
--
--   M.here() -> { where, type, name, fn, quoted, lang }
--
--   where   "member"     df$|  obj@|  pkg::|  obj.|   (Python)
--           "value"      after `name = ` in a call
--           "arg"        an argument position: a name or a positional value
--           "string"     in quotes, outside any call that tells more
--           "chain"      the next step of an R ggplot chain (after `+`) or
--                        pipe (after |> / %>%): chain = "ggplot" / "pipe"
--           "statement"  everything else (new lines, operators, ...)
--   type    for "value" / "arg" / "string", what the argument takes, when
--           known: "logical", "number", "string", "choice", "function",
--           "data", "colour", "text" (words for people: titles, labels,
--           messages), "column" (aes(), dplyr verbs, formulas),
--           "level" (a value of a column being compared: filter(sex == "|,
--           df$cyl %in% c(|; name is the column, see cmp-columns.lua)
--   name    the argument (`method`), fn the called function (`cor`)
--   quoted  the cursor is inside quotes
--
-- Types come from, in order: what the argument is called (title, colour,
-- FUN, data), the function (every string in labs() or message() is text,
-- every argument of aes() a column), and the call's signature
-- (cmp-signature.lua): R defaults (TRUE, 2, "x", c("a", "b")), Python
-- annotations (bool, int, Callable, DataFrame).
--
-- M.object_types(lang) -> { name = type } for the objects in the running
-- kernel's session (data / function / logical / number / string), cached
-- and refreshed in the background, so items can be ranked by type
-- ("layer" for ggplot objects and themes, which can follow a `+`).

local context = require("config.cmp-context")
local signature = require("config.cmp-signature")

local M = {}

local function set(list)
  local s = {}
  for _, v in ipairs(list) do
    s[v] = true
  end
  return s
end

-- Every string argument of these is text for people
local TEXT_FUNCTIONS = set({
  -- R
  "labs",
  "ggtitle",
  "xlab",
  "ylab",
  "message",
  "warning",
  "stop",
  "cat",
  "print",
  "paste",
  "paste0",
  "sprintf",
  "glue",
  "writeLines",
  "cli_alert",
  "cli_inform",
  "cli_abort",
  "cli_warn",
  "inform",
  "abort",
  "warn",
  -- Python
  "title",
  "suptitle",
  "xlabel",
  "ylabel",
  "set_title",
  "set_xlabel",
  "set_ylabel",
  "set_label",
  "info",
  "debug",
  "warning",
  "error",
  "critical",
})

-- Arguments, by name, that take ...
local TEXT_ARGS = set({
  "title",
  "subtitle",
  "caption",
  "tag",
  "main",
  "sub",
  "xlab",
  "ylab",
  "xlabel",
  "ylabel",
  "label",
  "name",
  "alt",
  "msg",
  "message",
  "help",
  "description",
})
local COLOUR_ARGS =
  set({ "colour", "color", "col", "fill", "bg", "fg", "facecolor", "edgecolor", "markerfacecolor", "markeredgecolor" })
local FUNCTION_ARGS =
  set({ "FUN", ".f", ".fn", ".fun", "fun", "func", "function", "key", "callback", "fn", "FUN.VALUE" })
local DATA_ARGS = set({ "data", ".data", "df", "frame", "dataframe" })

local function in_r_or_python()
  local r = context.region()
  if (r.kind == "code" or r.kind == "string") and (r.lang == "r" or r.lang == "python") then
    return r
  end
end

-- Type from an R default value or a Python annotation
local function from_signature(param, lang)
  if not param then
    return nil
  end
  local ann, default = param.annotation, param.default
  if ann then
    if ann:match("^Literal%[") then
      return "choice"
    elseif ann:match("^Callable") or ann:match("[%[|]%s*Callable") then
      return "function"
    elseif ann:match("DataFrame") then
      return "data"
    end
    local parts = {}
    for t in (ann .. "|"):gmatch("%s*([^|]-)%s*|") do
      if t ~= "None" then
        parts[#parts + 1] = t
      end
    end
    if #parts == 1 and parts[1] == "bool" then
      return "logical"
    elseif #parts >= 1 and vim.iter(parts):all(function(t)
      return t == "int" or t == "float"
    end) then
      return "number"
    elseif #parts == 1 and parts[1] == "str" then
      return "string"
    end
  end
  if not default then
    return nil
  end
  if default == "TRUE" or default == "FALSE" or default == "T" or default == "F" then
    return "logical"
  elseif lang == "python" and (default == "True" or default == "False") then
    return "logical"
  elseif default:match("^%-?[%d.]+[eE]?%-?%d*L?$") and default:match("%d") then
    return "number"
  elseif default:match("^c%(%s*[\"']") then
    return "choice"
  elseif default:match("^[\"']") then
    return "string"
  elseif default:match("^function%s*%(") or default:match("^\\%(") then
    return "function"
  end
end

-- Type from an argument's name alone
local function by_name(name)
  if not name then
    return nil
  elseif TEXT_ARGS[name] then
    return "text"
  elseif COLOUR_ARGS[name] then
    return "colour"
  elseif FUNCTION_ARGS[name] then
    return "function"
  elseif DATA_ARGS[name] then
    return "data"
  end
end

-- The type of argument `name` (or of positional argument number `index`)
-- of `fn`, inside `call`
local function arg_type(fn, name, index, quoted, lang, current)
  -- aes() and dplyr verbs: columns of the data frame (cmp-columns.lua);
  -- `y ~ x` formulas too
  if current:find("~", 1, true) then
    return "column"
  end
  if fn == "aes" or vim.tbl_contains(context.data_verbs, fn) then
    if not (name and TEXT_ARGS[name] and quoted) then
      return "column"
    end
  end
  local named = by_name(name)
  if named then
    return named
  end
  if TEXT_FUNCTIONS[fn] and (quoted or not name) then
    return "text"
  end
  local sig = signature.cached()
  local param
  if name then
    param = signature.param(sig, name)
  elseif sig and index then
    -- The positional argument being written: the next param not given by
    -- name (cmp-signature.filled has the same rule)
    local args = context.call_args()
    local filled = signature.filled(sig, args)
    for _, p in ipairs(sig.params) do
      if p.kind ~= "positional" then
        break
      end
      if not filled[p.name] then
        param = p
        break
      end
    end
  end
  -- A positional argument's param name says it too (sapply(x, | is FUN);
  -- then the default / annotation
  return (not name and param and by_name(param.name)) or from_signature(param, lang)
end

-- `before` ends inside quotes?
local function open_quote(before)
  local quote
  for i = 1, #before do
    local ch = before:sub(i, i)
    if quote then
      if ch == quote and before:sub(i - 1, i - 1) ~= "\\" then
        quote = nil
      end
    elseif ch == '"' or ch == "'" then
      quote = ch
    end
  end
  return quote ~= nil
end

-- Lines up to the cursor, the last one cut at it
local function lines_before(max_lines)
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local lines = vim.api.nvim_buf_get_lines(0, math.max(0, row - max_lines), row, false)
  lines[#lines] = (lines[#lines] or ""):sub(1, col)
  return lines
end

-- A line without its comment (roughly: a # with no quote after it)
local function code_of(line)
  return (line:gsub("%s*#[^\"']*$", ""))
end

-- Does this line go on onto the next one? (ends in + , ( |> %>%)
local function continues(line)
  local code = code_of(line)
  return code:match("[+,(]%s*$") or code:match("|>%s*$") or code:match("%%>%%%s*$")
end

-- The next step of a chain goes at the cursor: "ggplot" after a `+` in an
-- expression that starts with ggplot( (or a ggplot object in the session),
-- "pipe" after |> / %>% at the top level. R only.
--   ggplot(df, aes(x, y)) +
--     geom_|                    -> "ggplot"
--   df |>
--     fil|                      -> "pipe"
local function chain_here(call)
  local lines = lines_before(30)
  lines[#lines] = lines[#lines]:gsub("[%w._]*$", "")
  local i = #lines
  local text = code_of(lines[i])
  -- the operator may end the previous line
  while i > 1 and not text:find("%S") do
    i = i - 1
    text = code_of(lines[i])
  end
  if text:match("|>%s*$") or text:match("%%>%%%s*$") then
    return not call and "pipe" or nil
  end
  if not text:match("%+%s*$") then
    return nil
  end
  -- The whole expression: inside a call, what's in it; else back to the
  -- first line of the statement
  local expr
  if call then
    expr = call.args
  else
    local first = i
    while first > 1 and continues(lines[first - 1]) do
      first = first - 1
    end
    local parts = {}
    for j = first, i do
      parts[#parts + 1] = code_of(lines[j])
    end
    expr = table.concat(parts, "\n")
  end
  if expr:match("ggplot%s*%(") then
    return "ggplot"
  end
  -- p + : a ggplot object made earlier
  local head = expr:match("^%s*([%a._][%w._]*)")
  if head and M.object_types("r")[head] == "layer" then
    return "ggplot"
  end
end

local cache = { key = nil, value = nil }

function M.here()
  local buf = vim.api.nvim_get_current_buf()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local key = ("%d:%d:%d:%d"):format(buf, vim.b[buf].changedtick, row, col)
  if cache.key == key then
    return cache.value
  end
  local slot = M.compute()
  cache.key, cache.value = key, slot
  return slot
end

function M.compute()
  local r = in_r_or_python()
  if not r then
    return { where = "statement" }
  end
  local lang = r.lang
  local line = vim.api.nvim_get_current_line()
  local before = line:sub(1, vim.api.nvim_win_get_cursor(0)[2])
  -- (treesitter says "string" right after the closing quote too; a string
  -- with no quote on this line started on an earlier one)
  local quoted = open_quote(before) or (r.kind == "string" and not before:find("[\"']"))
  local slot = { lang = lang, quoted = quoted }

  -- filter(sex == "|: one of the column's values
  local compared = require("config.cmp-columns").value_context(lang, before)
  if compared then
    slot.where, slot.type, slot.name, slot.df = "value", "level", compared.column, compared.df
    return slot
  end

  if not quoted then
    local member
    if lang == "r" then
      member = before:match("[%w._%)%]`]%$[%w._]*$")
        or before:match("[%w._%)%]]@[%w._]*$")
        or before:match("[%w._]::[%w._]*$")
    else
      member = before:match("[%a_%)%]][%w_]*%.[%w_]*$")
    end
    if member then
      slot.where = "member"
      return slot
    end
  end

  local call = context.open_calls()[1]
  if lang == "r" and not quoted then
    local chain = chain_here(call)
    if chain then
      slot.where, slot.chain = "chain", chain
      return slot
    end
  end
  if not call then
    slot.where = quoted and "string" or "statement"
    slot.type = quoted and "text" or nil
    return slot
  end
  -- plt.title -> title; R names keep their dots (read.csv)
  local fn = lang == "python" and call.name:match("[^.]+$") or call.name
  slot.fn = fn
  local current = context.top_level(call.args):match("[^,]*$") or ""
  local name = current:match("^%s*([%a._][%w._]*)%s*=")
  if name and current:match("^%s*[%w._]+%s*==") then
    name = nil
  end
  -- sapply(x, function(v) |): code again, not an argument
  if
    not name
    and (current:match("^%s*function%s*%b()") or current:match("^%s*\\%b()") or current:match("^%s*lambda[^:]*:"))
  then
    slot.where = "statement"
    return slot
  end
  slot.where = name and "value" or "arg"
  slot.name = name
  slot.type = arg_type(fn, name, not name and 1 or nil, quoted, lang, current)
  return slot
end

---------- Objects in the kernel's session, by type ----------

local R_TYPES = [[
local({
  e <- globalenv()
  for (n in ls(e)) {
    v <- get(n, envir = e)
    k <- if (inherits(v, c("gg", "theme", "ggproto", "labels"))) "layer" else
      if (is.data.frame(v)) "data" else if (is.function(v)) "function" else
      if (is.logical(v)) "logical" else if (is.numeric(v)) "number" else
      if (is.character(v)) "string" else ""
    if (nzchar(k)) cat(n, "\t", k, "\n", sep = "")
  }
})]]

local PY_TYPES = [[
def __nvim_types():
    for n, v in list(globals().items()):
        if n.startswith("_"):
            continue
        t = type(v).__name__
        k = ("data" if t in ("DataFrame", "Series") else
             "logical" if isinstance(v, bool) else
             "number" if isinstance(v, (int, float)) else
             "string" if isinstance(v, str) else
             "function" if callable(v) and not isinstance(v, type) else "")
        if k:
            print(f"{n}\t{k}")
__nvim_types()
del __nvim_types]]

-- lang -> { types = { name = type }, stale = bool, asking = bool }
local types = {}

require("config.kernel.session").observe({
  -- Code that ran for real (not a silent eval like ours) may have made or
  -- changed objects
  exec = function(k, _, opts)
    if opts and opts.history == false then
      return
    end
    for _, t in pairs(types) do
      t.stale = true
    end
  end,
})

function M.object_types(lang)
  local t = types[lang]
  if not t then
    t = { types = {}, stale = true }
    types[lang] = t
  end
  if t.stale and not t.asking then
    local session = require("config.kernel.session")
    local k = session.find(lang, 0)
    if k and k.state == "idle" then
      t.asking = true
      session.eval(k, lang == "r" and R_TYPES or PY_TYPES, function(text, ok)
        t.asking = false
        if ok then
          local found = {}
          for n, kind in (text or ""):gmatch("([^\t\n]+)\t(%a+)") do
            found[n] = kind
          end
          t.types, t.stale = found, false
        end
      end)
    end
  end
  return t.types
end

return M
