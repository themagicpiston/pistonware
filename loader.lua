local isfile = isfile or function(file)
	local suc, res = pcall(function()
		return readfile(file)
	end)
	return suc and res ~= nil and res ~= ''
end
local cloneref = cloneref or function(ref)
	return ref
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

-- First-run only: a clickable prompt letting the user pick which shipped config
-- (Blatant / Legit) loads by default. Built from raw Instances since this runs before
-- the GUI framework exists. Returns 'blatant' or 'legit' -- matching the profile file
-- name prefixes (e.g. blatant<PlaceId>.txt) so the GUI's Load can find the file.
local function chooseDefaultConfig()
	local guiParent = (gethui and gethui()) or cloneref(game:GetService('CoreGui'))
	local screen = Instance.new('ScreenGui')
	screen.Name = 'PistonwareConfigChooser'
	screen.DisplayOrder = 999999999
	screen.IgnoreGuiInset = true
	screen.ResetOnSpawn = false
	pcall(function() screen.Parent = guiParent end)

	-- Dimmed full-screen backdrop. Modal=true frees the touch cursor so the buttons are
	-- tappable on phones (where input would otherwise be locked to the game).
	local overlay = Instance.new('TextButton')
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.BackgroundColor3 = Color3.new(0, 0, 0)
	overlay.BackgroundTransparency = 0.5
	overlay.BorderSizePixel = 0
	overlay.AutoButtonColor = false
	overlay.Modal = true
	overlay.Text = ''
	overlay.Parent = screen

	local frame = Instance.new('Frame')
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.5)
	frame.Size = UDim2.fromOffset(380, 190)
	frame.BackgroundColor3 = Color3.fromRGB(26, 25, 26)
	frame.BorderSizePixel = 0
	frame.Parent = screen
	local frameCorner = Instance.new('UICorner')
	frameCorner.CornerRadius = UDim.new(0, 8)
	frameCorner.Parent = frame

	-- Scale the panel with the viewport so it stays readable and fully on-screen on both
	-- phones (narrow) and PC (wide).
	local cam = workspace.CurrentCamera
	if cam then
		local uiscale = Instance.new('UIScale')
		uiscale.Scale = math.clamp(cam.ViewportSize.X / 900, 0.65, 1.35)
		uiscale.Parent = frame
	end

	local title = Instance.new('TextLabel')
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(16, 16)
	title.Size = UDim2.new(1, -32, 0, 82)
	title.Text = 'Which config would you like to load by default?'
	title.TextColor3 = Color3.fromRGB(230, 230, 230)
	title.TextSize = 20
	title.TextWrapped = true
	title.Font = Enum.Font.GothamMedium
	title.Parent = frame

	local choice
	local function makeButton(text, centerScale, col)
		local btn = Instance.new('TextButton')
		btn.AnchorPoint = Vector2.new(0.5, 1)
		btn.Position = UDim2.new(centerScale, 0, 1, -16)
		btn.Size = UDim2.new(0.5, -22, 0, 56)
		btn.BackgroundColor3 = col
		btn.BorderSizePixel = 0
		btn.AutoButtonColor = true
		btn.Text = text
		btn.TextColor3 = Color3.new(1, 1, 1)
		btn.TextSize = 20
		btn.Font = Enum.Font.GothamBold
		btn.Parent = frame
		local c = Instance.new('UICorner')
		c.CornerRadius = UDim.new(0, 6)
		c.Parent = btn
		btn.MouseButton1Click:Connect(function()
			choice = text:lower()
		end)
	end
	makeButton('Blatant', 0.25, Color3.fromRGB(200, 45, 45))
	makeButton('Legit', 0.75, Color3.fromRGB(45, 120, 205))

	-- Block the loader until a choice is made, with a safety timeout so a missed click can
	-- never hang injection forever (falls back to Blatant).
	local timeout = os.clock() + 120
	repeat task.wait() until choice or os.clock() > timeout
	pcall(function() screen:Destroy() end)
	return choice or 'blatant'
end

-- Detect the very first run (empty/near-empty profiles folder) BEFORE downloading, so we
-- know afterwards whether to show the default-config chooser.
local firstRunProfiles = false
pcall(function()
	firstRunProfiles = #listfiles('pistonware/profiles') < 3
end)

pcall(function()
	if firstRunProfiles then
		local reqSuc, res = pcall(function()
			return game:HttpGet('https://api.github.com/repos/themagicpiston/pistonware/contents/profiles', true)
		end)
		if reqSuc and res and res ~= '404: Not Found' then
			local bodySuc, body = pcall(function()
				return cloneref(game:GetService('HttpService')):JSONDecode(res)
			end)
			if bodySuc and body and typeof(body) == 'table' then
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
		end
	end
end)

-- After the shipped configs finish downloading on first run, ask which one should load by
-- default and hand it to the GUI via shared.VapeCustomProfile. main.lua's finishLoading
-- passes this straight into vape:Load as the profile to load, replacing the 'default'
-- profile. Only prompt if the configs actually downloaded (otherwise there's nothing to
-- pick between).
if firstRunProfiles then
	local haveConfigs = false
	pcall(function()
		haveConfigs = #listfiles('pistonware/profiles') >= 3
	end)
	if haveConfigs then
		local ok, choice = pcall(chooseDefaultConfig)
		if ok and type(choice) == 'string' then
			shared.VapeCustomProfile = choice
		end
	end
end

return loadstring(downloadFile('pistonware/main.lua'), 'main')()
