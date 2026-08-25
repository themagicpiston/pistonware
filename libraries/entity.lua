local entitylib = {
	isAlive = false,
	character = {},
	List = {},
	EntityByPlayer = {},
	EntityByCharacter = {},
	EntityIndex = {},
	Connections = {},
	PlayerConnections = {},
	EntityThreads = {},
	Running = false,
	Events = setmetatable({}, {
		__index = function(self, ind)
			local event = {
				Connections = {},
				ConnectionIndex = {}
			}

			function event:Connect(func)
				local record = {Callback = func}
				local index = #self.Connections + 1
				self.Connections[index] = record
				self.ConnectionIndex[record] = index

				return {
					Disconnect = function()
						local indexMap = self.ConnectionIndex
						if not indexMap then return end
						local current = indexMap[record]
						if not current then return end

						local last = #self.Connections
						local moved = self.Connections[last]
						self.Connections[current] = moved
						self.Connections[last] = nil
						indexMap[record] = nil
						if moved and moved ~= record then
							indexMap[moved] = current
						end
					end
				}
			end

			function event:Fire(...)
				local connections = self.Connections
				if not connections then return end
				for i = 1, #connections do
					local record = connections[i]
					if record and record.Callback then
						task.spawn(record.Callback, ...)
					end
				end
			end

			function event:Destroy()
				if not self.Connections then return end
				table.clear(self.Connections)
				table.clear(self.ConnectionIndex)
				table.clear(self)
			end

			self[ind] = event

			return self[ind]
		end
	})
}

local cloneref = cloneref or function(obj)
	return obj
end
local playersService = cloneref(game:GetService('Players'))
local inputService = cloneref(game:GetService('UserInputService'))
local lplr = playersService.LocalPlayer
local gameCamera = workspace.CurrentCamera

local debugLibrary = debug
local performanceEnabled = false
pcall(function()
	performanceEnabled = shared.PistonwareDeveloper == true and shared.PistonwarePerformance == true
end)

local performanceStats = {
	TargetScans = 0,
	TargetCandidates = 0,
	Raycasts = 0,
	RaycastFilterRebuilds = 0,
	EntityUpdates = 0,
	EntityFullRefreshes = 0,
	EntityAdds = 0,
	EntityRemoves = 0,
	NearestPlayerDistanceSq = math.huge
}

local function profileBegin(name)
	if performanceEnabled and debugLibrary and debugLibrary.profilebegin then
		debugLibrary.profilebegin(name)
	end
end

local function profileEnd()
	if performanceEnabled and debugLibrary and debugLibrary.profileend then
		debugLibrary.profileend()
	end
end

local function countStat(name, amount)
	if performanceEnabled then
		performanceStats[name] += (amount or 1)
	end
end

local function resetPerformanceStats()
	for name in performanceStats do
		performanceStats[name] = name == 'NearestPlayerDistanceSq' and math.huge or 0
	end
end

entitylib.Performance = {
	Stats = performanceStats,
	SetEnabled = function(_, enabled)
		performanceEnabled = enabled == true
	end,
	Reset = resetPerformanceStats,
	Snapshot = function()
		return table.clone(performanceStats)
	end
}

local function getMousePosition()
	if inputService.TouchEnabled then
		return gameCamera.ViewportSize / 2
	end

	return inputService.GetMouseLocation(inputService)
end

local function loopClean(tbl)
	for i, v in tbl do
		if type(v) == 'table' then
			loopClean(v)
		end

		tbl[i] = nil
	end
end

local function waitForChildOfType(obj, name, timeout, prop)
	local checktick = tick() + timeout
	local returned
	repeat
		returned = prop and obj[name] or obj:FindFirstChildOfClass(name)
		if returned or checktick < tick() then break end
		task.wait()
	until false
	return returned
end

entitylib.targetCheck = function(entity)
	if entity.TeamCheck then
		return entity:TeamCheck()
	end
	if entity.NPC then return true end
	if not lplr.Team then return true end
	if not entity.Player.Team then return true end
	if entity.Player.Team ~= lplr.Team then return true end
	return #entity.Player.Team:GetPlayers() == #playersService:GetPlayers()
end

entitylib.getUpdateConnections = function(entity)
	local humanoid = entity.Humanoid
	return {
		humanoid:GetPropertyChangedSignal('Health'),
		humanoid:GetPropertyChangedSignal('MaxHealth')
	}
end

entitylib.isVulnerable = function(entity)
	return entity.Health > 0 and not entity.Character.FindFirstChildWhichIsA(entity.Character, 'ForceField')
end

entitylib.getEntityColor = function(entity)
	entity = entity.Player
	return entity and tostring(entity.TeamColor) ~= 'White' and entity.TeamColor.Color or nil
end

local raycastFilter = {}
local raycastFilterVersion = 0
local raycastFilterBuiltVersion = -1
local raycastListSize = -1
local customRaycastCache = setmetatable({}, {__mode = 'k'})

local function markRaycastFilterDirty()
	raycastFilterVersion += 1
end

local function rebuildRaycastFilter()
	local count = 0
	if gameCamera then
		count += 1
		raycastFilter[count] = gameCamera
	end
	local character = lplr.Character
	if character then
		count += 1
		raycastFilter[count] = character
	end
	for _, entity in entitylib.List do
		if entity.Targetable and entity.Character then
			count += 1
			raycastFilter[count] = entity.Character
		end
	end
	for index = count + 1, #raycastFilter do
		raycastFilter[index] = nil
	end

	entitylib.IgnoreObject.FilterDescendantsInstances = raycastFilter
	raycastFilterBuiltVersion = raycastFilterVersion
	countStat('RaycastFilterRebuilds')
end

local function customIgnoreChanged(cache, ignoretable)
	local count = 0
	local changed = cache.Count < 0
	for _, object in ignoretable do
		count += 1
		if cache.Values[count] ~= object then
			changed = true
		end
	end
	if cache.Count ~= count then
		changed = true
	end
	return changed, count
end

local function getRaycastParams(ignoreobject)
	local listSize = #entitylib.List
	if listSize ~= raycastListSize then
		raycastListSize = listSize
		markRaycastFilterDirty()
	end
	if typeof(ignoreobject) ~= 'table' then
		if typeof(ignoreobject) == 'Instance' then
			return ignoreobject
		end
		if raycastFilterBuiltVersion ~= raycastFilterVersion then
			rebuildRaycastFilter()
		end
		return entitylib.IgnoreObject
	end

	local cache = customRaycastCache[ignoreobject]
	if not cache then
		cache = {
			Params = RaycastParams.new(),
			Filter = {},
			Values = {},
			Count = -1,
			BaseVersion = -1
		}
		cache.Params.RespectCanCollide = true
		customRaycastCache[ignoreobject] = cache
	end

	local customChanged, customCount = customIgnoreChanged(cache, ignoreobject)
	if cache.BaseVersion ~= raycastFilterVersion or customChanged then
		if raycastFilterBuiltVersion ~= raycastFilterVersion then
			rebuildRaycastFilter()
		end

		local count = 0
		for _, object in raycastFilter do
			count += 1
			cache.Filter[count] = object
		end
		for _, object in ignoreobject do
			count += 1
			cache.Filter[count] = object
		end
		for index = count + 1, #cache.Filter do
			cache.Filter[index] = nil
		end
		local valueIndex = 0
		for _, object in ignoreobject do
			valueIndex += 1
			cache.Values[valueIndex] = object
		end
		for index = customCount + 1, #cache.Values do
			cache.Values[index] = nil
		end

		cache.Count = customCount
		cache.BaseVersion = raycastFilterVersion
		cache.Params.FilterDescendantsInstances = cache.Filter
		countStat('RaycastFilterRebuilds')
	end

	return cache.Params
end

entitylib.IgnoreObject = RaycastParams.new()
entitylib.IgnoreObject.RespectCanCollide = true
entitylib.Wallcheck = function(origin, position, ignoreobject)
	profileBegin('Pistonware.RaycastVisibility')
	countStat('Raycasts')
	local result = workspace.Raycast(workspace, origin, (position - origin), getRaycastParams(ignoreobject))
	profileEnd()
	return result
end

entitylib.MarkRaycastFilterDirty = markRaycastFilterDirty

local candidateBuffer = {}
local candidateCapacity = 0

local function getCandidate(index)
	local candidate = candidateBuffer[index]
	if not candidate then
		candidate = {}
		candidateBuffer[index] = candidate
		candidateCapacity = math.max(candidateCapacity, index)
	end
	return candidate
end

local function clearCandidateBuffer()
	for index = 1, candidateCapacity do
		local candidate = candidateBuffer[index]
		candidate.Entity = nil
		candidate.Magnitude = nil
		candidate.DistanceSq = nil
		candidate.Target = nil
	end
end

local function defaultCandidateBefore(first, second)
	if first.Target ~= second.Target then
		return first.Target
	end
	return first.DistanceSq < second.DistanceSq
end

local function insertCandidate(count, candidate, limit)
	if limit and count >= limit then
		if not defaultCandidateBefore(candidate, candidateBuffer[count]) then
			return count
		end
	else
		count += 1
	end

	local index = count
	while index > 1 and defaultCandidateBefore(candidate, candidateBuffer[index - 1]) do
		candidateBuffer[index] = candidateBuffer[index - 1]
		index -= 1
	end
	candidateBuffer[index] = candidate
	return count
end

local function finishQuery(settings, result)
	table.clear(settings)
	profileEnd()
	return result
end

local function entityPartIsEligible(entity, settings, partName)
	if not settings.Players and entity.Player then return end
	if not settings.NPCs and entity.NPC then return end
	if not entity.Targetable then return end
	local part = entity[partName]
	if not part or not entitylib.isVulnerable(entity) then return end
	return part
end

entitylib.getEntityState = function(entity)
	return entitylib.targetCheck(entity)
end

entitylib.updateEntity = function(entity, notify)
	local oldTargetable = entity.Targetable
	local targetable, friend, target = entitylib.getEntityState(entity)
	local changed = entity.Targetable ~= targetable or entity.Friend ~= friend or entity.Target ~= target
	entity.Targetable = targetable
	entity.Friend = friend
	entity.Target = target
	if oldTargetable ~= targetable then
		markRaycastFilterDirty()
	end
	if changed then
		countStat('EntityUpdates')
		if notify then
			entitylib.Events.EntityUpdated:Fire(entity)
		end
	end
	return changed
end

entitylib.EntityMouse = function(entitysettings)
	profileBegin('Pistonware.TargetAcquire')
	countStat('TargetScans')
	if not entitylib.isAlive then
		return finishQuery(entitysettings)
	end

	local mouseLocation = entitysettings.MouseOrigin or getMousePosition()
	local range = entitysettings.Range or math.huge
	local rangeSq = range * range
	local partName = entitysettings.Part
	local bestEntity, bestDistanceSq = nil, math.huge
	local bestTarget, bestTargetDistanceSq = nil, math.huge

	if not entitysettings.Sort and not entitysettings.Wallcheck then
		for _, entity in entitylib.List do
			local part = entityPartIsEligible(entity, entitysettings, partName)
			if not part then continue end
			local position, visible = gameCamera.WorldToViewportPoint(gameCamera, part.Position)
			if not visible then continue end
			local dx = mouseLocation.X - position.X
			local dy = mouseLocation.Y - position.Y
			local distanceSq = dx * dx + dy * dy
			if distanceSq > rangeSq then continue end
			countStat('TargetCandidates')
			if entity.Target then
				if distanceSq < bestTargetDistanceSq then
					bestTarget, bestTargetDistanceSq = entity, distanceSq
				end
			elseif distanceSq < bestDistanceSq then
				bestEntity, bestDistanceSq = entity, distanceSq
			end
		end
		return finishQuery(entitysettings, bestTarget or bestEntity)
	end

	if entitysettings.Sort then
		local sortingTable = {}
		for _, entity in entitylib.List do
			local part = entityPartIsEligible(entity, entitysettings, partName)
			if not part then continue end
			local position, visible = gameCamera.WorldToViewportPoint(gameCamera, part.Position)
			if not visible then continue end
			local dx = mouseLocation.X - position.X
			local dy = mouseLocation.Y - position.Y
			local distanceSq = dx * dx + dy * dy
			if distanceSq > rangeSq then continue end
			countStat('TargetCandidates')
			sortingTable[#sortingTable + 1] = {
				Entity = entity,
				Magnitude = entity.Target and -1 or math.sqrt(distanceSq)
			}
		end
		table.sort(sortingTable, entitysettings.Sort)
		for _, candidate in sortingTable do
			if not entitysettings.Wallcheck or not entitylib.Wallcheck(entitysettings.Origin, candidate.Entity[partName].Position, entitysettings.Wallcheck) then
				table.clear(sortingTable)
				return finishQuery(entitysettings, candidate.Entity)
			end
		end
		table.clear(sortingTable)
		return finishQuery(entitysettings)
	end

	local candidateCount = 0
	for _, entity in entitylib.List do
		local part = entityPartIsEligible(entity, entitysettings, partName)
		if not part then continue end
		local position, visible = gameCamera.WorldToViewportPoint(gameCamera, part.Position)
		if not visible then continue end
		local dx = mouseLocation.X - position.X
		local dy = mouseLocation.Y - position.Y
		local distanceSq = dx * dx + dy * dy
		if distanceSq > rangeSq then continue end
		countStat('TargetCandidates')
		local candidate = getCandidate(candidateCount + 1)
		candidate.Entity = entity
		candidate.DistanceSq = distanceSq
		candidate.Target = entity.Target and true or false
		candidateCount = insertCandidate(candidateCount, candidate)
	end
	for index = 1, candidateCount do
		local candidate = candidateBuffer[index]
		if not entitylib.Wallcheck(entitysettings.Origin, candidate.Entity[partName].Position, entitysettings.Wallcheck) then
			local result = candidate.Entity
			clearCandidateBuffer()
			return finishQuery(entitysettings, result)
		end
	end
	clearCandidateBuffer()
	return finishQuery(entitysettings)
end

entitylib.EntityPosition = function(entitysettings)
	profileBegin('Pistonware.TargetAcquire')
	countStat('TargetScans')
	if not entitylib.isAlive then
		return finishQuery(entitysettings)
	end

	local localPosition = entitysettings.Origin or entitylib.character.HumanoidRootPart.Position
	local range = entitysettings.Range or math.huge
	local rangeSq = range * range
	local partName = entitysettings.Part
	local bestEntity, bestDistanceSq = nil, math.huge
	local bestTarget, bestTargetDistanceSq = nil, math.huge

	if not entitysettings.Sort and not entitysettings.Wallcheck then
		for _, entity in entitylib.List do
			local part = entityPartIsEligible(entity, entitysettings, partName)
			if not part then continue end
			local delta = part.Position - localPosition
			local distanceSq = delta:Dot(delta)
			if distanceSq > rangeSq then continue end
			countStat('TargetCandidates')
			if entity.Target then
				if distanceSq < bestTargetDistanceSq then
					bestTarget, bestTargetDistanceSq = entity, distanceSq
				end
			elseif distanceSq < bestDistanceSq then
				bestEntity, bestDistanceSq = entity, distanceSq
			end
		end
		return finishQuery(entitysettings, bestTarget or bestEntity)
	end

	if entitysettings.Sort then
		local sortingTable = {}
		for _, entity in entitylib.List do
			local part = entityPartIsEligible(entity, entitysettings, partName)
			if not part then continue end
			local delta = part.Position - localPosition
			local distanceSq = delta:Dot(delta)
			if distanceSq > rangeSq then continue end
			countStat('TargetCandidates')
			sortingTable[#sortingTable + 1] = {
				Entity = entity,
				Magnitude = entity.Target and -1 or math.sqrt(distanceSq)
			}
		end
		table.sort(sortingTable, entitysettings.Sort)
		for _, candidate in sortingTable do
			if not entitysettings.Wallcheck or not entitylib.Wallcheck(localPosition, candidate.Entity[partName].Position, entitysettings.Wallcheck) then
				table.clear(sortingTable)
				return finishQuery(entitysettings, candidate.Entity)
			end
		end
		table.clear(sortingTable)
		return finishQuery(entitysettings)
	end

	local candidateCount = 0
	for _, entity in entitylib.List do
		local part = entityPartIsEligible(entity, entitysettings, partName)
		if not part then continue end
		local delta = part.Position - localPosition
		local distanceSq = delta:Dot(delta)
		if distanceSq > rangeSq then continue end
		countStat('TargetCandidates')
		local candidate = getCandidate(candidateCount + 1)
		candidate.Entity = entity
		candidate.DistanceSq = distanceSq
		candidate.Target = entity.Target and true or false
		candidateCount = insertCandidate(candidateCount, candidate)
	end
	for index = 1, candidateCount do
		local candidate = candidateBuffer[index]
		if not entitylib.Wallcheck(localPosition, candidate.Entity[partName].Position, entitysettings.Wallcheck) then
			local result = candidate.Entity
			clearCandidateBuffer()
			return finishQuery(entitysettings, result)
		end
	end
	clearCandidateBuffer()
	return finishQuery(entitysettings)
end

entitylib.NearestDistanceSq = function(settings)
	profileBegin('Pistonware.Proximity')
	if not entitylib.isAlive then
		profileEnd()
		return math.huge
	end

	local origin = settings and settings.Origin or entitylib.character.HumanoidRootPart.Position
	local includePlayers = not settings or settings.Players ~= false
	local includeNPCs = settings and settings.NPCs == true
	local requireTargetable = not settings or settings.Targetable ~= false
	local requireVulnerable = settings and settings.Vulnerable == true
	local nearest = math.huge
	for _, entity in entitylib.List do
		if (entity.Player and includePlayers) or (entity.NPC and includeNPCs) then
			if (not requireTargetable or entity.Targetable) and (not requireVulnerable or entitylib.isVulnerable(entity)) then
				local root = entity.RootPart
				if root then
					local delta = root.Position - origin
					local distanceSq = delta:Dot(delta)
					if distanceSq < nearest then
						nearest = distanceSq
					end
				end
			end
		end
	end
	if performanceEnabled then
		performanceStats.NearestPlayerDistanceSq = nearest
	end
	profileEnd()
	return nearest
end

entitylib.AllPosition = function(entitysettings)
	local returned = entitysettings.Output or {}
	if entitysettings.Output then
		table.clear(returned)
	end
	profileBegin('Pistonware.TargetAcquire')
	countStat('TargetScans')
	if not entitylib.isAlive then
		return finishQuery(entitysettings, returned)
	end

	local localPosition = entitysettings.Origin or entitylib.character.HumanoidRootPart.Position
	local range = entitysettings.Range or math.huge
	local rangeSq = range * range
	local partName = entitysettings.Part
	local limit = entitysettings.Limit
	local boundedLimit = limit and limit < math.huge and math.max(1, limit) or nil

	if entitysettings.Sort then
		local sortingTable = {}
		for _, entity in entitylib.List do
			local part = entityPartIsEligible(entity, entitysettings, partName)
			if not part then continue end
			local delta = part.Position - localPosition
			local distanceSq = delta:Dot(delta)
			if distanceSq > rangeSq then continue end
			countStat('TargetCandidates')
			sortingTable[#sortingTable + 1] = {
				Entity = entity,
				Magnitude = entity.Target and -1 or math.sqrt(distanceSq)
			}
		end
		table.sort(sortingTable, entitysettings.Sort)
		for _, candidate in sortingTable do
			if not entitysettings.Wallcheck and boundedLimit and #returned >= boundedLimit then break end
			if entitysettings.Wallcheck and entitylib.Wallcheck(localPosition, candidate.Entity[partName].Position, entitysettings.Wallcheck) then continue end
			returned[#returned + 1] = candidate.Entity
			if limit and #returned >= limit then break end
		end
		table.clear(sortingTable)
		return finishQuery(entitysettings, returned)
	end

	local candidateCount = 0
	for _, entity in entitylib.List do
		local part = entityPartIsEligible(entity, entitysettings, partName)
		if not part then continue end
		local delta = part.Position - localPosition
		local distanceSq = delta:Dot(delta)
		if distanceSq > rangeSq then continue end
		countStat('TargetCandidates')
		local candidate = getCandidate(candidateCount + 1)
		candidate.Entity = entity
		candidate.DistanceSq = distanceSq
		candidate.Target = entity.Target and true or false
		candidateCount = insertCandidate(candidateCount, candidate, entitysettings.Wallcheck and nil or boundedLimit)
	end
	for index = 1, candidateCount do
		local candidate = candidateBuffer[index]
		if entitysettings.Wallcheck and entitylib.Wallcheck(localPosition, candidate.Entity[partName].Position, entitysettings.Wallcheck) then continue end
		returned[#returned + 1] = candidate.Entity
		if limit and #returned >= limit then break end
	end
	clearCandidateBuffer()
	return finishQuery(entitysettings, returned)
end

entitylib.getEntity = function(char)
	local entity = entitylib.EntityByPlayer[char] or entitylib.EntityByCharacter[char]
	local index = entity and entitylib.EntityIndex[entity]
	if entity and ((not index and entity == entitylib.character) or (index and entitylib.List[index] == entity)) then
		return entity, index
	end

	for listIndex, candidate in entitylib.List do
		if candidate.Player == char or candidate.Character == char then
			entitylib.EntityIndex[candidate] = listIndex
			if candidate.Player then
				entitylib.EntityByPlayer[candidate.Player] = candidate
			end
			if candidate.Character then
				entitylib.EntityByCharacter[candidate.Character] = candidate
			end
			return candidate, listIndex
		end
	end
	return nil
end

entitylib.addEntity = function(char, plr, teamfunc, spawntime)
	if not char or entitylib.EntityByCharacter[char] or entitylib.EntityThreads[char] then return end

	entitylib.EntityThreads[char] = task.spawn(function()
		local hum = waitForChildOfType(char, 'Humanoid', 10)
		local humrootpart = hum and waitForChildOfType(hum, 'RootPart', workspace.StreamingEnabled and 9e9 or 10, true)
		local head = char:WaitForChild('Head', 10) or humrootpart

		if hum and humrootpart then
			local entity = {
				Connections = {},
				Character = char,
				Health = hum.Health,
				Head = head,
				Humanoid = hum,
				HumanoidRootPart = humrootpart,
				HipHeight = hum.HipHeight + (humrootpart.Size.Y / 2) + (hum.RigType == Enum.HumanoidRigType.R6 and 2 or 0),
				MaxHealth = hum.MaxHealth,
				NPC = plr == nil,
				Player = plr,
				RootPart = humrootpart,
				SpawnTime = spawntime or 0,
				TeamCheck = teamfunc
			}
			entitylib.EntityByCharacter[char] = entity
			if plr then
				entitylib.EntityByPlayer[plr] = entity
			end

			if plr == lplr then
				entitylib.character = entity
				entitylib.isAlive = true
				markRaycastFilterDirty()
				entitylib.Events.LocalAdded:Fire(entity)
			else
				entitylib.updateEntity(entity)

				for _, connection in entitylib.getUpdateConnections(entity) do
					table.insert(entity.Connections, connection:Connect(function()
						entity.Health = hum.Health
						entity.MaxHealth = hum.MaxHealth
						entitylib.Events.EntityUpdated:Fire(entity)
					end))
				end

				local index = #entitylib.List + 1
				entitylib.List[index] = entity
				entitylib.EntityIndex[entity] = index
				markRaycastFilterDirty()
				countStat('EntityAdds')
				entitylib.Events.EntityAdded:Fire(entity)
			end
			--[[table.insert(entity.Connections, char.ChildRemoved:Connect(function(part)
				if (part == humrootpart or part == hum or part == head) then
					local found = char:FindFirstChild(part.Name)
					if found then
						if part == humrootpart then
							entity.HumanoidRootPart = found
							entity.RootPart = found
							humrootpart = found
							return
						elseif part == head then
							entity.Head = found
							head = found
							return
						end
					end
					entitylib.removeEntity(char, plr == lplr)
				end
			end))]]
		end

		entitylib.EntityThreads[char] = nil
	end)
end

entitylib.removeEntity = function(char, isLocal)
	if isLocal then
		if entitylib.isAlive then
			local entity = entitylib.character
			entitylib.isAlive = false
			for _, v in entity.Connections do
				v:Disconnect()
			end
			table.clear(entity.Connections)
			if entity.Character then
				entitylib.EntityByCharacter[entity.Character] = nil
			end
			if entity.Player then
				entitylib.EntityByPlayer[entity.Player] = nil
			end
			markRaycastFilterDirty()
			countStat('EntityRemoves')
			entitylib.Events.LocalRemoved:Fire(entity)
			--[[ table.clear(entitylib.character) ]]
		end

		return
	end

	if char then
		if entitylib.EntityThreads[char] then
			task.cancel(entitylib.EntityThreads[char])
			entitylib.EntityThreads[char] = nil
		end

		local entity, index = entitylib.getEntity(char)
		if entity and index then
			for _, v in entity.Connections do
				v:Disconnect()
			end

			table.clear(entity.Connections)
			local lastIndex = #entitylib.List
			local moved = entitylib.List[lastIndex]
			entitylib.List[index] = moved
			entitylib.List[lastIndex] = nil
			if moved and moved ~= entity then
				entitylib.EntityIndex[moved] = index
			end
			entitylib.EntityIndex[entity] = nil
			if entity.Character then
				entitylib.EntityByCharacter[entity.Character] = nil
			end
			if entity.Player then
				entitylib.EntityByPlayer[entity.Player] = nil
			end
			markRaycastFilterDirty()
			countStat('EntityRemoves')
			entitylib.Events.EntityRemoved:Fire(entity)
		end
	end
end

entitylib.refreshEntity = function(char, plr, spawntime)
	countStat('EntityFullRefreshes')
	entitylib.removeEntity(char)
	entitylib.addEntity(char, plr, nil, spawntime)
end

entitylib.addPlayer = function(plr)
	if plr.Character then
		entitylib.refreshEntity(plr.Character, plr)
	end

	entitylib.PlayerConnections[plr] = {
		plr.CharacterAdded:Connect(function(char)
			entitylib.refreshEntity(char, plr, os.clock() + 0.4)
		end),
		plr.CharacterRemoving:Connect(function(char)
			entitylib.removeEntity(char, plr == lplr)
		end),
		plr:GetPropertyChangedSignal('Team'):Connect(function()
			if plr == lplr then
				for _, entity in entitylib.List do
					entitylib.updateEntity(entity, true)
				end
			else
				local entity = entitylib.getEntity(plr)
				if entity then entitylib.updateEntity(entity, true) end
			end
		end)
	}
end

entitylib.removePlayer = function(plr)
	if entitylib.PlayerConnections[plr] then
		for _, v in entitylib.PlayerConnections[plr] do
			v:Disconnect()
		end

		table.clear(entitylib.PlayerConnections[plr])
		entitylib.PlayerConnections[plr] = nil
	end

	entitylib.removeEntity(plr)
end

entitylib.start = function()
	if entitylib.Running then
		entitylib.stop()
	end

	entitylib.Connections = {
		playersService.PlayerAdded:Connect(function(player)
			entitylib.addPlayer(player)
		end),
		playersService.PlayerRemoving:Connect(function(player)
			entitylib.removePlayer(player)
		end),
		workspace:GetPropertyChangedSignal('CurrentCamera'):Connect(function()
			gameCamera = workspace.CurrentCamera or workspace:FindFirstChildWhichIsA('Camera')
			markRaycastFilterDirty()
		end)
	}

	for _, player in playersService:GetPlayers() do
		entitylib.addPlayer(player)
	end

	entitylib.Running = true
end

entitylib.stop = function()
	for _, v in entitylib.Connections do
		v:Disconnect()
	end
	table.clear(entitylib.Connections)

	for _, v in entitylib.PlayerConnections do
		for _, v2 in v do
			v2:Disconnect()
		end
		table.clear(v)
	end

	entitylib.removeEntity(nil, true)
	for index = #entitylib.List, 1, -1 do
		local entity = entitylib.List[index]
		entitylib.removeEntity(entity.Character)
	end

	for _, thread in entitylib.EntityThreads do
		task.cancel(thread)
	end

	table.clear(entitylib.PlayerConnections)
	table.clear(entitylib.EntityThreads)
	table.clear(entitylib.EntityByPlayer)
	table.clear(entitylib.EntityByCharacter)
	table.clear(entitylib.EntityIndex)
	table.clear(entitylib.List)
	entitylib.character = {}
	markRaycastFilterDirty()
	entitylib.Running = false
end

entitylib.kill = function()
	if entitylib.Running then
		entitylib.stop()
	end

	for _, event in entitylib.Events do
		event:Destroy()
	end

	if entitylib.IgnoreObject then
		entitylib.IgnoreObject:Destroy()
	end
	loopClean(entitylib)
end

entitylib.refresh = function()
	for _, entity in entitylib.List do
		entitylib.updateEntity(entity, true)
	end
end

entitylib.start()

return entitylib
