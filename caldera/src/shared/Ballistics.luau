--[[
	Ballistics
	Closed-form projectile maths shared by the server (which decides where a lava bomb lands)
	and the client (which animates it). Both sides evaluate the same formula against the
	synced server clock, so the bomb a player sees lands exactly where the server applies damage.
]]

local Ballistics = {}

function Ballistics.PositionAt(origin: Vector3, velocity: Vector3, gravity: Vector3, t: number): Vector3
	return origin + velocity * t + gravity * (0.5 * t * t)
end

function Ballistics.VelocityAt(velocity: Vector3, gravity: Vector3, t: number): Vector3
	return velocity + gravity * t
end

-- Launch velocity that reaches `target` after exactly `flightTime` seconds.
function Ballistics.SolveVelocity(origin: Vector3, target: Vector3, gravity: Vector3, flightTime: number): Vector3
	return (target - origin - gravity * (0.5 * flightTime * flightTime)) / flightTime
end

--[[
	Walks the arc in small steps and asks `cast(from, to)` for the first obstruction.
	Returns the time of impact and the RaycastResult (or nil if nothing was hit before maxTime).
]]
function Ballistics.Trace(
	origin: Vector3,
	velocity: Vector3,
	gravity: Vector3,
	maxTime: number,
	step: number,
	cast: (Vector3, Vector3) -> RaycastResult?
): (number, RaycastResult?)
	local previous = origin
	local t = 0
	while t < maxTime do
		local nextT = math.min(t + step, maxTime)
		local point = Ballistics.PositionAt(origin, velocity, gravity, nextT)
		local result = cast(previous, point)
		if result then
			local segment = (point - previous).Magnitude
			local along = if segment > 0 then (result.Position - previous).Magnitude / segment else 0
			return t + (nextT - t) * along, result
		end
		previous = point
		t = nextT
	end
	return maxTime, nil
end

return Ballistics
