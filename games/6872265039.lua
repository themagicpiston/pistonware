local pistonwareBuffer
pcall(function()
	local env = getgenv()
	pistonwareBuffer = type(env.pistonware) == 'table' and env.pistonware.buffer or nil
end)

local function bufferCall(method, event, message, details)
	local callback = type(pistonwareBuffer) == 'table' and pistonwareBuffer[method] or nil
	if type(callback) == 'function' then return callback(event, message, details) end
	if shared.PistonwareDeveloper == true then warn('[pistonware] '..tostring(message)) end
end

if not shared.PistonwareAuthenticated then
	bufferCall('warn', 'lobby.unauthenticated', 'not authenticated -- run the pistonware loader and enter your key')
	return
end

-- Solara and Xeno support. Approach credit: stxvv (gitlab.com/stxvv/bedwarsdeps).
-- Written for pistonware from BedWars' own modules; no code from that project is included.
local exec = shared.PistonwareExec
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
		--[[ Solara's require runs a module's code again instead of handing back the game's copy, and when
		that code errors (KnitClient does) the thread that called require is left at identity 2 without its
		executor capabilities: file calls, gethui and CoreGui all refuse it from then on, and pcall does not
		prevent it. A require made in a thread of its own costs only that thread, so the probe requires
		through here, and so can any later require that may fail (exec.isolatedRequire). Returns what pcall
		would; a require still running when the timeout ends counts as failed, with no error value. ]]
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
		--[[ Roblox's own require is a C function. Solara's is written in Lua (its init script): it runs a
		module's code again instead of handing back the game's copy, and Knit's code fails there with its
		error printed to the console. Where there is no debug library to reach Knit by either, nothing
		tries KnitClient through such a require: not the Live check below, not the BedWars files. ]]
		exec.NativeRequire = passes(function()
			return debug.info(require, 's') == '[C]'
		end)

		local named, name = pcall(function()
			return identifyexecutor and ({identifyexecutor()})[1] or nil
		end)
		exec.Name = (named and type(name) == 'string') and name or ''

		--[[ Roblox's own require exists everywhere: what counts is whether it hands back a game module.
		It is tried only on modules whose bodies just build a table (PlayerModule's helpers, roblox-ts'
		RuntimeLib), never on PlayerModule itself: a require that re-ran modules instead of handing back
		the game's cached ones would build a second camera and control stack from it. Asked twice, the
		same module has to come back. A place with none of these leaves require untried, which does not
		count against Full below. ]]
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
		--[[ Live: require hands back the modules the game itself runs, not fresh copies of them. Only
		BedWars' Knit can show that from here: the game registers every controller in KnitClient's
		Controllers table, which a re-run copy holds empty. Everywhere else it stays false. An injection
		made before the game registered them sees an empty table too, so the BedWars files also set it
		once Knit has started through require. ]]
		exec.Live = exec.Require and passes(function()
			local node = game:GetService('ReplicatedStorage')
			for _, step in {'rbxts_include', 'node_modules', '@easy-games', 'knit', 'src', 'Knit'} do
				node = node:FindFirstChild(step)
				if not node then return false end
			end
			local client = node:FindFirstChild('KnitClient')
			-- KnitClient waits for its Services folder, so without one this would hang
			if not (client and node:FindFirstChild('Services')) then return false end
			if not exec.NativeRequire and type(debug.getupvalue) ~= 'function' then return false end
			local loaded, knit = isolatedRequire(client)
			return loaded and type(knit) == 'table' and type(knit.Controllers) == 'table' and next(knit.Controllers) ~= nil
		end)
		-- Tried in a throwaway thread, so the check cannot leave this one at another identity.
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

		--[[ getnamecallmethod is trusted only once something proves it. hookmetamethod is how full
		executors hook namecalls, and its presence is taken as proof. Without it, a pass-through wrapper
		goes on the raw __namecall for exactly one call of our own, game:GetService, which has to report
		'GetService'; the original goes straight back whatever happens. Delta is not tested that way:
		nothing may be written to its metatable at load (see the Delta notes in 6872274481.lua). ]]
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
		exec.Debug = passes(function()
			local marker = {}
			local function probeUpvalueHolder()
				return marker
			end
			return debug.getupvalue(probeUpvalueHolder, 1) == marker
		end)
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
		-- Everything the scripts were first written against: on such an executor nothing changes.
		-- A place with no module to try require on (requireTarget nil) does not decide it.
		exec.Full = (exec.Require or requireTarget == nil) and exec.Identity and exec.Rawmeta
			and exec.Namecall and exec.HookFunction and exec.Connections and exec.Debug

		-- Takes a module out of the list on this executor and keeps the reason for a later notice.
		-- Safe before the module exists (only the reason is kept) and after it was created.
		function exec.hide(moduleName, reason)
			if type(moduleName) ~= 'string' then return end
			local hidden = shared.PistonwareHidden
			if type(hidden) ~= 'table' then
				hidden = {}
				shared.PistonwareHidden = hidden
			end
			hidden[moduleName] = reason or 'not supported on this executor'
			local vape = shared.vape
			if type(vape) == 'table' and type(vape.Modules) == 'table' and vape.Modules[moduleName] ~= nil then
				pcall(vape.Remove, vape, moduleName)
			end
		end
		return exec
	end
	exec = probeExecutor()
	shared.PistonwareExec = exec
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

local run = function(func)
	local ok, err = callWithThreadFix(func)
	if not ok then
		bufferCall('error', 'lobby.module', err, {traceback = err})
	end
end
local cloneref = cloneref or function(obj) return obj end

local playersService = cloneref(game:GetService('Players'))
local replicatedStorage = cloneref(game:GetService('ReplicatedStorage'))
local inputService = cloneref(game:GetService('UserInputService'))
local runService = cloneref(game:GetService('RunService'))
local tweenService = cloneref(game:GetService('TweenService'))
local guiService = cloneref(game:GetService('GuiService'))
-- Guarded: at a low identity CoreGui may not come back, and this is file scope.
local coreGui = (function()
	local ok, service = pcall(function()
		return cloneref(game:GetService('CoreGui'))
	end)
	return ok and service or nil
end)()

local lplr = playersService.LocalPlayer
local vape = shared.vape
local entitylib = vape.Libraries.entity
local sessioninfo = vape.Libraries.sessioninfo
local bedwars = {}

sessioninfo = sessioninfo or vape.Libraries.sessioninfo
if type(sessioninfo) ~= 'table' or type(sessioninfo.Objects) ~= 'table' or type(sessioninfo.AddItem) ~= 'function' then
	local added = 0
	sessioninfo = {
		Objects = {},
		AddItem = function(self, name, startvalue, func, saved)
			added += 1
			self.Objects[name] = {
				Function = func or function(val) return val end,
				Saved = saved == nil or saved,
				Value = startvalue or 0,
				Index = added
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
	vape.Libraries.sessioninfo = sessioninfo
end

local function notif(...)
	return vape:CreateNotification(...)
end

--[[ Knit out of reach (Solara, Xeno): the lobby's bedwars table rebuilt from the game itself, so the
modules below run as they are. Remotes come by name through exec.net, data from games/bedwars-data.json
(exec.loadData), and the store's slices from what the game pushes and answers:
  Party                    the reducer's default (you, solo), then partyInfoEvent; asked for once
                           with requestPartyInfo, which the server answers once you have a party
  Consumable.inventory     ConsumableUpdate, push-only: empty until the game sends one
  Lobby.profileData        RequestProfileData replies (ClaimRewards asks every 30 s)
  Bedwars.playerLevel      the PlayerLevel attribute, PlayerLevelUpdate and profile replies
  milestoneRewardsClaimed  MilestoneRewardUpdate, push-only
CrateAltarController reads the RewardCrate-tagged crates and sends SpawnRewardCrate/OpenRewardCrate.
UserInputController answers the server's RequestUserInputType a frame after the game does, so a type
DeviceSpoofer sets on it is the one the server keeps. ]]
local function knitlessLobby()
	local net = exec.net
	local Client = net.client(replicatedStorage.rbxts_include.node_modules['@rbxts'].net.out._NetManaged)
	local collectionService = cloneref(game:GetService('CollectionService'))
	local state = {
		--[[ The lobby's party reducer starts here too: you, leading a party of one, not queued. The
		server only has a party for you once you queue or join one, and only then answers
		requestPartyInfo; until then this default is the game's own state as well. ]]
		Party = {
			leader = {userId = lplr.UserId, name = lplr.Name, displayName = lplr.DisplayName},
			members = {},
			queueState = 0,
			outgoingInviteUserIds = {}
		},
		Consumable = {inventory = {}},
		Lobby = {},
		Bedwars = {playerLevel = tonumber(lplr:GetAttribute('PlayerLevel')) or 0}
	}
	local consumablesKnown = false
	local layer = {Knitless = true, Client = Client}

	local function listen(name, callback)
		pcall(function()
			vape:Clean(Client:Get(name):Connect(callback))
		end)
	end
	listen('ConsumableUpdate', function(data)
		if type(data) == 'table' and type(data.inventory) == 'table' then
			state.Consumable = {inventory = data.inventory, record = data.record}
			consumablesKnown = true
		end
	end)
	listen('PlayerLevelUpdate', function(level)
		if tonumber(level) then state.Bedwars.playerLevel = tonumber(level) end
	end)
	listen('MilestoneRewardUpdate', function(claimed)
		if type(claimed) == 'table' then state.Bedwars.milestoneRewardsClaimed = claimed end
	end)
	vape:Clean(lplr:GetAttributeChangedSignal('PlayerLevel'):Connect(function()
		local level = tonumber(lplr:GetAttribute('PlayerLevel'))
		if level then state.Bedwars.playerLevel = level end
	end))
	pcall(function()
		local events = net.events('@easy-games/lobby:shared/event/lobby-events@getEvents.Events')
		vape:Clean(events:FindFirstChild('partyInfoEvent').OnClientEvent:Connect(function(data)
			if type(data) == 'table' and type(data.party) == 'table' then state.Party = data.party end
		end))
		events:FindFirstChild('requestPartyInfo'):FireServer()
	end)

	local Store = {changed = {connect = function()
		return {disconnect = function() end}
	end}}
	function Store:getState()
		return state
	end
	-- The two actions the lobby modules send; everything else stays with the game's own store.
	function Store:dispatch(action)
		if type(action) ~= 'table' then return end
		if action.type == 'LobbySetProfileData' and type(action.profileData) == 'table' then
			state.Lobby.profileData = action.profileData
			if tonumber(action.profileData.level) then state.Bedwars.playerLevel = tonumber(action.profileData.level) end
		elseif action.type == 'LobbyClaimAchievementRewards' then
			local achievements = state.Lobby.profileData and state.Lobby.profileData.achievements
			local entry = type(achievements) == 'table' and achievements[action.id]
			if type(entry) == 'table' then entry.rewardsClaimed = true end
		end
	end
	layer.Store = Store
	layer.ConsumablesUnknown = function()
		return not consumablesKnown
	end

	local rewardCrate = Client:GetNamespace('RewardCrate')
	layer.CrateAltarController = {
		-- activeCrates[altarId]: the crates on that altar, as the game's component lists them.
		activeCrates = setmetatable({}, {__index = function(_, altarId)
			local crates = {}
			for _, crate in collectionService:GetTagged('RewardCrate') do
				if crate:GetAttribute('altarId') == altarId then
					table.insert(crates, {instance = crate, attributes = {
						crateId = crate:GetAttribute('crateId'),
						crateType = crate:GetAttribute('crateType'),
						owner = crate:GetAttribute('owner'),
						altarId = altarId
					}})
				end
			end
			return #crates > 0 and crates or nil
		end}),
		pickCrate = function(_, crateType, altarId)
			rewardCrate:Get('SpawnRewardCrate'):SendToServer({crateType = crateType, altarId = altarId})
		end,
		requestOpenCrate = function(_, crateId, altarId)
			rewardCrate:Get('OpenRewardCrate'):SendToServer({crateId = crateId, altarId = altarId})
		end
	}

	layer.MilestonesController = {getMilestoneRewardsClaimed = function()
		return state.Bedwars.milestoneRewardsClaimed or {}
	end}

	-- The game's own rule (user-input-controller): a gamepad, a touch screen without a mouse, or PC.
	local UserInputController = {getUserInputType = function()
		if inputService.GamepadEnabled then return 'GAMEPAD' end
		if inputService.TouchEnabled and not inputService.MouseEnabled then return 'MOBILE' end
		return 'PC'
	end}
	local realInputType = UserInputController.getUserInputType
	layer.UserInputController = UserInputController
	listen('RequestUserInputType', function()
		if UserInputController.getUserInputType == realInputType then return end
		task.defer(function()
			pcall(function()
				Client:Get('SendUserInputType'):SendToServer({userInputType = UserInputController:getUserInputType()})
			end)
		end)
	end)

	-- game-core's GameQueryUtil keeps its ignore list as this attribute, which the game's targeting reads.
	layer.QueryUtil = {
		setQueryIgnored = function(_, part, ignored)
			if ignored == nil then ignored = true end
			part:SetAttribute('gamecore_GameQueryIgnore', ignored and true or nil)
		end,
		isQueryIgnored = function(_, part)
			return part:GetAttribute('gamecore_GameQueryIgnore') == true
		end
	}

	layer.QueueMeta = exec.loadData('shared', 'QueueMeta')
	layer.CrateConsumables = exec.loadData('lobby', 'CrateConsumables')
	local crateNames = exec.loadData('lobby', 'CrateItemNames') or {}
	layer.getCrateItemMeta = function(itemType)
		local name = crateNames[itemType]
		return name and {displayName = name} or nil
	end
	-- AchievementUtil.hasUnclaimedRewards, as the game has it: achieved, rewards listed, not yet claimed.
	local ids = exec.loadData('lobby', 'AchievementIds')
	local rewards = exec.loadData('lobby', 'AchievementRewards')
	if ids and rewards then
		local meta = {}
		for id, count in rewards do
			meta[id] = {rewards = count}
		end
		layer.Achievement = {Id = ids, Meta = meta, Util = {hasUnclaimedRewards = function(id, entry)
			return type(entry) == 'table' and entry.achieved and (rewards[id] or 0) > 0 and not entry.rewardsClaimed or false
		end}}
	end
	layer.MilestoneRewards = exec.loadData('lobby', 'MilestoneRewards')
	return layer
end

run(function()
	local function dumpRemote(tab)
		local ind = table.find(tab, 'Client')
		return ind and tab[ind + 1] or ''
	end

	local KnitInit, Knit, knitError
	if exec.Debug then
		repeat
			KnitInit, Knit = pcall(function() return debug.getupvalue(require(lplr.PlayerScripts.TS.knit).setup, 9) end)
			if KnitInit then break end
			task.wait()
		until KnitInit
		if not debug.getupvalue(Knit.Start, 1) then
			repeat task.wait() until debug.getupvalue(Knit.Start, 1)
		end
	elseif exec.Require and exec.NativeRequire then
		--[[ No debug library, but Roblox's own require (exec.NativeRequire): KnitClient's own export,
		the way 6872274481.lua takes it.
		Its Controllers table is public and OnStart resolves once Knit has started. Bounded, unlike
		the path above: a require that hands back a fresh copy instead of the game's module never
		starts, and must not hold up the rest of this file. Each try runs in a thread of its own
		(exec.isolatedRequire): on Solara KnitClient errors, which would leave this thread without its
		executor capabilities. An error ends the wait, since a module that failed to load fails again. ]]
		local deadline = os.clock() + 30
		local started = false
		local observing = false
		while os.clock() < deadline and vape.Loaded ~= nil do
			local found, knitClient = pcall(function()
				return replicatedStorage.rbxts_include.node_modules['@easy-games'].knit.src.Knit.KnitClient
			end)
			local ok, client = false, nil
			if found then
				ok, client = exec.isolatedRequire(knitClient)
				if not ok and client ~= nil then
					knitError = tostring(client)
					break
				end
			end
			if ok and type(client) == 'table' and type(client.Controllers) == 'table' then
				if not observing then
					observing = true
					pcall(function()
						client.OnStart():andThen(function()
							started = true
						end)
					end)
				end
				if started and next(client.Controllers) ~= nil then
					Knit = client
					-- started through require: the game's own KnitClient (exec.Live)
					exec.Live = true
					break
				end
			end
			task.wait(0.1)
		end
	end
	if not Knit then
		--[[ Expected with no debug library and no Roblox require (Solara, Xeno): a warning, not an error
		dump on every boot. The modules below that need Knit are not offered then (needsKnit). ]]
		if knitError or (exec.Require and exec.NativeRequire) then
			bufferCall('error', 'lobby.knit', knitError and 'KnitClient does not load through require here: '..knitError
				or 'Knit did not start within 30s through require')
		else
			bufferCall('warn', 'lobby.knit', exec.Require
				and 'Knit is out of reach: require here runs module code again instead of returning the game\'s modules, and there is no debug library'
				or 'Knit is out of reach on this executor (no debug library and no require)')
		end
	end

	if Knit then
		local Client = require(replicatedStorage.TS.remotes).default.Client

		bedwars = setmetatable({
			Client = Client,
			Store = require(lplr.PlayerScripts.TS.ui.store).ClientStore
		}, {
			__index = function(self, ind)
				rawset(self, ind, Knit.Controllers[ind])
				return rawget(self, ind)
			end
		})
		-- AutoQueue's mode list. Guarded on its own: a moved module costs that list, not the
		-- controllers every other lobby module needs from this table.
		pcall(function()
			bedwars.QueueMeta = require(replicatedStorage.TS.game['queue-meta']).QueueMeta
		end)
		-- AutoGamble's reward names: the lookup the game's own crate reveal uses, guarded the same way.
		pcall(function()
			bedwars.getCrateItemMeta = require(replicatedStorage.TS['reward-crate']['crate-item']['crate-item-meta']).getCrateItemMeta
		end)
	elseif type(exec.net) == 'table' then
		local built, layer = pcall(knitlessLobby)
		if built and type(layer) == 'table' then
			bedwars = layer
		else
			bufferCall('error', 'lobby.knitless', tostring(layer))
		end
	end

	local kills = sessioninfo:AddItem('Kills')
	local beds = sessioninfo:AddItem('Beds')
	local wins = sessioninfo:AddItem('Wins')
	local games = sessioninfo:AddItem('Games')

	vape:Clean(function()
		table.clear(bedwars)
	end)
end)

for _, v in {'AntiRagdoll', 'TriggerBot', 'SilentAim', 'AutoRejoin', 'Rejoin', 'Disabler', 'Timer', 'ServerHop', 'MouseTP', 'MurderMystery', 'Swim', 'Jesus', 'Invisible', 'Desync', 'Waypoints', 'PlayerModel', 'Schematica'} do
	vape:Remove(v)
end

--[[ Two bugs in the three lines this replaces, and they hid each other.

It called vape:Remove(i), and `i` is not declared anywhere in this file -- it was an
undeclared global, so every call was Remove(nil). Remove looks its argument up in
self.Modules and bails when it finds nothing, so the loop silently did nothing at all and the
lobby kept showing the combat modules this is meant to strip.

The second bug is why it cannot simply be corrected in place: Remove ends with `tab[obj] =
nil`, so fixing the argument would have it deleting keys out of vape.Modules while this loop
is still walking vape.Modules. Removing a key other than the one `next` is currently sitting
on is undefined in Lua -- in practice it skips entries or errors mid-iteration.

Collect first, remove after: the walk finishes before anything is mutated. ]]
local toRemove = {}
for name, module in (vape.EachModule and vape:EachModule() or vape.Modules) do
	if module.Category == 'Combat' or module.Category == 'Minigames' then
		table.insert(toRemove, name)
	end
end
for _, name in toRemove do
	vape:Remove(name)
end

--[[ With neither Knit nor the knitless layer (an executor without exec.net) bedwars stays empty, so a
lobby module that runs on its controllers, remotes client or store is not offered: its run block
returns before creating it. Where either loaded this is always false. ]]
local function needsKnit(name)
	if bedwars.Client then return false end
	exec.hide(name, "needs BedWars' Knit, which this executor cannot load")
	return true
end

run(function()
	local Sprint
	local old

	--[[ Without Knit (Solara, Xeno) there is no SprintController to hook, so this does what its
	startSprinting does to your character, from outside it, and nothing to the camera: the game's sprint
	is client-only, WalkSpeed going from SprintConstants.WALK_SPEED (14) to RUN_SPEED (20), each times
	the status multiplier. So a walking speed the game set (its Sprinting attribute is off) is raised to
	the matching run speed; a speed set while the game sprints itself, or one this set, is left alone.
	Checked each Heartbeat, not from a Changed handler, which must never write properties. ]]
	local RUN_SCALE = 20 / 14
	local raisedTo, raisedOn
	local function sprintWithoutKnit(callback)
		if inputService.TouchEnabled then
			pcall(function() lplr.PlayerGui.MobileUI['2'].Visible = not callback end)
		end
		if callback then
			Sprint:Clean(runService.Heartbeat:Connect(function()
				local character = lplr.Character
				local humanoid = character and character:FindFirstChildOfClass('Humanoid')
				-- The game's own startSprinting does nothing while freecam is on.
				if not humanoid or lplr:GetAttribute('Sprinting') == true or workspace:GetAttribute('FreecamEnabled') then
					return
				end
				local speed = humanoid.WalkSpeed
				if raisedOn == humanoid and math.abs(speed - raisedTo) < 0.01 then return end
				raisedTo, raisedOn = speed * RUN_SCALE, humanoid
				humanoid.WalkSpeed = raisedTo
			end))
		else
			-- Back to the walking speed, unless the game has set another one since.
			if raisedOn and raisedOn.Parent and math.abs(raisedOn.WalkSpeed - raisedTo) < 0.01 then
				raisedOn.WalkSpeed = raisedTo / RUN_SCALE
			end
			raisedTo, raisedOn = nil, nil
		end
	end

	Sprint = vape.Categories.Combat:CreateModule({
		Name = 'Sprint',
		Tab = 'Move',
		Function = function(callback)
			if not bedwars.SprintController then
				sprintWithoutKnit(callback)
				return
			end
			if callback then
				if inputService.TouchEnabled then pcall(function() lplr.PlayerGui.MobileUI['2'].Visible = false end) end
				old = bedwars.SprintController.stopSprinting
				bedwars.SprintController.stopSprinting = function(...)
					local call = old(...)
					bedwars.SprintController:startSprinting()
					return call
				end
				Sprint:Clean(entitylib.Events.LocalAdded:Connect(function() bedwars.SprintController:stopSprinting() end))
				bedwars.SprintController:stopSprinting()
			else
				if inputService.TouchEnabled then pcall(function() lplr.PlayerGui.MobileUI['2'].Visible = true end) end
				bedwars.SprintController.stopSprinting = old
				bedwars.SprintController:stopSprinting()
			end
		end,
		Tooltip = 'Automatically sprints for you.'
	})
end)
	
run(function()
	if needsKnit('AutoGamble') then return end
	local AutoGamble

	--[[ The crate types to try, in the store's order: every crate among your consumables. Without Knit
	that list only arrives with the game's next consumable update, so until then each known crate type
	is tried in turn; a type that spawned nothing waits a minute (the server only spawns crates you own). ]]
	local tried = {}
	local function crateCandidates()
		local list = {}
		for _, v in bedwars.Store:getState().Consumable.inventory do
			if v.consumable:find('crate') then table.insert(list, v.consumable) end
		end
		if #list == 0 and bedwars.ConsumablesUnknown and bedwars.ConsumablesUnknown() then
			for crateType in bedwars.CrateConsumables or {} do
				if os.clock() - (tried[crateType] or -math.huge) >= 60 then table.insert(list, crateType) end
			end
		end
		return list
	end
	
	AutoGamble = vape.Categories.Minigames:CreateModule({
		Name = 'AutoGamble',
		Tab = 'Utility',
		Function = function(callback)
			if callback then
				AutoGamble:Clean(bedwars.Client:GetNamespace('RewardCrate'):Get('CrateOpened'):Connect(function(data)
					if data.openingPlayer == lplr then
						-- Named the way the game's reveal names it: its override, else the item's meta.
						local itemType = data.reward and data.reward.itemType
						local ok, meta = pcall(function() return bedwars.getCrateItemMeta(itemType) end)
						local name = data.visualOverrides and data.visualOverrides.displayName or (ok and type(meta) == 'table' and meta.displayName) or tostring(itemType or 'unknown')
						notif('AutoGamble', 'Won '..name, 5)
					end
				end))
	
				repeat
					if not bedwars.CrateAltarController.activeCrates[1] then
						for _, crateType in crateCandidates() do
							tried[crateType] = os.clock()
							bedwars.CrateAltarController:pickCrate(crateType, 1)
							task.wait(1.2)
							-- activeCrates[altarId] is the list of crates on that altar; open ours, as the
							-- game's own prompt does (crateId and altarId).
							local crates = bedwars.CrateAltarController.activeCrates[1]
							if crates then
								for index = #crates, 1, -1 do
									local crate = crates[index]
									local owner = crate.attributes.owner
									if owner == nil or owner == lplr.UserId then
										bedwars.CrateAltarController:requestOpenCrate(crate.attributes.crateId, 1)
										break
									end
								end
							end
							break
						end
					end
					task.wait(1)
				until not AutoGamble.Enabled
			end
		end,
		Tooltip = 'Opens your crates for you one at a time.\nTells you what each crate gave you.'
	})
end)

run(function()
	if needsKnit('AutoQueue') then return end
	local AutoQueue
	local Mode
	local Delay
	local modes, titles = {}, {}

	-- Party.queueState, from @easy-games/lobby's QueueState: NONE 0, JOINING_QUEUE 1,
	-- IN_QUEUE 2, LEAVING_QUEUE 3, MATCH_FOUND 4.
	local QUEUE_NONE, QUEUE_IN = 0, 2
	local LOBBY_EVENTS = 'events-@easy-games/lobby:shared/event/lobby-events@getEvents.Events'
	-- The usual picks lead the list; List[1] is also the dropdown's default.
	local FIRST = {bedwars_to1 = 1, bedwars_to2 = 2, bedwars_to4 = 3}

	--[[ Every queue the lobby would let you into, under the title the game gives it: whatever
	QueueMeta has that is not switched off, voice-chat only or a tournament. Read live, so a
	mode the game adds or retires comes or goes without an update here. ]]
	local function addMode(queueType, title)
		title = tostring(title):gsub('[^%w%p ]', ''):gsub('^%s+', ''):gsub('%s+$', '')
		if title == '' then title = queueType end
		if modes[title] then title = title..' ('..queueType..')' end
		modes[title] = queueType
		table.insert(titles, title)
	end

	local ranks = {}
	pcall(function()
		for queueType, meta in bedwars.QueueMeta do
			if type(meta) == 'table' and not meta.disabled and not meta.voiceChatOnly and not meta.tournament then
				addMode(queueType, meta.title or queueType)
				ranks[titles[#titles]] = FIRST[queueType] or (meta.game == 'bedwars' and 10 or 20)
			end
		end
	end)
	if #titles == 0 then
		-- QueueMeta did not load: the three standard modes, by their queue types.
		for queueType, title in {bedwars_to1 = 'BedWars (Solo)', bedwars_to2 = 'BedWars (Doubles)', bedwars_to4 = 'BedWars (Squads)'} do
			addMode(queueType, title)
			ranks[title] = FIRST[queueType]
		end
	end
	table.sort(titles, function(a, b)
		if ranks[a] ~= ranks[b] then
			return ranks[a] < ranks[b]
		end
		return a < b
	end)

	local function partyState()
		local ok, party = pcall(function()
			return bedwars.Store:getState().Party
		end)
		return ok and type(party) == 'table' and party or nil
	end

	local function lobbyRemote(name)
		local events = replicatedStorage:FindFirstChild(LOBBY_EVENTS)
		return events and events:FindFirstChild(name)
	end

	--[[ QueueController:joinQueue is what the lobby's own queue NPCs and play menu call. It
	checks party leadership and hands the request to LobbyQueueController, which fires the
	lobby-events joinQueue remote with {queueType}. That remote is fired directly when the
	controller is missing or throws. ]]
	local function joinQueue(queueType)
		local ok = pcall(function()
			bedwars.QueueController:joinQueue(queueType)
		end)
		if not ok then
			local remote = lobbyRemote('joinQueue')
			if remote then
				remote:FireServer({queueType = queueType})
			end
		end
	end

	local function leaveQueue()
		local ok = pcall(function()
			bedwars.QueueController:leaveQueue()
		end)
		if not ok then
			local remote = lobbyRemote('leaveQueue')
			if remote then
				remote:FireServer()
			end
		end
	end

	AutoQueue = vape.Categories.Utility:CreateModule({
		Name = 'AutoQueue',
		Function = function(callback)
			if not callback then return end

			local warned = false
			-- The delay counts from the moment you are out of a queue with nothing pending:
			-- enabling it, arriving in the lobby, or leaving a queue.
			local idleSince = os.clock()
			local retryAt = 0

			repeat
				local party = partyState()
				local now = os.clock()
				if not party or party.queueState ~= QUEUE_NONE then
					idleSince = now
				elseif party.leader and party.leader.userId ~= lplr.UserId then
					-- Only the leader can queue a party; the game ignores anyone else.
					if not warned then
						warned = true
						notif('AutoQueue', 'You are not the party leader, so only they can queue.', 5)
					end
					idleSince = now
				elseif now - idleSince >= Delay.Value and now >= retryAt then
					local queueType = modes[Mode.Value]
					if queueType then
						joinQueue(queueType)
						-- A request that did not take (a closed mode, a hiccup) is tried again,
						-- but never faster than every 5s.
						retryAt = now + math.max(Delay.Value, 5)
					end
				end
				task.wait(0.25)
			until not AutoQueue.Enabled
		end,
		Tooltip = 'Automatically queues you into the chosen mode.'
	})
	Mode = AutoQueue:CreateDropdown({
		Name = 'Mode',
		List = titles,
		Function = function(_, isClick)
			-- A different mode picked while already queued: leave, and the loop joins the new
			-- one after the delay. Never once a match is found.
			local party = isClick and AutoQueue.Enabled and partyState()
			if party and party.queueState == QUEUE_IN then
				leaveQueue()
			end
		end,
		Tooltip = 'The gamemode to queue for.'
	})
	Delay = AutoQueue:CreateSlider({
		Name = 'Delay',
		Min = 0,
		Max = 30,
		Default = 3,
		Decimal = 10,
		Suffix = function(val)
			return val == 1 and 'second' or 'seconds'
		end,
		Tooltip = 'How long to wait in the lobby before queueing.'
	})
end)

run(function()
	--[[ The hold runs in main.lua's queued teleport script on the match server, the only thing that
	reads the file this module writes. With no queue_on_teleport (Xeno, and Solara builds without
	it) that script never runs, so the module would do nothing at all, and it is not offered: the
	same check the match copy makes. ]]
	if not (exec.Teleport or type(queueonteleport) == 'function'
		or (type(syn) == 'table' and type(syn.queue_on_teleport) == 'function')
		or (type(fluxus) == 'table' and type(fluxus.queue_on_teleport) == 'function')) then
		exec.hide('RegionLock', 'needs queue_on_teleport')
		return
	end
	local RegionLock
	local Timeout
	local Requeue
	local httpService = cloneref(game:GetService('HttpService'))

	--[[ RegionLock's settings live in their own file, not the per-place profiles: the lobby and
	the match are different places, and this is one switch you set before queueing. main.lua's
	teleport script reads it on the match server, holds the connect, and loads you in once the
	server's region is one switched on here. The match copy of the module reads and writes the same
	file, so turning it on or off in either place is the same switch. ]]
	local FILE = 'pistonware/regionlock.txt'
	local synced, written = false, nil

	--[[ The regions BedWars hosts, one toggle each, in this order. Code is what goes in the file and
	what main.lua matches the server against; Label is what the toggle shows. Australia and New
	Zealand play on SEA servers, so that one says OCE as well (main.lua already counts OCE, AU and
	NZ as SEA). A region added here gets its toggle and its place in the file with nothing else. ]]
	local REGIONS = {
		{Code = 'NA', Label = 'NA', Tooltip = 'North America'},
		{Code = 'EU', Label = 'EU', Tooltip = 'Europe'},
		{Code = 'SEA', Label = 'SEA / OCE', Tooltip = 'Asia and Oceania (Australia and New Zealand play here)'}
	}
	-- Other names an older file can hold for one of the codes above.
	local ALIASES = {
		OCE = 'SEA', OCEANIA = 'SEA', AU = 'SEA', AUS = 'SEA', NZ = 'SEA', ASIA = 'SEA', SG = 'SEA',
		US = 'NA', USA = 'NA', CA = 'NA', UK = 'EU', GB = 'EU', EUROPE = 'EU'
	}
	local RegionToggles = {}

	local function regionCodes(onlyEnabled)
		local codes = {}
		for _, region in REGIONS do
			local toggle = RegionToggles[region.Code]
			if not onlyEnabled or (toggle and toggle.Enabled) then
				table.insert(codes, region.Code)
			end
		end
		return codes
	end

	-- Only once the file has been read back: the profile applying first must not overwrite it.
	local function writeSettings()
		-- Uninject clears vape.Loaded before it switches modules off; that off is not the user's.
		if not synced or vape.Loaded == nil then return end
		local ok, encoded = pcall(function()
			return httpService:JSONEncode({
				enabled = RegionLock.Enabled,
				-- Every region there is, as the old Regions list kept it: an older match copy loads both.
				list = regionCodes(false),
				regions = regionCodes(true),
				timeout = Timeout.Value,
				requeue = Requeue.Enabled
			})
		end)
		if ok and encoded ~= written then
			written = encoded
			pcall(writefile, FILE, encoded)
		end
	end

	RegionLock = vape.Categories.Utility:CreateModule({
		Name = 'RegionLock',
		Function = function()
			writeSettings()
		end,
		ExtraText = function()
			local codes = regionCodes(true)
			return #codes > 0 and table.concat(codes, ' ') or 'Any'
		end,
		Tooltip = 'Only plays on servers in the regions you switch on. With none on, any region is allowed.'
	})
	Timeout = RegionLock:CreateSlider({
		Name = 'Timeout',
		Min = 0,
		Max = 120,
		Default = 30,
		Function = function()
			writeSettings()
		end,
		Suffix = function(val)
			return val == 1 and 'second' or 'seconds'
		end,
		Tooltip = 'Loads anyway after this long without a region. 0 waits forever.'
	})
	Requeue = RegionLock:CreateToggle({
		Name = 'Requeue',
		Function = function()
			writeSettings()
		end,
		Tooltip = 'Queues again when the server is in the wrong region. Not in a party.'
	})
	RegionLock:CreateDivider({Text = 'Regions'})
	for _, region in REGIONS do
		RegionToggles[region.Code] = RegionLock:CreateToggle({
			Name = 'Allow '..region.Code,
			DisplayName = region.Label,
			Default = true,
			Function = function()
				writeSettings()
				vape:UpdateTextGUI()
			end,
			Tooltip = 'Plays on '..region.Tooltip..' servers.'
		})
	end

	-- Once the profile is applied, the file wins: it is the last thing set anywhere.
	task.spawn(function()
		repeat task.wait(0.5) until vape.Loaded == true or vape.Loaded == nil
		if vape.Loaded == nil then return end
		local data
		pcall(function()
			if isfile(FILE) then
				data = httpService:JSONDecode(readfile(FILE))
			end
		end)
		if type(data) == 'table' then
			-- The switched-on regions, by code or by an older name for one; anything else is passed over.
			if type(data.regions) == 'table' then
				local wanted = {}
				for _, entry in data.regions do
					local code = tostring(entry):gsub('%s+', ''):upper()
					wanted[ALIASES[code] or code] = true
				end
				for code, toggle in RegionToggles do
					if (wanted[code] == true) ~= toggle.Enabled then
						toggle:Toggle()
					end
				end
			end
			if tonumber(data.timeout) then
				Timeout:SetValue(tonumber(data.timeout))
			end
			if (data.requeue == true) ~= Requeue.Enabled then
				Requeue:Toggle()
			end
			if (data.enabled == true) ~= RegionLock.Enabled then
				RegionLock:Toggle()
			end
		end
		synced = true
		repeat
			writeSettings()
			task.wait(1)
		until vape.Loaded == nil
	end)
end)
run(function()
	if needsKnit('DeviceSpoofer') then return end
	local DeviceSpoofer
	local Device
	local spoofedType
	local realInputType
	local realGetUserInputType

	local function sendInputType(inputType)
		bedwars.Client:Get('SendUserInputType'):SendToServer({
			userInputType = inputType
		})
	end

	local function resolveInputType()
		if Device.Value == 'Random' then
			local types = {'MOBILE', 'PC', 'GAMEPAD'}
			return types[math.random(#types)]
		end
		return Device.Value:upper()
	end

	DeviceSpoofer = vape.Categories.Utility:CreateModule({
		Name = 'DeviceSpoofer',
		Function = function(callback)
			if callback then
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
		ExtraText = function()
			if Device.Value == 'Random' then
				return 'Random'..(spoofedType and ' ('..spoofedType..')' or '')
			end
			return Device.Value
		end,
		Tooltip = 'Makes the game think you are playing on another device.\nPick mobile, PC, gamepad or a random one.'
	})

	Device = DeviceSpoofer:CreateDropdown({
		Name = 'Device',
		List = {'Mobile', 'PC', 'Gamepad', 'Random'},
		Function = function(value)
			if DeviceSpoofer.Enabled then
				spoofedType = resolveInputType()
				sendInputType(spoofedType)
			end
		end
	})
end)

run(function()
	if needsKnit('ClaimRewards') then return end
	local ClaimRewards
	local DailyReward
	local ClaimAchievements
	local Milestones

	local achievement
	local milestoneRewards
	local dailyAttempted = false
	local milestoneAttempts = {}
	local nextProfileRefresh = 0

	local function getAchievement()
		if not achievement then
			if bedwars.Knitless then
				-- From the data file: these modules load Knit, which is out of reach here.
				achievement = bedwars.Achievement
			else
				local folder = replicatedStorage.TS.achievement
				achievement = {
					Id = require(folder['achievement-id']).AchievementId,
					Meta = require(folder['achievement-meta']).AchievementsMeta,
					Util = require(folder['achievement-util']).AchievementUtil
				}
			end
		end
		return achievement
	end

	local function getMilestones()
		if not milestoneRewards then
			if bedwars.Knitless then
				milestoneRewards = bedwars.MilestoneRewards
			else
				milestoneRewards = require(replicatedStorage.TS.milestones.milestones).MilestoneRewards
			end
		end
		return milestoneRewards
	end

	local function claimDaily()
		local result = bedwars.Client:Get('DailyStoreRequestPurchase'):CallServer('BEDCOIN_100', 'Robux')
		if type(result) == 'table' and result.success then
			notif('ClaimRewards', 'Claimed the daily bedcoin reward', 5)
		end
	end

	local function claimAchievements()
		local data = getAchievement()
		if not data then return end

		if os.clock() >= nextProfileRefresh then
			nextProfileRefresh = os.clock() + 30
			local profileData = bedwars.Client:Get('RequestProfileData'):CallServer(lplr)
			if profileData then
				bedwars.Store:dispatch({type = 'LobbySetProfileData', profileData = profileData})
			end
		end

		local profileData = bedwars.Store:getState().Lobby.profileData
		local achievements = profileData and profileData.achievements
		if not achievements then return end

		local claimed = 0
		for _, id in data.Id do
			local entry = achievements[id]
			if entry and data.Meta[id] and data.Util.hasUnclaimedRewards(id, entry) then
				bedwars.Client:Get('ClaimAchievementRewards'):SendToServer({id = id})
				bedwars.Store:dispatch({type = 'LobbyClaimAchievementRewards', id = id})
				claimed = claimed + 1
				task.wait(0.2)
			end
		end

		if claimed > 0 then
			notif('ClaimRewards', 'Claimed '..claimed..' achievement reward'..(claimed == 1 and '' or 's'), 5)
		end
	end

	local function claimMilestones()
		local level = bedwars.Store:getState().Bedwars.playerLevel
		local claimedList = bedwars.MilestonesController:getMilestoneRewardsClaimed()
		if not (level and claimedList) then return end

		for _, milestone in getMilestones() or {} do
			if level >= milestone.levelRequirement and not table.find(claimedList, milestone.id) and not milestoneAttempts[milestone.id] then
				milestoneAttempts[milestone.id] = true
				if bedwars.Client:Get('ClaimMilestoneReward'):CallServer(milestone.id) then
					notif('ClaimRewards', 'Claimed milestone '..(milestone.description or milestone.id), 5)
				end
			end
		end
	end

	ClaimRewards = vape.Categories.Minigames:CreateModule({
		Name = 'ClaimRewards',
		Tab = 'Utility',
		Function = function(callback)
			if callback then
				dailyAttempted = false
				nextProfileRefresh = 0
				table.clear(milestoneAttempts)

				repeat
					if DailyReward and DailyReward.Enabled and not dailyAttempted then
						dailyAttempted = true
						pcall(claimDaily)
					end
					if ClaimAchievements and ClaimAchievements.Enabled then
						pcall(claimAchievements)
					end
					if Milestones and Milestones.Enabled then
						pcall(claimMilestones)
					end
					task.wait(5)
				until not ClaimRewards.Enabled
			end
		end,
		Tooltip = 'Claims your daily, achievement and level rewards.'
	})

	DailyReward = ClaimRewards:CreateToggle({
		Name = 'Daily Reward',
		Default = true,
		Function = function(state)
			if not state then dailyAttempted = false end
		end,
		Tooltip = 'Claims the free daily store item (100 bedcoins) once per enable.'
	})

	ClaimAchievements = ClaimRewards:CreateToggle({
		Name = 'Claim Achievements',
		Default = true,
		Tooltip = 'Claims the rewards of every achievement you have unlocked but not collected.'
	})

	Milestones = ClaimRewards:CreateToggle({
		Name = 'Milestones',
		Default = true,
		Tooltip = 'Claims level milestone rewards as soon as they become available.'
	})
end)

run(function()
	local NightmareEmote
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

	--[[ Mirrors the controller: every part anchored, non-collidable and out of the query
	set, because the effect is parented to workspace and would otherwise be something the
	game can stand on, walk into and raycast against. ]]
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
		--[[ The controller drops it two studs so the ring sits at your feet rather than
		through your waist. ]]
		pcall(function() effect:PivotTo(pivot.CFrame + Vector3.new(0, -2, 0)) end)
		spin(effect, 'Outer', 360, 1.5)
		spin(effect, 'Middle', -360, 12.5)

		--[[ The emote's own soundsOnBegin entry: locker.emotes.nightmare_1_sounds_on_begin_sound,
		which the meta marks looped -- it is a drone that runs under the whole emote, not a
		one-shot sting, so it has to be stopped with everything else rather than left to
		finish. Parented to the torso so it is positional and dies with the character even if
		stopEmote never gets to run. ]]
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

		--[[ Ends the way a real emote ends: the first step you take, or dying. Both are
		checked rather than only one, because a respawn destroys the character out from
		under the animation but leaves the effect parented to workspace forever. ]]
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

	NightmareEmote = vape.Categories.Utility:CreateModule({
		Name = 'NightmareEmote',
		Tab = 'Visual',
		Function = function(callback)
			if not callback then return end

			playEmote()

			--[[ Deferred rather than called straight from here: this IS the enable callback,
			and toggling from inside it would re-enter the module's own state machine
			mid-transition. One step later the enable has settled and the off is a normal
			toggle. ]]
			task.defer(function()
				if NightmareEmote.Enabled then
					NightmareEmote:Toggle(nil, true)
				end
			end)
		end,
		Tooltip = 'Plays the Nightmare emote, visible only to you.\nEnds when you move, jump or die.'
	})

	vape:Clean(function() stopEmote() end)
end)

run(function()
	local UICleanup
	--[[ Topbar Position. The BedWars top bar -- its row of buttons, the Settings menu that drops
	from them and, in a match, the scores and timer beside them -- sits at the right of the strip
	Roblox leaves free along the top of the screen. Middle centres that whole row on the screen
	instead. The game's own app draws it and moves it again whenever its size changes, so each
	move of the game's is kept (it is where Default puts it back) and the row is centred again
	straight after.

	On a phone the row also keeps room for the Pistonware button wherever that is: beside the
	buttons (Button Next To Topbar) or, by default, in the corner at the right end of the strip.
	The corner's room is kept with UI Cleanup off too, as that is where the button goes then. ]]
	local TopbarPosition
	local NextToTopbar
	local topbar = {
		Original = setmetatable({}, {__mode = 'k'}),
		Placed = setmetatable({}, {__mode = 'k'}),
		Watched = setmetatable({}, {__mode = 'k'}),
		Connections = {}
	}

	function topbar.middle()
		return UICleanup ~= nil and UICleanup.Enabled and TopbarPosition ~= nil and TopbarPosition.Value == 'Middle'
	end

	-- Docked beside the buttons only while UI Cleanup is on with Button Next To Topbar.
	function topbar.docked()
		return UICleanup ~= nil and UICleanup.Enabled and NextToTopbar ~= nil and NextToTopbar.Enabled
	end

	-- The strip Roblox leaves free along the top of the screen, as screen x, where the client has one.
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

	--[[ The room the mobile button takes in the row -- its width and the 7 px the GUI keeps from the
	game's buttons -- or 0 where there is no button (a PC), and whether the GUI wants it in the
	corner. A GUI without the corner always docks it. ]]
	function topbar.vapeButton()
		local button = vape.VapeButton
		if topbar.Unloaded or not (button and button.Parent) then
			return 0, false
		end
		return math.max(button.AbsoluteSize.X, 32) + 7, vape.SetVapeButtonDocked ~= nil and not vape.VapeButtonDocked
	end

	-- Whether there is anything to lay out: Middle, or room to keep for the button where it is.
	function topbar.active()
		if topbar.Unloaded then return false end
		if topbar.middle() then return true end
		local room, corner = topbar.vapeButton()
		return room > 0 and (corner or (UICleanup ~= nil and UICleanup.Enabled))
	end

	-- Several changes in one frame (a resize moves and resizes everything) place it once.
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

	-- Where the game last put a piece: where it is now, unless that is where this put it.
	function topbar.origin(object)
		local current = object.Position
		if current ~= topbar.Placed[object] then
			topbar.Original[object] = current
		end
		return topbar.Original[object]
	end

	-- Puts a piece so its right edge is at `right` (a screen x), at the height the game gave it.
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

	--[[ The button's room, made inside the row of buttons: padding on its right for the corner, on
	its left beside them. The game lays the row out round it as it would round one more button of
	its own -- the scores and timer move over, and on a full bar everything shrinks to fit -- so
	nothing is moved over the scores, in Default or in Middle. The row is drawn under a UIScale, so
	the padding is set in its units. Returns the room on the right, on screen. ]]
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

	-- The GUI places its button again now, not on its next once-a-second check.
	function topbar.nudge()
		if not vape.PlaceVapeButton then return end
		vape.PlaceVapeButton()
		--[[ And once more after this frame's layout pass. The call above reads the row as it was
		before the change that asked for it (padding moved from one side to the other, a Middle
		move), and moving the padding leaves the row's AbsoluteSize as it was, so no signal comes
		after the reflow to correct it -- the button would wait for the GUI's once-a-second check,
		sitting on the scores or a button until then. Coalesced: one follow-up however many calls. ]]
		if topbar.Renudge then return end
		topbar.Renudge = true
		task.delay(0, function()
			topbar.Renudge = false
			if not topbar.Unloaded and vape.PlaceVapeButton then
				vape.PlaceVapeButton()
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
		--[[ The mobile button's room, on the side of the row the button is on. The GUI measures the
		corner from the strip, so without one the button docks and its room goes beside the buttons.
		The corner keeps its room with UI Cleanup off too. ]]
		local strip, stripEnd = topbar.strip()
		local room, corner = topbar.vapeButton()
		corner = corner and strip ~= nil
		if not (corner or (UICleanup ~= nil and UICleanup.Enabled)) then
			room = 0
		end
		local cornerRoom = topbar.pad(buttons, corner and 'Right' or 'Left', room)
		if not topbar.middle() then
			-- Default: everything where the game puts it, with the button's room in the row.
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
		--[[ The mobile Pistonware button's room is part of the row's own width (see pad), so the
		scores and timer stop short of it rather than running under it: beside the buttons the
		button follows them, 7 px to their left, and in the corner the row stops short of it. ]]
		local width = buttons.AbsoluteSize.X + (statsWidth > 0 and statsWidth + 8 or 0)
		local left, area = appGui.AbsolutePosition.X, appGui.AbsoluteSize.X
		if area <= 0 then return end
		--[[ Centred on the screen, but kept inside the strip Roblox leaves free so it never runs under
		Roblox's buttons. That strip is TopbarInset where the client reports one; TopBarAppGui itself
		covers the whole screen. ]]
		local low, high = left, left + area
		if strip then
			low, high = strip, stripEnd
		end
		--[[ For the corner the row ends 12 px in from the end of the strip, as the game keeps it, so
		the room at its right end is under the corner button and the buttons stop 7 px short of it.
		The room is empty, so what is centred is the rest. The game sizes the row and the scores to
		the strip less 24 px, so this always fits. ]]
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
		-- The Settings menu hangs from the right end of the buttons, as it does by default.
		for _, child in appGui:GetChildren() do
			if child ~= buttons and child:IsA('GuiObject') and topbar.origin(child).X == UDim.new(1, -12) then
				topbar.move(child, appGui, right - cornerRoom)
			end
		end
		topbar.nudge()
	end

	-- Back where the game last put each piece, unless the game has moved it itself since.
	function topbar.unplace()
		for object, original in topbar.Original do
			if object.Parent and object.Position == topbar.Placed[object] then
				object.Position = original
			end
		end
		table.clear(topbar.Original)
		table.clear(topbar.Placed)
	end

	-- All of it undone: nothing watched, nothing moved, no room kept.
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
		if vape.SetVapeButtonDocked and not topbar.Unloaded then
			vape:SetVapeButtonDocked(topbar.docked())
		end
		if not topbar.active() then
			topbar.restore()
			return
		end
		if not topbar.Hooked then
			topbar.Hooked = true
			local playerGui = lplr:FindFirstChildOfClass('PlayerGui')
			if playerGui then
				-- The game builds the bar again when it remounts its HUD.
				table.insert(topbar.Connections, playerGui.ChildAdded:Connect(function(child)
					if child.Name == 'TopBarAppGui' or child.Name == 'TopBarStatsGui' then
						topbar.queue()
					end
				end))
			end
			-- Roblox's own buttons coming and going changes the free strip.
			pcall(function()
				table.insert(topbar.Connections, guiService:GetPropertyChangedSignal('TopbarInset'):Connect(topbar.queue))
			end)
		end
		topbar.queue()
	end

	UICleanup = vape.Legit:CreateModule({
		Name = 'UI Cleanup',
		Function = function()
			topbar.refresh()
		end,
		Tooltip = 'Tidies up the BedWars HUD and removes clutter.\nIn the lobby it covers the top bar.'
	})
	TopbarPosition = UICleanup:CreateDropdown({
		Name = 'Topbar Position',
		List = {'Default', 'Middle'},
		Function = function()
			topbar.refresh()
		end,
		Tooltip = 'Where the BedWars top bar sits: on the right (Default) or centred at the top of the screen (Middle).'
	})
	NextToTopbar = UICleanup:CreateToggle({
		Name = 'Button Next To Topbar',
		Function = function()
			topbar.refresh()
		end,
		Tooltip = 'Puts the mobile menu button next to the top bar instead of in the top-right corner.'
	})
	-- The corner's room is kept without UI Cleanup too; on unload everything goes back.
	topbar.refresh()
	vape:Clean(function()
		topbar.Unloaded = true
		topbar.restore()
	end)
end)
