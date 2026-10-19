-- Parser-independent highlighting for raw LaTeX in Rmd / Quarto / markdown.
--
--  * Everything inside $...$, $$...$$, \(...\), \[...\] and math environments
--    (equation, align, ...) gets a base colour (blue, via RmdMath -> Function),
--    including the $$ delimiters, so plain text, operators and brackets are
--    no longer white. Treesitter's more specific colours (numbers, \frac,
--    \times, \text{...}) still win on top of it.
--  * Raw LaTeX in prose is styled: \begin / \end and the environment name,
--    \item (drawn as a bullet or a number), \texttt{...} as code, \textbf{...}
--    bold, \textit/\emph italic, other \commands, and & / \\ inside tables.
--  * Code chunks, inline code (`...`) and YAML front matter are skipped. Which
--    parts are code comes from the markdown treesitter parsers, so this
--    agrees with treesitter's own highlighting.
--  * $$...$$ and \[...\] end at a blank line (as in pandoc), so a missing
--    closer doesn't colour the rest of the file.
--
-- Text objects (visual / operator-pending, in these filetypes):
--   i$  inside the maths under the cursor: $...$, $$...$$, \(...\), \[...\]
--       or a math environment. When the delimiters are on lines of their own,
--       selects the lines between them.
--   a$  the same, including the delimiters / \begin and \end.
--   With no maths under the cursor, both use the next maths on the line.
--   e.g. ci$ to rewrite an equation, ya$ to copy one, va$ to select it.
--
-- Drawn with a decoration provider, so no text is changed and nothing is
-- stored in the buffer. The \item bullet is an overlay and is hidden on the
-- cursor line so you can still edit the real text.

local M = {}

local cfg = {
  filetypes = { rmd = true, quarto = true, markdown = true },
  -- Above treesitter's default captures (100) so the maths base colour also
  -- covers brackets/operators, but below the specific patterns (130).
  math_priority = 101,
  prose_priority = 110,
  bullets = false, -- true = draw \item as a bullet / number; false = just colour it
}

-- highlight group -> group it links to (override these in your config if you like)
local links = {
  RmdMath = "Function", -- the blue for maths
  RmdTexKeyword = "@keyword",
  RmdTexEnv = "@type",
  RmdTexItem = "@markup.list",
  RmdTexCommand = "@function.macro",
  RmdTexCode = "@markup.raw",
  RmdTexBold = "@markup.strong",
  RmdTexItalic = "@markup.italic",
  RmdTexDelim = "@punctuation.special",
  RmdTexBracket = "@punctuation.bracket",
}

local function define_hl()
  for name, target in pairs(links) do
    vim.api.nvim_set_hl(0, name, { link = target, default = true })
  end
  -- Inline code (queries/markdown_inline/highlights.scm): @markup.raw, but
  -- replacing rather than adding to the latex colours below it, so no bold /
  -- italic from \textbf or keywords shows through.
  local raw = vim.api.nvim_get_hl(0, { name = "@markup.raw", link = false })
  raw.nocombine = true
  vim.api.nvim_set_hl(0, "@markup.raw.code_span", raw)
end

local MATH_ENVS = {}
for _, n in ipairs({
  "equation",
  "align",
  "alignat",
  "flalign",
  "gather",
  "multline",
  "eqnarray",
  "displaymath",
  "math",
}) do
  MATH_ENVS[n] = true
  MATH_ENVS[n .. "*"] = true
end

local LIST_ENVS = { itemize = true, enumerate = true, description = true }
local TAB_ENVS = { tabular = true, ["tabular*"] = true, tabularx = true, array = true, longtable = true }
local MASK = "\0" -- stands in for inline code while scanning; matches nothing
local WRAP = {
  texttt = "RmdTexCode",
  textbf = "RmdTexBold",
  textit = "RmdTexItalic",
  emph = "RmdTexItalic",
}

---------------------------------------------------------------------------
-- Scanning: buffer lines -> per-row segments
---------------------------------------------------------------------------

local function add(row, s, e, hl, prio, overlay)
  if s <= e then
    row[#row + 1] = { s = s, e = e, hl = hl, prio = prio, overlay = overlay }
  end
end

local function track(st, kind, env)
  if kind == "begin" then
    if LIST_ENVS[env] then
      st.stack[#st.stack + 1] = env
      st.counters[#st.stack] = 0
    elseif TAB_ENVS[env] then
      st.tab = st.tab + 1
    end
  else
    if LIST_ENVS[env] then
      for k = #st.stack, 1, -1 do
        local e = st.stack[k]
        st.stack[k] = nil
        st.counters[k] = nil
        if e == env then
          break
        end
      end
    elseif TAB_ENVS[env] then
      st.tab = math.max(st.tab - 1, 0)
    end
  end
end

-- Style raw LaTeX in prose within line[from..to]
local function prose(row, line, from, to, st)
  local P = cfg.prose_priority
  local pos = from
  while pos <= to do
    local p = line:find("[\\&]", pos)
    if not p or p > to then
      return
    end
    local c = line:sub(p, p)
    if c == "&" then
      if st.tab > 0 then
        add(row, p, p, "RmdTexDelim", P)
      end
      pos = p + 1
    else
      local nx = line:sub(p + 1, p + 1)
      if nx == "\\" then
        add(row, p, p + 1, "RmdTexDelim", P) -- \\ line break
        pos = p + 2
      elseif nx:match("%a") then
        local name = line:match("^%a+", p + 1)
        local ce = p + #name
        if name == "begin" or name == "end" then
          add(row, p, ce, "RmdTexKeyword", P)
          local a, b, env = line:find("^{([%w%*]+)}", ce + 1)
          if a then
            add(row, a, a, "RmdTexBracket", P)
            add(row, a + 1, b - 1, "RmdTexEnv", P)
            add(row, b, b, "RmdTexBracket", P)
            track(st, name, env)
            ce = b
          end
          pos = ce + 1
        elseif name == "item" then
          add(row, p, ce, "RmdTexItem", P)
          if cfg.bullets and line:sub(ce + 1, ce + 1) ~= "[" then
            local top = st.stack[#st.stack]
            local label
            if top == "itemize" then
              label = "  •  "
            elseif top == "enumerate" then
              st.counters[#st.stack] = (st.counters[#st.stack] or 0) + 1
              label = ("%3d. "):format(st.counters[#st.stack])
            end
            if label then
              add(row, p, ce, "RmdTexItem", P, label)
            end
          end
          pos = ce + 1
        elseif WRAP[name] and line:sub(ce + 1, ce + 1) == "{" then
          add(row, p, ce, "RmdTexCommand", P)
          local close = line:find("}", ce + 2, true)
          if close and close <= to then
            add(row, ce + 1, ce + 1, "RmdTexBracket", P)
            add(row, ce + 2, close - 1, WRAP[name], P)
            add(row, close, close, "RmdTexBracket", P)
            pos = close + 1
          else
            pos = ce + 1
          end
        else
          add(row, p, ce, "RmdTexCommand", P)
          pos = ce + 1
        end
      elseif nx == "" then
        pos = p + 1
      else
        pos = p + 2 -- escapes like \$ \% \&
      end
    end
  end
end

-- Next maths opener at/after pos: kind, start, end[, env name]
--   inline : "end" is the closing $
--   others : "end" is the last char of the opener token
-- Inline code has already been blanked out (MASK), so nothing in it matches.
local function next_opener(line, pos)
  local p = pos
  while true do
    p = line:find("[$\\]", p)
    if not p then
      return nil
    end
    if line:sub(p, p) == "\\" then
      local nx = line:sub(p + 1, p + 1)
      if nx == "[" then
        return "br", p, p + 1
      elseif nx == "(" then
        return "paren", p, p + 1
      elseif line:sub(p, p + 6) == "\\begin{" then
        local name = line:match("^\\begin{([%w%*]+)}", p)
        if name and MATH_ENVS[name] then
          return "env", p, p + #("\\begin{" .. name .. "}") - 1, name
        end
        p = p + 1
      else
        p = p + 2
      end
    else
      if line:sub(p, p + 1) == "$$" then
        return "dd", p, p + 1
      end
      -- inline $...$ with pandoc's rules: no space just inside the dollars,
      -- closing $ not followed by a digit (so "$5 and $10" is not maths).
      -- It can't run into inline code.
      local nx = line:sub(p + 1, p + 1)
      if nx ~= "" and not nx:match("%s") then
        local code = line:find(MASK, p + 1, true)
        local q = p + 1
        while true do
          q = line:find("$", q, true)
          if not q or (code and q > code) then
            break
          end
          local prev, after = line:sub(q - 1, q - 1), line:sub(q + 1, q + 1)
          if prev ~= "\\" and not prev:match("%s") and not after:match("%d") then
            return "inline", p, q
          end
          q = q + 1
        end
      end
      p = p + 1
    end
  end
end

---------------------------------------------------------------------------
-- Code: which parts of the buffer are code, according to treesitter
---------------------------------------------------------------------------

local queries -- nil = not tried yet, false = markdown parsers unavailable

local function get_queries()
  if queries == nil then
    local ok1, block =
      pcall(vim.treesitter.query.parse, "markdown", "(fenced_code_block) @code [(inline) (pipe_table_cell)] @inline")
    local ok2, inline = pcall(vim.treesitter.query.parse, "markdown_inline", "(code_span) @code")
    queries = ok1 and ok2 and { block = block, inline = inline } or false
  end
  return queries
end

-- Code spans in one paragraph's text, as { row, col, end_row, end_col } relative to it
local function inline_code(text, q)
  local out = {}
  local ok, sp = pcall(vim.treesitter.get_string_parser, text, "markdown_inline")
  if ok then
    for _, node in q:iter_captures(sp:parse()[1]:root(), text) do
      out[#out + 1] = { node:range() }
    end
  end
  return out
end

-- Returns code = { skip = { [row] = true }, spans = { [row] = { {s, e}, ... } } }
-- (1-based rows and columns, inclusive) and the paragraph cache for next time.
--
-- Only the markdown block tree is parsed here (the highlighter parses it
-- anyway); each paragraph's inline text is parsed on its own and cached by its
-- text, so an edit only re-parses the paragraph it touches. Parsing all the
-- inline injections instead costs ~35ms per edit on a 5000-line file.
local function find_code(buf, lines, old)
  local skip, spans, seen = {}, {}, {}
  local q = get_queries()
  local ok, parser = pcall(vim.treesitter.get_parser, buf, "markdown", { error = false })
  if not (q and ok and parser) then
    -- no parser: treat lines between ``` fences as code
    local fence = false
    for i, line in ipairs(lines) do
      if line:match("^%s*```") then
        fence, skip[i] = not fence, true
      elseif fence then
        skip[i] = true
      end
    end
    return { skip = skip, spans = spans }, seen
  end

  local tree = parser:parse()[1]
  for id, node in q.block:iter_captures(tree:root(), buf) do
    local sr, sc, er, ec = node:range()
    if q.block.captures[id] == "code" then
      for r = sr, ec == 0 and er - 1 or er do
        skip[r + 1] = true
      end
    else
      local text = vim.treesitter.get_node_text(node, buf)
      local found = seen[text] or old[text] or inline_code(text, q.inline)
      seen[text] = found
      for _, s in ipairs(found) do
        local r1, c1, r2, c2 = s[1] + sr, s[2], s[3] + sr, s[4]
        c1 = s[1] == 0 and c1 + sc or c1 -- first line of the text starts at sc
        c2 = s[3] == 0 and c2 + sc or c2
        for r = r1, r2 do
          local row = spans[r + 1] or {}
          spans[r + 1] = row
          row[#row + 1] = { r == r1 and c1 + 1 or 1, r == r2 and c2 or math.huge }
        end
      end
    end
  end
  return { skip = skip, spans = spans }, seen
end

-- line with every inline-code column replaced by MASK (same length)
local function mask(line, spans)
  for _, s in ipairs(spans or {}) do
    local a, b = s[1], math.min(s[2], #line)
    if a <= b then
      line = line:sub(1, a - 1) .. MASK:rep(b - a + 1) .. line:sub(b + 1)
    end
  end
  return line
end

---------------------------------------------------------------------------
-- Scan
---------------------------------------------------------------------------

-- $$ and \[ are inline in pandoc: they only count when the closer comes
-- before the paragraph ends (blank line or code chunk). Otherwise they're
-- literal text, so a stray or empty $$ doesn't colour the rest of the line.
local function closes(lines, code, i, line, from, closer)
  if line:find(closer, from, true) then
    return true
  end
  for j = i + 1, #lines do
    if code.skip[j] or lines[j]:match("^%s*$") then
      return false
    end
    if mask(lines[j], code.spans[j]):find(closer, 1, true) then
      return true
    end
  end
  return false
end

-- Returns segs (per row) and regions: every maths region for the text objects,
-- as { s = {row, col}, e = {row, col}, is = {row, col}, ie = {row, col} }
-- (outer start/end, inner start/end; 1-based, inclusive). An inner start can
-- sit just past the end of its line and an inner end at col 0, when the
-- delimiters are on lines of their own. Also returns the lines as scanned:
-- code chunks / YAML blank, inline code replaced by MASK.
local function scan(lines, code)
  local MP = cfg.math_priority
  local segs, regions, masked = {}, {}, {}
  local st = { stack = {}, counters = {}, tab = 0 }
  local in_yaml = false
  local mode -- nil | "dd" | "br" | "env:<name>"
  local open -- where the current multi-line region started: { row, col, opener end col }

  local function region(r1, c1, r2, c2, ir1, ic1, ir2, ic2)
    regions[#regions + 1] = { s = { r1, c1 }, e = { r2, c2 }, is = { ir1, ic1 }, ie = { ir2, ic2 } }
  end

  for i, raw in ipairs(lines) do
    local row = {}
    segs[i] = row

    local skip = false
    if in_yaml then
      skip = true
      if raw:match("^%-%-%-%s*$") or raw:match("^%.%.%.%s*$") then
        in_yaml = false
      end
    elseif i == 1 and raw:match("^%-%-%-%s*$") then
      in_yaml, skip = true, true
    else
      skip = code.skip[i] or false
    end

    masked[i] = ""
    if not skip then
      local line = mask(raw, code.spans[i])
      masked[i] = line
      local pos, n = 1, #line
      while pos <= n do
        if mode == "dd" or mode == "br" then
          local j = line:find(mode == "dd" and "$$" or "\\]", pos, true)
          if j then
            add(row, pos, j + 1, "RmdMath", MP)
            region(open[1], open[2], i, j + 1, open[1], open[3] + 1, i, j - 1)
            pos, mode = j + 2, nil
          else
            add(row, pos, n, "RmdMath", MP)
            pos = n + 1
          end
        elseif mode then -- inside a math environment
          local tok = "\\end{" .. mode:sub(5) .. "}"
          local a, b = line:find(tok, pos, true)
          if a then
            add(row, pos, a - 1, "RmdMath", MP)
            prose(row, line, a, b, st)
            region(open[1], open[2], i, b, open[1], open[3] + 1, i, a - 1)
            pos, mode = b + 1, nil
          else
            add(row, pos, n, "RmdMath", MP)
            pos = n + 1
          end
        else
          local kind, a, b, name = next_opener(line, pos)
          if not kind then
            prose(row, line, pos, n, st)
            pos = n + 1
          else
            if a > pos then
              prose(row, line, pos, a - 1, st)
            end
            if kind == "inline" then
              add(row, a, b, "RmdMath", MP)
              region(i, a, i, b, i, a + 1, i, b - 1)
              pos = b + 1
            elseif kind == "paren" then
              local j = line:find("\\)", b + 1, true)
              local e = j and j + 1 or n
              add(row, a, e, "RmdMath", MP)
              if j then
                region(i, a, i, e, i, b + 1, i, j - 1)
              end
              pos = e + 1
            elseif kind == "dd" or kind == "br" then
              if closes(lines, code, i, line, b + 1, kind == "dd" and "$$" or "\\]") then
                add(row, a, b, "RmdMath", MP)
                mode, open = kind, { i, a, b }
              end
              pos = b + 1
            else -- math environment
              prose(row, line, a, b, st)
              mode, open, pos = "env:" .. name, { i, a, b }, b + 1
            end
          end
        end
      end
    end
  end
  return segs, regions, masked
end

---------------------------------------------------------------------------
-- Math text objects: i$ / a$
---------------------------------------------------------------------------

local function before(a, b) -- position a <= position b
  return a[1] < b[1] or (a[1] == b[1] and a[2] <= b[2])
end

-- Region around the cursor (the innermost one), else the next one on the line
local function region_at(regions, cur)
  local best
  for _, r in ipairs(regions) do
    if before(r.s, cur) and before(cur, r.e) then
      if not best or before(best.s, r.s) then
        best = r
      end
    end
  end
  if best then
    return best
  end
  for _, r in ipairs(regions) do
    if r.s[1] == cur[1] and r.s[2] > cur[2] and (not best or r.s[2] < best.s[2]) then
      best = r
    end
  end
  return best
end

local get_segs -- defined below

-- Range for i$ / a$ at the cursor: start, end ({row, col}, 1-based) and
-- whether it is linewise; nil when there is nothing to select.
local function math_range(inner)
  local cur = vim.api.nvim_win_get_cursor(0)
  local r = region_at(select(2, get_segs(vim.api.nvim_get_current_buf())), { cur[1], cur[2] + 1 })
  if not r then
    return nil
  end
  if not inner then
    return r.s, r.e, false
  end
  local s, e = r.is, r.ie
  local last_before = vim.fn.getline(e[1]):sub(1, math.max(e[2], 0))
  -- delimiters on lines of their own: select the lines between them
  if s[2] > #vim.fn.getline(s[1]) and last_before:match("^%s*$") then
    if s[1] + 1 <= e[1] - 1 then
      return { s[1] + 1, 1 }, { e[1] - 1, 1 }, true
    end
  elseif before(s, e) then
    return s, e, false
  end
end

function M.select_math(inner)
  local s, e, linewise = math_range(inner)
  if not s then
    return
  end
  if vim.fn.mode():match("^[vV\22]") then
    vim.cmd("normal! \27")
  end
  vim.api.nvim_win_set_cursor(0, { s[1], s[2] - 1 })
  vim.cmd("normal! " .. (linewise and "V" or "v"))
  vim.api.nvim_win_set_cursor(0, { e[1], e[2] - 1 })
end

---------------------------------------------------------------------------
-- Decoration provider
---------------------------------------------------------------------------

local ns = vim.api.nvim_create_namespace("rmd_latex_hl")
local cache = {} -- buf -> { tick, segs, regions, paragraphs }

function get_segs(buf)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local c = cache[buf]
  if not c or c.tick ~= tick then
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local code, paragraphs = find_code(buf, lines, c and c.paragraphs or {})
    local segs, regions, masked = scan(lines, code)
    c = { tick = tick, segs = segs, regions = regions, masked = masked, paragraphs = paragraphs }
    cache[buf] = c
  end
  return c.segs, c.regions, c.masked
end

---------------------------------------------------------------------------
-- Shared with lua/config/tex-preview.lua, so previews and highlighting agree
-- on what is code and what is maths
---------------------------------------------------------------------------

-- Is this a markdown-like buffer (where `...` is code)?
function M.handles(buf)
  return cfg.filetypes[vim.bo[buf].filetype] == true
end

-- The buffer's lines with code chunks and YAML front matter blanked and inline
-- code replaced by MASK (same length, matches nothing). Only for M.handles().
function M.masked_lines(buf)
  return select(3, get_segs(buf))
end

-- Inline maths on one (masked) line, by the same rules as the highlighting:
-- { { s =, e =, text = }, ... } for $...$ and \(...\), e exclusive. Display
-- maths and environments are skipped over.
function M.inline_math(line)
  local out, pos = {}, 1
  while true do
    local kind, a, b, name = next_opener(line, pos)
    local e -- last char of this maths, nil when it runs past the line
    if kind == "inline" then
      e = b
    elseif kind == "paren" or kind == "dd" or kind == "br" then
      local closer = ({ paren = "\\)", dd = "$$", br = "\\]" })[kind]
      local j = line:find(closer, b + 1, true)
      e = j and j + 1
    elseif kind == "env" then
      e = select(2, line:find("\\end{" .. name .. "}", b + 1, true))
    end
    if not e then
      return out
    end
    local text = line:sub(a, e)
    if (kind == "inline" or kind == "paren") and not text:find(MASK, 1, true) then
      out[#out + 1] = { s = a, e = e + 1, text = text }
    end
    pos = e + 1
  end
end

function M.setup()
  define_hl()
  vim.api.nvim_create_autocmd("ColorScheme", { callback = define_hl })
  vim.api.nvim_create_autocmd("FileType", {
    pattern = vim.tbl_keys(cfg.filetypes),
    callback = function(args)
      for lhs, inner in pairs({ ["i$"] = true, ["a$"] = false }) do
        -- expr mapping so that with no maths around, an operator is cancelled
        -- (like yi( with no parens) instead of acting on an empty range
        vim.keymap.set({ "x", "o" }, lhs, function()
          if not math_range(inner) then
            return vim.fn.mode(1):match("^no") and "<Esc>" or ""
          end
          return ('<Cmd>lua require("config.rmd-latex-hl").select_math(%s)<CR>'):format(inner)
        end, { buffer = args.buf, expr = true, desc = (inner and "Inside" or "Around") .. " maths" })
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    callback = function(args)
      cache[args.buf] = nil
    end,
  })

  vim.api.nvim_set_decoration_provider(ns, {
    on_win = function(_, _, buf)
      if not cfg.filetypes[vim.bo[buf].filetype] then
        return false
      end
      get_segs(buf)
      return true
    end,
    on_line = function(_, win, buf, row)
      local c = cache[buf]
      local segs = c and c.segs[row + 1]
      if not segs then
        return
      end
      local cursor_row = vim.api.nvim_win_get_cursor(win)[1] - 1
      for _, s in ipairs(segs) do
        if s.overlay then
          if row ~= cursor_row then -- show the real text while editing the line
            vim.api.nvim_buf_set_extmark(buf, ns, row, s.s - 1, {
              virt_text = { { s.overlay, s.hl } },
              virt_text_pos = "overlay",
              ephemeral = true,
              priority = s.prio,
            })
          end
        else
          vim.api.nvim_buf_set_extmark(buf, ns, row, s.s - 1, {
            end_col = s.e,
            hl_group = s.hl,
            ephemeral = true,
            priority = s.prio,
          })
        end
      end
    end,
  })
end

return M
