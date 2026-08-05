-- This file needs to have same structure as nvconfig.lua 
-- https://github.com/NvChad/ui/blob/v3.0/lua/nvconfig.lua
-- Please read that file to know all available options :( 

  ---@type ChadrcConfig
  local M = {}


  M.base46 = {
  theme = "zenbones_custom",
  hl_override = {
    Keyword          = { fg = "#d0918d" },
    Conditional      = { fg = "#d0918d" },
    ["@keyword.return"] = { fg = "#d0918d" },
    ["@conditional"] = { fg = "#d0918d" },

    Boolean          = { fg = "#b193aa" },
    ["@boolean"]     = { fg = "#b193aa" },

    Type             = { fg = "#b5a494" },
    ["@type"]        = { fg = "#b5a494" },
    ["@namespace"]   = { fg = "#b5a494" },
    ["@module"]      = { fg = "#b5a494" },
    ["@constructor"] = { fg = "#b5a494" },
    ["@keyword.type"] = { fg = "#b5a494" },

    Function             = { fg = "#a39db5" },
    ["@function"]         = { fg = "#a39db5" },
    ["@function.call"]    = { fg = "#a39db5" },
    ["@function.method"]  = { fg = "#a39db5" },
    ["@function.method.call"] = { fg = "#a39db5" },

    String           = { fg = "#b6a585" },
    ["@string"]      = { fg = "#b6a585" },

    Comment          = { fg = "#555333", italic = true },
    ["@comment"]     = { fg = "#555333", italic = true },

    Identifier             = { fg = "#cdcdcd" },
    ["@variable"]          = { fg = "#cdcdcd" },
    ["@variable.parameter"] = { fg = "#cdcdcd" },
    ["@property"]          = { fg = "#cdcdcd" },

    Delimiter                  = { fg = "#4c4c4a" },
    ["@punctuation.delimiter"] = { fg = "#4c4c4a" },
    ["@punctuation.bracket"]   = { fg = "#4c4c4a" },
    Operator                  = { fg = "#4c4c4a" },
    LspInlayHint = { fg = "#3a3833", bg = "NONE", italic = true },

    -- zenbones_custom never defines its own Telescope/picker colors, so the
    -- selected row falls back to a barely-different near-black bg, and
    -- floating windows have no visible border. Accent = sand/beige rather
    -- than the pink used elsewhere; borders are a dimmer/desaturated sand
    -- (this theme's highlights are solid colors, not real alpha, so "low
    -- opacity" is approximated by muting the tone rather than blending it).
    TelescopeSelection       = { fg = "#ecdfc8", bg = "#4a4232", bold = true },
    TelescopeSelectionCaret  = { fg = "#c9a876", bg = "#4a4232", bold = true },
    TelescopeMultiSelection  = { fg = "#ecdfc8", bg = "#3a3a4a" },
    TelescopeMatching        = { fg = "#c9a876", bold = true },
    TelescopePromptPrefix    = { fg = "#c9a876" },
    -- base46's default theme integration puts a pink bg (#d0918d) on the
    -- title box specifically; swap it (and the preview title, for
    -- consistency) to sand.
    TelescopePromptTitle     = { fg = "#040403", bg = "#c9a876", bold = true },
    TelescopeResultsTitle    = { fg = "#040403", bg = "#c9a876", bold = true },
    TelescopePreviewTitle    = { fg = "#040403", bg = "#c9a876", bold = true },
    TelescopeBorder          = { fg = "#544c3a", bg = "NONE" },
    TelescopePromptBorder    = { fg = "#544c3a", bg = "NONE" },
    TelescopeResultsBorder   = { fg = "#544c3a", bg = "NONE" },
    TelescopePreviewBorder   = { fg = "#544c3a", bg = "NONE" },
    CursorLine                = { bg = "#3a3230" },
  },

  -- diagnostic virtual text, blended ~45% toward the bg so it reads as shaded
  -- (signs + underlines keep their full-strength colors)
  hl_add = {
    DiagnosticVirtualTextError = { fg = "#604341", bg = "NONE", italic = true },
    DiagnosticVirtualTextWarn  = { fg = "#544c3e", bg = "NONE", italic = true },
    DiagnosticVirtualTextInfo  = { fg = "#544c44", bg = "NONE", italic = true },
    DiagnosticVirtualTextHint  = { fg = "#4c4953", bg = "NONE", italic = true },
  },
}
-- M.nvdash = { load_on_startup = true }
  -- M.ui = {
    --       tabufline = {
      --          lazyload = false
      --      }
      -- }

      return M
