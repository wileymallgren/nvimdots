-- C / C++: compile the current file and run or debug it.
--   <localleader>r   (c / cpp) compile and run in a terminal split (stdin works)
--   <localleader>R   compile optimised (-O2, no sanitizers) and run, timed
--   <localleader>b   compile only; errors and warnings go to the quickfix list
--   <localleader>a   show the -O2 assembly next to the code, at the function
--                    under the cursor (again to refresh it after an edit)
--   <localleader>d   compile and start the debugger (lua/plugins/dap.lua)
--   <localleader>h   switch between header and source
--   <localleader>i   toggle inlay hints (parameter names, deduced types)
--   <localleader>K   look up the word under the cursor on cppreference
--
-- \r / \b / \d compile with warnings, debug info and the address /
-- undefined-behaviour sanitizers, so out-of-bounds access, use-after-free,
-- signed overflow, division by zero etc. stop the program with a report
-- instead of giving silently wrong output. That makes it several times
-- slower: time things with \R, which compiles the way real code is.
-- A compile_flags.txt in the file's folder (or above) replaces the default
-- -std / warning flags, the same file clangd reads. The binary goes to
-- stdpath("cache")/cpp-run/, not next to the source.

local M = {}

local FILETYPES = { "c", "cpp" }
local DEFAULT_FLAGS = {
  c = { "-std=c17", "-Wall", "-Wextra", "-Wpedantic", "-Wfloat-equal", "-Wdouble-promotion", "-Wshadow" },
  cpp = { "-std=c++20", "-Wall", "-Wextra", "-Wpedantic", "-Wfloat-equal", "-Wdouble-promotion", "-Wshadow" },
}
-- Added after the flags above, by what the build is for
local MODE_FLAGS = {
  debug = {
    "-g",
    -- x / 0.0 is inf by IEEE rules, so `undefined` leaves it alone; in
    -- numerical code it's almost always a bug that turns into NaN later
    "-fsanitize=address,undefined,float-divide-by-zero",
    "-fno-omit-frame-pointer",
  },
  release = { "-O2", "-march=native", "-DNDEBUG" },
  asm = { "-O2", "-S", "-fno-asynchronous-unwind-tables" },
}
local DIAGNOSTIC_FLAGS = {
  "-fno-caret-diagnostics", -- one line per message in the quickfix list
  "-fno-color-diagnostics",
}
-- Clang's "file:line:col: error: message"; %t takes the e / w / n.
local EFM = table.concat({
  "%f:%l:%c: %trror: %m",
  "%f:%l:%c: %tarning: %m",
  "%f:%l:%c: %tote: %m",
  "%f:%l:%c: %m",
  "%f:%l: %m",
}, ",")

--- Where the binary for `file` is written. Two files with the same name in
--- different folders don't overwrite each other.
function M.binary(file)
  local dir = vim.fs.dirname(file)
  local stem = vim.fn.fnamemodify(file, ":t:r")
  return ("%s/cpp-run/%s-%s"):format(vim.fn.stdpath("cache"), stem, vim.fn.sha256(dir):sub(1, 8))
end

-- Flags and the folder to compile in (compile_flags.txt paths such as -I are
-- relative to the file's own folder).
local function flags_for(file, ft)
  local found = vim.fs.find("compile_flags.txt", { upward = true, path = vim.fs.dirname(file) })[1]
  if not found then
    return vim.deepcopy(DEFAULT_FLAGS[ft]), vim.fs.dirname(file)
  end
  local flags = {}
  for line in io.lines(found) do
    line = vim.trim(line)
    if line ~= "" and not line:match("^#") then
      flags[#flags + 1] = line
    end
  end
  return flags, vim.fs.dirname(found)
end

--- Save and compile the current buffer; on success call on_ok(binary, file).
--- mode: "debug" (default), "release" (own binary, -O2) or "asm" (on_ok gets
--- the assembly text instead of a binary).
function M.build(on_ok, mode)
  mode = mode or "debug"
  local buf = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  local file = vim.api.nvim_buf_get_name(buf)
  local ft = vim.bo[buf].filetype
  if file == "" or not DEFAULT_FLAGS[ft] then
    vim.notify("Not a saved C / C++ file", vim.log.levels.WARN)
    return
  end
  vim.cmd("silent update")

  local exe = M.binary(file) .. (mode == "release" and "-release" or "")
  vim.fn.mkdir(vim.fs.dirname(exe), "p")
  local flags, cwd = flags_for(file, ft)
  local cmd = { ft == "cpp" and "clang++" or "clang" }
  vim.list_extend(cmd, flags)
  vim.list_extend(cmd, MODE_FLAGS[mode])
  vim.list_extend(cmd, DIAGNOSTIC_FLAGS)
  vim.list_extend(cmd, { file, "-o", mode == "asm" and "-" or exe })

  local name = vim.fn.fnamemodify(file, ":t")
  vim.api.nvim_echo({ { "Compiling " .. name .. "…" } }, false, {})
  vim.system(cmd, { text = true, cwd = cwd }, function(r)
    vim.schedule(function()
      local out = (r.stderr or "") .. (mode == "asm" and "" or (r.stdout or ""))
      local lines = vim.split(out, "\n", { trimempty = true })
      vim.fn.setqflist({}, " ", { title = "Compile " .. name, lines = lines, efm = EFM })
      -- Opens the list when it has errors / warnings, closes it otherwise;
      -- the cursor stays in the code.
      vim.cmd("botright cwindow")
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_set_current_win(win)
      end
      if r.code ~= 0 then
        vim.api.nvim_echo({ { "Compile failed: " .. name, "ErrorMsg" } }, false, {})
        return
      end
      local warnings = #vim.tbl_filter(function(e)
        return e.type == "w"
      end, vim.fn.getqflist())
      -- (The assembly view prints its own message: two in a row would
      -- stop at "Press ENTER")
      if mode ~= "asm" then
        vim.api.nvim_echo({
          { "Compiled " .. name },
          warnings > 0 and { (" (%d warning%s)"):format(warnings, warnings == 1 and "" or "s"), "WarningMsg" }
            or { "" },
        }, false, {})
      end
      if on_ok then
        on_ok(mode == "asm" and r.stdout or exe, file)
      end
    end)
  end)
end

local term -- the one terminal programs run in; replaced on every run

local function run_in_term(cmd, file)
  if term then
    term:shutdown()
  end
  term = require("toggleterm.terminal").Terminal:new({
    cmd = cmd,
    dir = vim.fs.dirname(file),
    direction = "horizontal",
    hidden = true, -- not part of <C-\> / :TermSelect
    close_on_exit = false, -- keep the output on screen
    on_exit = function(t)
      -- Leave terminal mode so the next key doesn't close the output
      vim.schedule(function()
        if t.window and vim.api.nvim_get_current_win() == t.window then
          vim.cmd("stopinsert")
        end
      end)
    end,
    on_open = function(t)
      vim.keymap.set("n", "q", function()
        t:shutdown()
      end, { buffer = t.bufnr, desc = "Close program output" })
    end,
  })
  term:open()
end

function M.run()
  M.build(function(exe, file)
    run_in_term(vim.fn.shellescape(exe), file)
  end)
end

--- Optimised build, run under time(1): real / user / sys after the output.
function M.run_release()
  M.build(function(exe, file)
    run_in_term("/usr/bin/time -p " .. vim.fn.shellescape(exe), file)
  end, "release")
end

function M.debug()
  M.build(function(exe, file)
    require("dap").run({
      type = "lldb",
      request = "launch",
      name = vim.fn.fnamemodify(file, ":t"),
      program = exe,
      cwd = vim.fs.dirname(file),
      stopOnEntry = false,
      runInTerminal = true, -- program output and std::cin in the console panel
    })
  end)
end

-- Assembly view ------------------------------------------------------------

-- Keep labels and instructions, roughly what Compiler Explorer shows: drop
-- assembler directives (.globl, .p2align, .cfi_*), comment-only lines and
-- the compiler's "; -- Begin function" style comments, and the leading _
-- macOS puts on every symbol.
local DATA = { quad = true, long = true, short = true, byte = true, asciz = true, ascii = true, double = true }

local MAC = vim.fn.has("mac") == 1

local function clean_asm(text)
  local out = {}
  for line in vim.gsplit(text, "\n", { plain = true }) do
    local data = DATA[line:match("^%s*%.(%a+)%s") or ""]
    -- Comments: ";" on arm64 macOS, " # " on x86 (arm64 immediates are #0).
    -- Data lines keep theirs: it says the value (".quad 0x3fe0… ; double 0.5").
    if not data then
      line = line:gsub("%s*;.*$", ""):gsub("%s+#%s.*$", "")
    end
    local directive = not data and line:match("^%s*%.") and not line:match("^%.?L[%w_]+:$")
    local hint = line:match("^Lloh%d+:$") -- linker optimisation hints, not code
    if not (directive or hint) and line:match("%S") then
      if MAC then
        line = line:gsub("^_([%a_][%w_]*)", "%1"):gsub("(%s)_([%a_][%w_]*)$", "%1%2")
      end
      out[#out + 1] = line
    end
  end
  return out
end

-- Name of the function the cursor is in, as c++filt prints it (ns::f)
local function enclosing_function()
  -- Parse first: right after opening a file the tree may not exist yet
  pcall(function()
    vim.treesitter.get_parser(0):parse()
  end)
  local ok, node = pcall(vim.treesitter.get_node)
  while ok and node and node:type() ~= "function_definition" do
    node = node:parent()
  end
  local decl = node and node:field("declarator")[1]
  while decl and decl:type() ~= "function_declarator" do
    decl = decl:field("declarator")[1] -- through pointer / reference declarators
  end
  local name = decl and decl:field("declarator")[1]
  return name and vim.treesitter.get_node_text(name, 0) or nil
end

local asm_bufs = {} -- source buffer -> its assembly buffer

function M.show_asm()
  local src_win = vim.api.nvim_get_current_win()
  local src_buf = vim.api.nvim_get_current_buf()
  local fn = enclosing_function()
  M.build(function(asm, file)
    local function show(text)
      local buf = asm_bufs[src_buf]
      if not (buf and vim.api.nvim_buf_is_valid(buf)) then
        buf = vim.api.nvim_create_buf(false, true)
        asm_bufs[src_buf] = buf
        vim.bo[buf].filetype = "asm"
        pcall(vim.api.nvim_buf_set_name, buf, "asm -O2: " .. vim.fn.fnamemodify(file, ":t"))
        vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, desc = "Close assembly" })
      end
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, clean_asm(text))
      vim.bo[buf].modifiable = false

      local win = vim.fn.bufwinid(buf)
      if win == -1 then
        local at = vim.api.nvim_win_is_valid(src_win) and src_win or vim.api.nvim_get_current_win()
        win = vim.api.nvim_open_win(buf, false, { split = "right", win = at })
        vim.wo[win].wrap = false
        vim.wo[win].number = false
        vim.wo[win].relativenumber = false
      end
      -- Put the function the cursor was in at the top of the view
      local line
      if fn then
        -- A label line, with the name at its start or after a return type
        -- (templates: "double payoff<double>(double):") or a class
        -- ("Option::price() const:" for a method defined in the class)
        local pat = "[%s:]" .. vim.pesc(fn) .. "[(<:]"
        for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
          if l:match("^%S.*:$") and (" " .. l):match(pat) then
            line = i
            break
          end
        end
        if not line then
          vim.api.nvim_echo({ { fn .. ": inlined at -O2, no code of its own", "WarningMsg" } }, false, {})
        end
      end
      line = line or 1
      vim.api.nvim_win_set_cursor(win, { line, 0 })
      vim.api.nvim_win_call(win, function()
        vim.cmd("normal! zt")
      end)
    end
    if vim.fn.executable("c++filt") == 1 then
      vim.system({ "c++filt" }, { stdin = asm, text = true }, function(r)
        vim.schedule(function()
          show(r.code == 0 and r.stdout or asm)
        end)
      end)
    else
      show(asm)
    end
  end, "asm")
end

-- The identifier under the cursor, including std:: style qualifiers
local function qualified_word()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1
  local s, e = col, col
  while s > 1 and line:sub(s - 1, s - 1):match("[%w_:]") do
    s = s - 1
  end
  while e <= #line and line:sub(e, e):match("[%w_:]") do
    e = e + 1
  end
  return (line:sub(s, e - 1):gsub("^:+", ""):gsub(":+$", ""))
end

local function attach(buf)
  local function map(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { buffer = buf, desc = desc })
  end
  map("<localleader>r", M.run, "Compile and run")
  map("<localleader>R", M.run_release, "Compile optimised and run (timed)")
  map("<localleader>b", function()
    M.build()
  end, "Compile (errors to quickfix)")
  map("<localleader>a", M.show_asm, "Show assembly (-O2)")
  map("<localleader>d", M.debug, "Compile and debug")
  map("<localleader>h", "<cmd>LspClangdSwitchSourceHeader<cr>", "Switch header / source")
  map("<localleader>i", function()
    local on = vim.lsp.inlay_hint.is_enabled({ bufnr = buf })
    vim.lsp.inlay_hint.enable(not on, { bufnr = buf })
  end, "Toggle inlay hints")
  map("<localleader>K", function()
    local word = qualified_word()
    if word == "" then
      return
    end
    vim.ui.open("https://en.cppreference.com/mwiki/index.php?search=" .. vim.uri_encode(word))
  end, "Look up on cppreference")
end

function M.setup()
  vim.api.nvim_create_autocmd("FileType", {
    group = vim.api.nvim_create_augroup("CppRun", { clear = true }),
    pattern = FILETYPES,
    callback = function(ev)
      attach(ev.buf)
    end,
  })
end

return M
