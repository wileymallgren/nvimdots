return {
  {
    "windwp/nvim-autopairs",
    event = "InsertEnter",
    opts = {},
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
