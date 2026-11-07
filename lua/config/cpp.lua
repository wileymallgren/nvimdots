-- C / C++: compile the current file and run or debug it.
--   <localleader>r   (c / cpp) compile and run in a terminal split (stdin works)
--   <localleader>b   compile only; errors and warnings go to the quickfix list
--   <localleader>d   compile and start the debugger (lua/plugins/dap.lua)
--   <localleader>h   switch between header and source
--   <localleader>i   toggle inlay hints (parameter names, deduced types)
--   <localleader>K   look up the word under the cursor on cppreference
--
-- Compiled with warnings, debug info and the address / undefined-behaviour
-- sanitizers, so out-of-bounds access, use-after-free, signed overflow etc.
-- stop the program with a report instead of giving silently wrong output.
-- A compile_flags.txt in the file's folder (or above) replaces the default
-- -std / warning flags, the same file clangd reads. The binary goes to
-- stdpath("cache")/cpp-run/, not next to the source.

local M = {}

local FILETYPES = { "c", "cpp" }
local DEFAULT_FLAGS = {
  c = { "-std=c17", "-Wall", "-Wextra", "-Wpedantic" },
  cpp = { "-std=c++20", "-Wall", "-Wextra", "-Wpedantic" },
}
local ALWAYS = {
  "-g",
  "-fsanitize=address,undefined",
  "-fno-omit-frame-pointer",
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
function M.build(on_ok)
  local buf = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  local file = vim.api.nvim_buf_get_name(buf)
  local ft = vim.bo[buf].filetype
  if file == "" or not DEFAULT_FLAGS[ft] then
    vim.notify("Not a saved C / C++ file", vim.log.levels.WARN)
    return
  end
  vim.cmd("silent update")

  local exe = M.binary(file)
  vim.fn.mkdir(vim.fs.dirname(exe), "p")
  local flags, cwd = flags_for(file, ft)
  local cmd = { ft == "cpp" and "clang++" or "clang" }
  vim.list_extend(cmd, flags)
  vim.list_extend(cmd, ALWAYS)
  vim.list_extend(cmd, { file, "-o", exe })

  local name = vim.fn.fnamemodify(file, ":t")
  vim.api.nvim_echo({ { "Compiling " .. name .. "…" } }, false, {})
  vim.system(cmd, { text = true, cwd = cwd }, function(r)
    vim.schedule(function()
      local lines = vim.split((r.stderr or "") .. (r.stdout or ""), "\n", { trimempty = true })
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
      vim.api.nvim_echo({
        { "Compiled " .. name },
        warnings > 0 and { (" (%d warning%s)"):format(warnings, warnings == 1 and "" or "s"), "WarningMsg" } or { "" },
      }, false, {})
      if on_ok then
        on_ok(exe, file)
      end
    end)
  end)
end

local term -- the one terminal programs run in; replaced on every run

function M.run()
  M.build(function(exe, file)
    if term then
      term:shutdown()
    end
    term = require("toggleterm.terminal").Terminal:new({
      cmd = vim.fn.shellescape(exe),
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
  end)
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
  map("<localleader>b", M.build, "Compile (errors to quickfix)")
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
