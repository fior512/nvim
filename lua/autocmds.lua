require "nvchad.autocmds"

-- dims inactive #if/#else branches, distinct from real comments
local function fix_lsp_comment_hl()
  vim.api.nvim_set_hl(0, "@lsp.type.comment", { fg = "#726d64", italic = false })
end
fix_lsp_comment_hl()
vim.api.nvim_create_autocmd("User", {
  pattern = "NvThemeReload",
  callback = fix_lsp_comment_hl,
})

-- restores real comments inside dimmed inactive branches
vim.api.nvim_create_autocmd("LspTokenUpdate", {
  callback = function(ev)
    local token = ev.data.token
    if token.type ~= "comment" then
      return
    end

    local node = vim.treesitter.get_node {
      bufnr = ev.buf,
      pos = { token.line, token.start_col },
    }
    local is_real_comment = false
    while node do
      if node:type() == "comment" then
        is_real_comment = true
        break
      end
      node = node:parent()
    end

    if is_real_comment then
      vim.lsp.semantic_tokens.highlight_token(token, ev.buf, ev.data.client_id, "Comment")
    end
  end,
})

vim.api.nvim_create_autocmd("LspAttach", {
  callback = function(args)
    local client = vim.lsp.get_client_by_id(args.data.client_id)
    -- gopls hints crash on multi-byte lines (nvim bug)
    if client and client.name ~= "gopls" and client:supports_method("textDocument/inlayHint") then
      vim.lsp.inlay_hint.enable(true, { bufnr = args.buf })
    end
  end,
})
