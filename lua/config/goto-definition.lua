-- gd (lua/plugins/lsp.lua): go to the definition of the name under the
-- cursor or, when the cursor is just before one (a space, `(`, `$` ...), the
-- next name on the line, like `*`.
--
-- For a variable assigned several times it goes to the assignment in effect:
-- the closest one above the cursor (in the same function, or at the top
-- level; in notebooks also in the chunks above). Press gd again on that
-- assignment to step to the one before it, and so on; <C-o> goes back.
--
-- The language server's answer is used where it helps (R's is scope-aware;
-- definitions in other files), and the assignments themselves come from
-- treesitter: R's server returns nothing for names inside a call's
-- arguments, Python's returns every assignment, later ones included.

local M = {}

-- Nodes that open a new variable scope
local FUNCTIONS = { function_definition = true, lambda = true }
-- Python nodes that pack several targets (a, b = ...)
local PATTERNS = { pattern_list = true, tuple_pattern = true, list_pattern = true }
-- Python parameter nodes, and the field holding the name (nil: the bare
-- identifier child)
local PARAMETERS = {
  parameters = false,
  default_parameter = "name",
  typed_default_parameter = "name",
  typed_parameter = false,
  list_splat_pattern = false,
  dictionary_splat_pattern = false,
}
-- Statements whose own right-hand side still sees the previous value
-- (x <- x + 1)
local ASSIGNMENTS = { binary_operator = true, assignment = true, augmented_assignment = true }

local function field_is(parent, field, node)
  for _, n in ipairs(parent:field(field)) do
    if n:id() == node:id() then
      return true
    end
  end
  return false
end

-- Does identifier `node` get a value here? Returns the statement that
-- assigns it and the node whose function scope it belongs to (nil if it
-- isn't an assignment target).
local function assigned(node, src)
  local parent = node:parent()
  if not parent then
    return nil
  end
  local t = parent:type()
  -- R
  if t == "binary_operator" then
    local op = parent:child(1) and vim.treesitter.get_node_text(parent:child(1), src)
    if (op == "<-" or op == "<<-" or op == "=") and field_is(parent, "lhs", node) then
      return parent, parent
    elseif (op == "->" or op == "->>") and field_is(parent, "rhs", node) then
      return parent, parent
    end
  elseif t == "for_statement" and (field_is(parent, "variable", node) or field_is(parent, "left", node)) then
    return parent, parent
  elseif t == "parameter" and field_is(parent, "name", node) then
    return parent, parent -- inside its function_definition: in scope in the body
  -- Python
  elseif PARAMETERS[t] ~= nil then
    local fname = PARAMETERS[t]
    if (fname and field_is(parent, fname, node)) or (not fname and not field_is(parent, "type", node)) then
      return parent, parent
    end
  elseif (t == "function_definition" or t == "class_definition") and field_is(parent, "name", node) then
    return parent, parent:parent() -- the name lives in the scope around the def
  elseif PATTERNS[t] then
    local top = parent
    while top:parent() and PATTERNS[top:parent():type()] do
      top = top:parent()
    end
    local owner = top:parent()
    if owner and (owner:type() == "assignment" or owner:type() == "for_statement") and field_is(owner, "left", top) then
      return owner, owner
    end
  elseif (t == "assignment" or t == "augmented_assignment") and field_is(parent, "left", node) then
    return parent, parent
  elseif t == "as_pattern_target" or (t == "aliased_import" and field_is(parent, "alias", node)) then
    return parent, parent
  end
end

local function enclosing_function(node)
  while node do
    if FUNCTIONS[node:type()] then
      return node
    end
    node = node:parent()
  end
end

local function contains(node, row, col)
  local sr, sc, er, ec = node:range()
  return (row > sr or (row == sr and col >= sc)) and (row < er or (row == er and col < ec))
end

local function before(a, b)
  return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2])
end

-- Assignments of `name` in `buf` that are in scope at `origin` ({row, col},
-- 0-based): { {row, col}, ... }, in buffer order.
local function assignments(buf, name, lang, origin)
  local ok, parser = pcall(vim.treesitter.get_parser, buf)
  if not ok or not parser then
    return {}
  end
  parser:parse(true)
  local found = {}
  local function scan(tree_lang, trees)
    if tree_lang ~= lang then
      return
    end
    for _, tree in pairs(trees) do
      local root = tree:root()
      local function walk(node)
        if node:type() == "identifier" then
          if vim.treesitter.get_node_text(node, buf) == name then
            local stmt, scope = assigned(node, buf)
            local fn = scope and enclosing_function(scope)
            local own_rhs = stmt and ASSIGNMENTS[stmt:type()] and contains(stmt, origin[1], origin[2])
            if stmt and not own_rhs and (not fn or contains(fn, origin[1], origin[2])) then
              local r, c = node:start()
              table.insert(found, { r, c })
            end
          end
          return
        end
        for child in node:iter_children() do
          walk(child)
        end
      end
      walk(root)
    end
  end
  parser:for_each_tree(function(tree, ltree)
    scan(ltree:lang(), { tree })
  end)
  table.sort(found, before)
  return found
end

-- Definitions from the language servers: in-buffer positions and the
-- locations in other files (for show_document).
local function lsp_definitions(buf, cb)
  local params = function(client)
    return vim.lsp.util.make_position_params(0, client.offset_encoding)
  end
  vim.lsp.buf_request_all(buf, "textDocument/definition", params, function(results)
    local here, elsewhere = {}, {}
    local file = vim.fn.resolve(vim.api.nvim_buf_get_name(buf))
    for client_id, res in pairs(results or {}) do
      local client = vim.lsp.get_client_by_id(client_id)
      local locs = res.result or {}
      if locs.uri or locs.targetUri then
        locs = { locs }
      end
      for _, loc in ipairs(locs) do
        local uri = loc.targetUri or loc.uri
        local range = loc.targetSelectionRange or loc.range
        if vim.fn.resolve(vim.uri_to_fname(uri)) == file then
          local line = vim.api.nvim_buf_get_lines(buf, range.start.line, range.start.line + 1, false)[1] or ""
          local col = vim.str_byteindex(line, client.offset_encoding, range.start.character, false)
          table.insert(here, { range.start.line, col })
        else
          table.insert(elsewhere, { loc = loc, encoding = client.offset_encoding })
        end
      end
    end
    cb(here, elsewhere)
  end)
end

local function go(buf, name, list, index)
  local target = list[index]
  vim.cmd("normal! m'")
  vim.api.nvim_win_set_cursor(0, { target[1] + 1, target[2] })
  vim.b[buf].gd_last = { name = name, list = list, index = index, target = target }
  local msg = #list > 1 and ("%s: assignment %d of %d (gd again: the one before)"):format(name, index, #list)
    or ("%s: definition"):format(name)
  vim.api.nvim_echo({ { msg } }, false, {})
end

function M.jump()
  local buf = vim.api.nvim_get_current_buf()
  local line, col = vim.api.nvim_get_current_line(), vim.fn.col(".")
  if vim.fn.matchstr(line:sub(col, col), [[\k]]) == "" then
    local nxt = vim.fn.match(line, [[\k]], col)
    if nxt >= 0 then
      vim.api.nvim_win_set_cursor(0, { vim.fn.line("."), nxt })
    end
  end
  local name = vim.fn.expand("<cword>")
  local pos = vim.api.nvim_win_get_cursor(0)
  local origin = { pos[1] - 1, pos[2] }

  -- gd again on the assignment it went to: the one before
  local last = vim.b[buf].gd_last
  if last and last.name == name and last.target[1] == origin[1] then
    if last.index < #last.list then
      return go(buf, name, last.list, last.index + 1)
    end
    return vim.notify("No earlier assignment of " .. name)
  end

  local lang = require("config.kernel.chunks").lang_at(origin[1] + 1, buf)
    or (vim.bo[buf].filetype == "python" and "python")
    or (vim.bo[buf].filetype == "r" and "r")
  lsp_definitions(buf, function(here, elsewhere)
    local found = lang and assignments(buf, name, lang, origin) or {}
    for _, p in ipairs(here) do
      if not vim.iter(found):any(function(f)
        return f[1] == p[1] and f[2] == p[2]
      end) then
        table.insert(found, p)
      end
    end
    -- Before the cursor, closest first
    local above = vim.tbl_filter(function(p)
      return before(p, origin)
    end, found)
    table.sort(above, function(a, b)
      return before(b, a)
    end)
    -- Start at the server's answer when it is above (R's knows the scope)
    local start = 1
    local lsp_above = vim.tbl_filter(function(p)
      return before(p, origin)
    end, here)
    if #lsp_above > 0 then
      table.sort(lsp_above, function(a, b)
        return before(b, a)
      end)
      for i, p in ipairs(above) do
        if p[1] == lsp_above[1][1] and p[2] == lsp_above[1][2] then
          start = i
          break
        end
      end
    end
    if #above > 0 then
      local list = vim.list_slice(above, start)
      return go(buf, name, list, 1)
    end
    -- Nothing above: what the server says (a function defined further down,
    -- a definition in another file), else the first assignment below
    if #here > 0 then
      return go(buf, name, here, 1)
    elseif #elsewhere > 0 then
      vim.cmd("normal! m'")
      return vim.lsp.util.show_document(elsewhere[1].loc, elsewhere[1].encoding, { focus = true })
    elseif #found > 0 then
      return go(buf, name, found, 1)
    end
    vim.notify("No definition found for " .. name, vim.log.levels.WARN)
  end)
end

return M
