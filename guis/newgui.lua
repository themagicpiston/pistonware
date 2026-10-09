local vape = {
	ActiveBinds = {},
	Categories = {},
	GUIColor = {
		Hue = 0.0556,
		Sat = 0.926,
		Value = 0.953
	},
	HeldKeybinds = {},
	Loaded = false,
	Libraries = {},
	Modules = {},
	--[[ Maintained on insert and remove so nothing has to WALK vape.Modules to size it.
	main.lua polls this while the payload is still registering, and iterating a table another
	thread is growing is the crash described on vape:Save. Reading a number is not. ]]
	ModuleCount = 0,
	--[[
		The same set of modules as vape.Modules, kept as a plain array, and the ONLY thing
		vape:Save is allowed to walk.

		pairs/next is a stateless protocol: it finds the current key's slot and returns the next
		one. If the table rehashes between two resumptions of the walking coroutine -- which is
		exactly what a module being registered does -- that slot no longer means what it meant,
		and the walk either skips entries or takes the VM down with it. That is the crash.

		A numeric `for i = 1, n` carries no such state. It reads t[1], t[2] ... t[n] and nothing
		about an append invalidates an index that was already valid, so a save that overlaps
		registration sees a prefix of the list instead of corrupting itself. Late arrivals are
		picked up by the next save; the alternative was a crash.
	]]
	ModuleOrder = {},
	Place = game.PlaceId,
	Profile = 'default',
	RainbowSliders = {},
	RainbowSliderIndices = {},
	--[[ Bumped by every vape:Load. Load yields now, so a second load can stop the older one
	while it is still walking instead of interleaving writes into the same modules. ]]
	LoadGeneration = 0,
	--[[ Modules past this index in ModuleOrder arrived after the last profile application. ]]
	LoadedCount = 0,
	-- Saving starts blocked and is opened by main.lua only after the complete module set and
	-- profile have both loaded successfully. A failed boot never reaches that transition.
	SaveBlocked = true,
	SaveEpoch = 0,
	Settings = {},
	SettingToggleNotifications = {},
	ThreadFix = setthreadidentity and true or false,
	ToggleNotifications = {},
	Version = '4.22',
	Windows = {}
}

local run = function(func)
	func()
end

local function addRainbowSlider(component)
	if vape.RainbowSliderIndices[component] then return end
	local index = #vape.RainbowSliders + 1
	vape.RainbowSliders[index] = component
	vape.RainbowSliderIndices[component] = index
end

local function removeRainbowSlider(component)
	local index = vape.RainbowSliderIndices[component]
	if not index then return end
	local lastIndex = #vape.RainbowSliders
	local moved = vape.RainbowSliders[lastIndex]
	vape.RainbowSliders[index] = moved
	vape.RainbowSliders[lastIndex] = nil
	vape.RainbowSliderIndices[component] = nil
	if moved and moved ~= component then
		vape.RainbowSliderIndices[moved] = index
	end
end

local function runChunk(source, name)
	local chunk = loadstring(source, name)
	return chunk and chunk()
end
local cloneref = cloneref or function(obj)
	return obj
end
local tweenService = cloneref(game:GetService('TweenService'))
local inputService = cloneref(game:GetService('UserInputService'))
local textService = cloneref(game:GetService('TextService'))
local guiService = cloneref(game:GetService('GuiService'))
local runService = cloneref(game:GetService('RunService'))
local httpService = cloneref(game:GetService('HttpService'))

local function pistonwareHttpGet(url, nocache, attempt)
	local adapter = shared.PistonwareDevHttpGet
	if type(adapter) == 'function' then
		return adapter(url, nocache, attempt)
	end
	return game:HttpGet(url, nocache)
end

local function pistonwareRequest(options)
	local adapter = shared.PistonwareDevRequest
	if type(adapter) == 'function' then
		return adapter(options)
	end
	return request(options)
end

--[[
	What this Roblox client can actually do.

	Mobile executors ship an older Roblox build than the desktop ones -- Delta is a repackaged
	client, not the live app -- and the rewritten GUI reaches for UI features that only exist on
	recent versions. Instance.new on a class the client does not have THROWS, and so does
	assigning a property it does not have. Both happen while the GUI is being built, outside any
	pcall, so one missing feature took the whole menu down rather than degrading.

	These probes run once, and their results stay constant for the session.
]]
local function classExists(className)
	local ok, obj = pcall(Instance.new, className)
	if ok and typeof(obj) == 'Instance' then
		obj:Destroy()
		return true
	end
	return false
end

local function propertyExists(className, property, value)
	local ok, obj = pcall(Instance.new, className)
	if not (ok and typeof(obj) == 'Instance') then return false end
	local set = pcall(function() obj[property] = value end)
	obj:Destroy()
	return set
end

local hasCornerRadii = propertyExists('UICorner', 'TopLeftRadius', UDim.new(0, 4))
local hasBorderOffset = propertyExists('UIStroke', 'BorderOffset', UDim.new(0, 1))

--[[
	TextLabel.ContentText strips rich-text markup from Text and is read-only, so support must be
	probed by reading it. Reading an unsupported property throws just like assigning one.

	This failure occurs only after a profile is applied. The Text GUI reads ContentText
	when it builds a module label, and it only builds labels for modules that are ENABLED -- so
	an install with no profile draws no labels and never touches it, while the first profile that
	switches modules on throws on the first label and takes the GUI down with it.

	The old GUI never used the property; it stripped the tags itself, which is what the fallback
	below does.
]]
local hasContentText = (function()
	local ok, obj = pcall(Instance.new, 'TextLabel')
	if not (ok and typeof(obj) == 'Instance') then return false end
	local readable = pcall(function() return obj.ContentText end)
	obj:Destroy()
	return readable
end)()

--[[
	This failure occurs only after a profile is loaded.

	Sliders set their Value directly when they are built and never call SetValue, so on a fresh
	install with no profile this code is unreachable. SetValue runs when a saved value is applied
	-- or when you drag the slider yourself. That is why enabling every module by hand is fine
	and applying a profile is not: toggling a module calls Toggle, loading one calls SetValue on
	every slider it saved.

	Two ways it went wrong there, and the guard used to be `if not math.isfinite(value)`:

	math.isfinite is a recent Luau builtin. The Luau VM in a repackaged mobile client predates
	it, so the guard itself is nil and calling it throws -- on the first slider in the profile,
	and there are dozens. The old GUI never used the function.

	And even on a current client, a profile that predates a slider (or was written by the old
	GUI, which stored these differently) hands over nil. math.isfinite(nil) does not return
	false, it throws 'number expected, got nil'.

	Plain arithmetic answers both, on every Luau version, for every input type.
]]
local function isFiniteNumber(value)
	if type(value) ~= 'number' then return false end
	if value ~= value then return false end
	return value > -math.huge and value < math.huge
end

local function removeTags(str)
	str = str:gsub('<br%s*/>', '\n')
	return (str:gsub('<[^<>]->', ''))
end

local function contentText(obj)
	if hasContentText then
		return obj.ContentText
	end
	return removeTags(obj.Text)
end

local gameCamera = workspace.CurrentCamera
local gui

--[[ Viewport in GUI units. The camera answers immediately; a ScreenGui's AbsoluteSize is (0, 0)
until it renders its first frame, so use the camera before falling back to the GUI size. ]]
local function viewportWidth()
	local camera = gameCamera or workspace.CurrentCamera
	local width = camera and camera.ViewportSize.X or 0
	if width <= 0 and gui then
		width = gui.AbsoluteSize.X
	end
	return width
end

--[[
	Which executor this is, asked once.

	identifyexecutor is missing on some executors and THROWS on others, so it goes behind a
	pcall and the answer is kept -- main.lua guards its own call the same way, for the same
	reason. Lower-cased because the name is a vendor string and nothing guarantees its casing
	from one build to the next.
]]
local executorName = ''
pcall(function()
	executorName = identifyexecutor and tostring(({identifyexecutor()})[1] or '') or ''
end)
executorName = executorName:lower()

--[[
	The Mac executors report TouchEnabled = true on a desktop.

	UserInputService.TouchEnabled is the only thing this GUI had to go on, and on Opiumware and
	MacSploit it answers yes on a Mac with no touchscreen anywhere near it. Everything keyed off
	it then treats the machine as a phone -- including the rescale, which is why a Mac user ends
	up with a menu shrunk for a handset on a full-size display.

	Kept as a separate question rather than replacing the touch check: TouchEnabled is still the
	right thing to ask about INPUT (a hold gesture, an on-screen button), and it is only the
	'this is a small screen' inference drawn from it that is wrong here.
]]
local isMacExecutor = executorName:find('opiumware') ~= nil or executorName:find('macsploit') ~= nil

local function isMobile()
	return inputService.TouchEnabled and not isMacExecutor
end

--[[ The old GUI's rescale, restored exactly: never below half size, never above 1:1.

The rewrite had math.max(width / 1920, 0.6) -- no upper bound at all. Phones report their
render resolution here, so a 2400-wide handset asked for a 1.25x menu on the smallest screen
in the lineup, and the window ran off the edge with no way to drag it back. ]]
local function autoScaleValue()
	--[[ Left at 1:1 on the Mac executors. Their displays are full size and their windows are
	narrower than 1920 as a matter of course, so the width rule alone shrinks a menu that has no
	reason to shrink. Auto rescale can still be turned off and the slider used, exactly as
	before; this only changes what AUTO means on a machine that was being misread as a phone. ]]
	if isMacExecutor then
		return 1
	end

	local width = viewportWidth()
	if width <= 0 then return 1 end
	return math.clamp(width / 1920, 0.4, 1)
end

local fontsize = Instance.new('GetTextBoundsParams')
fontsize.Width = math.huge
local notifications
local getvapeasset
local components
local clickgui
local scaledgui
local toolblur
local tooltip
local TextGUI
local layout, TABS
local scale = {Scale = 1}

local isfile = isfile or function(file)
	local success, data = pcall(function()
		return readfile(file)
	end)

	return success and data ~= nil and data ~= ''
end

--[[
	Applying a profile yields so the client stays responsive, but a yield costs a WHOLE FRAME no
	matter how little work came before it. Wall time is therefore roughly

		work * (1 + frame / budget)

	and the budget is the only term this controls. At the 0.0015 the call sites used to pass, a
	mobile client rendering at 30fps did 1.5ms of work and then waited 33ms, over and over: a
	multiplier of twenty-three. An apply whose real cost is a third of a second took eight,
	which is exactly the profile switch that feels broken.

	Ten milliseconds brings the multiplier to about four while keeping any single uninterrupted
	block to under a third of a mobile frame, so the responsiveness this was added for is intact.
]]
local buildclock = os.clock()
local yieldBudget = 0.01
local function yieldBuild(budget)
	if os.clock() - buildclock > (budget or yieldBudget) then
		task.wait()
		buildclock = os.clock()
	end
end

--[[
	A paced starter for modules switched on by a profile apply.

	task.spawn resumes its function inline, on the calling thread, until that function first
	yields -- so applying a profile used to run each module's whole setup synchronously inside
	the apply loop, sixty of them nose to tail with no yield reachable in between.

	task.defer fixes only half of that. It gets the setup out of the loop, but every deferred
	function then runs back to back in the same resumption cycle: the same unbroken block of
	work, moved rather than broken up.

	So they go through a queue that yields between them, and modules come online over a second
	or two instead of all in one instant.

	One drain thread at a time, and it exits when the queue empties, so nothing is left running
	between applies.
]]
local startQueue, recycledStartJobs = {}, {}
local startHead, startTail = 1, 0
local startThread
local function queueStart(name, callback)
	local job = table.remove(recycledStartJobs)
	job = job or {}
	job.Name, job.Start = name, callback
	startTail += 1
	startQueue[startTail] = job

	if startThread then
		return
	end

	startThread = task.spawn(function()
		while startHead <= startTail do
			-- Yield BEFORE the first job, not after it. task.spawn resumes this thread inline on
			-- the caller, so taking a job first would run one module synchronously inside the
			-- apply loop -- the exact thing being fixed, just once instead of sixty times.
			task.wait()
			local nextJob = startQueue[startHead]
			startQueue[startHead] = nil
			startHead += 1
			-- spawn, not a direct call: a module that errors on startup must not take the drain
			-- thread down with it and strand every module still queued behind it.
			local start = nextJob.Start
			nextJob.Start, nextJob.Name = nil, nil
			table.insert(recycledStartJobs, nextJob)
			task.spawn(start, true)
		end

		startHead, startTail = 1, 0
		startThread = nil
	end)
end

local function loadJson(path)
	local success, data = pcall(function()
		return httpService:JSONDecode(readfile(path))
	end)

	return success and type(data) == 'table' and data or nil
end

--[[
	Encode and write, reporting rather than throwing.

	writefile can fail for reasons that have nothing to do with the config -- a full disk, a
	sandboxed executor, a filesystem that rejects the profile name -- and JSONEncode throws on
	values it cannot represent (inf, NaN, a cycle) which a single misbehaving module Save can
	introduce. Both used to propagate out of vape:Save; in the autosave loop that error was
	swallowed and saving silently stopped working for the rest of the session.

	Encoding first also means a failure to encode never truncates the file that is already on
	disk: nothing is written unless there is something valid to write.
]]
local function writeJson(path, data)
	local success, encoded = pcall(httpService.JSONEncode, httpService, data)
	if not success then
		return false, encoded
	end

	local ok, err = pcall(writefile, path, encoded)
	return ok, err
end

--[[
	A profile name is a FILE PATH, not a label.

	Every load and save builds 'pistonware/profiles/'..Profile..Place..'.txt' out of it and hands
	that to the executor's filesystem. So whatever ends up in a profile name is what isfile,
	readfile and writefile are called with -- and the Profiles tab's name box accepted anything
	typed or pasted into it, including a 15KB exported profile. That name was then saved as the
	active profile, and the isfile call at the top of the next vape:Load took the whole client
	down. Once saved it recurred on every inject, because the crash happened before anything
	could write a corrected file back.

	Length and character set both matter: the length is what kills the filesystem call, and the
	character set is what stops a name from escaping the profiles folder or being rejected
	outright by the OS. Anything failing this is not repaired or truncated -- a truncated name
	silently points at a different profile's file.
]]
local function usableProfileName(name)
	return type(name) == 'string'
		and name ~= ''
		and #name <= 32
		and not name:find('[^%w_%- ]')
end

--[[
	Walk the modules without pairs.

	pairs/next is stateless: it locates the key it was handed and returns whatever sits after it.
	If the table rehashes between two resumptions of the walking coroutine -- which is precisely
	what registering a module does -- that lookup no longer means what it meant, and the walk
	either skips entries or takes the VM down with it. Not a catchable error; a client crash.

	This closure keeps its own integer cursor over the parallel array instead, so nothing that
	happens to the hash table can invalidate it. A module appended mid-walk is either seen or
	missed depending on where the cursor is, which is the correct trade: the next pass picks it
	up, and neither outcome is a crash.

	Every loop that can run while the payload is still registering uses this -- opening the GUI,
	the colour pass, the text list's update loop, the search box, saving. Yields the name first
	so `for name, module in` and `for _, module in` both read the same as they did over the hash.
]]
local function orderedModules(order)
	local index = 0
	order = order or {}

	return function()
		index += 1
		local module = order[index]
		if module then
			return module.Name, module
		end
		return nil
	end
end

local color = {}
local uipallet = {}
do
	function color.Dark(col, num)
		local h, s, v = col:ToHSV()
		return Color3.fromHSV(h, s, math.clamp(select(3, uipallet.Main:ToHSV()) > 0.5 and v + num or v - num, 0, 1))
	end

	function color.Light(col, num)
		local h, s, v = col:ToHSV()
		return Color3.fromHSV(h, s, math.clamp(select(3, uipallet.Main:ToHSV()) > 0.5 and v - num or v + num, 0, 1))
	end

	function vape:Color(h)
		local s = 0.74 + (0.26 * math.min(h / 0.045, 1))

		if h > 0.577 then
			s = 1 - (0.48 * math.min((h - 0.577) / 0.088, 1))
		end

		if h > 0.674 then
			s = 0.52 + (0.48 * math.min((h - 0.674) / 0.149, 1))
		end

		if h > 0.869 then
			s = 1 - (0.26 * math.min((h - 0.869) / 0.131, 1))
		end

		return h, s, 1
	end

	function vape:TextColor(h, s, v)
		if v >= 0.7 and (s < 0.6 or h > 0.04 and h < 0.56) then
			return Color3.new(0.19, 0.19, 0.19)
		end

		return Color3.new(1, 1, 1)
	end
end

--[[ Text measurement. GetTextBoundsAsync yields, and the menu measures the same few strings over
and over -- a module name every redraw of the overlay -- so answers are kept by face, size and
text. An Enum font is converted rather than ignored; nothing given means the menu's own face. ]]
local measureCache, measureCount = {}, 0
-- The generation before: a hit here moves back into the current one, so hot strings survive the turnover.
local measureOld = {}
local function getfontbounds(text, size, font)
	if typeof(font) == 'EnumItem' then
		local ok, converted = pcall(Font.fromEnum, font)
		font = ok and converted or nil
	end
	if typeof(font) ~= 'Font' then
		font = uipallet.Font or fontsize.Font
	end
	local key = tostring(font.Family)..'|'..tostring(font.Weight)..'|'..tostring(size)..'|'..tostring(text)
	local cached = measureCache[key]
	if cached then return cached end
	cached = measureOld[key]
	if cached then
		measureCache[key] = cached
		return cached
	end

	fontsize.Text = text
	fontsize.Size = size
	fontsize.Font = font
	local bounds = textService:GetTextBoundsAsync(fontsize)
	measureCount += 1
	if measureCount > 4000 then
		measureOld = measureCache
		measureCache = {}
		measureCount = 0
	end
	measureCache[key] = bounds
	return bounds
end

do
	local vapeAssets = {
		['pistonware/assets/new/pistonround.png'] = 'rbxassetid://99295797606112',
		['pistonware/assets/new/pistonsquare.png'] = 'rbxassetid://73714636260061'
	}

	--[[
		Every icon this GUI draws comes from the uploaded ids above. No disk, no getcustomasset.

		It used to work the other way on desktop: download all 105 files under
		pistonware/assets/new from the repo, then for each icon the GUI asked for run an isfile,
		a full readfile to prove the file was not truncated, and a getcustomasset that read it a
		THIRD time and copied it into the client content directory to get a content id back. 75
		icons during construction, all of it on the critical path before the menu could appear,
		and the first run paid a 105-file download on top.

		The uploaded ids were already sitting right there -- they were the mobile branch, and the
		fallback for every way the disk path could fail -- so both branches had always been
		drawing the same pictures. The disk copy bought nothing. Roblox caches by asset id across
		games and sessions, which a per-install content directory never did, so the ids are also
		warm on the second launch in a way the files were not.

		That also retires the 'ContentId formatting failed' crash at the source rather than
		guarding it: a truncated PNG on disk was what produced an invalid content id, and
		assigning one to .Image throws AT THE ASSIGNMENT, outside every pcall in this file,
		taking the whole GUI down over a single icon. Nothing reads those files now.

		The fallback below is not for the shipped GUI. A handful of paths that only game modules
		ask for (arrowmodule, radaricon, textguiicon, blockedicon, blockedtab) exist in the repo
		but have no uploaded id, so they still resolve the old way -- lazily, the first time a
		module that draws one is built, never during GUI construction. If those ever get uploaded
		and added to the table above, this whole tail can go.

		getcustomasset itself has to stay reachable regardless: games/*.lua hand it USER files
		(custom music, custom textures) through `assetfunction`, and those have no uploaded id and
		no substitute. What is gone is every use of it on the load path.
	]]
	local function usableAsset(value)
		return type(value) == 'string' and value:match('^rbx%a*://') ~= nil
	end

	--[[ Empty counts as missing. Every executor's real isfile reports a zero-byte file as PRESENT,
	so a write cut short by a cancel, crash or teleport leaves a truncated file that cache-first
	logic then skips forever. ]]
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

	--[[ Points at the pistonware repo, not VapeCompiled, and at main rather than a commit.txt this
	install never writes. Retried, because a raw host under load returns an error page as the
	body and caching that poisons the install silently. ]]
	local function downloadFile(path)
		local devLoader = shared.PistonwareDevLoadSource
		if type(devLoader) == 'function' then
			devLoader(path)
			return getcustomasset(path)
		end
		if not hasContent(path) then
			local relPath = select(1, path:gsub('pistonware/', ''))
			local data
			for attempt = 1, 4 do
				local success, res = pcall(function()
					return pistonwareHttpGet('https://raw.githubusercontent.com/themagicpiston/pistonware/main/'..relPath, true, attempt)
				end)
				if success and res and res ~= '' and res ~= '404: Not Found' then
					data = res
					break
				end
				if attempt < 4 then
					task.wait(attempt)
				end
			end

			if not data then
				error('failed to download '..path..' after 4 attempts')
			end

			writefile(path, data)
		end

		return getcustomasset(path)
	end

	local resolved = {}

	--[[ Resolves a path the old way: the file on disk, handed to the executor's own asset
	function. Blocks, and downloads the file first if it is not already there. ]]
	local function resolveFile(path)
		local cached = resolved[path]
		if cached ~= nil then return cached end

		local value = ''
		if not inputService.TouchEnabled and getcustomasset then
			local ok, res = pcall(downloadFile, path)
			if ok and usableAsset(res) then
				value = res
			end
		end

		resolved[path] = value
		return value
	end

	--[[
		The same answer, but never at the cost of a download on the load path.

		Used for icons that would RATHER come from the file than the uploaded id, where the id is
		still perfectly good if the file is not there. If the answer is already known, or the file
		is already on disk, it is returned right here -- that is only a read, no network. If the
		file is missing it returns nothing and fetches it on another thread, so the id gets drawn
		now and every later session has the file ready.

		Executors without getcustomasset, and touch devices, never have a file answer at all.
	]]
	local warming = {}
	local function resolveFileIfCheap(path)
		if inputService.TouchEnabled or not getcustomasset then return '' end

		local cached = resolved[path]
		if cached ~= nil then return cached end
		if hasContent(path) then return resolveFile(path) end

		if not warming[path] then
			warming[path] = true
			task.spawn(pcall, resolveFile, path)
		end

		return ''
	end

	--[[ preferFile asks for the real file when the executor can produce one, falling back to the
	uploaded id when it cannot -- no getcustomasset, a touch device, or the file not there yet.
	Only worth setting where the file is the better source; everything else is faster and more
	durable as an id. ]]
	getvapeasset = function(path, preferFile)
		if preferFile then
			local file = resolveFileIfCheap(path)
			if file ~= '' then return file end
		end

		local id = vapeAssets[path]
		if id then return id end
		--[[ Already a content id. Callers outside this file pass user values through the
		vape.Libraries.getcustomasset alias, and one of them hands over an rbxassetid
		directly; sending that down the download path only produced an empty string. ]]
		if usableAsset(path) then return path end

		return resolveFile(path)
	end
end

--[[
	The registry of in-flight tweens, keyed by the object being animated.

	The lazy __index has to STORE what it builds. Returning a fresh table without keeping
	it meant every call got its own throwaway registry, so `registry[obj]` was always empty:
	nothing was ever found, nothing was ever cancelled, and tween:Cancel was a no-op at all
	~100 call sites. Two tweens on the same property then ran at once and fought -- the hurt
	flash (which cancels the previous flash before starting the next), and every hover that
	re-enters before its 0.16s colour tween has finished. Each orphaned tween also kept its
	Completed connection alive for its full duration.
]]
local tween = setmetatable({}, {
	__index = function(self, key)
		local registry = {}
		rawset(self, key, registry)
		return registry
	end
})

do
	function tween:Tween(obj, info, goal, index)
		local registry = self[index or 'tweens']
		local existing = registry[obj]
		if existing then
			-- Cleared BEFORE cancelling: Cancel() fires Completed, and a handler that
			-- runs later would otherwise wipe the entry belonging to the tween created
			-- below it.
			registry[obj] = nil
			existing:Cancel()
		end

		--[[ Inside the menu while it is shut -- a module switched by its key, a profile applying --
		nobody can see the animation, so the end state is set at once, as it already was for an
		object that is itself hidden. The menu opens by appearing, never by animating in, so what
		it shows when it opens is the same. ]]
		if obj.Parent and (obj:IsA('UIStroke') or obj.Visible)
			and not (clickgui and not clickgui.Visible and obj:IsDescendantOf(clickgui)) then
			local playing = tweenService:Create(obj, info, goal)
			registry[obj] = playing
			playing.Completed:Once(function()
				-- Only retire the entry if it is still ours; a newer tween may already
				-- own the slot.
				if registry[obj] == playing then
					registry[obj] = nil
				end
			end)

			playing:Play()
		else
			for prop, value in goal do
				obj[prop] = value
			end
		end
	end

	function tween:Cancel(obj, index)
		local registry = self[index or 'tweens']
		local existing = registry[obj]

		if existing then
			registry[obj] = nil
			existing:Cancel()
		end
	end
end

--[[
	Palette and type.

	Main and Text stay the two colours everything else is derived from -- color.Dark/Light read
	Main's brightness, and the game files build their own panels out of uipallet -- so they move
	only as far as the new look needs. The rest of the look lives in theme, which nothing outside
	this file reads.
]]
uipallet = {
	Main = Color3.fromRGB(27, 27, 27),
	Text = Color3.fromRGB(226, 225, 220),
	Font = Font.new('rbxasset://fonts/families/BuilderSans.json'),
	FontMedium = Font.new('rbxasset://fonts/families/BuilderSans.json', Enum.FontWeight.Medium),
	FontSemiBold = Font.new('rbxasset://fonts/families/BuilderSans.json', Enum.FontWeight.SemiBold),
	FontBold = Font.new('rbxasset://fonts/families/BuilderSans.json', Enum.FontWeight.Bold),
	IconFont = nil,
	Tween = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
}

local theme = {
	Bar = Color3.fromRGB(20, 20, 20),
	Card = Color3.fromRGB(20, 20, 20),
	CardHover = Color3.fromRGB(20, 20, 20),
	Raised = Color3.fromRGB(41, 41, 41),
	Pill = Color3.fromRGB(64, 64, 64),
	PillHover = Color3.fromRGB(80, 80, 80),
	Badge = Color3.fromRGB(41, 41, 41),
	Outline = Color3.fromRGB(64, 64, 64),
	Track = Color3.fromRGB(64, 64, 64),
	TrackOff = Color3.fromRGB(64, 64, 64),
	TrackOffHover = Color3.fromRGB(79, 79, 79),
	Knob = Color3.fromRGB(20, 20, 20),
	KnobOff = Color3.fromRGB(20, 20, 20),
	Text = Color3.fromRGB(221, 221, 221),
	Label = Color3.fromRGB(221, 221, 221),
	SubText = Color3.fromRGB(153, 153, 153),
	Header = Color3.fromRGB(153, 153, 153),
	Muted = Color3.fromRGB(102, 102, 102),
	Red = Color3.fromRGB(221, 70, 71),
	Yellow = Color3.fromRGB(245, 190, 60),
	Green = Color3.fromRGB(82, 196, 106),
	-- One place for the sizes the cards are built from, so the layout code and the rows agree.
	CardWidth = 434,
	Gap = 8,
	RowHeight = 28,
	Inset = 12
}

-- The accent, from the GUI theme slider (orange by default).
function theme.Accent()
	return Color3.fromHSV(vape.GUIColor.Hue, vape.GUIColor.Sat, vape.GUIColor.Value)
end

-- The accent as a tint over a card, for the bound-key badge and the notification tag.
function theme.Tint(accent, amount)
	return theme.Card:Lerp(accent or theme.Accent(), amount or 0.18)
end

do
	local data = isfile('pistonware/profiles/color.txt') and loadJson('pistonware/profiles/color.txt')
	if data then
		uipallet.Main = data.Main and Color3.fromRGB(unpack(data.Main)) or uipallet.Main
		uipallet.Text = data.Text and Color3.fromRGB(unpack(data.Text)) or uipallet.Text
		if data.Font then
			local family = data.Font:find('rbxasset') and data.Font or string.format('rbxasset://fonts/families/%s.json', data.Font)
			uipallet.Font = Font.new(family)
			uipallet.FontMedium = Font.new(family, Enum.FontWeight.Medium)
			uipallet.FontSemiBold = Font.new(family, Enum.FontWeight.SemiBold)
			uipallet.FontBold = Font.new(family, Enum.FontWeight.Bold)
			uipallet.CustomFont = true
		end
	end

	fontsize.Font = uipallet.Font
end

--[[
	Inter, on every executor.

	Roblox ships no Inter, and a Font can only name a family JSON -- so the TTFs are kept on disk
	under pistonware/assets/fonts, a family JSON pointing at them through getcustomasset is written
	next to them, and the Font is built from THAT. Every executor documented in docs/executors has
	getcustomasset; an executor that does not, a file that will not load, or a client that refuses
	the face all land on BuilderSans, which every client has.

	The JSON is rewritten on every boot rather than cached: the content id getcustomasset hands back
	can change between sessions, and a JSON naming yesterday's ids names nothing.

	Built optimistically and verified afterwards. The menu is drawn with whatever is current; once
	the faces are confirmed (or have downloaded, on a first run), every label this file made is
	switched over through the registry below. Game visuals built in between keep the font they
	were built with until the next inject, which costs nothing but one session of BuilderSans.
]]
local fonts = {
	Ready = false,
	IconReady = false,
	Registry = setmetatable({}, {__mode = 'k'}),
	Remeasure = setmetatable({}, {__mode = 'k'})
}
local FONT_DIR = 'pistonware/assets/fonts'
local FONT_FACES = {
	{Role = 'Regular', File = 'Inter-Regular.ttf', Weight = 400, Enum = Enum.FontWeight.Regular},
	{Role = 'Medium', File = 'Inter-Medium.ttf', Weight = 500, Enum = Enum.FontWeight.Medium},
	{Role = 'SemiBold', File = 'Inter-SemiBold.ttf', Weight = 600, Enum = Enum.FontWeight.SemiBold},
	{Role = 'Bold', File = 'Inter-Bold.ttf', Weight = 700, Enum = Enum.FontWeight.Bold}
}
local FONT_ROLES = {Regular = 'Font', Medium = 'FontMedium', SemiBold = 'FontSemiBold', Bold = 'FontBold'}

-- What an icon reads as where its image cannot be shown: one character Inter itself draws.
local ICON_FALLBACK = {
	x = '\u{00D7}', plus = '+', minus = '\u{2212}', share = '\u{2191}', import = '\u{2193}', download = '\u{2193}',
	upload = '\u{2191}', folder = '\u{2026}', ['folder-open'] = '\u{2026}', ['trash-2'] = '\u{00D7}', pin = '\u{2022}',
	check = '\u{2713}', ['chevron-down'] = 'v', ['chevron-right'] = '\u{203A}', eye = '\u{2022}', ['eye-off'] = '\u{2013}',
	search = '?'
}

function fonts.face(role)
	return uipallet[FONT_ROLES[role] or 'Font'] or uipallet.Font
end

function fonts.glyph(name)
	return ICON_FALLBACK[name] or name
end

--[[ Applies the current faces to every label this file registered and, with remeasure, re-measures
what was sized from text through the Remeasure callbacks -- only when the face really changed: those
rebuild the mod overlay and restart name tags. Both registries are copied first: a callback can
yield, and labels come and go. Done in small batches a frame apart: a few hundred labels changing
face in one frame dropped the game to about 15 fps for a second. Only ever called from a
background thread. ]]
local RESTYLE_BATCH = 40
function fonts.restyle(remeasure)
	local labels = {}
	for obj, entry in fonts.Registry do
		table.insert(labels, {obj, entry})
	end
	for index, pair in labels do
		local obj, entry = pair[1], pair[2]
		if obj.Parent then
			pcall(function()
				-- An icon is an image; only its fallback character, if it shows one, has a face.
				local face = entry.Icon and uipallet.FontBold or fonts.face(entry.Role)
				if obj.FontFace ~= face then
					obj.FontFace = face
				end
			end)
		end
		if index % RESTYLE_BATCH == 0 then
			task.wait()
		end
	end
	if not remeasure then return end
	local callbacks = {}
	for _, callback in fonts.Remeasure do
		table.insert(callbacks, callback)
	end
	for index, callback in callbacks do
		pcall(callback)
		if index % 4 == 0 then
			task.wait()
		end
	end
end

--[[ For text drawn outside the menu -- overlays, name tags, ESP labels -- so all of it is in the
menu's own face: sets it now and keeps it on the face if Inter finishes loading later. Medium is
the weight the menu and the mod overlay are drawn in. ]]
function fonts.track(obj, role)
	role = role or 'Medium'
	obj.FontFace = fonts.face(role)
	fonts.Registry[obj] = {Role = role}
	return obj
end

-- A font file is only trusted when it starts like one: TrueType, OpenType CFF or Apple TrueType.
local function fontBodyValid(body)
	if type(body) ~= 'string' or #body < 1024 then return false end
	local head = body:sub(1, 4)
	return head == string.char(0, 1, 0, 0) or head == 'OTTO' or head == 'true'
end

local function fileValid(path)
	local ok, body = pcall(readfile, path)
	return ok and fontBodyValid(body)
end

local function exists(path)
	local ok, present = pcall(isfile, path)
	return ok and present == true
end

local function downloadFont(file)
	local path = FONT_DIR..'/'..file
	local devLoader = shared.PistonwareDevLoadSource
	if type(devLoader) == 'function' then
		pcall(devLoader, path)
		return fileValid(path)
	end
	for attempt = 1, 4 do
		local ok, body = pcall(pistonwareHttpGet, 'https://raw.githubusercontent.com/themagicpiston/pistonware/main/assets/fonts/'..file, true, attempt)
		if ok and fontBodyValid(body) then
			return pcall(writefile, path, body) and exists(path)
		end
		if attempt < 4 then task.wait(attempt) end
	end
	return false
end

--[[ Writes a family file for these faces and returns its content id. The extension is a choice
because executors differ in what their content folder will serve as a font family: '.json' is
what Roblox's own families use, '.font' is what other script libraries ship. ]]
local function familyId(name, faces, extension)
	local entries = {}
	for _, face in faces do
		local ok, id = pcall(getcustomasset, FONT_DIR..'/'..face.File)
		if not (ok and type(id) == 'string' and id:find('^rbx')) then return nil end
		table.insert(entries, {name = face.Role or 'Regular', weight = face.Weight or 400, style = 'normal', assetId = id})
	end
	local encoded = httpService:JSONEncode({name = name, faces = entries})
	local path = FONT_DIR..'/'..name..extension
	if not pcall(writefile, path, encoded) then return nil end
	local ok, id = pcall(getcustomasset, path)
	return ok and type(id) == 'string' and id:find('^rbx') and id or nil
end

--[[ Whether a face really draws, decided by measuring it. The probe is made of the letters where
Inter is widest next to every face Roblox ships: 'zxcwyk4zxcwyk4' at 40 px is 339.6 px in Inter,
and 299 (BuilderSans), 302 (Arial) or 305 (Roboto) in the faces a client falls back to. Measured
two ways, because an executor's TextService and its renderer have disagreed before: the text
service's bounds, and the bounds a real label on screen reports.

Judged as a ratio to BuilderSans measured the same way on the same client, not in absolute
pixels: one client measured every face at 0.83 of its real width (BuilderSans 246, Inter 282),
which an absolute check took for a failure although Inter was drawing. Inter is 1.134 times
BuilderSans on this probe; a face that fell back measures 1.0. ]]
local PROBE, PROBE_INTER, PROBE_BUILDER = 'zxcwyk4zxcwyk4', 339.6, 299.4

local function measureService(face)
	local textService = cloneref(game:GetService('TextService'))
	local params = Instance.new('GetTextBoundsParams')
	params.Text = PROBE
	params.Size = 40
	params.Font = face
	params.Width = 100000
	local result
	task.spawn(function()
		local ok, bounds = pcall(function()
			return textService:GetTextBoundsAsync(params)
		end)
		result = ok and bounds.X or false
	end)
	local deadline = os.clock() + 10
	while result == nil and os.clock() < deadline do
		task.wait(0.1)
	end
	return result or nil
end

local function probeLabel(face)
	local label = Instance.new('TextLabel')
	label.BackgroundTransparency = 1
	label.FontFace = face
	label.Position = UDim2.fromOffset(-4000, -4000)
	label.Size = UDim2.fromOffset(1000, 60)
	label.Text = PROBE
	label.TextSize = 40
	label.TextTransparency = 1
	label.Parent = vape.gui
	return label
end

local function measureLabel(label)
	if not (label and label.Parent) then return nil end
	local deadline = os.clock() + 3
	repeat
		task.wait()
		local width = label.TextBounds.X
		if width > 0 then return width end
	until os.clock() > deadline
	return nil
end

-- Asks the client to fetch the face before it is measured; the statuses go into the log.
local function preload(label)
	local statuses = {}
	local done = false
	task.spawn(function()
		pcall(function()
			cloneref(game:GetService('ContentProvider')):PreloadAsync({label}, function(_, status)
				table.insert(statuses, (tostring(status):gsub('^Enum%.AssetFetchStatus%.', '')))
			end)
		end)
		done = true
	end)
	local deadline = os.clock() + 8
	while not done and os.clock() < deadline do
		task.wait(0.1)
	end
	return #statuses > 0 and table.concat(statuses, '/') or (done and 'none' or 'timeout')
end

local function isInter(width, builder)
	if not width then return false end
	if builder and builder > 0 then
		local ratio = width / builder
		local expected = PROBE_INTER / PROBE_BUILDER
		return math.abs(ratio - expected) / expected < 0.04
	end
	return math.abs(width - PROBE_INTER) / PROBE_INTER < 0.06
end

local function fmt(width)
	return width and string.format('%.1f', width) or '-'
end

--[[ 'ok' when either measurement reads as Inter, 'failed' when both read as something else, and
'unknown' when nothing could be measured at all -- which is never taken for a pass. A face that
has not finished loading measures as the fallback, so a miss is retried after a wait. ]]
local function faceDraws(face, calibration)
	if not (vape.gui and vape.gui.Parent) then return 'unknown', 'no gui' end
	calibration = calibration or {}
	local label = probeLabel(face)
	local fetched = preload(label)
	local notes = {}
	local verdict = 'unknown'
	for _, delay in {0, 2, 5} do
		if delay > 0 then task.wait(delay) end
		local service, rendered = measureService(face), measureLabel(label)
		table.insert(notes, fmt(service)..'/'..fmt(rendered))
		if isInter(service, calibration.Service) or isInter(rendered, calibration.Label) then
			verdict = 'ok'
			break
		elseif service or rendered then
			verdict = 'failed'
		end
	end
	label:Destroy()
	return verdict, 'fetch='..fetched..' service/label='..table.concat(notes, ' ')
end

-- Counted per boot where the files loaded and still measured wrong; a failed download does not
-- count, and a pass sets it back to 0. Renamed again: the last counter filled up under checks that
-- misread every face on a client that measures fonts at 0.83 of their width.
local FAILURE_FILE = FONT_DIR..'/font-failures-3.txt'
local function fontFailures()
	local ok, body = pcall(readfile, FAILURE_FILE)
	return ok and tonumber(body) or 0
end

--[[ Once Inter is in: every weight fetched, then every self-sizing label nudged to lay itself out
again. The check above only loads the Regular face; Medium, SemiBold and Bold arrive later on their
own, and a label laid out before its face had arrived kept the fallback's narrower width for good --
titles ran into their NONE badges and the badges' own text sat off centre.

With changed (the face is not the one the menu was built in), the measurement cache is emptied too
and everything sized from text measured again. Without it the face is only confirmed: every cached
size was measured in that face already -- GetTextBoundsAsync loads a face before measuring it --
and measuring again would rebuild the mod overlay and restart name tags for nothing. ]]
function fonts.settle(changed)
	task.spawn(function()
		local labels = {}
		for _, face in FONT_FACES do
			local label = probeLabel(fonts.face(face.Role))
			table.insert(labels, label)
			preload(label)
		end
		task.wait(0.25)
		for _, label in labels do
			label:Destroy()
		end
		if not (vape.gui and vape.gui.Parent) then return end
		if changed then
			table.clear(measureCache)
			table.clear(measureOld)
			measureCount = 0
		end
		local resize = {}
		for obj in fonts.Registry do
			if obj.Parent and (obj:IsA('TextLabel') or obj:IsA('TextButton')) and obj.AutomaticSize ~= Enum.AutomaticSize.None then
				table.insert(resize, obj)
			end
		end
		for index, obj in resize do
			pcall(function()
				local text = obj.Text
				obj.Text = text..' '
				obj.Text = text
			end)
			if index % RESTYLE_BATCH == 0 then
				task.wait()
			end
		end
		fonts.restyle(changed)
	end)
end

--[[ Which Inter the menu starts in, chosen before its first label is built.

The Inter 4 files on disk come first wherever the executor has getcustomasset: they are the face
Slinky draws, and they load from the disk, so the menu is made in them from the start and nothing
changes over later. Roblox's library Inter (3.019: close, not the same drawing, and fetched over
the network, so text shows in a fallback face until it arrives) is for where the files cannot be
used -- no getcustomasset, the files not downloaded yet, or the files having measured wrong here.

font-choice.txt remembers what drew last time: 'file.json' or 'file.font' (the family extension
this executor served), 'library' or 'none'. The checks still run behind the menu and change the
face only when the one in use fails, or when the files pass where they had not before. ]]
local FONT_CHOICE = FONT_DIR..'/font-choice.txt'
local function libraryFace(face)
	return Font.fromId(12187365364, face.Enum)
end

function fonts.init()
	if uipallet.CustomFont or shared.PistonwareNoCustomFonts then return end

	local function filesUsable()
		return getcustomasset ~= nil and writefile ~= nil and readfile ~= nil and isfile ~= nil and fontFailures() < 3
	end
	local function filesPresent()
		for _, face in FONT_FACES do
			if not fileValid(FONT_DIR..'/'..face.File) then return false end
		end
		return true
	end
	local function fileFaces(id)
		return function(face)
			return Font.new(id, face.Enum)
		end
	end

	local fallback = {}
	for _, face in FONT_FACES do
		fallback[face.Role] = uipallet[FONT_ROLES[face.Role]]
	end
	local function fallbackFace(face)
		return fallback[face.Role]
	end
	local function setFaces(build)
		for _, face in FONT_FACES do
			uipallet[FONT_ROLES[face.Role]] = build(face)
		end
		fontsize.Font = uipallet.Font
	end
	-- All four or none: a face that throws part way puts the fallback back.
	local function useFaces(build)
		if pcall(setFaces, build) then return true end
		pcall(setFaces, fallbackFace)
		return false
	end
	local function apply(build)
		if not (vape.gui and vape.gui.Parent) then return end
		useFaces(build)
		fonts.Ready = true
		fonts.restyle()
		fonts.settle(true)
	end
	local function remember(choice)
		pcall(function()
			if not isfolder(FONT_DIR) then makefolder(FONT_DIR) end
			writefile(FONT_CHOICE, choice)
		end)
	end

	local okChoice, choice = pcall(readfile, FONT_CHOICE)
	choice = okChoice and type(choice) == 'string' and choice or ''
	-- The family extension that served last time is tried first.
	local extensions = choice == 'file.font' and {'.font', '.json'} or {'.json', '.font'}

	local early, earlyId
	if filesUsable() and fontFailures() == 0 and filesPresent() then
		earlyId = familyId('Inter', FONT_FACES, extensions[1])
		if earlyId and useFaces(fileFaces(earlyId)) then
			early = 'file'
		end
	end
	if not early and choice == 'library' and useFaces(libraryFace) then
		early = 'library'
	end
	fonts.Ready = early ~= nil
	if early then
		-- The four weights fetched now rather than as each is first drawn, and anything measured
		-- before they arrived measured again.
		fonts.settle()
	end

	task.spawn(function()
		-- Off the injection path: nothing below runs in the frame that builds the menu.
		task.wait()
		local log = {'probe '..PROBE..' expects '..PROBE_INTER, 'start='..(early or 'BuilderSans')}

		--[[ This client's own BuilderSans, the yardstick every face below is measured against. The
		saved fallback, not uipallet.Font: that is already Inter when the menu started in it, and
		Inter measured against itself reads as not Inter -- which used to put a menu that started in
		Inter back to BuilderSans, and the next inject back to Inter, one switch every time. ]]
		local calibrationLabel = probeLabel(fallback.Regular)
		local calibration = {Service = measureService(fallback.Regular), Label = measureLabel(calibrationLabel)}
		calibrationLabel:Destroy()
		table.insert(log, 'BuilderSans='..fmt(calibration.Service)..'/'..fmt(calibration.Label)..' (expects 299.4; Inter is 1.134x it)')

		-- 1. The Inter 4 files, wherever getcustomasset can serve them.
		local fileOutcome, keepInUse = 'skipped', false
		if filesUsable() then
			pcall(function()
				if not isfolder(FONT_DIR) then makefolder(FONT_DIR) end
			end)
			-- Already read and found whole when the menu started in them.
			local present = true
			if early ~= 'file' then
				for _, face in FONT_FACES do
					if not fileValid(FONT_DIR..'/'..face.File) then
						present = downloadFont(face.File) and present
					end
				end
			end
			fileOutcome = present and 'failed' or 'missing'
			if present then
				local inUseFailed = false
				for _, extension in extensions do
					local inUse = early == 'file' and extension == extensions[1]
					local id = inUse and earlyId or familyId('Inter', FONT_FACES, extension)
					if id then
						local verdict, note = faceDraws(Font.new(id, Enum.FontWeight.Regular), calibration)
						table.insert(log, 'file'..extension..'='..verdict..' '..note)
						if verdict == 'ok' then
							fileOutcome = 'ok'
							remember('file'..extension)
							pcall(writefile, FAILURE_FILE, '0')
							if inUse then
								-- In use since the start: only the later weights' sizes to settle.
								fonts.settle()
							else
								apply(fileFaces(id))
							end
							break
						elseif verdict == 'unknown' then
							if inUse then
								-- Nothing could be measured: the files in use loaded, so they stay.
								keepInUse = true
								break
							end
							fileOutcome = 'unknown'
						elseif inUse then
							inUseFailed = true
						end
					else
						table.insert(log, 'file'..extension..'=no-id')
					end
				end
				-- The face in use measuring wrong counts, whatever the other extension measured.
				if fileOutcome == 'failed' or (inUseFailed and fileOutcome ~= 'ok') then
					pcall(writefile, FAILURE_FILE, tostring(fontFailures() + 1))
				end
			else
				table.insert(log, 'files=missing')
			end
		end

		-- 2. Roblox's own Inter, the Creator Store family 12187365364, where the files did not draw.
		if not (fileOutcome == 'ok' or keepInUse) then
			-- The files the menu started in measured wrong or went missing, so they are not kept on an unknown.
			local broken = early == 'file'
			local ok, regular = pcall(Font.fromId, 12187365364, Enum.FontWeight.Regular)
			local verdict, note = 'failed', 'no font'
			if ok and regular then
				verdict, note = faceDraws(regular, calibration)
			end
			table.insert(log, 'library='..verdict..' '..note)
			if verdict == 'ok' then
				remember('library')
				if early == 'library' then
					fonts.settle()
				else
					apply(libraryFace)
				end
			elseif early and not broken and verdict == 'unknown' then
				-- Nothing could be measured this time: keep what drew last time.
				fonts.settle()
			elseif early then
				-- What the menu started in did not draw: BuilderSans for this session.
				remember('none')
				apply(fallbackFace)
			end
		end

		-- For diagnosing a machine we cannot see. Developer builds only.
		if writefile and shared.PistonwareDeveloper then
			pcall(function()
				if not isfolder(FONT_DIR) then makefolder(FONT_DIR) end
			end)
			pcall(writefile, FONT_DIR..'/load-status.txt', table.concat(log, '\n'))
		end
	end)
end

--[[
	View primitives. Every text object goes through ui.text or ui.icon so the font swap can reach
	it; everything else is a plain instance with its properties set from a table.
]]
local ui = {}

function ui.new(className, props, parent)
	local obj = Instance.new(className)
	if props then
		for key, value in props do
			obj[key] = value
		end
	end
	if parent then obj.Parent = parent end
	return obj
end

function ui.corner(obj, radius)
	local corner = Instance.new('UICorner')
	corner.CornerRadius = typeof(radius) == 'UDim' and radius or UDim.new(0, radius or 8)
	corner.Parent = obj
	return corner
end

function ui.stroke(obj, strokeColor, thickness, transparency)
	local stroke = Instance.new('UIStroke')
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Color = strokeColor or theme.Outline
	stroke.Thickness = thickness or 1
	stroke.Transparency = transparency or 0
	stroke.Parent = obj
	return stroke
end

function ui.padding(obj, left, right, top, bottom)
	local padding = Instance.new('UIPadding')
	padding.PaddingLeft = UDim.new(0, left or 0)
	padding.PaddingRight = UDim.new(0, right or left or 0)
	padding.PaddingTop = UDim.new(0, top or 0)
	padding.PaddingBottom = UDim.new(0, bottom or top or 0)
	padding.Parent = obj
	return padding
end

function ui.list(obj, gap, horizontal, align)
	local layout = Instance.new('UIListLayout')
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, gap or 0)
	if horizontal then
		layout.FillDirection = Enum.FillDirection.Horizontal
		layout.VerticalAlignment = Enum.VerticalAlignment.Center
	end
	if align then
		layout.HorizontalAlignment = align
	end
	layout.Parent = obj
	return layout
end

-- A TextLabel (or TextButton/TextBox via props.Class) in one of the four Inter weights.
function ui.text(parent, props)
	props = props or {}
	local className = props.Class or 'TextLabel'
	local label = Instance.new(className)
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.FontFace = fonts.face(props.Weight or 'Medium')
	label.TextColor3 = props.Color or theme.Label
	label.TextSize = props.Size or 14
	label.TextXAlignment = props.AlignX or Enum.TextXAlignment.Left
	label.TextYAlignment = props.AlignY or Enum.TextYAlignment.Center
	label.Text = props.Text or ''
	if className == 'TextButton' then
		label.AutoButtonColor = false
	end
	for key, value in props.Props or {} do
		label[key] = value
	end
	fonts.Registry[label] = {Role = props.Weight or 'Medium'}
	if parent then label.Parent = parent end
	return label
end

-- An icon: a Lucide image in pistonware/assets/icons, tinted by the holder's TextColor3; where the
-- image cannot be shown (no local files on this client), one fallback character instead.
local ICON_DIR = 'pistonware/assets/icons'
local iconAssets, iconFetching = {}, {}

-- The file's content id, or '' when it is missing, is not a PNG, or the executor will not serve it.
local function iconFile(name)
	local path = ICON_DIR..'/'..name..'.png'
	local ok, body = pcall(readfile, path)
	if not (ok and type(body) == 'string' and body:sub(2, 4) == 'PNG') then return '' end
	local idOk, id = pcall(getcustomasset, path)
	return idOk and type(id) == 'string' and id:find('^rbx') and id or ''
end

--[[ Never waits on the network: a missing file draws the fallback character now and is fetched on
another thread, and the icons showing that character are redrawn once it lands. ]]
local function iconImage(name)
	local cached = iconAssets[name]
	if cached ~= nil then return cached end
	local id = ''
	if getcustomasset and readfile and not isMobile() then
		id = iconFile(name)
	end
	iconAssets[name] = id
	if id == '' and getcustomasset and readfile and writefile and not isMobile() and not iconFetching[name] then
		iconFetching[name] = true
		task.defer(function()
			pcall(function()
				if not isfolder(ICON_DIR) then makefolder(ICON_DIR) end
			end)
			local path = ICON_DIR..'/'..name..'.png'
			local devLoader = shared.PistonwareDevLoadSource
			if type(devLoader) == 'function' then
				pcall(devLoader, path)
			else
				local ok, body = pcall(pistonwareHttpGet, 'https://raw.githubusercontent.com/themagicpiston/pistonware/main/assets/icons/'..name..'.png', true, 1)
				if ok and type(body) == 'string' and body:sub(2, 4) == 'PNG' then
					pcall(writefile, path, body)
				end
			end
			local fresh = iconFile(name)
			if fresh == '' then
				-- Whatever came back is not a PNG (an error page): removed, so the next session fetches
				-- again. A real PNG the executor will not serve is kept.
				local ok, body = pcall(readfile, path)
				if ok and type(body) == 'string' and body:sub(2, 4) ~= 'PNG' then
					pcall(delfile, path)
				end
				return
			end
			iconAssets[name] = fresh
			local holders = {}
			for holder, entry in fonts.Registry do
				if entry.Icon == name then
					table.insert(holders, holder)
				end
			end
			for _, holder in holders do
				if holder.Parent then
					pcall(ui.setIcon, holder, name)
				end
			end
		end)
	end
	return id
end

function ui.setIcon(holder, name)
	local entry = fonts.Registry[holder]
	if entry then entry.Icon = name end
	local id = iconImage(name)
	local image = holder:FindFirstChild('Glyph')
	if image then
		-- A content id the client rejects falls back to the character rather than failing the build.
		if not pcall(function()
			image.Image = id
		end) then
			id = ''
			iconAssets[name] = ''
		end
		image.Visible = id ~= ''
	end
	if id == '' then
		holder.Text = ICON_FALLBACK[name] or ''
		holder.TextSize = math.max((entry and entry.Size or 16) - 2, 10)
	else
		holder.Text = ''
	end
end

function ui.icon(parent, name, size, props)
	props = props or {}
	size = size or 16
	local holder = Instance.new(props.Class == 'TextButton' and 'TextButton' or 'TextLabel')
	holder.BackgroundTransparency = 1
	holder.BorderSizePixel = 0
	holder.FontFace = uipallet.FontBold
	holder.Text = ''
	holder.TextColor3 = props.Color or theme.SubText
	holder.TextXAlignment = Enum.TextXAlignment.Center
	holder.TextYAlignment = Enum.TextYAlignment.Center
	holder.Size = props.Box or UDim2.fromOffset(size + 4, size + 4)
	if holder:IsA('TextButton') then
		holder.AutoButtonColor = false
	end
	local image = Instance.new('ImageLabel')
	image.Name = 'Glyph'
	image.AnchorPoint = Vector2.new(0.5, 0.5)
	image.BackgroundTransparency = 1
	image.ImageColor3 = holder.TextColor3
	image.Position = UDim2.fromScale(0.5, 0.5)
	image.Size = UDim2.fromOffset(size, size)
	image.Parent = holder
	holder:GetPropertyChangedSignal('TextColor3'):Connect(function()
		image.ImageColor3 = holder.TextColor3
	end)
	for key, value in props.Props or {} do
		holder[key] = value
	end
	fonts.Registry[holder] = {Icon = name, Size = size}
	ui.setIcon(holder, name)
	if parent then holder.Parent = parent end
	return holder
end

--[[
	A pill switch, Slinky's: accent track with a dark knob on the right when on, a dark track with
	a grey knob on the left when off.
]]
function ui.switch(parent, position)
	local track = ui.new('Frame', {
		Name = 'Switch',
		AnchorPoint = Vector2.new(1, 0.5),
		BackgroundColor3 = theme.TrackOff,
		BorderSizePixel = 0,
		Position = position or UDim2.new(1, -theme.Inset, 0.5, 0),
		Size = UDim2.fromOffset(40, 20)
	}, parent)
	ui.corner(track, UDim.new(1, 0))
	local knob = ui.new('Frame', {
		Name = 'Knob',
		AnchorPoint = Vector2.new(0, 0.5),
		BackgroundColor3 = theme.KnobOff,
		BorderSizePixel = 0,
		Position = UDim2.new(0, 2, 0.5, 0),
		Size = UDim2.fromOffset(16, 16)
	}, track)
	ui.corner(knob, UDim.new(1, 0))

	local switch = {Object = track, Enabled = false}
	local hovered = false
	function switch:Set(enabled, accent)
		self.Enabled = enabled
		tween:Tween(track, uipallet.Tween, {BackgroundColor3 = enabled and (accent or theme.Accent()) or (hovered and theme.TrackOffHover or theme.TrackOff)})
		tween:Tween(knob, uipallet.Tween, {
			Position = enabled and UDim2.new(1, -18, 0.5, 0) or UDim2.new(0, 2, 0.5, 0),
			BackgroundColor3 = enabled and theme.Knob or theme.KnobOff
		})
	end
	track.MouseEnter:Connect(function()
		hovered = true
		if not switch.Enabled then
			tween:Cancel(track)
			track.BackgroundColor3 = theme.TrackOffHover
		end
	end)
	track.MouseLeave:Connect(function()
		hovered = false
		if not switch.Enabled then
			tween:Cancel(track)
			track.BackgroundColor3 = theme.TrackOff
		end
	end)
	function switch:Color(accent)
		if self.Enabled then
			tween:Cancel(track)
			track.BackgroundColor3 = accent
		end
	end
	return switch
end

--[[ The value bubble over a slider knob. It sits on the menu itself rather than in the card, so a
slider at the top edge of a scrolled page shows it whole instead of cut off by the page, and it
follows the knob as the knob moves or the page scrolls. Built the first time it is shown. ]]
function ui.knobBubble(knob)
	local entry = {Shown = false}
	local bubble, bubbleScale
	--[[ Whether the knob itself is showing: every ancestor up to the menu visible (a hidden row, a
	collapsed card, a card moved off its tab), and its centre inside the page it scrolls in. ]]
	local function onScreen(center)
		local node, page = knob, nil
		while node and node ~= clickgui do
			if node:IsA('GuiObject') and not node.Visible then return false end
			if not page and node:IsA('ScrollingFrame') then page = node end
			node = node.Parent
		end
		if node ~= clickgui then return false end
		if page then
			local corner, size = page.AbsolutePosition, page.AbsoluteSize
			if center.X < corner.X or center.X > corner.X + size.X or center.Y < corner.Y or center.Y > corner.Y + size.Y then
				return false
			end
		end
		return true
	end
	-- In the window's own zoom as well as the menu's scale, as the confirm dialog and picker are.
	local function place()
		if not (bubble and bubble.Parent and entry.Shown) then return end
		local center = knob.AbsolutePosition + knob.AbsoluteSize / 2
		local visible = knob.Parent ~= nil and onScreen(center)
		bubble.Visible = visible
		if not visible then return end
		local s = math.max(scale.Scale, 0.05)
		local zoom = layout and layout.Zoom or 1
		bubbleScale.Scale = zoom
		local offset = center - bubble.Parent.AbsolutePosition
		bubble.Position = UDim2.fromOffset(offset.X / s, offset.Y / s - 10 * zoom)
	end
	function entry:Show(text)
		-- Not over an open dropdown list.
		if layout and layout.ListOpen then return end
		if not bubble then
			if not clickgui then return end
			bubble = ui.text(clickgui, {Text = text, Size = 14, Color = theme.Text, AlignX = Enum.TextXAlignment.Center, Props = {
				Name = 'SliderBubble',
				AnchorPoint = Vector2.new(0.5, 1),
				AutomaticSize = Enum.AutomaticSize.X,
				BackgroundColor3 = theme.Pill,
				BackgroundTransparency = 0,
				Size = UDim2.fromOffset(0, 20),
				Visible = false,
				ZIndex = 15
			}})
			ui.corner(bubble, 5)
			ui.padding(bubble, 7, 7, 0, 0)
			bubbleScale = ui.new('UIScale', {Scale = layout and layout.Zoom or 1}, bubble)
			knob:GetPropertyChangedSignal('AbsolutePosition'):Connect(place)
			clickgui:GetPropertyChangedSignal('Visible'):Connect(function()
				entry.Shown = false
				bubble.Visible = false
			end)
			pcall(function()
				knob.Destroying:Connect(function()
					bubble:Destroy()
				end)
			end)
		end
		bubble.Text = text
		entry.Shown = true
		place()
	end
	function entry:SetText(text)
		if bubble then
			bubble.Text = text
		end
	end
	function entry:Hide()
		entry.Shown = false
		if bubble then
			bubble.Visible = false
		end
	end
	return entry
end

--[[ The small rounded-square button that expands a card or a row: '+' closed, '-' open. The press
is taken by the whole line the square sits on, the description beside it included, so a thumb that
lands next to the square on a phone opens the card instead of switching the module. ]]
function ui.expander(parent, position)
	local button = ui.new('TextButton', {
		Name = 'Expand',
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = position - UDim2.fromOffset(0, 8),
		Size = UDim2.new(1, -position.X.Offset * 2, 0, 32),
		Text = ''
	}, parent)
	local square = ui.new('Frame', {
		Name = 'Square',
		BackgroundColor3 = theme.Pill,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, 8),
		Size = UDim2.fromOffset(20, 20)
	}, button)
	ui.corner(square, 5)
	local function bar(rotation)
		return ui.new('Frame', {
			AnchorPoint = Vector2.new(0.5, 0.5),
			BackgroundColor3 = theme.Text,
			BorderSizePixel = 0,
			Position = UDim2.fromScale(0.5, 0.5),
			Rotation = rotation,
			Size = UDim2.fromOffset(8, 2)
		}, square)
	end
	bar(0)
	local upright = bar(90)
	local glyph = {}
	-- '+' closed, '-' open.
	function glyph:Set(open)
		upright.Visible = not open
	end
	button.MouseEnter:Connect(function()
		square.BackgroundColor3 = theme.PillHover
	end)
	button.MouseLeave:Connect(function()
		square.BackgroundColor3 = theme.Pill
	end)
	return button, glyph
end

-- A row inside a card: transparent, full width, label on the left.
function ui.row(children, props, height)
	local row = ui.new('Frame', {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		LayoutOrder = props.LayoutOrder or 0,
		Size = UDim2.new(1, 0, 0, height or theme.RowHeight),
		Visible = props.Visible == nil or props.Visible
	}, children)
	return row
end

-- reserve: the width the control on the right needs, for rows whose control is small (a switch,
-- a badge, a swatch); without one the label gets half the row.
function ui.rowLabel(row, props, reserve)
	local indent = theme.Inset
	return ui.text(row, {
		Text = props.DisplayName or props.Name or '',
		Size = 15,
		Color = theme.Label,
		Props = {
			Name = 'Label',
			Position = UDim2.fromOffset(indent, 0),
			Size = reserve and UDim2.new(1, -(indent + reserve), 0, theme.RowHeight) or UDim2.new(0.52, -indent, 0, theme.RowHeight),
			TextTruncate = Enum.TextTruncate.AtEnd
		}
	})
end

-- The outlined pill a dropdown, a text box or a list sits in.
function ui.pill(parent, props)
	local className = props.Class or 'TextButton'
	local pill = Instance.new(className)
	pill.Name = props.Name or 'Pill'
	pill.AnchorPoint = props.AnchorPoint or Vector2.new(1, 0.5)
	pill.BackgroundColor3 = props.Background or theme.Card
	pill.BackgroundTransparency = props.Transparency or 0
	pill.BorderSizePixel = 0
	pill.Position = props.Position or UDim2.new(1, -13, 0, theme.RowHeight / 2)
	pill.Size = props.Size or UDim2.new(0.5, -14, 0, 18)
	if className ~= 'Frame' then
		pill.AutoButtonColor = false
		pill.Text = ''
	end
	ui.corner(pill, UDim.new(1, 0))
	ui.stroke(pill, theme.Outline, 2, 0)
	if parent then pill.Parent = parent end
	return pill
end

-- Text that a card shows on one line: the first line of a tooltip, without its markup.
function ui.firstLine(text)
	if type(text) ~= 'string' or text == '' then return '' end
	text = removeTags(text)
	return (text:match('^([^\n]*)') or text)
end

--[[
	The confirmation every destructive action goes through: a card at the top of the screen,
	'Are you sure?', what is about to happen, and a red Continue. Clicking anywhere off the card
	cancels.
]]
function ui.confirm(body, onContinue, continueText)
	if not clickgui then return end
	local cardWidth = math.clamp(viewportWidth() / (math.max(scale.Scale, 0.05) * (layout and layout.Zoom or 1)) - 24, 260, 576)
	-- A body too long for one line (a phone in portrait, a long profile name) wraps onto a second
	-- line rather than losing its end, and the card grows to hold it.
	local wraps = false
	pcall(function()
		wraps = getfontbounds(body, 15, fonts.face('Medium')).X > cardWidth - 24
	end)
	local extra = wraps and 19 or 0
	local blocker = ui.new('TextButton', {
		Name = 'Confirm',
		AutoButtonColor = false,
		BackgroundColor3 = Color3.fromRGB(48, 48, 48),
		BackgroundTransparency = 0.25,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Text = '',
		ZIndex = 20
	}, clickgui)
	local card = ui.new('TextButton', {
		AutoButtonColor = false,
		AnchorPoint = Vector2.new(0.5, 0),
		BackgroundColor3 = theme.Bar,
		BorderSizePixel = 0,
		-- Under Roblox's top bar on a phone, level with the menu window (resize keeps layout.Top).
		Position = UDim2.new(0.5, 0, 0, layout and layout.Top or 12),
		Size = UDim2.fromOffset(cardWidth, 120 + extra),
		Text = '',
		ZIndex = 21
	}, blocker)
	ui.corner(card, 20)
	-- The same zoom as the menu window, so the modal stays readable on a phone.
	ui.new('UIScale', {Scale = layout and layout.Zoom or 1}, card)
	ui.text(card, {Text = 'Are you sure?', Size = 16, Weight = 'Medium', Color = theme.Text, Props = {
		Position = UDim2.fromOffset(12, 11), Size = UDim2.new(1, -60, 0, 20), ZIndex = 22
	}})
	ui.text(card, {Text = body, Size = 15, Color = theme.Text, Props = {
		Position = UDim2.fromOffset(12, 45), Size = UDim2.new(1, -24, 0, 20 + extra), ZIndex = 22,
		TextTruncate = Enum.TextTruncate.AtEnd, TextWrapped = wraps
	}})
	local close = ui.icon(card, 'x', 21, {Class = 'TextButton', Color = theme.SubText, Box = UDim2.fromOffset(24, 24), Props = {
		AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -10, 0, 10), ZIndex = 22
	}})
	local continue = ui.text(card, {Class = 'TextButton', Text = continueText or 'Continue', Size = 15, Weight = 'Medium',
		Color = Color3.new(1, 1, 1), AlignX = Enum.TextXAlignment.Center, Props = {
			BackgroundColor3 = theme.Red, BackgroundTransparency = 0,
			Position = UDim2.fromOffset(12, 78 + extra), Size = UDim2.new(1, -24, 0, 30), ZIndex = 22
		}})
	ui.corner(continue, 4)

	local function dismiss()
		blocker:Destroy()
	end
	blocker.MouseButton1Click:Connect(dismiss)
	close.MouseButton1Click:Connect(dismiss)
	continue.MouseButton1Click:Connect(function()
		dismiss()
		task.spawn(onContinue)
	end)
	return blocker
end

-- Key names as the badge prints them: RSHIFT, LCTRL, TAB.
local KEY_SHORT = {
	RightShift = 'RSHIFT', LeftShift = 'LSHIFT', RightControl = 'RCTRL', LeftControl = 'LCTRL',
	RightAlt = 'RALT', LeftAlt = 'LALT', LeftSuper = 'LWIN', RightSuper = 'RWIN', Return = 'ENTER',
	Backspace = 'BACK', CapsLock = 'CAPS', PageUp = 'PGUP', PageDown = 'PGDN', Insert = 'INS',
	Delete = 'DEL', Escape = 'ESC', Space = 'SPACE', Tab = 'TAB', Zero = '0', One = '1', Two = '2',
	Three = '3', Four = '4', Five = '5', Six = '6', Seven = '7', Eight = '8', Nine = '9',
	KeypadZero = 'NUM0', KeypadOne = 'NUM1', KeypadTwo = 'NUM2', KeypadThree = 'NUM3', KeypadFour = 'NUM4',
	KeypadFive = 'NUM5', KeypadSix = 'NUM6', KeypadSeven = 'NUM7', KeypadEight = 'NUM8', KeypadNine = 'NUM9',
	Backquote = '`', Minus = '-', Equals = '=', LeftBracket = '[', RightBracket = ']', BackSlash = '\\',
	Semicolon = ';', Quote = "'", Comma = ',', Period = '.', Slash = '/'
}
function ui.keyText(keys)
	local parts = {}
	for _, key in keys do
		table.insert(parts, KEY_SHORT[key] or tostring(key):upper())
	end
	return table.concat(parts, ' + ')
end

--[[ Display names. Module names are save keys and stay as written; what a card shows is the name
split at its capitals -- AutoClicker reads 'Auto Clicker', NameTags 'Name Tags', TPDown 'TP Down'
-- unless the module gave one of its own. ]]
function ui.prettify(name)
	if type(name) ~= 'string' then return '' end
	local pretty = name:gsub('(%l)(%u)', '%1 %2'):gsub('(%u)(%u%l)', '%1 %2'):gsub('(%a)(%d)', '%1 %2')
	return pretty
end

-- A colour as rich text takes it, '#RRGGBB': the names and states a notification picks out.
function ui.hex(value)
	return string.format('#%02X%02X%02X', math.floor(value.R * 255 + 0.5), math.floor(value.G * 255 + 0.5), math.floor(value.B * 255 + 0.5))
end

-- Roblox's top bar in the HUD's units. The ScreenGui ignores the inset, so the HUD draws under it.
function ui.insetUnits()
	local inset = 0
	pcall(function()
		inset = guiService:GetGuiInset().Y
	end)
	return inset / math.max(scale.Scale, 0.05)
end

--[[ The HUD's zoom on a phone. Notifications, overlays and legit widgets are drawn at the menu's auto
scale, width / 1920, which leaves a phone near 0.44 and their text near 6 px; the menu window has a
zoom of its own, and these get this one: an effective 0.72 on a touch screen, 1 everywhere else.
Overlays and widgets register their UIScale so a rotation or a rescale updates it (applyHudZoom);
hooks are for what sizes itself instead, the Mod Overlay. ]]
ui.hudScales = {}
ui.hudHooks = {}
function ui.hudZoom()
	if not isMobile() then return 1 end
	return math.max(1, 0.72 / math.max(scale.Scale, 0.05))
end

function ui.hudScale(obj, untracked)
	local zoom = ui.new('UIScale', {Name = 'HudZoom', Scale = ui.hudZoom()}, obj)
	if not untracked then
		table.insert(ui.hudScales, zoom)
	end
	return zoom
end

function ui.applyHudZoom()
	local value = ui.hudZoom()
	for index = #ui.hudScales, 1, -1 do
		local zoom = ui.hudScales[index]
		if not zoom.Parent then
			table.remove(ui.hudScales, index)
		elseif zoom.Scale ~= value then
			zoom.Scale = value
		end
	end
	for _, hook in ui.hudHooks do
		task.spawn(pcall, hook, value)
	end
end

--[[ Where an overlay or a legit widget starts before it is moved, in the HUD's units: under Roblox's
top bar, and each one a step on from the one before, so a fresh profile does not stack them all on
one spot. Overlays cascade like windows, a handle apart; widgets go down the left edge and start a
new column when the screen runs out. Worked out again by Reset GUI positions. ]]
ui.hudCount = {Overlay = 0, Widget = 0}
function ui.hudPlace(kind, index)
	local s = math.max(scale.Scale, 0.05)
	local zoom = ui.hudZoom()
	local top = ui.insetUnits() + 12
	local camera = gameCamera or workspace.CurrentCamera
	local height = camera and camera.ViewportSize.Y > 0 and camera.ViewportSize.Y / s or 1080
	if kind == 'Overlay' then
		local step = 40 * zoom
		local rows = math.max(math.floor((height - top - 160 * zoom) / step), 1)
		local slot = (index - 1) % rows
		return UDim2.fromOffset(240 + slot * 24 * zoom, top + slot * step)
	end
	local step = 50 * zoom
	local rows = math.max(math.floor((height - top - 12) / step), 1)
	local column, row = (index - 1) // rows, (index - 1) % rows
	return UDim2.fromOffset(16 + column * 130 * zoom, top + row * step)
end

function ui.hudSlot(kind)
	ui.hudCount[kind] += 1
	return ui.hudCount[kind]
end

--[[ Keeps a HUD element on the screen. A position saved on another device, or before a rotation,
can land past an edge, and one off screen can never be dragged back. Width and height are the
element's own, before the zoom; only a position that is out of bounds is touched. ]]
function ui.clampHud(obj, width, height)
	if not (obj and obj.Parent) then return end
	local camera = gameCamera or workspace.CurrentCamera
	local view = camera and camera.ViewportSize
	if not view or view.X < 100 or view.Y < 100 then return end
	local position = obj.Position
	if position.X.Scale ~= 0 or position.Y.Scale ~= 0 then return end
	local s = math.max(scale.Scale, 0.05)
	local zoom = ui.hudZoom()
	local x = math.clamp(position.X.Offset, 0, math.max(view.X / s - (width or 0) * zoom, 0))
	local y = math.clamp(position.Y.Offset, 0, math.max(view.Y / s - (height or 0) * zoom, 0))
	if x ~= position.X.Offset or y ~= position.Y.Offset then
		obj.Position = UDim2.fromOffset(math.floor(x), math.floor(y))
	end
end

-- Every overlay handle and widget, after a rotation or a rescale. An overlay is kept by its handle.
function ui.clampAllHud()
	for _, category in vape.Categories do
		if type(category) == 'table' and category.Type == 'Overlay' and not category.Fixed and category.Object then
			ui.clampHud(category.Object, category.Object.Size.X.Offset, 32)
		end
	end
	if vape.Legit then
		for _, module in orderedModules(vape.Legit.Order) do
			local widget = module.Children
			if widget then
				ui.clampHud(widget, widget.Size.X.Offset, widget.Size.Y.Offset)
			end
		end
	end
end

vape.Libraries = {
	color = color,
	getfontbounds = getfontbounds,
	getvapeasset = getvapeasset,
	tween = tween,
	uipallet = uipallet,
	fonts = fonts,
	theme = theme,
	ui = ui,

	--[[ Compatibility aliases. The rewrite renamed two libraries that the game files read by
	their old names -- getcustomasset -> getvapeasset and getfontsize -> getfontbounds --
	and those names appear across universal.lua, bedwars.lua and every per-place file.
	Aliasing here is two lines; renaming at the call sites is hundreds of edits across
	~30,000 lines of game code for no behavioural gain, and every one of them a chance to
	typo something that only fails at runtime in one module. ]]
	getcustomasset = getvapeasset,
	getfontsize = getfontbounds,
}

--[[
	Where the mobile button sits.

	It used to be a hardcoded (1, -90) from the right edge, measured against a top bar that no
	longer looks like that. The current client draws its buttons out of TopBarAppGui.TopBarApp,
	and where that cluster ends moves with the device, the notch, the buttons the game itself
	turns on and whether the player is in a menu -- so on plenty of phones our button landed on
	top of one of Roblox's own.

	So measure rather than guess: find where the run of buttons on the right of the bar BEGINS,
	and sit immediately to its left, 7px clear -- the same gap the client puts between its own
	buttons, so ours reads as one more of them. Where that run begins is walked rather than
	guessed at, because the count and the widths both vary: the lobby adds a wide Patch Notes
	button, and mobile shows one more than PC. If TopBarAppGui is not there at all -- older
	clients, which is what mobile executors repackage -- nothing is measured and the old offset
	stands.
]]
local topbarGap = 7
-- How far apart two boxes can be and still count as the same run of buttons. The client spaces
-- its own by topbarGap; the slack is for the padding a wrapper adds around one. It has to stay
-- well under the empty stretch between the right cluster and the chat button on the far left,
-- or the walk below would cross the bar and anchor to the wrong end.
local topbarClusterSlack = 20
local vapeButtonSize = 32
local vapeButtonFallback = UDim2.new(1, -90, 0, 4)

local function vapeButtonPosition()
	local players = cloneref(game:GetService('Players'))
	local localPlayer = players.LocalPlayer
	local playerGui = localPlayer and localPlayer:FindFirstChildOfClass('PlayerGui')
	local topbarGui = playerGui and playerGui:FindFirstChild('TopBarAppGui')
	local topbar = topbarGui and topbarGui:FindFirstChild('TopBarApp')
	if not (topbar and topbar:IsA('GuiObject')) or topbar.AbsoluteSize.X <= 0 then
		return nil
	end

	--[[
		Descendants, not children: TopBarApp's own children are layout containers, as wide as the
		stretch of bar they own rather than as wide as the buttons inside them. The buttons sit a
		level or two further down.

		Bounded by height, which is what separates a button from the full-height wrapper around it.
		An inner icon or label passes the test too, but it lives inside its button's box and so can
		never move either edge of it.
	]]
	local boxes = {}
	for _, obj in topbar:GetDescendants() do
		if
			obj:IsA('GuiObject') and obj.Visible
			and obj.AbsoluteSize.X > 0 and obj.AbsoluteSize.Y > 0 and obj.AbsoluteSize.Y <= 60
		then
			-- A visible button inside a hidden wrapper is still not on screen, and Visible is
			-- per-object -- the client hides whole clusters by the wrapper, never the buttons.
			local shown = true
			local parent = obj.Parent
			while parent and parent ~= topbar do
				if parent:IsA('GuiObject') and not parent.Visible then
					shown = false
					break
				end
				parent = parent.Parent
			end

			if shown then
				table.insert(boxes, {
					Left = obj.AbsolutePosition.X,
					Right = obj.AbsolutePosition.X + obj.AbsoluteSize.X,
					Top = obj.AbsolutePosition.Y,
					Height = obj.AbsoluteSize.Y
				})
			end
		end
	end

	if #boxes <= 0 then return nil end

	--[[
		Walk the run of buttons leftwards from the right edge of the bar.

		Picking "the leftmost thing on the right half of the screen" is what put the button on top
		of one of Roblox's: a wide button (the lobby's Patch Notes) has its centre left of the
		screen middle, so it was skipped, and the run was measured from the button AFTER it.

		Starting at the rightmost box and stepping left across every gap smaller than the slack
		asks the question that actually matters -- where does this run of buttons begin -- and it
		does not care how wide any one of them is, how many there are (mobile shows one more than
		PC), or where the screen's midpoint happens to fall.

		The repeat-until-settled walk is quadratic in the worst case, over a handful of boxes, once
		a second. Sorting them to do it in one pass costs more than it saves at this size.
	]]
	local run
	for _, box in boxes do
		if not run or box.Right > run.Right then
			run = box
		end
	end

	local edge, row = run.Left, run
	local extended = true
	while extended do
		extended = false
		for _, box in boxes do
			if box.Left < edge and box.Right >= (edge - topbarClusterSlack) then
				edge = box.Left
				row = box
				extended = true
			end
		end
	end

	--[[
		Our ScreenGui has IgnoreGuiInset set, so its offsets are true screen pixels. A ScreenGui
		without it -- which TopBarAppGui may or may not be, depending on client version -- reports
		AbsolutePosition with the inset already taken off, and lining the two up without adding it
		back puts our button the height of the top bar too high.
	]]
	local inset = 0
	if topbarGui:IsA('ScreenGui') and not topbarGui.IgnoreGuiInset then
		inset = guiService:GetGuiInset().Y
	end

	-- The bar reports negative Y while the client has it slid off screen (in its own menu, or
	-- mid-transition). Following it there would park our button off screen too, so only the
	-- horizontal placement is taken from it and the row falls back to the default height.
	local top = row.Top + inset + ((row.Height - vapeButtonSize) / 2)
	if top < 0 then
		top = 4
	end

	return UDim2.fromOffset(
		math.max(math.floor(edge - topbarGap - vapeButtonSize), 0),
		math.floor(top)
	)
end

--[[
	Polled rather than driven off a signal.

	The top bar does not move by tweening one frame around: it rebuilds its children when the
	game toggles a core GUI, when the player rotates the device, and when the client swaps to its
	in-experience menu -- so the instance any connection was bound to is frequently the one that
	just got destroyed. A second is imperceptible for a button that only has to be out of the way
	by the time a thumb reaches for it, and the read is four AbsolutePosition lookups.
]]
local function anchorVapeButton(button)
	local current

	local function apply()
		local position = vapeButtonPosition() or vapeButtonFallback
		if current ~= position then
			current = position
			button.Position = position
		end
	end

	--[[ Guarded like the loop below. This first call runs at the end of LoadGUI, and it reads
	the client's own top bar: anything that throws in there escaped LoadGUI and failed the whole
	menu on a phone, where the button already sits at the fallback and would have been fine. ]]
	pcall(apply)

	local thread = task.spawn(function()
		while button.Parent do
			task.wait(1)
			pcall(apply)
		end
	end)

	if vape.Clean then
		vape:Clean(thread)
	end
end

local function addCorner(parent, radius)
	local corner = Instance.new('UICorner')
	corner.CornerRadius = radius or UDim.new(0, 5)
	corner.Parent = parent

	return corner
end

local function addDragHandler(gui, window)
	gui.InputBegan:Connect(function(input)
		if window and not window.Visible then return end

		if
			(input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch)
			and (input.Position.Y - gui.AbsolutePosition.Y < 40 or window)
		then
			local dragPosition = Vector2.new(
				gui.AbsolutePosition.X - input.Position.X,
				gui.AbsolutePosition.Y - input.Position.Y + guiService:GetGuiInset().Y
			) / scale.Scale

			local releaseConnection
			local moveConnection = inputService.InputChanged:Connect(function(newInput)
				-- Only the press that started the drag: a touch keeps one InputObject for its whole life,
				-- and a second finger on the thumbstick used to pull the widget across the screen.
				if newInput == input or (input.UserInputType == Enum.UserInputType.MouseButton1 and newInput.UserInputType == Enum.UserInputType.MouseMovement) then
					local position = newInput.Position
					if inputService:IsKeyDown(Enum.KeyCode.LeftShift) then
						dragPosition = (dragPosition // 3) * 3
						position = (position // 3) * 3
					end

					gui.Position = UDim2.fromOffset((position.X / scale.Scale) + dragPosition.X, (position.Y / scale.Scale) + dragPosition.Y)
				end
			end)

			releaseConnection = input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End or input.UserInputState == Enum.UserInputState.Cancel then
					moveConnection:Disconnect()
					releaseConnection:Disconnect()
					vape:RequestSave()
				end
			end)
		end
	end)
end

local function addMaid(obj)
	obj.Connections = {}

	function obj:Clean(callback)
		if typeof(callback) == 'Instance' then
			table.insert(self.Connections, {
				Disconnect = function()
					callback:ClearAllChildren()
					callback:Destroy()
				end
			})
		elseif type(callback) == 'thread' then
			table.insert(self.Connections, {
				Disconnect = function()
					if coroutine.status(callback) ~= 'dead' then
						task.cancel(callback)
					end
				end
			})
		elseif type(callback) == 'function' then
			table.insert(self.Connections, {
				Disconnect = callback
			})
		else
			table.insert(self.Connections, callback)
		end
	end
end

local function cleanupConnection(connection)
	if connection == nil then return end
	if type(connection) == 'function' then
		pcall(connection)
		return
	end

	for _, methodName in {'Disconnect', 'disconnect', 'Destroy', 'Remove', 'DoCleaning'} do
		local ok, method = pcall(function()
			return connection[methodName]
		end)
		if ok and type(method) == 'function' then
			pcall(method, connection)
			return
		end
	end
end

local tooltipsEnabled = true

--[[ Cards, buttons and the rest show no hover text, as in Slinky: a card's description line is
all the text a module shows. Kept as a function so every caller still works. ]]
local function addTooltip()
end

--[[ Toggles do, and a module's own header: resting the pointer on the title -- the toggle's label,
the module's name -- shows its help in the grey pill right over its switch, the way a slider's value
sits over its knob. The pill is kept inside the card's right edge, so a long one runs back over the
card rather than off it, and text wider than 340 px wraps inside it.

Which row the pill belongs to is decided by where the pointer is, not by the order the rows' enter
and leave events arrive in. Roblox can deliver one row's leave after the next row's enter, and none
at all when a row hides or scrolls away under a still pointer. A row's enter only makes it a
candidate; the pill goes to the candidate whose title the pointer is really over, checked whenever
the pointer moves or the page scrolls (the watcher is connected where the pill is built). ]]
ui.tooltipHovered = {}

local function addRowTooltip(gui, text, anchor, title, bounds)
	if type(text) ~= 'string' or text == '' then return end
	local entry = {Text = (removeTags(text):gsub('\n', ' ')), Anchor = anchor, Title = title, Bounds = bounds}
	gui.MouseEnter:Connect(function()
		ui.tooltipHovered[gui] = entry
		ui.refreshTooltip()
	end)
	gui.MouseLeave:Connect(function()
		ui.tooltipHovered[gui] = nil
		ui.refreshTooltip()
	end)
end

-- Whether a row is really showing: every ancestor up to the menu visible, and the point inside the
-- page it scrolls in.
function ui.rowShowing(gui, point)
	local node, page = gui, nil
	while node and node ~= clickgui do
		if node:IsA('GuiObject') and not node.Visible then return false end
		if not page and node:IsA('ScrollingFrame') then page = node end
		node = node.Parent
	end
	if node ~= clickgui then return false end
	if page then
		local corner, size = page.AbsolutePosition, page.AbsoluteSize
		if point.X < corner.X or point.X > corner.X + size.X or point.Y < corner.Y or point.Y > corner.Y + size.Y then
			return false
		end
	end
	return true
end

function ui.within(point, corner, size)
	return point.X >= corner.X and point.X <= corner.X + size.X and point.Y >= corner.Y and point.Y <= corner.Y + size.Y
end

-- Measured once per row, on its own thread: the first measure of a text yields.
function ui.measureTooltip(entry)
	if entry.Measuring then return end
	entry.Measuring = true
	task.spawn(function()
		local font = uipallet.FontMedium or uipallet.Font
		local bounds = getfontbounds(entry.Text, tooltip.TextSize, font)
		-- Wrapped the way the label wraps it, word by word, so the pill is as tall as its text.
		local lines, line = 1, ''
		if bounds.X > 340 then
			for word in entry.Text:gmatch('%S+') do
				local candidate = line == '' and word or line..' '..word
				if line ~= '' and getfontbounds(candidate, tooltip.TextSize, font).X > 340 then
					lines += 1
					line = word
				else
					line = candidate
				end
			end
		end
		-- How wide the title's own text is, for a label wider than its words.
		local title = entry.Title
		if title and title:IsA('TextLabel') then
			entry.TitleWidth = getfontbounds(title.Text, title.TextSize, title.FontFace).X
		end
		entry.Wrapped = lines > 1
		entry.Size = Vector2.new(math.min(bounds.X, 340) + 18, math.max(20, bounds.Y * lines + 6))
		ui.refreshTooltip()
	end)
end

--[[ A tap enters a row the way a pointer does, and nothing moves the pointer off it again, so on a
touch screen the pill stayed up after every tap until the next one elsewhere. No hover help there. ]]
function ui.lastInputTouch()
	local ok, last = pcall(function()
		return inputService:GetLastInputType()
	end)
	return ok and last == Enum.UserInputType.Touch
end

-- Puts the pill on the switch of the title the pointer is on, or away when it is on none.
function ui.refreshTooltip()
	local current, entry
	if tooltipsEnabled and clickgui and clickgui.Visible and not (layout and layout.ListOpen) and not ui.lastInputTouch() then
		--[[ The pointer is measured from the top of the screen, but the positions the rows report
		are measured from the GUI's own origin, under Roblox's top bar; the menu's own position in
		that space is the difference. ]]
		local point = inputService:GetMouseLocation() + scaledgui.AbsolutePosition
		for gui, candidate in ui.tooltipHovered do
			if not (gui.Parent and ui.within(point, gui.AbsolutePosition, gui.AbsoluteSize)) then
				-- A leave that never came: the pointer is not on it, so it is no candidate.
				ui.tooltipHovered[gui] = nil
			elseif not current and ui.rowShowing(gui, point) then
				if not candidate.Size then
					ui.measureTooltip(candidate)
				else
					-- Only the title's words count, not the whole row.
					local title = candidate.Title or gui
					local corner, size = title.AbsolutePosition, title.AbsoluteSize
					if candidate.TitleWidth and title.Size.Y.Offset > 0 then
						size = Vector2.new(math.min(size.X, candidate.TitleWidth * size.Y / title.Size.Y.Offset), size.Y)
					end
					if ui.within(point, corner, size) then
						current, entry = gui, candidate
					end
				end
			end
		end
	end
	if not current then
		ui.tooltipShown = nil
		tooltip.Visible = false
		return
	end

	ui.tooltipShown = current
	tooltip.Text = entry.Text
	tooltip.TextWrapped = entry.Wrapped
	tooltip.Size = UDim2.fromOffset(entry.Size.X, entry.Size.Y)
	local s = math.max(scale.Scale, 0.05)
	-- In the window's zoom as well as the menu's scale, the size the rows it explains are drawn at.
	local zoom = ui.tooltipZoom and layout and layout.Zoom or 1
	if ui.tooltipZoom then
		ui.tooltipZoom.Scale = zoom
	end
	local width, height = entry.Size.X * zoom, entry.Size.Y * zoom
	local anchor = entry.Anchor and entry.Anchor.Parent and entry.Anchor or current
	--[[ Centred 4 px over the switch, as the slider's value sits over its knob, but never past the
	card's right edge; under the switch only at the top edge of the screen. Measured from the pill's
	own parent, so it lands where the switch really is. ]]
	local origin = tooltip.Parent and tooltip.Parent.AbsolutePosition or Vector2.zero
	local switchTop = (anchor.AbsolutePosition.Y - origin.Y) / s
	local switchCentre = (anchor.AbsolutePosition.X + anchor.AbsoluteSize.X / 2 - origin.X) / s
	local bound = entry.Bounds and entry.Bounds.Parent and entry.Bounds or current
	local rowRight = (bound.AbsolutePosition.X + bound.AbsoluteSize.X - origin.X) / s
	local left = math.min(switchCentre - width / 2, rowRight - width - 4)
	local top = switchTop - height - 4
	if top < 4 then
		top = switchTop + anchor.AbsoluteSize.Y / s + 4
	end
	left = math.clamp(left, 4, math.max(viewportWidth() / s - width - 4, 4))
	tooltip.Position = UDim2.fromOffset(left, top)
	tooltip.Visible = true
end

local function createSignal()
	local signal = {
		Connections = {}
	}

	function signal:Connect(callback)
		table.insert(self.Connections, callback)

		return {
			Disconnect = function()
				local index = table.find(signal.Connections, callback)
				if index then
					table.remove(signal.Connections, index)
				end
			end
		}
	end

	function signal:Fire(...)
		for _, callback in self.Connections do
			task.spawn(callback, ...)
		end
	end

	return signal
end

local function checkKeybinds(compare, target, key)
	if type(target) == 'table' then
		if table.find(target, key) then
			for _, key in target do
				if not table.find(compare, key) then
					return false
				end
			end

			return true
		end
	end

	return false
end

local function getTableSize(dict)
	local size = 0
	for _ in dict do
		size += 1
	end

	return size
end

local function loopClean(obj)
	for index, value in obj do
		if type(value) == 'table' then
			loopClean(value)
		end

		obj[index] = nil
	end
end

local function randomString()
	local array = {}
	for i = 1, math.random(10, 100) do
		array[i] = string.char(math.random(32, 126))
	end

	return table.concat(array)
end

-- The second copy of removeTags that stood here is gone. It shadowed the identical one
-- defined near the top of the file for everything below it, and -- lacking that one's
-- wrapping parentheses -- returned gsub's replacement COUNT as a second value, so any
-- caller passing it straight into another function would have handed over a stray number.

--[[
	This is the only native call this GUI makes, and it fires exactly when the menu opens.

	SetRobloxGuiFocused hands the client a flag that switches on its OWN full-screen blur behind
	the core UI. That is not a Roblox instance being drawn -- it is a GPU pass the engine runs
	every frame over the whole framebuffer, and it is the one thing in the open path capable of
	killing a client outright rather than throwing a Lua error. A Lua error prints red and the
	game carries on; a crash on open is native, and this is the only native surface here.

	Not on touch devices, where the cost is highest and where the older client mobile executors
	ship does not have the method at all. Those get setMobileBlur below instead -- the toggle
	used to be dead on a phone because this function bailed before doing anything.

	pcall'd on top: the method is executor- and client-version dependent, and a throw here used
	to abort whichever handler called it -- which includes the one that opens the menu.
]]
local lighting = cloneref(game:GetService('Lighting'))
local mobileBlur

--[[
	The blur a phone gets.

	SetRobloxGuiFocused is off the table there (see above), so 'Blur background' did nothing on
	every mobile executor -- the toggle saved, flipped, and had no effect.

	A BlurEffect is a plain instance every client can create, and it needs no native call and no
	elevated thread. It blurs the world behind the menu rather than the core UI, which is what
	the toggle's own description promises and close enough to what the desktop path draws.

	Destroyed rather than parked at Size 0 when the menu closes, so nothing of ours sits in
	Lighting while the GUI is shut -- and, since it is a fresh instance each time, a client that
	wipes Lighting between rounds cannot leave the toggle pointing at a dead effect.
]]
local function setMobileBlur(enabled)
	if enabled then
		if mobileBlur and mobileBlur.Parent then return end

		local created, effect = pcall(Instance.new, 'BlurEffect')
		if not created then return end

		effect.Name = randomString()
		effect.Size = 18
		effect.Parent = lighting
		mobileBlur = effect
	elseif mobileBlur then
		pcall(function()
			mobileBlur:Destroy()
		end)
		mobileBlur = nil
	end
end

function vape:BlurCheck()
	-- self.Blur is the toggle, and it does not exist yet the first time the settings pane is
	-- built -- every read of it goes through this, not just the mobile one.
	-- Not while the HUD is being moved (Move HUD): the menu stays open then only to drag things.
	local open = clickgui.Visible and not (layout and layout.MovingHud)
	local wanted = open and self.Blur ~= nil and self.Blur.Enabled

	if inputService.TouchEnabled or not self.ThreadFix then
		setMobileBlur(wanted)
		return
	end

	setthreadidentity(8)
	pcall(function()
		runService:SetRobloxGuiFocused((open or guiService:GetErrorType() ~= Enum.ConnectionError.OK) and self.Blur.Enabled)
	end)
end

function vape:CreateCategory(props)
	return components.Category(props)
end

function vape:CreateCategoryList(props)
	return components.CategoryList(props)
end

--[[
	A notification is a pill in the bottom-right corner, or the top-left one Slinky uses (the
	Notifications card's Position): an uppercase tag in the accent (green for a success, yellow
	for a warning, red for an alert) and the message beside it. Same signature, same folder and
	same Notifications toggle as before; the rich text callers send is drawn as written.
]]
local NOTIFICATION_HEIGHT = 36
local NOTIFICATION_GAP = 8

--[[ How far the pills ahead of the index-th one reach from the corner, in the HUD's units: each one's
own span (its height and the gap, at the zoom it was drawn at -- a wrapped message is taller), or a
one-line pill's for any not built yet. ]]
local function notificationOffset(index)
	local before = 0
	local list = ui.showingNotifications()
	for position = 1, index - 1 do
		local notif = list[position]
		before += notif and notif:GetAttribute('Span') or (NOTIFICATION_HEIGHT + NOTIFICATION_GAP) * ui.hudZoom()
	end
	return before
end

--[[ Where the index-th notification sits, stacked away from its corner, as an AnchorPoint and a
Position. Hidden is the same row slid off the screen edge it comes in from. The top-left stack
starts under Roblox's top bar, which this ScreenGui draws over. The margins grow with the phone zoom
the pills are drawn at. ]]
function ui.notificationPlace(index, hidden, before)
	local zoom = ui.hudZoom()
	before = before or notificationOffset(index)
	if layout and layout.NotifyTop then
		local y = ui.insetUnits() + 12 * zoom + before
		if hidden then
			return Vector2.new(1, 0), UDim2.new(0, -24, 0, y)
		end
		return Vector2.zero, UDim2.new(0, 16 * zoom, 0, y)
	end
	local y = -(16 * zoom + before)
	if hidden then
		return Vector2.new(0, 1), UDim2.new(1, 24, 1, y)
	end
	return Vector2.new(1, 1), UDim2.new(1, -16 * zoom, 1, y)
end

--[[ The notifications still showing, oldest first. Ordered by the number each was given when it
was asked for, not by when its frame was built: those are built a resumption later, and two asked
for together (a profile load sends a pair) are not built in a guaranteed order. ]]
function ui.showingNotifications()
	local list = {}
	for _, notif in notifications:GetChildren() do
		if not notif:GetAttribute('Leaving') then
			table.insert(list, notif)
		end
	end
	table.sort(list, function(a, b)
		return (a:GetAttribute('Order') or 0) < (b:GetAttribute('Order') or 0)
	end)
	return list
end

-- Moves every notification still showing to its place, after one arrives or leaves or the corner changes.
--[[ Asked for by every arrival and departure, and by the Position option: run once at the end of
the frame however many asked, so a burst moves each pill once instead of once per pill. ]]
function ui.restackNotifications()
	if ui.restackQueued then return end
	ui.restackQueued = true
	task.defer(function()
		ui.restackQueued = false
		if vape.ThreadFix then
			setthreadidentity(8)
		end
		pcall(ui.restackNow)
	end)
end

function ui.restackNow()
	local before = 0
	for index, notif in ui.showingNotifications() do
		local anchor, position = ui.notificationPlace(index, false, before)
		before += notif:GetAttribute('Span') or (NOTIFICATION_HEIGHT + NOTIFICATION_GAP) * ui.hudZoom()
		if tween.Tween then
			tween:Tween(notif, TweenInfo.new(0.35, Enum.EasingStyle.Exponential), {
				AnchorPoint = anchor,
				Position = position
			})
		end
	end
end

--[[ How tall a message has to be to fit within `width`: one line, or the lines it wraps to. Measured
wrapped by the text service when it can; counted from the one-line width when that fails. ]]
function ui.wrappedHeight(text, size, face, width)
	local single = getfontbounds(text, size, face)
	if single.X <= width then return single.Y, false end
	local lines
	pcall(function()
		local params = ui.wrapParams or Instance.new('GetTextBoundsParams')
		ui.wrapParams = params
		params.Text = text
		params.Size = size
		params.Font = face
		params.Width = width
		local wrapped = textService:GetTextBoundsAsync(params)
		if wrapped.X <= width + 1 and wrapped.Y > single.Y then
			lines = math.floor(wrapped.Y / math.max(single.Y, 1) + 0.5)
		end
	end)
	lines = lines or math.ceil(single.X / (width * 0.9))
	return single.Y * math.clamp(lines, 2, 4), true
end

function vape:CreateNotification(title, text, duration, type)
	if not self.Notifications.Enabled then
		return
	end

	layout.NotifySeq = (layout.NotifySeq or 0) + 1
	local order = layout.NotifySeq
	task.delay(0, function()
		if self.ThreadFix then
			setthreadidentity(8)
		end

		duration = tonumber(duration) or 3
		local accent = type == 'alert' and theme.Red or type == 'warning' and theme.Yellow or type == 'success' and theme.Green or theme.Accent()

		--[[ The title is the tag when it is a name ('Pistonware', 'AutoWin'). A sentence passed as
		the title -- the profile swap sends 'Profile swap to <name>' -- would be cut off in the tag,
		so it leads the message instead, under the usual tag. ]]
		local plainTitle = removeTags(tostring(title or 'Pistonware'))
		if #plainTitle > 18 or tostring(title):find('<', 1, true) then
			text = tostring(title)..'  <font color="#a2a19d">'..tostring(text or '')..'</font>'
			plainTitle = 'Pistonware'
		elseif plainTitle:lower() == 'vape' then
			plainTitle = 'Pistonware'
		end
		local tagText = plainTitle:upper()

		--[[ Never wider than the screen: a long message wraps onto more lines (four at most) instead of
		running one line off a phone's edge, and is kept to a readable width on a monitor too. ]]
		local zoom = ui.hudZoom()
		local messageHeight, wraps, messageWidth = NOTIFICATION_HEIGHT, false, 0
		pcall(function()
			local available = viewportWidth() / (math.max(scale.Scale, 0.05) * zoom) - 40
			local tagWidth = getfontbounds(tagText, 12, fonts.face('Bold')).X + 18
			messageWidth = math.floor(math.clamp(available - tagWidth - 32, 140, 560))
			local height
			height, wraps = ui.wrappedHeight(removeTags(tostring(text or '')), 15, fonts.face('Medium'), messageWidth)
			if wraps then
				messageHeight = math.max(NOTIFICATION_HEIGHT, math.ceil(height) + 14)
			end
		end)

		local index = 1
		for _, notif in notifications:GetChildren() do
			if not notif:GetAttribute('Leaving') and (notif:GetAttribute('Order') or 0) < order then
				index += 1
			end
		end
		local hiddenAnchor, hiddenPosition = ui.notificationPlace(index, true)
		local notification = ui.new('Frame', {
			AnchorPoint = hiddenAnchor,
			AutomaticSize = Enum.AutomaticSize.X,
			BackgroundColor3 = theme.Bar,
			BackgroundTransparency = 0.04,
			BorderSizePixel = 0,
			Position = hiddenPosition,
			Size = UDim2.fromOffset(0, messageHeight),
			ZIndex = 5
		})
		notification:SetAttribute('Order', order)
		notification:SetAttribute('Span', (messageHeight + NOTIFICATION_GAP) * zoom)
		-- The phone zoom; a pill lives a few seconds, so it keeps the zoom it was drawn at.
		ui.hudScale(notification, true)
		notification.Parent = notifications
		ui.corner(notification, wraps and UDim.new(0, 18) or UDim.new(1, 0))
		ui.stroke(notification, theme.Outline, 1, 0.55)
		ui.padding(notification, 6, 16, 0, 0)
		ui.list(notification, 10, true)

		local tagLabel = ui.text(notification, {Text = tagText, Size = 12, Weight = 'Bold', Color = accent, AlignX = Enum.TextXAlignment.Center, Props = {
			AutomaticSize = Enum.AutomaticSize.X,
			BackgroundColor3 = theme.Tint(accent, 0.22),
			BackgroundTransparency = 0,
			LayoutOrder = 1,
			Size = UDim2.fromOffset(0, 24),
			ZIndex = 5
		}})
		ui.corner(tagLabel, 6)
		ui.padding(tagLabel, 9, 9, 0, 0)

		local message = ui.text(notification, {Text = tostring(text or ''), Size = 15, Weight = 'Medium', Color = theme.Text, Props = {
			AutomaticSize = wraps and Enum.AutomaticSize.None or Enum.AutomaticSize.X,
			LayoutOrder = 2,
			RichText = true,
			Size = UDim2.fromOffset(wraps and messageWidth or 0, messageHeight),
			TextWrapped = wraps,
			ZIndex = 5
		}})
		message.TextYAlignment = Enum.TextYAlignment.Center

		-- In from its edge, and any that were asked for after it but built first move down a place.
		ui.restackNotifications()

		task.delay(duration, function()
			-- Out the way it came in, at the height it is at now; the others close up behind it.
			notification:SetAttribute('Leaving', true)
			if tween.Tween then
				local anchor, position = ui.notificationPlace(1, true)
				tween:Tween(notification, TweenInfo.new(0.35, Enum.EasingStyle.Exponential), {
					AnchorPoint = anchor,
					Position = UDim2.new(position.X.Scale, position.X.Offset, notification.Position.Y.Scale, notification.Position.Y.Offset)
				}, 'tweenstwo')
			end

			task.wait(0.25)
			notification:ClearAllChildren()
			notification:Destroy()
		end)
	end)
end

function vape:CreateOverlay(props)
	return components.Overlay(props)
end

local function migrateKillauraRange(data)
	local modules = type(data) == 'table' and data.Modules
	local options = type(modules) == 'table' and type(modules.Killaura) == 'table'
		and modules.Killaura.Options
	if type(options) == 'table' and options['Swing range'] and not options['Scan range'] then
		options['Scan range'] = options['Swing range']
	end
end

function vape:Load(skipgui, profile)
	--[[
		Applying a profile yields now (see yieldBuild), so this can be interrupted -- by a profile
		switch, or by the late pass that runs when a slow payload finally finishes registering.
		Both call Load, and two overlapping walks writing into the same modules would leave a
		mixture of the two profiles applied.

		So each load claims a generation, and checks after every yield that it is still the
		current one. The older walk stops where it stands and the newer one owns the result.
	]]
	self.LoadGeneration += 1
	local generation = self.LoadGeneration
	-- Nothing may write to disk while a load is in progress: it would serialise a config that is
	-- half the old profile and half the new one. Restored at the end.
	self.Loaded = false
	-- Read by the module toggles, which defer a module's function instead of running it inline
	-- while this is set. Deliberately NOT cleared on the generation-abort returns below: those
	-- happen because a newer load took over, and that load owns the flag until it finishes.
	self.Applying = true
	local guiData = {Categories = {}}
	local oldProfile = self.Profile
	local canSave = true
	local toggleCount = 0

	if isfile('pistonware/profiles/'..game.GameId..'.gui.txt') then
		guiData = loadJson('pistonware/profiles/'..game.GameId..'.gui.txt')
		if not guiData then
			guiData = {Categories = {}}
			self:CreateNotification('Vape', 'Failed to load GUI settings.', 10, 'alert')
			canSave = false
		end

		if guiData.v ~= 1 then
			guiData.Categories.Main = nil
		end

		self.Profile = profile or guiData.Profile or 'default'
		--[[ The last line of defence, and the one that matters most: this is read straight out of
		gui.txt, so a file already carrying a bad name has to be survivable. Falling back here is
		what lets a client that is crashing on every inject boot once more and write a sane file. ]]
		if not usableProfileName(self.Profile) then
			self.Profile = 'default'
		end
		if self.ProfileLabel then
			self.ProfileLabel.Text = #self.Profile > 10 and self.Profile:sub(1, 10)..'...' or self.Profile
			self.ProfileLabel.Size = UDim2.fromOffset(getfontbounds(self.ProfileLabel.Text, self.ProfileLabel.TextSize, self.ProfileLabel.Font).X + 16, 24)
		end

		if not skipgui then
			for name, data in guiData.Categories do
				local category = self.Categories[name]
				if category then
					category:Load(data)
				end
			end
		end
	end

	if not self.Categories.Profiles:GetValue('default') then
		self.Categories.Profiles:ChangeValue('default', true)
	end

	if isfile('pistonware/profiles/'..self.Profile..self.Place..'.txt') then
		local mainData = loadJson('pistonware/profiles/'..self.Profile..self.Place..'.txt')
		if not mainData then
			mainData = {Categories = {}, Modules = {}, Legit = {}}
			self:CreateNotification('Vape', 'Failed to load '..self.Profile..' profile.', 10, 'alert')
			canSave = false
		end
		migrateKillauraRange(mainData)

		if mainData.v ~= 1 then
			for _, data in mainData.Modules do
				data.Bind = {Keys = data.Bind}
				data.Visible = true
			end
		end

		-- PromptChanger combines the two older proximity-prompt modules. Merge their
		-- saved options before the normal module pass so existing profiles keep working.
		do
			local modules = mainData.Modules
			local promptData = modules.PromptChanger or modules.FastProxPrompt or modules.InteractExtender
			if promptData then
				promptData.Options = promptData.Options or {}
				local fastOptions = modules.FastProxPrompt and modules.FastProxPrompt.Options or {}
				local extenderOptions = modules.InteractExtender and modules.InteractExtender.Options or {}
				for _, option in {'Mode', 'Modifier'} do
					if fastOptions[option] and not promptData.Options[option] then
						promptData.Options[option] = fastOptions[option]
					end
				end
				if extenderOptions.Range and not promptData.Options.Range then
					promptData.Options.Range = extenderOptions.Range
				end
				modules.PromptChanger = promptData
				modules.FastProxPrompt = nil
				modules.InteractExtender = nil
			end
		end

		for name, data in mainData.Categories do
			local category = self.Categories[name]
			if category then
				category:Load(data)
				yieldBuild()
				if self.LoadGeneration ~= generation then return end
			end
		end

		for name, data in mainData.Modules do
			local module = self.Modules[name]
			if module then
				module:Load(data)
				toggleCount += module.Enabled and 1 or 0
				yieldBuild()
				if self.LoadGeneration ~= generation then return end
			end
		end

		for name, data in mainData.Legit do
			local module = self.Legit.Modules[name]
			if module then
				module:Load(data)
				yieldBuild()
				if self.LoadGeneration ~= generation then return end
			end
		end

		self:UpdateTextGUI(true)
	else
		-- Creation is deferred until main.lua confirms a complete boot. Writing here would
		-- serialize only the modules registered so far when a game payload failed or yielded.
		self.PendingProfileCreate = canSave and true or nil
	end

	if canSave then
		self:CreateNotification('Pistonware', 'Loaded profile '..self.Profile, 3, 'success')
		self:CreateNotification('Pistonware', 'Enabled '..toggleCount..(toggleCount == 1 and ' mod' or ' mods'), 3)
	end

	if self.Downloader then
		self.Downloader:Destroy()
		self.Downloader = nil
	end

	self.Loaded = canSave
	self.Applying = nil
	-- Everything registered up to here now holds its saved settings. vape:LoadLate applies the
	-- profile to whatever appears past this index.
	self.LoadedCount = #self.ModuleOrder
	--[[
		Drop the pending save rather than flushing it, because there is nothing to write.

		Applying a profile toggles every module in it, and every one of those toggles asked for a
		save. All of them are redundant by construction: the state they would serialise is the
		state that was just read off disk, so the write is the file being copied back onto itself.

		Flushing them put a full serialise and two file writes into the single most loaded instant
		of the session -- the moment Load returns, sixty module functions start their loops for
		the first time, and the client has the least headroom it will ever have.

		The cost is a toggle flipped BY HAND during the second or so a load takes, which is
		dropped instead of written. The next change to anything saves it, and losing a toggle from
		a one-second window is not worth what flushing it costs.
	]]
	self.SaveNeeded = nil
	if self.PendingProfileCreate and self:CanSave() then
		self.PendingProfileCreate = nil
		self:RequestSave()
	end

	-- Normally already there from LoadGUI; see EnsureVapeButton.
	if not skipgui then
		self:EnsureVapeButton()
	end

	--[[ `toggleData` was undeclared; return the module toggle count used by the notification. ]]
	return toggleCount, canSave
end

--[[ The on-screen button that opens the GUI. isMobile, not TouchEnabled: it exists because a
phone has no keyboard to press the GUI bind with, and a Mac reporting touch does have one.

Built at the end of LoadGUI, not only at the end of Load. Load is the profile apply, and a
session can go without one finishing: main.lua skips it outright when the game payload fails or
does not signal completion within 120s, a module whose Load throws aborts it part way, and a
LoadLate or profile swap that moves LoadGeneration mid-apply returns from it early. Each of those
left a phone with no button and so no way into the menu at all. Calling it again is harmless: a
button that is still parented is kept. ]]
function vape:EnsureVapeButton()
	if not (isMobile() and gui) then return end
	if self.VapeButton and self.VapeButton.Parent then return end

	-- The loader's >_ badge: its dark tile, its console face in its orange, and its grey border.
	local button = Instance.new('TextButton')
	button.AutoButtonColor = false
	button.BackgroundColor3 = Color3.fromRGB(22, 22, 22)
	button.BackgroundTransparency = 0
	button.BorderSizePixel = 0
	button.FontFace = Font.fromEnum(Enum.Font.Code)
	button.Position = vapeButtonFallback
	button.Size = UDim2.fromOffset(vapeButtonSize, vapeButtonSize)
	button.Text = '>_'
	button.TextColor3 = Color3.fromRGB(240, 122, 31)
	button.TextSize = 15
	button.Parent = gui
	addCorner(button, UDim.new(0, 8))
	local stroke = Instance.new('UIStroke')
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Color = Color3.fromRGB(52, 52, 52)
	stroke.Thickness = 1
	stroke.Parent = button
	anchorVapeButton(button)

	self.VapeButton = button
	self.VapeButtonStroke = stroke
	self.VapeButtonTransparency = button.BackgroundTransparency
	--[[ Honour the saved setting on a button built after the options loaded; when the
	button comes first, the toggle's own Function applies it on load. Transparency rather
	than Visible: see HideVapeButton. ]]
	if self.HideVapeButton and self.HideVapeButton.Enabled then
		button.BackgroundTransparency = 1
		button.TextTransparency = 1
		stroke.Transparency = 1
	end
	-- The Mod Overlay keeps clear of the button, so it is placed again now there is one.
	pcall(ui.applyHudZoom)

	button.MouseButton1Click:Connect(function()
		if self.GUIBind then
			self.GUIBind.Triggered:Fire(true)
		end
	end)
end

--[[
	Apply the current profile to modules that registered after it was loaded.

	The payload is the reason this exists. A protected bedwars.lua can still be registering when
	the profile is applied -- either because it never signals that it is done, or because it took
	longer than the backstop -- and every module that arrives afterwards would otherwise sit on
	its defaults with its real settings still on disk, untouched.

	Only the tail of ModuleOrder is touched: index LoadedCount + 1 onwards is exactly the set that
	has never been loaded. Modules the user changed by hand are earlier in the array and are not
	revisited, which is what makes running this at an arbitrary later moment safe -- the blanket
	re-apply that used to be rejected here reverted those changes because it walked all of them.
]]
function vape:LoadLate()
	if shared.PistonwareBootFailed or not self.Profile then return 0 end

	local path = 'pistonware/profiles/'..self.Profile..self.Place..'.txt'
	if not isfile(path) then return 0 end

	local mainData = loadJson(path)
	if type(mainData) ~= 'table' or type(mainData.Modules) ~= 'table' then return 0 end
	migrateKillauraRange(mainData)

	self.LoadGeneration += 1
	local generation = self.LoadGeneration
	self.Applying = true
	local order = self.ModuleOrder
	local first = (self.LoadedCount or 0) + 1
	local applied = 0

	for index = first, #order do
		local module = order[index]
		local data = module and mainData.Modules[module.Name]
		if data then
			pcall(module.Load, module, data)
			applied += 1
			yieldBuild()
			if self.LoadGeneration ~= generation then return applied end
		end
	end

	self.LoadedCount = #order
	self.Applying = nil
	return applied
end

function vape:LoadOptions(obj, data)
	-- Every option saves a table; anything else in a hand-edited or older file is passed over,
	-- rather than throwing and stopping the whole profile part way through.
	if type(data) ~= 'table' or type(obj.Options) ~= 'table' then return end
	for name, componentData in data do
		local component = obj.Options[name]

		if component and type(componentData) == 'table' then
			component:Load(componentData)
		end
	end
end

--[[
	LoadGUI, split into the pieces it builds. One function per piece keeps every one of them well
	clear of Luau's 200-register limit, which the single LoadGUI was sitting right against.
]]
local build = {}

function build.root()
	addMaid(vape)
	gui = Instance.new('ScreenGui')
	gui.Name = randomString()
	gui.DisplayOrder = 9999999
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.IgnoreGuiInset = true

	if vape.ThreadFix then
		--[[ Recent property; older clients throw on the assignment rather than ignoring it. ]]
		pcall(function() gui.OnTopOfCoreBlur = true end)
		--[[
			CoreGui on touch devices, gethui elsewhere.

			Mobile executors' gethui hands back a hidden container the client itself owns and
			reclaims: it gets emptied out from under the script, and a ScreenGui whose parent is
			destroyed underneath it is a straightforward way to take the client with it. Kept on
			desktop, where it works and is the more discreet parent of the two.
		]]
		local hidden = (not inputService.TouchEnabled) and gethui and select(2, pcall(gethui)) or nil
		--[[ A ScreenGui is no container for another ScreenGui. Some executors' gethui hands back
		CoreGui.RobloxGui itself, and a menu nested inside another LayerCollector cannot be relied
		on to draw at all. ]]
		if typeof(hidden) ~= 'Instance' or hidden:IsA('LayerCollector') then
			hidden = nil
		end
		--[[ Neither parent is guaranteed. CoreGui reads back nil below the executor's full
		identity, and a write into it can be refused outright. PlayerGui always works. ]]
		local parented = pcall(function()
			gui.Parent = hidden or cloneref(game:GetService('CoreGui'))
		end) and gui.Parent ~= nil
		if not parented then
			gui.Parent = cloneref(game:GetService('Players')).LocalPlayer.PlayerGui
			gui.ResetOnSpawn = false
		end
		--[[ Nothing reads this folder; it is only removed again on uninject. ]]
		local holder = Instance.new('Folder')
		if pcall(function() holder.Parent = cloneref(game:GetService('CoreGui')) end) then
			vape.holder = holder
		else
			holder:Destroy()
			vape.holder = gui
		end
	else
		gui.Parent = cloneref(game:GetService('Players')).LocalPlayer.PlayerGui
		gui.ResetOnSpawn = false
		vape.holder = gui
	end
	vape.gui = gui

	scaledgui = Instance.new('Frame')
	scaledgui.BackgroundTransparency = 1
	scaledgui.Name = 'ScaledGui'
	scaledgui.Size = UDim2.fromScale(1, 1)
	scaledgui.Parent = gui
	clickgui = Instance.new('Frame')
	clickgui.BackgroundTransparency = 1
	clickgui.Name = 'ClickGui'
	clickgui.Size = UDim2.fromScale(1, 1)
	clickgui.Visible = false
	--[[ Above the HUD windows and legit widgets (ZIndex 2): where one overlaps the menu, the menu
	is what gets drawn and touched. The dim layer is a sibling at 0, so everything else on the
	HUD stays bright and draggable around the window. ]]
	clickgui.ZIndex = 3
	clickgui.Parent = scaledgui
	--[[ Mirrored as a plain field for the modules' GUI checks. On ThreadFix executors this
	gui sits under gethui/CoreGui, and reading the Instance from a module loop -- a thread
	a profile apply or a GUI click started, without the raised identity -- throws. A
	table field reads the same from any thread. Kept current by the Visible watcher. ]]
	vape.ClickGuiOpen = false
	local modal = Instance.new('TextButton')
	modal.BackgroundTransparency = 1
	modal.Modal = true
	modal.Text = ''
	modal.Parent = clickgui
	vape.Cursor = Instance.new('ImageLabel')
	vape.Cursor.BackgroundTransparency = 1
	vape.Cursor.Image = 'rbxasset://textures/Cursors/KeyboardMouse/ArrowFarCursor.png'
	vape.Cursor.Size = UDim2.fromOffset(64, 64)
	vape.Cursor.Visible = false
	vape.Cursor.ZIndex = 50
	vape.Cursor.Parent = gui
	notifications = Instance.new('Folder')
	notifications.Name = 'Notifications'
	notifications.Parent = scaledgui
	tooltip = ui.text(scaledgui, {Text = '', Size = 14, Color = theme.Text, AlignX = Enum.TextXAlignment.Center, Props = {
		BackgroundColor3 = theme.Pill,
		BackgroundTransparency = 0,
		Position = UDim2.fromScale(-1, -1),
		RichText = true,
		Visible = false,
		ZIndex = 40
	}})
	ui.corner(tooltip, 5)
	ui.padding(tooltip, 9, 9, 0, 0)
	-- The window's zoom, set where the pill is placed (refreshTooltip).
	ui.tooltipZoom = ui.new('UIScale', {Scale = 1}, tooltip)
	-- Closing the menu under a hovered row sends no leave, so the pill is put away here.
	vape:Clean(clickgui:GetPropertyChangedSignal('Visible'):Connect(function()
		table.clear(ui.tooltipHovered)
		ui.refreshTooltip()
	end))
	--[[ The pointer moving or the page scrolling re-decides which row the pill is on; while one is
	showing it is also re-checked a few times a second, for a row hidden or collapsed under a still
	pointer. ]]
	vape:Clean(inputService.InputChanged:Connect(function(input)
		if (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.MouseWheel)
			and (ui.tooltipShown or next(ui.tooltipHovered)) then
			ui.refreshTooltip()
		end
	end))
	local tooltipCheck = 0
	vape:Clean(runService.Heartbeat:Connect(function()
		if ui.tooltipShown and os.clock() >= tooltipCheck then
			tooltipCheck = os.clock() + 0.2
			ui.refreshTooltip()
		end
	end))
	scale = Instance.new('UIScale')
	scale.Scale = autoScaleValue()
	scale.Parent = scaledgui
	scaledgui.Size = UDim2.fromScale(1 / scale.Scale, 1 / scale.Scale)
	fonts.init()
end

function build.categories()
	components.GUI({})

	for _, name in {'Combat', 'Blatant', 'Render', 'Utility', 'World', 'Inventory'} do
		vape:CreateCategory({
			Name = name
		})
	end
	--[[ Minigames is not optional: bedwars.lua and several other place files put modules in it,
	and without the category those CreateModule calls index nil and take their game script
	down. ]]
	vape:CreateCategory({
		Name = 'Minigames'
	})

	--[[ games/6872274481.lua sizes two scrolling frames against the GUI's UIScale and reads it as
	vape.guiscale, which the old GUI exported under that name. Same object, same field. ]]
	vape.guiscale = scale
	vape.Categories.Main:CreateDivider({
		Text = 'misc'
	})
end

function build.lists()
	--[[
		Friends
	]]
	do
		local friends
		local friendscolor = {
			Hue = 1,
			Sat = 1,
			Value = 1
		}
	
		friends = vape:CreateCategoryList({
			Name = 'Friends',
			Size = UDim2.fromOffset(17, 16),
			Placeholder = 'Roblox username',
			Color = Color3.fromRGB(243, 93, 18),
			Function = function()
				friends.Update:Fire()
				friends.ColorUpdate:Fire(friendscolor.Hue, friendscolor.Sat, friendscolor.Value)
			end
		})
		friends.Update = Instance.new('BindableEvent')
		friends.ColorUpdate = Instance.new('BindableEvent')
		friends:CreateToggle({
			Name = 'Recolor visuals',
			Darker = true,
			Default = true,
			Function = function()
				friends.Update:Fire()
				friends.ColorUpdate:Fire(friendscolor.Hue, friendscolor.Sat, friendscolor.Value)
			end
		})
		friendscolor = friends:CreateColorSlider({
			Name = 'Friends color',
			Darker = true,
			Function = function(hue, sat, val)
				for _, v in friends.Object.Children:GetChildren() do
					local dot = v:FindFirstChild('Dot')
					if dot and dot.BackgroundColor3 ~= theme.Muted then
						dot.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
						dot.Dot.BackgroundColor3 = dot.BackgroundColor3
					end
				end
	
				friends.ColorUpdate:Fire(hue, sat, val)
			end
		})
		friends:CreateToggle({
			Name = 'Use friends',
			Darker = true,
			Default = true,
			Function = function()
				friends.Update:Fire()
				friends.ColorUpdate:Fire(friendscolor.Hue, friendscolor.Sat, friendscolor.Value)
			end
		})
		vape:Clean(friends.Update)
		vape:Clean(friends.ColorUpdate)
	end
	
	--[[
		Profiles
	]]
	local profilescategory = vape:CreateCategoryList({
		Name = 'Profiles',
		Size = UDim2.fromOffset(17, 10),
		Position = UDim2.fromOffset(12, 16),
		Placeholder = 'Type name',
		Profiles = true
	})


	-- Same reinject route the buttons in Settings > General use: the developer build lives on
	-- disk under its own name and must never be fetched from GitHub, and every other path goes
	-- back through the loader so the key gate re-runs.
	local function reinjectThroughLoader()
		if shared.PistonwareDeveloper and isfile('pistonware/loaderdev.lua') then
			loadstring(readfile('pistonware/loaderdev.lua'), 'loader')()
		else
			-- A loader that did not download used to be called as nil: the click errored, the menu
			-- stayed as it was, and nothing on screen said why.
			local ok, source = pcall(pistonwareHttpGet, 'https://raw.githubusercontent.com/themagicpiston/pistonware/main/loader.lua', true)
			local chunk = ok and type(source) == 'string' and loadstring(source, 'loader')
			if not chunk then
				vape:CreateNotification('Pistonware', 'Could not download the loader to reload. Run the loader again to load the config.', 15, 'alert')
				return false
			end
			chunk()
		end
	end

	--[[
		<GameId>.gui.txt is the GUI's state file, not a config: besides the theme and window
		layout it holds the equipped config and the profile LIST shown in the Profiles tab,
		custom ones included. Writing the repo's copy over it wipes every custom profile from
		that list and forces the equipped config back to whatever shipped.

		Where the list lives differs between the two GUIs, and this GUI is the one on disk now:
		the old file kept it at the top level as `Profiles`, this one keeps it at
		Categories.Profiles.List / .ListEnabled (see vape:Save). Both are carried across, so a
		repo copy written by either version merges correctly -- the theme still syncs, the
		user's own profiles stay local, and only shipped configs get replaced.
	]]
	local function mergeGuiState(path, content)
		local ok, merged = pcall(function()
			local new = httpService:JSONDecode(content)
			if type(new) ~= 'table' then return content end

			if isfile(path) then
				local old = httpService:JSONDecode(readfile(path))
				if type(old) == 'table' then
					if old.Profiles ~= nil then new.Profiles = old.Profiles end
					if old.Profile ~= nil then new.Profile = old.Profile end

					local oldprofiles = type(old.Categories) == 'table' and old.Categories.Profiles or nil
					if type(oldprofiles) == 'table' then
						new.Categories = type(new.Categories) == 'table' and new.Categories or {}
						local newprofiles = type(new.Categories.Profiles) == 'table' and new.Categories.Profiles or {}
						new.Categories.Profiles = newprofiles
						if oldprofiles.List ~= nil then newprofiles.List = oldprofiles.List end
						if oldprofiles.ListEnabled ~= nil then newprofiles.ListEnabled = oldprofiles.ListEnabled end
					end
				end
			end

			return httpService:JSONEncode(new)
		end)

		return (ok and type(merged) == 'string') and merged or content
	end

	--[[
		GitHub profile sync, shared by the Sync button and the Load Blatant / Load Legit buttons.

		Every API request goes through the executor's request function with a User-Agent, as
		loader.lua's own API calls do. api.github.com answers a request without one with a
		plain-text 403 ("Request forbidden by administrative rules"), and game:HttpGet sends none
		on some executors -- Potassium among them -- so the sync failed at its first request there
		and never downloaded anything. HttpGet stays as the fallback for executors without request.
	]]
	local profileSync = {
		Headers = {['User-Agent'] = 'pistonware', Accept = 'application/vnd.github+json'}
	}

	-- A short reason for the notification. The rate-limit message names the caller's IP, so it is
	-- replaced rather than shown.
	function profileSync.describe(status, body)
		local message
		pcall(function()
			local decoded = httpService:JSONDecode(body)
			if type(decoded) == 'table' and type(decoded.message) == 'string' then
				message = decoded.message
			end
		end)
		if message then
			if message:lower():find('rate limit', 1, true) then
				return 'GitHub rate limit reached, try again in a few minutes'
			end
			return 'GitHub: '..message:gsub('%d+%.%d+%.%d+%.%d+', '<ip>'):sub(1, 80)
		end
		return status and ('GitHub answered '..tostring(status)) or 'GitHub refused the request'
	end

	-- The body, or nil and why not. Never throws.
	function profileSync.get(url)
		local reason
		local ok, res = pcall(pistonwareRequest, {Url = url, Method = 'GET', Headers = profileSync.Headers})
		if ok and type(res) == 'table' and type(res.Body) == 'string' then
			local status = tonumber(res.StatusCode) or 200
			if status >= 200 and status < 300 and res.Body ~= '' then
				return res.Body
			end
			reason = profileSync.describe(status, res.Body)
		end
		local got, body = pcall(pistonwareHttpGet, url, true)
		if got and type(body) == 'string' and body ~= '' and body ~= '404: Not Found' then
			return body, reason
		end
		return nil, reason or 'could not reach GitHub'
	end

	function profileSync.json(url)
		local body, reason = profileSync.get(url)
		if not body then return nil, reason end
		local ok, decoded = pcall(function()
			return httpService:JSONDecode(body)
		end)
		if not (ok and type(decoded) == 'table') then
			return nil, reason or 'GitHub sent an unreadable response'
		end
		-- An error object that came through HttpGet, which hides the status code.
		if type(decoded.message) == 'string' then
			return nil, profileSync.describe(nil, body)
		end
		return decoded
	end

	-- pistonware/profiles is stamped with what it was last synced to (see run below).
	function profileSync.localStamp()
		local suc, res = pcall(readfile, 'pistonware/profiles/profilecommit.txt')
		if not (suc and type(res) == 'string') then return nil end
		res = res:gsub('%s', '')
		return res ~= '' and res or nil
	end

	-- Being current is not enough on its own: the sync exists to put both shipped configs for this
	-- place on disk, so a missing one has to let it through regardless.
	function profileSync.hasBothConfigs()
		return isfile('pistonware/profiles/blatant'..vape.Place..'.txt') and isfile('pistonware/profiles/legit'..vape.Place..'.txt')
	end

	-- The newest commit that touched profiles/, so every file below comes from one snapshot.
	function profileSync.latestCommit()
		local body, reason = profileSync.json('https://api.github.com/repos/themagicpiston/pistonware/commits?path=profiles&sha=main&per_page=1')
		if body and type(body[1]) == 'table' and type(body[1].sha) == 'string' then
			return body[1].sha
		end
		-- The API is out (rate limit, a blocked host). The branch head from git's own ref
		-- advertisement costs no API request and pins the files just as well.
		local refs = profileSync.get('https://github.com/themagicpiston/pistonware.git/info/refs?service=git-upload-pack')
		if refs then
			for line in refs:gmatch('[^\n]+') do
				local hex, ref = line:match('^(%x+) (%S+)')
				if ref then
					local nul = ref:find('\0', 1, true)
					if nul then ref = ref:sub(1, nul - 1) end
					if ref == 'refs/heads/main' and #hex >= 40 then
						return hex:sub(-40)
					end
				end
			end
		end
		return nil, reason
	end

	-- Every file in profiles/ at that commit, with the blob sha the stamp is made from.
	function profileSync.listFiles(commit)
		local body, reason = profileSync.json('https://api.github.com/repos/themagicpiston/pistonware/contents/profiles'..(commit and ('?ref='..commit) or ''))
		local files = {}
		if body then
			for _, v in body do
				if type(v) == 'table' and v.type == 'file' and type(v.path) == 'string' then
					table.insert(files, {path = v.path, sha = v.sha})
				end
			end
		end
		if #files > 0 then return files end
		-- The loader read the repository tree at the start of the session, and it names the same
		-- files. Their shas belong to that commit, so they are left out and make no stamp.
		local tree = shared.PistonwareRepoTree
		if type(tree) == 'table' and type(tree.tree) == 'table' then
			for _, v in tree.tree do
				if type(v) == 'table' and v.type == 'blob' and type(v.path) == 'string'
					and v.path:sub(1, 9) == 'profiles/' and not v.path:find('/', 10, true) then
					table.insert(files, {path = v.path})
				end
			end
		end
		if #files > 0 then return files end
		return nil, reason or 'the repo has no profiles'
	end

	--[[ The same stamp loader.lua writes: djb2 over the sorted path:sha of every file in
	profiles/, 'p1-' prefixed. This used to write the commit sha instead, which the loader reads
	as its old scheme and adopts without looking -- so after one sync from here, the loader's
	"sync to the latest config?" check never fired again, however much the profiles changed. ]]
	function profileSync.fingerprint(files)
		local parts = {}
		for _, v in files do
			if type(v.sha) ~= 'string' then return nil end
			table.insert(parts, v.path..':'..v.sha)
		end
		if #parts == 0 then return nil end
		table.sort(parts)
		local joined = table.concat(parts, '\n')
		local h = 5381
		for i = 1, #joined do
			h = (h * 33 + string.byte(joined, i)) % 4294967296
		end
		return ('p1-%08x'):format(h)
	end

	-- Pinned to the commit rather than the branch: raw.githubusercontent serves CDN-cached content
	-- for a few minutes after a push, so a branch fetch can quietly reinstall the old profiles.
	function profileSync.downloadFile(path, commit)
		local relPath = select(1, path:gsub('pistonware/', ''))
		local content
		for attempt = 1, 4 do
			local suc, res = pcall(function()
				return pistonwareHttpGet('https://raw.githubusercontent.com/themagicpiston/pistonware/'..(commit or 'main')..'/'..relPath, true, attempt)
			end)
			if suc and res and res ~= '' and res ~= '404: Not Found' then
				content = res
				break
			end
			if attempt < 4 then
				task.wait(attempt)
			end
		end
		if not content then return false end

		if path:find('%.gui%.txt$') then
			content = mergeGuiState(path, content)
		end

		return (pcall(writefile, path, content))
	end

	-- In parallel like the loader, joined on a deadline so one stuck request cannot hold the button.
	function profileSync.download(files, commit)
		local synced, failed = 0, 0
		local total = #files
		for _, v in files do
			task.spawn(function()
				local ok, got = pcall(profileSync.downloadFile, 'pistonware/'..({v.path:gsub(' ', '%%20')})[1], commit)
				if ok and got then
					synced += 1
				else
					failed += 1
				end
			end)
		end
		local deadline = os.clock() + 90
		while synced + failed < total and os.clock() < deadline do
			task.wait(0.05)
		end
		return synced, total - synced
	end

	--[[ How many files landed, or nil and why not. 0 means nothing was new: only the Load buttons
	ask for that check; the Sync button forces a fresh copy, which is what it says it does. ]]
	function profileSync.run(force)
		local commit, reason = profileSync.latestCommit()
		local files, listReason = profileSync.listFiles(commit)
		if not files then
			return nil, 'Profile sync failed ('..(listReason or reason or 'could not reach GitHub')..').'
		end
		local stamp = profileSync.fingerprint(files)
		if not force and stamp and stamp == profileSync.localStamp() and profileSync.hasBothConfigs() then
			return 0, 'Profiles are already up to date.'
		end
		local synced, failed = profileSync.download(files, commit)
		if synced <= 0 then
			return nil, 'Profile sync failed (nothing downloaded).'
		end
		-- Stamped only when every file landed, so a partial sync is retried next time.
		if stamp and failed == 0 then
			pcall(writefile, 'pistonware/profiles/profilecommit.txt', stamp)
		end
		return synced, 'Synced '..synced..' file'..(synced == 1 and '' or 's')..' from GitHub'..(failed > 0 and ' ('..failed..' failed).' or '.')
	end

	do
		local busy = false
		-- Set once a download lands. From then until a config is picked the buttons below own the
		-- reinject, so syncing and choosing stay one flow rather than two reloads.
		local pending, syncmessage = false, nil
		local refreshConfigButtons
		local extras = profilescategory.Extras
		local row = ui.new('Frame', {
			Name = 'SyncRow',
			BackgroundTransparency = 1,
			LayoutOrder = 1,
			Size = UDim2.new(1, 0, 0, 34)
		}, extras)
		ui.list(row, 8, true)

		local function pillButton(text, order, tip)
			local button = ui.text(row, {Class = 'TextButton', Text = text, Size = 14, Weight = 'Medium', Color = theme.Label, AlignX = Enum.TextXAlignment.Center, Props = {
				AutomaticSize = Enum.AutomaticSize.X,
				BackgroundColor3 = theme.Card,
				BackgroundTransparency = 0,
				LayoutOrder = order,
				Size = UDim2.fromOffset(0, 30)
			}})
			ui.corner(button, UDim.new(1, 0))
			ui.padding(button, 16, 16, 0, 0)
			local stroke = ui.stroke(button, theme.Outline, 1, 0.1)
			if tip then addTooltip(button, tip) end
			button.MouseEnter:Connect(function()
				button.BackgroundColor3 = theme.Raised
			end)
			button.MouseLeave:Connect(function()
				button.BackgroundColor3 = theme.Card
			end)
			return button, stroke
		end

		local syncbutton = pillButton('Sync profiles from GitHub', 1, 'Redownloads the shipped profiles, then pick a config to load one')
		syncbutton.Name = 'SyncProfiles'

		--[[ What is in memory is flushed first, then saving is held off for the download: a save
		queued by a toggle a moment earlier would otherwise land in the middle of it and write the
		pre-sync config back over the file just downloaded. Once anything has landed, saving stays
		off for the rest of the session -- the reload builds a fresh vape -- and otherwise it is put
		back as it was. ]]
		local function runSync(force)
			pcall(function() vape:Save() end)
			local wasBlocked = vape.SaveBlocked
			vape:BlockSaving()
			local ok, synced, message = pcall(profileSync.run, force)
			if not ok then
				synced, message = nil, 'Profile sync failed ('..tostring(synced)..').'
			end
			if synced and synced > 0 then
				vape.Save = function() end
				vape.SaveNeeded = nil
			else
				vape.SaveBlocked = wasBlocked
			end
			return synced, message
		end

		syncbutton.MouseButton1Click:Connect(function()
			if busy then return end
			busy = true
			syncbutton.Text = 'Syncing...'
			local synced, message = runSync(true)
			busy = false
			if not synced then
				syncbutton.Text = 'Sync profiles from GitHub'
				vape:CreateNotification('Pistonware', message, 10, 'alert')
				return
			end

			pending, syncmessage = true, message
			syncbutton.Text = 'Synced, choose a config'
			refreshConfigButtons()
			vape:CreateNotification('Pistonware', message..' Choose Blatant or Legit to load one.', 10)
		end)

		-- Which shipped config loads by default: simply the active profile, which Save records.
		local configbuttons = {}
		local function recolorProfileCards()
			local accent = theme.Accent()
			for name, entry in configbuttons do
				local selected = vape.Profile == name and not pending
				entry.Button.TextColor3 = selected and accent or theme.Label
				entry.Stroke.Color = selected and accent or theme.Outline
			end
		end
		vape.RecolorProfileCards = recolorProfileCards

		function refreshConfigButtons()
			for name, entry in configbuttons do
				-- A config can only be offered once its file is on disk.
				entry.Button.Visible = pending or isfile('pistonware/profiles/'..name..vape.Place..'.txt')
			end
			recolorProfileCards()
		end

		local function selectConfig(name)
			if busy then return end
			busy = true
			--[[ The newest shipped profiles are fetched first, so the config picked here is the one on
			GitHub rather than whatever copy is on disk. Skipped straight after the Sync button, which
			has just done exactly that. ]]
			if not pending then
				syncbutton.Text = 'Checking for new profiles...'
				local synced, message = runSync(false)
				if synced and synced > 0 then
					pending, syncmessage = true, message
				elseif not synced then
					vape:CreateNotification('Pistonware', message..' Loading the copy already on disk.', 10, 'alert')
				end
			end
			if not isfile('pistonware/profiles/'..name..vape.Place..'.txt') then
				busy = false
				syncbutton.Text = pending and 'Synced, choose a config' or 'Sync profiles from GitHub'
				refreshConfigButtons()
				vape:CreateNotification('Pistonware', 'There is no '..name..' config for this game yet, press Sync profiles first.', 10, 'alert')
				return
			end
			-- Always a full reload, never an in-place profile switch: the GUI state lives in
			-- <GameId>.gui.txt, which an in-place switch deliberately skips.
			pending = false
			syncbutton.Text = 'Reloading...'
			pcall(function() vape:Save() end)
			vape.Save = function() end
			vape.SaveNeeded = nil
			-- Save is off now and the reload reads the profile list back out of gui.txt, so the chosen
			-- config has to be written in there directly.
			pcall(function()
				local guipath = 'pistonware/profiles/'..game.GameId..'.gui.txt'
				local guidata = isfile(guipath) and loadJson(guipath)
				if type(guidata) ~= 'table' then return end
				guidata.Categories = type(guidata.Categories) == 'table' and guidata.Categories or {}
				local profiles = type(guidata.Categories.Profiles) == 'table' and guidata.Categories.Profiles or {}
				guidata.Categories.Profiles = profiles
				profiles.List = type(profiles.List) == 'table' and profiles.List or {}
				local listed = false
				for _, v in profiles.List do
					if type(v) == 'table' and v.Name == name then
						listed = true
						break
					end
				end
				if not listed then
					table.insert(profiles.List, {Name = name, Bind = {}})
				end
				guidata.Profile = name
				writefile(guipath, httpService:JSONEncode(guidata))
			end)
			-- nil unless a sync is being finished off, which is the only time main.lua should report one
			shared.PistonwareSyncResult = syncmessage
			shared.VapeCustomProfile = name
			shared.vapereload = true
			if reinjectThroughLoader() == false then
				-- Nothing reloaded. A reload flag left standing would make the next manual run headless,
				-- with no way to ask for a key. Saving stays off so nothing overwrites the new files.
				shared.vapereload = nil
				shared.VapeCustomProfile = nil
				busy = false
				syncbutton.Text = 'Sync profiles from GitHub'
			end
		end

		for index, config in {{Key = 'blatant', Text = 'Load Blatant'}, {Key = 'legit', Text = 'Load Legit'}} do
			local button, stroke = pillButton(config.Text, index + 1, 'Load the '..config.Key..' config by default')
			button.Name = config.Key
			configbuttons[config.Key] = {Button = button, Stroke = stroke}
			button.MouseButton1Click:Connect(function()
				selectConfig(config.Key)
			end)
		end

		-- Load is the one place that settles which profile is active, so the highlight follows it.
		local loadprofile = vape.Load
		function vape:Load(...)
			-- Every value Load returns is passed on: main.lua reads the second (canSave) to fail the boot.
			local results = table.pack(loadprofile(self, ...))
			refreshConfigButtons()
			return table.unpack(results, 1, results.n)
		end
		refreshConfigButtons()
	end

	--[[
		Profile import / export.

		A profile is one JSON file on disk (pistonware/profiles/<name><Place>.txt), so sharing
		one is only a matter of moving that file's text around. It travels inside an envelope
		rather than raw: the envelope carries the name it was exported under and the place it
		belongs to, which is what lets Import name the new file and warn when a config from a
		different game is pasted in. A raw config is still accepted -- pasting the file contents
		straight in is the obvious thing to try -- it just arrives without a name.

		Both directions go through the clipboard first and pistonware/exports second. Clipboard
		access is an executor extension and plenty of them do not have it, so the folder is not
		a fallback that only appears on failure: an export always writes it, and an import that
		finds nothing on the clipboard reads pistonware/exports/import.txt.
	]]
	local EXPORT_FOLDER = 'pistonware/exports'

	local function ensureFolder(path)
		local ok, exists = pcall(isfolder, path)
		if ok and exists then return end
		pcall(makefolder, path)
	end

	local function setClipboard(text)
		local setter = setclipboard or toclipboard or set_clipboard
		return setter ~= nil and (pcall(setter, text))
	end

	local function getClipboard()
		local getter = getclipboard or get_clipboard
		if not getter then return nil end
		local suc, res = pcall(getter)
		return (suc and type(res) == 'string' and res ~= '') and res or nil
	end

	--[[
		Exports are packed, because a phone cannot paste a big one.

		A profile for this place is ~15KB of JSON. On desktop that pastes fine; on mobile the
		on-screen keyboard truncates a paste that size, so what lands in the box is a broken
		fragment that fails to decode with nothing useful to say about why.

		LZW over the JSON, packed at 9-16 bits, then base64 -- roughly 2.3x smaller on a profile
		and 1.8x on a flag set. Base64 rather than the raw bytes because the packed form is
		binary, and a clipboard round trip through a TextBox is not binary-safe.

		Reading stays permissive: anything that is not marked with the prefix is treated as plain
		JSON, so an older export, a hand-written config and a flag set copied out of any other
		tool all still work. Only writing changed.
	]]
	local PACK_PREFIX = 'PW1|'
	local B64_CHARS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
	local b64Lookup

	local function base64Encode(data)
		local out = table.create(math.ceil(#data / 3) * 4)

		for index = 1, #data, 3 do
			local a, b, c = data:byte(index, index + 2)
			local n = a * 65536 + (b or 0) * 256 + (c or 0)
			local one = n // 262144
			local two = (n // 4096) % 64
			local three = (n // 64) % 64
			local four = n % 64
			out[#out + 1] = B64_CHARS:sub(one + 1, one + 1)
			out[#out + 1] = B64_CHARS:sub(two + 1, two + 1)
			out[#out + 1] = B64_CHARS:sub(three + 1, three + 1)
			out[#out + 1] = B64_CHARS:sub(four + 1, four + 1)
		end

		local text = table.concat(out)
		-- One or two bytes short of a group means one or two characters of that group are noise.
		local remainder = #data % 3
		if remainder == 1 then
			return text:sub(1, -3)..'=='
		elseif remainder == 2 then
			return text:sub(1, -2)..'='
		end
		return text
	end

	local function base64Decode(text)
		if not b64Lookup then
			b64Lookup = {}
			for index = 1, 64 do
				b64Lookup[B64_CHARS:sub(index, index)] = index - 1
			end
		end

		--[[ Padding and any whitespace a chat client wrapped the blob in are dropped rather than
		rejected: how many bytes the last group carries is recoverable from how many characters
		it has, so '=' tells us nothing we cannot see. ]]
		text = text:gsub('[^A-Za-z0-9+/]', '')

		local out = table.create((#text // 4) * 3)
		for index = 1, #text, 4 do
			local a = b64Lookup[text:sub(index, index)] or 0
			local b = b64Lookup[text:sub(index + 1, index + 1)] or 0
			local c = b64Lookup[text:sub(index + 2, index + 2)]
			local d = b64Lookup[text:sub(index + 3, index + 3)]
			local n = a * 262144 + b * 4096 + (c or 0) * 64 + (d or 0)
			out[#out + 1] = string.char(n // 65536)
			if c then
				out[#out + 1] = string.char((n // 256) % 256)
			end
			if d then
				out[#out + 1] = string.char(n % 256)
			end
		end

		return table.concat(out)
	end

	--[[ Codes widen from 9 bits as the dictionary fills, which is most of where the saving over a
	fixed 16-bit code comes from: the first 256 entries of a JSON blob are almost all single
	characters and would otherwise cost two bytes each. Capped at 16 bits -- the dictionary stops
	growing there rather than being reset, which costs a little on a very large input and keeps
	both ends trivially in agreement about the width. ]]
	local function lzwPack(text)
		local dictionary = {}
		for index = 0, 255 do
			dictionary[string.char(index)] = index
		end

		local nextCode, width = 256, 9
		local bytes = table.create(#text // 2)
		local accumulator, accumulated = 0, 0

		local function emit(code)
			accumulator = accumulator * (2 ^ width) + code
			accumulated += width
			while accumulated >= 8 do
				accumulated -= 8
				local shift = 2 ^ accumulated
				bytes[#bytes + 1] = string.char((accumulator // shift) % 256)
				accumulator = accumulator % shift
			end
		end

		local word = ''
		for index = 1, #text do
			local char = text:sub(index, index)
			local candidate = word..char
			if dictionary[candidate] then
				word = candidate
			else
				emit(dictionary[word])
				if nextCode < 65536 then
					dictionary[candidate] = nextCode
					nextCode += 1
					if nextCode > (2 ^ width) - 1 and width < 16 then
						width += 1
					end
				end
				word = char
			end
		end

		if word ~= '' then
			emit(dictionary[word])
		end

		-- Trailing bits are padded out to a whole byte; the unpacker stops on the dictionary, not
		-- on the byte count, so the padding is never mistaken for another code.
		if accumulated > 0 then
			bytes[#bytes + 1] = string.char((accumulator * (2 ^ (8 - accumulated))) % 256)
		end

		return table.concat(bytes)
	end

	local function lzwUnpack(data)
		local dictionary = table.create(65536)
		for index = 0, 255 do
			dictionary[index] = string.char(index)
		end

		local nextCode, width = 256, 9
		local out = {}
		local accumulator, accumulated = 0, 0
		local position = 1
		local previous

		--[[ The width has to step up ONE code earlier than the packer's dictionary does. The
		packer widens after adding an entry, so the code it writes at the new width refers to an
		entry this side has not added yet -- reading it at the old width would take the wrong
		number of bits and desynchronise everything after it. ]]
		local function readCode()
			while accumulated < width do
				if position > #data then
					return nil
				end
				accumulator = accumulator * 256 + data:byte(position)
				accumulated += 8
				position += 1
			end
			accumulated -= width
			local shift = 2 ^ accumulated
			local code = accumulator // shift
			accumulator = accumulator % shift
			return code
		end

		while true do
			local code = readCode()
			if not code then break end

			local entry
			if dictionary[code] then
				entry = dictionary[code]
			elseif code == nextCode and previous then
				-- The one self-referential case in LZW: a code for a sequence being defined by
				-- the very code that emits it.
				entry = previous..previous:sub(1, 1)
			else
				break
			end

			out[#out + 1] = entry

			if previous then
				if nextCode < 65536 then
					dictionary[nextCode] = previous..entry:sub(1, 1)
					nextCode += 1
				end
			end

			if nextCode + 1 > (2 ^ width) - 1 and width < 16 then
				width += 1
			end

			previous = entry
		end

		return table.concat(out)
	end

	local function packExport(text)
		local ok, packed = pcall(function()
			return PACK_PREFIX..base64Encode(lzwPack(text))
		end)

		--[[ Two reasons to hand back the plain JSON. It failed, in which case a blob that is
		harder to paste still beats no blob at all -- and it came out LONGER, which it does on
		anything small: base64 costs a third on top, and a set of two flags has nothing for the
		dictionary to find. Packing there would be a bigger export that also cannot be read by
		anything else. ]]
		if not (ok and type(packed) == 'string' and packed ~= '') or #packed >= #text then
			return text
		end

		return packed
	end

	local function unpackImport(text)
		if text:sub(1, #PACK_PREFIX) ~= PACK_PREFIX then
			return text
		end
		local ok, plain = pcall(function()
			return lzwUnpack(base64Decode(text:sub(#PACK_PREFIX + 1)))
		end)
		return (ok and type(plain) == 'string' and plain ~= '') and plain or text
	end

	local function writeExport(name, blob)
		ensureFolder(EXPORT_FOLDER)
		return (pcall(writefile, EXPORT_FOLDER..'/'..name..'.txt', blob))
	end

	--[[ The blob the user pasted, wherever they managed to put it.

	The text box is asked first and everything else is a fallback: it is the only one of the
	three that the user can see, so when there is something in it, that is unambiguously what
	they meant to import -- even on an executor whose clipboard also happens to hold an old
	export. ]]
	local function readImport(box, fallbackpath)
		if box and type(box.Value) == 'string' then
			local typed = box.Value:gsub('^%s+', ''):gsub('%s+$', '')
			if typed ~= '' then return typed end
		end
		local blob = getClipboard()
		if blob then return blob end
		for _, path in {fallbackpath, EXPORT_FOLDER..'/import.txt'} do
			local suc, res = pcall(readfile, path)
			if suc and type(res) == 'string' and res ~= '' then
				return res
			end
		end
		return nil
	end

	local function decodeImport(blob)
		local suc, res = pcall(function()
			return httpService:JSONDecode(unpackImport(blob))
		end)
		return (suc and type(res) == 'table') and res or nil
	end

	--[[ Filenames are built out of these, so anything a filesystem could refuse -- a slash, a
	colon, a leading space -- is dropped here rather than handed to writefile, which on most
	executors fails with an error that says nothing about the name being the problem. ]]
	local function sanitizeName(name)
		if type(name) ~= 'string' then return nil end
		name = name:gsub('[^%w_%- ]', '')
		name = name:gsub('^%s+', ''):gsub('%s+$', '')
		return name ~= '' and name:sub(1, 24) or nil
	end

	--[[ An import keeps the name it was exported under, so the entry that appears in the list is
	the one the person who sent it is talking about. That means a name already in use is
	REPLACED rather than sidestepped with a number: two rows called the same thing would be two
	rows fighting over one file (see CreateProfile), and a numbered copy is not the profile
	anyone asked to import. Nothing is written before the payload has been validated, and the
	box is emptied only once it has. ]]


	local function exportProfile(name)
		name = name or vape.Profile
		--[[ Flushed first when it is the profile in use: everything toggled since the last
		autosave is still in memory, and an export read off the file alone would quietly ship
		the older state. ]]
		if name == vape.Profile then
			pcall(function() vape:Save() end)
		end

		local path = 'pistonware/profiles/'..name..vape.Place..'.txt'
		local data = isfile(path) and loadJson(path)
		if type(data) ~= 'table' then
			vape:CreateNotification('Pistonware', 'Nothing to export -- the '..name..' profile has no file for this game yet.', 10, 'alert')
			return
		end

		local suc, blob = pcall(httpService.JSONEncode, httpService, {
			Pistonware = 'profile',
			Version = 1,
			Name = name,
			Place = vape.Place,
			GameId = tostring(game.GameId),
			Data = data
		})
		if not suc then
			vape:CreateNotification('Pistonware', 'Export failed, '..tostring(blob), 10, 'alert')
			return
		end

		blob = packExport(blob)
		local filename = 'profile-'..name..vape.Place
		local wrote = writeExport(filename, blob)
		if setClipboard(blob) then
			vape:CreateNotification('Pistonware', 'Copied the <font color="'..ui.hex(theme.Accent())..'">'..name..'</font> profile to your clipboard'..(wrote and ' and to '..EXPORT_FOLDER..'/'..filename..'.txt.' or '.'), 10)
		elseif wrote then
			vape:CreateNotification('Pistonware', 'Your executor has no clipboard access, so the profile was written to '..EXPORT_FOLDER..'/'..filename..'.txt instead.', 10)
		else
			vape:CreateNotification('Pistonware', 'Export failed -- could not reach the clipboard or write to '..EXPORT_FOLDER..'.', 10, 'alert')
		end
	end

	-- Assigned below; importProfile is its own Function, so the two cannot be declared together.
	local profileimportbox

	--[[ Reads an exported profile (or a bare config) and returns the payload and the name it was
	exported under, or nil after saying why. ]]
	local function readProfileImport()
		local blob = readImport(profileimportbox, EXPORT_FOLDER..'/importprofile.txt')
		if not blob then
			vape:CreateNotification('Pistonware', 'Nothing to import -- paste a profile into the Import profile box, or copy one to your clipboard.', 10, 'alert')
			return nil
		end

		local decoded = decodeImport(blob)
		if not decoded then
			vape:CreateNotification('Pistonware', 'That does not look like a profile (it is not readable JSON).', 10, 'alert')
			return nil
		end

		--[[ Two shapes are accepted: this GUI's envelope, and a bare config file, recognised by
		the keys vape:Save writes. ]]
		local payload, name = decoded, nil
		if decoded.Pistonware == 'profile' and type(decoded.Data) == 'table' then
			payload, name = decoded.Data, decoded.Name
			-- Exported as a number (vape.Place is a PlaceId), so it is compared as one.
			local place = tonumber(decoded.Place)
			if place and place ~= vape.Place then
				vape:CreateNotification('Pistonware', 'Heads up: that profile was exported for a different game, most of its modules will not exist here.', 10, 'alert')
			end
		end
		--[[ vape:Load walks Modules, Categories and Legit unchecked, so a payload missing one throws part
		way through the apply with saving off. Modules is what makes it a profile; the other two may be empty. ]]
		if type(payload.Modules) ~= 'table' then
			vape:CreateNotification('Pistonware', 'That JSON is not a pistonware profile.', 10, 'alert')
			return nil
		end
		if type(payload.Categories) ~= 'table' then payload.Categories = {} end
		if type(payload.Legit) ~= 'table' then payload.Legit = {} end
		return payload, name
	end

	local function importProfile()
		local payload, name = readProfileImport()
		if not payload then return end

		-- Only a bare config arrives without one, and it has to be filed under something.
		name = sanitizeName(name) or 'imported'
		local existed = profilescategory:GetValue(name) ~= nil

		local ok, err = writeJson('pistonware/profiles/'..name..vape.Place..'.txt', payload)
		if not ok then
			vape:CreateNotification('Pistonware', 'Import failed, '..tostring(err), 10, 'alert')
			return
		end

		--[[ Adds the row only when it is not already there: on a name that IS listed, ChangeValue
		is the delete half of this list's toggle. Only the profile in use is loaded (below). ]]
		if not existed then
			profilescategory:ChangeValue(name)
		end

		if profileimportbox then
			profileimportbox:SetValue('')
		end

		--[[ Into the profile in use it is applied straight away, as importInto does: otherwise the
		next save (or selecting the card, which saves first) writes the old settings back over it. ]]
		if name == vape.Profile then
			vape:Load(true, name)
			vape:CreateNotification('Pistonware', 'Imported into <font color="'..ui.hex(theme.Accent())..'">'..name..'</font>.', 10)
			return
		end

		vape:CreateNotification('Pistonware', (existed and 'Replaced <font color="'..ui.hex(theme.Accent())..'">' or 'Imported as <font color="'..ui.hex(theme.Accent())..'">')..name..'</font>, click it in the Profiles tab to load it.', 10)
	end

	--[[ The import icon on a profile card: the pasted profile goes INTO that profile, replacing
	it, after a confirmation. Into the profile in use, it is applied straight away -- otherwise
	the next autosave would write the old settings back over it. ]]
	local function importInto(target)
		local payload = readProfileImport()
		if not payload then return end
		ui.confirm("Replace the '"..target.."' profile with the one you copied?", function()
			local ok, err = writeJson('pistonware/profiles/'..target..vape.Place..'.txt', payload)
			if not ok then
				vape:CreateNotification('Pistonware', 'Import failed, '..tostring(err), 10, 'alert')
				return
			end
			if profileimportbox then
				profileimportbox:SetValue('')
			end
			if target == vape.Profile then
				vape:Load(true)
			end
			vape:CreateNotification('Pistonware', 'Imported into <font color="'..ui.hex(theme.Accent())..'">'..target..'</font>.', 10)
		end, 'Replace')
	end

	--[[ No executor can open a folder in Explorer, so this copies the path to the file. ]]
	local function copyFolder(name)
		local path = 'pistonware/profiles/'..name..vape.Place..'.txt'
		if setClipboard(path) then
			vape:CreateNotification('Pistonware', 'Copied <font color="'..ui.hex(theme.Accent())..'">'..path..'</font> -- it is inside your executor\'s workspace folder.', 8)
		else
			vape:CreateNotification('Pistonware', 'The profile is at '..path..' inside your executor\'s workspace folder.', 8)
		end
	end

	profilescategory.CardActions = {
		Export = exportProfile,
		Import = importInto,
		Folder = copyFolder
	}

	profilescategory.Inline:CreateDivider({Text = 'Share profiles'})

	profilescategory.Inline:CreateButton({
		Name = 'Export profile',
		Darker = true,
		LayoutOrder = 1003,
		Function = exportProfile,
		Tooltip = 'Copies the profile you are on to your clipboard and to '..EXPORT_FOLDER
	})

	profileimportbox = profilescategory.Inline:CreateTextBox({
		Name = 'Import profile',
		Darker = true,
		LayoutOrder = 1001,
		Placeholder = 'Paste an exported profile',
		Function = function(enter)
			if enter then
				importProfile()
			end
		end,
		Tooltip = 'Paste a profile here and press Enter, or use the button below'
	})

	profilescategory.Inline:CreateButton({
		Name = 'Import pasted profile',
		Darker = true,
		LayoutOrder = 1002,
		Function = importProfile,
		Tooltip = 'Imports what is in the box above, falling back to your clipboard or '..EXPORT_FOLDER..'/import.txt'
	})

	--[[
		FFlags

		Fast flags are Roblox's own client switches, and it is the executor that sets them --
		pistonware never can on its own. What this tab owns is the LIST: one named set of flags
		per file in pistonware/fflags, of which exactly one is current.

		Built on the same list shape as the Profiles tab (Swap = true, see CategoryList), so the
		rows are identical to look at and to use: type a name to add one, click a row to make it
		current, the current one wears the GUI colour, the dots menu removes it, and the keybind
		on the row swaps to it without opening the GUI. What selecting MEANS is the only
		difference -- a profile swap loads a config, this writes flags into the client.

		A new entry starts as an empty set. It gets filled in either by importing one or by
		editing pistonware/fflags/<name>.txt by hand, which is why Apply exists as a button as
		well: a file edited outside the GUI should be applicable without swapping away and back.
	]]
	local FFLAG_FOLDER = 'pistonware/fflags'
	local fflags
	local function fflagPath(name)
		return FFLAG_FOLDER..'/'..name..'.txt'
	end

	--[[ Which set is current. Mirrors vape.Profile for the Profiles tab, and is persisted the same
	way -- through the list's own Save, into gui.txt. Declared before the list because the list's
	callbacks read and write it. ]]
	local selectedFFlag = 'default'
	local applyFFlags

	fflags = vape:CreateCategoryList({
		Name = 'FFlags',
		Tab = 'FFlags',
		Size = UDim2.fromOffset(15, 14),
		Placeholder = 'Type name',
		Swap = true,
		Current = function()
			return selectedFFlag
		end,
		--[[ Swapping applies, because a set that is current but not written to the client is a
		row that claims something untrue. This is the counterpart of a profile click loading the
		config it names. ]]
		Select = function(name)
			selectedFFlag = name
			applyFFlags()
		end,
		--[[ Removing a row deletes its file, exactly as removing a profile deletes the config it
		names. Falls back to the entry that can never be removed. ]]
		Delete = function(name)
			pcall(function()
				if isfile(fflagPath(name)) and delfile then
					delfile(fflagPath(name))
				end
			end)
			if selectedFFlag == name then
				selectedFFlag = 'default'
			end
		end,
		-- Restoring a saved selection must not write flags into the client on every inject.
		Restore = function(name)
			selectedFFlag = name
		end,
		OnExpand = function()
			-- The list is a UI affordance, not boot-critical state. Create its default row and
			-- backing files only when the user opens the pane (or when they add/import a set).
			if fflags and not fflags:GetValue('default') then
				fflags:ChangeValue('default')
				return
			end
			pcall(function()
				ensureFolder(FFLAG_FOLDER)
				for _, entry in fflags.List do
					if type(entry) == 'table' and type(entry.Name) == 'string' and not isfile(fflagPath(entry.Name)) then
						writeJson(fflagPath(entry.Name), {})
					end
				end
			end)
		end,
		Function = function(_, skipGUI)
			if skipGUI then return end
			--[[ Every name in the list gets a file, so a set added by typing is something the user
			can actually go and edit rather than a row that silently refers to nothing.

			Wrapped because an executor whose filesystem calls are missing or restricted would take
			the whole load down from here. Losing the file for a row costs an empty set the user can
			still import into. ]]
			pcall(function()
				ensureFolder(FFLAG_FOLDER)
				for _, entry in fflags.List do
					if type(entry) == 'table' and type(entry.Name) == 'string' and not isfile(fflagPath(entry.Name)) then
						writeJson(fflagPath(entry.Name), {})
					end
				end
			end)
		end
	})

	--[[ Counts string keys rather than using #: a flag set is a map, so its length is always 0. ]]
	local function countFlags(data)
		local count = 0
		for flag in data do
			if type(flag) == 'string' then
				count += 1
			end
		end
		return count
	end

	--[[ The tail both the Apply button and the adder put on their message. Kept in one place so
	the two can never disagree about what just happened, and so the explanation for a flag that
	did not stick is written once. ]]
	local function applySuffix(total, failed, verified, verifiable)
		local text = failed > 0 and ' ('..failed..' rejected)' or ''

		if not verifiable then
			-- No getfflag: nothing here can tell a flag that took from one that did not.
			return text..'. Restart Roblox to apply changes.'
		end

		if verified >= (total - failed) then
			return text..'. All of them read back changed; restart Roblox to apply changes that are read at startup.'
		end

		if verified <= 0 then
			return text..", but none of them read back changed -- these are read once while the client starts, so they have to go in your executor's own FastFlag settings. Restart Roblox to apply changes."
		end

		return text..", but only "..verified.." read back changed -- the rest are read once while the client starts. Restart Roblox to apply changes."
	end

	local function selectedFlags()
		local data = loadJson(fflagPath(selectedFFlag))
		return type(data) == 'table' and data or {}
	end

	--[[
		A flag that was SET is not a flag that CHANGED.

		setfflag is the executor's function, not Roblox's, and on most of them it returns nothing
		and throws nothing -- so a pcall around it succeeds whether the engine took the value or
		ignored it. Counting those successes is what produced 'applied 11 of 11' for a set that
		visibly did nothing, which is a worse answer than an error would have been.

		Nearly every flag worth setting -- the render, graphics and scheduler ones people share
		lists for -- is read ONCE while the client starts, into a variable the engine keeps from
		then on. Writing the flag afterwards changes the flag and not the variable, and a game
		already running is always afterwards. That is a limit of setting flags from inside a
		running client, not something this can code around.

		So the value is read back where the executor can do it, and the two numbers are reported
		separately: how many were set, and how many actually hold the value now. Where there is
		no getfflag the verified count is not guessed at -- it is left out of the message.

		Returns total, failed, verified, verifiable so the adder can say all of this in one line.
	]]
	function applyFFlags(quiet)
		local setter = setfflag or set_fflag
		local getter = getfflag or get_fflag
		local flags = selectedFlags()
		local total, failed, verified = 0, 0, 0

		for flag, value in flags do
			if type(flag) ~= 'string' then continue end
			total += 1

			--[[ The type prefix comes off before the call.

			setfflag takes the BARE name -- 'DisablePostFx', not 'FFlagDisablePostFx' -- and works
			out the type itself. The prefix is part of how a flag is written down in the JSON files
			people share, not part of the name the engine knows it by. Handed the full name the
			call matches nothing, returns cleanly, and changes nothing: the silent no-op this tab
			was reporting as success.

			Anchored to the front, where the version this is taken from gsubs each prefix anywhere
			in the string. Identical for every real flag name, and it cannot eat a 'FInt' that
			happens to sit in the middle of one. Anchoring also removes the ordering hazard --
			'FFlag' can never match inside 'DFFlagX' and leave 'DX' behind.

			FLog and DFLog are included because your own list uses them (FLogNetwork,
			FLogIXPGraphicsOptimizationModeQualityScale); they resolve the same way. ]]
			local name = flag
			for _, prefix in {'DFFlag', 'DFInt', 'DFString', 'DFLog', 'FFlag', 'FInt', 'FString', 'FLog'} do
				local stripped = name:match('^'..prefix..'(.+)$')
				if stripped then
					name = stripped
					break
				end
			end
			--[[ Stringified: the executors that take a value at all take it as a string, and the
			sets people share are a mix of "true", true and numbers. ]]
			local wanted = tostring(value)

			--[[ Booleans go in lower case, whatever spelling the list used.

			These lists are written for bootstrappers, which hand Roblox a JSON file and let its
			settings loader coerce "True" into a boolean. setfflag is a different route into the
			same flags, and the engine parses the string strictly there: "True" is not "true", so
			the flag keeps its default and nothing is reported -- the call still returns cleanly,
			which is exactly the silent no-op this tab was showing as success.

			Worth doing across the board: 122 of the 234 values in the list you pasted are
			capitalised, so this is most of the file rather than an edge case.

			Only booleans are touched. FInt/DFInt values are numbers, and FString values are
			content -- asset ids, URLs, embedded JSON -- where case is meaningful. ]]
			local lowered = wanted:lower()
			if lowered == 'true' or lowered == 'false' then
				wanted = lowered
			end
			if not (setter and pcall(setter, name, wanted)) then
				failed += 1
				continue
			end

			if getter then
				--[[ Compared case-insensitively: these lists are written for bootstrappers, which
				accept "True" where the engine reports back "true". A case difference here is the
				same value, not a flag that refused to take. ]]
				local ok, got = pcall(getter, name)
				if ok and got ~= nil and tostring(got):lower() == wanted:lower() then
					verified += 1
				end
			end
		end

		local verifiable = getter ~= nil

		if total <= 0 then
			if not quiet then
				vape:CreateNotification('Pistonware', 'Switched to <font color="'..ui.hex(theme.Accent())..'">'..selectedFFlag..'</font>, which has no flags in it yet.', 5)
			end
			return 0, 0, 0, verifiable
		end

		if not setter then
			vape:CreateNotification('Pistonware', 'Your executor cannot set fast flags (no setfflag), so the list here is stored but not applied.', 10, 'alert')
			return total, total, 0, verifiable
		end

		if failed >= total then
			vape:CreateNotification('Pistonware', 'None of the '..total..' flags in '..selectedFFlag..' could be applied.', 10, 'alert')
			return total, failed, 0, verifiable
		end

		if not quiet then
			vape:CreateNotification('Pistonware', 'Applied '..(total - failed)..' of '..total..' flags from <font color="'..ui.hex(theme.Accent())..'">'..selectedFFlag..'</font>'..applySuffix(total, failed, verified, verifiable), 10,
				(verifiable and verified <= 0) and 'alert' or nil)
		end

		return total, failed, verified, verifiable
	end

	local function exportFFlags()
		local flags = selectedFlags()
		local count = countFlags(flags)
		if count <= 0 then
			vape:CreateNotification('Pistonware', 'Nothing to export -- '..selectedFFlag..' has no flags in it.', 10, 'alert')
			return
		end

		local suc, blob = pcall(httpService.JSONEncode, httpService, {
			Pistonware = 'fflags',
			Version = 1,
			Name = selectedFFlag,
			Data = flags
		})
		if not suc then
			vape:CreateNotification('Pistonware', 'Export failed, '..tostring(blob), 10, 'alert')
			return
		end

		blob = packExport(blob)
		local filename = 'fflags-'..(sanitizeName(selectedFFlag) or 'export')
		local wrote = writeExport(filename, blob)
		if setClipboard(blob) then
			vape:CreateNotification('Pistonware', 'Copied '..count..' flag'..(count == 1 and '' or 's')..' from <font color="'..ui.hex(theme.Accent())..'">'..selectedFFlag..'</font> to your clipboard'..(wrote and ' and to '..EXPORT_FOLDER..'/'..filename..'.txt.' or '.'), 10)
		elseif wrote then
			vape:CreateNotification('Pistonware', 'Your executor has no clipboard access, so '..count..' flags were written to '..EXPORT_FOLDER..'/'..filename..'.txt instead.', 10)
		else
			vape:CreateNotification('Pistonware', 'Export failed -- could not reach the clipboard or write to '..EXPORT_FOLDER..'.', 10, 'alert')
		end
	end

	local fflagimportbox

	--[[
		Adding, not importing-as-a-new-thing.

		A pasted set goes into the profile you are ON, the way pasting into a document puts the
		text where the cursor is. Filing it under a name of its own instead was the wrong model:
		it left you looking at a profile you did not choose, called 'imported', while the one you
		had selected was untouched -- so the obvious next question was always "now how do I get
		these into MY profile".

		Building up a named set is still exactly as possible, and reads better this way round:
		type the name, click the row, paste. The destination is chosen before the paste rather
		than discovered after it.

		The flags land in the client immediately, because the set they were added to is the one
		that is current -- leaving it selected but not applied would be a row claiming something
		untrue. Applying is asked to stay quiet so this reports the whole thing in one line.
	]]
	local function importFFlags()
		local blob = readImport(fflagimportbox, FFLAG_FOLDER..'/import.txt')
		if not blob then
			vape:CreateNotification('Pistonware', 'Nothing to add -- paste an FFlag set into the box above, or copy one to your clipboard.', 10, 'alert')
			return
		end

		local decoded = decodeImport(blob)
		if not decoded then
			vape:CreateNotification('Pistonware', 'That does not look like an FFlag set (it is not readable JSON).', 10, 'alert')
			return
		end

		--[[ A bare flag map is accepted as well as this GUI's envelope. That shape is what every
		other fast-flag tool hands out, and it is what a user pasting from one of them will have.
		The envelope's name is deliberately ignored now -- where the flags go is the row you have
		selected, not something the sender gets to decide. ]]
		local payload = decoded
		if decoded.Pistonware == 'fflags' and type(decoded.Data) == 'table' then
			payload = decoded.Data
		end

		if countFlags(payload) <= 0 then
			vape:CreateNotification('Pistonware', 'That JSON has no flags in it.', 10, 'alert')
			return
		end

		--[[ Merged over what is already there rather than replacing it, so pasting a second set
		builds the profile up. A flag present in both takes the pasted value: the paste is the
		more recent instruction, and counting those separately is what lets the message below
		distinguish 'added 40' from 'added 40, changed 3'. ]]
		local target = selectedFFlag
		local flags = selectedFlags()
		local added, changed = 0, 0

		for flag, value in payload do
			if type(flag) ~= 'string' then continue end
			if flags[flag] == nil then
				added += 1
			elseif flags[flag] ~= value then
				changed += 1
			end
			flags[flag] = value
		end

		ensureFolder(FFLAG_FOLDER)
		local ok, err = writeJson(fflagPath(target), flags)
		if not ok then
			vape:CreateNotification('Pistonware', 'Could not save to '..target..', '..tostring(err), 10, 'alert')
			return
		end

		if fflagimportbox then
			fflagimportbox:SetValue('')
		end

		local total, failed, verified, verifiable = applyFFlags(true)
		vape:CreateNotification('Pistonware',
			'Added '..added..' flag'..(added == 1 and '' or 's')..
			(changed > 0 and ' and updated '..changed or '')..
			' in <font color="'..ui.hex(theme.Accent())..'">'..target..'</font> -- applied '..(total - failed)..' of '..total..
			applySuffix(total, failed, verified, verifiable), 10,
			(verifiable and verified <= 0) and 'alert' or nil)
	end

	--[[ In the list rather than behind the gear, and directly under the rows: what a paste does
	depends entirely on which row is selected, so the two belong in the same glance. The profile
	importer opposite is the other way round precisely because it does NOT read the selection. ]]
	fflagimportbox = fflags.Inline:CreateTextBox({
		Name = 'Add FFlags',
		Darker = true,
		LayoutOrder = 1001,
		Placeholder = 'Paste flags to add',
		Function = function(enter)
			if enter then
				importFFlags()
			end
		end,
		Tooltip = 'Paste flags here and press Enter to add them to the selected profile'
	})

	fflags.Inline:CreateButton({
		Name = 'Add pasted FFlags',
		Darker = true,
		LayoutOrder = 1002,
		Function = importFFlags,
		Tooltip = 'Adds what is in the box above to the selected profile, falling back to your clipboard or '..FFLAG_FOLDER..'/import.txt'
	})

	fflags.Inline:CreateButton({
		Name = 'Export FFlags',
		Darker = true,
		LayoutOrder = 1003,
		Function = exportFFlags,
		Tooltip = 'Copies the selected flag profile to your clipboard and to '..EXPORT_FOLDER
	})

	fflags.Inline:CreateButton({
		Name = 'Reset current fflag profile',
		Darker = true,
		LayoutOrder = 1004,
		Function = function()
			local target = selectedFFlag
			local emptied = countFlags(selectedFlags())

			--[[ Emptied, not deleted. The row stays exactly where it was and stays selected --
			this clears what is IN the profile, which is what makes it the counterpart of adding
			to it. Removing the profile itself is the dots menu on its row. ]]
			local ok, err = pcall(function()
				ensureFolder(FFLAG_FOLDER)
				return writeJson(fflagPath(target), {})
			end)
			if not ok then
				vape:CreateNotification('Pistonware', 'Could not clear '..target..', '..tostring(err), 10, 'alert')
				return
			end

			if emptied <= 0 then
				vape:CreateNotification('Pistonware', '<font color="'..ui.hex(theme.Accent())..'">'..target..'</font> was already empty.', 5)
				return
			end

			--[[ Nothing is unset in the running client, because nothing can be: a flag written
			this session is read back out of the engine, not out of this file. Clearing the file
			means the profile stops setting them on the next apply, and the ones already in the
			client stay until it restarts. Saying so is the honest version -- silently emptying
			the list while the game still looks flagged is what would confuse. ]]
			vape:CreateNotification('Pistonware', 'Cleared '..emptied..' flag'..(emptied == 1 and '' or 's')..' from <font color="'..ui.hex(theme.Accent())..'">'..target..'</font>. Flags already set stay until you restart Roblox.', 10)
		end,
		Tooltip = 'Removes every flag from the selected profile, keeping the profile itself'
	})

	
	--[[
		Targets
	]]
	local targets
	targets = vape:CreateCategoryList({
		Name = 'Targets',
		Size = UDim2.fromOffset(17, 16),
		Placeholder = 'Roblox username',
		Function = function()
			targets.Update:Fire()
		end
	})
	targets.Update = Instance.new('BindableEvent')
	vape:Clean(targets.Update)
end

--[[ Move HUD. Overlay handles and widget outlines only take a drag while the menu is open, and on a
phone the open menu covers nearly all of them. This hides the menu window and its dim but leaves the
menu open, so everything on the HUD can be dragged; the loader-style Done pill at the top, or the
menu key (the >_ button on a phone), brings the window back. ]]
function build.moveHud(pane)
	local LOADER_ORANGE = Color3.fromRGB(240, 122, 31)
	local done = ui.new('TextButton', {
		Name = 'MoveHudDone',
		AnchorPoint = Vector2.new(0.5, 0),
		AutoButtonColor = false,
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = Color3.fromRGB(10, 10, 10):Lerp(LOADER_ORANGE, 0.1),
		BackgroundTransparency = 0.3,
		BorderSizePixel = 0,
		FontFace = Font.fromEnum(Enum.Font.Code),
		RichText = true,
		Size = UDim2.fromOffset(0, 32),
		Text = '<font color="#9E9E9E">&gt;</font> <font color="#F07A1F">Done</font>  <font color="#A3A19D">drag your HUD into place</font>',
		TextColor3 = Color3.fromRGB(230, 230, 230),
		TextSize = 15,
		Visible = false,
		ZIndex = 30
	}, clickgui)
	ui.corner(done, UDim.new(1, 0))
	ui.stroke(done, LOADER_ORANGE, 1, 0.55)
	ui.padding(done, 16, 16, 0, 0)
	ui.hudScale(done)

	local function stop()
		if not layout.MovingHud then return end
		layout.MovingHud = false
		done.Visible = false
		if layout.Window then
			layout.Window.Visible = true
		end
		if layout.Dim then
			layout.Dim.Visible = clickgui.Visible
		end
		vape:BlurCheck()
	end
	local function start()
		if layout.MovingHud or not (clickgui.Visible and layout.Window) then return end
		layout.MovingHud = true
		layout.Window.Visible = false
		if layout.Dim then
			layout.Dim.Visible = false
		end
		done.Position = UDim2.new(0.5, 0, 0, ui.insetUnits() + 12)
		done.Visible = true
		vape:BlurCheck()
	end
	layout.StopMovingHud = stop
	done.MouseButton1Click:Connect(stop)
	-- Closed some other way (Unload, a module's hold gesture): the window is back for the next open.
	vape:Clean(clickgui:GetPropertyChangedSignal('Visible'):Connect(function()
		if not clickgui.Visible then
			stop()
		end
	end))

	pane:CreateButton({
		Name = 'Move HUD',
		Function = start,
		Tooltip = 'Hides the menu so the overlays and widgets under it can be dragged, until you press Done'
	})
end

function build.settings()
	components.LegitWindow()
	vape.SearchBar = components.SearchBar()
	vape.Categories.Main:CreateOverlayBar()

	--[[
		General Settings
	]]
	
	local general = vape.Categories.Main.Settings:CreateSettingsPane({Name = 'General'})
	local settingConnections = {}
	vape.MultiKeybind = general:CreateToggle({
		Name = 'Enable Multi-Keybinding',
		Tooltip = 'Allows multiple keys to be bound to a module (eg. G + H)'
	})
	general:CreateToggle({
		Name = 'Allow setting keybinds',
		Function = function(callback)
			if callback then
				for _, container in {vape.ModuleOrder, vape.Legit.Order} do
					for _, module in orderedModules(container) do
						for _, component in module.Options do
							if component.Type == 'Toggle' then
								local bind = components.Bind({
									Module = true
								}, nil, component)
								bind.Object.Position = UDim2.new(1, -40, 0, 5)
	
								table.insert(settingConnections, bind.Triggered:Connect(function(isDown)
									if bind.Hold then
										if component.Enabled ~= isDown then
											if vape.SettingToggleNotifications.Enabled then
												vape:CreateNotification(module.Name, component.Name..' '..(not component.Enabled and "<font color='"..ui.hex(theme.Green).."'>ON</font>" or "<font color='"..ui.hex(theme.Red).."'>OFF</font>"), 1.5)
											end
	
											component:Toggle()
										end
									else
										if vape.SettingToggleNotifications.Enabled then
											vape:CreateNotification(module.Name, component.Name..' '..(not component.Enabled and "<font color='"..ui.hex(theme.Green).."'>ON</font>" or "<font color='"..ui.hex(theme.Red).."'>OFF</font>"), 1.5)
										end
	
										component:Toggle()
									end
								end))
	
								table.insert(settingConnections, component.Object.MouseEnter:Connect(function()
									bind:SetVisible(true)
								end))
	
								table.insert(settingConnections, component.Object.MouseLeave:Connect(function()
									bind:SetVisible(false)
								end))
							end
						end
					end
				end
			else
				for _, container in {vape.ModuleOrder, vape.Legit.Order} do
					for _, module in orderedModules(container) do
						for _, component in module.Options do
							if component.Bind then
								component.Bind:Destroy()
							end
						end
					end
				end
	
				for _, connection in settingConnections do
					connection:Disconnect()
				end
				table.clear(settingConnections)
			end
		end,
		Tooltip = 'Hover a toggle setting to bind it to a key'
	})
	

	general:CreateButton({
		Name = 'Reset current profile',
		Function = function()
			ui.confirm("Reset the '"..vape.Profile.."' profile to the defaults? This reloads Pistonware.", function()
				vape.Save = function() end
				if isfile('pistonware/profiles/'..vape.Profile..vape.Place..'.txt') and delfile then
					delfile('pistonware/profiles/'..vape.Profile..vape.Place..'.txt')
				end

				shared.vapereload = true
				--[[ Back through the pistonware loader, which re-runs the key gate. The developer
				loader lives on disk under a different name and must never be fetched from GitHub. ]]
				if shared.PistonwareDeveloper and isfile('pistonware/loaderdev.lua') then
					runChunk(readfile('pistonware/loaderdev.lua'), 'loader')
				else
					runChunk(pistonwareHttpGet('https://raw.githubusercontent.com/themagicpiston/pistonware/main/loader.lua', true), 'loader')
				end
			end, 'Reset')
		end,
		Tooltip = 'This will set your profile to the default settings'
	})

	general:CreateButton({
		Name = 'Self destruct',
		Function = function()
			ui.confirm('Unload Pistonware from this game?', function()
				vape:Uninject()
			end, 'Unload')
		end,
		Tooltip = 'Removes Pistonware from the current game'
	})

	general:CreateButton({
		Name = 'Reinject',
		Function = function()
			shared.vapereload = true
			--[[ Back through the pistonware loader, which re-runs the key gate. ]]
			if shared.PistonwareDeveloper and isfile('pistonware/loaderdev.lua') then
				runChunk(readfile('pistonware/loaderdev.lua'), 'loader')
			else
				runChunk(pistonwareHttpGet('https://raw.githubusercontent.com/themagicpiston/pistonware/main/loader.lua', true), 'loader')
			end
		end,
		Tooltip = 'Reloads Pistonware'
	})

	general:CreateButton({
		Name = 'Reinstall',
		Function = function()
			ui.confirm('Delete the pistonware folder and download everything again?', function()
				runChunk(pistonwareHttpGet('https://raw.githubusercontent.com/themagicpiston/pistonware/refs/heads/main/reinstall.lua', true), 'reinstall')
			end, 'Reinstall')
		end,
		Tooltip = 'Uninjects, deletes the pistonware folder and downloads everything again'
	})

	--[[
		Module Settings
	]]
	
	local modules = vape.Categories.Main.Settings:CreateSettingsPane({Name = 'Modules'})
	modules:CreateToggle({
		Name = 'Teams by server',
		Tooltip = 'Ignore players on your team designated by the server',
		Default = true,
		Function = function()
			if vape.Libraries.entity and vape.Libraries.entity.Running then
				vape.Libraries.entity.refresh()
			end
		end
	})
	
	modules:CreateToggle({
		Name = 'Use team color',
		Tooltip = 'Uses the TeamColor property on players for render modules',
		Default = true,
		Function = function()
			if vape.Libraries.entity and vape.Libraries.entity.Running then
				vape.Libraries.entity.refresh()
			end
		end
	})
	
	--[[
		GUI Settings
	]]
	
	--[[
		Compatibility: the old GUI exposed every settings toggle in one flat table at
		vape.Categories.Main.Options. The rewrite splits them across vape.Settings.<pane>.Options.

		games/universal.lua and two place files still read the old path, for 'Teams by server'
		and 'Use team color' -- both on entity and render hot paths, where indexing nil does not
		fail quietly. universal.lua is pcall'd by main.lua, so the failure mode here was losing
		EVERY universal module at once with nothing printed to say why.

		A lazy lookup rather than a copied table: panes are still being created below this point,
		and game files add their own, so anything snapshotted here would be permanently missing
		whatever came later.
	]]
	vape.Categories.Main.Options = setmetatable({}, {
		__index = function(self, key)
			for _, pane in vape.Settings do
				local ok, options = pcall(function() return pane.Options end)
				if ok and type(options) == 'table' and options[key] ~= nil then
					--[[ Kept once found: these are read on entity and render paths, every frame, and
					each read walked every pane. An option never moves once made, and only keys that
					exist are kept, so one added by a later pane is still found. ]]
					rawset(self, key, options[key])
					return options[key]
				end
			end
			return nil
		end
	})

	local guipane = vape.Categories.Main.Settings:CreateSettingsPane({Name = 'GUI'})
	vape.Blur = guipane:CreateToggle({
		Name = 'Blur background',
		Function = function()
			vape:BlurCheck()
		end,
		-- On everywhere now. A phone drives the BlurEffect path in BlurCheck rather than the
		-- native SetRobloxGuiFocused call, which is the one thing the menu does on open that a
		-- client can die on rather than error on -- so the reason this defaulted off is gone.
		Default = true,
		Tooltip = 'Blur the background of the GUI'
	})
	

	guipane:CreateToggle({
		Name = 'GUI bind indicator',
		Default = true,
		Tooltip = "Displays a message indicating your GUI upon injecting.\nI.E. 'Press RSHIFT to open GUI'"
	})

	--[[ Tooltips are always on now (toggles and sliders only); the option keeps its save key and
	draws no row, and a profile that saved it off no longer turns them off. ]]
	guipane:CreateToggle({
		Name = 'Show tooltips',
		Function = function()
			tooltip.Visible = false
		end,
		Default = true,
		Visible = false
	})

	guipane:CreateToggle({
		Name = 'Show legit mode',
		Function = function(enabled)
			layout.ShowLegit = enabled
			layout.request('*')
		end,
		Default = true,
		Tooltip = 'Shows the HUD and cosmetic modules (clock, keystrokes, FPS...) in the Visual tab'
	})

	local ScaleSlider = {Object = {}, Value = 1}
	vape.Scale = guipane:CreateToggle({
		Name = 'Auto rescale',
		Default = true,
		Visible = false,
		Function = function(callback)
			ScaleSlider.Object.Visible = false
			if callback then
				--[[ Was commented out in the rewrite, so turning Auto rescale back on did
				nothing at all until the next resize -- and on a phone there is no next
				resize. The menu just stayed at whatever the manual slider left it on. ]]
				scale.Scale = autoScaleValue()
			else
				scale.Scale = ScaleSlider.Value
			end
			local main = vape.Categories.Main
			if main and main.Resize then
				main.Resize()
			end
		end,
		Tooltip = 'Automatically rescales the gui using the screens resolution'
	})
	
	ScaleSlider = guipane:CreateSlider({
		Name = 'Scale',
		Min = 0.1,
		Max = 2,
		Decimal = 10,
		Function = function(val, final)
			if final and not vape.Scale.Enabled then
				scale.Scale = val
			end
		end,
		Default = 1,
		Darker = true,
		Visible = false
	})
	
	vape.HideVapeButton = guipane:CreateToggle({
		Name = 'Hide Pistonware Mobile Button',
		Function = function(callback)
			--[[ Drops the transparencies rather than flipping Visible. An invisible
			GuiObject stops hit-testing in Roblox, so hiding the button used to take
			its tap target with it and the only way back into the GUI was the keybind
			-- which mobile doesn't have. Fully transparent still receives input, so
			the button keeps opening the menu from exactly where it always sat. ]]
			if vape.VapeButton then
				vape.VapeButton.BackgroundTransparency = callback and 1 or (vape.VapeButtonTransparency or 0)
				vape.VapeButton.TextTransparency = callback and 1 or 0
				if vape.VapeButtonStroke then
					vape.VapeButtonStroke.Transparency = callback and 1 or 0
				end
			end
		end,
		Tooltip = 'Makes the Pistonware button invisible on mobile\nIt still opens the GUI when tapped'
	})
	
	vape.RainbowSpeed = guipane:CreateSlider({
		Name = 'Rainbow speed',
		Min = 0.1,
		Max = 10,
		Decimal = 10,
		Default = 1,
		Tooltip = 'Adjusts the speed of rainbow values'
	})
	
	vape.RainbowUpdateSpeed = guipane:CreateSlider({
		Name = 'Rainbow update rate',
		Min = 1,
		Max = 144,
		Default = 60,
		Tooltip = 'Adjusts the update rate of rainbow values',
		Suffix = 'hz'
	})
	
	--[[ The GUI Theme dropdown that stood here is gone, not just commented out. It offered
	'old' and 'rise', both of which are discontinued -- guis/old.lua and guis/rise.lua no
	longer exist in this repo, so every branch of it pointed at a file that would 404. ]]
	
	guipane:CreateDropdown({
		Name = 'Search bar style',
		List = {'Floating', 'None'},
		Default = 'Floating',
		Visible = false,
		Function = function(value)
			vape.SearchBar.Object.Visible = value == 'Floating'
		end,
		Tooltip = 'Switch between search bar styles'
	})
	
	vape.RainbowMode = guipane:CreateDropdown({
		Name = 'Rainbow Mode',
		List = {'Normal', 'Gradient', 'Retro'},
		Tooltip = 'Normal - Smooth color fade\nGradient - Gradient color fade\nRetro - Static color'
	})

	guipane:CreateButton({
		Name = 'Edit hidden modules',
		Function = function()
			vape.EditGUI = not vape.EditGUI
			for _, module in orderedModules(vape.ModuleOrder) do
				if module.Edit then
					module.Edit.Visible = vape.EditGUI
				end
			end
			layout.request('*')
			vape:CreateNotification('Pistonware', vape.EditGUI and 'Click a card to hide or show it, press this again when done.' or 'Done editing hidden modules.', 5)
		end,
		Tooltip = 'Shows every module so you can hide the ones you never use'
	})

	guipane:CreateButton({
		Name = 'Reset GUI positions',
		Function = function()
			for _, category in vape.Categories do
				-- A fixed overlay (the Mod Overlay) has its own place, the top-right corner.
				if category.Type == 'Overlay' and category.Object and not category.Fixed then
					category.Object.Position = ui.hudPlace('Overlay', category.HudSlot or 1)
				end
			end
			for _, module in orderedModules(vape.Legit.Order) do
				if module.Children then
					module.Children.Position = ui.hudPlace('Widget', module.HudSlot or 1)
				end
			end
		end,
		Tooltip = 'Puts every overlay and on-screen widget back at the default position'
	})
	build.moveHud(guipane)

	--[[
		Notification Settings
	]]
	
	local notifpane = vape.Categories.Main.Settings:CreateSettingsPane({Name = 'Notifications'})
	vape.Notifications = notifpane:CreateToggle({
		Name = 'Notifications',
		Function = function(enabled)
			if vape.ToggleNotifications.Object then
				vape.ToggleNotifications.Object.Visible = enabled
			end
	
			if vape.SettingToggleNotifications.Object then
				vape.SettingToggleNotifications.Object.Visible = enabled
			end
		end,
		Tooltip = 'Shows notifications',
		Default = true
	})
	
	vape.ToggleNotifications = notifpane:CreateToggle({
		Name = 'Toggle alert',
		Tooltip = 'Notifies you if a module is enabled/disabled.',
		Default = true,
		Darker = true
	})
	vape.SettingToggleNotifications = notifpane:CreateToggle({
		Name = 'Setting toggle alert',
		Tooltip = 'Notifies you when a bound setting is toggled.',
		Default = true,
		Darker = true
	})
	
	vape.GUIColor = vape.Categories.Main.Settings:CreateGUISlider({
		Name = 'GUI Theme',
		Function = function(h, s, v)
			vape:UpdateGUI(h, s, v, true)
		end
	})
	
	vape.GUIBind = vape.Categories.Main.Settings:CreateBind({
		Name = 'Rebind GUI',
		Default = {'RightShift'},
		NoRemove = true,
		Tooltip = 'Change the bind of the GUI'
	})

	--[[ Where notifications stack, at the top of the Notifications card: the bottom-right corner,
	or the top-left one Slinky uses. A touch screen starts on the top left, since the bottom right is
	where its jump and attack buttons are. A dropdown starts on its first entry without calling its
	Function, so the stack is told here as well. ]]
	layout.NotifyTop = isMobile()
	notifpane:CreateDropdown({
		Name = 'Position',
		List = isMobile() and {'Top left', 'Bottom right'} or {'Bottom right', 'Top left'},
		LayoutOrder = -1,
		Function = function(value)
			layout.NotifyTop = value == 'Top left'
			ui.restackNotifications()
		end,
		Tooltip = 'Where notifications appear on your screen'
	})

	--[[ This card's saved settings are applied as soon as it exists, before universal.lua and the
	game script, instead of with the rest of the profile. In BedWars the profile waits for the game
	script, half a minute on a cold start, and every notification before it -- Finished Loading
	among them -- used the defaults: the bottom-right corner, still showing when the profile's pair
	arrived and pushing them down the top-left stack. The profile load applies the same values
	again, which changes nothing. Read the way vape:Load reads it: a gui.txt from before v1 has no
	Main settings to use. ]]
	pcall(function()
		local path = 'pistonware/profiles/'..game.GameId..'.gui.txt'
		if not isfile(path) then return end
		local data = loadJson(path)
		local main = data and data.v == 1 and type(data.Categories) == 'table' and data.Categories.Main
		local settings = type(main) == 'table' and main.Settings
		local saved = type(settings) == 'table' and settings.Notifications
		if type(saved) == 'table' then
			notifpane:Load(saved)
		end
	end)

	--[[ Slinky's Main section: Scale, Accent color, Allow input while open. Scale drives the older
	Auto rescale toggle and Scale slider, which keep their save keys but draw no rows. ]]
	local mainPane = vape.Categories.Main.Settings
	local SCALE_PRESETS = {['Small (75%)'] = 0.75, ['Medium (100%)'] = 1, ['Large (125%)'] = 1.25}
	local scalePreset
	local syncingScale = false
	scalePreset = mainPane:CreateDropdown({
		Name = 'Scale preset',
		DisplayName = 'Scale',
		List = {'Auto', 'Small (75%)', 'Medium (100%)', 'Large (125%)'},
		LayoutOrder = -1,
		Function = function(value)
			if syncingScale or vape.Applying then return end
			local factor = SCALE_PRESETS[value]
			local slider = vape.Settings.GUI and vape.Settings.GUI.Options.Scale
			if factor then
				if vape.Scale.Enabled then
					vape.Scale:Toggle()
				end
				if slider then
					slider:SetValue(factor, nil, true)
				end
				scale.Scale = factor
			elseif not vape.Scale.Enabled then
				vape.Scale:Toggle()
			end
		end
	})

	--[[ A profile saved before this dropdown existed carries only the older two settings, so after
	a load it shows what those amount to -- Auto, or the nearest preset -- instead of its default.
	Display only: the scale itself is left as loaded. ]]
	local function syncScalePreset()
		local shown = 'Auto'
		if not vape.Scale.Enabled then
			local slider = vape.Settings.GUI and vape.Settings.GUI.Options.Scale
			local value = slider and slider.Value or scale.Scale
			local gap = math.huge
			for label, factor in SCALE_PRESETS do
				if math.abs(factor - value) < gap then
					shown, gap = label, math.abs(factor - value)
				end
			end
		end
		if scalePreset.Value ~= shown then
			syncingScale = true
			pcall(scalePreset.SetValue, scalePreset, shown)
			syncingScale = false
		end
	end
	local loadScale = vape.Load
	function vape:Load(...)
		local results = table.pack(loadScale(self, ...))
		pcall(syncScalePreset)
		return table.unpack(results, 1, results.n)
	end

	--[[ Off: while the menu is open the movement keys go to the menu, not to your character. ]]
	local contextActionService = cloneref(game:GetService('ContextActionService'))
	local allowInput
	local function applyInputBlock()
		pcall(function()
			contextActionService:UnbindAction('PistonwareMenuInput')
		end)
		if clickgui.Visible and allowInput and not allowInput.Enabled then
			pcall(function()
				contextActionService:BindActionAtPriority('PistonwareMenuInput', function()
					return Enum.ContextActionResult.Sink
				end, false, Enum.ContextActionPriority.High.Value + 100,
					Enum.KeyCode.W, Enum.KeyCode.A, Enum.KeyCode.S, Enum.KeyCode.D, Enum.KeyCode.Space,
					Enum.KeyCode.Up, Enum.KeyCode.Down, Enum.KeyCode.Left, Enum.KeyCode.Right)
			end)
		end
	end
	allowInput = mainPane:CreateToggle({
		Name = 'Allow input while open',
		Default = true,
		LayoutOrder = 1,
		Function = applyInputBlock,
		Tooltip = 'Lets your character keep moving while the menu is open.'
	})
	vape:Clean(clickgui:GetPropertyChangedSignal('Visible'):Connect(applyInputBlock))
	vape:Clean(function()
		pcall(function()
			contextActionService:UnbindAction('PistonwareMenuInput')
		end)
	end)

	-- The GUI card's own badge is the menu key, as Slinky shows it. A phone has no key to press and
	-- opens the menu from the >_ button, so there the badge stays in its hidden row.
	local main = vape.Categories.Main
	if main.GUICard then
		if not isMobile() then
			vape.GUIBind:SetParent(main.GUICard.NameRow)
		end
		vape.GUIBind.Object.Visible = false
	end
end

--[[
	The key footer: the old Pistonware banner with the time left on the key, back as the loader's
	bottom row. It runs along the bottom of the menu window in the loader's console look -- its
	near-black window, grey border and 10 px corners, the >_ badge, the status chevron and word, the
	line in the loader's footer grey -- with the version and a [discord] link on the right, where the
	loader keeps its opt-out. The lines are the old ones word for word; a
	window too narrow for them (a phone in portrait) gets a short form. Built with ui.new rather
	than ui.text so the Inter restyle leaves the console face alone, and inside the window so the
	window's phone zoom applies to it. The expiry is read on every refresh: the loader stores it.
]]
function build.keyFooter()
	local main = vape.Categories.Main
	local window = main and main.Object
	local pages = window and window:FindFirstChild('Pages')
	if not (window and pages) then return end

	-- The loader's own palette (its Window, Border, Badge, Accent, Footer and Line), not the menu theme.
	local CODE = Font.fromEnum(Enum.Font.Code)
	local ORANGE = Color3.fromRGB(240, 122, 31)
	local GREY = Color3.fromRGB(110, 110, 110)
	local LINE = Color3.fromRGB(237, 237, 237)
	local FOOTER_HEIGHT, FOOTER_GAP, TEXT_LEFT = 32, 8, 39

	local bar = ui.new('Frame', {
		Name = 'KeyFooter',
		AnchorPoint = Vector2.new(0.5, 1),
		BackgroundColor3 = Color3.fromRGB(10, 10, 10),
		BackgroundTransparency = 0,
		BorderSizePixel = 0,
		Position = UDim2.new(0.5, 0, 1, 0),
		Size = UDim2.new(1, 0, 0, FOOTER_HEIGHT),
		ZIndex = 2
	}, window)
	ui.corner(bar, 10)
	ui.stroke(bar, Color3.fromRGB(52, 52, 52), 1, 0)
	-- The pages end above it, so the last row of cards is never under the footer.
	pages.Size = UDim2.new(1, 0, 1, -(50 + FOOTER_HEIGHT + FOOTER_GAP))

	local badge = ui.new('TextLabel', {
		BackgroundColor3 = Color3.fromRGB(22, 22, 22),
		BorderSizePixel = 0,
		FontFace = CODE,
		Position = UDim2.fromOffset(7, 6),
		Size = UDim2.fromOffset(24, 20),
		Text = '>_',
		TextColor3 = ORANGE,
		TextSize = 12,
		ZIndex = 2
	}, bar)
	ui.corner(badge, 5)
	local label = ui.new('TextLabel', {
		Name = 'KeyDuration',
		BackgroundTransparency = 1,
		ClipsDescendants = true,
		FontFace = CODE,
		Position = UDim2.fromOffset(TEXT_LEFT, 0),
		RichText = true,
		Size = UDim2.new(1, -200, 1, 0),
		Text = '',
		TextColor3 = GREY,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 2
	}, bar)

	-- The loader's bottom-right corner: the version, and the invite.
	local corner = ui.new('Frame', {
		AnchorPoint = Vector2.new(1, 0.5),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundTransparency = 1,
		Position = UDim2.new(1, -16, 0.5, 0),
		Size = UDim2.fromOffset(0, 22),
		ZIndex = 2
	}, bar)
	ui.list(corner, 14, true, Enum.HorizontalAlignment.Right)
	ui.new('TextLabel', {
		Name = 'Version',
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundTransparency = 1,
		FontFace = CODE,
		LayoutOrder = 2,
		Size = UDim2.fromOffset(0, 22),
		Text = 'v'..vape.Version,
		TextColor3 = GREY,
		TextSize = 14,
		ZIndex = 2
	}, corner)
	local discord = ui.new('TextButton', {
		Name = 'Discord',
		AutoButtonColor = false,
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundTransparency = 1,
		FontFace = CODE,
		LayoutOrder = 1,
		Size = UDim2.fromOffset(0, 22),
		Text = '[discord]',
		TextColor3 = GREY,
		TextSize = 14,
		ZIndex = 2
	}, corner)
	discord.MouseEnter:Connect(function()
		discord.TextColor3 = LINE
	end)
	discord.MouseLeave:Connect(function()
		discord.TextColor3 = GREY
	end)

	local function unit(n, word)
		return n..' '..word..(n == 1 and '' or 's')
	end
	--[[ The old banner's lines and its countdown: days and hours, or hours and minutes under a day. A
	developer run with no expiry is a lifetime key, as before. Returns the loader status word and its
	colour, the chevron, the long line and the value it ends on, and the short line. ]]
	local function state()
		local expire = tonumber(shared.PistonwareKeyExpire)
		if not expire and shared.PistonwareDeveloper then
			expire = -1
		end
		local thanks = 'Thank you for choosing Pistonware.'
		if not expire then
			-- An older loader, or no expiry from the key service: nothing to count down.
			return nil, nil, '>', thanks, '', thanks
		end
		if expire < 0 then
			return 'LIFETIME', '#F07A1F', '>', thanks, '', 'Lifetime key'
		end
		local left = math.max(expire - os.time(), 0)
		if left == 0 then
			return 'EXPIRED', '#E15046', '<', thanks..' Your key has expired.', '', 'Your key has expired.'
		end
		local days, hours, minutes = left // 86400, left % 86400 // 3600, left % 3600 // 60
		local parts = {}
		if days > 0 then table.insert(parts, unit(days, 'day')) end
		if hours > 0 then table.insert(parts, unit(hours, 'hour')) end
		if days == 0 and (minutes > 0 or hours == 0) then table.insert(parts, unit(math.max(minutes, 1), 'minute')) end
		local value = table.concat(parts, ', ')
		return 'KEY', '#F07A1F', '>', thanks..' Remaining Key Duration: ', value, value..' left'
	end

	-- The loader's status line: a grey chevron, the word in its colour, then the line, its value bright.
	local function refresh()
		if vape.ThreadFix then
			setthreadidentity(8)
		end
		local word, hex, chevron, lead, value, short = state()
		local cornerWidth = 120
		pcall(function()
			cornerWidth = getfontbounds('v'..vape.Version, 14, CODE).X + getfontbounds('[discord]', 14, CODE).X + 14
		end)
		local room = window.Size.X.Offset - TEXT_LEFT - cornerWidth - 16 - 12
		label.Size = UDim2.new(1, -(TEXT_LEFT + cornerWidth + 16 + 12), 1, 0)
		local fits = window.Size.X.Offset >= 700
		pcall(function()
			fits = getfontbounds(chevron..' '..(word and word..'  ' or '')..lead..value, 14, CODE).X <= room
		end)
		local body = fits and lead..(value ~= '' and '<font color="#EDEDED">'..value..'</font>' or '')
			or (value ~= '' and '<font color="#EDEDED">'..short..'</font>' or short)
		label.Text = '<font color="#9E9E9E">'..(chevron == '<' and '&lt;' or '&gt;')..'</font> '
			..(word and '<font color="'..hex..'">'..word..'</font>  ' or '')..body
	end

	--[[ The old banner's Discord button, on the right now. The invite goes to your clipboard; on a
	computer Discord's local RPC is asked to open it too, and only a real answer counts as opened --
	some request functions hand back a failure on a closed port instead of throwing. ]]
	local busy = false
	discord.MouseButton1Click:Connect(function()
		if busy then return end
		busy = true
		task.spawn(function()
			local setter = setclipboard or toclipboard
			local copied = type(setter) == 'function' and pcall(setter, 'https://discord.gg/pistonware') or false
			local opened = false
			if not isMobile() then
				local body = httpService:JSONEncode({
					nonce = httpService:GenerateGUID(false),
					args = {invite = {code = 'pistonware'}, code = 'pistonware'},
					cmd = 'INVITE_BROWSER'
				})
				for port = 6454, 6467 do
					local ok, response = pcall(pistonwareRequest, {
						Method = 'POST',
						Url = 'http://127.0.0.1:'..port..'/rpc?v=1',
						Headers = {['Content-Type'] = 'application/json', Origin = 'https://discord.com'},
						Body = body,
						Timeout = 2
					})
					local status = ok and type(response) == 'table' and tonumber(response.StatusCode) or 0
					if ok and type(response) == 'table' and (response.Success == true or (status >= 200 and status < 300)) then
						opened = true
						break
					end
				end
			end
			if opened then
				vape:CreateNotification('Pistonware', 'Opened the Pistonware invite in Discord.', 5, 'success')
			elseif copied and not isMobile() then
				vape:CreateNotification('Pistonware', 'Discord is not running locally. Use the copied invite link.', 5, 'warning')
			elseif copied then
				vape:CreateNotification('Pistonware', 'Discord invite copied to your clipboard.', 5, 'success')
			else
				vape:CreateNotification('Pistonware', 'Join the Discord at discord.gg/pistonware', 8, 'warning')
			end
			busy = false
		end)
	end)

	vape:Clean(clickgui:GetPropertyChangedSignal('Visible'):Connect(function()
		if clickgui.Visible then
			task.spawn(pcall, refresh)
		end
	end))
	-- A rotation or a rescale changes the window's width, and with it which line fits.
	vape:Clean(window:GetPropertyChangedSignal('Size'):Connect(function()
		if clickgui.Visible then
			task.defer(pcall, refresh)
		end
	end))
	-- Every 30 s while the menu is open, the old cadence, so a key running out mid-session shows it.
	vape:Clean(task.spawn(function()
		while true do
			task.wait(30)
			if clickgui.Visible then
				pcall(refresh)
			end
		end
	end))
	task.spawn(pcall, refresh)
end

--[[
	Mod Overlay: the list of active modules in the top-right corner.

	Slinky's arraylist, fixed in the top-right corner: each line on its own rounded dark pill,
	packed edge to edge so the right-aligned edges step down like stairs, the module's name in the
	accent and its detail (the module's ExtraText: a mode, a range) in grey after it, all lowercase
	by default, longest first. Lines are about one em tall, as Slinky packs them, not the font's
	full line height. The options the old Text GUI saved keep their names, so a saved profile
	still applies; the ones Slinky documents are added beside them.
]]
function build.modOverlay()
	local Sort
	local FontOption
	local ColorSlider
	local ColorMode
	local DetailsColor
	local Scale
	local PaddingX
	local PaddingY
	local Rounding
	local PositionX
	local PositionY
	local placeList
	local Shadow
	local Gradient
	local GradientV4
	local Animations
	local Watermark
	local WatermarkStyle
	local Background
	local BackgroundTransparency
	local BackgroundTint
	local Lowercase
	local ShowDetails
	local OnlyBound
	local TabFilters = {}
	local HideModules
	local HideModulesList
	local HideRender
	local CustomText
	local CustomTextBox
	local CustomTextFont
	local CustomTextColor
	local CustomTextColorSlider
	local Labels = {}
	local info = TweenInfo.new(0.3, Enum.EasingStyle.Exponential)

	-- Options that default on run their callback while the rest are still being built.
	local function refresh()
		if vape.UpdateTextGUI then
			vape:UpdateTextGUI()
		end
	end
	-- The part of vape:UpdateGUI these colours affect, with its gates: the overlay's own colours.
	local function recolorTextGUI()
		if vape.Loaded ~= nil and not vape.GUIColor.Rainbow and TextGUI and TextGUI.Button.Enabled and TextGUI.UpdateColor then
			TextGUI:UpdateColor(vape.GUIColor.Hue, vape.GUIColor.Sat, vape.GUIColor.Value)
		end
	end

	TextGUI = vape:CreateOverlay({
		Name = 'Text GUI',
		DisplayName = 'Mod Overlay',
		Tooltip = 'Displays a list of all active mods.',
		CategorySize = 240,
		Fixed = true,
		Function = refresh
	})

	--[[ Slinky's card, in Slinky's order: Visible categories, Customization, Conditions. Everything
	Pistonware adds on top keeps working under Extras at the end. ]]
	TextGUI:CreateDivider({Text = 'Visible categories'})
	for _, tab in TABS do
		-- FFlags holds no modules, so the overlay has nothing to filter there.
		if tab == 'FFlags' then continue end
		TabFilters[tab] = TextGUI:CreateToggle({
			Name = 'Show '..tab,
			DisplayName = tab,
			Default = true,
			Function = refresh
		})
	end

	TextGUI:CreateDivider({Text = 'Customization'})
	TextGUI:CreateSlider({
		Name = 'Scale',
		DisplayName = 'Text size',
		Min = 0.2,
		Max = 2,
		Decimal = 10,
		Default = 0.8,
		Function = function(val)
			Scale.Scale = val * ui.hudZoom()
			refresh()
		end
	})
	PaddingX = TextGUI:CreateSlider({
		Name = 'Padding X',
		Min = 0,
		Max = 8,
		Default = 6,
		Function = refresh
	})
	PaddingY = TextGUI:CreateSlider({
		Name = 'Padding Y',
		Min = 0,
		Max = 5,
		Default = 2,
		Function = refresh
	})
	Rounding = TextGUI:CreateSlider({
		Name = 'Rounding',
		Min = 0,
		Max = 8,
		Default = 3,
		Suffix = 'px',
		Function = refresh,
		Tooltip = '0 turns the rounding off'
	})
	--[[ Where the list sits, in screen pixels: in from the right edge, and down from the top. Both
	start at 0, flush in the corner, where the logo watermark has the top of the screen to itself and
	the list follows straight under it. ]]
	local function movedList()
		if placeList then
			placeList()
		end
	end
	PositionX = TextGUI:CreateSlider({
		Name = 'Position X',
		Min = 0,
		Max = 1000,
		Default = 0,
		Suffix = 'px',
		Function = movedList,
		Tooltip = 'How far in from the right edge of the screen the list sits'
	})
	PositionY = TextGUI:CreateSlider({
		Name = 'Position Y',
		Min = 0,
		Max = 1000,
		Default = 0,
		Suffix = 'px',
		Function = movedList,
		Tooltip = 'How far down from the top of the screen the list sits'
	})
	-- The text colour, starting on the accent. Changing it by hand switches the list from following
	-- the accent to this colour; a profile loading its saved value does not.
	ColorSlider = TextGUI:CreateColorSlider({
		Name = 'Text GUI color',
		DisplayName = 'Text color',
		DefaultHue = vape.GUIColor.Hue,
		DefaultSat = vape.GUIColor.Sat,
		DefaultValue = vape.GUIColor.Value,
		Function = function()
			if vape.Loaded and ColorMode and ColorMode.Value ~= 'Custom color' then
				ColorMode:SetValue('Custom color')
			end
			recolorTextGUI()
		end
	})
	DetailsColor = TextGUI:CreateColorSlider({
		Name = 'Details color',
		-- Slinky's cool grey, (157, 155, 162).
		DefaultHue = 0.7143,
		DefaultSat = 0.0432,
		DefaultValue = 0.6353,
		Function = refresh
	})
	Lowercase = TextGUI:CreateToggle({
		Name = 'Lowercase',
		Default = true,
		Function = refresh
	})
	ShowDetails = TextGUI:CreateToggle({
		Name = 'Show details',
		Default = true,
		Function = refresh,
		Tooltip = 'Shows what a module is set to, usually its mode'
	})

	TextGUI:CreateDivider({Text = 'Conditions'})
	OnlyBound = TextGUI:CreateToggle({
		Name = 'Only bound modules',
		Function = refresh,
		Tooltip = 'Lists only modules that have a key bound'
	})

	TextGUI:CreateDivider({Text = 'Extras'})
	Sort = TextGUI:CreateDropdown({
		Name = 'Sort',
		List = {'Length', 'Alphabetical'},
		Function = refresh
	})
	FontOption = TextGUI:CreateFont({
		Name = 'Font',
		Default = 'Inter',
		Function = refresh
	})
	ColorMode = TextGUI:CreateDropdown({
		Name = 'Color Mode',
		List = {'Match GUI color', 'Custom color'},
		Function = refresh,
		Tooltip = 'Follow the accent, or keep the Text color above'
	})
	Background = TextGUI:CreateToggle({
		Name = 'Render background',
		Default = true,
		Function = function(callback)
			if BackgroundTransparency then
				BackgroundTransparency.Object.Visible = callback
			end
			if BackgroundTint then
				BackgroundTint.Object.Visible = callback
			end
			refresh()
		end
	})
	BackgroundTransparency = TextGUI:CreateSlider({
		Name = 'Transparency',
		Min = 0,
		Max = 1,
		Default = 0.28,
		Decimal = 10,
		Function = refresh,
		Darker = true,
		Visible = Background.Enabled
	})
	BackgroundTint = TextGUI:CreateToggle({
		Name = 'Tint',
		Function = refresh,
		Darker = true,
		Visible = Background.Enabled
	})
	Shadow = TextGUI:CreateToggle({
		Name = 'Shadow',
		Tooltip = 'Renders shadowed text.',
		Function = refresh
	})
	Gradient = TextGUI:CreateToggle({
		Name = 'Gradient',
		Tooltip = 'Fades the colour down the list',
		Function = function(callback)
			GradientV4.Object.Visible = callback
			refresh()
		end
	})
	GradientV4 = TextGUI:CreateToggle({
		Name = 'V4 Gradient',
		Function = refresh,
		Darker = true,
		Visible = false
	})
	Animations = TextGUI:CreateToggle({
		Name = 'Animations',
		Tooltip = 'Slides lines in and out',
		Function = refresh
	})
	Watermark = TextGUI:CreateToggle({
		Name = 'Watermark',
		Tooltip = 'Shows the Pistonware logo above the list',
		Function = function(callback)
			if WatermarkStyle then
				WatermarkStyle.Object.Visible = callback
			end
			refresh()
		end
	})
	WatermarkStyle = TextGUI:CreateDropdown({
		Name = 'Watermark Style',
		List = {'Logo', 'Text'},
		Function = refresh,
		Darker = true,
		Visible = false,
		Tooltip = 'Logo: the Pistonware piston.\nText: the Pistonware name.\nBoth follow Gradient and V4 Gradient.'
	})
	HideModules = TextGUI:CreateToggle({
		Name = 'Hide modules',
		Tooltip = 'Allows you to blacklist certain modules from being shown.',
		Function = function(enabled)
			HideModulesList.Object.Visible = enabled
			refresh()
		end
	})
	HideModulesList = TextGUI:CreateTextList({
		Name = 'Blacklist',
		Tooltip = 'Name of module to hide.',
		Color = Color3.fromRGB(250, 50, 56),
		Function = refresh,
		Visible = false,
		Darker = true
	})
	HideRender = TextGUI:CreateToggle({
		Name = 'Hide render',
		Function = refresh,
		Tooltip = 'Hides the modules that only change what you see'
	})
	CustomText = TextGUI:CreateToggle({
		Name = 'Add custom text',
		Function = function(enabled)
			CustomTextBox.Object.Visible = enabled
			CustomTextFont.Object.Visible = enabled
			CustomTextColor.Object.Visible = enabled
			CustomTextColorSlider.Object.Visible = CustomTextColor.Enabled and enabled
			refresh()
		end
	})
	CustomTextBox = TextGUI:CreateTextBox({
		Name = 'Custom text',
		Function = refresh,
		Darker = true,
		Visible = false
	})
	CustomTextFont = TextGUI:CreateFont({
		Name = 'Custom Font',
		Default = 'Inter',
		Function = refresh,
		Darker = true,
		Visible = false
	})
	CustomTextColor = TextGUI:CreateToggle({
		Name = 'Set custom text color',
		Function = function(enabled)
			CustomTextColorSlider.Object.Visible = enabled
			recolorTextGUI()
		end,
		Darker = true,
		Visible = false
	})
	CustomTextColorSlider = TextGUI:CreateColorSlider({
		Name = 'Color of custom text',
		Function = function()
			recolorTextGUI()
		end,
		Darker = true,
		Visible = false
	})

	--[[ The overlay's objects. ]]
	Scale = Instance.new('UIScale')
	Scale.Parent = TextGUI.Children
	--[[ The Text size, times the HUD's phone zoom, so the lines are still snapped through Scale alone.
	Set here as well as by the slider: a profile that keeps the default never calls its Function, which
	left the list drawn at 1 instead of 0.8. ]]
	local function applyTextSize()
		local option = TextGUI.Options.Scale
		Scale.Scale = (option and option.Value or 0.8) * ui.hudZoom()
	end
	--[[ The list's corner: Position X in from the right edge of the screen and Position Y down from its
	top. A phone's corner belongs to the screen's rounded edge, Roblox's top bar and the >_ button in
	it, so there the list keeps a little room from the edge and stays under both. ]]
	function placeList()
		local s = math.max(scale.Scale, 0.05)
		local x = PositionX and PositionX.Value or 0
		local top = (PositionY and PositionY.Value or 0) / s
		if isMobile() then
			x += 8
			top = math.max(top, ui.insetUnits() + 4 / s)
			local button = vape.VapeButton
			if button and button.Parent then
				top = math.max(top, (button.AbsolutePosition.Y + button.AbsoluteSize.Y + 4) / s)
			end
		end
		TextGUI.Object.Position = UDim2.new(1, -math.floor(x / s), 0, math.floor(top))
	end
	applyTextSize()
	placeList()
	-- Every rescale moves the corner; the list is only rebuilt (re-snapped) when the zoom changed.
	local placedZoom = ui.hudZoom()
	table.insert(ui.hudHooks, function(value)
		placeList()
		if value ~= placedZoom then
			placedZoom = value
			applyTextSize()
			refresh()
		end
	end)
	local Logo = ui.text(TextGUI.Children, {Text = 'Pistonware', Size = 24, Weight = 'Bold', Color = Color3.new(1, 1, 1), Props = {
		Name = 'Logo',
		AutomaticSize = Enum.AutomaticSize.X,
		Position = UDim2.new(1, -142, 0, 3),
		Size = UDim2.fromOffset(0, 28),
		Visible = false
	}})
	local LogoGradient = Instance.new('UIGradient')
	LogoGradient.Rotation = 90
	LogoGradient.Parent = Logo
	--[[ A black outline round the name, so it reads over a bright sky. Contextual, so it follows the
	letters rather than the label's box; the gradient tints the letters only, never the stroke. ]]
	local function outlineText(label)
		local stroke = Instance.new('UIStroke')
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
		stroke.Color = Color3.new()
		stroke.Thickness = 1.5
		stroke.Parent = label
		return stroke
	end
	outlineText(Logo)
	local LogoShadow = ui.text(TextGUI.Children, {Text = 'Pistonware', Size = 24, Weight = 'Bold', Color = Color3.new(), Props = {
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 28),
		TextTransparency = 0.65,
		Visible = false,
		ZIndex = 0
	}})
	--[[ The logo watermark: the square piston face in its own colours, then the Pistonware name as
	the text watermark draws it, with nothing behind them. The name takes the GUI colour and its
	fade like the text watermark; Gradient also tints the face, V4 Gradient across. ]]
	local ascii = {Size = 44, Padding = 0}
	ascii.Height = ascii.Size
	ascii.Frame = Instance.new('Frame')
	ascii.Frame.Name = 'LogoImage'
	ascii.Frame.BackgroundColor3 = Color3.fromRGB(12, 12, 12)
	ascii.Frame.BackgroundTransparency = 1
	ascii.Frame.BorderSizePixel = 0
	ascii.Frame.AutomaticSize = Enum.AutomaticSize.X
	ascii.Frame.Size = UDim2.fromOffset(0, ascii.Size + ascii.Padding * 2)
	ascii.Frame.Visible = false
	ascii.Frame.Parent = TextGUI.Children
	ui.new('UIListLayout', {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
		VerticalAlignment = Enum.VerticalAlignment.Center
	}, ascii.Frame)
	ascii.Image = Instance.new('ImageLabel')
	ascii.Image.BackgroundTransparency = 1
	ascii.Image.Image = getvapeasset('pistonware/assets/new/pistonsquare.png')
	ascii.Image.LayoutOrder = 1
	ascii.Image.ResampleMode = Enum.ResamplerMode.Pixelated
	ascii.Image.Size = UDim2.fromOffset(ascii.Size, ascii.Size)
	ascii.Image.Parent = ascii.Frame
	ascii.Gradient = Instance.new('UIGradient')
	ascii.Gradient.Parent = ascii.Image
	ascii.Text = ui.text(ascii.Frame, {Text = 'Pistonware', Size = 24, Weight = 'Bold', Color = Color3.new(1, 1, 1), Props = {
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = 2,
		Size = UDim2.fromOffset(0, ascii.Size)
	}})
	ascii.TextGradient = Instance.new('UIGradient')
	ascii.TextGradient.Parent = ascii.Text
	outlineText(ascii.Text)

	local LabelCustom = Instance.new('TextLabel')
	LabelCustom.BackgroundTransparency = 1
	LabelCustom.BorderSizePixel = 0
	LabelCustom.FontFace = CustomTextFont.Value
	LabelCustom.Position = UDim2.fromOffset(5, 2)
	LabelCustom.Text = ''
	LabelCustom.TextSize = 25
	LabelCustom.Visible = false
	LabelCustom.RichText = true
	local LabelCustomShadow = LabelCustom:Clone()
	LabelCustomShadow.TextColor3 = Color3.new()
	LabelCustomShadow.TextTransparency = 0.65
	LabelCustomShadow.Parent = TextGUI.Children
	LabelCustom.Parent = TextGUI.Children
	local LabelHolder = Instance.new('Frame')
	LabelHolder.Name = 'Holder'
	LabelHolder.Size = UDim2.fromScale(1, 1)
	LabelHolder.Position = UDim2.fromOffset(5, 37)
	LabelHolder.BackgroundTransparency = 1
	LabelHolder.Parent = TextGUI.Children
	local ListLayout = Instance.new('UIListLayout')
	ListLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	ListLayout.VerticalAlignment = Enum.VerticalAlignment.Top
	ListLayout.SortOrder = Enum.SortOrder.LayoutOrder
	ListLayout.Parent = LabelHolder

	LabelCustom:GetPropertyChangedSignal('Position'):Connect(function()
		LabelCustomShadow.Position = UDim2.new(
			LabelCustom.Position.X.Scale,
			LabelCustom.Position.X.Offset + 1,
			0,
			LabelCustom.Position.Y.Offset + 1
		)
	end)

	LabelCustom:GetPropertyChangedSignal('FontFace'):Connect(function()
		LabelCustomShadow.FontFace = LabelCustom.FontFace
	end)

	LabelCustom:GetPropertyChangedSignal('Text'):Connect(function()
		LabelCustomShadow.Text = contentText(LabelCustom)
	end)

	LabelCustom:GetPropertyChangedSignal('Size'):Connect(function()
		LabelCustomShadow.Size = LabelCustom.Size
	end)

	local oldRight = TextGUI.Children.AbsolutePosition.X > (gui.AbsoluteSize.X / 2)
	vape:Clean(TextGUI.Children:GetPropertyChangedSignal('AbsolutePosition'):Connect(function()
		if vape.ThreadFix then
			setthreadidentity(8)
		end

		local isRight = TextGUI.Children.AbsolutePosition.X > (gui.AbsoluteSize.X / 2)
		if oldRight ~= isRight then
			vape:UpdateTextGUI()
			oldRight = isRight
		end
	end))

	local function escape(text)
		return (tostring(text):gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;'))
	end

	local function hexOf(colorValue)
		return '#'..colorValue:ToHex()
	end

	local textGUIGeneration = 0
	--[[ The list's lines live as long as their module is listed: one line per module, kept and
	updated in place. The list used to be destroyed and rebuilt on every redraw -- each toggle and
	every Killaura hand change -- which made and destroyed up to nine instances a line and measured
	every name again. A redraw now measures only text that changed, reshapes only the lines whose
	own or neighbouring width changed, and adds or removes only the lines that come or go. The look,
	the order and the slide in and out are the same. ]]
	local Lines = {}
	--[[ Redraws are requests. Any number in a frame cost one, run after the callers' code and never
	on their thread: a toggle, Killaura's frame or a profile load no longer waits on a text
	measurement, and a burst (a profile apply, a restart pair) draws once. `afterload` carries over. ]]
	local textGUIQueued, textGUIAfterLoad = false, false
	local rebuildTextGUI
	function vape:UpdateTextGUI(afterload)
		if afterload then
			textGUIAfterLoad = true
		end
		if textGUIQueued then return end
		textGUIQueued = true
		task.defer(function()
			textGUIQueued = false
			local carried = textGUIAfterLoad
			textGUIAfterLoad = false
			if vape.Loaded == nil then return end
			if vape.ThreadFix then
				setthreadidentity(8)
			end
			pcall(rebuildTextGUI, carried)
		end)
	end

	local function sameSize(a, b)
		return a ~= nil and b ~= nil and a.X.Scale == b.X.Scale and a.X.Offset == b.X.Offset
			and a.Y.Scale == b.Y.Scale and a.Y.Offset == b.Y.Offset
	end

	-- A line's background: the windows and fills shapePill (below) made for it.
	local function clearShape(line)
		for _, part in line.Parts do
			part:Destroy()
		end
		table.clear(line.Parts)
		table.clear(line.Fills)
		line.LastTint = nil
		line.ShapeKey = nil
	end

	local function removeLine(name)
		local line = Lines[name]
		if line then
			tween:Cancel(line.Object)
			line.Object:Destroy()
			Lines[name] = nil
		end
	end

	function rebuildTextGUI(afterload)
		if not afterload and not vape.Loaded then return end
		if TextGUI.Button.Enabled then
			--[[ A measure below can yield, and a rebuild that starts meanwhile owns the list from then on:
			this one stops at its next measure instead of adding its lines to the newer list. ]]
			textGUIGeneration += 1
			local generation = textGUIGeneration
			local isRight = TextGUI.Children.AbsolutePosition.X > (gui.AbsoluteSize.X / 2)

			local asciiMark = Watermark.Enabled and WatermarkStyle.Value == 'Logo'
			Logo.Visible = Watermark.Enabled and not asciiMark
			Logo.Position = isRight and UDim2.new(1 / Scale.Scale, -(Logo.AbsoluteSize.X / math.max(scale.Scale * Scale.Scale, 0.05)) - 4, 0, 4) or UDim2.fromOffset(4, 4)
			Logo.TextXAlignment = isRight and Enum.TextXAlignment.Right or Enum.TextXAlignment.Left
			ascii.Frame.Visible = asciiMark
			ascii.Frame.Position = isRight and UDim2.new(1 / Scale.Scale, -(ascii.Frame.AbsoluteSize.X / math.max(scale.Scale * Scale.Scale, 0.05)) - 4, 0, 4) or UDim2.fromOffset(4, 4)
			-- Height the list starts below: the text logo's line, or the whole piston.
			local markHeight = Logo.Visible and 32 or asciiMark and ascii.Height + ascii.Padding * 2 + 8 or 0
			LogoShadow.Visible = Logo.Visible and Shadow.Enabled
			LogoShadow.Position = Logo.Position + UDim2.fromOffset(1, 1)
			LabelCustom.Text = CustomTextBox.Value
			LabelCustom.FontFace = CustomTextFont.Value
			LabelCustom.Visible = LabelCustom.Text ~= '' and CustomText.Enabled
			LabelCustomShadow.Visible = LabelCustom.Visible and Shadow.Enabled
			ListLayout.HorizontalAlignment = isRight and Enum.HorizontalAlignment.Right or Enum.HorizontalAlignment.Left
			LabelHolder.Size = UDim2.fromScale(1 / Scale.Scale, 1)

			if LabelCustom.Visible then
				local size = getfontbounds(contentText(LabelCustom), LabelCustom.TextSize, LabelCustom.FontFace)
				if textGUIGeneration ~= generation then return end
				LabelCustom.Size = UDim2.fromOffset(size.X, size.Y)
				LabelCustom.Position = UDim2.new(isRight and 1 / Scale.Scale or 0, isRight and -size.X or 0, 0, (markHeight > 0 and markHeight + 4 or 8))
			end

			--[[ Every line, and the list's top, lands on whole screen pixels. Offsets cannot do it:
			they are whole local units, and once scaled a unit is a fraction of a pixel, so a line
			that starts or ends part way through one rounds differently from its neighbour -- the
			hairline gaps between the pills. So heights are given as a share of the list's height on
			screen (its 200-unit holder times the menu's scale and the Text size), worked out from
			those numbers rather than read back, so a scale that has only just changed is right too.
			The list starts under the watermark and the custom text. ]]
			local px = math.max(scale.Scale, 0.05) * math.max(Scale.Scale, 0.05)
			local listHeight = TextGUI.Children.Size.Y.Offset * px
			--[[ Widths the same way: a share of the holder's width on screen (the overlay's width at
			the menu's scale; the holder undoes the Text size), so each line's free end lands on a
			whole pixel too. In units it fell part way through one, and the stair edge drew soft. ]]
			local listWidth = TextGUI.Object.Size.X.Offset * math.max(scale.Scale, 0.05)
			local function pixelWidth(units)
				local pixels = math.max(math.floor(units * px + 0.5), 1)
				if listWidth > 0 then
					return UDim.new(pixels / listWidth, 0)
				end
				return UDim.new(0, units)
			end
			local function pixelHeight(units)
				local pixels = math.max(math.floor(units * px + 0.5), 1)
				if listHeight > 0 then
					return UDim.new(pixels / listHeight, 0), pixels / px, pixels
				end
				return UDim.new(0, units), units, pixels
			end
			local top = markHeight
			if LabelCustom.Visible then
				top = LabelCustom.Position.Y.Offset + LabelCustom.Size.Y.Offset + 4
			end
			LabelHolder.Position = top > 0 and UDim2.new(UDim.new(0, 0), (pixelHeight(top))) or UDim2.new()

			local padX, padY = PaddingX.Value, PaddingY.Value
			local detailsHex = hexOf(Color3.fromHSV(DetailsColor.Hue, DetailsColor.Sat, DetailsColor.Value))
			local fontFace = FontOption.Value
			local listed = {}
			table.clear(Labels)
			for name, module in orderedModules(vape.ModuleOrder) do
				if HideModules.Enabled then
					local hidden = false
					local plain, shown = name:lower(), tostring(module.DisplayName or name):lower()
					for _, entry in HideModulesList.ListEnabled do
						local text = tostring(entry):lower()
						if text == plain or text == shown then
							hidden = true
							break
						end
					end
					if hidden then
						continue
					end
				end

				if HideRender.Enabled and module.Category == 'Render' then
					continue
				end

				local filter = TabFilters[module.Tab or 'Utility']
				if filter and not filter.Enabled then
					continue
				end

				if OnlyBound.Enabled and not (module.Bind and #module.Bind.Keys > 0) then
					continue
				end

				local line = Lines[name]
				-- On last time: kept, or slides out if it is off now. Off last time (or never listed)
				-- and off now: not listed, and a line left from its slide out goes below.
				local wasShown = line ~= nil and line.Enabled
				if module.Enabled or wasShown then
					--[[ ExtraText belongs to the game script, not to this file, and it is called
					here for every enabled module on every redraw. A module whose state is not
					ready yet would otherwise throw and abort the whole rebuild. ]]
					local extra = ''
					if ShowDetails.Enabled and module.ExtraText then
						local ok, text = pcall(module.ExtraText)
						if ok and text ~= nil and text ~= '' then
							extra = tostring(text)
						end
					end
					local shown = module.DisplayName or name
					if Lowercase.Enabled then
						shown = shown:lower()
						extra = extra:lower()
					end
					local text = escape(shown)..(extra ~= '' and " <font color='"..detailsHex.."'>"..escape(extra)..'</font>' or '')

					if not line then
						local holder = Instance.new('Frame')
						holder.BackgroundTransparency = 1
						holder.ClipsDescendants = true
						holder.Name = name
						holder.Size = UDim2.fromOffset()
						holder.Parent = LabelHolder

						-- The background is shaped once the list is sorted (shapePill, below): its corners depend on
						-- the lines above and below. The text draws over it, and over its shadow, which is
						-- parented first so it draws underneath; it is hidden while Shadow is off.
						local label = Instance.new('TextLabel')
						label.BackgroundTransparency = 1
						label.BorderSizePixel = 0
						label.FontFace = fontFace
						label.ZIndex = 2
						label.RichText = true
						label.TextSize = 20
						label.TextXAlignment = Enum.TextXAlignment.Left
						local shadowlabel = label:Clone()
						shadowlabel.TextColor3 = Color3.new()
						shadowlabel.TextTransparency = 0.5
						shadowlabel.Visible = false
						shadowlabel.Parent = holder
						label.Parent = holder
						line = {Object = holder, Text = label, Shadow = shadowlabel, Fills = {}, Parts = {}, Enabled = false}
						Lines[name] = line
					end
					listed[name] = true
					local label, shadowlabel = line.Text, line.Shadow

					-- Measured again only when the text or font changed. Recorded once measured, so a
					-- rebuild that takes over during the measure measures it itself.
					if line.Markup ~= text or line.Font ~= fontFace then
						label.FontFace = fontFace
						label.Text = text
						local size = getfontbounds(contentText(label), label.TextSize, label.FontFace)
						if textGUIGeneration ~= generation then return end
						label.Size = UDim2.fromOffset(size.X, size.Y)
						shadowlabel.FontFace = fontFace
						shadowlabel.Text = contentText(label)
						shadowlabel.Size = label.Size
						line.Markup, line.Font, line.Measure = text, fontFace, size
					end
					local size = line.Measure

					--[[ A line is 1 em plus the padding: Slinky's list at 1080p puts its lines 19 px apart
					for 16 px text, which is Text size 0.8 with Padding Y 2 here. The glyphs sit at 0.59
					of the label's height, so the label is placed to centre them in the box. ]]
					local boxScale, boxHeight, boxPixels = pixelHeight(label.TextSize + padY * 2)
					local textY = math.floor(boxHeight / 2 - size.Y * 0.587 + 0.5)
					if line.PadX ~= padX or line.TextY ~= textY then
						line.PadX, line.TextY = padX, textY
						label.Position = UDim2.fromOffset(padX, textY)
						shadowlabel.Position = UDim2.fromOffset(padX + 1, textY + 1)
					end
					if shadowlabel.Visible ~= Shadow.Enabled then
						shadowlabel.Visible = Shadow.Enabled
					end

					local holder = line.Object
					local tweenSize = UDim2.new(pixelWidth(size.X + padX * 2), boxScale)
					if Animations.Enabled then
						if not wasShown then
							-- Coming in (new, or back while still sliding out): from nothing, as a new line did.
							tween:Cancel(holder)
							holder.Size = UDim2.fromOffset()
							tween:Tween(holder, info, {
								Size = tweenSize
							})
						elseif module.Enabled then
							-- Staying: a new width applies at once; a slide in still running carries on.
							if not sameSize(line.Target, tweenSize) then
								tween:Cancel(holder)
								holder.Size = tweenSize
							end
						else
							-- Leaving: from where it is to nothing; it goes with the next redraw.
							tween:Tween(holder, info, {
								Size = UDim2.fromOffset()
							})
						end
					else
						tween:Cancel(holder)
						holder.Size = module.Enabled and tweenSize or UDim2.fromOffset()
					end

					line.Enabled = module.Enabled
					line.Target = tweenSize
					line.Width = size.X
					line.Height = boxHeight
					line.Pixels = boxPixels
					line.Display = shown
					line.Size = module.Enabled and tweenSize or UDim2.fromOffset()
					table.insert(Labels, line)
				end
			end

			-- Lines whose module left the list, or that finished sliding out, go now.
			for name in Lines do
				if not listed[name] then
					removeLine(name)
				end
			end

			if Sort.Value == 'Alphabetical' then
				table.sort(Labels, function(a, b)
					return a.Display < b.Display
				end)
			else
				table.sort(Labels, function(a, b)
					if a.Width == b.Width then return a.Display < b.Display end
					return a.Width > b.Width
				end)
			end

			for index, label in Labels do
				if label.Object.LayoutOrder ~= index then
					label.Object.LayoutOrder = index
				end
			end

			--[[ Rounded the way Slinky rounds its list: only the corners that stick out -- a line's top
			corner when the line above is narrower or there is none, its bottom corner when the line
			below is -- so where the stair steps in, the two lines meet square and the outline runs
			smooth. A corner rounds no further than its step is wide: two names a few pixels apart
			used to get the full radius, which curved in past the line under it and bit a notch out of
			the stair. Roblox rounds all four corners of a frame or none, so each background is two
			halves, each a clipped window onto a frame the height of the whole line that is rounded or
			not; the split falls on a whole pixel, so the halves leave no seam. The side against the
			screen edge is never rounded. Rounding is in Slinky's units, 1.6 pixels each. A line is
			reshaped only when something its shape is made from changed. ]]
			local radius = math.floor(Rounding.Value * 1.6 + 0.5)
			local transparency = BackgroundTransparency.Value
			local tinted = BackgroundTint.Enabled
			-- How far a corner may round against the line beside it: all the way at the list's ends.
			local function stepRadius(label, other)
				if not other then return radius end
				return math.clamp(math.floor(label.Width - other.Width), 0, radius)
			end
			local function shapePill(label, topRadius, bottomRadius)
				local pixels = math.max(label.Pixels or 1, 1)
				local split = pixels > 1 and math.floor(pixels / 2) / pixels or 1
				local most = math.floor((label.Height or 0) / 2)
				-- The tint is in the key: a fill that was tinted goes back to the plain colour by being made again.
				local key = table.concat({topRadius, bottomRadius, most, pixels, isRight and 1 or 0, transparency, tinted and 1 or 0}, ':')
				if label.ShapeKey == key then return end
				clearShape(label)
				label.ShapeKey = key
				for half = 1, split < 1 and 2 or 1 do
					local share = half == 1 and split or 1 - split
					-- One frame for the whole line takes the larger of the two.
					local corner = math.min(split < 1 and (half == 1 and topRadius or bottomRadius) or math.max(topRadius, bottomRadius), most)
					local window = Instance.new('Frame')
					window.BackgroundTransparency = 1
					window.BorderSizePixel = 0
					window.ClipsDescendants = true
					window.Position = UDim2.fromScale(0, half == 1 and 0 or split)
					window.Size = UDim2.fromScale(1, share)
					window.ZIndex = 1
					window.Parent = label.Object
					local fill = Instance.new('Frame')
					fill.BackgroundColor3 = Color3.fromRGB(12, 12, 12)
					fill.BackgroundTransparency = transparency
					fill.BorderSizePixel = 0
					fill.Position = UDim2.new(0, isRight and 0 or -corner, half == 1 and 0 or 1 - 1 / share, 0)
					fill.Size = UDim2.new(1, corner, 1 / share, 0)
					fill.ZIndex = 1
					fill.Parent = window
					if corner > 0 then
						local round = Instance.new('UICorner')
						round.CornerRadius = UDim.new(0, corner)
						round.Parent = fill
					end
					table.insert(label.Parts, window)
					table.insert(label.Fills, fill)
				end
			end
			if Background.Enabled then
				local showing = {}
				for _, label in Labels do
					if label.Enabled then
						table.insert(showing, label)
					else
						-- On its way out; it closes to nothing either way.
						shapePill(label, radius, radius)
					end
				end
				for index, label in showing do
					local above, below = showing[index - 1], showing[index + 1]
					shapePill(label, stepRadius(label, above), stepRadius(label, below))
				end
			else
				for _, label in Labels do
					if label.ShapeKey then
						clearShape(label)
					end
				end
			end
		end

		--[[ A profile load recolours the whole menu, as it always has. Any other redraw changes only
		the list, so only the list is recoloured -- with UpdateGUI's own gates. Recolouring the menu
		too, on every toggle and every Killaura hand change, repainted every card in it. ]]
		if afterload then
			vape:UpdateGUI(vape.GUIColor.Hue, vape.GUIColor.Sat, vape.GUIColor.Value, true)
		elseif vape.Loaded ~= nil and TextGUI.Button.Enabled then
			TextGUI:UpdateColor(vape.GUIColor.Hue, vape.GUIColor.Sat, vape.GUIColor.Value, true)
		end
	end

	function TextGUI:UpdateColor(hue, sat, val, default)
		local base = Color3.fromHSV(hue, sat, val)
		local v4 = Gradient.Enabled and GradientV4.Enabled
		local fade = Gradient.Enabled and Color3.fromHSV(vape:Color((hue - (v4 and 0.15 or 0.075)) % 1)) or base
		-- The logo gradients only while a watermark shows; turning one on redraws, which lands here.
		if Logo.Visible or ascii.Frame.Visible then
			LogoGradient.Rotation = v4 and 0 or 90
			LogoGradient.Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, base),
				ColorSequenceKeypoint.new(1, fade)
			})
		end
		--[[ The piston keeps its own colours unless Gradient is on: then it is tinted from the GUI
		colour to the fade, down the face, or across it with V4 Gradient. ]]
		if ascii.Frame.Visible then
			ascii.Gradient.Rotation = v4 and 0 or 90
			ascii.Gradient.Color = Gradient.Enabled and ColorSequence.new({
				ColorSequenceKeypoint.new(0, base),
				ColorSequenceKeypoint.new(1, fade)
			}) or ColorSequence.new(Color3.new(1, 1, 1))
			ascii.TextGradient.Rotation = LogoGradient.Rotation
			ascii.TextGradient.Color = LogoGradient.Color
		end
		if LabelCustom.Visible then
			LabelCustom.TextColor3 = CustomTextColor.Enabled and Color3.fromHSV(CustomTextColorSlider.Hue, CustomTextColorSlider.Sat, CustomTextColorSlider.Value) or base
		end

		local isCustom = ColorMode.Value == 'Custom color' and Color3.fromHSV(ColorSlider.Hue, ColorSlider.Sat, ColorSlider.Value) or nil
		for index, label in Labels do
			local textColor = isCustom
			if not textColor then
				if vape.GUIColor.Rainbow then
					textColor = Color3.fromHSV(vape:Color((hue - ((Gradient.Enabled and index + 2 or index) * 0.025)) % 1))
				elseif Gradient.Enabled then
					textColor = base:Lerp(fade, math.clamp((index - 1) / math.max(#Labels - 1, 1), 0, 1))
				else
					textColor = base
				end
			end
			-- Written only when it changed: a redraw that moved nothing recolours nothing.
			if label.LastColor ~= textColor then
				label.LastColor = textColor
				label.Text.TextColor3 = textColor
			end

			if BackgroundTint.Enabled then
				local tint = color.Dark(textColor, 0.75)
				if label.LastTint ~= tint then
					label.LastTint = tint
					for _, fill in label.Fills or {} do
						fill.BackgroundColor3 = tint
					end
				end
			end
		end
	end
end

function build.targetInfo()
	--[[ Target Info: the target's avatar in a ring of their health colour, their name and distance on
	top, their health and a full-width bar under it. Drawn in the menu's own type. With the
	background on it sits on a dark rounded card; with it off every label turns bright with a dark
	outline and the bar keeps a dark track and rim, so it reads over anything. A hit shows on the
	bar at once; only healing slides. ]]
	local CARD = {
		Window = Color3.fromRGB(16, 16, 16),
		Border = Color3.fromRGB(255, 255, 255),
		Name = Color3.fromRGB(240, 240, 240),
		Muted = Color3.fromRGB(150, 150, 150),
		Bright = Color3.fromRGB(225, 225, 225),
		Tile = Color3.fromRGB(34, 34, 34),
		Green = theme.Green,
		Yellow = theme.Yellow,
		Red = theme.Red
	}
	local WIDTH, HEIGHT, AVATAR, PAD = 280, 64, 44, 10
	local targetinfo = {
		Targets = {},
		Object = nil,
		Health = 0,
		MaxHealth = 0
	}
	local TargetInfoOverlay
	local BackgroundTransparency = {
		Value = 0.15,
		Object = {Visible = {}}
	}
	local BorderColor
	local BKGColor
	local CustomColor
	local DisplayName
	local Border
	local DamageTint
	local FollowTarget
	local localPlayer = cloneref(game:GetService('Players')).LocalPlayer
	-- backgroundOn: the card is drawn. carded: it is solid enough for the card's quiet styling.
	local backgroundOn, carded = true, true

	--[[ The game scripts record every hit here whether or not the card is on, and only Update (which
	runs while it is) let expired ones go: with it off they piled up for the whole session. ]]
	vape:Clean(task.spawn(function()
		repeat
			task.wait(2)
			if not (TargetInfoOverlay and TargetInfoOverlay.Button and TargetInfoOverlay.Button.Enabled) then
				local now = tick()
				for target, expire in targetinfo.Targets do
					if type(expire) ~= 'number' or expire < now then
						targetinfo.Targets[target] = nil
					end
				end
			end
		until false
	end))

	TargetInfoOverlay = vape:CreateOverlay({
		Name = 'Target Info',
		Tooltip = 'Shows who you are fighting and how much health they have left.',
		CategorySize = WIDTH,
		Function = function(callback)
			if callback then
				TargetInfoOverlay:Clean(runService.RenderStepped:Connect(function()
					targetinfo:Update()
				end))
			end
		end
	})

	local Holder = ui.new('Frame', {
		BackgroundColor3 = CARD.Window,
		BackgroundTransparency = BackgroundTransparency.Value,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(WIDTH, HEIGHT)
	}, TargetInfoOverlay.Children)
	targetinfo.Object = Holder
	ui.corner(Holder, 20)
	local Stroke = ui.stroke(Holder, CARD.Border, 1, 0.9)
	-- Damage Tint: a red wash under the avatar and the words, raised for a moment when you are hit.
	local Tint = ui.new('Frame', {
		Name = 'DamageTint',
		BackgroundColor3 = Color3.fromRGB(235, 55, 55),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1)
	}, Holder)
	ui.corner(Tint, 20)

	-- Their avatar, in a ring of their health colour: the one cue that reads with or without the card.
	local Headshot = ui.new('ImageLabel', {
		Name = 'Avatar',
		BackgroundColor3 = CARD.Tile,
		BorderSizePixel = 0,
		Image = 'rbxthumb://type=AvatarHeadShot&id=1&w=150&h=150',
		Position = UDim2.fromOffset(PAD, (HEIGHT - AVATAR) / 2),
		Size = UDim2.fromOffset(AVATAR, AVATAR)
	}, Holder)
	ui.corner(Headshot, UDim.new(1, 0))
	local Ring = ui.stroke(Headshot, CARD.Green, 2, 0)

	local left = PAD + AVATAR + 10
	local Title = ui.text(Holder, {Text = 'No target', Size = 15, Weight = 'SemiBold', Color = CARD.Name, Props = {
		Name = 'Name',
		Position = UDim2.fromOffset(left, 8),
		Size = UDim2.new(1, -(left + PAD), 0, 20),
		TextTruncate = Enum.TextTruncate.AtEnd
	}})
	local Distance = ui.text(Holder, {Text = '', Size = 13, Weight = 'Medium', Color = CARD.Muted, AlignX = Enum.TextXAlignment.Right, Props = {
		Name = 'Distance',
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -PAD, 0, 8),
		Size = UDim2.fromOffset(48, 20)
	}})
	--[[ The name takes whatever the distance leaves. Estimated per character rather than measured:
	Potassium reports Inter's TextBounds at 0.83x. ]]
	local function fitTitle(distance)
		local reserve = distance == '' and 0 or #distance * 8 + 8
		Title.Size = UDim2.new(1, -(left + PAD + reserve), 0, 20)
	end
	-- Their health and heart in the health colour, then the maximum, smaller, beside it.
	local HealthRow = ui.new('Frame', {
		Name = 'HealthRow',
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(left, 28),
		Size = UDim2.new(1, -(left + PAD), 0, 18)
	}, Holder)
	ui.list(HealthRow, 5, true)
	local HealthText = ui.text(HealthRow, {Text = '', Size = 14, Weight = 'Bold', Color = CARD.Green, Props = {
		Name = 'Health',
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = 1,
		Size = UDim2.fromOffset(0, 18)
	}})
	local MaxText = ui.text(HealthRow, {Text = '', Size = 12, Weight = 'Medium', Color = CARD.Muted, Props = {
		Name = 'MaxHealth',
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = 2,
		Size = UDim2.fromOffset(0, 18)
	}})

	for _, label in {Title, Distance, HealthText, MaxText} do
		label.TextStrokeColor3 = Color3.new()
	end

	local Bar = ui.new('Frame', {
		Name = 'HealthBar',
		BackgroundColor3 = Color3.new(1, 1, 1),
		BackgroundTransparency = 0.88,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(left, 49),
		Size = UDim2.new(1, -(left + PAD), 0, 6)
	}, Holder)
	ui.corner(Bar, UDim.new(1, 0))
	-- Without the card, a dark rim gives the bar an edge even when the fill covers the whole track.
	local BarRim = ui.stroke(Bar, Color3.new(), 1, 0.5)
	BarRim.Enabled = false
	local Fill = ui.new('Frame', {
		BackgroundColor3 = CARD.Green,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1)
	}, Bar)
	ui.corner(Fill, UDim.new(1, 0))
	Fill:GetPropertyChangedSignal('Size'):Connect(function()
		Fill.Visible = Fill.Size.X.Scale > 0.01
	end)

	-- The menu's own green above half, its yellow down to a fifth, its red below.
	local function healthColor(percent)
		if percent > 0.5 then
			return CARD.Green
		elseif percent >= 0.2 then
			return CARD.Yellow
		end
		return CARD.Red
	end

	local shownHealth, shownMax = 20, 20
	local function paintHealthText()
		local percent = shownMax > 0 and math.clamp(shownHealth / shownMax, 0, 1) or 0
		HealthText.TextColor3 = healthColor(percent)
		HealthText.Text = math.floor(shownHealth + 0.5)..' \u{2665}'
		MaxText.TextColor3 = carded and CARD.Muted or CARD.Bright
		MaxText.Text = '/ '..math.floor(shownMax + 0.5)
	end

	--[[ The bar slides a little on a hit (0.12 s, easing out so it lands at once and settles) and a
	little slower on a heal; a new target snaps, so it never drains from the last one's health. ]]
	local BAR_SLIDE = {
		drop = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		heal = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	}
	local function showHealth(health, maxHealth, mode)
		shownHealth, shownMax = health, maxHealth
		local percent = maxHealth > 0 and math.clamp(health / maxHealth, 0, 1) or 0
		local colour = healthColor(percent)
		paintHealthText()
		Ring.Color = colour
		local slide = BAR_SLIDE[mode]
		if slide then
			tween:Tween(Fill, slide, {
				Size = UDim2.fromScale(percent, 1),
				BackgroundColor3 = colour
			})
		else
			tween:Cancel(Fill)
			Fill.Size = UDim2.fromScale(percent, 1)
			Fill.BackgroundColor3 = colour
		end
	end
	-- What the window shows with the menu open and nobody targeted.
	showHealth(20, 20, 'snap')

	--[[ Coming and going, faded instead of popping in: the card fades in, then the avatar, the name,
	the health and the bar follow it a beat apart, and it all fades back out, bar first, when the
	fight ends. Nothing moves while you fight: a hit or a new target changes the words in place. A
	hit on you washes the card red for a moment (Damage Tint). Driven from Update, which already
	runs every frame, and written only while something is changing. `look` holds each part's resting
	transparency; paint fades from it. ]]
	local IN_TIME, OUT_TIME, HURT_TIME, HURT_STRENGTH = 0.4, 0.22, 0.45, 0.55
	local anim = {Show = 0, Hurt = 0, Clock = os.clock()}
	local ORIGIN = UDim2.new()
	local look = {Card = BackgroundTransparency.Value, Border = 0.9, Outline = 1, Track = 0.88, Rim = 0.5}
	local function ease(x)
		x = math.clamp(x, 0, 1)
		return 1 - (1 - x) ^ 4
	end
	-- Each part starts `delay` into the show and takes the rest of it to arrive.
	local function shown(delay)
		return ease((anim.Show - delay) / (1 - 0.3))
	end
	local function fade(rest, alpha)
		return 1 - (1 - rest) * alpha
	end
	local function paint()
		local card, avatar, bar = shown(0), shown(0.08), shown(0.3)
		local name, health = shown(0.16), shown(0.24)
		Holder.BackgroundTransparency = fade(look.Card, card)
		Tint.BackgroundTransparency = 1 - HURT_STRENGTH * ease(anim.Hurt) * card
		Stroke.Transparency = fade(look.Border, card)
		Headshot.BackgroundTransparency = fade(0, avatar)
		Headshot.ImageTransparency = fade(0, avatar)
		Ring.Transparency = fade(0, avatar)
		Title.TextTransparency = fade(0, name)
		Title.TextStrokeTransparency = fade(look.Outline, name)
		Distance.TextTransparency = fade(0, name)
		Distance.TextStrokeTransparency = fade(look.Outline, name)
		for _, label in {HealthText, MaxText} do
			label.TextTransparency = fade(0, health)
			label.TextStrokeTransparency = fade(look.Outline, health)
		end
		Bar.BackgroundTransparency = fade(look.Track, bar)
		BarRim.Transparency = fade(look.Rim, bar)
		Fill.BackgroundTransparency = fade(0, bar)
	end

	--[[ Off, the card goes and the words carry themselves: bright, with a dark outline, and the bar
	gets a dark track and rim instead of the faint light track that only reads on the card. A card
	Transparency has made mostly see-through counts as off here, or the grey comes back. ]]
	local function setBackground(on, transparency)
		backgroundOn = on
		carded = on and transparency < 0.5
		look.Card = on and transparency or 1
		Stroke.Enabled = on and (Border == nil or Border.Enabled)
		look.Outline = carded and 1 or 0.45
		Distance.TextColor3 = carded and CARD.Muted or CARD.Bright
		Bar.BackgroundColor3 = carded and Color3.new(1, 1, 1) or Color3.new()
		look.Track = carded and 0.88 or 0.35
		BarRim.Enabled = not carded
		paintHealthText()
		paint()
	end

	-- Kept for saved profiles; the labels follow the menu's own type through the font registry.
	TargetInfoOverlay:CreateFont({
		Name = 'Font',
		Default = 'Inter',
		Function = function() end
	})
	DisplayName = TargetInfoOverlay:CreateToggle({
		Name = 'Use Displayname',
		Default = true
	})
	DamageTint = TargetInfoOverlay:CreateToggle({
		Name = 'Damage Tint',
		Default = true,
		Tooltip = 'Flashes the card red for a moment when you take damage.'
	})
	FollowTarget = TargetInfoOverlay:CreateToggle({
		Name = 'Follow Target',
		Default = false,
		Tooltip = 'Shows the card beside the player you are fighting instead of in its window.\nIt returns to its window while the menu is open.'
	})
	local RenderBackground
	RenderBackground = TargetInfoOverlay:CreateToggle({
		Name = 'Render Background',
		Function = function(callback)
			setBackground(callback, BackgroundTransparency.Value)
			BackgroundTransparency.Object.Visible = callback
		end,
		Default = true
	})
	BackgroundTransparency = TargetInfoOverlay:CreateSlider({
		Name = 'Transparency',
		Min = 0,
		Max = 1,
		Default = 0.15,
		Decimal = 100,
		Function = function(val)
			if RenderBackground == nil or RenderBackground.Enabled then
				setBackground(true, val)
			end
		end,
		Darker = true
	})
	CustomColor = TargetInfoOverlay:CreateToggle({
		Name = 'Custom Color',
		Function = function(callback)
			BKGColor.Object.Visible = callback
			Holder.BackgroundColor3 = callback and Color3.fromHSV(BKGColor.Hue, BKGColor.Sat, BKGColor.Value) or CARD.Window
		end
	})
	BKGColor = TargetInfoOverlay:CreateColorSlider({
		Name = 'Color',
		DefaultValue = 0.06,
		DefaultSat = 0,
		Function = function(hue, sat, val)
			if CustomColor.Enabled then
				Holder.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
			end
		end,
		Darker = true,
		Visible = false
	})
	Border = TargetInfoOverlay:CreateToggle({
		Name = 'Border',
		Default = true,
		Function = function(callback)
			Stroke.Enabled = callback and backgroundOn
			if BorderColor then
				BorderColor.Object.Visible = callback
			end
		end
	})
	BorderColor = TargetInfoOverlay:CreateColorSlider({
		Name = 'Border Color',
		DefaultHue = 0,
		DefaultSat = 0,
		DefaultValue = 1,
		DefaultOpacity = 0.1,
		Function = function(hue, sat, val, opacity)
			Stroke.Color = Color3.fromHSV(hue, sat, val)
			look.Border = 1 - opacity
			paint()
		end,
		Darker = true,
		Visible = Border.Enabled
	})

	function targetinfo:Update()
		if not vape.Libraries then return end

		-- One pass, no copy: expiry and the highest-priority search fold into the same walk.
		local now = tick()
		local entity, highest = nil, now
		for target, expire in self.Targets do
			if expire < now then
				self.Targets[target] = nil
			elseif expire > highest then
				entity = target
				highest = expire
			end
		end

		-- Eased in and out (see paint); nothing is written once it has settled.
		local clock = os.clock()
		local dt = math.min(clock - anim.Clock, 0.1)
		anim.Clock = clock
		local moved = false
		--[[ Follow Target: where the target is on screen, so the card can sit beside them; false
		while they are off screen (the card fades out), nil to stay in the window -- always with
		the menu open, where it is moved and set up. ]]
		local follow
		if entity and FollowTarget and FollowTarget.Enabled and not clickgui.Visible then
			local root = entity.RootPart
			local camera = workspace.CurrentCamera
			follow = false
			-- Dead (no health, or their character gone): it lets go of them at once and fades out.
			local alive = (entity.Health or 0) > 0 and entity.Character ~= nil and entity.Character.Parent ~= nil
			if alive and root and root.Parent and camera then
				--[[ Level with their head (the head itself, or a little above the body when there is
				none), and to the right of their shoulder rather than their middle: that edge is
				projected too, so the card clears them however near or far they are. The menu's
				ScreenGui ignores the top bar inset, so its pixels are the viewport's. ]]
				local head = entity.Head
				local headPosition = head and head.Parent and head.Position or root.Position + Vector3.new(0, (entity.HipHeight or 2) + 1.5, 0)
				local shoulder = headPosition + camera.CFrame.RightVector * 2.2
				local project = (vape.gui and vape.gui.IgnoreGuiInset) and camera.WorldToViewportPoint or camera.WorldToScreenPoint
				local point, onScreen = project(camera, headPosition)
				if onScreen then
					follow = Vector2.new(project(camera, shoulder).X, point.Y)
				end
			end
		end
		local wanted = (entity ~= nil and follow ~= false or clickgui.Visible) and 1 or 0
		if anim.Show ~= wanted then
			anim.Show = wanted > anim.Show and math.min(anim.Show + dt / IN_TIME, 1) or math.max(anim.Show - dt / OUT_TIME, 0)
			moved = true
		end
		--[[ Your own health, for Damage Tint: a drop since the last frame washes the card red. The
		Humanoid is looked up again only when your character changes. ]]
		local character = localPlayer.Character
		if anim.Character ~= character then
			anim.Character = character
			anim.Humanoid = character and character:FindFirstChildOfClass('Humanoid')
			anim.MyHealth = nil
		end
		local myHealth = anim.Humanoid and anim.Humanoid.Parent and anim.Humanoid.Health
		if myHealth then
			if anim.MyHealth and myHealth < anim.MyHealth - 0.01 and DamageTint and DamageTint.Enabled then
				anim.Hurt = 1
				moved = true
			end
			anim.MyHealth = myHealth
		elseif character then
			-- Built a moment after the character itself: keep looking until it is there.
			anim.Character = nil
		end
		if anim.Hurt > 0 then
			anim.Hurt = math.max(anim.Hurt - dt / HURT_TIME, 0)
			moved = true
		end
		local visible = anim.Show > 0
		if Holder.Visible ~= visible then
			Holder.Visible = visible
		end
		if moved then
			paint()
		end
		--[[ Beside the target: a little right of their shoulder and centred on their head, kept inside
		the screen. The card lives in its overlay window, so the screen point is turned back into an
		offset from that window, at the scale the card is drawn at. Back at the window's corner
		otherwise. ]]
		local position = ORIGIN
		local parent = Holder.Parent
		local size = Holder.AbsoluteSize
		if follow == false then
			-- Off screen or dead: it fades out where it last was, not back in its window.
			position = Holder.Position
		elseif follow and parent and size.X > 0 then
			local s = size.X / WIDTH
			local screen = vape.gui and vape.gui.AbsoluteSize or Vector2.new(1920, 1080)
			local x = math.clamp(follow.X + 10 * s, 0, math.max(screen.X - size.X, 0))
			--[[ A card hung under this one goes along with it -- Show Inventory's, in BedWars -- so the
			bottom kept on screen is the lower card's while it is shown. ]]
			local below = 0
			local inventory = Holder:FindFirstChild('Inventory')
			if inventory and inventory:IsA('GuiObject') and inventory.Visible then
				below = math.max(inventory.AbsolutePosition.Y + inventory.AbsoluteSize.Y - (Holder.AbsolutePosition.Y + size.Y), 0)
			end
			local y = math.clamp(follow.Y - size.Y / 2, 0, math.max(screen.Y - size.Y - below, 0))
			-- The window's corner in the viewport's space: AbsolutePosition is measured below Roblox's top
			-- bar and the projected point from the true top, and the menu's root frame sits at the latter.
			local base = parent.AbsolutePosition - (scaledgui and scaledgui.AbsolutePosition or Vector2.zero)
			position = UDim2.fromOffset(math.floor((x - base.X) / s + 0.5), math.floor((y - base.Y) / s + 0.5))
		end
		if Holder.Position ~= position then
			Holder.Position = position
		end
		if entity then
			--[[ NameHider, applied here rather than left to catch this from outside: this writes
			the real name every frame, and a watcher rewriting it would only fight it. ]]
			local hideName = shared.PistonwareHideName
			local shown = entity.Player and (DisplayName.Enabled and entity.Player.DisplayName or entity.Player.Name) or entity.Character and entity.Character.Name or Title.Text
			if type(hideName) == 'function' then
				local ok, res = pcall(hideName, shown)
				if ok and type(res) == 'string' then shown = res end
			end
			if Title.Text ~= shown then
				Title.Text = shown
			end

			local thumb = 'rbxthumb://type=AvatarHeadShot&id='..(entity.Player and entity.Player.UserId or 1)..'&w=150&h=150'
			local hideThumb = shared.PistonwareHideThumb
			if type(hideThumb) == 'function' then
				local ok, res = pcall(hideThumb, thumb)
				if ok and type(res) == 'string' then thumb = res end
			end
			if Headshot.Image ~= thumb then
				Headshot.Image = thumb
			end

			if not entity.Character then
				entity.Health = entity.Health or 0
				entity.MaxHealth = entity.MaxHealth or 100
			end

			-- Distance from wherever the camera is following; blank while you are dead.
			local root = entity.RootPart
			local camera = workspace.CurrentCamera
			local me = camera and camera.CameraSubject
			me = me and (me:IsA('Humanoid') and me.RootPart or me:IsA('BasePart') and me) or nil
			local distance = (root and root.Parent and me) and math.floor((root.Position - me.Position).Magnitude + 0.5)..'m' or ''
			if Distance.Text ~= distance then
				Distance.Text = distance
				fitTitle(distance)
			end

			if entity.Health ~= self.Health or entity.MaxHealth ~= self.MaxHealth then
				-- A new target snaps too: sliding from the last one's health would read as a hit.
				local switched = self.LastTarget ~= entity
				showHealth(entity.Health, entity.MaxHealth, switched and 'snap' or self.Health > entity.Health and 'drop' or 'heal')
				self.Health = entity.Health
				self.MaxHealth = entity.MaxHealth
			end

			if not entity.Character then
				table.clear(entity)
			end

			self.LastTarget = entity
		end
	end

	vape.Libraries.targetinfo = targetinfo
end


function build.loops()
	vape:Clean(task.spawn(function()
		local hue = 0
		repeat
			--[[
				Idle at 4Hz while nothing is on rainbow.

				This thread woke at the rainbow update rate -- up to 144 times a second by
				default 60 -- whether or not a single slider had rainbow switched on, and for
				most users none ever is. An empty loop body is cheap, but the wakeup itself is
				not free on a phone, and a GUISlider on rainbow drives vape:UpdateGUI, so the
				whole thing is only worth paying for when there is something to animate.

				hue is not advanced while parked: nothing is reading it, and resuming from
				where it left off is what makes switching rainbow on look continuous rather
				than jumping to wherever a free-running counter happened to be.
			]]
			if #vape.RainbowSliders == 0 then
				task.wait(0.25)
				continue
			end

			--[[ One at a time, each protected: a slider that throws (or one whose module was
			removed, which leaves no SetValue) used to end this thread, and every rainbow colour
			froze for the rest of the session. A slider with nothing left to call is dropped after
			the pass, since dropping one moves another into its place. ]]
			local stale
			for _, component in vape.RainbowSliders do
				if type(component.SetValue) ~= 'function' then
					stale = stale or {}
					table.insert(stale, component)
				elseif component.Type == 'GUISlider' then
					pcall(component.SetValue, component, vape:Color(hue))
				else
					pcall(component.SetValue, component, hue)
				end
			end
			if stale then
				for _, component in stale do
					removeRainbowSlider(component)
				end
			end

			local delta = task.wait(1 / vape.RainbowUpdateSpeed.Value)
			hue = (hue + (delta * (0.2 * vape.RainbowSpeed.Value))) % 1
		until false
	end))

	local cursorConnection
	vape:Clean(clickgui:GetPropertyChangedSignal('Visible'):Connect(function()
		vape.ClickGuiOpen = clickgui.Visible
		if not clickgui.Visible then
			tooltip.Visible = false
			tooltip.Text = ''
			vape.CurrentTooltip = nil
			if vape.Binding then
				local stale = vape.Binding
				vape.Binding = nil
				pcall(function() stale:SetBind(stale.Keys, true) end)
			end
		end

		--[[ Opening the menu repaints it only if a colour pass was skipped while it was shut, or
		something was added to it since the last one: otherwise every card already shows these
		colours, and the pass walked every option of every module for nothing. Closing it touches
		only the overlay, which was all that call ever reached with the menu shut. ]]
		if clickgui.Visible and (not layout or layout.ColorDirty ~= false) then
			vape:UpdateGUI(vape.GUIColor.Hue, vape.GUIColor.Sat, vape.GUIColor.Value, true)
		elseif vape.Loaded ~= nil and TextGUI and TextGUI.Button and TextGUI.Button.Enabled then
			TextGUI:UpdateColor(vape.GUIColor.Hue, vape.GUIColor.Sat, vape.GUIColor.Value, true)
		end

		if clickgui.Visible and inputService.MouseEnabled then
			if cursorConnection then
				cursorConnection:Disconnect()
			end

			cursorConnection = runService.RenderStepped:Connect(function()
				local isVisible = clickgui.Visible
				for _, window in vape.Windows do
					isVisible = isVisible or window.Visible
				end

				if not isVisible then
					vape.Cursor.Visible = false
					cursorConnection:Disconnect()
					cursorConnection = nil
					return
				end

				vape.Cursor.Visible = not inputService.MouseIconEnabled
				if vape.Cursor.Visible then
					local mouseLocation = inputService:GetMouseLocation()
					vape.Cursor.Position = UDim2.fromOffset(mouseLocation.X - 31, mouseLocation.Y - 32)
				end
			end)
		end
	end))

	vape:Clean(function()
		if cursorConnection then
			cursorConnection:Disconnect()
		end
	end)

	--[[
		Rescale on a resize, and on a rotation. The camera's ViewportSize is the thing that actually
		changes on a phone; a ScreenGui's AbsoluteSize is (0, 0) until it first renders.
	]]
	local function applyAutoScale()
		if vape.Scale and vape.Scale.Enabled then
			scale.Scale = autoScaleValue()
		end
		local main = vape.Categories.Main
		if main and main.Resize then
			main.Resize()
		end
		-- The HUD's phone zoom follows the scale, and a rotation can leave HUD pieces past an edge.
		ui.applyHudZoom()
		ui.clampAllHud()
	end

	--[[ A resize changes the camera's ViewportSize and the ScreenGui's AbsoluteSize together, and
	each ran the whole rescale: now they ask for one, run once at the end of the frame. A new
	camera is watched in place of the old one, whose size never changes again. ]]
	local autoScaleQueued, viewportConnection = false, nil
	local function queueAutoScale()
		if autoScaleQueued then return end
		autoScaleQueued = true
		task.defer(function()
			autoScaleQueued = false
			if vape.Loaded == nil then return end
			if vape.ThreadFix then
				setthreadidentity(8)
			end
			applyAutoScale()
		end)
	end
	local function watchCamera()
		if viewportConnection then
			viewportConnection:Disconnect()
		end
		viewportConnection = gameCamera and gameCamera:GetPropertyChangedSignal('ViewportSize'):Connect(queueAutoScale) or nil
	end
	watchCamera()
	vape:Clean(function()
		if viewportConnection then
			viewportConnection:Disconnect()
			viewportConnection = nil
		end
	end)
	vape:Clean(workspace:GetPropertyChangedSignal('CurrentCamera'):Connect(function()
		gameCamera = workspace.CurrentCamera
		watchCamera()
		applyAutoScale()
	end))
	vape:Clean(gui:GetPropertyChangedSignal('AbsoluteSize'):Connect(queueAutoScale))

	vape:Clean(notifications.ChildRemoved:Connect(function()
		ui.restackNotifications()
	end))

	vape:Clean(scale:GetPropertyChangedSignal('Scale'):Connect(function()
		scaledgui.Size = UDim2.fromScale(1 / scale.Scale, 1 / scale.Scale)
		local main = vape.Categories.Main
		if main and main.Resize then
			main.Resize()
		end
		ui.applyHudZoom()
		-- The mod overlay's lines are sized in whole pixels at the old scale.
		if vape.Loaded and vape.UpdateTextGUI then
			task.defer(pcall, vape.UpdateTextGUI, vape)
		end

		--[[ GetDescendants, not QueryDescendants. The selector-query API is recent and
		unavailable on the mobile clients used by these executors. ]]
		for _, obj in scaledgui:GetDescendants() do
			if obj:IsA('GuiObject') and obj.Visible then
				obj.Visible = false
				obj.Visible = true
			end
		end
	end))

	vape:Clean(vape.GUIBind.Triggered:Connect(function()
		if vape.ThreadFix then
			setthreadidentity(8)
		end
		if layout.MovingHud and layout.StopMovingHud then
			layout.StopMovingHud()
			return
		end
	
		for _, window in vape.Windows do
			window.Visible = false
		end
	
		for _, module in orderedModules(vape.ModuleOrder) do
			if module.Bind.Mobile then
				module.Bind.Mobile.Visible = clickgui.Visible
			end
		end
	
		clickgui.Visible = not clickgui.Visible
		vape:BlurCheck()
	end))
	
	vape:Clean(inputService.InputBegan:Connect(function(input)
		if vape.CurrentTooltip and input.KeyCode == Enum.KeyCode.LeftShift then
			vape.CurrentTooltip()
		end
	
		if not inputService:GetFocusedTextBox() and input.KeyCode ~= Enum.KeyCode.Unknown then
			table.insert(vape.HeldKeybinds, input.KeyCode.Name)
			if vape.Binding then return end
	
			for _, bind in vape.ActiveBinds do
				if checkKeybinds(vape.HeldKeybinds, bind.Keys, input.KeyCode.Name) then
					bind.Triggered:Fire(true)
				end
			end
		end
	end))
	
	vape:Clean(inputService.InputEnded:Connect(function(input)
		if vape.CurrentTooltip and input.KeyCode == Enum.KeyCode.LeftShift then
			vape.CurrentTooltip()
		end
	
		if not inputService:GetFocusedTextBox() and input.KeyCode ~= Enum.KeyCode.Unknown then
			if vape.Binding then
				if not vape.MultiKeybind.Enabled then
					vape.HeldKeybinds = {input.KeyCode.Name}
				end
	
				--[[
					Old-GUI unbind behaviour, kept alongside the new click-the-X removal:
					pressing the SAME key(s) the component is already bound to clears the
					bind instead of rebinding it to itself. Both routes now work.

					checkKeybinds needs every key of the current bind to be held, so a
					single-key press never accidentally clears a multi-key combo -- that
					rebinds, exactly as the old GUI did. SetBind's NoRemove guard still
					restores the default for binds that must not be lost (the menu key).
				]]
				local binding = vape.Binding
				vape.Binding = nil
				if input.KeyCode == Enum.KeyCode.Escape then
					vape.HeldKeybinds = {}
					binding:SetBind({}, true)
					return
				end
				local sameAsCurrent = checkKeybinds(vape.HeldKeybinds, binding.Keys, input.KeyCode.Name)
				binding:SetBind(sameAsCurrent and {} or vape.HeldKeybinds, true)
			else
				for _, bind in vape.ActiveBinds do
					if bind.Hold and checkKeybinds(vape.HeldKeybinds, bind.Keys, input.KeyCode.Name) then
						bind.Triggered:Fire(false)
					end
				end
			end
		end
	
		local index = table.find(vape.HeldKeybinds, input.KeyCode.Name)
		if index then
			table.remove(vape.HeldKeybinds, index)
		end
	end))

	--[[ Once now, not only on the events above. The resize the window runs when it is built comes
	before vape.Scale exists, so a phone's zoom used to wait on the ScreenGui's first size change. ]]
	applyAutoScale()
end

function vape:LoadGUI()
	build.root()
	build.categories()
	build.lists()
	build.settings()
	build.modOverlay()
	build.targetInfo()
	build.keyFooter()
	build.loops()

	-- The phone's way into the menu, up as soon as there is a menu to open; see
	-- EnsureVapeButton for why this does not wait for the profile.
	self:EnsureVapeButton()
end

function vape:Remove(obj)
	local container = (self.Modules[obj] and self.Modules or self.Legit.Modules[obj] and self.Legit.Modules or self.Categories)
	if container and container[obj] then
		local component = container[obj]
		local isModule = component.Type == 'Module'
		if self.ThreadFix then
			setthreadidentity(8)
		end

		--[[ Switched off first, quietly, as a toggle would: that runs the module's own shutdown and
		disconnects what it connected. Wiping the table below only forgot those connections, and
		they went on firing for the rest of the session. Its rainbow colours stop with it. ]]
		if component.Enabled and type(component.Toggle) == 'function' then
			if isModule then
				pcall(component.Toggle, component, nil, true)
			elseif component.Type == 'LegitModule' then
				pcall(component.Toggle, component)
			end
		end
		if type(component.Options) == 'table' then
			for _, option in component.Options do
				removeRainbowSlider(option)
			end
		end

		if component.Destroy then
			component:Destroy()
		end

		for _, child in {'Object', 'Children', 'Toggle', 'Button'} do
			child = typeof(component[child]) == 'table' and component[child].Object or component[child]

			if typeof(child) == 'Instance' then
				child:Destroy()
				child:ClearAllChildren()
			end
		end

		loopClean(component)
		container[obj] = nil

		-- Keep the save order in step with the table it mirrors. The lobby strips every Combat
		-- and Minigames module on entry, and a stale entry left here would have vape:Save call
		-- module:Save on a destroyed component on the next write.
		local order = container == self.Legit.Modules and self.Legit.Order or self.ModuleOrder
		if order then
			local index = table.find(order, component)
			if index then
				table.remove(order, index)
			end
		end

		if isModule then
			self.ModuleCount = math.max((self.ModuleCount or 1) - 1, 0)
			self:SortCategories()
		end
	end
end

function vape:CanSave()
	return self.Loaded
		and not self.Applying
		and not self.SaveBlocked
		and not shared.PistonwareBootFailed
end

function vape:BlockSaving()
	self.SaveBlocked = true
	self.SaveNeeded = nil
	self.SaveQueued = nil
	self.SaveDeadline = nil
	self.SaveEpoch = (self.SaveEpoch or 0) + 1
	return false
end

function vape:AllowSaving()
	if shared.PistonwareBootFailed then return self:BlockSaving() end
	self.SaveBlocked = nil
	if self.PendingProfileCreate and self:CanSave() then
		self.PendingProfileCreate = nil
		self:RequestSave()
	end
	return true
end

function vape:Save(newProfile)
	if not self:CanSave() then return false end

	if self.ThreadFix then
		setthreadidentity(8)
	end

	local guiData = {
		Categories = {},
		Profile = newProfile or self.Profile,
		v = 1
	}

	local mainData = {
		Modules = {},
		Categories = {},
		Legit = {},
		v = 1
	}

	local success, err = pcall(function()
		for _, category in self.Categories do
			category:Save((category.Type == 'Overlay' and mainData or guiData).Categories)
		end

		-- Length captured up front: if the payload appends while this runs, the new module is
		-- simply not in this write, and the save that follows its registration picks it up.
		local order = self.ModuleOrder
		for index = 1, #order do
			local module = order[index]
			if module then
				module:Save(mainData.Modules)
			end
		end

		local legit = self.Legit.Order
		for index = 1, (legit and #legit or 0) do
			local module = legit[index]
			if module then
				module:Save(mainData.Legit)
			end
		end
	end)

	if not success then
		if not self.SaveFailed then
			self.SaveFailed = true
			self:CreateNotification('Pistonware', 'Failed to save your config, '..tostring(err), 10, 'alert')
		end

		return false
	end

	local guiSuccess, guiError = writeJson('pistonware/profiles/'..game.GameId..'.gui.txt', guiData)
	local mainSuccess, mainError = writeJson('pistonware/profiles/'..self.Profile..self.Place..'.txt', mainData)

	if guiSuccess and mainSuccess then
		self.SaveFailed = nil
		return true
	elseif not self.SaveFailed then
		self.SaveFailed = true
		self:CreateNotification('Pistonware', 'Failed to save your config, '..tostring(guiError or mainError), 10, 'alert')
	end
	return false
end

function vape:RequestSave()
	if not self:CanSave() then
		--[[ A toggle made while a normal boot is still loading must survive: queue it so
		FlushSave writes it the moment main.lua opens saving. A failed boot never writes,
		so its intent is dropped instead of queued. ]]
		if not shared.PistonwareBootFailed then
			self.SaveNeeded = true
		end
		return false
	end

	local now = os.clock()
	self.SaveTime = now + 0.4

	if self.SaveQueued then
		return true
	end

	local epoch = self.SaveEpoch or 0
	self.SaveQueued = epoch
	--[[ A ceiling on the coalescing, because every option change asks to save now and some of
	them arrive in a stream: a slider being dragged, a text box being typed into, a module
	writing its own option. Each one pushes SaveTime forward, so the window alone would keep
	postponing the write for as long as the stream lasts and a long drag would write nothing
	until it ended. Still one write per burst, just never later than this. ]]
	self.SaveDeadline = now + 2

	local function flush()
		if self.SaveQueued ~= epoch or self.SaveEpoch ~= epoch then return end
		if vape.ThreadFix then
			setthreadidentity(8)
		end

		local remaining = math.min(self.SaveTime, self.SaveDeadline or math.huge) - os.clock()
		if remaining > 0 then
			task.delay(remaining, flush)
			return
		end

		self.SaveQueued = nil
		self.SaveDeadline = nil
		self.SaveNeeded = nil

		if self:CanSave() then
			self:Save()
		end
	end

	task.delay(0.4, flush)
	return true
end

-- Called by main.lua the instant saving becomes safe, so a toggle made while the payload was
-- still loading is written then rather than waiting for a backstop tick.
function vape:FlushSave()
	if not self:CanSave() then return false end
	if not self.SaveNeeded then return false end

	self.SaveNeeded = nil
	return self:RequestSave()
end

function vape:SaveOptions(obj)
	local data = {}
	for _, component in obj.Options do
		if not component.Save then
			continue
		end

		component:Save(data)
	end

	return data
end

--[[
	Reassigns every module's LayoutOrder alphabetically within its category.

	The order has to be a property of the whole set, not of insertion: a module dropdown is
	positioned from its LayoutOrder, so a category whose orders are stale puts a module's
	settings panel above the module instead of below it.

	Lifted out of module creation so removal can call it too. vape:Remove used to leave the
	surviving modules holding the indexes they had when the removed one was still there.
]]
--[[
	The public form of orderedModules, for game scripts.

	Anything outside this file that walks vape.Modules with pairs has the same hazard the GUI
	just had -- Panic, the chat 'toggle all' command and AutoConfig all iterate every module, and
	all three can be triggered while a payload is still registering. `for name, module in
	vape:EachModule() do` is a drop-in replacement for `for name, module in vape.Modules do`.
]]
function vape:EachModule()
	return orderedModules(self.ModuleOrder)
end

function vape:EachLegitModule()
	return orderedModules(self.Legit and self.Legit.Order)
end

local function sortCategoriesNow(self)
	local sorting = {}
	for _, module in orderedModules(self.ModuleOrder) do
		sorting[module.Category] = sorting[module.Category] or {}
		table.insert(sorting[module.Category], module.Name)
	end

	for _, sort in sorting do
		table.sort(sort)
		for index, name in sort do
			local module = self.Modules[name]
			-- The array can name a module the hash no longer holds if a removal lands
			-- between the request and this pass.
			if module then
				-- Still the rainbow offset per category; the cards are ordered by the tab layout.
				module.Index = index
			end
		end
	end

	if layout then
		layout.request('*')
	end
end

--[[
	Coalesced, because the callers are a burst.

	Every CreateModule ends with a SortCategories, and each one re-walks every module
	registered so far, sorts each category and writes two LayoutOrder properties per module.
	Over a payload that registers several hundred modules that is quadratic, and the expensive
	half is the property writes -- hundreds of thousands of round trips into the Roblox
	instance API during the single slowest part of the load.

	The answer only has to be right by the time anything looks at it, and nothing does until a
	frame is rendered. Deferring collapses a whole registration burst into ONE sort at the end
	of the frame, which is the same result the last call of the burst would have produced.

	task.defer rather than a flag checked elsewhere: it needs no cooperation from callers, and
	a module removed between the request and the pass is handled above.
]]
function vape:SortCategories()
	if self.SortQueued then return end
	self.SortQueued = true

	task.defer(function()
		self.SortQueued = nil
		-- Uninject's loopClean strips vape down to an empty table, so a pass still queued
		-- when it runs finds no ModuleOrder at all. Guarded rather than cancelled: there is
		-- nothing left to sort at that point and nothing to report.
		pcall(sortCategoriesNow, self)
	end)
end

function vape:Uninject()
	if self:CanSave() then self:Save() end
	self:BlockSaving()
	self.Loaded = nil

	for _, module in orderedModules(self.ModuleOrder) do
		if module.Enabled then
			module:Toggle()
		end
	end

	for _, module in orderedModules(self.Legit.Order) do
		if module.Enabled then
			module:Toggle()
		end
	end

	for _, category in self.Categories do
		if category.Type == 'Overlay' and category.Button.Enabled then
			category.Button:Toggle()
		end
	end

	for _, connection in self.Connections do
		cleanupConnection(connection)
	end

	if self.ThreadFix then
		setthreadidentity(8)
		clickgui.Visible = false
		self:BlurCheck()
	end

	-- Unconditional: the BlurCheck above is behind ThreadFix, and the executors without it are
	-- exactly the mobile ones that were using the BlurEffect. Unloading must not leave the world
	-- blurred with no menu to turn it off from.
	setMobileBlur(false)

	gui:ClearAllChildren()
	gui:Destroy()
	--[[ The ThreadFix branch of LoadGUI parents a Folder into CoreGui, but nothing removed it,
	so every inject left one behind. A queued teleport re-injects on each new server, so a phone
	that hops servers accumulates one folder per hop. ]]
	if self.holder and self.holder ~= gui then
		pcall(function() self.holder:Destroy() end)
	end
	self.holder = nil
	table.clear(self.Connections)
	table.clear(self.Libraries)
	loopClean(self)

	shared.vape = nil
	shared.vapereload = nil
	shared.VapeIndependent = nil
end

function vape:UpdateGUI(hue, sat, val, default)
	if vape.Loaded == nil then return end
	if not default and vape.GUIColor.Rainbow then return end

	if TextGUI and TextGUI.Button and TextGUI.Button.Enabled then
		TextGUI:UpdateColor(hue, sat, val, default)
	end

	if not clickgui or not clickgui.Visible then
		-- Painted when the menu next opens instead (its Visible handler, in build.loops).
		if layout then
			layout.ColorDirty = true
		end
		return
	end
	local isRainbow = vape.GUIColor.Rainbow and vape.RainbowMode ~= nil and vape.RainbowMode.Value ~= 'Retro'

	if vape.RecolorProfileCards then
		vape.RecolorProfileCards()
	end

	for name, component in vape.Categories do
		component:Color(hue, sat, val, isRainbow)
	end

	-- Every bind badge, wherever it sits: module cards, settings rows, profile cards. Only a bound
	-- one is drawn in the accent; NONE and PRESS A KEY... are the same in every theme.
	if layout and layout.Binds then
		for bind in layout.Binds do
			-- a removed module's bind can be emptied before the weak key lets go
			if bind.Repaint and (bind.Binding or (bind.Keys and #bind.Keys > 0)) then
				bind:Repaint()
			end
		end
	end

	for _, component in orderedModules(vape.ModuleOrder) do
		component:Color(hue, sat, val, isRainbow)
	end

	if vape.Overlays then
		for _, component in vape.Overlays.Options do
			if component.Color then
				component:Color(hue, sat, val, isRainbow)
			end
		end
	end

	for _, pane in vape.Settings do
		for _, component in pane.Options do
			if component.Color then
				component:Color(hue, sat, val, isRainbow)
			end
		end
	end

	if vape.Legit then
		for _, component in orderedModules(vape.Legit.Order) do
			component:Color(hue, sat, val, isRainbow)
		end
	end

	if layout then
		layout.ColorDirty = false
	end
end

--[[ Every container (category, module, legit module, overlay, window) binds the whole
components table into its own frame, and each container uses a different frame. Recorded here
so a component registered later -- vape.Components.X = f,
which games do for their own option types -- can be bound into the same frame
instead of guessing at it. Weak keys: a removed container takes its entry with it. ]]
local componentChildren = setmetatable({}, {__mode = 'k'})

local function bindComponents(component, children)
	componentChildren[component] = children

	for index, comp in components do
		component['Create'..index] = function(_, props)
			if layout then
				layout.ColorDirty = true
			end
			return comp(props, children, component)
		end
	end
end

--[[
	Tabs and the card layout.

	The menu is one window: a tab bar and, under it, a page per tab holding two independent
	columns of cards. Which tab a module lands in is its own `Tab` setting when it gives one, and
	otherwise follows the category it registered in -- the categories themselves are unchanged,
	because game files and the lobby's own filters still talk to them by name.

	Cards are placed by one deferred pass per frame, not as they arrive: a payload registers
	hundreds of modules in a burst, and placing each one as it came would re-sort the tab every
	time. Sorted alphabetically by the name the card shows, alternating left and right, so an
	expanded card only ever pushes its own column down.
]]
TABS = {'Combat', 'Move', 'Visual', 'Utility', 'Kits', 'FFlags'}
local TAB_OF_CATEGORY = {
	Combat = 'Combat', Blatant = 'Move', Render = 'Visual', World = 'Utility',
	Utility = 'Utility', Inventory = 'Utility', Minigames = 'Kits', Legit = 'Visual', Overlay = 'Visual'
}
layout = {
	-- Set when a colour pass was skipped with the menu shut or something was added; see build.loops.
	ColorDirty = true,
	Entries = {},
	Pages = {},
	Dirty = {},
	Search = '',
	Columns = 2,
	Binds = setmetatable({}, {__mode = 'k'}),
	-- The colour pickers' 'Recently used' row, newest first, shared by every picker.
	RecentColors = {},
	-- Called when a tab is opened, by tab name (the FFlags tab opens its list).
	TabShown = {}
}

function layout.tabOf(props, category)
	-- 'Block' was a tab of an older Slinky build; the current one keeps those modules in Utility.
	local tab = props.Tab == 'Block' and 'Utility' or props.Tab
	if type(tab) == 'string' and table.find(TABS, tab) then
		return tab
	end
	return TAB_OF_CATEGORY[category] or 'Utility'
end

function layout.request(tab)
	layout.Dirty[tab or '*'] = true
	if layout.Queued then return end
	layout.Queued = true
	task.defer(function()
		layout.Queued = false
		pcall(layout.flush)
	end)
end

function layout.add(entry)
	table.insert(layout.Entries, entry)
	layout.request(entry.Tab)
	return entry
end

function layout.remove(card)
	for index = #layout.Entries, 1, -1 do
		if layout.Entries[index].Card == card then
			table.remove(layout.Entries, index)
		end
	end
	layout.request('*')
end

local function entryMatches(entry, query)
	if query == '' then return false end
	for _, text in entry.Search do
		if text:find(query, 1, true) then return true end
	end
	return false
end

function layout.place(tab)
	local page = layout.Pages[tab]
	if not page or not page.Left then return end
	local columns = tab == 'FFlags' and 1 or layout.Columns
	local searching = layout.Search ~= ''
	local list = {}
	for _, entry in layout.Entries do
		local included
		if tab == 'Search' then
			included = searching and entryMatches(entry, layout.Search)
		else
			included = not searching and entry.Tab == tab
		end
		if included and (entry.Visible == nil or entry.Visible()) then
			table.insert(list, entry)
		elseif entry.Card.Parent ~= layout.Hidden and (entry.Card.Parent == page.Left or entry.Card.Parent == page.Right
			or (not searching and entry.Tab == tab)) then
			-- Out of this page: no longer matching the search, hidden, or another tab's card left
			-- over from a search.
			entry.Card.Parent = layout.Hidden
		end
	end

	table.sort(list, function(a, b)
		if a.Key == b.Key then return a.Name < b.Name end
		return a.Key < b.Key
	end)

	for index, entry in list do
		local column = (columns == 1 or index % 2 == 1) and page.Left or page.Right
		if entry.Card.Parent ~= column then
			entry.Card.Parent = column
		end
		if entry.Card.LayoutOrder ~= index then
			entry.Card.LayoutOrder = index
		end
	end

	page.Right.Visible = columns > 1
	page.Left.Size = columns > 1 and UDim2.new(0.5, -theme.Gap / 2, 0, 0) or UDim2.new(1, 0, 0, 0)
	if page.Empty then
		page.Empty.Visible = #list == 0
	end
end

function layout.flush()
	local dirty = layout.Dirty
	layout.Dirty = {}
	if vape.ThreadFix then
		setthreadidentity(8)
	end
	if layout.Search ~= '' then
		layout.place('Search')
		return
	end
	for _, tab in TABS do
		if dirty['*'] or dirty[tab] then
			layout.place(tab)
		end
	end
	if layout.SetTabHidden then
		local kits = 0
		for _, entry in layout.Entries do
			if entry.Tab == 'Kits' then
				kits += 1
			end
		end
		layout.SetTabHidden('Kits', kits == 0 or game.PlaceId == 6872265039)
	end
end

--[[ A row's accent: the theme colour, or its slot in the rainbow when the theme is on rainbow --
offset by the row's index so a column of switches does not all show the same hue. ]]
local function accentFor(index, step, hue, sat, val, isRainbow)
	if isRainbow then
		return Color3.fromHSV(vape:Color(((hue or vape.GUIColor.Hue) - ((index or 0) * (step or 0.075))) % 1))
	end
	return Color3.fromHSV(hue or vape.GUIColor.Hue, sat or vape.GUIColor.Sat, val or vape.GUIColor.Value)
end

local function liveAccent(index, step)
	local isRainbow = vape.GUIColor.Rainbow and vape.RainbowMode ~= nil and vape.RainbowMode.Value ~= 'Retro'
	return accentFor(index, step, nil, nil, nil, isRainbow)
end

--[[ Drags along a track: calls back with the 0..1 position under the pointer until the press is
released. The same arithmetic every slider here has always used. ]]
local function trackDrag(input, track, onMove, onEnd)
	local isMouse = input.UserInputType == Enum.UserInputType.MouseButton1
	local last = math.clamp((input.Position.X - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1), 0, 1)
	onMove(last)
	local releaseConnection
	local moveConnection = inputService.InputChanged:Connect(function(newInput)
		-- Only the press that started the drag. A touch keeps one InputObject for its whole life, and
		-- with input allowed while the menu is open a second finger on the thumbstick moved the knob.
		if newInput == input or (isMouse and newInput.UserInputType == Enum.UserInputType.MouseMovement) then
			last = math.clamp((newInput.Position.X - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1), 0, 1)
			onMove(last)
		end
	end)
	releaseConnection = input.Changed:Connect(function()
		if input.UserInputState == Enum.UserInputState.End or input.UserInputState == Enum.UserInputState.Cancel then
			moveConnection:Disconnect()
			releaseConnection:Disconnect()
			if onEnd then onEnd(last) end
		end
	end)
end

local function isPress(input)
	return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
end

--[[ A card opened near the bottom of its page brings its settings into view: the page scrolls just
far enough to show the card's bottom, never so far that the card's top leaves the page. Waits two
frames for the opened body to be laid out and the page's canvas to grow round it. ]]
function ui.revealCard(card)
	task.spawn(function()
		task.wait()
		task.wait()
		local page = card.Parent and card:FindFirstAncestorWhichIsA('ScrollingFrame')
		if not page then return end
		local viewTop = page.AbsolutePosition.Y
		local viewBottom = viewTop + page.AbsoluteWindowSize.Y
		local cardTop = card.AbsolutePosition.Y
		local overflow = cardTop + card.AbsoluteSize.Y - viewBottom
		if overflow <= 0 then return end
		-- In screen pixels; the canvas is measured before the menu's scale and the window's zoom.
		local shift = math.min(overflow + 8, cardTop - viewTop)
		if shift <= 0 then return end
		local s = math.max(scale.Scale, 0.05) * (layout.Zoom or 1)
		local furthest = math.max((page.AbsoluteCanvasSize.Y - page.AbsoluteWindowSize.Y) / s, 0)
		local target = math.clamp(page.CanvasPosition.Y + shift / s, 0, furthest)
		tween:Tween(page, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			CanvasPosition = Vector2.new(page.CanvasPosition.X, target)
		})
	end)
end

--[[
	A card: name, bind badge and switch on top, a '+' and the one-line description under them,
	and the settings below when opened. Modules, legit modules, overlays and the settings-only
	cards (GUI, Notifications, Friends ...) are all this.
]]
function ui.card(props)
	local card = ui.new('Frame', {
		Name = props.Name,
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = theme.Card,
		BackgroundTransparency = 0,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 0)
	}, props.Parent or layout.Hidden)
	ui.corner(card, 20)
	ui.list(card, 0)
	ui.padding(card, 0, 0, 0, 8)

	local header = ui.new('TextButton', {
		Name = 'Header',
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		LayoutOrder = 1,
		Size = UDim2.new(1, 0, 0, 64),
		Text = ''
	}, card)

	local nameRow = ui.new('Frame', {
		Name = 'Title',
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(theme.Inset, 12),
		Size = UDim2.new(1, -(theme.Inset * 2 + 48), 0, 20)
	}, header)
	ui.list(nameRow, 4, true)
	local title = ui.text(nameRow, {Text = props.Display or props.Name, Size = 16, Weight = 'Medium', Color = theme.Text, Props = {
		Name = 'Name',
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = 1,
		Size = UDim2.fromOffset(0, 20)
	}})
	-- Lifts the caps a pixel, onto the badge's and the switch's centre line.
	ui.padding(title, 0, 0, 0, 2)

	local switch = props.Switch and ui.switch(header, UDim2.new(1, -theme.Inset, 0, 22)) or nil
	local expand, glyph = ui.expander(header, UDim2.fromOffset(theme.Inset, 40))
	local description = ui.text(header, {Text = ui.firstLine(props.Tooltip), Size = 14, Color = theme.SubText, Props = {
		Name = 'Description',
		Position = UDim2.fromOffset(theme.Inset + 28, 40),
		Size = UDim2.new(1, -(theme.Inset * 2 + 28), 0, 20),
		TextTruncate = Enum.TextTruncate.AtEnd
	}})
	-- The description line, and the + beside it, light the description up a little while hovered.
	local function lightDescription(lit)
		tween:Tween(description, uipallet.Tween, {TextColor3 = lit and Color3.fromRGB(196, 196, 196) or theme.SubText})
	end
	for _, part in {description, expand} do
		part.MouseEnter:Connect(function()
			lightDescription(true)
		end)
		part.MouseLeave:Connect(function()
			lightDescription(false)
		end)
	end

	local body = ui.new('Frame', {
		Name = props.ChildrenName or (props.Name..'Children'),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = theme.Card,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		LayoutOrder = 2,
		Size = UDim2.new(1, 0, 0, 0),
		Visible = false
	}, card)
	ui.list(body, 0, false, Enum.HorizontalAlignment.Center)

	local view = {
		Card = card,
		Header = header,
		NameRow = nameRow,
		Title = title,
		Switch = switch,
		Expand = expand,
		Glyph = glyph,
		Description = description,
		Body = body
	}

	function view:SetExpanded(open)
		body.Visible = open and view.HasOptions
		glyph:Set(open)
		if open and view.HasOptions then
			ui.revealCard(card)
		end
	end

	--[[ A module with nothing to configure has no expand square in Slinky, and its description
	starts where the title does. The square comes back the moment an option is added. ]]
	view.HasOptions = true
	function view:SetHasOptions(has)
		view.HasOptions = has
		expand.Visible = has
		local left = has and theme.Inset + 28 or theme.Inset
		description.Position = UDim2.fromOffset(left, description.Position.Y.Offset)
		description.Size = UDim2.new(1, -(left + theme.Inset), 0, description.Size.Y.Offset)
		if not has then
			body.Visible = false
		end
	end

	-- Watches an Options table: the first option registered shows the square.
	function view:WatchOptions(options)
		view:SetHasOptions(next(options) ~= nil)
		return setmetatable(options, {
			__newindex = function(t, key, value)
				rawset(t, key, value)
				if value ~= nil and not view.HasOptions then
					view:SetHasOptions(true)
				end
			end
		})
	end

	if props.Tooltip and props.Tooltip ~= '' then
		addTooltip(description, props.Tooltip)
	end

	return view
end

components = {}

components.Bind = function(props, children, api)
	local component = {
		Hold = props.Hold or false,
		Keys = {},
		Triggered = createSignal(),
		Type = 'Bind'
	}

	--[[ The badge: NONE when unbound, the keys in the accent once bound, PRESS A KEY... while it
	waits for one. Shift-click switches it between toggle and hold. ]]
	local alwaysShown = props.Module and props.Cover and not isMobile()
	local bind = ui.text(nil, {Class = 'TextButton', Text = 'NONE', Size = 12, Weight = 'Bold', Color = theme.SubText, AlignX = Enum.TextXAlignment.Center, Props = {
		Name = 'Bind',
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = theme.Badge,
		BackgroundTransparency = 0,
		LayoutOrder = 2,
		Size = UDim2.fromOffset(0, 20),
		Visible = alwaysShown and true or false
	}})
	ui.corner(bind, 5)
	ui.padding(bind, 6, 6, 0, 0)
	addTooltip(bind, '', function()
		local holdText = 'Mode: '..(component.Hold and 'hold' or 'toggle')
		if inputService:IsKeyDown(Enum.KeyCode.LeftShift) then
			holdText = "<font color='"..ui.hex(theme.Red).."'>"..holdText.."</font>"
		end
		return 'Click to bind, click again to clear\nShift-click to switch toggle/hold\n'..holdText
	end)

	local function paint()
		if component.Binding then
			bind.Text = 'PRESS A KEY...'
			bind.TextColor3 = theme.Text
			bind.BackgroundColor3 = theme.Badge
		elseif #component.Keys > 0 then
			bind.Text = ui.keyText(component.Keys)..(component.Hold and '  HOLD' or '')
			local accent = theme.Accent()
			bind.TextColor3 = accent
			bind.BackgroundColor3 = theme.Tint(accent, 0.15)
		else
			bind.Text = component.Hold and 'NONE  HOLD' or 'NONE'
			bind.TextColor3 = theme.SubText
			bind.BackgroundColor3 = theme.Badge
		end
	end

	if props.Module then
		local parent = api.BindParent or api.Object
		bind.Parent = parent
		component.Object = bind
	else
		local holder = ui.row(children, props)
		ui.rowLabel(holder, props, 150)
		local slot = ui.new('Frame', {
			Name = 'BindSlot',
			AnchorPoint = Vector2.new(1, 0.5),
			AutomaticSize = Enum.AutomaticSize.X,
			BackgroundTransparency = 1,
			Position = UDim2.new(1, -theme.Inset, 0.5, 0),
			Size = UDim2.fromOffset(0, 20)
		}, holder)
		ui.list(slot, 0, true, Enum.HorizontalAlignment.Right)
		addTooltip(holder, props.Tooltip)
		bind.Visible = true
		bind.Parent = slot
		component.Object = holder
	end

	function component:CreateMobileButton(position)
		self:DestroyMobileButton()

		local isHeld = false
		local button = Instance.new('TextButton')
		button.AnchorPoint = Vector2.new(0.5, 0.5)
		button.BackgroundColor3 = api.Enabled and theme.Accent() or theme.Bar
		button.BackgroundTransparency = 0.2
		button.FontFace = uipallet.FontMedium
		button.Position = UDim2.fromOffset(position.X, position.Y)
		button.Size = UDim2.fromOffset(44, 44)
		button.Text = api.Name or 'Button'
		button.TextColor3 = Color3.new(1, 1, 1)
		button.TextScaled = true
		button.Parent = gui
		-- Hidden while the menu is open, like every placed button: a profile loaded from the Profiles tab builds them then.
		button.Visible = not (clickgui and clickgui.Visible)
		local constraint = Instance.new('UITextSizeConstraint')
		constraint.MaxTextSize = 14
		constraint.Parent = button
		addCorner(button, UDim.new(1, 0))

		button.MouseButton1Down:Connect(function()
			isHeld = true

			local holdtime, holdPos = os.clock(), inputService:GetMouseLocation()
			repeat
				isHeld = (inputService:GetMouseLocation() - holdPos).Magnitude < 6

				task.wait()
			until (os.clock() - holdtime) > 1 or not isHeld

			if isHeld then
				self:DestroyMobileButton()
				vape:RequestSave()
			end
		end)

		button.MouseButton1Up:Connect(function()
			isHeld = false
		end)

		button.MouseButton1Click:Connect(function()
			self.Triggered:Fire(true)
			button.BackgroundColor3 = api.Enabled and theme.Accent() or theme.Bar
		end)

		self.Mobile = button
	end

	function component:Destroy()
		layout.Binds[component] = nil
		bind:Destroy()
		bind:ClearAllChildren()

		if self.Object then
			self.Object:Destroy()
			self.Object:ClearAllChildren()
		end

		if self.Mobile then
			self.Mobile:Destroy()
			self.Mobile = nil
		end

		local index = table.find(vape.ActiveBinds, self)
		if index then
			table.remove(vape.ActiveBinds, index)
		end
	end

	function component:DestroyMobileButton()
		if self.Mobile then
			self.Mobile:Destroy()
			self.Mobile = nil
		end
	end

	--[[
		Every module's Load calls this with data.Bind, but that field may be missing. A profile
		written before the module existed, or a legacy profile whose migration produced
		{Keys = nil}, can arrive here as nil or as a table without Keys. Indexing nil or applying
		# to nil in SetBind then aborts the full module-list load, so one stale entry takes the
		whole profile down.
	]]
	function component:Load(data)
		if type(data) ~= 'table' then
			return
		end

		self.Hold = data.Hold
		self:SetBind(type(data.Keys) == 'table' and data.Keys or {})

		if type(data.Mobile) == 'table' and tonumber(data.Mobile.X) and tonumber(data.Mobile.Y) then
			self:CreateMobileButton(Vector2.new(data.Mobile.X, data.Mobile.Y))
		else
			-- One left from the profile before this one would otherwise be saved into this one.
			self:DestroyMobileButton()
		end
	end

	function component:Save(data)
		data[props and props.Name or 'Bind'] = {
			Keys = self.Keys,
			Mobile = self.Mobile and {
				X = self.Mobile.Position.X.Offset,
				Y = self.Mobile.Position.Y.Offset
			},
			Hold = self.Hold
		}
	end

	function component:SetBind(keys, mouse)
		--[[ Callers outside this file reach SetBind too, and a saved profile is not a trusted
		shape. Everything below counts and concatenates it, so make it a table first. ]]
		keys = type(keys) == 'table' and keys or {}

		if props and props.NoRemove and #keys <= 0 then
			keys = type(props.Default) == 'table' and props.Default or keys
		end

		self.Binding = nil
		self.Keys = table.clone(keys)

		if #keys <= 0 then
			bind.Visible = alwaysShown or not props.Module

			local index = table.find(vape.ActiveBinds, component)
			if index then
				table.remove(vape.ActiveBinds, index)
			end
		else
			bind.Visible = true

			if not table.find(vape.ActiveBinds, component) then
				table.insert(vape.ActiveBinds, component)
			end
		end
		paint()
		vape:RequestSave()
	end

	-- Kept for callers; the badge colours itself.
	function component:SetColor(newColor) end

	function component:SetParent(parent)
		bind.Parent = parent
		bind.LayoutOrder = 2
	end

	function component:SetVisible(visible)
		bind.Visible = alwaysShown or not props.Module or #self.Keys > 0 or visible
	end

	function component:Repaint()
		paint()
	end
	layout.Binds[component] = true

	bind.MouseButton1Click:Connect(function()
		if vape.Binding then
			if vape.Binding == component then
				--[[ Second click on the bind that is waiting: clear it. ]]
				component:SetBind({}, true)
				vape.Binding = nil
				return
			end

			--[[
				A DIFFERENT bind was left waiting, and this branch used to swallow the click
				and return -- which is the 'cannot unbind anything' state.

				Getting into it is easy: click a bind to arm it, then click anywhere that is
				not a bind. Nothing clears vape.Binding, so it stays armed on the old
				component forever. From then on every click on every bind landed here and
				returned, so no bind could be cleared, and the only way out was pressing a
				key -- which bound it to whichever component was still armed.

				Cancel the stale one and fall through, so this click is handled normally.
			]]
			local stale = vape.Binding
			vape.Binding = nil
			pcall(function() stale:SetBind(stale.Keys, true) end)
		end

		if props.Module and inputService:IsKeyDown(Enum.KeyCode.LeftShift) then
			component.Hold = not component.Hold
			paint()
			vape:RequestSave()
			if vape.CurrentTooltip then
				vape.CurrentTooltip()
			end

			return
		end

		component.Binding = true
		vape.Binding = component
		paint()
	end)

	if props.Module then
		api.Bind = component
	else
		if props.Default then
			component:SetBind(props.Default)
		end

		api.Options[props.Name] = component
	end
	paint()

	return component
end

components.Button = function(props, children, api)
	-- TextButton -> Frame -> TextLabel: the shape autoexec/mcp.lua looks for to find a button.
	local button = ui.new('TextButton', {
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		LayoutOrder = props.LayoutOrder or 0,
		Size = UDim2.new(1, 0, 0, 36),
		Text = ''
	}, children)
	addTooltip(button, props.Tooltip)
	local holder = ui.new('Frame', {
		Name = 'Pill',
		BackgroundColor3 = theme.Card,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(theme.Inset, 5),
		Size = UDim2.new(1, -theme.Inset * 2, 0, 26)
	}, button)
	ui.corner(holder, UDim.new(1, 0))
	local stroke = ui.stroke(holder, theme.Outline, 1, 0.1)
	ui.text(holder, {Text = props.DisplayName or props.Name, Size = 14, Weight = 'Medium', Color = theme.Label, AlignX = Enum.TextXAlignment.Center, Props = {
		Name = 'Title',
		Size = UDim2.fromScale(1, 1)
	}})
	props.Function = props.Function or function() end

	button.MouseEnter:Connect(function()
		tween:Tween(holder, uipallet.Tween, {BackgroundColor3 = theme.Raised})
		stroke.Color = theme.Muted
	end)

	button.MouseLeave:Connect(function()
		tween:Tween(holder, uipallet.Tween, {BackgroundColor3 = theme.Card})
		stroke.Color = theme.Outline
	end)

	button.MouseButton1Click:Connect(props.Function)

	-- Returned so a caller can reach the instance; nothing needed one before.
	return {
		Object = button,
		Type = 'Button'
	}
end

components.Category = function(props, children, api)
	local component = {
		Expanded = false,
		Name = props.Name,
		Type = 'Category'
	}

	--[[ A category is no longer a window -- its modules are cards in their tab. This hidden
	frame is what is left of the window: it keeps the position the profile file has always
	recorded for it, so a save made here matches one made by the old menu field for field. ]]
	local window = ui.new('Frame', {
		Name = props.Name..'Category',
		BackgroundColor3 = theme.Card,
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(236, 60),
		Size = UDim2.fromOffset(0, 0),
		Visible = false
	}, layout.Hidden)
	-- The old window's DONE button (editing hidden modules lives in the GUI card now).
	component.Done = ui.new('TextButton', {Name = 'Done', BackgroundTransparency = 1, Text = '', Visible = false}, window)

	function component:Color(hue, sat, val, isRainbow) end

	function component:Expand()
		self.Expanded = not self.Expanded
	end

	function component:Load(data)
		if self.Button.Enabled ~= (data.Enabled and true or false) then
			self.Button:Toggle()
		end

		if (self.Expanded and true or false) ~= (data.Expanded and true or false) then
			self:Expand()
		end

		if data.Position then
			window.Position = UDim2.fromOffset(data.Position.X, data.Position.Y)
		end
	end

	function component:Save(data)
		data[props.Name] = {
			Enabled = self.Button.Enabled,
			Expanded = self.Expanded,
			Position = {
				X = window.Position.X.Offset,
				Y = window.Position.Y.Offset
			}
		}
	end

	bindComponents(component, window)

	component.Button = vape.Categories.Main:CreateGUIButton({
		Name = props.Name,
		Window = window
	})

	component.Object = window
	vape.Categories[props.Name] = component

	return component
end

local function usedText(stamp)
	if type(stamp) ~= 'number' then return 'Never used.' end
	local days = math.floor((os.time() - stamp) / 86400)
	if days <= 0 then return 'Used today.' end
	if days == 1 then return 'Used yesterday.' end
	return 'Used '..days..' days ago.'
end

local CATEGORYLIST_DESCRIPTIONS = {
	Friends = 'Lets you mark other players as friendly.',
	Targets = 'Players every module goes for first.',
	FFlags = 'Sets of Roblox fast flags you can switch between.'
}

components.CategoryList = function(props, children, api)
	local component = {
		Expanded = false,
		List = {},
		ListEnabled = {},
		Objects = {},
		Options = {},
		Type = 'CategoryList'
	}
	props.Color = props.Color or Color3.fromRGB(243, 93, 18)

	--[[
		Two list shapes live in this component, and this is the switch between them.

		The plain shape is Friends and Targets: many entries, each independently on or off,
		a coloured dot and an X. The other is the Profiles tab: named entries where exactly
		ONE is current, the current one wears the GUI colour, and the row carries a keybind
		and a delete instead of a checkbox.

		`Profiles` selects the second shape AND hardcodes what selecting means -- save the
		old config, load the new one. `Swap` selects the same shape but takes the meaning as
		callbacks (Current/Select/Delete), so anything else that is a set of named things
		with one active can look and behave identically without pretending to be a config.
	]]
	local swapStyle = (props.Profiles or props.Swap) and true or false
	local function currentEntry()
		if props.Swap then
			return props.Current and props.Current() or nil
		end
		return vape.Profile
	end
	--[[ Selecting is the one thing the two shapes genuinely do differently, so it is the one
	thing kept behind a function: a config swap has to flush the profile it is leaving before
	it loads the next, and a Swap list must not touch profiles at all. ]]
	local function selectEntry(name)
		if props.Swap then
			if props.Select then
				props.Select(name)
			end
			return
		end
		local _, profile = component:GetValue(name)
		if profile then
			profile.Used = os.time()
		end
		--[[ The name goes to Load as well: a refused save (a load still applying, or saving blocked)
		leaves gui.txt naming the old profile, and Load would read that one back. ]]
		local saved = vape:Save(name)
		vape:Load(true, name)
		if not saved then
			vape:RequestSave()
		end
	end

	-- Holds the position the save file has always carried for this list's old window.
	local window = ui.new('Frame', {
		Name = props.Name..'CategoryList',
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(240, 46),
		Size = UDim2.fromOffset(0, 0),
		Visible = false
	}, layout.Hidden)

	local view, listHolder, optionsHolder, inlineHolder, addvalue, addbutton
	if props.Profiles then
		--[[ The Profiles tab: a header with the profile in use, a grid of profile cards ending in
		CREATE NEW PROFILE, then whatever else the tab builds below (sync, import). ]]
		local page = layout.Pages.Profiles.Frame
		-- Kept for vape.ProfileLabel's readers; Slinky's page has no header row, so it is not shown.
		local headerRow = ui.new('Frame', {
			Name = 'ProfileHeader',
			BackgroundTransparency = 1,
			LayoutOrder = 1,
			Size = UDim2.new(1, 0, 0, 34),
			Visible = false
		}, page)
		ui.list(headerRow, 8, true)
		ui.text(headerRow, {Text = 'Profile in use', Size = 15, Color = theme.SubText, Props = {
			AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 1, Size = UDim2.fromOffset(0, 28)
		}})
		local current = ui.text(headerRow, {Text = vape.Profile or 'default', Size = 14, Weight = 'Medium', Color = theme.Text, AlignX = Enum.TextXAlignment.Center, Props = {
			BackgroundColor3 = theme.Pill, BackgroundTransparency = 0, LayoutOrder = 2, Size = UDim2.fromOffset(80, 24)
		}})
		ui.corner(current, UDim.new(1, 0))
		vape.ProfileLabel = current
		component.HeaderRow = headerRow

		listHolder = ui.new('Frame', {
			Name = 'Children',
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			LayoutOrder = 2,
			Size = UDim2.new(1, 0, 0, 0)
		}, page)
		local grid = Instance.new('UIGridLayout')
		grid.CellPadding = UDim2.fromOffset(theme.Gap, theme.Gap)
		-- Two cards a row, as Slinky lays its profiles out; one on a narrow window (see resize).
		grid.CellSize = UDim2.new(0.5, -theme.Gap / 2, 0, 72)
		grid.SortOrder = Enum.SortOrder.LayoutOrder
		grid.Parent = listHolder
		component.Grid = grid

		inlineHolder = ui.new('Frame', {
			Name = 'Inline',
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundColor3 = theme.Card,
			BackgroundTransparency = 0,
			LayoutOrder = 4,
			Size = UDim2.new(1, 0, 0, 0)
		}, page)
		ui.corner(inlineHolder, 20)
		ui.list(inlineHolder, 0, false, Enum.HorizontalAlignment.Center)
		ui.padding(inlineHolder, 0, 0, 8, 8)
		optionsHolder = ui.new('Frame', {
			Name = 'Options',
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundColor3 = theme.Card,
			BackgroundTransparency = 1,
			LayoutOrder = 5,
			Size = UDim2.new(1, 0, 0, 0)
		}, page)
		ui.list(optionsHolder, 0, false, Enum.HorizontalAlignment.Center)
		component.Extras = ui.new('Frame', {
			Name = 'Extras',
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			LayoutOrder = 3,
			Size = UDim2.new(1, 0, 0, 0)
		}, page)
		ui.list(component.Extras, 8, false)
		component.Object = page
	else
		view = ui.card({
			Name = props.Name..'Card',
			Display = props.Name,
			Tooltip = props.Description or CATEGORYLIST_DESCRIPTIONS[props.Name] or '',
			ChildrenName = 'Children'
		})
		listHolder = view.Body
		optionsHolder = view.Body
		inlineHolder = view.Body
		component.View = view
		component.Object = view.Card
		layout.add({
			Card = view.Card,
			Tab = props.Tab or 'Utility',
			Name = props.Name,
			Key = props.Name:lower(),
			Search = {props.Name:lower()}
		})
		if props.Tab then
			-- Its own tab: the list opens the first time the tab does, as the card used to on a click.
			layout.TabShown[props.Tab] = function()
				if not component.Expanded then
					component:Expand()
				end
			end
		end

		-- The entry box: type a name and press Enter or the plus.
		local addrow = ui.row(listHolder, {LayoutOrder = -1}, 38)
		local addbkg = ui.pill(addrow, {Class = 'Frame', AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, theme.Inset, 0.5, 0), Size = UDim2.new(1, -theme.Inset * 2, 0, 28)})
		addvalue = ui.text(addbkg, {Class = 'TextBox', Size = 14, Color = theme.Text, Props = {
			ClearTextOnFocus = false,
			PlaceholderColor3 = theme.Muted,
			PlaceholderText = props.Placeholder or 'Add entry...',
			Position = UDim2.fromOffset(12, 0),
			Size = UDim2.new(1, -44, 1, 0)
		}})
		addbutton = ui.icon(addbkg, 'plus', 14, {Class = 'TextButton', Color = theme.SubText, Props = {
			AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -6, 0.5, 0)
		}})
	end
	props.Function = props.Function or function() end

	function component:CreateProfile(value, data, used)
		--[[ Names are the identity here: GetValue, ChangeValue and the profile file on disk all
		key off them, so two entries with the same name are two rows fighting over one file.

		usableProfileName is checked here too, not only where names are entered: this is what
		Load feeds the saved list through, so a bad name already written to gui.txt is dropped
		on the way back in rather than rebuilt into a row that crashes the next save. ]]
		if not usableProfileName(value) or self:GetValue(value) then
			return
		end

		local profile = {
			Name = value,
			Used = type(used) == 'number' and used or nil
		}

		profile.Bind = components.Bind({
			Module = true,
			Cover = true
		}, nil, profile)
		profile.Bind.Triggered:Connect(function(isPressed)
			if isPressed and currentEntry() ~= value then
				selectEntry(value)
				self:ChangeValue()
			end
		end)

		if data then
			profile.Bind:Load(data)
		end

		table.insert(self.List, profile)
	end

	local function profileCard(name, order)
		local isDefault = name.Name == 'default'
		local obj = ui.new('TextButton', {
			Name = name.Name,
			AutoButtonColor = false,
			BackgroundColor3 = theme.Card,
			BackgroundTransparency = 0,
			BorderSizePixel = 0,
			LayoutOrder = order,
			Text = ''
		}, listHolder)
		ui.corner(obj, 20)
		-- Slinky marks no card as the one in use; the stroke stays for the recolour code, off.
		local stroke = ui.stroke(obj, theme.Accent(), 1.5, 0)
		stroke.Enabled = false
		local nameRow = ui.new('Frame', {
			Name = 'Title',
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(theme.Inset, 12),
			Size = UDim2.new(1, -150, 0, 20)
		}, obj)
		ui.list(nameRow, 4, true)
		local nameLabel = ui.text(nameRow, {Text = isDefault and 'Default' or name.Name, Size = 16, Weight = 'Medium', Color = theme.Text, Props = {
			Name = 'Title', AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 1, Size = UDim2.fromOffset(0, 20), TextTruncate = Enum.TextTruncate.AtEnd
		}})
		ui.padding(nameLabel, 0, 0, 0, 2)
		if not isDefault or #name.Bind.Keys > 0 then
			name.Bind:SetParent(nameRow)
		end
		-- The profile in use says so beside its name, in the accent like a bound key's badge.
		if name.Enabled then
			local accent = theme.Accent()
			local inUse = ui.text(nameRow, {Text = 'IN USE', Size = 12, Weight = 'Bold', Color = accent, AlignX = Enum.TextXAlignment.Center, Props = {
				Name = 'InUse',
				AutomaticSize = Enum.AutomaticSize.X,
				BackgroundColor3 = theme.Tint(accent, 0.15),
				BackgroundTransparency = 0,
				LayoutOrder = 3,
				Size = UDim2.fromOffset(0, 20)
			}})
			ui.corner(inUse, 5)
			ui.padding(inUse, 6, 6, 0, 0)
			component.SelectedBadge = inUse
		end
		ui.text(obj, {Text = isDefault and 'Contains the default configuration.' or usedText(name.Used), Size = 14, Color = theme.SubText, Props = {
			Position = UDim2.fromOffset(theme.Inset, 40), Size = UDim2.new(1, -theme.Inset * 2, 0, 20)
		}})

		local icons = ui.new('Frame', {
			Name = 'Actions',
			AnchorPoint = Vector2.new(1, 0),
			AutomaticSize = Enum.AutomaticSize.X,
			BackgroundTransparency = 1,
			Position = UDim2.new(1, -9, 0, 10),
			Size = UDim2.fromOffset(0, 24)
		}, obj)
		ui.list(icons, 6, true, Enum.HorizontalAlignment.Right)
		local actions = component.CardActions or {}
		local function action(iconName, tip, order2, colour, callback)
			local button = ui.icon(icons, iconName, 20, {Class = 'TextButton', Color = colour or theme.SubText, Props = {LayoutOrder = order2, Size = UDim2.fromOffset(26, 24)}})
			addTooltip(button, tip)
			button.MouseEnter:Connect(function()
				if not colour then button.TextColor3 = theme.Text end
			end)
			button.MouseLeave:Connect(function()
				if not colour then button.TextColor3 = theme.SubText end
			end)
			if callback then
				button.MouseButton1Click:Connect(callback)
			end
			return button
		end

		--[[ The first icon loads the profile, held, as Slinky's cards do: holding it sweeps a ring round
		it in the accent, and the profile loads when the ring closes; letting go first winds it back.
		(Exporting is the Share profiles strip's Export profile.) The ring is two
		halves, each a clipped window onto a round stroke whose gradient is opaque on one side: turning
		the gradient sweeps the edge round, the right half for the first half of the hold and the left
		half for the second. ]]
		local loadButton = action('share', 'Hold to load', 0, nil, nil)
		do
			local HOLD_TIME = 0.6
			local ring = ui.new('Frame', {
				Name = 'LoadRing',
				AnchorPoint = Vector2.new(0.5, 0.5),
				BackgroundTransparency = 1,
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(30, 30),
				Visible = false
			}, loadButton)
			local track = ui.new('Frame', {BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1)}, ring)
			ui.corner(track, UDim.new(1, 0))
			ui.stroke(track, theme.Outline, 2, 0.3)
			local function half(isRight)
				local window = ui.new('Frame', {
					BackgroundTransparency = 1,
					ClipsDescendants = true,
					Position = UDim2.fromScale(isRight and 0.5 or 0, 0),
					Size = UDim2.fromScale(0.5, 1)
				}, ring)
				local circle = ui.new('Frame', {
					BackgroundTransparency = 1,
					Position = UDim2.fromScale(isRight and -1 or 0, 0),
					Size = UDim2.fromScale(2, 1)
				}, window)
				ui.corner(circle, UDim.new(1, 0))
				local stroke = ui.stroke(circle, theme.Accent(), 2, 0)
				return ui.new('UIGradient', {
					Transparency = NumberSequence.new({
						NumberSequenceKeypoint.new(0, 0),
						NumberSequenceKeypoint.new(0.499, 0),
						NumberSequenceKeypoint.new(0.5, 1),
						NumberSequenceKeypoint.new(1, 1)
					})
				}, stroke), stroke
			end
			local rightGradient, rightStroke = half(true)
			local leftGradient, leftStroke = half(false)
			local function paint(progress)
				rightGradient.Rotation = math.clamp(progress, 0, 0.5) * 360
				leftGradient.Rotation = math.clamp(progress, 0.5, 1) * 360
			end

			local holding, progress, stepper = false, 0, nil
			local function stop()
				if stepper then
					stepper:Disconnect()
					stepper = nil
				end
			end
			local function run()
				stop()
				ring.Visible = true
				rightStroke.Color, leftStroke.Color = theme.Accent(), theme.Accent()
				stepper = runService.RenderStepped:Connect(function(dt)
					-- The list rebuilt its rows mid-hold: this card is gone, and so is its profile's row.
					if not loadButton.Parent then
						stop()
						return
					end
					progress = math.clamp(progress + (holding and dt or -dt * 2) / HOLD_TIME, 0, 1)
					paint(progress)
					if progress >= 1 then
						stop()
						holding = false
						task.delay(0.12, function()
							ring.Visible = false
							progress = 0
							paint(0)
						end)
						selectEntry(name.Name)
						component:ChangeValue()
					elseif progress <= 0 and not holding then
						stop()
						ring.Visible = false
					end
				end)
			end
			loadButton.InputBegan:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
					holding = true
					run()
				end
			end)
			loadButton.InputEnded:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
					holding = false
				end
			end)
			loadButton.MouseLeave:Connect(function()
				holding = false
			end)
			-- The name and the hint over it, as the toggles' help shows.
			addRowTooltip(loadButton, 'Hold to load', loadButton, nil, obj)
		end
		action('import', 'Import into this profile', 2, nil, function()
			if actions.Import then actions.Import(name.Name) end
		end)
		action('folder-open', 'Copy folder path', 3, nil, function()
			if actions.Folder then actions.Folder(name.Name) end
		end)
		-- On every card, as in Slinky. Default and the profile in use refuse: deleting the one in use
		-- would leave nothing selected and the next autosave would write the file straight back.
		action('trash-2', 'Delete this profile', 4, theme.Red, function()
			if isDefault then
				vape:CreateNotification('Pistonware', 'The default profile cannot be deleted.', 4, 'warning')
				return
			end
			if name.Enabled then
				vape:CreateNotification('Pistonware', 'Switch to another profile before deleting this one.', 4, 'warning')
				return
			end
			ui.confirm("Delete the profile '"..name.Name.."'?", function()
				component:ChangeValue(name.Name)
			end, 'Delete')
		end)

		if name.Enabled then
			component.Selected = obj
			component.SelectedStroke = stroke
		end

		return {
			Destroy = function()
				name.Bind:SetParent(nil)
				obj:Destroy()
			end
		}
	end

	local function createCard(order)
		local obj = ui.new('TextButton', {
			Name = 'CreateProfile',
			AutoButtonColor = false,
			BackgroundColor3 = theme.Card,
			BackgroundTransparency = 0.5,
			BorderSizePixel = 0,
			LayoutOrder = order,
			Text = ''
		}, listHolder)
		ui.corner(obj, 20)
		local label = ui.text(obj, {Text = 'CREATE NEW PROFILE', Size = 15, Weight = 'Bold', Color = theme.Text, AlignX = Enum.TextXAlignment.Center, Props = {Size = UDim2.fromScale(1, 1)}})
		local box = ui.text(obj, {Class = 'TextBox', Size = 15, Color = theme.Text, AlignX = Enum.TextXAlignment.Center, Props = {
			ClearTextOnFocus = false,
			PlaceholderColor3 = theme.Muted,
			PlaceholderText = props.Placeholder or 'Type a name, then Enter',
			Size = UDim2.fromScale(1, 1),
			Visible = false
		}})
		obj.MouseButton1Click:Connect(function()
			label.Visible = false
			box.Visible = true
			box:CaptureFocus()
		end)
		box.FocusLost:Connect(function(enter)
			if enter or (isMobile() and box.Text ~= '') then
				addvalue = box
				component:Submit()
			end
			box.Text = ''
			box.Visible = false
			label.Visible = true
		end)
		return obj
	end

	local function swapRow(name, order)
		-- FFlags: a row per set, the current one in the accent.
		local obj = ui.new('TextButton', {
			Name = name.Name,
			AutoButtonColor = false,
			BackgroundTransparency = 1,
			LayoutOrder = order,
			Size = UDim2.new(1, 0, 0, 32),
			Text = ''
		}, listHolder)
		local title = ui.text(obj, {Text = name.Name, Size = 15, Weight = name.Enabled and 'Medium' or 'Regular', Color = name.Enabled and theme.Accent() or theme.Label, Props = {
			Name = 'Title', Position = UDim2.fromOffset(theme.Inset, 0), Size = UDim2.new(1, -140, 1, 0), TextTruncate = Enum.TextTruncate.AtEnd
		}})
		local right = ui.new('Frame', {
			AnchorPoint = Vector2.new(1, 0.5),
			AutomaticSize = Enum.AutomaticSize.X,
			BackgroundTransparency = 1,
			Position = UDim2.new(1, -theme.Inset, 0.5, 0),
			Size = UDim2.fromOffset(0, 24)
		}, obj)
		ui.list(right, 6, true, Enum.HorizontalAlignment.Right)
		name.Bind:SetParent(right)
		if name.Name ~= 'default' and not name.Enabled then
			local delete = ui.icon(right, 'trash-2', 15, {Class = 'TextButton', Color = theme.Red, Props = {LayoutOrder = 3, Size = UDim2.fromOffset(24, 24)}})
			delete.MouseButton1Click:Connect(function()
				component:ChangeValue(name.Name)
			end)
		end
		obj.MouseButton1Click:Connect(function()
			selectEntry(name.Name)
			component:ChangeValue()
		end)
		if name.Enabled then
			component.Selected = obj
			component.SelectedTitle = title
		end
		return {
			Destroy = function()
				name.Bind:SetParent(nil)
				obj:Destroy()
			end
		}
	end

	local function plainRow(name, order)
		local isEnabled = table.find(component.ListEnabled, name)
		local obj = ui.new('TextButton', {
			Name = name,
			AutoButtonColor = false,
			BackgroundTransparency = 1,
			LayoutOrder = order,
			Size = UDim2.new(1, 0, 0, 30),
			Text = ''
		}, listHolder)
		-- 'Dot' inside 'Dot': the Friends colour picker finds the dots by these names.
		local dot = ui.new('Frame', {
			Name = 'Dot',
			AnchorPoint = Vector2.new(0, 0.5),
			BackgroundColor3 = isEnabled and props.Color or theme.Muted,
			Position = UDim2.new(0, theme.Inset, 0.5, 0),
			Size = UDim2.fromOffset(12, 12)
		}, obj)
		ui.corner(dot, UDim.new(1, 0))
		local dotin = ui.new('Frame', {
			Name = 'Dot',
			BackgroundColor3 = isEnabled and props.Color or theme.Card,
			Position = UDim2.fromOffset(2, 2),
			Size = UDim2.fromOffset(8, 8)
		}, dot)
		ui.corner(dotin, UDim.new(1, 0))
		ui.text(obj, {Text = name, Size = 15, Color = theme.Label, Props = {
			Position = UDim2.fromOffset(theme.Inset + 22, 0), Size = UDim2.new(1, -(theme.Inset * 2 + 50), 1, 0), TextTruncate = Enum.TextTruncate.AtEnd
		}})
		local close = ui.icon(obj, 'x', 14, {Class = 'TextButton', Color = theme.SubText, Props = {
			AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -theme.Inset + 4, 0.5, 0)
		}})
		close.MouseButton1Click:Connect(function()
			component:ChangeValue(name)
		end)
		obj.MouseButton1Click:Connect(function()
			local index = table.find(component.ListEnabled, name)
			if index then
				table.remove(component.ListEnabled, index)
				dot.BackgroundColor3 = theme.Muted
				dotin.BackgroundColor3 = theme.Card
			else
				table.insert(component.ListEnabled, name)
				dot.BackgroundColor3 = props.Color
				dotin.BackgroundColor3 = props.Color
			end

			props.Function()
			vape:RequestSave()
		end)
		return obj
	end

	function component:ChangeValue(value, skipGUI)
		if value then
			if swapStyle then
				local index, profile = self:GetValue(value)
				if index then
					--[[ 'default' is the one entry that cannot be removed, in both shapes. It is
					what everything falls back to, so a list with no default is a list where the
					fallback names a row that does not exist. ]]
					if value ~= 'default' then
						profile.Bind:Destroy()
						table.remove(self.List, index)

						if props.Swap then
							if props.Delete then
								props.Delete(value)
							end
						elseif isfile('pistonware/profiles/'..value..vape.Place..'.txt') and delfile then
							delfile('pistonware/profiles/'..value..vape.Place..'.txt')
						end
					end
				else
					self:CreateProfile(value)
				end
			else
				local index = table.find(self.List, value)
				if index then
					table.remove(self.List, index)

					index = table.find(self.ListEnabled, value)
					if index then
						table.remove(self.ListEnabled, index)
					end
				else
					table.insert(self.List, value)
					table.insert(self.ListEnabled, value)
				end
			end
		end

		props.Function(value, skipGUI)
		-- A row added or removed is saved like any other change, as TextList does.
		if value ~= nil then
			vape:RequestSave()
		end
		for _, obj in self.Objects do
			obj:Destroy()
		end
		table.clear(self.Objects)
		self.Selected = nil
		self.SelectedStroke = nil
		self.SelectedTitle = nil
		self.SelectedBadge = nil

		if vape.ThreadFix then
			setthreadidentity(8)
		end

		-- default first, then the rest alphabetically; the saved order is left as it is.
		local ordered = table.clone(self.List)
		if swapStyle then
			table.sort(ordered, function(a, b)
				if a.Name == 'default' then return b.Name ~= 'default' end
				if b.Name == 'default' then return false end
				return a.Name:lower() < b.Name:lower()
			end)
		end

		for index, name in ordered do
			if swapStyle then
				name.Enabled = name.Name == currentEntry()
				if props.Profiles then
					table.insert(self.Objects, profileCard(name, index))
				else
					table.insert(self.Objects, swapRow(name, index))
				end
			else
				table.insert(self.Objects, plainRow(name, index))
			end
		end
		if props.Profiles then
			table.insert(self.Objects, createCard(#ordered + 1))
		end

		if not skipGUI then
			vape:UpdateGUI(vape.GUIColor.Hue, vape.GUIColor.Sat, vape.GUIColor.Value)
		end
	end

	function component:Color(hue, sat, val, isRainbow)
		for _, option in self.Options do
			if option.Color then
				option:Color(hue, sat, val, isRainbow)
			end
		end

		local accent = isRainbow and Color3.fromHSV(vape:Color(hue % 1)) or Color3.fromHSV(hue, sat, val)
		if self.SelectedStroke then
			self.SelectedStroke.Color = accent
		end
		if self.SelectedTitle then
			self.SelectedTitle.TextColor3 = accent
		end
		if self.SelectedBadge then
			self.SelectedBadge.TextColor3 = accent
			self.SelectedBadge.BackgroundColor3 = theme.Tint(accent, 0.15)
		end
	end

	function component:Expand()
		self.Expanded = not self.Expanded
		if view then
			view:SetExpanded(self.Expanded)
		end
		if self.Expanded and props.OnExpand then
			pcall(props.OnExpand)
		end
	end

	function component:GetValue(name)
		for index, profile in self.List do
			if profile.Name == name then
				return index, profile
			end
		end
	end

	function component:Load(data)
		vape:LoadOptions(self, data.Options)

		if self.Button.Enabled ~= (data.Enabled and true or false) then
			self.Button:Toggle()
		end

		if (self.Expanded and true or false) ~= (data.Expanded and true or false) then
			self:Expand()
		end

		if swapStyle then
			--[[
				Rebuilt, not appended to.

				CreateProfile pushes onto self.List unconditionally, and this loop feeds it the
				whole saved list every time. A second Load in the same session -- which is what
				a reinject does, and what arriving on a new server does before the old instance
				has finished tearing down -- therefore doubled the list, and every duplicate
				brought its own Bind into vape.ActiveBinds and its own row of GUI objects.
				Save then wrote the doubled list back out, so it persisted and doubled again.
			]]
			for _, profile in self.List do
				if profile.Bind and profile.Bind.Destroy then
					pcall(function() profile.Bind:Destroy() end)
				end
			end
			table.clear(self.List)

			for _, profile in data.List do
				if type(profile) == 'table' and type(profile.Name) == 'string' then
					self:CreateProfile(profile.Name, profile.Bind, profile.Used)
				end
			end

			--[[ Which entry is current is state the list owns only in Swap mode. For a profile
			list it lives in gui.txt's own Profile field (vape:Load reads it before this runs),
			so restoring it here would be a second, competing writer. Restored BEFORE the
			rebuild below so the right row comes back wearing the GUI colour. ]]
			if props.Swap and props.Restore and usableProfileName(data.Selected) then
				props.Restore(data.Selected)
			end

			self:ChangeValue(nil, true)
		else
			if data.List and (#self.List > 0 or #data.List > 0) then
				self.List = data.List or {}
				self.ListEnabled = data.ListEnabled or {}
				self:ChangeValue(nil, true)
			end
		end

		if data.Position then
			window.Position = UDim2.fromOffset(data.Position.X, data.Position.Y)
		end
	end

	function component:Save(data)
		data[props.Name] = {
			Enabled = self.Button.Enabled,
			Expanded = self.Expanded,
			List = self.List,
			ListEnabled = self.ListEnabled,
			Options = vape:SaveOptions(self),
			Position = {
				X = window.Position.X.Offset,
				Y = window.Position.Y.Offset
			}
		}

		if swapStyle then
			if props.Swap then
				data[props.Name].Selected = currentEntry()
			end

			local newList = {}

			for _, profile in self.List do
				local entry = {
					Name = profile.Name
				}

				profile.Bind:Save(entry)
				if profile.Used then
					entry.Used = profile.Used
				end
				table.insert(newList, entry)
			end

			data[props.Name].List = newList
		end
	end

	bindComponents(component, optionsHolder)

	--[[
		A second binding, into the list itself rather than the settings below it. Options is
		the same table, not a copy, so anything built through this still saves and loads with
		the list. Ordering is by LayoutOrder, which is why the components accept one.
	]]
	component.Inline = {
		Options = component.Options
	}
	bindComponents(component.Inline, inlineHolder)

	--[[ One path for both ways of submitting the box, and where the paste-an-export mistake is
	caught. On a profile list the text becomes a file name, so a pasted config used to be
	accepted, saved as the active profile, and crash the client on every inject afterwards.
	Turned away with an explanation rather than silently: pasting an export here is a
	reasonable thing to try, it is simply the wrong box. ]]
	function component:Submit()
		local text = addvalue and addvalue.Text or ''
		if text == '' then
			return
		end

		if swapStyle and not usableProfileName(text) then
			vape:CreateNotification('Pistonware', #text > 32
				and 'That is too long for a profile name. To bring in an exported profile, use the Import profile box below.'
				or 'A profile name can only use letters, numbers, spaces, - and _.', 10, 'alert')
			return
		end

		-- Profiles are tables, so a name is looked up with GetValue; a name already in the list
		-- is never passed to ChangeValue, which would take it as a delete.
		local exists
		if swapStyle then
			exists = component:GetValue(text) ~= nil
		else
			exists = table.find(component.List, text) ~= nil
		end
		if exists then
			if swapStyle then
				vape:CreateNotification('Pistonware', "There is already a profile called '"..text.."'.", 5, 'warning')
			end
			return
		end
		component:ChangeValue(text)
		addvalue.Text = ''
	end

	if addbutton then
		--[[ On a phone, tapping '+' first takes focus from the box, which submits it already. A
		rejected name stays in the box, so the tap itself would submit it again and repeat the alert. ]]
		local autoSubmitAt = -1
		addbutton.MouseButton1Click:Connect(function()
			if isMobile() and os.clock() - autoSubmitAt < 0.5 then
				return
			end
			component:Submit()
		end)
		addvalue.FocusLost:Connect(function(enter)
			-- A phone's keyboard is usually closed by tapping away, not by Return.
			if enter or (isMobile() and addvalue.Text ~= '') then
				autoSubmitAt = os.clock()
				component:Submit()
			end
		end)
	end

	if view then
		view.Header.MouseButton1Click:Connect(function()
			component:Expand()
		end)
		view.Header.MouseButton2Click:Connect(function()
			component:Expand()
		end)
		view.Expand.MouseButton1Click:Connect(function()
			component:Expand()
		end)
		-- The expander takes the whole description line, so a right-click there lands on it.
		view.Expand.MouseButton2Click:Connect(function()
			component:Expand()
		end)
	end

	component.Button = vape.Categories.Main:CreateGUIButton({
		Name = props.Name,
		Window = window
	})

	vape.Categories[props.Name] = component

	return component
end

components.ColorSlider = function(props, children, api)
	--[[ An option that names no colour starts on the menu's orange, not the old teal; one that names a
	hue keeps the full saturation and brightness it always had. ]]
	local orangeHue, orangeSat, orangeValue = Color3.fromRGB(243, 93, 18):ToHSV()
	local component = {
		Type = 'ColorSlider',
		Hue = props.DefaultHue or orangeHue,
		Sat = props.DefaultSat or (props.DefaultHue and 1 or orangeSat),
		Value = props.DefaultValue or (props.DefaultHue and 1 or orangeValue),
		Opacity = props.DefaultOpacity or 1,
		Rainbow = false,
		-- Where this colour sits in the rainbow's cycle, set from the Hue track while it runs.
		RainbowOffset = 0,
		Index = 0
	}

	local colorslider = ui.new('Frame', {
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = props.LayoutOrder or 0,
		Size = UDim2.new(1, 0, 0, 0),
		Visible = props.Visible == nil or props.Visible
	}, children)
	component.Object = colorslider
	ui.list(colorslider, 0)
	local line = ui.row(colorslider, {LayoutOrder = 1})
	ui.rowLabel(line, props, 60)
	local swatch = ui.new('TextButton', {
		Name = 'Swatch',
		AnchorPoint = Vector2.new(1, 0.5),
		AutoButtonColor = false,
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		Position = UDim2.new(1, -theme.Inset, 0.5, 0),
		Size = UDim2.fromOffset(40, 20),
		Text = ''
	}, line)
	ui.corner(swatch, UDim.new(1, 0))
	local swatchGradient = ui.new('UIGradient', {}, swatch)
	--[[ The Opacity track is for options that use it: those that name a default opacity, and those
	whose callback takes the fourth (opacity) argument. ]]
	local usesOpacity = props.DefaultOpacity ~= nil
	if not usesOpacity and type(props.Function) == 'function' then
		local ok, arity = pcall(debug.info, props.Function, 'a')
		usesOpacity = ok and (tonumber(arity) or 0) >= 4
	end
	props.Function = props.Function or function() end

	-- The picker's live pieces while it is open; nil when it is closed.
	local open

	--[[ The far end of the swatch fades darker, as Slinky's does. A colour already near black fades
	lighter instead, toward grey: the swatch still reads as black at its start, and as a swatch at
	all on the dark card, without an outline. ]]
	local function swatchEnd(h, s, v)
		local base = Color3.fromHSV(h, s, v)
		if v < 0.3 then
			return base:Lerp(Color3.fromRGB(96, 96, 96), 0.75)
		end
		return Color3.fromHSV(h, s, v * 0.35)
	end

	--[[ A rainbow shows its whole cycle at its saturation and brightness, from the hue it is on now.
	A colour near black is lifted toward grey, as swatchEnd does, so it still reads on the card. ]]
	local function rainbowSequence(h, s, v)
		local points = {}
		for i = 0, 6 do
			local stop = Color3.fromHSV((h + i / 6) % 1, s, v)
			if v < 0.3 then
				stop = stop:Lerp(Color3.fromRGB(96, 96, 96), 0.5)
			end
			table.insert(points, ColorSequenceKeypoint.new(i / 6, stop))
		end
		return ColorSequence.new(points)
	end

	local function paintSwatch()
		if component.Rainbow then
			swatchGradient.Color = rainbowSequence(component.Hue, component.Sat, component.Value)
		else
			local base = Color3.fromHSV(component.Hue, component.Sat, component.Value)
			swatchGradient.Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, base),
				ColorSequenceKeypoint.new(1, swatchEnd(component.Hue, component.Sat, component.Value))
			})
		end
		swatchGradient.Transparency = NumberSequence.new(1 - component.Opacity, 1 - component.Opacity)
	end

	--[[ Vape's tracks: Saturation and Brightness are the colour's own HSV saturation and value. The
	old Lightness track was HSL, where the far end is white for every hue -- a rainbow there stayed
	white whatever the saturation, so the colour never visibly changed. ]]
	local function paintPicker()
		if not open then return end
		local h = component.Hue
		local sat, value = component.Sat, component.Value
		local color = Color3.fromHSV(h, sat, value)
		open.Square.BackgroundColor3 = Color3.new(1, 1, 1)
		open.SquareGradient.Color = component.Rainbow and rainbowSequence(h, component.Sat, component.Value)
			or ColorSequence.new(color, swatchEnd(h, component.Sat, component.Value))
		if not open.Hex:IsFocused() then
			open.Hex.Text = '#'..color:ToHex():lower()
		end
		open.Sat.Gradient.Color = ColorSequence.new(Color3.fromHSV(h, 0, value), Color3.fromHSV(h, 1, value))
		open.Light.Gradient.Color = ColorSequence.new(Color3.new(), Color3.fromHSV(h, sat, 1))
		open.Hue.Knob.Position = UDim2.fromScale(h, 0.5)
		open.Sat.Knob.Position = UDim2.fromScale(sat, 0.5)
		open.Light.Knob.Position = UDim2.fromScale(value, 0.5)
		for _, track in {open.Hue, open.Sat, open.Light, open.Opacity} do
			track.Knob.BackgroundColor3 = color
		end
		if open.Opacity.Holder.Parent then
			open.Opacity.Gradient.Color = ColorSequence.new(theme.Card, color)
			open.Opacity.Knob.Position = UDim2.fromScale(component.Opacity, 0.5)
		end
		if open.Rainbow and open.Rainbow.Enabled ~= component.Rainbow then
			open.Rainbow:Set(component.Rainbow)
		end
	end

	function component:Load(data)
		self.RainbowOffset = tonumber(data.RainbowOffset) or 0
		if data.Rainbow ~= self.Rainbow then
			self:Toggle()
		end

		if self.Hue ~= data.Hue or self.Sat ~= data.Sat or self.Value ~= data.Value or self.Opacity ~= data.Opacity then
			self:SetValue(data.Hue, data.Sat, data.Value, data.Opacity)
		end
	end

	function component:Save(data)
		data[props.Name] = {
			Hue = self.Hue,
			Sat = self.Sat,
			Value = self.Value,
			Opacity = self.Opacity,
			Rainbow = self.Rainbow,
			RainbowOffset = self.RainbowOffset
		}
	end

	function component:SetValue(h, s, v, o)
		--[[ Vape's rainbow: the loop moves the hue alone, every frame, and the saturation, brightness
		and opacity stay what they were set to. The hue it hands over is the cycle's; this colour's
		offset into it is added here. ]]
		local cycling = self.Rainbow and h ~= nil and s == nil and v == nil and o == nil
		if cycling then
			h = (h + self.RainbowOffset) % 1
		end
		self.Hue = h or self.Hue
		self.Sat = s or self.Sat
		self.Value = v or self.Value
		self.Opacity = o or self.Opacity
		paintSwatch()
		paintPicker()

		props.Function(self.Hue, self.Sat, self.Value, self.Opacity)
		-- The hue a running rainbow happens to be on is nobody's setting; anything else is.
		if not cycling then
			vape:RequestSave()
		end
	end

	function component:Toggle()
		self.Rainbow = not self.Rainbow

		if self.Rainbow then
			addRainbowSlider(self)
		else
			removeRainbowSlider(self)
		end
		paintSwatch()
		paintPicker()
		vape:RequestSave()
	end

	function component:Color() end

	-- Typing a colour or choosing a recent one ends a rainbow: that is a colour picked.
	local function pick(h, s, v, o)
		if component.Rainbow then
			component:Toggle()
		end
		component:SetValue(h, s, v, o)
	end

	--[[ The tracks leave a rainbow running, as Vape's sliders do: saturation, brightness and opacity
	shape it, and the Hue track moves where this colour sits in the cycle -- it carries on from the
	hue it was dropped on. ]]
	local function adjust(h, s, v, o)
		if h and component.Rainbow then
			h = math.min(h, 0.9999)
			local base = (component.Hue - component.RainbowOffset) % 1
			component.RainbowOffset = (h - base) % 1
			component:SetValue(base)
			vape:RequestSave()
			return
		end
		component:SetValue(h, s, v, o)
	end

	local function remember()
		local color = Color3.fromHSV(component.Hue, component.Sat, component.Value)
		local recent = layout.RecentColors
		for index = #recent, 1, -1 do
			if recent[index]:ToHex() == color:ToHex() then
				table.remove(recent, index)
			end
		end
		table.insert(recent, 1, color)
		while #recent > 8 do
			table.remove(recent)
		end
	end

	--[[ Slinky's colour picker: a modal pinned under the tab bar like the confirm dialog -- title
	and close, the colour and its hex, Hue / Saturation / Brightness tracks, then the eight colours
	used most recently. Options that carry an opacity get an Opacity track too. ]]
	local function openPicker()
		if not clickgui or open then return end
		local scaleNow = math.max(scale.Scale, 0.05) * (layout.Zoom or 1)
		local blocker = ui.new('TextButton', {
			Name = 'ColorPicker',
			AutoButtonColor = false,
			BackgroundColor3 = Color3.fromRGB(48, 48, 48),
			BackgroundTransparency = 0.25,
			BorderSizePixel = 0,
			Size = UDim2.fromScale(1, 1),
			Text = '',
			ZIndex = 20
		}, clickgui)
		local width = math.clamp(viewportWidth() / scaleNow - 24, 260, 576)
		local card = ui.new('TextButton', {
			AutoButtonColor = false,
			AnchorPoint = Vector2.new(0.5, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundColor3 = theme.Card,
			BorderSizePixel = 0,
			-- Under Roblox's top bar on a phone, level with the menu window (resize keeps layout.Top).
			Position = UDim2.new(0.5, 0, 0, layout.Top or 12),
			Size = UDim2.fromOffset(width, 0),
			Text = '',
			ZIndex = 21
		}, blocker)
		ui.corner(card, 20)
		-- The window's zoom, but never taller than the screen leaves under its top: the tracks at its
		-- foot stay on screen on a short landscape phone.
		local fit = layout.Zoom or 1
		local camera = gameCamera or workspace.CurrentCamera
		local room = camera and camera.ViewportSize.Y / math.max(scale.Scale, 0.05) - (layout.Top or 12) - 8 or 0
		if room > 0 then
			fit = math.min(fit, room / (usesOpacity and 370 or 320))
		end
		ui.new('UIScale', {Scale = fit}, card)
		ui.list(card, 0)
		ui.padding(card, 12, 12, 11, 12)

		local function zText(parent, text, size, props2)
			local label = ui.text(parent, {Text = text, Size = size, Color = theme.Text, Props = props2})
			label.ZIndex = 22
			return label
		end
		local header = ui.new('Frame', {BackgroundTransparency = 1, LayoutOrder = 1, Size = UDim2.new(1, 0, 0, 20), ZIndex = 22}, card)
		zText(header, props.DisplayName or props.Name, 16, {Size = UDim2.new(1, -40, 1, 0)})
		local close = ui.icon(header, 'x', 21, {Class = 'TextButton', Color = theme.SubText, Box = UDim2.fromOffset(24, 24), Props = {
			AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 2, 0.5, 0), ZIndex = 22
		}})
		close.Glyph.ZIndex = 23

		local valueRow = ui.new('Frame', {BackgroundTransparency = 1, LayoutOrder = 2, Size = UDim2.new(1, 0, 0, 34), ZIndex = 22}, card)
		local square = ui.new('Frame', {
			AnchorPoint = Vector2.new(0, 0.5),
			BorderSizePixel = 0,
			Position = UDim2.new(0, 0, 0.5, 2),
			Size = UDim2.fromOffset(22, 22),
			ZIndex = 22
		}, valueRow)
		ui.corner(square, 4)
		local squareGradient = ui.new('UIGradient', {Rotation = 45}, square)
		local hex = ui.text(valueRow, {Class = 'TextBox', Size = 16, Color = theme.Text, Props = {
			ClearTextOnFocus = false,
			Position = UDim2.fromOffset(30, 2),
			Size = UDim2.new(1, -30, 1, 0),
			ZIndex = 22
		}})

		local function track(name, order, gradient)
			local section = ui.new('Frame', {BackgroundTransparency = 1, LayoutOrder = order, Size = UDim2.new(1, 0, 0, 50), ZIndex = 22}, card)
			zText(section, name, 15, {Position = UDim2.fromOffset(0, 6), Size = UDim2.new(1, 0, 0, 20)})
			local holder = ui.new('Frame', {
				Name = 'Holder',
				AnchorPoint = Vector2.new(0, 0.5),
				BackgroundColor3 = Color3.new(1, 1, 1),
				BorderSizePixel = 0,
				Position = UDim2.new(0, 0, 0, 37),
				Size = UDim2.new(1, 0, 0, 10),
				ZIndex = 22
			}, section)
			ui.corner(holder, UDim.new(1, 0))
			local fill = ui.new('UIGradient', {Color = gradient}, holder)
			local knob = ui.new('Frame', {
				Name = 'Knob',
				AnchorPoint = Vector2.new(0.5, 0.5),
				BorderSizePixel = 0,
				Size = UDim2.fromOffset(18, 18),
				ZIndex = 23
			}, holder)
			ui.corner(knob, UDim.new(1, 0))
			ui.stroke(knob, Color3.new(1, 1, 1), 2, 0)
			local hit = ui.new('TextButton', {
				BackgroundTransparency = 1,
				Position = UDim2.fromOffset(0, 24),
				Size = UDim2.new(1, 0, 0, 26),
				Text = '',
				ZIndex = 24
			}, section)
			return {Holder = holder, Gradient = fill, Knob = knob, Hit = hit, Section = section}
		end
		local rainbow = {}
		for i = 0, 1, 0.1 do
			table.insert(rainbow, ColorSequenceKeypoint.new(i, Color3.fromHSV(i, 1, 1)))
		end
		local hue = track('Hue', 3, ColorSequence.new(rainbow))
		local sat = track('Saturation', 4, ColorSequence.new(Color3.new(), Color3.new()))
		local light = track('Brightness', 5, ColorSequence.new(Color3.new(), Color3.new()))
		local opacity = track('Opacity', 6, ColorSequence.new(Color3.new(), Color3.new()))
		if not usesOpacity then
			opacity.Section:Destroy()
		end

		-- Rainbow: the colour cycles through every hue. Typing a colour or choosing a recent one turns it off.
		local rainbowRow = ui.new('Frame', {BackgroundTransparency = 1, LayoutOrder = 7, Size = UDim2.new(1, 0, 0, 40), ZIndex = 22}, card)
		zText(rainbowRow, 'Rainbow', 15, {Position = UDim2.fromOffset(0, 8), Size = UDim2.new(1, -60, 0, 24)})
		local rainbowSwitch = ui.switch(rainbowRow, UDim2.new(1, 0, 0, 20))
		rainbowSwitch.Object.ZIndex = 22
		rainbowSwitch.Object.Knob.ZIndex = 23
		local rainbowHit = ui.new('TextButton', {
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			Text = '',
			ZIndex = 24
		}, rainbowRow)
		rainbowHit.MouseButton1Click:Connect(function()
			component:Toggle()
			rainbowSwitch:Set(component.Rainbow)
			paintPicker()
		end)

		local recentSection = ui.new('Frame', {BackgroundTransparency = 1, AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 8, Size = UDim2.new(1, 0, 0, 0), ZIndex = 22}, card)
		ui.list(recentSection, 4)
		zText(recentSection, 'Recently used', 15, {LayoutOrder = 1, Size = UDim2.new(1, 0, 0, 26)})
		local boxes = ui.new('Frame', {BackgroundTransparency = 1, LayoutOrder = 2, Size = UDim2.new(1, 0, 0, 24), ZIndex = 22}, recentSection)
		local grid = Instance.new('UIGridLayout')
		grid.CellPadding = UDim2.fromOffset(8, 0)
		grid.CellSize = UDim2.new(1 / 8, -7, 0, 24)
		grid.SortOrder = Enum.SortOrder.LayoutOrder
		grid.Parent = boxes
		for index = 1, 8 do
			local color = layout.RecentColors[index]
			local box = ui.new('TextButton', {
				AutoButtonColor = false,
				BackgroundColor3 = color or theme.Card,
				BorderSizePixel = 0,
				LayoutOrder = index,
				Text = '',
				ZIndex = 22
			}, boxes)
			ui.corner(box, 4)
			ui.stroke(box, theme.Outline, 2, 0)
			if color then
				box.MouseButton1Click:Connect(function()
					local h, s, v = color:ToHSV()
					pick(h, s, v)
				end)
			end
		end

		open = {Square = square, SquareGradient = squareGradient, Hex = hex, Hue = hue, Sat = sat, Light = light, Opacity = opacity, Rainbow = rainbowSwitch}
		rainbowSwitch:Set(component.Rainbow)
		paintPicker()

		local before = Color3.fromHSV(component.Hue, component.Sat, component.Value):ToHex()
		local function dismiss()
			-- A cycling rainbow is on whatever hue it reached; that is no colour anyone picked.
			if not component.Rainbow and Color3.fromHSV(component.Hue, component.Sat, component.Value):ToHex() ~= before then
				remember()
			end
			open = nil
			blocker:Destroy()
		end
		blocker.MouseButton1Click:Connect(dismiss)
		close.MouseButton1Click:Connect(dismiss)

		local function drag(entry, apply)
			entry.Hit.InputBegan:Connect(function(input)
				if not isPress(input) then return end
				trackDrag(input, entry.Holder, apply)
			end)
		end
		drag(hue, function(value)
			adjust(value)
		end)
		drag(sat, function(value)
			adjust(nil, value)
		end)
		drag(light, function(value)
			adjust(nil, nil, value)
		end)
		drag(opacity, function(value)
			adjust(nil, nil, nil, value)
		end)

		hex.FocusLost:Connect(function(enter)
			if enter then
				local success, parsed = pcall(function()
					local commas = hex.Text:split(',')
					return tonumber(commas[1]) and Color3.fromRGB(tonumber(commas[1]), tonumber(commas[2]), tonumber(commas[3])) or Color3.fromHex(hex.Text)
				end)
				if success and parsed then
					pick(parsed:ToHSV())
				end
			end
			paintPicker()
		end)
	end

	swatch.MouseButton1Click:Connect(openPicker)

	paintSwatch()
	api.Options[props.Name] = component

	return component
end

components.Divider = function(props, children, api)
	if props and props.Text then
		-- A section header, as Slinky groups its settings: grey, no rule under it.
		local row = ui.row(children, props, 27)
		ui.text(row, {Text = props.Text, Size = 15, Color = theme.Header, Props = {
			Name = 'Header',
			Position = UDim2.fromOffset(theme.Inset, 9),
			Size = UDim2.new(1, -theme.Inset * 2, 0, 21)
		}})
		return
	end

	local row = ui.row(children, props or {}, 9)
	ui.new('Frame', {
		AnchorPoint = Vector2.new(0, 0.5),
		BackgroundColor3 = theme.Outline,
		BackgroundTransparency = 0.5,
		BorderSizePixel = 0,
		Position = UDim2.new(0, theme.Inset, 0.5, 0),
		Size = UDim2.new(1, -theme.Inset * 2, 0, 1)
	}, row)
end

components.Dropdown = function(props, children, api)
	local component = {
		Index = 0,
		Type = 'Dropdown',
		Value = props.List[1] or 'None'
	}

	local dropdown = ui.new('Frame', {
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = props.LayoutOrder or 0,
		Size = UDim2.new(1, 0, 0, 0),
		Visible = props.Visible == nil or props.Visible
	}, children)
	component.Object = dropdown
	ui.list(dropdown, 0)
	local line = ui.row(dropdown, {LayoutOrder = 1})
	ui.rowLabel(line, props)
	addTooltip(line, props.Tooltip or props.Name)
	-- The pill carries its own text, so nothing here is shaped like a button to autoexec/mcp.lua.
	local button = ui.pill(line, {})
	button.Name = 'Value'
	local title = ui.text(button, {Text = component.Value, Size = 15, Color = theme.Text, AlignX = Enum.TextXAlignment.Center, Props = {
		Position = UDim2.fromOffset(12, 0),
		Size = UDim2.new(1, -24, 1, 0),
		TextTruncate = Enum.TextTruncate.AtEnd
	}})
	props.Function = props.Function or function() end

	--[[ The list opens over the rows below it rather than pushing them down: an outlined box laid on
	the menu itself, its top on the pill so the first choice sits where the pill's text was, the
	choices stacked inside and the one in use in the accent, as Slinky draws it. Picking one, a click
	anywhere else or closing the menu closes it. ]]
	local ENTRY_HEIGHT = 26
	local blocker, hideConnection
	local function closeList()
		if hideConnection then
			hideConnection:Disconnect()
			hideConnection = nil
		end
		if blocker then
			if layout.ListOpen == blocker then
				layout.ListOpen = nil
			end
			blocker:Destroy()
			blocker = nil
		end
	end

	local function openList()
		closeList()
		if not (clickgui and clickgui.Visible and button.AbsoluteSize.X > 0) then return end
		local s = math.max(scale.Scale, 0.05)
		local zoom = layout and layout.Zoom or 1
		blocker = ui.new('TextButton', {
			Name = 'DropdownList',
			AutoButtonColor = false,
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			Text = '',
			ZIndex = 18
		}, clickgui)
		--[[ The rows under the list still get their hover events, so their value bubbles and help
		pills are held back while it is open, and any already showing are put away. ]]
		layout.ListOpen = blocker
		tooltip.Visible = false
		for _, child in clickgui:GetChildren() do
			if child.Name == 'SliderBubble' then
				child.Visible = false
			end
		end
		blocker.MouseButton1Click:Connect(closeList)
		blocker.MouseButton2Click:Connect(closeList)
		hideConnection = clickgui:GetPropertyChangedSignal('Visible'):Connect(closeList)

		local height = math.min(#props.List, 8) * ENTRY_HEIGHT + 4
		local box = ui.new('Frame', {
			BackgroundColor3 = theme.Card,
			BorderSizePixel = 0,
			Size = UDim2.fromOffset(button.AbsoluteSize.X / (s * zoom), height),
			ZIndex = 18
		}, blocker)
		ui.corner(box, 10)
		ui.stroke(box, theme.Outline, 2, 0)
		ui.new('UIScale', {Scale = zoom}, box)
		-- 4 units above the pill's top centres the first choice on it; kept on screen near the bottom.
		local origin = blocker.AbsolutePosition
		local top = button.AbsolutePosition.Y - 4 * s * zoom
		local limit = origin.Y + blocker.AbsoluteSize.Y - 8
		if top + height * s * zoom > limit then
			top = math.max(origin.Y + 8, limit - height * s * zoom)
		end
		box.Position = UDim2.fromOffset((button.AbsolutePosition.X - origin.X) / s, (top - origin.Y) / s)

		local list = ui.new('ScrollingFrame', {
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			CanvasSize = UDim2.fromOffset(0, #props.List * ENTRY_HEIGHT),
			Position = UDim2.fromOffset(8, 2),
			ScrollBarThickness = 0,
			ScrollingDirection = Enum.ScrollingDirection.Y,
			Size = UDim2.new(1, -16, 1, -4),
			ZIndex = 18
		}, box)
		ui.list(list, 0)
		for index, v in props.List do
			local selected = v == component.Value
			local entry = ui.text(list, {Class = 'TextButton', Text = v, Size = 15, Color = selected and theme.Accent() or theme.Text, AlignX = Enum.TextXAlignment.Center, Props = {
				LayoutOrder = index,
				Size = UDim2.new(1, 0, 0, ENTRY_HEIGHT),
				TextTruncate = Enum.TextTruncate.AtEnd,
				ZIndex = 19
			}})
			if not selected then
				entry.MouseEnter:Connect(function()
					entry.TextColor3 = Color3.new(1, 1, 1)
				end)
				entry.MouseLeave:Connect(function()
					entry.TextColor3 = theme.Text
				end)
			end
			entry.MouseButton1Click:Connect(function()
				component:SetValue(v, true)
			end)
		end
	end

	function component:Change(list)
		props.List = list or {}
		if not table.find(props.List, self.Value) then
			self:SetValue(self.Value)
		elseif blocker then
			openList()
		end
	end

	function component:Load(data)
		if self.Value ~= data.Value then
			self:SetValue(data.Value)
		end
	end

	function component:Save(data)
		data[props.Name] = {
			Value = self.Value
		}
	end

	function component:SetValue(value, isClick)
		self.Value = table.find(props.List, value) and value or props.List[1] or 'None'
		title.Text = self.Value
		closeList()

		props.Function(self.Value, isClick)
		vape:RequestSave()
	end

	button.MouseButton1Click:Connect(function()
		if blocker then
			closeList()
		else
			openList()
		end
	end)

	button.MouseEnter:Connect(function()
		tween:Tween(button, uipallet.Tween, {BackgroundColor3 = theme.Raised})
	end)

	button.MouseLeave:Connect(function()
		tween:Tween(button, uipallet.Tween, {BackgroundColor3 = theme.Card})
	end)

	api.Options[props.Name] = component

	return component
end

components.Font = function(props, children, api)
	--[[ Slinky has no font picker anywhere, so this menu has none either: every element keeps the
	face it was designed with -- the menu's Inter, or the caller's Default where one is named
	(Target Info's terminal face). The option still exists and still saves and loads under its
	name, so profiles keep their shape and code reading .Value always gets a real Font; it just
	never draws a row, and a font saved by an older build is not applied. ]]
	local fontNames = {}
	table.insert(fontNames, props.Default or 'Inter')
	if not table.find(fontNames, 'Inter') then table.insert(fontNames, 'Inter') end
	table.insert(fontNames, 'Custom')
	for _, v in Enum.Font:GetEnumItems() do
		if not table.find(fontNames, v.Name) then
			table.insert(fontNames, v.Name)
		end
	end
	local designed = props.Default or 'Inter'

	-- Inter is the menu's face at the menu's weight, so overlays, HUD text and name tags read as
	-- the same type as the menu and the mod overlay.
	local function resolve(name)
		if name == 'Inter' then
			return uipallet.FontMedium or uipallet.Font
		end
		local ok, face = pcall(Font.fromEnum, Enum.Font[name])
		return ok and face or uipallet.Font
	end

	local component = {
		Value = resolve(designed)
	}
	local function apply()
		component.Value = resolve(designed)
		if props.Function then
			props.Function(component.Value)
		end
	end

	local fontdropdown = components.Dropdown({
		Name = props.Name,
		List = fontNames,
		Function = apply,
		Visible = false
	}, children, api)
	fontdropdown.Object.Visible = false
	-- Saved by older builds next to the picker; kept so their profiles load into the same shape.
	local fontbox = components.TextBox({
		Name = props.Name..' Asset',
		Placeholder = 'font (rbxasset)',
		Visible = false
	}, children, api)
	fontbox.Object.Visible = false

	-- Game code shows and hides option rows through .Object; this option has no row to show.
	component.Object = ui.new('Frame', {Name = 'HiddenFont', Visible = false})

	-- The menu's Inter arrives after the menu is built (fonts.init runs in the background).
	fonts.Remeasure[component] = apply
	--[[ And once on the next resume, after the caller has built what it draws with: a profile that
	saved this option's default never sets it, which left that text in whatever face the module
	started it in. ]]
	task.defer(function()
		pcall(apply)
	end)

	return component
end
--[[ Where each settings pane is drawn: the GUI card holds the menu's own settings in sections,
the Notifications card its own. A pane a game adds lands in the GUI card under its name. ]]
local settingsHosts = {}
local PANE_HOSTS = {Notifications = 'Notifications'}
local PANE_ORDER = {Settings = 1, GUI = 2, General = 3, Modules = 4, Notifications = 1}
local PANE_TITLES = {Settings = 'Main', GUI = 'Interface', General = 'General', Modules = 'Modules', Notifications = false}

local TAB_ORDER = {'Combat', 'Move', 'Visual', 'Utility', 'Kits', 'FFlags', 'Profiles', 'Unload'}

components.GUI = function(props, children, api)
	local component = {
		Buttons = {},
		Type = 'MainWindow'
	}

	-- Cards that are not in the open tab are parked here, out of the layout.
	layout.Hidden = ui.new('Frame', {
		Name = 'Hidden',
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(theme.CardWidth, 0),
		Visible = false
	}, clickgui)
	-- The position the old menu's main window saved, kept so the save file does not change shape.
	local legacy = ui.new('Frame', {
		Name = 'GUICategory',
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(6, 60),
		Visible = false
	}, layout.Hidden)
	local hiddenChildren = ui.new('Frame', {
		Name = 'MainChildren',
		BackgroundColor3 = theme.Card,
		BackgroundTransparency = 1,
		Visible = false
	}, layout.Hidden)
	ui.list(hiddenChildren, 0)

	local dim = ui.new('Frame', {
		Name = 'Dim',
		BackgroundColor3 = Color3.fromRGB(48, 48, 48),
		BackgroundTransparency = 0.25,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Visible = clickgui.Visible,
		ZIndex = 0
	}, scaledgui)
	clickgui:GetPropertyChangedSignal('Visible'):Connect(function()
		dim.Visible = clickgui.Visible
	end)

	local window = ui.new('Frame', {
		Name = 'MainWindow',
		AnchorPoint = Vector2.new(0.5, 0),
		BackgroundTransparency = 1,
		Position = UDim2.new(0.5, 0, 0, 12),
		Size = UDim2.new(0, 876, 1, -24),
		ZIndex = 1
	}, clickgui)
	component.Object = window
	-- What Move HUD hides while the menu stays open.
	layout.Window, layout.Dim = window, dim

	-- The tab bar.
	local bar = ui.new('Frame', {
		Name = 'TabBar',
		BackgroundColor3 = theme.Bar,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 42)
	}, window)
	ui.corner(bar, UDim.new(1, 0))
	-- Equal slots across the whole bar.
	local tabsFrame = ui.new('Frame', {
		Name = 'Tabs',
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1)
	}, bar)
	local activePill = ui.new('Frame', {
		Name = 'Active',
		AnchorPoint = Vector2.new(0, 0.5),
		BackgroundColor3 = theme.Pill,
		BorderSizePixel = 0,
		Position = UDim2.new(0, 6, 0.5, 0),
		Size = UDim2.new(1 / #TAB_ORDER, -12, 0, 30)
	}, tabsFrame)
	ui.corner(activePill, UDim.new(1, 0))
	local tabButtons = {}
	for index, name in TAB_ORDER do
		tabButtons[name] = ui.text(tabsFrame, {Class = 'TextButton', Text = name, Size = 16, Weight = 'Medium',
			Color = name == 'Unload' and theme.Red or theme.Text, AlignX = Enum.TextXAlignment.Center, Props = {
				Name = name,
				Position = UDim2.new((index - 1) / #TAB_ORDER, 0, 0, -1),
				Size = UDim2.fromScale(1 / #TAB_ORDER, 1)
			}})
	end

	-- The pages.
	local pagesFrame = ui.new('Frame', {
		Name = 'Pages',
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 50),
		Size = UDim2.new(1, 0, 1, -50)
	}, window)

	local function makePage(name)
		local page = ui.new('ScrollingFrame', {
			Name = name,
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			CanvasSize = UDim2.new(),
			ScrollBarImageColor3 = theme.Muted,
			ScrollBarThickness = 0,
			ScrollingDirection = Enum.ScrollingDirection.Y,
			Size = UDim2.fromScale(1, 1),
			Visible = false
		}, pagesFrame)
		local left = ui.new('Frame', {
			Name = 'Left',
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			Size = UDim2.new(0.5, -theme.Gap / 2, 0, 0)
		}, page)
		ui.list(left, theme.Gap)
		local right = ui.new('Frame', {
			Name = 'Right',
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			Position = UDim2.new(0.5, theme.Gap / 2, 0, 0),
			Size = UDim2.new(0.5, -theme.Gap / 2, 0, 0)
		}, page)
		ui.list(right, theme.Gap)
		local empty = ui.text(page, {Text = name == 'Search' and 'No modules match.' or 'Nothing in this tab here.', Size = 15, Color = theme.Muted, AlignX = Enum.TextXAlignment.Center, Props = {
			Size = UDim2.new(1, 0, 0, 60),
			Visible = false
		}})
		layout.Pages[name] = {Frame = page, Left = left, Right = right, Empty = empty}
	end
	for _, name in TABS do
		makePage(name)
	end

	local profilesPage = ui.new('ScrollingFrame', {
		Name = 'Profiles',
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		CanvasSize = UDim2.new(),
		ScrollBarImageColor3 = theme.Muted,
		ScrollBarThickness = 0,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Size = UDim2.fromScale(1, 1),
		Visible = false
	}, pagesFrame)
	ui.list(profilesPage, theme.Gap)
	ui.padding(profilesPage, 0, 0, 0, 12)
	layout.Pages.Profiles = {Frame = profilesPage}

	local currentTab = 'Combat'
	-- Tabs a place has no use for (Kits in the lobby) are taken out of the bar.
	local hiddenTabs = {Kits = game.PlaceId == 6872265039 or nil}
	local function visibleTabs()
		local list = {}
		for _, name in TAB_ORDER do
			if not hiddenTabs[name] then
				table.insert(list, name)
			end
		end
		return list
	end
	local function showPages()
		local searching = layout.Search ~= ''
		for tab, info in layout.Pages do
			info.Frame.Visible = (searching and tab == 'Search') or (not searching and tab == currentTab)
		end
	end

	local function selectTab(name)
		if name == 'Unload' then
			ui.confirm('Unload Pistonware from this game?', function()
				vape:Uninject()
			end, 'Unload')
			return
		end
		currentTab = name
		showPages()
		local visible = visibleTabs()
		local index = table.find(visible, name) or 1
		tween:Tween(activePill, uipallet.Tween, {
			Position = UDim2.new((index - 1) / #visible, 6, 0.5, 0)
		})
		layout.request(name)
		if layout.TabShown[name] then
			task.spawn(layout.TabShown[name])
		end
	end
	component.SelectTab = selectTab

	-- Re-spaces the bar over the tabs that are showing, and moves the pill with them.
	local function layoutTabs()
		local visible = visibleTabs()
		for name, button in tabButtons do
			local index = table.find(visible, name)
			button.Visible = index ~= nil
			if index then
				button.Position = UDim2.new((index - 1) / #visible, 0, 0, -1)
				button.Size = UDim2.fromScale(1 / #visible, 1)
			end
		end
		activePill.Size = UDim2.new(1 / #visible, -12, 0, 30)
		activePill.Position = UDim2.new(((table.find(visible, currentTab) or 1) - 1) / #visible, 6, 0.5, 0)
	end

	function layout.SetTabHidden(name, hidden)
		hidden = hidden and true or nil
		if hiddenTabs[name] == hidden then return end
		hiddenTabs[name] = hidden
		layoutTabs()
		if hidden and currentTab == name then
			selectTab('Combat')
		end
	end
	layoutTabs()

	for name, button in tabButtons do
		button.MouseButton1Click:Connect(function()
			selectTab(name)
		end)
	end

	--[[ Two columns when they fit, one on a narrow screen. The window is in GUI units, which the
	UIScale shrinks with the screen. With Auto rescale on, the window also gets a zoom of its own:
	the rescale that keeps the HUD in proportion would leave the menu under half a phone wide with
	7px text. It is sized to the screen instead, up to 0.85, and never below the HUD's scale. The
	manual Scale slider is left exactly as set. ]]
	local zoom = ui.new('UIScale', {Scale = 1}, window)
	local function resize()
		if not window.Parent then return end
		local s = math.max(scale.Scale, 0.05)
		local camera = gameCamera or workspace.CurrentCamera
		local pxWidth = viewportWidth()
		local pxHeight = camera and camera.ViewportSize.Y or 0
		local avail = pxWidth - 16
		local width, factor = math.floor(math.min(876, math.max(pxWidth / s - 16, 320))), 1
		if vape.Scale and vape.Scale.Enabled and pxHeight > 0 and avail > 0 then
			local target = avail / 876 < 0.55 and theme.CardWidth + 8 or 876
			if target * s <= avail then
				width = target
				factor = math.max(s, math.min(avail / width, 0.85)) / s
			end
		end
		layout.Zoom = factor
		zoom.Scale = factor
		--[[ The ScreenGui ignores the inset, so on a phone the window would start inside the top
		bar, under Roblox's buttons and the Pistonware button. Desktop keeps its 12. ]]
		local top, bottom = 12, 12
		if isMobile() then
			local ok, inset, insetBottom = pcall(function()
				return guiService:GetGuiInset()
			end)
			if ok and typeof(inset) == 'Vector2' then
				top = math.max(12, (inset.Y + 6) / s)
			end
			-- The key footer runs along the window's foot: kept clear of a phone's rounded corners and
			-- home indicator.
			local edge = (ok and typeof(insetBottom) == 'Vector2' and insetBottom.Y or 0) + 16
			bottom = math.max(12, edge / s)
		end
		-- The confirm dialog and the colour picker open level with the window.
		layout.Top = top
		window.Position = UDim2.new(0.5, 0, 0, top)
		if factor ~= 1 or top ~= 12 or bottom ~= 12 then
			window.Size = UDim2.new(0, width, 0, math.floor((pxHeight / s - top - bottom) / factor))
		else
			window.Size = UDim2.new(0, width, 1, -24)
		end
		-- Seven tabs have to share a single-column bar.
		local tabSize = math.clamp(math.floor((width / #visibleTabs() - 6) / 4.6), 10, 16)
		for _, button in tabButtons do
			button.TextSize = tabSize
		end
		local columns = width >= 700 and 2 or 1
		if columns ~= layout.Columns then
			layout.Columns = columns
			layout.request('*')
		end
		local profiles = vape.Categories.Profiles
		if profiles and profiles.Grid then
			profiles.Grid.CellSize = columns == 2 and UDim2.new(0.5, -theme.Gap / 2, 0, 72) or UDim2.new(1, 0, 0, 72)
		end
	end
	component.Resize = resize

	-- The menu's own cards: GUI settings and notification settings, in the Visual tab.
	local function staticCard(name, tooltip)
		local view = ui.card({Name = name..'Card', Display = name, Tooltip = tooltip, ChildrenName = name..'Settings'})
		local expanded = false
		local function toggle()
			expanded = not expanded
			view:SetExpanded(expanded)
		end
		view.Header.MouseButton1Click:Connect(toggle)
		view.Header.MouseButton2Click:Connect(toggle)
		view.Expand.MouseButton1Click:Connect(toggle)
		view.Expand.MouseButton2Click:Connect(toggle)
		layout.add({
			Card = view.Card,
			Tab = 'Visual',
			Name = name,
			Key = name:lower(),
			Search = {name:lower(), 'settings'}
		})
		return view
	end
	component.GUICard = staticCard('GUI', 'Graphical interface for the cheat.')
	component.NotificationsCard = staticCard('Notifications', 'Informs you when certain actions are performed.')
	settingsHosts.Default = component.GUICard.Body
	settingsHosts.Notifications = component.NotificationsCard.Body
	ui.text(component.GUICard.Body, {Text = 'Pistonware '..vape.Version, Size = 12, Color = theme.Muted, AlignX = Enum.TextXAlignment.Right, Props = {
		LayoutOrder = 100000, Name = 'Version', Size = UDim2.new(1, -theme.Inset * 2, 0, 22)
	}})

	local settingspane = components.SettingsPane({
		Name = 'Settings',
		Main = true
	}, hiddenChildren, component)
	component.Settings = settingspane

	function component:Color(hue, sat, val, isRainbow) end

	function component:Load(data)
		for name, paneData in type(data.Settings) == 'table' and data.Settings or {} do
			local pane = vape.Settings[name]
			if pane then
				pane:Load(paneData)
			end
		end

		if data.Position then
			legacy.Position = UDim2.fromOffset(data.Position.X, data.Position.Y)
		end

		--[[ The accent moved to orange with this menu. A theme saved before it moves once, on the
		first load that finds no ThemeVersion -- and only if it is still the old default (the teal
		preset). A custom colour, a rainbow or any other preset was somebody's choice and stays. ]]
		local theme = vape.GUIColor
		if (tonumber(data.ThemeVersion) or 1) < 2 and theme and theme.SetValue
			and not theme.Rainbow and not theme.CustomColor and theme.Notch == 4 then
			theme:SetValue(nil, nil, nil, 2)
		end
	end

	function component:Save(data)
		data.Main = {
			Position = {
				X = legacy.Position.X.Offset,
				Y = legacy.Position.Y.Offset
			},
			Settings = {},
			ThemeVersion = 2
		}

		for name, pane in vape.Settings do
			pane:Save(data.Main.Settings)
		end
	end

	bindComponents(component, hiddenChildren)

	vape.Categories.Main = component
	selectTab('Combat')
	resize()

	return component
end

components.GUIButton = function(props, children, api)
	--[[ What is left of a category's button in the old window list: an on/off flag the save
	file has always recorded per category. Nothing is drawn. ]]
	local component = {
		Enabled = false,
		Index = getTableSize(api.Buttons),
		Name = props.Name
	}
	component.Object = ui.new('Frame', {Name = props.Name, BackgroundTransparency = 1, Visible = false})

	function component:Destroy()
		component.Object:Destroy()
	end

	function component:Toggle()
		if props.Window then
			self.Enabled = not self.Enabled
		elseif props.Function then
			props.Function()
		end
	end

	api.Buttons[props.Name] = component

	return component
end

components.GUISlider = function(props, children, api)
	local colors = {
		Color3.fromRGB(250, 50, 56),
		Color3.fromRGB(243, 93, 18),
		Color3.fromRGB(252, 179, 22),
		Color3.fromRGB(5, 133, 104),
		Color3.fromRGB(47, 122, 229),
		Color3.fromRGB(126, 84, 217),
		Color3.fromRGB(232, 96, 152)
	}
	local defaultHue, defaultSat, defaultValue = colors[2]:ToHSV()
	local component = {
		CustomColor = false,
		Hue = defaultHue,
		Notch = 2,
		Rainbow = false,
		Sat = defaultSat,
		Type = 'GUISlider',
		Value = defaultValue
	}

	local slider = ui.new('Frame', {
		Name = props.Name..'Slider',
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0)
	}, children)
	component.Object = slider
	ui.list(slider, 0)
	local line = ui.row(slider, {LayoutOrder = 1})
	ui.rowLabel(line, {Name = 'Accent color'}, 60)
	local swatch = ui.new('TextButton', {
		Name = 'Swatch',
		AnchorPoint = Vector2.new(1, 0.5),
		AutoButtonColor = false,
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		Position = UDim2.new(1, -theme.Inset, 0.5, 0),
		Size = UDim2.fromOffset(40, 20),
		Text = ''
	}, line)
	ui.corner(swatch, UDim.new(1, 0))
	local swatchGradient = ui.new('UIGradient', {}, swatch)
	addTooltip(line, 'The colour switches, sliders and highlights use')

	local picker = ui.new('Frame', {
		Name = 'Picker',
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = 2,
		Size = UDim2.new(1, 0, 0, 0),
		Visible = false
	}, slider)
	ui.list(picker, 2)
	ui.padding(picker, 0, 0, 2, 6)

	local presets = ui.row(picker, {}, 30)
	local presetList = ui.new('Frame', {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(theme.Inset + 12, 0),
		Size = UDim2.new(1, -(theme.Inset * 2 + 12), 1, 0)
	}, presets)
	ui.list(presetList, 8, true)
	local presetButtons = {}
	for index, colorValue in colors do
		local dot = ui.new('TextButton', {
			AutoButtonColor = false,
			BackgroundColor3 = colorValue,
			BorderSizePixel = 0,
			LayoutOrder = index,
			Size = UDim2.fromOffset(20, 20),
			Text = ''
		}, presetList)
		ui.corner(dot, UDim.new(1, 0))
		local ring = ui.stroke(dot, theme.Text, 2, 0)
		ring.Enabled = false
		presetButtons[index] = {Button = dot, Ring = ring}
		dot.MouseButton1Click:Connect(function()
			component:SetValue(nil, nil, nil, index)
		end)
	end
	local reset = ui.text(presets, {Class = 'TextButton', Text = 'RESET', Size = 12, Weight = 'Bold', Color = theme.SubText, AlignX = Enum.TextXAlignment.Center, Props = {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -theme.Inset, 0.5, 0), Size = UDim2.fromOffset(52, 24)
	}})
	reset.MouseButton1Click:Connect(function()
		component:SetValue(nil, nil, nil, 2)
	end)
	-- COPY puts the accent's hex code on the clipboard, and says so for a moment.
	local copy = ui.text(presets, {Class = 'TextButton', Text = 'COPY', Size = 12, Weight = 'Bold', Color = theme.SubText, AlignX = Enum.TextXAlignment.Center, Props = {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -theme.Inset - 56, 0.5, 0), Size = UDim2.fromOffset(52, 24)
	}})
	local copyStamp = 0
	copy.MouseButton1Click:Connect(function()
		local setter = setclipboard or toclipboard or set_clipboard
		local hex = '#'..Color3.fromHSV(component.Hue, component.Sat, component.Value):ToHex():upper()
		local ok = setter and pcall(setter, hex)
		copyStamp += 1
		local stamp = copyStamp
		copy.Text = ok and 'COPIED' or 'NO CLIPBOARD'
		task.delay(1.2, function()
			if copyStamp == stamp then
				copy.Text = 'COPY'
			end
		end)
	end)

	local function pickerTrack(name, gradientColor, value)
		local row = ui.row(picker, {}, 26)
		ui.text(row, {Text = name, Size = 13, Color = theme.SubText, Props = {
			Position = UDim2.fromOffset(theme.Inset + 12, 0), Size = UDim2.fromOffset(80, 26)
		}})
		local holder = ui.new('Frame', {
			Name = 'Holder',
			AnchorPoint = Vector2.new(1, 0.5),
			BackgroundColor3 = Color3.new(1, 1, 1),
			BorderSizePixel = 0,
			Position = UDim2.new(1, -theme.Inset - 8, 0.5, 0),
			Size = UDim2.new(0.6, -8, 0, 6)
		}, row)
		ui.corner(holder, UDim.new(1, 0))
		local gradient = ui.new('UIGradient', {Color = gradientColor}, holder)
		local knob = ui.new('Frame', {
			Name = 'Knob',
			AnchorPoint = Vector2.new(0.5, 0.5),
			BackgroundColor3 = theme.Text,
			Position = UDim2.fromScale(math.clamp(value, 0, 1), 0.5),
			Size = UDim2.fromOffset(12, 12)
		}, holder)
		ui.corner(knob, UDim.new(1, 0))
		ui.stroke(knob, theme.Knob, 2, 0)
		local hit = ui.new('TextButton', {
			BackgroundTransparency = 1, Position = UDim2.new(0.4, 0, 0, 0), Size = UDim2.new(0.6, 0, 1, 0), Text = ''
		}, row)
		return {Holder = holder, Gradient = gradient, Knob = knob, Hit = hit}
	end

	local rainbowTable = {}
	for i = 0, 1, 0.1 do
		table.insert(rainbowTable, ColorSequenceKeypoint.new(i, Color3.fromHSV(i, 1, 1)))
	end
	local colorSlider = pickerTrack('Custom color', ColorSequence.new(rainbowTable), component.Hue)
	local satSlider = pickerTrack('Saturation', ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromHSV(0, 0, component.Value)),
		ColorSequenceKeypoint.new(1, Color3.fromHSV(component.Hue, 1, component.Value))
	}), component.Sat)
	local vibSlider = pickerTrack('Vibrance', ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromHSV(0, 0, 0)),
		ColorSequenceKeypoint.new(1, Color3.fromHSV(component.Hue, component.Sat, 1))
	}), component.Value)

	local extras = ui.row(picker, {}, 30)
	ui.text(extras, {Text = 'Rainbow', Size = 13, Color = theme.SubText, Props = {
		Position = UDim2.fromOffset(theme.Inset + 12, 0), Size = UDim2.fromOffset(60, 30)
	}})
	local rainbowSwitch = ui.switch(extras, UDim2.new(0, theme.Inset + 12 + 60 + 42, 0.5, 0))
	local rainbowHit = ui.new('TextButton', {
		BackgroundTransparency = 1, Position = UDim2.fromOffset(theme.Inset, 0), Size = UDim2.fromOffset(130, 30), Text = ''
	}, extras)
	local custombox = ui.pill(extras, {Class = 'Frame', Size = UDim2.fromOffset(130, 24)})
	local hexbox = ui.text(custombox, {Class = 'TextBox', Size = 13, Color = theme.Text, AlignX = Enum.TextXAlignment.Center, Props = {
		ClearTextOnFocus = false,
		PlaceholderColor3 = theme.Muted,
		PlaceholderText = 'r, g, b or hex',
		Size = UDim2.fromScale(1, 1)
	}})
	props.Function = props.Function or function() end
	local rainbowthread

	local function paint()
		local base = Color3.fromHSV(component.Hue, component.Sat, component.Value)
		swatchGradient.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, base),
			ColorSequenceKeypoint.new(1, Color3.fromHSV(component.Hue, component.Sat, component.Value * 0.35))
		})
		for index, preset in presetButtons do
			preset.Ring.Enabled = not component.Rainbow and not component.CustomColor and component.Notch == index
		end
		if picker.Visible then
			colorSlider.Knob.Position = UDim2.fromScale(math.clamp(component.Hue, 0, 1), 0.5)
			satSlider.Knob.Position = UDim2.fromScale(math.clamp(component.Sat, 0, 1), 0.5)
			vibSlider.Knob.Position = UDim2.fromScale(math.clamp(component.Value, 0, 1), 0.5)
		end
	end

	function component:Load(data)
		if (self.Rainbow and true or false) ~= (data.Rainbow and true or false) then
			self:Toggle()
		end

		if self.Rainbow or data.CustomColor then
			self:SetValue(data.Hue, data.Sat, data.Value)
		else
			self:SetValue(nil, nil, nil, data.Notch)
		end
	end

	function component:Save(data)
		data[props.Name] = {
			Hue = self.Hue,
			Sat = self.Sat,
			Value = self.Value,
			Notch = self.Notch,
			CustomColor = self.CustomColor,
			Rainbow = self.Rainbow
		}
	end

	function component:SetValue(h, s, v, n)
		if n and not colors[n] then
			n = 2
		end
		if n then
			if self.Rainbow then
				self:Toggle()
			end

			self.CustomColor = false
			h, s, v = colors[n]:ToHSV()
		else
			self.CustomColor = true
		end

		self.Hue = h or self.Hue
		self.Sat = s or self.Sat
		self.Value = v or self.Value
		self.Notch = n

		satSlider.Gradient.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromHSV(0, 0, self.Value)),
			ColorSequenceKeypoint.new(1, Color3.fromHSV(self.Hue, 1, self.Value))
		})

		vibSlider.Gradient.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromHSV(0, 0, 0)),
			ColorSequenceKeypoint.new(1, Color3.fromHSV(self.Hue, self.Sat, 1))
		})
		paint()

		props.Function(self.Hue, self.Sat, self.Value)
		-- see the ColorSlider: not while the rainbow loop is driving it
		if not self.Rainbow then
			vape:RequestSave()
		end
	end

	function component:Toggle()
		self.Rainbow = not self.Rainbow
		if rainbowthread then
			task.cancel(rainbowthread)
			rainbowthread = nil
		end

		if self.Rainbow then
			addRainbowSlider(self)
		else
			self:SetValue(nil, nil, nil, 2)
			removeRainbowSlider(self)
		end
		rainbowSwitch:Set(self.Rainbow)
		paint()
		vape:RequestSave()
	end

	function component:Color(hue, sat, val, isRainbow)
		if self.Rainbow then
			rainbowSwitch:Color(accentFor(0, 0, hue, sat, val, isRainbow))
		end
	end

	swatch.MouseButton1Click:Connect(function()
		picker.Visible = not picker.Visible
		paint()
	end)

	for track, name in {[colorSlider] = 'Custom color', [satSlider] = 'Saturation', [vibSlider] = 'Vibrance'} do
		track.Hit.InputBegan:Connect(function(input)
			if not isPress(input) then return end
			trackDrag(input, track.Holder, function(value)
				component:SetValue(
					name == 'Custom color' and value or nil,
					name == 'Saturation' and value or nil,
					name == 'Vibrance' and value or nil
				)
			end)
		end)
	end

	rainbowHit.MouseButton1Click:Connect(function()
		component:Toggle()
	end)

	hexbox.FocusLost:Connect(function(enter)
		if enter then
			local success, parsed = pcall(function()
				local commas = hexbox.Text:split(',')
				return tonumber(commas[1]) and Color3.fromRGB(tonumber(commas[1]), tonumber(commas[2]), tonumber(commas[3])) or Color3.fromHex(hexbox.Text)
			end)

			if success then
				if component.Rainbow then
					component:Toggle()
				end

				component:SetValue(parsed:ToHSV())
			end
		end
		hexbox.Text = ''
	end)

	paint()
	api.Options[props.Name] = component

	return component
end

components.ImageToggle = function(props, children, api)
	--[[ An overlay's on/off: the switch on its card. ]]
	local component = {
		Enabled = false,
		Index = getTableSize(api.Options),
		Type = 'ImageToggle'
	}

	local switch = ui.switch(props.SwitchParent or children, props.SwitchParent and UDim2.new(1, -theme.Inset, 0, 24) or nil)
	component.Object = switch.Object
	props.Function = props.Function or function() end

	function component:Color(hue, sat, val, isRainbow)
		if self.Enabled then
			switch:Color(accentFor(self.Index, 0.075, hue, sat, val, isRainbow))
		end
	end

	function component:Toggle()
		self.Enabled = not self.Enabled
		switch:Set(self.Enabled, liveAccent(self.Index))
		props.Function(self.Enabled)
		vape:RequestSave()
	end

	if props.Default then
		component:Toggle()
	end

	api.Options[props.Name] = component

	return component
end

components.LegitModule = function(props, children, api)
	vape:Remove(props.Name)
	local component = {
		Enabled = false,
		Legit = true,
		Name = props.Name,
		Options = {},
		Type = 'LegitModule'
	}
	component.Tab = layout.tabOf(props, 'Legit')
	component.DisplayName = props.DisplayName or ui.prettify(props.Name)

	local view = ui.card({
		Name = props.Name,
		Display = component.DisplayName,
		Tooltip = props.Tooltip,
		Switch = true,
		ChildrenName = props.Name..'Settings'
	})
	component.Options = view:WatchOptions(component.Options)
	component.Object = view.Card
	local settingschildren = view.Body
	local expanded = false

	if props.Size then
		--[[ The on-screen widget. Shown whenever the module is on, and dragged into place while
		the menu is open, when it wears an outline so it can be found. ]]
		local modulechildren = ui.new('Frame', {
			Name = props.Name..'Widget',
			BackgroundTransparency = 1,
			Size = props.Size,
			Visible = false,
			ZIndex = 2
		}, scaledgui)
		-- Below Roblox's top bar and a step down from the widget before it, zoomed on a phone.
		component.HudSlot = ui.hudSlot('Widget')
		modulechildren.Position = ui.hudPlace('Widget', component.HudSlot)
		ui.hudScale(modulechildren)
		addDragHandler(modulechildren, clickgui)
		local objectstroke = Instance.new('UIStroke')
		objectstroke.Color = theme.Accent()
		objectstroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		objectstroke.Thickness = 1
		objectstroke.Transparency = 0.3
		objectstroke.Enabled = false
		objectstroke.Parent = modulechildren
		component.Children = modulechildren
		vape:Clean(clickgui:GetPropertyChangedSignal('Visible'):Connect(function()
			objectstroke.Enabled = clickgui.Visible
			objectstroke.Color = theme.Accent()
		end))
	end
	props.Function = props.Function or function() end
	addMaid(component)

	function component:Color(hue, sat, val, isRainbow)
		if self.Enabled then
			view.Switch:Color(Color3.fromHSV(hue, sat, val))
		end

		for _, option in self.Options do
			if option.Color then
				option:Color(hue, sat, val, isRainbow)
			end
		end
	end

	function component:Load(data)
		vape:LoadOptions(self, data.Options)

		if self.Enabled ~= data.Enabled then
			self:Toggle()
		end

		if data.Position and self.Children then
			self.Children.Position = UDim2.fromOffset(data.Position.X, data.Position.Y)
			ui.clampHud(self.Children, self.Children.Size.X.Offset, self.Children.Size.Y.Offset)
		end
	end

	function component:Save(data)
		data[props.Name] = {
			Enabled = self.Enabled,
			Options = vape:SaveOptions(self),
			Position = self.Children and {
				X = self.Children.Position.X.Offset,
				Y = self.Children.Position.Y.Offset
			} or nil
		}
	end

	function component:Toggle()
		self.Enabled = not self.Enabled
		if self.Children then
			self.Children.Visible = self.Enabled
		end
		view.Switch:Set(self.Enabled)

		if not self.Enabled then
			for _, v in self.Connections do
				cleanupConnection(v)
			end
			table.clear(self.Connections)
		end

		vape:RequestSave()
		-- Deferred while applying, for the reason set out at the module toggle.
		if vape.Applying and self.Enabled then
			-- As at the module toggle: only the newest queued start runs, and only while still on.
			local token = {}
			self.StartToken = token
			queueStart(props.Name, function()
				if self.Enabled and self.StartToken == token then
					props.Function(true)
				end
			end)
		else
			self.StartToken = nil
			task.spawn(props.Function, self.Enabled)
		end
	end

	function component:Destroy()
		layout.remove(view.Card)
	end

	bindComponents(component, settingschildren)

	local function toggleExpand()
		expanded = not expanded
		view:SetExpanded(expanded)
	end
	view.Header.MouseButton1Click:Connect(function()
		component:Toggle()
	end)
	view.Header.MouseButton2Click:Connect(toggleExpand)
	view.Expand.MouseButton1Click:Connect(toggleExpand)
	-- The expander takes the whole description line, so a right-click there lands on it.
	view.Expand.MouseButton2Click:Connect(toggleExpand)

	api.Modules[props.Name] = component
	-- Same reasoning as vape.ModuleOrder: vape:Save walks the array, never the hash.
	api.Order = api.Order or {}
	table.insert(api.Order, component)

	layout.add({
		Card = view.Card,
		Tab = component.Tab,
		Name = props.Name,
		-- Slinky orders cards ignoring case and spaces (Hitboxes before Hit Select).
		Key = ((props.SortKey or component.DisplayName):lower():gsub('%s', '')),
		Search = {props.Name:lower(), component.DisplayName:lower()},
		-- 'Show legit mode' in the GUI card takes these out of the tabs and the search.
		Visible = function()
			return layout.ShowLegit ~= false
		end
	})

	return component
end

components.LegitWindow = function(props, children, api)
	--[[ The legit modules are cards in the tabs now; this is only their registry. ]]
	local component = {
		Modules = {},
		-- The array half of Modules, for the same reason as vape.ModuleOrder.
		Order = {}
	}

	local window = ui.new('Frame', {
		BackgroundTransparency = 1,
		Name = 'LegitGUI',
		Size = UDim2.fromOffset(0, 0),
		Visible = false
	}, scaledgui)
	table.insert(vape.Windows, window)
	component.Window = window

	bindComponents(component, window)

	function component:CreateModule(props)
		if layout then
			layout.ColorDirty = true
		end
		return components.LegitModule(props, window, component)
	end

	local function visibleCheck()
		for _, module in orderedModules(component.Order) do
			if module.Children then
				module.Children.Visible = module.Enabled
			end
		end
	end

	vape:Clean(clickgui:GetPropertyChangedSignal('Visible'):Connect(visibleCheck))

	vape.Legit = component

	return component
end

components.Module = function(props, children, api)
	vape:Remove(props.Name)
	local component = {
		Category = api.Name,
		Enabled = false,
		ExtraText = props.ExtraText,
		-- ModuleCount, not a walk of vape.Modules: this runs once per registration.
		Index = vape.ModuleCount,
		Name = props.Name,
		Options = {},
		Type = 'Module',
		Visible = true
	}
	component.Tab = layout.tabOf(props, api.Name)
	component.DisplayName = props.DisplayName or ui.prettify(props.Name)

	local view = ui.card({
		Name = props.Name,
		Display = component.DisplayName,
		Tooltip = props.Tooltip,
		Switch = true
	})
	component.Options = view:WatchOptions(component.Options)
	local card = view.Card
	component.Object = card
	component.BindParent = view.NameRow
	-- Resting on the module's name shows its help centred over the whole card, just above it.
	addRowTooltip(view.Header, props.Tooltip, view.Header, view.Title)
	local modulechildren = view.Body
	component.Children = modulechildren
	local expanded = false

	-- Shown while hidden modules are being edited: the eye that hides or shows this card.
	local edit = ui.icon(view.NameRow, 'eye', 15, {Class = 'TextButton', Color = theme.SubText, Props = {
		Name = 'Edit', LayoutOrder = 3, Size = UDim2.fromOffset(22, 22), Visible = false
	}})
	component.Edit = edit
	props.Function = props.Function or function() end
	addMaid(component)

	function component:Color(hue, sat, val, isRainbow)
		if self.Enabled then
			view.Switch:Color(accentFor(self.Index, 0.025, hue, sat, val, isRainbow))
		end

		for _, option in self.Options do
			if option.Color then
				option:Color(hue, sat, val, isRainbow)
			end
		end
	end

	function component:Destroy()
		self.Bind:Destroy()

		for _, option in self.Options do
			if option.Type == 'Bind' then
				option:Destroy()
			end
		end
		layout.remove(card)
	end

	function component:Load(data)
		vape:LoadOptions(self, data.Options)
		self.Bind:Load(data.Bind)

		if self.Enabled ~= (data.Enabled and not self.Bind.Hold) then
			self:Toggle(true)
		end

		if self.Visible ~= data.Visible then
			self:SetVisible(data.Visible, true)
		end
	end

	function component:Save(data)
		data[props.Name] = {
			Enabled = self.Enabled,
			Options = vape:SaveOptions(self),
			Visible = self.Visible
		}

		self.Bind:Save(data[props.Name])
	end

	function component:SetVisible(isVisible, isLoad)
		self.Visible = isVisible
		ui.setIcon(edit, isVisible == false and 'eye-off' or 'eye')
		card.BackgroundTransparency = isVisible == false and 0.45 or 0
		layout.request(self.Tab)
		if not isLoad then
			vape:RequestSave()
		end
	end

	function component:Toggle(multiple, quiet, fromBind)
		if vape.ThreadFix then
			setthreadidentity(8)
		end

		self.Enabled = not self.Enabled
		-- Read once: the module's function gets the state this toggle set, even if another
		-- toggle lands before it starts.
		local enabled = self.Enabled
		view.Switch:Set(self.Enabled, liveAccent(self.Index, 0.025))
		-- A placed on-screen button shows the state whatever switched the module: its card, a key, another module.
		if self.Bind and self.Bind.Mobile then
			self.Bind.Mobile.BackgroundColor3 = self.Enabled and theme.Accent() or theme.Bar
		end

		--[[ 'Enabled Reach' / 'Disabled Reach' when a module is switched by its own key (or its on-screen
		button on a phone), as the old GUI did. Every other way a module changes -- its card, another
		module, a restart after a setting changed -- stays quiet: those alerts built and restacked a
		notification on every programmatic toggle. Never while a profile is loading or unloading. ]]
		if fromBind and not quiet and vape.Loaded and not vape.Applying and vape.ToggleNotifications and vape.ToggleNotifications.Enabled then
			vape:CreateNotification('Pistonware', (self.Enabled and 'Enabled ' or 'Disabled ')..(self.DisplayName or props.Name), 2)
		end

		if not self.Enabled then
			for _, v in self.Connections do
				cleanupConnection(v)
			end
			table.clear(self.Connections)
		end

		-- A request: the list redraws once at the end of the frame, however many modules changed.
		if vape.Loaded ~= nil then
			vape:UpdateTextGUI()
		end

		vape:RequestSave()
		-- Deferred while applying, for the reason set out at the other module toggle: with
		-- task.spawn the module's setup runs inline inside the apply loop.
		if vape.Applying and enabled then
			-- Only the newest queued start runs, and only if the module is still on when it does.
			local token = {}
			self.StartToken = token
			queueStart(props.Name, function()
				if self.Enabled and self.StartToken == token then
					props.Function(true)
				end
			end)
		else
			self.StartToken = nil
			task.spawn(props.Function, enabled)
		end
	end

	bindComponents(component, modulechildren)

	local function toggleExpand()
		expanded = not expanded
		view:SetExpanded(expanded)
	end

	view.Header.MouseButton1Click:Connect(function()
		if vape.EditGUI then
			component:SetVisible(not component.Visible)
			return
		end

		component:Toggle()
	end)
	view.Header.MouseButton2Click:Connect(toggleExpand)
	view.Expand.MouseButton1Click:Connect(toggleExpand)
	-- The expander takes the whole description line, so a right-click there lands on it.
	view.Expand.MouseButton2Click:Connect(toggleExpand)
	edit.MouseButton1Click:Connect(function()
		component:SetVisible(not component.Visible)
	end)

	local bind = component:CreateBind({
		Module = true,
		Cover = true
	})

	-- The module's own key (or its on-screen button): the one toggle that reports itself.
	bind.Triggered:Connect(function(isDown)
		if bind.Hold then
			if component.Enabled ~= isDown then
				component:Toggle(true, nil, true)
			end
		else
			component:Toggle(true, nil, true)
		end
	end)

	if inputService.TouchEnabled then
		local isHeld = false

		--[[ The expander covers the description line and takes the press there, so it starts the
		same hold as the title row. A finished hold hides the menu, so its release never expands. ]]
		local function startHold()
			isHeld = true
			local holdtime, holdPos = os.clock(), inputService:GetMouseLocation()
			repeat
				isHeld = (inputService:GetMouseLocation() - holdPos).Magnitude < 3
				task.wait()
			until (os.clock() - holdtime) > 1 or not isHeld or not clickgui.Visible

			if isHeld and clickgui.Visible then
				if vape.ThreadFix then
					setthreadidentity(8)
				end

				clickgui.Visible = false
				tooltip.Visible = false
				vape:BlurCheck()
				for _, module in orderedModules(vape.ModuleOrder) do
					if module.Bind.Mobile then
						module.Bind.Mobile.Visible = true
					end
				end

				local connection
				connection = inputService.InputBegan:Connect(function(input)
					if input.UserInputType == Enum.UserInputType.Touch then
						if vape.ThreadFix then
							setthreadidentity(8)
						end

						bind:CreateMobileButton(input.Position + Vector3.new(0, guiService:GetGuiInset().Y, 0))
						vape:RequestSave()
						clickgui.Visible = true
						vape:BlurCheck()

						for _, module in orderedModules(vape.ModuleOrder) do
							if module.Bind.Mobile then
								module.Bind.Mobile.Visible = false
							end
						end

						connection:Disconnect()
					end
				end)
			end
		end

		local function endHold()
			isHeld = false
		end

		view.Header.MouseButton1Down:Connect(startHold)
		view.Expand.MouseButton1Down:Connect(startHold)
		view.Header.MouseButton1Up:Connect(endHold)
		view.Expand.MouseButton1Up:Connect(endHold)
	end

	vape.Modules[props.Name] = component
	vape.ModuleCount += 1
	table.insert(vape.ModuleOrder, component)
	vape:SortCategories()

	layout.add({
		Card = card,
		Tab = component.Tab,
		Name = props.Name,
		-- Slinky orders cards ignoring case and spaces (Hitboxes before Hit Select).
		Key = ((props.SortKey or component.DisplayName):lower():gsub('%s', '')),
		Search = {props.Name:lower(), component.DisplayName:lower()},
		Visible = function()
			return component.Visible ~= false or vape.EditGUI == true
		end
	})

	return component
end

--[[ Drags `target` by a press on `handle`, while `enabled()` allows it -- addDragHandler's own sum,
for a handle that is not the thing it moves. ]]
function ui.dragBy(handle, target, enabled)
	return handle.InputBegan:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then return end
		if enabled and not enabled() then return end
		local dragPosition = Vector2.new(
			target.AbsolutePosition.X - input.Position.X,
			target.AbsolutePosition.Y - input.Position.Y + guiService:GetGuiInset().Y
		) / scale.Scale
		local isMouse = input.UserInputType == Enum.UserInputType.MouseButton1
		local releaseConnection
		local moveConnection = inputService.InputChanged:Connect(function(newInput)
			-- Only the press that started the drag, never a second finger on the thumbstick.
			if newInput == input or (isMouse and newInput.UserInputType == Enum.UserInputType.MouseMovement) then
				local position = newInput.Position
				if inputService:IsKeyDown(Enum.KeyCode.LeftShift) then
					dragPosition = (dragPosition // 3) * 3
					position = (position // 3) * 3
				end
				target.Position = UDim2.fromOffset((position.X / scale.Scale) + dragPosition.X, (position.Y / scale.Scale) + dragPosition.Y)
			end
		end)
		releaseConnection = input.Changed:Connect(function()
			if input.UserInputState == Enum.UserInputState.End or input.UserInputState == Enum.UserInputState.Cancel then
				moveConnection:Disconnect()
				releaseConnection:Disconnect()
				-- Where it was dropped is saved; nothing else asks for a save after a drag.
				vape:RequestSave()
			end
		end)
	end)
end

components.Overlay = function(props, children, api)
	local display = props.DisplayName or (props.Name == 'Text GUI' and 'Mod Overlay' or props.Name)
	local view = ui.card({
		Name = props.Name..'Card',
		Display = display,
		Tooltip = props.Tooltip or (props.Name == 'Text GUI' and 'Displays a list of all active mods.' or 'An overlay on your screen.')
	})
	local window
	local component
	component = {
		Button = vape.Overlays:CreateImageToggle({
			Name = props.Name,
			SwitchParent = view.Header,
			Function = function(callback)
				window.Visible = callback and (clickgui.Visible or component.Pinned)

				if not callback then
					for _, v in component.Connections do
						cleanupConnection(v)
					end
					table.clear(component.Connections)
				end

				if props.Function then
					task.spawn(props.Function, callback)
				end
			end
		}),
		Expanded = false,
		Pinned = false,
		Options = {},
		Type = 'Overlay'
	}

	--[[ The overlay on screen: a slim handle to drag it by while the menu is open, its content under
	that. A fixed overlay (the Mod Overlay, as Slinky draws it) has neither: it stays in the
	top-right corner, on screen whether or not the menu is open. ]]
	local fixed = props.Fixed == true
	component.Pinned = fixed
	component.Fixed = fixed
	-- A moveable overlay starts below Roblox's top bar, a step on from the overlay before it.
	component.HudSlot = not fixed and ui.hudSlot('Overlay') or nil
	window = ui.new('TextButton', {
		AnchorPoint = fixed and Vector2.new(1, 0) or Vector2.zero,
		AutoButtonColor = false,
		BackgroundColor3 = Color3.fromRGB(38, 38, 38),
		BackgroundTransparency = fixed and 1 or 0,
		BorderSizePixel = 0,
		Name = props.Name..'Overlay',
		Position = fixed and UDim2.fromScale(1, 0) or ui.hudPlace('Overlay', component.HudSlot),
		Size = UDim2.fromOffset(props.CategorySize or 220, fixed and 0 or 32),
		Text = '',
		Visible = false,
		ZIndex = 2
	}, scaledgui)
	component.Object = window
	-- The phone zoom, handle and content together. The Mod Overlay folds it into its own Text size.
	if not fixed then
		ui.hudScale(window)
	end
	ui.corner(window, 10)
	--[[ The handle it is dragged by while the menu is open is the loader's titlebar: its grey bar and
	border, the >_ badge in its orange, the name in its console face, and the pin as one of its
	window controls, grey until pinned. ]]
	local CONSOLE_FONT = Font.fromEnum(Enum.Font.Code)
	local LOADER_ORANGE, LOADER_GLYPH = Color3.fromRGB(240, 122, 31), Color3.fromRGB(190, 190, 190)
	local stroke = ui.stroke(window, Color3.fromRGB(52, 52, 52), 1, 0)
	stroke.Enabled = not fixed
	if not fixed then
		addDragHandler(window)
	end
	local badge = ui.new('TextLabel', {
		BackgroundColor3 = Color3.fromRGB(22, 22, 22),
		BorderSizePixel = 0,
		FontFace = CONSOLE_FONT,
		Position = UDim2.fromOffset(7, 6),
		Size = UDim2.fromOffset(24, 20),
		Text = '>_',
		TextColor3 = LOADER_ORANGE,
		TextSize = 12,
		Visible = not fixed
	}, window)
	ui.corner(badge, 5)
	local title = ui.new('TextLabel', {
		BackgroundTransparency = 1,
		FontFace = CONSOLE_FONT,
		Position = UDim2.fromOffset(39, 0),
		Size = UDim2.new(1, -72, 0, 32),
		Text = display,
		TextColor3 = Color3.fromRGB(232, 232, 232),
		TextSize = 14,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextXAlignment = Enum.TextXAlignment.Left,
		Visible = not fixed
	}, window)
	local pin = ui.icon(window, 'pin', 14, {Class = 'TextButton', Color = LOADER_GLYPH, Props = {
		AnchorPoint = Vector2.new(1, 0.5), Name = 'Pin', Position = UDim2.new(1, -8, 0, 16), Visible = not fixed
	}})
	addTooltip(pin, 'Pin: keep it on screen with the menu closed')
	local customchildren = ui.new('Frame', {
		BackgroundTransparency = 1,
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, 200)
	}, window)
	-- With the menu open, the overlay's own content (Target Info's card, say) drags it as well as the bar.
	if not fixed then
		customchildren.ChildAdded:Connect(function(child)
			if child:IsA('GuiObject') then
				ui.dragBy(child, window, function()
					return clickgui.Visible
				end)
			end
		end)
	end
	addMaid(component)

	function component:Color(hue, sat, val, isRainbow)
		for _, option in self.Options do
			if option.Color then
				option:Color(hue, sat, val, isRainbow)
			end
		end
	end

	function component:Expand(visCheck)
		if visCheck and not clickgui.Visible then return end

		self.Expanded = not self.Expanded
		view:SetExpanded(self.Expanded)
	end

	function component:Load(data)
		vape:LoadOptions(self, data.Options)

		if self.Button.Enabled ~= (data.Enabled and true or false) then
			self.Button:Toggle()
		end

		if not fixed and (self.Pinned and true or false) ~= (data.Pinned and true or false) then
			self:Pin()
			self:Update()
		end

		if data.Position and not fixed then
			window.Position = UDim2.fromOffset(data.Position.X, data.Position.Y)
			ui.clampHud(window, window.Size.X.Offset, 32)
		end

		if self.Bind and type(data.Bind) == 'table' then
			self.Bind:Load(data.Bind)
		end
	end

	function component:Pin()
		if fixed then return end
		self.Pinned = not self.Pinned
		pin.TextColor3 = self.Pinned and LOADER_ORANGE or LOADER_GLYPH
		vape:RequestSave()
	end

	function component:Save(data)
		data[props.Name] = {
			Enabled = self.Button.Enabled,
			Options = vape:SaveOptions(self),
			Pinned = self.Pinned,
			Position = {
				X = window.Position.X.Offset,
				Y = window.Position.Y.Offset
			}
		}
		if self.Bind then
			self.Bind:Save(data[props.Name])
		end
	end

	function component:Update()
		window.Visible = self.Button.Enabled and (clickgui.Visible or self.Pinned)
		if fixed then return end

		if clickgui.Visible then
			window.Size = UDim2.fromOffset(window.Size.X.Offset, 32)
			window.BackgroundTransparency = 0
			stroke.Enabled = true
			badge.Visible = true
			title.Visible = true
			pin.Visible = true
		else
			window.Size = UDim2.fromOffset(window.Size.X.Offset, 0)
			window.BackgroundTransparency = 1
			stroke.Enabled = false
			badge.Visible = false
			title.Visible = false
			pin.Visible = false
		end
	end

	function component:Destroy()
		layout.remove(view.Card)
		view.Card:Destroy()
	end

	bindComponents(component, view.Body)

	-- A bind badge, as on every module card; the key toggles the overlay.
	component.BindParent = view.NameRow
	local bind = component:CreateBind({
		Module = true,
		Cover = true
	})
	bind.Triggered:Connect(function(isDown)
		if bind.Hold then
			if component.Button.Enabled ~= isDown then
				component.Button:Toggle()
			end
		else
			component.Button:Toggle()
		end
	end)

	vape:Clean(clickgui:GetPropertyChangedSignal('Visible'):Connect(function()
		component:Update()
	end))

	view.Header.MouseButton1Click:Connect(function()
		component.Button:Toggle()
	end)
	view.Header.MouseButton2Click:Connect(function()
		component:Expand()
	end)
	view.Expand.MouseButton1Click:Connect(function()
		component:Expand()
	end)
	view.Expand.MouseButton2Click:Connect(function()
		component:Expand()
	end)
	pin.MouseButton1Click:Connect(function()
		component:Pin()
	end)
	window.MouseButton2Click:Connect(function()
		component:Expand(true)
	end)

	component.Children = customchildren
	vape.Categories[props.Name] = component

	layout.add({
		Card = view.Card,
		Tab = layout.tabOf(props, 'Overlay'),
		Name = props.Name,
		Key = (display:lower():gsub('%s', '')),
		Search = {props.Name:lower(), display:lower()}
	})

	return component
end

components.OverlayBar = function(props, children, api)
	--[[ The registry the overlay switches are kept in; UpdateGUI recolours through it. ]]
	local component = {
		Options = {},
		Type = 'OverlayBar'
	}

	local holder = ui.new('Frame', {
		Name = 'Overlays',
		BackgroundColor3 = theme.Card,
		BackgroundTransparency = 1,
		Visible = false
	}, layout.Hidden)
	bindComponents(component, holder)

	vape.Overlays = component

	return component
end

components.SearchBar = function(props, children, api)
	--[[ The menu has no search any more. 'Search bar style' still saves and loads, and still
	writes .Object.Visible, so it gets an object that is never shown. ]]
	return {
		Type = 'SearchBar',
		Object = ui.new('Frame', {Name = 'NoSearch', Visible = false})
	}
end

components.SettingsPane = function(props, children, api)
	local component = {
		Buttons = {},
		Options = {},
		Parent = api.Parent or children,
		Type = 'SettingsPane'
	}

	local host = settingsHosts[PANE_HOSTS[props.Name] or 'Default'] or settingsHosts.Default or children
	local section = ui.new('Frame', {
		Name = props.Name,
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = theme.Card,
		BackgroundTransparency = 1,
		LayoutOrder = PANE_ORDER[props.Name] or 99,
		Size = UDim2.new(1, 0, 0, 0)
	}, host)
	ui.list(section, 0, false, Enum.HorizontalAlignment.Center)
	local title = PANE_TITLES[props.Name]
	if title == nil then title = props.Name end
	if title then
		local header = ui.row(section, {LayoutOrder = -1000}, 27)
		ui.text(header, {Text = title, Size = 15, Color = theme.Header, Props = {
			Position = UDim2.fromOffset(theme.Inset, 9), Size = UDim2.new(1, -theme.Inset * 2, 0, 21)
		}})
	end

	function component:Load(data)
		vape:LoadOptions(self, data)
	end

	function component:Save(data)
		data[props.Name] = vape:SaveOptions(self)
	end

	bindComponents(component, section)

	component.Object = section
	vape.Settings[props.Name] = component

	return component
end

local function sliderText(value, suffix)
	return tostring(value)..(suffix and ' '..(type(suffix) == 'function' and suffix(value) or suffix) or '')
end

components.Slider = function(props, children, api)
	local component = {
		Index = getTableSize(api.Options),
		Max = props.Max,
		Type = 'Slider',
		Value = props.Default or props.Min,
	}

	local slider = ui.row(children, props)
	component.Object = slider
	local left = ui.new('Frame', {
		Name = 'Left',
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(theme.Inset, 0),
		Size = UDim2.new(0.5, -theme.Inset, 1, 0)
	}, slider)
	ui.list(left, 6, true)
	ui.text(left, {Text = props.DisplayName or props.Name, Size = 15, Color = theme.Label, Props = {
		Name = 'Label', AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 1, Size = UDim2.fromOffset(0, theme.RowHeight)
	}})
	-- Slinky prints no value beside a slider: it shows in a bubble over the knob while the slider is
	-- hovered or dragged. On a phone it also sits here, where a tap types one (Ctrl-click on a PC).
	local valuelabel = ui.text(left, {Class = 'TextButton', Text = sliderText(component.Value, props.Suffix), Size = 13, Color = theme.SubText, Props = {
		Name = 'Value', AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 2, Size = UDim2.fromOffset(0, theme.RowHeight), Visible = isMobile()
	}})
	local custombox = ui.text(left, {Class = 'TextBox', Size = 13, Color = theme.Text, Props = {
		ClearTextOnFocus = false, LayoutOrder = 3, Size = UDim2.fromOffset(64, theme.RowHeight), Text = tostring(component.Value), Visible = false
	}})

	-- From the card's centre to 14 px short of its right edge.
	local holder = ui.new('Frame', {
		Name = 'Track',
		AnchorPoint = Vector2.new(1, 0.5),
		BackgroundColor3 = theme.Track,
		BorderSizePixel = 0,
		Position = UDim2.new(1, -14, 0.5, 0),
		Size = UDim2.new(0.5, -14, 0, 4)
	}, slider)
	ui.corner(holder, UDim.new(1, 0))
	local function fraction(value)
		local low = props.Min or 0
		return math.clamp((value - low) / math.max((props.Max or 1) - low, 1e-9), 0, 1)
	end
	local fill = ui.new('Frame', {
		BackgroundColor3 = theme.Accent(),
		BorderSizePixel = 0,
		Size = UDim2.fromScale(fraction(component.Value), 1)
	}, holder)
	ui.corner(fill, UDim.new(1, 0))
	-- The knob only moves; the dot inside it grows on hover, so neither animation cancels the other.
	local knob = ui.new('Frame', {
		Name = 'Knob',
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundTransparency = 1,
		Position = UDim2.fromScale(fraction(component.Value), 0.5),
		Size = UDim2.fromOffset(14, 14)
	}, holder)
	local dot = ui.new('Frame', {
		Name = 'Dot',
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = theme.Accent(),
		BorderSizePixel = 0,
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(12, 12)
	}, knob)
	ui.corner(dot, UDim.new(1, 0))
	local bubble = ui.knobBubble(knob)
	local hovering, dragging = false, false
	local function showBubble()
		if hovering or dragging then
			bubble:Show(sliderText(component.Value, props.Suffix))
		else
			bubble:Hide()
		end
	end
	local hit = ui.new('TextButton', {
		Name = 'Hit',
		AnchorPoint = Vector2.new(1, 0),
		BackgroundTransparency = 1,
		Position = UDim2.new(1, 0, 0, 0),
		Size = UDim2.new(0.5, 0, 1, 0),
		Text = ''
	}, slider)
	props.Function = props.Function or function() end
	props.Decimal = props.Decimal or 1

	function component:Color(hue, sat, val, isRainbow)
		fill.BackgroundColor3 = accentFor(self.Index, 0.075, hue, sat, val, isRainbow)
		dot.BackgroundColor3 = fill.BackgroundColor3
	end

	function component:Load(data)
		local newValue = data.Value == data.Max and data.Max ~= self.Max and self.Max or data.Value
		-- Clamp to the CURRENT range: a lowered Max must not leave an out-of-range value that
		-- Save then writes back out forever.
		if isFiniteNumber(newValue) then
			newValue = math.clamp(newValue, props.Min or 0, self.Max)
		end
		if self.Value ~= newValue then
			self:SetValue(newValue, nil, true)
		end
	end

	function component:Save(data)
		data[props.Name] = {
			Value = self.Value,
			Max = self.Max
		}
	end

	function component:SetValue(value, position, wasReleased)
		if not isFiniteNumber(value) then
			return
		end

		local where = position or fraction(value)
		tween:Tween(fill, uipallet.Tween, {Size = UDim2.fromScale(where, 1)})
		tween:Tween(knob, uipallet.Tween, {Position = UDim2.fromScale(where, 0.5)})

		if self.Value ~= value or wasReleased then
			self.Value = value
			valuelabel.Text = sliderText(self.Value, props.Suffix)
			bubble:SetText(valuelabel.Text)
			props.Function(value, wasReleased)
			vape:RequestSave()
		end
	end

	local function editValue()
		custombox.Visible = true
		valuelabel.Visible = false
		custombox.Text = tostring(component.Value)
		custombox:CaptureFocus()
	end

	hit.InputBegan:Connect(function(input)
		if not isPress(input) then return end
		-- Ctrl-click types an exact value, as Slinky does.
		if inputService:IsKeyDown(Enum.KeyCode.LeftControl) or inputService:IsKeyDown(Enum.KeyCode.RightControl) then
			editValue()
			return
		end
		dragging = true
		showBubble()
		trackDrag(input, holder, function(position)
			component:SetValue(math.floor((props.Min + (props.Max - props.Min) * position) * props.Decimal) / props.Decimal, position)
		end, function(position)
			component:SetValue(component.Value, position, true)
			dragging = false
			showBubble()
		end)
	end)

	hit.MouseEnter:Connect(function()
		hovering = true
		showBubble()
		tween:Tween(dot, uipallet.Tween, {Size = UDim2.fromOffset(14, 14)})
	end)

	hit.MouseLeave:Connect(function()
		hovering = false
		showBubble()
		tween:Tween(dot, uipallet.Tween, {Size = UDim2.fromOffset(12, 12)})
	end)

	valuelabel.MouseButton1Click:Connect(editValue)

	custombox.FocusLost:Connect(function(enter)
		custombox.Visible = false
		valuelabel.Visible = isMobile()

		-- A phone's keyboard is usually closed by tapping away, not by Return. Kept to the range, as Load keeps it.
		local typed = (enter or isMobile()) and tonumber(custombox.Text)
		if isFiniteNumber(typed) then
			component:SetValue(math.clamp(typed, props.Min or 0, component.Max), nil, true)
		end
	end)

	api.Options[props.Name] = component

	return component
end

components.Targets = function(props, children, api)
	local component = {
		Index = getTableSize(api.Options),
		Type = 'Targets'
	}

	local targets = ui.new('Frame', {
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = theme.Card,
		BackgroundTransparency = 1,
		LayoutOrder = props.LayoutOrder or 0,
		Size = UDim2.new(1, 0, 0, 0),
		Visible = props.Visible == nil or props.Visible
	}, children)
	component.Object = targets
	component.Window = targets
	ui.list(targets, 0)
	local line = ui.row(targets, {LayoutOrder = 1})
	local title = ui.rowLabel(line, {Name = 'Targets', Darker = props.Darker})
	addTooltip(line, props.Tooltip)
	local chips = ui.new('Frame', {
		Name = 'Chips',
		AnchorPoint = Vector2.new(1, 0.5),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundTransparency = 1,
		Position = UDim2.new(1, -theme.Inset, 0.5, 0),
		Size = UDim2.fromOffset(0, 24)
	}, line)
	ui.list(chips, 6, true, Enum.HorizontalAlignment.Right)
	props.Function = props.Function or function() end

	function component:Color(hue, sat, val, isRainbow)
		local accent = accentFor(self.Index, 0.075, hue, sat, val, isRainbow)
		for _, chip in {self.Players, self.NPCs} do
			if chip.Enabled then
				chip:Paint(accent)
			end
		end
		self.Invisible:Color(hue, sat, val, isRainbow)
		self.Walls:Color(hue, sat, val, isRainbow)
	end

	function component:Load(data)
		if self.Players.Enabled ~= data.Players then
			self.Players:Toggle()
		end

		if self.NPCs.Enabled ~= data.NPCs then
			self.NPCs:Toggle()
		end

		if self.Invisible.Enabled ~= data.Invisible then
			self.Invisible:Toggle()
		end

		if self.Walls.Enabled ~= data.Walls then
			self.Walls:Toggle()
		end
	end

	function component:Save(data)
		data.Targets = {
			Players = self.Players.Enabled,
			NPCs = self.NPCs.Enabled,
			Invisible = self.Invisible.Enabled,
			Walls = self.Walls.Enabled
		}
	end

	function component:UpdateText()
		local any = self.Players.Enabled or self.NPCs.Enabled
		title.TextColor3 = any and (props.Darker and theme.SubText or theme.Label) or theme.Red
	end

	component.Players = components.TargetsButton({
		Text = 'Players',
		Order = 1,
		Targets = component,
		Tooltip = 'Target players',
		Function = props.Function
	}, chips, chips)

	component.NPCs = components.TargetsButton({
		Text = 'NPCs',
		Order = 2,
		Targets = component,
		Tooltip = 'Target NPCs',
		Function = props.Function
	}, chips, chips)

	component.Invisible = components.Toggle({
		Name = 'Ignore invisible',
		Darker = true,
		LayoutOrder = 2,
		Function = function()
			props.Function()
		end
	}, targets, {Options = {}})

	component.Walls = components.Toggle({
		Name = 'Ignore behind walls',
		Darker = true,
		LayoutOrder = 3,
		Function = function()
			props.Function()
		end
	}, targets, {Options = {}})

	if props.Players then
		component.Players:Toggle()
	end

	if props.NPCs then
		component.NPCs:Toggle()
	end

	if props.Invisible then
		component.Invisible:Toggle()
	end

	if props.Walls then
		component.Walls:Toggle()
	end
	component:UpdateText()

	api.Options.Targets = component

	return component
end

components.TargetsButton = function(props, children, api)
	local component = {
		Enabled = false,
		Type = 'TargetsButton'
	}

	local targetsbutton = ui.text(children, {Class = 'TextButton', Text = props.Text or 'Target', Size = 13, Weight = 'Medium', Color = theme.SubText, AlignX = Enum.TextXAlignment.Center, Props = {
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = theme.Card,
		BackgroundTransparency = 0,
		LayoutOrder = props.Order or 0,
		Size = UDim2.fromOffset(0, 24),
		Visible = props.Visible == nil or props.Visible
	}})
	ui.corner(targetsbutton, UDim.new(1, 0))
	ui.padding(targetsbutton, 12, 12, 0, 0)
	local stroke = ui.stroke(targetsbutton, theme.Outline, 1, 0.1)
	component.Object = targetsbutton
	addTooltip(targetsbutton, props.Tooltip)
	props.Function = props.Function or function() end

	function component:Paint(accent)
		if self.Enabled then
			targetsbutton.BackgroundColor3 = accent or theme.Accent()
			targetsbutton.TextColor3 = theme.Knob
			stroke.Enabled = false
		else
			targetsbutton.BackgroundColor3 = theme.Card
			targetsbutton.TextColor3 = theme.SubText
			stroke.Enabled = true
		end
	end

	function component:Toggle()
		self.Enabled = not self.Enabled
		self:Paint()

		props.Targets:UpdateText()
		props.Function(self.Enabled)
		vape:RequestSave()
	end

	targetsbutton.MouseButton1Click:Connect(function()
		component:Toggle()
	end)

	return component
end

components.TextBox = function(props, children, api)
	local component = {
		Index = 0,
		Type = 'TextBox',
		Value = props.Default or ''
	}

	local textbox = ui.row(children, props)
	component.Object = textbox
	ui.rowLabel(textbox, props)
	addTooltip(textbox, props.Tooltip)
	local holder = ui.pill(textbox, {Class = 'Frame'})
	local inputbox = ui.text(holder, {Class = 'TextBox', Size = 14, Color = theme.Text, Props = {
		ClearTextOnFocus = false,
		PlaceholderColor3 = theme.Muted,
		PlaceholderText = props.Placeholder or 'Click to set',
		Position = UDim2.fromOffset(12, 0),
		Size = UDim2.new(1, -24, 1, 0),
		Text = props.Default or '',
		TextTruncate = Enum.TextTruncate.AtEnd
	}})
	props.Function = props.Function or function() end

	function component:Load(data)
		if self.Value ~= data.Value then
			self:SetValue(data.Value)
		end
	end

	function component:Save(data)
		data[props.Name] = {
			Value = self.Value
		}
	end

	function component:SetValue(val, enter)
		self.Value = val
		inputbox.Text = val
		props.Function(enter)
		vape:RequestSave()
	end

	inputbox.FocusLost:Connect(function(enter)
		component:SetValue(inputbox.Text, enter)
	end)

	inputbox:GetPropertyChangedSignal('Text'):Connect(function()
		-- SetValue writes the text this listens to; that echo carries nothing new.
		if inputbox.Text == component.Value then return end
		component:SetValue(inputbox.Text)
	end)

	api.Options[props.Name] = component

	return component
end

components.TextList = function(props, children, api)
	local component = {
		Index = getTableSize(api.Options),
		--[[ Cloned, not referenced: assigning the module's own default made List, ListEnabled and
		the default the SAME table, so editing one list edited every list built from it. ]]
		List = props.Default and table.clone(props.Default) or {},
		ListEnabled = props.Default and table.clone(props.Default) or {},
		Objects = {},
		Type = 'TextList',
		Window = {Visible = false}
	}

	props.Color = props.Color or Color3.fromRGB(243, 93, 18)
	local textlist = ui.new('Frame', {
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = props.LayoutOrder or 0,
		Size = UDim2.new(1, 0, 0, 0),
		Visible = props.Visible == nil or props.Visible
	}, children)
	component.Object = textlist
	ui.list(textlist, 0)
	local line = ui.row(textlist, {LayoutOrder = 1})
	ui.rowLabel(line, props)
	addTooltip(line, props.Tooltip)
	local button = ui.pill(line, {})
	button.Name = 'Toggle'
	local amount = ui.text(button, {Text = '0 entries', Size = 14, Color = theme.Text, AlignX = Enum.TextXAlignment.Center, Props = {
		Position = UDim2.fromOffset(12, 0), Size = UDim2.new(1, -36, 1, 0), TextTruncate = Enum.TextTruncate.AtEnd
	}})
	local chevron = ui.icon(button, 'chevron-right', 13, {Color = theme.SubText, Props = {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -8, 0.5, 0)
	}})

	local textlistwindow = ui.new('Frame', {
		Name = 'Editor',
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = 2,
		Size = UDim2.new(1, 0, 0, 0),
		Visible = false
	}, textlist)
	component.Window = textlistwindow
	ui.list(textlistwindow, 2)
	ui.padding(textlistwindow, 0, 0, 2, 6)
	local addrow = ui.row(textlistwindow, {LayoutOrder = -1}, 34)
	local boxholder = ui.pill(addrow, {Class = 'Frame', AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, theme.Inset + 12, 0.5, 0), Size = UDim2.new(1, -(theme.Inset * 2 + 12), 0, 26)})
	local textbox = ui.text(boxholder, {Class = 'TextBox', Size = 14, Color = theme.Text, Props = {
		ClearTextOnFocus = false,
		PlaceholderColor3 = theme.Muted,
		PlaceholderText = props.Placeholder or 'Add entry...',
		Position = UDim2.fromOffset(12, 0),
		Size = UDim2.new(1, -44, 1, 0)
	}})
	local add = ui.icon(boxholder, 'plus', 14, {Class = 'TextButton', Color = theme.SubText, Props = {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -6, 0.5, 0)
	}})
	props.Function = props.Function or function() end

	function component:Color(hue, sat, val, isRainbow) end

	function component:ChangeValue(value)
		if value then
			local index = table.find(self.List, value)
			if index then
				table.remove(self.List, index)

				index = table.find(self.ListEnabled, value)
				if index then
					table.remove(self.ListEnabled, index)
				end
			else
				table.insert(self.List, value)
				table.insert(self.ListEnabled, value)
			end
		end

		props.Function(self.List)
		if value ~= nil then
			vape:RequestSave()
		end
		for _, v in self.Objects do
			v:Destroy()
		end
		table.clear(self.Objects)
		amount.Text = #self.List..(#self.List == 1 and ' entry' or ' entries')

		for index, value in self.List do
			local isEnabled = table.find(self.ListEnabled, value)
			local obj = ui.new('TextButton', {
				AutoButtonColor = false,
				BackgroundTransparency = 1,
				LayoutOrder = index,
				Size = UDim2.new(1, 0, 0, 28),
				Text = ''
			}, textlistwindow)
			local dot = ui.new('Frame', {
				Name = 'Dot',
				AnchorPoint = Vector2.new(0, 0.5),
				BackgroundColor3 = isEnabled and props.Color or theme.Muted,
				Position = UDim2.new(0, theme.Inset + 12, 0.5, 0),
				Size = UDim2.fromOffset(12, 12)
			}, obj)
			ui.corner(dot, UDim.new(1, 0))
			local dotin = ui.new('Frame', {
				BackgroundColor3 = isEnabled and props.Color or theme.Card,
				Position = UDim2.fromOffset(2, 2),
				Size = UDim2.fromOffset(8, 8)
			}, dot)
			ui.corner(dotin, UDim.new(1, 0))
			ui.text(obj, {Text = value, Size = 14, Color = theme.Label, Props = {
				Position = UDim2.fromOffset(theme.Inset + 34, 0), Size = UDim2.new(1, -(theme.Inset * 2 + 60), 1, 0), TextTruncate = Enum.TextTruncate.AtEnd
			}})
			local close = ui.icon(obj, 'x', 13, {Class = 'TextButton', Color = theme.SubText, Props = {
				AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -theme.Inset + 4, 0.5, 0)
			}})

			close.MouseButton1Click:Connect(function()
				self:ChangeValue(value)
			end)

			obj.MouseButton1Click:Connect(function()
				local found = table.find(self.ListEnabled, value)
				if found then
					table.remove(self.ListEnabled, found)
					dot.BackgroundColor3 = theme.Muted
					dotin.BackgroundColor3 = theme.Card
				else
					table.insert(self.ListEnabled, value)
					dot.BackgroundColor3 = props.Color
					dotin.BackgroundColor3 = props.Color
				end

				props.Function()
				vape:RequestSave()
			end)

			table.insert(self.Objects, obj)
		end
	end

	function component:Load(data)
		self.List = data.List or {}
		self.ListEnabled = data.ListEnabled or {}
		self:ChangeValue()
	end

	function component:Save(data)
		data[props.Name] = {
			List = self.List,
			ListEnabled = self.ListEnabled
		}
	end

	local function submit()
		if textbox.Text ~= '' and not table.find(component.List, textbox.Text) then
			component:ChangeValue(textbox.Text)
			textbox.Text = ''
		end
	end

	add.MouseButton1Click:Connect(submit)

	textbox.FocusLost:Connect(function(enter)
		-- A phone's keyboard is usually closed by tapping away, not by Return.
		if enter or isMobile() then
			submit()
		end
	end)

	button.MouseButton1Click:Connect(function()
		textlistwindow.Visible = not textlistwindow.Visible
		ui.setIcon(chevron, textlistwindow.Visible and 'chevron-down' or 'chevron-right')
	end)

	if props.Default then
		component:ChangeValue()
	end

	api.Options[props.Name] = component

	return component
end

components.Toggle = function(props, children, api)
	local component = {
		Enabled = false,
		Index = getTableSize(api.Options),
		Name = props.Name,
		Type = 'Toggle'
	}

	local toggle = ui.row(children, props)
	component.Object = toggle
	local title = ui.rowLabel(toggle, props, 70)
	local hit = ui.new('TextButton', {
		Name = 'Hit',
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Text = ''
	}, toggle)
	local switch = ui.switch(toggle)
	addRowTooltip(hit, props.Tooltip, switch.Object, title)
	-- Where a key bound to this setting shows, left of the switch.
	local slot = ui.new('Frame', {
		Name = 'BindSlot',
		AnchorPoint = Vector2.new(1, 0.5),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundTransparency = 1,
		Position = UDim2.new(1, -(theme.Inset + 48), 0.5, 0),
		Size = UDim2.fromOffset(0, 20)
	}, toggle)
	ui.list(slot, 0, true, Enum.HorizontalAlignment.Right)
	component.BindParent = slot
	props.Function = props.Function or function() end

	function component:Color(hue, sat, val, isRainbow)
		if self.Enabled then
			switch:Color(accentFor(self.Index, 0.075, hue, sat, val, isRainbow))
		end
	end

	function component:Load(data)
		if self.Enabled ~= data.Enabled then
			self:Toggle()
		end

		if self.Bind and data.Bind then
			self.Bind:Load(data.Bind)
		end
	end

	function component:Save(data)
		data[props.Name] = {
			Enabled = self.Enabled
		}

		if self.Bind then
			self.Bind:Save(data[props.Name])
		end
	end

	function component:Toggle()
		self.Enabled = not self.Enabled
		switch:Set(self.Enabled, liveAccent(self.Index))

		props.Function(self.Enabled)
		vape:RequestSave()
	end

	hit.MouseButton1Click:Connect(function()
		component:Toggle()
	end)

	if props.Default then
		component:Toggle()
	end

	api.Options[props.Name] = component

	return component
end

components.TwoSlider = function(props, children, api)
	local knobTween = TweenInfo.new(0.1)
	local component = {
		Index = getTableSize(api.Options),
		Max = props.Max,
		Type = 'TwoSlider',
		ValueMin = props.DefaultMin or props.Min,
		ValueMax = props.DefaultMax or 10
	}

	local twoslider = ui.row(children, props)
	component.Object = twoslider
	local left = ui.new('Frame', {
		Name = 'Left',
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(theme.Inset, 0),
		Size = UDim2.new(0.5, -theme.Inset, 1, 0)
	}, twoslider)
	ui.list(left, 6, true)
	ui.text(left, {Text = props.DisplayName or props.Name, Size = 15, Color = theme.Label, Props = {
		Name = 'Label', AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 1, Size = UDim2.fromOffset(0, theme.RowHeight)
	}})
	-- No min and max text at rest, as in Slinky: each knob gets a value bubble while the slider is
	-- hovered or dragged. On a phone the two ends also sit here, where a tap types one.
	local minvalue = ui.text(left, {Class = 'TextButton', Text = tostring(component.ValueMin), Size = 13, Color = theme.SubText, Props = {
		Name = 'Min', AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 2, Size = UDim2.fromOffset(0, theme.RowHeight), Visible = isMobile()
	}})
	local maxvalue = ui.text(left, {Class = 'TextButton', Text = tostring(component.ValueMax), Size = 13, Color = theme.SubText, Props = {
		Name = 'Max', AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 4, Size = UDim2.fromOffset(0, theme.RowHeight), Visible = isMobile()
	}})
	local custommin = ui.text(left, {Class = 'TextBox', Size = 13, Color = theme.Text, Props = {
		ClearTextOnFocus = false, LayoutOrder = 5, Size = UDim2.fromOffset(48, theme.RowHeight), Visible = false
	}})
	local custommax = ui.text(left, {Class = 'TextBox', Size = 13, Color = theme.Text, Props = {
		ClearTextOnFocus = false, LayoutOrder = 6, Size = UDim2.fromOffset(48, theme.RowHeight), Visible = false
	}})
	local holder = ui.new('Frame', {
		Name = 'Track',
		AnchorPoint = Vector2.new(1, 0.5),
		BackgroundColor3 = theme.Track,
		BorderSizePixel = 0,
		Position = UDim2.new(1, -14, 0.5, 0),
		Size = UDim2.new(0.5, -14, 0, 4)
	}, twoslider)
	ui.corner(holder, UDim.new(1, 0))
	-- Where a value sits along the bar, from Min rather than from 0.
	local function sliderFraction(value)
		local low = props.Min or 0
		return math.clamp((value - low) / math.max(props.Max - low, 1e-9), 0, 1)
	end
	local fill = ui.new('Frame', {
		BackgroundColor3 = theme.Accent(),
		BorderSizePixel = 0,
		Position = UDim2.fromScale(sliderFraction(component.ValueMin), 0),
		Size = UDim2.fromScale(math.max(sliderFraction(component.ValueMax) - sliderFraction(component.ValueMin), 0), 1)
	}, holder)
	local knob = ui.new('Frame', {
		Name = 'KnobMin',
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = theme.Accent(),
		Position = UDim2.fromScale(sliderFraction(component.ValueMin), 0.5),
		Size = UDim2.fromOffset(12, 12)
	}, holder)
	ui.corner(knob, UDim.new(1, 0))
	local knobmax = ui.new('Frame', {
		Name = 'KnobMax',
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = theme.Accent(),
		Position = UDim2.fromScale(sliderFraction(component.ValueMax), 0.5),
		Size = UDim2.fromOffset(12, 12)
	}, holder)
	ui.corner(knobmax, UDim.new(1, 0))
	local bubbleMin, bubbleMax = ui.knobBubble(knob), ui.knobBubble(knobmax)
	local hovering, dragging = false, false
	local function showBubbles()
		if hovering or dragging then
			bubbleMin:Show(tostring(component.ValueMin))
			bubbleMax:Show(tostring(component.ValueMax))
		else
			bubbleMin:Hide()
			bubbleMax:Hide()
		end
	end
	local hit = ui.new('TextButton', {
		Name = 'Hit',
		AnchorPoint = Vector2.new(1, 0),
		BackgroundTransparency = 1,
		Position = UDim2.new(1, 0, 0, 0),
		Size = UDim2.new(0.5, 0, 1, 0),
		Text = ''
	}, twoslider)
	props.Function = props.Function or function() end
	props.Decimal = props.Decimal or 1
	local random = Random.new()

	function component:Color(hue, sat, val, isRainbow)
		fill.BackgroundColor3 = accentFor(self.Index, 0.075, hue, sat, val, isRainbow)
		knob.BackgroundColor3 = fill.BackgroundColor3
		knobmax.BackgroundColor3 = fill.BackgroundColor3
	end

	-- Callers use both GetRandomValue() and :GetRandomValue(), so this reads component.
	function component:GetRandomValue()
		local low, high = component.ValueMin, component.ValueMax
		if low > high then
			low, high = high, low
		end
		return random:NextNumber(low, high)
	end

	function component:Load(data)
		local newMin, newMax = data.ValueMin, data.ValueMax
		-- Saved while this option was still a plain Slider ({Value = x}): a range of one.
		if newMin == nil and newMax == nil and isFiniteNumber(data.Value) then
			newMin, newMax = data.Value, data.Value
		end
		if isFiniteNumber(newMin) then
			newMin = math.clamp(newMin, props.Min or 0, self.Max)
		end
		if isFiniteNumber(newMax) then
			newMax = math.clamp(newMax, props.Min or 0, self.Max)
		end

		if self.ValueMin ~= newMin then
			self:SetValue(false, newMin)
		end

		if self.ValueMax ~= newMax then
			self:SetValue(true, newMax)
		end
	end

	function component:Save(data)
		data[props.Name] = {
			ValueMin = self.ValueMin,
			ValueMax = self.ValueMax
		}
	end

	function component:SetValue(isMax, value)
		if not isFiniteNumber(value) then
			return
		end

		self[isMax and 'ValueMax' or 'ValueMin'] = value
		maxvalue.Text = tostring(self.ValueMax)
		minvalue.Text = tostring(self.ValueMin)

		local low, high = sliderFraction(self.ValueMin), sliderFraction(self.ValueMax)
		tween:Tween(fill, knobTween, {
			Position = UDim2.fromScale(math.min(low, high), 0),
			Size = UDim2.fromScale(math.abs(high - low), 1)
		})
		tween:Tween(knob, knobTween, {Position = UDim2.fromScale(low, 0.5)})
		tween:Tween(knobmax, knobTween, {Position = UDim2.fromScale(high, 0.5)})
		bubbleMin:SetText(tostring(self.ValueMin))
		bubbleMax:SetText(tostring(self.ValueMax))

		props.Function(self.ValueMin, self.ValueMax, isMax)
		vape:RequestSave()
	end

	hit.InputBegan:Connect(function(input)
		if not isPress(input) then return end
		local start = math.clamp((input.Position.X - holder.AbsolutePosition.X) / math.max(holder.AbsoluteSize.X, 1), 0, 1)
		-- Whichever knob is nearer the press is the one that moves.
		local maxCheck = math.abs(start - sliderFraction(component.ValueMax)) <= math.abs(start - sliderFraction(component.ValueMin))
		if inputService:IsKeyDown(Enum.KeyCode.LeftControl) or inputService:IsKeyDown(Enum.KeyCode.RightControl) then
			local box = maxCheck and custommax or custommin
			box.Visible = true
			box.Text = tostring(maxCheck and component.ValueMax or component.ValueMin)
			box:CaptureFocus()
			return
		end
		dragging = true
		showBubbles()
		trackDrag(input, holder, function(position)
			local value = math.floor((props.Min + (props.Max - props.Min) * position) * props.Decimal) / props.Decimal
			-- Every pointer move lands here; one that leaves the value on the same step changes nothing.
			if value ~= component[maxCheck and 'ValueMax' or 'ValueMin'] then
				component:SetValue(maxCheck, value)
			end
		end, function()
			dragging = false
			showBubbles()
		end)
	end)
	hit.MouseEnter:Connect(function()
		hovering = true
		showBubbles()
	end)
	hit.MouseLeave:Connect(function()
		hovering = false
		showBubbles()
	end)

	maxvalue.MouseButton1Click:Connect(function()
		maxvalue.Visible = false
		custommax.Visible = true
		custommax.Text = tostring(component.ValueMax)
		custommax:CaptureFocus()
	end)

	minvalue.MouseButton1Click:Connect(function()
		minvalue.Visible = false
		custommin.Visible = true
		custommin.Text = tostring(component.ValueMin)
		custommin:CaptureFocus()
	end)

	custommax.FocusLost:Connect(function(enter)
		custommax.Visible = false
		maxvalue.Visible = isMobile()

		-- Kept to the range, as Load keeps it.
		local typed = (enter or isMobile()) and tonumber(custommax.Text)
		if isFiniteNumber(typed) then
			component:SetValue(true, math.clamp(typed, props.Min or 0, component.Max))
		end
	end)

	custommin.FocusLost:Connect(function(enter)
		custommin.Visible = false
		minvalue.Visible = isMobile()

		local typed = (enter or isMobile()) and tonumber(custommin.Text)
		if isFiniteNumber(typed) then
			component:SetValue(false, math.clamp(typed, props.Min or 0, component.Max))
		end
	end)

	api.Options[props.Name] = component

	return component
end

vape.Components = setmetatable(components, {
	__newindex = function(self, index, callback)
		--[[ rawset FIRST. Without it the components table never actually receives the
		entry, so only containers that already existed got the method and every
		container built afterwards was missing it -- which is what "attempt to call
		missing method 'CreateHotbarList'" was: AutoHotbar is created further down
		the same file that registers HotbarList. ]]
		rawset(self, index, callback)

		--[[ Every container that has already bound the table, not just modules: a
		category or an overlay can hold options too. module.Children was the wrong
		frame anyway -- it only exists on a module given a Size (its draggable
		on-screen window) and is nil for an ordinary one, so the component either
		indexed nil or drew itself into the wrong place. ]]
		for component, children in componentChildren do
			rawset(component, 'Create'..index, function(_, props)
				if layout then
					layout.ColorDirty = true
				end
				return callback(props, children, component)
			end)
		end
	end
})

vape:LoadGUI()

return vape
