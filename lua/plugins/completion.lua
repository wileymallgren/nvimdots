return {
  -- Codeium AI completions, shown as a blink.cmp source (free account needed)
  {
    "Exafunction/codeium.nvim",
    dependencies = { "nvim-lua/plenary.nvim" }, -- blink.cmp (below) loads this as a source
    -- Run `:Codeium Auth` once to log in
    opts = {
      enable_cmp_source = false, -- Disable legacy nvim-cmp wrapper
      virtual_text = { enabled = false }, -- suggestions go through blink.cmp instead
    },
  },

  -- Completion menu
  {
    "saghen/blink.cmp",
    dependencies = {
      "rafamadriz/friendly-snippets",
      "Exafunction/codeium.nvim",
    },
    version = "1.*",

    opts = {
      keymap = {
        preset = "super-tab",
      },

      appearance = {
        nerd_font_variant = "mono",
      },

      completion = {
        menu = {
          border = "rounded",
          draw = {
            columns = {
              { "kind_icon" },
              { "label", "label_description", gap = 1 },
              { "source_name" },
            },
          },
        },
        documentation = {
          auto_show = true,
          auto_show_delay_ms = 200,
          window = { border = "rounded" },
        },
        ghost_text = { enabled = true },
        trigger = {
          show_on_keyword = true,
          show_on_trigger_character = true,
        },
      },

      signature = { enabled = true, window = { border = "rounded" } },

      sources = {
        default = { "lsp", "path", "snippets", "buffer", "codeium" },
        providers = {
          codeium = {
            name = "Codeium",
            module = "codeium.blink", -- Uses the fast native blink wrapper
            -- Only ask Codeium in real file buffers. Special buffers like
            -- oil:///path/ make the Codeium server fail with
            -- "empty share name for UNC-like path".
            enabled = function()
              local buf = vim.api.nvim_get_current_buf()
              if vim.bo[buf].buftype ~= "" then
                return false
              end
              local name = vim.api.nvim_buf_get_name(buf)
              return not name:match("^%a[%w+.-]*://")
            end,
            score_offset = 100, -- Places AI entries near the top of your dropdown menu
          },
        },
      },

      fuzzy = { implementation = "prefer_rust_with_warning" },
    },
  },
}
