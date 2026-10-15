-- Inline chunk output for R Markdown via molten-nvim (Jupyter kernel: IRkernel).
-- R.nvim stays in charge of the R console; molten only renders output inline.
-- NOTE: molten runs its OWN R session, separate from the R.nvim console.
--
-- Prereqs (one-time):
--   Python: python >= 3.10 venv at ~/.venvs/nvim with pynvim + jupyter_client
--           (molten uses `match` statements; macOS system python 3.9 fails)
--   R:      install.packages("IRkernel"); IRkernel::installspec()
--   Shell:  brew install imagemagick            (only for inline plots)

-- Extra pause (ms) after each chunk in "clear all". Raise it (e.g. 50) if
-- some outputs are left behind; lower it to 0 for maximum speed.
local SETTLE_MS = 10

-- Functions that mark a chunk as "data import" for <localleader>mI.
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
-- Functions that mark a chunk as "setup" (packages, paths, sourced scripts).
local SETUP_FUNCS = { "library", "require", "requireNamespace", "setwd", "source" }

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

local function elapsed_ms(t0)
  return math.floor((vim.uv.hrtime() - t0) / 1e6)
end

-- Return all chunks in the buffer as { start_fence, end_fence, header } tables.
local function find_chunks()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local chunks, s, header = {}, nil, nil
  for i, l in ipairs(lines) do
    if not s then
      if l:match("^```+%s*{") then
        s, header = i, l
      end
    elseif l:match("^```+%s*$") then
      table.insert(chunks, { s = s, e = i, header = header })
      s = nil
    end
  end
  return chunks
end

local function kernel_running()
  local ok, kernels = pcall(vim.fn.MoltenRunningKernels, true)
  if ok and type(kernels) == "table" and #kernels == 0 then
    vim.notify("No molten kernel running: use <localleader>mi first", vim.log.levels.WARN)
    return false
  end
  return true
end

-- Chunk body with comments stripped (so commented-out read.csv() is ignored).
local function chunk_code(c)
  local lines = vim.api.nvim_buf_get_lines(0, c.s, c.e - 1, false)
  for i, l in ipairs(lines) do
    lines[i] = (l:gsub("#.*$", ""))
  end
  return table.concat(lines, "\n")
end

-- Does the code call any of `names` as a function (pkg::fn also counts)?
local function calls_any(code, names)
  for _, name in ipairs(names) do
    local esc = (name:gsub("%.", "%%."))
    if code:find("%f[%w_.]" .. esc .. "%s*%(") then
      return true
    end
  end
  return false
end

local function is_import_chunk(c)
  local code = chunk_code(c)
  return calls_any(code, IMPORT_FUNCS) or calls_any(code, SETUP_FUNCS)
end

-- Send the body of one chunk (between the fences) to molten.
local function eval_chunk(c)
  if c.e - c.s < 2 then
    return
  end -- empty chunk
  vim.cmd(("normal! %dGV%dG\27"):format(c.s + 1, c.e - 1))
  vim.cmd("MoltenEvaluateVisual")
end

local function run_chunk()
  local cur = vim.fn.line(".")
  for _, c in ipairs(find_chunks()) do
    if cur >= c.s and cur <= c.e then
      if not kernel_running() then
        return
      end
      local view = vim.fn.winsaveview()
      eval_chunk(c)
      vim.fn.winrestview(view)
      return
    end
  end
  vim.notify("Not inside a code chunk", vim.log.levels.WARN)
end

-- Run R chunks in order. `upto` (optional) limits to chunks starting before
-- that line; `filter` (optional) is a predicate chunk -> bool. Skips non-R
-- chunks and chunks marked eval=FALSE.
local function run_chunks(upto, filter)
  if not kernel_running() then
    return
  end
  local t0 = vim.uv.hrtime()
  local view = vim.fn.winsaveview()
  local n = 0
  for _, c in ipairs(find_chunks()) do
    if upto and c.s >= upto then
      break
    end
    local is_r = c.header:match("^```+%s*{%s*[rR]%f[^%w]") ~= nil
    local skip = c.header:match("eval%s*=%s*F") ~= nil
    if is_r and not skip and (not filter or filter(c)) then
      eval_chunk(c)
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
      vim.api.nvim_create_autocmd("FileType", {
        pattern = { "rmd", "quarto", "markdown" },
        callback = function(ev)
          local function map(lhs, rhs, desc)
            vim.keymap.set("n", lhs, rhs, { buffer = ev.buf, silent = true, desc = desc })
          end
          map("<localleader>mi", function()
            fix_ir_kernelspec()
            vim.cmd("MoltenInit ir")
          end, "Molten: start R kernel")
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
