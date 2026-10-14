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
--  * Code chunks (```) and YAML front matter are skipped.
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
      -- closing $ not followed by a digit (so "$5 and $10" is not maths)
      local nx = line:sub(p + 1, p + 1)
      if nx ~= "" and not nx:match("%s") then
        local q = p + 1
        while true do
          q = line:find("$", q, true)
          if not q then
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

local function scan(lines)
  local MP = cfg.math_priority
  local segs = {}
  local st = { stack = {}, counters = {}, tab = 0 }
  local in_fence, in_yaml = false, false
  local mode -- nil | "dd" | "br" | "env:<name>"

  for i, line in ipairs(lines) do
    local row = {}
    segs[i] = row

    local skip = false
    if in_yaml then
      skip = true
      if line:match("^%-%-%-%s*$") or line:match("^%.%.%.%s*$") then
        in_yaml = false
      end
    elseif i == 1 and line:match("^%-%-%-%s*$") then
      in_yaml, skip = true, true
    elseif line:match("^%s*```") then
      in_fence, skip = not in_fence, true
    elseif in_fence then
      skip = true
    end

    if not skip then
      local pos, n = 1, #line
      while pos <= n do
        if mode == "dd" then
          local j = line:find("$$", pos, true)
          if j then
            add(row, pos, j + 1, "RmdMath", MP)
            pos, mode = j + 2, nil
          else
            add(row, pos, n, "RmdMath", MP)
            pos = n + 1
          end
        elseif mode == "br" then
          local j = line:find("\\]", pos, true)
          if j then
            add(row, pos, j + 1, "RmdMath", MP)
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
              pos = b + 1
            elseif kind == "paren" then
              local j = line:find("\\)", b + 1, true)
              local e = j and j + 1 or n
              add(row, a, e, "RmdMath", MP)
              pos = e + 1
            elseif kind == "dd" then
              add(row, a, b, "RmdMath", MP)
              mode, pos = "dd", b + 1
            elseif kind == "br" then
              add(row, a, b, "RmdMath", MP)
              mode, pos = "br", b + 1
            else -- math environment
              prose(row, line, a, b, st)
              mode, pos = "env:" .. name, b + 1
            end
          end
        end
      end
    end
  end
  return segs
end

---------------------------------------------------------------------------
-- Decoration provider
---------------------------------------------------------------------------

local ns = vim.api.nvim_create_namespace("rmd_latex_hl")
local cache = {} -- buf -> { tick, segs }

local function get_segs(buf)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local c = cache[buf]
  if not c or c.tick ~= tick then
    c = { tick = tick, segs = scan(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) }
    cache[buf] = c
  end
  return c.segs
end

function M.setup()
  define_hl()
  vim.api.nvim_create_autocmd("ColorScheme", { callback = define_hl })
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
