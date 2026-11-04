-- The signature of the call the cursor is in, from the language server's
-- signature help, for completion (lua/plugins/completion.lua):
--
--   cor(x, y = NULL, use = "everything", method = c("pearson", "kendall", "spearman"))
--   -> { { name = "x", kind = "positional" },
--        { name = "y", default = "NULL", kind = "positional" }, ... }
--
--  * M.fetch(buf, cb): ask the server (once per call, then cached), cb(sig)
--    within 200 ms; sig is nil when there's no signature (yet).
--  * M.cached(): the signature already known for the call under the cursor.
--  * M.filled(sig, args): argument names already given in the call, by name
--    or by position: read.csv(f, | has filled `file`.
--
-- Params are { name, default?, kind }, kind "positional" (can be given by
-- position), "varargs" (R `...`, Python `*args` / bare `*`) or "keyword"
-- (only by name: after the varargs, or Python `**kwargs`).

local context = require("config.cmp-context")

local M = {}

local TIMEOUT_MS = 200

-- call key -> signature (only found ones are kept)
local cache, cache_size = {}, 0
local pending = {} -- call key -> callbacks waiting for the answer

local function key(buf, call)
  return ("%d:%d:%d:%s"):format(buf, call.row, call.col, call.name)
end

-- `s` with the inside of quoted strings replaced by `_` (same length), so
-- their commas, brackets and `=` don't count
local function mask_strings(s)
  local out, quote, escaped = {}, nil, false
  for i = 1, #s do
    local ch = s:sub(i, i)
    if quote then
      if escaped then
        escaped = false
      elseif ch == "\\" then
        escaped = true
      elseif ch == quote then
        quote = nil
      end
      out[i] = quote and "_" or ch
    else
      quote = (ch == '"' or ch == "'") and ch or nil
      out[i] = ch
    end
  end
  return table.concat(out)
end

-- Pieces of the argument list in `label` ("read.csv(file, header = TRUE)"
-- -> "file", "header = TRUE"), splitting at top-level commas
local function split_label(label)
  local masked = mask_strings(label)
  local open = masked:find("(", 1, true)
  if not open then
    return {}
  end
  local pieces, depth, start = {}, 0, open + 1
  for i = open + 1, #masked do
    local ch = masked:sub(i, i)
    if ch == "(" or ch == "[" or ch == "{" then
      depth = depth + 1
    elseif ch == ")" or ch == "]" or ch == "}" then
      if depth == 0 then
        pieces[#pieces + 1] = label:sub(start, i - 1)
        return pieces
      end
      depth = depth - 1
    elseif ch == "," and depth == 0 then
      pieces[#pieces + 1] = label:sub(start, i - 1)
      start = i + 1
    end
  end
  pieces[#pieces + 1] = label:sub(start)
  return pieces
end

-- "method = c(…)" (R) / "sep: str | None = ','" (Python) -> name, default,
-- annotation ("str | None"), stars
local function parse_param(piece)
  piece = vim.trim(piece)
  local stars, name = piece:match("^(%**)%s*([%a_.][%w_.]*)")
  if not name then
    return piece:match("^%*%s*$") and { name = "*", kind = "varargs" } or nil
  end
  local after = #stars + #name + 1 -- first byte after the name
  local eq = mask_strings(piece):find("=", after, true)
  local default = eq and vim.trim(piece:sub(eq + 1)) or nil
  local colon = piece:match("^%s*():", after)
  local annotation = colon and vim.trim(piece:sub(colon + 1, (eq or #piece + 1) - 1)) or nil
  return {
    name = name,
    default = default ~= "" and default or nil,
    annotation = annotation ~= "" and annotation or nil,
    stars = #stars,
  }
end

-- Fields can be JSON null (vim.NIL), which the R server sends
local function tbl(v)
  return type(v) == "table" and v or nil
end

local function parse(result)
  local sigs = tbl(tbl(result) and result.signatures)
  if not sigs or #sigs == 0 then
    return nil
  end
  local active = type(result.activeSignature) == "number" and result.activeSignature or 0
  local s = tbl(sigs[active + 1]) or tbl(sigs[1])
  local label = s and type(s.label) == "string" and s.label
  if not label then
    return nil
  end
  local pieces = {}
  -- The server's own parameter list when it has one; [start, end] are
  -- offsets into the label (UTF-16, same as bytes for the ASCII here)
  for _, p in ipairs(tbl(s.parameters) or {}) do
    if type(p) ~= "table" then
      break
    elseif type(p.label) == "table" then
      pieces[#pieces + 1] = label:sub(p.label[1] + 1, p.label[2])
    elseif type(p.label) == "string" then
      pieces[#pieces + 1] = p.label
    end
  end
  -- A parameter label may be only the name (no default): take the label's
  -- own pieces then, they have everything
  local from_label = split_label(label)
  if #pieces == 0 or #from_label == #pieces then
    pieces = from_label
  end
  local params, after_varargs = {}, false
  for _, piece in ipairs(pieces) do
    local p = parse_param(piece)
    if p and p.name ~= "/" then
      if p.kind == "varargs" or p.name == "..." or p.stars == 1 then
        p.kind, after_varargs = "varargs", true
      elseif p.stars == 2 or after_varargs then
        p.kind = "keyword"
      else
        p.kind = "positional"
      end
      p.stars = nil
      params[#params + 1] = p
    end
  end
  return #params > 0 and { label = label, params = params } or nil
end

function M.cached(buf)
  local call = context.open_calls()[1]
  return call and cache[key(buf or vim.api.nvim_get_current_buf(), call)]
end

local inflight = {} -- call key -> true while asking the servers

-- Hand `sig` to everyone waiting for call `k`, and keep it
local function settle(k, sig)
  if sig and not cache[k] then
    if cache_size > 100 then
      cache, cache_size = {}, 0
    end
    cache[k], cache_size = sig, cache_size + 1
  end
  local waiting = pending[k]
  pending[k] = nil
  for _, f in ipairs(waiting or {}) do
    f(sig)
  end
end

-- Ask every server with signature help; the first signature wins. Right
-- after an edit the R server can answer with nothing for a moment, and
-- some clients never answer (otter's, in an R chunk), so whatever has come
-- back, ask again 250 ms later, twice at most (from the first try's
-- position: still in the call).
local function ask(buf, k, attempt, positions)
  local clients = vim.lsp.get_clients({ bufnr = buf, method = "textDocument/signatureHelp" })
  if #clients == 0 or not vim.api.nvim_buf_is_valid(buf) then
    inflight[k] = nil
    return settle(k, nil)
  end
  inflight[k] = true
  for _, client in ipairs(clients) do
    positions[client.id] = positions[client.id] or vim.lsp.util.make_position_params(0, client.offset_encoding)
    client:request("textDocument/signatureHelp", positions[client.id], function(err, result)
      local ok, sig = pcall(parse, not err and result or nil)
      sig = ok and sig or nil
      if sig and inflight[k] then
        inflight[k] = nil
        settle(k, sig)
      end
    end, buf)
  end
  vim.defer_fn(function()
    if not inflight[k] then
      return
    elseif attempt < 3 then
      ask(buf, k, attempt + 1, positions)
    else
      inflight[k] = nil
      settle(k, nil)
    end
  end, 250)
end

function M.fetch(buf, cb)
  local call = context.open_calls()[1]
  if not call then
    return cb(nil)
  end
  local k = key(buf, call)
  if cache[k] then
    return cb(cache[k])
  end
  -- The caller hears back within TIMEOUT_MS either way; a later answer
  -- still goes into the cache for the next keystroke
  local called = false
  local function once(sig)
    if not called then
      called = true
      cb(sig)
    end
  end
  pending[k] = pending[k] or {}
  table.insert(pending[k], once)
  vim.defer_fn(function()
    once(nil)
  end, TIMEOUT_MS)
  if not inflight[k] then
    ask(buf, k, 1, {})
  end
end

-- Names of the params given in the call so far: by name, plus the first
-- `positional` params not given by name (R and Python fill them in order,
-- up to `...` / `*args`)
function M.filled(sig, args)
  local filled = vim.deepcopy(args.named)
  local n = args.positional
  for _, p in ipairs(sig and sig.params or {}) do
    if n == 0 or p.kind ~= "positional" then
      break
    end
    if not args.named[p.name] then
      filled[p.name] = true
      n = n - 1
    end
  end
  return filled
end

-- The param called `name` in `sig`
function M.param(sig, name)
  for _, p in ipairs(sig and sig.params or {}) do
    if p.name == name then
      return p
    end
  end
end

return M
