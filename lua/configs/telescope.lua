-- Telescope's `keymaps` picker renders the raw key sequence via
-- display_termcodes(), which already turns the literal space character
-- mapleader is bound to (init.lua) into the text "<Space>" -- but not into
-- "<leader>", so <leader>fk (mappings.lua) couldn't be found by typing the
-- word "leader". This entry_maker is a copy of telescope's own
-- make_entry.gen_from_keymaps, minus the parts that don't matter here
-- (alignment can be a static width instead of measuring every keymap's
-- length first), with that one substitution added. `value` stays the raw
-- keymap entry, unmodified -- selecting a result still triggers the real
-- lhs, only the label changes.
local function keymaps_entry_maker()
  local entry_display = require "telescope.pickers.entry_display"
  local utils = require "telescope.utils"

  local displayer = entry_display.create {
    separator = "▏",
    items = {
      { width = 3 },
      { width = 30 },
      { width = 2 },
      { remaining = true },
    },
  }

  local function make_display(entry)
    return displayer { entry.attr, entry.lhs_display, entry.mode, entry.desc }
  end

  return function(entry)
    local lhs_display = utils.display_termcodes(entry.lhs):gsub("^<Space>", "<leader>")
    local desc = (entry.desc or entry.rhs or ""):gsub("\n", "\\n")
    local attr = (entry.noremap ~= 0 and "*" or "") .. (entry.buffer ~= 0 and "@" or "")

    return {
      value = entry,
      ordinal = entry.mode .. " " .. lhs_display .. " " .. desc,
      display = make_display,
      lhs_display = lhs_display,
      mode = entry.mode,
      desc = desc,
      attr = attr,
    }
  end
end

return {
  keymaps_entry_maker = keymaps_entry_maker,
}
