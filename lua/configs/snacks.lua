-- only image module used: LaTeX/math via pdflatex + magick
return {
  image = {
    enabled = true,
    -- attached manually to split preview only, see markview.lua
    doc = {
      enabled = false,
    },
    -- blanks persistent loading-marker glyph on images
    icons = {
      math = "",
      chart = "",
      image = "",
    },
    convert = {
      magick = {
        -- no -trim: keep full page margins; density at default 192
        pdf = { "-density", 192, "{src}[{page}]", "-background", "white", "-alpha", "remove" },
      },
    },
  },
}
