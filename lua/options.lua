require "nvchad.options"

-- Normal/visual mode puts the cursor *on* a character, so the last valid column
-- is the final glyph -- a motion can never park "at the end of the line" the way
-- it does in insert mode, where the cursor sits in the gap and column len+1
-- exists. `onemore` allows that column outside insert mode too, so the same
-- keypress lands in the same place regardless of mode.
-- (:h 'virtualedit' -- `onemore` is a real setting, but a few operators and
-- plugins assume the classic invariant.)
vim.opt.virtualedit = "onemore"

-- ctags: look for `tags` next to the current file, walking up to the project
-- root (`;`), then fall back to `tags` in the cwd. This is what lets nvim-cmp
-- suggest functions from *every* file in the directory (via cmp-nvim-tags).
vim.opt.tags = "./tags;tags"
