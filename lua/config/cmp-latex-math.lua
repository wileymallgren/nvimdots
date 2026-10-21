-- blink.cmp source: LaTeX maths commands after a `\` inside $...$, $$...$$
-- etc. in markdown / Rmd / Quarto (lua/plugins/completion.lua only enables it
-- in maths). friendly-snippets has almost nothing for maths, and texlab
-- doesn't run on markdown. Commands that take arguments insert as snippets
-- (\frac{|}{}); Tab moves to the next argument.

-- "name" inserts \name; "name=body" inserts the snippet body instead.
-- Entries are split on whitespace, so a body can't contain spaces.
local COMMANDS = [[
frac=\frac{$1}{$2}$0 dfrac=\dfrac{$1}{$2}$0 sqrt=\sqrt{$1}$0 sum=\sum_{$1}^{$2}$0
prod=\prod_{$1}^{$2}$0 int=\int_{$1}^{$2}$0 lim=\lim_{$1}$0 binom=\binom{$1}{$2}$0
text=\text{$1}$0 mathrm=\mathrm{$1}$0 mathbf=\mathbf{$1}$0 mathbb=\mathbb{$1}$0
mathcal=\mathcal{$1}$0 boldsymbol=\boldsymbol{$1}$0 operatorname=\operatorname{$1}$0
hat=\hat{$1}$0 bar=\bar{$1}$0 tilde=\tilde{$1}$0 vec=\vec{$1}$0 dot=\dot{$1}$0
overline=\overline{$1}$0 underbrace=\underbrace{$1}_{$2}$0 left(=\left($1\right)$0
left[=\left[$1\right]$0 left|=\left|$1\right|$0 begin=\begin{${1:aligned}}$0\end{$1}
alpha beta gamma Gamma delta Delta epsilon varepsilon zeta eta theta Theta
iota kappa lambda Lambda mu nu xi Xi pi Pi rho sigma Sigma tau phi varphi Phi
chi psi Psi omega Omega
cdot times div pm mp leq geq neq approx equiv sim simeq propto infty partial
nabla to rightarrow leftarrow Rightarrow Leftrightarrow mapsto in notin subset
subseteq cup cap setminus forall exists emptyset ldots cdots mid perp circ
log ln exp sin cos tan max min arg sup inf det Pr quad qquad top intercal
]]

local items -- built once

local function build()
  local kinds = require("blink.cmp.types").CompletionItemKind
  local fmt = vim.lsp.protocol.InsertTextFormat
  items = {}
  for word in COMMANDS:gmatch("%S+") do
    local name, body = word:match("^([^=]+)=(.+)$")
    name = name or word
    items[#items + 1] = {
      label = "\\" .. name,
      filterText = name,
      kind = body and kinds.Snippet or kinds.Constant,
      insertText = body or ("\\" .. name),
      insertTextFormat = body and fmt.Snippet or fmt.PlainText,
    }
  end
end

local source = {}

function source.new()
  return setmetatable({}, { __index = source })
end

function source:get_trigger_characters()
  return { "\\" }
end

function source:get_completions(ctx, callback)
  local col = ctx.cursor[2]
  local typed = ctx.line:sub(1, col):match("\\(%a*)$")
  if not typed then
    return callback({ items = {}, is_incomplete_forward = false, is_incomplete_backward = false })
  end
  if not items then
    build()
  end
  -- replace the `\` and the letters typed after it
  local range = {
    start = { line = ctx.cursor[1] - 1, character = col - #typed - 1 },
    ["end"] = { line = ctx.cursor[1] - 1, character = col },
  }
  local out = {}
  for i, item in ipairs(items) do
    out[i] = vim.tbl_extend("force", item, { textEdit = { newText = item.insertText, range = range } })
  end
  callback({ items = out, is_incomplete_forward = false, is_incomplete_backward = false })
end

return source
