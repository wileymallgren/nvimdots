-- lazygit.nvim: the lazygit terminal UI in a floating window.
-- Needs the `lazygit` binary (macOS: brew install lazygit).
--   <leader>gg   lazygit for the current file's repo
--   <leader>gf   lazygit log of the current file's history
--   <leader>gl   pick another repo from the ones lazygit has opened (Telescope)

-- Directory to look for a repo in: the current file's, else Neovim's cwd.
local function target_dir()
  local name = vim.api.nvim_buf_get_name(0)
  if name ~= "" and vim.bo.buftype == "" and vim.uv.fs_stat(name) then
    return vim.fs.dirname(name), true
  end
  return vim.fn.getcwd(), false
end

-- Runs the file-aware command for a real file, the cwd one otherwise.
-- lazygit itself asks "Create a new git repository? (y/N)" outside a repo;
-- answering N exits and the float closes (see TermClose below).
local function open(cmd_for_file, cmd_for_cwd)
  local _, is_file = target_dir()
  vim.cmd(is_file and cmd_for_file or cmd_for_cwd)
end

return {
  "kdheepak/lazygit.nvim",
  cmd = { "LazyGit", "LazyGitConfig", "LazyGitCurrentFile", "LazyGitFilter", "LazyGitFilterCurrentFile" },
  dependencies = { "nvim-lua/plenary.nvim" },
  keys = {
    {
      "<leader>gg",
      function()
        open("LazyGitCurrentFile", "LazyGit")
      end,
      desc = "Lazygit",
    },
    {
      "<leader>gf",
      function()
        open("LazyGitFilterCurrentFile", "LazyGitFilter")
      end,
      desc = "Lazygit: current file history",
    },
    {
      "<leader>gl",
      function()
        local ok, tel = pcall(require, "telescope")
        if ok then
          pcall(tel.load_extension, "lazygit")
          pcall(tel.extensions.lazygit.lazygit)
        end
      end,
      desc = "Lazygit: switch repo",
    },
  },
  init = function()
    vim.g.lazygit_floating_window_scaling_factor = 0.72
    -- Neovim order: TL, T, TR, R, BR, B, BL, L
    vim.g.lazygit_floating_window_border_chars = { "╭", "─", "╮", "│", "╯", "─", "╰", "│" }

    -- Use the theme's float border colour (lazygit.nvim defaults it to Normal).
    local group = vim.api.nvim_create_augroup("LazygitFloat", { clear = true })
    local function set_hl()
      vim.api.nvim_set_hl(0, "LazyGitBorder", { link = "FloatBorder" })
    end
    set_hl()
    vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = set_hl })

    -- lazygit.nvim only closes its float / resets its state when lazygit exits
    -- with code 0; answering N to "create a repository?" exits with 1 and would
    -- leave a dead float (and stale state) behind. Clean up on ANY exit.
    vim.api.nvim_create_autocmd("TermClose", {
      group = group,
      callback = function(ev)
        if vim.bo[ev.buf].buftype ~= "terminal" then
          return
        end
        local win = vim.fn.bufwinid(ev.buf)
        local floating = win ~= -1 and vim.api.nvim_win_get_config(win).relative ~= ""
        local named = vim.api.nvim_buf_get_name(ev.buf):find("lazygit", 1, true) ~= nil
        if not (named or (vim.g.lazygit_opened == 1 and floating)) then
          return
        end
        vim.g.lazygit_opened = 0
        vim.schedule(function()
          if win ~= -1 and vim.api.nvim_win_is_valid(win) then
            pcall(vim.api.nvim_win_close, win, true)
          end
          if vim.api.nvim_buf_is_valid(ev.buf) then
            pcall(vim.api.nvim_buf_delete, ev.buf, { force = true })
          end
          vim.cmd("stopinsert")
        end)
      end,
    })
  end,
  config = function()
    if vim.fn.executable("lazygit") ~= 1 then
      vim.notify("lazygit.nvim: `lazygit` is not installed (brew install lazygit)", vim.log.levels.WARN)
    end
  end,
}
