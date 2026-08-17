require("nvchad.configs.lspconfig").defaults()

local servers = { "html", "cssls", "clangd", "ts_ls", "marksman", "julials" }
vim.lsp.enable(servers)

vim.lsp.config("clangd", {
  cmd = {
    "clangd",
    "--offset-encoding=utf-16", -- avoids a common encoding warning with some clients
    "--background-index", -- index the whole project, not just open buffers
    "--all-scopes-completion", -- suggest symbols not yet visible in scope
    "--header-insertion=iwyu", -- auto-insert #include when accepting such a completion
    "--completion-style=detailed",
  },
  settings = {
    clangd = {
      InlayHints = {
        -- clangd >= 16: the `--inlay-hints` CLI flag is obsolete/ignored,
        -- inlay hints are configured through LSP settings (or a .clangd file).
        Enabled = "Yes",        -- master switch for inlay hints
        DeducedTypes = "Yes",   -- show the REAL type of `auto` vars, e.g. `auto x: int = 1;`
        ParameterNames = "Yes", -- show parameter names in function calls
      },
    },
  },
})

vim.lsp.config("julials", {
  cmd = { "julia", "--startup-file=no", "--history-file=no", "-e", "using LanguageServer; runserver()" },
})


vim.lsp.config("ts_ls", {
  settings = {
    typescript = {
      inlayHints = {
        includeInlayParameterNameHints = "all",
        includeInlayFunctionParameterTypeHints = true,
        includeInlayVariableTypeHints = true,
        includeInlayFunctionLikeReturnTypeHints = true,
        includeInlayEnumMemberValueHints = true,
      },
    },
    javascript = {
      inlayHints = {
        includeInlayParameterNameHints = "all",
        includeInlayFunctionParameterTypeHints = true,
        includeInlayVariableTypeHints = true,
      },
    },
  },
})
