--[[
	SprayCone
	Whether a point is inside a fire extinguisher's spray: within range, inside the cone around the
	way the holder faces (measured flat, so the cone is a wedge rather than a narrow beam), and not
	too far above or below. Right next to the nozzle everything counts. Pure, so it is unit-tested.
]]

local SprayCone = {}

export type Spec = { Range: number, HalfAngle: number, Height: number, PointBlank: number }

function SprayCone.Contains(origin: Vector3, facing: Vector3, point: Vector3, spec: Spec): boolean
	local dx, dy, dz = point.X - origin.X, point.Y - origin.Y, point.Z - origin.Z
	if math.abs(dy) > spec.Height then
		return false
	end
	local distance = math.sqrt(dx * dx + dz * dz)
	if distance > spec.Range then
		return false
	end
	if distance <= spec.PointBlank then
		return true
	end
	local length = math.sqrt(facing.X * facing.X + facing.Z * facing.Z)
	if length < 1e-3 then
		return false
	end
	local cosine = (dx * facing.X + dz * facing.Z) / (distance * length)
	return cosine >= math.cos(spec.HalfAngle)
end

return SprayCone
