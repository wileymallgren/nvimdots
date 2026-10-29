-- Native console for the kernels: one prompt buffer per kernel (R, Python),
-- shown in a split along the bottom. It echoes everything that runs in the
-- kernel (sent lines, chunks, what you type) followed by its output. It
-- starts hidden (SHOW_ON_START); the statusline then says "(hidden)".
--   <localleader>rH  hide / show it (from code buffers)
-- In the console:
--   i / a        type at the "> " prompt; <CR> runs it (an incomplete
--                expression continues on a "+ " line, as in R)
--   <Up>/<Down>  history (insert mode)
--   <Tab>        complete from the kernel (objects, df$columns, arguments)
--   <C-c>        interrupt the kernel
--   <CR>         (normal mode) on a [plot] line: view the plot

local session = require("config.kernel.session")

local M = {}

local HEIGHT = 10
local SHOW_ON_START = false -- true: open the console when its kernel starts
local MAX_LINES = 10000
local ns = vim.api.nvim_create_namespace("kernel-console")
local plot_ns = vim.api.nvim_create_namespace("kernel-console-plots")

for name, link in pairs({
  KernelConsoleInput = "Function",
  KernelConsoleStderr = "DiagnosticWarn",
  KernelConsoleError = "DiagnosticError",
  KernelConsolePlot = "Special",
  KernelConsoleNote = "Comment",
}) do
  vim.api.nvim_set_hl(0, name, { link = link, default = true })
end

local consoles = {} -- kernel id -> console

local function line_count(c)
  return vim.api.nvim_buf_line_count(c.buf)
end

-- Keep the console windows we aren't typing in scrolled to the bottom.
local function scroll(c)
  local cur = vim.api.nvim_get_current_win()
  for _, win in ipairs(vim.fn.win_findbuf(c.buf)) do
    if win ~= cur then
      vim.api.nvim_win_set_cursor(win, { line_count(c), 0 })
    end
  end
end

-- Insert `lines` above the prompt line, highlighted with `hl`; returns the
-- 0-based row of the first one.
local function append(c, lines, hl)
  if #lines == 0 then
    return
  end
  local row = line_count(c) - 1
  vim.api.nvim_buf_set_lines(c.buf, row, row, false, lines)
  if hl then
    for i = 0, #lines - 1 do
      vim.api.nvim_buf_set_extmark(c.buf, ns, row + i, 0, { end_row = row + i + 1, hl_group = hl, hl_eol = false })
    end
  end
  local excess = line_count(c) - MAX_LINES
  if excess > 0 then
    vim.api.nvim_buf_set_lines(c.buf, 0, excess, false, {})
    row = row - excess
  end
  scroll(c)
  return row
end

-- What a terminal would show for a line with carriage returns (progress
-- bars): the last text written after one (a trailing \r only moves the cursor).
local function after_cr(s)
  local segs = vim.split(s, "\r", { plain = true })
  for i = #segs, 1, -1 do
    if segs[i] ~= "" then
      return segs[i]
    end
  end
  return ""
end

-- Write stream text, continuing an unfinished last line.
local function write(c, text, hl)
  local lines = vim.split(text, "\n", { plain = true })
  local ends_nl = lines[#lines] == ""
  if ends_nl then
    table.remove(lines)
  end
  if c.partial and #lines > 0 then
    local row = line_count(c) - 2
    local prev = vim.api.nvim_buf_get_lines(c.buf, row, row + 1, false)[1] or ""
    local first = table.remove(lines, 1)
    local merged = first:find("\r") and after_cr(first) or prev .. first
    vim.api.nvim_buf_set_lines(c.buf, row, row + 1, false, { merged })
    if hl then
      vim.api.nvim_buf_set_extmark(c.buf, ns, row, 0, { end_row = row + 1, hl_group = hl })
    end
  end
  append(c, vim.tbl_map(after_cr, lines), hl)
  c.partial = not ends_nl and (#lines > 0 or c.partial)
end

local function finish_line(c)
  c.partial = false
end

local function set_prompt(c, prompt)
  if c.prompt == prompt then
    return
  end
  local last = line_count(c)
  local line = vim.api.nvim_buf_get_lines(c.buf, last - 1, last, false)[1] or ""
  local rest = vim.startswith(line, c.prompt) and line:sub(#c.prompt + 1) or line
  vim.fn.prompt_setprompt(c.buf, prompt)
  vim.api.nvim_buf_set_lines(c.buf, last - 1, last, false, { prompt .. rest })
  c.prompt = prompt
end

-- Echo code run from elsewhere as "> first line" / "+ continuation".
local function echo(c, code)
  finish_line(c)
  local lines = vim.split(code, "\n", { plain = true })
  for i, l in ipairs(lines) do
    lines[i] = (i == 1 and "> " or "+ ") .. l
  end
  append(c, lines, "KernelConsoleInput")
end

local function add_history(c, code)
  local entry = code:gsub("\n%s*", " ")
  if entry ~= "" and c.history[#c.history] ~= entry then
    table.insert(c.history, entry)
  end
  c.hist_i = nil
end

local function recall(c, dir)
  if #c.history == 0 then
    return
  end
  c.hist_i = math.max(1, math.min(#c.history + 1, (c.hist_i or #c.history + 1) + dir))
  local text = c.history[c.hist_i] or ""
  local last = line_count(c)
  vim.api.nvim_buf_set_lines(c.buf, last - 1, last, false, { c.prompt .. text })
  vim.api.nvim_win_set_cursor(0, { last, #c.prompt + #text })
end

-- Tab completion from the kernel, in Neovim's own completion menu (blink.cmp
-- doesn't run in prompt buffers).
local function complete(c)
  local line = vim.api.nvim_get_current_line()
  if not vim.startswith(line, c.prompt) then
    return
  end
  local code = line:sub(#c.prompt + 1)
  local col = vim.fn.col(".") - 1 - #c.prompt -- bytes of code before the cursor
  if col < 0 then
    return
  end
  session.complete(c.k, code, vim.str_utfindex(code, "utf-32", col), function(ev)
    if vim.api.nvim_get_current_buf() ~= c.buf or vim.fn.mode() ~= "i" or #(ev.matches or {}) == 0 then
      return
    end
    local start = vim.str_byteindex(code, "utf-32", ev.start or 0)
    vim.fn.complete(#c.prompt + start + 1, ev.matches)
  end)
end

local function on_submit(c, text)
  if c.input then -- answering readline() / input()
    local reply = c.input
    c.input = nil
    set_prompt(c, "> ")
    reply(text)
    return
  end
  table.insert(c.pending, text)
  local code = table.concat(c.pending, "\n")
  if vim.trim(code) == "" then
    c.pending = {}
    return
  end
  session.is_complete(c.k, code, function(ev)
    if ev.status == "incomplete" then
      set_prompt(c, "+ ")
      return
    end
    c.pending = {}
    set_prompt(c, "> ")
    add_history(c, code)
    session.execute(c.k, code, { source = "console" })
  end)
end

function M.view_image(path)
  local ok, image = pcall(require, "image")
  if not ok then
    vim.ui.open(path)
    return
  end
  local buf = vim.api.nvim_create_buf(false, true)
  local width, height = math.floor(vim.o.columns * 0.8), math.floor(vim.o.lines * 0.8)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    style = "minimal",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    title = " " .. vim.fs.basename(path) .. " ",
  })
  local img = image.from_file(path, { window = win, buffer = buf, x = 0, y = 0, width = width, height = height })
  if not img or not pcall(img.render, img) then
    vim.api.nvim_win_close(win, true)
    vim.ui.open(path)
    return
  end
  local function close()
    pcall(img.clear, img)
    pcall(vim.api.nvim_win_close, win, true)
  end
  vim.keymap.set("n", "q", close, { buffer = buf })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf })
  vim.api.nvim_create_autocmd("WinLeave", { buffer = buf, once = true, callback = close })
end

local function create(k)
  local c = { k = k, prompt = "> ", pending = {}, history = {}, partial = false, plots = {}, to_echo = {} }
  c.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[c.buf].buftype = "prompt"
  vim.bo[c.buf].bufhidden = "hide"
  vim.bo[c.buf].swapfile = false
  vim.bo[c.buf].filetype = "kernel_console" -- autopairs is off here (lua/plugins/autopairs.lua)
  vim.bo[c.buf].completeopt = "menuone,noselect"
  pcall(vim.api.nvim_buf_set_name, c.buf, k.label .. " console")
  vim.fn.prompt_setprompt(c.buf, c.prompt)
  vim.fn.prompt_setcallback(c.buf, function(text)
    on_submit(c, text)
  end)
  vim.fn.prompt_setinterrupt(c.buf, function()
    session.interrupt(c.k)
  end)
  local function map(mode, lhs, rhs, desc)
    vim.keymap.set(mode, lhs, rhs, { buffer = c.buf, desc = desc })
  end
  map("n", "<C-c>", function()
    session.interrupt(c.k)
  end, "Interrupt kernel")
  -- With the completion menu open these keys work it; otherwise <Up>/<Down>
  -- go through the history, <Tab> completes and <CR> runs the line
  local function key(lhs, in_menu, otherwise, desc)
    vim.keymap.set("i", lhs, function()
      if vim.fn.pumvisible() == 1 then
        return in_menu
      end
      if type(otherwise) == "function" then
        vim.schedule(otherwise)
        return ""
      end
      return otherwise
    end, { buffer = c.buf, expr = true, desc = desc })
  end
  key("<Up>", "<C-p>", function()
    recall(c, -1)
  end, "Previous command")
  key("<Down>", "<C-n>", function()
    recall(c, 1)
  end, "Next command")
  key("<Tab>", "<C-n>", function()
    complete(c)
  end, "Complete")
  key("<S-Tab>", "<C-p>", "<S-Tab>", "Previous completion")
  key("<CR>", "<C-y>", "<CR>", "Run the line")
  map("n", "<CR>", function()
    local row = vim.fn.line(".") - 1
    local mark = vim.api.nvim_buf_get_extmarks(c.buf, plot_ns, { row, 0 }, { row, -1 }, {})[1]
    local path = mark and c.plots[mark[1]]
    if path then
      M.view_image(path)
    end
  end, "View plot")
  map("n", "<localleader>rH", function()
    M.hide(c.k)
  end, "Hide console")
  consoles[k.id] = c
  append(
    c,
    { ("%s kernel (%s) in %s"):format(k.label, k.name, vim.fn.fnamemodify(vim.fn.getcwd(), ":~")) },
    "KernelConsoleNote"
  )
  return c
end

function M.get(k)
  local c = consoles[k.id]
  if c and vim.api.nvim_buf_is_valid(c.buf) then
    c.k = k
    return c
  end
  return create(k)
end

local WIN_OPTS = {
  winfixheight = true,
  number = false,
  relativenumber = false,
  signcolumn = "no",
  foldcolumn = "0",
  cursorline = false,
  spell = false,
  wrap = true,
}

-- A window in the current tab showing any kernel console.
local function console_win()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    for _, c in pairs(consoles) do
      if c.buf == buf then
        return win, c
      end
    end
  end
end

-- Show k's console along the bottom (reusing a console window that shows
-- another kernel's). `focus` moves the cursor into it.
function M.open(k, focus)
  local c = M.get(k)
  local win, shown = console_win()
  local cur = vim.api.nvim_get_current_win()
  if not win then
    vim.cmd("botright " .. HEIGHT .. "split")
    win = vim.api.nvim_get_current_win()
  end
  if shown ~= c then
    vim.api.nvim_win_set_buf(win, c.buf)
    for opt, val in pairs(WIN_OPTS) do
      vim.wo[win][0][opt] = val
    end
  end
  vim.api.nvim_win_set_cursor(win, { line_count(c), 0 })
  vim.api.nvim_set_current_win(focus and win or cur)
  return win
end

function M.visible(k)
  local c = consoles[k.id]
  if not c then
    return false
  end
  return #vim.fn.win_findbuf(c.buf) > 0
end

function M.hide(k)
  local c = consoles[k.id]
  if not c then
    return
  end
  for _, win in ipairs(vim.fn.win_findbuf(c.buf)) do
    if not pcall(vim.api.nvim_win_hide, win) then
      vim.notify("Can't hide the console: it's the only window", vim.log.levels.WARN)
    end
  end
end

function M.toggle(k)
  if M.visible(k) then
    M.hide(k)
  else
    M.open(k)
  end
end

-- Empty the console (keeps the prompt line).
function M.clear(k)
  local c = consoles[k.id]
  if c then
    vim.api.nvim_buf_set_lines(c.buf, 0, line_count(c) - 1, false, {})
    vim.api.nvim_buf_clear_namespace(c.buf, plot_ns, 0, -1)
    c.plots, c.partial = {}, false
  end
end

session.observe({
  change = function(k)
    if k.state == "starting" and not consoles[k.id] then
      -- a new kernel: make its console (it collects output while hidden)
      if SHOW_ON_START then
        M.open(k)
      else
        M.get(k)
      end
    elseif k.state == "dead" and consoles[k.id] then
      append(consoles[k.id], { "[kernel stopped]" }, "KernelConsoleNote")
    end
  end,
  -- The code is echoed when the kernel starts it (not when it is queued), so
  -- each output follows its own code when several runs are queued.
  exec = function(k, code, opts, req)
    if opts.echo and opts.source ~= "console" then
      M.get(k).to_echo[req] = code
    end
  end,
  event = function(k, ev, opts, req)
    if not opts.echo then
      return
    end
    local c = M.get(k)
    if c.to_echo[req] then
      echo(c, c.to_echo[req])
      c.to_echo[req] = nil
    end
    if ev.ev == "stream" then
      write(c, ev.text or "", ev.name == "stderr" and "KernelConsoleStderr" or nil)
    elseif ev.ev == "result" or ev.ev == "display" then
      finish_line(c)
      if ev.image then
        local row = append(c, { "[plot]  <CR> to view" }, "KernelConsolePlot")
        c.plots[vim.api.nvim_buf_set_extmark(c.buf, plot_ns, row, 0, {})] = ev.image
      elseif ev.text and ev.text ~= "" then
        append(c, vim.split(ev.text, "\n", { plain = true }))
      end
    elseif ev.ev == "error" then
      finish_line(c)
      local text = k.lang == "r" and (ev.evalue or "") or table.concat(ev.traceback or {}, "\n")
      append(c, vim.split(vim.trim(text), "\n", { plain = true }), "KernelConsoleError")
    elseif ev.ev == "input_request" then
      finish_line(c)
      c.input = function(value)
        session.input(k, value)
      end
      set_prompt(c, ev.prompt ~= "" and ev.prompt or "? ")
      M.open(k, true)
      vim.cmd.startinsert({ bang = true })
    elseif ev.ev == "done" then
      finish_line(c)
      if not ev.ok and (ev.ename == "KernelDied" or ev.ename == "BridgeExited") then
        append(c, { "[kernel died]" }, "KernelConsoleError")
      end
    end
  end,
})

return M
