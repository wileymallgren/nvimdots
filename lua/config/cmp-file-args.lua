-- blink.cmp source: file names inside the file argument of read.csv("…"),
-- readRDS("…"), pd.read_csv("…"), open("…") and similar (the list is in
-- lua/config/cmp-context.lua), in markdown links / images, and in YAML
-- header keys like bibliography:. Only files with the extensions that function
-- reads are offered; folders are always listed so you can go down into them.
-- Unlike blink's own path source, it works before any `/` has been typed.

local context = require("config.cmp-context")

local source = {}

function source.new()
  return setmetatable({}, { __index = source })
end

function source:get_trigger_characters()
  return { '"', "'", "/" }
end

local function wanted(name, exts)
  if exts == true then
    return true
  end
  local ext = name:match("%.([^.]+)$")
  return ext ~= nil and vim.tbl_contains(exts, ext)
end

function source:get_completions(ctx, callback)
  local arg = context.file_arg(ctx.bufnr)
  if not arg then
    return callback({ items = {}, is_incomplete_forward = false, is_incomplete_backward = false })
  end

  -- "data/raw/fi" -> list data/raw, replace "fi"
  local dir, partial = arg.typed:match("^(.*/)([^/]*)$")
  dir, partial = dir or "", partial or arg.typed
  local full_dir = dir:sub(1, 1) == "/" and dir
    or dir:sub(1, 2) == "~/" and vim.fn.expand("~") .. dir:sub(2)
    or vim.fs.joinpath(arg.base_dir, dir)
  local show_hidden = partial:sub(1, 1) == "."

  local row, col = ctx.cursor[1] - 1, ctx.cursor[2]
  local range = { start = { line = row, character = col - #partial }, ["end"] = { line = row, character = col } }
  local kinds = require("blink.cmp.types").CompletionItemKind

  local items = {}
  for name, type in vim.fs.dir(full_dir) do
    local is_dir = type == "directory" or (type == "link" and vim.fn.isdirectory(full_dir .. "/" .. name) == 1)
    if (show_hidden or name:sub(1, 1) ~= ".") and (is_dir or wanted(name, arg.exts)) then
      local text = is_dir and name .. "/" or name
      items[#items + 1] = {
        label = text,
        kind = is_dir and kinds.Folder or kinds.File,
        textEdit = { newText = text, range = range },
        sortText = (is_dir and "1" or "0") .. name:lower(), -- files before folders
      }
    end
  end
  callback({ items = items, is_incomplete_forward = false, is_incomplete_backward = false })
end

return source
