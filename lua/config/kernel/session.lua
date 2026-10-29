-- Kernel registry: one R kernel shared by every buffer (scripts and
-- notebooks), and one Python kernel per project venv (lua/config/python-env.lua).
-- Everything that runs code goes through M.execute, so observers (the
-- console) see it all.

local client = require("config.kernel.client")

local M = {}

local kernels = {} -- id -> { id, lang, name, state, waiting }
local observers = {} -- { exec = fn, event = fn, change = fn }

local function notify_change(k)
  for _, o in ipairs(observers) do
    if o.change then
      o.change(k)
    end
  end
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
    vim.notify("No R binary on PATH", vim.log.levels.ERROR)
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

-- Kernelspec name for `lang` in `buf`, or nil (after telling the user why).
local function kernel_name(lang, buf)
  if lang == "r" then
    fix_ir_kernelspec()
    if not require("config.python-env").kernelspecs().ir then
      vim.notify(
        'No "ir" Jupyter kernel. In R: install.packages("IRkernel"); IRkernel::installspec()',
        vim.log.levels.ERROR
      )
      return nil
    end
    return "ir"
  elseif lang == "python" then
    local name = require("config.python-env").kernel(buf)
    if not name then
      vim.notify("No Python kernel found for this buffer", vim.log.levels.ERROR)
    end
    return name
  end
  vim.notify(("No kernel for %s code"):format(lang ~= "" and lang or "this"), vim.log.levels.WARN)
end

local LABEL = { r = "R", python = "Python" }

-- The running (or starting) kernel for `lang` in `buf`, without starting one.
-- A Python kernel counts once M.ensure picked it for the buffer.
function M.find(lang, buf)
  if lang == "r" then
    return kernels.r
  end
  local name = vim.b[buf ~= 0 and buf or vim.api.nvim_get_current_buf()].kernel_python
  return name and kernels["py:" .. name]
end

-- Start (if needed) the kernel for `lang` in `buf`. `on_ready(k)` runs once it
-- accepts code; returns the kernel table (possibly still starting) or nil.
function M.ensure(lang, buf, on_ready)
  local existing = lang == "r" and kernels.r or M.find(lang, buf)
  if not existing and lang ~= "r" then
    local name = kernel_name(lang, buf)
    if not name then
      return nil
    end
    vim.b[buf ~= 0 and buf or vim.api.nvim_get_current_buf()].kernel_python = name
    existing = kernels["py:" .. name]
    if not existing then
      return M.start(lang, name, on_ready)
    end
  end
  if existing then
    if existing.state == "starting" then
      table.insert(existing.waiting, on_ready)
    elseif on_ready then
      on_ready(existing)
    end
    return existing
  end
  local name = kernel_name(lang, buf)
  return name and M.start(lang, name, on_ready)
end

function M.start(lang, name, on_ready)
  local id = lang == "r" and "r" or ("py:" .. name)
  local k = { id = id, lang = lang, name = name, label = LABEL[lang] or lang, state = "starting", waiting = {} }
  if on_ready then
    table.insert(k.waiting, on_ready)
  end
  kernels[id] = k
  client.send({ op = "start", id = id, kernel_name = name, cwd = vim.fn.getcwd() })
  notify_change(k)
  return k
end

client.on_event(function(ev)
  if ev.ev == "bridge_exit" then
    for id, k in pairs(kernels) do
      k.state = "dead"
      kernels[id] = nil
      notify_change(k)
    end
    return
  end
  local k = kernels[ev.id]
  if not k then
    return
  end
  local function ready()
    k.state = "idle"
    local waiting = k.waiting
    k.waiting = {}
    for _, fn in ipairs(waiting) do
      fn(k)
    end
  end
  if ev.ev == "started" then
    ready()
  elseif ev.ev == "start_failed" then
    kernels[k.id] = nil
    k.state = "dead"
    vim.notify(("Could not start the %s kernel:\n%s"):format(k.label, ev.error or ""), vim.log.levels.ERROR)
  elseif ev.ev == "status" then
    if k.state ~= "starting" then
      k.state = ev.state == "busy" and "busy" or "idle"
    end
  elseif ev.ev == "died" then
    kernels[k.id] = nil
    k.state = "dead"
    vim.notify(("The %s kernel died"):format(k.label), vim.log.levels.ERROR)
  elseif ev.ev == "restarted" then
    ready()
    vim.notify(("%s kernel restarted"):format(k.label))
  end
  notify_change(k)
end)

-- Run `code` in kernel `k`. opts:
--   echo      show it in the console (default true)
--   history   count it in the kernel's history (default true)
--   on_event  fn(event) for its output (stream, result, display, error,
--             clear, input_request) and the final done
--   source    who sent it ("console", "chunk", ...), for observers
function M.execute(k, code, opts)
  opts = opts or {}
  if opts.echo == nil then
    opts.echo = true
  end
  local function run()
    local req
    req = client.request({ op = "execute", id = k.id, code = code, history = opts.history ~= false }, function(ev)
      for _, o in ipairs(observers) do
        if o.event then
          o.event(k, ev, opts, req)
        end
      end
      if opts.on_event then
        opts.on_event(ev)
      end
    end)
    for _, o in ipairs(observers) do
      if o.exec then
        o.exec(k, code, opts, req)
      end
    end
  end
  if k.state == "starting" then
    table.insert(k.waiting, run)
  else
    run()
  end
end

-- Run `code` without echo or history and collect its text output.
-- `cb(text, ok, err)` gets everything printed (stdout + results).
function M.eval(k, code, cb)
  local out, err = {}, nil
  M.execute(k, code, {
    echo = false,
    history = false,
    on_event = function(ev)
      if ev.ev == "stream" then
        table.insert(out, ev.text or "")
      elseif (ev.ev == "result" or ev.ev == "display") and ev.text then
        table.insert(out, ev.text .. "\n")
      elseif ev.ev == "error" then
        err = ev.evalue
      elseif ev.ev == "done" then
        cb(table.concat(out), ev.ok and not err, err or ev.evalue)
      end
    end,
  })
end

function M.complete(k, code, cursor, cb)
  client.request({ op = "complete", id = k.id, code = code, cursor = cursor }, cb)
end

function M.is_complete(k, code, cb)
  client.request({ op = "is_complete", id = k.id, code = code }, cb)
end

function M.input(k, value)
  client.send({ op = "input_reply", id = k.id, value = value })
end

function M.interrupt(k)
  client.send({ op = "interrupt", id = k.id })
end

function M.restart(k)
  k.state = "starting"
  notify_change(k)
  client.send({ op = "restart", id = k.id })
end

function M.shutdown(k)
  client.send({ op = "shutdown", id = k.id })
  kernels[k.id] = nil
  k.state = "dead"
  notify_change(k)
end

function M.list()
  return vim.tbl_values(kernels)
end

-- `o` = { exec = fn(k, code, opts, req), event = fn(k, ev, opts, req),
--         change = fn(k) }
function M.observe(o)
  table.insert(observers, o)
end

return M
