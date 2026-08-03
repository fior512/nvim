require("nvchad.configs.lspconfig").defaults()

local servers = { "html", "cssls", "clangd", "ts_ls", "marksman", "julials" }
vim.lsp.enable(servers)

-- per-server overrides go here using vim.lsp.config()
-- read :h vim.lsp.config for changing options of lsp servers

vim.lsp.config("clangd", {
  cmd = { "clangd", "--offset-encoding=utf-16" }, -- avoids a common encoding warning with some clients
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
