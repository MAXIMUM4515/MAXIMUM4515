--[[
	Shelter
	Decides whether a position is protected from a pyroclastic flow coming from `origin`.
	The server uses it to scale damage; the client uses the same test to show the
	"SHELTERED / EXPOSED" indicator, so the HUD never disagrees with the damage you take.

	A spot counts as sheltered when solid geometry blocks most of the sightlines toward the
	volcano, or when there is a roof overhead and at least one sightline is blocked.
]]

local Config = require(script.Parent.Config)

local PROBE = Config.Pyroclastic.ShelterProbe
local ROOF_PROBE = Config.Pyroclastic.RoofProbe

local Shelter = {}

-- Heights (relative to the root part) of the horizontal probes.
local PROBE_HEIGHTS = { -1.5, 0.5, 2.5 }

function Shelter.Evaluate(position: Vector3, origin: Vector3, params: RaycastParams): (boolean, number)
	local toward = Vector3.new(origin.X - position.X, 0, origin.Z - position.Z)
	if toward.Magnitude < 1e-3 then
		return false, 0
	end
	toward = toward.Unit

	local blocked = 0
	for _, height in PROBE_HEIGHTS do
		local from = position + Vector3.new(0, height, 0)
		-- Aim slightly upward: the flow is a tall cloud, so a knee-high wall is not enough.
		local direction = (toward + Vector3.new(0, 0.12, 0)).Unit * PROBE
		if workspace:Raycast(from, direction, params) then
			blocked += 1
		end
	end

	local roofed = workspace:Raycast(position + Vector3.new(0, 2, 0), Vector3.new(0, ROOF_PROBE, 0), params) ~= nil
	local score = blocked / #PROBE_HEIGHTS
	if roofed then
		score = math.min(1, score + 0.34)
	end

	local sheltered = blocked >= 2 or (roofed and blocked >= 1)
	return sheltered, score
end

return Shelter
