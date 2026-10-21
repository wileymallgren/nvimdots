-- Which part of the file the cursor is in (comment / string / math / yaml /
-- prose / code, and the language there): lua/config/cmp-context.lua
local function region()
  return require("config.cmp-context").region()
end

-- Sources for each kind of region; anything else gets the default list
local DEFAULT_SOURCES = { "lsp", "path", "snippets", "buffer", "codeium" }
local SOURCES_BY_REGION = {
  -- language-server items (keywords, builtins, members) are noise here
  comment = { "buffer", "path", "spell", "codeium" },
  -- \frac, \alpha, ... (friendly-snippets' tex set is document-level:
  -- \plotgraph3d, \fractionlarge, ... and would outrank \frac)
  math = { "latex_math", "codeium" },
  yaml = { "buffer", "path" },
  -- spelling corrections for misspelled words (spell is on in prose
  -- filetypes, see lua/config/options.lua)
  prose = { "lsp", "path", "snippets", "buffer", "spell", "codeium" },
}

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

-- R code gets completions from both r_language_server and R.nvim's r_ls,
-- mostly the same names twice (`file` and `file = `). Keep r_ls's copy (it
-- knows the running R session and its data frames) and drop
-- r_language_server's item for any name r_ls also returned.
local function drop_r_duplicates(items)
  local names = {} -- client id -> name
  local function client(item)
    if names[item.client_id] == nil then
      local c = vim.lsp.get_client_by_id(item.client_id)
      names[item.client_id] = c and c.name or false
    end
    return names[item.client_id]
  end
  local function key(label)
    return (label:gsub("%s*=%s*$", ""):gsub("%(.*$", ""))
  end
  local from_r_ls = {}
  for _, item in ipairs(items) do
    if client(item) == "r_ls" then
      from_r_ls[key(item.label)] = true
    end
  end
  if next(from_r_ls) == nil then
    return items
  end
  return vim.tbl_filter(function(item)
    return not (client(item) == "r_language_server" and from_r_ls[key(item.label)])
  end, items)
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
  local out = {}
  for _, item in ipairs(items) do
    local body = item.textEdit and item.textEdit.newText or item.insertText or ""
    local text = expanded(body)
    if not body:match("^%$") then
      -- Longest piece of what was typed that the snippet's text starts with:
      -- at least the current word, plus whatever comes before it, so
      -- ```{r, --- and "# Appendix" work too
      for n = #run, math.max(#keyword, 1), -1 do
        local typed = run:sub(-n)
        if starts_with(text, typed) then
          local first = text:match("^[^\n]*")
          item.label = first ~= text and first .. " …" or first
          item.filterText = first:sub(n - #keyword + 1)
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
        trigger = {
          show_on_keyword = true,
          show_on_trigger_character = true,
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
        -- Chosen by where the cursor is, so an R chunk in an Rmd completes
        -- R while the prose around it completes words.
        default = function()
          local r = region()
          -- "code" too: right after typing `"` the string isn't closed yet
          -- and treesitter doesn't see it as one
          if (r.kind == "string" or r.kind == "code") and require("config.cmp-context").file_arg() then
            -- read.csv("…"): file names; lsp stays for Python Literal/dict keys
            return { "file_args", "lsp", "codeium" }
          end
          return SOURCES_BY_REGION[r.kind] or DEFAULT_SOURCES
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
              end, drop_r_duplicates(items))
              local private_ok = ctx.get_keyword():sub(1, 1) == "_"
              for _, item in ipairs(items) do
                if not private_ok and item.label:sub(1, 1) == "_" then
                  item.score_offset = (item.score_offset or 0) - 10
                end
                -- Argument names (R `header = `, Python `header=`) only come
                -- back inside a call, where they're what you're most likely
                -- typing: rank them above functions like head()
                if item.label:match("=%s*$") then
                  item.score_offset = (item.score_offset or 0) + 5
                end
              end
              return items
            end,
          },
          snippets = {
            -- No `for`/`if` snippets in member lists after `.`, `:` etc.
            should_show_items = function(ctx)
              return ctx.trigger.initial_kind ~= "trigger_character"
            end,
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
          buffer = {
            opts = { get_bufnrs = file_buffers },
          },
          codeium = {
            name = "Codeium",
            module = "codeium.blink", -- Uses the fast native blink wrapper
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
            transform_items = codeium_eat_closers,
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
