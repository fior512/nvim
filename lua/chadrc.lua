-- This file needs to have same structure as nvconfig.lua
-- https://github.com/NvChad/ui/blob/v3.0/lua/nvconfig.lua
-- Please read that file to know all available options :(

---@type ChadrcConfig
local M = {}

-- colors live in lua/themes/, not here
M.base46 = {
  theme = "cyberdream_custom",
}

M.ui = {
  tabufline = {
    -- default is { "treeOffset", "buffers", "tabs", "btns" } -- "btns" is the
    -- theme-toggle + close-all-buffers pair on the right side of the top bar
    order = { "treeOffset", "buffers", "tabs" },
  },
}

return M
