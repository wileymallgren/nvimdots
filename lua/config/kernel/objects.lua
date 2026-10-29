-- Commands on the object under the cursor (or the visual selection) in R and
-- Python code. Most run in the console, where they show; help, view and the
-- object list run silently and open a window instead.
--   \rp print   \rs summary   \rt str / type   \rn names / columns
--   \rg plot    \ra args (R)
--   \rh help in a split            \rv view a data frame (csvview tab)
--   \ro the session's objects in a float (<CR> on one: view it)
--   \rl list objects   \rm remove all objects   \rd cwd -> the file's dir
-- Insert mode: <M--> " <- " and \, " |>" in R code; <M-r> a new R chunk
-- (R Markdown / Quarto).

local session = require("config.kernel.session")
local chunks = require("config.kernel.chunks")

local M = {}

local R = {
  print = "print(%s)",
  summary = "summary(%s)",
  str = "str(%s)",
  names = "names(%s)",
  plot = "plot(%s)",
  args = "args(%s)",
}
local PY = {
  print = "print(%s)",
  summary = "%s.describe()",
  str = "type(%s)",
  names = 'list(getattr(%s, "columns", None) if hasattr(%s, "columns") else dir(%s))',
}

-- Language of the code under the cursor, or nil after telling the user.
local function lang_here()
  local lang = chunks.lang_at(vim.fn.line("."))
  if not lang then
    vim.notify("Not in R or Python code", vim.log.levels.WARN)
  end
  return lang
end

-- The object name under the cursor (df, df$col, pkg::fun, obj.attr), or the
-- visual selection.
local function word(lang)
  if vim.fn.mode():match("^[vV\22]") then
    vim.cmd("normal! \27")
    local lines = vim.fn.getregion(vim.fn.getpos("'<"), vim.fn.getpos("'>"), { type = vim.fn.visualmode() })
    return vim.trim(table.concat(lines, "\n"))
  end
  local line, col = vim.api.nvim_get_current_line(), vim.fn.col(".")
  local chars = lang == "r" and "[%w._$@:]" or "[%w_.]"
  local s, e = col, col
  while s > 1 and line:sub(s - 1, s - 1):match(chars) do
    s = s - 1
  end
  while e <= #line and line:sub(e, e):match(chars) do
    e = e + 1
  end
  local w = line:sub(s, e - 1):gsub("^[:$@.]+", ""):gsub("[:$@.]+$", "")
  if w == "" then
    vim.notify("No object under the cursor", vim.log.levels.WARN)
    return nil
  end
  return w
end

local function kernel(lang, on_ready)
  return session.ensure(lang, vim.api.nvim_get_current_buf(), on_ready)
end

-- Run fn(name) on the object under the cursor in the console.
function M.action(what)
  local lang = lang_here()
  local tmpl = lang and (lang == "r" and R or PY)[what]
  if not tmpl then
    return lang and vim.notify(("No %s for %s"):format(what, lang), vim.log.levels.WARN)
  end
  local w = word(lang)
  local k = w and kernel(lang)
  if k then
    session.execute(k, (tmpl:gsub("%%s", w)), { source = "object" })
  end
end

-- Run `code` in the console of the cursor's kernel.
function M.console(r_code, py_code)
  local lang = lang_here()
  local code = lang == "r" and r_code or py_code
  local k = code and kernel(lang)
  if k then
    session.execute(k, code, { source = "object" })
  end
end

local function quote(s)
  return '"' .. s:gsub("\\", "/"):gsub('"', '\\"') .. '"'
end

function M.setwd()
  local dir = vim.fn.expand("%:p:h")
  M.console("setwd(" .. quote(dir) .. ")", "__import__('os').chdir(" .. quote(dir) .. ")")
end

-- View the data frame (anything as.data.frame / pd.DataFrame takes) in a
-- csvview tab. Real row names / a non-default index become the first column.
function M.view(name)
  local lang = lang_here()
  name = name or (lang and word(lang))
  if not name then
    return
  end
  local path = vim.fn.tempname() .. ".tsv"
  local code
  if lang == "r" then
    code = ([[local({
  o <- as.data.frame(%s)
  if (nrow(o) > 50000) o <- head(o, 50000)
  if (!identical(row.names(o), as.character(seq_len(nrow(o))))) o <- setNames(cbind(row.names(o), o), c("", names(o)))
  write.table(o, %s, sep = "\t", quote = FALSE, row.names = FALSE, na = "NA", fileEncoding = "UTF-8")
})]]):format(name, quote(path))
  else
    code = ([[(lambda pd, d: d.to_csv(%s, sep="\t", index=not isinstance(d.index, pd.RangeIndex)))(__import__("pandas"), __import__("pandas").DataFrame(%s).head(50000))]]):format(
      quote(path),
      name
    )
  end
  local k = kernel(lang)
  if not k then
    return
  end
  session.eval(k, code, function(_, ok, err)
    if ok and vim.fn.filereadable(path) == 1 then
      require("config.r-view-df").open(path, name)
    else
      vim.notify(("Can't view %s: %s"):format(name, vim.trim(err or "")), vim.log.levels.WARN)
    end
  end)
end

local help_ns = vim.api.nvim_create_namespace("kernel-help")

local function show_help(title, text)
  local lines = vim.split(text:gsub(".\b", ""), "\n", { plain = true })
  local buf
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.b[b].kernel_help then
      buf = b
    end
  end
  if not buf then
    buf = vim.api.nvim_create_buf(false, true)
    vim.b[buf].kernel_help = true
    vim.bo[buf].bufhidden = "wipe"
    vim.keymap.set("n", "q", "<cmd>close<CR>", { buffer = buf })
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, buf, "help: " .. title)
  vim.api.nvim_buf_clear_namespace(buf, help_ns, 0, -1)
  for i, l in ipairs(lines) do
    if l:match("^%u[%w%s]*:$") or (i <= 2 and l:find("%S")) then
      vim.api.nvim_buf_set_extmark(buf, help_ns, i - 1, 0, { end_row = i, hl_group = "Title" })
    end
  end
  local win = vim.fn.bufwinid(buf)
  if win == -1 then
    vim.cmd(vim.o.columns >= 160 and "vsplit" or "aboveleft split")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    vim.wo[win][0].number = false
    vim.wo[win][0].relativenumber = false
    vim.wo[win][0].spell = false
  end
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
end

function M.help()
  local lang = lang_here()
  local w = lang and word(lang)
  if not w then
    return
  end
  local code
  if lang == "r" then
    local pkg, topic = w:match("^([%w.]+):::?(.+)$")
    local call = pkg and ("help(%s, package = %s)"):format(quote(topic), quote(pkg)) or ("help(%s)"):format(quote(w))
    code = ([[local({
  h <- %s
  if (length(h) == 0) stop("No documentation for '%s'")
  tools::Rd2txt(utils:::.getHelpFile(h[1]), options = list(underline_titles = FALSE, width = 80))
})]]):format(call, w)
  else
    code = ("print(__import__('pydoc').render_doc(%s, renderer=__import__('pydoc').plaintext))"):format(w)
  end
  local k = kernel(lang)
  if not k then
    return
  end
  session.eval(k, code, function(text, ok, err)
    if ok and vim.trim(text) ~= "" then
      show_help(w, text)
    else
      vim.notify(vim.trim(err or ("No help for " .. w)), vim.log.levels.WARN)
    end
  end)
end

-- The objects in the session, one per line: name, class, dimensions.
function M.list_objects()
  local lang = lang_here()
  if not lang then
    return
  end
  local code = lang == "r"
      and [[local({
  for (n in ls(globalenv())) {
    o <- get(n, globalenv())
    d <- dim(o)
    cat(sprintf("%-24s %-14s %s\n", n, class(o)[1], if (!is.null(d)) paste(d, collapse = " x ") else length(o)))
  }
})]]
    or [[(lambda g: [print(f"{n:24} {type(v).__name__:14} {getattr(v, 'shape', '')}") for n, v in list(g.items()) if not n.startswith("_") and type(v).__name__ not in ("module", "function", "type", "builtin_function_or_method")])(globals())]]
  local k = kernel(lang)
  if not k then
    return
  end
  session.eval(k, code, function(text, ok, err)
    if not ok then
      return vim.notify(vim.trim(err or ""), vim.log.levels.WARN)
    end
    local lines = vim.split(vim.trim(text), "\n", { plain = true })
    if lines[1] == "" then
      return vim.notify("No objects in the session")
    end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    local width = math.min(vim.o.columns - 4, 70)
    local height = math.min(vim.o.lines - 6, #lines)
    local src = vim.api.nvim_get_current_win()
    vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      style = "minimal",
      width = width,
      height = height,
      row = math.floor((vim.o.lines - height) / 2),
      col = math.floor((vim.o.columns - width) / 2),
      title = (" %s objects  <CR> view  q close "):format(k.label),
    })
    vim.keymap.set("n", "q", "<cmd>close<CR>", { buffer = buf })
    vim.keymap.set("n", "<CR>", function()
      local name = vim.api.nvim_get_current_line():match("^(%S+)")
      vim.cmd.close()
      vim.api.nvim_set_current_win(src)
      M.view(name)
    end, { buffer = buf })
  end)
end

-- Insert-mode helpers (expr mappings)
function M.insert_assign()
  return chunks.lang_at(vim.fn.line(".")) == "r" and " <- " or ""
end

function M.insert_pipe()
  return chunks.lang_at(vim.fn.line(".")) == "r" and " |>" or ""
end

function M.insert_chunk()
  local row = vim.fn.line(".")
  vim.api.nvim_buf_set_lines(0, row, row, false, { "```{r}", "", "```" })
  vim.api.nvim_win_set_cursor(0, { row + 2, 0 })
end

return M
