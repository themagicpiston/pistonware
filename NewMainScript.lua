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

-- Shows a self-built Yes/No prompt and blocks until answered or `duration` seconds pass.
-- (Not StarterGui:SetCore's Button1/Button2/Callback -- some executors render the buttons
-- but never actually invoke the Callback, silently hanging until the timeout.)
-- Returns true (Yes), false (No), or nil (dismissed/timed out with no response).
local function askYesNo(title, text, duration)
	local settled, result = false, nil
	local done = Instance.new('BindableEvent')

	local suc = pcall(function()
		local gui = Instance.new('ScreenGui')
		gui.Name = 'PistonwarePrompt'
		gui.ResetOnSpawn = false
		gui.DisplayOrder = 999
		gui.Parent = cloneref(game:GetService('CoreGui'))

		local frame = Instance.new('Frame')
		frame.Size = UDim2.new(0, 300, 0, 120)
		frame.Position = UDim2.new(1, -320, 1, -150)
		frame.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
		frame.BorderSizePixel = 0
		frame.Parent = gui

		local corner = Instance.new('UICorner')
		corner.CornerRadius = UDim.new(0, 6)
		corner.Parent = frame

		local titleLabel = Instance.new('TextLabel')
		titleLabel.Size = UDim2.new(1, -16, 0, 24)
		titleLabel.Position = UDim2.new(0, 8, 0, 6)
		titleLabel.BackgroundTransparency = 1
		titleLabel.Font = Enum.Font.SourceSansBold
		titleLabel.TextSize = 18
		titleLabel.TextColor3 = Color3.new(1, 1, 1)
		titleLabel.TextXAlignment = Enum.TextXAlignment.Left
		titleLabel.Text = title
		titleLabel.Parent = frame

		local textLabel = Instance.new('TextLabel')
		textLabel.Size = UDim2.new(1, -16, 0, 44)
		textLabel.Position = UDim2.new(0, 8, 0, 32)
		textLabel.BackgroundTransparency = 1
		textLabel.Font = Enum.Font.SourceSans
		textLabel.TextWrapped = true
		textLabel.TextSize = 15
		textLabel.TextColor3 = Color3.fromRGB(220, 220, 220)
		textLabel.TextXAlignment = Enum.TextXAlignment.Left
		textLabel.TextYAlignment = Enum.TextYAlignment.Top
		textLabel.Text = text
		textLabel.Parent = frame

		local function finish(value)
			if settled then return end
			settled = true
			result = value
			gui:Destroy()
			done:Fire()
		end

		local yesButton = Instance.new('TextButton')
		yesButton.Size = UDim2.new(0, 138, 0, 30)
		yesButton.Position = UDim2.new(0, 8, 1, -36)
		yesButton.BackgroundColor3 = Color3.fromRGB(60, 150, 80)
		yesButton.TextColor3 = Color3.new(1, 1, 1)
		yesButton.Font = Enum.Font.SourceSansBold
		yesButton.TextSize = 16
		yesButton.Text = 'Yes'
		yesButton.Parent = frame
		yesButton.MouseButton1Click:Connect(function()
			finish(true)
		end)

		local noButton = Instance.new('TextButton')
		noButton.Size = UDim2.new(0, 138, 0, 30)
		noButton.Position = UDim2.new(1, -146, 1, -36)
		noButton.BackgroundColor3 = Color3.fromRGB(150, 60, 60)
		noButton.TextColor3 = Color3.new(1, 1, 1)
		noButton.Font = Enum.Font.SourceSansBold
		noButton.TextSize = 16
		noButton.Text = 'No'
		noButton.Parent = frame
		noButton.MouseButton1Click:Connect(function()
			finish(false)
		end)

		task.delay(duration, function()
			finish(nil)
		end)
	end)

	if not suc then
		done:Destroy()
		return nil
	end

	done.Event:Wait()
	done:Destroy()
	return result
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

-- catvape profile system credit to maxlasertech
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
