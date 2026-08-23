vim.bo.smartindent = false
vim.bo.indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"

require("utils.const_fold").enable(0)
