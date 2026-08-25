--[[ The loader is the only supported entry point: it runs the LuaArmor key gate and publishes
script_key (which the protected bedwars.lua reads) before any of this downloads or executes.
main.lua is re-run directly in two places -- the queued teleport script below, and the GUI's
reinject buttons -- and both re-establish that state first, so reaching here without it means
the gate was skipped. Checked before the uninject below, so a failed check cannot tear down a
working instance on its way out. ]]
if not shared.PistonwareAuthenticated then
	warn('[pistonware] not authenticated -- run the pistonware loader and enter your key')
	return
end

--[[ pcall'd: after a teleport shared.vape can still point at the previous server's instance,
whose GUI and connections no longer exist. An error walking that corpse would abort main.lua
on line one and leave the queued re-injection doing nothing at all. ]]
local queuedReload = shared.vapereload == true
if shared.vape then
	pcall(function() shared.vape:Uninject() end)
	if queuedReload then shared.vapereload = true end
end

local vape
local loadstring = function(...)
	local res, err = loadstring(...)
	if err and vape then
		vape:CreateNotification('Pistonware', 'Failed to load : '..err, 30, 'alert')
	end
	return res
end
local function runChunk(source, name)
	local chunk = loadstring(source, name)
	return chunk and chunk()
end
local queue_on_teleport = queue_on_teleport or syn and syn.queue_on_teleport
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
local playersService = cloneref(game:GetService('Players'))

--[[ Phones and tablets. Kept for the teleport path and notifications; it no longer paces saves. ]]
local isTouchDevice = false
pcall(function()
	isTouchDevice = cloneref(game:GetService('UserInputService')).TouchEnabled and true or false
end)

--[[ Telemetry the developer build prints and the public build does not.

Module counts and load timings are what you want in front of you while working on the loader,
and noise in a paying user's console -- they are yellow, they say [pistonware], and they turn
up at exactly the moment the script starts working, so they read as something having gone
wrong. Real failures still use warn() directly and are unaffected.

Gated at runtime rather than at build time because main.lua is one file serving both builds.
PUBLIC_BUILD nulls shared.PistonwareDeveloper and locks it behind a metatable, so this is off
for everyone except the developer build by construction -- and the queued teleport script
carries the flag across, so it stays on for a developer through a match join. ]]
local function debugWarn(...)
	if shared.PistonwareDeveloper then
		warn(...)
	end
end

--[[
	Breadcrumbs, off unless asked for:

		getgenv().PistonwareTrace = true

	The GUI keeps the same log (vape:Trace writes into this very table) but cannot record
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

--[[
	A heartbeat, so the log says WHEN it died and not only where.

	Without it, a crash during a long silent stretch is indistinguishable from a crash at the
	last thing that logged. Rewrites one line in place rather than appending, so a long session
	costs one small write every two seconds and the log stays readable.
]]
if traceOn then
	local started = os.clock()
	local index
	local trend = {}
	task.spawn(function()
		while true do
			task.wait(2)
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

--[[ `isfile` alone is insufficient. A zero-byte file reads back as PRESENT through every executor's
real isfile, and only the fallback above treats empty as absent -- so on executors that ship
one (most of them), an interrupted write leaves a truncated file that nothing ever repairs.

That is not hypothetical: cancelling, crashing or teleporting mid-download leaves a
half-written file, and from then on every cache-first route skips it forever. For a .lua file
that means a chunk that never loads. Every route that could have fixed it asked isfile and was
told the file was fine, which is why the only known remedy was reinstalling the whole script.

Treating empty as missing makes it repair itself on the next run instead. ]]
local function hasContent(path)
	if not isfile(path) then return false end
	local ok, body = pcall(readfile, path)
	if not ok or type(body) ~= 'string' or body == '' then return false end
	if path:match('%.lua$') then
		local compileOk, chunk = pcall(loadstring, body, path)
		return compileOk and type(chunk) == 'function'
	end
	return true
end

local function downloadFile(path, func)
	if not hasContent(path) then
		--[[ bedwars.lua only exists in the GitLab repo (kept separate/obfuscated there), at that
		repo's ROOT even though it caches locally under games/; everything else lives in the
		GitHub repo. ]]
		local relPath = select(1, path:gsub('pistonware/', ''))
		local isBedwars = relPath == 'games/bedwars.lua'
		--[[ Retried a few times: raw file hosts intermittently fail, returning an empty body that
		would otherwise get cached as a corrupt/empty file. ]]
		local content
		for attempt = 1, 4 do
			local suc, res = pcall(function()
				if isBedwars then
					return game:HttpGet('https://gitlab.com/pistonware/pistonware/-/raw/main/bedwars.lua', true)
				end
				return game:HttpGet('https://raw.githubusercontent.com/themagicpiston/pistonware/main/'..relPath, true)
			end)
			--[[ For .lua files, compile-check downloads so an outage page is not cached. ]]
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
		if path:find('%.lua$') then
			content = '--This watermark is used to delete the file if its cached, remove it to make the file persist after vape updates.\n'..content
		end
		writefile(path, content)
	end
	return (func or readfile)(path)
end

--[[ The repo-folder listing and concurrent prefetch are gone. Icons use uploaded IDs; remaining
assets load lazily when a module needs them. ]]

--[[ False while a game script registers modules. finishLoading uses this because saving and
profile application must wait for the module set. ]]
local gameScriptFinished = true

--[[ Set after the profile is applied; teleport saves are allowed only then. ]]
local profileApplied = false

local function finishLoading()
	vape.Init = nil
	--[[ shared.VapeCustomProfile is a ONE-SHOT hint for the load that immediately follows
	(set by the loader's first-run config chooser, or by the teleport handler below).
	Capture and clear it up front: getgenv()/shared persists across a reinject, so a
	value left over from an earlier teleport would keep forcing that old profile and
	override the config you actually switched to -- that stale value was the reinject
	'loads the wrong config' bug. Cleared here, a plain reinject always falls through to
	the profile saved in gui.txt (i.e. whatever you last switched to). ]]
	local customProfile = shared.VapeCustomProfile
	shared.VapeCustomProfile = nil
	if customProfile == '' then customProfile = nil end

	--[[
		The profile is applied EXACTLY ONCE, and only after every module exists.

		Loading it early and re-applying afterwards was tried and is wrong in both directions.
		Too early and the payload's modules do not exist yet, so they load on defaults; and the
		second pass needed to fix that would happily overwrite anything you had changed by hand
		in the meantime -- a toggle flipped at 10s silently reverting at 30s is a far worse bug
		than a config that arrives late. One load, once everything is registered, is the only
		version that cannot fight the user.

		Save() has the same constraint from the other side: it serialises the module list as it
		stands, so any save taken before the payload finishes writes a profile missing every
		module yet to appear -- destroying those settings on disk. vape.Loaded stays false for the
		whole of vape:Load, which is what holds saving off until the apply is complete.

		The one exception is a payload that runs past the backstop. Those modules are not lost:
		vape:LoadLate applies their saved settings when they finally register, and it touches only
		the ones that arrived after the load, so it cannot revert anything changed by hand.
	]]
	local function applyProfile(moduleSetComplete)
		--[[ A LuaArmor session that was refused registers no game modules (see the session
		block at the top of bedwars.lua). Loading a profile against that empty set would
		bring everything up on defaults, and the Save below would write those defaults
		back -- deleting the user's real config. Withholding the modules is the intended
		consequence of a refusal; deleting configs is not, so do neither here. ]]
		if shared.PistonwareSessionRejected then
			warn('[pistonware] session was not authorised -- leaving profiles untouched')
			return
		end
		debugWarn(('[pistonware] applying profile %s (teleported=%s)'):format(
			tostring(customProfile or '<saved>'), tostring(shared.vapereload and true or false)))
		vape:Load(nil, customProfile)
		debugWarn('[pistonware] profile load returned')

		--[[
			No autosave loop, and nothing timed anywhere in the save path.

			There used to be one because the only way to write safely was to wait until the module set
			had stopped changing, and with a payload that never announces it had finished the only
			available answer was a guess: watch the count, call it settled after thirty seconds of
			quiet, then poll every ten. Every part of that was a workaround for vape:Save walking a hash
			table the payload was still inserting into.

			Save walks vape.ModuleOrder now -- an array, by index -- which nothing about a registration
			can invalidate. That removes the reason to wait, and with it the timer, the poll, and the
			gate they existed to open. A module toggle writes through vape:RequestSave; vape.Loaded is
			the only thing gating it, and vape:Load owns that flag.
		]]
		profileApplied = true

		if not moduleSetComplete then
			warn('[pistonware] the payload never signalled completion -- re-upload games/bedwars.lua to LuaArmor.')
			--[[
				The modules that were not registered in time still have their settings on disk, and
				vape:LoadLate is what puts them on. It only touches modules that appeared AFTER the
				profile was applied, so anything toggled by hand in the meantime is left alone.

				No deadline on this watcher: it is waiting for the game script to finish, and if it
				never does there is nothing to apply and nothing lost by still waiting.
			]]
			task.spawn(function()
				repeat task.wait(1) until gameScriptFinished
					or shared.PistonwareBedwarsLoaded
					or not vape.Loaded
					or shared.PistonwareSessionRejected

				if vape.Loaded and not shared.PistonwareSessionRejected then
					local applied = 0
					pcall(function() applied = vape:LoadLate() or 0 end)
					debugWarn(('[pistonware] payload finished late -- applied saved settings to %d further modules'):format(applied))
					if applied > 0 then
						pcall(function() vape:RequestSave() end)
					end
				end
			end)
		end
	end

	--[[ Waits until the game script has finished registering its modules, because the profile can
	only be applied to modules that exist.

	There are exactly two ways that finish is observable, and no third:
	  * an ordinary game script RETURNS, which sets gameScriptFinished
	  * BedWars pulls in a LuaArmor-protected payload which never returns (the VM keeps the
	    thread it was invoked on), so bedwars.lua sets shared.PistonwareBedwarsLoaded as its
	    final statement

	An earlier version tried to infer completion by watching the module count go quiet. It
	does not work, and cannot be made to: the first seconds of downloadBedwars() are pure
	network, so nothing registers, and "nothing registering" is indistinguishable from
	"finished". It declared victory at 4s -- before the payload had started -- and every
	module that appeared afterwards was left on defaults. Guessing is worse than waiting.

	The timeout is a backstop, not a mechanism. It only matters when the payload on LuaArmor
	predates the completion flag; re-upload bedwars.lua and this returns the moment it lands.
	Returns whether the module list is actually COMPLETE, which is not the same as whether
	the wait finished. Hitting the backstop means the payload is still registering, and the
	caller has to know that before it writes anything to disk. ]]
	local function waitForModules()
		if gameScriptFinished then return true end
		local started = os.clock()
		repeat
			task.wait(0.1)
		until gameScriptFinished
			or shared.PistonwareBedwarsLoaded
			or os.clock() - started > 120
		local complete = (gameScriptFinished or shared.PistonwareBedwarsLoaded) and true or false
		--[[ Same reason as the settle-watcher below: on the timeout path the payload is still
		inserting, so this must not walk vape.Modules to count them. ]]
		local count = vape.ModuleCount or 0
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
			applyProfile(waitForModules())
		end)
	end

	local teleportedServers
	vape:Clean(playersService.LocalPlayer.OnTeleport:Connect(function(teleportState)
		--[[ A failed teleport is ignored rather than consumed. OnTeleport fires for EVERY state
		and the one-shot guard below does not look at which -- so an attempt that failed used
		to burn it, and the teleport that actually went somewhere afterwards queued nothing. ]]
		if teleportState == Enum.TeleportState.Failed then return end
		if (not teleportedServers) and (not shared.VapeIndependent) then
			teleportedServers = true
			--[[ Re-runs main.lua, not the loader. The loader is a full boot -- duplicate-run
			guard, GitHub API calls for the update check, the console window, the config
			prompt -- and any one of those bailing on the new server leaves the script
			uninjected. main.lua only needs the files the loader already cached, so it
			comes back reliably; the loader still runs on a manual execute. ]]
				local teleportScript = [[
					shared.vapereload = true
					local cached = isfile and isfile('pistonware/main.lua') and readfile('pistonware/main.lua')
					if cached and cached ~= '' then
						local chunk = loadstring(cached, 'main')
						if chunk then chunk() end
					else
						local chunk = loadstring(game:HttpGet('https://raw.githubusercontent.com/themagicpiston/pistonware/main/main.lua', true), 'main')
						if chunk then chunk() end
					end
				]]
			--[[ Globals and shared do not survive a teleport, and the new server re-runs main.lua
			directly rather than the loader -- so the key gate's output has to be re-published
			by hand here. Without it the guard at the top of this file would reject the
			re-injection, and bedwars.lua would be handed to loadstring with no script_key.
			%q so a key containing a quote or backslash still produces a valid chunk. ]]
			if shared.PistonwareKey then
				local quoted = string.format('%q', shared.PistonwareKey)
				teleportScript = 'script_key = '..quoted..'\nshared.PistonwareKey = '..quoted..'\nshared.PistonwareAuthenticated = true\n'..teleportScript
			end
			if shared.PistonwareDeveloper then
				teleportScript = 'shared.PistonwareDeveloper = true\n'..teleportScript
			end
			if shared.VapeSmoothBoot then
				teleportScript = 'shared.VapeSmoothBoot = true\n'..teleportScript
			end
			--[[ getgenv() and shared are wiped by a teleport; carry tracing and the optional yield
			budget into the match. ]]
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
			-- %q, matching the key above: profile names are user-supplied (the Profiles tab lets
			-- you name one anything), and a name containing a quote or backslash used to produce
			-- a chunk that would not compile -- which silently costs the whole re-injection, not
			-- just the profile.
			-- customProfile is the fallback rather than shared.VapeCustomProfile (cleared above):
			-- queueing before the payload has finished means vape.Profile is not set yet, and
			-- without this the next server would be told to load 'default'.
			teleportScript = 'shared.VapeCustomProfile = '..string.format('%q', vape.Profile or customProfile or 'default')..'\n'..teleportScript
			--[[
				Queue FIRST, and guard everything after it.

				The queue call used to be LAST, sitting behind an unguarded vape:Save(). Two
				things were wrong with that, and together they are the crash people hit when
				queueing from one match straight into another:

				  * Save() serialises every module and writes a file. This callback runs while
				    the client is already tearing down for the teleport, and a blocking disk
				    write in that window is what takes the game down with it -- worst on mobile,
				    where storage is slowest and the window is shortest.
				  * Save() was not pcall'd. If it threw, queue_on_teleport never ran at all, so
				    the script silently failed to come back on the new server. A failure to save
				    became a failure to re-inject.

				Queueing first ensures that later save failures do not prevent re-injection.
			]]
			local queueOk, queueError = pcall(queue_on_teleport, teleportScript)
			if not queueOk then
				warn('[pistonware] queue_on_teleport failed: '..tostring(queueError))
			end

			if not hasQueueOnTeleport then
				pcall(function()
					vape:CreateNotification('Pistonware', 'queue_on_teleport is not supported by your executor -- Vape will not re-inject automatically after this teleport (e.g. queueing into a match). You will need to re-run your loadstring manually.', 15, 'alert')
				end)
			end

			--[[ Best effort, and last. Same rule as everywhere else: saving before the profile has
			been applied against the full module set would write one missing every module still
			to appear. Queueing straight into a match is exactly when that happens, so skip the
			save rather than corrupt the config -- what is on disk is already correct, there is
			simply nothing new worth recording yet. ]]
			if profileApplied then
				pcall(function() vape:Save() end)
			end
		end
	end))

	if shared.PistonwareSyncResult then
		vape:CreateNotification('Pistonware', shared.PistonwareSyncResult, 15, shared.PistonwareSyncResult:find('failed') and 'alert' or nil)
		shared.PistonwareSyncResult = nil
	end

	if not shared.vapereload then
		--[[ Cosmetic, and entirely inside a pcall, because the rewrite moved every field it reads.
		'GUI bind indicator' left Categories.Main.Options for Settings.GUI.Options, the keybind
		list became GUIBind.Keys instead of a flat vape.Keybind, and vape.VapeButton no longer
		exists at all. A finished-loading toast is not worth risking finishLoading over if any
		of that moves again. ]]
		pcall(function()
			if not vape.Categories then return end
			local indicator = vape.Settings and vape.Settings.GUI and vape.Settings.GUI.Options['GUI bind indicator']
			if not (indicator and indicator.Enabled) then return end
			local keys = vape.GUIBind and vape.GUIBind.Keys
			local how = (keys and #keys > 0)
				and ('Press '..table.concat(keys, ' + '):upper()..' to open GUI')
				or 'Open the GUI with your keybind'
			vape:CreateNotification('Pistonware | Finished Loading', how, 5)
		end)
	end
end

	--[[
		One GUI now.

		guis/old.lua and guis/rise.lua are discontinued and deleted, so the gui.txt theme
		indirection has nothing left to choose between -- every value it could hold except one
		names a file that would 404. Reading it to decide which GUI to load was a way to break the
		install, not a feature, so the choice is made here instead.

		The asset folder keeps its own separate name: 'new' is the path the GUI itself asks for
		(pistonware/assets/new/...), and that is unrelated to what the GUI file is called.
	]]
	local GUI_FILE = 'newgui'
	local ASSET_FOLDER = 'new'

	--[[ Still written, so anything else reading gui.txt sees something current rather than a
	stale 'rise'/'old' left over from before those were removed. ]]
	pcall(function() writefile('pistonware/profiles/gui.txt', GUI_FILE) end)

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
	if not isfolder('pistonware/assets/'..ASSET_FOLDER) then
		makefolder('pistonware/assets/'..ASSET_FOLDER)
	end
	stage('downloading gui')
	vape = runChunk(downloadFile('pistonware/guis/'..GUI_FILE..'.lua'), 'gui')
	stage('gui chunk returned')
	if not vape then return end
	shared.vape = vape
	if not (vape.Categories and vape.Categories.Friends and vape.Categories.Targets) then
		warn('[pistonware] GUI did not register the required Friends and Targets categories; guis/'..GUI_FILE..'.lua is stale or did not finish loading')
		pcall(function() vape:Uninject() end)
		return
	end

if not shared.VapeIndependent then
	--[[ downloading doesn't need the game loaded; only wait here, right before touching game/character state ]]
	if not game:IsLoaded() then
		--[[ Deadline, matching every equivalent wait in the loader. Unbounded, a place that never
		reports loaded parks this thread forever AFTER the GUI has already been built above --
		so the menu opens, no game modules ever register, and nothing says why. ]]
		local loadDeadline = os.clock() + 120
		repeat task.wait() until game:IsLoaded() or os.clock() > loadDeadline
		--[[ identifyexecutor is absent on some executors (common on mobile); calling it
		unguarded errors here and aborts everything below, including the game script. ]]
		local executorName = ''
		pcall(function() executorName = identifyexecutor and identifyexecutor() or '' end)
		task.wait(executorName == 'Opiumware' and 30 or 5)
	end
	--[[ universal.lua owns the libraries every game payload consumes. Catch its error so the
	real source is reported, then stop instead of loading the game payload against half-built
	state and replacing that error with misleading nil accesses. ]]
	stage('universal.lua start')
	local getIdentity = getthreadidentity or getidentity
	local setIdentity = setthreadidentity or setidentity
	local oldIdentity
	if getIdentity then
		local ok, identity = pcall(getIdentity)
		if ok then oldIdentity = identity end
	end
	if setIdentity then
		pcall(setIdentity, 8)
	end
	local universalOk, universalError = pcall(function()
		runChunk(downloadFile('pistonware/games/universal.lua'), 'universal')
	end)
	if setIdentity and oldIdentity ~= nil then
		pcall(setIdentity, oldIdentity)
	end
	if not universalOk then
		warn('[pistonware] universal.lua failed: '..tostring(universalError))
		pcall(function() vape:Uninject() end)
		return
	end
	if not (vape.Libraries and vape.Libraries.sessioninfo and vape.Libraries.whitelist and type(vape.Libraries.whitelist.get) == 'function') then
		warn('[pistonware] universal.lua finished without registering sessioninfo and whitelist; games/universal.lua is stale or incomplete')
		pcall(function() vape:Uninject() end)
		return
	end

	--[[ Started, never waited on. There is no deadline here by design: a deadline would only be a
	guess at how long the payload needs, and whatever number it held would become the time
	your profile takes to load. Nothing below depends on this having finished -- finishLoading
	applies your profile to the modules that exist now, and re-applies it the moment the rest
	register (see finishLoading).

	This costs nothing for a normal game script: task.spawn runs the function inline until it
	yields, so anything that registers its modules without yielding -- which is every game
	file except BedWars -- has already set gameScriptFinished before we get past this line,
	and finishLoading takes the single-pass path exactly as it always did.

	BedWars is the exception. bedwars.lua is 425KB interpreted by a LuaArmor VM and takes
	~30s, and none of its modules can exist until it finishes -- that part is not fixable from
	here. What it must not do is hold up the GUI, the universal modules and your config, none
	of which have anything to do with it.

	Varargs are packed because '...' is only valid directly in this chunk, never inside the
	nested function the spawn needs. ]]
	local gameArgs = table.pack(...)
	local function runGameScript(source, chunkname)
		local fn, compileError = loadstring(source, chunkname)
		if not fn then
			gameScriptFinished = true
			warn('[pistonware] '..chunkname..' did not compile: '..tostring(compileError))
			return false
		end
		gameScriptFinished = false
		--[[ Cleared per run, not just per session: shared survives a reinject, and a leftover true
		from the previous injection would tell waitForModules the payload had already finished
		before it had even started re-registering. ]]
		shared.PistonwareBedwarsLoaded = nil
		--[[ Same reasoning for the refusal flag: bedwars.lua sets it from a fresh verdict every
		run, but a game script that never sets it at all (the lobby) would otherwise inherit
		a true left behind by a revoked BedWars session and refuse to save profiles there. ]]
		shared.PistonwareSessionRejected = nil

		--[[ Re-publish the key immediately before the game script runs. LuaArmor blanks the global
		script_key once it has authenticated, so it is single-use per session and any later
		load finds nothing -- which is not a soft failure, it kicks the player.

		games/6872274481.lua does this too, closer to the payload, but that file is CACHED:
		anyone still holding a copy from before it gained that call would never get it. This
		file is the one that is reliably current, so the safety net belongs here as well.

		Written to all three tables because executors disagree on what a loadstring'd chunk's
		environment is -- on several mobile executors a bare global, getgenv() and _G are
		genuinely different tables, and the payload only reads one of them. ]]
		if type(shared.PistonwareKey) == 'string' and shared.PistonwareKey ~= '' then
			local key = shared.PistonwareKey
			script_key = key
			pcall(function() getgenv().script_key = key end)
			pcall(function() _G.script_key = key end)
		end

		local started = os.clock()
		task.spawn(function()
			local ok, err = pcall(fn, table.unpack(gameArgs, 1, gameArgs.n))
			gameScriptFinished = true
			--[[ Only for a payload slow enough that the split-load path actually engaged; a normal
			game script never trips it. Keeps the real cost of protecting bedwars.lua visible
			instead of guessed at. ]]
			local elapsed = os.clock() - started
			if elapsed > 5 then
				debugWarn(('[pistonware] %s finished in %.1fs -- its modules now have their saved settings'):format(chunkname, elapsed))
			end
			if not ok then
				warn('[pistonware] '..chunkname..' errored: '..tostring(err))
			end
		end)
		return true
	end

	local gamePath = 'pistonware/games/'..game.PlaceId..'.lua'
	--[[ A cached-but-empty file is treated as missing and refetched: a truncated write from an
	earlier failed download reads back as "present", and loadstring('') silently does
	nothing -- indistinguishable from the game script never loading at all. ]]
	local gameScriptStarted = false
	local cached = hasContent(gamePath) and readfile(gamePath) or nil
	if cached and cached:gsub('%s', '') ~= '' then
		gameScriptStarted = runGameScript(cached, tostring(game.PlaceId))
	end
	if not gameScriptStarted and not shared.PistonwareDeveloper then
		--[[ Single fetch (the old code requested this URL twice: once to probe, then again
		inside downloadFile) and load straight from the response, so a stale/corrupt
		cache file can't shadow what we just downloaded. ]]
		local suc, res = pcall(function()
			return game:HttpGet('https://raw.githubusercontent.com/themagicpiston/pistonware/main/games/'..game.PlaceId..'.lua', true)
		end)
		if suc and res and res ~= '' and res ~= '404: Not Found' then
			pcall(writefile, gamePath, '--This watermark is used to delete the file if its cached, remove it to make the file persist after vape updates.\n'..res)
			gameScriptStarted = runGameScript(res, tostring(game.PlaceId))
		end
	end
	finishLoading()
else
	vape.Init = finishLoading
	return vape
end
