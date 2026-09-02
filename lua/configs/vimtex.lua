-- latexmk continuous compile (on save). No external viewer: the PDF is
-- rendered IN Neovim via snacks.image (configs.snacks already enables it
-- with `pdf` in its default `formats` list) -- opening the .pdf file in a
-- split triggers snacks' own BufReadCmd autocmd, which rasterizes it and
-- draws it inline with the kitty graphics protocol. That's the "actual
-- compiled document" preview: markview/snacks' OTHER path (configs.markview,
-- the `doc` table in configs.snacks) only renders inline LaTeX math
-- snippets found inside a source buffer, not a full document layout, so a
-- `\documentclass{article}` file like a resume needs this instead.
vim.g.vimtex_compiler_method = "latexmk"
vim.g.vimtex_compiler_latexmk = {
  continuous = 1,
  callback = 1,
}
-- Don't let vimtex launch its own (external) viewer on every compile --
-- we redraw the in-Neovim preview ourselves, from VimtexEventCompileSuccess
-- below. Leaving this on was also why okular opened twice: this automatic
-- launch races the explicit :VimtexView call that used to be in the
-- <leader>mv mapping, and both try to open/focus okular via its --unique
-- flag, which is what the "already running" message was warning about.
vim.g.vimtex_view_automatic = 0

-- Default is 1: pop open the quickfix list on ANY warning, even with no
-- errors -- that's the window that kept interrupting with font-shape/
-- overfull-hbox/fancyhdr noise on every save. Errors still open it
-- (quickfix_mode default 2, unchanged); real problems still surface.
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

-- snacks.image has no pan/zoom (see lua/plugins/init.lua git history --
-- that was tried and the "scroll" it relies on, virt_lines, doesn't
-- actually move with the window in practice). What actually determines
-- legibility is display SIZE: `placement.lua`'s `state()` fits the raster
-- into the window's cell box and asks the terminal to scale to exactly
-- that many columns/rows (`c=`/`r=` in the kitty graphics request) --
-- a 300dpi A4 page (2480x3508px, checked via `magick identify`) crammed
-- into a default 50/50 vsplit's ~half-width cell box is what was making
-- text tiny/aliased, not insufficient source resolution. So the preview
-- window gets most of the screen instead of an even split.
local PDF_WIN_WIDTH_FRAC = 0.7

--- Open the compiled PDF in a vertical split (source left, rendered
--- right, matching the markview split-preview convention), or if it's
--- already open in this tabpage, just refresh it in place -- snacks
--- rereads the file from disk on every `buf.attach` call, so this is
--- also how the preview picks up a newer compile (see the
--- VimtexEventCompileSuccess autocmd below).
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
  -- Resize BEFORE :edit, not after: opening the pdf starts snacks' async
  -- convert pipeline (identify -> magick -> placement) sized to whatever
  -- the window is at that moment. Resizing right after used to fire
  -- WinResized mid-conversion, which the placement's auto_resize autocmd
  -- turns into a scheduled redraw of a not-yet-ready image -- a likely
  -- cause of the stuck "identify loading..." placeholder.
  vim.cmd("vertical resize " .. math.floor(vim.o.columns * PDF_WIN_WIDTH_FRAC))
  vim.cmd.edit(vim.fn.fnameescape(path))
  vim.api.nvim_set_current_win(src_win)
end

local group = vim.api.nvim_create_augroup("vimtex_inline_pdf", { clear = true })

-- <leader>mv, tex-buffer-local override of the markdown mapping
-- (lua/mappings.lua): start continuous compilation (idempotent --
-- vimtex#compiler#start() no-ops with a warning if already running,
-- unlike :VimtexCompile which *toggles* and would stop it on a second
-- press) then show/refresh the rendered PDF split.
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

-- NOT auto-refreshing on VimtexEventCompileSuccess anymore: that fired on
-- every latexmk continuous-mode rebuild, and each `show_pdf` -> `attach`
-- call tears down the current placement (`placement.clean(buf)` in
-- snacks/image/buf.lua) and starts a fresh async convert. In continuous
-- mode a second success can land while the first conversion is still in
-- flight, which is a plausible cause of both symptoms reported: a
-- placement stuck forever on the "identify loading..." spinner, and a
-- resize-triggered redraw of an old ready image getting torn down again
-- right after ("flash and disappear"). Press <leader>mv again after a
-- save to refresh -- manual, but it won't race itself.
