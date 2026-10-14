return {
  {
    -- Mason packages stay in sync between machines:
    --  * every start, the LOCAL Neovim records what Mason has installed in
    --    ~/.config/nvim/mason-packages.json
    --  * every Neovim (including the remote-nvim server, which gets a copy of
    --    this config) installs anything from that file + the baseline below
    --    that is missing. Run :MasonSync to trigger it by hand.
    -- (mason.nvim itself ignores `ensure_installed`, hence this module.)
    "mason-org/mason.nvim",
    config = function()
      require("mason").setup({
        ui = {
          backdrop = 100, -- 100 = no dimming, same as lazy.nvim (dim-behind-float handles it)
          border = "rounded", -- match vim.o.winborder / the other floats
        },
      })

      -- Baseline: formatters + the servers enabled in this file (Mason names).
      -- julials / r_language_server / rustfmt / styler come from their own
      -- toolchains (Julia, R, rustup), not Mason.
      local baseline = {
        "stylua",
        "prettier",
        "clang-format",
        "google-java-format",
        "sqlfluff",
        "ruff",
        "goimports",
        "basedpyright",
        "rust-analyzer",
        "gopls",
        "typescript-language-server",
        "clangd",
        "lua-language-server",
        "jdtls",
        "sqls",
      }
      local state_file = vim.fn.stdpath("config") .. "/mason-packages.json"
      local registry = require("mason-registry")

      local function read_state()
        local f = io.open(state_file, "r")
        if not f then
          return {}
        end
        local txt = f:read("*a")
        f:close()
        local ok, list = pcall(vim.json.decode, txt)
        return (ok and type(list) == "table") and list or {}
      end

      local function write_state()
        if vim.g.remote_neovim_host then
          return
        end -- only the Mac is the source of truth
        local names = registry.get_installed_package_names()
        table.sort(names)
        local new = "[\n"
          .. table.concat(
            vim.tbl_map(function(n)
              return '  "' .. n .. '"'
            end, names),
            ",\n"
          )
          .. "\n]\n"
        local f = io.open(state_file, "r")
        local old = f and f:read("*a") or nil
        if f then
          f:close()
        end
        if old == new then
          return
        end
        local w = io.open(state_file, "w")
        if w then
          w:write(new)
          w:close()
        end
      end

      local function sync(notify)
        registry.refresh(function()
          local wanted, seen = {}, {}
          for _, n in ipairs(vim.list_extend(vim.deepcopy(baseline), read_state())) do
            if not seen[n] then
              seen[n] = true
              wanted[#wanted + 1] = n
            end
          end
          local started = 0
          for _, name in ipairs(wanted) do
            local ok, pkg = pcall(registry.get_package, name)
            if ok and not pkg:is_installed() and not pkg:is_installing() then
              started = started + 1
              pkg:install({}, function(success)
                if not success then
                  vim.schedule(function()
                    vim.notify("Mason: failed to install " .. name .. " (see :MasonLog)", vim.log.levels.WARN)
                  end)
                end
              end)
            end
          end
          if notify then
            vim.schedule(function()
              vim.notify(
                started > 0 and ("Mason: installing %d package(s)"):format(started)
                  or "Mason: everything already installed"
              )
            end)
          end
          write_state()
        end)
      end

      vim.api.nvim_create_user_command("MasonSync", function()
        sync(true)
      end, {
        desc = "Install Mason packages from mason-packages.json + baseline; record local installs",
      })
      -- Record installs made by hand (:Mason) so they sync next time.
      registry:on("package:install:success", vim.schedule_wrap(write_state))
      registry:on("package:uninstall:success", vim.schedule_wrap(write_state))

      sync(false)
    end,
  },

  {
    "neovim/nvim-lspconfig",
    config = function()
      vim.diagnostic.config({
        underline = { severity = vim.diagnostic.severity.ERROR },
        virtual_text = false,
        signs = true,
        update_in_insert = false,
      })

      vim.lsp.config("basedpyright", {
        settings = {
          basedpyright = {
            analysis = {
              typeCheckingMode = "recommended",
              diagnosticMode = "workspace",
            },
          },
        },
      })

      vim.lsp.config("lua_ls", {
        settings = {
          Lua = {
            diagnostics = { globals = { "vim" } },
            workspace = { checkThirdParty = false },
          },
        },
      })

      -- Suppress the harmless INVALID_SERVER_MESSAGE / -32800 "Request cancelled"
      -- error the R language server sends when Neovim cancels a pending request
      -- (e.g. pressing G right after opening a large Rmd). Only this specific error
      -- is dropped; any other server error is still reported.
      vim.lsp.config("r_language_server", {
        on_init = function(client)
          local function wrap(name)
            local orig = client[name]
            if type(orig) ~= "function" then
              return false
            end
            client[name] = function(self, code, err, ...)
              local cancelled = type(err) == "table" and type(err.error) == "table" and err.error.code == -32800
              if code == vim.lsp.rpc.client_errors.INVALID_SERVER_MESSAGE and cancelled then
                return -- drop the R server's malformed "request cancelled" reply
              end
              return orig(self, code, err, ...)
            end
            return true
          end
          if not wrap("write_error") then
            wrap("_write_error")
          end
        end,
      })

      -- Servers without settings above use nvim-lspconfig's defaults
      vim.lsp.enable({
        "basedpyright",
        "rust_analyzer",
        "gopls",
        "ts_ls",
        "clangd",
        "lua_ls",
        "r_language_server",
        "jdtls",
        "sqls",
        "julials",
      })
    end,
  },
}
