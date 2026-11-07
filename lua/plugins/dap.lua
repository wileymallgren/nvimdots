-- Debugger (nvim-dap) for C / C++ with Apple's lldb-dap (Xcode command line
-- tools; no Mason package needed). Start it with <localleader>d in a c / cpp
-- buffer (lua/config/cpp.lua), which compiles the file first.
--   <F5>          continue (or start: pick a configuration)
--   <F10>         step over        <F11> step into        <F12> step out
--   <leader>b     toggle breakpoint
--   <leader>B     breakpoint with a condition (e.g. i == 3)
--   <leader>Du    toggle the panels   <leader>Dr  REPL      <leader>Dl  run last
--   <leader>Dq    stop                <leader>Dh  value of the expression under the cursor
-- The panels (variables, watches, call stack, breakpoints, program console)
-- open when a session starts and stay open after it ends (<leader>Du).
-- Variable values are also shown at the end of each line as you step
-- (nvim-dap-virtual-text).
-- (Debug keys aren't under <leader>d: that's a mapping, delete to clipboard,
-- and a group under it would make it wait.)

local function lldb_dap()
  if vim.fn.executable("xcrun") == 1 then
    local r = vim.system({ "xcrun", "-f", "lldb-dap" }, { text = true }):wait()
    local path = vim.trim(r.stdout or "")
    if r.code == 0 and path ~= "" then
      return path
    end
  end
  return vim.fn.exepath("lldb-dap") ~= "" and vim.fn.exepath("lldb-dap") or nil
end

local function dap_call(fn, ...)
  local args = { ... }
  return function()
    require("dap")[fn](unpack(args))
  end
end

return {
  {
    "mfussenegger/nvim-dap",
    dependencies = {
      "rcarriga/nvim-dap-ui",
      "nvim-neotest/nvim-nio",
      "theHamsta/nvim-dap-virtual-text",
    },
    keys = {
      { "<F5>", dap_call("continue"), desc = "Debug: continue / start" },
      { "<F10>", dap_call("step_over"), desc = "Debug: step over" },
      { "<F11>", dap_call("step_into"), desc = "Debug: step into" },
      { "<F12>", dap_call("step_out"), desc = "Debug: step out" },
      { "<leader>b", dap_call("toggle_breakpoint"), desc = "Toggle breakpoint" },
      {
        "<leader>B",
        function()
          vim.ui.input({ prompt = "Break when: " }, function(cond)
            if cond and cond ~= "" then
              require("dap").set_breakpoint(cond)
            end
          end)
        end,
        desc = "Conditional breakpoint",
      },
      {
        "<leader>Du",
        function()
          require("dapui").toggle()
        end,
        desc = "Toggle debug panels",
      },
      {
        "<leader>Dr",
        function()
          require("dap").repl.toggle()
        end,
        desc = "Debug REPL",
      },
      { "<leader>Dl", dap_call("run_last"), desc = "Run last debug session" },
      { "<leader>Dq", dap_call("terminate"), desc = "Stop debugging" },
      {
        "<leader>Dh",
        function()
          require("dapui").eval(nil, { enter = true })
        end,
        mode = { "n", "v" },
        desc = "Value under cursor",
      },
    },
    config = function()
      local dap, dapui = require("dap"), require("dapui")

      local cmd = lldb_dap()
      if cmd then
        dap.adapters.lldb = {
          type = "executable",
          command = cmd,
          name = "lldb",
          -- lldb-dap answers in well under a second once warm, but its first
          -- start after a reboot loads LLDB from disk and can pass nvim-dap's
          -- default 4 s, which warns "Debug adapter didn't respond".
          options = { initialize_timeout_sec = 15 },
        }
      else
        vim.notify("lldb-dap not found: debugging C / C++ is unavailable", vim.log.levels.WARN)
      end

      -- For <F5> with no session running; <localleader>d compiles first and
      -- skips this.
      local launch = {
        {
          type = "lldb",
          request = "launch",
          name = "Current file (compile with <localleader>b first)",
          program = function()
            return require("config.cpp").binary(vim.api.nvim_buf_get_name(0))
          end,
          cwd = "${fileDirname}",
          stopOnEntry = false,
          runInTerminal = true,
        },
      }
      dap.configurations.cpp = launch
      dap.configurations.c = launch

      dapui.setup({
        floating = { border = "rounded" }, -- match vim.o.winborder
      })
      require("nvim-dap-virtual-text").setup({})

      dap.listeners.after.event_initialized.dapui = function()
        dapui.open()
      end
      -- Not closed when the program ends, so its output stays readable in the
      -- console panel; <leader>Du closes them.

      vim.fn.sign_define("DapBreakpoint", { text = "●", texthl = "DiagnosticError" })
      vim.fn.sign_define("DapBreakpointCondition", { text = "◆", texthl = "DiagnosticError" })
      vim.fn.sign_define("DapBreakpointRejected", { text = "○", texthl = "DiagnosticWarn" })
      vim.fn.sign_define("DapStopped", { text = "▶", texthl = "DiagnosticOk", linehl = "Visual" })
    end,
  },
}
