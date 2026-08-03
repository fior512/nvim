local M = {}

M.base_30 = {
  white         = "#cdcdcd",
  darker_black  = "#020201",
  black         = "#040403",
  black2        = "#0a0908",
  one_bg        = "#100f0d",
  one_bg2       = "#161412",
  one_bg3       = "#1c1a17",
  grey          = "#2a2723",
  grey_fg       = "#4c4c4a",
  grey_fg2      = "#5a5650",
  light_grey    = "#cdcdcd",
  red           = "#d0918d",
  baby_pink     = "#d0918d",
  pink          = "#b193aa",
  line          = "#161412",
  green         = "#b5a494",
  vibrant_green = "#b5a494",
  nord_blue     = "#a39db5",
  blue          = "#a39db5",
  yellow        = "#b6a585",
  sun           = "#b6a585",
  purple        = "#a39db5",
  dark_purple   = "#a39db5",
  teal          = "#b5a494",
  orange        = "#b5a494",
  cyan          = "#b5a494",
  statusline_bg = "#0a0908",
  lightbg       = "#161412",
  pmenu_bg      = "#a39db5",
  folder_bg     = "#b5a494",
}

M.base_16 = {
  base00 = "#040403",
  base01 = "#0a0908",
  base02 = "#161412",
  base03 = "#4c4c4a",
  base04 = "#5a5650",
  base05 = "#cdcdcd",
  base06 = "#dadada",
  base07 = "#ffffff",
  base08 = "#d0918d",
  base09 = "#b5a494",
  base0A = "#b6a585",
  base0B = "#b6a585",
  base0C = "#b5a494",
  base0D = "#a39db5",
  base0E = "#b193aa",
  base0F = "#77743c",
}

M.type = "dark"

M = require("base46").override_theme(M, "zenbones_custom")

return M
