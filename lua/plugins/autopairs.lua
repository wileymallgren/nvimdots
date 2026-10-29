return {
  {
    "windwp/nvim-autopairs",
    event = "InsertEnter",
    opts = {
      -- the defaults, plus the kernel console (lua/config/kernel/console.lua),
      -- where <CR> runs the line: a paired "{}" would end the expression early
      disable_filetype = { "TelescopePrompt", "spectre_panel", "snacks_picker_input", "kernel_console" },
    },
    config = function(_, opts)
      local npairs = require("nvim-autopairs")
      local cond = require("nvim-autopairs.conds")
      npairs.setup(opts)

      -- Typing ``` should give exactly ```. By default the third backtick
      -- pairs again (```` in code), and in markdown / Rmd / Quarto a
      -- separate rule adds a closing fence on the same line (``````, so
      -- {r} ended up as ```{r}```). Drop the fence rules, and don't pair a
      -- backtick typed right after another one. `inline code` still pairs.
      npairs.remove_rule("```")
      npairs.remove_rule("```.*$")
      for _, rule in ipairs(npairs.get_rules("`")) do
        rule:with_pair(cond.not_before_text("`"))
      end
    end,
  },
}
