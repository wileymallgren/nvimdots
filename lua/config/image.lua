-- Images in the editor with the kitty graphics protocol's Unicode
-- placeholders (kitty, Ghostty). The image is sent to the terminal once,
-- and the cells it covers are filled with placeholder characters (U+10EEEE
-- plus diacritics giving the cell's row and column, coloured with the image
-- id). Neovim draws those characters itself, as virtual text, so the image
-- behaves like text: floats (which-key, completion menus) cover it, it
-- scrolls and is clipped by the window, and redraws keep it.
--
--   local img = require("config.image").new(path, { max_cols = 80, max_rows = 12 })
--   if img then
--     -- img.cols x img.rows cells: put img:virt_lines(2) in an extmark's
--     -- virt_lines, or img:chunks(r) on row r as overlay virt_text
--     img:delete() -- when it isn't shown any more
--   end
--
-- Images stay in the terminal for a while after delete(): new() of the same
-- file at the same size gives the same image back without sending it again
-- (moving back to a chunk, re-rendering). The oldest hidden ones are freed
-- in the terminal once hidden images take more than HIDDEN_BYTES there,
-- and a moment after their cells are gone, so the screen never shows cells
-- of an image already freed.
--
-- set_dim(ns, color, alpha) (lua/config/dim-behind-float.lua) gives every
-- image a dimmed copy: in highlight namespace `ns` its placeholders show
-- that copy, so a plot dims with the text of the window it is in.
--
-- new() returns nil when the terminal can't show images or the file isn't a
-- PNG; callers then show something else.
-- Used by lua/config/kernel/ (plots) and lua/config/tex-preview.lua.

local M = {}

local PLACEHOLDER = "\u{10EEEE}"
-- Row / column numbers: kitty's rowcolumn-diacritics.txt (the list from
-- image.nvim, MIT, Copyright 2023 Andrei Neculaesei)
-- stylua: ignore
local DIACRITICS = {
  0x305, 0x30D, 0x30E, 0x310, 0x312, 0x33D, 0x33E, 0x33F, 0x346, 0x34A, 0x34B, 0x34C, 0x350,
  0x351, 0x352, 0x357, 0x35B, 0x363, 0x364, 0x365, 0x366, 0x367, 0x368, 0x369, 0x36A, 0x36B,
  0x36C, 0x36D, 0x36E, 0x36F, 0x483, 0x484, 0x485, 0x486, 0x487, 0x592, 0x593, 0x594, 0x595,
  0x597, 0x598, 0x599, 0x59C, 0x59D, 0x59E, 0x59F, 0x5A0, 0x5A1, 0x5A8, 0x5A9, 0x5AB, 0x5AC,
  0x5AF, 0x5C4, 0x610, 0x611, 0x612, 0x613, 0x614, 0x615, 0x616, 0x617, 0x657, 0x658, 0x659,
  0x65A, 0x65B, 0x65D, 0x65E, 0x6D6, 0x6D7, 0x6D8, 0x6D9, 0x6DA, 0x6DB, 0x6DC, 0x6DF, 0x6E0,
  0x6E1, 0x6E2, 0x6E4, 0x6E7, 0x6E8, 0x6EB, 0x6EC, 0x730, 0x732, 0x733, 0x735, 0x736, 0x73A,
  0x73D, 0x73F, 0x740, 0x741, 0x743, 0x745, 0x747, 0x749, 0x74A, 0x7EB, 0x7EC, 0x7ED, 0x7EE,
  0x7EF, 0x7F0, 0x7F1, 0x7F3, 0x816, 0x817, 0x818, 0x819, 0x81B, 0x81C, 0x81D, 0x81E, 0x81F,
  0x820, 0x821, 0x822, 0x823, 0x825, 0x826, 0x827, 0x829, 0x82A, 0x82B, 0x82C, 0x82D, 0x951,
  0x953, 0x954, 0xF82, 0xF83, 0xF86, 0xF87, 0x135D, 0x135E, 0x135F, 0x17DD, 0x193A, 0x1A17,
  0x1A75, 0x1A76, 0x1A77, 0x1A78, 0x1A79, 0x1A7A, 0x1A7B, 0x1A7C, 0x1B6B, 0x1B6D, 0x1B6E, 0x1B6F,
  0x1B70, 0x1B71, 0x1B72, 0x1B73, 0x1CD0, 0x1CD1, 0x1CD2, 0x1CDA, 0x1CDB, 0x1CE0, 0x1DC0, 0x1DC1,
  0x1DC3, 0x1DC4, 0x1DC5, 0x1DC6, 0x1DC7, 0x1DC8, 0x1DC9, 0x1DCB, 0x1DCC, 0x1DD1, 0x1DD2, 0x1DD3,
  0x1DD4, 0x1DD5, 0x1DD6, 0x1DD7, 0x1DD8, 0x1DD9, 0x1DDA, 0x1DDB, 0x1DDC, 0x1DDD, 0x1DDE, 0x1DDF,
  0x1DE0, 0x1DE1, 0x1DE2, 0x1DE3, 0x1DE4, 0x1DE5, 0x1DE6, 0x1DFE, 0x20D0, 0x20D1, 0x20D4, 0x20D5,
  0x20D6, 0x20D7, 0x20DB, 0x20DC, 0x20E1, 0x20E7, 0x20E9, 0x20F0, 0x2CEF, 0x2CF0, 0x2CF1, 0x2DE0,
  0x2DE1, 0x2DE2, 0x2DE3, 0x2DE4, 0x2DE5, 0x2DE6, 0x2DE7, 0x2DE8, 0x2DE9, 0x2DEA, 0x2DEB, 0x2DEC,
  0x2DED, 0x2DEE, 0x2DEF, 0x2DF0, 0x2DF1, 0x2DF2, 0x2DF3, 0x2DF4, 0x2DF5, 0x2DF6, 0x2DF7, 0x2DF8,
  0x2DF9, 0x2DFA, 0x2DFB, 0x2DFC, 0x2DFD, 0x2DFE, 0x2DFF, 0xA66F, 0xA67C, 0xA67D, 0xA6F0, 0xA6F1,
  0xA8E0, 0xA8E1, 0xA8E2, 0xA8E3, 0xA8E4, 0xA8E5, 0xA8E6, 0xA8E7, 0xA8E8, 0xA8E9, 0xA8EA, 0xA8EB,
  0xA8EC, 0xA8ED, 0xA8EE, 0xA8EF, 0xA8F0, 0xA8F1, 0xAAB0, 0xAAB2, 0xAAB3, 0xAAB7, 0xAAB8, 0xAABE,
  0xAABF, 0xAAC1, 0xFE20, 0xFE21, 0xFE22, 0xFE23, 0xFE24, 0xFE25, 0xFE26, 0x10A0F, 0x10A38,
  0x1D185, 0x1D186, 0x1D187, 0x1D188, 0x1D189, 0x1D1AA, 0x1D1AB, 0x1D1AC, 0x1D1AD, 0x1D242,
  0x1D243, 0x1D244
}
for i, cp in ipairs(DIACRITICS) do
  DIACRITICS[i] = vim.fn.nr2char(cp)
end
local MAX_CELLS = #DIACRITICS -- rows and columns an image can span

local live = {} -- id -> image, every image the terminal holds
local cache = {} -- file:size key -> image (shown or hidden)
local hidden = {} -- images nobody shows, oldest first
-- Terminal memory hidden images may keep (decoded: 4 bytes a pixel, twice
-- with the dimmed copy; an R plot ~2.6 MB). Ghostty allows 320 MB in all.
local HIDDEN_BYTES = 96 * 1024 * 1024
local FREE_DELAY_MS = 300
local dim -- set_dim(): { ns, color, alpha, key }
-- Ids are 24-bit (the id is the text colour), and differ between Neovims
-- in one terminal (nested in :terminal) so they don't replace each other's
local next_id = 0x100000 + (vim.uv.os_getpid() * 7919 + math.floor(vim.uv.hrtime() / 1e6)) % 0xC00000

local function take_id()
  local id = next_id
  next_id = next_id >= 0xFFFFFE and 0x100000 or next_id + 1
  return id
end

local function send(data)
  pcall(vim.api.nvim_ui_send, data)
end

local function apc(control, payload)
  return "\27_G" .. control .. (payload and (";" .. payload) or "") .. "\27\\"
end

-- Free images in the terminal a moment from now: by then the cells showing
-- them were redrawn with what replaced them, so nothing blank is drawn.
local function free_later(ids)
  vim.defer_fn(function()
    for _, id in ipairs(ids) do
      send(apc(("a=d,d=I,q=2,i=%d"):format(id)))
    end
  end, FREE_DELAY_MS)
end

-- Can the terminal show images this way? (kitty and Ghostty; a UI must be
-- attached to a tty: none in headless runs.)
function M.available()
  local term, prog = vim.env.TERM or "", (vim.env.TERM_PROGRAM or ""):lower()
  local ok = term == "xterm-kitty"
    or term == "xterm-ghostty"
    or prog == "ghostty"
    or prog == "kitty"
    or vim.env.KITTY_WINDOW_ID ~= nil
  if not ok then
    return false
  end
  for _, ui in ipairs(vim.api.nvim_list_uis()) do
    if ui.stdout_tty then
      return true
    end
  end
  return false
end

-- Pixel size of a terminal cell (8 x 16 when the terminal doesn't say).
local cell
function M.cell_size()
  if cell then
    return cell[1], cell[2]
  end
  local ok, ffi = pcall(require, "ffi")
  if ok then
    pcall(
      ffi.cdef,
      "typedef struct { unsigned short row, col, xpixel, ypixel; } config_image_winsize; int ioctl(int, unsigned long, ...);"
    )
    local req = vim.fn.has("mac") == 1 and 0x40087468 or 0x5413 -- TIOCGWINSZ
    for _, fd in ipairs({ 1, 2, 0 }) do
      local sz = ffi.new("config_image_winsize")
      if ffi.C.ioctl(fd, req, sz) == 0 and sz.xpixel > 0 and sz.ypixel > 0 and sz.col > 0 and sz.row > 0 then
        cell = { sz.xpixel / sz.col, sz.ypixel / sz.row }
        return cell[1], cell[2]
      end
    end
  end
  return 8, 16 -- (not cached: the terminal may say once it has a size)
end

-- Width and height in pixels of the PNG at `path` (nil if it isn't one).
function M.png_size(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local head = f:read(24)
  f:close()
  if not head or #head < 24 or head:sub(1, 8) ~= "\137PNG\r\n\26\n" then
    return nil
  end
  local function u32(i)
    local a, b, c, d = head:byte(i, i + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
  end
  return u32(17), u32(21)
end

-- Cells (cols, rows) for an image of `pw` x `ph` pixels in at most
-- `max_cols` x `max_rows` cells, keeping its shape. Smaller images keep
-- their size unless `grow`.
function M.fit(pw, ph, max_cols, max_rows, grow)
  local cw, ch = M.cell_size()
  local nc, nr = pw / cw, ph / ch
  local scale = math.min(max_cols / nc, max_rows / nr)
  if not grow then
    scale = math.min(scale, 1)
  end
  local cols = math.max(1, math.min(max_cols, math.floor(nc * scale + 0.5)))
  local rows = math.max(1, math.min(max_rows, math.floor(nr * scale + 0.5)))
  return cols, rows
end

local Image = {}
Image.__index = Image

local function set_hl(img)
  vim.api.nvim_set_hl(0, img.hl, { fg = img.id, nocombine = true })
end

-- Send PNG `data` as image `id` (base64 in chunks), then a virtual
-- placement of cols x rows cells for the placeholders to show.
local function transmit(id, data, cols, rows)
  local b64 = vim.base64.encode(data)
  local parts, CHUNK = {}, 4096
  for i = 1, #b64, CHUNK do
    local more = i + CHUNK <= #b64 and 1 or 0
    local control = i == 1 and ("a=t,f=100,t=d,q=2,i=%d,m=%d"):format(id, more) or ("m=%d"):format(more)
    table.insert(parts, apc(control, b64:sub(i, i + CHUNK - 1)))
  end
  table.insert(parts, apc(("a=p,U=1,q=2,i=%d,c=%d,r=%d,C=1"):format(id, cols, rows)))
  send(table.concat(parts))
end

-- In the dim namespace, show the image's dimmed copy once there is one for
-- the current dim colour (until then, the image itself).
local function apply_dim(img)
  if dim then
    local fg = img.dim_ready == dim.key and img.dim_id or img.id
    pcall(vim.api.nvim_set_hl, dim.ns, img.hl, { fg = fg, nocombine = true })
  end
end

-- Make the dimmed copy for the current dim colour (ImageMagick, in the
-- background), unless it is made or being made.
local function make_dim(img)
  if not dim or img.dim_want == dim.key or vim.fn.executable("magick") == 0 then
    return
  end
  local key, out = dim.key, vim.fn.tempname() .. ".png"
  img.dim_want = key
  local cmd = { "magick", img.path, "-fill", dim.color, "-colorize", ("%g%%"):format(dim.alpha * 100), out }
  vim.system(cmd, {}, function(r)
    vim.schedule(function()
      local f = r.code == 0 and io.open(out, "rb")
      local data = f and f:read("*a")
      if f then
        f:close()
      end
      os.remove(out)
      if not data or not live[img.id] or img.dim_want ~= key then
        return
      end
      if img.dim_id then
        free_later({ img.dim_id })
      end
      img.dim_id, img.dim_ready = take_id(), key
      transmit(img.dim_id, data, img.cols, img.rows)
      apply_dim(img)
    end)
  end)
end

-- Give images dimmed copies (blended `alpha` of the way toward `color`,
-- "#rrggbb") shown in highlight namespace `ns`. Called again whenever the
-- namespace is rebuilt; copies are only made again when the colour changes.
function M.set_dim(ns, color, alpha)
  dim = { ns = ns, color = color, alpha = alpha, key = color .. "/" .. alpha }
  for _, img in pairs(live) do
    make_dim(img)
    apply_dim(img)
  end
end

-- Show the PNG at `path` in at most opts.max_cols x opts.max_rows cells
-- (opts.grow: scale small images up to that). nil when it can't be shown.
function M.new(path, opts)
  opts = opts or {}
  if not M.available() then
    return nil
  end
  local pw, ph = M.png_size(path)
  local stat = vim.uv.fs_stat(path)
  if not pw or pw == 0 or ph == 0 or not stat then
    return nil
  end
  local max_cols = math.max(1, math.min(opts.max_cols or 80, MAX_CELLS))
  local max_rows = math.max(1, math.min(opts.max_rows or 20, MAX_CELLS))
  local cols, rows = M.fit(pw, ph, max_cols, max_rows, opts.grow)

  -- The same file (unchanged) at the same size: the image already sent
  local key = ("%s:%d:%d.%d:%dx%d"):format(path, stat.size, stat.mtime.sec, stat.mtime.nsec, cols, rows)
  local img = cache[key]
  if img then
    for i, h in ipairs(hidden) do
      if h == img then
        table.remove(hidden, i)
        break
      end
    end
    img.users = img.users + 1
    return img
  end

  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local data = f:read("*a")
  f:close()
  local id = take_id()
  img = setmetatable({
    id = id,
    key = key,
    path = path,
    cols = cols,
    rows = rows,
    users = 1,
    bytes = pw * ph * 4,
    hl = ("ConfigImage%d"):format(id),
  }, Image)
  transmit(id, data, cols, rows)
  set_hl(img)
  live[id], cache[key] = img, img
  make_dim(img)
  return img
end

-- Row `r` (0-based) of the image as virt_text chunks, after `indent` spaces.
function Image:chunks(r, indent)
  local row = DIACRITICS[r + 1]
  local cells = {}
  for c = 1, self.cols do
    cells[c] = PLACEHOLDER .. row .. DIACRITICS[c]
  end
  local res = {}
  if indent and indent > 0 then
    table.insert(res, { string.rep(" ", indent) })
  end
  table.insert(res, { table.concat(cells), self.hl })
  return res
end

-- All its rows, for an extmark's virt_lines.
function Image:virt_lines(indent)
  local lines = {}
  for r = 0, self.rows - 1 do
    lines[r + 1] = self:chunks(r, indent)
  end
  return lines
end

-- Done showing it (each new() that returned it needs one delete()). Once
-- nobody shows it, it is kept hidden for new() to give back; the oldest
-- hidden ones are freed in the terminal.
function Image:delete()
  if not live[self.id] or self.users == 0 then
    return
  end
  self.users = self.users - 1
  if self.users > 0 then
    return
  end
  table.insert(hidden, self)
  local total = 0
  for _, h in ipairs(hidden) do
    total = total + h.bytes * (h.dim_id and 2 or 1)
  end
  while total > HIDDEN_BYTES and #hidden > 1 do
    local old = table.remove(hidden, 1)
    total = total - old.bytes * (old.dim_id and 2 or 1)
    live[old.id], cache[old.key] = nil, nil
    free_later({ old.id, old.dim_id })
  end
end

local group = vim.api.nvim_create_augroup("ConfigImage", { clear = true })
-- :colorscheme clears the highlight groups that carry the image ids
vim.api.nvim_create_autocmd("ColorScheme", {
  group = group,
  callback = function()
    for _, img in pairs(live) do
      set_hl(img)
    end
  end,
})
vim.api.nvim_create_autocmd("VimResized", {
  group = group,
  callback = function()
    cell = nil -- (a font size change resizes the cells)
  end,
})
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = group,
  callback = function()
    for _, img in pairs(live) do
      send(apc(("a=d,d=I,q=2,i=%d"):format(img.id)))
      if img.dim_id then
        send(apc(("a=d,d=I,q=2,i=%d"):format(img.dim_id)))
      end
    end
  end,
})

return M
