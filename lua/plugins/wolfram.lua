-- Wolfram Language support
--
-- Architecture:
--   * Filetype detection for .wl / .wls unconditionally, .m via content sniff.
--   * LSP via the official Wolfram LSPServer paclet, launched as a
--     kernel-run server over stdio (not a Mason-managed binary).
--   * Tree-sitter highlighting via LumaKernel/tree-sitter-wolfram. The
--     parser's highlights.scm lives at queries/wolfram/highlights.scm under
--     this config so it stays on the runtimepath independently of the
--     parser install.
--   * Project-local package discovery: if a sibling `middleware/` directory
--     exists next to the detected root, it is prepended to $Path before
--     StartServer[] runs.

-- 1. Filetype detection -------------------------------------------------------

vim.filetype.add({
  extension = {
    wl = "wolfram",
    wls = "wolfram",
    -- .m is ambiguous (MATLAB / Objective-C / Mathematica). Only claim it
    -- when the file has a clear Mathematica package marker; otherwise defer
    -- to Neovim's default detection.
    m = function(_path, bufnr)
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, 10, false)
      for _, line in ipairs(lines) do
        if line:match("BeginPackage%s*%[") or line:match("::Package::") then
          return "wolfram"
        end
      end
      return nil
    end,
  },
})

local function build_cmd(middleware_path)
  local run_expr
  if middleware_path then
    run_expr = string.format(
      'PrependTo[$Path, "%s"]; Needs["LSPServer`"]; LSPServer`StartServer[]',
      middleware_path
    )
  else
    run_expr = 'Needs["LSPServer`"]; LSPServer`StartServer[]'
  end
  return {
    "WolframKernel",
    "-noinit",
    "-noprompt",
    "-nopaclet",
    "-nostartuppaclets",
    "-noicon",
    "-run",
    run_expr,
  }
end

return {
  -- 2. Tree-sitter parser (custom, not in nvim-treesitter's registry) ---------
  --
  -- LazyVim uses the `main` branch of nvim-treesitter (v2). The parser
  -- table is keyed directly by language name; install_info is just url +
  -- revision. The filetype <-> language mapping is handled by Neovim core,
  -- which looks up the parser by filetype name by default.
  {
    "nvim-treesitter/nvim-treesitter",
    opts = function(_, opts)
      -- nvim-treesitter's install.lua calls reload_parsers() which wipes
      -- the cached parsers module before consulting it. It fires a
      -- `User TSUpdate` event on reload — re-register on that event so our
      -- entry survives every reload.
      local function register()
        require("nvim-treesitter.parsers").wolfram = {
          install_info = {
            url = "https://github.com/LumaKernel/tree-sitter-wolfram",
            revision = "ab3506a5b49b7d76a8ed06958d0b2b7be91a5d34",
          },
        }
      end
      register()
      vim.api.nvim_create_autocmd("User", {
        group = vim.api.nvim_create_augroup("WolframTSRegister", { clear = true }),
        pattern = "TSUpdate",
        callback = register,
      })
      opts.ensure_installed = opts.ensure_installed or {}
      if type(opts.ensure_installed) == "table" then
        table.insert(opts.ensure_installed, "wolfram")
      end
    end,
  },

  -- 3. LSP --------------------------------------------------------------------
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        wolfram = {
          cmd = build_cmd(nil),
          filetypes = { "wolfram" },
          root_dir = function(fname)
            local util = require("lspconfig.util")
            return util.root_pattern("middleware", ".git")(fname)
              or vim.fs.dirname(fname)
          end,
          single_file_support = true,
          on_new_config = function(new_config, new_root_dir)
            if not new_root_dir then
              return
            end
            local middleware = new_root_dir .. "/middleware"
            if vim.uv.fs_stat(middleware) then
              new_config.cmd = build_cmd(middleware)
            end
          end,
          -- LSPServer returns semanticTokensProvider as JSON null, which
          -- nvim 0.12's semantic-tokens client tries to index and crashes
          -- on. Null the capability out before it's touched.
          on_attach = function(client, _bufnr)
            client.server_capabilities.semanticTokensProvider = nil
          end,
        },
      },
      setup = {
        -- wolfram is not in nvim-lspconfig's registry, so register it
        -- ourselves before LazyVim calls lspconfig.wolfram.setup.
        wolfram = function(_, opts)
          local configs = require("lspconfig.configs")
          if not configs.wolfram then
            configs.wolfram = {
              default_config = {
                cmd = opts.cmd,
                filetypes = opts.filetypes,
                root_dir = opts.root_dir,
                single_file_support = opts.single_file_support,
              },
              docs = {
                description = "Wolfram Language LSP via the LSPServer paclet",
              },
            }
          end
          require("lspconfig").wolfram.setup(opts)
          return true
        end,
      },
    },
  },
}
