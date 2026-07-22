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

-- Small corner popup (bottom-right, like a notification) used for both first-run prompts
-- below. Built from raw Instances since this runs before the GUI framework exists.
-- buttonDefs is a list of {text, key, color}; returns the clicked button's key, or
-- `fallback` if the safety timeout elapses with nothing clicked.
local function createCornerPrompt(title, text, buttonDefs, timeoutSeconds, fallback)
	local guiParent = (gethui and gethui()) or cloneref(game:GetService('CoreGui'))
	local screen = Instance.new('ScreenGui')
	screen.Name = 'PistonwareCornerPrompt'
	screen.DisplayOrder = 999999999
	screen.IgnoreGuiInset = true
	screen.ResetOnSpawn = false
	pcall(function() screen.Parent = guiParent end)

	local frame = Instance.new('Frame')
	frame.AnchorPoint = Vector2.new(1, 1)
	frame.Position = UDim2.new(1, -20, 1, -20)
	frame.Size = UDim2.fromOffset(300, 128)
	frame.BackgroundColor3 = Color3.fromRGB(26, 25, 26)
	frame.BorderSizePixel = 0
	frame.Parent = screen
	local frameCorner = Instance.new('UICorner')
	frameCorner.CornerRadius = UDim.new(0, 8)
	frameCorner.Parent = frame

	-- Scale the panel with the viewport so it stays readable on both phones and PC.
	local cam = workspace.CurrentCamera
	if cam then
		local uiscale = Instance.new('UIScale')
		uiscale.Scale = math.clamp(cam.ViewportSize.X / 1000, 0.75, 1.25)
		uiscale.Parent = frame
	end

	local titlelabel = Instance.new('TextLabel')
	titlelabel.BackgroundTransparency = 1
	titlelabel.Position = UDim2.fromOffset(14, 10)
	titlelabel.Size = UDim2.new(1, -28, 0, 18)
	titlelabel.Text = title
	titlelabel.TextColor3 = Color3.fromRGB(230, 230, 230)
	titlelabel.TextSize = 16
	titlelabel.TextXAlignment = Enum.TextXAlignment.Left
	titlelabel.Font = Enum.Font.GothamBold
	titlelabel.Parent = frame

	local textlabel = Instance.new('TextLabel')
	textlabel.BackgroundTransparency = 1
	textlabel.Position = UDim2.fromOffset(14, 30)
	textlabel.Size = UDim2.new(1, -28, 0, 54)
	textlabel.Text = text
	textlabel.TextColor3 = Color3.fromRGB(200, 200, 200)
	textlabel.TextSize = 14
	textlabel.TextWrapped = true
	textlabel.TextXAlignment = Enum.TextXAlignment.Left
	textlabel.TextYAlignment = Enum.TextYAlignment.Top
	textlabel.Font = Enum.Font.Gotham
	textlabel.Parent = frame

	local choice
	local count = #buttonDefs
	for idx, def in buttonDefs do
		local width = 1 / count
		local btn = Instance.new('TextButton')
		btn.AnchorPoint = Vector2.new(0, 1)
		btn.Position = UDim2.new(width * (idx - 1), idx == 1 and 14 or 4, 1, -12)
		btn.Size = UDim2.new(width, (idx == 1 or idx == count) and -18 or -8, 0, 30)
		btn.BackgroundColor3 = def.color
		btn.BorderSizePixel = 0
		btn.AutoButtonColor = true
		-- Frees the touch cursor so the button is tappable on phones (where input would
		-- otherwise be locked to the game).
		btn.Modal = true
		btn.Text = def.text
		btn.TextColor3 = Color3.new(1, 1, 1)
		btn.TextSize = 15
		btn.Font = Enum.Font.GothamBold
		btn.Parent = frame
		local c = Instance.new('UICorner')
		c.CornerRadius = UDim.new(0, 6)
		c.Parent = btn
		btn.MouseButton1Click:Connect(function()
			choice = def.key
		end)
	end

	-- Block the loader until a choice is made, with a safety timeout so a missed click can
	-- never hang injection forever.
	local timeout = os.clock() + (timeoutSeconds or 60)
	repeat task.wait() until choice ~= nil or os.clock() > timeout
	pcall(function() screen:Destroy() end)
	if choice == nil then
		return fallback
	end
	return choice
end

local function promptDownloadConfigs()
	return createCornerPrompt(
		'Pistonware',
		'Would you like to download the default configs (Blatant/Legit)?',
		{
			{text = 'Yes', key = true, color = Color3.fromRGB(45, 150, 90)},
			{text = 'No', key = false, color = Color3.fromRGB(150, 45, 45)},
		},
		60, true
	)
end

-- Lets the user pick which shipped config (Blatant / Legit) loads by default. Returns
-- 'blatant' or 'legit' -- matching the profile file name prefixes (e.g.
-- blatant<PlaceId>.txt) so the GUI's Load can find the file.
local function chooseDefaultConfig()
	return createCornerPrompt(
		'Pistonware',
		'Which config would you like to load by default?',
		{
			{text = 'Blatant', key = 'blatant', color = Color3.fromRGB(200, 45, 45)},
			{text = 'Legit', key = 'legit', color = Color3.fromRGB(45, 120, 205)},
		},
		120, 'blatant'
	)
end

-- Fetches the GitHub profiles folder listing; returns the decoded {name=,path=,type=} array, or nil on failure.
-- Pass a commit sha as `ref` to get the listing exactly as of that commit instead of branch head.
local function fetchProfilesListing(ref)
	local reqSuc, res = pcall(function()
		return game:HttpGet('https://api.github.com/repos/themagicpiston/pistonware/contents/profiles'..(ref and ('?ref='..ref) or ''), true)
	end)
	if not (reqSuc and res and res ~= '404: Not Found') then return nil end
	local bodySuc, body = pcall(function()
		return cloneref(game:GetService('HttpService')):JSONDecode(res)
	end)
	if not (bodySuc and body and typeof(body) == 'table') then return nil end
	return body
end

-- Downloads every file in a profiles listing concurrently. When `commit` is given, files are
-- fetched pinned to that exact commit sha and overwritten unconditionally -- branch-path raw
-- URLs can serve CDN-cached content for up to ~5 minutes after a push, which would make a
-- "sync" quietly reinstall the old profiles.
local function downloadProfilesListing(body, commit)
	local pending = 0
	local done = Instance.new('BindableEvent')
	for _, v in body do
		if v.type == 'file' then
			pending += 1
			local relPath = ({v.path:gsub(' ', '%%20')})[1]
			task.spawn(function()
				if commit then
					pcall(function()
						for attempt = 1, 4 do
							local suc, res = pcall(function()
								return game:HttpGet('https://raw.githubusercontent.com/themagicpiston/pistonware/'..commit..'/'..relPath, true)
							end)
							if suc and res and res ~= '' and res ~= '404: Not Found' then
								writefile('pistonware/'..relPath, res)
								break
							end
							if attempt < 4 then
								task.wait(attempt)
							end
						end
					end)
				else
					pcall(downloadFile, 'pistonware/'..relPath)
				end
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

-- Returns the sha of the most recent commit that touched profiles/ on GitHub, or nil on failure.
local function fetchProfilesCommit()
	local reqSuc, res = pcall(function()
		return game:HttpGet('https://api.github.com/repos/themagicpiston/pistonware/commits?path=profiles&sha=main&per_page=1', true)
	end)
	if not (reqSuc and res and res ~= '404: Not Found') then return nil end
	local bodySuc, body = pcall(function()
		return cloneref(game:GetService('HttpService')):JSONDecode(res)
	end)
	if not (bodySuc and body and typeof(body) == 'table' and body[1] and body[1].sha) then return nil end
	return body[1].sha
end

-- Detect the very first run (empty/near-empty profiles folder) BEFORE downloading, so we
-- know afterwards whether to show the prompts below.
local firstRunProfiles = false
pcall(function()
	firstRunProfiles = #listfiles('pistonware/profiles') < 3
end)

-- profilecheck.txt persists a prior 'No' answer, so the download prompt only asks once --
-- without it, a user who declines would get nagged again on every reinject (the profiles
-- folder stays under 3 files forever if nothing gets downloaded).
local declinedDownload = false
pcall(function()
	if isfile('pistonware/profiles/profilecheck.txt') then
		declinedDownload = readfile('pistonware/profiles/profilecheck.txt') == 'false'
	end
end)

local wantsDownload = true
if firstRunProfiles and not declinedDownload then
	local ok, res = pcall(promptDownloadConfigs)
	wantsDownload = ok and res == true
	if not wantsDownload then
		pcall(function() writefile('pistonware/profiles/profilecheck.txt', 'false') end)
	end
end

local downloadedConfigs = false
if firstRunProfiles and not declinedDownload and wantsDownload then
	pcall(function()
		local body = fetchProfilesListing()
		if body then
			downloadProfilesListing(body)
		end
	end)
	pcall(function()
		downloadedConfigs = #listfiles('pistonware/profiles') >= 3
	end)
	-- Record which commit this download reflects, so later sessions can tell whether
	-- profiles/ has changed on GitHub since (see the sync prompt below).
	if downloadedConfigs then
		pcall(function()
			local commit = fetchProfilesCommit()
			if commit then
				writefile('pistonware/profiles/profilecommit.txt', commit)
			end
		end)
	end
end

-- Existing installs (3+ profiles): if profiles/ has changed on GitHub since the last
-- download/sync, offer to overwrite the shipped configs with the latest ones. Only the
-- files that exist in the GitHub profiles folder are deleted/redownloaded -- profiles the
-- user made themselves are left alone. Skipped on reinjects/teleports (shared.vapereload)
-- so it only ever asks once per session, on the first manual execution.
if not firstRunProfiles and not declinedDownload and not shared.vapereload then
	pcall(function()
		local latestCommit = fetchProfilesCommit()
		local cachedCommit = isfile('pistonware/profiles/profilecommit.txt') and readfile('pistonware/profiles/profilecommit.txt'):gsub('%s', '') or nil
		if latestCommit and latestCommit ~= cachedCommit then
			local wantsSync = createCornerPrompt(
				'Pistonware',
				'Would you like to sync to the latest config?',
				{
					{text = 'Yes', key = true, color = Color3.fromRGB(45, 150, 90)},
					{text = 'No', key = false, color = Color3.fromRGB(150, 45, 45)},
				},
				60, false
			)
			if wantsSync == true then
				-- If a previous instance is still injected, uninject it BEFORE overwriting:
				-- Uninject() saves the old in-memory config to disk as its first step, and
				-- main.lua would otherwise trigger it right after us -- clobbering the
				-- freshly synced profiles with the old settings. Same for its autosave loop.
				if shared.vape then
					pcall(function() shared.vape:Uninject() end)
					shared.vape = nil
				end
				-- Listing and file contents both pinned to latestCommit so a sync right after
				-- a push can't grab a stale CDN copy of the branch head.
				local body = fetchProfilesListing(latestCommit)
				if body then
					downloadProfilesListing(body, latestCommit)
					writefile('pistonware/profiles/profilecommit.txt', latestCommit)
				end
			end
			-- On "No"/timeout the stored commit stays stale, so the prompt returns next
			-- session until the user agrees to sync once.
		end
	end)
end

-- After the shipped configs finish downloading, ask which one should load by default and
-- hand it to the GUI via shared.VapeCustomProfile. main.lua's finishLoading passes this
-- straight into vape:Load as the profile to load, replacing the 'default' profile.
if downloadedConfigs then
	local ok, choice = pcall(chooseDefaultConfig)
	if ok and type(choice) == 'string' then
		shared.VapeCustomProfile = choice
	end
end

return loadstring(downloadFile('pistonware/main.lua'), 'main')()
