-- Which part of the file the cursor is in (comment / string / math / yaml /
-- prose / code, and the language there): lua/config/cmp-context.lua
local function region()
  return require("config.cmp-context").region()
end

-- Sources for each kind of region; anything else gets the default list
local DEFAULT_SOURCES = { "lsp", "kernel", "arg_values", "path", "snippets", "buffer", "columns", "codeium" }
local SOURCES_BY_REGION = {
  -- language-server items (keywords, builtins, members) are noise here
  comment = { "buffer", "path", "spell", "codeium" },
  -- \frac, \alpha, ... (friendly-snippets' tex set is document-level:
  -- \plotgraph3d, \fractionlarge, ... and would outrank \frac), and the
  -- value of the arithmetic before an `=`
  math = { "latex_calc", "latex_math", "codeium" },
  yaml = { "buffer", "path" },
  -- spelling corrections for misspelled words (spell is on in prose
  -- filetypes, see lua/config/options.lua)
  prose = { "lsp", "path", "snippets", "buffer", "spell", "codeium" },
}

-- In R / Python code the sources also follow what goes at the cursor
-- (lua/config/cmp-slot.lua). Codeium helps where the rest is open-ended:
-- new lines, the rest of a call, and text for people (labs(title = "…"),
-- message("…")). Where the argument takes a known kind of value (TRUE,
-- a number, one of c("a", "b"), a function, a data frame, a colour, a
-- column) or after df$ / pkg::, its guesses only push the real choices
-- down, and so do snippets and plain buffer words.
local UNTYPED_ARG = { "lsp", "kernel", "arg_values", "used_values", "columns", "path", "buffer", "codeium" }
local function slot_sources(slot)
  local t = slot.type
  if slot.where == "member" then
    return { "lsp", "kernel", "columns" }
  elseif slot.where == "chain" then
    return { "lsp", "kernel", "snippets", "buffer", "codeium" } -- ranked in fits_slot
  elseif t == "level" then
    -- filter(sex == "|: the column's values (cmp-columns.lua)
    return slot.quoted and { "columns", "lsp" } or { "columns", "lsp", "kernel" }
  elseif t == "column" then
    return { "columns", "kernel", "lsp", "arg_values" }
  elseif t == "text" then
    -- words in the string; outside quotes a variable may hold the text
    return slot.quoted and { "codeium", "buffer" } or UNTYPED_ARG
  elseif t == "colour" then
    return { "colours", "used_values", "lsp", "kernel" }
  elseif t == "logical" or t == "choice" then
    return { "arg_values", "used_values", "lsp", "kernel" }
  elseif t == "number" or t == "function" or t == "data" then
    return { "used_values", "lsp", "kernel" }
  elseif t == "string" then
    return slot.quoted and { "lsp", "used_values" } or { "lsp", "kernel", "arg_values", "used_values" }
  elseif slot.where == "value" or slot.where == "arg" then
    return UNTYPED_ARG
  elseif slot.where == "string" then
    return { "lsp", "codeium", "buffer" } -- lsp: Python dict keys, Literal values
  end
end

-- Does `s` contain every character of `sub`, in order?
local function has_in_order(s, sub)
  local pos = 1
  for ch in sub:gmatch(".") do
    pos = s:find(ch, pos, true)
    if not pos then
      return false
    end
    pos = pos + 1
  end
  return true
end

-- Codeium suggestions include the closing `")` that autopairs has already
-- put after the cursor, and codeium.nvim's check for that is off by one
-- column (it compares from the character *before* the cursor), so
-- accepting print("hello") gave print("hello")"). When the rest of the
-- line is only closers and the suggestion re-types them in order, make the
-- edit replace them instead of inserting in front of them.
local function codeium_eat_closers(ctx, items)
  local after = ctx.line:sub(ctx.cursor[2] + 1)
  if after == "" or not after:match("^[%)%]}\"'`%s,;:]+$") then
    return items
  end
  local closers = after:gsub("%s", "")
  for _, item in ipairs(items) do
    local edit = item.textEdit
    if edit and has_in_order(edit.newText, closers) then
      for _, range in ipairs({ edit.insert, edit.replace, edit.range }) do
        if range and range["end"].line == ctx.cursor[1] - 1 then
          range["end"].character = #ctx.line
        end
      end
    end
  end
  return items
end

-- Argument names end in `=`: R `header = `, Python `header=`
local function is_arg(item)
  return item.label:match("=%s*$") ~= nil
end

-- The R language server labels its argument items `header` (inserting
-- `header = `), so they'd look like objects to the rules below. Label them
-- the way the kernel and basedpyright do, and give every argument item the
-- same kind, so they share an icon.
local function normalize_args(items)
  local property = require("blink.cmp.types").CompletionItemKind.Property
  for _, item in ipairs(items) do
    if item.detail == "parameter" and item.insertText == item.label .. " = " then
      item.label = item.insertText
    end
    if is_arg(item) then
      item.kind = property
    end
  end
  return items
end

-- The R language server's "value for method" items ("kendall", inserting
-- the quotes) come for every argument of the call with a string default,
-- wherever you are in it: after cor(x, method = it also offers "everything"
-- for `use`. Keep the ones for the argument being written, and only when
-- cmp-arg-values.lua has nothing for it (it does the same, with TRUE/FALSE
-- and inside quotes too).
local function current_arg_values(items)
  local any = false
  for _, item in ipairs(items) do
    if type(item.detail) == "string" and item.detail:match("^value for ") then
      any = true
      break
    end
  end
  if not any then
    return items
  end
  local arg_values = require("config.cmp-arg-values")
  local name = arg_values.arg_here()
  local ours = name and arg_values.values_here()
  return vim.tbl_filter(function(item)
    local of = type(item.detail) == "string" and item.detail:match("^value for (.+)$")
    return not of or (of == name and not ours)
  end, items)
end

-- With a kernel running, R/Python code gets completions from both the
-- language server and the kernel (lua/config/kernel/complete.lua), mostly
-- the same names twice. For objects keep the kernel's copy (it knows the
-- running session and its data frames); for arguments keep the language
-- server's, which shows the argument's documentation. blink transforms each
-- source's items on their own, so this runs on the merged lists instead
-- (see the config function below).
local function drop_kernel_duplicates(items_by_source)
  local kernel, lsp = items_by_source.kernel, items_by_source.lsp
  if not (kernel and #kernel > 0) then
    return items_by_source
  end
  lsp = lsp or {}
  local function key(item)
    return (is_arg(item) and "=" or "") .. item.label:gsub("%s*=%s*$", ""):gsub("%(.*$", "")
  end
  local in_kernel, in_lsp = {}, {}
  for _, item in ipairs(kernel) do
    in_kernel[key(item)] = true
  end
  for _, item in ipairs(lsp) do
    in_lsp[key(item)] = true
  end
  local out = {}
  for id, items in pairs(items_by_source) do
    out[id] = items
  end
  out.lsp = vim.tbl_filter(function(item)
    return is_arg(item) or not in_kernel[key(item)]
  end, lsp)
  -- df$ columns: cmp-columns.lua has them (with examples) when it knows
  -- the frame, so the kernel's copies go
  local columns = {}
  for _, item in ipairs(items_by_source.columns or {}) do
    columns[item.label] = true
  end
  out.kernel = vim.tbl_filter(function(item)
    return not (is_arg(item) and in_lsp[key(item)]) and not columns[item.label]
  end, kernel)
  return out
end

-- A value used before in the file (cmp-used-values.lua) that another
-- source offers too: cor(x, method = has "kendall" from the signature,
-- colour = "s has steelblue from the colour names. Keep that item, moved
-- up by as much as the used one would be and marked "used 2×", and drop
-- the copy. Items are copied before they change: blink hands the same
-- tables in on every keystroke.
local MERGE_INTO = { "arg_values", "colours", "lsp", "kernel" }
local function merge_used_values(items_by_source)
  local used = items_by_source.used_values
  if not (used and #used > 0) then
    return items_by_source
  end
  local function text(item)
    return item.textEdit and item.textEdit.newText or item.insertText or item.label
  end
  local by_text = {}
  for _, item in ipairs(used) do
    by_text[text(item)] = item
  end
  local out, merged = {}, {}
  for id, items in pairs(items_by_source) do
    out[id] = items
  end
  for _, id in ipairs(MERGE_INTO) do
    local items = out[id]
    if items and #items > 0 then
      local changed
      for i, item in ipairs(items) do
        local u = by_text[text(item)]
        if u and not merged[u] then
          merged[u] = true
          changed = changed or vim.list_slice(items)
          local copy = vim.tbl_extend("force", {}, item)
          copy.score_offset = (copy.score_offset or 0) + u.used.boost + 1
          local note = ("used %d×"):format(u.used.count)
          local desc = item.labelDetails and item.labelDetails.description
          copy.labelDetails =
            vim.tbl_extend("force", item.labelDetails or {}, { description = desc and (desc .. ", " .. note) or note })
          changed[i] = copy
        end
      end
      out[id] = changed or items
    end
  end
  if next(merged) then
    out.used_values = vim.tbl_filter(function(item)
      return not merged[item]
    end, used)
  end
  return out
end

-- Snippets only complete what you're typing, they never turn an
-- abbreviation into something else: `ggp` offers `ggplot(df, aes(...)) +`,
-- but `fun` no longer becomes `name <- function(...)`. A snippet is offered
-- when the text it inserts starts with (the end of) the text before the
-- cursor, and is
-- listed by that text instead of by its trigger. Snippets that start with a
-- name you'd choose yourself (`${1:name} <- ...`) are left out: they would
-- "complete" any word that happens to match the placeholder.
local expanded_cache = {}
local function expanded(snippet_text)
  local text = expanded_cache[snippet_text]
  if not text then
    local parsed = require("blink.cmp.sources.snippets.utils").safe_parse(snippet_text)
    text = parsed and tostring(parsed) or snippet_text
    expanded_cache[snippet_text] = text
  end
  return text
end

-- Same case rule as 'smartcase': lowercase typing matches any case
local function starts_with(text, typed)
  if not typed:find("%u") then
    text, typed = text:lower(), typed:lower()
  end
  return text:sub(1, #typed) == typed
end

local function snippets_as_completions(ctx, items)
  local row, col = ctx.cursor[1] - 1, ctx.cursor[2]
  local run = ctx.line:sub(1, col):match("^%s*(.-)$") -- the line so far, minus indentation
  local keyword = ctx.get_keyword()
  -- A number being typed (x = 1) isn't the start of a date or a time;
  -- from four digits on (2026) it may be
  if keyword:match("^%d+$") and #keyword < 4 then
    return {}
  end
  -- In a member list (after `.`, `::` ...) the word alone never matches, so
  -- `x.fo` doesn't offer `for`; the whole run still does (`std::mt` offers
  -- `std::mt19937_64 gen{42};`)
  local member = ctx.trigger.initial_kind == "trigger_character"
  local shortest = member and #keyword + 1 or math.max(#keyword, 1)
  local out = {}
  for _, item in ipairs(items) do
    local body = item.textEdit and item.textEdit.newText or item.insertText or ""
    local text = expanded(body)
    if not body:match("^%$") then
      -- Longest piece of what was typed that the snippet's text starts with:
      -- at least the current word, plus whatever comes before it, so
      -- ```{r, --- and "# Appendix" work too
      for n = #run, shortest, -1 do
        local typed = run:sub(-n)
        if starts_with(text, typed) then
          local first = text:match("^[^\n]*")
          item.label = first ~= text and first .. " …" or first
          item.filterText = first:sub(n - #keyword + 1)
          -- Matched more than the word being typed (`# App`, ```{r): a
          -- strong hint, so rank it above Codeium and plain words
          if n > #keyword then
            item.score_offset = (item.score_offset or 0) + 3
          end
          item.textEdit = {
            newText = body,
            range = { start = { line = row, character = col - n }, ["end"] = { line = row, character = col } },
          }
          out[#out + 1] = item
          break
        end
      end
    end
  end
  return out
end

-- Language servers send snippets too (e.g. lua_ls's `for .. ipairs`): keep
-- the ones whose text starts with the word being typed, and drop "postfix"
-- ones that rewrite the code before the cursor (additionalTextEdits)
local function lsp_snippet_is_completion(ctx, item)
  if item.kind ~= require("blink.cmp.types").CompletionItemKind.Snippet then
    return true
  end
  local keyword = ctx.get_keyword()
  local body = item.textEdit and item.textEdit.newText or item.insertText or item.label
  return #keyword > 0
    and not (item.additionalTextEdits and #item.additionalTextEdits > 0)
    and starts_with(expanded(body), keyword)
end

-- Argument names already given in this call aren't offered again, by name
-- or by position (when the server's signature for the call is known, see
-- cmp-signature.lua): read.csv(f, header = TRUE, | suggests neither
-- `header = ` nor `file = `. R's `...` isn't an argument you can name.
-- Runs on every source's items (kernel arguments too).
local function without_given_args(ctx, items)
  if ctx.mode == "cmdline" then
    return items
  end
  local has_args = false
  for _, item in ipairs(items) do
    if is_arg(item) then
      has_args = true
      break
    end
  end
  if not has_args then
    return items
  end
  local context = require("config.cmp-context")
  local call = context.open_calls()[1]
  -- After `method = ` comes a value, not another argument name
  local current = call and context.top_level(call.args):match("[^,]*$") or ""
  if current:match("^%s*[%a._][%w._]*%s*=") and not current:match("^%s*[%w._]+%s*==") then
    return vim.tbl_filter(function(item)
      return not is_arg(item)
    end, items)
  end
  local sig = require("config.cmp-signature")
  local given = sig.filled(sig.cached(ctx.bufnr), context.call_args(call))
  return vim.tbl_filter(function(item)
    local name = item.label:match("^([%w._]+)%s*=%s*$")
    return not (name and given[name]) and not item.label:match("^%.%.%.%s*=")
  end, items)
end

-- Language server / kernel / buffer items for a typed slot (cmp-slot.lua):
-- what can't go there is dropped, what fits is ranked first. Objects in
-- the kernel's session are known by type (data frame, function, logical,
-- ...), data frames read from files by cmp-columns.lua.
--   function   FUN = |       functions only
--   data       data = |      no functions; data frames first
--   colour     colour = |    no functions (variables can hold colours)
--   logical / number / string / choice / column: functions ranked lower
--              (n = nrow(df) is fine, but rarely what you want)
-- and nowhere typed: snippets, modules, the R server's plain-word items.
local GENERAL_SOURCES = { lsp = true, kernel = true, buffer = true }
local OBJECT_KINDS = { Variable = true, Field = true, Constant = true, Value = true, Property = true, Reference = true }
local FUNCTION_KINDS = { Function = true, Method = true, Constructor = true }
local CALLABLE_KINDS = { Function = true, Method = true, Constructor = true, Class = true, Struct = true }
local NEVER_TYPED = { Snippet = true, Module = true, Text = true, Keyword = true, Folder = true, File = true }
-- The next step of an R chain (cmp-slot.lua):
--   ggplot(df, aes(x, y)) +
--     g|          geom_*, scale_*, theme*, labs, facet_*, ... and ggplot
--                 objects in the session (my_theme) first
--   df |>
--     s|          select, summarise, slice_* (dplyr / tidyr) before sd, seq;
--                 objects last: a call has to come after |>
local GGPLOT_PARTS = {
  "^geom_",
  "^stat_",
  "^scale_",
  "^theme",
  "^labs$",
  "^facet_",
  "^coord_",
  "^guides?$",
  "^annotate$",
  "^[xy]lab$",
  "^ggtitle$",
  "^[xy]?lims?$",
  "^expand_limits$",
}
local GGPLOT_PACKAGES =
  { ggplot2 = true, ggrepel = true, patchwork = true, ggthemes = true, ggridges = true, ggforce = true }
local PIPE_PACKAGES = { dplyr = true, tidyr = true, janitor = true }
local PIPE_FUNCTIONS = {}
for _, name in ipairs(require("config.cmp-context").data_verbs) do
  PIPE_FUNCTIONS[name] = true
end
for _, name in ipairs({
  "ungroup",
  "rowwise",
  "slice",
  "slice_head",
  "slice_tail",
  "slice_sample",
  "left_join",
  "right_join",
  "inner_join",
  "full_join",
  "anti_join",
  "semi_join",
  "bind_rows",
  "bind_cols",
  "glimpse",
  "head",
  "tail",
  "complete",
  "replace_na",
  "clean_names",
}) do
  PIPE_FUNCTIONS[name] = true
end

local function chain_rank(slot, items, keyword, objects)
  local kinds = require("blink.cmp.types").CompletionItemKind
  for _, item in ipairs(items) do
    local kind = kinds[item.kind] or ""
    local name = item.label:gsub("%(.*$", "")
    local pkg = type(item.detail) == "string" and item.detail:match("^{(.+)}$")
    local callable = CALLABLE_KINDS[kind] or objects[name] == "function" or item.label:match("%($")
    local general = GENERAL_SOURCES[item.source_id] and not NEVER_TYPED[kind]
    local boost = 0
    if slot.chain == "ggplot" then
      local part = false
      for _, pat in ipairs(GGPLOT_PARTS) do
        part = part or name:match(pat) ~= nil
      end
      if objects[name] == "layer" or (callable and part) then
        boost = 6
      elseif callable and pkg and GGPLOT_PACKAGES[pkg] then
        boost = 3
      elseif general and not callable then
        boost = -4
      end
    else
      if callable and PIPE_FUNCTIONS[name] then
        boost = 8 -- the verbs themselves before dplyr's other functions
      elseif callable and pkg and PIPE_PACKAGES[pkg] then
        boost = 5
      elseif callable and (name == "ggplot" or pkg == "ggplot2") then
        boost = 3
      elseif general and not callable then
        boost = -8
      end
    end
    if #keyword > 0 and item.label:sub(1, #keyword) == keyword then
      boost = boost + 3
    end
    if boost ~= 0 then
      item.score_offset = (item.score_offset or 0) + boost
    end
  end
  return items
end

local function fits_slot(ctx, items)
  if ctx.mode == "cmdline" or #items == 0 then
    return items
  end
  local slot_lib = require("config.cmp-slot")
  local slot = slot_lib.here()
  local t = slot.type
  if slot.where == "chain" then
    return chain_rank(slot, items, ctx.get_keyword(), slot_lib.object_types("r"))
  end
  -- After a space in quoted text (labs(title = "Fuel use by |), only
  -- Codeium's continuation, not every word in the buffer
  if t == "text" and slot.quoted and ctx.get_keyword() == "" then
    return vim.tbl_filter(function(item)
      return item.source_id == "codeium"
    end, items)
  end
  -- After df$ / obj. only members fit, not the R server's plain words
  if slot.where == "member" then
    local kinds = require("blink.cmp.types").CompletionItemKind
    return vim.tbl_filter(function(item)
      return not (GENERAL_SOURCES[item.source_id] and NEVER_TYPED[kinds[item.kind] or ""])
    end, items)
  end
  if not t or t == "text" then
    return items
  end
  local kinds = require("blink.cmp.types").CompletionItemKind
  local objects = slot.lang and slot_lib.object_types(slot.lang) or {}
  local frames = {}
  if t == "data" and slot.lang then
    frames = require("config.cmp-columns").frame_names(ctx.bufnr, slot.lang) or {}
  end
  local keyword = ctx.get_keyword()
  local out = {}
  for _, item in ipairs(items) do
    local kind = kinds[item.kind] or ""
    local name = item.label:match("^[%w._]+$") and item.label
    local typed = name and objects[name]
    -- The R server's package objects: `{grDevices}`, `{datasets}`, ...
    local pkg = type(item.detail) == "string" and item.detail:match("^{(.+)}$")
    local keep, boost = true, 0
    if t == "level" and is_arg(item) then
      keep = false -- filter(df, sex == |: a value, not `.by = `
    elseif not GENERAL_SOURCES[item.source_id] or (is_arg(item) and slot.where == "arg") then
      keep = true -- slot-specific sources (arg values, columns, colours) and argument names
    elseif item.source_id == "kernel" and next(objects) and not typed then
      -- The kernel lists base and package names too, all as plain
      -- variables; the language server has the same with their real kinds
      keep = false
    elseif NEVER_TYPED[kind] or item.detail == "Auto-import" then
      keep = false -- (basedpyright's imports from other modules: T, TAB0, ...)
    elseif
      t == "logical"
      and (
        item.label:match("^TRUE$")
        or item.label:match("^FALSE$")
        or item.label:match("^True$")
        or item.label:match("^False$")
      )
    then
      keep = false -- the values source has them, the other one first
    elseif pkg and not FUNCTION_KINDS[kind] and not (t == "data" and pkg == "datasets") then
      keep = false -- blues9, .LC.categories, class_scale: not what you'd pass
    elseif t == "function" then
      keep = CALLABLE_KINDS[kind] or typed == "function"
    elseif t == "data" then
      keep = not FUNCTION_KINDS[kind] and (typed == nil or typed == "data")
      boost = (typed == "data" or frames[item.label]) and 8 or 0
    elseif t == "colour" then
      keep = not FUNCTION_KINDS[kind] and typed ~= "function"
    else
      if CALLABLE_KINDS[kind] or typed == "function" then
        boost = -5
      elseif typed == t or (t == "choice" and typed == "string") then
        boost = 6
      elseif OBJECT_KINDS[kind] and t ~= "column" then
        boost = 1
      end
    end
    -- What starts with the typed word before what merely contains its
    -- letters (FUN = me: mean before as.double.difftime)
    if keep and #keyword > 0 and item.label:sub(1, #keyword) == keyword then
      boost = boost + 3
    end
    if keep then
      if boost ~= 0 then
        item.score_offset = (item.score_offset or 0) + boost
      end
      out[#out + 1] = item
    end
  end
  return out
end

-- Inside an R / Python call, ask for the call's signature alongside the
-- language server's completions and hold those until it's known (at most
-- 200 ms, and only once per call), so the filter above can tell which
-- arguments were given by position
local function lsp_with_signature(source, ctx, callback)
  local lang = region().lang
  if not (lang == "r" or lang == "python") or not require("config.cmp-context").open_calls()[1] then
    return source:get_completions(ctx, callback)
  end
  -- Without the signature yet, have blink ask again on the next keystroke
  -- (it would otherwise keep filtering this list), when it may be known
  local waiting, held, known = true, nil, false
  local function deliver(response)
    if response and not known then
      response.is_incomplete_forward = true
    end
    callback(response)
  end
  require("config.cmp-signature").fetch(ctx.bufnr, function(sig)
    waiting, known = false, sig ~= nil
    if held then
      deliver(held)
      held = nil
    end
  end)
  return source:get_completions(ctx, function(response)
    if waiting then
      held = response
    else
      deliver(response)
    end
  end)
end

-- In Rmd / Quarto / notebooks, buffer words follow the region: an R chunk
-- gets words used as R code (not "the" or "results" from the text around
-- it), and prose gets words used in prose (not df_clean or geom_point).
-- Words seen nowhere yet (just typed) are always kept. After df$ there
-- are no buffer words at all, only the columns.
local function region_words(ctx, items)
  local known = require("config.cmp-columns").known_here(ctx)
  if known and known.only then
    return {} -- df$ / df["…"]: only columns fit (cmp-columns.lua)
  end
  local buf = vim.api.nvim_get_current_buf()
  if not require("config.rmd-latex-hl").handles(buf) then
    return items
  end
  local r = region()
  local want = r.kind == "prose" and "prose" or r.kind == "code" and r.lang or nil
  if not want then
    return items
  end
  local where = require("config.cmp-context").word_langs(buf)
  return vim.tbl_filter(function(item)
    local seen = where[item.label]
    return seen == nil or seen[want] == true
  end, items)
end

-- Buffer words come from every loaded file buffer, not only visible ones
local function file_buffers()
  return vim.tbl_filter(function(buf)
    return vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == ""
  end, vim.api.nvim_list_bufs())
end

return {
  -- Codeium AI completions, shown as a blink.cmp source (free account needed)
  {
    "Exafunction/codeium.nvim",
    dependencies = { "nvim-lua/plenary.nvim" }, -- blink.cmp (below) loads this as a source
    -- Run `:Codeium Auth` once to log in
    opts = {
      enable_cmp_source = false, -- Disable legacy nvim-cmp wrapper
      virtual_text = { enabled = false }, -- suggestions go through blink.cmp instead
    },
  },

  -- Completion menu
  -- Not lazy-loaded: blink's plugin/ file adds its LSP capabilities to
  -- vim.lsp.config('*'), which has to happen before the first server starts.
  {
    "saghen/blink.cmp",
    dependencies = {
      "rafamadriz/friendly-snippets",
      "Exafunction/codeium.nvim",
      "ribru17/blink-cmp-spell", -- dictionary words in prose
    },
    version = "1.*",

    config = function(_, opts)
      require("blink.cmp").setup(opts)
      -- blink has no hook over all sources' items together, which the
      -- kernel / language server de-dup needs: wrap the step that filters
      -- them for the menu. If blink renames it, completion just keeps both.
      local list = require("blink.cmp.completion.list")
      local fuzzy = list.fuzzy
      if type(fuzzy) == "function" then
        list.fuzzy = function(context, items_by_source)
          local ok, merged = pcall(drop_kernel_duplicates, items_by_source)
          merged = ok and merged or items_by_source
          local ok2, with_used = pcall(merge_used_values, merged)
          return fuzzy(context, ok2 and with_used or merged)
        end
      end
      -- `alpha=` with no space (the usual Python style): open the menu
      -- right after the `=` when there are values for the argument (a
      -- signature's choices, or values used elsewhere in the file). With a
      -- space, show_on_blocked_trigger_characters below does it.
      vim.api.nvim_create_autocmd("TextChangedI", {
        group = vim.api.nvim_create_augroup("cmp_value_after_equals", { clear = true }),
        callback = function()
          local col = vim.api.nvim_win_get_cursor(0)[2]
          if not vim.api.nvim_get_current_line():sub(1, col):match("[%w_]=$") then
            return
          end
          local lang = region().lang
          if
            (lang == "python" or lang == "r")
            and (require("config.cmp-arg-values").values_here() or require("config.cmp-used-values").any_here())
          then
            -- after blink has handled the `=` (which closes the menu)
            local tick = vim.b.changedtick
            vim.schedule(function()
              if vim.b.changedtick == tick and vim.fn.mode() == "i" then
                require("blink.cmp").show()
              end
            end)
          end
        end,
      })
    end,

    opts = {
      keymap = {
        preset = "super-tab",
      },

      appearance = {
        nerd_font_variant = "mono",
      },

      -- Window borders are left unset so they follow vim.o.winborder
      completion = {
        menu = {
          draw = {
            treesitter = { "lsp" }, -- highlight LSP labels like code
            columns = {
              { "kind_icon" },
              { "label", "label_description", gap = 1 },
              { "source_name" },
            },
          },
        },
        documentation = {
          auto_show = true,
          auto_show_delay_ms = 200,
        },
        -- Ghost text (the rest of the item drawn inline and on the lines
        -- below) only for multi-line snippets, where seeing what the whole
        -- block will look like before accepting it is worth the clutter
        ghost_text = {
          enabled = function()
            local item = require("blink.cmp").get_selected_item()
            local text = item and (item.textEdit and item.textEdit.newText or item.insertText)
            return item ~= nil
              and item.kind == require("blink.cmp.types").CompletionItemKind.Snippet
              and text ~= nil
              and text:find("\n") ~= nil
          end,
        },
        -- Moving through the menu only selects; nothing is written into the
        -- line until the item is accepted
        list = { selection = { auto_insert = false } },
        trigger = {
          show_on_keyword = true,
          show_on_trigger_character = true,
          -- Spaces never open the menu, except right after an `=` in maths,
          -- so the result of `\frac{1+1}{5} = ` shows up (cmp-latex-calc.lua),
          -- after an R argument that takes one of a few values (`method = `,
          -- cmp-arg-values.lua) or was given a value elsewhere in the file
          -- (`alpha = `, cmp-used-values.lua). Braces likewise only after
          -- `= \fbox{` (autopairs types `{}`), not in \frac{. Region checks
          -- only when one of those was typed.
          show_on_blocked_trigger_characters = function()
            local before = vim.api.nvim_get_current_line():sub(1, vim.api.nvim_win_get_cursor(0)[2])
            local answer = before:match("=%s+$") or before:match("=%s*\\%a+{$")
            if (answer or before:match("[{}]$")) and region().kind == "math" then
              return answer and { "\n", "\t" } or { " ", "\n", "\t", "{", "}" }
            end
            if
              before:match("[%w._]%s*=%s+$")
              and (require("config.cmp-arg-values").values_here() or require("config.cmp-used-values").any_here())
            then
              return { "\n", "\t" }
            end
            -- after `sex == ` / `cyl %in% c(4, ` where the column's values
            -- are known (cmp-columns.lua)
            if
              (before:match("[=!]=%s+$") or before:match(",%s+$"))
              and require("config.cmp-slot").here().type == "level"
            then
              return { "\n", "\t" }
            end
            -- and while writing text for people in quotes (labs(title =
            -- "Fuel use by ), where Codeium continues the sentence
            if before:match("%S%s$") then
              local slot = require("config.cmp-slot").here()
              if slot.type == "text" and slot.quoted then
                return { "\n", "\t" }
              end
            end
            return { " ", "\n", "\t" }
          end,
        },
      },

      signature = { enabled = true },

      -- `:` commands: show the menu as you type (blink only opens it on Tab
      -- by default). Nothing is preselected, so <CR> runs what you typed and
      -- Tab picks the first item; <Left>/<Right> move the cursor as usual
      -- instead of moving through the menu.
      cmdline = {
        keymap = { preset = "cmdline", ["<Left>"] = false, ["<Right>"] = false },
        completion = {
          menu = {
            auto_show = function(ctx)
              return ctx.mode == "cmdwin" or vim.fn.getcmdtype() == ":"
            end,
          },
          list = { selection = { preselect = false } },
          ghost_text = { enabled = false }, -- only for big snippets (above)
        },
      },

      sources = {
        -- Every source's items, after the source's own transform_items
        transform_items = function(ctx, items)
          return fits_slot(ctx, without_given_args(ctx, items))
        end,
        -- Chosen by where the cursor is, so an R chunk in an Rmd completes
        -- R while the prose around it completes words.
        default = function()
          local r = region()
          -- "code" too: right after typing `"` the string isn't closed yet
          -- and treesitter doesn't see it as one
          if (r.kind == "string" or r.kind == "code") and require("config.cmp-context").file_arg() then
            -- read.csv("…"): file names; lsp stays for Python Literal/dict keys.
            -- No Codeium: it can only guess names the file source knows.
            return { "file_args", "lsp" }
          end
          -- ![](…) / [text](…) and bibliography: in a YAML header
          if (r.kind == "prose" or r.kind == "yaml") and require("config.cmp-context").file_arg() then
            return { "file_args" }
          end
          if SOURCES_BY_REGION[r.kind] then
            return SOURCES_BY_REGION[r.kind]
          end
          -- R / Python: by what goes at the cursor (slot_sources, above)
          return slot_sources(require("config.cmp-slot").here()) or DEFAULT_SOURCES
        end,
        per_filetype = {
          lua = { inherit_defaults = true, "lazydev" },
        },
        providers = {
          lsp = {
            -- Rank _private / __dunder__ names below public ones unless
            -- the word being typed starts with `_`
            transform_items = function(ctx, items)
              items = vim.tbl_filter(function(item)
                return lsp_snippet_is_completion(ctx, item)
              end, items)
              local private_ok = ctx.get_keyword():sub(1, 1) == "_"
              items = normalize_args(current_arg_values(items))
              -- The columns source (cmp-columns.lua) knows this data frame:
              -- don't list its columns twice, and after df$ / in df["…"]
              -- drop the server's guesses
              local known = require("config.cmp-columns").known_here(ctx)
              if known then
                items = vim.tbl_filter(function(item)
                  return not known.only and not known.names[item.label]
                end, items)
              end
              for _, item in ipairs(items) do
                if not private_ok and item.label:sub(1, 1) == "_" then
                  item.score_offset = (item.score_offset or 0) - 10
                end
                -- Argument names (R `header = `, Python `header=`) only come
                -- back inside a call, where they're what you're most likely
                -- typing: rank them above functions like head()
                if is_arg(item) then
                  item.score_offset = (item.score_offset or 0) + 5
                end
              end
              return items
            end,
            override = { get_completions = lsp_with_signature },
          },
          snippets = {
            -- No `for`/`if` snippets in member lists after `.`, `:` etc.:
            -- snippets_as_completions only matches the whole run there
            transform_items = snippets_as_completions,
            -- The source says its list never changes as you type, so blink
            -- would keep fuzzy-matching the first list (`gp` would still
            -- offer ggplot). Ask again on every keystroke so the prefix rule
            -- above holds; snippets are cached in memory, so this is cheap.
            override = {
              get_completions = function(source, ctx, callback)
                return source:get_completions(ctx, function(response)
                  if response then
                    response.is_incomplete_forward = true
                    response.is_incomplete_backward = true
                  end
                  callback(response)
                end)
              end,
            },
            opts = {
              -- Snippets for the language under the cursor: R snippets in an
              -- R chunk, the file's own type elsewhere
              get_filetype = function()
                local r = region()
                if r.kind == "code" or r.kind == "string" or r.kind == "comment" then
                  return r.lang
                end
                return vim.bo.filetype
              end,
              -- friendly-snippets gives rmd the R snippets too; R chunks get
              -- them as "r" above, so keep them out of the prose
              filter_snippets = function(ft, file)
                return not (ft == "rmd" and file:match("/r%.json$"))
              end,
            },
          },
          file_args = {
            name = "Files",
            module = "config.cmp-file-args",
            score_offset = 5,
          },
          spell = {
            name = "Spell",
            module = "blink-cmp-spell",
            -- Below words from your files and Codeium, so Tab doesn't swap
            -- a half-typed word for a "correction"
            score_offset = -5,
            -- The source matches every correction against the word as typed,
            -- which makes each one an "exact" match (sorted first, see
            -- fuzzy.sorts). Match on the correction itself instead: "word"
            -- still matches "wor", "or" no longer does.
            transform_items = function(_, items)
              for _, item in ipairs(items) do
                item.filterText = item.label
              end
              return items
            end,
            opts = {
              max_entries = 3,
              preselect_current_word = false, -- correctly spelled: offer nothing
            },
          },
          latex_math = {
            name = "LaTeX",
            module = "config.cmp-latex-math",
            score_offset = 5,
          },
          latex_calc = {
            name = "Calc",
            module = "config.cmp-latex-calc",
            -- Its items are 10 apart (0, -10, -20); even the last stays
            -- above Codeium, so Tab takes the result
            score_offset = 30,
          },
          buffer = {
            opts = { get_bufnrs = file_buffers },
            transform_items = region_words,
          },
          -- "pearson" / "kendall" / "spearman" after cor(x, method = , and
          -- TRUE / FALSE for logical arguments, from the call's signature
          arg_values = {
            name = "Values",
            module = "config.cmp-arg-values",
            score_offset = 10, -- above argument names and objects
            async = true,
            timeout_ms = 300,
          },
          -- 0.6 after alpha = when alpha = 0.6 is written elsewhere in the
          -- file (cmp-used-values.lua); just under the signature's values
          used_values = {
            name = "Used",
            module = "config.cmp-used-values",
            score_offset = 8,
          },
          -- "steelblue", "tab:blue" where a colour goes (cmp-colours.lua)
          colours = {
            name = "Colours",
            module = "config.cmp-colours",
            score_offset = 10,
          },
          -- Objects, columns and arguments from the running R / Python kernel
          kernel = {
            name = "Kernel",
            module = "config.kernel.complete",
            score_offset = 3,
            async = true,
            timeout_ms = 500,
          },
          -- df$col, df["col"], select(col) from the files the buffer reads
          columns = {
            name = "Columns",
            module = "config.cmp-columns",
            score_offset = 5,
          },
          codeium = {
            name = "Codeium",
            -- codeium.nvim's blink source, plus the chunk outputs shown
            -- inline (lua/config/kernel/inline.lua), so prose about a chunk
            -- can use its results
            module = "config.cmp-codeium",
            -- Only ask Codeium in real file buffers. Special buffers like
            -- oil:///path/ make the Codeium server fail with
            -- "empty share name for UNC-like path".
            enabled = function()
              local buf = vim.api.nvim_get_current_buf()
              if vim.bo[buf].buftype ~= "" then
                return false
              end
              local name = vim.api.nvim_buf_get_name(buf)
              return not name:match("^%a[%w+.-]*://")
            end,
            -- Don't hold the menu for the network round trip: LSP/snippet
            -- items show right away and Codeium's join when they arrive.
            async = true,
            timeout_ms = 1000,
            -- In text for people (labs(title = "…"), see slot_sources) it's
            -- the one that knows what comes next: first there
            transform_items = function(ctx, items)
              items = codeium_eat_closers(ctx, items)
              local slot = require("config.cmp-slot").here()
              if slot.type == "text" and slot.quoted then
                for _, item in ipairs(items) do
                  item.score_offset = (item.score_offset or 0) + 8
                end
              end
              return items
            end,
            -- Just below LSP, so Tab (super-tab) accepts the LSP item first
            score_offset = -2,
            max_items = 3,
          },
          -- Neovim/plugin Lua API while editing this config (lazydev.lua)
          lazydev = {
            name = "LazyDev",
            module = "lazydev.integrations.blink",
            score_offset = 100, -- above lua_ls, which repeats these items
          },
        },
      },

      fuzzy = {
        implementation = "prefer_rust_with_warning",
        -- An item matching the typed word exactly always comes first;
        -- frecency and proximity (on by default) order the rest
        sorts = { "exact", "score", "sort_text" },
      },
    },
  },
}
