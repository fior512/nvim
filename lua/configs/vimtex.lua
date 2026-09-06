-- continuous compile; PDF rendered inline via snacks.image
vim.g.vimtex_compiler_method = "latexmk"
vim.g.vimtex_compiler_latexmk = {
  continuous = 1,
  callback = 1,
}
-- disable external viewer, preview is redrawn in-Neovim
vim.g.vimtex_view_automatic = 0

-- don't open quickfix on warnings, only real errors
vim.g.vimtex_quickfix_open_on_warning = 0

---@return string? path of the current buffer's compiled PDF, or nil if
--- vimtex hasn't attached (not a tex buffer, or no b:vimtex state yet)
local function pdf_path()
  local state = vim.b.vimtex
  if not state or not state.tex then
    return nil
  end
  return vim.fn.fnamemodify(state.tex, ":r") .. ".pdf"
end

--- Find a window in the current tabpage whose buffer is `path`.
---@param path string
local function find_pdf_win(path)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)) == path then
      return win
    end
  end
end

-- wide split needed: legibility depends on cell-box size, not dpi
local PDF_WIN_WIDTH_FRAC = 0.7

--- opens a PDF split for `path`
local function open_pdf(path)
  local src_win = vim.api.nvim_get_current_win()
  vim.cmd "vsplit"
  -- resize before :edit, so convert pipeline sizes correctly
  vim.cmd("vertical resize " .. math.floor(vim.o.columns * PDF_WIN_WIDTH_FRAC))
  vim.cmd.edit(vim.fn.fnameescape(path))
  vim.api.nvim_set_current_win(src_win)
end

-- snacks caches renders by pdf path, not mtime: drop the stale png
local function invalidate_image_cache(path)
  local base = vim.fn.fnamemodify(path, ":t:r"):gsub("[^%w%.]+", "-")
  for _, file in ipairs(vim.fn.glob(
    Snacks.image.config.cache .. "/*-" .. base .. ".*",
    true,
    true
  )) do
    vim.fn.delete(file)
  end
end

--- re-renders the PDF buffer if its split is currently open
local function refresh_pdf()
  local path = pdf_path()
  if not path or vim.fn.filereadable(path) == 0 then
    return
  end
  local win = find_pdf_win(path)
  if win then
    invalidate_image_cache(path)
    -- image.new() memoizes by output path in memory too; drop it
    Snacks.image.image.clear()
    Snacks.image.buf.attach(vim.api.nvim_win_get_buf(win))
  end
end

--- <leader>mv: close split if open, else start compile and open it
local function toggle_pdf()
  local path = pdf_path()
  if path then
    local win = find_pdf_win(path)
    if win then
      vim.api.nvim_win_close(win, false)
      return
    end
  end

  vim.fn["vimtex#compiler#start"]()
  path = pdf_path()
  if path and vim.fn.filereadable(path) == 1 then
    open_pdf(path)
  end
end

local group = vim.api.nvim_create_augroup("vimtex_inline_pdf", { clear = true })

vim.api.nvim_create_autocmd("FileType", {
  pattern = "tex",
  group = group,
  callback = function(ev)
    vim.keymap.set(
      "n",
      "<leader>mv",
      toggle_pdf,
      { buffer = ev.buf, desc = "Toggle rendered PDF split" }
    )
  end,
})

-- redraw the split each time latexmk finishes a compile
vim.api.nvim_create_autocmd("User", {
  pattern = "VimtexEventCompileSuccess",
  group = group,
  callback = refresh_pdf,
})
