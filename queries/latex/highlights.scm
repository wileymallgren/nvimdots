;; extends

; Category-aware LaTeX highlighting for statistics / data-science math, layered
; on top of nvim-treesitter's own latex highlights. Every pattern carries an
; explicit `priority` (default is 100) so these always win over the built-in
; `(command_name) @function` regardless of query load order.
; Node-level tweaks (numbers, ^ _ & \begin env names ...) live in
; lua/config/latex-hl.lua, which checks them against your parser first.
;
;   Greek letters (parameters)     \mu \sigma \beta \lambda ...   @constant.builtin
;   estimator accents              \bar \hat \tilde \overline     @attribute
;   sums / integrals / limits      \sum \prod \int \lim           @keyword.operator
;   named functions                \log \exp \det \Pr             @function.builtin
;   relations, sets, logic         \approx \leq \sim \mid \cap    @operator
;   structure, fonts, \textbf      \frac \sqrt \binom \mathbb     @function.macro
;   delimiters, spacing, ellipses  \left \right \, \quad \cdots   @punctuation.special
;   boxed answers                  \fbox \boxed                   @keyword.return
;   table / layout                 \hline \multicolumn \caption   @type.builtin

; Greek letters: population parameters and estimators
((command_name) @constant.builtin
  (#any-of? @constant.builtin
    "\\alpha" "\\beta" "\\gamma" "\\delta" "\\epsilon" "\\varepsilon" "\\zeta"
    "\\eta" "\\theta" "\\vartheta" "\\iota" "\\kappa" "\\lambda" "\\mu" "\\nu"
    "\\xi" "\\pi" "\\varpi" "\\rho" "\\varrho" "\\sigma" "\\varsigma" "\\tau"
    "\\upsilon" "\\phi" "\\varphi" "\\chi" "\\psi" "\\omega" "\\ell"
    "\\Gamma" "\\Delta" "\\Theta" "\\Lambda" "\\Xi" "\\Pi" "\\Sigma"
    "\\Upsilon" "\\Phi" "\\Psi" "\\Omega")
  (#set! priority 130))

; Accents that mark estimators and statistics: x-bar, p-hat, x-tilde, ...
((command_name) @attribute
  (#any-of? @attribute
    "\\bar" "\\overline" "\\hat" "\\widehat" "\\tilde" "\\widetilde" "\\vec"
    "\\dot" "\\ddot" "\\check" "\\breve" "\\acute" "\\grave")
  (#set! priority 130))

; Big operators and limits
((command_name) @keyword.operator
  (#any-of? @keyword.operator
    "\\sum" "\\prod" "\\coprod" "\\int" "\\iint" "\\iiint" "\\oint" "\\lim"
    "\\limsup" "\\liminf" "\\max" "\\min" "\\sup" "\\inf" "\\argmax" "\\argmin"
    "\\bigcup" "\\bigcap" "\\bigoplus" "\\bigotimes" "\\bigvee" "\\bigwedge")
  (#set! priority 130))

; Named math functions (and probability)
((command_name) @function.builtin
  (#any-of? @function.builtin
    "\\sin" "\\cos" "\\tan" "\\cot" "\\sec" "\\csc" "\\arcsin" "\\arccos"
    "\\arctan" "\\sinh" "\\cosh" "\\tanh" "\\log" "\\ln" "\\lg" "\\exp" "\\det"
    "\\dim" "\\ker" "\\gcd" "\\deg" "\\hom" "\\Pr" "\\arg" "\\operatorname")
  (#set! priority 130))

; Relations, set operations, probability and logic
((command_name) @operator
  (#any-of? @operator
    "\\pm" "\\mp" "\\times" "\\div" "\\cdot" "\\ast" "\\star" "\\circ"
    "\\bullet" "\\oplus" "\\otimes" "\\cup" "\\cap" "\\setminus"
    "\\leq" "\\le" "\\geq" "\\ge" "\\neq" "\\ne" "\\approx" "\\equiv" "\\sim"
    "\\simeq" "\\cong" "\\propto" "\\ll" "\\gg" "\\mid" "\\perp" "\\parallel"
    "\\in" "\\notin" "\\ni" "\\subset" "\\supset" "\\subseteq" "\\supseteq"
    "\\to" "\\rightarrow" "\\leftarrow" "\\leftrightarrow" "\\Rightarrow"
    "\\Leftarrow" "\\Leftrightarrow" "\\mapsto" "\\implies" "\\iff"
    "\\land" "\\lor" "\\lnot" "\\neg" "\\forall" "\\exists" "\\nexists"
    "\\partial" "\\nabla" "\\infty" "\\emptyset" "\\varnothing" "\\prime"
    "\\top" "\\binom" "\\choose")
  (#set! priority 130))

; Math structure: fractions, roots, fonts, text-in-math, bold/italic text
((command_name) @function.macro
  (#any-of? @function.macro
    "\\frac" "\\dfrac" "\\tfrac" "\\cfrac" "\\sqrt" "\\dbinom"
    "\\underline" "\\overbrace" "\\underbrace" "\\overset" "\\underset"
    "\\stackrel" "\\mathbb" "\\mathcal" "\\mathbf" "\\mathrm" "\\mathit"
    "\\mathsf" "\\mathtt" "\\mathfrak" "\\boldsymbol" "\\bm" "\\text"
    "\\textrm" "\\textbf" "\\textit" "\\emph" "\\texttt" "\\mbox")
  (#set! priority 130))

; Sized delimiters, spacing and ellipses
((command_name) @punctuation.special
  (#any-of? @punctuation.special
    "\\left" "\\right" "\\big" "\\Big" "\\bigg" "\\Bigg"
    "\\bigl" "\\bigr" "\\Bigl" "\\Bigr"
    "\\," "\\;" "\\:" "\\!" "\\ " "\\quad" "\\qquad"
    "\\ldots" "\\cdots" "\\dots" "\\vdots" "\\ddots")
  (#set! priority 130))

; Boxed final answers, e.g. \fbox{108.111}
((command_name) @keyword.return
  (#any-of? @keyword.return
    "\\fbox" "\\boxed" "\\framebox" "\\colorbox" "\\fcolorbox")
  (#set! priority 130))

; Table / layout commands
((command_name) @type.builtin
  (#any-of? @type.builtin
    "\\hline" "\\toprule" "\\midrule" "\\bottomrule" "\\cline" "\\cmidrule"
    "\\multicolumn" "\\multirow" "\\centering" "\\raggedright" "\\raggedleft"
    "\\caption" "\\noindent" "\\newline" "\\linebreak" "\\newpage"
    "\\clearpage" "\\vspace" "\\hspace")
  (#set! priority 130))
