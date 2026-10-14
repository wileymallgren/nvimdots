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
        dashboard.button("u", "  󰚰 Update", "<cmd>Lazy! sync | q | MasonSync<CR>"),
        dashboard.button("m", "   Mason", "<cmd>Mason<CR>"),
        dashboard.button("t", "   ToggleTerm", "<cmd>ToggleTerm<CR>"),
        dashboard.button("g", "   LazyGit", "<cmd>LazyGit<CR>"),
        dashboard.button("b", "  󰣀 Remote Connect", "<cmd>RemoteStart<CR>"),
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

      vim.api.nvim_create_autocmd("User", {
        pattern = "AlphaReady",
        group = alpha_cursor_grp,
        callback = hide_cursor,
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

          -- 2. Restore cursor whenever we look away from the dashboard
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
