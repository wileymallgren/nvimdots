-- Chunk output shown inline under each chunk's closing fence (virtual
-- lines; plots drawn with image.nvim), plus a status on the fence line:
-- running / done [execution count] and time / error. The code also shows
-- in the console. Outputs follow edits (extmarks).
--   run(c), run_all(upto, filter), delete(), clear_all(), toggle_hidden(),
--   open_float(), outputs(buf) (for lua/config/cmp-codeium.lua)

local session = require("config.kernel.session")
local chunks = require("config.kernel.chunks")

local M = {}

local MAX_TEXT_LINES = 20 -- per chunk; \mo shows everything
local IMAGE_ROWS = 12 -- rows reserved per plot (image.nvim max_height)
local ns = vim.api.nvim_create_namespace("kernel-inline")

for name, link in pairs({
  KernelOutput = "Comment",
  KernelOutputError = "DiagnosticError",
  KernelOutputStderr = "DiagnosticWarn",
  KernelOutputRunning = "DiagnosticInfo",
  KernelOutputDone = "DiagnosticOk",
  KernelOutputStale = "NonText",
}) do
  vim.api.nvim_set_hl(0, name, { link = link, default = true })
end

local state = {} -- buf -> { [mark id] = output }
local start_clock -- (defined below)

local function outputs_of(buf)
  state[buf] = state[buf] or {}
  return state[buf]
end

-- The output attached to chunk `c` (its closing fence), or nil.
local function find(buf, c)
  local row = c.e - 1
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, { row, 0 }, { row, -1 }, {})) do
    local out = outputs_of(buf)[m[1]]
    if out then
      return out
    end
  end
end

local function after_cr(s)
  local segs = vim.split(s, "\r", { plain = true })
  for i = #segs, 1, -1 do
    if segs[i] ~= "" then
      return segs[i]
    end
  end
  return ""
end

-- Split `text` into display lines no wider than `width`.
local function wrap(text, width)
  local res = {}
  for _, l in ipairs(vim.split(text, "\n", { plain = true })) do
    l = after_cr(l)
    while vim.fn.strdisplaywidth(l) > width do
      local cut = vim.fn.byteidx(l, width)
      table.insert(res, l:sub(1, cut))
      l = l:sub(cut + 1)
    end
    table.insert(res, l)
  end
  return res
end

local function clear_images(out)
  for _, img in ipairs(out.images or {}) do
    pcall(img.clear, img)
  end
  out.images, out.image_key = {}, nil
end

local function clock(secs)
  if secs < 60 then
    return ("%.1fs"):format(secs)
  end
  return ("%d:%02d"):format(math.floor(secs / 60), math.floor(secs % 60))
end

-- The status line shown first under the chunk.
local function status_line(out)
  if out.status == "running" then
    local secs = out.t0 and (vim.uv.hrtime() - out.t0) / 1e9 or 0
    return { { "  󰔟 running " .. clock(secs), "KernelOutputRunning" } }
  elseif out.status == "queued" then
    return { { "  󰔟 queued", "KernelOutput" } }
  end
  local text = (out.count and ("[%d]"):format(out.count) or "") .. (out.elapsed and (" " .. clock(out.elapsed)) or "")
  local line = out.status == "error" and { { "  ✗ " .. text, "KernelOutputError" } }
    or { { "  ✓ " .. text, "KernelOutputDone" } }
  if out.stale then
    table.insert(line, { "  · code edited since this ran", "KernelOutputStale" })
  end
  return line
end

local function render(buf, out)
  local pos = vim.api.nvim_buf_get_extmark_by_id(buf, ns, out.id, {})
  if not pos or not pos[1] then
    return
  end
  local row = pos[1]
  local win = vim.fn.bufwinid(buf)
  local width = (win ~= -1 and vim.api.nvim_win_get_width(win) - vim.fn.getwininfo(win)[1].textoff or 80) - 4
  local lines, n_text, slots, truncated = { status_line(out) }, 0, {}, 0
  local text_hl = out.stale and "KernelOutputStale" or nil
  if not out.hidden then
    for _, item in ipairs(out.items) do
      if item.kind == "image" then
        table.insert(slots, { offset = #lines, path = item.path })
        for _ = 1, IMAGE_ROWS do
          table.insert(lines, { { " ", "" } })
        end
      else
        for _, l in ipairs(wrap((item.text:gsub("\n$", "")), math.max(width, 20))) do
          if n_text < MAX_TEXT_LINES then
            table.insert(lines, { { "  " .. l, text_hl or item.hl or "KernelOutput" } })
          else
            truncated = truncated + 1
          end
          n_text = n_text + 1
        end
      end
    end
    if truncated > 0 then
      table.insert(lines, { { ("  … %d more lines (\\mo to see all)"):format(truncated), "KernelOutputRunning" } })
    end
  elseif #out.items > 0 then
    table.insert(lines, { { "  … output hidden (\\mh to show)", "KernelOutput" } })
  end
  vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { id = out.id, virt_lines = lines, right_gravity = false })

  -- Plots: only re-placed when they (or where they go) changed, so the
  -- running clock doesn't make them flicker
  local key = table.concat(
    vim.tbl_map(function(sl)
      return sl.path .. "@" .. sl.offset
    end, slots),
    ","
  ) .. ":" .. row .. ":" .. win .. ":" .. width
  if key == out.image_key and #(out.images or {}) == #slots then
    return
  end
  clear_images(out)
  out.image_key = key
  if #slots > 0 and win ~= -1 then
    local ok, image = pcall(require, "image")
    if ok then
      for _, sl in ipairs(slots) do
        local img = image.from_file(sl.path, {
          window = win,
          buffer = buf,
          x = 2,
          y = row,
          height = IMAGE_ROWS,
          render_offset_top = sl.offset,
          inline = false,
        })
        if img then
          pcall(img.render, img)
          table.insert(out.images, img)
        end
      end
    end
  end
end

local function rerender_soon(buf, out)
  if out.render_pending then
    return
  end
  out.render_pending = true
  vim.defer_fn(function()
    out.render_pending = false
    if vim.api.nvim_buf_is_valid(buf) then
      render(buf, out)
    end
  end, 30)
end

-- The running chunks' clocks tick once a second.
local clock_timer
local function tick()
  local running = false
  for buf, outs in pairs(state) do
    for _, out in pairs(outs) do
      if out.status == "running" and vim.api.nvim_buf_is_valid(buf) then
        running = true
        render(buf, out)
      end
    end
  end
  if not running and clock_timer then
    clock_timer:stop()
    clock_timer:close()
    clock_timer = nil
  end
end

start_clock = function()
  if not clock_timer then
    clock_timer = vim.uv.new_timer()
    clock_timer:start(1000, 1000, vim.schedule_wrap(tick))
  end
end

-- Mark outputs whose chunk was edited after it ran ("stale"), and unmark
-- them when the code is back to what ran.
local function check_stale(buf)
  local by_fence = {}
  for _, c in ipairs(chunks.find(buf)) do
    by_fence[c.e - 1] = c
  end
  for _, out in pairs(state[buf] or {}) do
    if out.body and out.status ~= "running" and out.status ~= "queued" then
      local pos = vim.api.nvim_buf_get_extmark_by_id(buf, ns, out.id, {})
      local c = pos and pos[1] and by_fence[pos[1]]
      local stale = c ~= nil and table.concat(chunks.body(c, buf), "\n") ~= out.body
      if stale ~= (out.stale or false) then
        out.stale = stale
        render(buf, out)
      end
    end
  end
end

-- Add an event's output to `out`.
local function collect(out, ev, lang)
  local items = out.items
  local last = items[#items]
  if ev.ev == "stream" then
    local hl = ev.name == "stderr" and "KernelOutputStderr" or nil
    if last and last.kind == "stream" and last.name == ev.name then
      last.text = last.text .. (ev.text or "")
    else
      table.insert(items, { kind = "stream", name = ev.name, text = ev.text or "", hl = hl })
    end
  elseif ev.ev == "result" or ev.ev == "display" then
    -- `display`: shown with display(); `result`: the value of the last line
    if ev.image then
      table.insert(items, { kind = "image", path = ev.image, display = ev.ev == "display", alt = ev.text })
    elseif ev.text and ev.text ~= "" then
      table.insert(items, { kind = "result", text = ev.text, display = ev.ev == "display" })
    end
  elseif ev.ev == "error" then
    local text = lang == "r" and (ev.evalue or "") or table.concat(ev.traceback or {}, "\n")
    table.insert(items, {
      kind = "error",
      text = vim.trim(text),
      hl = "KernelOutputError",
      ename = ev.ename,
      evalue = ev.evalue,
      traceback = ev.traceback,
    })
    out.status = "error"
  elseif ev.ev == "clear" then
    out.items = {}
  end
end

-- Run `code` and show its output under chunk `c` (replacing what was there).
function M.run_code(c, code, buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local out = find(buf, c)
  if not out then
    local id = vim.api.nvim_buf_set_extmark(buf, ns, c.e - 1, 0, { right_gravity = false })
    out = { id = id }
    outputs_of(buf)[id] = out
  end
  clear_images(out)
  out.items, out.status, out.count, out.elapsed, out.hidden = {}, "queued", nil, nil, false
  out.body, out.stale = table.concat(chunks.body(c, buf), "\n"), false
  render(buf, out)
  local k = session.ensure(c.lang, buf)
  if not k then
    out.status = "error"
    table.insert(out.items, { kind = "error", text = "No kernel for " .. c.lang, hl = "KernelOutputError" })
    render(buf, out)
    return
  end
  session.execute(k, code, {
    source = "chunk",
    on_event = function(ev)
      if out.status == "queued" then
        out.status, out.t0 = "running", vim.uv.hrtime()
        start_clock()
        if ev.ev == "running" then
          render(buf, out)
          return
        end
      end
      if ev.ev == "running" then
        return
      elseif ev.ev == "done" then
        out.elapsed = out.t0 and (vim.uv.hrtime() - out.t0) / 1e9
        out.count = ev.count
        if not ev.ok then
          out.status = "error"
          if ev.ename == "KernelDied" or ev.ename == "BridgeExited" or ev.ename == "Restarted" then
            table.insert(out.items, { kind = "error", text = "[" .. ev.ename .. "]", hl = "KernelOutputError" })
          end
        elseif out.status ~= "error" then
          out.status = "done"
        end
        render(buf, out)
      else
        collect(out, ev, c.lang)
        rerender_soon(buf, out)
      end
    end,
  })
end

-- The output under chunk `c` (nil if none): { items, status, count, ... }
function M.get(buf, c)
  return find(buf, c)
end

-- Show `items` (see collect()) as chunk `c`'s finished output, e.g. the
-- outputs saved in a notebook.
function M.restore(buf, c, items, count, failed)
  local out = find(buf, c)
  if not out then
    local id = vim.api.nvim_buf_set_extmark(buf, ns, c.e - 1, 0, { right_gravity = false })
    out = { id = id }
    outputs_of(buf)[id] = out
  end
  out.items, out.count, out.elapsed, out.hidden = items, count, nil, false
  out.status = failed and "error" or "done"
  out.body, out.stale = table.concat(chunks.body(c, buf), "\n"), false
  render(buf, out)
end

-- Has anything run, been restored or been cleared in `buf`? (Then its
-- outputs are what a notebook should be saved with.)
function M.touched(buf)
  return state[buf] ~= nil
end

function M.run(c, buf)
  if c.e - c.s < 2 then
    return -- empty chunk
  end
  M.run_code(c, table.concat(chunks.body(c, buf), "\n"), buf)
end

-- The chunk under the cursor, or nil after telling the user.
local function cursor_chunk()
  local c, i = chunks.at()
  if not c or not chunks.LANGS[c.lang] then
    vim.notify("Not inside an R or Python chunk", vim.log.levels.WARN)
    return nil
  end
  return c, i
end

-- Run the chunk under the cursor; `advance` then moves into the next chunk
-- (like Shift-Enter in Jupyter).
function M.run_cursor(advance)
  local c, i = cursor_chunk()
  if not c then
    return
  end
  M.run(c)
  if advance then
    local nxt = chunks.find()[i + 1]
    if nxt then
      vim.api.nvim_win_set_cursor(0, { math.min(nxt.s + 1, nxt.e), 0 })
    else
      vim.notify("That was the last chunk")
    end
  end
end

-- Run the visual selection as the output of the chunk it is in.
function M.run_selection()
  vim.cmd("normal! \27")
  local p1, p2 = vim.fn.getpos("'<"), vim.fn.getpos("'>")
  local c = chunks.at(p1[2])
  if not c or not chunks.LANGS[c.lang] then
    vim.notify("Not inside an R or Python chunk", vim.log.levels.WARN)
    return
  end
  local mode = vim.fn.visualmode()
  local lines = (mode == "V" or mode == "\22") and vim.api.nvim_buf_get_lines(0, p1[2] - 1, p2[2], false)
    or vim.fn.getregion(p1, p2, { type = mode })
  M.run_code(c, table.concat(lines, "\n"))
end

-- Run chunks in order. `upto` (optional) limits to chunks starting before
-- that line; `filter` (optional) is a predicate chunk -> bool. Skips
-- eval=FALSE chunks and languages without a kernel type.
function M.run_all(upto, filter)
  local n = 0
  for _, c in ipairs(chunks.find()) do
    if upto and c.s >= upto then
      break
    end
    if chunks.LANGS[c.lang] and not chunks.is_skipped(c) and (not filter or filter(c)) then
      M.run(c)
      n = n + 1
    end
  end
  vim.notify(("Running %d chunk(s)"):format(n))
end

-- Run the chunks above the cursor's (shown only in the console: their inline
-- outputs are left as they are), then the cursor's chunk with its output
-- inline. Skips eval=FALSE chunks above, not the current one.
function M.run_upto_cursor()
  local c, i = cursor_chunk()
  if not c then
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  local n = 0
  for j, above in ipairs(chunks.find(buf)) do
    if j >= i then
      break
    end
    if chunks.LANGS[above.lang] and not chunks.is_skipped(above) and above.e - above.s >= 2 then
      local k = session.ensure(above.lang, buf)
      if k then
        session.execute(k, table.concat(chunks.body(above, buf), "\n"), { source = "chunk" })
        n = n + 1
      end
    end
  end
  M.run(c, buf)
  vim.notify(("Ran %d chunk(s) above, then this one"):format(n))
end

-- Restart the kernels of the chunks above the cursor, then run those chunks
-- (inline), to check the notebook works from a clean session.
function M.restart_and_run_above()
  local buf, line = vim.api.nvim_get_current_buf(), vim.fn.line(".")
  local restarted = {}
  for _, c in ipairs(chunks.find(buf)) do
    if c.s >= line then
      break
    end
    local k = chunks.LANGS[c.lang] and session.find(c.lang, buf)
    if k and not restarted[k.id] then
      restarted[k.id] = true
      session.restart(k)
    end
  end
  M.run_all(line)
end

local function remove(buf, out)
  clear_images(out)
  pcall(vim.api.nvim_buf_del_extmark, buf, ns, out.id)
  outputs_of(buf)[out.id] = nil
end

function M.delete()
  local c = cursor_chunk()
  local buf = vim.api.nvim_get_current_buf()
  local out = c and find(buf, c)
  if out then
    remove(buf, out)
  end
end

function M.clear_all()
  local buf = vim.api.nvim_get_current_buf()
  for _, out in pairs(outputs_of(buf)) do
    remove(buf, out)
  end
end

function M.toggle_hidden()
  local c = cursor_chunk()
  local buf = vim.api.nvim_get_current_buf()
  local out = c and find(buf, c)
  if out then
    out.hidden = not out.hidden
    render(buf, out)
  end
end

-- All of the chunk's output in a float (plots as [plot] lines: <CR> views).
function M.open_float()
  local c = cursor_chunk()
  local out = c and find(vim.api.nvim_get_current_buf(), c)
  if not out or #out.items == 0 then
    vim.notify("No output for this chunk")
    return
  end
  local lines, plots = {}, {}
  for _, item in ipairs(out.items) do
    if item.kind == "image" then
      table.insert(lines, "[plot]  <CR> to view")
      plots[#lines] = item.path
    else
      vim.list_extend(lines, vim.tbl_map(after_cr, vim.split((item.text:gsub("\n$", "")), "\n", { plain = true })))
    end
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local width = 40
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l) + 2)
  end
  width = math.min(vim.o.columns - 4, width)
  local height = math.min(vim.o.lines - 6, #lines)
  vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    style = "minimal",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    title = " Chunk output ",
  })
  vim.keymap.set("n", "q", "<cmd>close<CR>", { buffer = buf })
  vim.keymap.set("n", "<CR>", function()
    local path = plots[vim.fn.line(".")]
    if path then
      require("config.kernel.console").view_image(path)
    end
  end, { buffer = buf })
end

-- Text outputs in `buf`: { { row = closing-fence row (0-based), lines } }.
function M.outputs(buf)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  local res = {}
  for id, out in pairs(state[buf] or {}) do
    local pos = vim.api.nvim_buf_get_extmark_by_id(buf, ns, id, {})
    if pos and pos[1] then
      local lines = {}
      for _, item in ipairs(out.items) do
        if item.kind ~= "image" then
          vim.list_extend(lines, vim.split((item.text:gsub("\n$", "")), "\n", { plain = true }))
        end
      end
      table.insert(res, { row = pos[1], lines = lines })
    end
  end
  return res
end

-- Re-draw plots when the window changes (they're tied to a window).
vim.api.nvim_create_autocmd({ "BufWinEnter", "VimResized" }, {
  group = vim.api.nvim_create_augroup("KernelInline", { clear = true }),
  callback = function(ev)
    for buf, outs in pairs(state) do
      if (ev.event == "VimResized" or buf == ev.buf) and vim.api.nvim_buf_is_valid(buf) then
        for _, out in pairs(outs) do
          render(buf, out)
        end
      end
    end
  end,
})
vim.api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, {
  group = "KernelInline",
  callback = function(ev)
    if state[ev.buf] then
      check_stale(ev.buf)
    end
  end,
})
vim.api.nvim_create_autocmd("BufWipeout", {
  group = "KernelInline",
  callback = function(ev)
    for _, out in pairs(state[ev.buf] or {}) do
      clear_images(out)
    end
    state[ev.buf] = nil
  end,
})

return M
