-- Root of the project the current file (or oil directory) is in: the
-- nearest folder going up with one of these. Falls back to Neovim's cwd,
-- e.g. on the dashboard.
local ROOT_MARKERS = { ".git", ".here", "DESCRIPTION", "pyproject.toml", "_quarto.yml" }
local function project_root()
  local source = vim.api.nvim_buf_get_name(0)
  if vim.bo.filetype == "oil" then
    source = require("oil").get_current_dir() or ""
  elseif vim.bo.buftype ~= "" then
    source = ""
  end
  local root = source ~= ""
    and vim.fs.root(source, function(name)
      return vim.tbl_contains(ROOT_MARKERS, name) or name:match("%.Rproj$") ~= nil
    end)
  return root or vim.fn.getcwd()
end

-- Telescope builtin `name`. With `rooted`, it searches from project_root()
-- (worked out when the key is pressed, not when the config loads).
local function tb(name, opts, rooted)
  return function()
    local o = vim.deepcopy(opts or {})
    if rooted then
      o.cwd = o.cwd or project_root()
    end
    require("telescope.builtin")[name](o)
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

local binary_exts = {}
for _, ext in ipairs({
  "pdf", "png", "jpg", "jpeg", "gif", "bmp", "tif", "tiff", "ico", "webp", "heic", "psd",
  "mp3", "mp4", "m4a", "mov", "avi", "mkv", "wav", "flac", "ogg", "webm",
  "zip", "gz", "tgz", "tar", "bz2", "xz", "7z", "rar", "dmg", "iso",
  "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp", "key", "pages", "numbers",
  "o", "a", "so", "dylib", "dll", "exe", "bin", "class", "jar", "pyc", "wasm",
  "rds", "rdata", "rda", "pkl", "pickle", "npy", "npz", "h5", "hdf5", "parquet", "feather",
  "sqlite", "sqlite3", "db", "woff", "woff2", "ttf", "otf", "eot",
}) do
  binary_exts[ext] = true
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
    { "<leader>ff", tb("find_files", nil, true), desc = "Find files (project)" },
    { "<leader>fg", tb("live_grep", nil, true), desc = "Live grep (project)" },
    -- Most recently used first, without the one you're in: <CR> = last buffer
    { "<leader>fb", tb("buffers", { sort_mru = true, ignore_current_buffer = true }), desc = "Find buffers" },
    -- In visual mode, telescope greps the (charwise) selection instead
    { "<leader>fw", tb("grep_string", nil, true), mode = { "n", "x" }, desc = "Grep word / selection (project)" },
    { "<leader>fr", tb("oldfiles", nil, true), desc = "Recent files (project)" },
    { "<leader>fR", tb("oldfiles"), desc = "Recent files (everywhere)" },
    { "<leader>fs", tb("lsp_document_symbols"), desc = "Symbols in this file" },
    { "<leader>fS", tb("lsp_dynamic_workspace_symbols"), desc = "Symbols in the project" },
    { "<leader>f<CR>", tb("resume"), desc = "Resume last picker" },
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

    -- Rank binary files (pdf, images, archives, ...) below everything else so
    -- e.g. hw3.Rmd comes before hw3.pdf. They still match, just last.
    local tconf = require("telescope.config").values
    local base_file_sorter = tconf.file_sorter
    tconf.file_sorter = function(opts)
      local sorter = base_file_sorter(opts)
      local score_fn = sorter.scoring_function
      sorter.scoring_function = function(self, prompt, line, ...)
        local score = score_fn(self, prompt, line, ...)
        local ext = line:match("%.([^./\\]+)$")
        if score >= 0 and ext and binary_exts[ext:lower()] then
          score = score + 1 -- fzf scores are in (0, 1], so this puts binaries last
        end
        return score
      end
      return sorter
    end
  end,
}
