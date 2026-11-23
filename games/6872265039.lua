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
--[[ Probes what this executor can do and keeps the answers in shared.PistonwareExec. exec.hide takes a
module out of the menu and keeps the reason for a later notice, before or after the module exists.

Solara's require runs a module's code again instead of handing back the game's copy, and when that
code errors (KnitClient does) the calling thread is left at identity 2 without its executor
capabilities: file calls, gethui and CoreGui refuse it from then on, pcall or not.
exec.isolatedRequire makes each such require in a thread of its own; one still running at the
timeout counts as failed. NativeRequire: require is Roblox's own C function. Require counts only
when the same module comes back twice, tried on modules that just build a table, never on
PlayerModule, which a re-running require would turn into a second camera and control stack. Live:
require returns the modules the game runs, which only BedWars' KnitClient can show (a re-run copy
has an empty Controllers table); the BedWars files also set it once Knit has started.

getnamecallmethod is trusted when hookmetamethod exists, or when a pass-through wrapper on the raw
__namecall reports 'GetService' for one game:GetService call; nothing may be written to Delta's
metatable at load, so Delta is not tested. Full: every capability the scripts assume; a place with
no module to try require on does not decide it. ]]
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
local slinky = shared.slinky
local combat = slinky.categories.Combat
local utility = slinky.categories.Utility
local minigames = slinky.categories.Minigames
local legit = slinky.legit
local entitylib = slinky.libraries.entity
local sessioninfo = slinky.libraries.sessioninfo
local bedwars = {}

sessioninfo = sessioninfo or slinky.libraries.sessioninfo
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
	slinky.libraries.sessioninfo = sessioninfo
end

local function notif(...)
	return slinky:notify(...)
end

--[[ Builds the lobby's bedwars table without Knit (Solara, Xeno) from the game itself, so the lobby
modules run unchanged. Remotes come by name through exec.net, static data from
games/bedwars-data.json through exec.loadData, and the store's state from what the game pushes and
answers.

Party starts as the lobby reducer's own default, you leading a party of one, not queued: the server
only has a party for you once you queue or join one, and only then answers requestPartyInfo.
Consumable.inventory (ConsumableUpdate) and the claimed milestones (MilestoneRewardUpdate) are
push-only and stay empty until the game sends them. Lobby.profileData comes from the
RequestProfileData replies ClaimRewards dispatches (every 30 s at most), the player level from the
PlayerLevel attribute, PlayerLevelUpdate and those replies. Store:dispatch handles only the two
actions the lobby modules send.

CrateAltarController lists the RewardCrate-tagged crates by their altarId attribute.
UserInputController follows the game's rule: a gamepad, a touch screen without a mouse, or PC. Once
its getUserInputType is replaced (DeviceSpoofer), it answers the server's RequestUserInputType
deferred, after the game's own answer, so that type is the one the server keeps. QueryUtil uses the
gamecore_GameQueryIgnore attribute, game-core's GameQueryUtil ignore list that the game's targeting
reads. ]]
local function knitlessLobby()
	local net = exec.net
	local client = net.client(replicatedStorage.rbxts_include.node_modules['@rbxts'].net.out._NetManaged)
	local collectionService = cloneref(game:GetService('CollectionService'))
	local state = {
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
	local layer = {Knitless = true, Client = client}

	local function listen(name, callback)
		pcall(function()
			slinky:clean(client:Get(name):Connect(callback))
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
	slinky:clean(lplr:GetAttributeChangedSignal('PlayerLevel'):Connect(function()
		local level = tonumber(lplr:GetAttribute('PlayerLevel'))
		if level then state.Bedwars.playerLevel = level end
	end))
	pcall(function()
		local events = net.events('@easy-games/lobby:shared/event/lobby-events@getEvents.Events')
		slinky:clean(events:FindFirstChild('partyInfoEvent').OnClientEvent:Connect(function(data)
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

	local rewardCrate = client:GetNamespace('RewardCrate')
	layer.CrateAltarController = {
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

	local userInputController = {getUserInputType = function()
		if inputService.GamepadEnabled then return 'GAMEPAD' end
		if inputService.TouchEnabled and not inputService.MouseEnabled then return 'MOBILE' end
		return 'PC'
	end}
	local realInputType = userInputController.getUserInputType
	layer.UserInputController = userInputController
	listen('RequestUserInputType', function()
		if userInputController.getUserInputType == realInputType then return end
		task.defer(function()
			pcall(function()
				client:Get('SendUserInputType'):SendToServer({userInputType = userInputController:getUserInputType()})
			end)
		end)
	end)

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

--[[ Finds BedWars' Knit and builds the lobby's bedwars table from it: Client is the remotes client,
Store the UI's ClientStore, and every other field is looked up in knit.Controllers on first use.

With the debug library Knit comes from an upvalue of the knit module's setup, and the wait for its
start has no limit. Without one but with Roblox's own require (exec.NativeRequire), KnitClient's own
export is required, as 6872274481.lua does, and waited on for at most 30 s: a require that hands
back a fresh copy never starts and must not hold up the rest of the file. Each try runs through
exec.isolatedRequire, because on Solara KnitClient errors and would leave this thread without its
executor capabilities; an error ends the wait, since a module that failed to load fails again. Knit
started that way sets exec.Live.

QueueMeta (AutoQueue's mode list) and getCrateItemMeta (AutoGamble's reward names, the lookup the
game's crate reveal uses) are each required under their own pcall, so a moved module costs only
that. Without Knit the knitless layer from knitlessLobby is used where exec.net exists. Knit out of
reach (no debug library and no Roblox require) is logged as a warning, not an error, since it is
expected on Solara and Xeno; needsKnit then hides the modules that need it. ]]
run(function()
	local function dumpRemote(tab)
		local ind = table.find(tab, 'Client')
		return ind and tab[ind + 1] or ''
	end

	local knitInit, knit, knitError
	if exec.Debug then
		repeat
			knitInit, knit = pcall(function() return debug.getupvalue(require(lplr.PlayerScripts.TS.knit).setup, 9) end)
			if knitInit then break end
			task.wait()
		until knitInit
		if not debug.getupvalue(knit.Start, 1) then
			repeat task.wait() until debug.getupvalue(knit.Start, 1)
		end
	elseif exec.Require and exec.NativeRequire then
		local deadline = os.clock() + 30
		local started = false
		local observing = false
		while os.clock() < deadline and slinky.loaded ~= nil do
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
					knit = client
					exec.Live = true
					break
				end
			end
			task.wait(0.1)
		end
	end
	if not knit then
		if knitError or (exec.Require and exec.NativeRequire) then
			bufferCall('error', 'lobby.knit', knitError and 'KnitClient does not load through require here: '..knitError
				or 'Knit did not start within 30s through require')
		else
			bufferCall('warn', 'lobby.knit', exec.Require
				and 'Knit is out of reach: require here runs module code again instead of returning the game\'s modules, and there is no debug library'
				or 'Knit is out of reach on this executor (no debug library and no require)')
		end
	end

	if knit then
		local client = require(replicatedStorage.TS.remotes).default.Client

		bedwars = setmetatable({
			Client = client,
			Store = require(lplr.PlayerScripts.TS.ui.store).ClientStore
		}, {
			__index = function(self, ind)
				rawset(self, ind, knit.Controllers[ind])
				return rawget(self, ind)
			end
		})
		pcall(function()
			bedwars.QueueMeta = require(replicatedStorage.TS.game['queue-meta']).QueueMeta
		end)
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

	slinky:clean(function()
		table.clear(bedwars)
	end)
end)

for _, v in {'AntiRagdoll', 'TriggerBot', 'SilentAim', 'AutoRejoin', 'Rejoin', 'Disabler', 'Timer', 'ServerHop', 'MouseTP', 'MurderMystery', 'Swim', 'Jesus', 'Invisible', 'Desync', 'Waypoints', 'PlayerModel', 'Schematica'} do
	slinky:remove(v)
end

--[[ Two bugs in the three lines this replaces, and they hid each other.

It called slinky:Remove(i), and `i` is not declared anywhere in this file -- it was an
undeclared global, so every call was Remove(nil). Remove looks its argument up in
self.Modules and bails when it finds nothing, so the loop silently did nothing at all and the
lobby kept showing the combat modules this is meant to strip.

The second bug is why it cannot simply be corrected in place: Remove ends with `tab[obj] =
nil`, so fixing the argument would have it deleting keys out of slinky.Modules while this loop
is still walking slinky.Modules. Removing a key other than the one `next` is currently sitting
on is undefined in Lua -- in practice it skips entries or errors mid-iteration.

Collect first, remove after: the walk finishes before anything is mutated. ]]
local toRemove = {}
for name, module in (slinky.eachModule and slinky:eachModule() or slinky.modules) do
	if module.category == 'Combat' or module.category == 'Minigames' then
		table.insert(toRemove, name)
	end
end
for _, name in toRemove do
	slinky:remove(name)
end

--[[ With neither Knit nor the knitless layer (an executor without exec.net) bedwars stays empty, so a
lobby module that runs on its controllers, remotes client or store is not offered: its run block
returns before creating it. Where either loaded this is always false. ]]
local function needsKnit(name)
	if bedwars.Client then return false end
	exec.hide(name, "needs BedWars' Knit, which this executor cannot load")
	return true
end

--[[ Sprint
Keeps you sprinting: the game's SprintController starts sprinting again whenever it stops.

Without Knit (Solara, Xeno) there is no controller to hook, so the module does what startSprinting
does to your character from outside it. The game's sprint is client-only, WalkSpeed going from
SprintConstants.WALK_SPEED (14) to RUN_SPEED (20), each times the status multiplier, so a walking
speed the game set is raised by 20/14 and a speed set while the game sprints you itself (its
Sprinting attribute), or one this set, is left alone. Nothing changes during freecam. It is checked
each Heartbeat, not from a Changed handler, which must never write properties.

The game's sprint also tweens the camera to FovController:getFOV() * 1.1 (RUN_FOV_MULT) over 0.1 s
while you move and back when you stop. Without Knit there is no FovController, and the FOV module
(universal.lua) writes the camera every frame while it is on, so the view is widened only while that
module is off, from the FOV the camera rests on, and restored only over its own widening still on
screen. Each edge sets the FOV rather than multiplying the live value, which would compound frame on
frame. On touch screens the game's mobile sprint button is hidden while the module is on. ]]
run(function()
	local sprint
	local old

	local RUN_SCALE = 20 / 14
	local RUN_FOV_MULT = 1.1
	local raisedTo, raisedOn
	local fovBase, fovTween
	local function fovModuleOwns()
		local fov = slinky.modules and slinky.modules.FOV
		return fov ~= nil and fov.enabled == true
	end
	local function tweenSprintFov(target)
		if fovTween then pcall(function() fovTween:Cancel() end) end
		local camera = workspace.CurrentCamera
		if not (camera and target) then fovTween = nil; return end
		fovTween = tweenService:Create(camera, TweenInfo.new(0.1, Enum.EasingStyle.Linear), {FieldOfView = target})
		fovTween:Play()
	end
	local function widenFov()
		if fovBase or fovModuleOwns() then return end
		local camera = workspace.CurrentCamera
		if not camera then return end
		fovBase = camera.FieldOfView
		tweenSprintFov(fovBase * RUN_FOV_MULT)
	end
	local function restoreFov()
		local base, tween = fovBase, fovTween
		fovBase, fovTween = nil, nil
		local camera = workspace.CurrentCamera
		if not (camera and base) or fovModuleOwns() then return end
		local playing = tween ~= nil and tween.PlaybackState == Enum.PlaybackState.Playing
		if not playing and math.abs(camera.FieldOfView - base * RUN_FOV_MULT) > 0.05 then return end
		tweenSprintFov(base)
	end
	local function sprintWithoutKnit(callback)
		if inputService.TouchEnabled then
			pcall(function() lplr.PlayerGui.MobileUI['2'].Visible = not callback end)
		end
		if callback then
			sprint:clean(runService.Heartbeat:Connect(function()
				local character = lplr.Character
				local humanoid = character and character:FindFirstChildOfClass('Humanoid')
				if not humanoid or lplr:GetAttribute('Sprinting') == true or workspace:GetAttribute('FreecamEnabled') then
					if fovBase then restoreFov() end
					return
				end
				local speed = humanoid.WalkSpeed
				if not (raisedOn == humanoid and math.abs(speed - raisedTo) < 0.01) then
					raisedTo, raisedOn = speed * RUN_SCALE, humanoid
					humanoid.WalkSpeed = raisedTo
				end
				if humanoid.MoveDirection.Magnitude > 0.01 then
					widenFov()
				elseif fovBase then
					restoreFov()
				end
			end))
		else
			if raisedOn and raisedOn.Parent and math.abs(raisedOn.WalkSpeed - raisedTo) < 0.01 then
				raisedOn.WalkSpeed = raisedTo / RUN_SCALE
			end
			raisedTo, raisedOn = nil, nil
			restoreFov()
		end
	end

	sprint = combat:module('Sprint', {
		tab = 'Move',
		toggled = function(on)
			if not bedwars.SprintController then
				sprintWithoutKnit(on)
				return
			end
			if on then
				if inputService.TouchEnabled then pcall(function() lplr.PlayerGui.MobileUI['2'].Visible = false end) end
				old = bedwars.SprintController.stopSprinting
				bedwars.SprintController.stopSprinting = function(...)
					local call = old(...)
					bedwars.SprintController:startSprinting()
					return call
				end
				sprint:clean(entitylib.Events.LocalAdded:Connect(function() bedwars.SprintController:stopSprinting() end))
				bedwars.SprintController:stopSprinting()
			else
				if inputService.TouchEnabled then pcall(function() lplr.PlayerGui.MobileUI['2'].Visible = true end) end
				bedwars.SprintController.stopSprinting = old
				bedwars.SprintController:stopSprinting()
			end
		end,
		about = 'Automatically sprints for you.'
	})
end)
	
--[[ AutoGamble
Opens your reward crates one at a time on altar 1 and tells you what each one gave. The crate types
come from your consumables in the store; without Knit that list only arrives with the game's next
consumable update, so until then each known crate type is tried in turn, and a type that spawned
nothing waits a minute, since the server only spawns crates you own. A spawned crate is opened by
its crateId and altarId, as the game's own prompt does, and the reward is named the way the game's
reveal names it: its visual override, else the item's meta. ]]
run(function()
	if needsKnit('AutoGamble') then return end
	local autoGamble

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
	
	autoGamble = minigames:module('AutoGamble', {
		tab = 'Utility',
		toggled = function(on)
			if on then
				autoGamble:clean(bedwars.Client:GetNamespace('RewardCrate'):Get('CrateOpened'):Connect(function(data)
					if data.openingPlayer == lplr then
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
				until not autoGamble.enabled
			end
		end,
		about = 'Opens your crates for you one at a time.\nTells you what each crate gave you.'
	})
end)

--[[ AutoQueue
Queues you into the chosen mode once you have been out of a queue for the set delay, counted from
enabling it, arriving in the lobby or leaving a queue. The modes are every queue in QueueMeta that
is not disabled, voice-chat only or a tournament, read live so modes the game adds or retires follow
it, with Solo, Doubles and Squads first; without QueueMeta those three are offered by their queue
types.

Party.queueState follows @easy-games/lobby's QueueState: NONE 0, JOINING_QUEUE 1, IN_QUEUE 2,
LEAVING_QUEUE 3, MATCH_FOUND 4. Only the party leader can queue; the game ignores anyone else.
Joining goes through QueueController:joinQueue, which the lobby's queue NPCs and play menu call (it
checks party leadership and fires the lobby-events joinQueue remote with {queueType}); that remote
is fired directly when the controller is missing or throws. A request that did not take is retried
no faster than every 5 s. Picking another mode while in a queue leaves it so the loop joins the new
one, never once a match is found. ]]
run(function()
	if needsKnit('AutoQueue') then return end
	local autoQueue
	local mode
	local delaySlider
	local modes, titles = {}, {}

	local QUEUE_NONE, QUEUE_IN = 0, 2
	local LOBBY_EVENTS = 'events-@easy-games/lobby:shared/event/lobby-events@getEvents.Events'
	local FIRST = {bedwars_to1 = 1, bedwars_to2 = 2, bedwars_to4 = 3}

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

	autoQueue = utility:module('AutoQueue', {
		toggled = function(on)
			if not on then return end

			local warned = false
			local idleSince = os.clock()
			local retryAt = 0

			repeat
				local party = partyState()
				local now = os.clock()
				if not party or party.queueState ~= QUEUE_NONE then
					idleSince = now
				elseif party.leader and party.leader.userId ~= lplr.UserId then
					if not warned then
						warned = true
						notif('AutoQueue', 'You are not the party leader, so only they can queue.', 5)
					end
					idleSince = now
				elseif now - idleSince >= delaySlider.value and now >= retryAt then
					local queueType = modes[mode.value]
					if queueType then
						joinQueue(queueType)
						retryAt = now + math.max(delaySlider.value, 5)
					end
				end
				task.wait(0.25)
			until not autoQueue.enabled
		end,
		about = 'Automatically queues you into the chosen mode.'
	})
	mode = autoQueue:dropdown('Mode', {
		choices = titles,
		changed = function(_, isClick)
			local party = isClick and autoQueue.enabled and partyState()
			if party and party.queueState == QUEUE_IN then
				leaveQueue()
			end
		end,
		about = 'The gamemode to queue for.'
	})
	delaySlider = autoQueue:slider('Delay', {
		min = 0,
		max = 30,
		default = 3,
		decimal = 10,
		suffix = function(val)
			return val == 1 and 'second' or 'seconds'
		end,
		about = 'How long to wait in the lobby before queueing.'
	})
end)

--[[ RegionLock
Only lets you load into a match server in a region you switched on; with none on, any region is
allowed. The hold itself runs in main.lua's queued teleport script on the match server, the only
reader of the settings file written here, so without queue_on_teleport (Xeno, and Solara builds
without it) the module is not offered, the same check the match copy makes.

The settings live in pistonware/regionlock.txt rather than the per-place profiles, since the lobby
and the match are different places; the match copy reads and writes the same file, so it is one
switch in both. Region codes are what main.lua matches the server against. Australia and New Zealand
play on SEA servers (main.lua counts OCE, AU and NZ as SEA), and other names an older file holds are
mapped through ALIASES. The file is read back once the profile has applied and then wins; nothing is
written before that, nor once uninject has cleared slinky.loaded, so the switch-off on unload is not
saved. The full region list is written alongside the switched-on ones for an older match copy. ]]
run(function()
	if not (exec.Teleport or type(queueonteleport) == 'function'
		or (type(syn) == 'table' and type(syn.queue_on_teleport) == 'function')
		or (type(fluxus) == 'table' and type(fluxus.queue_on_teleport) == 'function')) then
		exec.hide('RegionLock', 'needs queue_on_teleport')
		return
	end
	local regionLock
	local timeout
	local requeue
	local httpService = cloneref(game:GetService('HttpService'))

	local FILE = 'pistonware/regionlock.txt'
	local synced, written = false, nil

	local REGIONS = {
		{Code = 'NA', Label = 'NA', Tooltip = 'North America'},
		{Code = 'EU', Label = 'EU', Tooltip = 'Europe'},
		{Code = 'SEA', Label = 'SEA / OCE', Tooltip = 'Asia and Oceania (Australia and New Zealand play here)'}
	}
	local ALIASES = {
		OCE = 'SEA', OCEANIA = 'SEA', AU = 'SEA', AUS = 'SEA', NZ = 'SEA', ASIA = 'SEA', SG = 'SEA',
		US = 'NA', USA = 'NA', CA = 'NA', UK = 'EU', GB = 'EU', EUROPE = 'EU'
	}
	local regionToggles = {}

	local function regionCodes(onlyEnabled)
		local codes = {}
		for _, region in REGIONS do
			local toggle = regionToggles[region.Code]
			if not onlyEnabled or (toggle and toggle.enabled) then
				table.insert(codes, region.Code)
			end
		end
		return codes
	end

	local function writeSettings()
		if not synced or slinky.loaded == nil then return end
		local ok, encoded = pcall(function()
			return httpService:JSONEncode({
				enabled = regionLock.enabled,
				list = regionCodes(false),
				regions = regionCodes(true),
				timeout = timeout.value,
				requeue = requeue.enabled
			})
		end)
		if ok and encoded ~= written then
			written = encoded
			pcall(writefile, FILE, encoded)
		end
	end

	regionLock = utility:module('RegionLock', {
		toggled = function()
			writeSettings()
		end,
		info = function()
			local codes = regionCodes(true)
			return #codes > 0 and table.concat(codes, ' ') or 'Any'
		end,
		about = 'Only plays on servers in the regions you switch on. With none on, any region is allowed.'
	})
	timeout = regionLock:slider('Timeout', {
		min = 0,
		max = 120,
		default = 30,
		changed = function()
			writeSettings()
		end,
		suffix = function(val)
			return val == 1 and 'second' or 'seconds'
		end,
		about = 'Loads anyway after this long without a region. 0 waits forever.'
	})
	requeue = regionLock:toggle('Requeue', {
		changed = function()
			writeSettings()
		end,
		about = 'Queues again when the server is in the wrong region. Not in a party.'
	})
	regionLock:divider('Regions')
	for _, region in REGIONS do
		regionToggles[region.Code] = regionLock:toggle('Allow '..region.Code, {
			label = region.Label,
			default = true,
			changed = function()
				writeSettings()
				slinky:updateOverlay()
			end,
			about = 'Plays on '..region.Tooltip..' servers.'
		})
	end

	task.spawn(function()
		repeat task.wait(0.5) until slinky.loaded == true or slinky.loaded == nil
		if slinky.loaded == nil then return end
		local data
		pcall(function()
			if isfile(FILE) then
				data = httpService:JSONDecode(readfile(FILE))
			end
		end)
		if type(data) == 'table' then
			if type(data.regions) == 'table' then
				local wanted = {}
				for _, entry in data.regions do
					local code = tostring(entry):gsub('%s+', ''):upper()
					wanted[ALIASES[code] or code] = true
				end
				for code, toggle in regionToggles do
					if (wanted[code] == true) ~= toggle.enabled then
						toggle:flip()
					end
				end
			end
			if tonumber(data.timeout) then
				timeout:set(tonumber(data.timeout))
			end
			if (data.requeue == true) ~= requeue.enabled then
				requeue:flip()
			end
			if (data.enabled == true) ~= regionLock.enabled then
				regionLock:flip()
			end
		end
		synced = true
		repeat
			writeSettings()
			task.wait(1)
		until slinky.loaded == nil
	end)
end)
--[[ DeviceSpoofer
Makes the game think you are playing on another device. Pick mobile, PC, gamepad or a random one. ]]
run(function()
	if needsKnit('DeviceSpoofer') then return end
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

--[[ ClaimRewards
Claims the free daily store item (100 bedcoins, once per enable), unclaimed achievement rewards and
level milestone rewards, checking every 5 s. Profile data is asked of the server at most every 30 s
and dispatched into the store, where the achievement check reads it; each milestone is tried once
per enable. Without Knit the achievement and milestone tables come from the data file, since the
game's own modules for them load Knit. ]]
run(function()
	if needsKnit('ClaimRewards') then return end
	local claimRewards
	local dailyReward
	local claimAchievementsToggle
	local milestones

	local achievement
	local milestoneRewards
	local dailyAttempted = false
	local milestoneAttempts = {}
	local nextProfileRefresh = 0

	local function getAchievement()
		if not achievement then
			if bedwars.Knitless then
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

	claimRewards = minigames:module('ClaimRewards', {
		tab = 'Utility',
		toggled = function(on)
			if on then
				dailyAttempted = false
				nextProfileRefresh = 0
				table.clear(milestoneAttempts)

				repeat
					if dailyReward and dailyReward.enabled and not dailyAttempted then
						dailyAttempted = true
						pcall(claimDaily)
					end
					if claimAchievementsToggle and claimAchievementsToggle.enabled then
						pcall(claimAchievements)
					end
					if milestones and milestones.enabled then
						pcall(claimMilestones)
					end
					task.wait(5)
				until not claimRewards.enabled
			end
		end,
		about = 'Claims your daily, achievement and level rewards.'
	})

	dailyReward = claimRewards:toggle('Daily Reward', {
		default = true,
		changed = function(state)
			if not state then dailyAttempted = false end
		end,
		about = 'Claims the free daily store item (100 bedcoins) once per enable.'
	})

	claimAchievementsToggle = claimRewards:toggle('Claim Achievements', {
		default = true,
		about = 'Claims the rewards of every achievement you have unlocked but not collected.'
	})

	milestones = claimRewards:toggle('Milestones', {
		default = true,
		about = 'Claims level milestone rewards as soon as they become available.'
	})
end)

--[[ NightmareEmote
Plays the Nightmare emote, visible only to you: the NightmareEmote effect from Assets.Effects, its
looped animation and its sound. As in the game's controller, every part of the effect is anchored,
non-collidable and out of the query set, since it is parented to workspace and the game would
otherwise stand on, walk into and raycast against it; it is dropped two studs so the ring sits at
your feet.

The sound is the emote's soundsOnBegin entry, locker.emotes.nightmare_1_sounds_on_begin_sound, which
the meta marks looped: a drone under the whole emote that has to be stopped with the rest. It is
parented to the torso so it dies with the character. The emote ends the way a real one does, on your
first step, a jump or death, and also when the character is removed, because a respawn would
otherwise leave the effect in workspace. The module switches itself off deferred after enabling,
since flipping from inside the enable callback would re-enter the module's state mid-transition. ]]
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
		about = 'Plays the Nightmare emote, visible only to you.\nEnds when you move, jump or die.'
	})

	slinky:clean(function() stopEmote() end)
end)

--[[ UI Cleanup
Tidies up the BedWars HUD; in the lobby it covers the top bar. The BedWars top bar (its row of
buttons, the Settings menu that drops from them and, in a match, the scores and timer beside them)
sits at the right of the strip Roblox leaves free along the top of the screen, which is
GuiService.TopbarInset where the client reports one; TopBarAppGui itself covers the whole screen.
Topbar Position Middle centres that whole row on the screen, kept inside the strip so it never runs
under Roblox's buttons. The game's app moves the row again whenever its size changes, so each move
of the game's is kept as the piece's origin (where Default puts it back) and the row is centred
again in one deferred pass however many changes come in a frame. The game builds the bar again when
it remounts its HUD, and the strip changes as Roblox's own buttons come and go; both are watched.

On a phone the row also keeps room for the Pistonware button: its width plus the 7 px the GUI keeps
from the game's buttons, in the corner at the right end of the strip by default (kept with UI
Cleanup off too, as the button goes there then) or beside the buttons with Button Next To Topbar.
The room is a UIPadding inside the row, set in the units of the row's UIScale, so the game lays the
row out around it as around one more button of its own and nothing is pushed over the scores. For
the corner the row ends 12 px in from the end of the strip, as the game keeps it, and the game sizes
the row and the scores to the strip less 24 px, so the centred row always fits. A hidden button
takes no room and is docked beside the row, since left in the corner it would lie unseen over the
game's last button and take its taps.

After each layout the GUI places its button at once and again on the next step: the first call reads
the row as it was, and moving the padding leaves the row's AbsoluteSize unchanged, so no signal
follows the reflow; the follow-up is coalesced. The GUI's Hide Pistonware Mobile Button changes the
button's room and docking, so its flip is wrapped to lay the bar out again (a click or a profile
load). Unloading puts back every piece the game has not moved since. ]]
run(function()
	local uiCleanup
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
		toggled = function()
			topbar.refresh()
		end,
		about = 'Tidies up the BedWars HUD and removes clutter.\nIn the lobby it covers the top bar.'
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
