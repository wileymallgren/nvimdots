require("config.options")
require("config.lazy")
require("config.keymaps")

-- Hand-written features (see the header of each file for its keymaps)
require("config.dim-behind-float")
require("config.tex-preview")
require("config.latex-hl").setup()
require("config.rmd-latex-hl").setup()
require("config.rmd-knit").setup()
require("config.markdown-toc").setup()
require("config.kernel").setup() -- R / Python: console, sending code, inline chunk output
require("config.chunk-hl").setup() -- code chunk background and language label
