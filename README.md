# Neovim config

A personal Neovim setup built on [lazy.nvim](https://github.com/folke/lazy.nvim), tuned for Python, R / R Markdown and
LaTeX-heavy notes, with a few hand-written features:

- **Inline LaTeX / markdown previews** (`lua/config/tex-preview.lua`): render the equation, table or paragraph under
  the cursor as an image right below it.
- **R Markdown LaTeX highlighting** (`lua/config/rmd-latex-hl.lua`, `lua/config/latex-hl.lua`,
  `queries/`): maths, environments and raw LaTeX commands get colour inside `.Rmd` / `.qmd` / `.md`.
- **Dim behind floats** (`lua/config/dim-behind-float.lua`): windows behind a focused floating window are dimmed,
  including Tree-sitter and LSP colours.
- **R and Python, RStudio style** (`lua/config/kernel/`): Jupyter kernels run by a small bridge process, with one R
  session shared by scripts and notebooks. Send lines / selections / paragraphs from `.R` and `.py` files or code
  chunks; chunk output (text and plots) shows inline under the chunk with a status line (execution count, time, a
  live clock while running, a marker once the code was edited); a native console along the bottom (hidden until
  `\rH`) echoes everything that runs and takes typed input with history and Tab completion. Also: object
  commands (print, str, help in a split, data frames in a csvview tab with row names, an object list), completion
  from the running session (objects, `df$` columns), and background knitting (`lua/config/rmd-knit.lua`).
- **Code chunk highlighting** (`lua/config/chunk-hl.lua`): chunks in `.Rmd` / `.qmd` / markdown get a background and
  their language on the opening fence; `eval=FALSE` chunks are dimmed and `#| key: value` options highlighted as
  YAML.
- **Jupyter notebooks as markdown** (`lua/plugins/jupytext.lua`): `.ipynb` files open as markdown with ```` ```python ````
  cells, so they get everything R Markdown gets: run cells with inline output, LaTeX highlighting and previews, `\kk`
  to execute and export HTML. Saved outputs show when a notebook opens and the current ones are written back on
  save (`lua/config/kernel/ipynb.lua`). Python LSP inside cells comes from otter.nvim (`lua/plugins/otter.lua`), and
  the kernel is the project's `.venv` (`lua/config/python-env.lua`).
- **`gd` that knows reassignments** (`lua/config/goto-definition.lua`): goes to the assignment in effect at the
  cursor (closest above, in scope, across notebook chunks); `gd` again steps to the one before.
- **`:MasonSync`**: installs the Mason tools listed in `lua/plugins/lsp.lua` on a new machine.

## Try it without touching your own config

```sh
git clone <this repo> ~/.config/nvim-shared
NVIM_APPNAME=nvim-shared nvim
```

Plugins, parsers and Mason tools install on first start (give it a minute, then restart once).

## Requirements

Required:

- Neovim **0.11+** (uses `vim.lsp.config` and `winborder`)
- `git`, `make` and a C compiler (Tree-sitter parsers, telescope-fzf-native)
- A [Nerd Font](https://www.nerdfonts.com/) in your terminal
- [`ripgrep`](https://github.com/BurntSushi/ripgrep) for live grep
- [`tree-sitter` CLI](https://github.com/tree-sitter/tree-sitter) **≥ 0.26.1** for the `latex` parser (skipped with a
  warning otherwise)

Optional, per feature:

| Feature | Needs |
|---|---|
| `<leader>g*` lazygit | `lazygit` |
| `<leader>r*` LaTeX/markdown previews | `tectonic` or `pdflatex`, `pdftoppm` (poppler), `pandoc`; optional `magick` (ImageMagick); a terminal with the kitty graphics protocol (kitty, WezTerm, Ghostty) |
| Inline plots (image.nvim) | `magick` (ImageMagick) and the same kind of terminal |
| R, knitting, kernels | R with `rmarkdown` and `IRkernel` (`IRkernel::installspec()`); a Python venv at `~/.venvs/nvim` with `jupyter_client` |
| Jupyter notebooks, Python | `jupytext` (`brew install jupytext`); `nbconvert` in `~/.venvs/nvim` (for `\kk`); `ipykernel` in the project's `.venv` (registered as a kernel the first time Python code runs) |
| Codeium completions | a free Codeium account: run `:Codeium Auth` once |
| `<leader>R*` remote editing | SSH hosts in `~/.ssh/config` (note: remote-nvim.nvim is archived upstream) |
| Julia LSP, R LSP, `rustfmt`, `styler` | come from the Julia / R / Rust toolchains, not Mason |

The language servers and formatters themselves (basedpyright, lua_ls, rust-analyzer, gopls, prettier, stylua, ...)
are installed automatically by Mason.

## Layout

```
init.lua                 loads options -> lazy.nvim -> keymaps -> custom features
lua/config/options.lua   editor options (and leader keys)
lua/config/keymaps.lua   general keymaps
lua/config/lazy.lua      lazy.nvim bootstrap
lua/config/*.lua         hand-written features (one file each, documented in its header)
lua/plugins/*.lua        one lazy.nvim spec per plugin; plugin keymaps live in each spec's `keys`
lua/config/kernel/       the R / Python engine: bridge.py (owns the kernels), console, sending, inline output
queries/                 extra Tree-sitter queries (LaTeX highlighting, LaTeX inside markdown, chunk options as YAML)
after/queries/           query extensions (code-cell text objects for markdown)
lazy-lock.json           pinned plugin versions
```

## Keymaps

Leader is `<Space>`, local leader is `\`. Press `<Space>` and wait for which-key to list everything.

| Keys | Action |
|---|---|
| `<leader>ff` `fg` `fb` `fw` `fr` `fd` | Telescope: files, live grep, buffers, word under cursor, recent, files in buffer's dir |
| `<leader>K` / `<leader>k` | all diagnostics (Telescope) / toggle inline non-error diagnostics |
| `<leader>cc` | format buffer (conform) |
| `<leader>e` / `-` | file tree (nvim-tree) / parent directory (oil) |
| `s` `S`, `f` `t` `;` `,` | flash: jump / Tree-sitter jump; `f`/`t` with labels, repeated with `;` `,` (or `f` again) |
| `<leader>gg` `gf` `gl` | lazygit, file history, switch repo |
| `]h` `[h`, `<leader>gs` `gr` `gS` `gR` `gp` `gb` `gB`, `ih` | gitsigns: next / previous hunk, stage / reset hunk (or selection), stage / reset buffer, preview, blame, toggle inline blame; hunk text object |
| `<C-\>`, `<leader>tt` `th` `tv` `tp` `tl` `ts` | toggleterm: float / horizontal / vertical terminal, pick, send line / selection (`<Esc><Esc>` leaves terminal mode) |
| `<leader>rp` `rm` `ra` `rs` `rla` `rls` | LaTeX/markdown previews: under cursor (or selection), as markdown, whole buffer, screen, LaTeX only |
| `<leader>rr` `rw` `rx` `rc` | previews: repeat last, toggle re-render on save, clear under cursor, clear all |
| `<leader>r+` `r-` `rt` `ro` `re` | previews: bigger, smaller, toggle theme/paper colours, open last as PDF, edit last `.tex`; more settings with `:TexPreviewSet` |
| `\l` `\d`, `\ss` `\sd`, `\pp` `\pd`, `\fc`, `\aa` | R / Python scripts and chunks: send statement (and move down), selection, paragraph, function, whole file (scripts) |
| `\rf` `\rq` `\rk` `\rH` `\rr` | start the kernel (if running: show the console), stop, restart, hide / show console, clear it |
| `\rp` `\rs` `\rt` `\rn` `\rg` `\rh` `\rv` `\ro` | object under cursor: print, summary, str, names, plot, help, view data frame, object list |
| `\mc` `\mn` `<S-CR>`, `\ma` `\mb` `\mu` `\mR` `\mI` | notebooks: run chunk (and go to next), run all / above / above then this one / restart and run above / import chunks |
| `\md` `\mD` `\mh` `\mo`, `\gn` `\gN` | notebooks: delete / clear all outputs, hide output, output in a float; next / previous chunk |
| `\kk` / `\ko` | knit R Markdown (notebooks: execute + export HTML) / open the output |
| `ix` `ax`, `]x` `[x` | code chunk / notebook cell: select inside / with fences; next / previous (markdown, Rmd, notebooks) |
| `:NewNotebook {name}` | create and open an empty Jupyter notebook |
| `<leader>y` / `<leader>d` | yank / delete to system clipboard |
| `<leader>i` / `<leader>m` | toggle boolean / split-join (treesj) |
| `af` `if` `ac` `ic` `aa` `ia`, `]f` `[f` `]c` `[c` | Tree-sitter text objects and motions (in a diff, `]c` `[c` still jump between changes) |
| `<leader>R*` | remote-nvim |

LSP keymaps are Neovim's built-in defaults (`:help lsp-defaults`), active whenever a language server is attached,
plus `gd`:

| Keys | Action |
|---|---|
| `gd` | go to definition; for reassigned variables the assignment in effect, `gd` again for the one before |
| `K` | hover documentation |
| `grn` / `gra` / `grx` | rename / code action / run code lens |
| `grr` / `gri` / `grt` | references / implementation / type definition |
| `gO` | document symbols |
| `<C-s>` (insert) | signature help |
| `]d` `[d` / `<C-w>d` | next / previous diagnostic / diagnostic float |

## Opinionated defaults you may want to change

- **hardtime.nvim** is always on (in hint mode): it nags about repeated `hjkl` and similar habits. Delete
  `lua/plugins/hardtime.lua` to turn it off.
- **Mouse wheel scrolling is disabled** at the top of `lua/config/keymaps.lua`.
- **`<Esc>` closes Telescope** straight from insert mode.
- **The R / Python console starts hidden**: `\rH` shows it. Set `SHOW_ON_START = true` in
  `lua/config/kernel/console.lua` to open it whenever a kernel starts.
- **Colorscheme** is Catppuccin Mocha (`lua/plugins/colorscheme.lua`); float borders and status colours follow it.
