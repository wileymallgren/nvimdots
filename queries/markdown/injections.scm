;; extends

; Raw LaTeX in (R)markdown. $...$ and $$...$$ are already handled by the
; markdown_inline parser (-> latex); this covers pandoc-style raw LaTeX such as
; \begin{table} ... \end{table} that appears as ordinary paragraph text.

; any paragraph containing an environment
((inline) @injection.content
  (#lua-match? @injection.content "\\begin{")
  (#set! injection.language "latex"))

; paragraphs that start with a LaTeX command (\item, \end{...}, \textbf{...})
((inline) @injection.content
  (#lua-match? @injection.content "^%s*\\%a")
  (#set! injection.language "latex"))
