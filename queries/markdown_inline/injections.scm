; Not ";; extends": this replaces nvim-treesitter's markdown_inline injections,
; whose latex_block pattern injects latex into anything between two $, e.g.
; "$B = $ blue and $ R = $ red", which pandoc renders as plain text. Its html
; injection is copied here unchanged.

((html_tag) @injection.content
  (#set! injection.language "html")
  (#set! injection.combined))

; $...$ / $$...$$, by pandoc's rules (as in lua/config/rmd-latex-hl.lua):
; $$...$$ always counts; for $...$ there must be no space just inside either
; dollar, and the closing $ must not be escaped.
((latex_block) @injection.content
  (#lua-match? @injection.content "^%$%$")
  (#set! injection.language "latex")
  (#set! injection.include-children))

((latex_block) @injection.content
  (#lua-match? @injection.content "^%$[^%s%$]")
  (#lua-match? @injection.content "[^%s\\]%$$")
  (#set! injection.language "latex")
  (#set! injection.include-children))

; Raw LaTeX in (R)markdown. The patterns below cover pandoc-style raw LaTeX such
; as \begin{table} ... \end{table} that appears as ordinary paragraph text.
;
; Paragraphs with inline code (a backtick) leave out their child nodes, so code
; such as `df$x` or `\begin{align}` is never read as LaTeX. That also leaves out
; markdown escapes (\\ \{ \,) and _emphasis_ in those paragraphs only; the
; others get the whole paragraph text.

; any paragraph containing an environment
((inline) @injection.content
  (#lua-match? @injection.content "\\begin{")
  (#not-lua-match? @injection.content "`")
  (#set! injection.language "latex")
  (#set! injection.include-children))

((inline) @injection.content
  (#lua-match? @injection.content "\\begin{")
  (#lua-match? @injection.content "`")
  (#set! injection.language "latex"))

; paragraphs that start with a LaTeX command (\item, \end{...}, \textbf{...})
((inline) @injection.content
  (#lua-match? @injection.content "^%s*\\%a")
  (#not-lua-match? @injection.content "`")
  (#set! injection.language "latex")
  (#set! injection.include-children))

((inline) @injection.content
  (#lua-match? @injection.content "^%s*\\%a")
  (#lua-match? @injection.content "`")
  (#set! injection.language "latex"))
