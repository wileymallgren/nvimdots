-- Dim the windows behind an active floating window -- and *only* those,
-- and *only* while a float is focused. Ordinary <C-w> navigation between
-- splits is left completely alone.
--
-- Uses window-local highlight namespaces (the same mechanism tint.nvim
-- uses) rather than 'winhighlight' on Normal/NormalNC or a blended
-- overlay window, because this is the only approach that actually
-- recolors every highlight group -- Tree-sitter syntax, LSP semantic
-- tokens, everything -- instead of leaving colored text untouched.

local dim_ns = vim.api.nvim_create_namespace("DimBehindFloat")

-- How strongly to blend every highlight color toward the target dim
-- color. 0 = no change, 1 = flattened entirely to the target color.
local DIM_ALPHA = 0.55

local function is_floating(win)
  return vim.api.nvim_win_get_config(win).relative ~= ""
end

local function hex_to_rgb(hex)
  hex = hex:gsub("#", "")
  return tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16)
end

local function rgb_to_num(r, g, b)
  return (math.floor(r) * 65536) + (math.floor(g) * 256) + math.floor(b)
end

local function blend_toward(color_num, target_hex, alpha)
  local r1, g1, b1 = math.floor(color_num / 65536) % 256, math.floor(color_num / 256) % 256, color_num % 256
  local r2, g2, b2 = hex_to_rgb(target_hex)
  return rgb_to_num(r1 + (r2 - r1) * alpha, g1 + (g2 - g1) * alpha, b1 + (b2 - b1) * alpha)
end

-- Picks a sensible dim target color from the active colorscheme (falls
-- back to a plain dark gray if catppuccin isn't the active theme).
local function get_dim_target()
  local ok, palettes = pcall(require, "catppuccin.palettes")
  if ok then
    local palette = palettes.get_palette()
    if palette and palette.crust then
      return palette.crust
    end
  end
  return "#15151f"
end

local function build_dim_namespace()
  local target = get_dim_target()
  local highlights = vim.api.nvim_get_hl(0, {})

  -- Many syntax/Tree-sitter groups (e.g. @keyword, @string) are defined
  -- as *links* to another group rather than carrying their own fg/bg.
  -- Resolve the link chain ourselves down to concrete colors before
  -- dimming, rather than relying on `nvim_get_hl`'s `link = false` option
  -- (which isn't consistently honored across Neovim versions/paths) --
  -- otherwise a linked group gets copied into the dim namespace as a
  -- bare link and falls back to its original, undimmed color.
  local function resolve(name, seen)
    seen = seen or {}
    if seen[name] then
      return {}
    end
    seen[name] = true

    local def = vim.api.nvim_get_hl(0, { name = name })
    if def.link then
      local resolved = resolve(def.link, seen)
      def = vim.tbl_extend("force", resolved, def)
      def.link = nil
    end
    return def
  end

  for name, _ in pairs(highlights) do
    local resolved = resolve(name)
    local new_def = vim.deepcopy(resolved)
    if new_def.fg then
      new_def.fg = blend_toward(new_def.fg, target, DIM_ALPHA)
    end
    -- Deliberately leave bg untouched -- only text should dim, not the
    -- window's background color.
    pcall(vim.api.nvim_set_hl, dim_ns, name, new_def)
  end
end

build_dim_namespace()

local group = vim.api.nvim_create_augroup("DimBehindFloat", { clear = true })

-- Rebuild the dim palette whenever the colorscheme changes so it always
-- tracks the current theme.
vim.api.nvim_create_autocmd("ColorScheme", {
  group = group,
  callback = build_dim_namespace,
})

vim.api.nvim_create_autocmd("WinEnter", {
  group = group,
  callback = function()
    local entered = vim.api.nvim_get_current_win()
    if not is_floating(entered) then
      return
    end

    -- Rebuild right before use, not just on ColorScheme: Tree-sitter and
    -- LSP register many highlight groups lazily (per-language captures,
    -- semantic tokens) well after startup. Rebuilding here ensures any
    -- group that exists *now* gets a dimmed counterpart, instead of only
    -- whatever existed at the last rebuild.
    build_dim_namespace()

    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if win ~= entered and not is_floating(win) then
        vim.api.nvim_win_set_hl_ns(win, dim_ns)
      end
    end
  end,
})

vim.api.nvim_create_autocmd("WinLeave", {
  group = group,
  callback = function()
    local left = vim.api.nvim_get_current_win()
    if not is_floating(left) then
      return
    end

    -- Wait a tick: if this float is being replaced by another float
    -- (e.g. a picker opening a preview), don't flicker the dimming off
    -- and back on in between.
    vim.schedule(function()
      local any_float_open = false
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_is_valid(win) and is_floating(win) then
          any_float_open = true
          break
        end
      end

      if not any_float_open then
        for _, win in ipairs(vim.api.nvim_list_wins()) do
          if vim.api.nvim_win_is_valid(win) and not is_floating(win) then
            vim.api.nvim_win_set_hl_ns(win, 0)
          end
        end
      end
    end)
  end,
})
