-- Only the `image` module is used here (real, compiled LaTeX/math images
-- via pdflatex + magick).
--
-- `doc.enabled = false`: don't auto-attach to every markdown/tex buffer --
-- that would render images straight into the buffer you're editing, which
-- is the "edit and preview merged" problem the split-view setup
-- (lua/plugins/init.lua's markview `config`) exists to avoid. Instead,
-- markview's `MarkviewSplitviewOpen` autocmd attaches this manually, only
-- to the read-only split preview buffer.
return {
  image = {
    enabled = true,
    doc = {
      enabled = false,
    },
    -- snacks always draws one of these next to a rendered image, even once
    -- it's loaded fine -- a persistent nerd-font marker glyph, not just a
    -- loading placeholder. That's the "emoji" sitting next to the math.
    -- Blank all three so nothing shows but the actual image.
    icons = {
      math = "",
      chart = "",
      image = "",
    },
    convert = {
      magick = {
        -- Default pdf conversion passes `-trim`, which crops every page
        -- down to its non-white content bounding box -- that's the
        -- "cropped borders" (no page edges/margins visible), not a bug in
        -- our own config. Drop it so the full page renders as-is. Density
        -- is back at the 192 default -- 300 was a hypothesis (more source
        -- detail = sharper text) that turned out not to be the actual
        -- bottleneck (the window's cell grid is, see configs.vimtex's
        -- PDF_WIN_WIDTH_FRAC), so it's one less variable while chasing
        -- the "stuck on identify loading / flashes on resize" bug.
        pdf = { "-density", 192, "{src}[{page}]", "-background", "white", "-alpha", "remove" },
      },
    },
  },
}
