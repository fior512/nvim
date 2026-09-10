require "nvchad.mappings"

local map = vim.keymap.set

-- frees <C-s> for clangd signature-help cycling
vim.keymap.del("n", "<C-s>")

map("n", ";", ":", { desc = "CMD enter command mode" })
map("i", "jk", "<ESC>")

-- keeps w/b motion inside current line
local function bounded_word_motion(forward)
  local cur_line = vim.fn.line(".")
  -- measured before motion crosses lines
  local eol = #vim.fn.getline(cur_line)
  vim.cmd(forward and "normal! w" or "normal! b")
  if vim.fn.line(".") ~= cur_line then
    -- needs virtualedit=onemore (options.lua)
    vim.fn.cursor(cur_line, forward and eol + 1 or 1)
  end
end

-- insert mode only; <C-Right/Left> stay window-resize elsewhere
map({ "n", "x", "i" }, "<S-Right>", function() bounded_word_motion(true) end, { desc = "Word right, stop at end of line" })
map({ "n", "x", "i" }, "<S-Left>", function() bounded_word_motion(false) end, { desc = "Word left, stop at start of line" })
map("i", "<C-Right>", function() bounded_word_motion(true) end, { desc = "Word right, stop at end of line" })
map("i", "<C-Left>", function() bounded_word_motion(false) end, { desc = "Word left, stop at start of line" })

-- Tab indents; buffer cycling moved to <S-h>/<S-l>
map("n", "<Tab>", ">>", { desc = "Indent line" })
map("n", "<S-Tab>", "<<", { desc = "Unindent line" })
map("x", "<Tab>", ">gv", { desc = "Indent selection" })
map("x", "<S-Tab>", "<gv", { desc = "Unindent selection" })

-- saves/restores view around gg=G reindent
map("n", "<leader>=", function()
  local view = vim.fn.winsaveview()
  vim.cmd "normal! gg=G"
  vim.fn.winrestview(view)
end, { desc = "Re-indent whole file, keep cursor/scroll position" })

map("n", "<S-l>", function()
  require("nvchad.tabufline").next()
end, { desc = "Buffer goto next" })
map("n", "<S-h>", function()
  require("nvchad.tabufline").prev()
end, { desc = "Buffer goto prev" })

-- resize moved to smart-splits.nvim on <A-arrows>, see plugins/init.lua
-- frees <C-Left/Right> in terminal mode for the shell's own word motion

-- fuzzy keymap search by key or desc
map("n", "<leader>fk", "<cmd>Telescope keymaps<cr>", { desc = "telescope find keymaps" })

-- Overseer: compile / run / perf / valgrind / clang-tidy / rr task runner
map("n", "<leader>oo", function()
  require("configs.overseer").telescope_run()
end, { desc = "Overseer pick & run task (telescope)" })
map("n", "<leader>ot", "<cmd>OverseerToggle<cr>", { desc = "Overseer toggle task list" })
-- picks task, then reopen action
map("n", "<leader>oa", "<cmd>OverseerTaskAction<cr>", { desc = "Overseer pick task + action (e.g. open in split)" })
map("n", "<leader>oi", "<cmd>OverseerInfo<cr>", { desc = "Overseer info / debug" })

map("n", "<leader>uh", function()
  vim.lsp.inlay_hint.enable(not vim.lsp.inlay_hint.is_enabled())
end, { desc = "Toggle inlay hints (auto type hints)" })

map("n", "<leader>uc", function()
  require("utils.const_fold").toggle(0)
end, { desc = "Toggle constant-expression fold hints" })

-- toggles markdown split preview; tex uses its own <leader>mv
map("n", "<leader>mv", "<cmd>Markview splitToggle<cr>", { desc = "Toggle markdown split preview" })

-- gitsigns ships no default keymaps, only sign glyphs
map("n", "]h", function()
  require("gitsigns").nav_hunk("next")
end, { desc = "Next git hunk" })
map("n", "[h", function()
  require("gitsigns").nav_hunk("prev")
end, { desc = "Prev git hunk" })
map("n", "<leader>gp", function()
  require("gitsigns").preview_hunk()
end, { desc = "Preview git hunk diff (floating)" })
map("n", "<leader>gs", function()
  require("gitsigns").stage_hunk()
end, { desc = "Stage git hunk" })
map("n", "<leader>gr", function()
  require("gitsigns").reset_hunk()
end, { desc = "Reset git hunk" })
map("n", "<leader>gb", function()
  require("gitsigns").blame_line { full = true }
end, { desc = "Blame current line (full)" })
