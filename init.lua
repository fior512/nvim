vim.g.base46_cache = vim.fn.stdpath "data" .. "/base46/"
vim.g.mapleader = " "

local lazypath = vim.fn.stdpath "data" .. "/lazy/lazy.nvim"

if not vim.uv.fs_stat(lazypath) then
  local repo = "https://github.com/folke/lazy.nvim.git"
  vim.fn.system { "git", "clone", "--filter=blob:none", repo, "--branch=stable", lazypath }
end

vim.opt.rtp:prepend(lazypath)

local lazy_config = require "configs.lazy"

require("lazy").setup({
  {
    "NvChad/NvChad",
    lazy = false,
    branch = "v2.5",
    import = "nvchad.plugins",
  },

  { import = "plugins" },
}, lazy_config)

-- loads all base46 groups; overridden plugin specs skip their own dofile
require("nvchad.base46").load {
  "blankline",
  "blink",
  "cmp",
  "defaults",
  "devicons",
  "git",
  "lsp",
  "mason",
  "nvcheatsheet",
  "nvimtree",
  "statusline",
  "syntax",
  "treesitter",
  "tbline",
  "telescope",
  "whichkey",
}

-- must exist before snacks.image reads it once, on first load
vim.api.nvim_set_hl(0, "SnacksImageMath", { fg = "#ecd3a0" })

require "options"
require "autocmds"

vim.schedule(function()
  require "mappings"
end)
