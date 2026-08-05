require "nvchad.mappings"

-- add yours here

local map = vim.keymap.set

map("n", ";", ":", { desc = "CMD enter command mode" })
map("i", "jk", "<ESC>")

local function bounded_word_motion(forward)
  local cur_line = vim.fn.line(".")
  vim.cmd(forward and "normal! w" or "normal! b")
  local new_line = vim.fn.line(".")
  if new_line ~= cur_line then
    -- undo the line jump: go back and snap to end/start of original line
    vim.fn.cursor(cur_line, forward and vim.fn.col("$") - 1 or 1)
  end
end

vim.keymap.set({ "n", "v" }, "<S-Right>", function() bounded_word_motion(true) end)
vim.keymap.set({ "n", "v" }, "<S-Left>", function() bounded_word_motion(false) end)

-- Resize the focused window. Bound in both n and t mode: a terminal buffer
-- (e.g. overseer's task pane) in terminal-mode never sees a normal-mode-only
-- mapping, keys go straight to the pty instead.
map({ "n", "t" }, "<C-Up>", "<cmd>resize -3<cr>", { desc = "Resize window shorter" })
map({ "n", "t" }, "<C-Down>", "<cmd>resize +3<cr>", { desc = "Resize window taller" })
map({ "n", "t" }, "<C-Left>", "<cmd>vertical resize -3<cr>", { desc = "Resize window narrower" })
map({ "n", "t" }, "<C-Right>", "<cmd>vertical resize +3<cr>", { desc = "Resize window wider" })


-- Overseer: compile / run / perf / valgrind / clang-tidy / rr task runner
map("n", "<leader>oo", function()
  require("configs.overseer").telescope_run()
end, { desc = "Overseer pick & run task (telescope)" })
map("n", "<leader>ot", "<cmd>OverseerToggle<cr>", { desc = "Overseer toggle task list" })
-- Picks a task then an action: open/open float/open hsplit/open vsplit/open
-- tab reopens a task's output in a different window.
map("n", "<leader>oa", "<cmd>OverseerTaskAction<cr>", { desc = "Overseer pick task + action (e.g. open in split)" })
map("n", "<leader>oi", "<cmd>OverseerInfo<cr>", { desc = "Overseer info / debug" })
