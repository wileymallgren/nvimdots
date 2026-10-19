-- Knit Rmd/Quarto-style R Markdown files in a background Rscript job so the
-- editor layout is untouched. Only success/failure is reported.
--   <localleader>kk  knit (first output format in the YAML header)
--   <localleader>ko  open the knitted file (pdf, falling back to html / docx)
--
-- In a Jupyter notebook (.ipynb, see lua/plugins/jupytext.lua) <localleader>kk
-- runs every cell in a fresh kernel and exports HTML with nbconvert, the
-- notebook equivalent of knitting. Needs nbconvert in ~/.venvs/nvim.
--
-- Output opens in Skim on macOS if it is installed (it auto-reloads on
-- re-knit), otherwise in the system default viewer.

local M = {}

local function output_path(src)
  local base = vim.fn.fnamemodify(src, ":r")
  for _, ext in ipairs({ "pdf", "html", "docx" }) do
    if vim.uv.fs_stat(base .. "." .. ext) then
      return base .. "." .. ext
    end
  end
end

local function open_output(path)
  if vim.fn.has("mac") == 1 and vim.uv.fs_stat("/Applications/Skim.app") then
    vim.system({ "open", "-a", "Skim", path })
  else
    vim.ui.open(path)
  end
end

local NBCONVERT_PYTHON = vim.fn.expand("~/.venvs/nvim/bin/python3")

-- Command that knits `name` (a file in the current buffer's directory).
local function knit_cmd(buf, name)
  if name:match("%.ipynb$") then
    local cmd = { NBCONVERT_PYTHON, "-m", "nbconvert", "--to", "html", "--execute" }
    local kernel = require("config.python-env").kernel(buf)
    if kernel then
      table.insert(cmd, "--ExecutePreprocessor.kernel_name=" .. kernel)
    end
    table.insert(cmd, name)
    return cmd
  end
  return {
    "Rscript",
    "-e",
    ("rmarkdown::render(%s, quiet = TRUE, envir = new.env())"):format(vim.fn.json_encode(name)),
  }
end

local function knit(buf)
  local is_notebook = vim.api.nvim_buf_get_name(buf):match("%.ipynb$") ~= nil
  if is_notebook and vim.fn.executable(NBCONVERT_PYTHON) ~= 1 then
    vim.notify("No python at " .. NBCONVERT_PYTHON .. " (needs nbconvert)", vim.log.levels.ERROR)
    return
  elseif not is_notebook and vim.fn.executable("Rscript") ~= 1 then
    vim.notify("Rscript not found in PATH", vim.log.levels.ERROR)
    return
  end
  vim.cmd("silent! write")
  local src = vim.api.nvim_buf_get_name(buf)
  local name = vim.fn.fnamemodify(src, ":t")
  local dir = vim.fn.fnamemodify(src, ":h")
  local t0 = vim.uv.hrtime()
  vim.notify("Knitting " .. name .. "...")

  vim.system(knit_cmd(buf, name), { cwd = dir, text = true }, function(res)
    vim.schedule(function()
      if res.code == 0 then
        local secs = (vim.uv.hrtime() - t0) / 1e9
        local out = output_path(src)
        vim.notify(("Knitted %s (%.1fs)"):format(out and vim.fn.fnamemodify(out, ":t") or name, secs))
      else
        local lines = vim.split((res.stderr or "") .. (res.stdout or ""), "\n", { trimempty = true })
        vim.fn.setqflist({}, " ", { title = "Knit failed: " .. name, lines = lines })
        vim.cmd("copen")
        vim.notify("Knit failed - see quickfix list", vim.log.levels.ERROR)
      end
    end)
  end)
end

function M.setup()
  vim.api.nvim_create_autocmd("FileType", {
    group = vim.api.nvim_create_augroup("RmdKnit", { clear = true }),
    pattern = { "rmd", "quarto", "markdown" },
    callback = function(ev)
      vim.keymap.set("n", "<localleader>kk", function()
        knit(ev.buf)
      end, { buffer = ev.buf, desc = "Knit in background" })
      vim.keymap.set("n", "<localleader>ko", function()
        local out = output_path(vim.api.nvim_buf_get_name(ev.buf))
        if out then
          open_output(out)
        else
          vim.notify("No knitted output found - knit first", vim.log.levels.WARN)
        end
      end, { buffer = ev.buf, desc = "Open knitted output" })
    end,
  })
end

return M
