--[[
	Janitor
	Collects anything that needs tearing down at the end of a phase or round
	(connections, instances, threads, callbacks, objects with :Destroy()) and cleans it in one call.
]]

local Janitor = {}
Janitor.__index = Janitor

function Janitor.new()
	return setmetatable({ _tasks = {} }, Janitor)
end

function Janitor:Add<T>(item: T): T
	table.insert(self._tasks, item)
	return item
end

local function clean(item: any)
	local kind = typeof(item)
	if kind == "RBXScriptConnection" then
		item:Disconnect()
	elseif kind == "Instance" then
		item:Destroy()
	elseif kind == "function" then
		item()
	elseif kind == "thread" then
		if coroutine.status(item) ~= "dead" then
			pcall(task.cancel, item)
		end
	elseif kind == "table" then
		if type(item.Destroy) == "function" then
			item:Destroy()
		elseif type(item.Disconnect) == "function" then
			item:Disconnect()
		end
	end
end

function Janitor:Cleanup()
	local tasks = self._tasks
	self._tasks = {}
	-- Reverse order so later things (which may depend on earlier ones) go first.
	for index = #tasks, 1, -1 do
		local ok, err = pcall(clean, tasks[index])
		if not ok then
			warn("[Janitor] cleanup failed:", err)
		end
	end
end

Janitor.Destroy = Janitor.Cleanup

return Janitor
