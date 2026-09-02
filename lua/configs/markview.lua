-- `preview.enable = false` turns off markview's default in-buffer
-- conceal/extmark rendering, which redraws over the same buffer you're
-- typing in -- that's what made editing feel "merged" with the preview.
-- Structure (headers, lists, tables, code blocks, ...) is instead rendered
-- ONLY into the separate splitOpen preview buffer, wired up automatically in
-- lua/plugins/init.lua's markview `config`.
--
-- `latex.enable = false` disables markview's own unicode-symbol math
-- renderer in that preview buffer -- snacks.image (lua/configs/snacks.lua)
-- renders math there instead, as real compiled LaTeX images.
return {
  preview = {
    enable = false,
  },
  latex = {
    enable = false,
  },
}
