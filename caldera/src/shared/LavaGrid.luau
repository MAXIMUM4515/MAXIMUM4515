--[[
	LavaGrid
	Geometry of the lava simulation grid plus the compact binary format used to stream it.

	The server runs the simulation; clients only render it. Instead of replicating thousands of
	Parts, the server sends changed cells packed into a `buffer`:

		u16 count
		count x { u16 index, i16 ground(cm), u16 crust(cm), u16 lava(cm), u8 temperature }

	9 bytes per changed cell, so even a busy tick with a few hundred changes is only a few KB.
]]

local Config = require(script.Parent.Config)

local N = Config.Lava.GridSize
local CELL = Config.Lava.CellSize
local CENTER = Config.Volcano.Center
local HALF = N * CELL / 2

local ENTRY_SIZE = 9
local HEADER_SIZE = 2

local LavaGrid = {}

LavaGrid.N = N
LavaGrid.CellSize = CELL
LavaGrid.Count = N * N
LavaGrid.EntrySize = ENTRY_SIZE

-- Cells whose ground raycast found nothing. Lava that reaches them is discarded.
LavaGrid.Void = -100000

-- ix, iz are 0-based column/row; index is 1-based so it can address Luau arrays directly.
function LavaGrid.Index(ix: number, iz: number): number
	return ix * N + iz + 1
end

function LavaGrid.Coords(index: number): (number, number)
	local zeroBased = index - 1
	return zeroBased // N, zeroBased % N
end

function LavaGrid.InBounds(ix: number, iz: number): boolean
	return ix >= 0 and ix < N and iz >= 0 and iz < N
end

-- World-space XZ centre of a cell.
function LavaGrid.CellCenter(index: number): (number, number)
	local ix, iz = LavaGrid.Coords(index)
	return CENTER.X - HALF + (ix + 0.5) * CELL, CENTER.Z - HALF + (iz + 0.5) * CELL
end

-- Cell index containing a world position, or nil if outside the grid.
function LavaGrid.FromWorld(x: number, z: number): number?
	local ix = math.floor((x - CENTER.X + HALF) / CELL)
	local iz = math.floor((z - CENTER.Z + HALF) / CELL)
	if not LavaGrid.InBounds(ix, iz) then
		return nil
	end
	return LavaGrid.Index(ix, iz)
end

-- All cell indices whose centres fall inside a horizontal circle.
function LavaGrid.CellsInRadius(x: number, z: number, radius: number): { number }
	local cells = {}
	local minX = math.floor((x - radius - CENTER.X + HALF) / CELL)
	local maxX = math.floor((x + radius - CENTER.X + HALF) / CELL)
	local minZ = math.floor((z - radius - CENTER.Z + HALF) / CELL)
	local maxZ = math.floor((z + radius - CENTER.Z + HALF) / CELL)
	local radiusSq = radius * radius
	for ix = math.max(minX, 0), math.min(maxX, N - 1) do
		for iz = math.max(minZ, 0), math.min(maxZ, N - 1) do
			local index = LavaGrid.Index(ix, iz)
			local cx, cz = LavaGrid.CellCenter(index)
			local dx, dz = cx - x, cz - z
			if dx * dx + dz * dz <= radiusSq then
				table.insert(cells, index)
			end
		end
	end
	-- Always return at least the cell under the point so tiny radii still do something.
	if #cells == 0 then
		local index = LavaGrid.FromWorld(x, z)
		if index then
			table.insert(cells, index)
		end
	end
	return cells
end

local function quantize(value: number, min: number, max: number): number
	return math.clamp(math.floor(value * 100 + 0.5), min, max)
end

LavaGrid.QuantizeDepth = function(value: number): number
	return quantize(value, 0, 65535)
end

LavaGrid.QuantizeTemp = function(value: number): number
	return math.clamp(math.floor(value * 255 + 0.5), 0, 255)
end

--[[
	Packs the given cells. The arrays are the simulation's own state arrays, indexed by cell.
]]
function LavaGrid.Encode(
	indices: { number },
	ground: { number },
	crust: { number },
	lava: { number },
	temp: { number }
): buffer
	local count = math.min(#indices, 65535)
	local buf = buffer.create(HEADER_SIZE + count * ENTRY_SIZE)
	buffer.writeu16(buf, 0, count)
	local offset = HEADER_SIZE
	for i = 1, count do
		local index = indices[i]
		buffer.writeu16(buf, offset, index)
		buffer.writei16(buf, offset + 2, quantize(ground[index], -32768, 32767))
		buffer.writeu16(buf, offset + 4, quantize(crust[index], 0, 65535))
		buffer.writeu16(buf, offset + 6, quantize(lava[index], 0, 65535))
		buffer.writeu8(buf, offset + 8, LavaGrid.QuantizeTemp(temp[index]))
		offset += ENTRY_SIZE
	end
	return buf
end

--[[
	Unpacks a buffer produced by Encode, calling `visit(index, ground, crust, lava, temp)` per cell.
	Malformed input is rejected rather than trusted.
]]
function LavaGrid.Decode(buf: buffer, visit: (number, number, number, number, number) -> ())
	local length = buffer.len(buf)
	if length < HEADER_SIZE then
		return
	end
	local count = buffer.readu16(buf, 0)
	if HEADER_SIZE + count * ENTRY_SIZE > length then
		return
	end
	local offset = HEADER_SIZE
	for _ = 1, count do
		local index = buffer.readu16(buf, offset)
		if index >= 1 and index <= N * N then
			visit(
				index,
				buffer.readi16(buf, offset + 2) / 100,
				buffer.readu16(buf, offset + 4) / 100,
				buffer.readu16(buf, offset + 6) / 100,
				buffer.readu8(buf, offset + 8) / 255
			)
		end
		offset += ENTRY_SIZE
	end
end

return LavaGrid
