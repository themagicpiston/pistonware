pcall(function()
	game:GetService('StarterGui'):SetCore('SendNotification', {
		Title = 'Pistonware',
		Text = 'Script is loading please be patient',
		Duration = 5
	})
end)
local isfile = isfile or function(file)
	local suc, res = pcall(function()
		return readfile(file)
	end)
	return suc and res ~= nil and res ~= ''
end
local delfile = delfile or function(file)
	writefile(file, '')
end
local cloneref = cloneref or function(ref)
	return ref
end

-- Shows a Yes/No Roblox notification and blocks until answered or `duration` seconds pass.
-- Returns true (Yes), false (No), or nil (dismissed/timed out with no response).
local function askYesNo(title, text, duration)
	local settled, result = false, nil
	local done = Instance.new('BindableEvent')
	local suc = pcall(function()
		game:GetService('StarterGui'):SetCore('SendNotification', {
			Title = title,
			Text = text,
			Duration = duration,
			Button1 = 'Yes',
			Button2 = 'No',
			Callback = function(input)
				if settled then return end
				settled = true
				result = input
				done:Fire()
			end
		})
	end)
	if not suc then
		done:Destroy()
		return nil
	end
	task.delay(duration, function()
		if settled then return end
		settled = true
		done:Fire()
	end)
	done.Event:Wait()
	done:Destroy()
	if result == 'Button1' then return true end
	if result == 'Button2' then return false end
	return nil
end

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

for _, folder in {'pistonware', 'pistonware/games', 'pistonware/profiles', 'pistonware/assets', 'pistonware/libraries', 'pistonware/guis'} do
	if not isfolder(folder) then
		makefolder(folder)
	end
end

-- Fetches the GitHub profiles folder listing; returns the decoded {name=,path=,type=} array, or nil on failure.
local function fetchProfilesListing()
	local reqSuc, res = pcall(function()
		return game:HttpGet('https://api.github.com/repos/themagicpiston/pistonware/contents/profiles', true)
	end)
	if not (reqSuc and res and res ~= '404: Not Found') then return nil end
	local bodySuc, body = pcall(function()
		return cloneref(game:GetService('HttpService')):JSONDecode(res)
	end)
	if not (bodySuc and body and typeof(body) == 'table') then return nil end
	return body
end

-- Downloads every file in a profiles listing (overwriting/creating local copies).
local function downloadProfilesListing(body)
	local pending = 0
	local done = Instance.new('BindableEvent')
	for _, v in body do
		if v.type == 'file' then
			pending += 1
			task.spawn(function()
				pcall(downloadFile, 'pistonware/'.. ({v.path:gsub(' ', '%%20')})[1])
				pending -= 1
				if pending <= 0 then
					done:Fire()
				end
			end)
		end
	end
	if pending > 0 then
		done.Event:Wait()
	end
	done:Destroy()
end

pcall(function()
	-- Only prompt once per session: shared.vapereload is set by the teleport/reinject
	-- path, so this is skipped on re-injects and only runs on the first execution.
	if shared.vapereload then return end

	local profileCheckPath = 'pistonware/profiles/profilecheck.txt'
	local profileCheck = isfile(profileCheckPath) and readfile(profileCheckPath):gsub('%s', '') or nil

	if not profileCheck then
		if #listfiles('pistonware/profiles') < 3 then
			local wantsDownload = askYesNo('Pistonware', 'Would you like to download the config?', 300)
			if wantsDownload == true then
				writefile(profileCheckPath, 'true')
				local body = fetchProfilesListing()
				if body then
					downloadProfilesListing(body)
				end
			elseif wantsDownload == false then
				writefile(profileCheckPath, 'false')
			end
			-- if there was no response (dismissed/timed out), leave profilecheck.txt unwritten so we ask again next session
		end
	elseif profileCheck == 'true' then
		local wantsSync = askYesNo('Pistonware', 'Would you like to sync to the latest config?', 300)
		if wantsSync == true then
			local body = fetchProfilesListing()
			if body then
				-- only touch files that actually exist in the GitHub profiles folder; anything else local is left alone
				for _, v in body do
					if v.type == 'file' then
						local localPath = 'pistonware/'..({v.path:gsub(' ', '%%20')})[1]
						if isfile(localPath) then
							delfile(localPath)
						end
					end
				end
				downloadProfilesListing(body)
			end
		end
	end
end)

return loadstring(downloadFile('pistonware/main.lua'), 'main')()
