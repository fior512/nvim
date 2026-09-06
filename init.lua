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

-- ANSI colors for :terminal, matched to cyberdream_custom's hue roles.
-- base46 "term" reads base_16, which this theme recolors for syntax
-- fixups (see themes/cyberdream_custom.lua:43), so it can't drive this.
local term_colors = {
  "#040404", "#ff6e5e", "#5eff6c", "#f1ff5e",
  "#b5a494", "#b28aa4", "#6ca5a0", "#dcdcd4",
  "#5c5a46", "#ff6e5e", "#5eff6c", "#ffbd5e",
  "#b5a494", "#ecd3a0", "#6ca5a0", "#ffffff",
}
for i, hex in ipairs(term_colors) do
  vim.g["terminal_color_" .. (i - 1)] = hex
end

require "options"
require "autocmds"

vim.schedule(function()
  require "mappings"
end)
