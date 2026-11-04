-- blink.cmp source: values for the R / Python argument being written, from the
-- call's signature (lua/config/cmp-signature.lua):
--
--   cor(x, method = |       ->  "pearson"  "kendall"  "spearman"
--   cor(x, method = "k|     ->  kendall  (inside the quotes)
--   read.csv(f, header = |  ->  FALSE  TRUE  (the one you'd change it to first)
--
-- The choices are the default's c("…", …), which is how R functions list
-- the values match.arg() accepts. The R language server has its own
-- "value for …" items, but only outside quotes and for every argument of
-- the call at once; completion.lua keeps those only for the argument being
-- written, and only when this source has nothing for it (M.values_here).
-- Python's language server completes Literal[…] values itself; this source
-- adds True / False for `bool` arguments.

local context = require("config.cmp-context")
local signature = require("config.cmp-signature")

local source = {}

function source.new()
  return setmetatable({}, { __index = source })
end

-- The argument being written in the innermost call, when it's `name = `
-- plus maybe an opening quote and part of a value: name, quote, typed
local function arg_here()
  local call = context.open_calls()[1]
  if not call then
    return nil
  end
  local current = context.top_level(call.args):match("[^,]*$")
  local name, quote, typed = current:match("^%s*([%a._][%w._]*)%s*=%s*([\"']?)([%w._]*)$")
  if name and not current:match("^%s*[%w._]+%s*==") then
    return name, quote, typed
  end
end
source.arg_here = arg_here

-- The values a param's default lists: c("a", "b") -> { "a", "b" }, true
-- (strings); TRUE / FALSE -> both, the other one first, false. Python:
-- True / False for a `bool` annotation or default.
local function values(param, lang)
  local default = param and param.default
  if lang == "python" then
    local ann = param and param.annotation
    if default == "True" then
      return { "False", "True" }, false
    elseif default == "False" or (ann and ann:match("^bool")) then
      return { "True", "False" }, false
    end
    return nil
  end
  if not default then
    return nil
  end
  if default == "TRUE" or default == "T" then
    return { "FALSE", "TRUE" }, false
  elseif default == "FALSE" or default == "F" then
    return { "TRUE", "FALSE" }, false
  end
  local inner = default:match("^c%((.*)%)$")
  if not inner then
    return nil
  end
  local out = {}
  for piece in (inner .. ","):gmatch("%s*(.-)%s*,") do
    local str = piece:match('^"(.*)"$') or piece:match("^'(.*)'$")
    if not str then
      return nil -- c(1, 2) or c(a, b): not a list of choices
    end
    out[#out + 1] = str
  end
  if #out > 1 then
    return out, true
  end
end

-- "r" / "python" in code there, else nil
local function lang_here()
  local r = context.region()
  if (r.kind == "code" or r.kind == "string") and (r.lang == "r" or r.lang == "python") then
    return r.lang
  end
end

function source:enabled()
  return lang_here() ~= nil
end

-- Does this source have values for the argument being written, by the
-- signature already known? Starts fetching it when it isn't, for the next
-- keystroke. Used by completion.lua for the space trigger and to drop the
-- language server's duplicates.
function source.values_here()
  local name, quote = arg_here()
  if not (name and lang_here()) then
    return false
  end
  local sig = signature.cached()
  if not sig then
    -- Not known yet: when it comes, open the menu if the cursor is still
    -- right after this `name = ` and there are values for it
    local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
    local pos, line = vim.api.nvim_win_get_cursor(win), vim.api.nvim_get_current_line()
    signature.fetch(buf, function(found)
      vim.schedule(function()
        local here = vim.api.nvim_get_current_win() == win
          and vim.api.nvim_get_current_buf() == buf
          and vim.deep_equal(vim.api.nvim_win_get_cursor(win), pos)
          and vim.api.nvim_get_current_line() == line
          and vim.fn.mode() == "i"
        if here and found and values(signature.param(found, name), lang_here()) then
          require("blink.cmp").show()
        end
      end)
    end)
    return false
  end
  local list, quoted = values(signature.param(sig, name), lang_here())
  return list ~= nil and (quote == "" or quoted)
end

-- Space too: blink blocks it unless completion.lua lets it through, which
-- it does right after `name = ` when there are values (values_here)
function source:get_trigger_characters()
  return { '"', "'", " " }
end

function source:get_completions(ctx, callback)
  local function done(items)
    -- asked again on every keystroke: in / out of quotes changes the items
    callback({ items = items, is_incomplete_forward = true, is_incomplete_backward = true })
  end
  local name, quote, typed = arg_here()
  local lang = lang_here()
  if not (name and lang) then
    return done({})
  end
  local row, col = ctx.cursor[1] - 1, ctx.cursor[2]
  signature.fetch(ctx.bufnr, function(sig)
    local param = signature.param(sig, name)
    local list, quoted = values(param, lang)
    if not list or (quote ~= "" and not quoted) then -- no "TRUE"
      return done({})
    end
    local kinds = require("blink.cmp.types").CompletionItemKind
    local items = {}
    for i, v in ipairs(list) do
      -- Strings get quotes unless typed inside them; either way the part
      -- of the value already typed is replaced
      local text = (quoted and quote == "") and ('"' .. v .. '"') or v
      items[#items + 1] = {
        label = text,
        filterText = v,
        kind = quoted and kinds.EnumMember or kinds.Constant,
        labelDetails = (quoted and i == 1) and { description = "default" } or nil,
        detail = name .. " = " .. param.default,
        textEdit = {
          newText = text,
          range = { start = { line = row, character = col - #typed }, ["end"] = { line = row, character = col } },
        },
        sortText = ("%04d"):format(i),
        score_offset = #list - i, -- keep the signature's order
      }
    end
    done(items)
  end)
end

return source
