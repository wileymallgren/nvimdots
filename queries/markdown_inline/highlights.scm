;; extends

; Inline code wins over the latex colours that queries/markdown/injections.scm
; can lay over a whole paragraph (so `df$z + df$y` never looks like maths).
; Default priority is 100 and the latex patterns use 130. The group is set up
; with `nocombine` in lua/config/rmd-latex-hl.lua.
((code_span) @markup.raw.code_span (#set! priority 140))
