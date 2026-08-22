require "nvchad.autocmds"

-- clangd tags the body of inactive #if/#else preprocessor branches as an
-- LSP semantic token of type "comment" (@lsp.type.comment), which base46's
-- semantic_tokens integration links straight to Comment. hl_override in
-- chadrc.lua can't break that link (it deep-merges on top, so the old
-- `link = "Comment"` survives and wins over any fg we add), so fix it here
-- instead: dimmed like disabled code, but not italic/olive like real
-- comments, so inactive branches stay readable and distinguishable from
-- comments. Applied once at startup (this file loads after init.lua's
-- dofile of the compiled theme) and again on every :NvChadTheme reload.
local function fix_lsp_comment_hl()
  vim.api.nvim_set_hl(0, "@lsp.type.comment", { fg = "#726d64", italic = false })
end
fix_lsp_comment_hl()
vim.api.nvim_create_autocmd("User", {
  pattern = "NvThemeReload",
  callback = fix_lsp_comment_hl,
})

-- clangd's inactive-region "comment" token also covers real // and /* */
-- comments that happen to sit inside the disabled branch, so they'd get
-- swept into the dimmed @lsp.type.comment color above too. Catch those and
-- re-highlight them back to the real Comment group (higher priority wins
-- over the default token mark) so actual comments keep their true color
-- everywhere, active branch or not -- only genuinely-disabled code gets
-- dimmed.
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
    if client and client:supports_method("textDocument/inlayHint") then
      vim.lsp.inlay_hint.enable(true, { bufnr = args.buf })
    end
  end,
})
