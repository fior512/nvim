-- remaps devicon teal hues to theme's soft-gold

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
