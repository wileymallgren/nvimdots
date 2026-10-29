-- Outputs of Jupyter notebooks (.ipynb, opened as markdown by jupytext.nvim,
-- see lua/plugins/jupytext.lua). When a notebook opens, the outputs saved in
-- it show under their chunks; on :w the current outputs are written into it
-- (after jupytext has written the cells). Code cells and the buffer's R /
-- Python chunks are matched in order.

local chunks = require("config.kernel.chunks")
local inline = require("config.kernel.inline")

local M = {}

local HELPER = vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "ipynb.py")
local PYTHON = vim.fn.expand("~/.venvs/nvim/bin/python")

local function code_chunks(buf)
  return vim.tbl_filter(function(c)
    return chunks.LANGS[c.lang] ~= nil
  end, chunks.find(buf))
end

local function text_of(v)
  return type(v) == "table" and table.concat(v) or v or ""
end

local function plain(s)
  return (s:gsub("\27%[[0-9;?]*[ -/]*[@-~]", ""))
end

-- nbformat outputs -> inline items (see inline.lua's collect())
local function to_items(outputs, lang)
  local items, failed = {}, false
  for _, o in ipairs(outputs) do
    if o.output_type == "stream" then
      local hl = o.name == "stderr" and "KernelOutputStderr" or nil
      table.insert(items, { kind = "stream", name = o.name, text = plain(text_of(o.text)), hl = hl })
    elseif o.output_type == "execute_result" or o.output_type == "display_data" then
      local data = o.data or {}
      local display = o.output_type == "display_data"
      if data["image/png"] then
        local path = vim.fn.tempname() .. ".png"
        local png = text_of(data["image/png"]):gsub("%s", "")
        local f = io.open(path, "wb")
        if f then
          f:write(vim.base64.decode(png))
          f:close()
        end
        table.insert(items, { kind = "image", path = path, display = display, alt = text_of(data["text/plain"]) })
      elseif data["text/plain"] then
        table.insert(items, { kind = "result", text = plain(text_of(data["text/plain"])), display = display })
      end
    elseif o.output_type == "error" then
      local tb = vim.tbl_map(plain, o.traceback or {})
      local text = lang == "r" and plain(o.evalue or "") or table.concat(tb, "\n")
      table.insert(items, {
        kind = "error",
        text = vim.trim(text),
        hl = "KernelOutputError",
        ename = o.ename,
        evalue = o.evalue,
        traceback = o.traceback,
      })
      failed = true
    end
  end
  return items, failed
end

-- inline items -> nbformat outputs
local function to_outputs(items, count)
  local outputs = {}
  for _, item in ipairs(items) do
    if item.kind == "stream" then
      table.insert(outputs, { output_type = "stream", name = item.name or "stdout", text = item.text })
    elseif item.kind == "result" or item.kind == "image" then
      local o = { metadata = vim.empty_dict(), data = { ["text/plain"] = item.alt or item.text or "" } }
      if item.kind == "image" then
        o.png_path = item.path
      end
      if item.display then
        o.output_type = "display_data"
      else
        o.output_type, o.execution_count = "execute_result", count or vim.NIL
      end
      table.insert(outputs, o)
    elseif item.kind == "error" then
      table.insert(outputs, {
        output_type = "error",
        ename = item.ename or "Error",
        evalue = item.evalue or item.text,
        traceback = item.traceback or { item.text },
      })
    end
  end
  return outputs
end

local function read(path)
  local ok, nb = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  return ok and type(nb) == "table" and nb or nil
end

function M.import(buf)
  local path = vim.api.nvim_buf_get_name(buf)
  local nb = read(path)
  if not nb then
    return
  end
  local lang = (vim.tbl_get(nb, "metadata", "kernelspec", "language") or "python"):lower()
  local cs, i = code_chunks(buf), 0
  for _, cell in ipairs(nb.cells or {}) do
    if cell.cell_type == "code" then
      i = i + 1
      local c = cs[i]
      if c and type(cell.outputs) == "table" and #cell.outputs > 0 then
        local items, failed = to_items(cell.outputs, c.lang or lang)
        local count = cell.execution_count ~= vim.NIL and cell.execution_count or nil
        inline.restore(buf, c, items, count, failed)
      end
    end
  end
end

function M.export(buf)
  if not inline.touched(buf) then
    return -- nothing ran or was cleared: jupytext kept the saved outputs
  end
  local by_index = {}
  for i, c in ipairs(code_chunks(buf)) do
    local out = inline.get(buf, c)
    if not (out and (out.status == "running" or out.status == "queued")) then
      by_index[tostring(i - 1)] = {
        execution_count = out and out.count or vim.NIL,
        outputs = out and to_outputs(out.items, out.count) or {},
      }
    end
  end
  local res = vim
    .system({ PYTHON, "-I", HELPER, vim.api.nvim_buf_get_name(buf) }, { stdin = vim.json.encode(by_index), text = true })
    :wait()
  if res.code ~= 0 then
    vim.notify("Saving notebook outputs failed:\n" .. (res.stderr or ""), vim.log.levels.ERROR)
  end
end

function M.setup()
  local group = vim.api.nvim_create_augroup("KernelIpynb", { clear = true })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    pattern = "*.ipynb",
    callback = function(ev)
      if not vim.b[ev.buf].kernel_outputs_loaded then
        vim.b[ev.buf].kernel_outputs_loaded = true
        M.import(ev.buf)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = "*.ipynb",
    callback = function(ev)
      M.export(ev.buf)
    end,
  })
end

return M
