--[[
	Minimal stand-ins for the handful of Roblox globals the pure modules touch, so the
	simulation and codec can be tested with a plain Luau runtime (no Studio needed).
	`__loadfile(path)` is provided by the test runner and returns the chunk's value.
]]

local Harness = {}

-- Vector3 -------------------------------------------------------------------------------
local Vector3Meta = {}
Vector3Meta.__index = function(v, key)
	if key == "Magnitude" then
		return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
	elseif key == "Unit" then
		local m = math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
		return Vector3.new(v.X / m, v.Y / m, v.Z / m)
	end
	return nil
end
Vector3Meta.__add = function(a, b)
	return Vector3.new(a.X + b.X, a.Y + b.Y, a.Z + b.Z)
end
Vector3Meta.__sub = function(a, b)
	return Vector3.new(a.X - b.X, a.Y - b.Y, a.Z - b.Z)
end
Vector3Meta.__mul = function(a, b)
	if type(a) == "number" then
		return Vector3.new(b.X * a, b.Y * a, b.Z * a)
	end
	return Vector3.new(a.X * b, a.Y * b, a.Z * b)
end
Vector3Meta.__div = function(a, b)
	return Vector3.new(a.X / b, a.Y / b, a.Z / b)
end

Vector3 = {
	new = function(x, y, z)
		return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, Vector3Meta)
	end,
}

Color3 = {
	fromRGB = function(r, g, b)
		return { R = r / 255, G = g / 255, B = b / 255 }
	end,
}

Enum = setmetatable({}, {
	__index = function(_, enumName)
		return setmetatable({}, {
			__index = function(_, item)
				return `Enum.{enumName}.{item}`
			end,
		})
	end,
})

-- math.noise stand-in: smooth deterministic value noise in roughly [-0.6, 0.6].
local function hash(x: number, y: number, z: number): number
	local h = math.sin(x * 127.1 + y * 311.7 + z * 74.7) * 43758.5453
	return (h - math.floor(h)) * 1.2 - 0.6
end

local function fade(t: number): number
	return t * t * t * (t * (t * 6 - 15) + 10)
end

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

local mathTable = table.clone(math)
mathTable.noise = function(x: number, y: number?, z: number?): number
	local yy, zz = y or 0, z or 0
	local x0, y0, z0 = math.floor(x), math.floor(yy), math.floor(zz)
	local fx, fy, fz = fade(x - x0), fade(yy - y0), fade(zz - z0)
	local function corner(i, j, k)
		return hash(x0 + i, y0 + j, z0 + k)
	end
	local x00 = lerp(corner(0, 0, 0), corner(1, 0, 0), fx)
	local x10 = lerp(corner(0, 1, 0), corner(1, 1, 0), fx)
	local x01 = lerp(corner(0, 0, 1), corner(1, 0, 1), fx)
	local x11 = lerp(corner(0, 1, 1), corner(1, 1, 1), fx)
	return lerp(lerp(x00, x10, fy), lerp(x01, x11, fy), fz)
end
math = mathTable

-- Module loading ------------------------------------------------------------------------
local cache = {}

local function dirOf(path: string): string
	return string.match(path, "^(.*)/[^/]*$") or "."
end

local function scriptFor(path: string)
	local dir = dirOf(path)
	local parent = setmetatable({}, {
		__index = function(_, name)
			return { __path = `{dir}/{name}.luau` }
		end,
	})
	return { Parent = parent, __path = path }
end

function require(target)
	local path = if type(target) == "table" then target.__path else target
	if cache[path] == nil then
		local previous = script
		script = scriptFor(path)
		cache[path] = __loadfile(path)
		script = previous
	end
	return cache[path]
end

-- Tiny test framework -------------------------------------------------------------------
local passed, failed = 0, 0

function Harness.test(name: string, fn: () -> ())
	local ok, err = pcall(fn)
	if ok then
		passed += 1
		print(`  ok   {name}`)
	else
		failed += 1
		print(`  FAIL {name}\n       {err}`)
	end
end

function Harness.near(actual: number, expected: number, tolerance: number, label: string?)
	if math.abs(actual - expected) > tolerance then
		error(`{label or "value"}: expected {expected} ± {tolerance}, got {actual}`, 2)
	end
end

function Harness.check(condition: any, message: string)
	if not condition then
		error(message, 2)
	end
end

function Harness.finish()
	print(`\n{passed} passed, {failed} failed`)
	if failed > 0 then
		error("tests failed")
	end
end

return Harness
