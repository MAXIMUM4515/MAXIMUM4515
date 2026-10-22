--[[
	Net
	One place that owns every RemoteEvent plus the replicated state folder.
	The server creates the instances the first time this module is required; clients wait for them.

	Round/phase state is replicated through attributes on the state folder instead of remotes,
	so late joiners automatically read the current values.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local IS_SERVER = RunService:IsServer()
local REMOTES_NAME = "MountIgnisRemotes"
local STATE_NAME = "MountIgnisState"

local EVENT_NAMES = {
	"Announce", -- (text, color, duration, style)
	"KillFeed", -- (playerName, cause)
	"Results", -- ({ survivors }, totalParticipants)
	"LavaDelta", -- (buffer)
	"LavaClear", -- ()
	"LavaSnapshot", -- client -> server request, server -> client reply (buffer)
	"BombLaunched", -- (bomb data)
	"Pyroclastic", -- (flow data)
	"CameraImpulse", -- (position, strength, radius)
	"RockImpact", -- (position, boulderSize, power)
	"RockHit", -- server -> client (power): a boulder hit you directly
	"Knockback", -- server -> client (velocity, tumble)
	"ExtinguisherTest", -- client -> server (): a free extinguisher, only in Studio with no product id set
}

local function getOrCreate(parent: Instance, className: string, name: string): Instance
	local existing = parent:FindFirstChild(name)
	if existing then
		return existing
	end
	local instance = Instance.new(className)
	instance.Name = name
	instance.Parent = parent
	return instance
end

local remotesFolder: Instance
local stateFolder: Instance

if IS_SERVER then
	remotesFolder = getOrCreate(ReplicatedStorage, "Folder", REMOTES_NAME)
	for _, name in EVENT_NAMES do
		getOrCreate(remotesFolder, "RemoteEvent", name)
	end
	stateFolder = getOrCreate(ReplicatedStorage, "Folder", STATE_NAME)
else
	remotesFolder = ReplicatedStorage:WaitForChild(REMOTES_NAME)
	stateFolder = ReplicatedStorage:WaitForChild(STATE_NAME)
end

local Net = {}

local cache: { [string]: RemoteEvent } = {}

function Net.Event(name: string): RemoteEvent
	local event = cache[name]
	if event then
		return event
	end
	local found = if IS_SERVER then remotesFolder:FindFirstChild(name) else remotesFolder:WaitForChild(name, 10)
	assert(found and found:IsA("RemoteEvent"), `Unknown remote "{name}"`)
	cache[name] = found :: RemoteEvent
	return found :: RemoteEvent
end

function Net.State(): Instance
	return stateFolder
end

function Net.GetState(key: string): any
	return stateFolder:GetAttribute(key)
end

function Net.SetState(key: string, value: any)
	assert(IS_SERVER, "State is server-owned")
	stateFolder:SetAttribute(key, value)
end

function Net.OnState(key: string, callback: (any) -> ()): RBXScriptConnection
	local connection = stateFolder:GetAttributeChangedSignal(key):Connect(function()
		callback(stateFolder:GetAttribute(key))
	end)
	task.spawn(callback, stateFolder:GetAttribute(key))
	return connection
end

return Net
