return {
  "nvim-treesitter/nvim-treesitter-textobjects",
  branch = "main",
  dependencies = { "nvim-treesitter/nvim-treesitter" },
  init = function()
    -- Disable the built-in ftplugin mappings so they don't conflict
    vim.g.no_plugin_maps = true
  end,
  config = function()
    require("nvim-treesitter-textobjects").setup({
      select = {
        lookahead = true, -- jump forward to textobj, like targets.vim
        selection_modes = {
          ["@parameter.outer"] = "v", -- charwise
          ["@function.outer"] = "V", -- linewise
          ["@class.outer"] = "V",
        },
        include_surrounding_whitespace = false,
      },
      move = {
        set_jumps = true, -- adds movements to the jumplist
      },
    })

    -- === Select mappings ===
    local select = require("nvim-treesitter-textobjects.select")
    vim.keymap.set({ "x", "o" }, "af", function()
      select.select_textobject("@function.outer", "textobjects")
    end, { desc = "Select outer function" })
    vim.keymap.set({ "x", "o" }, "if", function()
      select.select_textobject("@function.inner", "textobjects")
    end, { desc = "Select inner function" })
    vim.keymap.set({ "x", "o" }, "ac", function()
      select.select_textobject("@class.outer", "textobjects")
    end, { desc = "Select outer class" })
    vim.keymap.set({ "x", "o" }, "ic", function()
      select.select_textobject("@class.inner", "textobjects")
    end, { desc = "Select inner class" })
    vim.keymap.set({ "x", "o" }, "aa", function()
      select.select_textobject("@parameter.outer", "textobjects")
    end, { desc = "Select outer parameter" })
    vim.keymap.set({ "x", "o" }, "ia", function()
      select.select_textobject("@parameter.inner", "textobjects")
    end, { desc = "Select inner parameter" })

    -- === Move mappings ===
    local move = require("nvim-treesitter-textobjects.move")
    vim.keymap.set({ "n", "x", "o" }, "]f", function()
      move.goto_next_start("@function.outer", "textobjects")
    end, { desc = "Next function start" })
    -- In a diff, ]c / [c keep their built-in meaning (next / previous change)
    local function diff_or(keys, fn)
      return function()
        if vim.wo.diff and vim.fn.mode() == "n" then
          vim.cmd.normal({ vim.v.count1 .. keys, bang = true })
        else
          fn()
        end
      end
    end
    vim.keymap.set(
      { "n", "x", "o" },
      "]c",
      diff_or("]c", function()
        move.goto_next_start("@class.outer", "textobjects")
      end),
      { desc = "Next class start (next change in a diff)" }
    )
    vim.keymap.set({ "n", "x", "o" }, "[f", function()
      move.goto_previous_start("@function.outer", "textobjects")
    end, { desc = "Previous function start" })
    vim.keymap.set(
      { "n", "x", "o" },
      "[c",
      diff_or("[c", function()
        move.goto_previous_start("@class.outer", "textobjects")
      end),
      { desc = "Previous class start (previous change in a diff)" }
    )

    -- === Swap mappings ===
    local swap = require("nvim-treesitter-textobjects.swap")
    vim.keymap.set("n", "<leader>a", function()
      swap.swap_next("@parameter.inner")
    end, { desc = "Swap with next parameter" })
    vim.keymap.set("n", "<leader>A", function()
      swap.swap_previous("@parameter.inner")
    end, { desc = "Swap with previous parameter" })

    -- ; and , are left to flash.nvim, which repeats f / F / t / T with them.
    -- To repeat ]f / ]c etc., press the motion again.
  end,
}
