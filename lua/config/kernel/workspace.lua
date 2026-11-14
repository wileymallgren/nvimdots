-- Notebook workspace (<localleader>mw): runs the chunks above the cursor's
-- (console only) and then the cursor's chunk, and opens a column on the
-- right with
--   top     the output of the chunk under the cursor (follows the cursor;
--           plots as image placeholders (lua/config/image.lua), <CR> on
--           one views it big)
--   bottom  the data that chunk works on (chunks.data_names: `df %>% ...`
--           shows df; follows the cursor too), loaded again whenever a
--           chunk finishes running; when \mw finds none it lets you pick
--           from the session's objects
-- Plots fill the output pane and re-fit when it is resized; while it is
-- open R draws plots in the pane's shape and wraps text at its width.
-- While it is open, chunk output (and its status) doesn't show inline.
-- \mw again, or q in the output pane, closes it and brings it back.

local chunks = require("config.kernel.chunks")
local image = require("config.image")
local inline = require("config.kernel.inline")
local objects = require("config.kernel.objects")
local session = require("config.kernel.session")

local M = {}

local ns = vim.api.nvim_create_namespace("kernel-workspace")
local layouts = {} -- tabpage -> layout

-- Rows a plot leaves free in the output pane: the header line.
local PLOT_MARGIN = 1

local WIN_OPTS = {
  number = false,
  relativenumber = false,
  signcolumn = "no",
  foldcolumn = "0",
  spell = false,
  winfixwidth = true,
}

local function valid(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
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

local function scratch(name)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  pcall(vim.api.nvim_buf_set_name, buf, name)
  return buf
end

local function set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

local function clear_images(L)
  for _, img in pairs(L.images) do
    img:delete()
  end
  L.images, L.image_key = {}, nil
end

-- The R / Python chunk under the cursor of the notebook window (nil outside one).
local function followed(L)
  if not valid(L.src_win) or vim.api.nvim_win_get_buf(L.src_win) ~= L.src_buf then
    return
  end
  local line = vim.api.nvim_win_get_cursor(L.src_win)[1]
  local c, i = chunks.at(line, L.src_buf)
  if c and chunks.LANGS[c.lang] then
    return c, i
  end
end

-- Show the output of chunk number L.idx in the output pane.
local function render_output(L)
  local c = L.idx and chunks.find(L.src_buf)[L.idx]
  local out = c and inline.get(L.src_buf, c)
  local lines, hls, overlays = {}, {}, {}
  local plot_rows = {} -- line -> plot shown on it (<CR> views it)
  local function add(text, hl)
    table.insert(lines, text)
    if hl then
      hls[#lines] = hl
    end
  end
  if not c then
    clear_images(L)
    add("Move into an R or Python chunk", "Comment")
  else
    local head = ("Chunk %d (%s)"):format(L.idx, c.lang == "r" and "R" or c.lang)
    if out then
      for _, seg in ipairs(inline.status_line(out)) do
        head = head .. seg[1]
      end
    end
    add(head, "Title")
    if not out then
      clear_images(L)
      add("Not run yet", "Comment")
    else
      local width, height = vim.api.nvim_win_get_width(L.out_win), vim.api.nvim_win_get_height(L.out_win)
      local n_plots, text_rows = 0, 0
      for _, item in ipairs(out.items) do
        if item.kind == "image" then
          n_plots = n_plots + 1
        else
          -- screen rows, with the long lines wrapped
          for _, l in ipairs(vim.split((item.text:gsub("\n$", "")), "\n", { plain = true })) do
            text_rows = text_rows + math.max(1, math.ceil(vim.fn.strdisplaywidth(after_cr(l)) / width))
          end
        end
      end
      -- A plot fills the pane: a lone one the room the header and text
      -- leave, several a pane height each (scroll through them)
      local rows = math.max(8, (n_plots == 1 and height - text_rows or height) - PLOT_MARGIN)
      -- Plots are only sent to the terminal again when they (or the room
      -- for them) changed, not on every clock tick
      local paths = {}
      for _, item in ipairs(out.items) do
        if item.kind == "image" then
          table.insert(paths, item.path)
        end
      end
      local key = table.concat(paths, ",") .. ":" .. rows .. "x" .. width
      if key ~= L.image_key then
        clear_images(L)
        L.image_key = key
        for i, path in ipairs(paths) do
          L.images[i] = image.new(path, { max_cols = width, max_rows = rows, grow = true })
        end
      end
      local n_img = 0
      for _, item in ipairs(out.items) do
        if item.kind == "image" then
          n_img = n_img + 1
          local img = L.images[n_img]
          if img then
            for r = 0, img.rows - 1 do
              add("")
              plot_rows[#lines] = item.path
              overlays[#lines] = img:chunks(r)
            end
          else
            add("[plot]  <CR> to view", "Comment")
            plot_rows[#lines] = item.path
          end
        else
          local hl = out.stale and "NonText" or item.hl
          for _, l in ipairs(vim.split((item.text:gsub("\n$", "")), "\n", { plain = true })) do
            add(after_cr(l), hl)
          end
        end
      end
    end
  end
  set_lines(L.out_buf, lines)
  vim.api.nvim_buf_clear_namespace(L.out_buf, ns, 0, -1)
  for row, hl in pairs(hls) do
    vim.api.nvim_buf_set_extmark(L.out_buf, ns, row - 1, 0, { end_row = row, hl_group = hl, hl_eol = false })
  end
  for row, chunks_ in pairs(overlays) do
    vim.api.nvim_buf_set_extmark(L.out_buf, ns, row - 1, 0, { virt_text = chunks_, virt_text_pos = "overlay" })
  end
  L.plots = plot_rows
end

local close -- (defined below)

local function render(L)
  if L.rendering or not valid(L.out_win) then
    return
  end
  if not vim.api.nvim_buf_is_valid(L.out_buf) or vim.api.nvim_win_get_buf(L.out_win) ~= L.out_buf then
    close(L) -- the pane lost its buffer (winfixbuf keeps it, but :bwipe doesn't ask)
    return
  end
  L.rendering = true
  local ok, err = pcall(render_output, L)
  L.rendering = false
  if not ok then
    vim.notify("Workspace: " .. tostring(err), vim.log.levels.ERROR)
  end
end

-- Show the data the followed chunk works on in the data pane: the first of
-- its chunks.data_names that is a data frame in the session. It loads
-- again when that changes or a chunk ran since it loaded (the data may have
-- changed). `pick`: when there is none, choose from the session's objects.
local function show_data(L, pick)
  local c = L.idx and chunks.find(L.src_buf)[L.idx]
  if not c or not valid(L.data_win) then
    return
  end
  local function choose()
    objects.list_objects({
      lang = c.lang,
      buf = L.src_buf,
      on_pick = function(n)
        objects.view(n, { win = L.data_win, lang = c.lang, buf = L.src_buf })
        L.shown = n
      end,
    })
  end
  local names = chunks.data_names(c, L.src_buf)
  local k = session.find(c.lang, L.src_buf)
  if #names == 0 or not k then
    if pick and k then
      choose()
    end
    return
  end
  local quoted = table.concat(
    vim.tbl_map(function(n)
      return '"' .. n .. '"'
    end, names),
    ", "
  )
  local code = c.lang == "r"
      and ([[cat(Find(function(n) { o <- get0(n, envir = globalenv()); is.data.frame(o) || is.matrix(o) }, c(%s)), "")]]):format(
        quoted
      )
    or ([[print(next((n for n in [%s] if isinstance(globals().get(n), (__import__("pandas").DataFrame, __import__("pandas").Series))), ""))]]):format(
      quoted
    )
  local dirty = L.dirty
  L.dirty = false
  session.eval(k, code, function(text, ok)
    local name = ok and vim.trim(text) or ""
    if L.closed or not valid(L.data_win) then
      return
    elseif name == "" then
      if pick then
        choose()
      elseif not L.shown and vim.api.nvim_win_get_buf(L.data_win) == L.placeholder then
        set_lines(L.placeholder, { ("No data frame yet: %s"):format(table.concat(names, ", ")) })
      end
    elseif name ~= L.shown or dirty then
      objects.view(name, {
        win = L.data_win,
        lang = c.lang,
        buf = L.src_buf,
        quiet = true,
        on_result = function(viewed)
          if viewed then
            L.shown = name
          end
        end,
      })
    end
  end)
end

-- show_data once things settle (cursor moves, runs finishing one after
-- another in a run-all).
local function show_data_soon(L, ms, pick)
  L.pick = L.pick or pick
  L.data_timer = L.data_timer or vim.uv.new_timer()
  L.data_timer:start(
    ms,
    0,
    vim.schedule_wrap(function()
      if not L.closed then
        local p = L.pick
        L.pick = false
        show_data(L, p)
      end
    end)
  )
end

-- Make R's next output fit the output pane: text as wide as the pane
-- (options(width)), plots in the pane's shape (repr.plot.*). The values
-- they had are kept in .nvim_ws_opts and put back on close. Python output
-- keeps its own sizes.
local function fit_kernel(L)
  local k = session.find("r", L.src_buf)
  if not k or not valid(L.out_win) then
    return
  end
  local cols, rows = vim.api.nvim_win_get_width(L.out_win), vim.api.nvim_win_get_height(L.out_win) - PLOT_MARGIN
  local cw, ch = image.cell_size()
  local h = 7 * math.max(0.3, math.min(3, (rows * ch) / (cols * cw)))
  local code = ([[local({
  o <- options(width = %d, repr.plot.width = 7, repr.plot.height = %.2f)
  if (!exists(".nvim_ws_opts", globalenv())) assign(".nvim_ws_opts", o, globalenv())
})]]):format(math.max(40, cols - 1), h)
  session.eval(k, code, function() end)
end

local function unfit_kernel(L)
  local k = session.find("r", L.src_buf)
  if k then
    session.eval(
      k,
      [[if (exists(".nvim_ws_opts", globalenv())) { options(.nvim_ws_opts); rm(".nvim_ws_opts", envir = globalenv()) }]],
      function() end
    )
  end
end

close = function(L)
  if L.closed then
    return
  end
  L.closed = true
  layouts[L.tab] = nil
  pcall(vim.api.nvim_del_augroup_by_id, L.group)
  clear_images(L)
  for _, win in ipairs({ L.out_win, L.data_win }) do
    if valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  for _, t in pairs({ L.fit_timer or false, L.data_timer or false }) do
    if t then
      t:stop()
      t:close()
    end
  end
  -- (another tab's workspace may still use the buffer / the kernel options)
  local others, same_buf = false, false
  for _, o in pairs(layouts) do
    others = true
    same_buf = same_buf or o.src_buf == L.src_buf
  end
  if not others then
    unfit_kernel(L)
  end
  if not same_buf and vim.api.nvim_buf_is_valid(L.src_buf) then
    inline.set_inline(L.src_buf, true)
  end
end

-- A restarted (or newly started) R kernel has R's default sizes again.
session.observe({
  change = function(k)
    if k.lang == "r" and k.state == "starting" then
      for _, L in pairs(layouts) do
        fit_kernel(L)
      end
    end
  end,
})

-- Output updates: re-render when they are the followed chunk's. Any chunk
-- finishing may have changed the data, so the data pane loads again.
inline.on_update(function(buf, out)
  for _, L in pairs(layouts) do
    if L.src_buf == buf and not L.rendering then
      local c = L.idx and chunks.find(buf)[L.idx]
      local is_followed = c ~= nil and inline.get(buf, c) == out
      if is_followed and not L.opening then
        render(L)
      end
      if out.status == "done" or out.status == "error" then
        local key = ("%s:%s"):format(tostring(out.count), tostring(out.elapsed))
        if L.opening then
          L.seen[out.id] = key -- ran before \mw: not a new run
        elseif L.seen[out.id] ~= key then
          L.seen[out.id] = key
          L.dirty = true
          -- the first time \mw's own chunk finishes, a chunk without a
          -- data name lets you pick one
          local pick = is_followed and L.first_run
          if is_followed then
            L.first_run = false
          end
          show_data_soon(L, 150, pick)
        end
      end
    end
  end
end)

local function open()
  local c, i = chunks.at()
  if not c or not chunks.LANGS[c.lang] then
    vim.notify("Not inside an R or Python chunk", vim.log.levels.WARN)
    return
  end
  local src_win, src_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  local tab = vim.api.nvim_get_current_tabpage()
  local L = {
    tab = tab,
    src_win = src_win,
    src_buf = src_buf,
    idx = i,
    images = {},
    plots = {},
    seen = {}, -- output id -> the finished run last seen
    first_run = true,
  }

  vim.cmd("rightbelow vsplit")
  L.out_win = vim.api.nvim_get_current_win()
  vim.cmd(("vertical resize %d"):format(math.max(50, math.floor(vim.o.columns * 0.3))))
  L.out_buf = scratch("chunk output")
  vim.bo[L.out_buf].filetype = "kernel_output"
  vim.api.nvim_win_set_buf(L.out_win, L.out_buf)
  vim.cmd("rightbelow split")
  L.data_win = vim.api.nvim_get_current_win()
  L.placeholder = scratch("data")
  set_lines(L.placeholder, { "The data the chunk works on shows here" })
  vim.api.nvim_win_set_buf(L.data_win, L.placeholder)
  for _, win in ipairs({ L.out_win, L.data_win }) do
    for opt, val in pairs(WIN_OPTS) do
      vim.wo[win][opt] = val -- (not [0]: they stay when the data pane loads a new table)
    end
  end
  vim.wo[L.out_win].wrap = true
  vim.wo[L.out_win].winfixbuf = true -- :e / :bnext / pickers can't replace the output
  vim.wo[L.out_win].cursorline = false
  vim.api.nvim_set_current_win(src_win)

  local function close_it()
    close(L)
  end
  vim.keymap.set("n", "q", close_it, { buffer = L.out_buf, desc = "Close the workspace" })
  vim.keymap.set("n", "<CR>", function()
    local path = L.plots[vim.fn.line(".")]
    if path then
      require("config.kernel.console").view_image(path)
    end
  end, { buffer = L.out_buf, desc = "View plot" })

  L.group = vim.api.nvim_create_augroup("KernelWorkspace" .. tab, { clear = true })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = L.group,
    buffer = src_buf,
    callback = function()
      -- the notebook may be in another window too: follow the one in use
      local win = vim.api.nvim_get_current_win()
      if win ~= L.out_win and win ~= L.data_win and vim.api.nvim_win_get_tabpage(win) == L.tab then
        L.src_win = win
      end
      local _, idx = followed(L)
      if idx and idx ~= L.idx then
        L.idx = idx
        render(L)
        show_data_soon(L, 250)
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = L.group,
    callback = function(ev)
      local win = tonumber(ev.match)
      if win == L.out_win or win == L.data_win then
        vim.schedule(close_it)
      elseif win == L.src_win then
        vim.schedule(function()
          -- the notebook still shown in another window of the tab: follow that
          for _, w in ipairs(valid(L.out_win) and vim.api.nvim_tabpage_list_wins(L.tab) or {}) do
            if vim.api.nvim_win_get_buf(w) == L.src_buf then
              L.src_win = w
              return
            end
          end
          close_it()
        end)
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinResized", {
    group = L.group,
    callback = function()
      if valid(L.out_win) and vim.tbl_contains(vim.v.event.windows or {}, L.out_win) then
        render(L) -- plots re-fit right away
        -- the kernel's sizes once the resizing stops
        L.fit_timer = L.fit_timer or vim.uv.new_timer()
        L.fit_timer:start(300, 0, vim.schedule_wrap(function()
          if not L.closed then
            fit_kernel(L)
          end
        end))
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", { group = L.group, buffer = src_buf, callback = close_it })

  layouts[tab] = L
  L.opening = true -- (outputs from before \mw re-render here: not new runs)
  inline.set_inline(src_buf, false)
  L.opening = false
  render(L)
  if c.lang == "r" then
    -- before the runs (the kernel runs requests in order); a kernel that
    -- starts now gets them from the observer above
    if session.find("r", src_buf) then
      fit_kernel(L)
    else
      session.ensure("r", src_buf)
    end
  end
  inline.run_upto_cursor()
end

function M.toggle()
  local L = layouts[vim.api.nvim_get_current_tabpage()]
  if L then
    close(L)
    if L.src_buf == vim.api.nvim_get_current_buf() then
      return
    end
  end
  open() -- (\mw in another notebook moves the workspace to it)
end

return M
