-- blink.cmp source: colour names for arguments that take a colour
-- (geom_point(colour = "|, plot(col = "|, ax.plot(color="|), as worked out
-- by lua/config/cmp-slot.lua. Not inside aes(): there `colour` is a column.
--
-- R gets grDevices::colors(), Python matplotlib's named colours (CSS names
-- plus tab:blue, C0, ...). Each list is asked for once, in the background,
-- and kept in Neovim's cache folder; until it's there, a short built-in
-- list stands in.

local M = {}

function M.new()
  return setmetatable({}, { __index = M })
end

local FALLBACK = {
  "black",
  "white",
  "grey",
  "gray50",
  "red",
  "blue",
  "green",
  "orange",
  "purple",
  "brown",
  "pink",
  "yellow",
  "steelblue",
  "darkgreen",
  "darkred",
  "navy",
  "tomato",
  "firebrick",
  "forestgreen",
  "skyblue",
}

local COMMANDS = {
  r = { "Rscript", "--vanilla", "-e", 'cat(grDevices::colors(distinct = TRUE), sep = "\\n")' },
  python = {
    "python3",
    "-c",
    "import matplotlib.colors as c\n"
      .. "print('\\n'.join([*c.TABLEAU_COLORS, *c.CSS4_COLORS, *[f'C{i}' for i in range(10)]]))",
  },
}

local lists = {} -- lang -> names (once known)
local asked = {}

local function cache_file(lang)
  return vim.fn.stdpath("cache") .. "/colour-names-" .. lang .. ".txt"
end

local function names(lang)
  if lists[lang] then
    return lists[lang]
  end
  local f = io.open(cache_file(lang), "r")
  if f then
    local list = vim.split(f:read("*a"), "\n", { trimempty = true })
    f:close()
    if #list > 0 then
      lists[lang] = list
      return list
    end
  end
  if not asked[lang] and COMMANDS[lang] then
    asked[lang] = true
    local cmd = vim.deepcopy(COMMANDS[lang])
    if lang == "python" then
      cmd[1] = require("config.python-env").project_python(vim.fn.getcwd()) or cmd[1]
    end
    pcall(vim.system, cmd, { text = true }, function(res)
      local list = res.code == 0 and vim.split(res.stdout or "", "\n", { trimempty = true }) or {}
      if #list > 0 then
        lists[lang] = list
        local w = io.open(cache_file(lang), "w")
        if w then
          w:write(table.concat(list, "\n"))
          w:close()
        end
      end
    end)
  end
  return FALLBACK
end

function M:enabled()
  return require("config.cmp-slot").here().type == "colour"
end

function M:get_trigger_characters()
  return { '"', "'" }
end

function M:get_completions(ctx, callback)
  local slot = require("config.cmp-slot").here()
  if slot.type ~= "colour" then
    return callback({ items = {}, is_incomplete_forward = false, is_incomplete_backward = false })
  end
  local before = ctx.line:sub(1, ctx.cursor[2])
  local typed = before:match("[%w_:]*$")
  local row, col = ctx.cursor[1] - 1, ctx.cursor[2]
  local range = { start = { line = row, character = col - #typed }, ["end"] = { line = row, character = col } }
  local kind = require("blink.cmp.types").CompletionItemKind.Color
  local items = {}
  for i, name in ipairs(names(slot.lang)) do
    -- Quotes added when the colour is written outside them
    local text = slot.quoted and name or ('"' .. name .. '"')
    items[#items + 1] = {
      label = text,
      filterText = name,
      kind = kind,
      textEdit = { newText = text, range = range },
      sortText = ("%04d"):format(i),
    }
  end
  callback({ items = items, is_incomplete_forward = false, is_incomplete_backward = false })
end

return M
