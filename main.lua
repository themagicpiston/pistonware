local pistonwareBuffer
pcall(function()
	local env = type(getgenv) == 'function' and getgenv() or nil
	local namespace = type(env) == 'table' and env.pistonware or nil
	pistonwareBuffer = type(namespace) == 'table' and namespace.buffer or nil
end)

local function bufferCall(method, event, message, details)
	local callback = type(pistonwareBuffer) == 'table' and pistonwareBuffer[method] or nil
	if type(callback) == 'function' then return callback(event, message, details) end
	if shared.PistonwareDeveloper == true then
		if method == 'warn' or method == 'error' then
			warn('[pistonware] '..tostring(message))
		else
			print('[pistonware] '..tostring(message))
		end
	end
end

local function bufferLog(event, message, details)
	return bufferCall('log', event, message, details)
end

local function bufferPrint(event, message, details)
	return bufferCall('print', event, message, details)
end

local function bufferWarn(event, message, details)
	return bufferCall('warn', event, message, details)
end

local function bufferError(event, message, details)
	return bufferCall('error', event, message, details)
end

--[[ The loader is the only supported entry point: it runs the LuaArmor key gate and publishes
script_key (which the protected bedwars.lua reads) before any of this downloads or executes.
The GUI's reinject buttons go back through the loader, and a queued teleport does the same on
the next server; the developer queued path restores loaderdev.lua first. All paths re-establish
that state before main.lua is reached, so reaching here without it means the gate was skipped.
Checked before the uninject below, so a failed check cannot tear down a working instance on its
way out. ]]
if not shared.PistonwareAuthenticated then
	bufferWarn('runtime.unauthenticated', 'not authenticated -- run the pistonware loader and enter your key')
	return
end

local release = type(shared.PistonwareRelease) == 'table' and shared.PistonwareRelease or {
	channel = 'main',
	branch = 'main',
	sourceRef = 'main',
	cacheReady = true
}

local function errorTrace(err)
	local traceback
	pcall(function()
		if debug and type(debug.traceback) == 'function' then
			traceback = debug.traceback(tostring(err), 2)
		end
	end)
	return traceback or tostring(err)
end

local function reportRuntimeError(stage, err, trace)
	local traceback = trace or errorTrace(err)
	bufferError('runtime.'..tostring(stage), err, {stage = stage, traceback = traceback})
	local reporter = shared.PistonwareTelemetry
	if type(reporter) == 'table' and type(reporter.report) == 'function' then
		pcall(function()
			reporter:report('runtime_error', tostring(err), {
				stage = stage,
				fatal = false,
					traceback = traceback
			})
		end)
	end
end

local function releaseRef()
	return release.sourceRef or release.branch or 'main'
end

local function rewriteReleaseUrl(url)
	local value = tostring(url or '')
	local ref = releaseRef()
	local adapter = shared.PistonwareRewriteUrl
	if type(adapter) == 'function' and adapter ~= rewriteReleaseUrl then
		local ok, rewritten = pcall(adapter, value)
		if ok and type(rewritten) == 'string' then return rewritten end
	end
	value = value:gsub('https://raw%.githubusercontent%.com/themagicpiston/pistonware/refs/heads/main/', function()
		return 'https://raw.githubusercontent.com/themagicpiston/pistonware/'..ref..'/'
	end)
	value = value:gsub('https://raw%.githubusercontent%.com/themagicpiston/pistonware/main/', function()
		return 'https://raw.githubusercontent.com/themagicpiston/pistonware/'..ref..'/'
	end)
	value = value:gsub('https://raw%.githubusercontent%.com/themagicpiston/pistonware/main/', function()
		return 'https://raw.githubusercontent.com/themagicpiston/pistonware/'..ref..'/'
	end)
	value = value:gsub('https://gitlab%.com/pistonware/pistonware/%-/raw/main/', function()
		return 'https://gitlab.com/pistonware/pistonware/-/raw/'..(release.branch or 'main')..'/'
	end)
	value = value:gsub('([?&]sha=)main', '%1'..ref)
	value = value:gsub('([?&]ref=)main', '%1'..ref)
	return value
end

shared.PistonwareRewriteUrl = rewriteReleaseUrl

local function projectRawUrl(path, ref)
	path = tostring(path or ''):gsub('^/', '')
	return 'https://raw.githubusercontent.com/themagicpiston/pistonware/'..(ref or releaseRef())..'/'..path
end

local function protectedRawUrl(ref)
	return 'https://gitlab.com/pistonware/pistonware/-/raw/'..(ref or release.branch or 'main')..'/bedwars.lua'
end

shared.PistonwareRawUrl = projectRawUrl
shared.PistonwareProtectedRawUrl = protectedRawUrl
shared.PistonwareChannel = release.channel or 'main'

local function cacheAllowed()
	return release.cacheReady ~= false
end

--[[ pcall'd: after a teleport shared.slinky can still point at the previous server's instance,
whose GUI and connections no longer exist. An error walking that corpse would abort main.lua
on line one and leave the queued re-injection doing nothing at all. ]]
if shared.slinky then pcall(function() shared.slinky:unload() end) end

local slinky
-- For checking a download quietly: the wrapper below alerts on every compile error.
local rawLoadstring = loadstring
local loadstring = function(...)
	local res, err = loadstring(...)
	if err and slinky then
		slinky:notify('Pistonware', 'Failed to load : '..err, 30, 'alert')
	end
	return res
end
--[[ Chunks hasContent already compiled, handed to the next loadstring of the same source under
the same name instead of being compiled a second time. hasContent compiles every cached .lua
to prove it is intact, and the caller then compiled the identical text again to run it -- for
the GUI, universal.lua and the game file that is ~1.4MB of source compiled twice on the game
thread, every inject. Consumed on use, so each entry lives from the check to the run. ]]
local validatedChunks = {}
local function takeValidatedChunk(source, name)
	for path, entry in validatedChunks do
		if entry.body == source and entry.name == name then
			validatedChunks[path] = nil
			return entry.chunk
		end
	end
	return nil
end

local function runChunk(source, name)
	local chunk = takeValidatedChunk(source, name) or loadstring(source, name)
	return chunk and chunk()
end
local queue_on_teleport = queue_on_teleport or queueonteleport
	or (syn and syn.queue_on_teleport) or (fluxus and fluxus.queue_on_teleport)
local hasQueueOnTeleport = queue_on_teleport ~= nil
queue_on_teleport = queue_on_teleport or function() end
local isfile = isfile or function(file)
	local suc, res = pcall(function()
		return readfile(file)
	end)
	return suc and res ~= nil and res ~= ''
end
local cloneref = cloneref or function(obj)
	return obj
end

local function pistonwareHttpGet(url, nocache, attempt)
	url = rewriteReleaseUrl(url)
	local adapter = shared.PistonwareDevHttpGet
	if type(adapter) == 'function' then
		return adapter(url, nocache, attempt)
	end
	return game:HttpGet(url, nocache)
end

local function pistonwareProtectedHttpGet(url, nocache, attempt)
	url = rewriteReleaseUrl(url)
	local adapter = shared.PistonwareDevProtectedHttpGet
	if type(adapter) == 'function' then
		return adapter(url, nocache, attempt)
	end
	return game:HttpGet(url, nocache)
end

local playersService = cloneref(game:GetService('Players'))

--[[ Phones and tablets. Kept for the teleport path and notifications; it no longer paces saves. ]]
local isTouchDevice = false
pcall(function()
	isTouchDevice = cloneref(game:GetService('UserInputService')).TouchEnabled and true or false
end)

--[[ Telemetry the developer build prints and the public build does not.

	Module counts and load timings are buffered for every build and mirrored into the executor
	console only in developer mode. Public failures stay in the same buffer and are available
	through getgenv().pistonware.buffer.dump().

Gated at runtime rather than at build time because main.lua is one file serving both builds.
PUBLIC_BUILD nulls shared.PistonwareDeveloper and locks it behind a metatable, so this is off
for everyone except the developer build by construction -- and the queued teleport script
carries the flag across, so it stays on for a developer through a match join. ]]
local function debugWarn(...)
	local values = {...}
	for index, value in ipairs(values) do values[index] = tostring(value) end
	bufferPrint('runtime.debug', table.concat(values, ' '))
end

--[[
	Breadcrumbs, off unless asked for:

		getgenv().PistonwareTrace = true

	The GUI keeps the same log (slinky:Trace writes into this very table) but cannot record
	anything before it is downloaded and run, and "the client died and there is no log" is
	exactly the case where that window matters. Root of the filesystem, because reinstall.lua
	deletes the pistonware folder and would take the evidence with it.
]]
local traceOn = false
pcall(function()
	traceOn = (((getgenv and getgenv().PistonwareTrace) or shared.PistonwareTrace) and true) or false
end)
shared.PistonwareTraceLines = {}
local traceLines = shared.PistonwareTraceLines
local function stage(text)
	bufferLog('runtime.stage', text)
	if not traceOn then return end
	table.insert(traceLines, text)
	if #traceLines > 200 then table.remove(traceLines, 1) end
	pcall(writefile, 'pistonware_trace.txt', table.concat(traceLines, '\n'))
end
local function heapKB()
	local kb = 0
	pcall(function() kb = gcinfo and gcinfo() or collectgarbage('count') end)
	return kb
end

--[[ A heartbeat in the trace, so the log says when the client died and not only where. Every 2 s it
rewrites one line in place with the uptime and the last 15 heap readings, so a long run costs one
small write each time. It stops once a reinject has put a fresh table in
shared.PistonwareTraceLines. ]]
if traceOn then
	local started = os.clock()
	local index
	local trend = {}
	task.spawn(function()
		while true do
			task.wait(2)
			if shared.PistonwareTraceLines ~= traceLines then return end
			local mem = heapKB()
			table.insert(trend, ('%d'):format(mem))
			if #trend > 15 then table.remove(trend, 1) end
			local text = ('alive %.1fs mem=%dKB trend=%s'):format(
				os.clock() - started, mem, table.concat(trend, ','))
			if index then
				traceLines[index] = text
				pcall(writefile, 'pistonware_trace.txt', table.concat(traceLines, '\n'))
			else
				stage(text)
				index = #traceLines
			end
		end
	end)
end

stage('main.lua running')

--[[ Returns the file's text, or false when it is missing, empty or (for a .lua) does not compile, so
callers need not read it again. Every executor's real isfile reports a zero-byte file as present,
and a download cut short by a cancel, crash or teleport would otherwise be skipped by every
cache-first route forever; treated as missing, it is repaired on the next run. A .lua is compiled
quietly under the name it runs as, and with chunkName the chunk is kept in validatedChunks for that
run. ]]
local function hasContent(path, chunkName)
	if not isfile(path) then return false end
	local ok, body = pcall(readfile, path)
	if not ok or type(body) ~= 'string' or body == '' then return false end
	if path:match('%.lua$') then
		local name = chunkName or path
		local compileOk, chunk = pcall(rawLoadstring, body, name)
		local valid = compileOk and type(chunk) == 'function'
		if valid and chunkName then
			validatedChunks[path] = {body = body, name = name, chunk = chunk}
		end
		return valid and body
	end
	return body
end

--[[ Returns a file's text, from the cache when hasContent accepts it, otherwise downloaded and written
to disk. The developer loader takes the request when it is there; a chunk it compiled under
chunkName goes into validatedChunks, not compiled twice. Developer mode never replaces a file that
has something in it: one that does not compile stops the load on its compile error.

bedwars.lua comes from the GitLab repo's root though it caches under games/; the rest comes from
GitHub. Raw hosts intermittently send an empty body, so there are 4 tries, and a .lua must compile
to be cached. ]]
local function downloadFile(path, func, chunkName)
	local devLoader = shared.PistonwareDevLoadSource
	if type(devLoader) == 'function' then
		local body, chunk = devLoader(path, chunkName)
		if chunkName and type(body) == 'string' and type(chunk) == 'function' then
			validatedChunks[path] = {body = body, name = chunkName, chunk = chunk}
		end
		return func and func(path) or body
	end
	local developer = shared.PistonwareDeveloper == true
	local body = (cacheAllowed() or developer) and hasContent(path, chunkName)
	if not body and developer then
		local ok, text = pcall(readfile, path)
		if isfile(path) and ok and type(text) == 'string' and text ~= '' then
			local compileOk, chunk, compileError = pcall(rawLoadstring, text, chunkName or path)
			error(path..' does not compile (developer mode does not replace it): '..tostring(compileOk and compileError or chunk), 0)
		end
	end
	if not body then
		local relPath = select(1, path:gsub('pistonware/', ''))
		local isBedwars = relPath == 'games/bedwars.lua'
		local content
		for attempt = 1, 4 do
			local suc, res = pcall(function()
				if isBedwars then
					return pistonwareProtectedHttpGet(protectedRawUrl(), true, attempt)
				end
				return pistonwareHttpGet(projectRawUrl(relPath), true, attempt)
			end)
			if suc and res and res ~= '' and res ~= '404: Not Found' and (not path:find('%.lua$') or loadstring(res) ~= nil) then
				content = res
				break
			end
			if attempt < 4 then
				task.wait(attempt)
			end
		end
		if not content then
			error('failed to download '..path..' after 4 attempts')
		end
		writefile(path, content)
		body = content
	end
	if func then return func(path) end
	return body
end

--[[ False while a game script registers modules. finishLoading uses this because saving and
profile application must wait for the module set. ]]
local gameScriptFinished = true
-- shared.bedwars as this boot found it, so a payload left over from the boot before cannot count.
local payloadTableBefore

--[[ Set after the profile is applied; teleport saves are allowed only then. ]]
local profileApplied = false

-- shared survives reinjection on several executors, so every new boot owns a fresh state.
shared.PistonwareBootFailed = nil
shared.PistonwareBootFailure = nil
-- Set when a game file this boot downloaded did not land on disk; the loader then holds its marker.
shared.PistonwareCacheWriteFailed = nil
--[[ Which boot owns the session. A reinject while the BedWars payload is still loading starts a new
boot, but the old one's profile waiter is still polling: without this it would wake later and fail
or apply into the new session, leaving saving off with no message. ]]
local bootToken = {}
shared.PistonwareBootToken = bootToken
local function isCurrentBoot()
	return shared.PistonwareBootToken == bootToken
end
-- slinky is only assigned further down, once the GUI library chunk has run; until then there is
-- nothing to block, and failBoot below re-applies the block once it exists.
if slinky and slinky.blockSaving then slinky:blockSaving() elseif slinky then slinky.saveBlocked = true end

--[[ The loader's mark that this account's boot is under way (loader.lua cache.repair), at the path
it names. Emptied once the boot has finished, and when it stopped for a reason that fetching the
files again cannot change. A developer boot has none. ]]
local function clearBootPending()
	local path = rawget(shared, 'PistonwareBootPending')
	if type(path) == 'string' and path ~= '' then
		pcall(writefile, path, '')
	end
end

-- Whether this boot moved a settings file aside (applyProfile), for what failBoot says.
local profileSetAside = false

--[[ Marks the boot as failed, blocks saving and puts the reason on screen once, through slinky.notify
or, when the menu is not up within 30 s, a Roblox notification. A stopped boot leaves the menu on
defaults with nothing saying why, and Xeno has no getgenv to reach the error buffer from. The
loader's next run repairs the install; when the key server refused the key, fetching the files again
cannot help, so the boot-pending mark is cleared. A boot that a reinject has replaced does nothing.
]]
local function failBoot(stageName, err)
	if not isCurrentBoot() then return false end
	if not shared.PistonwareBootFailed then
		shared.PistonwareBootFailed = true
		shared.PistonwareBootFailure = {
			stage = tostring(stageName or 'unknown'),
			error = tostring(err or 'unknown failure')
		}
		local stageText = tostring(stageName or 'unknown')
		local message = stageText == 'bedwars.session'
			and "Your key session wasn't accepted, so the BedWars modules stayed off."
			or stageText == 'profile.apply' and (profileSetAside
				and "Your settings couldn't be read, so they were set aside. Run Pistonware again to load fresh ones."
				or "Your settings couldn't be loaded. Run Pistonware again: the next run repairs its files.")
			or ("Pistonware couldn't finish loading (%s). Run it again: the next run repairs its files."):format(stageText)
		if stageText == 'bedwars.session' then
			clearBootPending()
		end
		task.spawn(function()
			local deadline = os.clock() + 30
			repeat
				if type(slinky) == 'table' and type(slinky.notify) == 'function' then
					pcall(slinky.notify, slinky, 'Pistonware', message, 20, 'alert')
					return
				end
				task.wait(0.5)
			until os.clock() > deadline
			pcall(function()
				game:GetService('StarterGui'):SetCore('SendNotification', {Title = 'Pistonware', Text = message, Duration = 20})
			end)
		end)
	end
	profileApplied = false
	if slinky and slinky.blockSaving then
		slinky:blockSaving()
	elseif slinky then
		slinky.saveBlocked = true
		slinky.saveNeeded = nil
	end
	return false
end

--[[ Runs once the GUI and the game script have been started: applies the profile, hooks the teleport so
the script comes back on the next server, and shows the finished-loading toast.
shared.SlinkyCustomProfile is a one-shot hint for this load (the loader's first-run chooser or the
teleport script sets it) and is cleared here: shared survives a reinject, and a stale value would
force an old profile over the one saved in settings.json.

The profile is applied exactly once, after every module exists. An early load leaves the payload's
modules on defaults, and a second pass would overwrite what was changed by hand in between. Saving
has the same rule: a save before the payload finishes writes a profile missing every module still to
come. slinky.Loaded stays false for the whole of slinky:load and gates every save; there is no
autosave timer, since saves walk slinky.ModuleOrder, an array a registration cannot invalidate. When
the key server refuses the key no game modules register, so nothing is loaded or saved. A settings
file that does not decode is moved to <name>.broken.txt and the config sync is offered again on the
next run.

The game script's end shows in only two ways: an ordinary game script returns, and bedwars.lua,
which never returns, sets shared.PistonwareBedwarsLoaded as its last statement. A module count going
quiet cannot stand in for it, since the payload's first seconds are pure network. The wait checks
every frame; past its 120 s backstop the payload is slow, not gone (a low-end phone can take
longer), so the profile keeps waiting while saves only queue, and a reinject in that time takes
over.

From here this boot queues its own teleports, and the developer loader's fallback handler is
disconnected. One queued boot per arrival: Delta keeps every queued script until the game closes and
runs them all on each join, so each queue writes a fresh token to teleport_token_<UserId>.txt and
puts it on the script's first line; a copy whose token is not the file's stops, and Uninject empties
the file. A Failed teleport state is ignored rather than spending the one-shot guard. The queued
script carries the release, the key (checked again by the loader; never the authenticated flag), the
developer and trace flags, the yield budget and the profile name; the key, the release fields and
the profile name go through %q so a quote or backslash still compiles. The developer path runs
loaderdev.lua first; the public one fetches loader.lua with 3 tries and falls back to the copy on
disk.

AutoQueueDodge and RegionLock sit first in the queued script, because the game's
ConnectController.KnitStart sends PlayerConnect as soon as Knit starts, long before the loader. They
hold the connect and judge the match from autoqueuedodge.txt (ranked queues on 6872274481 only) and
regionlock.txt; the match loads once every gate is open, and an error opens them. AutoQueueDodge
keeps KnitStart from running; RegionLock lets it run and holds back only PlayerConnect and
PlayerReady, sent connect first on release. The server answers '' for its region while you are held
out, so the region is judged by the fastest of at least 5 timed replies against your home region
(country through the lobby's Continents table): inside your own region under 70 ms, NA to EU 80-180
ms, NA or EU to SEA 110-300 ms; below 105 ms from NA or EU it cannot be SEA, and from 250 ms it can
only be SEA. Requeue fires the lobby's joinQueue remote, which works in a match server, waits for
slinky.teleportHooked, and is never sent from a party.

queue_on_teleport runs before the save, and the save is pcall'd and only taken after the profile was
applied: the callback runs while the client tears down for the teleport, a blocking write in that
window can take the game down (worst on mobile), and a save error must never stop the queue. ]]
local function finishLoading()
	slinky.init = nil
	local customProfile = shared.SlinkyCustomProfile
	shared.SlinkyCustomProfile = nil
	if customProfile == '' then customProfile = nil end

	local function applyProfile(moduleSetComplete)
		if not isCurrentBoot() then return end
		if shared.PistonwareSessionRejected then
			failBoot('bedwars.session', 'session was not authorised')
			bufferWarn('profile.session', 'session was not authorised -- leaving profiles untouched')
			return
		end
		if shared.PistonwareBootFailed then return end
		if not moduleSetComplete then
			failBoot('modules.timeout', 'the game payload did not signal completion within 120 seconds')
			bufferWarn('profile.timeout', 'payload completion timed out -- profile loading and saving are blocked for this session')
			return
		end
		debugWarn(('[pistonware] applying profile %s (teleported=%s)'):format(
			tostring(customProfile or '<saved>'), tostring(shared.slinkyreload and true or false)))
		local loadOk, _, canSave = xpcall(function()
			return slinky:load(nil, customProfile)
		end, errorTrace)
		if loadOk and canSave == false then
			pcall(function()
				local httpService = game:GetService('HttpService')
				local paths = {'pistonware/profiles/settings.json'}
				if type(slinky.profile) == 'string' then
					table.insert(paths, slinky:profilePath(slinky.profile))
				end
				local setAside = false
				for _, path in paths do
					local readOk, body = pcall(readfile, path)
					if isfile(path) and readOk and type(body) == 'string' then
						local decodes, decoded = pcall(httpService.JSONDecode, httpService, body)
						if not (decodes and type(decoded) == 'table') then
							local kept = pcall(writefile, (path:gsub('%.json$', '.broken.txt')), body)
							if type(delfile) == 'function' then
								pcall(delfile, path)
							else
								pcall(writefile, path, '{}\n')
							end
							setAside = true
							bufferWarn('profile.setaside', path..(kept and ' did not decode and was moved to .broken.txt'
								or ' did not decode and was cleared (its copy in .broken.txt could not be written)'))
						end
					end
				end
				if setAside then
					profileSetAside = true
					pcall(writefile, 'pistonware/profiles/profilecommit.txt', '')
				end
			end)
		end
		if not loadOk or canSave == false then
			failBoot('profile.apply', loadOk and 'profile data could not be loaded safely' or _)
			bufferWarn('profile.apply', 'profile application failed -- profile saving is blocked for this session')
			return
		end
		debugWarn('[pistonware] profile load returned')
		clearBootPending()

		profileApplied = true
		if slinky.allowSaving then slinky:allowSaving() else slinky.saveBlocked = nil end
	end

	local function waitForModules()
		if gameScriptFinished then return true end
		local function payloadDone()
			return shared.PistonwareBedwarsLoaded and shared.bedwars ~= payloadTableBefore
		end
		local started = os.clock()
		repeat
			task.wait()
		until gameScriptFinished
			or payloadDone()
			or not isCurrentBoot()
			or os.clock() - started > 120
		local complete = (gameScriptFinished or payloadDone()) and true or false
		local count = slinky.moduleCount or 0
		local how = shared.PistonwareBedwarsLoaded and 'payload signalled'
			or gameScriptFinished and 'game script returned'
			or 'TIMED OUT after 120s -- re-upload bedwars.lua to LuaArmor so it can signal when it is done'
		debugWarn(('[pistonware] %d modules in %.1fs (%s) -- applying profile'):format(count, os.clock() - started, how))
		return complete
	end

	if gameScriptFinished then
		applyProfile(true)
	else
		task.spawn(function()
			local complete = waitForModules()
			if not complete and shared.slinky == slinky then
				bufferWarn('profile.wait', 'payload still registering after 120s -- the profile is applied when it finishes')
				repeat
					task.wait(0.5)
				until gameScriptFinished
					or (shared.PistonwareBedwarsLoaded and shared.bedwars ~= payloadTableBefore)
					or shared.slinky ~= slinky
					or not isCurrentBoot()
				if shared.slinky ~= slinky or not isCurrentBoot() then return end
				complete = true
			end
			applyProfile(complete)
		end)
	end

	local teleportedServers
	slinky.teleportHooked = true
	pcall(function()
		rawset(shared, 'PistonwareTeleportOwned', true)
		local fallback = rawget(shared, 'PistonwareDevTeleportConnection')
		if fallback then
			rawset(shared, 'PistonwareDevTeleportConnection', nil)
			fallback:Disconnect()
		end
	end)
	local teleportTokenPath = 'pistonware/teleport_token_'..tostring(playersService.LocalPlayer.UserId)..'.txt'
	slinky:clean(function()
		pcall(writefile, teleportTokenPath, '')
	end)
	slinky:clean(playersService.LocalPlayer.OnTeleport:Connect(function(teleportState)
		if teleportState == Enum.TeleportState.Failed then return end
		if (not teleportedServers) and (not shared.SlinkyIndependent) then
			teleportedServers = true
						local teleportScript = [[
							shared.slinkyreload = true
							local function queuedError(event, message)
								local target
								pcall(function()
									local env = getgenv()
									target = type(env.pistonware) == 'table' and env.pistonware.buffer or nil
								end)
								if type(target) == 'table' and type(target.error) == 'function' then
									target.error(event, message)
								elseif rawget(shared, 'PistonwareDeveloper') == true then
									warn('[pistonware] '..tostring(message))
								end
							end
						-- A developer teleport must restore the developer loader first. loaderdev.lua
						-- installs the local LuaArmor test seam; jumping straight into main.lua loses
						-- that seam in the new Roblox execution context and the local payload reports
						-- an authorization failure even though the original boot was valid.
						if rawget(shared, 'PistonwareDeveloper') == true then
							-- Each step leaves a line in pistonware_teleport.log: nothing else is
							-- up yet on the new server to report where a queued boot stopped.
							local function crumb(text)
								pcall(function()
									local line = os.date('!%Y-%m-%dT%H:%M:%SZ')..' [main.lua] '..text..'\n'
									if type(appendfile) == 'function' and isfile('pistonware_teleport.log') then
										appendfile('pistonware_teleport.log', line)
									else
										writefile('pistonware_teleport.log', line)
									end
								end)
							end
							crumb('queued script started in place '..tostring(game.PlaceId))
							pcall(rawset, shared, 'PistonwareSessionRejected', nil)
							pcall(rawset, shared, 'PistonwareLoaderBoot', nil)
							local developerSource
							pcall(function()
								if type(readfile) == 'function' then
									developerSource = readfile('pistonware/loaderdev.lua')
								end
							end)
							if type(developerSource) == 'string' and developerSource ~= '' then
								local developerChunk, developerError = loadstring(developerSource, 'loaderdev')
								if developerChunk then
									local ran, runError = pcall(developerChunk)
									crumb(ran and 'loaderdev.lua finished' or ('loaderdev.lua errored: '..tostring(runError)))
									-- A boot that died cannot claim AutoQueueDodge's hold, so let the match in
									-- now instead of after the three-minute backstop.
									local hold = shared.PistonwareDodgeHold
									if not ran and type(hold) == 'table' and not hold.claimed and type(hold.release) == 'function' then
										pcall(hold.release)
										crumb('released the AutoQueueDodge hold')
									end
									return
								end
								crumb('loaderdev.lua did not compile: '..tostring(developerError))
								queuedError('teleport.loaderdev.compile', developerError)
								return
							else
								crumb('loaderdev.lua could not be read')
								queuedError('teleport.loaderdev.missing', 'queued developer loader is unavailable; refusing to continue')
								return
							end
						end
						-- The developer branch's rule for the public boot: one that never brings pistonware
						-- up cannot claim AutoQueueDodge's hold, and nothing else would let the match in or
						-- say why. Not while another boot is still running or came up; that one can.
						local slinkyBefore = shared.slinky
						local function releaseHeldMatch()
							local hold = shared.PistonwareDodgeHold
							if type(hold) ~= 'table' or hold.jobId ~= game.JobId then return end
							task.spawn(function()
								-- A fast failure can land before the hold is up.
								local deadline = os.clock() + 60
								while hold.state == 'waiting' and os.clock() < deadline do task.wait(0.25) end
								if shared.PistonwareLoaderBoot or (shared.slinky ~= nil and shared.slinky ~= slinkyBefore) then return end
								if hold.state == 'held' and not hold.claimed and type(hold.release) == 'function' then
									pcall(hold.release)
								end
							end)
						end
						local release = shared.PistonwareRelease
							local ref = type(release) == 'table' and (release.sourceRef or release.branch) or 'main'
							-- Three tries a second or two apart, then the copy the loader's update pass keeps on
							-- disk, as the loader's own queued copy does: one failed request on the way into a
							-- match left the new server without Pistonware.
							local chunk, compileError, source
							for attempt = 1, 3 do
								local ok, body = pcall(function()
									return game:HttpGet('https://raw.githubusercontent.com/themagicpiston/pistonware/'..ref..'/loader.lua', true)
								end)
								source = body
								if ok and type(body) == 'string' and body ~= '' and body ~= '404: Not Found' then
									chunk, compileError = loadstring(body, 'loader')
									if chunk then break end
								end
								if attempt < 3 then task.wait(attempt) end
							end
							if not chunk then
								local readOk, cached = pcall(readfile, 'pistonware/loader.lua')
								if readOk and type(cached) == 'string' and cached ~= '' then
									chunk = loadstring(cached, 'loader')
								end
							end
							if not chunk then
								if compileError then
									queuedError('teleport.loader.compile', compileError)
								else
									queuedError('teleport.loader.download', source)
								end
								releaseHeldMatch()
								return
							end
							-- The loader returns once main.lua has run, or once the key gate or a failure ended the boot.
							local ran, result = pcall(chunk)
							releaseHeldMatch()
							if not ran then error(result, 0) end
							return result
					]]
			local currentRelease = shared.PistonwareRelease
			if type(currentRelease) == 'table' then
				local channel = tostring(currentRelease.channel or 'main')
				local branch = tostring(currentRelease.branch or channel)
				local sourceRef = tostring(currentRelease.sourceRef or branch)
				local version = tostring(currentRelease.version or '')
				teleportScript = 'shared.PistonwareChannel = '..string.format('%q', channel)..'\n'
					..'shared.PistonwareRelease = {schema=1, channel='..string.format('%q', channel)
					..', branch='..string.format('%q', branch)
					..', sourceRef='..string.format('%q', sourceRef)
					..', version='..string.format('%q', version)
					..', cacheReady=true, resolved=true}\n'..teleportScript
			end
			local teleportKey = rawget(shared, 'PistonwareKey')
			if type(teleportKey) == 'string' and teleportKey ~= '' then
				local quoted = string.format('%q', teleportKey)
				teleportScript = 'script_key = '..quoted..'\nrawset(shared, "PistonwareKey", '..quoted..')\n'..teleportScript
			end
			if rawget(shared, 'PistonwareDeveloper') == true then
				teleportScript = 'rawset(shared, "PistonwareDeveloper", true)\n'..teleportScript
			end
			if shared.SlinkySmoothBoot then
				teleportScript = 'shared.SlinkySmoothBoot = true\n'..teleportScript
			end
			if traceOn then
				teleportScript = 'shared.PistonwareTrace = true\n'..teleportScript
			end
			do
				local env = (getgenv and getgenv()) or {}
				local budget = tonumber(env.PistonwareYieldBudget or shared.PistonwareYieldBudget)
				if budget and budget > 0 then
					teleportScript = 'shared.PistonwareYieldBudget = '..budget..'\n'..teleportScript
				end
			end
			teleportScript = 'shared.SlinkyCustomProfile = '..string.format('%q', slinky.profile or customProfile or 'default')..'\n'..teleportScript
			teleportScript = [==[
local previousHold = shared.PistonwareDodgeHold
local matchPlaces = {[6872274481] = true, [8444591321] = true, [8560631822] = true}
if matchPlaces[game.PlaceId] and not (type(previousHold) == 'table' and previousHold.jobId == game.JobId) then
	-- A module's settings, while it is on. AutoQueueDodge deletes its file when switched off,
	-- RegionLock marks its own off; either way, no settings means that check does not run, and
	-- with neither this match loads exactly as it always has.
	local function readSettings(path)
		local data
		pcall(function()
			if isfile(path) then
				data = game:GetService('HttpService'):JSONDecode(readfile(path))
			end
		end)
		return type(data) == 'table' and data.enabled == true and data or nil
	end
	local settings = game.PlaceId == 6872274481 and readSettings('pistonware/autoqueuedodge.txt') or nil
	local regionSettings = readSettings('pistonware/regionlock.txt')
	if settings or regionSettings then
		local hold = {state = 'waiting', jobId = game.JobId, gates = {}}
		shared.PistonwareDodgeHold = hold

		-- Pistonware's own notifications. pistonware keeps loading while the match is held,
		-- but its GUI is not up for the first few seconds, so anything said before then waits
		-- and goes out in order once it is. A slinky left in shared by the previous server is
		-- not ours to use.
		local staleSlinky = shared.slinky
		local outbox = {}
		local flushing = false
		-- Titled with the module it is about; untitled messages are AutoQueueDodge's (or the
		-- hold's, under whichever module placed it).
		local function notify(text, duration, kind, title)
			-- AutoQueueDodge's Notify toggle covers its own messages. Missing from settings written
			-- before it existed: on.
			if not title and settings and settings.notify == false then return end
			table.insert(outbox, {text, duration or 6, kind, title or (settings and 'AutoQueueDodge' or 'RegionLock')})
			if flushing then return end
			flushing = true
			task.spawn(function()
				local deadline = os.clock() + 180
				while #outbox > 0 and os.clock() < deadline do
					local slinky = shared.slinky
					if type(slinky) == 'table' and slinky ~= staleSlinky and type(slinky.notify) == 'function' then
						local entry = table.remove(outbox, 1)
						pcall(function()
							slinky:notify(entry[4], entry[1], entry[2], entry[3])
						end)
					else
						task.wait(0.25)
					end
				end
				flushing = false
			end)
		end

		task.spawn(function()
			local ok, err = pcall(function()
				repeat task.wait() until game:IsLoaded()
				local players = game:GetService('Players')
				local lplr = players.LocalPlayer
				local replicated = game:GetService('ReplicatedStorage')
				local scripts = lplr:WaitForChild('PlayerScripts')

				local controller
				local deadline = os.clock() + 30
				repeat
					pcall(function()
						controller = require(scripts:WaitForChild('TS').controllers.global.connect['connect-controller']).ConnectController
					end)
					if not controller then task.wait() end
				until controller or os.clock() > deadline
				if not controller then
					hold.state = 'failed'
					notify('Could not hold this match, loading in normally.', 6, 'warning')
					return
				end
				if controller.connected then
					hold.state = 'missed'
					notify('You loaded in before this match could be held.', 6, 'warning')
					return
				end

				-- AutoQueueDodge: ranked only. The teleport data names the queue, and every ranked
				-- queue's meta carries a rankCategory. Anything else, or a queue that cannot be
				-- read, is not judged on its teams at all.
				local queueMeta = require(replicated.TS.game['queue-meta']).QueueMeta
				local teleportData
				pcall(function()
					teleportData = game:GetService('TeleportService'):GetLocalPlayerTeleportData()
				end)
				local queueType = type(teleportData) == 'table' and type(teleportData.match) == 'table' and teleportData.match.queueType
				local meta = queueType and queueMeta[queueType]
				local dodging = settings ~= nil
					and meta ~= nil
					and (meta.rankCategory ~= nil or tostring(queueType):find('ranked', 1, true) ~= nil)
					and type(meta.teams) == 'table'
				if not (dodging or regionSettings) then
					hold.state = 'skipped'
					return
				end

				hold.controller = controller
				hold.gates.dodge = dodging or nil
				hold.gates.region = regionSettings and true or nil

				--[[ Two ways to hold, one per check.

				AutoQueueDodge keeps KnitStart from running at all: the teams are judged before this
				client does anything toward joining.

				RegionLock cannot: KnitStart runs, and only the two messages that tell the SERVER --
				PlayerConnect and PlayerReady -- are kept back, to go out in that order once every
				gate is open. PlayerConnect on its own already loads you in, and the server names its
				region only once you are in, so the region check judges the server by its ping while
				both stay held. ]]
				local original = controller.KnitStart
				local client = require(replicated:WaitForChild('TS'):WaitForChild('remotes')).default.Client
				local ownWaitFor = rawget(client, 'WaitFor')
				local captured = {}
				-- The game's KnitStart, run once whichever comes first: AutoQueueDodge letting it
				-- go, or Knit calling it after that already happened. Restoring it and running it
				-- as well sent everything twice when a match passed before Knit got to it.
				local knitRan = false
				local function runKnitStart()
					if knitRan then return end
					knitRan = true
					pcall(original, controller)
				end
				if dodging then
					controller.KnitStart = function()
						if hold.state ~= 'held' or not hold.gates.dodge then
							runKnitStart()
						end
					end
				end
				if regionSettings then
					local baseWaitFor = client.WaitFor
					client.WaitFor = function(self, name, ...)
						local promise = baseWaitFor(self, name, ...)
						if name ~= 'PlayerConnect' and name ~= 'PlayerReady' then return promise end
						return promise:andThen(function(remote)
							return setmetatable({
								SendToServer = function(_, ...)
									if hold.state == 'held' then
										table.insert(captured, {Name = name, Remote = remote, Args = table.pack(...)})
									else
										remote:SendToServer(...)
									end
								end
							}, {__index = remote})
						end)
					end
				end

				-- The lobby package's remotes, which a match server has too (Play Again queues
				-- through them), and this client's queue state from the game's store.
				local LOBBY_EVENTS = 'events-@easy-games/lobby:shared/event/lobby-events@getEvents.Events'
				local function lobbyRemote(name)
					local events = replicated:FindFirstChild(LOBBY_EVENTS)
					return events and events:FindFirstChild(name)
				end
				local function queueState()
					local state
					pcall(function()
						state = require(scripts.TS.ui.store).ClientStore:getState().Party.queueState
					end)
					return type(state) == 'number' and state or nil
				end

				-- Once AutoQueueDodge is done with it, KnitStart runs (still under RegionLock's hold,
				-- if that is up). The region can only come back from here on.
				local function startKnit()
					if hold.knitStarted then return end
					hold.knitStarted = os.clock()
					if dodging then
						task.spawn(runKnitStart)
					end
				end

				hold.release = function(gate)
					if hold.state ~= 'held' then return false end
					-- A check that passes opens its own gate and the match waits on the rest. No
					-- gate named (Load in now, a boot that died, an error in here) opens them all.
					if gate then
						hold.gates[gate] = nil
					else
						table.clear(hold.gates)
					end
					if not hold.gates.dodge then
						startKnit()
					end
					if next(hold.gates) then return false end
					hold.state = 'released'
					if regionSettings then
						client.WaitFor = ownWaitFor
					end
					-- What KnitStart already tried to send goes now, the connect first.
					table.sort(captured, function(a, b)
						return (a.Name == 'PlayerConnect' and 0 or 1) < (b.Name == 'PlayerConnect' and 0 or 1)
					end)
					for _, send in captured do
						pcall(function()
							send.Remote:SendToServer(table.unpack(send.Args, 1, send.Args.n))
						end)
					end
					table.clear(captured)
					-- Let in after all, with a Requeue already sent: out of that queue again.
					if hold.requeued then
						local remote = lobbyRemote('leaveQueue')
						if remote then pcall(function() remote:FireServer() end) end
					end
					return true
				end
				hold.state = 'held'
				if not dodging then
					-- Knit calls the untouched KnitStart itself.
					hold.knitStarted = os.clock()
				end

				--[[ Requeue: this mode again, from right here. The lobby's joinQueue remote works in
				a match server too, and you stay held on this one until the new match takes you.
				Only once pistonware is up here -- its teleport hook is what comes along to that
				match -- and never from a party: queueing is the leader's, and would pull everyone
				else out of this match with you. Let in meanwhile, it is not sent (or is taken
				back, above). ]]
				local function requeue(title, why)
					if hold.requeueing then return end
					hold.requeueing = true
					local party = type(teleportData) == 'table' and teleportData.party
					local size = type(party) == 'table' and tonumber(party.partySize) or 1
					if size > 1 then
						notify('You are in a party of '..size..', so it will not queue again on its own. Leave to requeue.', 10, 'warning', title)
						return
					end
					notify('Requeueing: '..why..'.', 6, nil, title)
					task.spawn(function()
						local deadline = os.clock() + 45
						while os.clock() < deadline do
							local slinky = shared.slinky
							if type(slinky) == 'table' and slinky ~= staleSlinky and slinky.teleportHooked then break end
							task.wait(0.25)
						end
						for _ = 1, 3 do
							if hold.state ~= 'held' then return end
							local state = queueState()
							if state and state ~= 0 then
								hold.requeued = true
								return
							end
							local remote = lobbyRemote('joinQueue')
							if not remote then break end
							pcall(function()
								remote:FireServer({queueType = queueType})
							end)
							hold.requeued = true
							-- No queue state to read: sent once, and left at that.
							if state == nil then return end
							local waitUntil = os.clock() + 5
							repeat
								task.wait(0.25)
							until (queueState() or 0) ~= 0 or os.clock() > waitUntil or hold.state ~= 'held'
							if (queueState() or 0) ~= 0 or hold.state ~= 'held' then return end
						end
						notify('Could not queue again from here. Leave to requeue.', 8, 'warning', title)
					end)
				end

				local remotes = require(replicated:WaitForChild('TS'):WaitForChild('remotes')).default

				--[[ RegionLock: loads only on a server in one of the regions the module lists.
				BedWars hosts NA, EU and SEA. The lobby files you under one by account country
				(its Continents table: AU, NZ and the rest of Oceania go to SEA) and matches you
				there, but a slow queue can still hand you another region's server. The game asks
				the server's region once at start-up (RegionController, kept as Game.serverRegion),
				but under this hold that is before PlayerConnect, and the answer is blank. ]]
				if regionSettings then
					local REGION_ALIASES = {
						AU = 'SEA', AUS = 'SEA', AUSTRALIA = 'SEA', NZ = 'SEA', NEWZEALAND = 'SEA',
						OCE = 'SEA', OCEANIA = 'SEA', AS = 'SEA', ASIA = 'SEA', SG = 'SEA', SGP = 'SEA',
						US = 'NA', USA = 'NA', AMERICA = 'NA', NORTHAMERICA = 'NA',
						EUROPE = 'EU', GB = 'EU', UK = 'EU',
						-- The countries BedWars' own labels lead with ('DE-HE'), should Continents not load.
						DE = 'EU', NL = 'EU', IE = 'EU', FR = 'EU', PL = 'EU', ZA = 'EU', BR = 'NA', CA = 'NA',
						JP = 'SEA', HK = 'SEA', IN = 'SEA',
						-- Datacenter cities and countries, in case a label names the place instead.
						SINGAPORE = 'SEA', SYDNEY = 'SEA', TOKYO = 'SEA', JAPAN = 'SEA', HONGKONG = 'SEA',
						MUMBAI = 'SEA', INDIA = 'SEA', AUCKLAND = 'SEA',
						FRANKFURT = 'EU', GERMANY = 'EU', AMSTERDAM = 'EU', NETHERLANDS = 'EU', LONDON = 'EU',
						PARIS = 'EU', FRANCE = 'EU', WARSAW = 'EU', POLAND = 'EU',
						VIRGINIA = 'NA', ASHBURN = 'NA', DALLAS = 'NA', TEXAS = 'NA', CHICAGO = 'NA',
						MIAMI = 'NA', SEATTLE = 'NA', LOSANGELES = 'NA', NEWYORK = 'NA', SANJOSE = 'NA',
						ATLANTA = 'NA', CANADA = 'NA'
					}
					local HOSTED = {NA = true, EU = true, SEA = true}
					local continents
					pcall(function()
						continents = require(replicated.rbxts_include.node_modules['@easy-games'].lobby.out.server.services['device-info'].data.continents).Continents
					end)

					local function canonical(value)
						value = tostring(value):gsub('%s+', ''):upper()
						return REGION_ALIASES[value] or value
					end

					-- NA, EU or SEA for a region label, or nil: the label itself, its leading word
					-- ('NA-East', 'US-Virginia'), or that word as a country code.
					local function regionCode(label)
						local whole = canonical(label)
						if HOSTED[whole] then return whole end
						local head = canonical(tostring(label):match('^%s*(%a+)') or '')
						if HOSTED[head] then return head end
						local continent = continents and continents[head]
						return HOSTED[continent] and continent or nil
					end

					-- No regions listed accepts anything.
					local function allowed(label, list)
						if type(list) ~= 'table' or #list == 0 then return true end
						local whole, code = canonical(label), regionCode(label)
						for _, entry in list do
							entry = canonical(entry)
							if entry ~= '' and (entry == code or whole:sub(1, #entry) == entry) then
								return true
							end
						end
						return false
					end

					-- What the game's RegionController got back (Game.serverRegion), or nil.
					local function storedRegion()
						local region
						pcall(function()
							region = require(scripts.TS.ui.store).ClientStore:getState().Game.serverRegion
						end)
						return type(region) == 'string' and region ~= '' and region or nil
					end

					-- The game asked once, before the server knew you, and kept the blank: hand its
					-- store and its REGION label the answer read here.
					local function showRegion(label)
						pcall(function()
							require(scripts.TS.ui.store).ClientStore:dispatch({type = 'SetServerRegion', serverRegion = label})
						end)
						pcall(function()
							lplr:FindFirstChildOfClass('PlayerGui').ServerRegionDisplay.ServerRegionText.Text = '<b>REGION: '..label..'</b>'
						end)
					end

					-- Asked in its own thread, the same call RegionController makes: a reply that
					-- takes its time must not stall the settings reads or the Timeout. Each reply is
					-- timed too; the fastest round trip is the fallback when no label ever comes.
					-- askError keeps the last thing that went wrong, for the Timeout's message.
					local asking, nextAsk, askError = false, 0, nil
					local blanks, fastest, timed = 0, math.huge, 0
					local fetch
					local function askRegion()
						if asking or os.clock() < nextAsk then return end
						asking = true
						task.spawn(function()
							local sentAt
							local ok, region = pcall(function()
								fetch = fetch or remotes.Client:Get('FetchServerRegion')
								sentAt = os.clock()
								return fetch:CallServer()
							end)
							if not ok then
								askError = tostring(region)
								-- The same RemoteFunction, invoked directly.
								ok, region = pcall(function()
									local remote = replicated.rbxts_include.node_modules['@rbxts'].net.out._NetManaged.FetchServerRegion
									sentAt = os.clock()
									return remote:InvokeServer()
								end)
								if not ok then askError = tostring(region) end
							end
							if ok and sentAt then
								fastest = math.min(fastest, os.clock() - sentAt)
								timed += 1
							end
							asking = false
							nextAsk = os.clock() + 0.5
							if ok and type(region) == 'string' and region ~= '' then
								if not hold.serverRegion then
									hold.serverRegion = region
									showRegion(region)
								end
							elseif ok then
								blanks += 1
								askError = region == '' and 'the server gave no region' or ('the server answered '..tostring(region))
							end
						end)
					end

					--[[ The server keeps its region to itself until you are in the match: it answers ''
					to a player held out of it, and PlayerConnect on its own already loads you in, so the
					label cannot be had in time. What can be measured while held is how far away the
					server is. Every ask is timed, blank or not, and the fastest round trip, against the
					region you queue from (your country through Continents, the lobby's own rule), says
					where the server can be. A real label, should one ever come back, outranks it. ]]
					local home
					task.spawn(function()
						pcall(function()
							home = regionCode(game:GetService('LocalizationService'):GetCountryRegionForPlayerAsync(lplr))
						end)
					end)
					--[[ Round trips as measured here, a network round trip plus up to a server and a
					client frame: inside your own region well under 70 ms; NA to EU 80-180 ms; from NA or
					EU over to SEA 110-300 ms. Below NEIGHBOUR_MS from NA or EU it cannot be SEA, and from
					FAR_MS it can only be SEA. From SEA a far server could be either of the others. ]]
					local NEAR_MS, NEIGHBOUR_MS, FAR_MS, SAMPLES = 70, 105, 250, 5
					local function pingRegions()
						if timed < SAMPLES or fastest == math.huge or not home then return nil end
						local ms = math.floor(fastest * 1000 + 0.5)
						if ms <= NEAR_MS then return {[home] = true}, ms end
						if home ~= 'SEA' then
							if ms < NEIGHBOUR_MS then return {NA = true, EU = true}, ms end
							if ms >= FAR_MS then return {SEA = true}, ms end
						end
						return {NA = true, EU = true, SEA = true}, ms
					end
					-- 'allowed' when every region it can be in is listed, 'wrong' when none is, else 'unclear'.
					local function pingVerdict(list)
						local possible, ms = pingRegions()
						if not possible then return nil end
						local any, all, names = false, true, {}
						for _, region in {'NA', 'EU', 'SEA'} do
							if possible[region] then
								table.insert(names, region)
								if allowed(region, list) then any = true else all = false end
							end
						end
						return all and 'allowed' or any and 'unclear' or 'wrong', table.concat(names, ' or ')..', judged by ping ('..ms..' ms)'
					end

					local function regionCheck()
						local told
						while hold.state == 'held' and hold.gates.region do
							-- Read every pass: switching RegionLock off or listing this region from
							-- inside the held match takes effect here.
							local current = readSettings('pistonware/regionlock.txt')
							if not current then
								hold.region = nil
								if hold.release('region') then
									notify('Switched off, loading in.', 5, nil, 'RegionLock')
								end
								return
							end
							-- No region listed accepts any server: nothing to wait for.
							if type(current.regions) ~= 'table' or #current.regions == 0 then
								hold.region = 'allowed'
								hold.release('region')
								return
							end
							-- Nothing to ask until KnitStart runs (AutoQueueDodge may still be judging
							-- the teams); the Timeout counts from then.
							local started = hold.knitStarted
							if started and not hold.serverRegion then
								local stored = storedRegion()
								if stored then
									hold.serverRegion = stored
								else
									askRegion()
								end
							end
							local label = hold.serverRegion
							local code = label and regionCode(label)
							local verdict, shown
							if label and (code or allowed(label, current.regions)) then
								shown = (code and code ~= canonical(label)) and (label..' ('..code..')') or label
								verdict = allowed(label, current.regions) and 'allowed' or 'wrong'
							elseif started then
								verdict, shown = pingVerdict(current.regions)
							end
							hold.regionText = shown
							local party = type(teleportData) == 'table' and teleportData.party
							local solo = (type(party) == 'table' and tonumber(party.partySize) or 1) <= 1
							local timeout = tonumber(current.timeout) or 30
							local timedOut = started and timeout > 0 and os.clock() - started >= timeout
							if verdict == 'allowed' then
								hold.region = 'allowed'
								if hold.release('region') then
									notify('Loading in: this server is in '..shown..'.', 6, nil, 'RegionLock')
								elseif hold.state == 'held' then
									notify('This server is in '..shown..'. Waiting on AutoQueueDodge.', 6, nil, 'RegionLock')
								end
								return
							elseif verdict then
								--[[ Wrong, or not clearly allowed: held, and with Requeue on (solo) queued
								again, until a server that is clearly in a listed region comes up. A server
								named by its label as wrong waits as it always has; one only judged by ping
								waits for the Timeout, unless Requeue still has you queued. ]]
								hold.region = verdict
								local message = verdict == 'wrong' and ('Not loading: this server is in '..shown..'.')
									or ('Not loading: this server could be in '..shown..'.')
								if told ~= message then
									told = message
									notify(message..((current.requeue == true and solo) and '' or '\nLeave to requeue, or add the region in RegionLock.'), 15, 'warning', 'RegionLock')
								end
								if current.requeue == true then
									requeue('RegionLock', verdict == 'wrong' and ('this server is in '..shown) or ('this server could be in '..shown))
								end
								if not label and timedOut and (queueState() or 0) == 0 then
									hold.region = 'unknown'
									if hold.release('region') then
										notify('Not queued again within the Timeout, loading in.', 8, 'warning', 'RegionLock')
									end
									return
								end
							else
								-- No label, and not enough replies (or no home region) to judge by ping yet.
								hold.region = 'finding'
								if timedOut then
									hold.region = 'unknown'
									if hold.release('region') then
										notify(label and ('Did not recognise this server\'s region ('..label..'), loading anyway.')
											or ('Could not tell this server\'s region'..(askError and (' ('..askError..')') or '')..', loading anyway.'), 10, 'warning', 'RegionLock')
									end
									return
								end
							end
							task.wait(0.5)
						end
					end

					task.spawn(function()
						local regionOk, regionError = pcall(regionCheck)
						-- Never strand anyone on an error in here either: this gate opens.
						if not regionOk and hold.state == 'held' and hold.release('region') then
							notify('Stopped checking the region ('..tostring(regionError)..'), loading you in.', 10, 'alert', 'RegionLock')
						end
					end)
				end

				if not dodging then return end

				local TIER_NAMES = {'Bronze', 'Silver', 'Gold', 'Platinum', 'Diamond', 'Emerald', 'Nightmare'}
				local rankCache, asked = {}, {}

				local function tierOf(plr)
					local division = rankCache[plr.UserId]
					return type(division) == 'number' and division // 4 or nil
				end

				local function tierName(tier)
					return tier and TIER_NAMES[tier + 1] or 'Unranked'
				end

				local function deviceOf(plr)
					local input = plr:GetAttribute('UserInputType')
					if input == nil then return nil end
					if type(input) == 'number' then
						if input == 7 then return 'mobile' end
						if input >= 9 and input <= 16 then return 'gamepad' end
						return 'pc'
					end
					local name = tostring(input):lower()
					if name:find('gamepad') or name:find('console') or name:find('xbox') or name:find('playstation') then
						return 'gamepad'
					end
					if name:find('touch') or name:find('mobile') or name:find('phone') or name:find('tablet') then
						return 'mobile'
					end
					return 'pc'
				end

				local function fetchRanks(list)
					local ids = {}
					for _, plr in list do
						if not asked[plr.UserId] then
							table.insert(ids, plr.UserId)
						end
					end
					if #ids == 0 then return true end
					local called, success, result = pcall(function()
						return remotes.Client:Get('FetchRanks'):CallServerAsync(ids):await()
					end)
					if not (called and success and type(result) == 'table') then return false end
					for _, id in ids do
						asked[id] = true
					end
					for _, data in result do
						if type(data) == 'table' and data.userId then
							rankCache[data.userId] = data.rankDivision
						end
					end
					return true
				end

				local function snapshot(teams)
					local sides = {}
					for _, team in teams do
						table.insert(sides, {
							id = tostring(team.id),
							name = tostring(team.displayName or ''):lower(),
							size = tonumber(team.maxPlayers) or 5,
							players = {}
						})
					end
					local pending = 0
					for _, plr in players:GetPlayers() do
						if plr ~= lplr then
							local attribute = plr:GetAttribute('Team')
							local teamName = plr.Team and plr.Team.Name:lower()
							local side
							for _, candidate in sides do
								if (attribute ~= nil and tostring(attribute) == candidate.id)
									or (teamName and candidate.name ~= '' and teamName:find(candidate.name, 1, true)) then
									side = candidate
									break
								end
							end
							if side then
								table.insert(side.players, plr)
							else
								pending += 1
							end
						end
					end
					return sides, pending
				end

				local function withMe(list)
					local copy = table.clone(list)
					table.insert(copy, lplr)
					return copy
				end

				local function bestTier(list)
					local best
					for _, plr in list do
						local tier = tierOf(plr)
						if tier and (not best or tier > best) then
							best = tier
						end
					end
					return best
				end

				local function countAbove(list, others)
					local best = bestTier(others)
					local count = 0
					for _, plr in list do
						local tier = tierOf(plr)
						if tier and (not best or tier > best) then
							count += 1
						end
					end
					return count
				end

				local function vetoReason(enemy, mine)
					if not settings.rankVeto then return nil end
					local above = countAbove(enemy, mine)
					if above >= (settings.vetoCount or 2) then
						return ('%d of them outrank your best (%s)'):format(above, tierName(bestTier(mine)))
					end
					return nil
				end

				local function matchReason(enemy, mine)
					if settings.rankAdvantage then
						local above = countAbove(mine, enemy)
						if above >= (settings.advantageCount or 3) then
							return ('%d of your team outrank their best'):format(above)
						end
					end
					if settings.weakDevices then
						local gamepads, mobiles = 0, 0
						for _, plr in enemy do
							local device = deviceOf(plr)
							if device == 'gamepad' then
								gamepads += 1
							elseif device == 'mobile' then
								mobiles += 1
							end
						end
						if gamepads >= (settings.gamepadCount or 2) then
							return ('%d gamepad players against you'):format(gamepads)
						elseif mobiles >= (settings.mobileCount or 3) then
							return ('%d mobile players against you'):format(mobiles)
						elseif settings.mixedDevices and gamepads >= 1 and mobiles >= 1 then
							return 'a mobile and a gamepad player against you'
						end
					end
					if settings.lowRank then
						local limit = (table.find(TIER_NAMES, settings.lowRankTier) or 3) - 1
						for _, plr in enemy do
							local tier = tierOf(plr)
							if tier and tier <= limit then
								return ('a %s player against you'):format(tierName(tier))
							end
						end
					end
					return nil
				end

				-- 'load', 'dodge', or nil to keep waiting, plus the reason. You join the smaller
				-- team, so yours is only known once the teams are uneven; with even teams you are
				-- the extra player on either side, and the veto has to pass against both.
				local function decide(teams, waitedOut)
					local sides, pending = snapshot(teams)
					if #sides ~= 2 then
						return 'load', 'this is not a two-team queue'
					end
					local a, b = sides[1], sides[2]
					local small, large = a, b
					if #a.players > #b.players then
						small, large = b, a
					end
					if #small.players >= small.size then
						return 'dodge', 'both teams are already full'
					end

					local oneFull = #large.players >= large.size
						and (#small.players + 1 >= small.size or pending == 0)
					local bothShort = pending == 0
						and #a.players == a.size - 1 and #b.players == b.size - 1
					if not (oneFull or bothShort or waitedOut) then
						return nil, ('%d v %d, %d still loading in'):format(#a.players, #b.players, pending)
					end

					local everyone = withMe(a.players)
					for _, plr in b.players do
						table.insert(everyone, plr)
					end
					if not fetchRanks(everyone) then
						return nil, 'looking up ranks'
					end

					if #small.players == #large.players then
						local count = #small.players
						local veto = vetoReason(a.players, withMe(b.players)) or vetoReason(b.players, withMe(a.players))
						if veto then
							return 'dodge', veto
						end
						if not settings.advanced or settings.extraPlayer then
							return 'load', ('%dv%d on either team'):format(count + 1, count)
						end
						local first = matchReason(a.players, withMe(b.players))
						local second = matchReason(b.players, withMe(a.players))
						if first and second then
							return 'load', first
						end
						return 'dodge', 'no advanced rule matches against both teams'
					end

					if settings.outnumbered ~= false and #small.players + 1 < #large.players then
						return 'dodge', ('you would be in a %dv%d'):format(#small.players + 1, #large.players)
					end
					local mine = withMe(small.players)
					local veto = vetoReason(large.players, mine)
					if veto then
						return 'dodge', veto
					end
					-- Basic mode only screens out bad matches; Advanced also asks for a reason to load.
					if not settings.advanced then
						return 'load', 'the teams pass your checks'
					end
					local reason = matchReason(large.players, mine)
					if reason then
						return 'load', reason
					end
					return 'dodge', 'no advanced rule matches this lobby'
				end

				local started = os.clock()
				local lastReason, lastWaitNotice = nil, 0
				-- A lobby still loading in can swing a verdict, so Requeue waits for it to hold.
				local dodgeSince
				while hold.state == 'held' do
					if controller.connected then
						hold.state = 'missed'
						notify('You loaded in before this match could be held.', 6, 'warning')
						break
					end
					local verdict, reason = decide(meta.teams, os.clock() - started >= (settings.maxWait or 30))
					if verdict ~= 'dodge' then
						dodgeSince = nil
					end
					if verdict == 'load' then
						if hold.release('dodge') then
							notify('Loading in: '..reason..'.', 8)
						elseif hold.state == 'held' then
							notify('The teams pass ('..reason..'). Waiting on RegionLock.', 8)
						end
						break
					elseif verdict == 'dodge' then
						if reason ~= lastReason then
							lastReason = reason
							notify('Not loading: '..reason..'.\nLeave to requeue, or press Load in now in the module.', 15, 'warning')
						end
						dodgeSince = dodgeSince or os.clock()
						if settings.requeue == true and os.clock() - dodgeSince >= 3 then
							requeue(nil, reason)
						end
					elseif os.clock() - lastWaitNotice >= 6 then
						lastReason = nil
						lastWaitNotice = os.clock()
						notify('Waiting: '..reason..'.', 5)
					end
					task.wait(0.5)
				end
			end)
			if not ok then
				-- Never strand anyone on an error in here: let the match in.
				if hold.state == 'held' and hold.release then
					hold.release()
				elseif hold.state == 'waiting' then
					hold.state = 'failed'
				end
				notify('Stopped checking this match ('..tostring(err)..'), loading you in.', 10, 'alert')
			end
		end)
	end
end
]==]..teleportScript
			do
				local token = tostring(game.JobId)..'-'..tostring(os.clock())..'-'..tostring(math.random(1, 2147483647))
				if pcall(writefile, teleportTokenPath, token) then
					local path = string.format('%q', teleportTokenPath)
					teleportScript = 'do local tokenOk, tokenNow = pcall(readfile, '..path..')\n'
						..'if tokenOk and tokenNow ~= '..string.format('%q', token)..' then return end\n'
						..'pcall(writefile, '..path..', "") end\n'..teleportScript
				end
			end
			local queued = pcall(queue_on_teleport, teleportScript)
			if queued and hasQueueOnTeleport then
				pcall(rawset, shared, 'PistonwareTeleportQueued', true)
			end

			if not hasQueueOnTeleport then
				pcall(function()
					slinky:notify('Pistonware', 'queue_on_teleport is not supported by your executor -- Pistonware will not re-inject automatically after this teleport (e.g. queueing into a match). You will need to re-run your loadstring manually.', 15, 'alert')
				end)
			end

			if profileApplied then
				pcall(function() slinky:save() end)
			end
		end
	end))

	if shared.PistonwareSyncResult then
		slinky:notify('Pistonware', shared.PistonwareSyncResult, 15, shared.PistonwareSyncResult:find('failed') and 'alert' or nil)
		shared.PistonwareSyncResult = nil
	end

	if not shared.slinkyreload then
		pcall(function()
			if not slinky.categories then return end
			local indicator = slinky.settings and slinky.settings.GUI and slinky.settings.GUI.options['GUI bind indicator']
			if not (indicator and indicator.enabled) then return end
			local keys = slinky.menuBind and slinky.menuBind.keys
			local how = slinky.menuButton and 'Tap the piston button in the top bar to open the GUI'
				or (keys and #keys > 0) and ('Press '..table.concat(keys, ' + '):upper()..' to open GUI')
				or 'Open the GUI with your keybind'
			slinky:notify('Pistonware | Finished Loading', how, 5)
		end)
	end
end

	--[[
		One GUI now: guilibrary.lua, next to this file.

		Images the GUI fetches on demand go in assets/icons.
	]]
	local GUI_PATH = 'pistonware/guilibrary.lua'
	local ICON_FOLDER = 'pistonware/assets/icons'

	--[[ Deletes, once, what older builds left that nothing reads: gui.txt at the root and in profiles/,
	profiles/whitelist.json, assets/new, the GUI files in guis/ and then guis/ itself once empty.
	Every step is pcall'd, so an item stays where the executor lacks a file function or one fails;
	cleanup.txt marks that it ran. whitelist.json can be a profile of that name, so it stays while
	settings.json lists one in any letter case or cannot be decoded. ]]
	local function cleanOldInstall()
		local marker = 'pistonware/cleanup.txt'
		if isfile(marker) then return end
		for _, path in {'pistonware/gui.txt', 'pistonware/profiles/gui.txt', 'pistonware/guis/newgui.lua', 'pistonware/guis/new.lua',
			'pistonware/guis/old.lua', 'pistonware/guis/rise.lua'} do
			pcall(function()
				if isfile(path) then delfile(path) end
			end)
		end
		pcall(function()
			local path, settingsPath = 'pistonware/profiles/whitelist.json', 'pistonware/profiles/settings.json'
			if not isfile(path) then return end
			if isfile(settingsPath) then
				local settings = game:GetService('HttpService'):JSONDecode(readfile(settingsPath))
				if type(settings) ~= 'table' then return end
				for _, row in type(settings.profiles) == 'table' and settings.profiles or {} do
					if type(row) == 'table' and type(row.name) == 'string' and row.name:lower() == 'whitelist' then return end
				end
			end
			delfile(path)
		end)
		pcall(function()
			if isfolder('pistonware/assets/new') then delfolder('pistonware/assets/new') end
		end)
		pcall(function()
			if isfolder('pistonware/guis') and #listfiles('pistonware/guis') == 0 then delfolder('pistonware/guis') end
		end)
		pcall(writefile, marker, '1')
	end
	cleanOldInstall()

	--[[
		No asset prefetch, and nothing to prefetch for.

		The GUI now resolves every icon it draws to an uploaded rbxassetid and never opens a file
		under pistonware/assets. This used to download the whole folder -- 105 files, 105 HTTP
		requests and 105 disk writes -- on the critical path of the first run, on every platform,
		and the desktop GUI then read each of those files back twice per icon.

		A few paths that only game modules ask for still have no uploaded id, so the GUI keeps a
		lazy fallback for exactly those: it downloads them the first time a module that draws one is
		built, not here, and not for anyone who never opens it. Prefetching 105 files to serve
		five of them was the expensive way round.

		The folder is still created, because that lazy fallback writes into it.
	]]
	if not isfolder(ICON_FOLDER) then
		makefolder(ICON_FOLDER)
	end
	stage('downloading gui')
	slinky = runChunk(downloadFile(GUI_PATH, nil, 'gui'), 'gui')
	stage('gui chunk returned')
	if not slinky then return end
	shared.slinky = slinky

--[[ Runs universal.lua and the place's game script, then finishLoading; with shared.SlinkyIndependent,
finishLoading is handed back as slinky.init instead. The wait for game:IsLoaded has a 120 s
deadline: unbounded, it parks the boot after the menu is up. universal.lua runs under xpcall, so its
error cannot skip the game script.

The game script is started with task.spawn and never waited on: a game file that registers without
yielding has finished before the next line, and bedwars.lua takes about 30 s, which must not hold up
the GUI, the universal modules or the profile. Before it runs, shared.PistonwareBedwarsLoaded and
shared.PistonwareSessionRejected are cleared, since shared survives a reinject, and the key is
written again to script_key as a global, in getgenv() and in _G: a load finding it empty kicks the
player, and on several mobile executors those are three different tables.

The place file comes from the cache when hasContent accepts it, else from GitHub with 4 tries;
developer mode replaces nothing and fails the boot on a copy that does not compile. A 404 means an
unsupported game: universal.lua is then the whole module set and the profile still loads. A body is
taken only when it is no error page and compiles. On a repair boot with GitHub out of reach the
intact copy on disk runs. A file that did not land on disk sets shared.PistonwareCacheWriteFailed
for the loader. ]]
if not shared.SlinkyIndependent then
	if not game:IsLoaded() then
		local loadDeadline = os.clock() + 120
		repeat task.wait() until game:IsLoaded() or os.clock() > loadDeadline
		local executorName = ''
		pcall(function() executorName = identifyexecutor and identifyexecutor() or '' end)
		task.wait(executorName == 'Opiumware' and 30 or 5)
	end
	stage('universal.lua start')
	do
		local okUniversal, universalError = xpcall(function()
			runChunk(downloadFile('pistonware/games/universal.lua', nil, 'universal'), 'universal')
		end, errorTrace)
		if not okUniversal then
			failBoot('universal.load', universalError)
			reportRuntimeError('universal.load', universalError, universalError)
		end
	end

	local gameArgs = table.pack(...)
	local function runGameScript(source, chunkname)
		local fn, compileError = takeValidatedChunk(source, chunkname)
		if not fn then
			fn, compileError = loadstring(source, chunkname)
		end
		if not fn then
			local trace = errorTrace(compileError)
			failBoot('game.compile', trace)
			gameScriptFinished = true
			reportRuntimeError('game.compile', compileError, trace)
			return false
		end
		gameScriptFinished = false
		shared.PistonwareBedwarsLoaded = nil
		payloadTableBefore = shared.bedwars
		shared.PistonwareSessionRejected = nil

		if type(shared.PistonwareKey) == 'string' and shared.PistonwareKey ~= '' then
			local key = shared.PistonwareKey
			script_key = key
			pcall(function() getgenv().script_key = key end)
			pcall(function() _G.script_key = key end)
		end

		local started = os.clock()
		task.spawn(function()
			local ok, result = xpcall(function()
				return fn(table.unpack(gameArgs, 1, gameArgs.n))
			end, errorTrace)
			if not ok then
				failBoot('game.execute', result)
			elseif type(result) == 'table' and result.PistonwareBootFailure then
				failBoot(result.stage or 'game.execute', result.error or 'game script reported an incomplete boot')
			end
			gameScriptFinished = true
			local elapsed = os.clock() - started
			if elapsed > 5 then
				debugWarn(('[pistonware] %s finished in %.1fs -- its modules now have their saved settings'):format(chunkname, elapsed))
			end
			if not ok then
				reportRuntimeError('game.execute', result, result)
			end
		end)
		return true
	end

	local gamePath = 'pistonware/games/'..game.PlaceId..'.lua'
	local gameScriptStarted = false
	local adapterMissing = false
	local rejected, compileError
	local cached = (cacheAllowed() or shared.PistonwareDeveloper) and hasContent(gamePath, tostring(game.PlaceId)) or nil
	if cached and cached:find('%S') then
		gameScriptStarted = runGameScript(cached, tostring(game.PlaceId))
	end
	if not cached and shared.PistonwareDeveloper then
		local ok, text = pcall(readfile, gamePath)
		if isfile(gamePath) and ok and type(text) == 'string' and text:find('%S') then
			local compileOk, chunk, err = pcall(rawLoadstring, text, tostring(game.PlaceId))
			compileError = gamePath..' does not compile (developer mode does not replace it): '..tostring(compileOk and err or chunk)
		end
	end
	if not gameScriptStarted and not shared.PistonwareDeveloper then
		local res
		local offline = release.repairFallback == true and release.repairOffline == true
		local onDisk
		for attempt = 1, 4 do
			local suc, body = pcall(function()
				return pistonwareHttpGet(projectRawUrl('games/'..game.PlaceId..'.lua'), true)
			end)
			if suc and body == '404: Not Found' then
				adapterMissing = true
				break
			end
			if suc and type(body) == 'string' and body ~= '' and not body:match('^%d%d%d: ') then
				local head = body:sub(1, 200):lower()
				if head:find('<!doctype html', 1, true) or head:find('<html', 1, true) then
					rejected = 'GitHub sent an error page'
				else
					local compileOk, chunk, err = pcall(rawLoadstring, body, tostring(game.PlaceId))
					if compileOk and type(chunk) == 'function' then
						validatedChunks[gamePath] = {body = body, name = tostring(game.PlaceId), chunk = chunk}
						res = body
						break
					end
					rejected = 'the download did not compile'
					compileError = tostring(compileOk and err or chunk)
				end
			end
			if offline then
				if onDisk == nil then
					onDisk = hasContent(gamePath, tostring(game.PlaceId)) or false
				end
				if onDisk and onDisk:find('%S') then break end
			end
			if attempt < 4 then
				task.wait(attempt)
			end
		end
		if not res and not adapterMissing and release.repairFallback == true then
			if onDisk == nil then
				onDisk = hasContent(gamePath, tostring(game.PlaceId)) or false
			end
			if onDisk and onDisk:find('%S') then
				bufferWarn('cache.repair', 'could not fetch '..gamePath..' again; the intact copy on disk runs')
				gameScriptStarted = runGameScript(onDisk, tostring(game.PlaceId))
			end
		end
		if res then
			local wrote = pcall(writefile, gamePath, res)
			if wrote then
				local readOk, back = pcall(readfile, gamePath)
				wrote = readOk and back == res
			end
			if not wrote then
				shared.PistonwareCacheWriteFailed = true
			end
			gameScriptStarted = runGameScript(res, tostring(game.PlaceId))
		end
	end
	if not gameScriptStarted then
		if not adapterMissing and compileError then
			if slinky then
				pcall(slinky.notify, slinky, 'Pistonware', 'Failed to load : '..compileError, 30, 'alert')
			end
			local trace = errorTrace(compileError)
			failBoot('game.compile', trace)
			reportRuntimeError('game.compile', compileError, trace)
		elseif not adapterMissing then
			failBoot('game.download', 'no usable game adapter could be loaded for '..tostring(game.PlaceId)
				..(rejected and ' ('..rejected..')' or ''))
		end
		gameScriptFinished = true
	end
	finishLoading()
else
	slinky.init = finishLoading
	return slinky
end
