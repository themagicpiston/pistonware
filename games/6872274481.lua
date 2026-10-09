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

local function errorTrace(err)
	local traceback
	pcall(function()
		if debug and type(debug.traceback) == 'function' then
			traceback = debug.traceback(tostring(err), 2)
		end
	end)
	return traceback or tostring(err)
end

--[[ Every module in this file and in bedwars.lua is registered inside one of these -- 60 blocks
here, 59 there, all at top level, and bedwars.lua takes this same function through bw.run.
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
freeze on every inject and reinject. VapeSmoothBoot already yields between every block and
the whole file is written to survive that, so this is the same yield, taken only when the
frame is actually spent: a boot that fits in a frame is exactly as fast as before. ]]
local FRAME_BUDGET = 0.012
local lastBootYield = os.clock()
-- A reinject replaces shared.vape; the blocks of the boot it superseded then stop building.
local bootVape = shared.vape
local run = function(func)
	if shared.vape ~= bootVape then return end
	if shared.VapeSmoothBoot or os.clock() - lastBootYield > FRAME_BUDGET then
		task.wait()
		lastBootYield = os.clock()
	end
	local ok, err = callWithThreadFix(func)
	if not ok then
		bufferCall('error', 'bedwars.module', err, {traceback = err})
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
local pathfindingService = cloneref(game:GetService('PathfindingService'))
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

-- Is Pistonware's menu open: newgui's field (safe from any thread), the Instance only as fallback.
local function clickGuiOpen()
	local open = vape.ClickGuiOpen
	if open ~= nil then return open == true end
	if vape.ThreadFix then pcall(setthreadidentity, 8) end
	local ok, visible = pcall(function()
		return vape.gui.ScaledGui.ClickGui.Visible
	end)
	return ok and visible == true
end

local function priorityRank(entity, mode)
	local isPlayer = entity and entity.Player ~= nil
	if mode == 'NPCs first' then return isPlayer and 1 or 0 end
	return isPlayer and 0 or 1
end

local priorityTargetOutput = {}
local function priorityTarget(options, priority)
	if not priority or priority.Value == 'Closest' then
		return entitylib.EntityPosition(options)
	end
	options.Cache = true
	options.Output = options.Output or priorityTargetOutput
	local targets = entitylib.AllPosition(options)
	--[[ The first target of the best rank, in the order AllPosition returned them. That is
	exactly what the stable sort this replaces put at the front, without the sort, the order
	table and the comparator it allocated on every call -- AimAssist makes one per frame. ]]
	local mode = priority.Value
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

--[[ Every kit you are playing, not just the first.

Kit Fusion (combined_kit_to4) plays two at once. The game keeps them in the PlayingAsKits
attribute as "kit_a,kit_b" (KitController:getActiveKits), while Bedwars.kit -- what
store.equippedKit mirrors -- only ever holds the first (getPrimaryActiveKit). So every
`store.equippedKit == kit` check was blind to the second kit, and its AutoKit loop, AutoBuy
picks and kit modules never ran. hasKit is the game's own KitController:isUsingKit: any active
kit, or one granted on top of them as an ExtraKit_<kit> attribute. Both functions live on store
so every module reads the same answer. ]]
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
		-- The store has the kit before the attribute arrives (and after it is cleared).
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
local Reach = {}
local HitBoxes = {}
local InfiniteFly = {}
local TrapDisabler
-- Which trap reports TrapDisabler drops, keyed by the remote the trap's controller fires.
local TrapToggles = {}
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

--[[ The loader's look, for what this file draws on the HUD and in the world, as the TP Down bar
and the AutoBank box already are: the loader window's near-black with a tenth of its orange
through it, part see-through, a soft orange border and rounded corners. Text is the menu's Inter
in the loader's light grey, labels in its secondary grey. ]]
local loaderStyle = {
	Orange = Color3.fromRGB(240, 122, 31),
	Text = Color3.fromRGB(230, 230, 230),
	SubText = Color3.fromRGB(163, 161, 157),
	-- What a button or a slot sits on inside a box, and its border: the loader's own buttons.
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

-- Inter through the font registry, so the label follows it if it finishes loading late.
function loaderStyle.text(label, role, textColor)
	label.TextColor3 = textColor or loaderStyle.Text
	label.TextStrokeTransparency = 1
	local fonts = vape.Libraries.fonts
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

--[[ The nearest block with air above it, within `range` cells and under 60 studs.

This used to list every block in the whole cube first and only then look for the nearest,
which is a block store lookup for every cell: 41^3 of them at the range of 20 AutoPearl asks
with, twice per throw, in the one moment a hitch hurts most -- while you are falling.

It now walks outward from your own cell and never looks at a cell, row or slab that is
already further away than the best found so far, so the nearer the ground, the sooner the
search stops; with nothing in range at all it still never looks past 60 studs, which at
AutoPearl's range is half the cube. The answer is the one the full sweep gave: the nearest,
and on an exact tie the cell that comes first in x, then y, then z order, which is the cell
the sweep reached first. ]]
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

	-- Squared distance nothing can beat any more, with a little slack for float noise.
	local function limit()
		local bound = bestMag + 0.001
		return bound * bound
	end
	-- The least distance, along one axis, of a cell `step` cells from yours: your cell's
	-- centre is at most 1.5 studs from you.
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

local function getSpeed()
    --[[ Delegate to shared.bedwars.getSpeed if DamageBoost has wrapped it ]]
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
	sessioninfo = sessioninfo or vape.Libraries.sessioninfo
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
	vape.Libraries.sessioninfo = sessioninfo
	return sessioninfo
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
local function markInput(input)
	if input.UserInputType ~= Enum.UserInputType.MouseMovement or input.Delta.Magnitude > 0 then
		store.lastInput = tick()
	end
end
vape:Clean(inputService.InputBegan:Connect(markInput))
vape:Clean(inputService.InputChanged:Connect(markInput))

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

local function switchItem(tool, delayTime)
	delayTime = delayTime or 0.05
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

local function updateVelocity(force)
	-- next(), not a full count: the only question is whether anything is in there, and
	-- getTableSize walks every entry to answer it.
	local newState = next(frictionTable) ~= nil
	if frictionState ~= newState or force then
		if frictionConnection then
			frictionConnection:Disconnect()
		end
		if newState then
			--[[ Parts a previous character left behind. A respawn lands here with the module
			still on, and their entries used to stay until the last friction user turned off,
			holding every dead character of the match. They are put back the way the disable
			below would, then let go. Weak keys are no answer: an Instance's Lua handle can be
			collected while the part is still alive, which would drop a part we still owe a
			restore to. ]]
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
		-- Guarded: anything that has never taken damage has no attribute, and nil < nil
		-- throws inside table.sort -- which ends whatever loop was doing the sorting.
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
			--[[ BedWars keeps the team on an ATTRIBUTE, and it lands AFTER the entity does.
			The game's own controllers sit in `while Attribute == nil do task.wait(1) end`
			loops waiting for it, so every entity is necessarily built with the team still
			unknown and Targetable comes out wrong. This signal is what corrects them, and it
			is the only thing that does -- the library's own refresh watches the Team PROPERTY,
			which bedwars never sets.

			It used to correct them by REBUILDING, and all three ways it did that were wrong.

			refreshEntity removes from entitylib.List with a swap-remove, and this loop was
			iterating that same list: the entity swapped down into the slot just visited was
			skipped, so an arbitrary subset of players kept a stale Targetable -- a different
			subset every match, which is why Priority Only worked in some games and hid
			everybody in others.

			entitylib.start() tore down and rebuilt the entire library whenever the LOCAL
			player's team landed, which is a thing that happens every single match. start()
			re-registers only its three default connections, so the CollectionService hooks
			this file installs for drones, guardians and training dummies were disconnected
			and never came back: NPC tracking died the moment your own team arrived.

			And every rebuild replaces every entity table, orphaning whatever the modules had
			keyed to the old ones -- nametags included.

			None of that is needed. The team is the only thing that changed, so re-run the
			check in place and fire EntityUpdated, which is exactly what updateEntity does
			everywhere else in the library. It also keeps Friend/Target and the raycast filter
			in step, which the hand-rolled version above did not. ]]
			plr:GetAttributeChangedSignal('Team'):Connect(function()
				-- your own team flips everybody's standing; anyone else's flips only theirs
				if plr == lplr then
					for _, v in entitylib.List do
						entitylib.updateEntity(v, true)
					end
				else
					local ent = entitylib.getEntity(plr)
					if ent then
						entitylib.updateEntity(ent, true)
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

	--[[ Same thread-tracking rule as the library's own addEntity, for the same reason:
	a build that finishes without yielding -- which is every character that is already
	streamed in -- would otherwise leave a dead thread in EntityThreads, and the next
	removeEntity would throw on the cancel instead of firing EntityRemoved. ]]
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
					localForwarder = char.AttributeChanged:Connect(function(attr)
						vapeEvents.AttributeChanged:Fire(attr)
					end)
					table.insert(entitylib.Connections, localForwarder)
				else
					entity.Targetable = entitylib.targetCheck(entity)

					local function refreshHealth()
						entity.Health, entity.MaxHealth = entitylib.readHealth(char)
						entitylib.Events.EntityUpdated:Fire(entity)
					end

					for _, v in entitylib.getUpdateConnections(entity) do
						table.insert(entity.Connections, v:Connect(refreshHealth))
					end

					--[[ An NPC is built around a stand-in humanoid table (see above), so nothing
					here was ever listening to its real Humanoid -- and a dummy or monster that keeps
					its health there, rather than in the Health attribute players carry, never fired
					a single update: its nametag sat on the number it was built with. Watch the real
					one, including a Humanoid that is only parented after the entity is. ]]
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
					--[[ The build above can yield for seconds (the armor slots wait up to 5s each).
					A player who leaves -- or a character destroyed -- in that window was still added
					here, after removeEntity had already run and found nothing to remove, so the
					entity sat in the list for the rest of the server with a nametag nothing would
					ever take down. Drop the build instead. ]]
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
			-- PlayingAsKits is the attribute the game actually updates; the singular one is
			-- kept for anything still on the older form.
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
-- Registered for cleanup: every reinject used to leave its copy of this listener behind.
vape:Clean(lplr.CharacterAdded:Connect(function(c)
    c:WaitForChild("HumanoidRootPart", 5)
    ensureCharPrimaryPart(c)
end))

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
local namecallObservers = {}

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
local previousNamecallHook = shared.PistonwareNamecallHook
local oldNamecall = mt.__namecall
if previousNamecallHook and oldNamecall == previousNamecallHook and shared.PistonwareOldNamecall then
    oldNamecall = shared.PistonwareOldNamecall
end
shared.PistonwareOldNamecall = oldNamecall
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
mt.__namecall = namecallHook
shared.PistonwareNamecallHook = namecallHook
setreadonly(mt, true)

vape:Clean(function()
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

    vape:Clean(function()
        for i = #scopes, 1, -1 do
            scopes[i]:stop()
        end
        table.clear(scopes)
        cleanAssetScope = nil
        cleanAssetResult = nil
    end)
end

local RunLoops = {RenderStepTable = {}, StepTable = {}, HeartTable = {}}
local vapeConnections = {}

--[[ Nothing used to disconnect either table on uninject. A run loop left bound kept running
into the next injection, and bedwars.lua's vapeConnections (lplr attribute and death handlers)
gained another live copy every reinject. ]]
vape:Clean(function()
    for _, loops in {RunLoops.RenderStepTable, RunLoops.StepTable, RunLoops.HeartTable} do
        for name, connection in loops do
            pcall(function() connection:Disconnect() end)
            loops[name] = nil
        end
    end
    for index, connection in vapeConnections do
        pcall(function() connection:Disconnect() end)
        vapeConnections[index] = nil
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
local function resolveSoundManager()
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
if shared.VapeSmoothBoot then task.wait() end
local bootstrapOk, bootstrapError = callWithThreadFix(function()
	local Knit = require(
		replicatedStorage.rbxts_include.node_modules['@easy-games'].knit.src.Knit.KnitClient
	)
	assert(type(Knit) == 'table', 'KnitClient returned no controller table')
	local knitDeadline = os.clock() + 60
	assert(type(Knit.OnStart) == 'function', 'Knit.OnStart is unavailable')
	local knitStarted = false
	local knitStartError
	local startup = Knit.OnStart()
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
		if vape.Loaded == nil then
			stopObserving()
			error('Knit initialization canceled by unload', 0)
		end
		if knitStartError then
			stopObserving()
			error('Knit startup failed: '..knitStartError, 0)
		end
		local controllers = Knit.Controllers
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

	local BowConstantsTable
	for i = 1, 32 do
		local ok, value = pcall(debug.getupvalue, Knit.Controllers.ProjectileController.enableBeam, i)
		if not ok then break end
		if type(value) == 'table' and type(rawget(value, 'RelX')) == 'number' then
			BowConstantsTable = value
			break
		end
	end
	BowConstantsTable = BowConstantsTable or {
		BeamGrowthMultiplier = 0.08,
		CameraMultiplier = 10,
		RelX = 0.8,
		RelY = -0.6,
		RelZ = 0,
		YTargetOffset = 0.05
	}

	local Flamework = require(replicatedStorage['rbxts_include']['node_modules']['@flamework'].core.out).Flamework
	local InventoryUtil = require(replicatedStorage.TS.inventory['inventory-util']).InventoryUtil
	local Client = require(replicatedStorage.TS.remotes).default.Client
	local EffectUtil = require(replicatedStorage.TS.util.effect['effect-util']).EffectUtil
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
		BuilderUtil = require(replicatedStorage.TS.games.bedwars.kit.kits.builder['builder-util']).BuilderUtil,
		JuggernautUtil = require(replicatedStorage.TS.balance['juggernaut-balance-file']).JuggernautUtil,
		BlockBreaker = Knit.Controllers.BlockBreakController.blockBreaker,
		BlockController = require(replicatedStorage['rbxts_include']['node_modules']['@easy-games']['block-engine'].out).BlockEngine,
		BlockEngine = require(lplr.PlayerScripts.TS.lib['block-engine']['client-block-engine']).ClientBlockEngine,
		BlockPlacer = require(replicatedStorage['rbxts_include']['node_modules']['@easy-games']['block-engine'].out.client.placement['block-placer']).BlockPlacer,
		BowConstantsTable = BowConstantsTable,
		ClickHold = require(replicatedStorage['rbxts_include']['node_modules']['@easy-games']['game-core'].out.client.ui.lib.util['click-hold']).ClickHold,
		Client = Client,
		ClientSyncEvents = require(lplr.PlayerScripts.TS['client-sync-events']).ClientSyncEvents,
		ClientConstructor = require(replicatedStorage['rbxts_include']['node_modules']['@rbxts'].net.out.client),
		ClientDamageBlock = require(replicatedStorage['rbxts_include']['node_modules']['@easy-games']['block-engine'].out.shared.remotes).BlockEngineRemotes.Client,
		CombatConstant = require(replicatedStorage.TS.combat['combat-constant']).CombatConstant,
		DamageIndicator = Knit.Controllers.DamageIndicatorController.spawnDamageIndicator,
		DefaultKillEffect = require(lplr.PlayerScripts.TS.controllers.global.locker["kill-effect"].effects['default-kill-effect']),
		EffectUtil = EffectUtil,
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
		ItemMeta = require(replicatedStorage.TS.item['item-meta']).items,
		-- Wanted by SkinChanger. Paths taken from where the game's own controllers import
		-- them (armor-item-skin-util for the meta, battle-pass-rewards for the id table).
		ItemSkinType = require(replicatedStorage.TS.games.bedwars['item-skin']['item-skin-types']).ItemSkinType,
		BedwarsKitSkin = require(replicatedStorage.TS.games.bedwars['kit-skin']['bedwars-kit-skin']).BedwarsKitSkin,
		BedwarsKitSkinMeta = require(replicatedStorage.TS.games.bedwars['kit-skin']['bedwars-kit-skin-meta']).BedwarsKitSkinMeta,
		getItemSkinMeta = require(replicatedStorage.TS.games.bedwars['item-skin']['item-skin-meta']).getItemSkinMeta,
		KillEffectMeta = require(replicatedStorage.TS.locker['kill-effect']['kill-effect-meta']).KillEffectMeta,
		KillFeedController = Flamework.resolveDependency('client/controllers/game/kill-feed/kill-feed-controller@KillFeedController'),
		Knit = Knit,
		KnockbackUtil = require(replicatedStorage.TS.damage['knockback-util']).KnockbackUtil,
		-- Wanted by the ported kit modules, and by nothing else in this file yet. Paths taken
		-- from where the game's own controllers import them.
		AudioManager = require(replicatedStorage['rbxts_include']['node_modules']['@easy-games']['game-core'].out).AudioManager,
		BalanceFile = require(replicatedStorage.TS.balance['balance-file']).BalanceFile,
		FrostyGunMode = require(replicatedStorage.TS.games.bedwars.kit.kits['frosty-gun']['frosty-gun-util']).FrostyGunMode,
		SoulBrokerConstants = require(replicatedStorage.TS.games.bedwars.kit.kits['soul-broker']['soul-broker-constants']).SoulBrokerConstants,
		TaliyahUtil = require(replicatedStorage.TS.games.bedwars.kit.kits.taliyah['taliyah-util']).TaliyahUtil,
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
			rawset(self, ind, Knit.Controllers[ind])
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
		elseif TrapDisabler and TrapDisabler.Enabled and TrapToggles[remoteName] and TrapToggles[remoteName].Enabled then
			return {SendToServer = function() end}
		elseif remoteName == 'SwordSwingMiss' and vape.Modules and vape.Modules.NoClickDelay and vape.Modules.NoClickDelay.Enabled then
			return {SendToServer = function() end}
		elseif remoteName == remotes.EquipItem and shared.PistonwareDeveloper then
			-- Developer trace for equips that bypass switchItem. Every method is forwarded
			-- to the real object with the real self; only the three that send are logged,
			-- and a request switchItem has just logged is not logged twice.
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

	local function frontOf(worldpos)
		if not entitylib.isAlive then return worldpos, false, 0 end

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
		local first, cost = nil, 0
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
				--[[ Something unbreakable on the line, in front or behind the first block,
				means this line never clears, and naming its first block would only send the
				break at cover with no way past it. Hand the spot back unchanged, and say so:
				'nothing in the way' and 'no way through' arrive as the same spot otherwise,
				and the caller has to tell a clear shot from a sealed one. ]]
				if isProtectedBlock(block, cell * 3) then return worldpos, true, math.huge end
				first = first or cell * 3
				--[[ Guarded: this prices every block on the line now, not only blocks the
				path search reached, and a block with no health to read must cost something
				rather than throw out of the whole break. ]]
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

	bedwars.placeBlock = function(pos, item, animate)
		if not getItem(item) then return end

		store.blockPlacer.blockType = item
		local suppressed = animate == false and suppressPlaceAnimation()

		local ok, result = pcall(function()
			return store.blockPlacer:placeBlock(bedwars.BlockController:getBlockPosition(pos))
		end)
		-- Inside the pcall's shadow on purpose: an error thrown by placeBlock must still
		-- decrement, or the depth never returns to zero and the stub stays for good.
		if suppressed then restorePlaceAnimation() end
		if not ok then error(result, 0) end
		return result
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
	of the block, and the 30-stud guard below then aborts the break outright.
	pin: a table the caller keeps from one call to the next. The cell a hit lands on is
	  remembered in it and struck again next call while it still stands, can still be hit
	  and the block asked for has not come open itself, so the hits go into one block until
	  it comes out. nil picks afresh each call as before.
	Returns pos, path, target when effects is set, and a fourth value, true, whenever a hit
	  was actually sent, so a caller can tell a swing from a call that found nothing to hit. ]]
	bedwars.breakBlock = function(block, effects, anim, customHealthbar, blockcheck, method, autotool, pin)
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
				--[[ With Block Check on, a candidate that can be struck directly beats one that
				would be redirected onto something in front of it -- so a bed with one clear
				cell is hit there rather than through the ore or wall beside the other. ]]
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

		--[[ Finish what was started. With Block Check the spot is often out of sight, and what
		gets hit is whatever stands in front of it -- which changes with every bob of the head
		and every step, so the hits got spread over the blocks round a hole with none of them
		coming out. So the block last struck stays the target while it is still there, nothing
		protects it, it is in reach, it can be hit directly, and it is still in the way of the
		spot, give or take a stud for the head moving. A spot that can be hit directly is taken
		over it: those hits are never wasted, the spot is on the way in. So is a spot that has
		moved off it altogether -- a cheaper way in through a hole just made, you walking round
		to another side. The block asked for coming open ends it too. ]]
		local pinned = false
		if pin then
			if pin.block == block and pin.cell and pos and not (open and direct) then
				local spot = pin.cell * 3
				local part = getPlacedBlock(spot)
				if part and part == pin.part and not isProtectedBlock(part, spot)
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
		if blockcheck and pos and not pinned then
			local front, sealed = clearShot(pos)
			--[[ Something that must not be broken -- our own bed, a NoBreak block -- stands in
			every line. There is no shot, and hitting the spot anyway is swinging through it. ]]
			if sealed then return end
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
			if isProtectedBlock(dblock, dpos * 3) then return end

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

			if pin then
				pin.block, pin.cell, pin.part = block, dpos, dblock
			end

			bedwars.ClientDamageBlock:Get('DamageBlock'):CallServerAsync({
				blockRef = {blockPosition = dpos},
				hitPosition = pos,
				hitNormal = Vector3.FromNormalId(Enum.NormalId.Top)
			}):andThen(function(result)
				-- The answer can land after a reinject tore this session down (bedwars emptied).
				if vape.Loaded == nil or not bedwars.BlockController then return end
				if result then
					--[[ The server would not take a hit there: stop coming back to it. ]]
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
				--[[ newinv, not new.Inventory.observedInventory: that is nil in exactly the case
				newinv falls back for, and an item with no meta entry reads as no tool type
				rather than an error. Either one thrown here aborted the store's change
				dispatch, so the game's own listeners still waiting their turn missed that
				update. ]]
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

			--[[ Defer the event fan-out to end-of-frame so multiple dispatches in the
			same frame coalesce into a single notification to each listener. ]]
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
			vape:Clean(handInv:GetPropertyChangedSignal('Value'):Connect(function()
				local tool = handInv.Value
				print(string.format('[pistonware equip] t=%.3f hand changed -> %s',
					os.clock(), tool and tool.Name or 'nothing'))
			end))
		end
		if lplr.Character then task.spawn(watchHand, lplr.Character) end
		vape:Clean(lplr.CharacterAdded:Connect(watchHand))
	end
	updateStore(bedwars.Store:getState(), {})
	
	for _, event in {'MatchEndEvent', 'EntityDeathEvent', 'BedwarsBedBreak', 'BalloonPopped', 'AngelProgress', 'GrapplingHookFunctions'} do
		if not vape.Connections then return end
		bedwars.Client:WaitFor(event):andThen(function(connection)
			vape:Clean(connection:Connect(function(...)
				vapeEvents[event]:Fire(...)
			end))
		end)
	end
	
	-- Named rather than picked out with select, which walks the arguments again for every field.
	vape:Clean(bedwars.ZapNetworking.EntityDamageEventZap.On(function(entityInstance, damage, damageType, fromPosition, fromEntity, knockbackMultiplier, knockbackId, attackData, ...)
		vapeEvents.EntityDamageEvent:Fire({
			entityInstance = entityInstance,
			damage = damage,
			damageType = damageType,
			fromPosition = fromPosition,
			fromEntity = fromEntity,
			knockbackMultiplier = knockbackMultiplier,
			knockbackId = knockbackId,
			attackData = attackData,
			-- the 13th argument: the eight named above, then four this does not use
			disableDamageHighlight = select(5, ...)
		})
	end))

	-- Keep confirmed Killaura telemetry at the normalized damage-event seam. The
	-- universal overlay can be enabled before this adapter finishes loading, so it
	-- must not depend on discovering this event from its own callback.
	vape:Clean(vapeEvents.EntityDamageEvent.Event:Connect(function(damageTable)
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

	--[[ optimized ZapNetworking hook ]]
	vape:Clean(bedwars.ZapNetworking.ProjectileLaunchZap.On(function(origin, projectileType, tool, shooter)
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
				--[[ only search nearby objects, not entire workspace ]]
				for _, obj in ipairs(workspace:GetChildren()) do
					if isTrackedProjectile(obj.Name) then
						local root = obj:FindFirstChildWhichIsA("BasePart")
						if root and (root.Position - origin).Magnitude < 25 then
							vapeEvents.ProjectileFired:Fire({
								origin = origin,
								projectile = obj,
								tool = tool,
								shooter = shooter,
								launchedAt = launchedAt,
								shooterPosition = shooterPosition,
								shooterVelocity = shooterVelocity
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
						shooter = lplr.Character,
						launchedAt = os.clock(),
						shooterPosition = root.Position,
						shooterVelocity = root.AssemblyLinearVelocity,
						fallback = true
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
	--[[ Every block in the map, which is tens of thousands of entries once one has loaded. The
	default removal is a table.find plus a shifting table.remove -- a walk of the whole list for
	each block that breaks, so one explosion taking out fifty blocks paid for fifty of them in a
	single frame. Each block's slot is kept alongside instead and a removal swaps the last entry
	into it. Everything that reads store.blocks only iterates it; none of it relies on the order.
	The same index also keeps a block from being listed twice. ]]
	local blockSlots = {}
	store.blocks = collection('block', vape, function(tab, obj)
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
	vape:Clean(function()
		table.clear(blockSlots)
	end)
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
		local deadline = os.clock() + 60
		local lastError = 'shop initialization has not completed'
		while vape.Loaded ~= nil do
			local oldIdentity
			local shop
			local canSetIdentity = type(getthreadidentity) == 'function'
				and type(setthreadidentity) == 'function'
			local ok, err = xpcall(function()
				if canSetIdentity then
					oldIdentity = getthreadidentity()
					assert(type(oldIdentity) == 'number', 'thread identity is unavailable')
					setthreadidentity(2)
				else
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
					if vape.Loaded ~= nil then
						notif('AutoBuy', 'Shop initialization could not restore thread identity.', 10, 'alert')
					end
					return
				end
			end
			if vape.Loaded == nil then return end
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
		if vape.Loaded == nil then return end
		bufferCall('error', 'bedwars.shop.initialize', lastError)
		notif('AutoBuy', 'Shop initialization failed. Open the item shop and reinject; see the error log.', 10, 'alert')
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
if not bootstrapOk then
	bufferCall('error', 'bedwars.bootstrap', bootstrapError)
	return {
		PistonwareBootFailure = true,
		stage = 'bedwars.bootstrap',
		error = tostring(bootstrapError)
	}
end
end

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
	local TargetPriority
	local FirstPersonOnly
	local Projectiles
	local ProjectileRange
	local speedRoll, speedRollAt = 0, 0
	local projectileRay = RaycastParams.new()
	projectileRay.FilterType = Enum.RaycastFilterType.Exclude

	--[[ Aim Speed is a range: a value from it is held for a random 0.25-0.6s, then re-rolled.
	Rolled every frame it would average straight back to the middle of the range; held, the
	pull speeds up and eases off the way a hand does. ]]
	local function aimSpeed()
		local now = os.clock()
		if now >= speedRollAt then
			speedRoll = AimSpeed:GetRandomValue()
			speedRollAt = now + 0.25 + math.random() * 0.35
		end
		return speedRoll
	end

	--[[ What the held tool fires, if it is a launcher: its speed and drop from ProjectileMeta, for
	the ammo you actually carry (a bow fires the first of its ammoItemTypes you have). A
	self-fuelled launcher lists no ammo and fires its own projectileType. Telepearls are for
	moving yourself, not for hitting anyone, so they are left alone. ]]
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

	--[[ The direction to look for a shot that lands: where the target will be when the
	projectile gets there, with the drop allowed for (the same SolveTrajectory the other aim
	code uses, with the target's own fall and landing). SolveTrajectory returns origin plus the
	launch velocity, so this is that velocity's direction. The camera is turned to look ALONG
	it rather than through a point on it: a bow fires at what the crosshair is over, and that is
	usually well past the target, so it is the look direction that has to match. ]]
	local function projectileDirection(ent, projectile)
		local head = entitylib.character.Head
		local root = ent.RootPart
		if not (head and root and prediction) then return end
		local origin = head.Position
		projectileRay.FilterDescendantsInstances = {lplr.Character, gameCamera}
		local aim = prediction.SolveTrajectory(origin, projectile.Speed, projectile.Gravity, root.Position,
			root.Velocity, workspace.Gravity, ent.HipHeight, nil, projectileRay)
		local direction = aim and (aim - origin)
		if not direction or direction.Magnitude < 0.01 then return end
		return direction.Unit
	end

	--[[ The game's own test, from CameraPerspectiveController (decompile:
	camera-perspective-controller): perspective 0 is first person, and it is 0 whenever the
	camera sits within a stud of its focus. The controller re-caches it every render step, so
	its answer is read when it can be; the same formula stands in if it can't. ]]
	local function inFirstPerson()
		local ok, perspective = pcall(function()
			return bedwars.CameraPerspectiveController:getCameraPerspective()
		end)
		if ok and type(perspective) == 'number' then
			return perspective == 0
		end
		return (gameCamera.CFrame.Position - gameCamera.Focus.Position).Magnitude <= 1
	end

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

	-- range: set for projectiles, which reach well past Killaura, so its target is not used.
	local function findAimTarget(range)
		if KillauraTarget.Enabled and not range then return store.KillauraTarget end
		return priorityTarget({
			Range = range or Distance.Value,
			Part = 'RootPart',
			Wallcheck = Targets.Walls.Enabled,
			Players = Targets.Players.Enabled,
			NPCs = Targets.NPCs.Enabled,
			Sort = sortmethods[Sort.Value]
		}, TargetPriority)
	end

	AimAssist = vape.Categories.Combat:CreateModule({
		Name = 'AimAssist',
		ExtraText = function()
			if not AimSpeed then return nil end
			local low, high = AimSpeed.ValueMin, AimSpeed.ValueMax
			return low == high and tostring(low) or low..'-'..high
		end,
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
					if not entitylib.isAlive or (FirstPersonOnly.Enabled and not inFirstPerson()) then return end

					-- A sword, or with Projectiles on, anything that fires one. Click Aim means a
					-- recent swing for the sword and the attack button held (drawing) for a
					-- launcher; a phone has no held button to read, so it always counts there.
					local projectile
					if store.hand.toolType == 'sword' then
						if ClickAim.Enabled and (tick() - bedwars.SwordController.lastSwing) >= 0.4 then return end
					else
						projectile = Projectiles.Enabled and heldProjectile()
						if not projectile then return end
						if ClickAim.Enabled and not (inputService.TouchEnabled or inputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)) then return end
					end

					do
						local ent = findAimTarget(projectile and ProjectileRange.Value or nil)

						if ent then
							if isFalconDecoy(ent) then return end
							local delta = (ent.RootPart.Position - entitylib.character.RootPart.Position)
							local localfacing = entitylib.character.RootPart.CFrame.LookVector * Vector3.new(1, 0, 1)
							local angle = math.acos(localfacing:Dot((delta * Vector3.new(1, 0, 1)).Unit))
							if angle >= (math.rad(AngleSlider.Value) / 2) then return end
							local direction = projectile and projectileDirection(ent, projectile)
							if projectile and not direction then return end
							targetinfo.Targets[ent] = tick() + 1
							local aimspeed = aimSpeed() + (StrafeIncrease.Enabled and (inputService:IsKeyDown(Enum.KeyCode.A) or inputService:IsKeyDown(Enum.KeyCode.D)) and 10 or 0)
							--[[ Strip last frame's shake, aim from that, then hang this frame's
							off the result -- the shake sits OUTSIDE the aim lerp. Folded
							into the lerp target it was a low-pass away from invisible: at
							the default aim speed the camera closes only ~10% of the gap per
							frame, so anything re-rolled faster than a few Hz averaged out
							to almost nothing no matter what the slider said. Stripping it
							first is also what keeps the leftovers from compounding frame
							over frame into a slow wander. ]]
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
		Tooltip = 'Pulls your aim towards nearby enemies.\nWorks with swords, plus bows and launchers if turned on.'
	})
	AimAssist:CreateDivider({Text = 'Aim'})
	AimSpeed = AimAssist:CreateTwoSlider({
		Name = 'Aim Speed',
		DisplayName = 'Horizontal speed',
		Min = 1,
		Max = 20,
		DefaultMin = 6,
		DefaultMax = 6,
		Tooltip = 'How hard it pulls. Set a range and the pull varies within it.'
	})
	Shake = AimAssist:CreateSlider({
		Name = 'Shake',
		DisplayName = 'Randomization',
		Min = 0,
		Max = 100,
		Default = 0,
		Suffix = '%',
		Tooltip = 'Adds a bit of random wobble to your aim.\n0 is dead centre, 100 is a full 5 degrees off.'
	})
	AimAssist:CreateDivider({Text = 'Target'})
	local methods = {'Damage', 'Distance'}
	for i in sortmethods do
		if not table.find(methods, i) then
			table.insert(methods, i)
		end
	end
	Sort = AimAssist:CreateDropdown({
		Name = 'Target Mode',
		DisplayName = 'Sort by',
		List = methods
	})
	Distance = AimAssist:CreateSlider({
		Name = 'Distance',
		DisplayName = 'Range',
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
		DisplayName = 'FOV',
		Min = 1,
		Max = 360,
		Default = 70
	})
	AimAssist:CreateDivider({Text = 'Conditions'})
	ClickAim = AimAssist:CreateToggle({
		Name = 'Click Aim',
		DisplayName = 'Mouse pressed',
		Default = true
	})
	Targets = AimAssist:CreateTargets({
		Players = true,
		Walls = true
	})
	AimAssist:CreateDivider({Text = 'Extras'})
	TargetPriority = AimAssist:CreateDropdown({
		Name = 'Target Priority',
		List = {'Players first', 'NPCs first', 'Closest'},
		Default = 'Players first'
	})
	KillauraTarget = AimAssist:CreateToggle({
		Name = 'Use killaura target'
	})
	StrafeIncrease = AimAssist:CreateToggle({Name = 'Strafe increase'})
	FirstPersonOnly = AimAssist:CreateToggle({
		Name = 'First Person Only',
		Tooltip = 'Only pulls your aim while the camera is in first person'
	})
	Projectiles = AimAssist:CreateToggle({
		Name = 'Projectiles',
		Function = function(callback)
			if ProjectileRange then
				ProjectileRange.Object.Visible = callback
			end
		end,
		Tooltip = 'Also aims bows, crossbows and other launchers: ahead of a moving target\nand above it for the drop. With Click Aim, only while you are drawing.'
	})
	ProjectileRange = AimAssist:CreateSlider({
		Name = 'Projectile Range',
		Min = 10,
		Max = 150,
		Default = 80,
		Darker = true,
		Visible = false,
		Suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
end)
	
run(function()
	local old
	
	vape.Categories.Combat:CreateModule({
		Name = 'NoClickDelay',
		DisplayName = 'No Hit Delay',
		Function = function(callback)
			if callback then
				old = bedwars.SwordController.isClickingTooFast
				bedwars.SwordController.isClickingTooFast = function(self)
					self.lastSwing = tick()
					return false
				end
			else
				bedwars.SwordController.isClickingTooFast = old
			end
		end,
		Tooltip = 'Lets you swing your sword as fast as you click.'
	})
end)
	
run(function()
	local Value
	local PlaceBlocks
	local PlaceRange
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
			if PlaceBlocks and PlaceBlocks.Enabled and mode == 0 then
				options = copyOptions(options)
				options.range = PlaceRange and PlaceRange.Value or 18
			end
			return original(self, mode, options)
		end

		if pcall(function()
			selector.getMouseInfo = wrapper
		end) then
			patchedSelectors[selector] = {Original = original, Wrapper = wrapper}
		end
	end

	-- True once this placer has nothing left to patch: there is no placer, or its selector is done.
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

	--[[ The two placers the Heartbeat below last patched. A selector is made once, with the
	client manager its placer is built around, so while both placers are the same objects and
	both were fully patched there is nothing new to reach -- and the identity switch and the two
	selector lookups are skipped for that frame. A placer that could not be patched yet is
	retried every frame, as before. ]]
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
		-- restorePlaceReach forgot every selector, so the next start patches from scratch
		placersCovered = false
	end

	local function startPlaceReach()
		patchPlaceReach()
		if not placeReachConnection then
			placeReachConnection = runService.Heartbeat:Connect(function()
				if Reach.Enabled and PlaceBlocks and PlaceBlocks.Enabled then
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
			Reach:Clean(placeReachConnection)
		end
	end
	
	-- Air Hit Chance: while you are off the ground only this share of swings get the extra
	-- range. attackEntity re-checks the target against RAYCAST_SWORD_CHARACTER_DISTANCE
	-- (sword-controller), so a failed roll runs that one call against the original distance
	-- and an out-of-range hit is dropped. swingSwordAtMouse is left alone on purpose --
	-- other modules debug.setconstant it, which a wrapper would break.
	local AirChance
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
			local airChance = AirChance:GetRandomValue()
			if airChance < 100 and isAirborne() and airRand:NextNumber(0, 100) > airChance then
				bedwars.CombatConstant.RAYCAST_SWORD_CHARACTER_DISTANCE = originalSwordReach or 14.4
				local results = table.pack(pcall(original, self, ...))
				-- read the module state again rather than restoring a saved value, in case
				-- the call yielded and Reach was turned off or re-ranged in the meantime
				bedwars.CombatConstant.RAYCAST_SWORD_CHARACTER_DISTANCE = Reach.Enabled and Value.Value + 2 or originalSwordReach or 14.4
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

	Reach = vape.Categories.Combat:CreateModule({
		Name = 'Reach',
		ExtraText = function()
			return Value and tostring(Value.Value) or nil
		end,
		Function = function(callback)
			if callback then
				originalSwordReach = originalSwordReach or bedwars.CombatConstant.RAYCAST_SWORD_CHARACTER_DISTANCE
				bedwars.CombatConstant.RAYCAST_SWORD_CHARACTER_DISTANCE = Value.Value + 2
				hookAttackEntity()
				if PlaceBlocks and PlaceBlocks.Enabled then
					startPlaceReach()
				end
			else
				unhookAttackEntity()
				bedwars.CombatConstant.RAYCAST_SWORD_CHARACTER_DISTANCE = originalSwordReach or 14.4
				stopPlaceReach()
			end
		end,
		Tooltip = 'Lets you hit enemies from further away.\nCan also extend how far away you can place blocks.'
	})
	Value = Reach:CreateSlider({
		Name = 'Range',
		DisplayName = 'Distance',
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
	Reach:CreateDivider({Text = 'Extras'})
	AirChance = Reach:CreateTwoSlider({
		Name = 'Air Hit Chance',
		Min = 0,
		Max = 100,
		DefaultMin = 100,
		DefaultMax = 100,
		Tooltip = 'Percent of swings that get the extra range while you are in the air.\nEach swing rolls its chance from this range.'
	})
	PlaceBlocks = Reach:CreateToggle({
		Name = 'Place Blocks',
		Function = function(callback)
			if PlaceRange and PlaceRange.Object then
				PlaceRange.Object.Visible = callback
			end
			if callback and Reach.Enabled then
				startPlaceReach()
			else
				stopPlaceReach()
			end
		end,
		Tooltip = 'Extends the distance used when selecting a block to place'
	})
	PlaceRange = Reach:CreateSlider({
		Name = 'Place Range',
		Min = 18,
		-- The server refuses a placement past 60 studs.
		Max = 60,
		Default = 18,
		Visible = false,
		Darker = true,
		Function = function()
			if Reach.Enabled and PlaceBlocks and PlaceBlocks.Enabled then
				patchPlaceReach()
			end
		end,
		Suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
	--[[ Sync PlaceRange's visibility to the saved state of PlaceBlocks. This used to set
	PlaceBlocks.Object.Visible, which hid the Place Blocks toggle itself whenever it was off
	-- so the option was invisible in exactly the state you needed to see it in to turn it
	on, and place reach looked like it did not exist. PlaceRange is the row that should
	follow the toggle, and its Function only runs on a change, not at creation. ]]
	if PlaceRange.Object then
		PlaceRange.Object.Visible = PlaceBlocks.Enabled
	end
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
		Tooltip = 'Plays the Nightmare emote until you move.'
	})

	vape:Clean(function() stopEmote() end)
end)
	
run(function()
	local Sprint
	local old
	
	Sprint = vape.Categories.Combat:CreateModule({
		Name = 'Sprint',
		Tab = 'Move',
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
		Tooltip = 'Automatically sprints for you.'
	})
end)
	
run(function()
	local TriggerBot
	local CPS
	local SelfAFK
	local rayParams = RaycastParams.new()

	TriggerBot = vape.Categories.Combat:CreateModule({
		Name = 'TriggerBot',
		ExtraText = function()
			if not CPS then return nil end
			local low, high = CPS.ValueMin, CPS.ValueMax
			return (low == high and tostring(low) or low..'-'..high)..' cps'
		end,
		Function = function(callback)
			if callback then
				repeat
					local doAttack
					if not bedwars.AppController:isLayerOpen(bedwars.UILayers.MAIN) and not (SelfAFK.Enabled and isLocalAfk()) then
						if entitylib.isAlive and store.hand.toolType == 'sword' and bedwars.DaoController.chargingMaid == nil then
							-- Guarded: no tool instance in hand, or a tool name the item meta has
							-- no sword entry for, threw here, and the throw ended the loop with the
							-- module still showing as on. The defaults below cover it instead.
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
	
					task.wait(doAttack and 1 / CPS.GetRandomValue() or 0.016)
				until not TriggerBot.Enabled
			end
		end,
		Tooltip = 'Swings your sword for you when an enemy is in reach.\nSet the click speed, and pause it while you are AFK.'
	})
	CPS = TriggerBot:CreateTwoSlider({
		Name = 'CPS',
		Min = 1,
		Max = 9,
		DefaultMin = 7,
		DefaultMax = 7
	})
	SelfAFK = TriggerBot:CreateToggle({
		Name = 'AFK check',
		Tooltip = 'Goes idle after 30 seconds without any mouse or keyboard input'
	})
end)
	
run(function()
	local Velocity
	local Horizontal
	local Vertical
	local Chance
	local TargetCheck
	local AFKCheck
	local rand, old = Random.new()

	Velocity = vape.Categories.Combat:CreateModule({
		Name = 'Velocity',
		ExtraText = function()
			if not (Horizontal and Vertical) then return nil end
			return Horizontal.Value..'% '..Vertical.Value..'%'
		end,
		Function = function(callback)
			if callback then
				old = bedwars.KnockbackUtil.applyKnockback
				bedwars.KnockbackUtil.applyKnockback = function(root, mass, dir, knockback, ...)
					-- A failed Chance roll (or being AFK) leaves this hit alone. This used to
					-- `return` here, which skipped applyKnockback altogether -- so every
					-- missed roll took off ALL of the knockback instead of none of it.
					if rand:NextNumber(0, 100) > Chance:GetRandomValue() or (AFKCheck.Enabled and isLocalAfk()) then
						return old(root, mass, dir, knockback, ...)
					end
					local check = (not TargetCheck.Enabled) or entitylib.EntityPosition({
						Range = 50,
						Part = 'RootPart',
						Players = true
					})

					if check then
						if Horizontal.Value == 0 and Vertical.Value == 0 then return end
						-- scale a copy: the table is the one EntityDamageEvent handed the
						-- knockback-controller, and writing into it (or erroring on it) is
						-- what can drop the whole hit
						local scaled = knockback and table.clone(knockback) or {}
						scaled.horizontal = (scaled.horizontal or 1) * (Horizontal.Value / 100)
						scaled.vertical = (scaled.vertical or 1) * (Vertical.Value / 100)
						knockback = scaled
					end
					
					return old(root, mass, dir, knockback, ...)
				end
			else
				bedwars.KnockbackUtil.applyKnockback = old
			end
		end,
		Tooltip = 'Reduces the amount of knockback you take.'
	})
	Chance = Velocity:CreateTwoSlider({
		Name = 'Chance',
		Min = 0,
		Max = 100,
		DefaultMin = 100,
		DefaultMax = 100,
		Tooltip = 'Percent of hits whose knockback gets reduced. Each hit rolls its chance from this range.'
	})
	Horizontal = Velocity:CreateSlider({
		Name = 'Horizontal',
		DisplayName = 'Reduce to',
		Min = 0,
		Max = 100,
		Default = 0,
		Suffix = function(val) return '%' end
	})
	Velocity:CreateDivider({Text = 'Extras'})
	Vertical = Velocity:CreateSlider({
		Name = 'Vertical',
		Min = 0,
		Max = 100,
		Default = 0,
		Suffix = function(val) return '%' end
	})
	TargetCheck = Velocity:CreateToggle({Name = 'Only when targeting'})
	AFKCheck = Velocity:CreateToggle({
		Name = 'AFK check',
		Tooltip = 'Takes full knockback once you have not touched your mouse or keyboard for 30 seconds'
	})
end)

--[[
run(function()
	local NoFall
	local groundHitConnection
	local groundHitSent = false

	local function findGroundBlock(root, humanoid)
		local position = root.Position - Vector3.new(0, root.Size.Y / 2 + humanoid.HipHeight + 0.75, 0)
		for _ = 1, 5 do
			local block = getPlacedBlock(position)
			if block then return block end
			position -= Vector3.new(0, 3, 0)
		end
	end

	local function stopGroundHit()
		if groundHitConnection then
			pcall(function() groundHitConnection:Disconnect() end)
			groundHitConnection = nil
		end
		groundHitSent = false
	end

	NoFall = vape.Categories.Blatant:CreateModule({
		Name = 'NoFall',
		Function = function(callback)
			if not callback then
				stopGroundHit()
				return
			end

			if groundHitConnection then return end
			groundHitConnection = runService.PreSimulation:Connect(function()
				if not entitylib.isAlive then
					groundHitSent = false
					return
				end

				local character = entitylib.character
				local root = character.RootPart
				local humanoid = character.Humanoid
				if not root or not humanoid then return end

				if humanoid.FloorMaterial ~= Enum.Material.Air then
					groundHitSent = false
					return
				end

				if not groundHitSent and root.AssemblyLinearVelocity.Y < -35 then
					groundHitSent = true
					pcall(function()
						local remote = bedwars.Client:Get('GroundHit')
						remote:SendToServer(
							findGroundBlock(root, humanoid),
							Vector3.new(0, 2.5, 0),
							workspace:GetServerTimeNow()
						)
					end)
				end
			end)
			NoFall:Clean(groundHitConnection)
		end,
		Tooltip = 'Prevents you from taking fall damage.'
	})
end)
]]

local AntiFallDirection
run(function()
	local AntiFall
	local Mode
	local Material
	local Color
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

	AntiFall = vape.Categories.Blatant:CreateModule({
		Name = 'AntiFall',
		ExtraText = function()
			return Mode and Mode.Value or nil
		end,
		Function = function(callback)
			if callback then
				repeat task.wait(0.1) until store.matchState ~= 0 or (not AntiFall.Enabled)
				if not AntiFall.Enabled then return end

				local ground, debounce = getLowGround(), os.clock()
				if ground ~= math.huge then
					AntiFallPart = Instance.new('Part')
					AntiFallPart.Size = Vector3.new(10000, 1, 10000)
					AntiFallPart.Transparency = 1 - Color.Opacity
					AntiFallPart.Material = Enum.Material[Material.Value]
					AntiFallPart.Color = Color3.fromHSV(Color.Hue, Color.Sat, Color.Value)
					AntiFallPart.Position = Vector3.new(0, ground - 2, 0)
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
									antiFallPriorityGeneration += 1
									setAutoWinAntiFallPriority(true)
									local lastTeleport = lplr:GetAttribute('LastTeleported')
									local connection
									connection = runService.PreSimulation:Connect(function()
										if vape.Modules.Fly.Enabled or (vape.Modules.TestFly and vape.Modules.TestFly.Enabled) or (vape.Modules.LongJump and vape.Modules.LongJump.Enabled) then
											connection:Disconnect()
											AntiFallDirection = nil
											clearAutoWinAntiFallPriority()
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
												--[[ Asked once. This sat in a ten-pass loop whose
												passes all asked the identical question, so a wall
												with a block on top of it cost ten store lookups every
												physics step for the same answer. ]]
												local dpos = roundPos(ray.Position + ray.Normal * 1.5) + Vector3.new(0, 3, 0)
												if not getPlacedBlock(dpos) then
													top = Vector3.new(top.X, ground, top.Z)
												end
											end

											root.CFrame += Vector3.new(0, top.Y - root.Position.Y, 0)
											if not frictionTable.Speed then
												root.AssemblyLinearVelocity = (AntiFallDirection * getSpeed()) + Vector3.new(0, root.AssemblyLinearVelocity.Y, 0)
											end

											if delta.Magnitude < 1 then
												connection:Disconnect()
												AntiFallDirection = nil
												clearAutoWinAntiFallPriority()
											end
										else
											connection:Disconnect()
											AntiFallDirection = nil
											clearAutoWinAntiFallPriority()
										end
									end)
									AntiFall:Clean(connection)
								end
							elseif Mode.Value == 'Velocity' then
								pulseAutoWinAntiFallPriority(0.35)
								entitylib.character.RootPart.Velocity = Vector3.new(entitylib.character.RootPart.Velocity.X, 100, entitylib.character.RootPart.Velocity.Z)
							end
						end
					end))
				end
			else
				AntiFallDirection = nil
				clearAutoWinAntiFallPriority()
			end
		end,
		Tooltip = 'Catches you before you fall into the void.\nCan guide you back to land, bounce you up or act as a floor.'
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
	local BlacklistCrops

	--[[ The cooldown the game ships with, restored on disable and used as the "don't
	speed this one up" value for blacklisted blocks. ]]
	local VANILLA_COOLDOWN = 0.3

	--[[ Name of the block currently under the crosshair, read through the same block
	selector AutoTool and Schematica use. Mode 1 is SELECT (the block being looked
	at); mode 0 is PLACE, which resolves to the empty cell in front of it instead. ]]
	local function readTargetedBlock()
		local breaker = bedwars.BlockBreakController.blockBreaker
		local info = breaker.clientManager:getBlockSelector():getMouseInfo(1)
		local target = info and info.target
		local block = target and target.blockInstance
		return block and block.Name
	end

	-- The read is its own function, not a closure made for each pcall: with a blacklist on, this runs every frame.
	local function targetedBlockName()
		local ok, name = pcall(readTargetedBlock)
		return ok and name or nil
	end

	--[[ Ores are named <material>_ore_mesh_block. Matched as a plain substring plus a
	trailing _ore, so diamond/emerald/gold are covered without hardcoding a list
	that a new ore would silently fall out of. Neither pattern can hit 'store' or
	'core' -- both need the underscore. ]]
	local function isOre(name)
		return name:find('ore_mesh_block', 1, true) ~= nil or name:match('_ore$') ~= nil
	end

	--[[ Crops are whatever the game's crop-meta has a config for -- pumpkin, carrot, melon
	and Taliyah's egg block today -- so a new crop is covered without editing a list here.
	Cached per block name, since this runs every frame while a blacklist is on. ]]
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
			if BlacklistBeds.Enabled and name == 'bed' then return VANILLA_COOLDOWN end
			if BlacklistOres.Enabled and isOre(name) then return VANILLA_COOLDOWN end
			if BlacklistHive.Enabled and name == 'beehive' then return VANILLA_COOLDOWN end
			if BlacklistCrops.Enabled and isCrop(name) then return VANILLA_COOLDOWN end
		end
		return Time.Value
	end

	FastBreak = vape.Categories.Blatant:CreateModule({
		Name = 'FastBreak',
		ExtraText = function()
			if not Time then return nil end
			if Time.Value <= 0 then return 'Instant' end
			return string.format('%.2fx', VANILLA_COOLDOWN / Time.Value)
		end,
		DisplayName = 'Fast Mine',
		Tab = 'Block',
		Function = function(callback)
			if callback then
				repeat
					--[[ With every blacklist off this is the original once-per-100ms
					setCooldown and costs exactly what it used to. With one on we need
					to react the frame the crosshair moves onto a blacklisted block,
					otherwise the stale value lets a fast hit or two through before the
					next poll catches up -- so tighten to per-frame only in that case. ]]
					local filtering = BlacklistBeds.Enabled or BlacklistOres.Enabled or BlacklistHive.Enabled or BlacklistCrops.Enabled
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
		Tooltip = 'Increases block mining speed.\nCan leave beds, ores, hives and crops at normal speed.'
	})
	Time = FastBreak:CreateSlider({
		Name = 'Break speed',
		Min = 0,
		Max = 0.3,
		Default = 0.25,
		Decimal = 100,
		Suffix = function(val) return 's' end
	})
	FastBreak:CreateDivider({Text = 'Extras'})
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
	BlacklistCrops = FastBreak:CreateToggle({
		Name = 'Blacklist Crops',
		Tooltip = 'Leaves crops at normal breaking speed'
	})
end)
	
local Fly
local TestFly
local LongJump

--[[ Persistent grounded/airborne state belongs to the adapter, not TPDown.
TPDown is a policy module: it decides when to teleport down and whether to show
its status bar. GroundWatcher stays alive regardless of that module so TestFly,
AutoZephyr and future traversal features all observe the same takeoff/landing
state.

lastGroundTick / lastGroundLandTick deliberately preserve the old TPDown timing
semantics. airTimerTick is separate: legitimate mid-air mechanics such as a
Zephyr air jump can renew the floating-time window without pretending the
player touched the ground. ResetAirTimer also updates entitylib.character.AirTime
for compatibility with the existing BedWars/Vape airborne clock. GroundWatcher
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
vape:Clean(GroundWatcher.Takeoff)
vape:Clean(GroundWatcher.Landed)
vape:Clean(GroundWatcher.AirTimerReset)

function GroundWatcher:ResetAirTimer(reason)
	local now = tick()
	self.airTimerTick = now
	if entitylib.isAlive and entitylib.character then
		entitylib.character.AirTime = os.clock()
	end
	self.AirTimerReset:Fire(now, reason)
	return now
end

run(function()
	local wasGrounded

	vape:Clean(runService.Heartbeat:Connect(function()
		--[[ Everyone else's jump count, settled once they have been still for a fifth of a
		second. This and the grounded AirTime below used to be a loop of their own, a second
		per-frame thread for the whole session. Only an entity mid-jump is walked: LandTick is
		read nowhere else, and the jump that makes Jumps non-zero sets it fresh. ]]
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
		-- TPDown's Air Time reads this as zero for as long as you stand on something
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

--[[ AutoZephyr follows TPDown's live Air Time option. Shortly before that
countdown expires it asks the vanilla JumpHeightController to spend one of
Zephyr's two air jumps by firing the same JumpRequest generated by user input.
The normal controller therefore remains responsible for NotifyAirJump, its
private air-jump counter and the 0.25s debounce.

A confirmed Freefall -> Jumping Zephyr transition renews GroundWatcher's
air-timer clock (and entitylib.character.AirTime), which restarts TPDown's
countdown/status window without falsifying lastGroundTick. ]]
run(function()
	local AutoZephyr
	local LeadTime
	local nextAttempt = 0
	local airJumpsUsed = 0

	local function reset()
		nextAttempt = 0
		airJumpsUsed = 0
	end

	local function getTPDown()
		local module = vape.Modules and vape.Modules.TPDown
		local airTime = module and module.Options and module.Options['Air Time']
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
		AutoZephyr:Clean(humanoid.StateChanged:Connect(function(oldState, newState)
			if newState == Enum.HumanoidStateType.Landed then
				reset()
				return
			end

			-- This is the same state transition WindWalker's controller uses to
			-- identify a real air jump. Only a successful jump renews TPDown.
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

	AutoZephyr = vape.Categories.Minigames:CreateModule({
		Name = 'AutoZephyr',
		Function = function(callback)
			if not callback then
				reset()
				return
			end

			reset()
			if entitylib.isAlive then
				watchHumanoid(entitylib.character.Humanoid)
			end
			AutoZephyr:Clean(entitylib.Events.LocalAdded:Connect(function(ent)
				reset()
				watchHumanoid(ent.Humanoid)
			end))
			AutoZephyr:Clean(GroundWatcher.Takeoff.Event:Connect(reset))
			AutoZephyr:Clean(GroundWatcher.Landed.Event:Connect(reset))

			AutoZephyr:Clean(runService.Heartbeat:Connect(function()
				if not (entitylib.isAlive and GroundWatcher.airborne and zephyrReady()) then
					return
				end
				if airJumpsUsed >= 2 then return end

				local humanoid = entitylib.character.Humanoid
				if not humanoid or humanoid:GetState() ~= Enum.HumanoidStateType.Freefall then
					return
				end

				local tpDown, airTime = getTPDown()
				if not (tpDown and tpDown.Enabled and airTime and type(airTime.Value) == 'number') then
					return
				end

				-- TPDown supplies the configured Air Time duration; GroundWatcher
				-- supplies the persistent countdown start. ResetAirTimer also keeps
				-- entitylib.character.AirTime synchronized for existing consumers.
				local remaining = airTime.Value - (tick() - GroundWatcher.airTimerTick)
				local now = tick()
				if remaining > LeadTime.Value or now < nextAttempt then return end

				nextAttempt = now + 0.26
				if type(firesignal) == 'function' then
					pcall(firesignal, inputService.JumpRequest)
				end
			end))
		end,
		ExtraText = function()
			local tpDown, airTime = getTPDown()
			if not (tpDown and tpDown.Enabled and airTime and type(airTime.Value) == 'number'
				and GroundWatcher.airTimerTick > 0) then
				return ''
			end
			return string.format('%.1fs', math.max(
				airTime.Value - (tick() - GroundWatcher.airTimerTick),
				0
			))
		end,
		Tooltip = 'Uses Zephyr air jumps to keep you in the air longer.\nTimes each jump for just before TPDown air time ends.'
	})

	LeadTime = AutoZephyr:CreateSlider({
		Name = 'Lead Time',
		Min = 0,
		Max = 1,
		Default = 0.15,
		Decimal = 100,
		Suffix = function(val) return val == 1 and 'second' or 'seconds' end,
		Tooltip = 'How early before TPDown Air Time expires AutoZephyr requests a jump'
	})
end)

run(function()
	local Value
	local VerticalValue
	local WallCheck
	local PopBalloons
	local rayCheck = RaycastParams.new()
	rayCheck.RespectCanCollide = true
	--[[ What rayCheck's filter was last built from. It is only cast with Wall Check on, and its
	parts change on a respawn at most, so it is rebuilt then rather than every physics step. ]]
	local filterChar, filterCamera, filterAntiFall
	local up, down, old = 0, 0

	Fly = vape.Categories.Blatant:CreateModule({
		Name = 'Fly',
		Function = function(callback)
			frictionTable.Fly = callback or nil
			updateVelocity()
			if callback then
				up, down = 0, 0
				old = true
				store.holdBalloons(true)

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

						if WallCheck.Enabled then
							if filterChar ~= lplr.Character or filterCamera ~= gameCamera or filterAntiFall ~= AntiFallPart then
								filterChar, filterCamera, filterAntiFall = lplr.Character, gameCamera, AntiFallPart
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
				if old then
					old = nil
					store.holdBalloons(false)
				end
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
		Tooltip = 'Lets you fly around freely.\nRise with jump and sink with Shift; can use and pop your balloon.'
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
	local Value
	local VerticalValue
	local WallCheck
	local PopBalloons
	local Notifications
	local VelocityBounceValue
	local CFrameBounceValue
	local BounceRepeat
	local BounceWait
	local VelocityIncrease
	local CFrameIncrease
	local VerticalClipVelocity
	local VerticalClipIncrement
	local VerticalClipWait
	local VerticalClipLoops
	local VerticalClipMaxY
	local JumpDuration
	local JumpHeightAbove
	local JumpMargin
	local rayCheck = RaycastParams.new()
	rayCheck.RespectCanCollide = true
	-- What rayCheck's filter was last built from; see Fly's, which is kept the same way.
	local filterChar, filterCamera, filterAntiFall
	local up, down = 0, 0
	local activeMode
	local modeGeneration = 0
	local modeCleanups = {}
	local Modes, ModeList = {}, {}
	local testFlySessionTick = 0
	local pendingOnGroundTick
	local waitForLandingGeneration
	local ModeContext = {}

	local function registerMode(name, hooks)
		Modes[name] = hooks or {}
		if not table.find(ModeList, name) then
			table.insert(ModeList, name)
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
				mode = Mode and Mode.Value or 'unknown'
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
		local mode = Modes[name]
		activeMode = mode
		modeGeneration += 1
		local generation = modeGeneration
		ModeContext.Generation = generation
		ModeContext.State = {}
		waitForLandingGeneration = nil

		if mode and type(mode.Once) == 'function' then
			task.spawn(function()
				callModeHook(mode, 'Once')
				if not (TestFly.Enabled and activeMode == mode and ModeContext.Generation == generation) then return end
				-- AutoWin owns the landing and releases this flight after support returns.
				if store.TestFlyJump and store.TestFlyJump.AutoWinOwned then return end

				if Notifications and Notifications.Enabled then
					-- Give GroundWatcher one frame to observe a ground -> air transition made by
					-- the final Once step before deciding whether a landing is pending.
					if entitylib.isAlive and entitylib.character.Humanoid.FloorMaterial == Enum.Material.Air then
						task.wait()
					end

					if TestFly.Enabled
						and activeMode == mode
						and ModeContext.Generation == generation
						and GroundWatcher.airborne
						and GroundWatcher.lastGroundTick >= testFlySessionTick then
						waitForLandingGeneration = generation
						return
					end
				end

				if TestFly.Enabled and activeMode == mode and ModeContext.Generation == generation then
					TestFly:Toggle()
				end
			end)
			return
		end

		callModeHook(mode, 'Start')
	end

	local function switchMode(name)
		if not (TestFly and TestFly.Enabled) then return end
		stopMode('switch')
		startMode(name)
	end

	local function notifyFlightStats(onGroundTick, onGroundPosition, landedPosition, landedTick)
		if not (Notifications and Notifications.Enabled) then return end
		if onGroundTick <= 0 or landedTick < onGroundTick or not onGroundPosition or not landedPosition then return end
		local horizontal = (landedPosition - onGroundPosition) * Vector3.new(1, 0, 1)
		notif('TestFly', string.format(
			'Flew %.1f studs for %.2f seconds',
			horizontal.Magnitude,
			landedTick - onGroundTick
		), 5)
	end

	vape:Clean(GroundWatcher.Landed.Event:Connect(function(onGroundTick, onGroundPosition, landedPosition, landedTick)
		local belongsToActiveSession = TestFly and TestFly.Enabled and onGroundTick >= testFlySessionTick
		local belongsToPendingFlight = pendingOnGroundTick ~= nil and onGroundTick == pendingOnGroundTick
		local finishesOnceMode = waitForLandingGeneration ~= nil
			and TestFly
			and TestFly.Enabled
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
			TestFly:Toggle()
		end
	end))

	local function startFlightMode(context)
		up, down = 0, 0
		context.State.oldDeflate = true
		store.holdBalloons(true)

		if lplr.Character and (lplr.Character:GetAttribute('InflatedBalloons') or 0) == 0 and getItem('balloon') then
			bedwars.BalloonController:inflateBalloon()
		end

		context:Clean(vapeEvents.AttributeChanged.Event:Connect(function(changed)
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

		if reason == 'disable' and PopBalloons.Enabled and entitylib.isAlive and lplr.Character and (lplr.Character:GetAttribute('InflatedBalloons') or 0) > 0 then
			for _ = 1, 3 do
				bedwars.BalloonController:deflateBalloon()
			end
		end
	end

	local function cleanupFlightMode()
		up, down = 0, 0
	end

	-- `maxSpeed` (optional) caps the studs a second moved this step below the
	-- usual getSpeed() plus the Speed slider's top-up.
	local function applyHorizontal(dt, maxSpeed)
		if not (entitylib.isAlive and isnetworkowner(entitylib.character.RootPart)) then return end

		local char = entitylib.character
		local root, moveDirection = char.RootPart, char.Humanoid.MoveDirection
		local velo = getSpeed()
		local speed = math.max(Value.Value, velo)
		if maxSpeed then
			speed = math.clamp(maxSpeed, 0, speed)
		end
		local walk = math.min(velo, speed)
		local destination = moveDirection * (speed - walk) * dt

		if WallCheck.Enabled then
			if filterChar ~= lplr.Character or filterCamera ~= gameCamera or filterAntiFall ~= AntiFallPart then
				filterChar, filterCamera, filterAntiFall = lplr.Character, gameCamera, AntiFallPart
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
		local amount = baseOption.Value
		local repeats = math.max(math.floor(BounceRepeat.Value), 1)

		for _ = 1, repeats do
			if not TestFly.Enabled or context.Generation ~= generation then return end
			if entitylib.isAlive and isnetworkowner(entitylib.character.RootPart) then
				local ok, err = pcall(apply, entitylib.character.RootPart, amount)
				if not ok then
					bufferCall('error', 'testfly.bounce', tostring(err), {
						mode = Mode and Mode.Value or 'unknown'
					})
				end
			end

			amount += increaseOption.Value
			task.wait(BounceWait.Value)
		end
	end
	registerMode('Heatseeker', {
		Start = startFlightMode,
		PreSimulation = function(_, dt)
			local root, moveDirection, velo = applyHorizontal(dt)
			if root then
				local balloons = lplr.Character:GetAttribute('InflatedBalloons')
				local flyAllowed = (balloons and balloons > 0) or store.matchState == 2
				local mass = (1.5 + (flyAllowed and 6 or 0) * (os.clock() % 0.4 < 0.2 and -1 or 1)) + ((up + down) * VerticalValue.Value)
				root.AssemblyLinearVelocity = (moveDirection * velo) + Vector3.new(0, mass, 0)
			end
		end,
		End = endFlightMode,
		Cleanup = cleanupFlightMode
	})

	registerMode('VelocityBounce', {
		Once = function(context)
			runBounceOnce(context, VelocityBounceValue, VelocityIncrease, function(root, amount)
				root.AssemblyLinearVelocity += Vector3.new(0, amount, 0)
			end)
		end
	})

	registerMode('CFrameBounce', {
		Once = function(context)
			runBounceOnce(context, CFrameBounceValue, CFrameIncrease, function(root, amount)
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
			local amount = VerticalClipVelocity.Value
			local loops = math.max(math.floor(VerticalClipLoops.Value), 1)

			-- Apply the configured vertical velocity pulse, wait, and repeat.
			-- With the defaults this runs 120 Y velocity 8 times at 0.17s
			-- intervals, so the final clip occurs after roughly 1.36 seconds.
			for _ = 1, loops do
				if not TestFly.Enabled or context.Generation ~= generation then return end
				if entitylib.isAlive and isnetworkowner(entitylib.character.RootPart) then
					local root = entitylib.character.RootPart
					local velocity = root.AssemblyLinearVelocity
					root.AssemblyLinearVelocity = Vector3.new(velocity.X, amount, velocity.Z)
				end

				amount += VerticalClipIncrement.Value
				task.wait(VerticalClipWait.Value)
			end

			-- Clip to the exact configured absolute world-space Y after the
			-- velocity sequence completes, preserving X/Z and rotation.
			if TestFly.Enabled and context.Generation == generation and entitylib.isAlive then
				local root = entitylib.character.RootPart
				local rotation = root.CFrame - root.CFrame.Position
				root.CFrame = CFrame.new(
					root.Position.X,
					VerticalClipMaxY.Value,
					root.Position.Z
				) * rotation
			end
		end
	})


	--[[ Jump. The map's block heights (player-placed blocks ignored, so towers
	cannot raise it) set the ceiling: the top block of every column, and the
	80th percentile of those tops rather than the single highest, so one spire
	does not lift every flight. Max Y = that top face + Jump Height Above
	Blocks, the highest point that does not take damage. It is worked out again
	when the match state changes, so the start of the match re-reads the map
	that actually loaded instead of the lobby's. The jump rises for
	exactly Jump Duration and peaks Jump Margin studs below that ceiling, then
	falls normally; unlike VerticalClip it never teleports.

	Every physics step re-solves the rise from where the character really is:
	the parabola through (now, current y) whose apex is (T, target y). With
	tau = T - now and dy = target y - current y, the straight line between those
	points has slope dy/tau, and that parabola's velocity now is 2 * dy/tau
	(falling linearly to zero at T). World gravity for the coming step is added
	back (g * dt), so the rise tracks the arc despite gravity, frame drops or
	knockback, and never passes the target. ]]
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

		-- Top map block per column. Attribute reads only for a new candidate
		-- height in that column.
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

	--[[ Aimed arc: AutoWin sets store.TestFlyJump.Target (the root position to
	land at) before switching Jump on, and the flight goes there instead of up
	to the ceiling. Its time is t = d / v: d the horizontal distance left, v the
	speed this step moves at (getSpeed() plus the Speed slider's top-up). The
	vertical velocity is the parabola under gravity g that reaches the target's
	height at that time, vy = dy / t + g * t / 2. Re-solved every step, so a
	faster speed flattens the arc and lands sooner instead of falling out the
	rest of a fixed rise. t is never shorter than:
	  - on the ground: a lift of Clearance studs over the higher end, so the
	    flight leaves its block and comes down onto the landing;
	  - rising below Clearance over the landing, or well under it: an apex
	    Clearance studs over the landing;
	  - otherwise: the free fall from here (never pushed down past gravity).
	When t is one of those, horizontal speed is cut to d / t. Nothing rises
	past the Jump ceiling. ]]
	local function arcSeconds(apexRise, dy, gravity)
		-- From rest up apexRise to the apex, then down to dy (apexRise >= dy).
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
			-- Not steered yet, or down on the landing (the owner ends the flight).
			applyHorizontal(dt)
			return
		end

		local minimum
		if grounded then
			minimum = arcSeconds(math.max(dy, 0) + clearance, dy, gravity)
		elseif (vy >= 0 and dy > -clearance) or dy > 1.5 then
			minimum = arcSeconds(dy + clearance, dy, gravity)
		elseif dy > 0 then
			-- Falling, just under the landing's height: nothing left to aim.
			applyHorizontal(dt)
			return
		else
			minimum = (vy + math.sqrt(vy * vy - 2 * gravity * dy)) / gravity
		end

		local speed = math.max(Value.Value, getSpeed(), 1)
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

			-- At least two steps of remaining time, so one step can never carry
			-- the character past the target.
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
				return TestFly.Enabled and context.Generation == generation and entitylib.isAlive
			end

			if store.TestFlyJump and typeof(store.TestFlyJump.Target) == 'Vector3' then
				-- Aimed arc: PreSimulation steers it until the owner ends the flight.
				local arc = {}
				context.State.Arc = arc
				local top = getHighestMapBlockTop()
				if top and current() then
					arc.CeilingY = top + JumpHeightAbove.Value - JumpMargin.Value
				end
				return
			end

			local top = getHighestMapBlockTop()
			if not top or not current() then return end

			local root = entitylib.character.RootPart
			local duration = math.max(JumpDuration.Value, 0.05)
			local targetY = top + JumpHeightAbove.Value - JumpMargin.Value
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

			-- Apex reached: stop rising here and fall under normal gravity.
			if current() and isnetworkowner(entitylib.character.RootPart) then
				local apexRoot = entitylib.character.RootPart
				local velocity = apexRoot.AssemblyLinearVelocity
				apexRoot.AssemblyLinearVelocity = Vector3.new(velocity.X, 0, velocity.Z)
			end
		end
	})

	-- Modes with Once run only that hook and TestFly disables when it returns.
	-- Other modes use Start/PreSimulation/Heartbeat/End/Cleanup normally.

	local function updateModeVisibility(name)
		local velocityBounce = name == 'VelocityBounce'
		local cframeBounce = name == 'CFrameBounce'
		local verticalClip = name == 'VerticalClip'
		local anyBounce = velocityBounce or cframeBounce

		if VerticalValue then VerticalValue.Object.Visible = name == 'Heatseeker' end
		if VelocityBounceValue then VelocityBounceValue.Object.Visible = velocityBounce end
		if CFrameBounceValue then CFrameBounceValue.Object.Visible = cframeBounce end
		if BounceRepeat then BounceRepeat.Object.Visible = anyBounce end
		if BounceWait then BounceWait.Object.Visible = anyBounce end
		if VelocityIncrease then VelocityIncrease.Object.Visible = velocityBounce end
		if CFrameIncrease then CFrameIncrease.Object.Visible = cframeBounce end
		if VerticalClipVelocity then VerticalClipVelocity.Object.Visible = verticalClip end
		if VerticalClipIncrement then VerticalClipIncrement.Object.Visible = verticalClip end
		if VerticalClipWait then VerticalClipWait.Object.Visible = verticalClip end
		if VerticalClipLoops then VerticalClipLoops.Object.Visible = verticalClip end
		if VerticalClipMaxY then VerticalClipMaxY.Object.Visible = verticalClip end
		local jump = name == 'Jump'
		if JumpDuration then JumpDuration.Object.Visible = jump end
		if JumpHeightAbove then JumpHeightAbove.Object.Visible = jump end
		if JumpMargin then JumpMargin.Object.Visible = jump end
	end

	TestFly = vape.Categories.Blatant:CreateModule({
		Name = 'TestFly',
		Function = function(callback)
			frictionTable.TestFly = callback or nil
			updateVelocity()
			if callback then
				testFlySessionTick = tick()
				pendingOnGroundTick = nil
				waitForLandingGeneration = nil
				startMode(Mode.Value)

				TestFly:Clean(runService.PreSimulation:Connect(function(dt)
					callModeHook(activeMode, 'PreSimulation', dt)
				end))

				TestFly:Clean(runService.Heartbeat:Connect(function(dt)
					callModeHook(activeMode, 'Heartbeat', dt)
				end))

				TestFly:Clean(inputService.InputBegan:Connect(function(input)
					if not inputService:GetFocusedTextBox() then
						if input.KeyCode == Enum.KeyCode.Space or input.KeyCode == Enum.KeyCode.ButtonA then
							up = 1
						elseif input.KeyCode == Enum.KeyCode.LeftShift or input.KeyCode == Enum.KeyCode.ButtonL2 then
							down = -1
						end
					end
				end))

				TestFly:Clean(inputService.InputEnded:Connect(function(input)
					if input.KeyCode == Enum.KeyCode.Space or input.KeyCode == Enum.KeyCode.ButtonA then
						up = 0
					elseif input.KeyCode == Enum.KeyCode.LeftShift or input.KeyCode == Enum.KeyCode.ButtonL2 then
						down = 0
					end
				end))

				if inputService.TouchEnabled then
					pcall(function()
						local jumpButton = lplr.PlayerGui.TouchGui.TouchControlFrame.JumpButton
						TestFly:Clean(jumpButton:GetPropertyChangedSignal('ImageRectOffset'):Connect(function()
							up = jumpButton.ImageRectOffset.X == 146 and 1 or 0
						end))
					end)
				end
			else
				waitForLandingGeneration = nil
				stopMode('disable')
				-- A manual disable still allows the current flight to report after
				-- landing without forcing TestFly to remain enabled.
				if Notifications and Notifications.Enabled and GroundWatcher.airborne and GroundWatcher.lastGroundTick >= testFlySessionTick then
					pendingOnGroundTick = GroundWatcher.lastGroundTick
				end
			end
		end,
		ExtraText = function()
			return Mode.Value
		end,
		Tooltip = 'Lets you fly using experimental flight modes.\nChoose Heatseeker, bounce, vertical clip or jump flight.'
	})

	ModeContext.Module = TestFly

	Mode = TestFly:CreateDropdown({
		Name = 'Mode',
		List = ModeList,
		Default = 'Heatseeker',
		Function = function(val)
			updateModeVisibility(val)
			switchMode(val)
		end
	})

	Value = TestFly:CreateSlider({
		Name = 'Speed',
		Min = 1,
		Max = 23,
		Default = 23,
		Suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})

	VerticalValue = TestFly:CreateSlider({
		Name = 'Vertical Speed',
		Min = 1,
		Max = 150,
		Default = 50,
		Suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})

	VelocityBounceValue = TestFly:CreateSlider({
		Name = 'Velocity',
		Min = 0,
		Max = 150,
		Default = 25,
		Darker = true,
		Visible = false,
		Suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})

	CFrameBounceValue = TestFly:CreateSlider({
		Name = 'CFrame',
		Min = 0,
		Max = 20,
		Decimal = 10,
		Default = 1,
		Darker = true,
		Visible = false,
		Suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})

	BounceRepeat = TestFly:CreateSlider({
		Name = 'Repeat',
		Min = 1,
		Max = 20,
		Default = 3,
		Darker = true,
		Visible = false
	})

	BounceWait = TestFly:CreateSlider({
		Name = 'Wait',
		Min = 0.01,
		Max = 2,
		Decimal = 100,
		Default = 0.1,
		Darker = true,
		Visible = false,
		Suffix = function(val)
			return val == 1 and 'second' or 'seconds'
		end
	})

	VelocityIncrease = TestFly:CreateSlider({
		Name = 'Increase Velocity',
		Min = -50,
		Max = 50,
		Default = 0,
		Darker = true,
		Visible = false,
		Suffix = function(val)
			return (val == 1 or val == -1) and 'stud' or 'studs'
		end
	})

	CFrameIncrease = TestFly:CreateSlider({
		Name = 'Increase CFrame',
		Min = -10,
		Max = 10,
		Decimal = 10,
		Default = 0,
		Darker = true,
		Visible = false,
		Suffix = function(val)
			return (val == 1 or val == -1) and 'stud' or 'studs'
		end
	})

	VerticalClipVelocity = TestFly:CreateSlider({
		Name = 'Clip Velocity',
		Min = -150,
		Max = 150,
		Default = 120,
		Darker = true,
		Visible = false,
		Suffix = function(val)
			return (val == 1 or val == -1) and 'stud' or 'studs'
		end
	})

	VerticalClipIncrement = TestFly:CreateSlider({
		Name = 'Clip Increment',
		Min = -50,
		Max = 50,
		Default = 0,
		Darker = true,
		Visible = false,
		Suffix = function(val)
			return (val == 1 or val == -1) and 'stud' or 'studs'
		end
	})

	VerticalClipWait = TestFly:CreateSlider({
		Name = 'Clip Wait',
		Min = 0.01,
		Max = 2,
		Decimal = 100,
		Default = 0.17,
		Darker = true,
		Visible = false,
		Suffix = function(val)
			return val == 1 and 'second' or 'seconds'
		end
	})

	VerticalClipLoops = TestFly:CreateSlider({
		Name = 'Clip Loop Count',
		Min = 1,
		Max = 20,
		Default = 8,
		Darker = true,
		Visible = false
	})

	VerticalClipMaxY = TestFly:CreateSlider({
		Name = 'Max Y',
		Min = -500,
		Max = 190,
		Decimal = 10,
		Default = 180,
		Darker = true,
		Visible = false,
		Tooltip = 'Exact absolute world-space Y to clip to after the velocity sequence'
	})

	JumpDuration = TestFly:CreateSlider({
		Name = 'Jump Duration',
		Min = 0.3,
		Max = 3,
		Decimal = 100,
		Default = 1.2,
		Darker = true,
		Visible = false,
		Suffix = function(val)
			return val == 1 and 'second' or 'seconds'
		end,
		Tooltip = 'Time the Jump rise takes to reach its apex (for an aimed arc, the latest it may peak)'
	})

	JumpHeightAbove = TestFly:CreateSlider({
		Name = 'Jump Height Above Blocks',
		Min = 0,
		Max = 200,
		Default = 125,
		Darker = true,
		Visible = false,
		Suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end,
		Tooltip = 'Max Y before damage: the highest map block top plus this many studs'
	})

	JumpMargin = TestFly:CreateSlider({
		Name = 'Jump Margin',
		Min = 0,
		Max = 30,
		Decimal = 10,
		Default = 5,
		Darker = true,
		Visible = false,
		Suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end,
		Tooltip = 'How far below Max Y the Jump apex stops'
	})

	WallCheck = TestFly:CreateToggle({
		Name = 'Wall Check',
		Default = true
	})

	PopBalloons = TestFly:CreateToggle({
		Name = 'Pop Balloons',
		Default = true
	})

	Notifications = TestFly:CreateToggle({
		Name = 'Notifications',
		Tooltip = 'Reports takeoff/landing flight stats and keeps Once modes enabled until landing'
	})

	-- Jump ceiling for AutoWin's flight planning. ApexY may scan the map once
	-- (yields); CachedApexY never scans and is nil until the ceiling is known.
	-- Target (a root position) set before Jump starts flies the aimed arc to
	-- it, landing from at least Clearance studs above; nil flies the rise.
	store.TestFlyJump = {
		AutoWinOwned = false,
		Target = nil,
		Clearance = nil,
		ApexY = function()
			local top = getHighestMapBlockTop()
			return top and top + JumpHeightAbove.Value - JumpMargin.Value or nil
		end,
		CachedApexY = function()
			if not jumpCeilingCurrent(bedwars.BlockController:getStore()) then
				return nil
			end
			return jumpCeiling.Top + JumpHeightAbove.Value - JumpMargin.Value
		end,
		Duration = function()
			return math.max(JumpDuration.Value, 0.05)
		end
	}

	ModeContext.Options = {
		Mode = Mode,
		Speed = Value,
		VerticalSpeed = VerticalValue,
		Velocity = VelocityBounceValue,
		CFrame = CFrameBounceValue,
		Repeat = BounceRepeat,
		Wait = BounceWait,
		IncreaseVelocity = VelocityIncrease,
		IncreaseCFrame = CFrameIncrease,
		ClipVelocity = VerticalClipVelocity,
		ClipIncrement = VerticalClipIncrement,
		ClipWait = VerticalClipWait,
		ClipLoopCount = VerticalClipLoops,
		MaxY = VerticalClipMaxY,
		JumpDuration = JumpDuration,
		JumpHeightAbove = JumpHeightAbove,
		JumpMargin = JumpMargin,
		WallCheck = WallCheck,
		PopBalloons = PopBalloons,
		Notifications = Notifications
	}

	updateModeVisibility(Mode.Value)
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
		ExtraText = function()
			return Expand and tostring(Expand.Value) or nil
		end,
		DisplayName = 'Hitboxes',
		Tab = 'Combat',
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
		Tooltip = 'Makes other players easier to hit.\nEither widens your sword swing or grows their hitboxes.'
	})
	Expand = HitBoxes:CreateSlider({
		Name = 'Expand amount',
		DisplayName = 'Expand',
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
	HitBoxes:CreateDivider({Text = 'Extras'})
	Mode = HitBoxes:CreateDropdown({
		Name = 'Mode',
		List = {'Sword', 'Player'},
		Function = function()
			if HitBoxes.Enabled then
				HitBoxes:Toggle(nil, true)
				HitBoxes:Toggle(nil, true)
			end
		end,
		Tooltip = 'Sword - widens the range you can hit people from\nPlayer - grows the players own hitboxes'
	})
end)
	
	
run(function()
	vape.Categories.Blatant:CreateModule({
		Name = 'KeepSprint',
		Function = function(callback)
			debug.setconstant(bedwars.SprintController.startSprinting, 5, callback and 'blockSprinting' or 'blockSprint')
			bedwars.SprintController:stopSprinting()
		end,
		Tooltip = 'Keeps your sprint speed when attacking players.'
	})
end)

run(function()
	local SafeWalk
	local rayCheck = RaycastParams.new()
	rayCheck.RespectCanCollide = true
	--[[ The hook this enable installed: {Active, Hook, Previous}. TargetStrafe and AutoWin wrap the
	same slot, so turning off puts Previous back only while our hook is still on top; otherwise it
	stays in the chain as a pass-through and the wrappers above it keep working. ]]
	local module, current

	SafeWalk = vape.Categories.World:CreateModule({
		Name = 'SafeWalk',
		Tab = 'Move',
		Function = function(callback)
			if callback then
				if not module then
					local suc = pcall(function()
						module = require(lplr.PlayerScripts.PlayerModule).controls
					end)
					if not suc then module = {} end
				end

				local old = module.moveFunction
				-- No movement function to wrap (the controls did not load): nothing to hook.
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
		Tooltip = 'Prevents you from walking off ledges.'
	})
end)

run(function()
	local old
	
	vape.Categories.Blatant:CreateModule({
		Name = 'NoSlowdown',
		DisplayName = 'No Slow',
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
		Tooltip = 'Removes slowdown while using items.'
	})
end)
	
run(function()
	local Speed
	local Mode
	local Value
	local WallCheck
	local AutoJump
	local AlwaysJump
	local PauseOnLagback
	local rayCheck = RaycastParams.new()
	rayCheck.RespectCanCollide = true
	--[[ Pause on Lagback: the executor's own isnetworkowner (the file's local one answers
	true on most executors). While the server holds the character -- a lagback -- every
	push here is set back again. The probe is not cheap, so it is read at most every 0.1s
	rather than every rendered frame. Without an executor function it never pauses. ]]
	local ownedAt, owned = 0, true
	local function ownsCharacter(root)
		if not PauseOnLagback.Enabled then
			return isnetworkowner(root)
		end
		local now = os.clock()
		if now - ownedAt >= 0.1 then
			ownedAt = now
			local check = getgenv and getgenv().isnetworkowner
			if type(check) == 'function' then
				local ok, result = pcall(check, root)
				owned = not ok or result == true
			else
				owned = isnetworkowner(root)
			end
		end
		return owned
	end
	
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
						if entitylib.isAlive and not Fly.Enabled and not TestFly.Enabled and not (vape.Modules.LongJump and vape.Modules.LongJump.Enabled) and ownsCharacter(entitylib.character.RootPart) then
						local char = entitylib.character
						local hum = char.Humanoid
						local state = hum:GetState()
						if state == Enum.HumanoidStateType.Climbing then return end

						--[[ getSpeed() is the wrapped one -- DamageBoost adds its boost on top of
						the real walk speed, and this module spends whatever it reports. So on
						Blatant a hit that boosts you also makes Speed carry you further, on top
						of the boost itself. Legit reads the unwrapped figure instead, which is
						the speed the server thinks you have. ]]
						local root = char.RootPart
						local velo = (Mode.Value == 'Legit' and rawGetSpeed or getSpeed)()
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
		Tooltip = 'Makes you move faster than normal.\nCan also jump for you while you fight, or all the time.'
	})
	--[[ First in the list because it changes what the slider below is measured against. ]]
	Mode = Speed:CreateDropdown({
		Name = 'Mode',
		List = {'Blatant', 'Legit'},
		Default = 'Blatant',
		Tooltip = 'Legit ignores the DamageBoost speed boost when working out how\nmuch to top you up. Blatant spends it.'
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
	PauseOnLagback = Speed:CreateToggle({
		Name = 'Pause on Lagback',
		Tooltip = 'Stops speeding while the server holds your character\n(no network ownership of it: a lagback).'
	})
end)
	
run(function()
	local BedESP
	local Method
	local Color
	local TeamColor
	local BoundingBox
	local Filled
	local HealthBar
	local Name
	local Background
	local Teammates
	local Distance
	local DistanceLimit
	local Reference = {}
	local menuHidden = false

	--[[ Drawn with the Drawing library, like ESP, rather than adornments in Pistonware's GUI:
	nothing is parented anywhere, so there is no GUI permission for an executor to refuse, and
	the options are ESP's -- 2D or 3D box, fill, health bar, name with a background, priority
	only, distance range -- read against a bed instead of a character.

	Every bed is boxed by its own block: a BasePart two cells long, or a model's bounding box.
	The 3D mode draws its twelve edges; the 2D mode the screen rectangle around them. The name
	and the health bar hang off that rectangle in both modes. ]]
	local CORNERS = {
		Vector3.new(-1, -1, -1), Vector3.new(1, -1, -1), Vector3.new(1, -1, 1), Vector3.new(-1, -1, 1),
		Vector3.new(-1, 1, -1), Vector3.new(1, 1, -1), Vector3.new(1, 1, 1), Vector3.new(-1, 1, 1)
	}
	local EDGES = {
		{1, 2}, {2, 3}, {3, 4}, {4, 1},
		{5, 6}, {6, 7}, {7, 8}, {8, 5},
		{1, 5}, {2, 6}, {3, 7}, {4, 8}
	}

	-- The team a bed belongs to: the id in its Team<id>NoBreak attribute, the one the game
	-- itself protects the bed with.
	local function bedTeam(bed)
		for name in bed:GetAttributes() do
			local id = name:match('^Team(.+)NoBreak$')
			if id then return id end
		end
	end

	-- The team's name and colour for this match, from its queue meta (displayName 'Blue',
	-- colorHex). A bed the meta does not cover falls back to 'Team <id>' and the colour of
	-- its own blanket.
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
		if not color then
			local part = bed:FindFirstChild('Blanket') or bed:FindFirstChild('Covers')
			color = part and part:IsA('BasePart') and part.Color or nil
		end
		return name or (teamId and 'Team '..tostring(teamId)) or 'Bed', color
	end

	-- The bed's health the way the block engine counts it (hits already taken off), over its
	-- block's full health. nil when there is nothing to read.
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

	local function bedBox(bed)
		if bed:IsA('BasePart') then
			return bed.CFrame, bed.Size
		end
		local ok, cframe, size = pcall(bed.GetBoundingBox, bed)
		if ok then return cframe, size end
	end

	local function colorOf(ref)
		return TeamColor.Enabled and ref.TeamColor or Color3.fromHSV(Color.Hue, Color.Sat, Color.Value)
	end

	local function newDrawing(class, props)
		local object = Drawing.new(class)
		for key, value in props do
			object[key] = value
		end
		return object
	end

	local function removeBed(bed)
		local ref = Reference[bed]
		if not ref then return end
		Reference[bed] = nil
		if vape.ThreadFix then
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
		if Reference[bed] or not bed.Parent then return end
		local teamId = bedTeam(bed)
		-- Priority Only: your own team's bed is the one you already know about.
		if Teammates.Enabled and teamId and tostring(teamId) == tostring(lplr:GetAttribute('Team')) then return end
		if vape.ThreadFix then
			setthreadidentity(8)
		end

		local teamName, teamColor = teamInfo(bed, teamId)
		local ref = {Objects = {}, Points = {}, TeamColor = teamColor, Label = teamName..' Bed', HealthAt = 0, TeamId = teamId, TeamAt = 0}
		local color = colorOf(ref)
		local ok = pcall(function()
			local objects = ref.Objects
			if Method.Value == '3D' then
				ref.Lines = {}
				for index = 1, #EDGES do
					local line = newDrawing('Line', {Thickness = 1, Color = color, ZIndex = 2})
					ref.Lines[index] = line
					table.insert(objects, line)
				end
			else
				ref.Main = newDrawing('Square', {
					Thickness = 1, Filled = false, ZIndex = 2, Color = color,
					Transparency = BoundingBox.Enabled and 1 or 0
				})
				table.insert(objects, ref.Main)
				if BoundingBox.Enabled then
					ref.Border = newDrawing('Square', {Thickness = 1, Filled = false, ZIndex = 1, Color = Color3.new(), Transparency = 0.35})
					ref.Border2 = newDrawing('Square', {Thickness = 1, Filled = Filled.Enabled, ZIndex = 1, Color = Color3.new(), Transparency = 0.35})
					table.insert(objects, ref.Border)
					table.insert(objects, ref.Border2)
				end
			end
			if HealthBar.Enabled then
				ref.HealthBorder = newDrawing('Line', {Thickness = 3, ZIndex = 1, Color = Color3.new(), Transparency = 0.35})
				ref.HealthLine = newDrawing('Line', {Thickness = 1, ZIndex = 2, Color = Color3.fromHSV(1 / 2.5, 0.89, 0.75)})
				table.insert(objects, ref.HealthBorder)
				table.insert(objects, ref.HealthLine)
			end
			if Name.Enabled then
				if Background.Enabled then
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
		Reference[bed] = ref
		-- A drawing that would not build leaves nothing half-drawn behind it.
		if not ok then
			removeBed(bed)
		end
	end

	local function recolor()
		for _, ref in Reference do
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

	--[[ Visibility is written only when it changes: Priority Only hides your own bed on every
	frame. ref.Shown is nil while a write is under way, so one that throws part way is redone
	in full next time rather than trusted. ]]
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

	-- The bed's team, looked up again twice a second until it is known. A bed added before
	-- its team attribute had replicated kept the plain 'Bed' label, and Priority Only, which
	-- only looked when the bed was added, drew our own bed for the whole match; the label
	-- and colour follow the team once it is in.
	local function teamOf(bed, ref)
		if ref.TeamId == nil and os.clock() >= ref.TeamAt then
			ref.TeamAt = os.clock() + 0.5
			local teamId = bedTeam(bed)
			if teamId then
				ref.TeamId = teamId
				local teamName, teamColor = teamInfo(bed, teamId)
				ref.Label, ref.TeamColor = teamName..' Bed', teamColor
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
		-- Hidden once while the menu is open; the first frame after it closes draws them again.
		if clickGuiOpen() then
			if not menuHidden then
				for _, ref in Reference do
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
		-- Priority Only as it draws, against our team as it is now: before the teams are
		-- given out (a profile loaded in the lobby cage) nothing matched when beds were added.
		local ownTeam = Teammates.Enabled and lplr:GetAttribute('Team')
		for bed, ref in Reference do
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
			if Distance.Enabled then
				local distance = rootPos and (rootPos - cframe.Position).Magnitude or math.huge
				if distance < DistanceLimit.ValueMin or distance > DistanceLimit.ValueMax then
					hide(ref)
					continue
				end
			end

			-- Every corner on screen space; one behind the camera would flip the box inside out.
			-- The points table is the bed's own, refilled each frame: only a full pass reads it.
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
			--[[ The rectangle the 2D box, the bar and the name were last drawn against. Standing
			still with the camera still, nothing below would change, so those writes are skipped;
			the 3D lines follow every corner and are always written. ]]
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
				-- Five times a second is plenty for a bar; the engine lookup is not free.
				if now >= ref.HealthAt then
					ref.HealthAt = now + 0.2
					local health, maxHealth = bedHealth(bed)
					if health and (not maxHealth or maxHealth < health) then
						-- No max to measure against: the most it has been seen at stands in.
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
				-- Read once a frame rather than three times; the label changes it when the team lands.
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
		if BedESP.Enabled then
			BedESP:Toggle(nil, true)
			BedESP:Toggle(nil, true)
		end
	end

	BedESP = vape.Categories.Render:CreateModule({
		Name = 'BedESP',
		DisplayName = 'Block ESP',
		Function = function(callback)
			if callback then
				-- Checked by use, not by type: some executors hand Drawing over as userdata.
				if not pcall(function() assert(Drawing.new) end) then
					notif('BedESP', 'Your executor has no Drawing library to draw with.', 5, 'warning')
					return
				end
				BedESP:Clean(collectionService:GetInstanceAddedSignal('bed'):Connect(function(bed)
					-- A placed bed replicates a moment before its team attribute does.
					task.delay(0.2, addBed, bed)
				end))
				BedESP:Clean(collectionService:GetInstanceRemovedSignal('bed'):Connect(removeBed))
				for _, bed in collectionService:GetTagged('bed') do
					addBed(bed)
				end
				BedESP:Clean(runService.RenderStepped:Connect(function()
					-- One bed that fails to draw this frame hides only itself.
					local ok = pcall(render)
					if not ok then
						for _, ref in Reference do
							pcall(hide, ref)
						end
					end
				end))
				-- A bed that could not be read yet (no team attribute, off the block store) is
				-- picked up here.
				BedESP:Clean(task.spawn(function()
					repeat
						task.wait(1)
						for _, bed in collectionService:GetTagged('bed') do
							if not Reference[bed] then
								addBed(bed)
							end
						end
					until not BedESP.Enabled
				end))
			else
				for bed in Reference do
					removeBed(bed)
				end
			end
		end,
		Tooltip = 'Shows beds through walls with their team and health.\nPick a 2D or 3D box, colors, labels and range.'
	})
	Distance = BedESP:CreateToggle({
		Name = 'Distance Check',
		Function = function(callback)
			DistanceLimit.Object.Visible = callback
		end
	})
	DistanceLimit = BedESP:CreateTwoSlider({
		Name = 'Bed Distance',
		DisplayName = 'Range',
		Min = 0,
		Max = 1024,
		DefaultMin = 0,
		DefaultMax = 512,
		Darker = true,
		Visible = false
	})
	Color = BedESP:CreateColorSlider({
		Name = 'Bed Color',
		Function = function()
			recolor()
		end
	})
	BedESP:CreateDivider({Text = 'Extras'})
	TeamColor = BedESP:CreateToggle({
		Name = 'Team Color',
		Default = true,
		Function = function()
			recolor()
		end,
		Tooltip = 'Draws each bed in its team colour instead of Bed Color'
	})
	Method = BedESP:CreateDropdown({
		Name = 'Mode',
		List = {'2D', '3D'},
		Function = function(val)
			restart()
			BoundingBox.Object.Visible = val == '2D'
			Filled.Object.Visible = val == '2D' and BoundingBox.Enabled
		end
	})
	BoundingBox = BedESP:CreateToggle({
		Name = 'Bounding Box',
		Function = function(callback)
			restart()
			if Filled then
				Filled.Object.Visible = callback and Method.Value == '2D'
			end
		end,
		Default = true,
		Darker = true
	})
	Filled = BedESP:CreateToggle({
		Name = 'Filled',
		Function = restart,
		Darker = true
	})
	HealthBar = BedESP:CreateToggle({
		Name = 'Health Bar',
		Function = restart,
		Default = true,
		Darker = true
	})
	Name = BedESP:CreateToggle({
		Name = 'Name',
		Function = function(callback)
			restart()
			if Background then
				Background.Object.Visible = callback
			end
		end,
		Default = true,
		Darker = true,
		Tooltip = 'Shows whose bed it is, like Blue Bed'
	})
	Background = BedESP:CreateToggle({
		Name = 'Show Background',
		Function = restart,
		Darker = true
	})
	Teammates = BedESP:CreateToggle({
		Name = 'Priority Only',
		Function = restart,
		Default = true,
		Tooltip = 'Hides your own team\'s bed'
	})
	-- Their Functions fire at creation, before the options they show and hide exist.
	BoundingBox.Object.Visible = Method.Value == '2D'
	Filled.Object.Visible = Method.Value == '2D' and BoundingBox.Enabled
	Background.Object.Visible = Name.Enabled

	-- Drawings outlive the module being switched off, so they go on uninject.
	vape:Clean(function()
		for bed in Reference do
			removeBed(bed)
		end
	end)
end)
	
run(function()
	local Health
	-- Others drawn just under the crosshair, which this moves below rather than writing over.
	local CROWD = {'ScaffoldCount', 'PistonwareFlyStatus'}

	-- The menu's green above half, its yellow down to a fifth, its red below, as Target Info.
	local function healthColor(percent)
		local theme = vape.Libraries.theme or {}
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

	-- The screen y a label's text actually covers: a zero-size label draws its text centred on its position.
	local function extent(obj)
		local top, bottom = obj.AbsolutePosition.Y, obj.AbsolutePosition.Y + obj.AbsoluteSize.Y
		if obj:IsA('TextLabel') and obj.Text ~= '' then
			local middle = obj.AbsolutePosition.Y + obj.AbsoluteSize.Y / 2
			top = math.min(top, middle - obj.TextBounds.Y / 2)
			bottom = math.max(bottom, middle + obj.TextBounds.Y / 2)
		end
		return top, bottom
	end

	--[[ 30 px under the crosshair, moved down past the Scaffold card or the fly status while either
	is up there. A short screen has no room under it, so there it sits beside the crosshair. ]]
	local function place(label)
		local camera = workspace.CurrentCamera
		if camera and camera.ViewportSize.Y > 0 and camera.ViewportSize.Y < 450 then
			label.AnchorPoint = Vector2.new(0, 0.5)
			label.Position = UDim2.new(0.5, 34, 0.5, 0)
			label.TextXAlignment = Enum.TextXAlignment.Left
			return
		end
		local centre = vape.gui.AbsolutePosition.Y + vape.gui.AbsoluteSize.Y / 2
		local offset = 30
		for _ = 1, 2 do
			for _, name in CROWD do
				local other = vape.gui:FindFirstChild(name)
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

	Health = vape.Categories.Render:CreateModule({
		Name = 'Health',
		Function = function(callback)
			if callback then
				local label = Instance.new('TextLabel')
				label.Size = UDim2.fromOffset(100, 20)
				label.Position = UDim2.new(0.5, 0, 0.5, 30)
				label.AnchorPoint = Vector2.new(0.5, 0)
				label.BackgroundTransparency = 1
				label.RichText = true
				label.Text = healthText()
				label.TextSize = 18
				loaderStyle.text(label, 'SemiBold')
				-- Over the world with no box behind it, so a soft outline keeps it readable.
				label.TextStrokeColor3 = Color3.new()
				label.TextStrokeTransparency = 0.6
				label.Visible = not clickGuiOpen()
				label.Parent = vape.gui
				Health:Clean(label)
				pcall(place, label)
				Health:Clean(task.spawn(function()
					if vape.ThreadFix then
						pcall(setthreadidentity, 8)
					end
					repeat
						task.wait(0.25)
						pcall(place, label)
					until not label.Parent
				end))
				-- Out of the way while the menu is open, back when it closes.
				if vape.ThreadFix then
					setthreadidentity(8)
				end
				local scaledGui = vape.gui:FindFirstChild('ScaledGui')
				local clickGui = scaledGui and scaledGui:FindFirstChild('ClickGui')
				if clickGui then
					Health:Clean(clickGui:GetPropertyChangedSignal('Visible'):Connect(function()
						if vape.ThreadFix then
							setthreadidentity(8)
						end
						label.Visible = not clickGui.Visible
					end))
				end
				--[[ Every attribute change on your character lands here, and most of them leave the
				health alone; the label is only written when its text actually changes. ]]
				local shownText = label.Text
				Health:Clean(vapeEvents.AttributeChanged.Event:Connect(function()
					local text = healthText()
					if text ~= shownText then
						shownText = text
						label.Text = text
					end
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
	local Scale
	local Reference = {}
	local Pending = {}
	local Removing = {}
	local connections = {}
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

	--[[ Every GUI write happens on this module's own thread, never on the tag signals.

	The tags are added by the game, on the game's thread (identity 2): an eldertree orb is
	tagged inside EldertreeController's spawn handler. vape.gui sits in CoreGui or gethui on
	executors with a settable identity, and a billboard parented there from the game's thread
	fails. So the signals only note what came and went, and the loop below builds and removes.

	The raise is guarded. vape.ThreadFix only says setthreadidentity exists; on an executor whose
	ceiling is below 8 an unguarded setthreadidentity(8) throws, and it used to be the first line
	of the loop, so KitESP stopped before drawing anything. ]]
	local function raiseIdentity()
		if not vape.ThreadFix then return end
		if not pcall(setthreadidentity, 8) then
			pcall(setthreadidentity, 7)
		end
	end

	local function Added(ent, icon)
		if Reference[ent] or not ent.Parent then return end
		-- A model streamed in before its parts has nothing to hang the icon on yet; the sweep
		-- picks it up once one arrives. Searched deep: a skinned model keeps its parts nested.
		local part = ent:IsA('BasePart') and ent or ent:IsA('Model') and (ent.PrimaryPart or ent:FindFirstChild('Root') or ent:FindFirstChildWhichIsA('BasePart', true))
		if not part then return end

		local billboard
		local ok = pcall(function()
			billboard = Instance.new('BillboardGui')
			billboard.Name = icon
			billboard.StudsOffsetWorldSpace = Vector3.new(0, 3, 0)
			local size = Scale and Scale.Value or 1
			billboard.Size = UDim2.fromOffset(36 * size, 36 * size)
			billboard.AlwaysOnTop = true
			billboard.ClipsDescendants = false
			billboard.Adornee = part
			-- Built hidden while the menu is open; the loop shows it once the menu closes.
			billboard.Enabled = not clickGuiOpen()
			billboard.Parent = Folder
			-- The plate is the loader's box, scaled with the billboard; the icon sits inset in it.
			local plate = Instance.new('Frame')
			plate.Name = 'Plate'
			plate.Size = UDim2.fromScale(1, 1)
			plate.BackgroundColor3 = Color3.fromHSV(Color.Hue, Color.Sat, Color.Value)
			plate.BackgroundTransparency = 1 - (Background.Enabled and Color.Opacity or 0)
			plate.BorderSizePixel = 0
			plate.Parent = billboard
			loaderStyle.corner(plate, 6)
			loaderStyle.stroke(plate).Enabled = Background.Enabled
			local image = Instance.new('ImageLabel')
			image.Name = 'Icon'
			image.Size = Background.Enabled and UDim2.fromScale(0.8, 0.8) or UDim2.fromScale(1, 1)
			image.Position = UDim2.fromScale(0.5, 0.5)
			image.AnchorPoint = Vector2.new(0.5, 0.5)
			image.BackgroundTransparency = 1
			image.BorderSizePixel = 0
			-- An icon the item meta cannot resolve still gets its marker, just without the picture.
			local iconOk, iconImage = pcall(bedwars.getIcon, {itemType = icon}, true)
			image.Image = iconOk and type(iconImage) == 'string' and iconImage or ''
			image.Parent = plate
		end)
		if ok then
			Reference[ent] = billboard
		elseif billboard then
			-- Half built: gone, so the next sweep can try again.
			pcall(function() billboard:Destroy() end)
		end
	end

	local function Removed(ent)
		local billboard = Reference[ent]
		Reference[ent] = nil
		if billboard then
			pcall(function() billboard:Destroy() end)
		end
	end

	local function clearAll()
		for _, v in connections do
			v:Disconnect()
		end
		table.clear(connections)
		table.clear(Reference)
		table.clear(Pending)
		table.clear(Removing)
		pcall(function() Folder:ClearAllChildren() end)
	end

	KitESP = vape.Categories.Render:CreateModule({
		Name = 'KitESP',
		Function = function(callback)
			raiseIdentity()
			if callback then
				local current, lastHidden
				local nextSweep = 0
				repeat
					local now = os.clock()
					if now >= nextSweep then
						nextSweep = now + 1
						-- Every kit you are playing: Kit Fusion's second kit has its own things to find.
						local kits = store.activeKits()
						local key = table.concat(kits, ',')
						if key ~= current then
							current = key
							clearAll()
							for _, name in kits do
								local kit = ESPKits[name]
								if kit then
									table.insert(connections, collectionService:GetInstanceAddedSignal(kit[1]):Connect(function(ent)
										Removing[ent] = nil
										Pending[ent] = kit[2]
									end))
									table.insert(connections, collectionService:GetInstanceRemovedSignal(kit[1]):Connect(function(ent)
										Pending[ent] = nil
										Removing[ent] = true
									end))
								end
							end
						end
						--[[ Once a second, everything tagged that still has no billboard: the whole
						set on a kit change, models whose parts had not streamed in when they were
						tagged, and anything a failed build left out. ]]
						for _, name in kits do
							local kit = ESPKits[name]
							if kit then
								for _, v in collectionService:GetTagged(kit[1]) do
									if not Reference[v] then
										Pending[v] = kit[2]
									end
								end
							end
						end
					end
					for ent in Removing do
						Removing[ent] = nil
						Removed(ent)
					end
					for ent, icon in Pending do
						Pending[ent] = nil
						Added(ent, icon)
					end
					-- Hidden while the menu is open; written only when that changes.
					local hidden = clickGuiOpen()
					if hidden ~= lastHidden then
						lastHidden = hidden
						for _, billboard in Reference do
							pcall(function() billboard.Enabled = not hidden end)
						end
					end
					task.wait(0.1)
				until not KitESP.Enabled
			else
				clearAll()
			end
		end,
		Tooltip = 'Highlights things your kit collects, like bees and orbs.'
	})

	Scale = KitESP:CreateSlider({
		Name = 'Scale',
		Function = function(val)
			for _, v in Reference do
				pcall(function()
					v.Size = UDim2.fromOffset(36 * val, 36 * val)
				end)
			end
		end,
		Default = 1,
		Min = 0.1,
		Max = 1.5,
		Decimal = 10
	})
	Background = KitESP:CreateToggle({
		Name = 'Background',
		Function = function(callback)
			if Color.Object then
				Color.Object.Visible = callback
			end
			for _, v in Reference do
				pcall(function()
					v.Plate.BackgroundTransparency = 1 - (callback and Color.Opacity or 0)
					v.Plate.UIStroke.Enabled = callback
					v.Plate.Icon.Size = callback and UDim2.fromScale(0.8, 0.8) or UDim2.fromScale(1, 1)
				end)
			end
		end,
		Default = true
	})
	Color = KitESP:CreateColorSlider({
		Name = 'Background Color',
		DefaultHue = loaderStyle.Hue,
		DefaultSat = loaderStyle.Sat,
		DefaultValue = loaderStyle.Value,
		DefaultOpacity = 1 - loaderStyle.Transparency,
		Function = function(hue, sat, val, opacity)
			for _, v in Reference do
				pcall(function()
					v.Plate.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
					v.Plate.BackgroundTransparency = 1 - (Background.Enabled and opacity or 0)
				end)
			end
		end,
		Darker = true
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

run(function()
	local NameTags
	local Targets
	local Color
	local Background
	local DisplayName
	local Health
	local Distance
	local Equipment
	local ShowKit
	local Rank
	local Enchant
	local Device
	local OverrideTarget
	local Scale
	local FontOption
	local Teammates
	local DistanceCheck
	local DistanceLimit
	local Strings, Sizes, Reference = {}, {}, {}
	--[[ Tags part way through Added.Normal, keyed by entity to a token owned by that one
	build. Kept apart from Reference because the build YIELDS: getfontsize is
	TextService:GetTextBoundsAsync. It used to claim Reference[ent] before measuring, so the
	render loop -- which drops any Reference entry whose label has no Parent yet -- deleted
	the half-built tag during that yield, and the build then saw Reference no longer pointing
	at its label and destroyed it. Nothing rebuilt it until that player's health or equipment
	next changed, which is the "some people just have no tag" report. ]]
	local Building = {}
	-- per-entity update generation, see Updated.Normal
	local UpdateGen = {}

	local Folder
	
	pcall(function()
		Folder = Instance.new('Folder')
		-- Named so NameHider can find it: it ignores vape's own GUI by default, and these
		-- labels are full of player names
		Folder.Name = 'NameTags'
		Folder.Parent = vape.gui
	end)
	
	local methodused
	--[[ assigned once the Updated table below exists; lets the rank fetch redraw a tag when
	the division finally lands ]]
	local refreshTag

	--[[ Drawn like the mod overlay's lines: the tag's own text is hidden and two layers carry it, a
	dark copy one pixel down and right with the coloured text over it -- layers, because a child
	always draws over its parent's own text. Both follow the tag's text, colour and size. ]]
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
		--[[ Colour emoji (the device icons) draw in colour whatever TextColor3 says, so in the shadow
		they are kept for their width but not drawn. ]]
		shadow.RichText = true
		local function sync()
			front.Text = nametag.Text
			local plain = removeTags(nametag.Text):gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;')
			shadow.Text = plain:gsub('[\128-\255]+', function(run)
				if run == '\u{2665}' then
					return run
				end
				return '<font transparency="1">'..run..'</font>'
			end)
		end
		sync()
		nametag.TextTransparency = 1
		nametag:GetPropertyChangedSignal('Text'):Connect(sync)
		nametag:GetPropertyChangedSignal('TextColor3'):Connect(function()
			front.TextColor3 = nametag.TextColor3
		end)
	end

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
	--[[ Kit leads the row: it is the thing you read first about a player, and it used to be
	stranded up in the equipment strip a whole row above the name. These sit INLINE with the
	text instead, which is what the rest of this row has always done. ]]
	local rightIcons = {'Kit', 'RankIcon', 'EnchantIcon'}
	local equipmentIcons = {'Hand', 'Helmet', 'Chestplate', 'Boots'}

	--[[ Each tag's icons, in row order, found once. positionIcons runs every time a moving
	player's distance ticks over, and it looked all seven up by name each time; the set never
	changes after the build that made them, which creates every one before its first
	positionIcons. Weak, so a destroyed tag takes its entry with it -- Reference holds every
	live one. ]]
	local TagIcons = setmetatable({}, {__mode = 'k'})
	-- positionIcons never yields, so one scratch list serves every call
	local carried = {}

	local function iconsOf(nametag)
		local icons = TagIcons[nametag]
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
			TagIcons[nametag] = icons
		end
		return icons
	end

	--[[ `height` is the nametag's own pixel height, so the icons scale with the tag instead
	of staying pinned at 30px. That was the other half of the mismatch: the text follows the
	Scale slider and a fixed 30 did not, so the icons drifted out of line with the tag the
	moment Scale moved off 1. Sized to the tag and sitting at y = 0, they are flush with it. ]]
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

		--[[ The equipment row sits above the tag, centred on it: what they hold first, then their
		armour, only the slots with something in them, at the tag's own height. It used to start one
		icon left of the tag's edge with every slot kept, so a weapon alone hung off the tag's
		corner, and at a fixed 30px per Scale it outgrew the tag. Centred on the tag's middle, the
		row stays centred as the distance changes the tag's width. ]]
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

	--[[ Green at full, red at none -- and never a throw.

	MaxHealth is not always a usable number at the moment a tag is built: an entity can reach
	the builder a frame before its Humanoid is populated, and 0 or nil there made this divide
	nan or throw outright. That took the whole build down with it, and since Reference[ent] is
	only assigned on the very last line of the build, the entity ended up with no tag AND no
	way to get one -- which is what "sometimes they just do not appear" was.

	Falling back to full health draws a tag that is briefly the wrong colour; the next update
	corrects it. A missing tag does not correct itself. ]]
	local TAG_GREEN, TAG_YELLOW, TAG_RED = Color3.fromRGB(85, 255, 85), Color3.fromRGB(255, 255, 85), Color3.fromRGB(255, 85, 85)

	--[[ Green above half health, yellow at half or less, red under a fifth -- the 20 health of 100
	that ten hearts come to. ]]
	local function tagHealthColor(ent)
		local maxHealth = ent.MaxHealth
		local fraction = 1

		if type(maxHealth) == 'number' and maxHealth > 0 then
			fraction = (ent.Health or maxHealth) / maxHealth
		end

		-- a nan compares false with everything, which would land it in red
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

	-- The same three for how far away they are: green past 30 studs, yellow from 10, red closer.
	-- Their hex is made once; this runs every time a moving player's distance ticks over.
	local TAG_GREEN_HEX, TAG_YELLOW_HEX, TAG_RED_HEX = TAG_GREEN:ToHex(), TAG_YELLOW:ToHex(), TAG_RED:ToHex()
	local function distanceText(studs)
		local hex = studs > 30 and TAG_GREEN_HEX or studs >= 10 and TAG_YELLOW_HEX or TAG_RED_HEX
		return '<font color="#'..hex..'">'..studs..'m</font>'
	end

	--[[ A team's name and colour for this match, from its queue meta, as the Block ESP names beds;
	the colour falls back to the team colour Roblox holds for the player, if there is one. Nothing
	in the lobby. ]]
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

	-- A black team's colour is lifted toward grey: the tag's own background is black.
	local function readable(colour)
		local _, _, value = colour:ToHSV()
		return value < 0.3 and colour:Lerp(Color3.fromRGB(150, 150, 150), 0.6) or colour
	end

	-- Their team's first letter in the team's colour: W for White.
	local function teamLetter(plr)
		local name, colour = teamOf(plr:GetAttribute('Team'), plr)
		if not name then return nil end
		colour = readable(colour or Color3.new(1, 1, 1))
		return '<b><font color="#'..colour:ToHex()..'">'..name:sub(1, 1):upper()..'</font></b>'
	end

	--[[ A name's colour, as Player ESP picks a box's: the target colour for everyone with Override
	target color on; otherwise a friend's in the Friends colour (Recolor visuals), and everyone
	else's in their team's own colour -- a drone's from its owner, a team monster's from its own
	Team attribute. No team, no colour of its own: white. ]]
	local function tagColor(ent)
		if OverrideTarget.Enabled then
			return Color3.fromHSV(Color.Hue, Color.Sat, Color.Value)
		end
		local plr = ent.Player
		if plr and isFriend(plr, true) then
			local friends = vape.Categories.Friends.Options['Friends color']
			return Color3.fromHSV(friends.Hue, friends.Sat, friends.Value)
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

	--[[ NameHider, applied before the name is ever drawn.

	It also watches these labels from the outside, but that is a race this module can simply
	not enter: it knows the name at the moment it builds the string, so it can hide it there.
	Doing it here also survives the distance rewrite in the render loop, which puts the whole
	original string back on the label every time the number changes.

	Reads the function fresh each time rather than caching it, so turning NameHider off takes
	effect on the next tag without either module knowing about the other. ]]
	local function hideNames(text)
		local hide = genv.PistonwareHideName
		if type(hide) ~= 'function' then return text end

		local ok, res = pcall(hide, text)
		return (ok and type(res) == 'string') and res or text
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

	--[[ Whether this entity should carry a tag at all.

	This is the upstream filter, unchanged: ent.Targetable is entitylib's own answer to
	"is this someone I am against", and ent.Friend covers a whitelisted player on the
	other team. What was wrong was never the rule -- it was that Targetable had stopped
	tracking the truth.

	entitylib decides Targetable through targetCheck, which for bedwars compares the Team
	ATTRIBUTE, but the only thing that asked it to look again was a listener on the Team
	PROPERTY, which bedwars never sets. So Targetable was fixed at the instant the entity
	was built -- before the team had replicated, for most of them -- and stayed wrong for
	the rest of the match. addPlayer now refreshes on the attribute instead, so this is a
	live answer again and the workaround that used to live here is gone.

	Declared HERE, above Added, on purpose. The previous version sat below it, so both
	call sites resolved the name as a global instead of an upvalue and read nil: with
	Priority Only on, every single tag build threw on the call and was swallowed by the
	pcall around it. That is the whole of "nametags only work with Priority Only off". ]]
	local function passesFilter(ent)
		if not Targets.Players.Enabled and ent.Player then return false end
		if not Targets.NPCs.Enabled and ent.NPC then return false end
		if Teammates.Enabled and (not ent.Targetable) and (not ent.Friend) then return false end
		return true
	end

	--[[ The tag's text: health with its heart, the device, the team letter right against the name,
	then the distance -- left as %s, filled with distanceText whenever it changes. ]]
	local function tagText(ent)
		local text = hideNames(ent.Player and whitelist:tag(ent.Player, true, true)..(DisplayName.Enabled and ent.Player.DisplayName or ent.Player.Name) or ent.Character.Name)
		-- The team letter, Slinky's W, where the name no longer says the team: Override target color on.
		if OverrideTarget.Enabled and ent.Player then
			local letter = teamLetter(ent.Player)
			if letter then
				text = letter..' '..text
			end
		end
		if Device.Enabled and ent.Player then
			local emoji = getDeviceEmoji(ent.Player)
			if emoji then
				text = emoji..' '..text
			end
		end
		if Health.Enabled then
			text = '<font color="#'..tagHealthColor(ent):ToHex()..'">'..math.round(ent.Health or 0)..'\u{2665}</font> '..text
		end
		if Distance.Enabled then
			-- A % typed into NameHider's replacement would be read by string.format as an option.
			text = text:gsub('%%', '%%%%')..' %s'
		end
		return text
	end

	local Added = {
		Normal = function(ent)
			local token = {}
			pcall(function()
				if not passesFilter(ent) then return end
				if Reference[ent] or Building[ent] then return end --[[ Prevent duplicates ]]
				Building[ent] = token

				local nametag = Instance.new('TextLabel')
				Strings[ent] = tagText(ent)

				--[[ Kit is no longer one of these. It is not equipment -- it does not change
				as they swap items -- and it now has its own toggle and its own slot beside the
				name. The four that are left are sized and placed by positionIcons, in one row centred
				above the tag: the held item first, then the armour. ]]
				if Equipment.Enabled then
					for _, v in equipmentIcons do
						local Icon = Instance.new('ImageLabel')
						Icon.Name = v
						Icon.BackgroundTransparency = 1
						Icon.Image = ''
						Icon.Visible = false
						Icon.Parent = nametag
					end
				end

				nametag.TextSize = 14 * Scale.Value
				nametag.FontFace = FontOption.Value
				local size = getfontsize(removeTags(Strings[ent]), nametag.TextSize, nametag.FontFace, Vector2.new(100000, 100000))
				-- getfontsize yielded: a removal or a restart in the meantime cancels this build
				if Building[ent] ~= token then
					nametag:Destroy()
					return
				end
				nametag.Name = ent.Player and ent.Player.Name or ent.Character.Name
				nametag.Size = UDim2.fromOffset(size.X + 8, size.Y + 7)

				--[[ Same shape as the Rank and Enchant icons below: no Position and no Size
				here, because positionIcons owns the layout and setting either now would flash
				the icon at a slot and a scale it may not end up at. ]]
				if ShowKit.Enabled and ent.Player then
					local Icon = Instance.new('ImageLabel')
					Icon.Name = 'Kit'
					Icon.Size = UDim2.fromOffset(ICON_SIZE, ICON_SIZE)
					Icon.BackgroundTransparency = 1
					Icon.Image = getKitRenderImage(ent.Player)
					Icon.Visible = false
					Icon.Parent = nametag
				end

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

				--[[ after every right-side icon exists, so each lands at its own slot ]]
				positionIcons(nametag, size.X, size.Y + 7)

				nametag.AnchorPoint = Vector2.new(0.5, 1)
				nametag.BackgroundColor3 = Color3.new()
				nametag.BackgroundTransparency = Background.Value
				nametag.BorderSizePixel = 0
				nametag.Visible = false
				nametag.Text = Strings[ent]
				nametag.TextColor3 = tagColor(ent)
				nametag.RichText = true
				shadeTag(nametag)
				if Building[ent] ~= token then
					nametag:Destroy()
					return
				end
				-- Only now does it become a real tag: finished and parented in the same step,
				-- so the render loop never meets one without a Parent.
				Reference[ent] = nametag
				Building[ent] = nil
				nametag.Parent = Folder
			end)
			-- A build that threw part way must not leave the entity marked as in progress.
			if Building[ent] == token then
				Building[ent] = nil
			end
		end
	}
	
	local Removed = {
		Normal = function(ent)
			-- cancels a build that is still yielding in getfontsize
			Building[ent] = nil
			UpdateGen[ent] = nil
			pcall(function()
				unwatchEnchant(ent)
				local v = Reference[ent]
				if v then
					if vape.ThreadFix then
						setthreadidentity(8)
					end
					v:Destroy()
					Reference[ent] = nil
					Strings[ent] = nil
					Sizes[ent] = nil
				end
			end)
		end
	}
	
	--[[ Whether this entity table has been superseded.

	entitylib hands a player a NEW entity table when their character is replaced, and the old
	one can still be sitting in entitylib.List with a RootPart that is still parented -- the
	previous character, wherever it was left. A tag built against that table renders at that
	position, which is how two tags for the same player ended up on screen with one of them
	parked in the sky.

	Only a DIFFERENT live entity counts as superseded. getEntity comes back nil for a moment
	while a player is dead, and treating that as stale would tear a tag down and build it again
	a second later, every death, for everyone. ]]
	local function supersededEntity(ent)
		local plr = ent.Player
		if not plr then return false end

		--[[ Compared against the player's OWN Character rather than asked of entitylib.

		entitylib.getEntity is called with a character instance everywhere else in this file,
		so handing it a Player was never going to come back with anything -- which made this
		return false for everybody and pruned nothing. Duplicate tags for one player, at three
		different places on screen, were the result.

		Player.Character is the authority on which character is current, and an entity table
		built around a previous one is by definition finished. ]]
		local live = plr.Character
		local mine = ent.Character

		-- live is nil for a moment while they are dead; treating that as stale would tear
		-- every tag down and rebuild it on every death
		return live ~= nil and mine ~= nil and mine ~= live
	end

	--[[ A tag that is missing gets rebuilt here rather than staying missing.

	Added assigns Reference[ent] on its very last line, so anything that throws part way
	through the build -- and the whole build sits under a pcall -- leaves that entity with no
	tag and no way back: both Updated paths bailed on a nil Reference, and the render loop
	only ever drops entries. One bad frame while a character streamed in and that player had
	no nametag for the rest of the round.

	EntityUpdated fires constantly (health, equipment), so this costs a table lookup on the
	common path and repairs the rare one within moments. Added re-applies the Targets and
	Teammates filters itself, so an entity that is deliberately untagged stays untagged. ]]
	local function rebuildTag(ent, method)
		local existing = Reference[ent]
		if existing then
			Removed[method](ent)
		end

		Added[method](ent)
		return Reference[ent] ~= nil
	end

	local Updated = {
		Normal = function(ent)
			pcall(function()
				--[[ The filter is re-asked here, which the upstream module has no need to do.

				Targetable now genuinely CHANGES during a round -- addPlayer refreshes it when
				the Team attribute lands and fires this very event -- so a tag can become owed
				to somebody who was correctly skipped a moment ago, and owed by somebody who
				was correctly given one. Both directions are handled from the same place the
				change is announced, which is why the retry sweep that used to sit in the
				module loop is gone. ]]
				if not passesFilter(ent) then
					if Reference[ent] then
						Removed['Normal'](ent)
					end
					return
				end

				local nametag = Reference[ent]

				-- Parent as well as existence: the label is dropped by the render loop when
				-- its container goes, and that left the entity in the same dead end
				if not nametag or not nametag.Parent then
					rebuildTag(ent, 'Normal')
					return
				end

				if vape.ThreadFix then
					setthreadidentity(8)
				end

				--[[ Health used to be the LAST thing this wrote, which is why it stopped updating.

				The new text was built first but only put on the label at the very end, after the
				equipment, kit, rank and enchant icons -- all under the one pcall. Any of those
				throwing (an inventory that has not replicated yet, an icon lookup) abandoned the
				update before the text was ever written, so the number stayed at whatever the
				last clean pass left. And the getfontsize just before it yields, so an older
				update resuming late could put an older health back over a newer one, and it
				wrote the raw string -- with Distance on that replaced the formatted distance the
				render loop had just drawn.

				So: a generation per entity so only the newest update finishes, the text written
				straight away and already formatted, and every icon on its own pcall. ]]
				local gen = (UpdateGen[ent] or 0) + 1
				UpdateGen[ent] = gen

				Strings[ent] = tagText(ent)
				-- Teams are given out after the tag is built, and the override can change: the colour follows.
				local nameColor = tagColor(ent)
				if nametag.TextColor3 ~= nameColor then
					nametag.TextColor3 = nameColor
				end

				if Distance.Enabled then
					local selfRoot = entitylib.isAlive and entitylib.character.RootPart
					local root = ent.RootPart
					local mag = (selfRoot and root) and math.floor((selfRoot.Position - root.Position).Magnitude) or 0
					nametag.Text = string.format(Strings[ent], distanceText(mag))
					Sizes[ent] = mag
				else
					nametag.Text = Strings[ent]
					Sizes[ent] = nil
				end

				if Equipment.Enabled and ent.Player and nametag:FindFirstChild('Hand') then
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

				-- FindFirstChild, not an index: the icon only exists when the toggle was on at
				-- the moment this tag was built.
				if ShowKit.Enabled and ent.Player then
					pcall(function()
						local icon = nametag:FindFirstChild('Kit')
						if icon then
							icon.Image = getKitRenderImage(ent.Player)
						end
					end)
				end

				if Rank.Enabled and ent.Player then
					pcall(function()
						local icon = nametag:FindFirstChild('RankIcon')
						if icon then
							icon.Image = getRankImage(ent.Player) or ''
						end
					end)
				end

				if Enchant.Enabled and ent.Player then
					pcall(function()
						local icon = nametag:FindFirstChild('EnchantIcon')
						if icon then
							icon.Image = getEnchantImage(ent.Player) or ''
						end
					end)
				end

				local size = getfontsize(removeTags(nametag.Text), nametag.TextSize, nametag.FontFace, Vector2.new(100000, 100000))
				-- getfontsize yielded: a newer update, or a removed tag, owns the label now
				if UpdateGen[ent] ~= gen or Reference[ent] ~= nametag then return end
				nametag.Size = UDim2.fromOffset(size.X + 8, size.Y + 7)
				positionIcons(nametag, size.X, size.Y + 7)
			end)
		end
	}
	
	refreshTag = function(ent)
		if Reference[ent] and Updated[methodused] then
			Updated[methodused](ent)
		end
	end

	local ColorFunc = {
		Normal = function()
			pcall(function()
				for i, v in Reference do
					if v and v.Parent then
						v.TextColor3 = tagColor(i)
					end
				end
			end)
		end
	}
	
	--[[ The re-measure after a distance change, on a thread of its own. getfontsize is
	GetTextBoundsAsync, and with the distance in the text most strings are new to its cache, so
	it yields -- and inside the render loop that yield held up every tag after this one until it
	came back, with the next frame's loop already running over the same tags. Same measure and
	the same writes, in the same order once it returns; the loop just no longer waits on it. It
	reads the label's text at once, before any yield, so it measures what was just written.

	A measure that comes back after the text has moved on is dropped. Whatever moved it has a
	measure of its own coming, and with Sizes already set to the new distance nothing would
	measure again: an older string finishing last would leave the tag sized for the wrong text
	until the distance next changed. ]]
	local function measureTag(nametag)
		local text = nametag.Text
		local size = getfontsize(removeTags(text), nametag.TextSize, nametag.FontFace, Vector2.new(100000, 100000))
		if nametag.Text ~= text then return end
		nametag.Size = UDim2.fromOffset(size.X + 8, size.Y + 7)
		positionIcons(nametag, size.X, size.Y + 7)
	end

	--[[ One tag's worth of work, under its own pcall.

	The comment inside spells out why a throw here used to freeze every tag after it in the
	iteration. The RootPart read it describes is guarded now, but that was never the only
	thing in here that can throw: ent.HipHeight is arithmetic on a field nothing guarantees,
	and string.format walks a Strings entry that has to carry a %s. Either one abandoning the
	frame leaves every remaining tag exactly where it was last drawn -- and it repeats every
	frame, so they stay there while you walk away.

	A pcall per tag per frame is a handful of nanoseconds against sixteen tags. Losing one
	tag for a frame is a flicker; losing the rest of the list is the bug being reported. ]]
	local function paintTag(ent, nametag, selfPos)
		--[[ THIS is why tags froze on screen.

		The whole loop used to sit under one pcall. An entity whose RootPart had gone --
		died, streamed out, character swapped -- threw on `ent.RootPart.Position`, and
		that one throw abandoned the rest of the frame. Every tag after it in the
		iteration kept the Position and the Visible it was last given, so they hung
		wherever they had been drawn while the players they belonged to walked away. It
		repeated every frame for as long as the dead entity stayed in Reference, which is
		until its label is destroyed -- so it never cleared on its own.

		A missing RootPart is now just a hidden tag. The entry is deliberately LEFT in
		Reference: Removed is what destroys the label, and it finds it through this
		very table, so clearing it here would orphan the TextLabel under Folder for
		the rest of the round. entitylib will report the entity properly soon enough
		and the real cleanup happens there. ]]
		local root = ent.RootPart
		if not (root and root.Parent) then
			nametag.Visible = false
			return
		end

		--[[ And never draw against a character its player has moved on from. The
		sweep prunes these once a second, which is up to a second of a tag sitting
		over an empty spot -- two property reads a frame is cheaper than explaining
		that to anyone. ]]
		if supersededEntity(ent) then
			nametag.Visible = false
			return
		end

		local rootPos = root.Position

		if DistanceCheck.Enabled then
			local distance = selfPos and (selfPos - rootPos).Magnitude or math.huge
			if distance < DistanceLimit.ValueMin or distance > DistanceLimit.ValueMax then
				nametag.Visible = false
				return
			end
		end

		local headPos, headVis = gameCamera:WorldToViewportPoint(rootPos + Vector3.new(0, ent.HipHeight + 1, 0))
		nametag.Visible = headVis
		if not headVis then
			return
		end

		if Distance.Enabled then
			local mag = selfPos and math.floor((selfPos - rootPos).Magnitude) or 0
			if Sizes[ent] ~= mag then
				nametag.Text = string.format(Strings[ent], distanceText(mag))
				Sizes[ent] = mag
				task.spawn(pcall, measureTag, nametag)
			end
		end
		nametag.Position = UDim2.fromOffset(headPos.X, headPos.Y)
	end

	-- The per-tag pcall takes its arguments rather than wrapping a fresh closure: this runs
	-- for every tag on every rendered frame.
	local function drawTag(ent, nametag, selfPos)
		pcall(paintTag, ent, nametag, selfPos)
	end

	local Loop = {
		Normal = function()
			pcall(function()
				--[[ Local player's position is identical for every nametag this frame;
				resolve the property chain once instead of per-entity. ]]
				local selfPos = entitylib.isAlive and entitylib.character.RootPart.Position
				-- Hidden while the menu is open; paintTag shows them again the frame after it closes.
				local hidden = clickGuiOpen()
				for ent, nametag in Reference do
					if not nametag or not nametag.Parent then
						Reference[ent] = nil
						continue
					end
					if hidden then
						if nametag.Visible then
							nametag.Visible = false
						end
						continue
					end
					drawTag(ent, nametag, selfPos)
				end
			end)
		end
	}
	
	--[[ One live setup at a time, however many starts arrive.

	Nearly every toggle below reacts with `if NameTags.Enabled then NameTags:Toggle()
	NameTags:Toggle() end`, which is fine when a person clicks one. Applying a profile
	clicks all of them: LoadOptions walks the saved options and fires that Function for
	every one whose value differs from the profile you were on.

	And while a profile is applying the GUI splits that pair. The OFF runs inline, but the
	ON goes through queueStart -- deferred onto a drain thread so sixty modules do not all
	start in one frame. So switching between two profiles that both have this module on
	queues one start per changed option and then runs them back to back with nothing in
	between.

	Every one of those starts connected another RenderStepped loop, another EntityAdded,
	another EntityRemoved and another set of device watchers on top of the last, and none
	were ever dropped -- the module's maid is emptied only when it is toggled OFF, and no
	toggle-off ever ran. Eight changed options meant eight of everything, all writing into
	the one Reference table.

	So a start ends the previous one first. Same two steps the GUI takes on a disable --
	empty the maid, then let the module drop its own state -- done from in here because a
	second start never gives the GUI the chance. ]]
	local liveSetup = false

	local function dropSetup()
		for _, connection in NameTags.Connections do
			pcall(function()
				local disconnect = connection.Disconnect or connection.disconnect or connection.Destroy
				if type(disconnect) == 'function' then
					disconnect(connection)
				end
			end)
		end
		table.clear(NameTags.Connections)
		-- any build still yielding belongs to the setup being dropped
		table.clear(Building)
		table.clear(UpdateGen)

		if Removed[methodused] then
			for ent in Reference do
				Removed[methodused](ent)
			end
		end
		--[[ the loop above only reaches entities that still have a tag; sweep the rest so
		no attribute listener outlives the setup ]]
		for ent in enchantConns do
			unwatchEnchant(ent)
		end

		liveSetup = false
	end

	NameTags = vape.Categories.Render:CreateModule({
		Name = 'NameTags',
		Function = function(callback)
			if callback then
				-- a start with no disable in front of it is a restart, not an addition
				if liveSetup then
					dropSetup()
				end
				liveSetup = true

				--[[ The game's own nametags are left alone. NameTags used to switch them off while it
				was on, and that broke them (including your own) after a late join. ]]

				methodused = 'Normal'
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

				--[[ Once a second, anyone who should have a tag and does not gets one.

				EntityUpdated is the only other thing that rebuilds a missing tag, and it fires
				on health, equipment and team changes -- a player standing still at full health
				can go a long time without any of those. Added applies the Targets and Priority
				Only filters itself and skips anyone tagged or mid-build, so this only ever fills
				a gap: an entity deliberately left untagged stays untagged. ]]
				local sweepAt = 0
				local npcPollAt = 0
				NameTags:Clean(runService.Heartbeat:Connect(function()
					local now = os.clock()

					--[[ NPC health, polled as well as listened for. Whatever a dummy or monster
					keeps its health in, a change that fires no signal still reaches the tag within
					a fifth of a second. Only tagged NPCs are read, and only a real change redraws. ]]
					if now >= npcPollAt then
						npcPollAt = now + 0.2
						for ent in Reference do
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

					--[[ A tag whose player has left the server, or whose character no longer
					exists, is taken down here. EntityRemoved is what normally does it, and this is
					the backstop for anything that slipped past it -- a player gone mid-build, a
					character destroyed without CharacterRemoving. ]]
					local remove = Removed[methodused]
					if remove then
						for ent in Reference do
							local gone = (ent.Player and ent.Player.Parent == nil)
								or not (ent.Character and ent.Character.Parent)
							if gone then
								remove(ent)
							end
						end
					end

					local add = Added[methodused]
					if not add then return end
					for _, ent in entitylib.List do
						local root = ent.RootPart
						if not Reference[ent] and not Building[ent] and root and root.Parent and not supersededEntity(ent) then
							add(ent)
						end
					end
				end))

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
				dropSetup()
			end
		end,
		Tooltip = 'Shows clear name tags above other players.\nCan add health, distance, gear, kit, rank and device.'
	})
	Scale = NameTags:CreateSlider({
		Name = 'Scale',
		Function = function()
			if NameTags.Enabled then
				NameTags:Toggle(nil, true)
				NameTags:Toggle(nil, true)
			end
		end,
		Default = 1,
		Min = 0.1,
		Max = 1.5,
		Decimal = 10
	})
	DistanceCheck = NameTags:CreateToggle({
		Name = 'Distance Check',
		Function = function(callback)
			DistanceLimit.Object.Visible = callback
		end
	})
	DistanceLimit = NameTags:CreateTwoSlider({
		Name = 'Player Distance',
		DisplayName = 'Range',
		Min = 0,
		Max = 256,
		DefaultMin = 0,
		DefaultMax = 64,
		Darker = true,
		Visible = false
	})
	NameTags:CreateDivider({Text = 'Extra info'})
	Health = NameTags:CreateToggle({
		Name = 'Health',
		Function = function()
			if NameTags.Enabled then
				NameTags:Toggle(nil, true)
				NameTags:Toggle(nil, true)
			end
		end
	})
	Distance = NameTags:CreateToggle({
		Name = 'Distance',
		Function = function()
			if NameTags.Enabled then
				NameTags:Toggle(nil, true)
				NameTags:Toggle(nil, true)
			end
		end
	})
	Equipment = NameTags:CreateToggle({
		Name = 'Equipment',
		Function = function()
			if NameTags.Enabled then
				NameTags:Toggle(nil, true)
				NameTags:Toggle(nil, true)
			end
		end
	})
	Enchant = NameTags:CreateToggle({
		Name = 'Show Enchant',
		DisplayName = 'Enchantments',
		Function = function()
			if NameTags.Enabled then
				NameTags:Toggle(nil, true)
				NameTags:Toggle(nil, true)
			end
		end,
		Tooltip = 'Puts their active enchant next to the name.'
	})
	NameTags:CreateDivider({Text = 'Extras'})
	Targets = NameTags:CreateTargets({
		Players = true,
		Function = function()
			if NameTags.Enabled then
				NameTags:Toggle(nil, true)
				NameTags:Toggle(nil, true)
			end
		end
	})
	FontOption = NameTags:CreateFont({
		Name = 'Font',
		Blacklist = 'Arial',
		Function = function()
			if NameTags.Enabled then
				NameTags:Toggle(nil, true)
				NameTags:Toggle(nil, true)
			end
		end
	})
	Background = NameTags:CreateSlider({
		Name = 'Transparency',
		Function = function()
			if NameTags.Enabled then
				NameTags:Toggle(nil, true)
				NameTags:Toggle(nil, true)
			end
		end,
		Default = 0.5,
		Min = 0,
		Max = 1,
		Decimal = 10
	})
	ShowKit = NameTags:CreateToggle({
		Name = 'Show Kit',
		Function = function()
			if NameTags.Enabled then
				NameTags:Toggle(nil, true)
				NameTags:Toggle(nil, true)
			end
		end,
		Tooltip = 'Puts their kit icon next to the nametag'
	})
	Rank = NameTags:CreateToggle({
		Name = 'Show Rank',
		Function = function()
			if NameTags.Enabled then
				NameTags:Toggle(nil, true)
				NameTags:Toggle(nil, true)
			end
		end,
		Tooltip = 'Puts their ranked division icon next to the name'
	})
	--[[ Off, every name is in its team's colour; on, all of them are in the target colour below, with
	the team letter in front. Every tag is rebuilt in place for the letter, without restarting. ]]
	OverrideTarget = NameTags:CreateToggle({
		Name = 'Override target color',
		Function = function(callback)
			if Color then
				Color.Object.Visible = callback
			end
			if NameTags.Enabled and Updated[methodused] then
				task.spawn(function()
					for ent in Reference do
						pcall(Updated[methodused], ent)
					end
				end)
			end
		end,
		Tooltip = 'Every name uses the colour below instead of its team colour, with the team letter in front.'
	})
	-- Saved under its old name, so the colour chosen before carries over.
	Color = NameTags:CreateColorSlider({
		Name = 'Player Color',
		DisplayName = 'Target color',
		Function = function()
			if NameTags.Enabled and ColorFunc[methodused] then
				ColorFunc[methodused]()
			end
		end,
		Visible = false
	})
	Device = NameTags:CreateToggle({
		Name = 'Show Device',
		Function = function()
			if NameTags.Enabled then
				NameTags:Toggle(nil, true)
				NameTags:Toggle(nil, true)
			end
		end,
		Tooltip = 'Shows 🎮 / 🖥️ / 📱 depending on what they\'re playing on'
	})
	DisplayName = NameTags:CreateToggle({
		Name = 'Use Displayname',
		Function = function()
			if NameTags.Enabled then
				NameTags:Toggle(nil, true)
				NameTags:Toggle(nil, true)
			end
		end,
		Default = true
	})
	Teammates = NameTags:CreateToggle({
		Name = 'Priority Only',
		Function = function()
			if NameTags.Enabled then
				NameTags:Toggle(nil, true)
				NameTags:Toggle(nil, true)
			end
		end,
		Default = true
	})
end)
	
run(function()
	local StorageESP
	local List
	local ShowAmount
	local Background
	local Color = {}
	local Reference = {}
	-- Per billboard: the Amount watchers on the items it is showing, replaced on each refresh.
	local AmountWatch = setmetatable({}, {__mode = 'k'})
	local Folder = Instance.new('Folder')
	Folder.Parent = vape.gui
	
	local function nearStorageItem(item)
		for _, v in List.ListEnabled do
			if item:find(v) then return v end
		end
	end
	
	-- Pending: chests still waiting on their contents value, so the sweep does not start a
	-- second wait on the same one.
	local Pending = {}
	--[[ Per chest: the contents listeners its billboard was built with. They used to go only
	when the module turned off, so a chest that left and came back (streaming, a re-tag) kept
	the old pair as well, still refreshing a billboard that had been destroyed. ]]
	local ChestWatch = {}

	--[[ Every billboard here lives in Pistonware's GUI -- under CoreGui or gethui wherever the
	identity can be raised -- and every way into this module (its own thread, the chest tag,
	chest contents and Amount changes) arrives without that identity, which is what building
	into the GUI needs. So everything that builds or changes a billboard raises first, the way
	NameTags does. ]]
	local function refreshAdornee(v)
		if vape.ThreadFix then
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
		for _, connection in AmountWatch[v] or {} do
			connection:Disconnect()
		end
		AmountWatch[v] = {}

		-- Totals per item type: a chest can hold the same item in more than one stack. Amount
		-- is the attribute the game's own chest display reads.
		local amounts = {}
		for _, item in chestitems do
			amounts[item.Name] = (amounts[item.Name] or 0) + (tonumber(item:GetAttribute('Amount')) or 1)
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
				local iconOk, icon = pcall(bedwars.getIcon, {itemType = item.Name}, true)
				blockimage.Image = iconOk and type(icon) == 'string' and icon or ''
				blockimage.Parent = v.Frame
				if ShowAmount.Enabled and amounts[item.Name] > 1 then
					local amount = Instance.new('TextLabel')
					amount.Name = 'Amount'
					amount.Size = UDim2.fromOffset(31, 14)
					amount.Position = UDim2.fromOffset(0, 18)
					amount.BackgroundTransparency = 1
					amount.Text = tostring(amounts[item.Name])
					amount.TextXAlignment = Enum.TextXAlignment.Right
					amount.TextSize = 14
					loaderStyle.text(amount, 'Bold')
					-- Drawn over the icon, so it keeps an outline to read against it.
					amount.TextStrokeColor3 = Color3.new()
					amount.TextStrokeTransparency = 0.4
					amount.Parent = blockimage
				end
			end
		end
		-- Someone taking half a stack changes the count without adding or removing a child.
		if ShowAmount.Enabled then
			for _, item in chestitems do
				if alreadygot[item.Name] then
					table.insert(AmountWatch[v], item:GetAttributeChangedSignal('Amount'):Connect(function()
						refreshAdornee(v)
					end))
				end
			end
		end
		table.clear(chestitems)
	end
	
	-- Built whole and only then parented; a build that fails takes this one billboard with it
	-- and the sweep tries the chest again. A chest with no contents value yet (still
	-- streaming in) waits for the sweep the same way instead of being dropped for good.
	local function Added(v)
		if Reference[v] or Pending[v] then return end
		Pending[v] = true
		local chest = v:WaitForChild('ChestFolderValue', 3)
		Pending[v] = nil
		chest = chest and chest.Value
		if not (chest and StorageESP.Enabled and v.Parent) or Reference[v] then return end
		if vape.ThreadFix then
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
			-- The loader's box, its border shown with the background.
			local frame = Instance.new('Frame')
			frame.Size = UDim2.fromScale(1, 1)
			frame.BackgroundColor3 = Color3.fromHSV(Color.Hue, Color.Sat, Color.Value)
			frame.BackgroundTransparency = 1 - (Background.Enabled and Color.Opacity or 0)
			frame.BorderSizePixel = 0
			frame.Parent = billboard
			loaderStyle.stroke(frame).Enabled = Background.Enabled
			local layout = Instance.new('UIListLayout')
			layout.FillDirection = Enum.FillDirection.Horizontal
			layout.Padding = UDim.new(0, 4)
			layout.VerticalAlignment = Enum.VerticalAlignment.Center
			layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
			layout:GetPropertyChangedSignal('AbsoluteContentSize'):Connect(function()
				if vape.ThreadFix then
					setthreadidentity(8)
				end
				pcall(function()
					billboard.Size = UDim2.fromOffset(math.max(layout.AbsoluteContentSize.X + 4, 36), 36)
				end)
			end)
			layout.Parent = frame
			loaderStyle.corner(frame, 6)
			billboard.Parent = Folder
		end)
		if not ok then
			if billboard then
				pcall(function() billboard:Destroy() end)
			end
			return
		end
		Reference[v] = billboard
		ChestWatch[v] = {
			chest.ChildAdded:Connect(function(item)
				if table.find(List.ListEnabled, item.Name) or nearStorageItem(item.Name) then
					refreshAdornee(billboard)
				end
			end),
			chest.ChildRemoved:Connect(function(item)
				if table.find(List.ListEnabled, item.Name) or nearStorageItem(item.Name) then
					refreshAdornee(billboard)
				end
			end)
		}
		task.spawn(refreshAdornee, billboard)
	end
	
	StorageESP = vape.Categories.Render:CreateModule({
		Name = 'StorageESP',
		DisplayName = 'Chest ESP',
		Function = function(callback)
			-- Both ways: switching off clears the folder, which is in the GUI as well.
			if vape.ThreadFix then
				setthreadidentity(8)
			end
			if callback then
				-- The folder leaves the GUI while the menu is open, so its billboards stop drawing.
				local scaledGui = vape.gui:FindFirstChild('ScaledGui')
				local clickGui = scaledGui and scaledGui:FindFirstChild('ClickGui')
				if clickGui then
					Folder.Parent = (not clickGui.Visible) and vape.gui or nil
					StorageESP:Clean(clickGui:GetPropertyChangedSignal('Visible'):Connect(function()
						if vape.ThreadFix then
							setthreadidentity(8)
						end
						Folder.Parent = (not clickGui.Visible) and vape.gui or nil
					end))
				end
				StorageESP:Clean(collectionService:GetInstanceAddedSignal('chest'):Connect(Added))
				-- A broken chest used to leave its icons hanging in the air where it stood.
				StorageESP:Clean(collectionService:GetInstanceRemovedSignal('chest'):Connect(function(v)
					local billboard = Reference[v]
					if billboard then
						if vape.ThreadFix then
							setthreadidentity(8)
						end
						for _, connection in AmountWatch[billboard] or {} do
							connection:Disconnect()
						end
						AmountWatch[billboard] = nil
						for _, connection in ChestWatch[v] or {} do
							connection:Disconnect()
						end
						ChestWatch[v] = nil
						pcall(function() billboard:Destroy() end)
						Reference[v] = nil
					end
				end))
				for _, v in collectionService:GetTagged('chest') do
					task.spawn(Added, v)
				end
				-- Every second, any chest still without a billboard: one whose build failed, or
				-- whose contents had not streamed in within the first wait.
				StorageESP:Clean(task.spawn(function()
					repeat
						task.wait(1)
						for _, v in collectionService:GetTagged('chest') do
							if not (Reference[v] or Pending[v]) then
								task.spawn(Added, v)
							end
						end
					until not StorageESP.Enabled
				end))
			else
				for _, list in AmountWatch do
					for _, connection in list do
						connection:Disconnect()
					end
				end
				table.clear(AmountWatch)
				for _, list in ChestWatch do
					for _, connection in list do
						connection:Disconnect()
					end
				end
				table.clear(ChestWatch)
				table.clear(Reference)
				table.clear(Pending)
				Folder:ClearAllChildren()
				-- Switched off with the menu open: back in the GUI for the next enable.
				Folder.Parent = vape.gui
			end
		end,
		Tooltip = 'Shows which chests hold the items on your list.\nAdds an icon for each item, and the amount if you want.'
	})
	StorageESP:CreateDivider({Text = 'Extras'})
	List = StorageESP:CreateTextList({
		Name = 'Item',
		Function = function()
			for _, v in Reference do
				task.spawn(refreshAdornee, v)
			end
		end
	})
	ShowAmount = StorageESP:CreateToggle({
		Name = 'Show amount',
		Default = true,
		Function = function()
			for _, v in Reference do
				task.spawn(refreshAdornee, v)
			end
		end,
		Tooltip = 'Shows how many of each item the chest holds.'
	})
	Background = StorageESP:CreateToggle({
		Name = 'Background',
		Function = function(callback)
			if Color.Object then Color.Object.Visible = callback end
			if vape.ThreadFix then
				setthreadidentity(8)
			end
			for _, v in Reference do
				pcall(function()
					v.Frame.BackgroundTransparency = 1 - (callback and Color.Opacity or 0)
					v.Frame.UIStroke.Enabled = callback
				end)
			end
		end,
		Default = true
	})
	Color = StorageESP:CreateColorSlider({
		Name = 'Background Color',
		DefaultHue = loaderStyle.Hue,
		DefaultSat = loaderStyle.Sat,
		DefaultValue = loaderStyle.Value,
		DefaultOpacity = 1 - loaderStyle.Transparency,
		Function = function(hue, sat, val, opacity)
			if vape.ThreadFix then
				setthreadidentity(8)
			end
			for _, v in Reference do
				pcall(function()
					v.Frame.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
					-- With Background off the frame stays clear; dragging the colour used to show it.
					v.Frame.BackgroundTransparency = 1 - (Background.Enabled and opacity or 0)
				end)
			end
		end,
		Darker = true
	})
end)

run(function()
	local AutoBalloon
	
	AutoBalloon = vape.Categories.Utility:CreateModule({
		Name = 'AutoBalloon',
		Tab = 'Move',
		Function = function(callback)
			if callback then
				repeat task.wait(0.1) until store.matchState ~= 0 or (not AutoBalloon.Enabled)
				if not AutoBalloon.Enabled then return end
	
				--[[ Every block on the map, tens of thousands of them, which in one go is a hitch
				right as the match starts. A copy is walked a slice per frame instead: the live list
				swap-removes, so a block broken mid-walk could slide an unread one into a slot
				already passed. The copy is the map as it stood at this moment, as before. ]]
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
				if not AutoBalloon.Enabled then return end
	
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
		Tooltip = 'Inflates balloons to save you when you fall off the map.'
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
	}
	
	AutoKit = vape.Categories.Utility:CreateModule({
		Name = 'AutoKit',
		Tab = 'Kits',
		Function = function(callback)
			if callback then
				--[[ Every kit loop below touches Instances and fires remotes, and this
				thread is whatever enabled the module -- a profile apply on load, or a
				GUI click -- neither of which carries the elevated identity. Without it
				a remote that needs the raised identity throws on the first call and
				takes the whole kit loop with it, since nothing here is pcall'd. Set
				once for the thread rather than inside the loops: it persists across
				task.wait, and every kit function runs on this same thread. ]]
				-- Guarded: on an executor whose ceiling is below 8 a bare setthreadidentity(8)
				-- throws, and AutoKit never started at all.
				if vape.ThreadFix and not pcall(setthreadidentity, 8) then
					pcall(setthreadidentity, 7)
				end
				repeat task.wait(0.1) until store.equippedKit ~= '' and store.matchState ~= 0 or (not AutoKit.Enabled)
				if not AutoKit.Enabled then return end
				--[[ Every kit you are playing (Kit Fusion has two; see store.activeKits),
				not only the first. A kit function can be a loop that runs until AutoKit goes
				off, so all but the last get a thread of their own, raised like this one. ]]
				local kits = {}
				for _, kit in store.activeKits() do
					if AutoKitFunctions[kit] and Toggles[kit] and Toggles[kit].Enabled then
						table.insert(kits, kit)
					end
				end
				for index, kit in kits do
					if index < #kits then
						task.spawn(function()
							if vape.ThreadFix and not pcall(setthreadidentity, 8) then
								pcall(setthreadidentity, 7)
							end
							AutoKitFunctions[kit]()
						end)
					else
						AutoKitFunctions[kit]()
					end
				end
			end
		end,
		Tooltip = 'Uses your kit abilities for you.\nPick which kits it plays and whether to use legit range.'
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
		Tooltip = 'Queues you up again once the match ends.\nCan join a random mode instead of the same one.'
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
		Tooltip = 'Sends chat messages after kills and when a game ends.'
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
	local AutoReset
	
	AutoVoidDrop = vape.Categories.Inventory:CreateModule({
		Name = 'AutoVoidDrop',
		Function = function(callback)
			if callback then
				repeat task.wait(0.1) until store.matchState ~= 0 or (not AutoVoidDrop.Enabled)
				if not AutoVoidDrop.Enabled then return end
	
				-- A slice per frame over a copy, for the reason AutoBalloon gives.
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
				if not AutoVoidDrop.Enabled then return end
	
				repeat
					if entitylib.isAlive then
						local root = entitylib.character.RootPart
						if root.Position.Y < lowestpoint and (lplr.Character:GetAttribute('InflatedBalloons') or 0) <= 0 and not getItem('balloon') then
							if not OwlCheck.Enabled or not root:FindFirstChild('OwlLiftForce') then
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
	
								if dropped and AutoReset.Enabled then
									bedwars.Client:Get(remotes.ResetCharacter):SendToServer()
								end
							end
						end
					end
	
					task.wait(0.1)
				until not AutoVoidDrop.Enabled
			end
		end,
		Tooltip = 'Drops your resources when you fall into the void.\nCan hold off during an owl rescue and reset you after.'
	})
	OwlCheck = AutoVoidDrop:CreateToggle({
		Name = 'Owl check',
		Default = true,
		Tooltip = 'Holds onto your items if an owl is coming for them'
	})
	AutoReset = AutoVoidDrop:CreateToggle({
		Name = 'Auto Reset',
		Default = true,
		Tooltip = 'Resets you the moment your resources are dropped'
	})
end)
	
run(function()
	local MissileTP
	
	MissileTP = vape.Categories.Utility:CreateModule({
		Name = 'MissileTP',
		Tab = 'Combat',
		Function = function(callback)
			if callback then
				MissileTP:Toggle(nil, true)
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
		Tooltip = 'Sends a missile at the player nearest your mouse.'
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
		ExtraText = function()
			return Range and tostring(Range.Value) or nil
		end,
		Function = function(callback)
			if callback then
				local items = collection('ItemDrop', PickupRange)
				repeat
					if entitylib.isAlive then
						local localPosition = entitylib.character.RootPart.Position
						--[[ Once per pass rather than once per drop: nothing in the loop below yields,
						so neither the clock nor your health moves in between. ]]
						local now = tick()
						local pullDrops = Network.Enabled and entitylib.character.Humanoid.Health > 0
						for _, v in items do
							--[[ A stack the bank is holding for you carries PistonwareBankOwner (set on this
							client only), and is never grabbed here, whatever its ClientDropTime says: once
							that marker was missing, Network TP pulled the parked stack down to your feet
							every pass and picked it up, un-banking it behind the bank's back. ]]
							if v:GetAttribute('PistonwareBankOwner') ~= nil then continue end
							if now - (v:GetAttribute('ClientDropTime') or 0) < 2 then continue end
							if pullDrops and isnetworkowner(v) then
								v.CFrame = CFrame.new(localPosition - Vector3.new(0, 3, 0)) 
							end
							
							-- read after the pull above, which moves it
							local dropPosition = v.Position
							if (localPosition - dropPosition).Magnitude <= Range.Value then
								if Lower.Enabled and (localPosition.Y - dropPosition.Y) < (entitylib.character.HipHeight - 1) then continue end

								--[[ One request per drop per Delay, rather than one per pass.
								This loop runs at 10hz and had nothing holding it back, so
								it re-asked for every drop in range until the server got
								round to removing it -- three items on the floor is already
								1800 calls a minute against the 299 the server's rate
								limiter allows. AntiBanwave mirrors that budget and drops
								the overflow, which is why pickups died with it enabled.
								The first sighting is still instant: an unseen drop has no
								entry here, so it goes out on the pass that spots it. ]]
								if (pickups[v] or 0) >= now then continue end
								pickups[v] = now + Delay.Value

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
		Tooltip = 'Picks up dropped items from further away.\nCan pull drops to you and skip ones below your feet.'
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
		Tab = 'Combat',
		Function = function(callback)
			if callback then
				RavenTP:Toggle(nil, true)
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
		Tooltip = 'Sends a raven at the player nearest your mouse.'
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
					if v.Bind then v.Bind:SetBind({}) end
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
		Tooltip = 'Warns you when staff are in your server.\nCan also unload, requeue, swap profile or turn modules off.'
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
		Tooltip = 'Stops enemy traps from going off on you.\nCovers snap traps, landmines, teleport blocks and void portals.'
	})
	-- Each of these is a trap whose controller reports YOU stepping on it, through one remote
	-- each (snap-trap, invisible-landmine, teleport-block and void-teleport-portal controllers).
	TrapToggles.StepOnSnapTrap = TrapDisabler:CreateToggle({
		Name = 'Snap traps',
		Default = true,
		Tooltip = 'Trapper snap traps.'
	})
	TrapToggles.TriggerInvisibleLandmine = TrapDisabler:CreateToggle({
		Name = 'Landmines',
		Default = true,
		Tooltip = 'Invisible landmines.'
	})
	TrapToggles.StepOnTeleportBlock = TrapDisabler:CreateToggle({
		Name = 'Teleport blocks',
		Tooltip = 'Teleport blocks. This also stops the ones your own team places from moving you.'
	})
	TrapToggles.StepOnVoidPortal = TrapDisabler:CreateToggle({
		Name = 'Void portals',
		Tooltip = 'Void portals. This also stops your own from moving you.'
	})
end)
	
run(function()
	vape.Categories.World:CreateModule({
		Name = 'Anti-AFK',
		Tab = 'Utility',
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
		Tooltip = 'Prevents you from getting kicked for being idle.'
	})
end)
	
run(function()
	local AutoSuffocate
	local Range
	local LimitItem
	local targetResults = {}
	
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
				until not AutoSuffocate.Enabled
			end
		end,
		Tooltip = 'Boxes in nearby players who are already half walled in.\nUses the block you hold, or your wool if allowed.'
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
	local SwitchBack
	local old, event
	-- The slot you were on before the first swap, the tool slot swapped to, and when a block
	-- was last hit, so Switch back can put your hand back once you stop mining.
	local previous, switchedTo, lastHit, returning = nil, nil, 0, false
	
	local function switchHotbarItem(block)
		if not block or block:GetAttribute('NoBreak') or block:GetAttribute('Team'..(lplr:GetAttribute('Team') or 0)..'NoBreak') then return end
		-- Not everything you can hit has block meta; indexing .block.breakType off one that
		-- does not threw inside the game's own break call.
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
	
	AutoTool = vape.Categories.World:CreateModule({
		Name = 'AutoTool',
		Function = function(callback)
			if callback then
				previous, switchedTo, lastHit, returning = nil, nil, 0, false
				event = Instance.new('BindableEvent')
				AutoTool:Clean(event)
				AutoTool:Clean(event.Event:Connect(function()
					contextActionService:CallFunction('block-break', Enum.UserInputState.Begin, newproxy(true))
				end))
				old = bedwars.BlockBreaker.hitBlock
				bedwars.BlockBreaker.hitBlock = function(self, maid, raycastparams, ...)
					lastHit = os.clock()
					local block = self.clientManager:getBlockSelector():getMouseInfo(1, {ray = raycastparams})
					if switchHotbarItem(block and block.target and block.target.blockInstance or nil) then return end
					return old(self, maid, raycastparams, ...)
				end
				-- Back to what you were holding once the hits stop -- but only while you are still
				-- on the tool it picked, so a slot you changed yourself is left alone.
				AutoTool:Clean(runService.Heartbeat:Connect(function()
					if not (SwitchBack.Enabled and previous) or returning or os.clock() - lastHit < 0.35 then return end
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
		Tooltip = 'Selects the best tool when digging.\nCan switch back to what you held once you stop mining.'
	})
	SwitchBack = AutoTool:CreateToggle({
		Name = 'Switch back',
		DisplayName = 'Switch back when done',
		Tooltip = 'Puts back what you were holding once you stop mining.'
	})
end)
	
run(function()
	local BedProtector
	local Layers
	-- Set while a build is running, so switching it on again mid-build does not start a second.
	local building = false

	--[[ Never used as a wall: they are blocks by meta, but a defense made of TNT is a trap for
	whoever holds the bed, and a cannon is not a wall at all. ]]
	local SKIP_BLOCKS = {tnt = true, siege_tnt = true, cannon = true}

	--[[ Placed at the game's normal pace, one block per 1 / CpsConstants.BLOCK_PLACE_CPS
	(12 a second), read here -- at load, before FastPlace can change it -- so FastPlace has no
	say over this module.

	The pace is not optional. Every placement goes through the game's BlockCpsController, which
	cancels, without a word, any block that comes less than half an interval after the last
	one. A layer sent in one burst had all but its first block thrown away that way: the build
	went up one block per retry, and how much of it got through depended on what FastPlace had
	the interval set to. Timed off the controller's own lastPlaceTimestamp, every block lands. ]]
	local PLACE_INTERVAL = 1 / 12
	pcall(function()
		local cps = tonumber(require(replicatedStorage.TS['shared-constants']).CpsConstants.BLOCK_PLACE_CPS)
		if cps and cps > 0 then
			PLACE_INTERVAL = 1 / cps
		end
	end)

	-- Until a normal interval has passed since the last block anything placed.
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

	--[[ Every grid cell the bed occupies -- both of them.

	The old wall was a pyramid centred on bed.Position, which is ONE cell: the bed's origin.
	A bed is two cells long (the beds block handler turns the second one with the bed's
	rotation), so the half that is not the origin sat at the edge of the shape with its end
	and part of its top left open. That is the uncovered end in the screenshot. The game's own
	handler says which cells a bed holds, so the defense is built around exactly those. ]]
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

	--[[ Layer `layer` of the shell: every cell exactly that many steps (up or sideways, never
	down) from the NEAREST bed cell. Layer 1 is the blocks touching the bed -- its sides and
	its top -- and each layer after it covers every face of the one inside, corners included,
	so no layer leaves a gap for the next to miss.

	Sorted bottom-up, so every block goes in with something under or beside it to sit on. ]]
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

	--[[ The block for a cell in `layer`: that layer's own type while it lasts, then whatever is
	left. Each type used to own exactly one layer, so a stack running out part way through left
	the rest of that layer empty even with other blocks still in the inventory. ]]
	local function pickBlock(blocks, layer)
		for i = math.min(layer, #blocks), #blocks do
			if getItem(blocks[i][1]) then return blocks[i][1] end
		end
		for i = math.min(layer, #blocks) - 1, 1, -1 do
			if getItem(blocks[i][1]) then return blocks[i][1] end
		end
	end

	BedProtector = vape.Categories.World:CreateModule({
		Name = 'BedProtector',
		Function = function(callback)
			if not callback or building then return end
			local bed = getBedNear()
			if not bed then
				notif('BedProtector', 'Unable to locate bed', 5)
				BedProtector:Toggle()
				return
			end

			local blocks = getBlocks()
			if #blocks == 0 then
				notif('BedProtector', 'No blocks to build with', 5)
				BedProtector:Toggle()
				return
			end

			--[[ Layers is a setting now. It used to be one layer per block TYPE in the
			inventory: wool alone built one, and wool, stone, wood, glass and obsidian built five
			-- a mound that spent every block you had and took an age to go up. Strongest blocks
			still go against the bed. ]]
			local cells = getBedCells(bed)
			local plan = {}
			for layer = 1, Layers.Value do
				plan[layer] = getLayer(cells, layer)
			end

			building = true
			local inFlight = 0
			-- Fire-and-forget, counted until the server answers: placeBlock returns only once
			-- its call to the server has. It used to be called straight, so every block waited
			-- a full round trip before the next was even sent.
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
						if not BedProtector.Enabled then return end
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
					--[[ Judged on the server's answers, not on the block store the moment a
					block is sent: the game drops a predicted copy in straight away and takes it
					back if the server refuses, so a pass judged early saw a finished wall with
					holes about to open in it. ]]
					local deadline = os.clock() + 1.5
					repeat
						task.wait()
					until inFlight <= 0 or os.clock() > deadline
					task.wait()
				end
			end)
			building = false

			-- What is still open after every pass, and the likely reason, rather than a
			-- defense with holes in it and nothing said.
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

			if BedProtector.Enabled then
				BedProtector:Toggle()
			end
		end,
		Tooltip = 'Walls your bed in with the strongest blocks you have.'
	})
	Layers = BedProtector:CreateSlider({
		Name = 'Layers',
		Min = 1,
		Max = 4,
		Default = 2,
		Tooltip = 'How many layers deep to build. The strongest blocks go against the bed.'
	})
end)
	
run(function()
	local ChestSteal
	local Range
	local Open
	local Skywars
	local Delay
	local Steal
	local LootRange
	local Deposit
	local DepositRange
	local StolenWithin
	local Delays = {}
	-- Paces the deposit sweep off the same slider the loot passes use. Without it a full
	-- inventory is thirty-odd remotes every tenth of a second.
	local nextDeposit = 0
	-- What Steal has taken and when. Deposit only banks what is still inside the Stolen
	-- Within window, so your own gear is never swept up by standing near the chest.
	local Stash = {}
	--[[ Also consulted by the tail of scoreChestItem, where an item with no mechanical meta
	at all lands. A kit item is exactly that shape -- the raven's whole entry is displayName,
	sharingDisabled and an image -- so naming one here is what makes it worth taking. ]]
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

	--[[ Trap items -- snap, venom and explosive, which SkyWars chests hand out -- are blocks
	whose meta sets disableInventoryPickup. That flag is about breaking a trap once it is PLACED
	(it does not come back as an item), not about taking one out of a chest, so it does not
	stop these. ]]
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

	--[[ The gear branches below used to `return` whenever an item wasn't a strict upgrade,
	which is why things like a wood_bow got left sitting in the chest. Gear is tested before
	the generic branches, so a non-upgrade didn't fall through to them either -- it scored
	nil, and nil means "leave it". Carrying any bow at all made every bow in the map
	invisible to the module; the same went for swords, tools and armour.

	A chest stealer should take everything it can actually carry. The priority is there to
	decide the ORDER items come out in, not whether to bother with them, so the upgrade
	tests now only add a bonus on top of a base score. What still refuses an item is limited
	to the three real blockers: no item meta, a block the game won't let you pick up, and a
	stack that is already full. ]]
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
			-- bestValue is gathered outside the improvement test now: a tool that beats
			-- nothing you carry still needs a base score that reflects how good it is.
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

		--[[ Nothing mechanical in the meta at all, so every branch above fell through.

		This used to end in an implicit nil, which reads as "leave it", and kit items are
		precisely the shape that reaches here:

		    [ItemType.RAVEN] = {displayName = "Raven", sharingDisabled = true, image = ...}

		No sword, no block, no projectileSource, no stack size -- so ravens were being walked
		past entirely.

		An item named in chestItemPriority is deliberate and outranks everything, upgrades
		included: a raven is worth more than a marginally better sword. Anything else still
		gets a floor rather than nil, so an item a future update adds and this list has never
		heard of is taken instead of ignored. ]]
		--[[ Clear of every gear branch, which is not a small number: those scale with the
		item's own stat before UPGRADE_BONUS is added, so a damage-55 sword upgrade already
		reaches ~1.66m. Five million leaves room for whatever the next update's numbers look
		like without having to revisit this. ]]
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

	-- `taken` collects what actually left the chest, stamped with the time. Only the Steal
	-- path passes one -- ordinary looting has nothing to deposit afterwards.
	--[[ Whatever the server currently has us observing, if anything.

	It matters because SetObservedChest(nil) is what the client turns into a ChestClear
	dispatch, and ChestClear is what empties the open Chest panel. Un-observing a chest the
	player is actually looking at leaves every item still in it but nothing on screen. ]]
	local function observedFolder()
		local character = lplr.Character
		local observed = character and character:FindFirstChild('ObservedChestFolder')
		return observed and observed.Value or nil
	end

	--[[ Your own storage is not loot: in GUI Check mode the open chest is whatever you
	opened, personal chest included, and without this the loot pass pulls straight back out
	whatever Deposit just put in, re-stashes it, and the two trade the same items forever.

	Matched by NAME, not by parentage. Every inventory-backed folder lives under
	ReplicatedStorage.Inventories -- ordinary chests and team crates as much as your own --
	so "is it in Inventories" refuses everything and stops the module dead. Only the three
	folders keyed to your own username are yours. ]]
	local function isOwnStorage(folder)
		if not folder then return false end
		local inventories = replicatedStorage:FindFirstChild('Inventories')
		if not inventories or folder.Parent ~= inventories then return false end

		local name = folder.Name
		return name == lplr.Name
			or name == lplr.Name .. '_personal'
			or name == lplr.Name .. '_smelter'
	end

	--[[ Whose crate is it.

	game-player-util's getTeamId is literally `player:GetAttribute("Team")`, and the game
	compares block teams to player teams the same way everywhere -- player-render-controller
	does `v:GetAttribute("Team") ~= Players.LocalPlayer:GetAttribute("Team")` -- so the
	attribute pair is the right test.

	Compared through tonumber as well as raw: an attribute stored as a string on one side
	and a number on the other is unequal to Lua while naming the same team. ]]
	local function sameTeam(a, b)
		if a == nil or b == nil then return false end
		if a == b then return true end
		local na = tonumber(a)
		return na ~= nil and na == tonumber(b)
	end

	--[[ A team crate carries BOTH the `team-crate` tag and the ordinary `chest` tag:

	    u22[ItemType.TEAM_CRATE] = {block = {collectionServiceTags = {"chest", "team-crate"}}}

	which is how our own crate was being emptied even with Steal off. The team check lived
	only in the Steal pass; the plain chest loop iterates everything tagged `chest` inside
	Range and never asked whose it was. Asking here covers both paths at once.

	A crate with no Team attribute belongs to nobody and stays fair game. An UNKNOWN local
	team is the opposite -- our own Team has not replicated for the first moments of a
	round, and while it is nil every crate on the map reads as an enemy's, so the very first
	pass would empty our own. Unknown means leave every crate alone. ]]
	local function isFriendlyCrate(block)
		local crateTeam = block:GetAttribute('Team')
		if crateTeam == nil then return false end

		local myTeam = lplr:GetAttribute('Team')
		if myTeam == nil then return true end

		return sameTeam(crateTeam, myTeam)
	end

	-- The GUI path is handed a folder rather than a block, and the Team attribute lives on
	-- the block -- so the crate that owns the folder has to be found before its team can be
	-- read. Cheap: there are only ever a handful of crates on a map.
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

	local function lootChest(chest, taken)
		chest = chest and chest.Value or nil
		if not chest or (Delays[chest] or 0) >= tick() then return end
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
			Delays[chest] = tick() + Delay.Value
			return
		end

		Delays[chest] = tick() + Delay.Value
		local inventory = bedwars.Client:GetNamespace('Inventory')
		local setObservedChest = inventory:Get('SetObservedChest')
		local chestGetItem = inventory:Get('ChestGetItem')

		-- Already the open chest (GUI Check mode passes exactly that): the server has it
		-- observed, so opening it again is a no-op and closing it afterwards is the bug --
		-- it blanks the panel the player is reading. Only chests we opened get closed.
		local alreadyOpen = chest == observedFolder()
		if not alreadyOpen then
			local observed = pcall(function()
				setObservedChest:SendToServer(chest)
			end)
			if not observed then return end
		end

		local firstItem = true
		while #accessories > 0 do
			-- The module can be switched off mid-chest, and a chest can be broken or
			-- emptied by someone else while we are waiting between items.
			if not ChestSteal.Enabled then break end

			if firstItem then
				firstItem = false
			else
				-- Delay paces the items too, not just the chests. Skipped before the first
				-- one, so a chest is not held up before anything has been taken from it.
				task.wait(Delay.Value)
				if not (ChestSteal.Enabled and chest.Parent) then break end
			end

			local bestIndex = getBestChestItem(accessories, chest, profile)
			if not bestIndex then break end
			local item = table.remove(accessories, bestIndex)
			-- Gone while we waited: taken by someone else, or the chest was emptied.
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
	
	--[[ Steal: the same looting, pointed at the enemy team's crate, plus the half that
	makes raiding one worth doing -- emptying your inventory into your own personal chest
	between trips so the next trip has room.

	It goes through lootChest rather than grabbing everything blindly, so the priority
	ordering and the stack-size limits apply here too: a crate raid that fills your
	inventory with the first thing it sees is a crate raid that leaves the diamonds
	behind. ]]
	local function inventoryRemote(name)
		return bedwars.Client:GetNamespace('Inventory'):Get(name)
	end

	local function personalInventory()
		local inventories = replicatedStorage:FindFirstChild('Inventories')
		return inventories and inventories:FindFirstChild(lplr.Name .. '_personal') or nil
	end

	--[[ Deposit banks only what Steal recently took, inside the Stolen Within window.

	The window is what makes the toggle safe to leave on: an entry that has aged out is
	dropped rather than deposited, so walking past your own chest with a sword you have
	been carrying all game does not bank it. It also bounds the retry -- an item the
	server never actually handed over stops being chased once it ages out. ]]
	--[[ One worker, walking the stash until it empties.

	The previous shape drained the stash into a snapshot and fired every ChestGiveItem as
	its own spawned call, relying on failures being re-queued and picked up by some later
	pass. That made success a matter of timing: the server routinely refuses an item that
	is still mid-move out of the chest it was just taken from -- a `false` reply is normal,
	not a rejection -- and between the drain and the re-queue the stash reads as empty, so
	the pass that would have retried bails out instead.

	Now nothing leaves the stash until the server has actually taken it, the sweep retries
	in place until the window closes, and `depositing` keeps two sweeps from firing
	overlapping calls for the same tool. It runs in one spawned thread so the sequential
	CallServers never park the module's own loop. ]]
	local depositing = false

	local function depositAll()
		if depositing then return end

		local inventory = personalInventory()
		if not inventory then return end

		local window = StolenWithin.Value
		local now = tick()
		for index = #Stash, 1, -1 do
			if now - Stash[index].Time > window then
				table.remove(Stash, index)
			end
		end
		if #Stash == 0 then return end

		depositing = true
		task.spawn(function()
			local chestGiveItem = inventoryRemote('ChestGiveItem')
			local index = 1

			while index <= #Stash do
				if not (ChestSteal.Enabled and Deposit.Enabled) then break end

				local entry = Stash[index]
				if tick() - entry.Time > StolenWithin.Value then
					table.remove(Stash, index)
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
					table.remove(Stash, index)
					-- Back to the front: an item that would not go a moment ago often will
					-- once another has moved, and the ones behind it are the older ones.
					index = 1
				else
					-- Left in place. It is either still replicating into the inventory or
					-- still mid-move out of the chest; both clear on their own, and the
					-- window is what stops this going round forever.
					index += 1
				end

				-- Same Delay as the chest side: one item per tick of it, whether it went in
				-- or has to be tried again.
				task.wait(Delay.Value)
			end

			depositing = false
		end)
	end

	--[[ Found two ways, because the two sources disagree and only one of them is a
	runtime fact.

	The match server tags the block `personal-chest` -- that is the tag AutoSteal collects
	and it demonstrably works. The lobby dump shows no such tag, only a script folder by
	that name, and its ChestController recognises the block by NAME off the ordinary
	`chest` tag instead. Reading the dump alone is what led to dropping the tag, and
	dropping it is why nothing was ever found in range.

	Taking both costs one extra collection and means neither being wrong sinks it. ]]
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

	--[[ GUI Check reads the ScreenGui rather than asking the AppController.

	bedwars.AppController is the app-controller module's exported CLASS, not the instance
	Flamework hands out -- chest-controller resolves the real one as
	Flamework.resolveDependency("@easy-games/game-core:client/controllers/app-controller@AppController")
	-- so isAppOpen is being called on the wrong table. An error thrown there takes the
	whole ChestSteal loop with it, which is why nothing ran at all while GUI Check was on,
	deposit included.

	The app parents a ScreenGui named ChestApp into PlayerGui while it is open, which is
	the same fact observable without resolving anything. The old call stays as a fallback
	for a build that does not name it that way, but pcall'd this time. ]]
	local function chestAppOpen()
		local playerGui = lplr:FindFirstChildOfClass('PlayerGui')
		local app = playerGui and playerGui:FindFirstChild('ChestApp')
		-- Left parented but disabled is not open.
		if app then return app.Enabled ~= false end

		local ok, open = pcall(function()
			return bedwars.AppController:isAppOpen('ChestApp')
		end)
		return (ok and open) and true or false
	end

	local function stealPass(crates, localPosition)
		for _, crate in crates do
			if isFriendlyCrate(crate) then continue end
			if (localPosition - crate.Position).Magnitude <= LootRange.Value then
				lootChest(crate:FindFirstChild('ChestFolderValue'), Stash)
			end
		end
	end

	local function depositPass(chests, personalChests, localPosition)
		-- Paced before the checks, not after, so the logging below runs at the Delay rate
		-- rather than ten times a second.
		if tick() < nextDeposit then return end
		nextDeposit = tick() + Delay.Value

		local chest, distance = nearestPersonalChest(chests, personalChests, localPosition)
		if not chest or distance > DepositRange.Value then return end

		depositAll()
	end

	ChestSteal = vape.Categories.World:CreateModule({
		Name = 'ChestSteal',
		ExtraText = function()
			return Delay and math.round(Delay.Value * 1000)..'ms' or nil
		end,
		Tab = 'Utility',
		Function = function(callback)
			if callback then
				local chests = collection('chest', ChestSteal)
				-- Collected up front rather than when Steal is switched on: collection()
				-- registers tag listeners, and doing that mid-run would miss every crate
				-- already on the map.
				local crates = collection('team-crate', ChestSteal)
				local personalChests = collection('personal-chest', ChestSteal)
				--[[ The enabled check is the exit, not just the queue type: without it, toggling the
				module back off inside a test queue left this spinning at frame rate forever. ]]
				repeat task.wait(0.1) until store.queueType ~= 'bedwars_test' or (not ChestSteal.Enabled)
				if not ChestSteal.Enabled then return end
				if (not Skywars.Enabled) or store.queueType:find('skywars') then
					repeat
						if entitylib.isAlive and store.matchState ~= 2 then
							local localPosition = entitylib.character.RootPart.Position
							-- Resolved once: both the loot branch and the deposit below ask
							-- the same question, and with GUI Check off the answer is always
							-- yes without touching PlayerGui at all.
							local guiOpen = (not Open.Enabled) or chestAppOpen()

							if Open.Enabled then
								if guiOpen then
									local observed = lplr.Character and lplr.Character:FindFirstChild('ObservedChestFolder')
									-- Opening our own crate by hand must not empty it either.
									if not folderIsFriendlyCrate(crates, observed and observed.Value) then
										lootChest(observed, Stash)
									end
								end
							else
								for _, v in chests do
									-- Team crates are in here too, tagged `chest` alongside
									-- `team-crate`, so our own has to be skipped by name of
									-- team rather than left to the Steal pass.
									if isFriendlyCrate(v) then continue end
									if (localPosition - v.Position).Magnitude <= Range.Value then
										lootChest(v:FindFirstChild('ChestFolderValue'), Stash)
									end
								end

								-- Kept inside the range branch: taking from a crate you have
								-- not opened is exactly what GUI Check is there to stop.
								if Steal.Enabled then
									stealPass(crates, localPosition)
								end
							end

							-- Outside the branch so it runs in both modes, but still behind
							-- GUI Check: with that on, nothing happens until a chest is
							-- actually open. What was breaking it before was not this gate,
							-- it was chestAppOpen throwing and killing the whole loop.
							if Deposit.Enabled and guiOpen then
								depositPass(chests, personalChests, localPosition)
							end
						end
						-- The loop itself runs off the slider too, so nothing is left
						-- pacing on a hardcoded number.
						task.wait(Delay.Value)
					until not ChestSteal.Enabled
				end
			else
				--[[ Keyed by chest folder, which is destroyed with the chest -- without this
				the table holds a reference to every chest looted this session. ]]
				table.clear(Delays)
				table.clear(Stash)
				nextDeposit = 0
				-- The sweep exits on its own once the toggles go, but the flag has to be
				-- cleared here or a re-enable finds a deposit already in progress.
				depositing = false
			end
		end,
		Tooltip = 'Pulls items out of the chests near you.\nCan also loot enemy crates and stash loot in your own chest.'
	})
	Range = ChestSteal:CreateSlider({
		Name = 'Range',
		Min = 0,
		Max = 18,
		Default = 18,
		Suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end,
		Tooltip = 'How far to reach for a chest.'
	})
	Delay = ChestSteal:CreateSlider({
		Name = 'Delay',
		-- Floors at zero: Delay is per-ITEM now, not per-chest, so the old 0.2 minimum was
		-- pacing something far smaller than it was chosen for. task.wait(0) still yields a
		-- frame, so the bottom of the slider is as fast as the round trips allow and no
		-- faster.
		Min = 0,
		Max = 3,
		Default = 0.5,
		Decimal = 10,
		Suffix = function(val) return 's' end,
		Tooltip = 'Wait between every action - item, chest and deposit.'
	})
	Steal = ChestSteal:CreateToggle({
		Name = 'Steal',
		Function = function()
			-- Guarded: the toggle's Function fires once while the options are still being
			-- built, before the slider below exists.
			if LootRange and LootRange.Object then
				LootRange.Object.Visible = Steal.Enabled
			end
		end,
		Tooltip = 'Also loots enemy team crates.'
	})
	LootRange = ChestSteal:CreateSlider({
		Name = 'Loot Range',
		Min = 1,
		Max = 18,
		Default = 18,
		Darker = true,
		Suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end,
		Tooltip = 'How far to reach for a crate.'
	})
	Deposit = ChestSteal:CreateToggle({
		Name = 'Deposit',
		Function = function()
			if DepositRange and DepositRange.Object then
				DepositRange.Object.Visible = Deposit.Enabled
			end
			if StolenWithin and StolenWithin.Object then
				StolenWithin.Object.Visible = Deposit.Enabled
			end
		end,
		Tooltip = 'Puts fresh loot into your personal chest.'
	})
	DepositRange = ChestSteal:CreateSlider({
		Name = 'Deposit Range',
		Min = 1,
		Max = 18,
		Default = 7.5,
		Decimal = 10,
		Darker = true,
		Suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end,
		Tooltip = 'How close to your personal chest to deposit.'
	})
	StolenWithin = ChestSteal:CreateSlider({
		Name = 'Stolen Within',
		Min = 1,
		Max = 15,
		-- Long enough to cover the walk back from an enemy crate, which ten seconds was
		-- not: the stash aged out on the way home and there was nothing left to bank.
		Default = 10,
		Decimal = 10,
		Darker = true,
		Suffix = function(val) return 's' end,
		Tooltip = 'Only deposits loot taken this recently.'
	})
	if LootRange.Object then
		LootRange.Object.Visible = Steal.Enabled
	end
	if DepositRange.Object then
		DepositRange.Object.Visible = Deposit.Enabled
	end
	if StolenWithin.Object then
		StolenWithin.Object.Visible = Deposit.Enabled
	end
	Open = ChestSteal:CreateToggle({
		Name = 'GUI Check',
		Tooltip = 'Only acts on the chest you have open.'
	})
	Skywars = ChestSteal:CreateToggle({
		Name = 'Only Skywars',
		Function = function()
			if ChestSteal.Enabled then
				ChestSteal:Toggle(nil, true)
				ChestSteal:Toggle(nil, true)
			end
		end,
		Default = true,
		Tooltip = 'Stays off outside Skywars.'
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
					Schematica:Toggle(nil, true)
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
		Tooltip = 'Saves your builds to a file and rebuilds them for you.\nShows a see-through preview while it places the blocks.'
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
	local TargetPriority

	local function hasTarget()
		return priorityTarget({
			Part = 'RootPart',
			Range = Range.Value,
			Players = Targets.Players.Enabled,
			NPCs = Targets.NPCs.Enabled,
			Wallcheck = Targets.Walls.Enabled
		}, TargetPriority) ~= nil
	end
	
	ArmorSwitch = vape.Categories.Inventory:CreateModule({
		Name = 'ArmorSwitch',
		Function = function(callback)
			if callback then
				if Mode.Value == 'Toggle' then
					repeat
						local state = hasTarget()
	
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
					ArmorSwitch:Toggle(nil, true)
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
		Tooltip = 'Swaps your armor on and off for baiting.\nWears it only near enemies, or flips it with a keybind.'
	})
	Mode = ArmorSwitch:CreateDropdown({
		Name = 'Mode',
		List = {'Toggle', 'On Key'}
	})
	Targets = ArmorSwitch:CreateTargets({
		Players = true,
		NPCs = true
	})
	TargetPriority = ArmorSwitch:CreateDropdown({
		Name = 'Target Priority',
		List = {'Players first', 'NPCs first', 'Closest'},
		Default = 'Players first'
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

	--[[ Only Bedwars used to mean "the queue name has bedwars in it", which shut AutoBuy off
	for good in Kit Fusion (combined_kit_to4) and Hyper Kits (overpowered): same game, same
	shop, other names. QueueMeta says which game a queue runs. ]]
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
	
	--[[ The sword line as your shop sells it: the wood one you spawn with, then from stone each
	sword's nextTier, read with your kit applied (getShopItem with the player runs the game's
	shop overrides). Ice Queen, Ember and Lumen get their kit sword straight after iron -- the
	override sets iron's nextTier to it -- and nothing after it. The fixed list put the kit
	sword in the emerald slot, after a diamond sword those kits are never offered, and with
	Tier Check on AutoBuy stopped at that diamond sword for good. ]]
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
		if currencytable[item.currency] == nil then
			local bank = store.AutoBank
			if bank and bank.GetAvailable then
				currencytable[item.currency] = bank:GetAvailable(item.currency)
			else
				local currency = getItem(item.currency)
				currencytable[item.currency] = currency and currency.amount or 0
			end
		end
		-- Any kit you are playing, the second Kit Fusion kit included.
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
			shopItem = item,
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
        if not Upgrades.Enabled then return end
        local upgrade = bedwars.TeamUpgradeMeta[upgradeType]
        local currentUpgrades = bedwars.Store:getState().Bedwars.teamUpgrades[lplr:GetAttribute('Team')] or {}
        local currentTier = (currentUpgrades[upgradeType] or 0) + 1
        local bought = false
        -- Paid in the game's team upgrade resource, not always diamonds.
        local utilOk, util = pcall(function()
            return require(replicatedStorage.TS.games.bedwars['team-upgrade']['team-upgrade-util']).TeamUpgradeUtil
        end)
        local currency = utilOk and util and util.TEAM_UPGRADE_RESOURCE or 'diamond'
    
        for i = currentTier, #upgrade.tiers do
            local tier = upgrade.tiers[i]
            if tier.availableOnlyInQueue and not table.find(tier.availableOnlyInQueue, store.queueType) then continue end
    
            if canBuy({currency = currency, price = tier.cost}, currencytable) then
                bedwars.Client:Get('RequestPurchaseTeamUpgrade'):CallServerAsync(upgradeType):andThen(function(suc)
                    if suc then
                        notif('AutoBuy', 'Bought '..(upgrade.name == 'Armor' and 'Protection' or upgrade.name)..' '..i, 3)
                    end
                end)
                currencytable[currency] -= tier.cost
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
			--[[ A tier this queue's shop does not sell comes back nil, and canBuy indexing it
			threw out of the whole AutoBuy loop -- nothing more was bought that match. ]]
			if not v then continue end
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
				if store.AutoWin and store.AutoWin.Enabled then
					notif(
						'AutoBuy',
						'AutoWin is running: AutoBuy only buys team upgrades until it stops.',
						5
					)
				end
				repeat task.wait(0.1) until store.queueType ~= 'bedwars_test' or (not AutoBuy.Enabled)
				if not AutoBuy.Enabled then return end
				if BedwarsCheck.Enabled and not isBedwarsQueue(store.queueType) then return end
	
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
						-- AutoWin buys the items itself; while it runs, AutoBuy only buys
						-- team upgrades (every item callback returns without a shop).
						local itemShop = not (store.AutoWin and store.AutoWin.Enabled) and shop or nil
						for _, tab in Callbacks do
							for _, callback in tab do
								if callback(currencytable, itemShop, upgrades) then
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
		Tooltip = 'Buys gear and upgrades when you are near a shop.\nCovers swords, armor, tools, team upgrades and your own list.'
	})
	Sword = AutoBuy:CreateToggle({
		Name = 'Buy Sword',
		Function = function(callback)
			npctick = tick()
			Functions[2] = callback and function(currencytable, shop)
				if not shop then return end
				return buyTool(store.tools.sword, swordLine(), currencytable)
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
				AutoBuy:Toggle(nil, true)
				AutoBuy:Toggle(nil, true)
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
				--[[ An entry without a usable amount is skipped rather than registered: its
				arithmetic below threw the first time the item showed up in the shop, and that
				ended the whole AutoBuy loop for the match. ]]
				if ind and tonumber(tab[3]) then
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
		ExtraText = function()
			return Health and Health.Value..'%' or nil
		end,
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
		Tooltip = 'Uses healing items and potions when you need them.\nCovers apples, speed potions and shield potions.'
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
	
	--[[ The hotbar editor and the list it opens from, in the loader's look: the editor is one of its
	boxes with the loader's buttons for slots and items, and the list is a column of those boxes
	inside the module's card. ]]
	local function slotBox(obj, radius)
		obj.BackgroundColor3 = loaderStyle.Button
		obj.BackgroundTransparency = 0
		obj.BorderSizePixel = 0
		loaderStyle.corner(obj, radius or 6)
		return loaderStyle.stroke(obj, loaderStyle.ButtonBorder, 0)
	end

	-- A menu icon where the menu's helper is there, its character where it is not.
	local function icon(parent, name, size, glyph, isButton, props)
		local ui = vape.Libraries.ui
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

	-- An item the meta no longer knows shows an empty slot rather than failing the list.
	local function itemIcon(id)
		if not id then return '' end
		local ok, image = pcall(bedwars.getIcon, {itemType = id}, true)
		return ok and type(image) == 'string' and image or ''
	end

	local function requestSave()
		if vape.RequestSave then
			vape:RequestSave()
		end
	end

	local function CreateWindow(self)
		local selectedslot = 1
		local hovered = {}
		local window = Instance.new('Frame')
		window.Name = 'HotbarGUI'
		window.Size = UDim2.fromOffset(600, 322)
		window.Position = UDim2.fromScale(0.5, 0.5)
		window.AnchorPoint = Vector2.new(0.5, 0.5)
		window.Visible = false
		window.Parent = vape.gui.ScaledGui
		loaderStyle.box(window)
		-- Nearly solid: a window to work in, not a readout over the game.
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
			vape.gui.ScaledGui.ClickGui.Visible = true
		end)
		-- The selected slot, large, with its number and a way to empty it that works by touch too.
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

		-- Writes one slot of the hotbar being edited, here and in its row in the list; nil empties it.
		local function setSlot(i, id, image)
			local obj = self.Hotbars[self.Selected]
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
		--[[ Where the image cannot be shown its stand-in is a '?', and the placeholder already says it:
		only the character is hidden, so an image that lands later still shows. ]]
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
		-- Room for the cells' borders, which the frame would otherwise clip.
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
		table.insert(vape.Windows, window)

		--[[ On a phone the HUD's scale leaves this a third of the screen with 5 px text. Sized like
		the menu window instead: to fit the screen under the top bar, up to 0.85 of full size and never
		below the HUD's scale, while Auto rescale is on. A full-size screen keeps it at 1:1. ]]
		local function fit()
			if vape.ThreadFix then
				pcall(setthreadidentity, 8)
			end
			local s = math.max(vape.guiscale and vape.guiscale.Scale or 1, 0.05)
			local camera = workspace.CurrentCamera
			local view = camera and camera.ViewportSize or Vector2.zero
			local inset = 0
			pcall(function()
				inset = guiService:GetGuiInset().Y
			end)
			local factor = 1
			if vape.Scale and vape.Scale.Enabled and view.X > 0 and view.Y > 0 then
				factor = math.max(s, math.min((view.X - 16) / 600, (view.Y - inset - 16) / 322, 0.85)) / s
			end
			zoom.Scale = factor
			-- Centred in the screen below the top bar.
			window.Position = UDim2.new(0.5, 0, 0.5, inset / 2 / s)
		end
		window:GetPropertyChangedSignal('Visible'):Connect(function()
			if window.Visible then
				fit()
			end
		end)
		if vape.guiscale then
			vape.guiscale:GetPropertyChangedSignal('Scale'):Connect(fit)
		end
		if gameCamera then
			vape:Clean(gameCamera:GetPropertyChangedSignal('ViewportSize'):Connect(fit))
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
			-- Counted in rows, not read off the layout: the layout reports pixels after both scales.
			local rows = math.ceil(count / 9)
			children.CanvasSize = UDim2.fromOffset(0, rows > 0 and rows * 51 - 1 or 0)
		end

		search:GetPropertyChangedSignal('Text'):Connect(function()
			indexSearch(search.Text)
		end)
		indexSearch('')

		-- The hotbar being edited, put into the slots when the editor opens.
		function self:RefreshWindow()
			local obj = self.Hotbars[self.Selected]
			for i = 1, 9 do
				window['Slot'..i].ImageLabel.Image = itemIcon(obj and obj.Hotbar[tostring(i)])
			end
			refreshSelected()
		end
		refreshSelected()

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
		-- As wide as the card, growing with the hotbars in it.
		local hotbarlist = Instance.new('Frame')
		hotbarlist.Name = 'HotbarList'
		hotbarlist.AutomaticSize = Enum.AutomaticSize.Y
		hotbarlist.Size = UDim2.new(1, 0, 0, 0)
		hotbarlist.BackgroundTransparency = 1
		hotbarlist.LayoutOrder = optionsettings.LayoutOrder or 0
		hotbarlist.Parent = children
		optionapi.Object = hotbarlist
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
			optionapi:AddHotbar()
			requestSave()
		end)
		optionapi.Window = CreateWindow(optionapi)

		-- The selected hotbar, the one AutoHotbar sorts to, is lit with its border at full strength.
		function optionapi:Repaint()
			for index, entry in self.Hotbars do
				local selected = index == self.Selected
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
			hint.Visible = #self.Hotbars > 0
		end

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
			-- The rows were painted against the selection before this one.
			self:Repaint()
		end

		function optionapi:AddHotbar(data)
			local hotbardata = {Hotbar = data or {}}
			table.insert(self.Hotbars, hotbardata)
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
				local ind = table.find(optionapi.Hotbars, hotbardata)
				if ind == optionapi.Selected then
					vape.gui.ScaledGui.ClickGui.Visible = false
					optionapi.Window.Visible = true
					optionapi:RefreshWindow()
				elseif ind then
					optionapi.Selected = ind
					optionapi:Repaint()
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
				local ind = table.find(self.Hotbars, hotbardata)
				if not ind then return end
				local selected = self.Hotbars[self.Selected]
				hotbar:Destroy()
				table.remove(self.Hotbars, ind)
				self.Selected = selected and table.find(self.Hotbars, selected) or 1
				self:Repaint()
				requestSave()
			end)
			self:Repaint()
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
	
	--[[ Each layout slot's item, resolved once per pass rather than once for every inventory
	item asked about it: the wool slot clones and sorts the whole inventory to answer. Only a
	dispatch changes the inventory part way through a pass, so that is where it is dropped. ]]
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
		vapeEvents.InventoryChanged.Event:Wait()
		table.clear(resolvedSlots)
	end
	
	local function sortHotbar()
		local items = (List.Hotbars[List.Selected] and List.Hotbars[List.Selected].Hotbar or {})
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
	end

	--[[ Active is cleared whatever the sort does. It used to be reset on the sort's last line,
	so anything that threw part way -- an item with no meta, a hotbar slot that is not there --
	left it set, and every later sort returned on the first line: AutoHotbar stayed on and
	never sorted again until a reinject. ]]
	local function sortCallback()
		if Active then return end
		Active = true
		pcall(sortHotbar)
		Active = false
	end
	
	AutoHotbar = vape.Categories.Inventory:CreateModule({
		Name = 'AutoHotbar',
		DisplayName = 'Inv Manager',
		Function = function(callback)
			if callback then
				task.spawn(sortCallback)
				if Mode.Value == 'On Key' then
					AutoHotbar:Toggle(nil, true)
					return
				end
	
				AutoHotbar:Clean(vapeEvents.InventoryAmountChanged.Event:Connect(sortCallback))
			end
		end,
		Tooltip = 'Sorts your items into the hotbar layout you set up.\nRuns as items change or on a key, and can clear the rest.'
	})
	List = AutoHotbar:CreateHotbarList({})
	AutoHotbar:CreateDivider({Text = 'Extras'})
	Mode = AutoHotbar:CreateDropdown({
		Name = 'Activation',
		List = {'Toggle', 'On Key'},
		Function = function()
			if AutoHotbar.Enabled then
				AutoHotbar:Toggle(nil, true)
				AutoHotbar:Toggle(nil, true)
			end
		end
	})
	Clear = AutoHotbar:CreateToggle({Name = 'Clear Hotbar'})
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
					self.startedClickTime = tick()
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
					local roact = bedwars.Roact
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
		Tooltip = 'Quickly drops your held item while you hold H or Backspace.'
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
		Tooltip = 'Plays an effect of your choice when a bed is broken.'
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
	local CleanKit
	local oldspawnorb

	local function hideEffect(obj)
		if obj.Name == 'WindWalkerEffect' and obj:IsA('GuiObject') then
			obj.Visible = false
		end
	end

	CleanKit = vape.Legit:CreateModule({
		Name = 'Clean Kit',
		Tab = 'Kits',
		Function = function(callback)
			local controller = bedwars.WindWalkerController
			if callback then
				if controller then
					oldspawnorb = rawget(controller, 'spawnOrb')
					controller.spawnOrb = function() end
				end
				-- The kit mounts its status tile only once the match spawns you, which is
				-- after a profile has already switched this on, so catch it as it appears.
				CleanKit:Clean(lplr.PlayerGui.DescendantAdded:Connect(hideEffect))
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
		Tooltip = 'Hides the Zephyr orbs and status indicator.'
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
		Tooltip = 'Replaces your crosshair with an image of your choice.'
	})
	Image = Crosshair:CreateTextBox({
		Name = 'Image',
		Placeholder = 'image id (roblox)',
		Function = function(enter)
			if enter and Crosshair.Enabled then
				Crosshair:Toggle(nil, true)
				Crosshair:Toggle(nil, true)
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
		Tooltip = 'Restyles the damage numbers that pop up on hits.\nSet the font, color, size, outline and how long they stay.'
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
		Tooltip = 'Changes how wide your camera can see.\nSet any field of view from 30 to 120.'
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

	-- Shared with NameTags, and ref-counted there: see hideGameNametags above
	local function removeGameNametags()
		hideGameNametags('fpsboost')
	end

	local function restoreGameNametags()
		showGameNametags('fpsboost')
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
		Tooltip = 'Turns off heavy effects to raise your frame rate.\nCan remove kill effects, the visualizer and game nametags.'
	})
	Kill = FPSBoost:CreateToggle({
		Name = 'Kill Effects',
		Function = function()
			if FPSBoost.Enabled then
				FPSBoost:Toggle(nil, true)
				FPSBoost:Toggle(nil, true)
			end
		end,
		Default = true
	})
	Visualizer = FPSBoost:CreateToggle({
		Name = 'Visualizer',
		Function = function()
			if FPSBoost.Enabled then
				FPSBoost:Toggle(nil, true)
				FPSBoost:Toggle(nil, true)
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
		Tooltip = 'Recolors the red highlight players get when hit.\nPick its color and how see-through it is.'
	})
	Color = HitColor:CreateColorSlider({
		Name = 'Color',
		DefaultOpacity = 0.4
	})
end)
	
run(function()
	vape.Legit:CreateModule({
		Name = 'HitFix',
		Tab = 'Combat',
		Function = function(callback)
			debug.setconstant(bedwars.SwordController.swingSwordAtMouse, 23, callback and 'raycast' or 'Raycast')
			debug.setupvalue(bedwars.SwordController.swingSwordAtMouse, 4, callback and bedwars.QueryUtil or workspace)
		end,
		Tooltip = 'Makes your sword hits land more reliably.'
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
		Tooltip = 'Restyles the BedWars hotbar and health bar.\nPick the health font and colors for both.'
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
		Tooltip = 'Plays your chosen effect when you get a final kill.\nUse any BedWars effect or Gravity, Lightning or Delete.'
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

	local function unit(value)
		return tostring(value)..' <font color="'..loaderStyle.SubHex..'">studs</font>'
	end

	ReachDisplay = vape.Legit:CreateModule({
		Name = 'Reach Display',
		Function = function(callback)
			if callback then
				repeat
					label.Text = unit(store.attackReachUpdate > os.clock() and store.attackReach or '0.00')
					task.wait(0.4)
				until not ReachDisplay.Enabled
			end
		end,
		Size = UDim2.fromOffset(100, 41),
		Tooltip = 'Shows the distance of your last hit.'
	})
	-- Kept for the profiles that save it; the face is the menu's Inter, as on the other widgets.
	ReachDisplay:CreateFont({
		Name = 'Font',
		Blacklist = 'Gotham',
		Function = function()
			if label then
				loaderStyle.text(label, 'SemiBold')
			end
		end
	})
	ReachDisplay:CreateColorSlider({
		Name = 'Color',
		DefaultHue = loaderStyle.Hue,
		DefaultSat = loaderStyle.Sat,
		DefaultValue = loaderStyle.Value,
		DefaultOpacity = 1 - loaderStyle.Transparency,
		Function = function(hue, sat, val, opacity)
			label.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
			label.BackgroundTransparency = 1 - opacity
		end
	})
	-- The loader's box, with the reading in its light grey and the unit in its secondary grey.
	label = Instance.new('TextLabel')
	label.Size = UDim2.fromScale(1, 1)
	loaderStyle.box(label)
	label.RichText = true
	label.TextSize = 15
	label.Text = unit('0.00')
	loaderStyle.text(label, 'SemiBold')
	label.Parent = ReachDisplay.Children
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
		Tab = 'Utility',
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
		Tooltip = 'Plays your own music files while you play.\nCan pulse your FOV to the beat; set the volume and pulse size.'
	})
	List = SongBeats:CreateTextList({
		Name = 'Songs',
		Placeholder = 'filepath/bpm/start'
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
	FOV = SongBeats:CreateToggle({
		Name = 'Beat FOV',
		Function = function(callback)
			if FOVValue.Object then
				FOVValue.Object.Visible = callback
			end
			if SongBeats.Enabled then
				SongBeats:Toggle(nil, true)
				SongBeats:Toggle(nil, true)
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
end)

run(function()
	local SoundChanger
	local List
	local Volume
	local HitOnly
	local MuteImpacts
	local trackedSounds = {}
	local customSounds = {}
	local capturedRegistry = {}
	local projectileSounds = {}
	local old, oldRegister, oldAudio, audioMethod

	--[[ How loud a sound plays through this module: nil leaves it untouched, 0 mutes it.
	Hit ding only wins over the list, so a listed projectile sound stays muted with it on. ]]
	local function soundMultiplier(id)
		if HitOnly and HitOnly.Enabled and projectileSounds[id] then
			return 0
		end
		if trackedSounds[id] then
			return (Volume and Volume.Value or 100) / 100
		end
	end

	-- Sound fields hold an id, a list of ids, or (hitSounds) a list of lists.
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

	--[[ Every projectile equip, draw, reload and fire sound in the game, built from the metas
	the game's own controllers read them from rather than a fixed list: a bow skin carries its
	own launch sound (projectileSourceOverrides), so naming NEW_BOW_FIRE alone left every
	skinned bow audible.

	  switching   GameSound.EQUIP_BOW -- inventory-effects-controller, on any hand change to
	              an item with a projectileSource (swords get EQUIP_SWORD, the rest
	              EQUIP_DEFAULT)
	  draw        projectileSource.chargeBeginSound (BOW_DRAW) -- projectile-source-controller
	  reload      projectileSource.reload.reloadSound (CROSSBOW_RELOAD) -- same controller
	  fire        projectileSource.launchSound (NEW_BOW_FIRE) and launchOverlaySound --
	              projectile-controller for yours, projectile-effects-controller for others'
	  impact      ProjectileMeta[name].impactSound (NEW_ARROW_IMPACT) -- the thud where an
	              arrow lands, for anyone's shot (Mute impacts)

	The ding is what projectile-effects-controller plays when YOUR shot connects: the
	projectile's (or skin's) hitSounds, falling back to GameSound.ARROW_HIT, plus
	GameSound.HEADSHOT on a headshot. Those are kept even where an id is shared with a
	muted list.

	So is any id the game also uses for something other than firing. Throwables such as the
	banana peel launch with SWORD_SWING_1, the sword controller's own swing sound, so every
	*SWING* GameSound is kept, as is any id an item or skin meta holds outside its
	projectile source. Impacts are limited to arrow projectiles for the same reason: the
	rest share FORTIFY_BLOCK, TNT_EXPLODE_1 and FIREBALL_EXPLODE with blocks and TNT. ]]
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
		if not (HitOnly and HitOnly.Enabled) then return end

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
				if MuteImpacts and MuteImpacts.Enabled
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
		-- The switch sound goes in last: nothing above may keep it.
		addSounds(projectileSounds, sounds.EQUIP_BOW)
	end

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

	--[[ The game plays everything through AudioManager now; SoundManager no longer exists in
	it, so a hook on bedwars.SoundManager (resolveSoundManager's stand-in) never saw a game
	sound -- which is why listed sounds kept playing. playAudio,
	playRandomAudio and playAudioPlayer all end in internalPlayAudio(asset, config), so that
	one hook sees every sound. Muting goes through the config's volumeMultiplier (0) rather
	than skipping the call: callers keep the playback handle it returns (the equip sound
	stops the previous one through it). Only string ids are touched -- a multiplier on a
	caller-owned AudioPlayer instance would stick to that instance. ]]
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
			-- Routing reads category/bus off the call config, and a custom id has no
			-- registered config of its own to fall back on.
			local base = type(self.audioAssetConfigs) == 'table' and self.audioAssetConfigs[asset]
			if type(base) == 'table' then
				if props.category == nil then props.category = base.category end
				if props.bus == nil then props.bus = base.bus end
			end
			asset = custom
		end
		return oldAudio(self, asset, props, ...)
	end

	SoundChanger = vape.Legit:CreateModule({
		Name = 'SoundChanger',
		Tab = 'Utility',
		Function = function(callback)
			if callback then
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

				-- resolveSoundManager's stand-in forwards playSound to AudioManager, so the
				-- script's own sounds already reach audioHook; hooking it too would scale a
				-- listed sound twice. A real SoundManager (a build that still has one) is
				-- hooked as before.
				if bedwars.SoundManager.routesToAudioManager ~= true then
					old = bedwars.SoundManager.playSound
					bedwars.SoundManager.playSound = function(self, id, ...)
						--[[ A sound nobody listed goes straight through, arguments untouched. Every
						sound the game plays passes here, and every one used to be copied into a
						table and unpacked back out -- dropping any argument after a nil on the
						way -- only to reach the few that are listed. ]]
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
		Tooltip = 'Replaces game sounds and changes how loud they are.\nCan also mute bow sounds apart from the hit ding.'
	})

	List = SoundChanger:CreateTextList({
		Name = 'Sounds',
		Placeholder = '(EQUIP_DEFAULT or EQUIP_DEFAULT/custom.mp3)',
		Function = function()
			table.clear(trackedSounds)
			table.clear(customSounds)
			local soundTable = bedwars.SoundList or bedwars.GameSound or bedwars.Sounds or {}
			for _, entry in ipairs(List.ListEnabled) do
				entry = entry:match('^%s*(.-)%s*$')
				-- A raw rbxassetid is accepted too (a skin's sound with no GameSound name to
				-- hand); it carries slashes of its own, so it is split off before the '/'.
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

	HitOnly = SoundChanger:CreateToggle({
		Name = 'Hit ding only',
		Function = function(callback)
			if MuteImpacts and MuteImpacts.Object then
				MuteImpacts.Object.Visible = callback
			end
			buildProjectileSounds()
		end,
		Tooltip = 'Mutes every projectile switch, draw, reload and fire sound (skins included)\nand keeps the ding and headshot sound when your shot lands.'
	})

	MuteImpacts = SoundChanger:CreateToggle({
		Name = 'Mute impacts',
		Default = true,
		Visible = false,
		Darker = true,
		Function = function()
			buildProjectileSounds()
		end,
		Tooltip = 'Also mutes the thud where an arrow lands.'
	})
	-- Follow the saved state of Hit ding only; a toggle's Function only runs on a change.
	if MuteImpacts.Object then
		MuteImpacts.Object.Visible = HitOnly.Enabled
	end
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
	
	--[[ Topbar Position. The BedWars top bar -- its row of buttons, the Settings menu that drops
	from them and, in a match, the scores and timer beside them -- sits at the right of the strip
	Roblox leaves free along the top of the screen. Middle centres that whole row on the screen
	instead. The game's own app draws it and moves it again whenever its size changes, so each
	move of the game's is kept (it is where Default puts it back) and the row is centred again
	straight after. ]]
	local TopbarPosition
	local topbar = {
		Original = setmetatable({}, {__mode = 'k'}),
		Placed = setmetatable({}, {__mode = 'k'}),
		Watched = setmetatable({}, {__mode = 'k'}),
		Connections = {}
	}

	function topbar.middle()
		return UICleanup ~= nil and UICleanup.Enabled and TopbarPosition ~= nil and TopbarPosition.Value == 'Middle'
	end

	-- Several changes in one frame (a resize moves and resizes everything) place it once.
	function topbar.queue()
		if topbar.Queued then return end
		topbar.Queued = true
		task.defer(function()
			topbar.Queued = false
			if topbar.middle() then
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

	function topbar.place()
		local playerGui = lplr:FindFirstChildOfClass('PlayerGui')
		local appGui = playerGui and playerGui:FindFirstChild('TopBarAppGui')
		local buttons = appGui and appGui:FindFirstChild('TopBarApp')
		local camera = workspace.CurrentCamera
		if not (buttons and buttons:IsA('GuiObject') and camera) then return end
		topbar.watch(appGui)
		topbar.watch(buttons)
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
		--[[ The mobile Pistonware button follows the buttons, 7 px to their left, so its place in the
		row is kept clear: the scores and timer stop short of it rather than running under it. ]]
		local vapeButton = vape.VapeButton
		local reserve = (vapeButton and vapeButton.Parent) and math.max(vapeButton.AbsoluteSize.X, 32) + 7 or 0
		local width = buttons.AbsoluteSize.X + reserve + (statsWidth > 0 and statsWidth + 8 or 0)
		local left, area = appGui.AbsolutePosition.X, appGui.AbsoluteSize.X
		if area <= 0 then return end
		--[[ Centred on the screen, but kept inside the strip Roblox leaves free so it never runs under
		Roblox's buttons. That strip is TopbarInset where the client reports one; TopBarAppGui itself
		covers the whole screen. ]]
		local low, high = left, left + area
		pcall(function()
			local inset = guiService.TopbarInset
			if inset.Width > 0 then
				low, high = inset.Min.X, inset.Max.X
			end
		end)
		local start = math.clamp(camera.ViewportSize.X / 2 - width / 2, low, math.max(high - width, low))
		local right = start + width
		topbar.move(buttons, appGui, right)
		if statsWidth > 0 then
			topbar.move(stats, statsGui, start + statsWidth)
		end
		-- The Settings menu hangs from the right end of the buttons, as it does by default.
		for _, child in appGui:GetChildren() do
			if child ~= buttons and child:IsA('GuiObject') and topbar.origin(child).X == UDim.new(1, -12) then
				topbar.move(child, appGui, right)
			end
		end
	end

	-- Back where the game last put each piece, unless the game has moved it itself since.
	function topbar.restore()
		for _, connection in topbar.Connections do
			connection:Disconnect()
		end
		table.clear(topbar.Connections)
		table.clear(topbar.Watched)
		topbar.Hooked = false
		for object, original in topbar.Original do
			if object.Parent and object.Position == topbar.Placed[object] then
				object.Position = original
			end
		end
		table.clear(topbar.Original)
		table.clear(topbar.Placed)
	end

	function topbar.refresh()
		if not topbar.middle() then
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
			topbar.refresh()
		end,
		Tooltip = 'Tidies up the BedWars HUD and removes clutter.\nCovers the health bar, hotbar, kill feed, player list, queue card and top bar.'
	})
	TopbarPosition = UICleanup:CreateDropdown({
		Name = 'Topbar Position',
		List = {'Default', 'Middle'},
		Function = function()
			topbar.refresh()
		end,
		Tooltip = 'Where the BedWars top bar sits: on the right (Default) or centred at the top of the screen (Middle).'
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
		Tooltip = 'Moves and rotates the item you hold in first person.\nCan also stop it bobbing as you walk.'
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
				Viewmodel:Toggle(nil, true)
				Viewmodel:Toggle(nil, true)
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
		Tooltip = 'Plays the win effect of your choice when a match ends.\nOnly you can see it.'
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
end)

--[[ DeviceSpoofer and HideNametag used to sit inside WinEffect's block, which was never closed
until after them, so a WinEffect that failed to build took both of them down with it. ]]
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
		Tab = 'Visual',
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
		Tooltip = 'Hides the nametag over your own head.'
	})
end)

--[[ == bedwars module loader ==
Exposes shared.bedwars and loads the external obfuscatable module ]]

--[[ A superseded boot stops here, and the current one clears any loaded flag the old payload left,
so main.lua only takes the flag from this payload. ]]
if shared.vape ~= vape then return end
shared.PistonwareBedwarsLoaded = nil
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
	pathfindingService   = pathfindingService,
	virtualInputManager = virtualInputManager,

    --[[ Framework ]]
    vape                = vape,
    vapeEvents          = vapeEvents,
    entitylib           = entitylib,
    targetinfo          = targetinfo,
    prediction          = prediction,
    color               = color,
	uipallet            = uipallet,
	buffer              = pistonwareBuffer,

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
        if not suc then
            return nil, bootFailure('bedwars.local.read', res)
        end
        if type(res) ~= 'string' or res == '' then
            return nil, bootFailure('bedwars.local.missing', 'developer mode requires pistonware/games/bedwars.lua')
        end
        --[[ Compiled under the name it runs as and handed back, so the caller runs this chunk
        instead of compiling the same ~1MB a second time -- which it used to, on the game
        thread, every inject. The failure is still reported as bedwars.local.compile. ]]
        local localFunc, compileError = compileBedwarsSource(res, 'bedwars')
        if not localFunc then
            return nil, bootFailure('bedwars.local.compile', compileError)
        end
		bufferCall('print', 'bedwars.developer', 'running local games/bedwars.lua')
        return res, nil, localFunc
    end

    local lastFailure
    for attempt = 1, 4 do
        local suc, res = pcall(function()
            local protectedUrl = shared.PistonwareProtectedRawUrl
            return type(protectedUrl) == 'function' and game:HttpGet(protectedUrl(), true)
                or game:HttpGet('https://gitlab.com/pistonware/pistonware/-/raw/main/bedwars.lua', true)
        end)
        --[[ compile check: during an outage HttpGet can hand back the 503/error page as the body,
        which the ~=''/'404' tests would accept ]]
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

local bedwarsSource, bedwarsFailure, bedwarsCompiled = downloadBedwars()
if not bedwarsSource then
    local failure = bedwarsFailure or bootFailure('bedwars.download', 'no usable BedWars payload')
	bufferCall('error', failure.stage, failure.error)
    pcall(function()
        vape:CreateNotification('Pistonware', 'BedWars modules could not be loaded ('..failure.stage..'). Rejoin the game to retry.', 30, 'alert')
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
        vape:CreateNotification('Pistonware', 'Combat modules could not be loaded (bedwars.compile). Rejoin the game to retry.', 30, 'alert')
    end)
    return failure
end

        --[[ Refuse to run the payload with no key rather than let it discover that itself: a
        LuaArmor auth failure is not a soft error, it puts up a modal and KICKS the player
        out of the game. Saying so here costs them their combat modules for the round instead
        of their session, and names the actual problem. ]]
if not republishKey() then
    local failure = bootFailure('bedwars.key', 'no validated key was available for the BedWars payload')
	bufferCall('error', failure.stage, failure.error)
    pcall(function()
        vape:CreateNotification('Pistonware', 'Your key was not available when combat modules tried to load. Re-run the pistonware loader to fix this.', 30, 'alert')
    end)
    return failure
end

if shared.vape ~= vape then return end
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
