-- Code chunks of R Markdown / Quarto / markdown / notebook buffers, and what
-- kind of code a buffer (or the cursor) holds. Shared by the kernel modules.

local M = {}

-- Functions that mark an R chunk as "data import" for <localleader>mI.
local IMPORT_FUNCS = {
  "read.csv",
  "read.csv2",
  "read.table",
  "read.delim",
  "read.delim2",
  "read.xlsx",
  "read_csv",
  "read_csv2",
  "read_tsv",
  "read_delim",
  "read_table",
  "read_fwf",
  "read_excel",
  "read_xlsx",
  "read_xls",
  "read_dta",
  "read_sav",
  "read_sas",
  "read_spss",
  "read_stata",
  "read_rds",
  "readRDS",
  "read_parquet",
  "read_feather",
  "read_json",
  "fromJSON",
  "readLines",
  "scan",
  "fread",
  "vroom",
  "import",
  "load",
  "data",
}
-- Functions that mark an R chunk as "setup" (packages, paths, sourced scripts).
local SETUP_FUNCS = { "library", "require", "requireNamespace", "setwd", "source" }

-- The same for python chunks (pd.read_csv, np.load, ...). Chunks with
-- import statements count as setup too (PY_SETUP_LINES).
local PY_IMPORT_FUNCS = {
  "read_csv",
  "read_table",
  "read_excel",
  "read_parquet",
  "read_feather",
  "read_json",
  "read_pickle",
  "read_sql",
  "read_stata",
  "read_spss",
  "read_sas",
  "load",
  "loadtxt",
  "genfromtxt",
  "load_dataset",
  "open",
}
local PY_SETUP_FUNCS = { "os.chdir", "sys.path.append", "sys.path.insert", "load_dotenv" }
local PY_SETUP_LINES = { "^%s*import%s", "^%s*from%s+%S+%s+import%s" }

-- Per chunk language: what counts as an import / setup chunk. `frontier` is
-- what may NOT precede a function name: R allows pkg::fn but treats dots as
-- part of names (read.csv), python allows obj.fn (pd.read_csv).
M.LANGS = {
  r = { import_funcs = IMPORT_FUNCS, setup_funcs = SETUP_FUNCS, frontier = "%f[%w_.]" },
  python = {
    import_funcs = PY_IMPORT_FUNCS,
    setup_funcs = PY_SETUP_FUNCS,
    setup_lines = PY_SETUP_LINES,
    frontier = "%f[%w_]",
  },
}

M.NOTEBOOK_FT = { rmd = true, quarto = true, markdown = true }

function M.is_notebook(buf)
  return M.NOTEBOOK_FT[vim.bo[buf or 0].filetype] == true
end

-- All chunks in the buffer as { s = start_fence, e = end_fence, header, lang }
-- (1-based lines). Both ```{r ...} (R Markdown) and ```python (markdown /
-- notebooks) fences count; `lang` is lowercased ("r", "python").
function M.find(buf)
  local lines = vim.api.nvim_buf_get_lines(buf or 0, 0, -1, false)
  local chunks, s, header = {}, nil, nil
  for i, l in ipairs(lines) do
    if not s then
      if l:match("^```+%s*{") or l:match("^```+%s*%a") then
        s, header = i, l
      end
    elseif l:match("^```+%s*$") then
      local lang = (header:match("^```+%s*{?%s*([%w_]+)") or ""):lower()
      table.insert(chunks, { s = s, e = i, header = header, lang = lang })
      s = nil
    end
  end
  return chunks
end

-- The chunk containing `line` (default: the cursor), and its index.
function M.at(line, buf)
  line = line or vim.fn.line(".")
  for i, c in ipairs(M.find(buf)) do
    if line >= c.s and line <= c.e then
      return c, i
    end
  end
end

-- Language of the code at `line`: "r" / "python" in an R / Python script,
-- the chunk's language in a notebook, nil outside chunks / in other buffers.
function M.lang_at(line, buf)
  buf = buf or 0
  local ft = vim.bo[buf].filetype
  if ft == "r" or ft == "python" then
    return ft
  elseif M.NOTEBOOK_FT[ft] then
    local c = M.at(line, buf)
    if c and c.lang ~= "" and line ~= c.s and line ~= c.e then
      return c.lang
    end
  end
end

-- Chunk body lines (between the fences).
function M.body(c, buf)
  return vim.api.nvim_buf_get_lines(buf or 0, c.s, c.e - 1, false)
end

-- Chunk body with comments stripped (so commented-out read.csv() is ignored).
local function code_without_comments(c)
  local lines = M.body(c)
  for i, l in ipairs(lines) do
    lines[i] = (l:gsub("#.*$", ""))
  end
  return table.concat(lines, "\n")
end

-- Does the code call any of `names` as a function? `frontier` decides what
-- may come right before the name (see LANGS).
local function calls_any(code, names, frontier)
  for _, name in ipairs(names) do
    local esc = (name:gsub("%.", "%%."))
    if code:find(frontier .. esc .. "%s*%(") then
      return true
    end
  end
  return false
end

function M.is_import(c)
  local lang = M.LANGS[c.lang]
  if not lang then
    return false
  end
  local code = code_without_comments(c)
  for _, pat in ipairs(lang.setup_lines or {}) do
    for line in (code .. "\n"):gmatch("(.-)\n") do
      if line:find(pat) then
        return true
      end
    end
  end
  return calls_any(code, lang.import_funcs, lang.frontier) or calls_any(code, lang.setup_funcs, lang.frontier)
end

-- eval=FALSE in an R Markdown header, or `#| eval: false` (Quarto) on the
-- chunk's first line.
function M.is_skipped(c)
  if c.header:match("eval%s*=%s*F") then
    return true
  end
  local first = vim.api.nvim_buf_get_lines(0, c.s, c.s + 1, false)[1] or ""
  return first:match("^#|%s*eval:%s*false") ~= nil
end

return M
