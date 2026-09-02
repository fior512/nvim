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
  },
}
