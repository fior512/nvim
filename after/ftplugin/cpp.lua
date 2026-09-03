vim.bo.smartindent = false
vim.bo.indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"

-- clang-format falls back to LLVM style (2-space)
vim.bo.tabstop = 2
vim.bo.shiftwidth = 2
vim.bo.softtabstop = 2
vim.bo.expandtab = true

require("utils.const_fold").enable(0)
