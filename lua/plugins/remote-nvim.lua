-- remote-nvim.nvim: VS Code "Remote-SSH"-style editing for Neovim.
-- Installs Neovim on a remote host (or container), copies this config over,
-- starts a headless server there, and attaches a local UI to it.
-- NOTE: upstream was archived (read-only) on 2026-08-13; pinned to the last release.
return {
  "amitds1997/remote-nvim.nvim",
  version = "*", -- latest tagged release (v0.3.12)
  lazy = true,
  dependencies = {
    "nvim-lua/plenary.nvim",
    "MunifTanjim/nui.nvim",
    "nvim-telescope/telescope.nvim",
  },
  -- Lazy-load: nothing is loaded until you run a command or press a key below.
  cmd = { "RemoteStart", "RemoteStop", "RemoteInfo", "RemoteCleanup", "RemoteConfigDel", "RemoteLog" },
  keys = {
    { "<leader>Rs", "<cmd>RemoteStart<cr>", desc = "Remote: start / connect" },
    { "<leader>Rx", "<cmd>RemoteStop<cr>", desc = "Remote: stop server" },
    { "<leader>Ri", "<cmd>RemoteInfo<cr>", desc = "Remote: session info" },
    { "<leader>Rc", "<cmd>RemoteCleanup<cr>", desc = "Remote: clean up host" },
    { "<leader>Rd", "<cmd>RemoteConfigDel<cr>", desc = "Remote: delete saved host" },
    { "<leader>Rl", "<cmd>RemoteLog<cr>", desc = "Remote: open log" },
  },
  opts = {
    ssh_config = {
      -- Hosts defined here show up in the :RemoteStart picker.
      ssh_config_file_paths = { "$HOME/.ssh/config" },
    },
    remote = {
      -- Run the remote with this same config (copied from ~/.config/nvim).
      app_name = "nvim",
    },
    progress_view = { type = "popup" }, -- or "split"
    -- Open the remote UI in a new tab. The remote Neovim draws its own statusline,
    -- tabline and mode text, so while this tab is focused the LOCAL ones are hidden
    -- (and restored when you leave) to avoid two stacked bars.
    -- Close it with :q in the remote; the remote server keeps running until :RemoteStop.
    client_callback = function(port, workspace_config)
      local host = (workspace_config and workspace_config.host) or "remote"
      local quit_local_on_exit = true -- set to false to keep local nvim open
      local saved
      local function hide_chrome()
        if saved then
          return
        end
        saved = {
          laststatus = vim.o.laststatus,
          showtabline = vim.o.showtabline,
          cmdheight = vim.o.cmdheight,
          showmode = vim.o.showmode,
        }
        vim.o.laststatus = 0
        vim.o.showtabline = 0
        vim.o.cmdheight = 0
        vim.o.showmode = false
      end
      local function restore_chrome()
        if not saved then
          return
        end
        for k, v in pairs(saved) do
          vim.o[k] = v
        end
        saved = nil
      end

      vim.cmd("tabnew")
      local buf = vim.api.nvim_get_current_buf()
      local group = vim.api.nvim_create_augroup("RemoteNvimChrome" .. buf, { clear = true })
      vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, { group = group, buffer = buf, callback = hide_chrome })
      vim.api.nvim_create_autocmd(
        { "BufLeave", "BufWipeout" },
        { group = group, buffer = buf, callback = restore_chrome }
      )

      vim.fn.jobstart({ "nvim", "--server", "localhost:" .. port, "--remote-ui" }, {
        term = true,
        on_exit = function(_, code)
          vim.schedule(function()
            restore_chrome()
            if code ~= 0 then
              vim.notify(("Remote client for %s exited with code %d"):format(host, code), vim.log.levels.ERROR)
            end
            if vim.api.nvim_buf_is_valid(buf) then
              vim.api.nvim_buf_delete(buf, { force = true })
            end
            -- Clean exit of the remote UI (:q on its last window, :qa, :detach)
            -- also quits this local Neovim. Errors (:cq, crash) leave it open.
            -- 'confirm' is on, so modified local buffers still prompt first.
            if code == 0 and quit_local_on_exit then
              pcall(vim.cmd, "qall")
            end
          end)
        end,
      })
      pcall(vim.api.nvim_buf_set_name, buf, "remote://" .. host)
      hide_chrome()
      vim.cmd("startinsert")
    end,
  },
}
