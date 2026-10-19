--[[
	Shelter
	Decides whether a player is protected from a pyroclastic flow coming from `origin`.
	The server uses it to decide who survives; the client uses the same test for the
	"SHELTERED / EXPOSED" indicator, so the HUD never disagrees with what happens to you.

	Only proper buildings count: a Model marked with the "Shelter" attribute (the village houses
	and the concrete bunker). Terrain, rocks, trees, props, debris, the well and loose parts never
	count, and glass does not stop the flow.

	A spot is sheltered when, in the same building:
		- there is a roof or ceiling overhead, and
		- solid walls block at least 2 of 3 sightlines toward the volcano.
	In practice: get inside a house or the bunker, in a room whose wall faces the volcano.
	Standing in a doorway that faces the flow, or next to a wall that has burned away, is exposed.

	The raycast params must include only the folder that holds the buildings.
]]

local Config = require(script.Parent.Config)

local PROBE = Config.Pyroclastic.ShelterProbe
local ROOF_PROBE = Config.Pyroclastic.RoofProbe

local Shelter = {}

-- Heights (relative to the root part) of the horizontal probes: knees, chest, head. Indoors these
-- land on a window's sill, its glass and the wall above it, so a window still counts as wall
-- (2 of 3) while an open doorway facing the volcano does not.
local PROBE_HEIGHTS = { -1.5, 0.5, 3 }

-- The sheltering building a ray hit, or nil if it hit nothing that can stop the flow.
local function buildingHit(result: RaycastResult?): Instance?
	if not result then
		return nil
	end
	local part = result.Instance
	if part:IsA("BasePart") and part.Material == Enum.Material.Glass then
		return nil
	end
	local model = part:FindFirstAncestorOfClass("Model")
	if model and model:GetAttribute("Shelter") == true then
		return model
	end
	return nil
end

-- Returns (sheltered, score). Score is 0..1, for UI hints only.
function Shelter.Evaluate(position: Vector3, origin: Vector3, params: RaycastParams): (boolean, number)
	local toward = Vector3.new(origin.X - position.X, 0, origin.Z - position.Z)
	if toward.Magnitude < 1e-3 then
		return false, 0
	end
	toward = toward.Unit

	local building =
		buildingHit(workspace:Raycast(position + Vector3.new(0, 2, 0), Vector3.new(0, ROOF_PROBE, 0), params))
	if not building then
		return false, 0
	end

	local blocked = 0
	for _, height in PROBE_HEIGHTS do
		local hit = buildingHit(workspace:Raycast(position + Vector3.new(0, height, 0), toward * PROBE, params))
		if hit == building then
			blocked += 1
		end
	end

	return blocked >= 2, blocked / #PROBE_HEIGHTS
end

return Shelter
