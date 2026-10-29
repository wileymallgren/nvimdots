-- Connection to bridge.py (the process that owns the Jupyter kernels).
-- One bridge per Neovim, started on first use; requests and events are JSON
-- lines (see the bridge's docstring). Use config.kernel.session, not this.

local M = {}

local BRIDGE = vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "bridge.py")
local PYTHON = vim.fn.expand("~/.venvs/nvim/bin/python")

local proc
local partial = ""
local stderr = {}
local next_req = 0
local handlers = {} -- req -> function(event)
local listeners = {} -- function(event), for events without a req

-- Events that end a request
local FINAL = { done = true, complete = true, is_complete = true }

local function dispatch(ev)
  local h = ev.req and handlers[ev.req]
  if h then
    if FINAL[ev.ev] then
      handlers[ev.req] = nil
    end
    h(ev)
  end
  if not ev.req then
    for _, fn in ipairs(listeners) do
      fn(ev)
    end
  end
end

local function on_stdout(_, data)
  if not data then
    return
  end
  partial = partial .. data
  local lines = vim.split(partial, "\n", { plain = true })
  partial = table.remove(lines)
  vim.schedule(function()
    for _, line in ipairs(lines) do
      local ok, ev = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
      if ok and type(ev) == "table" then
        dispatch(ev)
      end
    end
  end)
end

local function on_exit(res)
  vim.schedule(function()
    proc = nil
    -- Fail what was still running, and tell the session its kernels are gone
    for req, h in pairs(handlers) do
      handlers[req] = nil
      h({ ev = "done", req = req, ok = false, ename = "BridgeExited", evalue = "" })
    end
    dispatch({ ev = "bridge_exit" })
    if res.code ~= 0 and res.signal ~= 15 then
      vim.notify(
        ("Kernel bridge exited (%d):\n%s"):format(res.code, table.concat(stderr, "\n"):sub(-2000)),
        vim.log.levels.ERROR
      )
    end
  end)
end

local function ensure()
  if proc then
    return true
  end
  if vim.fn.executable(PYTHON) ~= 1 then
    vim.notify("Kernel bridge: no " .. PYTHON .. " (needs jupyter_client)", vim.log.levels.ERROR)
    return false
  end
  stderr, partial = {}, ""
  proc = vim.system({ PYTHON, "-I", BRIDGE }, {
    stdin = true,
    stdout = on_stdout,
    stderr = function(_, data)
      if data then
        table.insert(stderr, data)
      end
    end,
  }, on_exit)
  return true
end

-- Send a request without a reply handler.
function M.send(msg)
  if ensure() then
    proc:write(vim.json.encode(msg) .. "\n")
  end
end

-- Send a request; `handler` gets each event about it, ending with a final one
-- (done / complete / is_complete). Returns the req id.
function M.request(msg, handler)
  next_req = next_req + 1
  msg.req = next_req
  handlers[next_req] = handler
  M.send(msg)
  return next_req
end

-- `fn(event)` for kernel-level events: started, start_failed, status, died,
-- restarted, bridge_exit.
function M.on_event(fn)
  table.insert(listeners, fn)
end

function M.running()
  return proc ~= nil
end

return M
