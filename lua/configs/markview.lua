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
--
-- `preview.icon_provider = ""` turns off markview's per-language icon
-- lookup for code block labels (and callouts/checkboxes): with it on, a
-- fenced ```lua block gets a language "logo" glyph next to its label,
-- which read as a gaudy, gadget-y decoration rather than the plain
-- language name GitHub shows there. See plugins/init.lua's markview
-- `config` for the matching heading style fix (that part needs a
-- highlight override, not something settable from this table).
--
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
      -- "label" conceals the `#` markers and shows only the heading text,
      -- like GitHub does; the default "icon" style additionally prefixes
      -- a nerd-font glyph and colors the whole line with a background
      -- block per level, which is the "cube with a digit" look this
      -- replaces.
      heading_1 = { style = "label", icon = "", sign = false },
      heading_2 = { style = "label", icon = "", sign = false },
      heading_3 = { style = "label", icon = "" },
      heading_4 = { style = "label", icon = "" },
      heading_5 = { style = "label", icon = "" },
      heading_6 = { style = "label", icon = "" },
    },
  },
}
