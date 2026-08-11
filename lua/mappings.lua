require "nvchad.mappings"

local map = vim.keymap.set

map("n", ";", ":", { desc = "CMD enter command mode" })
map("i", "jk", "<ESC>")

-- `w`/`b` cross line boundaries by design. These keep the motion inside the
-- current line and park on its edge instead of wrapping.
local function bounded_word_motion(forward)
  local cur_line = vim.fn.line(".")
  -- Measured *before* the motion: once `w` has crossed onto the next line,
  -- col("$") reports that line's length, not the one we started on.
  local eol = #vim.fn.getline(cur_line)
  vim.cmd(forward and "normal! w" or "normal! b")
  if vim.fn.line(".") ~= cur_line then
    -- eol + 1 is the true end-of-line column, reachable because options.lua
    -- sets virtualedit=onemore. Without it this clamps back to eol.
    vim.fn.cursor(cur_line, forward and eol + 1 or 1)
  end
end

-- Insert mode had no mapping for either pair, so it used the native motion,
-- which crosses to the next line rather than stopping at the last word.
-- <C-Right>/<C-Left> stay normal-mode window-resize (see below); only insert
-- mode gets the word motion there.
map({ "n", "x", "i" }, "<S-Right>", function() bounded_word_motion(true) end, { desc = "Word right, stop at end of line" })
map({ "n", "x", "i" }, "<S-Left>", function() bounded_word_motion(false) end, { desc = "Word left, stop at start of line" })
map("i", "<C-Right>", function() bounded_word_motion(true) end, { desc = "Word right, stop at end of line" })
map("i", "<C-Left>", function() bounded_word_motion(false) end, { desc = "Word left, stop at start of line" })

-- Tab indents. Normal mode's <Tab> is NvChad's tabufline "next buffer" and
-- visual mode's is unmapped (so it fell through to <C-i> = jumplist forward,
-- which reads as "the cursor just jumped somewhere"). Both now indent, and
-- buffer cycling moves to <S-h>/<S-l>.
map("n", "<Tab>", ">>", { desc = "Indent line" })
map("n", "<S-Tab>", "<<", { desc = "Unindent line" })
map("x", "<Tab>", ">gv", { desc = "Indent selection" })
map("x", "<S-Tab>", "<gv", { desc = "Unindent selection" })

map("n", "<S-l>", function()
  require("nvchad.tabufline").next()
end, { desc = "Buffer goto next" })
map("n", "<S-h>", function()
  require("nvchad.tabufline").prev()
end, { desc = "Buffer goto prev" })

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
