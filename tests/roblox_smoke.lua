local sources = {}

--[[ PISTONWARE_SOURCES ]]

local warnings = {}

local function expect(condition, message)
	if not condition then
		error(message, 0)
	end
end

local function compile(name)
	local chunk, message = loadstring(sources[name], name)
	expect(chunk ~= nil, name..': '..tostring(message))
	return chunk
end

local function execute(name)
	local ok, result = pcall(compile(name))
	expect(ok, name..' raised while executing: '..tostring(result))
	return result
end

local function warningText()
	local messages = {}
	for index, message in warnings do
		messages[index] = tostring(message)
	end
	return table.concat(messages, ' ')
end

local function expectWarnings(name, expected)
	expect(#warnings == expected, name..' emitted '..tostring(#warnings)..' warning(s): '..warningText())
end

local function makeSignal()
	return {
		Connect = function()
			return {Disconnect = function() end}
		end,
		Wait = function() end
	}
end

local function makeVector3(x, y, z)
	local value = {X = x or 0, Y = y or 0, Z = z or 0}
	return setmetatable(value, {
		__index = function(self, key)
			if key == 'Magnitude' then
				return math.sqrt(self.X * self.X + self.Y * self.Y + self.Z * self.Z)
			elseif key == 'Unit' then
				local magnitude = self.Magnitude
				return magnitude == 0 and makeVector3(0, 0, 0) or makeVector3(self.X / magnitude, self.Y / magnitude, self.Z / magnitude)
			elseif key == 'Dot' then
				return function(_, other)
					return self.X * other.X + self.Y * other.Y + self.Z * other.Z
				end
			end
		end,
		__add = function(left, right)
			return makeVector3(left.X + right.X, left.Y + right.Y, left.Z + right.Z)
		end,
		__sub = function(left, right)
			return makeVector3(left.X - right.X, left.Y - right.Y, left.Z - right.Z)
		end,
		__mul = function(left, right)
			if type(left) == 'number' then
				return makeVector3(left * right.X, left * right.Y, left * right.Z)
			end
			return makeVector3(left.X * right, left.Y * right, left.Z * right)
		end,
		__div = function(left, right)
			return makeVector3(left.X / right, left.Y / right, left.Z / right)
		end
	})
end

local function makeVector2(x, y)
	local value = {X = x or 0, Y = y or 0, x = x or 0, y = y or 0}
	return setmetatable(value, {
		__index = function(self, key)
			if key == 'Magnitude' then
				return math.sqrt(self.X * self.X + self.Y * self.Y)
			end
		end,
		__truediv = function(left, right)
			return makeVector2(left.X / right, left.Y / right)
		end
	})
end

local function resetRoblox()
	warnings = {}
	shared = {}
	warn = function(...)
		local messages = {}
		for _, message in {...} do
			messages[#messages + 1] = tostring(message)
		end
		warnings[#warnings + 1] = table.concat(messages, ' ')
	end

	Vector3 = {new = makeVector3}
	Vector3.zero = makeVector3(0, 0, 0)
	Vector2 = {new = makeVector2}
	Color3 = {
		new = function(r, g, b) return {R = r, G = g, B = b} end,
		fromRGB = function(r, g, b) return {R = r / 255, G = g / 255, B = b / 255} end,
		fromHSV = function(h, s, v) return {H = h, S = s, V = v} end
	}
	UDim = {new = function(scale, offset) return {Scale = scale, Offset = offset} end}
	UDim2 = {new = function(...) return {...} end, fromOffset = function(x, y) return {X = x, Y = y} end}
	CFrame = {new = function(...) return {...} end}
	Rect = {new = function(...) return {...} end}
	Enum = {
		HumanoidRigType = {R6 = 'R6', R15 = 'R15'},
		TeleportState = {Failed = 'Failed'},
		ScaleType = {Slice = 'Slice'}
	}
	RaycastParams = {new = function() return {} end}
	Instance = {new = function(className) return {ClassName = className} end}
	task = {
		wait = function() return 0 end,
		spawn = function(callback, ...) return callback(...) end,
		defer = function(callback, ...) return callback(...) end,
		delay = function(_, callback, ...) return callback(...) end,
		cancel = function() end
	}
	getgenv = function() return _G end

	local players = {
		LocalPlayer = {Team = nil, Character = nil},
		PlayerAdded = makeSignal(),
		PlayerRemoving = makeSignal(),
		GetPlayers = function() return {} end
	}
	local services = {
		Players = players,
		UserInputService = {
			TouchEnabled = false,
			GetMouseLocation = function() return makeVector2(0, 0) end
		},
		RunService = {Heartbeat = makeSignal(), RenderStepped = makeSignal()},
		HttpService = {GenerateGUID = function() return 'test-guid' end},
		ReplicatedStorage = {},
		CoreGui = {},
		TweenService = {},
		TextService = {},
		Teams = {},
		CollectionService = {},
		ContextActionService = {}
	}
	game = {
		PlaceId = 6872274481,
		GameId = 6872274481,
		GetService = function(_, name) return services[name] or {} end
	}
	workspace = {
		CurrentCamera = {ViewportSize = makeVector2(1920, 1080)},
		GetPropertyChangedSignal = function() return makeSignal() end,
		FindFirstChildWhichIsA = function() return nil end,
		Raycast = function() return nil end
	}
end

local function expectGuarded(name)
	resetRoblox()
	local result = execute(name)
	expectWarnings(name, 1)
	expect(result == nil, name..' returned from its unauthenticated guard')
end

expectGuarded('main.lua')
expectGuarded('NewMainScript.lua')
expectGuarded('games/6872265039.lua')
expectGuarded('games/6872274481.lua')

resetRoblox()
shared.vape = {}
shared.PistonwareDeveloper = true
execute('games/12011959048.lua')
expectWarnings('games/12011959048.lua', 0)
expect(shared.vape.Place == 11630038968, 'bridge-duel wrapper did not initialise its place')

resetRoblox()
local drawing = execute('libraries/drawing.lua')
expectWarnings('libraries/drawing.lua', 0)
expect(drawing == '1', 'drawing.lua did not use its no-communication fallback')

resetRoblox()
local entity = execute('libraries/entity.lua')
expectWarnings('libraries/entity.lua', 0)
expect(type(entity) == 'table' and entity.Running, 'entity.lua did not start with stubbed Roblox services')

local function mockEntity(player, position, target)
	return {
		Player = player,
		Character = {FindFirstChildWhichIsA = function() return nil end},
		Connections = {},
		Health = 100,
		NPC = false,
		Targetable = true,
		Target = target,
		RootPart = {Position = position}
	}
end

local nearPlayer, farPlayer = {}, {}
local near = mockEntity(nearPlayer, Vector3.new(2, 0, 0), false)
local farTarget = mockEntity(farPlayer, Vector3.new(9, 0, 0), true)
entity.List = {near, farTarget}
entity.EntityByPlayer[nearPlayer] = near
entity.EntityByPlayer[farPlayer] = farTarget
entity.EntityByCharacter[near.Character] = near
entity.EntityByCharacter[farTarget.Character] = farTarget
entity.EntityIndex[near] = 1
entity.EntityIndex[farTarget] = 2
entity.isAlive = true
entity.character = {HumanoidRootPart = {Position = Vector3.new(0, 0, 0)}, Connections = {}}

local selected = entity.EntityPosition({
	Players = true,
	Part = 'RootPart',
	Range = 10
})
expect(selected == farTarget, 'entity target priority was not preserved')
local output = {}
local all = entity.AllPosition({
	Players = true,
	Part = 'RootPart',
	Range = 10,
	Limit = 1,
	Output = output
})
expect(all == output and #all == 1 and all[1] == farTarget, 'entity output buffer was not reused')
local found, foundIndex = entity.getEntity(farPlayer)
expect(found == farTarget and foundIndex == 2, 'entity O(1) player lookup failed')
entity.removeEntity(nearPlayer)
expect(#entity.List == 1 and entity.List[1] == farTarget and entity.EntityIndex[farTarget] == 1, 'entity swap-remove failed')
local event = entity.Events.Smoke
local calls = 0
local connection = event:Connect(function() calls += 1 end)
connection:Disconnect()
connection:Disconnect()
event:Fire()
expect(calls == 0, 'entity event disconnect was not idempotent')
event:Destroy()
connection:Disconnect()
entity.stop()
expectWarnings('libraries/entity.lua after stop', 0)

resetRoblox()
local hash = execute('libraries/hash.lua')
expectWarnings('libraries/hash.lua', 0)
expect(hash.sha256('abc') == 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad', 'hash.lua SHA-256 smoke test failed')
expectWarnings('libraries/hash.lua after sha256', 0)

resetRoblox()
local prediction = execute('libraries/prediction.lua')
expectWarnings('libraries/prediction.lua', 0)
local roots = prediction.solveQuartic(1, 0, -5, 0, 4)
expect(type(roots) == 'table' and #roots == 4, 'prediction.lua quartic smoke test failed')
local trajectory = prediction.SolveTrajectory(
	Vector3.new(0, 0, 0),
	20,
	9.8,
	Vector3.new(0, 0, 10),
	Vector3.new(0, 0, 0),
	nil,
	0,
	false,
	nil
)
expect(trajectory ~= nil and type(trajectory.X) == 'number', 'prediction.lua trajectory smoke test failed')
expectWarnings('libraries/prediction.lua after trajectory', 0)

resetRoblox()
local vm = execute('libraries/vm.lua')
expectWarnings('libraries/vm.lua', 0)
local settings = vm.luau_newsettings()
expect(settings.vectorCtor == Vector3.new, 'vm settings did not use the Roblox Vector3 constructor')
expect(settings.vectorSize == 4, 'vm settings had the wrong Luau vector width')
vm.luau_validatesettings(settings)
settings.vectorSize = 3
vm.luau_validatesettings(settings)
expectWarnings('libraries/vm.lua after validation', 0)

print('Roblox-shaped Luau load smoke passed')
