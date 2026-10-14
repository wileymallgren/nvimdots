-- Inline preview of LaTeX / markdown snippets using the existing image.nvim
-- (kitty backend, works in Ghostty).
--
-- Normal mode (all under <leader>r, "render"):
--   <leader>rp  auto-detect what's under the cursor and render it:
--                 1. outermost \begin{env}...\end{env} (table, itemize,
--                    enumerate, align, equation, matrix, ...)
--                 2. \[ ... \]  or  $$ ... $$
--                 3. inline $...$ on the current line
--                 4. the paragraph (blank-line delimited), converted from
--                    markdown with pandoc if available (lists, **bold**, math)
--   <leader>rm  render the current paragraph as markdown (via pandoc)
--   <leader>ra  render EVERYTHING renderable in the buffer
--   <leader>rs  render everything renderable on the SCREEN (visible lines)
--   <leader>rla render only LaTeX (environments, display + inline math) in the buffer
--   <leader>rls render only LaTeX on the SCREEN
--   <leader>rr  repeat the last preview command (e.g. after editing)
--   <leader>rw  toggle re-render on save (repeats the last preview command)
--   <leader>rx  clear the preview of the block under the cursor
--   <leader>rc  clear all previews in the current buffer
--   <leader>r+  bigger previews (higher dpi), re-render
--   <leader>r-  smaller previews, re-render
--   <leader>rt  toggle colours: match the colorscheme / black on white paper
--   <leader>ro  open the last rendered snippet as a PDF
--   <leader>re  open the last generated .tex file (debug a failing render)
--   <Esc>       if a render was the last thing you did, close it (all of
--               them, for ra/rs)
-- Visual mode:
--   <leader>rp  render selection as raw LaTeX
--   <leader>rm  render selection as markdown (via pandoc)
--
-- :TexPreviewSet              show the current settings
-- :TexPreviewSet {opt} {val}  change one for this session (dpi, width, pad,
--                             packages, theme, fg, bg, jobs, y_offset),
--                             e.g. `:TexPreviewSet width 600pt`
--
-- "Everything renderable" = every LaTeX environment, display math, and any
-- paragraph containing inline math, a LaTeX command, or a markdown list.
-- Code fences and YAML front matter are skipped.
--
-- Deps: tectonic OR pdflatex, pdftoppm (brew install poppler),
--       optional: pandoc (brew install pandoc) for markdown mode.

local cfg = {
  width = "450pt", -- max text width of the rendered snippet
  dpi = 200,
  jobs = 3, -- max parallel compiles for ta/ts
  msg_ms = 1500, -- how long success messages stay in the cmdline
  y_offset = -1, -- shift every image by this many lines (-1 = one line higher)
  -- colours (hex, no #). nil = take them from the active colorscheme:
  --   text = Normal fg, background = Normal bg
  fg = nil,
  bg = nil,
  theme = "colorscheme", -- "colorscheme" (match the editor) or "paper" (black on white); <leader>rt toggles
  pad = "8pt", -- padding around the text
  packages = "amsmath,amssymb,amsfonts,booktabs,multirow,array,xcolor,varwidth",
}

local previews = {} -- bufnr -> { [row] = image }
local last_dir -- temp dir of the most recent successful render (snip.tex / .pdf / .png)

-- <Esc> closes previews if rendering them was the last thing you did.
local key_count = 0 -- every key seen so far
local request_n = 0 -- key_count when the current request was made
local active -- list of { buf, row } still counting as "last input"
local ESC = vim.keycode("<Esc>")

vim.on_key(function(key, typed)
  local k = (typed and typed ~= "") and typed or key
  key_count = key_count + 1
  local a = active
  active = nil -- any key (including this one) ends the "last input" window
  if a and k == ESC then
    vim.schedule(function()
      for _, it in ipairs(a) do
        local img = previews[it.buf] and previews[it.buf][it.row]
        if img then
          pcall(function()
            img:clear()
          end)
          previews[it.buf][it.row] = nil
        end
      end
    end)
  end
end, vim.api.nvim_create_namespace("tex_preview_esc"))

local function clear(buf)
  for _, img in pairs(previews[buf] or {}) do
    pcall(function()
      img:clear()
    end)
  end
  previews[buf] = nil
end

local function clear_range(buf, first, last)
  for row, img in pairs(previews[buf] or {}) do
    if row >= first and row <= last then
      pcall(function()
        img:clear()
      end)
      previews[buf][row] = nil
    end
  end
end

---------------------------------------------------------------------------
-- Detection
---------------------------------------------------------------------------

-- Blank out fenced code blocks and YAML front matter (keeps line numbers)
local function mask_code(lines)
  local out, in_fence = {}, false
  for i, l in ipairs(lines) do
    if l:match("^%s*```") then
      in_fence = not in_fence
      out[i] = ""
    elseif in_fence then
      out[i] = ""
    else
      out[i] = l
    end
  end
  if lines[1] and lines[1]:match("^%-%-%-%s*$") then
    for j = 2, #lines do
      if lines[j]:match("^%-%-%-%s*$") or lines[j]:match("^%.%.%.%s*$") then
        for i = 1, j do
          out[i] = ""
        end
        break
      end
    end
  end
  return out
end

-- plain-find a token that is not preceded by a backslash (avoids `\\[2pt]`)
local function has_token(line, tok)
  local init = 1
  while true do
    local s = line:find(tok, init, true)
    if not s then
      return false
    end
    if s == 1 or line:sub(s - 1, s - 1) ~= "\\" then
      return true
    end
    init = s + 1
  end
end

-- All environment / display-math ranges: { {s=, e=}, ... } (may be nested)
local function collect_latex_blocks(lines)
  local stacks, found = {}, {}
  local disp_start, dollar_start

  for i, l in ipairs(lines) do
    for kind, name in l:gmatch("\\(%a+){([%w%*]+)}") do
      if kind == "begin" then
        stacks[name] = stacks[name] or {}
        table.insert(stacks[name], i)
      elseif kind == "end" then
        local st = stacks[name]
        if st and #st > 0 then
          local s = table.remove(st)
          if name ~= "document" then
            table.insert(found, { s = s, e = i })
          end
        end
      end
    end

    if has_token(l, "\\[") then
      disp_start = i
    end
    if disp_start and has_token(l, "\\]") then
      table.insert(found, { s = disp_start, e = i })
      disp_start = nil
    end

    for _ in l:gmatch("%$%$") do
      if not dollar_start then
        dollar_start = i
      else
        table.insert(found, { s = dollar_start, e = i })
        dollar_start = nil
      end
    end
  end
  return found
end

-- Outermost block containing `row`
local function find_latex_block(lines, row)
  local best
  for _, r in ipairs(collect_latex_blocks(lines)) do
    if r.s <= row and row <= r.e then
      if not best or (r.e - r.s) > (best.e - best.s) then
        best = r
      end
    end
  end
  if best then
    return best.s, best.e
  end
end

-- All inline math on a line: { {s=, e=, text=}, ... } (e is exclusive).
-- $...$ follows pandoc's rules (no space just inside the dollars, closing $
-- not followed by a digit) so prices like "$5 and $10" are not picked up.
-- \( ... \) is supported too.
local function inline_math_in(line)
  local out = {}
  for s, content, e in line:gmatch("()%$([^%$]+)%$()") do
    local before, after = line:sub(s - 1, s - 1), line:sub(e, e)
    if
      content:match("^%S")
      and content:match("%S$")
      and not after:match("%d")
      and before ~= "\\"
      and before ~= "$"
      and after ~= "$"
    then
      table.insert(out, { s = s, e = e, text = "$" .. content .. "$" })
    end
  end
  for s, content, e in line:gmatch("()\\%((.-)\\%)()") do
    table.insert(out, { s = s, e = e, text = "\\(" .. content .. "\\)" })
  end
  table.sort(out, function(a, b)
    return a.s < b.s
  end)
  return out
end

-- Returns the inline math text under the cursor, if any
local function find_inline_math(line, col0)
  local col = col0 + 1
  for _, m in ipairs(inline_math_in(line)) do
    if col >= m.s and col < m.e then
      return m.text
    end
  end
end

local function find_paragraph(lines, row)
  if not lines[row] or lines[row]:match("^%s*$") then
    return
  end
  local s, e = row, row
  while s > 1 and not lines[s - 1]:match("^%s*$") do
    s = s - 1
  end
  while e < #lines and not lines[e + 1]:match("^%s*$") do
    e = e + 1
  end
  return s, e
end

local function worth_rendering(run)
  for _, l in ipairs(run) do
    if l:find("$", 1, true) or l:find("\\%a") or l:match("^%s*[%-%*%+]%s") or l:match("^%s*%d+[%.%)]%s") then
      return true
    end
  end
  return false
end

-- Everything renderable that overlaps [first, last]:
-- { {s=, e=, kind="latex"|"md"}, ... } sorted by start line
local function collect_targets(masked, first, last, latex_only)
  local blocks = collect_latex_blocks(masked)
  table.sort(blocks, function(a, b)
    if a.s ~= b.s then
      return a.s < b.s
    end
    return a.e > b.e
  end)

  local targets, covered, cur_e = {}, {}, 0
  for _, r in ipairs(blocks) do
    if r.s > cur_e then -- outermost, non-overlapping only
      table.insert(targets, { s = r.s, e = r.e, kind = "latex" })
      for i = r.s, r.e do
        covered[i] = true
      end
      cur_e = r.e
    end
  end

  -- remaining prose: runs of non-blank, uncovered lines
  local i, n = 1, #masked
  while not latex_only and i <= n do
    if covered[i] or masked[i]:match("^%s*$") then
      i = i + 1
    else
      local j = i
      while j + 1 <= n and not covered[j + 1] and not masked[j + 1]:match("^%s*$") do
        j = j + 1
      end
      if worth_rendering(vim.list_slice(masked, i, j)) then
        table.insert(targets, { s = i, e = j, kind = "md" })
      end
      i = j + 1
    end
  end

  -- inline math ($...$, \(...\)) outside the blocks above: one image per line
  if latex_only then
    for row = 1, n do
      if not covered[row] then
        local ms = inline_math_in(masked[row])
        if #ms > 0 then
          table.insert(targets, {
            s = row,
            e = row,
            kind = "inline",
            texts = vim.tbl_map(function(m)
              return m.text
            end, ms),
          })
        end
      end
    end
  end

  table.sort(targets, function(a, b)
    return a.s < b.s
  end)
  return vim.tbl_filter(function(t)
    return t.e >= first and t.s <= last
  end, targets)
end

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------

-- Echo to the cmdline; optionally clear it again after `ms` (only if no newer
-- message replaced it, and never while you're typing a command).
local msg_token = 0
local function say(msg, hl, ms)
  msg_token = msg_token + 1
  local token = msg_token
  vim.api.nvim_echo({ { msg, hl or "Normal" } }, false, {})
  if ms then
    vim.defer_fn(function()
      if token == msg_token and vim.fn.mode() ~= "c" then
        vim.cmd("echo ''")
        vim.cmd("redraw")
      end
    end, ms)
  end
end

local function notify_err(msg)
  vim.schedule(function()
    vim.notify(msg, vim.log.levels.ERROR)
  end)
end

-- report a failure: batch callers aggregate via opts.on_done, singles notify
local function fail(opts, msg)
  if opts and opts.on_done then
    opts.on_done(false)
  else
    notify_err(msg)
  end
end

local function strip_floats(lines)
  return vim.tbl_filter(function(l)
    return not (
      l:find("\\begin{table", 1, true)
      or l:find("\\end{table", 1, true)
      or l:find("\\centering", 1, true)
      or l:find("\\caption", 1, true)
      or l:find("\\label", 1, true)
    )
  end, lines)
end

local function get_engine()
  if vim.fn.executable("pdftoppm") ~= 1 then
    return nil, "pdftoppm not found (brew install poppler)"
  end
  if vim.fn.executable("tectonic") == 1 then
    return function(dir, tex)
      return { "tectonic", "-o", dir, tex }
    end
  elseif vim.fn.executable("pdflatex") == 1 then
    return function(dir, tex)
      return { "pdflatex", "-interaction=nonstopmode", "-halt-on-error", "-output-directory", dir, tex }
    end
  end
  return nil, "Need tectonic or pdflatex in PATH"
end

-- simple job queue so ta/ts don't spawn dozens of compiles at once
local queue, running = {}, 0
local pump
local function enqueue(job)
  table.insert(queue, job)
  pump()
end
pump = function()
  while running < cfg.jobs and #queue > 0 do
    local job = table.remove(queue, 1)
    running = running + 1
    job(function()
      running = running - 1
      vim.schedule(pump)
    end)
  end
end

-- Colours come from the active colorscheme unless overridden in cfg.
local function hl_hex(name, attr)
  local ok, h = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  local v = ok and h and h[attr] or nil
  return v and ("%06X"):format(v) or nil
end

local function palette()
  if cfg.theme == "paper" then
    return { fg = "000000", bg = "FFFFFF" }
  end
  return {
    fg = cfg.fg or hl_hex("Normal", "fg") or "CDD6F4",
    bg = cfg.bg or hl_hex("Normal", "bg") or "1E1E2E",
  }
end

-- Must be called from the main loop. `body` = LaTeX lines, `row` = last
-- buffer line of the snippet (image is drawn beneath it).
-- opts.on_done(ok) is used by batch callers.
local function render(buf, win, row, body, opts)
  local n = request_n
  local engine, err = get_engine()
  if not engine then
    if opts and opts.on_done then
      return opts.on_done(false)
    end
    return vim.notify(err, vim.log.levels.ERROR)
  end

  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local tex = dir .. "/snip.tex"
  local pal = palette()
  local magick = vim.fn.executable("magick") == 1
  local doc = {
    "\\documentclass[preview,border=0pt]{standalone}",
    "\\usepackage{" .. cfg.packages .. "}",
    ("\\definecolor{pvfg}{HTML}{%s}"):format(pal.fg),
    ("\\definecolor{pvbg}{HTML}{%s}"):format(pal.bg),
    "\\pagecolor{pvbg}",
    ("\\setlength{\\fboxsep}{%s}"):format(cfg.pad),
    "\\providecommand{\\tightlist}{\\setlength{\\itemsep}{0pt}\\setlength{\\parskip}{0pt}}",
    "\\newsavebox{\\pvbox}",
    "\\begin{document}",
    -- lrbox (not \fcolorbox{...}{body}) so blank lines in the body are fine
    "\\begin{lrbox}{\\pvbox}%",
    ("\\begin{varwidth}{%s}%%"):format(cfg.width),
    "\\color{pvfg}",
  }
  vim.list_extend(doc, body)
  vim.list_extend(doc, {
    "\\end{varwidth}%",
    "\\end{lrbox}%",
    "\\colorbox{pvbg}{\\usebox{\\pvbox}}",
    "\\end{document}",
  })
  vim.fn.writefile(doc, tex)

  enqueue(function(done)
    vim.system(engine(dir, tex), { text = true }, function(r1)
      if r1.code ~= 0 then
        done()
        return fail(opts, "LaTeX failed:\n" .. (r1.stdout or "") .. (r1.stderr or ""))
      end
      vim.system(
        { "pdftoppm", "-png", "-r", tostring(cfg.dpi), "-singlefile", dir .. "/snip.pdf", dir .. "/snip" },
        {},
        function(r2)
          done()
          if r2.code ~= 0 then
            return fail(opts, "pdftoppm failed")
          end
          local function show()
            vim.schedule(function()
              local ok_img = false
              if vim.api.nvim_win_is_valid(win) and vim.api.nvim_buf_is_valid(buf) then
                local ok, image = pcall(require, "image")
                if ok then
                  local y = row + cfg.y_offset
                  -- drop a stale preview on this row first so its padding isn't measured
                  previews[buf] = previews[buf] or {}
                  if previews[buf][row] then
                    pcall(function()
                      previews[buf][row]:clear()
                    end)
                    previews[buf][row] = nil
                  end
                  -- The anchor line may wrap. image.nvim anchors on the line's first
                  -- screen row but the padding sits after ALL its wrapped rows, so push
                  -- the image down by the number of wrapped continuation rows.
                  local extra = 0
                  local okh, h = pcall(vim.api.nvim_win_text_height, win, { start_row = y, end_row = y })
                  if okh and h then
                    extra = math.max((h.all - (h.fill or 0)) - 1, 0)
                  end
                  local img = image.from_file(dir .. "/snip.png", {
                    window = win,
                    buffer = buf,
                    x = 0,
                    y = y,
                    with_virtual_padding = true,
                    render_offset_top = extra,
                  })
                  if img then
                    img:render()
                    previews[buf][row] = img
                    ok_img = true
                    last_dir = dir
                    -- only arm Esc if no key was pressed since the request
                    if n == key_count then
                      active = active or {}
                      table.insert(active, { buf = buf, row = row })
                    end
                  end
                end
              end
              if opts and opts.on_done then
                opts.on_done(ok_img)
              elseif ok_img then
                say("✓ Preview rendered", "DiagnosticOk", cfg.msg_ms)
              end
            end)
          end
          -- Trim the anti-aliased 2px edge (where the crop blends with the white
          -- page) and add back a solid background-coloured margin.
          if magick then
            local png = dir .. "/snip.png"
            vim.system(
              { "magick", png, "-shave", "2x2", "-bordercolor", "#" .. pal.bg, "-border", "2x2", png },
              {},
              function()
                show()
              end
            )
          else
            show()
          end
        end
      )
    end)
  end)
end

-- Convert markdown lines to LaTeX with pandoc, then render.
local function render_markdown(buf, win, row, lines, opts)
  if vim.fn.executable("pandoc") ~= 1 then
    if opts and opts.on_done then
      return opts.on_done(false)
    end
    return vim.notify("pandoc not found (brew install pandoc)", vim.log.levels.ERROR)
  end
  vim.system(
    { "pandoc", "-f", "markdown", "-t", "latex", "--wrap=none" },
    { text = true, stdin = table.concat(lines, "\n") },
    function(r)
      if r.code ~= 0 then
        return fail(opts, "pandoc failed:\n" .. (r.stderr or ""))
      end
      vim.schedule(function()
        render(buf, win, row, vim.split(r.stdout or "", "\n"), opts)
      end)
    end
  )
end

---------------------------------------------------------------------------
-- Entry points
---------------------------------------------------------------------------

local function ctx()
  return vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
end

local function visual_range()
  local s, e = vim.fn.line("v"), vim.fn.line(".")
  if s > e then
    s, e = e, s
  end
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  return s, e
end

local function preview_auto()
  request_n = key_count
  local buf, win = ctx()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local masked = mask_code(lines)
  local cur = vim.api.nvim_win_get_cursor(win)
  local row, col = cur[1], cur[2]

  local s, e = find_latex_block(masked, row)
  if s then
    return render(buf, win, e, strip_floats(vim.list_slice(lines, s, e)))
  end

  local inline = find_inline_math(masked[row], col)
  if inline then
    return render(buf, win, row, { inline })
  end

  s, e = find_paragraph(masked, row)
  if not s then
    return vim.notify("Nothing to preview under cursor", vim.log.levels.WARN)
  end
  local para = vim.list_slice(lines, s, e)
  if vim.fn.executable("pandoc") == 1 then
    render_markdown(buf, win, e, para)
  else
    render(buf, win, e, strip_floats(para))
  end
end

local function preview_markdown(s, e)
  request_n = key_count
  local buf, win = ctx()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if not s then
    s, e = find_paragraph(mask_code(lines), vim.api.nvim_win_get_cursor(win)[1])
  end
  if not s then
    return vim.notify("No paragraph under cursor", vim.log.levels.WARN)
  end
  render_markdown(buf, win, e, vim.list_slice(lines, s, e))
end

local function preview_raw(s, e)
  request_n = key_count
  local buf, win = ctx()
  local lines = vim.api.nvim_buf_get_lines(buf, s - 1, e, false)
  render(buf, win, e, strip_floats(lines))
end

-- Render everything renderable overlapping [first, last] (nil = whole buffer)
local function preview_many(first, last, latex_only)
  request_n = key_count
  local buf, win = ctx()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  first, last = first or 1, last or #lines

  local engine, err = get_engine()
  if not engine then
    return vim.notify(err, vim.log.levels.ERROR)
  end

  local targets = collect_targets(mask_code(lines), first, last, latex_only)
  if #targets == 0 then
    return vim.notify("Nothing to preview", vim.log.levels.WARN)
  end

  clear_range(buf, first, last)
  say(("Rendering %d preview(s)…"):format(#targets), "Comment")

  local has_pandoc = vim.fn.executable("pandoc") == 1
  local pending, failed, total = #targets, 0, #targets
  local opts = {
    on_done = function(ok)
      if not ok then
        failed = failed + 1
      end
      pending = pending - 1
      if pending == 0 then
        vim.schedule(function()
          if failed > 0 then
            vim.notify(
              ("%d of %d previews failed (run <leader>rp on one to see the error)"):format(failed, total),
              vim.log.levels.WARN
            )
          else
            say(("✓ Rendered %d preview(s)"):format(total), "DiagnosticOk", cfg.msg_ms)
          end
        end)
      end
    end,
  }

  for _, t in ipairs(targets) do
    local chunk = vim.list_slice(lines, t.s, t.e)
    if t.kind == "latex" then
      render(buf, win, t.e, strip_floats(chunk), opts)
    elseif t.kind == "inline" then
      -- all inline math on the line, side by side
      render(buf, win, t.e, { table.concat(t.texts, " \\quad ") }, opts)
    elseif has_pandoc then
      render_markdown(buf, win, t.e, chunk, opts)
    else
      render(buf, win, t.e, strip_floats(chunk), opts)
    end
  end
end

---------------------------------------------------------------------------
-- Repeat, watch, and settings
---------------------------------------------------------------------------

local last_by_buf = {} -- bufnr -> the last render action run in that buffer
local watching = {} -- bufnr -> augroup id while "re-render on save" is on

-- Run a render action and remember it so it can be repeated (<leader>rr),
-- re-run after a settings change, or re-run on save (<leader>rw).
local function run(action)
  last_by_buf[vim.api.nvim_get_current_buf()] = action
  action()
end

local function repeat_last(quiet)
  local action = last_by_buf[vim.api.nvim_get_current_buf()]
  if action then
    action()
  elseif not quiet then
    vim.notify("No previous preview in this buffer", vim.log.levels.WARN)
  end
end

local function toggle_watch()
  local buf = vim.api.nvim_get_current_buf()
  if watching[buf] then
    vim.api.nvim_del_augroup_by_id(watching[buf])
    watching[buf] = nil
    return say("Re-render on save: off", "Comment", cfg.msg_ms)
  end
  watching[buf] = vim.api.nvim_create_augroup("TexPreviewWatch" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = watching[buf],
    buffer = buf,
    callback = function()
      vim.schedule(function()
        if vim.api.nvim_get_current_buf() == buf then
          repeat_last(true)
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = watching[buf],
    buffer = buf,
    callback = function()
      watching[buf] = nil
    end,
  })
  say("Re-render on save: on (repeats your last preview command)", "DiagnosticOk", cfg.msg_ms)
end

local function rescale(factor)
  cfg.dpi = math.max(50, math.min(600, math.floor(cfg.dpi * factor + 0.5)))
  say(("Preview size: %d dpi"):format(cfg.dpi), "Comment", cfg.msg_ms)
  repeat_last(true)
end

local function toggle_theme()
  cfg.theme = cfg.theme == "paper" and "colorscheme" or "paper"
  say("Preview colours: " .. cfg.theme, "Comment", cfg.msg_ms)
  repeat_last(true)
end

-- Clear only the preview(s) belonging to the block / paragraph under the cursor
local function clear_at_cursor()
  local buf, win = ctx()
  local masked = mask_code(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  local row = vim.api.nvim_win_get_cursor(win)[1]
  local s, e = find_latex_block(masked, row)
  if not s then
    s, e = find_paragraph(masked, row)
  end
  clear_range(buf, s or row, e or row)
end

local function with_last(fn)
  if not last_dir or vim.fn.isdirectory(last_dir) == 0 then
    return vim.notify("Nothing rendered yet", vim.log.levels.WARN)
  end
  fn(last_dir)
end

-- "#rrggbb" / "rrggbb" -> "RRGGBB"; "auto" -> false (= follow the colorscheme)
local function parse_colour(v)
  if v == "auto" then
    return false
  end
  local hex = v:match("^#?(%x%x%x%x%x%x)$")
  return hex and hex:upper() or nil
end

-- :TexPreviewSet {option} {value}, e.g. `:TexPreviewSet width 600pt`
local settable = {
  dpi = tonumber,
  jobs = tonumber,
  y_offset = tonumber,
  width = tostring,
  pad = tostring,
  packages = tostring,
  theme = function(v)
    return (v == "paper" or v == "colorscheme") and v or nil
  end,
  fg = parse_colour,
  bg = parse_colour,
}

vim.api.nvim_create_user_command("TexPreviewSet", function(args)
  local key, value = args.fargs[1], args.fargs[2]
  if not key then
    local cur = {}
    for k in vim.spairs(settable) do
      cur[#cur + 1] = ("%s = %s"):format(k, tostring(cfg[k] or "auto"))
    end
    return vim.notify("TexPreview settings:\n" .. table.concat(cur, "\n"))
  end
  local parse = settable[key]
  local parsed = parse and value and parse(value)
  if parsed == nil then
    return vim.notify(("TexPreviewSet: invalid option or value: %s %s"):format(key, value or ""), vim.log.levels.ERROR)
  end
  cfg[key] = parsed or nil -- `false` (from "auto") resets fg/bg to the colorscheme
  say(("TexPreview: %s = %s"):format(key, tostring(cfg[key] or "auto")), "Comment", cfg.msg_ms)
  repeat_last(true)
end, {
  nargs = "*",
  desc = "Show or change LaTeX/markdown preview settings",
  complete = function(arglead, line)
    local words = vim.split(line, "%s+", { trimempty = true })
    local done = #words - (arglead == "" and 0 or 1) -- words before the one being typed
    local choices = {}
    if done == 1 then
      choices = vim.tbl_keys(settable)
    elseif done == 2 and words[2] == "theme" then
      choices = { "colorscheme", "paper" }
    elseif done == 2 and (words[2] == "fg" or words[2] == "bg") then
      choices = { "auto" }
    end
    return vim.tbl_filter(function(c)
      return c:find(arglead, 1, true) == 1
    end, choices)
  end,
})

---------------------------------------------------------------------------
-- Keymaps
---------------------------------------------------------------------------

local function map(mode, lhs, rhs, desc)
  vim.keymap.set(mode, lhs, rhs, { desc = desc })
end

local function screen()
  return vim.fn.line("w0"), vim.fn.line("w$")
end

-- Render
map("n", "<leader>rp", function()
  run(preview_auto)
end, "Preview under cursor")
map("n", "<leader>rm", function()
  run(function()
    preview_markdown()
  end)
end, "Preview paragraph as markdown")
map("n", "<leader>ra", function()
  run(function()
    preview_many()
  end)
end, "Preview everything in buffer")
map("n", "<leader>rs", function()
  run(function()
    preview_many(screen())
  end)
end, "Preview everything on screen")
map("n", "<leader>rla", function()
  run(function()
    preview_many(nil, nil, true)
  end)
end, "Preview all LaTeX in buffer")
map("n", "<leader>rls", function()
  run(function()
    local first, last = screen()
    preview_many(first, last, true)
  end)
end, "Preview LaTeX on screen")
map("v", "<leader>rp", function()
  local s, e = visual_range()
  run(function()
    preview_raw(s, e)
  end)
end, "Preview selection as LaTeX")
map("v", "<leader>rm", function()
  local s, e = visual_range()
  run(function()
    preview_markdown(s, e)
  end)
end, "Preview selection as markdown")

-- Repeat / watch / clear
map("n", "<leader>rr", function()
  repeat_last()
end, "Repeat last preview")
map("n", "<leader>rw", toggle_watch, "Toggle re-render on save")
map("n", "<leader>rx", clear_at_cursor, "Clear preview under cursor")
map("n", "<leader>rc", function()
  clear(vim.api.nvim_get_current_buf())
  say("✓ Previews cleared", "DiagnosticOk", cfg.msg_ms)
end, "Clear all previews")

-- Look
map("n", "<leader>r+", function()
  rescale(1.25)
end, "Bigger previews")
map("n", "<leader>r-", function()
  rescale(0.8)
end, "Smaller previews")
map("n", "<leader>rt", toggle_theme, "Toggle colours (theme / paper)")

-- Inspect the last render
map("n", "<leader>ro", function()
  with_last(function(dir)
    vim.ui.open(dir .. "/snip.pdf")
  end)
end, "Open last preview as PDF")
map("n", "<leader>re", function()
  with_last(function(dir)
    vim.cmd("split " .. vim.fn.fnameescape(dir .. "/snip.tex"))
  end)
end, "Edit last generated .tex")
