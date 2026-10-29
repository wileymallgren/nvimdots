-- blink.cmp source: completions from the running R / Python kernel for the
-- code under the cursor: objects in the session, df$columns, obj.attributes,
-- pkg::functions, argument names. Only while that kernel runs and is idle
-- (a busy kernel would answer after the code finishes).

local session = require("config.kernel.session")
local chunks = require("config.kernel.chunks")

local source = {}

function source.new()
  return setmetatable({}, { __index = source })
end

local function kernel_here()
  local lang = chunks.lang_at(vim.fn.line("."))
  local k = lang and session.find(lang, 0)
  if k and k.state == "idle" then
    return k, lang
  end
end

function source:enabled()
  return kernel_here() ~= nil
end

function source:get_trigger_characters()
  return { "$", "@", ":", "." }
end

-- Where the member part of `token` starts (after $ / @ / :: in R, . in
-- Python): completions are listed by that part.
local function member_start(token, lang)
  local pat = lang == "r" and ".*()[%$@:]" or ".*()%."
  local pos = token:match(pat)
  return pos and pos + 1 or 1
end

function source:get_completions(ctx, callback)
  local k, lang = kernel_here()
  if not k then
    return callback({ items = {}, is_incomplete_forward = false, is_incomplete_backward = false })
  end
  local line, col = ctx.line, ctx.cursor[2]
  local cancelled = false
  session.complete(k, line, vim.str_utfindex(line, "utf-32", col), function(ev)
    if cancelled then
      return
    end
    local s = vim.str_byteindex(line, "utf-32", ev.start or 0)
    local typed = line:sub(s + 1, col)
    local skip = member_start(typed, lang) - 1 -- bytes of "df$" to keep
    local row = ctx.cursor[1] - 1
    local range = { start = { line = row, character = s + skip }, ["end"] = { line = row, character = col } }
    local kinds = require("blink.cmp.types").CompletionItemKind
    local items = {}
    for i, m in ipairs(ev.matches or {}) do
      local label = m:sub(1, skip) == typed:sub(1, skip) and m:sub(skip + 1) or m
      if label ~= "" then
        items[#items + 1] = {
          label = label,
          kind = skip > 0 and kinds.Field or (label:match("=%s*$") and kinds.Property or kinds.Variable),
          textEdit = { newText = label, range = range },
          sortText = ("%04d"):format(i),
        }
      end
    end
    callback({ items = items, is_incomplete_forward = true, is_incomplete_backward = true })
  end)
  return function()
    cancelled = true
  end
end

return source
