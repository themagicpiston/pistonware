if not shared.PistonwareAuthenticated then
	warn('[pistonware] NewMainScript.lua is the old loader and no longer injects on its own -- run loader.lua instead')
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

local function downloadFile(path, func)
	if not hasContent(path) then
		--[[ bedwars.lua only exists in the GitLab repo (kept separate/obfuscated there), at that
		repo's ROOT even though it caches locally under games/; everything else lives in the
		GitHub repo. ]]
		local relPath = select(1, path:gsub('pistonware/', ''))
		local isBedwars = relPath == 'games/bedwars.lua'
		--[[ The request is retried because raw file hosts can intermittently return an empty body that
		would otherwise get cached as a corrupt/empty file. ]]
		local content
		for attempt = 1, 4 do
			local suc, res = pcall(function()
				if isBedwars then
					return game:HttpGet('https://gitlab.com/pistonware/pistonware/-/raw/main/bedwars.lua', true)
				end
				return game:HttpGet('https://raw.githubusercontent.com/themagicpiston/pistonware/main/'..relPath, true)
			end)
			if suc and res and res ~= '' and res ~= '404: Not Found' then
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
		if path:find('.lua') then
			content = '--This watermark is used to delete the file if its cached, remove it to make the file persist after vape updates.\n'..content
		end
		writefile(path, content)
	end
	return (func or readfile)(path)
end

for _, folder in {'pistonware', 'pistonware/games', 'pistonware/profiles', 'pistonware/assets', 'pistonware/libraries', 'pistonware/guis'} do
	if not isfolder(folder) then
		makefolder(folder)
	end
end

--[[ catvape profile system credit to maxlasertech ]]
pcall(function()
	if #listfiles('pistonware/profiles') < 3 then
		local reqSuc, res = pcall(function()
			return game:HttpGet('https://api.github.com/repos/themagicpiston/pistonware/contents/profiles', true)
		end)
		if reqSuc and res and res ~= '404: Not Found' then
			local bodySuc, body = pcall(function()
				return cloneref(game:GetService('HttpService')):JSONDecode(res)
			end)
			if bodySuc and body and typeof(body) == 'table' then
				local total, completed = 0, 0
				for _, v in body do
					if v.type == 'file' then
						total += 1
						task.spawn(function()
							pcall(downloadFile, 'pistonware/'.. ({v.path:gsub(' ', '%%20')})[1])
							completed += 1
						end)
					end
				end
				--[[ Joined on the counter with a deadline, matching loader.lua and main.lua. The
				BindableEvent this replaces had no timeout, so a worker that died before
				firing parked the boot for the rest of the session. ]]
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
