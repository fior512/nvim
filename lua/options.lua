require "nvchad.options"

-- indent width set per filetype, see after/ftplugin/*.lua

-- lets cursor reach the end-of-line column outside insert mode
vim.opt.virtualedit = "onemore"

-- search tags file upward from cwd to project root
vim.opt.tags = "./tags;tags"
