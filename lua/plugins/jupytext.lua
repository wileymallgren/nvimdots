-- Open Jupyter notebooks (.ipynb) as markdown with ```python fences, and
-- convert back on save. Being filetype markdown, notebooks get the same
-- features as R Markdown: running chunks with inline output (lua/config/kernel/),
-- LaTeX highlighting and previews, <localleader>kk to execute + export HTML.
--   :NewNotebook {name}   create and open an empty notebook
--
-- Needs the `jupytext` CLI on PATH (macOS: brew install jupytext).
-- The outputs saved in the .ipynb show under their chunks when it opens, and
-- saving writes the current ones into it (lua/config/kernel/ipynb.lua).

-- jupytext can only open a valid notebook, so new ones start from this.
local TEMPLATE = [[
{
 "cells": [
  {
   "cell_type": "markdown",
   "metadata": {},
   "source": [""]
  }
 ],
 "metadata": {
  "kernelspec": {
   "display_name": "Python 3",
   "language": "python",
   "name": "python3"
  },
  "language_info": {
   "name": "python"
  }
 },
 "nbformat": 4,
 "nbformat_minor": 5
}
]]

return {
  "GCBallesteros/jupytext.nvim",
  lazy = false, -- must be loaded before the first .ipynb is read
  opts = {
    style = "markdown",
    output_extension = "md",
    force_ft = "markdown",
  },
  config = function(_, opts)
    require("jupytext").setup(opts)

    vim.api.nvim_create_user_command("NewNotebook", function(args)
      local path = args.args:match("%.ipynb$") and args.args or (args.args .. ".ipynb")
      if vim.uv.fs_stat(path) then
        vim.notify(path .. " already exists", vim.log.levels.ERROR)
        return
      end
      vim.fn.writefile(vim.split(TEMPLATE, "\n"), path)
      vim.cmd.edit(vim.fn.fnameescape(path))
    end, { nargs = 1, complete = "file", desc = "Create and open an empty Jupyter notebook" })

    if vim.fn.executable("jupytext") ~= 1 then
      vim.notify("jupytext.nvim: `jupytext` is not installed (brew install jupytext)", vim.log.levels.WARN)
    end
  end,
}
