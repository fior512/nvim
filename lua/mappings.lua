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


-- Overseer: compile / run / perf / valgrind / clang-tidy / rr task runner
map("n", "<leader>oo", function()
  require("configs.overseer").telescope_run()
end, { desc = "Overseer pick & run task (telescope)" })
map("n", "<leader>ot", "<cmd>OverseerToggle<cr>", { desc = "Overseer toggle task list" })
map("n", "<leader>oa", "<cmd>OverseerQuickAction<cr>", { desc = "Overseer quick action on recent task" })
map("n", "<leader>oi", "<cmd>OverseerInfo<cr>", { desc = "Overseer info / debug" })
