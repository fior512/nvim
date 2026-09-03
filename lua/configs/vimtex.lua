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

--- opens PDF split, or refreshes it if already open
local function show_pdf()
  local path = pdf_path()
  if not path or vim.fn.filereadable(path) == 0 then
    return
  end

  local win = find_pdf_win(path)
  if win then
    Snacks.image.buf.attach(vim.api.nvim_win_get_buf(win))
    return
  end

  local src_win = vim.api.nvim_get_current_win()
  vim.cmd "vsplit"
  -- resize before :edit, so convert pipeline sizes correctly
  vim.cmd("vertical resize " .. math.floor(vim.o.columns * PDF_WIN_WIDTH_FRAC))
  vim.cmd.edit(vim.fn.fnameescape(path))
  vim.api.nvim_set_current_win(src_win)
end

local group = vim.api.nvim_create_augroup("vimtex_inline_pdf", { clear = true })

-- <leader>mv: start compile (idempotent), then show/refresh PDF
vim.api.nvim_create_autocmd("FileType", {
  pattern = "tex",
  group = group,
  callback = function(ev)
    vim.keymap.set("n", "<leader>mv", function()
      vim.fn["vimtex#compiler#start"]()
      show_pdf()
    end, { buffer = ev.buf, desc = "Compile (if needed) + show rendered PDF" })
  end,
})

-- no auto-refresh on compile success: races mid-flight conversions
-- press <leader>mv again after save to refresh manually
