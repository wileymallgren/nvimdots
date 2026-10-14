local function tb(name, opts)
  return function()
    require("telescope.builtin")[name](opts)
  end
end

-- Workspace diagnostics picker. Inline diagnostics are hidden while it is open
-- so they don't clutter the preview, and restored on select or <Esc>.
local function diagnostics_with_hooks()
  local builtin = require("telescope.builtin")
  local actions = require("telescope.actions")
  vim.cmd("TinyInlineDiag disable")

  builtin.diagnostics({
    attach_mappings = function(prompt_bufnr, map)
      actions.select_default:enhance({
        post = function()
          vim.cmd("TinyInlineDiag enable")
        end,
      })

      local function close_on_escape()
        vim.cmd("TinyInlineDiag enable")
        actions.close(prompt_bufnr)
      end
      map("i", "<esc>", close_on_escape)
      map("n", "<esc>", close_on_escape)

      return true
    end,
  })
end

return {
  "nvim-telescope/telescope.nvim",
  version = "*",
  cmd = "Telescope",
  dependencies = {
    "nvim-lua/plenary.nvim",
    { "nvim-telescope/telescope-fzf-native.nvim", build = "make" },
  },
  keys = {
    { "<leader>ff", tb("find_files"), desc = "Find files" },
    { "<leader>fg", tb("live_grep"), desc = "Live grep" },
    { "<leader>fb", tb("buffers"), desc = "Find buffers" },
    { "<leader>fw", tb("grep_string"), desc = "Grep word under cursor" },
    { "<leader>fr", tb("oldfiles"), desc = "Recent files" },
    {
      "<leader>fd",
      function()
        require("telescope.builtin").find_files({ cwd = vim.fn.expand("%:p:h") })
      end,
      desc = "Find files in current buffer directory",
    },
    { "<leader>K", diagnostics_with_hooks, desc = "Show all diagnostics" },
  },
  config = function()
    local actions = require("telescope.actions")

    -- Search hidden files/dirs too, but never descend into .git
    local vimgrep_arguments = vim.deepcopy(require("telescope.config").values.vimgrep_arguments)
    vim.list_extend(vimgrep_arguments, { "--hidden", "--glob", "!**/.git/*", "--no-ignore" })

    require("telescope").setup({
      defaults = {
        vimgrep_arguments = vimgrep_arguments,
        mappings = {
          i = {
            ["<esc>"] = actions.close, -- close Telescope instead of entering normal mode
          },
        },
      },
      pickers = {
        find_files = {
          find_command = { "rg", "--files", "--color", "never", "--hidden", "--glob", "!**/.git/*", "--no-ignore" },
        },
      },
      extensions = {
        fzf = {
          fuzzy = false, -- exact (non-fuzzy) matching
          override_generic_sorter = true,
          override_file_sorter = true,
          case_mode = "smart_case",
        },
      },
    })

    require("telescope").load_extension("fzf")
  end,
}
