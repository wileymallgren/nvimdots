-- blink.cmp source: values you've already written for the argument being
-- written, anywhere in this file, so a notebook stays consistent:
--
--   geom_point(alpha = 0.6, colour = "steelblue")
--   …
--   geom_line(alpha = |        ->  0.6          used 1×
--   geom_line(colour = "s|     ->  steelblue    (inside the quotes)
--
-- Values used with the same function come first, then by how often they
-- were used, then the nearest above the cursor. Only values that fit what
-- the argument takes (lua/config/cmp-slot.lua) are offered: no "red" for
-- `alpha = `, no 0.6 for `FUN = `. Where another source has the same value
-- (a signature's choice, a colour name, TRUE), completion.lua keeps that
-- item and moves it up instead (merge_used_values).

local M = {}

function M.new()
  return setmetatable({}, { __index = M })
end

local QUERIES = {
  r = "(call function: (_) @fn arguments: (arguments (argument name: (identifier) @name value: (_) @value)))",
  python = "(call function: (_) @fn arguments: (argument_list (keyword_argument name: (identifier) @name value: (_) @value)))",
}

local MAX_LEN = 40

local parsed = {}
local function query(lang)
  if parsed[lang] == nil then
    local ok, q = pcall(vim.treesitter.query.parse, lang, QUERIES[lang])
    parsed[lang] = ok and q or false
  end
  return parsed[lang] or nil
end

-- `ggplot2::geom_point` -> geom_point, `ax.set_title` -> set_title (R names
-- keep their dots: read.csv)
local function short_fn(text, lang)
  if lang == "python" then
    return text:match("([%w_]+)$")
  end
  return text:match("([%w._]+)$")
end

-- buf -> { tick, time, uses = { lang = { arg = { value = { { row, s, e, fn } } } } } }
local cache = {}

-- Every `name = value` in the buffer's calls, by language. Rebuilt at most
-- once a second while typing.
local function scan(buf)
  local tick, now = vim.b[buf].changedtick, vim.uv.now()
  local c = cache[buf]
  if c and (c.tick == tick or now - c.time < 1000) then
    return c.uses
  end
  local uses = {}
  local ok, parser = pcall(vim.treesitter.get_parser, buf, nil, { error = false })
  if ok and parser then
    pcall(parser.parse, parser, true) -- injected chunks too
    parser:for_each_tree(function(tree, ltree)
      local lang = ltree:lang()
      local q = QUERIES[lang] and query(lang)
      if not q then
        return
      end
      uses[lang] = uses[lang] or {}
      for _, match in q:iter_matches(tree:root(), buf, 0, -1) do
        local fn, name, value
        for id, nodes in pairs(match) do
          local node = type(nodes) == "table" and nodes[#nodes] or nodes
          local capture = q.captures[id]
          if capture == "fn" then
            fn = node
          elseif capture == "name" then
            name = node
          elseif capture == "value" then
            value = node
          end
        end
        if fn and name and value then
          local sr, sc, er, ec = value:range()
          local text = vim.treesitter.get_node_text(value, buf)
          if sr == er and #text <= MAX_LEN and not value:has_error() then
            local arg = vim.treesitter.get_node_text(name, buf)
            local by_value = uses[lang][arg] or {}
            uses[lang][arg] = by_value
            by_value[text] = by_value[text] or {}
            table.insert(by_value[text], {
              row = sr,
              s = sc,
              e = ec,
              fn = short_fn(vim.treesitter.get_node_text(fn, buf), lang),
            })
          end
        end
      end
    end)
  end
  cache[buf] = { tick = tick, time = now, uses = uses }
  return uses
end

local function is_string(value)
  return value:match('^"[^"]*"$') or value:match("^'[^']*'$")
end

local LOGICAL = { TRUE = true, FALSE = true, T = true, F = true, True = true, False = true }

-- Can `value` go in a slot of type `t`? (a variable can hold anything)
local function fits(value, t)
  if value:match("^[%a_][%w._]*$") and not LOGICAL[value] then
    return true
  end
  if t == "logical" then
    return LOGICAL[value] ~= nil
  elseif t == "number" then
    -- 0.6, 1e-3, 2L, -1, 1/3, c(1, 2)
    return (value:match("^[%d.%s%+%-%*/eEL()]+$") ~= nil and value:match("%d") ~= nil)
      or value:match("^c%([%d.%s,%-]+%)$") ~= nil
  elseif t == "string" or t == "choice" or t == "colour" then
    return is_string(value) ~= nil or value:match("^c%(") ~= nil
  elseif t == "function" then
    return not is_string(value) and not value:match("^[%-%d.]")
  elseif t == "data" then
    return not is_string(value) and not value:match("^[%-%d.]") and not LOGICAL[value]
  end
  return true
end

-- Slot types this source serves (cmp-slot.lua); "text" is one-off prose
-- (Codeium), "column" a column expression
local SKIP_TYPES = { text = true, column = true, level = true }

-- The argument being written and its slot, or nil
local function here()
  local slot = require("config.cmp-slot").here()
  if slot.where ~= "value" or not slot.name or SKIP_TYPES[slot.type or ""] then
    return nil
  end
  local name, quote, typed = require("config.cmp-arg-values").arg_here()
  if name ~= slot.name then
    return nil
  end
  return slot, quote, typed
end

-- { { value, count, same_fn, distance } } for the argument at the cursor,
-- best first
local function candidates(buf, slot, quote)
  local by_value = (scan(buf)[slot.lang] or {})[slot.name]
  if not by_value then
    return {}
  end
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  row = row - 1
  local out = {}
  for value, places in pairs(by_value) do
    local count, same, distance = 0, 0, math.huge
    for _, p in ipairs(places) do
      -- not the argument being typed itself
      local typing = p.row == row and p.s <= col and col <= p.e + 1
      if not typing then
        count = count + 1
        if p.fn == slot.fn then
          same = same + 1
        end
        -- above the cursor counts as nearer than below it
        local d = p.row <= row and (row - p.row) or (p.row - row + 10000)
        distance = math.min(distance, d)
      end
    end
    local ok = count > 0 and fits(value, slot.type)
    if ok and quote ~= "" then
      ok = is_string(value) ~= nil -- inside quotes only strings fit
    end
    if ok then
      out[#out + 1] = { value = value, count = count, same_fn = same > 0, distance = distance }
    end
  end
  table.sort(out, function(a, b)
    if a.same_fn ~= b.same_fn then
      return a.same_fn
    elseif a.count ~= b.count then
      return a.count > b.count
    end
    return a.distance < b.distance
  end)
  return out
end

-- Values to offer right after `name = ` (for the space trigger in completion.lua)?
function M.any_here()
  local slot, quote = here()
  return slot ~= nil and #candidates(vim.api.nvim_get_current_buf(), slot, quote) > 0
end

function M:enabled()
  return here() ~= nil
end

function M:get_trigger_characters()
  return { '"', "'", " " }
end

function M:get_completions(ctx, callback)
  local function done(items)
    -- asked again on every keystroke: in / out of quotes changes the items
    callback({ items = items, is_incomplete_forward = true, is_incomplete_backward = true })
  end
  local slot, quote, typed = here()
  if not slot then
    return done({})
  end
  local row, col = ctx.cursor[1] - 1, ctx.cursor[2]
  local range = { start = { line = row, character = col - #typed }, ["end"] = { line = row, character = col } }
  local kinds = require("blink.cmp.types").CompletionItemKind
  local items = {}
  for i, c in ipairs(candidates(ctx.bufnr, slot, quote)) do
    local inner = is_string(c.value) and c.value:sub(2, -2)
    local text = quote ~= "" and inner or c.value
    local boost = c.same_fn and 4 or 2
    items[#items + 1] = {
      label = text,
      filterText = inner or c.value,
      kind = kinds.Value,
      labelDetails = { description = ("used %d×"):format(c.count) },
      detail = slot.name .. " = " .. c.value,
      textEdit = { newText = text, range = range },
      sortText = ("%04d"):format(i),
      score_offset = boost,
      used = { count = c.count, boost = boost },
    }
  end
  done(items)
end

return M
