-- Project Python environment helpers, shared by the LSP config (basedpyright's
-- interpreter), molten (<localleader>mi) and notebook knitting (<localleader>kk).
--
-- The project's Python is $VIRTUAL_ENV if one is active, otherwise the nearest
-- .venv above the file. Its Jupyter kernel is registered on first use as
-- "<project-dir>-venv" (needs `pip install ipykernel` in that venv).

local M = {}

local JUPYTER = vim.fn.expand("~/.venvs/nvim/bin/jupyter")

-- Python interpreter of the project containing `path` (a file or directory),
-- and the project root. nil if there is no venv.
function M.project_python(path)
  local venv = vim.env.VIRTUAL_ENV
  if venv and venv ~= "" and vim.fn.executable(venv .. "/bin/python") == 1 then
    return venv .. "/bin/python", vim.fs.dirname(venv)
  end
  if not path or path == "" then
    path = vim.fn.getcwd()
  end
  local root = vim.fs.root(path, ".venv")
  if root and vim.fn.executable(root .. "/.venv/bin/python") == 1 then
    return root .. "/.venv/bin/python", root
  end
end

local specs_cache

-- Installed Jupyter kernels, as { [name] = language } with the language
-- lowercased ("python", "r", ...). Cached; pass `refresh` to re-read.
function M.kernelspecs(refresh)
  if specs_cache and not refresh then
    return specs_cache
  end
  local jupyter = vim.fn.executable(JUPYTER) == 1 and JUPYTER or "jupyter"
  if vim.fn.executable(jupyter) ~= 1 then
    return {}
  end
  local r = vim.system({ jupyter, "kernelspec", "list", "--json" }, { text = true }):wait()
  local ok, data = pcall(vim.json.decode, r.stdout or "")
  local specs = {}
  if ok and type(data) == "table" and type(data.kernelspecs) == "table" then
    for name, k in pairs(data.kernelspecs) do
      local lang = type(k) == "table" and type(k.spec) == "table" and k.spec.language or ""
      specs[name] = type(lang) == "string" and lang:lower() or ""
    end
  end
  specs_cache = specs
  return specs
end

-- kernelspec name stored in a notebook's metadata, if any.
local function notebook_kernel(file)
  if not file:match("%.ipynb$") or vim.fn.filereadable(file) ~= 1 then
    return nil
  end
  local ok, nb = pcall(vim.json.decode, table.concat(vim.fn.readfile(file), "\n"))
  if ok and type(nb) == "table" and type(nb.metadata) == "table" and type(nb.metadata.kernelspec) == "table" then
    return nb.metadata.kernelspec.name
  end
end

-- Name of the Jupyter kernel to use for Python in buffer `buf`, registering
-- the project venv as a kernel if needed. nil if nothing suitable was found
-- (the caller then lets molten ask).
function M.kernel(buf)
  local file = vim.api.nvim_buf_get_name(buf or 0)
  local kernels = M.kernelspecs(true)

  local python, root = M.project_python(file ~= "" and vim.fs.dirname(file) or nil)
  local nb = notebook_kernel(file)

  -- The notebook's own kernel wins, unless it is the generic "python3" and a
  -- project venv exists (then the venv is almost certainly what's meant).
  if nb and kernels[nb] and not (nb == "python3" and python) then
    return nb
  end

  if python then
    local name = (vim.fs.basename(root):lower():gsub("[^%w_.-]", "-")) .. "-venv"
    if kernels[name] then
      return name
    end
    local check = vim.system({ python, "-c", "import ipykernel" }):wait()
    if check.code ~= 0 then
      vim.notify(
        ("No ipykernel in %s\nRun: %s -m pip install ipykernel"):format(vim.fs.dirname(vim.fs.dirname(python)), python),
        vim.log.levels.ERROR
      )
      return nil
    end
    local display = vim.fs.basename(root) .. " (.venv)"
    local r = vim
      .system({ python, "-m", "ipykernel", "install", "--user", "--name", name, "--display-name", display }, { text = true })
      :wait()
    if r.code ~= 0 then
      vim.notify("Registering kernel " .. name .. " failed:\n" .. (r.stderr or ""), vim.log.levels.ERROR)
      return nil
    end
    M.kernelspecs(true)
    vim.notify("Registered Jupyter kernel " .. name)
    return name
  end

  if nb and kernels[nb] then
    return nb
  end
  if kernels.python3 then
    return "python3"
  end
end

return M
