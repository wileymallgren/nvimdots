-- R and Python through Jupyter kernels, RStudio style: one R session shared
-- by scripts and notebooks, chunk output inline under the chunks, and a
-- console along the bottom that shows everything that runs.
-- Pieces: bridge.py / client.lua (the kernels), session.lua (which kernel,
-- running code), console.lua, send.lua, chunks.lua.
--
-- In R / Python scripts and in R / Python code chunks (<localleader> = \):
--   \l  \d        send the statement on the cursor line (\d: and move down)
--   \ss \sd       (visual) send the selection (\sd: and move down)
--   \pp \pd       send the paragraph (\pd: and move down)
--   \fc           send the top-level statement (e.g. function) around the cursor
--   \aa           send the whole file (scripts)
--   \rf           start the kernel (if running: show the console)   \rq  stop it
--   \rk           restart the kernel                \rH  hide / show the console
--   \rr           clear the console
--   \rp \rs \rt \rn \rg \ra   print / summary / str / names / plot / args
--                 of the object under the cursor (objects.lua)
--   \rh help   \rv view data frame   \ro objects   \rl ls()   \rm rm all
--   \rd cwd -> file's dir   insert: <M--> " <- ", \, " |>", <M-r> R chunk
-- In notebooks (R Markdown, Quarto, markdown, .ipynb via jupytext), with the
-- output shown under the chunk (inline.lua):
--   \mc \cc       run the chunk          \mn \cd <S-CR>  run it, go to the next
--   \ma \aa       run all chunks         \mb \ch         run the chunks above
--   \mu           run the chunks above, then this one (only this one's output
--                 shows under its chunk; the others show in the console)
--   \mR           restart the kernel(s), then run the chunks above
--   \mI           run library / data-import chunks
--   \mr           (visual) run the selection, output under its chunk
--   \md \mD       delete this / all outputs    \mh  hide / show this output
--   \mo           this output in a float       \mi  start the buffer's kernels
--   \mx           stop the kernel              \gn \gN  next / previous chunk
-- Line, selection and paragraph sends (\l, \ss, \pp ...) only show their
-- output in the console. Kernel commands act on the kernel of the code under
-- the cursor (R by default). Needs ~/.venvs/nvim with jupyter_client, and
-- IRkernel for R.

local M = {}

local CODE_FT = { r = true, python = true, rmd = true, quarto = true, markdown = true }

-- The kernel language for commands like \rq: the code under the cursor's,
-- else R.
local function cursor_lang()
  return require("config.kernel.chunks").lang_at(vim.fn.line(".")) or "r"
end

local function with_kernel(fn)
  return function()
    local session = require("config.kernel.session")
    local lang = cursor_lang()
    local k = session.find(lang, 0)
    if not k then
      vim.notify(("No %s kernel running"):format(lang == "r" and "R" or lang), vim.log.levels.WARN)
      return
    end
    fn(k, session)
  end
end

function M.attach(buf)
  local send = require("config.kernel.send")
  local console = require("config.kernel.console")
  local function map(mode, lhs, rhs, desc)
    vim.keymap.set(mode, "<localleader>" .. lhs, rhs, { buffer = buf, silent = true, desc = desc })
  end
  map("n", "l", function()
    send.line(false)
  end, "Send line/statement")
  map("n", "d", function()
    send.line(true)
  end, "Send line/statement and move down")
  map("x", "ss", function()
    send.selection(false)
  end, "Send selection")
  map("x", "sd", function()
    send.selection(true)
  end, "Send selection and move down")
  map("n", "pp", function()
    send.paragraph(false)
  end, "Send paragraph")
  map("n", "pd", function()
    send.paragraph(true)
  end, "Send paragraph and move down")
  map("n", "fc", send.fun, "Send top-level statement (function)")
  local ft = vim.bo[buf].filetype
  if ft == "r" or ft == "python" then
    map("n", "aa", send.file, "Send file")
  end
  -- Like R.nvim's \rf: starts the kernel (R, or Python in a Python
  -- script / chunk); when it already runs, shows its console
  map("n", "rf", function()
    local session = require("config.kernel.session")
    local lang = cursor_lang()
    local running = session.find(lang, 0)
    local k = session.ensure(lang, 0)
    if running and k then
      console.open(k)
    end
  end, "Start kernel (if running: show console)")
  map(
    "n",
    "rq",
    with_kernel(function(k, session)
      session.shutdown(k)
    end),
    "Stop kernel"
  )
  map(
    "n",
    "rk",
    with_kernel(function(k, session)
      session.restart(k)
    end),
    "Restart kernel"
  )
  map("n", "rH", with_kernel(console.toggle), "Hide/show console")
  map("n", "rr", with_kernel(console.clear), "Clear console")

  local objects = require("config.kernel.objects")
  for lhs, what in pairs({ rp = "print", rs = "summary", rt = "str", rn = "names", rg = "plot", ra = "args" }) do
    map({ "n", "x" }, lhs, function()
      objects.action(what)
    end, "Object: " .. what)
  end
  map({ "n", "x" }, "rh", objects.help, "Help on the object")
  map({ "n", "x" }, "rv", function()
    objects.view()
  end, "View data frame")
  map("n", "ro", objects.list_objects, "Objects in the session")
  map("n", "rl", function()
    objects.console("ls()", '[k for k in globals() if not k.startswith("_")]')
  end, "List objects")
  map("n", "rm", function()
    objects.console("rm(list = ls())", "%reset -f")
  end, "Remove all objects")
  map("n", "rd", objects.setwd, "Working directory: this file's")
  if ft ~= "python" then
    vim.keymap.set("i", "<M-->", objects.insert_assign, { buffer = buf, expr = true, desc = "Insert <-" })
    vim.keymap.set("i", "<localleader>,", objects.insert_pipe, { buffer = buf, expr = true, desc = "Insert |>" })
  end

  if not require("config.kernel.chunks").is_notebook(buf) then
    return
  end
  local inline = require("config.kernel.inline")
  local chunks = require("config.kernel.chunks")
  local function run_cursor()
    inline.run_cursor(false)
  end
  local function run_next()
    inline.run_cursor(true)
  end
  local function run_all()
    inline.run_all()
  end
  local function run_above()
    inline.run_all(vim.fn.line("."))
  end
  for _, lhs in ipairs({ "mc", "cc" }) do
    map("n", lhs, run_cursor, "Run chunk")
  end
  for _, lhs in ipairs({ "mn", "cd" }) do
    map("n", lhs, run_next, "Run chunk, go to next")
  end
  -- Jupyter's Shift-Enter (needs a terminal that sends <S-CR> distinctly:
  -- kitty, WezTerm, Ghostty)
  vim.keymap.set("n", "<S-CR>", run_next, { buffer = buf, desc = "Run chunk, go to next" })
  for _, lhs in ipairs({ "ma", "aa" }) do
    map("n", lhs, run_all, "Run all chunks")
  end
  for _, lhs in ipairs({ "mb", "ch" }) do
    map("n", lhs, run_above, "Run chunks above the cursor")
  end
  map("n", "mu", inline.run_upto_cursor, "Run chunks above + this one (output only here)")
  map("n", "mR", inline.restart_and_run_above, "Restart kernel(s), run the chunks above")
  map("n", "mI", function()
    inline.run_all(nil, chunks.is_import)
  end, "Run library/data-import chunks")
  map("x", "mr", inline.run_selection, "Run selection (output under the chunk)")
  map("n", "md", inline.delete, "Delete chunk output")
  map("n", "mD", inline.clear_all, "Clear all outputs")
  map("n", "mh", inline.toggle_hidden, "Hide/show chunk output")
  map("n", "mo", inline.open_float, "Chunk output in a float")
  map("n", "mi", function()
    local session = require("config.kernel.session")
    local seen = {}
    for _, c in ipairs(chunks.find(buf)) do
      if chunks.LANGS[c.lang] and not seen[c.lang] then
        seen[c.lang] = true
        session.ensure(c.lang, buf)
      end
    end
  end, "Start the kernels this buffer's chunks need")
  map(
    "n",
    "mx",
    with_kernel(function(k, session)
      session.shutdown(k)
    end),
    "Stop kernel"
  )
  local function goto_chunk(dir)
    local cur = vim.fn.line(".")
    local list = chunks.find(buf)
    for i = dir > 0 and 1 or #list, dir > 0 and #list or 1, dir do
      local c = list[i]
      if (dir > 0 and c.s > cur) or (dir < 0 and c.e < cur) then
        vim.api.nvim_win_set_cursor(0, { math.min(c.s + 1, c.e), 0 })
        return
      end
    end
  end
  map("n", "gn", function()
    goto_chunk(1)
  end, "Next chunk")
  map("n", "gN", function()
    goto_chunk(-1)
  end, "Previous chunk")
  if vim.bo[buf].filetype ~= "markdown" then
    vim.keymap.set("i", "<M-r>", objects.insert_chunk, { buffer = buf, desc = "Insert R chunk" })
  end
end

function M.setup()
  -- The statusline shows kernel state (lua/plugins/lualine.lua)
  require("config.kernel.session").observe({
    change = function()
      pcall(function()
        require("lualine").refresh({ place = { "statusline" } })
      end)
    end,
  })
  require("config.kernel.ipynb").setup()
  vim.api.nvim_create_autocmd("FileType", {
    group = vim.api.nvim_create_augroup("KernelKeys", { clear = true }),
    pattern = vim.tbl_keys(CODE_FT),
    callback = function(ev)
      M.attach(ev.buf)
    end,
  })
end

return M
