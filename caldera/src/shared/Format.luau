--[[
	Format
	Number formatting shared by the boards (server) and the shop (client). Pure, so it is unit-tested.
]]

local Format = {}

-- A whole number with thousands separators: 20000 -> "20,000".
function Format.Number(value: number): string
	local digits = tostring(math.floor(math.abs(value)))
	local grouped = string.reverse((string.gsub(string.reverse(digits), "(%d%d%d)", "%1,")))
	if string.sub(grouped, 1, 1) == "," then
		grouped = string.sub(grouped, 2)
	end
	return if value < 0 then "-" .. grouped else grouped
end

function Format.Robux(value: number): string
	return `R$ {Format.Number(value)}`
end

return Format
