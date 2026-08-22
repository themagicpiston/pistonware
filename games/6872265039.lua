if not shared.PistonwareAuthenticated then
	warn('[pistonware] not authenticated -- run the pistonware loader and enter your key')
	return
end

local run = function(func) func() end
local cloneref = cloneref or function(obj) return obj end

local playersService = cloneref(game:GetService('Players'))
local replicatedStorage = cloneref(game:GetService('ReplicatedStorage'))
local inputService = cloneref(game:GetService('UserInputService'))
local runService = cloneref(game:GetService('RunService'))
local coreGui = cloneref(game:GetService('CoreGui'))

local lplr = playersService.LocalPlayer
local vape = shared.vape
local entitylib = vape.Libraries.entity
local sessioninfo = vape.Libraries.sessioninfo
local bedwars = {}

local function notif(...)
	return vape:CreateNotification(...)
end

run(function()
	local function dumpRemote(tab)
		local ind = table.find(tab, 'Client')
		return ind and tab[ind + 1] or ''
	end

	local KnitInit, Knit
	repeat
		KnitInit, Knit = pcall(function() return debug.getupvalue(require(lplr.PlayerScripts.TS.knit).setup, 9) end)
		if KnitInit then break end
		task.wait()
	until KnitInit
	if not debug.getupvalue(Knit.Start, 1) then
		repeat task.wait() until debug.getupvalue(Knit.Start, 1)
	end
	local Flamework = require(replicatedStorage['rbxts_include']['node_modules']['@flamework'].core.out).Flamework
	local Client = require(replicatedStorage.TS.remotes).default.Client

	bedwars = setmetatable({
		Client = Client,
		CrateItemMeta = debug.getupvalue(Flamework.resolveDependency('client/controllers/global/reward-crate/crate-controller@CrateController').onStart, 3),
		Store = require(lplr.PlayerScripts.TS.ui.store).ClientStore
	}, {
		__index = function(self, ind)
			rawset(self, ind, Knit.Controllers[ind])
			return rawget(self, ind)
		end
	})

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

run(function()
	local Sprint
	local old
	
	Sprint = vape.Categories.Combat:CreateModule({
		Name = 'Sprint',
		Function = function(callback)
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
		Tooltip = 'Sets your sprinting to true.'
	})
end)
	
run(function()
	local AutoGamble
	
	AutoGamble = vape.Categories.Minigames:CreateModule({
		Name = 'AutoGamble',
		Function = function(callback)
			if callback then
				AutoGamble:Clean(bedwars.Client:GetNamespace('RewardCrate'):Get('CrateOpened'):Connect(function(data)
					if data.openingPlayer == lplr then
						local tab = bedwars.CrateItemMeta[data.reward.itemType] or {displayName = data.reward.itemType or 'unknown'}
						notif('AutoGamble', 'Won '..tab.displayName, 5)
					end
				end))
	
				repeat
					if not bedwars.CrateAltarController.activeCrates[1] then
						for _, v in bedwars.Store:getState().Consumable.inventory do
							if v.consumable:find('crate') then
								bedwars.CrateAltarController:pickCrate(v.consumable, 1)
								task.wait(1.2)
								if bedwars.CrateAltarController.activeCrates[1] and bedwars.CrateAltarController.activeCrates[1][2] then
									bedwars.Client:GetNamespace('RewardCrate'):Get('OpenRewardCrate'):SendToServer({
										crateId = bedwars.CrateAltarController.activeCrates[1][2].attributes.crateId
									})
								end
								break
							end
						end
					end
					task.wait(1)
				until not AutoGamble.Enabled
			end
		end,
		Tooltip = 'Automatically opens lucky crates, piston inspired!'
	})
end)
run(function()
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
		Tooltip = 'Spoofs the device you show up as to the server'
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
			local folder = replicatedStorage.TS.achievement
			achievement = {
				Id = require(folder['achievement-id']).AchievementId,
				Meta = require(folder['achievement-meta']).AchievementsMeta,
				Util = require(folder['achievement-util']).AchievementUtil
			}
		end
		return achievement
	end

	local function getMilestones()
		if not milestoneRewards then
			milestoneRewards = require(replicatedStorage.TS.milestones.milestones).MilestoneRewards
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

		for _, milestone in getMilestones() do
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
		Tooltip = 'Automatically claims your daily reward, achievement rewards and level milestones.'
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
