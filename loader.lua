local PUBLIC_BUILD = true

--[[ Builds the error buffer: a ring of the last 512 log entries, published as
getgenv().pistonware.buffer and dumped to pistonware/errors/<time>-<session>.txt when an error is
recorded. Every text goes through safeText, which redacts script keys. It prints to the console only
in developer mode.

Automatic dumps are spaced at least autoDumpInterval (5 s) apart, because each one rewrites the
whole file from every entry; one that comes sooner is delayed until the gap has passed, not dropped,
so the file still ends up holding every error. Explicit dump() and raise() calls are never held
back. Each entry is formatted once when it is recorded, and a dump writes that text back out. ]]
local function installPistonwareBuffer(developerMode)
	local nativePrint, nativeWarn, nativeError = print, warn, error
	local capacity = 512
	local entries = {}
	local head, count, dropped = 1, 0, 0
	local dumping, dumpScheduled, pendingDump = false, false, false
	local filesystemReady = false
	local buffer = {}

	pcall(function()
		filesystemReady = type(isfolder) == 'function' and isfolder('pistonware') and true or false
	end)

	local function timestamp(pathSafe)
		local value
		pcall(function()
			value = os.date(pathSafe and '!%Y%m%dT%H%M%SZ' or '!%Y-%m-%dT%H:%M:%SZ')
		end)
		return value or tostring(os.time())
	end

	local session = tostring(os.time())..'-'..tostring(math.floor(os.clock() * 1000))
	pcall(function()
		local guid = game:GetService('HttpService'):GenerateGUID(false)
		if type(guid) == 'string' and guid ~= '' then session = guid end
	end)
	local sessionFile = session:gsub('[^%w%-]', ''):sub(1, 16)
	local dumpPath = 'pistonware/errors/'..timestamp(true)..'-'..sessionFile..'.txt'

	local function safeText(value, limit)
		local text = tostring(value or '')
		text = text:gsub('[\r\n]+', ' ')
		text = text:gsub('([Ss]cript[_%s]*[Kk]ey%s*[:=]%s*)[^%s,;]+', '%1<redacted>')
		text = text:gsub('([?&][Kk]ey=)[^&%s]+', '%1<redacted>')
		limit = limit or 1200
		if #text > limit then text = text:sub(1, limit - 3)..'...' end
		return text
	end

	local function copyDetails(details)
		local result = {}
		if type(details) == 'table' then
			for key, value in pairs(details) do
				if type(value) ~= 'table' and type(value) ~= 'function' then
					result[safeText(key, 80)] = safeText(value, 3000)
				end
			end
		end
		return result
	end

	local function formatEntry(entry)
		local parts = {}
		for key, value in pairs(entry.details) do
			table.insert(parts, tostring(key)..'='..tostring(value))
		end
		table.sort(parts)
		local line = ('[%s] [pistonware] [%s] [%s] %s'):format(
			entry.timestamp,
			entry.level:upper(),
			entry.event,
			entry.message
		)
		if #parts > 0 then line = line..' '..table.concat(parts, ' ') end
		return line
	end

	local function orderedEntries()
		local result = {}
		for offset = 0, count - 1 do
			result[#result + 1] = entries[((head + offset - 1) % capacity) + 1]
		end
		return result
	end

	local autoDumpInterval = 5
	local lastAutoDump

	local function requestDump()
		pendingDump = true
		if not filesystemReady or dumping or dumpScheduled then return end
		dumpScheduled = true
		local function flush()
			dumpScheduled = false
			lastAutoDump = os.clock()
			buffer.dump('automatic error')
		end
		local holdFor = lastAutoDump and lastAutoDump + autoDumpInterval - os.clock() or 0
		if holdFor > 0 and task and type(task.delay) == 'function' then
			task.delay(holdFor, flush)
		elseif task and type(task.defer) == 'function' then
			task.defer(flush)
		else
			flush()
		end
	end

	local function record(level, event, message, details)
		local entry = {
			timestamp = timestamp(false),
			level = safeText(level, 20):lower(),
			event = safeText(event, 160),
			message = safeText(message, 1600),
			details = copyDetails(details)
		}
		if count < capacity then
			entries[((head + count - 1) % capacity) + 1] = entry
			count += 1
		else
			entries[head] = entry
			head = (head % capacity) + 1
			dropped += 1
		end

		local line = formatEntry(entry)
		entry.line = line
		if developerMode then
			if entry.level == 'warn' or entry.level == 'error' or entry.level == 'fatal' then
				pcall(nativeWarn, line)
			else
				pcall(nativePrint, line)
			end
		end
		if entry.level == 'error' or entry.level == 'fatal' then requestDump() end
		return line
	end

	function buffer.log(event, message, details)
		return record('info', event, message, details)
	end

	function buffer.print(event, message, details)
		return record('info', event, message, details)
	end

	function buffer.warn(event, message, details)
		return record('warn', event, message, details)
	end

	function buffer.error(event, message, details)
		return record('error', event, message, details)
	end

	function buffer.raise(event, message, details, level)
		record('error', event, message, details)
		buffer.dump('raised error')
		return nativeError(message, (tonumber(level) or 1) + 1)
	end

	function buffer.guard(stage, fatal, callback, ...)
		local args = table.pack(...)
		local result = table.pack(xpcall(function()
			return callback(table.unpack(args, 1, args.n))
		end, function(err)
			local trace
			pcall(function()
				trace = debug and type(debug.traceback) == 'function' and debug.traceback(tostring(err), 2)
			end)
			return trace or tostring(err)
		end))
		if not result[1] then
			record(fatal and 'fatal' or 'error', stage, result[2], {traceback = result[2]})
		end
		return table.unpack(result, 1, result.n)
	end

	function buffer.snapshot()
		local snapshot = {}
		for index, entry in ipairs(orderedEntries()) do
			snapshot[index] = {
				timestamp = entry.timestamp,
				level = entry.level,
				event = entry.event,
				message = entry.message,
				details = copyDetails(entry.details)
			}
		end
		return snapshot, dropped
	end

	function buffer.dump(reason)
		if dumping then return false, 'a buffer dump is already running', count end
		if not filesystemReady then
			pendingDump = true
			return false, 'the pistonware filesystem is not ready', count
		end
		if type(writefile) ~= 'function' then return false, 'writefile is unavailable', count end
		pendingDump = false
		dumping = true
		local ok, result = pcall(function()
			if type(isfolder) == 'function' and type(makefolder) == 'function' then
				if not isfolder('pistonware/errors') then makefolder('pistonware/errors') end
			end
			local release = type(shared.PistonwareRelease) == 'table' and shared.PistonwareRelease or {}
			local lines = {
				'Pistonware error buffer',
				'session='..session,
				'dumped='..timestamp(false),
				'reason='..safeText(reason or 'manual', 240),
				'channel='..safeText(release.channel or 'unknown', 80),
				'version='..safeText(release.version or 'unknown', 160),
				'placeId='..safeText(game and game.PlaceId or 0, 40),
				'entries='..tostring(count),
				'dropped='..tostring(dropped),
				''
			}
			for _, entry in ipairs(orderedEntries()) do
				lines[#lines + 1] = entry.line
			end
			writefile(dumpPath, table.concat(lines, '\n')..'\n')
			return dumpPath
		end)
		dumping = false
		if ok then
			if pendingDump then requestDump() end
			return true, result, count
		end
		pendingDump = true
		return false, tostring(result), count
	end

	local function markFilesystemReady()
		filesystemReady = true
		if pendingDump then requestDump() end
	end

	pcall(function()
		local env = type(getgenv) == 'function' and getgenv() or nil
		if type(env) ~= 'table' then return end
		local namespace = env.pistonware
		if type(namespace) ~= 'table' then
			namespace = {}
			env.pistonware = namespace
		end
		namespace.buffer = buffer
	end)

	return buffer, markFilesystemReady
end

local pistonwareBuffer, markPistonwareBufferFilesystemReady = installPistonwareBuffer(false)

local VERSION_SCHEMA = 1
local CHANNELS = {
	main = {branch = 'main', label = 'stable'},
	beta = {branch = 'beta', label = 'beta'},
	nightly = {branch = 'nightly', label = 'nightly'}
}

local function configuredValue(name)
	local value
	pcall(function()
		local env = type(getgenv) == 'function' and getgenv() or nil
		if type(env) == 'table' then
			value = env[name]
		end
	end)
	if value == nil then
		pcall(function()
			value = shared[name]
		end)
	end
	return value
end

local requestedChannel = configuredValue('PistonwareChannel')
if type(requestedChannel) ~= 'string' then
	requestedChannel = 'main'
end
requestedChannel = requestedChannel:lower():gsub('^%s*(.-)%s*$', '%1')
local channelSpec = CHANNELS[requestedChannel]
local invalidChannel = channelSpec == nil
channelSpec = channelSpec or CHANNELS.main

local release = {
	schema = VERSION_SCHEMA,
	channel = channelSpec.branch == requestedChannel and requestedChannel or 'main',
	branch = channelSpec.branch,
	label = channelSpec.label,
	sourceRef = channelSpec.branch,
	requestedChannel = requestedChannel,
	cacheReady = false,
	resolved = false
}

local function safeText(value, limit)
	local text = tostring(value or '')
	text = text:gsub('[\r\n]+', ' ')
	text = text:gsub('([Ss]cript[_%s]*[Kk]ey%s*[:=]%s*)[^%s,;]+', '%1<redacted>')
	text = text:gsub('([?&][Kk]ey=)[^&%s]+', '%1<redacted>')
	limit = limit or 900
	if #text > limit then
		text = text:sub(1, limit - 3)..'...'
	end
	return text
end

local function jsonEncode(value)
	local ok, encoded = pcall(function()
		return game:GetService('HttpService'):JSONEncode(value)
	end)
	if ok and type(encoded) == 'string' then
		return encoded
	end
	local text = safeText(value, 1800)
	text = text:gsub('\\', '\\\\'):gsub('"', '\\"')
	return '"'..text..'"'
end

--[[ Paths already size-checked this boot. appendfile never trims, so each log is capped once
per boot, the same way the fallback below caps it on every write. ]]
local trimmedLogs = {}
local function appendText(path, text)
	if type(appendfile) == 'function' then
		if not trimmedLogs[path] and type(readfile) == 'function' and type(writefile) == 'function' then
			trimmedLogs[path] = true
			pcall(function()
				local body = readfile(path)
				if type(body) == 'string' and #body > 262144 then
					writefile(path, body:sub(-131072))
				end
			end)
		end
		local ok = pcall(appendfile, path, text)
		if ok then return true end
	end
	if type(writefile) ~= 'function' then return false end
	local previous = ''
	if type(readfile) == 'function' then
		pcall(function()
			local body = readfile(path)
			if type(body) == 'string' then previous = body end
		end)
	end
	if #previous > 262144 then
		previous = previous:sub(-131072)
	end
	return pcall(writefile, path, previous..text)
end

--[[ Log and telemetry lines are held per file during the boot and written with one append per
file at each boot phase, instead of one disk write per line. A warning, an error or a telemetry
report writes out everything held straight away, so whatever led up to a failure is on disk even
if the loader dies right after it. Once the boot has ended -- main.lua keeps reporting through the
telemetry handed to it -- every line goes straight to disk again. ]]
local heldLogText, heldLogOrder = {}, {}
local holdingLogs = true

local function writeLogText(path, text)
	if not holdingLogs then
		appendText(path, text)
		return
	end
	local held = heldLogText[path]
	if not held then
		held = {}
		heldLogText[path] = held
		table.insert(heldLogOrder, path)
	end
	table.insert(held, text)
end

local function flushLogs()
	if #heldLogOrder == 0 then return end
	local order, held = heldLogOrder, heldLogText
	heldLogText, heldLogOrder = {}, {}
	for _, path in order do
		appendText(path, table.concat(held[path]))
	end
end

local function stopHoldingLogs()
	holdingLogs = false
	flushLogs()
end

local function placeId()
	local value
	pcall(function() value = tonumber(game.PlaceId) end)
	return value or 0
end

local function sessionId()
	local guid
	pcall(function()
		guid = game:GetService('HttpService'):GenerateGUID(false)
	end)
	return type(guid) == 'string' and guid or (tostring(os.time())..'-'..tostring(math.floor(os.clock() * 1000)))
end

local function timestamp()
	local value
	pcall(function() value = os.date('!%Y-%m-%dT%H:%M:%SZ') end)
	return value or tostring(os.time())
end

local loaderSession = sessionId()
local logFiles = {'pistonware_loader.log'}
local logFileSet = {['pistonware_loader.log'] = true}
local telemetryFiles = {'pistonware_loader_telemetry.jsonl'}
local telemetryFileSet = {['pistonware_loader_telemetry.jsonl'] = true}

local function addFile(files, seen, path)
	if type(path) ~= 'string' or path == '' or seen[path] then return end
	seen[path] = true
	table.insert(files, path)
end

--[[ Whether the boot log is echoed into the executor output, read HERE -- at the top, before
the public build clears the flag further down -- so that setting

    shared.PistonwareDeveloper = true

in front of the loadstring turns the log on for the whole run. Captured once rather than read
per line precisely because of that clear: read live, only the loader.start line above the
lockout would ever appear.

This switch grants nothing else. The lockout still nils the flag, and isDeveloper is still
computed after it, so developer mode itself stays shut in a public build -- this decides
visibility of the loader's own log lines and nothing more. The lines are safe to show (safeText
redacts anything key-shaped), they are just noise: a wall of INFO during a boot that went fine
reads to an end user like something is broken. ]]
local logToConsole = shared.PistonwareDeveloper and true or false

local Logger = {}
Logger.__index = Logger

function Logger:addFile(path)
	addFile(logFiles, logFileSet, path)
end

function Logger:bindConsole(console)
	self.console = console
	if self.lastLine then
		pcall(function() console:SetLine(self.lastLine) end)
	end
end

function Logger:emit(level, event, message, details)
	local parts = {}
	if type(details) == 'table' then
		for key, value in pairs(details) do
			if type(value) ~= 'table' and type(value) ~= 'function' then
				table.insert(parts, tostring(key)..'='..safeText(value, 240))
			end
		end
		table.sort(parts)
	end
	local line = ('[%s] [pistonware] [%s] [%s] %s'):format(timestamp(), level:upper(), event, safeText(message, 1200))
	if #parts > 0 then line = line..' '..table.concat(parts, ' ') end
	self.lastLine = line
	for _, path in ipairs(logFiles) do
		writeLogText(path, line..'\n')
	end
	if level ~= 'info' then flushLogs() end
	if self.console then
		pcall(function() self.console:SetLine(line) end)
	end
	if level == 'error' then
		pistonwareBuffer.error(event, message, details)
	elseif level == 'warn' then
		pistonwareBuffer.warn(event, message, details)
	else
		pistonwareBuffer.log(event, message, details)
	end
	return line
end

function Logger:info(event, message, details)
	return self:emit('info', event, message, details)
end

function Logger:warn(event, message, details)
	return self:emit('warn', event, message, details)
end

function Logger:error(event, message, details)
	return self:emit('error', event, message, details)
end

local logger = setmetatable({}, Logger)

local Telemetry = {}
Telemetry.__index = Telemetry

local function telemetryValue(value)
	if type(value) == 'string' then return safeText(value, 3000) end
	if type(value) == 'number' or type(value) == 'boolean' then return value end
	return safeText(value, 3000)
end

function Telemetry:addFile(path)
	addFile(telemetryFiles, telemetryFileSet, path)
end

function Telemetry:report(event, message, details)
	local payload = {
		schema = VERSION_SCHEMA,
		event = event,
		message = safeText(message, 1600),
		session = loaderSession,
		channel = release.channel,
		branch = release.branch,
		version = release.version,
		placeId = placeId(),
		at = os.clock()
	}
	if type(details) == 'table' then
		for key, value in pairs(details) do
			if type(value) ~= 'table' and type(value) ~= 'function' then
				payload[key] = telemetryValue(value)
			end
		end
	end
	local encoded = jsonEncode(payload)
	for _, path in ipairs(telemetryFiles) do
		writeLogText(path, encoded..'\n')
	end
	flushLogs()

	local endpoint = self.endpoint
	local requestFn = self.requestFn
	if endpoint and requestFn then
		pcall(requestFn, {
			Url = endpoint,
			Method = 'POST',
			Headers = {['Content-Type'] = 'application/json'},
			Body = encoded
		})
	end
	return payload
end

local telemetry = setmetatable({}, Telemetry)
local configuredTelemetryEndpoint = configuredValue('PistonwareTelemetryEndpoint') or configuredValue('PistonwareTelemetryUrl')
if type(configuredTelemetryEndpoint) == 'string' and configuredTelemetryEndpoint:match('^https://') then
	telemetry.endpoint = configuredTelemetryEndpoint
end
--[[ Picks the executor's HTTP request function for telemetry from request, http_request, httprequest,
syn.request and http.request. Walked by index, not ipairs: ipairs stops at the first name the
executor does not have. ]]
pcall(function()
	local candidates = {
		request,
		http_request,
		httprequest,
		type(syn) == 'table' and syn.request or nil,
		type(http) == 'table' and http.request or nil
	}
	for index = 1, 5 do
		local candidate = candidates[index]
		if type(candidate) == 'function' then
			telemetry.requestFn = candidate
			break
		end
	end
end)

local function reportError(stage, err, trace, fatal)
	local message = safeText(err, 1600)
	logger:error('loader.error', message, {stage = stage, channel = release.channel})
	telemetry:report('loader_error', message, {
		stage = stage,
		fatal = fatal == true,
		traceback = trace and safeText(trace, 3000) or nil
	})
	return message
end

local loaderStopped = false
local function stopExecution(console, stage, err, trace, display)
	if loaderStopped then return false end
	loaderStopped = true
	local message = reportError(stage, err, trace, true)
	stopHoldingLogs()
	shared.PistonwareLoaderBoot = nil
	shared.slinkyreload = nil
	if console then
		pcall(function() console:Fail(display or ('Loader stopped: '..message)) end)
		pcall(function() console:Halt() end)
	end
	return false
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

logger:info('loader.start', 'loader started', {
	channel = release.channel,
	branch = release.branch,
	session = loaderSession
})
if invalidChannel then
	logger:warn('version.channel', 'unknown channel; using main', {requested = requestedChannel})
end

--[[ In the public build shared.PistonwareDeveloper is cleared and locked: a metatable on shared drops
every later write to that key. __newindex alone is the lock; an __index could only ever answer nil
and would cost a call on every read of an unset shared key. ]]
if PUBLIC_BUILD then
	shared.PistonwareDeveloper = nil
	pcall(function()
		if getmetatable(shared) ~= nil then return end
		setmetatable(shared, {
			__newindex = function(self, key, value)
				if key == 'PistonwareDeveloper' then return end
				rawset(self, key, value)
			end
		})
	end)
end

local isDeveloper = (not PUBLIC_BUILD) and shared.PistonwareDeveloper and true or false

--[[ Developer-only boot timing. The console shows ONE line -- 'Injecting into ROBLOX...' -- from
the moment the key validates until main.lua starts, and the status chip reads INJECTING right
through main.lua on top of that. So every wait in between (Roblox loading, the GitHub tree,
the GUI build, the payload) looks identical from outside: 'stuck on injecting'. These marks
put a number on each one instead, in the executor output, for the build that is allowed to
care. Off entirely in the public build -- isDeveloper is false there by construction. ]]
local phaseClock = os.clock()
local function phase(name)
	local now = os.clock()
	local elapsed = now - phaseClock
	logger:info('boot.phase', name..' completed', {seconds = ('%.2f'):format(elapsed)})
	if isDeveloper then pistonwareBuffer.print('boot.phase', name..' completed', {seconds = ('%.2f'):format(elapsed)}) end
	phaseClock = now
	flushLogs()
end

--[[ A boot parked on the key prompt is the one exception to the duplicate guard. That prompt
has no timeout on purpose -- the user is off finishing ad checkpoints -- so the flag below can
legitimately stand for minutes, and every manual re-execution in that window was swallowed here
with no window and no output. From outside that is indistinguishable from the loader refusing
to open, which is the worst possible thing to happen to someone whose key just lapsed.

A second run is allowed to take that one over instead: createConsole tears the old window down,
the old AskKey sees `closed` and returns nil, and the boot behind it unwinds without touching
the new one's flags (releaseBoot only clears what it still owns). ]]
if shared.PistonwareLoaderBoot and not shared.PistonwareKeyPrompt and os.clock() - shared.PistonwareLoaderBoot < 180 then
	logger:warn('loader.duplicate', 'loader is already running; ignoring duplicate execution')
	return
end
shared.PistonwareLoaderBoot = os.clock()
--[[ Identifies THIS boot in the session-wide shared table, so a run that has been taken over can
tell that the flags it is about to clear now belong to somebody else. ]]
local bootStamp = shared.PistonwareLoaderBoot

local isfile = isfile or function(file)
	local suc, res = pcall(function()
		return readfile(file)
	end)
	return suc and res ~= nil and res ~= ''
end
local cloneref = cloneref or function(ref)
	return ref
end
local delfile = delfile or function(file)
	writefile(file, '')
end

local setclipboard = setclipboard or toclipboard or (Clipboard and Clipboard.set)

-- The bedwarslua script's id in the Pistonware project (not the project id: check_key wants a script).
local SCRIPT_ID   = 'bcf715c699489c7457e00e5323c2399b'
--[[ The ad links a key can come from, one per provider. Both end at LuaArmor either way -- it
is what issues the key; the provider only decides whose checkpoints you sit through getting
there -- so adding another is a URL here and an entry in the links list at the gate, nothing
else. ]]
local LOOTLABS_URL = 'https://ads.luarmor.net/get_key?for=Pistonware_LootLabs-xnpnovpEljPO'
local WORKINK_URL = 'https://ads.luarmor.net/get_key?for=Pistonware_Workink-cjPVCqOPPBCJ'
local KEY_FILE    = 'pistonwarekey.json'
local RELEASE_FILE = 'pistonware_release.json'
local HELP_URL    = 'https://discord.gg/pistonware'
--[[ ======================================================================== ]]

local function sourceRef(ref)
	return ref or release.sourceRef or release.branch
end

local function projectRawUrl(path, ref)
	path = tostring(path or ''):gsub('^/', '')
	return 'https://raw.githubusercontent.com/themagicpiston/pistonware/'..sourceRef(ref)..'/'..path
end

local function protectedRawUrl(ref)
	return 'https://gitlab.com/pistonware/pistonware/-/raw/'..(ref or release.branch)..'/bedwars.lua'
end

local function rewriteProjectUrl(url)
	local value = tostring(url or '')
	local ref = sourceRef()
	value = value:gsub('https://raw%.githubusercontent%.com/themagicpiston/pistonware/refs/heads/main/', function() return projectRawUrl('', ref) end)
	value = value:gsub('https://raw%.githubusercontent%.com/themagicpiston/pistonware/main/', function() return projectRawUrl('', ref) end)
	value = value:gsub('https://raw%.githubusercontent%.com/themagicpiston/pistonware/main/', function() return projectRawUrl('', ref) end)
	value = value:gsub('https://gitlab%.com/pistonware/pistonware/%-/raw/main/', function() return protectedRawUrl(release.branch):gsub('/bedwars%.lua$', '/') end)
	value = value:gsub('(/git/trees/)main', '%1'..release.branch)
	value = value:gsub('([?&]sha=)main', '%1'..ref)
	value = value:gsub('([?&]ref=)main', '%1'..ref)
	return value
end

--[[ game:HttpGet as before wherever the executor has it: what it returns or raises comes back
unchanged. The executor's request function stands in only where HttpGet is missing or refused to
the calling thread, and there only a 2xx answer with a body counts, so an error page never comes
back as the file (Real's request hands back an error string rather than a table). The same rule as
httpGet in games/6872274481.lua and pistonwareHttpGet in universal.lua: in the public build every
file's download comes through here (the adapters below), which used to skip those fallbacks. ]]
local function httpGet(url, nocache)
	local ok, body = pcall(function()
		return game:HttpGet(url, nocache)
	end)
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
	local send = telemetry.requestFn
	if not (refused and send) then error(body, 0) end
	local response = send({Url = url, Method = 'GET'})
	local status = type(response) == 'table' and tonumber(response.StatusCode) or nil
	if type(response) ~= 'table' or response.Success == false or (status and (status < 200 or status > 299))
		or type(response.Body) ~= 'string' or response.Body == '' then
		error('GET '..tostring(url)..' failed'..(status and ' (HTTP '..status..')' or ''), 0)
	end
	return response.Body
end

shared.PistonwareRawUrl = projectRawUrl
shared.PistonwareProtectedRawUrl = protectedRawUrl
shared.PistonwareRewriteUrl = rewriteProjectUrl
shared.PistonwareRelease = release
shared.PistonwareTelemetry = telemetry
shared.PistonwareChannel = release.channel
if not isDeveloper then
	shared.PistonwareDevHttpGet = function(url, nocache)
		return httpGet(rewriteProjectUrl(url), nocache)
	end
	shared.PistonwareDevProtectedHttpGet = function(url, nocache)
		return httpGet(rewriteProjectUrl(url), nocache)
	end
end

local strings = {
	enter_key       = 'Enter your key below to continue.',
	saved_expired   = 'Your key expired - renew it with Get Key, then paste it below. It is still saved.',
	saved_hwid      = 'Your key is linked to another device - reset your HWID, then submit it below. The key itself is still good and is still saved.',
	saved_incorrect = 'Saved key no longer exists - get a new one.',
	saved_banned    = 'Saved key is blacklisted.',
	placeholder     = 'Paste your key here',
	work_ink        = 'Work.ink (Recommended)',
	loot_labs       = 'LootLabs',
	paste           = 'Paste',
	submit          = 'Submit',
	footer          = 'No key? Pick a link -> finish the checkpoints -> paste the key above.',
	empty_key       = 'Enter your key first.',
	bad_format      = "That doesn't look like a valid key.",
	checking        = 'Checking key...',
	valid_loading   = 'Key valid%s - loading...',
	hwid_locked     = 'That key is linked to another device - reset your HWID via the bot, then submit it again.',
	expired         = 'That key has expired - renew it, then submit it again.',
	time_left       = '%s left',
	lifetime        = 'lifetime',
	license_expires = 'Your license expires in %s',
	license_lifetime = 'Your license never expires',
	banned          = 'Key is blacklisted.',
	incorrect       = 'Key is incorrect or has been deleted.',
	invalid_format  = 'Invalid key format.',
	check_failed    = 'Check failed: %s (%s)',
	link_copied     = '%s link copied! Finish the checkpoints, then paste your key here.',
	link_missing    = '%s is not set up yet - use LootLabs for now.',
	tip_work_ink    = 'Copies the Work.ink link. Open it in a browser to earn a key.',
	tip_loot_labs   = 'Copies the LootLabs link. Open it in a browser to earn a key.',
	tip_paste       = 'Puts whatever is on your clipboard into the box.',
	tip_submit      = 'Checks the key in the box and starts loading.',
	tip_help        = 'Copies the Discord invite in case you get stuck.',
	pasted          = 'Pasted from clipboard.',
	clipboard_empty = 'Clipboard is empty.',
	need_help       = 'Need Help?',
	help_copied     = 'Help link copied to your clipboard!',
	copy_failed     = 'Failed to copy script.',
	no_library      = "Can't reach LuaArmor (%s). Press Submit to try again.",
	check_error     = 'Key check failed: %s',
	cancelled       = 'Key entry cancelled.',
	headless        = 'No valid key saved - run the loader manually to enter one.'
}

local function t(key, ...)
	local s = strings[key] or key
	if select('#', ...) > 0 then
		return string.format(s, ...)
	end
	return s
end

--[[ Coarse on purpose: '3 days' is what someone needs to know, and '3 days 4 hours 12 minutes'
is noise in a one-line status. Rounds down, so it never promises time that is not there. ]]
local function formatDuration(seconds)
	if seconds <= 0 then return nil end
	local days = math.floor(seconds / 86400)
	if days >= 1 then return days..(days == 1 and ' day' or ' days') end
	local hours = math.floor(seconds / 3600)
	if hours >= 1 then return hours..(hours == 1 and ' hour' or ' hours') end
	local minutes = math.max(1, math.floor(seconds / 60))
	return minutes..(minutes == 1 and ' minute' or ' minutes')
end

--[[ The parenthesised detail after 'Key valid', built from the fields LuaArmor only returns on
KEY_VALID: the seller note, and auth_expire (a unix timestamp, with -1 or 0 meaning a
lifetime key). Showing what is left matters because the complaint this addresses is people
believing a key had died when it had days on it -- if the remaining time is on screen every
run, that confusion has nowhere to start. ]]
local function keyDetail(status)
	local data = type(status) == 'table' and type(status.data) == 'table' and status.data or nil
	if not data then return '' end

	local parts = {}
	if data.note ~= nil and tostring(data.note) ~= '' then
		table.insert(parts, tostring(data.note))
	end

	local expire = tonumber(data.auth_expire)
	if expire == -1 or expire == 0 then
		table.insert(parts, t('lifetime'))
	elseif expire then
		local left = formatDuration(expire - os.time())
		if left then table.insert(parts, t('time_left', left)) end
	end

	if #parts == 0 then return '' end
	return ' ('..table.concat(parts, ', ')..')'
end

--[[ Hands the GUI the key's expiry so its footer can count it down: -1 for a lifetime key,
otherwise the unix time it runs out. Left unset when LuaArmor did not say. ]]
local function rememberExpiry(status)
	local data = type(status) == 'table' and type(status.data) == 'table' and status.data or nil
	local expire = data and tonumber(data.auth_expire)
	if expire == -1 or expire == 0 then
		shared.PistonwareKeyExpire = -1
	elseif expire then
		shared.PistonwareKeyExpire = expire
	end
end

local function trim(s)
	return (tostring(s):gsub('^%s*(.-)%s*$', '%1'))
end

--[[ Empty counts as missing. The executor's real isfile reports a zero-byte file as present, so a
write interrupted by a cancel, a crash or a teleport leaves a truncated file that this
function would otherwise never fetch again. For a .lua file that means a chunk that silently
does nothing; for an asset it means getcustomasset producing an invalid content id, which
throws 'ContentId formatting failed' and kills the GUI. Both states used to survive every
retry, because everything that could have repaired them asked isfile and was told the file
was fine -- so the only remedy was reinstalling the script.

Returns the body it read, and for a .lua file the chunk it compiled to prove it intact. Given the
name the file will run under, it compiles under that name, so the caller can run this chunk
instead of compiling the same source a second time with identical error traces. ]]
local function hasContent(path, chunkName)
	if not isfile(path) then return false end
	local ok, body = pcall(readfile, path)
	if not ok or type(body) ~= 'string' or body == '' then return false end
	if path:match('%.lua$') then
		local compileOk, chunk = pcall(loadstring, body, chunkName or path)
		if not (compileOk and type(chunk) == 'function') then return false end
		return body, chunk
	end
	return body
end

--[[ A write only counts once it reads back the same. Solara does its file I/O through another
process (Xeno likely too), where a write can return without the bytes arriving. A file whose write
did not land is treated as missing, never as current, and the release marker stays where it was,
so the next boot fetches it again instead of running the old copy from then on. ]]
local cacheWriteFailed = false
local function writeChecked(path, content)
	local wrote, err = pcall(writefile, path, content)
	if wrote then
		local readOk, back = pcall(readfile, path)
		if not (readOk and back == content) then
			wrote = false
			err = ('%s read back %s'):format(path,
				readOk and type(back) == 'string' and (#back..' of '..#content..' bytes') or 'nothing')
		end
	end
	if not wrote then
		cacheWriteFailed = true
	end
	return wrote, err
end

--[[ What a non-.lua download must never be cached as: an error page some executors hand back as
the body ('429: Too Many Requests', a 5xx page) and, for a config, anything that is not JSON. A
profile or GUI settings file saved as an error page failed to load on every boot after, with saving
blocked, until the folder was deleted. ]]
local function unusableBody(path, body)
	if type(body) ~= 'string' or body == '' or body == '404: Not Found' then return true end
	local head = body:sub(1, 200):lower()
	if body:match('^%d%d%d: ') or head:find('<!doctype html', 1, true) or head:find('<html', 1, true) then
		return true
	end
	if path:match('%.json$') or path:match('profiles/.+%.txt$') then
		local ok, decoded = pcall(function()
			return cloneref(game:GetService('HttpService')):JSONDecode(body)
		end)
		return not (ok and type(decoded) == 'table')
	end
	return false
end

--[[ Paths the update pass rewrote at the release commit during this boot. The release marker
only moves once the whole boot has succeeded, so until then release.cacheReady stays false and
downloadFile used to fetch every one of these again straight after they were written. Only a
refresh whose write landed is listed, so a failed write still downloads as before. ]]
local refreshedThisBoot = {}

--[[ Set by a repair boot (cache.repair below) whose cache was already current for this release. A
file it cannot fetch again then runs from disk when the copy there is intact, as it would have
without the repair. ]]
local repairFallback = false
--[[ Set once that repair has found GitHub's raw files out of reach. Every file after that is tried
once before its copy on disk runs, not four times with waits between, which held the boot on
'Loading' for most of a minute. main.lua reads both as release.repairFallback/repairOffline. ]]
local repairOffline = false

--[[ Returns a file's text from the cache, or downloads it with up to 4 tries (waits of 1, 2 and 3 s) and
caches it. A Lua file must compile and any other file must not be an error page; a cached config or
asset that is an error page is fetched again. With chunkName the compiled chunk is returned as well,
so the chunk that passed the compile check is the one the caller runs. With func it returns
func(path), which reads the file back off disk.

Once a repair has found GitHub's raw files out of reach (repairOffline), a file with a usable copy
on disk stops after one failed try and runs that copy, since the release marker already vouched for
it at this release; a file with nothing to fall back to keeps every try. A failed cache write still
returns the downloaded text, except to a func caller, which needs the file on disk. ]]
local function downloadFile(path, func, chunkName)
	local body, chunk
	if release.cacheReady or refreshedThisBoot[path] then
		body, chunk = hasContent(path, chunkName)
		if body and not path:find('%.lua$') and unusableBody(path, body) then
			body, chunk = nil, nil
		end
	end
	if not body then
		local relPath = select(1, path:gsub('pistonware/', ''))
		local isBedwars = relPath == 'games/bedwars.lua'
		local isLua = path:find('%.lua$') ~= nil
		local content
		local onDisk, onDiskChunk
		local function readOnDisk()
			onDisk, onDiskChunk = hasContent(path, chunkName)
			if onDisk and not isLua and unusableBody(path, onDisk) then
				onDisk, onDiskChunk = false, nil
			end
		end
		local attempts = 0
		for attempt = 1, 4 do
			attempts = attempt
			local suc, res = pcall(function()
				if isBedwars then
					return httpGet(protectedRawUrl(), true)
				end
				return httpGet(projectRawUrl(relPath), true)
			end)
			if suc and res and res ~= '' and res ~= '404: Not Found' then
				if not isLua then
					if not unusableBody(path, res) then
						content = res
					end
				elseif chunkName then
					chunk = loadstring(res, chunkName)
					if chunk then content = res end
				elseif loadstring(res) ~= nil then
					content = res
				end
				if content then break end
			end
			if repairOffline then
				if onDisk == nil then
					readOnDisk()
				end
				if onDisk then break end
			end
			if attempt < 4 then
				task.wait(attempt)
			end
		end
		if not content and repairFallback then
			repairOffline = true
			release.repairOffline = true
			if onDisk == nil then
				readOnDisk()
			end
			if onDisk then
				logger:warn('cache.repair', 'could not fetch '..path..' again; the intact copy on disk runs')
				if func then return func(path) end
				if chunkName then return onDisk, onDiskChunk end
				return onDisk
			end
		end
		if not content then
			local message = 'failed to download '..path..' after '..attempts..(attempts == 1 and ' attempt' or ' attempts')
			reportError('source.download', message, nil, false)
			error(message, 2)
		end
		local wrote, writeError = writeChecked(path, content)
		if not wrote then
			reportError('source.cache.write', writeError, nil, false)
			if func then
				error(writeError, 2)
			end
		end
		body = content
	end
	if func then return func(path) end
	if chunkName then return body, chunk end
	return body
end

if not isDeveloper then
	shared.PistonwareDevLoadSource = function(path, chunkName)
		return downloadFile(path, nil, chunkName)
	end
end

--[[ Every concurrent batch in this file joins through here.

The old code used `done.Event:Wait()` with no timeout, which parks the boot FOREVER if
a worker dies before firing -- and workers could die, because the progress callback they
called on their way out was not wrapped. That is the 'stuck on Injecting into ROBLOX' report:
not a slow download, a batch that lost a worker and a join that waits for it regardless.

Fixed at both ends, because either alone still leaves a hole: the callbacks are pcall'd at
their call sites now, AND this gives up on the clock no matter what killed the worker. A
batch that loses one costs the files that worker had left, not the session. ]]
local function joinBatch(isDone, seconds)
	local deadline = os.clock() + (seconds or 90)
	while not isDone() and os.clock() < deadline do
		task.wait(0.05)
	end
	return isDone()
end

--[[
	Resolve the branch through the small GitHub branch endpoint first. The recursive tree is an
	optional cache/update index, not the release-verification gate: GitHub can serve valid branch
	metadata while a recursive tree request is rate-limited or temporarily unavailable.

	The loader used to treat that tree failure as proof that the branch had no release. That made
	"branch main has no verified release" a false negative and prevented an otherwise valid boot.
	Once the branch endpoint returns a 40-character commit, every later raw-file request is pinned
	to that commit. A matching local marker remains the offline fallback when both metadata calls
	are unavailable.
]]
--[[ GitHub requests for the release lookup, made so a failure says WHY and never throws.

Both 'Loader stopped' reports came out of this lookup:

  "Can't parse JSON"  game:HttpGet sends no User-Agent on some executors, and api.github.com
                      answers a request without one with a plain-text 403 ("Request
                      forbidden by administrative rules...") -- JSONDecode on that throws.
  "branch metadata did not contain a verified commit"
                      the REST API allows 60 unauthenticated requests an hour per IP. Past
                      that it answers with a JSON error object and no commit. A shared IP, a
                      VPN or a handful of reinjects in an hour is enough.

So the executor's request function goes first, with a User-Agent, and the status code is read
rather than guessed from the body. HttpGet stays as the fallback for executors without one. ]]
local GITHUB_HEADERS = {['User-Agent'] = 'pistonware-loader', Accept = 'application/vnd.github+json'}

--[[ Turns a GitHub error response into one line for the log and reports. IP addresses in the rate-limit
message are replaced with <ip>. ]]
local function describeGithubFailure(status, body)
	local detail
	pcall(function()
		local decoded = cloneref(game:GetService('HttpService')):JSONDecode(body)
		if type(decoded) == 'table' and type(decoded.message) == 'string' then
			detail = decoded.message
		end
	end)
	if detail then
		detail = (detail:gsub('%d+%.%d+%.%d+%.%d+', '<ip>'))
		detail = (detail:gsub('%x*:%x*:[%x:]+', '<ip>'))
	end
	return (status and ('GitHub answered '..status) or 'GitHub refused the request')
		..(detail and (': '..safeText(detail, 200)) or '')
end

--[[ GETs a GitHub URL with GITHUB_HEADERS through the executor's request function, which reports the
status code, and falls back to HttpGet. A failure with no status code (or 0) never reached GitHub,
so HttpGet still gets its try. Returns the body, or nil and a reason. ]]
local function githubGet(url)
	local requestFn = telemetry.requestFn
	if requestFn then
		local ok, res = pcall(requestFn, {Url = url, Method = 'GET', Headers = GITHUB_HEADERS})
		if ok and type(res) == 'table' and type(res.Body) == 'string' then
			local status = tonumber(res.StatusCode) or (res.Success == false and 0 or 200)
			if status >= 200 and status < 300 then
				if res.Body ~= '' then return res.Body end
				return nil, 'GitHub sent an empty response'
			end
			if status ~= 0 then
				return nil, describeGithubFailure(status, res.Body)
			end
		end
	end
	local ok, body = pcall(function()
		return httpGet(url, true)
	end)
	if ok and type(body) == 'string' and body ~= '' then return body end
	return nil, ok and 'GitHub sent an empty response' or safeText(body, 200)
end

--[[ Fetches and decodes a GitHub API response. An object with a message and no sha or commit is an error
that came through HttpGet, which hides the status code. ]]
local function githubJson(url)
	local body, err = githubGet(url)
	if not body then return nil, err end
	local ok, decoded = pcall(function()
		return cloneref(game:GetService('HttpService')):JSONDecode(body)
	end)
	if not (ok and type(decoded) == 'table') then
		return nil, 'GitHub sent a response that is not JSON'
	end
	if type(decoded.message) == 'string' and decoded.sha == nil and decoded.commit == nil then
		return nil, describeGithubFailure(nil, body)
	end
	return decoded
end

local repoTree, repoTreeTried, repoTreeDone
local repoTreeError
--[[ Fetches the repository's recursive tree at the release ref once per boot and keeps it. It also goes
to shared.PistonwareRepoTree, so main.lua's asset prefetch reads the paths from it instead of
spending its own API calls. repoTreeTried is set on entry, so a caller that arrives while the first
request is in flight waits for it through joinBatch (up to 30 s) instead of reading nil as no tree.
]]
local function fetchRepoTree()
	if repoTreeTried then
		if not repoTreeDone then
			joinBatch(function() return repoTreeDone end, 30)
		end
		return repoTree
	end
	repoTreeTried = true
	local ok, err = pcall(function()
		local body, treeErr = githubJson('https://api.github.com/repos/themagicpiston/pistonware/git/trees/'..(release.sourceRef or release.branch)..'?recursive=1')
		if type(body) == 'table' and type(body.tree) == 'table' and type(body.sha) == 'string' then
			repoTree = body
			shared.PistonwareRepoTree = body
		else
			error(treeErr or 'the repository tree was missing its file list', 0)
		end
	end)
	if not ok then
		repoTreeError = safeText(err)
		logger:warn('version.tree', 'could not resolve the selected branch tree', {error = repoTreeError, branch = release.branch})
		telemetry:report('loader_error', repoTreeError, {stage = 'version.tree', fatal = false})
	end
	repoTreeDone = true
	return repoTree
end

local function readReleaseMarker()
	if not isfile(RELEASE_FILE) then return nil end
	local ok, body = pcall(readfile, RELEASE_FILE)
	if not ok or type(body) ~= 'string' or body == '' then return nil end
	local decodedOk, decoded = pcall(function()
		return cloneref(game:GetService('HttpService')):JSONDecode(body)
	end)
	return decodedOk and type(decoded) == 'table' and decoded or nil
end

local function validCommit(value)
	return type(value) == 'string' and #value == 40 and value:match('^%x+$') ~= nil
end

--[[ The branch head without the REST API, so without its hourly limit. Git's own smart-HTTP
ref advertisement -- what `git clone` reads first -- lists every branch as a pkt-line,
'<4 hex length><40 hex sha> refs/heads/<name>'. The first line also carries HEAD and the
capability list after a NUL, which the ref match below never reaches for a branch. ]]
local function commitFromGitRefs()
	local body, err = githubGet('https://github.com/themagicpiston/pistonware.git/info/refs?service=git-upload-pack')
	if not body then return nil, err end
	local wanted = 'refs/heads/'..release.branch
	for line in body:gmatch('[^\n]+') do
		local hex, ref = line:match('^(%x+) (%S+)')
		if ref then
			local nul = ref:find('\0', 1, true)
			if nul then ref = ref:sub(1, nul - 1) end
		end
		if ref == wanted and #hex >= 40 then
			local sha = hex:sub(-40)
			if validCommit(sha) then return sha end
		end
	end
	return nil, 'the git refs did not list branch '..release.branch
end

-- Second non-API source: the branch's commit feed, newest commit first.
local function commitFromFeed()
	local body, err = githubGet('https://github.com/themagicpiston/pistonware/commits/'..release.branch..'.atom')
	if not body then return nil, err end
	local sha = body:match('Grit::Commit/(%x+)')
	if validCommit(sha) then return sha end
	return nil, 'the commit feed did not list a commit'
end

local branchCommit, branchCommitTried, branchCommitDone
local branchCommitError
--[[ Finds the latest commit of the release branch once per boot: the branches API first, then git refs,
then the commit feed. The reason each source failed is kept, so a report names all of them. A second
caller waits for the first request through joinBatch, as in fetchRepoTree. ]]
local function fetchBranchCommit()
	if branchCommitTried then
		if not branchCommitDone then
			joinBatch(function() return branchCommitDone end, 30)
		end
		return branchCommit
	end
	branchCommitTried = true
	local reasons = {}
	local ok, err = pcall(function()
		local body, apiErr = githubJson('https://api.github.com/repos/themagicpiston/pistonware/branches/'..release.branch)
		local commit = type(body) == 'table' and type(body.commit) == 'table' and body.commit.sha
		if validCommit(commit) then
			branchCommit = commit
			return
		end
		table.insert(reasons, 'API: '..(apiErr or 'no commit in the branch metadata'))
		for _, source in {{'git refs', commitFromGitRefs}, {'commit feed', commitFromFeed}} do
			local sha, sourceErr = source[2]()
			if validCommit(sha) then
				branchCommit = sha
				return
			end
			table.insert(reasons, source[1]..': '..tostring(sourceErr))
		end
	end)
	if not ok then
		table.insert(reasons, safeText(err, 200))
	end
	if branchCommit then
		if #reasons > 0 then
			logger:info('version.branch', 'resolved the branch without the GitHub API', {reasons = table.concat(reasons, '; '), branch = release.branch})
		end
	else
		branchCommitError = 'could not find the latest commit of branch '..release.branch..' ('..table.concat(reasons, '; ')..')'
		logger:warn('version.branch', 'could not resolve the selected branch', {error = branchCommitError, branch = release.branch})
		telemetry:report('loader_error', branchCommitError, {stage = 'version.branch', fatal = false})
	end
	branchCommitDone = true
	return branchCommit
end

local function markerMatches(marker)
	return type(marker) == 'table'
		and marker.schema == VERSION_SCHEMA
		and marker.channel == release.channel
		and marker.branch == release.branch
		and validCommit(marker.commit)
end

--[[ Picks the commit every file of this boot is fetched at: the branch's latest commit, else the tree's
sha (for hosts or API proxies that expose git/trees but not /branches), else the last verified
release in the marker. The cache counts as ready only when the marker names that same commit.

With none of these and no marker (a first run behind a network that blocks github.com as well as the
API) the branch loads as it stands: nothing is cached as ready and no marker is written, so the next
run that resolves a commit pins it. The pin buys consistency, every file from one snapshot, not
authenticity. ]]
local function resolveRelease()
	local marker = readReleaseMarker()
	local commit = fetchBranchCommit()
	if validCommit(commit) then
		release.commit = commit
		release.sourceRef = commit
		release.version = release.channel..'@'..commit:sub(1, 12)
		release.resolved = true
		release.cacheReady = markerMatches(marker) and marker.commit == commit
			or false
		shared.PistonwareRelease = release
		logger:info('version.resolved', 'release selected', {
			channel = release.channel,
			branch = release.branch,
			version = release.version,
			cache = release.cacheReady and 'ready' or 'refresh'
		})
		return true
	end
	local tree = fetchRepoTree()
	if tree and validCommit(tree.sha) then
		release.commit = tree.sha
		release.sourceRef = tree.sha
		release.version = release.channel..'@'..tree.sha:sub(1, 12)
		release.resolved = true
		release.cacheReady = markerMatches(marker) and marker.commit == tree.sha or false
		shared.PistonwareRelease = release
		logger:info('version.resolved', 'release selected from the repository tree', {
			channel = release.channel,
			branch = release.branch,
			version = release.version,
			cache = release.cacheReady and 'ready' or 'refresh'
		})
		return true
	end
	if markerMatches(marker) then
		release.commit = marker.commit
		release.sourceRef = marker.commit
		release.version = release.channel..'@'..marker.commit:sub(1, 12)
		release.resolved = true
		release.cacheReady = true
		release.fromMarker = true
		shared.PistonwareRelease = release
		logger:warn('version.cached', 'using the last verified release because the branch tree was unavailable', {
			channel = release.channel,
			version = release.version
		})
		return true
	end
	release.commit = nil
	release.sourceRef = release.branch
	release.version = release.channel..'@'..release.branch
	release.resolved = true
	release.cacheReady = false
	shared.PistonwareRelease = release
	local reason = branchCommitError or repoTreeError or ('branch '..release.branch..' has no verified release')
	logger:warn('version.unpinned', 'loading the branch head because no commit could be resolved', {
		channel = release.channel,
		branch = release.branch,
		reason = reason
	})
	telemetry:report('loader_error', reason, {stage = 'version.unpinned', fatal = false})
	return true
end

local function persistReleaseMarker()
	if not release.resolved or type(release.commit) ~= 'string' then return false end
	local marker = {
		schema = VERSION_SCHEMA,
		channel = release.channel,
		branch = release.branch,
		commit = release.commit,
		version = release.version,
		savedAt = os.time()
	}
	local ok, err = pcall(function()
		writefile(RELEASE_FILE, jsonEncode(marker))
	end)
	if not ok then
		logger:warn('version.marker', 'could not persist the verified release marker', {error = err})
		telemetry:report('loader_error', err, {stage = 'version.marker', fatal = false})
		return false
	end
	release.cacheReady = true
	shared.PistonwareRelease = release
	return true
end

--[[ Lists the files under profiles/ from the repository tree, shaped like a contents API response ({type
= 'file', path = ...}) for the downloader. A tree is a snapshot, so the listing and the file
contents cannot disagree. profiles/gui.txt and profiles/whitelist.json are left out; nothing reads
them. ]]
local function fetchProfilesListing()
	local tree = fetchRepoTree()
	if not tree then return nil end
	local files = {}
	for _, v in tree.tree do
		if v.type == 'blob' and v.path:sub(1, 9) == 'profiles/' and v.path ~= 'profiles/gui.txt' and v.path ~= 'profiles/whitelist.json' then
			table.insert(files, {type = 'file', path = v.path})
		end
	end
	if #files == 0 then return nil end
	return files
end

--[[ Merges a synced settings file into the one on disk, so a config sync replaces the theme and window
layout but keeps the profiles the user made. In profiles/settings.json the profile in use and the
profile list stay the user's (keepOwnProfiles in guilibrary.lua does the same for its Sync button).
In an older build's <GameId>.gui.txt the top-level Profiles and Profile stay, and so do
Categories.Profiles.List and ListEnabled, where guilibrary.lua kept the profile list. On any decode
failure the incoming text is returned unchanged. ]]
local function mergeGuiState(path, incoming)
	if path:find('profiles/settings%.json$') then
		local ok, merged = pcall(function()
			local httpService = cloneref(game:GetService('HttpService'))
			local new = httpService:JSONDecode(incoming)
			local old = isfile(path) and httpService:JSONDecode(readfile(path))
			if type(new) ~= 'table' or type(old) ~= 'table' then return incoming end
			if old.profile ~= nil then new.profile = old.profile end
			if old.profiles ~= nil then new.profiles = old.profiles end
			return httpService:JSONEncode(new)
		end)
		return (ok and type(merged) == 'string') and merged or incoming
	end
	if not path:find('%.gui%.txt$') then return incoming end
	local ok, merged = pcall(function()
		local httpService = cloneref(game:GetService('HttpService'))
		local new = httpService:JSONDecode(incoming)
		if type(new) ~= 'table' then return incoming end
		if isfile(path) then
			local old = httpService:JSONDecode(readfile(path))
			if type(old) == 'table' then
				if old.Profiles ~= nil then new.Profiles = old.Profiles end
				if old.Profile ~= nil then new.Profile = old.Profile end

				local oldprofiles = type(old.Categories) == 'table' and old.Categories.Profiles or nil
				if type(oldprofiles) == 'table' then
					new.Categories = type(new.Categories) == 'table' and new.Categories or {}
					local newprofiles = type(new.Categories.Profiles) == 'table' and new.Categories.Profiles or {}
					new.Categories.Profiles = newprofiles
					if oldprofiles.List ~= nil then newprofiles.List = oldprofiles.List end
					if oldprofiles.ListEnabled ~= nil then newprofiles.ListEnabled = oldprofiles.ListEnabled end
				end
			end
		end
		return httpService:JSONEncode(new)
	end)
	return (ok and type(merged) == 'string') and merged or incoming
end

--[[ The menu library makes settings.json out of an older build's menu file (<GameId>.gui.txt) when it
starts, and only while there is no settings.json. A synced one written before that, on the first boot
after an update, would take the place of the user's profile list and menu settings, so it is left
for the next sync, which merges it into the converted one (mergeGuiState). ]]
local function holdsBackSettings(path)
	if not path:find('profiles/settings%.json$') or isfile(path) then return false end
	for _, gameId in {'2619619496', tostring(game.GameId)} do
		if isfile('pistonware/profiles/'..gameId..'.gui.txt') then return true end
	end
	return false
end

--[[ Names synced profiles in profiles/profilesync.txt. A shipped profile in an older build's format
(<name><placeId>.txt) is converted by the menu library at start, which skips one whose <name>.json
exists; a name listed here is converted over it, so a sync replaces that profile. A shipped
<name>.json needs no entry. A profile is named once every place file of it that the release ships
has landed and is in profiles/; with one of a pair missing the user's file stays. Called as each
file lands, so a sync cut short still names what it completed. ]]
local function noteSyncedProfiles(written, listing)
	local function stemOf(path)
		local file = path:match('^profiles/([^/]+)$')
		return file and (file:match('^(.+)6872274481%.txt$') or file:match('^(.+)6872265039%.txt$'))
	end
	local shipped, names, added = {}, {}, false
	local wanted, landed = {}, {}
	for _, v in listing do
		local path = ({v.path:gsub(' ', '%%20')})[1]
		shipped[path] = true
		local stem = stemOf(path)
		if stem then wanted[stem] = (wanted[stem] or 0) + 1 end
	end
	pcall(function()
		for name in readfile('pistonware/profiles/profilesync.txt'):gmatch('[^\n]+') do
			names[name] = true
		end
	end)
	for _, path in written do
		local stem = stemOf(path)
		if stem then landed[stem] = (landed[stem] or 0) + 1 end
	end
	local function allThere(stem)
		for path in shipped do
			if stemOf(path) == stem then
				local ok, there = pcall(isfile, 'pistonware/'..path)
				if not (ok and there) then return false end
			end
		end
		return true
	end
	for stem, count in landed do
		if count == wanted[stem] and not shipped['profiles/'..stem..'.json'] and not names[stem] and allThere(stem) then
			names[stem] = true
			added = true
		end
	end
	if not added then return end
	local list = {}
	for name in names do
		table.insert(list, name)
	end
	table.sort(list)
	pcall(writefile, 'pistonware/profiles/profilesync.txt', table.concat(list, '\n')..'\n')
end

--[[ Downloads the listed profile files in parallel. Returns true when every file landed or was held back
(holdsBackSettings).

A held-back file is neither written nor a failure: the user keeps the settings the menu library
makes from the old menu file, and the next sync merges the shipped one into them. A first download
also keeps an old profiles/<id>.gui.txt that is there. A sync, and a first download where
settings.json exists, merge through mergeGuiState and never overwrite. Each landed file is noted at
once (noteSyncedProfiles), so a teleport or a stopped script leaves none unnoted, and each worker is
counted before its guarded progress report, so a throwing callback cannot strand the join. ]]
local function downloadProfilesListing(body, commit, onProgress)
	local files = {}
	for _, v in body do
		if v.type == 'file' then
			table.insert(files, v)
		end
	end
	local completed, failed, total = 0, 0, #files
	local written = {}
	for _, v in files do
		local relPath = ({v.path:gsub(' ', '%%20')})[1]
		task.spawn(function()
			local succeeded, heldBack = false, false
			if holdsBackSettings('pistonware/'..relPath) then
				heldBack = true
			elseif not commit and relPath:match('^profiles/%d+%.gui%.txt$') and hasContent('pistonware/'..relPath) then
				heldBack = true
			elseif commit or (relPath == 'profiles/settings.json' and isfile('pistonware/'..relPath)) then
				pcall(function()
					for attempt = 1, 4 do
						local suc, res = pcall(function()
							return httpGet(projectRawUrl(relPath, commit or release.sourceRef), true)
						end)
						if suc and not unusableBody('pistonware/'..relPath, res) then
							local wrote = writeChecked('pistonware/'..relPath, mergeGuiState('pistonware/'..relPath, res))
							if wrote then
								succeeded = true
								break
							end
						end
						if attempt < 4 then
							task.wait(attempt)
						end
					end
				end)
			else
				succeeded = pcall(downloadFile, 'pistonware/'..relPath)
			end
			if succeeded then
				table.insert(written, relPath)
				noteSyncedProfiles(written, files)
			elseif not heldBack then
				failed += 1
			end
			completed += 1
			if onProgress then
				pcall(onProgress, completed, total)
			end
		end)
	end
	joinBatch(function() return completed >= total end)
	noteSyncedProfiles(written, files)
	return completed == total and failed == 0
end

--[[ Derived from the tree already in hand, so the sync check costs no request of its own. The
fingerprint changes only when a profile changes and stays identical otherwise; the blob shas
give exactly; djb2 over them keeps the stored value one short line instead of growing with
the profile count. The 'p1-' prefix marks the scheme, so the migration in Step 2b can tell
one of these from the 40-char git sha the old code wrote. ]]
local function profilesFingerprint()
	local tree = fetchRepoTree()
	if not tree then return nil end
	local parts = {}
	for _, v in tree.tree do
		if v.type == 'blob' and v.path:sub(1, 9) == 'profiles/' then
			table.insert(parts, v.path..':'..tostring(v.sha))
		end
	end
	if #parts == 0 then return nil end
	table.sort(parts)
	local joined = table.concat(parts, '\n')
	local h = 5381
	for i = 1, #joined do
		h = (h * 33 + string.byte(joined, i)) % 4294967296
	end
	return ('p1-%08x'):format(h)
end

--[[ Brings the cached .lua files up to the release tree. The one memoised tree request is the whole API
budget, and the profiles listing and fingerprint use the same response. A file whose blob sha
differs from filecheck.json is fetched at the tree's sha, and only files already on disk are
refreshed; the rest download on demand and are picked up the session after. A manifest file missing
from the tree is deleted, unless the tree came back truncated. A download must compile before it
replaces the cached copy, so an error page never overwrites a working file.

Under a release the marker vouches for, a file with no manifest entry gets one try without waits. A
repair that cannot get a file from GitHub at all sets repairOffline, so later files with a copy on
disk try once; a write that did not land says nothing about GitHub and does not count. Returns true
only once the cache was checked against a tree and every refresh landed; nil without a tree and
false after a failed or unjoined download, and the release marker is not advanced on either. A
developer boot never runs it. ]]
local function updateCachedFiles(onProgress)
	local httpService = cloneref(game:GetService('HttpService'))

	local tree = fetchRepoTree()
	if not tree then return end
	local headSha = tree.sha

	local manifest = {}
	pcall(function()
		if isfile('pistonware/filecheck.json') then
			local decoded = httpService:JSONDecode(readfile('pistonware/filecheck.json'))
			if type(decoded) == 'table' then
				manifest = decoded
			end
		end
	end)

	local remote = {}
	for _, v in tree.tree do
		if v.type == 'blob' and v.path:sub(-4) == '.lua' then
			remote[v.path] = v.sha
		end
	end

	local function managed(localPath)
		return isfile(localPath)
	end

	local toUpdate = {}
	for path, sha in remote do
		local localPath = 'pistonware/'..path
		if manifest[path] ~= sha and managed(localPath) then
			table.insert(toUpdate, path)
		end
	end

	local changed = false

	if not tree.truncated then
		for path in manifest do
			if not remote[path] then
				pcall(function()
					local localPath = 'pistonware/'..path
					if managed(localPath) then
						delfile(localPath)
					end
				end)
				manifest[path] = nil
				changed = true
			end
		end
	end

	local completed, failed, total = 0, 0, #toUpdate
	local joined = true
	if total > 0 then
		for _, path in toUpdate do
			task.spawn(function()
				local done = false
				local reached = false
				local attempts = (release.cacheReady == true and manifest[path] == nil) and 1 or 4
				for attempt = 1, attempts do
					local suc, res = pcall(function()
							return httpGet(projectRawUrl(select(1, path:gsub(' ', '%%20')), headSha), true)
					end)
					if suc and res and res ~= '' and res ~= '404: Not Found' and loadstring(res) ~= nil then
						reached = true
						local localPath = 'pistonware/'..path
						local wrote, writeError = writeChecked(localPath, res)
						if wrote then
							refreshedThisBoot[localPath] = true
							manifest[path] = remote[path]
							done = true
							changed = true
							break
						end
						reportError('cache.write', writeError, nil, false)
					end
					if attempt < attempts then
						task.wait(attempt)
					end
				end
				if not done then
					failed += 1
					if repairFallback and not reached then
						repairOffline = true
						release.repairOffline = true
					end
				end
				completed += 1
				if onProgress then
					pcall(onProgress, completed, total)
				end
			end)
		end
		joined = joinBatch(function() return completed >= total end)
	end

	if changed then
		pcall(writefile, 'pistonware/filecheck.json', httpService:JSONEncode(manifest))
	end
	return joined and failed == 0
end

--[[
	Loader console
	--------------
	A fake terminal window that stands in for the executor console while pistonware boots.
	The piston face is drawn one row at a time as the boot progresses, so the art is only
	ever complete at the same moment the status flips to '> DONE'.
]]

local pistonFace = {
	'******=============******++++++=============******',
	'******=============******++++++=============******',
	'******=============******++++++=============******',
	'++++++=============++++++===================++++++',
	'++++++=============++++++===================++++++',
	'++++++=============++++++===================++++++',
	'::::::@@@@@@       ------::::::@@@@@@       ::::::',
	'::::::@@@@@@       ------::::::@@@@@@       ::::::',
	'::::::@@@@@@       ------::::::@@@@@@       ::::::',
	'::::::@@@@@@       ++++++------@@@@@@       ::::::',
	'::::::@@@@@@       ++++++------@@@@@@       ::::::',
	'::::::@@@@@@       ++++++------@@@@@@       ::::::',
	'::::::######:::::::++++++======******:::::::::::::',
	'::::::++++++=======++++++++++++=============::::::',
	'::::::++++++=======++++++++++++=============::::::',
	'::::::++++++=======++++++++++++=============::::::',
	'------++++++                         =======------',
	'------++++++                         =======------',
	'------++++++                         =======------',
	'::::::=============      ++++++++++++=======::::::',
	'::::::=============      ++++++++++++=======::::::',
	'::::::=============      ++++++++++++=======::::::',
	'::::::------:::::::------::::::------:::::::::::::',
	'::::::------:::::::------::::::------:::::::::::::',
	'::::::------:::::::------::::::------:::::::::::::'
}

--[[ Every offset below is authored against the base window and scaled as a whole by the
UIScale, so the layout can't drift apart on other resolutions. ]]
local windowWidth = 1000
local titleBarHeight = 44
local contentPadding = 26
--[[ Rows are packed slightly tighter than the glyph size so the 25-row face stays a sane
height. Text is never clipped by its own frame in Roblox, so the 2px per row overlaps
harmlessly. ]]
local asciiTextSize = 20
local asciiLineHeight = 18

--[[ The rows under the art are positioned off the art itself, so a taller or shorter face
pushes them (and the bottom of the window) down instead of colliding with them. ]]
local asciiTop = titleBarHeight + 16
local statusY = asciiTop + #pistonFace * asciiLineHeight + 16
local lineY = statusY + 32
local answersY = lineY + 30
local baseWindowHeight = answersY + 34 + 30 + 22 + 16
--[[ How long the key has left, under the status once it is known (SetLicense), as Slinky's loader has
it. The row only takes room while it shows: the line and the answers under it move down by it and
the window grows to match. Kept open for the whole boot, it left a blank row over the line through
the key check and the loading, and the window a row taller than it needed. ]]
local licenseY = statusY + 32
local licenseRow = 28

local palette = {
	Window = Color3.fromRGB(10, 10, 10),
	TitleBar = Color3.fromRGB(38, 38, 38),
	Border = Color3.fromRGB(52, 52, 52),
	Title = Color3.fromRGB(232, 232, 232),
	Glyph = Color3.fromRGB(190, 190, 190),
	Accent = Color3.fromRGB(240, 122, 31),
	Line = Color3.fromRGB(237, 237, 237),
	Footer = Color3.fromRGB(110, 110, 110),
	ButtonIdle = Color3.fromRGB(200, 200, 200),
	ButtonBorder = Color3.fromRGB(60, 60, 60),
	Error = Color3.fromRGB(225, 80, 70),
	Ok = Color3.fromRGB(120, 225, 150)
}

--[[ Ascii shading: the art is one colour in a real terminal, but the piston only reads as a
face if the solid blocks sit brighter than the dithered background, so each glyph class
gets its own tone. ]]
local asciiShades = {
	['@'] = '#F2F2F2',
	['#'] = '#E4E4E4',
	['%'] = '#D2D2D2',
	['*'] = '#A6A6A6',
	['+'] = '#8C8C8C',
	['='] = '#6B6B6B',
	['-'] = '#5C5C5C',
	[':'] = '#4A4A4A',
	['.'] = '#4A4A4A'
}

--[[ Cancelling the loader has to leave nothing behind that THIS boot created, so on a fresh
install the whole folder is wiped. On an install that already existed before this run the
wipe is skipped entirely -- the folder holds the user's custom profiles, and cancelling a
reinject must never cost them those; only an explicit reinstall (reinstall.lua) deletes an
existing install. delfolder already recurses on the executors that have it; the manual walk
is for the ones that only ship delfile. ]]
--[[ Frees the session-wide flags this boot is holding, so the next manual run is not turned
away by the duplicate guard.

Ownership-checked, because a boot sitting on the key prompt can be taken over by a later
execution (see the guard above). The loser unwinds through here moments after the winner has
stamped its own boot, and clearing the winner's flags would leave the new run looking like a
reload -- headless, with no way to ask for a key. Exactly the state this whole path exists to
get people out of.

shared.slinkyreload goes with them. It is normally consumed at the very bottom of this file,
AFTER main.lua has had its look at it, but a boot that ends early never gets there and the flag
was left standing for the rest of the session. Everything from then on read as a reload: the
console went headless, and a headless console cannot ask for a key. That is what made a lapsed
key unrecoverable in-game -- Reinject failed at the gate telling you to run the loader manually,
and running it manually hit this same stale flag and said it again.

This is the WHOLE of what a failed key gate does. It never calls deleteInstall: the folder holds
the profiles the user built themselves, and wiping those because LuaArmor answered 'expired'
would charge them everything they configured for something a renewed key fixes in ten seconds.
The key outlives the install anyway -- pistonwarekey.json sits outside the folder for exactly
that reason -- so the deletion would be pure loss. ]]
local function releaseBoot()
	if shared.PistonwareLoaderBoot ~= bootStamp then return end
	shared.PistonwareLoaderBoot = nil
	shared.PistonwareKeyPrompt = nil
	shared.slinkyreload = nil
end

local freshInstall = false
--[[ Every cancel and abort path ends here. It frees the duplicate-execution guard at once for the next
manual run, writes out held log lines before any wipe, and deletes the pistonware folder only when
this run created it. ]]
local function deleteInstall()
	releaseBoot()
	stopHoldingLogs()
	if not freshInstall then return end
	pcall(function()
		if delfolder then
			delfolder('pistonware')
			return
		end
		local function purge(folder)
			for _, path in listfiles(folder) do
				if isfolder(path) then
					purge(path)
				elseif delfile then
					delfile(path)
				end
			end
		end
		purge('pistonware')
	end)
end

local function asciiRichText(line)
	local out = {}
	local runColor, runStart = nil, 1
	local function flush(stop)
		if stop < runStart then return end
		local chunk = line:sub(runStart, stop)
		table.insert(out, runColor and ('<font color="'..runColor..'">'..chunk..'</font>') or chunk)
	end
	for i = 1, #line do
		local color = asciiShades[line:sub(i, i)]
		if i > 1 and color ~= runColor then
			flush(i - 1)
			runStart = i
		end
		runColor = color
	end
	flush(#line)
	return table.concat(out)
end

local function createConsole()
	local tweenService = cloneref(game:GetService('TweenService'))
	local inputService = cloneref(game:GetService('UserInputService'))
	local playersService = cloneref(game:GetService('Players'))

		--[[ Whatever a previous run left standing goes first. Several Fail() paths through this
		file return without destroying the console so the message can be read, and each leaves behind
		a GUI tree, three service-level connections and the reveal thread below. Re-executing
		is the natural response to all of them, so without this the leak grows once per attempt
		rather than being replaced. ]]
	pcall(function()
		if type(shared.PistonwareLoaderTeardown) == 'function' then
			shared.PistonwareLoaderTeardown()
		end
	end)

	--[[ Connections on services and the camera, which outlive screen:Destroy() -- unlike the
	button and titlebar ones, which are parented into the GUI and go with it. ]]
	local connections = {}
	local function track(connection)
		table.insert(connections, connection)
		return connection
	end

	local screen = Instance.new('ScreenGui')
	screen.Name = 'PistonwareLoader'
	screen.DisplayOrder = 999999999
	screen.IgnoreGuiInset = true
	screen.ResetOnSpawn = false
	local parented = pcall(function()
		screen.Parent = (gethui and gethui()) or cloneref(game:GetService('CoreGui'))
	end)
	if not parented then
		pcall(function()
			screen.Parent = playersService.LocalPlayer:FindFirstChildOfClass('PlayerGui')
		end)
	end

	local window = Instance.new('Frame')
	window.AnchorPoint = Vector2.new(0.5, 0.5)
	window.Position = UDim2.fromScale(0.5, 0.5)
	window.Size = UDim2.fromOffset(windowWidth, baseWindowHeight)
	window.BackgroundColor3 = palette.Window
	window.BorderSizePixel = 0
	--[[ so minimising can roll the console up behind its own titlebar ]]
	window.ClipsDescendants = true
	window.Parent = screen
	local windowCorner = Instance.new('UICorner')
	windowCorner.CornerRadius = UDim.new(0, 10)
	windowCorner.Parent = window
	local windowStroke = Instance.new('UIStroke')
	windowStroke.Color = palette.Border
	windowStroke.Thickness = 1
	windowStroke.Parent = window

	--[[ One UIScale drives the whole window, so the console keeps its proportions from a phone up
	to a 4K monitor: full size at 1080p, shrunk to fit anything smaller. ]]
	local uiscale = Instance.new('UIScale')
	uiscale.Parent = window
	local camera = workspace.CurrentCamera

	--[[ Window state, the way a desktop WM handles it: minimise rolls the window up into its own
	titlebar (there is no taskbar to minimise *to* here, so shading is the recoverable
	equivalent) and maximise fills the viewport, both toggling back on a second click. ]]
	local minimized, maximized = false, false
	local restorePosition = window.Position
	-- WindowHeight, plus the license row while it shows (SetLicense).
	local windowHeight = baseWindowHeight

	--[[ Sizes and places the loader window for its maximised, minimised or normal state. Sizes are
	before UIScale, so a maximised window divides the viewport by the scale to fill it once scaled.
	]]
	local function applyWindowState(animate)
		local viewport = camera and camera.ViewportSize or Vector2.new(windowWidth, windowHeight)
		local width = maximized and (viewport.X / uiscale.Scale) or windowWidth
		local height = maximized and (viewport.Y / uiscale.Scale) or windowHeight
		local size = UDim2.fromOffset(width, minimized and titleBarHeight or height)
		local position = maximized and UDim2.fromScale(0.5, 0.5) or restorePosition
		if animate then
			tweenService:Create(window, TweenInfo.new(0.16, Enum.EasingStyle.Quad), {Size = size, Position = position}):Play()
		else
			window.Size, window.Position = size, position
		end
	end

	--[[ Scales the window to fit the viewport, capped at the 1080p size. Touch-only devices take the fit
	instead, up to 0.7 and never below the desktop size, because the cap leaves a landscape phone
	with 6px text. A maximised window is laid out again so it keeps tracking the viewport. ]]
	local function applyScale()
		local viewport = camera and camera.ViewportSize or Vector2.new(windowWidth, windowHeight)
		if viewport.X <= 0 or viewport.Y <= 0 then return end
		local fit = math.min(viewport.X * 0.94 / windowWidth, viewport.Y * 0.92 / windowHeight)
		local scale = math.min(fit, viewport.Y / 1080)
		if inputService.TouchEnabled and not inputService.KeyboardEnabled then
			scale = math.max(scale, math.min(fit, 0.7))
		end
		uiscale.Scale = math.clamp(scale, 0.25, 1.4)
		applyWindowState(false)
	end
	applyScale()
	if camera then
		track(camera:GetPropertyChangedSignal('ViewportSize'):Connect(applyScale))
	end

	local titlebar = Instance.new('Frame')
	titlebar.Size = UDim2.new(1, 0, 0, titleBarHeight)
	titlebar.BackgroundColor3 = palette.TitleBar
	titlebar.BorderSizePixel = 0
	titlebar.Parent = window
	local titlebarCorner = Instance.new('UICorner')
	titlebarCorner.CornerRadius = UDim.new(0, 10)
	titlebarCorner.Parent = titlebar
	--[[ Squares off the bottom two corners the UICorner above rounded. ]]
	local titlebarFill = Instance.new('Frame')
	titlebarFill.Position = UDim2.new(0, 0, 1, -10)
	titlebarFill.Size = UDim2.new(1, 0, 0, 10)
	titlebarFill.BackgroundColor3 = palette.TitleBar
	titlebarFill.BorderSizePixel = 0
	titlebarFill.Parent = titlebar

	local icon = Instance.new('TextLabel')
	icon.Position = UDim2.fromOffset(10, 10)
	icon.Size = UDim2.fromOffset(24, 24)
	icon.BackgroundColor3 = Color3.fromRGB(22, 22, 22)
	icon.BorderSizePixel = 0
	icon.Text = '>_'
	icon.TextColor3 = palette.Accent
	icon.TextSize = 13
	icon.Font = Enum.Font.Code
	icon.Parent = titlebar
	local iconCorner = Instance.new('UICorner')
	iconCorner.CornerRadius = UDim.new(0, 5)
	iconCorner.Parent = icon

	local title = Instance.new('TextLabel')
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, -220, 1, 0)
	title.Position = UDim2.fromOffset(110, 0)
	title.Text = './pistonware-loader'
	title.TextColor3 = palette.Title
	title.TextSize = 18
	title.Font = Enum.Font.Code
	title.Parent = titlebar

	--[[ `finished` is raised by Finish(): from then on the boot is complete and the window is only
	counting itself out. ]]
	local closed, aborted, finished = false, false, false
	local console
	--[[ Closes the loader window. closed is set first, so the reveal thread and every wait loop stop
	even if destroying the GUI throws. shared.PistonwareLoaderTeardown is cleared only while it is
	still this window's, since a newer console may own it. The logger outlives the window, so it
	lets go of this console. ]]
	local function destroy()
		if closed then return end
		closed = true
		for _, connection in connections do
			pcall(function() connection:Disconnect() end)
		end
		table.clear(connections)
		pcall(function() screen:Destroy() end)
		if shared.PistonwareLoaderTeardown == destroy then
			shared.PistonwareLoaderTeardown = nil
		end
		if logger.console == console then
			logger.console = nil
		end
	end

	--[[ Closing the window by hand is a cancel, not a dismissal: the boot stops at the next
	checkpoint, and on a first install everything the run wrote is deleted so a half-finished
	install can't be left behind (and no config gets silently picked for you). On an existing
	install deleteInstall refuses to wipe, so cancelling a reinject just stops the boot.

	Except once Finish() has run. The injection has succeeded and pistonware is running out of
	that folder, so [x] or ctrl+c during the countdown only closes the window early -- wiping a
	fresh install there deleted the profiles and cache from under the live GUI. ]]
	local function cancel()
		if finished then
			destroy()
			return
		end
		if aborted then return end
		aborted = true
		destroy()
		deleteInstall()
	end

	--[[ Draws a title-bar glyph from thin rotated bars: Roblox's Code font has no chevron glyphs, and a
	typed 'v' or '^' reads as text beside the title. A chevron is two 10px bars at +-45 degrees
	meeting at the centre of the 34x34 button; close is two 15px bars crossed. ]]
	local function drawGlyph(parent, kind)
		local bars = {}
		local function bar(length, x, y, rotation)
			local piece = Instance.new('Frame')
			piece.AnchorPoint = Vector2.new(0.5, 0.5)
			piece.Position = UDim2.fromOffset(x, y)
			piece.Size = UDim2.fromOffset(length, 2)
			piece.BackgroundColor3 = palette.Glyph
			piece.BorderSizePixel = 0
			piece.Rotation = rotation
			piece.Parent = parent
			local corner = Instance.new('UICorner')
			corner.CornerRadius = UDim.new(0, 1)
			corner.Parent = piece
			table.insert(bars, piece)
		end
		if kind == 'minimize' then
			bar(10, 13.5, 17, 45)
			bar(10, 20.5, 17, -45)
		elseif kind == 'maximize' then
			bar(10, 13.5, 17, -45)
			bar(10, 20.5, 17, 45)
		else
			bar(15, 17, 17, 45)
			bar(15, 17, 17, -45)
		end
		return bars
	end

	--[[ Assigned once the footer exists; the window buttons below are built before it. ]]
	local applyChromeVisibility = function() end

	--[[ Builds the minimise, maximise and close buttons of the title bar. Maximising a rolled-up window
	unrolls it, as a window manager would. ]]
	for index, kind in {'minimize', 'maximize', 'close'} do
		local button = Instance.new('TextButton')
		button.AnchorPoint = Vector2.new(1, 0.5)
		button.Position = UDim2.new(1, -14 - (3 - index) * 38, 0.5, 0)
		button.Size = UDim2.fromOffset(34, 34)
		button.BackgroundColor3 = Color3.new(1, 1, 1)
		button.BackgroundTransparency = 1
		button.AutoButtonColor = false
		button.Modal = true
		button.Text = ''
		button.Parent = titlebar
		local corner = Instance.new('UICorner')
		corner.CornerRadius = UDim.new(0, 6)
		corner.Parent = button

		local bars = drawGlyph(button, kind)
		button.MouseEnter:Connect(function()
			button.BackgroundTransparency = 0.9
			for _, piece in bars do
				piece.BackgroundColor3 = kind == 'close' and palette.Error or Color3.new(1, 1, 1)
			end
		end)
		button.MouseLeave:Connect(function()
			button.BackgroundTransparency = 1
			for _, piece in bars do
				piece.BackgroundColor3 = palette.Glyph
			end
		end)

		button.MouseButton1Click:Connect(function()
			if kind == 'close' then
				cancel()
			elseif kind == 'minimize' then
				minimized = not minimized
				applyWindowState(true)
				applyChromeVisibility()
			else
				maximized = not maximized
				minimized = false
				applyWindowState(true)
				applyChromeVisibility()
			end
		end)
	end

	--[[ Drag by the titlebar. Offsets live in screen space (the UIScale only rescales children),
	so the delta can be applied straight to the window position. ]]
	local dragging, dragStart, dragOrigin
	--[[ Starts a window drag from a mouse or touch press on the title bar; a maximised window is pinned
	to the viewport and does not move. The mouse hands every click the same InputObject, so the
	end-of-press handler disconnects itself, and it is tracked so a window destroyed mid-drag drops
	it too. ]]
	titlebar.InputBegan:Connect(function(input)
		if maximized then return end
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging, dragStart, dragOrigin = true, input.Position, window.Position
			local release
			release = track(input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					dragging = false
					release:Disconnect()
				end
			end))
		end
	end)
	--[[ Moves the window during a drag and keeps restorePosition, so unmaximising and unminimising both
	return it to where it was left. ]]
	track(inputService.InputChanged:Connect(function(input)
		if not dragging then return end
		if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
			local delta = input.Position - dragStart
			window.Position = UDim2.new(dragOrigin.X.Scale, dragOrigin.X.Offset + delta.X, dragOrigin.Y.Scale, dragOrigin.Y.Offset + delta.Y)
			restorePosition = window.Position
		end
	end))

	local ascii = Instance.new('Frame')
	ascii.BackgroundTransparency = 1
	ascii.Position = UDim2.fromOffset(contentPadding, asciiTop)
	ascii.Size = UDim2.fromOffset(windowWidth - contentPadding * 2, #pistonFace * asciiLineHeight)
	ascii.Parent = window

	local rows = {}
	for index, line in pistonFace do
		local label = Instance.new('TextLabel')
		label.BackgroundTransparency = 1
		label.Position = UDim2.fromOffset(0, (index - 1) * asciiLineHeight)
		label.Size = UDim2.new(1, 0, 0, asciiLineHeight)
		label.RichText = true
		label.Text = asciiRichText(line)
		label.TextColor3 = Color3.new(1, 1, 1)
		label.TextSize = asciiTextSize
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextTransparency = 1
		label.Font = Enum.Font.Code
		label.Visible = false
		label.Parent = ascii
		rows[index] = label
	end

	local status = Instance.new('TextLabel')
	status.BackgroundTransparency = 1
	status.Position = UDim2.fromOffset(contentPadding, statusY)
	status.Size = UDim2.new(1, -contentPadding * 2, 0, 28)
	status.RichText = true
	status.TextColor3 = palette.Line
	status.TextSize = 22
	status.TextXAlignment = Enum.TextXAlignment.Left
	status.Font = Enum.Font.Code
	status.Parent = window

	local license = Instance.new('TextLabel')
	license.BackgroundTransparency = 1
	license.Position = UDim2.fromOffset(contentPadding, licenseY)
	license.Size = UDim2.new(1, -contentPadding * 2, 0, 24)
	license.Text = ''
	license.TextColor3 = Color3.fromRGB(158, 158, 158)
	license.TextSize = 17
	license.TextXAlignment = Enum.TextXAlignment.Left
	license.Font = Enum.Font.Code
	license.Parent = window

	local line = Instance.new('TextLabel')
	line.BackgroundTransparency = 1
	line.Position = UDim2.fromOffset(contentPadding, lineY)
	line.Size = UDim2.new(1, -contentPadding * 2, 0, 24)
	line.Text = ''
	line.TextColor3 = palette.Line
	line.TextSize = 17
	line.TextXAlignment = Enum.TextXAlignment.Left
	line.Font = Enum.Font.Code
	line.Parent = window

	--[[ Answer buttons sit on the row directly under the question and are reused for every
	prompt, so answering one question simply rewrites the line above them. ]]
	local answers = Instance.new('Frame')
	answers.BackgroundTransparency = 1
	answers.Position = UDim2.fromOffset(contentPadding, answersY)
	answers.Size = UDim2.new(1, -contentPadding * 2, 0, 34)
	answers.Visible = false
	answers.Parent = window
	local answersLayout = Instance.new('UIListLayout')
	answersLayout.SortOrder = Enum.SortOrder.LayoutOrder
	answersLayout.FillDirection = Enum.FillDirection.Horizontal
	answersLayout.Padding = UDim.new(0, 12)
	answersLayout.Parent = answers

	--[[ Explains what the hovered answer actually does. It rides in the same list layout as the
	buttons (LayoutOrder puts it last, after however many there are) so it lands on their row
	with the same gap between, and a hidden child takes no space -- the row closes up around
	it while nothing is hovered. Ask() only clears TextButtons, so this survives each question. ]]
	local tooltip = Instance.new('TextLabel')
	tooltip.Name = 'Tooltip'
	tooltip.LayoutOrder = 999
	tooltip.AutomaticSize = Enum.AutomaticSize.X
	tooltip.Size = UDim2.fromOffset(0, 34)
	tooltip.BackgroundColor3 = Color3.fromRGB(18, 18, 18)
	tooltip.BorderSizePixel = 0
	tooltip.Visible = false
	tooltip.Text = ''
	tooltip.TextColor3 = palette.Line
	tooltip.TextSize = 15
	tooltip.Font = Enum.Font.Code
	tooltip.Parent = answers
	local tooltipPadding = Instance.new('UIPadding')
	tooltipPadding.PaddingLeft = UDim.new(0, 12)
	tooltipPadding.PaddingRight = UDim.new(0, 12)
	tooltipPadding.Parent = tooltip
	local tooltipCorner = Instance.new('UICorner')
	tooltipCorner.CornerRadius = UDim.new(0, 4)
	tooltipCorner.Parent = tooltip
	local tooltipStroke = Instance.new('UIStroke')
	tooltipStroke.Color = palette.ButtonBorder
	tooltipStroke.Thickness = 1
	tooltipStroke.Parent = tooltip

	local footer = Instance.new('TextLabel')
	footer.AnchorPoint = Vector2.new(0, 1)
	footer.BackgroundTransparency = 1
	footer.Position = UDim2.new(0, contentPadding, 1, -16)
	footer.Size = UDim2.new(1, -contentPadding * 2, 0, 22)
	--[[ Touch-only devices have no ctrl key, so point them at the titlebar button instead. ]]
	footer.Text = (inputService.TouchEnabled and not inputService.KeyboardEnabled) and 'Tap [x] to exit' or 'Press [CTRL+C] to exit'
	footer.TextColor3 = palette.Footer
	footer.TextSize = 17
	footer.TextXAlignment = Enum.TextXAlignment.Left
	footer.Font = Enum.Font.Code
	footer.Parent = window

	--[[ An opt-out for the question currently being asked, in the bottom-right corner opposite
	the footer. Greyed out on purpose: it is the answer nobody should click by accident.
	Ask() shows it only when the caller passes one, and hides it again afterwards. ]]
	local optOutButton = Instance.new('TextButton')
	optOutButton.AnchorPoint = Vector2.new(1, 1)
	optOutButton.BackgroundTransparency = 1
	optOutButton.Position = UDim2.new(1, -contentPadding, 1, -16)
	optOutButton.Size = UDim2.fromOffset(0, 22)
	optOutButton.AutomaticSize = Enum.AutomaticSize.X
	optOutButton.AutoButtonColor = false
	optOutButton.Modal = true
	optOutButton.Visible = false
	optOutButton.Text = ''
	optOutButton.TextColor3 = palette.Footer
	optOutButton.TextSize = 17
	optOutButton.TextXAlignment = Enum.TextXAlignment.Right
	optOutButton.Font = Enum.Font.Code
	optOutButton.Parent = window
	optOutButton.MouseEnter:Connect(function()
		optOutButton.TextColor3 = palette.Line
	end)
	optOutButton.MouseLeave:Connect(function()
		optOutButton.TextColor3 = palette.Footer
	end)

	--[[ The footer and the opt-out are anchored to the bottom edge, so a rolled-up window would
	leave them floating over the titlebar. Hidden while minimised. ]]
	local optOutActive = false
	applyChromeVisibility = function()
		footer.Visible = not minimized
		optOutButton.Visible = optOutActive and not minimized
	end

	track(inputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then return end
		if input.KeyCode == Enum.KeyCode.C and inputService:IsKeyDown(Enum.KeyCode.LeftControl) then
			cancel()
		end
	end))

	local revealed, revealTarget = 0, 0
	--[[ Set by Halt() on the paths that leave the window up for reading but have no more rows
	to draw. Without it this thread outlives the boot at ~14Hz for the rest of the session. ]]
	local halted = false
	task.spawn(function()
		while not closed and not halted do
			if revealed < revealTarget then
				revealed += 1
				local row = rows[revealed]
				row.Visible = true
				tweenService:Create(row, TweenInfo.new(0.18), {TextTransparency = 0}):Play()
			end
			task.wait(0.07)
		end
	end)

	--[[ Builds one flat terminal button for the answer row of Ask() and the key entry row of AskKey().
	Callers add their own MouseEnter and MouseLeave handlers on top of the accent hover here; Roblox
	runs every connection. Modal frees the touch cursor, so the button can be tapped on phones. ]]
	local function answerButton(text, width, order)
		local button = Instance.new('TextButton')
		button.LayoutOrder = order
		button.Size = UDim2.fromOffset(width, 34)
		button.BackgroundColor3 = Color3.fromRGB(18, 18, 18)
		button.BorderSizePixel = 0
		button.AutoButtonColor = false
		button.Modal = true
		button.Text = text
		button.TextColor3 = palette.ButtonIdle
		button.TextSize = 17
		button.Font = Enum.Font.Code
		button.Parent = answers
		local corner = Instance.new('UICorner')
		corner.CornerRadius = UDim.new(0, 4)
		corner.Parent = button
		local stroke = Instance.new('UIStroke')
		stroke.Color = palette.ButtonBorder
		stroke.Thickness = 1
		stroke.Parent = button
		button.MouseEnter:Connect(function()
			stroke.Color = palette.Accent
			button.TextColor3 = palette.Accent
		end)
		button.MouseLeave:Connect(function()
			stroke.Color = palette.ButtonBorder
			button.TextColor3 = palette.ButtonIdle
		end)
		return button
	end

	--[[ The controls that Ask() and AskKey() put on the answer row are cleared between prompts. The tooltip
	label shares the frame and has to survive, hence the class test rather than a blanket
	ClearAllChildren. ]]
	local function clearAnswers()
		for _, child in answers:GetChildren() do
			if child:IsA('TextButton') or child:IsA('TextBox') then
				child:Destroy()
			end
		end
	end

	console = {}

	--[[ `chevron` is the glyph in front of the status word. It points forward ('>') for every
	step of the boot itself, and backward ('<') for the key gate, which is the one phase that
	is holding the boot up rather than advancing it. Escaped, since the label is RichText. ]]
	function console:SetStatus(text, color, chevron)
		status.Text = '<font color="#9E9E9E">'..(chevron == '<' and '&lt;' or '&gt;')..'</font> <font color="'..(color or '#F07A1F')..'">'..text..'</font>'
	end

	function console:SetLine(text, color)
		line.Text = text
		line.TextColor3 = color or palette.Line
	end

	--[[ Shows the licence line. The window grows by licenseRow only while the line has text, and the
	output line and answer row move down with it. ]]
	function console:SetLicense(text)
		license.Text = text or ''
		local shift = license.Text ~= '' and licenseRow or 0
		if baseWindowHeight + shift ~= windowHeight then
			windowHeight = baseWindowHeight + shift
			line.Position = UDim2.fromOffset(contentPadding, lineY + shift)
			answers.Position = UDim2.fromOffset(contentPadding, answersY + shift)
			applyScale()
		end
	end

	--[[ alpha is how far through the boot we are; the face is drawn to match, one row at a time.
	Clamped upwards only: a late progress report from a background step must never pull rows
	back off the face (nothing here ever un-boots). ]]
	function console:SetProgress(alpha)
		local count = math.clamp(math.floor(alpha * #pistonFace + 0.5), 0, #pistonFace)
		revealTarget = math.max(revealTarget, count)
	end

	function console:IsAborted()
		return aborted
	end

	--[[ Asks a question on the output line, waits for one of the buttons under it, then clears the line
	for the next question. Returns fallback when the loader is closed or the timeout passes, so a
	missed click never hangs injection. optOut is one more answer, {text, key, tooltip}, drawn in
	the corner; its connections are dropped when the question ends. ]]
	function console:Ask(question, buttons, timeoutSeconds, fallback, optOut)
		if closed then return fallback end
		self:SetLine(question)
		clearAnswers()

		tooltip.Visible = false

		local choice
		local optOutConnections = {}
		if optOut then
			optOutButton.Text = optOut.text
			optOutButton.TextColor3 = palette.Footer
			table.insert(optOutConnections, optOutButton.MouseButton1Click:Connect(function()
				choice = optOut.key
			end))
			if optOut.tooltip then
				table.insert(optOutConnections, optOutButton.MouseEnter:Connect(function()
					tooltip.Text = optOut.tooltip
					tooltip.Visible = true
				end))
				table.insert(optOutConnections, optOutButton.MouseLeave:Connect(function()
					tooltip.Visible = false
				end))
			end
			optOutActive = true
			applyChromeVisibility()
		end
		for index, def in buttons do
			local button = answerButton(def.text, 132, index)
			if def.tooltip then
				button.MouseEnter:Connect(function()
					tooltip.Text = def.tooltip
					tooltip.Visible = true
				end)
				button.MouseLeave:Connect(function()
					tooltip.Visible = false
				end)
			end
			button.MouseButton1Click:Connect(function()
				choice = def.key
			end)
		end
		answers.Visible = true

		local timeout = os.clock() + (timeoutSeconds or 60)
		repeat task.wait() until choice ~= nil or closed or os.clock() > timeout
		answers.Visible = false
		optOutActive = false
		applyChromeVisibility()
		for _, connection in optOutConnections do
			connection:Disconnect()
		end
		clearAnswers()
		tooltip.Visible = false
		self:SetLine('')
		if choice == nil then
			return fallback
		end
		return choice
	end

	--[[ Draws the key entry into the console's own question row, under the '< KEY SYSTEM' status, so the
	gate reads as one more terminal prompt rather than a modal. Every handler gets say(message,
	kind) and does its own reporting, which keeps all knowledge of the key service out of the
	console. onSubmit returns whether the key was accepted; anything false leaves the prompt up.
	Returns the accepted key, or nil when the window was closed.

	No timeout, unlike Ask(): every boot question has a fallback answer and a missing key does not,
	and the user may be away in a browser finishing checkpoints. busy stops a second check while one
	is in flight, since check_key is a network round trip. Hover help goes on the footer, not
	Ask()'s inline tooltip, which shares the row's list layout and would push the row past the
	window edge; the footer is restored on the way out. One button per entry of opts.links, in its
	order; the row's widths fit 948px usable, 945px with every button showing. The paste button
	exists only when opts.onPaste is given, that is when the executor can read the clipboard. ]]
	function console:AskKey(opts)
		if closed then return nil end
		clearAnswers()
		tooltip.Visible = false

		local function say(message, kind)
			self:SetLine(message or '', kind == 'err' and palette.Error or (kind == 'ok' and palette.Ok or palette.Line))
		end
		say(opts.message, opts.messageKind)

		local previousFooter = footer.Text
		if opts.footer then
			footer.Text = opts.footer
		end

		local box = Instance.new('TextBox')
		box.LayoutOrder = 1
		box.Size = UDim2.fromOffset(260, 34)
		box.BackgroundColor3 = Color3.fromRGB(18, 18, 18)
		box.BorderSizePixel = 0
		box.ClearTextOnFocus = false
		box.Text = ''
		box.PlaceholderText = opts.placeholder or ''
		box.PlaceholderColor3 = palette.Footer
		box.TextColor3 = palette.Line
		box.TextSize = 16
		box.TextXAlignment = Enum.TextXAlignment.Left
		box.Font = Enum.Font.Code
		box.Parent = answers
		local boxCorner = Instance.new('UICorner')
		boxCorner.CornerRadius = UDim.new(0, 4)
		boxCorner.Parent = box
		local boxStroke = Instance.new('UIStroke')
		boxStroke.Color = palette.ButtonBorder
		boxStroke.Thickness = 1
		boxStroke.Parent = box
		local boxPadding = Instance.new('UIPadding')
		boxPadding.PaddingLeft = UDim.new(0, 10)
		boxPadding.PaddingRight = UDim.new(0, 10)
		boxPadding.Parent = box
		box.Focused:Connect(function()
			boxStroke.Color = palette.Accent
		end)
		box.FocusLost:Connect(function()
			boxStroke.Color = palette.ButtonBorder
		end)

		local accepted
		local busy = false
		local function submit()
			if busy or closed or accepted then return end
			busy = true
			local key = trim(box.Text)
			if opts.onSubmit(key, say) then
				accepted = key
			end
			busy = false
		end

		local function hint(button, text)
			if not text then return end
			button.MouseEnter:Connect(function()
				footer.Text = text
			end)
			button.MouseLeave:Connect(function()
				footer.Text = opts.footer or previousFooter
			end)
		end

		local order = 1
		for _, link in opts.links or {} do
			order += 1
			local button = answerButton(link.text, link.width or 105, order)
			hint(button, link.tooltip)
			button.MouseButton1Click:Connect(function()
				link.onClick(say)
			end)
		end

		if opts.onPaste then
			order += 1
			local paste = answerButton(opts.pasteText, 95, order)
			hint(paste, opts.pasteTip)
			paste.MouseButton1Click:Connect(function()
				local text = opts.onPaste(say)
				if text then
					box.Text = text
				end
			end)
		end

		order += 1
		local submitButton = answerButton(opts.submitText, 115, order)
		hint(submitButton, opts.submitTip)
		submitButton.MouseButton1Click:Connect(submit)

		order += 1
		local help = answerButton(opts.helpText, 110, order)
		hint(help, opts.helpTip)
		help.MouseButton1Click:Connect(function()
			opts.onHelp(say)
		end)

		box.FocusLost:Connect(function(enterPressed)
			if enterPressed then
				submit()
			end
		end)

		answers.Visible = true
		repeat task.wait() until accepted or closed

		answers.Visible = false
		clearAnswers()
		footer.Text = previousFooter
		self:SetLine('')
		return accepted
	end

	--[[ Waits up to 2 s for the remaining rows of the face, then shows DONE and counts the window out
	before destroying it. finished is raised before anything yields, so closing the window from then
	on is a dismissal (see cancel). ]]
	function console:Finish(message, seconds)
		finished = true
		if closed then return end
		self:SetProgress(1)
		local drawn = os.clock() + 2
		repeat task.wait() until revealed >= #pistonFace or closed or os.clock() > drawn
		task.wait(0.2)
		if closed then return end
		self:SetStatus('DONE')
		seconds = seconds or 5
		local deadline = os.clock() + seconds
		task.spawn(function()
			while not closed do
				local left = math.max(0, math.ceil(deadline - os.clock()))
				self:SetLine(message..' Loader will close in '..left..'s.')
				if left <= 0 then break end
				task.wait(0.2)
			end
			destroy()
		end)
	end

	--[[ Stops the reveal thread without taking the window down, for the paths that end the boot
	but still want the message on screen. Everything already drawn stays drawn. ]]
	function console:Halt()
		halted = true
	end

	--[[ Shows a failure on the status and output line and halts the console. The line wraps down into
	the answer row's space, because executor errors carry absolute paths that run off a single line
	and nothing is asked after a failure. ]]
	function console:Fail(err)
		if closed then return end
		self:SetStatus('FAILED', '#E15046')
		line.TextWrapped = true
		line.TextYAlignment = Enum.TextYAlignment.Top
		line.Size = UDim2.new(1, -contentPadding * 2, 0, answersY + 34 - lineY)
		self:SetLine(err, palette.Error)
		self:Halt()
	end

	--[[ Published so the next execution can tear this console down before building its own. ]]
	shared.PistonwareLoaderTeardown = destroy

	return console
end

--[[ The console's surface with nothing drawn, for reloads (the queued teleport script, the GUI's
reinject buttons), which run the same boot with no window over the game. Fail still sends a Roblox
notification, since a failed reload has usually torn the old GUI down already. Ask answers its
fallback at once. AskKey answers nil: nobody is there to type a key, and the caller turns that into
a clean failure instead of hanging on an invisible prompt. ]]
local function createHeadlessConsole()
	local console = {}
	function console:SetStatus() end
	function console:SetLine() end
	function console:SetLicense() end
	function console:SetProgress() end
	function console:Finish() end
	function console:Fail(err)
		pcall(function()
			local text = tostring(err or 'Loader stopped')
			local copied = text:find('(copied to clipboard)', 1, true) ~= nil
			text = text:gsub('%s*%(copied to clipboard%)%s*$', '')
			if #text > 180 then text = text:sub(1, 177)..'...' end
			if copied then text = text..' (copied to clipboard)' end
			game:GetService('StarterGui'):SetCore('SendNotification', {Title = 'Pistonware', Text = text, Duration = 15})
		end)
	end
	function console:Halt() end
	function console:IsAborted() return false end
	function console:Ask(question, buttons, timeoutSeconds, fallback)
		return fallback
	end
	function console:AskKey()
		return nil
	end
	return console
end

--[[ shared.slinkyreload marks a run that something else started rather than a manual execution.
Read once here: it is cleared after main.lua has had its look at it (see the bottom of this
file), because nothing else clears it and a stale true would hide the console from every
later manual execution in the session. ]]
local isReload = shared.slinkyreload and true or false

local console
local consoleOk, consoleResult = xpcall(function()
	return isReload and createHeadlessConsole() or createConsole()
end, errorTrace)
if consoleOk then
	console = consoleResult
else
	console = createHeadlessConsole()
	stopExecution(console, 'console.create', consoleResult, consoleResult)
	return
end
logger:bindConsole(console)
logger:info('console.ready', isReload and 'headless console ready' or 'console ready', {reload = isReload})
--[[ The key gate is the first thing that runs -- every run, reinjects included -- so the console
opens directly onto it rather than flashing '> INJECTING' for a frame first. ]]
console:SetStatus('AUTHENTICATING', nil, '<')
console:SetLine('Checking your key...')
console:SetProgress(0.08)

--[[ The key gate. Nothing after it runs until a key validates: no folder is created, no file is
downloaded, and main.lua, guilibrary.lua and the game files are never reached.

shared.PistonwareAuthenticated is cleared first and set only by a key the key service accepts on
this run, because shared lives for the whole executor session and a flag found there would skip the
gate in one line. That costs one check_key per loader run, reinjects included. Candidates are tried
in order until one validates: a script_key global set in front of the loadstring (read from the
chunk's globals, getgenv() and _G, since executors disagree on where it lands), shared.PistonwareKey
carried by a reinject, then pistonwarekey.json. A key that works is saved there; the file sits at
the workspace root so a reinstall or a cancelled first install cannot cost it. Only the saved key is
ever deleted, and only on KEY_INCORRECT or KEY_BANNED: KEY_HWID_LOCKED is a valid key waiting for an
HWID reset, KEY_EXPIRED is renewed in place, and the error codes mean the service, the network or
the executor failed, not the key.

The key library is fetched with 3 tries; after a failed round a 5 s cooldown stops the candidate
sweep from fetching it again for each key, while a person pressing Submit again gets a fresh
attempt. A result marked library = true means nothing was checked and is never a rejection. The
accepted key is written to script_key in the chunk's globals, getgenv() and _G, since later chunks
read it and those tables differ on some executors; shared.PistonwareKey carries it across teleports.

A rejected key stops this boot only: nothing already injected is torn down. When no key validates
the prompt is always shown, even on a reload, since every route here is a deliberate action; a
closed or headless console is rebuilt, up to 3 tries. shared.PistonwareKeyPrompt, stamped with this
boot, lets a second execution past the duplicate-execution guard while the prompt is up. Closing the
window during a check that then succeeds still stops the boot, but the key stays saved. In the
public build the licence line then shows a lifetime key or the time left. ]]
do
	local httpService = cloneref(game:GetService('HttpService'))

	local canPaste = (getclipboard ~= nil) or (syn ~= nil and syn.read_clipboard ~= nil)
	local function clipboardGet()
		local fn = getclipboard or (syn and syn.read_clipboard)
		if not fn then return nil end
		local ok, res = pcall(fn)
		if ok and type(res) == 'string' then return res end
		return nil
	end
	local function clipboardSet(text)
		if not setclipboard then return false end
		return (pcall(setclipboard, text))
	end

	local function copyLink(name, url, say)
		if url == '' then
			say(t('link_missing', name), 'err')
			return
		end
		if clipboardSet(url) then
			say(t('link_copied', name))
		else
			say(t('copy_failed'), 'err')
		end
	end

	local hasFiles = (isfile and readfile and writefile) and true or false
	local function readSavedKey()
		if not hasFiles then return nil end
		local ok, key = pcall(function()
			if isfile(KEY_FILE) then
				local decoded = httpService:JSONDecode(readfile(KEY_FILE))
				if type(decoded) == 'table' then return decoded.key end
			end
			return nil
		end)
		return ok and key or nil
	end
	local function saveKey(key)
		if not hasFiles then return end
		pcall(function()
			writefile(KEY_FILE, httpService:JSONEncode({key = key, saved = os.time()}))
		end)
	end
	local function deleteSavedKey()
		pcall(function()
			if isfile(KEY_FILE) then
				delfile(KEY_FILE)
			end
		end)
	end

	local function shortError(err, limit)
		return safeText(err, limit or 160)
	end

	local function errorMessage(err)
		return shortError(select(1, tostring(err or ''):gsub('^.-:%d+: ', '')), 90)
	end

	local api, apiCooldown, apiFailure, apiDetail
	local function getApi()
		if api then return api end
		if apiCooldown and os.clock() < apiCooldown then return nil end

		for attempt = 1, 3 do
			local ok, body = pcall(function()
				return httpGet('https://sdkapi-public.luarmor.net/library.lua', true)
			end)
			if not ok then
				apiFailure, apiDetail = 'network', shortError(body)
			elseif type(body) ~= 'string' or body == '' then
				apiFailure, apiDetail = 'no response', 'the request came back empty'
			else
				local chunk, compileError = loadstring(body, 'luarmor')
				if not chunk then
					apiFailure, apiDetail = 'blocked', shortError(compileError)
				else
					local ranOk, lib = pcall(chunk)
					if not ranOk then
						apiFailure, apiDetail = 'library error', shortError(lib)
					elseif type(lib) ~= 'table' or type(lib.check_key) ~= 'function' then
						apiFailure, apiDetail = 'bad library', 'the SDK loaded without a check_key'
					else
						lib.script_id = SCRIPT_ID
						api = lib
						apiFailure, apiDetail = nil, nil
						return api
					end
				end
			end
			if attempt < 3 then task.wait(attempt) end
		end

		apiCooldown = os.clock() + 5
		logger:warn('key.library', 'could not load the LuaArmor SDK', {reason = apiFailure, detail = apiDetail})
		return nil
	end
	local function checkKey(key)
		local lib = getApi()
		if not lib then
			return {code = 'UNKNOWN_ERROR', library = true, message = t('no_library', apiFailure or 'unknown')}
		end
		local ok, status = pcall(function()
			return lib.check_key(key)
		end)
		if ok and type(status) == 'table' and status.code then return status end
		if not ok then logger:warn('key.check', 'check_key failed', {detail = shortError(status)}) end
		return {code = 'UNKNOWN_ERROR', library = true, message = t('check_error', ok and 'no response' or errorMessage(status))}
	end

	local function authenticate(key)
		script_key = key
		pcall(function() getgenv().script_key = key end)
		pcall(function() _G.script_key = key end)
		shared.PistonwareKey = key
		shared.PistonwareAuthenticated = true
	end

	shared.PistonwareAuthenticated = nil

	do
		local reason
		local notice

		local savedKey = readSavedKey()
		if savedKey then
			savedKey = trim(savedKey)
			if savedKey == '' then savedKey = nil end
		end

		local candidates, seen = {}, {}
		local function offer(value)
			if type(value) ~= 'string' then return end
			value = trim(value)
			if value == '' or seen[value] then return end
			seen[value] = true
			table.insert(candidates, value)
		end

		for _, src in {
			function() return script_key end,
			function() return getgenv().script_key end,
			function() return _G.script_key end
		} do
			local ok, value = pcall(src)
			if ok then offer(value) end
		end
		offer(shared.PistonwareKey)
		offer(savedKey)

		for _, candidate in candidates do
			local status = checkKey(candidate)
			local code = status.code
			local fromDisk = candidate == savedKey
			if code == 'KEY_VALID' then
				rememberExpiry(status)
				authenticate(candidate)
				if candidate ~= savedKey then saveKey(candidate) end
				break
			elseif code == 'KEY_EXPIRED' then
				reason = fromDisk and t('saved_expired') or t('expired')
			elseif code == 'KEY_HWID_LOCKED' then
				reason = fromDisk and t('saved_hwid') or t('hwid_locked')
			elseif code == 'KEY_INCORRECT' then
				if fromDisk then deleteSavedKey() end
				reason = fromDisk and t('saved_incorrect') or t('incorrect')
			elseif code == 'KEY_BANNED' then
				if fromDisk then deleteSavedKey() end
				reason = fromDisk and t('saved_banned') or t('banned')
			elseif status.library then
				notice = status.message
			end
		end

		if not shared.PistonwareAuthenticated then
			local canPrompt = false
			for attempt = 1, 3 do
				if attempt == 1 and not isReload and not console:IsAborted() then
					canPrompt = true
					break
				end
				local built, upgraded = pcall(createConsole)
				if built and upgraded then
					console = upgraded
					logger:bindConsole(console)
					canPrompt = true
					break
				end
				logger:warn('key.console', 'could not build the key prompt console', {attempt = attempt})
				task.wait(0.5)
			end

			console:SetStatus('KEY SYSTEM', nil, '<')
			console:SetProgress(0.1)

			shared.PistonwareKeyPrompt = bootStamp
			flushLogs()

			local key = console:AskKey({
				message = reason or notice or t('enter_key'),
				messageKind = (reason or notice) and 'err' or nil,
				placeholder = t('placeholder'),
				footer = t('footer'),
				pasteText = t('paste'),
				pasteTip = t('tip_paste'),
				submitText = t('submit'),
				submitTip = t('tip_submit'),
				helpText = t('need_help'),
				helpTip = t('tip_help'),
				links = {
					{text = t('work_ink'), width = 200, tooltip = t('tip_work_ink'), onClick = function(say)
						copyLink('Work.ink', WORKINK_URL, say)
					end},
					{text = t('loot_labs'), tooltip = t('tip_loot_labs'), onClick = function(say)
						copyLink('LootLabs', LOOTLABS_URL, say)
					end}
				},
				onPaste = canPaste and function(say)
					local clip = clipboardGet()
					if clip and trim(clip) ~= '' then
						say(t('pasted'))
						return trim(clip)
					end
					say(t('clipboard_empty'), 'err')
					return nil
				end or nil,
				onHelp = function(say)
					if clipboardSet(HELP_URL) then
						say(t('help_copied'))
					else
						say(t('copy_failed'), 'err')
					end
				end,
				onSubmit = function(key, say)
					if key == '' then
						say(t('empty_key'), 'err')
						return false
					end
					if #key < 8 then
						say(t('bad_format'), 'err')
						return false
					end
					say(t('checking'))
					local status = checkKey(key)
					local code = status.code
					if code == 'KEY_VALID' then
						saveKey(key)
						rememberExpiry(status)
						say(t('valid_loading', keyDetail(status)), 'ok')
						authenticate(key)
						return true
					elseif code == 'KEY_HWID_LOCKED' then
						say(t('hwid_locked'), 'err')
					elseif code == 'KEY_EXPIRED' then
						say(t('expired'), 'err')
					elseif code == 'KEY_BANNED' then
						say(t('banned'), 'err')
					elseif code == 'KEY_INCORRECT' then
						say(t('incorrect'), 'err')
					elseif code == 'KEY_INVALID' then
						say(t('invalid_format'), 'err')
					elseif status.library then
						say(status.message, 'err')
					else
						say(t('check_failed', tostring(status.message), tostring(code)), 'err')
					end
					return false
				end
			})

			if shared.PistonwareKeyPrompt == bootStamp then
				shared.PistonwareKeyPrompt = nil
			end

			if not key or console:IsAborted() then
				local message = (not canPrompt) and t('headless') or t('cancelled')
				if not console:IsAborted() then
					console:Fail(message)
				end
				logger:warn('loader.cancelled', message)
				releaseBoot()
				return
			end
		end
	end

	phase('key gate')
	console:SetStatus('INJECTING')
	if PUBLIC_BUILD then
		local expire = tonumber(shared.PistonwareKeyExpire)
		local left = expire and expire > 0 and formatDuration(expire - os.time()) or nil
		if expire == -1 then
			console:SetLicense(t('license_lifetime'))
		elseif left then
			console:SetLicense(t('license_expires', left))
		end
	end
	console:SetLine('Injecting into ROBLOX...')
	console:SetProgress(0.12)
end

--[[ Queues the loader for the next server even when this boot never reached main.lua's finishLoading,
where main.lua queues its own teleport script. It connects once the key has validated, so a teleport
always comes back through the loader.

It never queues twice. Both handlers set shared.PistonwareTeleportQueued when they queue, and this
one defers first, so main.lua's handler goes first with its full script and this one stands down. It
also stands down once main.lua sets shared.PistonwareTeleportOwned (main.lua then disconnects
shared.PistonwareDevTeleportConnection, so nothing queues after an Unload), in an independent
session, and after a boot the user cancelled. A Failed teleport state is ignored.

The teleport queue is looked up under every name executors use (queue_on_teleport, queueonteleport,
queueteleport, syn and fluxus) as a global, then through getgenv() and getrenv(), and copied to
queue_on_teleport and queueonteleport wherever those are missing before main.lua compiles, because
main.lua and the game files look only under those names. A name that holds something is never
touched. Executors differ in the environment loadstring gives a chunk, and Xeno has no getgenv():
check chunks compiled both ways main.lua is (directly and through pcall) test whether they see it, a
chunk compiled the same way assigns it where they do not, and only when a fresh chunk still cannot
see it is the table its environment reads through filled. Not through getfenv() on a shared
environment, which switches off Luau's fast paths for every script in it; never getrenv(), a frozen
table or a read-only one.

The queued script carries the key, channel, profile and branch. It fetches loader.lua from the
channel's branch with 3 tries, then falls back to pistonware/loader.lua, and logs each step to
pistonware_teleport.log with the key redacted. A token file lets only the newest queued copy run,
because Delta runs every script ever queued again on each join. No line logged here holds the key.
The connection is made from its own thread, waiting up to 120 s for LocalPlayer, so nothing here can
hold up or abort the boot. ]]
do
	local queueTeleport
	local resolved, resolveError = pcall(function()
		local function callable(value)
			if type(value) == 'function' then return true end
			if type(value) ~= 'table' and type(value) ~= 'userdata' then return false end
			local ok, meta = pcall(getmetatable, value)
			return ok and type(meta) == 'table' and rawget(meta, '__call') ~= nil
		end
		local function lookIn(env)
			if type(env) ~= 'table' then return nil end
			for _, name in {'queue_on_teleport', 'queueonteleport', 'queueteleport'} do
				local ok, value = pcall(function() return env[name] end)
				if ok and callable(value) then return value, name end
			end
			for _, library in {'syn', 'fluxus'} do
				local ok, value = pcall(function()
					local tbl = env[library]
					return type(tbl) == 'table' and tbl.queue_on_teleport or nil
				end)
				if ok and callable(value) then return value, library..'.queue_on_teleport' end
			end
			return nil
		end

		local plain = {}
		pcall(function()
			plain = {
				queue_on_teleport = queue_on_teleport,
				queueonteleport = queueonteleport,
				queueteleport = queueteleport,
				syn = syn,
				fluxus = fluxus
			}
		end)
		local genv, renv, readonly
		pcall(function() genv = getgenv() end)
		pcall(function() renv = getrenv() end)
		if type(genv) ~= 'table' then genv = nil end
		if type(renv) ~= 'table' then renv = nil end
		pcall(function() readonly = isreadonly end)
		if type(readonly) ~= 'function' and genv then
			pcall(function() readonly = genv.isreadonly end)
		end

		local found, name = lookIn(plain)
		local foundAs = name
		if not found then
			found, name = lookIn(genv)
			foundAs = name and 'getgenv().'..name
		end
		if not found then
			found, name = lookIn(renv)
			foundAs = name and 'getrenv().'..name
		end
		if not found then return end
		if type(found) ~= 'function' then
			local callableValue = found
			found = function(...)
				return callableValue(...)
			end
		end
		queueTeleport = found

		local function writable(env)
			if type(env) ~= 'table' or (renv and rawequal(env, renv)) then return false end
			local frozenOk, frozen = pcall(table.isfrozen, env)
			if frozenOk and frozen then return false end
			if type(readonly) == 'function' then
				local readOk, isRead = pcall(readonly, env)
				if readOk and isRead then return false end
			end
			return true
		end
		local filled = {}
		local function fill(env, label, reader)
			if not writable(env) then return end
			for _, standard in {'queue_on_teleport', 'queueonteleport'} do
				pcall(function()
					if env[standard] == nil and (reader or env)[standard] == nil then
						env[standard] = found
						table.insert(filled, label..standard)
					end
				end)
			end
		end
		pcall(function()
			if queue_on_teleport == nil then
				queue_on_teleport = found
				table.insert(filled, 'queue_on_teleport')
			end
		end)
		pcall(function()
			if queueonteleport == nil then
				queueonteleport = found
				table.insert(filled, 'queueonteleport')
			end
		end)
		fill(genv, 'getgenv().')

		local compilers = {
			function(source, chunkName)
				return loadstring(source, chunkName)
			end,
			function(source, chunkName)
				local ok, chunk = pcall(loadstring, source, chunkName)
				return ok and chunk or nil
			end
		}
		local function sees(compile)
			local ok, chunk = pcall(compile, 'return queue_on_teleport', 'teleport-check')
			if not ok or type(chunk) ~= 'function' then return nil end
			local ran, value = pcall(chunk)
			return ran and callable(value), chunk
		end
		local publish = 'local found = ...\nlocal names = {}\n'
			..'if queue_on_teleport == nil then queue_on_teleport = found names[#names + 1] = "queue_on_teleport" end\n'
			..'if queueonteleport == nil then queueonteleport = found names[#names + 1] = "queueonteleport" end\n'
			..'return names'
		local checked, unseen = 0, 0
		for _, compile in compilers do
			local seen, probe = sees(compile)
			if seen ~= nil then
				checked += 1
				if not seen then
					local wrote
					pcall(function()
						local ran, names = pcall(compile(publish, 'teleport-publish'), found)
						if ran and type(names) == 'table' and #names > 0 then wrote = names end
					end)
					seen, probe = sees(compile)
					if seen and wrote then
						for _, standard in wrote do
							table.insert(filled, 'chunk globals.'..tostring(standard))
						end
					end
					if seen == false and wrote then
						local envOk, env = pcall(getfenv, probe)
						if envOk and type(env) == 'table' then
							local metaOk, meta = pcall(getmetatable, env)
							if metaOk and type(meta) == 'table' then
								fill(rawget(meta, '__index'), 'chunk env parent.', env)
							end
						end
						seen = sees(compile)
					end
				end
				if not seen then unseen += 1 end
			end
		end

		pistonwareBuffer.print('teleport.lookup', 'teleport queue found as '..foundAs, {
			filled = #filled > 0 and table.concat(filled, ', ')
				or (unseen > 0 and 'none (nothing would take it)' or 'none (nothing was missing)')
		})
		if checked == 0 then
			pistonwareBuffer.warn('teleport.publish', 'no check chunk would compile, so whether main.lua and the game files can see queue_on_teleport is unknown')
		elseif unseen > 0 then
			pistonwareBuffer.warn('teleport.publish', 'a chunk compiled here still cannot see queue_on_teleport, so main.lua and the game files will report no teleport support')
		end
	end)
	if not resolved then
		pistonwareBuffer.error('teleport.lookup', tostring(resolveError))
	end

	local function scrub(text)
		text = tostring(text)
		local key = rawget(shared, 'PistonwareKey')
		if type(key) == 'string' and key ~= '' then
			text = text:gsub((key:gsub('%p', '%%%0')), '<redacted>')
		end
		return text
	end

	local fallbackOk, fallbackError = pcall(function()
		if type(queueTeleport) ~= 'function' then
			pistonwareBuffer.warn('teleport.unsupported', 'this executor has no queue_on_teleport; pistonware will not re-inject after a teleport')
			return
		end
		local previous = rawget(shared, 'PistonwareDevTeleportConnection')
		if previous then
			rawset(shared, 'PistonwareDevTeleportConnection', nil)
			pcall(function() previous:Disconnect() end)
		end
		rawset(shared, 'PistonwareTeleportQueued', nil)
		rawset(shared, 'PistonwareTeleportOwned', nil)

		local body = [==[
shared.slinkyreload = true
-- Kept from the start: the loader can switch shared.PistonwareKey to another key before a line is written.
local carriedKey = rawget(shared, 'PistonwareKey')
local function crumb(text)
	pcall(function()
		text = tostring(text)
		for _, key in {carriedKey, rawget(shared, 'PistonwareKey')} do
			if type(key) == 'string' and key ~= '' then
				text = text:gsub((key:gsub('%p', '%%%0')), '<redacted>')
			end
		end
		local line = os.date('!%Y-%m-%dT%H:%M:%SZ')..' [loader fallback] '..text..'\n'
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
local chunk, from
for attempt = 1, 3 do
	local fetched, source = pcall(function()
		return game:HttpGet('https://raw.githubusercontent.com/themagicpiston/pistonware/refs/heads/'..loaderBranch..'/loader.lua', true)
	end)
	if fetched and type(source) == 'string' and source ~= '' and source ~= '404: Not Found' then
		local compileError
		chunk, compileError = loadstring(source, 'loader')
		if chunk then
			from = 'the '..loaderBranch..' branch'
			break
		end
		crumb('the downloaded loader.lua did not compile (attempt '..attempt..'): '..tostring(compileError))
	else
		crumb('loader.lua could not be downloaded (attempt '..attempt..'): '..tostring(source):sub(1, 200))
	end
	if attempt < 3 then task.wait(attempt) end
end
if not chunk then
	local readOk, cached = pcall(readfile, 'pistonware/loader.lua')
	if readOk and type(cached) == 'string' and cached ~= '' then
		local compileError
		chunk, compileError = loadstring(cached, 'loader')
		if chunk then
			from = 'pistonware/loader.lua'
		else
			crumb('pistonware/loader.lua did not compile: '..tostring(compileError))
		end
	else
		crumb('pistonware/loader.lua could not be read')
	end
end
if not chunk then
	crumb('no loader to run; nothing was loaded')
	return
end
crumb('running loader.lua from '..from)
local ran, runError = pcall(chunk)
crumb(ran and 'loader.lua finished' or ('loader.lua errored: '..tostring(runError)))
local hold = shared.PistonwareDodgeHold
if not ran and type(hold) == 'table' and not hold.claimed and type(hold.release) == 'function' then
	pcall(hold.release)
	crumb('released the AutoQueueDodge hold')
end
]==]

		task.spawn(function()
			local ok, err = pcall(function()
				local playersService = cloneref(game:GetService('Players'))
				local deadline = os.clock() + 120
				while not playersService.LocalPlayer and os.clock() < deadline do
					task.wait()
				end
				local localPlayer = playersService.LocalPlayer
				if not localPlayer then
					pistonwareBuffer.warn('teleport.fallback', 'no LocalPlayer; the teleport fallback is not connected')
					return
				end
				local queuedHere, stoodDown = false, false
				local connection = localPlayer.OnTeleport:Connect(function(state)
					if state == Enum.TeleportState.Failed then return end
					task.defer(function()
						if queuedHere then return end
						local standDown
						if rawget(shared, 'PistonwareTeleportQueued') or rawget(shared, 'PistonwareTeleportOwned') then
							standDown = 'main.lua has this teleport; nothing queued here'
						elseif rawget(shared, 'SlinkyIndependent') then
							standDown = 'an independent session; nothing queued here'
						else
							local abortedOk, aborted = pcall(function() return console:IsAborted() end)
							if abortedOk and aborted == true and not loaderStopped then
								standDown = 'the boot was cancelled; nothing queued here'
							end
						end
						if standDown then
							if not stoodDown then
								stoodDown = true
								pistonwareBuffer.print('teleport.fallback', standDown)
							end
							return
						end
						rawset(shared, 'PistonwareTeleportQueued', true)
						local queued, queueError = pcall(function()
							local function quote(value)
								return string.format('%q', tostring(value))
							end
							local lines = {}
							local key = rawget(shared, 'PistonwareKey')
							if type(key) == 'string' and key ~= '' then
								table.insert(lines, 'script_key = '..quote(key))
								table.insert(lines, 'rawset(shared, "PistonwareKey", '..quote(key)..')')
							end
							table.insert(lines, 'shared.PistonwareChannel = '..quote(release.channel))
							local profile = rawget(shared, 'SlinkyCustomProfile')
							if type(profile) ~= 'string' or profile == '' then
								local slinky = rawget(shared, 'slinky')
								profile = type(slinky) == 'table' and slinky.loaded and slinky.profile or nil
							end
							if type(profile) == 'string' and profile ~= '' then
								table.insert(lines, 'shared.SlinkyCustomProfile = '..quote(profile))
							end
							local branch = tostring(release.branch or 'main')
							if not branch:match('^[%w%-_%.]+$') then branch = 'main' end
							table.insert(lines, 'local loaderBranch = '..quote(branch))
							table.insert(lines, body)
							local tokenPath = 'pistonware/teleport_token_'..tostring(localPlayer.UserId)..'.txt'
							local token = tostring(game.JobId)..'-'..tostring(os.clock())..'-'..tostring(math.random(1, 2147483647))
							if pcall(writefile, tokenPath, token) then
								table.insert(lines, 1, 'do local tokenOk, tokenNow = pcall(readfile, '..quote(tokenPath)..')\n'
									..'if tokenOk and tokenNow ~= '..quote(token)..' then return end\n'
									..'pcall(writefile, '..quote(tokenPath)..', "") end')
							end
							queueTeleport(table.concat(lines, '\n'))
						end)
						if queued then
							queuedHere = true
							pistonwareBuffer.print('teleport.queued', 'main.lua did not queue this teleport; queued loader.lua instead')
						else
							rawset(shared, 'PistonwareTeleportQueued', nil)
							pistonwareBuffer.error('teleport.queue', scrub(queueError))
						end
					end)
				end)
				local stale = rawget(shared, 'PistonwareDevTeleportConnection')
				if stale and stale ~= connection then
					pcall(function() stale:Disconnect() end)
				end
				rawset(shared, 'PistonwareDevTeleportConnection', connection)
				pistonwareBuffer.print('teleport.fallback', 'connected; the loader is queued if main.lua does not take a teleport')
			end)
			if not ok then
				pistonwareBuffer.error('teleport.fallback', scrub(err))
			end
		end)
	end)
	if not fallbackOk then
		pcall(pistonwareBuffer.error, 'teleport.fallback', scrub(fallbackError))
	end
end

--[[ Decided before the folders are created, while 'did this run create the install' is still
observable. The key gate above yields, but it runs before any folder exists and its own
cancel path returns without reaching here, so freshInstall still cannot be read stale. ]]
local foldersOk, foldersError = xpcall(function()
	freshInstall = not isfolder('pistonware')
	for _, folder in {'pistonware', 'pistonware/games', 'pistonware/profiles', 'pistonware/assets', 'pistonware/libraries'} do
		if not isfolder(folder) then
			makefolder(folder)
		end
	end
end, errorTrace)
	if not foldersOk then
	stopExecution(console, 'filesystem.setup', foldersError, foldersError)
	return
	end
	markPistonwareBufferFilesystemReady()
	logger:addFile('pistonware/loader.log')
telemetry:addFile('pistonware/loader_telemetry.jsonl')

local releaseOk, releaseError = resolveRelease()
if not releaseOk then
	stopExecution(console, 'version.resolve', releaseError, errorTrace(releaseError))
	return
end
console:SetLine(('Loading %s (%s)...'):format(release.channel, release.version))

--[[ Self-repair. pistonware/bootpending_<UserId>.txt is written just before main.lua runs and
emptied by main.lua once the profile has applied, so finding it filled means this account's last
boot never finished: it stopped on an error, or hung, or the game closed on it. One file per
account, since accounts share an install, and another client still loading is not this one's
failure. This run then fetches every cached file again at the release commit, without touching
profiles: an empty manifest makes the update pass refresh them all, and with cacheReady off
nothing is trusted from disk unless it cannot be fetched (repairFallback, which main.lua also
applies to the place file). A run with no LocalPlayer after 5 s (a teleport-queued run can start
before there is one) leaves the check to a later run rather than guess at the account. ]]
local bootPendingPath
pcall(function()
	local players = cloneref(game:GetService('Players'))
	local deadline = os.clock() + 5
	while not players.LocalPlayer and os.clock() < deadline do
		task.wait()
	end
	if players.LocalPlayer then
		bootPendingPath = 'pistonware/bootpending_'..tostring(players.LocalPlayer.UserId)..'.txt'
	end
end)
local repairing = false
if bootPendingPath then
	pcall(function()
		repairing = isfile(bootPendingPath) and readfile(bootPendingPath) ~= ''
	end)
end
--[[ A repair whose release came from the marker, because the API, git refs, commit feed and tree all
failed, first checks with one request whether GitHub's raw files answer. With none there is nothing
to fetch, and the repair waits for a run that can reach GitHub. ]]
if repairing and release.fromMarker then
	local rawUp = false
	pcall(function()
		local res = httpGet(projectRawUrl('main.lua'), true)
		rawUp = not unusableBody('main.lua', res) and loadstring(res) ~= nil
	end)
	if not rawUp then
		repairing = false
		logger:warn('cache.repair', 'the last boot did not finish, but GitHub is out of reach; a later run repairs')
	end
end
if repairing then
	repairFallback = release.cacheReady == true
	release.repairFallback = repairFallback
	release.cacheReady = false
	pcall(writefile, 'pistonware/filecheck.json', '{}')
	logger:warn('cache.repair', 'the last boot did not finish; fetching every cached file again')
	console:SetLine('Repairing files after an incomplete load...')
end

--[[ Step 1: hold here until ROBLOX itself is ready. Everything after this touches game state
(or hands off to main.lua, which does), so the shared.Slinky* flags the injecting loadstring
sets have to be in place and the place has to be loaded before we move on.
Step 1b runs CONCURRENTLY with Step 1, not after it.

These two phases have nothing to do with each other: waiting on Roblox is pure dead time
(seconds of it when someone injects at the loading screen) and the update check is pure
network. Run in sequence, the boot paid for both. Started here, the update check happens
inside the wait it used to follow, and on a warm cache it is finished before Roblox is.

Nothing in updateCachedFiles touches game state, which is what made the old ordering
necessary in the first place -- it reads a GitHub tree and writes files into pistonware/.
Both folders and authentication are already behind us, so the security ordering is intact:
this still cannot start until a key has validated.

A reload skips the check only while the release marker still matches the resolved commit. The
first teleport or reinject after a push runs it once, so the cache it leaves behind -- and the
marker written at the end -- describe the same commit. ]]
local updateDone = isDeveloper or (isReload and release.cacheReady)
local cacheReconciled = false
--[[ Runs the cache update in the background. When the update is skipped, the repository tree is fetched
in the background instead (not on a reload, where Step 2b is skipped), so Step 2b reads a finished
memo rather than making a blocking api.github.com request on the boot thread. Every consumer treats
a missing tree as skipping its check. ]]
if not updateDone then
	task.spawn(function()
		local updateOk, updateError = xpcall(function()
			return updateCachedFiles(function(completed, total)
				console:SetLine('Updating files ('..completed..'/'..total..')...')
				console:SetProgress(0.4 + 0.06 * (completed / math.max(total, 1)))
			end)
		end, errorTrace)
		if not updateOk then
			stopExecution(console, 'cache.update', updateError, updateError)
		elseif updateError == true then
			cacheReconciled = true
		end
		updateDone = true
	end)
else
	if not isReload then
		task.spawn(fetchRepoTree)
	end
end

--[[ Waits up to 120 s for the game to load and for LocalPlayer. A shared.slinky still set means the old
GUI is mid-teardown (main.lua uninjects it), so the flags get a moment to settle. ]]
do
	local playersService = cloneref(game:GetService('Players'))
	local deadline = os.clock() + 120
	repeat task.wait() until game:IsLoaded() or console:IsAborted() or os.clock() > deadline
	console:SetProgress(0.24)
	repeat task.wait() until playersService.LocalPlayer or console:IsAborted() or os.clock() > deadline
	if shared.slinky then
		task.wait(0.25)
	end
	console:SetProgress(0.4)
end
phase('waiting for ROBLOX')
if console:IsAborted() or loaderStopped then deleteInstall() return end

--[[ Join the update check before anything reads a cached .lua file. Bounded for the same reason
every other join in this file is: a stalled update must cost the update, not the boot. ]]
if not updateDone then
	console:SetLine('Checking for updates...')
	joinBatch(function() return updateDone end, 60)
	console:SetLine('')
	if console:IsAborted() or loaderStopped then deleteInstall() return end
end
phase('update check')
console:SetProgress(0.46)

--[[ How many profiles the folder holds: a <name>.json each, or the <name><placeId>.txt of an older
build until guilibrary.lua has converted it. The profile of another game, <name>.<placeId>.json,
counts too: it is a profile, and the install is not new. settings.json, the old folder and the
loader's own notes in there are not profiles. ]]
local function countProfiles()
	local count = 0
	for _, path in listfiles('pistonware/profiles') do
		local name = tostring(path):gsub('\\', '/'):match('[^/]*$')
		if (name:match('%.json$') and name ~= 'settings.json') or name:match('%d%.txt$') then
			count += 1
		end
	end
	return count
end

--[[ Detect the very first run (no profile in the folder yet) BEFORE downloading, so we
know afterwards whether to show the prompts below. ]]
local firstRunProfiles = false
pcall(function()
	firstRunProfiles = countProfiles() == 0
end)

--[[ profilecheck.txt persists a prior 'No' on the first-run download prompt, and optout.txt
persists a prior 'No' (or 'Do not ask me again') on the sync prompt. Either file is enough:
both live on disk next to the other saved decisions, so a rejection still holds after a reload
or a rejoin. Whitespace is ignored on the way back in -- a trailing newline from writefile used
to fail the exact 'false' compare and ask again every reinject. ]]
local syncOptedOut = false
pcall(function()
	syncOptedOut = isfile('pistonware/optout.txt')
end)
local declinedDownload = false
pcall(function()
	if isfile('pistonware/profiles/profilecheck.txt') then
		declinedDownload = trim(readfile('pistonware/profiles/profilecheck.txt')) == 'false'
	end
end)
declinedDownload = declinedDownload or syncOptedOut

--[[ Step 2: offer the shipped configs. ]]
local wantsDownload = true
--[[ First run: asks whether to download the shipped configs. Cancelling is checked before the answer, so
it never counts as No. A timeout falls back to Yes; only an explicit No is recorded, in both
profiles/profilecheck.txt and optout.txt, so losing one file cannot bring the prompt back. ]]
if firstRunProfiles and not declinedDownload then
	console:SetProgress(0.47)
	local ok, res = pcall(function()
		return console:Ask('Would you like to download the latest config?', {
			{text = 'Yes', key = true, tooltip = 'Downloads the Blatant and Legit configs from GitHub'},
			{text = 'No', key = 'no', tooltip = 'Starts on default settings and stops asking on future runs'}
		}, 60, true)
	end)
	if console:IsAborted() then deleteInstall() return end
	wantsDownload = ok and res == true
	if ok and res == 'no' then
		declinedDownload = true
		pcall(writefile, 'pistonware/profiles/profilecheck.txt', 'false')
		pcall(writefile, 'pistonware/optout.txt', 'true')
		syncOptedOut = true
	end
end
console:SetProgress(0.53)

local downloadedConfigs = false
--[[ Downloads the shipped configs on a first run and records the fingerprint of profiles/ in
profiles/profilecommit.txt, so later sessions can tell whether profiles/ changed on GitHub since. ]]
if firstRunProfiles and not declinedDownload and wantsDownload then
	console:SetLine('Downloading configs...')
		local synced = false
		pcall(function()
			local body = fetchProfilesListing()
			if body then
				synced = downloadProfilesListing(body, nil, function(completed, total)
					console:SetLine('Downloading configs ('..completed..'/'..total..')...')
					console:SetProgress(0.53 + 0.2 * (completed / math.max(total, 1)))
			end)
		end
	end)
		if synced then
			pcall(function()
				downloadedConfigs = countProfiles() > 0
			end)
		end
	if downloadedConfigs then
		pcall(function()
			local commit = profilesFingerprint()
			if commit then
				writefile('pistonware/profiles/profilecommit.txt', commit)
			end
		end)
	end
end
--[[ Repeat the cleanup here: downloads already in flight when cancel fired can land after its wipe. ]]
if console:IsAborted() then deleteInstall() return end

--[[ Step 2b, existing installs: when profiles/ changed on GitHub since the last download or sync, offers
to replace the shipped configs with the latest ones. Only files the repository ships are fetched;
profiles the user made stay. Skipped on reinjects and teleports, and when optout.txt exists (delete
it, and a profilecheck.txt that says 'false', to be asked again), which is checked before the
fingerprint request. A stored value that is a 40-character git sha can never equal a 'p1-'
fingerprint, so it is replaced silently rather than read as a change. No and 'Do not ask me again'
are both saved to optout.txt; a timeout leaves the stored commit stale, so the prompt returns next
session.

The equipped profile is read before anything is overwritten, from the live shared.slinky first, else
settings.json (or the older <GameId>.gui.txt), and handed back through shared.SlinkyCustomProfile,
because mergeGuiState writes the repository's copy verbatim on a decode failure. A previous instance
is unloaded before the files are written, since its unload saves its in-memory config over them. The
listing and the file contents are both fetched at the tree's sha, so a sync right after a push
cannot take a stale CDN copy. ]]
if not firstRunProfiles and not declinedDownload and not isReload and not syncOptedOut then
	local latestCommit, cachedCommit
	pcall(function()
		latestCommit = profilesFingerprint()
		cachedCommit = isfile('pistonware/profiles/profilecommit.txt') and readfile('pistonware/profiles/profilecommit.txt'):gsub('%s', '') or nil
	end)

	if latestCommit and cachedCommit and #cachedCommit == 40 and cachedCommit:match('^%x+$') then
		pcall(writefile, 'pistonware/profiles/profilecommit.txt', latestCommit)
		cachedCommit = latestCommit
	end

	if latestCommit and latestCommit ~= cachedCommit then
		console:SetProgress(0.6)
		local ok, wantsSync = pcall(function()
			return console:Ask('Would you like to sync to the latest config?', {
				{text = 'Yes', key = true, tooltip = 'Replaces the shipped configs with the newer ones on GitHub'},
				{text = 'No', key = 'no', tooltip = 'Keeps the configs you have and does not ask again'}
			}, 60, false, {text = 'Do not ask me again', key = 'optout', tooltip = 'Keeps the configs you have and never asks again'})
		end)
		if console:IsAborted() then deleteInstall() return end
		if ok and (wantsSync == 'optout' or wantsSync == 'no') then
			pcall(writefile, 'pistonware/optout.txt', 'true')
			syncOptedOut = true
			declinedDownload = true
		end
		if ok and wantsSync == true then
			console:SetLine('Syncing configs...')

			local lastProfile
			pcall(function()
				local live = shared.slinky and shared.slinky.profile
				if type(live) == 'string' and live ~= '' then
					lastProfile = live
					return
				end

				local guipath, key = 'pistonware/profiles/settings.json', 'profile'
				if not isfile(guipath) then
					guipath, key = 'pistonware/profiles/'..game.GameId..'.gui.txt', 'Profile'
				end
				if not isfile(guipath) then return end
				local guidata = cloneref(game:GetService('HttpService')):JSONDecode(readfile(guipath))
				if type(guidata) == 'table' and type(guidata[key]) == 'string' and guidata[key] ~= '' then
					lastProfile = guidata[key]
				end
			end)

			pcall(function()
				if shared.slinky then
					pcall(function() shared.slinky:unload() end)
					shared.slinky = nil
				end
				local body = fetchProfilesListing()
				local treeSha = repoTree and repoTree.sha
			if body and treeSha then
				local synced = downloadProfilesListing(body, treeSha, function(completed, total)
					console:SetLine('Syncing configs ('..completed..'/'..total..')...')
					console:SetProgress(0.6 + 0.13 * (completed / math.max(total, 1)))
				end)
				if synced then
					writefile('pistonware/profiles/profilecommit.txt', latestCommit)
				else
					logger:warn('profiles.sync', 'profile sync did not complete; retrying on the next run')
				end
			end
			end)
			if console:IsAborted() then deleteInstall() return end

			if lastProfile then
				shared.SlinkyCustomProfile = lastProfile
			end
		end
	end
end
phase('config download/sync')
console:SetProgress(0.73)

--[[ Step 3: after the shipped configs download, asks which one loads by default and hands it to
main.lua's finishLoading through shared.SlinkyCustomProfile; the keys are the profile file names
without .json. No fallback: on a timeout or a headless console nothing is set, and the profile saved
in settings.json decides. ]]
if downloadedConfigs then
	local ok, choice = pcall(function()
		return console:Ask('Which config would you like to load by default?', {
			{text = 'Blatant', key = 'blatant', tooltip = 'Makes Blatant your default config: everything on, obvious'},
			{text = 'Legit', key = 'legit', tooltip = 'Makes Legit your default config: toned down to look normal'}
		}, 120, nil)
	end)
	if console:IsAborted() then deleteInstall() return end
	if ok and type(choice) == 'string' then
		shared.SlinkyCustomProfile = choice
	end
end

phase('config prompt')
console:SetProgress(0.8)
console:SetLine('Loading pistonware...')
--[[ Reveals the last couple of rows while main.lua downloads and builds the GUI, so the face
is still one row short of finished when injection actually completes. ]]
local injecting = true
--[[ Creeps the progress bar from 0.8 toward 0.93 while main.lua injects. injecting is checked again
after each wait, because a late report would land after Finish() has asked for the full face. ]]
task.spawn(function()
	local alpha = 0.8
	while injecting and alpha < 0.93 do
		task.wait(0.6)
		if not injecting then break end
		alpha += 0.02
		console:SetProgress(alpha)
	end
end)

--[[ Names this boot's pistonware/bootpending_<UserId>.txt. main.lua empties it once the profile has
applied; still filled at the next run, it means this boot never finished and that run repairs the
install. With no LocalPlayer by now the boot is not marked. ]]
if not bootPendingPath then
	pcall(function()
		local player = cloneref(game:GetService('Players')).LocalPlayer
		if player then
			bootPendingPath = 'pistonware/bootpending_'..tostring(player.UserId)..'.txt'
		end
	end)
end
shared.PistonwareBootPending = bootPendingPath
if bootPendingPath then
	pcall(writefile, bootPendingPath, tostring(os.time())..' '..tostring(release.version))
end

--[[ Runs main.lua under xpcall, so a failure shows on the console line instead of leaving the window on
'Loading pistonware...', and the buffer keeps the trace. The chunk downloadFile compiled under the
name 'main' to validate it is the one that runs. ]]
local ok, result = xpcall(function()
	local source, chunk = downloadFile('pistonware/main.lua', nil, 'main')
	local compileError
	if not chunk then
		chunk, compileError = loadstring(source, 'main')
	end
	if not chunk then
		error(compileError or 'main.lua did not compile', 0)
	end
	return chunk()
end, errorTrace)
injecting = false
phase('main.lua')
stopHoldingLogs()
--[[ Consumed only now: main.lua reads the flag itself while loading (it suppresses the 'Finished
Loading' notification on a reload). Left set it would leak into the rest of the session,
since main.lua never clears it and the next teleport/reinject sets it again anyway. ]]
shared.slinkyreload = nil
--[[ Boot is over (successfully or not) -- reinjects and later manual runs may proceed. ]]
shared.PistonwareLoaderBoot = nil

--[[ Cancelled while the GUI was already building: tear that back down too, then wipe whatever
the run wrote after cancel's first pass. ]]
if console:IsAborted() then
	if shared.slinky then
		pcall(function() shared.slinky:unload() end)
	end
	shared.SlinkyCustomProfile = nil
	deleteInstall()
	return
end

--[[ On success the release marker is written only when the cache already matched or this boot reconciled
it (or in developer mode), no cache write failed and main.lua finished the boot. Otherwise it would
vouch for files at the previous commit or files that are not there; held back, the next boot fetches
them again. ]]
if ok then
	local cacheSound = not cacheWriteFailed and not shared.PistonwareCacheWriteFailed and not shared.PistonwareBootFailed
	if (release.cacheReady or cacheReconciled or isDeveloper) and cacheSound then
		persistReleaseMarker()
	elseif not cacheSound then
		logger:warn('version.marker', 'release marker held back: a cache write did not land or the boot did not finish')
	end
	logger:info('loader.complete', 'injection succeeded', {
		channel = release.channel,
		version = release.version
	})
	console:Finish('Injected successfully.', 5)
	return result
end
--[[ Copied as well as printed: the message is long, full of executor paths, and the person
hitting it is usually being asked to report it. Done here rather than inside console:Fail so
a headless reload (which has no window to read) still leaves it on the clipboard. ]]
local failure = 'Injection failed: '..safeText(result, 3000)
local copied = pcall(function() setclipboard(failure) end)
stopExecution(console, 'main.load', result, result, failure..(copied and '\n\n(copied to clipboard)' or ''))
