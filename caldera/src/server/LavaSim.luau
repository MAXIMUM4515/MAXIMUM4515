--[[
	LavaSim
	Pure heightfield simulation of a lava flow. No Roblox APIs are used here, so the
	physics can be unit-tested outside of Studio (see tests/LavaSim.spec.luau).

	Each cell stores:
		ground  original surface height (from raycasts against terrain and buildings)
		crust   solidified basalt that has built up on top of the ground
		lava    molten depth on top of the crust
		temp    1 = fresh from the vent, cools toward 0

	Every step, molten cells push lava to lower neighbours. Lava behaves like a Bingham
	plastic: it only moves when the surface step is larger than a yield height, which is
	what makes real flows stop with thick lobed edges instead of spreading into a film.
	Cooler lava is thicker (less fluid, higher yield) and eventually freezes into crust,
	which raises the ground so later flows pile on top of earlier ones.
]]

export type Params = {
	FlowRate: number,
	YieldHot: number,
	YieldCold: number,
	MinFlowDepth: number,
	EdgeLimit: number,
	MaxOutFraction: number,
	Substeps: number,
	Epsilon: number,
	CoolRate: number,
	SolidifyTemp: number,
	SendDepthStep: number,
	SendTempStep: number,
}

local LavaSim = {}
LavaSim.__index = LavaSim

local function quantizeDepth(value: number): number
	return math.clamp(math.floor(value * 100 + 0.5), 0, 65535)
end

local function quantizeTemp(value: number): number
	return math.clamp(math.floor(value * 255 + 0.5), 0, 255)
end

function LavaSim.new(size: number, params: Params, voidLevel: number)
	local count = size * size
	local self = setmetatable({
		N = size,
		Count = count,
		Params = params,
		VoidLevel = voidLevel,

		Ground = table.create(count, 0),
		Crust = table.create(count, 0),
		Lava = table.create(count, 0),
		Temp = table.create(count, 0),

		-- Sparse sets keyed by cell index.
		Active = {},
		Dirty = {},

		-- Last quantised values sent to clients, used to skip unnoticeable changes.
		SentLava = table.create(count, 0),
		SentCrust = table.create(count, 0),
		SentTemp = table.create(count, 0),

		-- Volume that poured off the edge of the world (kept so tests can check conservation).
		Lost = 0,

		_from = {},
		_to = {},
		_amount = {},
	}, LavaSim)
	return self
end

function LavaSim:SetGround(index: number, height: number)
	self.Ground[index] = height
end

function LavaSim:IsVoid(index: number): boolean
	return self.Ground[index] <= self.VoidLevel
end

-- Pours `amount` of lava at `temperature` into a cell, mixing heat with what is already there.
function LavaSim:Add(index: number, amount: number, temperature: number)
	if amount <= 0 or self.Ground[index] <= self.VoidLevel then
		return
	end
	local lava, temp = self.Lava, self.Temp
	local existing = lava[index]
	local total = existing + amount
	temp[index] = (temp[index] * existing + temperature * amount) / total
	lava[index] = total
	self.Active[index] = true
	self.Dirty[index] = true
end

-- One explicit flow iteration. Step() runs several of these per tick.
function LavaSim:_Flow()
	local p = self.Params
	local N = self.N
	local ground, crust, lava, temp = self.Ground, self.Crust, self.Lava, self.Temp
	local active, dirty = self.Active, self.Dirty

	local solidTemp = p.SolidifyTemp
	local flowRate = p.FlowRate
	local yieldHot = p.YieldHot
	local yieldRange = p.YieldCold - p.YieldHot
	local minFlow = p.MinFlowDepth
	local maxOut = p.MaxOutFraction
	local edgeLimit = p.EdgeLimit
	local voidLevel = self.VoidLevel

	-- Scratch buffers, reused every step to avoid garbage.
	local fromList, toList, amountList = self._from, self._to, self._amount
	local flowCount = 0

	local function record(from: number, to: number, amount: number)
		flowCount += 1
		fromList[flowCount] = from
		toList[flowCount] = to
		amountList[flowCount] = amount
	end

	-- 1) Work out every flow from the current state (Jacobi style, so order does not matter).
	for index in active do
		local depth = lava[index]
		local t = temp[index]
		if depth > minFlow and t > solidTemp then
			local fluidity = (t - solidTemp) / (1 - solidTemp)
			-- Viscous flux grows with depth: a deep channel carries far more than a thin sheet.
			local conductance = flowRate * fluidity * depth
			local yield = yieldHot + yieldRange * (1 - fluidity)
			local surface = ground[index] + crust[index] + depth

			local zero = index - 1
			local ix, iz = zero // N, zero % N

			local f1, f2, f3, f4 = 0, 0, 0, 0
			local n1, n2, n3, n4 = 0, 0, 0, 0
			local s1, s2, s3, s4 = 0, 0, 0, 0
			local steepest = 0
			if ix > 0 then
				n1 = index - N
				s1 = surface - (ground[n1] + crust[n1] + lava[n1])
				if s1 > yield then
					f1 = math.min(conductance * (s1 - yield), edgeLimit * s1)
					steepest = math.max(steepest, s1)
				end
			end
			if ix < N - 1 then
				n2 = index + N
				s2 = surface - (ground[n2] + crust[n2] + lava[n2])
				if s2 > yield then
					f2 = math.min(conductance * (s2 - yield), edgeLimit * s2)
					steepest = math.max(steepest, s2)
				end
			end
			if iz > 0 then
				n3 = index - 1
				s3 = surface - (ground[n3] + crust[n3] + lava[n3])
				if s3 > yield then
					f3 = math.min(conductance * (s3 - yield), edgeLimit * s3)
					steepest = math.max(steepest, s3)
				end
			end
			if iz < N - 1 then
				n4 = index + 1
				s4 = surface - (ground[n4] + crust[n4] + lava[n4])
				if s4 > yield then
					f4 = math.min(conductance * (s4 - yield), edgeLimit * s4)
					steepest = math.max(steepest, s4)
				end
			end

			local total = f1 + f2 + f3 + f4
			if total > 0 then
				-- Stability: each edge moves at most `edgeLimit` (1/8) of its surface step, the bound
				-- for an explicit 4-neighbour solver to stay monotone (no checkerboard flicker), and a
				-- cell never drains more than a fraction of itself per iteration.
				local cap = math.min(depth * maxOut, 0.5 * steepest)
				local scale = if total > cap then cap / total else 1
				if f1 > 0 then
					record(index, n1, f1 * scale)
				end
				if f2 > 0 then
					record(index, n2, f2 * scale)
				end
				if f3 > 0 then
					record(index, n3, f3 * scale)
				end
				if f4 > 0 then
					record(index, n4, f4 * scale)
				end
			end
		end
	end

	-- 2) Apply. Outflow first so heat mixing uses what stayed behind.
	local inflow: { [number]: number } = {}
	local heat: { [number]: number } = {}
	for i = 1, flowCount do
		local from, to = fromList[i], toList[i]
		local amount = amountList[i]
		lava[from] -= amount
		dirty[from] = true
		inflow[to] = (inflow[to] or 0) + amount
		heat[to] = (heat[to] or 0) + amount * temp[from]
	end
	for index, amount in inflow do
		if ground[index] <= voidLevel then
			self.Lost += amount
		else
			local existing = lava[index]
			local total = existing + amount
			temp[index] = (temp[index] * existing + heat[index]) / total
			lava[index] = total
			active[index] = true
			dirty[index] = true
		end
	end
end

function LavaSim:Step(dt: number, cooling: number)
	for _ = 1, self.Params.Substeps do
		self:_Flow()
	end
	self:_Cool(dt, cooling)
end

-- Cools every molten cell and freezes cold lava into crust. Thin sheets lose heat much faster than deep pools.
function LavaSim:_Cool(dt: number, cooling: number)
	local p = self.Params
	local crust, lava, temp = self.Crust, self.Lava, self.Temp
	local active, dirty = self.Active, self.Dirty
	local solidTemp = p.SolidifyTemp
	local coolStep = p.CoolRate * cooling * dt
	local epsilon = p.Epsilon
	for index in active do
		local depth = lava[index]
		if depth <= epsilon then
			-- Too little to matter: let it soak into the crust so volume is conserved.
			crust[index] += depth
			lava[index] = 0
			temp[index] = 0
			active[index] = nil
		else
			local t = temp[index] - coolStep / math.clamp(depth, 0.25, 4)
			if t <= solidTemp then
				crust[index] += depth
				lava[index] = 0
				temp[index] = 0
				active[index] = nil
			else
				temp[index] = t
			end
		end
		dirty[index] = true
	end
end

--[[
	Returns the cells whose visible state changed enough to be worth sending, and records
	what was sent. Cells that just settled (froze or drained) are always sent exactly so the
	client ends up with the true final shape.
]]
function LavaSim:CollectChanges(): { number }
	local p = self.Params
	local depthStep, tempStep = p.SendDepthStep, p.SendTempStep
	local lava, crust, temp = self.Lava, self.Crust, self.Temp
	local sentLava, sentCrust, sentTemp = self.SentLava, self.SentCrust, self.SentTemp
	local active = self.Active

	local changed = {}
	for index in self.Dirty do
		local lq = quantizeDepth(lava[index])
		local cq = quantizeDepth(crust[index])
		local tq = quantizeTemp(temp[index])
		local sl, sc, st = sentLava[index], sentCrust[index], sentTemp[index]

		local appeared = (lq > 0) ~= (sl > 0) or (cq > 0) ~= (sc > 0)
		local moved = math.abs(lq - sl) >= depthStep or math.abs(cq - sc) >= depthStep or math.abs(tq - st) >= tempStep
		local settled = not active[index] and (lq ~= sl or cq ~= sc or tq ~= st)

		if appeared or moved or settled then
			table.insert(changed, index)
			sentLava[index] = lq
			sentCrust[index] = cq
			sentTemp[index] = tq
		end
	end
	table.clear(self.Dirty)
	return changed
end

-- Every cell with anything in it, for players who join mid-eruption.
function LavaSim:Snapshot(): { number }
	local cells = {}
	local lava, crust = self.Lava, self.Crust
	for index = 1, self.Count do
		if lava[index] > 0 or crust[index] > 0 then
			table.insert(cells, index)
		end
	end
	return cells
end

function LavaSim:Clear()
	local count = self.Count
	for index = 1, count do
		self.Lava[index] = 0
		self.Crust[index] = 0
		self.Temp[index] = 0
		self.SentLava[index] = 0
		self.SentCrust[index] = 0
		self.SentTemp[index] = 0
	end
	table.clear(self.Active)
	table.clear(self.Dirty)
	self.Lost = 0
end

function LavaSim:TotalVolume(): number
	local total = 0
	local lava, crust = self.Lava, self.Crust
	for index = 1, self.Count do
		total += lava[index] + crust[index]
	end
	return total
end

function LavaSim:ActiveCount(): number
	local count = 0
	for _ in self.Active do
		count += 1
	end
	return count
end

return LavaSim
