-- blink.cmp source: the value of the LaTeX arithmetic before an `=` in maths
-- (lua/plugins/completion.lua only enables it there). `$$\frac{1+1}{5} = `
-- offers 0.4, \frac{2}{5} and 0.400; `\frac{2}{3} = ` offers 0.667 and
-- 0.66666667. After `= \fbox{` the answer closes the box: 0.4}. Anything
-- with a variable or an unknown command in it offers nothing.

-- Spacing and sizing commands that don't change the value
local NOISE = { "\\left", "\\right", "\\displaystyle", "\\quad", "\\qquad", "\\,", "\\;", "\\:", "\\!" }

-- Boxes to fill in with the answer: `= \fbox{`
local BOXES = { fbox = true, boxed = true }

-- What ends the expression, looking back from the `=`
local DELIMITERS = { "$", "\\[", "\\(", "&", "\\\\", "=", "<", ">", "\\approx", "\\leq", "\\geq", "\\neq", "\\equiv" }

local function factorial(n)
  if n < 0 or n ~= math.floor(n) or n > 170 then
    error("factorial")
  end
  local r = 1
  for i = 2, n do
    r = r * i
  end
  return r
end

local FUNCTIONS = {
  sin = math.sin,
  cos = math.cos,
  tan = math.tan,
  arcsin = math.asin,
  arccos = math.acos,
  arctan = math.atan,
  sinh = function(x)
    return (math.exp(x) - math.exp(-x)) / 2
  end,
  cosh = function(x)
    return (math.exp(x) + math.exp(-x)) / 2
  end,
  tanh = function(x)
    return (math.exp(x) - math.exp(-x)) / (math.exp(x) + math.exp(-x))
  end,
  exp = math.exp,
  ln = math.log,
  log = math.log10,
}

-- Commands that start a value, so `2\pi` and `3\sqrt{2}` multiply
local VALUE_COMMANDS = { frac = true, dfrac = true, tfrac = true, cfrac = true, sqrt = true, binom = true, pi = true }
for name in pairs(FUNCTIONS) do
  VALUE_COMMANDS[name] = true
end

-- Recursive-descent parser over the string itself (LaTeX arguments are
-- single characters unless braced: `2^10` is 2^1 * 0). Errors on anything it
-- doesn't know; eval() turns that into nil.
local function evaluate(s)
  local pos = 1

  local function skip()
    pos = s:find("%S", pos) or #s + 1
  end
  local function peek()
    skip()
    return s:sub(pos, pos)
  end
  local function command_at()
    skip()
    return s:match("^\\(%a+)", pos)
  end
  local function expect(ch)
    if peek() ~= ch then
      error("expected " .. ch)
    end
    pos = pos + 1
  end

  local expr, power

  local function group(close)
    pos = pos + 1
    local v = expr()
    expect(close)
    return v
  end

  -- A macro argument: {…}, one digit, or one command (\pi)
  local function arg()
    local c = peek()
    if c == "{" then
      return group("}")
    elseif c:match("%d") then
      pos = pos + 1
      return tonumber(c)
    end
    return power()
  end

  -- Argument of \sin, \ln, …: (…), {…} or what follows up to the next operator
  local function func_arg()
    local c = peek()
    if c == "(" then
      return group(")")
    elseif c == "{" then
      return group("}")
    end
    return power()
  end

  local function command()
    local name = command_at()
    if not name then
      error("command")
    end
    pos = pos + #name + 1
    if name == "frac" or name == "dfrac" or name == "tfrac" or name == "cfrac" then
      local a = arg()
      return a / arg()
    elseif name == "sqrt" then
      local n = 2
      if peek() == "[" then
        n = group("]")
      end
      return arg() ^ (1 / n)
    elseif name == "binom" then
      local n, k = arg(), arg()
      return factorial(n) / (factorial(k) * factorial(n - k))
    elseif name == "pi" then
      return math.pi
    elseif name == "log" and peek() == "_" then
      pos = pos + 1
      local base = arg()
      return math.log(func_arg()) / math.log(base)
    elseif FUNCTIONS[name] then
      return FUNCTIONS[name](func_arg())
    end
    error("unknown command " .. name)
  end

  local function primary()
    local c = peek()
    if c:match("[%d.]") then
      local num = s:match("^%d*%.?%d*", pos)
      pos = pos + #num
      return tonumber(num) or error("number")
    elseif c == "(" then
      return group(")")
    elseif c == "[" then
      return group("]")
    elseif c == "{" then
      return group("}")
    elseif c == "|" then
      return math.abs(group("|"))
    elseif c == "\\" then
      return command()
    elseif c == "e" and not s:sub(pos + 1, pos + 1):match("%a") then
      pos = pos + 1
      return math.exp(1)
    end
    error("unexpected " .. c)
  end

  local function postfix()
    local v = primary()
    while peek() == "!" do
      pos = pos + 1
      v = factorial(v)
    end
    return v
  end

  function power()
    local v = postfix()
    if peek() == "^" then
      pos = pos + 1
      v = v ^ arg()
    end
    return v
  end

  local function unary()
    local c = peek()
    if c == "-" then
      pos = pos + 1
      return -unary()
    elseif c == "+" then
      pos = pos + 1
      return unary()
    end
    return power()
  end

  local function term()
    local v = unary()
    while true do
      local c, name = peek(), command_at()
      if c == "*" or name == "cdot" or name == "times" or name == "ast" then
        pos = pos + (name and #name + 1 or 1)
        v = v * unary()
      elseif c == "/" or name == "div" then
        pos = pos + (name and #name + 1 or 1)
        v = v / unary()
      elseif c == "(" or c == "[" or c == "{" or (name and VALUE_COMMANDS[name]) or c == "e" then
        v = v * power() -- implicit: 2\pi, 2(3+1), (1+2)(3)
      else
        return v
      end
    end
  end

  function expr()
    local v = term()
    while true do
      local c = peek()
      if c == "+" then
        pos = pos + 1
        v = v + term()
      elseif c == "-" then
        pos = pos + 1
        v = v - term()
      else
        return v
      end
    end
  end

  local v = expr()
  skip()
  if pos <= #s then
    error("trailing " .. s:sub(pos))
  end
  return v
end

local source = {}

-- Value of a LaTeX expression, or nil if it isn't plain arithmetic
function source._eval(s)
  for _, noise in ipairs(NOISE) do
    if noise:match("%a$") then
      -- not when it's the start of a longer command (\quad vs \quadrant)
      s = s:gsub(vim.pesc(noise) .. "(%A)", "%1"):gsub(vim.pesc(noise) .. "$", "")
    else
      s = s:gsub(vim.pesc(noise), " ")
    end
  end
  local ok, v = pcall(evaluate, s)
  if ok and type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge then
    return v
  end
end

-- Expression between the last delimiter and the `=` before the cursor, and
-- the box being filled in, if any (`= \fbox{`)
local function expression_before(before)
  local lhs, box = before:match("^(.*)=%s*\\(%a+){%s*$")
  if not BOXES[box] then
    lhs, box = before:match("^(.*)=%s*$"), nil
  end
  if not lhs then
    return nil
  end
  local start = 1
  for _, d in ipairs(DELIMITERS) do
    local from = 1
    while true do
      local _, e = lhs:find(d, from, true)
      if not e then
        break
      end
      start = math.max(start, e + 1)
      from = e + 1
    end
  end
  local text = vim.trim(lhs:sub(start))
  if text ~= "" then
    return text, box
  end
end

-- p, q with p/q == v and q <= 1000, if there are any
local function as_fraction(v)
  local x, h0, h1, k0, k1 = math.abs(v), 0, 1, 1, 0
  for _ = 1, 20 do
    local a = math.floor(x)
    h0, h1 = h1, a * h1 + h0
    k0, k1 = k1, a * k1 + k0
    if k1 > 1000 then
      return nil
    end
    if math.abs(h1 / k1 - math.abs(v)) < 1e-9 * math.max(1, math.abs(v)) then
      return (v < 0 and -h1 or h1), k1
    end
    if x - a < 1e-12 then
      return nil
    end
    x = 1 / (x - a)
  end
end

-- v rounded to `decimals` places, trailing zeros dropped (0.400 -> 0.4).
-- Values that would round to 0 (or are huge) get significant digits instead,
-- written as 1.5 \times 10^{-5} when %g uses an exponent.
local function rounded(v, decimals)
  local text
  if math.abs(v) >= 1e15 or (v ~= 0 and math.abs(v) < 0.5 * 10 ^ -decimals) then
    text = string.format("%." .. decimals .. "g", v)
  else
    text = string.format("%." .. decimals .. "f", v)
  end
  if not text:find("e") and text:find("%.") then
    text = text:gsub("0+$", ""):gsub("%.$", "")
  end
  if text == "-0" then
    text = "0"
  end
  local mantissa, exponent = text:match("^(.-)e([-+]%d+)$")
  if mantissa then
    mantissa = mantissa:find("%.") and mantissa:gsub("0+$", ""):gsub("%.$", "") or mantissa
    return string.format("%s \\times 10^{%d}", mantissa, tonumber(exponent))
  end
  return text
end

-- Is `text` (a plain decimal) exactly v?
local function exact(text, v)
  local n = tonumber(text)
  return n ~= nil and math.abs(n - v) < 1e-9 * math.max(1, math.abs(v))
end

-- What to offer for v, best first:
--   rounded to 3 decimals                          0.4    0.667
--   the fraction, if v is one                      \frac{2}{5}
--   0.400 when that is exact, else 8 decimals      0.400  0.66666667
-- Each is left out when it only repeats the expression or an earlier one.
local function answers(v, text)
  local out, seen = {}, { [text:gsub("%s", "")] = true }
  local function add(answer)
    if not seen[answer:gsub("%s", "")] then
      seen[answer:gsub("%s", "")] = true
      out[#out + 1] = answer
    end
  end
  local short = rounded(v, 3)
  add(short)
  if exact(short, v) and not short:find("%.") then
    return out -- an integer
  end
  local p, q = as_fraction(v)
  if p and q > 1 then
    add(("%s\\frac{%d}{%d}"):format(p < 0 and "-" or "", math.abs(p), q))
  end
  if exact(short, v) then
    add(string.format("%.3f", v))
  else
    add(rounded(v, 8))
  end
  return out
end

function source.new()
  return setmetatable({}, { __index = source })
end

function source:get_trigger_characters()
  -- `}` too: autopairs types `{}`, and blink sees the last character
  return { "=", " ", "{", "}" }
end

function source:get_completions(ctx, callback)
  local col = ctx.cursor[2]
  local before = ctx.line:sub(1, col)
  local text, box = expression_before(before)
  local v = text and source._eval(text)
  local items = {}
  if v then
    local kinds = require("blink.cmp.types").CompletionItemKind
    local space = before:sub(-1) == "=" and " " or ""
    -- close the \fbox{ unless autopairs already did
    local close = box and ctx.line:sub(col + 1, col + 1) ~= "}" and "}" or ""
    local cursor = { line = ctx.cursor[1] - 1, character = col }
    for i, answer in ipairs(answers(v, text)) do
      items[i] = {
        label = answer,
        filterText = answer,
        kind = kinds.Value,
        -- Keep this order: 10 apart, so the bonus blink gives items you
        -- picked recently (up to 6) or words nearby (2) can't reorder them
        sortText = tostring(i),
        score_offset = -10 * (i - 1),
        textEdit = { newText = space .. answer .. close, range = { start = cursor, ["end"] = cursor } },
        documentation = { kind = "markdown", value = ("`%s = %s`"):format(text, answer) },
      }
    end
  end
  callback({ items = items, is_incomplete_forward = true, is_incomplete_backward = true })
end

return source
