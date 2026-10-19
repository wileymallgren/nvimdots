-- Inline chunk output for R Markdown, Quarto, markdown and Jupyter notebooks
-- (opened as markdown by lua/plugins/jupytext.lua) via molten-nvim.
-- R chunks run in IRkernel, python chunks in the project's venv kernel (see
-- lua/config/python-env.lua). <localleader>mi starts one kernel per language
-- found in the buffer's chunks; every other command sends each chunk to the
-- kernel for its language.
-- R.nvim stays in charge of the R console; molten only renders output inline.
-- NOTE: molten runs its OWN R session, separate from the R.nvim console.
--
-- In a .ipynb, <localleader>mi also loads the outputs saved in the notebook,
-- and each save writes the current outputs back into it (adds ~0.5 s to :w).
--
-- Prereqs (one-time):
--   Python: python >= 3.10 venv at ~/.venvs/nvim with pynvim + jupyter_client
--           (molten uses `match` statements; macOS system python 3.9 fails)
--   R:      install.packages("IRkernel"); IRkernel::installspec()
--   Python chunks: a .venv in the project (or an active $VIRTUAL_ENV) with
--           ipykernel installed; it is registered as a kernel on first use
--   Shell:  brew install imagemagick            (only for inline plots)

-- Extra pause (ms) after each chunk in "clear all". Raise it (e.g. 50) if
-- some outputs are left behind; lower it to 0 for maximum speed.
local SETTLE_MS = 10

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

-- Use the dedicated venv as Neovim's Python host, if it exists.
local venv_python = vim.fn.expand("~/.venvs/nvim/bin/python3")
if vim.fn.executable(venv_python) == 1 then
  vim.g.python3_host_prog = venv_python
end

-- IRkernel::installspec() writes R's versioned Cellar path into kernel.json,
-- which breaks on every `brew upgrade r`. Before starting the kernel, point
-- it at the R on PATH (/opt/homebrew/bin/R, a symlink that survives upgrades).
local IR_KERNELSPECS = {
  "~/Library/Jupyter/kernels/ir/kernel.json", -- macOS
  "~/.local/share/jupyter/kernels/ir/kernel.json", -- Linux
}

local function fix_ir_kernelspec()
  local r = vim.fn.exepath("R")
  if r == "" then
    vim.notify("Molten: no R binary on PATH", vim.log.levels.ERROR)
    return
  end
  for _, p in ipairs(IR_KERNELSPECS) do
    local path = vim.fn.expand(p)
    if vim.fn.filereadable(path) == 1 then
      local ok, spec = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
      if ok and type(spec) == "table" and type(spec.argv) == "table" and spec.argv[1] ~= r then
        spec.argv[1] = r
        vim.fn.writefile({ vim.json.encode(spec) }, path)
      end
    end
  end
end

-- Per chunk language: how to pick its kernel, and what counts as an
-- import / setup chunk. `frontier` is what may NOT precede a function name:
-- R allows pkg::fn but treats dots as part of names (read.csv), python
-- allows obj.fn (pd.read_csv).
local LANGS = {
  r = {
    kernel = function()
      fix_ir_kernelspec()
      return "ir"
    end,
    import_funcs = IMPORT_FUNCS,
    setup_funcs = SETUP_FUNCS,
    frontier = "%f[%w_.]",
  },
  python = {
    kernel = function(buf)
      return require("config.python-env").kernel(buf)
    end,
    import_funcs = PY_IMPORT_FUNCS,
    setup_funcs = PY_SETUP_FUNCS,
    setup_lines = PY_SETUP_LINES,
    frontier = "%f[%w_]",
  },
}

local function elapsed_ms(t0)
  return math.floor((vim.uv.hrtime() - t0) / 1e6)
end

-- Return all chunks in the buffer as { s = start_fence, e = end_fence,
-- header, lang } tables. Both ```{r ...} (R Markdown) and ```python
-- (markdown / notebooks) fences count; `lang` is lowercased ("r", "python").
local function find_chunks()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
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

-- Kernels attached to the current buffer, as { [lang] = kernel_id }. The
-- language comes from the kernelspec, so kernels started by hand with
-- :MoltenInit count too. molten names a second instance of a kernel
-- "<name>_<n>", hence the suffix fallback.
local function buffer_kernels()
  local ok, ids = pcall(vim.fn.MoltenRunningKernels, true)
  local by_lang = {}
  if not ok or type(ids) ~= "table" then
    return by_lang
  end
  local pyenv = require("config.python-env")
  local specs = pyenv.kernelspecs()
  for _, id in ipairs(ids) do
    local base = id:gsub("_%d+$", "")
    if not (specs[id] or specs[base]) then
      specs = pyenv.kernelspecs(true) -- registered since the last lookup
    end
    local lang = specs[id] or specs[base]
    if lang and not by_lang[lang] then
      by_lang[lang] = id
    end
  end
  return by_lang, #ids
end

-- Like buffer_kernels(), but warns and returns nil when none is running.
local function kernels_or_warn()
  local by_lang, n = buffer_kernels()
  if (n or 0) == 0 then
    vim.notify("No molten kernel running: use <localleader>mi first", vim.log.levels.WARN)
    return nil
  end
  return by_lang
end

-- Chunk body with comments stripped (so commented-out read.csv() is ignored).
local function chunk_code(c)
  local lines = vim.api.nvim_buf_get_lines(0, c.s, c.e - 1, false)
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

local function is_import_chunk(c)
  local lang = LANGS[c.lang]
  if not lang then
    return false
  end
  local code = chunk_code(c)
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
local function is_skipped(c)
  if c.header:match("eval%s*=%s*F") then
    return true
  end
  local first = vim.api.nvim_buf_get_lines(0, c.s, c.s + 1, false)[1] or ""
  return first:match("^#|%s*eval:%s*false") ~= nil
end

-- Send the body of one chunk (between the fences) to molten kernel `kernel`.
local function eval_chunk(c, kernel)
  if c.e - c.s < 2 then
    return
  end -- empty chunk
  vim.cmd(("normal! %dGV%dG\27"):format(c.s + 1, c.e - 1))
  vim.cmd("MoltenEvaluateVisual " .. kernel)
end

local function run_chunk()
  local cur = vim.fn.line(".")
  for _, c in ipairs(find_chunks()) do
    if cur >= c.s and cur <= c.e then
      local kernels = kernels_or_warn()
      if not kernels then
        return
      end
      local kernel = kernels[c.lang]
      if not kernel then
        vim.notify(
          ("No %s kernel running: use <localleader>mi first"):format(c.lang ~= "" and c.lang or "matching"),
          vim.log.levels.WARN
        )
        return
      end
      local view = vim.fn.winsaveview()
      eval_chunk(c, kernel)
      vim.fn.winrestview(view)
      return
    end
  end
  vim.notify("Not inside a code chunk", vim.log.levels.WARN)
end

-- Run chunks in order, each in the kernel for its language. `upto`
-- (optional) limits to chunks starting before that line; `filter`
-- (optional) is a predicate chunk -> bool. Skips chunks whose language has
-- no running kernel and chunks marked eval=FALSE.
local function run_chunks(upto, filter)
  local kernels = kernels_or_warn()
  if not kernels then
    return
  end
  local t0 = vim.uv.hrtime()
  local view = vim.fn.winsaveview()
  local n = 0
  for _, c in ipairs(find_chunks()) do
    if upto and c.s >= upto then
      break
    end
    local kernel = kernels[c.lang]
    if kernel and not is_skipped(c) and (not filter or filter(c)) then
      eval_chunk(c, kernel)
      n = n + 1
    end
  end
  vim.fn.winrestview(view)
  vim.notify(("Molten: sent %d chunk(s) in %d ms"):format(n, elapsed_ms(t0)))
end

-- Synchronous round trip into molten's python host. It returns once the host
-- has handled everything queued before it (e.g. the CursorMoved event).
local function host_barrier()
  pcall(vim.fn.MoltenRunningKernels, true)
end

-- Delete the stored output of every chunk (re-run to get it back).
-- MoltenDelete acts on the cell molten last saw under the cursor, which it
-- tracks via CursorMoved autocmds. A programmatic cursor jump doesn't trigger
-- those before the next command runs, so fire CursorMoved by hand first.
local function clear_all()
  local t0 = vim.uv.hrtime()
  local view = vim.fn.winsaveview()
  local n = 0
  for _, c in ipairs(find_chunks()) do
    if c.e - c.s >= 2 then
      local mid = math.floor((c.s + c.e) / 2) -- a body line, inside the chunk
      vim.fn.cursor(mid, 1)
      vim.cmd("normal! $")
      vim.api.nvim_exec_autocmds("CursorMoved", {})
      host_barrier()
      if pcall(vim.cmd, "MoltenDelete") then
        n = n + 1
      end
      if SETTLE_MS > 0 then
        vim.wait(SETTLE_MS)
      end
    end
  end
  vim.fn.winrestview(view)
  vim.api.nvim_exec_autocmds("CursorMoved", {})
  vim.notify(("Molten: cleared %d chunk(s) in %d ms"):format(n, elapsed_ms(t0)))
end

local function is_notebook(buf)
  return vim.api.nvim_buf_get_name(buf):match("%.ipynb$") ~= nil
end

-- Start a kernel for every chunk language in the buffer that doesn't have
-- one yet (R only for a plain R Markdown file, as before). In a notebook,
-- then load the outputs saved in it.
local function init_kernels()
  local buf = vim.api.nvim_get_current_buf()
  local langs, seen = {}, {}
  for _, c in ipairs(find_chunks()) do
    if LANGS[c.lang] and not seen[c.lang] then
      seen[c.lang] = true
      table.insert(langs, c.lang)
    end
  end
  if #langs == 0 then
    langs = { is_notebook(buf) and "python" or "r" }
  end

  local running = buffer_kernels()
  for _, lang in ipairs(langs) do
    if not running[lang] then
      local name = LANGS[lang].kernel(buf)
      vim.cmd(name and ("MoltenInit " .. name) or "MoltenInit") -- no name: molten asks
    end
  end

  local py = buffer_kernels().python
  if is_notebook(buf) and py then
    pcall(vim.cmd, ("MoltenImportOutput %s %s"):format(vim.fn.fnameescape(vim.api.nvim_buf_get_name(buf)), py))
  end
end

return {
  {
    "benlubas/molten-nvim",
    version = "^1.0.0",
    build = ":UpdateRemotePlugins",
    dependencies = { "3rd/image.nvim" },
    init = function()
      vim.g.molten_image_provider = "image.nvim"
      vim.g.molten_virt_text_output = true -- output inline under the chunk
      vim.g.molten_auto_open_output = false
      vim.g.molten_wrap_output = true
      vim.g.molten_virt_lines_off_by_1 = true -- place output below the last line
      vim.g.molten_output_win_max_height = 20
    end,
    config = function()
      local group = vim.api.nvim_create_augroup("MoltenChunks", { clear = true })

      -- jupytext keeps the outputs already in the .ipynb when saving; write
      -- the current ones over them.
      vim.api.nvim_create_autocmd("BufWritePost", {
        group = group,
        pattern = "*.ipynb",
        callback = function(ev)
          local py = buffer_kernels().python
          if py then
            pcall(vim.cmd, ("MoltenExportOutput! %s %s"):format(vim.fn.fnameescape(ev.file), py))
          end
        end,
      })

      vim.api.nvim_create_autocmd("FileType", {
        group = group,
        pattern = { "rmd", "quarto", "markdown" },
        callback = function(ev)
          local function map(lhs, rhs, desc)
            vim.keymap.set("n", lhs, rhs, { buffer = ev.buf, silent = true, desc = desc })
          end
          map("<localleader>mi", init_kernels, "Molten: start kernel(s) for this buffer's chunks")
          map("<localleader>mc", run_chunk, "Molten: run current chunk")
          map("<localleader>ma", function()
            run_chunks()
          end, "Molten: run all chunks")
          map("<localleader>mb", function()
            run_chunks(vim.fn.line("."))
          end, "Molten: run all chunks above cursor")
          map("<localleader>mI", function()
            run_chunks(nil, is_import_chunk)
          end, "Molten: run library/data-import chunks only")
          map("<localleader>mo", "<cmd>noautocmd MoltenEnterOutput<CR>", "Molten: open output window")
          map("<localleader>mh", "<cmd>MoltenHideOutput<CR>", "Molten: hide output")
          map("<localleader>md", "<cmd>MoltenDelete<CR>", "Molten: delete cell output")
          map("<localleader>mD", clear_all, "Molten: clear all outputs")
          map("<localleader>mx", "<cmd>MoltenDeinit<CR>", "Molten: stop kernel")
          vim.keymap.set(
            "v",
            "<localleader>mr",
            ":<C-u>MoltenEvaluateVisual<CR>gv",
            { buffer = ev.buf, silent = true, desc = "Molten: run selection" }
          )
        end,
      })
    end,
  },

  -- Inline image rendering (plots). Needs a terminal with the kitty graphics
  -- protocol (kitty, WezTerm, Ghostty). Text output works without it.
  {
    "3rd/image.nvim",
    opts = {
      backend = "kitty",
      processor = "magick_cli", -- uses the `magick` binary, no luarocks needed
      integrations = {}, -- molten handles placement itself
      max_width = 100,
      max_height = 12,
      max_width_window_percentage = math.huge,
      max_height_window_percentage = math.huge,
      window_overlap_clear_enabled = true,
      -- Floating windows of these filetypes won't hide images they overlap.
      window_overlap_clear_ft_ignore = {
        "cmp_menu",
        "cmp_docs",
        "",
        "blink-cmp-menu",
        "blink-cmp-documentation",
        "blink-cmp-signature",
        "blink-cmp-ghost-text",
        "wk",
        "which_key",
      },
    },
  },
}
