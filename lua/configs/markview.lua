-- renders structure only in split preview, not inline
-- latex disabled: snacks.image renders math instead
-- icon_provider off: plain language labels, not glyphs
return {
  preview = {
    enable = false,
    icon_provider = "",
  },
  latex = {
    enable = false,
  },
  markdown = {
    headings = {
      -- GitHub-style: text only, no glyph/background
      heading_1 = { style = "label", icon = "", sign = false },
      heading_2 = { style = "label", icon = "", sign = false },
      heading_3 = { style = "label", icon = "" },
      heading_4 = { style = "label", icon = "" },
      heading_5 = { style = "label", icon = "" },
      heading_6 = { style = "label", icon = "" },
    },
  },
}
