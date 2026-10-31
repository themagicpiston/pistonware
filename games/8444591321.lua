local vape = shared.vape
local loadstring = function(...)
	local res, err = loadstring(...)
	if err and vape then
		vape:CreateNotification('Vape', 'Failed to load : '..err, 30, 'alert')
	end
	return res
end
--[[ A match file that could not be run is said as a failed boot. Returning nothing told main.lua the
game had loaded: it applied the profile to the universal modules alone and opened saving, and the
next save rewrote the BedWars profile without any of its BedWars modules. ]]
local function bootFailure(stage, err)
	return {
		PistonwareBootFailure = true,
		stage = stage,
		error = tostring(err)
	}
end
local function runChunk(source, name)
	local chunk = loadstring(source, name)
	if chunk then return chunk() end
	return bootFailure('game.compile', 'games/6872274481.lua did not compile')
end
local release = shared.PistonwareRelease
local cacheReady = type(release) ~= 'table' or release.cacheReady ~= false
local isfile = isfile or function(file)
	local suc, res = pcall(function()
		return readfile(file)
	end)
	return suc and res ~= nil and res ~= ''
end
vape.Place = 6872274481
--[[ 8444591321 is the same BedWars game under a different PlaceId. The real
setup (shared.bedwars, services, vape libs) lives in 6872274481.lua, which
loads bedwars.lua itself once that's done -- loading bedwars.lua directly
from here skips that setup and shared.bedwars is nil when it runs. ]]
local gamePath = 'pistonware/games/6872274481.lua'
--[[ Through the loader when it is there, as the other place files load theirs: the copy its update
pass refreshed this boot, the cache when that is current, GitHub otherwise, each compile-checked,
and on a repair boot the intact copy on disk when GitHub cannot be reached. Reading the cache only
when cacheReady said so passed over a good copy on every boot after an update or a repair. The
loader has already tried GitHub four times when it fails, so that is the answer. ]]
local loadSource = shared.PistonwareDevLoadSource
if type(loadSource) == 'function' then
	local loaded, source, chunk = pcall(loadSource, gamePath, '6872274481')
	if loaded and type(chunk) == 'function' then
		return chunk()
	end
	if loaded and type(source) == 'string' and source:gsub('%s', '') ~= '' then
		return runChunk(source, '6872274481')
	end
	return bootFailure('game.download', loaded and 'games/6872274481.lua was empty' or source)
end
local cached = cacheReady and isfile(gamePath) and readfile(gamePath) or nil
if cached and cached:gsub('%s', '') ~= '' then
	return runChunk(cached, '6872274481')
elseif not shared.PistonwareDeveloper then
	--[[ Fetched from GitHub: only bedwars.lua lives off-repo (on GitLab), and the old host's
	stale copy of this file was being downloaded twice (once to probe for existence, then
	again to save it). ]]
	local content
	for attempt = 1, 4 do
		local suc, res = pcall(function()
			local rawUrl = shared.PistonwareRawUrl
			return type(rawUrl) == 'function' and game:HttpGet(rawUrl('games/6872274481.lua'), true)
				or game:HttpGet('https://raw.githubusercontent.com/themagicpiston/pistonware/main/games/6872274481.lua', true)
		end)
		-- An error page sent as the body ('429: Too Many Requests') is not a file to cache over a good copy.
		if suc and type(res) == 'string' and res ~= '' and res ~= '404: Not Found' and not res:match('^%d%d%d: ') then
			content = res
			break
		end
		if attempt < 4 then
			task.wait(attempt)
		end
	end
	if content then
		pcall(writefile, gamePath, '--This watermark is used to delete the file if its cached, remove it to make the file persist after vape updates.\n'..content)
		return runChunk(content, '6872274481')
	end
end
return bootFailure('game.download', 'games/6872274481.lua could not be loaded for this place')
