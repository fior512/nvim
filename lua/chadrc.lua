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

    -- clangd (and other LSPs) highlight via semantic tokens, a separate
    -- layer from treesitter captures. Neovim has no built-in integration for
    -- most @lsp.type.* groups here (base46's semantic_tokens integration
    -- isn't enabled), so they fall back to Neovim's own default links:
    -- @lsp.type.class/struct/enum/interface -> @type, @lsp.type.namespace ->
    -- @module, @lsp.type.string -> @string, @lsp.type.number -> @number,
    -- @lsp.type.enumMember -> @constant. Overriding @lsp.type.* directly here
    -- does nothing (base46 only patches keys an enabled integration already
    -- defines) -- fix the underlying groups instead.
    Function             = { fg = "#a39db5" },
    ["@function"]         = { fg = "#a39db5" },
    ["@function.call"]    = { fg = "#a39db5" },
    ["@function.method"]  = { fg = "#a39db5" },
    ["@function.method.call"] = { fg = "#a39db5" },

    String           = { fg = "#bf8570" },
    ["@string"]      = { fg = "#bf8570" },

    Number           = { fg = "#b193aa" },
    ["@number"]      = { fg = "#b193aa" },
    Constant         = { fg = "#b193aa" },
    ["@constant"]    = { fg = "#b193aa" },

    Comment          = { fg = "#4c4b3c", italic = true },
    ["@comment"]     = { fg = "#4c4b3c", italic = true },

    Identifier             = { fg = "#cdcdcd" },
    ["@variable"]          = { fg = "#cdcdcd" },
    ["@variable.parameter"] = { fg = "#cdcdcd" },
    ["@property"]          = { fg = "#cdcdcd" },

    Delimiter                  = { fg = "#7a7873" },
    ["@punctuation.delimiter"] = { fg = "#7a7873" },
    ["@punctuation.bracket"]   = { fg = "#7a7873" },
    Operator                  = { fg = "#7a7873" },
    LspInlayHint = { fg = "#3a3833", bg = "NONE", italic = true },

    -- zenbones_custom has no Telescope colors of its own: selection/border
    -- fall back to near-black. Accent set to sand instead of the pink used
    -- elsewhere; borders are a dimmer sand tone.
    TelescopeSelection       = { fg = "#ecdfc8", bg = "#4a4232", bold = true },
    TelescopeSelectionCaret  = { fg = "#c9a876", bg = "#4a4232", bold = true },
    TelescopeMultiSelection  = { fg = "#ecdfc8", bg = "#3a3a4a" },
    TelescopeMatching        = { fg = "#c9a876", bold = true },
    TelescopePromptPrefix    = { fg = "#c9a876" },
    TelescopePromptTitle     = { fg = "#040403", bg = "#c9a876", bold = true },
    TelescopeResultsTitle    = { fg = "#040403", bg = "#c9a876", bold = true },
    TelescopePreviewTitle    = { fg = "#040403", bg = "#c9a876", bold = true },
    TelescopeBorder          = { fg = "#544c3a", bg = "NONE" },
    TelescopePromptBorder    = { fg = "#544c3a", bg = "NONE" },
    TelescopeResultsBorder   = { fg = "#544c3a", bg = "NONE" },
    TelescopePreviewBorder   = { fg = "#544c3a", bg = "NONE" },
    CursorLine                = { bg = "#3a3230" },
  },

  -- diagnostic virtual text, blended toward the bg; signs/underlines keep
  -- full-strength colors
  hl_add = {
    DiagnosticVirtualTextError = { fg = "#604341", bg = "NONE", italic = true },
    DiagnosticVirtualTextWarn  = { fg = "#544c3e", bg = "NONE", italic = true },
    DiagnosticVirtualTextInfo  = { fg = "#544c44", bg = "NONE", italic = true },
    DiagnosticVirtualTextHint  = { fg = "#4c4953", bg = "NONE", italic = true },
  },
}

M.ui = {
  tabufline = {
    -- default is { "treeOffset", "buffers", "tabs", "btns" } -- "btns" is the
    -- theme-toggle + close-all-buffers pair on the right side of the top bar
    order = { "treeOffset", "buffers", "tabs" },
  },
}

return M
