--This watermark is used to delete the file if its cached, remove it to make the file persist after vape updates.
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
		-- games/bedwars.lua only exists in the Codeberg repo (kept private/obfuscated there);
		-- everything else now lives in the GitHub repo.
		local relPath = select(1, path:gsub('pistonware/', ''))
		local isBedwars = relPath == 'games/bedwars.lua'
		-- Retried a few times: raw file hosts intermittently 504 (~5% observed on Codeberg's),
		-- returning an empty body that would otherwise get cached as a corrupt/empty file.
		local content
		for attempt = 1, 4 do
			local suc, res = pcall(function()
				if isBedwars then
					return game:HttpGet('https://codeberg.org/pistonware/pistonware/raw/branch/main/games/bedwars.lua', true)
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

-- Standalone progress label for the prefetch phase, since it runs before the GUI framework
-- (and its own downloader label) exists yet.
local downloaderGui, downloaderLabel
local function updateDownloader(text)
	if not downloaderGui then
		downloaderGui = Instance.new('ScreenGui')
		downloaderGui.Name = 'PistonwareDownloader'
		downloaderGui.ResetOnSpawn = false
		downloaderGui.Parent = cloneref(game:GetService('CoreGui'))
		downloaderLabel = Instance.new('TextLabel')
		downloaderLabel.Size = UDim2.new(1, 0, 0, 40)
		downloaderLabel.BackgroundTransparency = 1
		downloaderLabel.TextStrokeTransparency = 0
		downloaderLabel.TextSize = 20
		downloaderLabel.TextColor3 = Color3.new(1, 1, 1)
		downloaderLabel.Parent = downloaderGui
	end
	downloaderLabel.Text = text
end
local function destroyDownloader()
	if downloaderGui then
		downloaderGui:Destroy()
		downloaderGui, downloaderLabel = nil, nil
	end
end

-- Downloads every file in a repo folder concurrently instead of one HttpGet per getcustomasset call,
-- so GUI construction reads already-cached files instead of blocking on ~190 sequential round trips.
local function prefetchFolder(folder)
	local reqSuc, res = pcall(function()
		return game:HttpGet('https://api.github.com/repos/themagicpiston/pistonware/contents/'..folder, true)
	end)
	if not (reqSuc and res and res ~= '404: Not Found') then return end
	local bodySuc, body = pcall(function()
		return cloneref(game:GetService('HttpService')):JSONDecode(res)
	end)
	if not (bodySuc and body and typeof(body) == 'table') then return end

	local toFetch = {}
	for _, v in body do
		if v.type == 'file' and not isfile('pistonware/'..folder..'/'..v.name) then
			table.insert(toFetch, v.name)
		end
	end
	if #toFetch <= 0 then return end

	local completed, total = 0, #toFetch
	local done = Instance.new('BindableEvent')
	updateDownloader('Downloading '..folder..' ('..completed..'/'..total..')')
	for _, name in toFetch do
		task.spawn(function()
			pcall(downloadFile, 'pistonware/'..folder..'/'..name)
			completed += 1
			updateDownloader('Downloading '..folder..' ('..completed..'/'..total..')')
			if completed >= total then
				done:Fire()
			end
		end)
	end
	done.Event:Wait()
	done:Destroy()
end

local function finishLoading()
	vape.Init = nil
	-- shared.VapeCustomProfile is a ONE-SHOT hint for the load that immediately follows
	-- (set by the loader's first-run config chooser, or by the teleport handler below).
	-- Capture and clear it up front: getgenv()/shared persists across a reinject, so a
	-- value left over from an earlier teleport would keep forcing that old profile and
	-- override the config you actually switched to -- that stale value was the reinject
	-- 'loads the wrong config' bug. Cleared here, a plain reinject always falls through to
	-- the profile saved in gui.txt (i.e. whatever you last switched to).
	local customProfile = shared.VapeCustomProfile
	shared.VapeCustomProfile = nil
	if customProfile == '' then customProfile = nil end
	vape:Load(nil, customProfile)
	-- Persist the applied profile to gui.txt right away so a reinject before the first
	-- autosave tick still comes back to the same config.
	if customProfile then
		pcall(function() vape:Save() end)
	end
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
					loadstring(game:HttpGet('https://raw.githubusercontent.com/themagicpiston/pistonware/main/loader.lua', true), 'loader')()
				end
			]]
			if shared.PistonwareDeveloper then
				teleportScript = 'shared.PistonwareDeveloper = true\n'..teleportScript
			end
			if shared.VapeSmoothBoot then
				teleportScript = 'shared.VapeSmoothBoot = true\n'..teleportScript
			end
			teleportScript = 'shared.VapeCustomProfile = "'..(vape.Profile or shared.VapeCustomProfile or 'default')..'"\n'..teleportScript
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
	pcall(prefetchFolder, 'assets/'..gui)
	if gui ~= 'new' then
		pcall(prefetchFolder, 'assets/new')
	end
	destroyDownloader()
	vape = loadstring(downloadFile('pistonware/guis/'..gui..'.lua'), 'gui')()
	shared.vape = vape

if not shared.VapeIndependent then
	-- downloading doesn't need the game loaded; only wait here, right before touching game/character state
	if not game:IsLoaded() then
		repeat task.wait() until game:IsLoaded()
		task.wait(identifyexecutor() == 'Opiumware' and 30 or 5)
	end
	loadstring(downloadFile('pistonware/games/universal.lua'), 'universal')()
	if isfile('pistonware/games/'..game.PlaceId..'.lua') then
		loadstring(readfile('pistonware/games/'..game.PlaceId..'.lua'), tostring(game.PlaceId))(...)
	else
		if not shared.PistonwareDeveloper then
			local suc, res = pcall(function()
				return game:HttpGet('https://raw.githubusercontent.com/themagicpiston/pistonware/main/games/'..game.PlaceId..'.lua', true)
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
