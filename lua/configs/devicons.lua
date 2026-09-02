-- nvim-web-devicons ships ~120 file-type icons with hardcoded colors,
-- independent of the active colorscheme -- overriding cyberdream's `cyan`
-- (plugins/init.lua) does nothing to them. Several common ones (cpp, cxx,
-- ixx, go, jsx, hyprland.conf, tsconfig.json, ...) are teal-family
-- (`#519ABA`, `#00AAAE`, `#00ADD8`, ...), so teal kept showing up in
-- nvim-tree/tabufline/telescope no matter what the theme said.
--
-- Same fix as the cyan retirement: scan every icon's color, and any hue in
-- the teal/cyan band gets remapped to the same soft-gold (`#ecd3a0`) that
-- absorbed `cyan` there. Automatic and future-proof against devicons adding
-- more icons later, instead of listing extensions by hand.

local function rgb_to_hsl(hex)
	local r = tonumber(hex:sub(2, 3), 16) / 255
	local g = tonumber(hex:sub(4, 5), 16) / 255
	local b = tonumber(hex:sub(6, 7), 16) / 255
	local max, min = math.max(r, g, b), math.min(r, g, b)
	local h, s, l = 0, 0, (max + min) / 2

	if max ~= min then
		local d = max - min
		s = l > 0.5 and d / (2 - max - min) or d / (max + min)
		if max == r then
			h = (g - b) / d + (g < b and 6 or 0)
		elseif max == g then
			h = (b - r) / d + 2
		else
			h = (r - g) / d + 4
		end
		h = h * 60
	end

	return h, s, l
end

local function is_teal(hex)
	local h, s, l = rgb_to_hsl(hex)
	return h >= 155 and h <= 200 and s > 0.25 and l > 0.2 and l < 0.85
end

local SOFT_GOLD = "#ecd3a0"

local overrides = {}
for name, def in pairs(require("nvim-web-devicons").get_icons()) do
	if def.color and is_teal(def.color) then
		overrides[name] = { color = SOFT_GOLD, cterm_color = def.cterm_color, icon = def.icon, name = def.name }
	end
end

return {
	override = overrides,
	color_icons = true,
}
