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

			--[[ Dispatched over a copy of the list, not the list itself.

			task.spawn resumes its function INLINE on this thread, so every handler runs
			to its first yield before the next one is reached -- and a handler is free to
			connect and disconnect while the dispatch is still walking. Applying a profile
			does exactly that: it toggles a module off and straight back on for every
			option whose value differs, and the off empties that module's maid from inside
			whatever Fire happens to be running at the time.

			Disconnect swap-removes -- it moves the LAST record down into the freed slot.
			If that slot has already been passed, the record moved into it is never
			reached, so a handler that was connected when the event fired silently misses
			it. A missed EntityRemoved is a nametag with nothing left that will ever
			destroy it or move it again; a missed EntityAdded is a player who never gets
			one at all.

			The ConnectionIndex read is what makes the copy safe in the other direction: a
			handler disconnected earlier in this same dispatch is skipped rather than
			called after the fact, which is the behaviour a real signal has. ]]
			function event:Fire(...)
				local connections = self.Connections
				if not connections then return end

				local count = #connections
				if count == 0 then return end

				local snapshot = table.move(connections, 1, count, 1, table.create(count))
				local indexMap = self.ConnectionIndex
				for i = 1, count do
					local record = snapshot[i]
					if record and record.Callback and indexMap[record] then
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
local runService = cloneref(game:GetService('RunService'))
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
	TargetCacheHits = 0,
	TargetCacheRefreshes = 0,
	Raycasts = 0,
	RaycastFilterRebuilds = 0,
	EntityUpdates = 0,
	EntityFullRefreshes = 0,
	EntityAdds = 0,
	EntityRemoves = 0,
	NearestPlayerDistanceSq = math.huge
}

local killauraTelemetry = {
	Enabled = false,
	SwingCount = 0,
	ConfirmedCount = 0,
	ExpiredCount = 0,
	DroppedCount = 0,
	SwingGapCount = 0,
	HitGapCount = 0,
	ConfirmationCount = 0,
	AverageSwingGap = 0,
	AverageHitGap = 0,
	AverageConfirmationDelay = 0,
	StartedAt = nil,
	LastSwingAt = nil,
	LastHitAt = nil,
	LastTarget = nil,
	LastHitTarget = nil,
	Pending = {},
	RecentSwings = {},
	RecentHits = {}
}

local function newTelemetryHistory(window)
	return {
		Window = window,
		Times = {},
		Values = {},
		Head = 1,
		Count = 0
	}
end

local diagnostics = {
	Enabled = false,
	StartedAt = nil,
	PingAccumulator = 0,
	NextMemoryAt = 0,
	StatsService = nil,
	LastTeleported = nil,
	TeleportInitialized = false,
	Position = nil,
	Velocity = nil,
	Render = {
		Samples = newTelemetryHistory(10),
		Spikes = newTelemetryHistory(30),
		SpikeActive = false,
		LastDelta = 0,
		LifetimeMax = 0,
		LastAt = nil
	},
	Heartbeat = {
		Samples = newTelemetryHistory(10),
		Spikes = newTelemetryHistory(30),
		SpikeActive = false,
		LastDelta = 0,
		LifetimeMax = 0,
		LastAt = nil
	},
	Ping = {
		Samples = newTelemetryHistory(30),
		Spikes = newTelemetryHistory(60),
		Last = nil,
		LastAt = nil,
		LastSpikeAt = nil
	},
	Corrections = {
		Events = newTelemetryHistory(30),
		Count = 0,
		LastAt = nil,
		LastReason = nil
	},
	Memory = nil,
	Connections = {}
}

local function clearTelemetryHistory(history)
	table.clear(history.Times)
	table.clear(history.Values)
	history.Head = 1
	history.Count = 0
end

local function compactTelemetryHistory(history)
	if history.Head <= 1 then return end

	local write = 1
	for read = history.Head, history.Count do
		history.Times[write] = history.Times[read]
		history.Values[write] = history.Values[read]
		write += 1
	end
	for index = write, history.Count do
		history.Times[index] = nil
		history.Values[index] = nil
	end
	history.Count = write - 1
	history.Head = 1
end

local function pruneTelemetryHistory(history, now)
	local cutoff = now - history.Window
	while history.Head <= history.Count and history.Times[history.Head] < cutoff do
		history.Head += 1
	end

	if history.Head > 64 and history.Head > history.Count / 2 then
		compactTelemetryHistory(history)
	end
end

local function recordTelemetryHistory(history, now, value)
	history.Count += 1
	history.Times[history.Count] = now
	history.Values[history.Count] = value
	pruneTelemetryHistory(history, now)
end

local function clearTimestampList(list)
	table.clear(list)
end

local function pruneTimestampList(list, now, window)
	local cutoff = now - window
	local first = 1
	while list[first] and list[first] < cutoff do
		first += 1
	end
	if first == 1 then return end

	local write = 1
	for read = first, #list do
		list[write] = list[read]
		write += 1
	end
	for index = write, #list do
		list[index] = nil
	end
end

local function countRecentTimestamps(list, now, window)
	local cutoff = now - window
	local count = 0
	for index = #list, 1, -1 do
		if list[index] < cutoff then break end
		count += 1
	end
	return count
end

local function resetDiagnostics()
	diagnostics.StartedAt = os.clock()
	diagnostics.PingAccumulator = 0
	diagnostics.NextMemoryAt = 0
	diagnostics.LastTeleported = nil
	diagnostics.TeleportInitialized = false
	diagnostics.Position = nil
	diagnostics.Velocity = nil
	diagnostics.Memory = nil

	for _, channel in {diagnostics.Render, diagnostics.Heartbeat} do
		clearTelemetryHistory(channel.Samples)
		clearTelemetryHistory(channel.Spikes)
		channel.SpikeActive = false
		channel.LastDelta = 0
		channel.LifetimeMax = 0
		channel.LastAt = nil
	end
	clearTelemetryHistory(diagnostics.Ping.Samples)
	clearTelemetryHistory(diagnostics.Ping.Spikes)
	diagnostics.Ping.Last = nil
	diagnostics.Ping.LastAt = nil
	diagnostics.Ping.LastSpikeAt = nil
	clearTelemetryHistory(diagnostics.Corrections.Events)
	diagnostics.Corrections.Count = 0
	diagnostics.Corrections.LastAt = nil
	diagnostics.Corrections.LastReason = nil
end

local function resetKillauraTelemetry()
	killauraTelemetry.SwingCount = 0
	killauraTelemetry.ConfirmedCount = 0
	killauraTelemetry.ExpiredCount = 0
	killauraTelemetry.DroppedCount = 0
	killauraTelemetry.SwingGapCount = 0
	killauraTelemetry.HitGapCount = 0
	killauraTelemetry.ConfirmationCount = 0
	killauraTelemetry.AverageSwingGap = 0
	killauraTelemetry.AverageHitGap = 0
	killauraTelemetry.AverageConfirmationDelay = 0
	killauraTelemetry.StartedAt = os.clock()
	killauraTelemetry.LastSwingAt = nil
	killauraTelemetry.LastHitAt = nil
	killauraTelemetry.LastTarget = nil
	killauraTelemetry.LastHitTarget = nil
	table.clear(killauraTelemetry.Pending)
	clearTimestampList(killauraTelemetry.RecentSwings)
	clearTimestampList(killauraTelemetry.RecentHits)
end

local function targetCharacter(target)
	return type(target) == 'table' and target.Character or target
end

local function sameTarget(first, second)
	if first == second then return true end
	local firstCharacter = targetCharacter(first)
	local secondCharacter = targetCharacter(second)
	return firstCharacter ~= nil and firstCharacter == secondCharacter
end

local function updateTelemetryAverage(previous, count, average, now)
	if not previous then
		return now, count, average
	end

	local sample = math.max(now - previous, 0)
	count += 1
	return now, count, average + ((sample - average) / count)
end

local function pruneKillauraPending(now)
	local pending = killauraTelemetry.Pending
	for index = #pending, 1, -1 do
		if now - pending[index].SentAt > 2 then
			table.remove(pending, index)
			killauraTelemetry.ExpiredCount += 1
		end
	end
end

local function recordKillauraSwing(target, timestamp)
	if not killauraTelemetry.Enabled then return end
	timestamp = tonumber(timestamp) or os.clock()
	pruneKillauraPending(timestamp)

	killauraTelemetry.LastSwingAt, killauraTelemetry.SwingGapCount, killauraTelemetry.AverageSwingGap = updateTelemetryAverage(
		killauraTelemetry.LastSwingAt,
		killauraTelemetry.SwingGapCount,
		killauraTelemetry.AverageSwingGap,
		timestamp
	)
	killauraTelemetry.SwingCount += 1
	killauraTelemetry.LastTarget = target
	killauraTelemetry.RecentSwings[#killauraTelemetry.RecentSwings + 1] = timestamp

	local pending = killauraTelemetry.Pending
	pending[#pending + 1] = {
		Target = target,
		Character = targetCharacter(target),
		SentAt = timestamp
	}
	if #pending > 64 then
		table.remove(pending, 1)
		killauraTelemetry.DroppedCount += 1
	end
end

local function recordKillauraHit(target, timestamp)
	if not killauraTelemetry.Enabled then return end
	timestamp = tonumber(timestamp) or os.clock()
	pruneKillauraPending(timestamp)

	local pending = killauraTelemetry.Pending
	local matched
	for index = 1, #pending do
		local entry = pending[index]
		if sameTarget(entry.Target, target) or sameTarget(entry.Character, target) then
			matched = table.remove(pending, index)
			break
		end
	end
	if not matched then return end

	killauraTelemetry.LastHitAt, killauraTelemetry.HitGapCount, killauraTelemetry.AverageHitGap = updateTelemetryAverage(
		killauraTelemetry.LastHitAt,
		killauraTelemetry.HitGapCount,
		killauraTelemetry.AverageHitGap,
		timestamp
	)
	killauraTelemetry.ConfirmedCount += 1
	killauraTelemetry.ConfirmationCount += 1
	killauraTelemetry.AverageConfirmationDelay += ((math.max(timestamp - matched.SentAt, 0) - killauraTelemetry.AverageConfirmationDelay) / killauraTelemetry.ConfirmationCount)
	killauraTelemetry.LastHitTarget = matched.Target
	killauraTelemetry.RecentHits[#killauraTelemetry.RecentHits + 1] = timestamp
end

local function setKillauraTelemetryEnabled(enabled)
	killauraTelemetry.Enabled = enabled == true
	if killauraTelemetry.Enabled then
		resetKillauraTelemetry()
	else
		table.clear(killauraTelemetry.Pending)
		clearTimestampList(killauraTelemetry.RecentSwings)
		clearTimestampList(killauraTelemetry.RecentHits)
		killauraTelemetry.LastTarget = nil
		killauraTelemetry.LastHitTarget = nil
	end
end

local function getStatsService()
	if diagnostics.StatsService then return diagnostics.StatsService end
	local success, service = pcall(function()
		return game:GetService('Stats')
	end)
	if success then
		diagnostics.StatsService = service
	end
	return diagnostics.StatsService
end

local function readStatsValue(name)
	local statsService = getStatsService()
	if not statsService then return end

	local value
	pcall(function()
		local performanceStatsObject = statsService:FindFirstChild('PerformanceStats')
		local valueObject = performanceStatsObject and performanceStatsObject:FindFirstChild(name)
		if valueObject then
			value = tonumber(valueObject:GetValue())
		end
	end)
	return value
end

local function readMemoryValue()
	local memory = readStatsValue('Memory')
	if memory then return memory end

	local statsService = getStatsService()
	if not statsService then return end
	pcall(function()
		memory = tonumber(statsService:GetTotalMemoryUsageMb())
	end)
	return memory
end

local function recordDiagnosticChannel(channel, now, deltaTime, spikeThreshold)
	if type(deltaTime) ~= 'number' or deltaTime <= 0 then return end

	channel.LastAt = now
	channel.LastDelta = deltaTime
	channel.LifetimeMax = math.max(channel.LifetimeMax, deltaTime)
	recordTelemetryHistory(channel.Samples, now, deltaTime)

	if deltaTime >= spikeThreshold then
		if not channel.SpikeActive then
			recordTelemetryHistory(channel.Spikes, now, deltaTime)
		end
		channel.SpikeActive = true
	elseif deltaTime < spikeThreshold * 0.8 then
		channel.SpikeActive = false
	end
end

local function recordDiagnosticCorrection(now, reason)
	local corrections = diagnostics.Corrections
	corrections.Count += 1
	corrections.LastAt = now
	corrections.LastReason = reason
	recordTelemetryHistory(corrections.Events, now, reason)
end

local function recordDiagnosticMotion(now, deltaTime)
	local root
	if entitylib.isAlive and entitylib.character then
		root = entitylib.character.RootPart
	end

	local position, velocity
	if root then
		pcall(function()
			position = root.Position
			velocity = root.AssemblyLinearVelocity
		end)
	end

	if position and velocity then
		if diagnostics.Position and diagnostics.Velocity then
			local displacement = position - diagnostics.Position
			local expected = diagnostics.Velocity * math.min(deltaTime, 0.25)
			local correction = (displacement - expected).Magnitude
			local reversed = diagnostics.Velocity.Magnitude > 4 and displacement:Dot(diagnostics.Velocity) < 0
			if correction >= 8 and (reversed or displacement.Magnitude < 2 or diagnostics.Velocity.Magnitude < 2) then
				recordDiagnosticCorrection(now, 'motion discontinuity')
			end
		end
		diagnostics.Position = position
		diagnostics.Velocity = velocity
	else
		diagnostics.Position = nil
		diagnostics.Velocity = nil
	end

	local teleported
	pcall(function()
		teleported = lplr:GetAttribute('LastTeleported')
	end)
	if diagnostics.TeleportInitialized and diagnostics.LastTeleported ~= nil and teleported ~= nil and teleported ~= diagnostics.LastTeleported then
		recordDiagnosticCorrection(now, 'teleport signal')
	end
	diagnostics.LastTeleported = teleported
	diagnostics.TeleportInitialized = true
end

local function recordDiagnosticPing(now, value)
	if type(value) ~= 'number' or value < 0 then return end

	local ping = diagnostics.Ping
	if ping.Last and (value >= 150 or value - ping.Last >= math.max(50, ping.Last * 0.5)) then
		recordTelemetryHistory(ping.Spikes, now, value)
		ping.LastSpikeAt = now
	end
	recordTelemetryHistory(ping.Samples, now, value)
	ping.Last = value
	ping.LastAt = now
end

local function recordDiagnosticRender(deltaTime)
	if not diagnostics.Enabled then return end
	recordDiagnosticChannel(diagnostics.Render, os.clock(), deltaTime, 0.1)
end

local function recordDiagnosticHeartbeat(deltaTime)
	if not diagnostics.Enabled or type(deltaTime) ~= 'number' or deltaTime <= 0 then return end

	local now = os.clock()
	recordDiagnosticChannel(diagnostics.Heartbeat, now, deltaTime, 0.1)
	recordDiagnosticMotion(now, deltaTime)

	diagnostics.PingAccumulator += deltaTime
	if diagnostics.PingAccumulator >= 0.5 then
		diagnostics.PingAccumulator = 0
		recordDiagnosticPing(now, readStatsValue('Ping'))
	end
	if now >= diagnostics.NextMemoryAt then
		diagnostics.Memory = readMemoryValue()
		diagnostics.NextMemoryAt = now + 1
	end
end

local function stopDiagnostics()
	for _, connection in diagnostics.Connections do
		pcall(function()
			connection:Disconnect()
		end)
	end
	table.clear(diagnostics.Connections)
	diagnostics.Enabled = false
	resetDiagnostics()
end

local function startDiagnostics()
	if diagnostics.Enabled then return end
	resetDiagnostics()
	diagnostics.Enabled = true

	if runService and runService.RenderStepped and type(runService.RenderStepped.Connect) == 'function' then
		local success, connection = pcall(function()
			return runService.RenderStepped:Connect(recordDiagnosticRender)
		end)
		if success and connection then
			diagnostics.Connections[#diagnostics.Connections + 1] = connection
		end
	end
	if runService and runService.Heartbeat and type(runService.Heartbeat.Connect) == 'function' then
		local success, connection = pcall(function()
			return runService.Heartbeat:Connect(recordDiagnosticHeartbeat)
		end)
		if success and connection then
			diagnostics.Connections[#diagnostics.Connections + 1] = connection
		end
	end
end

local function historyWindowStart(history, now, window)
	pruneTelemetryHistory(history, now)
	local cutoff = now - window
	local first = history.Head
	while first <= history.Count and history.Times[first] < cutoff do
		first += 1
	end
	return first
end

local function historyCount(history, now, window)
	local first = historyWindowStart(history, now, window)
	return first <= history.Count and history.Count - first + 1 or 0
end

local function historyLatest(history, now)
	pruneTelemetryHistory(history, now)
	if history.Head > history.Count then return end
	return history.Times[history.Count], history.Values[history.Count]
end

local function numericHistoryStats(history, now, window)
	local first = historyWindowStart(history, now, window)
	if first > history.Count then
		return {Count = 0}
	end

	local values = {}
	local total = 0
	local maximum = 0
	for index = first, history.Count do
		local value = history.Values[index]
		if type(value) == 'number' then
			values[#values + 1] = value
			total += value
			maximum = math.max(maximum, value)
		end
	end
	if #values == 0 then return {Count = 0} end

	table.sort(values)
	local p95Index = math.max(1, math.ceil(#values * 0.95))
	local slowCount = math.max(1, math.ceil(#values * 0.01))
	local slowTotal = 0
	for index = #values - slowCount + 1, #values do
		slowTotal += values[index]
	end
	return {
		Count = #values,
		Average = total / #values,
		P95 = values[p95Index],
		Max = maximum,
		Low1PercentFps = 1 / (slowTotal / slowCount),
		FirstAt = history.Times[first],
		LastAt = history.Times[history.Count]
	}
end

local function numericHistoryJitter(history, now, window)
	local first = historyWindowStart(history, now, window)
	local previous
	local total = 0
	local count = 0
	for index = first, history.Count do
		local value = history.Values[index]
		if type(value) == 'number' then
			if previous then
				total += math.abs(value - previous)
				count += 1
			end
			previous = value
		end
	end
	return count > 0 and total / count or nil
end

local function snapshotKillaura(now)
	pruneKillauraPending(now)
	pruneTimestampList(killauraTelemetry.RecentSwings, now, 10)
	pruneTimestampList(killauraTelemetry.RecentHits, now, 10)

	local startedAt = killauraTelemetry.StartedAt or now
	local elapsed = math.max(now - startedAt, 0.001)
	local rollingElapsed = math.min(5, elapsed)
	local confirmed = killauraTelemetry.ConfirmedCount
	local finalized = confirmed + killauraTelemetry.ExpiredCount + killauraTelemetry.DroppedCount
	local recentHits = countRecentTimestamps(killauraTelemetry.RecentHits, now, 5)
	local recentSwings = countRecentTimestamps(killauraTelemetry.RecentSwings, now, 5)
	return {
		Enabled = killauraTelemetry.Enabled,
		StartedAt = startedAt,
		Elapsed = elapsed,
		SwingCount = killauraTelemetry.SwingCount,
		ConfirmedCount = confirmed,
		ExpiredCount = killauraTelemetry.ExpiredCount,
		DroppedCount = killauraTelemetry.DroppedCount,
		PendingCount = #killauraTelemetry.Pending,
		FinalizedCount = finalized,
		Accuracy = finalized > 0 and confirmed / finalized or nil,
		ProvisionalAccuracy = killauraTelemetry.SwingCount > 0 and confirmed / killauraTelemetry.SwingCount or nil,
		HitRate = recentHits / rollingElapsed,
		SwingRate = recentSwings / rollingElapsed,
		AverageSwingGap = killauraTelemetry.AverageSwingGap,
		AverageHitGap = killauraTelemetry.AverageHitGap,
		AverageConfirmationDelay = killauraTelemetry.AverageConfirmationDelay,
		LastTarget = killauraTelemetry.LastTarget,
		LastHitTarget = killauraTelemetry.LastHitTarget
	}
end

local function snapshotDiagnostics(now)
	if not diagnostics.Enabled then
		return {Enabled = false}
	end

	now = tonumber(now) or os.clock()
	local startedAt = diagnostics.StartedAt or now
	local elapsed = math.max(now - startedAt, 0.001)
	local renderOneSecond = numericHistoryStats(diagnostics.Render.Samples, now, 1)
	local renderWindow = numericHistoryStats(diagnostics.Render.Samples, now, 10)
	local heartbeatWindow = numericHistoryStats(diagnostics.Heartbeat.Samples, now, 10)
	local pingWindow = numericHistoryStats(diagnostics.Ping.Samples, now, 10)
	local renderCount = renderOneSecond.Count
	local fpsElapsed = math.min(1, elapsed)
	local renderFps = renderCount > 0 and renderCount / math.max(fpsElapsed, 0.001) or nil
	local _, lastRenderSpike = historyLatest(diagnostics.Render.Spikes, now)
	local _, lastHeartbeatSpike = historyLatest(diagnostics.Heartbeat.Spikes, now)
	local lastNetworkSpikeAt, lastNetworkSpike = historyLatest(diagnostics.Ping.Spikes, now)
	local lastCorrectionAt, lastCorrectionReason = historyLatest(diagnostics.Corrections.Events, now)

	return {
		Enabled = true,
		StartedAt = startedAt,
		Elapsed = elapsed,
		Render = {
			Fps = renderFps,
			FrameAverage = renderWindow.Average,
			FrameP95 = renderWindow.P95,
			FrameMax = renderWindow.Max,
			Low1PercentFps = renderWindow.Low1PercentFps,
			Samples = renderWindow.Count,
			LastDelta = diagnostics.Render.LastDelta,
			LastAt = diagnostics.Render.LastAt
		},
		Heartbeat = {
			Average = heartbeatWindow.Average,
			P95 = heartbeatWindow.P95,
			Max = heartbeatWindow.Max,
			Samples = heartbeatWindow.Count,
			LastDelta = diagnostics.Heartbeat.LastDelta,
			LastAt = diagnostics.Heartbeat.LastAt
		},
		Ping = {
			Current = diagnostics.Ping.Last,
			Average = pingWindow.Average,
			P95 = pingWindow.P95,
			Max = pingWindow.Max,
			Jitter = numericHistoryJitter(diagnostics.Ping.Samples, now, 10),
			Samples = pingWindow.Count,
			LastAt = diagnostics.Ping.LastAt
		},
		Spikes = {
			Render = historyCount(diagnostics.Render.Spikes, now, 10),
			Heartbeat = historyCount(diagnostics.Heartbeat.Spikes, now, 10),
			Network = historyCount(diagnostics.Ping.Spikes, now, 10),
			LastRender = lastRenderSpike,
			LastHeartbeat = lastHeartbeatSpike,
			LastNetwork = lastNetworkSpike,
			LastNetworkAt = lastNetworkSpikeAt
		},
		Corrections = {
			Count = diagnostics.Corrections.Count,
			Recent = historyCount(diagnostics.Corrections.Events, now, 10),
			LastAt = lastCorrectionAt,
			LastReason = lastCorrectionReason
		},
		Memory = diagnostics.Memory
	}
end

local positionCaches = {}
local positionCacheOrder = {}
local positionCacheVersion = 0
local positionCacheRangeMultiplier = 1.5
local positionCacheMinimumRadius = 20
local positionCacheLimit = 8

local function lowEndMode()
	return inputService.TouchEnabled or shared.PistonwarePerformanceMode == 'Low'
end

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
	Killaura = killauraTelemetry,
	SetEnabled = function(_, enabled)
		local previous = performanceEnabled
		performanceEnabled = enabled == true
		return previous
	end,
	IsEnabled = function()
		return performanceEnabled
	end,
	SetKillauraTelemetry = function(_, enabled)
		setKillauraTelemetryEnabled(enabled)
	end,
	StartDiagnostics = function()
		startDiagnostics()
	end,
	StopDiagnostics = function()
		stopDiagnostics()
	end,
	DiagnosticsSnapshot = function(_, now)
		return snapshotDiagnostics(now)
	end,
	KillauraSnapshot = function(_, now)
		return snapshotKillaura(tonumber(now) or os.clock())
	end,
	RecordKillauraSwing = function(_, target, timestamp)
		recordKillauraSwing(target, timestamp)
	end,
	RecordKillauraHit = function(_, target, timestamp)
		recordKillauraHit(target, timestamp)
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

-- The ForceField lookup is an engine call, and target queries make it for every candidate
-- on every frame. The answer is held for one 60 Hz frame per entity, so at high frame
-- rates it is looked up at most 60 times a second instead of once a frame. Health is a
-- plain field and is still read fresh every time.
local shieldCache = setmetatable({}, {__mode = 'k'})

entitylib.isVulnerable = function(entity)
	if not (entity.Health > 0) then return false end
	local char = entity.Character
	local now = os.clock()
	local cached = shieldCache[entity]
	if not cached then
		cached = {}
		shieldCache[entity] = cached
	elseif cached.Character == char and now - cached.At < 1 / 60 then
		return not cached.Shielded
	end
	cached.Character, cached.At = char, now
	cached.Shielded = char.FindFirstChildWhichIsA(char, 'ForceField') ~= nil
	return not cached.Shielded
end

entitylib.getEntityColor = function(entity)
	entity = entity.Player
	return entity and tostring(entity.TeamColor) ~= 'White' and entity.TeamColor.Color or nil
end

local raycastFilterVersion = 0

local function markRaycastFilterDirty()
	raycastFilterVersion += 1
end

entitylib.IgnoreObject = RaycastParams.new()
entitylib.IgnoreObject.RespectCanCollide = true
entitylib.Raycast = function(origin, direction, params)
	return workspace:Raycast(origin, direction, params)
end
-- The characters the plain wall check's filter was last built from. The filter used to be
-- rebuilt -- a fresh list, every entity walked into it, FilterDescendantsInstances
-- reassigned -- on every call, which is per candidate per frame, for a list that only
-- changes when someone spawns, dies or changes team. Now it is rebuilt only when the
-- characters that belong in it change. They are compared against the live list rather
-- than trusted to a version counter, because the game scripts build entities of their own
-- that never bump one.
local wallFilter = {Characters = {}, Count = -1, LocalCharacter = nil}

local function wallFilterCurrent()
	if wallFilter.LocalCharacter ~= lplr.Character then return false end
	local characters = wallFilter.Characters
	local count = 0
	for _, entity in entitylib.List do
		if entity.Targetable then
			count += 1
			if characters[count] ~= entity.Character then return false end
		end
	end
	return count == wallFilter.Count
end

entitylib.Wallcheck = function(origin, position, ignoreobject)
	if typeof(ignoreobject) ~= 'Instance' then
		local extra = typeof(ignoreobject) == 'table'
		if extra or not wallFilterCurrent() then
			local localCharacter = lplr.Character
			local ignorelist = {gameCamera, localCharacter}
			local characters = wallFilter.Characters
			table.clear(characters)
			for _, entity in entitylib.List do
				if entity.Targetable then
					table.insert(ignorelist, entity.Character)
					characters[#characters + 1] = entity.Character
				end
			end

			if extra then
				for _, obj in ignoreobject do
					table.insert(ignorelist, obj)
				end
				-- this filter carries the caller's extras, so the next plain check rebuilds
				wallFilter.Count = -1
			else
				wallFilter.Count = #characters
				wallFilter.LocalCharacter = localCharacter
			end

			entitylib.IgnoreObject.FilterDescendantsInstances = ignorelist
		end
		ignoreobject = entitylib.IgnoreObject
	end
	return entitylib.Raycast(origin, position - origin, ignoreobject)
end

entitylib.MarkRaycastFilterDirty = markRaycastFilterDirty

local candidateBuffer = {}
local candidateRecords = {}
local candidateCapacity = 0
local sortingBuffer, sortingRecords = {}, {}

local function getSortingRecord(index)
	local record = sortingRecords[index]
	if not record then
		record = {}
		sortingRecords[index] = record
	end
	sortingBuffer[index] = record
	return record
end

local function clearSortingBuffer(count)
	for index = 1, count do
		local record = sortingBuffer[index]
		if record then
			record.Entity = nil
			record.Magnitude = nil
		end
		sortingBuffer[index] = nil
	end
end

local function getCandidate(index)
	local candidate = candidateRecords[index]
	if not candidate then
		candidate = {}
		candidateRecords[index] = candidate
		candidateCapacity = math.max(candidateCapacity, index)
	end
	return candidate
end

local function clearCandidateBuffer()
	for index = 1, candidateCapacity do
		local candidate = candidateRecords[index]
		if candidate then
			candidate.Entity = nil
			candidate.Magnitude = nil
			candidate.DistanceSq = nil
			candidate.Target = nil
		end
		candidateBuffer[index] = nil
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

local function getPositionCacheKey(settings, partName, range)
	for _, key in positionCacheOrder do
		if key.Players == settings.Players
			and key.NPCs == settings.NPCs
			and key.Part == partName
			and key.Range == range
			and key.Origin == settings.Origin
			and key.Sort == settings.Sort
			and key.Wallcheck == settings.Wallcheck
			and key.Limit == settings.Limit then
			return key
		end
	end
	return {
		Players = settings.Players,
		NPCs = settings.NPCs,
		Part = partName,
		Range = range,
		Origin = settings.Origin,
		Sort = settings.Sort,
		Wallcheck = settings.Wallcheck,
		Limit = settings.Limit
	}
end

local function getPositionCandidates(settings, origin, range, partName, now)
	local key = getPositionCacheKey(settings, partName, range)
	local cache = positionCaches[key]
	if not cache then
		if #positionCacheOrder >= positionCacheLimit then
			local oldest = table.remove(positionCacheOrder, 1)
			positionCaches[oldest] = nil
		end
		cache = {
			Entities = {}
		}
		positionCaches[key] = cache
		positionCacheOrder[#positionCacheOrder + 1] = key
	end

	-- The list holds everything that was inside CoverageRadius of the origin it was built
	-- at, so it only answers a query of `range` while neither end can have closed the spare
	-- margin in between: we may have moved at most half of it, and the short lifetime below
	-- bounds how far a target can have moved in the other half. Reused for a full second
	-- with no check on movement, it let a player who closed in quickly stand inside the
	-- aura's range for most of a second without ever being a candidate.
	local reusable = cache.Version == positionCacheVersion
		and cache.ExpiresAt and now < cache.ExpiresAt
	if reusable and cache.CoverageRadius ~= math.huge then
		local margin = (cache.CoverageRadius - range) / 2
		local moved = origin - cache.Origin
		reusable = margin > 0 and moved:Dot(moved) <= margin * margin
	end
	if reusable then
		countStat('TargetCacheHits')
		return cache.Entities
	end

	local coverageRadius = math.max(range * positionCacheRangeMultiplier, positionCacheMinimumRadius)
	local coverageRadiusSq = coverageRadius * coverageRadius
	local candidates = cache.Entities
	table.clear(candidates)
	for _, entity in entitylib.List do
		local isPlayer = entity.Player and settings.Players
		local isNpc = entity.NPC and settings.NPCs
		if isPlayer or isNpc then
			local part = entity[partName]
			if part then
				local delta = part.Position - origin
				if coverageRadius == math.huge or delta:Dot(delta) <= coverageRadiusSq then
					candidates[#candidates + 1] = entity
				end
			end
		end
	end

	-- At the smallest margin the coverage formula produces (~6.7 studs, a 13.3 stud range)
	-- half of it is 3.3 studs, which 0.06s covers for anything slower than ~55 studs/s.
	cache.Origin = origin
	cache.CoverageRadius = coverageRadius
	cache.ExpiresAt = now + (lowEndMode() and 0.12 or 0.06)
	cache.Version = positionCacheVersion
	countStat('TargetCacheRefreshes')
	return candidates
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
		local sortingCount = 0
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
			sortingCount += 1
			local candidate = getSortingRecord(sortingCount)
			candidate.Entity = entity
			candidate.Magnitude = entity.Target and -1 or math.sqrt(distanceSq)
		end
		table.sort(sortingBuffer, entitysettings.Sort)
		for index = 1, sortingCount do
			local candidate = sortingBuffer[index]
			if not entitysettings.Wallcheck or not entitylib.Wallcheck(entitysettings.Origin, candidate.Entity[partName].Position, entitysettings.Wallcheck) then
				local result = candidate.Entity
				clearSortingBuffer(sortingCount)
				return finishQuery(entitysettings, result)
			end
		end
		clearSortingBuffer(sortingCount)
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
		local sortingCount = 0
		for _, entity in entitylib.List do
			local part = entityPartIsEligible(entity, entitysettings, partName)
			if not part then continue end
			local delta = part.Position - localPosition
			local distanceSq = delta:Dot(delta)
			if distanceSq > rangeSq then continue end
			countStat('TargetCandidates')
			sortingCount += 1
			local candidate = getSortingRecord(sortingCount)
			candidate.Entity = entity
			candidate.Magnitude = entity.Target and -1 or math.sqrt(distanceSq)
		end
		table.sort(sortingBuffer, entitysettings.Sort)
		for index = 1, sortingCount do
			local candidate = sortingBuffer[index]
			if not entitysettings.Wallcheck or not entitylib.Wallcheck(localPosition, candidate.Entity[partName].Position, entitysettings.Wallcheck) then
				local result = candidate.Entity
				clearSortingBuffer(sortingCount)
				return finishQuery(entitysettings, result)
			end
		end
		clearSortingBuffer(sortingCount)
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
	local entities = entitysettings.Cache ~= false
		and getPositionCandidates(entitysettings, localPosition, range, partName, os.clock())
		or entitylib.List

	if entitysettings.Sort then
		local sortingCount = 0
		for _, entity in entities do
			local part = entityPartIsEligible(entity, entitysettings, partName)
			if not part then continue end
			local delta = part.Position - localPosition
			local distanceSq = delta:Dot(delta)
			if distanceSq > rangeSq then continue end
			countStat('TargetCandidates')
			sortingCount += 1
			local candidate = getSortingRecord(sortingCount)
			candidate.Entity = entity
			candidate.Magnitude = entity.Target and -1 or math.sqrt(distanceSq)
		end
		table.sort(sortingBuffer, entitysettings.Sort)
		for index = 1, sortingCount do
			local candidate = sortingBuffer[index]
			if not entitysettings.Wallcheck and boundedLimit and #returned >= boundedLimit then break end
			if entitysettings.Wallcheck and entitylib.Wallcheck(localPosition, candidate.Entity[partName].Position, entitysettings.Wallcheck) then continue end
			returned[#returned + 1] = candidate.Entity
			if limit and #returned >= limit then break end
		end
		clearSortingBuffer(sortingCount)
		return finishQuery(entitysettings, returned)
	end

	local candidateCount = 0
	for _, entity in entities do
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

--[[ Records the builder thread ONLY while it is still running.

task.spawn runs the body up to its first yield before it ever returns, and the body
below has no yield at all when the character is already streamed in: WaitForChild
returns instantly for a child that exists, and waitForChildOfType breaks before its
task.wait on the first hit. So the whole build finishes -- including the
`EntityThreads[char] = nil` on its last line -- and only THEN does task.spawn hand
back a thread that is already dead, which the assignment writes straight back into
the table it just cleared.

That entry is poison. task.cancel throws on a thread that is not suspended, so the
next removeEntity for this character died on the cancel and never reached
Events.EntityRemoved -- leaving the entity in entitylib.List and every module's
per-entity state pointing at a character that had gone. Nametags parked over empty
ground came from here. The guard above compounds it: a character carrying a dead
entry can never be added again either.

Storing it only when it is genuinely suspended costs one status read. ]]
entitylib.addEntity = function(char, plr, teamfunc, spawntime)
	if not char or entitylib.EntityByCharacter[char] or entitylib.EntityThreads[char] then return end

	local builder = task.spawn(function()
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
				positionCacheVersion += 1
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
				positionCacheVersion += 1
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

	if coroutine.status(builder) ~= 'dead' then
		entitylib.EntityThreads[char] = builder
	end
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
			positionCacheVersion += 1
			markRaycastFilterDirty()
			countStat('EntityRemoves')
			entitylib.Events.LocalRemoved:Fire(entity)
			--[[ table.clear(entitylib.character) ]]
		end

		return
	end

	if char then
		--[[ Cleared BEFORE the cancel, and only cancelled while suspended: everything
		below this point -- the List removal and Events.EntityRemoved -- has to run even
		if the entry is stale, or the entity outlives its character. ]]
		local builder = entitylib.EntityThreads[char]
		if builder then
			entitylib.EntityThreads[char] = nil
			if coroutine.status(builder) == 'suspended' then
				pcall(task.cancel, builder)
			end
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
			positionCacheVersion += 1
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
		if coroutine.status(thread) == 'suspended' then
			pcall(task.cancel, thread)
		end
	end

	table.clear(entitylib.PlayerConnections)
	table.clear(entitylib.EntityThreads)
	table.clear(entitylib.EntityByPlayer)
	table.clear(entitylib.EntityByCharacter)
	table.clear(entitylib.EntityIndex)
	table.clear(entitylib.List)
	table.clear(positionCaches)
	table.clear(positionCacheOrder)
	positionCacheVersion += 1
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
