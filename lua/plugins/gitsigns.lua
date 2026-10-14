-- gitsigns.nvim: git changes in the sign column, plus hunk actions.
-- (lazygit, on <leader>gg / gf / gl, is for everything bigger.)
--   ]h / [h        next / previous hunk (]H / [H: last / first)
--   <leader>gs     stage / unstage hunk (visual: the selected lines)
--   <leader>gr     reset hunk (visual: the selected lines)
--   <leader>gS     stage the whole buffer
--   <leader>gR     reset the whole buffer
--   <leader>gp     preview hunk inline
--   <leader>gb     blame for the current line (full commit message)
--   <leader>gB     toggle inline blame on the current line
--   <leader>gd     diff the file against the index
--   ih             (operator / visual) select hunk, e.g. dih, yih, vih
return {
  "lewis6991/gitsigns.nvim",
  event = { "BufReadPre", "BufNewFile" },
  opts = {
    on_attach = function(buf)
      local gs = require("gitsigns")
      local function map(mode, lhs, rhs, desc)
        vim.keymap.set(mode, lhs, rhs, { buffer = buf, desc = desc })
      end
      local function selection()
        return { vim.fn.line("."), vim.fn.line("v") }
      end

      -- Navigation
      map("n", "]h", function()
        gs.nav_hunk("next")
      end, "Next git hunk")
      map("n", "[h", function()
        gs.nav_hunk("prev")
      end, "Previous git hunk")
      map("n", "]H", function()
        gs.nav_hunk("last")
      end, "Last git hunk")
      map("n", "[H", function()
        gs.nav_hunk("first")
      end, "First git hunk")

      -- Actions
      map("n", "<leader>gs", gs.stage_hunk, "Stage / unstage hunk")
      map("n", "<leader>gr", gs.reset_hunk, "Reset hunk")
      map("v", "<leader>gs", function()
        gs.stage_hunk(selection())
      end, "Stage / unstage selected lines")
      map("v", "<leader>gr", function()
        gs.reset_hunk(selection())
      end, "Reset selected lines")
      map("n", "<leader>gS", gs.stage_buffer, "Stage buffer")
      map("n", "<leader>gR", gs.reset_buffer, "Reset buffer")
      map("n", "<leader>gp", gs.preview_hunk_inline, "Preview hunk inline")
      map("n", "<leader>gb", function()
        gs.blame_line({ full = true })
      end, "Blame line")
      map("n", "<leader>gB", gs.toggle_current_line_blame, "Toggle inline blame")
      map("n", "<leader>gd", gs.diffthis, "Diff against index")

      -- Text object
      map({ "o", "x" }, "ih", gs.select_hunk, "Select git hunk")
    end,
  },
}
