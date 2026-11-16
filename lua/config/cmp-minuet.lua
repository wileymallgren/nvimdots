-- blink.cmp source: AI completion from a local model (minuet-ai.nvim talking
-- to Ollama), with two additions over minuet's own `minuet.blink`:
--
-- * In R Markdown / Quarto / markdown notebooks the prompt also holds each
--   chunk's output (shown under it by lua/config/kernel/inline.lua), placed
--   below the chunk the way a knitted .md has it:
--
--     ```{r}
--     mean(df$mpg)
--     ```
--
--     ```
--     ## [1] 21.3
--     ```
--
--     The mean mpg is |      <- the model can now suggest "21.3"
--
--   Only the request changes; the buffer is never touched. Each output is
--   cut to MAX_LINES_PER_OUTPUT lines (the inline view shows 20 too).
--
-- * Each item carries the model's confidence, `ai_score`: the mean log
--   probability of its tokens, so near 0 is sure and far below is a guess
--   (ai_first in lua/plugins/completion.lua puts sure items first).

local M = {}

local MAX_LINES_PER_OUTPUT = 20
local MAX_LINES_TOTAL = 200

-- Chunk outputs in `buf` (lua/config/kernel/inline.lua), in buffer order:
-- { { row = closing-fence row (0-based), lines } }
local function chunk_outputs(buf)
  if not require("config.rmd-latex-hl").handles(buf) then
    return {}
  end
  local outputs = {}
  for _, o in ipairs(require("config.kernel.inline").outputs(buf)) do
    local lines = vim.tbl_map(function(l)
      return (l:gsub("%s+$", ""))
    end, o.lines)
    while #lines > 0 and lines[#lines] == "" do
      lines[#lines] = nil
    end
    if #lines > 0 then
      outputs[#outputs + 1] = { row = o.row, lines = vim.list_slice(lines, 1, MAX_LINES_PER_OUTPUT) }
    end
  end
  table.sort(outputs, function(a, b)
    return a.row < b.row
  end)
  return outputs
end

-- minuet's text before the cursor (`before`: the end of the buffer up to
-- the cursor, maybe cut at the start) with each chunk output in it inserted
-- after its chunk. Its last line is the cursor's row.
function M.with_outputs(before)
  local ok, outputs = pcall(chunk_outputs, vim.api.nvim_get_current_buf())
  if not ok or #outputs == 0 then
    return before
  end
  local parts = vim.split(before, "\n", { plain = true })
  local cursor_row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local first_row = cursor_row - #parts + 1
  local by_row = {}
  for _, o in ipairs(outputs) do
    by_row[o.row] = o
  end
  local out, total = {}, 0
  for i, part in ipairs(parts) do
    out[#out + 1] = part
    local o = i < #parts and by_row[first_row + i - 1]
    if o and total < MAX_LINES_TOTAL then
      local block = { "", "```" }
      for _, l in ipairs(o.lines) do
        block[#block + 1] = "## " .. l
      end
      vim.list_extend(block, { "```", "" })
      total = total + #block
      vim.list_extend(out, block)
    end
  end
  return table.concat(out, "\n")
end

-- How much text around the cursor goes in the prompt. minuet hands over the
-- whole buffer (its context_window is set past any file) and M.prompt /
-- M.suffix cut it, so that the start stays put while you type:
--
-- Ollama keeps the last prompt's state and only reads what changed after
-- the first differing token. Cutting a fixed number of characters before
-- the cursor (minuet's own way) moves the start one character per
-- keystroke, so nothing matched and every request read all ~2000 tokens
-- again: 3.8 s on qwen2.5-coder:7b. Starting on a line that's a multiple of
-- ANCHOR_LINES only moves now and then, and a keystroke costs just the end
-- of the line plus the text after the cursor (that's why it's short):
-- 0.4 s with 800 characters after the cursor, about half that with 400.
local BEFORE_CHARS = 6000
local AFTER_CHARS = 400
local ANCHOR_LINES = 16

-- minuet's FIM prompt (a "language: python" comment, then the text before
-- the cursor) from a fixed line, with the chunk outputs in it
function M.prompt(before, after, opts)
  local parts = vim.split(before, "\n", { plain = true })
  local cursor_row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local first_row = cursor_row - #parts + 1 -- buffer row of parts[1]
  -- characters from each row to the cursor
  local chars, total = {}, 0
  for i = #parts, 1, -1 do
    total = total + #parts[i] + 1
    chars[i] = total
  end
  local keep = #parts -- at least the cursor's line
  for i = 1, #parts do
    if (first_row + i - 1) % ANCHOR_LINES == 0 and chars[i] <= BEFORE_CHARS then
      keep = i
      break
    end
  end
  before = table.concat(parts, "\n", keep)
  local default = require("minuet.config").default_fim_template.prompt
  return default(M.with_outputs(before), after, opts)
end

-- The text after the cursor, cut at a line end
function M.suffix(_, after)
  if #after <= AFTER_CHARS then
    return after
  end
  local cut = after:sub(1, AFTER_CHARS)
  local last_nl = cut:match(".*()\n")
  return last_nl and cut:sub(1, last_nl) or cut
end

-- The model's confidence in a completion: mean log probability per token
-- ({ { token, logprob } } from Ollama's /api/generate with logprobs = true).
-- nil when the response has none.
local function mean_logprob(logprobs)
  if type(logprobs) ~= "table" then
    return nil
  end
  local sum, n = 0, 0
  for _, t in ipairs(logprobs) do
    if type(t) == "table" and type(t.logprob) == "number" then
      sum, n = sum + t.logprob, n + 1
    end
  end
  return n > 0 and sum / n or nil
end

-- Score of the response being handed to blink. minuet decodes a response
-- and calls the source's callback in the same tick, so get_text sets this
-- and get_completions below reads it straight after.
local last_score

-- get_text_fn for minuet's openai_fim_compatible backend, reading Ollama's
-- own /api/generate response (no streaming)
function M.get_text(json)
  last_score = mean_logprob(json.logprobs)
  return json.response
end

-- Request body for Ollama's /api/generate, from the OpenAI-style one minuet
-- builds (a transform in minuet's provider options). /api/generate rather
-- than the OpenAI-style /v1/completions because only it returns logprobs.
function M.ollama_body(model, options)
  return function(data)
    data.body = {
      model = model,
      prompt = data.body.prompt,
      suffix = data.body.suffix,
      stream = false,
      logprobs = true,
      -- keep the model loaded between bursts of typing (loading takes ~4 s)
      keep_alive = "30m",
      options = vim.tbl_extend("force", options, M.length()),
    }
    return data
  end
end

-- How long a completion may be. Each token takes ~40 ms on the 7B model,
-- so length is most of the wait once the prompt is cached:
--   * typing on a line (text before or after the cursor): the rest of
--     that line, up to LINE_TOKENS (~0.4 s)
--   * on an empty line: a few lines, up to BLOCK_TOKENS, ending at a blank
--     line (the base model goes on to the next function otherwise)
local LINE_TOKENS = 24
local BLOCK_TOKENS = 48
function M.length()
  if vim.api.nvim_get_current_line():match("%S") then
    return { num_predict = LINE_TOKENS, stop = { "\n" } }
  end
  return { num_predict = BLOCK_TOKENS, stop = { "\n\n" } }
end

-- Ollama ------------------------------------------------------------------

M.OLLAMA_URL = "http://localhost:11434"

-- Is Ollama answering? Checked in the background (never blocks typing) at
-- most every RECHECK_MS while it isn't. When it isn't running, start it
-- once: detached, so it outlives this Neovim and other sessions share it.
-- It stays up after Neovim quits (unloading the model after keep_alive).
local RECHECK_MS = 30000
local ollama = { up = false, checked = nil, checking = false, started = false }

local function check_ollama(on_done)
  ollama.checking = true
  vim.system({ "curl", "-s", "-m", "1", M.OLLAMA_URL .. "/api/version" }, { text = true }, function(out)
    ollama.checking = false
    ollama.checked = vim.uv.now()
    ollama.up = out.code == 0 and out.stdout:find("version", 1, true) ~= nil
    if on_done then
      vim.schedule(on_done) -- vim.fn isn't allowed in this callback
    end
  end)
end

function M.ollama_up()
  if ollama.up or ollama.checking then
    return ollama.up
  end
  if ollama.checked and vim.uv.now() - ollama.checked < RECHECK_MS then
    return false
  end
  check_ollama(function()
    if ollama.up or ollama.started or vim.fn.executable("ollama") == 0 then
      return
    end
    ollama.started = true
    local ok = pcall(vim.system, { "ollama", "serve" }, { detach = true, stdout = false, stderr = false })
    if ok then
      vim.defer_fn(function()
        check_ollama()
      end, 1500)
    end
  end)
  return false
end

-- blink source ---------------------------------------------------------------

local base = require("minuet.blink")

function M.new()
  return setmetatable(base.new(), { __index = M })
end

-- Only in real file buffers (not oil:///path/ and the like), and only once
-- Ollama answers: otherwise every keystroke would fail a request
function M:enabled()
  local buf = vim.api.nvim_get_current_buf()
  if vim.bo[buf].buftype ~= "" or vim.api.nvim_buf_get_name(buf):match("^%a[%w+.-]*://") then
    return false
  end
  return M.ollama_up() and base.enabled(self)
end

M.get_trigger_characters = base.get_trigger_characters

function M:get_completions(ctx, callback)
  last_score = nil
  return base.get_completions(self, ctx, function(response)
    if response and response.items then
      for _, item in ipairs(response.items) do
        item.ai_score = last_score
        item.kind_icon = "󰚩"
      end
    end
    last_score = nil
    callback(response)
  end)
end

return M
