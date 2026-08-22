if not shared.PistonwareAuthenticated then
	warn('[pistonware] not authenticated -- run the pistonware loader and enter your key')
	return
end

--[[ Every module in this file and in bedwars.lua is registered inside one of these -- 60 blocks
here, 59 there, all at top level, and bedwars.lua takes this same function through bw.run.
Unprotected, an error anywhere in any of them aborted the rest of the file: every module
below the failure never registered, and in bedwars.lua the completion signal on the last
line never ran either, so main.lua sat in waitForModules for the full 120s before loading a
profile against a half-built module set. One game update touching one API took the whole
script down that way. Contained here, a bad block costs its own modules and nothing else. ]]
local run = function(func)
	if shared.VapeSmoothBoot then task.wait() end
	local ok, err = pcall(func)
	if not ok then
		warn('[pistonware] a module block failed to load: '..tostring(err))
	end
end

local cloneref = cloneref or function(obj)
	return obj
end
local vapeEvents = setmetatable({}, {
	__index = function(self, index)
		local result = rawget(self, index)
		if result == nil then
			result = Instance.new('BindableEvent')
			rawset(self, index, result)
		end
		return result
	end
})

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
local coreGui = cloneref(game:GetService('CoreGui'))
local starterGui = cloneref(game:GetService('StarterGui'))
local lightingService = cloneref(game:GetService('Lighting'))
local teleportService = cloneref(game:GetService("TeleportService"))
local virtualInputManager = cloneref(game:GetService('VirtualInputManager'))

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

local vape = shared.vape
local entitylib = vape.Libraries.entity
local targetinfo = vape.Libraries.targetinfo
local sessioninfo = vape.Libraries.sessioninfo
local uipallet = vape.Libraries.uipallet
local tween = vape.Libraries.tween
local color = vape.Libraries.color
local whitelist = vape.Libraries.whitelist
local prediction = vape.Libraries.prediction
local getfontsize = vape.Libraries.getfontsize
local getcustomasset = vape.Libraries.getcustomasset

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
local Reach = {}
local HitBoxes = {}
local InfiniteFly = {}
local TrapDisabler
local AntiFallPart
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

local function addBlur(parent)
	local blur = Instance.new('ImageLabel')
	blur.Name = 'Blur'
	blur.Size = UDim2.new(1, 89, 1, 52)
	blur.Position = UDim2.fromOffset(-48, -31)
	blur.BackgroundTransparency = 1
	blur.Image = getcustomasset('pistonware/assets/new/blur.png')
	blur.ScaleType = Enum.ScaleType.Slice
	blur.SliceCenter = Rect.new(52, 31, 261, 502)
	blur.Parent = parent
	return blur
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
		module:Clean(cleanFunc)
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

local function getBow()
	local bestBow, bestSlot, highestDamage = nil, nil, 0
	for slot, item in store.inventory.inventory.items do
		local meta = bedwars.ItemMeta[item.itemType]
		if meta then
			local source = meta.projectileSource
			-- ammoItemTypes is absent on self-fuelled launchers (the frost staffs and most kit
			-- casters -- bedwars.lua's isSelfFuelled is about the same field), and
			-- table.find(nil, ...) throws rather than returning nil. Carrying one of those made
			-- every getBow() call error out, which takes the caller with it.
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

local function getStrength(plr)
	if not (plr and plr.Player) then return 0 end
	local strength = 0
	local inv = store.inventories[plr.Player]
	if not inv then return 0 end

	for _, v in inv.items do
		local meta = bedwars.ItemMeta[v.itemType]
		if meta and meta.sword and meta.sword.damage > strength then
			strength = meta.sword.damage
		end
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

local function getNearGround(range)
	range = Vector3.new(3, 3, 3) * (range or 10)
	local localPos = entitylib.character.RootPart.Position
	local closest, bestMag = nil, 60
	local s, e = bedwars.BlockController:getBlockPosition(localPos - range), bedwars.BlockController:getBlockPosition(localPos + range)
	local blocks = getBlocksInPoints(s, e)

	for _, v in blocks do
		if not getPlacedBlock(v + Vector3.new(0, 3, 0)) then
			local mag = (localPos - v).Magnitude
			if mag < bestMag then
				bestMag, closest = mag, v + Vector3.new(0, 3, 0)
			end
		end
	end

	table.clear(blocks)
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

local function getSpeed()
    --[[ Delegate to shared.bedwars.getSpeed if DamageBoost has wrapped it ]]
    local bw = shared.bedwars
    if bw and type(bw.getSpeed) == "function" then
        return bw.getSpeed()
    end
    return _baseGetSpeed()
end

local function getTableSize(tab)
	local ind = 0
	for _ in tab do
		ind += 1
	end
	return ind
end

local function hotbarSwitch(slot)
	if slot and store.inventory.hotbarSlot ~= slot then
		bedwars.Store:dispatch({
			type = 'InventorySelectHotbarSlot',
			slot = slot
		})
		vapeEvents.InventoryChanged.Event:Wait()
		return true
	end
	return false
end

local function isFriend(plr, recolor)
	if vape.Categories.Friends.Options['Use friends'].Enabled then
		local friend = table.find(vape.Categories.Friends.ListEnabled, plr.Name) and true
		if recolor then
			friend = friend and vape.Categories.Friends.Options['Recolor visuals'].Enabled
		end
		return friend
	end
	return nil
end

local function isTarget(plr)
	return table.find(vape.Categories.Targets.ListEnabled, plr.Name) and true
end

local function notif(...)
	return vape:CreateNotification(...)
end

local function removeTags(str)
	str = str:gsub('<br%s*/>', '\n')
	return (str:gsub('<[^<>]->', ''))
end

local function roundPos(vec)
	return Vector3.new(math.round(vec.X / 3) * 3, math.round(vec.Y / 3) * 3, math.round(vec.Z / 3) * 3)
end

local function switchItem(tool, delayTime)
	delayTime = delayTime or 0.05
	local check = lplr.Character and lplr.Character:FindFirstChild('HandInvItem') or nil
	if check and check.Value ~= tool and tool.Parent ~= nil then
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

local function updateVelocity(force)
	-- next(), not a full count: the only question is whether anything is in there, and
	-- getTableSize walks every entry to answer it.
	local newState = next(frictionTable) ~= nil
	if frictionState ~= newState or force then
		if frictionConnection then
			frictionConnection:Disconnect()
		end
		if newState then
			if entitylib.isAlive then
				for _, v in entitylib.character.Character:GetDescendants() do
					modifyVelocity(v)
				end
				frictionConnection = entitylib.character.Character.DescendantAdded:Connect(modifyVelocity)
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

local sortmethods = {
	Damage = function(a, b)
		return a.Entity.Character:GetAttribute('LastDamageTakenTime') < b.Entity.Character:GetAttribute('LastDamageTakenTime')
	end,
	Threat = function(a, b)
		return getStrength(a.Entity) > getStrength(b.Entity)
	end,
	Kit = function(a, b)
		return (a.Entity.Player and kitorder[a.Entity.Player:GetAttribute('PlayingAsKit')] or 0) > (b.Entity.Player and kitorder[b.Entity.Player:GetAttribute('PlayingAsKit')] or 0)
	end,
	Health = function(a, b)
		return a.Entity.Health < b.Entity.Health
	end,
	Angle = function(a, b)
		--[[ acos is monotonically DECREASING on [-1, 1], so comparing the raw dots
		the other way round gives the identical ordering without two acos calls
		per comparison -- this runs O(n log n) per Heartbeat when sorting by Angle ]]
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

	--[[ A Practice room dummy is identified by either of the two markers.
	training-room-entity-controller watches the tag and then reads the attribute off
	the instance; the attribute is the half that actually shows up on a dummy in the
	explorer, so neither is trusted alone. ]]
	local function isTrainingDummy(ent)
		return ent:HasTag('trainingRoomDummy') or ent:GetAttribute('TrainingRoomDummy') ~= nil
	end

	local function customEntity(ent)
		--[[ Inventory entities are the shop keepers and other furniture standing around a
		lobby, which is why they are skipped. But a dummy is one too -- it wears armor
		and holds an item, so it has the same ArmorInvItem/HandInvItem rig a player
		does -- and this guard was throwing away the only thing in the Practice room
		worth hitting, no matter which tag found it. ]]
		if ent:HasTag('inventory-entity') and not (ent:HasTag('Monster') or isTrainingDummy(ent)) then
			return
		end

		--[[ Monsters are watched under their own tag as well as 'entity' (see start
		below), so anything carrying both arrives here twice and would be registered
		twice -- two list entries for one character, counting double against Max
		targets and drawing two of every box. ]]
		if entitylib.EntityThreads[ent] or entitylib.getEntity(ent) then
			return
		end

		entitylib.addEntity(ent, nil, ent:HasTag('Drone') and function(self)
			local droneplr = playersService:GetPlayerByUserId(self.Character:GetAttribute('PlayerUserId'))
			return not droneplr or lplr:GetAttribute('Team') ~= droneplr:GetAttribute('Team')
		end or function(self)
			--[[ Nothing without a team is anybody's teammate. Practice and tutorial
			dummies carry no Team attribute, and in the lobby neither do we, so the
			plain comparison had nil equal to nil and read every dummy as friendly --
			untargetable in exactly the place where they are the only thing to hit.
			In a real match this changes nothing: a team-less monster was already
			targetable there, since our own team is set. ]]
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

	entitylib.start = function()
		oldstart()
		if entitylib.Running then
			for _, tag in ENTITY_TAGS do
				for _, ent in collectionService:GetTagged(tag) do
					customEntity(ent)
				end
				table.insert(entitylib.Connections, collectionService:GetInstanceAddedSignal(tag):Connect(customEntity))
				table.insert(entitylib.Connections, collectionService:GetInstanceRemovedSignal(tag):Connect(function(ent)
					entitylib.removeEntity(ent)
				end))
			end
		end
	end

	entitylib.addPlayer = function(plr)
		if plr.Character then
			entitylib.refreshEntity(plr.Character, plr)
		end
		entitylib.PlayerConnections[plr] = {
			plr.CharacterAdded:Connect(function(char)
				entitylib.refreshEntity(char, plr)
			end),
			plr.CharacterRemoving:Connect(function(char)
				entitylib.removeEntity(char, plr == lplr)
			end),
			plr:GetAttributeChangedSignal('Team'):Connect(function()
				for _, v in entitylib.List do
					if v.Targetable ~= entitylib.targetCheck(v) then
						entitylib.refreshEntity(v.Character, v.Player)
					end
				end

				if plr == lplr then
					entitylib.start()
				else
					entitylib.refreshEntity(plr.Character, plr)
				end
			end)
		}
	end

	entitylib.addEntity = function(char, plr, teamfunc)
		if not char then return end
		entitylib.EntityThreads[char] = task.spawn(function()
			local hum, humrootpart, head
			if plr then
				hum = waitForChildOfType(char, 'Humanoid', 10)
				humrootpart = hum and waitForChildOfType(hum, 'RootPart', workspace.StreamingEnabled and 9e9 or 10, true)
				head = char:WaitForChild('Head', 10) or humrootpart
			else
				hum = {HipHeight = 0.5}
				humrootpart = waitForRootPart(char, 10)
				head = humrootpart
			end
			local updateobjects = plr and plr ~= lplr and {
				char:WaitForChild('ArmorInvItem_0', 5),
				char:WaitForChild('ArmorInvItem_1', 5),
				char:WaitForChild('ArmorInvItem_2', 5),
				char:WaitForChild('HandInvItem', 5)
			} or {}

			if hum and humrootpart then
				local entity = {
					Connections = {},
					Character = char,
					Health = (char:GetAttribute('Health') or 100) + getShieldAttribute(char),
					Head = head,
					Humanoid = hum,
					HumanoidRootPart = humrootpart,
					HipHeight = hum.HipHeight + (humrootpart.Size.Y / 2) + (hum.RigType == Enum.HumanoidRigType.R6 and 2 or 0),
					Jumps = 0,
					JumpTick = os.clock(),
					Jumping = false,
					LandTick = os.clock(),
					MaxHealth = char:GetAttribute('MaxHealth') or 100,
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
					table.insert(entitylib.Connections, char.AttributeChanged:Connect(function(attr)
						vapeEvents.AttributeChanged:Fire(attr)
					end))
				else
					entity.Targetable = entitylib.targetCheck(entity)

					for _, v in entitylib.getUpdateConnections(entity) do
						table.insert(entity.Connections, v:Connect(function()
							entity.Health = (char:GetAttribute('Health') or 100) + getShieldAttribute(char)
							entity.MaxHealth = char:GetAttribute('MaxHealth') or 100
							entitylib.Events.EntityUpdated:Fire(entity)
						end))
					end

					for _, v in updateobjects do
						table.insert(entity.Connections, v:GetPropertyChangedSignal('Value'):Connect(function()
							task.delay(0.1, function()
								if bedwars.getInventory then
									store.inventories[plr] = bedwars.getInventory(plr)
									entitylib.Events.EntityUpdated:Fire(entity)
								end
							end)
						end))
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
						entitylib.removeEntity(char, plr == lplr)
					end
				end))
			end
			entitylib.EntityThreads[char] = nil
		end)
	end

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
		if not select(2, whitelist:get(ent.Player)) then return false end
		return lplr:GetAttribute('Team') ~= ent.Player:GetAttribute('Team')
	end
	vape:Clean(entitylib.Events.LocalAdded:Connect(updateVelocity))
end)
entitylib.start()

--[[ pistonware funcs ]]

local genv = getgenv()
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
lplr.CharacterAdded:Connect(function(c)
    c:WaitForChild("HumanoidRootPart", 5)
    ensureCharPrimaryPart(c)
end)

--[[ == shared __namecall guard ==
There is exactly ONE global __namecall hook in the whole product and it lives
here, in the unobfuscated file. Every namecall in the game -- including the
tens of thousands Roact issues while it builds and re-renders the item shop --
passes through this function, so it must stay native-speed Lua. A hook
installed from bedwars.lua costs a Luraph VM re-entry on each of those calls,
which is what turned opening the shop (and every purchase re-render) into a
visible hitch while leaving the unobfuscated build smooth.

Modules that need to see or block a specific remote register the exact
(Instance, method) pair here via shared.bedwars.namecallGuard instead. The hot
path cost is one hash lookup; handlers only ever run for instances somebody
actually asked about. ]]
local namecallWatch = {}
local namecallGuard = {}

--[[ handler may be `true` to swallow the call outright, or a function. From a function:
  nil / false       -- let the call through unchanged
  a table           -- REPLACEMENT ARGUMENTS, table.pack shape (`n` plus 1..n), forwarded
                       to the same method in place of the originals
  any other truthy  -- swallow the call
Method names are matched exactly as getnamecallmethod() reports them.

The table form exists so a module can rewrite what a remote sends without installing a
second __namecall hook of its own. That is not a style preference: a hook installed from
bedwars.lua charges a Luraph VM re-entry to EVERY namecall in the game, and the item shop
issues tens of thousands of them per Roact render -- enough to take the client down when
the shop opens. Registering here costs one hash lookup on the hot path instead. ]]
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

local getnamecallmethod = getnamecallmethod
local mt = getrawmetatable(game)
setreadonly(mt, false)
--[[
	Chain to the FIRST original, never to whatever is installed right now.

	This file is re-executed on every injection, and a reinject in the same server is an
	ordinary thing to do -- the Reinject button, Reset current profile, and the config sync all
	go back through the loader. Reading mt.__namecall straight into oldNamecall meant the new
	hook wrapped the previous hook, which wrapped the one before it: three reinjects and every
	namecall in the game -- the tens of thousands Roact issues per item-shop render included --
	walked three nested Lua closures, with only the newest one's watch table doing anything.
	The stack never came back down, because nothing here restores the metamethod.

	shared is per-session (it does not survive a teleport, and a teleport gives us a fresh
	metatable anyway), so it holds exactly the right thing: the untouched original from the
	first injection of this session. Later injections replace the live hook instead of stacking
	on it, and the chain stays one deep however many times the script is reloaded.
]]
local oldNamecall = shared.PistonwareOldNamecall or mt.__namecall
shared.PistonwareOldNamecall = oldNamecall
mt.__namecall = function(self, ...)
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
    local entry = namecallWatch[self]
    if entry then
        local handler = entry[method]
        if handler == true then
            return
        elseif handler then
            local ok, result = pcall(handler, self, ...)
            --[[ Any truthy non-table result swallows the call, as it always did. ]]
            if ok and result ~= nil and result ~= false and type(result) ~= 'table' then
                return
            end
            local replacement = (ok and type(result) == 'table') and result or nil

            --[[ Forward as a NAMECALL wherever that is still correct, because the
            index-and-call path below is observably different from the outside. It
            turns one `remote:FireServer(x)` into an __index plus a direct call, so
            anything instrumenting the method itself -- a remote spy, another
            executor hook -- sees the call a second time and reports the remote as
            firing twice. Only ever one packet reached the server, but the duplicate
            is indistinguishable from a real double-send when you are debugging one,
            and SwordHit is watched for rate limiting, so every sword swing hit it.

            The concern remains, but it is narrower than it looks:
            getnamecallmethod() reports the LAST namecall made on this thread, so if
            the handler made namecalls of its own, oldNamecall would dispatch off
            whatever it touched last. That is testable rather than assumed -- re-read
            it and compare. Unchanged means no handler namecall clobbered it and
            oldNamecall dispatches exactly what we entered with. ]]
            if not replacement and getnamecallmethod() == method then
                return oldNamecall(self, ...)
            end

            --[[ Fallback for the two cases the above cannot cover: a handler that
            rewrote the arguments (oldNamecall would forward the originals), and a
            handler whose own namecalls moved getnamecallmethod() out from under us.
            Indexing the method off self carries it with the value and cannot be
            clobbered, at the cost of the duplicate observation described above. ]]
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
setreadonly(mt, true)

local blankFunction = function(...) return ... end

local RunLoops = {RenderStepTable = {}, StepTable = {}, HeartTable = {}}
local vapeConnections = {}

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

--[[ Substring match of an instance name against a TextList's switched-on entries.

Reads ListEnabled, not Objects. Objects holds the list window's row BUTTONS, and
every one of them has Text = '' (the visible text lives on a child TextLabel) and
the default Name 'TextButton' -- so the old version compared every name against
the literal string "textbutton" and matched nothing, ever. Objects is also the
wrong set even when read correctly: it holds every entry, including the ones the
user switched off. ListEnabled is the enabled subset and is what the rest of the
script reads.

Plain-text find, since item names carry '-' and '(' which read as pattern syntax
and would either mis-match or throw. ]]
local function entryMatches(objName, list)
    if type(objName) ~= "string" or type(list) ~= "table" then return false end
    --[[ A bare array of strings is accepted too, so callers can pass List.ListEnabled. ]]
    local entries = list.ListEnabled or list.List or list
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

local function safeGetProto(func, index)
    if not func then return nil end
    local success, proto = pcall(debug.getproto, func, index)
    if success then
        return proto
    else
        --[[ Developer-only. This prints a raw function pointer and an index, which means nothing
        to a user and fires on executors whose debug.getproto is simply missing -- so on
        those it used to spray the console on every call for no reason. The caller already
        handles nil. ]]
        if shared.PistonwareDeveloper then
            warn('[pistonware] getproto failed -- function:', func, 'index:', index)
        end
        return nil
    end
end

--[[ The `out` barrel re-exports sound-manager, but each of its re-exports is guarded by
`or {}`, so a build where that submodule fails to resolve silently drops the key and
leaves SoundManager nil -- which is how "attempt to index nil with 'playSound'" reached
both SoundChanger and the projectile launch sound. Handing back a stub instead of nil is
what fixes that: a dozen call sites across both files index this directly and none of
them are worth taking down over a missing sound effect. Every method on the stub is a
no-op, and SoundChanger's hook and restore still work against it. ]]
local function resolveSoundManager()
    local ok, res = pcall(function()
        return require(replicatedStorage['rbxts_include']['node_modules']['@easy-games']['game-core'].out).SoundManager
    end)
    if ok and res then return res end

    return setmetatable({}, {__index = function() return blankFunction end})
end

--[[ pistonware funcs ]]

run(function()
	local KnitInit, Knit
	repeat
		KnitInit, Knit = pcall(function()
			return debug.getupvalue(require(lplr.PlayerScripts.TS.knit).setup, 9)
		end)
		if KnitInit then break end
		task.wait()
	until KnitInit

	--[[ The wait is protected by pcall and has a deadline. Two separate hazards, both fatal here before the fix:
	Knit.Start is nil if a game update reshapes Knit, and debug.getupvalue(nil, 1) THROWS --
	which killed this block before the bedwars table on the next line was ever built, taking
	every module in this file and bedwars.lua with it. And a Knit that loads but never
	finishes starting parked this loop at frame rate for the rest of the session. ]]
	local knitDeadline = os.clock() + 60
	while true do
		local started, value = pcall(debug.getupvalue, Knit.Start, 1)
		if started and value then break end
		if os.clock() > knitDeadline then
			warn('[pistonware] Knit did not finish starting within 60s -- loading anyway')
			break
		end
		task.wait()
	end

	local Flamework = require(replicatedStorage['rbxts_include']['node_modules']['@flamework'].core.out).Flamework
	local InventoryUtil = require(replicatedStorage.TS.inventory['inventory-util']).InventoryUtil
	local Client = require(replicatedStorage.TS.remotes).default.Client
	local OldGet, OldBreak = Client.Get

	bedwars = setmetatable({
		AbilityController = Flamework.resolveDependency('@easy-games/game-core:client/controllers/ability/ability-controller@AbilityController'),
		AdetundeUpgradeMeta = require(replicatedStorage.TS.games.bedwars.items['frosty-hammer']['frosty-hammer-upgrades']).FrostyHammerUpgradeMeta,
		AdetundeUtil = require(replicatedStorage.TS.games.bedwars.items['frosty-hammer']['frosty-hammer-util']).FrostyHammerUtil,
		AnimationType = require(replicatedStorage.TS.animation['animation-type']).AnimationType,
		AnimationUtil = require(replicatedStorage['rbxts_include']['node_modules']['@easy-games']['game-core'].out['shared'].util['animation-util']).AnimationUtil,
		AppController = require(replicatedStorage['rbxts_include']['node_modules']['@easy-games']['game-core'].out.client.controllers['app-controller']).AppController,
		BedBreakEffectMeta = require(replicatedStorage.TS.locker['bed-break-effect']['bed-break-effect-meta']).BedBreakEffectMeta,
		BedwarsKitMeta = require(replicatedStorage.TS.games.bedwars.kit['bedwars-kit-meta']).BedwarsKitMeta,
		BlackMarketeerBalance = require(replicatedStorage.TS.balance['black-marketeer-balance']).BlackMarketeerBalance,
		JuggernautUtil = require(replicatedStorage.TS.balance['juggernaut-balance-file']).JuggernautUtil,
		BlockBreaker = Knit.Controllers.BlockBreakController.blockBreaker,
		BlockController = require(replicatedStorage['rbxts_include']['node_modules']['@easy-games']['block-engine'].out).BlockEngine,
		BlockEngine = require(lplr.PlayerScripts.TS.lib['block-engine']['client-block-engine']).ClientBlockEngine,
		BlockPlacer = require(replicatedStorage['rbxts_include']['node_modules']['@easy-games']['block-engine'].out.client.placement['block-placer']).BlockPlacer,
		BowConstantsTable = debug.getupvalue(Knit.Controllers.ProjectileController.enableBeam, 8),
		ClickHold = require(replicatedStorage['rbxts_include']['node_modules']['@easy-games']['game-core'].out.client.ui.lib.util['click-hold']).ClickHold,
		Client = Client,
		ClientConstructor = require(replicatedStorage['rbxts_include']['node_modules']['@rbxts'].net.out.client),
		ClientDamageBlock = require(replicatedStorage['rbxts_include']['node_modules']['@easy-games']['block-engine'].out.shared.remotes).BlockEngineRemotes.Client,
		CombatConstant = require(replicatedStorage.TS.combat['combat-constant']).CombatConstant,
		DamageIndicator = Knit.Controllers.DamageIndicatorController.spawnDamageIndicator,
		DefaultKillEffect = require(lplr.PlayerScripts.TS.controllers.global.locker["kill-effect"].effects['default-kill-effect']),
		EmoteType = require(replicatedStorage.TS.locker.emote['emote-type']).EmoteType,
		EnchantMeta = require(replicatedStorage.TS.enchant['enchant-meta']).EnchantMeta,
		GameAnimationUtil = require(replicatedStorage.TS.animation['animation-util']).GameAnimationUtil,
		getIcon = function(item, showinv)
			local itemmeta = bedwars.ItemMeta[item.itemType]
			return itemmeta and showinv and itemmeta.image or ''
		end,
		getInventory = function(plr)
			local suc, res = pcall(function()
				return InventoryUtil.getInventory(plr)
			end)
			return suc and res or {
				items = {},
				armor = {}
			}
		end,
		HudAliveCount = require(lplr.PlayerScripts.TS.controllers.global['top-bar'].ui.game['hud-alive-player-counts']).HudAlivePlayerCounts,
		ItemMeta = debug.getupvalue(require(replicatedStorage.TS.item['item-meta']).getItemMeta, 1),
		KillEffectMeta = require(replicatedStorage.TS.locker['kill-effect']['kill-effect-meta']).KillEffectMeta,
		KillFeedController = Flamework.resolveDependency('client/controllers/game/kill-feed/kill-feed-controller@KillFeedController'),
		Knit = Knit,
		KnockbackUtil = require(replicatedStorage.TS.damage['knockback-util']).KnockbackUtil,
		MageKitUtil = require(replicatedStorage.TS.games.bedwars.kit.kits.mage['mage-kit-util']).MageKitUtil,
		NametagController = Knit.Controllers.NametagController,
		PartyController = Flamework.resolveDependency('@easy-games/lobby:client/controllers/party-controller@PartyController'),
		ProjectileMeta = require(replicatedStorage.TS.projectile['projectile-meta']).ProjectileMeta,
		PingController = require(lplr.PlayerScripts.TS.controllers.game.ping["ping-controller"]).PingController,
		QueryUtil = require(replicatedStorage['rbxts_include']['node_modules']['@easy-games']['game-core'].out).GameQueryUtil,
		QueueCard = require(lplr.PlayerScripts.TS.controllers.global.queue.ui['queue-card']).QueueCard,
		QueueMeta = require(replicatedStorage.TS.game['queue-meta']).QueueMeta,
		Roact = require(replicatedStorage['rbxts_include']['node_modules']['@rbxts']['roact'].src),
		RuntimeLib = require(replicatedStorage['rbxts_include'].RuntimeLib),
		SoundList = require(replicatedStorage.TS.sound['game-sound']).GameSound,
		SoundManager = resolveSoundManager(),
		StatusEffectUtil = require(replicatedStorage.TS['status-effect']['status-effect-util']).StatusEffectUtil,
		StatusEffectMeta = require(replicatedStorage.TS['status-effect']['status-effect-type']).StatusEffectType,
		Store = require(lplr.PlayerScripts.TS.ui.store).ClientStore,
		SummonerKitBalance = require(replicatedStorage.TS.games.bedwars.kit.kits.summoner['summoner-kit-balance']).SummonerKitBalance,
		TeamUpgradeMeta = debug.getupvalue(require(replicatedStorage.TS.games.bedwars['team-upgrade']['team-upgrade-meta']).getTeamUpgradeMetaForQueue, 7),
		UILayers = require(replicatedStorage['rbxts_include']['node_modules']['@easy-games']['game-core'].out).UILayers,
		VisualizerUtils = require(lplr.PlayerScripts.TS.lib.visualizer['visualizer-utils']).VisualizerUtils,
		WeldTable = require(replicatedStorage.TS.util['weld-util']).WeldUtil,
		WinEffectMeta = require(replicatedStorage.TS.locker['win-effect']['win-effect-meta']).WinEffectMeta,
		ZapNetworking = require(lplr.PlayerScripts.TS.lib.network)
	}, {
		__index = function(self, ind)
			rawset(self, ind, Knit.Controllers[ind])
			return rawget(self, ind)
		end
	})

	local remoteNames = {
		AfkStatus = safeGetProto(Knit.Controllers.AfkController.KnitStart, 1),
		AttackEntity = Knit.Controllers.SwordController.sendServerRequest,
		BeePickup = Knit.Controllers.BeeNetController.trigger,
		CannonAim = safeGetProto(Knit.Controllers.CannonController.startAiming, 5),
		CannonLaunch = Knit.Controllers.CannonHandController.launchSelf,
		ConsumeBattery = safeGetProto(Knit.Controllers.BatteryController.onKitLocalActivated, 1),
		ConsumeItem = safeGetProto(Knit.Controllers.ConsumeController.onEnable, 1),
		ConsumeSoul = Knit.Controllers.GrimReaperController.consumeSoul,
		DepositPinata = safeGetProto(safeGetProto(Knit.Controllers.PiggyBankController.KnitStart, 2), 5),
		DragonBreath = safeGetProto(Knit.Controllers.VoidDragonController.onKitLocalActivated, 5),
		DragonEndFly = safeGetProto(Knit.Controllers.VoidDragonController.flapWings, 1),
		DragonFly = Knit.Controllers.VoidDragonController.flapWings,
		DropItem = Knit.Controllers.ItemDropController.dropItemInHand,
		EquipItem = safeGetProto(require(replicatedStorage.TS.entity.entities['inventory-entity']).InventoryEntity.equipItem, 4),
		FireProjectile = debug.getupvalue(Knit.Controllers.ProjectileController.launchProjectileWithValues, 2),
		GroundHit = Knit.Controllers.FallDamageController.KnitStart,
		GuitarHeal = Knit.Controllers.GuitarController.performHeal,
		HannahKill = safeGetProto(Knit.Controllers.HannahController.registerExecuteInteractions, 1),
		HarvestCrop = safeGetProto(safeGetProto(Knit.Controllers.CropController.KnitStart, 4), 1),
		KaliyahPunch = safeGetProto(Knit.Controllers.DragonSlayerController.onKitLocalActivated, 1),
		MageSelect = safeGetProto(Knit.Controllers.MageController.registerTomeInteraction, 1),
		MinerDig = safeGetProto(Knit.Controllers.MinerController.setupMinerPrompts, 1),
		PickupItem = Knit.Controllers.ItemDropController.checkForPickup,
		PickupMetal = safeGetProto(Knit.Controllers.HiddenMetalController.onKitLocalActivated, 4),
		ReportPlayer = require(lplr.PlayerScripts.TS.controllers.global.report['report-controller']).default.reportPlayer,
		ResetCharacter = safeGetProto(Knit.Controllers.ResetController.createBindable, 1),
		SpawnRaven = safeGetProto(Knit.Controllers.RavenController.KnitStart, 1),
		SummonerClawAttack = Knit.Controllers.SummonerClawHandController.attack,
		WarlockTarget = safeGetProto(Knit.Controllers.WarlockStaffController.KnitStart, 2)
	}

	local function dumpRemote(tab)
		local ind
		for i, v in tab do
			if v == 'Client' then
				ind = i
				break
			end
		end
		return ind and tab[ind + 1] or ''
	end

	for i, v in remoteNames do
		local remote = dumpRemote(debug.getconstants(v))
		if remote == '' then
			--[[ notif('Pistonware', 'Failed to grab remote ('..i..')', 10, 'alert') ]]
		end
		remotes[i] = remote
	end

	OldBreak = bedwars.BlockController.isBlockBreakable

	Client.Get = function(self, remoteName)
		local call = OldGet(self, remoteName)

		if remoteName == remotes.AttackEntity then
			return {
				instance = call.instance,
				SendToServer = function(_, attackTable, ...)
					local suc, plr = pcall(function()
						return playersService:GetPlayerFromCharacter(attackTable.entityInstance)
					end)

					local selfpos = attackTable.validate.selfPosition.value
					local targetpos = attackTable.validate.targetPosition.value
					store.attackReach = ((selfpos - targetpos).Magnitude * 100) // 1 / 100
					store.attackReachUpdate = os.clock() + 1

					if Reach.Enabled or HitBoxes.Enabled then
						attackTable.validate.raycast = attackTable.validate.raycast or {}
						attackTable.validate.selfPosition.value += CFrame.lookAt(selfpos, targetpos).LookVector * math.max((selfpos - targetpos).Magnitude - 14.399, 0)
					end

					if suc and plr then
						if not select(2, whitelist:get(plr)) then return end
					end

					return call:SendToServer(attackTable, ...)
				end
			}
		-- TrapDisabler is nil until its own run() block registers it, hundreds of lines below
		-- this one, and stays nil for the session if that block fails (which is exactly what
		-- run() is there to survive). Indexing it then threw on every Client:Get for the trap
		-- remote -- inside the hot path every remote in the game goes through.
		elseif remoteName == 'StepOnSnapTrap' and TrapDisabler and TrapDisabler.Enabled then
			return {SendToServer = function() end}
		end

		return call
	end

	bedwars.BlockController.isBlockBreakable = function(self, breakTable, plr)
		local obj = bedwars.BlockController:getStore():getBlockAt(breakTable.blockPosition)

		if obj and obj.Name == 'bed' then
			for _, plr in playersService:GetPlayers() do
				if obj:GetAttribute('Team'..(plr:GetAttribute('Team') or 0)..'NoBreak') and not select(2, whitelist:get(plr)) then
					return false
				end
			end
		end

		return OldBreak(self, breakTable, plr)
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
	local function calculatePath(target, blockpos)
		local origin = entitylib.isAlive and entitylib.character.RootPart.Position or Vector3.zero
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

		--[[ Cheapest wins, and the nearest of the cheapest wins the tie.

		The tie is not an edge case, it is the normal case: every cell of a one-layer cover
		costs the same one block to get through, so the top of the pile, the far side and
		the face you are standing at are all equally cheap, and picking whichever the queue
		happened to reach first is picking at random. Which of them the answer names decides
		where the break lands, and a spot on the wrong side of a structure is one Block Check
		then has to walk all the way back -- when it can, and it could not always. ]]
		local best, bestcost, bestrange
		for _ = 1, 10000 do
			local node = pop()
			if not node then break end

			local cost, current = node[1], node[2]
			--[[ Nodes come off cheapest first, so once one costs more than the answer already
			in hand, nothing still queued can beat it. The slack is for float noise: two
			routes through the same blocks can add up in different orders. ]]
			if best and cost > bestcost + 0.0001 then break end
			--[[ A cell can sit in the heap more than once, from before its distance was
			improved; the first pop is the good one and the rest are stale. ]]
			if visited[current] then continue end
			visited[current] = true

			local touchesair = false
			for _, side in sides do
				side = current + side
				if visited[side] then continue end

				local block = getPlacedBlock(side)
				if not block or block:GetAttribute('NoBreak') or block == target then
					if not block then
						touchesair = true
					end
					continue
				end

				local curdist = getBlockHits(block, side) + cost
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

	local function frontOf(worldpos)
		if not entitylib.isAlive then return worldpos end

		--[[ From the head, not the root: it is the eye line that decides what is reachable, and
		a root at foot height reads a floor block as cover when nothing is in the way. ]]
		local head = entitylib.character.Head
		local origin = (head and head.Position) or entitylib.character.RootPart.Position
		local direction = worldpos - origin
		local start, finish = bedwars.BlockController:getBlockPosition(origin), bedwars.BlockController:getBlockPosition(worldpos)
		local x, y, z = start.X, start.Y, start.Z

		local stepx, nextx, deltax = boundary(x, origin.X, direction.X)
		local stepy, nexty, deltay = boundary(y, origin.Y, direction.Y)
		local stepz, nextz, deltaz = boundary(z, origin.Z, direction.Z)

		--[[ 30 studs of reach is ten cells, and a diagonal line crosses at most one boundary per
		axis per cell, so this cannot run out before the spot does. ]]
		for _ = 1, 40 do
			--[[ every axis past its last boundary: the spot itself is the next thing on the line ]]
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
				--[[ Something unbreakable on the line means there is no shot at this spot at
				all, and naming it would only send the break at a block that never yields.
				Hand the spot back unchanged, and say so: 'nothing in the way' and 'no way
				through' arrive as the same spot otherwise, and the caller has to tell a
				clear shot from a sealed one. ]]
				if block:GetAttribute('NoBreak') then return worldpos, true end
				return cell * 3
			end
		end

		return worldpos
	end

	bedwars.placeBlock = function(pos, item)
		if getItem(item) then
			store.blockPlacer.blockType = item
			return store.blockPlacer:placeBlock(bedwars.BlockController:getBlockPosition(pos))
		end
	end

	--[[ blockcheck: when true, walk the chosen dig spot back to whatever physically stands
	  between it and the player, so cover comes off first instead of being mined through.
	  Anything else (false, or the nil every other caller passes) leaves the original
	  behaviour completely alone -- pathfind and dig, cover or no cover.
	method: 'Distance' ranks candidates by how far the dig spot is from the player;
	  anything else keeps the original ranking, fewest hits to get through. The ranking
	  still decides which cell is aimed at; blockcheck only walks that choice back to
	  whatever is physically in front of it.
	autotool: pick the tool by selecting its hotbar slot (what the AutoTool module does)
	  instead of equipping it directly. The correct tool is equipped either way -- this
	  only decides which route gets used.
	The ranking matters: picking purely by hit count can settle on a spot on the far side
	of the block, and the 30-stud guard below then aborts the break outright. ]]
	bedwars.breakBlock = function(block, effects, anim, customHealthbar, blockcheck, method, autotool)
		if lplr:GetAttribute('DenyBlockBreak') or not entitylib.isAlive then return end
		local handler = bedwars.BlockController:getHandlerRegistry():getHandler(block.Name)
		local cost, pos, target, path = math.huge
		local selfpos = entitylib.character.RootPart.Position
		local positions = (handler and handler:getContainedPositions(block)) or {block.Position / 3}
		local direct = false

		for _, v in positions do
			local cell = v * 3
			local dpos, dcost, dpath = calculatePath(block, cell)
			if dpos then
				--[[ Does this candidate land on the block itself rather than on something
				covering it? calculatePath answers with the cell it started from when that
				cell already touches air, so dpos == cell IS 'this side of the block is
				open'. Preferred outright, because aiming at the target beats aiming at its
				cover and 'Distance' would otherwise rank a nearer cover cell above an open
				bed. It is only a preference: blockcheck still gets the last word below, and
				sends the break back onto the cover when the open side cannot be reached
				from where the player stands. ]]
				local ddirect = dpos == cell
				local score = method == 'Distance' and (selfpos - dpos).Magnitude or dcost
				--[[ Kept a strict boolean: a single-celled block offers one candidate, so for
				every caller but a bed this collapses to the original `score < cost` ]]
				local better
				if ddirect ~= direct then
					better = ddirect
				else
					better = score < cost
				end
				if better then
					cost, pos, target, path, direct = score, dpos, cell, dpath, ddirect
				end
			end
		end

		--[[ Block Check. The spot chosen above is picked by the selected metric, but it can sit
		behind the cover (an air face under the bed, or one on its far side, or a cell up on
		top of a mound) and hitting it there is what reads as mining straight through the
		blocks. Take the first cell the eye line actually runs into instead, so the cover
		comes off from the side the player is standing on.

		There are no exceptions. Everything that used to be waved through
		here -- a face pointing your way is open, the target itself is exposed somewhere --
		turned out to mean 'exposed' in a sense that had nothing to do with being reachable
		from where the player is standing, and each one came back as a break going through a
		wall. There is nothing to lose by asking every time: a spot already at the front of
		the line is what the march meets first, so it hands back exactly that spot. An open
		bed you can see is hit; the same bed with wool in front of it gets the wool stripped. ]]
		if blockcheck and pos then
			local front = frontOf(pos)
			if front ~= pos then
				--[[ path described the old target; drop it so the visualiser stops drawing a
				chain that no longer leads anywhere ]]
				pos, path = front, nil
			end
		end

		if pos then
			if (entitylib.character.RootPart.Position - pos).Magnitude > 30 then return end
			local dblock, dpos = getPlacedBlock(pos)
			--[[ Nothing standing where the path said to dig: the world moved under the answer
			between working it out and acting on it. Next pass works out a fresh one. ]]
			if not dblock then return end

			--[[ Never swing at something the game marks unbreakable for our own team, whatever
			the caller thought it was aiming at. The dig spot is routinely NOT the block that
			was ranked -- Block Check redirects it onto whatever stands in the way -- so a
			caller's own filtering says nothing about what ends up taking the damage, and the
			one thing that must never take damage is our own bed. One attribute read, the
			same one the game marks it with. ]]
			if dblock:GetAttribute('Team'..(lplr:GetAttribute('Team') or -1)..'NoBreak') ~= nil then return end

			--[[ The recent-swing gate keeps the sword in hand mid-fight for callers that
			pass autotool=false. When the caller explicitly asked for AutoTool it has
			to win instead: Breaker runs its loop continuously, so with a killaura or
			autoclicker active lastAttack is refreshed constantly, this window never
			opened and the tool swap simply never happened -- the block got mined with
			whatever was already held. ]]
			local blockmeta = bedwars.ItemMeta[dblock.Name]
			blockmeta = blockmeta and blockmeta.block
			if blockmeta and (autotool or (workspace:GetServerTimeNow() - bedwars.SwordController.lastAttack) > 0.4) then
				local breaktype = blockmeta.breakType
				--[[ store.tools is only rebuilt when the Rodux inventory fires an items
				change, so it can still be empty (or stale) at the moment a break
				starts. Rescan on a miss rather than silently skipping the swap --
				a nil here meant the whole block below was skipped and the block got
				mined with the sword, which looks exactly like AutoTool doing nothing. ]]
				local tool = breaktype and (store.tools[breaktype] or getTool(breaktype))
				--[[ Exact type match first (shears for wool), then the best break tool
				carried (a pickaxe on wool). Gated on autotool so the other callers,
				which pass it nil, keep their previous hold-the-sword behaviour. ]]
				if not tool and autotool then
					tool = getBestBreakTool()
				end
				if tool and tool.tool then
					--[[ autotool: move the hotbar selection onto the tool the way the AutoTool
					module does it -- an InventorySelectHotbarSlot dispatch, i.e. the same
					path as pressing the number key -- so the swap happens through the
					game's own selection instead of a bare EquipItem. ]]
					local slot
					if autotool then
						for i, v in store.inventory.hotbar or {} do
							if v.item and v.item.itemType == tool.itemType then
								slot = i - 1
								break
							end
						end
					end
					--[[ Both, not either. The hotbar dispatch only moves the client's
					selected slot; it is not proof the character actually ended up
					holding the tool. Treating a successful dispatch as "done" and
					skipping the equip is what left the sword in hand while the UI
					showed the pickaxe selected -- and block damage is resolved from
					what is actually held (BlockEngine.calculateBlockDamage takes the
					player), so the block still got mined with the sword. switchItem
					no-ops when the tool is already in hand, so this costs nothing. ]]
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

			bedwars.ClientDamageBlock:Get('DamageBlock'):CallServerAsync({
				blockRef = {blockPosition = dpos},
				hitPosition = pos,
				hitNormal = Vector3.FromNormalId(Enum.NormalId.Top)
			}):andThen(function(result)
				if result then
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
				return pos, path, target
			end
		end
	end

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
		vapeEvents.InventoryChanged:Fire()
		if amount then
			vapeEvents.InventoryAmountChanged:Fire()
		end
	end

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
				--[[ keep tool cache synchronous (small scans, read elsewhere immediately) ]]
				store.tools.sword = getSword()
				for _, v in {'stone', 'wood', 'wool'} do
					store.tools[v] = getTool(v)
				end
				pendingAmount = true
			end

			if newinv.inventory.hand ~= oldinv.inventory.hand then
				local currentHand, toolType = new.Inventory.observedInventory.inventory.hand, ''
				if currentHand then
					local handData = bedwars.ItemMeta[currentHand.itemType]
					toolType = handData.sword and 'sword' or handData.block and 'block' or currentHand.itemType:find('bow') and 'bow'
				end

				store.hand = {
					tool = currentHand and currentHand.tool,
					amount = currentHand and currentHand.amount or 0,
					toolType = toolType
				}
			end

			--[[ Defer the event fan-out to end-of-frame so multiple dispatches in the
			same frame coalesce into a single notification to each listener. ]]
			if invChanged and not invFireQueued then
				invFireQueued = true
				task.defer(flushInventoryEvents)
			end
		end
	end

	local storeChanged = bedwars.Store.changed:connect(updateStore)
	updateStore(bedwars.Store:getState(), {})
	
	for _, event in {'MatchEndEvent', 'EntityDeathEvent', 'BedwarsBedBreak', 'BalloonPopped', 'AngelProgress', 'GrapplingHookFunctions'} do
		if not vape.Connections then return end
		bedwars.Client:WaitFor(event):andThen(function(connection)
			vape:Clean(connection:Connect(function(...)
				vapeEvents[event]:Fire(...)
			end))
		end)
	end
	
	vape:Clean(bedwars.ZapNetworking.EntityDamageEventZap.On(function(...)
		vapeEvents.EntityDamageEvent:Fire({
			entityInstance = ...,
			damage = select(2, ...),
			damageType = select(3, ...),
			fromPosition = select(4, ...),
			fromEntity = select(5, ...),
			knockbackMultiplier = select(6, ...),
			knockbackId = select(7, ...),
			disableDamageHighlight = select(13, ...)
		})
	end))

	--[[ cache projectile names we care about ]]
	local validProjectiles = {
		arrow = true,
		snowball = true
	}

	--[[ optimized ZapNetworking hook ]]
	vape:Clean(bedwars.ZapNetworking.ProjectileLaunchZap.On(function(origin, projectileType, tool, shooter)
		task.defer(function()
			local lowerType = tostring(projectileType):lower()
			if validProjectiles[lowerType] then
				--[[ only search nearby objects, not entire workspace ]]
				for _, obj in ipairs(workspace:GetChildren()) do
					if validProjectiles[obj.Name:lower()] then
						local root = obj:FindFirstChildWhichIsA("BasePart")
						if root and (root.Position - origin).Magnitude < 25 then
							vapeEvents.ProjectileFired:Fire({
								origin = origin,
								projectile = obj,
								tool = tool,
								shooter = shooter
							})
							break --[[ stop after first match ]]
						end
					end
				end
			end
		end)
	end))

	local projectileNames = {arrow = true, snowball = true}
	vape:Clean(workspace.ChildAdded:Connect(function(child)
		if projectileNames[child.Name:lower()] then
			task.defer(function()
				local root = child:FindFirstChildWhichIsA("BasePart")
				if root then
					vapeEvents.ProjectileFired:Fire({
						origin = root.Position,
						projectile = child,
						tool = nil,
						shooter = lplr.Character
					})
				end
			end)
		end
	end))
	
	for _, event in {'PlaceBlockEvent', 'BreakBlockEvent'} do
		vape:Clean(bedwars.ZapNetworking[event..'Zap'].On(function(...)
			local data = {
				blockRef = {
					blockPosition = ...,
				},
				player = select(5, ...)
			}
			vapeEvents[event]:Fire(data)
		end))
	end

	--[[
		Second argument is whatever owns the cleanup, and `gui` is not a name that exists in
		this file -- so all three of these passed nil and registered no cleanup at all.

		Each call opens two CollectionService signals per tag. Nothing disconnected them, so an
		uninject left them live and mutating tables the rest of the script had let go of, and a
		reinject in the same server (the Reinject button, a profile reset, a config sync) simply
		added another set on top. Every other collection() call site in this file and in
		bedwars.lua passes the module that owns it; these are file-level, so they belong to vape
		itself, which is what its Clean list is for.
	]]
	store.blocks = collection('block', vape)
	store.shop = collection({'BedwarsItemShop', 'TeamUpgradeShopkeeper'}, vape, function(tab, obj)
		table.insert(tab, {
			Id = obj.Name,
			RootPart = obj,
			Shop = obj:HasTag('BedwarsItemShop'),
			Upgrades = obj:HasTag('TeamUpgradeShopkeeper')
		})
	end)
	store.enchant = collection({'enchant-table', 'broken-enchant-table'}, vape, nil, function(tab, obj, tag)
		if obj:HasTag('enchant-table') and tag == 'broken-enchant-table' then return end
		obj = table.find(tab, obj)
		if obj then
			table.remove(tab, obj)
		end
	end)

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
			repeat task.wait() until store.matchState ~= 0 or vape.Loaded == nil
			if vape.Loaded == nil then return end
			mapname = workspace:WaitForChild('Map', 5):WaitForChild('Worlds', 5):GetChildren()[1].Name
			mapname = string.gsub(string.split(mapname, '_')[2] or mapname, '-', '') or 'Blank'
		end)
	end)

	vape:Clean(vapeEvents.BedwarsBedBreak.Event:Connect(function(bedTable)
		if bedTable.player and bedTable.player.UserId == lplr.UserId then
			beds:Increment()
		end
	end))

	vape:Clean(vapeEvents.MatchEndEvent.Event:Connect(function(winTable)
		if (bedwars.Store:getState().Game.myTeam or {}).id == winTable.winningTeamId or lplr.Neutral then
			wins:Increment()
		end
	end))

	vape:Clean(vapeEvents.EntityDeathEvent.Event:Connect(function(deathTable)
		local killer = playersService:GetPlayerFromCharacter(deathTable.fromEntity)
		local killed = playersService:GetPlayerFromCharacter(deathTable.entityInstance)
		if not killed or not killer then return end

		if killed ~= lplr and killer == lplr then
			kills:Increment()
		end
	end))

	task.spawn(function()
		repeat
			if entitylib.isAlive then
				entitylib.character.AirTime = entitylib.character.Humanoid.FloorMaterial ~= Enum.Material.Air and os.clock() or entitylib.character.AirTime
			end

			for _, v in entitylib.List do
				v.LandTick = math.abs(v.RootPart.Velocity.Y) < 0.1 and v.LandTick or os.clock()
				if (os.clock() - v.LandTick) > 0.2 and v.Jumps ~= 0 then
					v.Jumps = 0
					v.Jumping = false
				end
			end
			task.wait()
		until vape.Loaded == nil
	end)

	pcall(function()
		if getthreadidentity and setthreadidentity then
			local old = getthreadidentity()
			setthreadidentity(2)

			bedwars.Shop = require(replicatedStorage.TS.games.bedwars.shop['bedwars-shop']).BedwarsShop
			bedwars.ShopItems = debug.getupvalue(debug.getupvalue(bedwars.Shop.getShopItem, 1), 2)
			bedwars.Shop.getShopItem('iron_sword', lplr)

			setthreadidentity(old)
			store.shopLoaded = true
		else
			task.spawn(function()
				repeat
					task.wait(0.1)
				until vape.Loaded == nil or bedwars.AppController:isAppOpen('BedwarsItemShopApp')

				bedwars.Shop = require(replicatedStorage.TS.games.bedwars.shop['bedwars-shop']).BedwarsShop
				bedwars.ShopItems = debug.getupvalue(debug.getupvalue(bedwars.Shop.getShopItem, 1), 2)
				store.shopLoaded = true
			end)
		end
	end)

	vape:Clean(function()
		Client.Get = OldGet
		bedwars.BlockController.isBlockBreakable = OldBreak
		store.blockPlacer:disable()
		for _, v in vapeEvents do
			v:Destroy()
		end
		table.clear(store.blockPlacer)
		table.clear(vapeEvents)
		table.clear(bedwars)
		table.clear(store)
		table.clear(sides)
		table.clear(remotes)
		storeChanged:disconnect()
		storeChanged = nil
	end)
end)

for _, v in {'AntiRagdoll', 'TriggerBot', 'SilentAim', 'AutoRejoin', 'Rejoin', 'Disabler', 'Timer', 'ServerHop', 'MouseTP', 'MurderMystery', 'Swim', 'Jesus', 'Invisible', 'Desync', 'Waypoints', 'PlayerModel', 'Schematica'} do
	vape:Remove(v)
end
run(function()
	local AimAssist
	local Targets
	local Sort
	local AimSpeed
	local Distance
	local AngleSlider
	local StrafeIncrease
	local KillauraTarget
	local ClickAim
	local Shake

	--[[ Shake nudges the aim off the target's RootPart by a random angle. Rolled as an
	ANGLE rather than a world-space offset so the slider means the same thing at 3
	studs as it does at 30 -- a fixed stud offset is a wild swing up close and nothing
	at range.

	The slider is a percentage of shakemax rather than raw degrees: past about five
	degrees the aim is no longer pointed at anyone, so the useful range was crammed
	into the bottom of a degree scale. 100% is shakemax and the two layers below are
	budgeted to hit exactly that at the extreme, so the number on the slider is the
	real fraction of full deflection.

	Two layers, because either alone falls flat. The wander re-rolls a direction every
	15-45ms and is chased fast enough to nearly arrive before the next roll; on its own
	it still traces a continuous path and reads as drift. The per-frame noise on top is
	untracked white noise, and that is the layer that actually reads as jitter. Split
	60/40 so the pair tops out at the slider's percentage rather than 1.6x it. ]]
	local shakemax = 5 --[[ degrees of deflection at 100% ]]
	local rand = Random.new()
	local shakeoffset, shaketarget, shakestamp = Vector2.zero, Vector2.zero, 0
	local shakeapplied = CFrame.identity

	local function shakeRotation(dt)
		if Shake.Value <= 0 then
			shakeoffset, shaketarget = Vector2.zero, Vector2.zero
			return CFrame.identity
		end
		if os.clock() >= shakestamp then
			--[[ the interval is itself random, so there is no steady beat to the wander ]]
			shakestamp = os.clock() + rand:NextNumber(0.015, 0.045)
			shaketarget = Vector2.new(rand:NextNumber(-1, 1), rand:NextNumber(-1, 1))
		end
		--[[ dt-scaled so the chase rate is the same on 30fps and 240fps, clamped so a frame
		spike can't overshoot past the target ]]
		shakeoffset = shakeoffset:Lerp(shaketarget, math.min(dt * 45, 1))
		local noise = Vector2.new(rand:NextNumber(-1, 1), rand:NextNumber(-1, 1))
		local offset = (shakeoffset * 0.6) + (noise * 0.4)
		local amount = math.rad(shakemax * (Shake.Value / 100))
		return CFrame.Angles(offset.Y * amount, offset.X * amount, 0)
	end

	--[[ Ignore decoy/NPC models named "Falcon" (e.g. workspace["Falcon-1"]).
	A real player named Falcon still has a backing Player object AND a valid
	(hyphen-free) username, so gating on "no Player" only skips fake models
	while never sparing an actual person called Falcon. ]]
	local function isFalconDecoy(ent)
		if not ent or ent.Player then return false end
		local name = ent.Character and ent.Character.Name
		return name ~= nil and (name == 'Falcon' or name:match('^Falcon%-') ~= nil)
	end

	AimAssist = vape.Categories.Combat:CreateModule({
		Name = 'AimAssist',
		Function = function(callback)
			if not callback then
				--[[ nothing is going to strip it back off once we stop writing the camera,
				and a stale one would be subtracted from a camera that no longer holds
				it on the first frame after a re-enable ]]
				shakeapplied = CFrame.identity
				shakeoffset, shaketarget = Vector2.zero, Vector2.zero
			end
			if callback then
				AimAssist:Clean(runService.Heartbeat:Connect(function(dt)
					if entitylib.isAlive and store.hand.toolType == 'sword' and ((not ClickAim.Enabled) or (os.clock() - bedwars.SwordController.lastSwing) < 0.4) then
						local ent = not KillauraTarget.Enabled and entitylib.EntityPosition({
							Range = Distance.Value,
							Part = 'RootPart',
							Wallcheck = Targets.Walls.Enabled,
							Players = Targets.Players.Enabled,
							NPCs = Targets.NPCs.Enabled,
							Sort = sortmethods[Sort.Value]
						}) or store.KillauraTarget
	
						if ent then
							if isFalconDecoy(ent) then return end
							local delta = (ent.RootPart.Position - entitylib.character.RootPart.Position)
							local localfacing = entitylib.character.RootPart.CFrame.LookVector * Vector3.new(1, 0, 1)
							local angle = math.acos(localfacing:Dot((delta * Vector3.new(1, 0, 1)).Unit))
							if angle >= (math.rad(AngleSlider.Value) / 2) then return end
							targetinfo.Targets[ent] = tick() + 1
							local aimspeed = AimSpeed.Value + (StrafeIncrease.Enabled and (inputService:IsKeyDown(Enum.KeyCode.A) or inputService:IsKeyDown(Enum.KeyCode.D)) and 10 or 0)
							--[[ Strip last frame's shake, aim from that, then hang this frame's
							off the result -- the shake sits OUTSIDE the aim lerp. Folded
							into the lerp target it was a low-pass away from invisible: at
							the default aim speed the camera closes only ~10% of the gap per
							frame, so anything re-rolled faster than a few Hz averaged out
							to almost nothing no matter what the slider said. Stripping it
							first is also what keeps the leftovers from compounding frame
							over frame into a slow wander. ]]
							local base = gameCamera.CFrame * shakeapplied:Inverse()
							local aimed = base:Lerp(CFrame.lookAt(base.p, ent.RootPart.Position), aimspeed * dt)
							shakeapplied = shakeRotation(dt)
							gameCamera.CFrame = aimed * shakeapplied
						end
					end
				end))
			end
		end,
		Tooltip = 'Smoothly pulls your aim onto the closest target while you have a sword out'
	})
	Targets = AimAssist:CreateTargets({
		Players = true,
		Walls = true
	})
	local methods = {'Damage', 'Distance'}
	for i in sortmethods do
		if not table.find(methods, i) then
			table.insert(methods, i)
		end
	end
	Sort = AimAssist:CreateDropdown({
		Name = 'Target Mode',
		List = methods
	})
	AimSpeed = AimAssist:CreateSlider({
		Name = 'Aim Speed',
		Min = 1,
		Max = 20,
		Default = 6
	})
	Distance = AimAssist:CreateSlider({
		Name = 'Distance',
		Min = 1,
		Max = 30,
		Default = 30,
		--[[ 'Suffx' was a typo, so the slider drew a bare number with no unit. ]]
		Suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
	AngleSlider = AimAssist:CreateSlider({
		Name = 'Max angle',
		Min = 1,
		Max = 360,
		Default = 70
	})
	Shake = AimAssist:CreateSlider({
		Name = 'Shake',
		Min = 0,
		Max = 100,
		Default = 0,
		Suffix = '%',
		Tooltip = 'Adds a bit of random wobble to your aim.\n0 is dead centre, 100 is a full 5 degrees off.'
	})
	ClickAim = AimAssist:CreateToggle({
		Name = 'Click Aim',
		Default = true
	})
	KillauraTarget = AimAssist:CreateToggle({
		Name = 'Use killaura target'
	})
	StrafeIncrease = AimAssist:CreateToggle({Name = 'Strafe increase'})
end)
	
run(function()
	local old
	
	vape.Categories.Combat:CreateModule({
		Name = 'NoClickDelay',
		Function = function(callback)
			if callback then
				old = bedwars.SwordController.isClickingTooFast
				bedwars.SwordController.isClickingTooFast = function(self)
					self.lastSwing = os.clock()
					return false
				end
			else
				bedwars.SwordController.isClickingTooFast = old
			end
		end,
		Tooltip = 'Takes the CPS cap off'
	})
end)
	
run(function()
	local Value
	
	Reach = vape.Categories.Combat:CreateModule({
		Name = 'Reach',
		Function = function(callback)
			bedwars.CombatConstant.RAYCAST_SWORD_CHARACTER_DISTANCE = callback and Value.Value + 2 or 14.4
		end,
		Tooltip = 'Lets you hit from further away'
	})
	Value = Reach:CreateSlider({
		Name = 'Range',
		Min = 0,
		Max = 18,
		Default = 18,
		Function = function(val)
			if Reach.Enabled then
				bedwars.CombatConstant.RAYCAST_SWORD_CHARACTER_DISTANCE = val + 2
			end
		end,
		Suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
end)
	
run(function()
	local Sprint
	local old
	
	Sprint = vape.Categories.Combat:CreateModule({
		Name = 'Sprint',
		Function = function(callback)
			if callback then
				old = bedwars.SprintController.stopSprinting
				bedwars.SprintController.stopSprinting = function(...)
					local call = old(...)
					bedwars.SprintController:startSprinting()
					return call
				end
				Sprint:Clean(entitylib.Events.LocalAdded:Connect(function() 
					task.delay(0.1, function() 
						bedwars.SprintController:stopSprinting() 
					end) 
				end))
				bedwars.SprintController:stopSprinting()
			else
				bedwars.SprintController.stopSprinting = old
				bedwars.SprintController:stopSprinting()
			end
		end,
		Tooltip = 'Keeps you sprinting without holding the key.'
	})
end)
	
run(function()
	local TriggerBot
	local CPS
	local rayParams = RaycastParams.new()
	
	TriggerBot = vape.Categories.Combat:CreateModule({
		Name = 'TriggerBot',
		Function = function(callback)
			if callback then
				repeat
					local doAttack
					if not bedwars.AppController:isLayerOpen(bedwars.UILayers.MAIN) then
						if entitylib.isAlive and store.hand.toolType == 'sword' and bedwars.DaoController.chargingMaid == nil then
							local attackRange = bedwars.ItemMeta[store.hand.tool.Name].sword.attackRange
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
	
							doAttack = doAttack or bedwars.SwordController:getTargetInRegion(attackRange or 3.8 * 3, 0)
							if doAttack then
								bedwars.SwordController:swingSwordAtMouse()
							end
						end
					end
	
					task.wait(doAttack and 1 / CPS.GetRandomValue() or 0.016)
				until not TriggerBot.Enabled
			end
		end,
		Tooltip = 'Swings on its own when your cursor is over someone'
	})
	CPS = TriggerBot:CreateTwoSlider({
		Name = 'CPS',
		Min = 1,
		Max = 9,
		DefaultMin = 7,
		DefaultMax = 7
	})
end)
	
run(function()
	local Velocity
	local Horizontal
	local Vertical
	local Chance
	local TargetCheck
	local rand, old = Random.new()
	
	Velocity = vape.Categories.Combat:CreateModule({
		Name = 'Velocity',
		Function = function(callback)
			if callback then
				old = bedwars.KnockbackUtil.applyKnockback
				bedwars.KnockbackUtil.applyKnockback = function(root, mass, dir, knockback, ...)
					if rand:NextNumber(0, 100) > Chance.Value then return end
					local check = (not TargetCheck.Enabled) or entitylib.EntityPosition({
						Range = 50,
						Part = 'RootPart',
						Players = true
					})
	
					if check then
						knockback = knockback or {}
						if Horizontal.Value == 0 and Vertical.Value == 0 then return end
						knockback.horizontal = (knockback.horizontal or 1) * (Horizontal.Value / 100)
						knockback.vertical = (knockback.vertical or 1) * (Vertical.Value / 100)
					end
					
					return old(root, mass, dir, knockback, ...)
				end
			else
				bedwars.KnockbackUtil.applyKnockback = old
			end
		end,
		Tooltip = 'Takes some of the knockback off you'
	})
	Horizontal = Velocity:CreateSlider({
		Name = 'Horizontal',
		Min = 0,
		Max = 100,
		Default = 0,
		Suffix = function(val) return '%' end
	})
	Vertical = Velocity:CreateSlider({
		Name = 'Vertical',
		Min = 0,
		Max = 100,
		Default = 0,
		Suffix = function(val) return '%' end
	})
	Chance = Velocity:CreateSlider({
		Name = 'Chance',
		Min = 0,
		Max = 100,
		Default = 100,
		Suffix = function(val) return '%' end
	})
	TargetCheck = Velocity:CreateToggle({Name = 'Only when targeting'})
end)
	
local AntiFallDirection
run(function()
	local AntiFall
	local Mode
	local Material
	local Color
	local rayCheck = RaycastParams.new()
	rayCheck.RespectCanCollide = true

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

	AntiFall = vape.Categories.Blatant:CreateModule({
		Name = 'AntiFall',
		Function = function(callback)
			if callback then
				repeat task.wait(0.1) until store.matchState ~= 0 or (not AntiFall.Enabled)
				if not AntiFall.Enabled then return end

				local pos, debounce = getLowGround(), os.clock()
				if pos ~= math.huge then
					AntiFallPart = Instance.new('Part')
					AntiFallPart.Size = Vector3.new(10000, 1, 10000)
					AntiFallPart.Transparency = 1 - Color.Opacity
					AntiFallPart.Material = Enum.Material[Material.Value]
					AntiFallPart.Color = Color3.fromHSV(Color.Hue, Color.Sat, Color.Value)
					AntiFallPart.Position = Vector3.new(0, pos - 2, 0)
					AntiFallPart.CanCollide = Mode.Value == 'Collide'
					AntiFallPart.Anchored = true
					AntiFallPart.CanQuery = false
					AntiFallPart.Parent = workspace
					AntiFall:Clean(AntiFallPart)
					AntiFall:Clean(AntiFallPart.Touched:Connect(function(touched)
						if touched.Parent == lplr.Character and entitylib.isAlive and debounce < os.clock() then
							debounce = os.clock() + 0.1
							if Mode.Value == 'Normal' then
								local top = getNearGround()
								if top then
									local lastTeleport = lplr:GetAttribute('LastTeleported')
									local connection
									connection = runService.PreSimulation:Connect(function()
										if vape.Modules.Fly.Enabled or vape.Modules.LongJump.Enabled then
											connection:Disconnect()
											AntiFallDirection = nil
											return
										end

										if entitylib.isAlive and lplr:GetAttribute('LastTeleported') == lastTeleport then
											local delta = ((top - entitylib.character.RootPart.Position) * Vector3.new(1, 0, 1))
											local root = entitylib.character.RootPart
											AntiFallDirection = delta.Unit == delta.Unit and delta.Unit or Vector3.zero
											root.Velocity *= Vector3.new(1, 0, 1)
											rayCheck.FilterDescendantsInstances = {gameCamera, lplr.Character}
											rayCheck.CollisionGroup = root.CollisionGroup

											local ray = workspace:Raycast(root.Position, AntiFallDirection, rayCheck)
											if ray then
												for _ = 1, 10 do
													local dpos = roundPos(ray.Position + ray.Normal * 1.5) + Vector3.new(0, 3, 0)
													if not getPlacedBlock(dpos) then
														top = Vector3.new(top.X, pos.Y, top.Z)
														break
													end
												end
											end

											root.CFrame += Vector3.new(0, top.Y - root.Position.Y, 0)
											if not frictionTable.Speed then
												root.AssemblyLinearVelocity = (AntiFallDirection * getSpeed()) + Vector3.new(0, root.AssemblyLinearVelocity.Y, 0)
											end

											if delta.Magnitude < 1 then
												connection:Disconnect()
												AntiFallDirection = nil
											end
										else
											connection:Disconnect()
											AntiFallDirection = nil
										end
									end)
									AntiFall:Clean(connection)
								end
							elseif Mode.Value == 'Velocity' then
								entitylib.character.RootPart.Velocity = Vector3.new(entitylib.character.RootPart.Velocity.X, 100, entitylib.character.RootPart.Velocity.Z)
							end
						end
					end))
				end
			else
				AntiFallDirection = nil
			end
		end,
		Tooltip = 'Helps you with your Parkinsons.\nCatches you before you go into the void.'
	})
	Mode = AntiFall:CreateDropdown({
		Name = 'Move Mode',
		List = {'Normal', 'Collide', 'Velocity'},
		Function = function(val)
			if AntiFallPart then
				AntiFallPart.CanCollide = val == 'Collide'
			end
		end,
	Tooltip = 'Normal - eases you back to the nearest safe spot\nVelocity - throws you upward the moment you touch it\nCollide - just lets you walk on the part'
	})
	local materials = {'ForceField'}
	for _, v in Enum.Material:GetEnumItems() do
		if v.Name ~= 'ForceField' then
			table.insert(materials, v.Name)
		end
	end
	Material = AntiFall:CreateDropdown({
		Name = 'Material',
		List = materials,
		Function = function(val)
			if AntiFallPart then
				AntiFallPart.Material = Enum.Material[val]
			end
		end
	})
	Color = AntiFall:CreateColorSlider({
		Name = 'Color',
		DefaultOpacity = 0.5,
		Function = function(h, s, v, o)
			if AntiFallPart then
				AntiFallPart.Color = Color3.fromHSV(h, s, v)
				AntiFallPart.Transparency = 1 - o
			end
		end
	})
end)
	
run(function()
	local FastBreak
	local Time
	local BlacklistBeds
	local BlacklistOres
	local BlacklistHive

	--[[ The cooldown the game ships with, restored on disable and used as the "don't
	speed this one up" value for blacklisted blocks. ]]
	local VANILLA_COOLDOWN = 0.3

	--[[ Name of the block currently under the crosshair, read through the same block
	selector AutoTool and Schematica use. Mode 1 is SELECT (the block being looked
	at); mode 0 is PLACE, which resolves to the empty cell in front of it instead. ]]
	local function targetedBlockName()
		local ok, name = pcall(function()
			local breaker = bedwars.BlockBreakController.blockBreaker
			local info = breaker.clientManager:getBlockSelector():getMouseInfo(1)
			local target = info and info.target
			local block = target and target.blockInstance
			return block and block.Name
		end)
		return ok and name or nil
	end

	--[[ Ores are named <material>_ore_mesh_block. Matched as a plain substring plus a
	trailing _ore, so diamond/emerald/gold are covered without hardcoding a list
	that a new ore would silently fall out of. Neither pattern can hit 'store' or
	'core' -- both need the underscore. ]]
	local function isOre(name)
		return name:find('ore_mesh_block', 1, true) ~= nil or name:match('_ore$') ~= nil
	end

	local function currentCooldown()
		local name = targetedBlockName()
		if name then
			if BlacklistBeds.Enabled and name == 'bed' then return VANILLA_COOLDOWN end
			if BlacklistOres.Enabled and isOre(name) then return VANILLA_COOLDOWN end
			if BlacklistHive.Enabled and name == 'beehive' then return VANILLA_COOLDOWN end
		end
		return Time.Value
	end

	FastBreak = vape.Categories.Blatant:CreateModule({
		Name = 'FastBreak',
		Function = function(callback)
			if callback then
				repeat
					--[[ With every blacklist off this is the original once-per-100ms
					setCooldown and costs exactly what it used to. With one on we need
					to react the frame the crosshair moves onto a blacklisted block,
					otherwise the stale value lets a fast hit or two through before the
					next poll catches up -- so tighten to per-frame only in that case. ]]
					local filtering = BlacklistBeds.Enabled or BlacklistOres.Enabled or BlacklistHive.Enabled
					bedwars.BlockBreakController.blockBreaker:setCooldown(filtering and currentCooldown() or Time.Value)
					if filtering then
						task.wait()
					else
						task.wait(0.1)
					end
				until not FastBreak.Enabled
			else
				bedwars.BlockBreakController.blockBreaker:setCooldown(VANILLA_COOLDOWN)
			end
		end,
		Tooltip = 'Cuts down the cooldown between block hits'
	})
	Time = FastBreak:CreateSlider({
		Name = 'Break speed',
		Min = 0,
		Max = 0.3,
		Default = 0.25,
		Decimal = 100,
		Suffix = function(val) return 's' end
	})
	BlacklistBeds = FastBreak:CreateToggle({
		Name = 'Blacklist Bed',
		Tooltip = 'Leaves beds at normal breaking speed'
	})
	BlacklistOres = FastBreak:CreateToggle({
		Name = 'Blacklist Ore',
		Tooltip = 'Leaves ores at normal breaking speed'
	})
	BlacklistHive = FastBreak:CreateToggle({
		Name = 'Blacklist Hive',
		Tooltip = 'Leaves beehives at normal breaking speed'
	})
end)
	
local Fly
local LongJump
run(function()
	local Value
	local VerticalValue
	local WallCheck
	local PopBalloons
	local rayCheck = RaycastParams.new()
	rayCheck.RespectCanCollide = true
	local up, down, old = 0, 0

	Fly = vape.Categories.Blatant:CreateModule({
		Name = 'Fly',
		Function = function(callback)
			frictionTable.Fly = callback or nil
			updateVelocity()
			if callback then
				up, down, old = 0, 0, bedwars.BalloonController.deflateBalloon
				bedwars.BalloonController.deflateBalloon = function() end

				if lplr.Character and (lplr.Character:GetAttribute('InflatedBalloons') or 0) == 0 and getItem('balloon') then
					bedwars.BalloonController:inflateBalloon()
				end

				Fly:Clean(vapeEvents.AttributeChanged.Event:Connect(function(changed)
					if changed == 'InflatedBalloons' and (lplr.Character:GetAttribute('InflatedBalloons') or 0) == 0 and getItem('balloon') then
						bedwars.BalloonController:inflateBalloon()
					end
				end))

				Fly:Clean(runService.PreSimulation:Connect(function(dt)
					if entitylib.isAlive and isnetworkowner(entitylib.character.RootPart) then
						local char = entitylib.character
						local balloons = lplr.Character:GetAttribute('InflatedBalloons')  --[[ one attribute read, not two ]]
						local flyAllowed = (balloons and balloons > 0) or store.matchState == 2
						local mass = (1.5 + (flyAllowed and 6 or 0) * (os.clock() % 0.4 < 0.2 and -1 or 1)) + ((up + down) * VerticalValue.Value)
						local root, moveDirection = char.RootPart, char.Humanoid.MoveDirection
						local velo = getSpeed()
						local destination = (moveDirection * math.max(Value.Value - velo, 0) * dt)
						rayCheck.FilterDescendantsInstances = {lplr.Character, gameCamera, AntiFallPart}
						rayCheck.CollisionGroup = root.CollisionGroup

						if WallCheck.Enabled then
							local ray = workspace:Raycast(root.Position, destination, rayCheck)
							if ray then
								destination = ((ray.Position + ray.Normal) - root.Position)
							end
						end

						root.CFrame += destination
						root.AssemblyLinearVelocity = (moveDirection * velo) + Vector3.new(0, mass, 0)
					end
				end))

				Fly:Clean(inputService.InputBegan:Connect(function(input)
					if not inputService:GetFocusedTextBox() then
						if input.KeyCode == Enum.KeyCode.Space or input.KeyCode == Enum.KeyCode.ButtonA then
							up = 1
						elseif input.KeyCode == Enum.KeyCode.LeftShift or input.KeyCode == Enum.KeyCode.ButtonL2 then
							down = -1
						end
					end
				end))

				Fly:Clean(inputService.InputEnded:Connect(function(input)
					if input.KeyCode == Enum.KeyCode.Space or input.KeyCode == Enum.KeyCode.ButtonA then
						up = 0
					elseif input.KeyCode == Enum.KeyCode.LeftShift or input.KeyCode == Enum.KeyCode.ButtonL2 then
						down = 0
					end
				end))

				if inputService.TouchEnabled then
					pcall(function()
						local jumpButton = lplr.PlayerGui.TouchGui.TouchControlFrame.JumpButton
						Fly:Clean(jumpButton:GetPropertyChangedSignal('ImageRectOffset'):Connect(function()
							up = jumpButton.ImageRectOffset.X == 146 and 1 or 0
						end))
					end)
				end
			else
				bedwars.BalloonController.deflateBalloon = old
				if PopBalloons.Enabled and entitylib.isAlive and (lplr.Character:GetAttribute('InflatedBalloons') or 0) > 0 then
					for _ = 1, 3 do
						bedwars.BalloonController:deflateBalloon()
					end
				end
			end
		end,
		ExtraText = function()
			return 'Heatseeker'
		end,
		Tooltip = 'Makes you go zoom.'
	})

	Value = Fly:CreateSlider({
		Name = 'Speed',
		Min = 1,
		Max = 23,
		Default = 23,
		Suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})

	VerticalValue = Fly:CreateSlider({
		Name = 'Vertical Speed',
		Min = 1,
		Max = 150,
		Default = 50,
		Suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})

	WallCheck = Fly:CreateToggle({
		Name = 'Wall Check',
		Default = true
	})

	PopBalloons = Fly:CreateToggle({
		Name = 'Pop Balloons',
		Default = true
	})
end)
	
run(function()
	local Mode
	local Expand
	local objects, set = {}
	
	local function createHitbox(ent)
		if ent.Targetable and ent.Player then
			local hitbox = Instance.new('Part')
			hitbox.Size = Vector3.new(3, 6, 3) + Vector3.one * (Expand.Value / 5)
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
	
	HitBoxes = vape.Categories.Blatant:CreateModule({
		Name = 'HitBoxes',
		Function = function(callback)
			if callback then
				if Mode.Value == 'Sword' then
					debug.setconstant(bedwars.SwordController.swingSwordInRegion, 6, (Expand.Value / 3))
					set = true
				else
					HitBoxes:Clean(entitylib.Events.EntityAdded:Connect(createHitbox))
					HitBoxes:Clean(entitylib.Events.EntityRemoving:Connect(function(ent)
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
					debug.setconstant(bedwars.SwordController.swingSwordInRegion, 6, 3.8)
					set = nil
				end
				for _, part in objects do
					part:Destroy()
				end
				table.clear(objects)
			end
		end,
		Tooltip = 'Grows the hitbox you attack into'
	})
	Mode = HitBoxes:CreateDropdown({
		Name = 'Mode',
		List = {'Sword', 'Player'},
		Function = function()
			if HitBoxes.Enabled then
				HitBoxes:Toggle()
				HitBoxes:Toggle()
			end
		end,
		Tooltip = 'Sword - widens the range you can hit people from\nPlayer - grows the players own hitboxes'
	})
	Expand = HitBoxes:CreateSlider({
		Name = 'Expand amount',
		Min = 0,
		Max = 14.4,
		Default = 14.4,
		Decimal = 10,
		Function = function(val)
			if HitBoxes.Enabled then
				if Mode.Value == 'Sword' then
					debug.setconstant(bedwars.SwordController.swingSwordInRegion, 6, (val / 3))
				else
					for _, part in objects do
						part.Size = Vector3.new(3, 6, 3) + Vector3.one * (val / 5)
					end
				end
			end
		end,
		Suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
end)
	
run(function()
	vape.Categories.Blatant:CreateModule({
		Name = 'KeepSprint',
		Function = function(callback)
			debug.setconstant(bedwars.SprintController.startSprinting, 5, callback and 'blockSprinting' or 'blockSprint')
			bedwars.SprintController:stopSprinting()
		end,
		Tooltip = 'Lets you keep sprinting while a speed potion is up.'
	})
end)

run(function()
	local SafeWalk
	local rayCheck = RaycastParams.new()
	rayCheck.RespectCanCollide = true
	local module, old
	
	SafeWalk = vape.Categories.World:CreateModule({
		Name = 'SafeWalk',
		Function = function(callback)
			if callback then
				if not module then
					local suc = pcall(function() 
						module = require(lplr.PlayerScripts.PlayerModule).controls 
					end)
					if not suc then module = {} end
				end
				
				old = module.moveFunction
				module.moveFunction = function(self, vec, face)
					if entitylib.isAlive then
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
			else
				if module and old then
					module.moveFunction = old
				end
			end
		end,
		Tooltip = 'Stops you walking off the edge of a block'
	})
end)

run(function()
	local old
	
	vape.Categories.Blatant:CreateModule({
		Name = 'NoSlowdown',
		Function = function(callback)
			local modifier = bedwars.SprintController:getMovementStatusModifier()
			if callback then
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
		Tooltip = 'Keeps you at full speed while youre using items.'
	})
end)
	
run(function()
	local Speed
	local Value
	local WallCheck
	local AutoJump
	local AlwaysJump
	local rayCheck = RaycastParams.new()
	rayCheck.RespectCanCollide = true
	
	Speed = vape.Categories.Blatant:CreateModule({
		Name = 'Speed',
		Function = function(callback)
			frictionTable.Speed = callback or nil
			updateVelocity()
			pcall(function()
				debug.setconstant(bedwars.WindWalkerController.updateSpeed, 7, callback and 'constantSpeedMultiplier' or 'moveSpeedMultiplier')
			end)
	
			if callback then
				Speed:Clean(runService.PreSimulation:Connect(function(dt)
					bedwars.StatefulEntityKnockbackController.lastImpulseTime = callback and math.huge or time()
						if entitylib.isAlive and not Fly.Enabled and not vape.Modules.LongJump.Enabled and isnetworkowner(entitylib.character.RootPart) then
						local char = entitylib.character
						local hum = char.Humanoid
						local state = hum:GetState()
						if state == Enum.HumanoidStateType.Climbing then return end

						local root, velo = char.RootPart, getSpeed()
						local moveDirection = AntiFallDirection or hum.MoveDirection
						local destination = (moveDirection * math.max(Value.Value - velo, 0) * dt)
	
						if WallCheck.Enabled then
							rayCheck.FilterDescendantsInstances = {lplr.Character, gameCamera}
							rayCheck.CollisionGroup = root.CollisionGroup
							local ray = workspace:Raycast(root.Position, destination, rayCheck)
							if ray then
								destination = ((ray.Position + ray.Normal) - root.Position)
							end
						end
	
						root.CFrame += destination
						root.AssemblyLinearVelocity = (moveDirection * velo) + Vector3.new(0, root.AssemblyLinearVelocity.Y, 0)
						-- `Attacking` is a bare global on purpose: bedwars.lua's Killaura sets it
						-- every Heartbeat and the two chunks share one environment. Do not turn it
						-- into a local here or in bedwars.lua without moving it onto genv first --
						-- this is the only thing that tells AutoJump a swing is in progress.
						if AutoJump.Enabled and (state == Enum.HumanoidStateType.Running or state == Enum.HumanoidStateType.Landed) and moveDirection ~= Vector3.zero and (Attacking or AlwaysJump.Enabled) then
							hum:ChangeState(Enum.HumanoidStateType.Jumping)
						end
					end
				end))
			end
		end,
		ExtraText = function()
			return 'Heatseeker'
		end,
		Tooltip = 'Speeds you up. Pick whichever method works best for you.'
	})
	Value = Speed:CreateSlider({
		Name = 'Speed',
		Min = 1,
		Max = 23,
		Default = 23,
		Suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
	WallCheck = Speed:CreateToggle({
		Name = 'Wall Check',
		Default = true
	})
	AutoJump = Speed:CreateToggle({
		Name = 'AutoJump',
		Function = function(callback)
			AlwaysJump.Object.Visible = callback
		end
	})
	AlwaysJump = Speed:CreateToggle({
		Name = 'Always Jump',
		Visible = false,
		Darker = true
	})
end)
	
run(function()
	local BedESP
	local Reference = {}
	local Folder = Instance.new('Folder')
	Folder.Parent = vape.gui
	
	local function Added(bed)
		if not BedESP.Enabled then return end
		local BedFolder = Instance.new('Folder')
		BedFolder.Parent = Folder
		Reference[bed] = BedFolder
		local parts = bed:GetChildren()
		table.sort(parts, function(a, b)
			return a.Name > b.Name
		end)
	
		for _, part in parts do
			if part:IsA('BasePart') and part.Name ~= 'Blanket' then
				local handle = Instance.new('BoxHandleAdornment')
				handle.Size = part.Size + Vector3.new(.01, .01, .01)
				handle.AlwaysOnTop = true
				handle.ZIndex = 2
				handle.Visible = true
				handle.Adornee = part
				handle.Color3 = part.Color
				if part.Name == 'Legs' then
					handle.Color3 = Color3.fromRGB(167, 112, 64)
					handle.Size = part.Size + Vector3.new(.01, -1, .01)
					handle.CFrame = CFrame.new(0, -0.4, 0)
					handle.ZIndex = 0
				end
				handle.Parent = BedFolder
			end
		end
	
		table.clear(parts)
	end
	
	BedESP = vape.Categories.Render:CreateModule({
		Name = 'BedESP',
		Function = function(callback)
			if callback then
				BedESP:Clean(collectionService:GetInstanceAddedSignal('bed'):Connect(function(bed)
					task.delay(0.2, Added, bed)
				end))
				BedESP:Clean(collectionService:GetInstanceRemovedSignal('bed'):Connect(function(bed)
					if Reference[bed] then
						Reference[bed]:Destroy()
						Reference[bed] = nil
					end
				end))
				for _, bed in collectionService:GetTagged('bed') do
					Added(bed)
				end
			else
				Folder:ClearAllChildren()
				table.clear(Reference)
			end
		end,
		Tooltip = 'Shows beds through walls'
	})
end)
	
run(function()
	local Health
	
	Health = vape.Categories.Render:CreateModule({
		Name = 'Health',
		Function = function(callback)
			if callback then
				local label = Instance.new('TextLabel')
				label.Size = UDim2.fromOffset(100, 20)
				label.Position = UDim2.new(0.5, 6, 0.5, 30)
				label.BackgroundTransparency = 1
				label.AnchorPoint = Vector2.new(0.5, 0)
				label.Text = entitylib.isAlive and math.round(lplr.Character:GetAttribute('Health'))..' ❤️' or ''
				label.TextColor3 = entitylib.isAlive and Color3.fromHSV((lplr.Character:GetAttribute('Health') / lplr.Character:GetAttribute('MaxHealth')) / 2.8, 0.86, 1) or Color3.new()
				label.TextSize = 18
				label.Font = Enum.Font.Arial
				label.Parent = vape.gui
				Health:Clean(label)
				Health:Clean(vapeEvents.AttributeChanged.Event:Connect(function()
					label.Text = entitylib.isAlive and math.round(lplr.Character:GetAttribute('Health'))..' ❤️' or ''
					label.TextColor3 = entitylib.isAlive and Color3.fromHSV((lplr.Character:GetAttribute('Health') / lplr.Character:GetAttribute('MaxHealth')) / 2.8, 0.86, 1) or Color3.new()
				end))
			end
		end,
		Tooltip = 'Puts your health right in the middle of your screen.'
	})
end)
	
run(function()
    local KitESP
    local Background
    local Color = {}
    local Reference = {}
    --[[ model -> adornee part recorded at billboard creation, so removal cleanup
    doesn't depend on PrimaryPart still being set (it's often nil by then) ]]
    local ModelParts = {}
    --[[ per-kit tag connections, disconnected whenever the tracked kit changes ]]
    local kitConns = {}
    local Folder = Instance.new('Folder')
    Folder.Parent = vape.gui

    local ESPKits = {
        alchemist = {'alchemist_ingedients', 'wild_flower'},
        beekeeper = {'bee', 'bee'},
        bigman = {'treeOrb', 'natures_essence_1'},
        ghost_catcher = {'ghost', 'ghost_orb'},
        metal_detector = {'hidden-metal', 'iron'},
        sheep_herder = {'SheepModel', 'purple_hay_bale'},
        sorcerer = {'alchemy_crystal', 'wild_flower'},
        star_collector = {'stars', 'crit_star'}
    }

    local function Added(v, icon)
        if not v then return end
        --[[ Billboards live under vape.gui (CoreGui). Tag/added signals invoke this
        on game threads at identity 2, where parenting into CoreGui silently
        throws — which is why only enable-time (exploit thread) objects showed. ]]
        if vape.ThreadFix then
            setthreadidentity(8)
        end
        if Reference[v] then
            if Reference[v].Billboard then
                Reference[v].Billboard:Destroy()
            end
            Reference[v] = nil
        end

        local billboard = Instance.new('BillboardGui')
        billboard.Parent = Folder
        billboard.Name = icon
        billboard.StudsOffsetWorldSpace = Vector3.new(0, 3, 0)
        billboard.Size = UDim2.fromOffset(36, 36)
        billboard.AlwaysOnTop = true
        billboard.ClipsDescendants = false
        billboard.Adornee = v

        local blur = addBlur(billboard)
        blur.Visible = Background.Enabled

        local image = Instance.new('ImageLabel')
        image.Name = "ImageLabel"
        image.Size = UDim2.fromOffset(36, 36)
        image.Position = UDim2.fromScale(0.5, 0.5)
        image.AnchorPoint = Vector2.new(0.5, 0.5)
        image.BackgroundColor3 = Color3.fromHSV(Color.Hue, Color.Sat, Color.Value)
        image.BackgroundTransparency = 1 - (Background.Enabled and Color.Opacity or 0)
        image.BorderSizePixel = 0
        image.Image = bedwars.getIcon({itemType = icon}, true)
        image.Parent = billboard

        local uicorner = Instance.new('UICorner')
        uicorner.CornerRadius = UDim.new(0, 4)
        uicorner.Parent = image

        --[[ Store all references including Blur and ImageLabel ]]
        Reference[v] = {
            Billboard = billboard,
            Blur = blur,
            ImageLabel = image
        }
    end

    --[[ A model is often tagged a frame before its PrimaryPart is assigned. Reading
    v.PrimaryPart at tag time then gives nil and the billboard is skipped forever
    (why it only worked after a disable/re-enable, once the models were fully built).
    Wait for PrimaryPart before adding. ]]
    local function addWhenReady(v, icon)
        if not v then return end
        if v.PrimaryPart then
            ModelParts[v] = v.PrimaryPart
            Added(v.PrimaryPart, icon)
            return
        end
        task.spawn(function()
            local timeout = os.clock() + 5
            while not v.PrimaryPart and v.Parent and os.clock() < timeout do
                task.wait()
            end
            if v.PrimaryPart and KitESP and KitESP.Enabled then
                ModelParts[v] = v.PrimaryPart
                Added(v.PrimaryPart, icon)
            end
        end)
    end

    --[[ Drops every billboard and per-kit tag connection. Called on disable AND on
    kit change, so stale objects from the previous kit can't linger. ]]
    local function clearTracked()
        for _, c in kitConns do
            pcall(function() c:Disconnect() end)
        end
        table.clear(kitConns)
        if vape.ThreadFix then
            setthreadidentity(8)
        end
        Folder:ClearAllChildren()
        table.clear(Reference)
        table.clear(ModelParts)
    end

    local function addKit(tag, icon)
        table.insert(kitConns, collectionService:GetInstanceAddedSignal(tag):Connect(function(v)
            addWhenReady(v, icon)
        end))

        table.insert(kitConns, collectionService:GetInstanceRemovedSignal(tag):Connect(function(v)
            local part = ModelParts[v] or v.PrimaryPart
            ModelParts[v] = nil
            if part and Reference[part] then
                if vape.ThreadFix then
                    setthreadidentity(8)
                end
                if Reference[part].Billboard then
                    Reference[part].Billboard:Destroy()
                end
                Reference[part] = nil
            end
        end))

        for _, v in pairs(collectionService:GetTagged(tag)) do
            addWhenReady(v, icon)
        end
    end

    --[[ Bumped each toggle so a stale enable-loop from a quick off/on can't keep
    running alongside the new one. ]]
    local loopId = 0

    KitESP = vape.Categories.Render:CreateModule({
        Name = 'KitESP',
        Function = function(callback)
            loopId += 1
            if callback then
                local myId = loopId

                if KitESP.Clean then
                    KitESP:Clean(vapeEvents.EntityDeathEvent.Event:Connect(function(deathTable)
                        local deadEnt = entitylib.getEntity(deathTable.entityInstance)
                        if deadEnt and deadEnt.RootPart and Reference[deadEnt.RootPart] then
                            if vape.ThreadFix then
                                setthreadidentity(8)
                            end
                            if Reference[deadEnt.RootPart].Billboard then
                                Reference[deadEnt.RootPart].Billboard:Destroy()
                            end
                            Reference[deadEnt.RootPart] = nil
                        end
                    end))
                end

                --[[ Kits can change mid-session (kit swap, new match): whenever the
                equipped kit differs from what we're tracking, wipe the old
                kit's billboards/connections and start tracking the new tag. ]]
                local lastKit = nil
                repeat
                    local kit = store.equippedKit
                    if kit ~= lastKit then
                        lastKit = kit
                        clearTracked()
                        local info = ESPKits[kit]
                        if info then
                            addKit(info[1], info[2])
                        end
                    end
                    task.wait(0.5)
                until (not KitESP.Enabled) or loopId ~= myId
            else
                clearTracked()
            end
        end,
        Tooltip = 'ESP for the kit objects lying around the map'
    })

    Background = KitESP:CreateToggle({
        Name = 'Background',
        Function = function(callback)
            if Color.Object then Color.Object.Visible = callback end
            for _, v in pairs(Reference) do
                if v.ImageLabel then
                    v.ImageLabel.BackgroundTransparency = 1 - (callback and Color.Opacity or 0)
                end
                if v.Blur then
                    v.Blur.Visible = callback
                end
            end
        end,
        Default = true
    })

    Color = KitESP:CreateColorSlider({
        Name = 'Background Color',
        DefaultValue = 0,
        DefaultOpacity = 0.5,
        Function = function(hue, sat, val, opacity)
            for _, v in pairs(Reference) do
                if v.ImageLabel then
                    v.ImageLabel.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
                    v.ImageLabel.BackgroundTransparency = 1 - opacity
                end
            end
        end,
        Darker = true
    })
end)

run(function()
	local NameTags
	local Targets
	local Color
	local Background
	local DisplayName
	local Health
	local Distance
	local Equipment
	local Rank
	local Enchant
	local Device
	local DrawingToggle
	local Scale
	local FontOption
	local Teammates
	local DistanceCheck
	local DistanceLimit
	local Strings, Sizes, Reference = {}, {}, {}
	local Folder
	
	pcall(function()
		Folder = Instance.new('Folder')
		Folder.Parent = vape.gui
	end)
	
	local methodused
	--[[ assigned once the Updated table below exists; lets the rank fetch redraw a tag when
	the division finally lands ]]
	local refreshTag

	local RankMeta = (function()
		local suc, res = pcall(function()
			return require(replicatedStorage.TS.rank['rank-meta']).RankMeta
		end)
		return suc and res or nil
	end)()

	local rankRequested = {}

	local function getRankImage(plr)
		if not (RankMeta and plr) then return nil end
		local controller = bedwars.RankController
		local cache = controller and controller.rankCache
		local division = cache and cache[plr.UserId]
		local meta = division and RankMeta[division]
		return meta and meta.image or nil
	end

	--[[ the icons ride the right edge of the text, so everywhere that re-measures the tag has
	to move them as well. They pack outward from the end of the text in list order,
	and a slot is consumed only by an icon that is actually SHOWING something.

	Existence isn't enough: both icons get created up front whenever their toggle is
	on, and start blank -- rank until the async fetch lands (or forever, if the player
	is unranked), enchant whenever nothing is currently applied. A blank one used to
	hold its slot, which is what left the hole. Skipping it means an enchant-only
	player draws exactly where a rank icon would have gone, a rank-only player is
	unaffected, and with both showing they sit flush against each other -- the same
	30px step the equipment row above uses, so the two rows line up. ]]
	local ICON_SIZE = 30
	local rightIcons = {'RankIcon', 'EnchantIcon'}
	local function positionIcons(nametag, width)
		local offset = width + 10
		for _, name in rightIcons do
			local icon = nametag:FindFirstChild(name)
			if icon then
				local shown = icon.Image ~= ''
				icon.Visible = shown
				if shown then
					icon.Position = UDim2.fromOffset(offset, -4)
					offset += ICON_SIZE
				end
			end
		end
	end

	local function requestRank(plr, ent)
		if not plr or rankRequested[plr.UserId] then return end
		local controller = bedwars.RankController
		if not (controller and controller.getRanks) then return end
		rankRequested[plr.UserId] = true
		task.spawn(function()
			pcall(function()
				--[[ forced: getRanks skips the server call once its cache holds anything, so
				an uncached player would otherwise never resolve ]]
				controller:getRanks({plr.UserId}, true):andThen(function()
					if refreshTag then refreshTag(ent) end
				end)
			end)
		end)
	end

	--[[ The guards are kept without the logging: every step of the chain
	(store.enchants -> StatusEffectMeta -> EnchantMeta) throws on a nil table rather
	than returning nil, so a missing piece has to fall out as a blank icon instead of
	an error escaping into the tag build. ]]
	local function getEnchantImage(plr)
		if not plr then return nil end
		if not (store.enchants and bedwars.EnchantMeta) then return nil end
		local suc, res = pcall(function()
			return store.enchants[plr].async()
		end)
		return suc and res or nil
	end

	--[[ Enchants come and go as StatusEffect_* attributes on the character, several times
	over a fight, and far more often than EntityUpdated fires -- so the icon gets its
	own watcher rather than riding the health/equipment refresh and showing a stale
	enchant in between. Keyed by entity and torn down with the tag. ]]
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
				if attribute:find('StatusEffect_') and refreshTag then
					refreshTag(ent)
				end
			end)
		end)
	end

	local deviceEmojis = {gamepad = '🎮', touch = '📱', keyboard = '🖥️'}

	local function getDeviceEmoji(plr)
		if not plr then return nil end
		--[[ checked on the character too, in case the attribute is written there ]]
		local inputType = plr:GetAttribute('UserInputType')
		if inputType == nil and plr.Character then
			inputType = plr.Character:GetAttribute('UserInputType')
		end
		if inputType == nil then return nil end
		if type(inputType) == 'number' then
			--[[ Enum.UserInputType values: Touch 7, Keyboard 8, Gamepad1..8 9-16 ]]
			if inputType == 7 then return deviceEmojis.touch end
			if inputType == 8 then return deviceEmojis.keyboard end
			if inputType >= 9 and inputType <= 16 then return deviceEmojis.gamepad end
			return deviceEmojis.keyboard
		end
		--[[ covers a plain string and an EnumItem alike ("Enum.UserInputType.Touch"), and the
		platform-flavoured values some servers write instead of the enum names ]]
		local name = tostring(inputType):lower()
		if name:find('gamepad') or name:find('console') or name:find('xbox') or name:find('playstation') then
			return deviceEmojis.gamepad
		end
		if name:find('touch') or name:find('mobile') or name:find('phone') or name:find('tablet') then
			return deviceEmojis.touch
		end
		--[[ anything left that carries a value at all is a desktop input (keyboard, any of
		the mouse variants, MouseMovement, TextInput...), so fall through rather than
		silently showing nothing ]]
		return name ~= '' and deviceEmojis.keyboard or nil
	end

	local Added = {
		Normal = function(ent)
			pcall(function()
				if not Targets.Players.Enabled and ent.Player then return end
				if not Targets.NPCs.Enabled and ent.NPC then return end
				if Teammates.Enabled and (not ent.Targetable) and (not ent.Friend) then return end
				if Reference[ent] then return end --[[ Prevent duplicates ]]

				local nametag = Instance.new('TextLabel')
				Strings[ent] = ent.Player and whitelist:tag(ent.Player, true, true)..(DisplayName.Enabled and ent.Player.DisplayName or ent.Player.Name) or ent.Character.Name

				if Device.Enabled and ent.Player then
					local emoji = getDeviceEmoji(ent.Player)
					if emoji then
						Strings[ent] = emoji..' '..Strings[ent]
					end
				end

				if Health.Enabled then
					local healthColor = Color3.fromHSV(math.clamp(ent.Health / ent.MaxHealth, 0, 1) / 2.5, 0.89, 0.75)
					Strings[ent] = Strings[ent]..' <font color="rgb('..tostring(math.floor(healthColor.R * 255))..','..tostring(math.floor(healthColor.G * 255))..','..tostring(math.floor(healthColor.B * 255))..')">'..math.round(ent.Health)..'</font>'
				end

				if Distance.Enabled then
					Strings[ent] = '<font color="rgb(85, 255, 85)">[</font><font color="rgb(255, 255, 255)">%s</font><font color="rgb(85, 255, 85)">]</font> '..Strings[ent]
				end

				if Equipment.Enabled then
					for i, v in {'Hand', 'Helmet', 'Chestplate', 'Boots', 'Kit'} do
						local Icon = Instance.new('ImageLabel')
						Icon.Name = v
						Icon.Size = UDim2.fromOffset(30, 30)
						Icon.Position = UDim2.fromOffset(-60 + (i * 30), -30)
						Icon.BackgroundTransparency = 1
						Icon.Image = ''
						Icon.Parent = nametag
					end
				end

				nametag.TextSize = 14 * Scale.Value
				nametag.FontFace = FontOption.Value
				local size = getfontsize(removeTags(Strings[ent]), nametag.TextSize, nametag.FontFace, Vector2.new(100000, 100000))
				nametag.Name = ent.Player and ent.Player.Name or ent.Character.Name
				nametag.Size = UDim2.fromOffset(size.X + 8, size.Y + 7)

				--[[ Rank Icon: sits immediately to the right of the text, so it has to be
				built after the text has been measured ]]
				if Rank.Enabled and ent.Player then
					--[[ no Position here: positionIcons below owns the layout, and setting
					one now would flash the icon at a slot it may not end up in ]]
					local Icon = Instance.new('ImageLabel')
					Icon.Name = 'RankIcon'
					Icon.Size = UDim2.fromOffset(ICON_SIZE, ICON_SIZE)
					Icon.BackgroundTransparency = 1
					Icon.Image = getRankImage(ent.Player) or ''
					Icon.Visible = false
					Icon.Parent = nametag
					if Icon.Image == '' then
						requestRank(ent.Player, ent)
					end
				end

				if Enchant.Enabled and ent.Player then
					local Icon = Instance.new('ImageLabel')
					Icon.Name = 'EnchantIcon'
					Icon.Size = UDim2.fromOffset(ICON_SIZE, ICON_SIZE)
					Icon.BackgroundTransparency = 1
					Icon.Image = getEnchantImage(ent.Player) or ''
					Icon.Visible = false
					Icon.Parent = nametag
					watchEnchant(ent)
				end

				--[[ after both right-side icons exist, so each lands at its own slot ]]
				positionIcons(nametag, size.X)

				nametag.AnchorPoint = Vector2.new(0.5, 1)
				nametag.BackgroundColor3 = Color3.new()
				nametag.BackgroundTransparency = Background.Value
				nametag.BorderSizePixel = 0
				nametag.Visible = false
				nametag.Text = Strings[ent]
				nametag.TextColor3 = entitylib.getEntityColor(ent) or Color3.fromHSV(Color.Hue, Color.Sat, Color.Value)
				nametag.RichText = true
				nametag.Parent = Folder
				Reference[ent] = nametag
			end)
		end,
		Drawing = function(ent)
			pcall(function()
				if not Targets.Players.Enabled and ent.Player then return end
				if not Targets.NPCs.Enabled and ent.NPC then return end
				if Teammates.Enabled and (not ent.Targetable) and (not ent.Friend) then return end
				if Reference[ent] then return end

				local nametag = {}
				nametag.BG = Drawing.new('Square')
				nametag.BG.Filled = true
				nametag.BG.Transparency = 1 - Background.Value
				nametag.BG.Color = Color3.new()
				nametag.BG.ZIndex = 1
				nametag.Text = Drawing.new('Text')
				nametag.Text.Size = 15 * Scale.Value
				nametag.Text.Font = 0
				nametag.Text.ZIndex = 2
				Strings[ent] = ent.Player and whitelist:tag(ent.Player, true)..(DisplayName.Enabled and ent.Player.DisplayName or ent.Player.Name) or ent.Character.Name

				--[[ Drawing text only; the rank icon needs an ImageLabel, which this render
				path has no equivalent for ]]
				if Device.Enabled and ent.Player then
					local emoji = getDeviceEmoji(ent.Player)
					if emoji then
						Strings[ent] = emoji..' '..Strings[ent]
					end
				end

				if Health.Enabled then
					Strings[ent] = Strings[ent]..' '..math.round(ent.Health)
				end

				if Distance.Enabled then
					Strings[ent] = '[%s] '..Strings[ent]
				end

				nametag.Text.Text = Strings[ent]
				nametag.Text.Color = entitylib.getEntityColor(ent) or Color3.fromHSV(Color.Hue, Color.Sat, Color.Value)
				nametag.BG.Size = Vector2.new(nametag.Text.TextBounds.X + 8, nametag.Text.TextBounds.Y + 7)
				Reference[ent] = nametag
			end)
		end
	}
	
	local Removed = {
		Normal = function(ent)
			pcall(function()
				unwatchEnchant(ent)
				local v = Reference[ent]
				if v then
					Reference[ent] = nil
					Strings[ent] = nil
					Sizes[ent] = nil
					v:Destroy()
				end
			end)
		end,
		Drawing = function(ent)
			pcall(function()
				--[[ the Drawing path never creates the watcher, but Removed runs for
				entities whose tag was built under the other method too ]]
				unwatchEnchant(ent)
				local v = Reference[ent]
				if v then
					Reference[ent] = nil
					Strings[ent] = nil
					Sizes[ent] = nil
					for _, obj in v do
						pcall(function()
							obj.Visible = false
							obj:Remove()
						end)
					end
				end
			end)
		end
	}
	
	local Updated = {
		Normal = function(ent)
			pcall(function()
				local nametag = Reference[ent]
				if not nametag or not nametag.Parent then return end
				
				if vape.ThreadFix then
					setthreadidentity(8)
				end
				Sizes[ent] = nil
				Strings[ent] = ent.Player and whitelist:tag(ent.Player, true, true)..(DisplayName.Enabled and ent.Player.DisplayName or ent.Player.Name) or ent.Character.Name

				if Device.Enabled and ent.Player then
					local emoji = getDeviceEmoji(ent.Player)
					if emoji then
						Strings[ent] = emoji..' '..Strings[ent]
					end
				end

				if Health.Enabled then
					local healthColor = Color3.fromHSV(math.clamp(ent.Health / ent.MaxHealth, 0, 1) / 2.5, 0.89, 0.75)
					Strings[ent] = Strings[ent]..' <font color="rgb('..tostring(math.floor(healthColor.R * 255))..','..tostring(math.floor(healthColor.G * 255))..','..tostring(math.floor(healthColor.B * 255))..')">'..math.round(ent.Health)..'</font>'
				end

				if Distance.Enabled then
					Strings[ent] = '<font color="rgb(85, 255, 85)">[</font><font color="rgb(255, 255, 255)">%s</font><font color="rgb(85, 255, 85)">]</font> '..Strings[ent]
				end

				if Equipment.Enabled and store.inventories[ent.Player] and nametag:FindFirstChild("Hand") then
					local kit = ent.Player:GetAttribute('PlayingAsKit')
					local inventory = store.inventories[ent.Player]
					nametag.Hand.Image = bedwars.getIcon(inventory.hand or {itemType = ''}, true)
					nametag.Helmet.Image = bedwars.getIcon(inventory.armor[4] or {itemType = ''}, true)
					nametag.Chestplate.Image = bedwars.getIcon(inventory.armor[5] or {itemType = ''}, true)
					nametag.Boots.Image = bedwars.getIcon(inventory.armor[6] or {itemType = ''}, true)
					nametag.Kit.Image = kit and kit ~= 'none' and bedwars.BedwarsKitMeta[kit].renderImage or ''
				end

				if Rank.Enabled and ent.Player then
					local icon = nametag:FindFirstChild('RankIcon')
					if icon then
						icon.Image = getRankImage(ent.Player) or ''
					end
				end

				if Enchant.Enabled and ent.Player then
					local icon = nametag:FindFirstChild('EnchantIcon')
					if icon then
						icon.Image = getEnchantImage(ent.Player) or ''
					end
				end

				local size = getfontsize(removeTags(Strings[ent]), nametag.TextSize, nametag.FontFace, Vector2.new(100000, 100000))
				nametag.Size = UDim2.fromOffset(size.X + 8, size.Y + 7)
				positionIcons(nametag, size.X)
				nametag.Text = Strings[ent]
			end)
		end,
		Drawing = function(ent)
			pcall(function()
				local nametag = Reference[ent]
				if not nametag then return end
				
				if vape.ThreadFix then
					setthreadidentity(8)
				end
				Sizes[ent] = nil
				Strings[ent] = ent.Player and whitelist:tag(ent.Player, true)..(DisplayName.Enabled and ent.Player.DisplayName or ent.Player.Name) or ent.Character.Name

				if Device.Enabled and ent.Player then
					local emoji = getDeviceEmoji(ent.Player)
					if emoji then
						Strings[ent] = emoji..' '..Strings[ent]
					end
				end

				if Health.Enabled then
					Strings[ent] = Strings[ent]..' '..math.round(ent.Health)
				end

				if Distance.Enabled then
					Strings[ent] = '[%s] '..Strings[ent]
					nametag.Text.Text = entitylib.isAlive and string.format(Strings[ent], math.floor((entitylib.character.RootPart.Position - ent.RootPart.Position).Magnitude)) or Strings[ent]
				else
					nametag.Text.Text = Strings[ent]
				end

				nametag.BG.Size = Vector2.new(nametag.Text.TextBounds.X + 8, nametag.Text.TextBounds.Y + 7)
				nametag.Text.Color = entitylib.getEntityColor(ent) or Color3.fromHSV(Color.Hue, Color.Sat, Color.Value)
			end)
		end
	}
	
	refreshTag = function(ent)
		if Reference[ent] and Updated[methodused] then
			Updated[methodused](ent)
		end
	end

	local ColorFunc = {
		Normal = function(hue, sat, val)
			pcall(function()
				local color = Color3.fromHSV(hue, sat, val)
				for i, v in Reference do
					if v and v.Parent then
						v.TextColor3 = entitylib.getEntityColor(i) or color
					end
				end
			end)
		end,
		Drawing = function(hue, sat, val)
			pcall(function()
				local color = Color3.fromHSV(hue, sat, val)
				for i, v in Reference do
					if v and v.Text then
						v.Text.Color = entitylib.getEntityColor(i) or color
					end
				end
			end)
		end
	}
	
	local Loop = {
		Normal = function()
			pcall(function()
				--[[ Local player's position is identical for every nametag this frame;
				resolve the property chain once instead of per-entity. ]]
				local selfPos = entitylib.isAlive and entitylib.character.RootPart.Position
				for ent, nametag in Reference do
					if not nametag or not nametag.Parent then
						Reference[ent] = nil
						continue
					end
					
					if DistanceCheck.Enabled then
						local distance = selfPos and (selfPos - ent.RootPart.Position).Magnitude or math.huge
						if distance < DistanceLimit.ValueMin or distance > DistanceLimit.ValueMax then
							nametag.Visible = false
							continue
						end
					end

					local headPos, headVis = gameCamera:WorldToViewportPoint(ent.RootPart.Position + Vector3.new(0, ent.HipHeight + 1, 0))
					nametag.Visible = headVis
					if not headVis then
						continue
					end

					if Distance.Enabled then
						local mag = selfPos and math.floor((selfPos - ent.RootPart.Position).Magnitude) or 0
						if Sizes[ent] ~= mag then
							nametag.Text = string.format(Strings[ent], mag)
						local size = getfontsize(removeTags(nametag.Text), nametag.TextSize, nametag.FontFace, Vector2.new(100000, 100000))
						nametag.Size = UDim2.fromOffset(size.X + 8, size.Y + 7)
						positionIcons(nametag, size.X)
							Sizes[ent] = mag
						end
					end
					nametag.Position = UDim2.fromOffset(headPos.X, headPos.Y)
				end
			end)
		end,
		Drawing = function()
			pcall(function()
				--[[ Local player's position is identical for every nametag this frame;
				resolve the property chain once instead of per-entity. ]]
				local selfPos = entitylib.isAlive and entitylib.character.RootPart.Position
				for ent, nametag in Reference do
					if not nametag or not nametag.Text or not nametag.BG then
						Reference[ent] = nil
						continue
					end

					if DistanceCheck.Enabled then
						local distance = selfPos and (selfPos - ent.RootPart.Position).Magnitude or math.huge
						if distance < DistanceLimit.ValueMin or distance > DistanceLimit.ValueMax then
							nametag.Text.Visible = false
							nametag.BG.Visible = false
							continue
						end
					end

					local headPos, headVis = gameCamera:WorldToViewportPoint(ent.RootPart.Position + Vector3.new(0, ent.HipHeight + 1, 0))
					nametag.Text.Visible = headVis
					nametag.BG.Visible = headVis
					if not headVis then
						continue
					end

					if Distance.Enabled then
						local mag = selfPos and math.floor((selfPos - ent.RootPart.Position).Magnitude) or 0
						if Sizes[ent] ~= mag then
							nametag.Text.Text = string.format(Strings[ent], mag)
							nametag.BG.Size = Vector2.new(nametag.Text.TextBounds.X + 8, nametag.Text.TextBounds.Y + 7)
							Sizes[ent] = mag
						end
					end
					nametag.BG.Position = Vector2.new(headPos.X - (nametag.BG.Size.X / 2), headPos.Y - nametag.BG.Size.Y)
					nametag.Text.Position = nametag.BG.Position + Vector2.new(4, 3)
				end
			end)
		end
	}
	
	NameTags = vape.Categories.Render:CreateModule({
		Name = 'NameTags',
		Function = function(callback)
			if callback then
				methodused = DrawingToggle.Enabled and 'Drawing' or 'Normal'
				if Removed[methodused] then
					NameTags:Clean(entitylib.Events.EntityRemoved:Connect(Removed[methodused]))
				end
				if Added[methodused] then
					for _, v in entitylib.List do
						if Reference[v] then
							Removed[methodused](v)
						end
						Added[methodused](v)
					end
					NameTags:Clean(entitylib.Events.EntityAdded:Connect(function(ent)
						if Reference[ent] then
							Removed[methodused](ent)
						end
						Added[methodused](ent)
					end))
				end
				if Updated[methodused] then
					NameTags:Clean(entitylib.Events.EntityUpdated:Connect(Updated[methodused]))
					for _, v in entitylib.List do
						Updated[methodused](v)
					end
				end
				if ColorFunc[methodused] then
					NameTags:Clean(vape.Categories.Friends.ColorUpdate.Event:Connect(function()
						ColorFunc[methodused](Color.Hue, Color.Sat, Color.Value)
					end))
				end
				if Loop[methodused] then
					NameTags:Clean(runService.RenderStepped:Connect(Loop[methodused]))
				end

				--[[ UserInputType can replicate after the tag was built (and changes when a
				player switches input), and the tag is only rebuilt on health/equipment
				updates -- which is why the emoji was missing on some players and not
				others. Redraw whoever's attribute lands or changes. ]]
				local function watchDevice(plr)
					NameTags:Clean(plr:GetAttributeChangedSignal('UserInputType'):Connect(function()
						if not Device.Enabled then return end
						local ent = entitylib.getEntity(plr)
						if ent then
							refreshTag(ent)
						end
					end))
				end

				for _, plr in playersService:GetPlayers() do
					watchDevice(plr)
				end
				NameTags:Clean(playersService.PlayerAdded:Connect(watchDevice))
			else
				if Removed[methodused] then
					for i in Reference do
						Removed[methodused](i)
					end
				end
				--[[ the loop above only reaches entities that still have a tag; sweep the
				rest so no attribute listener outlives the module ]]
				for ent in enchantConns do
					unwatchEnchant(ent)
				end
			end
		end,
		Tooltip = 'Draws nametags through walls.'
	})
	Targets = NameTags:CreateTargets({
		Players = true,
		Function = function()
			if NameTags.Enabled then
				NameTags:Toggle()
				NameTags:Toggle()
			end
		end
	})
	FontOption = NameTags:CreateFont({
		Name = 'Font',
		Blacklist = 'Arial',
		Function = function()
			if NameTags.Enabled then
				NameTags:Toggle()
				NameTags:Toggle()
			end
		end
	})
	Color = NameTags:CreateColorSlider({
		Name = 'Player Color',
		Function = function(hue, sat, val)
			if NameTags.Enabled and ColorFunc[methodused] then
				ColorFunc[methodused](hue, sat, val)
			end
		end
	})
	Scale = NameTags:CreateSlider({
		Name = 'Scale',
		Function = function()
			if NameTags.Enabled then
				NameTags:Toggle()
				NameTags:Toggle()
			end
		end,
		Default = 1,
		Min = 0.1,
		Max = 1.5,
		Decimal = 10
	})
	Background = NameTags:CreateSlider({
		Name = 'Transparency',
		Function = function()
			if NameTags.Enabled then
				NameTags:Toggle()
				NameTags:Toggle()
			end
		end,
		Default = 0.5,
		Min = 0,
		Max = 1,
		Decimal = 10
	})
	Health = NameTags:CreateToggle({
		Name = 'Health',
		Function = function()
			if NameTags.Enabled then
				NameTags:Toggle()
				NameTags:Toggle()
			end
		end
	})
	Distance = NameTags:CreateToggle({
		Name = 'Distance',
		Function = function()
			if NameTags.Enabled then
				NameTags:Toggle()
				NameTags:Toggle()
			end
		end
	})
	Equipment = NameTags:CreateToggle({
		Name = 'Equipment',
		Function = function()
			if NameTags.Enabled then
				NameTags:Toggle()
				NameTags:Toggle()
			end
		end
	})
	Rank = NameTags:CreateToggle({
		Name = 'Show Rank',
		Function = function()
			if NameTags.Enabled then
				NameTags:Toggle()
				NameTags:Toggle()
			end
		end,
		Tooltip = 'Puts their ranked division icon above the nametag'
	})
	Enchant = NameTags:CreateToggle({
		Name = 'Show Enchant',
		Function = function()
			if NameTags.Enabled then
				NameTags:Toggle()
				NameTags:Toggle()
			end
		end,
		Tooltip = 'Puts their active enchant above the nametag. Drawing mode doesnt have the icons.'
	})
	Device = NameTags:CreateToggle({
		Name = 'Show Device',
		Function = function()
			if NameTags.Enabled then
				NameTags:Toggle()
				NameTags:Toggle()
			end
		end,
		Tooltip = 'Shows 🎮 / 🖥️ / 📱 depending on what theyre playing on'
	})
	DisplayName = NameTags:CreateToggle({
		Name = 'Use Displayname',
		Function = function()
			if NameTags.Enabled then
				NameTags:Toggle()
				NameTags:Toggle()
			end
		end,
		Default = true
	})
	Teammates = NameTags:CreateToggle({
		Name = 'Priority Only',
		Function = function()
			if NameTags.Enabled then
				NameTags:Toggle()
				NameTags:Toggle()
			end
		end,
		Default = true
	})
	DrawingToggle = NameTags:CreateToggle({
		Name = 'Drawing',
		Function = function()
			if NameTags.Enabled then
				NameTags:Toggle()
				NameTags:Toggle()
			end
		end,
	})
	DistanceCheck = NameTags:CreateToggle({
		Name = 'Distance Check',
		Function = function(callback)
			DistanceLimit.Object.Visible = callback
		end
	})
	DistanceLimit = NameTags:CreateTwoSlider({
		Name = 'Player Distance',
		Min = 0,
		Max = 256,
		DefaultMin = 0,
		DefaultMax = 64,
		Darker = true,
		Visible = false
	})
end)
	
run(function()
	local StorageESP
	local List
	local Background
	local Color = {}
	local Reference = {}
	local Folder = Instance.new('Folder')
	Folder.Parent = vape.gui
	
	local function nearStorageItem(item)
		for _, v in List.ListEnabled do
			if item:find(v) then return v end
		end
	end
	
	local function refreshAdornee(v)
		local chest = v.Adornee:FindFirstChild('ChestFolderValue')
		chest = chest and chest.Value or nil
		if not chest then
			v.Enabled = false
			return
		end
	
		local chestitems = chest and chest:GetChildren() or {}
		for _, obj in v.Frame:GetChildren() do
			if obj:IsA('ImageLabel') and obj.Name ~= 'Blur' then
				obj:Destroy()
			end
		end
	
		v.Enabled = false
		local alreadygot = {}
		for _, item in chestitems do
			if not alreadygot[item.Name] and (table.find(List.ListEnabled, item.Name) or nearStorageItem(item.Name)) then
				alreadygot[item.Name] = true
				v.Enabled = true
				local blockimage = Instance.new('ImageLabel')
				blockimage.Size = UDim2.fromOffset(32, 32)
				blockimage.BackgroundTransparency = 1
				blockimage.Image = bedwars.getIcon({itemType = item.Name}, true)
				blockimage.Parent = v.Frame
			end
		end
		table.clear(chestitems)
	end
	
	local function Added(v)
		local chest = v:WaitForChild('ChestFolderValue', 3)
		if not (chest and StorageESP.Enabled) then return end
		chest = chest.Value
		local billboard = Instance.new('BillboardGui')
		billboard.Parent = Folder
		billboard.Name = 'chest'
		billboard.StudsOffsetWorldSpace = Vector3.new(0, 3, 0)
		billboard.Size = UDim2.fromOffset(36, 36)
		billboard.AlwaysOnTop = true
		billboard.ClipsDescendants = false
		billboard.Adornee = v
		local blur = addBlur(billboard)
		blur.Visible = Background.Enabled
		local frame = Instance.new('Frame')
		frame.Size = UDim2.fromScale(1, 1)
		frame.BackgroundColor3 = Color3.fromHSV(Color.Hue, Color.Sat, Color.Value)
		frame.BackgroundTransparency = 1 - (Background.Enabled and Color.Opacity or 0)
		frame.Parent = billboard
		local layout = Instance.new('UIListLayout')
		layout.FillDirection = Enum.FillDirection.Horizontal
		layout.Padding = UDim.new(0, 4)
		layout.VerticalAlignment = Enum.VerticalAlignment.Center
		layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		layout:GetPropertyChangedSignal('AbsoluteContentSize'):Connect(function()
			billboard.Size = UDim2.fromOffset(math.max(layout.AbsoluteContentSize.X + 4, 36), 36)
		end)
		layout.Parent = frame
		local corner = Instance.new('UICorner')
		corner.CornerRadius = UDim.new(0, 4)
		corner.Parent = frame
		Reference[v] = billboard
		StorageESP:Clean(chest.ChildAdded:Connect(function(item)
			if table.find(List.ListEnabled, item.Name) or nearStorageItem(item.Name) then
				refreshAdornee(billboard)
			end
		end))
		StorageESP:Clean(chest.ChildRemoved:Connect(function(item)
			if table.find(List.ListEnabled, item.Name) or nearStorageItem(item.Name) then
				refreshAdornee(billboard)
			end
		end))
		task.spawn(refreshAdornee, billboard)
	end
	
	StorageESP = vape.Categories.Render:CreateModule({
		Name = 'StorageESP',
		Function = function(callback)
			if callback then
				StorageESP:Clean(collectionService:GetInstanceAddedSignal('chest'):Connect(Added))
				for _, v in collectionService:GetTagged('chest') do
					task.spawn(Added, v)
				end
			else
				table.clear(Reference)
				Folder:ClearAllChildren()
			end
		end,
		Tooltip = 'Shows you whats in a chest without opening it'
	})
	List = StorageESP:CreateTextList({
		Name = 'Item',
		Function = function()
			for _, v in Reference do
				task.spawn(refreshAdornee, v)
			end
		end
	})
	Background = StorageESP:CreateToggle({
		Name = 'Background',
		Function = function(callback)
			if Color.Object then Color.Object.Visible = callback end
			for _, v in Reference do
				v.Frame.BackgroundTransparency = 1 - (callback and Color.Opacity or 0)
				v.Blur.Visible = callback
			end
		end,
		Default = true
	})
	Color = StorageESP:CreateColorSlider({
		Name = 'Background Color',
		DefaultValue = 0,
		DefaultOpacity = 0.5,
		Function = function(hue, sat, val, opacity)
			for _, v in Reference do
				v.Frame.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
				v.Frame.BackgroundTransparency = 1 - opacity
			end
		end,
		Darker = true
	})
end)

run(function()
	local AutoBalloon
	
	AutoBalloon = vape.Categories.Utility:CreateModule({
		Name = 'AutoBalloon',
		Function = function(callback)
			if callback then
				repeat task.wait(0.1) until store.matchState ~= 0 or (not AutoBalloon.Enabled)
				if not AutoBalloon.Enabled then return end
	
				local lowestpoint = math.huge
				for _, v in store.blocks do
					local point = (v.Position.Y - (v.Size.Y / 2)) - 50
					if point < lowestpoint then 
						lowestpoint = point 
					end
				end
	
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
				until not AutoBalloon.Enabled
			end
		end,
		Tooltip = 'Inflates when you go over the edge'
	})
end)
	
run(function()
	local AutoKit
	local Legit
	local Toggles = {}
	
	local function kitCollection(id, func, range, specific)
		local objs = type(id) == 'table' and id or collection(id, AutoKit)
		repeat
			if entitylib.isAlive then
				local localPosition = entitylib.character.RootPart.Position
				for _, v in objs do
					if not AutoKit.Enabled then break end
					local part = not v:IsA('Model') and v or v.PrimaryPart
					if part and (part.Position - localPosition).Magnitude <= (not Legit.Enabled and specific and math.huge or range) then
						func(v)
					end
				end
			end
			task.wait(0.1)
		until not AutoKit.Enabled
	end
	
	local AutoKitFunctions = {
		battery = function()
			repeat
				if entitylib.isAlive then
					local localPosition = entitylib.character.RootPart.Position
					for i, v in bedwars.BatteryEffectsController.liveBatteries do
						if (v.position - localPosition).Magnitude <= 10 then
							local BatteryInfo = bedwars.BatteryEffectsController:getBatteryInfo(i)
							if not BatteryInfo or BatteryInfo.activateTime >= workspace:GetServerTimeNow() or BatteryInfo.consumeTime + 0.1 >= workspace:GetServerTimeNow() then continue end
							BatteryInfo.consumeTime = workspace:GetServerTimeNow()
							bedwars.Client:Get(remotes.ConsumeBattery):SendToServer({batteryId = i})
						end
					end
				end
				task.wait(0.1)
			until not AutoKit.Enabled
		end,
		cat = function()
			local old = bedwars.CatController.leap
			bedwars.CatController.leap = function(...)
				vapeEvents.CatPounce:Fire()
				return old(...)
			end
	
			AutoKit:Clean(function()
				bedwars.CatController.leap = old
			end)
		end,
		farmer_cletus = function()
			kitCollection('HarvestableCrop', function(v)
				if bedwars.Client:Get(remotes.HarvestCrop):CallServer({position = bedwars.BlockController:getBlockPosition(v.Position)}) then
					bedwars.GameAnimationUtil:playAnimation(lplr.Character, bedwars.AnimationType.PUNCH)
					bedwars.SoundManager:playSound(bedwars.SoundList.CROP_HARVEST)
				end
			end, 10, false)
		end,
		gingerbread_man = function()
			local old = bedwars.LaunchPadController.attemptLaunch
			bedwars.LaunchPadController.attemptLaunch = function(...)
				local res = {old(...)}
				local self, block = ...
	
				-- AutoGumdrop owns the pad while it is on, toggles and all. This break is
				-- unconditional, so with both running its 'Break gumdrop' toggle did nothing
				-- visible -- the pad went either way -- and the two modules raced to break the
				-- same block.
				if not genv.AutoGumdropActive and (workspace:GetServerTimeNow() - self.lastLaunch) < 0.4 then
					if block:GetAttribute('PlacedByUserId') == lplr.UserId and (block.Position - entitylib.character.RootPart.Position).Magnitude < 30 then
						task.spawn(bedwars.breakBlock, block, false, nil, true)
					end
				end
	
				return unpack(res)
			end
	
			AutoKit:Clean(function()
				bedwars.LaunchPadController.attemptLaunch = old
			end)
		end,
		void_dragon = function()
			local oldflap = bedwars.VoidDragonController.flapWings
			local flapped
	
			bedwars.VoidDragonController.flapWings = function(self)
				if not flapped and bedwars.Client:Get(remotes.DragonFly):CallServer() then
					local modifier = bedwars.SprintController:getMovementStatusModifier():addModifier({
						blockSprint = true,
						constantSpeedMultiplier = 2
					})
					self.SpeedMaid:GiveTask(modifier)
					self.SpeedMaid:GiveTask(function()
						flapped = false
					end)
					flapped = true
				end
			end
	
			AutoKit:Clean(function()
				bedwars.VoidDragonController.flapWings = oldflap
			end)
	
			repeat
				if bedwars.VoidDragonController.inDragonForm then
					local plr = entitylib.EntityPosition({
						Range = 30,
						Part = 'RootPart',
						Players = true
					})
	
					if plr then
						bedwars.Client:Get(remotes.DragonBreath):SendToServer({
							player = lplr,
							targetPoint = plr.RootPart.Position
						})
					end
				end
				task.wait(0.1)
			until not AutoKit.Enabled
		end,
		warlock = function()
			local lastTarget
			repeat
				if store.hand.tool and store.hand.tool.Name == 'warlock_staff' then
					local plr = entitylib.EntityPosition({
						Range = 30,
						Part = 'RootPart',
						Players = true,
						NPCs = true
					})
	
					if plr and plr.Character ~= lastTarget then
						if not bedwars.Client:Get(remotes.WarlockTarget):CallServer({
							target = plr.Character
						}) then
							plr = nil
						end
					end
	
					lastTarget = plr and plr.Character
				else
					lastTarget = nil
				end
	
				task.wait(0.1)
			until not AutoKit.Enabled
		end,
	}
	
	AutoKit = vape.Categories.Utility:CreateModule({
		Name = 'AutoKit',
		Function = function(callback)
			if callback then
				--[[ Every kit loop below touches Instances and fires remotes, and this
				thread is whatever enabled the module -- a profile apply on load, or a
				GUI click -- neither of which carries the elevated identity. Without
				this, farmer_cletus' harvest remote throws 'lacking capability Plugin'
				on the first crop in range and takes the whole kit loop with it, since
				nothing here is pcall'd. Set once for the thread rather than inside
				the loops: it persists across task.wait, and every kit function runs
				on this same thread. ]]
				if vape.ThreadFix then
					setthreadidentity(8)
				end
				repeat task.wait(0.1) until store.equippedKit ~= '' and store.matchState ~= 0 or (not AutoKit.Enabled)
				if AutoKit.Enabled and AutoKitFunctions[store.equippedKit] and Toggles[store.equippedKit].Enabled then
					AutoKitFunctions[store.equippedKit]()
				end
			end
		end,
		Tooltip = 'Uses your kit abilities for you.'
	})
	Legit = AutoKit:CreateToggle({Name = 'Legit Range'})
	local sortTable = {}
	for i in AutoKitFunctions do
		table.insert(sortTable, i)
	end
	table.sort(sortTable, function(a, b)
		return bedwars.BedwarsKitMeta[a].name < bedwars.BedwarsKitMeta[b].name
	end)
	for _, v in sortTable do
		Toggles[v] = AutoKit:CreateToggle({
			Name = bedwars.BedwarsKitMeta[v].name,
			Default = true
		})
	end
end)
	
run(function()
	local AutoPlay
	local Random
	
	local function isEveryoneDead()
		return #bedwars.Store:getState().Party.members <= 0
	end
	
	local function joinQueue()
		if not bedwars.Store:getState().Game.customMatch and bedwars.Store:getState().Party.leader.userId == lplr.UserId and bedwars.Store:getState().Party.queueState == 0 then
			if Random.Enabled then
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
	
	AutoPlay = vape.Categories.Utility:CreateModule({
		Name = 'AutoPlay',
		Function = function(callback)
			if callback then
				AutoPlay:Clean(vapeEvents.EntityDeathEvent.Event:Connect(function(deathTable)
					if deathTable.finalKill and deathTable.entityInstance == lplr.Character and isEveryoneDead() and store.matchState ~= 2 then
						joinQueue()
					end
				end))
				AutoPlay:Clean(vapeEvents.MatchEndEvent.Event:Connect(joinQueue))
			end
		end,
		Tooltip = 'Queues you up again once the match ends.'
	})
	Random = AutoPlay:CreateToggle({
		Name = 'Random',
		Tooltip = 'Picks a random mode for you'
	})
end)
	
run(function()
	local AutoToxic
	local GG
	local Kill
	local KillMessage
	local Presets, PresetNames = {}, {}

	local function normalise(str)
		return (tostring(str):lower():gsub('^%s*(.-)%s*$', '%1'))
	end

	local function sendChat(message)
		if not message then return end

		if textChatService.ChatVersion ~= Enum.ChatVersion.TextChatService then
			replicatedStorage.DefaultChatSystemChatEvents.SayMessageRequest:FireServer(message, 'All')
			return
		end

		local presetId = Presets[normalise(message)]
		if not presetId then return end

		local channel = textChatService.ChatInputBarConfiguration.TargetTextChannel
		if not channel then return end

		task.spawn(function()
			pcall(function()
				channel:SendPresetAsync(presetId)
			end)
		end)
	end

	AutoToxic = vape.Categories.Utility:CreateModule({
		Name = 'AutoToxic',
		Function = function(callback)
			if callback then
				AutoToxic:Clean(vapeEvents.MatchEndEvent.Event:Connect(function()
					if GG.Enabled then
						sendChat('Good game')
					end
				end))
				AutoToxic:Clean(vapeEvents.EntityDeathEvent.Event:Connect(function(deathTable)
					if not Kill.Enabled then return end

					local killer = playersService:GetPlayerFromCharacter(deathTable.fromEntity)
					local killed = playersService:GetPlayerFromCharacter(deathTable.entityInstance)
					if not killer or not killed then return end
					if killer ~= lplr or killed == lplr then return end

					if KillMessage.Value ~= 'None' then
						sendChat(KillMessage.Value)
					end
				end))
			end
		end,
		Tooltip = 'Fires off a quick chat message after certain things happen'
	})
	GG = AutoToxic:CreateToggle({
		Name = 'AutoGG',
		Default = true
	})
	Kill = AutoToxic:CreateToggle({
		Name = 'Kill',
		Function = function(callback)
			if KillMessage then
				KillMessage.Object.Visible = callback
			end
		end
	})
	KillMessage = AutoToxic:CreateDropdown({
		Name = 'Kill Message',
		List = PresetNames,
		Darker = true,
		Visible = false,
		Tooltip = 'What to say after you kill someone'
	})

	local savedKillMessage
	local loadDropdown = KillMessage.Load
	function KillMessage:Load(tab)
		savedKillMessage = tab.Value
		loadDropdown(self, tab)
	end
	task.spawn(function()
		if textChatService.ChatVersion ~= Enum.ChatVersion.TextChatService then return end

		local success, presets = pcall(function()
			return textChatService:GetPresetsAsync()
		end)
		if not success or type(presets) ~= 'table' then return end

		for _, group in presets.categoryGroups or {} do
			for _, category in group.categories or {} do
				for _, message in category.messages or {} do
					Presets[normalise(message.value)] = message.presetId
					table.insert(PresetNames, message.value)
				end
			end
		end

		table.sort(PresetNames)

		if savedKillMessage and table.find(PresetNames, savedKillMessage) then
			KillMessage:SetValue(savedKillMessage)
		elseif KillMessage.Value == 'None' and PresetNames[1] then
			KillMessage:SetValue(PresetNames[1])
		end
	end)
end)
	
run(function()
	local AutoVoidDrop
	local OwlCheck
	
	AutoVoidDrop = vape.Categories.Inventory:CreateModule({
		Name = 'AutoVoidDrop',
		Function = function(callback)
			if callback then
				repeat task.wait(0.1) until store.matchState ~= 0 or (not AutoVoidDrop.Enabled)
				if not AutoVoidDrop.Enabled then return end
	
				local lowestpoint = math.huge
				for _, v in store.blocks do
					local point = (v.Position.Y - (v.Size.Y / 2)) - 50
					if point < lowestpoint then
						lowestpoint = point
					end
				end
	
				repeat
					if entitylib.isAlive then
						local root = entitylib.character.RootPart
						if root.Position.Y < lowestpoint and (lplr.Character:GetAttribute('InflatedBalloons') or 0) <= 0 and not getItem('balloon') then
							if not OwlCheck.Enabled or not root:FindFirstChild('OwlLiftForce') then
								for _, item in {'iron', 'diamond', 'emerald', 'gold'} do
									item = getItem(item)
									if item then
										item = bedwars.Client:Get(remotes.DropItem):CallServer({
											item = item.tool,
											amount = item.amount
										})
	
										if item then
											item:SetAttribute('ClientDropTime', os.clock() + 100)
										end
									end
								end
							end
						end
					end
	
					task.wait(0.1)
				until not AutoVoidDrop.Enabled
			end
		end,
		Tooltip = 'Dumps your resources if you fall into the void'
	})
	OwlCheck = AutoVoidDrop:CreateToggle({
		Name = 'Owl check',
		Default = true,
		Tooltip = 'Holds onto your items if an owl is coming for them'
	})
end)
	
run(function()
	local MissileTP
	
	MissileTP = vape.Categories.Utility:CreateModule({
		Name = 'MissileTP',
		Function = function(callback)
			if callback then
				MissileTP:Toggle()
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
		Tooltip = 'Spawns a missile and sends it at whoever is\nnearest your mouse.'
	})
end)

run(function()
	local PickupRange
	local Range
	local Network
	local Lower
	local Delay
	--[[ Item drop -> the tick() at which another request for it is allowed. Weak keys so drops
	that get picked up or destroyed fall out on their own rather than piling up for the
	round; cleared on disable regardless. ]]
	local pickups = setmetatable({}, {__mode = 'k'})

	PickupRange = vape.Categories.Utility:CreateModule({
		Name = 'PickupRange',
		Function = function(callback)
			if callback then
				local items = collection('ItemDrop', PickupRange)
				repeat
					if entitylib.isAlive then
						local localPosition = entitylib.character.RootPart.Position
						for _, v in items do
							if tick() - (v:GetAttribute('ClientDropTime') or 0) < 2 then continue end
							if isnetworkowner(v) and Network.Enabled and entitylib.character.Humanoid.Health > 0 then 
								v.CFrame = CFrame.new(localPosition - Vector3.new(0, 3, 0)) 
							end
							
							if (localPosition - v.Position).Magnitude <= Range.Value then
								if Lower.Enabled and (localPosition.Y - v.Position.Y) < (entitylib.character.HipHeight - 1) then continue end

								--[[ One request per drop per Delay, rather than one per pass.
								This loop runs at 10hz and had nothing holding it back, so
								it re-asked for every drop in range until the server got
								round to removing it -- three items on the floor is already
								1800 calls a minute against the 299 the server's rate
								limiter allows. AntiBanwave mirrors that budget and drops
								the overflow, which is why pickups died with it enabled.
								The first sighting is still instant: an unseen drop has no
								entry here, so it goes out on the pass that spots it. ]]
								if (pickups[v] or 0) >= tick() then continue end
								pickups[v] = tick() + Delay.Value

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
				until not PickupRange.Enabled
			else
				table.clear(pickups)
			end
		end,
		Tooltip = 'Grabs items from further away'
	})
	Range = PickupRange:CreateSlider({
		Name = 'Range',
		Min = 1,
		Max = 10,
		Default = 10,
		Suffix = function(val) 
			return val == 1 and 'stud' or 'studs' 
		end
	})
	Delay = PickupRange:CreateSlider({
		Name = 'Delay',
		Min = 0.2,
		Max = 5,
		Default = 1,
		Decimal = 10,
		Suffix = function(val) return 's' end,
		Tooltip = 'How long before it retries the same drop. New drops are\nalways grabbed the moment they show up, so this only\naffects retries. Go too low and a floor full of items\nwill blow past the 299/min the server allows.'
	})
	Network = PickupRange:CreateToggle({
		Name = 'Network TP',
		Default = true
	})
	Lower = PickupRange:CreateToggle({Name = 'Feet Check'})
end)

run(function()
	local RavenTP
	
	RavenTP = vape.Categories.Utility:CreateModule({
		Name = 'RavenTP',
		Function = function(callback)
			if callback then
				RavenTP:Toggle()
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
		Tooltip = 'Spawns a raven and sends it at whoever is\nnearest your mouse.'
	})
end)
	
run(function()
	local StaffDetector
	local Mode
	local Clans
	local Party
	local Profile
	local Users
	local blacklistedclans = {'gg', 'gg2', 'DV', 'DV2'}
	local blacklisteduserids = {3826146717, 4531785383, 1049767300, 4926350670, 653085195, 184655415, 2752307430, 5087196317, 5744061325, 1536265275}
	local joined = {}

	if vape.ThreadFix then
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
		if not vape.Loaded then
			repeat task.wait(0.1) until vape.Loaded
		end
	
		notif('StaffDetector', 'Staff Detected ('..checktype..'): '..plr.Name..' ('..plr.UserId..')', 60, 'alert')
		whitelist.customtags[plr.Name] = {{text = 'GAME STAFF', color = Color3.new(1, 0, 0)}}
	
		if Party.Enabled and not checktype:find('clan') then
			bedwars.PartyController:leaveParty()
		end
	
		if Mode.Value == 'Uninject' then
			task.spawn(function()
				vape:Uninject()
			end)
			game:GetService('StarterGui'):SetCore('SendNotification', {
				Title = 'StaffDetector',
				Text = 'Staff Detected ('..checktype..')\n'..plr.Name..' ('..plr.UserId..')',
				Duration = 60,
			})
		elseif Mode.Value == 'Requeue' then
			bedwars.QueueController:joinQueue(store.queueType)
		elseif Mode.Value == 'Profile' then
			vape.Save = function() end
			if vape.Profile ~= Profile.Value then
				vape:Load(true, Profile.Value)
			end
		elseif Mode.Value == 'AutoConfig' then
			local safe = {'AutoClicker', 'Reach', 'Sprint', 'HitFix', 'StaffDetector'}
			vape.Save = function() end
			for i, v in (vape.EachModule and vape:EachModule() or vape.Modules) do
				if not (table.find(safe, i) or v.Category == 'Render') then
					if v.Enabled then
						v:Toggle()
					end
					v:SetBind('')
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

	local function checkJoin(plr)
		if resolved[plr] or not isSpectating(plr) then return end
		if bedwars.Store:getState().Game.customMatch then return end

		--[[ Gate on when the player ARRIVED, not on when this check happens to fire. A late
		loader's Spectator attribute can settle minutes into the match, long past the grace
		window, so accepting any late check, as the old version did, is what flagged them. nil
		means they were already here when StaffDetector turned on,
		and we never saw them arrive, so there is nothing to judge. ]]
		local arrival = arrivedAfter[plr]
		if not arrival or arrival < JOIN_GRACE then return end

		resolved[plr] = true
		--[[ Let them finish loading before deciding they have no team. 'PlayerConnected' is the
		game's own has-this-client-finished-connecting flag (GamePlayer.hasFinishedConnecting). ]]
		local deadline = os.clock() + 30
		while plr.Parent and plr:GetAttribute('PlayerConnected') ~= true and os.clock() < deadline do
			task.wait(0.5)
		end
		task.wait(SETTLE)
		--[[ Re-verify. A late loader has a Team by now, at which point there was never anything
		to report; clearing resolved lets a genuine later transition still be caught. ]]
		if not plr.Parent or not isSpectating(plr) then
			resolved[plr] = nil
			return
		end

		local suc, tab = pcall(function()
			local ids, pages = {}, playersService:GetFriendsAsync(plr.UserId)
			for _ = 1, 4 do
				for _, v in pages:GetCurrentPage() do
					table.insert(ids, v.Id)
				end
				if pages.IsFinished then break end
				pages:AdvanceToNextPageAsync()
			end
			return ids
		end)
		--[[ GetFriendsAsync throws on rate limits and on private friend lists. A failed lookup is
		not evidence of anything -- treating it as 'has no friends here' would flag on nothing. ]]
		if not suc then
			resolved[plr] = nil
			return
		end

		local friend = checkFriends(tab)
		if not friend then
			staffFunction(plr, 'impossible_join')
		else
			notif('StaffDetector', string.format('Spectator %s joined from %s', plr.Name, friend), 20, 'warning')
		end
	end

	local function playerAdded(plr, existing)
		joined[plr.UserId] = plr.Name
		if plr == lplr then return end
		if not existing then
			arrivedAfter[plr] = matchRunningFor()
		end

		if table.find(blacklisteduserids, plr.UserId) or table.find(Users.ListEnabled, tostring(plr.UserId)) then
			staffFunction(plr, 'blacklisted_user')
		elseif getRole(plr, 5774246) >= 100 then
			staffFunction(plr, 'staff_role')
		else
			--[[ Spawned rather than called inline: checkJoin now yields while the player settles,
			and blocking the signal handler would stall every later attribute change on them. ]]
			StaffDetector:Clean(plr:GetAttributeChangedSignal('Spectator'):Connect(function()
				task.spawn(checkJoin, plr)
			end))
			--[[ Covers a mid-match join whose Spectator attribute replicated with the player, so
			no change signal ever fires for it. ]]
			task.spawn(checkJoin, plr)

			if not plr:GetAttribute('ClanTag') then
				plr:GetAttributeChangedSignal('ClanTag'):Wait()
			end

			if table.find(blacklistedclans, plr:GetAttribute('ClanTag')) and vape.Loaded and Clans.Enabled then
				resolved[plr] = true
				staffFunction(plr, 'blacklisted_clan_'..plr:GetAttribute('ClanTag'):lower())
			end
		end
	end
	
	StaffDetector = vape.Categories.Utility:CreateModule({
		Name = 'StaffDetector',
		Function = function(callback)
			if callback then
				StaffDetector:Clean(playersService.PlayerAdded:Connect(playerAdded))
				for _, v in playersService:GetPlayers() do
					--[[ existing = true: these were already here, so no arrival stamp and no
					impossible-join check. The blacklist and staff-role checks still run. ]]
					task.spawn(playerAdded, v, true)
				end
			else
				table.clear(joined)
				table.clear(arrivedAfter)
				table.clear(resolved)
				matchRunningSince = nil
			end
		end,
		Tooltip = 'Lets you know when someone with a staff rank is in the server'
	})
	Mode = StaffDetector:CreateDropdown({
		Name = 'Mode',
		List = {'Uninject', 'Profile', 'Requeue', 'AutoConfig', 'Notify'},
		Function = function(val)
			if Profile.Object then
				Profile.Object.Visible = val == 'Profile'
			end
		end
	})
	Clans = StaffDetector:CreateToggle({
		Name = 'Blacklist clans',
		Default = true
	})
	Party = StaffDetector:CreateToggle({
		Name = 'Leave party'
	})
	Profile = StaffDetector:CreateTextBox({
		Name = 'Profile',
		Default = 'default',
		Darker = true,
		Visible = false
	})
	Users = StaffDetector:CreateTextList({
		Name = 'Users',
		Placeholder = 'player (userid)'
	})
	
	task.spawn(function()
		repeat task.wait(1) until vape.Loaded or vape.Loaded == nil
		if vape.Loaded and not StaffDetector.Enabled then
			StaffDetector:Toggle()
		end
	end)
end)
	
run(function()
	TrapDisabler = vape.Categories.Utility:CreateModule({
		Name = 'TrapDisabler',
		Tooltip = 'Turns off snap traps'
	})
end)
	
run(function()
	vape.Categories.World:CreateModule({
		Name = 'Anti-AFK',
		Function = function(callback)
			if callback then
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
		Tooltip = 'Keeps you in the game instead of getting kicked for idling'
	})
end)
	
run(function()
	local AutoSuffocate
	local Range
	local LimitItem
	
	local function fixPosition(pos)
		return bedwars.BlockController:getBlockPosition(pos) * 3
	end
	
	AutoSuffocate = vape.Categories.World:CreateModule({
		Name = 'AutoSuffocate',
		Function = function(callback)
			if callback then
				repeat
					local item = store.hand.toolType == 'block' and store.hand.tool.Name or not LimitItem.Enabled and getWool()
	
					if item then
						local plrs = entitylib.AllPosition({
							Part = 'RootPart',
							Range = Range.Value,
							Players = true
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
				until not AutoSuffocate.Enabled
			end
		end,
		Tooltip = 'Boxes in anyone stuck nearby'
	})
	Range = AutoSuffocate:CreateSlider({
		Name = 'Range',
		Min = 1,
		Max = 20,
		Default = 20,
		Suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
	LimitItem = AutoSuffocate:CreateToggle({
		Name = 'Limit to Items',
		Default = true
	})
end)
	
run(function()
	local AutoTool
	local old, event
	
	local function switchHotbarItem(block)
		if block and not block:GetAttribute('NoBreak') and not block:GetAttribute('Team'..(lplr:GetAttribute('Team') or 0)..'NoBreak') then
			local tool, slot = store.tools[bedwars.ItemMeta[block.Name].block.breakType], nil
			if tool then
				for i, v in store.inventory.hotbar do
					if v.item and v.item.itemType == tool.itemType then slot = i - 1 break end
				end
	
				if hotbarSwitch(slot) then
					if inputService:IsMouseButtonPressed(0) then 
						event:Fire() 
					end
					return true
				end
			end
		end
	end
	
	AutoTool = vape.Categories.World:CreateModule({
		Name = 'AutoTool',
		Function = function(callback)
			if callback then
				event = Instance.new('BindableEvent')
				AutoTool:Clean(event)
				AutoTool:Clean(event.Event:Connect(function()
					contextActionService:CallFunction('block-break', Enum.UserInputState.Begin, newproxy(true))
				end))
				old = bedwars.BlockBreaker.hitBlock
				bedwars.BlockBreaker.hitBlock = function(self, maid, raycastparams, ...)
					local block = self.clientManager:getBlockSelector():getMouseInfo(1, {ray = raycastparams})
					if switchHotbarItem(block and block.target and block.target.blockInstance or nil) then return end
					return old(self, maid, raycastparams, ...)
				end
			else
				bedwars.BlockBreaker.hitBlock = old
				old = nil
			end
		end,
		Tooltip = 'Grabs the right tool for you'
	})
end)
	
run(function()
	local BedProtector
	
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
			local block = bedwars.ItemMeta[item.itemType].block
			if block then
				table.insert(blocks, {item.itemType, block.health})
			end
		end
		table.sort(blocks, function(a, b) 
			return a[2] > b[2]
		end)
		return blocks
	end
	
	local function getPyramid(size, grid)
		local positions = {}
		for h = size, 0, -1 do
			for w = h, 0, -1 do
				table.insert(positions, Vector3.new(w, (size - h), ((h + 1) - w)) * grid)
				table.insert(positions, Vector3.new(w * -1, (size - h), ((h + 1) - w)) * grid)
				table.insert(positions, Vector3.new(w, (size - h), (h - w) * -1) * grid)
				table.insert(positions, Vector3.new(w * -1, (size - h), (h - w) * -1) * grid)
			end
		end
		return positions
	end
	
	BedProtector = vape.Categories.World:CreateModule({
		Name = 'BedProtector',
		Function = function(callback)
			if callback then
				local bed = getBedNear()
				bed = bed and bed.Position or nil
				if bed then
					for i, block in getBlocks() do
						for _, pos in getPyramid(i, 3) do
							if not BedProtector.Enabled then break end
							if getPlacedBlock(bed + pos) then continue end
							bedwars.placeBlock(bed + pos, block[1], false)
						end
					end
					if BedProtector.Enabled then 
						BedProtector:Toggle() 
					end
				else
					notif('BedProtector', 'Unable to locate bed', 5)
					BedProtector:Toggle()
				end
			end
		end,
		Tooltip = 'Walls your bed in with the strongest blocks you have.'
	})
end)
	
run(function()
	local ChestSteal
	local Range
	local Open
	local Skywars
	local Delay
	local Delays = {}
	
	local function lootChest(chest)
		chest = chest and chest.Value or nil
		if not chest or (Delays[chest] or 0) >= tick() then return end

		--[[ Counts what can actually be taken rather than what is in there. The gate used to
		be #GetChildren() > 1, but only Accessories are ever pulled -- so a chest holding
		anything else, or armour a ChestGetItem keeps failing on, never emptied and this
		kept firing at it for the rest of the round. ]]
		local accessories = {}
		for _, v in chest:GetChildren() do
			if v:IsA('Accessory') then
				table.insert(accessories, v)
			end
		end
		if #accessories == 0 then return end

		--[[ Two SetObservedChest calls go out per pass, so the old fixed 0.2s was 600 calls a
		minute off a single chest in range -- against the 299 the server's rate limiter
		allows, and doubling with every extra chest. AntiBanwave mirrors that budget and
		swallows the overflow (going over is a rate_limit_exceeded detection, and the
		server discards the calls either way), which is what looked like chest looting
		breaking partway through a round. The slider gives a chest-dense skywars map more
		more room; the accessory gate above is what keeps the steady-state cost at zero. ]]
		Delays[chest] = tick() + Delay.Value
		bedwars.Client:GetNamespace('Inventory'):Get('SetObservedChest'):SendToServer(chest)

		for _, v in accessories do
			task.spawn(function()
				pcall(function()
					bedwars.Client:GetNamespace('Inventory'):Get('ChestGetItem'):CallServer(chest, v)
				end)
			end)
		end

		bedwars.Client:GetNamespace('Inventory'):Get('SetObservedChest'):SendToServer(nil)
	end
	
	ChestSteal = vape.Categories.World:CreateModule({
		Name = 'ChestSteal',
		Function = function(callback)
			if callback then
				local chests = collection('chest', ChestSteal)
				--[[ The enabled check is the exit, not just the queue type: without it, toggling the
				module back off inside a test queue left this spinning at frame rate forever. ]]
				repeat task.wait(0.1) until store.queueType ~= 'bedwars_test' or (not ChestSteal.Enabled)
				if not ChestSteal.Enabled then return end
				if (not Skywars.Enabled) or store.queueType:find('skywars') then
					repeat
						if entitylib.isAlive and store.matchState ~= 2 then
							if Open.Enabled then
								if bedwars.AppController:isAppOpen('ChestApp') then
									lootChest(lplr.Character:FindFirstChild('ObservedChestFolder'))
								end
							else
								local localPosition = entitylib.character.RootPart.Position
								for _, v in chests do
									if (localPosition - v.Position).Magnitude <= Range.Value then
										lootChest(v:FindFirstChild('ChestFolderValue'))
									end
								end
							end
						end
						task.wait(0.1)
					until not ChestSteal.Enabled
				end
			else
				--[[ Keyed by chest folder, which is destroyed with the chest -- without this
				the table holds a reference to every chest looted this session. ]]
				table.clear(Delays)
			end
		end,
		Tooltip = 'Pulls items out of the chests near you.'
	})
	Range = ChestSteal:CreateSlider({
		Name = 'Range',
		Min = 0,
		Max = 18,
		Default = 18,
		Suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
	Delay = ChestSteal:CreateSlider({
		Name = 'Delay',
		Min = 0.2,
		Max = 3,
		Default = 0.5,
		Decimal = 10,
		Suffix = function(val) return 's' end,
		Tooltip = 'How long before it tries the same chest again.\nRaise it if looting dies off mid round, each pass\ncosts two remotes out of a 299/min budget.'
	})
	Open = ChestSteal:CreateToggle({Name = 'GUI Check'})
	Skywars = ChestSteal:CreateToggle({
		Name = 'Only Skywars',
		Function = function()
			if ChestSteal.Enabled then
				ChestSteal:Toggle()
				ChestSteal:Toggle()
			end
		end,
		Default = true
	})
end)
	
run(function()
	local Schematica
	local File
	local Mode
	local Transparency
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
			return isfile(File.Value) and httpService:JSONDecode(readfile(File.Value)) 
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
				holder.Parent = Schematica.Children
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
			writefile(File.Value, httpService:JSONEncode(savetab))
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
					part.Transparency = Transparency.Value
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
							if not Schematica.Enabled then break end
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
	
			if getTableSize(parts) <= 0 and Schematica.Enabled then
				notif('Schematica', 'Finished building', 5)
				Schematica:Toggle()
			end
		end
	end
	
	Schematica = vape.Categories.World:CreateModule({
		Name = 'Schematica',
		Function = function(callback)
			if callback then
				if not File.Value:find('.json') then
					notif('Schematica', 'Invalid file', 3)
					Schematica:Toggle()
					return
				end
	
				if Mode.Value == 'Save' then
					save()
					Schematica:Toggle()
				else
					local suc, read = pcall(function() 
						return isfile(File.Value) and httpService:JSONDecode(readfile(File.Value)) 
					end)
	
					if suc and read then
						load(read)
					else
						notif('Schematica', 'Missing / corrupted file', 3)
						Schematica:Toggle()
					end
				end
			else
				for _, v in parts do 
					v:Destroy() 
				end
				table.clear(parts)
			end
		end,
		Tooltip = 'Save your builds and drop them back down later'
	})
	File = Schematica:CreateTextBox({
		Name = 'File',
		Function = function()
			loadMaterials()
			point1, point2 = nil, nil
		end
	})
	Mode = Schematica:CreateDropdown({
		Name = 'Mode',
		List = {'Load', 'Save'}
	})
	Transparency = Schematica:CreateSlider({
		Name = 'Transparency',
		Min = 0,
		Max = 1,
		Default = 0.7,
		Decimal = 10,
		Function = function(val)
			for _, v in parts do 
				v.Transparency = val 
			end
		end
	})
end)
	
run(function()
	local ArmorSwitch
	local Mode
	local Targets
	local Range
	
	ArmorSwitch = vape.Categories.Inventory:CreateModule({
		Name = 'ArmorSwitch',
		Function = function(callback)
			if callback then
				if Mode.Value == 'Toggle' then
					repeat
						local state = entitylib.EntityPosition({
							Part = 'RootPart',
							Range = Range.Value,
							Players = Targets.Players.Enabled,
							NPCs = Targets.NPCs.Enabled,
							Wallcheck = Targets.Walls.Enabled
						}) and true or false
	
						for i = 0, 2 do
							if (store.inventory.inventory.armor[i + 1] ~= 'empty') ~= state and ArmorSwitch.Enabled then
								bedwars.Store:dispatch({
									type = 'InventorySetArmorItem',
									item = store.inventory.inventory.armor[i + 1] == 'empty' and state and getBestArmor(i) or nil,
									armorSlot = i
								})
								vapeEvents.InventoryChanged.Event:Wait()
							end
						end
						task.wait(0.1)
					until not ArmorSwitch.Enabled
				else
					ArmorSwitch:Toggle()
					for i = 0, 2 do
						bedwars.Store:dispatch({
							type = 'InventorySetArmorItem',
							item = store.inventory.inventory.armor[i + 1] == 'empty' and getBestArmor(i) or nil,
							armorSlot = i
						})
						vapeEvents.InventoryChanged.Event:Wait()
					end
				end
			end
		end,
		Tooltip = 'Swaps your armor on and off for baiting.'
	})
	Mode = ArmorSwitch:CreateDropdown({
		Name = 'Mode',
		List = {'Toggle', 'On Key'}
	})
	Targets = ArmorSwitch:CreateTargets({
		Players = true,
		NPCs = true
	})
	Range = ArmorSwitch:CreateSlider({
		Name = 'Range',
		Min = 1,
		Max = 30,
		Default = 30,
		Suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
end)
	
run(function()
	local AutoBuy
	local Sword
	local Armor
	local Upgrades
	local TierCheck
	local BedwarsCheck
	local GUI
	local SmartCheck
	local Custom = {}
	local CustomPost = {}
	local UpgradeToggles = {}
	local Functions, id = {}
	local Callbacks = {Custom, Functions, CustomPost}
	local npctick = tick()
	
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
	
	local function getShopNPC()
		local shop, items, upgrades, newid = nil, false, false, nil
		if entitylib.isAlive then
			local localPosition = entitylib.character.RootPart.Position
			for _, v in store.shop do
				--[[ GetPivot rather than .Position: the BedwarsItemShop tag sits on the
				shop container, not on a part -- the game's own getShopkeeperModel
				resolves the NPC as tagged:FindFirstChildWhichIsA('Model'), so the
				tagged instance is whatever holds desertMerchant. When that's a
				Model, .Position doesn't exist and indexing it throws, taking this
				whole function down so no shop ever registers. GetPivot is defined
				on both Model and BasePart, so it works either way. ]]
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
	
	local function canBuy(item, currencytable, amount)
		amount = amount or 1
		if not currencytable[item.currency] then
			local currency = getItem(item.currency)
			currencytable[item.currency] = currency and currency.amount or 0
		end
		if item.ignoredByKit and table.find(item.ignoredByKit, store.equippedKit or '') then return false end
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
		notif('AutoBuy', 'Bought '..bedwars.ItemMeta[item.itemType].displayName, 3)
		bedwars.Client:Get('BedwarsPurchaseItem'):CallServerAsync({
			shopItem = item,
			shopId = id
		}):andThen(function(suc)
			if suc then
				bedwars.SoundManager:playSound(bedwars.SoundList.BEDWARS_PURCHASE_ITEM)
				bedwars.Store:dispatch({
					type = 'BedwarsAddItemPurchased',
					itemType = item.itemType
				})
				bedwars.BedwarsShopController.alreadyPurchasedMap[item.itemType] = true
			end
		end)
		currencytable[item.currency] -= item.price
	end
	
    local function buyUpgrade(upgradeType, currencytable)
        if not Upgrades.Enabled then return end
        local upgrade = bedwars.TeamUpgradeMeta[upgradeType]
        local currentUpgrades = bedwars.Store:getState().Bedwars.teamUpgrades[lplr:GetAttribute('Team')] or {}
        local currentTier = (currentUpgrades[upgradeType] or 0) + 1
        local bought = false
    
        for i = currentTier, #upgrade.tiers do
            local tier = upgrade.tiers[i]
            if tier.availableOnlyInQueue and not table.find(tier.availableOnlyInQueue, store.queueType) then continue end
    
            if canBuy({currency = 'diamond', price = tier.cost}, currencytable) then
                notif('AutoBuy', 'Bought '..(upgrade.name == 'Armor' and 'Protection' or upgrade.name)..' '..i, 3)
                bedwars.Client:Get('RequestPurchaseTeamUpgrade'):CallServerAsync(upgradeType)
                currencytable.diamond -= tier.cost
                bought = true
            else
                break
            end
        end
    
        return bought
    end
	
	local function buyTool(tool, tools, currencytable)
		local bought, buyable = false
		tool = tool and table.find(tools, tool.itemType) and table.find(tools, tool.itemType) + 1 or math.huge
	
		for i = tool, #tools do
			local v = bedwars.Shop.getShopItem(tools[i], lplr)
			if canBuy(v, currencytable) then
				if SmartCheck.Enabled and bedwars.ItemMeta[tools[i]].breakBlock and i > 2 then
					if Armor.Enabled then
						local currentarmor = store.inventory.inventory.armor[2]
						currentarmor = currentarmor and currentarmor ~= 'empty' and currentarmor.itemType or 'none'
						if (table.find(armors, currentarmor) or 3) < 3 then break end
					end
					if Sword.Enabled then
						if store.tools.sword and (table.find(swords, store.tools.sword.itemType) or 2) < 2 then break end
					end
				end
				bought = true
				buyable = v
			end
			if TierCheck.Enabled and v.nextTier then break end
		end
	
		if buyable then
			buyItem(buyable, currencytable)
		end
	
		return bought
	end
	
	AutoBuy = vape.Categories.Inventory:CreateModule({
		Name = 'AutoBuy',
		Function = function(callback)
			if callback then
				repeat task.wait(0.1) until store.queueType ~= 'bedwars_test' or (not AutoBuy.Enabled)
				if not AutoBuy.Enabled then return end
				if BedwarsCheck.Enabled and not store.queueType:find('bedwars') then return end
	
				--[[ A pass that bought nothing used to latch AutoBuy off entirely
				(npctick = tick() + math.huge), leaving InventoryAmountChanged as the
				only way back in. Anything that changes what you can afford without
				changing your inventory left it asleep -- a teammate's upgrade
				unlocking the next tier, store.shopLoaded flipping true after the
				latch, a kit swap rewriting the sword table, an edit to the Item list
				-- so standing at the shop with the currency already in hand bought
				nothing until some unrelated pickup happened to poke it. Re-check on a
				bounded interval instead, and only while actually in range of a
				shopkeeper: one shop scan every 0.3s, worst case ~0.4s to buy. ]]
				local idlerecheck = 0.3
				local lastupgrades, wasnear, buytick = nil, false, 0

				repeat
					local npc, shop, upgrades, newid = getShopNPC()
					id = newid
					if GUI.Enabled then
						if not (bedwars.AppController:isAppOpen('BedwarsItemShopApp') or bedwars.AppController:isAppOpen('TeamUpgradeApp')) then
							npc = nil
						end
					end

					--[[ Walking into range (or swapping shopkeeper) buys on this pass rather
					than sitting out whatever idle wait was left over. math.max keeps a
					pending post-purchase cooldown intact, so stepping back into range
					right after a buy can't re-fire it off a stale currencytable. ]]
					if npc and (not wasnear or lastupgrades ~= upgrades) then
						npctick = math.max(tick(), buytick)
						lastupgrades = upgrades
					end
					wasnear = npc ~= nil

					if npc and npctick <= tick() and store.matchState ~= 2 and store.shopLoaded then
						local currencytable = {}
						local waitcheck
						for _, tab in Callbacks do
							for _, callback in tab do
								if callback(currencytable, shop, upgrades) then
									waitcheck = true
								end
							end
						end
						--[[ 0.4s after a purchase so the next pass reads an inventory the
						server has already updated: currencytable is rebuilt from it each
						pass, and a stale read buys the same tier twice. ]]
						buytick = waitcheck and (tick() + 0.4) or buytick
						npctick = tick() + (waitcheck and 0.4 or idlerecheck)
					end
	
					task.wait(0.1)
				until not AutoBuy.Enabled
			else
				npctick = tick()
			end
		end,
		Tooltip = 'Buys your items for you when you walk up to the shop'
	})
	Sword = AutoBuy:CreateToggle({
		Name = 'Buy Sword',
		Function = function(callback)
			npctick = tick()
			Functions[2] = callback and function(currencytable, shop)
				if not shop then return end
	
				if store.equippedKit == 'dasher' then
					swords = {
						[1] = 'wood_dao',
						[2] = 'stone_dao',
						[3] = 'iron_dao',
						[4] = 'diamond_dao',
						[5] = 'emerald_dao'
					}
				elseif store.equippedKit == 'ice_queen' then
					swords[5] = 'ice_sword'
				elseif store.equippedKit == 'ember' then
					swords[5] = 'infernal_saber'
				elseif store.equippedKit == 'lumen' then
					swords[5] = 'light_sword'
				end
	
				return buyTool(store.tools.sword, swords, currencytable)
			end or nil
		end
	})
	Armor = AutoBuy:CreateToggle({
		Name = 'Buy Armor',
		Function = function(callback)
			npctick = tick()
			Functions[1] = callback and function(currencytable, shop)
				if not shop then return end
				local currentarmor = store.inventory.inventory.armor[2] ~= 'empty' and store.inventory.inventory.armor[2] or getBestArmor(1)
				currentarmor = currentarmor and currentarmor.itemType or 'none'
				return buyTool({itemType = currentarmor}, armors, currencytable)
			end or nil
		end,
		Default = true
	})
	AutoBuy:CreateToggle({
		Name = 'Buy Axe',
		Function = function(callback)
			npctick = tick()
			Functions[3] = callback and function(currencytable, shop)
				if not shop then return end
				return buyTool(store.tools.wood or {itemType = 'none'}, axes, currencytable)
			end or nil
		end
	})
	AutoBuy:CreateToggle({
		Name = 'Buy Pickaxe',
		Function = function(callback)
			npctick = tick()
			Functions[4] = callback and function(currencytable, shop)
				if not shop then return end
				return buyTool(store.tools.stone, pickaxes, currencytable)
			end or nil
		end
	})
	Upgrades = AutoBuy:CreateToggle({
		Name = 'Buy Upgrades',
		Function = function(callback)
			for _, v in UpgradeToggles do
				v.Object.Visible = callback
			end
		end,
		Default = true
	})
	local count = 0
	for i, v in bedwars.TeamUpgradeMeta do
		local toggleCount = count
		table.insert(UpgradeToggles, AutoBuy:CreateToggle({
			Name = 'Buy '..(v.name == 'Armor' and 'Protection' or v.name),
			Function = function(callback)
				npctick = tick()
				Functions[5 + toggleCount + (v.name == 'Armor' and 20 or 0)] = callback and function(currencytable, shop, upgrades)
					if not upgrades then return end
					if v.disabledInQueue and table.find(v.disabledInQueue, store.queueType) then return end
					return buyUpgrade(i, currencytable)
				end or nil
			end,
			Darker = true,
			Default = (i == 'ARMOR' or i == 'DAMAGE')
		}))
		count += 1
	end
	TierCheck = AutoBuy:CreateToggle({Name = 'Tier Check'})
	BedwarsCheck = AutoBuy:CreateToggle({
		Name = 'Only Bedwars',
		Function = function()
			if AutoBuy.Enabled then
				AutoBuy:Toggle()
				AutoBuy:Toggle()
			end
		end,
		Default = true
	})
	GUI = AutoBuy:CreateToggle({Name = 'GUI check'})
	SmartCheck = AutoBuy:CreateToggle({
		Name = 'Smart check',
		Default = true,
		Tooltip = 'Gets iron armor before the iron axe'
	})
	AutoBuy:CreateTextList({
		Name = 'Item',
		Placeholder = 'priority/item/amount/after',
		Function = function(list)
			table.clear(Custom)
			table.clear(CustomPost)
			for _, entry in list do
				local tab = entry:split('/')
				local ind = tonumber(tab[1])
				if ind then
					(tab[4] and CustomPost or Custom)[ind] = function(currencytable, shop)
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
	
run(function()
	local AutoConsume
	local Health
	local SpeedPotion
	local Apple
	local ShieldPotion
	
	local function consumeCheck(attribute)
		if entitylib.isAlive then
			if SpeedPotion.Enabled and (not attribute or attribute == 'StatusEffect_speed') then
				local speedpotion = getItem('speed_potion')
				if speedpotion and (not lplr.Character:GetAttribute('StatusEffect_speed')) then
					for _ = 1, 4 do
						if bedwars.Client:Get(remotes.ConsumeItem):CallServer({item = speedpotion.tool}) then break end
					end
				end
			end
	
			if Apple.Enabled and (not attribute or attribute:find('Health')) then
				if (lplr.Character:GetAttribute('Health') / lplr.Character:GetAttribute('MaxHealth')) <= (Health.Value / 100) then
					local apple = getItem('orange') or (not lplr.Character:GetAttribute('StatusEffect_golden_apple') and getItem('golden_apple')) or getItem('apple')
					
					if apple then
						bedwars.Client:Get(remotes.ConsumeItem):CallServerAsync({
							item = apple.tool
						})
					end
				end
			end
	
			if ShieldPotion.Enabled and (not attribute or attribute:find('Shield')) then
				if (lplr.Character:GetAttribute('Shield_POTION') or 0) == 0 then
					local shield = getItem('big_shield') or getItem('mini_shield')
	
					if shield then
						bedwars.Client:Get(remotes.ConsumeItem):CallServerAsync({
							item = shield.tool
						})
					end
				end
			end
		end
	end
	
	AutoConsume = vape.Categories.Inventory:CreateModule({
		Name = 'AutoConsume',
		Function = function(callback)
			if callback then
				AutoConsume:Clean(vapeEvents.InventoryAmountChanged.Event:Connect(consumeCheck))
				AutoConsume:Clean(vapeEvents.AttributeChanged.Event:Connect(function(attribute)
					if attribute:find('Shield') or attribute:find('Health') or attribute == 'StatusEffect_speed' then
						consumeCheck(attribute)
					end
				end))
				consumeCheck()
			end
		end,
		Tooltip = 'Heals you once your health or shield drops under the threshold.'
	})
	Health = AutoConsume:CreateSlider({
		Name = 'Health Percent',
		Min = 1,
		Max = 99,
		Default = 70,
		Suffix = function(val) return '%' end
	})
	SpeedPotion = AutoConsume:CreateToggle({
		Name = 'Speed Potions',
		Default = true
	})
	Apple = AutoConsume:CreateToggle({
		Name = 'Apple',
		Default = true
	})
	ShieldPotion = AutoConsume:CreateToggle({
		Name = 'Shield Potions',
		Default = true
	})
end)
	
run(function()
	local AutoHotbar
	local Mode
	local Clear
	local List
	local Active
	
	local function CreateWindow(self)
		local selectedslot = 1
		local window = Instance.new('Frame')
		window.Name = 'HotbarGUI'
		window.Size = UDim2.fromOffset(660, 465)
		window.Position = UDim2.fromScale(0.5, 0.5)
		window.BackgroundColor3 = uipallet.Main
		window.AnchorPoint = Vector2.new(0.5, 0.5)
		window.Visible = false
		window.Parent = vape.gui.ScaledGui
		local title = Instance.new('TextLabel')
		title.Name = 'Title'
		title.Size = UDim2.new(1, -10, 0, 20)
		title.Position = UDim2.fromOffset(math.abs(title.Size.X.Offset), 12)
		title.BackgroundTransparency = 1
		title.Text = 'AutoHotbar'
		title.TextXAlignment = Enum.TextXAlignment.Left
		title.TextColor3 = uipallet.Text
		title.TextSize = 13
		title.FontFace = uipallet.Font
		title.Parent = window
		local divider = Instance.new('Frame')
		divider.Name = 'Divider'
		divider.Size = UDim2.new(1, 0, 0, 1)
		divider.Position = UDim2.fromOffset(0, 40)
		divider.BackgroundColor3 = color.Light(uipallet.Main, 0.04)
		divider.BorderSizePixel = 0
		divider.Parent = window
		addBlur(window)
		local modal = Instance.new('TextButton')
		modal.Text = ''
		modal.BackgroundTransparency = 1
		modal.Modal = true
		modal.Parent = window
		local corner = Instance.new('UICorner')
		corner.CornerRadius = UDim.new(0, 5)
		corner.Parent = window
		local close = Instance.new('ImageButton')
		close.Name = 'Close'
		close.Size = UDim2.fromOffset(24, 24)
		close.Position = UDim2.new(1, -35, 0, 9)
		close.BackgroundColor3 = Color3.new(1, 1, 1)
		close.BackgroundTransparency = 1
		close.Image = getcustomasset('pistonware/assets/new/close.png')
		close.ImageColor3 = color.Light(uipallet.Text, 0.2)
		close.ImageTransparency = 0.5
		close.AutoButtonColor = false
		close.Parent = window
		close.MouseEnter:Connect(function()
			close.ImageTransparency = 0.3
			tween:Tween(close, TweenInfo.new(0.2), {
				BackgroundTransparency = 0.6
			})
		end)
		close.MouseLeave:Connect(function()
			close.ImageTransparency = 0.5
			tween:Tween(close, TweenInfo.new(0.2), {
				BackgroundTransparency = 1
			})
		end)
		close.MouseButton1Click:Connect(function()
			window.Visible = false
			vape.gui.ScaledGui.ClickGui.Visible = true
		end)
		local closecorner = Instance.new('UICorner')
		closecorner.CornerRadius = UDim.new(1, 0)
		closecorner.Parent = close
		local bigslot = Instance.new('Frame')
		bigslot.Size = UDim2.fromOffset(110, 111)
		bigslot.Position = UDim2.fromOffset(11, 71)
		bigslot.BackgroundColor3 = color.Dark(uipallet.Main, 0.02)
		bigslot.Parent = window
		local bigslotcorner = Instance.new('UICorner')
		bigslotcorner.CornerRadius = UDim.new(0, 4)
		bigslotcorner.Parent = bigslot
		local bigslotstroke = Instance.new('UIStroke')
		bigslotstroke.Color = color.Light(uipallet.Main, 0.034)
		bigslotstroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		bigslotstroke.Parent = bigslot
		local slotnum = Instance.new('TextLabel')
		slotnum.Size = UDim2.fromOffset(80, 20)
		slotnum.Position = UDim2.fromOffset(25, 200)
		slotnum.BackgroundTransparency = 1
		slotnum.Text = 'SLOT 1'
		slotnum.TextColor3 = color.Dark(uipallet.Text, 0.1)
		slotnum.TextSize = 12
		slotnum.FontFace = uipallet.Font
		slotnum.Parent = window
		for i = 1, 9 do
			local slotbkg = Instance.new('TextButton')
			slotbkg.Name = 'Slot'..i
			slotbkg.Size = UDim2.fromOffset(51, 52)
			slotbkg.Position = UDim2.fromOffset(89 + (i * 55), 382)
			slotbkg.BackgroundColor3 = color.Dark(uipallet.Main, 0.02)
			slotbkg.Text = ''
			slotbkg.AutoButtonColor = false
			slotbkg.Parent = window
			local slotimage = Instance.new('ImageLabel')
			slotimage.Size = UDim2.fromOffset(32, 32)
			slotimage.Position = UDim2.new(0.5, -16, 0.5, -16)
			slotimage.BackgroundTransparency = 1
			slotimage.Image = ''
			slotimage.Parent = slotbkg
			local slotcorner = Instance.new('UICorner')
			slotcorner.CornerRadius = UDim.new(0, 4)
			slotcorner.Parent = slotbkg
			local slotstroke = Instance.new('UIStroke')
			slotstroke.Color = color.Light(uipallet.Main, 0.04)
			slotstroke.Thickness = 2
			slotstroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
			slotstroke.Enabled = i == selectedslot
			slotstroke.Parent = slotbkg
			slotbkg.MouseEnter:Connect(function()
				slotbkg.BackgroundColor3 = color.Light(uipallet.Main, 0.034)
			end)
			slotbkg.MouseLeave:Connect(function()
				slotbkg.BackgroundColor3 = color.Dark(uipallet.Main, 0.02)
			end)
			slotbkg.MouseButton1Click:Connect(function()
				window['Slot'..selectedslot].UIStroke.Enabled = false
				selectedslot = i
				slotstroke.Enabled = true
				slotnum.Text = 'SLOT '..selectedslot
			end)
			slotbkg.MouseButton2Click:Connect(function()
				local obj = self.Hotbars[self.Selected]
				if obj then
					window['Slot'..i].ImageLabel.Image = ''
					obj.Hotbar[tostring(i)] = nil
					obj.Object['Slot'..i].Image = '	'
				end
			end)
		end
		local searchbkg = Instance.new('Frame')
		searchbkg.Size = UDim2.fromOffset(496, 31)
		searchbkg.Position = UDim2.fromOffset(142, 80)
		searchbkg.BackgroundColor3 = color.Light(uipallet.Main, 0.034)
		searchbkg.Parent = window
		local search = Instance.new('TextBox')
		search.Size = UDim2.new(1, -10, 0, 31)
		search.Position = UDim2.fromOffset(10, 0)
		search.BackgroundTransparency = 1
		search.Text = ''
		search.PlaceholderText = ''
		search.TextXAlignment = Enum.TextXAlignment.Left
		search.TextColor3 = uipallet.Text
		search.TextSize = 12
		search.FontFace = uipallet.Font
		search.ClearTextOnFocus = false
		search.Parent = searchbkg
		local searchcorner = Instance.new('UICorner')
		searchcorner.CornerRadius = UDim.new(0, 4)
		searchcorner.Parent = searchbkg
		local searchicon = Instance.new('ImageLabel')
		searchicon.Size = UDim2.fromOffset(14, 14)
		searchicon.Position = UDim2.new(1, -26, 0, 8)
		searchicon.BackgroundTransparency = 1
		searchicon.Image = getcustomasset('pistonware/assets/new/search.png')
		searchicon.ImageColor3 = color.Light(uipallet.Main, 0.37)
		searchicon.Parent = searchbkg
		local children = Instance.new('ScrollingFrame')
		children.Name = 'Children'
		children.Size = UDim2.fromOffset(500, 240)
		children.Position = UDim2.fromOffset(144, 122)
		children.BackgroundTransparency = 1
		children.BorderSizePixel = 0
		children.ScrollBarThickness = 2
		children.ScrollBarImageTransparency = 0.75
		children.CanvasSize = UDim2.new()
		children.Parent = window
		local windowlist = Instance.new('UIGridLayout')
		windowlist.SortOrder = Enum.SortOrder.LayoutOrder
		windowlist.FillDirectionMaxCells = 9
		windowlist.CellSize = UDim2.fromOffset(51, 52)
		windowlist.CellPadding = UDim2.fromOffset(4, 3)
		windowlist.Parent = children
		windowlist:GetPropertyChangedSignal('AbsoluteContentSize'):Connect(function()
			if vape.ThreadFix then
				setthreadidentity(8)
			end
			children.CanvasSize = UDim2.fromOffset(0, windowlist.AbsoluteContentSize.Y / vape.guiscale.Scale)
		end)
		table.insert(vape.Windows, window)
	
		local function createitem(id, image)
			local slotbkg = Instance.new('TextButton')
			slotbkg.BackgroundColor3 = color.Light(uipallet.Main, 0.02)
			slotbkg.Text = ''
			slotbkg.AutoButtonColor = false
			slotbkg.Parent = children
			local slotimage = Instance.new('ImageLabel')
			slotimage.Size = UDim2.fromOffset(32, 32)
			slotimage.Position = UDim2.new(0.5, -16, 0.5, -16)
			slotimage.BackgroundTransparency = 1
			slotimage.Image = image
			slotimage.Parent = slotbkg
			local slotcorner = Instance.new('UICorner')
			slotcorner.CornerRadius = UDim.new(0, 4)
			slotcorner.Parent = slotbkg
			slotbkg.MouseEnter:Connect(function()
				slotbkg.BackgroundColor3 = color.Light(uipallet.Main, 0.04)
			end)
			slotbkg.MouseLeave:Connect(function()
				slotbkg.BackgroundColor3 = color.Light(uipallet.Main, 0.02)
			end)
			slotbkg.MouseButton1Click:Connect(function()
				local obj = self.Hotbars[self.Selected]
				if obj then
					window['Slot'..selectedslot].ImageLabel.Image = image
					obj.Hotbar[tostring(selectedslot)] = id
					obj.Object['Slot'..selectedslot].Image = image
				end
			end)
		end
	
		local function indexSearch(text)
			for _, v in children:GetChildren() do
				if v:IsA('TextButton') then
					v:ClearAllChildren()
					v:Destroy()
				end
			end
	
			if text == '' then
				for _, v in {'diamond_sword', 'diamond_pickaxe', 'diamond_axe', 'shears', 'wood_bow', 'wool_white', 'fireball', 'apple', 'iron', 'gold', 'diamond', 'emerald'} do
					createitem(v, bedwars.ItemMeta[v].image)
				end
				return
			end
	
			for i, v in bedwars.ItemMeta do
				if text:lower() == i:lower():sub(1, text:len()) then
					if not v.image then continue end
					createitem(i, v.image)
				end
			end
		end
	
		search:GetPropertyChangedSignal('Text'):Connect(function()
			indexSearch(search.Text)
		end)
		indexSearch('')
	
		return window
	end
	
	vape.Components.HotbarList = function(optionsettings, children, api)
		if vape.ThreadFix then
			setthreadidentity(8)
		end
		local optionapi = {
			Type = 'HotbarList',
			Hotbars = {},
			Selected = 1
		}
		local hotbarlist = Instance.new('TextButton')
		hotbarlist.Name = 'HotbarList'
		hotbarlist.Size = UDim2.fromOffset(220, 40)
		hotbarlist.BackgroundColor3 = optionsettings.Darker and (children.BackgroundColor3 == color.Dark(uipallet.Main, 0.02) and color.Dark(uipallet.Main, 0.04) or color.Dark(uipallet.Main, 0.02)) or children.BackgroundColor3
		hotbarlist.Text = ''
		hotbarlist.BorderSizePixel = 0
		hotbarlist.AutoButtonColor = false
		hotbarlist.Parent = children
		local textbkg = Instance.new('Frame')
		textbkg.Name = 'BKG'
		textbkg.Size = UDim2.new(1, -20, 0, 31)
		textbkg.Position = UDim2.fromOffset(10, 4)
		textbkg.BackgroundColor3 = color.Light(uipallet.Main, 0.034)
		textbkg.Parent = hotbarlist
		local textbkgcorner = Instance.new('UICorner')
		textbkgcorner.CornerRadius = UDim.new(0, 4)
		textbkgcorner.Parent = textbkg
		local textbutton = Instance.new('TextButton')
		textbutton.Name = 'HotbarList'
		textbutton.Size = UDim2.new(1, -2, 1, -2)
		textbutton.Position = UDim2.fromOffset(1, 1)
		textbutton.BackgroundColor3 = uipallet.Main
		textbutton.Text = ''
		textbutton.AutoButtonColor = false
		textbutton.Parent = textbkg
		textbutton.MouseEnter:Connect(function()
			tween:Tween(textbkg, TweenInfo.new(0.2), {
				BackgroundColor3 = color.Light(uipallet.Main, 0.14)
			})
		end)
		textbutton.MouseLeave:Connect(function()
			tween:Tween(textbkg, TweenInfo.new(0.2), {
				BackgroundColor3 = color.Light(uipallet.Main, 0.034)
			})
		end)
		local textbuttoncorner = Instance.new('UICorner')
		textbuttoncorner.CornerRadius = UDim.new(0, 4)
		textbuttoncorner.Parent = textbutton
		local textbuttonicon = Instance.new('ImageLabel')
		textbuttonicon.Size = UDim2.fromOffset(12, 12)
		textbuttonicon.Position = UDim2.fromScale(0.5, 0.5)
		textbuttonicon.AnchorPoint = Vector2.new(0.5, 0.5)
		textbuttonicon.BackgroundTransparency = 1
		textbuttonicon.Image = getcustomasset('pistonware/assets/new/add.png')
		textbuttonicon.ImageColor3 = Color3.fromHSV(0.46, 0.96, 0.52)
		textbuttonicon.Parent = textbutton
		local childrenlist = Instance.new('Frame')
		childrenlist.Size = UDim2.new(1, 0, 1, -40)
		childrenlist.Position = UDim2.fromOffset(0, 40)
		childrenlist.BackgroundTransparency = 1
		childrenlist.Parent = hotbarlist
		local windowlist = Instance.new('UIListLayout')
		windowlist.SortOrder = Enum.SortOrder.LayoutOrder
		windowlist.HorizontalAlignment = Enum.HorizontalAlignment.Center
		windowlist.Padding = UDim.new(0, 3)
		windowlist.Parent = childrenlist
		windowlist:GetPropertyChangedSignal('AbsoluteContentSize'):Connect(function()
			if vape.ThreadFix then
				setthreadidentity(8)
			end
			hotbarlist.Size = UDim2.fromOffset(220, math.min(43 + windowlist.AbsoluteContentSize.Y / vape.guiscale.Scale, 603))
		end)
		textbutton.MouseButton1Click:Connect(function()
			optionapi:AddHotbar()
		end)
		optionapi.Window = CreateWindow(optionapi)
	
		function optionapi:Save(savetab)
			local hotbars = {}
			for _, v in self.Hotbars do
				table.insert(hotbars, v.Hotbar)
			end
			savetab.HotbarList = {
				Selected = self.Selected,
				Hotbars = hotbars
			}
		end
	
		function optionapi:Load(savetab)
			for _, v in self.Hotbars do
				v.Object:ClearAllChildren()
				v.Object:Destroy()
				table.clear(v.Hotbar)
			end
			table.clear(self.Hotbars)
			--[[ `or {}`: a profile written before HotbarList worked has no hotbar array,
			and indexing nil here would take the whole profile load down with it. ]]
			for _, v in savetab.Hotbars or {} do
				self:AddHotbar(v)
			end
			self.Selected = savetab.Selected or 1
		end
	
		function optionapi:AddHotbar(data)
			local hotbardata = {Hotbar = data or {}}
			table.insert(self.Hotbars, hotbardata)
			local hotbar = Instance.new('TextButton')
			hotbar.Size = UDim2.fromOffset(200, 27)
			hotbar.BackgroundColor3 = table.find(self.Hotbars, hotbardata) == self.Selected and color.Light(uipallet.Main, 0.034) or uipallet.Main
			hotbar.Text = ''
			hotbar.AutoButtonColor = false
			hotbar.Parent = childrenlist
			hotbardata.Object = hotbar
			local hotbarcorner = Instance.new('UICorner')
			hotbarcorner.CornerRadius = UDim.new(0, 4)
			hotbarcorner.Parent = hotbar
			for i = 1, 9 do
				local slot = Instance.new('ImageLabel')
				slot.Name = 'Slot'..i
				slot.Size = UDim2.fromOffset(17, 18)
				slot.Position = UDim2.fromOffset(-7 + (i * 18), 5)
				slot.BackgroundColor3 = color.Dark(uipallet.Main, 0.02)
				slot.Image = hotbardata.Hotbar[tostring(i)] and bedwars.getIcon({itemType = hotbardata.Hotbar[tostring(i)]}, true) or ''
				slot.BorderSizePixel = 0
				slot.Parent = hotbar
			end
			hotbar.MouseButton1Click:Connect(function()
				local ind = table.find(optionapi.Hotbars, hotbardata)
				if ind == optionapi.Selected then
					vape.gui.ScaledGui.ClickGui.Visible = false
					optionapi.Window.Visible = true
					for i = 1, 9 do
						optionapi.Window['Slot'..i].ImageLabel.Image = hotbardata.Hotbar[tostring(i)] and bedwars.getIcon({itemType = hotbardata.Hotbar[tostring(i)]}, true) or ''
					end
				else
					if optionapi.Hotbars[optionapi.Selected] then
						optionapi.Hotbars[optionapi.Selected].Object.BackgroundColor3 = uipallet.Main
					end
					hotbar.BackgroundColor3 = color.Light(uipallet.Main, 0.034)
					optionapi.Selected = ind
				end
			end)
			local close = Instance.new('ImageButton')
			close.Name = 'Close'
			close.Size = UDim2.fromOffset(16, 16)
			close.Position = UDim2.new(1, -23, 0, 6)
			close.BackgroundColor3 = Color3.new(1, 1, 1)
			close.BackgroundTransparency = 1
			close.Image = getcustomasset('pistonware/assets/new/closemini.png')
			close.ImageColor3 = color.Light(uipallet.Text, 0.2)
			close.ImageTransparency = 0.5
			close.AutoButtonColor = false
			close.Parent = hotbar
			local closecorner = Instance.new('UICorner')
			closecorner.CornerRadius = UDim.new(1, 0)
			closecorner.Parent = close
			close.MouseEnter:Connect(function()
				close.ImageTransparency = 0.3
				tween:Tween(close, TweenInfo.new(0.2), {
					BackgroundTransparency = 0.6
				})
			end)
			close.MouseLeave:Connect(function()
				close.ImageTransparency = 0.5
				tween:Tween(close, TweenInfo.new(0.2), {
					BackgroundTransparency = 1
				})
			end)
			close.MouseButton1Click:Connect(function()
				local ind = table.find(self.Hotbars, hotbardata)
				local obj = self.Hotbars[self.Selected]
				local obj2 = self.Hotbars[ind]
				if obj and obj2 then
					obj2.Object:ClearAllChildren()
					obj2.Object:Destroy()
					table.remove(self.Hotbars, ind)
					ind = table.find(self.Hotbars, obj)
					self.Selected = table.find(self.Hotbars, obj) or 1
				end
			end)
		end
	
		api.Options.HotbarList = optionapi
	
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
	
	local function findItemInTable(tab, item)
		for slot, v in tab do
			if item.itemType == getCustomItem(v) then
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
		vapeEvents.InventoryChanged.Event:Wait()
	end
	
	local function sortCallback()
		if Active then return end
		Active = true
		local items = (List.Hotbars[List.Selected] and List.Hotbars[List.Selected].Hotbar or {})
	
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
			elseif Clear.Enabled then
				local newslot = findInHotbar(v)
				if newslot then
				   	dispatch({
						type = 'InventoryRemoveFromHotbar',
						slot = newslot
					})
				end
			end
		end
	
		Active = false
	end
	
	AutoHotbar = vape.Categories.Inventory:CreateModule({
		Name = 'AutoHotbar',
		Function = function(callback)
			if callback then
				task.spawn(sortCallback)
				if Mode.Value == 'On Key' then
					AutoHotbar:Toggle()
					return
				end
	
				AutoHotbar:Clean(vapeEvents.InventoryAmountChanged.Event:Connect(sortCallback))
			end
		end,
		Tooltip = 'Sorts your hotbar the way you want it.'
	})
	Mode = AutoHotbar:CreateDropdown({
		Name = 'Activation',
		List = {'Toggle', 'On Key'},
		Function = function()
			if AutoHotbar.Enabled then
				AutoHotbar:Toggle()
				AutoHotbar:Toggle()
			end
		end
	})
	Clear = AutoHotbar:CreateToggle({Name = 'Clear Hotbar'})
	List = AutoHotbar:CreateHotbarList({})
end)
	
run(function()
	local Value
	local oldclickhold, oldshowprogress
	
	local FastConsume = vape.Categories.Inventory:CreateModule({
		Name = 'FastConsume',
		Function = function(callback)
			if callback then
				oldclickhold = bedwars.ClickHold.startClick
				oldshowprogress = bedwars.ClickHold.showProgress
				bedwars.ClickHold.startClick = function(self)
					self.startedClickTime = os.clock()
					local handle = self:showProgress()
					local clicktime = self.startedClickTime
					bedwars.RuntimeLib.Promise.defer(function()
						task.wait(self.durationSeconds * (Value.Value / 40))
						if handle == self.handle and clicktime == self.startedClickTime and self.closeOnComplete then
							self:hideProgress()
							if self.onComplete then self.onComplete() end
							if self.onPartialComplete then self.onPartialComplete(1) end
							self.startedClickTime = -1
						end
					end)
				end
	
				bedwars.ClickHold.showProgress = function(self)
					local roact = debug.getupvalue(oldshowprogress, 1)
					local countdown = roact.mount(roact.createElement('ScreenGui', {}, { roact.createElement('Frame', {
						[roact.Ref] = self.wrapperRef,
						Size = UDim2.new(),
						Position = UDim2.fromScale(0.5, 0.55),
						AnchorPoint = Vector2.new(0.5, 0),
						BackgroundColor3 = Color3.fromRGB(0, 0, 0),
						BackgroundTransparency = 0.8
					}, { roact.createElement('Frame', {
						[roact.Ref] = self.progressRef,
						Size = UDim2.fromScale(0, 1),
						BackgroundColor3 = Color3.new(1, 1, 1),
						BackgroundTransparency = 0.5
					}) }) }), lplr:FindFirstChild('PlayerGui'))
	
					self.handle = countdown
					local sizetween = tweenService:Create(self.wrapperRef:getValue(), TweenInfo.new(0.1), {
						Size = UDim2.fromScale(0.11, 0.005)
					})
					local countdowntween = tweenService:Create(self.progressRef:getValue(), TweenInfo.new(self.durationSeconds * (Value.Value / 100), Enum.EasingStyle.Linear), {
						Size = UDim2.fromScale(1, 1)
					})
	
					sizetween:Play()
					countdowntween:Play()
					table.insert(self.tweens, countdowntween)
					table.insert(self.tweens, sizetween)
					
					return countdown
				end
			else
				bedwars.ClickHold.startClick = oldclickhold
				bedwars.ClickHold.showProgress = oldshowprogress
				oldclickhold = nil
				oldshowprogress = nil
			end
		end,
		Tooltip = 'Eats and uses items faster.'
	})
	Value = FastConsume:CreateSlider({
		Name = 'Multiplier',
		Min = 0,
		Max = 100
	})
end)
	
run(function()
	local FastDrop
	
	FastDrop = vape.Categories.Inventory:CreateModule({
		Name = 'FastDrop',
		Function = function(callback)
			if callback then
				repeat
					if entitylib.isAlive and (not store.inventory.opened) and (inputService:IsKeyDown(Enum.KeyCode.H) or inputService:IsKeyDown(Enum.KeyCode.Backspace)) and inputService:GetFocusedTextBox() == nil then
						task.spawn(bedwars.ItemDropController.dropItemInHand)
						task.wait(0.1)
					else
						task.wait(0.1)
					end
				until not FastDrop.Enabled
			end
		end,
		Tooltip = 'Dumps items quickly while you hold Q'
	})
end)
	
run(function()
	local BedBreakEffect
	local Mode
	local List
	local NameToId = {}
	
	BedBreakEffect = vape.Legit:CreateModule({
		Name = 'Bed Break Effect',
		Function = function(callback)
			if callback then
	            BedBreakEffect:Clean(vapeEvents.BedwarsBedBreak.Event:Connect(function(data)
	                firesignal(bedwars.Client:Get('BedBreakEffectTriggered').instance.OnClientEvent, {
	                    player = data.player,
	                    position = data.bedBlockPosition * 3,
	                    effectType = NameToId[List.Value],
	                    teamId = data.brokenBedTeam.id,
	                    centerBedPosition = data.bedBlockPosition * 3
	                })
	            end))
	        end
		end,
		Tooltip = 'Your own effect when a bed goes down'
	})
	local BreakEffectName = {}
	for i, v in bedwars.BedBreakEffectMeta do
		table.insert(BreakEffectName, v.name)
		NameToId[v.name] = i
	end
	table.sort(BreakEffectName)
	List = BedBreakEffect:CreateDropdown({
		Name = 'Effect',
		List = BreakEffectName
	})
end)
	
run(function()
	vape.Legit:CreateModule({
		Name = 'Clean Kit',
		Function = function(callback)
			if callback then
				bedwars.WindWalkerController.spawnOrb = function() end
				local zephyreffect = lplr.PlayerGui:FindFirstChild('WindWalkerEffect', true)
				if zephyreffect then 
					zephyreffect.Visible = false 
				end
			end
		end,
		Tooltip = 'Gets rid of the zephyr status indicator'
	})
end)
	
run(function()
	local old
	local Image
	
	local Crosshair = vape.Legit:CreateModule({
		Name = 'Crosshair',
		Function = function(callback)
			if callback then
				old = debug.getconstant(bedwars.ViewmodelController.showCrosshair, 25)
				debug.setconstant(bedwars.ViewmodelController.showCrosshair, 25, Image.Value)
				debug.setconstant(bedwars.ViewmodelController.showCrosshair, 37, Image.Value)
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
		Tooltip = 'Your own first person crosshair, whatever image you pick.'
	})
	Image = Crosshair:CreateTextBox({
		Name = 'Image',
		Placeholder = 'image id (roblox)',
		Function = function(enter)
			if enter and Crosshair.Enabled then
				Crosshair:Toggle()
				Crosshair:Toggle()
			end
		end
	})
end)
	
run(function()
	local DamageIndicator
	local FontOption
	local Color
	local Size
	local Anchor
	local Stroke
	local suc, tab = pcall(function()
		return debug.getupvalue(bedwars.DamageIndicator, 2)
	end)
	tab = suc and tab or {}
	local oldvalues, oldfont = {}
	
	DamageIndicator = vape.Legit:CreateModule({
		Name = 'Damage Indicator',
		Function = function(callback)
			if callback then
				oldvalues = table.clone(tab)
				oldfont = debug.getconstant(bedwars.DamageIndicator, 86)
				debug.setconstant(bedwars.DamageIndicator, 86, Enum.Font[FontOption.Value])
				debug.setconstant(bedwars.DamageIndicator, 119, Stroke.Enabled and 'Thickness' or 'Enabled')
				tab.strokeThickness = Stroke.Enabled and 1 or false
				tab.textSize = Size.Value
				tab.blowUpSize = Size.Value
				tab.blowUpDuration = 0
				tab.baseColor = Color3.fromHSV(Color.Hue, Color.Sat, Color.Value)
				tab.blowUpCompleteDuration = 0
				tab.anchoredDuration = Anchor.Value
			else
				for i, v in oldvalues do
					tab[i] = v
				end
				debug.setconstant(bedwars.DamageIndicator, 86, oldfont)
				debug.setconstant(bedwars.DamageIndicator, 119, 'Thickness')
			end
		end,
		Tooltip = 'Change how the damage indicator looks'
	})
	local fontitems = {'GothamBlack'}
	for _, v in Enum.Font:GetEnumItems() do
		if v.Name ~= 'GothamBlack' then
			table.insert(fontitems, v.Name)
		end
	end
	FontOption = DamageIndicator:CreateDropdown({
		Name = 'Font',
		List = fontitems,
		Function = function(val)
			if DamageIndicator.Enabled then
				debug.setconstant(bedwars.DamageIndicator, 86, Enum.Font[val])
			end
		end
	})
	Color = DamageIndicator:CreateColorSlider({
		Name = 'Color',
		DefaultHue = 0,
		Function = function(hue, sat, val)
			if DamageIndicator.Enabled then
				tab.baseColor = Color3.fromHSV(hue, sat, val)
			end
		end
	})
	Size = DamageIndicator:CreateSlider({
		Name = 'Size',
		Min = 1,
		Max = 32,
		Default = 32,
		Function = function(val)
			if DamageIndicator.Enabled then
				tab.textSize = val
				tab.blowUpSize = val
			end
		end
	})
	Anchor = DamageIndicator:CreateSlider({
		Name = 'Anchor',
		Min = 0,
		Max = 1,
		Decimal = 10,
		Function = function(val)
			if DamageIndicator.Enabled then
				tab.anchoredDuration = val
			end
		end
	})
	Stroke = DamageIndicator:CreateToggle({
		Name = 'Stroke',
		Function = function(callback)
			if DamageIndicator.Enabled then
				debug.setconstant(bedwars.DamageIndicator, 119, callback and 'Thickness' or 'Enabled')
				tab.strokeThickness = callback and 1 or false
			end
		end
	})
end)
	
run(function()
	local FOV
	local Value
	local old, old2
	
	FOV = vape.Legit:CreateModule({
		Name = 'FOV',
		Function = function(callback)
			if callback then
				old = bedwars.FovController.setFOV
				old2 = bedwars.FovController.getFOV
				bedwars.FovController.setFOV = function(self) 
					return old(self, Value.Value) 
				end
				bedwars.FovController.getFOV = function() 
					return Value.Value 
				end
			else
				bedwars.FovController.setFOV = old
				bedwars.FovController.getFOV = old2
			end
			
			bedwars.FovController:setFOV(bedwars.Store:getState().Settings.fov)
		end,
		Tooltip = 'Tweaks how far and wide the camera sees'
	})
	Value = FOV:CreateSlider({
		Name = 'FOV',
		Min = 30,
		Max = 120
	})
end)
	
run(function()
	local FPSBoost
	local Kill
	local Visualizer
	local Nametags
	local effects, util = {}, {}

	--[[ The game's own nametag builder, stashed the first time we stub it so disable can
	put it back. This is the ONLY thing that builds a character nametag -- the game
	turns Roblox's own Humanoid name display off (NameDisplayDistance = 0,
	DisplayDistanceType = None) and then calls this for every entity, players and
	mobs alike -- so stubbing it and never restoring it left the session with no
	nametags on anyone until a rejoin, whatever the module's knob said. ]]
	local oldAddGameNametag

	local function removeGameNametags()
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

	--[[ Puts the builder back and re-runs it over everything currently tagged as an
	entity, since the tags we closed above won't come back on their own until that
	character is re-tagged (i.e. respawns). addGameNametag bails on its own for
	anyone whose tag is already open, so this fills in the gaps without doubling
	anybody up, and it still honours NoNametag / shouldShowNametag. ]]
	local function restoreGameNametags()
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

	FPSBoost = vape.Legit:CreateModule({
		Name = 'FPS Boost',
		Function = function(callback)
			if callback then
				if Kill.Enabled then
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
	
				if Visualizer.Enabled then
					for i, v in bedwars.VisualizerUtils do
						util[i] = v
						bedwars.VisualizerUtils[i] = function() end
					end
				end
	
				if Nametags.Enabled then
					--[[ the module's own thread parks here in the lobby. It used to wait
					on matchState alone, so turning FPS Boost off before the match
					started still stubbed the nametags the moment it did -- hence the
					re-check on both flags after the wait. ]]
					repeat task.wait(0.1) until store.matchState ~= 0 or not (FPSBoost.Enabled and Nametags.Enabled)
					if FPSBoost.Enabled and Nametags.Enabled then
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
		Tooltip = 'Turns off some effects to get you more frames'
	})
	Kill = FPSBoost:CreateToggle({
		Name = 'Kill Effects',
		Function = function()
			if FPSBoost.Enabled then
				FPSBoost:Toggle()
				FPSBoost:Toggle()
			end
		end,
		Default = true
	})
	Visualizer = FPSBoost:CreateToggle({
		Name = 'Visualizer',
		Function = function()
			if FPSBoost.Enabled then
				FPSBoost:Toggle()
				FPSBoost:Toggle()
			end
		end,
		Default = true
	})
	--[[ Split out of the module body and defaulted off. It used to run unconditionally
	whenever FPS Boost was on, with no way to keep the framerate work and keep the
	nametags. Doesn't borrow Kill/Visualizer's re-toggle trick: that restarts the
	whole module, and the enable path parks on matchState for as long as the lobby
	lasts, so this drives its own state directly. ]]
	Nametags = FPSBoost:CreateToggle({
		Name = 'Hide Nametags',
		Function = function(callback)
			if not FPSBoost.Enabled then return end
			if callback then
				task.spawn(function()
					repeat task.wait(0.1) until store.matchState ~= 0 or not (FPSBoost.Enabled and Nametags.Enabled)
					if FPSBoost.Enabled and Nametags.Enabled then
						removeGameNametags()
					end
				end)
			else
				restoreGameNametags()
			end
		end,
		Tooltip = 'Hides the game nametag over everyone, teammates too.\nTurn it back off and they come back, no rejoin needed.'
	})
end)
	
run(function()
	local HitColor
	local Color
	--[[ weak keys so highlights destroyed mid-session don't sit in here until disable ]]
	local done = setmetatable({}, {__mode = 'k'})
	
	HitColor = vape.Legit:CreateModule({
		Name = 'Hit Color',
		Function = function(callback)
			if callback then
				repeat
					--[[ same colour for every entity this tick; compute once, not per-entity ]]
					local fill = Color3.fromHSV(Color.Hue, Color.Sat, Color.Value)
					local trans = Color.Opacity
					for _, v in entitylib.List do
						local highlight = v.Character and v.Character:FindFirstChild('_DamageHighlight_')
						if highlight then
							--[[ set, not array: the table.find here was a linear scan
							per entity per tick that only grew as highlights piled up ]]
							done[highlight] = true
							highlight.FillColor = fill
							highlight.FillTransparency = trans
						end
					end
					task.wait(0.1)
				until not HitColor.Enabled
			else
				for v in next, done do
					v.FillColor = Color3.new(1, 0, 0)
					v.FillTransparency = 0.4
				end
				table.clear(done)
			end
		end,
		Tooltip = 'Change how the hit highlight looks'
	})
	Color = HitColor:CreateColorSlider({
		Name = 'Color',
		DefaultOpacity = 0.4
	})
end)
	
run(function()
	vape.Legit:CreateModule({
		Name = 'HitFix',
		Function = function(callback)
			debug.setconstant(bedwars.SwordController.swingSwordAtMouse, 23, callback and 'raycast' or 'Raycast')
			debug.setupvalue(bedwars.SwordController.swingSwordAtMouse, 4, callback and bedwars.QueryUtil or workspace)
		end,
		Tooltip = 'Points raycasts at the right function'
	})
end)
	
run(function()
	local Interface
	local HotbarOpenInventory = require(lplr.PlayerScripts.TS.controllers.global.hotbar.ui['hotbar-open-inventory']).HotbarOpenInventory
	local HotbarHealthbar = require(lplr.PlayerScripts.TS.controllers.global.hotbar.ui.healthbar['hotbar-healthbar']).HotbarHealthbar
	local HotbarApp = getRoactRender(require(lplr.PlayerScripts.TS.controllers.global.hotbar.ui['hotbar-app']).HotbarApp.render)
	local old, new = {}, {}
	
	vape:Clean(function()
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
	
		if Interface.Enabled then
			if val then
				debug.setconstant(func, ind, val)
			else
				debug.setconstant(func, ind, old[func][ind])
				old[func][ind] = nil
			end
		end
	end
	
	Interface = vape.Legit:CreateModule({
		Name = 'Interface',
		Function = function(callback)
			for i, v in (callback and new or old) do
				for i2, v2 in v do
					debug.setconstant(i, i2, v2)
				end
			end
		end,
		Tooltip = 'Change how the bedwars UI looks'
	})
	local fontitems = {'LuckiestGuy'}
	for _, v in Enum.Font:GetEnumItems() do
		if v.Name ~= 'LuckiestGuy' then
			table.insert(fontitems, v.Name)
		end
	end
	Interface:CreateDropdown({
		Name = 'Health Font',
		List = fontitems,
		Function = function(val)
			modifyconstant(HotbarHealthbar.render, 77, val)
		end
	})
	Interface:CreateColorSlider({
		Name = 'Health Color',
		Function = function(hue, sat, val)
			modifyconstant(HotbarHealthbar.render, 16, tonumber(Color3.fromHSV(hue, sat, val):ToHex(), 16))
			if Interface.Enabled then
				local hotbar = lplr.PlayerGui:FindFirstChild('hotbar')
				hotbar = hotbar and hotbar:FindFirstChild('HealthbarProgressWrapper', true)
				if hotbar then
					hotbar['1'].BackgroundColor3 = Color3.fromHSV(hue, sat, val)
				end
			end
		end
	})
	Interface:CreateColorSlider({
		Name = 'Hotbar Color',
		DefaultOpacity = 0.8,
		Function = function(hue, sat, val, opacity)
			local func = oldinvrender or HotbarOpenInventory.render
			modifyconstant(debug.getupvalue(HotbarApp, 23).render, 51, tonumber(Color3.fromHSV(hue, sat, val):ToHex(), 16))
			modifyconstant(debug.getupvalue(HotbarApp, 23).render, 58, tonumber(Color3.fromHSV(hue, sat, math.clamp(val > 0.5 and val - 0.2 or val + 0.2, 0, 1)):ToHex(), 16))
			modifyconstant(debug.getupvalue(HotbarApp, 23).render, 54, 1 - opacity)
			modifyconstant(debug.getupvalue(HotbarApp, 23).render, 55, math.clamp(1.2 - opacity, 0, 1))
			modifyconstant(func, 31, tonumber(Color3.fromHSV(hue, sat, val):ToHex(), 16))
			modifyconstant(func, 32, math.clamp(1.2 - opacity, 0, 1))
			modifyconstant(func, 34, tonumber(Color3.fromHSV(hue, sat, math.clamp(val > 0.5 and val - 0.2 or val + 0.2, 0, 1)):ToHex(), 16))
		end
	})
end)
	
run(function()
	local KillEffect
	local Mode
	local List
	local NameToId = {}
	
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
	
	KillEffect = vape.Legit:CreateModule({
		Name = 'Kill Effect',
		Function = function(callback)
			if callback then
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
				KillEffect:Clean(lplr:GetAttributeChangedSignal('KillEffectType'):Connect(function()
					lplr:SetAttribute('KillEffectType', Mode.Value == 'Bedwars' and NameToId[List.Value] or 'Custom'..Mode.Value)
				end))
				lplr:SetAttribute('KillEffectType', Mode.Value == 'Bedwars' and NameToId[List.Value] or 'Custom'..Mode.Value)
			else
				for i in killeffects do
					bedwars.KillEffectController.killEffects['Custom'..i] = nil
				end
				lplr:SetAttribute('KillEffectType', 'default')
			end
		end,
		Tooltip = 'Your own effect on a final kill'
	})
	local modes = {'Bedwars'}
	for i in killeffects do
		table.insert(modes, i)
	end
	Mode = KillEffect:CreateDropdown({
		Name = 'Mode',
		List = modes,
		Function = function(val)
			List.Object.Visible = val == 'Bedwars'
			if KillEffect.Enabled then
				lplr:SetAttribute('KillEffectType', val == 'Bedwars' and NameToId[List.Value] or 'Custom'..val)
			end
		end
	})
	local KillEffectName = {}
	for i, v in bedwars.KillEffectMeta do
		table.insert(KillEffectName, v.name)
		NameToId[v.name] = i
	end
	table.sort(KillEffectName)
	List = KillEffect:CreateDropdown({
		Name = 'Bedwars',
		List = KillEffectName,
		Function = function(val)
			if KillEffect.Enabled then
				lplr:SetAttribute('KillEffectType', NameToId[val])
			end
		end,
		Darker = true
	})
end)
	
run(function()
	local ReachDisplay
	local label
	
	ReachDisplay = vape.Legit:CreateModule({
		Name = 'Reach Display',
		Function = function(callback)
			if callback then
				repeat
					label.Text = (store.attackReachUpdate > os.clock() and store.attackReach or '0.00')..' studs'
					task.wait(0.4)
				until not ReachDisplay.Enabled
			end
		end,
		Size = UDim2.fromOffset(100, 41)
	})
	ReachDisplay:CreateFont({
		Name = 'Font',
		Blacklist = 'Gotham',
		Function = function(val)
			label.FontFace = val
		end
	})
	ReachDisplay:CreateColorSlider({
		Name = 'Color',
		DefaultValue = 0,
		DefaultOpacity = 0.5,
		Function = function(hue, sat, val, opacity)
			label.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
			label.BackgroundTransparency = 1 - opacity
		end
	})
	label = Instance.new('TextLabel')
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 0.5
	label.TextSize = 15
	label.Font = Enum.Font.Gotham
	label.Text = '0.00 studs'
	label.TextColor3 = Color3.new(1, 1, 1)
	label.BackgroundColor3 = Color3.new()
	label.Parent = ReachDisplay.Children
	local corner = Instance.new('UICorner')
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = label
end)
	
run(function()
	local SongBeats
	local List
	local FOV
	local FOVValue = {}
	local Volume
	local alreadypicked = {}
	local beattick = os.clock()
	local oldfov, songobj, songbpm, songtween
	
	local function choosesong()
		local list = List.ListEnabled
		if #alreadypicked >= #list then 
			table.clear(alreadypicked) 
		end
	
		if #list <= 0 then
			notif('SongBeats', 'no songs', 10)
			SongBeats:Toggle()
			return
		end
	
		local chosensong = list[math.random(1, #list)]
		if #list > 1 and table.find(alreadypicked, chosensong) then
			repeat 
				task.wait(0.1) 
				chosensong = list[math.random(1, #list)] 
			until not table.find(alreadypicked, chosensong) or not SongBeats.Enabled
		end
		if not SongBeats.Enabled then return end
	
		local split = chosensong:split('/')
		if not isfile(split[1]) then
			notif('SongBeats', 'Missing song ('..split[1]..')', 10)
			SongBeats:Toggle()
			return
		end
	
		songobj.SoundId = assetfunction(split[1])
		repeat task.wait(0.1) until songobj.IsLoaded or not SongBeats.Enabled
		if SongBeats.Enabled then
			beattick = os.clock() + (tonumber(split[3]) or 0)
			songbpm = 60 / (tonumber(split[2]) or 50)
			songobj:Play()
		end
	end
	
	SongBeats = vape.Legit:CreateModule({
		Name = 'Song Beats',
		Function = function(callback)
			if callback then
				songobj = Instance.new('Sound')
				songobj.Volume = Volume.Value / 100
				songobj.Parent = workspace
				repeat
					if not songobj.Playing then choosesong() end
					if beattick < os.clock() and SongBeats.Enabled and FOV.Enabled then
						beattick = os.clock() + songbpm
						oldfov = math.min(bedwars.FovController:getFOV() * (bedwars.SprintController.sprinting and 1.1 or 1), 120)
						gameCamera.FieldOfView = oldfov - FOVValue.Value
						songtween = tweenService:Create(gameCamera, TweenInfo.new(math.min(songbpm, 0.2), Enum.EasingStyle.Linear), {FieldOfView = oldfov})
						songtween:Play()
					end
					task.wait(0.1)
				until not SongBeats.Enabled
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
		Tooltip = 'A little mp3 player built right in'
	})
	List = SongBeats:CreateTextList({
		Name = 'Songs',
		Placeholder = 'filepath/bpm/start'
	})
	FOV = SongBeats:CreateToggle({
		Name = 'Beat FOV',
		Function = function(callback)
			if FOVValue.Object then
				FOVValue.Object.Visible = callback
			end
			if SongBeats.Enabled then
				SongBeats:Toggle()
				SongBeats:Toggle()
			end
		end,
		Default = true
	})
	FOVValue = SongBeats:CreateSlider({
		Name = 'Adjustment',
		Min = 1,
		Max = 30,
		Default = 5,
		Darker = true
	})
	Volume = SongBeats:CreateSlider({
		Name = 'Volume',
		Function = function(val)
			if songobj then 
				songobj.Volume = val / 100 
			end
		end,
		Min = 1,
		Max = 100,
		Default = 100,
		Suffix = function(val) return '%' end
	})
end)

run(function()
	local SoundChanger
	local List
	local Volume
	local trackedSounds = {}
	local customSounds = {}
	local capturedRegistry = {}
	local old, oldRegister
	
	local function updateVolumes()
		local volMultiplier = (Volume and Volume.Value or 100) / 100
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

	SoundChanger = vape.Legit:CreateModule({
		Name = 'SoundChanger',
		Function = function(callback)
			if callback then
				old = bedwars.SoundManager.playSound
				bedwars.SoundManager.playSound = function(self, id, ...)
					local args = {...}
					local isTracked = trackedSounds[id]
					
					if isTracked then
						if customSounds[id] then
							id = customSounds[id]
						end
						
						local volMultiplier = (Volume and Volume.Value or 100) / 100
						
						for i, v in ipairs(args) do
							if type(v) == "table" then
								local newProps = {}
								for k, val in pairs(v) do newProps[k] = val end
								local baseVol = newProps.volume or newProps.Volume or 1
								newProps.volume = baseVol * volMultiplier
								newProps.Volume = newProps.volume
								args[i] = newProps
							end
						end
					end
					
					local result = old(self, id, table.unpack(args))
					
					if isTracked and result and typeof(result) == "Instance" and result:IsA("Sound") then
						local volMultiplier = (Volume and Volume.Value or 100) / 100
						result.Volume = result.Volume * volMultiplier
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
								local volMultiplier = (Volume and Volume.Value or 100) / 100
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

				updateVolumes()
			else
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
		Tooltip = 'Swap ingame sounds for your own and set how loud they are.'
	})
	
	List = SoundChanger:CreateTextList({
		Name = 'Sounds',
		Placeholder = '(EQUIP_DEFAULT or EQUIP_DEFAULT/custom.mp3)',
		Function = function()
			table.clear(trackedSounds)
			table.clear(customSounds)
			local soundTable = bedwars.SoundList or bedwars.GameSound or bedwars.Sounds or {}
			for _, entry in ipairs(List.ListEnabled) do
				local split = entry:split('/')
				local name = split[1]
				local id = soundTable[name]
				
				if id then
					trackedSounds[id] = true
					if #split > 1 and split[2] ~= "" then
						local path = split[2]
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
	
	Volume = SoundChanger:CreateSlider({
		Name = 'Volume',
		Min = 0,
		Max = 200,
		Default = 100,
		Suffix = function(val) return '%' end,
		Function = function()
			updateVolumes()
		end
	})
end)
	
run(function()
	local UICleanup
	local OpenInv
	local KillFeed
	local OldTabList
	local HotbarApp = getRoactRender(require(lplr.PlayerScripts.TS.controllers.global.hotbar.ui['hotbar-app']).HotbarApp.render)
	local HotbarOpenInventory = require(lplr.PlayerScripts.TS.controllers.global.hotbar.ui['hotbar-open-inventory']).HotbarOpenInventory
	local old, new = {}, {}
	local oldkillfeed
	
	vape:Clean(function()
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
		if UICleanup.Enabled then
			if val then
				debug.setconstant(func, ind, val)
			else
				debug.setconstant(func, ind, old[func][ind])
				old[func][ind] = nil
			end
		end
	end
	
	UICleanup = vape.Legit:CreateModule({
		Name = 'UI Cleanup',
		Function = function(callback)
			for i, v in (callback and new or old) do
				for i2, v2 in v do
					debug.setconstant(i, i2, v2)
				end
			end
			if callback then
				if OpenInv.Enabled then
					oldinvrender = HotbarOpenInventory.render
					HotbarOpenInventory.render = function()
						return bedwars.Roact.createElement('TextButton', {Visible = false}, {})
					end
				end
	
				if KillFeed.Enabled then
					oldkillfeed = bedwars.KillFeedController.addToKillFeed
					bedwars.KillFeedController.addToKillFeed = function() end
				end
	
				if OldTabList.Enabled then
					starterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, true)
				end
			else
				if oldinvrender then
					HotbarOpenInventory.render = oldinvrender
					oldinvrender = nil
				end
	
				if KillFeed.Enabled then
					bedwars.KillFeedController.addToKillFeed = oldkillfeed
					oldkillfeed = nil
				end
	
				if OldTabList.Enabled then
					starterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, false)
				end
			end
		end,
		Tooltip = 'Tidies up the kit and main menu UI'
	})
	UICleanup:CreateToggle({
		Name = 'Resize Health',
		Function = function(callback)
			modifyconstant(HotbarApp, 60, callback and 1 or nil)
			modifyconstant(debug.getupvalue(HotbarApp, 15).render, 30, callback and 1 or nil)
			modifyconstant(debug.getupvalue(HotbarApp, 23).tweenPosition, 16, callback and 0 or nil)
		end,
		Default = true
	})
	UICleanup:CreateToggle({
		Name = 'No Hotbar Numbers',
		Function = function(callback)
			local func = oldinvrender or HotbarOpenInventory.render
			modifyconstant(debug.getupvalue(HotbarApp, 23).render, 90, callback and 0 or nil)
			modifyconstant(func, 71, callback and 0 or nil)
		end,
		Default = true
	})
	OpenInv = UICleanup:CreateToggle({
		Name = 'No Inventory Button',
		Function = function(callback)
			modifyconstant(HotbarApp, 78, callback and 0 or nil)
			if UICleanup.Enabled then
				if callback then
					oldinvrender = HotbarOpenInventory.render
					HotbarOpenInventory.render = function()
						return bedwars.Roact.createElement('TextButton', {Visible = false}, {})
					end
				else
					HotbarOpenInventory.render = oldinvrender
					oldinvrender = nil
				end
			end
		end,
		Default = true
	})
	KillFeed = UICleanup:CreateToggle({
		Name = 'No Kill Feed',
		Function = function(callback)
			if UICleanup.Enabled then
				if callback then
					oldkillfeed = bedwars.KillFeedController.addToKillFeed
					bedwars.KillFeedController.addToKillFeed = function() end
				else
					bedwars.KillFeedController.addToKillFeed = oldkillfeed
					oldkillfeed = nil
				end
			end
		end,
		Default = true
	})
	OldTabList = UICleanup:CreateToggle({
		Name = 'Old Player List',
		Function = function(callback)
			if UICleanup.Enabled then
				starterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, callback)
			end
		end,
		Default = true
	})
	UICleanup:CreateToggle({
		Name = 'Fix Queue Card',
		Function = function(callback)
			modifyconstant(bedwars.QueueCard.render, 15, callback and 0.1 or nil)
		end,
		Default = true
	})
end)
	
run(function()
	local Viewmodel
	local Depth
	local Horizontal
	local Vertical
	local NoBob
	local Rots = {}
	local old, oldc1
	
	Viewmodel = vape.Legit:CreateModule({
		Name = 'Viewmodel',
		Function = function(callback)
			local viewmodel = gameCamera:FindFirstChild('Viewmodel')
			if callback then
				old = bedwars.ViewmodelController.playAnimation
				oldc1 = viewmodel and viewmodel.RightHand.RightWrist.C1 or CFrame.identity
				if NoBob.Enabled then
					bedwars.ViewmodelController.playAnimation = function(self, animtype, ...)
						if bedwars.AnimationType and animtype == bedwars.AnimationType.FP_WALK then return end
						return old(self, animtype, ...)
					end
				end
	
				bedwars.InventoryViewmodelController:handleStore(bedwars.Store:getState())
				if viewmodel then
					gameCamera.Viewmodel.RightHand.RightWrist.C1 = oldc1 * CFrame.Angles(math.rad(Rots[1].Value), math.rad(Rots[2].Value), math.rad(Rots[3].Value))
				end
				lplr.PlayerScripts.TS.controllers.global.viewmodel['viewmodel-controller']:SetAttribute('ConstantManager_DEPTH_OFFSET', -Depth.Value)
				lplr.PlayerScripts.TS.controllers.global.viewmodel['viewmodel-controller']:SetAttribute('ConstantManager_HORIZONTAL_OFFSET', Horizontal.Value)
				lplr.PlayerScripts.TS.controllers.global.viewmodel['viewmodel-controller']:SetAttribute('ConstantManager_VERTICAL_OFFSET', Vertical.Value)
			else
				bedwars.ViewmodelController.playAnimation = old
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
		Tooltip = 'Swaps out the viewmodel animations'
	})
	Depth = Viewmodel:CreateSlider({
		Name = 'Depth',
		Min = 0,
		Max = 2,
		Default = 0.8,
		Decimal = 10,
		Function = function(val)
			if Viewmodel.Enabled then
				lplr.PlayerScripts.TS.controllers.global.viewmodel['viewmodel-controller']:SetAttribute('ConstantManager_DEPTH_OFFSET', -val)
			end
		end
	})
	Horizontal = Viewmodel:CreateSlider({
		Name = 'Horizontal',
		Min = 0,
		Max = 2,
		Default = 0.8,
		Decimal = 10,
		Function = function(val)
			if Viewmodel.Enabled then
				lplr.PlayerScripts.TS.controllers.global.viewmodel['viewmodel-controller']:SetAttribute('ConstantManager_HORIZONTAL_OFFSET', val)
			end
		end
	})
	Vertical = Viewmodel:CreateSlider({
		Name = 'Vertical',
		Min = -0.2,
		Max = 2,
		Default = -0.2,
		Decimal = 10,
		Function = function(val)
			if Viewmodel.Enabled then
				lplr.PlayerScripts.TS.controllers.global.viewmodel['viewmodel-controller']:SetAttribute('ConstantManager_VERTICAL_OFFSET', val)
			end
		end
	})
	for _, name in {'Rotation X', 'Rotation Y', 'Rotation Z'} do
		table.insert(Rots, Viewmodel:CreateSlider({
			Name = name,
			Min = 0,
			Max = 360,
			Function = function(val)
				if Viewmodel.Enabled then
					gameCamera.Viewmodel.RightHand.RightWrist.C1 = oldc1 * CFrame.Angles(math.rad(Rots[1].Value), math.rad(Rots[2].Value), math.rad(Rots[3].Value))
				end
			end
		}))
	end
	NoBob = Viewmodel:CreateToggle({
		Name = 'No Bobbing',
		Default = true,
		Function = function()
			if Viewmodel.Enabled then
				Viewmodel:Toggle()
				Viewmodel:Toggle()
			end
		end
	})
end)
	
run(function()
	local WinEffect
	local List
	local NameToId = {}
	
	WinEffect = vape.Legit:CreateModule({
		Name = 'WinEffect',
		Function = function(callback)
			if callback then
				WinEffect:Clean(vapeEvents.MatchEndEvent.Event:Connect(function()
					for i, v in getconnections(bedwars.Client:Get('WinEffectTriggered').instance.OnClientEvent) do
						if v.Function then
							v.Function({
								winEffectType = NameToId[List.Value],
								winningPlayer = lplr
							})
						end
					end
				end))
			end
		end,
		Tooltip = 'Pick any win effect you want. Clientside only'
	})
	local WinEffectName = {}
	for i, v in bedwars.WinEffectMeta do
		table.insert(WinEffectName, v.name)
		NameToId[v.name] = i
	end
	table.sort(WinEffectName)
	List = WinEffect:CreateDropdown({
		Name = 'Effects',
		List = WinEffectName
	})

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
		Tooltip = 'Changes what device the server thinks youre on'
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
	local HideNametag
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

	HideNametag = vape.Categories.Utility:CreateModule({
		Name = 'HideNametag',
		Function = function(callback)
			if callback then
				setNametagEnabled(false)
				charConn = lplr.CharacterAdded:Connect(function(char)
					if HideNametag.Enabled then
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
		Tooltip = 'Hides the nametag over your own head'
	})
end)
end)

--[[ == bedwars module loader ==
Exposes shared.bedwars and loads the external obfuscatable module ]]

shared.bedwars = {
    --[[ Services ]]
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
	virtualInputManager = virtualInputManager,

    --[[ Framework ]]
    vape                = vape,
    vapeEvents          = vapeEvents,
    entitylib           = entitylib,
    targetinfo          = targetinfo,
    prediction          = prediction,
    color               = color,
    uipallet            = uipallet,

    --[[ Game state ]]
    lplr                = lplr,
    gameCamera          = gameCamera,
    bedwars             = bedwars,
    remotes             = remotes,
    store               = store,
    sides               = sides,
    AntiFallPart        = AntiFallPart,
    vapeConnections     = vapeConnections,
    RunLoops            = RunLoops,

    --[[ Utilities ]]
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
    addBlur             = addBlur,
    isnetworkowner      = isnetworkowner,
    getfontsize         = getfontsize,
    getcustomasset      = getcustomasset,
    cloneref            = cloneref,
    assetfunction       = assetfunction,
    oldSwing            = oldSwing,
    updateVelocity      = updateVelocity,
    _baseGetSpeed       = _baseGetSpeed,
    namecallGuard       = namecallGuard,
}

--[[ bedwars.lua is the ONLY file fetched from GitLab -- everything else comes from GitHub -- and
it sits at the REPO ROOT there (gitlab.com/pistonware/pistonware/bedwars.lua).

What lives at that URL is a ~220 byte REDIRECT to LuaArmor's loader endpoint, not the
protected build; LuaArmor hosts the build itself and serves the current one on every request,
which is what keeps security updates and Heartbeat live.

It is never written to disk and, outside developer mode, never read from disk. This is the
one file whose integrity the key system rests on, so it gets neither the caching nor the
commit tracking that every other file in the project has -- both turned out to be ways to get
a tampered local file executed in its place. See downloadBedwars for why the developer hatch
is the one exception and why it no longer costs anything.

The payload validates the global script_key server-side on execution. The loader's key gate
is what sets it; nothing here can substitute for it. ]]

--[[
    Fetches the payload redirect from GitLab. Outside developer mode it is NEVER cached and
    NEVER read from disk.

    This is the file protection depends on, and two conveniences that made sense everywhere else
    turned out to be bypasses here:

      * A cached copy whose recorded commit sha still matched was returned as-is. Editing the
        file did not change the sha, so a tampered cache survived every update check.
      * Honouring shared.PistonwareDeveloper returned the local file without making a request at
        all -- which, before the payload validated its own key, meant a dumped or rewritten
        bedwars.lua could run unkeyed forever.

    The cache is gone for good. The developer hatch is back, because the second problem was
    never really about where the source came from -- it was about the source not being checked.
    Now that it checks itself, see downloadBedwars.

    There is no offline fallback, on purpose: what lives on GitLab is a ~220 byte redirect to
    LuaArmor, and running it needs LuaArmor reachable anyway, so a cached copy could not have
    helped a genuinely offline user -- only someone who wanted a local file executed instead of
    the real one.

    Cheap, too: one small request, and dropping the cache also dropped the commit-check round
    trip that used to precede it.
]]
local function downloadBedwars()
    --[[ Developer mode runs the local file instead of fetching. This hatch was removed and is
    now back, and the reason it is safe this time is specific, so it is worth stating:

    It was removed because a local payload meant ZERO contact with LuaArmor. The published
    loader ships plaintext, so anyone could set the developer flag, drop any bedwars.lua at
    this path, and have pistonware execute it forever -- unkeyed, with no request that could
    ever notice.

    It is back because bedwars.lua now validates its own key (the session block at the top
    of it). The genuine source contacts LuaArmor whether it was loaded from disk or off the
    network, so loading it locally no longer grants an unkeyed session -- the file refuses by
    itself. What the hatch still helps is someone running a payload they have already dumped
    and stripped, and for them it is a convenience rather than a capability: anyone holding a
    working stripped payload has no need of this loader to run it.

    PUBLIC_BUILD nulls shared.PistonwareDeveloper and locks it behind a metatable, so this
    branch is unreachable from the published loader unless that loader is itself edited. ]]
    if shared.PistonwareDeveloper then
        local suc, res = pcall(function()
            if not isfile('pistonware/games/bedwars.lua') then return nil end
            return readfile('pistonware/games/bedwars.lua')
        end)
        if suc and res and res ~= '' and loadstring(res) ~= nil then
            warn('[pistonware] developer mode: running local games/bedwars.lua (not the published build)')
            return res
        end
        --[[ Falls through to the network rather than failing: a developer with no local copy, or
        one that does not compile, still wants a working script. ]]
        warn('[pistonware] developer mode: no usable local games/bedwars.lua -- using the published build')
    end

    for attempt = 1, 4 do
        local suc, res = pcall(function()
            return game:HttpGet('https://gitlab.com/pistonware/pistonware/-/raw/main/bedwars.lua', true)
        end)
        --[[ compile check: during an outage HttpGet can hand back the 503/error page as the body,
        which the ~=''/'404' tests would accept ]]
        if suc and res and res ~= '' and res ~= '404: Not Found' and loadstring(res) ~= nil then
            return res
        end
        if attempt < 4 then
            task.wait(attempt)
        end
    end

    --[[ Every attempt failed. Returns nil rather than falling back to a local copy: a local copy
    is precisely what must never be executed here, and there is nothing useful it could do
    anyway, since what it contains still needs LuaArmor reachable to run. ]]
    return nil
end

--[[ LuaArmor blanks the global script_key as soon as it has authenticated -- an anti-key-theft
measure, so another script running later in the same session cannot read it back out. That
makes the key single-use per session, and ANY second load of the payload (the GUI's Reinject
button, a re-run of this file, a manual execute after injecting) lands on 'No key found',
which does not merely fail: LuaArmor puts up a modal Auth Error with a Leave button and never
returns. Everything downstream of the call below is then stranded -- including main.lua's
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

local bedwarsSource = downloadBedwars()
if bedwarsSource then
    local bedwarsFn = loadstring(bedwarsSource)
    if bedwarsFn then
        --[[ Refuse to run the payload with no key rather than let it discover that itself: a
        LuaArmor auth failure is not a soft error, it puts up a modal and KICKS the player
        out of the game. Saying so here costs them their combat modules for the round instead
        of their session, and names the actual problem. ]]
        if not republishKey() then
            warn('[pistonware] no key available to hand bedwars.lua -- skipping it rather than risk a kick. Re-run the pistonware loader.')
            pcall(function()
                vape:CreateNotification('Vape', 'Your key was not available when combat modules tried to load, so they were skipped. Re-run the pistonware loader to fix this.', 30, 'alert')
            end)
            return
        end
        local ok, err = pcall(bedwarsFn)
        if not ok then
            warn('[pistonware] bedwars.lua errored while running: '..tostring(err))
        end
    else
        --[[ What came back does not compile. Nothing is cached now, so there is no stale file to
        delete and no state to repair -- the next run fetches again from scratch. Almost
        certainly the host served an error page that happened to pass the checks above. ]]
        warn('[pistonware] bedwars.lua did not compile -- the file host may be serving an error page')
        pcall(function()
            vape:CreateNotification('Vape', 'Combat modules could not be loaded (the file host returned something invalid). Rejoin the game to retry.', 30, 'alert')
        end)
    end
else
    --[[ Every attempt failed. Say so instead of silently loading without combat modules. ]]
    warn('[pistonware] bedwars.lua could not be downloaded -- the file host may be down')
    pcall(function()
        vape:CreateNotification('Vape', 'Could not download bedwars.lua -- the file host may be down. Combat modules are unavailable; rejoin the game to retry.', 30, 'alert')
    end)
end
