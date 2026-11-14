-- Notebook workspace (<localleader>mw): runs the chunks above the cursor's
-- (console only) and then the cursor's chunk, and opens a column on the
-- right with
--   top     the output of the chunk under the cursor (follows the cursor;
--           plots drawn with image.nvim, <CR> on [plot] views it big)
--   bottom  the data that chunk works on (chunks.data_name: `df %>% ...`
--           shows df), refreshed each time the chunk finishes running; when
--           \mw finds none it lets you pick from the session's objects
-- Plots fill the output pane and re-fit when it is resized; while it is
-- open R draws plots in the pane's shape and wraps text at its width.
-- While it is open, chunk output (and its status) doesn't show inline.
-- \mw again, or q in the output pane, closes it and brings it back.

local chunks = require("config.kernel.chunks")
local inline = require("config.kernel.inline")
local objects = require("config.kernel.objects")

local M = {}

local ns = vim.api.nvim_create_namespace("kernel-workspace")
local layouts = {} -- tabpage -> layout

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
  for _, img in ipairs(L.images) do
    pcall(img.clear, img)
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
  local lines, hls, plots = {}, {}, {}
  local function add(text, hl)
    table.insert(lines, text)
    if hl then
      hls[#lines] = hl
    end
  end
  if not c then
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
      add("Not run yet", "Comment")
    else
      local width, height = vim.api.nvim_win_get_width(L.out_win), vim.api.nvim_win_get_height(L.out_win)
      local n_plots, n_text = 0, 0
      for _, item in ipairs(out.items) do
        if item.kind == "image" then
          n_plots = n_plots + 1
        else
          n_text = n_text + #vim.split((item.text:gsub("\n$", "")), "\n", { plain = true })
        end
      end
      -- A plot fills the pane: a lone one the room the text leaves, several
      -- a pane height each (scroll through them)
      local rows = n_plots == 1 and height - 2 - n_text or height - 2
      rows = math.max(8, rows)
      for _, item in ipairs(out.items) do
        if item.kind == "image" then
          add("[plot]  <CR> to view", "Special")
          table.insert(plots, { row = #lines, path = item.path, rows = rows, width = width })
          for _ = 1, rows do
            add("")
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
  L.plots = {}
  for _, p in ipairs(plots) do
    L.plots[p.row] = p.path
  end

  -- Plots are only re-placed when they (or the pane) changed, so the
  -- running clock doesn't make them flicker
  local key = table.concat(
    vim.tbl_map(function(p)
      return p.path .. "@" .. p.row .. ":" .. p.rows .. "x" .. p.width
    end, plots),
    ","
  )
  if key ~= L.image_key then
    clear_images(L)
    L.image_key = key
    local ok, image = pcall(require, "image")
    if ok then
      for _, p in ipairs(plots) do
        local img = image.from_file(p.path, {
          window = L.out_win,
          buffer = L.out_buf,
          x = 0,
          y = p.row, -- the line after [plot] (0-based)
          width = p.width,
          height = p.rows,
          inline = false,
        })
        if img then
          -- past image.nvim's max_width / max_height (lua/plugins/image.lua,
          -- sized for inline plots): the pane decides the size here
          img.ignore_global_max_size = true
          pcall(img.render, img)
          table.insert(L.images, img)
        end
      end
    end
  end
end

local function render(L)
  if L.rendering or not valid(L.out_win) then
    return
  end
  L.rendering = true
  local ok, err = pcall(render_output, L)
  L.rendering = false
  if not ok then
    vim.notify("Workspace: " .. tostring(err), vim.log.levels.ERROR)
  end
end

-- Show the data chunk `c` works on in the data pane. `pick`: when the chunk
-- names none, choose from the session's objects.
local function show_data(L, c, pick)
  if not valid(L.data_win) then
    return
  end
  local name = chunks.data_name(c, L.src_buf)
  if name then
    objects.view(name, { win = L.data_win, lang = c.lang, buf = L.src_buf, quiet = true, df_only = true })
  elseif pick then
    objects.list_objects({
      lang = c.lang,
      on_pick = function(n)
        objects.view(n, { win = L.data_win, lang = c.lang, buf = L.src_buf })
      end,
    })
  end
end

-- Make R's next output fit the output pane: text as wide as the pane
-- (options(width)), plots in the pane's shape (repr.plot.*). The values
-- they had are kept in .nvim_ws_opts and put back on close. Python output
-- keeps its own sizes.
local function fit_kernel(L)
  local k = require("config.kernel.session").find("r", L.src_buf)
  if not k or not valid(L.out_win) then
    return
  end
  local cols, rows = vim.api.nvim_win_get_width(L.out_win), vim.api.nvim_win_get_height(L.out_win) - 2
  local cw, ch = 1, 2 -- cell width : height, when the terminal doesn't say
  local ok, term = pcall(function()
    return require("image.utils.term").get_size()
  end)
  if ok and term and (term.cell_width or 0) > 0 and (term.cell_height or 0) > 0 then
    cw, ch = term.cell_width, term.cell_height
  end
  local h = 7 * math.max(0.3, math.min(3, (rows * ch) / (cols * cw)))
  local code = ([[local({
  o <- options(width = %d, repr.plot.width = 7, repr.plot.height = %.2f)
  if (!exists(".nvim_ws_opts", globalenv())) assign(".nvim_ws_opts", o, globalenv())
})]]):format(math.max(40, cols - 1), h)
  require("config.kernel.session").eval(k, code, function() end)
end

local function unfit_kernel(L)
  local k = require("config.kernel.session").find("r", L.src_buf)
  if k then
    require("config.kernel.session").eval(
      k,
      [[if (exists(".nvim_ws_opts", globalenv())) { options(.nvim_ws_opts); rm(".nvim_ws_opts", envir = globalenv()) }]],
      function() end
    )
  end
end

local function close(L)
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
  if L.fit_timer then
    L.fit_timer:stop()
    L.fit_timer:close()
  end
  unfit_kernel(L)
  if vim.api.nvim_buf_is_valid(L.src_buf) then
    inline.set_inline(L.src_buf, true)
  end
end

-- Output updates: re-render when they are the followed chunk's; when it
-- finishes running, refresh the data pane.
inline.on_update(function(buf, out)
  for _, L in pairs(layouts) do
    if L.src_buf == buf and not L.rendering then
      local c = L.idx and chunks.find(buf)[L.idx]
      if c and inline.get(buf, c) == out then
        render(L)
        if out.status == "done" or out.status == "error" then
          local key = ("%d:%s:%s"):format(out.id, tostring(out.count), tostring(out.elapsed))
          if key ~= L.data_key then
            L.data_key = key
            show_data(L, c, L.first_run)
            L.first_run = false
          end
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
  local placeholder = scratch("data")
  set_lines(placeholder, { "The data the chunk works on shows here" })
  vim.api.nvim_win_set_buf(L.data_win, placeholder)
  for _, win in ipairs({ L.out_win, L.data_win }) do
    for opt, val in pairs(WIN_OPTS) do
      vim.wo[win][opt] = val -- (not [0]: they stay when the data pane loads a new table)
    end
  end
  vim.wo[L.out_win].wrap = true
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
      local _, idx = followed(L)
      if idx and idx ~= L.idx then
        L.idx = idx
        render(L)
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = L.group,
    pattern = { tostring(L.out_win), tostring(L.data_win), tostring(src_win) },
    callback = function()
      vim.schedule(close_it)
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
  inline.set_inline(src_buf, false)
  render(L)
  if c.lang == "r" then
    -- before the runs (the kernel runs requests in order)
    require("config.kernel.session").ensure("r", src_buf)
    fit_kernel(L)
  end
  inline.run_upto_cursor()
end

function M.toggle()
  local L = layouts[vim.api.nvim_get_current_tabpage()]
  if L then
    close(L)
  else
    open()
  end
end

return M
