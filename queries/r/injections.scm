;; extends

; Quarto / R Markdown chunk options (`#| echo: false`) highlighted as YAML,
; without the leading "#|" (lua/config/chunk-hl.lua; R.nvim did this before).
((comment) @injection.content
  (#match? @injection.content "^#\\|")
  (#set! injection.language "yaml")
  (#set! injection.include-children)
  (#offset! @injection.content 0 2 0 0))
