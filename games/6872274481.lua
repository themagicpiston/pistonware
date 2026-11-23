local pistonwareBuffer
pcall(function()
	local env = getgenv()
	pistonwareBuffer = type(env.pistonware) == 'table' and env.pistonware.buffer or nil
end)

local function bufferCall(method, event, message, details)
	local callback = type(pistonwareBuffer) == 'table' and pistonwareBuffer[method] or nil
	if type(callback) == 'function' then return callback(event, message, details) end
	if shared.PistonwareDeveloper == true then
		if method == 'print' then print('[pistonware] '..tostring(message)) else warn('[pistonware] '..tostring(message)) end
	end
end

if not shared.PistonwareAuthenticated then
	bufferCall('warn', 'bedwars.unauthenticated', 'not authenticated -- run the pistonware loader and enter your key')
	return
end

-- Solara and Xeno support. Approach credit: stxvv (gitlab.com/stxvv/bedwarsdeps).
-- Written for pistonware from BedWars' own modules; no code from that project is included.
local exec = shared.PistonwareExec
--[[ Probes the executor once and keeps the answer in shared.PistonwareExec: which capabilities exist and
actually work, plus exec.isolatedRequire and exec.hide.

Solara's require is written in Lua and runs a module's code again instead of handing back the game's
copy; when that code errors (KnitClient does) the calling thread drops to identity 2 and loses file
calls, gethui and CoreGui for good, and pcall does not prevent it. So a require that may fail runs
in a thread of its own (isolatedRequire), and one still running at the timeout counts as failed.
Without a native (C) require and without the debug library, KnitClient is never required. Require is
tried only on modules whose bodies just build a table, never on PlayerModule, and the same table has
to come back twice. Live means KnitClient's Controllers table is filled, which a re-run copy leaves
empty; KnitClient waits for its Services folder, so it is not required without one. An injection
made before the game registered its controllers sees an empty table too, so the BedWars files also
set Live once Knit has started. getnamecallmethod is trusted when hookmetamethod exists; otherwise a
pass-through wrapper goes on the raw __namecall for one GetService call, except on Delta, where
nothing may be written to the metatable at load. A place with no module to try require on does not
decide Full. ]]
if not (type(exec) == 'table' and type(exec.hide) == 'function') then
	local function probeExecutor()
		local exec = {}
		local function present(value)
			return type(value) == 'function'
		end
		local function passes(check)
			local ok, result = pcall(check)
			return ok and result == true
		end
		local function isolatedRequire(module, timeout)
			local finished, ok, result = false, false, nil
			task.spawn(function()
				ok, result = pcall(require, module)
				finished = true
			end)
			local deadline = os.clock() + (timeout or 10)
			while not finished and os.clock() < deadline do
				task.wait()
			end
			if not finished then return false, nil end
			return ok, result
		end
		exec.isolatedRequire = isolatedRequire
		exec.NativeRequire = passes(function()
			return debug.info(require, 's') == '[C]'
		end)

		local named, name = pcall(function()
			return identifyexecutor and ({identifyexecutor()})[1] or nil
		end)
		exec.Name = (named and type(name) == 'string') and name or ''

		local requireTarget
		pcall(function()
			local scripts = game:GetService('Players').LocalPlayer:FindFirstChild('PlayerScripts')
			local playerModule = scripts and scripts:FindFirstChild('PlayerModule')
			local utils = playerModule and playerModule:FindFirstChild('CommonUtils')
			local module = utils and (utils:FindFirstChild('FlagUtil') or utils:FindFirstChild('ConnectionUtil'))
			if not module then
				local include = game:GetService('ReplicatedStorage'):FindFirstChild('rbxts_include')
				module = include and include:FindFirstChild('RuntimeLib')
			end
			if module and module.ClassName == 'ModuleScript' then
				requireTarget = module
			end
		end)
		exec.Require = requireTarget ~= nil and passes(function()
			local loaded, exported = isolatedRequire(requireTarget)
			if not loaded or type(exported) ~= 'table' then return false end
			local again, second = isolatedRequire(requireTarget)
			return again and second == exported
		end)
		exec.Debug = passes(function()
			local marker = {}
			local function probeUpvalueHolder()
				return marker
			end
			return debug.getupvalue(probeUpvalueHolder, 1) == marker
		end)
		exec.Live = exec.Require and passes(function()
			local node = game:GetService('ReplicatedStorage')
			for _, step in {'rbxts_include', 'node_modules', '@easy-games', 'knit', 'src', 'Knit'} do
				node = node:FindFirstChild(step)
				if not node then return false end
			end
			local client = node:FindFirstChild('KnitClient')
			if not (client and node:FindFirstChild('Services')) then return false end
			if not exec.NativeRequire and not exec.Debug then return false end
			local loaded, knit = isolatedRequire(client)
			return loaded and type(knit) == 'table' and type(knit.Controllers) == 'table' and next(knit.Controllers) ~= nil
		end)
		exec.Identity = present(setthreadidentity) and passes(function()
			local thread = coroutine.create(function()
				local level = 8
				if present(getthreadidentity) then
					local got, current = pcall(getthreadidentity)
					if got and type(current) == 'number' then level = current end
				end
				setthreadidentity(level)
				return true
			end)
			local resumed, result = coroutine.resume(thread)
			return resumed and result == true
		end)
		exec.Genv = passes(function()
			return type(getgenv()) == 'table'
		end)
		exec.Rawmeta = present(setreadonly) and passes(function()
			return type(getrawmetatable(game)) == 'table'
		end)
		exec.HookFunction = present(hookfunction)
		exec.HookMetamethod = present(hookmetamethod)

		exec.Namecall = false
		if present(getnamecallmethod) then
			if exec.HookMetamethod then
				exec.Namecall = true
			elseif exec.Name:lower():find('delta', 1, true) then
				exec.Namecall = exec.Rawmeta
			elseif exec.Rawmeta then
				exec.Namecall = passes(function()
					local mt = getrawmetatable(game)
					local original = rawget(mt, '__namecall')
					if type(original) ~= 'function' then return false end
					local readonly = true
					if present(isreadonly) then
						local got, value = pcall(isreadonly, mt)
						if got then readonly = value == true end
					end
					local seen
					local installed = pcall(function()
						setreadonly(mt, false)
						rawset(mt, '__namecall', function(self, ...)
							if seen == nil then
								local got, method = pcall(getnamecallmethod)
								seen = got and method or false
							end
							return original(self, ...)
						end)
					end)
					if installed then
						pcall(function()
							return game:GetService('Players')
						end)
					end
					pcall(function()
						setreadonly(mt, false)
						rawset(mt, '__namecall', original)
					end)
					pcall(setreadonly, mt, readonly)
					return installed and seen == 'GetService' and rawget(mt, '__namecall') == original
				end)
			end
		end

		exec.Connections = present(getconnections) and passes(function()
			local event = Instance.new('BindableEvent')
			local connection = event.Event:Connect(function() end)
			local got, list = pcall(getconnections, event.Event)
			connection:Disconnect()
			event:Destroy()
			return got and type(list) == 'table'
		end)
		exec.FireSignal = present(firesignal)
		exec.Touch = present(firetouchinterest)
		exec.Prompt = present(fireproximityprompt)
		exec.Click = present(fireclickdetector)
		exec.NetworkOwner = present(isnetworkowner)
		exec.FpsCap = present(setfpscap)
		exec.FFlag = present(setfflag)
		exec.Mouse = present(mouse1click) and present(mouse1press)
		exec.MouseMove = present(mousemoverel)
		exec.Hui = present(gethui)
		exec.Teleport = present(queue_on_teleport)
		exec.HttpGet = passes(function()
			return type(game.HttpGet) == 'function'
		end)
		exec.Full = (exec.Require or requireTarget == nil) and exec.Identity and exec.Rawmeta
			and exec.Namecall and exec.HookFunction and exec.Connections and exec.Debug

		function exec.hide(moduleName, reason)
			if type(moduleName) ~= 'string' then return end
			local hidden = shared.PistonwareHidden
			if type(hidden) ~= 'table' then
				hidden = {}
				shared.PistonwareHidden = hidden
			end
			hidden[moduleName] = reason or 'not supported on this executor'
			local slinky = shared.slinky
			if type(slinky) == 'table' and type(slinky.modules) == 'table' and slinky.modules[moduleName] ~= nil then
				pcall(slinky.remove, slinky, moduleName)
			end
		end
		return exec
	end
	exec = probeExecutor()
	shared.PistonwareExec = exec
end

--[[ Skip lists for Solara and Xeno, told apart by how the identifyexecutor() name starts (exec.Name,
asked again when empty), in any case. A listed module is never built there: its run block returns
first and exec.hide keeps the reason. A listed option ('Module/Option') is hidden instead, and
whatever a profile saved for it is kept. Neither executor can load BedWars' Knit, so both share one
list. Every other executor gets no list, and exec.skip answers false there. ]]
do
	if type(exec.skip) ~= 'function' or type(exec.addSkips) ~= 'function' then
		local executor
		local function executorKey()
			if executor == nil then
				local name = exec.Name
				if type(name) ~= 'string' or name == '' then
					local ok, result = pcall(function()
						return identifyexecutor and ({identifyexecutor()})[1] or nil
					end)
					name = (ok and type(result) == 'string') and result or ''
				end
				name = name:lower()
				executor = (name:sub(1, 6) == 'solara' and 'solara') or (name:sub(1, 4) == 'xeno' and 'xeno') or false
			end
			return executor
		end
		function exec.addSkips(lists)
			local key = executorKey()
			if not key then return end
			local skipped = type(exec.Skipped) == 'table' and exec.Skipped or {}
			exec.Skipped = skipped
			for _, list in {lists.both or {}, lists[key] or {}} do
				for name, reason in list do
					skipped[name] = reason
				end
			end
		end
		function exec.skip(name)
			local skipped = exec.Skipped
			local reason = type(skipped) == 'table' and skipped[name] or nil
			if type(reason) ~= 'string' then return false end
			exec.hide(name, reason)
			return true
		end
	end
	exec.addSkips({both = {
		NoClickDelay = "changes the game's own click limiter, which Solara and Xeno cannot reach (being rebuilt)",
		Reach = "changes the game's own combat constants, which Solara and Xeno cannot reach (being rebuilt)",
		FastBreak = "changes the game's own block breaker, which Solara and Xeno cannot reach (being rebuilt)",
		AutoZephyr = "needs the game's own Zephyr controller, which Solara and Xeno cannot reach (being rebuilt)",
		HitBoxes = "needs the game's own sword code, which Solara and Xeno cannot reach (being rebuilt)",
		KeepSprint = "changes the game's own sprint code, which Solara and Xeno cannot reach (being rebuilt)",
		SafeWalk = "needs the game's movement controls, which Solara and Xeno cannot reach (being rebuilt)",
		NoSlowdown = "changes the game's own movement modifiers, which Solara and Xeno cannot reach (being rebuilt)",
		AutoCobalt = "needs the game's own battery controller, which Solara and Xeno cannot reach (being rebuilt)",
		TrapDisabler = "needs the game's own remotes client, which Solara and Xeno cannot reach (being rebuilt)",
		AutoTool = "needs the game's own block breaker, which Solara and Xeno cannot reach (being rebuilt)",
		ArmorSwitch = "cannot equip armor through the server inventory on this executor yet (being rebuilt)",
		AutoHotbar = "cannot sort the server inventory on this executor yet (being rebuilt)",
		['Bed Break Effect'] = "needs the game's own effect controllers, which Solara and Xeno cannot reach (being rebuilt)",
		Crosshair = "changes the game's own viewmodel code, which Solara and Xeno cannot reach (being rebuilt)",
		HitFix = "not enabled on this executor yet (being rebuilt)",
		Interface = "changes the game's own hotbar code, which Solara and Xeno cannot reach (being rebuilt)",
		SoundChanger = "needs the game's own audio manager, which Solara and Xeno cannot reach (being rebuilt)",
		WinEffect = "needs the game's own effect controllers, which Solara and Xeno cannot reach (being rebuilt)",
		['Speed/Pause on Lagback'] = "needs isnetworkowner, which Solara and Xeno do not have (being rebuilt)",
		['NameTags/Show Rank'] = "rank data is not available on this executor yet",
		['FPS Boost/Kill Effects'] = "changes the game's own kill effect controller, which this executor cannot reach (being rebuilt)",
		['FPS Boost/Visualizer'] = "needs the game's live visualizer module, which this executor cannot reach",
	}})
end

--[[ game:HttpGet wherever the executor has it, its result or error passed on unchanged. Only where
HttpGet is missing or refused to this thread (Xeno has none) does request() stand in, under any name
the executors give it, and then only a 2xx answer with a body counts, so an error page never comes
back as the file. Real's request answers a failure with an error string, which the table check turns
down. ]]
local function httpGet(url, ...)
	local ok, body = pcall(function(...)
		return game:HttpGet(url, ...)
	end, ...)
	if ok then return body end
	local reason = tostring(body):lower()
	local refused = false
	for _, hint in {'not a valid member', 'lacking capability', 'lacking permission', 'cannot call'} do
		if reason:find(hint, 1, true) then
			refused = true
			break
		end
	end
	if not refused then
		local indexed, method = pcall(function()
			return game.HttpGet
		end)
		refused = not indexed or type(method) ~= 'function'
	end
	local send = type(request) == 'function' and request or type(http_request) == 'function' and http_request
		or type(httprequest) == 'function' and httprequest
		or type(http) == 'table' and type(http.request) == 'function' and http.request
		or type(syn) == 'table' and type(syn.request) == 'function' and syn.request or nil
	if not (refused and send) then error(body, 0) end
	local response = send({Url = url, Method = 'GET'})
	local status = type(response) == 'table' and tonumber(response.StatusCode) or nil
	if type(response) ~= 'table' or response.Success == false or (status and (status < 200 or status > 299))
		or type(response.Body) ~= 'string' or response.Body == '' then
		error('GET '..tostring(url)..' failed'..(status and ' (HTTP '..status..')' or ''), 0)
	end
	return response.Body
end

local function errorTrace(err)
	local traceback
	pcall(function()
		if debug and type(debug.traceback) == 'function' then
			traceback = debug.traceback(tostring(err), 2)
		end
	end)
	return traceback or tostring(err)
end

--[[ Every module in this file and in bedwars.lua is registered inside one of these blocks, all
at top level, and bedwars.lua takes this same function through bw.run.
Unprotected, an error anywhere in any of them aborted the rest of the file: every module
below the failure never registered, and in bedwars.lua the completion signal on the last
line never ran either, so main.lua sat in waitForModules for the full 120s before loading a
profile against a half-built module set. One game update touching one API took the whole
script down that way. Contained here, a bad block costs its own modules and nothing else. ]]
local function callWithThreadFix(func)
	local setIdentity = setthreadidentity
	local oldIdentity
	local switched = false
	if type(setIdentity) == 'function' then
		if type(getthreadidentity) == 'function' then
			local ok, identity = pcall(getthreadidentity)
			if ok then oldIdentity = identity end
		end
		oldIdentity = oldIdentity or 2
		if oldIdentity ~= 8 then
			switched = pcall(setIdentity, 8)
		end
	end

	local ok, err = xpcall(func, errorTrace)
	if switched then
		pcall(setIdentity, oldIdentity)
	end
	return ok, err
end

--[[ Registration yields a frame once it has held the game thread for FRAME_BUDGET. Every
module here and in bedwars.lua used to be built back to back -- the modules, their options
and the GUI objects behind all of it -- in one uninterrupted stretch, which is one long
freeze on every inject and reinject. The whole file is written to survive a yield between
any two blocks, so this yields only when the frame is actually spent: a boot that fits in a
frame is exactly as fast as before. SlinkySmoothBoot used to yield before every block, a full
frame each even for small blocks; it now gets a smaller budget instead. ]]
local FRAME_BUDGET = shared.SlinkySmoothBoot and 0.008 or 0.012
local lastBootYield = os.clock()
-- A reinject replaces shared.slinky; the blocks of the boot it superseded then stop building.
local bootSlinky = shared.slinky
--[[ Runs one registration block of the boot through callWithThreadFix, yielding a frame first once the
boot has held the thread for FRAME_BUDGET. A reinject or an unload replaces this boot's slinky,
often during that yield, so the check is made again after it: a block building into the cleared
table would leave its connections and hooks behind with nothing to clean them. An error from a block
whose boot was replaced is that teardown and is not reported. ]]
local run = function(func)
	if shared.slinky ~= bootSlinky then return end
	if os.clock() - lastBootYield > FRAME_BUDGET then
		task.wait()
		lastBootYield = os.clock()
		if shared.slinky ~= bootSlinky then return end
	end
	local ok, err = callWithThreadFix(func)
	if not ok and shared.slinky == bootSlinky then
		bufferCall('error', 'bedwars.module', err, {traceback = err})
	end
end

local cloneref = cloneref or function(obj)
	return obj
end
--[[ On Xeno, an Instance inside a table fired through a BindableEvent comes out broken on every
other Fire: until the next one it no longer converts back to an Instance ("Instance expected, got
table"), however it is reached. Damage, death, projectile, bed and block events all carry characters
or players in a table. So on Xeno each event keeps what it fires in a ring and sends only the slot
number through its BindableEvent, and its listeners read the arguments back from the ring. The
BindableEvent still delivers, so listeners run when and in the order they did, and they get the
values that were fired rather than copies (no listener writes to them). Other executors keep plain
BindableEvents; in developer mode shared.PistonwareForceEventRing puts the ring on them too, for
testing. 256 slots hold far more than one frame's worth of any event. ]]
local slinkyEvents
--[[ Creates slinkyEvents, which makes one event per name on first use: a plain BindableEvent, or on Xeno
(and with PistonwareForceEventRing in developer mode) a ring event. A ring event keeps the arguments
of its last 256 fires in slots and sends only the slot number through its BindableEvent; Connect,
Once and Wait read the arguments back from the slot, so listeners get the values that were fired. ]]
do
	local RING_SIZE = 256
	local function ringEvent()
		local bindable = Instance.new('BindableEvent')
		local ring, fired = {}, 0
		local function deliver(callback)
			return function(id)
				local entry = ring[id % RING_SIZE]
				if entry and entry.id == id then
					return callback(table.unpack(entry, 1, entry.n))
				end
			end
		end
		local signal = {}
		function signal:Connect(callback)
			return bindable.Event:Connect(deliver(callback))
		end
		function signal:Once(callback)
			return bindable.Event:Once(deliver(callback))
		end
		function signal:Wait()
			while true do
				local id = bindable.Event:Wait()
				local entry = ring[id % RING_SIZE]
				if entry and entry.id == id then
					return table.unpack(entry, 1, entry.n)
				end
			end
		end
		local event = {Event = signal}
		function event:Fire(...)
			fired += 1
			local entry = table.pack(...)
			entry.id = fired
			ring[fired % RING_SIZE] = entry
			bindable:Fire(fired)
		end
		function event:Destroy()
			bindable:Destroy()
			table.clear(ring)
		end
		return event
	end

	local useRing = shared.PistonwareDeveloper == true and shared.PistonwareForceEventRing == true
	if not useRing then
		local name = type(exec.Name) == 'string' and exec.Name or ''
		if name == '' then
			local ok, result = pcall(function()
				return identifyexecutor and ({identifyexecutor()})[1] or nil
			end)
			name = (ok and type(result) == 'string') and result or ''
		end
		useRing = name:lower():sub(1, 4) == 'xeno'
	end

	slinkyEvents = setmetatable({}, {
		__index = function(self, index)
			local result = rawget(self, index)
			if result == nil then
				result = useRing and ringEvent() or Instance.new('BindableEvent')
				rawset(self, index, result)
			end
			return result
		end
	})
end

local playersService = cloneref(game:GetService('Players'))
local replicatedStorage = cloneref(game:GetService('ReplicatedStorage'))
local runService = cloneref(game:GetService('RunService'))
local inputService = cloneref(game:GetService('UserInputService'))
local tweenService = cloneref(game:GetService('TweenService'))
local httpService = cloneref(game:GetService('HttpService'))
local textChatService = cloneref(game:GetService('TextChatService'))
local collectionService = cloneref(game:GetService('CollectionService'))
local contextActionService = cloneref(game:GetService('ContextActionService'))
local guiService = cloneref(game:GetService('GuiService'))
-- Guarded: at a low identity these may not come back, and this is file scope.
local coreGui = (function()
	local ok, service = pcall(function()
		return cloneref(game:GetService('CoreGui'))
	end)
	return ok and service or nil
end)()
local starterGui = cloneref(game:GetService('StarterGui'))
local lightingService = cloneref(game:GetService('Lighting'))
local teleportService = cloneref(game:GetService("TeleportService"))
local pathfindingService = cloneref(game:GetService('PathfindingService'))
local virtualInputManager = (function()
	local ok, service = pcall(function()
		return cloneref(game:GetService('VirtualInputManager'))
	end)
	return ok and service or nil
end)()

--[[ identifyexecutor exists but THROWS on several mobile executors, and this runs at the top
level of the file -- so an unguarded call here does not degrade one feature, it kills the
whole game script before a single module registers. main.lua already carries a comment
saying exactly this about its own call; these three never got the same treatment, and this
is the file BedWars users load. ]]
local function executorName()
	local ok, name = pcall(function()
		return identifyexecutor and ({identifyexecutor()})[1] or nil
	end)
	return (ok and type(name) == 'string') and name or ''
end

local isnetworkowner = table.find({'AWP', 'Nihon'}, executorName()) and isnetworkowner or function()
	return true
end
local gameCamera = workspace.CurrentCamera
local lplr = playersService.LocalPlayer
local assetfunction = getcustomasset

local slinky = shared.slinky
local combat = slinky.categories.Combat
local blatant = slinky.categories.Blatant
local render = slinky.categories.Render
local utility = slinky.categories.Utility
local world = slinky.categories.World
local inventory = slinky.categories.Inventory
local minigames = slinky.categories.Minigames
local legit = slinky.legit
local entitylib = slinky.libraries.entity
local targetinfo = slinky.libraries.targetinfo
local sessioninfo = slinky.libraries.sessioninfo
local uipallet = slinky.libraries.uipallet
local tween = slinky.libraries.tween
local color = slinky.libraries.color
local tags = slinky.libraries.tags
local prediction = slinky.libraries.prediction
local getfontsize = slinky.libraries.getfontsize
local getcustomasset = slinky.libraries.getcustomasset

-- Is Pistonware's menu open: the GUI's field (safe from any thread), the Instance only as fallback.
local function clickGuiOpen()
	local open = slinky.menuOpen
	if open ~= nil then return open == true end
	if slinky.threadFix then pcall(setthreadidentity, 8) end
	local ok, visible = pcall(function()
		return slinky.gui.ScaledGui.ClickGui.Visible
	end)
	return ok and visible == true
end

local function priorityRank(entity, mode)
	local isPlayer = entity and entity.Player ~= nil
	if mode == 'NPCs first' then return isPlayer and 1 or 0 end
	return isPlayer and 0 or 1
end

local priorityTargetOutput = {}
--[[ The target under a priority setting: the nearest with 'Closest', else the first entity of the best
rank in the order entitylib.AllPosition returns them. It picks without sorting, so nothing is
allocated per call; AimAssist calls it every frame. ]]
local function priorityTarget(options, priority)
	if not priority or priority.value == 'Closest' then
		return entitylib.EntityPosition(options)
	end
	options.Cache = true
	options.Output = options.Output or priorityTargetOutput
	local targets = entitylib.AllPosition(options)
	local mode = priority.value
	local best, bestRank
	for _, entity in targets do
		local rank = priorityRank(entity, mode)
		if best == nil or rank < bestRank then
			best, bestRank = entity, rank
			if rank == 0 then break end
		end
	end
	return best
end

local store = {
	attackReach = 0,
	attackReachUpdate = os.clock(),
	damageBlockFail = os.clock(),
	hand = {},
	inventory = {
		inventory = {
			items = {},
			armor = {}
		},
		hotbar = {}
	},
	inventories = {},
	matchState = 0,
	queueType = 'bedwars_test',
	tools = {}
}

--[[ downloadBedwars' request, started here and collected there, so its network wait overlaps
match setup instead of following it. Kept in memory only; developer mode skips it. ]]
if not shared.PistonwareDeveloper then
	local fetch = {done = false}
	store.payloadFetch = fetch
	task.spawn(function()
		fetch.ok, fetch.body = pcall(function()
			local protectedUrl = shared.PistonwareProtectedRawUrl
			return type(protectedUrl) == 'function' and httpGet(protectedUrl(), true)
				or httpGet('https://gitlab.com/pistonware/pistonware/-/raw/main/bedwars.lua', true)
		end)
		fetch.done = true
	end)
end

--[[ store.activeKits and store.hasKit: every kit you are playing, not just the first. Kit Fusion
(combined_kit_to4) plays two at once; the game keeps them in the PlayingAsKits attribute as
"kit_a,kit_b", while store.equippedKit holds only the first. hasKit follows
KitController:isUsingKit: any active kit, or one granted as an ExtraKit_<kit> attribute. The store
can have the kit before the attribute arrives and after it is cleared, so equippedKit is put in
front when it is missing. ]]
do
	local listSource, listKits = nil, {}

	function store.activeKits()
		local list = lplr:GetAttribute('PlayingAsKits')
		if type(list) ~= 'string' then
			list = store.equippedKit or ''
		end
		if list ~= listSource then
			listSource = list
			listKits = {}
			for _, kit in list:split(',') do
				if kit ~= '' and kit ~= 'none' then
					table.insert(listKits, kit)
				end
			end
		end
		if store.equippedKit and store.equippedKit ~= '' and not table.find(listKits, store.equippedKit) then
			local kits = table.clone(listKits)
			table.insert(kits, 1, store.equippedKit)
			return kits
		end
		return listKits
	end

	function store.hasKit(kit)
		if type(kit) ~= 'string' or kit == '' then return false end
		return table.find(store.activeKits(), kit) ~= nil or lplr:GetAttribute('ExtraKit_'..kit) == true
	end
end

--[[ BedWars runs Workspace.SignalBehavior = Immediate, so a handler connected to a game signal runs
INSIDE the write, replication step or Destroy that fired it, and the executor's own native code
sits in that path. Firing an event, writing a property or calling into the executor from in there
nests inside it, which is the memory corruption that closed Delta at the next place load. So the
handlers below hand their work to store.queueDispatch, and this pump runs it on the next
Heartbeat, in arrival order.

This was Delta only. It now covers every executor that takes the Knit path (the Knit gate's own
test, further down: a working debug library, or Roblox's own require), because crashes are reported
on Potassium and other full executors too, and the Delta crash came down to this same always-on
Knit-path code: these handlers and the namecall hook below. Solara and Xeno, which never crashed
this way, are left out by name (a Xeno build can report a working debug library and then fall back
to the stand-in layer), and so is the developer force-knitless test, which mirrors them. There
queueDispatch stays nil and dispatchSafe returns the handler itself, so nothing changes. The store
is emptied on uninject, so code that runs later reads these through locals taken at load. ]]
store.deltaExecutor = executorName():lower():find('delta', 1, true) ~= nil
do
	local name = executorName():lower()
	store.deferDispatch = store.deltaExecutor
		or ((exec.Debug == true or (exec.Require == true and exec.NativeRequire == true))
			and not (shared.PistonwareForceKnitless == true and shared.PistonwareDeveloper == true)
			and name:sub(1, 6) ~= 'solara' and name:sub(1, 4) ~= 'xeno')
end
--[[ The dispatch pump, with store.deferDispatch: store.queueDispatch queues a job, store.dispatchSafe
wraps a handler so it queues itself, and the queued jobs run on the next Heartbeat in arrival order,
errors reported. The queue is taken whole before a pass, so a job that yields or queues more cannot
disturb it. Without deferDispatch, dispatchSafe returns the handler itself. ]]
if store.deferDispatch then
	local pending, count, closed = {}, 0, false
	local function queueDispatch(fn, ...)
		if closed then return end
		count += 1
		pending[count] = table.pack(fn, ...)
	end
	store.queueDispatch = queueDispatch
	function store.dispatchSafe(fn)
		return function(...)
			queueDispatch(fn, ...)
		end
	end
	slinky:clean(runService.Heartbeat:Connect(function()
		if count == 0 then return end
		local batch, total = pending, count
		pending, count = {}, 0
		for i = 1, total do
			local job = batch[i]
			local ok, err = xpcall(job[1], errorTrace, table.unpack(job, 2, job.n))
			if not ok then
				bufferCall('error', 'bedwars.dispatch', err, {traceback = err})
			end
		end
	end))
	slinky:clean(function()
		closed = true
		table.clear(pending)
		count = 0
	end)
else
	function store.dispatchSafe(fn)
		return fn
	end
end
local reach = {}
local hitBoxes = {}
local infiniteFly = {}
local trapDisabler
-- Which trap reports TrapDisabler drops, keyed by the remote the trap's controller fires.
local trapToggles = {}
local antiFallPart
local bedwars, remotes, sides, oldinvrender, oldSwing = {}, {}, {}

--[[ Resolves a player's active enchant to its icon. Enchants replicate as
StatusEffect_<type> attributes on the character (with a matching _stacks
attribute that is skipped), so the type has to be run back through
StatusEffectMeta and stripped of its _1/_2/_3 level suffix before EnchantMeta
will recognise it. Indexed rather than precomputed because the set changes
constantly mid-fight.

Has to sit BELOW the `local bedwars` declaration above, not up with the rest of
`store`. A local is only in scope for code that comes after it, so from up there
these `bedwars` references compiled against the (never-assigned) global instead of
capturing the local as an upvalue -- the file assigns the local later, which this
closure would never have seen. Deferring the call didn't help; it was scope, not
timing. ]]
store.enchants = setmetatable({}, {
	__index = function(self, plr)
		return {
			async = function()
				if plr and plr.Character then
					for i in plr.Character:GetAttributes() do
						if i:find('StatusEffect_') and not i:find('_stacks') then
							local name = bedwars.StatusEffectMeta[({i:gsub('StatusEffect_', '')})[1]]
							if bedwars.StatusEffectMeta[name] then
								name = bedwars.StatusEffectMeta[name]
								for num = 1, 3 do
									name = name:gsub(`_{num}`, '')
								end

								if bedwars.EnchantMeta[name] then
									return bedwars.EnchantMeta[name].image
								end
							end
						end
					end
				end
				return nil
			end,
		}
	end
})

--[[ Fly and TestFly's Heatseeker both stop your balloons popping while they fly. Each used to
save and put back deflateBalloon on its own, so with both on, whichever turned off last put the
other's no-op back and balloons stayed unpoppable until rejoin. They share one counted hold:
the first takes the original, the last gives it back. ]]
do
	local holds, original = 0, nil
	local function noPop() end

	function store.holdBalloons(hold)
		local controller = bedwars.BalloonController
		if not controller then return end
		if hold then
			if holds == 0 then
				original = controller.deflateBalloon
				controller.deflateBalloon = noPop
			end
			holds += 1
		elseif holds > 0 then
			holds -= 1
			if holds == 0 then
				controller.deflateBalloon = original
				original = nil
			end
		end
	end
end

--[[ The loader window's colours, for what this file draws on the HUD and in the world (the TP Down bar
and the AutoBank box): its orange, its light grey text and secondary grey labels, and its button
fill and border for a button or slot inside a box. Boxes are the loader's near-black with a tenth of
the orange through it, part see-through, with a soft orange border and rounded corners; text is the
menu's Inter. ]]
local loaderStyle = {
	Orange = Color3.fromRGB(240, 122, 31),
	Text = Color3.fromRGB(230, 230, 230),
	SubText = Color3.fromRGB(163, 161, 157),
	Button = Color3.fromRGB(18, 18, 18),
	ButtonBorder = Color3.fromRGB(60, 60, 60),
	Transparency = 0.3
}
loaderStyle.Background = Color3.fromRGB(10, 10, 10):Lerp(loaderStyle.Orange, 0.1)
-- The background as colour-slider defaults, so a box with a colour option starts on it.
loaderStyle.Hue, loaderStyle.Sat, loaderStyle.Value = loaderStyle.Background:ToHSV()
loaderStyle.SubHex = '#'..loaderStyle.SubText:ToHex()

function loaderStyle.corner(obj, radius)
	local corner = Instance.new('UICorner')
	corner.CornerRadius = typeof(radius) == 'UDim' and radius or UDim.new(0, radius or 8)
	corner.Parent = obj
	return corner
end

function loaderStyle.stroke(obj, strokeColor, transparency, thickness)
	local stroke = Instance.new('UIStroke')
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Color = strokeColor or loaderStyle.Orange
	stroke.Thickness = thickness or 1
	stroke.Transparency = transparency or 0.55
	stroke.Parent = obj
	return stroke
end

function loaderStyle.box(obj, radius)
	obj.BackgroundColor3 = loaderStyle.Background
	obj.BackgroundTransparency = loaderStyle.Transparency
	obj.BorderSizePixel = 0
	loaderStyle.corner(obj, radius)
	return loaderStyle.stroke(obj)
end

--[[ The draggable overlays' look (Reach Display here; universal.lua draws the rest the same way):
Target Info's card. A near-black card, mostly opaque, with a faint white edge, values bright and
labels muted. Fields on loaderStyle rather than locals: this chunk is near the local cap. ]]
loaderStyle.Card = {
	Background = Color3.fromRGB(16, 16, 16),
	Transparency = 0.15,
	Text = Color3.fromRGB(240, 240, 240),
	SubText = Color3.fromRGB(150, 150, 150),
	Edge = Color3.new(1, 1, 1),
	EdgeTransparency = 0.9
}
loaderStyle.Card.Hue, loaderStyle.Card.Sat, loaderStyle.Card.Value = loaderStyle.Card.Background:ToHSV()
loaderStyle.Card.SubHex = '#'..loaderStyle.Card.SubText:ToHex()
function loaderStyle.card(obj, radius)
	obj.BackgroundColor3 = loaderStyle.Card.Background
	obj.BackgroundTransparency = loaderStyle.Card.Transparency
	obj.BorderSizePixel = 0
	loaderStyle.corner(obj, radius or 12)
	return loaderStyle.stroke(obj, loaderStyle.Card.Edge, loaderStyle.Card.EdgeTransparency)
end
--[[ A colour option still saved on the loader box's old default (its background at 70%) is drawn as
the card: a profile saves every option, so a new default never reaches anyone who saved the old. ]]
function loaderStyle.cardColor(hue, sat, val, opacity)
	if math.abs(hue - loaderStyle.Hue) < 0.01 and math.abs(sat - loaderStyle.Sat) < 0.01
		and math.abs(val - loaderStyle.Value) < 0.01 and math.abs(opacity - (1 - loaderStyle.Transparency)) < 0.01 then
		return loaderStyle.Card.Background, 1 - loaderStyle.Card.Transparency
	end
	return Color3.fromHSV(hue, sat, val), opacity
end

-- Inter through the font registry, so the label follows it if it finishes loading late.
function loaderStyle.text(label, role, textColor)
	label.TextColor3 = textColor or loaderStyle.Text
	label.TextStrokeTransparency = 1
	local fonts = slinky.libraries.fonts
	if fonts and fonts.track then
		fonts.track(label, role or 'Medium')
	end
	return label
end

local function collection(tags, module, customadd, customremove)
	tags = typeof(tags) ~= 'table' and {tags} or tags
	local objs, connections = {}, {}

	for _, tag in tags do
		table.insert(connections, collectionService:GetInstanceAddedSignal(tag):Connect(function(v)
			if customadd then
				customadd(objs, v, tag)
				return
			end
			table.insert(objs, v)
		end))
		table.insert(connections, collectionService:GetInstanceRemovedSignal(tag):Connect(function(v)
			if customremove then
				customremove(objs, v, tag)
				return
			end
			v = table.find(objs, v)
			if v then
				table.remove(objs, v)
			end
		end))

		for _, v in collectionService:GetTagged(tag) do
			if customadd then
				customadd(objs, v, tag)
				continue
			end
			table.insert(objs, v)
		end
	end

	local cleanFunc = function(self)
		for _, v in connections do
			v:Disconnect()
		end
		table.clear(connections)
		table.clear(objs)
		table.clear(self)
	end
	if module then
		module:clean(cleanFunc)
	end
	return objs, cleanFunc
end

local function getBestArmor(slot)
	local closest, mag = nil, 0

	for _, item in store.inventory.inventory.items do
		local meta = item and bedwars.ItemMeta[item.itemType] or {}

		if meta.armor and meta.armor.slot == slot then
			local newmag = (meta.armor.damageReductionMultiplier or 0)

			if newmag > mag then
				closest, mag = item, newmag
			end
		end
	end

	return closest
end

--[[ The bow in your inventory whose arrow does the most damage, and its slot. Self-fuelled launchers
(the frost staffs and most kit casters) have no ammoItemTypes, and table.find on nil throws, so they
are skipped. ]]
local function getBow()
	local bestBow, bestSlot, highestDamage = nil, nil, 0
	for slot, item in store.inventory.inventory.items do
		local meta = bedwars.ItemMeta[item.itemType]
		if meta then
			local source = meta.projectileSource
			if source and source.ammoItemTypes and table.find(source.ammoItemTypes, "arrow") then
				local damage = (bedwars.ProjectileMeta[source.projectileType("arrow")] or {}).combat and bedwars.ProjectileMeta[source.projectileType("arrow")].combat.damage or 0
				if damage > highestDamage then
					bestBow, bestSlot, highestDamage = item, slot, damage
				end
			end
		end
	end
	return bestBow, bestSlot
end

local function getItem(itemName, inv)
	for slot, item in (inv or store.inventory.inventory.items) do
		if item and item.itemType == itemName then
			return item, slot
		end
	end
end

local function getRoactRender(func)
	return debug.getupvalue(debug.getupvalue(debug.getupvalue(func, 3).render, 2).render, 1)
end

--[[ Several modules below change a game function's constants with debug.setconstant, which needs
the debug library. Solara and Xeno leave that library out. fieldPatch.constants says whether it is
there; where it is not, those modules get the same effect by replacing a field of the game's
controller or component table instead (fieldPatch.wrap), which needs only require.

fieldPatch.wrap(tbl, key, build): build(current) is handed the function now in tbl[key] and returns
the replacement, which goes into tbl[key]. The handle's remove() puts the previous value back while
the replacement is still the one there. If something wrapped it since, it stays in that chain and
just passes calls through, so the wrapper on top keeps working; it is taken out of the chain when
the one above it goes. nil when tbl[key] is no function. ]]
local fieldPatch = {
	constants = exec.Debug and type(debug.getconstant) == 'function' and type(debug.setconstant) == 'function',
	hooks = setmetatable({}, {__mode = 'k'})
}
--[[ Puts build(current) into tbl[key] behind a handle whose remove() takes it out again. Only on the
game's own tables: where exec.Live is false (a re-running require made copies) nothing changes and
it returns nil. A removed wrapper that is still in a chain passes calls through, and remove() on the
top one skips down past removed handles to the nearest live value. ]]
function fieldPatch.wrap(tbl, key, build)
	if not exec.Live or type(tbl) ~= 'table' then return nil end
	local current = tbl[key]
	if type(current) ~= 'function' then return nil end
	local own = rawget(tbl, key)
	local replacement = build(current)
	if type(replacement) ~= 'function' then return nil end
	local handle = {Active = true, Own = own}
	handle.Hook = function(...)
		if handle.Active then
			return replacement(...)
		end
		return current(...)
	end
	fieldPatch.hooks[handle.Hook] = handle
	tbl[key] = handle.Hook
	function handle.remove()
		if not handle.Active then return end
		handle.Active = false
		if rawget(tbl, key) == handle.Hook then
			local value = own
			local below = fieldPatch.hooks[value]
			while below and not below.Active do
				value = below.Own
				below = fieldPatch.hooks[value]
			end
			tbl[key] = value
		end
	end
	return handle
end

--[[ For the HUD modules, which change what the game's Roact components render. A Roact element is
a plain table {component = ..., props = {...}} with its children in props[Roact.Children]; a
fragment keeps its elements in .elements. fieldPatch.render wraps component[key] (render by
default) so that style(self, element) can change the element it returns; a failing style is
skipped and the element is returned either way. ]]
function fieldPatch.children(element)
	local props = type(element) == 'table' and element.props
	local roact = bedwars.Roact
	if type(props) ~= 'table' or roact == nil then return nil end
	local children = props[roact.Children]
	return type(children) == 'table' and children or nil
end

function fieldPatch.child(children, component)
	if type(children) ~= 'table' then return nil end
	for _, child in children do
		if type(child) == 'table' and child.component == component and type(child.props) == 'table' then
			return child
		end
	end
end

function fieldPatch.render(component, style, key)
	return fieldPatch.wrap(component, key or 'render', function(render)
		return function(self, ...)
			local element = render(self, ...)
			pcall(style, self, element)
			return element
		end
	end)
end

local function getSword()
	local best, slot, maxDmg = nil, nil, 0
	for i, item in store.inventory.inventory.items do
		local meta = bedwars.ItemMeta[item.itemType]
		local sword = meta and meta.sword
		if sword then
			local dmg = sword.damage or 0
			if dmg > maxDmg then
				best, slot, maxDmg = item, i, dmg
			end
		end
	end
	return best, slot
end

local function getTool(breakType)
	local best, slot, maxDmg = nil, nil, 0
	for i, item in store.inventory.inventory.items do
		local meta = bedwars.ItemMeta[item.itemType]
		local tool = meta and meta.breakBlock
		if tool then
			local dmg = tool[breakType] or 0
			if dmg > maxDmg then
				best, slot, maxDmg = item, i, dmg
			end
		end
	end
	return best, slot
end

--[[ Fallback for a block type nothing in the inventory is specialised for -- wool while
carrying a pickaxe but no shears, say. getTool only matches a tool declaring the
block's own breakType, so it returns nil there and the swap was skipped entirely,
leaving the sword in hand. A break tool still beats that, so take the strongest one
available judged by its best break value across all types. Only consulted after an
exact type match fails, so shears still win for wool whenever they're carried. ]]
local function getBestBreakTool()
	local best, maxDmg = nil, 0
	for _, item in store.inventory.inventory.items do
		local meta = bedwars.ItemMeta[item.itemType]
		local breakBlock = meta and meta.breakBlock
		if breakBlock then
			for _, dmg in breakBlock do
				if type(dmg) == 'number' and dmg > maxDmg then
					best, maxDmg = item, dmg
				end
			end
		end
	end
	return best
end

local function getWool(inv)
	for _, item in (inv or store.inventory.inventory.items) do
		if item and item.itemType and item.itemType:find("wool") then
			return item.itemType, item.amount
		end
	end
end

--[[ Threat's measure: the best sword a player has. Another player's inventory cannot be read any
more -- it lives in their own PlayerGui.PrivateInventory -- so store.inventories holds no items for
anyone but you, and every target used to come out at 0. What every client does get is the item in
their hand: the server mirrors it onto the character as PublicHandInvItem, the value
InventoryUtil.getInventory reads for a player other than you. So the best sword seen in their hand
this life (each time they are ranked) stands in for the best in their bag, along with anything the
inventory does still show. Keyed by character, so a respawn starts over. ]]
local heldSword = setmetatable({}, {__mode = 'k'})

local function swordDamage(itemType)
	local meta = type(itemType) == 'string' and bedwars.ItemMeta[itemType]
	return meta and meta.sword and tonumber(meta.sword.damage) or 0
end

local function getStrength(plr)
	if not (plr and plr.Player) then return 0 end
	local strength = 0
	local inv = store.inventories[plr.Player]
	if inv then
		for _, v in inv.items or {} do
			strength = math.max(strength, swordDamage(v.itemType))
		end
	end

	local character = plr.Character
	if character then
		local value = character:FindFirstChild('PublicHandInvItem')
		local item = value and value:IsA('ObjectValue') and value.Value or nil
		local held = item and swordDamage(item.Name) or swordDamage(inv and inv.hand and inv.hand.itemType)
		local best = math.max(heldSword[character] or 0, held)
		heldSword[character] = best
		strength = math.max(strength, best)
	end
	return strength
end

local function getPlacedBlock(pos)
	if not pos then return end
	local blockPos = bedwars.BlockController:getBlockPosition(pos)
	return bedwars.BlockController:getStore():getBlockAt(blockPos), blockPos
end

local function getBlocksInPoints(s, e)
	local blocks, list = bedwars.BlockController:getStore(), {}
	for x = s.X, e.X do
		for y = s.Y, e.Y do
			for z = s.Z, e.Z do
				local vec = Vector3.new(x, y, z)
				if blocks:getBlockAt(vec) then
					list[#list + 1] = vec * 3
				end
			end
		end
	end
	return list
end

--[[ The nearest block with air above it, within `range` cells and under 60 studs; the answer is the spot
above that block. AutoPearl asks with a range of 20, twice per throw while you fall, where a full
sweep is 41^3 block store lookups. The search walks outward from your own cell and skips any cell,
row or slab already further away than the best found, so near ground ends it early, and with nothing
in range it never looks past 60 studs. On an exact tie it returns the cell that comes first in x,
then y, then z, as a full sweep would. ]]
local function getNearGround(range)
	range = Vector3.new(3, 3, 3) * (range or 10)
	local localPos = entitylib.character.RootPart.Position
	local closest, bestMag = nil, 60
	local bestX, bestY, bestZ
	local s, e = bedwars.BlockController:getBlockPosition(localPos - range), bedwars.BlockController:getBlockPosition(localPos + range)
	local center = bedwars.BlockController:getBlockPosition(localPos)
	local blocks = bedwars.BlockController:getStore()
	local up = Vector3.new(0, 3, 0)
	local lx, ly = localPos.X, localPos.Y

	local function limit()
		local bound = bestMag + 0.001
		return bound * bound
	end
	local function gap(step)
		return math.max(step * 3 - 1.51, 0)
	end

	for xStep = 0, math.max(center.X - s.X, e.X - center.X) do
		local gx = gap(xStep)
		if gx * gx > limit() then break end
		for xSide = 1, xStep == 0 and 1 or 2 do
			local x = xSide == 1 and center.X + xStep or center.X - xStep
			if x < s.X or x > e.X then continue end
			local dx = x * 3 - lx
			for yStep = 0, math.max(center.Y - s.Y, e.Y - center.Y) do
				local gy = gap(yStep)
				if dx * dx + gy * gy > limit() then break end
				for ySide = 1, yStep == 0 and 1 or 2 do
					local y = ySide == 1 and center.Y + yStep or center.Y - yStep
					if y < s.Y or y > e.Y then continue end
					local dy = y * 3 - ly
					local dxy = dx * dx + dy * dy
					for zStep = 0, math.max(center.Z - s.Z, e.Z - center.Z) do
						local gz = gap(zStep)
						if dxy + gz * gz > limit() then break end
						for zSide = 1, zStep == 0 and 1 or 2 do
							local z = zSide == 1 and center.Z + zStep or center.Z - zStep
							if z < s.Z or z > e.Z then continue end
							local v = Vector3.new(x, y, z) * 3
							local mag = (localPos - v).Magnitude
							local better = mag < bestMag
							if not better and mag == bestMag and closest then
								if x ~= bestX then
									better = x < bestX
								elseif y ~= bestY then
									better = y < bestY
								else
									better = z < bestZ
								end
							end
							if better and blocks:getBlockAt(Vector3.new(x, y, z)) and not getPlacedBlock(v + up) then
								bestMag, closest = mag, v + up
								bestX, bestY, bestZ = x, y, z
							end
						end
					end
				end
			end
		end
	end

	return closest
end

local function getShieldAttribute(char)
	local total = 0
	for name, val in char:GetAttributes() do
		if type(val) == "number" and val > 0 and name:find("Shield") then
			total += val
		end
	end
	return total
end

local function _baseGetSpeed()
    local multi, increase, modifiers = 0, true, bedwars.SprintController:getMovementStatusModifier():getModifiers()

    for v in modifiers do
        local val = v.constantSpeedMultiplier or 0
        if val > math.max(multi, 1) then
            increase = false
            multi = val - (0.06 * math.round(val))
        end
    end

    for v in modifiers do
        multi += math.max((v.moveSpeedMultiplier or 0) - 1, 0)
    end

    if multi > 0 and increase then
        multi += 0.16 + (0.02 * math.round(multi))
    end

    return 20 * (multi + 1)
end

--[[ Your walk speed from the sprint controller's movement modifiers, or shared.bedwars.getSpeed where
DamageBoost has wrapped it. ]]
local function getSpeed()
    local bw = shared.bedwars
    if bw and type(bw.getSpeed) == "function" then
        return bw.getSpeed()
    end
    return _baseGetSpeed()
end

--[[ The same reading with nothing layered on top -- straight past whatever DamageBoost wrapped
around it. Speed's Legit mode uses this so the top-up is measured against the speed the server
believes you have rather than one the boost inflated. ]]
local function rawGetSpeed()
    return _baseGetSpeed()
end

local function getTableSize(tab)
	local ind = 0
	for _ in tab do
		ind += 1
	end
	return ind
end

local function ensureSessionInfo()
	sessioninfo = sessioninfo or slinky.libraries.sessioninfo
	if type(sessioninfo) == 'table' and type(sessioninfo.Objects) == 'table' and type(sessioninfo.AddItem) == 'function' then
		return sessioninfo
	end

	local added = 0
	sessioninfo = {
		Objects = {},
		AddItem = function(self, name, startvalue, func, saved)
			added += 1
			self.Objects[name] = {
				Function = func or function(val) return val end,
				Saved = saved == nil or saved,
				Value = startvalue or 0,
				Index = getTableSize(self.Objects) + 2
			}
			return {
				Increment = function(_, val)
					self.Objects[name].Value += (val or 1)
				end,
				Get = function()
					return self.Objects[name].Value
				end
			}
		end
	}
	slinky.libraries.sessioninfo = sessioninfo
	return sessioninfo
end

--[[ A drink's hold on the hand (knitless.holdHand). Since the game's 10-24 update the server times a
drink from StartConsume and refuses the ConsumeItem when the hand was swapped in between. The
game's own client never sends one after a swap: its ConsumeController is a HandKnitController, and
any item switch ends the drink there. While a hold is up, switchItem and hotbarSwitch
here and every module's own swap path leave the hand alone, the item being drunk excepted. A hold
ends at its deadline whatever happens to the drink, so a release that never runs cannot keep the
hand. It also ends the moment an owner that ranks above the drink (LongJump, AutoPearl's void
save, a manual claim) takes the hand from it (lock.owned), so their swaps go through. On store, as
hasKit is, so every file reads the same one. ]]
store.handHeld = function(tool)
	local lock = store.handLock
	return lock ~= nil and os.clock() < lock.deadline and (tool == nil or tool ~= lock.item)
		and (lock.owned == nil or lock.owned())
end

--[[ Selects a hotbar slot through the store and waits for InventoryChanged; false while a drink holds
the hand (store.handHeld) or when the slot is already selected. Without Knit the wait is bounded,
because a selection the stand-in store turns down never fires the change. ]]
local function hotbarSwitch(slot)
	if store.handHeld() then return false end
	if slot and store.inventory.hotbarSlot ~= slot then
		bedwars.Store:dispatch({
			type = 'InventorySelectHotbarSlot',
			slot = slot
		})
		if exec.Knitless then
			local changed = false
			local connection = slinkyEvents.InventoryChanged.Event:Once(function()
				changed = true
			end)
			local deadline = os.clock() + 1
			repeat task.wait() until changed or os.clock() > deadline
			connection:Disconnect()
		else
			slinkyEvents.InventoryChanged.Event:Wait()
		end
		return true
	end
	return false
end

--[[ The kit to SHOW for a player, and the icon for it.

Two separate problems lived in the one line this replaces:

  * PlayingAsKit (singular) is the older attribute. The live one is PlayingAsKits, a comma
    separated LIST -- kit-util's getKitArrayFromCommaSeparatedString is a plain string.split
    on ',' because a player can be on more than one kit at once. Reading only the singular
    meant the nametag icon was blank for anyone the game describes the modern way.
  * BedwarsKitMeta[kit].renderImage was indexed with no nil guard, so any value without a
    meta entry -- an unknown kit, a combined string, a renamed id after an update -- was a
    hard error raised inside the nametag loop rather than a missing icon.

The first non-empty entry is the one to show: KitController:getPrimaryActiveKit is exactly
getActiveKits()[1]. ]]
--[[ Your own input, for the AFK checks on TriggerBot, ProjectileAura and AutoZeno: they
stand down once nothing has been pressed, clicked or moved for AFK_SECONDS. Mouse movement
only counts when the mouse actually moved -- InputChanged also fires with a zero delta. ]]
local AFK_SECONDS = 30
store.lastInput = tick()
--[[ Stamps store.lastInput for any input except a mouse move that did not move. A number key the
knitless hotbar pressed itself (marked in shared.PistonwareSyntheticKeys) does not count as yours.
]]
local function markInput(input)
	local synthetic = shared.PistonwareSyntheticKeys
	if type(synthetic) == 'table' and (tonumber(synthetic[input.KeyCode]) or 0) > os.clock() then return end
	if input.UserInputType ~= Enum.UserInputType.MouseMovement or input.Delta.Magnitude > 0 then
		store.lastInput = tick()
	end
end
slinky:clean(inputService.InputBegan:Connect(markInput))
slinky:clean(inputService.InputChanged:Connect(markInput))

-- `seconds` overrides the default for a module that lets you pick its own threshold.
local function isLocalAfk()
	return (tick() - store.lastInput) >= AFK_SECONDS
end

-- The player's primary kit: the first entry of PlayingAsKits, falling back to the older
-- singular attribute. Shared by everything that asks "what kit is this player on".
local function getPrimaryKit(plr)
	if not plr then return nil end

	local kit = plr:GetAttribute('PlayingAsKits')
	if type(kit) == 'string' and kit ~= '' then
		for _, name in string.split(kit, ',') do
			if name ~= '' then
				return name
			end
		end
	end

	kit = plr:GetAttribute('PlayingAsKit')
	if type(kit) == 'string' and kit ~= '' then
		return kit
	end
	return nil
end

local function getKitRenderImage(plr)
	if not plr then return '' end

	local kit = getPrimaryKit(plr)
	if not kit or kit == 'none' then return '' end

	local meta = bedwars.BedwarsKitMeta and bedwars.BedwarsKitMeta[kit]
	return (meta and meta.renderImage) or ''
end

local function isFriend(plr, recolor)
	if slinky.categories.Friends.options['Use friends'].enabled then
		local friend = table.find(slinky.categories.Friends.active, plr.Name) and true
		if recolor then
			friend = friend and slinky.categories.Friends.options['Recolor visuals'].enabled
		end
		return friend
	end
	return nil
end

local function isTarget(plr)
	return table.find(slinky.categories.Targets.active, plr.Name) and true
end

local function notif(...)
	return slinky:notify(...)
end

local function removeTags(str)
	str = str:gsub('<br%s*/>', '\n')
	return (str:gsub('<[^<>]->', ''))
end

local function roundPos(vec)
	return Vector3.new(math.round(vec.X / 3) * 3, math.round(vec.Y / 3) * 3, math.round(vec.Z / 3) * 3)
end

--[[ Developer-only equip trace (shared.PistonwareDeveloper). Swaps have to be caught while
the code that asked for them is still on the stack, so this runs before switchItem spawns
its request. Deduplicated per item and call site over half a second, so a module that
re-requests the same swap every frame logs it once rather than flooding the console. ]]
local equipTraceKey, equipTraceAt = nil, 0
local switchItemRequested = setmetatable({}, {__mode = 'k'})
local function traceEquip(tool, via)
	if not shared.PistonwareDeveloper then return end
	local ok, trace = pcall(debug.traceback, '', 3)
	trace = ok and trace or ''
	local now = os.clock()
	local key = tostring(tool) .. via .. trace
	if key == equipTraceKey and now - equipTraceAt < 0.5 then return end
	equipTraceKey, equipTraceAt = key, now
	local handInv = lplr.Character and lplr.Character:FindFirstChild('HandInvItem')
	local held = handInv and handInv.Value
	local cached = store and store.hand and store.hand.tool
	print(string.format('[pistonware equip] t=%.3f %s: holding %s (store.hand %s) -> %s%s',
		now, via,
		held and held.Name or 'nothing',
		cached and cached.Name or 'nothing',
		typeof(tool) == 'Instance' and tool.Name or tostring(tool),
		trace))
end

--[[ Equips a tool: HandInvItem is set locally at once and EquipItem goes to the server in its own
thread, then it waits delayTime. Nothing happens while a drink holds the hand (store.handHeld). In
developer mode the request is traced. ]]
local function switchItem(tool, delayTime)
	delayTime = delayTime or 0.05
	if store.handHeld(tool) then return false end
	local check = lplr.Character and lplr.Character:FindFirstChild('HandInvItem') or nil
	if check and check.Value ~= tool and tool.Parent ~= nil then
		if shared.PistonwareDeveloper then
			switchItemRequested[tool] = os.clock()
			traceEquip(tool, 'switchItem')
		end
		task.spawn(function()
			bedwars.Client:Get(remotes.EquipItem):CallServerAsync({hand = tool})
		end)
		check.Value = tool
		if delayTime > 0 then
			task.wait(delayTime)
		end
		return true
	end
end

local function waitForChildOfType(obj, name, timeout, prop)
	local check, returned = os.clock() + timeout
	repeat
		returned = prop and obj[name] or obj:FindFirstChildOfClass(name)
		if returned and returned.Name ~= 'UpperTorso' or check < os.clock() then
			break
		end
		task.wait()
	until false
	return returned
end

--[[ Root part for a non-player entity. Prefers a rig's HumanoidRootPart over whatever
the model names as its PrimaryPart, and settles for either.

Player dummies -- the tutorial ones included -- are character rigs, and a rig is
under no obligation to name a PrimaryPart. Asking for PrimaryPart alone spent the
whole timeout and then handed back nil, and a nil root is why the dummy never
reached the entity list at all. Where a rig does name one it is often UpperTorso,
which is the name the helper above already had to special-case; taking the root part
directly sidesteps that too. Monsters that are not rigs at all -- crates, statues --
have no HumanoidRootPart and still fall back to PrimaryPart. ]]
local function waitForRootPart(char, timeout)
	local check = os.clock() + timeout
	repeat
		local root = char:FindFirstChild('HumanoidRootPart') or char.PrimaryPart
		if root or check < os.clock() then return root end
		task.wait()
	until false
end

local frictionTable, oldfrict = {}, {}
local frictionConnection
local frictionState

local function modifyVelocity(v)
	if v:IsA('BasePart') and v.Name ~= 'HumanoidRootPart' and not oldfrict[v] then
		oldfrict[v] = v.CustomPhysicalProperties or 'none'
		v.CustomPhysicalProperties = PhysicalProperties.new(0.0001, 0.2, 0.5, 1, 1)
	end
end

--[[ Gives each of your character's parts except HumanoidRootPart near-zero density while anything is
listed in frictionTable, and puts each part's own CustomPhysicalProperties back when the list
empties. Parts an earlier character left behind are restored and released each time it turns on;
weak keys are not used, since an Instance's Lua handle can be collected while the part still lives,
losing its restore. With deferred dispatch, parts added later are changed from the pump, not inside
DescendantAdded, and only while friction is still on. ]]
local function updateVelocity(force)
	local newState = next(frictionTable) ~= nil
	if frictionState ~= newState or force then
		if frictionConnection then
			frictionConnection:Disconnect()
		end
		if newState then
			for part, props in oldfrict do
				if not part:IsDescendantOf(game) then
					oldfrict[part] = nil
					pcall(function()
						part.CustomPhysicalProperties = props ~= 'none' and props or nil
					end)
				end
			end
			if entitylib.isAlive then
				for _, v in entitylib.character.Character:GetDescendants() do
					modifyVelocity(v)
				end
				local queueDispatch = store.queueDispatch
				frictionConnection = entitylib.character.Character.DescendantAdded:Connect(queueDispatch and function(v)
					queueDispatch(function()
						if frictionState then modifyVelocity(v) end
					end)
				end or modifyVelocity)
			end
		else
			for i, v in oldfrict do
				i.CustomPhysicalProperties = v ~= 'none' and v or nil
			end
			table.clear(oldfrict)
		end
	end
	frictionState = newState
end

local kitorder = {
	hannah = 5,
	spirit_assassin = 4,
	dasher = 3,
	jade = 2,
	regent = 1
}

--[[ Target sort comparators: Damage, Threat, Kit, Health and Angle. Damage reads a missing
LastDamageTakenTime as 0, since nil < nil throws inside table.sort and ends the sorting loop. Angle
compares the raw dot products the other way round instead of their acos (acos falls on [-1, 1]), the
same order without two acos calls per comparison; it runs every Heartbeat when sorting by Angle. ]]
local sortmethods = {
	Damage = function(a, b)
		return (a.Entity.Character:GetAttribute('LastDamageTakenTime') or 0) < (b.Entity.Character:GetAttribute('LastDamageTakenTime') or 0)
	end,
	Threat = function(a, b)
		return getStrength(a.Entity) > getStrength(b.Entity)
	end,
	Kit = function(a, b)
		return (a.Entity.Player and kitorder[getPrimaryKit(a.Entity.Player)] or 0) > (b.Entity.Player and kitorder[getPrimaryKit(b.Entity.Player)] or 0)
	end,
	Health = function(a, b)
		return a.Entity.Health < b.Entity.Health
	end,
	Angle = function(a, b)
		local selfroot = entitylib.character.RootPart
		local selfrootpos = selfroot.Position
		local localfacing = selfroot.CFrame.LookVector * Vector3.new(1, 0, 1)
		local dota = localfacing:Dot(((a.Entity.RootPart.Position - selfrootpos) * Vector3.new(1, 0, 1)).Unit)
		local dotb = localfacing:Dot(((b.Entity.RootPart.Position - selfrootpos) * Vector3.new(1, 0, 1)).Unit)
		return dota > dotb
	end
}

run(function()
	local oldstart = entitylib.start
	-- Deferred dispatch: the game-signal handlers below queue their work for the dispatch pump (see
	-- store.queueDispatch). nil and a pass-through on Solara and Xeno.
	local queueDispatch, dispatchSafe = store.queueDispatch, store.dispatchSafe

	--[[ A Practice room dummy is identified by either of the two markers.
	training-room-entity-controller watches the tag and then reads the attribute off
	the instance; the attribute is the half that actually shows up on a dummy in the
	explorer, so neither is trusted alone. ]]
	local function isTrainingDummy(ent)
		return ent:HasTag('trainingRoomDummy') or ent:GetAttribute('TrainingRoomDummy') ~= nil
	end

	--[[ Registers a tagged NPC as an entity. Inventory entities (shop keepers and lobby furniture) are
	skipped, except monsters and training dummies, which carry the same ArmorInvItem/HandInvItem
	rig. Monsters are watched under their own tag as well as 'entity', so one already registered or
	being built is skipped. A drone is targetable when its owner (PlayerUserId) is not on your team;
	anything else without a Team attribute is always targetable, since practice and tutorial dummies
	carry none, and in the lobby neither do you. ]]
	local function customEntity(ent)
		if ent:HasTag('inventory-entity') and not (ent:HasTag('Monster') or isTrainingDummy(ent)) then
			return
		end

		if entitylib.EntityThreads[ent] or entitylib.getEntity(ent) then
			return
		end

		entitylib.addEntity(ent, nil, ent:HasTag('Drone') and function(self)
			local droneplr = playersService:GetPlayerByUserId(self.Character:GetAttribute('PlayerUserId'))
			return not droneplr or lplr:GetAttribute('Team') ~= droneplr:GetAttribute('Team')
		end or function(self)
			local theirteam = self.Character:GetAttribute('Team')
			if theirteam == nil then return true end
			return lplr:GetAttribute('Team') ~= theirteam
		end)
	end

	--[[ Dummies are entities the 'entity' tag alone never reaches, and they come in two
	kinds under two different tags:

	  Monster             tutorial dummies. The game's own entity-util resolves these
	                      through its inventory-entity branch, which returns before it
	                      ever asks whether the instance carries 'entity' -- so a
	                      player dummy is a full entity to the game while being
	                      invisible to a watcher that only knows the one tag. Monster
	                      is what the game itself watches for them, in
	                      player-dummy-controller and in the tutorial's kill tasks.
	  trainingRoomDummy   the Practice room's dummies, tagged and driven entirely by
	                      training-room-entity-controller.

	customEntity dedupes, so anything holding more than one of these is still
	registered once. ]]
	local ENTITY_TAGS = {'entity', 'Monster', 'trainingRoomDummy'}

	local onEntityTagged = dispatchSafe(customEntity)
	local onEntityUntagged = dispatchSafe(function(ent)
		entitylib.removeEntity(ent)
	end)

	entitylib.start = function()
		oldstart()
		if entitylib.Running then
			for _, tag in ENTITY_TAGS do
				for _, ent in collectionService:GetTagged(tag) do
					customEntity(ent)
				end
				table.insert(entitylib.Connections, collectionService:GetInstanceAddedSignal(tag):Connect(onEntityTagged))
				table.insert(entitylib.Connections, collectionService:GetInstanceRemovedSignal(tag):Connect(onEntityUntagged))
			end
		end
	end

	--[[ EntityUpdated from the handlers below, a frame late and once per entity per frame.
	Every one of them is a signal that runs its handler inside the write that fired it -- the
	Health, MaxHealth and Shield attributes, the kit attributes, an NPC's Humanoid, the Team
	attribute -- and what EntityUpdated reaches, NameTags most of all, raises the thread identity
	and rewrites GUI. Fired from a deferred thread none of that runs inside someone else's write,
	and the Health and Shield changes of one hit draw once. The entity's own fields are still
	updated at once, so anything reading Health or Targetable this frame reads the new value. ]]
	local pendingUpdates = {}

	--[[ Deferred dispatch: one pump job sends everything queued since the last one, so no thread is made
	inside the write. With nothing listening (every module off) it neither raises the thread
	identity nor fires. ]]
	local updatesQueued = false
	--[[ The pump job that fires EntityUpdated once for each entity queued since the last one, in a
	thread of its own at identity 8 (slinky.threadFix) so the raised identity ends with it. With no
	listener connected nothing fires; entities that left entitylib.List are skipped. ]]
	local function flushEntityUpdates()
		updatesQueued = false
		local batch = {}
		for entity in pendingUpdates do
			table.insert(batch, entity)
		end
		table.clear(pendingUpdates)
		local event, list = entitylib.Events.EntityUpdated, entitylib.List
		if not (list and event.Connections and #event.Connections > 0) then return end
		task.spawn(function()
			if slinky.threadFix then
				local ok, identity = pcall(getthreadidentity)
				if not (ok and identity == 8) then
					setthreadidentity(8)
				end
			end
			for _, entity in batch do
				if table.find(list, entity) then
					event:Fire(entity)
				end
			end
		end)
	end

	--[[ Queues one EntityUpdated for an entity, once per frame at most: through the dispatch pump where
	there is one, else a deferred thread at identity 8. An entity that has left entitylib.List
	(removed, or rebuilt into a new table) is not announced. ]]
	local function queueEntityUpdate(entity)
		if pendingUpdates[entity] then return end
		pendingUpdates[entity] = true
		if queueDispatch then
			if not updatesQueued then
				updatesQueued = true
				queueDispatch(flushEntityUpdates)
			end
			return
		end
		task.defer(function()
			pendingUpdates[entity] = nil
			if slinky.threadFix then
				setthreadidentity(8)
			end
			local list = entitylib.List
			if not (list and table.find(list, entity)) then return end
			entitylib.Events.EntityUpdated:Fire(entity)
		end)
	end

	--[[ Tracks a player's characters and team. CharacterAdded and CharacterRemoving go through the pump,
	so a removal still runs ahead of the arrival after it. BedWars sets the team as a Team attribute
	after the entity is built, and the library watches the Team property, which BedWars never sets:
	this listener re-checks Targetable in place with entitylib.updateEntity. Never rebuild here:
	refreshEntity swap-removes from the entitylib.List being walked, entitylib.start() drops this
	file's CollectionService hooks for drones, guardians and dummies, and a rebuild replaces the
	entity tables modules hold. ]]
	entitylib.addPlayer = function(plr)
		if plr.Character then
			entitylib.refreshEntity(plr.Character, plr)
		end
		entitylib.PlayerConnections[plr] = {
			plr.CharacterAdded:Connect(dispatchSafe(function(char)
				entitylib.refreshEntity(char, plr)
			end)),
			plr.CharacterRemoving:Connect(dispatchSafe(function(char)
				entitylib.removeEntity(char, plr == lplr)
			end)),
			plr:GetAttributeChangedSignal('Team'):Connect(function()
				if plr == lplr then
					for _, v in entitylib.List do
						if entitylib.updateEntity(v) then
							queueEntityUpdate(v)
						end
					end
				else
					local ent = entitylib.getEntity(plr)
					if ent and entitylib.updateEntity(ent) then
						queueEntityUpdate(ent)
					end
				end
			end)
		}
	end

	--[[ WaitForChild, polled. A restart cancels every builder still waiting (entitylib.stop
	does it), and a builder parked in WaitForChild is held by the engine, which still tries to
	resume it when the child turns up -- the likely source of the "cannot resume dead coroutine"
	at boot. Parked on task.wait, a cancel always lands on a yield it owns. Same answer as
	WaitForChild: the child, or nil once the timeout has passed. ]]
	local function waitForNamedChild(parent, name, timeout)
		local check = os.clock() + timeout
		repeat
			local child = parent:FindFirstChild(name)
			if child or check < os.clock() then return child end
			task.wait()
		until false
	end

	--[[ The local character's attribute forwarder. Each local build used to add one to
	entitylib.Connections, where it stayed until the library stopped, so every character you had
	been this match stayed referenced by its listener. Only the newest is kept: the previous one
	goes when the next is connected, never on death, so the live character forwards for exactly
	as long as it did. ]]
	local localForwarder

	--[[ Builds an entity for a character in its own thread, kept in EntityThreads only while it is still
	running: a build that finishes without yielding would otherwise leave a dead thread there, and
	the next removeEntity would throw on the cancel instead of firing EntityRemoved.

	For your own character only the newest attribute forwarder is kept. Other entities get their
	fields refreshed at once and EntityUpdated a frame later. An NPC is built around a stand-in
	humanoid table, so its real Humanoid's Health and MaxHealth are watched too, including a
	Humanoid parented after the entity. The build can yield for seconds (each armor slot waits up to
	5 s); a player who leaves or a character destroyed in that window is dropped instead of added.
	The attribute forwarder, inventory refreshes and removals go through the dispatch pump, and a
	queued local removal goes ahead only while entitylib.character is still this entity. ]]
	entitylib.addEntity = function(char, plr, teamfunc)
		if not char then return end
		local builder = task.spawn(function()
			local hum, humrootpart, head
			if plr then
				hum = waitForChildOfType(char, 'Humanoid', 10)
				humrootpart = hum and waitForChildOfType(hum, 'RootPart', workspace.StreamingEnabled and 9e9 or 10, true)
				head = waitForNamedChild(char, 'Head', 10) or humrootpart
			else
				hum = {HipHeight = 0.5}
				humrootpart = waitForRootPart(char, 10)
				head = humrootpart
			end
			local updateobjects = plr and plr ~= lplr and {
				waitForNamedChild(char, 'ArmorInvItem_0', 5),
				waitForNamedChild(char, 'ArmorInvItem_1', 5),
				waitForNamedChild(char, 'ArmorInvItem_2', 5),
				waitForNamedChild(char, 'HandInvItem', 5)
			} or {}

			if hum and humrootpart then
				local startHealth, startMaxHealth = entitylib.readHealth(char)
				local entity = {
					Connections = {},
					Character = char,
					Health = startHealth,
					Head = head,
					Humanoid = hum,
					HumanoidRootPart = humrootpart,
					HipHeight = hum.HipHeight + (humrootpart.Size.Y / 2) + (hum.RigType == Enum.HumanoidRigType.R6 and 2 or 0),
					Jumps = 0,
					JumpTick = os.clock(),
					Jumping = false,
					LandTick = os.clock(),
					MaxHealth = startMaxHealth,
					NPC = plr == nil,
					Player = plr,
					RootPart = humrootpart,
					TeamCheck = teamfunc
				}

				if plr == lplr then
					entity.AirTime = os.clock()
					entitylib.character = entity
					entitylib.isAlive = true
					entitylib.Events.LocalAdded:Fire(entity)
					if localForwarder then
						local index = table.find(entitylib.Connections, localForwarder)
						if index then
							table.remove(entitylib.Connections, index)
						end
						localForwarder:Disconnect()
					end
					localForwarder = char.AttributeChanged:Connect(dispatchSafe(function(attr)
						slinkyEvents.AttributeChanged:Fire(attr)
					end))
					table.insert(entitylib.Connections, localForwarder)
				else
					entity.Targetable = entitylib.targetCheck(entity)

					local function refreshHealth()
						entity.Health, entity.MaxHealth = entitylib.readHealth(char)
						queueEntityUpdate(entity)
					end

					for _, v in entitylib.getUpdateConnections(entity) do
						table.insert(entity.Connections, v:Connect(refreshHealth))
					end

					if not plr then
						local function watchHumanoid(humanoid)
							table.insert(entity.Connections, humanoid:GetPropertyChangedSignal('Health'):Connect(refreshHealth))
							table.insert(entity.Connections, humanoid:GetPropertyChangedSignal('MaxHealth'):Connect(refreshHealth))
							refreshHealth()
						end
						local humanoid = char:FindFirstChildOfClass('Humanoid')
						if humanoid then
							watchHumanoid(humanoid)
						else
							local waiting
							waiting = char.ChildAdded:Connect(function(child)
								if child:IsA('Humanoid') then
									waiting:Disconnect()
									watchHumanoid(child)
								end
							end)
							table.insert(entity.Connections, waiting)
						end
					end

					local onInventoryItem = dispatchSafe(function()
						task.delay(0.1, function()
							if bedwars.getInventory then
								store.inventories[plr] = bedwars.getInventory(plr)
								entitylib.Events.EntityUpdated:Fire(entity)
							end
						end)
					end)
					for _, v in updateobjects do
						table.insert(entity.Connections, v:GetPropertyChangedSignal('Value'):Connect(onInventoryItem))
					end

					if plr then
						local anim = char:FindFirstChild('Animate')
						if anim then
							pcall(function()
								anim = anim.jump:FindFirstChildWhichIsA('Animation').AnimationId
								table.insert(entity.Connections, hum.Animator.AnimationPlayed:Connect(function(playedanim)
									if playedanim.Animation.AnimationId == anim then
										entity.JumpTick = os.clock()
										entity.Jumps += 1
										entity.LandTick = os.clock() + 1
										entity.Jumping = entity.Jumps > 1
									end
								end))
							end)
						end

						task.delay(0.1, function()
							if bedwars.getInventory then
								store.inventories[plr] = bedwars.getInventory(plr)
							end
						end)
					end
					if not char.Parent or (plr and plr.Parent == nil) then
						for _, connection in entity.Connections do
							pcall(function() connection:Disconnect() end)
						end
						table.clear(entity.Connections)
						entitylib.EntityThreads[char] = nil
						return
					end

					table.insert(entitylib.List, entity)
					entitylib.Events.EntityAdded:Fire(entity)
				end

				table.insert(entity.Connections, char.ChildRemoved:Connect(function(part)
					if part == humrootpart or part == hum or part == head then
						if part == humrootpart and hum.RootPart then
							humrootpart = hum.RootPart
							entity.RootPart = hum.RootPart
							entity.HumanoidRootPart = hum.RootPart
							return
						end
						if queueDispatch then
							queueDispatch(function()
								if plr == lplr and entitylib.character ~= entity then return end
								entitylib.removeEntity(char, plr == lplr)
							end)
							return
						end
						entitylib.removeEntity(char, plr == lplr)
					end
				end))
			end
			entitylib.EntityThreads[char] = nil
		end)

		if coroutine.status(builder) ~= 'dead' then
			entitylib.EntityThreads[char] = builder
		end
	end

	--[[ Health and max health for any entity's character, shields folded into health the way
	players have always been read. Players carry both as attributes; dummies and monsters may
	only have them on a Humanoid, so that is the fallback rather than a flat 100. ]]
	entitylib.readHealth = function(char)
		local health = char:GetAttribute('Health')
		local maxHealth = char:GetAttribute('MaxHealth')
		if health == nil or maxHealth == nil then
			local humanoid = char:FindFirstChildOfClass('Humanoid')
			if humanoid then
				health = health or humanoid.Health
				maxHealth = maxHealth or humanoid.MaxHealth
			end
		end
		return (health or 100) + getShieldAttribute(char), maxHealth or 100
	end

	--[[ The signals that refresh an entity: Health, MaxHealth and every numeric Shield attribute, and
	for a player PlayingAsKits (the attribute the game updates) and PlayingAsKit. A pseudo-signal
	sets Friend and Target when it is connected. ]]
	entitylib.getUpdateConnections = function(ent)
		local char = ent.Character
		local tab = {
			char:GetAttributeChangedSignal('Health'),
			char:GetAttributeChangedSignal('MaxHealth'),
			{
				Connect = function()
					ent.Friend = ent.Player and isFriend(ent.Player) or nil
					ent.Target = ent.Player and isTarget(ent.Player) or nil
					return {Disconnect = function() end}
				end
			}
		}

		if ent.Player then
			table.insert(tab, ent.Player:GetAttributeChangedSignal('PlayingAsKits'))
			table.insert(tab, ent.Player:GetAttributeChangedSignal('PlayingAsKit'))
		end

		for name, val in char:GetAttributes() do
			if name:find('Shield') and type(val) == 'number' then
				table.insert(tab, char:GetAttributeChangedSignal(name))
			end
		end

		return tab
	end

	entitylib.targetCheck = function(ent)
		if ent.TeamCheck then
			return ent:TeamCheck()
		end
		if ent.NPC then return true end
		if isFriend(ent.Player) then return false end
		return lplr:GetAttribute('Team') ~= ent.Player:GetAttribute('Team')
	end

	--[[ Milo hiding as a block, for Ignore Milo in the Targets row. The server tags a hidden player
	PlayerHidden (the game's own target selectors skip them), and the block the client draws in their
	place is DisguisedPlayerBlock_<UserId> in the workspace; either one is enough. ]]
	entitylib.isDisguised = function(ent)
		local plr = ent.Player
		if not plr then return false end
		return plr:HasTag('PlayerHidden') or workspace:FindFirstChild('DisguisedPlayerBlock_'..plr.UserId) ~= nil
	end

	-- Deferred dispatch: only the library's PlayerRemoving handler calls this; queued like the character
	-- removals, so its disconnects and EntityRemoved do not run inside that dispatch.
	if queueDispatch then
		entitylib.removePlayer = dispatchSafe(entitylib.removePlayer)
	end
	slinky:clean(entitylib.Events.LocalAdded:Connect(updateVelocity))
end)
entitylib.start()

--[[ pistonware funcs ]]

--[[ getgenv() where it works. Elsewhere (Xeno has none) one plain table stands in, kept on shared
so every file that runs this session shares the same one. ]]
local genv
if exec.Genv then
	local ok, env = pcall(getgenv)
	genv = ok and env or nil
end
if type(genv) ~= 'table' then
	genv = type(shared.PistonwareGenv) == 'table' and shared.PistonwareGenv or {}
	shared.PistonwareGenv = genv
end
--[[ Idempotent shared-state defaults: fill a key only if a previous execution
hasn't already set it. Add new flags here instead of another line below.
(== nil, not `or`, so a stored `false` is never clobbered back to default.) ]]
for key, default in pairs({
	IsLongJumping            = false,
	LongJumpFireballThrown   = false,
	ItemOwner                = "none",
	ProjectileAuraFiringLock = false,
}) do
	if genv[key] == nil then
		genv[key] = default
	end
end

local function ensureCharPrimaryPart(char)
    if not char then return end
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if hrp and char.PrimaryPart ~= hrp then
        pcall(function() char.PrimaryPart = hrp end)
    end
end

ensureCharPrimaryPart(lplr.Character)
--[[ Sets each new character's PrimaryPart to its HumanoidRootPart (ensureCharPrimaryPart), waiting up to
5 s for the root. With deferred dispatch it starts from the pump and polls instead of WaitForChild,
so the PrimaryPart write never lands inside CharacterAdded or the root's ChildAdded. ]]
slinky:clean(lplr.CharacterAdded:Connect(store.queueDispatch and store.dispatchSafe(function(c)
    task.spawn(function()
        local deadline = os.clock() + 5
        while not c:FindFirstChild("HumanoidRootPart") and os.clock() < deadline do
            task.wait()
        end
        ensureCharPrimaryPart(c)
    end)
end) or function(c)
    c:WaitForChild("HumanoidRootPart", 5)
    ensureCharPrimaryPart(c)
end))

--[[ == shared __namecall guard ==
There is exactly ONE global __namecall hook in the whole product and it lives
here. Every namecall in the game -- including the tens of thousands Roact issues
while it builds and re-renders the item shop -- passes through this function, so
it must stay fast. A second hook installed elsewhere adds its own cost to each of
those calls, which is what turned opening the shop (and every purchase re-render)
into a visible hitch.

Modules that need to see or block a specific remote register the exact
(Instance, method) pair here via shared.bedwars.namecallGuard instead. The hot
path cost is one hash lookup; handlers only ever run for instances somebody
actually asked about. ]]
local namecallWatch = {}
local namecallGuard = {}
local namecallObservers = {}

--[[ handler may be `true` to swallow the call outright, or a function. From a function:
  nil / false       -- let the call through unchanged
  a table           -- REPLACEMENT ARGUMENTS, table.pack shape (`n` plus 1..n), forwarded
                       to the same method in place of the originals
  any other truthy  -- swallow the call
Method names are matched exactly as getnamecallmethod() reports them.

The table form exists so a module can rewrite what a remote sends without installing a
second __namecall hook of its own. That is not a style preference: a second hook adds its
cost to EVERY namecall in the game, and the item shop issues tens of thousands of them per
Roact render -- enough to take the client down when the shop opens. Registering here costs one hash lookup on the hot path instead. ]]
function namecallGuard.watch(inst, method, handler)
    if typeof(inst) ~= 'Instance' or type(method) ~= 'string' then return false end
    local entry = namecallWatch[inst]
    if not entry then
        entry = {}
        namecallWatch[inst] = entry
    end
    entry[method] = handler or true
    return true
end

--[[ Marks that the __namecall body below understands a table return as replacement arguments.
bedwars.lua ships from GitLab and this file from GitHub, and both are cached independently,
so the two genuinely can run out of step. Against a guard that predates the contract a
returned table reads as plain truthy -- i.e. "swallow" -- so the call the handler meant to
adjust is eaten instead, and the module looks broken rather than absent. Modules test this
before registering a rewriting handler. ]]
namecallGuard.rewrites = true

function namecallGuard.block(inst, method)
    return namecallGuard.watch(inst, method, true)
end

function namecallGuard.unwatch(inst, method)
    local entry = inst and namecallWatch[inst]
    if not entry then return end
    if method then
        entry[method] = nil
        if next(entry) == nil then
            namecallWatch[inst] = nil
        end
    else
        namecallWatch[inst] = nil
    end
end

function namecallGuard.unwatchIf(inst, method, handler)
    local entry = inst and namecallWatch[inst]
    if not entry or entry[method] ~= handler then return false end
    namecallGuard.unwatch(inst, method)
    return true
end

-- Observers never change the result of a watched call. They are separate from the
-- replacement/block table so a diagnostic listener can coexist with a module that
-- rewrites or suppresses the same remote.
function namecallGuard.observe(inst, method, handler)
    if typeof(inst) ~= 'Instance' or type(method) ~= 'string' or type(handler) ~= 'function' then
        return nil
    end
    local byMethod = namecallObservers[inst]
    if not byMethod then
        byMethod = {}
        namecallObservers[inst] = byMethod
    end
    local observers = byMethod[method]
    if not observers then
        observers = {}
        byMethod[method] = observers
    end
    local token = {instance = inst, method = method, handler = handler}
    table.insert(observers, token)
    return token
end

function namecallGuard.unobserve(token)
    if type(token) ~= 'table' then return false end
    local byMethod = namecallObservers[token.instance]
    local observers = byMethod and byMethod[token.method]
    if not observers then return false end
    for index = #observers, 1, -1 do
        if observers[index] == token then
            table.remove(observers, index)
            if #observers == 0 then
                byMethod[token.method] = nil
            end
            if next(byMethod) == nil then
                namecallObservers[token.instance] = nil
            end
            return true
        end
    end
    return false
end

--[[ The raw hook only goes in where the executor probe proved getnamecallmethod and found the raw
metatable writable. Solara has getrawmetatable and setreadonly but not a getnamecallmethod that can
be trusted: installed there, this hook would put every namecall in the game through a broken
function. Without it, see the block after this one. ]]
namecallGuard.supported = exec.Namecall and exec.Rawmeta
namecallGuard.mode = namecallGuard.supported and 'namecall' or nil
--[[ The namecall hook behind namecallGuard. Observers run first and never change the call; then a watch
entry blocks it (true, or a truthy non-table result), replaces its arguments (a table) or lets it
through.

Every reinject chains to the first injection's original __namecall (shared.PistonwareOldNamecall),
so the chain stays one deep; shared does not survive a teleport, which brings a fresh metatable. A
handled call is forwarded as a namecall while getnamecallmethod() still reports the method, because
calling self[method] makes a remote spy or another hook see the call twice; a handler that rewrote
the arguments or made namecalls of its own falls back to self[method].

With store.deferDispatch nothing is written at load. Executors have native code on the namecall path
and Delta's client died at the next place load with this code always on, so the hook goes in through
hookmetamethod (a raw write only without it), from a Heartbeat step, once something is registered
and a module is on. Registrations arrive inside signal handlers, and hooking from there is the
nested dispatch this avoids, so a watch registered at enable takes effect up to one frame later,
first time only. hookmetamethod may leave a wrapper in the slot, so the previous hook is recognised
by PistonwareNamecallTop and PistonwareNamecallRest. On uninject the original goes back only while
this hook is the live one. ]]
if namecallGuard.supported then
local getnamecallmethod = getnamecallmethod
local mt = getrawmetatable(game)
if not store.deferDispatch then
setreadonly(mt, false)
end
local previousNamecallHook = shared.PistonwareNamecallHook
local oldNamecall = mt.__namecall
if not store.deferDispatch then
if previousNamecallHook and oldNamecall == previousNamecallHook and shared.PistonwareOldNamecall then
    oldNamecall = shared.PistonwareOldNamecall
end
shared.PistonwareOldNamecall = oldNamecall
end
local namecallHook = function(self, ...)
    local method = getnamecallmethod()
    if method == "GetPrimaryPartCFrame" and self and self:IsA("Model") then
        local pp = self.PrimaryPart
            or self:FindFirstChild("HumanoidRootPart")
            or self:FindFirstChildWhichIsA("BasePart")
        if pp then
            return pp.CFrame
        else
            return CFrame.new()
        end
    end
    local observerMethods = namecallObservers[self]
    local observers = observerMethods and observerMethods[method]
    if observers then
        for _, token in observers do
            pcall(token.handler, self, ...)
        end
    end

    local entry = namecallWatch[self]
    if entry then
        local handler = entry[method]
        if handler == true then
            return
        elseif handler then
            local ok, result = pcall(handler, self, ...)
            if ok and result ~= nil and result ~= false and type(result) ~= 'table' then
                return
            end
            local replacement = (ok and type(result) == 'table') and result or nil

            if not replacement and getnamecallmethod() == method then
                return oldNamecall(self, ...)
            end

            local fn = self[method]
            if type(fn) == 'function' then
                if replacement then
                    return fn(self, table.unpack(replacement, 1, replacement.n or #replacement))
                end
                return fn(self, ...)
            end
        end
    end
    return oldNamecall(self, ...)
end
if not store.deferDispatch then
mt.__namecall = namecallHook
shared.PistonwareNamecallHook = namecallHook
setreadonly(mt, true)
end

if not store.deferDispatch then
slinky:clean(function()
    table.clear(namecallWatch)
    table.clear(namecallObservers)
    if mt.__namecall == namecallHook then
        setreadonly(mt, false)
        mt.__namecall = oldNamecall
        setreadonly(mt, true)
    end
    if shared.PistonwareNamecallHook == namecallHook then
        shared.PistonwareNamecallHook = nil
    end
    if shared.PistonwareOldNamecall == oldNamecall then
        shared.PistonwareOldNamecall = nil
    end
end)
else
local deltaMode, deltaClosed, deltaTop
local function installDelta()
    if deltaMode then return true end
    if deltaClosed then return false end

    local current = mt.__namecall
    local first = shared.PistonwareOldNamecall
    local reuse = first ~= nil and (current == (shared.PistonwareNamecallTop or shared.PistonwareNamecallHook)
        or current == shared.PistonwareNamecallRest)
    oldNamecall = reuse and first or current

    if type(hookmetamethod) == 'function' then
        local ok, original = pcall(hookmetamethod, game, '__namecall', namecallHook)
        if not ok then
            deltaClosed = true
            return false
        end
        if not reuse and type(original) == 'function' then
            oldNamecall = original
        end
        deltaMode = 'hookmetamethod'
    else
        local ok = pcall(function()
            setreadonly(mt, false)
            mt.__namecall = namecallHook
            setreadonly(mt, true)
        end)
        if not ok then
            deltaClosed = true
            return false
        end
        deltaMode = 'raw'
    end

    deltaTop = mt.__namecall
    shared.PistonwareOldNamecall = oldNamecall
    shared.PistonwareNamecallHook = namecallHook
    shared.PistonwareNamecallTop = deltaTop
    shared.PistonwareNamecallRest = nil
    bufferCall('print', 'bedwars.namecall', string.format('hook in (%s, %s) %.2fs after Knit started',
        deltaMode, rawequal(deltaTop, current) and 'hooked in place' or 'slot replaced',
        os.clock() - (namecallGuard.knitReadyAt or os.clock())))
    return true
end

local watch, observe = namecallGuard.watch, namecallGuard.observe
function namecallGuard.watch(...)
    if deltaClosed then return false end
    return watch(...)
end
function namecallGuard.observe(...)
    if deltaClosed then return nil end
    return observe(...)
end

slinky:clean(runService.Heartbeat:Connect(function()
    if deltaMode or deltaClosed then return end
    if next(namecallWatch) == nil and next(namecallObservers) == nil then return end
    for _, module in slinky.modules do
        if module.enabled then
            installDelta()
            return
        end
    end
end))

slinky:clean(function()
    deltaClosed = true
    table.clear(namecallWatch)
    table.clear(namecallObservers)
    local mode = deltaMode
    deltaMode = nil
    if not mode then return end
    if mt.__namecall == deltaTop then
        if mode == 'hookmetamethod' then
            pcall(hookmetamethod, game, '__namecall', oldNamecall)
        else
            pcall(function()
                setreadonly(mt, false)
                mt.__namecall = oldNamecall
                setreadonly(mt, true)
            end)
        end
        shared.PistonwareNamecallRest = mt.__namecall
    end
    if shared.PistonwareNamecallHook == namecallHook then
        shared.PistonwareNamecallHook = nil
        shared.PistonwareNamecallTop = nil
    end
end)
end
end

--[[ namecallGuard without a trustworthy namecall hook (Solara, Xeno): watch and block answer false and
observe nil, which every caller treats as unsupported, except for the game's own @rbxts/net sends
where exec.Live holds. Every net client object inherits SendToServer, CallServer and CallServerAsync
from a class table shared by all of them, including those cached at start, so replacing those
methods, keyed on the remote each object wraps, shows those sends to the same handlers with the same
contract. That covers every remote under both _NetManaged folders (the main copy and
block-engine's), and watch and observe accept exactly those; a direct :FireServer, Zap buffers and
the GetPrimaryPartCFrame fallback are not seen. The methods are replaced only once something
registers and are put back on uninject; a wrapper an earlier injection left is chained past to its
original.

exec.Live, not exec.Require: where require re-runs module code, requiring the net and Promise
modules errors them and poisons the game's own copies, which breaks the item shop's Knit chain. A
swallowed send or blocking call returns nothing; a swallowed async call returns a promise from the
game's library (resolved for a Function, rejected for an AsyncFunction), so the async forms are
wrapped only when that library loaded. AsyncFunction sends go as FireServer(requestId, {arguments});
handlers see '' as the id. ]]
if not namecallGuard.supported then
	local netGuard
	if exec.Live then
		local function dispatch(inst, method, ...)
			local observerMethods = namecallObservers[inst]
			local observers = observerMethods and observerMethods[method]
			if observers then
				for _, token in observers do
					pcall(token.handler, inst, ...)
				end
			end
			local entry = namecallWatch[inst]
			local handler = entry and entry[method]
			if handler == nil then return nil end
			if handler == true then return true end
			local ok, result = pcall(handler, inst, ...)
			if not ok or result == nil or result == false then return nil end
			if type(result) == 'table' then return false, result end
			return true
		end

		local built, guard = pcall(function()
			local outs = {}
			pcall(function()
				table.insert(outs, replicatedStorage.rbxts_include.node_modules['@rbxts'].net.out)
			end)
			pcall(function()
				table.insert(outs, replicatedStorage.rbxts_include.node_modules['@easy-games']['block-engine'].node_modules['@rbxts'].net.out)
			end)
			local promise
			pcall(function()
				local library = require(replicatedStorage.rbxts_include.Promise)
				if type(library) == 'table' and type(library.resolve) == 'function' and type(library.reject) == 'function' then
					promise = library
				end
			end)
			local folders, classes = {}, {}
			for _, out in outs do
				local folder, client = out:FindFirstChild('_NetManaged'), out:FindFirstChild('client')
				if folder and client then
					table.insert(folders, folder)
					for kind, moduleName in {Event = 'ClientEvent', Function = 'ClientFunction', AsyncFunction = 'ClientAsyncFunction'} do
						local module = client:FindFirstChild(moduleName)
						local exported = module and require(module)
						if type(exported) == 'table' and type(exported.default) == 'table' and require(module) == exported then
							table.insert(classes, {kind = kind, class = exported.default})
						end
					end
				end
			end
			assert(#folders > 0 and #classes > 0, 'the @rbxts/net client classes are unavailable')
			local specs = {
				Event = {{key = 'SendToServer', method = 'FireServer', swallowed = function() return nil end}},
				Function = {
					{key = 'CallServer', method = 'InvokeServer', swallowed = function() return nil end},
					{key = 'CallServerAsync', method = 'InvokeServer', swallowed = function() return promise.resolve(nil) end}
				},
				AsyncFunction = {{key = 'CallServerAsync', method = 'FireServer', packed = true,
					swallowed = function() return promise.reject('the request was not sent') end}}
			}
			local state = shared.PistonwareNetGuard
			if type(state) ~= 'table' then
				state = {wrappers = setmetatable({}, {__mode = 'k'})}
				shared.PistonwareNetGuard = state
			end
			local patches, installed, closed = {}, false, false

			local function wrap(original, spec)
				return function(self, ...)
					local inst = type(self) == 'table' and rawget(self, 'instance') or nil
					if inst == nil then return original(self, ...) end
					local action, replacement
					if spec.packed then
						action, replacement = dispatch(inst, spec.method, '', {...})
					else
						action, replacement = dispatch(inst, spec.method, ...)
					end
					if action == true then return spec.swallowed() end
					if action == false then
						local args = replacement
						if spec.packed then args = type(replacement[2]) == 'table' and replacement[2] or {} end
						return original(self, table.unpack(args, 1, args.n or #args))
					end
					return original(self, ...)
				end
			end

			local api = {}
			function api.covers(inst, method)
				if method ~= 'FireServer' and method ~= 'InvokeServer' then return false end
				if typeof(inst) ~= 'Instance' then return false end
				local ok, parent = pcall(function() return inst.Parent end)
				if not ok then return false end
				for _, folder in folders do
					if parent == folder then return true end
				end
				return false
			end
			function api.restore()
				closed = true
				for index = #patches, 1, -1 do
					local patch = patches[index]
					pcall(function()
						if patch.class[patch.key] == patch.wrapper then
							patch.class[patch.key] = patch.original
						end
					end)
					state.wrappers[patch.wrapper] = nil
				end
				table.clear(patches)
				installed = false
			end
			function api.install()
				if installed then return true end
				if closed then return false end
				if not exec.Live then return false end
				local ok = pcall(function()
					for _, item in classes do
						for _, spec in specs[item.kind] do
							local current = item.class[spec.key]
							if type(current) == 'function' and (spec.key ~= 'CallServerAsync' or promise) then
								local original = state.wrappers[current] or current
								local wrapper = wrap(original, spec)
								item.class[spec.key] = wrapper
								state.wrappers[wrapper] = original
								table.insert(patches, {class = item.class, key = spec.key, wrapper = wrapper, original = original})
							end
						end
					end
				end)
				if not ok then
					api.restore()
					closed = false
					return false
				end
				installed = true
				return true
			end
			return api
		end)
		if built then
			netGuard = guard
		else
			bufferCall('error', 'bedwars.netguard', guard)
		end
	end

	namecallGuard.mode = netGuard and 'net' or nil
	namecallGuard.rewrites = netGuard ~= nil
	local baseWatch, baseObserve = namecallGuard.watch, namecallGuard.observe
	function namecallGuard.watch(inst, method, handler)
		if not (netGuard and netGuard.covers(inst, method) and netGuard.install()) then return false end
		return baseWatch(inst, method, handler)
	end
	function namecallGuard.observe(inst, method, handler)
		if not (netGuard and netGuard.covers(inst, method) and netGuard.install()) then return nil end
		return baseObserve(inst, method, handler)
	end
	slinky:clean(function()
		table.clear(namecallWatch)
		table.clear(namecallObservers)
		if netGuard then netGuard.restore() end
	end)
end

local blankFunction = function(...) return ... end

local fpsHooks = {}
do
    local scopes = {}

    local function removeScope(scope)
        for i = #scopes, 1, -1 do
            if scopes[i] == scope then
                table.remove(scopes, i)
                return
            end
        end
    end

    local function newScope()
        local scope = {
            active = true,
            connections = {},
            watches = {},
            patches = {},
            properties = {},
            finalizers = {},
            restoreProperties = true
        }

        function scope:isActive()
            return self.active
        end

        function scope:connect(connection)
            if not self.active then
                pcall(function() connection:Disconnect() end)
                return connection
            end
            table.insert(self.connections, connection)
            return connection
        end

        function scope:watch(instance, method, handler)
            if not self.active then return false end
            local previous = namecallWatch[instance] and namecallWatch[instance][method]
            if not namecallGuard.watch(instance, method, handler) then return false end
            table.insert(self.watches, {
                instance = instance,
                method = method,
                handler = handler,
                previous = previous
            })
            return true
        end

        function scope:patchFunction(target, key, replacement)
            if not self.active or type(target) ~= 'table' or type(replacement) ~= 'function' then
                return false
            end
            local hadOwnValue = rawget(target, key) ~= nil
            local original = target[key]
            if type(original) ~= 'function' then return false end
            local ok = pcall(function()
                target[key] = replacement
            end)
            if not ok then return false end
            table.insert(self.patches, {
                target = target,
                key = key,
                original = original,
                hadOwnValue = hadOwnValue,
                replacement = replacement
            })
            return true
        end

        function scope:remember(instance, property)
            if not self.active or not instance then return false end
            local record = self.properties[instance]
            if not record then
                record = {values = {}, seen = {}}
                self.properties[instance] = record
            end
            if record.seen[property] then return true end
            local ok, value = pcall(function()
                return instance[property]
            end)
            if not ok then return false end
            record.seen[property] = true
            record.values[property] = value
            return true
        end

        function scope:set(instance, property, value)
            if self.restoreProperties and not self:remember(instance, property) then return false end
            return pcall(function()
                instance[property] = value
            end)
        end

        function scope:onStop(callback)
            if type(callback) == 'function' then
                table.insert(self.finalizers, callback)
            end
        end

        function scope:stop()
            if not self.active then return end
            self.active = false

            for i = #self.connections, 1, -1 do
                pcall(function() self.connections[i]:Disconnect() end)
            end

            for i = #self.watches, 1, -1 do
                local watch = self.watches[i]
                local entry = namecallWatch[watch.instance]
                if entry and entry[watch.method] == watch.handler then
                    if watch.previous ~= nil then
                        entry[watch.method] = watch.previous
                    else
                        namecallGuard.unwatch(watch.instance, watch.method)
                    end
                end
            end

            for i = #self.patches, 1, -1 do
                local patch = self.patches[i]
                pcall(function()
                    if patch.target[patch.key] == patch.replacement then
                        patch.target[patch.key] = patch.hadOwnValue and patch.original or nil
                    end
                end)
            end

            for instance, record in next, self.properties do
                for property, value in next, record.values do
                    pcall(function()
                        instance[property] = value
                    end)
                end
                table.clear(record.values)
                table.clear(record.seen)
            end

            for i = #self.finalizers, 1, -1 do
                pcall(self.finalizers[i])
            end

            table.clear(self.connections)
            table.clear(self.watches)
            table.clear(self.patches)
            table.clear(self.properties)
            table.clear(self.finalizers)
            removeScope(self)
        end

        table.insert(scopes, scope)
        return scope
    end

    local function destroyChildren(container, active)
        if not container then return 0 end
        local removed = 0
        local clock = os.clock()
        for _, child in next, (container:GetChildren()) do
            if active and not active() then break end
            pcall(function()
                child:Destroy()
                removed += 1
            end)
            if os.clock() - clock > 0.004 then
                task.wait()
                clock = os.clock()
            end
        end
        return removed
    end

    function fpsHooks.newScope()
        return newScope()
    end

    function fpsHooks.disableClientApply(scope, client)
        if not scope or not scope:isActive() or type(client) ~= 'table' then
            return false
        end
        return scope:patchFunction(client, 'apply', function() end)
    end

    local cleanAssetScope
    local cleanAssetResult

    function fpsHooks.cleanAssets(options)
        options = options or {}
        if cleanAssetScope and cleanAssetScope:isActive() then
            return cleanAssetResult
        end

        local scope = newScope()
        local result = {
            lobbyBoards = 0,
            clientApply = false,
            packetProfiler = false,
            lockerPreview = 0
        }

        if options.clearLobbyBoards then
            local lobby = workspace:FindFirstChild('Lobby')
            local boards = lobby and lobby:FindFirstChild('Boards')
            result.lobbyBoards = destroyChildren(boards, function() return scope:isActive() end)
        end

        if options.disableClientApply then
            result.clientApply = fpsHooks.disableClientApply(scope, options.client)
        end

        if options.removePacketProfiler then
            local playerScripts = lplr and lplr:FindFirstChild('PlayerScripts')
            local profiler = playerScripts and playerScripts:FindFirstChild('packetprofiler')
            local canRemove = true
            local rankOk, rank = pcall(function()
                return lplr:GetRankInGroup(5774246)
            end)
            if not rankOk or rank >= 121 then
                canRemove = false
            end
            if profiler and canRemove then
                pcall(function() profiler:Destroy() end)
                result.packetProfiler = true
            end
        end

        if options.removeLockerPreview then
            local preview = workspace:FindFirstChild('LockerPreview')
            for _, child in next, (workspace:GetChildren()) do
                if child:IsA('Model') and child.Name:find('_LockerPreviewClone$')
                    and (not preview or not child:IsDescendantOf(preview)) then
                    pcall(function()
                        child:Destroy()
                        result.lockerPreview += 1
                    end)
                end
            end
        end

        cleanAssetScope = scope
        cleanAssetResult = result
        return result
    end

    function fpsHooks.startNativeCore(options)
        options = options or {}
        local scope = newScope()
        scope.restoreProperties = options.restoreProperties ~= false
        local renderFidelitySeen = setmetatable({}, {__mode = 'k'})
        local renderFidelityOriginal = setmetatable({}, {__mode = 'k'})

        local function applyRenderFidelity(instance)
            if not options.renderFidelity then return end
            local isMesh = false
            pcall(function()
                isMesh = instance:IsA('MeshPart')
            end)
            if not isMesh then return end
            if not renderFidelitySeen[instance] then
                renderFidelitySeen[instance] = true
                local ok, original = pcall(function() return instance.RenderFidelity end)
                if not ok then return end
                renderFidelityOriginal[instance] = original
            end
            pcall(function()
                instance.RenderFidelity = Enum.RenderFidelity.Performance
            end)
        end

        scope:onStop(function()
            for instance, original in next, renderFidelityOriginal do
                pcall(function() instance.RenderFidelity = original end)
                renderFidelityOriginal[instance] = nil
            end
            table.clear(renderFidelitySeen)
        end)
        local map = workspace:FindFirstChild('Map')
        local camera = workspace.CurrentCamera or gameCamera
        local canEnable = {
            ParticleEmitter = true,
            Smoke = true,
            Fire = true,
            Sparkles = true,
            PostEffect = true,
            SpotLight = true
        }

        local function shouldProcess(instance)
            if not scope:isActive() then return false end
            if camera and instance:IsDescendantOf(camera) then
                local viewmodel = camera:FindFirstChild('Viewmodel')
                if not (viewmodel and instance:IsDescendantOf(viewmodel)) then
                    return false
                end
            end
            local character = lplr.Character
            if not options.cleanSelf and character and instance:IsDescendantOf(character) then
                return false
            end
            if not options.cleanModels and not instance:FindFirstAncestorWhichIsA('Model') then
                return false
            end
            return true
        end

        local function process(instance)
            if not shouldProcess(instance) then return end
            local blockCheck = options.simpleBlocks or not map or not instance:IsDescendantOf(map)

            if instance:IsA('FaceInstance') and blockCheck then
                scope:set(instance, 'Transparency', 1)
                pcall(function() scope:set(instance, 'Shiny', 0) end)
            end

            if options.noImages and (instance:IsA('ImageLabel') or instance:IsA('ImageButton')) then
                scope:set(instance, 'Image', 'rbxassetid://0')
            end

            if options.noAccessories and instance:IsA('Clothing') then
                scope:set(instance, 'Parent', nil)
            end

            if instance:IsA('Explosion') then
                scope:set(instance, 'BlastPressure', 1)
                scope:set(instance, 'BlastRadius', 1)
                scope:set(instance, 'Visible', false)
            end

            if instance:IsA('BasePart') then
                if blockCheck then
                    scope:set(instance, 'Material', Enum.Material.SmoothPlastic)
                end
                scope:set(instance, 'Reflectance', 0)
                if options.beta then
                    scope:set(instance, 'CastShadow', false)
                end
            end

            applyRenderFidelity(instance)

            if instance:IsA('MeshPart') or instance:IsA('Union') then
                scope:set(instance, 'DoubleSided', false)
            end

            if instance:IsA('ParticleEmitter') then
                scope:set(instance, 'Enabled', false)
                scope:set(instance, 'Lifetime', NumberRange.new(0))
            elseif canEnable[instance.ClassName] then
                scope:set(instance, 'Enabled', false)
            end
        end

        task.spawn(function()
            local clock = os.clock()
            for _, instance in next, (workspace:GetDescendants()) do
                if not scope:isActive() then return end
                pcall(process, instance)
                if os.clock() - clock > 0.004 then
                    task.wait()
                    clock = os.clock()
                end
            end

            if options.simpleBlocks and scope:isActive() then
                for _, block in next, (collectionService:GetTagged('block')) do
                    for _, child in next, (block:GetChildren()) do
                        if child:IsA('Texture') then
                            scope:set(child, 'Texture', 'rbxassetid://0')
                            scope:set(child, 'Transparency', 1)
                        end
                    end
                end
            end

            if options.connectWorkspace and scope:isActive() then
                scope:connect(workspace.DescendantAdded:Connect(function(instance)
                    if scope:isActive() then
                        task.defer(function()
                            pcall(process, instance)
                        end)
                    end
                end))
            end

            local terrain = workspace:FindFirstChildWhichIsA('Terrain')
            if terrain and scope:isActive() then
                scope:set(terrain, 'WaterWaveSize', 0)
                scope:set(terrain, 'WaterWaveSpeed', 0)
                scope:set(terrain, 'WaterReflectance', 0)
                scope:set(terrain, 'WaterTransparency', 0)
            end

            if options.simpleLighting and scope:isActive() then
                scope:set(lightingService, 'GlobalShadows', false)
                scope:set(lightingService, 'FogEnd', 9e9)
            end

            if options.beta and scope:isActive() then
                local settingsObject
                pcall(function()
                    if typeof(settings) == 'Instance' then
                        settingsObject = settings
                    elseif type(settings) == 'function' then
                        settingsObject = settings()
                    end
                end)
                if settingsObject then
                    local physics
                    local rendering
                    pcall(function() physics = settingsObject.Physics end)
                    pcall(function() rendering = settingsObject.Rendering end)
                    if physics then
                        scope:set(physics, 'AllowSleep', true)
                        pcall(function()
                            scope:set(physics, 'PhysicsEnvironmentalThrottle', Enum.EnviromentalPhysicsThrottle.Skip2)
                        end)
                    end
                    if rendering then
                        scope:set(rendering, 'EagerBulkExecution', false)
                        pcall(function()
                            scope:set(rendering, 'QualityLevel', Enum.QualityLevel.Level01)
                            scope:set(rendering, 'EditQualityLevel', Enum.QualityLevel.Level01)
                            scope:set(rendering, 'ViewMode', Enum.ViewMode.None)
                            scope:set(rendering, 'EnableFRM', true)
                            scope:set(rendering, 'AutoFRMLevel', 1)
                            scope:set(rendering, 'ShowBoundingBoxes', false)
                            scope:set(rendering, 'RenderCSGTrianglesDebug', false)
                            scope:set(rendering, 'ReloadAssets', false)
                        end)
                    end
                end
            end

        end)

        return scope
    end

    function fpsHooks.startConnectionCleaner(disabledNames)
        local scope = newScope()
        local disabled = {}
        local blocked = {}
        for _, name in next, (disabledNames or {}) do
            blocked[name:gsub('-', '_')] = true
        end

        scope:onStop(function()
            for _, connection in next, disabled do
                pcall(function() connection:Enable() end)
            end
            table.clear(disabled)
        end)

        task.spawn(function()
            if type(getconnections) ~= 'function' then return end
            for _, eventName in {'Heartbeat', 'Stepped', 'RenderStepped'} do
                if not scope:isActive() then return end
                local event = runService[eventName]
                local ok, connections = pcall(getconnections, event)
                if ok and connections then
                    local checked = 0
                    for _, connection in next, connections do
                        if not scope:isActive() then return end
                        local fn = connection.Function
                        if type(fn) == 'function' then
                            local source
                            pcall(function() source = debug.getinfo(fn).source end)
                            if type(source) == 'string' then
                                source = source:gsub('-', '_')
                                for name in next, blocked do
                                    if source:find(name) then
                                        pcall(function() connection:Disable() end)
                                        table.insert(disabled, connection)
                                        break
                                    end
                                end
                            end
                        end
                        checked += 1
                        if checked % 50 == 0 then task.wait() end
                    end
                end
            end
        end)

        return scope
    end

    function fpsHooks.startBlockDemesh(blockController, whitelist)
        local scope = newScope()
        whitelist = whitelist or {}
        scope:onStop(function()
            pcall(function() blockController:remesh() end)
        end)
        task.spawn(function()
            local clock = os.clock()
            for _, block in next, (collectionService:GetTagged('block')) do
                if not scope:isActive() then return end
                pcall(function()
                    if block:GetAttribute('PlacedByUserId') == 0 and not whitelist[block.Name] then
                        block:ClearAllChildren()
                        block.Material = Enum.Material.SmoothPlastic
                        block.Transparency = 0
                        block.BrickColor = BrickColor.new(2)
                        block.Color = Color3.new(0.3, 0.3, 0.3)
                    end
                end)
                if os.clock() - clock > 0.004 then
                    task.wait()
                    clock = os.clock()
                end
            end
            pcall(function() blockController:remesh() end)
        end)
        return scope
    end

    function fpsHooks.startVisualModuleBlocker(options)
        options = options or {}
        local scope = newScope()

        local function noopCleanup()
            return {
                DoCleaning = function() end,
                Destroy = function() end,
                Disconnect = function() end,
                GiveTask = function(self) return self end
            }
        end

        local function setIgnored(instance, includeQuery)
            if typeof(instance) ~= 'Instance' or not instance:IsA('BasePart') then return end
            local queryUtil = options.queryUtil
            if type(queryUtil) == 'table' and type(queryUtil.setQueryIgnored) == 'function' then
                pcall(queryUtil.setQueryIgnored, queryUtil, instance, true)
            end
            pcall(function() instance.CanCollide = false end)
            if includeQuery then
                pcall(function() instance.CanQuery = false end)
            end
        end

        local function setEnabled(instance, value)
            if typeof(instance) ~= 'Instance' then return end
            if not (instance:IsA('ParticleEmitter')
                or instance:IsA('Beam')
                or instance:IsA('Trail')
                or instance:IsA('Light')) then
                return
            end
            scope:set(instance, 'Enabled', value)
        end

        local function protectedRoot(instance, entity)
            if typeof(instance) ~= 'Instance' then return true end
            if typeof(entity) == 'Instance' then
                local character = lplr and lplr.Character
                if character and (entity == character or entity:IsDescendantOf(character)) then
                    return true
                end
            end

            local map = workspace:FindFirstChild('Map')
            local camera = workspace.CurrentCamera or gameCamera
            local playerGui = lplr and lplr:FindFirstChildOfClass('PlayerGui')
            if (map and instance:IsDescendantOf(map))
                or (camera and instance:IsDescendantOf(camera))
                or (playerGui and instance:IsDescendantOf(playerGui))
                or (coreGui and instance:IsDescendantOf(coreGui))
                or instance:IsDescendantOf(replicatedStorage) then
                return true
            end

            local current = instance
            while current do
                if current:IsA('BasePart') and current.CanCollide then
                    return true
                end
                if current:IsA('Model') and current:FindFirstChildOfClass('Humanoid') then
                    return true
                end
                if current:IsA('ScreenGui') then
                    return true
                end
                local name = string.lower(current.Name)
                if name:find('projectile', 1, true)
                    or name:find('shield', 1, true)
                    or name:find('ability', 1, true)
                    or name:find('win_effect', 1, true)
                    or name:find('win-effect', 1, true)
                    or name:find('wineffect', 1, true) then
                    return true
                end
                current = current.Parent
            end

            local ok, descendants = pcall(function()
                return instance:GetDescendants()
            end)
            if ok and descendants then
                for _, descendant in next, descendants do
                    if descendant:IsA('BasePart') and descendant.CanCollide then
                        return true
                    end
                end
            end
            return false
        end

        local function suppress(instance, includeQuery, processParts)
            if typeof(instance) ~= 'Instance' then return end
            local function process(candidate)
                if not scope:isActive() then return end
                if candidate:IsA('BasePart') then
                    if processParts ~= false then
                        setIgnored(candidate, includeQuery)
                    end
                else
                    setEnabled(candidate, false)
                end
            end
            pcall(process, instance)
            local ok, descendants = pcall(function() return instance:GetDescendants() end)
            if ok and descendants then
                for _, descendant in next, descendants do
                    if not scope:isActive() then return end
                    pcall(process, descendant)
                end
            end
        end

        local function blockEffect(original, self, instance, entity, config)
            if protectedRoot(instance, entity) then
                return original(self, instance, entity, config)
            end
            suppress(instance, false)
        end

        local function blockInstanceEffect(original, self, instance, config)
            if protectedRoot(instance) then
                return original(self, instance, config)
            end
            suppress(instance, true)
        end

        local effectUtil = options.effectUtil
        if type(effectUtil) == 'table' then
            local originalPlayEffect = effectUtil.playEffect
            if type(originalPlayEffect) == 'function' then
                scope:patchFunction(effectUtil, 'playEffect', function(self, instance, entity, config)
                    return blockEffect(originalPlayEffect, self, instance, entity, config)
                end)
            end
            local originalPlayInstanceEffect = effectUtil.playInstanceEffect
            if type(originalPlayInstanceEffect) == 'function' then
                scope:patchFunction(effectUtil, 'playInstanceEffect', function(self, instance, config)
                    return blockInstanceEffect(originalPlayInstanceEffect, self, instance, config)
                end)
            end
            local originalEnableInstanceEffect = effectUtil.enableInstanceEffect
            if type(originalEnableInstanceEffect) == 'function' then
                scope:patchFunction(effectUtil, 'enableInstanceEffect', function(self, instance)
                    if protectedRoot(instance) then
                        return originalEnableInstanceEffect(self, instance)
                    end
                    suppress(instance, false, false)
                    return noopCleanup()
                end)
            end
        end

        return scope
    end

    slinky:clean(function()
        for i = #scopes, 1, -1 do
            scopes[i]:stop()
        end
        table.clear(scopes)
        cleanAssetScope = nil
        cleanAssetResult = nil
    end)
end

local RunLoops = {RenderStepTable = {}, StepTable = {}, HeartTable = {}}
local slinkyConnections = {}

--[[ Nothing used to disconnect either table on uninject. A run loop left bound kept running
into the next injection, and bedwars.lua's slinkyConnections (lplr attribute and death handlers)
gained another live copy every reinject. ]]
slinky:clean(function()
    for _, loops in {RunLoops.RenderStepTable, RunLoops.StepTable, RunLoops.HeartTable} do
        for name, connection in loops do
            pcall(function() connection:Disconnect() end)
            loops[name] = nil
        end
    end
    for index, connection in slinkyConnections do
        pcall(function() connection:Disconnect() end)
        slinkyConnections[index] = nil
    end
end)

function RunLoops:BindToRenderStep(name, func)
    if RunLoops.RenderStepTable[name] == nil then
        RunLoops.RenderStepTable[name] = runService.RenderStepped:Connect(func)
    end
end

function RunLoops:UnbindFromRenderStep(name)
    if RunLoops.RenderStepTable[name] then
        RunLoops.RenderStepTable[name]:Disconnect()
        RunLoops.RenderStepTable[name] = nil
    end
end

function RunLoops:BindToStepped(name, func)
    if RunLoops.StepTable[name] == nil then
        RunLoops.StepTable[name] = runService.Stepped:Connect(func)
    end
end

function RunLoops:UnbindFromStepped(name)
    if RunLoops.StepTable[name] then
        RunLoops.StepTable[name]:Disconnect()
        RunLoops.StepTable[name] = nil
    end
end

function RunLoops:BindToHeartbeat(name, func)
    if RunLoops.HeartTable[name] == nil then
        RunLoops.HeartTable[name] = runService.Heartbeat:Connect(func)
    end
end

function RunLoops:UnbindFromHeartbeat(name)
    if RunLoops.HeartTable[name] then
        RunLoops.HeartTable[name]:Disconnect()
        RunLoops.HeartTable[name] = nil
    end
end

--[[ Whether an instance name contains any switched-on entry of a TextList (list.active, list.items or a
bare array of strings), ignoring case and surrounding spaces. A plain-text find, because item names
carry '-' and '(', which read as pattern syntax. ]]
local function entryMatches(objName, list)
    if type(objName) ~= "string" or type(list) ~= "table" then return false end
    local entries = list.active or list.items or list
    if type(entries) ~= "table" then return false end
    local lowerName = objName:lower()
    for _, entry in pairs(entries) do
        if type(entry) == "string" then
            local nameString = entry:lower():gsub("^%s*(.-)%s*$", "%1")
            if nameString ~= "" and lowerName:find(nameString, 1, true) then
                return true
            end
        end
    end
    return false
end

--[[ The `out` barrel re-exports sound-manager, but each of its re-exports is guarded by
`or {}`, so a build where that submodule fails to resolve silently drops the key and
leaves SoundManager nil -- which is how "attempt to index nil with 'playSound'" reached
both SoundChanger and the projectile launch sound. Handing back a stand-in instead of nil
is what fixes that: a dozen call sites across both files index this directly and none of
them are worth taking down over a missing sound effect.

The current game has no SoundManager at all -- everything plays through AudioManager
(playAudio(asset, config)) -- and while the stand-in was a stub of no-ops, every sound
the script played itself was silent: its own projectile launches, pickups, purchases,
the miner's hammer. So playSound now forwards to AudioManager:playAudio. The props the
call sites pass (position, volumeMultiplier) are AudioManager config keys already, and a
registered GameSound brings its own category and volume. It is pcall'd so a bad id still
costs nothing but the sound.

routesToAudioManager tells SoundChanger these already reach its AudioManager hook, so it
leaves playSound alone rather than scaling them twice. Every other method is still a
no-op, and without an AudioManager this is the plain stub. ]]
-- require is the caller's: the bootstrap's own, which is knitless.require when Knit is out of reach.
local function resolveSoundManager(require)
    local ok, res = pcall(function()
        return require(replicatedStorage['rbxts_include']['node_modules']['@easy-games']['game-core'].out).SoundManager
    end)
    if ok and res then return res end

    local stub = setmetatable({}, {__index = function() return blankFunction end})
    local audioOk, audio = pcall(function()
        return require(replicatedStorage['rbxts_include']['node_modules']['@easy-games']['game-core'].out).AudioManager
    end)
    if not (audioOk and type(audio) == 'table' and type(audio.playAudio) == 'function') then
        return stub
    end

    stub.routesToAudioManager = true
    function stub:playSound(id, props)
        if type(id) ~= 'string' or id == '' then return nil end
        local config = {}
        if type(props) == 'table' then
            for key, value in props do
                config[key] = value
            end
        end
        local played, handle = pcall(audio.playAudio, audio, id, config)
        return played and handle or nil
    end
    return stub
end

--[[ pistonware funcs ]]

do
--[[ Knit out of reach (Solara, Xeno). The bootstrap below then runs as it is, on stand-ins built
from the game's own instances: Knit is knitless.Knit, whose Controllers are the stand-in
controllers, and require inside the bootstrap is knitless.require, which hands back the stand-in
export registered for a module's path. The sections build them from remotes found by name,
attributes, CollectionService tags and games/bedwars-data.json; nothing in them requires a game
module or needs the debug library or a hook. One local, scoped to this block, so the main chunk
stays clear of Luau's 200-local limit. ]]
local knitless = {empty = {}}

--[[ Registry slice of the knitless layer: the export table each module the bootstrap requires would
hand back, for every module the store, blocks and controllers slices do not own. Data comes from the
dump (ctx.data), behaviour from instances, attributes, tags and the remotes clients. Nothing here
requires a game module. Where the game keeps client-only state this layer cannot see, the function
says what it does instead. ]]

--[[ The instance under root at a dotted path of child names, or nil. ]]
function knitless.registryFind(root, path)
	local node = root
	for name in string.gmatch(path, '[^%.]+') do
		node = node and node:FindFirstChild(name)
	end
	return node
end

--[[ A deep copy, as object-utils' deepCopy: tables copied, everything else shared. ]]
function knitless.registryCopy(value)
	if type(value) ~= 'table' then return value end
	local copy = {}
	for key, item in value do
		copy[key] = knitless.registryCopy(item)
	end
	return copy
end

--[[ roblox-ts enums answer both ways, name to value and value to name. The dump keeps the forward
half; the reverse half goes behind __index, so iterating an enum still sees the names only. ]]
function knitless.registryEnum(forward)
	if type(forward) ~= 'table' or getmetatable(forward) ~= nil then return forward end
	local reverse = {}
	for key, value in forward do
		if type(value) == 'string' or type(value) == 'number' then
			reverse[value] = key
		end
	end
	return setmetatable(forward, {__index = reverse})
end

--[[ ConstantManager.registerConstants keeps each constant as a ConstantManager_<key> attribute on its
module and copies any change of it into the live table. This reads the same attributes into a table
of our own and follows them; it never writes them, since the game would copy that into its own. ]]
function knitless.registryConstants(ctx, module, defaults)
	local constants = table.clone(type(defaults) == 'table' and defaults or {})
	if typeof(module) ~= 'Instance' then return constants end
	for key in constants do
		local attribute = 'ConstantManager_'..key
		local function read()
			local value = module:GetAttribute(attribute)
			if value ~= nil then constants[key] = value end
		end
		read()
		ctx.clean(module:GetAttributeChangedSignal(attribute):Connect(read))
	end
	return constants
end

--[[ Rebuilds item-meta's projectileSource.projectileType(ammo), a function the dump leaves out. With
projectileTypeByAmmo in the dump ({[''] = default, [ammo] = projectile}) it is exact. Without it the
name is guessed from the item and ammo names, taking only a name ProjectileMeta has: wood_crossbow +
firework_arrow is crossbow_firework_arrow, golden_bow + arrow is golden_arrow, an iron arrow is
<that arrow>_iron. A guess can miss (glitch_wood_bow shoots glitch_arrow, this says arrow).
multiProjectileSource entries answer their own key. ]]
function knitless.registryProjectileTypes(items, projectiles)
	if type(items) ~= 'table' or type(projectiles) ~= 'table' then return end
	local function guess(itemType, ammo, source)
		local stem = string.gsub(itemType, '_bow$', '')
		local family = string.match(itemType, '(%a+)$') or itemType
		if ammo == nil then
			if projectiles[itemType] then return itemType end
			local ammoTypes = source.ammoItemTypes
			if type(ammoTypes) == 'table' then
				ammo = table.find(ammoTypes, 'arrow') and 'arrow' or (#ammoTypes == 1 and ammoTypes[1]) or nil
			end
			if type(ammo) ~= 'string' then
				for _, name in {itemType..'_projectile', itemType..'_arrow', stem..'_arrow'} do
					if projectiles[name] then return name end
				end
				return nil
			end
		end
		if ammo == 'iron_arrow' then
			local base = guess(itemType, 'arrow', source)
			if base and base ~= 'arrow' and projectiles[base..'_iron'] then return base..'_iron' end
		end
		for _, name in {itemType..'_'..ammo, stem..'_'..ammo, family..'_'..ammo, ammo} do
			if projectiles[name] then return name end
		end
		return nil
	end

	for itemType, meta in items do
		if type(meta) ~= 'table' then continue end
		local source = meta.projectileSource
		if type(source) == 'table' and source.projectileType == nil then
			local byAmmo = type(source.projectileTypeByAmmo) == 'table' and source.projectileTypeByAmmo or nil
			local guessed = {}
			source.projectileType = function(ammo)
				if byAmmo then
					local name = ammo ~= nil and byAmmo[ammo] or nil
					if name == nil then name = byAmmo[''] end
					return name
				end
				local key = ammo == nil and '' or tostring(ammo)
				if guessed[key] == nil then
					guessed[key] = guess(itemType, ammo, source) or false
				end
				return guessed[key] or nil
			end
		end
		if type(meta.multiProjectileSource) == 'table' then
			for projectile, entry in meta.multiProjectileSource do
				if type(entry) == 'table' and entry.projectileType == nil then
					entry.projectileType = function()
						return projectile
					end
				end
			end
		end
	end
end

--[[ A Zap client event: On(listener) returns the function that disconnects it, as lib.network's do,
and listeners run on threads of their own, as Zap runs them. fire is ours, for whatever feeds the
event: the block tags and the Zap decoder below. Until something feeds it, it never fires. ]]
function knitless.registryZapEvent()
	local listeners = {}
	local event = {}
	function event.On(listener)
		table.insert(listeners, listener)
		return function()
			local index = table.find(listeners, listener)
			if index then table.remove(listeners, index) end
		end
	end
	function event.fire(...)
		for _, listener in table.clone(listeners) do
			task.spawn(listener, ...)
		end
	end
	return event
end

--[[ PlayerScripts.TS.lib.network with every client event it has. Placed and broken blocks also show
as the 'block' tag coming and going, so PlaceBlockEventZap and BreakBlockEventZap are fed from it in
Zap's argument order, the block's cell then its type. Who broke a block, and the hit data a break
carries, are not known here and stay nil. Blocks the map streams in fire a place as well. The
other events come from knitless.registryZapDecoder. ]]
function knitless.registryZap(ctx)
	local zap = {}
	for _, name in {
		'EntityDamageEventZap', 'PickupItemEventZap', 'ProjectileLaunchZap', 'ProjectileImpactZap',
		'UpdateMapDataZap', 'PlaceBlockEventZap', 'BreakBlockEventZap', 'EntityHealEventZap',
		'AddMatchEventCountdownZap', 'KitsUpdateEventZap', 'EntityDeathEventZap'
	} do
		zap[name] = knitless.registryZapEvent()
	end

	local collectionService = ctx.services.CollectionService
	local function cell(part)
		local position = part.Position / 3
		return Vector3.new(math.round(position.X) + 0, math.round(position.Y) + 0, math.round(position.Z) + 0)
	end
	ctx.clean(collectionService:GetInstanceAddedSignal('block'):Connect(function(block)
		if block:IsA('BasePart') then
			zap.PlaceBlockEventZap.fire(cell(block), block.Name)
		end
	end))
	ctx.clean(collectionService:GetInstanceRemovedSignal('block'):Connect(function(block)
		if block:IsA('BasePart') then
			zap.BreakBlockEventZap.fire(cell(block), block.Name)
		end
	end))
	local ok, err = pcall(knitless.registryZapDecoder, ctx, zap)
	if not ok then
		ctx.log('zap decoder: '..tostring(err))
	end
	return zap
end

--[[ Feeds the events above from ReplicatedStorage.ZAP.ZAP_RELIABLE, read the way lib.network's own
decoder reads it; nothing is ever sent. A packet is a buffer and an array of instances: events back
to back, each a u8 id and then its fields, the instances taken from the array in order. Every
layout is walked, since each event starts where the one before it ends, and each event fires with
the arguments lib.network passes, except place and break, which the block tags above feed. A packet
is read whole, in a pcall, before any of it fires. An instance that did not replicate drops the
rest of its packet, as it does in the game. A read past the end, an unknown id or any other error
means the layout has changed: decoding stops for the match with one log line. zap.decoding is true
while it runs, and zap.packets counts what it has read. ]]
function knitless.registryZapDecoder(ctx, zap)
	zap.decoding, zap.packets = false, 0
	local PAST_END, MISSING = {}, {}
	local data, size, at, instances, taken = nil, 0, 0, nil, 0

	local function skip(count)
		if at + count > size then error(PAST_END, 0) end
		local start = at
		at += count
		return start
	end
	local function u8() return buffer.readu8(data, skip(1)) end
	local function u16() return buffer.readu16(data, skip(2)) end
	local function f32() return buffer.readf32(data, skip(4)) end
	local function f64() return buffer.readf64(data, skip(8)) end
	local function bool() return u8() == 1 end
	local function text(length) return buffer.readstring(data, skip(length), length) end
	local function text16() return text(u16()) end
	local function text8() return text(8) end
	-- Read in order, one statement each: every read moves the cursor.
	local function vector32()
		local x = f32()
		local y = f32()
		return Vector3.new(x, y, f32())
	end
	local function vector16()
		local x = u16()
		local y = u16()
		return Vector3.new(x, y, u16())
	end
	local function vector8()
		local x = u8()
		local y = u8()
		return Vector3.new(x, y, u8())
	end
	local function rgb()
		local r = u8()
		local g = u8()
		return Color3.fromRGB(r, g, u8())
	end
	--[[ An optional field: a u8 1 and then the value; anything else is nil. ]]
	local function maybe(read)
		if u8() ~= 1 then return nil end
		return read()
	end
	--[[ The next instance in the array, which the game asserts is there and of its class. ]]
	local function instance(class)
		taken += 1
		local value = instances[taken]
		if value == nil or not value:IsA(class) then error(MISSING, 0) end
		return value
	end
	--[[ An optional one: nil when flagged absent, or flagged but not replicated. ]]
	local function maybeInstance(class)
		if u8() ~= 1 then return nil end
		taken += 1
		local value = instances[taken]
		if value ~= nil and class and not value:IsA(class) then error(MISSING, 0) end
		return value
	end

	local function list16()
		local list = {}
		for index = 1, u16() do
			list[index] = u16()
		end
		return list
	end
	local function regions()
		local list = {}
		for index = 1, u16() do
			local region = {}
			region.center = vector16()
			local x = u8()
			region.radius = Vector3.new(x, u8(), 0)
			region.box = bool()
			region.whiteListTeamId = maybe(text16)
			list[index] = region
		end
		return list
	end
	local function knockback()
		local value = {}
		value.horizontal = maybe(f64)
		value.vertical = maybe(f64)
		value.disabled = maybe(bool)
		return value
	end
	local function projectileData()
		local value = {}
		value.projectileType = u16()
		value.projectileModel = instance('Model')
		return value
	end
	local ATTACK = {
		{'itemUsed', text16}, {'swingTimeRatio', f32}, {'projectileData', projectileData}, {'guidedProjectile', u8},
		{'paintBlast', bool}, {'pyroBrittleAttack', bool}, {'chargeRatio', f32}, {'isVoidAttack', bool},
		{'isDoubleHit', bool}, {'halloweenEventFog', bool}, {'halloweenLaser', bool}, {'seahorseAttack', bool},
		{'headshot', bool}, {'damageOverTime', bool}, {'ignorePurgatoryDisable', bool}, {'spiderKill', bool}
	}
	local function attackData()
		local value = {}
		for _, field in ATTACK do
			value[field[1]] = maybe(field[2])
		end
		return value
	end
	local function launchOptions()
		local value = {}
		value.drawDurationSec = maybe(f32)
		value.shotId = maybe(text8)
		return value
	end
	local function hitOptions()
		local value = {}
		value.detectHitTerrain = maybe(bool)
		return value
	end
	local function countdownOptions()
		local value = {}
		value.shouldDisplay = bool()
		value.permanentDisplay = maybe(bool)
		return value
	end
	--[[ Where a death happened: a position, then an axis whose length is the angle turned about it. ]]
	local function cframe()
		local position = vector32()
		local axis = vector32()
		local angle = axis.Magnitude
		if angle == 0 then return CFrame.new(position) end
		return CFrame.fromAxisAngle(axis, angle) + position
	end
	--[[ What a death paid out: per id (an f64), resources by name, each an amount and maybe visualOnly. ]]
	local function payout()
		local value = {}
		for _ = 1, u16() do
			local id = f64()
			local items = {}
			for _ = 1, u16() do
				local name = text16()
				local item = {}
				item.amount = f64()
				item.visualOnly = maybe(bool)
				items[name] = item
			end
			value[id] = items
		end
		return value
	end

	--[[ The Zap events by id, in lib.network's order. Each read returns the arguments as table.pack
	does; an entry without a name is read past and not fired. Deaths arrive as EntityDeathEventZap
	(id 10), one table with entityInstance, fromEntity, finalKill, respawnDuration and the rest, as
	lib.network passes it on. Id 11 is the reply to a FetchMapDataFuncZap call, which this layer
	never makes. ]]
	local EVENTS = {
		[0] = {name = 'EntityDamageEventZap', read = function()
			local entity = instance('Model')
			local damage = f64()
			local damageType = u8()
			local fromPosition = maybe(vector32)
			local fromEntity = maybeInstance('Model')
			local multiplier = maybe(knockback)
			local knockbackId = maybe(u16)
			local attack = maybe(attackData)
			local flag9 = maybe(bool)
			local sound = maybe(u16)
			local sounds = maybe(list16)
			local flag12 = maybe(bool)
			local flag13 = maybe(bool)
			return table.pack(entity, damage, damageType, fromPosition, fromEntity, multiplier, knockbackId,
				attack, flag9, sound, sounds, flag12, flag13, maybe(u8))
		end},
		[1] = {name = 'PickupItemEventZap', read = function()
			local item = u16()
			return table.pack(item, vector32())
		end},
		[2] = {name = 'ProjectileLaunchZap', read = function()
			local source = maybeInstance(nil)
			local origin = vector32()
			local projectile = instance('Model')
			local shot = text8()
			local accessory = maybeInstance('Accessory')
			local part = maybeInstance('BasePart')
			local shooter = maybeInstance('Model')
			local options = maybe(launchOptions)
			local flag9 = maybe(bool)
			local flag10 = maybe(bool)
			return table.pack(source, origin, projectile, shot, accessory, part, shooter, options, flag9, flag10,
				maybe(hitOptions))
		end},
		[3] = {name = 'ProjectileImpactZap', read = function()
			local position = vector32()
			local kind = u8()
			local projectile = instance('Model')
			local accessory = maybeInstance('Accessory')
			local part = maybeInstance('BasePart')
			local player = maybeInstance('Player')
			local model = maybeInstance('Model')
			return table.pack(position, kind, projectile, accessory, part, player, model, maybe(bool))
		end},
		[4] = {name = 'UpdateMapDataZap', read = function()
			local list = regions()
			return table.pack(list, bool())
		end},
		[5] = {read = function()
			vector16()
			text16()
		end},
		[6] = {read = function()
			vector16()
			text16()
			vector32()
			maybe(vector8)
			maybeInstance('Player')
		end},
		[7] = {name = 'EntityHealEventZap', read = function()
			local entity = instance('Model')
			local amount = f64()
			local source = maybe(text16)
			return table.pack(entity, amount, source, maybe(bool))
		end},
		[8] = {name = 'AddMatchEventCountdownZap', read = function()
			local first = text16()
			local second = text16()
			local third = text16()
			local number = f64()
			local options = countdownOptions()
			local color = maybe(rgb)
			local color2 = maybe(rgb)
			return table.pack(first, second, third, number, options, color, color2, maybe(f32))
		end},
		[9] = {name = 'KitsUpdateEventZap', read = function()
			local number = f64()
			return table.pack(number, text16())
		end},
		[10] = {name = 'EntityDeathEventZap', read = function()
			local death = {}
			death.teamIdBefore = maybe(text16)
			death.entityInstance = maybeInstance('Model')
			death.itemUsed = maybe(text16)
			death.damageType = u8()
			death.fromEntity = maybeInstance('Model')
			death.cframe = cframe()
			death.respawnDuration = f64()
			death.multiKillCount = maybe(u16)
			death.deathPayout = maybe(payout)
			death.finalKill = maybe(bool)
			death.noKillSound = maybe(bool)
			death.customUI = maybe(bool)
			return table.pack(death)
		end},
		[11] = {read = function()
			u8()
			regions()
		end}
	}

	local fired
	local function walk()
		while at < size do
			local id = u8()
			local event = EVENTS[id]
			if not event then error('unknown event id '..id, 0) end
			local args = event.read()
			if event.name then
				table.insert(fired, {event.name, args})
			end
		end
	end

	local connection, stopped, dropped, seenOnYou
	local function stop(why)
		stopped = true
		zap.decoding = false
		if connection then connection:Disconnect() end
		ctx.log('Zap decoder stopped ('..why..'): damage, launch and the other Zap events stay silent')
	end
	local function onPacket(packet, list)
		if stopped or type(packet) ~= 'buffer' then return end
		data, size, at, taken = packet, buffer.len(packet), 0, 0
		instances = type(list) == 'table' and list or {}
		fired = {}
		local ok, err = pcall(walk)
		local events = fired
		data, instances, fired = nil, nil, nil
		zap.packets += 1
		if not ok then
			if err ~= MISSING then
				stop(err == PAST_END and 'a read past the end of a packet' or tostring(err))
				return
			end
			if not dropped then
				dropped = true
				ctx.log('Zap decoder: a packet named an instance that had not replicated; the rest of it is dropped, as the game drops it')
			end
		end
		if not seenOnYou and shared.PistonwareDeveloper == true then
			local character = ctx.lplr.Character
			for _, event in events do
				if event[1] == 'EntityDamageEventZap' and character and event[2][1] == character then
					seenOnYou = true
					ctx.log('Zap decoder: first damage event on you, in packet '..zap.packets)
					break
				end
			end
		end
		for _, event in events do
			zap[event[1]].fire(table.unpack(event[2], 1, event[2].n))
		end
	end

	task.spawn(function()
		local services = ctx.services
		local folder = services.ReplicatedStorage:FindFirstChild('ZAP') or services.ReplicatedStorage:WaitForChild('ZAP', 30)
		local remote = folder and (folder:FindFirstChild('ZAP_RELIABLE') or folder:WaitForChild('ZAP_RELIABLE', 30))
		if not (remote and remote:IsA('RemoteEvent')) then
			stop('no ReplicatedStorage.ZAP.ZAP_RELIABLE')
			return
		end
		connection = remote.OnClientEvent:Connect(onPacket)
		ctx.clean(connection)
		zap.decoding = true
		if shared.PistonwareDeveloper == true then
			ctx.log('Zap decoder on: reading ReplicatedStorage.ZAP.ZAP_RELIABLE')
		end
	end)
end

--[[ A client sync event shaped like @easy-games/sync-event's SyncEvent: connect(callback, priority)
returns a connection (Destroy, as the game's EventConnection, plus Disconnect and disconnect),
setPriority(priority) a builder that connects and fires at that priority, and fire builds an event
from its arguments, runs every handler on it in priority order and returns it. fireEvent takes an
event already built. The game's own handlers sit on the game's events, never on these, so these
carry only what pistonware itself fires. ]]
function knitless.registrySyncEvent(log)
	local entries = {}
	local event = {}
	function event:connect(callback, priority)
		local entry = {callback = callback, priority = tonumber(priority) or 200}
		local index = #entries + 1
		for i, other in entries do
			if other.priority > entry.priority then
				index = i
				break
			end
		end
		table.insert(entries, index, entry)
		local function disconnect()
			local at = table.find(entries, entry)
			if at then table.remove(entries, at) end
		end
		return {Destroy = disconnect, Disconnect = disconnect, disconnect = disconnect}
	end
	function event:fireEvent(fired)
		for _, entry in table.clone(entries) do
			local ok, err = pcall(entry.callback, fired)
			if not ok and log then log('sync event handler failed: '..tostring(err)) end
		end
		return fired
	end
	function event:fire(...)
		local fired = table.pack(...)
		function fired:setCancelled(cancelled)
			self.cancelled = cancelled ~= false
		end
		function fired:isCancelled()
			return self.cancelled == true
		end
		return self:fireEvent(fired)
	end
	function event:setPriority(priority)
		local source = self
		local builder = {}
		function builder:setPriority(newPriority)
			priority = newPriority
			return self
		end
		function builder:connect(callback)
			return source:connect(callback, priority)
		end
		function builder:fire(...)
			return source:fire(...)
		end
		return builder
	end
	return event
end

--[[ game-core's AnimationUtil and the game's GameAnimationUtil over it. playAnimation(target, assetId,
options) is game-core's own without its game-local BeforeAnimationPlayEvent: it finds the Animator
of a Player's character, of a Model or the Animator itself, plays the track with looped, speed,
fadeInTime, restorePreviousTracks and fadeSamePriorityTracks, and removes the track when it stops.
GameAnimationUtil maps an AnimationType (its number or its name) to an asset id through the dump's
Animations table; without it only the few animations the scripts play by type are known, with ids
from prod-animations. ]]
function knitless.registryAnimation(ctx)
	local AnimationUtil = {}
	function AnimationUtil.playAnimation(_, target, assetId, options)
		options = type(options) == 'table' and options or {}
		if typeof(target) ~= 'Instance' or type(assetId) ~= 'string' or assetId == '' then return nil end
		local animator
		if target:IsA('Player') then
			local humanoid = target.Character and target.Character:FindFirstChild('Humanoid')
			animator = humanoid and humanoid:FindFirstChild('Animator')
		elseif target:IsA('Animator') then
			animator = target
		elseif target:IsA('Model') then
			local humanoid = target:FindFirstChildWhichIsA('Humanoid')
			animator = humanoid and humanoid:FindFirstChild('Animator')
			if not animator then
				local controller = target:FindFirstChildWhichIsA('AnimationController')
				animator = controller and controller:FindFirstChild('Animator')
			end
		end
		if not (animator and animator:IsDescendantOf(game)) then return nil end

		local animation = Instance.new('Animation')
		animation.AnimationId = assetId
		local track = animator:LoadAnimation(animation)
		if options.looped ~= nil then track.Looped = options.looped end
		local priority = track.Priority
		local restore = options.restorePreviousTracks
		if restore == nil then restore = not track.Looped end
		if options.fadeSamePriorityTracks ~= false then
			for _, other in animator:GetPlayingAnimationTracks() do
				if other.Priority == priority then
					if not restore then
						other:Stop(0.1)
					elseif other:GetAttribute('OriginalWeight') == nil then
						other:SetAttribute('OriginalWeight', other.WeightTarget)
						other:AdjustWeight(0.0001, 0.1)
					end
				end
			end
		end
		track:Play(options.fadeInTime, nil, options.speed)

		local stopped
		stopped = track.Stopped:Connect(function()
			stopped:Disconnect()
			local ownWeight = track:GetAttribute('OriginalWeight')
			track:Destroy()
			if not (animator.Parent and restore) or ownWeight ~= nil then return end
			local last
			for _, other in animator:GetPlayingAnimationTracks() do
				if other.Priority == priority and other ~= track then last = other end
			end
			local weight = last and last:GetAttribute('OriginalWeight')
			if weight ~= nil then
				last:SetAttribute('OriginalWeight', nil)
				last:AdjustWeight(weight, 0.1)
			end
		end)
		return track
	end

	local types = knitless.registryEnum(ctx.data('AnimationType'))
	local assets = ctx.data('Animations')
	if type(assets) ~= 'table' then
		ctx.log('registry: no Animations in the data file; GameAnimationUtil knows only the animations the scripts play')
		assets = {}
	end
	local known = {
		PUNCH = 'rbxassetid://4866397461',
		SWORD_SWING = 'rbxassetid://4947108314',
		FP_USE_ITEM = 'rbxassetid://8089691925',
		FP_SWING_SWORD = 'rbxassetid://8089691925',
		FP_WALK = 'rbxassetid://8091867276',
		BUILDER_HAMMER_HIT = 'rbxassetid://6955840280',
		WIZARD_BALL_CAST = 'rbxassetid://7265176148',
		NET_CATCH = 'rbxassetid://7377150622',
		JADE_HAMMER_SLAM = 'rbxassetid://79601612304177',
		MINER_MINE_STONE = 'rbxassetid://8934264605',
		SHOVEL_DIG = 'rbxassetid://9378575104',
		TINKER_ATTACK = 'rbxassetid://16992948586'
	}

	local GameAnimationUtil = {}
	function GameAnimationUtil.getAssetId(_, animationType)
		local name = animationType
		if type(animationType) == 'number' then
			if assets[animationType] then return assets[animationType] end
			name = type(types) == 'table' and types[animationType] or nil
		end
		if type(name) ~= 'string' then return nil end
		return assets[name] or known[name]
	end
	function GameAnimationUtil.getAnimation(_, animationType)
		local animation = Instance.new('Animation')
		animation.AnimationId = GameAnimationUtil:getAssetId(animationType) or ''
		return animation
	end
	function GameAnimationUtil.playAnimation(_, target, animationType, options)
		return AnimationUtil:playAnimation(target, GameAnimationUtil:getAssetId(animationType), options)
	end

	return AnimationUtil, GameAnimationUtil, types
end

--[[ game-core's AudioManager, playing plain Sounds. The game's buses, pooled AudioPlayers and per-sound
registered volumes are its own, so a Sound at its default volume stands in. The config keys are the
game's: position (a hidden part there), parent, looped, volumeMultiplier, playbackSpeedMultiplier
and the roll-off distances. playAudio goes through internalPlayAudio as the game's does, so a hook
there sees these sounds too. A sound it made is removed when it ends, or 10 s on when it never
loaded. ]]
function knitless.registryAudio(ctx)
	local workspace = ctx.services.Workspace
	local soundService = ctx.services.SoundService or game:GetService('SoundService')
	local AudioManager = {audioAssetConfigs = {}}

	function AudioManager:internalPlayAudio(asset, config)
		config = type(config) == 'table' and config or {}
		local sound, owned
		if typeof(asset) == 'Instance' then
			if not asset:IsA('Sound') then return nil end
			sound = asset
		elseif type(asset) == 'string' and asset ~= '' then
			sound, owned = Instance.new('Sound'), true
			sound.SoundId = asset
			if type(config.volumeMultiplier) == 'number' then sound.Volume *= config.volumeMultiplier end
			if type(config.playbackSpeedMultiplier) == 'number' then sound.PlaybackSpeed *= config.playbackSpeedMultiplier end
			sound.RollOffMaxDistance = tonumber(config.rollOffMaxDistance) or 60
			sound.RollOffMinDistance = tonumber(config.rollOffMinDistance) or 10
		else
			return nil
		end
		if config.looped == true then sound.Looped = true end

		local parent, spatial = typeof(config.parent) == 'Instance' and config.parent or nil, nil
		if not parent and typeof(config.position) == 'Vector3' then
			spatial = Instance.new('Part')
			spatial.Size = Vector3.one
			spatial.Anchored = true
			spatial.CanCollide = false
			spatial.CanQuery = false
			spatial.CanTouch = false
			spatial.Transparency = 1
			spatial.CFrame = CFrame.new(config.position)
			spatial:SetAttribute('gamecore_GameQueryIgnore', true)
			spatial.Parent = workspace
			parent = spatial
		end
		sound.Parent = parent or soundService
		sound:Play()

		local entry = {player = sound, released = false}
		function entry.release()
			if entry.released then return end
			entry.released = true
			if spatial then
				spatial:Destroy()
			elseif owned then
				sound:Destroy()
			end
		end
		if owned or spatial then
			if not sound.Looped then sound.Ended:Once(entry.release) end
			task.delay(10, function()
				if not sound.IsLoaded then entry.release() end
			end)
		end
		return entry
	end

	function AudioManager:playAudio(asset, config)
		local entry = self:internalPlayAudio(asset, config or {})
		if type(entry) ~= 'table' then return nil end
		local playback = {}
		function playback:getAudioPlayer()
			return entry.player
		end
		function playback:setProperty(name, value)
			pcall(function()
				entry.player[name] = value
			end)
		end
		function playback:Stop()
			pcall(function()
				entry.player:Stop()
			end)
			if entry.release then entry.release() end
		end
		playback.Destroy = playback.Stop
		return playback
	end

	function AudioManager:playRandomAudio(list, config)
		if type(list) ~= 'table' or #list == 0 then return nil end
		return self:playAudio(list[math.random(#list)], config)
	end

	function AudioManager:playAudioPlayer(asset, config)
		local entry = self:internalPlayAudio(asset, config or {})
		return type(entry) == 'table' and entry.player or nil
	end

	return AudioManager
end

--[[ game-core's GameQueryUtil. The ignore mark is the gamecore_GameQueryIgnore attribute, the one the
game's own targeting reads. raycast is the game's: a hit on a marked part (or one options.ignorePart
turns down) is taken out of the params and the cast is made again, so the params passed in are
changed as the game changes them. ]]
function knitless.registryQueryUtil(ctx)
	local workspace = ctx.services.Workspace
	local ATTRIBUTE = 'gamecore_GameQueryIgnore'
	local QueryUtil = {ADJUST_CAN_QUERY = false}

	function QueryUtil.isQueryIgnored(_, part)
		if typeof(part) ~= 'Instance' or not part:IsA('BasePart') then return false end
		return part:GetAttribute(ATTRIBUTE) == true
	end

	function QueryUtil.setQueryIgnored(_, part, ignored)
		if ignored == nil then ignored = true end
		if typeof(part) ~= 'Instance' or not part:IsA('BasePart') then return nil end
		part:SetAttribute(ATTRIBUTE, ignored and true or nil)
	end

	function QueryUtil.raycast(self, origin, direction, params, options)
		params = params or RaycastParams.new()
		local world = type(options) == 'table' and options.world or workspace
		local ignorePart = type(options) == 'table' and options.ignorePart or nil
		local included
		while true do
			local result = world:Raycast(origin, direction, params)
			if not result then return nil end
			local hit = result.Instance
			if not (self:isQueryIgnored(hit) or (ignorePart and ignorePart(hit))) then return result end
			if params.FilterType ~= Enum.RaycastFilterType.Include then
				params:AddToFilter(hit)
			else
				included = included or table.clone(params.FilterDescendantsInstances)
				local found
				for index, root in included do
					if hit == root or hit:IsDescendantOf(root) then
						found = index
						break
					end
				end
				if not found then return nil end
				table.remove(included, found)
				params.FilterDescendantsInstances = included
			end
		end
	end

	return QueryUtil
end

--[[ game-core's AppController, read off PlayerGui: an app the game opens is mounted there as a
ScreenGui named by its app id, and closing it removes that. isLayerOpen asks whether any app the
game opens on that layer is up, from the dump's AppLayers ({layer = {appId, ...}}) or else the MAIN
apps the game registers (ui/apps and the game-core settings app). closeApp disables the ScreenGui
rather than destroying it: the game's own Roact tree still owns it and unmounts it later. openApp
needs the game's components and is not offered. ]]
function knitless.registryAppController(ctx)
	local layers = ctx.data('AppLayers')
	if type(layers) ~= 'table' then
		layers = {MAIN = {
			'InventoryApp', 'TeamUpgradeApp', 'BedwarsItemShopApp', 'KitShopApp', 'WeaponSelectionApp',
			'KitDetailsApp', 'LockerApp', 'MissionsApp', 'BattlePassApp', 'CustomMatchesApp', 'FlamethrowerApp',
			'FrostyHammerApp', 'GiftingApp', 'GiftedApp', 'SocialConnectionsApp', 'GameUpdatesApp', 'ChestApp',
			'EnchantTable', 'QueueSelection', 'CustomMatchHostPanel', 'ClanCreateForm', 'ClanProfile', 'EventApp',
			'FriendsList', 'MilestonesApp', 'ScriptEditor', 'NewsApp', 'LoreApp', 'KitContractApp',
			'CreativeGadgetMenu', 'WorldGuardMenu', 'AfkApp', 'TrainingRoomCommandsListApp', 'CommandMenuApp',
			'TrainingRoomKitSelectionApp', 'LassoWarsUpgradeShopApp', 'LassoWarsTutorialApp', 'ArmorTrimApp',
			'StoreMenuApp', 'LobbyPlayMenuApp', 'AllRandomKitDraftApp', 'ClanHQSelectorApp',
			'ClanLobbySelectorApp', 'PurchaseOptionsScreenApp', 'SettingsApp', 'CreativeInventory',
			'PlayerProfile', 'CardSelection'
		}}
	end

	local function playerGui()
		return ctx.lplr:FindFirstChildOfClass('PlayerGui')
	end
	local function appId(app)
		if type(app) == 'table' then return app.appId end
		return app
	end
	local function openGui(id)
		local gui = type(id) == 'string' and playerGui()
		gui = gui and gui:FindFirstChild(id)
		if gui and (not gui:IsA('LayerCollector') or gui.Enabled) then return gui end
		return nil
	end

	local AppController = {}
	function AppController.isAppOpen(_, app)
		return openGui(appId(app)) ~= nil
	end
	function AppController.getOpenApps(_)
		local open = {}
		local gui = playerGui()
		for _, child in gui and gui:GetChildren() or {} do
			if child:IsA('ScreenGui') and child.Enabled then
				table.insert(open, child.Name)
			end
		end
		return open
	end
	function AppController.closeApp(_, app)
		local gui = openGui(appId(app))
		if not gui then return end
		if gui:IsA('LayerCollector') then
			gui.Enabled = false
		else
			gui:Destroy()
		end
	end
	AppController.closeAppById = AppController.closeApp
	function AppController.isLayerOpen(_, layer)
		for _, id in layers[layer] or {} do
			if openGui(id) then return true end
		end
		return false
	end
	function AppController.closeLayer(self, layer)
		for _, id in layers[layer] or {} do
			self:closeApp(id)
		end
	end
	return AppController
end

--[[ The part of Roact the scripts use for UI of their own: createElement, createFragment, createRef,
mount, unmount, and the Children, Ref, Event, Change and None keys. Elements are the plain
{component, props} tables Roact makes, with children in props[Roact.Children]. mount builds host
elements (class names) and function components into Instances; stateful components, bindings and
updates are not offered, and the game's own trees are never reached. ]]
function knitless.registryRoact()
	local Roact = {}
	local function symbol(name)
		return setmetatable({}, {__tostring = function()
			return 'Symbol('..name..')'
		end})
	end
	local function keys(kind)
		return setmetatable({}, {__index = function(self, name)
			local key = {kind = kind, name = name}
			rawset(self, name, key)
			return key
		end})
	end
	local fragment = symbol('Fragment')
	Roact.Children = symbol('Children')
	Roact.Ref = symbol('Ref')
	Roact.None = symbol('None')
	Roact.Event = keys('Event')
	Roact.Change = keys('Change')

	function Roact.createElement(component, props, children)
		local copy = {}
		for key, value in props or {} do
			copy[key] = value
		end
		if children ~= nil then copy[Roact.Children] = children end
		return {component = component, props = copy}
	end
	function Roact.createFragment(elements)
		return {component = fragment, elements = elements}
	end
	function Roact.createRef()
		local ref = {}
		function ref:getValue()
			return self.current
		end
		return ref
	end

	local function build(element, parent, name, handle)
		if type(element) ~= 'table' then return nil end
		local component = element.component
		if component == fragment then
			for key, child in element.elements or {} do
				build(child, parent, type(key) == 'string' and key or nil, handle)
			end
			return nil
		end
		if type(component) == 'function' then
			return build(component(element.props), parent, name, handle)
		end
		if type(component) ~= 'string' then return nil end
		local instance = Instance.new(component)
		if name then instance.Name = name end
		for key, value in element.props do
			if key == Roact.Ref then
				value.current = instance
			elseif type(key) == 'table' and key.kind == 'Event' then
				table.insert(handle.connections, instance[key.name]:Connect(function(...)
					value(instance, ...)
				end))
			elseif type(key) == 'table' and key.kind == 'Change' then
				table.insert(handle.connections, instance:GetPropertyChangedSignal(key.name):Connect(function()
					value(instance)
				end))
			elseif type(key) == 'string' and value ~= Roact.None then
				instance[key] = value
			end
		end
		for key, child in element.props[Roact.Children] or {} do
			build(child, instance, type(key) == 'string' and key or nil, handle)
		end
		instance.Parent = parent
		return instance
	end

	function Roact.mount(element, parent, key)
		local handle = {connections = {}}
		handle.instance = build(element, parent, key or 'RoactTree', handle)
		return handle
	end
	function Roact.unmount(handle)
		if type(handle) ~= 'table' then return end
		for _, connection in handle.connections or {} do
			connection:Disconnect()
		end
		table.clear(handle.connections or {})
		if handle.instance then
			handle.instance:Destroy()
			handle.instance = nil
		end
	end
	return Roact
end

--[[ The game's WeldUtil for accessories: each Accessory's Handle attachment is welded to the
character attachment of the same name, a Weld named AccessoryAttachment on the character's part
(a RigidConstraint for a bone), held items preferring their grip attachments, as the game does. An
accessory whose handle is already joined to something outside it (the game welded it) is left alone,
so nothing is welded twice. ]]
function knitless.registryWeldUtil()
	local WeldUtil = {}

	local function findAttachment(root, name)
		for _, child in root:GetChildren() do
			if child:IsA('Accoutrement') or child:IsA('Tool') then continue end
			if (child:IsA('Attachment') or child:IsA('Bone')) and child.Name == name
				and not (string.sub(name, -17) == 'KneeRigAttachment' and string.find(child.Parent.Name, 'Upper', 1, true)) then
				return child
			end
			local found = findAttachment(child, name)
			if found then return found end
		end
		return nil
	end

	local function joinedOutside(handle, accessory)
		for _, joint in handle:GetJoints() do
			local first, second
			if joint:IsA('JointInstance') or joint:IsA('WeldConstraint') then
				first, second = joint.Part0, joint.Part1
			elseif joint:IsA('Constraint') then
				first = joint.Attachment0 and joint.Attachment0.Parent
				second = joint.Attachment1 and joint.Attachment1.Parent
			end
			for _, part in {first, second} do
				if typeof(part) == 'Instance' and not part:IsDescendantOf(accessory) then return true end
			end
		end
		return false
	end

	function WeldUtil.weldParts(_, part0, part1)
		local weld = Instance.new('WeldConstraint')
		weld.Name = part1.Name
		weld.Part0 = part0
		weld.Part1 = part1
		weld.Parent = part0
		return weld
	end

	function WeldUtil.weldAttachments(_, characterAttachment, accessoryAttachment)
		local weld = Instance.new('Weld')
		weld.Name = 'AccessoryAttachment'
		weld.Part0 = characterAttachment.Parent
		weld.Part1 = accessoryAttachment.Parent
		weld.C0 = characterAttachment.CFrame
		weld.C1 = accessoryAttachment.CFrame
		weld.Parent = characterAttachment.Parent
		return weld
	end

	function WeldUtil.rigidWeldAttachments(_, attachment0, attachment1)
		local constraint = Instance.new('RigidConstraint')
		constraint.Name = 'AccessoryRigidConstraint'
		constraint.Attachment0 = attachment0
		constraint.Attachment1 = attachment1
		constraint.Parent = attachment0.Parent
		return constraint
	end

	function WeldUtil.weldAccessory(self, character, accessory)
		if accessory.Parent ~= character then accessory.Parent = character end
		local handle = accessory:FindFirstChild('Handle')
		if handle and handle:IsA('BasePart') and not joinedOutside(handle, accessory) then
			local candidates = handle:GetChildren()
			if accessory:GetAttribute('InvItem') == true and accessory:GetAttribute('ArmorSlot') == nil
				and accessory:GetAttribute('IsBackpack') == nil then
				local grips = {}
				for _, child in candidates do
					if child:IsA('Attachment') and (child.Name == 'RightGripAttachment'
						or child.Name == 'LeftGripAttachment' or child.Name == 'BodyFrontAttachment') then
						table.insert(grips, child)
					end
				end
				if #grips > 0 then candidates = grips end
			end
			for _, attachment in candidates do
				if attachment:IsA('Attachment') then
					local target = findAttachment(character, attachment.Name)
					if target then
						if target:IsA('Bone') then
							self:rigidWeldAttachments(attachment, target)
						else
							self:weldAttachments(target, attachment)
						end
						break
					end
				end
			end
		end
		for _, part in accessory:GetDescendants() do
			if part:IsA('BasePart') then part.CanCollide = false end
		end
	end

	function WeldUtil.weldCharacterAccessories(self, character, container)
		for _, child in (container or character):GetChildren() do
			if child:IsA('Accessory') then
				self:weldAccessory(character, child)
			end
		end
	end

	function WeldUtil.weldModel(_, model)
		local primary = model.PrimaryPart
		if not primary then return nil end
		for _, part in primary:GetDescendants() do
			if part:IsA('BasePart') then
				local weld = Instance.new('WeldConstraint')
				weld.Name = 'WeldUtil_WeldModel'
				weld.Part0 = part
				weld.Part1 = primary
				weld.Parent = part
			end
		end
	end

	return WeldUtil
end

--[[ bedwars-shop's BedwarsShop over the dumped ShopItems. getShopItem(itemType, player, {shopId}) is
the game's: the item's entry (the last one listed wins, as in the game), a deep copy, and with a
player the adjusted price. getAdjustedShopPrice is the game's rule: priceMultiplier, the player's
DisruptionPriceIncrease (none in the 20v20 and 16v16 queues), the iron shop tax and the queue's
shopPriceModifiers. Not here: each shop's own item list (a shop component), the kit and game mode
overrides the dump drops, and the tax, which comes from a ShopTaxController stand-in when one is
there and is 0 otherwise. getTeamWool is getTeamWoolById, the name the scripts call it by. ]]
function knitless.registryShop(ctx)
	local items = ctx.data('ShopItems')
	if type(items) ~= 'table' then
		ctx.log('registry: no ShopItems in the data file; the shop is unavailable')
		return nil
	end
	local byType = {}
	for _, item in items do
		if type(item) == 'table' and item.itemType ~= nil then
			byType[item.itemType] = item
		end
	end
	local workspace = ctx.services.Workspace
	local queueMeta = ctx.sharedData('QueueMeta')
	local noDisruption = {bedwars_20v20_lb = true, bedwars_16v16 = true, bedwars_20v20 = true}

	local Shop = {ShopItems = items}

	function Shop.getAdjustedShopPrice(item, player)
		if item.disabled then return item.price end
		local price = item.price
		if item.priceMultiplier ~= nil then
			price = math.clamp(math.round(item.price * item.priceMultiplier), 1, item.price)
		end
		local queueType = workspace:GetAttribute('QueueType')
		local disruption = 0
		if typeof(player) == 'Instance' and not noDisruption[queueType] then
			disruption = math.ceil(item.price * (player:GetAttribute('DisruptionPriceIncrease') or 0))
		end
		local tax = 0
		local taxController = ctx.controllers and ctx.controllers.ShopTaxController
		if item.currency == 'iron' and type(taxController) == 'table' and type(taxController.getAddedTax) == 'function' then
			local ok, added = pcall(taxController.getAddedTax, taxController, item.itemType)
			tax = ok and tonumber(added) or 0
		end
		local total = price + disruption + tax
		local modifiers = queueType ~= nil and type(queueMeta) == 'table' and type(queueMeta[queueType]) == 'table'
			and queueMeta[queueType].shopPriceModifiers or nil
		if type(modifiers) == 'table' then
			local multiplier = item.currency == 'iron' and modifiers.ironMultiplier
				or item.currency == 'diamond' and modifiers.diamondMultiplier
				or item.currency == 'emerald' and modifiers.emeraldMultiplier
				or nil
			if multiplier ~= nil then total *= multiplier end
			local rounding = modifiers.roundingMethod
			total = rounding == 'up' and math.ceil(total) or rounding == 'down' and math.floor(total) or math.round(total)
			if modifiers.canGoToZero then return math.max(total, 0) end
			if total < 1 then total = 1 end
		end
		return total
	end

	function Shop.getShopItemBase(itemType)
		return knitless.registryCopy(byType[itemType])
	end

	function Shop.getShopItem(itemType, player)
		local item = Shop.getShopItemBase(itemType)
		if item and typeof(player) == 'Instance' then
			local price = Shop.getAdjustedShopPrice(item, player)
			if price ~= item.price then item.price = price end
		end
		return item
	end

	function Shop.doesItemRequireKit(itemType, kit)
		local item = byType[itemType]
		return type(item) == 'table' and type(item.requiresKit) == 'table' and table.find(item.requiresKit, kit) ~= nil
	end

	local wools = {'wool_blue', 'wool_orange', 'wool_pink', 'wool_yellow', 'wool_brown', 'wool_white', 'wool_cyan', 'wool_purple'}
	function Shop.getTeamWoolById(teamId)
		return wools[tonumber(teamId) or 0] or 'wool_white'
	end
	Shop.getTeamWool = Shop.getTeamWoolById

	return Shop
end

--[[ team-upgrade-meta over the dumped TeamUpgradeMeta ({tables, byQueue, default}). The game picks
the table by the match's queue type; this takes the queue type passed, else the Workspace's
QueueType attribute. Without the data it answers an empty table, so the bootstrap still starts and
AutoBuy simply offers no upgrades. ]]
function knitless.registryTeamUpgrades(ctx)
	local meta = ctx.data('TeamUpgradeMeta')
	if type(meta) ~= 'table' or type(meta.tables) ~= 'table' then
		ctx.log('registry: no TeamUpgradeMeta in the data file; there are no team upgrades')
		meta = nil
	end
	local function forQueue(queueType)
		if not meta then return {} end
		queueType = queueType or ctx.services.Workspace:GetAttribute('QueueType')
		local index = type(meta.byQueue) == 'table' and queueType ~= nil and meta.byQueue[queueType] or meta.default
		return meta.tables[index] or meta.tables[meta.default] or meta.tables[1] or {}
	end
	return {
		getTeamUpgradeMetaForQueue = forQueue,
		getTeamUpgradeDefinition = function(upgrade)
			return forQueue()[upgrade]
		end
	}
end

--[[ Fills ctx.modules with the export table of every module the bootstrap requires that the store,
blocks and controllers slices do not own. Each part is built on its own, so one that fails costs
only its own modules, and the data names missing from the dump are logged together at the end.

Plain tables come straight from the dump; a missing one stands in empty, except ItemMeta, which is
left nil so the bootstrap's own check reports it. JadeBalance, ConquerorBalance and
FlamethrowerUpgradeMeta are read by bedwars.lua at module load (LongJump/JadeAura, AutoConqueror,
AutoPyro). shared-constants is not in the dump and is written here; the blocks slice reads the place
rate from it. A frosty hammer upgrade's tier is an attribute of that name on what is passed (the
scripts pass the player), and Taliyah's chicken price is the Workspace's ChickenPrice and
ChickenCurrency attributes. The remotes go through the layer's own net clients, and RuntimeLib's
await returns a promise's value or throws its rejection. The game's UI and effect internals are
plain tables: the scripts only patch fields on them or walk them, and nothing put there reaches the
game. ]]
function knitless.buildRegistry(ctx)
	local modules = ctx.modules
	local RS = 'ReplicatedStorage.TS.'
	local NODE = 'ReplicatedStorage.rbxts_include.node_modules.'
	local CORE = NODE..'@easy-games.game-core.out'
	local missing, noted = {}, {}

	local function note(name)
		if noted[name] then return end
		noted[name] = true
		table.insert(missing, name)
	end
	local function data(name)
		local ok, value = pcall(ctx.data, name)
		if ok and value ~= nil then return value end
		note(name)
		return nil
	end
	local function part(name, build)
		local ok, err = pcall(build)
		if not ok then ctx.log('registry: '..name..' failed: '..tostring(err)) end
	end

	part('data', function()
		for _, entry in {
			{'games.bedwars.items.frosty-hammer.frosty-hammer-upgrades', 'FrostyHammerUpgradeMeta', 'AdetundeUpgradeMeta'},
			{'locker.bed-break-effect.bed-break-effect-meta', 'BedBreakEffectMeta', 'BedBreakEffectMeta'},
			{'games.bedwars.kit.bedwars-kit-meta', 'BedwarsKitMeta', 'BedwarsKitMeta'},
			{'balance.black-marketeer-balance', 'BlackMarketeerBalance', 'BlackMarketeerBalance'},
			{'balance.juggernaut-balance-file', 'JuggernautUtil', 'JuggernautUtil'},
			{'locker.emote.emote-type', 'EmoteType', 'EmoteType', true},
			{'enchant.enchant-meta', 'EnchantMeta', 'EnchantMeta'},
			{'games.bedwars.item-skin.item-skin-types', 'ItemSkinType', 'ItemSkinType', true},
			{'games.bedwars.kit-skin.bedwars-kit-skin', 'BedwarsKitSkin', 'BedwarsKitSkin', true},
			{'games.bedwars.kit-skin.bedwars-kit-skin-meta', 'BedwarsKitSkinMeta', 'BedwarsKitSkinMeta'},
			{'locker.kill-effect.kill-effect-meta', 'KillEffectMeta', 'KillEffectMeta'},
			{'balance.balance-file', 'BalanceFile', 'BalanceFile'},
			{'games.bedwars.kit.kits.frosty-gun.frosty-gun-util', 'FrostyGunMode', 'FrostyGunMode', true},
			{'games.bedwars.kit.kits.soul-broker.soul-broker-constants', 'SoulBrokerConstants', 'SoulBrokerConstants'},
			{'projectile.projectile-meta', 'ProjectileMeta', 'ProjectileMeta'},
			{'sound.game-sound', 'GameSound', 'GameSound'},
			{'status-effect.status-effect-type', 'StatusEffectType', 'StatusEffectType', true},
			{'games.bedwars.kit.kits.summoner.summoner-kit-balance', 'SummonerKitBalance', 'SummonerKitBalance'},
			{'locker.win-effect.win-effect-meta', 'WinEffectMeta', 'WinEffectMeta'},
			{'balance.jade-balance', 'JadeBalance', 'JadeBalance'},
			{'balance.conqueror-balance', 'ConquerorBalance', 'ConquerorBalance'},
			{'games.bedwars.kit.kits.pyro.flamethrower-upgrade', 'FlamethrowerUpgradeMeta', 'FlamethrowerUpgradeMeta'}
		} do
			local value = data(entry[3]) or {}
			if entry[4] then value = knitless.registryEnum(value) end
			local exports = modules[RS..entry[1]] or {}
			exports[entry[2]] = value
			modules[RS..entry[1]] = exports
		end
		local kitSkins = modules[RS..'games.bedwars.kit-skin.bedwars-kit-skin'].BedwarsKitSkin
		if type(kitSkins) == 'table' and rawget(kitSkins, 'DEFAULT') == nil then
			rawset(kitSkins, 'DEFAULT', 'default')
		end
	end)

	part('item-meta', function()
		local items = data('ItemMeta')
		knitless.registryProjectileTypes(items, data('ProjectileMeta'))
		modules[RS..'item.item-meta'] = {
			items = items,
			getItemMeta = function(itemType)
				return type(items) == 'table' and items[itemType] or nil
			end
		}
	end)

	part('item-skin-meta', function()
		local skins = data('ItemSkinMeta') or {}
		local byItem
		modules[RS..'games.bedwars.item-skin.item-skin-meta'] = {
			ItemSkinMeta = skins,
			getItemSkinMeta = function(skin)
				return skins[skin]
			end,
			getItemSkins = function(itemType)
				if not byItem then
					byItem = {}
					for skin, meta in skins do
						if type(meta) == 'table' and meta.itemType ~= nil then
							byItem[meta.itemType] = byItem[meta.itemType] or {}
							table.insert(byItem[meta.itemType], skin)
						end
					end
					for _, list in byItem do
						table.sort(list)
					end
				end
				return byItem[itemType] and table.clone(byItem[itemType]) or nil
			end
		}
	end)

	part('combat-constant', function()
		local swords = knitless.registryConstants(ctx,
			knitless.registryFind(ctx.services.ReplicatedStorage, 'TS.combat.combat-constant'),
			data('SwordsConstants') or {swordSwingBufferMultiplier = 0.4})
		modules[RS..'combat.combat-constant'] = {
			CombatConstant = table.clone(data('CombatConstant') or {
				RAYCAST_SWORD_CHARACTER_DISTANCE = 14.4,
				REGION_SWORD_CHARACTER_DISTANCE = 12.6
			}),
			SwordsConstants = swords
		}
	end)

	modules[RS..'shared-constants'] = {
		IS_DEV = false,
		PingConstants = {PING_COOLDOWN = 2, PING_LIFETIME = 6},
		CpsConstants = {BLOCK_PLACE_CPS = 12}
	}

	part('queue-meta', function()
		local queues = ctx.sharedData('QueueMeta')
		if queues == nil then note('QueueMeta') end
		modules[RS..'game.queue-meta'] = {
			QueueMeta = queues,
			getQueueMeta = function(queueType)
				return type(queues) == 'table' and queues[queueType] or nil
			end
		}
	end)

	part('frosty-hammer', function()
		local exports = modules[RS..'games.bedwars.items.frosty-hammer.frosty-hammer-upgrades'] or {}
		local upgrades = {}
		for key in type(exports.FrostyHammerUpgradeMeta) == 'table' and exports.FrostyHammerUpgradeMeta or {} do
			upgrades[string.upper(key)] = key
		end
		exports.FrostyHammerUpgrade = knitless.registryEnum(upgrades)
		modules[RS..'games.bedwars.items.frosty-hammer.frosty-hammer-upgrades'] = exports
		modules[RS..'games.bedwars.items.frosty-hammer.frosty-hammer-util'] = {FrostyHammerUtil = {
			getUpgradesFromHammer = function(hammer)
				local tiers = {}
				for _, upgrade in upgrades do
					tiers[upgrade] = typeof(hammer) == 'Instance' and hammer:GetAttribute(upgrade) or 0
				end
				return tiers
			end
		}}
	end)

	modules[RS..'games.bedwars.kit.kits.taliyah.taliyah-util'] = {TaliyahUtil = {
		CHICKEN_BASE_LIFETIME = 75,
		CHICKEN_BASE_HP = 70,
		DEFAULT_MAX_CHICKEN = 4,
		getPrice = function()
			local workspace = ctx.services.Workspace
			return {
				price = workspace:GetAttribute('ChickenPrice') or 30,
				currency = workspace:GetAttribute('ChickenCurrency') or 'iron'
			}
		end
	}}

	part('team-upgrade-meta', function()
		modules[RS..'games.bedwars.team-upgrade.team-upgrade-meta'] = knitless.registryTeamUpgrades(ctx)
	end)

	part('bedwars-shop', function()
		modules[RS..'games.bedwars.shop.bedwars-shop'] = {BedwarsShop = knitless.registryShop(ctx)}
	end)

	modules[RS..'remotes'] = {default = {Client = ctx.net}}
	modules[NODE..'@rbxts.net.out.client'] = {}
	modules['ReplicatedStorage.rbxts_include.RuntimeLib'] = {
		Promise = ctx.Promise,
		await = function(promise)
			if type(promise) ~= 'table' or type(promise.await) ~= 'function' then return promise end
			local results = table.pack(promise:await())
			if not results[1] then error(results[2], 2) end
			return table.unpack(results, 2, results.n)
		end
	}

	part('animation', function()
		local animationUtil, gameAnimationUtil, types = knitless.registryAnimation(ctx)
		if types == nil then note('AnimationType') end
		modules[CORE..'.shared.util.animation-util'] = {AnimationUtil = animationUtil}
		modules[RS..'animation.animation-type'] = {AnimationType = types}
		modules[RS..'animation.animation-util'] = {
			GameAnimationUtil = gameAnimationUtil,
			getAnimation = function(animationType)
				return gameAnimationUtil:getAnimation(animationType)
			end,
			getAnimationFromAssetId = function(assetId)
				local animation = Instance.new('Animation')
				animation.AnimationId = assetId
				return animation
			end
		}
	end)

	part('game-core', function()
		modules[CORE] = {
			AudioManager = knitless.registryAudio(ctx),
			GameQueryUtil = knitless.registryQueryUtil(ctx),
			UILayers = knitless.registryEnum({MAIN = 'MAIN', OVERLAY = 'OVERLAY', HUD = 'HUD'})
		}
	end)

	part('app-controller', function()
		modules[CORE..'.client.controllers.app-controller'] = {AppController = knitless.registryAppController(ctx)}
	end)

	part('sync-events', function()
		local priority = knitless.registryEnum({HIGHEST = 0, HIGH = 100, NORMAL = 200, LOW = 300, LOWEST = 400, MONITOR = 500})
		modules[NODE..'@easy-games.sync-event.out'] = {
			SyncEventPriority = priority,
			SyncEventPriorityOrdered = {0, 100, 200, 300, 400, 500}
		}
		local events = {}
		for _, name in {'SwordSwing', 'ProjectileLaunched', 'StatusEffectAdded', 'AbilityUsed'} do
			events[name] = knitless.registrySyncEvent(ctx.log)
		end
		modules['PlayerScripts.TS.client-sync-events'] = {ClientSyncEvents = events}
	end)

	part('zap', function()
		modules['PlayerScripts.TS.lib.network'] = knitless.registryZap(ctx)
	end)

	part('roact', function()
		modules[NODE..'@rbxts.roact.src'] = knitless.registryRoact()
	end)

	part('weld-util', function()
		modules[RS..'util.weld-util'] = {WeldUtil = knitless.registryWeldUtil()}
	end)

	modules[RS..'util.effect.effect-util'] = {EffectUtil = {}}
	modules[RS..'games.bedwars.kit.kits.mage.mage-kit-util'] = {MageKitUtil = {}}
	modules[CORE..'.client.ui.lib.util.click-hold'] = {ClickHold = {}}
	modules['PlayerScripts.TS.controllers.global.locker.kill-effect.effects.default-kill-effect'] = {}
	modules['PlayerScripts.TS.controllers.global.top-bar.ui.game.hud-alive-player-counts'] = {HudAlivePlayerCounts = {}}
	modules['PlayerScripts.TS.controllers.global.queue.ui.queue-card'] = {QueueCard = {}}
	modules['PlayerScripts.TS.lib.visualizer.visualizer-utils'] = {VisualizerUtils = {}}
	modules['PlayerScripts.TS.controllers.game.ping.ping-controller'] = {PingController = {}}

	if #missing > 0 then
		ctx.log('registry: not in the data file: '..table.concat(missing, ', '))
	end
end

--[[ Store slice: bedwars.Store and InventoryUtil without Knit.

The store keeps Rodux's contract. getState() returns the current state, which is never edited in
place: a change gives new tables along its path (state, slice, sub-table) and every other reference
stays as it was. changed listeners run once on the next Heartbeat with (new, previous), and only
when something changed, never inside dispatch. The slices are rebuilt from what every client can
see: the character's inventory ObjectValues and accessories, player and Workspace attributes, and
the remotes the game's own controllers listen to. ]]

--[[ One inventory accessory, as the game's store and InventoryUtil describe it. ]]
function knitless.storeItem(tool)
	return {
		tool = tool,
		itemType = tool.Name,
		amount = tool:GetAttribute('Amount'),
		addedToBackpackTime = tool:GetAttribute('AddedToBackpackTime'),
		itemSkin = tool:GetAttribute('ItemSkin')
	}
end

--[[ InventoryUtil.getInventory as the game has it (inventory-util), for a Player or a character:
the InventoryFolder's accessories, the backpack and the hand. armor starts as three 'empty' entries
and the worn pieces are appended after them, so a helmet is armor[4]. That is the game's own shape,
and NameTags reads it that way. ]]
function knitless.storeGetInventory(player)
	local inventory = {items = {}, armor = {'empty', 'empty', 'empty'}}
	if typeof(player) ~= 'Instance' then return inventory end
	local character = if player:IsA('Player') then player.Character else player
	if not character then return inventory end
	local function linked(name)
		local link = character:FindFirstChild(name)
		return link and link:IsA('ObjectValue') and link.Value or nil
	end
	local folder = linked('InventoryFolder')
	if folder then
		for _, tool in folder:GetChildren() do
			table.insert(inventory.items, knitless.storeItem(tool))
		end
	end
	for slot = 0, 2 do
		local worn = linked('ArmorInvItem_'..slot)
		if worn then
			table.insert(inventory.armor, knitless.storeItem(worn))
		end
	end
	local backpack = linked('BedWarsBackpackSlot')
	if backpack then
		inventory.backpack = knitless.storeItem(backpack)
	end
	local hand = linked('HandInvItem')
	if hand then
		inventory.hand = knitless.storeItem(hand)
	end
	return inventory
end

--[[ The InventoryUtil export: getInventory and the three lookups the game builds on it. ]]
function knitless.storeInventoryUtil()
	local InventoryUtil = {}
	function InventoryUtil.getInventory(player)
		return knitless.storeGetInventory(player)
	end
	function InventoryUtil.getToolFromInventory(player, itemType)
		for _, item in knitless.storeGetInventory(player).items do
			if item.itemType == itemType then
				return item
			end
		end
		return nil
	end
	function InventoryUtil.getAmount(player, itemType)
		local total, counted = 0, {}
		for _, item in knitless.storeGetInventory(player).items do
			if not counted[item.tool] then
				counted[item.tool] = true
				if item.itemType == itemType then
					total += item.amount or 0
				end
			end
		end
		return total
	end
	function InventoryUtil.hasEnough(player, itemType, amount)
		if type(amount) ~= 'number' or amount < 0 or amount ~= amount then
			return false
		end
		return amount <= InventoryUtil.getAmount(player, itemType)
	end
	return InventoryUtil
end

--[[ Seconds on a TimerUtil clock ('mm:ss', the minutes not capped at two digits), or nil. ]]
function knitless.storeTimerSeconds(text)
	if type(text) ~= 'string' then return nil end
	local minutes, seconds = text:match('^(%d+):(%d%d)$')
	if not minutes then return nil end
	return tonumber(minutes) * 60 + tonumber(seconds)
end

--[[ The match state a late injection missed, read off the top bar's match timer (hud-match-timer).
It shows 00:00 until the match runs, then counts up once a second from the start time. Returns 1
and the elapsed seconds when a clock there advanced within 1.5 s, 0 when the clocks sat at 00:00,
and nil when there is no clock to read. Yields. ]]
function knitless.storeReadHudTimer(player)
	local gui = player:FindFirstChildOfClass('PlayerGui')
	local topBar = gui and gui:FindFirstChild('TopBarAppGui')
	if not topBar then return nil end
	local first = {}
	local found = false
	for _, label in topBar:GetDescendants() do
		if label:IsA('TextLabel') then
			local seconds = knitless.storeTimerSeconds(label.Text)
			if seconds then
				first[label] = seconds
				found = true
			end
		end
	end
	if not found then return nil end
	task.wait(1.5)
	local stopped = false
	for label, seconds in first do
		local now = knitless.storeTimerSeconds(label.Text)
		if now and now > seconds then
			return 1, now
		end
		if now == 0 and seconds == 0 then
			stopped = true
		end
	end
	if stopped then return 0 end
	return nil
end

--[[ The game's own hotbar selection, without Knit. The number keys are ContextActionService actions,
priority-keyboard-HotbarSlot1..9, which HotbarController binds through game-core's priority handler.
Each one dispatches InventorySelectHotbarSlot to the game's own ClientStore, and HotbarController
follows that store: select_hotbar when the slot changed, equipItem (HandInvItem and SetInvItem) when
the held tool changed, and the highlight and the first-person item redraw. CallFunction runs that
same bound function, as the key does, with no input sent: nothing reaches pistonware's own
number-key binds or a focused text box, the window need not be in front, and a rebound key changes
nothing, since the action names stay.

  * CallFunction is a RobloxScript member. It is tried once, on the game's own slot-1 action with
    the Cancel state, which selects nothing (knitless.hotbarProbe), from a thread raised to
    identity 8 where the executor can raise it and the thread is below it (knitless.hotbarCall).
    Any error, whatever its words (Solara blocks the call, Xeno lacks the capability), and the
    number keys are tried instead (below); without them the route is off: the stand-in store
    selects the way it always did.
  * The number keys (route.method 'key'), where CallFunction is refused and VirtualInputManager
    answers a call that sends nothing (knitless.hotbarKeyProbe): SendKeyEvent presses the key the
    slot's action is bound to and lets it go a frame later, a player's tap (knitless.hotbarKeyPress).
    It is real input, so no key goes while a text box has focus, Roblox's menu is open, a jade slam
    holds the hammer or the player holds that key (knitless.hotbarKeySafe); the store then sets the
    hand alone. The key is marked in shared.PistonwareSyntheticKeys until just after its release,
    and the menu's binds, the AFK watch and FastDrop pass a marked key by. A key lands a frame
    after it is sent, where CallFunction selects at once, so its check below waits two frames more.
  * The real selection is read off the hotbar tiles (knitless.hotbarRealSlot): in
    PlayerGui.hotbar.1.ItemsHotbar, the tile whose LayoutOrder is the slot and whose button has the
    white border hotbar-tile draws on the selected one.
  * No press while the inventory or a chest is open: there the same action moves the hovered item
    into the slot instead.
  * The InputObject handed over is the last mouse, touch or keyboard one seen, else a gamepad one.
    game-core's wrapper reads only its KeyCode, and passes a gamepad one by while the ability key
    is held.
  * A press whose highlight has not moved after route.verify seconds and at least three frames is
    told to the server the old way after all. Two such misses in a row, with the tiles there to
    read, end the route for the session; a press that errors ends it at once and goes the old way
    itself. The frames count too, so a lagging client whose frame outlasts the check does not count
    a press the game took as a miss.
  * Until that check ends, the store reports the pressed slot (route.want), so a press made before
    the game has drawn the one before it counts from that one. route.hold is only a backstop. ]]
function knitless.hotbarRoute(ctx)
	local route = knitless.hotbarRouteState
	if route then return route end
	route = {status = nil, nextProbe = 0, pollAt = 0, seq = 0, misses = 0, want = nil, wantUntil = 0,
		input = nil, verify = 0.35, hold = 3, method = nil, keyHeld = {}}
	knitless.hotbarRouteState = route
	local kinds = {
		[Enum.UserInputType.MouseMovement] = true, [Enum.UserInputType.MouseButton1] = true,
		[Enum.UserInputType.MouseButton2] = true, [Enum.UserInputType.MouseButton3] = true,
		[Enum.UserInputType.MouseWheel] = true, [Enum.UserInputType.Keyboard] = true,
		[Enum.UserInputType.Touch] = true
	}
	local function keep(input)
		if kinds[input.UserInputType] then
			route.input = input
		end
	end
	local inputService = ctx.services.UserInputService
	ctx.clean(inputService.InputBegan:Connect(keep))
	ctx.clean(inputService.InputChanged:Connect(keep))
	ctx.clean(function()
		route.status = 'off'
		route.input = nil
		route.want = nil
		route.seq += 1
	end)
	return route
end

-- The ItemsHotbar frame of the game's hotbar, or nil.
function knitless.hotbarTiles(ctx)
	local gui = ctx.lplr:FindFirstChildOfClass('PlayerGui')
	local hotbar = gui and gui:FindFirstChild('hotbar')
	hotbar = hotbar and hotbar:FindFirstChild('1')
	return hotbar and hotbar:FindFirstChild('ItemsHotbar')
end

--[[ The slot (0 to 8) the game has selected, from the tile it draws as selected, or nil with no
hotbar to read. ]]
function knitless.hotbarRealSlot(ctx)
	local items = knitless.hotbarTiles(ctx)
	if not items then return nil end
	local white = Color3.new(1, 1, 1)
	for _, tile in items:GetChildren() do
		if tile:IsA('GuiObject') and tile.LayoutOrder >= 0 and tile.LayoutOrder <= 8 then
			local button = tile:FindFirstChildOfClass('ImageButton')
			if button and button.BorderColor3 == white then
				return tile.LayoutOrder
			end
		end
	end
	return nil
end

--[[ What the game has selected, from the store: the item in the slot the tiles show
(knitless.hotbarRealSlot), false for an empty slot, nil with no tiles to read. With Knit the store's
hand is this item; here the hand is HandInvItem, which every module's swap moves. ]]
function knitless.hotbarSelectedItem(ctx)
	local slot = knitless.hotbarRealSlot(ctx)
	local state = slot and ctx.store and ctx.store:getState()
	local observed = state and state.Inventory and state.Inventory.observedInventory
	local entry = observed and observed.hotbar and observed.hotbar[slot + 1]
	if type(entry) ~= 'table' then return nil end
	return entry.item or false
end

-- The inventory or a chest open, which HotbarController asks AppController about before it selects.
function knitless.hotbarAppOpen(ctx)
	local gui = ctx.lplr:FindFirstChildOfClass('PlayerGui')
	for _, id in {'InventoryApp', 'ChestApp'} do
		local app = gui and gui:FindFirstChild(id)
		if app and (not app:IsA('LayerCollector') or app.Enabled) then
			return true
		end
	end
	return false
end

-- The bound action for a slot (priority-keyboard-HotbarSlot<slot + 1>), found by its name's end.
function knitless.hotbarAction(slot)
	local suffix = 'HotbarSlot'..(slot + 1)
	local ok, bound = pcall(function()
		return contextActionService:GetAllBoundActionInfo()
	end)
	if not (ok and type(bound) == 'table') then return nil end
	local found
	for name in bound do
		if type(name) == 'string' and string.sub(name, -#suffix) == suffix then
			if string.find(name, 'keyboard', 1, true) then return name end
			found = found or name
		end
	end
	return found
end

--[[ CallFunction on an action, in a thread of its own: raised to identity 8 first where the executor
can raise it and the thread is below it, so the caller's thread keeps its identity. Returns whether
the call has come back (the game's bound function does not yield) and what pcall gave. ]]
function knitless.hotbarCall(name, inputState, input)
	local done, ok, err = false, false, nil
	task.spawn(function()
		if exec.Identity and type(getthreadidentity) == 'function' and type(setthreadidentity) == 'function' then
			local got, level = pcall(getthreadidentity)
			if got and type(level) == 'number' and level < 8 then
				pcall(setthreadidentity, 8)
			end
		end
		ok, err = pcall(function()
			contextActionService:CallFunction(name, inputState, input)
		end)
		done = true
	end)
	return done, ok, err
end

-- The calling thread raised to identity 8, where the executor can raise it and the thread is below it.
function knitless.hotbarRaise()
	if exec.Identity and type(getthreadidentity) == 'function' and type(setthreadidentity) == 'function' then
		local got, level = pcall(getthreadidentity)
		if got and type(level) == 'number' and level < 8 then
			pcall(setthreadidentity, 8)
		end
	end
end

--[[ The key a slot's action is bound to: the first keyboard KeyCode of its binding
(GetBoundActionInfo), so a key changed in the game's settings is followed; One to Nine by slot when
the binding cannot be read or names no keyboard key. ]]
function knitless.hotbarKey(slot)
	local name = knitless.hotbarAction(slot) or 'priority-keyboard-HotbarSlot'..(slot + 1)
	local ok, info = pcall(function()
		return contextActionService:GetBoundActionInfo(name)
	end)
	local inputs = ok and type(info) == 'table' and info.inputTypes
	for _, input in type(inputs) == 'table' and inputs or {} do
		if typeof(input) == 'EnumItem' and input.EnumType == Enum.KeyCode and input ~= Enum.KeyCode.Unknown then
			local keyName = input.Name
			if not (string.sub(keyName, 1, 6) == 'Button' or string.sub(keyName, 1, 4) == 'DPad'
				or string.sub(keyName, 1, 10) == 'Thumbstick') then
				return input
			end
		end
	end
	local digit = ({'One', 'Two', 'Three', 'Four', 'Five', 'Six', 'Seven', 'Eight', 'Nine'})[slot + 1]
	return digit and Enum.KeyCode[digit] or nil
end

--[[ Whether a number-key press can go now. It is real input: not while a text box has focus (the key
would be typed there), while Roblox's menu or emotes menu is open, while a jade slam holds the
hammer (genv.JadeSlamHold: the game would equip the slot itself, past the hold that keeps the hammer
in hand where there is no namecall hook), or while the player holds that key. A key still marked as
our own press (shared.PistonwareSyntheticKeys) is not the player's. The menu checks are optional
reads: one that errors counts as shut. ]]
function knitless.hotbarKeySafe(ctx, key)
	local inputService = ctx.services.UserInputService
	local function yes(read)
		local ok, value = pcall(read)
		return ok and value == true
	end
	if yes(function() return inputService:GetFocusedTextBox() ~= nil end) then return false end
	if yes(function() return guiService.MenuIsOpen end) then return false end
	if yes(function() return guiService:GetEmotesMenuOpen() end) then return false end
	local hold = genv.JadeSlamHold
	if type(hold) == 'table' and os.clock() < (tonumber(hold.expires) or 0) then return false end
	local marks = shared.PistonwareSyntheticKeys
	if type(marks) == 'table' and (tonumber(marks[key]) or 0) > os.clock() then return true end
	return not yes(function() return inputService:IsKeyDown(key) end)
end

--[[ A number-key tap through VirtualInputManager, in a thread raised as knitless.hotbarCall raises one:
key down now, up a frame later. The key is marked in shared.PistonwareSyntheticKeys from before the
down until half a second after the up, the margin for the release to be delivered, so pistonware's
own binds pass both by. A key the last press still holds is let go first, so the game sees each
selection in order. Returns as knitless.hotbarCall does, for the key down. ]]
function knitless.hotbarKeyPress(route, key)
	local marks = shared.PistonwareSyntheticKeys
	if type(marks) ~= 'table' then
		marks = {}
		shared.PistonwareSyntheticKeys = marks
	end
	local token, previous = {}, marks[key]
	local done, ok, err = false, false, nil
	marks[key] = os.clock() + 1
	task.spawn(function()
		knitless.hotbarRaise()
		ok, err = pcall(function()
			if route.keyHeld[key] then
				virtualInputManager:SendKeyEvent(false, key, false, game)
			end
			route.keyHeld[key] = token
			virtualInputManager:SendKeyEvent(true, key, false, game)
		end)
		done = true
		if not ok then
			route.keyHeld[key] = nil
			marks[key] = previous
			return
		end
		task.wait()
		if route.keyHeld[key] ~= token then return end
		route.keyHeld[key] = nil
		pcall(function()
			virtualInputManager:SendKeyEvent(false, key, false, game)
		end)
		marks[key] = os.clock() + 0.5
	end)
	return done, ok, err
end

-- The InputObject to hand over: the last one kept, else the first gamepad one (there with no pad too).
function knitless.hotbarInput(ctx, route)
	if route.input then return route.input end
	local ok, gamepad = pcall(function()
		return ctx.services.UserInputService:GetGamepadState(Enum.UserInputType.Gamepad1)
	end)
	return ok and type(gamepad) == 'table' and gamepad[1] or nil
end

--[[ Once a session: CallFunction on the game's own slot-1 action with the Cancel state, the same call
a press makes, which the bound function returns from at once (it selects on Begin only). Back with
no error, the route is on, each press then checked by its highlight. Any error, whatever it says,
and the number keys are tried instead (knitless.hotbarKeyProbe); without them the route is off.
Tried again a second later while that action is not bound yet or there is no InputObject to hand
over. ]]
function knitless.hotbarProbe(ctx, route)
	local input = knitless.hotbarInput(ctx, route)
	local name = input and knitless.hotbarAction(0)
	if not name then
		route.nextProbe = os.clock() + 1
		return
	end
	route.status = 'probing'
	local done, ok, err = knitless.hotbarCall(name, Enum.UserInputState.Cancel, input)
	if not done then
		route.status = nil
		route.nextProbe = os.clock() + 5
		return
	end
	if ok then
		route.status = 'on'
		route.method = 'call'
		ctx.log('hotbar: selecting through the game hotbar (ContextActionService:CallFunction)')
	elseif not knitless.hotbarKeyProbe(ctx, route, err) then
		route.status = 'off'
		ctx.log('hotbar: CallFunction is refused here ('..tostring(err)..'); hotbar selections stay as before')
	end
end

--[[ Where CallFunction is refused: checks from a raised thread whether VirtualInputManager answers a
call that sends no input (WaitForInputEventsProcessed). An answer without error turns the route on
with number-key presses (route.method 'key'); an error, or no answer within 3 s, turns it off. While
the probe is out the route is 'probing' and the store selects by itself. Returns false, doing
nothing, without VirtualInputManager. ]]
function knitless.hotbarKeyProbe(ctx, route, refusal)
	if not virtualInputManager then return false end
	route.status = 'probing'
	local settled = false
	local function settle(ok, err)
		if settled then return end
		settled = true
		if route.status ~= 'probing' then return end
		if ok then
			route.status, route.method = 'on', 'key'
			ctx.log('hotbar: CallFunction is refused here ('..tostring(refusal)..'); selecting through the game hotbar by its number keys (VirtualInputManager)')
		else
			route.status = 'off'
			ctx.log('hotbar: CallFunction is refused here ('..tostring(refusal)..'), and VirtualInputManager too ('..tostring(err)..'); hotbar selections stay as before')
		end
	end
	task.spawn(function()
		knitless.hotbarRaise()
		local ok, err = pcall(function()
			virtualInputManager:WaitForInputEventsProcessed()
		end)
		settle(ok, err)
	end)
	if not settled then
		task.delay(3, settle, false, 'no answer within 3 s')
	end
	return true
end

--[[ What the stand-in store reports as hotbarSlot while the route is on: the slot just pressed, until
the tiles show it or its check ends (route.hold is a backstop), else the slot the tiles show. nil
while the route is off or not yet decided, or with no tiles to read: the store then goes by
HandInvItem, as before. ]]
function knitless.hotbarFollow(ctx)
	local route = knitless.hotbarRoute(ctx)
	if route.status == nil and os.clock() >= route.nextProbe then
		knitless.hotbarProbe(ctx, route)
	end
	if route.status ~= 'on' then return nil end
	local real = knitless.hotbarRealSlot(ctx)
	if route.want ~= nil then
		if real ~= route.want and os.clock() < route.wantUntil then
			return route.want
		end
		route.want = nil
	end
	return real
end

--[[ From the store's Heartbeat, ten times a second: whether the game's selection has moved on its own
(a number key, a tile, a respawn) away from what the store holds, so the store reads it again. Also
where an undecided route is probed again. Reads only. ]]
function knitless.hotbarMoved(ctx, current)
	local route = knitless.hotbarRouteState
	if not route or route.status == 'off' or route.status == 'probing' then return false end
	local now = os.clock()
	if now < route.pollAt then return false end
	route.pollAt = now + 0.1
	local slot = knitless.hotbarFollow(ctx)
	return slot ~= nil and slot ~= current
end

--[[ InventorySelectHotbarSlot through the game's own hotbar. nil: the route is off or undecided, there
are no tiles to read, or the press errored (the route then stays off), and the store selects by
itself. 'pressed': the game was asked to select the slot; its HotbarController sends SetInvItem and
select_hotbar, so the store sends neither, and missed() runs if the highlight has not moved within
route.verify seconds and three frames (five for a key, which lands a frame after it is sent). Both
are counted because on a lagging client one frame can outlast route.verify, and two misses in a row
turn the route off. 'following': the route is on but no press is needed or possible (slot already
selected, inventory or chest open, no action or InputObject, a key not safe just then:
knitless.hotbarKeySafe); the store sets the hand alone and sends no select_hotbar. A press made
before the game has drawn the previous one counts from that one (route.want): the game's store has
it already and redraws only for the last. ]]
function knitless.hotbarPress(ctx, slot, chestOpen, missed)
	local route = knitless.hotbarRouteState
	if not (route and route.status == 'on') then return nil end
	local shown = knitless.hotbarRealSlot(ctx)
	if shown == nil then return nil end
	local before = shown
	if route.want ~= nil and os.clock() < route.wantUntil then
		before = route.want
	end
	if before == slot or chestOpen or knitless.hotbarAppOpen(ctx) then return 'following' end
	local name, via, done, ok, err
	if route.method == 'key' then
		local key = knitless.hotbarKey(slot)
		if not (key and knitless.hotbarKeySafe(ctx, key)) then return 'following' end
		name, via = 'key '..key.Name, 'VirtualInputManager'
		done, ok, err = knitless.hotbarKeyPress(route, key)
	else
		name, via = knitless.hotbarAction(slot), 'CallFunction'
		local input = name and knitless.hotbarInput(ctx, route)
		if not input then return 'following' end
		done, ok, err = knitless.hotbarCall(name, Enum.UserInputState.Begin, input)
	end
	if done and not ok then
		route.status = 'off'
		ctx.log('hotbar: '..via..' is refused here ('..tostring(err)..'); hotbar selections stay as before')
		return nil
	end
	route.seq += 1
	local seq = route.seq
	if slot == shown then
		route.want = nil
		return 'following'
	end
	route.want, route.wantUntil = slot, os.clock() + route.hold
	if shared.PistonwareDeveloper then
		ctx.log('hotbar: '..name..' (slot '..before..' to '..slot..')')
	end
	local minFrames = route.method == 'key' and 5 or 3
	task.spawn(function()
		local deadline, frames = os.clock() + route.verify, 0
		repeat
			task.wait()
			frames += 1
			if route.seq ~= seq or route.status ~= 'on' then return end
			local now = knitless.hotbarRealSlot(ctx)
			if now ~= nil and now ~= shown then
				route.misses = 0
				route.want = nil
				return
			end
		until os.clock() >= deadline and frames >= minFrames
		route.want = nil
		if knitless.hotbarRealSlot(ctx) ~= nil then
			route.misses += 1
			ctx.log('hotbar: '..name..' did not move the selection; told to the server as before')
			if route.misses >= 2 then
				route.status = 'off'
				ctx.log('hotbar: two presses in a row did not take; hotbar selections stay as before')
			end
		end
		missed()
	end)
	return 'pressed'
end

--[[ Builds the store and InventoryUtil, sets ctx.store and the two module exports.

Slices and where they come from:
  Inventory  InventoryFolder.Value's accessories (in arrival order), ArmorInvItem_0..2, HandInvItem,
             BedWarsBackpackSlot; the hotbar from the server's slot snapshot (Inventory/GetSlotState,
             then Inventory/SlotStateChanged, under the dragging controller's revision rule).
             hotbarSlot is the slot the game's own hotbar has selected while that can be read and
             asked (knitless.hotbarFollow), else the hotbar slot holding HandInvItem.Value, else the
             last one selected.
  Game       MatchStateEvent (state, customMatch, startTime), MatchEndEvent, QueueTypeEvent and the
             QueueType attribute, TeamsUpdateEvent and the Team attribute.
  Bedwars    the PlayingAsKits and PlayerLevel attributes, TeamUpgradePurchased,
             BulkUpdateTeamUpgrades, SendTablistSnapshot, BulkSendPurchasedItems.
  Kit        the BloodAssassin contract pushes and the bounty hunter target.
  Party      the lobby reducer's default (you, solo), then lobby-events partyInfoEvent.
  Settings   GetSettings, as SettingsController asks for it; fov 80 until it answers. ]]
function knitless.buildStore(ctx)
	ctx.modules['ReplicatedStorage.TS.inventory.inventory-util'] = {InventoryUtil = knitless.storeInventoryUtil()}

	local workspace, runService = ctx.services.Workspace, ctx.services.RunService
	local lplr, net, promise = ctx.lplr, ctx.net, ctx.Promise
	local alive = true
	local listeners = {}
	local inner = {}
	ctx.storeInner = inner

	local state, notified
	local pending, inventoryDirty = false, false

	local function setSlice(name, value)
		if state[name] == value then return end
		local nextState = table.clone(state)
		nextState[name] = value
		state = nextState
		pending = true
	end

	-- A slice is copied only when the value really changes, as a Rodux reducer does.
	local function patch(name, key, value)
		local slice = state[name]
		if slice[key] == value then return end
		local nextSlice = table.clone(slice)
		nextSlice[key] = value
		setSlice(name, nextSlice)
	end

	local function markInventory()
		inventoryDirty = true
	end

	--[[ Inventory. Each accessory keeps one item table until one of its fields changes, so items,
	hand, armor and hotbar hold the same references for as long as nothing about them moves. ]]
	local character
	local itemCache = setmetatable({}, {__mode = 'k'})
	local arrival = {}
	local slotSnapshot
	local selectedSlot = 0

	local function linkValue(name)
		local link = character and character:FindFirstChild(name)
		return link and link:IsA('ObjectValue') and link.Value or nil
	end

	--[[ The store's item table for an accessory tool, reused until its type, Amount, ItemSkin or
	AddedToBackpackTime changes. A tool without AddedToBackpackTime gets the time it was first seen,
	as the game's reducer stamps it. ]]
	local function itemFor(tool)
		if typeof(tool) ~= 'Instance' then return nil end
		local cached = itemCache[tool]
		local added = tool:GetAttribute('AddedToBackpackTime')
		if added == nil then
			added = cached and cached.addedToBackpackTime or workspace:GetServerTimeNow()
		end
		if cached and cached.itemType == tool.Name and cached.amount == tool:GetAttribute('Amount')
			and cached.itemSkin == tool:GetAttribute('ItemSkin') and cached.addedToBackpackTime == added then
			return cached
		end
		local item = knitless.storeItem(tool)
		item.addedToBackpackTime = added
		itemCache[tool] = item
		return item
	end

	local function sameList(a, b)
		if #a ~= #b then return false end
		for index, value in a do
			if b[index] ~= value then return false end
		end
		return true
	end

	local function findSlot(snapshot, ref)
		if type(snapshot) ~= 'table' or type(ref) ~= 'table' then return nil end
		local slots = if ref.container == 'chest' then snapshot.chest and snapshot.chest.slots else snapshot.player and snapshot.player.slots
		if type(slots) ~= 'table' then return nil end
		for _, slot in slots do
			if slot.container == ref.container and slot.index == ref.index then
				return slot
			end
		end
		return nil
	end

	--[[ inventory-slot-to-item: the item a snapshot slot holds, matched by tool, then by type. The
	amount is the accessory's live Amount rather than the snapshot's copy of it. ]]
	local function slotItem(slot, items)
		if type(slot) ~= 'table' then return nil end
		local match
		for _, item in items do
			if item.tool == slot.tool then
				match = item
				break
			end
		end
		if not match then
			for _, item in items do
				if item.itemType == slot.itemType then
					match = item
					break
				end
			end
		end
		local tool = slot.tool or (match and match.tool)
		if match and match.tool == tool then return match end
		return itemFor(tool)
	end

	--[[ The nine hotbar entries from the server's slot snapshot, or before the first snapshot the first
	nine items, as InventoryController fills the hotbar at start. Unchanged entries, and an
	unchanged hotbar, keep their old tables. ]]
	local function buildHotbar(items, previous)
		local hotbar = table.create(9)
		local same = true
		for index = 1, 9 do
			local item
			if slotSnapshot then
				item = slotItem(findSlot(slotSnapshot, {container = 'hotbar', index = index - 1}), items)
			else
				item = items[index]
			end
			local entry = previous[index]
			if not entry or entry.item ~= item then
				entry = if item then {item = item} else {}
				same = false
			end
			hotbar[index] = entry
		end
		return if same then previous else hotbar
	end

	--[[ Rebuilds the Inventory slice from the character's InventoryFolder and its armor, hand and
	backpack links, keeping items in arrival order and reusing every table that did not change, so
	the slice is replaced only when something moved (or with force). While the game's own hotbar is
	followed (knitless.hotbarFollow), hotbarSlot is the slot the game has selected, whatever is in
	hand; otherwise it is the slot holding HandInvItem.Value. ]]
	local function rebuildInventory(force)
		inventoryDirty = false
		local slice = state.Inventory
		local observed = slice.observedInventory
		local old = observed.inventory

		local folder = linkValue('InventoryFolder')
		local children = if folder then folder:GetChildren() else {}
		local present, kept, order = {}, {}, {}
		for _, tool in children do
			present[tool] = true
		end
		for _, tool in arrival do
			if present[tool] then
				table.insert(order, tool)
				kept[tool] = true
			end
		end
		for _, tool in children do
			if not kept[tool] then
				table.insert(order, tool)
			end
		end
		arrival = order

		local items = table.create(#order)
		for index, tool in order do
			items[index] = itemFor(tool)
		end
		if sameList(items, old.items) then items = old.items end

		local armor = table.create(3)
		for slot = 0, 2 do
			armor[slot + 1] = itemFor(linkValue('ArmorInvItem_'..slot)) or 'empty'
		end
		if sameList(armor, old.armor) then armor = old.armor end

		local handTool = linkValue('HandInvItem')
		local hand = if handTool and handTool.Parent then itemFor(handTool) else nil
		local backpack = itemFor(linkValue('BedWarsBackpackSlot'))

		local hotbar = buildHotbar(items, observed.hotbar)
		local followed = knitless.hotbarFollow(ctx)
		if followed then
			selectedSlot = followed
		elseif handTool then
			for index, entry in hotbar do
				if entry.item and entry.item.tool == handTool then
					selectedSlot = index - 1
					break
				end
			end
		end

		local inventory = old
		if force or items ~= old.items or armor ~= old.armor or hand ~= old.hand or backpack ~= old.backpack then
			inventory = {items = items, armor = armor, hand = hand, backpack = backpack}
		end
		local nextObserved = observed
		if force or inventory ~= old or hotbar ~= observed.hotbar or selectedSlot ~= observed.hotbarSlot then
			nextObserved = {
				hotbarSlot = selectedSlot,
				hotbar = hotbar,
				inventory = inventory,
				observedChest = observed.observedChest
			}
		end
		if force or nextObserved ~= observed or slotSnapshot ~= slice.slotSnapshot then
			local nextSlice = table.clone(slice)
			nextSlice.observedInventory = nextObserved
			nextSlice.slotSnapshot = slotSnapshot
			setSlice('Inventory', nextSlice)
		end
	end

	--[[ InventoryDraggingController.applySnapshot: an older player revision keeps the player part
	already held, a chest that is not the one open is dropped, and a snapshot equal to the held one
	changes nothing. ]]
	local function acceptSnapshot(snapshot)
		if type(snapshot) ~= 'table' or type(snapshot.player) ~= 'table' then return false end
		local current = slotSnapshot
		if current and (tonumber(snapshot.player.revision) or 0) < (tonumber(current.player.revision) or 0) then
			snapshot = table.clone(snapshot)
			snapshot.player = current.player
		end
		local chestFolder = linkValue('ObservedChestFolder')
		if (snapshot.chest and snapshot.chest.chestFolder) ~= chestFolder then
			snapshot = table.clone(snapshot)
			local held = current and current.chest
			snapshot.chest = if held and held.chestFolder == chestFolder then held else nil
		end
		local held = current and current.chest
		if held and snapshot.chest and snapshot.chest.chestFolder == held.chestFolder
			and (tonumber(snapshot.chest.revision) or 0) < (tonumber(held.revision) or 0) then
			snapshot = table.clone(snapshot)
			snapshot.chest = held
		end
		if current and current.player.revision == snapshot.player.revision then
			local a, b = current.chest, snapshot.chest
			if (a and a.chestFolder) == (b and b.chestFolder) and (a and a.revision) == (b and b.revision)
				and (a and a.slotCount) == (b and b.slotCount) then
				return false
			end
		end
		slotSnapshot = snapshot
		inventoryDirty = true
		return true
	end

	local function refreshSlots()
		local chest = linkValue('ObservedChestFolder')
		local ok, snapshot = pcall(function()
			return net:GetNamespace('Inventory'):Get('GetSlotState'):CallServer(chest)
		end)
		if not ok then
			ctx.log('store: Inventory/GetSlotState failed: '..tostring(snapshot))
			return false
		end
		if chest and linkValue('ObservedChestFolder') ~= chest then return false end
		return acceptSnapshot(snapshot)
	end

	--[[ InventoryDraggingController.sendTransaction: the request goes up with the open chest and
	the revisions of the latest snapshot, and the snapshot that comes back is applied. A busy server
	is retried only for return_cursor, with the game's backoff. A move turned down because the
	inventory changed meanwhile is sent once more when the slots it names still hold the same thing
	(a close cut of canRetryTransaction, which also weighs the cursor). ]]
	local RETRY_OPERATIONS = {pickup = true, place = true, quick_move = true, swap_hotbar = true, collect = true, drop = true}

	local function sameSlot(a, b)
		if a == b then return true end
		return a ~= nil and b ~= nil and a.itemType == b.itemType and a.amount == b.amount and a.tool == b.tool
	end

	local function sendTransaction(request, mayRetry)
		if not alive then return false end
		if not slotSnapshot then refreshSlots() end
		local before = slotSnapshot
		if not before then return false end
		local chest = linkValue('ObservedChestFolder')
		local remote = net:GetNamespace('Inventory'):Get('TransactSlots')
		local result
		for attempt = 0, 3 do
			local latest = slotSnapshot or before
			local payload = table.clone(request)
			payload.chestFolder = if request.operation ~= 'return_cursor' then chest else nil
			payload.expectedPlayerRevision = latest.player.revision
			payload.expectedChestRevision = latest.chest and latest.chest.revision
			result = remote:CallServer(payload)
			if type(result) ~= 'table' then return false end
			if type(result.state) == 'table' then acceptSnapshot(result.state) end
			if request.operation ~= 'return_cursor' or result.ok then break end
			if result.error ~= 'inventory_busy' and result.error ~= 'chest_busy' then break end
			if attempt < 3 then task.wait(2 ^ attempt * 0.1) end
		end
		if not result.ok and mayRetry ~= false and RETRY_OPERATIONS[request.operation]
			and (result.error == 'player_inventory_changed' or result.error == 'chest_changed')
			and sameSlot(findSlot(before, request.slot), findSlot(slotSnapshot, request.slot))
			and sameSlot(findSlot(before, request.target), findSlot(slotSnapshot, request.target)) then
			return sendTransaction(request, false)
		end
		return result.ok == true
	end

	--[[ One at a time, in order, as the game's transaction queue runs them. Rejections are taken
	with andThen's second handler: exec.Promise's catch also runs on a resolved promise. ]]
	local queue = promise.resolve()
	local function transact(request)
		local promise = queue:andThen(function()
			return sendTransaction(request)
		end):andThen(function(took)
			return took
		end, function(err)
			ctx.log('store: inventory transaction failed: '..tostring(err))
			return false
		end)
		queue = promise:andThen(function() end)
		return promise
	end

	--[[ InventorySelectHotbarSlot: hotbarSlot and the hand become that slot's item at once, HandInvItem
	included, so a caller sees the tool in hand on return. Where the game's own hotbar can be asked
	(knitless.hotbarPress), the game moves its highlight and sends SetInvItem and select_hotbar
	itself; if the press does not take, the hand goes to the server from here. Otherwise a deferred
	thread sends SetInvItem when the tool changed, and select_hotbar when the slot changed, a
	snapshot is held and the route is off. ]]
	local function selectHotbarSlot(slot)
		local observed = state.Inventory.observedInventory
		local entry = type(slot) == 'number' and observed.hotbar[slot + 1]
		if not entry then
			ctx.log('store: InventorySelectHotbarSlot for a slot that does not exist: '..tostring(slot))
			return
		end
		local tool = entry.item and entry.item.tool
		local previousSlot = observed.hotbarSlot
		local link = character and character:FindFirstChild('HandInvItem')
		if not (link and link:IsA('ObjectValue')) then link = nil end
		local previousTool = link and link.Value
		selectedSlot = slot
		local route = knitless.hotbarPress(ctx, slot, linkValue('ObservedChestFolder') ~= nil, function()
			if not alive then return end
			if link and previousTool ~= tool and link.Value == tool then
				pcall(function()
					net:Get('SetInvItem'):CallServerAsync({hand = tool or false})
				end)
			end
			markInventory()
		end)
		if link and previousTool ~= tool then
			link.Value = tool
		end
		rebuildInventory(true)
		if route == 'pressed' then return end
		task.defer(function()
			if not alive then return end
			if link and previousTool ~= tool then
				pcall(function()
					net:Get('SetInvItem'):CallServerAsync({hand = tool or false})
				end)
			end
			if slot ~= previousSlot and slotSnapshot and route == nil then
				transact({operation = 'select_hotbar', target = {container = 'hotbar', index = slot}})
			end
		end)
	end

	--[[ InventorySetArmorItem. With the server's snapshot held, the game's hotbar controller puts
	the snapshot's armor back on, so nothing reaches the server; without one it is equipArmorItem
	(ArmorInvItem set locally, SetArmorInvItem). Either way a new Inventory goes out, as the reducer
	makes, so a caller waiting on InventoryChanged is woken. ]]
	local function setArmorItem(action)
		local slot = action.armorSlot
		if type(slot) ~= 'number' or slot < 0 or slot > 2 then return end
		if not slotSnapshot then
			local tool = type(action.item) == 'table' and action.item.tool or nil
			local link = character and character:FindFirstChild('ArmorInvItem_'..slot)
			if link and link:IsA('ObjectValue') and link.Value ~= tool then
				link.Value = tool
				task.defer(function()
					pcall(function()
						net:Get('SetArmorInvItem'):CallServerAsync({item = tool or false, armorSlot = slot})
					end)
				end)
			end
		end
		rebuildInventory(true)
	end

	-- A remote by name now, or once it replicates.
	local function listen(name, callback)
		local function guarded(...)
			local ok, err = pcall(callback, ...)
			if not ok then
				ctx.log('store: '..name..' handler failed: '..tostring(err))
			end
		end
		local connected = pcall(function()
			ctx.clean(net:Get(name):Connect(guarded))
		end)
		if connected then return end
		net:WaitFor(name):andThen(function(remote)
			if not alive then return end
			local ok, err = pcall(function()
				ctx.clean(remote:Connect(guarded))
			end)
			if not ok then
				ctx.log('store: cannot listen to '..name..': '..tostring(err))
			end
		end, function(err)
			ctx.log('store: no '..name..' remote: '..tostring(err))
		end)
	end

	local function kitList()
		local kits = {}
		local value = lplr:GetAttribute('PlayingAsKits')
		if type(value) == 'string' then
			for _, kit in string.split(value, ',') do
				kit = kit:match('^%s*(.-)%s*$')
				if kit ~= '' then
					table.insert(kits, kit)
				end
			end
		end
		return kits
	end

	-- GameSetTeams picks the team whose id is your Team attribute; missed, it is the id alone.
	local function myTeam()
		local id = lplr:GetAttribute('Team')
		if id == nil then return nil end
		local gameSlice = state and state.Game
		if gameSlice then
			for _, team in gameSlice.teams do
				if type(team) == 'table' and tostring(team.id) == tostring(id) then
					return team
				end
			end
			if gameSlice.myTeam and tostring(gameSlice.myTeam.id) == tostring(id) then
				return gameSlice.myTeam
			end
		end
		return {id = id}
	end

	local function setTeamUpgrades(teamId, upgrades)
		if teamId == nil then return end
		local all = table.clone(state.Bedwars.teamUpgrades)
		all[tostring(teamId)] = upgrades
		patch('Bedwars', 'teamUpgrades', all)
	end

	-- BountyHunterController asks once its kit is active.
	local bountyAsked = false
	local function askBountyTarget()
		if bountyAsked or not table.find(kitList(), 'bounty_hunter') then return end
		bountyAsked = true
		net:WaitFor('GetBountyHunterTarget'):andThen(function(remote)
			return remote:CallServerAsync()
		end):andThen(function(target)
			if alive then
				patch('Kit', 'bountyHunterTarget', target)
			end
		end, function(err)
			ctx.log('store: GetBountyHunterTarget failed: '..tostring(err))
		end)
	end

	local LINKS = {
		InventoryFolder = true,
		HandInvItem = true,
		ArmorInvItem_0 = true,
		ArmorInvItem_1 = true,
		ArmorInvItem_2 = true,
		BedWarsBackpackSlot = true,
		ObservedChestFolder = true
	}
	local characterConnections, folderConnections, itemConnections = {}, {}, {}

	local function drop(connections)
		for key, connection in connections do
			pcall(function()
				connection:Disconnect()
			end)
			connections[key] = nil
		end
	end

	-- Only the attributes an item table carries; an accessory's other attributes change nothing here.
	local ITEM_ATTRIBUTES = {Amount = true, ItemSkin = true, AddedToBackpackTime = true}
	local function watchItem(tool)
		if not itemConnections[tool] then
			itemConnections[tool] = tool.AttributeChanged:Connect(function(attribute)
				if ITEM_ATTRIBUTES[attribute] then markInventory() end
			end)
		end
	end

	local function watchFolder()
		drop(folderConnections)
		drop(itemConnections)
		local folder = linkValue('InventoryFolder')
		if not folder then return end
		for _, tool in folder:GetChildren() do
			watchItem(tool)
		end
		table.insert(folderConnections, folder.ChildAdded:Connect(function(tool)
			watchItem(tool)
			markInventory()
		end))
		table.insert(folderConnections, folder.ChildRemoved:Connect(function(tool)
			local connection = itemConnections[tool]
			if connection then
				connection:Disconnect()
				itemConnections[tool] = nil
			end
			markInventory()
		end))
	end

	local function watchLink(link)
		if not (LINKS[link.Name] and link:IsA('ObjectValue')) then return end
		table.insert(characterConnections, link.Changed:Connect(function()
			if link.Name == 'InventoryFolder' then watchFolder() end
			markInventory()
		end))
		if link.Name == 'InventoryFolder' then watchFolder() end
	end

	--[[ The game empties its items when the character goes (each item's maid dispatches
	InventoryRemoveItem), and fills them again from the new one. ]]
	local function watchCharacter(newCharacter)
		drop(characterConnections)
		drop(folderConnections)
		drop(itemConnections)
		character = newCharacter
		markInventory()
		if not newCharacter then return end
		for _, child in newCharacter:GetChildren() do
			watchLink(child)
		end
		table.insert(characterConnections, newCharacter.ChildAdded:Connect(function(child)
			watchLink(child)
			if LINKS[child.Name] then markInventory() end
		end))
		table.insert(characterConnections, newCharacter.ChildRemoved:Connect(function(child)
			if LINKS[child.Name] then markInventory() end
		end))
	end

	local function flush()
		if inventoryDirty then
			local ok, err = pcall(rebuildInventory, false)
			if not ok then
				ctx.log('store: inventory rebuild failed: '..tostring(err))
			end
		end
		pending = false
		local new, old = state, notified
		if new == old then return end
		notified = new
		for _, connection in table.clone(listeners) do
			if connection.connected then
				local ok, err = pcall(connection.callback, new, old)
				if not ok then
					ctx.log('store: a changed listener failed: '..tostring(err))
				end
			end
		end
	end

	--[[ The stand-in store's starting state, in the game's Rodux slices: Inventory, Game, Bedwars, Kit,
	Party and Settings. The open chest's items are not mirrored, as nothing reads them from the
	store. ]]
	state = {
		Inventory = {
			observedPlayer = lplr,
			taxState = 0,
			observedInventory = {
				hotbarSlot = 0,
				hotbar = {{}, {}, {}, {}, {}, {}, {}, {}, {}},
				inventory = {items = {}, armor = {'empty', 'empty', 'empty'}},
				observedChest = {items = {}}
			}
		},
		Game = {teams = {}, matchState = 0, queueType = workspace:GetAttribute('QueueType'), spectating = false},
		Bedwars = {
			kit = kitList()[1] or 'none',
			kits = {},
			teamUpgrades = {},
			myTeamUpgrades = {},
			itemTiersPurchased = {},
			playerLevel = tonumber(lplr:GetAttribute('PlayerLevel')) or 0
		},
		Kit = {availableContracts = {}},
		Party = {
			leader = {userId = lplr.UserId, name = lplr.Name, displayName = lplr.DisplayName},
			members = {},
			queueState = 0,
			outgoingInviteUserIds = {}
		},
		Settings = {fov = 80}
	}
	state.Game.myTeam = myTeam()

	ctx.clean(function()
		alive = false
		table.clear(listeners)
		drop(characterConnections)
		drop(folderConnections)
		drop(itemConnections)
	end)
	watchCharacter(lplr.Character)
	ctx.clean(lplr.CharacterAdded:Connect(watchCharacter))
	ctx.clean(lplr.CharacterRemoving:Connect(function(old)
		if old == character then watchCharacter(nil) end
	end))
	rebuildInventory(false)

	--[[ MatchStateEvent only fires on a change, so a late injection starts from a guess (running when
	you have a team and items) and then reads the top bar's clock. ]]
	local matchStateHeard = false
	local hasItems = #state.Inventory.observedInventory.inventory.items > 0
	patch('Game', 'matchState', if lplr:GetAttribute('Team') ~= nil and hasItems then 1 else 0)
	notified = state
	pending = false

	listen('Inventory/SlotStateChanged', acceptSnapshot)
	listen('MatchStateEvent', function(matchState, customMatch, startTime)
		matchStateHeard = true
		patch('Game', 'matchState', matchState)
		if startTime ~= nil then patch('Game', 'startTime', startTime) end
		if customMatch ~= nil then patch('Game', 'customMatch', customMatch) end
	end)
	listen('MatchEndEvent', function()
		matchStateHeard = true
		patch('Game', 'matchState', 2)
	end)
	listen('QueueTypeEvent', function(queueType)
		patch('Game', 'queueType', queueType)
	end)
	listen('TeamsUpdateEvent', function(data)
		if type(data) ~= 'table' or type(data.teams) ~= 'table' then return end
		local teams = {}
		for _, team in data.teams do
			table.insert(teams, team)
		end
		patch('Game', 'teams', teams)
		patch('Game', 'myTeam', myTeam())
	end)
	listen('TeamUpgradePurchased', function(teamId, upgrades)
		if teamId ~= nil and tostring(teamId) == tostring(lplr:GetAttribute('Team')) then
			patch('Bedwars', 'myTeamUpgrades', upgrades)
		end
		setTeamUpgrades(teamId, upgrades)
	end)
	listen('BulkUpdateTeamUpgrades', function(upgrades)
		if type(upgrades) == 'table' then
			patch('Bedwars', 'myTeamUpgrades', upgrades)
		end
	end)
	listen('SendTablistSnapshot', function(snapshot)
		if type(snapshot) ~= 'table' or type(snapshot.teams) ~= 'table' then return end
		for teamId, team in snapshot.teams do
			if type(team) == 'table' and team.teamUpgrades then
				setTeamUpgrades(teamId, team.teamUpgrades)
			end
		end
	end)
	listen('BulkSendPurchasedItems', function(data)
		if type(data) ~= 'table' or type(data.purchasedItems) ~= 'table' then return end
		local list = if data.reset then {} else table.clone(state.Bedwars.itemTiersPurchased)
		for _, itemType in data.purchasedItems do
			table.insert(list, itemType)
		end
		patch('Bedwars', 'itemTiersPurchased', list)
	end)
	listen('BloodAssassinUpdateAvailableContracts', function(data)
		if type(data) == 'table' and type(data.contracts) == 'table' then
			patch('Kit', 'availableContracts', data.contracts)
		end
	end)
	--[[ Keeps Kit.activeContract in step with the server. A contract that arrives without a start time
	is stamped with the server time, as BloodAssassinController does. ]]
	listen('BloodAssassinSetActiveContract', function(data)
		if type(data) ~= 'table' then return end
		local contract = data.activeContract
		if type(contract) == 'table' then
			local activated = contract.activationTime
			if not activated or activated == 0 or activated ~= activated then
				contract = table.clone(contract)
				contract.activationTime = workspace:GetServerTimeNow()
			end
		end
		patch('Kit', 'activeContract', contract)
	end)
	listen('BountyHunterTargetChanged', function(data)
		if type(data) == 'table' and data.hunter == lplr then
			patch('Kit', 'bountyHunterTarget', data.target)
			patch('Kit', 'bountyHunterReward', data.reward)
		end
	end)

	ctx.clean(workspace:GetAttributeChangedSignal('QueueType'):Connect(function()
		local queueType = workspace:GetAttribute('QueueType')
		if queueType ~= nil then
			patch('Game', 'queueType', queueType)
		end
	end))
	ctx.clean(lplr:GetAttributeChangedSignal('Team'):Connect(function()
		patch('Game', 'myTeam', myTeam())
	end))
	ctx.clean(lplr:GetAttributeChangedSignal('PlayingAsKits'):Connect(function()
		patch('Bedwars', 'kit', kitList()[1] or 'none')
		askBountyTarget()
	end))
	ctx.clean(lplr:GetAttributeChangedSignal('PlayerLevel'):Connect(function()
		local level = tonumber(lplr:GetAttribute('PlayerLevel'))
		if level then
			patch('Bedwars', 'playerLevel', level)
		end
	end))
	askBountyTarget()

	-- The tablist asks for its snapshot once at start; this asks once more for the upgrades in it.
	pcall(function()
		net:Get('RequestTablistSnapshot'):SendToServer()
	end)

	pcall(function()
		local events = ctx.events('@easy-games/lobby:shared/event/lobby-events@getEvents.Events')
		local info = events and events:FindFirstChild('partyInfoEvent')
		if not (info and info:IsA('RemoteEvent')) then return end
		ctx.clean(info.OnClientEvent:Connect(function(data)
			if type(data) == 'table' and type(data.party) == 'table' then
				setSlice('Party', data.party)
			end
		end))
		local request = events:FindFirstChild('requestPartyInfo')
		if request and request:IsA('RemoteEvent') then
			request:FireServer()
		end
	end)

	net:WaitFor('GetSettings'):andThen(function(remote)
		return remote:CallServer()
	end):andThen(function(settings)
		if not (alive and type(settings) == 'table') then return end
		local merged = table.clone(state.Settings)
		for key, value in settings do
			merged[key] = value
		end
		setSlice('Settings', merged)
	end, function(err)
		ctx.log('store: GetSettings failed: '..tostring(err))
	end)

	task.spawn(function()
		for attempt = 1, 3 do
			if not alive or slotSnapshot then return end
			refreshSlots()
			if slotSnapshot then return end
			task.wait(2 * attempt)
		end
	end)

	task.spawn(function()
		local inferred, seconds = knitless.storeReadHudTimer(lplr)
		if not alive or matchStateHeard or inferred == nil then return end
		patch('Game', 'matchState', inferred)
		if inferred == 1 and seconds then
			patch('Game', 'startTime', workspace:GetServerTimeNow() - seconds)
		end
	end)

	-- Rodux flushes on Heartbeat; so does this, and only when something is waiting. While the game's
	-- own hotbar is in use, a selection it made on its own is looked for here (knitless.hotbarMoved).
	ctx.clean(runService.Heartbeat:Connect(function()
		if not inventoryDirty and knitless.hotbarMoved(ctx, state.Inventory.observedInventory.hotbarSlot) then
			inventoryDirty = true
		end
		if pending or inventoryDirty then
			flush()
		end
	end))

	local changed = {}
	function changed:connect(callback)
		local connection = {connected = true, callback = callback}
		local function disconnect()
			connection.connected = false
			local index = table.find(listeners, connection)
			if index then
				table.remove(listeners, index)
			end
		end
		connection.disconnect = disconnect
		connection.Disconnect = disconnect
		table.insert(listeners, connection)
		return connection
	end
	changed.Connect = changed.connect

	--[[ The actions pistonware sends. The hotbar edits of the old client (InventoryAddToHotbar,
	InventoryRemoveFromHotbar, InventorySwapHotbarSlots) leave the state as it is, which is what the
	reducer does once the server's snapshot is in; any other action is logged once and ignored. ]]
	local unmirrored = {}
	local store = {changed = changed}
	function store:getState()
		return state
	end
	function store:dispatch(action)
		if type(action) ~= 'table' then return end
		local kind = action.type
		local ok, err = pcall(function()
			if kind == 'InventorySelectHotbarSlot' then
				selectHotbarSlot(action.slot)
			elseif kind == 'InventorySetArmorItem' then
				setArmorItem(action)
			elseif kind == 'InventorySlotSnapshot' then
				acceptSnapshot(action.snapshot)
			elseif kind == 'BedwarsAddItemPurchased' then
				local list = table.clone(state.Bedwars.itemTiersPurchased)
				table.insert(list, action.itemType)
				patch('Bedwars', 'itemTiersPurchased', list)
			elseif not unmirrored[kind] then
				unmirrored[kind] = true
				ctx.log('store: action '..tostring(kind)..' is not mirrored without Knit')
			end
		end)
		if not ok then
			ctx.log('store: '..tostring(kind)..' failed: '..tostring(err))
		end
	end

	inner.transact = transact
	inner.refresh = function()
		return promise.new(function(resolve)
			resolve(refreshSlots())
		end)
	end
	inner.observedChestFolder = function()
		return linkValue('ObservedChestFolder')
	end
	inner.acceptSnapshot = acceptSnapshot
	inner.getSnapshot = function()
		return slotSnapshot
	end
	inner.patch = patch
	inner.setSlice = setSlice
	inner.notify = markInventory

	ctx.store = store
	ctx.modules['PlayerScripts.TS.ui.store'] = {ClientStore = store}
	return store
end

--[[ One Inventory/TransactSlots request ({operation, slot?, target?, mode?}), queued behind the ones
before it like the dragging controller's transact. The promise resolves true when the server took it. ]]
function knitless.storeTransact(ctx, request)
	local inner = ctx.storeInner
	if not inner then return ctx.Promise.resolve(false) end
	return inner.transact(request)
end

-- Asks the server for the slot snapshot again (Inventory/GetSlotState).
function knitless.storeRefreshSlots(ctx)
	local inner = ctx.storeInner
	if not inner then return ctx.Promise.resolve(false) end
	return inner.refresh()
end

--[[ An InventoryDraggingController stand-in over the store's snapshot, with the members AutoHotbar
uses: transact(request) and refresh() returning promises, getObservedChestFolder(), and snapshot. ]]
function knitless.storeDraggingController(ctx)
	local inner = ctx.storeInner
	if not inner then return nil end
	local controller = setmetatable({}, {__index = function(_, key)
		if key == 'snapshot' then
			return inner.getSnapshot()
		end
		return nil
	end})
	function controller:transact(request)
		return inner.transact(request)
	end
	function controller:refresh()
		return inner.refresh()
	end
	function controller:getObservedChestFolder()
		return inner.observedChestFolder()
	end
	function controller:applySnapshot(snapshot)
		inner.acceptSnapshot(snapshot)
	end
	return controller
end

--[[ Sets one field of a slice the way a reducer would (a new slice table, changed on the next
Heartbeat), for slices that own state the store should show. A slice that is not there yet is made. ]]
function knitless.storePatch(ctx, slice, key, value)
	local inner = ctx.storeInner
	if not (inner and ctx.store) then return end
	if ctx.store:getState()[slice] == nil then
		inner.setSlice(slice, {[key] = value})
	else
		inner.patch(slice, key, value)
	end
end

-- Re-reads the inventory instances on the next Heartbeat.
function knitless.storeNotify(ctx)
	local inner = ctx.storeInner
	if inner then
		inner.notify()
	end
end

--[[ Blocks slice of the knitless layer: the block engine the bootstrap reads as
bedwars.BlockController, the client engine and BlockPlacer that store.blockPlacer is built from, the
block-engine remotes and BuilderUtil. Each rule follows the game's module of the same name; where the
game asks client-only state this layer cannot see, the function says what it does instead. ]]

--[[ World position to block cell, as PositionUtil.convertToBlockPosition: a third of it, rounded. A
rounded -0 is folded into 0 so one cell is always one table key. ]]
function knitless.blockCell(position)
	return Vector3.new(
		math.round(position.X / 3) + 0,
		math.round(position.Y / 3) + 0,
		math.round(position.Z / 3) + 0
	)
end

--[[ A cell as the store keys it, as BasicBlockStore.getKey: every component rounded. ]]
function knitless.blockKey(position)
	return Vector3.new(math.round(position.X) + 0, math.round(position.Y) + 0, math.round(position.Z) + 0)
end

--[[ BlockEngine.snapBlockRotation: degrees to the nearest of 0, 90, 180, 270 and 360. ]]
function knitless.snapBlockRotation(degrees)
	local angle = degrees % 360
	local best, bestGap = 0, math.abs(angle)
	for _, option in {90, 180, 270, 360} do
		local gap = math.abs(angle - option)
		if gap < bestGap then
			best, bestGap = option, gap
		end
	end
	return best
end

--[[ The block handler registry by block type, as game-block-engine.module fills it: a greedy handler for
every ItemMeta block with a greedyMesh and for glass, barrier, magic glass, smoke and stone-player
blocks, a plain one for the four crops, and a prefab handler for every source block in
ReplicatedStorage.Assets.Blocks, which is registered last and wins. A prefab whose item has no block
meta gets the plain prefab handler, as the game's source-block hook returns nothing for it. Without
the data file every type gets a handler that decides from the block itself: greedy when the block
has the GreedyBlock attribute, which only GreedyBlockHandler.place sets.

Footprints of prefabs that hold more than their root cell come from each handler's
getContainedPositions; place marks those whose getPlacementPositions asks for the same cells, and
the rest place on the root cell only. The bed's second cell follows its yaw. The gargoyle statues
read their footprint from their parts and count as their root cell here. A greedy block holds every
cell in its box, cached until its size changes. Until the source folder has replicated every other
block counts as a prefab, and a miss is remembered only once that folder exists. Handler:place
returns an unparented copy for previews such as Schematica's, which the server never hears of. ]]
function knitless.newBlockRegistry(ctx, itemMeta)
	local replicatedStorage = ctx.services.ReplicatedStorage
	local up = Vector3.new(0, 1, 0)
	local greedyTypes = {glass = true, barrier = true, magic_glass = true, smoke_block = true, stone_player_block = true}
	local cropTypes = {pumpkin = true, melon = true, chicken_egg_block = true, carrot = true}

	local function sourceFolder()
		local assets = replicatedStorage:FindFirstChild('Assets')
		return assets and assets:FindFirstChild('Blocks')
	end

	local function box(width, height, depth)
		local cells = {}
		for x = 0, width - 1 do
			for y = 0, height - 1 do
				for z = 0, depth - 1 do
					table.insert(cells, Vector3.new(x, y, z))
				end
			end
		end
		return cells
	end

	local function bedShape(root, degrees)
		local turn = knitless.snapBlockRotation(degrees)
		local second = if turn == 0 or turn == 360 then Vector3.new(0, 0, 1)
			elseif turn == 270 then Vector3.new(-1, 0, 0)
			elseif turn == 180 then Vector3.new(0, 0, -1)
			else Vector3.new(1, 0, 0)
		return {root, root + second}
	end

	local function cottonCandyShape(root, degrees)
		local turn = knitless.snapBlockRotation(degrees)
		local width = if turn == 90 then Vector3.new(0, 0, 1)
			elseif turn == 180 then Vector3.new(-1, 0, 0)
			elseif turn == 270 then Vector3.new(0, 0, -1)
			else Vector3.new(1, 0, 0)
		local cells = {}
		for across = 0, 1 do
			for high = 0, 1 do
				table.insert(cells, root + width * across + up * high)
			end
		end
		return cells
	end

	local tall = {cells = {Vector3.zero, up}, place = true}
	local taller = {cells = {Vector3.zero, up, up * 2}, place = true}
	local footprints = {
		bed = {shape = bedShape},
		og_bed = {cells = {Vector3.zero, Vector3.new(0, 0, 1)}},
		black_market_shop = {cells = {Vector3.zero, Vector3.new(0, 0, 1)}},
		cursed_coffin = {cells = {Vector3.zero, Vector3.new(-1, 0, 0)}},
		cotton_candy_machine = {shape = cottonCandyShape, place = true},
		camera_turret = tall,
		grave_trap = tall,
		tesla_trap = tall,
		diamond_capture_block = tall,
		fire_sheep_statue = tall,
		target_dummy_tier_1 = tall,
		target_dummy_tier_2 = tall,
		target_dummy_tier_3 = tall,
		target_dummy_tier_4 = tall,
		lightning_coil = taller,
		snow_cone_machine = taller,
		broken_snow_cone_machine = taller,
		zipline_base = taller,
		huge_lucky_block = {cells = box(2, 2, 2), place = true},
		merchant_region = {cells = box(7, 5, 8), place = true},
	}

	local greedyCache = setmetatable({}, {__mode = 'k'})
	local function greedyCells(block)
		local size = block.Size / 3
		local cached = greedyCache[block]
		if cached and cached.size == size then
			return cached.cells
		end
		local low = block.Position / 3 - size / 2 + Vector3.new(0.5, 0.5, 0.5)
		local cells = {}
		for x = 0, math.max(math.round(size.X), 1) - 1 do
			for y = 0, math.max(math.round(size.Y), 1) - 1 do
				for z = 0, math.max(math.round(size.Z), 1) - 1 do
					table.insert(cells, knitless.blockKey(low + Vector3.new(x, y, z)))
				end
			end
		end
		greedyCache[block] = {size = size, cells = cells}
		return cells
	end

	local Handler = {}
	Handler.__index = Handler

	function Handler:getBlockType()
		return self.blockType
	end

	function Handler:getBlockMeta()
		return self.blockMeta
	end

	function Handler:isGreedy(block)
		if self.kind == 'auto' then
			return block ~= nil and block:GetAttribute('GreedyBlock') == true
		end
		return self.kind == 'greedy'
	end

	function Handler:getContainedPositions(block)
		if not block then return {} end
		if self:isGreedy(block) then
			return greedyCells(block)
		end
		local root = knitless.blockCell(block.Position)
		local footprint = self.footprint
		if not footprint then
			return {root}
		end
		if footprint.shape then
			return footprint.shape(root, math.deg((select(2, block.CFrame:ToOrientation()))))
		end
		local cells = table.create(#footprint.cells)
		for index, offset in footprint.cells do
			cells[index] = root + offset
		end
		return cells
	end

	function Handler:getPlacementPositions(cell, rotation)
		local footprint = self.footprint
		if not (footprint and footprint.place) then
			return {cell}
		end
		if footprint.shape then
			return footprint.shape(cell, rotation or 0)
		end
		local cells = table.create(#footprint.cells)
		for index, offset in footprint.cells do
			cells[index] = cell + offset
		end
		return cells
	end

	function Handler:place(cell)
		local folder = sourceFolder()
		local source = folder and folder:FindFirstChild(self.blockType)
		local root = source and source:FindFirstChild('Root')
		local part = root and root:Clone()
		if not part then
			part = Instance.new('Part')
			part.Size = Vector3.new(3, 3, 3)
		end
		part.Name = self.blockType
		part.Anchored = true
		part.CFrame = CFrame.new(cell * 3)
		return part
	end

	local function newHandler(name, kind, blockMeta, footprint)
		return setmetatable({
			blockType = name,
			kind = kind,
			blockMeta = blockMeta or {breakType = 'wood'},
			footprint = footprint
		}, Handler)
	end

	local function resolve(name)
		if not itemMeta then
			return newHandler(name, 'auto', nil, footprints[name])
		end
		local meta = itemMeta[name]
		local blockMeta = type(meta) == 'table' and meta.block or nil
		local folder = sourceFolder()
		if folder and folder:FindFirstChild(name) then
			return newHandler(name, 'prefab', blockMeta, blockMeta and footprints[name] or nil)
		end
		if not blockMeta then return nil end
		if cropTypes[name] then
			return newHandler(name, 'single', blockMeta)
		end
		if greedyTypes[name] or blockMeta.greedyMesh then
			return newHandler(name, 'greedy', blockMeta)
		end
		if not folder then
			return newHandler(name, 'prefab', blockMeta, footprints[name])
		end
		return nil
	end

	local registry = {handlers = {}, fallback = newHandler('', 'auto')}

	function registry:getHandler(name)
		if type(name) ~= 'string' then return nil end
		local handler = self.handlers[name]
		if handler == nil then
			handler = resolve(name)
			if handler or sourceFolder() then
				self.handlers[name] = handler or false
			end
		end
		return handler or nil
	end

	return registry
end

--[[ BasicBlockStore over the 'block' tag, filled as IClientBlockEngine.startBlockReplication fills it:
every cell its handler says the block holds, only its root cell when it is tagged
single-space-block, and a greedy block's cells again whenever its size changes. A block whose type
has no handler is kept by its root cell. A cell taken from another block drops that block's root, as
BasicBlockStore.setBlock does. getBlockData reads Workspace.BlockData[BlockUUID], or
BlockUUID_<cell> for a greedy block; the server names that one after its own integer cell, so an
unrounded cell is tried rounded too.

hold keeps the client's own copy of a block it asked the server for, as the game's placer does from
the request until the answer, so a caller sees the cell taken at once: Scaffold grows its line off
it, and nothing asks for the cell again while the request is out. The copy is never parented, tagged
or drawn and holds only an empty cell. The server's part takes the cell over when it replicates, and
letGo clears the cell only while the copy still holds it. ]]
function knitless.newBlockStore(ctx, registry)
	local collectionService = ctx.services.CollectionService
	local workspace = ctx.services.Workspace
	local blocks, roots, tracked, held = {}, {}, {}, {}
	local store = {blocks = blocks, blockRoots = roots, handlerRegistry = registry}

	function store:getKey(position)
		return knitless.blockKey(position)
	end

	function store:getBlockAt(position)
		if not position then return nil end
		return blocks[Vector3.new(math.round(position.X) + 0, math.round(position.Y) + 0, math.round(position.Z) + 0)]
	end

	function store:getBlockRootPosition(block)
		return roots[block]
	end

	function store:getAllBlocks()
		local list = {}
		for _, block in blocks do
			table.insert(list, block)
		end
		return list
	end

	function store:getAllBlockPositions()
		local list = {}
		for cell in blocks do
			table.insert(list, cell)
		end
		return list
	end

	function store:getBlockDataFolder()
		return workspace:FindFirstChild('BlockData')
	end

	function store:getBlockDataName(block, position)
		local uuid = block:GetAttribute('BlockUUID')
		if block:GetAttribute('GreedyBlock') == true then
			return tostring(uuid)..'_'..tostring(position)
		end
		return uuid
	end

	function store:getBlockData(position)
		local block = self:getBlockAt(position)
		local folder = block and workspace:FindFirstChild('BlockData')
		if not folder then return nil end
		local name = self:getBlockDataName(block, position)
		local data = name ~= nil and folder:FindFirstChild(tostring(name)) or nil
		if not data and block:GetAttribute('GreedyBlock') == true then
			data = folder:FindFirstChild(tostring(block:GetAttribute('BlockUUID'))..'_'..tostring(knitless.blockKey(position)))
		end
		return data
	end

	local function claim(block, cells)
		for _, cell in cells do
			local key = knitless.blockKey(cell)
			local previous = blocks[key]
			if previous ~= nil and previous ~= block then
				roots[previous] = nil
			end
			blocks[key] = block
		end
	end

	local function release(block, cells, keep)
		for _, cell in cells do
			local key = knitless.blockKey(cell)
			if not (keep and keep[key]) and blocks[key] == block then
				blocks[key] = nil
			end
		end
	end

	local function add(block)
		if tracked[block] or not block:IsA('BasePart') then return end
		local root = knitless.blockCell(block.Position)
		local single = collectionService:HasTag(block, 'single-space-block')
		local handler = registry:getHandler(block.Name) or registry.fallback
		local entry = {cells = if single then {root} else handler:getContainedPositions(block)}
		tracked[block] = entry
		claim(block, entry.cells)
		roots[block] = root
		if not single and handler:isGreedy(block) then
			entry.resized = block:GetPropertyChangedSignal('Size'):Connect(function()
				local cells = handler:getContainedPositions(block)
				local keep = {}
				for _, cell in cells do
					keep[knitless.blockKey(cell)] = true
				end
				release(block, entry.cells, keep)
				entry.cells = cells
				claim(block, cells)
				roots[block] = knitless.blockCell(block.Position)
			end)
		end
	end

	local function remove(block)
		local entry = tracked[block]
		if not entry then return end
		tracked[block] = nil
		if entry.resized then
			entry.resized:Disconnect()
		end
		release(block, entry.cells)
		roots[block] = nil
	end

	function store:hold(cell, part)
		local key = knitless.blockKey(cell)
		if blocks[key] ~= nil then return nil end
		held[part] = key
		blocks[key] = part
		roots[part] = key
		return part
	end

	function store:letGo(part)
		local key = held[part]
		if key == nil then return end
		held[part] = nil
		if blocks[key] == part then
			blocks[key] = nil
		end
		roots[part] = nil
		part:Destroy()
	end

	ctx.clean(collectionService:GetInstanceAddedSignal('block'):Connect(function(block)
		pcall(add, block)
	end))
	ctx.clean(collectionService:GetInstanceRemovedSignal('block'):Connect(function(block)
		pcall(remove, block)
	end))
	ctx.clean(function()
		for _, entry in tracked do
			if entry.resized then
				entry.resized:Disconnect()
			end
		end
		table.clear(tracked)
		for part, key in held do
			if blocks[key] == part then
				blocks[key] = nil
			end
			roots[part] = nil
			pcall(part.Destroy, part)
		end
		table.clear(held)
	end)
	for _, block in collectionService:GetTagged('block') do
		pcall(add, block)
	end

	return store
end

--[[ The shared BlockEngine singleton (block-engine.out .BlockEngine) over the stand-in store and
registry. getCharacter follows BlockEngineCharacter: a live model in the player's ObjectValue of
that name acts for them, else their character. isBlockBreakable applies the one breakable hook the
game has: NoBreak, then Team<team>NoBreak and Player<userId>NoBreak for the asking player; an empty
cell is breakable. calculateBlockDamage is 2, or the held tool's breakBlock figure for the block's
breakType, then game-block-engine's own changes (Axolotl speed, snow cone stacks, host-only and
owner-only blocks, bed shields); kit listeners (Berserker rage, Jailor souls) and bed plating are
not seen, so the figure is the plain one for those. Client placement refuses an unknown type, a cell
inside your head, your own body's column and other players' feet cells. Server placement is the half
the server repeats: cells free or CanReplace, not on a denied block type, supported where the block
needs it, not on a prefab where that is denied; the server's own placement listeners may still
refuse. ]]
function knitless.newBlockEngine(ctx, store, registry, itemMeta)
	local players = ctx.services.Players
	local workspace = ctx.services.Workspace
	local replicatedStorage = ctx.services.ReplicatedStorage
	local okBalance, balance = pcall(ctx.data, 'BalanceFile')
	balance = okBalance and type(balance) == 'table' and balance or {}

	local animations = {animationMap = {[0] = 'rbxassetid://4866397461', [1] = 'rbxassetid://6322507715'}}
	function animations:getAssetId(id)
		return self.animationMap[id]
	end
	function animations:setAssetId(id, asset)
		self.animationMap[id] = asset
	end

	local engine = {store = store, handlerRegistry = registry, animationController = animations}

	function engine:getStore()
		return self.store
	end

	function engine:getHandlerRegistry()
		return self.handlerRegistry
	end

	function engine:getAnimationController()
		return self.animationController
	end

	function engine:getSourceBlocksFolder()
		local assets = replicatedStorage:FindFirstChild('Assets')
		return assets and assets:FindFirstChild('Blocks')
	end

	function engine:getBlockPosition(position)
		return knitless.blockCell(position)
	end

	function engine:getWorldPosition(cell)
		return cell * 3
	end

	function engine:snapPosition(position)
		return knitless.blockKey(position)
	end

	function engine:snapBlockRotation(degrees)
		return knitless.snapBlockRotation(degrees)
	end

	function engine:getCharacter(player)
		local override = player:FindFirstChild('BlockEngineCharacter')
		local model = override and override:IsA('ObjectValue') and override.Value
		if model and model:IsA('Model') and model.Parent then
			return model
		end
		return player.Character
	end

	function engine:distanceFromCharacter(player, position)
		local character = self:getCharacter(player)
		if character ~= nil and character ~= player.Character then
			local head = character:FindFirstChild('Head')
			local from = if head and head:IsA('BasePart') then head.Position else character:GetPivot().Position
			return (from - position).Magnitude
		end
		return player:DistanceFromCharacter(position)
	end

	function engine:getBlockInstanceFromChild(instance)
		while instance do
			if instance:GetAttribute('Block') == true then
				return instance
			end
			instance = instance.Parent
		end
		return nil
	end

	function engine:isBlockBreakable(blockRef, player)
		local block = self.store:getBlockAt(blockRef.blockPosition)
		if not block then return true end
		if block:GetAttribute('NoBreak') == true then return false end
		if player then
			local team = player:GetAttribute('Team')
			if team ~= nil and team ~= '' and block:GetAttribute('Team'..tostring(team)..'NoBreak') == true then
				return false
			end
			if block:GetAttribute('Player'..tostring(player.UserId)..'NoBreak') == true then
				return false
			end
		end
		return true
	end

	function engine:calculateBlockDamage(player, blockRef)
		local character = player.Character
		if not character then return 0 end
		local damage = 2
		local block = self.store:getBlockAt(blockRef.blockPosition)
		local blockItem = block and itemMeta[block.Name]
		local blockMeta = blockItem and blockItem.block
		local hand = character:FindFirstChild('HandInvItem')
		local tool = hand and hand:IsA('ObjectValue') and hand.Value
		if tool and blockMeta and blockMeta.breakType then
			local toolMeta = itemMeta[tool.Name]
			local figure = toolMeta and toolMeta.breakBlock and toolMeta.breakBlock[blockMeta.breakType]
			if figure ~= nil then
				damage = figure
			end
		end
		local axolotl = balance.AXOLOTL
		if character:GetAttribute('AxolotlBreakSpeed') == true and axolotl and axolotl.AXOLOTL_BREAK_SPEED_MULT then
			damage *= axolotl.AXOLOTL_BREAK_SPEED_MULT
		end
		local stacks = 0
		if character:GetAttribute('StatusEffect_snow_cone') ~= nil then
			stacks = tonumber(character:GetAttribute('StatusEffect_snow_cone_stacks')) or 0
		end
		if balance.SNOW_CONE_BLOCK_COST and stacks >= balance.SNOW_CONE_BLOCK_COST then
			damage *= (balance.SNOW_CONE_BLOCK_BASE_DMG or 1) + (balance.SNOW_CONE_BLOCK_STACK_BONUS or 0) * stacks
		end
		if block then
			if blockMeta and blockMeta.breakableOnlyByHosts then
				local role = player:GetAttribute('CustomMatchRole')
				if role ~= 'host' and role ~= 'cohost' then return 0 end
			end
			if blockMeta and blockMeta.breakableOnlyByOwner and block:GetAttribute('PlacedByUserId') ~= player.UserId then
				return 0
			end
			local shield = block:GetAttribute('BedShieldEndTime')
			if type(shield) == 'number' and shield ~= 0 and shield == shield and workspace:GetServerTimeNow() < shield then
				return 0
			end
		end
		return damage
	end

	function engine:isClientAllowedPlacement(player, blockType, cell, rotation)
		local handler = self.handlerRegistry:getHandler(blockType)
		if not handler then return false end
		local character = self:getCharacter(player)
		local head = character and character:FindFirstChild('Head')
		if head then
			local overlap = OverlapParams.new()
			overlap.FilterType = Enum.RaycastFilterType.Include
			overlap.FilterDescendantsInstances = {head}
			overlap.MaxParts = 1
			for _, position in handler:getPlacementPositions(cell, rotation or 0) do
				if #workspace:GetPartBoundsInBox(CFrame.new(position * 3), Vector3.new(3, 3, 3), overlap) > 0 then
					return false
				end
			end
		end
		if not character then return false end
		local humanoid = character:FindFirstChildOfClass('Humanoid')
		if not humanoid then return false end
		local feet = self:getBlockPosition(character:GetPivot().Position - Vector3.new(0, humanoid.HipHeight / 2, 0))
		local scale = humanoid:GetAttribute('BodyHeightScaleOverride')
		if scale == nil then
			local value = humanoid:FindFirstChild('BodyHeightScale')
			scale = value and value.Value or 1
		end
		local height = math.round(scale * 2)
		local overhead = self.store:getBlockAt(feet + Vector3.new(0, height, 0))
		if height > 1 and cell.X == feet.X and cell.Z == feet.Z
			and feet.Y + (if overhead then 0 else 1) <= cell.Y and cell.Y <= feet.Y + height - 1 then
			return false
		end
		for _, other in players:GetPlayers() do
			if other ~= player then
				local bodies = {other.Character}
				local acting = self:getCharacter(other)
				if acting and acting ~= other.Character then
					table.insert(bodies, acting)
				end
				for _, body in bodies do
					local otherHumanoid = body:FindFirstChildOfClass('Humanoid')
					if otherHumanoid then
						local otherFeet = self:getBlockPosition(body:GetPivot().Position - Vector3.new(0, otherHumanoid.HipHeight / 2, 0))
						local depth = otherHumanoid:FindFirstChild('BodyDepthScale')
						for step = 0, math.round((depth and depth.Value or 1) * 2) - 1 do
							if cell == otherFeet + Vector3.new(0, step, 0) then
								return false
							end
						end
					end
				end
			end
		end
		return true
	end

	function engine:isServerAllowedPlacement(blockType, cell, rotation, mouseInfo)
		local handler = self.handlerRegistry:getHandler(blockType)
		if not handler then return false end
		for _, position in handler:getPlacementPositions(cell, rotation or 0) do
			local occupant = self.store:getBlockAt(position)
			if occupant and occupant:GetAttribute('CanReplace') ~= true then
				return false
			end
		end
		local meta = handler:getBlockMeta()
		local target = mouseInfo and mouseInfo.target
		local targetName = target and target.blockInstance and target.blockInstance.Name
		if targetName and targetName ~= '' and type(meta.denyPlaceOnBlockTypes) == 'table'
			and table.find(meta.denyPlaceOnBlockTypes, targetName) ~= nil then
			return false
		end
		local below = self.store:getBlockAt(cell - Vector3.new(0, 1, 0))
		if meta.requiresSupportingBlock and not below then
			return false
		end
		if meta.denyPlacingOnPrefabBlocks and below then
			local belowHandler = self.handlerRegistry:getHandler(below.Name)
			if belowHandler and belowHandler.kind == 'prefab' then
				return false
			end
		end
		return true
	end

	function engine:isAllowedPlacement(player, blockType, cell, rotation, mouseInfo)
		rotation = rotation or 0
		if not self:isClientAllowedPlacement(player, blockType, cell, rotation, mouseInfo) then
			return false
		end
		return self:isServerAllowedPlacement(blockType, cell, rotation, mouseInfo)
	end

	return engine
end

--[[ BlockSelector.getMouseInfo(mode, {ray, range, searchOutward, allowVoidSave}): mode 0 places, 1
selects. A block under the ray within range gives its cell and the cell beside the hit face. Placing
with nothing there bridges off the block under you, as the game does: a flat invisible plate through
the supporting layer catches the ray, and the walk goes from the support towards that point half a
cell at a time until it leaves the blocks. Parts tagged block:no-collision or marked
gamecore_GameQueryIgnore are passed through, and in place mode those marked
BlockEngine_Select_IgnorePlaceMode too. ]]
function knitless.newBlockSelector(ctx, engine)
	local players = ctx.services.Players
	local workspace = ctx.services.Workspace
	local collectionService = ctx.services.CollectionService
	local lplr = ctx.lplr
	local okMouse, mouse = pcall(function()
		return lplr:GetMouse()
	end)
	local around = {
		Vector3.new(1, 0, 0), Vector3.new(-1, 0, 0), Vector3.new(0, 0, 1), Vector3.new(0, 0, -1),
		Vector3.new(1, 0, 1), Vector3.new(-1, 0, -1), Vector3.new(-1, 0, 1), Vector3.new(1, 0, -1)
	}

	local function skipped(part, mode)
		return collectionService:HasTag(part, 'block:no-collision')
			or (part:IsA('BasePart') and part:GetAttribute('gamecore_GameQueryIgnore') == true)
			or (mode == 0 and part:GetAttribute('BlockEngine_Select_IgnorePlaceMode') == true)
	end

	local function cast(ray, range, params, mode)
		local direction = ray.Direction * (range * 3.5)
		local result = workspace:Raycast(ray.Origin, direction, params)
		for _ = 1, 64 do
			if not (result and skipped(result.Instance, mode)) then break end
			local filter = params.FilterDescendantsInstances
			table.insert(filter, result.Instance)
			params.FilterDescendantsInstances = filter
			result = workspace:Raycast(ray.Origin, direction, params)
		end
		return result
	end

	local selector = {mouse = okMouse and mouse or nil}

	function selector:getMouseInfo(mode, options)
		options = options or {}
		local store = engine:getStore()
		local character = engine:getCharacter(lplr)
		local primary = character and character.PrimaryPart
		if not primary then return nil end
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = {character}
		local ray = options.ray or (self.mouse and self.mouse.UnitRay)
		if not ray then return nil end
		local range = options.range
		if range == 0 or range ~= range or not range then
			range = 18
		end
		local origin = primary.Position
		local hit = cast(ray, range, params, mode)

		if hit and hit.Instance:IsA('BasePart') and options.searchOutward ~= true and (hit.Position - origin).Magnitude <= range then
			local block = engine:getBlockInstanceFromChild(hit.Instance)
			if block then
				local handler = engine:getHandlerRegistry():getHandler(block.Name)
				local meta = handler and handler:getBlockMeta()
				if mode == 0 and meta and meta.denyPlaceOn then return nil end
				local inside = hit.Position - hit.Normal * 0.1
				local cell
				if handler and not handler:isGreedy(block) then
					local scaled = inside / 3
					for _, candidate in handler:getContainedPositions(block) do
						if (candidate - scaled).Magnitude < (if cell then (cell - scaled).Magnitude else math.huge) then
							cell = candidate
						end
					end
				end
				cell = cell or knitless.blockCell(inside)
				return {
					target = {
						blockInstance = block,
						blockRef = {blockPosition = cell},
						hitPosition = hit.Position,
						hitNormal = hit.Normal
					},
					placementPosition = cell + hit.Normal.Unit
				}
			end
		end
		if mode ~= 0 then return nil end

		local normal = workspace:GetAttribute('WorldNormal') or Vector3.new(0, 1, 0)
		local support
		for depth = 1, 3 do
			local cell = engine:getBlockPosition(origin - normal * 3 * depth)
			if store:getBlockAt(cell) then
				support = cell
				break
			end
		end
		if not support then
			if options.allowVoidSave then
				for depth = 1, 3 do
					local cell = engine:getBlockPosition(origin - normal * 3 * depth)
					for _, offset in around do
						if store:getBlockAt(cell + offset) ~= nil then
							return {placementPosition = cell}
						end
					end
				end
			end
			return nil
		end

		local plate = Instance.new('Part')
		plate.Size = Vector3.new(90, 3, 90)
		plate.CFrame = CFrame.new(support * 3) * CFrame.Angles(normal.Z, 0, normal.X)
		plate.Anchored = true
		plate.Transparency = 1
		plate.CanCollide = false
		plate.Parent = workspace
		local bodies = {}
		for _, player in players:GetPlayers() do
			if player.Character then
				table.insert(bodies, player.Character)
			end
			local acting = engine:getCharacter(player)
			if acting and acting ~= player.Character then
				table.insert(bodies, acting)
			end
		end
		params.FilterDescendantsInstances = bodies
		if options.searchOutward then
			params.FilterDescendantsInstances = {plate}
			params.FilterType = Enum.RaycastFilterType.Include
		end
		hit = cast(ray, range, params, mode)
		plate:Destroy()
		if hit and hit.Instance == plate then
			local aim = engine:getBlockPosition(engine:snapPosition(hit.Position - normal * 1.5))
			local walk = support
			if store:getBlockAt(walk) then
				for _ = 1, 20 do
					local gap = aim - walk
					local length = gap.Magnitude
					walk += (if length == 0 or length ~= length then gap else gap.Unit) / 2
					if not store:getBlockAt(engine:snapPosition(walk)) then break end
				end
			end
			local cell = engine:snapPosition(walk)
			if store:getBlockAt(cell) == nil then
				return {placementPosition = cell}
			end
		end
		return nil
	end

	return selector
end

--[[ Builds the place sound of block-placement-audio-controller's playPlaceAudio(blockRef, blockType):
one of the block's place sounds at its world position, only within 50 studs of your character. The
server sends you everyone else's placements but never your own, so for a block this layer places
nothing else plays it. The data file cannot carry item meta's createPlaceAudioPlayers, so the blocks
whose sounds differ from GENERIC_BLOCK_PLACE are listed here from item-meta. Names resolve through
GameSound (a failed read is tried again on the next placement) and play through the AudioManager
stand-in. ]]
function knitless.newPlaceAudio(ctx, engine)
	local stone = {'STONE_BREAK'}
	local crop = {'CROP_PLANT_1', 'CROP_PLANT_2', 'CROP_PLANT_3'}
	local snow = {'SNOW_FOOTSTEP_1', 'SNOW_FOOTSTEP_2', 'SNOW_FOOTSTEP_3', 'SNOW_FOOTSTEP_4'}
	local egg = {'CHICKEN_EGG_CRACK'}
	local sounds = {
		snow = snow, snow_pile = snow, chicken_egg_block = egg, egg_block = egg,
		cursed_coffin = {'CURSED_COFFIN_PLACE'}, slime_block = {'SLIME_BLOCK_PLACE'},
		magic_glass = {'MAGIC_GLASS_PLACE_1', 'MAGIC_GLASS_PLACE_2', 'MAGIC_GLASS_PLACE_3'},
		pinata = {'PINATA_HIT_1', 'PINATA_HIT_2', 'PINATA_HIT_3'}
	}
	for _, blockType in {'andesite', 'andesite_polished', 'big_gargoyle_statue', 'brick', 'ceramic', 'clay', 'clay_black',
		'clay_blue', 'clay_dark_brown', 'clay_dark_green', 'clay_gray', 'clay_green', 'clay_light_brown', 'clay_light_green',
		'clay_orange', 'clay_pink', 'clay_purple', 'clay_red', 'clay_tan', 'clay_white', 'clay_yellow', 'concrete_green',
		'cotton_candy_machine', 'damage_banner', 'defense_banner', 'diorite', 'diorite_polished', 'gargoyle_statue',
		'gargoyle_statue_breaker', 'gargoyle_statue_fighter', 'gargoyle_statue_swift', 'granite', 'granite_polished', 'gravel',
		'halloween_crystal_block', 'heal_banner', 'ice', 'ice_bricks', 'iron_ore_mesh_block', 'marble', 'marble_pillar',
		'pirate_flag', 'red_sand', 'red_sandstone', 'red_sandstone_polished', 'red_sandstone_smooth', 'sacrophagus', 'sand',
		'sandstone', 'sandstone_polished', 'sandstone_smooth', 'slate_brick', 'slate_tiles', 'teleport_block', 'tuff_bricks',
		'void_teleport_portal'} do
		sounds[blockType] = stone
	end
	for _, blockType in {'carrot', 'crystalheart_flower', 'melon', 'pumpkin', 'soulvine_flower', 'tearbloom_flower'} do
		sounds[blockType] = crop
	end
	local fallback = {'GENERIC_BLOCK_PLACE'}
	local assets

	return function(blockRef, blockType)
		local cell = type(blockRef) == 'table' and blockRef.blockPosition
		if typeof(cell) ~= 'Vector3' or type(blockType) ~= 'string' then return end
		local position = engine:getWorldPosition(cell)
		if engine:distanceFromCharacter(ctx.lplr, position) >= 50 then return end
		if not assets then
			local ok, data = pcall(ctx.data, 'GameSound')
			if ok and type(data) == 'table' then assets = data end
		end
		local core = ctx.modules['ReplicatedStorage.rbxts_include.node_modules.@easy-games.game-core.out']
		local audio = type(core) == 'table' and core.AudioManager
		if not (assets and type(audio) == 'table' and type(audio.playAudio) == 'function') then return end
		local list = sounds[blockType] or fallback
		local asset = assets[list[math.random(#list)]]
		if type(asset) == 'string' then
			audio:playAudio(asset, {position = position})
		end
	end
end

--[[ The BlockPlacer class of the knitless layer: the game's placer without its animation (the place
sound is newPlaceAudio's). placeBlock(cell, mouseInfo) runs the game's checks and pace, then sends
PlaceBlock {blockType, position, mouseBlockInfo?} through the block-engine client, exactly the keys
of the game's strict interface, and returns nothing, as the game's does. blockData is the game's
client place event's to set and stays out.

clearToPlace stands in for the game's client place-event listeners: BlockCpsController's pace at
BLOCK_PLACE_CPS (a placement less than half an interval early waits its turn, an earlier one is
dropped, and the latest waiter wins), then MapController's deny regions and map bounds. Kit
listeners (smoke, wall builder, gargoyle) are not seen. The bridge lift is AUTOBRIDGE_Y_OFFSET,
which block-placer registers through ConstantManager.

For the plain one-cell blocks (the greedy handlers: wool, clay, wood, stone, glass, which is what
bridging places) a copy holds the cell in the store until the server answers, as the game's own copy
does. Prefab blocks (traps, banners, cannons, beds) get none, as nothing is built off them, and
neither does a cell something already stands in; without the data file no handler is known to be
greedy and nothing is held. HOLD_LIMIT only stops a lost answer from holding a cell for good (the
game's copy waits however long it takes); HOLD_SETTLE keeps the cell after a yes until the server's
part takes it.

The request is sent and answered in the caller's thread, as the game's is (its TS.try is a plain
xpcall): the bed and wall builders count their requests until it returns, and traps, banners and the
cannon look for the block after it. Scaffold and the other callers that must not wait call it from a
thread of their own. The type is read once, at the call, so a caller switching blockType during the
pace wait does not change what is sent. The place sound plays before the server answers, as the
game's does once its local placement is in, so prefabs get it too.

autoBridge does nothing when a block is just ahead, places straight down onto the column under you
when you look more than 65 degrees down, and otherwise uses the selector's outward search along your
move direction tipped 15 degrees down. enable binds nothing: the game's own placer already answers
clicks and taps. In developer mode count logs one line per 2 s of placing. ]]
function knitless.newBlockPlacerClass(ctx, engine)
	local lplr = ctx.lplr
	local players = ctx.services.Players
	local workspace = ctx.services.Workspace
	local replicatedStorage = ctx.services.ReplicatedStorage
	local paceFallback = {lastPlaceTimestamp = 0}
	local playPlaceAudio = knitless.newPlaceAudio(ctx, engine)
	local underfoot = {
		Vector3.new(1, 0, 0), Vector3.new(-1, 0, 0), Vector3.new(0, 0, 1), Vector3.new(0, 0, -1),
		Vector3.new(1, 0, 1), Vector3.new(-1, 0, -1), Vector3.new(-1, 0, 1), Vector3.new(1, 0, -1),
		Vector3.new(0, -1, 0)
	}

	local function placeRate()
		local constants = ctx.modules['ReplicatedStorage.TS.shared-constants']
		local cps = type(constants) == 'table' and type(constants.CpsConstants) == 'table'
			and tonumber(constants.CpsConstants.BLOCK_PLACE_CPS)
		return if cps and cps > 0 then cps else 12
	end

	local function bridgeLift()
		local ok, value = pcall(function()
			local module = replicatedStorage.rbxts_include.node_modules['@easy-games']['block-engine'].out.client.placement['block-placer']
			return module:GetAttribute('ConstantManager_AUTOBRIDGE_Y_OFFSET')
		end)
		return ok and tonumber(value) or 3
	end

	local function clearToPlace(cell)
		local controllers = ctx.controllers or {}
		local pace = controllers.BlockCpsController or paceFallback
		local interval = 1 / placeRate()
		local remaining = interval - (workspace:GetServerTimeNow() - (tonumber(pace.lastPlaceTimestamp) or 0))
		local ticket
		if remaining > 0 then
			if remaining >= interval * 0.5 then return false end
			ticket = {}
			pace.pendingPlacement = ticket
			task.wait(remaining)
		end
		local map = controllers.MapController
		if map then
			local ok, denied = pcall(function()
				return map:isInDenyRegion(cell) or map:isOutOfBounds(cell)
			end)
			if ok and denied then return false end
		end
		if ticket and pace.pendingPlacement ~= ticket then return false end
		pace.lastPlaceTimestamp = workspace:GetServerTimeNow()
		pace.pendingPlacement = nil
		return true
	end

	local HOLD_LIMIT, HOLD_SETTLE = 3, 0.5

	local function holdCell(blockType, cell)
		local store = engine:getStore()
		local handler = engine:getHandlerRegistry():getHandler(blockType)
		if not (handler and handler.kind == 'greedy' and type(store.hold) == 'function') then return nil end
		if store:getBlockAt(cell) ~= nil then return nil end
		local ok, part = pcall(handler.place, handler, cell)
		if not (ok and typeof(part) == 'Instance') then return nil end
		part:SetAttribute('Block', true)
		part:SetAttribute('ClientPlaced', true)
		part:SetAttribute('PlacedByUserId', lplr.UserId)
		if store:hold(cell, part) then
			return part
		end
		part:Destroy()
		return nil
	end

	local stats
	local function count(field, value)
		if shared.PistonwareDeveloper ~= true then return end
		local now = os.clock()
		if not stats then
			stats = {since = now, sent = 0, placed = 0, refused = 0, failed = 0, held = 0, paced = 0, taken = 0, answers = {}}
		end
		if field == 'answer' then
			table.insert(stats.answers, value)
		elseif field then
			stats[field] += value or 1
		end
		local span = now - stats.since
		if span < 2 or not (field == 'placed' or field == 'refused' or field == 'failed') then return end
		local answers = stats.answers
		table.sort(answers)
		local median = answers[math.max(1, math.ceil(#answers / 2))]
		ctx.log(string.format('blocks: %.1f s: %d PlaceBlock sent (%.1f/s), %d placed, %d turned down, %d failed;'
			..' answers in %s ms (%s-%s); %d held a copy; %d dropped by the pace or a deny region, %d on a taken cell',
			span, stats.sent, stats.sent / span, stats.placed, stats.refused, stats.failed,
			median and tostring(math.floor(median)) or '-', answers[1] and tostring(math.floor(answers[1])) or '-',
			answers[#answers] and tostring(math.floor(answers[#answers])) or '-', stats.held, stats.paced, stats.taken))
		stats = nil
	end

	local BlockPlacer = {}
	BlockPlacer.__index = BlockPlacer

	function BlockPlacer.new(clientManager, blockType)
		return setmetatable({clientManager = clientManager, blockType = blockType}, BlockPlacer)
	end

	function BlockPlacer:placeBlock(cell, mouseInfo)
		local blockType = self.blockType
		if type(blockType) ~= 'string' or typeof(cell) ~= 'Vector3' then return nil end
		if not engine:isAllowedPlacement(lplr, blockType, cell, 0, mouseInfo) then
			count('taken')
			return nil
		end
		if not clearToPlace(cell) or lplr:GetAttribute('DenyBlockPlace') == true then
			count('paced')
			return nil
		end
		local payload = {blockType = blockType, position = cell}
		if type(mouseInfo) == 'table' then
			local target = mouseInfo.target
			payload.mouseBlockInfo = {
				target = if target then {
					blockRef = target.blockRef,
					hitPosition = target.hitPosition,
					hitNormal = target.hitNormal
				} else nil,
				placementPosition = mouseInfo.placementPosition
			}
		end
		count('sent')
		local copy = holdCell(blockType, cell)
		pcall(playPlaceAudio, {blockPosition = cell}, blockType)
		if copy then
			count('held')
			task.delay(HOLD_LIMIT, function()
				engine:getStore():letGo(copy)
			end)
		end
		local sentAt = os.clock()
		local ok, result = pcall(function()
			return ctx.blockNet:Get('PlaceBlock'):CallServer(payload)
		end)
		if copy then
			local store = engine:getStore()
			if ok and result and store:getBlockAt(cell) == copy then
				task.delay(HOLD_SETTLE, function()
					store:letGo(copy)
				end)
			else
				store:letGo(copy)
			end
		end
		if not ok then
			ctx.log('blocks: PlaceBlock failed: '..tostring(result))
		end
		count('answer', (os.clock() - sentAt) * 1000)
		count(not ok and 'failed' or result and 'placed' or 'refused')
		return nil
	end

	function BlockPlacer:autoBridge(allowVoidSave)
		if allowVoidSave == nil then
			allowVoidSave = true
		end
		local character = engine:getCharacter(lplr)
		local primary = character and character.PrimaryPart
		if not primary then return nil end
		local humanoid = character:FindFirstChild('Humanoid')
		local move = ((humanoid and humanoid.MoveDirection) or Vector3.zero) * Vector3.new(1, 0, 1)
		local facing = if move.Magnitude == 0 then primary.CFrame else CFrame.new(Vector3.zero, move)
		local look = (facing * CFrame.Angles(-math.rad(15), 0, 0)).LookVector
		local start = primary.CFrame.Position + Vector3.new(0, bridgeLift(), 0)
		local params = RaycastParams.new()
		params.CollisionGroup = 'Blocks'
		params.FilterType = Enum.RaycastFilterType.Exclude
		local bodies = {}
		for _, player in players:GetPlayers() do
			if player.Character then
				table.insert(bodies, player.Character)
			end
			local acting = engine:getCharacter(player)
			if acting and acting ~= player.Character then
				table.insert(bodies, acting)
			end
		end
		params.FilterDescendantsInstances = bodies
		local ahead = workspace:Raycast(start, look, params)
		for _ = 1, 32 do
			if not (ahead and ahead.Instance:IsA('BasePart') and ahead.Instance:GetAttribute('gamecore_GameQueryIgnore') == true) then break end
			params:AddToFilter(ahead.Instance)
			ahead = workspace:Raycast(start, look, params)
		end
		if ahead and engine:getBlockInstanceFromChild(ahead.Instance) then return nil end
		local camera = workspace.CurrentCamera
		if camera and math.deg((camera.CFrame:ToOrientation())) < -65 then
			local position = primary.Position
			for depth = 0, 3 do
				local cell = engine:getBlockPosition(position - Vector3.new(0, 3, 0) * depth)
				for _, offset in underfoot do
					if engine:getStore():getBlockAt(cell + offset) ~= nil then
						self:placeBlock(cell)
						return nil
					end
				end
			end
		end
		local info = self.clientManager:getBlockSelector():getMouseInfo(0, {
			searchOutward = true,
			ray = Ray.new(start, look),
			allowVoidSave = allowVoidSave
		})
		if info then
			self:placeBlock(info.placementPosition, info)
		end
		return nil
	end

	function BlockPlacer:enable() end

	function BlockPlacer:disable() end

	function BlockPlacer:getBlockType()
		return self.blockType
	end

	return BlockPlacer
end

--[[ BuilderUtil.getFortificationCost: one {currency, amount} from the block's base shop entry (white
wool's for any wool), the price times 1.5 for blast-proof blocks or 2.25 otherwise, over the stack
size; nil when the shop has no entry. It reads the default ShopItems list, which is what
BedwarsShop.getShopItem(type, nil) answers outside a shop's own component. An unknown type errors,
as getItemMeta(type).block does in the game. ]]
function knitless.newBuilderUtil(ctx, itemMeta)
	local byType

	local function shopItem(itemType)
		if not byType then
			byType = {}
			local ok, items = pcall(ctx.data, 'ShopItems')
			if ok and type(items) == 'table' then
				for _, item in items do
					if type(item) == 'table' and item.itemType ~= nil then
						byType[item.itemType] = item
					end
				end
			end
		end
		return byType[itemType]
	end

	local util = {FORTIFY_RANGE = 18}

	function util.getFortificationCost(itemType)
		local meta = itemMeta[itemType]
		if type(meta) ~= 'table' then
			error('no item meta for '..tostring(itemType), 2)
		end
		local block = meta.block
		local item = shopItem(if block and block.wool then 'wool_white' else itemType)
		if not item then return nil end
		local price, amount = tonumber(item.price), tonumber(item.amount)
		if not (price and amount and amount > 0) then return nil end
		local factor = if block and block.blastProof then 1.5 else 2.25
		return {{currency = item.currency, amount = math.ceil(price * factor / amount)}}
	end

	return util
end

--[[ Fills the block-engine module paths the bootstrap requires and publishes the store, engine, client
engine and placer class on knitless for the other slices. clientEngine stands for the game's
IClientBlockEngine from PlayerScripts.TS.lib.block-engine; its placement audio controller plays
newPlaceAudio for any caller, and startBlockReplication does nothing because the store already
follows the block tag. ]]
function knitless.buildBlocks(ctx)
	local okMeta, itemMeta = pcall(ctx.data, 'ItemMeta')
	itemMeta = okMeta and type(itemMeta) == 'table' and itemMeta or nil
	if not itemMeta then
		ctx.log('blocks: no ItemMeta in the data file; block handlers are guessed from the blocks')
	end
	if not ctx.blockNet then
		ctx.log('blocks: the block-engine remotes folder is missing; PlaceBlock and DamageBlock are unavailable')
	end

	local registry = knitless.newBlockRegistry(ctx, itemMeta)
	local store = knitless.newBlockStore(ctx, registry)
	local engine = knitless.newBlockEngine(ctx, store, registry, itemMeta or {})
	local selector = knitless.newBlockSelector(ctx, engine)
	local blockPlacer = knitless.newBlockPlacerClass(ctx, engine)

	local clientEngine = {config = {}, blockSelector = selector}
	function clientEngine:getBlockSelector()
		return self.blockSelector
	end
	function clientEngine:getConfig()
		return self.config
	end
	local placeAudio = knitless.newPlaceAudio(ctx, engine)
	function clientEngine:getBlockPlacementAudioController()
		return {playPlaceAudio = function(_, blockRef, blockType)
			pcall(placeAudio, blockRef, blockType)
		end}
	end
	function clientEngine:startBlockReplication() end

	local remotes = {
		BlockEngineRemotes = {Client = ctx.blockNet},
		DamageBlockResponse = {FAILED = 'failed', DAMAGED = 'damaged', DESTROYED = 'destroyed', CANCELLED = 'cancelled'}
	}

	knitless.blockStore = store
	knitless.blockEngine = engine
	knitless.clientBlockEngine = clientEngine
	knitless.BlockPlacer = blockPlacer

	local base = 'ReplicatedStorage.rbxts_include.node_modules.@easy-games.block-engine.out'
	ctx.modules[base] = {BlockEngine = engine, BlockEngineRemotes = remotes.BlockEngineRemotes}
	ctx.modules[base..'.shared.remotes'] = remotes
	ctx.modules[base..'.client.placement.block-placer'] = {BlockPlacer = blockPlacer}
	ctx.modules['PlayerScripts.TS.lib.block-engine.client-block-engine'] = {ClientBlockEngine = clientEngine}
	ctx.modules['ReplicatedStorage.TS.games.bedwars.kit.kits.builder.builder-util'] = {
		BuilderUtil = knitless.newBuilderUtil(ctx, itemMeta or {})
	}
end

--[[ Controllers slice of the knitless layer: the stand-ins behind Knit.Controllers, Flamework's
resolver for the three controllers the bootstrap takes from it, and KnockbackUtil and
StatusEffectUtil. Each stand-in offers what the bootstrap, the loader's modules and the payload read,
with the game's signatures. They work from instances, attributes, tags and remotes only. The game's
own controllers keep running beside them and stay out of reach, so where a value lives only inside
one of those, the stand-in says what it does instead. ]]

--[[ The shared state every controller stand-in reads: services, the tables it needs from the data file,
and the animation ids it plays. ownTracks holds the tracks this file plays, so its own swings never
count as the player's. AbilityMeta is not in the current dump; the ability stand-in uses it when a
later dump carries it. animationIdByName lists the swing and use animations from prod-animations,
for when the registry's GameAnimationUtil does not know one. ]]
function knitless.ctrlShared(ctx)
	local services = ctx.services
	local h = {
		ctx = ctx,
		lplr = ctx.lplr,
		players = services.Players,
		workspace = services.Workspace,
		replicatedStorage = services.ReplicatedStorage,
		collection = services.CollectionService,
		inputService = services.UserInputService,
		tweenService = services.TweenService,
		debris = services.Debris,
		logged = {},
		ownTracks = setmetatable({}, {__mode = 'k'})
	}
	local function data(name)
		local ok, value = pcall(ctx.data, name)
		return ok and type(value) == 'table' and value or nil
	end
	h.animationType = data('AnimationType') or {}
	h.gameSound = data('GameSound') or {}
	h.kitMeta = knitless.ctrlExport(h, 'ReplicatedStorage.TS.games.bedwars.kit.bedwars-kit-meta', 'BedwarsKitMeta')
		or data('BedwarsKitMeta') or {}
	h.combatData = data('CombatConstant') or {RAYCAST_SWORD_CHARACTER_DISTANCE = 14.4, REGION_SWORD_CHARACTER_DISTANCE = 12.6}
	h.swordsData = data('SwordsConstants') or {swordSwingBufferMultiplier = 0.4}
	h.abilityMeta = data('AbilityMeta')

	h.animationIdByName = {
		SWORD_SWING = 'rbxassetid://4947108314',
		NEW_SWORD_SWING = 'rbxassetid://138277477587269',
		FP_SWING_SWORD = 'rbxassetid://8089691925',
		FP_USE_ITEM = 'rbxassetid://8089691925',
		NEW_SWORD_SWING_FP = 'rbxassetid://89650060348854',
		DAGGER_SWING_1 = 'rbxassetid://13836234644',
		DAGGER_SWING_2 = 'rbxassetid://13816190401',
		DAGGER_SWING_FP = 'rbxassetid://13816205964',
		DAGGER_SWING_2_FP = 'rbxassetid://13816207519',
		GREAT_HAMMER_SWING_1 = 'rbxassetid://13802346346',
		GREAT_HAMMER_SWING_2 = 'rbxassetid://13802354449',
		GREAT_HAMMER_SWING_1_FP = 'rbxassetid://13802501742',
		GREAT_HAMMER_SWING_2_FP = 'rbxassetid://13802503894',
		SCYTHE_SWING = 'rbxassetid://8479246017',
		SCYTHE_SLASH_1 = 'rbxassetid://13802531000',
		SCYTHE_SLASH_2 = 'rbxassetid://13816174473',
		SCYTHE_SLASH_1_FP = 'rbxassetid://13802569648',
		SCYTHE_SLASH_2_FP = 'rbxassetid://13816181777',
		TWIRLBLADE_ATTACK_1 = 'rbxassetid://8789340437',
		TWIRLBLADE_ATTACK_2 = 'rbxassetid://8789342166',
		FP_TWIRLBLADE_ATTACK_1 = 'rbxassetid://8795210389',
		FP_TWIRLBLADE_ATTACK_2 = 'rbxassetid://8795211816',
		BEAR_CLAWS_SWIPE = 'rbxassetid://9440191148',
		INFERNO_SWORD_SPIN = 'rbxassetid://9611595934',
		FP_INFERNO_SWORD_SPIN = 'rbxassetid://9611585335',
		FROSTY_HAMMER_1 = 'rbxassetid://11824356500',
		FROSTY_HAMMER_2 = 'rbxassetid://11824358904',
		FROSTY_HAMMER_3 = 'rbxassetid://11824362467',
		LASER_SWORD_SWING_1 = 'rbxassetid://11710365271',
		LASER_SWORD_SWING_2 = 'rbxassetid://11710363907',
		KNIGHT_SHIELD_THIRD_PERSON_BASH = 'rbxassetid://140300979233839'
	}
	h.animationIds = {}
	for name, id in h.animationIdByName do
		local number = h.animationType[name]
		if number ~= nil then
			h.animationIds[number] = id
		end
	end
	return h
end

--[[ ctx.modules[path][key], or nil. ]]
function knitless.ctrlExport(h, path, key)
	local module = h.ctx.modules[path]
	local value = type(module) == 'table' and module[key] or nil
	return value
end

--[[ One log line per distinct message, for anything that can repeat on every swing or frame. ]]
function knitless.ctrlLog(h, message)
	if h.logged[message] then return end
	h.logged[message] = true
	h.ctx.log('controllers: '..message)
end

--[[ Registers a stand-in, unless an earlier slice already made that controller. ]]
function knitless.ctrlPut(h, name, controller)
	local existing = h.ctx.controllers[name]
	if existing ~= nil then
		knitless.ctrlLog(h, name..' was already provided by another slice; kept that one')
		return existing
	end
	h.ctx.controllers[name] = controller
	return controller
end

--[[ The same, for a module export table. ]]
function knitless.ctrlModule(h, path, exports)
	if h.ctx.modules[path] ~= nil then
		knitless.ctrlLog(h, path..' was already provided by another slice; kept that one')
		return
	end
	h.ctx.modules[path] = exports
end

--[[ A controller whose methods pistonware swaps for a no-op to switch a game behaviour off
(deflateBalloon, addGameNametag). That swap never reaches the game's controller, so the swap itself
is what is watched: onSwap(key, replaced) runs each time a method in methods is set, replaced being
whether it is now something other than this file's own. Methods are served from a shadow table and
never stored on the controller, so every later assignment is seen as well. Other fields are stored
as usual. ]]
function knitless.ctrlWatched(fields, methods, onSwap)
	local shadow = {}
	return setmetatable(fields, {
		__index = function(_, key)
			local value = shadow[key]
			if value == nil then
				value = methods[key]
			end
			return value
		end,
		__newindex = function(self, key, value)
			if methods[key] == nil then
				rawset(self, key, value)
				return
			end
			shadow[key] = value
			onSwap(key, value ~= nil and value ~= methods[key])
		end
	})
end

--[[ The remotes client the scripts use (bedwars.Client), so sends from here pass through the
loader's Client.Get wrapper the way the game's own sends do on a full executor. ]]
function knitless.ctrlRemote(h, name)
	local remotes = h.ctx.modules['ReplicatedStorage.TS.remotes']
	local client = type(remotes) == 'table' and type(remotes.default) == 'table' and remotes.default.Client or h.ctx.net
	local ok, remote = pcall(client.Get, client, name)
	if ok and type(remote) == 'table' then
		return remote
	end
	knitless.ctrlLog(h, 'remote '..name..' is unavailable: '..tostring(remote))
	return nil
end

--[[ Listens to a server event of the main remotes folder, in a thread of its own because the
lookup can wait for the remote to replicate. ]]
function knitless.ctrlListen(h, name, callback)
	task.spawn(function()
		local ok, remote = pcall(h.ctx.net.Get, h.ctx.net, name)
		if not (ok and type(remote) == 'table') then
			knitless.ctrlLog(h, 'cannot listen to '..name..': '..tostring(remote))
			return
		end
		local connected, connection = pcall(remote.Connect, remote, function(...)
			local fine, err = pcall(callback, ...)
			if not fine then
				knitless.ctrlLog(h, name..' handler failed: '..tostring(err))
			end
		end)
		if connected then
			h.ctx.clean(connection)
		end
	end)
end

--[[ A RemoteEvent of a Flamework events folder (ReplicatedStorage['events-'..folder]), looked up
at the time of use: the folder can replicate late. ]]
function knitless.ctrlEventRemote(h, folderName, remoteName)
	local ok, folder = pcall(h.ctx.events, folderName)
	local remote = ok and typeof(folder) == 'Instance' and folder:FindFirstChild(remoteName) or nil
	if remote and remote:IsA('RemoteEvent') then
		return remote
	end
	knitless.ctrlLog(h, remoteName..' is not in events-'..folderName)
	return nil
end

--[[ A plain FireServer on a Flamework event, as the game's networking event sends it. ]]
function knitless.ctrlFire(h, folderName, remoteName, ...)
	local remote = knitless.ctrlEventRemote(h, folderName, remoteName)
	if not remote then return false end
	remote:FireServer(...)
	return true
end

--[[ Listens to a server event of a Flamework events folder once the folder is there. ]]
function knitless.ctrlListenFolder(h, folderName, remoteName, callback)
	task.spawn(function()
		local folder = h.replicatedStorage:WaitForChild('events-'..folderName, 60)
		local remote = folder and folder:WaitForChild(remoteName, 30)
		if not (remote and remote:IsA('RemoteEvent')) then
			knitless.ctrlLog(h, 'cannot listen to '..remoteName..' in events-'..folderName)
			return
		end
		h.ctx.clean(remote.OnClientEvent:Connect(function(...)
			local fine, err = pcall(callback, ...)
			if not fine then
				knitless.ctrlLog(h, remoteName..' handler failed: '..tostring(err))
			end
		end))
	end)
end

--[[ Runs callback(character, humanoid) for the current character and every one after, once its
Humanoid is there. The connections callback returns are dropped when the next character comes. ]]
function knitless.ctrlOnCharacter(h, callback)
	local current = {}
	local function drop()
		for _, connection in current do
			pcall(function()
				connection:Disconnect()
			end)
		end
		table.clear(current)
	end
	local function attach(character)
		drop()
		task.spawn(function()
			local humanoid = character:WaitForChild('Humanoid', 10)
			if not humanoid or h.lplr.Character ~= character then return end
			local ok, connections = pcall(callback, character, humanoid)
			if not ok then
				knitless.ctrlLog(h, 'character hook failed: '..tostring(connections))
			elseif type(connections) == 'table' and h.lplr.Character == character then
				for _, connection in connections do
					table.insert(current, connection)
				end
			end
		end)
	end
	h.ctx.clean(h.lplr.CharacterAdded:Connect(attach))
	h.ctx.clean(drop)
	if h.lplr.Character then
		attach(h.lplr.Character)
	end
end

--[[ The store stand-in's state, or nil before it exists. ]]
function knitless.ctrlState(h)
	local store = h.ctx.store
	if type(store) ~= 'table' or type(store.getState) ~= 'function' then return nil end
	local ok, state = pcall(store.getState, store)
	return ok and type(state) == 'table' and state or nil
end

--[[ Game.matchState: 0 before the match, 1 running, 2 over. ]]
function knitless.ctrlMatchState(h)
	local state = knitless.ctrlState(h)
	local game = state and state.Game
	return game and tonumber(game.matchState) or 0
end

--[[ item-meta for an item type, from the registry's table (the one bedwars.ItemMeta is). ]]
function knitless.ctrlItemMeta(h, itemType)
	if type(itemType) ~= 'string' then return nil end
	local items = knitless.ctrlExport(h, 'ReplicatedStorage.TS.item.item-meta', 'items')
	return type(items) == 'table' and items[itemType] or nil
end

--[[ CombatConstant, the table Reach rewrites, read at the time of use. ]]
function knitless.ctrlCombat(h)
	local constants = knitless.ctrlExport(h, 'ReplicatedStorage.TS.combat.combat-constant', 'CombatConstant')
	return type(constants) == 'table' and constants or h.combatData
end

--[[ The tool in your hand (Character.HandInvItem) and its item meta. ]]
function knitless.ctrlHand(h)
	local character = h.lplr.Character
	local holder = character and character:FindFirstChild('HandInvItem')
	local tool = holder and holder:IsA('ObjectValue') and holder.Value or nil
	if not tool then return nil, nil end
	return tool, knitless.ctrlItemMeta(h, tool.Name)
end

function knitless.ctrlAlive(model)
	local humanoid = model and model:FindFirstChildOfClass('Humanoid')
	return humanoid ~= nil and humanoid.Health > 0
end

--[[ The entity a part belongs to: a player's character or a model tagged 'entity'. ]]
function knitless.ctrlEntityOf(h, part)
	local node = part
	while node and node ~= h.workspace do
		if node:IsA('Model') and (h.collection:HasTag(node, 'entity') or h.players:GetPlayerFromCharacter(node)) then
			return node
		end
		node = node.Parent
	end
	return nil
end

--[[ Whether you may hit this entity: alive, not you, and on another team (the Team attribute of
its player, or of the model itself for a mob). ]]
function knitless.ctrlCanAttack(h, model)
	if not model or model == h.lplr.Character or not knitless.ctrlAlive(model) then return false end
	local player = h.players:GetPlayerFromCharacter(model)
	local team
	if player then
		team = player:GetAttribute('Team')
	else
		team = model:GetAttribute('Team')
	end
	return team == nil or team ~= h.lplr:GetAttribute('Team')
end

--[[ GameQueryUtil's raycast: parts the game marks gamecore_GameQueryIgnore are passed through. ]]
function knitless.ctrlQueryCast(h, origin, direction, exclude)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local list = table.clone(exclude)
	for _ = 1, 16 do
		params.FilterDescendantsInstances = list
		local hit = h.workspace:Raycast(origin, direction, params)
		if not hit or not (hit.Instance:IsA('BasePart') and hit.Instance:GetAttribute('gamecore_GameQueryIgnore') == true) then
			return hit
		end
		table.insert(list, hit.Instance)
	end
	return nil
end

--[[ CameraPerspectiveController's own test: 0 (first person) when the camera is within a stud of
its focus, else 1. ]]
function knitless.ctrlPerspective(h)
	local camera = h.workspace.CurrentCamera
	if camera and (camera.CFrame.Position - camera.Focus.Position).Magnitude <= 1 then
		return 0
	end
	return 1
end

--[[ An animation type's asset id: the registry's GameAnimationUtil first, then this file's list.
A string that already is an asset id passes through. ]]
function knitless.ctrlAssetId(h, animationType)
	if animationType == nil then return nil end
	if type(animationType) == 'string' and animationType:find('^rbxassetid://') then
		return animationType
	end
	local util = knitless.ctrlExport(h, 'ReplicatedStorage.TS.animation.animation-util', 'GameAnimationUtil')
	if type(util) == 'table' and type(util.getAssetId) == 'function' then
		local ok, id = pcall(util.getAssetId, util, animationType)
		if ok and type(id) == 'string' and id ~= '' then
			return id
		end
	end
	return h.animationIds[animationType] or h.animationIdByName[animationType]
end

--[[ Plays an asset on a model's Animator (a character or the viewmodel), as the game's controllers
do: Action priority unless told otherwise, gone once it ends. ]]
function knitless.ctrlPlayTrack(h, model, assetId, options)
	if typeof(model) ~= 'Instance' or type(assetId) ~= 'string' then return nil end
	local humanoid = model:FindFirstChildOfClass('Humanoid')
	local animator = humanoid and humanoid:FindFirstChildOfClass('Animator')
	if not animator then return nil end
	local animation = Instance.new('Animation')
	animation.AnimationId = assetId
	local ok, track = pcall(animator.LoadAnimation, animator, animation)
	if not (ok and track) then return nil end
	h.ownTracks[track] = true
	track.Looped = type(options) == 'table' and options.looped == true or false
	track.Priority = type(options) == 'table' and options.priority or Enum.AnimationPriority.Action
	if not (type(options) == 'table' and options.reuseAfterStop) then
		track.Ended:Once(function()
			track:Destroy()
		end)
	end
	track:Play()
	return track
end

--[[ A sound by asset id: through the registry's AudioManager when there is one, else a Sound on
the camera that removes itself. ]]
function knitless.ctrlPlaySound(h, assetId)
	if type(assetId) ~= 'string' or assetId == '' then return end
	local audio = knitless.ctrlExport(h, 'ReplicatedStorage.rbxts_include.node_modules.@easy-games.game-core.out', 'AudioManager')
	if type(audio) == 'table' and type(audio.playAudio) == 'function' then
		pcall(audio.playAudio, audio, assetId)
		return
	end
	local camera = h.workspace.CurrentCamera
	if not camera then return end
	local sound = Instance.new('Sound')
	sound.SoundId = assetId
	sound.Parent = camera
	sound:Play()
	h.debris:AddItem(sound, 5)
end

--[[ Whether an input is the Attack binding, from KeybindLoadController's keybinds. ]]
function knitless.ctrlIsAttackInput(h, input)
	local keyboard, gamepad = Enum.UserInputType.MouseButton1, Enum.KeyCode.ButtonR2
	pcall(function()
		local binds = h.ctx.controllers.KeybindLoadController.loadedKeybinds
		keyboard = binds.keyboard.controlActions.Attack or keyboard
		gamepad = binds.gamepad.controlActions.Attack or gamepad
	end)
	return input.UserInputType == keyboard or input.KeyCode == keyboard or input.KeyCode == gamepad
end

--[[ SwordController stand-in, after sword-controller: state, casting, cooldowns and targeting;
ctrlSwordSwing, ctrlSwordEffect and ctrlSwordStamps add the rest. The game's swing-disabled flag is
also flipped by kit controllers (elk, sorcerer, spirit gardener) this file cannot see; a cast
(IsCasting) is the part of it that shows on the player.

canSee wants a clear line from your feet to theirs, from five studs up to five studs up, or between
the two, in either direction, past anything tagged DontBlockSwordRaycast. getTargetInRegion answers
the model of the first entity you may hit in the box ahead of you, while the match runs. The game
asks for entities touching the box; here an entity counts when its PrimaryPart is inside it. ]]
function knitless.ctrlSword(h)
	local lplr, workspace = h.lplr, h.workspace
	local sword = {
		Name = 'SwordController',
		lastAttack = 0,
		lastSwing = 0,
		disableSwingState = false,
		holdAutoSwingDisabled = false,
		swingCounter = 0,
		lastChargedAttackTimeMap = {}
	}

	function sword:getHandItem()
		local tool = knitless.ctrlHand(h)
		return tool and {tool = tool, itemType = tool.Name, amount = tool:GetAttribute('Amount')} or nil
	end

	function sword:isRelevantItem(item)
		local meta = type(item) == 'table' and knitless.ctrlItemMeta(h, item.itemType) or nil
		return meta ~= nil and meta.sword ~= nil
	end

	function sword:getRemainingCastingTime()
		local casting = lplr:GetAttribute('IsCasting')
		if casting == true then return 0.3 end
		if type(casting) == 'number' and casting == casting and casting ~= 0 then
			return math.max(casting - workspace:GetServerTimeNow(), 0)
		end
		return 0
	end

	function sword:getSwordSwingDisabled()
		return self.disableSwingState or self:getRemainingCastingTime() > 0
	end

	function sword:toggleSwordSwing(disabled)
		self.disableSwingState = disabled
	end

	function sword:isClickingTooFast()
		if tick() - self.lastSwing < 1 / 9 then
			return true
		end
		self.lastSwing = tick()
		return false
	end

	function sword:getRemainingSwingCooldown(itemType)
		local meta = knitless.ctrlItemMeta(h, itemType)
		local data = meta and meta.sword
		if not data or self.lastAttack == 0 then return 0 end
		return math.max(self.lastAttack + (data.attackSpeed or 0) - workspace:GetServerTimeNow(), 0)
	end

	function sword:getRemainingChargeCooldown(itemType)
		local meta = knitless.ctrlItemMeta(h, itemType)
		local charged = meta and meta.sword and meta.sword.chargedAttack
		local last = self.lastChargedAttackTimeMap[itemType] or 0
		if not (charged and charged.attackCooldown) or last == 0 then return 0 end
		return math.max(last + charged.attackCooldown - workspace:GetServerTimeNow(), 0)
	end

	function sword:isOnChargeAttackCooldown(itemType)
		local meta = knitless.ctrlItemMeta(h, itemType)
		local charged = meta and meta.sword and meta.sword.chargedAttack
		if not charged then return false end
		if self:getRemainingCastingTime() > 0 then return true end
		if charged.attackCooldown == nil then return false end
		return self:getRemainingSwingCooldown(itemType) > 0 or self:getRemainingChargeCooldown(itemType) > 0
	end

	function sword:canSee(target)
		local character = lplr.Character
		if not (character and target) then return false end
		local function feet(model)
			local root = model.PrimaryPart
			if not root then return nil end
			local humanoid = model:FindFirstChildWhichIsA('Humanoid')
			return root.Position - Vector3.new(0, (humanoid and humanoid.HipHeight or 0) + root.Size.Y / 2, 0)
		end
		local from, to = feet(character), feet(target)
		if not (from and to) then return false end
		local humanoid = character:FindFirstChildWhichIsA('Humanoid')
		local scale = humanoid and humanoid:FindFirstChild('BodyHeightScale')
		local lift = Vector3.new(0, 5 * (scale and scale.Value or 1), 0)
		local ignore = {character, target}
		for _, part in h.collection:GetTagged('DontBlockSwordRaycast') do
			table.insert(ignore, part)
		end
		local function clear(a, b)
			return not (knitless.ctrlQueryCast(h, a, b - a, ignore) or knitless.ctrlQueryCast(h, b, a - b, ignore))
		end
		local fromTop, toTop = from + lift, to + lift
		return clear(from, to) or clear(fromTop, toTop) or clear((from + fromTop) / 2, (to + toTop) / 2)
	end

	function sword:getTargetInRegion(range)
		if knitless.ctrlMatchState(h) ~= 1 or type(range) ~= 'number' then return nil end
		local character = lplr.Character
		local root = character and character.PrimaryPart
		if not root then return nil end
		local humanoid = character:FindFirstChild('Humanoid')
		local height = math.max(3, humanoid and humanoid.HipHeight or 1.5)
		local center = root.Position + root.CFrame.LookVector.Unit * (range / 2)
		for _, model in h.collection:GetTagged('entity') do
			local part = model:IsA('Model') and model.PrimaryPart
			if part and model ~= character then
				local offset = part.Position - center
				if math.abs(offset.X) <= range / 2 and math.abs(offset.Y) <= height and math.abs(offset.Z) <= range / 2
					and (part.Position - root.Position).Magnitude <= range
					and knitless.ctrlCanAttack(h, model) and self:canSee(model) then
					return model
				end
			end
		end
		return nil
	end

	knitless.ctrlSwordSwing(h, sword)
	knitless.ctrlSwordEffect(h, sword)
	knitless.ctrlSwordStamps(h, sword)
	knitless.ctrlPut(h, 'SwordController', sword)
end

--[[ The swing as sword-controller sends it: SwordHit for a target, SwordSwingMiss for none.
attackEntity(targetModel, rayDirection, {chargeTime}, {playAnimation, playSound}) cancels a swing
inside the cooldown as the game's SwordSwing handler does: still animated for most swords, and
replayed when the cooldown ends soon enough. The cooldown bar is the game's UI and is left out.

swingSwordInRegion swings at whatever is in the box ahead; a weapon with multiHitCheckDurationSec
keeps looking for a target that long after a miss, as the game's does, here in a thread of its own.
A click casts a ray up to 200 studs from the mouse or a screen point; an entity it meets in reach
and in sight is hit, anything else falls back to the box ahead. Holding the button to repeat swings
is the game's own binding. ]]
function knitless.ctrlSwordSwing(h, sword)
	local lplr, workspace = h.lplr, h.workspace

	function sword:sendServerRequest(target, chargeRatio, options)
		if self.disableSwingState then return false end
		local character = lplr.Character
		local camera = workspace.CurrentCamera
		if not (character and character.PrimaryPart and camera and target) then return false end
		local tool = knitless.ctrlHand(h)
		if not tool then return false end
		local raycast
		if type(options) == 'table' and options.rayDirection then
			raycast = {cameraPosition = {value = camera.CFrame.Position}, cursorDirection = {value = options.rayDirection}}
		end
		local swingStart = type(options) == 'table' and options.swingStartTime or nil
		local remote = knitless.ctrlRemote(h, 'SwordHit')
		if not remote then return false end
		remote:SendToServer({
			weapon = tool,
			entityInstance = target,
			validate = {
				raycast = raycast,
				targetPosition = {value = target:GetPivot().Position},
				selfPosition = {value = character:GetPivot().Position}
			},
			chargedAttack = {chargeRatio = chargeRatio},
			timeSinceSwingStart = if swingStart and swingStart ~= 0 then workspace:GetServerTimeNow() - swingStart else nil
		})
		return true
	end

	function sword:attackEntity(target, direction, charge, effect)
		if self.disableSwingState or self:getRemainingCastingTime() > 0 then return false end
		local character = lplr.Character
		local root = character and character.PrimaryPart
		if not (root and workspace.CurrentCamera) then return false end
		local tool, meta = knitless.ctrlHand(h)
		local data = meta and meta.sword
		if not data then return false end
		local skin = tool:GetAttribute('ItemSkin')
		if skin == '' then skin = nil end
		if target then
			local targetRoot = target.PrimaryPart
			if not (target.Parent and targetRoot) then return false end
			local range = data.attackRange
			if not range or range == 0 then
				range = knitless.ctrlCombat(h).RAYCAST_SWORD_CHARACTER_DISTANCE or 14.4
			end
			if range + 2 <= (root.Position - targetRoot.Position).Magnitude then return false end
		end
		local ratio = 0
		local charged = data.chargedAttack
		local chargeTime = type(charge) == 'table' and charge.chargeTime or nil
		if charged and chargeTime and chargeTime ~= 0 then
			ratio = math.clamp(chargeTime / (charged.maxChargeTimeSec or 1), 0, 1)
		end

		local now = workspace:GetServerTimeNow()
		local speed = data.attackSpeed or 0
		local elapsed = now - self.lastAttack
		if elapsed < speed then
			if not data.respectAttackSpeedForEffects and not data.applyCooldownOnMiss and data.skipSwingEffects ~= true then
				self:playSwordEffect(meta, ratio >= 1, {itemSkin = skin})
			end
			local wait = (speed - elapsed) * 1.01
			local swords = knitless.ctrlExport(h, 'ReplicatedStorage.TS.combat.combat-constant', 'SwordsConstants')
			swords = type(swords) == 'table' and swords or h.swordsData
			local buffer = tonumber(swords.swordSwingBufferMultiplier) or 0.4
			if wait < math.min(speed * buffer, 0.2) and not self.bufferedSwing then
				self.bufferedSwing = true
				task.delay(wait, function()
					self.bufferedSwing = nil
					if target and self:attackEntity(target, direction, nil, {playAnimation = false, playSound = false}) then
						return
					end
					self:swingSwordInRegion()
				end)
			end
			return false
		end

		if not data.skipSwingEffects then
			self:playSwordEffect(meta, ratio >= 1, {
				playAnimation = type(effect) == 'table' and effect.playAnimation or nil,
				playSound = type(effect) == 'table' and effect.playSound or nil,
				itemSkin = skin
			})
		end
		if ratio == 1 then
			self.lastChargedAttackTimeMap[tool.Name] = now
		end
		if target then
			self.lastAttack = now
			self:sendServerRequest(target, ratio, {rayDirection = direction})
		else
			if data.applyCooldownOnMiss == true then
				self.lastAttack = now
			end
			local multiHit = data.multiHitCheckDurationSec
			if not multiHit or multiHit == 0 then
				local remote = knitless.ctrlRemote(h, 'SwordSwingMiss')
				if remote then
					remote:SendToServer({weapon = tool, chargeRatio = ratio})
				end
			end
		end
		return true
	end

	function sword:swingSwordInRegion(chargeTime)
		local _, meta = knitless.ctrlHand(h)
		local data = meta and meta.sword
		if not data then return nil end
		local mobile = h.inputService.TouchEnabled and not h.inputService.MouseEnabled
		local range = 3.8 * 3
		if data.attackRange and data.attackRange ~= 0 then
			range = data.attackRange
		elseif mobile then
			range = knitless.ctrlCombat(h).REGION_SWORD_CHARACTER_DISTANCE or range
		end
		local charge = if chargeTime and chargeTime ~= 0 then {chargeTime = chargeTime} else nil
		local target = self:getTargetInRegion(range, chargeTime)
		if not self:attackEntity(target, nil, charge) then return nil end
		local window = data.multiHitCheckDurationSec or 0
		if target or window == 0 then return nil end
		local started = workspace:GetServerTimeNow()
		local ratio = 0
		if data.chargedAttack and chargeTime and chargeTime ~= 0 then
			ratio = math.clamp(chargeTime / (data.chargedAttack.maxChargeTimeSec or 1), 0, 1)
		end
		task.spawn(function()
			local left = window
			for _ = 1, math.ceil(window / 0.1) do
				task.wait(math.min(0.1, left))
				left -= 0.1
				local found = self:getTargetInRegion(range, chargeTime)
				if found then
					self:sendServerRequest(found, ratio, {swingStartTime = started})
					return
				end
			end
		end)
		return nil
	end

	local function swingAlong(self, ray, chargeTime)
		local character = lplr.Character
		local root = character and character.PrimaryPart
		local tool, meta = knitless.ctrlHand(h)
		if not (tool and root and knitless.ctrlAlive(character)) then return nil end
		local data = meta and meta.sword
		local params = RaycastParams.new()
		params.FilterDescendantsInstances = {character}
		params.FilterType = Enum.RaycastFilterType.Exclude
		local hit = workspace:Raycast(ray.Origin, ray.Direction * 200, params)
		if hit then
			local range = data and data.attackRange
			if not range or range == 0 then
				range = knitless.ctrlCombat(h).RAYCAST_SWORD_CHARACTER_DISTANCE or 14.4
			end
			if (root.Position - hit.Instance.Position).Magnitude <= range then
				local target = knitless.ctrlEntityOf(h, hit.Instance)
				if target and knitless.ctrlCanAttack(h, target) and self:canSee(target) then
					self:attackEntity(target, ray.Direction, if chargeTime and chargeTime ~= 0 then {chargeTime = chargeTime} else nil)
					return nil
				end
			end
		end
		self:swingSwordInRegion(chargeTime)
		return nil
	end

	function sword:swingSwordAtMouse(chargeTime)
		if self:isClickingTooFast() then return nil end
		return swingAlong(self, lplr:GetMouse().UnitRay, chargeTime)
	end

	function sword:swingSwordAtViewportPoint(point)
		if self:isClickingTooFast() then return nil end
		local camera = workspace.CurrentCamera
		if not (camera and typeof(point) == 'Vector2') then return nil end
		return swingAlong(self, camera:ViewportPointToRay(point.X, point.Y))
	end

	function sword:mobileSwingPressed()
		if self.disableSwingState or self.holdAutoSwingDisabled then return nil end
		local casting = lplr:GetAttribute('IsCasting')
		if casting ~= nil and casting ~= false and casting ~= 0 and casting ~= '' then return nil end
		local camera = workspace.CurrentCamera
		if camera and knitless.ctrlPerspective(h) == 0 then
			self:swingSwordAtViewportPoint(camera.ViewportSize / 2)
			return nil
		end
		self:swingSwordAtMouse()
		return nil
	end

	function sword:enableHoldAutoSwing()
		self.holdAutoSwingDisabled = false
	end
	function sword:disableHoldAutoSwing()
		self.holdAutoSwingDisabled = true
	end
	function sword:stopHoldAutoSwing() end
	function sword:isHoldAutoSwingDisabled()
		return self.holdAutoSwingDisabled
	end
end

--[[ playSwordEffect(meta, charged, {itemSkin, playAnimation, playSound, character}): the swing on
the character, the first-person swing while ViewmodelController says it is visible (asked at the
time, so a script that hides it for one call is obeyed), and a swing sound, picked the way
sword-controller picks them. The trail and hit effects are the game's. ]]
function knitless.ctrlSwordEffect(h, sword)
	function sword:playSwordEffect(meta, charged, options)
		local data = type(meta) == 'table' and meta.sword or nil
		if not data then return nil end
		options = type(options) == 'table' and options or {}
		local types = h.animationType
		local third = data.swingAnimations or {types.SWORD_SWING}
		local first = data.firstPersonSwingAnimations or {types.FP_SWING_SWORD}
		local sounds = data.swingSounds or {h.gameSound.SWORD_SWING_1, h.gameSound.SWORD_SWING_2}
		if options.itemSkin then
			local getSkin = knitless.ctrlExport(h, 'ReplicatedStorage.TS.games.bedwars.item-skin.item-skin-meta', 'getItemSkinMeta')
			local ok, skin = pcall(getSkin, options.itemSkin)
			local skinSounds = ok and type(skin) == 'table' and skin.sword and skin.sword.swingSounds
			if skinSounds then
				sounds = skinSounds
			end
		end
		if charged then
			third, first = {types.NEW_SWORD_SWING}, {types.NEW_SWORD_SWING_FP}
		end
		local chargedMeta = data.chargedAttack
		if charged and chargedMeta then
			third = chargedMeta.chargedSwingAnimations or third
			first = chargedMeta.firstPersonChargedSwingAnimations or first
			sounds = chargedMeta.chargedSwingSounds or sounds
		end

		local _, held = knitless.ctrlHand(h)
		if not held then return nil end
		local heldCharge = held.sword and held.sword.chargedAttack
		if charged and heldCharge and heldCharge.ignoreEffectsOnFullyCharged == true then return nil end
		if data.swingAnimations and #data.swingAnimations == 0 then return nil end

		local function pick(list)
			if #list == 0 then return nil end
			if data.randomizeSwingAnimations then
				return list[math.random(1, #list)]
			end
			return list[math.min(self.swingCounter, #list - 1) + 1]
		end
		if options.playAnimation ~= false then
			local previous = self.thirdPersonSwingTrack
			if previous then
				pcall(previous.Stop, previous, 0)
			end
			self.thirdPersonSwingTrack = knitless.ctrlPlayTrack(h, options.character or h.lplr.Character,
				knitless.ctrlAssetId(h, pick(third)))
			local viewmodel = h.ctx.controllers.ViewmodelController
			local ok, visible = pcall(function()
				return viewmodel:isVisible()
			end)
			if ok and visible then
				pcall(viewmodel.playAnimation, viewmodel, pick(first))
			end
		end
		if self.swingCounter + 1 < #third then
			self.swingCounter += 1
		else
			self.swingCounter = 0
		end
		if #sounds > 0 and options.playSound ~= false then
			knitless.ctrlPlaySound(h, sounds[math.random(1, #sounds)])
		end
		return nil
	end
end

--[[ lastSwing and lastAttack for the swings the game makes for you, which never pass through this
stand-in. lastSwing moves on an Attack press with a sword in hand, on the 1/9 s rule of
isClickingTooFast, and on the game's own swing animations (held-button and touch swings). lastAttack
moves on a game swing the cooldown would let through with someone you may hit in reach: the game
moves it only when it sends a hit, which this cannot see. Swings this file plays are not counted. ]]
function knitless.ctrlSwordStamps(h, sword)
	local swingIds = {}
	for _, name in {
		'SWORD_SWING', 'NEW_SWORD_SWING', 'DAGGER_SWING_1', 'DAGGER_SWING_2', 'GREAT_HAMMER_SWING_1',
		'GREAT_HAMMER_SWING_2', 'SCYTHE_SWING', 'SCYTHE_SLASH_1', 'SCYTHE_SLASH_2', 'TWIRLBLADE_ATTACK_1',
		'TWIRLBLADE_ATTACK_2', 'BEAR_CLAWS_SWIPE', 'INFERNO_SWORD_SPIN', 'FROSTY_HAMMER_1', 'FROSTY_HAMMER_2',
		'FROSTY_HAMMER_3', 'LASER_SWORD_SWING_1', 'LASER_SWORD_SWING_2', 'KNIGHT_SHIELD_THIRD_PERSON_BASH'
	} do
		local id = h.animationIdByName[name]
		if id then
			swingIds[id] = true
		end
	end

	local function stampSwing()
		if tick() - sword.lastSwing >= 1 / 9 then
			sword.lastSwing = tick()
		end
	end

	h.ctx.clean(h.inputService.InputBegan:Connect(function(input, processed)
		if processed or not knitless.ctrlIsAttackInput(h, input) then return end
		local _, meta = knitless.ctrlHand(h)
		if not (meta and meta.sword) or sword.disableSwingState or sword:getRemainingCastingTime() > 0 then return end
		stampSwing()
	end))

	local function onTrack(track)
		if h.ownTracks[track] then return end
		local animation = track.Animation
		if not (animation and swingIds[animation.AnimationId]) then return end
		stampSwing()
		local _, meta = knitless.ctrlHand(h)
		local data = meta and meta.sword
		local character = h.lplr.Character
		local root = character and character.PrimaryPart
		if not (data and root) then return end
		local now = h.workspace:GetServerTimeNow()
		if now - sword.lastAttack < (data.attackSpeed or 0) then return end
		local range = data.attackRange
		if not range or range == 0 then
			range = knitless.ctrlCombat(h).RAYCAST_SWORD_CHARACTER_DISTANCE or 14.4
		end
		for _, model in h.collection:GetTagged('entity') do
			local part = model:IsA('Model') and model.PrimaryPart
			if part and model ~= character and (part.Position - root.Position).Magnitude < range + 2
				and knitless.ctrlCanAttack(h, model) then
				sword.lastAttack = now
				return
			end
		end
	end

	knitless.ctrlOnCharacter(h, function(_, humanoid)
		local animator = humanoid:WaitForChild('Animator', 10)
		if not animator then return nil end
		return {animator.AnimationPlayed:Connect(onTrack)}
	end)
end

--[[ CameraPerspectiveController, ViewmodelController, InventoryViewmodelController and FovController
stand-ins. The game caches the perspective every render step; here it is worked out when asked. The
viewmodel's isVisible and playAnimation are plain fields because Killaura swaps isVisible out for
one call and puts back what rawget gave it; setHeldItem and the crosshair belong to the game's
controller. The game redraws the held item from its own store, so handleStore does nothing. setFOV
writes the camera's field of view the way the game's does, ten less in third person; the game's
controller sets it again on its own events (perspective, settings) and that is not undone. ]]
function knitless.ctrlCamera(h)
	local workspace = h.workspace

	local perspective = {Name = 'CameraPerspectiveController', cachedCameraPerspective = 1}
	function perspective:calculateCameraPerspective()
		return knitless.ctrlPerspective(h)
	end
	function perspective:getCameraPerspective()
		return knitless.ctrlPerspective(h)
	end
	knitless.ctrlPut(h, 'CameraPerspectiveController', perspective)

	local viewmodel = {Name = 'ViewmodelController', crosshair = false}
	function viewmodel:getViewModel()
		local camera = workspace.CurrentCamera
		return camera and camera:FindFirstChild('Viewmodel')
	end
	function viewmodel:isVisible()
		return knitless.ctrlPerspective(h) == 0
	end
	function viewmodel:playAnimation(animationType, options)
		return knitless.ctrlPlayTrack(h, viewmodel:getViewModel(), knitless.ctrlAssetId(h, animationType), options)
	end
	function viewmodel:showCrosshair() end
	function viewmodel:hideCrosshair() end
	knitless.ctrlPut(h, 'ViewmodelController', viewmodel)

	knitless.ctrlPut(h, 'InventoryViewmodelController', {
		Name = 'InventoryViewmodelController',
		handleStore = function() end
	})

	local function settingsFov()
		local state = knitless.ctrlState(h)
		local settings = state and state.Settings
		local camera = workspace.CurrentCamera
		return settings and tonumber(settings.fov) or (camera and camera.FieldOfView) or 80
	end
	local fov = {Name = 'FovController', fovMultiplier = 1}
	function fov:getBaseFOV()
		local base = settingsFov()
		return knitless.ctrlPerspective(h) == 0 and base or base - 10
	end
	fov.fov = fov:getBaseFOV()
	function fov:getFOV()
		return self.fov
	end
	function fov:setFOV(value)
		value = tonumber(value) or settingsFov()
		if knitless.ctrlPerspective(h) ~= 0 then
			value -= 10
		end
		self.fov = value * self.fovMultiplier
		local camera = workspace.CurrentCamera
		if camera then
			camera.FieldOfView = self.fov
		end
	end
	knitless.ctrlPut(h, 'FovController', fov)
end

--[[ SprintController stand-in, after sprint-controller. The game's controller keeps running and owns the
Sprinting attribute, so that attribute is read as the game's own sprint state and never written.
Speed is WalkSpeed: base speed (20 running, 14 walking) times the game's multiplier, read off what
the game writes to WalkSpeed, times the modifiers added here. startSprinting holds run speed and
sets it back each time the game writes walk speed; a sprint the game blocks through its own
modifiers is not seen.

Modifiers reduce as the game's do: percents add up, a zero multiplier stops you, a constant one
wins, and any blockSprint ends the sprint. getModifiers adds one entry for the game's multiplier;
with Speed on, Zephyr's boost (zephyrConstant, from the WindWalkerController stand-in) is reported
as the constantSpeedMultiplier Knit executors turn it into, and taken out of that multiplier. They
are cleared on respawn, as the game's are.

The field of view tweens wider once on each change of this sprint state, as the game's
startSprinting does, only from the base or a widening of it (a scope is left alone), and goes back
only over this file's widening still on screen. Nothing answers a field of view change: tweening on
each one fought the game's own tweens. The widening goes back on after the game's own sprint ends
(deferred, after its tween) and after a perspective switch. ]]
function knitless.ctrlSprint(h)
	local WALK, RUN, FOV_MULT = 14, 20, 1.1
	local lplr, workspace = h.lplr, h.workspace
	local state = {humanoid = nil, gameMultiplier = 1, own = 1, written = nil}
	local inferred, zephyrEntry = {}, {}
	local sprint = {
		Name = 'SprintController',
		sprinting = false,
		attemptingSprint = false,
		blockSprint = false,
		moveSpeedMultiplier = 1,
		immediateStop = false
	}
	local modifier = {modifiers = {}}

	local function gameRunning()
		return lplr:GetAttribute('Sprinting') == true
	end

	local function apply()
		local humanoid = state.humanoid
		if not (humanoid and humanoid.Parent) then return end
		local base = (sprint.sprinting or gameRunning()) and RUN or WALK
		local target = base * state.gameMultiplier * state.own
		if math.abs(humanoid.WalkSpeed - target) > 0.01 then
			state.written = target
			humanoid.WalkSpeed = target
		end
	end

	local fovTween, fovBase
	local function widenFov()
		local camera = workspace.CurrentCamera
		local controller = h.ctx.controllers.FovController
		if not (camera and controller) then return end
		pcall(function()
			local base = controller:getBaseFOV()
			local fov = camera.FieldOfView
			if fov < base - 1 or fov > base * FOV_MULT + 1 then return end
			fovBase = base
			fovTween = h.tweenService:Create(camera, TweenInfo.new(0.1, Enum.EasingStyle.Linear), {FieldOfView = base * FOV_MULT})
			fovTween:Play()
		end)
	end
	local function restoreFov()
		local camera = workspace.CurrentCamera
		local base, tween = fovBase, fovTween
		fovBase, fovTween = nil, nil
		if not (camera and base) or gameRunning() then return end
		pcall(function()
			local playing = tween ~= nil and tween.PlaybackState == Enum.PlaybackState.Playing
			if not playing and math.abs(camera.FieldOfView - base * FOV_MULT) > 0.05 then return end
			h.tweenService:Create(camera, TweenInfo.new(0.1, Enum.EasingStyle.Linear), {FieldOfView = base}):Play()
		end)
	end

	function modifier:updateModifiers()
		local percent, stopped, blocked, constant = 0, false, false, nil
		for entry in self.modifiers do
			local multiplier = entry.moveSpeedMultiplier
			if multiplier ~= nil then
				if multiplier == 0 then
					stopped = true
				else
					percent += multiplier - 1
				end
			end
			if entry.blockSprint then
				blocked = true
			end
			if entry.constantSpeedMultiplier ~= nil then
				constant = entry.constantSpeedMultiplier
			end
		end
		state.own = constant or (if stopped then 0 else math.max(1 + percent, 0))
		sprint.blockSprint = blocked
		sprint.moveSpeedMultiplier = state.gameMultiplier * state.own
		if blocked then
			sprint:stopSprinting(false)
		elseif sprint.attemptingSprint and not sprint.sprinting then
			sprint:startSprinting()
		end
		apply()
	end

	function modifier:addModifier(entry, onRemove)
		self.modifiers[entry] = true
		self:updateModifiers()
		return {Destroy = function()
			if onRemove then
				onRemove()
			end
			return self:removeModifier(entry)
		end}
	end

	function modifier:removeModifier(entry)
		local had = self.modifiers[entry] ~= nil
		self.modifiers[entry] = nil
		if had then
			self:updateModifiers()
		end
		return had
	end

	function modifier:getModifiers()
		local set = table.clone(self.modifiers)
		local zephyr = sprint.zephyrConstant
		if type(zephyr) == 'number' and zephyr > 1 then
			zephyrEntry.constantSpeedMultiplier = zephyr
			set[zephyrEntry] = true
			inferred.moveSpeedMultiplier = math.max(state.gameMultiplier - (zephyr - 1), 1)
		else
			inferred.moveSpeedMultiplier = state.gameMultiplier
		end
		set[inferred] = true
		return set
	end

	function modifier:clear()
		table.clear(self.modifiers)
		self:updateModifiers()
	end

	function sprint:getMovementStatusModifier()
		return modifier
	end

	function sprint:isSprinting()
		return self.sprinting
	end

	function sprint:setSpeed()
		apply()
	end

	function sprint:startSprinting()
		if workspace:GetAttribute('FreecamEnabled') then return nil end
		if self.blockSprint then return nil end
		local was = self.sprinting
		self.sprinting = true
		self.attemptingSprint = true
		apply()
		if not was then
			widenFov()
		end
		return nil
	end

	function sprint:stopSprinting(clearAttempt)
		if not self.sprinting then return nil end
		self.sprinting = false
		if clearAttempt then
			self.attemptingSprint = false
		end
		apply()
		restoreFov()
		return nil
	end

	knitless.ctrlOnCharacter(h, function(_, humanoid)
		state.humanoid = humanoid
		state.gameMultiplier = 1
		state.written = nil
		modifier:clear()
		return {humanoid:GetPropertyChangedSignal('WalkSpeed'):Connect(function()
			local speed = humanoid.WalkSpeed
			if state.written and math.abs(speed - state.written) < 0.01 then return end
			state.written = nil
			state.gameMultiplier = speed / (gameRunning() and RUN or WALK)
			sprint.moveSpeedMultiplier = state.gameMultiplier * state.own
			task.defer(apply)
		end)}
	end)

	local lastPerspective
	h.ctx.clean(lplr:GetAttributeChangedSignal('Sprinting'):Connect(function()
		if gameRunning() or not sprint.sprinting then return end
		task.defer(function()
			if sprint.sprinting and not gameRunning() then
				widenFov()
			end
		end)
	end))
	h.ctx.clean(h.ctx.services.RunService.Heartbeat:Connect(function()
		if not sprint.sprinting or gameRunning() then
			lastPerspective = nil
			return
		end
		local now = knitless.ctrlPerspective(h)
		if lastPerspective ~= nil and now ~= lastPerspective then
			widenFov()
		end
		lastPerspective = now
	end))

	knitless.ctrlPut(h, 'SprintController', sprint)
end

--[[ ProjectileController.createLocalProjectile without the game's controller. The game scores a
shot only through the shooter's own local projectile: ProjectileUtil.fireProjectile flies it, and at
the first part it accepts the hit callback sends ProjectileHit(refId, entity model or nil) with the
refId the ProjectileFire call carried. Nothing else reports a hit, so without this the server has
the shot and never hears that it landed. This flies the shot the way fireProjectile does
(projectile-controller and projectile-util, 10-19 and 10-24 decompiles), with no model:

  * Path: spawn = CFrame.new(positionFrom, positionFrom + velocity) * CFrame.new(rel), rel being
    the source's relativeOverride or projectile-util's RelX/RelY/RelZ; then
    spawn + velocity*t + (0, -g, 0)*t*t/2, g = ProjectileMeta[type].gravitationalAcceleration
    (196.2 when missing), no drag. t adds up the Heartbeat steps, starting with the first physics
    step after the call, as the game's model moves.
  * Each Heartbeat takes clamp(ceil(|velocity|/170), 1, 16) points from the last position to this
    one (positionFrom itself first, on the first step) and at each runs an entity box
    (3, 1, 3)*hitscanRegionMultiplier, a wall box (1, 0.5, 1)*wallHitscanRegionMultiplier and the
    terrain around the wall box, in that order, through the game's own test of each part
    (knitless.projectileAccept). The first part it accepts is the hit.
  * The hit sends ProjectileHit(refId, model) as the game does: model is the 'entity' the part
    belongs to, or nil for a block, terrain or any other part. One per shot; then the shot is over.
  * With no hit the shot ends silently after lifetimeSec (10 s when the meta has none; the game
    counts from a frame late), below FallenPartsDestroyHeight (Roblox removes the game's model
    there), or once it is returnDistance from you (the game then flies it back to you).
  * useServerModel and collisionDisabled projectiles get no local shot, as in the game.
At most sim.cap shots fly at once; a new one drops the oldest. Nothing is drawn and nil is returned.
It never throws or yields, and nothing is tested or sent before the next Heartbeat. ]]
function knitless.projectileLaunch(h, source, ammo, projectileType, positionFrom, refId, velocity, options, config, shooter, tool)
	local ok, err = pcall(knitless.projectileStart, h, source, projectileType, positionFrom, refId, velocity, config, tool)
	if not ok then
		knitless.ctrlLog(h, 'createLocalProjectile failed: '..tostring(err))
	end
	return nil
end

--[[ isValidProjectileLaunch: finite, within a million studs, and 0.001 to 10000 studs a second. ]]
function knitless.projectileValid(position, velocity)
	for _, value in {position.X, position.Y, position.Z, velocity.X, velocity.Y, velocity.Z} do
		if value ~= value or math.abs(value) == math.huge then return false end
	end
	if math.abs(position.X) > 1e6 or math.abs(position.Y) > 1e6 or math.abs(position.Z) > 1e6 then
		return false
	end
	local speed = velocity.Magnitude
	return speed >= 0.001 and speed <= 10000
end

--[[ Starts one simulated shot, checked the way createLocalProjectile and fireProjectile check it, and
adds it to the list the Heartbeat flies. The game makes no local shot for a server-model projectile,
never tests a collisionDisabled one, and makes none while you have no character. The spawn offset is
the source's relativeOverride, or the config's when there is no source. The first step's points
start at positionFrom itself, not at the spawn. The lifetime is never longer than a minute, whatever
the meta says. frame is the frame the shot was made in: made after that frame's Stepped, the game's
model first moves in the next. At the cap the oldest shot is dropped. onSimulatedShot listeners run
over a copy, so one may stop itself. ]]
function knitless.projectileStart(h, source, projectileType, positionFrom, refId, velocity, config, tool)
	local sim = knitless.projectileSim or knitless.projectileSetup(h)
	if sim.closed then return end
	local meta = type(projectileType) == 'string' and sim.meta[projectileType] or nil
	if type(meta) ~= 'table' then
		knitless.ctrlLog(h, 'no ProjectileMeta for '..tostring(projectileType)..'; that projectile is not flown')
		return
	end
	if meta.useServerModel or meta.collisionDisabled then return end
	if refId == nil or typeof(positionFrom) ~= 'Vector3' or typeof(velocity) ~= 'Vector3'
		or not knitless.projectileValid(positionFrom, velocity) then
		knitless.ctrlLog(h, 'a '..projectileType..' shot without a refId or with an invalid position or velocity is not flown')
		return
	end
	local gravity = meta.gravitationalAcceleration
	if gravity == nil then gravity = 196.2 end
	if type(gravity) ~= 'number' or gravity ~= gravity or math.abs(gravity) == math.huge then return end
	local character = h.lplr.Character
	if not (character and character.PrimaryPart) then return end

	local relative
	if source ~= nil then
		relative = type(source) == 'table' and source.relativeOverride or nil
	elseif type(config) == 'table' then
		relative = config.relativeOverride
	end
	local offset = sim.relative
	if type(relative) == 'table' then
		offset = Vector3.new(tonumber(relative.relX) or 0, tonumber(relative.relY) or 0, tonumber(relative.relZ) or 0)
	end
	local hitscan = tonumber(meta.hitscanRegionMultiplier) or 1
	local wall = tonumber(meta.wallHitscanRegionMultiplier) or hitscan
	local lifetime = meta.lifetimeSec
	if type(lifetime) ~= 'number' or lifetime ~= lifetime then lifetime = 10 end
	local returnDistance = meta.returnDistance
	if not (type(returnDistance) == 'number' and returnDistance > 0) then returnDistance = nil end

	local shot = {
		id = refId,
		kind = projectileType,
		from = positionFrom,
		spawn = (CFrame.new(positionFrom, positionFrom + velocity) * CFrame.new(offset)).Position,
		velocity = velocity,
		fall = Vector3.new(0, -gravity / 2, 0),
		last = positionFrom,
		first = true,
		t = 0,
		count = math.clamp(math.ceil(velocity.Magnitude / 170), 1, 16),
		entityBox = Vector3.new(3, 1, 3) * hitscan,
		wallBox = Vector3.new(1, 0.5, 1) * wall,
		lifetime = math.min(lifetime, 60),
		returnDistance = returnDistance,
		tool = typeof(tool) == 'Instance' and tool or nil,
		friendlyFire = meta.canHitAllyPlayers == true or knitless.projectileFriendlyFire(h, character),
		frame = sim.frame
	}
	local shots = sim.shots
	if #shots >= sim.cap then
		local dropped = table.remove(shots, 1)
		knitless.projectileLog(sim, 'Projectile cap ('..sim.cap..') reached; dropped the oldest shot ('
			..tostring(dropped.kind)..' '..tostring(dropped.id)..')')
	end
	table.insert(shots, shot)
	if sim.developer then
		knitless.projectileRemember(sim, shot)
	end
	local listeners = h.shotListeners
	if listeners and #listeners > 0 then
		for _, entry in table.clone(listeners) do
			pcall(entry.callback, shot)
		end
	end
end

--[[ The shared projectile simulation state, made at the first shot: the shot list, one Heartbeat that
flies every shot and one Stepped that counts frames, both dropped with the rest of the layer. The
default spawn offset is projectile-util's RelX/RelY/RelZ, which ConstantManager keeps as attributes
on the module. A step that fails clears every shot. ]]
function knitless.projectileSetup(h)
	local meta = knitless.ctrlExport(h, 'ReplicatedStorage.TS.projectile.projectile-meta', 'ProjectileMeta')
	local sim = {
		shots = {},
		points = {},
		cap = 16,
		frame = 0,
		meta = type(meta) == 'table' and meta or {},
		relative = Vector3.new(0.8, -0.6, 0),
		params = OverlapParams.new(),
		voidY = -500,
		terrain = h.workspace:FindFirstChildOfClass('Terrain'),
		logWindow = -math.huge,
		logCount = 0,
		held = 0,
		developer = shared.PistonwareDeveloper == true,
		recent = {},
		remembered = 0,
		targets = setmetatable({}, {__mode = 'k'})
	}
	sim.params.FilterType = Enum.RaycastFilterType.Exclude
	pcall(function()
		local module = h.replicatedStorage.TS.combat['projectile-util']
		local function read(key, default)
			local value = module:GetAttribute('ConstantManager_'..key)
			return type(value) == 'number' and value or default
		end
		sim.relative = Vector3.new(read('RelX', 0.8), read('RelY', -0.6), read('RelZ', 0))
	end)
	pcall(function()
		sim.voidY = h.workspace.FallenPartsDestroyHeight
	end)
	knitless.projectileSim = sim

	local runService = h.ctx.services.RunService
	h.ctx.clean(runService.Stepped:Connect(function()
		sim.frame += 1
	end))
	h.ctx.clean(runService.Heartbeat:Connect(function(dt)
		local ok, err = pcall(knitless.projectileStep, h, sim, dt)
		if not ok then
			table.clear(sim.shots)
			knitless.ctrlLog(h, 'projectile step failed: '..tostring(err))
		end
	end))
	h.ctx.clean(function()
		sim.closed = true
		table.clear(sim.shots)
	end)
	if sim.developer then
		local ok, err = pcall(knitless.projectileWatch, h, sim)
		if not ok then
			knitless.ctrlLog(h, 'projectile watch failed: '..tostring(err))
		end
	end
	return sim
end

--[[ One Heartbeat: each shot moves on by dt and is tested along the way, and finished shots leave
the list. A shot made since this frame's Stepped waits for the next frame. ]]
function knitless.projectileStep(h, sim, dt)
	local shots = sim.shots
	if #shots == 0 then return end
	local lplr = h.lplr
	local character = lplr.Character
	local camera = h.workspace.CurrentCamera
	if character ~= sim.character or camera ~= sim.camera then
		sim.character, sim.camera = character, camera
		local exclude = {}
		if character then table.insert(exclude, character) end
		if camera then table.insert(exclude, camera) end
		sim.params.FilterDescendantsInstances = exclude
	end
	sim.root = character and character.PrimaryPart or nil
	sim.team = lplr:GetAttribute('Team')
	local team = lplr.Team
	sim.teamName = team and team.Name or nil
	sim.vehicle = knitless.projectileVehicle(h, character)

	local index = 1
	while index <= #shots do
		local shot = shots[index]
		local done = false
		if shot.frame ~= sim.frame then
			local ok, result = pcall(knitless.projectileAdvance, h, sim, shot, dt)
			if ok then
				done = result
			else
				done = true
				knitless.ctrlLog(h, 'projectile '..tostring(shot.kind)..' failed in flight: '..tostring(result))
			end
		end
		if done then
			table.remove(shots, index)
		else
			index += 1
		end
	end
end

--[[ Moves one shot one step and tests the points along it; true once the shot is over (a hit, out of the
map, turned back or expired). The game's lifetime clock starts a frame after its model's first step.
A projectile that comes back skips the step while you have no character, as in the game. ]]
function knitless.projectileAdvance(h, sim, shot, dt)
	shot.t += dt
	shot.age = shot.age and shot.age + dt or 0
	local t = shot.t
	local position = shot.spawn + shot.velocity * t + shot.fall * (t * t)
	if position.Y < sim.voidY then
		knitless.projectileLog(sim, string.format('Projectile %s fell out of the map after %.2fs without a hit (%s)',
			tostring(shot.kind), t, tostring(shot.id)))
		return true
	end
	local root = sim.root
	if not (shot.returnDistance and not root) then
		local points = sim.points
		table.clear(points)
		local last = shot.last
		if shot.first then
			shot.first = false
			table.insert(points, last)
		end
		local count = shot.count
		local delta = position - last
		for step = 1, count - 1 do
			table.insert(points, last + delta * (step / count))
		end
		table.insert(points, position)
		shot.last = position
		for _, point in points do
			local part = knitless.projectileTest(h, sim, shot, point)
			if part then
				knitless.projectileHit(h, sim, shot, part, point)
				return true
			end
		end
		if shot.returnDistance and (root.Position - position).Magnitude > shot.returnDistance then
			knitless.projectileLog(sim, string.format('Projectile %s turned back at %.0f studs without a hit (%s)',
				tostring(shot.kind), shot.returnDistance, tostring(shot.id)))
			return true
		end
	end
	if shot.age > shot.lifetime then
		knitless.projectileLog(sim, string.format('Projectile %s expired after %.2fs without a hit (%s)',
			tostring(shot.kind), t, tostring(shot.id)))
		return true
	end
	return false
end

--[[ The game's three tests at one point, in its order: the entity box, the wall box, the terrain.
The accepted part, or nil. ]]
function knitless.projectileTest(h, sim, shot, point)
	local world = h.workspace
	local frame = CFrame.new(point)
	for _, part in world:GetPartBoundsInBox(frame, shot.entityBox, sim.params) do
		local hit = knitless.projectileAccept(h, sim, shot, part, true)
		if hit then return hit end
	end
	for _, part in world:GetPartBoundsInBox(frame, shot.wallBox, sim.params) do
		local hit = knitless.projectileAccept(h, sim, shot, part, false)
		if hit then return hit end
	end
	local terrain = sim.terrain
	if terrain and knitless.projectileTerrain(h, sim, terrain, point, shot.wallBox) then
		return knitless.projectileAccept(h, sim, shot, terrain, false)
	end
	return nil
end

--[[ Whether the 4-stud voxels around the wall box hold anything but air or water. ]]
function knitless.projectileTerrain(h, sim, terrain, point, size)
	local half = size / 2
	local region = Region3.new(point - half, point + half):ExpandToGrid(4)
	local ok, materials = pcall(terrain.ReadVoxels, terrain, region, 4)
	if not ok then
		sim.terrain = nil
		knitless.ctrlLog(h, 'projectile terrain test off: '..tostring(materials))
		return false
	end
	local air, water = Enum.Material.Air, Enum.Material.Water
	for x = 1, #materials do
		local plane = materials[x]
		for y = 1, #plane do
			local row = plane[y]
			for z = 1, #row do
				local material = row[z]
				if material ~= air and material ~= water then
					return true
				end
			end
		end
	end
	return false
end

--[[ fireProjectile's test of one part: the part the hit is reported with (an entity's PrimaryPart for an
entity), or nil when the shot flies on. The game's rules in its order, except that the entity box's
rule (entities and falling blocks only) runs first, where it costs least. The game's three local
listeners that cancel a hit are reproduced: your own team's airbender tornado, battle royale's ghost
form and the vehicle you sit in. A part in genv.PistonwarePierced is still hit despite
gamecore_GameQueryIgnore: pistonware set that mark and the server's copy of the shot still hits it.
]]
function knitless.projectileAccept(h, sim, shot, part, entityOnly)
	local collection = h.collection
	local hitbox = collection:HasTag(part, 'Hitbox')
	local entity = knitless.projectileEntityOf(h, part)
	if hitbox then
		local value = part:FindFirstChild('EntityValue')
		value = value and value:IsA('ObjectValue') and value.Value or nil
		if value then
			entity = knitless.projectileEntityFrom(h, value)
		end
	end
	if entityOnly and not entity and not collection:HasTag(part, 'falling-block') then return nil end
	local tool = shot.tool
	if tool and (part == tool or part:IsDescendantOf(tool)) then return nil end
	if part:GetAttribute('gamecore_GameQueryIgnore') == true and not hitbox then
		local pierced = genv.PistonwarePierced
		if not (type(pierced) == 'table' and pierced[part]) then return nil end
	end
	if collection:HasTag(part, 'ProjectilesIgnore') or part:GetAttribute('IgnoreProjectileCollision') == true then
		return nil
	end
	local parent = part.Parent
	if parent and parent.Name == 'ArcParticles' then return nil end
	if entity then
		if not knitless.projectileAlive(h, entity) then return nil end
		if part:IsA('Accessory') or part:FindFirstAncestorWhichIsA('Accessory') then return nil end
		part = entity:IsA('Model') and entity.PrimaryPart or part
		local lplr = h.lplr
		local player = knitless.projectilePlayerOf(h, entity)
		if entity == lplr.Character or (player and player.UserId == lplr.UserId) then return nil end
		local ghost = player and entity:GetAttribute('GhostForm')
		if ghost and ghost ~= 0 and ghost ~= '' and ghost == ghost then return nil end
		if not shot.friendlyFire and not knitless.projectileEnemy(h, sim, entity, player) then return nil end
	end
	local model = part:FindFirstAncestorOfClass('Model')
	if model and sim.meta[model.Name] ~= nil then return nil end
	if collection:HasTag(part, 'ProjectileShield') then
		local center = part:GetAttribute('ShieldCenter')
		if typeof(center) ~= 'Vector3' then center = Vector3.zero end
		if (tonumber(part:GetAttribute('ShieldRadius')) or 0) / 2 > (shot.from - center).Magnitude then return nil end
		local shieldTeam = part:GetAttribute('ShieldTeamId')
		if shieldTeam ~= nil and shieldTeam ~= '' and shieldTeam == sim.team then return nil end
	end
	local tornado = part:GetAttribute('TornadoTeam')
	if tornado ~= nil and tornado ~= '' and tornado == sim.teamName then return nil end
	local vehicle = sim.vehicle
	if vehicle and part:IsDescendantOf(vehicle) then return nil end
	return part
end

--[[ VehicleController's own-vehicle canceller: a shot made from a seat of a 'vehicle' passes that
vehicle's parts (VehicleUtil.isInVehicle: a Seat in it that your Humanoid occupies). The vehicle,
or nil. ]]
function knitless.projectileVehicle(h, character)
	local humanoid = character and character:FindFirstChildOfClass('Humanoid')
	local seat = humanoid and humanoid.SeatPart
	if not (seat and seat:IsA('Seat')) then return nil end
	local collection = h.collection
	local node = seat.Parent
	while node and not node:IsA('Workspace') do
		if collection:HasTag(node, 'vehicle') then return node end
		node = node.Parent
	end
	return nil
end

--[[ EntityUtil:getEntityFromDescendant's instance: the nearest ancestor (or the part) tagged 'entity'. ]]
function knitless.projectileEntityOf(h, part)
	local collection = h.collection
	local node = part
	while node and not node:IsA('Workspace') do
		if collection:HasTag(node, 'entity') then return node end
		node = node.Parent
	end
	return nil
end

--[[ EntityUtil:getEntity's instance for a Hitbox's EntityValue: a player's character, a player's
model in Workspace, or the nearest ancestor tagged 'entity' or 'inventory-entity'. ]]
function knitless.projectileEntityFrom(h, value)
	if typeof(value) ~= 'Instance' then return nil end
	if value:IsA('Player') then return value.Character end
	local collection = h.collection
	local node = value
	while node and not node:IsA('Workspace') do
		if knitless.projectilePlayerOf(h, node) or collection:HasTag(node, 'inventory-entity')
			or collection:HasTag(node, 'entity') then
			return node
		end
		node = node.Parent
	end
	return nil
end

--[[ The player an entity is, by EntityUtil's rule: a Model in Workspace named after a player. ]]
function knitless.projectilePlayerOf(h, model)
	local parent = model.Parent
	if parent and parent:IsA('Workspace') and model:IsA('Model') then
		local player = h.players:FindFirstChild(model.Name)
		if player and player:IsA('Player') then return player end
	end
	return nil
end

--[[ Entity:isAlive: a player's character needs its Humanoid, and the Humanoid's health, the Health
attribute (else the Humanoid's) and the Dead attribute must all say alive. ]]
function knitless.projectileAlive(h, entity)
	local humanoid = entity:FindFirstChild('Humanoid')
	if humanoid and not humanoid:IsA('Humanoid') then humanoid = nil end
	if h.players:GetPlayerFromCharacter(entity) and (humanoid == nil or humanoid.Parent == nil) then return false end
	if humanoid and humanoid.Health <= 0 then return false end
	local health = entity:GetAttribute('Health')
	if health == nil then health = humanoid and humanoid.Health or 0 end
	if type(health) == 'number' and health <= 0 then return false end
	return entity:GetAttribute('Dead') ~= true
end

--[[ PlayerEntity.canAttack's team test for your shot: a player on your team, a mob whose Team is
yours, or one placed by a teammate is not hit (the shot flies on). ]]
function knitless.projectileEnemy(h, sim, entity, player)
	local team = sim.team
	if player then
		return player:GetAttribute('Team') ~= team
	end
	if entity:GetAttribute('Team') == team then return false end
	local owner = entity:GetAttribute('PlacedByUserId')
	if owner == nil then owner = entity:GetAttribute('PlayerUserId') end
	if type(owner) == 'number' and owner ~= 0 and owner == owner then
		local ownerPlayer = h.players:GetPlayerByUserId(owner)
		if ownerPlayer and ownerPlayer:GetAttribute('Team') == team then return false end
	end
	return true
end

--[[ PlayerEntity.canAttack's friendly-fire cases: the FriendlyFire attribute on your character, or
a queue whose meta turns friendly fire on. ]]
function knitless.projectileFriendlyFire(h, character)
	if character:GetAttribute('FriendlyFire') == true then return true end
	local queues = knitless.ctrlExport(h, 'ReplicatedStorage.TS.game.queue-meta', 'QueueMeta')
	local queue = h.workspace:GetAttribute('QueueType')
	local meta = type(queues) == 'table' and queue ~= nil and queues[queue] or nil
	return type(meta) == 'table' and meta.enableFriendlyFire == true
end

--[[ The hit callback: ProjectileHit(refId, model) exactly as the game sends it, model being the
entity of the reported part or nil, and one log line. ]]
function knitless.projectileHit(h, sim, shot, part, point)
	local model = knitless.projectileEntityOf(h, part)
	local remote = knitless.ctrlRemote(h, 'ProjectileHit')
	local sent, err = false, 'no ProjectileHit remote'
	if remote then
		sent, err = pcall(remote.SendToServer, remote, shot.id, model)
	end
	local target
	if model then
		target = model.Name
	elseif part:IsA('Terrain') then
		target = 'terrain'
	elseif h.collection:HasTag(part, 'block') then
		target = 'block '..part.Name
	else
		target = 'part '..part.Name
	end
	knitless.projectileLog(sim, string.format('ProjectileHit %s -> %s (%s, %.2fs, %.1f studs)%s', tostring(shot.kind),
		target, tostring(shot.id), shot.t, (point - shot.from).Magnitude, sent and '' or ' NOT SENT: '..tostring(err)))
	if sim.developer and model then
		sim.targets[model] = {kind = shot.kind, id = shot.id, at = os.clock()}
	end
end

--[[ The log lines, at most 8 a second; the count of any held back goes on the next one. ]]
function knitless.projectileLog(sim, text)
	local now = os.clock()
	if now - sim.logWindow >= 1 then
		sim.logWindow, sim.logCount = now, 0
	end
	if sim.logCount >= 8 then
		sim.held += 1
		return
	end
	sim.logCount += 1
	if sim.held > 0 then
		text = text..' ('..sim.held..' lines held back)'
		sim.held = 0
	end
	knitless.log(text)
end

--[[ Developer mode: the shots of the last half minute, by the first 8 characters of the id (all the
server's launch echo carries). ]]
function knitless.projectileRemember(sim, shot)
	local recent = sim.recent
	local now = os.clock()
	recent[string.sub(tostring(shot.id), 1, 8)] = {kind = shot.kind, id = shot.id, at = now}
	sim.remembered += 1
	if sim.remembered > 64 then
		sim.remembered = 0
		for key, record in recent do
			if now - record.at > 30 then
				recent[key] = nil
			else
				sim.remembered += 1
			end
		end
	end
end

--[[ Developer mode, read only: what the server says back about these shots, from the Zap events the
layer decodes. The launch echo carries the shot's id and the server's model for it, the impact names
that model, and the damage event names who dealt it. ]]
function knitless.projectileWatch(h, sim)
	local zap = h.ctx.modules['PlayerScripts.TS.lib.network']
	if type(zap) ~= 'table' then return end
	local function listen(name, callback)
		local event = zap[name]
		if type(event) == 'table' and type(event.On) == 'function' then
			h.ctx.clean(event.On(function(...)
				pcall(callback, ...)
			end))
		end
	end
	listen('ProjectileLaunchZap', function(_, _, model, id)
		local record = type(id) == 'string' and sim.recent[id] or nil
		if record and record.model == nil then
			record.model = model
			knitless.projectileLog(sim, 'server launched '..tostring(record.kind)..' '..tostring(record.id))
		end
	end)
	listen('ProjectileImpactZap', function(_, kind, model, _, _, player, target)
		if not (player and player.UserId == h.lplr.UserId) or model == nil then return end
		for _, record in sim.recent do
			if record.model == model then
				knitless.projectileLog(sim, 'server impact '..tostring(record.kind)..' '..tostring(record.id)..' on '
					..(target and target.Name or 'no entity')..' (kind '..tostring(kind)..')')
				return
			end
		end
	end)
	listen('EntityDamageEventZap', function(entity, damage, _, _, from)
		local character = h.lplr.Character
		if not (from and character and from == character) then return end
		local record = sim.targets[entity]
		if record and os.clock() - record.at < 2 then
			knitless.projectileLog(sim, 'server damage '..tostring(damage)..' on '..entity.Name..' after the '
				..tostring(record.kind)..' hit ('..tostring(record.id)..')')
		end
	end)
end

--[[ The controllers the bootstrap waits for besides SwordController, plus DamageIndicatorController,
which it indexes, and the knockback pair. ProjectileController leaves the launch hooks
(calculateImportantLaunchValues, launchProjectileWithValues, launchProjectile) nil: they belong to
the game's own shots, so the modules that wrap them find nothing to wrap. enableBeam is read only
for its upvalues. createLocalProjectile flies the shot unseen and reports its hit as the game does
(knitless.projectileLaunch). onSimulatedShot exists because the server's launch echo and its reply
to the shot come in the same network tick, in either order; its callback runs in a pcall right after
the shot is listed and must not yield.

The game paces its own mining inside its own breaker, so the blockBreaker's setCooldown only
remembers the value; hit and break effects and the healthbar are not drawn. ItemDropController drops
the item the game has selected (HandInvItem with no tiles to read); auto-pickup stays with the game.
getLastKnockbackTime is stamped, at most once per 50 ms, by EntityDamageEventZap with the game's
filter (not fall damage, knockback not disabled) and by every drop in your Humanoid's health, fall
damage included: the health watch runs whether or not Zap events arrive. Speed writes
StatefulEntityKnockbackController.lastImpulseTime every frame. ]]
function knitless.ctrlCore(h)
	local lplr = h.lplr

	local projectile = {Name = 'ProjectileController'}
	function projectile.enableBeam() end
	function projectile:createLocalProjectile(...)
		return knitless.projectileLaunch(h, ...)
	end
	function projectile:simulatedShot(refId)
		local sim = knitless.projectileSim
		if not (sim and refId) then return nil end
		for _, shot in sim.shots do
			if shot.id == refId then
				return shot
			end
		end
		return nil
	end
	local shotListeners = {}
	h.shotListeners = shotListeners
	function projectile:onSimulatedShot(callback)
		if type(callback) ~= 'function' then
			return function() end
		end
		local entry = {callback = callback}
		table.insert(shotListeners, entry)
		return function()
			local index = table.find(shotListeners, entry)
			if index then table.remove(shotListeners, index) end
		end
	end
	knitless.ctrlPut(h, 'ProjectileController', projectile)

	local clientEngine = knitless.ctrlExport(h, 'PlayerScripts.TS.lib.block-engine.client-block-engine', 'ClientBlockEngine')
	if type(clientEngine) ~= 'table' then
		local selector = {getMouseInfo = function() return nil end}
		clientEngine = {
			getBlockSelector = function() return selector end,
			getConfig = function() return {} end
		}
		knitless.ctrlLog(h, 'no ClientBlockEngine from the blocks slice; the breaker selects nothing')
	end
	local breakEffect = {}
	function breakEffect:playHit() end
	function breakEffect:playBreak() end
	local breaker = {
		clientManager = clientEngine,
		cooldown = 0.3,
		range = 18,
		blockHealth = -1,
		lastHitTime = 0,
		breakEffect = breakEffect
	}
	function breaker:hitBlock() end
	function breaker:updateHealthbar() end
	function breaker:setCooldown(value)
		self.cooldown = value
	end
	function breaker:getCooldown()
		return self.cooldown
	end
	function breaker:setRange(value)
		self.range = value
	end
	function breaker:getRange()
		return self.range
	end
	function breaker:enable() end
	function breaker:disable() end
	knitless.ctrlPut(h, 'BlockBreakController', {Name = 'BlockBreakController', blockBreaker = breaker})

	local matchController = {Name = 'MatchController'}
	function matchController:getMatchState()
		return knitless.ctrlMatchState(h)
	end
	knitless.ctrlPut(h, 'MatchController', matchController)

	local drop = {Name = 'ItemDropController'}
	local function sendDrop(payload)
		local remote = knitless.ctrlRemote(h, 'DropItem')
		if not remote then return nil end
		local ok, dropped = pcall(remote.CallServer, remote, payload)
		if not (ok and dropped) then return nil end
		knitless.ctrlPlaySound(h, h.gameSound.DROP_ITEM)
		if typeof(dropped) == 'Instance' then
			pcall(dropped.SetAttribute, dropped, 'ClientDropTime', tick())
		end
		return dropped
	end
	function drop.dropItemInHand()
		local item = knitless.hotbarSelectedItem(h.ctx)
		local tool = if item == nil then knitless.ctrlHand(h) else item and item.tool
		if tool then
			sendDrop({item = tool})
		end
	end
	function drop:dropHotbarItem(slot)
		local state = knitless.ctrlState(h)
		local observed = state and state.Inventory and state.Inventory.observedInventory
		local entry = observed and observed.hotbar and observed.hotbar[(tonumber(slot) or 0) + 1]
		local item = type(entry) == 'table' and entry.item or nil
		if not (type(item) == 'table' and item.tool) then return false end
		return sendDrop({item = item.tool, amount = item.amount}) ~= nil
	end
	knitless.ctrlPut(h, 'ItemDropController', drop)

	knitless.ctrlPut(h, 'DamageIndicatorController', {
		Name = 'DamageIndicatorController',
		spawnDamageIndicator = function() end
	})

	local knockback = {Name = 'KnockbackController', lastKnockbackTime = 0}
	function knockback:getLastKnockbackTime()
		return self.lastKnockbackTime
	end
	local function stamp()
		local now = h.workspace:GetServerTimeNow()
		if now - knockback.lastKnockbackTime > 0.05 then
			knockback.lastKnockbackTime = now
		end
	end
	local damageEvent = knitless.ctrlExport(h, 'PlayerScripts.TS.lib.network', 'EntityDamageEventZap')
	if type(damageEvent) == 'table' and type(damageEvent.On) == 'function' then
		pcall(function()
			local stop = damageEvent.On(function(entity, _, damageType, _, _, multiplier)
				if entity ~= lplr.Character or damageType == 1 then return end
				if type(multiplier) == 'table' and multiplier.disabled then return end
				stamp()
			end)
			if stop then
				h.ctx.clean(stop)
			end
		end)
	end
	knitless.ctrlOnCharacter(h, function(_, humanoid)
		local last = humanoid.Health
		return {humanoid.HealthChanged:Connect(function(health)
			if health < last then
				stamp()
			end
			last = health
		end)}
	end)
	knitless.ctrlPut(h, 'KnockbackController', knockback)

	knitless.ctrlPut(h, 'StatefulEntityKnockbackController', {Name = 'StatefulEntityKnockbackController', lastImpulseTime = 0})
end

--[[ Controllers the loader and payload read outside the swing: placement, input, names, honor, queue and
the HUD hooks. BlockPlacementController.disabled is the DenyBlockPlace attribute (kit controllers
that disable the placer are not seen); blockPlacer is there while the item the game has selected is
a block, its blockType following that item, which a module's swap leaves where it was.
BlockCpsController is stamped only by this layer's placer; placements the game makes are paced by
its own controller. DaoController.chargingMaid is set while IsCasting with a dao sword in hand.
StreamerModeController.getDisplayName is the game's formula: the kit's name ('Player' before the
match), then '-', the team id and two digits from Random.new(startTime + UserId); without startTime,
the kit's name only. HonorController does not update the honored list in the game's store. Every
keybind set keeps an Attack binding, as the readers expect. A UserInputController type set by
DeviceSpoofer is sent again, deferred, after the game answers RequestUserInputType.
getCurrentGuidedProjectile is left nil: the guided drone is the game's own state. FPS Boost walks
KillEffectController.killEffects. ]]
function knitless.ctrlGeneral(h)
	local lplr = h.lplr

	local blockPlacer = knitless.ctrlExport(h, 'ReplicatedStorage.rbxts_include.node_modules.@easy-games.block-engine.out.client.placement.block-placer', 'BlockPlacer')
	local clientEngine = knitless.ctrlExport(h, 'PlayerScripts.TS.lib.block-engine.client-block-engine', 'ClientBlockEngine')
	local placer
	if type(blockPlacer) == 'table' and type(blockPlacer.new) == 'function' and clientEngine then
		local ok, made = pcall(blockPlacer.new, clientEngine, 'wool_white')
		placer = ok and made or nil
	end
	knitless.ctrlPut(h, 'BlockPlacementController', setmetatable({Name = 'BlockPlacementController'}, {
		__index = function(_, key)
			if key == 'disabled' then
				return lplr:GetAttribute('DenyBlockPlace') == true
			elseif key == 'blockPlacer' and placer then
				local item = knitless.hotbarSelectedItem(h.ctx)
				local tool, meta
				if item == nil then
					tool, meta = knitless.ctrlHand(h)
				elseif item and item.tool then
					tool, meta = item.tool, knitless.ctrlItemMeta(h, item.tool.Name)
				end
				if not (meta and meta.block) then return nil end
				placer.blockType = tool.Name
				return placer
			end
			return nil
		end
	}))

	knitless.ctrlPut(h, 'BlockCpsController', {Name = 'BlockCpsController', lastPlaceTimestamp = 0})

	local charging = {DoCleaning = function() end}
	knitless.ctrlPut(h, 'DaoController', setmetatable({Name = 'DaoController'}, {
		__index = function(_, key)
			if key ~= 'chargingMaid' then return nil end
			local casting = lplr:GetAttribute('IsCasting')
			if casting == nil or casting == false or casting == 0 then return nil end
			local _, meta = knitless.ctrlHand(h)
			return meta and meta.daoSword and charging or nil
		end
	}))

	knitless.ctrlPut(h, 'HangGliderController', setmetatable({Name = 'HangGliderController'}, {
		__index = function(_, key)
			if key ~= 'hangGliderActive' then return nil end
			local character = lplr.Character
			local root = character and (character:FindFirstChild('HumanoidRootPart') or character.PrimaryPart)
			return root ~= nil and root:FindFirstChild('LiftForce') ~= nil
		end
	}))

	local streamer = {Name = 'StreamerModeController'}
	function streamer:getDisplayName(player)
		local kits = player:GetAttribute('PlayingAsKits')
		local kit = type(kits) == 'string' and kits:split(',')[1] or 'none'
		if kit == '' then kit = 'none' end
		local meta = h.kitMeta[kit]
		local name = type(meta) == 'table' and meta.name or kit
		if knitless.ctrlMatchState(h) == 0 then
			name = 'Player'
		end
		local state = knitless.ctrlState(h)
		local startTime = state and state.Game and tonumber(state.Game.startTime)
		if not startTime then return name end
		local random = Random.new(startTime + player.UserId)
		return name..'-'..tostring(player:GetAttribute('Team') or '')..tostring(random:NextInteger(0, 9))..tostring(random:NextInteger(0, 9))
	end
	knitless.ctrlPut(h, 'StreamerModeController', streamer)

	local honor = {Name = 'HonorController'}
	function honor:honorPlayer(userId)
		local remote = knitless.ctrlRemote(h, 'TryGiveMatchHonorPoints')
		if not remote then
			return h.ctx.Promise.reject('TryGiveMatchHonorPoints is unavailable')
		end
		return remote:CallServerAsync({toPlayerId = userId})
	end
	knitless.ctrlPut(h, 'HonorController', honor)

	local function normalize(definition, attack)
		local result = type(definition) == 'table' and table.clone(definition) or {}
		local actions = type(result.controlActions) == 'table' and table.clone(result.controlActions) or {}
		if typeof(actions.Attack) ~= 'EnumItem' then
			actions.Attack = attack
		end
		result.controlActions = actions
		return result
	end
	local keybinds = {
		Name = 'KeybindLoadController',
		loadedKeybinds = {
			keyboard = normalize(nil, Enum.UserInputType.MouseButton1),
			gamepad = normalize(nil, Enum.KeyCode.ButtonR2)
		}
	}
	function keybinds:getKeybinds()
		return self.loadedKeybinds
	end
	function keybinds:waitForKeybinds()
		return self.loadedKeybinds
	end
	task.spawn(function()
		local ok, reply = pcall(function()
			return h.ctx.net:Get('RetrieveProfileDataKeybinds'):CallServer()
		end)
		if ok and type(reply) == 'table' then
			keybinds.loadedKeybinds = {
				keyboard = normalize(reply.keyboardKeybindDefinition, Enum.UserInputType.MouseButton1),
				gamepad = normalize(reply.gamepadKeybindDefinition, Enum.KeyCode.ButtonR2)
			}
		elseif not ok then
			knitless.ctrlLog(h, 'RetrieveProfileDataKeybinds failed: '..tostring(reply))
		end
	end)
	knitless.ctrlPut(h, 'KeybindLoadController', keybinds)

	local LOBBY = '@easy-games/lobby:shared/event/lobby-events@getEvents.Events'
	local queue = {Name = 'QueueController'}
	function queue:joinQueue(queueType)
		knitless.ctrlFire(h, LOBBY, 'joinQueue', {queueType = queueType})
	end
	function queue:leaveQueue()
		knitless.ctrlFire(h, LOBBY, 'leaveQueue')
	end
	knitless.ctrlPut(h, 'QueueController', queue)

	local userInput = {Name = 'UserInputController'}
	function userInput:getUserInputType()
		if h.inputService.GamepadEnabled then return 'GAMEPAD' end
		if h.inputService.TouchEnabled and not h.inputService.MouseEnabled then return 'MOBILE' end
		return 'PC'
	end
	local realInputType = userInput.getUserInputType
	knitless.ctrlListen(h, 'RequestUserInputType', function()
		if userInput.getUserInputType == realInputType then return end
		task.defer(function()
			local remote = knitless.ctrlRemote(h, 'SendUserInputType')
			if remote then
				pcall(remote.SendToServer, remote, {userInputType = userInput:getUserInputType()})
			end
		end)
	end)
	knitless.ctrlPut(h, 'UserInputController', userInput)

	knitless.ctrlPut(h, 'GuidedProjectileController', setmetatable({Name = 'GuidedProjectileController'}, {
		__index = function(self, key)
			if key ~= 'fireGuidedProjectile' then return nil end
			local remote = knitless.ctrlRemote(h, 'FireGuidedProjectile')
			if remote then
				rawset(self, key, remote)
			end
			return remote
		end
	}))

	knitless.ctrlPut(h, 'KillEffectController', {Name = 'KillEffectController', killEffects = {}})
end

--[[ BalloonController and NametagController stand-ins whose methods are watched (ctrlWatched), so that
swapping one out turns a game behaviour off through what the game itself reads. Replacing
deflateBalloon (Fly) sets BalloonPopDisabled, which the game reads when your balloons go up to
decide whether to offer the pop button; balloons already up keep theirs, and the inflate cooldown is
not checked. Replacing addGameNametag (NameTags, FPS Boost) sets NoNametag on every entity, which
the game's nametag controller watches: it takes the tag down and keeps it down. Putting the method
back clears only the marks set here, and the game brings the tags back. ]]
function knitless.ctrlWatchers(h)
	local lplr = h.lplr

	local balloonMethods = {}
	local function balloonSend(name)
		local viewmodel = h.ctx.controllers.ViewmodelController
		if viewmodel then
			pcall(viewmodel.playAnimation, viewmodel, h.animationType.FP_USE_ITEM)
		end
		local remote = knitless.ctrlRemote(h, name)
		if remote then
			remote:SendToServer()
		end
	end
	function balloonMethods:inflateBalloon()
		balloonSend('InflateBalloon')
	end
	function balloonMethods:deflateBalloon()
		balloonSend('DeflateBalloon')
	end
	local ownPopFlag = false
	knitless.ctrlPut(h, 'BalloonController', knitless.ctrlWatched({Name = 'BalloonController'}, balloonMethods, function(key, replaced)
		if key ~= 'deflateBalloon' then return end
		if replaced and lplr:GetAttribute('BalloonPopDisabled') == nil then
			ownPopFlag = true
			lplr:SetAttribute('BalloonPopDisabled', true)
		elseif not replaced and ownPopFlag then
			ownPopFlag = false
			lplr:SetAttribute('BalloonPopDisabled', nil)
		end
	end))

	local hidden = false
	local owned = setmetatable({}, {__mode = 'k'})
	local function hide(model)
		if typeof(model) == 'Instance' and model:GetAttribute('NoNametag') == nil then
			owned[model] = true
			model:SetAttribute('NoNametag', true)
		end
	end
	local function show(model)
		if typeof(model) == 'Instance' and owned[model] then
			owned[model] = nil
			model:SetAttribute('NoNametag', nil)
		end
	end
	local nametagMethods = {}
	function nametagMethods:addGameNametag(model)
		show(model)
	end
	function nametagMethods:removeGameNametag(model)
		hide(model)
	end
	knitless.ctrlPut(h, 'NametagController', knitless.ctrlWatched({Name = 'NametagController'}, nametagMethods, function(key, replaced)
		if key ~= 'addGameNametag' or replaced == hidden then return end
		hidden = replaced
		for _, model in h.collection:GetTagged('entity') do
			if hidden then
				hide(model)
			else
				show(model)
			end
		end
	end))
	h.ctx.clean(h.collection:GetInstanceAddedSignal('entity'):Connect(function(model)
		if hidden then
			task.defer(hide, model)
		end
	end))
end

--[[ AbilityController stand-in, after game-core's ability-controller. Cooldowns are known only when the
server sends them (abilityCooldownUpdate) or a dump carries AbilityMeta; otherwise an ability used
here waits half a second (LOCAL_GAP) before canUseAbility says yes again, so the polling modules do
not fire it every frame. Blocking status effects come from AbilityMeta, or silence alone without it.
enabledAbilities holds your kits' innate abilities (BedwarsKitMeta, PlayingAsKits and ExtraKit_
attributes) and any ability the server has reported for you; item abilities appear once reported. It
is rebuilt in place because modules keep the table they read. getExtraData of the game's ability
entries is not known, so useAbility sends only the data it is given; its token is the game's local
AbilityUsed handle and is unused. The game's cooldownController (its UI) is not offered. ]]
function knitless.ctrlAbility(h)
	local GAME_CORE = '@easy-games/game-core:shared/game-core-networking@getEvents.Events'
	local LOCAL_GAP = 0.5
	local lplr, workspace = h.lplr, h.workspace
	local cooldownUntil, observed = {}, {}
	local ability = {
		Name = 'AbilityController',
		enabledAbilities = {},
		blockedAbilities = {},
		abilityProgressValues = {}
	}

	local function metaOf(id)
		local meta = type(h.abilityMeta) == 'table' and h.abilityMeta[id] or nil
		return type(meta) == 'table' and meta or nil
	end

	local function rebuild()
		local kits = {}
		local list = lplr:GetAttribute('PlayingAsKits')
		if type(list) == 'string' then
			for _, kit in list:split(',') do
				kits[kit] = true
			end
		end
		for name, value in lplr:GetAttributes() do
			if value == true and name:sub(1, 9) == 'ExtraKit_' then
				kits[name:sub(10)] = true
			end
		end
		local enabled = {}
		for kit in kits do
			local meta = h.kitMeta[kit]
			for _, entry in (type(meta) == 'table' and type(meta.abilities) == 'table' and meta.abilities or {}) do
				if type(entry) == 'table' and entry.innate == true and entry.abilityId then
					enabled[entry.abilityId] = true
				end
			end
		end
		for id in observed do
			enabled[id] = true
		end
		local map = ability.enabledAbilities
		for id in map do
			if not enabled[id] then
				map[id] = nil
			end
		end
		for id in enabled do
			map[id] = map[id] or {abilityId = id}
		end
	end

	local function observe(id)
		if type(id) == 'string' and not observed[id] then
			observed[id] = true
			rebuild()
		end
	end

	function ability:getEnabledAbility(id)
		return self.enabledAbilities[id]
	end

	function ability:getEnabledAbilities()
		return self.enabledAbilities
	end

	function ability:getProgress(id)
		return self.abilityProgressValues[id]
	end

	function ability:isAbilityBlocked(id)
		local character = lplr.Character
		if not character then return false end
		local meta = metaOf(id)
		local effects = meta and type(meta.blockingStatusEffects) == 'table' and meta.blockingStatusEffects or {'silence'}
		for _, effect in effects do
			if character:GetAttribute('StatusEffect_'..tostring(effect)) ~= nil then
				return true
			end
		end
		return false
	end

	function ability:getBlockedAbilities()
		local blocked = {}
		for id in self.enabledAbilities do
			if self:isAbilityBlocked(id) then
				table.insert(blocked, id)
			end
		end
		return blocked
	end

	function ability:canUseAbility(id)
		if type(id) ~= 'string' or self:isAbilityBlocked(id) then return false end
		if (cooldownUntil[id] or 0) > workspace:GetServerTimeNow() then return false end
		local meta = metaOf(id)
		local progress = meta and meta.usableProgress
		if type(progress) == 'table' and (self.abilityProgressValues[id] or 0) < (progress.progressNeededPerUse or 0) then
			return false
		end
		return knitless.ctrlAlive(lplr.Character)
	end

	function ability:useAbility(id, _, data)
		if not self:canUseAbility(id) then return nil end
		local meta = metaOf(id)
		local cooldown = meta and meta.cooldown
		local duration = type(cooldown) == 'table' and tonumber(cooldown.duration) or LOCAL_GAP
		if knitless.ctrlFire(h, GAME_CORE, 'useAbility', id, data) then
			cooldownUntil[id] = workspace:GetServerTimeNow() + duration
		end
		return nil
	end

	knitless.ctrlListenFolder(h, GAME_CORE, 'abilityCooldownUpdate', function(id, seconds)
		if type(id) ~= 'string' then return end
		cooldownUntil[id] = workspace:GetServerTimeNow() + (tonumber(seconds) or 0)
		observe(id)
	end)
	knitless.ctrlListenFolder(h, GAME_CORE, 'abilityProgressUpdate', function(id, value)
		if type(id) ~= 'string' then return end
		ability.abilityProgressValues[id] = tonumber(value) or 0
		observe(id)
	end)
	knitless.ctrlListenFolder(h, GAME_CORE, 'abilityUsed', function(character, id)
		if character == lplr.Character then
			observe(id)
		end
	end)
	h.ctx.clean(lplr.AttributeChanged:Connect(function(name)
		if name == 'PlayingAsKits' or name:sub(1, 9) == 'ExtraKit_' then
			rebuild()
		end
	end))
	rebuild()
	return ability
end

--[[ Flamework's resolver for the ids the bootstrap and loader ask for: AbilityController,
KillFeedController (addToKillFeed draws nothing: the feed is the game's UI), PartyController
(leaveParty through lobby-events) and AppController (the registry's). Any other id goes to a
resolver an earlier slice put there, then to the stand-in controller of that name. ]]
function knitless.ctrlFlamework(h, ability)
	local PATH = 'ReplicatedStorage.rbxts_include.node_modules.@flamework.core.out'
	local LOBBY = '@easy-games/lobby:shared/event/lobby-events@getEvents.Events'
	local party = {Name = 'PartyController'}
	function party:leaveParty()
		knitless.ctrlFire(h, LOBBY, 'leaveParty')
	end
	local dependencies = {
		['@easy-games/game-core:client/controllers/ability/ability-controller@AbilityController'] = ability,
		['client/controllers/game/kill-feed/kill-feed-controller@KillFeedController'] = {
			Name = 'KillFeedController',
			addToKillFeed = function() end
		},
		['@easy-games/lobby:client/controllers/party-controller@PartyController'] = party
	}
	local previous = h.ctx.modules[PATH]
	previous = type(previous) == 'table' and type(previous.Flamework) == 'table' and previous.Flamework.resolveDependency or nil

	local Flamework = {}
	function Flamework.resolveDependency(id)
		local found = dependencies[id]
		if found ~= nil then return found end
		id = tostring(id)
		local name = id:match('@([%w_]+)$')
		if name == 'AppController' then
			local app = knitless.ctrlExport(h, 'ReplicatedStorage.rbxts_include.node_modules.@easy-games.game-core.out.client.controllers.app-controller', 'AppController')
			if app ~= nil then return app end
		end
		if type(previous) == 'function' then
			local ok, value = pcall(previous, id)
			if ok and value ~= nil then return value end
		end
		found = name and h.ctx.controllers[name]
		if found == nil then
			knitless.ctrlLog(h, 'Flamework has no stand-in for '..id)
		end
		return found
	end
	h.ctx.modules[PATH] = {Flamework = Flamework}
end

--[[ WindWalkerController (Zephyr) stand-in. The game's own controller keeps running and applies the
speed boost and air jumps, so this one only follows WindWalkerSpeedUpdate for the multiplier and orb
count, reset on respawn. doubleJumpActive stays false: AutoZephyr's air jumps lean on the game's
JumpHeightController, which has no stand-in here. setSpeedConversion is Speed's: with Knit, Speed
turns moveSpeedMultiplier into a constantSpeedMultiplier; here the SprintController stand-in reports
the boost that way (zephyrConstant). Nothing here writes WalkSpeed. ]]
function knitless.ctrlWindWalker(h)
	local controller = {Name = 'WindWalkerController', multiplier = 1, orbCount = 0, doubleJumpActive = false, speedConversion = false}
	local function publish()
		local sprint = h.ctx.controllers.SprintController
		if type(sprint) == 'table' then
			sprint.zephyrConstant = if controller.speedConversion and controller.multiplier > 1 then controller.multiplier else nil
		end
	end
	function controller:updateSpeed(multiplier)
		self.multiplier = tonumber(multiplier) or 1
		publish()
	end
	function controller:updateJump(orbCount)
		self.orbCount = tonumber(orbCount) or 0
	end
	function controller:setSpeedConversion(enabled)
		self.speedConversion = enabled == true
		publish()
	end
	knitless.ctrlListen(h, 'WindWalkerSpeedUpdate', function(update)
		if type(update) ~= 'table' then return end
		controller:updateSpeed(update.multiplier)
		controller:updateJump(update.orbCount)
	end)
	knitless.ctrlOnCharacter(h, function()
		controller:updateSpeed(1)
		controller:updateJump(0)
	end)
	knitless.ctrlPut(h, 'WindWalkerController', controller)
end

--[[ Kit controllers the payload calls without a guard, built on their remotes, and empty ones for the
kit controllers whose methods the payload only replaces: the game never calls those replacements, so
the modules that install them do nothing here instead of failing. SummonerClawHandController:attack
refuses while frozen and inside CLAW_COOLDOWN, then sends SummonerClawAttackRequest from your root
along the camera; the game's 0.1 s after equipping is not seen (enableTime stays 0), and the claw
swipe is not drawn. DragonSlayerController keeps dragonEmblems from UpdateDragonSlayerStacks for
your own punches. GrimReaperController.soulsByPosition is the models the game's controller tags
GrimSoul. SpiritAssassinController:useSpirit refuses while grounded or frosted, sends UseSpirit with
the orb's secret and removes the orb 0.7 s later, as the game does; the speed boost the game adds on
its side is not added. MapController reads the map bounds from Workspace.MapCFrames in block cells,
for the blocks slice and AutoTrap. The no-build regions come through Zap map data this file has no
reader for, so isInDenyRegion says no and the server decides. ]]
function knitless.ctrlKits(h, ability)
	local lplr, workspace = h.lplr, h.workspace

	knitless.ctrlPut(h, 'RavenController', {
		Name = 'RavenController',
		detonateRaven = function()
			ability:useAbility('raven_detonate')
		end
	})

	local balance = knitless.ctrlExport(h, 'ReplicatedStorage.TS.games.bedwars.kit.kits.summoner.summoner-kit-balance', 'SummonerKitBalance')
	local claw = {Name = 'SummonerClawHandController', lastAttackTime = 0, enableTime = 0}
	function claw:attack(itemType)
		local character = lplr.Character
		local root = character and character.PrimaryPart
		local camera = workspace.CurrentCamera
		if not (root and camera and knitless.ctrlAlive(character)) then return nil end
		if character:GetAttribute('StatusEffect_frozen') ~= nil then return nil end
		local cooldown = type(balance) == 'table' and tonumber(balance.CLAW_COOLDOWN) or 0.55
		local now = workspace:GetServerTimeNow()
		if now - self.enableTime < 0.1 or now - self.lastAttackTime < cooldown then return nil end
		self.lastAttackTime = now
		local look, position = camera.CFrame.LookVector, root.Position
		task.spawn(function()
			local visual = h.ctx.controllers.SummonerClawController
			if visual then
				pcall(visual.clawAttack, visual, lplr, position, look, itemType)
			end
		end)
		local remote = knitless.ctrlRemote(h, 'SummonerClawAttackRequest')
		if remote then
			remote:SendToServer({position = position, direction = look, clientTime = workspace:GetServerTimeNow()})
		end
		return nil
	end
	knitless.ctrlPut(h, 'SummonerClawHandController', claw)
	knitless.ctrlPut(h, 'SummonerClawController', {Name = 'SummonerClawController', clawAttack = function() end})

	local dragon = {Name = 'DragonSlayerController', dragonEmblems = {}}
	knitless.ctrlListen(h, 'UpdateDragonSlayerStacks', function(data)
		if type(data) ~= 'table' or data.kitUser ~= lplr.UserId or typeof(data.target) ~= 'Instance' then return end
		local emblems = dragon.dragonEmblems
		for target in emblems do
			if not target.Parent then
				emblems[target] = nil
			end
		end
		if data.stacks == 0 then
			emblems[data.target] = nil
			return
		end
		local entry = emblems[data.target] or {stackCount = 0}
		entry.stackCount = tonumber(data.stacks) or 0
		emblems[data.target] = entry
	end)
	knitless.ctrlPut(h, 'DragonSlayerController', dragon)

	local function collector(name, sound)
		return {Name = name, collectEntity = function(_, player, entity, collectableName)
			if player ~= lplr or typeof(entity) ~= 'Instance' then return nil end
			if sound then
				knitless.ctrlPlaySound(h, sound)
			end
			local remote = knitless.ctrlRemote(h, 'CollectCollectableEntity')
			if remote then
				remote:SendToServer({id = entity:GetAttribute('Id'), collectableName = collectableName})
			end
			return nil
		end}
	end
	knitless.ctrlPut(h, 'StarCollectorController', collector('StarCollectorController', h.gameSound.STAR_PICKUP))
	knitless.ctrlPut(h, 'JailorController', collector('JailorController'))

	knitless.ctrlPut(h, 'GrimReaperController', setmetatable({Name = 'GrimReaperController'}, {
		__index = function(_, key)
			if key ~= 'soulsByPosition' then return nil end
			return h.collection:GetTagged('GrimSoul')
		end
	}))

	local spirit = {Name = 'SpiritAssassinController'}
	function spirit:useSpirit(player, orb)
		local character = player and player.Character
		if character and (character:GetAttribute('StatusEffect_grounded') ~= nil or character:GetAttribute('StatusEffect_frosted') ~= nil) then
			return false
		end
		local remote = typeof(orb) == 'Instance' and knitless.ctrlRemote(h, 'UseSpirit')
		if not remote then return false end
		local ok, used = pcall(remote.CallServer, remote, {secret = orb:GetAttribute('SpiritSecret')})
		if ok and used then
			task.delay(0.7, function()
				if orb.Parent then
					orb:Destroy()
				end
			end)
		end
		return ok and used or false
	end
	knitless.ctrlPut(h, 'SpiritAssassinController', spirit)

	local map = {Name = 'MapController'}
	function map:getMapName()
		return workspace:GetAttribute('MapName')
	end
	function map:getCFrameWithoutYield(name)
		local folder = workspace:FindFirstChild('MapCFrames')
		local value = folder and folder:FindFirstChild(name)
		return value and value:IsA('CFrameValue') and value.Value or nil
	end
	function map:cacheMapBounds()
		local one = self:getCFrameWithoutYield('bound_1') or self:getCFrameWithoutYield('corner_1')
		local two = self:getCFrameWithoutYield('bound_2') or self:getCFrameWithoutYield('corner_2')
		if not (one and two) then return end
		local function cell(position)
			return Vector3.new(math.round(position.X / 3), math.round(position.Y / 3), math.round(position.Z / 3))
		end
		local a, b = cell(one.Position), cell(two.Position)
		self.minMapCorner = a:Min(b)
		self.maxMapCorner = a:Max(b)
	end
	function map:isInDenyRegion()
		return false
	end
	function map:isOutOfBounds(cell)
		if typeof(cell) ~= 'Vector3' then return false end
		if not (self.minMapCorner and self.maxMapCorner) then
			self:cacheMapBounds()
		end
		local low, high = self.minMapCorner, self.maxMapCorner
		if not (low and high) then return false end
		return cell.X < low.X or cell.X > high.X or cell.Y < low.Y or cell.Y > high.Y or cell.Z < low.Z or cell.Z > high.Z
	end
	knitless.ctrlPut(h, 'MapController', map)

	for name, fields in {
		CatController = {},
		CannonHandController = {},
		LaunchPadController = {lastLaunch = 0},
		TripleShotProjectileController = {overchargeStartTime = 0},
		FishingMinigameController = {},
		FishingRodController = {activeFishing = false},
		BlockKickerKitController = {},
		BatteryEffectsController = {liveBatteries = {}, getBatteryInfo = function() return nil end}
	} do
		fields.Name = name
		knitless.ctrlPut(h, name, fields)
	end
end

--[[ KnockbackUtil (knockback-util), called with '.': the game's formula, with the constants the
game registers through ConstantManager read off the module's attributes. applyKnockback is the
game's to call on its own hits; this one is called by nothing and does nothing. ]]
function knitless.ctrlKnockbackUtil(h)
	local defaults = {
		kbUpwardStrength = 10000,
		kbDirectionStrength = 11750,
		kbStandardMass = 300,
		nonGroundedHorizontalResistence = 0.6,
		nonGroundedVerticalResistence = 0.75
	}
	local moduleScript
	pcall(function()
		moduleScript = h.replicatedStorage.TS.damage['knockback-util']
	end)
	local constants = setmetatable({}, {__index = function(_, key)
		local value = moduleScript and moduleScript:GetAttribute('ConstantManager_'..tostring(key))
		return type(value) == 'number' and value or defaults[key]
	end})

	local util = {}
	function util.getDirection(from, to)
		if not to then return Vector3.zero end
		local away = Vector3.new(from.X, 0, from.Z) - Vector3.new(to.X or 0, 0, to.Z or 0)
		if away.Magnitude == 0 then return Vector3.zero end
		return away.Unit
	end
	function util.calculateKnockbackVelocity(direction, mass, options)
		if typeof(direction) ~= 'Vector3' or direction.Magnitude == 0 then return Vector3.zero end
		local vertical = type(options) == 'table' and options.vertical or 1
		local horizontal = type(options) == 'table' and options.horizontal or 1
		local velocity = (Vector3.new(0, constants.kbUpwardStrength * vertical, 0) + direction.Unit * (constants.kbDirectionStrength * horizontal))
			* ((tonumber(mass) or 0) / constants.kbStandardMass)
		local multiplier = h.workspace:GetAttribute('kbmultiplier')
		return velocity * (tonumber(multiplier) or 1) * 0.9
	end
	function util.calculateKnockbackVelocityRelative(part, mass, from, options)
		return util.calculateKnockbackVelocity(util.getDirection(part.Position, from), mass, options)
	end
	function util.applyKnockback() end
	function util.applyKnockbackDirection(_, mass, direction, options)
		return util.calculateKnockbackVelocity(direction, mass, options)
	end
	knitless.ctrlModule(h, 'ReplicatedStorage.TS.damage.knockback-util', {KnockbackUtil = util, KnockbackConstants = constants})
end

--[[ StatusEffectUtil (status-effect-util), called with ':': a status effect is the entity's
StatusEffect_<type> attribute (its expiry, -1 for none), with _stacks, _extraNumbers and
_extraBooleans beside it. ]]
function knitless.ctrlStatusEffectUtil(h)
	local util = {}
	function util:getAttributeName(effect)
		return 'StatusEffect_'..tostring(effect)
	end
	function util:getActive(entity, effect)
		if typeof(entity) ~= 'Instance' then return nil end
		local name = self:getAttributeName(effect)
		local expiry = entity:GetAttribute(name)
		if expiry == nil then return nil end
		local numbers, booleans = {}, {}
		local rawNumbers = entity:GetAttribute(name..'_extraNumbers')
		if type(rawNumbers) == 'string' then
			for _, part in rawNumbers:split(',') do
				local number = tonumber(part)
				if number then
					table.insert(numbers, number)
				end
			end
		end
		local rawBooleans = entity:GetAttribute(name..'_extraBooleans')
		if type(rawBooleans) == 'string' then
			for _, part in rawBooleans:split(',') do
				if part ~= '' then
					table.insert(booleans, part == '1')
				end
			end
		end
		return {
			statusEffect = effect,
			expireTime = if expiry == -1 then nil else expiry,
			stacks = entity:GetAttribute(name..'_stacks'),
			extraNumbers = if #numbers > 0 then numbers else nil,
			extraBooleans = if #booleans > 0 then booleans else nil
		}
	end
	function util:isActive(entity, effect)
		if typeof(entity) ~= 'Instance' then return false end
		return entity:GetAttribute(self:getAttributeName(effect)) ~= nil
	end
	function util:hasAnyActive(entity, effects)
		for _, effect in (type(effects) == 'table' and effects or {}) do
			if self:isActive(entity, effect) then return true end
		end
		return false
	end
	function util:getStacks(entity, effect)
		local active = self:getActive(entity, effect)
		return active and active.stacks or 0
	end
	function util:getAllActive(entity)
		local types = knitless.ctrlExport(h, 'ReplicatedStorage.TS.status-effect.status-effect-type', 'StatusEffectType')
		local list = {}
		for _, effect in (type(types) == 'table' and types or {}) do
			local active = self:getActive(entity, effect)
			if active then
				table.insert(list, active)
			end
		end
		return list
	end
	knitless.ctrlModule(h, 'ReplicatedStorage.TS.status-effect.status-effect-util', {StatusEffectUtil = util})
end

--[[ Builds every controller stand-in into ctx.controllers and the three modules into ctx.modules. Each
part runs on its own, so one that fails costs only its own controllers; the five the bootstrap waits
for and DamageIndicatorController are made empty if their part failed. The kit stand-ins are built
even without the ability tracker. ]]
function knitless.buildControllers(ctx)
	local h = knitless.ctrlShared(ctx)
	local function part(name, ...)
		local ok, result = pcall(knitless[name], h, ...)
		if not ok then
			ctx.log('controllers: '..name..' failed: '..tostring(result))
			return nil
		end
		return result
	end

	part('ctrlCamera')
	part('ctrlSword')
	part('ctrlSprint')
	part('ctrlCore')
	part('ctrlGeneral')
	part('ctrlWatchers')
	local ability = part('ctrlAbility')
	if ability then
		part('ctrlFlamework', ability)
	end
	part('ctrlKits', ability)
	part('ctrlWindWalker')
	part('ctrlKnockbackUtil')
	part('ctrlStatusEffectUtil')

	for _, name in {'SwordController', 'ProjectileController', 'BlockBreakController', 'MatchController',
		'ItemDropController', 'DamageIndicatorController'} do
		if ctx.controllers[name] == nil then
			ctx.log('controllers: '..name..' could not be built; an empty one stands in')
			ctx.controllers[name] = {Name = name, lastAttack = 0, lastSwing = 0}
		end
	end
end

-- Developer log: kept in the session log, printed in developer mode.
function knitless.log(message)
	bufferCall('print', 'bedwars.knitless', tostring(message))
end

--[[ Builds what the bootstrap runs on and returns what the Knit path gets: true and the Knit stand-in.
Each section builder fills ctx.modules[path] and ctx.controllers[name]; one that fails costs its own
stand-ins and is logged. It errors only where the bootstrap could not go on: no exec.net,
exec.Promise or exec.loadData from universal.lua, no remotes folders within 30 s, or a missing
export the bootstrap indexes past, calls or assigns into, named here since the bootstrap's own error
would name no module. The remotes folders and the remotes the stand-ins take share that 30 s budget:
on a fresh server the remotes replicate after their folder.

What can be made from ctx alone is filled in when a section left it out: both remotes clients the
way the game's modules export them, Flamework's resolver over the stand-ins (by the name after the
'@'), and a Zap whose events stay silent. The five controllers the bootstrap waits for and
DamageIndicatorController, which it indexes, get empty stand-ins when missing. BowConstantsTable is
read once from the projectile controller's ConstantManager_<key> attributes; nil leaves the
bootstrap's own defaults. OnStart resolves at once: everything is built before the bootstrap asks.
In developer mode knitless is shared.PistonwareKnitless until uninject. ]]
function knitless.build()
	assert(type(exec.net) == 'table' and type(exec.net.client) == 'function' and type(exec.Promise) == 'table'
		and type(exec.loadData) == 'function',
		'Knit is out of reach, and the layer that stands in for it needs exec.net, exec.Promise and exec.loadData from games/universal.lua')

	local deadline = os.clock() + 30
	local function waitPath(node, steps)
		for _, step in steps do
			node = node:FindFirstChild(step) or node:WaitForChild(step, math.max(deadline - os.clock(), 0.1))
			if not node then return nil end
		end
		return node
	end
	local netFolder = waitPath(replicatedStorage, {'rbxts_include', 'node_modules', '@rbxts', 'net', 'out', '_NetManaged'})
	local blockFolder = waitPath(replicatedStorage, {'rbxts_include', 'node_modules', '@easy-games', 'block-engine',
		'node_modules', '@rbxts', 'net', 'out', '_NetManaged'})
	assert(netFolder and blockFolder, 'the remotes folders (_NetManaged) did not appear within 30s')
	for _, name in {'SwordHit', 'MatchStateEvent', 'SetInvItem', 'Inventory/GetSlotState'} do
		waitPath(netFolder, {name})
	end
	for _, name in {'PlaceBlock', 'DamageBlock'} do
		waitPath(blockFolder, {name})
	end

	local ctx = {
		services = {
			Players = playersService,
			ReplicatedStorage = replicatedStorage,
			CollectionService = collectionService,
			RunService = runService,
			HttpService = httpService,
			Workspace = cloneref(game:GetService('Workspace')),
			UserInputService = inputService,
			TweenService = tweenService,
			Debris = cloneref(game:GetService('Debris')),
			SoundService = cloneref(game:GetService('SoundService'))
		},
		lplr = lplr,
		net = exec.net.client(netFolder),
		blockNet = exec.net.client(blockFolder),
		events = exec.net.events,
		Promise = exec.Promise,
		data = function(name)
			return exec.loadData('match', name)
		end,
		sharedData = function(name)
			return exec.loadData('shared', name)
		end,
		clean = function(item)
			slinky:clean(item)
		end,
		log = knitless.log,
		modules = {},
		controllers = {}
	}
	knitless.ctx = ctx

	for _, step in {'buildRegistry', 'buildStore', 'buildBlocks', 'buildControllers'} do
		local builder = knitless[step]
		local ok, err = false, 'not included'
		if type(builder) == 'function' then
			ok, err = xpcall(builder, errorTrace, ctx)
		end
		if not ok then
			bufferCall('error', 'bedwars.knitless', step..': '..tostring(err), {traceback = err})
		end
	end

	local modules, controllers = ctx.modules, ctx.controllers
	local remotesPath = 'ReplicatedStorage.TS.remotes'
	local blockRemotesPath = 'ReplicatedStorage.rbxts_include.node_modules.@easy-games.block-engine.out.shared.remotes'
	local flameworkPath = 'ReplicatedStorage.rbxts_include.node_modules.@flamework.core.out'
	local zapPath = 'PlayerScripts.TS.lib.network'
	modules[remotesPath] = modules[remotesPath] or {default = {Client = ctx.net}}
	modules[blockRemotesPath] = modules[blockRemotesPath] or {BlockEngineRemotes = {Client = ctx.blockNet}}
	modules[flameworkPath] = modules[flameworkPath] or {Flamework = {resolveDependency = function(id)
		return controllers[tostring(id):match('@([%w_]+)$') or '']
	end}}
	if modules[zapPath] == nil then
		local silent = {On = function()
			return function() end
		end}
		modules[zapPath] = setmetatable({}, {__index = function()
			return silent
		end})
		knitless.log('no Zap stand-in: damage, launch and block events stay silent')
	end
	for _, name in {'SwordController', 'ProjectileController', 'BlockBreakController', 'MatchController',
		'ItemDropController', 'DamageIndicatorController'} do
		if controllers[name] == nil then
			controllers[name] = {Name = name, lastAttack = 0, lastSwing = 0}
			bufferCall('warn', 'bedwars.knitless', 'no '..name..' stand-in; an empty one stands in')
		end
	end
	local missing = {}
	for path, keys in {
		['ReplicatedStorage.rbxts_include.node_modules.@easy-games.block-engine.out'] = {'BlockEngine'},
		['ReplicatedStorage.rbxts_include.node_modules.@easy-games.block-engine.out.client.placement.block-placer'] = {'BlockPlacer', 'new'},
		['ReplicatedStorage.TS.games.bedwars.team-upgrade.team-upgrade-meta'] = {'getTeamUpgradeMetaForQueue'},
		['ReplicatedStorage.TS.item.item-meta'] = {'items'},
		['PlayerScripts.TS.ui.store'] = {'ClientStore', 'changed'}
	} do
		local value = modules[path]
		for _, key in keys do
			value = type(value) == 'table' and value[key] or nil
		end
		if value == nil then
			table.insert(missing, path..' ('..table.concat(keys, '.')..')')
		end
	end
	assert(#missing == 0, 'no stand-in for '..table.concat(missing, ', '))

	pcall(function()
		local module = lplr.PlayerScripts.TS.controllers.global.combat.projectile['projectile-controller']
		local constants = {BeamGrowthMultiplier = 0.08, CameraMultiplier = 10, RelX = 0.8, RelY = -0.6, RelZ = 0, YTargetOffset = 0.05}
		for key in constants do
			local value = module:GetAttribute('ConstantManager_'..key)
			if type(value) == 'number' then
				constants[key] = value
			end
		end
		knitless.BowConstants = constants
	end)

	knitless.Knit = {
		Controllers = controllers,
		OnStart = function()
			return exec.Promise.resolve()
		end
	}
	if shared.PistonwareDeveloper == true then
		shared.PistonwareKnitless = knitless
		slinky:clean(function()
			if shared.PistonwareKnitless == knitless then
				shared.PistonwareKnitless = nil
			end
		end)
	end
	return true, knitless.Knit
end

--[[ require inside the bootstrap while knitless.active. A module's path is its full name, with the
"Players.<name>." in front of the local player's scripts left off; a path with no stand-in gets an
empty table, the same one each time, and one log line. ]]
function knitless.require(module)
	local path = typeof(module) == 'Instance' and module:GetFullName() or tostring(module)
	local prefix = 'Players.'..lplr.Name..'.'
	if path:sub(1, #prefix) == prefix then
		path = path:sub(#prefix + 1)
	end
	local export = knitless.ctx and knitless.ctx.modules[path]
	if export ~= nil then return export end
	if not knitless.empty[path] then
		knitless.empty[path] = {}
		knitless.log('no stand-in for '..path)
	end
	return knitless.empty[path]
end

--[[ ConsumeItem sent the way the game's ConsumeController sends it: StartConsume with the item when
eating starts, then ConsumeItem with the same item once the item's consumeTime has run. Callers ask
for ConsumeItem alone and get both. Knitless this is what Client.Get hands back for ConsumeItem; on
the Knit path AutoConsume gets it from bedwars.getConsumeRemote, which passes via: the remotes
client, Promise, log and settle to use.

The game eats only the item in hand (ConsumeController is a HandKnitController). A consume goes with
the item where it is first and, if the server refuses it while the hand stayed put, once more in
hand (knitless.consumeOnce); once that has worked, every consume holds the item. A try with the item
already in hand teaches nothing. One consume at a time, as the game's ClickHold allows; the busy
mark is a deadline, so a thread that never comes back cannot hold the rest. An item refused both
ways rests 5 s, twice as long for each refusal in a row, up to 30 s, so triggers that keep firing
and AutoConsume's look once a second do not keep swapping the hand. A status item (a potion, a
shield) waits via.settle (1 s on both paths) after it is eaten, until its status has come in; a heal
that needs missing health does not. A drink not started or dropped sets no rest. An eaten item
answers truthy: AutoConsume's speed potion tries again on a falsy answer. ]]
function knitless.consumeRemote(call, via)
	via = via or {net = knitless.ctx.net, Promise = knitless.ctx.Promise, log = knitless.log, settle = 1}
	knitless.consumeRefused = knitless.consumeRefused or setmetatable({}, {__mode = 'k'})
	local function consume(args)
		local item = type(args) == 'table' and args.item or nil
		if typeof(item) ~= 'Instance' or not item.Parent or os.clock() < (knitless.consumeBusy or 0)
			or os.clock() < (knitless.consumeRefused[item] or 0) then
			return nil
		end
		local meta = bedwars.ItemMeta and bedwars.ItemMeta[item.Name]
		local consumable = type(meta) == 'table' and meta.consumable or nil
		local seconds = type(consumable) == 'table' and tonumber(consumable.consumeTime) or 0.8
		local deadline = os.clock() + (seconds + 5) * 2
		knitless.consumeBusy = deadline
		local ok, result = pcall(function()
			local held = knitless.consumeHold == true
			local link = lplr.Character and lplr.Character:FindFirstChild('HandInvItem')
			local inHand = link ~= nil and link:IsA('ObjectValue') and link.Value == item
			local answer, eaten, moved, busy = knitless.consumeOnce(call, args, item, seconds, held, via)
			if busy then return nil end
			if not eaten and not held and item.Parent then
				local still = moved == 0
				via.log('ConsumeItem '..item.Name..(not still and ': not eaten, the hand moved; once more'
					or inHand and ': not eaten in hand; once more'
					or ': not eaten from the inventory; once more in hand'))
				local busyAgain
				answer, eaten, moved, busyAgain = knitless.consumeOnce(call, args, item, seconds, still, via)
				if busyAgain then return nil end
				if eaten and still and not inHand then
					knitless.consumeHold = true
					via.log('ConsumeItem: the server eats only what is in hand; every consume holds the item now')
				end
			end
			if eaten then
				knitless.consumeStrikes = 0
				if via.settle and item.Parent and not (type(consumable) == 'table' and consumable.requiresMissingHealth) then
					knitless.consumeRefused[item] = os.clock() + via.settle
				end
			else
				knitless.consumeStrikes = (knitless.consumeStrikes or 0) + 1
				local rest = math.min(5 * 2 ^ (knitless.consumeStrikes - 1), 30)
				knitless.consumeRefused[item] = os.clock() + rest
				via.log('ConsumeItem '..item.Name..': rests '..rest..' s')
			end
			return if eaten and not answer then true else answer
		end)
		if knitless.consumeBusy == deadline then
			knitless.consumeBusy = nil
		end
		if not ok then
			via.log('ConsumeItem '..item.Name..' failed: '..tostring(result))
			error(result, 0)
		end
		return result
	end
	return setmetatable({
		CallServer = function(_, args)
			return consume(args)
		end,
		CallServerAsync = function(_, args)
			return via.Promise.new(function(resolve)
				resolve(consume(args))
			end)
		end
	}, {__index = call})
end

--[[ Holds the hand for one drink: the autoconsume claim (genv.claimItem) and store.handLock, which every
swap path goes by. autoconsume ranks above the auras and kit abilities and below LongJump, AutoPearl
and a manual claim, which may take the hand mid-drink and end the hold (lock.owned). Other holders
mid-swap are waited out; one kept 3 s is taken as left behind. Returns the release (also
store.handRelease while held; release(true) drops the drink) and the lock, or nil and what has the
hand. The hold ends after `hard` seconds regardless. ]]
function knitless.holdHand(item, hard)
	local owner = genv.ItemOwner
	local pinned = (genv.JadeSlamLock and 'jade slam')
		or (genv.IsLongJumping and not genv.LongJumpFireballThrown and 'longjump') or nil
	if pinned then return nil, pinned end
	local stale = false
	if owner ~= nil and owner ~= 'none' and owner ~= 'autoconsume' and owner ~= 'projectileaura'
		and owner ~= 'killaura' then
		local now, seen = os.clock(), knitless.handBusy
		if not (seen and seen.owner == owner and seen.token == genv.ItemOwnerToken) then
			knitless.handBusy = {owner = owner, token = genv.ItemOwnerToken, since = now}
			return nil, owner
		elseif now - seen.since < 3 then
			return nil, owner
		end
		stale = owner ~= 'manual'
	end
	knitless.handBusy = nil
	local priorities = genv.ITEM_PRIORITY
	if type(priorities) == 'table' and priorities.autoconsume == nil then
		priorities.autoconsume = 2.5
	end
	local claimed, token = false, nil
	if type(genv.claimItem) == 'function' then
		local fine, ok, value = pcall(genv.claimItem, 'autoconsume')
		if fine and ok then
			claimed, token = true, value
		elseif stale then
			token = genv.ItemOwnerToken
		else
			return nil, tostring(genv.ItemOwner)
		end
	end
	local lock = {item = item, since = os.clock(), deadline = os.clock() + hard}
	if token ~= nil then
		lock.owned = function()
			return genv.ItemOwnerToken == token
		end
	end
	store.handLock = lock
	local function release(drop)
		if drop then lock.dropped = true end
		if not lock.ended then lock.ended = os.clock() end
		if store.handLock == lock then store.handLock = nil end
		if store.handRelease == release then store.handRelease = nil end
		if claimed then
			claimed = false
			if type(genv.releaseItem) == 'function' then pcall(genv.releaseItem, 'autoconsume', token) end
		end
	end
	store.handRelease = release
	task.delay(hard, release)
	return release, lock
end

--[[ One StartConsume and ConsumeItem for knitless.consumeRemote. Returns the server's answer, whether
the item was eaten (a truthy answer, or the item gone or fewer within half a second of it), how
often the hand moved between StartConsume and ConsumeItem, and true when the drink was not started
because another action has the hand, or was dropped because its hold was let go from outside (a
death, AutoConsume turned off). With hold, the item goes in hand first the way the game's equipItem
puts it there (HandInvItem, then SetInvItem, whose reply is waited for), and the previous hand goes
back after unless something else took the hand.

The hand is held (knitless.holdHand) from before StartConsume until just after the reply: the server
times a drink from StartConsume, and a swap in between (Killaura's sword, the aura's bow or raven)
spoils it. Putting the item back after such a swap is one more swap, so a moved hand is only
counted. A frame passes first, so a swap another module sent before the hold goes out ahead of
StartConsume, and because AutoConsume can be called from inside the character's AttributeChanged.
ConsumeItem goes a little past the item's time, as the game's own request does. The store's hand
lags HandInvItem by a Heartbeat, so the previous hand is read from the link. ]]
function knitless.consumeOnce(call, args, item, seconds, hold, via)
	local link = lplr.Character and lplr.Character:FindFirstChild('HandInvItem')
	if not (link and link:IsA('ObjectValue')) then link = nil end
	local previous = if link then link.Value else store.hand and store.hand.tool
	local swap = hold and link ~= nil and link.Value ~= item
	local release, taken = knitless.holdHand(item, seconds + (swap and 1.2 or 0.7))
	if not release then
		local key = tostring(taken)..'#'..tostring(genv.ItemOwnerToken)
		if knitless.handBusyLogged ~= key then
			knitless.handBusyLogged = key
			via.log('ConsumeItem '..item.Name..': not started, the hand is busy ('..tostring(taken)..')')
		end
		return nil, false, 0, true
	end
	knitless.handBusyLogged = nil
	local function hand(tool)
		link.Value = tool
		local fine, err = pcall(function()
			bedwars.Client:Get(remotes.EquipItem):CallServer({hand = tool or false})
		end)
		if not fine then
			via.log('ConsumeItem: SetInvItem failed: '..tostring(err))
		end
	end
	local moved, watch = 0, nil
	local ok, answer, eaten, dropped = pcall(function()
		task.wait()
		if swap then
			hand(item)
		end
		if link then
			local expect = link.Value
			watch = link.Changed:Connect(function(value)
				if value ~= expect then moved += 1 end
			end)
		end
		local amount = item:GetAttribute('Amount')
		local started = pcall(function()
			via.net:Get('StartConsume'):SendToServer({item = item})
		end)
		if started then
			task.wait(seconds + 0.1)
		else
			via.log('StartConsume could not be sent; ConsumeItem goes alone')
		end
		local dropping = taken.dropped == true
		local sent, reply, done = true, nil, false
		if not dropping then
			sent, reply = pcall(call.CallServer, call, args)
		end
		if watch then watch:Disconnect() end
		task.delay(0.1, release)
		local function gone()
			local left = item:GetAttribute('Amount')
			return item.Parent == nil or (type(amount) == 'number' and type(left) == 'number' and left < amount)
		end
		if not dropping then
			done = sent and (reply and true or gone())
			if sent and not done then
				local stop = os.clock() + 0.5
				repeat
					task.wait()
					done = gone()
				until done or os.clock() > stop
			end
		end
		if swap and link.Parent and (link.Value == item or link.Value == nil) then
			local back = previous ~= item and previous and previous.Parent and previous or nil
			if link.Value ~= back then
				task.spawn(hand, back)
			end
		end
		if not sent then error(reply, 0) end
		return reply, done, dropping
	end)
	if watch then watch:Disconnect() end
	if not ok then
		release()
		error(answer, 0)
	end
	if dropped then
		via.log('ConsumeItem '..item.Name..': dropped, the hand was let go mid-drink')
		return nil, false, moved, true
	end
	via.log('ConsumeItem '..item.Name..(swap and ' (in hand)' or '')..': '..tostring(answer)
		..(eaten and ', eaten' or ', not eaten')
		..string.format('; hand held %.2f s', (taken.ended or os.clock()) - taken.since)
		..(moved > 0 and ', the hand moved '..moved..'x during the drink' or ''))
	return answer, eaten, moved
end

--[[ SetInvItem during a jade slam, knitless with no namecall hook to hold it back (Xeno). The slam
lands only with the hammer still in hand, and where the hook is in, it swallows any other equip
until the landing; here the send stands back the same way while genv.JadeSlamHold (the hammer, and
when the hold lapses at the latest) is up. The caller gets what a swallowed send gives: nothing, or
a promise of nothing. Every other member is the remote's own, called on the remote. ]]
function knitless.jadeEquipGate(call)
	return setmetatable({}, {__index = function(_, key)
		local value = call[key]
		if type(value) ~= 'function' then return value end
		return function(_, ...)
			local hold = genv.JadeSlamHold
			if (key == 'CallServerAsync' or key == 'CallServer' or key == 'SendToServer') and type(hold) == 'table'
				and os.clock() < (tonumber(hold.expires) or 0) then
				local args = ...
				if not (type(args) == 'table' and args.hand == hold.tool) then
					traceEquip(type(args) == 'table' and args.hand or nil, 'EquipItem:'..key..' held back for a jade slam')
					if key == 'CallServerAsync' then return exec.Promise.resolve(nil) end
					return nil
				end
			end
			return value(call, ...)
		end
	end})
end

--[[ The Knit path below needs either Roblox's own require or a debug library that actually works
(exec.Debug: tested, not merely present); Solara and Xeno have neither. The owner can take this path
on a full executor too, to test it: developer mode plus shared.PistonwareForceKnitless. The stand-ins
are not the game's modules, so exec.Live is off with them, and fieldPatch and netGuard leave them alone. ]]
knitless.active = (not exec.Debug and not (exec.Require and exec.NativeRequire))
	or (shared.PistonwareForceKnitless == true and shared.PistonwareDeveloper == true)
--[[ Turns knitless mode on; a function so the bootstrap can also turn it on after the fact, when an
executor whose require re-runs module code makes KnitClient error. Stand-ins are not the game's
functions, so exec.Live and constant patching go off. Force mode answers as Solara does from here
on. store.selectedHand gives the item in the slot the game draws as selected, in store.hand's shape,
because store.hand here is HandInvItem, which every swap moves; nil with no tiles to read. It is
looked up ten times a second at most: Killaura asks every frame. ]]
local function activateKnitless()
	knitless.active = true
	exec.Live = false
	fieldPatch.constants = false
	if shared.PistonwareForceKnitless == true then
		exec.Debug, exec.Connections, exec.HookFunction = false, false, false
		exec.HookMetamethod, exec.FireSignal, exec.Full = false, false, false
	end
	store.selectedHand = function()
		local now, seen = os.clock(), knitless.selectedHandSeen
		if seen and now < seen.expires then return seen.hand end
		local item = knitless.ctx and knitless.hotbarSelectedItem(knitless.ctx)
		if item == nil or not (seen and seen.item == item) then
			local hand
			if item ~= nil then
				hand = {tool = nil, amount = 0, toolType = ''}
				if item then
					local meta = bedwars.ItemMeta and bedwars.ItemMeta[item.itemType] or {}
					hand.tool, hand.amount = item.tool, item.amount or 0
					hand.toolType = meta.sword and 'sword' or meta.block and 'block' or item.itemType:find('bow') and 'bow'
				end
			end
			seen = {item = item, hand = hand}
			knitless.selectedHandSeen = seen
		end
		seen.expires = now + 0.1
		return seen.hand
	end
end
if knitless.active then activateKnitless() end
if shared.SlinkySmoothBoot and os.clock() - lastBootYield > FRAME_BUDGET then
	task.wait()
	lastBootYield = os.clock()
end
local bootstrapOk, bootstrapError = callWithThreadFix(function()
	-- Knitless: every require below hands back the layer's stand-in for that module.
	local require = knitless.active and knitless.require or require
	local knitLoaded, knit
	--[[ Loads Knit, or builds the stand-in layer when knitless. KnitClient is required in a thread of
	its own (exec.isolatedRequire) because on Solara it errors, and a require that errors leaves its
	thread without executor capabilities; the 60 s matches the wait for Knit below. When Knit was
	expected to load but did not (an executor whose require re-runs module code), the stand-in layer
	takes over if universal.lua published it, rather than failing the whole payload. ]]
	if knitless.active then
		knitLoaded, knit = knitless.build()
	else
		knitLoaded, knit = exec.isolatedRequire(
			replicatedStorage.rbxts_include.node_modules['@easy-games'].knit.src.Knit.KnitClient, 60
		)
		if not knitLoaded and type(exec.net) == 'table' and type(exec.net.client) == 'function'
			and type(exec.Promise) == 'table' and type(exec.loadData) == 'function' then
			knitless.log('KnitClient did not load ('..tostring(knit)..'); using the stand-in layer instead')
			activateKnitless()
			require = knitless.require
			knitLoaded, knit = knitless.build()
		end
	end
	if not knitLoaded then
		error('KnitClient did not load: '..(knit ~= nil and tostring(knit) or 'still loading after 60s'), 0)
	end
	assert(type(knit) == 'table', 'KnitClient returned no controller table')
	local knitDeadline = os.clock() + 60
	assert(type(knit.OnStart) == 'function', 'Knit.OnStart is unavailable')
	local knitStarted = false
	local knitStartError
	local startup = knit.OnStart()
	assert(startup and type(startup.andThen) == 'function',
		'Knit.OnStart returned no startup promise')
	local observer = startup:andThen(function()
		knitStarted = true
	end, function(err)
		knitStartError = tostring(err)
	end)
	local function stopObserving()
		if observer and type(observer.cancel) == 'function' then
			pcall(function() observer:cancel() end)
		end
	end
	while true do
		if slinky.loaded == nil then
			stopObserving()
			error('Knit initialization canceled by unload', 0)
		end
		if knitStartError then
			stopObserving()
			error('Knit startup failed: '..knitStartError, 0)
		end
		local controllers = knit.Controllers
		if knitStarted and type(controllers) == 'table'
			and controllers.SwordController
			and controllers.ProjectileController
			and controllers.BlockBreakController
			and controllers.MatchController
			and controllers.ItemDropController then
			break
		end
		if os.clock() >= knitDeadline then
			stopObserving()
			error('Knit startup and controllers did not become ready within 60s', 0)
		end
		task.wait(0.1)
	end

	--[[ Knitless: no upvalues to read. The projectile controller's ConstantManager attributes stand in,
	read by knitless.build; the defaults below cover a miss. ]]
	local bowConstantsTable = knitless.active and knitless.BowConstants or nil
	for i = 1, knitless.active and 0 or 32 do
		local ok, value = pcall(debug.getupvalue, knit.Controllers.ProjectileController.enableBeam, i)
		if not ok then break end
		if type(value) == 'table' and type(rawget(value, 'RelX')) == 'number' then
			bowConstantsTable = value
			break
		end
	end
	bowConstantsTable = bowConstantsTable or {
		BeamGrowthMultiplier = 0.08,
		CameraMultiplier = 10,
		RelX = 0.8,
		RelY = -0.6,
		RelZ = 0,
		YTargetOffset = 0.05
	}

	local flamework = require(replicatedStorage['rbxts_include']['node_modules']['@flamework'].core.out).Flamework
	-- Knit started through require above, so this KnitClient is the game's own and require hands
	-- back the modules the game runs, not copies (exec.Live, which an early injection could not see).
	-- Not so with stand-ins: they are not the game's modules.
	if not knitless.active then
		exec.Live = true
	end
	local inventoryUtil = require(replicatedStorage.TS.inventory['inventory-util']).InventoryUtil
	local client = require(replicatedStorage.TS.remotes).default.Client
	namecallGuard.knitReadyAt = namecallGuard.knitReadyAt or os.clock()
	local effectUtil = require(replicatedStorage.TS.util.effect['effect-util']).EffectUtil
	local oldGet = client.Get

	--[[ The bedwars table: the game's modules, controllers and helpers the payload uses, resolved at
	boot through require, Flamework and Knit. Any other key is looked up in knit.Controllers on
	first use and kept. ItemSkinType, BedwarsKitSkin, BedwarsKitSkinMeta and getItemSkinMeta are for
	SkinChanger, and AudioManager, BalanceFile, FrostyGunMode, SoulBrokerConstants, TaliyahUtil and
	MageKitUtil for the ported kit modules, all from the paths the game's own controllers import
	them from. getInventory answers empty items and armor when inventoryUtil fails. ]]
	bedwars = setmetatable({
		AbilityController = flamework.resolveDependency('@easy-games/game-core:client/controllers/ability/ability-controller@AbilityController'),
		AdetundeUpgradeMeta = require(replicatedStorage.TS.games.bedwars.items['frosty-hammer']['frosty-hammer-upgrades']).FrostyHammerUpgradeMeta,
		AdetundeUtil = require(replicatedStorage.TS.games.bedwars.items['frosty-hammer']['frosty-hammer-util']).FrostyHammerUtil,
		AnimationType = require(replicatedStorage.TS.animation['animation-type']).AnimationType,
		AnimationUtil = require(replicatedStorage['rbxts_include']['node_modules']['@easy-games']['game-core'].out['shared'].util['animation-util']).AnimationUtil,
		AppController = require(replicatedStorage['rbxts_include']['node_modules']['@easy-games']['game-core'].out.client.controllers['app-controller']).AppController,
		BedBreakEffectMeta = require(replicatedStorage.TS.locker['bed-break-effect']['bed-break-effect-meta']).BedBreakEffectMeta,
		BedwarsKitMeta = require(replicatedStorage.TS.games.bedwars.kit['bedwars-kit-meta']).BedwarsKitMeta,
		BlackMarketeerBalance = require(replicatedStorage.TS.balance['black-marketeer-balance']).BlackMarketeerBalance,
		BuilderUtil = require(replicatedStorage.TS.games.bedwars.kit.kits.builder['builder-util']).BuilderUtil,
		JuggernautUtil = require(replicatedStorage.TS.balance['juggernaut-balance-file']).JuggernautUtil,
		BlockBreaker = knit.Controllers.BlockBreakController.blockBreaker,
		BlockController = require(replicatedStorage['rbxts_include']['node_modules']['@easy-games']['block-engine'].out).BlockEngine,
		BlockEngine = require(lplr.PlayerScripts.TS.lib['block-engine']['client-block-engine']).ClientBlockEngine,
		BlockPlacer = require(replicatedStorage['rbxts_include']['node_modules']['@easy-games']['block-engine'].out.client.placement['block-placer']).BlockPlacer,
		BowConstantsTable = bowConstantsTable,
		ClickHold = require(replicatedStorage['rbxts_include']['node_modules']['@easy-games']['game-core'].out.client.ui.lib.util['click-hold']).ClickHold,
		Client = client,
		ClientSyncEvents = require(lplr.PlayerScripts.TS['client-sync-events']).ClientSyncEvents,
		ClientConstructor = require(replicatedStorage['rbxts_include']['node_modules']['@rbxts'].net.out.client),
		ClientDamageBlock = require(replicatedStorage['rbxts_include']['node_modules']['@easy-games']['block-engine'].out.shared.remotes).BlockEngineRemotes.Client,
		CombatConstant = require(replicatedStorage.TS.combat['combat-constant']).CombatConstant,
		DamageIndicator = knit.Controllers.DamageIndicatorController.spawnDamageIndicator,
		DefaultKillEffect = require(lplr.PlayerScripts.TS.controllers.global.locker["kill-effect"].effects['default-kill-effect']),
		EffectUtil = effectUtil,
		EmoteType = require(replicatedStorage.TS.locker.emote['emote-type']).EmoteType,
		EnchantMeta = require(replicatedStorage.TS.enchant['enchant-meta']).EnchantMeta,
		GameAnimationUtil = require(replicatedStorage.TS.animation['animation-util']).GameAnimationUtil,
		getIcon = function(item, showinv)
			local itemmeta = bedwars.ItemMeta[item.itemType]
			return itemmeta and showinv and itemmeta.image or ''
		end,
		getInventory = function(plr)
			local suc, res = pcall(function()
				return inventoryUtil.getInventory(plr)
			end)
			return suc and res or {
				items = {},
				armor = {}
			}
		end,
		HudAliveCount = require(lplr.PlayerScripts.TS.controllers.global['top-bar'].ui.game['hud-alive-player-counts']).HudAlivePlayerCounts,
		ItemMeta = require(replicatedStorage.TS.item['item-meta']).items,
		ItemSkinType = require(replicatedStorage.TS.games.bedwars['item-skin']['item-skin-types']).ItemSkinType,
		BedwarsKitSkin = require(replicatedStorage.TS.games.bedwars['kit-skin']['bedwars-kit-skin']).BedwarsKitSkin,
		BedwarsKitSkinMeta = require(replicatedStorage.TS.games.bedwars['kit-skin']['bedwars-kit-skin-meta']).BedwarsKitSkinMeta,
		getItemSkinMeta = require(replicatedStorage.TS.games.bedwars['item-skin']['item-skin-meta']).getItemSkinMeta,
		KillEffectMeta = require(replicatedStorage.TS.locker['kill-effect']['kill-effect-meta']).KillEffectMeta,
		KillFeedController = flamework.resolveDependency('client/controllers/game/kill-feed/kill-feed-controller@KillFeedController'),
		Knit = knit,
		KnockbackUtil = require(replicatedStorage.TS.damage['knockback-util']).KnockbackUtil,
		AudioManager = require(replicatedStorage['rbxts_include']['node_modules']['@easy-games']['game-core'].out).AudioManager,
		BalanceFile = require(replicatedStorage.TS.balance['balance-file']).BalanceFile,
		FrostyGunMode = require(replicatedStorage.TS.games.bedwars.kit.kits['frosty-gun']['frosty-gun-util']).FrostyGunMode,
		SoulBrokerConstants = require(replicatedStorage.TS.games.bedwars.kit.kits['soul-broker']['soul-broker-constants']).SoulBrokerConstants,
		TaliyahUtil = require(replicatedStorage.TS.games.bedwars.kit.kits.taliyah['taliyah-util']).TaliyahUtil,
		MageKitUtil = require(replicatedStorage.TS.games.bedwars.kit.kits.mage['mage-kit-util']).MageKitUtil,
		NametagController = knit.Controllers.NametagController,
		PartyController = flamework.resolveDependency('@easy-games/lobby:client/controllers/party-controller@PartyController'),
		ProjectileMeta = require(replicatedStorage.TS.projectile['projectile-meta']).ProjectileMeta,
		PingController = require(lplr.PlayerScripts.TS.controllers.game.ping["ping-controller"]).PingController,
		QueryUtil = require(replicatedStorage['rbxts_include']['node_modules']['@easy-games']['game-core'].out).GameQueryUtil,
		QueueCard = require(lplr.PlayerScripts.TS.controllers.global.queue.ui['queue-card']).QueueCard,
		QueueMeta = require(replicatedStorage.TS.game['queue-meta']).QueueMeta,
		Roact = require(replicatedStorage['rbxts_include']['node_modules']['@rbxts']['roact'].src),
		RuntimeLib = require(replicatedStorage['rbxts_include'].RuntimeLib),
		SoundList = require(replicatedStorage.TS.sound['game-sound']).GameSound,
		SoundManager = resolveSoundManager(require),
		StatusEffectUtil = require(replicatedStorage.TS['status-effect']['status-effect-util']).StatusEffectUtil,
		StatusEffectMeta = require(replicatedStorage.TS['status-effect']['status-effect-type']).StatusEffectType,
		StatusEffectType = require(replicatedStorage.TS['status-effect']['status-effect-type']).StatusEffectType,
		Store = require(lplr.PlayerScripts.TS.ui.store).ClientStore,
		SummonerKitBalance = require(replicatedStorage.TS.games.bedwars.kit.kits.summoner['summoner-kit-balance']).SummonerKitBalance,
		SwordsConstants = require(replicatedStorage.TS.combat['combat-constant']).SwordsConstants,
		SyncEventPriority = require(replicatedStorage['rbxts_include']['node_modules']['@easy-games']['sync-event'].out).SyncEventPriority,
		TeamUpgradeMeta = require(replicatedStorage.TS.games.bedwars['team-upgrade']['team-upgrade-meta']).getTeamUpgradeMetaForQueue(),
		UILayers = require(replicatedStorage['rbxts_include']['node_modules']['@easy-games']['game-core'].out).UILayers,
		VisualizerUtils = require(lplr.PlayerScripts.TS.lib.visualizer['visualizer-utils']).VisualizerUtils,
		WeldTable = require(replicatedStorage.TS.util['weld-util']).WeldUtil,
		WinEffectMeta = require(replicatedStorage.TS.locker['win-effect']['win-effect-meta']).WinEffectMeta,
		ZapNetworking = require(lplr.PlayerScripts.TS.lib.network)
	}, {
		__index = function(self, ind)
			rawset(self, ind, knit.Controllers[ind])
			return rawget(self, ind)
		end
	})

	assert(type(bedwars.ItemMeta) == 'table', 'item-meta.items is unavailable')
	assert(type(bedwars.TeamUpgradeMeta) == 'table', 'queue team upgrades are unavailable')

	for name, remote in {
		AfkStatus = 'AfkInfo',
		AttackEntity = 'SwordHit',
		BeePickup = 'PickUpBee',
		CannonAim = 'AimCannon',
		CannonLaunch = 'LaunchSelfFromCannon',
		ConsumeBattery = 'ConsumeBattery',
		ConsumeItem = 'ConsumeItem',
		ConsumeSoul = 'ConsumeGrimReaperSoul',
		DepositPinata = 'DepositCoins',
		DragonBreath = 'DragonBreath',
		DragonEndFly = 'VoidDragonEndFlying',
		DragonFly = 'DragonFlap',
		DropItem = 'DropItem',
		EquipItem = 'SetInvItem',
		FireProjectile = 'ProjectileFire',
		GroundHit = 'GroundHit',
		GuitarHeal = 'PlayGuitar',
		HannahKill = 'HannahPromptTrigger',
		HarvestCrop = 'CropHarvest',
		KaliyahPunch = 'PlayerDragonPunched',
		MageSelect = 'LearnElementTome',
		MinerDig = 'DestroyPetrifiedPlayer',
		PickupItem = 'PickupItemDrop',
		PickupMetal = 'CollectCollectableEntity',
		ReportPlayer = 'ReportPlayer',
		ResetCharacter = 'ResetCharacter',
		SpawnRaven = 'SpawnRaven',
		SummonerClawAttack = 'SummonerClawAttackRequest',
		WarlockTarget = 'WarlockLinkTarget'
	} do
		remotes[name] = remote
	end

	--[[ Wraps the remotes client's Get, the path every remote request in the game goes through.
	AttackEntity records the hit's reach in store.attackReach and, with Reach or HitBoxes on, moves
	selfPosition toward the target to at most 14.399 studs from it. A trap remote gets a send that
	does nothing while TrapDisabler and that trap's toggle are on; trapDisabler is nil until its own
	run() block registers it, and stays nil if that block fails. SwordSwingMiss sends nothing with
	NoClickDelay on. Knitless with no namecall hook (Xeno), SetInvItem goes through
	knitless.jadeEquipGate while a jade slam hold is up; where the hook is in, it does this itself.
	In developer mode EquipItem sends that bypass switchItem are traced. Knitless, ConsumeItem
	becomes knitless.consumeRemote; the Knit path leaves it to bedwars.getConsumeRemote. ]]
	client.Get = function(self, remoteName)
		local call = oldGet(self, remoteName)

		if remoteName == remotes.AttackEntity then
			return {
				instance = call.instance,
				SendToServer = function(_, attackTable, ...)
					local selfpos = attackTable.validate.selfPosition.value
					local targetpos = attackTable.validate.targetPosition.value
					store.attackReach = ((selfpos - targetpos).Magnitude * 100) // 1 / 100
					store.attackReachUpdate = os.clock() + 1

					if reach.enabled or hitBoxes.enabled then
						attackTable.validate.raycast = attackTable.validate.raycast or {}
						attackTable.validate.selfPosition.value += CFrame.lookAt(selfpos, targetpos).LookVector * math.max((selfpos - targetpos).Magnitude - 14.399, 0)
					end

					return call:SendToServer(attackTable, ...)
				end
			}
		elseif trapDisabler and trapDisabler.enabled and trapToggles[remoteName] and trapToggles[remoteName].enabled then
			return {SendToServer = function() end}
		elseif remoteName == 'SwordSwingMiss' and slinky.modules and slinky.modules.NoClickDelay and slinky.modules.NoClickDelay.enabled then
			return {SendToServer = function() end}
		elseif remoteName == remotes.EquipItem and knitless.active and not namecallGuard.supported
			and type(genv.JadeSlamHold) == 'table' and os.clock() < (tonumber(genv.JadeSlamHold.expires) or 0) then
			return knitless.jadeEquipGate(call)
		elseif remoteName == remotes.EquipItem and shared.PistonwareDeveloper then
			return setmetatable({}, {__index = function(_, key)
				local value = call[key]
				if type(value) ~= 'function' then return value end
				return function(_, ...)
					if key == 'CallServerAsync' or key == 'CallServer' or key == 'SendToServer' then
						local args = ...
						local tool = type(args) == 'table' and args.hand or nil
						local fromSwitch = tool and switchItemRequested[tool]
						if not (fromSwitch and os.clock() - fromSwitch < 0.2) then
							traceEquip(tool, 'EquipItem:' .. key)
						end
					end
					return value(call, ...)
				end
			end})
		elseif knitless.active and remoteName == remotes.ConsumeItem then
			return knitless.consumeRemote(call)
		end

		return call
	end

	--[[ ConsumeItem for AutoConsume, on both paths: StartConsume, the item's consumeTime, then
	ConsumeItem, as the game's ConsumeController sends them (knitless.consumeRemote). ConsumeItem
	alone, with the item in the inventory, is what AutoConsume sent before, and it is not eaten any
	more. Knitless this is what Client.Get hands back. On the Knit path the game's own
	ConsumeController asks Client:Get for ConsumeItem when you eat, after its own StartConsume and
	consumeTime, so Client.Get leaves it alone there and AutoConsume asks here instead: the real
	remote, wrapped, with the game's remotes client and Promise. A status item eaten here settles
	for a second before it is eaten again (via.settle), as knitless. ]]
	bedwars.getConsumeRemote = function()
		if knitless.active then
			return client:Get(remotes.ConsumeItem)
		end
		return knitless.consumeRemote(oldGet(client, remotes.ConsumeItem), {
			net = client,
			Promise = bedwars.RuntimeLib.Promise,
			settle = 1,
			log = function(message)
				bufferCall('print', 'bedwars.consume', tostring(message))
			end
		})
	end

	local blockhealthbar = {blockHealth = -1, breakingBlockPosition = Vector3.zero}
	store.blockPlacer = bedwars.BlockPlacer.new(bedwars.BlockEngine, 'wool_white')

	local function getBlockHealth(block, blockpos)
		local blockdata = bedwars.BlockController:getStore():getBlockData(blockpos)
		return (blockdata and (blockdata:GetAttribute('1') or blockdata:GetAttribute('Health')) or block:GetAttribute('Health'))
	end

	local function getBlockHits(block, blockpos)
		if not block then return 0 end
		local breaktype = bedwars.ItemMeta[block.Name].block.breakType
		local tool = store.tools[breaktype]
		tool = tool and bedwars.ItemMeta[tool.itemType].breakBlock[breaktype] or 2
		return getBlockHealth(block, bedwars.BlockController:getBlockPosition(blockpos)) / tool
	end

	--[[ Published for the same reason breakBlock and placeBlock are: Breaker's 'Health' mode
	ranks the blocks around you and has to measure them the way the dig-spot ranking
	inside breakBlock already does, or the two disagree about what is cheapest. ]]
	bedwars.getBlockHits = getBlockHits

	--[[
		Pathfinding using a luau version of dijkstra's algorithm
		Source: https://stackoverflow.com/questions/39355587/speeding-up-dijkstras-algorithm-to-solve-a-3d-maze

		Walks outward through solid blocks from the target and answers with the cheapest cell
		that touches air -- the spot someone could stand at and put a tool on.

		Two things used to make that answer expensive, and together they are the 'the bed is
		wide open and Breaker sits there for three seconds before it starts' delay:

		* The queue was drained in insertion order, so nothing about the search ever knew it
		  was finished. Every call explored the whole mass of blocks connected to the target
		  -- on an island that is thousands of cells, and each one costs six getPlacedBlock
		  lookups plus a getBlockHits that reads block data back out of the game -- and only
		  then picked a winner out of everything it had seen.
		* Popping was table.remove(unvisited, 1), which shifts the entire array down one slot
		  every time. With a queue that long that is the quadratic half of the cost.

		Both go away by popping the cheapest node instead of the oldest. Breaking a block never
		costs a negative number of hits, so once an air-touching cell comes off a min-heap,
		nothing still queued behind it can be cheaper, and the search only has to finish the
		cost it is on rather than everything reachable. An exposed bed is answered on the first
		pop, at zero cost, instead of after a full sweep of everything joined to it.

		The search intentionally finishes that cost band. Ties are the
		normal case here, not an edge case -- every cell of a one-layer cover is the same one
		block from the target -- and which of them the answer names decides where the break
		actually lands. The nearest to the player wins it; see the loop.

		Nothing is cached by design. There used to be a
		table of answers keyed by target cell, from when a call cost a full sweep and paying it
		every pass was unthinkable. It has to go now that the cost is made of block HEALTH:
		health falls with every hit landed, changes nothing about the layout and fires no event
		anybody can listen for, so a cached cost is wrong the moment anyone starts breaking
		anything -- and 'which of these is cheapest' is precisely the question Breaker's Health
		mode is asking. A stale answer there means watching it chew on a full block while a
		one-hit block sits next to it. The invalidation grew a rule per bug (blocks placed,
		blocks broken, the player walking round to the other side) and this was simply the next
		one, so the table went instead. A search that stops at the first cost band is cheap
		enough to run every pass, and Breaker's pass is a quarter of a second long.
	]]
	--[[ A block the break code must treat as solid: never dug through, never struck.

	The generic NoBreak attribute is what calculatePath and frontOf used to test, and the
	Team<id>NoBreak one what breakBlock's last guard tested -- but neither covered our own
	bed in every case. The per-team attribute is not always there (a Team attribute that has
	not replicated yet reads as Team-1 and matches nothing), and breakBlock hits the DIG SPOT,
	which is routinely not the block the caller asked for: the path can route through a cell
	of our own bed, and Block Check redirects onto whatever is first on the eye line. That is
	the rare own-bed break.

	So a bed also asks the game, over its whole footprint, the same question isOwnBed in
	bedwars.lua asks: any cell we are not allowed to break makes it ours. The whole footprint
	because a bed half carrying a scarab hive reads as breakable on its own. Only beds pay for
	that; every other block is two attribute reads. ]]
	local function isProtectedBlock(block, worldpos)
		if not block then return false end
		if block:GetAttribute('NoBreak') then return true end
		if block:GetAttribute('Team'..(lplr:GetAttribute('Team') or -1)..'NoBreak') ~= nil then return true end
		if collectionService:HasTag(block, 'bed') then
			local cells
			pcall(function()
				local handler = bedwars.BlockController:getHandlerRegistry():getHandler(block.Name)
				cells = handler and handler:getContainedPositions(block)
			end)
			cells = cells or {bedwars.BlockController:getBlockPosition(worldpos)}
			for _, cell in cells do
				local ok, breakable = pcall(function()
					return bedwars.BlockController:isBlockBreakable({blockPosition = cell}, lplr)
				end)
				if ok and breakable == false then return true end
			end
		end
		return false
	end

	--[[ Dijkstra's algorithm over block cells (Source:
	https://stackoverflow.com/questions/39355587/speeding-up-dijkstras-algorithm-to-solve-a-3d-maze):
	walks outward through solid blocks from the target and answers the cheapest cell that touches
	air, the spot someone could stand at and put a tool on, with its cost and the path table. The
	cost is hits to break (hitResolver, getBlockHits by default); protected blocks and the target
	are never entered.

	The queue is a binary min-heap. Breaking never costs a negative number of hits, so once a node
	costs more than the answer in hand nothing still queued can beat it; the 0.0001 slack is for
	float noise, as two routes through the same blocks can add up in different orders. A cell can
	sit in the heap more than once from before its distance improved; the first pop is the good one.
	Ties are the normal case: every cell of a one-layer cover costs the same one block, and which
	one is named decides where the break lands, so the nearest to the player wins. A spot on the
	wrong side of a structure is one Block Check then has to walk all the way back. Nothing is
	cached: the cost is block health, which falls with every hit and fires no event. ]]
	local function calculatePath(target, blockpos, hitResolver, originOverride)
		local origin = originOverride
			or (entitylib.isAlive and entitylib.character.RootPart.Position or Vector3.zero)
		hitResolver = hitResolver or getBlockHits
		local visited, distances, path = {}, {[blockpos] = 0}, {}
		local heap, heapsize = {{0, blockpos}}, 1

		local function push(cost, node)
			heapsize += 1
			heap[heapsize] = {cost, node}
			local child = heapsize
			while child > 1 do
				local parent = child // 2
				if heap[parent][1] <= heap[child][1] then break end
				heap[parent], heap[child] = heap[child], heap[parent]
				child = parent
			end
		end

		local function pop()
			if heapsize == 0 then return nil end
			local top = heap[1]
			heap[1] = heap[heapsize]
			heap[heapsize] = nil
			heapsize -= 1

			local parent = 1
			while true do
				local left, right = parent * 2, parent * 2 + 1
				local smallest = parent
				if left <= heapsize and heap[left][1] < heap[smallest][1] then smallest = left end
				if right <= heapsize and heap[right][1] < heap[smallest][1] then smallest = right end
				if smallest == parent then break end
				heap[parent], heap[smallest] = heap[smallest], heap[parent]
				parent = smallest
			end

			return top
		end

		local best, bestcost, bestrange
		for _ = 1, 10000 do
			local node = pop()
			if not node then break end

			local cost, current = node[1], node[2]
			if best and cost > bestcost + 0.0001 then break end
			if visited[current] then continue end
			visited[current] = true

			local touchesair = false
			for _, side in sides do
				side = current + side
				if visited[side] then continue end

				local block = getPlacedBlock(side)
				if not block or block == target or isProtectedBlock(block, side) then
					if not block then
						touchesair = true
					end
					continue
				end

				local curdist = hitResolver(block, side) + cost
				if curdist < (distances[side] or math.huge) then
					distances[side] = curdist
					path[side] = current
					push(curdist, side)
				end
			end

			if touchesair then
				local range = (origin - current).Magnitude
				if not best or range < bestrange then
					best, bestcost, bestrange = current, cost, range
				end
			end
		end

		if best then
			return best, bestcost, path
		end
	end

	bedwars.calculateBreakPath = calculatePath

	--[[ Where does the line from the player to this dig spot first meet a block? That block is
	what someone standing here would actually hit swinging at it, and it is what has to come
	off before anything behind it can be reached. calculatePath calls a cell diggable when
	ANY of its six faces touches air, including the face underneath it or the one on the far
	side, so its answer on its own happily digs a covered bed straight through its cover.

		The code now marches cell by cell along the whole line. It used to hop one cell at a time along
	whichever axis dominated, which is blind in exactly the case that matters: a dig spot up
	on a mound has air beside it on that axis, so the very first hop found nothing, the walk
	stopped, and the spot reported itself as the thing in the way -- Block Check waving
	through a break into the middle of a structure with the wall in front of the player
	untouched. A march cannot miss it: the wall is on the line whether or not it happens to
	lie along the dominant axis.

	Done against the block store rather than with a raycast: blocks render through chunked
	geometry, so a ray reports chunk parts instead of the block the store hands back and
	cannot tell a target apart from whatever covers it.

	The march carries on past that first block to the spot, adding up the hits every block
	on the line will take, so clearShot can tell a line with one wool block left in it from
	one through end stone. The first block is still what gets returned.

	t runs 0 at the player to 1 at the dig spot: next* is the t at which the march crosses
	into the following cell on that axis, delta* is the t one whole cell costs there, and an
	axis the line does not move along never comes up for its turn. ]]
	local function boundary(index, component, delta)
		if delta == 0 then
			return 0, math.huge, math.huge
		end
		local step = delta > 0 and 1 or -1
		return step, ((((index + (step * 0.5)) * 3) - component) / delta), (3 / math.abs(delta))
	end

	--[[ Marches cell by cell along the line from your head to a dig spot and returns the first block on
	it (or the spot), whether the line is sealed, and the hits every block on it will take. From the
	head, not the root: the eye line decides what is reachable, and a root at foot height reads a
	floor block as cover. An unbreakable block anywhere on the line returns the spot, true and
	math.huge, so a sealed line is not mistaken for a clear one. A block with no health to read
	costs one hit. 30 studs of reach is ten cells, so the 40 steps cannot run out first. ]]
	local function frontOf(worldpos)
		if not entitylib.isAlive then return worldpos, false, 0 end

		local head = entitylib.character.Head
		local origin = (head and head.Position) or entitylib.character.RootPart.Position
		local direction = worldpos - origin
		local start, finish = bedwars.BlockController:getBlockPosition(origin), bedwars.BlockController:getBlockPosition(worldpos)
		local x, y, z = start.X, start.Y, start.Z

		local stepx, nextx, deltax = boundary(x, origin.X, direction.X)
		local stepy, nexty, deltay = boundary(y, origin.Y, direction.Y)
		local stepz, nextz, deltaz = boundary(z, origin.Z, direction.Z)

		local first, cost = nil, 0
		for _ = 1, 40 do
			if nextx > 1 and nexty > 1 and nextz > 1 then break end

			if nextx <= nexty and nextx <= nextz then
				x, nextx = x + stepx, nextx + deltax
			elseif nexty <= nextz then
				y, nexty = y + stepy, nexty + deltay
			else
				z, nextz = z + stepz, nextz + deltaz
			end

			local cell = Vector3.new(x, y, z)
			if cell == finish then break end

			local block = getPlacedBlock(cell * 3)
			if block then
				if isProtectedBlock(block, cell * 3) then return worldpos, true, math.huge end
				first = first or cell * 3
				local ok, hits = pcall(getBlockHits, block, cell * 3)
				cost += (ok and type(hits) == 'number') and hits or 1
			end
		end

		return first or worldpos, false, cost
	end

	--[[ The points inside a cell a line from the player is tried against, as clearShot below
	describes. ]]
	local function aimOffsets(origin, pos)
		local toward = origin - pos
		local offsets = {Vector3.zero, Vector3.new(0, 1.4, 0)}
		if math.abs(toward.X) > 0.01 then
			table.insert(offsets, Vector3.new(math.sign(toward.X) * 1.4, 0, 0))
		end
		if math.abs(toward.Z) > 0.01 then
			table.insert(offsets, Vector3.new(0, 0, math.sign(toward.Z) * 1.4))
		end
		if toward.Y < 0 then
			table.insert(offsets, Vector3.new(0, -1.4, 0))
		end
		return offsets
	end

	--[[ Is there a clear line onto this cell from ANY of its visible faces?

	frontOf aims at the cell's centre, and a line to the centre clips whatever sits beside the
	target even when a face of the target is in plain view -- a line down onto a bed grazes the
	ore block next to it, so Block Check sent the break into the ore and the bed waited. That
	is the ores-before-bed report. The centre, the top face and the faces turned toward the
	player are each tried, kept 1.4 studs in so every point still lies inside the same cell;
	any one of them with nothing in the way means the target itself can be hit.

	Returns the spot to strike and whether the way is sealed. When every line is blocked, the
	way in is the line that takes the fewest hits to clear, and its first block is what gets
	struck. The centre line used to decide alone: grazing the end stone over a hole it sent
	six hits there while the line onto the near face had one wool block left in it, and with
	a map wall on it it called the spot sealed though the top was only behind wool. Fewest
	hits also keeps a block that is part-way broken in front, it being the cheaper one. A
	line with anything unbreakable on it never clears and does not count; only when that is
	every line is the way sealed. ]]
	local function clearShot(pos)
		if not entitylib.isAlive then return pos, false end
		local head = entitylib.character.Head
		local origin = (head and head.Position) or entitylib.character.RootPart.Position
		local offsets = aimOffsets(origin, pos)

		local front, sealed, best
		for i, offset in offsets do
			local point = pos + offset
			local first, blocked, cost = frontOf(point)
			if first == point and not blocked then
				return pos, false
			end
			if i == 1 then
				front, sealed = first, blocked
			end
			if not blocked and (not best or cost < best) then
				front, sealed, best = first, false, cost
			end
		end
		return front, sealed
	end

	--[[ Does any of the lines clearShot tries onto pos pass through this cell, or within
	`margin` studs of it? A slab test against the cell's cube grown by the margin; the margin
	is what lets a line that wobbles off the cell's edge with the head still count. ]]
	local AXES = {'X', 'Y', 'Z'}
	local function inTheWay(cell, pos, margin)
		local head = entitylib.character.Head
		local origin = (head and head.Position) or entitylib.character.RootPart.Position
		local center, half = cell * 3, 1.5 + margin
		for _, offset in aimOffsets(origin, pos) do
			local point = pos + offset
			local tmin, tmax = 0, 1
			for _, axis in AXES do
				local from, delta = origin[axis], point[axis] - origin[axis]
				local lo, hi = center[axis] - half, center[axis] + half
				if math.abs(delta) < 1e-6 then
					if from < lo or from > hi then
						tmin = math.huge
						break
					end
				else
					local t1, t2 = (lo - from) / delta, (hi - from) / delta
					if t1 > t2 then t1, t2 = t2, t1 end
					tmin, tmax = math.max(tmin, t1), math.min(tmax, t2)
					if tmin > tmax then break end
				end
			end
			if tmin <= tmax then return true end
		end
		return false
	end

	--[[ Suppressing the place-block animation has to be re-entrancy safe.

	It used to save whatever sat in AnimationUtil.playAnimation, stub it, and put the saved
	value back when the placement finished. That is only correct for one placement at a
	time, and placements are never one at a time: blockPlacer:placeBlock ends in
	BlockEngineRemotes.Client:Get('PlaceBlock'):CallServer(...), which yields on the round
	trip, and Scaffold and Nuker both dispatch through task.spawn. So two overlap
	constantly:

	    A: saves the real function, installs the stub, yields in CallServer
	    B: saves THE STUB as "the real function", installs the stub, yields
	    A: resumes, restores the real function
	    B: resumes, restores the stub  <- permanent

	AnimationUtil.playAnimation is game-core's shared animation entry point, not a
	block-placement detail, so from that moment the client plays no animations at all --
	no swing, no place, no break -- until a rejoin. It bites hardest on mobile, where the
	framerate is low enough that a CallServer spans several placement ticks.

	One stored original and a depth count instead: the stub goes in when the first
	placement starts and comes out only when the last one finishes, in whatever order they
	happen to interleave. ]]
	local placeAnimOriginal, placeAnimDepth = nil, 0

	local function suppressPlaceAnimation()
		if not bedwars.AnimationUtil then return false end
		if placeAnimDepth == 0 then
			placeAnimOriginal = bedwars.AnimationUtil.playAnimation
			bedwars.AnimationUtil.playAnimation = function() end
		end
		placeAnimDepth += 1
		return true
	end

	local function restorePlaceAnimation()
		placeAnimDepth -= 1
		if placeAnimDepth > 0 then return end
		placeAnimDepth = 0
		if placeAnimOriginal then
			bedwars.AnimationUtil.playAnimation = placeAnimOriginal
			placeAnimOriginal = nil
		end
	end

	--[[ Places item at a world position through store.blockPlacer, without the place animation when
	animate is false. Knitless nothing is hushed: the stand-in placer plays no place animation, and
	a stub held for the round trip would hush every animation the layer plays meanwhile.
	restorePlaceAnimation runs before an error from placeBlock is rethrown, or the depth would never
	return to zero and the stub would stay. ]]
	bedwars.placeBlock = function(pos, item, animate)
		if not getItem(item) then return end

		store.blockPlacer.blockType = item
		local suppressed = animate == false and not exec.Knitless and suppressPlaceAnimation()

		local ok, result = pcall(function()
			return store.blockPlacer:placeBlock(bedwars.BlockController:getBlockPosition(pos))
		end)
		if suppressed then restorePlaceAnimation() end
		if not ok then error(result, 0) end
		return result
	end

	--[[ Sends one hit at a block through DamageBlock. Returns pos, path, target when effects is set, and
	a fourth value, true, whenever a hit was sent.

	The dig spot is ranked over every cell the block covers: a spot Block Check can strike directly
	first, then one on the block itself, then method ('Distance' ranks by distance from the player,
	anything else by fewest hits). blockcheck walks the chosen spot back to the first block the eye
	line meets, so cover comes off from the player's side; when a protected block (your own bed, a
	NoBreak block) seals every line nothing is sent. pin is a table the caller keeps between calls:
	the last struck cell is hit again while it stands, is in reach and is still in the way.
	allowHit(block, blockPosition) can turn down the block about to be hit. Nothing past 30 studs is
	hit, and never a block the game marks unbreakable for your team. autotool selects the tool's
	hotbar slot and equips it as well, since block damage is worked out from what the character
	actually holds (BlockEngine.calculateBlockDamage takes the player). Without autotool the tool is
	swapped in only when the last sword attack is more than 0.4 s back, which keeps the sword in
	hand mid-fight; with autotool it always is. ]]
	bedwars.breakBlock = function(block, effects, anim, customHealthbar, blockcheck, method, autotool, pin, allowHit)
		if lplr:GetAttribute('DenyBlockBreak') or not entitylib.isAlive then return end
		local handler = bedwars.BlockController:getHandlerRegistry():getHandler(block.Name)
		local cost, pos, target, path = math.huge
		local selfpos = entitylib.character.RootPart.Position
		local positions = (handler and handler:getContainedPositions(block)) or {block.Position / 3}
		local direct = false
		local open = false

		for _, v in positions do
			local cell = v * 3
			local dpos, dcost, dpath = calculatePath(block, cell)
			if dpos then
				local ddirect = dpos == cell
				local score = method == 'Distance' and (selfpos - dpos).Magnitude or dcost
				local dopen = true
				if blockcheck then
					local front, sealed = clearShot(dpos)
					dopen = (not sealed) and front == dpos
				end
				local better
				if pos == nil then
					better = true
				elseif dopen ~= open then
					better = dopen
				elseif ddirect ~= direct then
					better = ddirect
				else
					better = score < cost
				end
				if better then
					cost, pos, target, path, direct, open = score, dpos, cell, dpath, ddirect, dopen
				end
			end
		end

		local pinned = false
		if pin then
			if pin.block == block and pin.cell and pos and not (open and direct) then
				local spot = pin.cell * 3
				local part = getPlacedBlock(spot)
				if part and part == pin.part and not isProtectedBlock(part, spot)
					and (not allowHit or allowHit(part, pin.cell))
					and (entitylib.character.RootPart.Position - spot).Magnitude <= 30
					and (spot == pos or (not open and inTheWay(pin.cell, pos, 0.75))) then
					local front, sealed = spot, false
					if blockcheck then
						front, sealed = clearShot(spot)
					end
					if not sealed and front == spot then
						pos, path, pinned = spot, nil, true
					end
				end
			end
			if not pinned then
				pin.block, pin.cell, pin.part = nil, nil, nil
			end
		end

		if blockcheck and pos and not pinned then
			local front, sealed = clearShot(pos)
			if sealed then return end
			if front ~= pos then
				pos, path = front, nil
			end
		end

		if pos then
			if (entitylib.character.RootPart.Position - pos).Magnitude > 30 then return end
			local dblock, dpos = getPlacedBlock(pos)
			if not dblock then return end

			if isProtectedBlock(dblock, dpos * 3) then return end
			if allowHit and not allowHit(dblock, dpos) then return end

			local blockmeta = bedwars.ItemMeta[dblock.Name]
			blockmeta = blockmeta and blockmeta.block
			if blockmeta and (autotool or (workspace:GetServerTimeNow() - bedwars.SwordController.lastAttack) > 0.4) then
				local breaktype = blockmeta.breakType
				local tool = breaktype and (store.tools[breaktype] or getTool(breaktype))
				if not tool and autotool then
					tool = getBestBreakTool()
				end
				if tool and tool.tool then
					local slot
					if autotool then
						for i, v in store.inventory.hotbar or {} do
							if v.item and v.item.itemType == tool.itemType then
								slot = i - 1
								break
							end
						end
					end
					if slot then
						hotbarSwitch(slot)
					end
					switchItem(tool.tool)
				end
			end

			if blockhealthbar.blockHealth == -1 or dpos ~= blockhealthbar.breakingBlockPosition then
				blockhealthbar.blockHealth = getBlockHealth(dblock, dpos)
				blockhealthbar.breakingBlockPosition = dpos
			end

			if pin then
				pin.block, pin.cell, pin.part = block, dpos, dblock
			end

			bedwars.ClientDamageBlock:Get('DamageBlock'):CallServerAsync({
				blockRef = {blockPosition = dpos},
				hitPosition = pos,
				hitNormal = Vector3.FromNormalId(Enum.NormalId.Top)
			}):andThen(function(result)
				if slinky.loaded == nil or not bedwars.BlockController then return end
				if result then
					if pin and pin.cell == dpos and (result == 'cancelled' or result == 'failed') then
						pin.block, pin.cell, pin.part = nil, nil, nil
					end

					if result == 'cancelled' then
						store.damageBlockFail = os.clock() + 1
						return
					end

					if effects then
						local blockdmg = (blockhealthbar.blockHealth - (result == 'destroyed' and 0 or getBlockHealth(dblock, dpos)))
						customHealthbar = customHealthbar or bedwars.BlockBreaker.updateHealthbar
						customHealthbar(bedwars.BlockBreaker, {blockPosition = dpos}, blockhealthbar.blockHealth, dblock:GetAttribute('MaxHealth'), blockdmg, dblock)
						blockhealthbar.blockHealth = math.max(blockhealthbar.blockHealth - blockdmg, 0)

						if blockhealthbar.blockHealth <= 0 then
							bedwars.BlockBreaker.breakEffect:playBreak(dblock.Name, dpos, lplr)
							if bedwars.BlockBreaker.healthbarMaid then
								bedwars.BlockBreaker.healthbarMaid:DoCleaning()
							end
							blockhealthbar.breakingBlockPosition = Vector3.zero
						else
							bedwars.BlockBreaker.breakEffect:playHit(dblock.Name, dpos, lplr)
						end
					end

					if anim then
						local animation = bedwars.AnimationUtil:playAnimation(lplr, bedwars.BlockController:getAnimationController():getAssetId(1))
						bedwars.ViewmodelController:playAnimation(15)
						task.wait(0.3)
						animation:Stop()
						animation:Destroy()
					end
				end
			end)

			if effects then
				return pos, path, target, true
			end
			return nil, nil, nil, true
		end
	end

	--[[ Tells a caller this breakBlock reports a sent hit as its fourth value; one from before
	that returns nothing there whether it swung or not. ]]
	bedwars.breakBlockReportsHit = true
	--[[ And that it asks allowHit before every hit. One from before ignores the argument, so a
	caller that must keep a hit off somewhere checks this first. ]]
	bedwars.breakBlockAllowHit = true

	for _, v in Enum.NormalId:GetEnumItems() do
		table.insert(sides, Vector3.FromNormalId(v) * 3)
	end

	--[[ Coalesces inventory-change fan-out so a single shop purchase (which causes
	multiple bedwars.Store updates in one frame) only notifies the downstream
	listeners (AutoBuy / AutoConsume / AutoHotbar, each doing full inventory
	scans) once per frame instead of once per store dispatch. The synchronous
	store.tools/store.hand updates are kept inline so nothing reads stale data. ]]
	local invFireQueued = false
	local pendingAmount = false
	local function flushInventoryEvents()
		invFireQueued = false
		local amount = pendingAmount
		pendingAmount = false
		slinkyEvents.InventoryChanged:Fire()
		if amount then
			slinkyEvents.InventoryAmountChanged:Fire()
		end
	end

	--[[ Copies the parts of the game's Rodux state that changed into store: kit, match state, queue
	type, inventory, the tool cache and the held item. It must never throw: an error here aborts the
	store's change dispatch, and the game's own listeners after it miss that update. Inventory
	events are deferred to the end of the frame, so several dispatches in one frame reach each
	listener once. ]]
	local function updateStore(new, old)
		if new.Bedwars ~= old.Bedwars then
			store.equippedKit = new.Bedwars.kit ~= 'none' and new.Bedwars.kit or ''
		end

		if new.Game ~= old.Game then
			store.matchState = new.Game.matchState
			store.queueType = new.Game.queueType or 'bedwars_test'
		end

		if new.Inventory ~= old.Inventory then
			local newinv = (new.Inventory and new.Inventory.observedInventory or {inventory = {}})
			local oldinv = (old.Inventory and old.Inventory.observedInventory or {inventory = {}})
			store.inventory = newinv

			local invChanged    = newinv ~= oldinv
			local itemsChanged  = newinv.inventory.items ~= oldinv.inventory.items

			if itemsChanged then
				store.tools.sword = getSword()
				for _, v in {'stone', 'wood', 'wool'} do
					store.tools[v] = getTool(v)
				end
				pendingAmount = true
			end

			if newinv.inventory.hand ~= oldinv.inventory.hand then
				local currentHand, toolType = newinv.inventory.hand, ''
				if currentHand then
					local handData = bedwars.ItemMeta[currentHand.itemType] or {}
					toolType = handData.sword and 'sword' or handData.block and 'block' or currentHand.itemType:find('bow') and 'bow'
				end

				store.hand = {
					tool = currentHand and currentHand.tool,
					amount = currentHand and currentHand.amount or 0,
					toolType = toolType
				}
			end

			if invChanged and not invFireQueued then
				invFireQueued = true
				task.defer(flushInventoryEvents)
			end
		end
	end

	local storeChanged = bedwars.Store.changed:connect(updateStore)

	-- Developer trace: every change to what the character is actually holding, whoever
	-- made it. A swap logged here with no switchItem or EquipItem line just before it did
	-- not come from a request this client sent.
	if shared.PistonwareDeveloper then
		local function watchHand(char)
			local handInv = char:WaitForChild('HandInvItem', 10)
			if not handInv then return end
			slinky:clean(handInv:GetPropertyChangedSignal('Value'):Connect(function()
				local tool = handInv.Value
				print(string.format('[pistonware equip] t=%.3f hand changed -> %s',
					os.clock(), tool and tool.Name or 'nothing'))
			end))
		end
		if lplr.Character then task.spawn(watchHand, lplr.Character) end
		slinky:clean(lplr.CharacterAdded:Connect(watchHand))
	end
	updateStore(bedwars.Store:getState(), {})
	
	--[[ Deaths come over Zap now: EntityDeathEventZap hands its listeners one table with the fields
	the EntityDeathEvent remote had (entityInstance, fromEntity, finalKill, respawnDuration and the
	rest). A game build without that event still has the remote, which is then waited for as before. ]]
	local deathZap = bedwars.ZapNetworking.EntityDeathEventZap
	--[[ Forwards the game's match end, death, bed break, balloon, angel and grappling hook remotes to
	slinkyEvents, fired from the dispatch pump rather than inside the remote's own dispatch. Deaths
	come from EntityDeathEventZap when deathZap exists. WaitFor rejects a name the game's remotes do
	not define (without Knit, after a minute); that event then stays silent with a log line and the
	others still connect. ]]
	for _, event in {'MatchEndEvent', 'EntityDeathEvent', 'BedwarsBedBreak', 'BalloonPopped', 'AngelProgress', 'GrapplingHookFunctions'} do
		if not slinky.connections then return end
		local forward = store.dispatchSafe(function(...)
			slinkyEvents[event]:Fire(...)
		end)
		if event == 'EntityDeathEvent' and deathZap then
			slinky:clean(deathZap.On(forward))
		else
			local ok, err = pcall(function()
				bedwars.Client:WaitFor(event):andThen(function(connection)
					slinky:clean(connection:Connect(forward))
				end):catch(function(e)
					bufferCall('warn', 'bedwars.events', event..' not connected: '..tostring(e))
				end)
			end)
			if not ok then
				bufferCall('warn', 'bedwars.events', event..' not connected: '..tostring(err))
			end
		end
	end
	
	--[[ Re-fires EntityDamageEventZap as slinkyEvents.EntityDamageEvent with named fields, from the
	dispatch pump. disableDamageHighlight is the 13th argument. The arguments are named rather than
	picked with select, which walks them again for every field. ]]
	slinky:clean(bedwars.ZapNetworking.EntityDamageEventZap.On(store.dispatchSafe(function(entityInstance, damage, damageType, fromPosition, fromEntity, knockbackMultiplier, knockbackId, attackData, ...)
		slinkyEvents.EntityDamageEvent:Fire({
			entityInstance = entityInstance,
			damage = damage,
			damageType = damageType,
			fromPosition = fromPosition,
			fromEntity = fromEntity,
			knockbackMultiplier = knockbackMultiplier,
			knockbackId = knockbackId,
			attackData = attackData,
			disableDamageHighlight = select(5, ...)
		})
	end)))

	-- Keep confirmed Killaura telemetry at the normalized damage-event seam. The
	-- universal overlay can be enabled before this adapter finishes loading, so it
	-- must not depend on discovering this event from its own callback.
	slinky:clean(slinkyEvents.EntityDamageEvent.Event:Connect(function(damageTable)
		if damageTable and damageTable.fromEntity == lplr.Character and damageTable.entityInstance then
			entitylib.Performance:RecordKillauraHit(damageTable.entityInstance, os.clock())
		end
	end))

	--[[ cache projectile names we care about ]]
	local validProjectiles = {
		arrow = true,
		snowball = true,
		telepearl = true,
		pearl = true
	}
	--[[ Remembered per name. The launch handler below asks this of every child of workspace
	for every tracked launch in the server, and lowering each name again every time was a
	fresh string per child per shot. Names repeat, so the table stays small; the cap is only
	a backstop. ]]
	local trackedNames, trackedNameCount = {}, 0
	local function isTrackedProjectile(name)
		local cached = trackedNames[name]
		if cached ~= nil then return cached end
		local lower = tostring(name):lower()
		local result = validProjectiles[lower] or lower:find('telepearl', 1, true) ~= nil
		if type(name) == 'string' then
			if trackedNameCount >= 1024 then
				table.clear(trackedNames)
				trackedNameCount = 0
			end
			trackedNames[name] = result
			trackedNameCount += 1
		end
		return result
	end

	--[[ Turns ProjectileLaunchZap into slinkyEvents.ProjectileFired with the projectile instance, the
	launch time and the shooter's position and velocity at launch. The projectile is the first
	tracked workspace child within 25 studs of the origin, looked for in a task.defer after the
	launch. Runs from the dispatch pump, so neither the reads nor the defer happen inside Zap's
	dispatch. ]]
	slinky:clean(bedwars.ZapNetworking.ProjectileLaunchZap.On(store.dispatchSafe(function(origin, projectileType, tool, shooter)
		local launchedAt = os.clock()
		local shooterPosition, shooterVelocity
		pcall(function()
			local character = shooter
			if typeof(shooter) == 'Instance' and shooter:IsA('Player') then
				character = shooter.Character
			end
			local root = character and (character.PrimaryPart or character:FindFirstChild('HumanoidRootPart'))
			if root then
				shooterPosition = root.Position
				shooterVelocity = root.AssemblyLinearVelocity
			end
		end)
		task.defer(function()
			local lowerType = tostring(projectileType):lower()
			if isTrackedProjectile(lowerType) then
				for _, obj in ipairs(workspace:GetChildren()) do
					if isTrackedProjectile(obj.Name) then
						local root = obj:FindFirstChildWhichIsA("BasePart")
						if root and (root.Position - origin).Magnitude < 25 then
							slinkyEvents.ProjectileFired:Fire({
								origin = origin,
								projectile = obj,
								tool = tool,
								shooter = shooter,
								launchedAt = launchedAt,
								shooterPosition = shooterPosition,
								shooterVelocity = shooterVelocity
							})
							break
						end
					end
				end
			end
		end)
	end)))

	local projectileNames = {arrow = true, snowball = true}
	-- Deferred dispatch: run from the dispatch pump, so no thread is started inside ChildAdded
	slinky:clean(workspace.ChildAdded:Connect(store.dispatchSafe(function(child)
		if projectileNames[child.Name:lower()] then
			task.defer(function()
				local root = child:FindFirstChildWhichIsA("BasePart")
				if root then
					slinkyEvents.ProjectileFired:Fire({
						origin = root.Position,
						projectile = child,
						tool = nil,
						shooter = lplr.Character,
						launchedAt = os.clock(),
						shooterPosition = root.Position,
						shooterVelocity = root.AssemblyLinearVelocity,
						fallback = true
					})
				end
			end)
		end
	end)))
	
	--[[ Re-fires PlaceBlockEventZap and BreakBlockEventZap as slinkyEvents with blockRef.blockPosition
	and the player (the fifth argument), from the dispatch pump rather than inside Zap's dispatch.
	]]
	for _, event in {'PlaceBlockEvent', 'BreakBlockEvent'} do
		slinky:clean(bedwars.ZapNetworking[event..'Zap'].On(store.dispatchSafe(function(...)
			local data = {
				blockRef = {
					blockPosition = ...,
				},
				player = select(5, ...)
			}
			slinkyEvents[event]:Fire(data)
		end)))
	end

	--[[
		Second argument is whatever owns the cleanup, and `gui` is not a name that exists in
		this file -- so all three of these passed nil and registered no cleanup at all.

		Each call opens two CollectionService signals per tag. Nothing disconnected them, so an
		uninject left them live and mutating tables the rest of the script had let go of, and a
		reinject in the same server (the Reinject button, a profile reset, a config sync) simply
		added another set on top. Every other collection() call site in this file and in
		bedwars.lua passes the module that owns it; these are file-level, so they belong to slinky
		itself, which is what its Clean list is for.
	]]
	--[[ Every block in the map, which is tens of thousands of entries once one has loaded. The
	default removal is a table.find plus a shifting table.remove -- a walk of the whole list for
	each block that breaks, so one explosion taking out fifty blocks paid for fifty of them in a
	single frame. Each block's slot is kept alongside instead and a removal swaps the last entry
	into it. Everything that reads store.blocks only iterates it; none of it relies on the order.
	The same index also keeps a block from being listed twice. ]]
	local blockSlots = {}
	store.blocks = collection('block', slinky, function(tab, obj)
		if blockSlots[obj] then return end
		local slot = #tab + 1
		tab[slot] = obj
		blockSlots[obj] = slot
	end, function(tab, obj)
		local slot = blockSlots[obj]
		if not slot then return end
		blockSlots[obj] = nil
		if tab[slot] ~= obj then return end
		local last = #tab
		local moved = tab[last]
		tab[last] = nil
		if slot ~= last and moved ~= nil then
			tab[slot] = moved
			blockSlots[moved] = slot
		end
	end)
	slinky:clean(function()
		table.clear(blockSlots)
	end)
	store.shop = collection({'BedwarsItemShop', 'TeamUpgradeShopkeeper'}, slinky, function(tab, obj)
		table.insert(tab, {
			Id = obj.Name,
			RootPart = obj,
			Shop = obj:HasTag('BedwarsItemShop'),
			Upgrades = obj:HasTag('TeamUpgradeShopkeeper')
		})
	end)
	store.enchant = collection({'enchant-table', 'broken-enchant-table'}, slinky, nil, function(tab, obj, tag)
		if obj:HasTag('enchant-table') and tag == 'broken-enchant-table' then return end
		obj = table.find(tab, obj)
		if obj then
			table.remove(tab, obj)
		end
	end)

	-- Universal creates this library before the game-specific files. Keep the fallback here
	-- for cached or partial universal copies, and reject incomplete stale tables as well.
	sessioninfo = ensureSessionInfo()

	local kills = sessioninfo:AddItem('Kills')
	local beds = sessioninfo:AddItem('Beds')
	local wins = sessioninfo:AddItem('Wins')
	local games = sessioninfo:AddItem('Games')

	local mapname = 'Unknown'
	sessioninfo:AddItem('Map', 0, function()
		return mapname
	end, false)

	task.delay(1, function()
		games:Increment()
	end)

	task.spawn(function()
		pcall(function()
			repeat task.wait() until store.matchState ~= 0 or slinky.loaded == nil
			if slinky.loaded == nil then return end
			mapname = workspace:WaitForChild('Map', 5):WaitForChild('Worlds', 5):GetChildren()[1].Name
			mapname = string.gsub(string.split(mapname, '_')[2] or mapname, '-', '') or 'Blank'
		end)
	end)

	slinky:clean(slinkyEvents.BedwarsBedBreak.Event:Connect(function(bedTable)
		if bedTable.player and bedTable.player.UserId == lplr.UserId then
			beds:Increment()
		end
	end))

	slinky:clean(slinkyEvents.MatchEndEvent.Event:Connect(function(winTable)
		if (bedwars.Store:getState().Game.myTeam or {}).id == winTable.winningTeamId or lplr.Neutral then
			wins:Increment()
		end
	end))

	slinky:clean(slinkyEvents.EntityDeathEvent.Event:Connect(function(deathTable)
		local killer = playersService:GetPlayerFromCharacter(deathTable.fromEntity)
		local killed = playersService:GetPlayerFromCharacter(deathTable.entityInstance)
		if not killed or not killer then return end

		if killed ~= lplr and killer == lplr then
			kills:Increment()
		end
	end))

	--[[ Fetches the game's settings again when its own request came back broken. SettingsController asks
	once from KnitStart (GetSettings), and AudioVolumeController leaves the master bus at 0 until
	they arrive. A request still pending when the deferred __namecall hook goes in returns the
	RemoteFunction itself, the store's reducer errors on it, and the match has no sound. Settings
	still missing once the hook is in, or 15 s on, are fetched and handed over as KnitStart does,
	for up to 45 s. ]]
	task.spawn(function()
		local controller = not knitless.active and knit.Controllers.SettingsController
		if type(controller) ~= 'table' or type(controller.getSettingsEvent) ~= 'table' then return end
		local started, nextTry = os.clock(), 0
		while slinky.loaded ~= nil and controller.settings == nil and os.clock() - started < 45 do
			if (shared.PistonwareNamecallTop ~= nil or os.clock() - started > 15) and os.clock() >= nextTry then
				local ok, settings = pcall(function()
					return client:Get('GetSettings'):CallServer()
				end)
				nextTry = os.clock() + 3
				if slinky.loaded == nil or controller.settings ~= nil then return end
				if ok and type(settings) == 'table' then
					local stored, storeError = pcall(function()
						bedwars.Store:dispatch({type = 'SettingsUpdateAll', settings = settings})
					end)
					controller.settings = settings
					pcall(function()
						controller.getSettingsEvent:Fire(settings)
					end)
					task.wait(0.5)
					local audio = knit.Controllers.AudioVolumeController
					local how = 'waiters resumed'
					if type(audio) == 'table' and audio.hydrated ~= true and type(audio.applyAllSettings) == 'function' then
						how = pcall(function()
							audio:applyAllSettings(settings)
							audio.hydrated = true
						end) and 'audio buses set directly' or 'audio buses could not be set'
					end
					bufferCall('print', 'bedwars.settings', 'game settings fetched again ('..how..')'
						..(stored and '' or '; store: '..tostring(storeError)))
					return
				end
			end
			task.wait(0.5)
		end
		if slinky.loaded ~= nil and controller.settings == nil then
			bufferCall('warn', 'bedwars.settings', 'game settings still missing after 45s; game audio stays muted')
		end
	end)

	--[[ Loads the game's BedwarsShop for AutoBuy into bedwars.Shop and bedwars.ShopItems, retrying every
	0.5 s for up to 60 s. Delta and the knitless layer require it at the thread's own identity: on
	Delta bedwars-shop is already in the module cache (builder-util and the game's shop controllers
	import it), and knitless it is the layer's stand-in over the dumped ShopItems. Elsewhere the
	require runs at identity 2 and the old identity is put back; with no identity functions the item
	shop has to be open. Without require (Xeno) the shop cannot be read, so nothing is retried. An
	identity that cannot be restored stops the loop. ]]
	task.spawn(function()
		local deltaExecutor = store.deltaExecutor or knitless.active
		if not deltaExecutor and not (exec.Require or exec.Live) then
			bufferCall('error', 'bedwars.shop.initialize', 'require is unavailable on this executor')
			return
		end
		local deadline = os.clock() + 60
		local lastError = 'shop initialization has not completed'
		while slinky.loaded ~= nil do
			local oldIdentity
			local shop
			local canSetIdentity = not deltaExecutor
				and exec.Identity
				and type(getthreadidentity) == 'function'
				and type(setthreadidentity) == 'function'
			local ok, err = xpcall(function()
				if canSetIdentity then
					oldIdentity = getthreadidentity()
					assert(type(oldIdentity) == 'number', 'thread identity is unavailable')
					setthreadidentity(2)
				elseif not deltaExecutor then
					assert(bedwars.AppController
						and bedwars.AppController:isAppOpen('BedwarsItemShopApp'),
						'open the item shop to initialize AutoBuy on this executor')
				end

				shop = require(replicatedStorage.TS.games.bedwars.shop['bedwars-shop']).BedwarsShop
				assert(type(shop) == 'table' and type(shop.getShopItem) == 'function'
					and type(shop.ShopItems) == 'table', 'shop data is not ready')
				shop.getShopItem('iron_sword', lplr)
			end, errorTrace)

			if type(oldIdentity) == 'number' then
				local restored, restoreError = pcall(setthreadidentity, oldIdentity)
				if not restored then
					bufferCall('error', 'bedwars.shop.identity', tostring(restoreError))
					if slinky.loaded ~= nil then
						notif('AutoBuy', 'Shop initialization could not restore thread identity.', 10, 'alert')
					end
					return
				end
			end
			if slinky.loaded == nil then return end
			if ok then
				bedwars.Shop = shop
				bedwars.ShopItems = shop.ShopItems
				store.shopLoaded = true
				return
			end

			lastError = tostring(err)
			if os.clock() >= deadline then break end
			task.wait(0.5)
		end
		if slinky.loaded == nil then return end
		bufferCall('error', 'bedwars.shop.initialize', lastError)
		notif('AutoBuy', 'Shop initialization failed. Open the item shop and reinject; see the error log.', 10, 'alert')
	end)

	--[[ BedwarsShopController.randomlySelectedItems is the reply to the one
	BedwarsShopRequestRandomlySelectedItems call the controller makes in KnitStart, and the item shop's
	getShop iterates it on every open. When that reply comes back as something other than a list (the
	RemoteFunction itself, from a start-up call still waiting when the namecall hook went in, or nil from a swallowed call) every shop
	open errors at bedwars-shop:424. Watched for the first minute: anything but a table is logged, set to
	an empty list so the shop opens, and asked for again. ]]
	if not knitless.active then
		task.spawn(function()
			local deadline = os.clock() + 60
			while slinky.loaded ~= nil and os.clock() < deadline do
				local controller = knit.Controllers.BedwarsShopController
				local items = controller and controller.randomlySelectedItems
				if controller and type(items) ~= 'table' then
					local described = typeof(items)
					if described == 'Instance' then
						pcall(function()
							described = described..' '..items.ClassName..' '..items:GetFullName()
						end)
					else
						described = described..' '..tostring(items)
					end
					controller.randomlySelectedItems = {}
					bufferCall('warn', 'bedwars.shop.randomItems', 'BedwarsShopController.randomlySelectedItems was '
						..described..'; set to {} and requested again')
					local sent, err = pcall(function()
						client:Get('BedwarsShopRequestRandomlySelectedItems'):CallServerAsync():andThen(function(fresh)
							if type(fresh) == 'table' then
								controller.randomlySelectedItems = fresh
							end
							bufferCall('print', 'bedwars.shop.randomItems', 'asked again: got '..typeof(fresh)
								..(type(fresh) == 'table' and (' of '..#fresh) or ''))
						end):catch(function(e)
							bufferCall('error', 'bedwars.shop.randomItems', 'asked again: '..tostring(e))
						end)
					end)
					if not sent then
						bufferCall('error', 'bedwars.shop.randomItems', tostring(err))
					end
					return
				end
				task.wait(0.5)
			end
		end)
	end

	slinky:clean(function()
		client.Get = oldGet
		store.blockPlacer:disable()
		for _, v in slinkyEvents do
			v:Destroy()
		end
		table.clear(store.blockPlacer)
		table.clear(slinkyEvents)
		table.clear(bedwars)
		table.clear(store)
		table.clear(sides)
		table.clear(remotes)
		storeChanged:disconnect()
		storeChanged = nil
	end)
end)
if not bootstrapOk then
	bufferCall('error', 'bedwars.bootstrap', bootstrapError)
	return {
		PistonwareBootFailure = true,
		stage = 'bedwars.bootstrap',
		error = tostring(bootstrapError)
	}
end
--[[ Read by the modules below and by bedwars.lua (bw.exec): true while BedWars runs on the layer's
stand-ins, so what has none is left out. knitlessRequire is knitless.require, for their own
requires of game modules, which must not reach the executor's require there. ]]
exec.Knitless = knitless.active == true
exec.knitlessRequire = knitless.active and knitless.require or nil
end
--[[ Knitless (exec.Knitless): the modules below require game modules too. Theirs go to the layer's
stand-ins, never to the executor's require, which re-runs the module (on Solara one that errors strips
the thread it runs on) or has none (Xeno). ]]
local require = exec.Knitless and exec.knitlessRequire or require

for _, v in {'AntiRagdoll', 'TriggerBot', 'SilentAim', 'AutoRejoin', 'Rejoin', 'Disabler', 'Timer', 'ServerHop', 'MouseTP', 'MurderMystery', 'Swim', 'Jesus', 'Invisible', 'Desync', 'Waypoints', 'PlayerModel', 'Schematica'} do
	slinky:remove(v)
end
--[[ AimAssist
Turns your camera towards a nearby enemy while you hold a sword, and with Projectiles on while you
hold a bow or launcher, aiming where the shot will land. Click Aim means a swing in the last 0.4 s
for a sword and the attack button held for a launcher; on a phone a launcher always counts.

Aim Speed is held for a random 0.25-0.6 s before it is rolled again from its range, so the pull
speeds up and eases off like a hand instead of averaging to the middle. Projectile aim uses
prediction.SolveTrajectory with the ammo you carry (telepearls are skipped) and turns the camera
along the launch velocity, since a bow fires where the crosshair points. Airborne is read from
FloorMaterial, because a standing humanoid's vertical velocity keeps crossing SolveTrajectory's 0.01
threshold. The root is passed so its motion filter runs, and an arc IsTrajectoryClear rejects is not
aimed. First person is CameraPerspectiveController's perspective 0, with a camera within a stud of
its focus as the stand-in.

Shake is an angle, so it means the same at any range; 100% is shakemax, 5 degrees. It is a wander
re-rolled every 15-45 ms and chased with a dt-scaled lerp, plus per-frame noise, weighted 60/40. The
shake sits outside the aim lerp and last frame's is stripped before aiming: at the default speed the
camera closes only about 10% of the gap per frame, which would average a faster shake away. Models
named Falcon with no Player behind them are decoys and are ignored. ]]
run(function()
	local aimAssist
	local targets
	local sort
	local aimSpeedRange
	local distance
	local angleSlider
	local strafeIncrease
	local killauraTarget
	local clickAim
	local shake
	local targetPriority
	local firstPersonOnly
	local projectiles
	local projectileRange
	local speedRoll, speedRollAt = 0, 0
	local projectileRay = RaycastParams.new()
	projectileRay.FilterType = Enum.RaycastFilterType.Exclude

	local function aimSpeed()
		local now = os.clock()
		if now >= speedRollAt then
			speedRoll = aimSpeedRange:random()
			speedRollAt = now + 0.25 + math.random() * 0.35
		end
		return speedRoll
	end

	local function heldProjectile()
		local tool = store.hand.tool
		local meta = tool and bedwars.ItemMeta[tool.Name]
		local source = meta and meta.projectileSource
		if not source then return end

		local ammo
		if source.ammoItemTypes then
			for _, itemType in source.ammoItemTypes do
				if getItem(itemType) then
					ammo = itemType
					break
				end
			end
			if not ammo then return end
		end

		local projType = source.projectileType
		if type(projType) == 'function' then
			local ok, resolved = pcall(projType, ammo)
			projType = ok and resolved or nil
		end
		local projMeta = type(projType) == 'string' and projType ~= 'telepearl' and bedwars.ProjectileMeta[projType]
		if not projMeta then return end

		return {
			Speed = projMeta.launchVelocity or 100,
			Gravity = projMeta.gravitationalAcceleration or 196.2
		}
	end

	local function projectileDirection(ent, projectile)
		local head = entitylib.character.Head
		local root = ent.RootPart
		if not (head and root and prediction) then return end
		local origin = head.Position
		projectileRay.FilterDescendantsInstances = {lplr.Character, gameCamera}
		local airborne
		local humanoid = ent.Humanoid
		if typeof(humanoid) == 'Instance' then
			airborne = humanoid.FloorMaterial == Enum.Material.Air
		end
		local aim, flight = prediction.SolveTrajectory(origin, projectile.Speed, projectile.Gravity, root.Position,
			root.Velocity, workspace.Gravity, ent.HipHeight, nil, projectileRay, nil, nil, airborne, root)
		if not (aim and flight) then return end
		if not prediction.IsTrajectoryClear(origin, aim, projectile.Gravity, flight, projectileRay, root) then
			return
		end
		local direction = aim - origin
		if direction.Magnitude < 0.01 then return end
		return direction.Unit
	end

	local function inFirstPerson()
		local ok, perspective = pcall(function()
			return bedwars.CameraPerspectiveController:getCameraPerspective()
		end)
		if ok and type(perspective) == 'number' then
			return perspective == 0
		end
		return (gameCamera.CFrame.Position - gameCamera.Focus.Position).Magnitude <= 1
	end

	local shakemax = 5
	local rand = Random.new()
	local shakeoffset, shaketarget, shakestamp = Vector2.zero, Vector2.zero, 0
	local shakeapplied = CFrame.identity

	local function shakeRotation(dt)
		if shake.value <= 0 then
			shakeoffset, shaketarget = Vector2.zero, Vector2.zero
			return CFrame.identity
		end
		if os.clock() >= shakestamp then
			shakestamp = os.clock() + rand:NextNumber(0.015, 0.045)
			shaketarget = Vector2.new(rand:NextNumber(-1, 1), rand:NextNumber(-1, 1))
		end
		shakeoffset = shakeoffset:Lerp(shaketarget, math.min(dt * 45, 1))
		local noise = Vector2.new(rand:NextNumber(-1, 1), rand:NextNumber(-1, 1))
		local offset = (shakeoffset * 0.6) + (noise * 0.4)
		local amount = math.rad(shakemax * (shake.value / 100))
		return CFrame.Angles(offset.Y * amount, offset.X * amount, 0)
	end

	local function isFalconDecoy(ent)
		if not ent or ent.Player then return false end
		local name = ent.Character and ent.Character.Name
		return name ~= nil and (name == 'Falcon' or name:match('^Falcon%-') ~= nil)
	end

	local function findAimTarget(range)
		if killauraTarget.enabled and not range then return store.KillauraTarget end
		return priorityTarget({
			Range = range or distance.value,
			Part = 'RootPart',
			Wallcheck = targets.walls.enabled,
			Milo = targets.milo and targets.milo.enabled or nil,
			Players = targets.players.enabled,
			NPCs = targets.npcs.enabled,
			Sort = sortmethods[sort.value]
		}, targetPriority)
	end

	aimAssist = combat:module('AimAssist', {
		info = function()
			if not aimSpeedRange then return nil end
			local low, high = aimSpeedRange.min, aimSpeedRange.max
			return low == high and tostring(low) or low..'-'..high
		end,
		toggled = function(on)
			if not on then
				shakeapplied = CFrame.identity
				shakeoffset, shaketarget = Vector2.zero, Vector2.zero
			end
			if on then
				aimAssist:clean(runService.Heartbeat:Connect(function(dt)
					if not entitylib.isAlive or (firstPersonOnly.enabled and not inFirstPerson()) then return end

					local projectile
					if store.hand.toolType == 'sword' then
						if clickAim.enabled and (tick() - bedwars.SwordController.lastSwing) >= 0.4 then return end
					else
						projectile = projectiles.enabled and heldProjectile()
						if not projectile then return end
						if clickAim.enabled and not (inputService.TouchEnabled or inputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)) then return end
					end

					do
						local ent = findAimTarget(projectile and projectileRange.value or nil)

						if ent then
							if isFalconDecoy(ent) then return end
							local delta = (ent.RootPart.Position - entitylib.character.RootPart.Position)
							local localfacing = entitylib.character.RootPart.CFrame.LookVector * Vector3.new(1, 0, 1)
							local angle = math.acos(localfacing:Dot((delta * Vector3.new(1, 0, 1)).Unit))
							if angle >= (math.rad(angleSlider.value) / 2) then return end
							local direction = projectile and projectileDirection(ent, projectile)
							if projectile and not direction then return end
							targetinfo.Targets[ent] = tick() + 1
							local aimspeed = aimSpeed() + (strafeIncrease.enabled and (inputService:IsKeyDown(Enum.KeyCode.A) or inputService:IsKeyDown(Enum.KeyCode.D)) and 10 or 0)
							local base = gameCamera.CFrame * shakeapplied:Inverse()
							local goal = direction and base.p + direction or ent.RootPart.Position
							local aimed = base:Lerp(CFrame.lookAt(base.p, goal), aimspeed * dt)
							shakeapplied = shakeRotation(dt)
							gameCamera.CFrame = aimed * shakeapplied
						end
						end
					end))
				end
			end,
		about = 'Pulls your aim towards nearby enemies.\nWorks with swords, plus bows and launchers if turned on.'
	})
	aimAssist:divider('Aim')
	aimSpeedRange = aimAssist:range('Aim Speed', {
		label = 'Horizontal speed',
		min = 1,
		max = 20,
		defaultMin = 6,
		defaultMax = 6,
		about = 'How hard it pulls. Set a range and the pull varies within it.'
	})
	shake = aimAssist:slider('Shake', {
		label = 'Randomization',
		min = 0,
		max = 100,
		default = 0,
		suffix = '%',
		about = 'Adds a bit of random wobble to your aim.\n0 is dead centre, 100 is a full 5 degrees off.'
	})
	aimAssist:divider('Target')
	local methods = {'Damage', 'Distance'}
	for i in sortmethods do
		if not table.find(methods, i) then
			table.insert(methods, i)
		end
	end
	sort = aimAssist:dropdown('Target Mode', {
		label = 'Sort by',
		choices = methods
	})
	distance = aimAssist:slider('Distance', {
		label = 'Range',
		min = 1,
		max = 30,
		default = 30,
		suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
	angleSlider = aimAssist:slider('Max angle', {
		label = 'FOV',
		min = 1,
		max = 360,
		default = 70
	})
	aimAssist:divider('Conditions')
	clickAim = aimAssist:toggle('Click Aim', {
		label = 'Mouse pressed',
		default = true
	})
	targets = aimAssist:targets({
		players = true,
		walls = true,
		milo = false
	})
	aimAssist:divider('Extras')
	targetPriority = aimAssist:dropdown('Target Priority', {
		choices = {'Players first', 'NPCs first', 'Closest'},
		default = 'Players first'
	})
	killauraTarget = aimAssist:toggle('Use killaura target')
	strafeIncrease = aimAssist:toggle('Strafe increase')
	firstPersonOnly = aimAssist:toggle('First Person Only', {
		about = 'Only pulls your aim while the camera is in first person'
	})
	projectiles = aimAssist:toggle('Projectiles', {
		changed = function(callback)
			if projectileRange then
				projectileRange.row.Visible = callback
			end
		end,
		about = 'Also aims bows, crossbows and other launchers: ahead of a moving target\nand above it for the drop. With Click Aim, only while you are drawing.'
	})
	projectileRange = aimAssist:slider('Projectile Range', {
		min = 10,
		max = 150,
		default = 80,
		sub = true,
		visible = false,
		suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
end)
	
--[[ NoClickDelay
Lets you swing your sword as fast as you click. ]]
run(function()
	if exec.skip('NoClickDelay') then return end
	local old
	
	if exec.Knitless then
		exec.hide('NoClickDelay', "needs BedWars' Knit, which this executor cannot load")
		return
	end
	combat:module('NoClickDelay', {
		label = 'No Hit Delay',
		toggled = function(on)
			if on then
				old = bedwars.SwordController.isClickingTooFast
				bedwars.SwordController.isClickingTooFast = function(self)
					self.lastSwing = tick()
					return false
				end
			else
				bedwars.SwordController.isClickingTooFast = old
			end
		end,
		about = 'Lets you swing your sword as fast as you click.'
	})
end)
	
--[[ Reach
Raises the sword's hit distance (RAYCAST_SWORD_CHARACTER_DISTANCE becomes Range plus 2) and, with
Place Blocks, the range of the block selector used for placing. The server refuses a placement past
60 studs.

Place reach wraps getMouseInfo for mode 0 on the selectors of both block placers. A selector is
built once per placer, so while both placers are the same, fully patched objects a frame patches
nothing. Air Hit Chance wraps attackEntity, which checks the target against that constant again: a
failed roll while airborne runs that call with the original distance, so an out-of-range hit is
dropped. swingSwordAtMouse is not wrapped because other modules debug.setconstant it. The constant
is set from the module's state after the call, since the call may yield. Place Range's row follows
Place Blocks at creation as well, because its changed callback only runs on a change. ]]
run(function()
	if exec.skip('Reach') then return end
	if exec.Knitless then
		exec.hide('Reach', "needs BedWars' Knit, which this executor cannot load")
		return
	end
	local amount
	local placeBlocks
	local placeRange
	local originalSwordReach
	local patchedSelectors = {}
	local placeReachConnection

	local function copyOptions(options)
		local result = {}
		if type(options) == 'table' then
			for key, value in options do
				result[key] = value
			end
		end
		return result
	end

	local function patchSelector(selector)
		if not selector or patchedSelectors[selector] then return end

		local ok, original = pcall(function()
			return selector.getMouseInfo
		end)
		if not ok or type(original) ~= 'function' then return end

		local wrapper
		wrapper = function(self, mode, options)
			if placeBlocks and placeBlocks.enabled and mode == 0 then
				options = copyOptions(options)
				options.range = placeRange and placeRange.value or 18
			end
			return original(self, mode, options)
		end

		if pcall(function()
			selector.getMouseInfo = wrapper
		end) then
			patchedSelectors[selector] = {Original = original, Wrapper = wrapper}
		end
	end

	local function patchPlacer(placer)
		local ok, selector = pcall(function()
			local manager = placer and placer.clientManager
			return manager and manager:getBlockSelector()
		end)
		if ok then patchSelector(selector) end
		return not placer or (ok and selector ~= nil and patchedSelectors[selector] ~= nil)
	end

	local function patchPlaceReach()
		local covered = false
		callWithThreadFix(function()
			local storeCovered = patchPlacer(store.blockPlacer)
			local controller = bedwars.BlockPlacementController
			covered = patchPlacer(controller and controller.blockPlacer) and storeCovered
		end)
		return covered
	end

	local coveredStorePlacer, coveredControllerPlacer
	local placersCovered = false

	local function restorePlaceReach()
		local restore = {}
		for selector, data in patchedSelectors do
			table.insert(restore, {Selector = selector, Data = data})
		end
		for _, entry in restore do
			pcall(function()
				if entry.Selector.getMouseInfo == entry.Data.Wrapper then
					entry.Selector.getMouseInfo = entry.Data.Original
				end
			end)
			patchedSelectors[entry.Selector] = nil
		end
	end

	local function stopPlaceReach()
		if placeReachConnection then
			pcall(function() placeReachConnection:Disconnect() end)
			placeReachConnection = nil
		end
		restorePlaceReach()
		placersCovered = false
	end

	local function startPlaceReach()
		patchPlaceReach()
		if not placeReachConnection then
			placeReachConnection = runService.Heartbeat:Connect(function()
				if reach.enabled and placeBlocks and placeBlocks.enabled then
					local controller = bedwars.BlockPlacementController
					local storePlacer, controllerPlacer = store.blockPlacer, controller and controller.blockPlacer
					if not placersCovered or storePlacer ~= coveredStorePlacer or controllerPlacer ~= coveredControllerPlacer then
						coveredStorePlacer, coveredControllerPlacer = storePlacer, controllerPlacer
						placersCovered = patchPlaceReach()
					end
				else
					stopPlaceReach()
				end
			end)
			reach:clean(placeReachConnection)
		end
	end

	local airChance
	local oldAttackEntity, attackEntityHook
	local airRand = Random.new()

	local function isAirborne()
		local hum = entitylib.isAlive and entitylib.character.Humanoid
		return hum ~= nil and hum.FloorMaterial == Enum.Material.Air
	end

	local function hookAttackEntity()
		if oldAttackEntity then return end
		local original = bedwars.SwordController.attackEntity
		oldAttackEntity = original
		attackEntityHook = function(self, ...)
			local airChance = airChance:random()
			if airChance < 100 and isAirborne() and airRand:NextNumber(0, 100) > airChance then
				bedwars.CombatConstant.RAYCAST_SWORD_CHARACTER_DISTANCE = originalSwordReach or 14.4
				local results = table.pack(pcall(original, self, ...))
				bedwars.CombatConstant.RAYCAST_SWORD_CHARACTER_DISTANCE = reach.enabled and amount.value + 2 or originalSwordReach or 14.4
				if not results[1] then
					error(results[2], 0)
				end
				return table.unpack(results, 2, results.n)
			end
			return original(self, ...)
		end
		bedwars.SwordController.attackEntity = attackEntityHook
	end

	local function unhookAttackEntity()
		if not oldAttackEntity then return end
		if bedwars.SwordController.attackEntity == attackEntityHook then
			bedwars.SwordController.attackEntity = oldAttackEntity
		end
		oldAttackEntity, attackEntityHook = nil, nil
	end

	reach = combat:module('Reach', {
		info = function()
			return amount and tostring(amount.value) or nil
		end,
		toggled = function(on)
			if on then
				originalSwordReach = originalSwordReach or bedwars.CombatConstant.RAYCAST_SWORD_CHARACTER_DISTANCE
				bedwars.CombatConstant.RAYCAST_SWORD_CHARACTER_DISTANCE = amount.value + 2
				hookAttackEntity()
				if placeBlocks and placeBlocks.enabled then
					startPlaceReach()
				end
			else
				unhookAttackEntity()
				bedwars.CombatConstant.RAYCAST_SWORD_CHARACTER_DISTANCE = originalSwordReach or 14.4
				stopPlaceReach()
			end
		end,
		about = 'Lets you hit enemies from further away.\nCan also extend how far away you can place blocks.'
	})
	amount = reach:slider('Range', {
		label = 'Distance',
		min = 0,
		max = 18,
		default = 18,
		changed = function(val)
			if reach.enabled then
				bedwars.CombatConstant.RAYCAST_SWORD_CHARACTER_DISTANCE = val + 2
			end
		end,
		suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
	reach:divider('Extras')
	airChance = reach:range('Air Hit Chance', {
		min = 0,
		max = 100,
		defaultMin = 100,
		defaultMax = 100,
		about = 'Percent of swings that get the extra range while you are in the air.\nEach swing rolls its chance from this range.'
	})
	placeBlocks = reach:toggle('Place Blocks', {
		changed = function(callback)
			if placeRange and placeRange.row then
				placeRange.row.Visible = callback
			end
			if callback and reach.enabled then
				startPlaceReach()
			else
				stopPlaceReach()
			end
		end,
		about = 'Extends the distance used when selecting a block to place'
	})
	placeRange = reach:slider('Place Range', {
		min = 18,
		max = 60,
		default = 18,
		visible = false,
		sub = true,
		changed = function()
			if reach.enabled and placeBlocks and placeBlocks.enabled then
				patchPlaceReach()
			end
		end,
		suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
	if placeRange.row then
		placeRange.row.Visible = placeBlocks.enabled
	end
end)

--[[ NightmareEmote
Plays the Nightmare emote's effect, animation and looped sound on your character until your first
step, a jump, death or a respawn. The effect is set up the way the game's controller does it: every
part anchored, non-collidable and out of the query set, dropped 2 studs so the ring sits at your
feet. The sound is the emote's looped soundsOnBegin drone, parented to the torso so it goes with the
character. The module turns itself off one step after it turns on, since flipping it inside its own
toggled callback would re-enter the module's state change. ]]
run(function()
	local nightmareEmote
	local effect
	local track
	local sound
	local connections = {}
	local playing = false

	local function clearConnections()
		for _, connection in connections do
			pcall(function() connection:Disconnect() end)
		end
		table.clear(connections)
	end

	local function stopEmote()
		playing = false
		clearConnections()
		if track then
			pcall(function() track:Stop(0.25) end)
			track = nil
		end
		if sound then
			pcall(function() sound:Destroy() end)
			sound = nil
		end
		if effect then
			pcall(function() effect:Destroy() end)
			effect = nil
		end
	end

	local function neutralise(model)
		for _, descendant in model:GetDescendants() do
			if descendant:IsA('BasePart') then
				descendant.CanCollide = false
				descendant.CanQuery = false
				descendant.CanTouch = false
				descendant.Anchored = true
				pcall(function() bedwars.QueryUtil:setQueryIgnored(descendant, true) end)
			end
		end
	end

	local function spin(model, name, degrees, seconds)
		local part = model:FindFirstChild(name)
		if not part then return end
		tweenService:Create(part, TweenInfo.new(seconds, Enum.EasingStyle.Linear, Enum.EasingDirection.Out, -1), {
			Orientation = part.Orientation + Vector3.new(0, degrees, 0)
		}):Play()
	end

	local function playEmote()
		stopEmote()

		if not entitylib.isAlive then
			notif('Pistonware', 'You have to be alive to play an emote.', 3)
			return
		end

		local character = entitylib.character.Character
		local humanoid = character and character:FindFirstChildOfClass('Humanoid')
		local pivot = character and (character:FindFirstChild('LowerTorso') or entitylib.character.RootPart)
		if not (character and humanoid and pivot) then return end

		local template = replicatedStorage:FindFirstChild('Assets')
		template = template and template:FindFirstChild('Effects')
		template = template and template:FindFirstChild('NightmareEmote')
		if not template then
			notif('Pistonware', 'This place has no NightmareEmote effect to play.', 5)
			return
		end

		playing = true

		effect = template:Clone()
		neutralise(effect)
		effect.Parent = workspace
		pcall(function() effect:PivotTo(pivot.CFrame + Vector3.new(0, -2, 0)) end)
		spin(effect, 'Outer', 360, 1.5)
		spin(effect, 'Middle', -360, 12.5)

		pcall(function()
			sound = Instance.new('Sound')
			sound.Name = 'PistonwareNightmareEmote'
			sound.SoundId = 'rbxassetid://9188182911'
			sound.Looped = true
			sound.Volume = 0.5
			sound.Parent = pivot
			sound:Play()
		end)

		local animator = humanoid:FindFirstChildOfClass('Animator')
		if animator then
			pcall(function()
				local animation = Instance.new('Animation')
				animation.AnimationId = 'rbxassetid://9191822700'
				track = animator:LoadAnimation(animation)
				track.Looped = true
				track.Priority = Enum.AnimationPriority.Action
				track:Play(0.2)
			end)
		end

		connections[#connections + 1] = humanoid:GetPropertyChangedSignal('MoveDirection'):Connect(function()
			if playing and humanoid.MoveDirection.Magnitude > 0 then
				stopEmote()
			end
		end)
		connections[#connections + 1] = humanoid.Died:Connect(stopEmote)
		connections[#connections + 1] = humanoid.Jumping:Connect(function(active)
			if active then stopEmote() end
		end)
		connections[#connections + 1] = character.AncestryChanged:Connect(function(_, parent)
			if not parent then stopEmote() end
		end)
	end

	nightmareEmote = utility:module('NightmareEmote', {
		tab = 'Visual',
		toggled = function(on)
			if not on then return end

			playEmote()

			task.defer(function()
				if nightmareEmote.enabled then
					nightmareEmote:flip(nil, true)
				end
			end)
		end,
		about = 'Plays the Nightmare emote until you move.'
	})

	slinky:clean(function() stopEmote() end)
end)
	
--[[ Sprint
Keeps you sprinting: SprintController.stopSprinting is wrapped to start sprinting again straight
after, and a respawn sprints 0.1 s in. Knitless, turning off also clears attemptingSprint, because
the stand-in would sprint again on its next modifier change and letting go of shift never reaches
it. ]]
run(function()
	local sprint
	local old
	
	sprint = combat:module('Sprint', {
		tab = 'Move',
		toggled = function(on)
			if on then
				old = bedwars.SprintController.stopSprinting
				bedwars.SprintController.stopSprinting = function(...)
					local call = old(...)
					bedwars.SprintController:startSprinting()
					return call
				end
				sprint:clean(entitylib.Events.LocalAdded:Connect(function() 
					task.delay(0.1, function() 
						bedwars.SprintController:stopSprinting() 
					end) 
				end))
				bedwars.SprintController:stopSprinting()
			else
				bedwars.SprintController.stopSprinting = old
				bedwars.SprintController:stopSprinting()
				if exec.Knitless then
					bedwars.SprintController.attemptingSprint = false
				end
			end
		end,
		about = 'Automatically sprints for you.'
	})
end)
	
--[[ TriggerBot
Swings your sword at the CPS rate while the mouse is over an enemy within sword reach, or the game's
region check finds one. Reach is the held sword's attackRange, 14.4 studs when its item meta has
none; the hand is read defensively because a throw would end the loop with the module still on. ]]
run(function()
	local triggerBot
	local cps
	local selfAFK
	local rayParams = RaycastParams.new()

	triggerBot = combat:module('TriggerBot', {
		info = function()
			if not cps then return nil end
			local low, high = cps.min, cps.max
			return (low == high and tostring(low) or low..'-'..high)..' cps'
		end,
		toggled = function(on)
			if on then
				repeat
					local doAttack
					if not bedwars.AppController:isLayerOpen(bedwars.UILayers.MAIN) and not (selfAFK.enabled and isLocalAfk()) then
						if entitylib.isAlive and store.hand.toolType == 'sword' and bedwars.DaoController.chargingMaid == nil then
							local handTool = store.hand.tool
							local handMeta = handTool and bedwars.ItemMeta[handTool.Name]
							local attackRange = handMeta and handMeta.sword and handMeta.sword.attackRange
							rayParams.FilterDescendantsInstances = {lplr.Character}
	
							local unit = lplr:GetMouse().UnitRay
							local localPos = entitylib.character.RootPart.Position
							local rayRange = (attackRange or 14.4)
							local ray = bedwars.QueryUtil:raycast(unit.Origin, unit.Direction * 200, rayParams)
							if ray and (localPos - ray.Instance.Position).Magnitude <= rayRange then
								for _, ent in entitylib.List do
									doAttack = ent.Targetable and ray.Instance:IsDescendantOf(ent.Character) and (localPos - ent.RootPart.Position).Magnitude <= rayRange
									if doAttack then
										break
									end
								end
							end
	
							local regionTarget = bedwars.SwordController:getTargetInRegion(attackRange or 3.8 * 3, 0)
							if regionTarget then
								doAttack = true
							end
							if doAttack then
								bedwars.SwordController:swingSwordAtMouse()
							end
						end
					end
	
					task.wait(doAttack and 1 / cps.random() or 0.016)
				until not triggerBot.enabled
			end
		end,
		about = 'Swings your sword for you when an enemy is in reach.\nSet the click speed, and pause it while you are AFK.'
	})
	cps = triggerBot:range('CPS', {
		min = 1,
		max = 9,
		defaultMin = 7,
		defaultMax = 7
	})
	selfAFK = triggerBot:toggle('AFK check', {
		about = 'Goes idle after 30 seconds without any mouse or keyboard input'
	})
end)
	
--[[ Velocity
Cuts the knockback you take to the Horizontal and Vertical shares. With Knit,
KnockbackUtil.applyKnockback is wrapped and scales a copy of the knockback table: it is the one
EntityDamageEvent handed the knockback-controller, and writing into it can drop the whole hit. A
failed Chance roll or the AFK check passes the hit through whole; Only when targeting needs an enemy
within 50 studs.

Without Knit (Solara, Xeno) there is nothing to wrap. The game's KnockbackController turns
PlatformStand on for 65 ms and pushes the root with ApplyImpulse. This listens to the same hit on
EntityDamageEventZap, runs the controller's checks (your character, not fall damage, knockback not
disabled, one attacker at a time for 0.3 s, hits 50 ms apart), works out the push with
KnockbackUtil.calculateKnockbackVelocityRelative and applies the opposite impulse for the share to
take off. The listener stays for the whole match, so those checks keep the controller's state while
Velocity is off. Zap's remote is handled before PreSimulation, newest connection first, so this runs
just before the game's listener; the counter goes in once PlatformStand is on, so both impulses land
in the same physics step, and a hit with no PlatformStand within 0.1 s was not pushed and gets
nothing. A PlatformStand older than 45 ms may be an earlier hit's, so Heartbeat sums the next two or
three frames and takes back a counter that landed alone. With no Zap decoder running, a velocity
jump within two frames of PlatformStand and within 0.15 s of a health drop stands in for the hit.
Everything is polled, so no Changed handler writes. Developer mode traces each step of a hit to F9
and the log. ]]
run(function()
	local velocity
	local horizontal
	local vertical
	local chance
	local targetCheck
	local afkCheck
	local rand, old = Random.new()

	local noKnit = {lastAt = 0, attacker = nil, attackerUntil = 0, on = false, hits = 0, recent = {}}

	local function reduceThisHit()
		if rand:NextNumber(0, 100) > chance:random() or (afkCheck.enabled and isLocalAfk()) then
			return false
		end
		return (not targetCheck.enabled) or entitylib.EntityPosition({
			Range = 50,
			Part = 'RootPart',
			Players = true
		}) ~= nil
	end

	local function trace(text, ...)
		if shared.PistonwareDeveloper ~= true then return end
		local args = table.pack(...)
		for index = 1, args.n do
			local value = args[index]
			if typeof(value) == 'Vector3' then
				args[index] = string.format('(%.1f, %.1f, %.1f)', value.X, value.Y, value.Z)
			elseif type(value) == 'number' then
				args[index] = tostring(math.round(value * 100) / 100)
			else
				args[index] = tostring(value)
			end
		end
		bufferCall('print', 'bedwars.velocity', 'Velocity: '..string.format(text, table.unpack(args, 1, args.n)))
	end

	local function gameSkips(damageType, fromEntity, multiplier)
		if damageType == 1 then return 'fall damage' end
		if type(multiplier) == 'table' and multiplier.disabled then return 'knockback disabled' end
		local attacker = fromEntity and playersService:GetPlayerFromCharacter(fromEntity)
		local now = os.clock()
		if attacker and noKnit.attacker and noKnit.attacker ~= attacker.UserId and noKnit.attackerUntil >= now then
			return 'another player hit you less than 0.3 s ago'
		end
		local serverNow = workspace:GetServerTimeNow()
		if serverNow - noKnit.lastAt <= 0.05 then return 'under 50 ms after the last hit' end
		noKnit.lastAt = serverNow
		if attacker then
			noKnit.attacker, noKnit.attackerUntil = attacker.UserId, now + 0.3
		end
		return nil
	end

	local function watchFrames(job, check)
		local stand = noKnit.stand
		job.frame, job.sum, job.fall, job.changes, job.check = 0, Vector3.zero, 0, {}, check
		job.prior = stand and stand.sum or noKnit.change or Vector3.zero
		job.priorFall = stand and stand.fall or workspace.Gravity * (noKnit.dt or 0)
		noKnit.pending = job
	end

	local function applyCounter(job, check, how)
		job.root:ApplyImpulse(job.impulse)
		watchFrames(job, check)
		trace('hit %s: counter in %s', job.hit, how)
	end

	local function pushAlreadyIn(push)
		local limit = push.Magnitude / 3
		for _, frame in noKnit.recent do
			if math.min((frame.change - push).Magnitude, (frame.change + Vector3.new(0, frame.fall, 0) - push).Magnitude) < limit then
				return true
			end
		end
		return false
	end

	local function onHitWithoutKnit(entity, damage, damageType, fromPosition, fromEntity, multiplier, knockbackId)
		local character = lplr.Character
		local root = character and entity == character and character.PrimaryPart
		if not root then return end
		local skipped = gameSkips(damageType, fromEntity, multiplier)
		if not (noKnit.on and velocity.enabled) then return end
		noKnit.hits += 1
		local hit = noKnit.hits
		local options = type(multiplier) == 'table' and multiplier or {}
		trace('hit %s: %s damage, type %s, from %s, knockback x%s/x%s, id %s: %s', hit, damage, damageType,
			fromEntity and fromEntity.Name or 'nothing', options.horizontal or 1, options.vertical or 1, knockbackId,
			skipped and 'the game skips it ('..skipped..')' or 'the game pushes you')
		if skipped then return end

		local util = bedwars.KnockbackUtil
		local position = fromPosition
		if position == nil and fromEntity and fromEntity.PrimaryPart then
			position = fromEntity.PrimaryPart.Position
		end
		local mass = root.AssemblyMass
		if not position or not (mass > 0) or not (util and util.calculateKnockbackVelocityRelative) then
			trace('hit %s: nothing to counter (%s)', hit, not position and 'no hit position'
				or not (mass > 0) and 'no mass' or 'no KnockbackUtil')
			return
		end
		local push = util.calculateKnockbackVelocityRelative(root, mass, position, multiplier)
		local landedAlready = pushAlreadyIn(push / mass)
		table.clear(noKnit.recent)
		local reduce = reduceThisHit()
		local keepFlat, keepUp = horizontal.value / 100, vertical.value / 100
		local impulse = reduce and Vector3.new(push.X * (keepFlat - 1), push.Y * (keepUp - 1), push.Z * (keepFlat - 1)) or Vector3.zero
		local humanoid = character:FindFirstChildOfClass('Humanoid')
		local job = {root = root, humanoid = humanoid, hit = hit, impulse = impulse, counter = impulse / mass,
			net = (push + impulse) / mass}
		noKnit.waiting = nil
		if impulse.Magnitude < 0.001 then
			trace('hit %s: the game push %s is left whole (%s)', hit, push / mass,
				reduce and 'sliders at 100%' or 'Chance roll, AFK check or no enemy within 50 studs')
			if shared.PistonwareDeveloper == true then
				watchFrames(job, false)
			end
			return
		end
		trace('hit %s: counter %s on the game push %s, keeping %s%% / %s%%', hit, job.counter, push / mass,
			horizontal.value, vertical.value)
		if humanoid and not humanoid.PlatformStand then
			job.untilAt = os.clock() + 0.1
			noKnit.waiting = job
			return
		end
		local stand = noKnit.stand
		applyCounter(job, not humanoid or (stand ~= nil and os.clock() - stand.since > 0.045 and not landedAlready),
			not humanoid and 'at once, no Humanoid to wait on'
				or landedAlready and 'at once, PlatformStand was already on and a frame since the last hit shows the game push'
				or 'at once, PlatformStand was already on')
	end

	local function beforePhysicsWithoutKnit()
		local job = noKnit.waiting
		if not job then return end
		if job.humanoid.PlatformStand then
			noKnit.waiting = nil
			if job.root.Parent then
				applyCounter(job, false, 'before physics, as PlatformStand came on (the same step as the game push)')
			end
		elseif os.clock() > job.untilAt then
			noKnit.waiting = nil
			trace('hit %s: PlatformStand did not come on within 0.1 s, so the game did not push you: nothing countered', job.hit)
		end
	end

	local function takeOff(velocity, push)
		local flat = Vector3.new(push.X, 0, push.Z)
		if flat.Magnitude > 0 then
			local unit = flat.Unit
			velocity -= unit * math.min(flat.Magnitude * (1 - horizontal.value / 100), math.max(velocity:Dot(unit), 0))
		end
		if push.Y > 0 then
			velocity -= Vector3.new(0, math.min(push.Y * (1 - vertical.value / 100), math.max(velocity.Y, 0)), 0)
		end
		return velocity
	end

	local function heartbeatWithoutKnit(dt)
		local character = lplr.Character
		local root = character and character.PrimaryPart
		local humanoid = character and character:FindFirstChildOfClass('Humanoid')
		if not (root and humanoid) then
			noKnit.root, noKnit.stand = nil, nil
			table.clear(noKnit.recent)
			return
		end
		local now = os.clock()
		local velocity = root.AssemblyLinearVelocity
		local change = noKnit.root == root and velocity - noKnit.velocity or nil
		if change then
			local recent = noKnit.recent
			table.insert(recent, {change = change, fall = workspace.Gravity * dt})
			if #recent > 8 then table.remove(recent, 1) end
		end
		if humanoid.PlatformStand then
			local stand = noKnit.stand
			if not stand then
				stand = {since = now, sum = Vector3.zero, fall = 0}
				noKnit.stand = stand
			end
			if change then
				stand.sum += change
				stand.fall += workspace.Gravity * dt
			end
		else
			noKnit.stand = nil
		end

		local pending = noKnit.pending
		if pending and not (pending.root == root and change) then
			pending, noKnit.pending = nil, nil
		end
		if pending then
			pending.frame += 1
			pending.sum += change
			pending.fall += workspace.Gravity * dt
			pending.changes[pending.frame] = change
			if pending.frame >= 3 or (pending.frame >= 2 and not humanoid.PlatformStand) then
				noKnit.pending = nil
				local up = Vector3.new(0, pending.fall, 0)
				local upEarly = Vector3.new(0, pending.fall + pending.priorFall, 0)
				local sum, early = pending.sum, pending.sum + pending.prior
				local alone = math.min((sum - pending.counter).Magnitude, (sum + up - pending.counter).Magnitude)
				local landed = math.min((sum - pending.net).Magnitude, (sum + up - pending.net).Magnitude,
					(early - pending.net).Magnitude, (early + upEarly - pending.net).Magnitude)
				local changes = pending.changes
				if pending.check and alone < pending.counter.Magnitude / 3 and alone < landed then
					velocity -= pending.counter
					root.AssemblyLinearVelocity = velocity
					trace('hit %s: frames %s %s %s are the counter alone (the game did not push): taken back',
						pending.hit, changes[1], changes[2], changes[3])
				else
					trace('hit %s: frames %s %s %s, before them %s; the game push with the counter makes %s, the counter alone %s: %s',
						pending.hit, changes[1], changes[2], changes[3], pending.prior, pending.net, pending.counter,
						pending.counter.Magnitude < 0.001 and 'measured only'
							or landed <= alone and 'kept, the frames add up to both'
							or pending.check and 'kept, nearer both than the counter alone'
							or 'kept (PlatformStand showed the game pushed)')
				end
			end
		end

		local zap = bedwars.ZapNetworking
		if not (zap and zap.decoding == true) then
			local health = humanoid.Health
			if noKnit.humanoid == humanoid and health < noKnit.health then
				noKnit.hurtAt = now
			end
			noKnit.humanoid, noKnit.health = humanoid, health
			local standing = humanoid.PlatformStand
			if standing and not noKnit.standing then
				noKnit.watch = 2
			end
			noKnit.standing = standing
			if noKnit.watch and change then
				local push = change + Vector3.new(0, workspace.Gravity * dt, 0)
				noKnit.watch -= 1
				if push.Magnitude > 5 then
					noKnit.jump, noKnit.jumpAt, noKnit.watch = push, now, nil
				elseif noKnit.watch <= 0 then
					noKnit.watch = nil
				end
			end
			if noKnit.jump and now - noKnit.jumpAt > 0.15 then noKnit.jump = nil end
			if noKnit.hurtAt and now - noKnit.hurtAt > 0.15 then noKnit.hurtAt = nil end
			if noKnit.jump and noKnit.hurtAt then
				if reduceThisHit() then
					local before = velocity
					velocity = takeOff(velocity, noKnit.jump)
					root.AssemblyLinearVelocity = velocity
					trace('no decoder: jump %s with a health drop, velocity %s cut to %s', noKnit.jump, before, velocity)
				else
					trace('no decoder: jump %s with a health drop, left whole (Chance roll, AFK check or no enemy)', noKnit.jump)
				end
				noKnit.jump, noKnit.hurtAt = nil, nil
			end
		end
		noKnit.root, noKnit.velocity, noKnit.change, noKnit.dt = root, velocity, change, dt
	end

	local function velocityWithoutKnit(callback)
		noKnit.pending, noKnit.waiting, noKnit.jump, noKnit.hurtAt, noKnit.watch, noKnit.root, noKnit.humanoid = nil, nil, nil, nil, nil, nil, nil
		noKnit.on, noKnit.change, noKnit.stand = false, nil, nil
		table.clear(noKnit.recent)
		if not callback then return end
		noKnit.on = true
		local zap = bedwars.ZapNetworking
		trace('on (knitless): %s; the Zap decoder is %s, %s packets read so far',
			noKnit.listening and 'listening for hits on you' or 'no damage event to listen to',
			type(zap) == 'table' and zap.decoding == true and 'decoding' or 'not decoding (the PlatformStand and health fallback stands in)',
			type(zap) == 'table' and tonumber(zap.packets) or 0)
		velocity:clean(runService.Heartbeat:Connect(heartbeatWithoutKnit))
		local okStep, beforePhysics = pcall(function()
			return runService.PreSimulation
		end)
		velocity:clean((okStep and beforePhysics or runService.Stepped):Connect(beforePhysicsWithoutKnit))
	end

	velocity = combat:module('Velocity', {
		info = function()
			if not (horizontal and vertical) then return nil end
			return horizontal.value..'% '..vertical.value..'%'
		end,
		toggled = function(on)
			if exec.Knitless then
				velocityWithoutKnit(on)
				return
			end
			if on then
				old = bedwars.KnockbackUtil.applyKnockback
				bedwars.KnockbackUtil.applyKnockback = function(root, mass, dir, knockback, ...)
					if rand:NextNumber(0, 100) > chance:random() or (afkCheck.enabled and isLocalAfk()) then
						return old(root, mass, dir, knockback, ...)
					end
					local check = (not targetCheck.enabled) or entitylib.EntityPosition({
						Range = 50,
						Part = 'RootPart',
						Players = true
					})

					if check then
						if horizontal.value == 0 and vertical.value == 0 then return end
						local scaled = knockback and table.clone(knockback) or {}
						scaled.horizontal = (scaled.horizontal or 1) * (horizontal.value / 100)
						scaled.vertical = (scaled.vertical or 1) * (vertical.value / 100)
						knockback = scaled
					end
					
					return old(root, mass, dir, knockback, ...)
				end
			else
				bedwars.KnockbackUtil.applyKnockback = old
			end
		end,
		about = 'Reduces the amount of knockback you take.'
	})
	chance = velocity:range('Chance', {
		min = 0,
		max = 100,
		defaultMin = 100,
		defaultMax = 100,
		about = 'Percent of hits whose knockback gets reduced. Each hit rolls its chance from this range.'
	})
	horizontal = velocity:slider('Horizontal', {
		label = 'Reduce to',
		min = 0,
		max = 100,
		default = 0,
		suffix = function(val) return '%' end
	})
	velocity:divider('Extras')
	vertical = velocity:slider('Vertical', {
		min = 0,
		max = 100,
		default = 0,
		suffix = function(val) return '%' end
	})
	targetCheck = velocity:toggle('Only when targeting')
	afkCheck = velocity:toggle('AFK check', {
		about = 'Takes full knockback once you have not touched your mouse or keyboard for 30 seconds'
	})

	if exec.Knitless then
		local event = bedwars.ZapNetworking and bedwars.ZapNetworking.EntityDamageEventZap
		if type(event) == 'table' and type(event.On) == 'function' then
			local stop = event.On(onHitWithoutKnit)
			if type(stop) == 'function' then
				slinky:clean(stop)
			end
			noKnit.listening = true
		end
	end
end)

local antiFallDirection
--[[ AntiFall
Puts a part 2 studs under the map's lowest open block once the match has started, to catch you over
the void. Normal walks you back towards the nearest ground, Velocity throws you up at 100 studs/s,
Collide makes it a floor. While it acts it holds AutoWin's ANTIFALL movement priority, and Normal
stops as soon as Fly, TestFly or LongJump is on or the game teleports you. ]]
run(function()
	local antiFall
	local mode
	local material
	local color
	local rayCheck = RaycastParams.new()
	rayCheck.RespectCanCollide = true
	local antiFallPriorityGeneration = 0

	local function setAutoWinAntiFallPriority(active)
		local handlers = store.AutoWinHandlers
		local movement = handlers and handlers.Movement
		if movement and movement.SetPriority then
			movement:SetPriority('ANTIFALL', active == true)
		end
	end

	local function clearAutoWinAntiFallPriority()
		antiFallPriorityGeneration += 1
		setAutoWinAntiFallPriority(false)
	end

	local function pulseAutoWinAntiFallPriority(seconds)
		antiFallPriorityGeneration += 1
		local generation = antiFallPriorityGeneration
		setAutoWinAntiFallPriority(true)
		task.delay(seconds or 0.3, function()
			if generation == antiFallPriorityGeneration then
				setAutoWinAntiFallPriority(false)
			end
		end)
	end

	local function getLowGround()
		local mag = math.huge
		for _, pos in bedwars.BlockController:getStore():getAllBlockPositions() do
			pos = pos * 3
			if pos.Y < mag and not getPlacedBlock(pos + Vector3.new(0, 3, 0)) then
				mag = pos.Y
			end
		end
		return mag
	end

	antiFall = blatant:module('AntiFall', {
		info = function()
			return mode and mode.value or nil
		end,
		toggled = function(on)
			if on then
				repeat task.wait(0.1) until store.matchState ~= 0 or (not antiFall.enabled)
				if not antiFall.enabled then return end

				local ground, debounce = getLowGround(), os.clock()
				if ground ~= math.huge then
					antiFallPart = Instance.new('Part')
					antiFallPart.Size = Vector3.new(10000, 1, 10000)
					antiFallPart.Transparency = 1 - color.opacity
					antiFallPart.Material = Enum.Material[material.value]
					antiFallPart.Color = Color3.fromHSV(color.hue, color.sat, color.value)
					antiFallPart.Position = Vector3.new(0, ground - 2, 0)
					antiFallPart.CanCollide = mode.value == 'Collide'
					antiFallPart.Anchored = true
					antiFallPart.CanQuery = false
					antiFallPart.Parent = workspace
					antiFall:clean(antiFallPart)
					antiFall:clean(antiFallPart.Touched:Connect(function(touched)
						if touched.Parent == lplr.Character and entitylib.isAlive and debounce < os.clock() then
							debounce = os.clock() + 0.1
							if mode.value == 'Normal' then
								local top = getNearGround()
								if top then
									antiFallPriorityGeneration += 1
									setAutoWinAntiFallPriority(true)
									local lastTeleport = lplr:GetAttribute('LastTeleported')
									local connection
									connection = runService.PreSimulation:Connect(function()
										if slinky.modules.Fly.enabled or (slinky.modules.TestFly and slinky.modules.TestFly.enabled) or (slinky.modules.LongJump and slinky.modules.LongJump.enabled) then
											connection:Disconnect()
											antiFallDirection = nil
											clearAutoWinAntiFallPriority()
											return
										end

										if entitylib.isAlive and lplr:GetAttribute('LastTeleported') == lastTeleport then
											local delta = ((top - entitylib.character.RootPart.Position) * Vector3.new(1, 0, 1))
											local root = entitylib.character.RootPart
											antiFallDirection = delta.Unit == delta.Unit and delta.Unit or Vector3.zero
											root.Velocity *= Vector3.new(1, 0, 1)
											rayCheck.FilterDescendantsInstances = {gameCamera, lplr.Character}
											rayCheck.CollisionGroup = root.CollisionGroup

											local ray = workspace:Raycast(root.Position, antiFallDirection, rayCheck)
											if ray then
												local dpos = roundPos(ray.Position + ray.Normal * 1.5) + Vector3.new(0, 3, 0)
												if not getPlacedBlock(dpos) then
													top = Vector3.new(top.X, ground, top.Z)
												end
											end

											root.CFrame += Vector3.new(0, top.Y - root.Position.Y, 0)
											if not frictionTable.Speed then
												root.AssemblyLinearVelocity = (antiFallDirection * getSpeed()) + Vector3.new(0, root.AssemblyLinearVelocity.Y, 0)
											end

											if delta.Magnitude < 1 then
												connection:Disconnect()
												antiFallDirection = nil
												clearAutoWinAntiFallPriority()
											end
										else
											connection:Disconnect()
											antiFallDirection = nil
											clearAutoWinAntiFallPriority()
										end
									end)
									antiFall:clean(connection)
								end
							elseif mode.value == 'Velocity' then
								pulseAutoWinAntiFallPriority(0.35)
								entitylib.character.RootPart.Velocity = Vector3.new(entitylib.character.RootPart.Velocity.X, 100, entitylib.character.RootPart.Velocity.Z)
							end
						end
					end))
				end
			else
				antiFallDirection = nil
				clearAutoWinAntiFallPriority()
			end
		end,
		about = 'Catches you before you fall into the void.\nCan guide you back to land, bounce you up or act as a floor.'
	})
	mode = antiFall:dropdown('Move Mode', {
		choices = {'Normal', 'Collide', 'Velocity'},
		changed = function(val)
			if antiFallPart then
				antiFallPart.CanCollide = val == 'Collide'
			end
		end,
	about = 'Normal - eases you back to the nearest safe spot\nVelocity - throws you upward the moment you touch it\nCollide - just lets you walk on the part'
	})
	local materials = {'ForceField'}
	for _, v in Enum.Material:GetEnumItems() do
		if v.Name ~= 'ForceField' then
			table.insert(materials, v.Name)
		end
	end
	material = antiFall:dropdown('Material', {
		choices = materials,
		changed = function(val)
			if antiFallPart then
				antiFallPart.Material = Enum.Material[val]
			end
		end
	})
	color = antiFall:color('Color', {
		opacity = 0.5,
		changed = function(h, s, v, o)
			if antiFallPart then
				antiFallPart.Color = Color3.fromHSV(h, s, v)
				antiFallPart.Transparency = 1 - o
			end
		end
	})
end)
	
--[[ FastBreak
Lowers the block breaker's cooldown from the game's 0.3 s to Break speed. A blacklisted block under
the crosshair (beds, ores, beehives, crops) keeps 0.3 s. With any blacklist on the cooldown is set
every frame, so no fast hit lands on a blacklisted block before the next poll; otherwise every 0.1
s. Ores are names containing ore_mesh_block or ending in _ore; crops are whatever crop-meta has a
config for, cached per name. The crosshair block comes from the block selector in mode 1 (SELECT);
mode 0 is PLACE, the empty cell in front of it. ]]
run(function()
	if exec.skip('FastBreak') then return end
	if exec.Knitless then
		exec.hide('FastBreak', "needs BedWars' Knit, which this executor cannot load")
		return
	end
	local fastBreak
	local timeSlider
	local blacklistBeds
	local blacklistOres
	local blacklistHive
	local blacklistCrops

	local VANILLA_COOLDOWN = 0.3

	local function readTargetedBlock()
		local breaker = bedwars.BlockBreakController.blockBreaker
		local info = breaker.clientManager:getBlockSelector():getMouseInfo(1)
		local target = info and info.target
		local block = target and target.blockInstance
		return block and block.Name
	end

	local function targetedBlockName()
		local ok, name = pcall(readTargetedBlock)
		return ok and name or nil
	end

	local function isOre(name)
		return name:find('ore_mesh_block', 1, true) ~= nil or name:match('_ore$') ~= nil
	end

	local cropMeta
	local cropCache = {}
	local function isCrop(name)
		if type(name) ~= 'string' then return false end
		local cached = cropCache[name]
		if cached ~= nil then return cached end
		if cropMeta == nil then
			local ok, res = pcall(function()
				return require(replicatedStorage.TS.crop['crop-meta'])
			end)
			cropMeta = ok and res or false
		end
		local result
		if cropMeta and cropMeta.getCropConfig then
			local ok, config = pcall(cropMeta.getCropConfig, name)
			result = ok and config ~= nil
		else
			result = name == 'pumpkin' or name == 'carrot' or name == 'melon'
		end
		cropCache[name] = result
		return result
	end

	local function currentCooldown()
		local name = targetedBlockName()
		if name then
			if blacklistBeds.enabled and name == 'bed' then return VANILLA_COOLDOWN end
			if blacklistOres.enabled and isOre(name) then return VANILLA_COOLDOWN end
			if blacklistHive.enabled and name == 'beehive' then return VANILLA_COOLDOWN end
			if blacklistCrops.enabled and isCrop(name) then return VANILLA_COOLDOWN end
		end
		return timeSlider.value
	end

	fastBreak = blatant:module('FastBreak', {
		info = function()
			if not timeSlider then return nil end
			if timeSlider.value <= 0 then return 'Instant' end
			return string.format('%.2fx', VANILLA_COOLDOWN / timeSlider.value)
		end,
		label = 'Fast Mine',
		tab = 'Block',
		toggled = function(on)
			if on then
				repeat
					local filtering = blacklistBeds.enabled or blacklistOres.enabled or blacklistHive.enabled or blacklistCrops.enabled
					bedwars.BlockBreakController.blockBreaker:setCooldown(filtering and currentCooldown() or timeSlider.value)
					if filtering then
						task.wait()
					else
						task.wait(0.1)
					end
				until not fastBreak.enabled
			else
				bedwars.BlockBreakController.blockBreaker:setCooldown(VANILLA_COOLDOWN)
			end
		end,
		about = 'Increases block mining speed.\nCan leave beds, ores, hives and crops at normal speed.'
	})
	timeSlider = fastBreak:slider('Break speed', {
		min = 0,
		max = 0.3,
		default = 0.25,
		decimal = 100,
		suffix = function(val) return 's' end
	})
	fastBreak:divider('Extras')
	blacklistBeds = fastBreak:toggle('Blacklist Bed', {
		about = 'Leaves beds at normal breaking speed'
	})
	blacklistOres = fastBreak:toggle('Blacklist Ore', {
		about = 'Leaves ores at normal breaking speed'
	})
	blacklistHive = fastBreak:toggle('Blacklist Hive', {
		about = 'Leaves beehives at normal breaking speed'
	})
	blacklistCrops = fastBreak:toggle('Blacklist Crops', {
		about = 'Leaves crops at normal breaking speed'
	})
end)
	
local fly
local testFly
local longJump

--[[ Persistent grounded/airborne state belongs to the adapter, not TPDown.
TPDown is a policy module: it decides when to teleport down and whether to show
its status bar. GroundWatcher stays alive regardless of that module so TestFly,
AutoZephyr and future traversal features all observe the same takeoff/landing
state.

lastGroundTick / lastGroundLandTick deliberately preserve the old TPDown timing
semantics. airTimerTick is separate: legitimate mid-air mechanics such as a
Zephyr air jump can renew the floating-time window without pretending the
player touched the ground. ResetAirTimer also updates entitylib.character.AirTime
for compatibility with the existing airborne clock. GroundWatcher
itself remains authoritative for AutoZephyr's countdown. ]]
local GroundWatcher = {
	grounded = false,
	airborne = false,
	lastGroundTick = 0,
	lastGroundLandTick = 0,
	takeoffPosition = nil,
	landedPosition = nil,
	airTimerTick = 0,
	Takeoff = Instance.new('BindableEvent'),
	Landed = Instance.new('BindableEvent'),
	AirTimerReset = Instance.new('BindableEvent')
}
store.GroundWatcher = GroundWatcher
slinky:clean(GroundWatcher.Takeoff)
slinky:clean(GroundWatcher.Landed)
slinky:clean(GroundWatcher.AirTimerReset)

function GroundWatcher:ResetAirTimer(reason)
	local now = tick()
	self.airTimerTick = now
	if entitylib.isAlive and entitylib.character then
		entitylib.character.AirTime = os.clock()
	end
	self.AirTimerReset:Fire(now, reason)
	return now
end

--[[ Tracks your ground state every Heartbeat for GroundWatcher: grounded and airborne, takeoff and
landing times and positions, the Takeoff and Landed events and the air timer. Standing on something
keeps character.AirTime at now, which TPDown's Air Time reads as zero. Everyone else's Jumps and
Jumping are cleared once they have been still vertically for 0.2 s; only an entity mid-jump is
walked. ]]
run(function()
	local wasGrounded

	slinky:clean(runService.Heartbeat:Connect(function()
		for _, v in entitylib.List do
			if v.Jumps ~= 0 and v.RootPart then
				v.LandTick = math.abs(v.RootPart.Velocity.Y) < 0.1 and v.LandTick or os.clock()
				if (os.clock() - v.LandTick) > 0.2 then
					v.Jumps = 0
					v.Jumping = false
				end
			end
		end

		if not entitylib.isAlive then
			wasGrounded = nil
			GroundWatcher.grounded = false
			GroundWatcher.airborne = false
			return
		end

		local character = entitylib.character
		local humanoid = character.Humanoid
		local root = character.RootPart
		if not humanoid or not root then return end

		local grounded = humanoid.FloorMaterial ~= Enum.Material.Air
		GroundWatcher.grounded = grounded
		if grounded then
			character.AirTime = os.clock()
		end

		if wasGrounded == nil then
			wasGrounded = grounded
			if grounded then
				GroundWatcher.airborne = false
				GroundWatcher:ResetAirTimer('initial-ground')
			else
				local now = tick()
				GroundWatcher.lastGroundTick = now
				GroundWatcher.takeoffPosition = root.Position
				GroundWatcher.landedPosition = nil
				GroundWatcher.lastGroundLandTick = 0
				GroundWatcher.airborne = true
				GroundWatcher:ResetAirTimer('initial-air')
				GroundWatcher.Takeoff:Fire(now, root.Position)
			end
			return
		end

		if wasGrounded and not grounded then
			local now = tick()
			GroundWatcher.lastGroundTick = now
			GroundWatcher.takeoffPosition = root.Position
			GroundWatcher.landedPosition = nil
			GroundWatcher.lastGroundLandTick = 0
			GroundWatcher.airborne = true
			GroundWatcher:ResetAirTimer('takeoff')
			GroundWatcher.Takeoff:Fire(now, root.Position)
		elseif not wasGrounded and grounded then
			GroundWatcher.landedPosition = root.Position
			GroundWatcher.lastGroundLandTick = tick()
			GroundWatcher.airborne = false
			GroundWatcher:ResetAirTimer('landed')
			GroundWatcher.Landed:Fire(
				GroundWatcher.lastGroundTick,
				GroundWatcher.takeoffPosition,
				GroundWatcher.landedPosition,
				GroundWatcher.lastGroundLandTick
			)
		end

		wasGrounded = grounded
	end))
end)

--[[ AutoZephyr
Spends Zephyr's air jumps Lead Time before TPDown's Air Time runs out, which keeps you in the air
longer. It fires the JumpRequest player input fires, so the game's JumpHeightController still sends
NotifyAirJump and keeps its own air-jump counter and 0.25 s debounce. Without firesignal (Solara,
Xeno) it does what that handler does for an air jump, after the same allowedAirJumps check. A
Freefall to Jumping transition with the wind_walker kit active counts as an air jump (at most 2) and
renews GroundWatcher's air timer and entitylib.character.AirTime, which restarts TPDown's countdown
without changing lastGroundTick. ]]
run(function()
	if exec.skip('AutoZephyr') then return end
	local autoZephyr
	local leadTime
	local nextAttempt = 0
	local airJumpsUsed = 0

	local function reset()
		nextAttempt = 0
		airJumpsUsed = 0
	end

	local function getTPDown()
		local module = slinky.modules and slinky.modules.TPDown
		local airTime = module and module.options and module.options['Air Time']
		return module, airTime
	end

	local function zephyrReady()
		local controller = bedwars.WindWalkerController
		return store.hasKit('wind_walker')
			and controller ~= nil
			and controller.doubleJumpActive == true
	end

	local function watchHumanoid(humanoid)
		if not humanoid then return end
		autoZephyr:clean(humanoid.StateChanged:Connect(function(oldState, newState)
			if newState == Enum.HumanoidStateType.Landed then
				reset()
				return
			end

			if oldState == Enum.HumanoidStateType.Freefall
				and newState == Enum.HumanoidStateType.Jumping
				and GroundWatcher.airborne
				and zephyrReady() then
				airJumpsUsed = math.min(airJumpsUsed + 1, 2)
				GroundWatcher:ResetAirTimer('zephyr-air-jump')
				nextAttempt = tick() + 0.25
			end
		end))
	end

	autoZephyr = minigames:module('AutoZephyr', {
		toggled = function(on)
			if not on then
				reset()
				return
			end

			reset()
			if entitylib.isAlive then
				watchHumanoid(entitylib.character.Humanoid)
			end
			autoZephyr:clean(entitylib.Events.LocalAdded:Connect(function(ent)
				reset()
				watchHumanoid(ent.Humanoid)
			end))
			autoZephyr:clean(GroundWatcher.Takeoff.Event:Connect(reset))
			autoZephyr:clean(GroundWatcher.Landed.Event:Connect(reset))

			autoZephyr:clean(runService.Heartbeat:Connect(function()
				if not (entitylib.isAlive and GroundWatcher.airborne and zephyrReady()) then
					return
				end
				if airJumpsUsed >= 2 then return end

				local humanoid = entitylib.character.Humanoid
				if not humanoid or humanoid:GetState() ~= Enum.HumanoidStateType.Freefall then
					return
				end

				local tpDown, airTime = getTPDown()
				if not (tpDown and tpDown.enabled and airTime and type(airTime.value) == 'number') then
					return
				end

				local remaining = airTime.value - (tick() - GroundWatcher.airTimerTick)
				local now = tick()
				if remaining > leadTime.value or now < nextAttempt then return end

				nextAttempt = now + 0.26
				if type(firesignal) == 'function' then
					pcall(firesignal, inputService.JumpRequest)
				else
					local jumps = bedwars.JumpHeightController
					if jumps and (tonumber(jumps.allowedAirJumps) or 0) < 1 then return end
					local sent = pcall(function()
						bedwars.Client:Get('NotifyAirJump'):SendToServer()
					end)
					if sent then
						humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
					end
				end
			end))
		end,
		info = function()
			local tpDown, airTime = getTPDown()
			if not (tpDown and tpDown.enabled and airTime and type(airTime.value) == 'number'
				and GroundWatcher.airTimerTick > 0) then
				return ''
			end
			return string.format('%.1fs', math.max(
				airTime.value - (tick() - GroundWatcher.airTimerTick),
				0
			))
		end,
		about = 'Uses Zephyr air jumps to keep you in the air longer.\nTimes each jump for just before TPDown air time ends.'
	})

	leadTime = autoZephyr:slider('Lead Time', {
		min = 0,
		max = 1,
		default = 0.15,
		decimal = 100,
		suffix = function(val) return val == 1 and 'second' or 'seconds' end,
		about = 'How early before TPDown Air Time expires AutoZephyr requests a jump'
	})
end)

--[[ Fly
Flies by moving the root up to Speed each physics step and setting its vertical velocity; jump rises
and Shift sinks at Vertical Speed. Balloons are inflated and held while it runs, and Pop Balloons
deflates them when it turns off. Wall Check stops the move at a wall; its ray filter is rebuilt only
when the character, camera or AntiFall part changes. ]]
run(function()
	local amount
	local verticalValue
	local wallCheck
	local popBalloons
	local rayCheck = RaycastParams.new()
	rayCheck.RespectCanCollide = true
	local filterChar, filterCamera, filterAntiFall
	local up, down, old = 0, 0

	fly = blatant:module('Fly', {
		toggled = function(on)
			frictionTable.Fly = on or nil
			updateVelocity()
			if on then
				up, down = 0, 0
				old = true
				store.holdBalloons(true)

				if lplr.Character and (lplr.Character:GetAttribute('InflatedBalloons') or 0) == 0 and getItem('balloon') then
					bedwars.BalloonController:inflateBalloon()
				end

				fly:clean(slinkyEvents.AttributeChanged.Event:Connect(function(changed)
					if changed == 'InflatedBalloons' and (lplr.Character:GetAttribute('InflatedBalloons') or 0) == 0 and getItem('balloon') then
						bedwars.BalloonController:inflateBalloon()
					end
				end))

				fly:clean(runService.PreSimulation:Connect(function(dt)
					if entitylib.isAlive and isnetworkowner(entitylib.character.RootPart) then
						local char = entitylib.character
						local balloons = lplr.Character:GetAttribute('InflatedBalloons')
						local flyAllowed = (balloons and balloons > 0) or store.matchState == 2
						local mass = (1.5 + (flyAllowed and 6 or 0) * (os.clock() % 0.4 < 0.2 and -1 or 1)) + ((up + down) * verticalValue.value)
						local root, moveDirection = char.RootPart, char.Humanoid.MoveDirection
						local velo = getSpeed()
						local destination = (moveDirection * math.max(amount.value - velo, 0) * dt)

						if wallCheck.enabled then
							if filterChar ~= lplr.Character or filterCamera ~= gameCamera or filterAntiFall ~= antiFallPart then
								filterChar, filterCamera, filterAntiFall = lplr.Character, gameCamera, antiFallPart
								rayCheck.FilterDescendantsInstances = {filterChar, filterCamera, filterAntiFall}
							end
							rayCheck.CollisionGroup = root.CollisionGroup
							local ray = workspace:Raycast(root.Position, destination, rayCheck)
							if ray then
								destination = ((ray.Position + ray.Normal) - root.Position)
							end
						end

						root.CFrame += destination
						root.AssemblyLinearVelocity = (moveDirection * velo) + Vector3.new(0, mass, 0)
					end
				end))

				fly:clean(inputService.InputBegan:Connect(function(input)
					if not inputService:GetFocusedTextBox() then
						if input.KeyCode == Enum.KeyCode.Space or input.KeyCode == Enum.KeyCode.ButtonA then
							up = 1
						elseif input.KeyCode == Enum.KeyCode.LeftShift or input.KeyCode == Enum.KeyCode.ButtonL2 then
							down = -1
						end
					end
				end))

				fly:clean(inputService.InputEnded:Connect(function(input)
					if input.KeyCode == Enum.KeyCode.Space or input.KeyCode == Enum.KeyCode.ButtonA then
						up = 0
					elseif input.KeyCode == Enum.KeyCode.LeftShift or input.KeyCode == Enum.KeyCode.ButtonL2 then
						down = 0
					end
				end))

				if inputService.TouchEnabled then
					pcall(function()
						local jumpButton = lplr.PlayerGui.TouchGui.TouchControlFrame.JumpButton
						fly:clean(jumpButton:GetPropertyChangedSignal('ImageRectOffset'):Connect(function()
							up = jumpButton.ImageRectOffset.X == 146 and 1 or 0
						end))
					end)
				end
			else
				if old then
					old = nil
					store.holdBalloons(false)
				end
				if popBalloons.enabled and entitylib.isAlive and (lplr.Character:GetAttribute('InflatedBalloons') or 0) > 0 then
					for _ = 1, 3 do
						bedwars.BalloonController:deflateBalloon()
					end
				end
			end
		end,
		info = function()
			return 'Heatseeker'
		end,
		about = 'Lets you fly around freely.\nRise with jump and sink with Shift; can use and pop your balloon.'
	})

	amount = fly:slider('Speed', {
		min = 1,
		max = 23,
		default = 23,
		suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})

	verticalValue = fly:slider('Vertical Speed', {
		min = 1,
		max = 150,
		default = 50,
		suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})

	wallCheck = fly:toggle('Wall Check', {
		default = true
	})

	popBalloons = fly:toggle('Pop Balloons', {
		default = true
	})
end)
	

--[[ TestFly
Experimental flight in modes registered with registerMode: Heatseeker (Fly's flight), VelocityBounce
and CFrameBounce (repeated upward pushes), VerticalClip and Jump. A mode with a Once hook runs it in
place of Start, and TestFly turns off when it returns; with Notifications on it stays on until you
land and reports the distance and time flown. PreSimulation and Heartbeat hooks run for every mode,
End and Cleanup when it stops. ModeContext carries the generation, state and options, and its Clean
list is emptied when a mode stops.

VerticalClip sets the vertical velocity Clip Loop Count times, Clip Wait apart (with the defaults
120 studs/s 8 times at 0.17 s, about 1.36 s), then teleports to Max Y keeping X, Z and rotation.

Jump rises for exactly Jump Duration to Jump Margin below the ceiling and then falls normally,
without teleporting. The ceiling is the 80th percentile of the map's column tops, player-placed
blocks ignored so towers and a single spire do not raise it, plus Jump Height Above Blocks, the
highest point that takes no damage; it is worked out again when the match state changes. Each step
solves the parabola from the current height to the apex: velocity 2 * dy / tau with tau at least two
steps, plus g * dt for the coming step's gravity.

AutoWin uses store.TestFlyJump: ApexY (may scan the map and yield), CachedApexY (nil until known),
Duration and Target. A Target set before Jump starts flies an aimed arc to that root position: t = d
/ v and vy = dy / t + g * t / 2, solved again each step. t is never shorter than a lift of Clearance
over the higher end on the ground, an apex Clearance over the landing while below it, or the free
fall from here; horizontal speed is then cut to d / t, and nothing rises past the ceiling. With
AutoWinOwned set, AutoWin ends the flight after the landing. ]]
run(function()
	local modeDropdown
	local amount
	local verticalValue
	local wallCheck
	local popBalloons
	local notifications
	local velocityBounceValue
	local cFrameBounceValue
	local bounceRepeat
	local bounceWait
	local velocityIncrease
	local cFrameIncrease
	local verticalClipVelocity
	local verticalClipIncrement
	local verticalClipWait
	local verticalClipLoops
	local verticalClipMaxY
	local jumpDuration
	local jumpHeightAbove
	local jumpMargin
	local rayCheck = RaycastParams.new()
	rayCheck.RespectCanCollide = true
	local filterChar, filterCamera, filterAntiFall
	local up, down = 0, 0
	local activeMode
	local modeGeneration = 0
	local modeCleanups = {}
	local modes, modeList = {}, {}
	local testFlySessionTick = 0
	local pendingOnGroundTick
	local waitForLandingGeneration
	local ModeContext = {}

	local function registerMode(name, hooks)
		modes[name] = hooks or {}
		if not table.find(modeList, name) then
			table.insert(modeList, name)
		end
	end

	function ModeContext:Clean(item)
		if item ~= nil then
			table.insert(modeCleanups, item)
		end
		return item
	end

	local function cleanupModeResources()
		for i = #modeCleanups, 1, -1 do
			local item = modeCleanups[i]
			pcall(function()
				local itemType = typeof(item)
				if itemType == 'RBXScriptConnection' then
					item:Disconnect()
				elseif itemType == 'Instance' then
					item:Destroy()
				elseif type(item) == 'function' then
					item()
				elseif type(item) == 'table' then
					if type(item.Disconnect) == 'function' then
						item:Disconnect()
					elseif type(item.Destroy) == 'function' then
						item:Destroy()
					end
				end
			end)
		end
		table.clear(modeCleanups)
	end

	local function callModeHook(mode, hook, ...)
		local callback = mode and mode[hook]
		if type(callback) ~= 'function' then return end
		local ok, err = pcall(callback, ModeContext, ...)
		if not ok then
			bufferCall('error', 'testfly.mode.'..hook:lower(), tostring(err), {
				mode = modeDropdown and modeDropdown.value or 'unknown'
			})
		end
	end

	local function stopMode(reason)
		local mode = activeMode
		activeMode = nil
		modeGeneration += 1
		ModeContext.Generation = modeGeneration
		callModeHook(mode, 'End', reason)
		cleanupModeResources()
		callModeHook(mode, 'Cleanup', reason)
		ModeContext.State = nil
	end

	local function startMode(name)
		local mode = modes[name]
		activeMode = mode
		modeGeneration += 1
		local generation = modeGeneration
		ModeContext.Generation = generation
		ModeContext.State = {}
		waitForLandingGeneration = nil

		if mode and type(mode.Once) == 'function' then
			task.spawn(function()
				callModeHook(mode, 'Once')
				if not (testFly.enabled and activeMode == mode and ModeContext.Generation == generation) then return end
				if store.TestFlyJump and store.TestFlyJump.AutoWinOwned then return end

				if notifications and notifications.enabled then
					if entitylib.isAlive and entitylib.character.Humanoid.FloorMaterial == Enum.Material.Air then
						task.wait()
					end

					if testFly.enabled
						and activeMode == mode
						and ModeContext.Generation == generation
						and GroundWatcher.airborne
						and GroundWatcher.lastGroundTick >= testFlySessionTick then
						waitForLandingGeneration = generation
						return
					end
				end

				if testFly.enabled and activeMode == mode and ModeContext.Generation == generation then
					testFly:flip()
				end
			end)
			return
		end

		callModeHook(mode, 'Start')
	end

	local function switchMode(name)
		if not (testFly and testFly.enabled) then return end
		stopMode('switch')
		startMode(name)
	end

	local function notifyFlightStats(onGroundTick, onGroundPosition, landedPosition, landedTick)
		if not (notifications and notifications.enabled) then return end
		if onGroundTick <= 0 or landedTick < onGroundTick or not onGroundPosition or not landedPosition then return end
		local horizontal = (landedPosition - onGroundPosition) * Vector3.new(1, 0, 1)
		notif('TestFly', string.format(
			'Flew %.1f studs for %.2f seconds',
			horizontal.Magnitude,
			landedTick - onGroundTick
		), 5)
	end

	slinky:clean(GroundWatcher.Landed.Event:Connect(function(onGroundTick, onGroundPosition, landedPosition, landedTick)
		local belongsToActiveSession = testFly and testFly.enabled and onGroundTick >= testFlySessionTick
		local belongsToPendingFlight = pendingOnGroundTick ~= nil and onGroundTick == pendingOnGroundTick
		local finishesOnceMode = waitForLandingGeneration ~= nil
			and testFly
			and testFly.enabled
			and ModeContext.Generation == waitForLandingGeneration
			and onGroundTick >= testFlySessionTick

		if belongsToActiveSession or belongsToPendingFlight then
			notifyFlightStats(onGroundTick, onGroundPosition, landedPosition, landedTick)
		end
		if belongsToPendingFlight then
			pendingOnGroundTick = nil
		end
		if finishesOnceMode and not (store.TestFlyJump and store.TestFlyJump.AutoWinOwned) then
			waitForLandingGeneration = nil
			testFly:flip()
		end
	end))

	local function startFlightMode(context)
		up, down = 0, 0
		context.State.oldDeflate = true
		store.holdBalloons(true)

		if lplr.Character and (lplr.Character:GetAttribute('InflatedBalloons') or 0) == 0 and getItem('balloon') then
			bedwars.BalloonController:inflateBalloon()
		end

		context:Clean(slinkyEvents.AttributeChanged.Event:Connect(function(changed)
			if changed == 'InflatedBalloons' and lplr.Character and (lplr.Character:GetAttribute('InflatedBalloons') or 0) == 0 and getItem('balloon') then
				bedwars.BalloonController:inflateBalloon()
			end
		end))
	end

	local function endFlightMode(context, reason)
		if context.State and context.State.oldDeflate then
			context.State.oldDeflate = nil
			store.holdBalloons(false)
		end

		if reason == 'disable' and popBalloons.enabled and entitylib.isAlive and lplr.Character and (lplr.Character:GetAttribute('InflatedBalloons') or 0) > 0 then
			for _ = 1, 3 do
				bedwars.BalloonController:deflateBalloon()
			end
		end
	end

	local function cleanupFlightMode()
		up, down = 0, 0
	end

	local function applyHorizontal(dt, maxSpeed)
		if not (entitylib.isAlive and isnetworkowner(entitylib.character.RootPart)) then return end

		local char = entitylib.character
		local root, moveDirection = char.RootPart, char.Humanoid.MoveDirection
		local velo = getSpeed()
		local speed = math.max(amount.value, velo)
		if maxSpeed then
			speed = math.clamp(maxSpeed, 0, speed)
		end
		local walk = math.min(velo, speed)
		local destination = moveDirection * (speed - walk) * dt

		if wallCheck.enabled then
			if filterChar ~= lplr.Character or filterCamera ~= gameCamera or filterAntiFall ~= antiFallPart then
				filterChar, filterCamera, filterAntiFall = lplr.Character, gameCamera, antiFallPart
				rayCheck.FilterDescendantsInstances = {filterChar, filterCamera, filterAntiFall}
			end
			rayCheck.CollisionGroup = root.CollisionGroup
			local ray = workspace:Raycast(root.Position, destination, rayCheck)
			if ray then
				destination = (ray.Position + ray.Normal) - root.Position
			end
		end

		root.CFrame += destination
		root.AssemblyLinearVelocity = (moveDirection * walk) + Vector3.new(0, root.AssemblyLinearVelocity.Y, 0)
		return root, moveDirection, velo
	end

	local function runBounceOnce(context, baseOption, increaseOption, apply)
		local generation = context.Generation
		local amount = baseOption.value
		local repeats = math.max(math.floor(bounceRepeat.value), 1)

		for _ = 1, repeats do
			if not testFly.enabled or context.Generation ~= generation then return end
			if entitylib.isAlive and isnetworkowner(entitylib.character.RootPart) then
				local ok, err = pcall(apply, entitylib.character.RootPart, amount)
				if not ok then
					bufferCall('error', 'testfly.bounce', tostring(err), {
						mode = modeDropdown and modeDropdown.value or 'unknown'
					})
				end
			end

			amount += increaseOption.value
			task.wait(bounceWait.value)
		end
	end
	registerMode('Heatseeker', {
		Start = startFlightMode,
		PreSimulation = function(_, dt)
			local root, moveDirection, velo = applyHorizontal(dt)
			if root then
				local balloons = lplr.Character:GetAttribute('InflatedBalloons')
				local flyAllowed = (balloons and balloons > 0) or store.matchState == 2
				local mass = (1.5 + (flyAllowed and 6 or 0) * (os.clock() % 0.4 < 0.2 and -1 or 1)) + ((up + down) * verticalValue.value)
				root.AssemblyLinearVelocity = (moveDirection * velo) + Vector3.new(0, mass, 0)
			end
		end,
		End = endFlightMode,
		Cleanup = cleanupFlightMode
	})

	registerMode('VelocityBounce', {
		Once = function(context)
			runBounceOnce(context, velocityBounceValue, velocityIncrease, function(root, amount)
				root.AssemblyLinearVelocity += Vector3.new(0, amount, 0)
			end)
		end
	})

	registerMode('CFrameBounce', {
		Once = function(context)
			runBounceOnce(context, cFrameBounceValue, cFrameIncrease, function(root, amount)
				root.CFrame += Vector3.new(0, amount, 0)
			end)
		end
	})

	registerMode('VerticalClip', {
		PreSimulation = function(_, dt)
			applyHorizontal(dt)
		end,
		Once = function(context)
			local generation = context.Generation
			local amount = verticalClipVelocity.value
			local loops = math.max(math.floor(verticalClipLoops.value), 1)

			for _ = 1, loops do
				if not testFly.enabled or context.Generation ~= generation then return end
				if entitylib.isAlive and isnetworkowner(entitylib.character.RootPart) then
					local root = entitylib.character.RootPart
					local velocity = root.AssemblyLinearVelocity
					root.AssemblyLinearVelocity = Vector3.new(velocity.X, amount, velocity.Z)
				end

				amount += verticalClipIncrement.value
				task.wait(verticalClipWait.value)
			end

			if testFly.enabled and context.Generation == generation and entitylib.isAlive then
				local root = entitylib.character.RootPart
				local rotation = root.CFrame - root.CFrame.Position
				root.CFrame = CFrame.new(
					root.Position.X,
					verticalClipMaxY.value,
					root.Position.Z
				) * rotation
			end
		end
	})

	local jumpCeiling = {}
	local JUMP_CEILING_PERCENTILE = 0.8
	local function jumpCeilingCurrent(blockStore)
		return jumpCeiling.Store == blockStore
			and jumpCeiling.MatchState == store.matchState
			and jumpCeiling.Top ~= nil
	end

	local function getHighestMapBlockTop()
		local blockStore = bedwars.BlockController:getStore()
		if jumpCeilingCurrent(blockStore) then
			return jumpCeiling.Top
		end
		local matchState = store.matchState

		local columns = {}
		for index, pos in blockStore:getAllBlockPositions() do
			local column = Vector3.new(pos.X, 0, pos.Z)
			local best = columns[column]
			if not best or pos.Y > best then
				local block = blockStore:getBlockAt(pos)
				if block and (block:GetAttribute('PlacedByUserId') or 0) == 0 then
					columns[column] = pos.Y
				end
			end
			if index % 4000 == 0 then
				task.wait()
			end
		end

		local tops = {}
		for _, y in columns do
			table.insert(tops, y)
		end
		if #tops > 0 then
			table.sort(tops)
			local index = math.clamp(math.ceil(#tops * JUMP_CEILING_PERCENTILE), 1, #tops)
			jumpCeiling.Store = blockStore
			jumpCeiling.MatchState = matchState
			jumpCeiling.Top = tops[index] * 3 + 1.5
		end
		return jumpCeiling.Top
	end

	local function arcSeconds(apexRise, dy, gravity)
		return math.sqrt(2 * math.max(apexRise, 0) / gravity)
			+ math.sqrt(2 * math.max(apexRise - dy, 0) / gravity)
	end

	local function steerArc(arc, target, dt)
		local char = entitylib.character
		local root = char.RootPart
		local position = root.Position
		local gravity = math.max(workspace.Gravity, 1)
		local clearance = math.max(tonumber(store.TestFlyJump.Clearance) or 0, 0)
		local distance = Vector3.new(target.X - position.X, 0, target.Z - position.Z).Magnitude
		local dy = target.Y - position.Y
		local vy = root.AssemblyLinearVelocity.Y
		local grounded = char.Humanoid.FloorMaterial ~= Enum.Material.Air

		local moving = char.Humanoid.MoveDirection.Magnitude > 0.05
		if not grounded then
			arc.Launched = true
		elseif not moving or (arc.Launched and distance <= 4.5) then
			applyHorizontal(dt)
			return
		end

		local minimum
		if grounded then
			minimum = arcSeconds(math.max(dy, 0) + clearance, dy, gravity)
		elseif (vy >= 0 and dy > -clearance) or dy > 1.5 then
			minimum = arcSeconds(dy + clearance, dy, gravity)
		elseif dy > 0 then
			applyHorizontal(dt)
			return
		else
			minimum = (vy + math.sqrt(vy * vy - 2 * gravity * dy)) / gravity
		end

		local speed = math.max(amount.value, getSpeed(), 1)
		local seconds = math.max(moving and distance / speed or 0, minimum, 2 * dt)
		root = applyHorizontal(dt, distance / seconds)
		if not root then return end

		local velocityY = dy / seconds + gravity * seconds / 2
		if arc.CeilingY then
			velocityY = math.min(velocityY, math.sqrt(2 * gravity * math.max(arc.CeilingY - position.Y, 0)))
		end
		local velocity = root.AssemblyLinearVelocity
		root.AssemblyLinearVelocity = Vector3.new(velocity.X, velocityY, velocity.Z)
	end

	registerMode('Jump', {
		PreSimulation = function(context, dt)
			local arc = context.State and context.State.Arc
			local target = arc and store.TestFlyJump and store.TestFlyJump.Target
			if typeof(target) == 'Vector3' then
				if entitylib.isAlive and isnetworkowner(entitylib.character.RootPart) then
					steerArc(arc, target, dt)
				end
				return
			end

			local root = applyHorizontal(dt)
			local jump = context.State and context.State.Jump
			if not root or not jump then return end

			local remaining = jump.Duration - (os.clock() - jump.Started)
			if remaining <= 0 then return end

			local tau = math.max(remaining, 2 * dt)
			local rise = jump.TargetY - root.Position.Y
			local velocity = root.AssemblyLinearVelocity
			root.AssemblyLinearVelocity = Vector3.new(
				velocity.X,
				math.max(2 * rise / tau, 0) + workspace.Gravity * dt,
				velocity.Z
			)
		end,
		Once = function(context)
			local generation = context.Generation
			local function current()
				return testFly.enabled and context.Generation == generation and entitylib.isAlive
			end

			if store.TestFlyJump and typeof(store.TestFlyJump.Target) == 'Vector3' then
				local arc = {}
				context.State.Arc = arc
				local top = getHighestMapBlockTop()
				if top and current() then
					arc.CeilingY = top + jumpHeightAbove.value - jumpMargin.value
				end
				return
			end

			local top = getHighestMapBlockTop()
			if not top or not current() then return end

			local root = entitylib.character.RootPart
			local duration = math.max(jumpDuration.value, 0.05)
			local targetY = top + jumpHeightAbove.value - jumpMargin.value
			if targetY <= root.Position.Y then return end

			local jump = {
				TargetY = targetY,
				Duration = duration,
				Started = os.clock()
			}
			context.State.Jump = jump
			repeat
				task.wait()
			until not current() or os.clock() - jump.Started >= duration
			if context.State and context.State.Jump == jump then
				context.State.Jump = nil
			end

			if current() and isnetworkowner(entitylib.character.RootPart) then
				local apexRoot = entitylib.character.RootPart
				local velocity = apexRoot.AssemblyLinearVelocity
				apexRoot.AssemblyLinearVelocity = Vector3.new(velocity.X, 0, velocity.Z)
			end
		end
	})

	local function updateModeVisibility(name)
		local velocityBounce = name == 'VelocityBounce'
		local cframeBounce = name == 'CFrameBounce'
		local verticalClip = name == 'VerticalClip'
		local anyBounce = velocityBounce or cframeBounce

		if verticalValue then verticalValue.row.Visible = name == 'Heatseeker' end
		if velocityBounceValue then velocityBounceValue.row.Visible = velocityBounce end
		if cFrameBounceValue then cFrameBounceValue.row.Visible = cframeBounce end
		if bounceRepeat then bounceRepeat.row.Visible = anyBounce end
		if bounceWait then bounceWait.row.Visible = anyBounce end
		if velocityIncrease then velocityIncrease.row.Visible = velocityBounce end
		if cFrameIncrease then cFrameIncrease.row.Visible = cframeBounce end
		if verticalClipVelocity then verticalClipVelocity.row.Visible = verticalClip end
		if verticalClipIncrement then verticalClipIncrement.row.Visible = verticalClip end
		if verticalClipWait then verticalClipWait.row.Visible = verticalClip end
		if verticalClipLoops then verticalClipLoops.row.Visible = verticalClip end
		if verticalClipMaxY then verticalClipMaxY.row.Visible = verticalClip end
		local jump = name == 'Jump'
		if jumpDuration then jumpDuration.row.Visible = jump end
		if jumpHeightAbove then jumpHeightAbove.row.Visible = jump end
		if jumpMargin then jumpMargin.row.Visible = jump end
	end

	testFly = blatant:module('TestFly', {
		toggled = function(on)
			frictionTable.TestFly = on or nil
			updateVelocity()
			if on then
				testFlySessionTick = tick()
				pendingOnGroundTick = nil
				waitForLandingGeneration = nil
				startMode(modeDropdown.value)

				testFly:clean(runService.PreSimulation:Connect(function(dt)
					callModeHook(activeMode, 'PreSimulation', dt)
				end))

				testFly:clean(runService.Heartbeat:Connect(function(dt)
					callModeHook(activeMode, 'Heartbeat', dt)
				end))

				testFly:clean(inputService.InputBegan:Connect(function(input)
					if not inputService:GetFocusedTextBox() then
						if input.KeyCode == Enum.KeyCode.Space or input.KeyCode == Enum.KeyCode.ButtonA then
							up = 1
						elseif input.KeyCode == Enum.KeyCode.LeftShift or input.KeyCode == Enum.KeyCode.ButtonL2 then
							down = -1
						end
					end
				end))

				testFly:clean(inputService.InputEnded:Connect(function(input)
					if input.KeyCode == Enum.KeyCode.Space or input.KeyCode == Enum.KeyCode.ButtonA then
						up = 0
					elseif input.KeyCode == Enum.KeyCode.LeftShift or input.KeyCode == Enum.KeyCode.ButtonL2 then
						down = 0
					end
				end))

				if inputService.TouchEnabled then
					pcall(function()
						local jumpButton = lplr.PlayerGui.TouchGui.TouchControlFrame.JumpButton
						testFly:clean(jumpButton:GetPropertyChangedSignal('ImageRectOffset'):Connect(function()
							up = jumpButton.ImageRectOffset.X == 146 and 1 or 0
						end))
					end)
				end
			else
				waitForLandingGeneration = nil
				stopMode('disable')
				if notifications and notifications.enabled and GroundWatcher.airborne and GroundWatcher.lastGroundTick >= testFlySessionTick then
					pendingOnGroundTick = GroundWatcher.lastGroundTick
				end
			end
		end,
		info = function()
			return modeDropdown.value
		end,
		about = 'Lets you fly using experimental flight modes.\nChoose Heatseeker, bounce, vertical clip or jump flight.'
	})

	ModeContext.Module = testFly

	modeDropdown = testFly:dropdown('Mode', {
		choices = modeList,
		default = 'Heatseeker',
		changed = function(val)
			updateModeVisibility(val)
			switchMode(val)
		end
	})

	amount = testFly:slider('Speed', {
		min = 1,
		max = 23,
		default = 23,
		suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})

	verticalValue = testFly:slider('Vertical Speed', {
		min = 1,
		max = 150,
		default = 50,
		suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})

	velocityBounceValue = testFly:slider('Velocity', {
		min = 0,
		max = 150,
		default = 25,
		sub = true,
		visible = false,
		suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})

	cFrameBounceValue = testFly:slider('CFrame', {
		min = 0,
		max = 20,
		decimal = 10,
		default = 1,
		sub = true,
		visible = false,
		suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})

	bounceRepeat = testFly:slider('Repeat', {
		min = 1,
		max = 20,
		default = 3,
		sub = true,
		visible = false
	})

	bounceWait = testFly:slider('Wait', {
		min = 0.01,
		max = 2,
		decimal = 100,
		default = 0.1,
		sub = true,
		visible = false,
		suffix = function(val)
			return val == 1 and 'second' or 'seconds'
		end
	})

	velocityIncrease = testFly:slider('Increase Velocity', {
		min = -50,
		max = 50,
		default = 0,
		sub = true,
		visible = false,
		suffix = function(val)
			return (val == 1 or val == -1) and 'stud' or 'studs'
		end
	})

	cFrameIncrease = testFly:slider('Increase CFrame', {
		min = -10,
		max = 10,
		decimal = 10,
		default = 0,
		sub = true,
		visible = false,
		suffix = function(val)
			return (val == 1 or val == -1) and 'stud' or 'studs'
		end
	})

	verticalClipVelocity = testFly:slider('Clip Velocity', {
		min = -150,
		max = 150,
		default = 120,
		sub = true,
		visible = false,
		suffix = function(val)
			return (val == 1 or val == -1) and 'stud' or 'studs'
		end
	})

	verticalClipIncrement = testFly:slider('Clip Increment', {
		min = -50,
		max = 50,
		default = 0,
		sub = true,
		visible = false,
		suffix = function(val)
			return (val == 1 or val == -1) and 'stud' or 'studs'
		end
	})

	verticalClipWait = testFly:slider('Clip Wait', {
		min = 0.01,
		max = 2,
		decimal = 100,
		default = 0.17,
		sub = true,
		visible = false,
		suffix = function(val)
			return val == 1 and 'second' or 'seconds'
		end
	})

	verticalClipLoops = testFly:slider('Clip Loop Count', {
		min = 1,
		max = 20,
		default = 8,
		sub = true,
		visible = false
	})

	verticalClipMaxY = testFly:slider('Max Y', {
		min = -500,
		max = 190,
		decimal = 10,
		default = 180,
		sub = true,
		visible = false,
		about = 'Exact absolute world-space Y to clip to after the velocity sequence'
	})

	jumpDuration = testFly:slider('Jump Duration', {
		min = 0.3,
		max = 3,
		decimal = 100,
		default = 1.2,
		sub = true,
		visible = false,
		suffix = function(val)
			return val == 1 and 'second' or 'seconds'
		end,
		about = 'Time the Jump rise takes to reach its apex (for an aimed arc, the latest it may peak)'
	})

	jumpHeightAbove = testFly:slider('Jump Height Above Blocks', {
		min = 0,
		max = 200,
		default = 125,
		sub = true,
		visible = false,
		suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end,
		about = 'Max Y before damage: the highest map block top plus this many studs'
	})

	jumpMargin = testFly:slider('Jump Margin', {
		min = 0,
		max = 30,
		decimal = 10,
		default = 5,
		sub = true,
		visible = false,
		suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end,
		about = 'How far below Max Y the Jump apex stops'
	})

	wallCheck = testFly:toggle('Wall Check', {
		default = true
	})

	popBalloons = testFly:toggle('Pop Balloons', {
		default = true
	})

	notifications = testFly:toggle('Notifications', {
		about = 'Reports takeoff/landing flight stats and keeps Once modes enabled until landing'
	})

	store.TestFlyJump = {
		AutoWinOwned = false,
		Target = nil,
		Clearance = nil,
		ApexY = function()
			local top = getHighestMapBlockTop()
			return top and top + jumpHeightAbove.value - jumpMargin.value or nil
		end,
		CachedApexY = function()
			if not jumpCeilingCurrent(bedwars.BlockController:getStore()) then
				return nil
			end
			return jumpCeiling.Top + jumpHeightAbove.value - jumpMargin.value
		end,
		Duration = function()
			return math.max(jumpDuration.value, 0.05)
		end
	}

	ModeContext.Options = {
		Mode = modeDropdown,
		Speed = amount,
		VerticalSpeed = verticalValue,
		Velocity = velocityBounceValue,
		CFrame = cFrameBounceValue,
		Repeat = bounceRepeat,
		Wait = bounceWait,
		IncreaseVelocity = velocityIncrease,
		IncreaseCFrame = cFrameIncrease,
		ClipVelocity = verticalClipVelocity,
		ClipIncrement = verticalClipIncrement,
		ClipWait = verticalClipWait,
		ClipLoopCount = verticalClipLoops,
		MaxY = verticalClipMaxY,
		JumpDuration = jumpDuration,
		JumpHeightAbove = jumpHeightAbove,
		JumpMargin = jumpMargin,
		WallCheck = wallCheck,
		PopBalloons = popBalloons,
		Notifications = notifications
	}

	updateModeVisibility(modeDropdown.value)
end)	
--[[ HitBoxes
Makes other players easier to hit. Sword mode widens the swing's region check to Expand; Player mode
welds a larger invisible part (3 x 6 x 3 plus Expand / 5) to each player's root. With
debug.setconstant the swing's 3.8 constant becomes Expand / 3. Without it (Solara, Xeno)
swingSwordInRegion is wrapped, and only inside its own call, told apart by its thread because it can
wait, a getTargetInRegion range of 3.8 * 3 becomes Expand. A sword's own attackRange and every other
caller, TriggerBot among them, keep the range they asked for. ]]
run(function()
	if exec.skip('HitBoxes') then return end
	if exec.Knitless then
		exec.hide('HitBoxes', "needs BedWars' Knit, which this executor cannot load")
		return
	end
	local mode
	local expand
	local objects, set = {}
	
	local function createHitbox(ent)
		if ent.Targetable and ent.Player then
			local hitbox = Instance.new('Part')
			hitbox.Size = Vector3.new(3, 6, 3) + Vector3.one * (expand.value / 5)
			hitbox.Position = ent.RootPart.Position
			hitbox.CanCollide = false
			hitbox.Massless = true
			hitbox.Transparency = 1
			hitbox.Parent = ent.Character
			local weld = Instance.new('Motor6D')
			weld.Part0 = hitbox
			weld.Part1 = ent.RootPart
			weld.Parent = hitbox
			objects[ent] = hitbox
		end
	end

	local swingThreads = setmetatable({}, {__mode = 'k'})
	local swingHook, targetHook
	local REGION_RANGE = 3.8 * 3

	local function unwrapSword()
		if swingHook then
			swingHook.remove()
			swingHook = nil
		end
		if targetHook then
			targetHook.remove()
			targetHook = nil
		end
		table.clear(swingThreads)
	end

	local function wrapSword()
		unwrapSword()
		local controller = bedwars.SwordController
		swingHook = fieldPatch.wrap(controller, 'swingSwordInRegion', function(swing)
			return function(self, ...)
				local thread = coroutine.running()
				swingThreads[thread] = (swingThreads[thread] or 0) + 1
				local results = table.pack(pcall(swing, self, ...))
				local depth = (swingThreads[thread] or 1) - 1
				swingThreads[thread] = depth > 0 and depth or nil
				if not results[1] then error(results[2], 0) end
				return table.unpack(results, 2, results.n)
			end
		end)
		targetHook = fieldPatch.wrap(controller, 'getTargetInRegion', function(getTarget)
			return function(self, range, ...)
				if swingThreads[coroutine.running()] and type(range) == 'number'
					and math.abs(range - REGION_RANGE) < 1e-6 then
					range = expand.value
				end
				return getTarget(self, range, ...)
			end
		end)
	end

	hitBoxes = blatant:module('HitBoxes', {
		info = function()
			return expand and tostring(expand.value) or nil
		end,
		label = 'Hitboxes',
		tab = 'Combat',
		toggled = function(on)
			if on then
				if mode.value == 'Sword' then
					if fieldPatch.constants then
						debug.setconstant(bedwars.SwordController.swingSwordInRegion, 6, (expand.value / 3))
					else
						wrapSword()
					end
					set = true
				else
					hitBoxes:clean(entitylib.Events.EntityAdded:Connect(createHitbox))
					hitBoxes:clean(entitylib.Events.EntityRemoving:Connect(function(ent)
						if objects[ent] then
							objects[ent]:Destroy()
							objects[ent] = nil
						end
					end))
					for _, ent in entitylib.List do
						createHitbox(ent)
					end
				end
			else
				if set then
					if fieldPatch.constants then
						debug.setconstant(bedwars.SwordController.swingSwordInRegion, 6, 3.8)
					else
						unwrapSword()
					end
					set = nil
				end
				for _, part in objects do
					part:Destroy()
				end
				table.clear(objects)
			end
		end,
		about = 'Makes other players easier to hit.\nEither widens your sword swing or grows their hitboxes.'
	})
	expand = hitBoxes:slider('Expand amount', {
		label = 'Expand',
		min = 0,
		max = 14.4,
		default = 14.4,
		decimal = 10,
		changed = function(val)
			if hitBoxes.enabled then
				if mode.value == 'Sword' then
					if fieldPatch.constants then
						debug.setconstant(bedwars.SwordController.swingSwordInRegion, 6, (val / 3))
					end
				else
					for _, part in objects do
						part.Size = Vector3.new(3, 6, 3) + Vector3.one * (val / 5)
					end
				end
			end
		end,
		suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
	hitBoxes:divider('Extras')
	mode = hitBoxes:dropdown('Mode', {
		choices = {'Sword', 'Player'},
		changed = function()
			if hitBoxes.enabled then
				hitBoxes:flip(nil, true)
				hitBoxes:flip(nil, true)
			end
		end,
		about = 'Sword - widens the range you can hit people from\nPlayer - grows the players own hitboxes'
	})
end)
	
	
--[[ KeepSprint
Keeps your sprint while you attack. With debug.setconstant, startSprinting reads blockSprinting
instead of blockSprint. Without it (Solara, Xeno) startSprinting is wrapped to clear
self.blockSprint for its own call and put it back afterwards, unless the controller wrote a newer
value meanwhile. ]]
run(function()
	if exec.skip('KeepSprint') then return end
	if exec.Knitless then
		exec.hide('KeepSprint', "needs BedWars' Knit, which this executor cannot load")
		return
	end
	local sprintHook

	blatant:module('KeepSprint', {
		toggled = function(on)
			if fieldPatch.constants then
				debug.setconstant(bedwars.SprintController.startSprinting, 5, on and 'blockSprinting' or 'blockSprint')
			else
				if sprintHook then
					sprintHook.remove()
					sprintHook = nil
				end
				if on then
					sprintHook = fieldPatch.wrap(bedwars.SprintController, 'startSprinting', function(start)
						return function(self, ...)
							local blocked = self.blockSprint
							if not blocked then return start(self, ...) end
							self.blockSprint = false
							local results = table.pack(pcall(start, self, ...))
							if self.blockSprint == false then
								self.blockSprint = blocked
							end
							if not results[1] then error(results[2], 0) end
							return table.unpack(results, 2, results.n)
						end
					end)
				end
			end
			bedwars.SprintController:stopSprinting()
		end,
		about = 'Keeps your sprint speed when attacking players.'
	})
end)

--[[ SafeWalk
Stops you walking off ledges: with no ground below the next step, the move vector of PlayerModule's
controls is bent back onto the block under you. TargetStrafe and AutoWin wrap the same moveFunction,
so turning off puts the previous one back only while this hook is still on top; otherwise it stays
in the chain as a pass-through. ]]
run(function()
	if exec.skip('SafeWalk') then return end
	local safeWalk
	local rayCheck = RaycastParams.new()
	rayCheck.RespectCanCollide = true
	local module, current

	safeWalk = world:module('SafeWalk', {
		tab = 'Move',
		toggled = function(on)
			if on then
				if not module then
					local suc = pcall(function()
						module = require(lplr.PlayerScripts.PlayerModule).controls
					end)
					if not suc or type(module) ~= 'table' then module = {} end
				end

				local old = module.moveFunction
				if type(old) ~= 'function' then return end
				local state = {Active = true, Previous = old}
				current = state
				state.Hook = function(self, vec, face)
					if state.Active and entitylib ~= nil and entitylib.isAlive then
						rayCheck.FilterDescendantsInstances = {lplr.Character, gameCamera}
						local root = entitylib.character.RootPart
						local movedir = root.Position + vec
						local ray = workspace:Raycast(movedir, Vector3.new(0, -15, 0), rayCheck)
						if not ray then
							local check = workspace:Blockcast(root.CFrame, Vector3.new(3, 1, 3), Vector3.new(0, -(entitylib.character.HipHeight + 1), 0), rayCheck)
							if check then
								vec = (check.Instance:GetClosestPointOnSurface(movedir) - root.Position) * Vector3.new(1, 0, 1)
							end
						end
					end

					return old(self, vec, face)
				end
				module.moveFunction = state.Hook
			else
				if current then
					current.Active = false
					if module and module.moveFunction == current.Hook then
						module.moveFunction = current.Previous
					end
					current = nil
				end
			end
		end,
		about = 'Prevents you from walking off ledges.'
	})
end)

--[[ NoSlowdown
Removes slowdown while using items. ]]
run(function()
	if exec.skip('NoSlowdown') then return end
	local old
	
	blatant:module('NoSlowdown', {
		label = 'No Slow',
		toggled = function(on)
			local modifier = bedwars.SprintController:getMovementStatusModifier()
			if on then
				old = modifier.addModifier
				modifier.addModifier = function(self, tab)
					if tab.moveSpeedMultiplier then
						tab.moveSpeedMultiplier = math.max(tab.moveSpeedMultiplier, 1)
					end
					return old(self, tab)
				end
	
				for i in modifier.modifiers do
					if (i.moveSpeedMultiplier or 1) < 1 then
						modifier:removeModifier(i)
					end
				end
			else
				modifier.addModifier = old
				old = nil
			end
		end,
		about = 'Removes slowdown while using items.'
	})
end)
	
--[[ Speed
Tops your walk speed up to Speed each physics step, except while climbing or while Fly, TestFly or
LongJump is on. Blatant spends getSpeed(), which includes DamageBoost's boost, so a boosting hit
also carries you further; Legit uses rawGetSpeed, the speed the server thinks you have.

Pause on Lagback asks the executor's own isnetworkowner (the file's local one answers true on most
executors) at most every 0.1 s, and stops while the server holds the character; without one it never
pauses. The Zephyr boost is turned from a moveSpeedMultiplier into a constantSpeedMultiplier: by
debug.setconstant, by replacing WindWalkerController.updateSpeed with the same function changed in
that key, or knitless through the stand-in's setSpeedConversion. AutoJump reads the bare global
Attacking, which bedwars.lua's Killaura sets every Heartbeat in the shared environment; it stays a
global unless it moves onto genv. ]]
run(function()
	local speed
	local mode
	local amount
	local wallCheck
	local autoJump
	local alwaysJump
	local pauseOnLagback
	local rayCheck = RaycastParams.new()
	rayCheck.RespectCanCollide = true
	local ownedAt, owned = 0, true
	local function ownsCharacter(root)
		if not pauseOnLagback.enabled then
			return isnetworkowner(root)
		end
		local now = os.clock()
		if now - ownedAt >= 0.1 then
			ownedAt = now
			local check = genv.isnetworkowner
			if type(check) == 'function' then
				local ok, result = pcall(check, root)
				owned = not ok or result == true
			else
				owned = isnetworkowner(root)
			end
		end
		return owned
	end

	local zephyrHook
	local function setZephyrSpeed(enabled)
		if zephyrHook then
			zephyrHook.remove()
			zephyrHook = nil
		end
		local controller = bedwars.WindWalkerController
		if type(controller) == 'table' and type(controller.setSpeedConversion) == 'function' then
			controller:setSpeedConversion(enabled)
			return
		end
		if not enabled then return end
		zephyrHook = fieldPatch.wrap(bedwars.WindWalkerController, 'updateSpeed', function()
			return function(self, multiplier)
				if self.currentSpeedModifier then
					self.currentSpeedModifier:Destroy()
				end
				if multiplier == 1 then
					return nil
				end
				self.currentSpeedModifier = bedwars.SprintController:getMovementStatusModifier():addModifier({
					constantSpeedMultiplier = multiplier
				})
			end
		end)
	end

	speed = blatant:module('Speed', {
		toggled = function(on)
			frictionTable.Speed = on or nil
			updateVelocity()
			if fieldPatch.constants then
				pcall(function()
					debug.setconstant(bedwars.WindWalkerController.updateSpeed, 7, on and 'constantSpeedMultiplier' or 'moveSpeedMultiplier')
				end)
			else
				pcall(setZephyrSpeed, on)
			end
	
			if on then
				speed:clean(runService.PreSimulation:Connect(function(dt)
					bedwars.StatefulEntityKnockbackController.lastImpulseTime = on and math.huge or time()
						if entitylib.isAlive and not fly.enabled and not testFly.enabled and not (slinky.modules.LongJump and slinky.modules.LongJump.enabled) and ownsCharacter(entitylib.character.RootPart) then
						local char = entitylib.character
						local hum = char.Humanoid
						local state = hum:GetState()
						if state == Enum.HumanoidStateType.Climbing then return end

						local root = char.RootPart
						local velo = (mode.value == 'Legit' and rawGetSpeed or getSpeed)()
						local moveDirection = antiFallDirection or hum.MoveDirection
						local destination = (moveDirection * math.max(amount.value - velo, 0) * dt)

						if wallCheck.enabled then
							rayCheck.FilterDescendantsInstances = {lplr.Character, gameCamera}
							rayCheck.CollisionGroup = root.CollisionGroup
							local ray = workspace:Raycast(root.Position, destination, rayCheck)
							if ray then
								destination = ((ray.Position + ray.Normal) - root.Position)
							end
						end

						root.CFrame += destination
						root.AssemblyLinearVelocity = (moveDirection * velo) + Vector3.new(0, root.AssemblyLinearVelocity.Y, 0)
						if autoJump.enabled and (state == Enum.HumanoidStateType.Running or state == Enum.HumanoidStateType.Landed) and moveDirection ~= Vector3.zero and (Attacking or alwaysJump.enabled) then
							hum:ChangeState(Enum.HumanoidStateType.Jumping)
						end
					end
				end))
			end
		end,
		info = function()
			return 'Heatseeker'
		end,
		about = 'Makes you move faster than normal.\nCan also jump for you while you fight, or all the time.'
	})
	mode = speed:dropdown('Mode', {
		choices = {'Blatant', 'Legit'},
		default = 'Blatant',
		about = 'Legit ignores the DamageBoost speed boost when working out how\nmuch to top you up. Blatant spends it.'
	})
	amount = speed:slider('Speed', {
		min = 1,
		max = 23,
		default = 23,
		suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
	wallCheck = speed:toggle('Wall Check', {
		default = true
	})
	autoJump = speed:toggle('AutoJump', {
		changed = function(callback)
			alwaysJump.row.Visible = callback
		end
	})
	alwaysJump = speed:toggle('Always Jump', {
		visible = false,
		sub = true
	})
	pauseOnLagback = speed:toggle('Pause on Lagback', {
		visible = not exec.skip('Speed/Pause on Lagback'),
		about = 'Stops speeding while the server holds your character\n(no network ownership of it: a lagback).'
	})
end)
	
--[[ BedESP
Draws every bed with the Drawing library, like ESP: a 2D or 3D box, fill, health bar, team name with
a background, a distance range, and Priority Only to hide your own team's bed. Nothing is parented
anywhere, so no executor can refuse a GUI permission; without a Drawing library it does not start.

The 'bed' tag sits on the model's invisible Root, one block. The bed lies across that block and the
next along the Root's +Z, and the block engine files both under it
(BedBlockHandler:getContainedPositions), so bed and og_bed get a 3 x 3 x 6 box half a block along
+Z. Anything else tagged keeps its own part or model bounding box.

A bed's team is the id in its Team<id>NoBreak attribute; name and colour come from the queue meta
(displayName, colorHex), else 'Team <id>' and the blanket's colour. A placed bed replicates a moment
before that attribute, so it is added 0.2 s later and its team is looked up twice a second until
known. Priority Only compares against your team as it is at draw time, since teams are given out
after the lobby. Knitless, the queue meta has no teams: a player whose Team attribute is the bed's
id names the Roblox Team, else the one Team whose TeamColor matches the bed's paint with no player
of another team on it. Health is the block engine's value over MaxHealth or the block meta's, read 5
times a second; with no max known the highest value seen stands in.

The 2D box, bar and name are written only when they moved, visibility only when it changes, and
everything is hidden while the menu is open or a corner is behind the camera. Removal waits a frame,
because the tag signal fires inside the write that caused it. Drawings are also removed on uninject.
]]
run(function()
	local bedESP
	local method
	local color
	local teamColor
	local boundingBox
	local filled
	local healthBar
	local name
	local background
	local teammates
	local distance
	local distanceLimit
	local reference = {}
	local menuHidden = false

	local CORNERS = {
		Vector3.new(-1, -1, -1), Vector3.new(1, -1, -1), Vector3.new(1, -1, 1), Vector3.new(-1, -1, 1),
		Vector3.new(-1, 1, -1), Vector3.new(1, 1, -1), Vector3.new(1, 1, 1), Vector3.new(-1, 1, 1)
	}
	local EDGES = {
		{1, 2}, {2, 3}, {3, 4}, {4, 1},
		{5, 6}, {6, 7}, {7, 8}, {8, 5},
		{1, 5}, {2, 6}, {3, 7}, {4, 8}
	}

	local function bedTeam(bed)
		for name in bed:GetAttributes() do
			local id = name:match('^Team(.+)NoBreak$')
			if id then return id end
		end
	end

	local teamsService

	local function rosterTeam(teamId, paint)
		local id, brick = tostring(teamId), paint and BrickColor.new(paint).Number
		local held, loose = {}, nil
		for _, plr in playersService:GetPlayers() do
			local team, attribute = plr.Team, plr:GetAttribute('Team')
			if team and attribute ~= nil and team.Name ~= 'Spectators' then
				if tostring(attribute) ~= id then
					held[team.Name] = true
				elseif not brick or team.TeamColor.Number == brick then
					return team
				else
					loose = team
				end
			end
		end
		if brick then
			teamsService = teamsService or cloneref(game:GetService('Teams'))
			local found, count = nil, 0
			for _, team in teamsService:GetTeams() do
				if team.TeamColor.Number == brick and team.Name ~= 'Spectators' and not held[team.Name] then
					found, count = team, count + 1
				end
			end
			if count == 1 then return found end
		end
		return loose
	end

	local function teamInfo(bed, teamId)
		local name, color
		pcall(function()
			local meta = bedwars.QueueMeta[store.queueType]
			for _, team in (meta and meta.teams or {}) do
				if teamId and tostring(team.id) == tostring(teamId) then
					name = team.displayName
					local hex = tonumber(team.colorHex)
					if hex then
						color = Color3.fromRGB(hex // 65536 % 256, hex // 256 % 256, hex % 256)
					end
					break
				end
			end
		end)
		if exec.Knitless and teamId and not (name and color) then
			pcall(function()
				local part = bed:FindFirstChild('Bed')
				local paint = part and part:IsA('BasePart') and part.Color or nil
				local team = rosterTeam(teamId, paint)
				name = name or (team and team.Name)
				color = color or paint or (team and team.TeamColor.Color)
			end)
		end
		if not color then
			local part = bed:FindFirstChild('Blanket') or bed:FindFirstChild('Covers')
			color = part and part:IsA('BasePart') and part.Color or nil
		end
		return name or (teamId and 'Team '..tostring(teamId)) or 'Bed', color, exec.Knitless and teamId ~= nil and name == nil
	end

	local function bedHealth(bed)
		local health
		pcall(function()
			local _, cell = getPlacedBlock(bed.Position)
			local data = cell and bedwars.BlockController:getStore():getBlockData(cell)
			health = data and (data:GetAttribute('1') or data:GetAttribute('Health'))
		end)
		health = tonumber(health) or tonumber(bed:GetAttribute('Health'))
		local meta = bedwars.ItemMeta[bed.Name]
		local maxHealth = tonumber(bed:GetAttribute('MaxHealth')) or (meta and meta.block and tonumber(meta.block.health))
		return health, maxHealth
	end

	local TWO_BLOCK_BEDS = {bed = true, og_bed = true}
	local TWO_BLOCK_OFFSET = CFrame.new(0, 0, 1.5)
	local TWO_BLOCK_SIZE = Vector3.new(3, 3, 6)

	local function bedBox(bed)
		if bed:IsA('BasePart') then
			if TWO_BLOCK_BEDS[bed.Name] then
				return bed.CFrame * TWO_BLOCK_OFFSET, TWO_BLOCK_SIZE
			end
			return bed.CFrame, bed.Size
		end
		local ok, cframe, size = pcall(bed.GetBoundingBox, bed)
		if ok then return cframe, size end
	end

	local function colorOf(ref)
		return teamColor.enabled and ref.TeamColor or Color3.fromHSV(color.hue, color.sat, color.value)
	end

	local function newDrawing(class, props)
		local object = Drawing.new(class)
		for key, value in props do
			object[key] = value
		end
		return object
	end

	local function removeBed(bed)
		local ref = reference[bed]
		if not ref then return end
		reference[bed] = nil
		if slinky.threadFix then
			setthreadidentity(8)
		end
		for _, object in ref.Objects do
			pcall(function()
				object.Visible = false
				object:Remove()
			end)
		end
	end

	local function addBed(bed)
		if reference[bed] or not bed.Parent then return end
		local teamId = bedTeam(bed)
		if teammates.enabled and teamId and tostring(teamId) == tostring(lplr:GetAttribute('Team')) then return end
		if slinky.threadFix then
			setthreadidentity(8)
		end

		local teamName, teamColor, retry = teamInfo(bed, teamId)
		local ref = {Objects = {}, Points = {}, TeamColor = teamColor, Label = teamName..' Bed', HealthAt = 0, TeamId = teamId, TeamAt = 0, Retry = retry}
		local color = colorOf(ref)
		local ok = pcall(function()
			local objects = ref.Objects
			if method.value == '3D' then
				ref.Lines = {}
				for index = 1, #EDGES do
					local line = newDrawing('Line', {Thickness = 1, Color = color, ZIndex = 2})
					ref.Lines[index] = line
					table.insert(objects, line)
				end
			else
				ref.Main = newDrawing('Square', {
					Thickness = 1, Filled = false, ZIndex = 2, Color = color,
					Transparency = boundingBox.enabled and 1 or 0
				})
				table.insert(objects, ref.Main)
				if boundingBox.enabled then
					ref.Border = newDrawing('Square', {Thickness = 1, Filled = false, ZIndex = 1, Color = Color3.new(), Transparency = 0.35})
					ref.Border2 = newDrawing('Square', {Thickness = 1, Filled = filled.enabled, ZIndex = 1, Color = Color3.new(), Transparency = 0.35})
					table.insert(objects, ref.Border)
					table.insert(objects, ref.Border2)
				end
			end
			if healthBar.enabled then
				ref.HealthBorder = newDrawing('Line', {Thickness = 3, ZIndex = 1, Color = Color3.new(), Transparency = 0.35})
				ref.HealthLine = newDrawing('Line', {Thickness = 1, ZIndex = 2, Color = Color3.fromHSV(1 / 2.5, 0.89, 0.75)})
				table.insert(objects, ref.HealthBorder)
				table.insert(objects, ref.HealthLine)
			end
			if name.enabled then
				if background.enabled then
					ref.TextBKG = newDrawing('Square', {Thickness = 1, Filled = true, ZIndex = 0, Color = Color3.new(), Transparency = 0.35})
					table.insert(objects, ref.TextBKG)
				end
				ref.Drop = newDrawing('Text', {Text = ref.Label, Color = Color3.new(), Center = true, Size = 18, ZIndex = 1})
				ref.Text = newDrawing('Text', {Text = ref.Label, Color = color, Center = true, Size = 18, ZIndex = 2})
				table.insert(objects, ref.Drop)
				table.insert(objects, ref.Text)
			end
			for _, object in objects do
				object.Visible = false
			end
		end)
		reference[bed] = ref
		if not ok then
			removeBed(bed)
		end
	end

	local function recolor()
		for _, ref in reference do
			local color = colorOf(ref)
			pcall(function()
				if ref.Main then ref.Main.Color = color end
				if ref.Text then ref.Text.Color = color end
				for _, line in (ref.Lines or {}) do
					line.Color = color
				end
			end)
		end
	end

	local function hide(ref)
		if ref.Shown == false then return end
		ref.Shown = nil
		for _, object in ref.Objects do
			object.Visible = false
		end
		ref.Shown = false
	end

	local function show(ref)
		if ref.Shown == true then return end
		ref.Shown = nil
		for _, object in ref.Objects do
			object.Visible = true
		end
		ref.Shown = true
	end

	local function teamOf(bed, ref)
		if (ref.TeamId == nil or ref.Retry) and os.clock() >= ref.TeamAt then
			ref.TeamAt = os.clock() + 0.5
			local teamId = ref.TeamId or bedTeam(bed)
			if teamId then
				ref.TeamId = teamId
				local teamName, teamColor, retry = teamInfo(bed, teamId)
				ref.Label, ref.TeamColor, ref.Retry = teamName..' Bed', teamColor, retry
				local color = colorOf(ref)
				pcall(function()
					if ref.Text then
						ref.Text.Text = ref.Label
						ref.Text.Color = color
					end
					if ref.Drop then ref.Drop.Text = ref.Label end
					if ref.Main then ref.Main.Color = color end
					for _, line in (ref.Lines or {}) do
						line.Color = color
					end
				end)
			end
		end
		return ref.TeamId
	end

	local function render()
		if clickGuiOpen() then
			if not menuHidden then
				for _, ref in reference do
					pcall(hide, ref)
				end
				menuHidden = true
			end
			return
		end
		menuHidden = false
		local camera = workspace.CurrentCamera
		local rootPos = entitylib.isAlive and entitylib.character.RootPart.Position
		local now = os.clock()
		local ownTeam = teammates.enabled and lplr:GetAttribute('Team')
		for bed, ref in reference do
			if not bed.Parent then
				removeBed(bed)
				continue
			end
			local teamId = teamOf(bed, ref)
			if ownTeam ~= nil and ownTeam ~= false and teamId ~= nil and tostring(teamId) == tostring(ownTeam) then
				hide(ref)
				continue
			end
			local cframe, size = bedBox(bed)
			if not cframe then
				hide(ref)
				continue
			end
			if distance.enabled then
				local distance = rootPos and (rootPos - cframe.Position).Magnitude or math.huge
				if distance < distanceLimit.min or distance > distanceLimit.max then
					hide(ref)
					continue
				end
			end

			local points, minX, minY, maxX, maxY = ref.Points, math.huge, math.huge, -math.huge, -math.huge
			local behind = false
			for index, corner in CORNERS do
				local screen = camera:WorldToViewportPoint(cframe:PointToWorldSpace(corner * size / 2))
				if screen.Z <= 0 then
					behind = true
					break
				end
				local point = Vector2.new(screen.X, screen.Y)
				points[index] = point
				minX, minY = math.min(minX, point.X), math.min(minY, point.Y)
				maxX, maxY = math.max(maxX, point.X), math.max(maxY, point.Y)
			end
			if behind then
				hide(ref)
				continue
			end
			show(ref)

			local posX, posY = minX // 1, minY // 1
			local sizeX, sizeY = math.max((maxX - minX) // 1, 2), math.max((maxY - minY) // 1, 2)
			local moved = posX ~= ref.DrawnX or posY ~= ref.DrawnY or sizeX ~= ref.DrawnW or sizeY ~= ref.DrawnH
			if ref.Lines then
				for index, edge in EDGES do
					ref.Lines[index].From = points[edge[1]]
					ref.Lines[index].To = points[edge[2]]
				end
			elseif ref.Main and moved then
				ref.Main.Position = Vector2.new(posX, posY)
				ref.Main.Size = Vector2.new(sizeX, sizeY)
				if ref.Border then
					ref.Border.Position = Vector2.new(posX - 1, posY - 1)
					ref.Border.Size = Vector2.new(sizeX + 2, sizeY + 2)
					ref.Border2.Position = Vector2.new(posX + 1, posY + 1)
					ref.Border2.Size = Vector2.new(sizeX - 2, sizeY - 2)
				end
			end

			if ref.HealthLine then
				if now >= ref.HealthAt then
					ref.HealthAt = now + 0.2
					local health, maxHealth = bedHealth(bed)
					if health and (not maxHealth or maxHealth < health) then
						ref.MaxSeen = math.max(ref.MaxSeen or 0, health)
						maxHealth = ref.MaxSeen
					end
					ref.Fraction = (health and maxHealth and maxHealth > 0) and math.clamp(health / maxHealth, 0, 1) or 1
					ref.HealthLine.Color = Color3.fromHSV(ref.Fraction / 2.5, 0.89, 0.75)
				end
				if moved or ref.DrawnFraction ~= ref.Fraction then
					local barX = posX - 5
					ref.HealthBorder.From = Vector2.new(barX, posY - 1)
					ref.HealthBorder.To = Vector2.new(barX, posY + sizeY + 1)
					ref.HealthLine.From = Vector2.new(barX, posY + sizeY)
					ref.HealthLine.To = Vector2.new(barX, posY + sizeY - (sizeY * (ref.Fraction or 1)) // 1)
					ref.DrawnFraction = ref.Fraction
				end
			end

			if ref.Text then
				local bounds = ref.Text.TextBounds
				if moved or bounds ~= ref.DrawnBounds then
					local textPos = Vector2.new(posX + sizeX / 2, posY - bounds.Y - 4) // 1
					ref.Text.Position = textPos
					ref.Drop.Position = textPos + Vector2.new(1, 1)
					if ref.TextBKG then
						ref.TextBKG.Size = bounds + Vector2.new(8, 4)
						ref.TextBKG.Position = textPos - Vector2.new(4 + bounds.X / 2, 0)
					end
					ref.DrawnBounds = bounds
				end
			end
			ref.DrawnX, ref.DrawnY, ref.DrawnW, ref.DrawnH = posX, posY, sizeX, sizeY
		end
	end

	local function restart()
		if bedESP.enabled then
			bedESP:flip(nil, true)
			bedESP:flip(nil, true)
		end
	end

	bedESP = slinky.categories.Render:module('BedESP', {
		label = 'Block ESP',
		toggled = function(on)
			if on then
				if not pcall(function() assert(Drawing.new) end) then
					notif('BedESP', 'Your executor has no Drawing library to draw with.', 5, 'warning')
					return
				end
				bedESP:clean(collectionService:GetInstanceAddedSignal('bed'):Connect(function(bed)
					task.delay(0.2, addBed, bed)
				end))
				bedESP:clean(collectionService:GetInstanceRemovedSignal('bed'):Connect(function(bed)
					task.defer(removeBed, bed)
				end))
				for _, bed in collectionService:GetTagged('bed') do
					addBed(bed)
				end
				bedESP:clean(runService.RenderStepped:Connect(function()
					local ok = pcall(render)
					if not ok then
						for _, ref in reference do
							pcall(hide, ref)
						end
					end
				end))
				bedESP:clean(task.spawn(function()
					repeat
						task.wait(1)
						for _, bed in collectionService:GetTagged('bed') do
							if not reference[bed] then
								addBed(bed)
							end
						end
					until not bedESP.enabled
				end))
			else
				for bed in reference do
					removeBed(bed)
				end
			end
		end,
		about = 'Shows beds through walls with their team and health.\nPick a 2D or 3D box, colors, labels and range.'
	})
	distance = bedESP:toggle('Distance Check', {
		changed = function(callback)
			distanceLimit.row.Visible = callback
		end
	})
	distanceLimit = bedESP:range('Bed Distance', {
		label = 'Range',
		min = 0,
		max = 1024,
		defaultMin = 0,
		defaultMax = 512,
		sub = true,
		visible = false
	})
	color = bedESP:color('Bed Color', {
		changed = function()
			recolor()
		end
	})
	bedESP:divider('Extras')
	teamColor = bedESP:toggle('Team Color', {
		default = true,
		changed = function()
			recolor()
		end,
		about = 'Draws each bed in its team colour instead of Bed Color'
	})
	method = bedESP:dropdown('Mode', {
		choices = {'2D', '3D'},
		changed = function(val)
			restart()
			boundingBox.row.Visible = val == '2D'
			filled.row.Visible = val == '2D' and boundingBox.enabled
		end
	})
	boundingBox = bedESP:toggle('Bounding Box', {
		changed = function(callback)
			restart()
			if filled then
				filled.row.Visible = callback and method.value == '2D'
			end
		end,
		default = true,
		sub = true
	})
	filled = bedESP:toggle('Filled', {
		changed = restart,
		sub = true
	})
	healthBar = bedESP:toggle('Health Bar', {
		changed = restart,
		default = true,
		sub = true
	})
	name = bedESP:toggle('Name', {
		changed = function(callback)
			restart()
			if background then
				background.row.Visible = callback
			end
		end,
		default = true,
		sub = true,
		about = 'Shows whose bed it is, like Blue Bed'
	})
	background = bedESP:toggle('Show Background', {
		changed = restart,
		sub = true
	})
	teammates = bedESP:toggle('Priority Only', {
		changed = restart,
		default = true,
		about = 'Hides your own team\'s bed'
	})
	boundingBox.row.Visible = method.value == '2D'
	filled.row.Visible = method.value == '2D' and boundingBox.enabled
	background.row.Visible = name.enabled

	slinky:clean(function()
		for bed in reference do
			removeBed(bed)
		end
	end)
end)
	
--[[ Health
Shows your health with a heart 30 px under the crosshair, green above half, yellow down to a fifth
and red below, like Target Info. It moves further down past the Scaffold card or the fly status
while either is shown, and on a screen under 450 px tall it sits beside the crosshair. The label is
written only when its text changes and is hidden while the menu is open. ]]
run(function()
	local health
	local CROWD = {'ScaffoldCount', 'PistonwareFlyStatus'}

	local function healthColor(percent)
		local theme = slinky.libraries.theme or {}
		if percent > 0.5 then
			return theme.Green or Color3.fromRGB(82, 196, 106)
		elseif percent >= 0.2 then
			return theme.Yellow or Color3.fromRGB(245, 190, 60)
		end
		return theme.Red or Color3.fromRGB(221, 70, 71)
	end

	local function healthText()
		local character = entitylib.isAlive and lplr.Character
		local health = character and tonumber(character:GetAttribute('Health'))
		if not health then return '' end
		local maxHealth = tonumber(character:GetAttribute('MaxHealth')) or 100
		local percent = maxHealth > 0 and math.clamp(health / maxHealth, 0, 1) or 0
		return math.round(health)..' <font color="#'..healthColor(percent):ToHex()..'">\u{2665}</font>'
	end

	local function extent(obj)
		local top, bottom = obj.AbsolutePosition.Y, obj.AbsolutePosition.Y + obj.AbsoluteSize.Y
		if obj:IsA('TextLabel') and obj.Text ~= '' then
			local middle = obj.AbsolutePosition.Y + obj.AbsoluteSize.Y / 2
			top = math.min(top, middle - obj.TextBounds.Y / 2)
			bottom = math.max(bottom, middle + obj.TextBounds.Y / 2)
		end
		return top, bottom
	end

	local function place(label)
		local camera = workspace.CurrentCamera
		if camera and camera.ViewportSize.Y > 0 and camera.ViewportSize.Y < 450 then
			label.AnchorPoint = Vector2.new(0, 0.5)
			label.Position = UDim2.new(0.5, 34, 0.5, 0)
			label.TextXAlignment = Enum.TextXAlignment.Left
			return
		end
		local centre = slinky.gui.AbsolutePosition.Y + slinky.gui.AbsoluteSize.Y / 2
		local offset = 30
		for _ = 1, 2 do
			for _, name in CROWD do
				local other = slinky.gui:FindFirstChild(name)
				if other and other:IsA('GuiObject') and other.Visible then
					local top, bottom = extent(other)
					if top < centre + offset + label.AbsoluteSize.Y and bottom > centre + offset then
						offset = math.ceil(bottom - centre) + 4
					end
				end
			end
		end
		label.AnchorPoint = Vector2.new(0.5, 0)
		label.Position = UDim2.new(0.5, 0, 0.5, offset)
		label.TextXAlignment = Enum.TextXAlignment.Center
	end

	health = render:module('Health', {
		toggled = function(on)
			if on then
				local label = Instance.new('TextLabel')
				label.Size = UDim2.fromOffset(100, 20)
				label.Position = UDim2.new(0.5, 0, 0.5, 30)
				label.AnchorPoint = Vector2.new(0.5, 0)
				label.BackgroundTransparency = 1
				label.RichText = true
				label.Text = healthText()
				label.TextSize = 18
				loaderStyle.text(label, 'SemiBold')
				label.TextStrokeColor3 = Color3.new()
				label.TextStrokeTransparency = 0.6
				label.Visible = not clickGuiOpen()
				label.Parent = slinky.gui
				health:clean(label)
				pcall(place, label)
				health:clean(task.spawn(function()
					if slinky.threadFix then
						pcall(setthreadidentity, 8)
					end
					repeat
						task.wait(0.25)
						pcall(place, label)
					until not label.Parent
				end))
				if slinky.threadFix then
					setthreadidentity(8)
				end
				local scaledGui = slinky.gui:FindFirstChild('ScaledGui')
				local clickGui = scaledGui and scaledGui:FindFirstChild('ClickGui')
				if clickGui then
					health:clean(clickGui:GetPropertyChangedSignal('Visible'):Connect(function()
						if slinky.threadFix then
							setthreadidentity(8)
						end
						label.Visible = not clickGui.Visible
					end))
				end
				local shownText = label.Text
				health:clean(slinkyEvents.AttributeChanged.Event:Connect(function()
					local text = healthText()
					if text ~= shownText then
						shownText = text
						label.Text = text
					end
				end))
			end
		end,
		about = 'Puts your health right in the middle of your screen.'
	})
end)
	
--[[ KitESP
Shows an icon over the things your kit collects (bees, orbs, flowers, stars, hidden metal and more)
for every kit you play, Kit Fusion's second kit included. The game adds these tags on its own thread
at identity 2, and a billboard parented to slinky.gui (CoreGui or gethui where the identity can be
set) from that thread fails, so the tag signals only note what came and went and the module's own
loop builds and removes. The identity is raised to 8, or 7 on an executor whose ceiling is lower,
where setthreadidentity(8) throws. A sweep once a second picks up models whose parts had not
streamed in and failed builds. ]]
run(function()
	local kitESP
	local background
	local color = {}
	local scale
	local reference = {}
	local pending = {}
	local removing = {}
	local connections = {}
	local folder = Instance.new('Folder')
	folder.Parent = slinky.gui

	local espKits = {
		alchemist = {'alchemist_ingedients', 'wild_flower'},
		beekeeper = {'bee', 'bee'},
		bigman = {'treeOrb', 'natures_essence_1'},
		ghost_catcher = {'ghost', 'ghost_orb'},
		metal_detector = {'hidden-metal', 'iron'},
		sheep_herder = {'SheepModel', 'purple_hay_bale'},
		sorcerer = {'alchemy_crystal', 'wild_flower'},
		star_collector = {'stars', 'crit_star'}
	}

	local function raiseIdentity()
		if not slinky.threadFix then return end
		if not pcall(setthreadidentity, 8) then
			pcall(setthreadidentity, 7)
		end
	end

	local function added(ent, icon)
		if reference[ent] or not ent.Parent then return end
		local part = ent:IsA('BasePart') and ent or ent:IsA('Model') and (ent.PrimaryPart or ent:FindFirstChild('Root') or ent:FindFirstChildWhichIsA('BasePart', true))
		if not part then return end

		local billboard
		local ok = pcall(function()
			billboard = Instance.new('BillboardGui')
			billboard.Name = icon
			billboard.StudsOffsetWorldSpace = Vector3.new(0, 3, 0)
			local size = scale and scale.value or 1
			billboard.Size = UDim2.fromOffset(36 * size, 36 * size)
			billboard.AlwaysOnTop = true
			billboard.ClipsDescendants = false
			billboard.Adornee = part
			billboard.Enabled = not clickGuiOpen()
			billboard.Parent = folder
			local plate = Instance.new('Frame')
			plate.Name = 'Plate'
			plate.Size = UDim2.fromScale(1, 1)
			plate.BackgroundColor3 = Color3.fromHSV(color.hue, color.sat, color.value)
			plate.BackgroundTransparency = 1 - (background.enabled and color.opacity or 0)
			plate.BorderSizePixel = 0
			plate.Parent = billboard
			loaderStyle.corner(plate, 6)
			loaderStyle.stroke(plate).Enabled = background.enabled
			local image = Instance.new('ImageLabel')
			image.Name = 'Icon'
			image.Size = background.enabled and UDim2.fromScale(0.8, 0.8) or UDim2.fromScale(1, 1)
			image.Position = UDim2.fromScale(0.5, 0.5)
			image.AnchorPoint = Vector2.new(0.5, 0.5)
			image.BackgroundTransparency = 1
			image.BorderSizePixel = 0
			local iconOk, iconImage = pcall(bedwars.getIcon, {itemType = icon}, true)
			image.Image = iconOk and type(iconImage) == 'string' and iconImage or ''
			image.Parent = plate
		end)
		if ok then
			reference[ent] = billboard
		elseif billboard then
			pcall(function() billboard:Destroy() end)
		end
	end

	local function removed(ent)
		local billboard = reference[ent]
		reference[ent] = nil
		if billboard then
			pcall(function() billboard:Destroy() end)
		end
	end

	local function clearAll()
		for _, v in connections do
			v:Disconnect()
		end
		table.clear(connections)
		table.clear(reference)
		table.clear(pending)
		table.clear(removing)
		pcall(function() folder:ClearAllChildren() end)
	end

	kitESP = render:module('KitESP', {
		toggled = function(on)
			raiseIdentity()
			if on then
				local current, lastHidden
				local nextSweep = 0
				repeat
					local now = os.clock()
					if now >= nextSweep then
						nextSweep = now + 1
						local kits = store.activeKits()
						local key = table.concat(kits, ',')
						if key ~= current then
							current = key
							clearAll()
							for _, name in kits do
								local kit = espKits[name]
								if kit then
									table.insert(connections, collectionService:GetInstanceAddedSignal(kit[1]):Connect(function(ent)
										removing[ent] = nil
										pending[ent] = kit[2]
									end))
									table.insert(connections, collectionService:GetInstanceRemovedSignal(kit[1]):Connect(function(ent)
										pending[ent] = nil
										removing[ent] = true
									end))
								end
							end
						end
						for _, name in kits do
							local kit = espKits[name]
							if kit then
								for _, v in collectionService:GetTagged(kit[1]) do
									if not reference[v] then
										pending[v] = kit[2]
									end
								end
							end
						end
					end
					for ent in removing do
						removing[ent] = nil
						removed(ent)
					end
					for ent, icon in pending do
						pending[ent] = nil
						added(ent, icon)
					end
					local hidden = clickGuiOpen()
					if hidden ~= lastHidden then
						lastHidden = hidden
						for _, billboard in reference do
							pcall(function() billboard.Enabled = not hidden end)
						end
					end
					task.wait(0.1)
				until not kitESP.enabled
			else
				clearAll()
			end
		end,
		about = 'Highlights things your kit collects, like bees and orbs.'
	})

	scale = kitESP:slider('Scale', {
		changed = function(val)
			for _, v in reference do
				pcall(function()
					v.Size = UDim2.fromOffset(36 * val, 36 * val)
				end)
			end
		end,
		default = 1,
		min = 0.1,
		max = 1.5,
		decimal = 10
	})
	background = kitESP:toggle('Background', {
		changed = function(callback)
			if color.row then
				color.row.Visible = callback
			end
			for _, v in reference do
				pcall(function()
					v.Plate.BackgroundTransparency = 1 - (callback and color.opacity or 0)
					v.Plate.UIStroke.Enabled = callback
					v.Plate.Icon.Size = callback and UDim2.fromScale(0.8, 0.8) or UDim2.fromScale(1, 1)
				end)
			end
		end,
		default = true
	})
	color = kitESP:color('Background Color', {
		hue = loaderStyle.Hue,
		sat = loaderStyle.Sat,
		value = loaderStyle.Value,
		opacity = 1 - loaderStyle.Transparency,
		changed = function(hue, sat, val, opacity)
			for _, v in reference do
				pcall(function()
					v.Plate.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
					v.Plate.BackgroundTransparency = 1 - (background.enabled and opacity or 0)
				end)
			end
		end,
		sub = true
	})
end)

--[[ The game's own nametags, and who wants them gone.

They are drawn by NametagController.addGameNametag -- the only thing that builds one, since
the game turns Roblox's own Humanoid display off (NameDisplayDistance = 0) and calls this for
every entity, players and mobs alike.

Two modules want them out of the way now. FPS Boost has always had a toggle for it, and
NameTags needs it as well: ours draws the same name and the same health in the same place, so
with the game's still up you get both, one on top of the other. That is what the doubled text
and the stray coloured icon beside each name were -- the icon is the game's, not ours (ours
cannot be drawn at the left of the text: positionIcons is the only thing that ever makes one
visible, and it sets the position in the same breath).

Ref-counted rather than a plain flag, because two owners would otherwise fight: turning FPS
Boost off would hand the game's tags back while NameTags was still drawing its own, and the
doubling would return with no obvious cause. ]]
local gameNametagHiders = {}
local oldAddGameNametag

local function hideGameNametags(owner)
    gameNametagHiders[owner] = true

    local controller = bedwars.NametagController
    if not (controller and bedwars.AppController) then return end
    if oldAddGameNametag then return end

    oldAddGameNametag = controller.addGameNametag
    controller.addGameNametag = function() end
    for _, v in bedwars.AppController:getOpenApps() do
        if tostring(v):find('Nametag') then
            bedwars.AppController:closeApp(tostring(v))
        end
    end
end

--[[ Puts the builder back and re-runs it over everything currently tagged as an entity, since
the tags closed above will not come back on their own until that character is re-tagged (i.e.
respawns). addGameNametag bails on its own for anyone whose tag is already open, so this fills
the gaps without doubling anybody up, and it still honours NoNametag / shouldShowNametag. ]]
local function showGameNametags(owner)
    gameNametagHiders[owner] = nil
    if next(gameNametagHiders) ~= nil then return end

    local controller = bedwars.NametagController
    if not (controller and oldAddGameNametag) then return end

    controller.addGameNametag = oldAddGameNametag
    oldAddGameNametag = nil
    for _, char in collectionService:GetTagged('entity') do
        pcall(function()
            controller:addGameNametag(char)
        end)
    end
end

--[[ NameTags
Draws a name tag over each player and NPC, with optional health, distance, device, team letter,
gear, kit, rank and enchant icons. NameHider is applied while the tag's string is built: NameHider
ignores the NameTags folder, and a tag is built again whenever PistonwareHideNameVersion moves. The
game's own nametags are never switched off; doing so broke them, your own included, after a late
join.

getfontsize is TextService:GetTextBoundsAsync and yields. A build in progress is held in building,
apart from reference, because the render loop drops any reference entry whose label has no Parent;
reference[ent] is set only once the tag is finished and parented, and a removal or restart during
the yield cancels the build. Each tag has at most one measuring thread, which measures the newest
text and is given up on after 5 s. Updates carry a per-entity generation so only the newest one
finishes; the text is written first, already formatted, and every icon has its own pcall.

Text, TextColor3 and attribute signals run their handler inside the write that fired them, so
refreshes and removals run a frame later, once per tag. The tag's own text is hidden and drawn by
two layers, a dark copy one pixel down and right under the coloured text; every write goes through
setTagText and setTagColor. Colour emoji keep their width in the shadow but are not drawn.

Kit, rank and enchant icons sit inline after the text, sized to the tag's height, and only an icon
that shows something takes a slot. The equipment row sits above the tag, centred, filled slots only.
getRanks skips the server once its cache holds anything, so the rank fetch is forced. Every step of
store.enchants -> StatusEffectMeta -> EnchantMeta throws on a nil table. Enchants arrive as
StatusEffect_* character attributes, far more often than EntityUpdated fires, and have their own
watcher.

Health colour: green above half, yellow at half or less, red under a fifth; a MaxHealth of 0 or nil
at build time counts as full health. Distance colour: green past 30 studs, yellow from 10, red
closer. UserInputType numbers: Touch 7, Keyboard 8, Gamepad 9-16; the attribute can replicate after
the build and is watched per player.

passesFilter has to be declared above Added so both call sites see the upvalue. Targetable follows
the Team attribute (bedwars never sets the Team property) and changes during a round, so
EntityUpdated re-asks the filter in both directions. entitylib makes a new entity table when a
character is replaced, and the old one can stay listed with a parented RootPart: an entity whose
Character is not its player's Character is superseded and not drawn, while a nil Character (dead) is
not. An update for an entity missing from entitylib.List (the armour-slot watcher fires 0.1 s after
a slot changes) rebuilds nothing.

The frame loop paints each tag under its own pcall, so one throw cannot freeze the rest. A missing
RootPart hides the tag but keeps its reference entry, through which Removed finds the label.
WorldToViewportPoint is called as a plain function to skip the __namecall hook (on Potassium about a
microsecond and 48 bytes of garbage a call); Position is written only after half a pixel of movement
and Visible only on change. Tags are hidden while the menu is open.

Applying a profile flips the module once per changed option and the starts run back to back, so a
start drops the previous setup first. Once a second a sweep tags whoever is missing one and removes
tags whose player or character is gone; NPC health is polled every 0.2 s. ]]
run(function()
	local nameTags
	local targets
	local color
	local background
	local displayName
	local health
	local distance
	local equipment
	local showKit
	local rank
	local enchant
	local device
	local overrideTarget
	local scale
	local fontOption
	local teammates
	local distanceCheck
	local distanceLimit
	local strings, sizes, reference = {}, {}, {}
	local building = {}
	local updateGen = {}

	local folder
	
	pcall(function()
		folder = Instance.new('Folder')
		folder.Name = 'NameTags'
		folder.Parent = slinky.gui
	end)
	
	local methodused
	local refreshTag

	local pendingRefresh = {}
	local function queueTagRefresh(ent)
		if pendingRefresh[ent] then return end
		pendingRefresh[ent] = true
		task.defer(function()
			pendingRefresh[ent] = nil
			if slinky.threadFix then
				setthreadidentity(8)
			end
			if refreshTag then
				refreshTag(ent)
			end
		end)
	end

	local tagLayers = setmetatable({}, {__mode = 'k'})

	local function shadowRun(run)
		if run == '\u{2665}' then
			return run
		end
		return '<font transparency="1">'..run..'</font>'
	end

	local function readLabelText(label)
		return label.Text
	end

	local function syncTagText(nametag, layers)
		local text = nametag.Text
		layers.Synced = text
		layers.Front.Text = text
		local plain = removeTags(text):gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;')
		layers.Shadow.Text = (plain:gsub('[\128-\255]+', shadowRun))
	end

	local function shadeTag(nametag)
		local shadow = Instance.new('TextLabel')
		shadow.Name = 'TextShadow'
		shadow.BackgroundTransparency = 1
		shadow.Position = UDim2.fromOffset(1, 1)
		shadow.Size = UDim2.fromScale(1, 1)
		shadow.TextColor3 = Color3.new()
		shadow.TextTransparency = 0.35
		local front = Instance.new('TextLabel')
		front.Name = 'TextFront'
		front.BackgroundTransparency = 1
		front.RichText = true
		front.Size = UDim2.fromScale(1, 1)
		front.TextColor3 = nametag.TextColor3
		for _, layer in {shadow, front} do
			layer.FontFace = nametag.FontFace
			layer.TextSize = nametag.TextSize
			layer.Parent = nametag
		end
		shadow.RichText = true
		local layers = {Front = front, Shadow = shadow}
		tagLayers[nametag] = layers
		syncTagText(nametag, layers)
		nametag.TextTransparency = 1
		local function catchUp()
			layers.Queued = false
			if slinky.threadFix then
				setthreadidentity(8)
			end
			if not nametag.Parent or layers.Front.Text == nametag.Text then return end
			syncTagText(nametag, layers)
		end
		nametag:GetPropertyChangedSignal('Text'):Connect(function()
			if layers.Queued then return end
			local ok, text = pcall(readLabelText, nametag)
			if ok and text == layers.Synced then return end
			layers.Queued = true
			task.defer(catchUp)
		end)
	end

	local function setTagText(nametag, text)
		nametag.Text = text
		local layers = tagLayers[nametag]
		if layers then
			syncTagText(nametag, layers)
		end
	end

	local function setTagColor(nametag, colour)
		nametag.TextColor3 = colour
		local layers = tagLayers[nametag]
		if layers then
			layers.Front.TextColor3 = colour
		end
	end

	local rankMeta = (function()
		local suc, res = pcall(function()
			return require(replicatedStorage.TS.rank['rank-meta']).RankMeta
		end)
		return suc and res or nil
	end)()

	local rankRequested = {}

	local function getRankImage(plr)
		if not (rankMeta and plr) then return nil end
		local controller = bedwars.RankController
		local cache = controller and controller.rankCache
		local division = cache and cache[plr.UserId]
		local meta = division and rankMeta[division]
		return meta and meta.image or nil
	end

	local ICON_SIZE = 30
	local rightIcons = {'Kit', 'RankIcon', 'EnchantIcon'}
	local equipmentIcons = {'Hand', 'Helmet', 'Chestplate', 'Boots'}

	local tagIcons = setmetatable({}, {__mode = 'k'})
	local carried = {}

	local function iconsOf(nametag)
		local icons = tagIcons[nametag]
		if not icons then
			icons = {Right = {}, Equipment = {}}
			for _, name in rightIcons do
				local icon = nametag:FindFirstChild(name)
				if icon then
					table.insert(icons.Right, icon)
				end
			end
			for _, name in equipmentIcons do
				local icon = nametag:FindFirstChild(name)
				if icon then
					table.insert(icons.Equipment, icon)
				end
			end
			tagIcons[nametag] = icons
		end
		return icons
	end

	local function positionIcons(nametag, width, height)
		local iconSize = height or ICON_SIZE
		local offset = width + 10
		local icons = iconsOf(nametag)
		for _, icon in icons.Right do
			local shown = icon.Image ~= ''
			icon.Visible = shown
			if shown then
				icon.Size = UDim2.fromOffset(iconSize, iconSize)
				icon.Position = UDim2.fromOffset(offset, 0)
				offset += iconSize
			end
		end

		table.clear(carried)
		for _, icon in icons.Equipment do
			local shown = icon.Image ~= ''
			icon.Visible = shown
			if shown then
				table.insert(carried, icon)
			end
		end
		for index, icon in carried do
			icon.Size = UDim2.fromOffset(iconSize, iconSize)
			icon.Position = UDim2.new(0.5, (index - 1 - #carried / 2) * iconSize, 0, -iconSize)
		end
	end

	local MEASURE_BOUNDS = Vector2.new(100000, 100000)
	local lastMeasured = setmetatable({}, {__mode = 'k'})
	local measuredWidth = setmetatable({}, {__mode = 'k'})
	local measuredHeight = setmetatable({}, {__mode = 'k'})
	local measuring = setmetatable({}, {__mode = 'k'})
	local placedX, placedY = setmetatable({}, {__mode = 'k'}), setmetatable({}, {__mode = 'k'})
	local tagShown = setmetatable({}, {__mode = 'k'})

	local function measureLoop(nametag)
		repeat
			local text = nametag.Text
			if text == lastMeasured[nametag] then
				positionIcons(nametag, measuredWidth[nametag], measuredHeight[nametag])
				return
			end
			local size = getfontsize(removeTags(text), nametag.TextSize, nametag.FontFace, MEASURE_BOUNDS)
			if not nametag.Parent then return end
			if nametag.Text == text then
				lastMeasured[nametag] = text
				measuredWidth[nametag], measuredHeight[nametag] = size.X, size.Y + 7
				nametag.Size = UDim2.fromOffset(size.X + 8, size.Y + 7)
				positionIcons(nametag, size.X, size.Y + 7)
				return
			end
		until false
	end

	local function runMeasure(nametag, started)
		pcall(measureLoop, nametag)
		if measuring[nametag] == started then
			measuring[nametag] = nil
		end
	end

	local function requestMeasure(nametag, relayout)
		local started = measuring[nametag]
		if started and os.clock() - started < 5 then return end
		local width = measuredWidth[nametag]
		if width and nametag.Text == lastMeasured[nametag] then
			if relayout then
				positionIcons(nametag, width, measuredHeight[nametag])
			end
			return
		end
		started = os.clock()
		measuring[nametag] = started
		task.spawn(runMeasure, nametag, started)
	end

	local function forgetTag(nametag)
		tagLayers[nametag] = nil
		tagIcons[nametag] = nil
		lastMeasured[nametag], measuredWidth[nametag], measuredHeight[nametag] = nil, nil, nil
		measuring[nametag] = nil
		placedX[nametag], placedY[nametag] = nil, nil
		tagShown[nametag] = nil
	end

	local function requestRank(plr, ent)
		if not plr or rankRequested[plr.UserId] then return end
		local controller = bedwars.RankController
		if not (controller and controller.getRanks) then return end
		rankRequested[plr.UserId] = true
		task.spawn(function()
			pcall(function()
				controller:getRanks({plr.UserId}, true):andThen(function()
					if refreshTag then refreshTag(ent) end
				end)
			end)
		end)
	end

	local function getEnchantImage(plr)
		if not plr then return nil end
		if not (store.enchants and bedwars.EnchantMeta) then return nil end
		local suc, res = pcall(function()
			return store.enchants[plr].async()
		end)
		return suc and res or nil
	end

	local enchantConns = {}

	local function unwatchEnchant(ent)
		local conn = enchantConns[ent]
		if conn then
			pcall(function() conn:Disconnect() end)
			enchantConns[ent] = nil
		end
	end

	local function watchEnchant(ent)
		unwatchEnchant(ent)
		local char = ent.Character
		if not char then return end
		pcall(function()
			enchantConns[ent] = char.AttributeChanged:Connect(function(attribute)
				if attribute:find('StatusEffect_') then
					queueTagRefresh(ent)
				end
			end)
		end)
	end

	local TAG_GREEN, TAG_YELLOW, TAG_RED = Color3.fromRGB(85, 255, 85), Color3.fromRGB(255, 255, 85), Color3.fromRGB(255, 85, 85)

	local function tagHealthColor(ent)
		local maxHealth = ent.MaxHealth
		local fraction = 1

		if type(maxHealth) == 'number' and maxHealth > 0 then
			fraction = (ent.Health or maxHealth) / maxHealth
		end

		if fraction ~= fraction then
			fraction = 1
		end

		if fraction > 0.5 then
			return TAG_GREEN
		elseif fraction >= 0.2 then
			return TAG_YELLOW
		end
		return TAG_RED
	end

	local TAG_GREEN_HEX, TAG_YELLOW_HEX, TAG_RED_HEX = TAG_GREEN:ToHex(), TAG_YELLOW:ToHex(), TAG_RED:ToHex()
	local function distanceText(studs)
		local hex = studs > 30 and TAG_GREEN_HEX or studs >= 10 and TAG_YELLOW_HEX or TAG_RED_HEX
		return '<font color="#'..hex..'">'..studs..'m</font>'
	end

	local function teamOf(teamId, plr)
		local name, colour
		if teamId ~= nil then
			pcall(function()
				local meta = bedwars.QueueMeta[store.queueType]
				for _, team in (meta and meta.teams or {}) do
					if tostring(team.id) == tostring(teamId) then
						name = team.displayName
						local hex = tonumber(team.colorHex)
						if hex then
							colour = Color3.fromRGB(hex // 65536 % 256, hex // 256 % 256, hex % 256)
						end
						break
					end
				end
			end)
		end
		if not colour and plr and plr.Team and plr.TeamColor then
			colour = plr.TeamColor.Color
		end
		return type(name) == 'string' and name ~= '' and name or nil, colour
	end

	local function readable(colour)
		local _, _, value = colour:ToHSV()
		return value < 0.3 and colour:Lerp(Color3.fromRGB(150, 150, 150), 0.6) or colour
	end

	local function teamLetter(plr)
		local name, colour = teamOf(plr:GetAttribute('Team'), plr)
		if not name then return nil end
		colour = readable(colour or Color3.new(1, 1, 1))
		return '<b><font color="#'..colour:ToHex()..'">'..name:sub(1, 1):upper()..'</font></b>'
	end

	local function tagColor(ent)
		if overrideTarget.enabled then
			return Color3.fromHSV(color.hue, color.sat, color.value)
		end
		local plr = ent.Player
		if plr and isFriend(plr, true) then
			local friends = slinky.categories.Friends.options['Friends color']
			return Color3.fromHSV(friends.hue, friends.sat, friends.value)
		end
		local teamId
		pcall(function()
			if plr then
				teamId = plr:GetAttribute('Team')
			elseif ent.Character then
				local ownerId = ent.Character:GetAttribute('PlayerUserId')
				local owner = ownerId and playersService:GetPlayerByUserId(ownerId)
				teamId = owner and owner:GetAttribute('Team') or ent.Character:GetAttribute('Team')
			end
		end)
		local _, colour = teamOf(teamId, plr)
		return colour and readable(colour) or Color3.new(1, 1, 1)
	end

	local hideVersionOf = setmetatable({}, {__mode = 'k'})

	local function hideNames(text)
		local hide = genv.PistonwareHideName
		if type(hide) ~= 'function' then return text end

		local ok, res = pcall(hide, text)
		return (ok and type(res) == 'string') and res or text
	end

	local deviceEmojis = {gamepad = '🎮', touch = '📱', keyboard = '🖥️'}

	local function getDeviceEmoji(plr)
		if not plr then return nil end
		local inputType = plr:GetAttribute('UserInputType')
		if inputType == nil and plr.Character then
			inputType = plr.Character:GetAttribute('UserInputType')
		end
		if inputType == nil then return nil end
		if type(inputType) == 'number' then
			if inputType == 7 then return deviceEmojis.touch end
			if inputType == 8 then return deviceEmojis.keyboard end
			if inputType >= 9 and inputType <= 16 then return deviceEmojis.gamepad end
			return deviceEmojis.keyboard
		end
		local name = tostring(inputType):lower()
		if name:find('gamepad') or name:find('console') or name:find('xbox') or name:find('playstation') then
			return deviceEmojis.gamepad
		end
		if name:find('touch') or name:find('mobile') or name:find('phone') or name:find('tablet') then
			return deviceEmojis.touch
		end
		return name ~= '' and deviceEmojis.keyboard or nil
	end

	local function passesFilter(ent)
		if not targets.players.enabled and ent.Player then return false end
		if not targets.npcs.enabled and ent.NPC then return false end
		if teammates.enabled and (not ent.Targetable) and (not ent.Friend) then return false end
		return true
	end

	local function tagText(ent)
		hideVersionOf[ent] = genv.PistonwareHideNameVersion
		local text = hideNames(ent.Player and tags:prefix(ent.Player, true)..(displayName.enabled and ent.Player.DisplayName or ent.Player.Name) or ent.Character.Name)
		if overrideTarget.enabled and ent.Player then
			local letter = teamLetter(ent.Player)
			if letter then
				text = letter..' '..text
			end
		end
		if device.enabled and ent.Player then
			local emoji = getDeviceEmoji(ent.Player)
			if emoji then
				text = emoji..' '..text
			end
		end
		if health.enabled then
			text = '<font color="#'..tagHealthColor(ent):ToHex()..'">'..math.round(ent.Health or 0)..'\u{2665}</font> '..text
		end
		if distance.enabled then
			text = text:gsub('%%', '%%%%')..' %s'
		end
		return text
	end

	local function abandonBuild(ent)
		if building[ent] == nil and reference[ent] == nil then
			strings[ent] = nil
			sizes[ent] = nil
			unwatchEnchant(ent)
		end
	end

	local added = {
		Normal = function(ent)
			local token = {}
			pcall(function()
				if not passesFilter(ent) then return end
				if reference[ent] or building[ent] then return end
				building[ent] = token

				local nametag = Instance.new('TextLabel')
				strings[ent] = tagText(ent)

				if equipment.enabled then
					for _, v in equipmentIcons do
						local icon = Instance.new('ImageLabel')
						icon.Name = v
						icon.BackgroundTransparency = 1
						icon.Image = ''
						icon.Visible = false
						icon.Parent = nametag
					end
				end

				nametag.TextSize = 14 * scale.value
				nametag.FontFace = fontOption.value
				local measuredText = strings[ent]
				local size = getfontsize(removeTags(measuredText), nametag.TextSize, nametag.FontFace, MEASURE_BOUNDS)
				if building[ent] ~= token then
					nametag:Destroy()
					abandonBuild(ent)
					return
				end
				nametag.Name = ent.Player and ent.Player.Name or ent.Character.Name
				nametag.Size = UDim2.fromOffset(size.X + 8, size.Y + 7)
				lastMeasured[nametag] = measuredText
				measuredWidth[nametag], measuredHeight[nametag] = size.X, size.Y + 7

				if showKit.enabled and ent.Player then
					local icon = Instance.new('ImageLabel')
					icon.Name = 'Kit'
					icon.Size = UDim2.fromOffset(ICON_SIZE, ICON_SIZE)
					icon.BackgroundTransparency = 1
					icon.Image = getKitRenderImage(ent.Player)
					icon.Visible = false
					icon.Parent = nametag
				end

				if rank.enabled and ent.Player then
					local icon = Instance.new('ImageLabel')
					icon.Name = 'RankIcon'
					icon.Size = UDim2.fromOffset(ICON_SIZE, ICON_SIZE)
					icon.BackgroundTransparency = 1
					icon.Image = getRankImage(ent.Player) or ''
					icon.Visible = false
					icon.Parent = nametag
					if icon.Image == '' then
						requestRank(ent.Player, ent)
					end
				end

				if enchant.enabled and ent.Player then
					local icon = Instance.new('ImageLabel')
					icon.Name = 'EnchantIcon'
					icon.Size = UDim2.fromOffset(ICON_SIZE, ICON_SIZE)
					icon.BackgroundTransparency = 1
					icon.Image = getEnchantImage(ent.Player) or ''
					icon.Visible = false
					icon.Parent = nametag
					watchEnchant(ent)
				end

				positionIcons(nametag, size.X, size.Y + 7)

				nametag.AnchorPoint = Vector2.new(0.5, 1)
				nametag.BackgroundColor3 = Color3.new()
				nametag.BackgroundTransparency = background.value
				nametag.BorderSizePixel = 0
				nametag.Visible = false
				nametag.Text = strings[ent]
				nametag.TextColor3 = tagColor(ent)
				nametag.RichText = true
				shadeTag(nametag)
				if building[ent] ~= token then
					nametag:Destroy()
					abandonBuild(ent)
					return
				end
				reference[ent] = nametag
				building[ent] = nil
				nametag.Parent = folder
			end)
			if building[ent] == token then
				building[ent] = nil
				abandonBuild(ent)
			end
		end
	}
	
	local removed = {
		Normal = function(ent)
			building[ent] = nil
			updateGen[ent] = nil
			pcall(function()
				unwatchEnchant(ent)
				local v = reference[ent]
				if v then
					if slinky.threadFix then
						setthreadidentity(8)
					end
					v:Destroy()
					reference[ent] = nil
					forgetTag(v)
				end
			end)
			if reference[ent] == nil then
				strings[ent] = nil
				sizes[ent] = nil
			end
		end
	}

	local function isListed(ent)
		local list = entitylib.List
		return list ~= nil and table.find(list, ent) ~= nil
	end

	local function supersededEntity(ent)
		local plr = ent.Player
		if not plr then return false end

		local live = plr.Character
		local mine = ent.Character

		return live ~= nil and mine ~= nil and mine ~= live
	end

	local function rebuildTag(ent, method)
		local existing = reference[ent]
		if existing then
			removed[method](ent)
		end

		added[method](ent)
		return reference[ent] ~= nil
	end

	local updated = {
		Normal = function(ent)
			pcall(function()
				if not passesFilter(ent) then
					if reference[ent] or building[ent] then
						removed['Normal'](ent)
					end
					return
				end

				local nametag = reference[ent]

				if not nametag or not nametag.Parent then
					if not isListed(ent) then
						if nametag then
							removed['Normal'](ent)
						end
						return
					end
					rebuildTag(ent, 'Normal')
					return
				end

				if slinky.threadFix then
					setthreadidentity(8)
				end

				local gen = (updateGen[ent] or 0) + 1
				updateGen[ent] = gen

				strings[ent] = tagText(ent)
				local nameColor = tagColor(ent)
				if nametag.TextColor3 ~= nameColor then
					setTagColor(nametag, nameColor)
				end

				if distance.enabled then
					local selfRoot = entitylib.isAlive and entitylib.character.RootPart
					local root = ent.RootPart
					local mag = (selfRoot and root) and math.floor((selfRoot.Position - root.Position).Magnitude) or 0
					setTagText(nametag, string.format(strings[ent], distanceText(mag)))
					sizes[ent] = mag
				else
					setTagText(nametag, strings[ent])
					sizes[ent] = nil
				end

				if equipment.enabled and ent.Player and nametag:FindFirstChild('Hand') then
					pcall(function()
						local inventory = store.inventories[ent.Player]
						if not inventory then return end
						local armor = inventory.armor or {}
						nametag.Hand.Image = bedwars.getIcon(inventory.hand or {itemType = ''}, true)
						nametag.Helmet.Image = bedwars.getIcon(armor[4] or {itemType = ''}, true)
						nametag.Chestplate.Image = bedwars.getIcon(armor[5] or {itemType = ''}, true)
						nametag.Boots.Image = bedwars.getIcon(armor[6] or {itemType = ''}, true)
					end)
				end

				if showKit.enabled and ent.Player then
					pcall(function()
						local icon = nametag:FindFirstChild('Kit')
						if icon then
							icon.Image = getKitRenderImage(ent.Player)
						end
					end)
				end

				if rank.enabled and ent.Player then
					pcall(function()
						local icon = nametag:FindFirstChild('RankIcon')
						if icon then
							icon.Image = getRankImage(ent.Player) or ''
						end
					end)
				end

				if enchant.enabled and ent.Player then
					pcall(function()
						local icon = nametag:FindFirstChild('EnchantIcon')
						if icon then
							icon.Image = getEnchantImage(ent.Player) or ''
						end
					end)
				end

				if updateGen[ent] ~= gen or reference[ent] ~= nametag then return end
				requestMeasure(nametag, true)
			end)
		end
	}
	
	refreshTag = function(ent)
		if reference[ent] and updated[methodused] then
			updated[methodused](ent)
		end
	end

	local colorFunc = {
		Normal = function()
			pcall(function()
				for i, v in reference do
					if v and v.Parent then
						setTagColor(v, tagColor(i))
					end
				end
			end)
		end
	}

	local worldToViewport

	local function setShown(nametag, shown)
		if tagShown[nametag] ~= shown then
			tagShown[nametag] = shown
			nametag.Visible = shown
		end
	end

	local function paintTag(ent, nametag, selfPos)
		local root = ent.RootPart
		if not (root and root.Parent) then
			setShown(nametag, false)
			return
		end

		if supersededEntity(ent) then
			setShown(nametag, false)
			return
		end

		local rootPos = root.Position

		if distanceCheck.enabled then
			local distance = selfPos and (selfPos - rootPos).Magnitude or math.huge
			if distance < distanceLimit.min or distance > distanceLimit.max then
				setShown(nametag, false)
				return
			end
		end

		worldToViewport = worldToViewport or gameCamera.WorldToViewportPoint
		local headPos, headVis = worldToViewport(gameCamera, rootPos + Vector3.new(0, ent.HipHeight + 1, 0))
		setShown(nametag, headVis)
		if not headVis then
			return
		end

		if distance.enabled then
			local mag = selfPos and math.floor((selfPos - rootPos).Magnitude) or 0
			if sizes[ent] ~= mag then
				setTagText(nametag, string.format(strings[ent], distanceText(mag)))
				sizes[ent] = mag
				requestMeasure(nametag)
			end
		end
		local x, y = headPos.X, headPos.Y
		local lastX, lastY = placedX[nametag], placedY[nametag]
		if not lastX or math.abs(x - lastX) >= 0.5 or math.abs(y - lastY) >= 0.5 then
			placedX[nametag], placedY[nametag] = x, y
			nametag.Position = UDim2.fromOffset(x, y)
		end
	end

	local function drawTag(ent, nametag, selfPos)
		pcall(paintTag, ent, nametag, selfPos)
	end

	local function drawAll()
		local selfPos = entitylib.isAlive and entitylib.character.RootPart.Position
		local hidden = clickGuiOpen()
		local hideVersion = genv.PistonwareHideNameVersion
		for ent, nametag in reference do
			if not nametag or not nametag.Parent then
				reference[ent] = nil
				continue
			end
			if hideVersionOf[ent] ~= hideVersion then
				hideVersionOf[ent] = hideVersion
				queueTagRefresh(ent)
			end
			if hidden then
				setShown(nametag, false)
				continue
			end
			drawTag(ent, nametag, selfPos)
		end
	end

	local loop = {
		Normal = function()
			pcall(drawAll)
		end
	}

	local liveSetup = false
	local deviceConns = {}

	local function dropSetup()
		for _, connection in nameTags.connections do
			pcall(function()
				local disconnect = connection.Disconnect or connection.disconnect or connection.Destroy
				if type(disconnect) == 'function' then
					disconnect(connection)
				end
			end)
		end
		table.clear(nameTags.connections)
		table.clear(building)
		table.clear(updateGen)

		if removed[methodused] then
			for ent in reference do
				removed[methodused](ent)
			end
		end
		for ent in enchantConns do
			unwatchEnchant(ent)
		end
		for _, connection in deviceConns do
			pcall(function() connection:Disconnect() end)
		end
		table.clear(deviceConns)
		table.clear(strings)
		table.clear(sizes)

		liveSetup = false
	end

	nameTags = render:module('NameTags', {
		toggled = function(on)
			if on then
				if liveSetup then
					dropSetup()
				end
				liveSetup = true

				methodused = 'Normal'
				if removed[methodused] then
					local remove = removed[methodused]
					nameTags:clean(entitylib.Events.EntityRemoved:Connect(function(ent)
						task.defer(function()
							if slinky.threadFix then
								setthreadidentity(8)
							end
							local list = entitylib.List
							if list and table.find(list, ent) then return end
							remove(ent)
						end)
					end))
				end
				if added[methodused] then
					for _, v in entitylib.List do
						if reference[v] then
							removed[methodused](v)
						end
						added[methodused](v)
					end
					nameTags:clean(entitylib.Events.EntityAdded:Connect(function(ent)
						if reference[ent] then
							removed[methodused](ent)
						end
						added[methodused](ent)
					end))
				end
				if updated[methodused] then
					nameTags:clean(entitylib.Events.EntityUpdated:Connect(updated[methodused]))
					for _, v in entitylib.List do
						updated[methodused](v)
					end
				end
				if colorFunc[methodused] then
					nameTags:clean(slinky.categories.Friends.colorUpdate.Event:Connect(function()
						colorFunc[methodused](color.hue, color.sat, color.value)
					end))
				end
				if loop[methodused] then
					nameTags:clean(runService.RenderStepped:Connect(loop[methodused]))
				end

				local sweepAt = 0
				local npcPollAt = 0
				local listed = {}
				nameTags:clean(runService.Heartbeat:Connect(function()
					local now = os.clock()

					if now >= npcPollAt then
						npcPollAt = now + 0.2
						for ent in reference do
							if ent.NPC and ent.Character and ent.Character.Parent then
								local ok, health, maxHealth = pcall(entitylib.readHealth, ent.Character)
								if ok and (health ~= ent.Health or maxHealth ~= ent.MaxHealth) then
									ent.Health, ent.MaxHealth = health, maxHealth
									refreshTag(ent)
								end
							end
						end
					end

					if now < sweepAt then return end
					sweepAt = now + 1

					local remove = removed[methodused]
					local list = entitylib.List
					if remove and list then
						table.clear(listed)
						for _, ent in list do
							listed[ent] = true
						end
						for ent in reference do
							local gone = not listed[ent]
								or (ent.Player and ent.Player.Parent == nil)
								or not (ent.Character and ent.Character.Parent)
							if gone then
								remove(ent)
							end
						end
						table.clear(listed)
					end

					local add = added[methodused]
					if not add then return end
					for _, ent in entitylib.List do
						local root = ent.RootPart
						if not reference[ent] and not building[ent] and root and root.Parent and not supersededEntity(ent) then
							add(ent)
						end
					end
				end))

				local function watchDevice(plr)
					local old = deviceConns[plr]
					if old then
						old:Disconnect()
					end
					deviceConns[plr] = plr:GetAttributeChangedSignal('UserInputType'):Connect(function()
						if not device.enabled then return end
						local ent = entitylib.getEntity(plr)
						if ent then
							queueTagRefresh(ent)
						end
					end)
				end

				for _, plr in playersService:GetPlayers() do
					watchDevice(plr)
				end
				nameTags:clean(playersService.PlayerAdded:Connect(watchDevice))
				nameTags:clean(playersService.PlayerRemoving:Connect(function(plr)
					local connection = deviceConns[plr]
					if connection then
						deviceConns[plr] = nil
						connection:Disconnect()
					end
				end))
			else
				dropSetup()
			end
		end,
		about = 'Shows clear name tags above other players.\nCan add health, distance, gear, kit, rank and device.'
	})
	scale = nameTags:slider('Scale', {
		changed = function()
			if nameTags.enabled then
				nameTags:flip(nil, true)
				nameTags:flip(nil, true)
			end
		end,
		default = 1,
		min = 0.1,
		max = 1.5,
		decimal = 10
	})
	distanceCheck = nameTags:toggle('Distance Check', {
		changed = function(callback)
			distanceLimit.row.Visible = callback
		end
	})
	distanceLimit = nameTags:range('Player Distance', {
		label = 'Range',
		min = 0,
		max = 256,
		defaultMin = 0,
		defaultMax = 64,
		sub = true,
		visible = false
	})
	nameTags:divider('Extra info')
	health = nameTags:toggle('Health', {
		changed = function()
			if nameTags.enabled then
				nameTags:flip(nil, true)
				nameTags:flip(nil, true)
			end
		end
	})
	distance = nameTags:toggle('Distance', {
		changed = function()
			if nameTags.enabled then
				nameTags:flip(nil, true)
				nameTags:flip(nil, true)
			end
		end
	})
	equipment = nameTags:toggle('Equipment', {
		changed = function()
			if nameTags.enabled then
				nameTags:flip(nil, true)
				nameTags:flip(nil, true)
			end
		end
	})
	enchant = nameTags:toggle('Show Enchant', {
		label = 'Enchantments',
		changed = function()
			if nameTags.enabled then
				nameTags:flip(nil, true)
				nameTags:flip(nil, true)
			end
		end,
		about = 'Puts their active enchant next to the name.'
	})
	nameTags:divider('Extras')
	targets = nameTags:targets({
		players = true,
		changed = function()
			if nameTags.enabled then
				nameTags:flip(nil, true)
				nameTags:flip(nil, true)
			end
		end
	})
	fontOption = nameTags:font('Font', {
		exclude = 'Arial',
		changed = function()
			if nameTags.enabled then
				nameTags:flip(nil, true)
				nameTags:flip(nil, true)
			end
		end
	})
	background = nameTags:slider('Transparency', {
		changed = function()
			if nameTags.enabled then
				nameTags:flip(nil, true)
				nameTags:flip(nil, true)
			end
		end,
		default = 0.5,
		min = 0,
		max = 1,
		decimal = 10
	})
	showKit = nameTags:toggle('Show Kit', {
		changed = function()
			if nameTags.enabled then
				nameTags:flip(nil, true)
				nameTags:flip(nil, true)
			end
		end,
		about = 'Puts their kit icon next to the nametag'
	})
	rank = nameTags:toggle('Show Rank', {
		visible = not exec.skip('NameTags/Show Rank'),
		changed = function()
			if nameTags.enabled then
				nameTags:flip(nil, true)
				nameTags:flip(nil, true)
			end
		end,
		about = 'Puts their ranked division icon next to the name'
	})
	overrideTarget = nameTags:toggle('Override target color', {
		changed = function(callback)
			if color then
				color.row.Visible = callback
			end
			if nameTags.enabled and updated[methodused] then
				task.spawn(function()
					for ent in reference do
						pcall(updated[methodused], ent)
					end
				end)
			end
		end,
		about = 'Every name uses the colour below instead of its team colour, with the team letter in front.'
	})
	color = nameTags:color('Player Color', {
		label = 'Target color',
		changed = function()
			if nameTags.enabled and colorFunc[methodused] then
				colorFunc[methodused]()
			end
		end,
		visible = false
	})
	device = nameTags:toggle('Show Device', {
		changed = function()
			if nameTags.enabled then
				nameTags:flip(nil, true)
				nameTags:flip(nil, true)
			end
		end,
		about = 'Shows 🎮 / 🖥️ / 📱 depending on what they\'re playing on'
	})
	displayName = nameTags:toggle('Use Displayname', {
		changed = function()
			if nameTags.enabled then
				nameTags:flip(nil, true)
				nameTags:flip(nil, true)
			end
		end,
		default = true
	})
	teammates = nameTags:toggle('Priority Only', {
		changed = function()
			if nameTags.enabled then
				nameTags:flip(nil, true)
				nameTags:flip(nil, true)
			end
		end,
		default = true
	})
end)
	
--[[ StorageESP
Shows over each chest an icon for every item on your list that it holds, with the stack total.
Amount is the attribute the game's own chest display reads, and a chest can hold one item in several
stacks.

The billboards live in Pistonware's GUI, and every way in (the module's thread, the chest tag,
contents and Amount changes) arrives without the identity that building there needs, so each path
raises it first. Tag, contents, Amount, layout and menu Visible signals run their handler inside the
write that fired them: builds, refreshes, resizes, removals and folder moves run a frame later, once
per billboard. Each chest's contents listeners go with its billboard. A chest whose contents value
has not streamed in, or whose build failed, is retried by a sweep every second. The folder leaves
the GUI while the menu is open. ]]
run(function()
	local storageESP
	local list
	local showAmount
	local background
	local color = {}
	local reference = {}
	local amountWatch = setmetatable({}, {__mode = 'k'})
	local folder = Instance.new('Folder')
	folder.Parent = slinky.gui
	
	local function nearStorageItem(item)
		for _, v in list.active do
			if item:find(v) then return v end
		end
	end

	local pending = {}
	local chestWatch = {}
	local queueRefresh

	local function refreshAdornee(v)
		if slinky.threadFix then
			setthreadidentity(8)
		end
		if not (v.Parent and v.Adornee) then return end
		local chest = v.Adornee:FindFirstChild('ChestFolderValue')
		chest = chest and chest.Value or nil
		if not chest then
			v.Enabled = false
			return
		end
	
		local chestitems = chest and chest:GetChildren() or {}
		for _, obj in v.Frame:GetChildren() do
			if obj:IsA('ImageLabel') then
				obj:Destroy()
			end
		end
		for _, connection in amountWatch[v] or {} do
			connection:Disconnect()
		end
		amountWatch[v] = {}

		local amounts = {}
		for _, item in chestitems do
			amounts[item.Name] = (amounts[item.Name] or 0) + (tonumber(item:GetAttribute('Amount')) or 1)
		end

		v.Enabled = false
		local alreadygot = {}
		for _, item in chestitems do
			if not alreadygot[item.Name] and (table.find(list.active, item.Name) or nearStorageItem(item.Name)) then
				alreadygot[item.Name] = true
				v.Enabled = true
				local blockimage = Instance.new('ImageLabel')
				blockimage.Size = UDim2.fromOffset(32, 32)
				blockimage.BackgroundTransparency = 1
				local iconOk, icon = pcall(bedwars.getIcon, {itemType = item.Name}, true)
				blockimage.Image = iconOk and type(icon) == 'string' and icon or ''
				blockimage.Parent = v.Frame
				if showAmount.enabled and amounts[item.Name] > 1 then
					local amount = Instance.new('TextLabel')
					amount.Name = 'Amount'
					amount.Size = UDim2.fromOffset(31, 14)
					amount.Position = UDim2.fromOffset(0, 18)
					amount.BackgroundTransparency = 1
					amount.Text = tostring(amounts[item.Name])
					amount.TextXAlignment = Enum.TextXAlignment.Right
					amount.TextSize = 14
					loaderStyle.text(amount, 'Bold')
					amount.TextStrokeColor3 = Color3.new()
					amount.TextStrokeTransparency = 0.4
					amount.Parent = blockimage
				end
			end
		end
		if showAmount.enabled then
			for _, item in chestitems do
				if alreadygot[item.Name] then
					table.insert(amountWatch[v], item:GetAttributeChangedSignal('Amount'):Connect(function()
						queueRefresh(v)
					end))
				end
			end
		end
		table.clear(chestitems)
	end

	local refreshQueued = {}
	queueRefresh = function(bb)
		if refreshQueued[bb] then return end
		refreshQueued[bb] = true
		task.defer(function()
			refreshQueued[bb] = nil
			refreshAdornee(bb)
		end)
	end

	local function added(v)
		if reference[v] or pending[v] then return end
		pending[v] = true
		local chest = v:WaitForChild('ChestFolderValue', 3)
		pending[v] = nil
		chest = chest and chest.Value
		if not (chest and storageESP.enabled and v.Parent) or reference[v] then return end
		if slinky.threadFix then
			setthreadidentity(8)
		end

		local billboard
		local ok = pcall(function()
			billboard = Instance.new('BillboardGui')
			billboard.Name = 'chest'
			billboard.StudsOffsetWorldSpace = Vector3.new(0, 3, 0)
			billboard.Size = UDim2.fromOffset(36, 36)
			billboard.AlwaysOnTop = true
			billboard.ClipsDescendants = false
			billboard.Adornee = v
			local frame = Instance.new('Frame')
			frame.Size = UDim2.fromScale(1, 1)
			frame.BackgroundColor3 = Color3.fromHSV(color.hue, color.sat, color.value)
			frame.BackgroundTransparency = 1 - (background.enabled and color.opacity or 0)
			frame.BorderSizePixel = 0
			frame.Parent = billboard
			loaderStyle.stroke(frame).Enabled = background.enabled
			local layout = Instance.new('UIListLayout')
			layout.FillDirection = Enum.FillDirection.Horizontal
			layout.Padding = UDim.new(0, 4)
			layout.VerticalAlignment = Enum.VerticalAlignment.Center
			layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
			local resizeQueued = false
			layout:GetPropertyChangedSignal('AbsoluteContentSize'):Connect(function()
				if resizeQueued then return end
				resizeQueued = true
				task.defer(function()
					resizeQueued = false
					if slinky.threadFix then
						setthreadidentity(8)
					end
					if not billboard.Parent then return end
					pcall(function()
						billboard.Size = UDim2.fromOffset(math.max(layout.AbsoluteContentSize.X + 4, 36), 36)
					end)
				end)
			end)
			layout.Parent = frame
			loaderStyle.corner(frame, 6)
			billboard.Parent = folder
		end)
		if not ok then
			if billboard then
				pcall(function() billboard:Destroy() end)
			end
			return
		end
		reference[v] = billboard
		chestWatch[v] = {
			chest.ChildAdded:Connect(function(item)
				if table.find(list.active, item.Name) or nearStorageItem(item.Name) then
					queueRefresh(billboard)
				end
			end),
			chest.ChildRemoved:Connect(function(item)
				if table.find(list.active, item.Name) or nearStorageItem(item.Name) then
					queueRefresh(billboard)
				end
			end)
		}
		task.spawn(refreshAdornee, billboard)
	end
	
	storageESP = render:module('StorageESP', {
		label = 'Chest ESP',
		toggled = function(on)
			if slinky.threadFix then
				setthreadidentity(8)
			end
			if on then
				local scaledGui = slinky.gui:FindFirstChild('ScaledGui')
				local clickGui = scaledGui and scaledGui:FindFirstChild('ClickGui')
				if clickGui then
					folder.Parent = (not clickGui.Visible) and slinky.gui or nil
					local parentQueued = false
					storageESP:clean(clickGui:GetPropertyChangedSignal('Visible'):Connect(function()
						if parentQueued then return end
						parentQueued = true
						task.defer(function()
							parentQueued = false
							if slinky.threadFix then
								setthreadidentity(8)
							end
							if not storageESP.enabled then return end
							folder.Parent = (not clickGui.Visible) and slinky.gui or nil
						end)
					end))
				end
				storageESP:clean(collectionService:GetInstanceAddedSignal('chest'):Connect(function(v)
					task.defer(added, v)
				end))
				storageESP:clean(collectionService:GetInstanceRemovedSignal('chest'):Connect(function(v)
					local billboard = reference[v]
					if not billboard then return end
					task.defer(function()
						if slinky.threadFix then
							setthreadidentity(8)
						end
						if reference[v] ~= billboard then return end
						for _, connection in amountWatch[billboard] or {} do
							connection:Disconnect()
						end
						amountWatch[billboard] = nil
						for _, connection in chestWatch[v] or {} do
							connection:Disconnect()
						end
						chestWatch[v] = nil
						pcall(function() billboard:Destroy() end)
						reference[v] = nil
					end)
				end))
				for _, v in collectionService:GetTagged('chest') do
					task.spawn(added, v)
				end
				storageESP:clean(task.spawn(function()
					repeat
						task.wait(1)
						for _, v in collectionService:GetTagged('chest') do
							if not (reference[v] or pending[v]) then
								task.spawn(added, v)
							end
						end
					until not storageESP.enabled
				end))
			else
				for _, list in amountWatch do
					for _, connection in list do
						connection:Disconnect()
					end
				end
				table.clear(amountWatch)
				for _, list in chestWatch do
					for _, connection in list do
						connection:Disconnect()
					end
				end
				table.clear(chestWatch)
				table.clear(reference)
				table.clear(pending)
				folder:ClearAllChildren()
				folder.Parent = slinky.gui
			end
		end,
		about = 'Shows which chests hold the items on your list.\nAdds an icon for each item, and the amount if you want.'
	})
	storageESP:divider('Extras')
	list = storageESP:list('Item', {
		changed = function()
			for _, v in reference do
				task.spawn(refreshAdornee, v)
			end
		end
	})
	showAmount = storageESP:toggle('Show amount', {
		default = true,
		changed = function()
			for _, v in reference do
				task.spawn(refreshAdornee, v)
			end
		end,
		about = 'Shows how many of each item the chest holds.'
	})
	background = storageESP:toggle('Background', {
		changed = function(callback)
			if color.row then color.row.Visible = callback end
			if slinky.threadFix then
				setthreadidentity(8)
			end
			for _, v in reference do
				pcall(function()
					v.Frame.BackgroundTransparency = 1 - (callback and color.opacity or 0)
					v.Frame.UIStroke.Enabled = callback
				end)
			end
		end,
		default = true
	})
	color = storageESP:color('Background Color', {
		hue = loaderStyle.Hue,
		sat = loaderStyle.Sat,
		value = loaderStyle.Value,
		opacity = 1 - loaderStyle.Transparency,
		changed = function(hue, sat, val, opacity)
			if slinky.threadFix then
				setthreadidentity(8)
			end
			for _, v in reference do
				pcall(function()
					v.Frame.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
					v.Frame.BackgroundTransparency = 1 - (background.enabled and opacity or 0)
				end)
			end
		end,
		sub = true
	})
end)

--[[ AutoBalloon
Inflates balloons once you fall 50 studs below the bottom of the lowest block on the map. The map's
tens of thousands of blocks are scanned from a copy, 2,000 a frame: the live list swap-removes, so a
block broken mid-walk could move an unread one into a slot already passed. ]]
run(function()
	local autoBalloon
	
	autoBalloon = utility:module('AutoBalloon', {
		tab = 'Move',
		toggled = function(on)
			if on then
				repeat task.wait(0.1) until store.matchState ~= 0 or (not autoBalloon.enabled)
				if not autoBalloon.enabled then return end

				local lowestpoint = math.huge
				for index, v in table.clone(store.blocks) do
					local point = (v.Position.Y - (v.Size.Y / 2)) - 50
					if point < lowestpoint then 
						lowestpoint = point 
					end
					if index % 2000 == 0 then
						task.wait()
					end
				end
				if not autoBalloon.enabled then return end
	
				repeat
					if entitylib.isAlive then
						if entitylib.character.RootPart.Position.Y < lowestpoint and (lplr.Character:GetAttribute('InflatedBalloons') or 0) < 3 then
							local balloon = getItem('balloon')
							if balloon then
								for _ = 1, 3 do 
									bedwars.BalloonController:inflateBalloon() 
								end
							end
							task.wait(0.1)
						end
					end
					task.wait(0.1)
				until not autoBalloon.enabled
			end
		end,
		about = 'Inflates balloons to save you when you fall off the map.'
	})
end)
	
--[[ AutoCobalt
Picks up Cobalt batteries from further away by making them bigger to the game's own pickup; it sends
nothing itself. BatteryController.onKitLocalActivated takes, every frame while your Cobalt logic is
on, any opened battery with a part within 6 studs of your character's pivot, one per frame, retrying
after 0.5 s without an answer, and sends ConsumeBattery. It finds parts with GetPartBoundsInRadius
and maps them to batteries through BatteryEffectsController.batteryIds. A battery within Range gets
one more part registered there: an invisible cube whose half-width is Range less 6, so while the
battery is within Range the cube's edge is never more than 6 studs from you.

The server takes a battery from up to 14.4 studs (accepted in a match; 18.3 refused), its
RAYCAST_SWORD_CHARACTER_DISTANCE of 4.8 blocks, so Range is capped there, profiles included. The
cube exists only while it is needed, sits under the camera, and carries gamecore_GameQueryIgnore so
the game's GameQueryUtil raycasts skip it; GetPartBoundsInRadius still finds it. The pickup runs
while localLogicActivate is set, which covers a match, Kit Fusion and the PvP arena's Cobalt
augment. ]]
run(function()
	if exec.skip('AutoCobalt') then return end
	local autoCobalt
	local range
	local GAME_REACH = 6
	local SERVER_REACH = 14.4
	local boxes = {}
	local loopId = 0

	local function dropBox(id, effects)
		local box = boxes[id]
		if not box then return end
		boxes[id] = nil
		if effects and type(effects.batteryIds) == 'table' and effects.batteryIds[box] == id then
			effects.batteryIds[box] = nil
		end
		box:Destroy()
	end

	local function clearBoxes()
		local effects = bedwars.BatteryEffectsController
		for id in boxes do
			dropBox(id, effects)
		end
	end

	autoCobalt = utility:module('AutoCobalt', {
		tab = 'Kits',
		toggled = function(on)
			if on then
				autoCobalt:clean(clearBoxes)
				loopId += 1
				local thisLoop = loopId
				repeat
					local controller = bedwars.BatteryController
					local effects = bedwars.BatteryEffectsController
					local character = lplr.Character
					local reach = math.min(range.value, SERVER_REACH)
					if controller and controller.localLogicActivate == true and effects
						and type(effects.liveBatteries) == 'table' and type(effects.batteryIds) == 'table'
						and character and character.PrimaryPart and reach > GAME_REACH then
						local point = character:GetPivot().Position
						local now = workspace:GetServerTimeNow()
						local size = Vector3.one * ((reach - GAME_REACH) * 2)
						for id, info in effects.liveBatteries do
							local box = boxes[id]
							local position = info.position
							if typeof(position) == 'Vector3' and info.activateTime < now
								and (position - point).Magnitude <= reach then
								if box and (not box:IsDescendantOf(workspace) or (box.Size - size).Magnitude > 0.01) then
									dropBox(id, effects)
									box = nil
								end
								if not box then
									box = Instance.new('Part')
									box.Name = 'Hitbox'
									box.Anchored = true
									box.CanCollide = false
									box.CanTouch = false
									box.CanQuery = true
									box.CastShadow = false
									box.Transparency = 1
									box.Size = size
									box.CFrame = CFrame.new(position)
									box:SetAttribute('gamecore_GameQueryIgnore', true)
									box.Parent = gameCamera.Parent and gameCamera or workspace.CurrentCamera
									boxes[id] = box
									effects.batteryIds[box] = id
								end
							elseif box then
								dropBox(id, effects)
							end
						end
						for id in boxes do
							if effects.liveBatteries[id] == nil then
								dropBox(id, effects)
							end
						end
						runService.Heartbeat:Wait()
					else
						if next(boxes) then clearBoxes() end
						task.wait(0.5)
					end
				until not autoCobalt.enabled or loopId ~= thisLoop
			end
		end,
		about = 'Picks up Cobalt batteries from further away.'
	})
	range = autoCobalt:slider('Range', {
		min = 7,
		max = SERVER_REACH,
		default = 10,
		decimal = 10,
		changed = function(val)
			if val > SERVER_REACH then
				task.defer(function()
					if range.value > SERVER_REACH then range:set(SERVER_REACH) end
				end)
			end
		end,
		suffix = function(val)
			return val <= 1 and 'stud' or 'studs'
		end,
		about = 'How far away batteries get picked up.'
	})
end)
	
--[[ AutoPlay
Queues you up again once the match ends. Can join a random mode instead of the same one. ]]
run(function()
	local autoPlay
	local random
	
	local function isEveryoneDead()
		return #bedwars.Store:getState().Party.members <= 0
	end
	
	local function joinQueue()
		if not bedwars.Store:getState().Game.customMatch and bedwars.Store:getState().Party.leader.userId == lplr.UserId and bedwars.Store:getState().Party.queueState == 0 then
			if random.enabled then
				local listofmodes = {}
				for i, v in bedwars.QueueMeta do
					if not v.disabled and not v.voiceChatOnly and not v.rankCategory then 
						table.insert(listofmodes, i) 
					end
				end
				bedwars.QueueController:joinQueue(listofmodes[math.random(1, #listofmodes)])
			else
				bedwars.QueueController:joinQueue(store.queueType)
			end
		end
	end
	
	autoPlay = utility:module('AutoPlay', {
		toggled = function(on)
			if on then
				autoPlay:clean(slinkyEvents.EntityDeathEvent.Event:Connect(function(deathTable)
					if deathTable.finalKill and deathTable.entityInstance == lplr.Character and isEveryoneDead() and store.matchState ~= 2 then
						joinQueue()
					end
				end))
				autoPlay:clean(slinkyEvents.MatchEndEvent.Event:Connect(joinQueue))
			end
		end,
		about = 'Queues you up again once the match ends.\nCan join a random mode instead of the same one.'
	})
	random = autoPlay:toggle('Random', {
		about = 'Picks a random mode for you'
	})
end)
	
--[[ AutoToxic
Sends a message after you kill a player and when a game ends, as Roblox Quick Words or, on an
account that may chat, your own text. Quick Words come from GetPresetsAsync
(categoryGroups[].categories[].contents[], each {kind, text, presetId}); Roblox translates them into
each player's chat language, but the presetIds were the same in every server seen.

One message every 5 s at most: Quick Words have a cooldown of about 4.5 s (Roblox's own chat bar
waits 5) and chat has a flood check. A kill message inside the gap is dropped, the end-of-game one
waits it out, and a kill job more than a second old is dropped. GetPresetsAsync and SendPresetAsync
are RobloxScript calls, and an event handler runs at the identity of whatever connected it, so every
send runs in order on one worker thread made at load.

CanUserChatAsync, the question Roblox's own chat UI asks, decides whether own text is sent: it is
false without an age check and also under chat settings, parental controls or a moderation timeout,
and its answer is kept for a minute. A message the server turns down goes as Quick Words instead,
and a refusal for the account means Quick Words for the next minute. SendAsync and SendPresetAsync
can return a message that is still Sending; the verdict arrives through MessageReceived under the
same MessageId and is waited for up to 5 s. A moderation timeout keeps Quick Words out too: its
first sign stops every send for the rest of the match. Messages go to the general channel, not the
tab the chat bar has open. Legacy chat has no presets and gets plain text.

A profile can load before the presets arrive, so the saved Kill Message is kept until they do.
Presets are fetched at load and every 10 s for a minute while none are found. ]]
run(function()
	local autoToxic
	local mode
	local gg
	local ggMessage
	local kill
	local killMessage
	local killMessages
	local presets, presetNames, phraseOf = {}, {}, {}
	local GG_PHRASE, GG_ID = 'Good game', '2f641f8a-9bde-5242-a695-880059871184'
	local KILL_PHRASE, KILL_ID = 'Well played', '1cebf811-b597-5be3-9100-172a049ae298'
	local SUCCESS, SENDING = Enum.TextChatMessageStatus.Success, Enum.TextChatMessageStatus.Sending
	local REFUSED = {
		[Enum.TextChatMessageStatus.InvalidPrivacySettings] = true,
		[Enum.TextChatMessageStatus.ModerationTimeout] = true
	}
	local CHAT_OFF = 'This account cannot chat (no age check, or chat is off for it). AutoToxic sends Quick Words instead, as set in Quick Words mode.'
	local GAP = 5
	local lastSent = -math.huge
	local told = {}
	local savedKillMessage, savedKillProfile
	local chatAllowed, chatAsked = false, -math.huge

	local function normalise(str)
		return (tostring(str):lower():gsub('^%s*(.-)%s*$', '%1'))
	end

	local function tell(key, text)
		if told[key] then return end
		told[key] = true
		notif('AutoToxic', text, 10, 'warning')
	end

	local function refresh()
		if not (mode and gg and kill and ggMessage and killMessage and killMessages) then return end
		local chat = mode.value == 'Chat'
		ggMessage.row.Visible = chat and gg.enabled
		killMessage.row.Visible = not chat and kill.enabled
		killMessages.row.Visible = chat and kill.enabled
	end

	local function presetFor(value)
		if value ~= nil and table.find(presetNames, value) then return value end
		return phraseOf[KILL_ID] or table.find(presetNames, KILL_PHRASE) and KILL_PHRASE or presetNames[1]
	end

	local function fetchPresets()
		if presetNames[1] then return true end
		local ok, byText, phrases = pcall(function()
			local presets = textChatService:GetPresetsAsync()
			local found, order = {}, {}
			for _, group in presets.categoryGroups or {} do
				for _, category in group.categories or {} do
					for _, entry in category.contents or category.messages or {} do
						local text = entry.text or entry.value
						if type(text) == 'string' and type(entry.presetId) == 'string' and (entry.kind or 'Preset') == 'Preset' and not found[normalise(text)] then
							found[normalise(text)] = entry.presetId
							table.insert(order, text)
						end
					end
				end
			end
			return found, order
		end)
		if not ok then return false, tostring(byText) end
		if not phrases[1] then return false, 'Roblox gave no phrases' end
		table.sort(phrases)
		for key, presetId in byText do
			presets[key] = presetId
		end
		for _, text in phrases do
			phraseOf[byText[normalise(text)]] = text
		end
		table.move(phrases, 1, #phrases, 1, presetNames)
		local saved = savedKillProfile == slinky.profile and savedKillMessage or nil
		local value = presetFor(saved or killMessage.value)
		local fallback = presetFor(nil)
		if killMessage.value ~= fallback then
			killMessage:set(fallback)
		end
		slinky:rebase(killMessage)
		if killMessage.value ~= value then
			killMessage:set(value)
		end
		return true
	end

	local function generalChannel()
		local channels = textChatService:FindFirstChild('TextChannels')
		local general = channels and channels:FindFirstChild('RBXGeneral')
		if general then return general end
		local bar = textChatService:FindFirstChildOfClass('ChatInputBarConfiguration')
		return bar and bar.TargetTextChannel
	end

	local muted = false
	slinky:clean(textChatService.MessageReceived:Connect(function(message)
		if muted or message.TextSource then return end
		local text = string.lower(tostring(message.Text))
		if text:find('cannot currently send chats', 1, true) or text:find("can't send messages", 1, true) then
			muted = true
			if shared.PistonwareDeveloper then
				bufferCall('warn', 'bedwars.autotoxic', 'chat is blocked for this account; AutoToxic stays quiet for the rest of the match')
			end
		end
	end))

	local function attempt(channel, send)
		lastSent = os.clock()
		local verdicts = {}
		local watch = channel.MessageReceived:Connect(function(message)
			if message.Status ~= SENDING then
				verdicts[message.MessageId] = message.Status
			end
		end)
		local ok, status = pcall(function()
			local message = send()
			local deadline = os.clock() + 5
			local verdict = verdicts[message.MessageId] or message.Status
			while verdict == SENDING and os.clock() < deadline do
				task.wait(0.1)
				verdict = verdicts[message.MessageId] or message.Status
			end
			return verdict
		end)
		watch:Disconnect()
		if not ok then return nil, tostring(status) end
		if status == Enum.TextChatMessageStatus.ModerationTimeout then
			muted = true
		end
		return status ~= SENDING and status or nil
	end

	local function sendQuickWords(kill)
		local ready, why = fetchPresets()
		if not ready then
			tell('quick', 'Quick Words are not available: '..why)
			return
		end
		local presetId
		if kill then
			presetId = presets[normalise(killMessage.value)]
		else
			presetId = phraseOf[GG_ID] and GG_ID or presets[normalise(GG_PHRASE)]
		end
		local channel = generalChannel()
		if not (presetId and channel) then return end
		local status, err = attempt(channel, function()
			return channel:SendPresetAsync(presetId)
		end)
		if err or (status and status ~= SUCCESS) then
			local reason = err or status.Name
			bufferCall('warn', 'bedwars.autotoxic', 'Quick Words not sent: '..reason)
			tell('quick', 'A Quick Words message was not sent: '..reason)
		end
	end

	local function canChat()
		if os.clock() - chatAsked > 60 then
			local ok, allowed = pcall(function()
				return textChatService:CanUserChatAsync(lplr.UserId)
			end)
			if not ok then
				ok, allowed = pcall(function()
					return cloneref(game:GetService('Chat')):CanUserChatAsync(lplr.UserId)
				end)
			end
			chatAllowed, chatAsked = ok and allowed == true, os.clock()
		end
		return chatAllowed
	end

	local function sendText(text, kill)
		local channel = generalChannel()
		if not channel then return end
		if canChat() then
			local status, err = attempt(channel, function()
				return channel:SendAsync(text)
			end)
			if status == SUCCESS or not (status or err) then return end
			bufferCall('warn', 'bedwars.autotoxic', 'chat message not sent: '..(err or status.Name))
			if not REFUSED[status] then
				sendQuickWords(kill)
				return
			end
			chatAllowed, chatAsked = false, os.clock()
		end
		tell('chat', CHAT_OFF)
		sendQuickWords(kill)
	end

	local function deliver(killed)
		if muted then return end
		local left = lastSent + GAP - os.clock()
		if left > 0 then
			if killed then return end
			task.wait(left)
			if not autoToxic.enabled then return end
		end
		local text
		if mode.value == 'Chat' then
			if killed then
				local list = killMessages.active
				if not list[1] then return end
				text = list[math.random(#list)]:gsub('{name}', function()
					return killed.DisplayName
				end)
			else
				text = ggMessage.value
			end
			text = tostring(text):match('^%s*(.-)%s*$')
			if text == '' then return end
		end
		if textChatService.ChatVersion ~= Enum.ChatVersion.TextChatService then
			text = text or (killed and killMessage.value or GG_PHRASE)
			local events = replicatedStorage:FindFirstChild('DefaultChatSystemChatEvents')
			local say = events and events:FindFirstChild('SayMessageRequest')
			if say and text ~= 'None' then
				lastSent = os.clock()
				say:FireServer(text, 'All')
			end
		elseif text then
			sendText(text, killed ~= nil)
		else
			sendQuickWords(killed ~= nil)
		end
	end

	local jobs, parked = {}, false
	local worker = coroutine.create(function()
		if slinky.threadFix and not pcall(setthreadidentity, 8) then
			pcall(setthreadidentity, 7)
		end
		while true do
			local job = table.remove(jobs, 1)
			if job then
				local ok, err = pcall(job)
				if not ok then
					bufferCall('warn', 'bedwars.autotoxic', tostring(err))
				end
			else
				parked = true
				coroutine.yield()
				parked = false
			end
		end
	end)
	task.spawn(worker)

	local function queue(job)
		table.insert(jobs, job)
		if parked then
			task.spawn(worker)
		end
	end

	autoToxic = utility:module('AutoToxic', {
		toggled = function(on)
			if on then
				autoToxic:clean(slinkyEvents.MatchEndEvent.Event:Connect(function()
					if gg.enabled then
						queue(deliver)
					end
				end))
				autoToxic:clean(slinkyEvents.EntityDeathEvent.Event:Connect(function(deathTable)
					if not kill.enabled then return end

					local killer = playersService:GetPlayerFromCharacter(deathTable.fromEntity)
					local killed = playersService:GetPlayerFromCharacter(deathTable.entityInstance)
					if not killer or not killed then return end
					if killer ~= lplr or killed == lplr then return end

					local at = os.clock()
					queue(function()
						if os.clock() - at <= 1 and autoToxic.enabled and kill.enabled then
							deliver(killed)
						end
					end)
				end))
			end
		end,
		about = 'Sends chat messages after kills and when a game ends.\nQuick Words needs no age check; Chat needs an account that can chat.'
	})
	mode = autoToxic:dropdown('Mode', {
		choices = {'Quick Words', 'Chat'},
		changed = function(val, isClick)
			refresh()
			if val == 'Chat' and isClick then
				queue(function()
					if not canChat() then
						tell('chat', CHAT_OFF)
					end
				end)
			end
		end,
		about = 'Quick Words, with no age check needed, or your own text if this account can chat'
	})
	gg = autoToxic:toggle('AutoGG', {
		default = true,
		changed = refresh
	})
	ggMessage = autoToxic:textbox('GG Message', {
		default = 'gg',
		sub = true,
		visible = false,
		about = 'What to say when a game ends'
	})
	kill = autoToxic:toggle('Kill', {
		changed = refresh,
		about = 'Sends a message when you kill a player.\nIn Chat mode, {name} in a message becomes their name.'
	})
	killMessage = autoToxic:dropdown('Kill Message', {
		choices = presetNames,
		sub = true,
		visible = false,
		about = 'What to say after you kill someone'
	})
	killMessages = autoToxic:list('Kill Messages', {
		default = {'gg {name}', 'ez'},
		placeholder = 'e.g. gg {name}',
		sub = true,
		visible = false,
		about = 'One is picked at random after each kill'
	})

	local loadDropdown = killMessage.load
	function killMessage:load(value)
		savedKillMessage, savedKillProfile = value, slinky.profile
		loadDropdown(self, presetNames[1] and presetFor(value) or value)
	end
	local loadToxic = autoToxic.load
	function autoToxic:load(entry)
		savedKillMessage = nil
		return loadToxic(self, entry)
	end

	local function loadPresets(tries)
		if slinky.loaded == nil or fetchPresets() or tries <= 1 then return end
		task.delay(10, queue, function()
			loadPresets(tries - 1)
		end)
	end
	if textChatService.ChatVersion == Enum.ChatVersion.TextChatService then
		queue(function()
			loadPresets(6)
		end)
	end
end)
	
--[[ AutoVoidDrop
Drops your iron, diamonds, emeralds and gold once you fall 50 studs below the bottom of the lowest
block, when no balloon can save you, and can reset you after. The map is scanned a slice per frame
from a copy, as AutoBalloon does. Owl check holds the drop while an OwlLiftForce is on your root
part. ]]
run(function()
	local autoVoidDrop
	local owlCheck
	local autoReset
	
	autoVoidDrop = inventory:module('AutoVoidDrop', {
		toggled = function(on)
			if on then
				repeat task.wait(0.1) until store.matchState ~= 0 or (not autoVoidDrop.enabled)
				if not autoVoidDrop.enabled then return end

				local lowestpoint = math.huge
				for index, v in table.clone(store.blocks) do
					local point = (v.Position.Y - (v.Size.Y / 2)) - 50
					if point < lowestpoint then
						lowestpoint = point
					end
					if index % 2000 == 0 then
						task.wait()
					end
				end
				if not autoVoidDrop.enabled then return end
	
				repeat
					if entitylib.isAlive then
						local root = entitylib.character.RootPart
						if root.Position.Y < lowestpoint and (lplr.Character:GetAttribute('InflatedBalloons') or 0) <= 0 and not getItem('balloon') then
							if not owlCheck.enabled or not root:FindFirstChild('OwlLiftForce') then
								local dropped = false
	
								for _, item in {'iron', 'diamond', 'emerald', 'gold'} do
									item = getItem(item)
									if item then
										dropped = true
										item = bedwars.Client:Get(remotes.DropItem):CallServer({
											item = item.tool,
											amount = item.amount
										})
	
										if item then
											item:SetAttribute('ClientDropTime', tick() + 100)
										end
									end
								end
	
								if dropped and autoReset.enabled then
									bedwars.Client:Get(remotes.ResetCharacter):SendToServer()
								end
							end
						end
					end
	
					task.wait(0.1)
				until not autoVoidDrop.enabled
			end
		end,
		about = 'Drops your resources when you fall into the void.\nCan hold off during an owl rescue and reset you after.'
	})
	owlCheck = autoVoidDrop:toggle('Owl check', {
		default = true,
		about = 'Holds onto your items if an owl is coming for them'
	})
	autoReset = autoVoidDrop:toggle('Auto Reset', {
		default = true,
		about = 'Resets you the moment your resources are dropped'
	})
end)
	
--[[ MissileTP
Sends a missile at the player nearest your mouse. ]]
run(function()
	local missileTP
	
	missileTP = utility:module('MissileTP', {
		tab = 'Combat',
		toggled = function(on)
			if on then
				missileTP:flip(nil, true)
				local plr = entitylib.EntityMouse({
					Range = 1000,
					Players = true,
					Part = 'RootPart'
				})
	
				if getItem('guided_missile') and plr then
					local projectile = bedwars.RuntimeLib.await(bedwars.GuidedProjectileController.fireGuidedProjectile:CallServerAsync('guided_missile'))
					if projectile then
						local projectilemodel = projectile.model
						if not projectilemodel.PrimaryPart then
							projectilemodel:GetPropertyChangedSignal('PrimaryPart'):Wait()
						end
	
						local bodyforce = Instance.new('BodyForce')
						bodyforce.Force = Vector3.new(0, projectilemodel.PrimaryPart.AssemblyMass * workspace.Gravity, 0)
						bodyforce.Name = 'AntiGravity'
						bodyforce.Parent = projectilemodel.PrimaryPart
	
						repeat
							projectile.model:SetPrimaryPartCFrame(CFrame.lookAlong(plr.RootPart.CFrame.p, gameCamera.CFrame.LookVector))
							task.wait(0.1)
						until not projectile.model or not projectile.model.Parent
					else
						notif('MissileTP', 'Missile on cooldown.', 3)
					end
				end
			end
		end,
		about = 'Sends a missile at the player nearest your mouse.'
	})
end)

--[[ PickupRange
Picks up dropped items from further away, and can pull drops whose physics you own down to your
feet. The server's rate limiter allows 299 pickup calls a minute, so each drop is asked for at most
once per Delay; a new drop goes out on the pass that spots it. AntiBanwave drops calls over that
budget.

A drop whose ClientDropTime is under 2 s old is skipped, and so is a stack the bank is holding for
you: it carries PistonwareBankOwner, set on this client only. ]]
run(function()
	local pickupRange
	local range
	local network
	local lower
	local delaySlider
	local pickups = setmetatable({}, {__mode = 'k'})

	pickupRange = utility:module('PickupRange', {
		info = function()
			return range and tostring(range.value) or nil
		end,
		toggled = function(on)
			if on then
				local items = collection('ItemDrop', pickupRange)
				repeat
					if entitylib.isAlive then
						local localPosition = entitylib.character.RootPart.Position
						local now = tick()
						local pullDrops = network.enabled and entitylib.character.Humanoid.Health > 0
						for _, v in items do
							if v:GetAttribute('PistonwareBankOwner') ~= nil then continue end
							if now - (v:GetAttribute('ClientDropTime') or 0) < 2 then continue end
							if pullDrops and isnetworkowner(v) then
								v.CFrame = CFrame.new(localPosition - Vector3.new(0, 3, 0)) 
							end

							local dropPosition = v.Position
							if (localPosition - dropPosition).Magnitude <= range.value then
								if lower.enabled and (localPosition.Y - dropPosition.Y) < (entitylib.character.HipHeight - 1) then continue end

								if (pickups[v] or 0) >= now then continue end
								pickups[v] = now + delaySlider.value

								task.spawn(function()
									bedwars.Client:Get(remotes.PickupItem):CallServerAsync({
										itemDrop = v
									}):andThen(function(suc)
										if suc and bedwars.SoundList then
											bedwars.SoundManager:playSound(bedwars.SoundList.PICKUP_ITEM_DROP)
											local sound = bedwars.ItemMeta[v.Name].pickUpOverlaySound
											if sound then
												bedwars.SoundManager:playSound(sound, {
													position = v.Position,
													volumeMultiplier = 0.9
												})
											end
										end
									end)
								end)
							end
						end
					end
					task.wait(0.1)
				until not pickupRange.enabled
			else
				table.clear(pickups)
			end
		end,
		about = 'Picks up dropped items from further away.\nCan pull drops to you and skip ones below your feet.'
	})
	range = pickupRange:slider('Range', {
		min = 1,
		max = 10,
		default = 10,
		suffix = function(val) 
			return val == 1 and 'stud' or 'studs' 
		end
	})
	delaySlider = pickupRange:slider('Delay', {
		min = 0.2,
		max = 5,
		default = 1,
		decimal = 10,
		suffix = function(val) return 's' end,
		about = 'How long before it retries the same drop. New drops are\nalways grabbed the moment they show up, so this only\naffects retries. Go too low and a floor full of items\nwill blow past the 299/min the server allows.'
	})
	network = pickupRange:toggle('Network TP', {
		default = true
	})
	lower = pickupRange:toggle('Feet Check')
end)

--[[ RavenTP
Sends a raven at the player nearest your mouse. ]]
run(function()
	local ravenTP
	
	ravenTP = utility:module('RavenTP', {
		tab = 'Combat',
		toggled = function(on)
			if on then
				ravenTP:flip(nil, true)
				local plr = entitylib.EntityMouse({
					Range = 1000,
					Players = true,
					Part = 'RootPart'
				})
	
				if getItem('raven') and plr then
					bedwars.Client:Get(remotes.SpawnRaven):CallServerAsync():andThen(function(projectile)
						if projectile then
							local bodyforce = Instance.new('BodyForce')
							bodyforce.Force = Vector3.new(0, projectile.PrimaryPart.AssemblyMass * workspace.Gravity, 0)
							bodyforce.Parent = projectile.PrimaryPart
	
							if plr then
								task.spawn(function()
									for _ = 1, 20 do
										if plr.RootPart and projectile then
											projectile:SetPrimaryPartCFrame(CFrame.lookAlong(plr.RootPart.Position, gameCamera.CFrame.LookVector))
										end
										task.wait(0.05)
									end
								end)
								task.wait(0.3)
								bedwars.RavenController:detonateRaven()
							end
						end
					end)
				end
			end
		end,
		about = 'Sends a raven at the player nearest your mouse.'
	})
end)
	
run(function()
	local staffDetector
	local mode
	local clans
	local party
	local profile
	local users
	local blacklistedclans = {'gg', 'gg2', 'DV', 'DV2'}
	local blacklisteduserids = {3826146717, 4531785383, 1049767300, 4926350670, 653085195, 184655415, 2752307430, 5087196317, 5744061325, 1536265275}
	local joined = {}

	if slinky.threadFix then
		setthreadidentity(8)
	end
	
	local function getRole(plr, id)
		local suc, res = pcall(function()
			return plr:GetRankInGroup(id)
		end)
		if not suc then
			notif('StaffDetector', res, 30, 'alert')
		end
		return suc and res or 0
	end
	
	local function staffFunction(plr, checktype)
		if not slinky.loaded then
			repeat task.wait(0.1) until slinky.loaded
		end
	
		notif('StaffDetector', 'Staff Detected ('..checktype..'): '..plr.Name..' ('..plr.UserId..')', 60, 'alert')
		tags.customtags[plr.Name] = {{text = 'GAME STAFF', color = Color3.new(1, 0, 0)}}
	
		if party.enabled and not checktype:find('clan') then
			bedwars.PartyController:leaveParty()
		end
	
		if mode.value == 'Uninject' then
			task.spawn(function()
				slinky:unload()
			end)
			game:GetService('StarterGui'):SetCore('SendNotification', {
				Title = 'StaffDetector',
				Text = 'Staff Detected ('..checktype..')\n'..plr.Name..' ('..plr.UserId..')',
				Duration = 60,
			})
		elseif mode.value == 'Requeue' then
			bedwars.QueueController:joinQueue(store.queueType)
		elseif mode.value == 'Profile' then
			slinky.save = function() end
			if slinky.profile ~= profile.value then
				slinky:load(true, profile.value)
			end
		elseif mode.value == 'AutoConfig' then
			local safe = {'AutoClicker', 'Reach', 'Sprint', 'HitFix', 'StaffDetector'}
			slinky.save = function() end
			for i, v in (slinky.eachModule and slinky:eachModule() or slinky.modules) do
				if not (table.find(safe, i) or v.category == 'Render') then
					if v.enabled then
						v:flip()
					end
					if v.bind then v.bind:set({}) end
				end
			end
		end
	end
	
	local function checkFriends(list)
		for _, v in list do
			if joined[v] then
				return joined[v]
			end
		end
		return nil
	end
	
	--[[ MatchState.RUNNING (match-state module: PRE 0, RUNNING 1, POST 2). ]]
	local MATCH_RUNNING = 1
	--[[ A whole queue teleports into the server at once, but slow clients keep trickling in for a
	while after the match has already flipped to RUNNING, and until the server finishes with
	them they look exactly like a mid-match join: Spectator with no Team. Anyone who turns up
	inside this window counts as part of the original queue. ]]
	local JOIN_GRACE = 45
	--[[ Time to let a Team assignment land before calling someone team-less. ]]
	local SETTLE = 10
	--[[ A queue loader can still be waiting on its Team after SETTLE. Observers (friend
	spectates, mod teleports) never get one, so only non-observers wait, and the wait ends the
	moment a Team lands. ]]
	local TEAM_LATE = 20
	--[[ A spectator can land before the friend they followed. Anyone who turns up this long
	after SETTLE still gets checked as that friend before anything is flagged. ]]
	local LATE_FRIEND = 10
	--[[ The friend list is 50 rows a page and up to 1000 friends, each page its own web
	request. The cap only stops a list that never says IsFinished. ]]
	local MAX_PAGES = 25
	local LOOKUP_TRIES = 3
	--[[ How long a decision waits on a friend lookup that is still running. ]]
	local LOOKUP_WAIT = 30
	--[[ A lookup that failed every try gets one more full attempt this much later, so a
	throttled lookup cannot quietly let a mod through. ]]
	local RETRY_AFTER = 30
	--[[ Per-pair friendship checks: requests in flight at once, and the time they all get. ]]
	local ASK_PARALLEL = 6
	local ASK_TIMEOUT = 8
	local matchRunningSince
	--[[ Weak keys: entries for players who left go away on their own instead of pinning the Player
	instance for the rest of the session. ]]
	local arrivedAfter = setmetatable({}, {__mode = 'k'})
	local resolved = setmetatable({}, {__mode = 'k'})

	--[[ Seconds the match has been RUNNING, or nil if it is not. Injecting mid-match starts this
	clock at injection rather than at the true match start, which only ever makes the check
	below more conservative. Read straight off the store rather than store.matchState: the
	mirror is only filled in by the Store.changed handler, so it still reads PRE for the first
	dispatch or two after injecting into an already-running match. ]]
	local function matchRunningFor()
		if bedwars.Store:getState().Game.matchState ~= MATCH_RUNNING then
			matchRunningSince = nil
			return nil
		end
		matchRunningSince = matchRunningSince or os.clock()
		return os.clock() - matchRunningSince
	end

	local function isSpectating(plr)
		return plr:GetAttribute('Spectator') == true and not plr:GetAttribute('Team')
	end

	--[[ Also false once StaffDetector is off, so a check that was mid-wait never flags after it. ]]
	local function stillSpectating(plr)
		return staffDetector.enabled and plr.Parent ~= nil and isSpectating(plr)
	end

	--[[ Reads plr's whole friend list into st.ids while checkJoin waits on other things. Hidden
	friends come back as Id -1 and can never match, so they are dropped. Any page request can
	throw, so a failure starts the list again after a short backoff. Rows from a failed try are
	kept: a match among them is still a real friend. st.ok is set only by a full read. ]]
	local function lookupFriends(plr, st)
		for try = 1, LOOKUP_TRIES do
			local suc = pcall(function()
				local pages = playersService:GetFriendsAsync(plr.UserId)
				for _ = 1, MAX_PAGES do
					for _, v in pages:GetCurrentPage() do
						if v.Id ~= -1 then
							table.insert(st.ids, v.Id)
						end
					end
					if pages.IsFinished or st.stop then break end
					pages:AdvanceToNextPageAsync()
				end
			end)
			if suc or st.stop then
				st.ok = suc
				break
			end
			if try < LOOKUP_TRIES then
				task.wait(try * 2)
			end
		end
		st.done = true
	end

	--[[ IsFriendsWithAsync is the current name. Older clients only have the deprecated
	IsFriendsWith, and reading a member a client lacks throws. ]]
	local function isFriendsWith(plr, id)
		local suc, fn = pcall(function()
			return plr.IsFriendsWithAsync
		end)
		return (suc and fn or plr.IsFriendsWith)(plr, id)
	end

	--[[ Asks Roblox about each pair directly, a few at a time. This finds friends the list hides
	or has not reached yet. ids maps UserId to name; returns the first friend's name. ]]
	local function askFriends(plr, ids)
		local found, busy, deadline = nil, 0, os.clock() + ASK_TIMEOUT
		for id, name in ids do
			while busy >= ASK_PARALLEL and not found and os.clock() < deadline do
				task.wait(0.1)
			end
			if found or os.clock() >= deadline or not plr.Parent then break end
			busy += 1
			task.spawn(function()
				local suc, res = pcall(isFriendsWith, plr, id)
				busy -= 1
				if suc and res == true then
					found = found or name
				end
			end)
		end
		while busy > 0 and not found and os.clock() < deadline do
			task.wait(0.1)
		end
		return found
	end

	--[[ Everyone StaffDetector has seen in this server except plr, minus the ids in skip. ]]
	local function othersIn(plr, skip)
		local ids = {}
		for id, name in joined do
			if id ~= plr.UserId and not (skip and skip[id]) then
				ids[id] = name
			end
		end
		return ids
	end

	--[[ again = the one retry after a failed lookup: the player has already settled and had the
	late-friend window, so only the lookup and the friend checks run. ]]
	local function checkJoin(plr, again)
		if resolved[plr] or not plr.Parent or not isSpectating(plr) then return end
		if bedwars.Store:getState().Game.customMatch then return end

		--[[ Gate on when the player ARRIVED, not on when this check happens to fire. A late
		loader's Spectator attribute can settle minutes into the match, long past the grace
		window, so accepting any late check, as the old version did, is what flagged them. nil
		means they were already here when StaffDetector turned on,
		and we never saw them arrive, so there is nothing to judge. ]]
		local arrival = arrivedAfter[plr]
		if not arrival or arrival < JOIN_GRACE then return end

		resolved[plr] = true
		--[[ Start the friend lookup now so its page requests overlap the waits below instead of
		adding to them. ]]
		local st = {ids = {}}
		task.spawn(lookupFriends, plr, st)
		local windowEnd = 0
		if not again then
			--[[ Let them finish loading before deciding they have no team. 'PlayerConnected' is the
			game's own has-this-client-finished-connecting flag (GamePlayer.hasFinishedConnecting). ]]
			local deadline = os.clock() + 30
			while plr.Parent and plr:GetAttribute('PlayerConnected') ~= true and os.clock() < deadline do
				task.wait(0.5)
			end
			task.wait(SETTLE)
			--[[ Re-verify. A late loader has a Team by now, at which point there was never anything
			to report; clearing resolved lets a genuine later transition still be caught. ]]
			if not stillSpectating(plr) then
				st.stop, resolved[plr] = true, nil
				return
			end
			windowEnd = os.clock() + LATE_FRIEND
			if plr:GetAttribute('IsObserver') ~= true then
				local teamDeadline = os.clock() + TEAM_LATE
				while stillSpectating(plr) and os.clock() < teamDeadline do
					task.wait(0.25)
				end
				if not stillSpectating(plr) then
					st.stop, resolved[plr] = true, nil
					return
				end
			end
		end

		local lookupDeadline = os.clock() + LOOKUP_WAIT
		local asked = othersIn(plr)
		local friend = checkFriends(st.ids) or askFriends(plr, asked)
		if not friend then
			--[[ Time already spent waiting on a Team counts toward the late-friend window. ]]
			while stillSpectating(plr) and (os.clock() < windowEnd or not st.done) and os.clock() < lookupDeadline do
				task.wait(0.25)
			end
			if not stillSpectating(plr) then
				st.stop, resolved[plr] = true, nil
				return
			end
			friend = checkFriends(st.ids) or askFriends(plr, othersIn(plr, asked))
		end
		st.stop = true

		if friend then
			notif('StaffDetector', string.format('Spectator %s joined from %s', plr.Name, friend), 20, 'warning')
		elseif not stillSpectating(plr) then
			--[[ The friend checks above can take seconds. Re-verify, or a Team that landed, a leave
			or StaffDetector turning off in that time would still end in a flag. ]]
			resolved[plr] = nil
		elseif not st.ok then
			--[[ A failed lookup is not evidence of anything -- treating it as 'has no friends here'
			would flag on nothing. ]]
			resolved[plr] = nil
			if not again then
				staffDetector:clean(task.delay(RETRY_AFTER, checkJoin, plr, true))
			end
		else
			staffFunction(plr, 'impossible_join')
		end
	end

	local function playerAdded(plr, existing)
		--[[ A UserId already seen in this server is someone reconnecting to their own match, not
		a new arrival, so they get no arrival stamp. ]]
		local seenBefore = joined[plr.UserId] ~= nil
		joined[plr.UserId] = plr.Name
		if plr == lplr then return end
		if not existing and not seenBefore then
			arrivedAfter[plr] = matchRunningFor()
		end

		if table.find(blacklisteduserids, plr.UserId) or table.find(users.active, tostring(plr.UserId)) then
			staffFunction(plr, 'blacklisted_user')
		elseif getRole(plr, 5774246) >= 100 then
			staffFunction(plr, 'staff_role')
		else
			--[[ Spawned rather than called inline: checkJoin now yields while the player settles,
			and blocking the signal handler would stall every later attribute change on them. ]]
			staffDetector:clean(plr:GetAttributeChangedSignal('Spectator'):Connect(function()
				task.spawn(checkJoin, plr)
			end))
			--[[ Covers a mid-match join whose Spectator attribute replicated with the player, so
			no change signal ever fires for it. ]]
			task.spawn(checkJoin, plr)

			if not plr:GetAttribute('ClanTag') then
				plr:GetAttributeChangedSignal('ClanTag'):Wait()
			end

			if table.find(blacklistedclans, plr:GetAttribute('ClanTag')) and slinky.loaded and clans.enabled then
				resolved[plr] = true
				staffFunction(plr, 'blacklisted_clan_'..plr:GetAttribute('ClanTag'):lower())
			end
		end
	end
	
	staffDetector = utility:module('StaffDetector', {
		toggled = function(on)
			if on then
				--[[ Keep the match clock running from the moment the match flips to RUNNING. Left to
				playerAdded, it started at the first arrival after that, so that player and anyone
				within JOIN_GRACE of them were never judged. ]]
				staffDetector:clean(task.spawn(function()
					repeat
						matchRunningFor()
					until not task.wait(1)
				end))
				staffDetector:clean(playersService.PlayerAdded:Connect(playerAdded))
				for _, v in playersService:GetPlayers() do
					--[[ existing = true: these were already here, so no arrival stamp and no
					impossible-join check. The blacklist and staff-role checks still run. ]]
					task.spawn(playerAdded, v, true)
				end
			else
				--[[ joined is kept: it is per server and only ever lets someone off, and clearing it
				would forget a friend who has left since, so their spectator would be flagged. ]]
				table.clear(arrivedAfter)
				table.clear(resolved)
				matchRunningSince = nil
			end
		end,
		about = 'Warns you when staff are in your server.\nCan also unload, requeue, swap profile or turn modules off.'
	})
	mode = staffDetector:dropdown('Mode', {
		choices = {'Uninject', 'Profile', 'Requeue', 'AutoConfig', 'Notify'},
		changed = function(val)
			if profile.row then
				profile.row.Visible = val == 'Profile'
			end
		end
	})
	clans = staffDetector:toggle('Blacklist clans', {
		default = true
	})
	party = staffDetector:toggle('Leave party')
	profile = staffDetector:textbox('Profile', {
		default = 'default',
		sub = true,
		visible = false
	})
	users = staffDetector:list('Users', {
		placeholder = 'player (userid)'
	})
	
	task.spawn(function()
		repeat task.wait(1) until slinky.loaded or slinky.loaded == nil
		if slinky.loaded and not staffDetector.enabled then
			staffDetector:flip()
		end
	end)
end)
	
--[[ TrapDisabler
Stops enemy traps from going off on you. Each trap's controller (snap-trap, invisible-landmine,
teleport-block and void-teleport-portal) reports you stepping on it through one remote, and
trapToggles is keyed by those remote names. Hidden on executors that cannot load BedWars' Knit. ]]
run(function()
	if exec.skip('TrapDisabler') then return end
	if exec.Knitless then
		exec.hide('TrapDisabler', "needs BedWars' Knit, which this executor cannot load")
		return
	end
	trapDisabler = utility:module('TrapDisabler', {
		about = 'Stops enemy traps from going off on you.\nCovers snap traps, landmines, teleport blocks and void portals.'
	})
	trapToggles.StepOnSnapTrap = trapDisabler:toggle('Snap traps', {
		default = true,
		about = 'Trapper snap traps.'
	})
	trapToggles.TriggerInvisibleLandmine = trapDisabler:toggle('Landmines', {
		default = true,
		about = 'Invisible landmines.'
	})
	trapToggles.StepOnTeleportBlock = trapDisabler:toggle('Teleport blocks', {
		about = 'Teleport blocks. This also stops the ones your own team places from moving you.'
	})
	trapToggles.StepOnVoidPortal = trapDisabler:toggle('Void portals', {
		about = 'Void portals. This also stops your own from moving you.'
	})
end)
	
--[[ Anti-AFK
Keeps you from being kicked for idling. With getconnections it disconnects Idled and the Heartbeat
connection that sends AfkStatus, then reports afk = false.

Without getconnections (Solara, Xeno) nothing can be disconnected. AfkController's Heartbeat
connection only sends afk = false once the camera moves and then disconnects itself, so it can stay;
each Idled gets a VirtualUser click, which counts as input, and afk = false again. VirtualUser is
not an executor function, so the click is skipped where it fails. ]]
run(function()
	local antiAFK

	local function sendActive()
		pcall(function()
			bedwars.Client:Get(remotes.AfkStatus):SendToServer({
				afk = false
			})
		end)
	end

	antiAFK = world:module('Anti-AFK', {
		tab = 'Utility',
		toggled = function(on)
			if on and not exec.Connections then
				antiAFK:clean(lplr.Idled:Connect(function()
					pcall(function()
						local virtualUser = game:GetService('VirtualUser')
						virtualUser:CaptureController()
						virtualUser:ClickButton2(Vector2.zero)
					end)
					sendActive()
				end))
				sendActive()
				return
			end
			if on then
				for _, v in getconnections(lplr.Idled) do
					v:Disconnect()
				end

				for _, v in getconnections(runService.Heartbeat) do
					if type(v.Function) == 'function' and islclosure(v.Function) then
						local ok, constants = pcall(debug.getconstants, v.Function)
						if ok and table.find(constants, remotes.AfkStatus) then
							v:Disconnect()
						end
					end
				end

				bedwars.Client:Get(remotes.AfkStatus):SendToServer({
					afk = false
				})
			end
		end,
		about = 'Prevents you from getting kicked for being idle.'
	})
end)
	
--[[ AutoSuffocate
Boxes in nearby players who already have at least two of their four sides walled, one block per
player per pass: an open side first, then the head and the cell under them. Uses the block in your
hand, or your wool with Limit to Items off. On knitless executors store.hand follows every swap, so
the block the game has selected is read from store.selectedHand: with Killaura's sword swapped in
over your wool, store.hand would place nothing. ]]
run(function()
	local autoSuffocate
	local range
	local limitItem
	local targetResults = {}
	
	local function fixPosition(pos)
		return bedwars.BlockController:getBlockPosition(pos) * 3
	end
	
	autoSuffocate = world:module('AutoSuffocate', {
		toggled = function(on)
			if on then
				repeat
					local hand = (store.selectedHand and store.selectedHand()) or store.hand
					local item = hand.toolType == 'block' and hand.tool.Name or not limitItem.enabled and getWool()
	
					if item then
						local plrs = entitylib.AllPosition({
							Part = 'RootPart',
							Range = range.value,
							Players = true,
							Cache = true,
							Output = targetResults
						})
	
						for _, ent in plrs do
							local needPlaced = {}
	
							for _, side in Enum.NormalId:GetEnumItems() do
								side = Vector3.fromNormalId(side)
								if side.Y ~= 0 then continue end
	
								side = fixPosition(ent.RootPart.Position + side * 2)
								if not getPlacedBlock(side) then
									table.insert(needPlaced, side)
								end
							end
	
							if #needPlaced < 3 then
								table.insert(needPlaced, fixPosition(ent.Head.Position))
								table.insert(needPlaced, fixPosition(ent.RootPart.Position - Vector3.new(0, 1, 0)))
	
								for _, pos in needPlaced do
									if not getPlacedBlock(pos) then
										task.spawn(bedwars.placeBlock, pos, item)
										break
									end
								end
							end
						end
					end
	
					task.wait(0.09)
				until not autoSuffocate.enabled
			end
		end,
		about = 'Boxes in nearby players who are already half walled in.\nUses the block you hold, or your wool if allowed.'
	})
	range = autoSuffocate:slider('Range', {
		min = 1,
		max = 20,
		default = 20,
		suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
	limitItem = autoSuffocate:toggle('Limit to Items', {
		default = true
	})
end)
	
--[[ AutoTool
Switches to the best tool for the block you hit, through a wrapper on BlockBreaker.hitBlock, and can
switch back once you stop mining. Not everything you can hit has block meta. Switch back leaves a
slot you changed yourself alone, and waits while a drink holds the hand (store.handHeld), since
hotbarSwitch would refuse the swap. ]]
run(function()
	if exec.skip('AutoTool') then return end
	local autoTool
	local switchBack
	local old, event
	local previous, switchedTo, lastHit, returning = nil, nil, 0, false
	
	local function switchHotbarItem(block)
		if not block or block:GetAttribute('NoBreak') or block:GetAttribute('Team'..(lplr:GetAttribute('Team') or 0)..'NoBreak') then return end
		local meta = bedwars.ItemMeta[block.Name]
		local tool = meta and meta.block and store.tools[meta.block.breakType]
		if not tool then return end
		local slot
		for i, v in store.inventory.hotbar do
			if v.item and v.item.itemType == tool.itemType then slot = i - 1 break end
		end
		local from = store.inventory.hotbarSlot
		if hotbarSwitch(slot) then
			previous = previous or from
			switchedTo = slot
			if inputService:IsMouseButtonPressed(0) then 
				event:Fire() 
			end
			return true
		end
	end
	
	autoTool = world:module('AutoTool', {
		toggled = function(on)
			if on then
				previous, switchedTo, lastHit, returning = nil, nil, 0, false
				event = Instance.new('BindableEvent')
				autoTool:clean(event)
				autoTool:clean(event.Event:Connect(function()
					contextActionService:CallFunction('block-break', Enum.UserInputState.Begin, newproxy(true))
				end))
				old = bedwars.BlockBreaker.hitBlock
				bedwars.BlockBreaker.hitBlock = function(self, maid, raycastparams, ...)
					lastHit = os.clock()
					local block = self.clientManager:getBlockSelector():getMouseInfo(1, {ray = raycastparams})
					if switchHotbarItem(block and block.target and block.target.blockInstance or nil) then return end
					return old(self, maid, raycastparams, ...)
				end
				autoTool:clean(runService.Heartbeat:Connect(function()
					if not (switchBack.enabled and previous) or returning or os.clock() - lastHit < 0.35 or store.handHeld() then return end
					local slot = previous
					previous = nil
					if store.inventory.hotbarSlot ~= switchedTo then return end
					returning = true
					task.spawn(function()
						hotbarSwitch(slot)
						returning = false
					end)
				end))
			else
				bedwars.BlockBreaker.hitBlock = old
				old = nil
				previous, switchedTo = nil, nil
			end
		end,
		about = 'Selects the best tool when digging.\nCan switch back to what you held once you stop mining.'
	})
	switchBack = autoTool:toggle('Switch back', {
		label = 'Switch back when done',
		about = 'Puts back what you were holding once you stop mining.'
	})
end)
	
--[[ BedProtector
Walls your own bed in with the strongest blocks you have, Layers deep, then switches itself off and
says how many cells were left open. TNT, siege TNT and cannons are never used.

Every placement goes through the game's BlockCpsController, which silently cancels a block placed
less than half an interval after the last one. Blocks are paced one per 1 /
CpsConstants.BLOCK_PLACE_CPS (12 a second), read at load before FastPlace can change it, and timed
off the controller's lastPlaceTimestamp. Sends do not wait for the server, but a pass is judged only
after its answers (up to 1.5 s): the game shows a predicted block at once and takes it back if the
server refuses. Up to four passes.

A bed is two cells long, and the beds block handler's getContainedPositions gives both. Layer n is
every cell n steps up or sideways from the nearest bed cell, built bottom-up. Each layer uses its
own block type while it lasts, then whatever is left. Nobody can stand in the defense, you included.
]]
run(function()
	local bedProtector
	local layers
	local building = false

	local SKIP_BLOCKS = {tnt = true, siege_tnt = true, cannon = true}

	local PLACE_INTERVAL = 1 / 12
	pcall(function()
		local cps = tonumber(require(replicatedStorage.TS['shared-constants']).CpsConstants.BLOCK_PLACE_CPS)
		if cps and cps > 0 then
			PLACE_INTERVAL = 1 / cps
		end
	end)

	local function awaitPlaceSlot()
		while true do
			local controller = bedwars.BlockCpsController
			local last = controller and tonumber(controller.lastPlaceTimestamp) or 0
			local remaining = last + PLACE_INTERVAL + 0.01 - workspace:GetServerTimeNow()
			if remaining <= 0 then return end
			task.wait(remaining)
		end
	end

	local function getBedNear()
		local localPosition = entitylib.isAlive and entitylib.character.RootPart.Position or Vector3.zero
		for _, v in collectionService:GetTagged('bed') do
			if (localPosition - v.Position).Magnitude < 20 and v:GetAttribute('Team'..(lplr:GetAttribute('Team') or -1)..'NoBreak') then
				return v
			end
		end
	end

	local function getBlocks()
		local blocks = {}
		for _, item in store.inventory.inventory.items do
			local meta = bedwars.ItemMeta[item.itemType]
			local block = meta and meta.block
			if block and not SKIP_BLOCKS[item.itemType] then
				table.insert(blocks, {item.itemType, block.health or 0})
			end
		end
		table.sort(blocks, function(a, b)
			return a[2] > b[2]
		end)
		return blocks
	end

	local function getBedCells(bed)
		local cells
		pcall(function()
			local handler = bedwars.BlockController:getHandlerRegistry():getHandler(bed.Name)
			cells = handler and handler:getContainedPositions(bed)
		end)
		if not cells or #cells == 0 then
			cells = {bedwars.BlockController:getBlockPosition(bed.Position)}
		end
		return cells
	end

	local function getLayer(cells, layer)
		local isBed, seen, positions = {}, {}, {}
		for _, cell in cells do
			isBed[tostring(cell)] = true
		end

		for _, origin in cells do
			for dy = 0, layer do
				local flat = layer - dy
				for dx = -flat, flat do
					local dz = flat - math.abs(dx)
					for _, sz in (dz == 0 and {0} or {dz, -dz}) do
						local cell = origin + Vector3.new(dx, dy, sz)
						local key = tostring(cell)
						if not seen[key] and not isBed[key] then
							seen[key] = true
							local nearest = math.huge
							for _, other in cells do
								local d = cell - other
								if d.Y >= 0 then
									nearest = math.min(nearest, math.abs(d.X) + d.Y + math.abs(d.Z))
								end
							end
							if nearest == layer then
								table.insert(positions, cell)
							end
						end
					end
				end
			end
		end

		table.sort(positions, function(a, b)
			if a.Y ~= b.Y then return a.Y < b.Y end
			if a.X ~= b.X then return a.X < b.X end
			return a.Z < b.Z
		end)
		return positions
	end

	local function pickBlock(blocks, layer)
		for i = math.min(layer, #blocks), #blocks do
			if getItem(blocks[i][1]) then return blocks[i][1] end
		end
		for i = math.min(layer, #blocks) - 1, 1, -1 do
			if getItem(blocks[i][1]) then return blocks[i][1] end
		end
	end

	bedProtector = world:module('BedProtector', {
		toggled = function(on)
			if not on or building then return end
			local bed = getBedNear()
			if not bed then
				notif('BedProtector', 'Unable to locate bed', 5)
				bedProtector:flip()
				return
			end

			local blocks = getBlocks()
			if #blocks == 0 then
				notif('BedProtector', 'No blocks to build with', 5)
				bedProtector:flip()
				return
			end

			local cells = getBedCells(bed)
			local plan = {}
			for layer = 1, layers.value do
				plan[layer] = getLayer(cells, layer)
			end

			building = true
			local inFlight = 0
			local function place(cell, item)
				awaitPlaceSlot()
				inFlight += 1
				task.spawn(function()
					pcall(bedwars.placeBlock, cell * 3, item, false)
					inFlight -= 1
				end)
			end

			local ranOut = false
			pcall(function()
				for _ = 1, 4 do
					local sent = 0
					for layer, positions in plan do
						if not bedProtector.enabled then return end
						local sentHere = 0
						for _, cell in positions do
							if not getPlacedBlock(cell * 3) then
								local item = pickBlock(blocks, layer)
								if not item then
									ranOut = true
									break
								end
								place(cell, item)
								sentHere += 1
							end
						end
						sent += sentHere
					end
					if sent == 0 then return end
					local deadline = os.clock() + 1.5
					repeat
						task.wait()
					until inFlight <= 0 or os.clock() > deadline
					task.wait()
				end
			end)
			building = false

			local missing = 0
			for _, positions in plan do
				for _, cell in positions do
					if not getPlacedBlock(cell * 3) then
						missing += 1
					end
				end
			end
			if missing > 0 then
				local plural = missing == 1 and ' block' or ' blocks'
				notif('BedProtector', ranOut
					and ('Ran out of blocks, '..missing..plural..' short.')
					or (missing..plural..' could not be placed. Nobody can stand in the defense, you included:\nstep clear of the bed and run it again.'), 6)
			end

			if bedProtector.enabled then
				bedProtector:flip()
			end
		end,
		about = 'Walls your bed in with the strongest blocks you have.'
	})
	layers = bedProtector:slider('Layers', {
		min = 1,
		max = 4,
		default = 2,
		about = 'How many layers deep to build. The strongest blocks go against the bed.'
	})
end)
	
--[[ ChestSteal
Takes items out of the chests in Range, and with Steal out of enemy team crates in Loot Range.
Deposit banks what it took within the Stolen Within window into your nearest personal chest, so gear
you have carried all game is never banked. Delay paces every item, chest and deposit; at 0 every
item of a chest is requested at once, the way clicking through the chest screen sends them.

Every item you can carry is taken, and the score only sets the order: what refuses an item is
missing item meta, a block the game will not let you pick up and a full stack. Trap blocks (snap,
venom, explosive) carry disableInventoryPickup, which is about breaking a placed trap, so they are
taken anyway. A kit item such as the raven has no mechanical meta at all; one named in
chestItemPriority scores above every gear upgrade (KIT_ITEM_BASE), anything else still gets a floor.

SetObservedChest(nil) makes the client dispatch ChestClear, which blanks the open chest panel, so
only a chest ChestSteal opened is closed afterwards, and only once every take has answered: closing
a chest under a take turns the take away. Your inventory, personal chest and smelter live in
PlayerGui.PrivateInventory (in the older place, ReplicatedStorage.Inventories, the folders keyed to
your username) and are never looted, or the loot and deposit passes would trade the same items
forever.

A team crate carries both the team-crate and chest tags, so with Skip Own Crate on the plain chest
loop checks the crate's Team attribute too, as do Steal and a crate opened under GUI Check, compared
raw and through tonumber. A crate with no Team is fair game; while your own Team has not replicated
every crate is left alone.

Chests are opened one at a time with the other modules through bedwars.ChestLock ({Owner, Serial,
Holds = {[hold] = expiry}}). Every hold expires by itself, so a holder that errors cannot keep the
lock. rawget and rawset: bedwars' __index would look a missing name up as a Knit controller.

The server often answers false for an item still moving out of the chest it came from, so the
deposit sweep keeps an item in the stash until the server takes it, goes back to the front after
each success and lets the window age the rest out. Personal chests are found both by the
personal-chest tag the match server sets and by name among the chest tag. GUI Check reads the
ChestApp ScreenGui in PlayerGui: bedwars.AppController is the class, not the instance Flamework
hands out, and isAppOpen on it throws. ]]
run(function()
	local chestSteal
	local range
	local open
	local skywars
	local delaySlider
	local steal
	local lootRange
	local deposit
	local depositRange
	local stolenWithin
	local skipOwnCrate
	local delays = {}
	local nextDeposit = 0
	local stash = {}
	local chestItemPriority = {
		raven = 1200,
		recon_raven = 1150,
		emerald = 1000,
		diamond = 900,
		gold = 800,
		iron = 700,
		void_crystal = 650,
		telepearl = 950,
		fireball = 900,
		big_apple = 850,
		apple = 750,
		balloon = 800,
		arrow = 500,
		iron_arrow = 600,
		firework_arrow = 550,
		explosive_trap = 880,
		snap_trap = 870,
		venom_trap = 860
	}

	local TAKE_DESPITE_NO_PICKUP = {snap_trap = true, venom_trap = true, explosive_trap = true}

	local function getChestAmount(item)
		local amount = tonumber(item:GetAttribute('Amount'))
		return amount == nil and 1 or math.max(0, amount)
	end

	local function getInventoryAmount(item)
		local amount = tonumber(item.amount)
		return amount == nil and 1 or math.max(0, amount)
	end

	local function getItemPriority(itemType)
		local priority = chestItemPriority[itemType]
		if priority then return priority end
		if itemType:find('emerald', 1, true) then return 1000 end
		if itemType:find('diamond', 1, true) then return 900 end
		if itemType:find('gold', 1, true) then return 800 end
		if itemType:find('iron', 1, true) then return 700 end
		if itemType:find('arrow', 1, true) then return 500 end
		return 100
	end

	local function getBowValue(meta)
		local source = meta and meta.projectileSource
		if not source or not source.ammoItemTypes or not table.find(source.ammoItemTypes, 'arrow') then return end

		local projectileType = source.projectileType
		if type(projectileType) == 'function' then
			local success, resolved = pcall(projectileType, 'arrow')
			projectileType = success and resolved or nil
		end

		local projectileMeta = projectileType and bedwars.ProjectileMeta and bedwars.ProjectileMeta[projectileType]
		local damage = projectileMeta and projectileMeta.combat and tonumber(projectileMeta.combat.damage) or 0
		local fireDelay = tonumber(source.fireDelaySec) or 1
		return damage + (1 / math.max(fireDelay, 0.05)) * 0.01
	end

	local function addProfileItem(profile, itemType, amount)
		if not itemType then return end
		amount = tonumber(amount) or 1
		if amount <= 0 then return end
		profile.amounts[itemType] = (profile.amounts[itemType] or 0) + amount

		local meta = bedwars.ItemMeta[itemType]
		if not meta then return end

		local sword = meta.sword
		if sword then
			profile.sword = math.max(profile.sword, tonumber(sword.damage) or 0)
		end

		local armor = meta.armor
		if armor and armor.slot ~= nil then
			local value = tonumber(armor.damageReductionMultiplier) or 0
			profile.armor[armor.slot] = math.max(profile.armor[armor.slot] or 0, value)
		end

		local breakBlock = meta.breakBlock
		if breakBlock then
			for breakType, value in breakBlock do
				if type(value) == 'number' then
					profile.tools[breakType] = math.max(profile.tools[breakType] or 0, value)
				end
			end
		end

		local bowValue = getBowValue(meta)
		if bowValue then
			profile.bow = math.max(profile.bow, bowValue)
		end

		if meta.backpack then
			profile.backpack = true
		end
	end

	local function createInventoryProfile()
		local profile = {
			amounts = {},
			sword = 0,
			armor = {},
			tools = {},
			bow = 0,
			backpack = false
		}
		local inventory = store.inventory and store.inventory.inventory
		if not inventory then return profile end

		local seen = {}
		local function add(item)
			if type(item) ~= 'table' or not item.itemType then return end
			local key = item.tool or item
			if seen[key] then return end
			seen[key] = true
			addProfileItem(profile, item.itemType, getInventoryAmount(item))
		end

		for _, item in inventory.items or {} do
			add(item)
		end
		for _, item in inventory.armor or {} do
			add(item)
		end
		add(inventory.backpack)
		add(inventory.hand)
		return profile
	end

	local UPGRADE_BONUS = 1000000

	local function scoreChestItem(item, profile)
		if not item or not item:IsA('Accessory') then return end
		local itemType = item.Name
		local amount = getChestAmount(item)
		if amount <= 0 then return end

		local meta = bedwars.ItemMeta[itemType]
		if not meta or (meta.block and meta.block.disableInventoryPickup and not TAKE_DESPITE_NO_PICKUP[itemType]) then return end

		local currentAmount = profile.amounts[itemType] or 0
		local maxStackSize = meta.maxStackSize and tonumber(meta.maxStackSize.amount)
		if maxStackSize and currentAmount >= maxStackSize then return end

		local armor = meta.armor
		if armor and armor.slot ~= nil then
			local value = tonumber(armor.damageReductionMultiplier) or 0
			local current = profile.armor[armor.slot] or 0
			local score = 100000 + value * 10000
			if value > current then
				return score + UPGRADE_BONUS + (value - current) * 1000
			end
			return score
		end

		local sword = meta.sword
		if sword then
			local value = tonumber(sword.damage) or 0
			local score = 100000 + value * 10000
			if value > profile.sword then
				return score + UPGRADE_BONUS + (value - profile.sword) * 100
			end
			return score
		end

		local breakBlock = meta.breakBlock
		if breakBlock then
			local bestValue, improvement = 0, 0
			for breakType, value in breakBlock do
				if type(value) == 'number' then
					bestValue = math.max(bestValue, value)
					local current = profile.tools[breakType] or 0
					if value > current then
						improvement = math.max(improvement, value - current)
					end
				end
			end
			local score = 100000 + bestValue * 10000
			if improvement > 0 then
				return score + UPGRADE_BONUS + improvement * 100
			end
			return score
		end

		local bowValue = getBowValue(meta)
		if bowValue then
			local score = 100000 + bowValue * 10000
			if bowValue > profile.bow then
				return score + UPGRADE_BONUS + (bowValue - profile.bow) * 100
			end
			return score
		end

		if meta.backpack then
			local score = 90000 + getItemPriority(itemType) * 10 + math.min(amount, 100)
			return profile.backpack and score or score + UPGRADE_BONUS
		end

		if meta.hotbarFillRight then
			return 50000 + getItemPriority(itemType) * 10 + math.min(amount, 100)
		end

		local utility = meta.consumable or meta.balloon or meta.placesBlock or meta.projectileSource
			or meta.multiProjectileSource or meta.guidedProjectileSource or meta.fortifiesBlock
			or meta.cooldownId or meta.keepOnDeath or meta.maxStackSize
		if utility then
			return 30000 + getItemPriority(itemType) * 10 + math.min(amount, 100)
		end

		local block = meta.block
		if block then
			return 10000 + (tonumber(block.health) or 0) * 10 + math.min(amount, 100)
		end

		local KIT_ITEM_BASE = 5000000
		local named = chestItemPriority[itemType]
		if named then
			return KIT_ITEM_BASE + named * 10 + math.min(amount, 100)
		end
		return 5000 + math.min(amount, 100)
	end

	local function getBestChestItem(items, chest, profile)
		local bestIndex, bestScore, bestName = nil, -math.huge, nil
		for index, item in items do
			if item.Parent == chest then
				local score = scoreChestItem(item, profile)
				if score and (score > bestScore or (score == bestScore and (not bestName or item.Name < bestName))) then
					bestIndex, bestScore, bestName = index, score, item.Name
				end
			end
		end
		return bestIndex
	end

	local function observedFolder()
		local character = lplr.Character
		local observed = character and character:FindFirstChild('ObservedChestFolder')
		return observed and observed.Value or nil
	end

	local function privateInventory()
		local playerGui = lplr:FindFirstChildOfClass('PlayerGui')
		return playerGui and playerGui:FindFirstChild('PrivateInventory') or nil
	end

	local function isOwnStorage(folder)
		if not folder then return false end
		local private = privateInventory()
		if private and folder:IsDescendantOf(private) then return true end
		local owner = folder:GetAttribute('PersonalChest')
		if owner ~= nil and tonumber(owner) == lplr.UserId then return true end

		local inventories = replicatedStorage:FindFirstChild('Inventories')
		if not inventories or folder.Parent ~= inventories then return false end

		local name = folder.Name
		return name == lplr.Name
			or name == lplr.Name .. '_personal'
			or name == lplr.Name .. '_smelter'
	end

	local function chestLock()
		local lock = rawget(bedwars, 'ChestLock')
		if type(lock) ~= 'table' or type(lock.Holds) ~= 'table' then
			lock = {Serial = 0, Holds = {}}
			rawset(bedwars, 'ChestLock', lock)
		end
		return lock
	end

	local function chestLockHeld(lock, now)
		for _, expiry in lock.Holds do
			if now < expiry then return true end
		end
		return false
	end

	local function claimChestLock(seconds)
		local lock, now = chestLock(), os.clock()
		if lock.Owner ~= 'ChestSteal' then
			if lock.Owner ~= nil and chestLockHeld(lock, now) then return nil end
			lock.Owner = 'ChestSteal'
			table.clear(lock.Holds)
		end
		lock.Serial += 1
		lock.Holds[lock.Serial] = now + seconds
		return lock.Serial
	end

	local function releaseChestLock(hold)
		local lock = chestLock()
		if lock.Owner == 'ChestSteal' and lock.Holds[hold] then
			lock.Holds[hold] = nil
			if next(lock.Holds) == nil then lock.Owner = nil end
		end
	end

	local function sameTeam(a, b)
		if a == nil or b == nil then return false end
		if a == b then return true end
		local na = tonumber(a)
		return na ~= nil and na == tonumber(b)
	end

	local function isFriendlyCrate(block)
		local crateTeam = block:GetAttribute('Team')
		if crateTeam == nil then return false end

		local myTeam = lplr:GetAttribute('Team')
		if myTeam == nil then return true end

		return sameTeam(crateTeam, myTeam)
	end

	local function folderIsFriendlyCrate(crates, folder)
		if not folder then return false end
		for _, crate in crates do
			local value = crate:FindFirstChild('ChestFolderValue')
			if value and value.Value == folder then
				return isFriendlyCrate(crate)
			end
		end
		return false
	end

	local function skipsOwnCrate()
		return skipOwnCrate == nil or skipOwnCrate.enabled
	end

	local function lootChestUnlocked(chest, taken)
		chest = chest and chest.Value or nil
		if not chest or (delays[chest] or 0) >= tick() then return end
		if isOwnStorage(chest) then return end

		local accessories = {}
		for _, v in chest:GetChildren() do
			if v:IsA('Accessory') then
				table.insert(accessories, v)
			end
		end
		if #accessories == 0 then return end

		local profile = createInventoryProfile()
		if not getBestChestItem(accessories, chest, profile) then
			delays[chest] = tick() + delaySlider.value
			return
		end

		delays[chest] = tick() + delaySlider.value
		local inventory = bedwars.Client:GetNamespace('Inventory')
		local setObservedChest = inventory:Get('SetObservedChest')
		local chestGetItem = inventory:Get('ChestGetItem')

		local alreadyOpen = chest == observedFolder()
		if not alreadyOpen then
			local observed = pcall(function()
				setObservedChest:SendToServer(chest)
			end)
			if not observed then return end
		end

		if delaySlider.value <= 0 then
			local picks = {}
			while #accessories > 0 do
				local bestIndex = getBestChestItem(accessories, chest, profile)
				if not bestIndex then break end
				local item = table.remove(accessories, bestIndex)
				if item.Parent == chest then
					addProfileItem(profile, item.Name, getChestAmount(item))
					table.insert(picks, item)
				end
			end

			local pending, took = #picks, 0
			for _, item in picks do
				task.spawn(function()
					local success, result = pcall(function()
						return chestGetItem:CallServer(chest, item)
					end)
					if success and result ~= false then
						took += 1
						if taken then
							table.insert(taken, {Type = item.Name, Time = tick()})
						end
					end
					pending -= 1
				end)
			end
			local deadline = os.clock() + 3
			while pending > 0 and os.clock() < deadline do
				task.wait()
			end
			if #picks > 0 and took == 0 then
				delays[chest] = tick() + 0.5
			end
			accessories = {}
		end

		local firstItem = true
		while #accessories > 0 do
			if not chestSteal.enabled then break end

			if firstItem then
				firstItem = false
			else
				task.wait(delaySlider.value)
				if not (chestSteal.enabled and chest.Parent) then break end
			end

			local bestIndex = getBestChestItem(accessories, chest, profile)
			if not bestIndex then break end
			local item = table.remove(accessories, bestIndex)
			if item.Parent ~= chest then continue end

			local amount = getChestAmount(item)
			local success, result = pcall(function()
				return chestGetItem:CallServer(chest, item)
			end)
			if success and result ~= false then
				addProfileItem(profile, item.Name, amount)
				if taken then
					table.insert(taken, {Type = item.Name, Time = tick()})
				end
			end
		end

		if not alreadyOpen then
			pcall(function()
				setObservedChest:SendToServer(nil)
			end)
		end
	end

	local function lootChest(chest, taken)
		local hold = claimChestLock(10 + 24 * delaySlider.value)
		if not hold then return end
		local looted, lootError = pcall(lootChestUnlocked, chest, taken)
		releaseChestLock(hold)
		if not looted then error(lootError, 0) end
	end

	local function inventoryRemote(name)
		return bedwars.Client:GetNamespace('Inventory'):Get(name)
	end

	local function personalInventory()
		local private = privateInventory()
		local folder = private and private:FindFirstChild(lplr.Name .. '_personal')
		if folder then return folder end
		local inventories = replicatedStorage:FindFirstChild('Inventories')
		return inventories and inventories:FindFirstChild(lplr.Name .. '_personal') or nil
	end

	local depositing = false

	local function depositAll()
		if depositing then return end

		local inventory = personalInventory()
		if not inventory then return end

		local window = stolenWithin.value
		local now = tick()
		for index = #stash, 1, -1 do
			if now - stash[index].Time > window then
				table.remove(stash, index)
			end
		end
		if #stash == 0 then return end

		depositing = true
		task.spawn(function()
			local lockHold = claimChestLock(5 + #stash * (delaySlider.value + 1))
			if not lockHold then
				depositing = false
				return
			end
			local chestGiveItem = inventoryRemote('ChestGiveItem')

			if delaySlider.value <= 0 then
				local batch, seenTypes = {}, {}
				for _, entry in stash do
					if tick() - entry.Time <= stolenWithin.value and not seenTypes[entry.Type] then
						seenTypes[entry.Type] = true
						table.insert(batch, entry.Type)
					end
				end

				local pending = #batch
				for _, itemType in batch do
					task.spawn(function()
						local item = getItem(itemType)
						local given = false
						if item and item.tool and chestSteal.enabled and deposit.enabled then
							local success, result = pcall(function()
								return chestGiveItem:CallServer(inventory, item.tool)
							end)
							given = success and result ~= false
						end
						if given then
							for index = #stash, 1, -1 do
								if stash[index].Type == itemType then
									table.remove(stash, index)
								end
							end
						end
						pending -= 1
					end)
				end
				local deadline = os.clock() + 3
				while pending > 0 and os.clock() < deadline do
					task.wait()
				end
				releaseChestLock(lockHold)
				depositing = false
				return
			end

			local index = 1

			while index <= #stash do
				if not (chestSteal.enabled and deposit.enabled) then break end

				local entry = stash[index]
				if tick() - entry.Time > stolenWithin.value then
					table.remove(stash, index)
					continue
				end

				local item = getItem(entry.Type)
				local given = false
				if item and item.tool then
					local success, result = pcall(function()
						return chestGiveItem:CallServer(inventory, item.tool)
					end)
					given = success and result ~= false
				end

				if given then
					table.remove(stash, index)
					index = 1
				else
					index += 1
				end

				task.wait(delaySlider.value)
			end

			releaseChestLock(lockHold)
			depositing = false
		end)
	end

	local PERSONAL_CHESTS = {personal_chest = true, og_personal_chest = true}

	local function nearestPersonalChest(chests, personalChests, localPosition)
		local best, bestDistance = nil, math.huge
		for _, chest in personalChests do
			local distance = (localPosition - chest.Position).Magnitude
			if distance < bestDistance then best, bestDistance = chest, distance end
		end
		for _, chest in chests do
			if PERSONAL_CHESTS[chest.Name] then
				local distance = (localPosition - chest.Position).Magnitude
				if distance < bestDistance then best, bestDistance = chest, distance end
			end
		end
		return best, bestDistance
	end

	local function chestAppOpen()
		local playerGui = lplr:FindFirstChildOfClass('PlayerGui')
		local app = playerGui and playerGui:FindFirstChild('ChestApp')
		if app then return app.Enabled ~= false end

		local ok, open = pcall(function()
			return bedwars.AppController:isAppOpen('ChestApp')
		end)
		return (ok and open) and true or false
	end

	local function stealPass(crates, localPosition)
		for _, crate in crates do
			if skipsOwnCrate() and isFriendlyCrate(crate) then continue end
			if (localPosition - crate.Position).Magnitude <= lootRange.value then
				lootChest(crate:FindFirstChild('ChestFolderValue'), stash)
			end
		end
	end

	local function depositPass(chests, personalChests, localPosition)
		if tick() < nextDeposit then return end
		nextDeposit = tick() + delaySlider.value

		local chest, distance = nearestPersonalChest(chests, personalChests, localPosition)
		if not chest or distance > depositRange.value then return end

		depositAll()
	end

	chestSteal = world:module('ChestSteal', {
		info = function()
			return delaySlider and math.round(delaySlider.value * 1000)..'ms' or nil
		end,
		tab = 'Utility',
		toggled = function(on)
			if on then
				local chests = collection('chest', chestSteal)
				local crates = collection('team-crate', chestSteal)
				local personalChests = collection('personal-chest', chestSteal)
				repeat task.wait(0.1) until store.queueType ~= 'bedwars_test' or (not chestSteal.enabled)
				if not chestSteal.enabled then return end
				if (not skywars.enabled) or store.queueType:find('skywars') then
					repeat
						if entitylib.isAlive and store.matchState ~= 2 then
							local localPosition = entitylib.character.RootPart.Position
							local guiOpen = (not open.enabled) or chestAppOpen()

							if open.enabled then
								if guiOpen then
									local observed = lplr.Character and lplr.Character:FindFirstChild('ObservedChestFolder')
									if not (skipsOwnCrate() and folderIsFriendlyCrate(crates, observed and observed.Value)) then
										lootChest(observed, stash)
									end
								end
							else
								for _, v in chests do
									if PERSONAL_CHESTS[v.Name] or v.Name == 'lucky_block_item_smelter' then continue end
									if skipsOwnCrate() and isFriendlyCrate(v) then continue end
									if (localPosition - v.Position).Magnitude <= range.value then
										lootChest(v:FindFirstChild('ChestFolderValue'), stash)
									end
								end

								if steal.enabled then
									stealPass(crates, localPosition)
								end
							end

							if deposit.enabled and guiOpen then
								depositPass(chests, personalChests, localPosition)
							end
						end
						task.wait(delaySlider.value)
					until not chestSteal.enabled
				end
			else
				table.clear(delays)
				table.clear(stash)
				nextDeposit = 0
				depositing = false
			end
		end,
		about = 'Pulls items out of the chests near you.\nCan also loot enemy crates and stash loot in your own chest.'
	})
	range = chestSteal:slider('Range', {
		min = 0,
		max = 18,
		default = 18,
		suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end,
		about = 'How far to reach for a chest.'
	})
	delaySlider = chestSteal:slider('Delay', {
		min = 0,
		max = 3,
		default = 0.5,
		decimal = 10,
		suffix = function(val) return 's' end,
		about = 'Wait between every action - item, chest and deposit.'
	})
	steal = chestSteal:toggle('Steal', {
		changed = function()
			if lootRange and lootRange.row then
				lootRange.row.Visible = steal.enabled
			end
		end,
		about = 'Also loots enemy team crates.'
	})
	lootRange = chestSteal:slider('Loot Range', {
		min = 1,
		max = 18,
		default = 18,
		sub = true,
		suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end,
		about = 'How far to reach for a crate.'
	})
	deposit = chestSteal:toggle('Deposit', {
		changed = function()
			if depositRange and depositRange.row then
				depositRange.row.Visible = deposit.enabled
			end
			if stolenWithin and stolenWithin.row then
				stolenWithin.row.Visible = deposit.enabled
			end
		end,
		about = 'Puts fresh loot into your personal chest.'
	})
	depositRange = chestSteal:slider('Deposit Range', {
		min = 1,
		max = 18,
		default = 7.5,
		decimal = 10,
		sub = true,
		suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end,
		about = 'How close to your personal chest to deposit.'
	})
	stolenWithin = chestSteal:slider('Stolen Within', {
		min = 1,
		max = 15,
		default = 10,
		decimal = 10,
		sub = true,
		suffix = function(val) return 's' end,
		about = 'Only deposits loot taken this recently.'
	})
	if lootRange.row then
		lootRange.row.Visible = steal.enabled
	end
	if depositRange.row then
		depositRange.row.Visible = deposit.enabled
	end
	if stolenWithin.row then
		stolenWithin.row.Visible = deposit.enabled
	end
	open = chestSteal:toggle('GUI Check', {
		about = 'Only acts on the chest you have open.'
	})
	skipOwnCrate = chestSteal:toggle('Skip Own Crate', {
		default = true,
		about = "Leaves your team's crate alone."
	})
	skywars = chestSteal:toggle('Only Skywars', {
		changed = function()
			if chestSteal.enabled then
				chestSteal:flip(nil, true)
				chestSteal:flip(nil, true)
			end
		end,
		default = true,
		about = 'Stays off outside Skywars.'
	})
end)
	
--[[ Schematica
Saves your builds to a file and rebuilds them for you. Shows a see-through preview while it places
the blocks. ]]
run(function()
	local schematica
	local file
	local mode
	local transparency
	local parts, guidata, poschecklist = {}, {}, {}
	local point1, point2
	
	for x = -3, 3, 3 do
		for y = -3, 3, 3 do
			for z = -3, 3, 3 do
				if Vector3.new(x, y, z) ~= Vector3.zero then
					table.insert(poschecklist, Vector3.new(x, y, z))
				end
			end
		end
	end
	
	local function checkAdjacent(pos)
		for _, v in poschecklist do
			if getPlacedBlock(pos + v) then return true end
		end
		return false
	end
	
	local function getPlacedBlocksInPoints(s, e)
		local list, blocks = {}, bedwars.BlockController:getStore()
		for x = (e.X > s.X and s.X or e.X), (e.X > s.X and e.X or s.X) do
			for y = (e.Y > s.Y and s.Y or e.Y), (e.Y > s.Y and e.Y or s.Y) do
				for z = (e.Z > s.Z and s.Z or e.Z), (e.Z > s.Z and e.Z or s.Z) do
					local vec = Vector3.new(x, y, z)
					local block = blocks:getBlockAt(vec)
					if block and block:GetAttribute('PlacedByUserId') == lplr.UserId then
						list[vec] = block
					end
				end
			end
		end
		return list
	end
	
	local function loadMaterials()
		for _, v in guidata do 
			v:Destroy() 
		end
		local suc, read = pcall(function() 
			return isfile(file.value) and httpService:JSONDecode(readfile(file.value)) 
		end)
	
		if suc and read then
			local items = {}
			for _, v in read do 
				items[v[2]] = (items[v[2]] or 0) + 1 
			end
			
			for i, v in items do
				local holder = Instance.new('Frame')
				holder.Size = UDim2.new(1, 0, 0, 32)
				holder.BackgroundTransparency = 1
				holder.Parent = schematica.frame
				local icon = Instance.new('ImageLabel')
				icon.Size = UDim2.fromOffset(24, 24)
				icon.Position = UDim2.fromOffset(4, 4)
				icon.BackgroundTransparency = 1
				icon.Image = bedwars.getIcon({itemType = i}, true)
				icon.Parent = holder
				local text = Instance.new('TextLabel')
				text.Size = UDim2.fromOffset(100, 32)
				text.Position = UDim2.fromOffset(32, 0)
				text.BackgroundTransparency = 1
				text.Text = (bedwars.ItemMeta[i] and bedwars.ItemMeta[i].displayName or i)..': '..v
				text.TextXAlignment = Enum.TextXAlignment.Left
				text.TextColor3 = uipallet.Text
				text.TextSize = 14
				text.FontFace = uipallet.Font
				text.Parent = holder
				table.insert(guidata, holder)
			end
			table.clear(read)
			table.clear(items)
		end
	end
	
	local function save()
		if point1 and point2 then
			local tab = getPlacedBlocksInPoints(point1, point2)
			local savetab = {}
			point1 = point1 * 3
			for i, v in tab do
				i = bedwars.BlockController:getBlockPosition(CFrame.lookAlong(point1, entitylib.character.RootPart.CFrame.LookVector):PointToObjectSpace(i * 3)) * 3
				table.insert(savetab, {
					{
						x = i.X, 
						y = i.Y, 
						z = i.Z
					}, 
					v.Name
				})
			end
			point1, point2 = nil, nil
			writefile(file.value, httpService:JSONEncode(savetab))
			notif('Schematica', 'Saved '..getTableSize(tab)..' blocks', 5)
			loadMaterials()
			table.clear(tab)
			table.clear(savetab)
		else
			local mouseinfo = bedwars.BlockBreaker.clientManager:getBlockSelector():getMouseInfo(0)
			if mouseinfo and mouseinfo.target then
				if point1 then
					point2 = mouseinfo.target.blockRef.blockPosition
					notif('Schematica', 'Selected position 2, toggle again near position 1 to save it', 3)
				else
					point1 = mouseinfo.target.blockRef.blockPosition
					notif('Schematica', 'Selected position 1', 3)
				end
			end
		end
	end
	
	local function load(read)
		local mouseinfo = bedwars.BlockBreaker.clientManager:getBlockSelector():getMouseInfo(0)
		if mouseinfo and mouseinfo.target then
			local position = CFrame.new(mouseinfo.placementPosition * 3) * CFrame.Angles(0, math.rad(math.round(math.deg(math.atan2(-entitylib.character.RootPart.CFrame.LookVector.X, -entitylib.character.RootPart.CFrame.LookVector.Z)) / 45) * 45), 0)
	
			for _, v in read do
				local blockpos = bedwars.BlockController:getBlockPosition((position * CFrame.new(v[1].x, v[1].y, v[1].z)).p) * 3
				if parts[blockpos] then continue end
				local handler = bedwars.BlockController:getHandlerRegistry():getHandler(v[2]:find('wool') and getWool() or v[2])
				if handler then
					local part = handler:place(blockpos / 3, 0)
					part.Transparency = transparency.value
					part.CanCollide = false
					part.Anchored = true
					part.Parent = workspace
					parts[blockpos] = part
				end
			end
			table.clear(read)
	
			repeat
				if entitylib.isAlive then
					local localPosition = entitylib.character.RootPart.Position
					for i, v in parts do
						if (i - localPosition).Magnitude < 60 and checkAdjacent(i) then
							if not schematica.enabled then break end
							if not getItem(v.Name) then continue end
							bedwars.placeBlock(i, v.Name, false)
							task.delay(0.1, function()
								local block = getPlacedBlock(i)
								if block then
									v:Destroy()
									parts[i] = nil
								end
							end)
						end
					end
				end
				task.wait(0.1)
			until getTableSize(parts) <= 0
	
			if getTableSize(parts) <= 0 and schematica.enabled then
				notif('Schematica', 'Finished building', 5)
				schematica:flip()
			end
		end
	end
	
	schematica = world:module('Schematica', {
		toggled = function(on)
			if on then
				if not file.value:find('.json') then
					notif('Schematica', 'Invalid file', 3)
					schematica:flip()
					return
				end
	
				if mode.value == 'Save' then
					save()
					schematica:flip(nil, true)
				else
					local suc, read = pcall(function() 
						return isfile(file.value) and httpService:JSONDecode(readfile(file.value)) 
					end)
	
					if suc and read then
						load(read)
					else
						notif('Schematica', 'Missing / corrupted file', 3)
						schematica:flip()
					end
				end
			else
				for _, v in parts do 
					v:Destroy() 
				end
				table.clear(parts)
			end
		end,
		about = 'Saves your builds to a file and rebuilds them for you.\nShows a see-through preview while it places the blocks.'
	})
	file = schematica:textbox('File', {
		changed = function()
			loadMaterials()
			point1, point2 = nil, nil
		end
	})
	mode = schematica:dropdown('Mode', {
		choices = {'Load', 'Save'}
	})
	transparency = schematica:slider('Transparency', {
		min = 0,
		max = 1,
		default = 0.7,
		decimal = 10,
		changed = function(val)
			for _, v in parts do 
				v.Transparency = val 
			end
		end
	})
end)
	
--[[ ArmorSwitch
Swaps your armor on and off for baiting. Wears it only near enemies, or flips it with a keybind. ]]
run(function()
	if exec.skip('ArmorSwitch') then return end
	local armorSwitch
	local mode
	local targets
	local range
	local targetPriority

	local function hasTarget()
		return priorityTarget({
			Part = 'RootPart',
			Range = range.value,
			Players = targets.players.enabled,
			NPCs = targets.npcs.enabled,
			Wallcheck = targets.walls.enabled,
			Milo = targets.milo and targets.milo.enabled or nil
		}, targetPriority) ~= nil
	end
	
	armorSwitch = inventory:module('ArmorSwitch', {
		toggled = function(on)
			if on then
				if mode.value == 'Toggle' then
					repeat
						local state = hasTarget()
	
						for i = 0, 2 do
							if (store.inventory.inventory.armor[i + 1] ~= 'empty') ~= state and armorSwitch.enabled then
								bedwars.Store:dispatch({
									type = 'InventorySetArmorItem',
									item = store.inventory.inventory.armor[i + 1] == 'empty' and state and getBestArmor(i) or nil,
									armorSlot = i
								})
								slinkyEvents.InventoryChanged.Event:Wait()
							end
						end
						task.wait(0.1)
					until not armorSwitch.enabled
				else
					armorSwitch:flip(nil, true)
					for i = 0, 2 do
						bedwars.Store:dispatch({
							type = 'InventorySetArmorItem',
							item = store.inventory.inventory.armor[i + 1] == 'empty' and getBestArmor(i) or nil,
							armorSlot = i
						})
						slinkyEvents.InventoryChanged.Event:Wait()
					end
				end
			end
		end,
		about = 'Swaps your armor on and off for baiting.\nWears it only near enemies, or flips it with a keybind.'
	})
	mode = armorSwitch:dropdown('Mode', {
		choices = {'Toggle', 'On Key'}
	})
	targets = armorSwitch:targets({
		players = true,
		npcs = true,
		milo = false
	})
	targetPriority = armorSwitch:dropdown('Target Priority', {
		choices = {'Players first', 'NPCs first', 'Closest'},
		default = 'Players first'
	})
	range = armorSwitch:slider('Range', {
		min = 1,
		max = 30,
		default = 30,
		suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
end)
	
--[[ AutoBuy
Buys swords, armor, tools, team upgrades and the entries of your own Item list while you stand at a
shopkeeper. Kit Fusion (combined_kit_to4) and Hyper Kits (overpowered) run the same shop under other
queue names, so Only Bedwars also asks QueueMeta which game a queue runs. While AutoWin runs,
AutoBuy only buys team upgrades.

The sword line is read from your shop with your kit applied (getShopItem with the player runs the
game's shop overrides): Ice Queen, Ember and Lumen get their kit sword straight after iron, and
nothing after it. A tier the queue's shop does not sell comes back nil and is skipped. The
BedwarsItemShop tag can sit on a Model, so the shop's distance is read with GetPivot.

At your own base's upgrade shop the game counts the diamonds in your team chest with yours
(team-upgrade-util: hasEnoughForTeamUpgrade with IsHomeBase), from the chest you are observing. With
Use Team Chest a purchase that needs the chest observes your team crate first, as opening that shop
does, unless another chest is open, and the last purchase to answer lets it go;
SetObservedChest(nil) would close a chest opened since, so that one is left alone. Your own diamonds
are spent first. Team upgrades are paid in the game's team upgrade resource, not always diamonds.

In range of a shopkeeper AutoBuy checks again every 0.3 s even after a pass that bought nothing: a
teammate's upgrade or the shop loading changes what you can afford without touching your inventory.
After a purchase the next pass waits 0.4 s so it reads an inventory the server has updated, as a
stale read buys the same tier twice. Walking into range buys on that pass, but never inside that
wait. An Item entry without a number for its amount is skipped. ]]
run(function()
	local autoBuy
	local sword
	local armor
	local upgrades
	local teamChest
	local tierCheck
	local bedwarsCheck
	local gui
	local smartCheck
	local custom = {}
	local customPost = {}
	local upgradeToggles = {}
	local functions, id = {}
	local callbacks = {custom, functions, customPost}
	local npctick = tick()

	local BEDWARS_GAMES = {bedwars = true, ['combined-kit'] = true, overpowered = true}
	local function isBedwarsQueue(queueType)
		if queueType:find('bedwars') then return true end
		local meta = bedwars.QueueMeta and bedwars.QueueMeta[queueType]
		return type(meta) == 'table' and BEDWARS_GAMES[meta.game] == true
	end
	
	local swords = {
		'wood_sword',
		'stone_sword',
		'iron_sword',
		'diamond_sword',
		'emerald_sword'
	}
	
	local armors = {
		'none',
		'leather_chestplate',
		'iron_chestplate',
		'diamond_chestplate',
		'emerald_chestplate'
	}
	
	local axes = {
		'none',
		'wood_axe',
		'stone_axe',
		'iron_axe',
		'diamond_axe'
	}
	
	local pickaxes = {
		'none',
		'wood_pickaxe',
		'stone_pickaxe',
		'iron_pickaxe',
		'diamond_pickaxe'
	}

	local function swordLine()
		local dao = store.hasKit('dasher')
		local line = {dao and 'wood_dao' or 'wood_sword'}
		local itemType, seen = dao and 'stone_dao' or 'stone_sword', {}
		while itemType and not seen[itemType] and #line < 10 do
			seen[itemType] = true
			table.insert(line, itemType)
			local ok, item = pcall(bedwars.Shop.getShopItem, itemType, lplr)
			itemType = ok and type(item) == 'table' and item.nextTier or nil
		end
		return line
	end

	local function getShopNPC()
		local shop, items, upgrades, newid = nil, false, false, nil
		if entitylib.isAlive then
			local localPosition = entitylib.character.RootPart.Position
			for _, v in store.shop do
				if (v.RootPart:GetPivot().Position - localPosition).Magnitude <= 20 then
					shop = v.Upgrades or v.Shop or nil
					upgrades = upgrades or v.Upgrades
					items = items or v.Shop
					newid = v.Shop and v.Id or newid
				end
			end
		end
		return shop, items, upgrades, newid
	end

	local function haveCurrency(currency, currencytable)
		if currencytable[currency] == nil then
			local bank = store.AutoBank
			if bank and bank.GetAvailable then
				currencytable[currency] = bank:GetAvailable(currency)
			else
				local item = getItem(currency)
				currencytable[currency] = item and item.amount or 0
			end
		end
		return currencytable[currency]
	end

	local TEAM_CHEST = '@teamChest'
	local crateHolds, crateObserved = 0, nil

	local function homeUpgradeShop()
		if not entitylib.isAlive then return false end
		local team = lplr:GetAttribute('Team')
		if team == nil then return false end
		local position = entitylib.character.RootPart.Position
		for _, v in store.shop do
			if v.Upgrades and tostring(v.RootPart:GetAttribute('GeneratorTeam')) == tostring(team)
				and (v.RootPart:GetPivot().Position - position).Magnitude <= 20 then
				return true
			end
		end
		return false
	end

	local function teamCrateFolder()
		local team = lplr:GetAttribute('Team')
		if team == nil or team == 0 then return nil end
		for _, crate in collectionService:GetTagged('team-crate') do
			if crate:GetAttribute('Team') == team then
				local link = crate:FindFirstChild('ChestFolderValue')
				return link and link.Value or nil
			end
		end
		return nil
	end

	local function folderAmount(folder, itemType)
		local total = 0
		for _, item in folder:GetChildren() do
			if item.Name == itemType then
				total += tonumber(item:GetAttribute('Amount')) or 1
			end
		end
		return total
	end

	local function observedChest()
		local character = lplr.Character
		local observed = character and character:FindFirstChild('ObservedChestFolder')
		return observed and observed.Value or nil
	end

	local function holdCrate(folder)
		local current = observedChest()
		if current ~= nil and current ~= folder then return false end
		if current == nil and crateObserved ~= folder then
			local sent = pcall(function()
				bedwars.Client:GetNamespace('Inventory'):Get('SetObservedChest'):SendToServer(folder)
			end)
			if not sent then return false end
			crateObserved = folder
		end
		crateHolds += 1
		return true
	end

	local function releaseCrate()
		crateHolds = math.max(crateHolds - 1, 0)
		if crateHolds == 0 and crateObserved then
			local folder = crateObserved
			crateObserved = nil
			local current = observedChest()
			if current == nil or current == folder then
				pcall(function()
					bedwars.Client:GetNamespace('Inventory'):Get('SetObservedChest'):SendToServer(nil)
				end)
			end
		end
	end

	local function canBuy(item, currencytable, amount)
		amount = amount or 1
		haveCurrency(item.currency, currencytable)
		if item.ignoredByKit then
			for _, kit in item.ignoredByKit do
				if store.hasKit(kit) then return false end
			end
		end
		if item.lockedByForge or item.disabled then return false end
		if item.require and item.require.teamUpgrade then
			if (bedwars.Store:getState().Bedwars.teamUpgrades[item.require.teamUpgrade.upgradeId] or -1) < item.require.teamUpgrade.lowestTierIndex then
				return false
			end
		end
		return currencytable[item.currency] >= (item.price * amount)
	end
	
	local function buyItem(item, currencytable)
		if not id then return end
		bedwars.Client:Get('BedwarsPurchaseItem'):CallServerAsync({
			itemType = item.itemType,
			shopId = id
		}):andThen(function(suc)
			if suc then
				notif('AutoBuy', 'Bought '..bedwars.ItemMeta[item.itemType].displayName, 3)
				bedwars.SoundManager:playSound(bedwars.SoundList.BEDWARS_PURCHASE_ITEM)
				bedwars.Store:dispatch({
					type = 'BedwarsAddItemPurchased',
					itemType = item.itemType
				})
			end
		end)
		currencytable[item.currency] -= item.price
	end
	
    local function buyUpgrade(upgradeType, currencytable)
        if not upgrades.enabled then return end
        local upgrade = bedwars.TeamUpgradeMeta[upgradeType]
        local currentUpgrades = bedwars.Store:getState().Bedwars.teamUpgrades[lplr:GetAttribute('Team')] or {}
        local currentTier = (currentUpgrades[upgradeType] or 0) + 1
        local bought = false
        local utilOk, util = pcall(function()
            return require(replicatedStorage.TS.games.bedwars['team-upgrade']['team-upgrade-util']).TeamUpgradeUtil
        end)
        local currency = utilOk and util and util.TEAM_UPGRADE_RESOURCE or 'diamond'

        local crate = teamChest.enabled and homeUpgradeShop() and teamCrateFolder() or nil
        if crate and currencytable[TEAM_CHEST] == nil then
            currencytable[TEAM_CHEST] = folderAmount(crate, currency)
        end

        for i = currentTier, #upgrade.tiers do
            local tier = upgrade.tiers[i]
            if tier.availableOnlyInQueue and not table.find(tier.availableOnlyInQueue, store.queueType) then continue end

            local own = haveCurrency(currency, currencytable)
            local chest = crate and currencytable[TEAM_CHEST] or 0
            if own + chest < tier.cost then break end
            local needsChest = own < tier.cost
            if needsChest and not holdCrate(crate) then break end

            bedwars.Client:Get('RequestPurchaseTeamUpgrade'):CallServerAsync(upgradeType):andThen(function(suc)
                if needsChest then releaseCrate() end
                if suc then
                    notif('AutoBuy', 'Bought '..(upgrade.name == 'Armor' and 'Protection' or upgrade.name)..' '..i, 3)
                end
            end, function()
                if needsChest then releaseCrate() end
            end)
            local fromOwn = math.min(own, tier.cost)
            currencytable[currency] = own - fromOwn
            if needsChest then
                currencytable[TEAM_CHEST] = chest - (tier.cost - fromOwn)
            end
            bought = true
        end

        return bought
    end
	
	local function buyTool(tool, tools, currencytable)
		local bought, buyable = false
		tool = tool and table.find(tools, tool.itemType) and table.find(tools, tool.itemType) + 1 or math.huge
	
		for i = tool, #tools do
			local v = bedwars.Shop.getShopItem(tools[i], lplr)
			if not v then continue end
			if canBuy(v, currencytable) then
				if smartCheck.enabled and bedwars.ItemMeta[tools[i]].breakBlock and i > 2 then
					if armor.enabled then
						local currentarmor = store.inventory.inventory.armor[2]
						currentarmor = currentarmor and currentarmor ~= 'empty' and currentarmor.itemType or 'none'
						if (table.find(armors, currentarmor) or 3) < 3 then break end
					end
					if sword.enabled then
						if store.tools.sword and (table.find(swords, store.tools.sword.itemType) or 2) < 2 then break end
					end
				end
				bought = true
				buyable = v
			end
			if tierCheck.enabled and v.nextTier then break end
		end
	
		if buyable then
			buyItem(buyable, currencytable)
		end
	
		return bought
	end
	
	autoBuy = inventory:module('AutoBuy', {
		toggled = function(on)
			if on then
				if store.AutoWin and store.AutoWin.Enabled then
					notif(
						'AutoBuy',
						'AutoWin is running: AutoBuy only buys team upgrades until it stops.',
						5
					)
				end
				repeat task.wait(0.1) until store.queueType ~= 'bedwars_test' or (not autoBuy.enabled)
				if not autoBuy.enabled then return end
				if bedwarsCheck.enabled and not isBedwarsQueue(store.queueType) then return end

				local idlerecheck = 0.3
				local lastupgrades, wasnear, buytick = nil, false, 0

				repeat
					local npc, shop, upgrades, newid = getShopNPC()
					id = newid
					if gui.enabled then
						if not (bedwars.AppController:isAppOpen('BedwarsItemShopApp') or bedwars.AppController:isAppOpen('TeamUpgradeApp')) then
							npc = nil
						end
					end

					if npc and (not wasnear or lastupgrades ~= upgrades) then
						npctick = math.max(tick(), buytick)
						lastupgrades = upgrades
					end
					wasnear = npc ~= nil

					if npc and npctick <= tick() and store.matchState ~= 2 and store.shopLoaded then
						local currencytable = {}
						local waitcheck
						local itemShop = not (store.AutoWin and store.AutoWin.Enabled) and shop or nil
						for _, tab in callbacks do
							for _, callback in tab do
								if callback(currencytable, itemShop, upgrades) then
									waitcheck = true
								end
							end
						end
						buytick = waitcheck and (tick() + 0.4) or buytick
						npctick = tick() + (waitcheck and 0.4 or idlerecheck)
					end
	
					task.wait(0.1)
				until not autoBuy.enabled
			else
				npctick = tick()
			end
		end,
		about = 'Buys gear and upgrades when you are near a shop.\nCovers swords, armor, tools, team upgrades and your own list.'
	})
	sword = autoBuy:toggle('Buy Sword', {
		changed = function(callback)
			npctick = tick()
			functions[2] = callback and function(currencytable, shop)
				if not shop then return end
				return buyTool(store.tools.sword, swordLine(), currencytable)
			end or nil
		end
	})
	armor = autoBuy:toggle('Buy Armor', {
		changed = function(callback)
			npctick = tick()
			functions[1] = callback and function(currencytable, shop)
				if not shop then return end
				local currentarmor = store.inventory.inventory.armor[2] ~= 'empty' and store.inventory.inventory.armor[2] or getBestArmor(1)
				currentarmor = currentarmor and currentarmor.itemType or 'none'
				return buyTool({itemType = currentarmor}, armors, currencytable)
			end or nil
		end,
		default = true
	})
	autoBuy:toggle('Buy Axe', {
		changed = function(callback)
			npctick = tick()
			functions[3] = callback and function(currencytable, shop)
				if not shop then return end
				return buyTool(store.tools.wood or {itemType = 'none'}, axes, currencytable)
			end or nil
		end
	})
	autoBuy:toggle('Buy Pickaxe', {
		changed = function(callback)
			npctick = tick()
			functions[4] = callback and function(currencytable, shop)
				if not shop then return end
				return buyTool(store.tools.stone, pickaxes, currencytable)
			end or nil
		end
	})
	upgrades = autoBuy:toggle('Buy Upgrades', {
		changed = function(callback)
			for _, v in upgradeToggles do
				v.row.Visible = callback
			end
		end,
		default = true
	})
	teamChest = autoBuy:toggle('Use Team Chest', {
		sub = true,
		default = true,
		about = 'Counts the diamonds in your team chest, as the upgrade shop at your base does'
	})
	table.insert(upgradeToggles, teamChest)
	local count = 0
	for i, v in bedwars.TeamUpgradeMeta do
		local toggleCount = count
		table.insert(upgradeToggles, autoBuy:toggle('Buy '..(v.name == 'Armor' and 'Protection' or v.name), {
			changed = function(callback)
				npctick = tick()
				functions[5 + toggleCount + (v.name == 'Armor' and 20 or 0)] = callback and function(currencytable, shop, upgrades)
					if not upgrades then return end
					if v.disabledInQueue and table.find(v.disabledInQueue, store.queueType) then return end
					return buyUpgrade(i, currencytable)
				end or nil
			end,
			sub = true,
			default = (i == 'ARMOR' or i == 'DAMAGE')
		}))
		count += 1
	end
	tierCheck = autoBuy:toggle('Tier Check')
	bedwarsCheck = autoBuy:toggle('Only Bedwars', {
		changed = function()
			if autoBuy.enabled then
				autoBuy:flip(nil, true)
				autoBuy:flip(nil, true)
			end
		end,
		default = true
	})
	gui = autoBuy:toggle('GUI check')
	smartCheck = autoBuy:toggle('Smart check', {
		default = true,
		about = 'Gets iron armor before the iron axe'
	})
	autoBuy:list('Item', {
		placeholder = 'priority/item/amount/after',
		changed = function(list)
			table.clear(custom)
			table.clear(customPost)
			for _, entry in list do
				local tab = entry:split('/')
				local ind = tonumber(tab[1])
				if ind and tonumber(tab[3]) then
					(tab[4] and customPost or custom)[ind] = function(currencytable, shop)
						if not shop then return end
	
						local v = bedwars.Shop.getShopItem(tab[2], lplr)
						if v then
							local item = getItem(tab[2] == 'wool_white' and bedwars.Shop.getTeamWool(lplr:GetAttribute('Team')) or tab[2])
							item = (item and tonumber(tab[3]) - item.amount or tonumber(tab[3])) // v.amount
							if item > 0 and canBuy(v, currencytable, item) then
								for _ = 1, item do
									buyItem(v, currencytable)
								end
								return true
							end
						end
					end
				end
			end
		end
	})
end)
	
--[[ AutoConsume
Drinks speed potions, eats apples below Health Percent and uses shield potions. Besides the
inventory and attribute events it looks once a second: one consume runs at a time, so a trigger
during one gets nothing, and knitless a refused item rests a while (knitless.consumeRemote). The
look is connected before the first check, which can yield for seconds.

A death, or turning AutoConsume off mid-drink, calls store.handRelease, which drops the drink and
gives the hand back to the other modules (knitless.holdHand). A speed potion is retried up to four
times only while AutoConsume is on and you are alive, since a drink let go mid-way answers nil as a
refusal does. ]]
run(function()
	local autoConsume
	local health
	local speedPotion
	local apple
	local shieldPotion
	
	local function consumeCheck(attribute)
		if entitylib.isAlive then
			if speedPotion.enabled and (not attribute or attribute == 'StatusEffect_speed') then
				local speedpotion = getItem('speed_potion')
				if speedpotion and (not lplr.Character:GetAttribute('StatusEffect_speed')) then
					for _ = 1, 4 do
						if not (autoConsume.enabled and entitylib.isAlive) then break end
						if bedwars.getConsumeRemote():CallServer({item = speedpotion.tool}) then break end
					end
				end
			end
	
			if apple.enabled and (not attribute or attribute:find('Health')) then
				if (lplr.Character:GetAttribute('Health') / lplr.Character:GetAttribute('MaxHealth')) <= (health.value / 100) then
					local apple = getItem('orange') or (not lplr.Character:GetAttribute('StatusEffect_golden_apple') and getItem('golden_apple')) or getItem('apple')
					
					if apple then
						bedwars.getConsumeRemote():CallServerAsync({
							item = apple.tool
						})
					end
				end
			end
	
			if shieldPotion.enabled and (not attribute or attribute:find('Shield')) then
				if (lplr.Character:GetAttribute('Shield_POTION') or 0) == 0 then
					local shield = getItem('big_shield') or getItem('mini_shield')
	
					if shield then
						bedwars.getConsumeRemote():CallServerAsync({
							item = shield.tool
						})
					end
				end
			end
		end
	end
	
	autoConsume = inventory:module('AutoConsume', {
		info = function()
			return health and health.value..'%' or nil
		end,
		toggled = function(on)
			if on then
				autoConsume:clean(slinkyEvents.InventoryAmountChanged.Event:Connect(consumeCheck))
				autoConsume:clean(slinkyEvents.AttributeChanged.Event:Connect(function(attribute)
					if attribute:find('Shield') or attribute:find('Health') or attribute == 'StatusEffect_speed' then
						consumeCheck(attribute)
					end
				end))
				do
					local nextLook = os.clock() + 1
					autoConsume:clean(runService.Heartbeat:Connect(function()
						if os.clock() < nextLook then return end
						nextLook = os.clock() + 1
						task.spawn(consumeCheck)
					end))
				end
				autoConsume:clean(entitylib.Events.LocalRemoved:Connect(function()
					if store.handRelease then store.handRelease(true) end
				end))
				consumeCheck()
			elseif store.handRelease then
				store.handRelease(true)
			end
		end,
		about = 'Uses healing items and potions when you need them.\nCovers apples, speed potions and shield potions.'
	})
	health = autoConsume:slider('Health Percent', {
		min = 1,
		max = 99,
		default = 70,
		suffix = function(val) return '%' end
	})
	speedPotion = autoConsume:toggle('Speed Potions', {
		default = true
	})
	apple = autoConsume:toggle('Apple', {
		default = true
	})
	shieldPotion = autoConsume:toggle('Shield Potions', {
		default = true
	})
end)
	
--[[ AutoHotbar
Sorts your items into the layout selected in its hotbar list, whenever your inventory changes or
once with On Key; Clear Hotbar sends every other hotbar item back to the inventory. In a layout
diamond_sword, diamond_pickaxe, diamond_axe and wood_bow stand for your best item of that kind, and
wool_white for your smallest stack of solid blocks.

The editor and the list are built in the loader's look. At the HUD's scale a phone would show the
editor over a third of the screen with 5 px text, so it is sized like the menu window instead, to
fit the screen under the top bar, up to 0.85 of full size and never below the HUD's scale, and it is
fitted a frame later: its handlers run inside the write that fired them, and fitting needs the
thread identity raised.

The inventory is the server's: every slot lives in Inventory.slotSnapshot, numbered by revision, and
the reducer turns away the old store actions once a snapshot exists. The hotbar is laid out the way
hotbar-save-controller does it, one swap_hotbar per slot through the inventory dragging controller's
transact, which queues them, sends the revisions the server checks and retries a stale one; Clear
Hotbar is quick_move. The dispatch path stays, bounded, for a game where that controller cannot be
resolved.

transact sends the open chest with every request, and a quick_move then moves the item into that
chest, so nothing is sent while a chest is open: a sort waits for it to close while the module is
on, and at most 30 s for an On Key sort. A pass a chest stopped starts over from a fresh snapshot,
five times at most. A slot that already holds its item is never taken from, and an item comes from
the inventory before another hotbar slot. Active is cleared however a sort ends, and a change that
lands mid-sort runs it once more afterwards. ]]
run(function()
	if exec.skip('AutoHotbar') then return end
	local autoHotbar
	local mode
	local clear
	local list
	local active

	local function slotBox(obj, radius)
		obj.BackgroundColor3 = loaderStyle.Button
		obj.BackgroundTransparency = 0
		obj.BorderSizePixel = 0
		loaderStyle.corner(obj, radius or 6)
		return loaderStyle.stroke(obj, loaderStyle.ButtonBorder, 0)
	end

	local function icon(parent, name, size, glyph, isButton, props)
		local ui = slinky.libraries.ui
		local holder
		if ui and ui.icon then
			holder = ui.icon(nil, name, size, {Class = isButton and 'TextButton' or nil, Color = loaderStyle.SubText})
		else
			holder = Instance.new(isButton and 'TextButton' or 'TextLabel')
			holder.BackgroundTransparency = 1
			holder.Size = UDim2.fromOffset(size + 4, size + 4)
			holder.Text = glyph
			holder.TextSize = size
			if isButton then
				holder.AutoButtonColor = false
			end
			loaderStyle.text(holder, 'Bold', loaderStyle.SubText)
		end
		for key, value in props or {} do
			holder[key] = value
		end
		holder.Parent = parent
		return holder
	end

	local function itemIcon(id)
		if not id then return '' end
		local ok, image = pcall(bedwars.getIcon, {itemType = id}, true)
		return ok and type(image) == 'string' and image or ''
	end

	local function requestSave()
		if slinky.requestSave then
			slinky:requestSave()
		end
	end

	local function createWindow(self)
		local selectedslot = 1
		local hovered = {}
		local window = Instance.new('Frame')
		window.Name = 'HotbarGUI'
		window.Size = UDim2.fromOffset(600, 322)
		window.Position = UDim2.fromScale(0.5, 0.5)
		window.AnchorPoint = Vector2.new(0.5, 0.5)
		window.Visible = false
		window.Parent = slinky.gui.ScaledGui
		loaderStyle.box(window)
		window.BackgroundTransparency = 0.1
		local zoom = Instance.new('UIScale')
		zoom.Parent = window
		local modal = Instance.new('TextButton')
		modal.Text = ''
		modal.BackgroundTransparency = 1
		modal.Modal = true
		modal.Parent = window
		local title = Instance.new('TextLabel')
		title.Name = 'Title'
		title.Size = UDim2.new(1, -60, 0, 20)
		title.Position = UDim2.fromOffset(14, 10)
		title.BackgroundTransparency = 1
		title.Text = 'Inv Manager'
		title.TextSize = 15
		title.TextXAlignment = Enum.TextXAlignment.Left
		loaderStyle.text(title, 'SemiBold')
		title.Parent = window
		local hint = Instance.new('TextLabel')
		hint.Name = 'Hint'
		hint.Size = UDim2.new(1, -60, 0, 14)
		hint.Position = UDim2.fromOffset(14, 31)
		hint.BackgroundTransparency = 1
		hint.Text = 'Pick a slot below, then the item for it. Clear slot empties it.'
		hint.TextSize = 12
		hint.TextXAlignment = Enum.TextXAlignment.Left
		hint.TextTruncate = Enum.TextTruncate.AtEnd
		loaderStyle.text(hint, 'Medium', loaderStyle.SubText)
		hint.Parent = window
		local divider = Instance.new('Frame')
		divider.Name = 'Divider'
		divider.Size = UDim2.new(1, -28, 0, 1)
		divider.Position = UDim2.fromOffset(14, 54)
		divider.BackgroundColor3 = loaderStyle.Orange
		divider.BackgroundTransparency = 0.8
		divider.BorderSizePixel = 0
		divider.Parent = window
		local close = icon(window, 'x', 16, '\u{00D7}', true, {
			Name = 'Close',
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -10, 0, 10),
			Size = UDim2.fromOffset(26, 26)
		})
		close.MouseEnter:Connect(function()
			close.TextColor3 = loaderStyle.Text
		end)
		close.MouseLeave:Connect(function()
			close.TextColor3 = loaderStyle.SubText
		end)
		close.MouseButton1Click:Connect(function()
			window.Visible = false
			slinky.gui.ScaledGui.ClickGui.Visible = true
		end)
		local bigslot = Instance.new('Frame')
		bigslot.Name = 'Selected'
		bigslot.Size = UDim2.fromOffset(100, 100)
		bigslot.Position = UDim2.fromOffset(14, 66)
		bigslot.Parent = window
		slotBox(bigslot, 8)
		local bigimage = Instance.new('ImageLabel')
		bigimage.Size = UDim2.fromScale(0.64, 0.64)
		bigimage.Position = UDim2.fromScale(0.5, 0.5)
		bigimage.AnchorPoint = Vector2.new(0.5, 0.5)
		bigimage.BackgroundTransparency = 1
		bigimage.Image = ''
		bigimage.Parent = bigslot
		local slotnum = Instance.new('TextLabel')
		slotnum.Size = UDim2.fromOffset(100, 16)
		slotnum.Position = UDim2.fromOffset(14, 174)
		slotnum.BackgroundTransparency = 1
		slotnum.RichText = true
		slotnum.Text = 'SLOT 1'
		slotnum.TextSize = 12
		loaderStyle.text(slotnum, 'Bold', loaderStyle.SubText)
		slotnum.Parent = window
		local clear = Instance.new('TextButton')
		clear.Name = 'Clear'
		clear.Size = UDim2.fromOffset(100, 28)
		clear.Position = UDim2.fromOffset(14, 198)
		clear.Text = 'Clear slot'
		clear.TextSize = 13
		clear.AutoButtonColor = false
		loaderStyle.text(clear, 'Medium', loaderStyle.SubText)
		local clearstroke = slotBox(clear, UDim.new(1, 0))
		clear.Parent = window
		clear.MouseEnter:Connect(function()
			clearstroke.Color = loaderStyle.Orange
			clear.TextColor3 = loaderStyle.Text
		end)
		clear.MouseLeave:Connect(function()
			clearstroke.Color = loaderStyle.ButtonBorder
			clear.TextColor3 = loaderStyle.SubText
		end)

		local function paintSlot(i)
			local slot = window:FindFirstChild('Slot'..i)
			local stroke = slot and slot:FindFirstChildOfClass('UIStroke')
			if not stroke then return end
			local selected = i == selectedslot
			stroke.Color = (selected or hovered[i]) and loaderStyle.Orange or loaderStyle.ButtonBorder
			stroke.Thickness = selected and 2 or 1
			stroke.Transparency = (hovered[i] and not selected) and 0.3 or 0
		end

		local function refreshSelected()
			slotnum.Text = 'SLOT <font color="#'..loaderStyle.Orange:ToHex()..'">'..selectedslot..'</font>'
			bigimage.Image = window['Slot'..selectedslot].ImageLabel.Image
		end

		local function setSlot(i, id, image)
			local obj = self.hotbars[self.selected]
			if not obj then return end
			window['Slot'..i].ImageLabel.Image = image
			obj.Hotbar[tostring(i)] = id
			obj.Object['Slot'..i].Image = image
			if i == selectedslot then
				refreshSelected()
			end
			requestSave()
		end

		clear.MouseButton1Click:Connect(function()
			setSlot(selectedslot, nil, '')
		end)

		for i = 1, 9 do
			local slotbkg = Instance.new('TextButton')
			slotbkg.Name = 'Slot'..i
			slotbkg.Size = UDim2.fromOffset(46, 46)
			slotbkg.Position = UDim2.fromOffset(130 + (i - 1) * 51, 262)
			slotbkg.Text = ''
			slotbkg.AutoButtonColor = false
			slotBox(slotbkg)
			slotbkg.Parent = window
			local slotimage = Instance.new('ImageLabel')
			slotimage.Size = UDim2.fromOffset(30, 30)
			slotimage.Position = UDim2.fromScale(0.5, 0.5)
			slotimage.AnchorPoint = Vector2.new(0.5, 0.5)
			slotimage.BackgroundTransparency = 1
			slotimage.Image = ''
			slotimage.Parent = slotbkg
			local index = Instance.new('TextLabel')
			index.Name = 'Index'
			index.Size = UDim2.fromOffset(12, 12)
			index.Position = UDim2.fromOffset(4, 2)
			index.BackgroundTransparency = 1
			index.Text = tostring(i)
			index.TextSize = 10
			index.TextXAlignment = Enum.TextXAlignment.Left
			loaderStyle.text(index, 'SemiBold', loaderStyle.SubText)
			index.Parent = slotbkg
			paintSlot(i)
			slotbkg.MouseEnter:Connect(function()
				hovered[i] = true
				paintSlot(i)
			end)
			slotbkg.MouseLeave:Connect(function()
				hovered[i] = nil
				paintSlot(i)
			end)
			slotbkg.MouseButton1Click:Connect(function()
				local previous = selectedslot
				selectedslot = i
				paintSlot(previous)
				paintSlot(i)
				refreshSelected()
			end)
			slotbkg.MouseButton2Click:Connect(function()
				setSlot(i, nil, '')
			end)
		end
		local searchbkg = Instance.new('Frame')
		searchbkg.Name = 'Search'
		searchbkg.Size = UDim2.new(1, -142, 0, 30)
		searchbkg.Position = UDim2.fromOffset(128, 66)
		local searchstroke = slotBox(searchbkg, UDim.new(1, 0))
		searchbkg.Parent = window
		local search = Instance.new('TextBox')
		search.Size = UDim2.new(1, -46, 1, 0)
		search.Position = UDim2.fromOffset(14, 0)
		search.BackgroundTransparency = 1
		search.Text = ''
		search.PlaceholderText = 'Search items'
		search.PlaceholderColor3 = Color3.fromRGB(110, 110, 110)
		search.TextXAlignment = Enum.TextXAlignment.Left
		search.TextSize = 13
		search.ClearTextOnFocus = false
		loaderStyle.text(search, 'Medium')
		search.Parent = searchbkg
		local searchicon = icon(searchbkg, 'search', 14, '', false, {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -10, 0.5, 0)
		})
		searchicon.TextTransparency = 1
		search.Focused:Connect(function()
			searchstroke.Color = loaderStyle.Orange
		end)
		search.FocusLost:Connect(function()
			searchstroke.Color = loaderStyle.ButtonBorder
		end)
		local children = Instance.new('ScrollingFrame')
		children.Name = 'Children'
		children.Size = UDim2.new(1, -142, 0, 152)
		children.Position = UDim2.fromOffset(128, 102)
		children.BackgroundTransparency = 1
		children.BorderSizePixel = 0
		children.ScrollBarThickness = 3
		children.ScrollBarImageColor3 = loaderStyle.Orange
		children.ScrollBarImageTransparency = 0.4
		children.ScrollingDirection = Enum.ScrollingDirection.Y
		children.CanvasSize = UDim2.new()
		children.Parent = window
		local childpadding = Instance.new('UIPadding')
		childpadding.PaddingLeft = UDim.new(0, 2)
		childpadding.PaddingTop = UDim.new(0, 2)
		childpadding.Parent = children
		local windowlist = Instance.new('UIGridLayout')
		windowlist.SortOrder = Enum.SortOrder.LayoutOrder
		windowlist.FillDirectionMaxCells = 9
		windowlist.CellSize = UDim2.fromOffset(46, 46)
		windowlist.CellPadding = UDim2.fromOffset(5, 5)
		windowlist.Parent = children
		table.insert(slinky.windows, window)

		local function fit()
			local s = math.max(slinky.guiscale and slinky.guiscale.Scale or 1, 0.05)
			local camera = workspace.CurrentCamera
			local view = camera and camera.ViewportSize or Vector2.zero
			local inset = 0
			pcall(function()
				inset = guiService:GetGuiInset().Y
			end)
			local factor = 1
			if slinky.scale and slinky.scale.enabled and view.X > 0 and view.Y > 0 then
				factor = math.max(s, math.min((view.X - 16) / 600, (view.Y - inset - 16) / 322, 0.85)) / s
			end
			zoom.Scale = factor
			window.Position = UDim2.new(0.5, 0, 0.5, inset / 2 / s)
		end
		local fitQueued = false
		local function queueFit()
			if fitQueued then return end
			fitQueued = true
			task.defer(function()
				fitQueued = false
				if slinky.threadFix then
					pcall(setthreadidentity, 8)
				end
				if window.Parent then
					fit()
				end
			end)
		end
		window:GetPropertyChangedSignal('Visible'):Connect(function()
			if window.Visible then
				queueFit()
			end
		end)
		if slinky.guiscale then
			slinky.guiscale:GetPropertyChangedSignal('Scale'):Connect(queueFit)
		end
		if gameCamera then
			slinky:clean(gameCamera:GetPropertyChangedSignal('ViewportSize'):Connect(queueFit))
		end

		local function createitem(id, image)
			local slotbkg = Instance.new('TextButton')
			slotbkg.Text = ''
			slotbkg.AutoButtonColor = false
			local stroke = slotBox(slotbkg)
			slotbkg.Parent = children
			local slotimage = Instance.new('ImageLabel')
			slotimage.Size = UDim2.fromOffset(30, 30)
			slotimage.Position = UDim2.fromScale(0.5, 0.5)
			slotimage.AnchorPoint = Vector2.new(0.5, 0.5)
			slotimage.BackgroundTransparency = 1
			slotimage.Image = image
			slotimage.Parent = slotbkg
			slotbkg.MouseEnter:Connect(function()
				stroke.Color = loaderStyle.Orange
				stroke.Transparency = 0.3
			end)
			slotbkg.MouseLeave:Connect(function()
				stroke.Color = loaderStyle.ButtonBorder
				stroke.Transparency = 0
			end)
			slotbkg.MouseButton1Click:Connect(function()
				setSlot(selectedslot, id, image)
			end)
		end

		local function indexSearch(text)
			for _, v in children:GetChildren() do
				if v:IsA('TextButton') then
					v:ClearAllChildren()
					v:Destroy()
				end
			end

			local count = 0
			if text == '' then
				for _, v in {'diamond_sword', 'diamond_pickaxe', 'diamond_axe', 'shears', 'wood_bow', 'wool_white', 'fireball', 'apple', 'iron', 'gold', 'diamond', 'emerald'} do
					local meta = bedwars.ItemMeta[v]
					if meta and meta.image then
						createitem(v, meta.image)
						count += 1
					end
				end
			else
				for i, v in bedwars.ItemMeta do
					if text:lower() == i:lower():sub(1, text:len()) then
						if not v.image then continue end
						createitem(i, v.image)
						count += 1
					end
				end
			end
			local rows = math.ceil(count / 9)
			children.CanvasSize = UDim2.fromOffset(0, rows > 0 and rows * 51 - 1 or 0)
		end

		search:GetPropertyChangedSignal('Text'):Connect(function()
			indexSearch(search.Text)
		end)
		indexSearch('')

		function self:refreshWindow()
			local obj = self.hotbars[self.selected]
			for i = 1, 9 do
				window['Slot'..i].ImageLabel.Image = itemIcon(obj and obj.Hotbar[tostring(i)])
			end
			refreshSelected()
		end
		refreshSelected()

		return window
	end

	slinky.components.hotbarList = function(optionsettings, children, api)
		if slinky.threadFix then
			setthreadidentity(8)
		end
		local optionapi = {
			kind = 'hotbarList',
			hotbars = {},
			selected = 1
		}
		local hotbarlist = Instance.new('Frame')
		hotbarlist.Name = 'HotbarList'
		hotbarlist.AutomaticSize = Enum.AutomaticSize.Y
		hotbarlist.Size = UDim2.new(1, 0, 0, 0)
		hotbarlist.BackgroundTransparency = 1
		hotbarlist.LayoutOrder = optionsettings.order or 0
		hotbarlist.Parent = children
		optionapi.row = hotbarlist
		local listpadding = Instance.new('UIPadding')
		listpadding.PaddingLeft = UDim.new(0, 12)
		listpadding.PaddingRight = UDim.new(0, 12)
		listpadding.PaddingTop = UDim.new(0, 4)
		listpadding.PaddingBottom = UDim.new(0, 8)
		listpadding.Parent = hotbarlist
		local listlayout = Instance.new('UIListLayout')
		listlayout.SortOrder = Enum.SortOrder.LayoutOrder
		listlayout.Padding = UDim.new(0, 6)
		listlayout.Parent = hotbarlist
		local add = Instance.new('TextButton')
		add.Name = 'Add'
		add.LayoutOrder = 1
		add.Size = UDim2.new(1, 0, 0, 30)
		add.Text = ''
		add.AutoButtonColor = false
		local addstroke = loaderStyle.box(add, UDim.new(1, 0))
		add.Parent = hotbarlist
		local addrow = Instance.new('Frame')
		addrow.Size = UDim2.fromScale(1, 1)
		addrow.BackgroundTransparency = 1
		addrow.Parent = add
		local addlayout = Instance.new('UIListLayout')
		addlayout.FillDirection = Enum.FillDirection.Horizontal
		addlayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		addlayout.VerticalAlignment = Enum.VerticalAlignment.Center
		addlayout.SortOrder = Enum.SortOrder.LayoutOrder
		addlayout.Padding = UDim.new(0, 4)
		addlayout.Parent = addrow
		icon(addrow, 'plus', 14, '+', false, {LayoutOrder = 1, TextColor3 = loaderStyle.Orange})
		local addlabel = Instance.new('TextLabel')
		addlabel.LayoutOrder = 2
		addlabel.AutomaticSize = Enum.AutomaticSize.X
		addlabel.Size = UDim2.fromOffset(0, 18)
		addlabel.BackgroundTransparency = 1
		addlabel.Text = 'New hotbar'
		addlabel.TextSize = 14
		loaderStyle.text(addlabel, 'Medium')
		addlabel.Parent = addrow
		add.MouseEnter:Connect(function()
			addstroke.Transparency = 0.2
		end)
		add.MouseLeave:Connect(function()
			addstroke.Transparency = 0.55
		end)
		local hint = Instance.new('TextLabel')
		hint.Name = 'Hint'
		hint.LayoutOrder = 2
		hint.Size = UDim2.new(1, 0, 0, 14)
		hint.BackgroundTransparency = 1
		hint.Text = (inputService.TouchEnabled and 'Tap' or 'Click')..' a hotbar to use it, and again to edit its slots.'
		hint.TextSize = 12
		hint.TextXAlignment = Enum.TextXAlignment.Left
		hint.TextTruncate = Enum.TextTruncate.AtEnd
		hint.Visible = false
		loaderStyle.text(hint, 'Medium', loaderStyle.SubText)
		hint.Parent = hotbarlist
		local childrenlist = Instance.new('Frame')
		childrenlist.Name = 'Hotbars'
		childrenlist.LayoutOrder = 3
		childrenlist.AutomaticSize = Enum.AutomaticSize.Y
		childrenlist.Size = UDim2.new(1, 0, 0, 0)
		childrenlist.BackgroundTransparency = 1
		childrenlist.Parent = hotbarlist
		local windowlist = Instance.new('UIListLayout')
		windowlist.SortOrder = Enum.SortOrder.LayoutOrder
		windowlist.Padding = UDim.new(0, 4)
		windowlist.Parent = childrenlist
		add.MouseButton1Click:Connect(function()
			optionapi:addHotbar()
			requestSave()
		end)
		optionapi.window = createWindow(optionapi)

		function optionapi:repaint()
			for index, entry in self.hotbars do
				local selected = index == self.selected
				local object = entry.Object
				object.LayoutOrder = index
				object.BackgroundColor3 = selected and Color3.fromRGB(10, 10, 10):Lerp(loaderStyle.Orange, 0.22) or loaderStyle.Background
				local stroke = object:FindFirstChildOfClass('UIStroke')
				if stroke then
					stroke.Transparency = selected and 0 or 0.55
				end
				local active = object:FindFirstChild('Active')
				if active then
					active.Visible = selected
				end
			end
			hint.Visible = #self.hotbars > 0
		end

		function optionapi:save()
			local hotbars = {}
			for _, v in self.hotbars do
				table.insert(hotbars, table.clone(v.Hotbar))
			end
			return {
				Selected = self.selected,
				Hotbars = hotbars
			}
		end

		function optionapi:load(savetab)
			if type(savetab) ~= 'table' then return end
			for _, v in self.hotbars do
				v.Object:ClearAllChildren()
				v.Object:Destroy()
				table.clear(v.Hotbar)
			end
			table.clear(self.hotbars)
			for _, v in savetab.Hotbars or {} do
				self:addHotbar(v)
			end
			self.selected = savetab.Selected or 1
			self:repaint()
		end

		function optionapi:addHotbar(data)
			local hotbardata = {Hotbar = data or {}}
			table.insert(self.hotbars, hotbardata)
			local hotbar = Instance.new('TextButton')
			hotbar.Name = 'Hotbar'
			hotbar.Size = UDim2.new(1, 0, 0, 32)
			hotbar.Text = ''
			hotbar.AutoButtonColor = false
			loaderStyle.box(hotbar)
			hotbar.Parent = childrenlist
			hotbardata.Object = hotbar
			for i = 1, 9 do
				local slot = Instance.new('ImageLabel')
				slot.Name = 'Slot'..i
				slot.Size = UDim2.fromOffset(22, 22)
				slot.Position = UDim2.fromOffset(5 + (i - 1) * 25, 5)
				slot.BackgroundColor3 = loaderStyle.Button
				slot.BorderSizePixel = 0
				slot.Image = itemIcon(hotbardata.Hotbar[tostring(i)])
				slot.Parent = hotbar
				loaderStyle.corner(slot, 4)
			end
			local active = Instance.new('TextLabel')
			active.Name = 'Active'
			active.AnchorPoint = Vector2.new(1, 0.5)
			active.Position = UDim2.new(1, -34, 0.5, 0)
			active.Size = UDim2.fromOffset(60, 16)
			active.BackgroundTransparency = 1
			active.Text = 'IN USE'
			active.TextSize = 11
			active.TextXAlignment = Enum.TextXAlignment.Right
			active.Visible = false
			loaderStyle.text(active, 'Bold', loaderStyle.Orange)
			active.Parent = hotbar
			hotbar.MouseButton1Click:Connect(function()
				local ind = table.find(optionapi.hotbars, hotbardata)
				if ind == optionapi.selected then
					slinky.gui.ScaledGui.ClickGui.Visible = false
					optionapi.window.Visible = true
					optionapi:refreshWindow()
				elseif ind then
					optionapi.selected = ind
					optionapi:repaint()
					requestSave()
				end
			end)
			local close = icon(hotbar, 'x', 14, '\u{00D7}', true, {
				Name = 'Close',
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -6, 0.5, 0),
				Size = UDim2.fromOffset(22, 22)
			})
			close.MouseEnter:Connect(function()
				close.TextColor3 = loaderStyle.Text
			end)
			close.MouseLeave:Connect(function()
				close.TextColor3 = loaderStyle.SubText
			end)
			close.MouseButton1Click:Connect(function()
				local ind = table.find(self.hotbars, hotbardata)
				if not ind then return end
				local selected = self.hotbars[self.selected]
				hotbar:Destroy()
				table.remove(self.hotbars, ind)
				self.selected = selected and table.find(self.hotbars, selected) or 1
				self:repaint()
				requestSave()
			end)
			self:repaint()
		end

		api.options.HotbarList = optionapi

		return optionapi
	end
	
	local function getBlock()
		local clone = table.clone(store.inventory.inventory.items)
		table.sort(clone, function(a, b)
			return a.amount < b.amount
		end)
	
		for _, item in clone do
			local block = bedwars.ItemMeta[item.itemType].block
			if block and not block.seeThrough then
				return item
			end
		end
	end
	
	local function getCustomItem(v)
		if v == 'diamond_sword' then
			local sword = store.tools.sword
			v = sword and sword.itemType or 'wood_sword'
		elseif v == 'diamond_pickaxe' then
			local pickaxe = store.tools.stone
			v = pickaxe and pickaxe.itemType or 'wood_pickaxe'
		elseif v == 'diamond_axe' then
			local axe = store.tools.wood
			v = axe and axe.itemType or 'wood_axe'
		elseif v == 'wood_bow' then
			local bow = getBow()
			v = bow and bow.itemType or 'wood_bow'
		elseif v == 'wool_white' then
			local block = getBlock()
			v = block and block.itemType or 'wool_white'
		end
	
		return v
	end

	local resolvedSlots = {}
	
	local function findItemInTable(tab, item)
		for slot, v in tab do
			local resolved = resolvedSlots[slot]
			if resolved == nil then
				resolved = getCustomItem(v)
				resolvedSlots[slot] = resolved
			end
			if item.itemType == resolved then
				return tonumber(slot)
			end
		end
	end
	
	local function findInHotbar(item)
		for i, v in store.inventory.hotbar do
			if v.item and v.item.itemType == item.itemType then
				return i - 1, v.item
			end
		end
	end
	
	local function findInInventory(item)
		for _, v in store.inventory.inventory.items do
			if v.itemType == item.itemType then
				return v
			end
		end
	end

	local function dispatch(...)
		bedwars.Store:dispatch(...)
		local done = false
		local connection = slinkyEvents.InventoryChanged.Event:Once(function()
			done = true
		end)
		local deadline = os.clock() + 1
		repeat task.wait() until done or os.clock() > deadline
		connection:Disconnect()
		table.clear(resolvedSlots)
	end
	
	local function sortHotbarLegacy()
		local items = (list.hotbars[list.selected] and list.hotbars[list.selected].Hotbar or {})
		table.clear(resolvedSlots)
	
		for _, v in store.inventory.inventory.items do
			local slot = findItemInTable(items, v)
			if slot then
				local olditem = store.inventory.hotbar[slot]
				if olditem.item and olditem.item.itemType == v.itemType then continue end
				if olditem.item then
					dispatch({
						type = 'InventoryRemoveFromHotbar',
						slot = slot - 1
					})
				end
	
				local newslot = findInHotbar(v)
				if newslot then
					dispatch({
						type = 'InventoryRemoveFromHotbar',
						slot = newslot
					})
					if olditem.item then
						dispatch({
							type = 'InventoryAddToHotbar',
							item = findInInventory(olditem.item),
							slot = newslot
						})
					end
				end
	
				dispatch({
					type = 'InventoryAddToHotbar',
					item = findInInventory(v),
					slot = slot - 1
				})
			elseif clear.enabled then
				local newslot = findInHotbar(v)
				if newslot then
				   	dispatch({
						type = 'InventoryRemoveFromHotbar',
						slot = newslot
					})
				end
			end
		end
	end

	local flamework
	local function dragController()
		local ok, controller = pcall(function()
			flamework = flamework or require(replicatedStorage.rbxts_include.node_modules['@flamework'].core.out).Flamework
			return flamework.resolveDependency('client/controllers/global/inventory/inventory-dragging-controller@InventoryDraggingController')
		end)
		return ok and type(controller) == 'table' and type(controller.transact) == 'function' and controller or nil
	end

	local function slotSnapshot()
		local ok, snapshot = pcall(function()
			return bedwars.Store:getState().Inventory.slotSnapshot
		end)
		return ok and type(snapshot) == 'table' and snapshot.player and snapshot or nil
	end

	local function chestOpen(controller)
		local ok, folder = pcall(controller.getObservedChestFolder, controller)
		return ok and folder ~= nil
	end

	local function waitChestClosed(controller)
		local deadline = os.clock() + 30
		while chestOpen(controller) do
			if not autoHotbar.enabled and (mode.value ~= 'On Key' or os.clock() > deadline) then
				return false
			end
			task.wait(0.25)
		end
		return true
	end

	local function transact(controller, request)
		if chestOpen(controller) then return false end
		local ok, result = pcall(function()
			return controller:transact(request):expect()
		end)
		return ok and result == true
	end

	local function hotbarSlotAt(slots, index)
		for _, slot in slots do
			if slot.container == 'hotbar' and slot.index == index then
				return slot
			end
		end
		return nil
	end

	local function sortPass(controller)
		local snapshot = slotSnapshot()
		if not snapshot then
			pcall(function()
				controller:refresh():expect()
			end)
			snapshot = slotSnapshot()
		end
		if not snapshot then return true end

		local layout = (list.hotbars[list.selected] and list.hotbars[list.selected].Hotbar or {})
		table.clear(resolvedSlots)
		local wanted, wantedTypes = {}, {}
		for slot, itemType in layout do
			local number = tonumber(slot)
			if number and number >= 1 and number <= 9 then
				local resolved = getCustomItem(itemType)
				wanted[number - 1] = resolved
				wantedTypes[resolved] = true
			end
		end

		local settled = {}
		for index, itemType in wanted do
			local current = hotbarSlotAt(snapshot.player.slots, index)
			if current and current.itemType == itemType then
				settled[index] = true
			end
		end

		for index = 0, 8 do
			local itemType = wanted[index]
			if itemType and not settled[index] then
				if chestOpen(controller) then return false end
				snapshot = slotSnapshot() or snapshot
				local current = hotbarSlotAt(snapshot.player.slots, index)
				if current and current.itemType == itemType then
					settled[index] = true
					continue
				end
				local source
				for _, slot in snapshot.player.slots do
					if slot.itemType == itemType and (slot.container == 'inventory'
						or (slot.container == 'hotbar' and slot.index ~= index and not settled[slot.index])) then
						if not source or (slot.container == 'inventory' and source.container ~= 'inventory') then
							source = slot
						end
					end
				end
				if source and transact(controller, {
					operation = 'swap_hotbar',
					slot = {container = source.container, index = source.index},
					target = {container = 'hotbar', index = index}
				}) then
					settled[index] = true
				end
			end
		end

		if clear.enabled then
			snapshot = slotSnapshot() or snapshot
			for _, slot in table.clone(snapshot.player.slots) do
				if slot.container == 'hotbar' and not settled[slot.index] and not wantedTypes[slot.itemType] then
					if chestOpen(controller) then return false end
					transact(controller, {
						operation = 'quick_move',
						slot = {container = 'hotbar', index = slot.index}
					})
				end
			end
		end
		return true
	end

	local function sortSlots(controller)
		for _ = 1, 5 do
			if not waitChestClosed(controller) or sortPass(controller) then return end
		end
	end

	local function sortHotbar()
		local controller = dragController()
		if controller then
			sortSlots(controller)
		else
			sortHotbarLegacy()
		end
	end

	local again = false
	local function sortCallback()
		if active then
			again = true
			return
		end
		active = true
		repeat
			again = false
			pcall(sortHotbar)
		until not (again and autoHotbar.enabled)
		active = false
	end
	
	autoHotbar = inventory:module('AutoHotbar', {
		label = 'Inv Manager',
		toggled = function(on)
			if on then
				task.spawn(sortCallback)
				if mode.value == 'On Key' then
					autoHotbar:flip(nil, true)
					return
				end
	
				autoHotbar:clean(slinkyEvents.InventoryAmountChanged.Event:Connect(sortCallback))
			end
		end,
		about = 'Sorts your items into the hotbar layout you set up.\nRuns as items change or on a key, and can clear the rest.'
	})
	list = autoHotbar:hotbarList({})
	autoHotbar:divider('Extras')
	mode = autoHotbar:dropdown('Activation', {
		choices = {'Toggle', 'On Key'},
		changed = function()
			if autoHotbar.enabled then
				autoHotbar:flip(nil, true)
				autoHotbar:flip(nil, true)
			end
		end
	})
	clear = autoHotbar:toggle('Clear Hotbar')
end)
	
--[[ FastDrop
Drops the item in your hand while you hold H or Backspace, outside the inventory screen and text
boxes. A key the knitless hotbar is pressing itself, for a slot bound to it in the game's settings
(shared.PistonwareSyntheticKeys), does not count as held, or that tap would drop what is in hand. ]]
run(function()
	local fastDrop
	local function held(key)
		local synthetic = shared.PistonwareSyntheticKeys
		if type(synthetic) == 'table' and (tonumber(synthetic[key]) or 0) > os.clock() then return false end
		return inputService:IsKeyDown(key)
	end
	
	fastDrop = inventory:module('FastDrop', {
		toggled = function(on)
			if on then
				repeat
					if entitylib.isAlive and (not store.inventory.opened) and (held(Enum.KeyCode.H) or held(Enum.KeyCode.Backspace)) and inputService:GetFocusedTextBox() == nil then
						task.spawn(bedwars.ItemDropController.dropItemInHand)
						task.wait(0.1)
					else
						task.wait(0.1)
					end
				until not fastDrop.enabled
			end
		end,
		about = 'Quickly drops your held item while you hold H or Backspace.'
	})
end)
	
--[[ Bed Break Effect
Plays the bed break effect chosen in Effect whenever a bed is broken. With firesignal it fires
BedBreakEffectTriggered at the game's own listener. Without it (Solara, Xeno) it calls
onBedBreak(player, cframe, teamId, centerBedPosition) on every Knit controller of the chosen
breakBedEffectType (break-bed-effect-controller), which is all that listener does after checking the
type. ]]
run(function()
	if exec.skip('Bed Break Effect') then return end
	local bedBreakEffect
	local mode
	local list
	local nameToId = {}

	local function playBedBreakEffect(data)
		if type(data) ~= 'table' then return end
		local effectType = nameToId[list.value]
		local controllers = bedwars.Knit and bedwars.Knit.Controllers
		if effectType == nil or type(controllers) ~= 'table' or typeof(data.bedBlockPosition) ~= 'Vector3' then return end
		local position = data.bedBlockPosition * 3
		local team = data.brokenBedTeam
		local teamId = type(team) == 'table' and team.id or nil
		for _, controller in controllers do
			if type(controller) == 'table' and controller.breakBedEffectType == effectType
				and type(controller.onBedBreak) == 'function' then
				task.spawn(pcall, controller.onBedBreak, controller, data.player, CFrame.new(position), teamId, position)
			end
		end
	end

	bedBreakEffect = legit:module('Bed Break Effect', {
		toggled = function(on)
			if on and not exec.FireSignal then
				bedBreakEffect:clean(slinkyEvents.BedwarsBedBreak.Event:Connect(playBedBreakEffect))
				return
			end
			if on then
	            bedBreakEffect:clean(slinkyEvents.BedwarsBedBreak.Event:Connect(function(data)
	                firesignal(bedwars.Client:Get('BedBreakEffectTriggered').instance.OnClientEvent, {
	                    player = data.player,
	                    position = data.bedBlockPosition * 3,
	                    effectType = nameToId[list.value],
	                    teamId = data.brokenBedTeam.id,
	                    centerBedPosition = data.bedBlockPosition * 3
	                })
	            end))
	        end
		end,
		about = 'Plays an effect of your choice when a bed is broken.'
	})
	local breakEffectName = {}
	for i, v in bedwars.BedBreakEffectMeta do
		table.insert(breakEffectName, v.name)
		nameToId[v.name] = i
	end
	table.sort(breakEffectName)
	list = bedBreakEffect:dropdown('Effect', {
		choices = breakEffectName
	})
end)
	
--[[ Clean Kit
Hides the Zephyr orbs, by stubbing WindWalkerController.spawnOrb, and its WindWalkerEffect status
tile. The kit mounts that tile only once the match spawns you, after a profile has already switched
this on, so it is caught as it appears in PlayerGui. ]]
run(function()
	local cleanKit
	local oldspawnorb

	local function hideEffect(obj)
		if obj.Name == 'WindWalkerEffect' and obj:IsA('GuiObject') then
			obj.Visible = false
		end
	end

	cleanKit = legit:module('Clean Kit', {
		tab = 'Kits',
		toggled = function(on)
			local controller = bedwars.WindWalkerController
			if on then
				if controller then
					oldspawnorb = rawget(controller, 'spawnOrb')
					controller.spawnOrb = function() end
				end
				cleanKit:clean(lplr.PlayerGui.DescendantAdded:Connect(hideEffect))
				local zephyreffect = lplr.PlayerGui:FindFirstChild('WindWalkerEffect', true)
				if zephyreffect then
					hideEffect(zephyreffect)
				end
			else
				if controller then
					controller.spawnOrb = oldspawnorb
				end
				oldspawnorb = nil
				local zephyreffect = lplr.PlayerGui:FindFirstChild('WindWalkerEffect', true)
				if zephyreffect and zephyreffect:IsA('GuiObject') then
					zephyreffect.Visible = true
				end
			end
		end,
		about = 'Hides the Zephyr orbs and status indicator.'
	})
end)
	
--[[ Crosshair
Replaces your crosshair with the image id in Image. Not on knitless executors.

Without debug.setconstant (Solara, Xeno) ViewmodelController.showCrosshair is wrapped. On a computer
it hands the image to setMouseIcon, and calls made from inside it get Image instead; they are told
apart by thread, as the phone path can wait. On a phone it mounts a ScreenGui with an ImageLabel,
which is given Image after the call. ]]
run(function()
	if exec.skip('Crosshair') then return end
	if exec.Knitless then
		exec.hide('Crosshair', "needs BedWars' Knit, which this executor cannot load")
		return
	end
	local old
	local image

	local showHook, iconHook
	local showThreads = setmetatable({}, {__mode = 'k'})

	local function unwrapCrosshair()
		if showHook then
			showHook.remove()
			showHook = nil
		end
		if iconHook then
			iconHook.remove()
			iconHook = nil
		end
		table.clear(showThreads)
	end

	local function wrapCrosshair()
		unwrapCrosshair()
		local controller = bedwars.ViewmodelController
		iconHook = fieldPatch.wrap(controller, 'setMouseIcon', function(setIcon)
			return function(self, icon, ...)
				if showThreads[coroutine.running()] then
					icon = image.value
				end
				return setIcon(self, icon, ...)
			end
		end)
		showHook = fieldPatch.wrap(controller, 'showCrosshair', function(show)
			return function(self, ...)
				local playerGui = lplr:FindFirstChildOfClass('PlayerGui')
				local before = {}
				if playerGui then
					for _, child in playerGui:GetChildren() do
						before[child] = true
					end
				end
				local thread = coroutine.running()
				showThreads[thread] = (showThreads[thread] or 0) + 1
				local results = table.pack(pcall(show, self, ...))
				local depth = (showThreads[thread] or 1) - 1
				showThreads[thread] = depth > 0 and depth or nil
				if playerGui then
					for _, child in playerGui:GetChildren() do
						if not before[child] and child:IsA('ScreenGui') then
							local label = child:FindFirstChildWhichIsA('ImageLabel')
							if label then
								label.Image = image.value
							end
						end
					end
				end
				if not results[1] then error(results[2], 0) end
				return table.unpack(results, 2, results.n)
			end
		end)
	end

	local crosshair = legit:module('Crosshair', {
		toggled = function(on)
			if not fieldPatch.constants then
				if on then
					wrapCrosshair()
				else
					unwrapCrosshair()
				end
			elseif on then
				old = debug.getconstant(bedwars.ViewmodelController.showCrosshair, 25)
				debug.setconstant(bedwars.ViewmodelController.showCrosshair, 25, image.value)
				debug.setconstant(bedwars.ViewmodelController.showCrosshair, 37, image.value)
			else
				debug.setconstant(bedwars.ViewmodelController.showCrosshair, 25, old)
				debug.setconstant(bedwars.ViewmodelController.showCrosshair, 37, old)
				old = nil
			end

			if bedwars.ViewmodelController.crosshair then
				bedwars.ViewmodelController:hideCrosshair()
				bedwars.ViewmodelController:showCrosshair()
			end
		end,
		about = 'Replaces your crosshair with an image of your choice.'
	})
	image = crosshair:textbox('Image', {
		placeholder = 'image id (roblox)',
		changed = function(enter)
			if enter and crosshair.enabled then
				crosshair:flip(nil, true)
				crosshair:flip(nil, true)
			end
		end
	})
end)
	
--[[ Damage Indicator
Restyles the damage numbers that pop up on hits: font, colour, size, outline and how long they stay
anchored, with no blow-up. With the debug library it writes the controller's constant table (upvalue
2 of bedwars.DamageIndicator) and the font and stroke constants of spawnDamageIndicator.

Without it (Solara, Xeno): that table is ConstantManager.registerConstants(script, {...})
(damage-indicator-controller), and ConstantManager copies every key in it from the attribute
ConstantManager_<key> on the controller's ModuleScript whenever that attribute changes, so the
sizes, timings, colour and outline width go through those attributes and their old values are put
back on disable. The font and switching the outline off are set on each indicator's TextLabel and
UIStroke as its part reaches workspace. ]]
run(function()
	local damageIndicator
	local fontOption
	local color
	local size
	local anchor
	local strokeToggle
	local suc, tab = pcall(function()
		return debug.getupvalue(bedwars.DamageIndicator, 2)
	end)
	tab = suc and tab or {}
	local oldvalues, oldfont = {}

	local viaDebug = fieldPatch.constants
	local attributeHost
	local savedAttributes = {}
	local attributeKeys = {'strokeThickness', 'textSize', 'blowUpSize', 'blowUpDuration', 'baseColor',
		'blowUpCompleteDuration', 'anchoredDuration'}

	local function setConstant(key, value)
		if viaDebug or not attributeHost then return end
		pcall(attributeHost.SetAttribute, attributeHost, 'ConstantManager_'..key, value)
	end

	local function restyle(part)
		if not (damageIndicator.enabled and part.Name == 'DamageIndicatorPart') then return end
		local gui = part:FindFirstChildWhichIsA('BillboardGui')
		local frame = gui and gui:FindFirstChildWhichIsA('Frame')
		local label = frame and frame:FindFirstChildWhichIsA('TextLabel')
		if not label then return end
		pcall(function()
			label.Font = Enum.Font[fontOption.value]
		end)
		local stroke = label:FindFirstChildWhichIsA('UIStroke')
		if stroke and not strokeToggle.enabled then
			stroke.Enabled = false
		end
	end

	local function applyAttributes(callback)
		if callback then
			if not attributeHost then
				pcall(function()
					attributeHost = lplr.PlayerScripts.TS.controllers.global.damage['damage-indicator-controller']
				end)
			end
			table.clear(savedAttributes)
			if attributeHost then
				for _, key in attributeKeys do
					local ok, value = pcall(attributeHost.GetAttribute, attributeHost, 'ConstantManager_'..key)
					if ok and value ~= nil then
						savedAttributes[key] = value
					end
				end
			end
			setConstant('strokeThickness', strokeToggle.enabled and 1 or 0)
			setConstant('textSize', size.value)
			setConstant('blowUpSize', size.value)
			setConstant('blowUpDuration', 0)
			setConstant('baseColor', Color3.fromHSV(color.hue, color.sat, color.value))
			setConstant('blowUpCompleteDuration', 0)
			setConstant('anchoredDuration', anchor.value)
			damageIndicator:clean(workspace.ChildAdded:Connect(restyle))
		else
			for key, value in savedAttributes do
				setConstant(key, value)
			end
			table.clear(savedAttributes)
		end
	end

	damageIndicator = legit:module('Damage Indicator', {
		toggled = function(on)
			if not viaDebug then
				applyAttributes(on)
			elseif on then
				oldvalues = table.clone(tab)
				oldfont = debug.getconstant(bedwars.DamageIndicator, 86)
				debug.setconstant(bedwars.DamageIndicator, 86, Enum.Font[fontOption.value])
				debug.setconstant(bedwars.DamageIndicator, 119, strokeToggle.enabled and 'Thickness' or 'Enabled')
				tab.strokeThickness = strokeToggle.enabled and 1 or false
				tab.textSize = size.value
				tab.blowUpSize = size.value
				tab.blowUpDuration = 0
				tab.baseColor = Color3.fromHSV(color.hue, color.sat, color.value)
				tab.blowUpCompleteDuration = 0
				tab.anchoredDuration = anchor.value
			else
				for i, v in oldvalues do
					tab[i] = v
				end
				debug.setconstant(bedwars.DamageIndicator, 86, oldfont)
				debug.setconstant(bedwars.DamageIndicator, 119, 'Thickness')
			end
		end,
		about = 'Restyles the damage numbers that pop up on hits.\nSet the font, color, size, outline and how long they stay.'
	})
	local fontitems = {'GothamBlack'}
	for _, v in Enum.Font:GetEnumItems() do
		if v.Name ~= 'GothamBlack' then
			table.insert(fontitems, v.Name)
		end
	end
	fontOption = damageIndicator:dropdown('Font', {
		choices = fontitems,
		changed = function(val)
			if damageIndicator.enabled and viaDebug then
				debug.setconstant(bedwars.DamageIndicator, 86, Enum.Font[val])
			end
		end
	})
	color = damageIndicator:color('Color', {
		hue = 0,
		changed = function(hue, sat, val)
			if damageIndicator.enabled then
				tab.baseColor = Color3.fromHSV(hue, sat, val)
				setConstant('baseColor', Color3.fromHSV(hue, sat, val))
			end
		end
	})
	size = damageIndicator:slider('Size', {
		min = 1,
		max = 32,
		default = 32,
		changed = function(val)
			if damageIndicator.enabled then
				tab.textSize = val
				tab.blowUpSize = val
				setConstant('textSize', val)
				setConstant('blowUpSize', val)
			end
		end
	})
	anchor = damageIndicator:slider('Anchor', {
		min = 0,
		max = 1,
		decimal = 10,
		changed = function(val)
			if damageIndicator.enabled then
				tab.anchoredDuration = val
				setConstant('anchoredDuration', val)
			end
		end
	})
	strokeToggle = damageIndicator:toggle('Stroke', {
		changed = function(callback)
			if damageIndicator.enabled then
				if viaDebug then
					debug.setconstant(bedwars.DamageIndicator, 119, callback and 'Thickness' or 'Enabled')
					tab.strokeThickness = callback and 1 or false
				else
					setConstant('strokeThickness', callback and 1 or 0)
				end
			end
		end
	})
end)
	
--[[ FOV
Changes how wide your camera can see. Set any field of view from 30 to 120. ]]
run(function()
	local fov
	local amount
	local old, old2
	
	fov = legit:module('FOV', {
		toggled = function(on)
			if on then
				old = bedwars.FovController.setFOV
				old2 = bedwars.FovController.getFOV
				bedwars.FovController.setFOV = function(self) 
					return old(self, amount.value) 
				end
				bedwars.FovController.getFOV = function() 
					return amount.value 
				end
			else
				bedwars.FovController.setFOV = old
				bedwars.FovController.getFOV = old2
			end
			
			bedwars.FovController:setFOV(bedwars.Store:getState().Settings.fov)
		end,
		about = 'Changes how wide your camera can see.\nSet any field of view from 30 to 120.'
	})
	amount = fov:slider('FOV', {
		min = 30,
		max = 120
	})
end)
	
--[[ FPS Boost
Raises the frame rate by stubbing the kill effects (all but the Custom ones) and the visualizer, and
with Hide Nametags by hiding the game's nametags. The nametag hiding is shared with NameTags and
ref-counted there (hideGameNametags). It waits for the match to start and checks both toggles again
after the wait, so turning either off in the lobby cancels it. Hide Nametags drives its own state
instead of restarting the module like the other two options, because the module's enable path waits
through the whole lobby. ]]
run(function()
	local fpsBoost
	local kill
	local visualizer
	local nametags
	local effects, util = {}, {}

	local function removeGameNametags()
		hideGameNametags('fpsboost')
	end

	local function restoreGameNametags()
		showGameNametags('fpsboost')
	end

	fpsBoost = legit:module('FPS Boost', {
		toggled = function(on)
			if on then
				if kill.enabled then
					for i, v in bedwars.KillEffectController.killEffects do
						if not i:find('Custom') then
							effects[i] = v
							bedwars.KillEffectController.killEffects[i] = {
								new = function() 
									return {
										onKill = function() end, 
										isPlayDefaultKillEffect = function() 
											return true 
										end
									} 
								end
							}
						end
					end
				end
	
				if visualizer.enabled then
					for i, v in bedwars.VisualizerUtils do
						util[i] = v
						bedwars.VisualizerUtils[i] = function() end
					end
				end
	
				if nametags.enabled then
					repeat task.wait(0.1) until store.matchState ~= 0 or not (fpsBoost.enabled and nametags.enabled)
					if fpsBoost.enabled and nametags.enabled then
						removeGameNametags()
					end
				end
			else
				for i, v in effects do 
					bedwars.KillEffectController.killEffects[i] = v 
				end
				for i, v in util do 
					bedwars.VisualizerUtils[i] = v 
				end
				table.clear(effects)
				table.clear(util)
				restoreGameNametags()
			end
		end,
		about = 'Turns off heavy effects to raise your frame rate.\nCan remove kill effects, the visualizer and game nametags.'
	})
	kill = fpsBoost:toggle('Kill Effects', {
		visible = not exec.skip('FPS Boost/Kill Effects'),
		changed = function()
			if fpsBoost.enabled then
				fpsBoost:flip(nil, true)
				fpsBoost:flip(nil, true)
			end
		end,
		default = true
	})
	visualizer = fpsBoost:toggle('Visualizer', {
		visible = not exec.skip('FPS Boost/Visualizer'),
		changed = function()
			if fpsBoost.enabled then
				fpsBoost:flip(nil, true)
				fpsBoost:flip(nil, true)
			end
		end,
		default = true
	})
	nametags = fpsBoost:toggle('Hide Nametags', {
		changed = function(callback)
			if not fpsBoost.enabled then return end
			if callback then
				task.spawn(function()
					repeat task.wait(0.1) until store.matchState ~= 0 or not (fpsBoost.enabled and nametags.enabled)
					if fpsBoost.enabled and nametags.enabled then
						removeGameNametags()
					end
				end)
			else
				restoreGameNametags()
			end
		end,
		about = 'Hides the game nametag over everyone, teammates too.\nTurn it back off and they come back, no rejoin needed.'
	})
end)
	
--[[ Hit Color
Recolors the _DamageHighlight_ the game puts on a player who is hit. Off, every highlight it touched
gets the game's red back; they are held with weak keys, so a destroyed one is not kept. ]]
run(function()
	local hitColor
	local color
	local done = setmetatable({}, {__mode = 'k'})
	
	hitColor = legit:module('Hit Color', {
		toggled = function(on)
			if on then
				repeat
					local fill = Color3.fromHSV(color.hue, color.sat, color.value)
					local trans = color.opacity
					for _, v in entitylib.List do
						local highlight = v.Character and v.Character:FindFirstChild('_DamageHighlight_')
						if highlight then
							done[highlight] = true
							highlight.FillColor = fill
							highlight.FillTransparency = trans
						end
					end
					task.wait(0.1)
				until not hitColor.enabled
			else
				for v in next, done do
					v.FillColor = Color3.new(1, 0, 0)
					v.FillTransparency = 0.4
				end
				table.clear(done)
			end
		end,
		about = 'Recolors the red highlight players get when hit.\nPick its color and how see-through it is.'
	})
	color = hitColor:color('Color', {
		opacity = 0.4
	})
end)
	
--[[ HitFix
Makes sword hits land more reliably: swingSwordAtMouse's mouse ray goes through
GameQueryUtil:raycast instead of workspace:Raycast, and the one difference is that GameQueryUtil
skips parts with the attribute gamecore_GameQueryIgnore (game-query-util). Not on knitless
executors.

Without the debug library (Solara, Xeno) those parts are taken out of every ray instead: while
HitFix is on, each marked part that does not collide gets CanQuery = false, which Roblox allows only
on non-colliding parts, and gets it back when HitFix goes off. A part the game marks right after
adding it is checked once more through task.defer. ]]
run(function()
	if exec.skip('HitFix') then return end
	if exec.Knitless then
		exec.hide('HitFix', "needs BedWars' Knit, which this executor cannot load")
		return
	end
	local hitFix

	local IGNORE_ATTRIBUTE = 'gamecore_GameQueryIgnore'
	local unqueried = setmetatable({}, {__mode = 'k'})

	local function skipQuery(part)
		if unqueried[part] or not part:IsA('BasePart') then return end
		if part:GetAttribute(IGNORE_ATTRIBUTE) == true and part.CanQuery and not part.CanCollide then
			part.CanQuery = false
			unqueried[part] = true
		end
	end

	local function restoreQuery()
		for part in unqueried do
			pcall(function()
				part.CanQuery = true
			end)
		end
		table.clear(unqueried)
	end

	hitFix = legit:module('HitFix', {
		tab = 'Combat',
		toggled = function(on)
			if fieldPatch.constants then
				debug.setconstant(bedwars.SwordController.swingSwordAtMouse, 23, on and 'raycast' or 'Raycast')
				debug.setupvalue(bedwars.SwordController.swingSwordAtMouse, 4, on and bedwars.QueryUtil or workspace)
				return
			end
			if not on then
				restoreQuery()
				return
			end
			hitFix:clean(workspace.DescendantAdded:Connect(function(object)
				if not object:IsA('BasePart') then return end
				skipQuery(object)
				if not unqueried[object] then
					task.defer(function()
						if hitFix.enabled and object.Parent then
							skipQuery(object)
						end
					end)
				end
			end))
			for _, object in workspace:GetDescendants() do
				skipQuery(object)
			end
		end,
		about = 'Makes your sword hits land more reliably.'
	})
end)
	
--[[ Interface
Restyles the BedWars hotbar and health bar: the health font and colour, and the hotbar tiles' colour
and transparency. With the debug library it changes constants of the hotbar components' render
functions. Not on knitless executors.

Without the debug library (Solara, Xeno) HotbarApp's render, the way to HotbarTile, cannot be
reached, so while Interface is on HotbarHealthbar, HotbarTile and HotbarOpenInventory have their
render wrapped and each wrapper changes the props those constants feed (hotbar-healthbar,
hotbar-tile, hotbar-open-inventory): the health font LuckiestGuy, the health colour 0xCB3624, the
tile colours 0x1D242E and 0x727FAC and the tile transparencies 0.2 (selected) and 0.4. Only the
plain bar colour is that constant; the decay and event colours stay. Either way a change shows from
the component's next render, and only the options that were set are applied. ]]
run(function()
	if exec.skip('Interface') then return end
	if exec.Knitless then
		exec.hide('Interface', "needs BedWars' Knit, which this executor cannot load")
		return
	end
	local interface
	local hotbarOpenInventory = require(lplr.PlayerScripts.TS.controllers.global.hotbar.ui['hotbar-open-inventory']).HotbarOpenInventory
	local hotbarHealthbar = require(lplr.PlayerScripts.TS.controllers.global.hotbar.ui.healthbar['hotbar-healthbar']).HotbarHealthbar
	local hotbarApp = fieldPatch.constants and getRoactRender(require(lplr.PlayerScripts.TS.controllers.global.hotbar.ui['hotbar-app']).HotbarApp.render) or nil
	local old, new = {}, {}

	local styles = {}
	local renderHooks = {}
	local hotbarTile
	if not fieldPatch.constants then
		pcall(function()
			hotbarTile = require(lplr.PlayerScripts.TS.controllers.global.hotbar.ui['hotbar-tile']).HotbarTile
		end)
	end

	local function styleHealthbar(_, element)
		local container = type(element) == 'table' and type(element.elements) == 'table'
			and element.elements.HotbarHealthbarContainer or nil
		local children = fieldPatch.children(container)
		if not children then return end
		local label = fieldPatch.child(children, 'TextLabel')
		if label and styles.healthFont then
			label.props.Font = styles.healthFont
		end
		local bars = fieldPatch.children(children.HealthbarProgressWrapper)
		local bar = bars and bars[1]
		local props = type(bar) == 'table' and bar.props
		if styles.healthColor and type(props) == 'table' and typeof(props.BackgroundColor3) == 'Color3'
			and props.BackgroundColor3:ToHex():lower() == 'cb3624' then
			props.BackgroundColor3 = styles.healthColor
		end
	end

	local function styleButton(button, selected)
		local props = button.props
		if not styles.tileColor then return end
		props.BackgroundColor3 = styles.tileColor
		props.BackgroundTransparency = selected and styles.selectedTransparency or styles.tileTransparency
		if not selected then
			props.BorderColor3 = styles.tileShade
			local keybind = fieldPatch.child(fieldPatch.children(button), 'TextLabel')
			if keybind then
				keybind.props.BackgroundColor3 = styles.tileShade
			end
		end
	end

	local function styleTile(self, element)
		local button = fieldPatch.child(fieldPatch.children(element), 'ImageButton')
		if button then
			styleButton(button, type(self.props) == 'table' and self.props.Selected == true)
		end
	end

	local function styleOpenInventory(_, element)
		local button = fieldPatch.child(fieldPatch.children(element), 'ImageButton')
		if button then
			styleButton(button, false)
		end
	end

	local function setRenderHooks(enabled)
		for _, hook in renderHooks do
			hook.remove()
		end
		table.clear(renderHooks)
		if not enabled then return end
		for _, pair in {{hotbarHealthbar, styleHealthbar}, {hotbarOpenInventory, styleOpenInventory}, {hotbarTile, styleTile}} do
			local hook = pair[1] ~= nil and fieldPatch.render(pair[1], pair[2]) or nil
			if hook then
				table.insert(renderHooks, hook)
			end
		end
	end

	slinky:clean(function()
		for _, v in new do
			table.clear(v)
		end
		for _, v in old do
			table.clear(v)
		end
		table.clear(new)
		table.clear(old)
	end)
	
	local function modifyconstant(func, ind, val)
		if not func then return end
		if not old[func] then old[func] = {} end
		if not new[func] then new[func] = {} end
		if not old[func][ind] then
			old[func][ind] = debug.getconstant(func, ind)
		end
		if typeof(old[func][ind]) ~= typeof(val) then return end
		new[func][ind] = val
	
		if interface.enabled then
			if val then
				debug.setconstant(func, ind, val)
			else
				debug.setconstant(func, ind, old[func][ind])
				old[func][ind] = nil
			end
		end
	end
	
	interface = legit:module('Interface', {
		toggled = function(on)
			if not fieldPatch.constants then
				setRenderHooks(on)
				return
			end
			for i, v in (on and new or old) do
				for i2, v2 in v do
					debug.setconstant(i, i2, v2)
				end
			end
		end,
		about = 'Restyles the BedWars hotbar and health bar.\nPick the health font and colors for both.'
	})
	local fontitems = {'LuckiestGuy'}
	for _, v in Enum.Font:GetEnumItems() do
		if v.Name ~= 'LuckiestGuy' then
			table.insert(fontitems, v.Name)
		end
	end
	interface:dropdown('Health Font', {
		choices = fontitems,
		changed = function(val)
			if not fieldPatch.constants then
				styles.healthFont = val
				return
			end
			modifyconstant(hotbarHealthbar.render, 77, val)
		end
	})
	interface:color('Health Color', {
		changed = function(hue, sat, val)
			if fieldPatch.constants then
				modifyconstant(hotbarHealthbar.render, 16, tonumber(Color3.fromHSV(hue, sat, val):ToHex(), 16))
			else
				styles.healthColor = Color3.fromHSV(hue, sat, val)
			end
			if interface.enabled then
				local hotbar = lplr.PlayerGui:FindFirstChild('hotbar')
				hotbar = hotbar and hotbar:FindFirstChild('HealthbarProgressWrapper', true)
				if hotbar then
					hotbar['1'].BackgroundColor3 = Color3.fromHSV(hue, sat, val)
				end
			end
		end
	})
	interface:color('Hotbar Color', {
		opacity = 0.8,
		changed = function(hue, sat, val, opacity)
			if not fieldPatch.constants then
				styles.tileColor = Color3.fromHSV(hue, sat, val)
				styles.tileShade = Color3.fromHSV(hue, sat, math.clamp(val > 0.5 and val - 0.2 or val + 0.2, 0, 1))
				local alpha = tonumber(opacity) or 0.8
				styles.selectedTransparency = 1 - alpha
				styles.tileTransparency = math.clamp(1.2 - alpha, 0, 1)
				return
			end
			local func = oldinvrender or hotbarOpenInventory.render
			modifyconstant(debug.getupvalue(hotbarApp, 23).render, 51, tonumber(Color3.fromHSV(hue, sat, val):ToHex(), 16))
			modifyconstant(debug.getupvalue(hotbarApp, 23).render, 58, tonumber(Color3.fromHSV(hue, sat, math.clamp(val > 0.5 and val - 0.2 or val + 0.2, 0, 1)):ToHex(), 16))
			modifyconstant(debug.getupvalue(hotbarApp, 23).render, 54, 1 - opacity)
			modifyconstant(debug.getupvalue(hotbarApp, 23).render, 55, math.clamp(1.2 - opacity, 0, 1))
			modifyconstant(func, 31, tonumber(Color3.fromHSV(hue, sat, val):ToHex(), 16))
			modifyconstant(func, 32, math.clamp(1.2 - opacity, 0, 1))
			modifyconstant(func, 34, tonumber(Color3.fromHSV(hue, sat, math.clamp(val > 0.5 and val - 0.2 or val + 0.2, 0, 1)):ToHex(), 16))
		end
	})
end)
	
--[[ Kill Effect
Plays your chosen effect when you get a final kill. Use any BedWars effect or Gravity, Lightning or
Delete. ]]
run(function()
	local killEffect
	local mode
	local list
	local nameToId = {}
	
	local killeffects = {
		Gravity = function(_, _, char, _)
			char:BreakJoints()
			local highlight = char:FindFirstChildWhichIsA('Highlight')
			local nametag = char:FindFirstChild('Nametag', true)
			if highlight then
				highlight:Destroy()
			end
			if nametag then
				nametag:Destroy()
			end
	
			task.spawn(function()
				local partvelo = {}
				for _, v in char:GetDescendants() do
					if v:IsA('BasePart') then
						partvelo[v.Name] = v.Velocity
					end
				end
				char.Archivable = true
				local clone = char:Clone()
				clone.Humanoid.Health = 100
				clone.Parent = workspace
				game:GetService('Debris'):AddItem(clone, 30)
				char:Destroy()
				task.wait(0.01)
				clone.Humanoid:ChangeState(Enum.HumanoidStateType.Dead)
				clone:BreakJoints()
				task.wait(0.01)
				for _, v in clone:GetDescendants() do
					if v:IsA('BasePart') then
						local bodyforce = Instance.new('BodyForce')
						bodyforce.Force = Vector3.new(0, (workspace.Gravity - 10) * v:GetMass(), 0)
						bodyforce.Parent = v
						v.CanCollide = true
						v.Velocity = partvelo[v.Name] or Vector3.zero
					end
				end
			end)
		end,
		Lightning = function(_, _, char, _)
			char:BreakJoints()
			local highlight = char:FindFirstChildWhichIsA('Highlight')
			if highlight then
				highlight:Destroy()
			end
			local startpos = 1125
			local startcf = char.PrimaryPart.CFrame.p - Vector3.new(0, 8, 0)
			local newpos = Vector3.new((math.random(1, 10) - 5) * 2, startpos, (math.random(1, 10) - 5) * 2)
	
			for i = startpos - 75, 0, -75 do
				local newpos2 = Vector3.new((math.random(1, 10) - 5) * 2, i, (math.random(1, 10) - 5) * 2)
				if i == 0 then
					newpos2 = Vector3.zero
				end
				local part = Instance.new('Part')
				part.Size = Vector3.new(1.5, 1.5, 77)
				part.Material = Enum.Material.SmoothPlastic
				part.Anchored = true
				part.Material = Enum.Material.Neon
				part.CanCollide = false
				part.CFrame = CFrame.new(startcf + newpos + ((newpos2 - newpos) * 0.5), startcf + newpos2)
				part.Parent = workspace
				local part2 = part:Clone()
				part2.Size = Vector3.new(3, 3, 78)
				part2.Color = Color3.new(0.7, 0.7, 0.7)
				part2.Transparency = 0.7
				part2.Material = Enum.Material.SmoothPlastic
				part2.Parent = workspace
				game:GetService('Debris'):AddItem(part, 0.5)
				game:GetService('Debris'):AddItem(part2, 0.5)
				bedwars.QueryUtil:setQueryIgnored(part, true)
				bedwars.QueryUtil:setQueryIgnored(part2, true)
				if i == 0 then
					local soundpart = Instance.new('Part')
					soundpart.Transparency = 1
					soundpart.Anchored = true
					soundpart.Size = Vector3.zero
					soundpart.Position = startcf
					soundpart.Parent = workspace
					bedwars.QueryUtil:setQueryIgnored(soundpart, true)
					local sound = Instance.new('Sound')
					sound.SoundId = 'rbxassetid://6993372814'
					sound.Volume = 2
					sound.Pitch = 0.5 + (math.random(1, 3) / 10)
					sound.Parent = soundpart
					sound:Play()
					sound.Ended:Connect(function()
						soundpart:Destroy()
					end)
				end
				newpos = newpos2
			end
		end,
		Delete = function(_, _, char, _)
			char:Destroy()
		end
	}
	
	killEffect = legit:module('Kill Effect', {
		toggled = function(on)
			if on then
				for i, v in killeffects do
					bedwars.KillEffectController.killEffects['Custom'..i] = {
						new = function()
							return {
								onKill = v,
								isPlayDefaultKillEffect = function()
									return false
								end
							}
						end
					}
				end
				killEffect:clean(lplr:GetAttributeChangedSignal('KillEffectType'):Connect(function()
					lplr:SetAttribute('KillEffectType', mode.value == 'Bedwars' and nameToId[list.value] or 'Custom'..mode.value)
				end))
				lplr:SetAttribute('KillEffectType', mode.value == 'Bedwars' and nameToId[list.value] or 'Custom'..mode.value)
			else
				for i in killeffects do
					bedwars.KillEffectController.killEffects['Custom'..i] = nil
				end
				lplr:SetAttribute('KillEffectType', 'default')
			end
		end,
		about = 'Plays your chosen effect when you get a final kill.\nUse any BedWars effect or Gravity, Lightning or Delete.'
	})
	local modes = {'Bedwars'}
	for i in killeffects do
		table.insert(modes, i)
	end
	mode = killEffect:dropdown('Mode', {
		choices = modes,
		changed = function(val)
			list.row.Visible = val == 'Bedwars'
			if killEffect.enabled then
				lplr:SetAttribute('KillEffectType', val == 'Bedwars' and nameToId[list.value] or 'Custom'..val)
			end
		end
	})
	local killEffectName = {}
	for i, v in bedwars.KillEffectMeta do
		table.insert(killEffectName, v.name)
		nameToId[v.name] = i
	end
	table.sort(killEffectName)
	list = killEffect:dropdown('Bedwars', {
		choices = killEffectName,
		changed = function(val)
			if killEffect.enabled then
				lplr:SetAttribute('KillEffectType', nameToId[val])
			end
		end,
		sub = true
	})
end)
	
--[[ Reach Display
Shows the distance of your last hit, in studs, on a card. The Font option stays for the profiles
that save it; the card always uses the menu's Inter, as the other widgets do. ]]
run(function()
	local reachDisplay
	local label

	local function unit(value)
		return tostring(value)..' <font color="'..loaderStyle.Card.SubHex..'">studs</font>'
	end

	reachDisplay = legit:module('Reach Display', {
		toggled = function(on)
			if on then
				repeat
					label.Text = unit(store.attackReachUpdate > os.clock() and store.attackReach or '0.00')
					task.wait(0.4)
				until not reachDisplay.enabled
			end
		end,
		size = UDim2.fromOffset(100, 41),
		about = 'Shows the distance of your last hit.'
	})
	reachDisplay:font('Font', {
		exclude = 'Gotham',
		changed = function()
			if label then
				loaderStyle.text(label, 'SemiBold', loaderStyle.Card.Text)
			end
		end
	})
	reachDisplay:color('Color', {
		hue = loaderStyle.Card.Hue,
		sat = loaderStyle.Card.Sat,
		value = loaderStyle.Card.Value,
		opacity = 1 - loaderStyle.Card.Transparency,
		changed = function(hue, sat, val, opacity)
			local colour, alpha = loaderStyle.cardColor(hue, sat, val, opacity)
			label.BackgroundColor3 = colour
			label.BackgroundTransparency = 1 - alpha
		end
	})
	label = Instance.new('TextLabel')
	label.Size = UDim2.fromScale(1, 1)
	loaderStyle.card(label)
	label.RichText = true
	label.TextSize = 15
	label.Text = unit('0.00')
	loaderStyle.text(label, 'SemiBold', loaderStyle.Card.Text)
	label.Parent = reachDisplay.frame
end)
	
--[[ Song Beats
Plays your own music files while you play. Can pulse your FOV to the beat; set the volume and pulse
size. ]]
run(function()
	local songBeats
	local list
	local fov
	local fovValue = {}
	local volume
	local alreadypicked = {}
	local beattick = os.clock()
	local oldfov, songobj, songbpm, songtween
	
	local function choosesong()
		local list = list.active
		if #alreadypicked >= #list then 
			table.clear(alreadypicked) 
		end
	
		if #list <= 0 then
			notif('SongBeats', 'no songs', 10)
			songBeats:flip()
			return
		end
	
		local chosensong = list[math.random(1, #list)]
		if #list > 1 and table.find(alreadypicked, chosensong) then
			repeat 
				task.wait(0.1) 
				chosensong = list[math.random(1, #list)] 
			until not table.find(alreadypicked, chosensong) or not songBeats.enabled
		end
		if not songBeats.enabled then return end
	
		local split = chosensong:split('/')
		if not isfile(split[1]) then
			notif('SongBeats', 'Missing song ('..split[1]..')', 10)
			songBeats:flip()
			return
		end
	
		songobj.SoundId = assetfunction(split[1])
		repeat task.wait(0.1) until songobj.IsLoaded or not songBeats.enabled
		if songBeats.enabled then
			beattick = os.clock() + (tonumber(split[3]) or 0)
			songbpm = 60 / (tonumber(split[2]) or 50)
			songobj:Play()
		end
	end
	
	songBeats = legit:module('Song Beats', {
		tab = 'Utility',
		toggled = function(on)
			if on then
				songobj = Instance.new('Sound')
				songobj.Volume = volume.value / 100
				songobj.Parent = workspace
				repeat
					if not songobj.Playing then choosesong() end
					if beattick < os.clock() and songBeats.enabled and fov.enabled then
						beattick = os.clock() + songbpm
						oldfov = math.min(bedwars.FovController:getFOV() * (bedwars.SprintController.sprinting and 1.1 or 1), 120)
						gameCamera.FieldOfView = oldfov - fovValue.value
						songtween = tweenService:Create(gameCamera, TweenInfo.new(math.min(songbpm, 0.2), Enum.EasingStyle.Linear), {FieldOfView = oldfov})
						songtween:Play()
					end
					task.wait(0.1)
				until not songBeats.enabled
			else
				if songobj then
					songobj:Destroy()
				end
				if songtween then
					songtween:Cancel()
				end
				if oldfov then
					gameCamera.FieldOfView = oldfov
				end
				table.clear(alreadypicked)
			end
		end,
		about = 'Plays your own music files while you play.\nCan pulse your FOV to the beat; set the volume and pulse size.'
	})
	list = songBeats:list('Songs', {
		placeholder = 'filepath/bpm/start'
	})
	volume = songBeats:slider('Volume', {
		changed = function(val)
			if songobj then 
				songobj.Volume = val / 100 
			end
		end,
		min = 1,
		max = 100,
		default = 100,
		suffix = function(val) return '%' end
	})
	fov = songBeats:toggle('Beat FOV', {
		changed = function(callback)
			if fovValue.row then
				fovValue.row.Visible = callback
			end
			if songBeats.enabled then
				songBeats:flip(nil, true)
				songBeats:flip(nil, true)
			end
		end,
		default = true
	})
	fovValue = songBeats:slider('Adjustment', {
		min = 1,
		max = 30,
		default = 5,
		sub = true
	})
end)

--[[ SoundChanger
Replaces listed game sounds and scales their volume; Hit ding only mutes every projectile switch,
draw, reload and fire sound and keeps the ding when your shot lands. Hit ding only wins over the
list.

The game plays every sound through AudioManager, whose playAudio, playRandomAudio and
playAudioPlayer all end in internalPlayAudio(asset, config), so that one hook sees them all. Muting
sets the config's volumeMultiplier to 0 rather than skipping the call, because callers keep the
playback handle it returns (the equip sound stops the previous one through it). Only string ids are
touched: a multiplier on a caller's own AudioPlayer would stick to that instance. A custom sound
takes the category and bus of the id it replaces. bedwars.SoundManager is hooked only when it is a
real one; resolveSoundManager's stand-in forwards to AudioManager, and hooking it too would scale a
listed sound twice.

The projectile sounds are read from the metas the game's controllers use, so bow skins
(projectileSourceOverrides) are covered: EQUIP_BOW, chargeBeginSound, reload.reloadSound,
launchSound and launchOverlaySound, and with Mute impacts the impactSound of arrow projectiles.
Their hitSounds, ARROW_HIT, HEADSHOT, every SWING sound and any id a meta holds outside its
projectile source stay audible: throwables such as the banana peel launch with SWORD_SWING_1, and
the other projectiles' impacts share FORTIFY_BLOCK, TNT_EXPLODE_1 and FIREBALL_EXPLODE with blocks
and TNT. ]]
run(function()
	if exec.skip('SoundChanger') then return end
	local soundChanger
	local list
	local volume
	local hitOnly
	local muteImpacts
	local trackedSounds = {}
	local customSounds = {}
	local capturedRegistry = {}
	local projectileSounds = {}
	local old, oldRegister, oldAudio, audioMethod

	local function soundMultiplier(id)
		if hitOnly and hitOnly.enabled and projectileSounds[id] then
			return 0
		end
		if trackedSounds[id] then
			return (volume and volume.value or 100) / 100
		end
	end

	local function addSounds(set, value)
		if type(value) == 'string' then
			if value ~= '' then
				set[value] = true
			end
		elseif type(value) == 'table' then
			for _, v in value do
				addSounds(set, v)
			end
		end
	end

	local function addShared(set, value, skipKey, seen)
		if type(value) == 'string' then
			if value:find('rbxassetid://', 1, true) then
				set[value] = true
			end
		elseif type(value) == 'table' and not seen[value] then
			seen[value] = true
			for k, v in value do
				if k ~= skipKey then
					addShared(set, v, skipKey, seen)
				end
			end
		end
	end

	local function buildProjectileSounds()
		table.clear(projectileSounds)
		if not (hitOnly and hitOnly.enabled) then return end

		local sounds = bedwars.SoundList or {}
		local keep, seen = {}, {}
		local function addSource(source)
			if type(source) ~= 'table' then return end
			addSounds(projectileSounds, source.launchSound)
			addSounds(projectileSounds, source.launchOverlaySound)
			addSounds(projectileSounds, source.chargeBeginSound)
			if type(source.reload) == 'table' then
				addSounds(projectileSounds, source.reload.reloadSound)
			end
			addSounds(keep, source.hitSounds)
		end

		for _, meta in bedwars.ItemMeta or {} do
			if type(meta) == 'table' then
				addSource(meta.projectileSource)
				addShared(keep, meta, 'projectileSource', seen)
			end
		end
		local ok, skins = pcall(function()
			return require(replicatedStorage.TS.games.bedwars['item-skin']['item-skin-meta']).ItemSkinMeta
		end)
		if ok and type(skins) == 'table' then
			for _, skin in skins do
				if type(skin) == 'table' then
					addSource(skin.projectileSourceOverrides)
					addShared(keep, skin, 'projectileSourceOverrides', seen)
				end
			end
		end
		for name, meta in bedwars.ProjectileMeta or {} do
			if type(meta) == 'table' then
				if muteImpacts and muteImpacts.enabled
					and type(name) == 'string' and name:find('arrow', 1, true) then
					addSounds(projectileSounds, meta.impactSound)
				end
				addSounds(keep, meta.hitSounds)
			end
		end

		for name, id in sounds do
			if type(name) == 'string' and name:find('SWING', 1, true) then
				addSounds(keep, id)
			end
		end
		addSounds(keep, sounds.ARROW_HIT)
		addSounds(keep, sounds.HEADSHOT)
		for id in keep do
			projectileSounds[id] = nil
		end
		addSounds(projectileSounds, sounds.EQUIP_BOW)
	end

	local function updateVolumes()
		local volMultiplier = (volume and volume.value or 100) / 100
		for id, props in pairs(capturedRegistry) do
			if type(props) == "table" then
				if props._originalVolume == nil then
					props._originalVolume = props.volume or props.Volume or 1
				end
				if trackedSounds[id] then
					props.volume = props._originalVolume * volMultiplier
					props.Volume = props.volume
				else
					props.volume = props._originalVolume
					props.Volume = props._originalVolume
				end
			end
		end
	end

	local function audioHook(self, asset, config, ...)
		local mult = type(asset) == 'string' and soundMultiplier(asset)
		if not mult then
			return oldAudio(self, asset, config, ...)
		end
		local props = {}
		if type(config) == 'table' then
			for k, v in config do
				props[k] = v
			end
		end
		props.volumeMultiplier = (props.volumeMultiplier or 1) * mult
		local custom = customSounds[asset]
		if custom then
			local base = type(self.audioAssetConfigs) == 'table' and self.audioAssetConfigs[asset]
			if type(base) == 'table' then
				if props.category == nil then props.category = base.category end
				if props.bus == nil then props.bus = base.bus end
			end
			asset = custom
		end
		return oldAudio(self, asset, props, ...)
	end

	soundChanger = legit:module('SoundChanger', {
		tab = 'Utility',
		toggled = function(on)
			if on then
				buildProjectileSounds()

				local audio = bedwars.AudioManager
				audioMethod = type(audio) == 'table' and (
					type(audio.internalPlayAudio) == 'function' and 'internalPlayAudio'
					or type(audio.playAudio) == 'function' and 'playAudio'
				) or nil
				if audioMethod and audio[audioMethod] ~= audioHook then
					oldAudio = audio[audioMethod]
					audio[audioMethod] = audioHook
				end

				if bedwars.SoundManager.routesToAudioManager ~= true then
					old = bedwars.SoundManager.playSound
					bedwars.SoundManager.playSound = function(self, id, ...)
						local mult = soundMultiplier(id)
						if not mult then
							return old(self, id, ...)
						end
						local args = {...}
						for i, v in ipairs(args) do
							if type(v) == "table" then
								local newProps = {}
								for k, val in pairs(v) do newProps[k] = val end
								local baseVol = newProps.volume or newProps.Volume or 1
								newProps.volume = baseVol * mult
								newProps.Volume = newProps.volume
								args[i] = newProps
							end
						end

						local result = old(self, customSounds[id] or id, table.unpack(args))

						if result and typeof(result) == "Instance" and result:IsA("Sound") then
							result.Volume = result.Volume * mult
						end

						return result
					end

					oldRegister = bedwars.SoundManager.registerSound
					if oldRegister then
						bedwars.SoundManager.registerSound = function(self, id, props)
							capturedRegistry[id] = props
							if type(props) == "table" then
								if props._originalVolume == nil then
									props._originalVolume = props.volume or props.Volume or 1
								end
								if trackedSounds[id] then
									local volMultiplier = (volume and volume.value or 100) / 100
									props.volume = props._originalVolume * volMultiplier
									props.Volume = props.volume
								end
							end
							return oldRegister(self, id, props)
						end
					end

					if type(bedwars.SoundManager) == "table" then
						for k, v in pairs(bedwars.SoundManager) do
							if type(v) == "table" then
								for rk, rv in pairs(v) do
									if type(rk) == "string" and rk:find("rbxassetid://") and type(rv) == "table" then
										if not capturedRegistry[rk] then
											capturedRegistry[rk] = rv
										end
									end
								end
							end
						end
					end
				end

				updateVolumes()
			else
				if oldAudio then
					bedwars.AudioManager[audioMethod] = oldAudio
					oldAudio, audioMethod = nil, nil
				end
				if old then
					bedwars.SoundManager.playSound = old
					old = nil
				end
				if oldRegister then
					bedwars.SoundManager.registerSound = oldRegister
					oldRegister = nil
				end

				for id, props in pairs(capturedRegistry) do
					if type(props) == "table" and props._originalVolume ~= nil then
						props.volume = props._originalVolume
						props.Volume = props._originalVolume
					end
				end
			end
		end,
		about = 'Replaces game sounds and changes how loud they are.\nCan also mute bow sounds apart from the hit ding.'
	})

	list = soundChanger:list('Sounds', {
		placeholder = '(EQUIP_DEFAULT or EQUIP_DEFAULT/custom.mp3)',
		changed = function()
			table.clear(trackedSounds)
			table.clear(customSounds)
			local soundTable = bedwars.SoundList or bedwars.GameSound or bedwars.Sounds or {}
			for _, entry in ipairs(list.active) do
				entry = entry:match('^%s*(.-)%s*$')
				local id, path = entry:match('^(rbxassetid://%d+)/?(.*)$')
				if not id then
					local name
					name, path = entry:match('^([^/]+)/(.*)$')
					name = name or entry
					id = soundTable[name] or soundTable[name:upper()]
				end

				if id then
					trackedSounds[id] = true
					if path and path ~= "" then
						local custom = path:find('rbxasset') and path or isfile(path) and assetfunction(path) or nil
						if custom then
							customSounds[id] = custom
						end
					end
				end
			end
			updateVolumes()
		end
	})

	volume = soundChanger:slider('Volume', {
		min = 0,
		max = 200,
		default = 100,
		suffix = function(val) return '%' end,
		changed = function()
			updateVolumes()
		end
	})

	hitOnly = soundChanger:toggle('Hit ding only', {
		changed = function(callback)
			if muteImpacts and muteImpacts.row then
				muteImpacts.row.Visible = callback
			end
			buildProjectileSounds()
		end,
		about = 'Mutes every projectile switch, draw, reload and fire sound (skins included)\nand keeps the ding and headshot sound when your shot lands.'
	})

	muteImpacts = soundChanger:toggle('Mute impacts', {
		default = true,
		visible = false,
		sub = true,
		changed = function()
			buildProjectileSounds()
		end,
		about = 'Also mutes the thud where an arrow lands.'
	})
	if muteImpacts.row then
		muteImpacts.row.Visible = hitOnly.enabled
	end
end)
	
--[[ UI Cleanup
Tidies the BedWars HUD: a full-width health bar, no hotbar numbers, no inventory button, no kill
feed, the old player list, a lower queue card, and the top bar placed by Topbar Position. With the
debug library the options change constants of the hotbar components.

Without it (Solara, Xeno) the components those constants belong to are wrapped while UI Cleanup is
on: Resize Health takes the health bar's width from 0.85 to 1 (hotbar-healthbar) and stops
tweenPosition (hotbar-tile) lifting the selected tile by 0.075, No Hotbar Numbers sizes the 0.23
keybind label to 0, and Fix Queue Card moves the queue card's top from 0.01 to 0.1. HotbarApp's own
two constants (60 and 78) have no component to wrap and are left out. A change shows from the
component's next render.

Knitless (exec.Knitless) the components are stand-ins, so hud changes the HUD the game has rendered
under PlayerGui instead: the same sizes, the inventory button's tile (LayoutOrder 20) and
KillFeedContainer hidden, and each tile's ImageButton put back at 0, 0 after the game lifts it.
Roact writes a property only when its prop changes, so a change stays until the game mounts that
part again (the hotbar on each respawn). New pieces are styled once the frame's work is done
(task.defer), never inside a property signal, and every replaced value is kept and put back when its
option or UI Cleanup goes off.

Topbar Position: the game's top bar sits at the right of the strip Roblox leaves free (TopbarInset),
and the game moves it again whenever its size changes, so each of its moves is kept as the Default
position and Middle centres the row again straight after, inside that strip. On a phone the row
keeps room for the Pistonware button as padding inside the row of buttons, set in the units of its
UIScale, so the game lays the scores and timer out round it: in the corner at the right end of the
strip, or beside the buttons with Button Next To Topbar. That room is the button's width and the 7
px the GUI keeps from the game's buttons; the game ends the row 12 px in from the strip's end and
sizes it to the strip less 24 px. Hidden, the button takes no room and docks beside the buttons: in
the corner it would lie unseen over the game's last button and take its taps. The corner's room is
kept with UI Cleanup off too, and the bar is laid out again whenever Hide Pistonware Mobile Button
is switched. After a change the GUI places its button at once and again after the frame's layout
pass, as moving the padding fires no size signal. ]]
run(function()
	local uiCleanup
	local openInv
	local killFeed
	local oldTabList
	local hotbarApp = fieldPatch.constants and getRoactRender(require(lplr.PlayerScripts.TS.controllers.global.hotbar.ui['hotbar-app']).HotbarApp.render) or nil
	local hotbarOpenInventory = not exec.Knitless and require(lplr.PlayerScripts.TS.controllers.global.hotbar.ui['hotbar-open-inventory']).HotbarOpenInventory or nil
	local old, new = {}, {}
	local oldkillfeed
	local resizeHealth
	local noHotbarNumbers
	local fixQueueCard

	local cleanupHooks = {}
	local hotbarHealthbar, hotbarTile
	if not fieldPatch.constants and not exec.Knitless then
		pcall(function()
			hotbarHealthbar = require(lplr.PlayerScripts.TS.controllers.global.hotbar.ui.healthbar['hotbar-healthbar']).HotbarHealthbar
		end)
		pcall(function()
			hotbarTile = require(lplr.PlayerScripts.TS.controllers.global.hotbar.ui['hotbar-tile']).HotbarTile
		end)
	end

	local function hideKeybind(button)
		local keybind = fieldPatch.child(fieldPatch.children(button), 'TextLabel')
		if keybind then
			keybind.props.Size = UDim2.fromScale(0, 0)
		end
	end

	local function cleanHealthbar(_, element)
		if not (resizeHealth and resizeHealth.enabled) then return end
		local container = type(element) == 'table' and type(element.elements) == 'table'
			and element.elements.HotbarHealthbarContainer or nil
		local props = type(container) == 'table' and container.props
		if type(props) == 'table' and typeof(props.Size) == 'UDim2' then
			props.Size = UDim2.new(1, props.Size.X.Offset, props.Size.Y.Scale, props.Size.Y.Offset)
		end
	end

	local function cleanKeybind(_, element)
		if not (noHotbarNumbers and noHotbarNumbers.enabled) then return end
		local button = fieldPatch.child(fieldPatch.children(element), 'ImageButton')
		if button then
			hideKeybind(button)
		end
	end

	local function cleanQueueCard(_, element)
		local props = fixQueueCard and fixQueueCard.enabled and type(element) == 'table' and element.props
		if type(props) == 'table' and typeof(props.Position) == 'UDim2'
			and math.abs(props.Position.Y.Scale - 0.01) < 1e-6 then
			props.Position = UDim2.new(props.Position.X.Scale, props.Position.X.Offset, 0.1, props.Position.Y.Offset)
		end
	end

	local function setCleanupHooks(enabled)
		for _, hook in cleanupHooks do
			hook.remove()
		end
		table.clear(cleanupHooks)
		if not enabled then return end
		for _, pair in {{hotbarHealthbar, cleanHealthbar}, {hotbarTile, cleanKeybind},
			{hotbarOpenInventory, cleanKeybind}, {bedwars.QueueCard, cleanQueueCard}} do
			local hook = pair[1] ~= nil and fieldPatch.render(pair[1], pair[2]) or nil
			if hook then
				table.insert(cleanupHooks, hook)
			end
		end
		local hook = hotbarTile and fieldPatch.wrap(hotbarTile, 'tweenPosition', function(tweenPosition)
			return function(self, ...)
				if not (resizeHealth and resizeHealth.enabled) then
					return tweenPosition(self, ...)
				end
				self.positionMaid:DoCleaning()
				local frame = self.frameRef:getValue()
				if not frame then
					return nil
				end
				local tween = tweenService:Create(frame, TweenInfo.new(0.12), {
					Position = UDim2.fromScale(0, 0)
				})
				tween:Play()
				self.positionMaid:GiveTask(function()
					tween:Cancel()
				end)
			end
		end) or nil
		if hook then
			table.insert(cleanupHooks, hook)
		end
	end

	local hud = {
		Guis = {'hotbar', 'KillFeedGui', 'QueueApp'},
		Flat = UDim2.fromScale(0, 0),
		Lift = UDim2.fromScale(0, -0.075),
		Saved = {},
		Lifted = {},
		Pending = {},
		Hooked = {}
	}

	function hud.on(option)
		return option ~= nil and option.enabled == true
	end

	function hud.original(object, prop)
		local saved = hud.Saved[object]
		if saved and saved[prop] ~= nil then
			return saved[prop]
		end
		return object[prop]
	end

	function hud.style(object, prop, on, value)
		local saved = hud.Saved[object]
		if on then
			if not saved then
				saved = {}
				hud.Saved[object] = saved
			end
			if saved[prop] == nil then
				saved[prop] = object[prop]
			end
		elseif saved and saved[prop] ~= nil then
			value = saved[prop]
			saved[prop] = nil
		else
			return
		end
		if object[prop] ~= value then
			object[prop] = value
		end
	end

	function hud.flatten(button)
		if hud.Pending[button] then return end
		hud.Pending[button] = true
		task.defer(function()
			hud.Pending[button] = nil
			if hud.Lifted[button] and button.Position ~= hud.Flat then
				button.Position = hud.Flat
			end
		end)
	end

	function hud.lift(button, flat)
		local watch = hud.Lifted[button]
		if flat then
			if not watch then
				hud.Lifted[button] = button:GetPropertyChangedSignal('Position'):Connect(function()
					hud.flatten(button)
				end)
			end
			hud.flatten(button)
		elseif watch then
			watch:Disconnect()
			hud.Lifted[button] = nil
			if button.BorderColor3 == Color3.new(1, 1, 1) and button.Position == hud.Flat then
				button.Position = hud.Lift
			end
		end
	end

	function hud.keybind(object)
		if not object:IsA('TextLabel') then return false end
		local size = object.Size
		return math.abs(size.X.Scale - 0.23) < 1e-3 and math.abs(size.Y.Scale - 0.23) < 1e-3
	end

	function hud.apply()
		local playerGui = lplr:FindFirstChildOfClass('PlayerGui')
		if not playerGui then return end
		for object in hud.Saved do
			if not object:IsDescendantOf(playerGui) then
				hud.Saved[object] = nil
			end
		end
		for object, connection in hud.Lifted do
			if not object:IsDescendantOf(playerGui) then
				connection:Disconnect()
				hud.Lifted[object] = nil
			end
		end
		for gui, connection in hud.Hooked do
			if gui.Parent ~= playerGui then
				connection:Disconnect()
				hud.Hooked[gui] = nil
			end
		end
		for _, name in hud.Guis do
			local gui = playerGui:FindFirstChild(name)
			if gui and not hud.Hooked[gui] then
				hud.Hooked[gui] = gui.DescendantAdded:Connect(hud.queue)
			end
		end

		local hotbar = playerGui:FindFirstChild('hotbar')
		hotbar = hotbar and hotbar:FindFirstChild('1')
		local health = hotbar and hotbar:FindFirstChild('HotbarHealthbarContainer')
		if health and health:IsA('GuiObject') then
			local size = hud.original(health, 'Size')
			hud.style(health, 'Size', hud.on(resizeHealth), UDim2.new(1, size.X.Offset, size.Y.Scale, size.Y.Offset))
		end
		local items = hotbar and hotbar:FindFirstChild('ItemsHotbar')
		for _, tile in items and items:GetChildren() or {} do
			if not tile:IsA('GuiObject') then continue end
			local inventory = tile.LayoutOrder == 20
			if inventory then
				hud.style(tile, 'Visible', hud.on(openInv), false)
			end
			local button = tile:FindFirstChildOfClass('ImageButton')
			if button then
				for _, label in button:GetChildren() do
					if hud.keybind(label) then
						hud.style(label, 'Visible', hud.on(noHotbarNumbers), false)
					end
				end
				if not inventory then
					hud.lift(button, hud.on(resizeHealth))
				end
			end
		end

		local feed = playerGui:FindFirstChild('KillFeedGui')
		feed = feed and feed:FindFirstChild('KillFeedContainer')
		if feed and feed:IsA('GuiObject') then
			hud.style(feed, 'Visible', hud.on(killFeed), false)
		end

		local queue = playerGui:FindFirstChild('QueueApp')
		for _, card in queue and queue:GetChildren() or {} do
			if card:IsA('GuiObject') then
				local position = hud.original(card, 'Position')
				if math.abs(position.Y.Scale - 0.01) < 1e-4 then
					hud.style(card, 'Position', hud.on(fixQueueCard), UDim2.new(position.X.Scale, position.X.Offset, 0.1, position.Y.Offset))
				end
			end
		end
	end

	function hud.queue()
		if hud.Queued or not hud.Started then return end
		hud.Queued = true
		task.defer(function()
			hud.Queued = false
			if not hud.Started then return end
			local ok, err = pcall(hud.apply)
			if not ok then
				bufferCall('warn', 'UICleanup.knitless', tostring(err))
			end
		end)
	end

	function hud.refresh()
		if exec.Knitless and hud.Started then
			hud.queue()
		end
	end

	function hud.start()
		if hud.Started then return end
		hud.Started = true
		local playerGui = lplr:FindFirstChildOfClass('PlayerGui')
		if playerGui then
			hud.Added = playerGui.ChildAdded:Connect(function(child)
				if table.find(hud.Guis, child.Name) then
					hud.queue()
				end
			end)
		end
		hud.queue()
	end

	function hud.stop()
		hud.Started = false
		if hud.Added then
			hud.Added:Disconnect()
			hud.Added = nil
		end
		for _, connection in hud.Hooked do
			connection:Disconnect()
		end
		table.clear(hud.Hooked)
		local lifted = {}
		for button in hud.Lifted do
			table.insert(lifted, button)
		end
		for _, button in lifted do
			pcall(hud.lift, button, false)
		end
		table.clear(hud.Lifted)
		for object, saved in hud.Saved do
			for prop, value in saved do
				pcall(function()
					if object[prop] ~= value then
						object[prop] = value
					end
				end)
			end
		end
		table.clear(hud.Saved)
	end
	if exec.Knitless then
		slinky:clean(hud.stop)
	end

	slinky:clean(function()
		for _, v in new do
			table.clear(v)
		end
		for _, v in old do
			table.clear(v)
		end
		table.clear(new)
		table.clear(old)
	end)
	
	local function modifyconstant(func, ind, val)
		if not old[func] then old[func] = {} end
		if not new[func] then new[func] = {} end
		if not old[func][ind] then
			local typing = type(old[func][ind])
			if typing == 'function' or typing == 'userdata' then return end
			old[func][ind] = debug.getconstant(func, ind)
		end
		if typeof(old[func][ind]) ~= typeof(val) and val ~= nil then return end
	
		new[func][ind] = val
		if uiCleanup.enabled then
			if val then
				debug.setconstant(func, ind, val)
			else
				debug.setconstant(func, ind, old[func][ind])
				old[func][ind] = nil
			end
		end
	end

	local topbarPosition
	local nextToTopbar
	local topbar = {
		Original = setmetatable({}, {__mode = 'k'}),
		Placed = setmetatable({}, {__mode = 'k'}),
		Watched = setmetatable({}, {__mode = 'k'}),
		Connections = {}
	}

	function topbar.middle()
		return uiCleanup ~= nil and uiCleanup.enabled and topbarPosition ~= nil and topbarPosition.value == 'Middle'
	end

	function topbar.hidden()
		local hide = slinky.hideMenuButton
		return type(hide) == 'table' and hide.enabled == true
	end

	function topbar.docked()
		if topbar.hidden() then return true end
		return uiCleanup ~= nil and uiCleanup.enabled and nextToTopbar ~= nil and nextToTopbar.enabled
	end

	function topbar.strip()
		local ok, low, high = pcall(function()
			local inset = guiService.TopbarInset
			if inset.Width > 0 then
				return inset.Min.X, inset.Max.X
			end
			return nil
		end)
		if ok and low then
			return low, high
		end
		return nil
	end

	function topbar.slinkyButton()
		local button = slinky.menuButton
		if topbar.Unloaded or not (button and button.Parent) or topbar.hidden() then
			return 0, false
		end
		return math.max(button.AbsoluteSize.X, 32) + 7, slinky.dockMenuButton ~= nil and not slinky.menuButtonDocked
	end

	function topbar.active()
		if topbar.Unloaded then return false end
		if topbar.middle() then return true end
		local room, corner = topbar.slinkyButton()
		return room > 0 and (corner or (uiCleanup ~= nil and uiCleanup.enabled))
	end

	function topbar.queue()
		if topbar.Queued then return end
		topbar.Queued = true
		task.defer(function()
			topbar.Queued = false
			if topbar.active() then
				topbar.place()
			end
		end)
	end

	function topbar.watch(object)
		if topbar.Watched[object] then return end
		topbar.Watched[object] = true
		local connections = topbar.Connections
		table.insert(connections, object:GetPropertyChangedSignal('AbsoluteSize'):Connect(topbar.queue))
		if object:IsA('GuiObject') then
			table.insert(connections, object:GetPropertyChangedSignal('Visible'):Connect(topbar.queue))
			table.insert(connections, object:GetPropertyChangedSignal('Position'):Connect(function()
				if object.Position ~= topbar.Placed[object] then
					topbar.queue()
				end
			end))
		else
			table.insert(connections, object:GetPropertyChangedSignal('AbsolutePosition'):Connect(topbar.queue))
			table.insert(connections, object.ChildAdded:Connect(topbar.queue))
		end
	end

	function topbar.origin(object)
		local current = object.Position
		if current ~= topbar.Placed[object] then
			topbar.Original[object] = current
		end
		return topbar.Original[object]
	end

	function topbar.move(object, gui, right)
		local original = topbar.origin(object)
		local x = right - gui.AbsolutePosition.X - (1 - object.AnchorPoint.X) * object.AbsoluteSize.X
		local position = UDim2.new(0, math.floor(x + 0.5), original.Y.Scale, original.Y.Offset)
		topbar.Placed[object] = position
		if object.Position ~= position then
			object.Position = position
		end
		topbar.watch(object)
	end

	function topbar.pad(buttons, side, room)
		local padding = topbar.Padding
		if not buttons or room <= 0 then
			if padding then
				topbar.Padding = nil
				padding:Destroy()
			end
			return 0
		end
		if not padding or padding.Parent ~= buttons then
			if padding then
				padding:Destroy()
			end
			padding = Instance.new('UIPadding')
			topbar.Padding = padding
		end
		local uiScale = buttons:FindFirstChildOfClass('UIScale')
		local factor = uiScale and uiScale.Scale > 0 and uiScale.Scale or 1
		local width = math.ceil(room / factor)
		local left = UDim.new(0, side == 'Left' and width or 0)
		local right = UDim.new(0, side == 'Right' and width or 0)
		if padding.PaddingLeft ~= left then
			padding.PaddingLeft = left
		end
		if padding.PaddingRight ~= right then
			padding.PaddingRight = right
		end
		if padding.Parent ~= buttons then
			padding.Parent = buttons
		end
		return side == 'Right' and width * factor or 0
	end

	function topbar.nudge()
		if not slinky.placeMenuButton then return end
		slinky.placeMenuButton()
		if topbar.Renudge then return end
		topbar.Renudge = true
		task.delay(0, function()
			topbar.Renudge = false
			if not topbar.Unloaded and slinky.placeMenuButton then
				slinky.placeMenuButton()
			end
		end)
	end

	function topbar.place()
		local playerGui = lplr:FindFirstChildOfClass('PlayerGui')
		local appGui = playerGui and playerGui:FindFirstChild('TopBarAppGui')
		local buttons = appGui and appGui:FindFirstChild('TopBarApp')
		local camera = workspace.CurrentCamera
		if not (buttons and buttons:IsA('GuiObject') and camera) then return end
		topbar.watch(appGui)
		topbar.watch(buttons)
		local strip, stripEnd = topbar.strip()
		local room, corner = topbar.slinkyButton()
		corner = corner and strip ~= nil
		if not (corner or (uiCleanup ~= nil and uiCleanup.enabled)) then
			room = 0
		end
		local cornerRoom = topbar.pad(buttons, corner and 'Right' or 'Left', room)
		if not topbar.middle() then
			topbar.unplace()
			topbar.nudge()
			return
		end
		local statsGui = playerGui:FindFirstChild('TopBarStatsGui')
		local stats = statsGui and statsGui:FindFirstChild('TopBarStatsScroller')
		if statsGui then
			topbar.watch(statsGui)
		end
		if stats and stats:IsA('GuiObject') then
			topbar.watch(stats)
		else
			stats = nil
		end
		local statsWidth = stats and stats.Visible and stats.AbsoluteSize.X or 0
		local width = buttons.AbsoluteSize.X + (statsWidth > 0 and statsWidth + 8 or 0)
		local left, area = appGui.AbsolutePosition.X, appGui.AbsoluteSize.X
		if area <= 0 then return end
		local low, high = left, left + area
		if strip then
			low, high = strip, stripEnd
		end
		local shown = width
		if corner then
			high -= 12
			shown -= cornerRoom
		end
		local start = math.clamp(camera.ViewportSize.X / 2 - shown / 2, low, math.max(high - width, low))
		local right = start + width
		topbar.move(buttons, appGui, right)
		if statsWidth > 0 then
			topbar.move(stats, statsGui, start + statsWidth)
		end
		for _, child in appGui:GetChildren() do
			if child ~= buttons and child:IsA('GuiObject') and topbar.origin(child).X == UDim.new(1, -12) then
				topbar.move(child, appGui, right - cornerRoom)
			end
		end
		topbar.nudge()
	end

	function topbar.unplace()
		for object, original in topbar.Original do
			if object.Parent and object.Position == topbar.Placed[object] then
				object.Position = original
			end
		end
		table.clear(topbar.Original)
		table.clear(topbar.Placed)
	end

	function topbar.restore()
		for _, connection in topbar.Connections do
			connection:Disconnect()
		end
		table.clear(topbar.Connections)
		table.clear(topbar.Watched)
		topbar.Hooked = false
		topbar.unplace()
		topbar.pad(nil, nil, 0)
	end

	function topbar.refresh()
		if slinky.dockMenuButton and not topbar.Unloaded then
			slinky:dockMenuButton(topbar.docked())
		end
		if not topbar.active() then
			topbar.restore()
			return
		end
		if not topbar.Hooked then
			topbar.Hooked = true
			local playerGui = lplr:FindFirstChildOfClass('PlayerGui')
			if playerGui then
				table.insert(topbar.Connections, playerGui.ChildAdded:Connect(function(child)
					if child.Name == 'TopBarAppGui' or child.Name == 'TopBarStatsGui' then
						topbar.queue()
					end
				end))
			end
			pcall(function()
				table.insert(topbar.Connections, guiService:GetPropertyChangedSignal('TopbarInset'):Connect(topbar.queue))
			end)
		end
		topbar.queue()
	end

	uiCleanup = legit:module('UI Cleanup', {
		toggled = function(on)
			if exec.Knitless then
				if on then
					hud.start()
				else
					hud.stop()
				end
				if oldTabList.enabled then
					starterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, on)
				end
				topbar.refresh()
				return
			end
			if fieldPatch.constants then
				for i, v in (on and new or old) do
					for i2, v2 in v do
						debug.setconstant(i, i2, v2)
					end
				end
			elseif on then
				setCleanupHooks(true)
			end
			if on then
				if openInv.enabled then
					oldinvrender = hotbarOpenInventory.render
					hotbarOpenInventory.render = function()
						return bedwars.Roact.createElement('TextButton', {Visible = false}, {})
					end
				end
	
				if killFeed.enabled then
					oldkillfeed = bedwars.KillFeedController.addToKillFeed
					bedwars.KillFeedController.addToKillFeed = function() end
				end
	
				if oldTabList.enabled then
					starterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, true)
				end
			else
				if oldinvrender then
					hotbarOpenInventory.render = oldinvrender
					oldinvrender = nil
				end
	
				if killFeed.enabled then
					bedwars.KillFeedController.addToKillFeed = oldkillfeed
					oldkillfeed = nil
				end
	
				if oldTabList.enabled then
					starterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, false)
				end
				if not fieldPatch.constants then
					setCleanupHooks(false)
				end
			end
			topbar.refresh()
		end,
		about = 'Tidies up the BedWars HUD and removes clutter.\nCovers the health bar, hotbar, kill feed, player list, queue card and top bar.'
	})
	topbarPosition = uiCleanup:dropdown('Topbar Position', {
		choices = {'Default', 'Middle'},
		changed = function()
			topbar.refresh()
		end,
		about = 'Where the BedWars top bar sits: on the right (Default) or centred at the top of the screen (Middle).'
	})
	nextToTopbar = uiCleanup:toggle('Button Next To Topbar', {
		changed = function()
			topbar.refresh()
		end,
		about = 'Puts the mobile menu button next to the top bar instead of in the top-right corner.'
	})
	resizeHealth = uiCleanup:toggle('Resize Health', {
		changed = function(callback)
			if not fieldPatch.constants then
				hud.refresh()
				return
			end
			modifyconstant(hotbarApp, 60, callback and 1 or nil)
			modifyconstant(debug.getupvalue(hotbarApp, 15).render, 30, callback and 1 or nil)
			modifyconstant(debug.getupvalue(hotbarApp, 23).tweenPosition, 16, callback and 0 or nil)
		end,
		default = true
	})
	noHotbarNumbers = uiCleanup:toggle('No Hotbar Numbers', {
		changed = function(callback)
			if not fieldPatch.constants then
				hud.refresh()
				return
			end
			local func = oldinvrender or hotbarOpenInventory.render
			modifyconstant(debug.getupvalue(hotbarApp, 23).render, 90, callback and 0 or nil)
			modifyconstant(func, 71, callback and 0 or nil)
		end,
		default = true
	})
	openInv = uiCleanup:toggle('No Inventory Button', {
		changed = function(callback)
			if fieldPatch.constants then
				modifyconstant(hotbarApp, 78, callback and 0 or nil)
			end
			if exec.Knitless then
				hud.refresh()
				return
			end
			if uiCleanup.enabled then
				if callback then
					oldinvrender = hotbarOpenInventory.render
					hotbarOpenInventory.render = function()
						return bedwars.Roact.createElement('TextButton', {Visible = false}, {})
					end
				else
					hotbarOpenInventory.render = oldinvrender
					oldinvrender = nil
				end
			end
		end,
		default = true
	})
	killFeed = uiCleanup:toggle('No Kill Feed', {
		changed = function(callback)
			if exec.Knitless then
				hud.refresh()
				return
			end
			if uiCleanup.enabled then
				if callback then
					oldkillfeed = bedwars.KillFeedController.addToKillFeed
					bedwars.KillFeedController.addToKillFeed = function() end
				else
					bedwars.KillFeedController.addToKillFeed = oldkillfeed
					oldkillfeed = nil
				end
			end
		end,
		default = true
	})
	oldTabList = uiCleanup:toggle('Old Player List', {
		changed = function(callback)
			if uiCleanup.enabled then
				starterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, callback)
			end
		end,
		default = true
	})
	fixQueueCard = uiCleanup:toggle('Fix Queue Card', {
		changed = function(callback)
			if not fieldPatch.constants then
				hud.refresh()
				return
			end
			modifyconstant(bedwars.QueueCard.render, 15, callback and 0.1 or nil)
		end,
		default = true
	})
	topbar.refresh()
	slinky:clean(function()
		topbar.Unloaded = true
		topbar.restore()
	end)
	local hideButton = slinky.hideMenuButton
	if type(hideButton) == 'table' and type(hideButton.flip) == 'function' then
		local toggle = hideButton.flip
		hideButton.flip = function(self, ...)
			local results = table.pack(toggle(self, ...))
			topbar.refresh()
			return table.unpack(results, 1, results.n)
		end
		slinky:clean(function()
			hideButton.flip = toggle
		end)
	end
end)
	
--[[ Viewmodel
Moves and rotates the item you hold in first person and can stop it bobbing as you walk. The offsets
are the viewmodel controller's ConstantManager attributes and the rotation is the RightWrist C1.

Knitless (Solara, Xeno; exec.Knitless) ViewmodelController.playAnimation cannot be made to skip
FP_WALK. That bob is one looped track on the viewmodel's Animator: setHeldItem loads it with each
held item, and a 0.1 s loop of the game's plays it while you move and stops it when you stand. With
No Bobbing each FP_WALK track on a model under the camera is turned down to the weight the game
gives a track it mutes (0.0001) as it starts, and again on any frame its weight came back. A muted
track still counts as playing, so that loop leaves it alone. Read back as a float, the muted weight
is not exactly 0.0001, so under 0.001 counts as muted. On disable each muted track still playing
fades back to its weight. ]]
run(function()
	local viewmodel
	local depth
	local horizontal
	local vertical
	local noBob
	local rots = {}
	local old, oldc1

	local MUTED_WEIGHT = 0.0001
	local walkTracks = {}
	local walkAsset

	local function weighted(track)
		return track.WeightTarget >= 0.001
	end

	local function muteWalk(track)
		local animation = track.Animation
		local id = animation and animation.AnimationId
		if type(id) ~= 'string' or id:match('%d+$') ~= walkAsset then return end
		if walkTracks[track] == nil then
			walkTracks[track] = weighted(track) and track.WeightTarget or 1
			track.Destroying:Once(function()
				walkTracks[track] = nil
			end)
		end
		if track.IsPlaying and weighted(track) then
			track:AdjustWeight(MUTED_WEIGHT, 0)
		end
	end

	local function muteBob()
		local ok, id = pcall(function()
			return bedwars.GameAnimationUtil:getAssetId(bedwars.AnimationType.FP_WALK)
		end)
		walkAsset = ok and type(id) == 'string' and id:match('%d+$') or '8091867276'
		local function watch(model)
			local humanoid = model:IsA('Model') and model:FindFirstChildOfClass('Humanoid')
			local animator = humanoid and humanoid:FindFirstChildOfClass('Animator')
			if not animator then return end
			viewmodel:clean(animator.AnimationPlayed:Connect(muteWalk))
			for _, track in animator:GetPlayingAnimationTracks() do
				muteWalk(track)
			end
		end
		for _, child in gameCamera:GetChildren() do
			watch(child)
		end
		viewmodel:clean(gameCamera.ChildAdded:Connect(watch))
		viewmodel:clean(runService.Heartbeat:Connect(function()
			for track in walkTracks do
				if track.IsPlaying and weighted(track) then
					track:AdjustWeight(MUTED_WEIGHT, 0)
				end
			end
		end))
	end

	local function unmuteBob()
		for track, weight in walkTracks do
			if track.IsPlaying and not weighted(track) then
				track:AdjustWeight(weight, 0.3)
			end
		end
		table.clear(walkTracks)
	end
	
	viewmodel = legit:module('Viewmodel', {
		toggled = function(on)
			local viewmodel = gameCamera:FindFirstChild('Viewmodel')
			if on then
				old = bedwars.ViewmodelController.playAnimation
				oldc1 = viewmodel and viewmodel.RightHand.RightWrist.C1 or CFrame.identity
				if noBob.enabled then
					bedwars.ViewmodelController.playAnimation = function(self, animtype, ...)
						if bedwars.AnimationType and animtype == bedwars.AnimationType.FP_WALK then return end
						return old(self, animtype, ...)
					end
				end
	
				bedwars.InventoryViewmodelController:handleStore(bedwars.Store:getState())
				if viewmodel then
					gameCamera.Viewmodel.RightHand.RightWrist.C1 = oldc1 * CFrame.Angles(math.rad(rots[1].value), math.rad(rots[2].value), math.rad(rots[3].value))
				end
				lplr.PlayerScripts.TS.controllers.global.viewmodel['viewmodel-controller']:SetAttribute('ConstantManager_DEPTH_OFFSET', -depth.value)
				lplr.PlayerScripts.TS.controllers.global.viewmodel['viewmodel-controller']:SetAttribute('ConstantManager_HORIZONTAL_OFFSET', horizontal.value)
				lplr.PlayerScripts.TS.controllers.global.viewmodel['viewmodel-controller']:SetAttribute('ConstantManager_VERTICAL_OFFSET', vertical.value)
				if exec.Knitless and noBob.enabled then
					muteBob()
				end
			else
				bedwars.ViewmodelController.playAnimation = old
				if exec.Knitless then
					unmuteBob()
				end
				if viewmodel then
					viewmodel.RightHand.RightWrist.C1 = oldc1
				end
	
				bedwars.InventoryViewmodelController:handleStore(bedwars.Store:getState())
				lplr.PlayerScripts.TS.controllers.global.viewmodel['viewmodel-controller']:SetAttribute('ConstantManager_DEPTH_OFFSET', 0)
				lplr.PlayerScripts.TS.controllers.global.viewmodel['viewmodel-controller']:SetAttribute('ConstantManager_HORIZONTAL_OFFSET', 0)
				lplr.PlayerScripts.TS.controllers.global.viewmodel['viewmodel-controller']:SetAttribute('ConstantManager_VERTICAL_OFFSET', 0)
				old = nil
			end
		end,
		about = 'Moves and rotates the item you hold in first person.\nCan also stop it bobbing as you walk.'
	})
	depth = viewmodel:slider('Depth', {
		min = 0,
		max = 2,
		default = 0.8,
		decimal = 10,
		changed = function(val)
			if viewmodel.enabled then
				lplr.PlayerScripts.TS.controllers.global.viewmodel['viewmodel-controller']:SetAttribute('ConstantManager_DEPTH_OFFSET', -val)
			end
		end
	})
	horizontal = viewmodel:slider('Horizontal', {
		min = 0,
		max = 2,
		default = 0.8,
		decimal = 10,
		changed = function(val)
			if viewmodel.enabled then
				lplr.PlayerScripts.TS.controllers.global.viewmodel['viewmodel-controller']:SetAttribute('ConstantManager_HORIZONTAL_OFFSET', val)
			end
		end
	})
	vertical = viewmodel:slider('Vertical', {
		min = -0.2,
		max = 2,
		default = -0.2,
		decimal = 10,
		changed = function(val)
			if viewmodel.enabled then
				lplr.PlayerScripts.TS.controllers.global.viewmodel['viewmodel-controller']:SetAttribute('ConstantManager_VERTICAL_OFFSET', val)
			end
		end
	})
	for _, name in {'Rotation X', 'Rotation Y', 'Rotation Z'} do
		table.insert(rots, viewmodel:slider(name, {
			min = 0,
			max = 360,
			changed = function(val)
				if viewmodel.enabled then
					gameCamera.Viewmodel.RightHand.RightWrist.C1 = oldc1 * CFrame.Angles(math.rad(rots[1].value), math.rad(rots[2].value), math.rad(rots[3].value))
				end
			end
		}))
	end
	noBob = viewmodel:toggle('No Bobbing', {
		default = true,
		changed = function()
			if viewmodel.enabled then
				viewmodel:flip(nil, true)
				viewmodel:flip(nil, true)
			end
		end
	})
end)
	
--[[ WinEffect
Plays the win effect chosen in Effects when a match ends; only you see it. With getconnections it
calls the WinEffectTriggered listeners itself. Without it (Solara, Xeno) it calls
onWin(winningPlayer) on every Knit controller of the chosen winEffectType (win-effect), which is all
that listener does after checking the type. ]]
run(function()
	if exec.skip('WinEffect') then return end
	local winEffect
	local list
	local nameToId = {}

	local function playWinEffect()
		local effectType = nameToId[list.value]
		local controllers = bedwars.Knit and bedwars.Knit.Controllers
		if effectType == nil or type(controllers) ~= 'table' then return end
		for _, controller in controllers do
			if type(controller) == 'table' and controller.winEffectType == effectType
				and type(controller.onWin) == 'function' then
				task.spawn(pcall, controller.onWin, controller, lplr)
			end
		end
	end

	winEffect = legit:module('WinEffect', {
		toggled = function(on)
			if on and not exec.Connections then
				winEffect:clean(slinkyEvents.MatchEndEvent.Event:Connect(playWinEffect))
				return
			end
			if on then
				winEffect:clean(slinkyEvents.MatchEndEvent.Event:Connect(function()
					for i, v in getconnections(bedwars.Client:Get('WinEffectTriggered').instance.OnClientEvent) do
						if v.Function then
							v.Function({
								winEffectType = nameToId[list.value],
								winningPlayer = lplr
							})
						end
					end
				end))
			end
		end,
		about = 'Plays the win effect of your choice when a match ends.\nOnly you can see it.'
	})
	local winEffectName = {}
	for i, v in bedwars.WinEffectMeta do
		table.insert(winEffectName, v.name)
		nameToId[v.name] = i
	end
	table.sort(winEffectName)
	list = winEffect:dropdown('Effects', {
		choices = winEffectName
	})
end)

--[[ DeviceSpoofer
DeviceSpoofer and HideNametag used to sit inside WinEffect's block, which was never closed until
after them, so a WinEffect that failed to build took both of them down with it. ]]
run(function()
	local deviceSpoofer
	local device
	local spoofedType
	local realInputType
	local realGetUserInputType

	local function sendInputType(inputType)
		bedwars.Client:Get('SendUserInputType'):SendToServer({
			userInputType = inputType
		})
	end

	local function resolveInputType()
		if device.value == 'Random' then
			local types = {'MOBILE', 'PC', 'GAMEPAD'}
			return types[math.random(#types)]
		end
		return device.value:upper()
	end

	deviceSpoofer = utility:module('DeviceSpoofer', {
		toggled = function(on)
			if on then
				realInputType = bedwars.UserInputController:getUserInputType()
				realGetUserInputType = bedwars.UserInputController.getUserInputType
				spoofedType = resolveInputType()

				bedwars.UserInputController.getUserInputType = function()
					return spoofedType
				end

				sendInputType(spoofedType)
			else
				bedwars.UserInputController.getUserInputType = realGetUserInputType
				sendInputType(realInputType)
				realGetUserInputType = nil
			end
		end,
		info = function()
			if device.value == 'Random' then
				return 'Random'..(spoofedType and ' ('..spoofedType..')' or '')
			end
			return device.value
		end,
		about = 'Makes the game think you are playing on another device.\nPick mobile, PC, gamepad or a random one.'
	})

	device = deviceSpoofer:dropdown('Device', {
		choices = {'Mobile', 'PC', 'Gamepad', 'Random'},
		changed = function(value)
			if deviceSpoofer.enabled then
				spoofedType = resolveInputType()
				sendInputType(spoofedType)
			end
		end
	})
end)

--[[ HideNametag
Hides the nametag over your own head. ]]
run(function()
	local hideNametag
	local nametagWatch = {}
	local charConn

	local function clearNametagWatch()
		for _, c in nametagWatch do
			pcall(function() c:Disconnect() end)
		end
		table.clear(nametagWatch)
	end

	local function eachNametag(char, fn)
		if not char then return end
		for _, v in char:GetDescendants() do
			if v:IsA('BillboardGui') and v.Name == 'Nametag' then
				pcall(fn, v)
			end
		end
	end

	local function setNametagEnabled(state, char)
		clearNametagWatch()
		char = char or lplr.Character
		if not char then return end

		eachNametag(char, function(v) v.Enabled = state end)
		if state then return end

		nametagWatch[#nametagWatch + 1] = char.DescendantAdded:Connect(function(v)
			if v:IsA('BillboardGui') and v.Name == 'Nametag' then
				pcall(function() v.Enabled = false end)
			end
		end)
	end

	hideNametag = utility:module('HideNametag', {
		tab = 'Visual',
		toggled = function(on)
			if on then
				setNametagEnabled(false)
				charConn = lplr.CharacterAdded:Connect(function(char)
					if hideNametag.enabled then
						setNametagEnabled(false, char)
					end
				end)
			else
				if charConn then
					pcall(function() charConn:Disconnect() end)
					charConn = nil
				end
				setNametagEnabled(true)
			end
		end,
		about = 'Hides the nametag over your own head.'
	})
end)

--[[ Knitless (Solara, Xeno; exec.Knitless), NoSlowdown, AutoTool and SafeWalk load and toggle but can
change nothing: all they do is wrap a method the game never calls on the stand-ins. They are taken
out before the profile applies, as an impossible module is. One already skipped by name keeps the
reason it was skipped with. ]]
if exec.Knitless then
	for _, name in {'NoSlowdown', 'AutoTool', 'SafeWalk'} do
		if not exec.skip(name) then
			exec.hide(name, "needs BedWars' Knit, which this executor cannot load")
		end
	end
end

--[[ == bedwars module loader ==
Exposes shared.bedwars and loads the BedWars module payload ]]

--[[ A superseded boot stops here, and the current one clears any loaded flag the old payload left,
so main.lua only takes the flag from this payload. ]]
if shared.slinky ~= slinky then return end
shared.PistonwareBedwarsLoaded = nil
--[[ Hands the script's services, libraries, game state and helpers to other scripts through
shared.bedwars. ]]
shared.bedwars = {
    playersService      = playersService,
    replicatedStorage   = replicatedStorage,
    runService          = runService,
    inputService        = inputService,
    tweenService        = tweenService,
    httpService         = httpService,
    textChatService     = textChatService,
    collectionService   = collectionService,
    contextActionService = contextActionService,
    guiService          = guiService,
    coreGui             = coreGui,
    starterGui          = starterGui,
    lightingService     = lightingService,
    teleportService     = teleportService,
	pathfindingService   = pathfindingService,
	virtualInputManager = virtualInputManager,

    slinky                = slinky,
    slinkyEvents          = slinkyEvents,
    entitylib           = entitylib,
    targetinfo          = targetinfo,
    prediction          = prediction,
    color               = color,
	uipallet            = uipallet,
	buffer              = pistonwareBuffer,

    lplr                = lplr,
    gameCamera          = gameCamera,
    bedwars             = bedwars,
    remotes             = remotes,
    store               = store,
    sides               = sides,
    AntiFallPart        = antiFallPart,
    slinkyConnections     = slinkyConnections,
    RunLoops            = RunLoops,

    run                 = run,
    blankFunction       = blankFunction,
    notif               = notif,
    switchItem          = switchItem,
    getItem             = getItem,
    getWool             = getWool,
    getNearGround       = getNearGround,
    getBlocksInPoints   = getBlocksInPoints,
    getPlacedBlock      = getPlacedBlock,
    roundPos            = roundPos,
    entryMatches        = entryMatches,
    sortmethods         = sortmethods,
    frictionTable       = frictionTable,
    genv                = genv,
    collection          = collection,
    isnetworkowner      = isnetworkowner,
    getfontsize         = getfontsize,
    getcustomasset      = getcustomasset,
    cloneref            = cloneref,
    assetfunction       = assetfunction,
    oldSwing            = oldSwing,
    isLocalAfk          = isLocalAfk,
    updateVelocity      = updateVelocity,
	_baseGetSpeed       = _baseGetSpeed,
	namecallGuard       = namecallGuard,
	fpsHooks            = fpsHooks,
	exec                = exec,
}

--[[ bedwars.lua is the ONLY file fetched from GitLab -- everything else comes from GitHub -- and
it sits at the REPO ROOT there (gitlab.com/pistonware/pistonware/bedwars.lua). It is never
written to disk and, outside developer mode, never read from disk: it gets neither the caching
nor the commit tracking that every other file in the project has, so every load runs the
current one. The payload checks the global script_key itself when it runs; the loader's key
gate is what sets it, and nothing here can stand in for it. ]]

--[[ Compiles a payload source under the name it runs as; a source that does not compile is
reported as bedwars.compile with its size, and the caller gets nil and the error. ]]
local function compileBedwarsSource(source, chunkName)
    local func, err = loadstring(source, chunkName)
    if not func then
        local size = type(source) == 'string' and #source or 0
		bufferCall('error', 'bedwars.compile', err, {chunk = chunkName, bytes = size})
    end
    return func, err
end

local function bootFailure(stage, err)
    local message = tostring(err or 'unknown BedWars boot failure')
    message = message:gsub('([Ss]cript[_%s]*[Kk]ey%s*[:=]%s*)[^%s,;]+', '%1<redacted>')
    message = message:gsub('([?&][Kk]ey=)[^&%s]+', '%1<redacted>')
    if #message > 900 then message = message:sub(1, 897)..'...' end
    return {
        PistonwareBootFailure = true,
        stage = stage,
        error = message
    }
end

--[[ Returns the BedWars payload's source, or nil and a boot failure. In developer mode the local
pistonware/games/bedwars.lua is read instead of fetched, compiled under the name it runs as and
handed back as a third result, so the caller runs that chunk and does not compile the same ~1 MB a
second time on the game thread.

Otherwise up to four attempts, waiting the attempt's number in seconds between them. Attempt 1 is
the request started after the store was built (store.payloadFetch), so its network wait overlaps
match setup; it is waited on with no cut-off, as HttpGet ends a hung request itself and the pcall
around it always sets done. A body is accepted only when it compiles: during an outage HttpGet can
hand back the 503 or error page as the body, which the empty and '404: Not Found' tests would
accept. ]]
local function downloadBedwars()
    if shared.PistonwareDeveloper then
        local suc, res = pcall(function()
            if not isfile('pistonware/games/bedwars.lua') then return nil end
            return readfile('pistonware/games/bedwars.lua')
        end)
        if not suc then
            return nil, bootFailure('bedwars.local.read', res)
        end
        if type(res) ~= 'string' or res == '' then
            return nil, bootFailure('bedwars.local.missing', 'developer mode requires pistonware/games/bedwars.lua')
        end
        local localFunc, compileError = compileBedwarsSource(res, 'bedwars')
        if not localFunc then
            return nil, bootFailure('bedwars.local.compile', compileError)
        end
		bufferCall('print', 'bedwars.developer', 'running local games/bedwars.lua')
        return res, nil, localFunc
    end

    local early = store.payloadFetch
    store.payloadFetch = nil

    local lastFailure
    for attempt = 1, 4 do
        local suc, res
        if attempt == 1 and early then
            while not early.done do
                task.wait()
            end
            suc, res = early.ok, early.body
        else
            suc, res = pcall(function()
                local protectedUrl = shared.PistonwareProtectedRawUrl
                return type(protectedUrl) == 'function' and httpGet(protectedUrl(), true)
                    or httpGet('https://gitlab.com/pistonware/pistonware/-/raw/main/bedwars.lua', true)
            end)
        end
        if suc and type(res) == 'string' and res ~= '' and res ~= '404: Not Found' then
            local chunkName = string.format('bedwars.network.%d', attempt)
            local networkFunc, compileError = compileBedwarsSource(res, chunkName)
            if networkFunc then return res end
            lastFailure = bootFailure('bedwars.network.compile', compileError)
        else
            lastFailure = bootFailure('bedwars.download', suc and 'empty or missing BedWars payload' or res)
        end
        if attempt < 4 then
            task.wait(attempt)
        end
    end

    return nil, lastFailure or bootFailure('bedwars.download', 'the protected payload could not be downloaded')
end

--[[ The key check blanks the global script_key as soon as it has authenticated, so another
script running later in the same session cannot read it back out. That makes the key single-use
per session, and ANY second load of the payload (the GUI's Reinject button, a re-run of this
file, a manual execute after injecting) lands on 'No key found', which does not merely fail:
the key check puts up a modal Auth Error with a Leave button and never returns. Everything downstream of the call below is then stranded -- including main.lua's
finishLoading(), which is what applies your saved profile, so the symptom is a GUI that loads
with Profile 'default' and an empty Profiles list rather than an obvious error.

shared.PistonwareKey is the loader's own copy of the validated key and is never blanked, so
re-publishing from it immediately before each load makes the key effectively reusable.
Written to every table the payload might read it from, not just one. Executors do not agree
on what a loadstring'd chunk's environment is: on most, a bare global assignment lands in
getgenv(), but several mobile executors sandbox chunks so that the two are different tables,
and _G is different again. Whichever one the payload looks at has to have the key in it, and
writing all three costs nothing. Returns false when there is no key to publish. ]]
local function republishKey()
    local key = shared.PistonwareKey
    if type(key) ~= 'string' or key == '' then return false end
    script_key = key
    pcall(function() getgenv().script_key = key end)
    pcall(function() _G.script_key = key end)
    return true
end

local bedwarsSource, bedwarsFailure, bedwarsCompiled = downloadBedwars()
if not bedwarsSource then
    local failure = bedwarsFailure or bootFailure('bedwars.download', 'no usable BedWars payload')
	bufferCall('error', failure.stage, failure.error)
    pcall(function()
        slinky:notify('Pistonware', 'BedWars modules could not be loaded ('..failure.stage..'). Rejoin the game to retry.', 30, 'alert')
    end)
    return failure
end

local bedwarsFn, bedwarsCompileError = bedwarsCompiled, nil
if not bedwarsFn then
    bedwarsFn, bedwarsCompileError = compileBedwarsSource(bedwarsSource, 'bedwars')
end
if not bedwarsFn then
    local failure = bootFailure('bedwars.compile', bedwarsCompileError)
	bufferCall('error', failure.stage, failure.error)
    pcall(function()
        slinky:notify('Pistonware', 'Combat modules could not be loaded (bedwars.compile). Rejoin the game to retry.', 30, 'alert')
    end)
    return failure
end

        --[[ Refuse to run the payload with no key rather than let it discover that itself: a
        failed key check is not a soft error, it puts up a modal and KICKS the player
        out of the game. Saying so here costs them their combat modules for the round instead
        of their session, and names the actual problem. ]]
if not republishKey() then
    local failure = bootFailure('bedwars.key', 'no validated key was available for the BedWars payload')
	bufferCall('error', failure.stage, failure.error)
    pcall(function()
        slinky:notify('Pistonware', 'Your key was not available when combat modules tried to load. Re-run the pistonware loader to fix this.', 30, 'alert')
    end)
    return failure
end

if shared.slinky ~= slinky then return end
local ok, result = xpcall(bedwarsFn, errorTrace)
if not ok then
    local failure = bootFailure('bedwars.payload.execute', result)
	bufferCall('error', failure.stage, failure.error)
    return failure
end
if type(result) == 'table' and result.PistonwareBootFailure then
    return result
end
return result
