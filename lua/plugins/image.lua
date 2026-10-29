-- Inline image rendering (plots under notebook chunks, and the plot viewer of
-- the kernel console, lua/config/kernel/). Needs a terminal with the kitty
-- graphics protocol (kitty, WezTerm, Ghostty). Text output works without it.
return {
  "3rd/image.nvim",
  opts = {
    backend = "kitty",
    processor = "magick_cli", -- uses the `magick` binary, no luarocks needed
    integrations = {}, -- lua/config/kernel/inline.lua places the images itself
    max_width = 100,
    max_height = 12,
    max_width_window_percentage = math.huge,
    max_height_window_percentage = math.huge,
    window_overlap_clear_enabled = true,
    -- Floating windows of these filetypes won't hide images they overlap.
    window_overlap_clear_ft_ignore = {
      "cmp_menu",
      "cmp_docs",
      "",
      "blink-cmp-menu",
      "blink-cmp-documentation",
      "blink-cmp-signature",
      "blink-cmp-ghost-text",
      "wk",
      "which_key",
    },
  },
}
