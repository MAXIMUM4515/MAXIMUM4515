--[[
	Signal
	Minimal script-side event used for communication between server systems
	(for example Structures telling LavaFlow that a building fell over).
]]

export type Connection = { Disconnect: (Connection) -> (), Connected: boolean }

local Signal = {}
Signal.__index = Signal

function Signal.new()
	return setmetatable({ _handlers = {} }, Signal)
end

function Signal:Connect(handler: (...any) -> ()): Connection
	local connection = { Connected = true }
	local handlers = self._handlers

	function connection.Disconnect(conn)
		if not conn.Connected then
			return
		end
		conn.Connected = false
		local index = table.find(handlers, handler)
		if index then
			table.remove(handlers, index)
		end
	end

	table.insert(handlers, handler)
	return connection :: any
end

function Signal:Fire(...: any)
	-- Copy so handlers can disconnect while we iterate.
	for _, handler in table.clone(self._handlers) do
		task.spawn(handler, ...)
	end
end

function Signal:DisconnectAll()
	table.clear(self._handlers)
end

return Signal
