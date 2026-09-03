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

-- bound in n and t mode: terminal-mode buffers ignore n-only maps
map({ "n", "t" }, "<C-Up>", "<cmd>resize -3<cr>", { desc = "Resize window shorter" })
map({ "n", "t" }, "<C-Down>", "<cmd>resize +3<cr>", { desc = "Resize window taller" })
map({ "n", "t" }, "<C-Left>", "<cmd>vertical resize -3<cr>", { desc = "Resize window narrower" })
map({ "n", "t" }, "<C-Right>", "<cmd>vertical resize +3<cr>", { desc = "Resize window wider" })


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

-- rebuilds project-wide ctags index, powers cmp-nvim-tags
map("n", "<leader>ct", function()
  local cwd = vim.fn.getcwd()
  vim.system({ "ctags", "-R", "." }, { cwd = cwd }, function(obj)
    local ok = obj.code == 0
    vim.schedule(function()
      vim.notify(
        "ctags: index " .. (ok and "refreshed" or "FAILED") .. " in " .. cwd,
        ok and vim.log.levels.INFO or vim.log.levels.ERROR
      )
    end)
  end)
end, { desc = "Regenerate ctags index (project-wide)" })

-- toggles markdown split preview; tex uses its own <leader>mv
map("n", "<leader>mv", "<cmd>Markview splitToggle<cr>", { desc = "Toggle markdown split preview" })

-- gitsigns ships no default keymaps, only sign glyphs
map("n", "]h", function()
  require("gitsigns").nav_hunk("next")
end, { desc = "Next git hunk" })
map("n", "[h", function()
  require("gitsigns").nav_hunk("prev")
end, { desc = "Prev git hunk" })
map("n", "<leader>hp", function()
  require("gitsigns").preview_hunk()
end, { desc = "Preview git hunk diff (floating)" })
map("n", "<leader>hs", function()
  require("gitsigns").stage_hunk()
end, { desc = "Stage git hunk" })
map("n", "<leader>hr", function()
  require("gitsigns").reset_hunk()
end, { desc = "Reset git hunk" })
map("n", "<leader>hb", function()
  require("gitsigns").blame_line { full = true }
end, { desc = "Blame current line (full)" })
