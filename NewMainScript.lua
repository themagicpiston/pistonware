local pistonwareBuffer
pcall(function()
	local env = getgenv()
	pistonwareBuffer = type(env.pistonware) == 'table' and env.pistonware.buffer or nil
end)

if not shared.PistonwareAuthenticated then
	if type(pistonwareBuffer) == 'table' and type(pistonwareBuffer.warn) == 'function' then
		pistonwareBuffer.warn('legacy.entrypoint', 'NewMainScript.lua no longer injects on its own -- run loader.lua instead')
	elseif shared.PistonwareDeveloper == true then
		warn('[pistonware] NewMainScript.lua no longer injects on its own -- run loader.lua instead')
	end
	return
end

local isfile = isfile or function(file)
	local suc, res = pcall(function()
		return readfile(file)
	end)
	return suc and res ~= nil and res ~= ''
end
local cloneref = cloneref or function(ref)
	return ref
end

local function pistonwareHttpGet(url, nocache, attempt)
	local adapter = shared.PistonwareDevHttpGet
	if type(adapter) == 'function' then
		return adapter(url, nocache, attempt)
	end
	return game:HttpGet(url, nocache)
end

local function pistonwareProtectedHttpGet(url, nocache, attempt)
	local adapter = shared.PistonwareDevProtectedHttpGet
	if type(adapter) == 'function' then
		return adapter(url, nocache, attempt)
	end
	return game:HttpGet(url, nocache)
end

--[[ As in `main.lua`, `isfile` alone is insufficient: every
executor's real isfile reports a zero-byte file as PRESENT, so a write cut short by a
cancel, crash or teleport leaves a truncated file that cache-first logic then skips
forever. For a .lua file that is a chunk which silently does nothing; for an asset it is a
content id that throws when the GUI reads it. Treating empty as missing repairs it on the
next run instead of requiring a reinstall. ]]
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

--[[ Returns a file's text, downloading it first when hasContent finds it missing, empty or not
compiling; the developer loader takes the request when it is there. Developer mode never replaces a
file that has something in it: one that does not compile stops the load on its compile error.
bedwars.lua comes from the root of the GitLab repo though it caches under games/; everything else
comes from the GitHub repo. Raw hosts intermittently answer with an empty body, so there are 4
tries, and a non-.lua body that unusableBody rejects is never cached. ]]
local function downloadFile(path, func)
	local devLoader = shared.PistonwareDevLoadSource
	if type(devLoader) == 'function' then
		local body = devLoader(path)
		return func and func(path) or body
	end
	if not hasContent(path) then
		if shared.PistonwareDeveloper == true then
			local ok, text = pcall(readfile, path)
			if isfile(path) and ok and type(text) == 'string' and text ~= '' then
				local compileOk, chunk, compileError = pcall(loadstring, text, path)
				error(path..' does not compile (developer mode does not replace it): '..tostring(compileOk and compileError or chunk), 0)
			end
		end
		local relPath = select(1, path:gsub('pistonware/', ''))
		local isBedwars = relPath == 'games/bedwars.lua'
		local content
		for attempt = 1, 4 do
			local suc, res = pcall(function()
				if isBedwars then
					return pistonwareProtectedHttpGet('https://gitlab.com/pistonware/pistonware/-/raw/main/bedwars.lua', true, attempt)
				end
				return pistonwareHttpGet('https://raw.githubusercontent.com/themagicpiston/pistonware/main/'..relPath, true, attempt)
			end)
			if suc and res and res ~= '' and res ~= '404: Not Found' and (path:find('%.lua$') or not unusableBody(path, res)) then
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
	end
	return (func or readfile)(path)
end

for _, folder in {'pistonware', 'pistonware/games', 'pistonware/profiles', 'pistonware/assets', 'pistonware/libraries'} do
	if not isfolder(folder) then
		makefolder(folder)
	end
end

--[[ How many profiles the folder holds, as the loaders count them: a <name>.json each, or the
<name><placeId>.txt of an older build until guilibrary.lua has converted it. The profile of another
game, <name>.<placeId>.json, counts too: it is a profile, and the install is not new. settings.json, the
old folder and the loader's own notes are not profiles. ]]
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

--[[ On an install with no profiles, downloads every file in the repo's profiles folder except gui.txt,
whitelist.json and a settings.json that holdsBackSettings keeps for the next sync. The downloads run
in parallel and are joined on a counter with a 90 s deadline, so a worker that dies cannot park the
boot.

profile system credit to maxlasertech ]]
pcall(function()
	if countProfiles() == 0 then
		local reqSuc, res = pcall(function()
			return pistonwareHttpGet('https://api.github.com/repos/themagicpiston/pistonware/contents/profiles', true)
		end)
		if reqSuc and res and res ~= '404: Not Found' then
			local bodySuc, body = pcall(function()
				return cloneref(game:GetService('HttpService')):JSONDecode(res)
			end)
			if bodySuc and body and typeof(body) == 'table' then
				local total, completed = 0, 0
				for _, v in body do
					if v.type == 'file' and v.path ~= 'profiles/gui.txt' and v.path ~= 'profiles/whitelist.json'
						and not holdsBackSettings('pistonware/'..v.path) then
						total += 1
						task.spawn(function()
							pcall(downloadFile, 'pistonware/'.. ({v.path:gsub(' ', '%%20')})[1])
							completed += 1
						end)
					end
				end
				local deadline = os.clock() + 90
				while completed < total and os.clock() < deadline do
					task.wait(0.05)
				end
			end
		end
	end
end)

local mainChunk = loadstring(downloadFile('pistonware/main.lua'), 'main')
return mainChunk and mainChunk()
