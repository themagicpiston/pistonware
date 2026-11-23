local pistonwareBuffer
pcall(function()
	local env = getgenv()
	pistonwareBuffer = type(env.pistonware) == 'table' and env.pistonware.buffer or nil
end)

local function bufferError(event, message, details)
	if type(pistonwareBuffer) == 'table' and type(pistonwareBuffer.error) == 'function' then
		return pistonwareBuffer.error(event, message, details)
	end
	if shared.PistonwareDeveloper == true then warn('[pistonware] '..tostring(message)) end
end

--[[ Solara and Xeno support. Approach credit: stxvv (gitlab.com/stxvv/bedwarsdeps). Written for
pistonware from BedWars' own modules; no code from that project is included.

Works out once per injection what this executor can do, as shared.PistonwareExec for the game files
(each builds the same itself when run without this file). Every check is pcall-guarded and leaves
nothing behind.

Solara's require is written in Lua and re-runs a module instead of returning the game's copy; when
that code errors (KnitClient does), the calling thread is left at identity 2 without file calls,
gethui or CoreGui, and pcall does not prevent it. Requires go through exec.isolatedRequire, each in
its own thread; one still running at the timeout fails. Require is tried only on modules that just
build a table, never on PlayerModule (a re-run builds a second camera and control stack), and must
return the same table twice. Live (require returns the game's own modules) shows only in a filled
KnitClient.Controllers; an injection before the game fills it reads false, so the BedWars files also
set Live once Knit has started. KnitClient waits for its Services folder and is never required
without one. getnamecallmethod is trusted where hookmetamethod exists, otherwise after a one-call
pass-through test on the raw __namecall; Delta is never tested that way, since nothing may be
written to its metatable at load. ]]
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
shared.PistonwareExec = probeExecutor()
shared.PistonwareHidden = {}
local exec = shared.PistonwareExec
--[[ The executors these files were first written for (Potassium, Wave, Delta and the like) hook
functions and list connections. Where a module has a second way of working for Solara and Xeno,
this keeps those executors on the original one. It stands in for exec.Full there because none of
those modules needs Full's other parts, which depend on the place (Require) or differ between such
executors (Identity). ]]
local hookExecutor = exec.HookFunction and exec.Connections

local loadstring = function(...)
	local res, err = loadstring(...)
	if err and slinky then
		slinky:notify('Pistonware', 'Failed to load : '..err, 30, 'alert')
	end
	return res
end
local isfile = isfile or function(file)
	local suc, res = pcall(function()
		return readfile(file)
	end)
	return suc and res ~= nil and res ~= ''
end

--[[ Fetches a URL; shared.PistonwareDevHttpGet replaces it when set. game:HttpGet is used wherever the
executor has it, and its result or error comes back unchanged. request() stands in only where
HttpGet is missing or refused to this thread (Xeno has none), and then only a 2xx answer with a body
counts, so an error page is never cached as the file. Real's request answers a failure with an error
string, which fails the same check. ]]
local function pistonwareHttpGet(url, nocache, attempt)
	local adapter = shared.PistonwareDevHttpGet
	if type(adapter) == 'function' then
		return adapter(url, nocache, attempt)
	end
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
	local send = type(request) == 'function' and request or type(http_request) == 'function' and http_request
		or type(httprequest) == 'function' and httprequest
		or type(http) == 'table' and type(http.request) == 'function' and http.request
		or type(syn) == 'table' and type(syn.request) == 'function' and syn.request or nil
	if not (refused and send) then error(body, 0) end
	local response = send({Url = url, Method = 'GET'})
	local status = type(response) == 'table' and tonumber(response.StatusCode) or nil
	if type(response) ~= 'table' or response.Success == false or (status and (status < 200 or status > 299))
		or type(response.Body) ~= 'string' or response.Body == '' then
		error('GET '..tostring(url)..' failed'..(status and ' (HTTP '..status..')' or ''), 0)
	end
	return response.Body
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

--[[ Returns a pistonware file, downloading it from the GitHub repository when it is not on disk. With
shared.PistonwareDevLoadSource set, the developer loader supplies it and, told the chunk name, also
hands back the compiled chunk so loadModule does not compile the source again. An empty body is a
failed download: Real's HttpGet answers one instead of raising, and an empty file written to disk
would never be fetched again. ]]
local function downloadFile(path, func, chunkName)
	local devLoader = shared.PistonwareDevLoadSource
	if type(devLoader) == 'function' then
		local body, chunk = devLoader(path, chunkName)
		if func then return func(path) or body end
		return body, chunkName and type(chunk) == 'function' and chunk or nil
	end
	if not isfile(path) then
		local suc, res = pcall(function()
			return pistonwareHttpGet('https://raw.githubusercontent.com/themagicpiston/pistonware/main/'..select(1, path:gsub('pistonware/', '')), true)
		end)
		if not suc or type(res) ~= 'string' or res == '' or res == '404: Not Found' then
			error(suc and ('failed to download '..path) or res)
		end
		writefile(path, res)
	end
	return (func or readfile)(path)
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

--[[ Runs one module block at the raised identity. A block that throws costs only its own modules: the
error goes to the buffer and every later block still registers, the sessioninfo library other files
capture among them. main.lua pcalls this file, so an uncaught error here would stop the rest of it
silently. ]]
local run = function(func)
	local ok, err = callWithThreadFix(func)
	if not ok then
		bufferError('universal.module', err, {traceback = err})
	end
end
local queue_on_teleport = queue_on_teleport or function() end
local cloneref = cloneref or function(obj)
	return obj
end

local playersService = cloneref(game:GetService('Players'))
local replicatedStorage = cloneref(game:GetService('ReplicatedStorage'))
local runService = cloneref(game:GetService('RunService'))
local inputService = cloneref(game:GetService('UserInputService'))
local tweenService = cloneref(game:GetService('TweenService'))
local lightingService = cloneref(game:GetService('Lighting'))
local marketplaceService = cloneref(game:GetService('MarketplaceService'))
local teleportService = cloneref(game:GetService('TeleportService'))
local httpService = cloneref(game:GetService('HttpService'))
local guiService = cloneref(game:GetService('GuiService'))
local groupService = cloneref(game:GetService('GroupService'))
local textChatService = cloneref(game:GetService('TextChatService'))
local contextService = cloneref(game:GetService('ContextActionService'))
-- Guarded: at a low identity CoreGui may not come back, and this is file scope.
local coreGui = (function()
	local ok, service = pcall(function()
		return cloneref(game:GetService('CoreGui'))
	end)
	return ok and service or nil
end)()
local proxService = cloneref(game:GetService('ProximityPromptService'))

--[[ The parts of BedWars' own client code the game files need where Knit is out of reach (Solara, Xeno),
written for pistonware: approach credit stxvv (gitlab.com/stxvv/bedwarsdeps), no code from it. They
sit on exec so both BedWars files share one copy, and nothing here runs until a game file asks.

exec.Promise is the small part of roblox-ts' Promise the scripts chain on. A promise settles once,
Resolved or Rejected, every chain off it runs on a thread of its own, and a handler that returns a
promise is waited on. cancel does nothing: the request is already on its way to the server.

exec.net finds remotes by name in an @rbxts/net folder and offers the calls the game's own client
makes (SendToServer, CallServer, CallServerAsync, Connect, GetNamespace, WaitFor). @rbxts/net keeps
every remote flat in one _NetManaged folder; a namespace is only part of the name
('RewardCrate/CrateOpened'). A RemoteFunction is a CallServer remote. A RemoteEvent tagged
NetManagedAsyncFunction is CallServerAsync: the request goes up with a fresh GUID and the reply
comes back on the same remote under that GUID (rbx-net's ClientAsyncFunction). Any other RemoteEvent
is a plain event. Get errors on a name the folder does not have, as the game's GetOrThrow does;
WaitFor waits for it. exec.net.events finds Flamework's ReplicatedStorage['events-'..name] folders.

exec.loadData reads games/bedwars-data.json, the BedWars tables dumped from the game on a full
executor in sections (shared, lobby, match), read once per injection. The cached copy is used when
there is one; a missing copy is fetched now, and one dumped before this place's current version is
fetched again in the background while the old copy serves. Developer mode reads the local file only.
Each value is decoded the first time it is asked for; an instance is found again by its full name
and reads as nil when it is gone or renamed. ]]
do
	local collectionService = cloneref(game:GetService('CollectionService'))
	local httpService = cloneref(game:GetService('HttpService'))
	local replicatedStorage = cloneref(game:GetService('ReplicatedStorage'))

	local Promise = {}
	Promise.__index = Promise

	local function isPromise(value)
		return type(value) == 'table' and getmetatable(value) == Promise
	end

	function Promise.new(executor)
		local self = setmetatable({status = 'Started', values = {n = 0}, waiting = {}}, Promise)
		local function settle(status, ...)
			if self.status ~= 'Started' then return end
			self.status, self.values = status, table.pack(...)
			local waiting = self.waiting
			self.waiting = {}
			for _, thread in waiting do
				task.spawn(thread)
			end
		end
		task.spawn(function()
			local ok, err = pcall(executor, function(...)
				settle('Resolved', ...)
			end, function(...)
				settle('Rejected', ...)
			end)
			if not ok then settle('Rejected', err) end
		end)
		return self
	end

	function Promise.resolve(...)
		local values = table.pack(...)
		return Promise.new(function(resolve)
			resolve(table.unpack(values, 1, values.n))
		end)
	end

	function Promise.reject(...)
		local values = table.pack(...)
		return Promise.new(function(_, reject)
			reject(table.unpack(values, 1, values.n))
		end)
	end

	function Promise.delay(seconds)
		return Promise.new(function(resolve)
			resolve(task.wait(seconds))
		end)
	end

	function Promise:await()
		if self.status == 'Started' then
			table.insert(self.waiting, coroutine.running())
			coroutine.yield()
		end
		return self.status == 'Resolved', table.unpack(self.values, 1, self.values.n)
	end

	function Promise:expect()
		local results = table.pack(self:await())
		if not results[1] then error(results[2], 2) end
		return table.unpack(results, 2, results.n)
	end

	function Promise:andThen(onResolved, onRejected)
		return Promise.new(function(resolve, reject)
			local results = table.pack(self:await())
			local handler = if results[1] then onResolved else onRejected
			if not handler then
				(results[1] and resolve or reject)(table.unpack(results, 2, results.n))
				return
			end
			local returned = table.pack(handler(table.unpack(results, 2, results.n)))
			if returned.n == 1 and isPromise(returned[1]) then
				local chained = table.pack(returned[1]:await())
				;(chained[1] and resolve or reject)(table.unpack(chained, 2, chained.n))
			else
				resolve(table.unpack(returned, 1, returned.n))
			end
		end)
	end

	function Promise:catch(onRejected)
		return self:andThen(nil, onRejected)
	end

	function Promise:finally(handler)
		return Promise.new(function(resolve, reject)
			local results = table.pack(self:await())
			handler(results[1] and 'Resolved' or 'Rejected')
			;(results[1] and resolve or reject)(table.unpack(results, 2, results.n))
		end)
	end

	function Promise:getStatus()
		return self.status
	end

	function Promise:cancel() end

	exec.Promise = Promise

	local NAMESPACE_SEPARATOR = '/'
	local ASYNC_TIMEOUT = 60

	local function remoteObject(remote, name)
		local isFunction = remote:IsA('RemoteFunction')
		local isAsync = not isFunction and collectionService:HasTag(remote, 'NetManagedAsyncFunction')
		local object = {instance = remote, name = name}

		function object:SendToServer(...)
			if isFunction then error(name..' is a function remote; use CallServer', 2) end
			remote:FireServer(...)
		end

		function object:CallServer(...)
			if not isFunction then error(name..' is not a function remote', 2) end
			return remote:InvokeServer(...)
		end

		function object:CallServerAsync(...)
			local args = table.pack(...)
			if isFunction then
				return Promise.new(function(resolve)
					resolve(remote:InvokeServer(table.unpack(args, 1, args.n)))
				end)
			end
			if not isAsync then
				return Promise.reject(name..' is not an async function remote')
			end
			return Promise.new(function(resolve, reject)
				local id = httpService:GenerateGUID(false)
				local reply
				local connection = remote.OnClientEvent:Connect(function(replyId, result)
					if replyId == id and result ~= nil and reply == nil then
						reply = {result}
					end
				end)
				local packed = {}
				for index = 1, args.n do packed[index] = args[index] end
				remote:FireServer(id, packed)
				local deadline = os.clock() + ASYNC_TIMEOUT
				while reply == nil and os.clock() < deadline do
					task.wait()
				end
				connection:Disconnect()
				if reply then
					resolve(reply[1])
				else
					reject('Request to server timed out after '..ASYNC_TIMEOUT..' seconds')
				end
			end)
		end

		function object:Connect(callback)
			if isFunction then error(name..' is a function remote; it has no event', 2) end
			return remote.OnClientEvent:Connect(callback)
		end

		return object
	end

	exec.net = {}

	function exec.net.client(folder)
		local cache = {}
		local function find(name, timeout)
			local cached = cache[name]
			if cached and cached.instance.Parent then return cached end
			local remote = folder:FindFirstChild(name)
			if not remote and timeout then remote = folder:WaitForChild(name, timeout) end
			if not (remote and (remote:IsA('RemoteEvent') or remote:IsA('RemoteFunction'))) then
				error(name..' is not defined', 3)
			end
			cached = remoteObject(remote, name)
			cache[name] = cached
			return cached
		end
		local function view(prefix)
			local client = {}
			function client:Get(name)
				return find(prefix..name)
			end
			function client:GetNamespace(namespace)
				return view(prefix..namespace..NAMESPACE_SEPARATOR)
			end
			function client:WaitFor(name)
				return Promise.new(function(resolve)
					resolve(find(prefix..name, 60))
				end)
			end
			return client
		end
		return view('')
	end

	function exec.net.events(name)
		return replicatedStorage:FindFirstChild('events-'..name)
	end

	local DATA_FILE = 'pistonware/games/bedwars-data.json'
	local dataRaw, dataTried, dataDecoded = nil, false, {}

	local function fetchData()
		local rawUrl = shared.PistonwareRawUrl
		if type(rawUrl) ~= 'function' then return nil end
		local ok, body = pcall(pistonwareHttpGet, rawUrl('games/bedwars-data.json'), true)
		if not ok or type(body) ~= 'string' or body:sub(1, 1) ~= '{' then return nil end
		local decoded, value = pcall(httpService.JSONDecode, httpService, body)
		if not decoded or type(value) ~= 'table' or value.schema ~= 1 then return nil end
		pcall(writefile, DATA_FILE, body)
		return value
	end

	local function readData()
		if dataTried then return dataRaw end
		dataTried = true
		pcall(function()
			if isfile(DATA_FILE) then
				local value = httpService:JSONDecode(readfile(DATA_FILE))
				if type(value) == 'table' and value.schema == 1 then dataRaw = value end
			end
		end)
		if shared.PistonwareDeveloper == true then return dataRaw end
		if not dataRaw then
			dataRaw = fetchData()
		else
			local place = type(dataRaw.places) == 'table' and dataRaw.places[tostring(game.PlaceId)]
			if type(place) == 'table' and tonumber(place.placeVersion) and tonumber(place.placeVersion) < game.PlaceVersion then
				task.spawn(function()
					local fresh = fetchData()
					if fresh then
						dataRaw = fresh
						table.clear(dataDecoded)
					end
				end)
			end
		end
		return dataRaw
	end

	local function decodeKey(key)
		if type(key) ~= 'string' or key:sub(1, 1) ~= '#' then return key end
		local marker = key:sub(2, 2)
		if marker == 'n' then return tonumber(key:sub(3)) or key end
		if marker == 'e' then
			local enumName, itemName = key:match('^#eEnum%.([^%.]+)%.(.+)$')
			local ok, item = pcall(function() return Enum[enumName][itemName] end)
			return ok and item or key
		end
		return key:sub(2)
	end

	local function decodeValue(value)
		if type(value) ~= 'table' then return value end
		local tag = value['$t']
		if type(tag) == 'string' then
			local v = value.v
			if tag == 'map' then return {} end
			if tag == 'cycle' or tag == 'nil' then return nil end
			if tag == 'nan' then return 0 / 0 end
			if tag == 'inf' then return (v or 1) * math.huge end
			local ok, result = pcall(function()
				if tag == 'Color3' then return Color3.new(v[1], v[2], v[3]) end
				if tag == 'Vector3' then return Vector3.new(v[1], v[2], v[3]) end
				if tag == 'Vector2' then return Vector2.new(v[1], v[2]) end
				if tag == 'UDim2' then return UDim2.new(v[1], v[2], v[3], v[4]) end
				if tag == 'NumberRange' then return NumberRange.new(v[1], v[2]) end
				if tag == 'CFrame' then return CFrame.new(table.unpack(v)) end
				if tag == 'Enum' then
					local enumName, itemName = tostring(v):match('^Enum%.([^%.]+)%.(.+)$')
					return Enum[enumName][itemName]
				end
				if tag == 'ColorSequence' then
					local points = {}
					for _, p in v do
						table.insert(points, ColorSequenceKeypoint.new(p[1], Color3.new(p[2], p[3], p[4])))
					end
					return ColorSequence.new(points)
				end
				if tag == 'NumberSequence' then
					local points = {}
					for _, p in v do
						table.insert(points, NumberSequenceKeypoint.new(p[1], p[2], p[3]))
					end
					return NumberSequence.new(points)
				end
				if tag == 'Instance' then
					local node = game
					for part in tostring(v):gmatch('[^%.]+') do
						node = node and node:FindFirstChild(part)
					end
					return node
				end
				return nil
			end)
			return ok and result or nil
		end
		local out = {}
		for key, item in value do
			local decodedKey = decodeKey(key)
			if decodedKey ~= nil then
				out[decodedKey] = decodeValue(item)
			end
		end
		return out
	end

	function exec.loadData(section, name)
		local cacheKey = tostring(section)..'.'..tostring(name)
		if dataDecoded[cacheKey] ~= nil then return dataDecoded[cacheKey] or nil end
		local raw = readData()
		local entry = type(raw) == 'table' and type(raw[section]) == 'table' and raw[section][name]
		local value = entry ~= nil and entry ~= false and decodeValue(entry) or nil
		dataDecoded[cacheKey] = value == nil and false or value
		return value
	end
end

--[[ identifyexecutor throws on several mobile executors. Because this runs at file scope, an
unguarded call would terminate the whole game script before any module registers. main.lua
already documents the same risk for its own call; this file is loaded by BedWars users. ]]
local function executorName()
	local ok, name = pcall(function()
		return identifyexecutor and ({identifyexecutor()})[1] or nil
	end)
	return (ok and type(name) == 'string') and name or ''
end

local isnetworkowner = table.find({'AWP', 'Nihon'}, executorName()) and isnetworkowner or function()
	return true
end
local gameCamera = workspace.CurrentCamera or workspace:FindFirstChildWhichIsA('Camera')
local lplr = playersService.LocalPlayer
local assetfunction = getcustomasset

local slinky = shared.slinky
local combat = slinky.categories.Combat
local blatant = slinky.categories.Blatant
local render = slinky.categories.Render
local utility = slinky.categories.Utility
local world = slinky.categories.World
local minigames = slinky.categories.Minigames
local legit = slinky.legit
local tween = slinky.libraries.tween
local targetinfo = slinky.libraries.targetinfo
local getfontsize = slinky.libraries.getfontsize
local getcustomasset = slinky.libraries.getcustomasset

local targetStrafeVector, spiderShift, waypointFolder
local spider = {enabled = false}
local phase = {enabled = false}

--[[ The overlays' look, for the boxes this file draws on the HUD: Target Info's card. A near-black
card, mostly opaque, with a faint white edge and rounded corners; text in the Mod Overlay's Inter,
values bright and labels in a muted grey. The orange is kept only for what is lit (a pressed key). ]]
local loaderStyle = {
	Orange = Color3.fromRGB(240, 122, 31),
	Text = Color3.fromRGB(240, 240, 240),
	SubText = Color3.fromRGB(150, 150, 150),
	Pressed = Color3.fromRGB(20, 20, 20),
	Background = Color3.fromRGB(16, 16, 16),
	Transparency = 0.15,
	Edge = Color3.new(1, 1, 1),
	EdgeTransparency = 0.9
}
-- The background and the edge as colour-slider defaults, so a box with colour options starts on them.
loaderStyle.Hue, loaderStyle.Sat, loaderStyle.Value = loaderStyle.Background:ToHSV()
loaderStyle.EdgeHue, loaderStyle.EdgeSat, loaderStyle.EdgeValue = loaderStyle.Edge:ToHSV()
loaderStyle.SubHex = '#'..loaderStyle.SubText:ToHex()

--[[ The look before this one: the loader's near-black with a tenth of its orange, at 70%, and a soft
orange edge at 45%. A profile saves every option, so a new default never reaches anyone who saved
the old one; a colour still on exactly the old default is drawn with today's instead. ]]
local LEGACY_BACKGROUND = Color3.fromRGB(10, 10, 10):Lerp(loaderStyle.Orange, 0.1)
function loaderStyle.isLegacy(hue, sat, val, opacity, oldColor, oldOpacity)
	local h, s, v = oldColor:ToHSV()
	return math.abs(hue - h) < 0.01 and math.abs(sat - s) < 0.01 and math.abs(val - v) < 0.01
		and math.abs(opacity - oldOpacity) < 0.01
end
function loaderStyle.background(hue, sat, val, opacity)
	if loaderStyle.isLegacy(hue, sat, val, opacity, LEGACY_BACKGROUND, 0.7) then
		return loaderStyle.Background, 1 - loaderStyle.Transparency
	end
	return Color3.fromHSV(hue, sat, val), opacity
end
function loaderStyle.edge(hue, sat, val, opacity)
	if loaderStyle.isLegacy(hue, sat, val, opacity, loaderStyle.Orange, 0.45) then
		return loaderStyle.Edge, 1 - loaderStyle.EdgeTransparency
	end
	return Color3.fromHSV(hue, sat, val), opacity
end
-- A background colour option's colour and opacity as drawn, for code that reads the option directly.
function loaderStyle.colorOf(option)
	return loaderStyle.background(option.hue, option.sat, option.value, option.opacity)
end

-- Props for a box's background colour option, defaulting to the card. Its Function is handed the
-- colour as drawn, so an old saved default arrives as the card.
function loaderStyle.backgroundOption(props)
	props.hue, props.sat, props.value = loaderStyle.Hue, loaderStyle.Sat, loaderStyle.Value
	props.opacity = 1 - loaderStyle.Transparency
	local apply = props.changed
	if apply then
		props.changed = function(hue, sat, val, opacity, ...)
			local colour, alpha = loaderStyle.background(hue, sat, val, opacity)
			local h, s, v = colour:ToHSV()
			return apply(h, s, v, alpha, ...)
		end
	end
	return props
end

function loaderStyle.box(obj, radius)
	obj.BackgroundColor3 = loaderStyle.Background
	obj.BackgroundTransparency = loaderStyle.Transparency
	obj.BorderSizePixel = 0
	local corner = Instance.new('UICorner')
	corner.CornerRadius = radius or UDim.new(0, 12)
	corner.Parent = obj
	local stroke = Instance.new('UIStroke')
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Color = loaderStyle.Edge
	stroke.Thickness = 1
	stroke.Transparency = loaderStyle.EdgeTransparency
	stroke.Parent = obj
	return stroke, corner
end

-- The border follows a box's Color option: at no opacity the box is bare text, without an outline.
function loaderStyle.border(obj, opacity)
	local stroke = obj:FindFirstChildOfClass('UIStroke')
	if stroke then
		stroke.Enabled = opacity > 0
	end
end

-- Inter through the font registry, so the label follows it if it finishes loading late.
function loaderStyle.text(label, role)
	label.TextColor3 = loaderStyle.Text
	label.TextStrokeTransparency = 1
	local fonts = slinky.libraries.fonts
	if fonts and fonts.track then
		fonts.track(label, role or 'Medium')
	end
end

-- A reading with its unit after it in the secondary grey ('60 FPS'), for RichText labels.
function loaderStyle.unit(value, unit)
	return value..' <font color="'..loaderStyle.SubHex..'">'..unit..'</font>'
end

-- One Legit HUD reading (FPS, Ping, Clock...): a card filling its widget, the value centred on it.
function loaderStyle.reading(parent, text)
	local label = Instance.new('TextLabel')
	label.Size = UDim2.fromScale(1, 1)
	label.TextSize = 15
	label.RichText = true
	label.Text = text
	loaderStyle.box(label)
	loaderStyle.text(label, 'SemiBold')
	label.Parent = parent
	return label
end

local function calculateMoveVector(vec)
	local c, s
	local _, _, _, R00, R01, R02, _, _, R12, _, _, R22 = gameCamera.CFrame:GetComponents()
	if R12 < 1 and R12 > -1 then
		c = R22
		s = R02
	else
		c = R00
		s = -R01 * math.sign(R12)
	end
	vec = Vector3.new((c * vec.X + s * vec.Z), 0, (c * vec.Z - s * vec.X)) / math.sqrt(c * c + s * s)
	return vec.Unit == vec.Unit and vec.Unit or Vector3.zero
end

local friendNames, targetNames = {}, {}
local targetStateCacheDirty = true

local function rebuildTargetStateCaches()
	table.clear(friendNames)
	table.clear(targetNames)
	local friends = slinky.categories.Friends
	local targets = slinky.categories.Targets
	if friends and friends.active then
		for _, name in friends.active do
			friendNames[name] = true
		end
	end
	if targets and targets.active then
		for _, name in targets.active do
			targetNames[name] = true
		end
	end
	targetStateCacheDirty = false
end

local function ensureTargetStateCaches()
	if targetStateCacheDirty then
		rebuildTargetStateCaches()
	end
end

local function isFriend(plr, recolor)
	ensureTargetStateCaches()
	if slinky.categories.Friends.options['Use friends'].enabled then
		local friend = friendNames[plr.Name] and true
		if recolor then
			friend = friend and slinky.categories.Friends.options['Recolor visuals'].enabled
		end
		return friend
	end
	return nil
end

local function isTarget(plr)
	ensureTargetStateCaches()
	return targetNames[plr.Name] and true
end

--[[ Is Pistonware's own menu open. The GUI publishes it as slinky.ClickGuiOpen, a plain
field: on ThreadFix executors the menu sits under gethui/CoreGui, and reading the
Instance from a module loop (a thread a profile apply or a GUI click started, without
the raised identity) throws and takes the loop down with it. The Instance read is only
the fallback for a cached GUI that predates the field, and a failed read counts as
closed. ]]
local function clickGuiOpen()
	local open = slinky.menuOpen
	if open ~= nil then return open == true end
	if slinky.threadFix then pcall(setthreadidentity, 8) end
	local ok, visible = pcall(function()
		return slinky.gui.ScaledGui.ClickGui.Visible
	end)
	return ok and visible == true
end

--[[ Whether a click at the mouse would reach the world: false over an active GUI in PlayerGui or
CoreGui, while the menu is open, or while a text box has focus. CoreGui can be missing or refuse the
read from a module thread without the raised identity (Solara, Xeno); there the read is guarded and
only PlayerGui counts when it fails. ]]
local function canClick()
	local mousepos = (inputService:GetMouseLocation() - guiService:GetGuiInset())
	for _, v in lplr.PlayerGui:GetGuiObjectsAtPosition(mousepos.X, mousepos.Y) do
		local obj = v:FindFirstAncestorOfClass('ScreenGui')
		if v.Active and v.Visible and obj and obj.Enabled then
			return false
		end
	end
	if hookExecutor then
		for _, v in coreGui:GetGuiObjectsAtPosition(mousepos.X, mousepos.Y) do
			local obj = v:FindFirstAncestorOfClass('ScreenGui')
			if v.Active and v.Visible and obj and obj.Enabled then
				return false
			end
		end
	elseif coreGui then
		local ok, covered = pcall(function()
			for _, v in coreGui:GetGuiObjectsAtPosition(mousepos.X, mousepos.Y) do
				local obj = v:FindFirstAncestorOfClass('ScreenGui')
				if v.Active and v.Visible and obj and obj.Enabled then
					return true
				end
			end
			return false
		end)
		if ok and covered then
			return false
		end
	end
	return (not clickGuiOpen()) and (not inputService:GetFocusedTextBox())
end

--[[ Whether Roblox has the window focus, for the modules that send real mouse clicks. The check
is isrbxactive or iswindowactive, whichever the executor has; with neither the window is taken as
focused instead of calling nil. A check that throws counts as not focused, so no click is sent
while it cannot tell. ]]
local function windowActive()
	local check = isrbxactive or iswindowactive
	if type(check) ~= 'function' then return true end
	local ok, active = pcall(check)
	return ok and active
end

local function getTableSize(tab)
	local ind = 0
	for _ in tab do ind += 1 end
	return ind
end

--[[ Setting FilterDescendantsInstances copies the whole list into the engine. The filters rebuilt
every physics step (the camera and every character in the server) are almost always the list the
step before set, so a list is only handed over when an entry differs from the last one set on
those params. ]]
local appliedFilters = setmetatable({}, {__mode = 'k'})
local function setFilter(params, list)
	local last = appliedFilters[params]
	if last and #last == #list then
		local same = true
		for i = 1, #list do
			if last[i] ~= list[i] then
				same = false
				break
			end
		end
		if same then return end
	end
	params.FilterDescendantsInstances = list
	appliedFilters[params] = list
end

local function ensureSessionInfo()
	local current = slinky.libraries.sessioninfo
	if type(current) == 'table' and type(current.Objects) == 'table' and type(current.AddItem) == 'function' then
		return current
	end

	local session = {Objects = {}}
	function session:AddItem(name, startvalue, func, saved)
		func = func or function(val) return val end
		saved = saved == nil or saved
		self.Objects[name] = {
			Function = func,
			Saved = saved,
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
	slinky.libraries.sessioninfo = session
	return session
end

ensureSessionInfo()

local function getTool()
	return lplr.Character and lplr.Character:FindFirstChildWhichIsA('Tool', true) or nil
end

local function notif(...)
	return slinky:notify(...)
end

local function removeTags(str)
	str = str:gsub('<br%s*/>', '\n')
	return (str:gsub('<[^<>]->', ''))
end

local function rakNetCheck(module)
	if not (raknet and raknet.add_send_hook and pcall(raknet.add_send_hook, function() end)) then
		notif(module, 'This feature requires raknet! (risky feature, please do not use on mains.)', 10, 'warning')
		return false
	end

	return true
end

local visited, attempted, tpSwitch = {}, {}, false
local serverPageCache, serverPageInflight = {}, {}

local function serverPageKey(pointer, filter)
	return tostring(game.PlaceId)..'|'..tostring(filter or 'Descending')..'|'..tostring(pointer or '')
end

local function recordServerCache(key, state)
	local telemetry = shared.PistonwareDevTelemetry
	if type(telemetry) == 'table' and type(telemetry.cache) == 'function' then
		telemetry.cache('server-hop/'..key, state)
	end
end

local function getServerPage(pointer, filter)
	local key = serverPageKey(pointer, filter)
	local now = tick()
	local cached = serverPageCache[key]
	if cached and cached.expires > now then
		recordServerCache(key, 'hit')
		return cached.data, cached.body
	end

	local waiting = serverPageInflight[key]
	if waiting then
		local deadline = now + 10
		while not waiting.done and tick() < deadline do
			task.wait(0.05)
		end
		if waiting.done and waiting.data then
			recordServerCache(key, 'joined')
			return waiting.data, waiting.body
		end
		recordServerCache(key, 'timeout')
		return nil, nil
	end

	waiting = {done = false}
	serverPageInflight[key] = waiting
	recordServerCache(key, 'miss')
	local url = 'https://games.roblox.com/v1/games/'..game.PlaceId..'/servers/Public?sortOrder='..(filter == 'Ascending' and 1 or 2)..'&excludeFullGames=true&limit=100'..(pointer and '&cursor='..pointer or '')
	local requestOk, body = pcall(function()
		return pistonwareHttpGet(url)
	end)
	local parseOk, data = false, nil
	if requestOk then
		parseOk, data = pcall(function()
			return httpService:JSONDecode(body)
		end)
	end
	if parseOk and type(data) == 'table' and type(data.data) == 'table' then
		waiting.data, waiting.body = data, body
		serverPageCache[key] = {data = data, body = body, expires = tick() + 60}
	end
	waiting.done = true
	serverPageInflight[key] = nil
	if waiting.data then
		return waiting.data, waiting.body
	end
	return nil, nil
end

local function serverHop(pointer, filter)
	visited = shared.slinkyserverhoplist and shared.slinkyserverhoplist:split('/') or {}
	if not table.find(visited, game.JobId) then
		table.insert(visited, game.JobId)
	end
	if not pointer then
		notif('Pistonware', 'Searching for an available server.', 2)
	end

	local data = getServerPage(pointer, filter)
	if data and data.data then
		for _, v in data.data do
			if tonumber(v.playing) < playersService.MaxPlayers and not table.find(visited, v.id) and not table.find(attempted, v.id) then
				table.insert(attempted, v.id)

				notif('Pistonware', 'Found! Teleporting.', 5)
				teleportService:TeleportToPlaceInstance(game.PlaceId, v.id)
				return
			end
		end

		if data.nextPageCursor then
			serverHop(data.nextPageCursor, filter)
		else
			notif('Pistonware', 'Failed to find an available server.', 5, 'warning')
		end
	else
		notif('Pistonware', 'Failed to grab servers. ('..(data and data.errors[1].message or 'no data')..')', 5, 'warning')
	end
end

slinky:clean(lplr.OnTeleport:Connect(function()
	if not tpSwitch then
		tpSwitch = true
		queue_on_teleport("shared.slinkyserverhoplist = '"..table.concat(visited, '/').."'\nshared.slinkyserverhopprevious = '"..game.JobId.."'")
	end
end))

slinky:clean(function()
	table.clear(serverPageCache)
	table.clear(serverPageInflight)
end)

local frictionTable, oldfrict, entitylib = {}, {}
local function updateVelocity()
	if getTableSize(frictionTable) > 0 then
		if entitylib.isAlive then
			for _, v in entitylib.character.Character:GetChildren() do
				if v:IsA('BasePart') and v.Name ~= 'HumanoidRootPart' and not oldfrict[v] then
					oldfrict[v] = v.CustomPhysicalProperties or 'none'
					v.CustomPhysicalProperties = PhysicalProperties.new(0.0001, 0.2, 0.5, 1, 1)
				end
			end
		end
	else
		for i, v in oldfrict do
			i.CustomPhysicalProperties = v ~= 'none' and v or nil
		end
		table.clear(oldfrict)
	end
end

local function motorMove(target, cf)
	local part = Instance.new('Part')
	part.Anchored = true
	part.Parent = workspace
	local motor = Instance.new('Motor6D')
	motor.Part0 = target
	motor.Part1 = part
	motor.C1 = cf
	motor.Parent = part
	task.delay(0, part.Destroy, part)
end

local function loadModule(path, name)
	local source, chunk = downloadFile(path, nil, name)
	chunk = chunk or loadstring(source, name)
	return chunk and chunk()
end

local prediction = loadModule('pistonware/libraries/prediction.lua', 'prediction')
entitylib = loadModule('pistonware/libraries/entity.lua', 'entitylibrary')
if not prediction or not entitylib then return end
-- Name tags that modules put on players (GAME STAFF): customtags[player name] = a list of {text, color}.
local tags = {customtags = {}}
-- Those tags as the text in front of a name, coloured when rich.
function tags:prefix(plr, rich)
	local list = self.customtags[plr.Name]
	if not list then return '' end
	local text = ''
	for _, v in list do
		text = text..(rich and '<font color="#'..v.color:ToHex()..'">['..v.text..']</font>' or '['..removeTags(v.text)..']')..' '
	end
	return text
end
slinky:clean(function()
	table.clear(tags.customtags)
end)
slinky.libraries.entity = entitylib
slinky.libraries.tags = tags
slinky.libraries.prediction = prediction
slinky.libraries.auraanims = {
	Normal = {
		{CFrame = CFrame.new(-0.17, -0.14, -0.12) * CFrame.Angles(math.rad(-53), math.rad(50), math.rad(-64)), Time = 0.1},
		{CFrame = CFrame.new(-0.55, -0.59, -0.1) * CFrame.Angles(math.rad(-161), math.rad(54), math.rad(-6)), Time = 0.08},
		{CFrame = CFrame.new(-0.62, -0.68, -0.07) * CFrame.Angles(math.rad(-167), math.rad(47), math.rad(-1)), Time = 0.03},
		{CFrame = CFrame.new(-0.56, -0.86, 0.23) * CFrame.Angles(math.rad(-167), math.rad(49), math.rad(-1)), Time = 0.03}
	},
	Random = {},
	['Horizontal Spin'] = {
		{CFrame = CFrame.Angles(math.rad(-10), math.rad(-90), math.rad(-80)), Time = 0.12},
		{CFrame = CFrame.Angles(math.rad(-10), math.rad(180), math.rad(-80)), Time = 0.12},
		{CFrame = CFrame.Angles(math.rad(-10), math.rad(90), math.rad(-80)), Time = 0.12},
		{CFrame = CFrame.Angles(math.rad(-10), 0, math.rad(-80)), Time = 0.12}
	},
	['Vertical Spin'] = {
		{CFrame = CFrame.Angles(math.rad(-90), 0, math.rad(15)), Time = 0.12},
		{CFrame = CFrame.Angles(math.rad(180), 0, math.rad(15)), Time = 0.12},
		{CFrame = CFrame.Angles(math.rad(90), 0, math.rad(15)), Time = 0.12},
		{CFrame = CFrame.Angles(0, 0, math.rad(15)), Time = 0.12}
	},
	Exhibition = {
		{CFrame = CFrame.new(0.69, -0.7, 0.6) * CFrame.Angles(math.rad(-30), math.rad(50), math.rad(-90)), Time = 0.1},
		{CFrame = CFrame.new(0.7, -0.71, 0.59) * CFrame.Angles(math.rad(-84), math.rad(50), math.rad(-38)), Time = 0.2}
	},
	['Exhibition Old'] = {
		{CFrame = CFrame.new(0.69, -0.7, 0.6) * CFrame.Angles(math.rad(-30), math.rad(50), math.rad(-90)), Time = 0.15},
		{CFrame = CFrame.new(0.69, -0.7, 0.6) * CFrame.Angles(math.rad(-30), math.rad(50), math.rad(-90)), Time = 0.05},
		{CFrame = CFrame.new(0.7, -0.71, 0.59) * CFrame.Angles(math.rad(-84), math.rad(50), math.rad(-38)), Time = 0.1},
		{CFrame = CFrame.new(0.7, -0.71, 0.59) * CFrame.Angles(math.rad(-84), math.rad(50), math.rad(-38)), Time = 0.05},
		{CFrame = CFrame.new(0.63, -0.1, 1.37) * CFrame.Angles(math.rad(-84), math.rad(50), math.rad(-38)), Time = 0.15}
	}
}

local speedMethods
local speedMethodList = {'Velocity'}
speedMethods = {
	Velocity = function(options, moveDirection)
		local root = entitylib.character.RootPart
		root.AssemblyLinearVelocity = (moveDirection * options.Value.value) + Vector3.new(0, root.AssemblyLinearVelocity.Y, 0)
	end,
	Impulse = function(options, moveDirection)
		local root = entitylib.character.RootPart
		local diff = ((moveDirection * options.Value.value) - root.AssemblyLinearVelocity) * Vector3.new(1, 0, 1)
		if diff.Magnitude > (moveDirection == Vector3.zero and 10 or 2) then
			root:ApplyImpulse(diff * root.AssemblyMass)
		end
	end,
	CFrame = function(options, moveDirection, dt)
		local root = entitylib.character.RootPart
		local dest = (moveDirection * math.max(options.Value.value - entitylib.character.Humanoid.WalkSpeed, 0) * dt)
		if options.WallCheck.enabled then
			options.rayCheck.FilterDescendantsInstances = {lplr.Character, gameCamera}
			options.rayCheck.CollisionGroup = root.CollisionGroup
			local ray = workspace:Raycast(root.Position, dest, options.rayCheck)
			if ray then
				dest = ((ray.Position + ray.Normal) - root.Position)
			end
		end
		root.CFrame += dest
	end,
	TP = function(options, moveDirection)
		if options.TPTiming < tick() then
			options.TPTiming = tick() + options.TPFrequency.value
			speedMethods.CFrame(options, moveDirection, 1)
		end
	end,
	WalkSpeed = function(options)
		if not options.WalkSpeed then options.WalkSpeed = entitylib.character.Humanoid.WalkSpeed end
		entitylib.character.Humanoid.WalkSpeed = options.Value.value
	end,
	Pulse = function(options, moveDirection)
		local root = entitylib.character.RootPart
		local dt = math.max(options.Value.value - entitylib.character.Humanoid.WalkSpeed, 0)
		dt = dt * (1 - math.min((tick() % (options.PulseLength.value + options.PulseDelay.value)) / options.PulseLength.value, 1))
		root.AssemblyLinearVelocity = (moveDirection * (entitylib.character.Humanoid.WalkSpeed + dt)) + Vector3.new(0, root.AssemblyLinearVelocity.Y, 0)
	end
}
for name in speedMethods do
	if not table.find(speedMethodList, name) then
		table.insert(speedMethodList, name)
	end
end

run(function()
	entitylib.getUpdateConnections = function(ent)
		local hum = ent.Humanoid
		return {
			hum:GetPropertyChangedSignal('Health'),
			hum:GetPropertyChangedSignal('MaxHealth')
		}
	end

	entitylib.getEntityState = function(ent)
		local friend = ent.Player and isFriend(ent.Player) or nil
		local target = ent.Player and isTarget(ent.Player) or nil
		return entitylib.targetCheck(ent), friend, target
	end

	entitylib.targetCheck = function(ent)
		if ent.TeamCheck then
			return ent:TeamCheck()
		end
		if ent.NPC then return true end
		if isFriend(ent.Player) then return false end
		if slinky.categories.Main.options['Teams by server'].enabled then
			if not lplr.Team then return true end
			if not ent.Player.Team then return true end
			if ent.Player.Team ~= lplr.Team then return true end
			return #ent.Player.Team:GetPlayers() == #playersService:GetPlayers()
		end
		return true
	end
	entitylib.refresh()

	entitylib.getEntityColor = function(ent)
		ent = ent.Player
		if not (ent and slinky.categories.Main.options['Use team color'].enabled) then return end
		if isFriend(ent, true) then
			return Color3.fromHSV(slinky.categories.Friends.options['Friends color'].hue, slinky.categories.Friends.options['Friends color'].sat, slinky.categories.Friends.options['Friends color'].value)
		end
		return tostring(ent.TeamColor) ~= 'White' and ent.TeamColor.Color or nil
	end

	slinky:clean(function()
		entitylib.kill()
		entitylib = nil
	end)
	slinky:clean(slinky.categories.Friends.update.Event:Connect(function()
		targetStateCacheDirty = true
		entitylib.refresh()
	end))
	slinky:clean(slinky.categories.Targets.update.Event:Connect(function()
		targetStateCacheDirty = true
		entitylib.refresh()
	end))
	slinky:clean(entitylib.Events.LocalAdded:Connect(updateVelocity))
	slinky:clean(workspace:GetPropertyChangedSignal('CurrentCamera'):Connect(function()
		gameCamera = workspace.CurrentCamera or workspace:FindFirstChildWhichIsA('Camera')
	end))
end)

entitylib.start()
--[[ AimAssist
Pulls your aim towards the enemy nearest the mouse inside the FOV circle, optionally only while you
hold right-click. A speed from the range is held for a random 0.25-0.6 s before a new one is rolled:
rolled every frame it would average out to the middle of the range, held it visibly speeds up and
eases off the way a hand does. Without mousemoverel the camera is turned directly by the same share
of the yaw and pitch gap; the default camera module carries on from Camera.CFrame's look each frame,
so the pull builds up the same way. ]]
run(function()
	local aimAssist
	local targets
	local part
	local fov
	local speed
	local circleColor
	local circleTransparency
	local circleFilled
	local circleThickness
	local circleObject
	local rightClick
	local showTarget
	local moveConst = Vector2.new(1, 0.77) * math.rad(0.5)
	local speedRoll, speedRollAt = 0, 0

	local function aimSpeed()
		local now = os.clock()
		if now >= speedRollAt then
			speedRoll = speed:random()
			speedRollAt = now + 0.25 + math.random() * 0.35
		end
		return speedRoll
	end

	local function wrapAngle(num)
		num = num % math.pi
		num -= num >= (math.pi / 2) and math.pi or 0
		num += num < -(math.pi / 2) and math.pi or 0
		return num
	end

	local function turnCamera(diffYaw, diffPitch, share)
		local look = gameCamera.CFrame.LookVector
		local yaw = math.atan2(look.X, look.Z) - diffYaw * share
		local pitch = math.clamp(math.asin(look.Y) - diffPitch * share, -1.5, 1.5)
		local position = gameCamera.CFrame.Position
		local direction = Vector3.new(math.cos(pitch) * math.sin(yaw), math.sin(pitch), math.cos(pitch) * math.cos(yaw))
		gameCamera.CFrame = CFrame.lookAt(position, position + direction)
	end

	aimAssist = combat:module('AimAssist', {
		info = function()
			if not speed then return nil end
			local low, high = speed.min, speed.max
			return low == high and tostring(low) or low..'-'..high
		end,
		toggled = function(on)
			if circleObject then
				circleObject.Visible = on and not clickGuiOpen()
			end
	
			if on then
				local ent
				local rightClicked = not rightClick.enabled or inputService:IsMouseButtonPressed(1)
				aimAssist:clean(runService.RenderStepped:Connect(function(dt)
					if circleObject then
						circleObject.Position = inputService:GetMouseLocation()
						local show = not clickGuiOpen()
						if circleObject.Visible ~= show then circleObject.Visible = show end
					end
	
					if rightClicked and not clickGuiOpen() then
						ent = entitylib.EntityMouse({
							Range = fov.value,
							Part = part.value,
							Players = targets.players.enabled,
							NPCs = targets.npcs.enabled,
							Wallcheck = targets.walls.enabled,
							Origin = gameCamera.CFrame.Position
						})
	
						if ent then
							local facing = gameCamera.CFrame.LookVector
							local new = (ent[part.value].Position - gameCamera.CFrame.Position).Unit
							new = new == new and new or Vector3.zero
	
							if showTarget.enabled then
								targetinfo.Targets[ent] = tick() + 1
							end
	
							if new ~= Vector3.zero then
								local diffYaw = wrapAngle(math.atan2(facing.X, facing.Z) - math.atan2(new.X, new.Z))
								local diffPitch = math.asin(facing.Y) - math.asin(new.Y)
								local angle = Vector2.new(diffYaw, diffPitch) // (moveConst * UserSettings():GetService('UserGameSettings').MouseSensitivity)
	
								local share = math.min(aimSpeed() * dt, 1)
								if exec.MouseMove then
									angle *= share
									mousemoverel(angle.X, angle.Y)
								else
									turnCamera(diffYaw, diffPitch, share)
								end
							end
						end
					end
				end))
	
				if rightClick.enabled then
					aimAssist:clean(inputService.InputBegan:Connect(function(input)
						if input.UserInputType == Enum.UserInputType.MouseButton2 then
							ent = nil
							rightClicked = true
						end
					end))
	
					aimAssist:clean(inputService.InputEnded:Connect(function(input)
						if input.UserInputType == Enum.UserInputType.MouseButton2 then
							rightClicked = false
						end
					end))
				end
			end
		end,
		about = 'Pulls your aim towards nearby enemies.\nSet pull speed, FOV size, head or body, and right-click only.'
	})
	aimAssist:divider('Aim')
	speed = aimAssist:range('Speed', {
		label = 'Horizontal speed',
		min = 0,
		max = 30,
		defaultMin = 15,
		defaultMax = 15,
		about = 'How hard it pulls. Set a range and the pull varies within it.'
	})
	aimAssist:divider('Target')
	fov = aimAssist:slider('FOV', {
		min = 0,
		max = 1000,
		default = 100,
		changed = function(val)
			if circleObject then
				circleObject.Radius = val
			end
		end
	})
	aimAssist:divider('Conditions')
	targets = aimAssist:targets({players = true})
	aimAssist:divider('Extras')
	part = aimAssist:dropdown('Part', {
		choices = {'RootPart', 'Head'}
	})
	aimAssist:toggle('Range Circle', {
		changed = function(callback)
			if callback then
				circleObject = Drawing.new('Circle')
				circleObject.Filled = circleFilled.enabled
				circleObject.Color = Color3.fromHSV(circleColor.hue, circleColor.sat, circleColor.value)
				circleObject.Position = slinky.gui.AbsoluteSize / 2
				circleObject.Radius = fov.value
				circleObject.NumSides = 100
				circleObject.Thickness = circleThickness and circleThickness.value or 1
				circleObject.Transparency = 1 - circleTransparency.value
				circleObject.Visible = aimAssist.enabled and not clickGuiOpen()
			else
				pcall(function()
					circleObject.Visible = false
					circleObject:Remove()
				end)
				circleObject = nil
			end
			circleColor.row.Visible = callback
			circleTransparency.row.Visible = callback
			circleFilled.row.Visible = callback
			if circleThickness then
				circleThickness.row.Visible = callback
			end
		end
	})
	circleColor = aimAssist:color('Circle Color', {
		changed = function(hue, sat, val)
			if circleObject then
				circleObject.Color = Color3.fromHSV(hue, sat, val)
			end
		end,
		sub = true,
		visible = false
	})
	circleTransparency = aimAssist:slider('Transparency', {
		min = 0,
		max = 1,
		decimal = 10,
		default = 0.5,
		changed = function(val)
			if circleObject then
				circleObject.Transparency = 1 - val
			end
		end,
		sub = true,
		visible = false
	})
	circleFilled = aimAssist:toggle('Circle Filled', {
		changed = function(callback)
			if circleObject then
				circleObject.Filled = callback
			end
		end,
		sub = true,
		visible = false
	})
	circleThickness = aimAssist:slider('Circle Thickness', {
		min = 1,
		max = 10,
		default = 1,
		changed = function(val)
			if circleObject then
				circleObject.Thickness = val
			end
		end,
		sub = true,
		visible = false
	})
	rightClick = aimAssist:toggle('Require right click', {
		changed = function()
			if aimAssist.enabled then
				aimAssist:flip()
				aimAssist:flip()
			end
		end
	})
	showTarget = aimAssist:toggle('Show target info')
end)
	
--[[ AutoClicker
Clicks at a speed from the CPS range: swings the held tool while you hold left-click, or sends real
left or right clicks. Click and RightClick are offered only where the executor has mouse1click and
mouse2click. ]]
run(function()
	local autoClicker
	local mode
	local cps
	
	autoClicker = combat:module('AutoClicker', {
		info = function()
			if not cps then return nil end
			local low, high = cps.min, cps.max
			return (low == high and tostring(low) or low..'-'..high)..' cps'
		end,
		toggled = function(on)
			if on then
				repeat
					if mode.value == 'Tool' then
						local tool = getTool()
						if tool and inputService:IsMouseButtonPressed(0) then
							tool:Activate()
						end
					else
						if mouse1click and windowActive() then
							if not clickGuiOpen() then
								local click = mode.value == 'Click' and mouse1click or mouse2click
								if click then
									click()
								end
							end
						end
					end
	
					task.wait(1 / cps.random())
				until not autoClicker.enabled
			end
		end,
		about = 'Clicks for you at the speed you set.\nSwings your tool while you hold left-click, or clicks nonstop.'
	})
	cps = autoClicker:range('CPS', {
		label = 'Target CPS',
		min = 1,
		max = 20,
		defaultMin = 8,
		defaultMax = 12
	})
	autoClicker:divider('Extras')
	local modes = {'Tool'}
	if type(mouse1click) == 'function' then
		table.insert(modes, 'Click')
		if type(mouse2click) == 'function' then
			table.insert(modes, 'RightClick')
		end
	end
	mode = autoClicker:dropdown('Mode', {
		choices = modes,
		about = 'Tool - Automatically uses roblox tools (eg. swords)\nClick - Left click\nRightClick - Right click'
	})
end)
	
--[[ Reach
Lets you hit enemies from further away. Set the extra distance, who it works on, and how often it
applies. ]]
run(function()
	local reach
	local targets
	local mode
	local amount
	local chance
	local overlay = OverlapParams.new()
	overlay.FilterType = Enum.RaycastFilterType.Include
	local entityFilter = {}
	local reachRandom = Random.new()
	local modified = {}
	
	reach = combat:module('Reach', {
		info = function()
			return amount and tostring(amount.value) or nil
		end,
		toggled = function(on)
			if on then
				repeat
					local tool = getTool()
					tool = tool and tool:FindFirstChildWhichIsA('TouchTransmitter', true)
					if tool then
						if mode.value == 'TouchInterest' then
							table.clear(entityFilter)
							for _, v in entitylib.List do
								if v.Targetable then
									if not targets.players.enabled and v.Player then continue end
									if not targets.npcs.enabled and v.NPC then continue end
								entityFilter[#entityFilter + 1] = v.Character
								end
							end
			
							overlay.FilterDescendantsInstances = entityFilter
							local parts = workspace:GetPartBoundsInBox(tool.Parent.CFrame * CFrame.new(0, 0, amount.value / 2), tool.Parent.Size + Vector3.new(0, 0, amount.value), overlay)
			
							for _, v in parts do
								if reachRandom:NextNumber(0, 100) > chance:random() then
									task.wait(0.2)
									break
								end
	
								firetouchinterest(tool.Parent, v, 1)
								firetouchinterest(tool.Parent, v, 0)
							end
						else
							if not modified[tool.Parent] then
								modified[tool.Parent] = tool.Parent.Size
							end
	
							tool.Parent.Size = modified[tool.Parent] + Vector3.new(0, 0, amount.value)
							tool.Parent.Massless = true
						end
					end
	
					task.wait()
				until not reach.enabled
			else
				table.clear(entityFilter)
				for i, v in modified do
					i.Size = v
					i.Massless = false
				end
				table.clear(modified)
			end
		end,
		about = 'Lets you hit enemies from further away.\nSet the extra distance, who it works on, and how often it applies.'
	})
	amount = reach:slider('Range', {
		label = 'Distance',
		min = 0,
		max = 2,
		decimal = 10,
		suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
	reach:divider('Extras')
	targets = reach:targets({players = true})
	mode = reach:dropdown('Mode', {
		choices = {'TouchInterest', 'Resize'},
		changed = function(val)
			chance.row.Visible = val == 'TouchInterest'
		end,
		about = 'TouchInterest - Reports fake collision events to the server\nResize - Physically modifies the tools size'
	})
	chance = reach:range('Chance', {
		min = 0,
		max = 100,
		defaultMin = 100,
		defaultMax = 100,
		about = 'Percent of touches that get the extra reach. Each one rolls its chance from this range.'
	})
end)
	
local mouseClicked
--[[ SilentAim
Redirects the rays the game's own scripts cast towards a target near the mouse or near you, with the
hit and headshot chances rolled per shot. AutoFire clicks while a target is in range, Wallbang hands
back the target part as the hit, and Projectile aims ahead through prediction.SolveTrajectory.

It hooks __namecall for the chosen method (with a trustworthy getnamecallmethod) or Ray.new through
hookfunction, and needs checkcaller and getcallingscript to leave the executor's own calls and the
ignored scripts alone (ControlScript and ControlModule while the list is empty). No plain Roblox API
can do that, so where the executor has neither path the module is left out of the list. A generation
counter stops the loop left over from a Method restart or a quick off and on, so it never auto fires
beside the new one. ]]
run(function()
	local silentAim
	local target
	local mode
	local method
	local methodRay
	local ignoredScripts
	local range
	local hitChance
	local headshotChance
	local autoFire
	local autoFireShootDelay
	local autoFireMode
	local autoFirePosition
	local wallbang
	local circleColor
	local circleTransparency
	local circleFilled
	local circleThickness
	local circleObject
	local projectile
	local projectileSpeed
	local projectileGravity
	local raycastWhitelist = RaycastParams.new()
	raycastWhitelist.FilterType = Enum.RaycastFilterType.Include
	local projectileRaycast = RaycastParams.new()
	projectileRaycast.RespectCanCollide = true
	local targetQuery = {}
	local ignoreRay = {}
	local projectileFilter = {}
	local whitelistFilter = {}
	local defaultIgnoredScripts = {'ControlScript', 'ControlModule'}
	local fireoffset, rand, delayCheck = CFrame.identity, Random.new(), tick()
	local oldnamecall, oldray
	local generation = 0

	local function getTarget(origin, obj)
		if rand.NextNumber(rand, 0, 100) > (autoFire.enabled and 100 or hitChance.random()) then return end
		local targetPart = (rand.NextNumber(rand, 0, 100) < (autoFire.enabled and 100 or headshotChance.random())) and 'Head' or 'RootPart'
		targetQuery.Range = range.value
		targetQuery.Wallcheck = target.walls.enabled and (obj or true) or nil
		targetQuery.Part = targetPart
		targetQuery.Origin = origin
		targetQuery.Players = target.players.enabled
		targetQuery.NPCs = target.npcs.enabled
		local ent = entitylib['Entity'..mode.value](targetQuery)

		if ent then
			targetinfo.Targets[ent] = tick() + 1
			if projectile.enabled then
				projectileFilter[1], projectileFilter[2], projectileFilter[3] = gameCamera, ent.Character, nil
				projectileRaycast.FilterDescendantsInstances = projectileFilter
				projectileRaycast.CollisionGroup = ent[targetPart].CollisionGroup
			end
		end

		return ent, ent and ent[targetPart], origin
	end

	local hooks = {
		FindPartOnRayWithIgnoreList = function(args)
			ignoreRay[1], ignoreRay[2] = args[2], nil
			local ent, targetPart, origin = getTarget(args[1].Origin, ignoreRay)
			if not ent then return end
			if wallbang.enabled then
				return {targetPart, targetPart.Position, targetPart.GetClosestPointOnSurface(targetPart, origin), targetPart.Material}
			end
			args[1] = Ray.new(origin, CFrame.lookAt(origin, targetPart.Position).LookVector * args[1].Direction.Magnitude)
		end,
		Raycast = function(args)
			if methodRay.value ~= 'All' and args[3] and args[3].FilterType ~= Enum.RaycastFilterType[methodRay.value] then return end
			local ent, targetPart, origin = getTarget(args[1])
			if not ent then return end
			args[2] = CFrame.lookAt(origin, targetPart.Position).LookVector * args[2].Magnitude
			if wallbang.enabled then
				whitelistFilter[1], whitelistFilter[2] = targetPart, nil
				raycastWhitelist.FilterDescendantsInstances = whitelistFilter
				args[3] = raycastWhitelist
			end
		end,
		ScreenPointToRay = function(args)
			local ent, targetPart, origin = getTarget(gameCamera.CFrame.Position)
			if not ent then return end
			local direction = CFrame.lookAt(origin, targetPart.Position)
			if projectile.enabled then
				local calc = prediction.SolveTrajectory(origin, projectileSpeed.value, projectileGravity.value, targetPart.Position, targetPart.Velocity, workspace.Gravity, ent.HipHeight, nil, projectileRaycast)
				if not calc then return end
				direction = CFrame.lookAt(origin, calc)
			end
			return {Ray.new(origin + (args[3] and direction.LookVector * args[3] or Vector3.zero), direction.LookVector)}
		end,
		Ray = function(args)
			local ent, targetPart, origin = getTarget(args[1])
			if not ent then return end
			if projectile.enabled then
				local calc = prediction.SolveTrajectory(origin, projectileSpeed.value, projectileGravity.value, targetPart.Position, targetPart.Velocity, workspace.Gravity, ent.HipHeight, nil, projectileRaycast)
				if not calc then return end
				args[2] = CFrame.lookAt(origin, calc).LookVector * args[2].Magnitude
			else
				args[2] = CFrame.lookAt(origin, targetPart.Position).LookVector * args[2].Magnitude
			end
		end
	}
	hooks.FindPartOnRayWithWhitelist = hooks.FindPartOnRayWithIgnoreList
	hooks.FindPartOnRay = hooks.FindPartOnRayWithIgnoreList
	hooks.ViewportPointToRay = hooks.ScreenPointToRay

	local callerChecks = type(checkcaller) == 'function' and type(getcallingscript) == 'function'
	if not (callerChecks and ((exec.HookMetamethod and exec.Namecall) or exec.HookFunction)) then
		exec.hide('SilentAim', 'needs hookmetamethod or hookfunction, getnamecallmethod, checkcaller and getcallingscript')
		return
	end

	silentAim = combat:module('SilentAim', {
		toggled = function(on)
			generation += 1
			if circleObject then
				circleObject.Visible = on and mode.value == 'Mouse'
			end
			if on then
				if method.value == 'Ray' then
					oldray = hookfunction(Ray.new, function(origin, direction)
						if checkcaller() then
							return oldray(origin, direction)
						end
						local calling = getcallingscript()

						if calling then
							local list = #ignoredScripts.active > 0 and ignoredScripts.active or defaultIgnoredScripts
							if table.find(list, tostring(calling)) then
								return oldray(origin, direction)
							end
						end

						local args = {origin, direction}
						hooks.Ray(args)
						return oldray(unpack(args))
					end)
				else
					oldnamecall = hookmetamethod(game, '__namecall', function(...)
						if getnamecallmethod() ~= method.value then
							return oldnamecall(...)
						end
						if checkcaller() then
							return oldnamecall(...)
						end

						local calling = getcallingscript()
						if calling then
							local list = #ignoredScripts.active > 0 and ignoredScripts.active or defaultIgnoredScripts
							if table.find(list, tostring(calling)) then
								return oldnamecall(...)
							end
						end

						local self, args = ..., {select(2, ...)}
						local res = hooks[method.value](args)
						if res then
							return unpack(res)
						end
						return oldnamecall(self, unpack(args))
					end)
				end

				local gen = generation
				repeat
					if circleObject then
						circleObject.Position = inputService:GetMouseLocation()
						local show = mode.value == 'Mouse' and not clickGuiOpen()
						if circleObject.Visible ~= show then circleObject.Visible = show end
					end

					if autoFire.enabled then
						local origin = autoFireMode.value == 'Camera' and gameCamera.CFrame or entitylib.isAlive and entitylib.character.RootPart.CFrame or CFrame.identity
						targetQuery.Range = range.value
						targetQuery.Wallcheck = target.walls.enabled or nil
						targetQuery.Part = 'Head'
						targetQuery.Origin = (origin * fireoffset).Position
						targetQuery.Players = target.players.enabled
						targetQuery.NPCs = target.npcs.enabled
						local ent = entitylib['Entity'..mode.value](targetQuery)

						if mouse1click and windowActive() then
							if ent and canClick() then
								if delayCheck < tick() then
									if mouseClicked then
										mouse1release()
										delayCheck = tick() + autoFireShootDelay.value
									else
										mouse1press()
									end
									mouseClicked = not mouseClicked
								end
							else
								if mouseClicked then
									mouse1release()
								end
								mouseClicked = false
							end
						end
					end

					task.wait()
				until not silentAim.enabled or generation ~= gen
			else
				if oldnamecall then
					hookmetamethod(game, '__namecall', oldnamecall)
				end
				if oldray then
					hookfunction(Ray.new, oldray)
				end
				oldnamecall, oldray = nil, nil
			end
		end,
		info = function()
			return method.value:gsub('FindPartOnRay', '')
		end,
		about = 'Makes your shots hit enemies without you aiming.\nSet range, hit and headshot chance, auto fire, wallbang and projectiles.'
	})
	target = silentAim:targets({players = true})
	mode = silentAim:dropdown('Mode', {
		choices = {'Mouse', 'Position'},
		changed = function(val)
			if circleObject then
				circleObject.Visible = silentAim.enabled and val == 'Mouse' and not clickGuiOpen()
			end
		end,
		about = 'Mouse - Checks for entities near the mouses position\nPosition - Checks for entities near the local character'
	})
	method = silentAim:dropdown('Method', {
		choices = {'FindPartOnRay', 'FindPartOnRayWithIgnoreList', 'FindPartOnRayWithWhitelist', 'ScreenPointToRay', 'ViewportPointToRay', 'Raycast', 'Ray'},
		changed = function(val)
			if silentAim.enabled then
				silentAim:flip()
				silentAim:flip()
			end
			methodRay.row.Visible = val == 'Raycast'
		end,
		about = 'FindPartOnRay* - Deprecated methods of raycasting used in old games\nRaycast - The modern raycast method\nPointToRay - Method to generate a ray from screen coords\nRay - Hooking Ray.new'
	})
	methodRay = silentAim:dropdown('Raycast Type', {
		choices = {'All', 'Exclude', 'Include'},
		sub = true,
		visible = false
	})
	ignoredScripts = silentAim:list('Ignored Scripts')
	range = silentAim:slider('Range', {
		min = 1,
		max = 1000,
		default = 150,
		changed = function(val)
			if circleObject then
				circleObject.Radius = val
			end
		end,
		suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
	hitChance = silentAim:range('Hit Chance', {
		min = 0,
		max = 100,
		defaultMin = 85,
		defaultMax = 85,
		about = 'Percent of shots that get redirected. Each shot rolls its chance from this range.'
	})
	headshotChance = silentAim:range('Headshot Chance', {
		min = 0,
		max = 100,
		defaultMin = 65,
		defaultMax = 65,
		about = 'Percent of redirected shots aimed at the head. Each shot rolls its chance from this range.'
	})
	autoFire = silentAim:toggle('AutoFire', {
		changed = function(callback)
			autoFireShootDelay.row.Visible = callback
			autoFireMode.row.Visible = callback
			autoFirePosition.row.Visible = callback
		end
	})
	autoFireShootDelay = silentAim:slider('Next Shot Delay', {
		min = 0,
		max = 1,
		decimal = 100,
		visible = false,
		sub = true,
		suffix = function(val)
			return val == 1 and 'second' or 'seconds'
		end
	})
	autoFireMode = silentAim:dropdown('Origin', {
		choices = {'RootPart', 'Camera'},
		visible = false,
		sub = true,
		about = 'Determines the position to check for before shooting'
	})
	autoFirePosition = silentAim:textbox('Offset', {
		changed = function()
			local suc, res = pcall(function()
				return CFrame.new(unpack(autoFirePosition.value:split(',')))
			end)
			if suc then fireoffset = res end
		end,
		default = '0, 0, 0',
		visible = false,
		sub = true
	})
	wallbang = silentAim:toggle('Wallbang')
	silentAim:toggle('Range Circle', {
		changed = function(callback)
			if callback then
				circleObject = Drawing.new('Circle')
				circleObject.Filled = circleFilled.enabled
				circleObject.Color = Color3.fromHSV(circleColor.hue, circleColor.sat, circleColor.value)
				circleObject.Position = slinky.gui.AbsoluteSize / 2
				circleObject.Radius = range.value
				circleObject.NumSides = 100
				circleObject.Thickness = circleThickness and circleThickness.value or 1
				circleObject.Transparency = 1 - circleTransparency.value
				circleObject.Visible = silentAim.enabled and mode.value == 'Mouse' and not clickGuiOpen()
			else
				pcall(function()
					circleObject.Visible = false
					circleObject:Remove()
				end)
				circleObject = nil
			end
			circleColor.row.Visible = callback
			circleTransparency.row.Visible = callback
			circleFilled.row.Visible = callback
			if circleThickness then
				circleThickness.row.Visible = callback
			end
		end
	})
	circleColor = silentAim:color('Circle Color', {
		changed = function(hue, sat, val)
			if circleObject then
				circleObject.Color = Color3.fromHSV(hue, sat, val)
			end
		end,
		sub = true,
		visible = false
	})
	circleTransparency = silentAim:slider('Transparency', {
		min = 0,
		max = 1,
		decimal = 10,
		default = 0.5,
		changed = function(val)
			if circleObject then
				circleObject.Transparency = 1 - val
			end
		end,
		sub = true,
		visible = false
	})
	circleFilled = silentAim:toggle('Circle Filled', {
		changed = function(callback)
			if circleObject then
				circleObject.Filled = callback
			end
		end,
		sub = true,
		visible = false
	})
	circleThickness = silentAim:slider('Circle Thickness', {
		min = 1,
		max = 10,
		default = 1,
		changed = function(val)
			if circleObject then
				circleObject.Thickness = val
			end
		end,
		sub = true,
		visible = false
	})
	projectile = silentAim:toggle('Projectile', {
		changed = function(callback)
			projectileSpeed.row.Visible = callback
			projectileGravity.row.Visible = callback
		end
	})
	projectileSpeed = silentAim:slider('Speed', {
		min = 1,
		max = 1000,
		default = 1000,
		sub = true,
		visible = false,
		suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
	projectileGravity = silentAim:slider('Gravity', {
		min = 0,
		max = 192.6,
		default = 192.6,
		sub = true,
		visible = false
	})
end)
	
--[[ TriggerBot
Shoots automatically when a target is in your crosshair. Set the max distance and the delay between
shots. ]]
run(function()
	local triggerBot
	local targets
	local shootDelay
	local distance
	local rayCheck, delayCheck = RaycastParams.new(), tick()
	
	local function getTriggerBotTarget()
		rayCheck.FilterDescendantsInstances = {lplr.Character, gameCamera}
	
		local ray = workspace:Raycast(gameCamera.CFrame.Position, gameCamera.CFrame.LookVector * distance.value, rayCheck)
		if ray and ray.Instance then
			for _, v in entitylib.List do
				if v.Targetable and v.Character and (targets.players.enabled and v.Player or targets.npcs.enabled and v.NPC) then
					if ray.Instance:IsDescendantOf(v.Character) then
						return entitylib.isVulnerable(v) and v
					end
				end
			end
		end
	end
	
	triggerBot = combat:module('TriggerBot', {
		info = function()
			return shootDelay and math.round(shootDelay.value * 1000)..'ms' or nil
		end,
		toggled = function(on)
			if on then
				repeat
					if mouse1click and mouse1press and mouse1release and windowActive() then
						if getTriggerBotTarget() and canClick() then
							if delayCheck < tick() then
								if mouseClicked then
									mouse1release()
									delayCheck = tick() + shootDelay.value
								else
									mouse1press()
								end
								mouseClicked = not mouseClicked
							end
						else
							if mouseClicked then
								mouse1release()
							end
							mouseClicked = false
						end
					end
	
					task.wait()
				until not triggerBot.enabled
			else
				if mouse1click and mouse1release and windowActive() then
					if mouseClicked then
						mouse1release()
					end
				end
				mouseClicked = false
			end
		end,
		about = 'Shoots automatically when a target is in your crosshair.\nSet the max distance and the delay between shots.'
	})
	targets = triggerBot:targets({
		players = true,
		npcs = true
	})
	shootDelay = triggerBot:slider('Next Shot Delay', {
		min = 0,
		max = 1,
		decimal = 100,
		suffix = function(val)
			return val == 1 and 'second' or 'seconds'
		end,
		about = 'The delay set after shooting a target'
	})
	distance = triggerBot:slider('Distance', {
		min = 0,
		max = 1000,
		default = 1000,
		suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
end)
	
--[[ AntiFall
Catches you before you fall into the void. Part keeps a part below the ground under you that bounces
you up when you touch it, or lets you stand on it; Classic puts you back at your last spot on the
ground once you drop near FallenPartsDestroyHeight. A generation counter stops the part loop left
over from a Method restart or a quick off and on. ]]
run(function()
	local antiFall
	local method
	local mode
	local material
	local color
	local rayCheck = RaycastParams.new()
	rayCheck.RespectCanCollide = true
	local part
	local generation = 0

	antiFall = blatant:module('AntiFall', {
		info = function()
			if not method then return nil end
			return method.value == 'Part' and mode and mode.value or method.value
		end,
		toggled = function(on)
			generation += 1
			if on then
				if method.value == 'Part' then
					local debounce = tick()
					part = Instance.new('Part')
					part.Size = Vector3.new(10000, 1, 10000)
					part.Transparency = 1 - color.opacity
					part.Material = Enum.Material[material.value]
					part.Color = Color3.fromHSV(color.hue, color.sat, color.value)
					part.CanCollide = mode.value == 'Collide'
					part.Anchored = true
					part.CanQuery = false
					part.Parent = workspace
	
					antiFall:clean(part)
					antiFall:clean(part.Touched:Connect(function(touchedpart)
						if touchedpart.Parent == lplr.Character and entitylib.isAlive and debounce < tick() then
							local root = entitylib.character.RootPart
							debounce = tick() + 0.1
							if mode.value == 'Velocity' then
								root.AssemblyLinearVelocity = Vector3.new(root.AssemblyLinearVelocity.X, 100, root.AssemblyLinearVelocity.Z)
							elseif mode.value == 'Impulse' then
								root:ApplyImpulse(Vector3.new(0, (100 - root.AssemblyLinearVelocity.Y), 0) * root.AssemblyMass)
							end
						end
					end))

					local gen = generation
					repeat
						if entitylib.isAlive then
							local root = entitylib.character.RootPart
							rayCheck.FilterDescendantsInstances = {gameCamera, lplr.Character, part}
							rayCheck.CollisionGroup = root.CollisionGroup
							local ray = workspace:Raycast(root.Position, Vector3.new(0, -1000, 0), rayCheck)
							if ray then
								part.Position = ray.Position - Vector3.new(0, 15, 0)
							end
						end
	
						task.wait(0.1)
					until not antiFall.enabled or generation ~= gen
				else
					local lastpos
					antiFall:clean(runService.PreSimulation:Connect(function()
						if entitylib.isAlive then
							local root = entitylib.character.RootPart
							lastpos = entitylib.character.Humanoid.FloorMaterial ~= Enum.Material.Air and root.Position or lastpos
							if (root.Position.Y + (root.Velocity.Y * 0.016)) <= (workspace.FallenPartsDestroyHeight + 10) then
								lastpos = lastpos or Vector3.new(root.Position.X, (workspace.FallenPartsDestroyHeight + 20), root.Position.Z)
								root.CFrame += (lastpos - root.Position)
								root.Velocity *= Vector3.new(1, 0, 1)
							end
						end
					end))
				end
			end
		end,
		about = 'Catches you before you fall into the void.\nBounces you up, gives you a floor, or sends you back to land.'
	})
	method = antiFall:dropdown('Method', {
		choices = {'Part', 'Classic'},
		changed = function(val)
			if mode.row then
				mode.row.Visible = val == 'Part'
				material.row.Visible = val == 'Part'
				color.row.Visible = val == 'Part'
			end
			if antiFall.enabled then
				antiFall:flip()
				antiFall:flip()
			end
		end,
		about = 'Part - Moves a part under you that does various methods to stop you from falling\nClassic - Teleports you out of the void after reaching the part destroy plane'
	})
	mode = antiFall:dropdown('Move Mode', {
		choices = {'Impulse', 'Velocity', 'Collide'},
		sub = true,
		changed = function(val)
			if part then
				part.CanCollide = val == 'Collide'
			end
		end,
		about = 'Velocity - Launches you upward after touching\nCollide - Allows you to walk on the part'
	})
	local materials = {'ForceField'}
	for _, v in Enum.Material:GetEnumItems() do
		if v.Name ~= 'ForceField' then
			table.insert(materials, v.Name)
		end
	end
	material = antiFall:dropdown('Material', {
		choices = materials,
		sub = true,
		changed = function(val)
			if part then
				part.Material = Enum.Material[val]
			end
		end
	})
	color = antiFall:color('Color', {
		opacity = 0.5,
		sub = true,
		changed = function(h, s, v, o)
			if part then
				part.Color = Color3.fromHSV(h, s, v)
				part.Transparency = 1 - o
			end
		end
	})
end)
	
--[[ Desync
Others keep seeing you where Desync was switched on while you move freely. The executors that hook,
and any with raknet.add_send_hook, rewrite the outgoing 0x1b packet through raknet and warn when
raknet is missing. Without raknet (Solara, Xeno) the swap Invisible uses does the same: the root is
put at the held CFrame in Heartbeat, after physics, so that is what replicates, and back at its real
CFrame at render step 0 of the next frame, before the camera and the next simulation see it. The
real CFrame is kept until render step 0 has put it back, so it is never lost. ]]
run(function()
	local desync
	local hook

	local function holdPosition()
		local held, real
		local bindKey = httpService:GenerateGUID(true)
		local function restore()
			if real and entitylib.isAlive then
				entitylib.character.RootPart.CFrame = real
			end
			real = nil
		end
		runService:BindToRenderStep(bindKey, 0, restore)
		desync:clean(function()
			runService:UnbindFromRenderStep(bindKey)
			restore()
		end)
		desync:clean(runService.Heartbeat:Connect(function()
			if not entitylib.isAlive then
				held, real = nil, nil
				return
			end
			local root = entitylib.character.RootPart
			held = held or root.CFrame
			real = real or root.CFrame
			root.CFrame = held
		end))
		desync:clean(entitylib.Events.LocalAdded:Connect(function()
			held, real = nil, nil
		end))
	end

	desync = blatant:module('Desync', {
		toggled = function(on)
			if on then
				if not hookExecutor and not (type(raknet) == 'table' and type(raknet.add_send_hook) == 'function') then
					holdPosition()
					return
				end
				if not rakNetCheck('Desync') then
					desync:flip()
					return
				end
	
				hook = function(packet)
					if packet.AsArray[1] == 0x1b then
						local data = packet.AsBuffer
						buffer.writeu32(data, 1, 0xFFFFFFFF)
						packet:SetData(data)
					end
				end
	
				raknet.add_send_hook(hook)
			elseif hook then
				raknet.remove_send_hook(hook)
				hook = nil
			end
		end,
		about = 'Hides your real position from other players.'
	})
end)
	
local fly
local longJump
--[[ Fly
Lets you fly around freely. Choose the flying and hovering styles, speeds and up and down keys. ]]
run(function()
	local options = {TPTiming = tick()}
	local mode
	local floatMode
	local state
	local moveMethod
	local keys
	local verticalValue
	local bounceLength
	local bounceDelay
	local floatTPGround
	local floatTPAir
	local customProperties
	local wallCheck
	local platformStanding
	local platform, yLevel, oldYLevel
	local w, s, a, d, up, down = 0, 0, 0, 0, 0, 0
	local rayCheck = RaycastParams.new()
	rayCheck.RespectCanCollide = true
	options.rayCheck = rayCheck

	local functions
	functions = {
		Velocity = function()
			entitylib.character.RootPart.Velocity = (entitylib.character.RootPart.Velocity * Vector3.new(1, 0, 1)) + Vector3.new(0, 2.25 + ((up + down) * verticalValue.value), 0)
		end,
		Impulse = function(options, moveDirection)
			local root = entitylib.character.RootPart
			local diff = (Vector3.new(0, 2.25 + ((up + down) * verticalValue.value), 0) - root.AssemblyLinearVelocity) * Vector3.new(0, 1, 0)
			if diff.Magnitude > 2 then
				root:ApplyImpulse(diff * root.AssemblyMass)
			end
		end,
		CFrame = function(dt)
			local root = entitylib.character.RootPart
			if not yLevel then
				yLevel = root.Position.Y
			end
			yLevel = yLevel + ((up + down) * verticalValue.value * dt)
			if wallCheck.enabled then
				rayCheck.FilterDescendantsInstances = {lplr.Character, gameCamera}
				rayCheck.CollisionGroup = root.CollisionGroup
				local ray = workspace:Raycast(root.Position, Vector3.new(0, yLevel - root.Position.Y, 0), rayCheck)
				if ray then
					yLevel = ray.Position.Y + entitylib.character.HipHeight
				end
			end
			root.Velocity *= Vector3.new(1, 0, 1)
			root.CFrame += Vector3.new(0, yLevel - root.Position.Y, 0)
		end,
		Bounce = function()
			functions.Velocity()
			entitylib.character.RootPart.Velocity += Vector3.new(0, ((tick() % bounceDelay.value) / bounceDelay.value > 0.5 and 1 or -1) * bounceLength.value, 0)
		end,
		Floor = function()
			platform.CFrame = down ~= 0 and CFrame.identity or entitylib.character.RootPart.CFrame + Vector3.new(0, -(entitylib.character.HipHeight + 0.5), 0)
		end,
		TP = function(dt)
			functions.CFrame(dt)
			if tick() % (floatTPAir.value + floatTPGround.value) > floatTPAir.value then
				oldYLevel = oldYLevel or yLevel
				rayCheck.FilterDescendantsInstances = {lplr.Character, gameCamera}
				rayCheck.CollisionGroup = entitylib.character.RootPart.CollisionGroup
				local ray = workspace:Raycast(entitylib.character.RootPart.Position, Vector3.new(0, -1000, 0), rayCheck)
				if ray then
					yLevel = ray.Position.Y + entitylib.character.HipHeight
				end
			else
				if oldYLevel then
					yLevel = oldYLevel
					oldYLevel = nil
				end
			end
		end,
		Jump = function(dt)
			local root = entitylib.character.RootPart
			if not yLevel then
				yLevel = root.Position.Y
			end
			yLevel = yLevel + ((up + down) * verticalValue.value * dt)
			if root.Position.Y < yLevel then
				entitylib.character.Humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
			end
		end
	}

	fly = blatant:module('Fly', {
		toggled = function(on)
			if platform then
				platform.Parent = on and gameCamera or nil
			end

			frictionTable.Fly = on and customProperties.enabled or nil
			updateVelocity()
			if on then
				fly:clean(runService.PreSimulation:Connect(function(dt)
					if entitylib.isAlive then
						if platformStanding.enabled then
							entitylib.character.Humanoid.PlatformStand = true
							entitylib.character.RootPart.RotVelocity = Vector3.zero
							entitylib.character.RootPart.CFrame = CFrame.lookAlong(entitylib.character.RootPart.CFrame.Position, gameCamera.CFrame.LookVector)
						end

						if state.value ~= 'None' then
							entitylib.character.Humanoid:ChangeState(Enum.HumanoidStateType[state.value])
						end

						speedMethods[mode.value](options, targetStrafeVector or moveMethod.value == 'Direct' and calculateMoveVector(Vector3.new(a + d, 0, w + s)) or entitylib.character.Humanoid.MoveDirection, dt)
						functions[floatMode.value](dt)
					else
						yLevel = nil
						oldYLevel = nil
					end
				end))

				w, s, a, d = inputService:IsKeyDown(Enum.KeyCode.W) and -1 or 0, inputService:IsKeyDown(Enum.KeyCode.S) and 1 or 0, inputService:IsKeyDown(Enum.KeyCode.A) and -1 or 0, inputService:IsKeyDown(Enum.KeyCode.D) and 1 or 0
				up, down = 0, 0
				for _, v in {'InputBegan', 'InputEnded'} do
					fly:clean(inputService[v]:Connect(function(input)
						if not inputService:GetFocusedTextBox() then
							local divided = keys.value:split('/')
							if input.KeyCode == Enum.KeyCode.W then
								w = v == 'InputBegan' and -1 or 0
							elseif input.KeyCode == Enum.KeyCode.S then
								s = v == 'InputBegan' and 1 or 0
							elseif input.KeyCode == Enum.KeyCode.A then
								a = v == 'InputBegan' and -1 or 0
							elseif input.KeyCode == Enum.KeyCode.D then
								d = v == 'InputBegan' and 1 or 0
							elseif input.KeyCode == Enum.KeyCode[divided[1]] then
								up = v == 'InputBegan' and 1 or 0
							elseif input.KeyCode == Enum.KeyCode[divided[2]] then
								down = v == 'InputBegan' and -1 or 0
							end
						end
					end))
				end

				if inputService.TouchEnabled then
					pcall(function()
						local jumpButton = lplr.PlayerGui.TouchGui.TouchControlFrame.JumpButton
						fly:clean(jumpButton:GetPropertyChangedSignal('ImageRectOffset'):Connect(function()
							up = jumpButton.ImageRectOffset.X == 146 and 1 or 0
						end))
					end)
				end
			else
				yLevel, oldYLevel = nil, nil
				if entitylib.isAlive then
					if platformStanding.enabled then
						entitylib.character.Humanoid.PlatformStand = false
					end

					if options.WalkSpeed then
						entitylib.character.Humanoid.WalkSpeed = options.WalkSpeed
					end
				end

				options.WalkSpeed = nil
			end
		end,
		info = function()
			return mode.value
		end,
		about = 'Lets you fly around freely.\nChoose the flying and hovering styles, speeds and up and down keys.'
	})
	mode = fly:dropdown('Speed Mode', {
		choices = speedMethodList,
		changed = function(val)
			wallCheck.row.Visible = floatMode.value == 'CFrame' or floatMode.value == 'TP' or val == 'CFrame' or val == 'TP'
			options.TPFrequency.row.Visible = val == 'TP'
			options.PulseLength.row.Visible = val == 'Pulse'
			options.PulseDelay.row.Visible = val == 'Pulse'
			if fly.enabled then
				fly:flip()
				fly:flip()
			end
		end,
		about = 'Velocity - Uses smooth physics based movement\nImpulse - Same as velocity while using forces instead\nCFrame - Directly adjusts the position of the root\nTP - Large teleports within intervals\nPulse - Controllable bursts of speed\nWalkSpeed - The classic mode of speed, usually detected on most games.'
	})
	floatMode = fly:dropdown('Float Mode', {
		choices = {'Velocity', 'Impulse', 'CFrame', 'Bounce', 'Floor', 'Jump', 'TP'},
		changed = function(val)
			wallCheck.row.Visible = mode.value == 'CFrame' or mode.value == 'TP' or val == 'CFrame' or val == 'TP'
			bounceLength.row.Visible = val == 'Bounce'
			bounceDelay.row.Visible = val == 'Bounce'
			verticalValue.row.Visible = val ~= 'Floor'
			floatTPGround.row.Visible = val == 'TP'
			floatTPAir.row.Visible = val == 'TP'

			if platform then
				platform:Destroy()
				platform = nil
			end

			if val == 'Floor' then
				platform = Instance.new('Part')
				platform.CanQuery = false
				platform.Anchored = true
				platform.Size = Vector3.one
				platform.Transparency = 1
				platform.Parent = fly.enabled and gameCamera or nil
			end
		end,
		about = 'Velocity - Uses smooth physics based movement\nImpulse - Same as velocity while using forces instead\nCFrame - Directly adjusts the position of the root\nTP - Teleports you to the ground within intervals\nFloor - Spawns a part under you\nJump - Presses space after going below a certain Y Level\nBounce - Vertical bouncing motion'
	})
	local states = {'None'}
	for _, v in Enum.HumanoidStateType:GetEnumItems() do
		if v.Name ~= 'Dead' and v.Name ~= 'None' then
			table.insert(states, v.Name)
		end
	end
	state = fly:dropdown('Humanoid State', {
		choices = states
	})
	moveMethod = fly:dropdown('Move Mode', {
		choices = {'MoveDirection', 'Direct'},
		about = 'MoveDirection - Uses the games input vector for movement\nDirect - Directly calculate our own input vector'
	})
	keys = fly:dropdown('Keys', {
		choices = {'Space/LeftControl', 'Space/LeftShift', 'E/Q', 'Space/Q', 'ButtonA/ButtonL2'},
		about = 'The key combination for going up & down'
	})
	options.Value = fly:slider('Speed', {
		min = 1,
		max = 150,
		default = 50,
		suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
	verticalValue = fly:slider('Vertical Speed', {
		min = 1,
		max = 150,
		default = 50,
		suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
	options.TPFrequency = fly:slider('TP Frequency', {
		min = 0,
		max = 1,
		decimal = 100,
		sub = true,
		visible = false,
		suffix = function(val)
			return val == 1 and 'second' or 'seconds'
		end
	})
	options.PulseLength = fly:slider('Pulse Length', {
		min = 0,
		max = 1,
		decimal = 100,
		sub = true,
		visible = false,
		suffix = function(val)
			return val == 1 and 'second' or 'seconds'
		end
	})
	options.PulseDelay = fly:slider('Pulse Delay', {
		min = 0,
		max = 1,
		decimal = 100,
		sub = true,
		visible = false,
		suffix = function(val)
			return val == 1 and 'second' or 'seconds'
		end
	})
	bounceLength = fly:slider('Bounce Length', {
		min = 0,
		max = 30,
		sub = true,
		visible = false,
		suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
	bounceDelay = fly:slider('Bounce Delay', {
		min = 0,
		max = 1,
		decimal = 100,
		sub = true,
		visible = false,
		suffix = function(val)
			return val == 1 and 'second' or 'seconds'
		end
	})
	floatTPGround = fly:slider('Ground', {
		min = 0,
		max = 1,
		decimal = 10,
		default = 0.1,
		sub = true,
		visible = false,
		suffix = function(val)
			return val == 1 and 'second' or 'seconds'
		end
	})
	floatTPAir = fly:slider('Air', {
		min = 0,
		max = 5,
		decimal = 10,
		default = 2,
		sub = true,
		visible = false,
		suffix = function(val)
			return val == 1 and 'second' or 'seconds'
		end
	})
	wallCheck = fly:toggle('Wall Check', {
		default = true,
		sub = true,
		visible = false
	})
	options.WallCheck = wallCheck
	platformStanding = fly:toggle('PlatformStand', {
		changed = function(callback)
			if fly.enabled then
				entitylib.character.Humanoid.PlatformStand = callback
			end
		end,
		about = 'Forces the character to look infront of the camera'
	})
	customProperties = fly:toggle('Custom Properties', {
		changed = function()
			if fly.enabled then
				fly:flip()
				fly:flip()
			end
		end,
		default = true
	})
end)
	
--[[ HighJump
Boosts your jump to the height set: by velocity, by impulse, or by moving the root up step by step
(CFrame over frames, Instant in one go). With Auto Disable it boosts once and turns off; otherwise
every jump while Space or the touch jump button is held. The touch jump button sets no key, so
Humanoid.Jump stands in for it. The step modes do nothing without gravity, and stop at 600 steps in
case gravity drops to 0 mid-jump (normal gravity needs under 50). ]]
run(function()
	local highJump
	local mode
	local amount
	local autoDisable
	
	local function jump()
		local state = entitylib.isAlive and entitylib.character.Humanoid:GetState() or nil
	
		if state == Enum.HumanoidStateType.Running or state == Enum.HumanoidStateType.Landed then
			local root = entitylib.character.RootPart
	
			if mode.value == 'Velocity' then
				entitylib.character.Humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
				root.AssemblyLinearVelocity = Vector3.new(root.AssemblyLinearVelocity.X, amount.value, root.AssemblyLinearVelocity.Z)
			elseif mode.value == 'Impulse' then
				entitylib.character.Humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
				task.delay(0, function()
					root:ApplyImpulse(Vector3.new(0, amount.value - root.AssemblyLinearVelocity.Y, 0) * root.AssemblyMass)
				end)
			else
				if workspace.Gravity <= 0 then return end
				local yLevel = math.max(amount.value - entitylib.character.Humanoid.JumpHeight, 0)
				local steps = 0
	
				repeat
					root.CFrame += Vector3.new(0, yLevel * 0.016, 0)
					yLevel = yLevel - (workspace.Gravity * 0.016)
					steps += 1
	
					if mode.value == 'CFrame' then
						task.wait()
					end
				until yLevel <= 0 or steps >= 600
			end
		end
	end
	
	highJump = blatant:module('HighJump', {
		toggled = function(on)
			if on then
				if autoDisable.enabled then
					jump()
					highJump:flip()
				else
					highJump:clean(runService.RenderStepped:Connect(function()
						if inputService:GetFocusedTextBox() then return end
						if inputService:IsKeyDown(Enum.KeyCode.Space)
							or (inputService.TouchEnabled and entitylib.isAlive and entitylib.character.Humanoid.Jump) then
							jump()
						end
					end))
				end
			end
		end,
		info = function()
			return mode.value
		end,
		about = 'Lets you jump much higher than normal.\nBoosts one jump then turns off, or every jump while you hold Space.'
	})
	mode = highJump:dropdown('Mode', {
		choices = {'Impulse', 'Velocity', 'CFrame', 'Instant'},
		about = 'Velocity - Uses smooth movement to boost you upward\nImpulse - Same as velocity while using forces instead\nCFrame - Directly adjusts the position upward\nInstant - Teleports you to the peak of the jump'
	})
	amount = highJump:slider('Velocity', {
		min = 1,
		max = 150,
		default = 50,
		suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
	autoDisable = highJump:toggle('Auto Disable', {
		default = true
	})
end)
	
--[[ HitBoxes
Makes other players easier to hit. Grows their body or head by the amount you set. ]]
run(function()
	local hitBoxes
	local targets
	local targetPart
	local expand
	local modified = {}
	
	hitBoxes = blatant:module('HitBoxes', {
		info = function()
			return expand and tostring(expand.value) or nil
		end,
		label = 'Hitboxes',
		tab = 'Combat',
		toggled = function(on)
			if on then
				repeat
					for _, v in entitylib.List do
						if v.Targetable then
							if not targets.players.enabled and v.Player then continue end
							if not targets.npcs.enabled and v.NPC then continue end
							local part = v[targetPart.value]
							if not modified[part] then
								modified[part] = part.Size
							end
							part.Size = modified[part] + Vector3.new(expand.value, expand.value, expand.value)
						end
					end
	
					task.wait()
				until not hitBoxes.enabled
			else
				for i, v in modified do
					i.Size = v
				end
				table.clear(modified)
			end
		end,
		about = 'Makes other players easier to hit.\nGrows their body or head by the amount you set.'
	})
	expand = hitBoxes:slider('Expand amount', {
		label = 'Expand',
		min = 0,
		max = 2,
		decimal = 10,
		suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
	hitBoxes:divider('Extras')
	targets = hitBoxes:targets({players = true})
	targetPart = hitBoxes:dropdown('Part', {
		choices = {'RootPart', 'Head'}
	})
end)
	
--[[ Invisible
Turns you invisible. ]]
run(function()
	local invisible
	local oldcf
	local animtrack
	local proper = true
	
	local function animationTrickery()
		if entitylib.isAlive then
			local isR15 = entitylib.character.Humanoid.RigType == Enum.HumanoidRigType.R15
			local anim = Instance.new('Animation')
			anim.AnimationId = 'rbxassetid://'..(isR15 and '18537363391' or '215384594')
			animtrack = entitylib.character.Humanoid.Animator:LoadAnimation(anim)
			animtrack.Priority = Enum.AnimationPriority.Action4
			animtrack:Play(0, 0.001, 0)
			anim:Destroy()
	
			task.delay(0, function()
				animtrack.TimePosition = isR15 and 0.77 or 0.38
			end)
		end
	end
	
	invisible = blatant:module('Invisible', {
		toggled = function(on)
			if on then
				animationTrickery()
	
				local bindKey = httpService:GenerateGUID(true)
				runService:BindToRenderStep(bindKey, 0, function()
					if entitylib.isAlive and oldcf then
						entitylib.character.RootPart.CFrame = oldcf
						animtrack:AdjustWeight(0.001)
					end
				end)
	
				invisible:clean(function()
					runService:UnbindFromRenderStep(bindKey)
				end)
	
				invisible:clean(runService.Heartbeat:Connect(function(dt)
					if entitylib.isAlive then
						local isR15 = entitylib.character.Humanoid.RigType == Enum.HumanoidRigType.R15
						local root = entitylib.character.RootPart
						local cf = root.CFrame - Vector3.new(0, entitylib.character.Humanoid.HipHeight + (root.Size.Y / 2) - 1, 0)
						oldcf = root.CFrame
	
						root.CFrame = cf * CFrame.Angles(math.rad(isR15 and 180 or 90), 0, 0)
						animtrack:AdjustWeight(100)
					end
				end))
	
				invisible:clean(entitylib.Events.LocalAdded:Connect(function(char)
					local animator = char.Humanoid:WaitForChild('Animator', 1)
					if animator and invisible.enabled then
						oldcf = nil
						invisible:flip()
						invisible:flip()
					end
				end))
			else
				if animtrack then
					animtrack:Stop()
					animtrack:Destroy()
				end
	
				if entitylib.isAlive and oldcf then
					entitylib.character.RootPart.CFrame = oldcf
				end
			end
		end,
		about = 'Turns you invisible.'
	})
end)
	
--[[ Jesus
Lets you walk on water as if it were solid ground. ]]
run(function()
	local jesus
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	
	jesus = blatant:module('Jesus', {
		toggled = function(on)
			if on then
				local terrain = workspace:FindFirstChildWhichIsA('Terrain')
				params.FilterDescendantsInstances = {terrain}
				local platform = Instance.new('Part')
				platform.CanQuery = false
				platform.Anchored = true
				platform.Size = Vector3.one
				platform.Transparency = 1
				platform.Parent = gameCamera
	
				jesus:clean(platform)
				jesus:clean(runService.PreSimulation:Connect(function()
					if entitylib.isAlive then
						local root = entitylib.character.RootPart
						local ray = workspace:Raycast(root.Position, Vector3.new(0, -((root.Size.Y / 2) + entitylib.character.HipHeight + math.abs(root.AssemblyLinearVelocity.Y * 0.032)), 0), params)
	
						if ray and ray.Material == Enum.Material.Water then
							platform.CFrame = CFrame.new(ray.Position)
						else
							platform.CFrame = CFrame.new(10000, 10000, 10000)
						end
					end
				end))
			end
		end,
		about = 'Lets you walk on water as if it were solid ground.'
	})
end)
	
--[[ Killaura
Swings the held tool at targets in range in front of you, up to Max targets, and within Attack range
sends the hit through firetouchinterest on the target's parts. Boxes and particles drop while the
menu is open; attacking goes on. On Solara and Xeno an entity's RootPart can be a stand-in table
that still carries a Position, which Adornee rejects, so a box adorns only a real Instance. ]]
run(function()
	local killaura
	local targets
	local cps
	local swingRange
	local attackRange
	local angleSlider
	local max
	local mouse
	local lunge
	local boxSwingColor
	local boxAttackColor
	local particleTexture
	local particleColor1
	local particleColor2
	local particleSize
	local face
	local overlay = OverlapParams.new()
	overlay.FilterType = Enum.RaycastFilterType.Include
	local particleParts, boxes, attackDelay = {}, {}, time()
	local attacked, targetQuery, targetsBuffer, overlayFilter = {}, {}, {}, {}
	local proximityQuery = {}
	local attackedCapacity = 0
	local targetScanElapsed, elapsed = 0, 0
	local closeTargetMode = false
	local forceTargetScan = true
	local lastPlayers, lastNPCs, lastRange, lastLimit
	local flatVector = Vector3.new(1, 0, 1)
	local hitboxSize = Vector3.new(4, 4, 4)
	local farAway = Vector3.new(9e9, 9e9, 9e9)
	
	local function getAttackData()
		if mouse.enabled then
			if not inputService:IsMouseButtonPressed(0) then return false end
		end
	
		local tool = getTool()
		return tool and tool:FindFirstChildWhichIsA('TouchTransmitter', true) or nil, tool
	end
	
	killaura = blatant:module('Killaura', {
		info = function()
			return attackRange and tostring(attackRange.value) or nil
		end,
		tab = 'Combat',
		toggled = function(on)
			if on then
				killaura:clean(entitylib.Events.EntityAdded:Connect(function()
					forceTargetScan = true
				end))
				killaura:clean(entitylib.Events.EntityRemoved:Connect(function()
					forceTargetScan = true
				end))
				repeat
					local interest, tool = getAttackData()
					local attackedCount = 0
					local playersEnabled = targets.players.enabled
					local npcsEnabled = targets.npcs.enabled
					local swingRange = swingRange.value
					local maxTargets = max.value
					if playersEnabled ~= lastPlayers or npcsEnabled ~= lastNPCs or swingRange ~= lastRange or maxTargets ~= lastLimit then
						lastPlayers, lastNPCs, lastRange, lastLimit = playersEnabled, npcsEnabled, swingRange, maxTargets
						forceTargetScan = true
					end

					proximityQuery.Players = playersEnabled
					proximityQuery.NPCs = npcsEnabled
					proximityQuery.Targetable = true
					local nearestDistanceSq = entitylib.NearestDistanceSq(proximityQuery)
					if closeTargetMode then
						if nearestDistanceSq >= (55 * 55) then
							closeTargetMode = false
							forceTargetScan = true
						end
					elseif nearestDistanceSq <= (45 * 45) then
						closeTargetMode = true
						forceTargetScan = true
					end
					targetScanElapsed += elapsed
					local scanInterval = closeTargetMode and (1 / 60) or (1 / 30)
					local scanDue = forceTargetScan or targetScanElapsed >= scanInterval or targets.walls.enabled

					if interest then
						if scanDue then
							targetScanElapsed %= scanInterval
							forceTargetScan = false
							targetQuery.Range = swingRange
							targetQuery.Wallcheck = targets.walls.enabled or nil
							targetQuery.Part = 'RootPart'
							targetQuery.Players = playersEnabled
							targetQuery.NPCs = npcsEnabled
							targetQuery.Limit = maxTargets
							targetQuery.Output = targetsBuffer
							targetQuery.Cache = true
							entitylib.AllPosition(targetQuery)
						else
							local rangeSq = swingRange * swingRange
							for index = #targetsBuffer, 1, -1 do
								local target = targetsBuffer[index]
								local root = target and target.RootPart
								local valid = target and target.Targetable and root and entitylib.isVulnerable(target)
								if valid then
									local delta = root.Position - entitylib.character.RootPart.Position
									valid = delta:Dot(delta) <= rangeSq
								end
								if not valid then
									targetsBuffer[index] = targetsBuffer[#targetsBuffer]
									targetsBuffer[#targetsBuffer] = nil
									forceTargetScan = true
								end
							end
						end

						local plrs = targetsBuffer

						if #plrs > 0 then
							local selfpos = entitylib.character.RootPart.Position
							local localfacing = entitylib.character.RootPart.CFrame.LookVector * flatVector
							local angleLimit = math.rad(angleSlider.value) / 2
							local attackRange = attackRange.value
							local now = time()

							for _, v in plrs do
								local delta = (v.RootPart.Position - selfpos)
								local angle = math.acos(localfacing:Dot((delta * flatVector).Unit))
								if angle > angleLimit then continue end
								local distanceSq = delta:Dot(delta)
								local distance = math.sqrt(distanceSq)

								attackedCount += 1
								local hit = attacked[attackedCount]
								if not hit then
									hit = {}
									attacked[attackedCount] = hit
									attackedCapacity = attackedCount
								end
								hit.Entity = v
								hit.Check = distance > attackRange and boxSwingColor or boxAttackColor
								targetinfo.Targets[v] = now + 1

				if attackDelay < now then
					attackDelay = now + (1 / cps.random())
					entitylib.Performance:RecordKillauraSwing(v, os.clock())
					tool:Activate()
				end

								if lunge.enabled and tool.GripUp.X == 0 then break end
								if distance > attackRange then continue end

								overlayFilter[1] = v.Character
								overlayFilter[2] = nil
								overlay.FilterDescendantsInstances = overlayFilter
								for _, part in workspace:GetPartBoundsInBox(v.RootPart.CFrame, hitboxSize, overlay) do
									firetouchinterest(interest.Parent, part, 1)
									firetouchinterest(interest.Parent, part, 0)
								end
							end
						end
					end

				local hideVisuals = clickGuiOpen()
				for i, v in boxes do
					local hit = not hideVisuals and i <= attackedCount and attacked[i] or nil
					local root = hit and hit.Entity.RootPart or nil
					v.Adornee = typeof(root) == 'Instance' and root or nil
					if hit then
						v.Color3 = Color3.fromHSV(hit.Check.hue, hit.Check.sat, hit.Check.value)
						v.Transparency = 1 - hit.Check.opacity
					end
				end

				for i, v in particleParts do
					local hit = not hideVisuals and i <= attackedCount and attacked[i] or nil
					v.Position = hit and hit.Entity.RootPart.Position or farAway
					v.Parent = hit and gameCamera or nil
				end

				if face.enabled and attackedCount > 0 then
					local vec = attacked[1].Entity.RootPart.Position * flatVector
					entitylib.character.RootPart.CFrame = CFrame.lookAt(entitylib.character.RootPart.Position, Vector3.new(vec.X, entitylib.character.RootPart.Position.Y + 0.01, vec.Z))
				end

				for index = 1, attackedCapacity do
					local hit = attacked[index]
					hit.Entity = nil
					hit.Check = nil
				end

				elapsed = task.wait()
				until not killaura.enabled
			else
				for _, v in boxes do
					v.Adornee = nil
				end

				for _, v in particleParts do
					v.Parent = nil
				end
				table.clear(targetsBuffer)
				forceTargetScan = true
				targetScanElapsed = 0
			end
		end,
		about = 'Attacks enemies around you without you aiming.\nSet reach, speed, angle and target count, with target boxes and particles.'
	})
	targets = killaura:targets({players = true})
	cps = killaura:range('Attacks per Second', {
		min = 1,
		max = 20,
		defaultMin = 12,
		defaultMax = 12
	})
	swingRange = killaura:slider('Swing range', {
		min = 1,
		max = 30,
		default = 13,
		suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
	attackRange = killaura:slider('Attack range', {
		min = 1,
		max = 30,
		default = 13,
		suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
	angleSlider = killaura:slider('Max angle', {
		min = 1,
		max = 360,
		default = 90
	})
	max = killaura:slider('Max targets', {
		min = 1,
		max = 10,
		default = 10
	})
	mouse = killaura:toggle('Require mouse down')
	lunge = killaura:toggle('Sword lunge only')
	killaura:toggle('Show target', {
		changed = function(callback)
			boxSwingColor.row.Visible = callback
			boxAttackColor.row.Visible = callback
			if callback then
				for i = 1, 10 do
					local box = Instance.new('BoxHandleAdornment')
					box.Adornee = nil
					box.AlwaysOnTop = true
					box.Size = Vector3.new(3, 5, 3)
					box.CFrame = CFrame.new(0, -0.5, 0)
					box.ZIndex = 0
					box.Parent = slinky.gui
					boxes[i] = box
				end
			else
				for _, v in boxes do
					v:Destroy()
				end
				table.clear(boxes)
			end
		end
	})
	boxSwingColor = killaura:color('Target Color', {
		sub = true,
		hue = 0.6,
		opacity = 0.5,
		visible = false
	})
	boxAttackColor = killaura:color('Attack Color', {
		sub = true,
		opacity = 0.5,
		visible = false
	})
	killaura:toggle('Target particles', {
		changed = function(callback)
			particleTexture.row.Visible = callback
			particleColor1.row.Visible = callback
			particleColor2.row.Visible = callback
			particleSize.row.Visible = callback
			if callback then
				for i = 1, 10 do
					local part = Instance.new('Part')
					part.Size = Vector3.new(2, 4, 2)
					part.Anchored = true
					part.CanCollide = false
					part.Transparency = 1
					part.CanQuery = false
					part.Parent = killaura.enabled and not clickGuiOpen() and gameCamera or nil
					local particles = Instance.new('ParticleEmitter')
					particles.Brightness = 1.5
					particles.Size = NumberSequence.new(particleSize.value)
					particles.Shape = Enum.ParticleEmitterShape.Sphere
					particles.Texture = particleTexture.value
					particles.Transparency = NumberSequence.new(0)
					particles.Lifetime = NumberRange.new(0.4)
					particles.Speed = NumberRange.new(16)
					particles.Rate = 128
					particles.Drag = 16
					particles.ShapePartial = 1
					particles.Color = ColorSequence.new({
						ColorSequenceKeypoint.new(0, Color3.fromHSV(particleColor1.hue, particleColor1.sat, particleColor1.value)),
						ColorSequenceKeypoint.new(1, Color3.fromHSV(particleColor2.hue, particleColor2.sat, particleColor2.value))
					})
					particles.Parent = part
					particleParts[i] = part
				end
			else
				for _, v in particleParts do
					v:Destroy()
				end
				table.clear(particleParts)
			end
		end
	})
	particleTexture = killaura:textbox('Texture', {
		default = 'rbxassetid://14736249347',
		changed = function()
			for _, v in particleParts do
				v.ParticleEmitter.Texture = particleTexture.value
			end
		end,
		sub = true,
		visible = false
	})
	particleColor1 = killaura:color('Color Begin', {
		changed = function(hue, sat, val)
			for _, v in particleParts do
				v.ParticleEmitter.Color = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromHSV(hue, sat, val)),
					ColorSequenceKeypoint.new(1, Color3.fromHSV(particleColor2.hue, particleColor2.sat, particleColor2.value))
				})
			end
		end,
		sub = true,
		visible = false
	})
	particleColor2 = killaura:color('Color End', {
		changed = function(hue, sat, val)
			for _, v in particleParts do
				v.ParticleEmitter.Color = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromHSV(particleColor1.hue, particleColor1.sat, particleColor1.value)),
					ColorSequenceKeypoint.new(1, Color3.fromHSV(hue, sat, val))
				})
			end
		end,
		sub = true,
		visible = false
	})
	particleSize = killaura:slider('Size', {
		min = 0,
		max = 1,
		default = 0.2,
		decimal = 100,
		changed = function(val)
			for _, v in particleParts do
				v.ParticleEmitter.Size = NumberSequence.new(val)
			end
		end,
		sub = true,
		visible = false
	})
	face = killaura:toggle('Face target')
end)
	
--[[ LongJump
Sends you far forward in a long, fast jump. Set the jump speed and whether it turns off when you
land. ]]
run(function()
	local mode
	local amount
	local autoDisable
	
	longJump = blatant:module('LongJump', {
		toggled = function(on)
			if on then
				local exempt = tick() + 0.1
				longJump:clean(runService.PreSimulation:Connect(function(dt)
					if entitylib.isAlive then
						if entitylib.character.Humanoid.FloorMaterial ~= Enum.Material.Air then
							if exempt < tick() and autoDisable.enabled then
								if longJump.enabled then
									longJump:flip()
								end
							else
								entitylib.character.Humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
							end
						end
	
						local root = entitylib.character.RootPart
						local dir = entitylib.character.Humanoid.MoveDirection * amount.value
						if mode.value == 'Velocity' then
							root.AssemblyLinearVelocity = dir + Vector3.new(0, root.AssemblyLinearVelocity.Y, 0)
						elseif mode.value == 'Impulse' then
							local diff = (dir - root.AssemblyLinearVelocity) * Vector3.new(1, 0, 1)
							if diff.Magnitude > (dir == Vector3.zero and 10 or 2) then
								root:ApplyImpulse(diff * root.AssemblyMass)
							end
						else
							root.CFrame += dir * dt
						end
					end
				end))
			end
		end,
		info = function()
			return mode.value
		end,
		about = 'Sends you far forward in a long, fast jump.\nSet the jump speed and whether it turns off when you land.'
	})
	mode = longJump:dropdown('Mode', {
		choices = {'Velocity', 'Impulse', 'CFrame'},
		about = 'Velocity - Uses smooth physics based movement\nImpulse - Same as velocity while using forces instead\nCFrame - Directly adjusts the position of the root'
	})
	amount = longJump:slider('Speed', {
		min = 1,
		max = 150,
		default = 50,
		suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
	autoDisable = longJump:toggle('Auto Disable', {
		default = true
	})
end)
	
--[[ MouseTP
Teleports you to the spot, player or waypoint you point at. Go there instantly, or glide over in
steps. ]]
run(function()
	local mouseTP
	local mode
	local movementMode
	local length
	local delaySlider
	local rayCheck = RaycastParams.new()
	rayCheck.RespectCanCollide = true
	
	local function getWaypointInMouse()
		local obj, dist, location = nil, math.huge, inputService:GetMouseLocation()
	
		for _, v in waypointFolder:GetChildren() do
			local position, vis = gameCamera:WorldToViewportPoint(v.StudsOffsetWorldSpace)
			if not vis then continue end
	
			local mag = (location - Vector2.new(position.x, position.y)).Magnitude
			if mag < dist then
				obj, dist = v, mag
			end
		end
	
		return obj
	end
	
	mouseTP = blatant:module('MouseTP', {
		toggled = function(on)
			if on then
				local position
				if mode.value == 'Mouse' then
					local ray = cloneref(lplr:GetMouse()).UnitRay
					rayCheck.FilterDescendantsInstances = {lplr.Character, gameCamera}
					ray = workspace:Raycast(ray.Origin, ray.Direction * 10000, rayCheck)
					position = ray and ray.Position + Vector3.new(0, entitylib.character.HipHeight or 2, 0)
				elseif mode.value == 'Waypoint' then
					local waypoint = getWaypointInMouse()
					position = waypoint and waypoint.StudsOffsetWorldSpace
				else
					local ent = entitylib.EntityMouse({
						Range = math.huge,
						Part = 'RootPart',
						Players = true
					})
					position = ent and ent.RootPart.Position
				end
	
				if not position then
					notif('MouseTP', 'No position found.', 5)
					mouseTP:flip()
					return
				end
	
				if movementMode.value ~= 'Lerp' then
					mouseTP:flip()
					if entitylib.isAlive then
						if movementMode.value == 'Motor' then
							motorMove(entitylib.character.RootPart, CFrame.lookAlong(position, entitylib.character.RootPart.CFrame.LookVector))
						else
							entitylib.character.RootPart.CFrame = CFrame.lookAlong(position, entitylib.character.RootPart.CFrame.LookVector)
						end
					end
				else
					mouseTP:clean(runService.Heartbeat:Connect(function()
						if entitylib.isAlive then
							entitylib.character.RootPart.Velocity = Vector3.zero
						end
					end))
	
					repeat
						if entitylib.isAlive then
							local direction = CFrame.lookAt(entitylib.character.RootPart.Position, position).LookVector * math.min((entitylib.character.RootPart.Position - position).Magnitude, length.value)
							entitylib.character.RootPart.CFrame += direction
							if (entitylib.character.RootPart.Position - position).Magnitude < 3 and mouseTP.enabled then
								mouseTP:flip()
							end
						elseif mouseTP.enabled then
							mouseTP:flip()
							notif('MouseTP', 'Character missing', 5, 'warning')
						end
	
						task.wait(delaySlider.value)
					until not mouseTP.enabled
				end
			end
		end,
		about = 'Teleports you to the spot, player or waypoint you point at.\nGo there instantly, or glide over in steps.'
	})
	mode = mouseTP:dropdown('Mode', {
		choices = {'Mouse', 'Player', 'Waypoint'}
	})
	movementMode = mouseTP:dropdown('Movement', {
		choices = {'CFrame', 'Motor', 'Lerp'},
		changed = function(val)
			length.row.Visible = val == 'Lerp'
			delaySlider.row.Visible = val == 'Lerp'
		end
	})
	length = mouseTP:slider('Length', {
		min = 0,
		max = 150,
		sub = true,
		visible = false,
		suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
	delaySlider = mouseTP:slider('Delay', {
		min = 0,
		max = 1,
		decimal = 100,
		sub = true,
		visible = false,
		suffix = function(val)
			return val == 1 and 'second' or 'seconds'
		end
	})
end)
	
--[[ Phase
Lets you walk through walls. Part makes the parts around you passable and puts each back once you
leave it; Character makes your own parts passable; CFrame and Motor teleport you through a wall no
thicker than Wall Size; FFlag changes AssemblyExtentsExpansionStudHundredth through setfflag and is
offered only where the executor has it, a saved FFlag falling back to the first mode. With Spider
on, Phase only acts while Shift is held.

Character mode lists your parts once, and again only when the character is replaced or gains or
loses a piece, sparing a GetDescendants and an IsA per piece every step. While AutoWin runs, Phase
stays on but releases everything: AutoWin walks on the blocks it plans around, and every mode put
the body inside them (suffocation). phase.autoWinAware tells AutoWin that Phase holds off by itself,
so it is left switched on. ]]
run(function()
	local mode
	local studLimit = {row = {}}
	local rayCheck = RaycastParams.new()
	rayCheck.RespectCanCollide = true
	local overlapCheck = OverlapParams.new()
	overlapCheck.MaxParts = 9e9
	local modified, fflag = {}
	local teleported
	local inBox = {}
	local charParts, charPartsOf, charPartsStale = {}, nil, true
	local charWatch = {}

	local function dropCharacterParts()
		for _, connection in charWatch do
			connection:Disconnect()
		end
		table.clear(charWatch)
		table.clear(charParts)
		charPartsOf, charPartsStale = nil, true
	end

	local function characterParts(char)
		if char ~= charPartsOf then
			dropCharacterParts()
			charPartsOf = char
			local function markStale()
				charPartsStale = true
			end
			table.insert(charWatch, char.DescendantAdded:Connect(markStale))
			table.insert(charWatch, char.DescendantRemoving:Connect(markStale))
		end
		if charPartsStale then
			charPartsStale = false
			table.clear(charParts)
			for _, part in char:GetDescendants() do
				if part:IsA('BasePart') then
					table.insert(charParts, part)
				end
			end
		end
		return charParts
	end

	local function grabClosestNormal(ray)
		local partCF, mag, closest = ray.Instance.CFrame, 0, Enum.NormalId.Top
	
		for _, normal in Enum.NormalId:GetEnumItems() do
			local dot = partCF:VectorToWorldSpace(Vector3.fromNormalId(normal)):Dot(ray.Normal)
			if dot > mag then
				mag, closest = dot, normal
			end
		end
	
		return Vector3.fromNormalId(closest).X ~= 0 and 'X' or 'Z'
	end

	local function releasePhase()
		if fflag then
			setfflag('AssemblyExtentsExpansionStudHundredth', '30')
		end
		for part in modified do
			part.CanCollide = true
		end
		table.clear(modified)
		table.clear(inBox)
		dropCharacterParts()
		fflag = nil
	end

	local function heldByAutoWin()
		local autoWin = slinky.modules.AutoWin
		return autoWin ~= nil and autoWin.enabled == true
	end

	local functions = {
		Part = function()
			local chars = {gameCamera, lplr.Character}
			for _, v in entitylib.List do
				table.insert(chars, v.Character)
			end
			setFilter(overlapCheck, chars)

			local parts = workspace:GetPartBoundsInBox(entitylib.character.RootPart.CFrame + Vector3.new(0, 1, 0), entitylib.character.RootPart.Size + Vector3.new(7, entitylib.character.HipHeight, 7), overlapCheck)
			table.clear(inBox)
			for _, part in parts do
				inBox[part] = true
				if part.CanCollide and (not spider.enabled or spiderShift) then
					modified[part] = true
					part.CanCollide = false
				end
			end

			for part in modified do
				if not inBox[part] then
					modified[part] = nil
					part.CanCollide = true
				end
			end
		end,
		Character = function()
			for _, part in characterParts(lplr.Character) do
				if part.CanCollide and (not spider.enabled or spiderShift) then
					modified[part] = true
					part.CanCollide = spider.enabled and not spiderShift
				end
			end
		end,
		CFrame = function()
			local chars = {gameCamera, lplr.Character}
			for _, v in entitylib.List do
				table.insert(chars, v.Character)
			end
			setFilter(rayCheck, chars)
			setFilter(overlapCheck, chars)
	
			local ray = workspace:Raycast(entitylib.character.Head.CFrame.Position, entitylib.character.Humanoid.MoveDirection * 1.1, rayCheck)
			if ray and (not spider.enabled or spiderShift) then
				local phaseDirection = grabClosestNormal(ray)
				if ray.Instance.Size[phaseDirection] <= studLimit.value then
					local root = entitylib.character.RootPart
					local dest = root.CFrame + (ray.Normal * (-(ray.Instance.Size[phaseDirection]) - (root.Size.X / 1.5)))
	
					if #workspace:GetPartBoundsInBox(dest, Vector3.one, overlapCheck) <= 0 then
						if mode.value == 'Motor' then
							motorMove(root, dest)
						else
							root.CFrame = dest
						end
					end
				end
			end
		end,
		FFlag = function()
			if teleported then return end
			setfflag('AssemblyExtentsExpansionStudHundredth', '-10000')
			fflag = true
		end
	}
	functions.Motor = functions.CFrame
	
	phase = blatant:module('Phase', {
		info = function()
			return mode and mode.value or nil
		end,
		toggled = function(on)
			if on then
				phase:clean(runService.Stepped:Connect(function()
					if heldByAutoWin() then
						releasePhase()
					elseif entitylib.isAlive then
						functions[mode.value]()
					end
				end))
	
				if mode.value == 'FFlag' then
					phase:clean(lplr.OnTeleport:Connect(function()
						teleported = true
						setfflag('AssemblyExtentsExpansionStudHundredth', '30')
					end))
				end
			else
				releasePhase()
			end
		end,
		about = 'Lets you walk through walls.\nChoose how it gets you through and the thickest wall it will pass.'
	})
	phase.autoWinAware = true
	local modeList = {'Part', 'Character', 'CFrame', 'Motor'}
	local modeTips = 'Part - Modifies parts collision status around you\nCharacter - Modifies the local collision status of the character\nCFrame - Teleports you past parts\nMotor - Same as CFrame with a bypass'
	if exec.FFlag then
		table.insert(modeList, 'FFlag')
		modeTips ..= '\nFFlag - Directly adjusts all physics collisions'
	end
	mode = phase:dropdown('Mode', {
		choices = modeList,
		changed = function(val)
			studLimit.row.Visible = val == 'CFrame' or val == 'Motor'
			releasePhase()
		end,
		about = modeTips
	})
	studLimit = phase:slider('Wall Size', {
		min = 1,
		max = 20,
		default = 5,
		suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end,
		sub = true,
		visible = false
	})
end)
	
--[[ Speed
Makes you move faster than normal. Pick a movement style and speed, with optional auto jumping. ]]
run(function()
	local speed
	local customProperties
	local mode
	local options
	local autoJump
	local autoJumpCustom
	local autoJumpValue
	local w, s, a, d = 0, 0, 0, 0
	
	speed = blatant:module('Speed', {
		toggled = function(on)
			frictionTable.Speed = on and customProperties.enabled or nil
			updateVelocity()
			if on then
				speed:clean(runService.PreSimulation:Connect(function(dt)
					if entitylib.isAlive and not fly.enabled and not longJump.enabled then
						local state = entitylib.character.Humanoid:GetState()
						if state == Enum.HumanoidStateType.Climbing then return end
	
						local movevec = targetStrafeVector or options.MoveMethod.value == 'Direct' and calculateMoveVector(Vector3.new(a + d, 0, w + s)) or entitylib.character.Humanoid.MoveDirection
						speedMethods[mode.value](options, movevec, dt)
						if autoJump.enabled and entitylib.character.Humanoid.FloorMaterial ~= Enum.Material.Air and movevec ~= Vector3.zero then
							if autoJumpCustom.enabled then
								local velocity = entitylib.character.RootPart.Velocity * Vector3.new(1, 0, 1)
								entitylib.character.RootPart.Velocity = Vector3.new(velocity.X, autoJumpValue.value, velocity.Z)
							else
								entitylib.character.Humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
							end
						end
					end
				end))
	
				w, s, a, d = inputService:IsKeyDown(Enum.KeyCode.W) and -1 or 0, inputService:IsKeyDown(Enum.KeyCode.S) and 1 or 0, inputService:IsKeyDown(Enum.KeyCode.A) and -1 or 0, inputService:IsKeyDown(Enum.KeyCode.D) and 1 or 0
				for _, v in {'InputBegan', 'InputEnded'} do
					speed:clean(inputService[v]:Connect(function(input)
						if not inputService:GetFocusedTextBox() then
							if input.KeyCode == Enum.KeyCode.W then
								w = v == 'InputBegan' and -1 or 0
							elseif input.KeyCode == Enum.KeyCode.S then
								s = v == 'InputBegan' and 1 or 0
							elseif input.KeyCode == Enum.KeyCode.A then
								a = v == 'InputBegan' and -1 or 0
							elseif input.KeyCode == Enum.KeyCode.D then
								d = v == 'InputBegan' and 1 or 0
							end
						end
					end))
				end
			else
				if options.WalkSpeed and entitylib.isAlive then
					entitylib.character.Humanoid.WalkSpeed = options.WalkSpeed
				end
				options.WalkSpeed = nil
			end
		end,
		info = function()
			return mode.value
		end,
		about = 'Makes you move faster than normal.\nPick a movement style and speed, with optional auto jumping.'
	})
	mode = speed:dropdown('Mode', {
		choices = speedMethodList,
		changed = function(val)
			options.WallCheck.row.Visible = val == 'CFrame' or val == 'TP'
			options.TPFrequency.row.Visible = val == 'TP'
			options.PulseLength.row.Visible = val == 'Pulse'
			options.PulseDelay.row.Visible = val == 'Pulse'
			if speed.enabled then
				speed:flip()
				speed:flip()
			end
		end,
		about = 'Velocity - Uses smooth physics based movement\nImpulse - Same as velocity while using forces instead\nCFrame - Directly adjusts the position of the root\nTP - Large teleports within intervals\nPulse - Controllable bursts of speed\nWalkSpeed - The classic mode of speed, usually detected on most games.'
	})
	options = {
		MoveMethod = speed:dropdown('Move Mode', {
			choices = {'MoveDirection', 'Direct'},
			about = 'MoveDirection - Uses the games input vector for movement\nDirect - Directly calculate our own input vector'
		}),
		Value = speed:slider('Speed', {
			min = 1,
			max = 150,
			default = 50,
			suffix = function(val)
				return val == 1 and 'stud' or 'studs'
			end
		}),
		TPFrequency = speed:slider('TP Frequency', {
			min = 0,
			max = 1,
			decimal = 100,
			sub = true,
			visible = false,
			suffix = function(val)
				return val == 1 and 'second' or 'seconds'
			end
		}),
		PulseLength = speed:slider('Pulse Length', {
			min = 0,
			max = 1,
			decimal = 100,
			sub = true,
			visible = false,
			suffix = function(val)
				return val == 1 and 'second' or 'seconds'
			end
		}),
		PulseDelay = speed:slider('Pulse Delay', {
			min = 0,
			max = 1,
			decimal = 100,
			sub = true,
			visible = false,
			suffix = function(val)
				return val == 1 and 'second' or 'seconds'
			end
		}),
		WallCheck = speed:toggle('Wall Check', {
			default = true,
			sub = true,
			visible = false
		}),
		TPTiming = tick(),
		rayCheck = RaycastParams.new()
	}
	options.rayCheck.RespectCanCollide = true
	customProperties = speed:toggle('Custom Properties', {
		changed = function()
			if speed.enabled then
				speed:flip()
				speed:flip()
			end
		end,
		default = true
	})
	autoJump = speed:toggle('AutoJump', {
		changed = function(callback)
			autoJumpCustom.row.Visible = callback
		end
	})
	autoJumpCustom = speed:toggle('Custom Jump', {
		changed = function(callback)
			autoJumpValue.row.Visible = callback
		end,
		about = 'Allows you to adjust the jump power',
		sub = true,
		visible = false
	})
	autoJumpValue = speed:slider('Jump Power', {
		min = 1,
		max = 50,
		default = 30,
		sub = true,
		visible = false
	})
end)
	
--[[ Spider
Lets you climb straight up walls: walking into a wall pushes you up by velocity, impulse or CFrame,
or Part keeps an invisible truss in front of you. With Phase on, holding Shift lets Phase take the
wall instead. While AutoWin is on, Spider stays on but holds off except for the climbs AutoWin picks
through spider.autoWinClimb; spider.autoWinAware tells AutoWin so. A reinject empties the old slinky
table, so a loop that outlived its injection (started again by AutoWin mid-unload) disconnects
itself instead of erroring every physics step. ]]
run(function()
	local mode
	local amount
	local state
	local rayCheck = RaycastParams.new()
	rayCheck.RespectCanCollide = true
	local active, truss
	local trussAt, trussPos

	local function placeTruss(pos)
		if trussAt ~= truss or trussPos ~= pos then
			truss.Position = pos
			trussAt, trussPos = truss, pos
		end
	end

	local function heldByAutoWin()
		local modules = slinky.modules
		local autoWin = modules and modules.AutoWin
		return autoWin ~= nil and autoWin.enabled == true and not spider.autoWinClimb
	end

	spider = blatant:module('Spider', {
		info = function()
			return mode and mode.value or nil
		end,
		toggled = function(on)
			if on then
				if truss then
					truss.Parent = gameCamera
				end

				local loop
				loop = runService.PreSimulation:Connect(function(dt)
					if slinky.loaded == nil then
						loop:Disconnect()
						return
					end
					if heldByAutoWin() then
						active = nil
						if truss then
							placeTruss(Vector3.zero)
						end
					elseif entitylib.isAlive then
						local root = entitylib.character.RootPart
						local chars = {gameCamera, lplr.Character, truss}
						for _, v in entitylib.List do
							table.insert(chars, v.Character)
						end

						spiderShift = inputService:IsKeyDown(Enum.KeyCode.LeftShift)
						setFilter(rayCheck, chars)
						rayCheck.CollisionGroup = root.CollisionGroup
	
						if mode.value ~= 'Part' then
							local vec = entitylib.character.Humanoid.MoveDirection * 2.5
							local ray = workspace:Raycast(root.Position - Vector3.new(0, entitylib.character.HipHeight - 0.5, 0), vec, rayCheck)
							if active and not ray then
								root.Velocity = Vector3.new(root.Velocity.X, 0, root.Velocity.Z)
							end
	
							active = ray
							if active and ray.Normal.Y == 0 then
								if not phase.enabled or not spiderShift then
									if state.enabled then
										entitylib.character.Humanoid:ChangeState(Enum.HumanoidStateType.Climbing)
									end
	
									root.Velocity *= Vector3.new(1, 0, 1)
									if mode.value == 'CFrame' then
										root.CFrame += Vector3.new(0, amount.value * dt, 0)
									elseif mode.value == 'Impulse' then
										root:ApplyImpulse(Vector3.new(0, amount.value, 0) * root.AssemblyMass)
									else
										root.Velocity += Vector3.new(0, amount.value, 0)
									end
								end
							end
						else
							local ray = workspace:Raycast(root.Position - Vector3.new(0, entitylib.character.HipHeight - 0.5, 0), entitylib.character.RootPart.CFrame.LookVector * 2, rayCheck)
							if ray and (not phase.enabled or not spiderShift) then
								placeTruss(ray.Position - ray.Normal * 0.9 or Vector3.zero)
							else
								placeTruss(Vector3.zero)
							end
						end
					end
				end)
				spider:clean(loop)
			else
				if truss then
					truss.Parent = nil
				end
				spiderShift = false
			end
		end,
		about = 'Lets you climb straight up walls.\nWalk into a wall to climb it; set the climbing style and speed.'
	})
	spider.autoWinAware = true
	mode = spider:dropdown('Mode', {
		choices = {'Velocity', 'Impulse', 'CFrame', 'Part'},
		changed = function(val)
			amount.row.Visible = val ~= 'Part'
			state.row.Visible = val ~= 'Part'
			if truss then
				truss:Destroy()
				truss = nil
			end
			if val == 'Part' then
				truss = Instance.new('TrussPart')
				truss.Size = Vector3.new(2, 2, 2)
				truss.Transparency = 1
				truss.Anchored = true
				truss.Parent = spider.enabled and gameCamera or nil
			end
		end,
		about = 'Velocity - Uses smooth movement to boost you upward\nCFrame - Directly adjusts the position upward\nPart - Positions a climbable part infront of you'
	})
	amount = spider:slider('Speed', {
		min = 0,
		max = 100,
		default = 30,
		sub = true,
		suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
	state = spider:toggle('Climb State', {
		sub = true
	})
end)
	
--[[ SpinBot
Makes your character spin around in circles. Set the spin speed and which ways it turns. ]]
run(function()
	local spinBot
	local mode
	local xToggle
	local yToggle
	local zToggle
	local amount
	local angularVelocity
	
	spinBot = blatant:module('SpinBot', {
		toggled = function(on)
			if on then
				spinBot:clean(runService.PreSimulation:Connect(function()
					if entitylib.isAlive then
						if mode.value == 'RotVelocity' then
							local originalRotVelocity = entitylib.character.RootPart.RotVelocity
							entitylib.character.Humanoid.AutoRotate = false
							entitylib.character.RootPart.RotVelocity = Vector3.new(xToggle.enabled and amount.value or originalRotVelocity.X, yToggle.enabled and amount.value or originalRotVelocity.Y, zToggle.enabled and amount.value or originalRotVelocity.Z)
						elseif mode.value == 'CFrame' then
							local val = math.rad((tick() * (20 * amount.value)) % 360)
							local x, y, z = entitylib.character.RootPart.CFrame:ToOrientation()
							entitylib.character.RootPart.CFrame = CFrame.new(entitylib.character.RootPart.Position) * CFrame.Angles(xToggle.enabled and val or x, yToggle.enabled and val or y, zToggle.enabled and val or z)
						elseif angularVelocity then
							angularVelocity.Parent = entitylib.isAlive and entitylib.character.RootPart
							angularVelocity.MaxTorque = Vector3.new(xToggle.enabled and math.huge or 0, yToggle.enabled and math.huge or 0, zToggle.enabled and math.huge or 0)
							angularVelocity.AngularVelocity = Vector3.new(amount.value, amount.value, amount.value)
						end
					end
				end))
			else
				if entitylib.isAlive and mode.value == 'RotVelocity' then
					entitylib.character.Humanoid.AutoRotate = true
				end
	
				if angularVelocity then
					angularVelocity.Parent = nil
				end
			end
		end,
		about = 'Makes your character spin around in circles.\nSet the spin speed and which ways it turns.'
	})
	mode = spinBot:dropdown('Mode', {
		choices = {'CFrame', 'RotVelocity', 'BodyMover'},
		changed = function(val)
			if angularVelocity then
				angularVelocity:Destroy()
				angularVelocity = nil
			end
			angularVelocity = val == 'BodyMover' and Instance.new('BodyAngularVelocity') or nil
		end
	})
	amount = spinBot:slider('Speed', {
		min = 1,
		max = 100,
		default = 40
	})
	xToggle = spinBot:toggle('Spin X')
	yToggle = spinBot:toggle('Spin Y', {
		default = true
	})
	zToggle = spinBot:toggle('Spin Z')
end)
	
--[[ Swim
Lets you swim through the air as if it were water. ]]
run(function()
	local swim
	local terrain = cloneref(workspace:FindFirstChildWhichIsA('Terrain'))
	local lastpos = Region3.new(Vector3.zero, Vector3.zero)
	
	swim = blatant:module('Swim', {
		toggled = function(on)
			if on then
				swim:clean(runService.PreSimulation:Connect(function(dt)
					if entitylib.isAlive then
						local root = entitylib.character.RootPart
						local moving = entitylib.character.Humanoid.MoveDirection ~= Vector3.zero
						local rootvelo = root.Velocity
						local space = inputService:IsKeyDown(Enum.KeyCode.Space)
	
						if terrain then
							local factor = (moving or space) and Vector3.new(6, 6, 6) or Vector3.new(2, 1, 2)
							local pos = root.Position - Vector3.new(0, 1, 0)
							local newpos = Region3.new(pos - factor, pos + factor):ExpandToGrid(4)
							terrain:ReplaceMaterial(lastpos, 4, Enum.Material.Water, Enum.Material.Air)
							terrain:FillRegion(newpos, 4, Enum.Material.Water)
							lastpos = newpos
						end
					end
				end))
			else
				if terrain and lastpos then
					terrain:ReplaceMaterial(lastpos, 4, Enum.Material.Water, Enum.Material.Air)
				end
			end
		end,
		about = 'Lets you swim through the air as if it were water.'
	})
end)
	
--[[ TargetStrafe
Circles you around the nearest target in Search Range while you move, at Strafe Range less the
height gap times Y Factor, sliding along walls and pulling in where the circle has no ground below
(unless Fly is on). Holding S stops it. It wraps the movement function of PlayerModule's controls.
SafeWalk and AutoWin wrap the same slot, so turning off puts the previous function back only while
this hook is still the top of the chain; otherwise the hook stays as a pass-through, and the
wrappers above it keep a working previous function. ]]
run(function()
	local targetStrafe
	local targets
	local searchRange
	local strafeRange
	local yFactor
	local rayCheck = RaycastParams.new()
	rayCheck.RespectCanCollide = true
	local module, current

	targetStrafe = blatant:module('TargetStrafe', {
		info = function()
			return strafeRange and tostring(strafeRange.value) or nil
		end,
		toggled = function(on)
			if on then
				if not module then
					local suc = pcall(function() module = require(lplr.PlayerScripts.PlayerModule).controls end)
					if not suc then module = nil end
				end

				local old = module and module.moveFunction
				if type(old) ~= 'function' then
					module = nil
					return
				end
				local state = {Active = true, Previous = old}
				current = state
				local flymod, ang, oldent = slinky.modules.Fly or {enabled = false}
				state.Hook = function(self, vec, face)
					if not state.Active or entitylib == nil then
						return old(self, vec, face)
					end
					local wallcheck = targets.walls.enabled
					local ent = not inputService:IsKeyDown(Enum.KeyCode.S) and entitylib.EntityPosition({
						Range = searchRange.value,
						Wallcheck = wallcheck,
						Part = 'RootPart',
						Players = targets.players.enabled,
						NPCs = targets.npcs.enabled
					})
	
					if ent then
						local root, targetPos = entitylib.character.RootPart, ent.RootPart.Position
						rayCheck.FilterDescendantsInstances = {lplr.Character, gameCamera, ent.Character}
						rayCheck.CollisionGroup = root.CollisionGroup
	
						if flymod.enabled or workspace:Raycast(targetPos, Vector3.new(0, -70, 0), rayCheck) then
							local factor, localPosition = 0, root.Position
							if ent ~= oldent then
								ang = math.deg(select(2, CFrame.lookAt(targetPos, localPosition):ToEulerAnglesYXZ()))
							end
	
							local yFactor = math.abs(localPosition.Y - targetPos.Y) * (yFactor.value / 100)
							local entityPos = Vector3.new(targetPos.X, localPosition.Y, targetPos.Z)
							local newPos = entityPos + (CFrame.Angles(0, math.rad(ang), 0).LookVector * (strafeRange.value - yFactor))
							local startRay, endRay = entityPos, newPos
	
							if not wallcheck and workspace:Raycast(targetPos, (localPosition - targetPos), rayCheck) then
								startRay, endRay = entityPos + (CFrame.Angles(0, math.rad(ang), 0).LookVector * (entityPos - localPosition).Magnitude), entityPos
							end
	
							local ray = workspace:Blockcast(CFrame.new(startRay), Vector3.new(1, entitylib.character.HipHeight + (root.Size.Y / 2), 1), (endRay - startRay), rayCheck)
							if (localPosition - newPos).Magnitude < 3 or ray then
								factor = (8 - math.min((localPosition - newPos).Magnitude, 3))
								if ray then
									newPos = ray.Position + (ray.Normal * 1.5)
									factor = (localPosition - newPos).Magnitude > 3 and 0 or factor
								end
							end
	
							if not flymod.enabled and not workspace:Raycast(newPos, Vector3.new(0, -70, 0), rayCheck) then
								newPos = entityPos
								factor = 40
							end
	
							ang += factor % 360
							vec = ((newPos - localPosition) * Vector3.new(1, 0, 1)).Unit
							vec = vec == vec and vec or Vector3.zero
							targetStrafeVector = vec
						else
							ent = nil
						end
					end
	
					targetStrafeVector = ent and vec or nil
					oldent = ent

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
				targetStrafeVector = nil
			end
		end,
		about = 'Circles you around the nearest enemy while you move.\nSet how far it looks and how wide it circles. Hold S to stop.'
	})
	targets = targetStrafe:targets({
		players = true,
		walls = true
	})
	searchRange = targetStrafe:slider('Search Range', {
		min = 1,
		max = 30,
		default = 24,
		suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
	strafeRange = targetStrafe:slider('Strafe Range', {
		min = 1,
		max = 30,
		default = 18,
		suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
	yFactor = targetStrafe:slider('Y Factor', {
		min = 0,
		max = 100,
		default = 100,
		suffix = '%'
	})
end)
	
--[[ Timer
Runs your character's physics faster: every frame the root gets an extra StepPhysics of the frame
time times (Speed - 1), between Pause and Run, with the SimEnableStepPhysics flags set through
setfflag. On Solara and Xeno the same step runs at the raised identity and guarded, Run always
following a Pause that went through. The first refusal (no setfflag, a flag that did not take, or
too low an identity for Pause or StepPhysics) switches to emulateStep, which adds the root's
velocity over the extra time after physics, with gravity on that velocity while airborne. ]]
run(function()
	local timer
	local amount

	local function emulateStep(dt)
		if not entitylib.isAlive then return end
		local root = entitylib.character.RootPart
		local extra = dt * (amount.value - 1)
		local velocity = root.AssemblyLinearVelocity
		if entitylib.character.Humanoid.FloorMaterial == Enum.Material.Air then
			velocity += Vector3.new(0, -workspace.Gravity * extra, 0)
			root.AssemblyLinearVelocity = velocity
		end
		root.CFrame += velocity * extra
	end

	timer = blatant:module('Timer', {
		info = function()
			return amount and amount.value..'x' or nil
		end,
		toggled = function(on)
			if on then
				if not hookExecutor then
					local stepping = exec.FFlag and pcall(setfflag, 'SimEnableStepPhysics', 'True') and pcall(setfflag, 'SimEnableStepPhysicsSelective', 'True')
					timer:clean(runService.RenderStepped:Connect(function(dt)
						if stepping and amount.value > 1 and entitylib.isAlive then
							if exec.Identity then
								pcall(setthreadidentity, 8)
							end
							local paused = pcall(runService.Pause, runService)
							stepping = paused and pcall(function()
								workspace:StepPhysics(dt * (amount.value - 1), {entitylib.character.RootPart})
							end)
							if paused then
								pcall(runService.Run, runService)
							end
						end
					end))
					timer:clean(runService.Heartbeat:Connect(function(dt)
						if not stepping and amount.value > 1 then
							emulateStep(dt)
						end
					end))
					return
				end
				setfflag('SimEnableStepPhysics', 'True')
				setfflag('SimEnableStepPhysicsSelective', 'True')

				timer:clean(runService.RenderStepped:Connect(function(dt)
					if amount.value > 1 then
						runService:Pause()
						workspace:StepPhysics(dt * (amount.value - 1), {entitylib.character.RootPart})
						runService:Run()
					end
				end))
			end
		end,
		about = 'Speeds up your character, as if the game ran faster.\nSet how many times faster, up to 3x.'
	})
	amount = timer:slider('Value', {
		label = 'Speed',
		min = 1,
		max = 3,
		decimal = 10
	})
end)
	
--[[ Arrows
Draws a ring of pointers around the crosshair towards other players (shown as Pointers). The closest
enemy's pointer can take its own colour and is drawn over the others; someone else has to be 1 stud
nearer to take it, so two players at about the same distance do not make it flicker. The closest is
picked before Ignore within FOV, so when they are inside the ignored view no pointer has it. Only a
living player can be the closest. Teammates get a pointer too, hidden each frame while Hide
friendlies is on, because BedWars sets a player's team after they are added.

The dart is Slinky's: measured from the middle of its back edge in lengths, the tip 1 out, the back
corners 0.45 to each side, the notch 0.25 in; 14 px long at Scale 1 on a 1080 px tall screen,
outlined 1.25 px past the fill at a tenth of its colour. It is two filled Triangles split from tip
to notch (executors do not all fill a concave Quad alike) over a thick unfilled Quad for the
outline, with a Line down the split so the background does not show through between them. Without
Triangles a text glyph is drawn instead. Transition between defaults to Slinky's 10 to 50 blocks, in
studs (a block is 3). Distance-based radius puts the far end 0.85 further out, about 1.8x the near
ring, and the ring is capped so the whole dart stays on screen. 3D tips the ring by the pitch: half
its height looking level, up or less than 42 degrees down, opening out towards round as you look
further down.

Everything runs at the raised identity: where Drawing is built from GUI objects (phone executors
like Delta) a write without it can fail, and a RenderStepped callback does not always carry it.
Values are written only when they change and noted only after the write went through. Making the
drawings can yield, so the player is checked again afterwards. A pointer that fails is hidden for
the frame without stopping the others. Range, Ignore within FOV, Radius, Style and Distance-based
radius are saved under new names because every profile holds the old defaults. ]]
run(function()
	local arrows
	local targets
	local range
	local ignoreFOV
	local scale
	local radius
	local style
	local colorMode
	local color
	local friendColor
	local nearColor
	local farColor
	local transition
	local teammates
	local distanceRadius
	local closest
	local closestColor
	local closestEnt
	local reference = {}
	local folder = Instance.new('Folder')
	folder.Parent = slinky.gui
	local DART = {Length = 14, HalfWidth = 0.45, Notch = 0.25, Shade = 0.1, Outline = 2.5}
	local RANGE_MAX = 1024
	local CLOSEST_MARGIN = 1
	local FAR_SPREAD = 0.85

	local function raiseIdentity()
		if slinky.threadFix and not pcall(setthreadidentity, 8) then
			pcall(setthreadidentity, 7)
		end
	end

	local function applyProps(object, props)
		for key, value in props do
			object[key] = value
		end
	end

	local function newDrawing(class, props)
		local ok, object = pcall(function()
			return Drawing.new(class)
		end)
		if not ok or object == nil then return nil end
		if not pcall(applyProps, object, props) then
			pcall(function()
				object:Remove()
			end)
			return nil
		end
		return object
	end

	local function newPointer()
		local half = {Filled = true, Thickness = 1, Transparency = 1, ZIndex = 2, Visible = false}
		local right, left = newDrawing('Triangle', half), newDrawing('Triangle', half)
		if right and left then
			local outline = newDrawing('Quad', {Filled = false, Thickness = DART.Outline, Transparency = 1, ZIndex = 1, Visible = false})
			local seam = newDrawing('Line', {Thickness = 1, Transparency = 1, ZIndex = 2, Visible = false})
			return {Right = right, Left = left, Outline = outline, Seam = seam, Visible = false, Layer = 0}
		end
		if right then
			pcall(function() right:Remove() end)
		end
		if left then
			pcall(function() left:Remove() end)
		end
		local arrow = Instance.new('TextLabel')
		arrow.AnchorPoint = Vector2.new(0.5, 0.5)
		arrow.BackgroundTransparency = 1
		arrow.BorderSizePixel = 0
		arrow.Size = UDim2.fromOffset(24, 24)
		arrow.Text = '\u{25B2}'
		arrow.TextStrokeTransparency = 0.4
		arrow.Visible = false
		slinky.libraries.fonts.track(arrow, 'Bold')
		arrow.Parent = folder
		return {Image = arrow, Visible = false}
	end

	local function setVisible(pointer, visible)
		if pointer.Visible == visible then return end
		if pointer.Image then
			pointer.Image.Visible = visible
		else
			pointer.Right.Visible = visible
			pointer.Left.Visible = visible
			if pointer.Outline then
				pointer.Outline.Visible = visible
			end
			if pointer.Seam then
				pointer.Seam.Visible = visible
			end
		end
		pointer.Visible = visible
	end

	local function dropPointer(pointer)
		if pointer.Image then
			pcall(function()
				pointer.Image:Destroy()
			end)
			return
		end
		for _, key in {'Right', 'Left', 'Outline', 'Seam'} do
			local object = pointer[key]
			if object then
				pcall(function()
					object.Visible = false
					object:Remove()
				end)
			end
		end
	end

	local function added(ent)
		if not targets.players.enabled and ent.Player then return end
		if not targets.npcs.enabled and ent.NPC then return end
		raiseIdentity()
		local pointer = newPointer()
		if arrows.enabled and not reference[ent] and table.find(entitylib.List, ent) then
			reference[ent] = pointer
		else
			dropPointer(pointer)
		end
	end

	local function removed(ent)
		local pointer = reference[ent]
		if pointer then
			raiseIdentity()
			reference[ent] = nil
			if closestEnt == ent then
				closestEnt = nil
			end
			dropPointer(pointer)
		end
	end

	local function hsv(option)
		return Color3.fromHSV(option.hue, option.sat, option.value)
	end

	local function closestCandidate(ent)
		return ent.Player ~= nil and ent.Targetable and not ent.Friend and not (type(ent.Health) == 'number' and ent.Health <= 0)
	end

	local function farness(distance)
		local span = math.max(transition.max - transition.min, 1)
		return math.clamp((distance - transition.min) / span, 0, 1)
	end

	local frame = {}

	local function drawPointer(ent, pointer)
		local distance = pointer.Distance
		if not distance then
			setVisible(pointer, false)
			return
		end

		local relative = frame.Basis:PointToObjectSpace(pointer.Position)
		local angle = math.atan2(relative.X, -relative.Z)
		if math.deg(math.abs(angle)) < frame.HalfFov then
			setVisible(pointer, false)
			return
		end

		local t = farness(distance)
		local closestColor = frame.ClosestColor
		local color
		if closestColor and ent == closestEnt then
			color = closestColor
		elseif frame.Mode == 'Distance' then
			color = frame.Near:Lerp(frame.Far, t)
		elseif frame.Mode == 'Name Tag' then
			color = entitylib.getEntityColor(ent) or Color3.new(1, 1, 1)
		else
			color = (ent.Friend or not ent.Targetable) and frame.FriendColor or frame.EnemyColor
		end

		local center, squash, length = frame.Center, frame.Squash, frame.Length
		local radius = frame.BaseRadius
		if distanceRadius.enabled then
			radius += radius * FAR_SPREAD * t
		end
		radius = math.min(radius, frame.MaxRadius)
		if pointer.Image then
			local arrow = pointer.Image
			local dir = Vector2.new(math.sin(angle), -math.cos(angle))
			local at = center + dir * (radius + length * 0.5) * squash
			arrow.Position = UDim2.fromOffset(at.X, at.Y)
			arrow.Rotation = math.deg(angle)
			arrow.TextSize = math.max(length * 1.2, 8)
			if arrow.TextColor3 ~= color then
				arrow.TextColor3 = color
			end
			setVisible(pointer, true)
			return
		end
		local dir = Vector2.new(math.sin(angle), -math.cos(angle))
		local side = Vector2.new(-dir.Y, dir.X) * frame.HalfWidth
		local back = dir * radius
		local tip = center + dir * (radius + length) * squash
		local notch = center + dir * (radius + frame.NotchAt) * squash
		local wingR = center + (back + side) * squash
		local wingL = center + (back - side) * squash
		if tip ~= pointer.Tip or notch ~= pointer.Notch or wingR ~= pointer.WingR or wingL ~= pointer.WingL then
			local right, left, outline = pointer.Right, pointer.Left, pointer.Outline
			right.PointA, right.PointB, right.PointC = tip, wingR, notch
			left.PointA, left.PointB, left.PointC = tip, notch, wingL
			if outline then
				outline.PointA, outline.PointB, outline.PointC, outline.PointD = tip, wingR, notch, wingL
			end
			local seam = pointer.Seam
			if seam then
				local along = tip - notch
				local span = along.Magnitude
				if span > 3 then
					local unit = along / span
					seam.From, seam.To = notch + unit * 0.5, tip - unit
				else
					seam.From, seam.To = notch, notch
				end
			end
			pointer.Tip, pointer.Notch, pointer.WingR, pointer.WingL = tip, notch, wingR, wingL
		end
		if color ~= pointer.Color then
			pointer.Right.Color = color
			pointer.Left.Color = color
			if pointer.Seam then
				pointer.Seam.Color = color
			end
			if pointer.Outline then
				pointer.Outline.Color = Color3.new(color.R * DART.Shade, color.G * DART.Shade, color.B * DART.Shade)
			end
			pointer.Color = color
		end
		local layer = closestColor and ent == closestEnt and 2 or 0
		if layer ~= pointer.Layer then
			pointer.Right.ZIndex, pointer.Left.ZIndex = 2 + layer, 2 + layer
			if pointer.Seam then
				pointer.Seam.ZIndex = 2 + layer
			end
			if pointer.Outline then
				pointer.Outline.ZIndex = 1 + layer
			end
			pointer.Layer = layer
		end
		setVisible(pointer, true)
	end

	local function loop()
		raiseIdentity()
		if clickGuiOpen() then
			for _, pointer in reference do
				pcall(setVisible, pointer, false)
			end
			return
		end
		local camCF = gameCamera.CFrame
		local viewport = gameCamera.ViewportSize
		local center = viewport / 2
		local look = camCF.LookVector
		local flat = look * Vector3.new(1, 0, 1)
		if flat.Magnitude < 1e-3 then
			flat = camCF.UpVector * Vector3.new(1, 0, 1) * (look.Y > 0 and -1 or 1)
		end
		local basis = CFrame.lookAlong(camCF.Position, flat.Unit)
		local origin = entitylib.isAlive and entitylib.character.RootPart.Position or camCF.Position
		local maxRange = range.value >= RANGE_MAX and math.huge or range.value

		local hideFriendlies = teammates.enabled
		local best, bestDistance = nil, math.huge
		for ent, pointer in reference do
			local root = ent.RootPart
			local position = root and root.Parent and root.Position
			local distance = position and (origin - position).Magnitude
			if distance and (distance > maxRange or (hideFriendlies and (ent.Friend or not ent.Targetable))) then
				distance = nil
			end
			pointer.Distance, pointer.Position = distance, position
			if distance and distance < bestDistance and closestCandidate(ent) then
				best, bestDistance = ent, distance
			end
		end
		local held = closestEnt and reference[closestEnt]
		if best and held and held.Distance and closestCandidate(closestEnt) and held.Distance <= bestDistance + CLOSEST_MARGIN then
			best = closestEnt
		end
		closestEnt = best

		local px = math.clamp(viewport.Y / 1080, 0.5, 2)
		local length = DART.Length * scale.value * px
		local yScale = 1
		if style.value == '3D' then
			local pitch = -math.deg(math.asin(math.clamp(look.Y, -1, 1)))
			yScale = math.cos(math.rad(math.clamp(pitch, 42, 90) - 102))
		end
		frame.Basis = basis
		frame.Center = center
		frame.Length = length
		frame.HalfWidth, frame.NotchAt = length * DART.HalfWidth, length * DART.Notch
		frame.BaseRadius = radius.value * px
		frame.HalfFov = ignoreFOV.value / 2
		frame.Squash = Vector2.new(1, yScale)
		frame.MaxRadius = math.max(math.min(center.X - 6, (center.Y - 6) / math.max(yScale, 0.1)) - length, 0)
		frame.Mode = colorMode.value
		frame.Near, frame.Far = hsv(nearColor), hsv(farColor)
		frame.EnemyColor, frame.FriendColor = hsv(color), hsv(friendColor)
		frame.ClosestColor = closest.enabled and hsv(closestColor) or nil

		for ent, pointer in reference do
			if not pcall(drawPointer, ent, pointer) then
				pointer.Tip, pointer.Color, pointer.Layer = nil, nil, nil
				pcall(setVisible, pointer, false)
			end
		end
	end

	arrows = render:module('Arrows', {
		label = 'Pointers',
		toggled = function(on)
			if on then
				if not arrows.enabled then return end
				arrows:clean(entitylib.Events.EntityRemoved:Connect(removed))
				for _, v in entitylib.List do
					if reference[v] then removed(v) end
					added(v)
				end
				arrows:clean(entitylib.Events.EntityAdded:Connect(function(ent)
					if reference[ent] then removed(ent) end
					added(ent)
				end))
				arrows:clean(runService.RenderStepped:Connect(loop))
			else
				for i in reference do
					removed(i)
				end
				closestEnt = nil
			end
		end,
		about = 'Draws pointers around your crosshair towards other players.\nThe closest one is red; set range, size, style and colors.'
	})
	range = arrows:slider('Max Range', {
		label = 'Range',
		min = 8,
		max = RANGE_MAX,
		default = RANGE_MAX,
		suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end,
		about = 'No pointer is drawn for players further away than this.\nAll the way up is no limit, like Name Tags.'
	})
	ignoreFOV = arrows:slider('Ignore FOV', {
		label = 'Ignore within FOV',
		min = 0,
		max = 180,
		default = 0,
		suffix = '°',
		about = 'No pointer is drawn for players inside this field of view. 0 points to everyone.'
	})
	teammates = arrows:toggle('Priority Only', {
		label = 'Hide friendlies',
		default = true,
		about = 'Teammates and friends get no pointer.'
	})
	arrows:divider('Customization')
	scale = arrows:slider('Scale', {
		min = 0.5,
		max = 2,
		default = 1,
		decimal = 10,
		about = 'The size of the pointers.'
	})
	radius = arrows:slider('Ring Radius', {
		label = 'Radius',
		min = 20,
		max = 300,
		default = 100,
		about = 'How far from your crosshair the pointers are drawn.'
	})
	style = arrows:dropdown('Pointer Style', {
		label = 'Style',
		choices = {'3D', '2D'},
		about = '3D: laid back at an angle for a sense of depth.\n2D: flat on the screen.'
	})
	colorMode = arrows:dropdown('Colors', {
		choices = {'Distance', 'Name Tag', 'Manual'},
		changed = function(val)
			nearColor.row.Visible = val == 'Distance'
			farColor.row.Visible = val == 'Distance'
			color.row.Visible = val == 'Manual'
			friendColor.row.Visible = val == 'Manual'
			transition.row.Visible = val == 'Distance' or distanceRadius.enabled
		end,
		about = 'Distance: from the near colour to the far colour.\nName Tag: their team colour.\nManual: one colour for enemies, one for friendlies.'
	})
	nearColor = arrows:color('Near Color', {
		label = 'Near color',
		hue = 0,
		sub = true
	})
	farColor = arrows:color('Far Color', {
		label = 'Far color',
		hue = 1 / 3,
		sub = true
	})
	color = arrows:color('Player Color', {
		label = 'Enemy color',
		sub = true,
		visible = false
	})
	friendColor = arrows:color('Friendly Color', {
		label = 'Friendly color',
		hue = 0.6,
		sub = true,
		visible = false
	})
	transition = arrows:range('Transition between', {
		min = 0,
		max = 256,
		defaultMin = 30,
		defaultMax = 150,
		sub = true,
		about = 'Which distances count as near and far, for the colours and the distance-based radius.'
	})
	distanceRadius = arrows:toggle('Distance Radius', {
		label = 'Distance-based radius',
		changed = function(callback)
			transition.row.Visible = colorMode.value == 'Distance' or callback
		end,
		default = true,
		about = 'Pointers for players far away are drawn further from your crosshair.'
	})
	closest = arrows:toggle('Highlight Closest', {
		label = 'Highlight closest',
		changed = function(callback)
			if closestColor then
				closestColor.row.Visible = callback
			end
		end,
		default = true,
		about = 'The pointer to the closest enemy is always drawn in this colour, whatever the colour mode.'
	})
	closestColor = arrows:color('Closest Color', {
		label = 'Closest color',
		hue = 0,
		sub = true
	})
	arrows:divider('Extras')
	targets = arrows:targets({
		players = true,
		changed = function()
			if arrows.enabled then
				arrows:flip()
				arrows:flip()
			end
		end
	})
end)
	
--[[ Chams
Colours other players through walls with a Highlight, or with box and sphere handles on their limbs,
in their team colour where they have one. The folder leaves the GUI while the menu is open, so the
chams stop drawing. Targetable and Friend can change after a cham is made: in BedWars your own team
is an attribute that can land after everyone is built (every time while RegionLock or AutoQueueDodge
hold the load-in), and EntityUpdated then announces every entity, so the filter is asked again
there. A late update after removal makes nothing. EntityUpdated also fires for health and equipment,
where it costs three field checks. ]]
run(function()
	local chams
	local targets
	local mode
	local fillColor
	local outlineColor
	local fillTransparency
	local outlineTransparency
	local teammates
	local walls
	local reference = {}
	local folder = Instance.new('Folder')
	folder.Parent = slinky.gui
	
	local function passes(ent)
		if not targets.players.enabled and ent.Player then return false end
		if not targets.npcs.enabled and ent.NPC then return false end
		if teammates.enabled and (not ent.Targetable) and (not ent.Friend) then return false end
		return true
	end
	
	local function added(ent)
		if not passes(ent) then return end
		if slinky.threadFix then
			setthreadidentity(8)
		end
	
		if mode.value == 'Highlight' then
			local cham = Instance.new('Highlight')
			cham.Adornee = ent.Character
			cham.DepthMode = Enum.HighlightDepthMode[walls.enabled and 'AlwaysOnTop' or 'Occluded']
			cham.FillColor = entitylib.getEntityColor(ent) or Color3.fromHSV(fillColor.hue, fillColor.sat, fillColor.value)
			cham.OutlineColor = Color3.fromHSV(outlineColor.hue, outlineColor.sat, outlineColor.value)
			cham.FillTransparency = fillTransparency.value
			cham.OutlineTransparency = outlineTransparency.value
			cham.Parent = folder
			reference[ent] = cham
		else
			local chams = {}
			for _, v in ent.Character:GetChildren() do
				if v:IsA('BasePart') and (ent.NPC or v.Name:find('Arm') or v.Name:find('Leg') or v.Name:find('Hand') or v.Name:find('Feet') or v.Name:find('Torso') or v.Name == 'Head') then
					local box = Instance.new(v.Name == 'Head' and 'SphereHandleAdornment' or 'BoxHandleAdornment')
					if v.Name == 'Head' then
						box.Radius = 0.75
					else
						box.Size = v.Size
					end
					box.AlwaysOnTop = walls.enabled
					box.Adornee = v
					box.ZIndex = 0
					box.Transparency = fillTransparency.value
					box.Color3 = entitylib.getEntityColor(ent) or Color3.fromHSV(fillColor.hue, fillColor.sat, fillColor.value)
					box.Parent = folder
					table.insert(chams, box)
				end
			end
			reference[ent] = chams
		end
	end
	
	local function removed(ent)
		if reference[ent] then
			if slinky.threadFix then
				setthreadidentity(8)
			end
			if type(reference[ent]) == 'table' then
				for _, v in reference[ent] do
					v:Destroy()
				end
				table.clear(reference[ent])
			else
				reference[ent]:Destroy()
			end
			reference[ent] = nil
		end
	end

	local function updated(ent)
		if passes(ent) then
			if not reference[ent] and table.find(entitylib.List, ent) then
				added(ent)
			end
		elseif reference[ent] then
			removed(ent)
		end
	end
	
	chams = render:module('Chams', {
		toggled = function(on)
			if on then
				chams:clean(entitylib.Events.EntityRemoved:Connect(removed))
				chams:clean(entitylib.Events.EntityUpdated:Connect(updated))
				chams:clean(entitylib.Events.EntityAdded:Connect(function(ent)
					if reference[ent] then
						removed(ent)
					end
					added(ent)
				end))
				chams:clean(slinky.categories.Friends.colorUpdate.Event:Connect(function()
					for i, v in reference do
						local color = entitylib.getEntityColor(i) or Color3.fromHSV(fillColor.hue, fillColor.sat, fillColor.value)
						if type(v) == 'table' then
							for _, v2 in v do v2.Color3 = color end
						else
							v.FillColor = color
						end
					end
				end))
				if slinky.threadFix then
					setthreadidentity(8)
				end
				local scaled = slinky.gui:FindFirstChild('ScaledGui')
				local clickGui = scaled and scaled:FindFirstChild('ClickGui')
				if clickGui then
					folder.Parent = (not clickGui.Visible) and slinky.gui or nil
					chams:clean(clickGui:GetPropertyChangedSignal('Visible'):Connect(function()
						if slinky.threadFix then
							setthreadidentity(8)
						end
						folder.Parent = (not clickGui.Visible) and slinky.gui or nil
					end))
				end
	
				for _, v in entitylib.List do
					if reference[v] then
						removed(v)
					end
					added(v)
				end
			else
				for i in reference do
					removed(i)
				end
				if slinky.threadFix then
					setthreadidentity(8)
				end
				folder.Parent = slinky.gui
			end
		end,
		about = 'Colors other players so you can see them through walls.\nChoose a glow or box style, its colors and transparency.'
	})
	chams:divider('Main')
	teammates = chams:toggle('Priority Only', {
		label = 'Hide friendlies',
		changed = function()
			if chams.enabled then
				chams:flip()
				chams:flip()
			end
		end,
		default = true,
		about = 'Hides teammates & non targetable entities'
	})
	chams:divider('Extras')
	targets = chams:targets({
		players = true,
		changed = function()
			if chams.enabled then
				chams:flip()
				chams:flip()
			end
		end
		})
	mode = chams:dropdown('Mode', {
		choices = {'Highlight', 'BoxHandles'},
		changed = function(val)
			outlineColor.row.Visible = val == 'Highlight'
			outlineTransparency.row.Visible = val == 'Highlight'
			if chams.enabled then
				chams:flip()
				chams:flip()
			end
		end
	})
	outlineColor = chams:color('Outline Color', {
		sat = 0,
		changed = function(hue, sat, val)
			for i, v in reference do
				if type(v) ~= 'table' then
					v.OutlineColor = Color3.fromHSV(hue, sat, val)
				end
			end
		end,
		sub = true
	})
	outlineTransparency = chams:slider('Outline Transparency', {
		min = 0,
		max = 1,
		default = 0.5,
		changed = function(val)
			for _, v in reference do
				if type(v) ~= 'table' then
					v.OutlineTransparency = val
				end
			end
		end,
		decimal = 10,
		sub = true
	})
	fillColor = chams:color('Color', {
		changed = function(hue, sat, val)
			for i, v in reference do
				local color = entitylib.getEntityColor(i) or Color3.fromHSV(hue, sat, val)
				if type(v) == 'table' then
					for _, v2 in v do v2.Color3 = color end
				else
					v.FillColor = color
				end
			end
		end
	})
	fillTransparency = chams:slider('Transparency', {
		min = 0,
		max = 1,
		default = 0.5,
		changed = function(val)
			for _, v in reference do
				if type(v) == 'table' then
					for _, v2 in v do v2.Transparency = val end
				else
					v.FillTransparency = val
				end
			end
		end,
		decimal = 10
	})
	walls = chams:toggle('Render Walls', {
		changed = function(callback)
			for _, v in reference do
				if type(v) == 'table' then
					for _, v2 in v do
						v2.AlwaysOnTop = callback
					end
				else
					v.DepthMode = Enum.HighlightDepthMode[callback and 'AlwaysOnTop' or 'Occluded']
				end
			end
		end,
		default = true
	})
end)
	
--[[ ESP
Draws 2D or 3D boxes or skeletons on other players with the Drawing library, with names, health
bars, team or manual colours and a red flash when they take damage; Override target color puts every
box in fixed border and fill colours. Without the Drawing library it warns and turns off; that is
checked by use, since some executors hand Drawing over as userdata.

The frame loop is kept cheap. WorldToViewportPoint is called as a plain function, not with ':'
through __namecall and the hook Pistonware keeps there: on Potassium that costs about a microsecond
and 48 bytes of garbage a call, at three a player every frame. Every Drawing write goes through set,
which skips a value equal to the last one written, and whether each player is shown is kept so most
frames touch nothing. A new Color3, Vector2 or CFrame per write would be about 20 objects a box a
frame, some 4.6 MB a second at 500 fps, and makes the collector stall the game: option colours are
made once per change, boxes keep the pixel values they last drew, and box corners are worked out in
vector maths except when looking straight up or down.

Everything runs at the raised identity: where Drawing is built from GUI objects in a protected
container (phone executors like Delta) a write without it can fail, and a RenderStepped callback
does not always carry it. A drawing the executor cannot make, or one that refuses a property, is
removed and treated as switched off; some phone executors have no Quad, and the box is then drawn
unfilled. Boxes are placed by their top-left corner with a positive size, since a library built from
GUI frames may draw nothing for a negative one. A name with no TextBounds is sized at about half the
text size per character. On R15 the skeleton joins the rig attachments its motors turn about, so it
bends with every animation; R6 uses points along each part. One player failing hides only that
player for the frame. Targetable and Friend are asked again on EntityUpdated, since a team can land
after the entity was built. ]]
run(function()
	local esp
	local targets
	local range
	local lineWidth
	local method
	local colorMode
	local color
	local friendColor
	local boundingBox
	local healthBar
	local filled
	local hurtEffect
	local name
	local displayName
	local background
	local teammates
	local overrideTarget
	local targetColor
	local targetFill
	local reference = {}
	local lastHealth = {}
	local hurtAt = {}
	local methodused
	local HURT_TIME = 0.5
	local HURT_COLOR = Color3.fromRGB(255, 40, 40)
	local TEXT_SIZE = 20
	local DROP_OFFSET = Vector2.new(1, 1)
	local BACKGROUND_PADDING = Vector2.new(8, 4)

	local worldToViewport
	local function screenPoint(pos)
		worldToViewport = worldToViewport or gameCamera.WorldToViewportPoint
		return worldToViewport(gameCamera, pos)
	end

	local function espWorldToViewport(pos)
		local newpos = screenPoint(pos)
		return Vector2.new(newpos.X, newpos.Y)
	end

	local function raiseIdentity()
		if slinky.threadFix and not pcall(setthreadidentity, 8) then
			pcall(setthreadidentity, 7)
		end
	end

	local written = setmetatable({}, {__mode = 'k'})

	local function set(obj, key, value)
		local last = written[obj]
		if last[key] ~= value then
			obj[key] = value
			last[key] = value
		end
	end

	local function setLine(line, from, to)
		set(line, 'From', from)
		set(line, 'To', to)
	end

	local shown = setmetatable({}, {__mode = 'k'})

	local function passes(ent)
		if not targets.players.enabled and ent.Player then return false end
		if not targets.npcs.enabled and ent.NPC then return false end
		if teammates.enabled and (not ent.Targetable) and (not ent.Friend) then return false end
		return true
	end

	local function healthFraction(ent)
		local maxHealth = ent.MaxHealth
		if type(maxHealth) ~= 'number' or maxHealth <= 0 then return 1 end
		local fraction = (ent.Health or maxHealth) / maxHealth
		return fraction == fraction and math.clamp(fraction, 0, 1) or 1
	end

	local function hurtTint(ent, now, color)
		local hurt = hurtEffect.enabled and hurtAt[ent]
		if hurt then
			local alpha = 1 - (now - hurt) / HURT_TIME
			if alpha > 0 then
				return color:Lerp(HURT_COLOR, alpha)
			end
			hurtAt[ent] = nil
		end
		return color
	end

	local optionColors = setmetatable({}, {__mode = 'k'})
	local function optionColor(option)
		local h, s, v = option.hue, option.sat, option.value
		local cached = optionColors[option]
		if not (cached and cached[1] == h and cached[2] == s and cached[3] == v) then
			cached = {h, s, v, Color3.fromHSV(h, s, v)}
			optionColors[option] = cached
		end
		return cached[4]
	end
	local boxes = setmetatable({}, {__mode = 'k'})
	local bars = setmetatable({}, {__mode = 'k'})

	local function fillFor(ent, now, color, alpha)
		if overrideTarget.enabled then
			return optionColor(targetFill), targetFill.opacity
		end
		return color, alpha
	end

	local function baseColor(ent)
		if overrideTarget.enabled then
			return optionColor(targetColor)
		end
		if colorMode.value == 'Manual' then
			local friendly = ent.Friend or not ent.Targetable
			return optionColor(friendly and friendColor or color)
		end
		return entitylib.getEntityColor(ent) or optionColor(color)
	end

	local function entityColor(ent, now)
		if overrideTarget.enabled then
			return baseColor(ent)
		end
		return hurtTint(ent, now, baseColor(ent))
	end

	local function applyProps(obj, props)
		for key, value in props do
			obj[key] = value
		end
	end

	local function newDrawing(kind, props)
		local made, obj = pcall(Drawing.new, kind)
		if not made or obj == nil then return nil end
		if not pcall(applyProps, obj, props) then
			pcall(function()
				obj:Remove()
			end)
			return nil
		end
		written[obj] = table.clone(props)
		return obj
	end

	local function addHealthBar(entityESP)
		entityESP.HealthBorder = newDrawing('Line', {Thickness = 4, Transparency = 0.5, ZIndex = 1, Color = Color3.new()})
		entityESP.HealthLine = newDrawing('Line', {Thickness = 2, ZIndex = 2})
	end

	local function drawHealthBar(entityESP, ent, left, top, bottom)
		local fraction = healthFraction(ent)
		local x = math.floor(left - 5)
		local trackTop, trackBottom = math.floor(top - 1), math.floor(bottom + 1)
		local barBottom, barTop = math.floor(bottom), math.floor(bottom - (bottom - top) * fraction)
		local cache = bars[entityESP]
		if not cache then
			cache = {}
			bars[entityESP] = cache
		end
		if cache.X ~= x or cache.TrackTop ~= trackTop or cache.TrackBottom ~= trackBottom
			or cache.BarBottom ~= barBottom or cache.BarTop ~= barTop then
			cache.X, cache.TrackTop, cache.TrackBottom, cache.BarBottom, cache.BarTop = x, trackTop, trackBottom, barBottom, barTop
			cache.TrackFrom, cache.TrackTo = Vector2.new(x, trackTop), Vector2.new(x, trackBottom)
			cache.BarFrom, cache.BarTo = Vector2.new(x, barBottom), Vector2.new(x, barTop)
		end
		if cache.Fraction ~= fraction then
			cache.Fraction = fraction
			cache.Color = Color3.fromHSV(fraction / 2.5, 0.89, 0.75)
		end
		local track, bar = entityESP.HealthBorder, entityESP.HealthLine
		if track then
			setLine(track, cache.TrackFrom, cache.TrackTo)
		end
		if bar then
			set(bar, 'Visible', fraction > 0)
			setLine(bar, cache.BarFrom, cache.BarTo)
			set(bar, 'Color', cache.Color)
		end
	end

	local function nameText(ent)
		return ent.Player and tags:prefix(ent.Player)..(displayName.enabled and ent.Player.DisplayName or ent.Player.Name) or ent.Character.Name
	end

	local function readTextBounds(text)
		return text.TextBounds
	end

	local function textBounds(text)
		local ok, bounds = pcall(readTextBounds, text)
		if ok and typeof(bounds) == 'Vector2' and bounds.X > 0 then
			return bounds
		end
		local name = tostring(written[text].Text or '')
		return Vector2.new((utf8.len(name) or #name) * TEXT_SIZE * 0.5, TEXT_SIZE)
	end

	local R15_JOINTS = {
		Head = {'Head', nil, 0},
		Neck = {'UpperTorso', 'NeckRigAttachment', 0.5},
		Waist = {'UpperTorso', 'WaistRigAttachment', -0.5}
	}
	local R6_JOINTS = {
		Head = {'Head', nil, 0},
		Neck = {'Torso', nil, 0.5},
		Waist = {'Torso', nil, -0.5}
	}
	local BONES = {{'Neck', 'Head'}, {'Neck', 'Waist'}}
	for _, side in {'Left', 'Right'} do
		R15_JOINTS[side..'Shoulder'] = {side..'UpperArm', side..'ShoulderRigAttachment', 0.5}
		R15_JOINTS[side..'Elbow'] = {side..'LowerArm', side..'ElbowRigAttachment', 0.5}
		R15_JOINTS[side..'Hand'] = {side..'Hand', nil, 0}
		R15_JOINTS[side..'Hip'] = {side..'UpperLeg', side..'HipRigAttachment', 0.5}
		R15_JOINTS[side..'Knee'] = {side..'LowerLeg', side..'KneeRigAttachment', 0.5}
		R15_JOINTS[side..'Ankle'] = {side..'Foot', side..'AnkleRigAttachment', 0.5}
		R6_JOINTS[side..'Shoulder'] = {side..' Arm', nil, 0.5}
		R6_JOINTS[side..'Elbow'] = {side..' Arm', nil, 0}
		R6_JOINTS[side..'Hand'] = {side..' Arm', nil, -0.5}
		R6_JOINTS[side..'Hip'] = {side..' Leg', nil, 0.5}
		R6_JOINTS[side..'Knee'] = {side..' Leg', nil, 0}
		R6_JOINTS[side..'Ankle'] = {side..' Leg', nil, -0.5}
		table.insert(BONES, {'Neck', side..'Shoulder'})
		table.insert(BONES, {side..'Shoulder', side..'Elbow'})
		table.insert(BONES, {side..'Elbow', side..'Hand'})
		table.insert(BONES, {'Waist', side..'Hip'})
		table.insert(BONES, {side..'Hip', side..'Knee'})
		table.insert(BONES, {side..'Knee', side..'Ankle'})
	end
	local rigCache = setmetatable({}, {__mode = 'k'})
	local jointScreen = {}

	local espAdded = {
		Drawing2D = function(ent)
			if not passes(ent) then return end
			local text = name.enabled and nameText(ent)
			raiseIdentity()
			local entityESP = {}
			if filled.enabled then
				entityESP.Fill = newDrawing('Square', {Filled = true, Transparency = 0.25, ZIndex = 0, Thickness = 1})
			end
			if boundingBox.enabled then
				entityESP.Border = newDrawing('Square', {Filled = false, Transparency = 0.5, ZIndex = 1, Thickness = lineWidth.value + 2, Color = Color3.new()})
				entityESP.Main = newDrawing('Square', {Filled = false, Transparency = 1, ZIndex = 2, Thickness = lineWidth.value})
			end
			if healthBar.enabled then
				addHealthBar(entityESP)
			end
			if text then
				entityESP.Text = newDrawing('Text', {Text = text, ZIndex = 2, Center = true, Size = TEXT_SIZE})
				if entityESP.Text then
					entityESP.Drop = newDrawing('Text', {Color = Color3.new(), Text = text, ZIndex = 1, Center = true, Size = TEXT_SIZE})
					if background.enabled then
						entityESP.TextBKG = newDrawing('Square', {Transparency = 0.35, ZIndex = 0, Thickness = 1, Filled = true, Color = Color3.new()})
					end
				end
			end
			reference[ent] = entityESP
		end,
		Drawing3D = function(ent)
			if not passes(ent) then return end
			raiseIdentity()
			local entityESP = {Lines = {}, Faces = {}}
			if boundingBox.enabled then
				for i = 1, 12 do
					entityESP.Lines[i] = newDrawing('Line', {Thickness = lineWidth.value, ZIndex = 2})
				end
			end
			if filled.enabled then
				for i = 1, 6 do
					local face = newDrawing('Quad', {Filled = true, Transparency = 0.15, Thickness = 1, ZIndex = 1})
					if not face then break end
					entityESP.Faces[i] = face
				end
			end
			if healthBar.enabled then
				addHealthBar(entityESP)
			end
			reference[ent] = entityESP
		end,
		DrawingSkeleton = function(ent)
			if not passes(ent) then return end
			raiseIdentity()
			local entityESP = {Lines = {}}
			for i in BONES do
				entityESP.Lines[i] = newDrawing('Line', {Thickness = math.max(lineWidth.value, 2)})
			end
			reference[ent] = entityESP
		end
	}

	local function eachDrawing(entityESP, callback)
		for key, obj in entityESP do
			if key == 'Lines' or key == 'Faces' then
				for _, line in obj do
					callback(line)
				end
			else
				callback(obj)
			end
		end
	end

	local function espRemoved(ent)
		local entityESP = reference[ent]
		lastHealth[ent] = nil
		hurtAt[ent] = nil
		rigCache[ent] = nil
		if entityESP then
			raiseIdentity()
			reference[ent] = nil
			eachDrawing(entityESP, function(obj)
				written[obj] = nil
				pcall(function()
					obj.Visible = false
					obj:Remove()
				end)
			end)
		end
	end

	local function espUpdated(ent)
		local shown = reference[ent] ~= nil
		if passes(ent) ~= shown then
			if shown then
				espRemoved(ent)
			elseif table.find(entitylib.List, ent) then
				espAdded[methodused](ent)
			end
		end
		local health = ent.Health
		local last = lastHealth[ent]
		if type(health) == 'number' then
			if last and health < last then
				hurtAt[ent] = os.clock()
			end
			lastHealth[ent] = health
		end
		local entityESP = reference[ent]
		if entityESP and entityESP.Text then
			raiseIdentity()
			local text = nameText(ent)
			set(entityESP.Text, 'Text', text)
			if entityESP.Drop then
				set(entityESP.Drop, 'Text', text)
			end
		end
	end

	local function setAll(entityESP, visible)
		if shown[entityESP] == visible then return end
		for key, obj in entityESP do
			if key == 'Lines' or key == 'Faces' then
				for _, line in obj do
					set(line, 'Visible', visible)
				end
			else
				set(obj, 'Visible', visible)
			end
		end
		shown[entityESP] = visible
	end

	local function screenRoot(ent, entityESP, origin, menuOpen)
		if menuOpen then
			setAll(entityESP, false)
			return nil
		end
		local root = ent.RootPart
		if not (root and root.Parent) then
			setAll(entityESP, false)
			return nil
		end
		local position = root.Position
		if origin and (origin - position).Magnitude > range.value then
			setAll(entityESP, false)
			return nil
		end
		local rootPos, rootVis = screenPoint(position)
		setAll(entityESP, rootVis)
		return rootVis and rootPos or nil, position
	end

	local function draw2D(ent, entityESP, origin, menuOpen, now, camera)
		local rootPos, position = screenRoot(ent, entityESP, origin, menuOpen)
		if not rootPos then return end

		local lookDir = camera.LookVector
		local right = lookDir:Cross(Vector3.yAxis)
		local topWorld, bottomWorld
		if right.Magnitude > 1e-4 then
			right = right.Unit
			local up = right:Cross(lookDir).Unit
			topWorld = position + right * 2 + up * ent.HipHeight
			bottomWorld = position - right * 2 - up * (ent.HipHeight + 1)
		else
			local look = CFrame.lookAlong(position, lookDir)
			topWorld = (look * CFrame.new(2, ent.HipHeight, 0)).Position
			bottomWorld = (look * CFrame.new(-2, -ent.HipHeight - 1, 0)).Position
		end
		local topPos = screenPoint(topWorld)
		local bottomPos = screenPoint(bottomWorld)
		local width, height = math.abs(topPos.X - bottomPos.X), math.abs(topPos.Y - bottomPos.Y)
		local left, top = rootPos.X - width / 2, rootPos.Y - height / 2
		local box = boxes[entityESP]
		if not box then
			box = {}
			boxes[entityESP] = box
		end
		local x, y, w, h = math.floor(left), math.floor(top), math.floor(width), math.floor(height)
		if box.X ~= x or box.Y ~= y or box.W ~= w or box.H ~= h then
			box.X, box.Y, box.W, box.H = x, y, w, h
			box.Pos, box.Size = Vector2.new(x, y), Vector2.new(w, h)
		end
		local boxPos, boxSize = box.Pos, box.Size
		local color = entityColor(ent, now)
		local main, border, fill = entityESP.Main, entityESP.Border, entityESP.Fill
		if main then
			set(main, 'Position', boxPos)
			set(main, 'Size', boxSize)
			set(main, 'Color', color)
		end
		if border then
			set(border, 'Position', boxPos)
			set(border, 'Size', boxSize)
		end
		if fill then
			local fillColor, fillAlpha = fillFor(ent, now, color, 0.25)
			set(fill, 'Position', boxPos)
			set(fill, 'Size', boxSize)
			set(fill, 'Color', fillColor)
			set(fill, 'Transparency', fillAlpha)
		end
		if entityESP.HealthLine or entityESP.HealthBorder then
			drawHealthBar(entityESP, ent, left, top, top + height)
		end
		local text = entityESP.Text
		if text then
			local textPos = Vector2.new(rootPos.X, top - 28) // 1
			set(text, 'Color', color)
			set(text, 'Position', textPos)
			if entityESP.Drop then
				set(entityESP.Drop, 'Position', textPos + DROP_OFFSET)
			end
			local background = entityESP.TextBKG
			if background then
				local bounds = textBounds(text)
				set(background, 'Size', (bounds + BACKGROUND_PADDING) // 1)
				set(background, 'Position', (textPos - Vector2.new((bounds.X + BACKGROUND_PADDING.X) / 2, BACKGROUND_PADDING.Y / 2)) // 1)
			end
		end
	end

	local BOX_EDGES = {{1, 2}, {3, 4}, {5, 6}, {7, 8}, {1, 3}, {1, 5}, {5, 7}, {7, 3}, {2, 4}, {2, 6}, {6, 8}, {8, 4}}
	local BOX_FACES = {{1, 3, 4, 2}, {5, 7, 8, 6}, {1, 5, 6, 2}, {3, 7, 8, 4}, {1, 3, 7, 5}, {2, 4, 8, 6}}
	local BOX_CORNERS = {
		Vector3.new(1.5, 1, 1.5), Vector3.new(1.5, -1, 1.5), Vector3.new(-1.5, 1, 1.5), Vector3.new(-1.5, -1, 1.5),
		Vector3.new(1.5, 1, -1.5), Vector3.new(1.5, -1, -1.5), Vector3.new(-1.5, 1, -1.5), Vector3.new(-1.5, -1, -1.5)
	}
	local boxPoints = {}

	local function draw3D(ent, entityESP, origin, menuOpen, now)
		local rootPos, position = screenRoot(ent, entityESP, origin, menuOpen)
		if not rootPos then return end

		local height = ent.HipHeight
		local left, top, bottom = math.huge, math.huge, -math.huge
		for i, corner in BOX_CORNERS do
			local point = espWorldToViewport(position + Vector3.new(corner.X, corner.Y * height, corner.Z))
			boxPoints[i] = point
			left = math.min(left, point.X)
			top, bottom = math.min(top, point.Y), math.max(bottom, point.Y)
		end
		local color = entityColor(ent, now)
		for i, line in entityESP.Lines do
			local edge = BOX_EDGES[i]
			setLine(line, boxPoints[edge[1]], boxPoints[edge[2]])
			set(line, 'Color', color)
		end
		local fill, fillAlpha = fillFor(ent, now, color, 0.15)
		for i, face in entityESP.Faces do
			local corners = BOX_FACES[i]
			set(face, 'PointA', boxPoints[corners[1]])
			set(face, 'PointB', boxPoints[corners[2]])
			set(face, 'PointC', boxPoints[corners[3]])
			set(face, 'PointD', boxPoints[corners[4]])
			set(face, 'Color', fill)
			set(face, 'Transparency', fillAlpha)
		end
		if entityESP.HealthLine or entityESP.HealthBorder then
			drawHealthBar(entityESP, ent, left, top, bottom)
		end
	end

	local function rigFor(ent)
		local character = ent.Character
		local rig = rigCache[ent]
		if rig and rig.Character == character then
			return rig
		end
		local specs = ent.Humanoid.RigType == Enum.HumanoidRigType.R6 and R6_JOINTS or R15_JOINTS
		local joints = {}
		for name, spec in specs do
			local part = character:FindFirstChild(spec[1])
			if not (part and part:IsA('BasePart')) then return nil end
			local attachment = spec[2] and part:FindFirstChild(spec[2])
			joints[name] = {part, attachment and attachment:IsA('Attachment') and attachment or nil, spec[3]}
		end
		rig = {Character = character, Joints = joints}
		rigCache[ent] = rig
		return rig
	end

	local function jointPosition(joint)
		local attachment = joint[2]
		if attachment then
			return attachment.WorldPosition
		end
		local part = joint[1]
		return part.CFrame:PointToWorldSpace(Vector3.new(0, part.Size.Y * joint[3], 0))
	end

	local function drawSkeleton(ent, entityESP, origin, menuOpen, now)
		if not screenRoot(ent, entityESP, origin, menuOpen) then return end

		local rig = rigFor(ent)
		if not rig then
			setAll(entityESP, false)
			return
		end
		for name, joint in rig.Joints do
			jointScreen[name] = espWorldToViewport(jointPosition(joint))
		end
		local color = entityColor(ent, now)
		for i, line in entityESP.Lines do
			local bone = BONES[i]
			setLine(line, jointScreen[bone[1]], jointScreen[bone[2]])
			set(line, 'Color', color)
		end
	end

	local function frameLoop(drawOne)
		return function()
			raiseIdentity()
			local now = os.clock()
			local camera = gameCamera.CFrame
			local origin = entitylib.isAlive and entitylib.character.RootPart.Position or camera.Position
			local menuOpen = clickGuiOpen()
			for ent, entityESP in reference do
				if not pcall(drawOne, ent, entityESP, origin, menuOpen, now, camera) then
					pcall(setAll, entityESP, false)
				end
			end
		end
	end

	local espLoop = {
		Drawing2D = frameLoop(draw2D),
		Drawing3D = frameLoop(draw3D),
		DrawingSkeleton = frameLoop(drawSkeleton)
	}

	local function restart()
		if esp.enabled then
			esp:flip()
			esp:flip()
		end
	end

	esp = render:module('ESP', {
		label = 'Player ESP',
		toggled = function(on)
			if on then
				if not pcall(function() assert(Drawing.new) end) then
					notif('Player ESP', 'Your executor has no Drawing library to draw with.', 5, 'warning')
					if esp.enabled then
						esp:flip(nil, true)
					end
					return
				end
				methodused = 'Drawing'..method.value
				esp:clean(entitylib.Events.EntityRemoved:Connect(espRemoved))
				for _, v in entitylib.List do
					if reference[v] then
						espRemoved(v)
					end
					espAdded[methodused](v)
					espUpdated(v)
				end
				esp:clean(entitylib.Events.EntityAdded:Connect(function(ent)
					if reference[ent] then
						espRemoved(ent)
					end
					espAdded[methodused](ent)
				end))
				esp:clean(entitylib.Events.EntityUpdated:Connect(espUpdated))
				esp:clean(runService.RenderStepped:Connect(espLoop[methodused]))
			else
				for i in reference do
					espRemoved(i)
				end
				table.clear(lastHealth)
				table.clear(hurtAt)
			end
		end,
		about = 'Shows boxes around other players, even through walls.\nChoose 2D, 3D or skeleton, with names, health bars and colors.'
	})
	esp:divider('Main')
	range = esp:slider('Range', {
		min = 8,
		max = 1024,
		default = 1024,
		suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end,
		about = 'Players further away than this are not highlighted.'
	})
	esp:divider('Customization')
	method = esp:dropdown('Mode', {
		label = 'Style',
		choices = {'2D', '3D', 'Skeleton'},
		changed = function(val)
			restart()
			boundingBox.row.Visible = val ~= 'Skeleton'
			healthBar.row.Visible = val ~= 'Skeleton'
			filled.row.Visible = val ~= 'Skeleton'
			name.row.Visible = val == '2D'
			displayName.row.Visible = name.row.Visible and name.enabled
			background.row.Visible = name.row.Visible and name.enabled
		end,
		about = 'Both box styles can show the box and the health bar on their own.'
	})
	colorMode = esp:dropdown('Colors', {
		choices = {'Automatic', 'Manual'},
		changed = function(val)
			color.row.Visible = val == 'Manual'
			friendColor.row.Visible = val == 'Manual'
		end,
		about = 'Automatic: their name tag colour. Manual: one colour for enemies, one for friendlies.'
	})
	color = esp:color('Player Color', {
		label = 'Enemy color',
		visible = false
	})
	friendColor = esp:color('Friendly Color', {
		label = 'Friendly color',
		hue = 0.6,
		visible = false
	})
	overrideTarget = esp:toggle('Override target color', {
		changed = function(callback)
			targetColor.row.Visible = callback
			targetFill.row.Visible = callback
		end,
		about = 'Every box and outline uses the colours below.'
	})
	targetColor = esp:color('Target color', {
		label = 'Target border color',
		hue = 1 / 6,
		sat = 1,
		value = 1,
		visible = false
	})
	targetFill = esp:color('Target fill color', {
		hue = 1 / 6,
		sat = 1,
		value = 1,
		opacity = 0.35,
		visible = false
	})
	lineWidth = esp:slider('Line Width', {
		label = 'Line width',
		min = 1,
		max = 5,
		default = 1,
		suffix = 'px',
		changed = restart,
		about = 'How thick the outlines are.'
	})
	boundingBox = esp:toggle('Bounding Box', {
		label = 'Show box',
		changed = restart,
		default = true,
		about = 'Draws a box around each player.'
	})
	filled = esp:toggle('Filled', {
		changed = restart,
		about = 'When off, only the outline is drawn.'
	})
	hurtEffect = esp:toggle('Hurt Effect', {
		label = 'Hurt effect',
		default = true,
		about = 'Flashes red when they take damage, like their own model does.'
	})
	healthBar = esp:toggle('Health Bar', {
		label = 'Show health bar',
		changed = restart,
		about = 'Shows how much health each player has left.'
	})
	esp:divider('Extras')
	teammates = esp:toggle('Priority Only', {
		label = 'Hide friendlies',
		changed = restart,
		default = true,
		about = 'Teammates and friends are not highlighted.'
	})
	name = esp:toggle('Name', {
		changed = function(callback)
			restart()
			displayName.row.Visible = callback and name.row.Visible
			background.row.Visible = callback and name.row.Visible
		end
	})
	displayName = esp:toggle('Use Displayname', {
		changed = restart,
		default = true,
		visible = false
	})
	background = esp:toggle('Show Background', {
		changed = restart,
		visible = false
	})
	targets = esp:targets({
		players = true,
		changed = restart
	})
end)
	
--[[ Fullbright
Lights up the world. Lighting sets Ambient and OutdoorAmbient to white and Brightness to 3, sets
them again whenever the game changes Lighting, and puts the old values back when turned off;
PointLight carries a wide light on your root. A generation counter stops a light loop left over from
a Mode restart or a quick off and on. ]]
run(function()
	local fullbright
	local mode
	local oldsettings = {}
	local flag
	local generation = 0

	local function changeLighting(prop)
		if flag then
			return
		end
	
		flag = true
		lightingService.Ambient = Color3.new(1, 1, 1)
		lightingService.OutdoorAmbient = Color3.new(1, 1, 1)
		lightingService.Brightness = 3
		runService.RenderStepped:Wait()
		flag = false
	end
	
	fullbright = render:module('Fullbright', {
		toggled = function(on)
			generation += 1
			if on then
				if mode.value == 'Lighting' then
					for _, v in {'Ambient', 'OutdoorAmbient', 'Brightness'} do
						oldsettings[v] = lightingService[v]
					end
	
					fullbright:clean(lightingService.Changed:Connect(changeLighting))
					task.spawn(changeLighting)
				else
					local inst = Instance.new('PointLight')
					inst.Range = 1000
					fullbright:clean(inst)

					local gen = generation
					repeat
						inst.Parent = entitylib.isAlive and entitylib.character.RootPart or nil
						task.wait(0.1)
					until not fullbright.enabled or generation ~= gen
				end
			else
				flag = false
				for i, v in oldsettings do
					lightingService[i] = v
				end
				table.clear(oldsettings)
			end
		end,
		about = 'Lights up the world so dark areas are easy to see.\nBrighten the whole map, or carry a light around with you.'
	})
	mode = fullbright:dropdown('Mode', {
		choices = {'Lighting', 'PointLight'},
		changed = function()
			if fullbright.enabled then
				fullbright:flip()
				fullbright:flip()
			end
		end
	})
end)
	
--[[ GamingChair
Seats your character in a gaming chair that rolls along with you and hovers while you fly.
Uninjecting clears entitylib while the loop waits for a respawn, and a stale loop must not unanchor
the new chair, so the loop stops in both cases; switching off destroys the chair. A generation
counter stops a loop left over from a quick off and on. ]]
run(function()
	local gamingChair = {enabled = false}
	local color
	local wheelpositions = {
		Vector3.new(-0.8, -0.6, -0.18),
		Vector3.new(0.1, -0.6, -0.88),
		Vector3.new(0, -0.6, 0.7)
	}
	local chairhighlight
	local currenttween
	local movingsound
	local flyingsound
	local chairanim
	local chair
	local generation = 0

	gamingChair = render:module('GamingChair', {
		toggled = function(on)
			generation += 1
			if on then
				if slinky.threadFix then
					setthreadidentity(8)
				end
				chair = Instance.new('MeshPart')
				chair.Color = Color3.fromRGB(21, 21, 21)
				chair.Size = Vector3.new(2.16, 3.6, 2.3) / Vector3.new(12.37, 20.636, 13.071)
				chair.CanCollide = false
				chair.Massless = true
				chair.MeshId = 'rbxassetid://12972961089'
				chair.Material = Enum.Material.SmoothPlastic
				chair.Parent = workspace
				movingsound = Instance.new('Sound')
				movingsound.Volume = 0.4
				movingsound.Looped = true
				movingsound.Parent = workspace
				flyingsound = Instance.new('Sound')
				flyingsound.Volume = 0.4
				flyingsound.Looped = true
				flyingsound.Parent = workspace
				local chairweld = Instance.new('WeldConstraint')
				chairweld.Part0 = chair
				chairweld.Parent = chair
				if entitylib.isAlive then
					chair.CFrame = entitylib.character.RootPart.CFrame * CFrame.Angles(0, math.rad(-90), 0)
					chairweld.Part1 = entitylib.character.RootPart
				end
				chairhighlight = Instance.new('Highlight')
				chairhighlight.FillTransparency = 1
				chairhighlight.OutlineColor = Color3.fromHSV(color.hue, color.sat, color.value)
				chairhighlight.DepthMode = Enum.HighlightDepthMode.Occluded
				chairhighlight.OutlineTransparency = 0.2
				chairhighlight.Parent = chair
				local chairarms = Instance.new('MeshPart')
				chairarms.Color = chair.Color
				chairarms.Size = Vector3.new(1.39, 1.345, 2.75) / Vector3.new(97.13, 136.216, 234.031)
				chairarms.CFrame = chair.CFrame * CFrame.new(-0.169, -1.129, -0.013)
				chairarms.MeshId = 'rbxassetid://12972673898'
				chairarms.CanCollide = false
				chairarms.Parent = chair
				local chairarmsweld = Instance.new('WeldConstraint')
				chairarmsweld.Part0 = chairarms
				chairarmsweld.Part1 = chair
				chairarmsweld.Parent = chair
				local chairlegs = Instance.new('MeshPart')
				chairlegs.Color = chair.Color
				chairlegs.Name = 'Legs'
				chairlegs.Size = Vector3.new(1.8, 1.2, 1.8) / Vector3.new(10.432, 8.105, 9.488)
				chairlegs.CFrame = chair.CFrame * CFrame.new(0.047, -2.324, 0)
				chairlegs.MeshId = 'rbxassetid://13003181606'
				chairlegs.CanCollide = false
				chairlegs.Parent = chair
				local chairfan = Instance.new('MeshPart')
				chairfan.Color = chair.Color
				chairfan.Name = 'Fan'
				chairfan.Size = Vector3.zero
				chairfan.CFrame = chair.CFrame * CFrame.new(0, -1.873, 0)
				chairfan.MeshId = 'rbxassetid://13004977292'
				chairfan.CanCollide = false
				chairfan.Parent = chair
				local trails = {}
				for _, v in wheelpositions do
					local attachment = Instance.new('Attachment')
					attachment.Position = v
					attachment.Parent = chairlegs
					local attachment2 = Instance.new('Attachment')
					attachment2.Position = v + Vector3.new(0, 0, 0.18)
					attachment2.Parent = chairlegs
					local trail = Instance.new('Trail')
					trail.Texture = 'http://www.roblox.com/asset/?id=13005168530'
					trail.TextureMode = Enum.TextureMode.Static
					trail.Transparency = NumberSequence.new(0.5)
					trail.Color = ColorSequence.new(Color3.new(0.5, 0.5, 0.5))
					trail.Attachment0 = attachment
					trail.Attachment1 = attachment2
					trail.Lifetime = 20
					trail.MaxLength = 60
					trail.MinLength = 0.1
					trail.Parent = chairlegs
					table.insert(trails, trail)
				end
				gamingChair:clean(chair)
				gamingChair:clean(movingsound)
				gamingChair:clean(flyingsound)
				chairanim = {Stop = function() end}
				local oldmoving = false
				local oldflying = false
				local gen = generation
				repeat
					if entitylib.isAlive and entitylib.character.Humanoid.Health > 0 then
						if not chairanim.IsPlaying then
							local temp2 = Instance.new('Animation')
							temp2.AnimationId = entitylib.character.Humanoid.RigType == Enum.HumanoidRigType.R15 and 'http://www.roblox.com/asset/?id=2506281703' or 'http://www.roblox.com/asset/?id=178130996'
							chairanim = entitylib.character.Humanoid:LoadAnimation(temp2)
							chairanim.Priority = Enum.AnimationPriority.Movement
							chairanim.Looped = true
							chairanim:Play()
						end
						chair.CFrame = entitylib.character.RootPart.CFrame * CFrame.Angles(0, math.rad(-90), 0)
						chairweld.Part1 = entitylib.character.RootPart
						chairlegs.Velocity = Vector3.zero
						chairlegs.CFrame = chair.CFrame * CFrame.new(0.047, -2.324, 0)
						chairfan.Velocity = Vector3.zero
						chairfan.CFrame = chair.CFrame * CFrame.new(0.047, -1.873, 0) * CFrame.Angles(0, math.rad(tick() * 180 % 360), math.rad(180))
						local moving = entitylib.character.Humanoid:GetState() == Enum.HumanoidStateType.Running and entitylib.character.Humanoid.MoveDirection ~= Vector3.zero
						local flying = slinky.modules.Fly and slinky.modules.Fly.enabled or slinky.modules.LongJump and slinky.modules.LongJump.enabled or slinky.modules.InfiniteFly and slinky.modules.InfiniteFly.enabled
						if movingsound.TimePosition > 1.9 then
							movingsound.TimePosition = 0.2
						end
						movingsound.PlaybackSpeed = (entitylib.character.RootPart.Velocity * Vector3.new(1, 0, 1)).Magnitude / 16
						for _, v in trails do
							v.Enabled = not flying and moving
							v.Color = ColorSequence.new(movingsound.PlaybackSpeed > 1.5 and Color3.new(1, 0.5, 0) or Color3.new())
						end
						if moving ~= oldmoving then
							if movingsound.IsPlaying then
								if not moving then
									movingsound:Stop()
								end
							else
								if not flying and moving then
									movingsound:Play()
								end
							end
							oldmoving = moving
						end
						if flying ~= oldflying then
							if flying then
								if movingsound.IsPlaying then
									movingsound:Stop()
								end
								if not flyingsound.IsPlaying then
									flyingsound:Play()
								end
								if currenttween then
									currenttween:Cancel()
								end
								currenttween = tweenService:Create(chairlegs, TweenInfo.new(0.15), {
									Size = Vector3.zero
								})
								currenttween.Completed:Connect(function(state)
									if state == Enum.PlaybackState.Completed then
										chairfan.Transparency = 0
										chairlegs.Transparency = 1
										currenttween = tweenService:Create(chairfan, TweenInfo.new(0.15), {
											Size = Vector3.new(1.534, 0.328, 1.537) / Vector3.new(791.138, 168.824, 792.027)
										})
										currenttween:Play()
									end
								end)
								currenttween:Play()
							else
								if flyingsound.IsPlaying then
									flyingsound:Stop()
								end
								if not movingsound.IsPlaying and moving then
									movingsound:Play()
								end
								if currenttween then currenttween:Cancel() end
								currenttween = tweenService:Create(chairfan, TweenInfo.new(0.15), {
									Size = Vector3.zero
								})
								currenttween.Completed:Connect(function(state)
									if state == Enum.PlaybackState.Completed then
										chairfan.Transparency = 1
										chairlegs.Transparency = 0
										currenttween = tweenService:Create(chairlegs, TweenInfo.new(0.15), {
											Size = Vector3.new(1.8, 1.2, 1.8) / Vector3.new(10.432, 8.105, 9.488)
										})
										currenttween:Play()
									end
								end)
								currenttween:Play()
							end
							oldflying = flying
						end
					else
						chair.Anchored = true
						chairlegs.Anchored = true
						chairfan.Anchored = true
						repeat task.wait() until not (gamingChair.enabled and generation == gen and entitylib) or entitylib.isAlive and entitylib.character.Humanoid.Health > 0
						if not (gamingChair.enabled and generation == gen and entitylib) then break end
						chair.Anchored = false
						chairlegs.Anchored = false
						chairfan.Anchored = false
						chairanim:Stop()
					end
					task.wait()
				until not gamingChair.enabled or generation ~= gen
			else
				if chairanim then
					chairanim:Stop()
				end
			end
		end,
		about = 'Sit in the best gaming chair known to mankind.\nIt rolls along with you and hovers while you fly.'
	})
	color = gamingChair:color('Color', {
		changed = function(h, s, v)
			if chairhighlight then
				chairhighlight.OutlineColor = Color3.fromHSV(h, s, v)
			end
		end
	})
end)
	
--[[ Health
Shows your health with a heart below the middle of the screen, coloured from green to red by the
share left, and hidden while the menu is open. ]]
run(function()
	local health
	local generation = 0

	health = render:module('Health', {
		toggled = function(on)
			generation += 1
			if on then
				local label = Instance.new('TextLabel')
				label.Size = UDim2.fromOffset(100, 20)
				label.Position = UDim2.new(0.5, 6, 0.5, 30)
				label.AnchorPoint = Vector2.new(0.5, 0)
				label.BackgroundTransparency = 1
				label.Text = '100 ❤️'
				label.TextSize = 18
				slinky.libraries.fonts.track(label)
				label.Parent = slinky.gui
				health:clean(label)

				local gen = generation
				repeat
					local show = not clickGuiOpen()
					if label.Visible ~= show then label.Visible = show end
					label.Text = entitylib.isAlive and math.round(entitylib.character.Humanoid.Health)..' ❤️' or ''
					label.TextColor3 = entitylib.isAlive and Color3.fromHSV((entitylib.character.Humanoid.Health / entitylib.character.Humanoid.MaxHealth) / 2.8, 0.86, 1) or Color3.new()
					task.wait()
				until not health.enabled or generation ~= gen
			end
		end,
		about = 'Shows your health in the middle of the screen.'
	})
end)

--[[ MotionBlur
Blurs the screen on fast camera turns and, with Speed Blur, at speeds well past running. The turn
speed is averaged over about 25 ms, so a mouse that reports less often than the screen draws reads
as one steady turn. Under DEADZONE degrees a second (aiming) it adds nothing; past it the blur eases
toward full, about two thirds of the way 500 degrees a second further on, with no hard cap. Speed
Blur works the same on how far you are over running pace sideways (FLAT) or over a jump's fall
(FALL), and gives at most SPEED_SHARE of the peak on its own. The blur comes in at RISE and fades at
FALL_RATE per second of real frame time, so every frame rate looks the same, and below OFF it is
switched off, so a still camera costs nothing. A turn of more than CUT degrees in one frame from a
nearly still camera is the camera being placed (a teleport, a cutscene) and adds nothing; the same
again straight after is a fast turn at a low frame rate. For SETTLE seconds after a respawn turning
adds nothing either. The BlurEffect is made again if the game clears Lighting. ]]
run(function()
	local motionBlur
	local strength
	local speedBlur
	local tuning = {
		PEAK = 32, DEADZONE = 120, TURN_SCALE = 500, TURN_SMOOTH = 40, CUT = 75, SETTLE = 0.2,
		FLAT = 28, FALL = 70, SPEED_SCALE = 60, SPEED_SHARE = 0.7,
		RISE = 20, FALL_RATE = 7, OFF = 0.25
	}

	motionBlur = render:module('MotionBlur', {
		toggled = function(on)
			if on then
				local blur, camera, lastLook
				local size, rate, lastAngle, settle = 0, 0, 0, 0

				local function show(value)
					if value < tuning.OFF then
						if blur and blur.Enabled then
							blur.Enabled = false
						end
						return
					end
					if not blur or not blur.Parent then
						if blur then
							pcall(blur.Destroy, blur)
						end
						blur = nil
						local ok, effect = pcall(function()
							local made = Instance.new('BlurEffect')
							made.Size = 0
							made.Parent = lightingService
							return made
						end)
						if not ok then return end
						blur = effect
					end
					blur.Size = value
					if not blur.Enabled then
						blur.Enabled = true
					end
				end

				motionBlur:clean(function()
					if blur then
						pcall(blur.Destroy, blur)
						blur = nil
					end
				end)
				motionBlur:clean(lplr.CharacterAdded:Connect(function()
					settle = tuning.SETTLE
				end))
				motionBlur:clean(runService.RenderStepped:Connect(function(delta)
					local step = math.max(delta, 1e-4)
					settle = math.max(settle - delta, 0)
					local turn = 0
					if gameCamera then
						local look = gameCamera.CFrame.LookVector
						local angle = 0
						if camera == gameCamera and lastLook and settle == 0 then
							angle = math.deg(math.atan2(look:Cross(lastLook).Magnitude, look:Dot(lastLook)))
							if angle < tuning.CUT or (angle <= 180 and lastAngle >= tuning.CUT / 3) then
								turn = angle / step
							end
						end
						camera, lastLook, lastAngle = gameCamera, look, angle
					end
					rate += (turn - rate) * (1 - math.exp(-tuning.TURN_SMOOTH * step))

					local fast = 0
					if speedBlur.enabled and entitylib.isAlive then
						local velocity = entitylib.character.RootPart.AssemblyLinearVelocity
						fast = math.max(math.sqrt(velocity.X * velocity.X + velocity.Z * velocity.Z) - tuning.FLAT, -velocity.Y - tuning.FALL, 0)
					end

					local turning = rate > tuning.DEADZONE and 1 - math.exp(-(rate - tuning.DEADZONE) / tuning.TURN_SCALE) or 0
					local moving = fast > 0 and tuning.SPEED_SHARE * (1 - math.exp(-fast / tuning.SPEED_SCALE)) or 0
					local target = tuning.PEAK * (strength.value / 100) * (1 - (1 - turning) * (1 - moving))
					size += (target - size) * (1 - math.exp(-(target > size and tuning.RISE or tuning.FALL_RATE) * step))
					show(size)
				end))
			end
		end,
		about = 'Blurs the screen on fast turns and at high speed.\nSlow aiming and walking stay sharp; the blur fades out smoothly.'
	})
	strength = motionBlur:slider('Strength', {
		min = 10,
		max = 100,
		default = 50,
		suffix = '%',
		about = 'How strong the blur gets, from turning and from speed.'
	})
	speedBlur = motionBlur:toggle('Speed Blur', {
		default = true,
		about = 'Also blurs when you move much faster than running, like a long fall or a strong speed boost. Walking and jumping stay sharp.'
	})
end)

--[[ NameTags
Shows name tags above other players, with optional health (green above half, yellow at half or less,
red under a fifth) and distance (green past 30 studs, yellow from 10, red closer), in your font,
size and team or chosen colour. The tag's own text is hidden and carried by two layers, a dark copy
one pixel down and right under the coloured text, because a child always draws over its parent's own
text. Colour emoji (the device icons) draw in colour whatever TextColor3 says, so the shadow keeps
them for their width but does not draw them.

getfontsize yields, so a build in progress is kept in building under a token of its own: a second
Added makes no second tag, and a removal or a disable takes the token, after which the build throws
its tag away. A resize after getfontsize leaves alone a tag that a removal or rebuild took over
meanwhile. Targetable and Friend can change after a tag is made (a held load-in builds everyone
before your own team lands), so Priority Only is checked again on EntityUpdated. The frame loop
writes Visible and Position only when they change, and hides the tags while the menu is open. ]]
run(function()
	local nameTags
	local targets
	local color
	local background
	local displayName
	local health
	local distance
	local scale
	local fontOption
	local teammates
	local distanceCheck
	local distanceLimit
	local strings, sizes, reference = {}, {}, {}
	local shown, placed = {}, {}
	local building = {}
	local folder = Instance.new('Folder')
	folder.Parent = slinky.gui
	local methodused

	local function showTag(ent, nametag, visible)
		if shown[ent] ~= visible then
			nametag.Visible = visible
			shown[ent] = visible
		end
	end

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
	
	local TAG_GREEN, TAG_YELLOW, TAG_RED = Color3.fromRGB(85, 255, 85), Color3.fromRGB(255, 255, 85), Color3.fromRGB(255, 85, 85)

	local function tagHealthColor(ent)
		local fraction = 1
		if type(ent.MaxHealth) == 'number' and ent.MaxHealth > 0 then
			fraction = (ent.Health or ent.MaxHealth) / ent.MaxHealth
		end
		if fraction ~= fraction then
			fraction = 1
		end
		return fraction > 0.5 and TAG_GREEN or fraction >= 0.2 and TAG_YELLOW or TAG_RED
	end

	local function distanceText(studs)
		local colour = studs > 30 and TAG_GREEN or studs >= 10 and TAG_YELLOW or TAG_RED
		return '<font color="#'..colour:ToHex()..'">'..studs..'m</font>'
	end

	local function tagText(ent)
		local text = ent.Player and tags:prefix(ent.Player, true)..(displayName.enabled and ent.Player.DisplayName or ent.Player.Name) or ent.Character.Name
		if health.enabled then
			text = '<font color="#'..tagHealthColor(ent):ToHex()..'">'..math.round(ent.Health or 0)..'\u{2665}</font> '..text
		end
		if distance.enabled then
			text = text..' %s'
		end
		return text
	end

	local added = {
		Normal = function(ent)
			if not targets.players.enabled and ent.Player then return end
			if not targets.npcs.enabled and ent.NPC then return end
			if teammates.enabled and (not ent.Targetable) and (not ent.Friend) then return end
			if reference[ent] or building[ent] then return end
			if slinky.threadFix then
				setthreadidentity(8)
			end
	
			local text = tagText(ent)
	
			local nametag = Instance.new('TextLabel')
			nametag.TextSize = 14 * scale.value
			nametag.FontFace = fontOption.value
			local token = {}
			building[ent] = token
			local size = getfontsize(removeTags(text), nametag.TextSize, nametag.FontFace, Vector2.new(100000, 100000))
			if building[ent] ~= token then
				nametag:Destroy()
				return
			end
			building[ent] = nil
			strings[ent] = text
			nametag.Name = ent.Player and ent.Player.Name or ent.Character.Name
			nametag.Size = UDim2.fromOffset(size.X + 8, size.Y + 7)
			nametag.AnchorPoint = Vector2.new(0.5, 1)
			nametag.BackgroundColor3 = Color3.new()
			nametag.BackgroundTransparency = background.value
			nametag.BorderSizePixel = 0
			nametag.Visible = false
			nametag.Text = strings[ent]
			nametag.TextColor3 = entitylib.getEntityColor(ent) or Color3.fromHSV(color.hue, color.sat, color.value)
			nametag.RichText = true
			shadeTag(nametag)
			nametag.Parent = folder
			reference[ent] = nametag
			shown[ent] = false
		end
	}
	
	local removed = {
		Normal = function(ent)
			building[ent] = nil
			local v = reference[ent]
			if v then
				if slinky.threadFix then
					setthreadidentity(8)
				end
				reference[ent] = nil
				strings[ent] = nil
				sizes[ent] = nil
				shown[ent] = nil
				placed[ent] = nil
				v:Destroy()
			end
		end
	}
	
	local updated = {
		Normal = function(ent)
			if teammates.enabled and (not ent.Targetable) and (not ent.Friend) then
				removed.Normal(ent)
				return
			end
			if not reference[ent] then
				added.Normal(ent)
				return
			end
			local nametag = reference[ent]
			if nametag then
				if slinky.threadFix then
					setthreadidentity(8)
				end
				sizes[ent] = nil
				strings[ent] = tagText(ent)
	
				local size = getfontsize(removeTags(strings[ent]), nametag.TextSize, nametag.FontFace, Vector2.new(100000, 100000))
				if reference[ent] ~= nametag then return end
				nametag.Size = UDim2.fromOffset(size.X + 8, size.Y + 7)
				nametag.Text = strings[ent]
			end
		end
	}
	
	local colorFunc = {
		Normal = function(hue, sat, val)
			local color = Color3.fromHSV(hue, sat, val)
			for i, v in reference do
				v.TextColor3 = entitylib.getEntityColor(i) or color
			end
		end
	}
	
	local loop = {
		Normal = function()
			local hidden = clickGuiOpen()
			for ent, nametag in reference do
				if hidden then
					showTag(ent, nametag, false)
					continue
				end
				if distanceCheck.enabled then
					local distance = entitylib.isAlive and (entitylib.character.RootPart.Position - ent.RootPart.Position).Magnitude or math.huge
					if distance < distanceLimit.min or distance > distanceLimit.max then
						showTag(ent, nametag, false)
						continue
					end
				end

				local headPos, headVis = gameCamera:WorldToViewportPoint(ent.RootPart.Position + Vector3.new(0, ent.HipHeight + 1, 0))
				showTag(ent, nametag, headVis)
				if not headVis then
					continue
				end

				if distance.enabled then
					local mag = entitylib.isAlive and math.floor((entitylib.character.RootPart.Position - ent.RootPart.Position).Magnitude) or 0
					if sizes[ent] ~= mag then
						local text = string.format(strings[ent], distanceText(mag))
						nametag.Text = text
						local size = getfontsize(removeTags(text), nametag.TextSize, nametag.FontFace, Vector2.new(100000, 100000))
						nametag.Size = UDim2.fromOffset(size.X + 8, size.Y + 7)
						sizes[ent] = mag
					end
				end
				local position = UDim2.fromOffset(headPos.X, headPos.Y)
				if placed[ent] ~= position then
					nametag.Position = position
					placed[ent] = position
				end
			end
		end
	}
	
	nameTags = render:module('NameTags', {
		toggled = function(on)
			if on then
				methodused = 'Normal'
				if removed[methodused] then
					nameTags:clean(entitylib.Events.EntityRemoved:Connect(removed[methodused]))
				end
				if added[methodused] then
					for _, v in entitylib.List do
						if reference[v] then
							removed[methodused](v)
						end
						added[methodused](v)
					end
					nameTags:clean(entitylib.Events.EntityAdded:Connect(function(ent)
						if reference[ent] then
							removed[methodused](ent)
						end
						added[methodused](ent)
					end))
				end
				if updated[methodused] then
					nameTags:clean(entitylib.Events.EntityUpdated:Connect(updated[methodused]))
					for _, v in entitylib.List do
						updated[methodused](v)
					end
				end
				if colorFunc[methodused] then
					nameTags:clean(slinky.categories.Friends.colorUpdate.Event:Connect(function()
						colorFunc[methodused](color.hue, color.sat, color.value)
					end))
				end
				if loop[methodused] then
					nameTags:clean(runService.RenderStepped:Connect(loop[methodused]))
				end
			else
				if removed[methodused] then
					for i in reference do
						removed[methodused](i)
					end
				end
				table.clear(building)
			end
		end,
		about = 'Shows clear name tags above other players.\nCan add health and distance, with your own font, size and colors.'
	})
	scale = nameTags:slider('Scale', {
		changed = function()
			if nameTags.enabled then
				nameTags:flip()
				nameTags:flip()
			end
		end,
		default = 1,
		min = 0.1,
		max = 1.5,
		decimal = 10
	})
	nameTags:divider('Extra info')
	health = nameTags:toggle('Health', {
		changed = function()
			if nameTags.enabled then
				nameTags:flip()
				nameTags:flip()
			end
		end
	})
	distance = nameTags:toggle('Distance', {
		changed = function()
			if nameTags.enabled then
				nameTags:flip()
				nameTags:flip()
			end
		end
	})
	nameTags:divider('Extras')
	targets = nameTags:targets({
		players = true,
		changed = function()
			if nameTags.enabled then
				nameTags:flip()
				nameTags:flip()
			end
		end
	})
	fontOption = nameTags:font('Font', {
		exclude = 'Arial',
		changed = function()
			if nameTags.enabled then
				nameTags:flip()
				nameTags:flip()
			end
		end
	})
	color = nameTags:color('Player Color', {
		changed = function(hue, sat, val)
			if nameTags.enabled and colorFunc[methodused] then
				colorFunc[methodused](hue, sat, val)
			end
		end
	})
	background = nameTags:slider('Transparency', {
		changed = function()
			if nameTags.enabled then
				nameTags:flip()
				nameTags:flip()
			end
		end,
		default = 0.5,
		min = 0,
		max = 1,
		decimal = 10
	})
	displayName = nameTags:toggle('Use Displayname', {
		changed = function()
			if nameTags.enabled then
				nameTags:flip()
				nameTags:flip()
			end
		end,
		default = true
	})
	teammates = nameTags:toggle('Priority Only', {
		changed = function()
			if nameTags.enabled then
				nameTags:flip()
				nameTags:flip()
			end
		end,
		default = true,
		about = 'Hides teammates & non targetable entities'
	})
	distanceCheck = nameTags:toggle('Distance Check', {
		changed = function(callback)
			distanceLimit.row.Visible = callback
		end
	})
	distanceLimit = nameTags:range('Player Distance', {
		min = 0,
		max = 256,
		defaultMin = 0,
		defaultMax = 64,
		sub = true,
		visible = false
	})
end)
	
--[[ PlayerModel
Puts a custom 3D model on other players. Set the mesh, texture, size and rotation; Local adds one to
you too. ]]
run(function()
	local playerModel
	local scale
	local localToggle
	local mesh
	local texture
	local rots = {}
	local models = {}
	local modelGeneration = 0
	
	local function addMesh(ent, generation)
		if generation and generation ~= modelGeneration then return end
		if not (playerModel and playerModel.enabled) then return end
		if slinky.threadFix then 
			setthreadidentity(8)
		end
		local root = ent.RootPart
		if not (root and root.Parent) then return end
		local previous = models[root]
		if previous then
			pcall(function() previous:Destroy() end)
			models[root] = nil
		end
		local part = Instance.new('Part')
		part.Size = Vector3.new(3, 3, 3)
		part.CFrame = root.CFrame * CFrame.Angles(math.rad(rots[1].value), math.rad(rots[2].value), math.rad(rots[3].value))
		part.CanCollide = false
		part.CanQuery = false
		part.Massless = true
		part.Parent = workspace
		local meshd = Instance.new('SpecialMesh')
		meshd.MeshId = mesh.value
		meshd.TextureId = texture.value
		meshd.Scale = Vector3.one * scale.value
		meshd.Parent = part
		local weld = Instance.new('WeldConstraint')
		weld.Part0 = part
		weld.Part1 = root
		weld.Parent = part
		models[root] = part
	end
	
	local function removeMesh(ent)
		if models[ent.RootPart] then 
			models[ent.RootPart]:Destroy()
			models[ent.RootPart] = nil
		end
	end
	
	playerModel = render:module('PlayerModel', {
		toggled = function(on)
			if on then 
				modelGeneration += 1
				local generation = modelGeneration
				if localToggle.enabled then 
					playerModel:clean(entitylib.Events.LocalAdded:Connect(function(ent)
						addMesh(ent, generation)
					end))
					playerModel:clean(entitylib.Events.LocalRemoved:Connect(removeMesh))
					if entitylib.isAlive then 
						task.spawn(function()
							if generation == modelGeneration and playerModel.enabled then
								addMesh(entitylib.character, generation)
							end
						end)
					end
				end
				playerModel:clean(entitylib.Events.EntityAdded:Connect(function(ent)
					addMesh(ent, generation)
				end))
				playerModel:clean(entitylib.Events.EntityRemoved:Connect(removeMesh))
				for _, ent in entitylib.List do 
					task.spawn(function()
						if generation == modelGeneration and playerModel.enabled then
							addMesh(ent, generation)
						end
					end)
				end
			else
				modelGeneration += 1
				for _, part in models do 
					part:Destroy()
				end
				table.clear(models)
			end
		end,
		about = 'Puts a custom 3D model on other players.\nSet the mesh, texture, size and rotation; Local adds one to you too.'
	})
	scale = playerModel:slider('Scale', {
		min = 0,
		max = 2,
		default = 1,
		decimal = 100,
		changed = function(val)
			for _, part in models do 
				part.Mesh.Scale = Vector3.one * val
			end
		end
	})
	for _, name in {'Rotation X', 'Rotation Y', 'Rotation Z'} do 
		table.insert(rots, playerModel:slider(name, {
			min = 0,
			max = 360,
			changed = function(val)
				for root, part in models do 
					part.WeldConstraint.Enabled = false
					part.CFrame = root.CFrame * CFrame.Angles(math.rad(rots[1].value), math.rad(rots[2].value), math.rad(rots[3].value))
					part.WeldConstraint.Enabled = true
				end
			end
		}))
	end
	localToggle = playerModel:toggle('Local', {
		changed = function()
			if playerModel.enabled then 
				playerModel:flip()
				playerModel:flip()
			end
		end
	})
	mesh = playerModel:textbox('Mesh', {
		placeholder = 'mesh id',
		changed = function()
			for _, part in models do 
				part.Mesh.MeshId = mesh.value
			end
		end
	})
	texture = playerModel:textbox('Texture', {
		placeholder = 'texture id',
		changed = function()
			for _, part in models do 
				part.Mesh.TextureId = texture.value
			end
		end
	})
	
end)
	
--[[ Radar
An overlay card with a dot for each targetable or friendly player, placed by where they are relative
to you and the way the camera faces, and kept inside the card with Clamp Radar. The accent bar
follows the GUI colour while Bar Color is left at its own default (the old orange) or at the older
teal default the shipped profiles still save. ]]
run(function()
	local radar
	local targets
	local dotStyle
	local playerColor
	local clamp
	local barColorOption
	local reference = {}
	local bkg, bar
	local barDefaults = {{Color3.fromRGB(243, 93, 18):ToHSV()}, {0.44, 1, 1}}

	local function barColor()
		local h, s, v = barColorOption.hue, barColorOption.sat, barColorOption.value
		if not barColorOption.rainbow then
			for _, default in barDefaults do
				if math.abs(h - default[1]) < 1e-3 and math.abs(s - default[2]) < 1e-3 and math.abs(v - default[3]) < 1e-3 then
					h, s, v = slinky.accent.hue, slinky.accent.sat, slinky.accent.value
					break
				end
			end
		end
		return Color3.fromHSV(h, s, v)
	end

	local function added(ent)
		if not targets.players.enabled and ent.Player then return end
		if not targets.npcs.enabled and ent.NPC then return end
		if (not ent.Targetable) and (not ent.Friend) then return end
		if slinky.threadFix then
			setthreadidentity(8)
		end
	
		local dot = Instance.new('Frame')
		dot.Size = UDim2.fromOffset(4, 4)
		dot.AnchorPoint = Vector2.new(0.5, 0.5)
		dot.BackgroundColor3 = entitylib.getEntityColor(ent) or Color3.fromHSV(playerColor.hue, playerColor.sat, playerColor.value)
		dot.Parent = bkg
		local corner = Instance.new('UICorner')
		corner.CornerRadius = UDim.new(dotStyle.value == 'Circles' and 1 or 0, 0)
		corner.Parent = dot
		local stroke = Instance.new('UIStroke')
		stroke.Color = Color3.new()
		stroke.Thickness = 1
		stroke.Transparency = 0.8
		stroke.Parent = dot
		reference[ent] = dot
	end
	
	local function removed(ent)
		local v = reference[ent]
		if v then
			if slinky.threadFix then
				setthreadidentity(8)
			end
			reference[ent] = nil
			v:Destroy()
		end
	end
	
	radar = slinky:overlay('Radar', {
		toggled = function(on)
			if on then
				radar:clean(entitylib.Events.EntityRemoved:Connect(removed))
				for _, v in entitylib.List do
					if reference[v] then
						removed(v)
					end
					added(v)
				end
				radar:clean(entitylib.Events.EntityAdded:Connect(function(ent)
					if reference[ent] then
						removed(ent)
					end
					added(ent)
				end))
				radar:clean(slinky.categories.Friends.colorUpdate.Event:Connect(function()
					for ent, dot in reference do
						dot.BackgroundColor3 = entitylib.getEntityColor(ent) or Color3.fromHSV(playerColor.hue, playerColor.sat, playerColor.value)
					end
				end))
				radar:clean(runService.RenderStepped:Connect(function()
					local accent = barColor()
					if bar.BackgroundColor3 ~= accent then
						bar.BackgroundColor3 = accent
					end
					if entitylib.isAlive and next(reference) then
						local view = CFrame.lookAlong(entitylib.character.RootPart.Position, gameCamera.CFrame.LookVector * Vector3.new(1, 0, 1))
						for ent, dot in reference do
							local dt = view:PointToObjectSpace(ent.RootPart.Position)
							dot.Position = UDim2.fromOffset(clamp.enabled and math.clamp(108 + dt.X, 2, 214) or 108 + dt.X, clamp.enabled and math.clamp(108 + dt.Z, 8, 214) or 108 + dt.Z)
						end
					end
				end))
			else
				for ent in reference do
					removed(ent)
				end
			end
		end
	})
	targets = radar:targets({
		players = true,
		changed = function()
			if radar.switch.enabled then
				radar.switch:flip()
				radar.switch:flip()
			end
		end
	})
	dotStyle = radar:dropdown('Dot Style', {
		choices = {'Circles', 'Squares'},
		changed = function(val)
			for _, dot in reference do
				dot.UICorner.CornerRadius = UDim.new(val == 'Circles' and 1 or 0, 0)
			end
		end
	})
	playerColor = radar:color('Player Color', {
		changed = function(hue, sat, val)
			for ent, dot in reference do
				dot.BackgroundColor3 = entitylib.getEntityColor(ent) or Color3.fromHSV(hue, sat, val)
			end
		end
	})
	bkg = Instance.new('Frame')
	bkg.Size = UDim2.fromOffset(216, 216)
	bkg.Position = UDim2.fromOffset(2, 2)
	bkg.ClipsDescendants = true
	bkg.Parent = radar.frame
	local stroke = loaderStyle.box(bkg)
	local line1 = Instance.new('Frame')
	line1.Size = UDim2.new(0, 1, 1, 0)
	line1.Position = UDim2.fromScale(0.5, 0.5)
	line1.AnchorPoint = Vector2.new(0.5, 0.5)
	line1.ZIndex = 0
	line1.BackgroundColor3 = loaderStyle.SubText
	line1.BackgroundTransparency = 0.6
	line1.BorderSizePixel = 0
	line1.Parent = bkg
	local line2 = line1:Clone()
	line2.Size = UDim2.new(1, 0, 0, 1)
	line2.Parent = bkg
	bar = Instance.new('Frame')
	bar.Size = UDim2.new(1, -20, 0, 2)
	bar.Position = UDim2.fromOffset(10, 0)
	bar.BorderSizePixel = 0
	bar.Parent = bkg
	local barcorner = Instance.new('UICorner')
	barcorner.CornerRadius = UDim.new(1, 0)
	barcorner.Parent = bar
	radar:toggle('Show Background', {
		default = true,
		changed = function(callback)
			bkg.BackgroundTransparency = callback and loaderStyle.Transparency or 1
			bar.BackgroundTransparency = callback and 0 or 1
			stroke.Transparency = callback and loaderStyle.EdgeTransparency or 1
		end
	})
	radar:toggle('Show Cross', {
		default = true,
		changed = function(callback)
			line1.BackgroundTransparency = callback and 0.6 or 1
			line2.BackgroundTransparency = callback and 0.6 or 1
		end
	})
	radar:toggle('Accent Bar', {
		default = true,
		changed = function(callback)
			bar.Visible = callback
			if barColorOption then
				barColorOption.row.Visible = callback
			end
		end
	})
	barColorOption = radar:color('Bar Color', {
		sub = true,
		changed = function()
			bar.BackgroundColor3 = barColor()
		end
	})
	bar.BackgroundColor3 = barColor()
	clamp = radar:toggle('Clamp Radar', {
		default = true
	})
end)
	
--[[ Search
Draws boxes through walls around every part or model whose name is on the list. The workspace is
watched only while Search is on and walked again each time it turns on, since every block,
projectile, particle and effect the game adds would otherwise pass through the handler; any change
to the list restarts it. The folder leaves the GUI while the menu is open, so its boxes stop
drawing. ]]
run(function()
	local search
	local list
	local color
	local fillTransparency
	local reference = {}
	local names = {}
	local folder = Instance.new('Folder')
	folder.Parent = slinky.gui

	local function add(v)
		if reference[v] then return end
		if not table.find(list.active, v.Name) then return end
		if v:IsA('BasePart') or v:IsA('Model') then
			local size = v:IsA('Model') and v:GetExtentsSize() or v.Size
			local box = Instance.new('BoxHandleAdornment')
			box.AlwaysOnTop = true
			box.Adornee = v
			box.Size = size.Magnitude > 0.4 and size or Vector3.one
			box.ZIndex = 0
			box.Transparency = fillTransparency.value
			box.Color3 = Color3.fromHSV(color.hue, color.sat, color.value)
			box.Parent = folder
			reference[v] = box
			end
	end

	local function addCandidate(v)
		if not names[v.Name] then return end
		if search and search.enabled then
			add(v)
		end
	end

	search = render:module('Search', {
		toggled = function(on)
			if on then
				table.clear(names)
				for _, name in list.active do
					names[name] = true
				end
				search:clean(workspace.DescendantAdded:Connect(addCandidate))
				search:clean(workspace.DescendantRemoving:Connect(function(v)
					if reference[v] then
						reference[v]:Destroy()
						reference[v] = nil
					end
				end))
				for _, v in workspace:GetDescendants() do
					if names[v.Name] then
						add(v)
					end
				end
				if slinky.threadFix then
					setthreadidentity(8)
				end
				local scaled = slinky.gui:FindFirstChild('ScaledGui')
				local clickGui = scaled and scaled:FindFirstChild('ClickGui')
				if clickGui then
					folder.Parent = (not clickGui.Visible) and slinky.gui or nil
					search:clean(clickGui:GetPropertyChangedSignal('Visible'):Connect(function()
						if slinky.threadFix then
							setthreadidentity(8)
						end
						folder.Parent = (not clickGui.Visible) and slinky.gui or nil
					end))
				end
			else
			folder:ClearAllChildren()
			if slinky.threadFix then
				setthreadidentity(8)
			end
			folder.Parent = slinky.gui
			table.clear(reference)
		end
		end,
		about = 'Shows boxes around parts you name, even through walls.\nAdd part names to the list and pick the box color and transparency.'
	})
	list = search:list('Parts', {
		changed = function()
			if search.enabled then
				search:flip()
				search:flip()
			end
		end
	})
	color = search:color('Color', {
		changed = function(hue, sat, val)
			for _, v in reference do
				v.Color3 = Color3.fromHSV(hue, sat, val)
			end
		end
	})
	fillTransparency = search:slider('Transparency', {
		min = 0,
		max = 1,
		changed = function(val)
			for _, v in reference do
				v.Transparency = val
			end
		end,
	decimal = 10
})
end)

--[[ The sessioninfo library is pure data with no GUI dependency, so it registers in its own
block ahead of the Session Info overlay. It used to be created at the tail of the overlay
block, meaning any failure in the overlay's instance work (or in anything before it, while
the runner was still unguarded) left slinky.Libraries.sessioninfo unset -- and the place
files capture it into a file-local exactly once, so they then indexed nil for the rest of
the session no matter what universal did later. ]]
run(function()
	local sessioninfo = ensureSessionInfo()
	if not sessioninfo.Objects['Time Played'] then
		sessioninfo:AddItem('Time Played', os.clock(), function(value)
			return os.date('!%X', math.floor(os.clock() - value))
		end)
	end
end)

--[[ Session Info
An overlay card listing the sessioninfo library's entries, refreshed once a second, with an optional
title and custom line; entries named on the Blacklist are left out. Saved values cross a teleport
through queue_on_teleport. With a Blacklist the lines are rebuilt into a fresh table rather than
compacted in place: table.remove during a next() walk is undefined in Lua and can skip entries,
revisit them or crash the client, which no pcall catches. The card is built before the options, so
the Border toggle reaches its stroke. ]]
run(function()
	local sessionInfo
	local fontOption
	local hide
	local textSize
	local borderColor
	local title
	local titleOffset = {}
	local custom
	local customBox
	local infoholder
	local infolabel
	local infostroke

	local TITLE = '<b>Session Info</b>'
	local KEY = '<font color="'..loaderStyle.SubHex..'">%s:</font> %s'

	sessionInfo = slinky:overlay('Session Info', {
		toggled = function(on)
			if on then
				local teleportedServers
				sessionInfo:clean(playersService.LocalPlayer.OnTeleport:Connect(function()
					if not teleportedServers then
						teleportedServers = true
						queue_on_teleport("shared.slinkysessioninfo = '"..httpService:JSONEncode(slinky.libraries.sessioninfo.Objects).."'")
					end
				end))
	
				if shared.slinkysessioninfo then
					for i, v in httpService:JSONDecode(shared.slinkysessioninfo) do
						if slinky.libraries.sessioninfo.Objects[i] and v.Saved then
							slinky.libraries.sessioninfo.Objects[i].Value = v.Value
						end
					end
				end
	
				repeat
					if slinky.libraries.sessioninfo then
						local stuff = {''}
						if title.enabled then
							stuff[1] = titleOffset.enabled and TITLE..'\n<font size="4"> </font>' or TITLE
						end
	
						for i, v in slinky.libraries.sessioninfo.Objects do
							stuff[v.Index] = not table.find(hide.active, i) and KEY:format(i, v.Function(v.Value)) or false
						end

						if #hide.active > 0 then
							local kept = {}
							for index = 1, #stuff do
								local entry = stuff[index]
								if entry ~= false and entry ~= nil then
									table.insert(kept, entry)
								end
							end
							stuff = kept
						end
	
						if custom.enabled then
							table.insert(stuff, customBox.value)
						end
	
						if not title.enabled then
							table.remove(stuff, 1)
						end
						infolabel.Text = table.concat(stuff, '\n')
						infolabel.TextSize = textSize.value
						local size = getfontsize(removeTags(infolabel.Text), infolabel.TextSize, infolabel.FontFace)
						infoholder.Size = UDim2.fromOffset(size.X + 20, size.Y + (title.enabled and titleOffset.enabled and 4 or 16))
					end
	
					task.wait(1)
				until not sessionInfo.switch or not sessionInfo.switch.enabled
			end
		end
	})
	infoholder = Instance.new('Frame')
	infoholder.Parent = sessionInfo.frame
	infostroke = loaderStyle.box(infoholder)
	slinky:clean(sessionInfo.frame:GetPropertyChangedSignal('AbsolutePosition'):Connect(function()
		if slinky.threadFix then
			setthreadidentity(8)
		end
		local newside = sessionInfo.frame.AbsolutePosition.X > (slinky.gui.AbsoluteSize.X / 2)
		infoholder.Position = UDim2.fromScale(newside and 1 or 0, 0)
		infoholder.AnchorPoint = Vector2.new(newside and 1 or 0, 0)
	end))
	infolabel = Instance.new('TextLabel')
	infolabel.Size = UDim2.new(1, -20, 1, -16)
	infolabel.Position = UDim2.fromOffset(10, 8)
	infolabel.BackgroundTransparency = 1
	infolabel.TextXAlignment = Enum.TextXAlignment.Left
	infolabel.TextYAlignment = Enum.TextYAlignment.Top
	infolabel.TextSize = 16
	infolabel.RichText = true
	loaderStyle.text(infolabel, 'Medium')
	infolabel.Parent = infoholder

	fontOption = sessionInfo:font('Font', {
		exclude = 'Arial'
	})
	hide = sessionInfo:list('Blacklist', {
		about = 'Name of entry to hide.',
		color = Color3.fromRGB(250, 50, 56)
	})
	sessionInfo:color('Background Color', loaderStyle.backgroundOption({
		changed = function(hue, sat, val, opacity)
			infoholder.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
			infoholder.BackgroundTransparency = 1 - opacity
		end
	}))
	textSize = sessionInfo:slider('Text Size', {
		min = 1,
		max = 30,
		default = 16
	})
	title = sessionInfo:toggle('Title', {
		changed = function(callback)
			if titleOffset.row then
				titleOffset.row.Visible = callback
			end
		end,
		default = true
	})
	titleOffset = sessionInfo:toggle('Offset', {
		default = true,
		sub = true
	})
	sessionInfo:toggle('Border', {
		default = true,
		changed = function(callback)
			infostroke.Enabled = callback
			if borderColor then
				borderColor.row.Visible = callback
			end
		end
	})
	borderColor = sessionInfo:color('Border Color', {
		hue = loaderStyle.EdgeHue,
		sat = loaderStyle.EdgeSat,
		value = loaderStyle.EdgeValue,
		opacity = 1 - loaderStyle.EdgeTransparency,
		changed = function(hue, sat, val, opacity)
			local colour, alpha = loaderStyle.edge(hue, sat, val, opacity)
			infostroke.Color = colour
			infostroke.Transparency = 1 - alpha
		end,
		sub = true
	})
	custom = sessionInfo:toggle('Add custom text', {
		changed = function(enabled)
			customBox.row.Visible = enabled
		end
	})
	customBox = sessionInfo:textbox('Custom text', {
		sub = true,
		visible = false
	})
end)

--[[ Killaura Info
Developer-only overlay showing Killaura's telemetry from entitylib.Performance four times a second:
attempts, confirmed, pending and dropped hits, hit and swing rates and gaps, and, while the
diagnostics sampler runs, frame and heartbeat times, ping, spikes, correction signals and memory,
plus targeting and cache rates. Turning it on enables Performance with its Killaura telemetry and
diagnostics; turning it off, or starting a new run, puts back whether Performance was enabled
before. The overlay keeps the name 'Killaura Info' so existing developer profiles still load. ]]
if shared.PistonwareDeveloper == true then
	run(function()
		local killauraInfo
		local fontOption
		local textSize
		local borderColor
		local title
		local titleOffset
		local infoholder
		local infolabel
		local infostroke
		local lifecycle = 0
		local activeRun

		local function stopRun(run)
			if not run or run.Cleaned then return end
			run.Cleaned = true
			if activeRun == run then
				activeRun = nil
			end
			lifecycle += 1

			local thread = run.Thread
			if thread and thread ~= coroutine.running() and coroutine.status(thread) ~= 'dead' then
				pcall(task.cancel, thread)
			end

			local performance = run.Performance
			if performance then
				pcall(function()
					performance:StopDiagnostics()
				end)
				pcall(function()
					performance:SetKillauraTelemetry(false)
				end)
				if run.WasPerformanceEnabled ~= nil then
					pcall(function()
						performance:SetEnabled(run.WasPerformanceEnabled)
					end)
				end
			end
			run.Thread = nil
			run.Performance = nil
			run.WasPerformanceEnabled = nil

			if infolabel then infolabel.Text = '' end
			if infoholder then infoholder.Visible = false end
		end

		local function getKillaura()
			local modules = slinky.modules
			return modules and modules.Killaura
		end

		local function formatMilliseconds(value)
			return type(value) == 'number' and value >= 0 and string.format('%.1f ms', value * 1000) or '--'
		end

		local function formatPing(value)
			return type(value) == 'number' and value >= 0 and string.format('%.0f ms', value) or '--'
		end

		local function formatRate(value)
			return type(value) == 'number' and string.format('%.2f/s', value) or '--'
		end

		local function formatCount(value)
			return type(value) == 'number' and tostring(math.floor(value + 0.5)) or '--'
		end

		local function formatPercent(value)
			return type(value) == 'number' and string.format('%.1f%%', value * 100) or '--'
		end

		local function formatMemory(value)
			return type(value) == 'number' and string.format('%.0f MB', value) or '--'
		end

		local function formatAge(now, timestamp)
			return type(timestamp) == 'number' and string.format('%.1fs ago', math.max(now - timestamp, 0)) or '--'
		end

		local function getTargetName(target)
			if not target then return 'none' end
			local name
			pcall(function()
				if type(target) == 'table' and target.Player then
					name = target.Player.DisplayName or target.Player.Name
				else
					name = target.Name
				end
			end)
			return removeTags(tostring(name or 'target'))
		end

		killauraInfo = slinky:overlay('Killaura Info', {
			categorySize = 240,
			toggled = function(on)
				if not on then
					stopRun(activeRun)
					return
				end

				stopRun(activeRun)
				lifecycle += 1
				local currentLifecycle = lifecycle
				local performance = entitylib.Performance
				local run = {
					Performance = performance,
					WasPerformanceEnabled = performance:IsEnabled(),
					Thread = coroutine.running()
				}
				activeRun = run
				killauraInfo:clean(function()
					stopRun(run)
				end)

					performance:SetEnabled(true)
					performance:SetKillauraTelemetry(true)
					performance:StartDiagnostics()

					local previousStats = performance:Snapshot()
					local previousStatsAt = os.clock()
					if infoholder then infoholder.Visible = true end

					repeat
						local now = os.clock()
						local currentStats = performance:Snapshot()
						local statsElapsed = math.max(now - previousStatsAt, 0.001)
						local function statRate(name)
							return math.max((currentStats[name] or 0) - (previousStats[name] or 0), 0) / statsElapsed
						end
						local cacheHits = statRate('TargetCacheHits')
						local cacheRefreshes = statRate('TargetCacheRefreshes')
						local cacheTotal = cacheHits + cacheRefreshes
						local cacheRatio = cacheTotal > 0 and string.format('%.1f%%', cacheHits / cacheTotal * 100) or '--'
						local scanRate = statRate('TargetScans')
						local candidateRate = statRate('TargetCandidates')
						local raycastRate = statRate('Raycasts')
						local updateRate = statRate('EntityUpdates')
						previousStats = currentStats
						previousStatsAt = now

						local telemetry = performance:KillauraSnapshot(now)
						local diagnostics = performance:DiagnosticsSnapshot(now)
						local killaura = getKillaura()
						local status = killaura and (killaura.enabled and 'ON' or 'OFF') or 'UNAVAILABLE'
						local render = diagnostics.Render
						local heartbeat = diagnostics.Heartbeat
						local ping = diagnostics.Ping
						local spikes = diagnostics.Spikes
						local corrections = diagnostics.Corrections
						local lines = {}
						local showTitle = not title or title.enabled
						if showTitle then
							lines[#lines + 1] = titleOffset and titleOffset.enabled and '<b>Developer Diagnostics</b>\n<font size="4"> </font>' or '<b>Developer Diagnostics</b>'
						end
						lines[#lines + 1] = 'Killaura: '..status..' | Target: '..getTargetName(telemetry.LastTarget)
						lines[#lines + 1] = 'Attempts: '..formatCount(telemetry.SwingCount)..' | Confirmed: '..formatCount(telemetry.ConfirmedCount)..' | Pending: '..formatCount(telemetry.PendingCount)
						lines[#lines + 1] = 'Expired: '..formatCount(telemetry.ExpiredCount)..' | Dropped: '..formatCount(telemetry.DroppedCount)
						lines[#lines + 1] = 'Finalized hit ratio: '..formatPercent(telemetry.Accuracy)..' | provisional '..formatPercent(telemetry.ProvisionalAccuracy)
						lines[#lines + 1] = 'Hit rate: '..formatRate(telemetry.HitRate)..' rolling 5s | Swing rate: '..formatRate(telemetry.SwingRate)
						lines[#lines + 1] = 'Hit gap: '..formatMilliseconds(telemetry.AverageHitGap)..' avg | Swing gap: '..formatMilliseconds(telemetry.AverageSwingGap)..' avg'
						lines[#lines + 1] = 'Confirm source: matched adapter event | Telemetry uptime: '..string.format('%.1fs', telemetry.Elapsed or 0)
						if diagnostics.Enabled then
							lines[#lines + 1] = 'Render FPS: '..formatCount(render.Fps)..' | 1% low: '..formatCount(render.Low1PercentFps)
							lines[#lines + 1] = 'Frame: '..formatMilliseconds(render.FrameAverage)..' avg | '..formatMilliseconds(render.FrameP95)..' p95 | '..formatMilliseconds(render.FrameMax)..' max'
							lines[#lines + 1] = 'Heartbeat: '..formatMilliseconds(heartbeat.Average)..' avg | '..formatMilliseconds(heartbeat.P95)..' p95 | '..formatMilliseconds(heartbeat.Max)..' max'
							lines[#lines + 1] = 'Ping: '..formatPing(ping.Current)..' now | '..formatPing(ping.Average)..' avg | '..formatPing(ping.P95)..' p95 | jitter '..formatPing(ping.Jitter)
							lines[#lines + 1] = 'Spikes/10s: render '..formatCount(spikes.Render)..' | heartbeat '..formatCount(spikes.Heartbeat)..' | ping '..formatCount(spikes.Network)
							lines[#lines + 1] = 'Last spikes: render '..formatMilliseconds(spikes.LastRender)..' | heartbeat '..formatMilliseconds(spikes.LastHeartbeat)..' | ping '..formatPing(spikes.LastNetwork)
							lines[#lines + 1] = 'Samples: render '..formatCount(render.Samples)..' | heartbeat '..formatCount(heartbeat.Samples)..' | ping '..formatCount(ping.Samples)
							lines[#lines + 1] = 'Correction signals: '..formatCount(corrections.Count)..' total | '..formatCount(corrections.Recent)..' recent | '..(corrections.LastReason or 'none')..' ('..formatAge(now, corrections.LastAt)..')'
							lines[#lines + 1] = 'Memory: '..formatMemory(diagnostics.Memory)
						else
							lines[#lines + 1] = 'Diagnostics sampler: unavailable'
						end
						lines[#lines + 1] = 'Targeting/s: scan '..formatRate(scanRate)..' | candidates '..formatRate(candidateRate)..' | raycast '..formatRate(raycastRate)
						lines[#lines + 1] = 'Cache: '..cacheRatio..' hit | entity updates '..formatRate(updateRate)

						infolabel.Text = table.concat(lines, '\n')
						infolabel.FontFace = fontOption.value
						infolabel.TextSize = textSize.value
						local size = getfontsize(removeTags(infolabel.Text), infolabel.TextSize, infolabel.FontFace)
						infoholder.Size = UDim2.fromOffset(math.max(420, math.min(size.X + 16, 640)), size.Y + (showTitle and titleOffset and titleOffset.enabled and 4 or 16))
						task.wait(0.25)
					until lifecycle ~= currentLifecycle or not killauraInfo.switch or not killauraInfo.switch.enabled

				if activeRun == run then
					stopRun(run)
				end
			end
		})
		fontOption = killauraInfo:font('Font', {
			exclude = 'Arial'
		})
		killauraInfo:color('Background Color', {
			value = 0,
			opacity = 0.5,
			changed = function(hue, sat, val, opacity)
				if infoholder then
					infoholder.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
					infoholder.BackgroundTransparency = 1 - opacity
				end
			end
		})
		borderColor = killauraInfo:color('Border Color', {
			changed = function(hue, sat, val, opacity)
				if infostroke then
					infostroke.Color = Color3.fromHSV(hue, sat, val)
					infostroke.Transparency = 1 - opacity
				end
			end,
			sub = true,
			visible = false
		})
		textSize = killauraInfo:slider('Text Size', {
			min = 1,
			max = 30,
			default = 16
		})
		title = killauraInfo:toggle('Title', {
			changed = function(callback)
				if titleOffset and titleOffset.row then
					titleOffset.row.Visible = callback
				end
			end,
			default = true
		})
		titleOffset = killauraInfo:toggle('Offset', {
			default = true,
			sub = true
		})
		killauraInfo:toggle('Border', {
			changed = function(callback)
				if infostroke then infostroke.Enabled = callback end
				if borderColor and borderColor.row then borderColor.row.Visible = callback end
			end
		})
		infoholder = Instance.new('Frame')
		infoholder.BackgroundColor3 = Color3.new()
		infoholder.BackgroundTransparency = 0.5
		infoholder.Parent = killauraInfo.frame
		slinky:clean(killauraInfo.frame:GetPropertyChangedSignal('AbsolutePosition'):Connect(function()
			if slinky.threadFix then
				setthreadidentity(8)
			end
			local newside = killauraInfo.frame.AbsolutePosition.X > (slinky.gui.AbsoluteSize.X / 2)
			infoholder.Position = UDim2.fromScale(newside and 1 or 0, 0)
			infoholder.AnchorPoint = Vector2.new(newside and 1 or 0, 0)
		end))
		local infocorner = Instance.new('UICorner')
		infocorner.CornerRadius = UDim.new(0, 5)
		infocorner.Parent = infoholder
		infolabel = Instance.new('TextLabel')
		infolabel.Size = UDim2.new(1, -16, 1, -16)
		infolabel.Position = UDim2.fromOffset(8, 8)
		infolabel.BackgroundTransparency = 1
		infolabel.TextXAlignment = Enum.TextXAlignment.Left
		infolabel.TextYAlignment = Enum.TextYAlignment.Top
		infolabel.TextSize = 16
		infolabel.TextColor3 = Color3.new(1, 1, 1)
		infolabel.TextStrokeColor3 = Color3.new()
		infolabel.TextStrokeTransparency = 0.8
		infolabel.Font = Enum.Font.Arial
		infolabel.RichText = true
		infolabel.Parent = infoholder
		infostroke = Instance.new('UIStroke')
		infostroke.Enabled = false
		infostroke.Color = Color3.fromRGB(243, 93, 18)
		infostroke.Parent = infoholder
	end)
end

--[[ Tracers
Draws a line from the middle, the bottom or the mouse to each other player's head or torso, in their
team colour, a set colour or by distance, optionally only inside a distance range; Behind points the
line for someone behind you towards the screen edge. Without the Drawing library it warns and turns
off, checked by use since some executors hand Drawing over as userdata.

Everything runs at the raised identity: where Drawing is built from GUI objects (phone executors
like Delta) a write without it can fail, and a RenderStepped callback does not always carry it.
Writes go through set, which skips a value equal to the last one written; colour and transparency
are written by the frame loop too, so nothing else touches a line. A line the executor cannot make,
or one that refuses a property, is removed and left out. Drawing works in viewport pixels, so the
start is taken from the camera's ViewportSize. Targetable and Friend are asked again on
EntityUpdated, since a team can land late; only a line about to be made checks that the entity is
still listed, so an update after it has gone cannot leave a line nothing takes down. One line
failing hides only that line for the frame. ]]
run(function()
	local tracers
	local targets
	local color
	local transparency
	local startPosition
	local endPosition
	local teammates
	local distanceColor
	local distanceToggle
	local distanceLimit
	local behind
	local reference = {}

	local function raiseIdentity()
		if slinky.threadFix and not pcall(setthreadidentity, 8) then
			pcall(setthreadidentity, 7)
		end
	end

	local written = setmetatable({}, {__mode = 'k'})
	
	local function set(line, key, value)
		local last = written[line]
		if last[key] ~= value then
			line[key] = value
			last[key] = value
		end
	end
	
	local function passes(ent)
		if not targets.players.enabled and ent.Player then return false end
		if not targets.npcs.enabled and ent.NPC then return false end
		if teammates.enabled and (not ent.Targetable) and (not ent.Friend) then return false end
		return true
	end
	
	local function tracerColor(ent)
		return entitylib.getEntityColor(ent) or Color3.fromHSV(color.hue, color.sat, color.value)
	end
	
	local function applyProps(line, props)
		for key, value in props do
			line[key] = value
		end
	end

	local function added(ent)
		if not passes(ent) then return end
		raiseIdentity()
		local props = {Thickness = 1, Transparency = 1 - transparency.value, Color = tracerColor(ent)}
		local made, entityTracer = pcall(function()
			return Drawing.new('Line')
		end)
		if not made or entityTracer == nil then return end
		if not pcall(applyProps, entityTracer, props) then
			pcall(function()
				entityTracer:Remove()
			end)
			return
		end
		written[entityTracer] = props
		reference[ent] = entityTracer
	end
	
	local function removed(ent)
		local v = reference[ent]
		if v then
			raiseIdentity()
			reference[ent] = nil
			written[v] = nil
			pcall(function()
				v.Visible = false
				v:Remove()
			end)
		end
	end

	local function updated(ent)
		if reference[ent] then
			if not passes(ent) then
				removed(ent)
			end
		elseif passes(ent) and table.find(entitylib.List, ent) then
			added(ent)
		end
	end
	
	local function drawTracer(ent, entityTracer, startVector)
		local distance = entitylib.isAlive and (entitylib.character.RootPart.Position - ent.RootPart.Position).Magnitude
		if distanceToggle.enabled and distance then
			if distance < distanceLimit.min or distance > distanceLimit.max then
				set(entityTracer, 'Visible', false)
				return
			end
		end
	
		local pos = ent[endPosition.value == 'Torso' and 'RootPart' or 'Head'].Position
		local rootPos, rootVis = gameCamera:WorldToViewportPoint(pos)
		if not rootVis and behind.enabled then
			local tempPos = gameCamera.CFrame:PointToObjectSpace(pos)
			tempPos = CFrame.Angles(0, 0, (math.atan2(tempPos.Y, tempPos.X) + math.pi)):VectorToWorldSpace((CFrame.Angles(0, math.rad(89.9), 0):VectorToWorldSpace(Vector3.new(0, 0, -1))))
			rootPos = gameCamera:WorldToViewportPoint(gameCamera.CFrame:pointToWorldSpace(tempPos))
			rootVis = true
		end
	
		set(entityTracer, 'From', startVector)
		set(entityTracer, 'To', Vector2.new(rootPos.X, rootPos.Y))
		set(entityTracer, 'Transparency', 1 - transparency.value)
		if distanceColor.enabled then
			if distance then
				set(entityTracer, 'Color', Color3.fromHSV(math.min((distance / 128) / 2.8, 0.4), 0.89, 0.75))
			end
		else
			set(entityTracer, 'Color', tracerColor(ent))
		end
		set(entityTracer, 'Visible', rootVis)
	end
	
	local function loop()
		raiseIdentity()
		if clickGuiOpen() then
			for _, entityTracer in reference do
				pcall(set, entityTracer, 'Visible', false)
			end
			return
		end
		local screenSize = gameCamera.ViewportSize
		local startVector = startPosition.value == 'Mouse' and inputService:GetMouseLocation() or Vector2.new(screenSize.X / 2, (startPosition.value == 'Middle' and screenSize.Y / 2 or screenSize.Y))

		for ent, entityTracer in reference do
			if not pcall(drawTracer, ent, entityTracer, startVector) then
				pcall(set, entityTracer, 'Visible', false)
			end
		end
	end
	
	tracers = render:module('Tracers', {
		toggled = function(on)
			if on then
				if not pcall(function() assert(Drawing.new) end) then
					notif('Tracers', 'Your executor has no Drawing library to draw with.', 5, 'warning')
					if tracers.enabled then
						tracers:flip(nil, true)
					end
					return
				end
				tracers:clean(entitylib.Events.EntityRemoved:Connect(removed))
				for _, v in entitylib.List do
					if reference[v] then
						removed(v)
					end
					added(v)
				end
				tracers:clean(entitylib.Events.EntityAdded:Connect(function(ent)
					if reference[ent] then
						removed(ent)
					end
					added(ent)
				end))
				tracers:clean(entitylib.Events.EntityUpdated:Connect(updated))
				tracers:clean(runService.RenderStepped:Connect(loop))
			else
				for i in reference do
					removed(i)
				end
			end
		end,
		about = 'Draws lines from your screen to other players.\nSet where lines start and end, colors, distance limits and off-screen lines.'
	})
	targets = tracers:targets({
		players = true,
		changed = function()
			if tracers.enabled then
				tracers:flip()
				tracers:flip()
			end
		end
	})
	startPosition = tracers:dropdown('Start Position', {
		choices = {'Middle', 'Bottom', 'Mouse'},
		changed = function()
			if tracers.enabled then
				tracers:flip()
				tracers:flip()
			end
		end
	})
	endPosition = tracers:dropdown('End Position', {
		choices = {'Head', 'Torso'},
		changed = function()
			if tracers.enabled then
				tracers:flip()
				tracers:flip()
			end
		end
	})
	color = tracers:color('Player Color')
	transparency = tracers:slider('Transparency', {
		min = 0,
		max = 1,
		decimal = 10
	})
	distanceColor = tracers:toggle('Color by distance', {
		changed = function()
			if tracers.enabled then
				tracers:flip()
				tracers:flip()
			end
		end
	})
	distanceToggle = tracers:toggle('Distance Check', {
		changed = function(callback)
			distanceLimit.row.Visible = callback
		end
	})
	distanceLimit = tracers:range('Player Distance', {
		min = 0,
		max = 256,
		defaultMin = 0,
		defaultMax = 64,
		sub = true,
		visible = false
	})
	behind = tracers:toggle('Behind', {
		default = true
	})
	teammates = tracers:toggle('Priority Only', {
		changed = function()
			if tracers.enabled then
				tracers:flip()
				tracers:flip()
			end
		end,
		default = true,
		about = 'Hides teammates & non targetable entities'
	})
end)
	
--[[ Waypoints
Shows labelled markers at saved points, entered as 'x, y, z/name' or added where you stand. The
cards live in Pistonware's GUI (CoreGui or gethui), so switching on and off both run at the raised
identity, guarded because setthreadidentity(8) throws on an executor capped below 8. Each billboard
is adorned to Terrain, which sits at the world origin, so its offset is the point itself; a
billboard in the GUI folder with no Adornee is drawn nowhere. Each point is built whole before it is
parented, so a malformed entry costs only itself. The folder leaves the GUI while the menu is open.
]]
run(function()
	local waypoints
	local fontOption
	local list
	local color
	local scale
	local background
	waypointFolder = Instance.new('Folder')
	waypointFolder.Parent = slinky.gui
	
	waypoints = render:module('Waypoints', {
		toggled = function(on)
			if slinky.threadFix and not pcall(setthreadidentity, 8) then
				pcall(setthreadidentity, 7)
			end
			if on then
				local scaled = slinky.gui:FindFirstChild('ScaledGui')
				local clickGui = scaled and scaled:FindFirstChild('ClickGui')
				if clickGui then
					waypointFolder.Parent = (not clickGui.Visible) and slinky.gui or nil
					waypoints:clean(clickGui:GetPropertyChangedSignal('Visible'):Connect(function()
						if slinky.threadFix and not pcall(setthreadidentity, 8) then
							pcall(setthreadidentity, 7)
						end
						waypointFolder.Parent = (not clickGui.Visible) and slinky.gui or nil
					end))
				end
				for _, v in list.active do
					local billboard
					local ok = pcall(function()
						local split = v:split('/')
						local tagSize = getfontsize(removeTags(split[2]), 14 * scale.value, fontOption.value, Vector2.new(100000, 100000))
						billboard = Instance.new('BillboardGui')
						billboard.Size = UDim2.fromOffset(tagSize.X + 12, tagSize.Y + 7)
						billboard.Adornee = workspace.Terrain
						billboard.StudsOffsetWorldSpace = Vector3.new(unpack(split[1]:split(',')))
						billboard.AlwaysOnTop = true
						local tag = Instance.new('TextLabel')
						local stroke = loaderStyle.box(tag, UDim.new(0, 6))
						stroke.Enabled = background.value < 1
						tag.Visible = true
						tag.RichText = true
						tag.TextSize = 14 * scale.value
						tag.BackgroundTransparency = background.value
						tag.Size = billboard.Size
						tag.Text = split[2]
						loaderStyle.text(tag, 'Medium')
						tag.TextColor3 = Color3.fromHSV(color.hue, color.sat, color.value)
						tag.Parent = billboard
						billboard.Parent = waypointFolder
					end)
					if not ok and billboard then
						pcall(function() billboard:Destroy() end)
					end
				end
			else
				waypointFolder:ClearAllChildren()
				waypointFolder.Parent = slinky.gui
			end
		end,
		about = 'Shows named markers at spots in the world you save.\nAdd points by position or where you stand, and style their labels.'
	})
	fontOption = waypoints:font('Font', {
		exclude = 'Arial',
		changed = function()
			if waypoints.enabled then
				waypoints:flip()
				waypoints:flip()
			end
		end,
	})
	list = waypoints:list('Points', {
		placeholder = 'x, y, z/name',
		changed = function()
			if waypoints.enabled then
				waypoints:flip()
				waypoints:flip()
			end
		end
	})
	waypoints:button('Add current position', {
		clicked = function()
			if entitylib.isAlive then
				local pos = entitylib.character.RootPart.Position // 1
				list:change(pos.X..','..pos.Y..','..pos.Z..'/Waypoint '..(#list.items + 1))
			end
		end
	})
	color = waypoints:color('Color', {
		hue = 0,
		sat = 0,
		value = 230 / 255,
		changed = function(hue, sat, val)
			for _, v in waypointFolder:GetChildren() do
				v.TextLabel.TextColor3 = Color3.fromHSV(hue, sat, val)
			end
		end
	})
	scale = waypoints:slider('Scale', {
		changed = function()
			if waypoints.enabled then
				waypoints:flip()
				waypoints:flip()
			end
		end,
		default = 1,
		min = 0.1,
		max = 1.5,
		decimal = 10
	})
	background = waypoints:slider('Transparency', {
		changed = function()
			if waypoints.enabled then
				waypoints:flip()
				waypoints:flip()
			end
		end,
		default = 0.3,
		min = 0,
		max = 1,
		decimal = 10
	})
	
end)
	
--[[ AnimationPlayer
Plays an animation of your choosing. Enter an animation id, then set its speed and priority. ]]
run(function()
	local animationPlayer
	local idBox
	local priority
	local speed
	local anim, animobject
	
	local function playAnimation(char)
		local animcheck = anim
		if animcheck then
			anim = nil
			animcheck:Stop()
		end
	
		local suc, res = pcall(function()
			anim = char.Humanoid.Animator:LoadAnimation(animobject)
		end)
	
		if suc then
			local currentanim = anim
			anim.Priority = Enum.AnimationPriority[priority.value]
			anim:Play()
			anim:AdjustSpeed(speed.value)
			animationPlayer:clean(anim.Stopped:Connect(function()
				if currentanim == anim then
					anim:Play()
				end
			end))
		else
			notif('AnimationPlayer', 'failed to load anim : '..(res or 'invalid animation id'), 5, 'warning')
		end
	end
	
	animationPlayer = utility:module('AnimationPlayer', {
		toggled = function(on)
			if on then
				animobject = Instance.new('Animation')
				local suc, id = pcall(function()
					return string.match(game:GetObjects('rbxassetid://'..idBox.value)[1].AnimationId, '%?id=(%d+)')
				end)
				animobject.AnimationId = 'rbxassetid://'..(suc and id or idBox.value)
	
				if entitylib.isAlive then
					playAnimation(entitylib.character)
				end
				animationPlayer:clean(entitylib.Events.LocalAdded:Connect(playAnimation))
				animationPlayer:clean(animobject)
			else
				if anim then
					anim:Stop()
				end
			end
		end,
		about = 'Plays an animation of your choosing.\nEnter an animation id, then set its speed and priority.'
	})
	idBox = animationPlayer:textbox('Animation', {
		placeholder = 'anim (num only)',
		changed = function(enter)
			if enter and animationPlayer.enabled then
				animationPlayer:flip()
				animationPlayer:flip()
			end
		end
	})
	local prio = {'Action4'}
	for _, v in Enum.AnimationPriority:GetEnumItems() do
		if v.Name ~= 'Action4' then
			table.insert(prio, v.Name)
		end
	end
	priority = animationPlayer:dropdown('Priority', {
		choices = prio,
		changed = function(val)
			if anim then
				anim.Priority = Enum.AnimationPriority[val]
			end
		end
	})
	speed = animationPlayer:slider('Speed', {
		changed = function(val)
			if anim then
				anim:AdjustSpeed(val)
			end
		end,
		min = 0.1,
		max = 2,
		decimal = 10
	})
end)
	
--[[ AntiRagdoll
Stops you from getting knocked into a ragdoll. ]]
run(function()
	local antiRagdoll
	
	antiRagdoll = utility:module('AntiRagdoll', {
		toggled = function(on)
			if entitylib.isAlive then
				entitylib.character.Humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, not on)
			end
	
			if on then
				antiRagdoll:clean(entitylib.Events.LocalAdded:Connect(function(char)
					char.Humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
				end))
			end
		end,
		about = 'Stops you from getting knocked into a ragdoll.'
	})
end)
	
--[[ AutoRejoin
Automatically joins a new server when you get kicked. Choose whether it prefers full or empty
servers. ]]
run(function()
	local autoRejoin
	local sort
	
	autoRejoin = utility:module('AutoRejoin', {
		toggled = function(on)
			if on then
				local check
				autoRejoin:clean(guiService.ErrorMessageChanged:Connect(function(str)
					if (not check or guiService:GetErrorCode() ~= Enum.ConnectionError.DisconnectLuaKick) and guiService:GetErrorCode() ~= Enum.ConnectionError.DisconnectConnectionLost and not str:lower():find('ban') then
						check = true
						serverHop(nil, sort.value)
					end
				end))
			end
		end,
		about = 'Automatically joins a new server when you get kicked.\nChoose whether it prefers full or empty servers.'
	})
	sort = autoRejoin:dropdown('Sort', {
		choices = {'Descending', 'Ascending'},
		about = 'Descending - Prefers full servers\nAscending - Prefers empty servers'
	})
end)

--[[ PromptChanger
Lets you use proximity prompts from the set range, with the hold time cut to a percent of normal:
Signal fires the prompt itself after the shortened hold, Property lowers HoldDuration while the
prompt is shown. Everything is put back when turned off. Range writes run at the raised identity.
Every instance added to the workspace passes through updatePrompt, so anything that is not a prompt
is turned away before the raise, which costs a closure and two protected calls; a full sweep raises
the identity once, with each prompt still failing on its own. ]]
run(function()
	local promptChanger
	local mode
	local modifier
	local range
	local originalRanges = {}
	local modified = {}
	local thread

	local function setPromptRange(prompt)
		if originalRanges[prompt] == nil then
			originalRanges[prompt] = prompt.MaxActivationDistance
		end
		prompt.MaxActivationDistance = range.value
	end

	local function updatePrompt(prompt)
		if not prompt or not prompt:IsA('ProximityPrompt') then return end
		callWithThreadFix(function()
			setPromptRange(prompt)
		end)
	end

	local function updateAllPrompts()
		callWithThreadFix(function()
			for _, prompt in workspace:GetDescendants() do
				if prompt:IsA('ProximityPrompt') then
					pcall(setPromptRange, prompt)
				end
			end
		end)
	end

	local function applyHoldDuration(prompt)
		if not prompt or not prompt:IsA('ProximityPrompt') then return end
		if modified[prompt] == nil then
			modified[prompt] = prompt.HoldDuration
		end
		prompt.HoldDuration = modified[prompt] * (modifier.value / 100)
	end

	local function restorePrompts()
		if thread then
			task.cancel(thread)
			thread = nil
		end

		for prompt, distance in originalRanges do
			callWithThreadFix(function()
				if prompt.Parent then
					prompt.MaxActivationDistance = distance
				end
			end)
		end
		table.clear(originalRanges)

		for prompt, duration in modified do
			callWithThreadFix(function()
				if prompt.Parent then
					prompt.HoldDuration = duration
				end
			end)
		end
		table.clear(modified)
	end

	promptChanger = utility:module('PromptChanger', {
		toggled = function(on)
			if on then
				updateAllPrompts()
				promptChanger:clean(proxService.PromptShown:Connect(function(prompt)
					updatePrompt(prompt)
					if mode.value == 'Property' then
						applyHoldDuration(prompt)
					end
				end))
				promptChanger:clean(workspace.DescendantAdded:Connect(function(instance)
					updatePrompt(instance)
				end))

				if mode.value == 'Signal' then
					promptChanger:clean(proxService.PromptButtonHoldBegan:Connect(function(prompt, plr)
						if plr == lplr then
							thread = task.delay(prompt.HoldDuration * (modifier.value / 100), function()
								fireproximityprompt(prompt)
								thread = nil
							end)
						end
					end))
					promptChanger:clean(proxService.PromptButtonHoldEnded:Connect(function(prompt, plr)
						if plr == lplr and thread then
							task.cancel(thread)
							thread = nil
						end
					end))
				else
					promptChanger:clean(proxService.PromptHidden:Connect(function(prompt)
						if modified[prompt] then
							prompt.HoldDuration = modified[prompt]
							modified[prompt] = nil
						end
					end))
				end
			else
				restorePrompts()
			end
		end,
		about = 'Lets you use interact prompts from further away and faster.\nSet the reach, and the hold time as a percent of normal.'
	})
	mode = promptChanger:dropdown('Mode', {
		choices = {'Signal', 'Property'},
		about = 'Signal - Fires the prompt after the adjusted delay\nProperty - Sets the HoldDuration property',
		changed = function()
			if promptChanger.enabled then
				promptChanger:flip()
				promptChanger:flip()
			end
		end
	})
	range = promptChanger:slider('Range', {
		min = 1,
		max = 100,
		default = 32,
		suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end,
		changed = function()
			if promptChanger.enabled then
				for prompt in originalRanges do
					updatePrompt(prompt)
				end
			end
		end
	})
	modifier = promptChanger:slider('Modifier', {
		min = 0,
		max = 100,
		default = 50,
		suffix = '%',
		changed = function(val)
			for prompt, duration in modified do
				prompt.HoldDuration = duration * (val / 100)
			end
		end
	})
end)
	
--[[ Blink
Holds your movement back from the server, or everything with Type All, through the
PhysicsSenderMaxBandwidthBps and DataSenderRate flags, then lets it through at once; Auto send opens
them for a moment at the set interval. The normal values come back on teleport and when turned off.
Needs setfflag, so it is hidden where the executor has none. ]]
run(function()
	local blink
	local typeDropdown
	local autoSend
	local autoSendLength
	local oldphys, oldsend
	local generation = 0

	if not exec.FFlag then
		exec.hide('Blink', 'needs setfflag')
		return
	end

	blink = utility:module('Blink', {
		info = function()
			return typeDropdown and (typeDropdown.value == 'All' and 'All' or 'Movement') or nil
		end,
		toggled = function(on)
			generation += 1
			if on then
				local teleported
				blink:clean(lplr.OnTeleport:Connect(function()
					setfflag('PhysicsSenderMaxBandwidthBps', '38760')
					setfflag('DataSenderRate', '60')
					teleported = true
				end))

				local gen = generation
				repeat
					local physicsrate, senderrate = '0', typeDropdown.value == 'All' and '-1' or '60'
					if autoSend.enabled and tick() % (autoSendLength.value + 0.1) > autoSendLength.value then
						physicsrate, senderrate = '38760', '60'
					end
	
					if physicsrate ~= oldphys or senderrate ~= oldsend then
						setfflag('PhysicsSenderMaxBandwidthBps', physicsrate)
						setfflag('DataSenderRate', senderrate)
						oldphys, oldsend = physicsrate, senderrate
					end
	
					task.wait(0.03)
				until not blink.enabled or teleported or generation ~= gen
			else
				if setfflag then
					setfflag('PhysicsSenderMaxBandwidthBps', '38760')
					setfflag('DataSenderRate', '60')
				end
				oldphys, oldsend = nil, nil
			end
		end,
		about = 'Freezes you in place for others, then jumps you ahead.\nCan hold back your actions too, and catch up at set intervals.'
	})
	blink:divider('Extras')
	typeDropdown = blink:dropdown('Type', {
		choices = {'Movement Only', 'All'},
		about = 'Movement Only - Only chokes movement packets\nAll - Chokes remotes & movement'
	})
	autoSend = blink:toggle('Auto send', {
		changed = function(callback)
			autoSendLength.row.Visible = callback
		end,
		about = 'Automatically send packets in intervals'
	})
	autoSendLength = blink:slider('Send threshold', {
		min = 0,
		max = 1,
		decimal = 100,
		sub = true,
		visible = false,
		suffix = function(val)
			return val == 1 and 'second' or 'seconds'
		end
	})
end)
	
local chatSpammer
local lines
local mode
local delaySlider
local hide
local randomList = {}
local oldchat
-- Bumped on every switch, so the sender left over from a Hide restart or a quick off and on stops
-- at its next check instead of sending beside the new one.
local spamGeneration = 0

--[[ ChatSpammer
Sends the lines from the list in order, or at random without a repeat until every line has gone, at
the set delay; nothing is sent while the list is empty. Hide removes the chat's wait warning. In
TextChatService chat that means hiding the warning in CoreGui's chat window, which can be missing or
refuse the read at a low identity (Solara, Xeno), and then the warning stays. Legacy chat's Hide
hooks the game's own OnNewSystemMessage handler and needs getconnections and hookfunction. ]]
chatSpammer = utility:module('ChatSpammer', {
	toggled = function(on)
		spamGeneration += 1
		if on then
			if #lines.active == 0 then
				notif('ChatSpammer', 'Add a line to send first.', 5, 'warning')
				chatSpammer:flip(nil, true)
				return
			end

			if textChatService.ChatVersion == Enum.ChatVersion.TextChatService then
				local function hideWaitNotices()
					chatSpammer:clean(coreGui.ExperienceChat.appLayout.chatWindow.contentFrame.scrollingView.bottomLockedScrollView.scrollView.ChildAdded:Connect(function(msg)
						if msg.Name:sub(1, 2) == '0-' and msg.TextMessage.BodyText.Text == '<font color="#d4d4d4">You must wait before sending another message.</font>' then
							msg.Visible = false
						end
					end))
				end
				if hookExecutor then
					if hide.enabled and coreGui:FindFirstChild('ExperienceChat') then
						hideWaitNotices()
					end
				elseif hide.enabled and coreGui then
					pcall(function()
						if coreGui:FindFirstChild('ExperienceChat') then
							hideWaitNotices()
						end
					end)
				end
			elseif replicatedStorage:FindFirstChild('DefaultChatSystemChatEvents') then
				if hide.enabled and exec.Connections and exec.HookFunction then
					oldchat = hookfunction(getconnections(replicatedStorage.DefaultChatSystemChatEvents.OnNewSystemMessage.OnClientEvent)[1].Function, function(data, ...)
						if data.Message:find('ChatFloodDetector') then return end
						return oldchat(data, ...)
					end)
				end
			else
				notif('ChatSpammer', 'unsupported chat', 5, 'warning')
				chatSpammer:flip()
				return
			end

			local index = 1
			local gen = spamGeneration
			repeat
				local message
				if #lines.active > 0 then
					if mode.value == 'Order' then
						message = lines.active[index] or lines.active[1]
						index = (index % #lines.active) + 1
					else
						if #randomList <= 0 then
							randomList = table.clone(lines.active)
						end

						local entry = Random.new():NextInteger(1, #randomList)
						message = randomList[entry]
						table.remove(randomList, entry)
					end
				end

				if message then
					if textChatService.ChatVersion == Enum.ChatVersion.TextChatService then
						textChatService.ChatInputBarConfiguration.TargetTextChannel:SendAsync(message)
					else
						replicatedStorage.DefaultChatSystemChatEvents.SayMessageRequest:FireServer(message, 'All')
					end
				end

				task.wait(delaySlider.value)
			until not chatSpammer.enabled or spamGeneration ~= gen
		else
			if oldchat then
				hookfunction(getconnections(replicatedStorage.DefaultChatSystemChatEvents.OnNewSystemMessage.OnClientEvent)[1].Function, oldchat)
			end
		end
	end,
	about = 'Sends your chosen messages in chat over and over.\nSet the lines, random or in order, the delay, and hide the wait warning.'
})
lines = chatSpammer:list('Lines', {
	changed = function()
		table.clear(randomList)
	end
})
mode = chatSpammer:dropdown('Mode', {
	choices = {'Random', 'Order'}
})
delaySlider = chatSpammer:slider('Delay', {
	min = 0.1,
	max = 10,
	default = 1,
	decimal = 10,
	suffix = function(val)
		return val == 1 and 'second' or 'seconds'
	end
})
hide = chatSpammer:toggle('Hide Flood Message', {
	default = true,
	changed = function()
		if chatSpammer.enabled then
			chatSpammer:flip()
			chatSpammer:flip()
		end
	end
})
	
run(function()
	local disabler

	--[[ Disabler silences the game's own handlers on your root's CFrame and Velocity changes. Other
	scripts' connections can only be listed and replaced with getconnections and hookfunction, so
	without both the module is left out of the list. ]]
	if not (exec.Connections and exec.HookFunction) then
		exec.hide('Disabler', 'needs getconnections and hookfunction')
		return
	end

	local function characterAdded(char)
		for _, v in getconnections(char.RootPart:GetPropertyChangedSignal('CFrame')) do
			hookfunction(v.Function, function() end)
		end
	
		for _, v in getconnections(char.RootPart:GetPropertyChangedSignal('Velocity')) do
			hookfunction(v.Function, function() end)
		end
	end
	
	disabler = utility:module('Disabler', {
		toggled = function(on)
			if on then
				disabler:clean(entitylib.Events.LocalAdded:Connect(characterAdded))
				if entitylib.isAlive then
					characterAdded(entitylib.character)
				end
			end
		end,
		about = 'Makes movement modules work more reliably.'
	})
end)
	
--[[ Panic
Turns off every module that is on. Each one is switched off quiet and batched, so the overlay
rebuilds once and no toast shows per module. ]]
run(function()
	utility:module('Panic', {
		toggled = function(on)
			if on then
				for _, v in (slinky.eachModule and slinky:eachModule() or slinky.modules) do
					if v.enabled then
						v:flip(true, true)
					end
				end
			end
		end,
		about = 'Turns off every module that is currently on.'
	})
end)
	
--[[ Rejoin
Rejoins the server you are in. ]]
run(function()
	local rejoin
	
	rejoin = utility:module('Rejoin', {
		toggled = function(on)
			if on then
				notif('Rejoin', 'Rejoining...', 5)
				rejoin:flip()
	
				if playersService.NumPlayers > 1 then
					teleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId)
				else
					teleportService:Teleport(game.PlaceId)
				end
			end
		end,
		about = 'Rejoins the server you are in.'
	})
end)
	
--[[ ServerHop
Moves you to a different server of this game. Prefer full or empty servers, or go back to the
previous one. ]]
run(function()
	local serverHopModule
	local sort
	
	serverHopModule = utility:module('ServerHop', {
		toggled = function(on)
			if on then
				serverHopModule:flip()
				serverHop(nil, sort.value)
			end
		end,
		about = 'Moves you to a different server of this game.\nPrefer full or empty servers, or go back to the previous one.'
	})
	sort = serverHopModule:dropdown('Sort', {
		choices = {'Descending', 'Ascending'},
		about = 'Descending - Prefers full servers\nAscending - Prefers empty servers'
	})
	serverHopModule:button('Rejoin Previous Server', {
		clicked = function()
			notif('ServerHop', shared.slinkyserverhopprevious and 'Rejoining previous server...' or 'Cannot find previous server', 5)
			if shared.slinkyserverhopprevious then
				teleportService:TeleportToPlaceInstance(game.PlaceId, shared.slinkyserverhopprevious)
			end
		end
	})
end)
	
run(function()
	local staffDetector
	local mode
	local profile
	local users
	local group
	local role
	
	local function getRole(plr, id)
		local suc, res
		for _ = 1, 3 do
			suc, res = pcall(function()
				return plr:GetRankInGroup(id)
			end)
			if suc then break end
		end
		return suc and res or 0
	end
	
	local function getLowestStaffRole(roles)
		local highest = math.huge
		for _, v in roles do
			local low = v.Name:lower()
			if (low:find('admin') or low:find('mod') or low:find('dev')) and v.Rank < highest then
				highest = v.Rank
			end
		end
		return highest
	end
	
	local function playerAdded(plr)
		if not slinky.loaded then
			-- Loaded goes nil on uninject; without that check this waited for a load that never came.
			repeat task.wait() until slinky.loaded or slinky.loaded == nil
			if not slinky.loaded then return end
		end

		local user = table.find(users.active, tostring(plr.UserId))
		if user or getRole(plr, tonumber(group.value) or 0) >= (tonumber(role.value) or 1) then
			notif('StaffDetector', 'Staff Detected ('..(user and 'blacklisted_user' or 'staff_role')..'): '..plr.Name, 60, 'alert')
			tags.customtags[plr.Name] = {{text = 'GAME STAFF', color = Color3.new(1, 0, 0)}}
	
			if mode.value == 'Uninject' then
				task.spawn(function()
					slinky:unload()
				end)
				game:GetService('StarterGui'):SetCore('SendNotification', {
					Title = 'StaffDetector',
					Text = 'Staff Detected\n'..plr.Name,
					Duration = 60,
				})
			elseif mode.value == 'ServerHop' then
				serverHop()
			elseif mode.value == 'Profile' then
				slinky.save = function() end
				if slinky.profile ~= profile.value then
					slinky.profile = profile.value
					slinky:load(true, profile.value)
				end
			elseif mode.value == 'AutoConfig' then
				slinky.save = function() end
				for _, v in (slinky.eachModule and slinky:eachModule() or slinky.modules) do
					if v.enabled then
						v:flip()
					end
				end
			end
		end
	end
	
	staffDetector = utility:module('StaffDetector', {
		toggled = function(on)
			if on then
				if group.value == '' or role.value == '' then
					local placeinfo = {Creator = {CreatorTargetId = tonumber(group.value)}}
					if group.value == '' then
						placeinfo = marketplaceService:GetProductInfo(game.PlaceId)
						if placeinfo.Creator.CreatorType ~= 'Group' then
							local desc = placeinfo.Description:split('\n')
							for _, str in desc do
								local _, begin = str:find('roblox.com/groups/')
								if begin then
									local endof = str:find('/', begin + 1)
									placeinfo = {Creator = {
										CreatorType = 'Group',
										CreatorTargetId = str:sub(begin + 1, endof - 1)
									}}
								end
							end
						end
	
						if placeinfo.Creator.CreatorType ~= 'Group' then
							notif('StaffDetector', 'Automatic Setup Failed (no group detected)', 60, 'warning')
							return
						end
					end
	
					local groupinfo = groupService:GetGroupInfoAsync(placeinfo.Creator.CreatorTargetId)
					group:set(placeinfo.Creator.CreatorTargetId)
					role:set(getLowestStaffRole(groupinfo.Roles))
				end
	
				if group.value == '' or role.value == '' then
					return
				end
	
				staffDetector:clean(playersService.PlayerAdded:Connect(playerAdded))
				for _, v in playersService:GetPlayers() do
					task.spawn(playerAdded, v)
				end
			end
		end,
		about = 'Warns you when staff are in your server.\nCan also unload, switch server, swap profile or turn modules off.'
	})
	mode = staffDetector:dropdown('Mode', {
		choices = {'Uninject', 'ServerHop', 'Profile', 'AutoConfig', 'Notify'},
		changed = function(val)
			if profile.row then
				profile.row.Visible = val == 'Profile'
			end
		end
	})
	profile = staffDetector:textbox('Profile', {
		default = 'default',
		sub = true,
		visible = false
	})
	users = staffDetector:list('Users', {
		placeholder = 'player (userid)'
	})
	group = staffDetector:textbox('Group', {
		placeholder = 'Group Id'
	})
	role = staffDetector:textbox('Role', {
		placeholder = 'Role Rank'
	})
end)
	
--[[ Anti-AFK
Keeps Roblox from kicking you for being idle. With getconnections the idle kick's own Idled
connections are disabled, and enabled again on off.

Without getconnections (Solara, Xeno) the idle timer is reset instead each time Roblox reports you
idle: VirtualUser clicks at identity 8, or where that is refused the mouse moves a pixel and back.
The reset is spawned so the identity change stays out of the signal's own thread. ]]
run(function()
	local connections = {}
	local idled

	local function resetIdle()
		task.spawn(function()
			if exec.Identity then
				pcall(setthreadidentity, 8)
			end
			local clicked = pcall(function()
				local user = cloneref(game:GetService('VirtualUser'))
				user:CaptureController()
				user:ClickButton2(Vector2.zero)
			end)
			if not clicked and exec.MouseMove then
				pcall(mousemoverel, 1, 0)
				task.wait()
				pcall(mousemoverel, -1, 0)
			end
		end)
	end

	world:module('Anti-AFK', {
		tab = 'Utility',
		toggled = function(on)
			if on then
				if not exec.Connections then
					if not idled then
						idled = lplr.Idled:Connect(resetIdle)
					end
					return
				end
				for _, v in getconnections(lplr.Idled) do
					table.insert(connections, v)
					v:Disable()
				end
			else
				for _, v in connections do
					v:Enable()
				end
				table.clear(connections)
				if idled then
					idled:Disconnect()
					idled = nil
				end
			end
		end,
		about = 'Prevents you from getting kicked for being idle.'
	})
end)
	
--[[ Freecam
Lets the camera fly free with W, A, S, D, Q and E, Shift slowing it to a quarter. A touch-only
device gets a warning and the module turns off, since without a keyboard the camera would only be
pinned in place.

With getconnections and debug the camera module is the first upvalue of a CameraType changed
handler. Without them, and only where require hands back the game's own modules (exec.Live),
PlayerModule:GetCameras gives the same module; a fresh copy of PlayerModule would build a second
camera and control stack. The active controller's GetSubjectPosition is then replaced to return the
free position. With no camera module in reach the camera is placed right after the camera module's
render step each frame, looking where that module looks, so mouse look keeps working. The movement
keys are sunk at high priority while it is on. ]]
run(function()
	local freecam
	local amount
	local randomkey, module, old = httpService:GenerateGUID(false)
	
	freecam = world:module('Freecam', {
		tab = 'Visual',
		toggled = function(on)
			if on then
				if inputService.TouchEnabled and not inputService.KeyboardEnabled then
					notif('Freecam', 'Freecam moves with W, A, S, D, Q and E, so it needs a keyboard.', 5, 'warning')
					freecam:flip(nil, true)
					return
				end

				local hooked = exec.Connections and exec.Debug
				if hooked then
					repeat
						task.wait(0.1)
						for _, v in getconnections(gameCamera:GetPropertyChangedSignal('CameraType')) do
							if v.Function then
								module = debug.getupvalue(v.Function, 1)
							end
						end
					until module or not freecam.enabled
				elseif exec.Live then
					local ok, cameras = pcall(function()
						return require(lplr.PlayerScripts.PlayerModule):GetCameras()
					end)
					module = ok and type(cameras) == 'table' and cameras or nil
				end

				local camPos
				if module and module.activeCameraController and freecam.enabled then
					old = module.activeCameraController.GetSubjectPosition
					camPos = old(module.activeCameraController) or Vector3.zero
					module.activeCameraController.GetSubjectPosition = function()
						return camPos
					end
				elseif not hooked and freecam.enabled then
					module = nil
					camPos = gameCamera.CFrame.Position
					local bindKey = 'Freecam'..randomkey
					runService:BindToRenderStep(bindKey, Enum.RenderPriority.Camera.Value + 1, function()
						local placed = CFrame.lookAlong(camPos, gameCamera.CFrame.LookVector)
						gameCamera.CFrame = placed
						gameCamera.Focus = placed
					end)
					freecam:clean(function()
						pcall(function()
							runService:UnbindFromRenderStep(bindKey)
						end)
					end)
				end

				if camPos then
					freecam:clean(runService.PreSimulation:Connect(function(dt)
						if not inputService:GetFocusedTextBox() then
							local forward = (inputService:IsKeyDown(Enum.KeyCode.W) and -1 or 0) + (inputService:IsKeyDown(Enum.KeyCode.S) and 1 or 0)
							local side = (inputService:IsKeyDown(Enum.KeyCode.A) and -1 or 0) + (inputService:IsKeyDown(Enum.KeyCode.D) and 1 or 0)
							local up = (inputService:IsKeyDown(Enum.KeyCode.Q) and -1 or 0) + (inputService:IsKeyDown(Enum.KeyCode.E) and 1 or 0)
							dt = dt * (inputService:IsKeyDown(Enum.KeyCode.LeftShift) and 0.25 or 1)
							camPos = (CFrame.lookAlong(camPos, gameCamera.CFrame.LookVector) * CFrame.new(Vector3.new(side, up, forward) * (amount.value * dt))).Position
						end
					end))
	
					contextService:BindActionAtPriority('FreecamKeyboard'..randomkey, function()
						return Enum.ContextActionResult.Sink
					end, false, Enum.ContextActionPriority.High.Value,
						Enum.KeyCode.W,
						Enum.KeyCode.A,
						Enum.KeyCode.S,
						Enum.KeyCode.D,
						Enum.KeyCode.E,
						Enum.KeyCode.Q,
						Enum.KeyCode.Up,
						Enum.KeyCode.Down
					)
				end
			else
				pcall(function()
					contextService:UnbindAction('FreecamKeyboard'..randomkey)
				end)
				if module and old then
					module.activeCameraController.GetSubjectPosition = old
					module = nil
					old = nil
				end
			end
		end,
		about = 'Lets you fly your camera around freely.\nMove with WASD, E and Q, and hold Shift to slow down.'
	})
	amount = freecam:slider('Speed', {
		min = 1,
		max = 150,
		default = 50,
		suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
end)
	
--[[ Gravity
Lowers gravity so you fall more slowly. Apply it to the whole game or just to your own character. ]]
run(function()
	local gravity
	local mode
	local amount
	local changed, old = false
	
	gravity = world:module('Gravity', {
		tab = 'Move',
		info = function()
			return amount and tostring(amount.value) or nil
		end,
		toggled = function(on)
			if on then
				if mode.value == 'Workspace' then
					old = workspace.Gravity
					workspace.Gravity = amount.value
					gravity:clean(workspace:GetPropertyChangedSignal('Gravity'):Connect(function()
						if changed then return end
						changed = true
						old = workspace.Gravity
						workspace.Gravity = amount.value
						changed = false
					end))
				else
					gravity:clean(runService.PreSimulation:Connect(function(dt)
						if entitylib.isAlive and entitylib.character.Humanoid.FloorMaterial == Enum.Material.Air then
							local root = entitylib.character.RootPart
							if mode.value == 'Impulse' then
								root:ApplyImpulse(Vector3.new(0, dt * (workspace.Gravity - amount.value), 0) * root.AssemblyMass)
							else
								root.AssemblyLinearVelocity += Vector3.new(0, dt * (workspace.Gravity - amount.value), 0)
							end
						end
					end))
				end
			else
				if old then
					workspace.Gravity = old
					old = nil
				end
			end
		end,
		about = 'Lowers gravity so you fall more slowly.\nApply it to the whole game or just to your own character.'
	})
	mode = gravity:dropdown('Mode', {
		choices = {'Workspace', 'Velocity', 'Impulse'},
		about = 'Workspace - Adjusts the gravity for the entire game\nVelocity - Adjusts the local players gravity\nImpulse - Same as velocity while using forces instead'
	})
	amount = gravity:slider('Gravity', {
		min = 0,
		max = 192,
		changed = function(val)
			if gravity.enabled and mode.value == 'Workspace' then
				changed = true
				workspace.Gravity = val
				changed = false
			end
		end,
		default = 192
	})
end)
	
--[[ Parkour
Jumps for you automatically as you run off an edge. ]]
run(function()
	local parkour
	
	parkour = world:module('Parkour', {
		tab = 'Move',
		toggled = function(on)
			if on then 
				local oldfloor
				parkour:clean(runService.RenderStepped:Connect(function()
					if entitylib.isAlive then 
						local material = entitylib.character.Humanoid.FloorMaterial
						if material == Enum.Material.Air and oldfloor ~= Enum.Material.Air then 
							entitylib.character.Humanoid.Jump = true
						end
						oldfloor = material
					end
				end))
			end
		end,
		about = 'Jumps for you automatically as you run off an edge.'
	})
end)
	
--[[ SafeWalk
Keeps you from walking off ledges. It wraps the PlayerModule controls' moveFunction and, when
nothing is under the next step, pulls the move toward the closest point of the block you stand on.
On off the hook is put back only while it is still the top one, as in TargetStrafe, so a hook
installed after it stays. ]]
run(function()
	local rayCheck = RaycastParams.new()
	rayCheck.RespectCanCollide = true
	local module, current

	world:module('SafeWalk', {
		tab = 'Move',
		toggled = function(on)
			if on then
				if not module then
					local suc = pcall(function()
						module = require(lplr.PlayerScripts.PlayerModule).controls
					end)
					if not suc then module = nil end
				end

				local old = module and module.moveFunction
				if type(old) ~= 'function' then
					module = nil
					return
				end
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
		about = 'Prevents you from walking off ledges.'
	})
end)
	
--[[ Xray
Makes the world see-through so you can look past walls. Parts named in the list stay solid. ]]
run(function()
	local xray
	local list
	local modified = {}

	local function modifyPart(v)
		if v:IsA('BasePart') and not table.find(list.active, v.Name) then
			if modified[v] == nil then
				modified[v] = v.LocalTransparencyModifier
			end
			v.LocalTransparencyModifier = 0.5
		end
	end

	xray = world:module('Xray', {
		tab = 'Visual',
		toggled = function(on)
			if on then
				xray:clean(workspace.DescendantAdded:Connect(modifyPart))
				xray:clean(workspace.DescendantRemoving:Connect(function(v)
					if modified[v] ~= nil then
						v.LocalTransparencyModifier = modified[v]
					end
					modified[v] = nil
				end))
				for _, v in workspace:GetDescendants() do
					modifyPart(v)
				end
			else
				for i, original in modified do
					if i.Parent then
						i.LocalTransparencyModifier = original
					end
				end
				table.clear(modified)
			end
		end,
		about = 'Makes the world see-through so you can look past walls.\nParts named in the list stay solid.'
	})
	list = xray:list('Part', {
		changed = function()
			if xray.enabled then
				xray:flip()
				xray:flip()
			end
		end
	})
end)
	
--[[ MurderMystery
Finds the murderer and sheriff from their weapons. Colors them and makes them your targets, or
everyone if you are the murderer. ]]
run(function()
	local murderMystery
	local murderer, sheriff, oldtargetable, oldgetcolor
	
	local function itemAdded(v, plr)
		if v:IsA('Tool') then
			local check = v:FindFirstChild('IsGun') and 'sheriff' or v:FindFirstChild('KnifeServer') and 'murderer' or nil
			check = check or v.Name:lower():find('knife') and 'murderer' or v.Name:lower():find('gun') and 'sheriff' or nil
	
			if check == 'murderer' and plr ~= murderer then
				murderer = plr
				if plr.Character then
					entitylib.refresh()
				end
			elseif check == 'sheriff' and plr ~= sheriff then
				sheriff = plr
				if plr.Character then
					entitylib.refresh()
				end
			end
		end
	end
	
	local function playerAdded(plr)
		murderMystery:clean(plr.DescendantAdded:Connect(function(v)
			itemAdded(v, plr)
		end))
	
		local pack = plr:FindFirstChildWhichIsA('Backpack')
		if pack then
			for _, v in pack:GetChildren() do
				itemAdded(v, plr)
			end
		end
	
		if plr.Character then
			for _, v in plr.Character:GetChildren() do
				itemAdded(v, plr)
			end
		end
	end
	
	murderMystery = minigames:module('MurderMystery', {
		tab = 'Utility',
		toggled = function(on)
			if on then
				oldtargetable, oldgetcolor = entitylib.targetCheck, entitylib.getEntityColor
	
				entitylib.getEntityColor = function(ent)
					ent = ent.Player
					if not (ent and slinky.categories.Main.options['Use team color'].enabled) then return end
					if isFriend(ent, true) then
						return Color3.fromHSV(slinky.categories.Friends.options['Friends color'].hue, slinky.categories.Friends.options['Friends color'].sat, slinky.categories.Friends.options['Friends color'].value)
					end
					return murderer == ent and Color3.new(1, 0.3, 0.3) or sheriff == ent and Color3.new(0, 0.5, 1) or nil
				end
	
				entitylib.targetCheck = function(ent)
					if ent.Player and isFriend(ent.Player) then return false end
					if murderer == lplr then return true end
					return murderer == ent.Player or sheriff == ent.Player
				end
	
				for _, v in playersService:GetPlayers() do
					playerAdded(v)
				end
	
				murderMystery:clean(playersService.PlayerAdded:Connect(playerAdded))
				entitylib.refresh()
			else
				entitylib.getEntityColor = oldgetcolor
				entitylib.targetCheck = oldtargetable
				entitylib.refresh()
			end
		end,
		about = 'Finds the murderer and sheriff from their weapons.\nColors them and makes them your targets, or everyone if you are the murderer.'
	})
end)
	
--[[ Atmosphere
Replaces the sky, atmosphere and post effects in Lighting with objects built from your settings. The
game's own objects of an enabled class are parked under game and put back on off; ones the game adds
later are moved out deferred. apidump lists each class's editable properties and their kind.

A colour change recolours the live object instead of restarting the module, since rainbow mode calls
it every frame. ]]
run(function()
	local atmosphere
	local toggles = {}
	local newobjects, oldobjects = {}, {}
	local apidump = {
		Sky = {
			SkyboxUp = 'Text',
			SkyboxDn = 'Text',
			SkyboxLf = 'Text',
			SkyboxRt = 'Text',
			SkyboxFt = 'Text',
			SkyboxBk = 'Text',
			SunTextureId = 'Text',
			SunAngularSize = 'Number',
			MoonTextureId = 'Text',
			MoonAngularSize = 'Number',
			StarCount = 'Number'
		},
		Atmosphere = {
			Color = 'Color',
			Decay = 'Color',
			Density = 'Number',
			Offset = 'Number',
			Glare = 'Number',
			Haze = 'Number'
		},
		BloomEffect = {
			Intensity = 'Number',
			Size = 'Number',
			Threshold = 'Number'
		},
		DepthOfFieldEffect = {
			FarIntensity = 'Number',
			FocusDistance = 'Number',
			InFocusRadius = 'Number',
			NearIntensity = 'Number'
		},
		SunRaysEffect = {
			Intensity = 'Number',
			Spread = 'Number'
		},
		ColorCorrectionEffect = {
			TintColor = 'Color',
			Saturation = 'Number',
			Contrast = 'Number',
			Brightness = 'Number'
		}
	}
	
	local function removeObject(v)
		if not table.find(newobjects, v) then
			local toggle = toggles[v.ClassName]
			if toggle and toggle.Toggle.enabled then
				if v.Parent then
					table.insert(oldobjects, v)
					v.Parent = game
				end
			end
		end
	end
	
	atmosphere = legit:module('Atmosphere', {
		toggled = function(on)
			if on then
				for _, v in lightingService:GetChildren() do
					removeObject(v)
				end
	
				atmosphere:clean(lightingService.ChildAdded:Connect(function(v)
					task.defer(removeObject, v)
				end))
	
				for i, v in toggles do
					if v.Toggle.enabled then
						local obj = Instance.new(i)
						for i2, v2 in v.Objects do
							if v2.kind == 'color' then
								obj[i2] = Color3.fromHSV(v2.hue, v2.sat, v2.value)
							else
								obj[i2] = apidump[i][i2] ~= 'Number' and v2.value or tonumber(v2.value) or 0
							end
						end
						obj.Parent = lightingService
						table.insert(newobjects, obj)
					end
				end
			else
				for _, v in newobjects do
					v:Destroy()
				end
	
				for _, v in oldobjects do
					v.Parent = lightingService
				end
	
				table.clear(newobjects)
				table.clear(oldobjects)
			end
		end,
		about = 'Replaces the sky and lighting with your own settings.\nCovers sky, atmosphere, bloom, depth of field, sun rays and color.'
	})
	for i, v in apidump do
		toggles[i] = {Objects = {}}
		toggles[i].Toggle = atmosphere:toggle(i, {
			changed = function(callback)
				if atmosphere.enabled then
					atmosphere:flip()
					atmosphere:flip()
				end
	
				for _, toggle in toggles[i].Objects do
					toggle.row.Visible = callback
				end
			end
		})
	
		for i2, v2 in v do
			if v2 == 'Text' or v2 == 'Number' then
				toggles[i].Objects[i2] = atmosphere:textbox(i2, {
					changed = function(enter)
						if atmosphere.enabled and enter then
							atmosphere:flip()
							atmosphere:flip()
						end
					end,
					sub = true,
					default = v2 == 'Number' and '0' or nil,
					visible = false
				})
			elseif v2 == 'Color' then
				toggles[i].Objects[i2] = atmosphere:color(i2, {
					changed = function(hue, sat, val)
						for _, obj in newobjects do
							if obj.ClassName == i then
								obj[i2] = Color3.fromHSV(hue, sat, val)
							end
						end
					end,
					sub = true,
					visible = false
				})
			end
		end
	end
end)
	
--[[ Breadcrumbs
Draws a trail behind your character between two attachments on the root part. The attachments are
destroyed with the character, so on respawn new ones are made when the old ones cannot be moved. ]]
run(function()
	local breadcrumbs
	local texture
	local lifetime
	local thickness
	local fadeIn
	local fadeOut
	local trail, point, point2
	
	breadcrumbs = legit:module('Breadcrumbs', {
		toggled = function(on)
			if on then
				point = Instance.new('Attachment')
				point.Position = Vector3.new(0, thickness.value - 2.7, 0)
				point2 = Instance.new('Attachment')
				point2.Position = Vector3.new(0, -thickness.value - 2.7, 0)
				trail = Instance.new('Trail')
				trail.Texture = texture.value == '' and 'http://www.roblox.com/asset/?id=14166981368' or texture.value
				trail.TextureMode = Enum.TextureMode.Static
				trail.Color = ColorSequence.new(Color3.fromHSV(fadeIn.hue, fadeIn.sat, fadeIn.value), Color3.fromHSV(fadeOut.hue, fadeOut.sat, fadeOut.value))
				trail.Lifetime = lifetime.value
				trail.Attachment0 = point
				trail.Attachment1 = point2
				trail.FaceCamera = true
	
				breadcrumbs:clean(trail)
				breadcrumbs:clean(point)
				breadcrumbs:clean(point2)
				breadcrumbs:clean(entitylib.Events.LocalAdded:Connect(function(ent)
					local moved = pcall(function()
						point.Parent = ent.HumanoidRootPart
						point2.Parent = ent.HumanoidRootPart
					end)
					if not moved then
						point = Instance.new('Attachment')
						point.Position = Vector3.new(0, thickness.value - 2.7, 0)
						point2 = Instance.new('Attachment')
						point2.Position = Vector3.new(0, -thickness.value - 2.7, 0)
						trail.Attachment0 = point
						trail.Attachment1 = point2
						breadcrumbs:clean(point)
						breadcrumbs:clean(point2)
						point.Parent = ent.HumanoidRootPart
						point2.Parent = ent.HumanoidRootPart
					end
					trail.Parent = gameCamera
				end))
	
				if entitylib.isAlive then
					point.Parent = entitylib.character.RootPart
					point2.Parent = entitylib.character.RootPart
					trail.Parent = gameCamera
				end
			else
				trail = nil
				point = nil
				point2 = nil
			end
		end,
		about = 'Leaves a trail behind your character as you move.\nSet its texture, colors, length and thickness.'
	})
	texture = breadcrumbs:textbox('Texture', {
		placeholder = 'Texture Id',
		changed = function(enter)
			if enter and trail then
				trail.Texture = texture.value == '' and 'http://www.roblox.com/asset/?id=14166981368' or texture.value
			end
		end
	})
	fadeIn = breadcrumbs:color('Fade In', {
		changed = function(hue, sat, val)
			if trail then
				trail.Color = ColorSequence.new(Color3.fromHSV(hue, sat, val), Color3.fromHSV(fadeOut.hue, fadeOut.sat, fadeOut.value))
			end
		end
	})
	fadeOut = breadcrumbs:color('Fade Out', {
		changed = function(hue, sat, val)
			if trail then
				trail.Color = ColorSequence.new(Color3.fromHSV(fadeIn.hue, fadeIn.sat, fadeIn.value), Color3.fromHSV(hue, sat, val))
			end
		end
	})
	lifetime = breadcrumbs:slider('Lifetime', {
		min = 1,
		max = 5,
		default = 3,
		decimal = 10,
		changed = function(val)
			if trail then
				trail.Lifetime = val
			end
		end,
		suffix = function(val)
			return val == 1 and 'second' or 'seconds'
		end
	})
	thickness = breadcrumbs:slider('Thickness', {
		min = 0,
		max = 2,
		default = 0.1,
		decimal = 100,
		changed = function(val)
			if point then
				point.Position = Vector3.new(0, val - 2.7, 0)
			end
			if point2 then
				point2.Position = Vector3.new(0, -val - 2.7, 0)
			end
		end,
		suffix = function(val)
			return val == 1 and 'stud' or 'studs'
		end
	})
end)

--[[ Cape
Hangs a cape on your back that swings with your speed, showing the Pistonware piston, your own image
or a .webm video. It is hidden in first person.

The cape hangs off the camera, not the character, so FpsBoostPlus' Clean Self check (a descendant of
lplr.Character) never covers it; the PistonwareSelf attribute opts it out of that and of No Decals,
and anything else the script parents into the world can set it the same way. generation stops a loop
left from a quick off and on. ]]
run(function()
	local cape
	local texture
	local outlineToggle
	local outlineColor
	local part, motor, outline
	local DEFAULT_CAPE = 'rbxassetid://73714636260061'
	local generation = 0

	local function paintOutline()
		if not outline then return end
		outline.Enabled = outlineToggle.enabled
		outline.OutlineColor = Color3.fromHSV(outlineColor.hue, outlineColor.sat, outlineColor.value)
		outline.OutlineTransparency = 1 - outlineColor.opacity
	end
	
	local function createMotor(char)
		if motor then 
			motor:Destroy() 
		end
		part.Parent = gameCamera
		motor = Instance.new('Motor6D')
		motor.MaxVelocity = 0.08
		motor.Part0 = part
		motor.Part1 = char.Character:FindFirstChild('UpperTorso') or char.RootPart
		motor.C0 = CFrame.new(0, 2, 0) * CFrame.Angles(0, math.rad(-90), 0)
		motor.C1 = CFrame.new(0, motor.Part1.Size.Y / 2, 0.45) * CFrame.Angles(0, math.rad(90), 0)
		motor.Parent = part
	end
	
	cape = legit:module('Cape', {
		toggled = function(on)
			generation += 1
			if on then
				part = Instance.new('Part')
				part.Size = Vector3.new(2, 4, 0.1)
				part.CanCollide = false
				part.CanQuery = false
				part.Massless = true
				part.Transparency = 0
				part.Material = Enum.Material.SmoothPlastic
				part.Color = Color3.new()
				part.CastShadow = false
				part:SetAttribute('PistonwareSelf', true)
				part.Parent = gameCamera
				local capesurface = Instance.new('SurfaceGui')
				capesurface.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
				capesurface.Adornee = part
				capesurface.Parent = part
	
				if texture.value:find('.webm') then
					local decal = Instance.new('VideoFrame')
					decal.Video = getcustomasset(texture.value)
					decal.Size = UDim2.fromScale(1, 1)
					decal.BackgroundTransparency = 1
					decal.Looped = true
					decal.Parent = capesurface
					decal:Play()
				else
					local decal = Instance.new('ImageLabel')
					decal.Image = texture.value ~= '' and (texture.value:find('rbxasset') and texture.value or assetfunction(texture.value)) or DEFAULT_CAPE
					decal.Size = UDim2.fromScale(1, 1)
					decal.BackgroundTransparency = 1
					decal.Parent = capesurface
				end
				outline = Instance.new('Highlight')
				outline.DepthMode = Enum.HighlightDepthMode.Occluded
				outline.FillTransparency = 1
				outline.Adornee = part
				outline.Parent = part
				paintOutline()
				cape:clean(part)
				cape:clean(entitylib.Events.LocalAdded:Connect(createMotor))
				if entitylib.isAlive then
					createMotor(entitylib.character)
				end

				local gen = generation
				repeat
					if motor and entitylib.isAlive then
						local velo = math.min(entitylib.character.RootPart.Velocity.Magnitude, 90)
						motor.DesiredAngle = math.rad(6) + math.rad(velo) + (velo > 1 and math.abs(math.cos(tick() * 5)) / 3 or 0)
					end
					capesurface.Enabled = (gameCamera.CFrame.Position - gameCamera.Focus.Position).Magnitude > 0.6
					part.Transparency = (gameCamera.CFrame.Position - gameCamera.Focus.Position).Magnitude > 0.6 and 0 or 1
					task.wait()
				until not cape.enabled or generation ~= gen
			else
				part = nil
				motor = nil
				outline = nil
			end
		end,
		about = 'Gives your character a cape that sways as you move.\nShows the Pistonware piston, or your own image or video.'
	})
	texture = cape:textbox('Texture')
	outlineToggle = cape:toggle('Outline', {
		changed = function(callback)
			if outlineColor then
				outlineColor.row.Visible = callback
			end
			paintOutline()
		end,
		about = 'Draws an outline round the cape.'
	})
	outlineColor = cape:color('Outline Color', {
		changed = function()
			paintOutline()
		end,
		sub = true,
		visible = false
	})
end)
	
--[[ China Hat
Puts a cone hat on your head, welded to it and welded again on each respawn. It is hidden in first
person. generation stops a loop left from a quick off and on. ]]
run(function()
	local chinaHat
	local material
	local color
	local hat
	local generation = 0

	chinaHat = legit:module('China Hat', {
		toggled = function(on)
			generation += 1
			if on then
				if slinky.threadFix then
					setthreadidentity(8)
				end
	
				hat = Instance.new('MeshPart')
				hat.Size = Vector3.new(3, 0.7, 3)
				hat.Name = 'ChinaHat'
				hat.Material = Enum.Material[material.value]
				hat.Color = Color3.fromHSV(color.hue, color.sat, color.value)
				hat.CanCollide = false
				hat.CanQuery = false
				hat.Massless = true
				hat.MeshId = 'http://www.roblox.com/asset/?id=1778999'
				hat.Transparency = 1 - color.opacity
				hat.Parent = gameCamera
				hat.CFrame = entitylib.isAlive and entitylib.character.Head.CFrame + Vector3.new(0, 1, 0) or CFrame.identity
				local weld = Instance.new('WeldConstraint')
				weld.Part0 = hat
				weld.Part1 = entitylib.isAlive and entitylib.character.Head or nil
				weld.Parent = hat
	
				chinaHat:clean(hat)
				chinaHat:clean(entitylib.Events.LocalAdded:Connect(function(char)
					if weld then
						weld:Destroy()
					end
					hat.Parent = gameCamera
					hat.CFrame = char.Head.CFrame + Vector3.new(0, 1, 0)
					hat.Velocity = Vector3.zero
					weld = Instance.new('WeldConstraint')
					weld.Part0 = hat
					weld.Part1 = char.Head
					weld.Parent = hat
				end))
	
				local gen = generation
				repeat
					hat.LocalTransparencyModifier = ((gameCamera.CFrame.Position - gameCamera.Focus.Position).Magnitude <= 0.6 and 1 or 0)
					task.wait()
				until not chinaHat.enabled or generation ~= gen
			else
				hat = nil
			end
		end,
		about = 'Puts a china hat on your head.\nPick its material, color and transparency. (ty mastadawn)'
	})
	local materials = {'ForceField'}
	for _, v in Enum.Material:GetEnumItems() do
		if v.Name ~= 'ForceField' then
			table.insert(materials, v.Name)
		end
	end
	material = chinaHat:dropdown('Material', {
		choices = materials,
		changed = function(val)
			if hat then
				hat.Material = Enum.Material[val]
			end
		end
	})
	color = chinaHat:color('Hat Color', {
		opacity = 0.7,
		changed = function(hue, sat, val, opacity)
			if hat then
				hat.Color = Color3.fromHSV(hue, sat, val)
				hat.Transparency = 1 - opacity
			end
		end
	})
end)
	
--[[ Clock
Shows your local time on screen, refreshed each second; 24 hour time uses the zh-cn time format. The
Font option stays only for saved profiles: the label is in the menu's Inter through
loaderStyle.text. ]]
run(function()
	local clock
	local twentyFourHour
	local label
	
	clock = legit:module('Clock', {
		toggled = function(on)
			if on then
				repeat
					label.Text = DateTime.now():FormatLocalTime('LT', twentyFourHour.enabled and 'zh-cn' or 'en-us')
					task.wait(1)
				until not clock.enabled
			end
		end,
		size = UDim2.fromOffset(100, 41),
		about = 'Shows your local time on screen.\nPick the font, background, and 12 or 24 hour time.'
	})
	clock:font('Font', {
		exclude = 'Gotham'
	})
	clock:color('Color', loaderStyle.backgroundOption({
		changed = function(hue, sat, val, opacity)
			label.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
			label.BackgroundTransparency = 1 - opacity
			loaderStyle.border(label, opacity)
		end
	}))
	twentyFourHour = clock:toggle('24 Hour Clock')
	label = loaderStyle.reading(clock.frame, '0:00 PM')
end)
	
--[[ Disguise
Wears another player's avatar, or an animation pack, on your own character on your screen. applied
records everything changed on the current character: your items parked with their old parent, the
disguise's items, the old AnimationIds, the head mesh and the emote lists. Switching off puts all of
it back instead of leaving you bald until you respawn.

Only your own look is replaced: held items and armour carry InvItem or ArmorSlot and are left alone,
and items the module added carry Disguise. Your items are parked rather than destroyed, deferred and
retried, because an item arriving through ChildAdded is still being parented and moving it on the
spot throws. Items the game puts on later (a kit skin, a respawned item) are parked as they arrive.

The look is taken from a clone of your own character dressed in the description: same rig and part
names, so its accessories weld straight onto yours. CreateHumanoidModelFromDescription is the
fallback for clients that refuse ApplyDescriptionClientServer. Either way the description takes your
scales first, or the accessories come out sized and placed for someone else's body. Each item moves
on its own, so one that will not move costs only itself. Animate is found with FindFirstChild, never
WaitForChild: a character without one would hang after your own accessories were already gone.

A lookup gets five tries a second apart while the module stays on, then a notification. In Animation
mode an item's slot is the last word of its name ('Ninja Run' is run). A pass that finishes after
the module was switched off undoes itself. ]]
run(function()
	local disguise
	local mode
	local idBox
	local assetService = cloneref(game:GetService('AssetService'))
	local DEFAULT_USER = 239702688
	local DEFAULT_BUNDLE = 43
	local LOOK = {'Accessory', 'ShirtGraphic', 'Shirt', 'Pants', 'BodyColors'}
	local SCALES = {'HeightScale', 'WidthScale', 'DepthScale', 'HeadScale', 'ProportionScale', 'BodyTypeScale'}
	local applied

	local function isLook(v)
		for _, class in LOOK do
			if v:IsA(class) then return true end
		end
		return false
	end

	local function isOwnLook(v)
		if v:GetAttribute('Disguise') or not isLook(v) then return false end
		return not (v:IsA('Accessory') and (v:GetAttribute('InvItem') or v:GetAttribute('ArmorSlot')))
	end

	local function hide(state, v)
		if state.hidden[v] then return end
		state.hidden[v] = v.Parent
		task.spawn(function()
			for _ = 1, 10 do
				task.wait()
				if applied ~= state or pcall(function() v.Parent = nil end) then return end
			end
		end)
	end

	local function restore()
		local state = applied
		applied = nil
		if not state then return end

		for _, connection in state.connections do
			pcall(function() connection:Disconnect() end)
		end
		for _, v in state.added do
			pcall(function() v:Destroy() end)
		end

		local character = state.character
		if not (character and character.Parent) then return end
		for v, parent in state.hidden do
			pcall(function() v.Parent = parent end)
		end
		for animation, id in state.animations do
			pcall(function() animation.AnimationId = id end)
		end
		if state.head then
			pcall(function() state.head.Part.MeshId = state.head.MeshId end)
		end
		if state.emotes then
			pcall(function()
				state.emotes.Description:SetEmotes(state.emotes.Emotes)
				state.emotes.Description:SetEquippedEmotes(state.emotes.Equipped)
			end)
		end
	end

	local function fetch(label, getter)
		for attempt = 1, 5 do
			local ok, result = pcall(getter)
			if ok and result then return result end
			if attempt < 5 then
				task.wait(1)
				if not disguise.enabled then return end
			end
		end
		notif('Disguise', 'Could not load '..label, 5, 'warning')
	end

	local function boxText()
		return (idBox.value:gsub('^%s+', ''):gsub('%s+$', ''))
	end

	local function resolveUserId()
		local text = boxText()
		if text == '' then return DEFAULT_USER end
		return tonumber(text) or fetch('the user '..text, function()
			return playersService:GetUserIdFromNameAsync(text)
		end)
	end

	local function dressedModel(char, desc, ownDesc)
		if ownDesc then
			for _, scale in SCALES do
				pcall(function() desc[scale] = ownDesc[scale] end)
			end
		end

		local clone
		local ok = pcall(function()
			local archivable = char.Character.Archivable
			char.Character.Archivable = true
			clone = char.Character:Clone()
			char.Character.Archivable = archivable
			for _, v in clone:GetChildren() do
				if isLook(v) then v:Destroy() end
			end
			if not pcall(function() clone.Parent = game end) then
				clone.Parent = nil
			end
			clone:FindFirstChildOfClass('Humanoid'):ApplyDescriptionClientServer(desc)
		end)
		if ok and clone then return clone end
		if clone then clone:Destroy() end

		local model
		ok, model = pcall(function()
			return playersService:CreateHumanoidModelFromDescription(desc, char.Humanoid.RigType)
		end)
		return ok and model or nil
	end

	local function wearCharacter(char, state)
		local userId = resolveUserId()
		if not userId or applied ~= state then return end
		local desc = fetch('the avatar of '..userId, function()
			return playersService:GetHumanoidDescriptionFromUserId(userId)
		end)
		if not desc or applied ~= state then return end

		local character = char.Character
		local ownDesc = char.Humanoid:FindFirstChildOfClass('HumanoidDescription')
		local model = dressedModel(char, desc, ownDesc)
		if not model or applied ~= state then
			if model then model:Destroy() end
			notif('Disguise', 'Could not build that avatar on this client', 5, 'warning')
			return
		end

		for _, v in character:GetChildren() do
			if isOwnLook(v) then hide(state, v) end
		end
		table.insert(state.connections, character.ChildAdded:Connect(function(v)
			if applied == state and isOwnLook(v) then hide(state, v) end
		end))

		for _, v in model:GetChildren() do
			if isLook(v) then
				pcall(function()
					v:SetAttribute('Disguise', true)
					for _, weld in v:GetDescendants() do
						if weld:IsA('Weld') and weld.Part1 then
							local part = character:FindFirstChild(weld.Part1.Name)
							if part then weld.Part1 = part end
						end
					end
					v.Parent = character
					table.insert(state.added, v)
				end)
			end
		end

		local head, modelHead = char.Head, model:FindFirstChild('Head')
		if head and modelHead and head:IsA('MeshPart') and modelHead:IsA('MeshPart') and not head:FindFirstChild('FaceControls') then
			local oldMesh = head.MeshId
			if pcall(function() head.MeshId = modelHead.MeshId end) then
				state.head = {Part = head, MeshId = oldMesh}
			end
		end

		local face = head and head:FindFirstChild('face')
		local modelFace = modelHead and modelHead:FindFirstChild('face')
		if face and modelFace then
			hide(state, face)
			pcall(function()
				modelFace:SetAttribute('Disguise', true)
				modelFace.Parent = head
				table.insert(state.added, modelFace)
			end)
		end

		local animate, modelAnimate = character:FindFirstChild('Animate'), model:FindFirstChild('Animate')
		if animate and modelAnimate then
			for _, slot in modelAnimate:GetChildren() do
				local real = animate:FindFirstChild(slot.Name)
				if real then
					for _, anim in slot:GetChildren() do
						local realAnim = anim:IsA('Animation') and real:FindFirstChild(anim.Name)
						if realAnim and realAnim:IsA('Animation') and anim.AnimationId ~= '' then
							state.animations[realAnim] = state.animations[realAnim] or realAnim.AnimationId
							realAnim.AnimationId = anim.AnimationId
						end
					end
				end
			end
		end

		if ownDesc then
			pcall(function()
				state.emotes = {Description = ownDesc, Emotes = ownDesc:GetEmotes(), Equipped = ownDesc:GetEquippedEmotes()}
				ownDesc:SetEmotes(desc:GetEmotes())
				ownDesc:SetEquippedEmotes(desc:GetEquippedEmotes())
			end)
		end

		model:Destroy()
		desc:Destroy()
	end

	local function wearAnimations(char, state)
		local text = boxText()
		local bundleId = text == '' and DEFAULT_BUNDLE or tonumber(text)
		if not bundleId then
			notif('Disguise', 'Animation mode takes an animation pack (bundle) id', 5, 'warning')
			return
		end
		local data = fetch('bundle '..bundleId, function()
			local ok, info = pcall(function()
				return marketplaceService:GetProductInfo(bundleId, Enum.InfoType.Bundle)
			end)
			if ok and type(info) == 'table' and type(info.Items) == 'table' then return info end
			return assetService:GetBundleDetailsAsync(bundleId)
		end)
		if not data or applied ~= state then return end

		local animate = char.Character:FindFirstChild('Animate')
		if not animate then
			notif('Disguise', 'Your character has no animation script to change', 5, 'warning')
			return
		end

		local changed = 0
		for _, item in (data.Items or {}) do
			local slot = type(item.Name) == 'string' and item.Name:match('(%a+)%s*$')
			local real = slot and animate:FindFirstChild(slot:lower())
			if real and applied == state then
				local ok, objects = pcall(function()
					return game:GetObjects('rbxassetid://'..item.Id)
				end)
				local loaded = ok and objects and objects[1]
				if loaded then
					for _, anim in real:GetChildren() do
						if anim:IsA('Animation') then
							local source = loaded:FindFirstChild(anim.Name, true)
							if not (source and source:IsA('Animation')) then
								source = loaded:FindFirstChildWhichIsA('Animation', true)
							end
							if source then
								state.animations[anim] = state.animations[anim] or anim.AnimationId
								anim.AnimationId = source.AnimationId
								changed += 1
							end
						end
					end
				end
			end
		end

		if changed == 0 and applied == state then
			notif('Disguise', 'That is not an animation pack', 5, 'warning')
		end
	end

	local function characterAdded(char)
		restore()
		if not (disguise.enabled and char and char.Character) then return end
		if slinky.threadFix then
			setthreadidentity(8)
		end

		local state = {character = char.Character, hidden = {}, added = {}, animations = {}, connections = {}}
		applied = state
		local ok, err = pcall(mode.value == 'Character' and wearCharacter or wearAnimations, char, state)
		if not ok then
			notif('Disguise', 'Failed: '..tostring(err), 5, 'warning')
		end
		if applied == state and not disguise.enabled then
			restore()
		end
	end

	disguise = legit:module('Disguise', {
		toggled = function(on)
			if on then
				disguise:clean(entitylib.Events.LocalAdded:Connect(characterAdded))
				if entitylib.isAlive then
					task.spawn(characterAdded, entitylib.character)
				end
			else
				restore()
			end
		end,
		about = 'Wears another avatar or animation pack on your screen.\nEnter a username or user id for an avatar, or a bundle id for animations.'
	})
	mode = disguise:dropdown('Mode', {
		choices = {'Character', 'Animation'},
		changed = function()
			if disguise.enabled then
				disguise:flip()
				disguise:flip()
			end
		end
	})
	idBox = disguise:textbox('Disguise', {
		placeholder = 'User id / username, or bundle id',
		changed = function()
			if disguise.enabled then
				disguise:flip()
				disguise:flip()
			end
		end
	})
end)
	
--[[ FOV
Changes how wide your camera can see. ]]
run(function()
	local fov
	local amount
	local oldfov
	
	fov = legit:module('FOV', {
		toggled = function(on)
			if on then
				oldfov = gameCamera.FieldOfView
				repeat
					gameCamera.FieldOfView = amount.value
					task.wait()
				until not fov.enabled
			else
				gameCamera.FieldOfView = oldfov
			end
		end,
		about = 'Changes how wide your camera can see.'
	})
	amount = fov:slider('FOV', {
		min = 30,
		max = 120
	})
end)

--[[ FPS
Shows your frames per second on screen, counted over the last second. Source:
https://devforum.roblox.com/t/get-client-FPS-trough-a-script/282631

The frame times sit between first and last, oldest first; old ones are dropped from the front
instead of shifting every entry along each frame. The Font option stays only for saved profiles: the
label is in the menu's Inter through loaderStyle.text. ]]
run(function()
	local fps
	local label

	fps = legit:module('FPS', {
		toggled = function(on)
			if on then
				local frames, first, last = {}, 1, 0
				local startClock = os.clock()
				local updateTick = tick()

				fps:clean(runService.Heartbeat:Connect(function()
					local updateClock = os.clock()
					while first <= last and frames[first] < updateClock - 1 do
						frames[first] = nil
						first += 1
					end

					last += 1
					frames[last] = updateClock
					if updateTick < tick() then
						updateTick = tick() + 1
						local count = last - first + 1
						label.Text = loaderStyle.unit(math.floor(os.clock() - startClock >= 1 and count or count / (os.clock() - startClock)), 'FPS')
					end
				end))
			end
		end,
		size = UDim2.fromOffset(100, 41),
		about = 'Shows your frames per second on screen.\nPick the font and background.'
	})
	fps:font('Font', {
		exclude = 'Gotham'
	})
	fps:color('Color', loaderStyle.backgroundOption({
		changed = function(hue, sat, val, opacity)
			label.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
			label.BackgroundTransparency = 1 - opacity
			loaderStyle.border(label, opacity)
		end
	}))
	label = loaderStyle.reading(fps.frame, loaderStyle.unit('inf', 'FPS'))
end)
	
--[[ Keystrokes
Shows your movement keys and the spacebar on screen as loader boxes, in the loader's orange with
dark text while pressed. A phone has no movement keys: its thumbstick and jump button drive the
humanoid, so on a touch-only device the keys follow which way the humanoid walks relative to the
camera, and whether it jumps. The spacebar outlives a restart, so it is set released on enable like
the rest. ]]
run(function()
	local keystrokes
	local style
	local color
	local keys, holder = {}
	
	local function createKeystroke(keybutton, pos, text)
		if keys[keybutton] then
			keys[keybutton].Key:Destroy()
			keys[keybutton] = nil
		end

		local space = keybutton == Enum.KeyCode.Space
		local key = Instance.new('Frame')
		key.Size = space and UDim2.new(0, 110, 0, 24) or UDim2.new(0, 34, 0, 36)
		loaderStyle.box(key)
		local colour, opacity = loaderStyle.colorOf(color)
		key.BackgroundColor3 = colour
		key.BackgroundTransparency = 1 - opacity
		loaderStyle.border(key, opacity)
		key.Position = pos
		key.Name = keybutton.Name
		key.Parent = holder
		local keytext = Instance.new('TextLabel')
		keytext.BackgroundTransparency = 1
		keytext.Size = UDim2.fromScale(1, 1)
		keytext.Text = space and '' or text or keybutton.Name
		keytext.TextSize = 15
		loaderStyle.text(keytext, 'SemiBold')
		keytext.Parent = key
		local bar
		if space then
			bar = Instance.new('Frame')
			bar.AnchorPoint = Vector2.new(0.5, 0.5)
			bar.Position = UDim2.fromScale(0.5, 0.5)
			bar.Size = UDim2.new(0.4, 0, 0, 2)
			bar.BackgroundColor3 = loaderStyle.Text
			bar.BorderSizePixel = 0
			bar.Parent = key
			local barcorner = Instance.new('UICorner')
			barcorner.CornerRadius = UDim.new(1, 0)
			barcorner.Parent = bar
		end
	
		keys[keybutton] = {Key = key, Text = keytext, Bar = bar}
	end

	local function setPressed(keyCode, pressed)
		local key = keys[keyCode]
		if not key or key.Pressed == pressed then return end
		key.Pressed = pressed
		for _, tween in key.Tweens or {} do
			tween:Cancel()
		end
		local textColor = pressed and loaderStyle.Pressed or loaderStyle.Text
		local colour, opacity = loaderStyle.colorOf(color)
		key.Tweens = {
			tweenService:Create(key.Key, TweenInfo.new(0.1), {
				BackgroundColor3 = pressed and loaderStyle.Orange or colour,
				BackgroundTransparency = pressed and 0 or 1 - opacity
			}),
			tweenService:Create(key.Text, TweenInfo.new(0.1), {TextColor3 = textColor})
		}
		if key.Bar then
			table.insert(key.Tweens, tweenService:Create(key.Bar, TweenInfo.new(0.1), {BackgroundColor3 = textColor}))
		end
		for _, tween in key.Tweens do
			tween:Play()
		end
	end
	
	local function updateKey(inputType)
		setPressed(inputType.KeyCode, inputType.UserInputState == Enum.UserInputState.Begin)
	end

	local function touchKeys()
		local humanoid = entitylib.isAlive and entitylib.character.Humanoid
		local forward, right, jump = 0, 0, false
		if humanoid then
			local look = gameCamera.CFrame.LookVector * Vector3.new(1, 0, 1)
			if look.Magnitude > 1e-3 then
				look = look.Unit
				local move = humanoid.MoveDirection
				forward, right = move:Dot(look), move:Dot(Vector3.new(-look.Z, 0, look.X))
			end
			jump = humanoid.Jump
		end
		setPressed(Enum.KeyCode.W, forward > 0.3)
		setPressed(Enum.KeyCode.S, forward < -0.3)
		setPressed(Enum.KeyCode.A, right < -0.3)
		setPressed(Enum.KeyCode.D, right > 0.3)
		setPressed(Enum.KeyCode.Space, jump)
	end
	
	keystrokes = legit:module('Keystrokes', {
		toggled = function(on)
			if on then
				createKeystroke(Enum.KeyCode.W, UDim2.new(0, 38, 0, 0), style.value == 'Arrow' and '↑' or nil)
				createKeystroke(Enum.KeyCode.S, UDim2.new(0, 38, 0, 42), style.value == 'Arrow' and '↓' or nil)
				createKeystroke(Enum.KeyCode.A, UDim2.new(0, 0, 0, 42), style.value == 'Arrow' and '←' or nil)
				createKeystroke(Enum.KeyCode.D, UDim2.new(0, 76, 0, 42), style.value == 'Arrow' and '→' or nil)
				setPressed(Enum.KeyCode.Space, false)
	
				if inputService.TouchEnabled and not inputService.KeyboardEnabled then
					keystrokes:clean(runService.RenderStepped:Connect(touchKeys))
				else
					keystrokes:clean(inputService.InputBegan:Connect(updateKey))
					keystrokes:clean(inputService.InputEnded:Connect(updateKey))
				end
			end
		end,
		size = UDim2.fromOffset(110, 176),
		about = 'Shows your movement keys on screen as you press them.\nPick letter or arrow keys, the color, and whether Space shows.'
	})
	holder = Instance.new('Frame')
	holder.Size = UDim2.fromScale(1, 1)
	holder.BackgroundTransparency = 1
	holder.Parent = keystrokes.frame
	style = keystrokes:dropdown('Key Style', {
		choices = {'Keyboard', 'Arrow'},
		changed = function()
			if keystrokes.enabled then
				keystrokes:flip()
				keystrokes:flip()
			end
		end
	})
	color = keystrokes:color('Color', loaderStyle.backgroundOption({
		changed = function(hue, sat, val, opacity)
			for _, v in keys do
				if not v.Pressed then
					v.Key.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
					v.Key.BackgroundTransparency = 1 - opacity
				end
				loaderStyle.border(v.Key, opacity)
			end
		end
	}))
	keystrokes:toggle('Show Spacebar', {
		changed = function(callback)
			keystrokes.frame.Size = UDim2.fromOffset(110, callback and 107 or 78)
	
			if callback then
				createKeystroke(Enum.KeyCode.Space, UDim2.new(0, 0, 0, 83))
			elseif keys[Enum.KeyCode.Space] then
				keys[Enum.KeyCode.Space].Key:Destroy()
				keys[Enum.KeyCode.Space] = nil
			end
		end,
		default = true
	})
end)
	
--[[ Memory
Shows how much memory Roblox is using, in MB, refreshed each second. The Font option stays only for
saved profiles: the label is in the menu's Inter through loaderStyle.text. ]]
run(function()
	local memory
	local label
	
	memory = legit:module('Memory', {
		toggled = function(on)
			if on then
				repeat
					label.Text = loaderStyle.unit(math.floor(tonumber(game:GetService('Stats'):FindFirstChild('PerformanceStats').Memory:GetValue())), 'MB')
					task.wait(1)
				until not memory.enabled
			end
		end,
		size = UDim2.fromOffset(100, 41),
		about = 'Shows how much memory Roblox is using.\nPick the font and background.'
	})
	memory:font('Font', {
		exclude = 'Gotham'
	})
	memory:color('Color', loaderStyle.backgroundOption({
		changed = function(hue, sat, val, opacity)
			label.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
			label.BackgroundTransparency = 1 - opacity
			loaderStyle.border(label, opacity)
		end
	}))
	label = loaderStyle.reading(memory.frame, loaderStyle.unit('0', 'MB'))
end)
	
--[[ Ping
Shows your ping to the server in milliseconds, refreshed each second. The Font option stays only for
saved profiles: the label is in the menu's Inter through loaderStyle.text. ]]
run(function()
	local ping
	local label

	ping = legit:module('Ping', {
		toggled = function(on)
			if on then
				repeat
					label.Text = loaderStyle.unit(math.floor(tonumber(game:GetService('Stats'):FindFirstChild('PerformanceStats').Ping:GetValue())), 'ms')
					task.wait(1)
				until not ping.enabled
			end
		end,
		size = UDim2.fromOffset(100, 41),
		about = 'Shows your ping to the server in milliseconds.\nPick the font and background.'
	})
	ping:font('Font', {
		exclude = 'Gotham'
	})
	ping:color('Color', loaderStyle.backgroundOption({
		changed = function(hue, sat, val, opacity)
			label.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
			label.BackgroundTransparency = 1 - opacity
			loaderStyle.border(label, opacity)
		end
	}))
	label = loaderStyle.reading(ping.frame, loaderStyle.unit('0', 'ms'))
end)
	
--[[ Song Beats
Plays your own music files in random order and can pulse the field of view on each beat. A list
entry is filepath/bpm/start: the bpm (50 when missing) sets the beat interval and start delays the
first beat by that many seconds. generation stops the loop left from a Beat FOV restart or a quick
off and on. ]]
run(function()
	local songBeats
	local list
	local fov
	local fovValue = {}
	local volume
	local alreadypicked = {}
	local beattick = tick()
	local oldfov, songobj, songbpm, songtween
	local generation = 0

	local function choosesong()
		local list = list.active
		if #alreadypicked >= #list then
			table.clear(alreadypicked)
		end
	
		if #list <= 0 then
			notif('SongBeats', 'no songs', 10)
			songBeats:flip()
			return
		end
	
		local chosensong = list[math.random(1, #list)]
		if #list > 1 and table.find(alreadypicked, chosensong) then
			repeat
				task.wait()
				chosensong = list[math.random(1, #list)]
			until not table.find(alreadypicked, chosensong) or not songBeats.enabled
		end
		if not songBeats.enabled then return end
	
		local split = chosensong:split('/')
		if not isfile(split[1]) then
			notif('SongBeats', 'Missing song ('..split[1]..')', 10)
			songBeats:flip()
			return
		end
	
		songobj.SoundId = assetfunction(split[1])
		repeat
			task.wait()
		until songobj.IsLoaded or not songBeats.enabled
	
		if songBeats.enabled then
			beattick = tick() + (tonumber(split[3]) or 0)
			songbpm = 60 / (tonumber(split[2]) or 50)
			songobj:Play()
		end
	end
	
	songBeats = legit:module('Song Beats', {
		tab = 'Utility',
		toggled = function(on)
			generation += 1
			if on then
				songobj = Instance.new('Sound')
				songobj.Volume = volume.value / 100
				songobj.Parent = workspace
				oldfov = gameCamera.FieldOfView

				local gen = generation
				repeat
					if not songobj.Playing then
						choosesong()
					end
	
					if beattick < tick() and songBeats.enabled and fov.enabled then
						beattick = tick() + songbpm
						gameCamera.FieldOfView = oldfov - fovValue.value
						songtween = tweenService:Create(gameCamera, TweenInfo.new(math.min(songbpm, 0.2), Enum.EasingStyle.Linear), {
							FieldOfView = oldfov
						})
						songtween:Play()
					end
	
					task.wait()
				until not songBeats.enabled or generation ~= gen
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
		about = 'Plays your own music files while you play.\nCan pulse your FOV to the beat; set the volume and pulse size.'
	})
	list = songBeats:list('Songs', {
		placeholder = 'filepath/bpm/start'
	})
	fov = songBeats:toggle('Beat FOV', {
		changed = function(callback)
			if fovValue.row then
				fovValue.row.Visible = callback
			end
	
			if songBeats.enabled then
				songBeats:flip()
				songBeats:flip()
			end
		end,
		default = true
	})
	fovValue = songBeats:slider('Adjustment', {
		min = 1,
		max = 30,
		default = 5,
		sub = true
	})
	volume = songBeats:slider('Volume', {
		changed = function(val)
			if songobj then
				songobj.Volume = val / 100
			end
		end,
		min = 1,
		max = 100,
		default = 100,
		suffix = '%'
	})
end)
	
--[[ Speedmeter
Shows your horizontal speed in studs per second, measured over 0.2 s steps. Uninject clears
entitylib during the wait, so the loop stops once it is gone. The Font option stays only for saved
profiles: the label is in the menu's Inter through loaderStyle.text. ]]
run(function()
	local speedmeter
	local label
	
	speedmeter = legit:module('Speedmeter', {
		toggled = function(on)
			if on then
				repeat
					local lastpos = entitylib.isAlive and entitylib.character.HumanoidRootPart.Position * Vector3.new(1, 0, 1) or Vector3.zero
					local dt = task.wait(0.2)
					if not entitylib then break end
					local newpos = entitylib.isAlive and entitylib.character.HumanoidRootPart.Position * Vector3.new(1, 0, 1) or Vector3.zero
					label.Text = loaderStyle.unit(math.round(((lastpos - newpos) / dt).Magnitude), 'sps')
				until not speedmeter.enabled
			end
		end,
		size = UDim2.fromOffset(100, 41),
		about = 'Shows how fast you are moving, in studs per second.\nPick the font and background.'
	})
	speedmeter:font('Font', {
		exclude = 'Gotham'
	})
	speedmeter:color('Color', loaderStyle.backgroundOption({
		changed = function(hue, sat, val, opacity)
			label.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
			label.BackgroundTransparency = 1 - opacity
			loaderStyle.border(label, opacity)
		end
	}))
	label = loaderStyle.reading(speedmeter.frame, loaderStyle.unit('0', 'sps'))
end)
	
--[[ Time Changer
Sets the time of day to the hour you choose. ]]
run(function()
	local timeChanger
	local amount
	local old
	
	timeChanger = legit:module('Time Changer', {
		toggled = function(on)
			if on then
				old = lightingService.TimeOfDay
				lightingService.TimeOfDay = amount.value..':00:00'
			else
				lightingService.TimeOfDay = old
				old = nil
			end
		end,
		about = 'Sets the time of day to the hour you choose.'
	})
	amount = timeChanger:slider('Time', {
		min = 0,
		max = 24,
		default = 12,
		changed = function(val)
			if timeChanger.enabled then 
				lightingService.TimeOfDay = val..':00:00'
			end
		end
	})
end)

--[[ Transparency
Makes your body parts, hair and armour see-through on your screen, and puts the original values back
on off. It reapplies at 10 Hz, not every frame: each pass sweeps the character's children and
descendants, hundreds of instance calls per frame at 60 fps, and the game only rarely resets
transparency; slider changes still apply at once. restoreTransparency is registered on every enable
because each disable clears the module's cleanup list. ]]
run(function()
    local transparency
    local sliders = {}
    local hideArmor
    local connection

    local originalTransparency = {}

    local parts = {
        "Head",
        "UpperTorso", "LowerTorso",
        "LeftUpperArm", "LeftLowerArm", "LeftHand",
        "RightUpperArm", "RightLowerArm", "RightHand",
        "LeftUpperLeg", "LeftLowerLeg", "LeftFoot",
        "RightUpperLeg", "RightLowerLeg", "RightFoot"
    }

    local function getCharacter()
        local char = entitylib.character
        if typeof(char) == "table" then
            if char.character then
                char = char.character
            elseif char.HumanoidRootPart then
                char = char.HumanoidRootPart.Parent
            end
        end
        return typeof(char) == "Instance" and cloneref(char) or nil
    end

    local function isArmor(name)
        local lowered = name:lower()
        return lowered:find("helmet") or lowered:find("chestplate") or lowered:find("boots")
    end

    local function setHandleTransparency(handle, value)
        if handle:IsA("BasePart") then
            if originalTransparency[handle] == nil then
                originalTransparency[handle] = handle.Transparency
            end
            handle.Transparency = value
        end
        for _, child in ipairs(handle:GetDescendants()) do
            if child:IsA("BasePart") then
                if originalTransparency[child] == nil then
                    originalTransparency[child] = child.Transparency
                end
                child.Transparency = value
            end
        end
    end

    local function handleArmor(char, transparency)
        for _, accessory in ipairs(char:GetChildren()) do
            if accessory:IsA("Accessory") and accessory:FindFirstChild("Handle") then
                if isArmor(accessory.Name) then
                    setHandleTransparency(accessory.Handle, transparency)
                end
            end
        end
    end

    local function setTransparency()
        if not transparency.enabled then return end
        if not entitylib.isAlive then return end

        local char = getCharacter()
        if not char then return end

        for partName, slider in pairs(sliders) do
            local part = char:FindFirstChild(partName)
            if part then
                if originalTransparency[part] == nil then
                    originalTransparency[part] = part.Transparency
                end
                part.Transparency = slider.value

                if partName == "Head" then
                    local face = part:FindFirstChild("face")
                    if face and face:IsA("Decal") then
                        if originalTransparency[face] == nil then
                            originalTransparency[face] = face.Transparency
                        end
                        face.Transparency = slider.value
                    end
                end
            end
        end

        for _, obj in ipairs(char:GetChildren()) do
            if obj:IsA("Accessory") and obj:FindFirstChild("Handle") then
                if obj.Name:lower():find("hair") then
                    setHandleTransparency(obj.Handle, sliders.Hair.value)
                end
            end
        end

        if hideArmor.enabled then
            handleArmor(char, 1)
        else
            handleArmor(char, 0)
        end
    end

    local function restoreTransparency()
        if connection then
            connection:Disconnect()
            connection = nil
        end

        local char = getCharacter()
        if char then
            for obj, value in pairs(originalTransparency) do
                if obj and obj:IsDescendantOf(char) then
                    obj.Transparency = value
                end
            end
        end

        table.clear(originalTransparency)
    end

    transparency = render:module('Transparency', {
        toggled = function(on)
            if on then
                local nextApply = 0
                connection = runService.RenderStepped:Connect(function()
                    if os.clock() < nextApply then return end
                    nextApply = os.clock() + 0.1
                    setTransparency()
                end)
                transparency:clean(restoreTransparency)
            end
        end,
        about = 'Makes parts of your character see-through for you.\nSet each body part and your hair, and hide your armor.'
    })

    sliders.Hair = transparency:slider("Hair", {
        min = 0,
        max = 1,
        default = 0,
        decimal = 10,
        changed = setTransparency
    })

    for _, partName in ipairs(parts) do
        sliders[partName] = transparency:slider(partName, {
            min = 0,
            max = 1,
            default = 0,
            decimal = 10,
            changed = setTransparency
        })
    end

    hideArmor = transparency:toggle("Hide Armor", {
        changed = setTransparency,
        default = false
    })
end)

	--[[ AnimDisabler
	Stops every animation track on your character each frame. The Animator is kept with the
	character and humanoid it was found under and looked up again only once one of them changes,
	which saves three clonerefs and two child searches per step. On off the Animate script is
	disabled and enabled again. ]]
	run(function()
		local animDisabler
		local animChar, animHumanoid, animator

		animDisabler = utility:module('AnimDisabler', {
			tab = 'Visual',
			toggled = function(on)
				if on then
					if not animDisabler.connection then
						animDisabler.connection = runService.Heartbeat:Connect(function()
							local character = lplr.Character
							if not character then return end
							if character ~= animChar or not animator or animator.Parent ~= animHumanoid or animHumanoid.Parent ~= character then
								animChar, animHumanoid, animator = character, nil, nil
								local humanoid = cloneref(character):FindFirstChildOfClass('Humanoid')
								if not humanoid then return end
								animHumanoid = humanoid
								local found = cloneref(humanoid):FindFirstChildOfClass('Animator')
								if not found then return end
								animator = cloneref(found)
							end
							for _, track in animator:GetPlayingAnimationTracks() do
								track:Stop()
							end
						end)
					end
				else
					if animDisabler.connection then
						animDisabler.connection:Disconnect()
						animDisabler.connection = nil
					end
					animChar, animHumanoid, animator = nil, nil, nil
					local character = lplr.Character
					if character then
						character = cloneref(character)
						local animate = character:FindFirstChild('Animate')
						if animate then
							animate = cloneref(animate)
							animate.Disabled = true
							animate.Disabled = false
						end
					end
				end
			end,
			about = 'Disables all your animations completely.'
		})
	end)

--[[ FPS Unlocker
Raises the framerate cap while on, and on off puts back the cap read at load (60 when getfpscap is
missing). Nothing but setfpscap can raise the cap, so without it the module is left out of the list.
]]
run(function()
	local fpsUnlocker
	local cap
	local previousCap
	if not exec.FpsCap then
		exec.hide('FPS Unlocker', 'needs setfpscap')
		return
	end
	if getfpscap then
		local ok, value = pcall(getfpscap)
		previousCap = ok and tonumber(value) or nil
	end

	fpsUnlocker = legit:module('FPS Unlocker', {
		tab = 'Utility',
		toggled = function(on)
			if on then
				if not setfpscap then
					notif('FPSUnlocker', 'This feature requires setfpscap! (your executor does not support it)', 10, 'warning')
					fpsUnlocker:flip()
					return
				end
				setfpscap(cap.value)
			else
				if setfpscap then
					setfpscap(previousCap or 60)
				end
			end
		end,
		info = function()
			return tostring(cap.value)
		end,
		about = 'Raises the framerate cap while enabled.'
	})
	cap = fpsUnlocker:slider('FPS Cap', {
		min = 30,
		max = 999,
		default = 999,
		changed = function(val)
			if fpsUnlocker.enabled and setfpscap then
				setfpscap(val)
			end
		end,
		about = 'Framerate cap applied while the module is on'
	})
end)

--[[ ZoomUnlocker
Lets the camera zoom out further than the game allows. The game writes CameraMaxZoomDistance itself:
the zipline handler sets 20 and then restores 14, aiming down a scope sets 6.5 and restores what it
captured, and menu and spectate paths write 30, 40 and 100. So the value is applied again whenever
it changes.

Not while min and max are equal: aiming and ziplining pin the distance that way, fighting them
breaks the scope and the ride, and both end with a normal min < max that brings the value back. The
reapply is deferred because those paths write max and min as two statements; inline it would see max
changed with min still 0, read that as a normal range and overwrite the pin.

On off the place default is restored, StarterPlayer.CameraMaxZoomDistance (14 when it cannot be
read), which is the value the game's own code writes back; the value at enable could be the 6.5 of a
scope. ]]
run(function()
	local zoomUnlocker
	local maxZoom
	local zoomConn

	local FALLBACK_MAX_ZOOM = 14

	local function defaultMaxZoom()
		local ok, val = pcall(function()
			return cloneref(game:GetService('StarterPlayer')).CameraMaxZoomDistance
		end)
		if ok and type(val) == 'number' and val > 0 then return val end
		return FALLBACK_MAX_ZOOM
	end

	local pending = false

	local function applyZoom()
		pending = false
		if not (zoomUnlocker and zoomUnlocker.enabled) then return end
		if lplr.CameraMinZoomDistance >= lplr.CameraMaxZoomDistance then return end
		if lplr.CameraMaxZoomDistance ~= maxZoom.value then
			lplr.CameraMaxZoomDistance = maxZoom.value
		end
	end

	local function queueZoom()
		if pending then return end
		pending = true
		task.defer(applyZoom)
	end

	zoomUnlocker = utility:module('ZoomUnlocker', {
		tab = 'Visual',
		toggled = function(on)
			if on then
				applyZoom()
				zoomConn = lplr:GetPropertyChangedSignal('CameraMaxZoomDistance'):Connect(queueZoom)
			else
				if zoomConn then
					pcall(function() zoomConn:Disconnect() end)
					zoomConn = nil
				end
				pending = false
				lplr.CameraMaxZoomDistance = defaultMaxZoom()
			end
		end,
		about = 'Lets you zoom your camera further out.'
	})

	maxZoom = zoomUnlocker:slider('Max Zoom Distance', {
		min = 14,
		max = 1000,
		default = 100,
		suffix = function(v) return v == 1 and 'stud' or 'studs' end,
		changed = function()
			if zoomUnlocker and zoomUnlocker.enabled then
				queueZoom()
			end
		end,
		about = 'How far out the camera is allowed to go. 14 is the game default'
	})
end)

--[[ ChatMover
Moves Roblox's chat to the top or bottom of the screen and puts its old alignment back on off. On a
touch-only device the chat always goes to the top, since the bottom left belongs to the thumbstick.
ChatWindowConfiguration can arrive a moment after the game has loaded, so the first apply waits for
it. ]]
run(function()
	local chatMover
	local position
	local original

	local function apply()
		local config = textChatService:FindFirstChild('ChatWindowConfiguration')
		if not config then return end
		if original == nil then
			original = config.VerticalAlignment
		end
		local touchOnly = inputService.TouchEnabled and not inputService.KeyboardEnabled
		config.VerticalAlignment = (position.value == 'Top' or touchOnly) and Enum.VerticalAlignment.Top or Enum.VerticalAlignment.Bottom
	end

	chatMover = utility:module('ChatMover', {
		label = 'Chat Mover',
		toggled = function(on)
			if on then
				task.spawn(function()
					textChatService:WaitForChild('ChatWindowConfiguration', 10)
					if chatMover.enabled then
						apply()
					end
				end)
			else
				local config = textChatService:FindFirstChild('ChatWindowConfiguration')
				if config and original ~= nil then
					config.VerticalAlignment = original
				end
				original = nil
			end
		end,
		about = 'Moves the chat to the top or bottom of your screen.'
	})
	position = chatMover:dropdown('Position', {
		choices = {'Bottom', 'Top'},
		changed = function()
			if chatMover.enabled then
				apply()
			end
		end
	})
end)
