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
	local records = {}
	local signal = {}
	function signal:Connect(callback)
		local record = {Callback = callback, Connected = true}
		records[#records + 1] = record
		return {
			Disconnect = function()
				record.Connected = false
			end
		}
	end
	function signal:Fire(...)
		for _, record in records do
			if record.Connected then
				record.Callback(...)
			end
		end
	end
	signal.Wait = function() end
	return signal
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
		ContextActionService = {},
		Stats = {
			FindFirstChild = function(_, name)
				if name ~= 'PerformanceStats' then return end
				return {
					FindFirstChild = function(_, statName)
						local value = statName == 'Ping' and 42 or statName == 'Memory' and 768
						return value and {GetValue = function() return value end} or nil
					end
				}
			end,
			GetTotalMemoryUsageMb = function() return 768 end
		}
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
	expectWarnings(name, 0)
	expect(result == nil, name..' returned from its unauthenticated guard')
end

local function expectSourceContains(name, text)
	expect(sources[name] and sources[name]:find(text, 1, true), name..' is missing expected source: '..text)
end

expectGuarded('main.lua')
expectGuarded('NewMainScript.lua')
expectGuarded('games/6872265039.lua')
expectGuarded('games/6872274481.lua')

do
	local source = sources['games/6872274481.lua']
	local startAt = assert(source:find(
		'local bootstrapOk, bootstrapError = callWithThreadFix(function()', 1, true
	))
	local endAt = assert(source:find('\n\tlocal Flamework = ', startAt, true))
	local probe = assert(loadstring(
		'return function(replicatedStorage, require, debug, os, task)\n'
		..'local function callWithThreadFix(callback) return pcall(callback) end\n'
		..'local vape = {Loaded = false}\n'
		..source:sub(startAt, endAt - 1)
		..'\nreturn {Knit = Knit, BowConstantsTable = BowConstantsTable}\nend)\n'
		..'return bootstrapOk, bootstrapError\nend',
		'bedwars-bootstrap-probe'
	))()

	local function runProbe(debugApi, delay, startupDelay)
		local controllers = {
			SwordController = {},
			ProjectileController = {enableBeam = function() end},
			BlockBreakController = {},
			MatchController = {},
			ItemDropController = {}
		}
		local knit = {Controllers = delay == nil and controllers or {}}
		local finishStartup
		knit.OnStart = function()
			return {
				andThen = function(_, resolve)
					if startupDelay then
						finishStartup = resolve
					else
						resolve()
					end
					return {cancel = function() finishStartup = nil end}
				end
			}
		end
		local storage = {
			rbxts_include = {
				node_modules = {
					['@easy-games'] = {
						knit = {src = {Knit = {KnitClient = knit}}}
					}
				}
			}
		}
		local elapsed, waits = 0, 0
		local ok, result = probe(storage, function(module)
			expect(module == knit, 'bootstrap required the wrong Knit module')
			return module
		end, debugApi, {
			clock = function() return elapsed end
		}, {
			wait = function(seconds)
				waits += 1
				elapsed += seconds
				if delay and waits >= delay then knit.Controllers = controllers end
				if finishStartup and waits >= startupDelay then
					local resolve = finishStartup
					finishStartup = nil
					resolve()
				end
			end
		})
		return ok, result, waits, knit
	end

	local extracted = {RelX = 1, RelY = 2, RelZ = 3}
	local debugApi = {
		getupvalue = function(callback, index)
			expect(type(callback) == 'function' and index == 8, 'wrong bow extraction target')
			return extracted
		end
	}
	local ok, result = runProbe(debugApi)
	expect(ok and result.BowConstantsTable == extracted, 'bootstrap discarded the live bow table')
	local ready, _, waits = runProbe(debugApi, 3)
	expect(ready and waits == 3, 'bootstrap did not wait for controllers')
	local started, _, startupWaits = runProbe(debugApi, nil, 3)
	expect(started and startupWaits == 3,
		'bootstrap proceeded before Knit startup completed')
	local stalled, startupFailure = runProbe(debugApi, nil, math.huge)
	expect(not stalled and tostring(startupFailure):find('within 60s', 1, true),
		'Knit startup wait did not time out')
	local timedOut, failure, timeoutWaits = runProbe(debugApi, math.huge)
	expect(not timedOut and tostring(failure):find('within 60s', 1, true),
		'controller timeout did not fail initialization')
	expect(timeoutWaits <= 602, 'controller wait exceeded its deadline')

	local mapStart = assert(source:find('\tfor name, remote in {', endAt, true))
	local mapEnd = assert(source:find('\n\tOldBreak = ', mapStart, true))
	local fillRemotes = assert(loadstring(
		'return function(remotes)\n'..source:sub(mapStart, mapEnd - 1)
		..'\nreturn remotes\nend', 'bedwars-remote-map'
	))()
	local remotes = {}
	expect(fillRemotes(remotes) == remotes, 'remote map replaced the shared table')
	local count = 0
	for _, remote in remotes do
		expect(type(remote) == 'string' and remote ~= '', 'invalid direct remote name')
		count += 1
	end
	expect(count == 29, 'direct remote map is incomplete')
	expect(remotes.AttackEntity == 'SwordHit'
		and remotes.FireProjectile == 'ProjectileFire'
		and remotes.EquipItem == 'SetInvItem'
		and remotes.WarlockTarget == 'WarlockLinkTarget', 'direct remote mapping changed')
end

expectSourceContains('loader.lua', '/branches/')
expectSourceContains('loader.lua', "release.sourceRef or release.branch")
expectSourceContains('loader.lua', 'namespace.buffer = buffer')
expectSourceContains('loader.lua', "local dumpPath = 'pistonware/errors/'")
expectSourceContains('loader.lua', 'function buffer.dump(reason)')
expectSourceContains('loader.lua', 'function buffer.guard(stage, fatal, callback, ...)')
expect(not sources['loader.lua']:find('pcall(print, line)', 1, true), 'loader.lua still prints logger lines directly')
expect(not sources['loader.lua']:find('pcall(warn, line)', 1, true), 'loader.lua still warns logger lines directly')
expectSourceContains('loader.lua', "local unsupported = {'xeno', 'solara'}")

do
	local startAt = assert(sources['loader.lua']:find('local function installPistonwareBuffer', 1, true))
	local endAt = assert(sources['loader.lua']:find('\nlocal pistonwareBuffer, markPistonwareBufferFilesystemReady', startAt, true))
	local installerChunk = assert(loadstring(
		sources['loader.lua']:sub(startAt, endAt - 1)..'\nreturn installPistonwareBuffer',
		'buffer-installer'
	))
	pcall(setfenv, installerChunk, getfenv())
	local installBuffer = installerChunk()
	local originalPrint, originalWarn = print, warn
	local originalGetgenv, originalIsfolder = getgenv, isfolder
	local originalMakefolder, originalWritefile = makefolder, writefile
	local consoleLines, files = {}, {}
	local folders = {pistonware = true}
	print = function(message) consoleLines[#consoleLines + 1] = 'print:'..tostring(message) end
	warn = function(message) consoleLines[#consoleLines + 1] = 'warn:'..tostring(message) end
	local publicEnv = {}
	getgenv = function() return publicEnv end
	isfolder = function(path) return folders[path] == true end
	makefolder = function(path) folders[path] = true end
	writefile = function(path, contents) files[path] = contents end

	local publicBuffer = installBuffer(false)
	expect(type(publicEnv.pistonware) == 'table' and publicEnv.pistonware.buffer == publicBuffer, 'buffer was not published through getgenv().pistonware')
	publicBuffer.log('test.log', 'public info')
	publicBuffer.print('test.print', 'public print')
	publicBuffer.warn('test.warn', 'public warning')
	publicBuffer.error('test.error', 'script_key=secret', {url = 'https://example.test/?key=secret'})
	expect(#consoleLines == 0, 'public buffer wrote to the executor console')
	local dumped, dumpPath, entryCount = publicBuffer.dump('smoke')
	expect(dumped and type(files[dumpPath]) == 'string', 'public buffer did not write its dump')
	expect(dumpPath:find('pistonware/errors/', 1, true) == 1, 'buffer dump used the wrong folder')
	expect(entryCount == 4, 'buffer dump reported the wrong entry count')
	expect(not files[dumpPath]:find('secret', 1, true), 'buffer dump did not redact a key')
	for index = 1, 520 do publicBuffer.log('test.capacity', index) end
	local snapshot, dropped = publicBuffer.snapshot()
	expect(#snapshot == 512 and dropped == 12, 'buffer ring did not enforce its capacity')
	local guarded, guardedError = publicBuffer.guard('test.guard', false, function() error('guarded failure') end)
	expect(not guarded and tostring(guardedError):find('guarded failure', 1, true), 'buffer guard did not return its failure')

	consoleLines = {}
	local developerBuffer = installBuffer(true)
	developerBuffer.print('test.print', 'developer print')
	developerBuffer.warn('test.warn', 'developer warning')
	developerBuffer.error('test.error', 'developer error')
	expect(#consoleLines == 3, 'developer buffer did not mirror all three entries')
	expect(consoleLines[1]:find('print:', 1, true) == 1, 'developer info did not use print')
	expect(consoleLines[2]:find('warn:', 1, true) == 1 and consoleLines[3]:find('warn:', 1, true) == 1, 'developer warning/error did not use warn')

	print, warn = originalPrint, originalWarn
	getgenv, isfolder = originalGetgenv, originalIsfolder
	makefolder, writefile = originalMakefolder, originalWritefile
end
expectSourceContains('games/universal.lua', "local SpeedMethodList = {'Velocity'}")
expectSourceContains('games/universal.lua', 'List = SpeedMethodList')
expectSourceContains('games/universal.lua', 'if shared.PistonwareDeveloper == true then')
expectSourceContains('games/universal.lua', "Name = 'Killaura Info'")
expectSourceContains('games/universal.lua', "<b>Developer Diagnostics</b>")
expectSourceContains('games/universal.lua', 'performance:StartDiagnostics()')
expect(not sources['games/universal.lua']:find("Name = 'MotionBlur'", 1, true), 'universal.lua still registers MotionBlur')
expectSourceContains('games/6872274481.lua', 'Max = 23')
expect(not sources['games/6872274481.lua']:find("instance:IsA('MeshPart') or instance:IsA('UnionOperation')", 1, true), '6872274481.lua still attempts RenderFidelity on solid geometry')
expectSourceContains('main.lua', "failBoot('game.compile', trace)")
expectSourceContains('main.lua', "failBoot('game.execute', result)")
expectSourceContains('main.lua', "failBoot('profile.apply',")
expectSourceContains('guis/newgui.lua', 'function vape:CanSave()')
expectSourceContains('guis/newgui.lua', 'function vape:BlockSaving()')
expectSourceContains('guis/newgui.lua', 'function vape:AllowSaving()')
expectSourceContains('guis/newgui.lua', 'self.PendingProfileCreate = canSave and true or nil')
expectSourceContains('games/6872274481.lua', "bootFailure('bedwars.local.compile'")
expectSourceContains('games/6872274481.lua', 'PistonwareBootFailure = true')
expectSourceContains('games/6872274481.lua', "bootFailure('bedwars.payload.execute'")
expect(not sources['games/6872274481.lua']:find('no usable local games/bedwars.lua -- using the published build', 1, true), '6872274481.lua still falls back after an invalid local payload')
expect(not sources['main.lua']:find('rawset(shared, "PistonwareAuthenticated", true)', 1, true), 'main.lua still carries an unauthenticated teleport gate')
expectSourceContains('games/8444591321.lua', 'return runChunk')
expectSourceContains('games/8560631822.lua', 'return runChunk')

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
local cachedOutput = {}
entity.Performance:SetEnabled(true)
near.Targetable = false
local cachedFirst = entity.AllPosition({
	Players = true,
	Part = 'RootPart',
	Range = 10,
	Cache = true,
	Output = cachedOutput
})
expect(#cachedFirst == 1 and cachedFirst[1] == farTarget, 'cached query did not re-filter targetability')
expect(entity.Performance.Stats.TargetCacheRefreshes == 1, 'cached query did not build its watchlist')
near.Targetable = true
local cachedSecond = entity.AllPosition({
	Players = true,
	Part = 'RootPart',
	Range = 10,
	Cache = true,
	Output = cachedOutput
})
expect(table.find(cachedSecond, near) ~= nil, 'cached query did not reuse its watchlist')
expect(entity.Performance.Stats.TargetCacheHits == 1, 'cached query did not record a cache hit')
near.RootPart.Position = Vector3.new(30, 0, 0)
local cachedThird = entity.AllPosition({
	Players = true,
	Part = 'RootPart',
	Range = 10,
	Cache = true,
	Output = cachedOutput
})
expect(table.find(cachedThird, near) == nil, 'cached query returned a stale position result')
expect(entity.Performance.Stats.TargetCacheHits == 2, 'cached query did not re-filter current positions')
near.RootPart.Position = Vector3.new(2, 0, 0)
local runService = game:GetService('RunService')

do
	local now = 0
	local chunk = compile('libraries/entity.lua')
	local environment = setmetatable({
		os = setmetatable({
			clock = function() return now end
		}, {__index = os})
	}, {__index = getfenv()})
	setfenv(chunk, environment)
	local cached = chunk()
	cached.isAlive = true
	cached.character = {
		HumanoidRootPart = {Position = Vector3.new(0, 0, 0)},
		Connections = {}
	}
	cached.Performance:SetEnabled(true)

	local inside = mockEntity({}, Vector3.new(2, 0, 0), false)
	local boundary = mockEntity({}, Vector3.new(20, 0, 0), false)
	local outside = mockEntity({}, Vector3.new(21, 0, 0), false)
	cached.List = {inside, boundary, outside}
	local function query(range, extra)
		local settings = {
			Players = true,
			Part = 'RootPart',
			Range = range
		}
		for key, value in extra or {} do settings[key] = value end
		return cached.AllPosition(settings)
	end

	local first = query(10)
	expect(#first == 1 and first[1] == inside,
		'cache returned candidates beyond the requested range')
	expect(cached.Performance.Stats.TargetCacheRefreshes == 1,
		'default query did not populate the cache')

	now = 0.5
	inside.RootPart.Position = Vector3.new(30, 0, 0)
	boundary.RootPart.Position = Vector3.new(5, 0, 0)
	outside.RootPart.Position = Vector3.new(6, 0, 0)
	local moved = query(10)
	expect(#moved == 1 and moved[1] == boundary,
		'cache did not rescan current positions within its saved membership')
	expect(#query(10, {Cache = false}) == 2,
		'explicit uncached query did not scan all entities')

	now = 0.999
	expect(#query(10) == 1, 'cache refreshed before its one-second expiry')
	now = 1
	expect(#query(10) == 2, 'expired cache did not discover the entering entity')
	expect(cached.Performance.Stats.TargetCacheRefreshes == 2,
		'cache expiry did not trigger exactly one rebuild')

	now = 2
	boundary.RootPart.Position = Vector3.new(30, 0, 0)
	outside.RootPart.Position = Vector3.new(31, 0, 0)
	inside.RootPart.Position = Vector3.new(100, 0, 0)
	expect(#query(20) == 0, 'expanded candidates leaked into the result')
	boundary.RootPart.Position = Vector3.new(5, 0, 0)
	outside.RootPart.Position = Vector3.new(6, 0, 0)
	now = 2.5
	local expanded = query(20)
	expect(#expanded == 1 and expanded[1] == boundary,
		'candidate radius was not exactly 150 percent for a 20-stud query')

	local before = cached.Performance.Stats.TargetCacheRefreshes
	query(20, {Limit = 1})
	expect(cached.Performance.Stats.TargetCacheRefreshes == before + 1,
		'changed query parameters reused the wrong cache entry')
	local originalSort = function(a, b) return a.Magnitude < b.Magnitude end
	local anotherSort = function(a, b) return a.Magnitude > b.Magnitude end
	query(20, {Sort = originalSort})
	query(20, {Sort = anotherSort})
	expect(cached.Performance.Stats.TargetCacheRefreshes == before + 3,
		'distinct sort functions shared a cache entry')

	cached.List = {}
	for index = 1, 140 do
		cached.List[index] = mockEntity({}, Vector3.new(2, 0, 0), false)
	end
	expect(#query(40) == 140, 'candidate collection retained a count cutoff')
	cached.List[1].Targetable = false
	expect(#query(40) == 139, 'cached query did not recheck targetability')
	cached.stop()
end

entity.Performance:StartDiagnostics()
runService.RenderStepped:Fire(0.016)
runService.RenderStepped:Fire(0.2)
runService.RenderStepped:Fire(0.016)
runService.RenderStepped:Fire(0.2)
runService.Heartbeat:Fire(0.2)
runService.Heartbeat:Fire(0.2)
runService.Heartbeat:Fire(0.2)
local diagnosticsSnapshot = entity.Performance:DiagnosticsSnapshot()
expect(diagnosticsSnapshot.Enabled and diagnosticsSnapshot.Render.Samples == 4, 'diagnostics did not sample render frames')
expect(diagnosticsSnapshot.Spikes.Render == 2, 'diagnostics did not count separated render spikes')
expect(diagnosticsSnapshot.Heartbeat.Samples == 3, 'diagnostics did not sample heartbeats')
expect(diagnosticsSnapshot.Ping.Samples == 1 and diagnosticsSnapshot.Ping.Current == 42, 'diagnostics did not sample ping')
expect(diagnosticsSnapshot.Memory == 768, 'diagnostics did not sample memory')
entity.Performance:StopDiagnostics()
expect(not entity.Performance:DiagnosticsSnapshot().Enabled, 'diagnostics did not stop cleanly')
entity.Performance:SetKillauraTelemetry(true)
entity.Performance:RecordKillauraSwing(near, 1)
entity.Performance:RecordKillauraSwing(near, 1.3)
entity.Performance:RecordKillauraHit(near.Character, 1.4)
entity.Performance:RecordKillauraHit(near.Character, 1.7)
local killauraTelemetry = entity.Performance.Killaura
expect(killauraTelemetry.SwingCount == 2 and killauraTelemetry.ConfirmedCount == 2, 'killaura telemetry did not match confirmed swings')
expect(math.abs(killauraTelemetry.AverageHitGap - 0.3) < 0.0001, 'killaura telemetry calculated the wrong hit gap')
expect(math.abs(killauraTelemetry.AverageConfirmationDelay - 0.4) < 0.0001, 'killaura telemetry calculated the wrong confirmation delay')
local killauraSnapshot = entity.Performance:KillauraSnapshot(1.7)
expect(killauraSnapshot.FinalizedCount == 2 and killauraSnapshot.Accuracy == 1 and killauraSnapshot.ProvisionalAccuracy == 1, 'killaura snapshot calculated the wrong accuracy')
entity.Performance:RecordKillauraSwing(near, 2)
local expiredSnapshot = entity.Performance:KillauraSnapshot(4.1)
expect(expiredSnapshot.ExpiredCount == 1 and expiredSnapshot.FinalizedCount == 3 and math.abs(expiredSnapshot.Accuracy - (2 / 3)) < 0.0001, 'killaura snapshot did not finalize expired attempts')
entity.Performance:SetKillauraTelemetry(false)
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
