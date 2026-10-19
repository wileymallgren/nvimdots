;; extends

; Raw LaTeX in (R)markdown. $...$ and $$...$$ are already handled by the
; markdown_inline parser (-> latex); this covers pandoc-style raw LaTeX such as
; \begin{table} ... \end{table} that appears as ordinary paragraph text.
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
