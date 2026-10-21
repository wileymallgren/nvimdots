-- blink.cmp source: Codeium, like codeium.nvim's own `codeium.blink`, but in
-- R Markdown / Quarto / markdown notebooks the text sent to Codeium also
-- holds each chunk's output (what molten shows under it as virtual text),
-- placed below the chunk the way a knitted .md has it:
--
--   ```{r}
--   mean(df$mpg)
--   ```
--
--   ```
--   ## [1] 21.3
--   ```
--
--   The mean mpg is |      <- Codeium can now suggest "21.3"
--
-- Only the request changes; the buffer is never touched. Molten shows at
-- most vim.g.molten_virt_text_max_lines (12) lines of each output, so
-- that's what Codeium gets too.

local enums = require("codeium.enums")
local util = require("codeium.util")
local base = require("codeium.blink")

local M = {}

local MAX_LINES_PER_OUTPUT = 20
local MAX_LINES_TOTAL = 200

function M.new()
  return setmetatable({ server = require("codeium").s }, { __index = M })
end

M.enabled = base.enabled
M.get_trigger_characters = base.get_trigger_characters
M.resolve = base.resolve

-- Molten's outputs in `buf`: { { row = closing-fence row (0-based), lines } }
local function molten_outputs(buf)
  local ns = vim.api.nvim_get_namespaces()["molten-extmarks"]
  if not ns or not require("config.rmd-latex-hl").handles(buf) then
    return {}
  end
  local outputs = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    local virt = mark[4].virt_lines
    if virt then
      local lines = {}
      for i, chunks in ipairs(virt) do
        local text = table.concat(vim.tbl_map(function(c)
          return c[1]
        end, chunks))
        -- skip the "Out[2]: ✓ Done 0.0s" header and the "󰁅 3 More Lines" marker
        if not (i == 1 and text:match("^Out%[")) and not text:match("More Lines%s*$") then
          lines[#lines + 1] = (text:gsub("%s+$", ""))
        end
      end
      while #lines > 0 and lines[#lines] == "" do
        lines[#lines] = nil
      end
      if #lines > 0 then
        outputs[#outputs + 1] = { row = mark[2], lines = vim.list_slice(lines, 1, MAX_LINES_PER_OUTPUT) }
      end
    end
  end
  table.sort(outputs, function(a, b)
    return a.row < b.row
  end)
  return outputs
end

-- `lines` with each output inserted after its chunk. Returns the new lines,
-- and how many lines and bytes were inserted above `cursor_row` (0-based).
local function with_outputs(buf, lines, cursor_row, line_ending_len)
  local out, shift, shift_bytes, total = {}, 0, 0, 0
  local outputs, next_output = molten_outputs(buf), 1
  for i, line in ipairs(lines) do
    out[#out + 1] = line
    local o = outputs[next_output]
    while o and o.row < i do
      if o.row == i - 1 and total < MAX_LINES_TOTAL then
        local block = { "", "```" }
        for _, l in ipairs(o.lines) do
          block[#block + 1] = "## " .. l
        end
        vim.list_extend(block, { "```", "" })
        total = total + #block
        vim.list_extend(out, block)
        if o.row < cursor_row then
          shift = shift + #block
          for _, l in ipairs(block) do
            shift_bytes = shift_bytes + #l + line_ending_len
          end
        end
      end
      next_output = next_output + 1
      o = outputs[next_output]
    end
  end
  return out, shift, shift_bytes
end

-- Same as codeium.blink's (local there): a Codeium completion -> blink item
local function codeium_to_item(comp, offset, right)
  local insert_text = comp.completion.text:sub(offset)
  if insert_text:sub(-#right) == right then
    insert_text = insert_text:sub(1, -#right - 1)
  end

  -- the completion part with the largest offset
  local max_offset = offset
  for _, v in pairs(comp.completionParts or {}) do
    max_offset = math.max(max_offset, tonumber(v.offset))
  end
  -- where the completion's suffix stops differing from the code
  local suffix_diff = comp.range.endOffset - max_offset

  local range = {
    start = { line = tonumber(comp.range.startPosition.row) or 0, character = offset - 1 },
    ["end"] = {
      line = tonumber(comp.range.endPosition.row) or 0,
      character = (comp.range.endPosition.col or suffix_diff) - suffix_diff,
    },
  }

  local label = insert_text:match("([^\n]*)")
  if label ~= insert_text then
    label = label .. " "
  end

  return {
    label = label,
    insertText = insert_text,
    kind = require("blink.cmp.types").CompletionItemKind.Text,
    insertTextFormat = vim.lsp.protocol.InsertTextFormat.PlainText,
    kind_name = "Codeium",
    kind_hl_group = "BlinkCmpKindCopilot",
    kind_icon = "󰘦",
    textEdit = { newText = insert_text, insert = range, replace = range },
  }
end

function M:get_completions(ctx, callback)
  local offset = ctx.bounds.start_col
  local cursor = ctx.cursor
  local bufnr = ctx.bufnr
  local filetype = vim.bo[bufnr].filetype
  filetype = enums.filetype_aliases[filetype] or filetype or "text"
  local language = enums.languages[filetype] or enums.languages.unspecified
  local after_line = ctx.line:sub(cursor[2])
  local before_line = ctx.line:sub(1, cursor[2] - 1)
  local line_ending = util.get_newline(bufnr)

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, true)
  lines[cursor[1]] = ctx.line -- what's typed since the menu opened

  local cursor_offset = #before_line
  for i = 1, cursor[1] - 1 do
    cursor_offset = cursor_offset + #lines[i] + #line_ending
  end

  local shift, shift_bytes
  lines, shift, shift_bytes = with_outputs(bufnr, lines, cursor[1] - 1, #line_ending)
  table.insert(lines, "") -- always end with a newline
  local text = table.concat(lines, line_ending)
  M.last_request = { text = text, cursor_offset = cursor_offset + shift_bytes } -- for debugging

  self.server:request_completion(
    {
      text = text,
      editor_language = filetype,
      language = language,
      cursor_position = { row = cursor[1] - 1 + shift, col = cursor[2] },
      absolute_uri = util.get_uri(vim.api.nvim_buf_get_name(bufnr)),
      workspace_uri = util.get_uri(util.get_project_root()),
      line_ending = line_ending,
      cursor_offset = cursor_offset + shift_bytes,
    },
    util.get_editor_options(bufnr),
    util.get_other_documents(bufnr),
    function(success, json)
      if not (success and json and json.state and json.state.state == "CODEIUM_STATE_SUCCESS") then
        return
      end
      local seen, items = {}, {}
      for _, comp in ipairs(json.completionItems or {}) do
        if not seen[comp.completion.text] then
          seen[comp.completion.text] = true
          local item = codeium_to_item(comp, offset, after_line)
          -- back to buffer rows (the outputs above the cursor aren't there)
          local range = item.textEdit.insert
          range.start.line = range.start.line - shift
          range["end"].line = range["end"].line - shift
          items[#items + 1] = item
        end
      end
      callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = items })
    end
  )
  return function() end
end

return M
