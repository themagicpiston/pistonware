local vape = shared.vape
local loadstring = function(...)
	local res, err = loadstring(...)
	if err and vape then 
		vape:CreateNotification('Vape', 'Failed to load : '..err, 30, 'alert') 
	end
	return res
end
local isfile = isfile or function(file)
	local suc, res = pcall(function() 
		return readfile(file) 
	end)
	return suc and res ~= nil and res ~= ''
end
vape.Place = 6872274481
-- 8560631822 is the same BedWars game under a different PlaceId. The real
-- setup (shared.bedwars, services, vape libs) lives in 6872274481.lua, which
-- loads bedwars.lua itself once that's done -- loading bedwars.lua directly
-- from here skips that setup and shared.bedwars is nil when it runs.
local gamePath = 'pistonware/games/6872274481.lua'
local cached = isfile(gamePath) and readfile(gamePath) or nil
if cached and cached:gsub('%s', '') ~= '' then
	loadstring(cached, '6872274481')()
elseif not shared.PistonwareDeveloper then
	-- Fetched from GitHub, not Codeberg: only games/bedwars.lua still lives on Codeberg,
	-- and its stale copy of this file was being downloaded twice (once to probe for
	-- existence, then again to save it).
	local content
	for attempt = 1, 4 do
		local suc, res = pcall(function()
			return game:HttpGet('https://raw.githubusercontent.com/themagicpiston/pistonware/main/games/6872274481.lua', true)
		end)
		if suc and res and res ~= '' and res ~= '404: Not Found' then
			content = res
			break
		end
		if attempt < 4 then
			task.wait(attempt)
		end
	end
	if content then
		pcall(writefile, gamePath, '--This watermark is used to delete the file if its cached, remove it to make the file persist after vape updates.\n'..content)
		loadstring(content, '6872274481')()
	end
end
