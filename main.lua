--This watermark is used to delete the file if its cached, remove it to make the file persist after vape updates.
repeat task.wait() until game:IsLoaded()
if shared.vape then shared.vape:Uninject() end

local vape
local loadstring = function(...)
	local res, err = loadstring(...)
	if err and vape then
		vape:CreateNotification('Vape', 'Failed to load : '..err, 30, 'alert')
	end
	return res
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

local function downloadFile(path, func)
	if not isfile(path) then
		local suc, res = pcall(function()
			return game:HttpGet('https://codeberg.org/pistonware/pistonware/raw/branch/main/'..select(1, path:gsub('pistonware/', '')), true)
		end)
		if not suc or res == '404: Not Found' then
			error(res)
		end
		if path:find('.lua') then
			res = '--This watermark is used to delete the file if its cached, remove it to make the file persist after vape updates.\n'..res
		end
		writefile(path, res)
	end
	return (func or readfile)(path)
end

local function finishLoading()
	vape.Init = nil
	vape:Load(nil, shared.VapeCustomProfile)
	task.spawn(function()
		while vape.Loaded do
			vape:Save()
			for _ = 1, 10 do
				task.wait(1)
				if not vape.Loaded then break end
			end
		end
	end)

	local teleportedServers
	vape:Clean(playersService.LocalPlayer.OnTeleport:Connect(function()
		if (not teleportedServers) and (not shared.VapeIndependent) then
			teleportedServers = true
			local teleportScript = [[
				shared.vapereload = true
				if shared.PistonwareDeveloper then
					loadstring(readfile('pistonware/loader.lua'), 'loader')()
				else
					loadstring(game:HttpGet('https://codeberg.org/pistonware/pistonware/raw/branch/main/loader.lua', true), 'loader')()
				end
			]]
			if shared.PistonwareDeveloper then
				teleportScript = 'shared.PistonwareDeveloper = true\n'..teleportScript
			end
			if shared.VapeSmoothBoot then
				teleportScript = 'shared.VapeSmoothBoot = true\n'..teleportScript
			end
			teleportScript = 'shared.VapeCustomProfile = "'..(shared.VapeCustomProfile or vape.Profile)..'"\n'..teleportScript
			vape:Save()
			if not hasQueueOnTeleport then
				vape:CreateNotification('Vape', 'queue_on_teleport is not supported by your executor -- Vape will not re-inject automatically after this teleport (e.g. queueing into a match). You will need to re-run your loadstring manually.', 15, 'alert')
			end
			queue_on_teleport(teleportScript)
		end
	end))

	if shared.PistonwareSyncResult then
		vape:CreateNotification('Vape', shared.PistonwareSyncResult, 15, shared.PistonwareSyncResult:find('failed') and 'alert' or nil)
		shared.PistonwareSyncResult = nil
	end

	if not shared.vapereload then
		if not vape.Categories then return end
		if vape.Categories.Main.Options['GUI bind indicator'].Enabled then
			vape:CreateNotification('Finished Loading', vape.VapeButton and 'Press the button in the top right to open GUI' or 'Press '..table.concat(vape.Keybind, ' + '):upper()..' to open GUI', 5)
		end
	end
end

	if not isfile('pistonware/profiles/gui.txt') then
		writefile('pistonware/profiles/gui.txt', 'new')
	end
	local gui = readfile('pistonware/profiles/gui.txt')

	if not isfolder('pistonware/assets/'..gui) then
		makefolder('pistonware/assets/'..gui)
	end
	vape = loadstring(downloadFile('pistonware/guis/'..gui..'.lua'), 'gui')()
	shared.vape = vape

if not shared.VapeIndependent then
	loadstring(downloadFile('pistonware/games/universal.lua'), 'universal')()
	if isfile('pistonware/games/'..game.PlaceId..'.lua') then
		loadstring(readfile('pistonware/games/'..game.PlaceId..'.lua'), tostring(game.PlaceId))(...)
	else
		if not shared.PistonwareDeveloper then
			local suc, res = pcall(function()
				return game:HttpGet('https://codeberg.org/pistonware/pistonware/raw/branch/main/games/'..game.PlaceId..'.lua', true)
			end)
			if suc and res ~= '404: Not Found' then
				loadstring(downloadFile('pistonware/games/'..game.PlaceId..'.lua'), tostring(game.PlaceId))(...)
			end
		end
	end
	finishLoading()
else
	vape.Init = finishLoading
	return vape
end
