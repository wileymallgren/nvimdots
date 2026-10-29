-- "Neovim" in the DOS Rebel figlet font (from ascii.nvim's art.text.neovim.dos_rebel)
local header = {
  "                                                                       ",
  "  ██████   █████                   █████   █████  ███                  ",
  " ░░██████ ░░███                   ░░███   ░░███  ░░░                   ",
  "  ░███░███ ░███   ██████   ██████  ░███    ░███  ████  █████████████   ",
  "  ░███░░███░███  ███░░███ ███░░███ ░███    ░███ ░░███ ░░███░░███░░███  ",
  "  ░███ ░░██████ ░███████ ░███ ░███ ░░███   ███   ░███  ░███ ░███ ░███  ",
  "  ░███  ░░█████ ░███░░░  ░███ ░███  ░░░█████░    ░███  ░███ ░███ ░███  ",
  "  █████  ░░█████░░██████ ░░██████     ░░███      █████ █████░███ █████ ",
  " ░░░░░    ░░░░░  ░░░░░░   ░░░░░░       ░░░      ░░░░░ ░░░░░ ░░░ ░░░░░  ",
  "                                                                       ",
}

return {
  -- Dashboard shown on `nvim` with no args
  {
    "goolord/alpha-nvim",
    lazy = false,
    config = function()
      local alpha = require("alpha")
      local dashboard = require("alpha.themes.dashboard")

      local top_padding = {
        type = "padding",
        val = 10,
      }
      dashboard.section.header.val = header

      dashboard.section.buttons.val = {
        dashboard.button("e", "   New File", "<cmd>ene <BAR> startinsert<CR>"),
        dashboard.button("f", "   Find File", "<cmd>Telescope find_files<CR>"),
        dashboard.button("r", "   Recent Files", "<cmd>Telescope oldfiles<CR>"),
        dashboard.button("l", "  󰒲 Lazy", "<cmd>Lazy<CR>"),
        dashboard.button(
          "c",
          "  󰒓 Config",
          "<cmd>cd " .. vim.fn.fnameescape(vim.fn.stdpath("config")) .. " | Telescope find_files<CR>"
        ),
        dashboard.button("u", "  󰚰 Update", "<cmd>Lazy! sync | q | MasonSync!<CR>"),
        dashboard.button("m", "   Mason", "<cmd>Mason<CR>"),
        dashboard.button("t", "   ToggleTerm", "<cmd>ToggleTerm<CR>"),
        dashboard.button("g", "   LazyGit", "<cmd>LazyGit<CR>"),
        dashboard.button("s", "  󰣀 Remote Connect", "<cmd>RemoteStart<CR>"),
        dashboard.button("q", "  󰈆 Quit", "<cmd>qa<CR>"),
      }

      dashboard.config.layout = {
        top_padding,
        dashboard.section.header,
        { type = "padding", val = 2 }, -- Space between art and buttons
        dashboard.section.buttons,
        dashboard.section.footer,
      }

      alpha.setup(dashboard.config)

      vim.api.nvim_set_hl(0, "HiddenCursor", { blend = 100, nocombine = true })

      -- Create an autocommand group so we don't duplicate listeners
      local alpha_cursor_grp = vim.api.nvim_create_augroup("AlphaCursorToggle", { clear = true })

      -- The cursor shape to go back to when leaving the dashboard
      local saved_guicursor
      local function hide_cursor()
        if vim.o.guicursor ~= "n:HiddenCursor" then
          saved_guicursor = vim.o.guicursor
        end
        vim.o.guicursor = "n:HiddenCursor"
      end

      -- The tabline (always shown, see lua/plugins/lualine.lua) would only say
      -- "1 [No Name]" here, so hide it while the dashboard is all there is:
      -- one tab whose windows, floats aside (Telescope, which-key, ...),
      -- all show it. Checked whenever windows or buffers change.
      local saved_showtabline
      local function dashboard_alone()
        if #vim.api.nvim_list_tabpages() ~= 1 then
          return false
        end
        local seen = false
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          if vim.api.nvim_win_get_config(win).relative == "" then
            if vim.bo[vim.api.nvim_win_get_buf(win)].filetype ~= "alpha" then
              return false
            end
            seen = true
          end
        end
        return seen
      end
      local function update_tabline()
        if dashboard_alone() then
          if vim.o.showtabline ~= 0 then
            saved_showtabline = vim.o.showtabline
            vim.o.showtabline = 0
          end
        elseif saved_showtabline then
          vim.o.showtabline = saved_showtabline
          saved_showtabline = nil
        end
      end
      vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter", "WinEnter", "TabEnter", "TabNew", "FileType" }, {
        group = alpha_cursor_grp,
        callback = update_tabline,
      })
      vim.api.nvim_create_autocmd("WinClosed", {
        group = alpha_cursor_grp,
        callback = function()
          vim.schedule(update_tabline) -- once the window is gone
        end,
      })

      vim.api.nvim_create_autocmd("User", {
        pattern = "AlphaReady",
        group = alpha_cursor_grp,
        callback = function()
          hide_cursor()
          update_tabline()
        end,
      })

      vim.api.nvim_create_autocmd("FileType", {
        pattern = "alpha",
        callback = function()
          -- Hide tildes locally (this persists naturally for the buffer life)
          vim.opt_local.fillchars = { eob = " " }

          -- 1. Hide cursor whenever we look at the dashboard
          vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, {
            group = alpha_cursor_grp,
            buffer = 0,
            callback = hide_cursor,
          })

          -- 2. Restore it whenever we look away from the dashboard
          vim.api.nvim_create_autocmd("BufLeave", {
            group = alpha_cursor_grp,
            buffer = 0,
            callback = function()
              if saved_guicursor then
                vim.o.guicursor = saved_guicursor
              end
            end,
          })
        end,
      })
    end,
  },
}
