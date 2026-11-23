--[[ The library's shared state. moduleCount is kept on insert and remove so main.lua can poll it while
modules register, without walking slinky.modules. moduleOrder holds the same modules as a plain
array and is the only thing slinky:save walks: pairs/next loses its place, or takes the VM down,
when the table rehashes between two resumptions, while an index loop over a growing array sees a
prefix. loadGeneration lets a newer slinky:load stop an older one that is still yielding.
saveBlocked stays true until main.lua has loaded every module and the profile. ]]
local slinky = {
	activeBinds = {},
	categories = {},
	accent = {
		hue = 0.0556,
		sat = 0.926,
		value = 0.953
	},
	heldKeybinds = {},
	loaded = false,
	libraries = {},
	modules = {},
	moduleCount = 0,
	moduleOrder = {},
	place = game.PlaceId,
	profile = 'default',
	rainbowSliders = {},
	rainbowSliderIndices = {},
	loadGeneration = 0,
	loadedCount = 0,
	saveBlocked = true,
	saveEpoch = 0,
	settings = {},
	settingToggleNotifications = {},
	threadFix = setthreadidentity and true or false,
	toggleNotifications = {},
	version = '4.22',
	windows = {}
}

local run = function(func)
	func()
end

local function addRainbowSlider(component)
	if slinky.rainbowSliderIndices[component] then return end
	local index = #slinky.rainbowSliders + 1
	slinky.rainbowSliders[index] = component
	slinky.rainbowSliderIndices[component] = index
end

local function removeRainbowSlider(component)
	local index = slinky.rainbowSliderIndices[component]
	if not index then return end
	local lastIndex = #slinky.rainbowSliders
	local moved = slinky.rainbowSliders[lastIndex]
	slinky.rainbowSliders[index] = moved
	slinky.rainbowSliders[lastIndex] = nil
	slinky.rainbowSliderIndices[component] = nil
	if moved and moved ~= component then
		slinky.rainbowSliderIndices[moved] = index
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

--[[ Sends an HTTP request through shared.PistonwareDevRequest when it is set, otherwise through
whichever name the executor puts its request function under. Errors when there is none; callers
pcall it and fall back to HttpGet. ]]
local function pistonwareRequest(options)
	local adapter = shared.PistonwareDevRequest
	if type(adapter) == 'function' then
		return adapter(options)
	end
	local send = type(request) == 'function' and request or type(http_request) == 'function' and http_request
		or type(httprequest) == 'function' and httprequest
		or type(http) == 'table' and type(http.request) == 'function' and http.request
		or type(syn) == 'table' and type(syn.request) == 'function' and syn.request
	if not send then error('this executor has no request function', 0) end
	return send(options)
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

--[[ The automatic menu scale: the screen width over 1920, kept between 0.4 and 1. Phones report their
render resolution here, so without the upper bound a wide handset gets a menu larger than 1:1 that
runs off the screen. The Mac executors stay at 1:1: their displays are full size and their windows
narrower than 1920 as a matter of course. ]]
local function autoScaleValue()
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
local getslinkyasset
local components
local clickgui
local scaledgui
local toolblur
local tooltip
local textGUI
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
	The boot apply with the menu shut gets 16ms, half a 30fps frame, as nothing on screen waits
	on it. SaveBlocked marks the boot: set from the start, cleared by main.lua after that apply.
]]
local buildclock = os.clock()
local yieldBudget = 0.01
--[[ Yields a frame once the apply has worked past its budget: yieldBudget while the menu is open or
after boot, 16 ms during the boot apply. It reads slinky.menuOpen, not clickgui.Visible, because the
apply thread may not be allowed to read the gui. ]]
local function yieldBuild(budget)
	if os.clock() - buildclock > (budget or ((slinky.menuOpen or not slinky.saveBlocked) and yieldBudget or 0.016)) then
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
	or two instead of all in one instant. During boot it starts a few milliseconds' worth a frame
	rather than one.

	One drain thread at a time, and it exits when the queue empties, so nothing is left running
	between applies.
]]
local startQueue, recycledStartJobs = {}, {}
local startHead, startTail = 1, 0
local startThread
--[[ Queues a module's start for a profile apply and starts the drain thread when none runs. The drain
yields before its first job: task.spawn resumes it inline on the caller, and taking a job first
would run one module inside the apply loop. During the boot apply (slinky.saveBlocked) it starts as
many as fit in about 5 ms of a frame, at least one; one a frame put a 77-module profile at 2.5 s at
30 fps. Later applies start one a frame. Each start is spawned, so a module that errors does not
take the drain down with it. ]]
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
		local batch = slinky.saveBlocked
		while startHead <= startTail do
			task.wait()
			local frameStart = os.clock()
			repeat
				local nextJob = startQueue[startHead]
				startQueue[startHead] = nil
				startHead += 1
				local start = nextJob.Start
				nextJob.Start, nextJob.Name = nil, nil
				table.insert(recycledStartJobs, nextJob)
				task.spawn(start, true)
			until not batch or startHead > startTail or os.clock() - frameStart > 0.005
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
	introduce. Both used to propagate out of slinky:Save; in the autosave loop that error was
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

	Every load and save builds 'pistonware/profiles/'..Profile..'.json' out of it and hands
	that to the executor's filesystem. So whatever ends up in a profile name is what isfile,
	readfile and writefile are called with -- and the Profiles tab's name box accepted anything
	typed or pasted into it, including a 15KB exported profile. That name was then saved as the
	active profile, and the isfile call at the top of the next slinky:Load took the whole client
	down. Once saved it recurred on every inject, because the crash happened before anything
	could write a corrected file back.

	Length and character set both matter: the length is what kills the filesystem call, and the
	character set is what stops a name from escaping the profiles folder or being rejected
	outright by the OS. Anything failing this is not repaired or truncated -- a truncated name
	silently points at a different profile's file.
]]
-- 'settings' is taken: a profile of that name would be the file the menu's own state is in.
local function usableProfileName(name)
	return type(name) == 'string'
		and name ~= ''
		and #name <= 32
		and not name:find('[^%w_%- ]')
		and name:lower() ~= 'settings'
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
			return module.name, module
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

	function slinky:colorAt(h)
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

	function slinky:textColor(h, s, v)
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

--[[ getslinkyasset. Every icon the menu draws has an uploaded id in slinkyAssets, so the load path reads
no file and calls no getcustomasset. A truncated PNG on disk gives an invalid content id, and
assigning one to .Image throws at the assignment, outside every pcall, taking the whole GUI down.

Paths with no uploaded id (arrowmodule, radaricon, textguiicon, blockedicon, blockedtab, asked for
only by game modules) resolve from the file through getcustomasset, lazily, the first time a module
draws one. getcustomasset stays reachable because the game files pass user files (custom music,
textures) through the slinky.libraries.getcustomasset alias. A path that is already a content id is
returned as it is.

hasContent treats an empty file as missing, since every executor's isfile reports a zero-byte file
as present and a write cut short by a cancel, crash or teleport leaves one; a .lua file must also
compile. downloadFile fetches from the pistonware repo's main branch with 4 attempts, because a raw
host under load returns an error page as the body. In developer mode a file with content that does
not compile stops the load on its compile error. preferFile asks for the file first:
resolveFileIfCheap answers only from cache or disk and fetches a missing file on another thread, so
the id is drawn now. Touch devices and executors without getcustomasset never get a file. ]]
do
	local slinkyAssets = {
		['pistonware/assets/icons/pistonround.png'] = 'rbxassetid://99295797606112',
		['pistonware/assets/icons/pistonsquare.png'] = 'rbxassetid://73714636260061'
	}

	local function usableAsset(value)
		return type(value) == 'string' and value:match('^rbx%a*://') ~= nil
	end

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

	local function downloadFile(path)
		local devLoader = shared.PistonwareDevLoadSource
		if type(devLoader) == 'function' then
			devLoader(path)
			return getcustomasset(path)
		end
		if not hasContent(path) then
			if shared.PistonwareDeveloper == true then
				local ok, text = pcall(readfile, path)
				if isfile(path) and ok and type(text) == 'string' and text ~= '' then
					local compileOk, chunk, compileError = pcall(loadstring, text, path)
					error(path..' does not compile (developer mode does not replace it): '..tostring(compileOk and compileError or chunk), 0)
				end
			end
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

	getslinkyasset = function(path, preferFile)
		if preferFile then
			local file = resolveFileIfCheap(path)
			if file ~= '' then return file end
		end

		local id = slinkyAssets[path]
		if id then return id end
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

--[[ tween:Tween plays a tween and keeps it in a registry (index, 'tweens' by default) so a newer one on
the same object replaces it. The entry is cleared before the old tween is cancelled, because Cancel
fires Completed. An object that is hidden, or inside the shut menu, is set to the end state at once:
nobody sees the animation, and the menu opens by appearing. ]]
do
	function tween:Tween(obj, info, goal, index)
		local registry = self[index or 'tweens']
		local existing = registry[obj]
		if existing then
			registry[obj] = nil
			existing:Cancel()
		end

		if obj.Parent and (obj:IsA('UIStroke') or obj.Visible)
			and not (clickgui and not clickgui.Visible and obj:IsDescendantOf(clickgui)) then
			local playing = tweenService:Create(obj, info, goal)
			registry[obj] = playing
			playing.Completed:Once(function()
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

--[[ The menu's colours, sizes and motion. The colours are measured off Slinky's click GUI: text #DDDDDD,
secondary #999999, white under the pointer and a description #BBBBBB. HoldOn is the HOLD badge while
hold is on, CloseRest a list row's x at rest, red under the pointer. CardWidth to Inset are the
sizes the cards are built from, shared by the layout code and the rows.

A Roblox TextSize is the face's line height, not its em: in game Inter draws at TextSize / 1.196 em
(TextScale). Slinky's sizes are em px, written as measured and turned into a TextSize by theme.em.
OverlayEm is the Mod Overlay's em before its Text size, Slinky's 24 px at the default 1.2.

Hovers are instant; HoverTween is for the few colour changes that still ease. The Follow rates are
per second, for ui.anim.follow, so they hold at any frame rate: FollowFast moves the tab pill and
page, FollowDrop a dropdown's height, and FollowCard, 10 ln 2 / 0.3, draws Roblox's Exponential Out
over 0.3 s for a card's height. SwitchTime is a switch's knob and track (Sine InOut), SlinkyInfo the
notifications, and Backdrop the grey behind a modal at 0.75 opacity. ]]
local theme = {
	Bar = Color3.fromRGB(20, 20, 20),
	Card = Color3.fromRGB(20, 20, 20),
	CardHover = Color3.fromRGB(20, 20, 20),
	Raised = Color3.fromRGB(41, 41, 41),
	Pill = Color3.fromRGB(64, 64, 64),
	PillHover = Color3.fromRGB(80, 80, 80),
	Badge = Color3.fromRGB(40, 40, 40),
	HoldOn = Color3.fromRGB(50, 50, 50),
	Outline = Color3.fromRGB(64, 64, 64),
	Track = Color3.fromRGB(64, 64, 64),
	TrackOff = Color3.fromRGB(64, 64, 64),
	TrackOffHover = Color3.fromRGB(80, 80, 80),
	Knob = Color3.fromRGB(20, 20, 20),
	KnobOff = Color3.fromRGB(20, 20, 20),
	Text = Color3.fromRGB(221, 221, 221),
	Label = Color3.fromRGB(221, 221, 221),
	SubText = Color3.fromRGB(153, 153, 153),
	Header = Color3.fromRGB(153, 153, 153),
	Lit = Color3.fromRGB(255, 255, 255),
	SubTextLit = Color3.fromRGB(187, 187, 187),
	Muted = Color3.fromRGB(102, 102, 102),
	Red = Color3.fromRGB(221, 70, 71),
	CloseRest = Color3.fromRGB(66, 66, 66),
	Yellow = Color3.fromRGB(245, 190, 60),
	Green = Color3.fromRGB(82, 196, 106),
	CardWidth = 434,
	Gap = 8,
	RowHeight = 28,
	Inset = 12,
	TextScale = 1.196,
	OverlayEm = 20,
	HoverTween = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
	RedHover = Color3.fromRGB(238, 87, 88),
	TrashOff = Color3.fromRGB(119, 45, 46),
	Trash = Color3.fromRGB(218, 72, 72),
	NotifyText = Color3.fromRGB(223, 223, 223),
	NotifyGreen = Color3.fromRGB(141, 237, 51),
	Backdrop = Color3.fromRGB(48, 48, 48),
	FollowFast = 21.9,
	FollowCard = 23.1,
	FollowDrop = 10.75,
	SwitchTime = 0.10,
	TipInfo = TweenInfo.new(0.10, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
	ModalInfo = TweenInfo.new(0.30, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
	SlinkyInfo = TweenInfo.new(0.2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
}

-- The accent, from the GUI theme slider (orange by default).
function theme.Accent()
	return Color3.fromHSV(slinky.accent.hue, slinky.accent.sat, slinky.accent.value)
end

-- The accent as a tint over a card, for the bound-key badge and the notification tag.
function theme.Tint(accent, amount)
	return theme.Card:Lerp(accent or theme.Accent(), amount or 0.18)
end

-- The TextSize that draws a size given in em px, the unit Slinky's sizes are measured in: 16 is 19.
function theme.em(size)
	return math.floor(size * theme.TextScale + 0.5)
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

--[[ What an icon reads as where its image cannot be shown: one character Inter itself draws. slinky-plus
and slinky-minus have none, because the expander draws its two bars instead. ]]
local ICON_FALLBACK = {
	x = '\u{00D7}', plus = '+', minus = '\u{2212}', share = '\u{2191}', import = '\u{2193}', download = '\u{2193}',
	upload = '\u{2191}', folder = '\u{2026}', ['folder-open'] = '\u{2026}', ['trash-2'] = '\u{00D7}', pin = '\u{2022}',
	check = '\u{2713}', ['chevron-down'] = 'v', ['chevron-right'] = '\u{203A}', eye = '\u{2022}', ['eye-off'] = '\u{2013}',
	search = '?',
	['slinky-export'] = '\u{2191}', ['slinky-save'] = '\u{2193}', ['slinky-folder'] = '\u{2026}',
	['slinky-trash'] = '\u{00D7}', ['slinky-plus'] = '', ['slinky-minus'] = '', ['slinky-x'] = '\u{00D7}'
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
--[[ Sets every registered label to its role's current face, and with remeasure runs the fonts.Remeasure
callbacks too, yielding between batches. An icon is an image, so only its fallback character takes a
face: the bold one. ]]
function fonts.restyle(remeasure)
	local labels = {}
	for obj, entry in fonts.Registry do
		table.insert(labels, {obj, entry})
	end
	for index, pair in labels do
		local obj, entry = pair[1], pair[2]
		if obj.Parent then
			pcall(function()
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

--[[ Fetches one Inter file into FONT_DIR from the pistonware repo, with 4 attempts, and reports whether
a valid file is there now. In developer mode a font file that has content is never replaced. ]]
local function downloadFont(file)
	local path = FONT_DIR..'/'..file
	local devLoader = shared.PistonwareDevLoadSource
	if type(devLoader) == 'function' then
		pcall(devLoader, path)
		return fileValid(path)
	end
	if shared.PistonwareDeveloper == true then
		local ok, body = pcall(readfile, path)
		if ok and type(body) == 'string' and body ~= '' then return false end
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
	label.Parent = slinky.gui
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
	if not (slinky.gui and slinky.gui.Parent) then return 'unknown', 'no gui' end
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

--[[ Once Inter is in: fetches every weight, then makes every self-sizing label lay itself out again.
Only Regular is checked at load; Medium, SemiBold and Bold arrive later, and a label laid out before
its face arrived keeps the fallback's narrower width. A preload can return without the face,
GetTextBoundsAsync cannot, so each face is measured too. With changed the measure cache is emptied;
without it every cached size is already in that face, and measuring again would rebuild the mod
overlay and restart name tags. ]]
function fonts.settle(changed)
	task.spawn(function()
		local labels = {}
		for _, face in FONT_FACES do
			local label = probeLabel(fonts.face(face.Role))
			table.insert(labels, label)
			preload(label)
			pcall(getfontbounds, 'NONE Aa '..tostring(fonts.Generation or 0), 16, fonts.face(face.Role))
		end
		task.wait(0.25)
		for _, label in labels do
			label:Destroy()
		end
		if not (slinky.gui and slinky.gui.Parent) then return end
		if changed then
			table.clear(measureCache)
			table.clear(measureOld)
			measureCount = 0
		end
		fonts.Generation = (fonts.Generation or 0) + 1
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

--[[ Picks the face the menu starts in, then checks it behind the menu, off the injection frame. The
Inter files are used from the start when getcustomasset works, all four are present and no failure
is recorded; otherwise the library Inter when it drew last time. All four faces are set or none: a
face that throws part way puts the fallback back.

Every face is measured against this client's own BuilderSans, the saved fallback, never
uipallet.Font: that is already Inter when the menu started in it, and Inter measured against itself
reads as not Inter, which would switch the face on every inject. The files come first, the family
extension that served last time tried first. A face in use that measures wrong counts as a failure
in FAILURE_FILE, whatever the other extension measured, and after 3 the files are not used. Where
the files do not draw, Roblox's library Inter, the Creator Store family 12187365364, is checked. A
check that could measure nothing keeps what drew last time, except files the menu started in that
measured wrong or went missing; a face in use that did not draw gives BuilderSans until the next
inject. Developer builds write the log to load-status.txt. ]]
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
	local function useFaces(build)
		if pcall(setFaces, build) then return true end
		pcall(setFaces, fallbackFace)
		return false
	end
	local function apply(build)
		if not (slinky.gui and slinky.gui.Parent) then return end
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
		fonts.settle()
	end

	task.spawn(function()
		task.wait()
		local log = {'probe '..PROBE..' expects '..PROBE_INTER, 'start='..(early or 'BuilderSans')}

		local calibrationLabel = probeLabel(fallback.Regular)
		local calibration = {Service = measureService(fallback.Regular), Label = measureLabel(calibrationLabel)}
		calibrationLabel:Destroy()
		table.insert(log, 'BuilderSans='..fmt(calibration.Service)..'/'..fmt(calibration.Label)..' (expects 299.4; Inter is 1.134x it)')

		local fileOutcome, keepInUse = 'skipped', false
		if filesUsable() then
			pcall(function()
				if not isfolder(FONT_DIR) then makefolder(FONT_DIR) end
			end)
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
								fonts.settle()
							else
								apply(fileFaces(id))
							end
							break
						elseif verdict == 'unknown' then
							if inUse then
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
				if fileOutcome == 'failed' or (inUseFailed and fileOutcome ~= 'ok') then
					pcall(writefile, FAILURE_FILE, tostring(fontFailures() + 1))
				end
			else
				table.insert(log, 'files=missing')
			end
		end

		if not (fileOutcome == 'ok' or keepInUse) then
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
				fonts.settle()
			elseif early then
				remember('none')
				apply(fallbackFace)
			end
		end

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

--[[ A TextLabel (or TextButton/TextBox via props.Class) in one of the four Inter weights. Size is in
em px, as Slinky's sizes are measured, and drawn through theme.em. TextSize is for text sized in
Roblox's own units instead (the HUD's own widgets), and is set as it is. ]]
function ui.text(parent, props)
	props = props or {}
	local className = props.Class or 'TextLabel'
	local label = Instance.new(className)
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.FontFace = fonts.face(props.Weight or 'Medium')
	label.TextColor3 = props.Color or theme.Label
	label.TextSize = props.TextSize or theme.em(props.Size or 14)
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
	if className == 'TextBox' then
		ui.caret(label)
	end
	if parent then label.Parent = parent end
	return label
end

--[[ A text box's caret, as Slinky's (the owner's recording, 2026-11-10): a 2 px bar at half the text's
strength that fades out and back in on a cosine once every 0.785 s, and is solid again whenever the text,
the cursor or the selection moves. Roblox draws its own caret, faster, and has no setting for its rate, so
a box made here draws none: its own text is fully transparent, which hides Roblox's caret, placeholder and
selection with it (checked live), and a label over it, Shown, shows the text, or the placeholder, in the
box's font, size, colours and alignment. Line, under Shown, is that text measured and laid where the box
lays its text. In it, Prefix is the part before the cursor, with the caret on its right edge, and Lead and
Span the parts before and inside the selection, Span drawn in Roblox's own selection blue (measured off
the live box), a line tall, with the text over it as Roblox draws it. The measures read spaces as no-break
spaces, which a layout never drops at the end of a line. Every write comes from a deferred sync or the
blink's frame step (ui.anim), never from inside a property signal. A transparency someone else gives the
box later is taken as Shown's, and the box goes back to fully transparent. ]]
local CARET_PERIOD, CARET_PEAK, CARET_WIDTH = 0.785, 0.5, 2
--[[ Clear of the letters (the owner's screenshot, 2026-11-10: on the line's start it cut through the
placeholder's S, whose curve starts a pixel left of the line). At the start of the line the caret's right
edge stands CARET_LEAD before it, a 2 px gap; after a letter, its left edge CARET_TRAIL past that letter. ]]
local CARET_LEAD, CARET_TRAIL = 3, 1
local CARET_SPACE = '\u{A0}'
local CARET_SELECTION = Color3.fromRGB(108, 162, 250)
-- What Shown takes from the box, and what the measures take (they stay left-aligned, unwrapped, untruncated).
local CARET_SHOWN = {'FontFace', 'TextSize', 'TextXAlignment', 'TextYAlignment', 'TextWrapped', 'TextTruncate', 'LineHeight', 'RichText'}
local CARET_MEASURE = {'FontFace', 'TextSize', 'LineHeight'}
local CARET_WATCH = {'PlaceholderText', 'PlaceholderColor3', 'TextColor3', 'TextTransparency', 'FontFace', 'TextSize',
	'TextXAlignment', 'TextYAlignment', 'TextWrapped', 'TextTruncate', 'LineHeight', 'RichText'}
--[[ Builds the drawn caret for a text box: the box's own text is hidden and drawn by a Shown label, with
Line under it holding the measures, the selection and the caret. Every write comes from a deferred
sync or the blink's frame step, never from inside a property signal. With nothing typed the
placeholder is measured, so a centred box's caret stands before it. The selection is the bytes
between SelectionStart and the cursor, from either end. Typing, moving the cursor or selecting makes
the caret solid again. ]]
function ui.caret(box)
	local textRest = box.TextTransparency or 0
	local shownRest
	local function part(className, name, parent)
		local obj = Instance.new(className)
		obj.Name = name
		obj.Active = false
		obj.BackgroundTransparency = 1
		obj.BorderSizePixel = 0
		obj.Parent = parent
		return obj
	end
	local line = part('Frame', 'Line', box)
	line.AutomaticSize = Enum.AutomaticSize.X
	line.Size = UDim2.fromScale(0, 1)
	line.ZIndex = 1
	local shown = part('TextLabel', 'Shown', box)
	shown.Size = UDim2.fromScale(1, 1)
	shown.ZIndex = 2
	local function measure(name, parent)
		local label = part('TextLabel', name, parent)
		label.AutomaticSize = Enum.AutomaticSize.X
		label.RichText = false
		label.Size = UDim2.fromScale(0, 1)
		label.Text = ''
		label.TextTransparency = 1
		label.TextWrapped = false
		label.TextXAlignment = Enum.TextXAlignment.Left
		return label
	end
	local full, prefix = measure('Full', line), measure('Prefix', line)
	local selection = part('Frame', 'Selection', line)
	selection.AutomaticSize = Enum.AutomaticSize.X
	selection.Size = UDim2.fromScale(0, 1)
	local flow = Instance.new('UIListLayout')
	flow.FillDirection = Enum.FillDirection.Horizontal
	flow.SortOrder = Enum.SortOrder.LayoutOrder
	flow.VerticalAlignment = Enum.VerticalAlignment.Center
	flow.Parent = selection
	local lead, span = measure('Lead', selection), measure('Span', selection)
	lead.LayoutOrder, span.LayoutOrder = 1, 2
	span.BackgroundColor3 = CARET_SELECTION
	local caret = part('Frame', 'Caret', prefix)
	caret.AnchorPoint = Vector2.new(0, 0.5)
	caret.Visible = false
	box.TextTransparency = 1

	local function sync()
		local own = box.TextTransparency
		if type(own) == 'number' and own < 1 then
			textRest = own
			box.TextTransparency = 1
		end
		if textRest ~= shownRest then
			shownRest = textRest
			shown.TextTransparency = textRest
		end
		for _, prop in CARET_SHOWN do
			pcall(function()
				shown[prop] = box[prop]
			end)
		end
		for _, prop in CARET_MEASURE do
			pcall(function()
				local value = box[prop]
				full[prop] = value
				prefix[prop] = value
				lead[prop] = value
				span[prop] = value
			end)
		end
		local text = box.Text or ''
		local placeholder = text == ''
		shown.Text = placeholder and (box.PlaceholderText or '') or text
		shown.TextColor3 = placeholder and box.PlaceholderColor3 or box.TextColor3
		full.Text = (shown.Text:gsub(' ', CARET_SPACE))
		local cursor = box.CursorPosition
		local before = text
		if type(cursor) == 'number' and cursor >= 1 then
			before = text:sub(1, cursor - 1)
		end
		prefix.Text = (before:gsub(' ', CARET_SPACE))
		local anchor = box.SelectionStart
		local from, to
		if type(anchor) == 'number' and anchor >= 1 and type(cursor) == 'number' and cursor >= 1 and anchor ~= cursor then
			from, to = math.min(anchor, cursor), math.max(anchor, cursor)
		end
		lead.Text = from and (text:sub(1, from - 1):gsub(' ', CARET_SPACE)) or ''
		span.Text = from and (text:sub(from, to - 1):gsub(' ', CARET_SPACE)) or ''
		span.BackgroundTransparency = from and 0 or 1
		span.Size = UDim2.fromOffset(0, box.TextSize or 14)
		local alignX = box.TextXAlignment
		if alignX == Enum.TextXAlignment.Center then
			line.AnchorPoint, line.Position = Vector2.new(0.5, 0), UDim2.fromScale(0.5, 0)
		elseif alignX == Enum.TextXAlignment.Right then
			line.AnchorPoint, line.Position = Vector2.new(1, 0), UDim2.fromScale(1, 0)
		else
			line.AnchorPoint, line.Position = Vector2.new(0, 0), UDim2.new()
		end
		local size = box.TextSize or 14
		caret.Size = UDim2.fromOffset(CARET_WIDTH, math.floor(size * 1.15 + 0.5))
		local alignY = box.TextYAlignment
		local scaleY, offsetY = 0.5, 0
		if alignY == Enum.TextYAlignment.Top then
			scaleY, offsetY = 0, math.floor(size / 2 + 0.5)
		elseif alignY == Enum.TextYAlignment.Bottom then
			scaleY, offsetY = 1, -math.floor(size / 2 + 0.5)
		end
		if before == '' then
			caret.AnchorPoint = Vector2.new(1, 0.5)
			caret.Position = UDim2.new(1, -CARET_LEAD, scaleY, offsetY)
		else
			caret.AnchorPoint = Vector2.new(0, 0.5)
			caret.Position = UDim2.new(1, CARET_TRAIL, scaleY, offsetY)
		end
		caret.BackgroundColor3 = box.TextColor3
	end
	local queued = false
	local function queue()
		if queued then return end
		queued = true
		task.defer(function()
			queued = false
			sync()
		end)
	end

	local blink = {Owner = box, T = 0}
	function blink.Step(dt)
		blink.T += dt
		if not caret.Visible then
			caret.Visible = true
		end
		caret.BackgroundTransparency = 1 - CARET_PEAK * (0.5 + 0.5 * math.cos(2 * math.pi * blink.T / CARET_PERIOD))
	end
	function blink.Finish()
		caret.Visible = false
		caret.BackgroundTransparency = 1
	end
	local function moved()
		blink.T = 0
		queue()
	end
	box:GetPropertyChangedSignal('Text'):Connect(moved)
	for _, prop in {'CursorPosition', 'SelectionStart'} do
		pcall(function()
			box:GetPropertyChangedSignal(prop):Connect(moved)
		end)
	end
	for _, prop in CARET_WATCH do
		pcall(function()
			box:GetPropertyChangedSignal(prop):Connect(queue)
		end)
	end
	box.Focused:Connect(function()
		blink.T = 0
		queue()
		ui.anim.play(caret, blink)
	end)
	box.FocusLost:Connect(function()
		ui.anim.stop(caret, true)
	end)
	sync()
end

--[[ What is lit under the pointer, each with how to set it back. Showing or hiding the menu under a
hovered element sends it no leave, so the menu's Visible handler puts all of it back to rest. ]]
ui.hovered = setmetatable({}, {__mode = 'k'})
function ui.restHovered()
	local resting = ui.hovered
	ui.hovered = setmetatable({}, {__mode = 'k'})
	for _, rest in resting do
		pcall(rest)
	end
end

--[[
	Motion: one RenderStepped driver for everything that follows a target or plays for a set time,
	in the menu and on the HUD, on Slinky's measured curves (slinky_anim/ANIM_SPEC.md). It is
	connected only while something moves. An entry owned by the menu jumps to its end the moment the
	menu is shut or its owner is off screen, so a shut menu costs nothing; only HUD entries step while
	it is shut.

	An entry is {Owner = a GuiObject (menu entries), Hud = true (HUD entries), Step = function(dt)
	that returns true when done, Finish = function() that sets the end state}. play only registers
	it, so it is safe from any handler, a property signal included: the first step comes next frame.
]]
ui.anim = {Active = {}}
--[[ ui.anim: the one RenderStepped loop every menu motion runs on. anim.follow eases towards a target
the same way at 60 fps as at 144; the curves are written out because TweenService:GetValue is not on
every client. An entry whose owner is not on screen is put at its end instead of stepped, unless it
is a Hud entry, and the connection goes as soon as nothing moves.

The connection is made deferred, never inside the handler that asked, and an entry whose owner is
off screen by then, such as an open card's settings resizing with the menu shut, is finished there
and costs no connection. stop with finish sets the end state now: for direct callers, never from a
property signal. anim.Connected is false whenever nothing is moving, for checking the idle cost. ]]
do
	local anim = ui.anim
	local connection, queued = nil, false

	function anim.follow(x, target, lambda, dt)
		return target + (x - target) * math.exp(-lambda * dt)
	end
	function anim.sineInOut(u)
		return 0.5 - math.cos(math.pi * u) / 2
	end
	function anim.quintOut(u)
		return 1 - (1 - u) ^ 5
	end

	function anim.onScreen(obj)
		if not (clickgui and clickgui.Visible) then return false end
		local node = obj
		while node and node ~= clickgui do
			if node:IsA('GuiObject') and not node.Visible then return false end
			node = node.Parent
		end
		return node == clickgui
	end

	local function disconnect()
		if connection then
			connection:Disconnect()
			connection = nil
		end
	end

	local function step(dt)
		if slinky.loaded == nil then
			disconnect()
			table.clear(anim.Active)
			return
		end
		local keys = {}
		for key in anim.Active do
			table.insert(keys, key)
		end
		for _, key in keys do
			local entry = anim.Active[key]
			if entry then
				local done = true
				if not entry.Hud and not (entry.Owner and anim.onScreen(entry.Owner)) then
					pcall(entry.Finish)
				else
					local ok, result = pcall(entry.Step, dt)
					if ok then
						done = result == true
					else
						pcall(entry.Finish)
					end
				end
				if done and anim.Active[key] == entry then
					anim.Active[key] = nil
				end
			end
		end
		if next(anim.Active) == nil then
			disconnect()
		end
	end

	local function wake()
		if connection or queued then return end
		queued = true
		task.defer(function()
			queued = false
			if slinky.loaded == nil then return end
			if slinky.threadFix then
				setthreadidentity(8)
			end
			if connection then return end
			for key, entry in table.clone(anim.Active) do
				if anim.Active[key] == entry and not entry.Hud and not (entry.Owner and anim.onScreen(entry.Owner)) then
					pcall(entry.Finish)
					if anim.Active[key] == entry then
						anim.Active[key] = nil
					end
				end
			end
			if next(anim.Active) ~= nil and not connection then
				connection = runService.RenderStepped:Connect(step)
			end
		end)
	end

	function anim.play(key, entry)
		anim.Active[key] = entry
		wake()
	end

	function anim.stop(key, finish)
		local entry = anim.Active[key]
		anim.Active[key] = nil
		if entry and finish then
			pcall(entry.Finish)
		end
	end

	function anim.playing(key)
		return anim.Active[key] ~= nil
	end

	function anim.Connected()
		return connection ~= nil
	end
end

--[[
	Fading part of the menu by its own properties, with no CanvasGroup. A group draws everything in it
	into one texture -- scaled down, so blurred, past the texture limit -- and draws that again every
	frame it changes. Here each showing part goes from the value it rests at towards nothing,
	rest + (1 - rest) * hidden, written by the frame step of the motion the fade belongs to
	(ui.anim), never from a property signal.

	A page is taken a card at a time, and an open card's settings a row at a time (fade.split), and
	only the cards and rows on screen in it are kept, so a long page, or a card taller than the page,
	costs what shows of it. A page just shown can still report where its cards were a layout pass
	ago, so everything showing is taken at first, and a card or row is let go -- put back at its
	rest -- only once a frame has been drawn since and it is off the page. One that comes on screen
	part way, scrolled to, is taken by the next draw; one the deferred layout pass places that the
	fade has not had yet (fade.placed) is taken at once.

	The fade owns a property only while it holds what the fade wrote there. Anything else that sets
	it part way -- a hover, a toggle, the theme -- shows on the next frame as a value the fade did not
	write, and that is its rest from then on; the end puts the rest back only where the fade still
	owns it. A part resting fully transparent is not taken: there is nothing of it to fade. A hidden
	object is, on its own, as a hover or an icon can show it part way, but nothing under it is.

	A set is made with new, given parts with add (a part of the window and all that shows in it) and
	page (a scrolling page, a card at a time), drawn each frame with draw(set, hidden) -- 0 at rest,
	1 nothing showing -- and ended with finish, which also serves a fade cut short.
]]
ui.fade = {}
--[[ The fade's internals and its calls (new, add, page, split, draw, watched, placed, finish). KIND
names the transparency properties each class fades; a corner, a list or a scale is passed over. The
values are stored as floats, so one within SAME of what was written is the fade's own; anything else
is someone else's write and becomes the part's rest.

A card or row is let go as off the page only SETTLE draws after it was taken, so a frame has been
laid out in between, and taken again when a draw finds it back on. A card let go takes its settings
rows with it, as its body clips them. On the page means across the page's own width, which slides
with a tab switch, and down the screen: a page has no scrolling frame of its own, so the screen's
edges are all that cut it. fade.split marks a card's settings body to be taken a row at a time, so
an open card taller than the page costs what shows of it.

fade.placed runs after the deferred layout pass (layout.place), never inside a property signal: a
fade under way takes each showing card it has not had yet at the point the fade has got to, rather
than a frame later drawn in full. A card let go stays let go until a draw finds it on screen, since
taking the whole page again costs every card on it on each frame a pass runs, as one does on every
frame of a load registering modules. A moved card is taken again, with its rows, when it lands at an
end of its column or beside a card that has settled on the page. fade.finish, for the end or a fade
cut short, puts each part it still owns back at its rest exactly. ]]
do
	local fade = ui.fade
	local TEXT = {'BackgroundTransparency', 'TextTransparency', 'TextStrokeTransparency'}
	local IMAGE = {'BackgroundTransparency', 'ImageTransparency'}
	local SCROLL = {'BackgroundTransparency', 'ScrollBarImageTransparency'}
	local PLAIN = {'BackgroundTransparency'}
	local STROKE = {'Transparency'}
	local KIND = {
		TextLabel = TEXT, TextButton = TEXT, TextBox = TEXT,
		ImageLabel = IMAGE, ImageButton = IMAGE,
		ScrollingFrame = SCROLL,
		Frame = PLAIN, ViewportFrame = PLAIN, VideoFrame = PLAIN,
		UIStroke = STROKE
	}
	local SAME = 1e-6
	local SETTLE = 2
	local watching = setmetatable({}, {__mode = 'k'})
	local bodies = setmetatable({}, {__mode = 'k'})

	local function inView(obj, at, size)
		local pos, extent = obj.AbsolutePosition, obj.AbsoluteSize
		return pos.X <= at.X + size.X and pos.Y <= at.Y + size.Y
			and pos.X + extent.X >= at.X and pos.Y + extent.Y >= at.Y
	end

	local function own(parts, obj, props)
		for _, prop in props do
			local rest = obj[prop]
			if type(rest) == 'number' and rest < 1 then
				table.insert(parts, {obj, prop, rest})
			end
		end
	end

	local function walk(parts, obj, props, rows)
		own(parts, obj, props)
		if not obj.Visible then return end
		for _, child in obj:GetChildren() do
			local kind = KIND[child.ClassName]
			if kind == STROKE then
				if child.Enabled then
					own(parts, child, kind)
				end
			elseif kind and rows and bodies[child] then
				own(parts, child, kind)
				rows[obj] = child
			elseif kind then
				walk(parts, child, kind)
			end
		end
	end

	local function write(parts, hidden)
		for _, part in parts do
			local obj, prop = part[1], part[2]
			local now = obj[prop]
			local written = part[4]
			if written ~= nil and math.abs(now - written) > SAME then
				part[3] = now
			end
			local rest = part[3]
			local value = rest + (1 - rest) * hidden
			if math.abs(value - now) > SAME then
				obj[prop] = value
			end
			part[4] = value
		end
	end

	local function restore(part)
		local written = part[4]
		if written == nil then return end
		local obj, prop, rest = part[1], part[2], part[3]
		local now = obj[prop]
		if math.abs(now - written) <= SAME and now ~= rest then
			obj[prop] = rest
		end
	end
	local function release(parts)
		for _, part in parts do
			pcall(restore, part)
		end
	end

	local function take(set, unit, kind, whole)
		local parts = {}
		if whole then
			walk(parts, unit, kind, set.Rows)
		else
			own(parts, unit, kind)
		end
		set.Units[unit] = parts
		set.Taken[unit] = set.Frame
		set.Off[unit] = nil
	end

	local function consider(set, unit, kind, whole, at, size)
		if set.Units[unit] then
			if at and set.Frame - set.Taken[unit] >= SETTLE and not inView(unit, at, size) then
				release(set.Units[unit])
				set.Units[unit] = nil
				set.Off[unit] = true
				local body = set.Rows[unit]
				if body then
					for _, row in body:GetChildren() do
						local parts = set.Units[row]
						if parts then
							release(parts)
							set.Units[row] = nil
							set.Off[row] = true
						end
					end
				end
			end
		elseif not set.Off[unit] then
			take(set, unit, kind, whole)
		elseif at and inView(unit, at, size) then
			take(set, unit, kind, whole)
		end
	end

	local function scan(set, page, settled)
		local at, size
		if settled then
			local corner, extent = page.AbsolutePosition, page.AbsoluteSize
			local screenAt, screen = clickgui.AbsolutePosition, clickgui.AbsoluteSize
			at, size = Vector2.new(corner.X, screenAt.Y), Vector2.new(extent.X, screen.Y)
		end
		for _, column in page:GetChildren() do
			local kind = KIND[column.ClassName]
			if kind and kind ~= STROKE and column.Visible then
				consider(set, column, kind, false, at, size)
				for _, card in column:GetChildren() do
					local cardKind = KIND[card.ClassName]
					if cardKind == STROKE then
						if not set.Units[card] and card.Enabled then
							take(set, card, cardKind, false)
						end
					elseif cardKind and card.Visible then
						consider(set, card, cardKind, true, at, size)
						local body = set.Units[card] and set.Rows[card]
						if body and body.Visible then
							for _, row in body:GetChildren() do
								local rowKind = KIND[row.ClassName]
								if rowKind and rowKind ~= STROKE and row.Visible then
									consider(set, row, rowKind, true, at, size)
								end
							end
						end
					end
				end
			end
		end
	end

	function fade.new()
		return {Units = {}, Taken = {}, Off = {}, Rows = {}, Pages = {}, Frame = 0}
	end

	function fade.split(body)
		bodies[body] = true
	end

	function fade.add(set, obj)
		local kind = KIND[obj.ClassName]
		if kind == STROKE then
			if obj.Enabled then
				take(set, obj, kind, false)
			end
		elseif kind then
			take(set, obj, kind, true)
		end
	end

	function fade.page(set, page)
		table.insert(set.Pages, page)
		watching[page] = set
	end

	function fade.draw(set, hidden)
		set.Frame += 1
		set.Hidden = hidden
		for _, page in set.Pages do
			scan(set, page, true)
		end
		for _, parts in set.Units do
			write(parts, hidden)
		end
	end

	function fade.watched(page)
		local set = watching[page]
		return set ~= nil and set.Hidden ~= nil
	end

	local function besideShown(set, neighbour)
		if neighbour == nil then return true end
		local taken = set.Units[neighbour] and set.Taken[neighbour]
		return taken ~= nil and set.Frame - taken >= SETTLE
	end

	function fade.placed(page, moved)
		local set = watching[page]
		if not (set and set.Hidden) then return end
		if moved then
			for _, entry in moved do
				local card = entry[1]
				if set.Off[card] and (besideShown(set, entry[2]) or besideShown(set, entry[3])) then
					set.Off[card] = nil
					local body = set.Rows[card]
					if body then
						for _, row in body:GetChildren() do
							set.Off[row] = nil
						end
					end
				end
			end
		end
		scan(set, page, false)
		for unit, parts in set.Units do
			if set.Taken[unit] == set.Frame then
				write(parts, set.Hidden)
			end
		end
	end

	function fade.finish(set)
		for _, parts in set.Units do
			release(parts)
		end
		for _, page in set.Pages do
			if watching[page] == set then
				watching[page] = nil
			end
		end
		table.clear(set.Units)
		table.clear(set.Taken)
		table.clear(set.Off)
		table.clear(set.Rows)
		table.clear(set.Pages)
		set.Hidden = nil
	end
end

--[[ Instant hover, Slinky's rule: entering lights at once and leaving puts it out at once, and never
on a touch screen, where a tap enters and never leaves. region(point), when given, narrows where on
gui the pointer lights it, and is checked again as the pointer moves. While a modal is open nothing
outside it lights, as the rows under its backdrop still get pointer events. Each one is registered,
so ui.restHovered can put it out and ui.rehover light it again. The registry is keyed by the entry,
which only gui's own connections hold, so a destroyed gui lets go of both. ]]
ui.hoverables = setmetatable({}, {__mode = 'k'})
--[[ Wires one hover and registers it in ui.hoverables. Disconnect is for a hover that ends before its
gui does, such as a reveal a setting turns off: its connections go and it leaves both registries
without calling leave, whose target may already be gone. The entry is shaped as a connection so it
can sit in a list of them. ]]
function ui.hover(gui, enter, leave, region)
	local entry = {Gui = gui, Lit = false}
	local function set(lit)
		if lit == entry.Lit then return end
		entry.Lit = lit
		if lit then
			ui.hovered[gui] = entry.Rest
			enter()
		else
			ui.hovered[gui] = nil
			leave()
		end
	end
	entry.Rest = function()
		set(false)
	end
	function entry.Check(inside)
		local lit = false
		if inside and not ui.lastInputTouch() then
			local modal = ui.modal
			if not (modal and modal.Parent and not gui:IsDescendantOf(modal)) then
				lit = region == nil or region(inputService:GetMouseLocation() + scaledgui.AbsolutePosition) == true
			end
		end
		set(lit)
	end
	local connections = {}
	table.insert(connections, gui.MouseEnter:Connect(function()
		entry.Check(true)
	end))
	if region then
		table.insert(connections, gui.MouseMoved:Connect(function()
			entry.Check(true)
		end))
	end
	table.insert(connections, gui.MouseLeave:Connect(function()
		entry.Check(false)
	end))
	function entry.Disconnect()
		for _, connection in connections do
			connection:Disconnect()
		end
		table.clear(connections)
		if ui.hovered[gui] == entry.Rest then
			ui.hovered[gui] = nil
		end
		entry.Lit = false
		ui.hoverables[entry] = nil
	end
	ui.hoverables[entry] = true
	return entry
end

--[[ After a modal closes: whatever is under the still pointer lights straight away -- in the menu a
row really showing (ui.rowShowing), outside it (an overlay window's pin) one shown all the way up to
the scaled layer. ]]
function ui.rehover()
	local point = inputService:GetMouseLocation() + scaledgui.AbsolutePosition
	for entry in ui.hoverables do
		local gui = entry.Gui
		if gui.Parent and ui.within(point, gui.AbsolutePosition, gui.AbsoluteSize) then
			local showing
			if gui:IsDescendantOf(clickgui) then
				showing = ui.rowShowing(gui, point)
			else
				local node = gui
				while node and node ~= scaledgui and not (node:IsA('GuiObject') and not node.Visible) do
					node = node.Parent
				end
				showing = node == scaledgui
			end
			if showing then
				entry.Check(true)
			end
		end
	end
end

--[[ A list's rows rebuilt under a still pointer (an entry added or taken away): after the click that
rebuilt them, what the pointer rests on now lights and what moved away from it goes out. Once per
frame, and only with the menu open. ]]
function ui.rehoverSoon()
	if ui.rehoverQueued then return end
	ui.rehoverQueued = true
	task.defer(function()
		ui.rehoverQueued = false
		if slinky.loaded == nil or not (clickgui and clickgui.Visible) then return end
		if slinky.threadFix then
			setthreadidentity(8)
		end
		ui.restHovered()
		ui.rehover()
	end)
end

-- Run at the end of the frame the menu is shut in (its Visible handler, build.gui).
ui.shutHooks = {}
function ui.whenShut(fn)
	table.insert(ui.shutHooks, fn)
end

--[[ Run at the end of the frame the menu is opened or shut in, by the same deferred handler, with the
identity raised: whatever shows, hides or recolours with the menu writes here, after the change, and
never inside the write to Visible. ]]
ui.menuHooks = {}
function ui.whenMenu(fn)
	table.insert(ui.menuHooks, fn)
end

-- An icon's colour, written straight to its image and to its fallback character.
function ui.paintIcon(holder, value)
	local image = holder:FindFirstChild('Glyph')
	if image then
		image.ImageColor3 = value
	end
	holder.TextColor3 = value
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

--[[ Returns an icon's file content id, or '' to draw the fallback character. Never waits on the network:
a missing file is fetched from the pistonware repo on a deferred thread, and the icons showing the
fallback are redrawn once it lands. A download that is not a PNG (an error page) is deleted so the
next inject fetches again; a real PNG the executor will not serve is kept. Phones and executors
without getcustomasset always get ''. In developer mode an icon file with content is never replaced.
]]
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
			if shared.PistonwareDeveloper == true then
				local ok, body = pcall(readfile, path)
				if ok and type(body) == 'string' and body ~= '' then return end
			end
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

--[[ Shows an icon's image on holder, or its ICON_FALLBACK character where there is no image. A content
id the client rejects falls back to the character rather than failing the build. ]]
function ui.setIcon(holder, name)
	local entry = fonts.Registry[holder]
	if entry then entry.Icon = name end
	local id = iconImage(name)
	local image = holder:FindFirstChild('Glyph')
	if image then
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

--[[ Makes an icon: a text holder for the fallback character with a Glyph image in it, registered in
fonts.Registry. The image follows the holder's TextColor3, so a caller that sets that colour (a
game's own icon) colours both. The menu's own icons that change colour pass NoMirror and are painted
through ui.paintIcon, so a hover writes nothing inside a property signal. ]]
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
	if not props.NoMirror then
		holder:GetPropertyChangedSignal('TextColor3'):Connect(function()
			image.ImageColor3 = holder.TextColor3
		end)
	end
	for key, value in props.Props or {} do
		holder[key] = value
	end
	fonts.Registry[holder] = {Icon = name, Size = size}
	ui.setIcon(holder, name)
	if parent then holder.Parent = parent end
	return holder
end

--[[ Slinky's pill switch: the accent track with the dark knob on the right when on, a grey track with
the knob on the left when off. Knob and track move on one progress over 0.1 s, Sine InOut; a click
mid-motion turns it round from where it is, and where nobody can see it (a shut menu, another tab)
it goes to the end at once. The off grey lightens under the pointer, mid-motion too; the on colour
does not. ]]
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
	local u, dir, hovered, accentColor = 0, -1, false, nil
	local function apply()
		local p = ui.anim.sineInOut(u)
		knob.Position = UDim2.new(0, math.floor(2 + 20 * p + 0.5), 0.5, 0)
		track.BackgroundColor3 = (hovered and theme.TrackOffHover or theme.TrackOff):Lerp(accentColor or theme.Accent(), p)
	end
	local motion = {
		Owner = track,
		Step = function(dt)
			u = math.clamp(u + dir * dt / theme.SwitchTime, 0, 1)
			apply()
			return u == (dir > 0 and 1 or 0)
		end,
		Finish = function()
			u = dir > 0 and 1 or 0
			apply()
		end
	}
	function switch:Set(enabled, accent)
		self.Enabled = enabled
		accentColor = accent or theme.Accent()
		dir = enabled and 1 or -1
		if u == (enabled and 1 or 0) or not ui.anim.onScreen(track) then
			ui.anim.stop(track)
			u = enabled and 1 or 0
			apply()
		else
			ui.anim.play(track, motion)
		end
	end
	ui.hover(track, function()
		hovered = true
		if not ui.anim.playing(track) then apply() end
	end, function()
		hovered = false
		if not ui.anim.playing(track) then apply() end
	end)
	function switch:Color(accent)
		accentColor = accent
		if self.Enabled and not ui.anim.playing(track) then
			track.BackgroundColor3 = accent
		end
	end
	return switch
end

--[[ The small rounded-square button that expands a card or a row: + closed, - open. The press is taken
by the whole line the square sits on, the description beside it included, so a thumb that lands next
to the square on a phone opens the card instead of switching the module. Slinky's own + and - images
show where this client shows icon files; elsewhere two bars draw the same pixels, so an image that
lands later looks no different. Under the pointer the square lightens and its glyph goes white, at
once.

opts.Lit(lit) is told whenever the square lights or goes out, so a card's description lights with
it; opts.Region(point, square) narrows where the pointer lights it. The hover entry is returned too,
so a card can put its light out when the square goes. ]]
function ui.expander(parent, position, opts)
	opts = opts or {}
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
	local horizontal = bar(0)
	local upright = bar(90)
	local icon = ui.icon(square, 'slinky-plus', 16, {Color = theme.Text, NoMirror = true, Box = UDim2.fromOffset(16, 16), Props = {
		Name = 'Png', AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5)
	}})
	local isOpen = false
	local function syncGlyph()
		local image = icon:FindFirstChild('Glyph')
		local drawn = image ~= nil and image.Visible
		horizontal.Visible = not drawn
		upright.Visible = not drawn and not isOpen
	end
	syncGlyph()
	local glyph = {}
	function glyph:Set(open)
		isOpen = open == true
		ui.setIcon(icon, isOpen and 'slinky-minus' or 'slinky-plus')
		syncGlyph()
	end
	local function paint(lit)
		local ink = lit and theme.Lit or theme.Text
		square.BackgroundColor3 = lit and theme.PillHover or theme.Pill
		horizontal.BackgroundColor3 = ink
		upright.BackgroundColor3 = ink
		ui.paintIcon(icon, ink)
		if opts.Lit then
			opts.Lit(lit)
		end
	end
	local region = opts.Region and function(point)
		return opts.Region(point, square)
	end or nil
	local hover = ui.hover(button, function()
		paint(true)
	end, function()
		paint(false)
	end, region)
	return button, glyph, hover
end

-- A row inside a card: transparent, full width, label on the left.
function ui.row(children, props, height)
	local row = ui.new('Frame', {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		LayoutOrder = props.order or 0,
		Size = UDim2.new(1, 0, 0, height or theme.RowHeight),
		Visible = props.visible == nil or props.visible
	}, children)
	return row
end

-- reserve: the width the control on the right needs, for rows whose control is small (a switch,
-- a badge, a swatch); without one the label gets half the row.
function ui.rowLabel(row, props, reserve)
	local indent = theme.Inset
	return ui.text(row, {
		Text = props.label or props.name or '',
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
	ui.corner(pill, props.Radius or UDim.new(1, 0))
	ui.stroke(pill, theme.Outline, props.Thickness or 2, 0)
	if parent then pill.Parent = parent end
	return pill
end

-- Text that a card shows on one line: the first line of a tooltip, without its markup.
function ui.firstLine(text)
	if type(text) ~= 'string' or text == '' then return '' end
	text = removeTags(text)
	return (text:match('^([^\n]*)') or text)
end

--[[ The confirmation every destructive action goes through: a card at the top of the screen with 'Are
you sure?', what is about to happen and a red Continue. A click off the card, the X or Escape
cancels and leaves the menu up. It comes in as Slinky's does, over 0.3 s Quint Out: the card drops
its last 48 px in its own zoom and fades in while the backdrop greys the screen out to 0.75. It goes
at once, the action starts right after, and hints and hover come back for whatever the pointer rests
on.

A body too long for one line wraps onto up to four lines and the card grows 19 px a line. Each part
fades on its own rather than in a CanvasGroup, which old phone clients do not have. The rows under
the backdrop still get pointer events, so ui.modal keeps everything outside the card from lighting
meanwhile. ]]
function ui.confirm(body, onContinue, continueText)
	if not clickgui then return end
	ui.hideTips()
	ui.restHovered()
	local zoom = layout and layout.Zoom or 1
	local cardWidth = math.clamp(viewportWidth() / (math.max(scale.Scale, 0.05) * zoom) - 24, 260, 576)
	local lines = 1
	pcall(function()
		local size, face = theme.em(15), fonts.face('Medium')
		local height, wrapped = ui.wrappedHeight(body, size, face, cardWidth - 24)
		if wrapped then
			lines = math.clamp(math.floor(height / math.max(getfontbounds(body, size, face).Y, 1) + 0.5), 2, 4)
		end
	end)
	local wraps = lines > 1
	local extra = (lines - 1) * 19
	local top = layout and layout.Top or 12
	local blocker = ui.new('TextButton', {
		Name = 'Confirm',
		AutoButtonColor = false,
		BackgroundColor3 = theme.Backdrop,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Text = '',
		ZIndex = 20
	}, clickgui)
	ui.modal = blocker
	local card = ui.new('TextButton', {
		AutoButtonColor = false,
		AnchorPoint = Vector2.new(0.5, 0),
		BackgroundColor3 = theme.Bar,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.new(0.5, 0, 0, top - math.floor(48 * zoom + 0.5)),
		Size = UDim2.fromOffset(cardWidth, 120 + extra),
		Text = '',
		ZIndex = 21
	}, blocker)
	ui.corner(card, 20)
	ui.new('UIScale', {Scale = zoom}, card)
	local heading = ui.text(card, {Text = 'Are you sure?', Size = 16, Weight = 'Medium', Color = theme.Text, Props = {
		Position = UDim2.fromOffset(12, 11), Size = UDim2.new(1, -60, 0, 20), TextTransparency = 1, ZIndex = 22
	}})
	local message = ui.text(card, {Text = body, Size = 15, Color = theme.Text, Props = {
		Position = UDim2.fromOffset(12, 44), Size = UDim2.new(1, -24, 0, 20 + extra), TextTransparency = 1, ZIndex = 22,
		TextTruncate = Enum.TextTruncate.AtEnd, TextWrapped = wraps
	}})
	local close = ui.icon(card, 'slinky-x', 16, {Class = 'TextButton', Color = theme.SubText, NoMirror = true, Box = UDim2.fromOffset(24, 24), Props = {
		AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -10, 0, 10), TextTransparency = 1, ZIndex = 22
	}})
	local closeEntry = fonts.Registry[close]
	if closeEntry then
		closeEntry.Size = 21
		ui.setIcon(close, 'slinky-x')
	end
	close.Glyph.ImageTransparency = 1
	close.Glyph.ZIndex = 22
	local continue = ui.text(card, {Class = 'TextButton', Text = continueText or 'Continue', Size = 15, Weight = 'Medium',
		Color = Color3.new(1, 1, 1), AlignX = Enum.TextXAlignment.Center, Props = {
			BackgroundColor3 = theme.Red, BackgroundTransparency = 1, TextTransparency = 1,
			Position = UDim2.fromOffset(12, 78 + extra), Size = UDim2.new(1, -24, 0, 30), ZIndex = 22
		}})
	ui.corner(continue, 5)

	tween:Tween(blocker, theme.ModalInfo, {BackgroundTransparency = 0.25}, 'modal')
	tween:Tween(card, theme.ModalInfo, {Position = UDim2.new(0.5, 0, 0, top), BackgroundTransparency = 0}, 'modal')
	tween:Tween(heading, theme.ModalInfo, {TextTransparency = 0}, 'modal')
	tween:Tween(message, theme.ModalInfo, {TextTransparency = 0}, 'modal')
	tween:Tween(close, theme.ModalInfo, {TextTransparency = 0}, 'modal')
	tween:Tween(close.Glyph, theme.ModalInfo, {ImageTransparency = 0}, 'modal')
	tween:Tween(continue, theme.ModalInfo, {BackgroundTransparency = 0, TextTransparency = 0}, 'modal')

	ui.hover(close, function()
		ui.paintIcon(close, theme.RedHover)
	end, function()
		ui.paintIcon(close, theme.SubText)
	end)
	ui.hover(continue, function()
		continue.BackgroundColor3 = theme.RedHover
	end, function()
		continue.BackgroundColor3 = theme.Red
	end)

	local function dismiss()
		ui.popEscape(blocker)
		if ui.modal == blocker then
			ui.modal = nil
		end
		blocker:Destroy()
		task.defer(function()
			if slinky.loaded == nil then return end
			if slinky.threadFix then
				setthreadidentity(8)
			end
			ui.refreshTooltip()
			ui.rehover()
		end)
	end
	blocker.MouseButton1Click:Connect(dismiss)
	close.MouseButton1Click:Connect(dismiss)
	continue.MouseButton1Click:Connect(function()
		dismiss()
		task.spawn(onContinue)
	end)
	ui.pushEscape(blocker, dismiss)
	return blocker
end

--[[
	Escape, as in Slinky: it closes the menu inside the menu that is open -- a confirmation, a colour
	picker, an item search, an open dropdown, the module search -- and leaves the menu up; with none
	open it shuts the menu, exactly as the menu's key does. Each inner menu puts how it closes on this
	stack when it opens, newest on top, and takes it off when it closes, however it closes. Roblox's
	own menu may still open on the same press; nothing here stops it. One press can be reported three
	ways -- the key, Roblox's menu opening (GuiService.MenuOpened, for a client where the key never
	arrives) and a text box losing the keyboard to it -- so the first report acts and the others of
	that press are ignored: one press never closes both an inner menu and the menu. Roblox's menu
	opening and an Escape key going down within 0.1 s of each other, in either order, are one press,
	unless the opening was nearer the key before. A press after it is a press of its own, however
	soon it comes.
]]
ui.escapes = {}
-- When an Escape last acted, a click or tap began, an Escape key went down, a text box let go of the
-- keyboard, and Roblox's menu opened and shut (os.clock).
ui.escapeAt, ui.escapePress, ui.escapeKey, ui.escapeFocus, ui.escapeMenuAt, ui.escapeMenuShut = -1, -1, -1, -1, -1, -1
-- When the Escape key before the latest one went down (-1: none).
ui.escapeKeyPrev = -1
-- The press the last action was, by when its key went down (-1: a report that came before its key,
-- or with none), and the text box that last let go of the keyboard.
ui.escapeActed, ui.escapeFocusBox = -1, nil

-- owner: what the inner menu is (its backdrop); live(), when given, says whether it is still open.
function ui.pushEscape(owner, close, live)
	ui.popEscape(owner)
	table.insert(ui.escapes, {Owner = owner, Close = close, Live = live})
end

function ui.popEscape(owner)
	for index = #ui.escapes, 1, -1 do
		if ui.escapes[index].Owner == owner then
			table.remove(ui.escapes, index)
		end
	end
end

-- The newest inner menu still open; one that went without saying so (destroyed, hidden) is dropped.
function ui.escapeTop()
	for index = #ui.escapes, 1, -1 do
		local entry = ui.escapes[index]
		local open = not (typeof(entry.Owner) == 'Instance' and entry.Owner.Parent == nil)
		if open and entry.Live then
			local ok, live = pcall(entry.Live)
			open = ok and live == true
		end
		if open then
			return entry
		end
		table.remove(ui.escapes, index)
	end
	return nil
end

--[[ Handles one report of an Escape press: 'key' (pressAt: when its key went down), 'menu' (Roblox's
menu opened) or 'focus' (a text box in an inner menu lost the keyboard). Returns whether it closed
something: the newest inner menu, else the open lists, else the menu itself, which shuts exactly as
its key shuts it. Never with the menu shut, and not while a bind waits for a key: there Escape
clears the bind.

One press can come as several reports, so each is matched to its key. Roblox can report its menu
opening up to 0.1 s before the key, and a box letting go or the menu opening can come up to 0.35 s
after it; a report with no key that close, within 0.35 s of an Escape that acted, is that Escape's.
The press that shuts Roblox's menu, opened by an earlier one, is that menu's. With no keyboard, or a
click or tap within 0.6 s and Escape not held, Roblox's menu was opened from its button. Typing in a
box, Escape only takes the keyboard away, unless the box is the newest inner menu's own (its search
or hex box), whose menu it closes. ]]
function ui.escape(source, pressAt)
	if slinky.loaded == nil or slinky.binding or not (clickgui and clickgui.Visible) then return false end
	local now = os.clock()
	local top = ui.escapeTop()
	local lists = layout ~= nil and layout.OpenLists ~= nil and next(layout.OpenLists) ~= nil
	local at, key = now, -1
	if source == 'key' then
		pressAt = pressAt or now
		if pressAt == ui.escapeActed or (ui.escapeActed == -1 and math.abs(pressAt - ui.escapeAt) < 0.1) then return false end
		local menuOpen = false
		pcall(function()
			menuOpen = guiService.MenuIsOpen == true
		end)
		local before = pressAt == ui.escapeKey and ui.escapeKeyPrev or -1
		local earlier = ui.escapeMenuAt < pressAt - 0.1
			or (before ~= -1 and math.abs(ui.escapeMenuAt - before) < math.abs(pressAt - ui.escapeMenuAt))
		if (menuOpen and earlier) or now - ui.escapeMenuShut < 0.1 then return false end
	else
		if source == 'menu' then
			at = ui.escapeMenuAt
		end
		local lead = ui.escapeKey - at
		if ui.escapeKey ~= -1 and lead < 0.1 and lead > -0.35 then
			key = ui.escapeKey
			if key == ui.escapeActed or (ui.escapeActed == -1 and math.abs(key - ui.escapeAt) < 0.1) then return false end
		elseif now - ui.escapeAt < 0.35 then
			return false
		end
		if source == 'menu' then
			if not inputService.KeyboardEnabled then return false end
			local down = false
			pcall(function()
				down = inputService:IsKeyDown(Enum.KeyCode.Escape) == true
			end)
			if not down and now - ui.escapePress < 0.6 then return false end
		end
	end
	if source == 'focus' and not top and not lists then return false end
	if source ~= 'focus' then
		local focused
		pcall(function()
			focused = inputService:GetFocusedTextBox()
		end)
		local released = now - ui.escapeFocus < 0.1
		if focused or released then
			local box = released and ui.escapeFocusBox or focused
			local own = false
			if top and typeof(top.Owner) == 'Instance' and typeof(box) == 'Instance' then
				pcall(function()
					own = box:IsDescendantOf(top.Owner)
				end)
			end
			if not own then return false end
		end
	end
	ui.escapeAt = now
	ui.escapeActed = source == 'key' and pressAt or (key ~= -1 and math.abs(key - at) < 0.1 and key or -1)
	if top then
		ui.popEscape(top.Owner)
		pcall(top.Close)
	elseif lists then
		for close in table.clone(layout.OpenLists) do
			pcall(close)
		end
	elseif slinky.menuBind and slinky.menuBind.triggered then
		slinky.menuBind.triggered:Fire(true)
	else
		clickgui.Visible = false
		slinky:blurCheck()
	end
	return true
end

-- A report acted on after the event that brought it, never inside it: a close writes and destroys.
function ui.escapeLater(source, pressAt)
	task.defer(function()
		if slinky.loaded == nil then return end
		if slinky.threadFix then
			setthreadidentity(8)
		end
		ui.escape(source, pressAt)
	end)
end

--[[ The card every menu inside the menu is drawn on (Search item, a colour), built like ui.confirm:
pinned under the top bar, as wide as the confirmation, at the window's zoom, less on a screen too
short for opts.FitHeight. It comes in over 0.3 s, Quint Out: the backdrop greys the screen out to
0.75 and the card drops its last 48 px. A title, and Slinky's X, grey, red under the pointer. A
click off the card, the X or Escape closes it at once; hints and hover lights go out while it is up,
and come back for whatever the pointer rests on after. Closing hands ui.modal back to the modal
under it, if there is one.

opts: Name, Title, FitHeight, OnClose(). Returns {Blocker, Card, Header, Title, CloseButton,
Close(), Closed}; the caller fills Card, a vertical list, from LayoutOrder 2. ]]
function ui.modalCard(opts)
	if not clickgui then return nil end
	opts = opts or {}
	ui.hideTips()
	ui.restHovered()
	local zoom = layout and layout.Zoom or 1
	local s = math.max(scale.Scale, 0.05)
	local width = math.clamp(viewportWidth() / (s * zoom) - 24, 260, 576)
	local top = layout and layout.Top or 12
	local fit = zoom
	if opts.FitHeight then
		local camera = gameCamera or workspace.CurrentCamera
		local room = camera and camera.ViewportSize.Y / s - top - 8 or 0
		if room > 0 then
			fit = math.min(fit, room / opts.FitHeight)
		end
	end
	local modal = {Closed = false}
	local previous = ui.modal
	local blocker = ui.new('TextButton', {
		Name = opts.Name or 'Modal',
		AutoButtonColor = false,
		BackgroundColor3 = theme.Backdrop,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Text = '',
		ZIndex = 20
	}, clickgui)
	ui.modal = blocker
	local card = ui.new('TextButton', {
		AutoButtonColor = false,
		AnchorPoint = Vector2.new(0.5, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = theme.Bar,
		BorderSizePixel = 0,
		Position = UDim2.new(0.5, 0, 0, top - math.floor(48 * fit + 0.5)),
		Size = UDim2.fromOffset(width, 0),
		Text = '',
		ZIndex = 21
	}, blocker)
	ui.corner(card, 20)
	ui.new('UIScale', {Scale = fit}, card)
	ui.list(card, 0)
	ui.padding(card, 12, 12, 11, 12)
	local header = ui.new('Frame', {BackgroundTransparency = 1, LayoutOrder = 1, Size = UDim2.new(1, 0, 0, 20), ZIndex = 22}, card)
	local title = ui.text(header, {Text = opts.Title or '', Size = 16, Color = theme.Text, Props = {
		Size = UDim2.new(1, -40, 1, 0), TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 22
	}})
	local close = ui.icon(header, 'slinky-x', 16, {Class = 'TextButton', Color = theme.SubText, NoMirror = true, Box = UDim2.fromOffset(24, 24), Props = {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 2, 0.5, 0), ZIndex = 22
	}})
	local closeEntry = fonts.Registry[close]
	if closeEntry then
		closeEntry.Size = 21
		ui.setIcon(close, 'slinky-x')
	end
	close.Glyph.ZIndex = 23
	ui.hover(close, function()
		ui.paintIcon(close, theme.RedHover)
	end, function()
		ui.paintIcon(close, theme.SubText)
	end)
	tween:Tween(blocker, theme.ModalInfo, {BackgroundTransparency = 0.25}, 'modal')
	tween:Tween(card, theme.ModalInfo, {Position = UDim2.new(0.5, 0, 0, top)}, 'modal')

	function modal.Close()
		if modal.Closed then return end
		modal.Closed = true
		ui.popEscape(blocker)
		if ui.modal == blocker then
			ui.modal = previous and previous.Parent and previous or nil
		end
		if opts.OnClose then
			pcall(opts.OnClose)
		end
		blocker:Destroy()
		task.defer(function()
			if slinky.loaded == nil then return end
			if slinky.threadFix then
				setthreadidentity(8)
			end
			ui.refreshTooltip()
			ui.rehover()
		end)
	end
	blocker.MouseButton1Click:Connect(modal.Close)
	close.MouseButton1Click:Connect(modal.Close)
	ui.pushEscape(blocker, modal.Close)
	modal.Blocker, modal.Card, modal.Header, modal.Title, modal.CloseButton = blocker, card, header, title, close
	return modal
end

-- HSL, the colour modal's model, where Lightness runs black, the colour, white.
function ui.hsl(h, s, l)
	h = math.clamp(tonumber(h) or 0, 0, 1)
	s = math.clamp(tonumber(s) or 0, 0, 1)
	l = math.clamp(tonumber(l) or 0, 0, 1)
	local v = l + s * math.min(l, 1 - l)
	local sv = v > 0 and 2 * (1 - l / v) or 0
	return Color3.fromHSV(h, math.clamp(sv, 0, 1), math.clamp(v, 0, 1))
end

function ui.toHsl(color)
	local h, sv, v = color:ToHSV()
	local l = v * (1 - sv / 2)
	local s = 0
	if l > 0 and l < 1 then
		s = (v - l) / math.min(l, 1 - l)
	end
	return h, math.clamp(s, 0, 1), math.clamp(l, 0, 1)
end

-- The eight colours picked most recently, newest first, shared by every colour picker.
function ui.rememberColor(color)
	local recent = layout and layout.RecentColors
	if typeof(color) ~= 'Color3' or not recent then return end
	local key = color:ToHex()
	for index = #recent, 1, -1 do
		if recent[index]:ToHex() == key then
			table.remove(recent, index)
		end
	end
	table.insert(recent, 1, color)
	while #recent > 8 do
		table.remove(recent)
	end
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
	for _, category in slinky.categories do
		if type(category) == 'table' and category.kind == 'overlay' and not category.fixed and category.row then
			ui.clampHud(category.row, category.row.Size.X.Offset, 32)
		end
	end
	if slinky.legit then
		for _, module in orderedModules(slinky.legit.order) do
			local widget = module.frame
			if widget then
				ui.clampHud(widget, widget.Size.X.Offset, widget.Size.Y.Offset)
			end
		end
	end
end

--[[ The libraries the game files read. getcustomasset and getfontsize are aliases for getslinkyasset and
getfontbounds: the game files use the old names across some 30,000 lines, and renaming every call
site is a chance to break a module that only fails at runtime. ]]
slinky.libraries = {
	color = color,
	getfontbounds = getfontbounds,
	getslinkyasset = getslinkyasset,
	tween = tween,
	uipallet = uipallet,
	fonts = fonts,
	theme = theme,
	ui = ui,

	getcustomasset = getslinkyasset,
	getfontsize = getfontbounds,
}

--[[
	Where the mobile button sits when it is docked beside the game's top bar. Its default place is
	the corner instead: see slinkyButtonCorner.

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
local slinkyButtonSize = 32
local slinkyButtonFallback = UDim2.new(1, -90, 0, 4)

--[[
	The corner: where the button goes unless the game docks it beside its top bar (UI Cleanup's
	Button Next To Topbar sets that, through SetSlinkyButtonDocked).

	The right end of the strip Roblox leaves free along the top of the screen, TopbarInset. That
	strip already stops at the device's safe area, so a notch or a rounded screen corner is never
	under it. 12px in from its end, as the game keeps its own row of buttons -- the game file moves
	that row over to give the button the room. Vertically, on that row: 44px buttons 2px up from
	the bottom of the strip, which slinkyButtonPosition replaces with the measured row when there is
	one. A client without TopbarInset gets nothing here, and the button docks as it always has.
]]
local function slinkyButtonCorner()
	local ok, inset = pcall(function()
		return guiService.TopbarInset
	end)
	if not (ok and typeof(inset) == 'Rect' and inset.Width > 0) then
		return nil
	end
	return math.floor(inset.Max.X - 12 - slinkyButtonSize),
		math.max(math.floor(inset.Max.Y - 2 - (44 + slinkyButtonSize) / 2), 4)
end

--[[ Where the menu button goes: the corner (slinkyButtonCorner) once the game's top-bar row stops short
of it, otherwise just left of the run of Roblox's top-bar buttons. Without a top bar, or with no
button on it, the corner, which is nil when docked or on a client without TopbarInset. The buttons
are searched among TopBarApp's descendants, since its children are layout containers as wide as
their stretch of bar, and are told from their full-height wrappers by a height of 60 px at most. A
visible button inside a hidden wrapper is not on screen: the client hides whole clusters by the
wrapper.

The run is walked leftwards from the rightmost box across every gap within topbarClusterSlack, so it
does not depend on how wide a button is (the lobby's Patch Notes has its centre left of the middle),
how many there are (mobile shows one more than PC) or where the screen's middle falls. A
TopBarAppGui without IgnoreGuiInset reports positions with the inset taken off, so it is added back.
The bar reports negative Y while the client has it slid off screen; then only the horizontal place
is taken from it. The 2 px on the corner test are for fractional pixels. ]]
local function slinkyButtonPosition(docked)
	local cornerX, cornerTop
	if not docked then
		cornerX, cornerTop = slinkyButtonCorner()
	end
	local corner = cornerX and UDim2.fromOffset(cornerX, cornerTop) or nil
	local players = cloneref(game:GetService('Players'))
	local localPlayer = players.LocalPlayer
	local playerGui = localPlayer and localPlayer:FindFirstChildOfClass('PlayerGui')
	local topbarGui = playerGui and playerGui:FindFirstChild('TopBarAppGui')
	local topbar = topbarGui and topbarGui:FindFirstChild('TopBarApp')
	if not (topbar and topbar:IsA('GuiObject')) or topbar.AbsoluteSize.X <= 0 then
		return corner
	end

	local boxes = {}
	for _, obj in topbar:GetDescendants() do
		if
			obj:IsA('GuiObject') and obj.Visible
			and obj.AbsoluteSize.X > 0 and obj.AbsoluteSize.Y > 0 and obj.AbsoluteSize.Y <= 60
		then
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

	if #boxes <= 0 then return corner end

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

	local inset = 0
	if topbarGui:IsA('ScreenGui') and not topbarGui.IgnoreGuiInset then
		inset = guiService:GetGuiInset().Y
	end

	if cornerX and run.Right + topbarGap <= cornerX + 2 then
		local top = run.Top + inset + ((run.Height - slinkyButtonSize) / 2)
		return UDim2.fromOffset(cornerX, top >= 0 and math.floor(top) or cornerTop)
	end

	local top = row.Top + inset + ((row.Height - slinkyButtonSize) / 2)
	if top < 0 then
		top = 4
	end

	return UDim2.fromOffset(
		math.max(math.floor(edge - topbarGap - slinkyButtonSize), 0),
		math.floor(top)
	)
end

--[[ Places the menu button and checks its place every second. Polled, not driven off a signal: the top
bar rebuilds its children when the game toggles a core GUI, the device rotates or the client opens
its own menu, so a connected instance is often a destroyed one. slinky.placeMenuButton places it
now. Every call is guarded, the first too: it runs at the end of LoadGUI and reads the client's own
top bar. After a move the Mod Overlay is placed again under the button. ]]
local function anchorSlinkyButton(button)
	local current

	local function apply()
		local position = slinkyButtonPosition(slinky.menuButtonDocked) or slinkyButtonFallback
		if current ~= position then
			local moved = current ~= nil
			current = position
			button.Position = position
			if moved then
				task.defer(pcall, ui.applyHudZoom)
			end
		end
	end

	slinky.placeMenuButton = function()
		pcall(apply)
	end

	pcall(apply)

	local thread = task.spawn(function()
		while button.Parent do
			task.wait(1)
			pcall(apply)
		end
	end)

	if slinky.clean then
		slinky:clean(thread)
	end
end

--[[ Beside the game's top bar (true) or in the corner (false, the default). The game's UI Cleanup
sets it, docked only while it is on with Button Next To Topbar, and the button moves now rather
than on its next check. ]]
slinky.menuButtonDocked = false
function slinky:dockMenuButton(docked)
	docked = docked == true
	if self.menuButtonDocked == docked then return end
	self.menuButtonDocked = docked
	if self.placeMenuButton then
		self.placeMenuButton()
	end
end

local function addCorner(parent, radius)
	local corner = Instance.new('UICorner')
	corner.CornerRadius = radius or UDim.new(0, 5)
	corner.Parent = parent

	return corner
end

--[[ Lets a press drag gui, on its top 40 px or anywhere when window is given, and saves on release. Only
the press that started the drag moves it: a touch keeps one InputObject for its whole life, so a
second finger on the thumbstick does not pull the widget. ]]
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
					slinky:requestSave()
				end
			end)
		end
	end)
end

local function addMaid(obj)
	obj.connections = {}

	function obj:clean(callback)
		if typeof(callback) == 'Instance' then
			table.insert(self.connections, {
				Disconnect = function()
					callback:ClearAllChildren()
					callback:Destroy()
				end
			})
		elseif type(callback) == 'thread' then
			table.insert(self.connections, {
				Disconnect = function()
					if coroutine.status(callback) ~= 'dead' then
						task.cancel(callback)
					end
				end
			})
		elseif type(callback) == 'function' then
			table.insert(self.connections, {
				Disconnect = callback
			})
		else
			table.insert(self.connections, callback)
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

-- noLight: the title keeps its colour while the hint shows, as a module's name does in Slinky.
local function addRowTooltip(gui, text, anchor, title, bounds, noLight)
	if type(text) ~= 'string' or text == '' then return end
	local entry = {Text = (removeTags(text):gsub('\n', ' ')), Anchor = anchor, Title = title, Bounds = bounds}
	entry.NoLight = noLight
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

--[[ Measures a hint's pill once per row, on its own thread, since the first measure of a text yields.
The text wraps word by word at 340 px the way the label wraps it; the pill is 6 px either side of
the text, as Slinky's, and one line is 20 tall whatever the client measures. TitleWidth is the
title's own text width, for a label wider than its words. ]]
function ui.measureTooltip(entry)
	if entry.Measuring then return end
	entry.Measuring = true
	task.spawn(function()
		local font = uipallet.FontMedium or uipallet.Font
		local bounds = getfontbounds(entry.Text, tooltip.TextSize, font)
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
		local title = entry.Title
		if title and title:IsA('TextLabel') then
			entry.TitleWidth = getfontbounds(title.Text, title.TextSize, title.FontFace).X
		end
		entry.Wrapped = lines > 1
		entry.Size = Vector2.new(math.min(bounds.X, 340) + 12, lines > 1 and (bounds.Y * lines + 6) or 20)
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

--[[ Lights the title a hint belongs to (a toggle's name) white while the hint is up, at once, and sets
its own colour back after; that colour is taken the first time, at rest. A module's name is not lit
(NoLight): Slinky's never is. ]]
function ui.lightTitle(entry, lit)
	if entry and entry.NoLight then return end
	local title = entry and entry.Title
	if not (title and title.Parent and (title:IsA('TextLabel') or title:IsA('TextButton'))) then return end
	if lit then
		entry.TitleColor = entry.TitleColor or title.TextColor3
		tween:Cancel(title)
		title.TextColor3 = theme.Lit
	elseif entry.TitleColor then
		tween:Cancel(title)
		title.TextColor3 = entry.TitleColor
	end
end

--[[ The hint pill: one look and one motion for every hint, a row's help, a profile icon's action, a
slider's value. Slinky's: #404040, radius 5, 20 tall, the text plus 6 px a side. It comes in over
0.1 s, Sine InOut, grown from a point just under its box and faded up as it grows, and goes at once.
Each is a label on the menu's layer with a UIScale of its own. A UIScale grows a label about its
AnchorPoint, so the anchor is put under the box instead of wrapping the label in a holder. Text and
fill fade on their own rather than in a CanvasGroup: hints never show on a touch screen, and old
phone clients have no CanvasGroup. ]]
ui.tips = setmetatable({}, {__mode = 'k'})
function ui.newTip(name, autoWidth)
	local label = ui.text(scaledgui, {Text = '', Size = 14, Color = theme.Text, AlignX = Enum.TextXAlignment.Center, Props = {
		Name = name,
		AnchorPoint = Vector2.new(0.5, 1.4),
		AutomaticSize = autoWidth and Enum.AutomaticSize.X or Enum.AutomaticSize.None,
		BackgroundColor3 = theme.Pill,
		BackgroundTransparency = 0,
		Position = UDim2.fromScale(-1, -1),
		RichText = true,
		Size = UDim2.fromOffset(0, 20),
		Visible = false,
		ZIndex = 40
	}})
	ui.corner(label, 5)
	ui.padding(label, 6, 6, 0, 0)
	local tip = {Label = label, Zoom = ui.new('UIScale', {Scale = 1}, label)}
	ui.tips[tip] = true
	return tip
end

--[[ Puts a hint centred on centreX with its box's top at boxTop, in the menu's units; height is the
box's before the window's zoom. It grows from 8 px under its box, or from 8 px over it when it is put
under its anchor (below). appearing plays the way in; otherwise it moves straight there. ]]
function ui.tipPlace(tip, centreX, boxTop, height, appearing, below)
	local label = tip.Label
	local zoom = layout and layout.Zoom or 1
	height = math.max(height, 1)
	local originY
	if below then
		label.AnchorPoint = Vector2.new(0.5, -8 / height)
		originY = boxTop - 8 * zoom
	else
		label.AnchorPoint = Vector2.new(0.5, 1 + 8 / height)
		originY = boxTop + (height + 8) * zoom
	end
	label.Position = UDim2.fromOffset(math.floor(centreX + 0.5), math.floor(originY + 0.5))
	if appearing then
		if tip.Grow then
			tip.Grow:Cancel()
		end
		tween:Cancel(label, 'tip')
		tip.Zoom.Scale = 0
		label.TextTransparency = 1
		label.BackgroundTransparency = 1
		label.Visible = true
		local grow = tweenService:Create(tip.Zoom, theme.TipInfo, {Scale = zoom})
		tip.Grow = grow
		grow.Completed:Once(function()
			if tip.Grow == grow then
				tip.Grow = nil
			end
		end)
		grow:Play()
		tween:Tween(label, theme.TipInfo, {TextTransparency = 0, BackgroundTransparency = 0}, 'tip')
	elseif not tip.Grow then
		tip.Zoom.Scale = zoom
	end
end

function ui.tipHide(tip)
	if not tip then return end
	if tip.Grow then
		tip.Grow:Cancel()
		tip.Grow = nil
	end
	tween:Cancel(tip.Label, 'tip')
	tip.Label.Visible = false
end

-- Every hint away at once: a modal opening, the menu showing or shutting.
function ui.hideTips()
	for tip in ui.tips do
		ui.tipHide(tip)
	end
	ui.tooltipShown = nil
	if ui.tooltipEntry then
		ui.lightTitle(ui.tooltipEntry, false)
		ui.tooltipEntry = nil
	end
end

-- The page scrolled under a still pointer: each slider hint showing follows its knob, or goes.
function ui.placeTips()
	local done = {}
	for tip in ui.tips do
		local place = tip.Place
		if place and not done[place] and tip.Label.Visible then
			done[place] = true
			pcall(place)
		end
	end
end

--[[ Puts the hint pill over the switch of the title the pointer is on, or away when it is on none. There
is no hint while a confirmation or a menu inside the menu is up, or after touch input. The pointer
is measured from the top of the screen and the rows from the GUI's origin under Roblox's top bar, so
scaledgui.AbsolutePosition is added to the pointer. A gui whose leave never came is dropped once the
pointer is off it, and only the title's words count, not the whole row.

The pill is centred 6 px over the switch, as the slider's value sits over its knob, but never past
the card's right edge, and goes under the switch only at the top edge of the screen; it is sized in
the window's zoom as well as the menu's scale. A new hint comes in the way every hint does; one
already up moves straight to its new place. ]]
function ui.refreshTooltip()
	if not ui.rowTip then return end
	local current, entry
	if tooltipsEnabled and clickgui and clickgui.Visible
		and not clickgui:FindFirstChild('Confirm') and not (ui.modal and ui.modal.Parent) and not ui.lastInputTouch() then
		local point = inputService:GetMouseLocation() + scaledgui.AbsolutePosition
		for gui, candidate in ui.tooltipHovered do
			if not (gui.Parent and ui.within(point, gui.AbsolutePosition, gui.AbsoluteSize)) then
				ui.tooltipHovered[gui] = nil
			elseif not current and ui.rowShowing(gui, point) then
				if not candidate.Size then
					ui.measureTooltip(candidate)
				end
				if candidate.Size then
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
		if ui.tooltipEntry then
			ui.lightTitle(ui.tooltipEntry, false)
			ui.tooltipEntry = nil
		end
		ui.tooltipShown = nil
		ui.tipHide(ui.rowTip)
		return
	end

	local appearing = ui.tooltipShown ~= current or not tooltip.Visible
	if ui.tooltipEntry and ui.tooltipEntry ~= entry then
		ui.lightTitle(ui.tooltipEntry, false)
	end
	ui.tooltipShown = current
	ui.tooltipEntry = entry
	tooltip.Text = entry.Text
	tooltip.TextWrapped = entry.Wrapped
	tooltip.Size = UDim2.fromOffset(entry.Size.X, entry.Size.Y)
	local s = math.max(scale.Scale, 0.05)
	local zoom = layout and layout.Zoom or 1
	local width, height = entry.Size.X * zoom, entry.Size.Y * zoom
	local anchor = entry.Anchor and entry.Anchor.Parent and entry.Anchor or current
	local origin = tooltip.Parent and tooltip.Parent.AbsolutePosition or Vector2.zero
	local switchTop = (anchor.AbsolutePosition.Y - origin.Y) / s
	local switchCentre = (anchor.AbsolutePosition.X + anchor.AbsoluteSize.X / 2 - origin.X) / s
	local bound = entry.Bounds and entry.Bounds.Parent and entry.Bounds or current
	local rowRight = (bound.AbsolutePosition.X + bound.AbsoluteSize.X - origin.X) / s
	local left = math.min(switchCentre - width / 2, rowRight - width - 4)
	local top, below = switchTop - height - 6, false
	if top < 4 then
		top, below = switchTop + anchor.AbsoluteSize.Y / s + 4, true
	end
	left = math.clamp(left, 4, math.max(viewportWidth() / s - width - 4, 4))
	if appearing then
		ui.lightTitle(entry, true)
	end
	ui.tipPlace(ui.rowTip, left + width / 2, top, entry.Size.Y, appearing, below)
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

--[[ The blur a phone gets, and any menu the native blur cannot be used for: a BlurEffect in Lighting,
which blurs the world behind the menu and needs no native call or elevated thread. Destroyed when
the menu closes, so nothing sits in Lighting while it is shut and a client that wipes Lighting
cannot leave the toggle on a dead effect. Each is tagged PistonwareMenuBlur, so one an earlier
injection left behind is found and removed. ]]
local function setMobileBlur(enabled)
	pcall(function()
		for _, child in lighting:GetChildren() do
			if child ~= mobileBlur and child:GetAttribute('PistonwareMenuBlur') then
				child:Destroy()
			end
		end
	end)

	if enabled then
		if mobileBlur and mobileBlur.Parent then return end

		local created, effect = pcall(Instance.new, 'BlurEffect')
		if not created then return end

		effect.Name = randomString()
		effect.Size = 18
		pcall(effect.SetAttribute, effect, 'PistonwareMenuBlur', true)
		effect.Parent = lighting
		mobileBlur = effect
	elseif mobileBlur then
		pcall(function()
			mobileBlur:Destroy()
		end)
		mobileBlur = nil
	end
end

--[[ Turns the menu blur on or off with the menu and its toggle; not while the HUD is being moved.
self.blur does not exist the first time the settings pane is built, so every read of it goes through
here. Touch devices and clients without setthreadidentity get the BlurEffect. SetRobloxGuiFocused
blurs every ScreenGui not marked OnTopOfCoreBlur, and a menu in PlayerGui (Solara's) is not drawn
over it, so that menu takes the BlurEffect too, and the native blur is switched off unless Roblox's
connection-error blur is up. ]]
function slinky:blurCheck()
	local open = clickgui.Visible and not (layout and layout.MovingHud)
	local wanted = open and self.blur ~= nil and self.blur.enabled

	if inputService.TouchEnabled or not self.threadFix then
		setMobileBlur(wanted)
		return
	end

	setthreadidentity(8)
	local underBlur = false
	pcall(function()
		underBlur = gui ~= nil and gui.Parent ~= nil and gui.Parent:IsA('PlayerGui')
	end)
	if underBlur then
		pcall(function()
			if guiService:GetErrorType() == Enum.ConnectionError.OK then
				runService:SetRobloxGuiFocused(false)
			end
		end)
		setMobileBlur(wanted)
		return
	end

	pcall(function()
		runService:SetRobloxGuiFocused((open or guiService:GetErrorType() ~= Enum.ConnectionError.OK) and self.blur.enabled)
	end)
end

--[[
	A notification is Slinky's capsule in the bottom-right corner, or the top-left one Slinky uses
	(the Notifications card's Position): an uppercase tag in the accent (green for a success, yellow
	for a warning, red for an alert) and the message beside it. Same signature, same folder and
	same Notifications toggle as before; the rich text callers send is drawn as written. It moves as
	Slinky's do (OVERLAY_SPEC 3, ANIM_SPEC 9): in from 100 px out while it fades in, out the same way,
	and the rest close up on the same 0.2 s Sine InOut, all through TweenService. It stays the 5 s
	Slinky's do, or longer when the caller asks for longer.
]]
local NOTIFICATION_HEIGHT = 42
local NOTIFICATION_GAP = 8
-- The margin from the corner, and how far a pill slides in and out, in the HUD's units at 1080p.
ui.NotifyMargin = 12
ui.NotifySlide = 100
-- The shortest a pill stays, in seconds from the start of its way in to the end of its way out:
-- Slinky's 5 (ANIM_SPEC 9, out from 4.8 s).
ui.NotifyLifetime = 5

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
Position. Hidden is the same row slid out toward the screen edge it comes in from, 100 px; the
AnchorPoint is the corner's either way. The top-left stack starts under Roblox's top bar, which this
ScreenGui draws over. The margins grow with the phone zoom the pills are drawn at. ]]
function ui.notificationPlace(index, hidden, before)
	local zoom = ui.hudZoom()
	before = before or notificationOffset(index)
	local margin = ui.NotifyMargin * zoom
	local slide = hidden and ui.NotifySlide * zoom or 0
	if layout and layout.NotifyTop then
		return Vector2.zero, UDim2.new(0, margin - slide, 0, ui.insetUnits() + margin + before)
	end
	return Vector2.new(1, 1), UDim2.new(1, -margin + slide, 1, -(margin + before))
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
		if slinky.threadFix then
			setthreadidentity(8)
		end
		pcall(ui.restackNow)
	end)
end

--[[ Puts every showing notification at its place in the stack. Newer pills draw over older ones, and one
on its way out under them all. Only a pill whose place changed moves, on the same curve; one on its
way in carries its x along to the new place, and a corner change starts it from the new corner's
edge. ]]
function ui.restackNow()
	local before = 0
	for index, notif in ui.showingNotifications() do
		local z = 5 + math.min(index, 29)
		if notif.ZIndex ~= z then
			notif.ZIndex = z
		end
		local anchor, position = ui.notificationPlace(index, false, before)
		local top = layout and layout.NotifyTop and true or false
		if notif:GetAttribute('SlotX') ~= position.X.Offset or notif:GetAttribute('SlotY') ~= position.Y.Offset or notif:GetAttribute('SlotTop') ~= top then
			if notif:GetAttribute('SlotTop') ~= top then
				local _, hidden = ui.notificationPlace(index, true, before)
				tween:Cancel(notif)
				notif.AnchorPoint = anchor
				notif.Position = hidden
			end
			notif:SetAttribute('SlotX', position.X.Offset)
			notif:SetAttribute('SlotY', position.Y.Offset)
			notif:SetAttribute('SlotTop', top)
			tween:Tween(notif, theme.SlinkyInfo, {Position = position})
		end
		before += notif:GetAttribute('Span') or (NOTIFICATION_HEIGHT + NOTIFICATION_GAP) * ui.hudZoom()
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

--[[ Shows a notification pill when notifications are on, built on a deferred thread. It stays Slinky's 5
s (ui.NotifyLifetime), or longer when asked, its way in and out included; nil, 0, a negative time,
NaN or a non-number gets 5 s, and math.huge stays until the menu goes. A title longer than 18
characters or with markup is a sentence (the profile swap sends 'Profile swap to <name>'), so it
leads the message under the usual tag. A long message wraps onto more lines rather than running off
a phone's edge, and is kept to a readable width on a monitor too.

The pill is Slinky's capsule: #141414, no outline, 8 px round the tag and 16 past the message. The
tag is the accent over the pill at 1/7 (Slinky's 0.857 transparency), 26 tall, radius 10. In: from
100 px out to its place while it fades in, all on one 0.2 s Sine InOut; position and fade are
separate tweens, so a restack on its way in leaves the fade running. Out over the last 0.2 s of its
time, the way it came, while the others close up on the same frame and curve. A pill keeps the phone
zoom it was drawn at. ]]
function slinky:notify(title, text, duration, type)
	if not self.notifications.enabled then
		return
	end

	layout.NotifySeq = (layout.NotifySeq or 0) + 1
	local order = layout.NotifySeq
	task.delay(0, function()
		if self.threadFix then
			setthreadidentity(8)
		end

		duration = tonumber(duration)
		duration = math.max(duration and duration > 0 and duration or 0, ui.NotifyLifetime)
		local accent = type == 'alert' and theme.Red or type == 'warning' and theme.Yellow or type == 'success' and theme.NotifyGreen or theme.Accent()

		local plainTitle = removeTags(tostring(title or 'Pistonware'))
		if #plainTitle > 18 or tostring(title):find('<', 1, true) then
			text = tostring(title)..'  <font color="#a2a19d">'..tostring(text or '')..'</font>'
			plainTitle = 'Pistonware'
		elseif plainTitle:lower() == 'slinky' then
			plainTitle = 'Pistonware'
		end
		local tagText = plainTitle:upper()

		local zoom = ui.hudZoom()
		local messageHeight, wraps, messageWidth = NOTIFICATION_HEIGHT, false, 0
		pcall(function()
			local available = viewportWidth() / (math.max(scale.Scale, 0.05) * zoom) - 40
			local tagWidth = getfontbounds(tagText, theme.em(14), fonts.face('Medium')).X + 21
			messageWidth = math.floor(math.clamp(available - tagWidth - 32, 140, 560))
			local height
			height, wraps = ui.wrappedHeight(removeTags(tostring(text or '')), theme.em(14), fonts.face('Medium'), messageWidth)
			if wraps then
				messageHeight = math.max(NOTIFICATION_HEIGHT, math.ceil(height) + 16)
			end
		end)

		local index = 1
		for _, notif in notifications:GetChildren() do
			if not notif:GetAttribute('Leaving') and (notif:GetAttribute('Order') or 0) < order then
				index += 1
			end
		end
		local anchor, hiddenPosition = ui.notificationPlace(index, true)
		local _, shownPosition = ui.notificationPlace(index, false)
		local notification = ui.new('Frame', {
			AnchorPoint = anchor,
			AutomaticSize = Enum.AutomaticSize.X,
			BackgroundColor3 = theme.Bar,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Position = hiddenPosition,
			Size = UDim2.fromOffset(0, messageHeight),
			ZIndex = 5 + math.min(index, 29)
		})
		notification:SetAttribute('Order', order)
		notification:SetAttribute('Span', (messageHeight + NOTIFICATION_GAP) * zoom)
		notification:SetAttribute('SlotX', shownPosition.X.Offset)
		notification:SetAttribute('SlotY', shownPosition.Y.Offset)
		notification:SetAttribute('SlotTop', layout and layout.NotifyTop and true or false)
		ui.hudScale(notification, true)
		notification.Parent = notifications
		ui.corner(notification, wraps and UDim.new(0, 18) or UDim.new(1, 0))
		ui.padding(notification, 8, 16, 0, 0)
		ui.list(notification, 8, true)

		local tagLabel = ui.text(notification, {Text = tagText, Size = 14, Weight = 'Medium', Color = accent, AlignX = Enum.TextXAlignment.Center, Props = {
			AutomaticSize = Enum.AutomaticSize.X,
			BackgroundColor3 = theme.Tint(accent, 1 / 7),
			BackgroundTransparency = 1,
			LayoutOrder = 1,
			Size = UDim2.fromOffset(0, 26),
			TextTransparency = 1,
			ZIndex = 5
		}})
		ui.corner(tagLabel, 10)
		ui.padding(tagLabel, 10, 11, 0, 0)

		local message = ui.text(notification, {Text = tostring(text or ''), Size = 14, Weight = 'Medium', Color = theme.NotifyText, Props = {
			AutomaticSize = wraps and Enum.AutomaticSize.None or Enum.AutomaticSize.X,
			LayoutOrder = 2,
			RichText = true,
			Size = UDim2.fromOffset(wraps and messageWidth or 0, messageHeight),
			TextTransparency = 1,
			TextWrapped = wraps,
			ZIndex = 5
		}})
		message.TextYAlignment = Enum.TextYAlignment.Center

		local function fade(value)
			tween:Tween(notification, theme.SlinkyInfo, {BackgroundTransparency = value}, 'notify')
			tween:Tween(tagLabel, theme.SlinkyInfo, {BackgroundTransparency = value, TextTransparency = value}, 'notify')
			tween:Tween(message, theme.SlinkyInfo, {TextTransparency = value}, 'notify')
		end
		tween:Tween(notification, theme.SlinkyInfo, {Position = shownPosition})
		fade(0)
		ui.restackNotifications()

		local exitTime = theme.SlinkyInfo.Time
		task.delay(duration - exitTime, function()
			notification:SetAttribute('Leaving', true)
			notification.ZIndex = 5
			local _, hidden = ui.notificationPlace(1, true)
			tween:Tween(notification, theme.SlinkyInfo, {
				Position = UDim2.new(hidden.X.Scale, hidden.X.Offset, notification.Position.Y.Scale, notification.Position.Y.Offset)
			})
			fade(1)
			ui.restackNotifications()

			task.wait(exitTime)
			tween:Cancel(notification)
			for _, part in {notification, tagLabel, message} do
				tween:Cancel(part, 'notify')
			end
			notification:ClearAllChildren()
			notification:Destroy()
		end)
	end)
end

--[[ The props a public creator hands its component. The name comes first,
module:toggle('Name', {...}), and goes into the props; a lone table (the old call shape, and
targets) or no argument at all reaches the component as it is. ]]
local function declared(name, props)
	if props == nil and type(name) ~= 'string' then
		return name
	end
	props = props or {}
	props.name = name
	return props
end

function slinky:overlay(name, props)
	return components.overlay(declared(name, props))
end

function slinky:categoryWindow(name, props)
	return components.categoryWindow(declared(name, props))
end

function slinky:categoryList(name, props)
	return components.categoryList(declared(name, props))
end

--[[ Saved state. A profile is one file, pistonware/profiles/<name>.json: an entry per module, legit
module and overlay under the name the menu shows, shared by the lobby and matches. What is not per
profile is in settings.json beside it. Both are written one entry per line, so a file reads and
compares line by line; reading is the executor's own JSON decoder. Saving merges into what the file
held when it was read: the lobby knows nothing of the match modules and writes their entries back as
they were. ]]
local store = {
	folder = 'pistonware/profiles',
	settingsPath = 'pistonware/profiles/settings.json',
	profile = {},
	settings = {},
	applied = setmetatable({}, {__mode = 'k'}),
	kept = setmetatable({}, {__mode = 'k'}),
	defaults = setmetatable({}, {__mode = 'k'}),
	unconverted = {},
	oldName = {},
	snakes = {}
}

do
	local MATCH_PLACE, LOBBY_PLACE = '6872274481', '6872265039'
	-- The menu file an older build kept for BedWars: <gameId>.gui.txt.
	local BEDWARS_GUI = '2619619496.gui.txt'
	-- An entry's own keys in the order they are written; its option keys follow in byte order.
	local META_ORDER = {'__on', '__lobby', '__bind', '__hold', '__mobile', '__hidden', '__pinned', '__pos',
		'__open', '__selected', '__items'}
	-- The keys of an object inside an entry, in the order they are written.
	local NESTED_ORDER = {'name', 'id', 'min', 'max', 'r', 'g', 'b', 'a', 'rainbow', 'rainbow_offset', 'preset',
		'players', 'npcs', 'walls', 'invisible', 'milo', 'x', 'y', 'keys', 'hold', 'mobile', 'used', 'items',
		'active', 'color'}
	local metaRank, nestedRank = {}, {}
	for index, key in META_ORDER do
		metaRank[key] = index
		nestedRank[key] = index
	end
	for index, key in NESTED_ORDER do
		nestedRank[key] = #META_ORDER + index
	end
	-- What each kind of object decides in its entry, besides its on/off and its options.
	local OWNED = {
		module = {'__bind', '__hold', '__mobile', '__hidden'},
		legitModule = {'__pos'},
		overlay = {'__bind', '__hold', '__mobile', '__pinned', '__pos'}
	}
	-- Entry state every place shares: the match file's lack of one wins over the lobby file's value.
	local SHARED = {'__bind', '__hold', '__mobile', '__hidden', '__pos'}
	-- The sections of settings.json that hold entries.
	local SECTIONS = {categories = true, settings = true}

	-- The file the lobby and every match share.
	local function bedwarsPath(name)
		return store.folder..'/'..name..'.json'
	end

	--[[ A profile's file in the place this is. BedWars has one for the lobby and its matches; any other
	place has a file of its own beside it, so nothing saved there reaches the BedWars profile and
	nothing saved in BedWars switches a module on there. ]]
	function store.path(name)
		local place = tostring(slinky.place)
		if place == MATCH_PLACE or place == LOBBY_PLACE then
			return bedwarsPath(name)
		end
		return store.folder..'/'..name..'.'..place..'.json'
	end

	-- Where this place keeps a module's on/off. The lobby has its own key beside the matches' in the
	-- file they share; a place with a file of its own uses the plain one.
	function store.onKey()
		return tostring(slinky.place) == LOBBY_PLACE and '__lobby' or '__on'
	end

	function store.copy(value)
		if type(value) ~= 'table' then
			return value
		end
		local copy = {}
		for key, held in value do
			copy[key] = store.copy(held)
		end
		return copy
	end

	function store.same(a, b)
		if type(a) ~= 'table' or type(b) ~= 'table' then
			return a == b
		end
		for key, value in a do
			if not store.same(value, b[key]) then
				return false
			end
		end
		for key in b do
			if a[key] == nil then
				return false
			end
		end
		return true
	end

	-- A decoded JSON list: its keys are 1 to n. An empty table counts, as a list may be empty.
	local function isList(value)
		if type(value) ~= 'table' then
			return false
		end
		local count = 0
		for _ in value do
			count += 1
		end
		return count == #value
	end

	-- A decoded JSON object. An empty table counts here too: Lua cannot tell the two apart.
	local function isObject(value)
		return type(value) == 'table' and (next(value) == nil or not isList(value))
	end

	local function named(value)
		return isObject(value) and value or {}
	end

	local function sortedNames(entries)
		local names = {}
		for name in entries do
			if type(name) == 'string' then
				table.insert(names, name)
			end
		end
		table.sort(names)
		return names
	end

	--[[ An option's key in the file: 'Attack Range' is attack_range, 'StarCount' star_count, 'TPDown'
	tp_down and 'NPCs' npcs. ]]
	function store.snake(name)
		local key = store.snakes[name]
		if not key then
			key = name:gsub('(%l)(%u)', '%1 %2'):gsub('(%u)(%u%l%l)', '%1 %2'):lower():gsub('[^%d%l]+', '_')
			key = key:gsub('^_', ''):gsub('_$', '')
			if key == '' then
				key = 'option'
			end
			store.snakes[name] = key
		end
		return key
	end

	-- Names to keys. Two names that fold to one key are numbered in byte order of the names, which
	-- needs no knowledge of the order they were declared in.
	function store.keys(names)
		local keys, taken, clash = {}, {}, false
		for _, name in names do
			local key = store.snake(name)
			keys[name] = key
			clash = clash or taken[key] ~= nil
			taken[key] = true
		end
		if clash then
			local ordered, count = table.clone(names), {}
			table.sort(ordered)
			for _, name in ordered do
				local key = store.snake(name)
				count[key] = (count[key] or 0) + 1
				keys[name] = count[key] == 1 and key or key..'_'..count[key]
			end
		end
		return keys
	end

	-- The option names of an object, and the key each has in its entry.
	function store.optionKeys(options)
		local names = {}
		for name in options do
			if type(name) == 'string' then
				table.insert(names, name)
			end
		end
		return store.keys(names), names
	end

	--[[ The writer. ]]

	--[[ A number as profile text: a whole number below 1e15 without a fraction, any other in the
	shortest of 15 to 17 significant digits that reads back as the same number. A profile cannot
	hold NaN or infinity. ]]
	local function numberText(value)
		if value ~= value or value == math.huge or value == -math.huge then
			error('a profile cannot hold nan or inf', 0)
		end
		if value == 0 then
			return '0'
		end
		if value == math.floor(value) and math.abs(value) < 1e15 then
			return string.format('%.0f', value)
		end
		local text
		for digits = 15, 17 do
			text = string.format('%.'..digits..'g', value)
			if tonumber(text) == value then
				break
			end
		end
		return text
	end

	local ESCAPES = {['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t', ['\b'] = '\\b', ['\f'] = '\\f'}
	local function stringText(text)
		return '"'..text:gsub('[%z\1-\31"\\]', function(char)
			return ESCAPES[char] or string.format('\\u%04x', char:byte())
		end)..'"'
	end

	local function orderedKeys(value, rank)
		local keys = {}
		for key in value do
			table.insert(keys, key)
		end
		table.sort(keys, function(a, b)
			local first, second = rank[a] or math.huge, rank[b] or math.huge
			if first ~= second then
				return first < second
			end
			return tostring(a) < tostring(b)
		end)
		return keys
	end

	-- One value on one line. An empty table is written []: below an entry nothing says which it was.
	local function valueText(value, rank)
		local kind = type(value)
		if kind == 'string' then
			return stringText(value)
		elseif kind == 'number' then
			return numberText(value)
		elseif kind == 'boolean' then
			return value and 'true' or 'false'
		elseif kind ~= 'table' then
			error('a profile cannot hold a '..typeof(value), 0)
		end
		local parts = {}
		if isList(value) then
			for index = 1, #value do
				parts[index] = valueText(value[index])
			end
			return '['..table.concat(parts, ', ')..']'
		end
		for _, key in orderedKeys(value, rank or nestedRank) do
			table.insert(parts, stringText(tostring(key))..': '..valueText(value[key]))
		end
		return '{'..table.concat(parts, ', ')..'}'
	end

	-- An entry is an object even when it is empty.
	local function entryText(entry)
		if type(entry) == 'table' and next(entry) == nil then
			return '{}'
		end
		return valueText(entry, metaRank)
	end

	local function entryLines(entries, indent)
		local lines = {}
		for _, name in orderedKeys(entries, {}) do
			table.insert(lines, indent..stringText(tostring(name))..': '..entryText(entries[name]))
		end
		return table.concat(lines, ',\n')
	end

	function store.profileText(entries)
		if next(entries) == nil then
			return '{}\n'
		end
		return '{\n'..entryLines(entries, '\t')..'\n}\n'
	end

	function store.settingsText(settings)
		if next(settings) == nil then
			return '{}\n'
		end
		local lines = {}
		for _, key in orderedKeys(settings, {}) do
			local value = settings[key]
			local text
			if SECTIONS[key] and type(value) == 'table' then
				text = next(value) == nil and '{}' or '{\n'..entryLines(value, '\t\t')..'\n\t}'
			else
				text = valueText(value)
			end
			table.insert(lines, '\t'..stringText(tostring(key))..': '..text)
		end
		return '{\n'..table.concat(lines, ',\n')..'\n}\n'
	end

	-- Encodes first, so a value that cannot be written never truncates the file on disk.
	function store.write(path, encode, data)
		local encoded, text = pcall(encode, data)
		if not encoded then
			return false, text
		end
		return pcall(writefile, path, text)
	end

	--[[ Colours. A file holds red, green and blue to four decimals; the pickers work in hue,
	saturation and value. Plain arithmetic both ways, the same sums the reference converter does. ]]

	function store.tidy(number)
		return math.floor(number * 10000 + 0.5) / 10000
	end

	function store.rgb(hue, sat, value)
		hue = (hue % 1) * 6
		local sector = math.floor(hue)
		local part = hue - sector
		local low = value * (1 - sat)
		local falling = value * (1 - sat * part)
		local rising = value * (1 - sat * (1 - part))
		sector %= 6
		if sector == 0 then
			return value, rising, low
		elseif sector == 1 then
			return falling, value, low
		elseif sector == 2 then
			return low, value, rising
		elseif sector == 3 then
			return low, falling, value
		elseif sector == 4 then
			return rising, low, value
		end
		return value, low, falling
	end

	-- A grey has no hue and black no saturation: both come back as 0, which only moves a picker's knob.
	function store.hsv(red, green, blue)
		local high, low = math.max(red, green, blue), math.min(red, green, blue)
		local spread = high - low
		local hue = 0
		if spread > 0 then
			if high == red then
				hue = ((green - blue) / spread) % 6
			elseif high == green then
				hue = (blue - red) / spread + 2
			else
				hue = (red - green) / spread + 4
			end
			hue /= 6
		end
		return hue, high > 0 and spread / high or 0, high
	end

	-- A colour as the file holds it.
	function store.color(hue, sat, value)
		local red, green, blue = store.rgb(hue, sat, value)
		return {r = store.tidy(red), g = store.tidy(green), b = store.tidy(blue)}
	end

	local function isColor(value)
		return type(value) == 'table' and isFiniteNumber(value.r) and isFiniteNumber(value.g) and isFiniteNumber(value.b)
	end
	store.isColor = isColor

	--[[ A list of entries that can each be on or off: the entries alone when every one is on, else
	both lists. ]]
	function store.list(items, active)
		local allOn = #items == #active
		if allOn then
			local first, second = table.clone(items), table.clone(active)
			for index = 1, #first do
				allOn = allOn and type(first[index]) == 'string' and type(second[index]) == 'string'
			end
			if allOn then
				table.sort(first)
				table.sort(second)
				for index = 1, #first do
					allOn = allOn and first[index] == second[index]
				end
			end
		end
		if allOn then
			return table.clone(items)
		end
		return {items = table.clone(items), active = table.clone(active)}
	end

	-- The other way: the entries and the ones that are on.
	function store.listed(value)
		if type(value) ~= 'table' then
			return {}, {}
		end
		if type(value.items) == 'table' or type(value.active) == 'table' then
			return table.clone(type(value.items) == 'table' and value.items or {}),
				table.clone(type(value.active) == 'table' and value.active or {})
		end
		return table.clone(value), table.clone(value)
	end

	-- A module's own bind sits in its entry as __bind, __hold and __mobile.
	function store.bindInto(entry, bind)
		local value = bind:save()
		entry.__bind = #value.keys > 0 and value.keys or nil
		entry.__hold = value.hold
		entry.__mobile = value.mobile
	end

	function store.bindOf(entry)
		return {keys = entry.__bind, hold = entry.__hold, mobile = entry.__mobile}
	end

	-- A saved position, or nil when the entry holds none.
	function store.spot(value)
		if type(value) == 'table' and isFiniteNumber(value.x) and isFiniteNumber(value.y) then
			return value.x, value.y
		end
		return nil
	end

	--[[ Entries and the objects they belong to. ]]

	-- The key an object saves under, and the key the converter gave its old entry.
	function store.entryKeys(object)
		local name = object.name
		return object.label or ui.prettify(name), ui.prettify(name)
	end

	--[[ Gives an object its entry, or nil when the profile has none. The converter cannot know the label
	a module was given in code, so an entry it wrote sits under the prettified saved name: the
	object takes that one when there is none under its own name, and saves under its own from then
	on. A value kept from the profile before this one is dropped. ]]
	function store.adopt(object)
		local key, old = store.entryKeys(object)
		local entries = store.profile
		local entry = entries[key]
		if old ~= key and entries[old] ~= nil then
			local other = entries[old]
			if type(entry) ~= 'table' then
				entry = other
			elseif type(other) == 'table' then
				for field, value in other do
					if entry[field] == nil then
						entry[field] = value
					end
				end
			end
			entries[old] = nil
			entries[key] = entry
		end
		store.applied[object] = true
		if type(object.options) == 'table' then
			for _, option in object.options do
				store.kept[option] = nil
			end
		end
		return type(entry) == 'table' and entry or nil
	end

	-- Every overlay, module and legit module there is now, as one list a load can walk across yields.
	function store.objects()
		local list = {}
		for _, category in slinky.categories do
			if category.kind == 'overlay' then
				table.insert(list, category)
			end
		end
		for _, order in {slinky.moduleOrder, slinky.legit and slinky.legit.order or {}} do
			for index = 1, #order do
				table.insert(list, order[index])
			end
		end
		return list
	end

	-- Whether an object in such a list is still the one registered under its name.
	function store.registered(object)
		if object.kind == 'overlay' then
			return slinky.categories[object.name] == object
		elseif object.kind == 'legitModule' then
			return slinky.legit.modules[object.name] == object
		end
		return slinky.modules[object.name] == object
	end

	--[[ A profile holds what the user chose, never a default. The lobby and a match register different
	modules under one name, each with defaults of its own, and they share an entry: a default one of
	them wrote there would be loaded by the other as if it had been chosen. So what a thing saves the
	moment it is built is remembered here, and a key the file does not hold is written only once the
	value under it has left that. A key that is absent means the default of the place that reads it. ]]
	function store.built(thing)
		if type(thing) == 'table' and type(thing.save) == 'function' then
			local ok, saved = pcall(thing.save, thing)
			store.defaults[thing] = ok and {saved = store.copy(saved)} or nil
		end
		return thing
	end

	-- The state of an entry that has a default: where an overlay or a widget sits, and an overlay's pin.
	local DEFAULTED = {'__pinned', '__pos'}

	--[[ Takes out of what an object saves the keys the file does not hold and nobody has changed. A
	fixed overlay (the Mod Overlay) is placed by the menu, never by hand, on each device where that
	suits it: its __pos stays what the file held there, nothing when it held nothing. ]]
	local function chosen(object, own, held)
		held = type(held) == 'table' and held or {}
		local options = type(object.options) == 'table' and object.options or {}
		local keys = store.optionKeys(options)
		for name, option in options do
			local key, built = keys[name], store.defaults[option]
			if key and built and held[key] == nil and store.same(own[key], built.saved) then
				own[key] = nil
			end
		end
		local built = store.defaults[object]
		if built and type(built.saved) == 'table' then
			local placed = rawget(object, 'fixed') == true
			for _, key in DEFAULTED do
				if placed and key == '__pos' then
					own[key] = store.copy(held[key])
				elseif held[key] == nil and store.same(own[key], built.saved[key]) then
					own[key] = nil
				end
			end
		end
		return own
	end

	--[[ The entry an object is handed to load. Over the profile it had before, what this one does not
	say goes back to where the object started, its on/off for this place too; the options do the same
	for themselves (slinky:loadOptions). ]]
	function store.entryFor(object, entry)
		local copy = store.copy(entry)
		local built = store.defaults[object]
		if store.reapplied and built and type(built.saved) == 'table' then
			for _, key in DEFAULTED do
				if copy[key] == nil then
					copy[key] = store.copy(built.saved[key])
				end
			end
			local on = store.onKey()
			if copy[on] == nil then
				copy[on] = built.saved[on]
			end
		end
		return copy
	end

	local function mergeEntry(held, own, owned)
		if type(held) ~= 'table' then
			return own
		end
		local entry = table.clone(held)
		for _, key in owned do
			entry[key] = nil
		end
		for key, value in own do
			entry[key] = value
		end
		return entry
	end

	-- A settings entry: its `__` keys are its object's own; option keys nobody here has are kept.
	local function mergeSettings(held, own)
		if type(held) ~= 'table' then
			return own
		end
		local entry = {}
		for key, value in held do
			if type(key) ~= 'string' or key:sub(1, 2) ~= '__' then
				entry[key] = value
			end
		end
		for key, value in own do
			entry[key] = value
		end
		return entry
	end

	-- The members of slinky.categories that settings.json holds, and their keys there.
	local function settingsCategories()
		local names = {}
		for name, category in slinky.categories do
			if type(name) == 'string' and category.kind ~= 'overlay' and type(category.save) == 'function' then
				table.insert(names, name)
			end
		end
		table.sort(names)
		return names, store.keys(names)
	end

	local function settingsPanes()
		local names = {}
		for name in slinky.settings do
			if type(name) == 'string' then
				table.insert(names, name)
			end
		end
		table.sort(names)
		return names, store.keys(names)
	end

	--[[ What both files should hold now: what they held, with every object's own state over it. An
	object that registered after the profile was applied and has not been given its entry yet is
	left as the file has it, so its defaults cannot replace saved settings; one with no entry to
	wait for counts as given. The profile list is saved as the settings file's own profiles, not
	inside its category. ]]
	function store.gather(selected)
		local profile = table.clone(store.profile)
		for _, object in store.objects() do
			local key, old = store.entryKeys(object)
			if store.applied[object] or (profile[key] == nil and profile[old] == nil) then
				store.applied[object] = true
				local own = object:save()
				if type(own) == 'table' then
					profile[key] = mergeEntry(profile[key], chosen(object, own, profile[key]), OWNED[object.kind] or {})
				end
			end
		end

		local settings = table.clone(store.settings)
		settings.profile = selected
		local categories = table.clone(named(settings.categories))
		local names, keys = settingsCategories()
		for _, name in names do
			local own = slinky.categories[name]:save()
			if type(own) == 'table' then
				if name == 'Profiles' then
					settings.profiles, own.__items = own.__items, nil
				end
				categories[keys[name]] = mergeSettings(categories[keys[name]], own)
			end
		end
		settings.categories = categories

		local panes = table.clone(named(settings.settings))
		names, keys = settingsPanes()
		for _, name in names do
			local own = slinky.settings[name]:save()
			if type(own) == 'table' then
				panes[keys[name]] = mergeSettings(panes[keys[name]], own)
			end
		end
		settings.settings = panes
		return profile, settings
	end

	-- Applies settings.json to the menu: the panes, then the lists and windows.
	function store.applySettings(settings)
		local panes = named(settings.settings)
		local names, keys = settingsPanes()
		for _, name in names do
			local entry = panes[keys[name]]
			if type(entry) == 'table' then
				slinky.settings[name]:load(store.copy(entry))
			end
		end

		local categories = named(settings.categories)
		names, keys = settingsCategories()
		for _, name in names do
			local entry = store.copy(categories[keys[name]])
			if name == 'Profiles' and type(settings.profiles) == 'table' then
				entry = type(entry) == 'table' and entry or {}
				entry.__items = store.copy(settings.profiles)
			end
			if type(entry) == 'table' then
				slinky.categories[name]:load(entry)
			end
		end
	end

	--[[ The converter: old profiles (profiles/<name><placeId>.txt, with <gameId>.gui.txt for the menu's
	own state) to the files above. It runs once per profile, at start. A saved state converts by its
	shape, so a module this place never loads converts like any other. Everything the old loader
	repaired on each load is repaired here, once. tools/profile_reference.py in the rewrite folder does
	the same steps and is what this is checked against. ]]

	--[[ Converts an old profile's bind to its keys, whether it holds, and the mobile button's spot.
	Files from before v1 hold the bare list of keys. ]]
	local function convertBind(bind)
		if type(bind) ~= 'table' then
			return {}, false, nil
		end
		if isList(bind) then
			return table.clone(bind), false, nil
		end
		local mobile = bind.Mobile
		local spot
		if isObject(mobile) and type(mobile.X) == 'number' and type(mobile.Y) == 'number' then
			spot = {x = mobile.X, y = mobile.Y}
		end
		return isList(bind.Keys) and table.clone(bind.Keys) or {}, bind.Hold == true, spot
	end

	local function only(state, allowed)
		for key in state do
			if not table.find(allowed, key) then
				return false
			end
		end
		return true
	end

	local function numbers(state, ...)
		for _, key in {...} do
			if type(state[key]) ~= 'number' then
				return false
			end
		end
		return true
	end

	local TARGETS = {'Players', 'NPCs', 'Walls', 'Invisible', 'Milo'}

	--[[ Turns one saved option state of the old format into its value in the new profile file. A toggle
	without a bind is saved as its bare on/off, and the menu's accent as its preset number unless it
	is a colour of its own. A shape nobody knows is kept as it is. ]]
	local function convertOption(state)
		if not isObject(state) or next(state) == nil then
			return state
		end
		if type(state.Enabled) == 'boolean' and only(state, {'Enabled', 'Bind'}) then
			local keys, hold, mobile = convertBind(state.Bind)
			if #keys == 0 and not hold and not mobile then
				return state.Enabled
			end
			return {__on = state.Enabled, __bind = #keys > 0 and keys or nil, __hold = hold or nil, __mobile = mobile}
		end
		if type(state.Value) == 'number' and only(state, {'Value', 'Max'}) then
			return state.Value
		end
		if state.Value ~= nil and type(state.Value) ~= 'table' and only(state, {'Value'}) then
			return state.Value
		end
		if numbers(state, 'Hue', 'Sat', 'Value') and only(state, {'Hue', 'Sat', 'Value', 'Opacity', 'Rainbow', 'RainbowOffset'}) then
			local value = store.color(state.Hue, state.Sat, state.Value)
			if type(state.Opacity) == 'number' and math.abs(state.Opacity - 1) > 1e-9 then
				value.a = store.tidy(state.Opacity)
			end
			if state.Rainbow == true then
				value.rainbow = true
				if type(state.RainbowOffset) == 'number' and math.abs(state.RainbowOffset) > 1e-9 then
					value.rainbow_offset = store.tidy(state.RainbowOffset)
				end
			end
			return value
		end
		if numbers(state, 'Hue', 'Sat', 'Value') and (state.Notch ~= nil or state.CustomColor ~= nil)
			and only(state, {'Hue', 'Sat', 'Value', 'Notch', 'CustomColor', 'Rainbow'}) then
			if state.Rainbow ~= true and state.CustomColor ~= true and type(state.Notch) == 'number' then
				return {preset = state.Notch}
			end
			local value = store.color(state.Hue, state.Sat, state.Value)
			value.rainbow = state.Rainbow == true or nil
			return value
		end
		if state.ValueMin ~= nil and state.ValueMax ~= nil and only(state, {'ValueMin', 'ValueMax'}) then
			return {min = state.ValueMin, max = state.ValueMax}
		end
		if isList(state.List) and isList(state.ListEnabled) and only(state, {'List', 'ListEnabled'}) then
			return store.list(state.List, state.ListEnabled)
		end
		if only(state, TARGETS) then
			local value = {}
			for key, held in state do
				if type(held) ~= 'boolean' then
					return state
				end
				value[key:lower()] = held
			end
			return value
		end
		if state.Keys ~= nil and only(state, {'Keys', 'Hold', 'Mobile'}) then
			local keys, hold, mobile = convertBind(state)
			return {keys = keys, hold = hold or nil, mobile = mobile}
		end
		if isList(state.Items) and only(state, {'Items'}) then
			local items = {}
			for _, item in state.Items do
				if not (isObject(item) and item.Id ~= nil and item.Color ~= nil and only(item, {'Id', 'Color'})) then
					return state
				end
				table.insert(items, {id = item.Id, color = item.Color})
			end
			return items
		end
		return state
	end

	local function convertOptions(options, value)
		if not isObject(options) then
			return
		end
		local names = sortedNames(options)
		local keys = store.keys(names)
		for _, name in names do
			value[keys[name]] = convertOption(options[name])
		end
	end

	local function near(value, target)
		return type(value) == 'number' and math.abs(value - target) < 1e-3
	end

	--[[ Makes on an old-format profile the repairs the old-format loader made on every load. Before v1 a
	module's bind was the bare list of keys, and no module could be hidden. PromptChanger takes the
	options of FastProxPrompt and InteractExtender, which it replaced, and Killaura's Swing range is
	copied to Scan range.

	A Text GUI entry with DefaultsVersion below 4 moves each option that still holds a default an
	earlier build shipped to the current one; anything changed by hand stays, and a phone keeps its
	Scale. The details colour moves off the earlier greys. Render background is switched on only
	where no backdrop was the old Text GUI's default: a profile with no Padding X, or one still on
	its Arial font. ]]
	local function repair(data, mobile)
		local modules = named(data.Modules)
		if data.v ~= 1 then
			for _, entry in modules do
				if isObject(entry) then
					entry.Bind = {Keys = entry.Bind}
					entry.Visible = true
				end
			end
		end

		local prompt
		for _, name in {'PromptChanger', 'FastProxPrompt', 'InteractExtender'} do
			if isObject(modules[name]) then
				prompt = modules[name]
				break
			end
		end
		if prompt and (modules.FastProxPrompt ~= nil or modules.InteractExtender ~= nil) then
			if not isObject(prompt.Options) then
				prompt.Options = {}
			end
			local fast = named(named(modules.FastProxPrompt).Options)
			local extender = named(named(modules.InteractExtender).Options)
			for _, option in {'Mode', 'Modifier'} do
				if fast[option] ~= nil and prompt.Options[option] == nil then
					prompt.Options[option] = fast[option]
				end
			end
			if extender.Range ~= nil and prompt.Options.Range == nil then
				prompt.Options.Range = extender.Range
			end
			modules.PromptChanger = prompt
			modules.FastProxPrompt = nil
			modules.InteractExtender = nil
		end

		local options = named(named(modules.Killaura).Options)
		if options['Swing range'] ~= nil and options['Scan range'] == nil then
			options['Scan range'] = options['Swing range']
		end

		local overlay = named(data.Categories)['Text GUI']
		options = isObject(overlay) and overlay.Options
		if isObject(options) and (type(overlay.DefaultsVersion) == 'number' and overlay.DefaultsVersion or 1) < 4 then
			for name, change in {
				Scale = {{0.8, 1}, 1.2},
				['Padding X'] = {{6, 5, 3}, 4},
				['Padding Y'] = {{2}, 1},
				Rounding = {{3}, 5},
				Transparency = {{0.3, 0.28}, 0.5}
			} do
				local saved = options[name]
				if isObject(saved) and not (name == 'Scale' and mobile) then
					for _, old in change[1] do
						if near(saved.Value, old) then
							saved.Value = change[2]
							break
						end
					end
				end
			end
			local details = options['Details color']
			if isObject(details) and details.Rainbow ~= true and (details.Opacity == nil or near(details.Opacity, 1))
				and ((near(details.Hue, 0.7143) and near(details.Sat, 0.0432) and near(details.Value, 0.6353))
					or (near(details.Sat, 0) and (near(details.Value, 0.64) or near(details.Value, 0.6) or near(details.Value, 0.6118)))) then
				details.Hue, details.Sat, details.Value = 0.0556, 0, 0.7355
			end
			local animations = options.Animations
			if isObject(animations) and animations.Enabled == false then
				animations.Enabled = true
			end
			local background = options['Render background']
			if isObject(background) and background.Enabled == false
				and (options['Padding X'] == nil or (isObject(options.Font) and options.Font.Value == 'Arial')) then
				background.Enabled = true
			end
		end
	end

	local function convertSpot(position)
		if isObject(position) and type(position.X) == 'number' and type(position.Y) == 'number' then
			return {x = position.X, y = position.Y}
		end
		return nil
	end

	local function convertEntry(section, entry)
		local value = {__on = entry.Enabled == true}
		if entry.Bind ~= nil then
			local keys, hold, mobile = convertBind(entry.Bind)
			value.__bind = #keys > 0 and keys or nil
			value.__hold = hold or nil
			value.__mobile = mobile
		end
		if section == 'Modules' and entry.Visible == false then
			value.__hidden = true
		end
		if section == 'Categories' then
			value.__pinned = entry.Pinned == true
		end
		value.__pos = convertSpot(entry.Position)
		convertOptions(entry.Options, value)
		return value
	end

	-- One place's entry over what another gave: its lack of a bind, a position or a hidden card wins too.
	local function layOver(merged, value)
		for _, meta in SHARED do
			if value[meta] == nil then
				merged[meta] = nil
			end
		end
		for field, held in value do
			merged[field] = held
		end
		return merged
	end

	--[[ One profile from its old files, each {place, data}, the match file first. The match file's
	on/off becomes __on and the lobby file's __lobby; everything else is merged, the match file
	winning. Overlays are told from the old menu lists by their Pinned. ]]
	function store.convertProfile(used, mobile)
		local result = {}
		for index = #used, 1, -1 do
			local place, data = used[index][1], used[index][2]
			repair(data, mobile)
			for _, section in {'Modules', 'Legit', 'Categories'} do
				local entries = named(data[section])
				for _, name in sortedNames(entries) do
					local entry = entries[name]
					if isObject(entry) and not (section == 'Categories' and entry.Pinned == nil) then
						local key = ui.prettify(name)
						local value = convertEntry(section, entry)
						if place == LOBBY_PLACE then
							value.__lobby, value.__on = value.__on, nil
						end
						local merged = result[key]
						result[key] = merged and layOver(merged, value) or value
					end
				end
			end
		end
		return result
	end

	--[[ An export an older build made is one place of a profile. Brought into a profile that exists it
	replaces that place's part and leaves the rest: the other place's on/off, the entries and the
	option keys it does not name. Its entries sit under the names the converter gives them, so one
	that a module here keeps under its menu name is laid over that one. Options alone (store.optionsOf)
	are set and leave the rest of an entry as it is. ]]
	function store.mergeImport(held, entries, optionsOnly)
		local profile = table.clone(held)
		for _, object in store.objects() do
			local key, old = store.entryKeys(object)
			if old ~= key and entries[old] ~= nil and entries[key] == nil and profile[old] == nil then
				entries[key], entries[old] = entries[old], nil
			end
		end
		for key, entry in entries do
			local before = profile[key]
			if type(before) ~= 'table' then
				profile[key] = entry
			elseif optionsOnly then
				local merged = table.clone(before)
				for field, value in entry do
					merged[field] = value
				end
				profile[key] = merged
			else
				profile[key] = layOver(table.clone(before), entry)
			end
		end
		return profile
	end

	-- Whether two places keep their profiles in one file: BedWars' lobby and its matches do.
	function store.sameFile(first, second)
		first, second = tostring(first), tostring(second)
		local bedwars = {[MATCH_PLACE] = true, [LOBBY_PLACE] = true}
		return first == second or bedwars[first] == true and bedwars[second] == true
	end

	--[[ What an older build's export of another game can bring: its options. Its on/off is that game's,
	and so are its binds, places and hidden cards; an entry with no options brings nothing. ]]
	function store.optionsOf(entries)
		local out = {}
		for key, entry in entries do
			local options = {}
			for field, value in entry do
				if type(field) ~= 'string' or field:sub(1, 2) ~= '__' then
					options[field] = value
				end
			end
			if next(options) ~= nil then
				out[key] = options
			end
		end
		return out
	end

	local function convertRow(row)
		local keys, hold, mobile = convertBind(row.Bind)
		return {
			name = row.Name,
			keys = #keys > 0 and keys or nil,
			hold = hold or nil,
			mobile = mobile,
			used = type(row.Used) == 'number' and row.Used or nil
		}
	end

	--[[ Turns a decoded <gameId>.gui.txt into the contents of settings.json. Overlays (they have Pinned)
	are profile state and are left out, and a file from before v1 has no Main settings to use. A GUI
	Theme with ThemeVersion below 2 still on the teal preset (Notch 4) moves to the orange one
	(Notch 2). The Profiles list becomes the profile list; other lists keep rows with a name and a
	key, or plain names. ]]
	function store.convertSettings(gui)
		local out = {}
		if type(gui.Profile) == 'string' then
			out.profile = gui.Profile
		end
		local saved = named(gui.Categories)
		local names = {}
		for _, name in sortedNames(saved) do
			if isObject(saved[name]) and saved[name].Pinned == nil and not (name == 'Main' and gui.v ~= 1) then
				table.insert(names, name)
			end
		end
		local keys = store.keys(names)
		local categories = {}
		for _, name in names do
			local entry = saved[name]
			local value = {__pos = convertSpot(entry.Position)}
			if name == 'Main' then
				local panes = named(entry.Settings)
				local theme = named(panes.Settings)['GUI Theme']
				if isObject(theme) and (type(entry.ThemeVersion) == 'number' and entry.ThemeVersion or 1) < 2
					and theme.Rainbow ~= true and theme.CustomColor ~= true and theme.Notch == 4 then
					theme.Notch = 2
				end
				local paneNames = {}
				for _, pane in sortedNames(panes) do
					if isObject(panes[pane]) then
						table.insert(paneNames, pane)
					end
				end
				local paneKeys = store.keys(paneNames)
				local settings = {}
				for _, pane in paneNames do
					local held = {}
					convertOptions(panes[pane], held)
					settings[paneKeys[pane]] = held
				end
				if next(settings) ~= nil then
					out.settings = settings
				end
			else
				value.__on = entry.Enabled == true
				value.__open = entry.Expanded == true
				local rows = entry.List
				if isList(rows) then
					local hasRows = name == 'Profiles'
					for _, row in rows do
						hasRows = hasRows or type(row) == 'table'
					end
					local items
					if hasRows then
						items = {}
						for _, row in rows do
							if isObject(row) and type(row.Name) == 'string' then
								table.insert(items, convertRow(row))
							end
						end
					else
						items = store.list(rows, isList(entry.ListEnabled) and entry.ListEnabled or {})
					end
					if name == 'Profiles' then
						out.profiles = items
					else
						value.__items = items
					end
				end
				if type(entry.Selected) == 'string' then
					value.__selected = entry.Selected
				end
				convertOptions(entry.Options, value)
			end
			categories[keys[name]] = value
		end
		if next(categories) ~= nil then
			out.categories = categories
		end
		return out
	end

	-- 'legit6872274481' is 'legit' and its place. Known profile names settle a name that ends in digits.
	local function splitName(stem, known)
		for _, place in {MATCH_PLACE, LOBBY_PLACE} do
			if #stem > #place and stem:sub(-#place) == place then
				return stem:sub(1, -#place - 1), place
			end
		end
		local longest = {}
		for name in known do
			table.insert(longest, name)
		end
		table.sort(longest, function(a, b)
			return #a > #b
		end)
		for _, name in longest do
			local rest = stem:sub(#name + 1)
			if stem:sub(1, #name) == name and rest:match('^%d+$') then
				return name, rest
			end
		end
		local name, place = stem:match('^(.-)(%d+)$')
		if name and name ~= '' then
			return name, place
		end
		return nil
	end

	local function readText(path)
		local ok, body = pcall(readfile, path)
		return ok and type(body) == 'string' and body or nil
	end

	local function readObject(path)
		local body = readText(path)
		local ok, data = pcall(function()
			return httpService:JSONDecode(body)
		end)
		return body ~= nil and ok and isObject(data) and data or nil
	end

	-- A new file counts once it reads back; one that does not is taken away again.
	local function writeChecked(path, text)
		if pcall(writefile, path, text) and loadJson(path) then
			return true
		end
		if type(delfile) == 'function' then
			pcall(delfile, path)
		end
		return false
	end

	-- An old profile file as its table, or nil when the text is no such thing.
	local function decodeProfile(body)
		local ok, data = pcall(function()
			return httpService:JSONDecode(body)
		end)
		if body ~= nil and ok and isObject(data) and data.Modules ~= nil and isObject(data.Modules) then
			return data
		end
		return nil
	end

	--[[ Where an old file goes in profiles/old, and whether that is a copy of it that is there already.
	A copy is never overwritten: a file that differs from the one put away under its name goes beside
	it under a numbered one (legit6872274481.2.txt), so no old file has to stay behind for that. ]]
	local function archivePath(name, body)
		local to, copies = store.folder..'/old/'..name, 1
		while isfile(to) do
			if readText(to) == body then
				return to, true
			end
			copies += 1
			to = store.folder..'/old/'..name:sub(1, -5)..'.'..copies..name:sub(-4)
		end
		return to, false
	end

	--[[ Moves an old file into profiles/old: written there, read back, and only then deleted here.
	Without delfile the original stays, which costs nothing: its profile has a .json, so it is not
	converted again, and its copy is found again where it is. ]]
	local function archive(name)
		local from = store.folder..'/'..name
		local body = readText(from)
		if not body then
			return false
		end
		local to, there = archivePath(name, body)
		if not there then
			local ok, exists = pcall(isfolder, store.folder..'/old')
			if not (ok and exists) then
				pcall(makefolder, store.folder..'/old')
			end
			if not pcall(writefile, to, body) or readText(to) ~= body then
				return false
			end
		end
		return type(delfile) == 'function' and (pcall(delfile, from)) or false
	end

	--[[ A match or lobby file, or a menu file, that does not read is never put away as if it had been
	converted. It is kept as <name>.broken.txt beside where it was, the way a file that does not decode
	has always been set aside. Without delfile an empty old file takes its place, as the old build
	wrote one: the next start converts that, so a profile none of whose files reads does not block
	every start. Where its copy cannot be written it simply stays. ]]
	local function setAside(name, body)
		local from, to = store.folder..'/'..name, store.folder..'/'..name:sub(1, -5)..'.broken.txt'
		if not body then
			return false
		end
		if readText(to) ~= body and (not pcall(writefile, to, body) or readText(to) ~= body) then
			return false
		end
		if type(delfile) == 'function' then
			return (pcall(delfile, from))
		end
		local empty = name:sub(-8) == '.gui.txt' and '{"v":1,"Categories":{}}' or '{"v":1,"Categories":{},"Modules":{},"Legit":{}}'
		return pcall(writefile, from, empty) and readText(from) == empty
	end

	--[[ The old files of a profile that is reset or deleted, where they are still in profiles/ (their
	copy in profiles/old could not be written): a start converts a profile that has no file from them,
	which would bring it back. A profile that was renamed from 'settings' has its old files under that name. ]]
	function store.dropOld(name)
		if type(delfile) ~= 'function' or store.path(name) ~= bedwarsPath(name) then
			return
		end
		for _, stem in {name, store.oldName[name]} do
			for _, place in {MATCH_PLACE, LOBBY_PLACE} do
				local old = store.folder..'/'..stem..place..'.txt'
				if isfile(old) then
					pcall(delfile, old)
				end
			end
		end
	end

	-- A direct child of the profiles folder, whatever shape of path the executor lists.
	local function childName(path)
		local name = tostring(path):gsub('\\', '/')
		name = name:match('^.*profiles/(.+)$') or name
		return not name:find('/', 1, true) and name or nil
	end

	--[[ Profiles a sync brought in an older build's format, one name a line in profiles/profilesync.txt;
	the loader notes them the same way. The release ships them like that and each replaces the profile
	of its name, so the next store.convert converts their files over the .json the profile has, and
	then takes the note away. ]]
	local SYNC_NOTE = 'profilesync.txt'

	function store.syncedNames()
		local path, names = store.folder..'/'..SYNC_NOTE, {}
		local body = isfile(path) and readText(path)
		for name in (body or ''):gmatch('[^\n]+') do
			names[name] = true
		end
		return names
	end

	local function writeSynced(names)
		local path, list = store.folder..'/'..SYNC_NOTE, sortedNames(names)
		if #list > 0 then
			pcall(writefile, path, table.concat(list, '\n')..'\n')
		elseif type(delfile) == 'function' then
			pcall(delfile, path)
		else
			pcall(writefile, path, '')
		end
	end

	--[[ Notes which profiles a sync brought in the old format, from the paths that landed and the
	release's listing, so store.convert converts them at the next start. A profile shipped as
	<name>.json as well is not noted: that file is the profile. Nor is one until every place file of
	it that the release ships has landed and is in the folder when the note is written: a download
	worker goes on after the deadline, and a start in between may have moved a leftover to
	profiles/old. A file isfile does not report is not there. ]]
	function store.noteSynced(paths, listing)
		local names, shipped, added = store.syncedNames(), {}, false
		local wanted, landed = {}, {}
		local function count(into, file)
			for _, place in {MATCH_PLACE, LOBBY_PLACE} do
				local stem = file and file:match('^(.+)'..place..'%.txt$')
				if stem then
					into[stem] = (into[stem] or 0) + 1
				end
			end
		end
		for _, v in listing do
			local path = ({v.path:gsub(' ', '%%20')})[1]
			shipped[path] = true
			count(wanted, childName(path))
		end
		for _, path in paths do
			count(landed, childName(path))
		end
		local function allThere(stem)
			for path in shipped do
				local file, of = childName(path), {}
				count(of, file)
				if of[stem] then
					local ok, there = pcall(isfile, store.folder..'/'..file)
					if not (ok and there) then return false end
				end
			end
			return true
		end
		for stem, got in landed do
			if got == wanted[stem] and not shipped['profiles/'..stem..'.json'] and not names[stem] and allThere(stem) then
				names[stem], added = true, true
			end
		end
		if added then
			writeSynced(names)
		end
	end

	-- Whether a profile the running place keeps in BedWars' file is noted, and so is converted at the next start.
	function store.pendingSync(name)
		return store.path(name) == bedwarsPath(name) and store.syncedNames()[name] == true
	end

	--[[ Converts the old-format files in the profile folder at start: each profile's <name><place>.txt
	files into one profile file, and a menu file into settings.json. Files used, and leftovers of a
	profile converted before, go to profiles/old, and one that does not read is set aside. A start
	with no old file and no sync note returns without reading anything.

	settings.json is made from BedWars' menu file whatever game this is, as that file holds the
	profile list and menu settings; the running game's own counts only when BedWars' is missing or
	does not read. The names the menu lists settle a file name whose profile ends in digits. Where
	listfiles fails, the files of every profile the menu knew are looked up by name.

	Only the match and lobby place files are converted: another place's on/off would switch modules
	on in matches. A profile is made from the files that read; with none, nothing is written and it
	is marked unconverted, as slinky:load must not make it from defaults while its files are there.
	One converted before only has its leftovers put away, unless a sync brought them.

	A profile called settings would now be the menu's own file. It becomes 'settings profile', or
	the first 'settings profile N' no old profile has; while its old files remain it keeps the
	lowest such name settings.json lists that has its file. Names compare in any letter case, as
	most executors' disks ignore it. ]]
	function store.convert()
		local folder = store.folder
		local files, listed = {}, false
		if type(listfiles) == 'function' then
			local ok, paths = pcall(listfiles, folder)
			if ok and type(paths) == 'table' then
				listed = true
				for _, path in paths do
					local name = childName(path)
					if name then
						files[name] = true
					end
				end
			end
		end
		local ownGui, source = tostring(game.GameId)..'.gui.txt', BEDWARS_GUI
		for _, name in {BEDWARS_GUI, ownGui} do
			if not files[name] and isfile(folder..'/'..name) then
				files[name] = true
			end
		end
		if not files[source] then
			source = ownGui
		end

		local synced = store.syncedNames()
		local anyOld = next(synced) ~= nil
		for name in files do
			anyOld = anyOld or name:sub(-8) == '.gui.txt' or name:match('%d%.txt$') ~= nil
		end
		if not anyOld then
			return
		end

		local known, guis, selected = {}, {}, nil
		local settings = isfile(store.settingsPath) and readObject(store.settingsPath)
		for _, row in settings and isList(settings.profiles) and settings.profiles or {} do
			if isObject(row) and type(row.name) == 'string' then
				known[row.name] = true
			end
		end
		for name in files do
			if name:sub(-8) == '.gui.txt' then
				local gui = readObject(folder..'/'..name)
				guis[name] = gui or false
				if gui then
					if name == source and type(gui.Profile) == 'string' then
						selected = gui.Profile
					end
					local list = named(named(gui.Categories).Profiles).List
					for _, row in isList(list) and list or {} do
						if isObject(row) and type(row.Name) == 'string' then
							known[row.Name] = true
						end
					end
				end
			end
		end
		if not guis[source] and guis[ownGui] then
			source = ownGui
			selected = type(guis[ownGui].Profile) == 'string' and guis[ownGui].Profile or nil
		end
		for name, gui in guis do
			if gui == false then
				setAside(name, readText(folder..'/'..name))
			end
		end

		if not listed then
			local wanted = table.clone(known)
			wanted.default = true
			if selected then
				wanted[selected] = true
			end
			for name in synced do
				wanted[name] = true
			end
			for name in wanted do
				if usableProfileName(name) or name:lower() == 'settings' then
					for _, place in {MATCH_PLACE, LOBBY_PLACE, tostring(slinky.place)} do
						if isfile(folder..'/'..name..place..'.txt') then
							files[name..place..'.txt'] = true
						end
					end
				end
			end
		end

		local profiles = {}
		for name in files do
			if name:sub(-4) == '.txt' and name:sub(-8) ~= '.gui.txt' then
				local profile, place = splitName(name:sub(1, -5), known)
				if profile then
					profiles[profile] = profiles[profile] or {}
					table.insert(profiles[profile], {name = name, place = place})
				end
			end
		end

		local names, newName, taken = sortedNames(profiles), {}, {}
		for _, profile in names do
			taken[profile:lower()] = true
		end
		local given = {}
		for _, row in settings and isList(settings.profiles) and settings.profiles or {} do
			local listed = isObject(row) and type(row.name) == 'string' and row.name
			local number = listed and (listed == 'settings profile' and 1 or tonumber(listed:match('^settings profile ([1-9]%d*)$')))
			if number and isfile(bedwarsPath(listed)) then
				table.insert(given, {number, listed})
			end
		end
		table.sort(given, function(a, b)
			return a[1] < b[1]
		end)
		table.clear(store.oldName)
		for _, profile in names do
			if profile:lower() == 'settings' then
				local name, count
				for _, pair in given do
					if not taken[pair[2]] and not newName[pair[2]] then
						name = pair[2]
						break
					end
				end
				if not name then
					name, count = 'settings profile', 1
					while taken[name] or newName[name] do
						count += 1
						name = 'settings profile '..count
					end
				end
				newName[profile], newName[name] = name, name
				store.oldName[name] = profile
				newName.settings = newName.settings or name
			end
		end
		local function nameNow(name)
			return newName[name] or type(name) == 'string' and name:lower() == 'settings' and newName.settings or name
		end

		local converted, failed, partial, renamed, moves = 0, {}, {}, {}, {}
		for _, profile in names do
			local name = nameNow(profile)
			local target = bedwarsPath(name)
			local done = isfile(target) and not synced[profile]
			local used, unread = {}, 0
			for _, file in profiles[profile] do
				local body = readText(folder..'/'..file.name)
				if done and body and select(2, archivePath(file.name, body)) then
					table.insert(moves, file.name)
				else
					local data = decodeProfile(body)
					if file.place ~= MATCH_PLACE and file.place ~= LOBBY_PLACE then
						if data then
							table.insert(moves, file.name)
						end
					elseif not data then
						unread += 1
						setAside(file.name, body)
					elseif done then
						table.insert(moves, file.name)
					else
						table.insert(used, file.place == MATCH_PLACE and 1 or #used + 1, {file.place, data, file.name})
					end
				end
			end
			local written = false
			if #used > 0 then
				local ok, text = pcall(function()
					return store.profileText(store.convertProfile(used, isMobile()))
				end)
				written = ok and writeChecked(target, text)
			end
			if written then
				converted += 1
				for _, item in used do
					table.insert(moves, item[3])
				end
				if unread > 0 then
					table.insert(partial, name)
				end
				if name ~= profile then
					table.insert(renamed, {profile, name})
				end
			elseif not done and #used + unread > 0 then
				table.insert(failed, name)
				store.unconverted[target] = true
			end
		end
		if next(synced) ~= nil then
			writeSynced({})
		end

		local settingsConverted = false
		if not isfile(store.settingsPath) and guis[source] then
			local ok, text = pcall(function()
				local settings = store.convertSettings(guis[source])
				settings.profile = nameNow(settings.profile)
				for _, row in settings.profiles or {} do
					row.name = nameNow(row.name)
				end
				return store.settingsText(settings)
			end)
			settingsConverted = ok and writeChecked(store.settingsPath, text)
		end
		if isfile(store.settingsPath) then
			local bedwars = (settingsConverted and source == BEDWARS_GUI) or isfile(folder..'/old/'..BEDWARS_GUI)
				or type(settings) == 'table' and type(guis[BEDWARS_GUI]) == 'table'
			for name, gui in guis do
				if gui and (bedwars or (settingsConverted and name == source) or isfile(folder..'/old/'..name)) then
					table.insert(moves, name)
				end
			end
		end

		for _, name in moves do
			archive(name)
		end
		if converted > 0 or settingsConverted or #failed > 0 then
			store.converted = {count = converted, settings = settingsConverted, failed = failed, partial = partial, renamed = renamed}
		end
	end
end

--[[ The on/off an entry holds for the place this is: the lobby and matches each have their own.
With one argument it is read (nil when the entry does not say), with two it is written. Game code
that reads or changes a saved entry goes through this, never through the keys. ]]
function slinky:savedOn(entry, on)
	local key = store.onKey()
	if on == nil then
		local held = type(entry) == 'table' and entry[key]
		if type(held) == 'boolean' then
			return held
		end
		return nil
	end
	entry[key] = on and true or false
	return entry
end

-- The file of a profile in the place this is. main.lua asks, to set aside one that does not decode.
function slinky:profilePath(name)
	return store.path(name)
end

-- The key an option of this object has in the object's entry.
function slinky:optionKey(object, name)
	local keys = store.optionKeys(type(object.options) == 'table' and object.options or {})
	return keys[name] or store.snake(name)
end

--[[ What this option holds now is its default. For one whose default only code can know once it is
built (a list that comes in later): the code sets the value itself and calls this right after, so
a profile that never changed it does not save it (store.built). A module or an overlay that code
switches on once it is built is given its default the same way. ]]
function slinky:rebase(option)
	store.built(option)
end

--[[ Applies the settings file and a profile to every registered overlay and module, and returns the
count of modules on and whether saving is allowed (main.lua reads the second to fail the boot).

Applying yields (yieldBuild), so a profile switch or slinky:loadLate can start another load
mid-walk. Each load claims a generation and returns after a yield where a newer one took over,
leaving self.applying set for it. While self.applying is set, module toggles defer their functions,
and self.loaded stays false so nothing saves a mix of two profiles. buildclock is reset first, or
the first frame would apply a single category.

A bad profile name read from settings.json falls back to default, so a client crashing on every
inject can boot and write a sane file. A profile with no file is not written during the walk, which
would save only the modules registered so far when a game payload failed or yielded; its save is
requested at the end when self:canSave() allows. Old files that could not be converted keep saving
off: a file made now would hold defaults and be taken for their conversion.

The saves the toggles queued are dropped, not flushed: they would write back what was just read, at
the moment sixty module loops start. A toggle flipped by hand during the second a load takes is
saved only with the next change. ]]
function slinky:load(skipSettings, profile)
	self.loadGeneration += 1
	local generation = self.loadGeneration
	buildclock = os.clock()
	self.loaded = false
	self.applying = true
	local canSave = true
	local toggleCount = 0

	local settings
	if isfile(store.settingsPath) then
		settings = loadJson(store.settingsPath)
		if not settings then
			self:notify('Pistonware', 'Failed to load GUI settings.', 10, 'alert')
			canSave = false
		end
		self.profile = profile or (settings and settings.profile) or 'default'
	elseif profile then
		self.profile = profile
	end
	if not usableProfileName(self.profile) then
		self.profile = 'default'
	end
	if self.profileLabel then
		self.profileLabel.Text = #self.profile > 10 and self.profile:sub(1, 10)..'...' or self.profile
		self.profileLabel.Size = UDim2.fromOffset(getfontbounds(self.profileLabel.Text, self.profileLabel.TextSize, self.profileLabel.Font).X + 16, 24)
	end

	if not skipSettings then
		store.settings = settings or {}
		store.applySettings(store.settings)
	end

	if not self.categories.Profiles:find('default') then
		self.categories.Profiles:change('default', true)
	end

	local path = store.path(self.profile)
	local entries = {}
	local unconverted = store.unconverted[path] or store.unconverted['*']
	local fromFile = isfile(path)
	if fromFile then
		entries = loadJson(path)
		if not entries then
			entries = {}
			self:notify('Pistonware', 'Failed to load '..self.profile..' profile.', 10, 'alert')
			canSave = false
		end
		unconverted = false
	elseif unconverted then
		canSave = false
		self.pendingProfileCreate = nil
	else
		self.pendingProfileCreate = canSave and true or nil
	end
	store.profile = entries
	store.applied = setmetatable({}, {__mode = 'k'})
	store.reapplied, store.loadedOnce = store.loadedOnce == true and fromFile, true

	for _, object in store.objects() do
		if store.registered(object) then
			local entry = store.adopt(object)
			if entry or store.reapplied then
				object:load(store.entryFor(object, entry or {}))
				yieldBuild()
				if self.loadGeneration ~= generation then return end
			end
			if object.kind == 'module' then
				toggleCount += object.enabled and 1 or 0
			end
		end
	end

	self:updateOverlay(true)

	if canSave then
		self:notify('Pistonware', 'Loaded profile '..self.profile, 3, 'success')
		self:notify('Pistonware', 'Enabled '..toggleCount..(toggleCount == 1 and ' mod' or ' mods'), 3)
	end

	local report = store.converted
	local unsaved = unconverted and 'Nothing is saved while '..self.profile..' is selected.' or nil
	if report then
		store.converted = nil
		local said = {}
		if report.count > 0 then
			table.insert(said, 'Converted '..report.count..(report.count == 1 and ' profile' or ' profiles')..' to the new format. The old files are in profiles/old.')
		elseif report.settings then
			table.insert(said, 'Converted your menu settings to the new format.')
		end
		for _, pair in report.renamed do
			table.insert(said, "The profile '"..pair[1].."' is now called '"..pair[2].."'.")
		end
		if #report.partial > 0 then
			table.insert(said, 'Converted '..table.concat(report.partial, ', ')..' from one place only: its other file could not be read.')
		end
		if #report.failed > 0 then
			table.insert(said, 'Could not convert '..table.concat(report.failed, ', ')..': the old files were kept.')
		end
		table.insert(said, unsaved)
		local alert = #report.failed > 0 or #report.partial > 0
		self:notify('Pistonware', table.concat(said, ' '), 10, alert and 'alert' or nil)
	elseif unsaved then
		self:notify('Pistonware', 'The old files of '..self.profile..' could not be read. '..unsaved, 10, 'alert')
	end

	if self.downloader then
		self.downloader:Destroy()
		self.downloader = nil
	end

	self.loaded = canSave
	self.applying = nil
	ui.anim.LoadEnded = os.clock()
	self.loadedCount = #self.moduleOrder
	self.saveNeeded = nil
	if self.pendingProfileCreate and self:canSave() then
		self.pendingProfileCreate = nil
		self:requestSave()
	end

	if not skipSettings then
		self:ensureMenuButton()
	end

	return toggleCount, canSave
end

--[[ Builds the on-screen button that opens the menu on a phone. It checks isMobile, not TouchEnabled: a
Mac reporting touch has a keyboard for the menu bind. It is called at the end of LoadGUI as well as
of slinky:load, because an inject can go without a finished load (main.lua skips it when the game
payload fails or does not signal within 120 s, a module's load can throw, a newer load returns from
it early), and a phone without the button has no way into the menu. A button still parented is kept.

The piston face is 8 by 8 cells, not an image: on a touch device this GUI draws uploaded ids and
never files. The CanvasGroup's UICorner clips the cells, and each reaches one pixel into the next so
no seam shows. Hide Pistonware Mobile Button works through transparency rather than Visible, and the
Mod Overlay is placed again to keep clear of the button. ]]
function slinky:ensureMenuButton()
	if not (isMobile() and gui) then return end
	if self.menuButton and self.menuButton.Parent then return end

	local PISTON_FACE = {
		'474747 E2731D DE711D FF9025 ED781F D96F1C D56C1C 474747',
		'363636 D06A1B D36B1B EF7A1F D86E1C D86E1C D76D1C 363636',
		'191919 F07A1F 090909 232323 181818 F07A1F 090909 161616',
		'171717 F07A1F 090909 353535 252525 F07A1F 090909 191919',
		'171717 363636 313131 333333 373737 2C2C2C 292929 191919',
		'1C1C1C 343434 090909 090909 090909 090909 2D2D2D 1E1E1E',
		'1A1A1A 2B2B2B 2E2E2E 090909 F07A1F F07A1F 313131 161616',
		'191919 1B1B1B 171717 1E1E1E 191919 1D1D1D 161616 131313'
	}
	local button = Instance.new('TextButton')
	button.AutoButtonColor = false
	button.BackgroundColor3 = Color3.fromRGB(22, 22, 22)
	button.BackgroundTransparency = 0
	button.BorderSizePixel = 0
	button.Position = slinkyButtonFallback
	button.Size = UDim2.fromOffset(slinkyButtonSize, slinkyButtonSize)
	button.Text = ''
	button.Parent = gui
	addCorner(button, UDim.new(0, 8))
	local face = Instance.new('CanvasGroup')
	face.Name = 'Face'
	face.BackgroundTransparency = 1
	face.BorderSizePixel = 0
	face.Size = UDim2.fromScale(1, 1)
	face.Parent = button
	addCorner(face, UDim.new(0, 8))
	for row, line in PISTON_FACE do
		local column = 0
		for hex in line:gmatch('%x+') do
			local cell = Instance.new('Frame')
			cell.BackgroundColor3 = Color3.fromHex(hex)
			cell.BorderSizePixel = 0
			cell.Position = UDim2.fromScale(column / 8, (row - 1) / 8)
			cell.Size = UDim2.new(1 / 8, 1, 1 / 8, 1)
			cell.Parent = face
			column += 1
		end
	end
	local stroke = Instance.new('UIStroke')
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Color = Color3.fromRGB(52, 52, 52)
	stroke.Thickness = 1
	stroke.Parent = button
	anchorSlinkyButton(button)

	self.menuButton = button
	self.menuButtonFace = face
	self.menuButtonStroke = stroke
	self.menuButtonTransparency = button.BackgroundTransparency
	if self.hideMenuButton and self.hideMenuButton.enabled then
		button.BackgroundTransparency = 1
		face.GroupTransparency = 1
		stroke.Transparency = 1
	end
	pcall(ui.applyHudZoom)

	button.MouseButton1Click:Connect(function()
		if self.menuBind then
			self.menuBind.triggered:Fire(true)
		end
	end)
end

--[[
	Apply the current profile to whatever registered after it was loaded.

	The payload is the reason this exists. A protected bedwars.lua can still be registering when
	the profile is applied -- either because it never signals that it is done, or because it took
	longer than the backstop -- and every module that arrives afterwards would otherwise sit on
	its defaults with its real settings still on disk, untouched.

	Only objects that have not been given their entry are touched. Modules the user changed by hand
	took theirs at the load and are not revisited, which is what makes running this at an arbitrary
	later moment safe. Until it has run, slinky:save leaves a late object's entry as the file has it.
]]
function slinky:loadLate()
	if shared.PistonwareBootFailed or not self.profile then return 0 end

	self.loadGeneration += 1
	local generation = self.loadGeneration
	self.applying = true
	local applied = 0

	for _, object in store.objects() do
		if not store.applied[object] and store.registered(object) then
			local entry = store.adopt(object)
			if entry then
				pcall(object.load, object, store.copy(entry))
				applied += 1
				yieldBuild()
				if self.loadGeneration ~= generation then return applied end
			end
		end
	end

	self.loadedCount = #self.moduleOrder
	self.applying = nil
	ui.anim.LoadEnded = os.clock()
	return applied
end

--[[ Gives an object's options their values from its entry. A value the option cannot hold exactly (a
missing choice, a number out of range, another module's type under the same name) leaves it on its
fallback and goes into store.kept, so the next save writes it back. The names are taken first: an
option's function may add options during the walk. After a profile that moved it, an option the
entry leaves out goes back to its built default. ]]
function slinky:loadOptions(obj, entry)
	if type(entry) ~= 'table' or type(obj.options) ~= 'table' then return end
	local keys, names = store.optionKeys(obj.options)
	for _, name in names do
		local option = obj.options[name]
		local value = entry[keys[name]]
		if value ~= nil and type(option) == 'table' and type(option.load) == 'function' then
			option:load(value)
			store.kept[option] = nil
			if not option.transient and type(option.save) == 'function' then
				local shown = option:save()
				if not store.same(shown, value) then
					store.kept[option] = {saved = store.copy(value), shown = store.copy(shown)}
				end
			end
		elseif value == nil and store.reapplied then
			local built = store.defaults[option]
			if built and built.saved ~= nil and type(option.load) == 'function' and not store.same(option:save(), built.saved) then
				option:load(store.copy(built.saved))
			end
		end
	end
end

--[[
	LoadGUI, split into the pieces it builds. One function per piece keeps every one of them well
	clear of Luau's 200-register limit, which the single LoadGUI was sitting right against.
]]
local build = {}

--[[ Builds the root ScreenGui, its scaled layer, the menu frame, the cursor and the row hint pill, and
connects the menu's Visible watcher, the hint refresh and the Escape sources.

On Solara the menu goes in PlayerGui: its signal callbacks cannot read anything inside gethui's
container or CoreGui ('lacking capability Plugin'), and probing for that did not work. Elsewhere
with setthreadidentity it goes in gethui on desktop and CoreGui on touch devices, where the client
empties the gethui container and a ScreenGui destroyed under the menu can crash it. PlayerGui is the
fallback when neither parent takes.

The menu frame sits at ZIndex 3, above HUD windows and widgets at 2, with the dim at 0.
slinky.menuOpen mirrors its visibility, as reading the Instance from a thread without the raised
identity throws. The Visible watcher defers its work, still inside the frame the menu opened or
shut: hints and hover lights reset, the shut hooks (on a shut) and ui.menuHooks run under pcall,
then layout.MenuShown. Escape comes from the key and from Roblox's menu opening. A key press is
stamped so one press acts once; a click or tap is remembered so Roblox's menu opened by its own
button is not taken for Escape, and a text box letting go of the keyboard so Escape in it only ends
the typing. Each acts after its event, never inside it, and each signal is looked up under pcall. ]]
function build.root()
	addMaid(slinky)
	gui = Instance.new('ScreenGui')
	gui.Name = randomString()
	gui.DisplayOrder = 9999999
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.IgnoreGuiInset = true

	local callbacksBlocked = false
	pcall(function()
		callbacksBlocked = tostring(identifyexecutor and identifyexecutor() or ''):lower():find('solara', 1, true) ~= nil
	end)
	if slinky.threadFix and not callbacksBlocked then
		pcall(function() gui.OnTopOfCoreBlur = true end)
		local hidden = (not inputService.TouchEnabled) and gethui and select(2, pcall(gethui)) or nil
		if typeof(hidden) ~= 'Instance' or hidden:IsA('LayerCollector') then
			hidden = nil
		end
		local parented = pcall(function()
			gui.Parent = hidden or cloneref(game:GetService('CoreGui'))
		end) and gui.Parent ~= nil
		if not parented then
			gui.Parent = cloneref(game:GetService('Players')).LocalPlayer.PlayerGui
			gui.ResetOnSpawn = false
		end
		local holder = Instance.new('Folder')
		if pcall(function() holder.Parent = cloneref(game:GetService('CoreGui')) end) then
			slinky.holder = holder
		else
			holder:Destroy()
			slinky.holder = gui
		end
	else
		gui.Parent = cloneref(game:GetService('Players')).LocalPlayer.PlayerGui
		gui.ResetOnSpawn = false
		slinky.holder = gui
	end
	slinky.gui = gui

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
	clickgui.ZIndex = 3
	clickgui.Parent = scaledgui
	slinky.menuOpen = false
	local modal = Instance.new('TextButton')
	modal.BackgroundTransparency = 1
	modal.Modal = true
	modal.Text = ''
	modal.Parent = clickgui
	slinky.cursor = Instance.new('ImageLabel')
	slinky.cursor.BackgroundTransparency = 1
	slinky.cursor.Image = 'rbxasset://textures/Cursors/KeyboardMouse/ArrowFarCursor.png'
	slinky.cursor.Size = UDim2.fromOffset(64, 64)
	slinky.cursor.Visible = false
	slinky.cursor.ZIndex = 50
	slinky.cursor.Parent = gui
	notifications = Instance.new('Folder')
	notifications.Name = 'Notifications'
	notifications.Parent = scaledgui
	ui.rowTip = ui.newTip('Tooltip')
	tooltip = ui.rowTip.Label
	ui.tooltipZoom = ui.rowTip.Zoom
	slinky:clean(clickgui:GetPropertyChangedSignal('Visible'):Connect(function()
		if ui.menuQueued then return end
		ui.menuQueued = true
		task.defer(function()
			ui.menuQueued = false
			if slinky.loaded == nil then return end
			if slinky.threadFix then
				setthreadidentity(8)
			end
			table.clear(ui.tooltipHovered)
			pcall(ui.hideTips)
			pcall(ui.refreshTooltip)
			pcall(ui.restHovered)
			if not clickgui.Visible then
				for _, hook in ui.shutHooks do
					pcall(hook)
				end
			end
			for _, hook in ui.menuHooks do
				pcall(hook)
			end
			if layout and layout.MenuShown then
				layout.MenuShown(clickgui.Visible)
			end
		end)
	end))
	slinky:clean(inputService.InputChanged:Connect(function(input)
		local wheel = input.UserInputType == Enum.UserInputType.MouseWheel
		if (input.UserInputType == Enum.UserInputType.MouseMovement or wheel)
			and (ui.tooltipShown or next(ui.tooltipHovered)) then
			ui.refreshTooltip()
		end
		if wheel and clickgui.Visible then
			ui.placeTips()
		end
	end))
	local tooltipCheck = 0
	slinky:clean(runService.Heartbeat:Connect(function()
		if ui.tooltipShown and os.clock() >= tooltipCheck then
			tooltipCheck = os.clock() + 0.2
			ui.refreshTooltip()
		end
	end))
	do
		slinky:clean(inputService.InputBegan:Connect(function(input)
			local kind = input.UserInputType
			if kind == Enum.UserInputType.MouseButton1 or kind == Enum.UserInputType.Touch then
				ui.escapePress = os.clock()
			elseif input.KeyCode == Enum.KeyCode.Escape and not slinky.binding then
				ui.escapeKeyPrev = ui.escapeKey
				ui.escapeKey = os.clock()
				ui.escapeLater('key', ui.escapeKey)
			end
		end))
		local function watch(find, handler)
			local ok, connection = pcall(function()
				return find():Connect(handler)
			end)
			if ok and connection then
				slinky:clean(connection)
			end
		end
		watch(function()
			return inputService.TextBoxFocusReleased
		end, function(box)
			ui.escapeFocus = os.clock()
			ui.escapeFocusBox = box
		end)
		watch(function()
			return guiService.MenuOpened
		end, function()
			ui.escapeMenuAt = os.clock()
			if not slinky.binding then
				ui.escapeLater('menu')
			end
		end)
		watch(function()
			return guiService.MenuClosed
		end, function()
			ui.escapeMenuShut = os.clock()
		end)
	end
	scale = Instance.new('UIScale')
	scale.Scale = autoScaleValue()
	scale.Parent = scaledgui
	scaledgui.Size = UDim2.fromScale(1 / scale.Scale, 1 / scale.Scale)
	fonts.init()
end

--[[ Creates the menu and its category windows. Minigames always exists: bedwars.lua and other place
files put modules in it, and without it their calls index nil and take the game script down.
slinky.guiscale is the GUI's UIScale, which games/6872274481.lua reads to size two scrolling frames.
]]
function build.categories()
	components.gui({})

	for _, name in {'Combat', 'Blatant', 'Render', 'Utility', 'World', 'Inventory'} do
		slinky:categoryWindow(name)
	end
	slinky:categoryWindow('Minigames')

	slinky.guiscale = scale
	slinky.categories.Main:divider('misc')
end

function build.lists()
	--[[
		Friends
	]]
	do
		local friends
		local friendscolor = {
			hue = 1,
			sat = 1,
			value = 1
		}
	
		friends = slinky:categoryList('Friends', {
			size = UDim2.fromOffset(17, 16),
			placeholder = 'Roblox username',
			color = Color3.fromRGB(243, 93, 18),
			changed = function()
				friends.update:Fire()
				friends.colorUpdate:Fire(friendscolor.hue, friendscolor.sat, friendscolor.value)
			end
		})
		friends.update = Instance.new('BindableEvent')
		friends.colorUpdate = Instance.new('BindableEvent')
		friends:toggle('Recolor visuals', {
			sub = true,
			default = true,
			changed = function()
				friends.update:Fire()
				friends.colorUpdate:Fire(friendscolor.hue, friendscolor.sat, friendscolor.value)
			end
		})
		friendscolor = friends:color('Friends color', {
			sub = true,
			changed = function(hue, sat, val)
				for _, v in friends.row.Children:GetChildren() do
					local dot = v:FindFirstChild('Dot')
					if dot and dot.BackgroundColor3 ~= theme.Muted then
						dot.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
						dot.Dot.BackgroundColor3 = dot.BackgroundColor3
					end
				end
	
				friends.colorUpdate:Fire(hue, sat, val)
			end
		})
		friends:toggle('Use friends', {
			sub = true,
			default = true,
			changed = function()
				friends.update:Fire()
				friends.colorUpdate:Fire(friendscolor.hue, friendscolor.sat, friendscolor.value)
			end
		})
		slinky:clean(friends.update)
		slinky:clean(friends.colorUpdate)
	end
	
	--[[
		Profiles
	]]
	local profilescategory = slinky:categoryList('Profiles', {
		size = UDim2.fromOffset(17, 10),
		position = UDim2.fromOffset(12, 16),
		placeholder = 'Type name',
		profiles = true
	})


	--[[ Reloads through the loader, as the Settings > General buttons do, so the key gate runs again. A
	developer build runs pistonware/loaderdev.lua from disk and is never fetched from GitHub.
	Returns false after a notification when the loader does not download. ]]
	local function reinjectThroughLoader()
		if shared.PistonwareDeveloper and isfile('pistonware/loaderdev.lua') then
			loadstring(readfile('pistonware/loaderdev.lua'), 'loader')()
		else
			local ok, source = pcall(pistonwareHttpGet, 'https://raw.githubusercontent.com/themagicpiston/pistonware/main/loader.lua', true)
			local chunk = ok and type(source) == 'string' and loadstring(source, 'loader')
			if not chunk then
				slinky:notify('Pistonware', 'Could not download the loader to reload. Run the loader again to load the config.', 15, 'alert')
				return false
			end
			chunk()
		end
	end

	--[[
		settings.json is the menu's state file, not a config: besides the theme and the windows it
		holds the profile in use and the profile LIST shown in the Profiles tab, custom ones
		included. Writing the repo's copy over it would wipe every custom profile from that list and
		force the profile in use back to whatever shipped. Both are carried across, so the theme
		still syncs, the user's own profiles stay local, and only shipped configs get replaced.
	]]
	local function keepOwnProfiles(path, content)
		local ok, merged = pcall(function()
			local new = httpService:JSONDecode(content)
			if type(new) ~= 'table' then return content end

			local old = isfile(path) and loadJson(path)
			if old then
				if old.profile ~= nil then new.profile = old.profile end
				if old.profiles ~= nil then new.profiles = old.profiles end
			end

			return store.settingsText(new)
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

	--[[ Fetches a URL and returns the body, or nil and the reason. Never throws. Any failed request
	falls back to HttpGet, whose '404: Not Found' body counts as a failure. A failure with no status
	code (or 0) never reached GitHub and gives no reason of its own. ]]
	function profileSync.get(url)
		local reason
		local ok, res = pcall(pistonwareRequest, {Url = url, Method = 'GET', Headers = profileSync.Headers})
		if ok and type(res) == 'table' and type(res.Body) == 'string' then
			local status = tonumber(res.StatusCode) or (res.Success == false and 0 or 200)
			if status >= 200 and status < 300 and res.Body ~= '' then
				return res.Body
			end
			if status ~= 0 then
				reason = profileSync.describe(status, res.Body)
			end
		end
		local got, body = pcall(pistonwareHttpGet, url, true)
		if got and type(body) == 'string' and body ~= '' and body ~= '404: Not Found' then
			return body, reason
		end
		return nil, reason or 'could not reach GitHub'
	end

	--[[ Fetches a URL and decodes its JSON, or returns nil and the reason. A GitHub error object can
	come through HttpGet, which hides the status code, so a decoded message field is a failure. ]]
	function profileSync.json(url)
		local body, reason = profileSync.get(url)
		if not body then return nil, reason end
		local ok, decoded = pcall(function()
			return httpService:JSONDecode(body)
		end)
		if not (ok and type(decoded) == 'table') then
			return nil, reason or 'GitHub sent an unreadable response'
		end
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

	-- Being current is not enough on its own: the sync exists to put both shipped configs on disk,
	-- so a missing one has to let it through regardless.
	function profileSync.hasBothConfigs()
		return isfile(store.path('blatant')) and isfile(store.path('legit'))
	end

	--[[ Returns the newest commit that touched profiles/, so every synced file comes from one snapshot.
	When the API is out (rate limit, a blocked host), the main branch head is read from git's ref
	advertisement, which costs no API request. ]]
	function profileSync.latestCommit()
		local body, reason = profileSync.json('https://api.github.com/repos/themagicpiston/pistonware/commits?path=profiles&sha=main&per_page=1')
		if body and type(body[1]) == 'table' and type(body[1].sha) == 'string' then
			return body[1].sha
		end
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

	--[[ Lists every file in profiles/ at a commit, with the blob sha the stamp is made from. When the
	API gives nothing, the repository tree the loader read at boot names the files; their shas
	belong to that commit, so they are left out and make no stamp. ]]
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

	--[[ What a download must never be written as, the loader's rule (unusableBody in loader.lua): an
	error page some executors hand back as the body ('429: Too Many Requests', a 5xx page) and, for a
	config, anything that is not JSON. ]]
	function profileSync.unusableBody(path, body)
		if type(body) ~= 'string' or body == '' or body == '404: Not Found' then return true end
		local head = body:sub(1, 200):lower()
		if body:match('^%d%d%d: ') or head:find('<!doctype html', 1, true) or head:find('<html', 1, true) then
			return true
		end
		if path:match('%.json$') or path:match('profiles/.+%.txt$') then
			local ok, decoded = pcall(function()
				return httpService:JSONDecode(body)
			end)
			return not (ok and type(decoded) == 'table')
		end
		return false
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
			if suc and not profileSync.unusableBody(path, res) then
				content = res
				break
			end
			if attempt < 4 then
				task.wait(attempt)
			end
		end
		if not content then return false end

		if path == store.settingsPath then
			content = keepOwnProfiles(path, content)
		end

		return (pcall(writefile, path, content))
	end

	--[[ Downloads the files in parallel, as the loader does, joined on a deadline so one stuck request
	cannot hold the button. Returns the counts that landed and did not, and the paths that landed.
	Each file is noted with store.noteSynced as it lands, so a reload in the middle or a file
	landing after the deadline still counts. ]]
	function profileSync.download(files, commit)
		local synced, failed, landed = 0, 0, {}
		local total = #files
		for _, v in files do
			task.spawn(function()
				local path = 'pistonware/'..({v.path:gsub(' ', '%%20')})[1]
				local ok, got = pcall(profileSync.downloadFile, path, commit)
				if ok and got then
					synced += 1
					table.insert(landed, path)
					store.noteSynced(landed, files)
				else
					failed += 1
				end
			end)
		end
		local deadline = os.clock() + 90
		while synced + failed < total and os.clock() < deadline do
			task.wait(0.05)
		end
		return synced, total - synced, landed
	end

	--[[ Syncs the shipped profiles and returns how many files landed, or nil and why. 0 means nothing
	was new, which only the Load buttons check; the Sync button forces a fresh copy.
	profiles/gui.txt and profiles/whitelist.json are not downloaded, as nothing reads them, but they
	stay in the stamp, which has to be the one the loader makes. The stamp is written only when
	every file landed, so a partial sync is retried. ]]
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
		local wanted = {}
		for _, v in files do
			if v.path ~= 'profiles/gui.txt' and v.path ~= 'profiles/whitelist.json' then
				table.insert(wanted, v)
			end
		end
		local synced, failed, landed = profileSync.download(wanted, commit)
		store.noteSynced(landed, wanted)
		if synced <= 0 then
			return nil, 'Profile sync failed (nothing downloaded).'
		end
		if stamp and failed == 0 then
			pcall(writefile, 'pistonware/profiles/profilecommit.txt', stamp)
		end
		return synced, 'Synced '..synced..' file'..(synced == 1 and '' or 's')..' from GitHub'..(failed > 0 and ' ('..failed..' failed).' or '.')
	end

	--[[ The sync row of the Profiles tab: Sync profiles from GitHub, Load Blatant and Load Legit. Once a
	sync lands, the Load buttons own the reinject until a config is picked, so syncing and choosing
	take one reload. The pills have 12 px padding a side: at 16 the three ran past a 442 px phone
	window.

	A sync saves first and blocks saving during the download, so a queued save cannot write the
	earlier config over the files just downloaded; once anything landed, saving stays off until the
	reload. A Load button syncs first unless the Sync button just did, writes the chosen profile
	into settings.json directly as saving is off, and always reloads, because an in-place switch
	skips settings.json. When the reload fails, the reload flag is cleared: left standing it would
	make the next manual run headless, with no way to ask for a key.

	slinky:load is wrapped so the button highlight follows the active profile, and passes every
	return value on, as main.lua reads the second. ]]
	do
		local busy = false
		local pending, syncmessage = false, nil
		local refreshConfigButtons
		local extras = profilescategory.extras
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
			ui.padding(button, 12, 12, 0, 0)
			local stroke = ui.stroke(button, theme.Outline, 1, 0.1)
			if tip then addRowTooltip(button, tip, button, nil, row) end
			ui.hover(button, function()
				button.BackgroundColor3 = theme.Raised
			end, function()
				button.BackgroundColor3 = theme.Card
			end)
			return button, stroke
		end

		local syncbutton = pillButton('Sync profiles from GitHub', 1, 'Redownloads the shipped profiles, then pick a config to load one')
		syncbutton.Name = 'SyncProfiles'

		local function runSync(force)
			pcall(function() slinky:save() end)
			local wasBlocked = slinky.saveBlocked
			slinky:blockSaving()
			local ok, synced, message = pcall(profileSync.run, force)
			if not ok then
				synced, message = nil, 'Profile sync failed ('..tostring(synced)..').'
			end
			if synced and synced > 0 then
				slinky.save = function() end
				slinky.saveNeeded = nil
			else
				slinky.saveBlocked = wasBlocked
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
				slinky:notify('Pistonware', message, 10, 'alert')
				return
			end

			pending, syncmessage = true, message
			syncbutton.Text = 'Synced, choose a config'
			refreshConfigButtons()
			slinky:notify('Pistonware', message..' Choose Blatant or Legit to load one.', 10)
		end)

		local configbuttons = {}
		local function recolorProfileCards()
			local accent = theme.Accent()
			for name, entry in configbuttons do
				local selected = slinky.profile == name and not pending
				entry.Button.TextColor3 = selected and accent or theme.Label
				entry.Stroke.Color = selected and accent or theme.Outline
			end
		end
		slinky.recolorProfileCards = recolorProfileCards

		function refreshConfigButtons()
			for name, entry in configbuttons do
				entry.Button.Visible = pending or isfile(store.path(name))
			end
			recolorProfileCards()
		end

		local function selectConfig(name)
			if busy then return end
			busy = true
			if not pending then
				syncbutton.Text = 'Checking for new profiles...'
				local synced, message = runSync(false)
				if synced and synced > 0 then
					pending, syncmessage = true, message
				elseif not synced then
					slinky:notify('Pistonware', message..' Loading the copy already on disk.', 10, 'alert')
				end
			end
			if not isfile(store.path(name)) and not store.pendingSync(name) then
				busy = false
				syncbutton.Text = pending and 'Synced, choose a config' or 'Sync profiles from GitHub'
				refreshConfigButtons()
				slinky:notify('Pistonware', 'There is no '..name..' config for this game yet, press Sync profiles first.', 10, 'alert')
				return
			end
			pending = false
			syncbutton.Text = 'Reloading...'
			pcall(function() slinky:save() end)
			slinky.save = function() end
			slinky.saveNeeded = nil
			pcall(function()
				local settings = isfile(store.settingsPath) and loadJson(store.settingsPath)
				if not settings then return end
				local rows = type(settings.profiles) == 'table' and settings.profiles or {}
				settings.profiles = rows
				local listed = false
				for _, row in rows do
					if type(row) == 'table' and row.name == name then
						listed = true
						break
					end
				end
				if not listed then
					table.insert(rows, {name = name})
				end
				settings.profile = name
				writefile(store.settingsPath, store.settingsText(settings))
			end)
			shared.PistonwareSyncResult = syncmessage
			shared.SlinkyCustomProfile = name
			shared.slinkyreload = true
			if reinjectThroughLoader() == false then
				shared.slinkyreload = nil
				shared.SlinkyCustomProfile = nil
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

		local loadprofile = slinky.load
		function slinky:load(...)
			local results = table.pack(loadprofile(self, ...))
			refreshConfigButtons()
			return table.unpack(results, 1, results.n)
		end
		refreshConfigButtons()
	end

	--[[
		Profile import / export.

		A profile is one JSON file on disk (pistonware/profiles/<name>.json), so sharing one is
		only a matter of moving that file's text around. It travels inside an envelope rather
		than raw: the envelope carries the name it was exported under, which is what lets Import
		name the new file. A raw config is still accepted -- pasting the file contents straight
		in is the obvious thing to try -- it just arrives without a name. An export made by an
		older build, which held one place's file in the old format, is converted as it comes in.

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

	--[[ Encodes a string as base64. A last group one or two bytes short ends in '=' padding in place of
	the characters that would be noise. ]]
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
		local remainder = #data % 3
		if remainder == 1 then
			return text:sub(1, -3)..'=='
		elseif remainder == 2 then
			return text:sub(1, -2)..'='
		end
		return text
	end

	--[[ Decodes base64. Padding and any whitespace a chat client wrapped the blob in are dropped, not
	rejected: the number of characters in the last group already tells how many bytes it carries. ]]
	local function base64Decode(text)
		if not b64Lookup then
			b64Lookup = {}
			for index = 1, 64 do
				b64Lookup[B64_CHARS:sub(index, index)] = index - 1
			end
		end

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

	--[[ Compresses a string with LZW. Codes widen from 9 bits as the dictionary fills, which is most of
	the saving over a fixed 16-bit code: the first 256 entries of a JSON blob are almost all single
	characters. The width is capped at 16 bits and the dictionary stops growing there instead of
	resetting, which keeps both ends in agreement about the width. Trailing bits are padded to a
	whole byte; the unpacker stops on the dictionary, not on the byte count. ]]
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

		if accumulated > 0 then
			bytes[#bytes + 1] = string.char((accumulator * (2 ^ (8 - accumulated))) % 256)
		end

		return table.concat(bytes)
	end

	--[[ Reverses lzwPack. The width steps up one code earlier than the packer's does: the packer widens
	after adding an entry, so its first code at the new width refers to an entry this side has not
	added yet. A code equal to the next free one is LZW's self-referential case, the previous entry
	plus its own first character. ]]
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

	--[[ Packs an export as PACK_PREFIX and the base64 of lzwPack. The plain JSON is returned when
	packing fails or comes out no shorter, which it does on anything small: base64 adds a third, and
	a small set gives the dictionary nothing to find. ]]
	local function packExport(text)
		local ok, packed = pcall(function()
			return PACK_PREFIX..base64Encode(lzwPack(text))
		end)

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
		if box and type(box.value) == 'string' then
			local typed = box.value:gsub('^%s+', ''):gsub('%s+$', '')
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
	rows fighting over one file (see addProfile), and a numbered copy is not the profile
	anyone asked to import. Nothing is written before the payload has been validated, and the
	box is emptied only once it has. ]]


	--[[ Copies a profile as an export blob to the clipboard and writes it to
	EXPORT_FOLDER/profile-<name>.txt. The profile in use is saved first, as everything toggled since
	the last autosave is only in memory. Version 2 holds a profile as its file holds it, and Place
	says which game's on/off the file holds; version 1 held one place's old-format file. ]]
	local function exportProfile(name)
		name = name or slinky.profile
		if name == slinky.profile then
			pcall(function() slinky:save() end)
		end

		local path = store.path(name)
		local data = isfile(path) and loadJson(path)
		if type(data) ~= 'table' then
			slinky:notify('Pistonware', 'Nothing to export -- the '..name..' profile has no file yet.', 10, 'alert')
			return
		end

		local suc, blob = pcall(httpService.JSONEncode, httpService, {
			Pistonware = 'profile',
			Version = 2,
			Name = name,
			Place = slinky.place,
			Data = data
		})
		if not suc then
			slinky:notify('Pistonware', 'Export failed, '..tostring(blob), 10, 'alert')
			return
		end

		blob = packExport(blob)
		local filename = 'profile-'..name
		local wrote = writeExport(filename, blob)
		if setClipboard(blob) then
			slinky:notify('Pistonware', 'Copied the <font color="'..ui.hex(theme.Accent())..'">'..name..'</font> profile to your clipboard'..(wrote and ' and to '..EXPORT_FOLDER..'/'..filename..'.txt.' or '.'), 10)
		elseif wrote then
			slinky:notify('Pistonware', 'Your executor has no clipboard access, so the profile was written to '..EXPORT_FOLDER..'/'..filename..'.txt instead.', 10)
		else
			slinky:notify('Pistonware', 'Export failed -- could not reach the clipboard or write to '..EXPORT_FOLDER..'.', 10, 'alert')
		end
	end

	-- Assigned below; importProfile is its own Function, so the two cannot be declared together.
	local profileimportbox

	--[[ Reads an exported profile or a bare profile file from the Import profile box, the clipboard, or
	importprofile.txt (then import.txt) in EXPORT_FOLDER, and returns the payload and its exported
	name, or nil after saying why. A third result marks a part of a profile: 'place' for one place's
	old-format file, 'options' for the options alone of an export made in another game, whose on/off
	would switch modules on here.

	An FFlags export is filed through profilescategory.importFlags when takeFlags is set; a profile
	card cannot take one. An old-format payload (it has Modules) is converted the way the files on
	disk are. JSON that is not entries carrying __on or __lobby, such as a list of FFlags, is turned
	away. An export without a Place is taken as this place's. ]]
	local function readProfileImport(takeFlags)
		local blob = readImport(profileimportbox, EXPORT_FOLDER..'/importprofile.txt')
		if not blob then
			slinky:notify('Pistonware', 'Nothing to import -- paste a profile into the Import profile box, or copy one to your clipboard.', 10, 'alert')
			return nil
		end

		local decoded = decodeImport(blob)
		if not decoded then
			slinky:notify('Pistonware', 'That does not look like a profile (it is not readable JSON).', 10, 'alert')
			return nil
		end

		if decoded.Pistonware == 'fflags' then
			if takeFlags and profilescategory.importFlags then
				profilescategory.importFlags(decoded)
			else
				slinky:notify('Pistonware', 'That is an FFlags export, not a profile. Paste it into the Import profile box below, or into Add FFlags in the FFlags tab.', 10, 'alert')
			end
			return nil
		end

		local payload, name, place = decoded, nil, slinky.place
		if decoded.Pistonware == 'profile' and type(decoded.Data) == 'table' then
			payload, name = decoded.Data, decoded.Name
			place = tonumber(decoded.Place) or place
		end

		if type(payload.Modules) == 'table' then
			local ok, entries = pcall(store.convertProfile, {{tostring(place), payload}}, isMobile())
			if not ok then
				slinky:notify('Pistonware', 'That profile could not be converted to the new format.', 10, 'alert')
				return nil
			end
			if not store.sameFile(place, slinky.place) then
				slinky:notify('Pistonware', 'Heads up: that profile was exported for a different game, most of its modules will not exist here.', 10, 'alert')
				return store.optionsOf(entries), name, 'options'
			end
			return entries, name, 'place'
		end

		local entries = false
		for _, entry in payload do
			if type(entry) ~= 'table' then
				entries = false
				break
			end
			entries = entries or entry.__on ~= nil or entry.__lobby ~= nil
		end
		if not entries then
			slinky:notify('Pistonware', 'That JSON is not a pistonware profile. A list of FFlags goes into Add FFlags in the FFlags tab.', 10, 'alert')
			return nil
		end
		if not store.sameFile(place, slinky.place) then
			slinky:notify('Pistonware', 'Heads up: that profile was exported for a different game, most of its modules will not exist here.', 10, 'alert')
			return store.optionsOf(payload), name, 'options'
		end
		return payload, name
	end

	--[[ What an import writes into a profile's file. A whole profile replaces it. Part of a profile
	(one place, or the options of another game's) goes into the file that is there and leaves the rest
	as it is; what the profile in use has in memory is flushed first, so the file it goes into is current. ]]
	local function importedInto(name, payload, part)
		local path = store.path(name)
		if part then
			if name == slinky.profile then
				pcall(function() slinky:save() end)
			end
			local held = isfile(path) and loadJson(path)
			if type(held) == 'table' then
				payload = store.mergeImport(held, payload, part == 'options')
			end
		end
		return store.write(path, store.profileText, payload)
	end

	--[[ Imports the pasted profile under the name it was exported with, or 'imported' for a bare one or
	a name that is not usable (settings is the menu's own file). A name already listed gets no new
	row, since change on a listed name is the delete half of the list's toggle. An import into the
	profile in use is loaded at once; otherwise the next save would write the earlier settings back
	over it. ]]
	local function importProfile()
		local payload, name, part = readProfileImport(true)
		if not payload then return end

		name = sanitizeName(name) or 'imported'
		if not usableProfileName(name) then
			name = 'imported'
		end
		local existed = profilescategory:find(name) ~= nil

		local ok, err = importedInto(name, payload, part)
		if not ok then
			slinky:notify('Pistonware', 'Import failed, '..tostring(err), 10, 'alert')
			return
		end

		if not existed then
			profilescategory:change(name)
		end

		if profileimportbox then
			profileimportbox:set('')
		end

		if name == slinky.profile then
			slinky:load(true, name)
			slinky:notify('Pistonware', 'Imported into <font color="'..ui.hex(theme.Accent())..'">'..name..'</font>.', 10)
			return
		end

		slinky:notify('Pistonware', (existed and 'Replaced <font color="'..ui.hex(theme.Accent())..'">' or 'Imported as <font color="'..ui.hex(theme.Accent())..'">')..name..'</font>, click it in the Profiles tab to load it.', 10)
	end

	--[[ The import icon on a profile card: the pasted profile goes INTO that profile, replacing
	it, after a confirmation. Into the profile in use, it is applied straight away -- otherwise
	the next autosave would write the old settings back over it. ]]
	local function importInto(target)
		local payload, _, part = readProfileImport()
		if not payload then return end
		ui.confirm("Replace the '"..target.."' profile with the one you copied?", function()
			local ok, err = importedInto(target, payload, part)
			if not ok then
				slinky:notify('Pistonware', 'Import failed, '..tostring(err), 10, 'alert')
				return
			end
			if profileimportbox then
				profileimportbox:set('')
			end
			if target == slinky.profile then
				slinky:load(true)
			end
			slinky:notify('Pistonware', 'Imported into <font color="'..ui.hex(theme.Accent())..'">'..target..'</font>.', 10)
		end, 'Replace')
	end

	--[[ No executor can open a folder in Explorer, so this copies the path to the file. ]]
	local function copyFolder(name)
		local path = store.path(name)
		if setClipboard(path) then
			slinky:notify('Pistonware', 'Copied <font color="'..ui.hex(theme.Accent())..'">'..path..'</font> -- it is inside your executor\'s workspace folder.', 8)
		else
			slinky:notify('Pistonware', 'The profile is at '..path..' inside your executor\'s workspace folder.', 8)
		end
	end

	profilescategory.cardActions = {
		export = exportProfile,
		import = importInto,
		folder = copyFolder
	}

	profilescategory.inline:divider('Share profiles')

	profilescategory.inline:button('Export profile', {
		sub = true,
		order = 1003,
		clicked = exportProfile,
		about = 'Copies the profile you are on to your clipboard and to '..EXPORT_FOLDER
	})

	--[[ The Import profile box in the Profiles tab. It is transient: pasted, imported and emptied, never
	saved or restored. ]]
	profileimportbox = profilescategory.inline:textbox('Import profile', {
		sub = true,
		order = 1001,
		placeholder = 'Paste an exported profile',
		transient = true,
		changed = function(enter)
			if enter then
				importProfile()
			end
		end,
		about = 'Paste a profile here and press Enter, or use the button below'
	})

	profilescategory.inline:button('Import pasted profile', {
		sub = true,
		order = 1002,
		clicked = importProfile,
		about = 'Imports what is in the box above, falling back to your clipboard or '..EXPORT_FOLDER..'/import.txt'
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

	--[[ Which set is current. Mirrors slinky.Profile for the Profiles tab, and is persisted through
	the list's own Save, into the settings file. Declared before the list because the list's
	callbacks read and write it. ]]
	local selectedFFlag = 'default'
	local applyFFlags

	--[[ The FFlags tab's list of flag profiles, each a file in FFLAG_FOLDER. Selecting a row applies it,
	as a profile click loads its config, but restoring the saved selection at inject writes no
	flags. Removing a row deletes its file and falls back to default, stopping an apply still
	writing it. Every row gets a file, made when the list changes or the pane opens, and the default
	row is created only when the pane opens, as the list is not boot-critical. The file calls are
	under pcall: an executor without them would take the load down. ]]
	fflags = slinky:categoryList('FFlags', {
		tab = 'FFlags',
		size = UDim2.fromOffset(15, 14),
		placeholder = 'Type name',
		swap = true,
		current = function()
			return selectedFFlag
		end,
		select = function(name)
			selectedFFlag = name
			applyFFlags()
		end,
		delete = function(name)
			pcall(function()
				if isfile(fflagPath(name)) and delfile then
					delfile(fflagPath(name))
				end
			end)
			if selectedFFlag == name then
				selectedFFlag = 'default'
				if applyFFlags then
					applyFFlags(true, nil, {})
				end
			end
		end,
		restore = function(name)
			selectedFFlag = name
		end,
		onExpand = function()
			if fflags and fflags.showQuarantine then
				pcall(fflags.showQuarantine)
			end
			if fflags and not fflags:find('default') then
				fflags:change('default')
				return
			end
			pcall(function()
				ensureFolder(FFLAG_FOLDER)
				for _, entry in fflags.items do
					if type(entry) == 'table' and type(entry.name) == 'string' and not isfile(fflagPath(entry.name)) then
						writeJson(fflagPath(entry.name), {})
					end
				end
			end)
		end,
		changed = function(_, skipGUI)
			if skipGUI then return end
			pcall(function()
				ensureFolder(FFLAG_FOLDER)
				for _, entry in fflags.items do
					if type(entry) == 'table' and type(entry.name) == 'string' and not isfile(fflagPath(entry.name)) then
						writeJson(fflagPath(entry.name), {})
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

	--[[ The tail the Apply button and the adder both put on their message, so the two agree about what
	happened. Without getfflag nothing can tell a flag that took from one that did not. A flag that
	does not read back changed is read only while the client starts, and belongs in the executor's
	own FastFlag settings. ]]
	local function applySuffix(total, failed, verified, verifiable)
		local text = failed > 0 and ' ('..failed..' rejected)' or ''

		if not verifiable then
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
	local FFLAG_PREFIXES = {'DFFlag', 'DFInt', 'DFString', 'DFLog', 'FFlag', 'FInt', 'FString', 'FLog'}
	--[[ Strips a prefix in FFLAG_PREFIXES off a flag name. Prefixes are compared, not matched, so a set
	of thousands builds no table and no pattern per flag. ]]
	local function bareFlagName(flag)
		for _, prefix in FFLAG_PREFIXES do
			if #flag > #prefix and flag:sub(1, #prefix) == prefix then
				return flag:sub(#prefix + 1)
			end
		end
		return flag
	end

	--[[ Stringified: the executors that take a value at all take it as a string, and the
	sets people share are a mix of "true", true and numbers.

	Booleans go in lower case, whatever spelling the list used.

	These lists are written for bootstrappers, which hand Roblox a JSON file and let its
	settings loader coerce "True" into a boolean. setfflag is a different route into the
	same flags, and the engine parses the string strictly there: "True" is not "true", so
	the flag keeps its default and nothing is reported -- the call still returns cleanly,
	which is exactly the silent no-op this tab was showing as success.

	Worth doing across the board: 122 of the 234 values in the list you pasted are
	capitalised, so this is most of the file rather than an edge case.

	Only booleans are touched. FInt/DFInt values are numbers, and FString values are
	content -- asset ids, URLs, embedded JSON -- where case is meaningful. ]]
	local function flagValue(value)
		local wanted = tostring(value)
		local lowered = wanted:lower()
		if lowered == 'true' or lowered == 'false' then
			wanted = lowered
		end
		return wanted
	end

	--[[ Whether what the engine reads back is the value wanted (flagValue's). Booleans ignore case:
	the engine may report "True" for "true". Nothing else does: an FString's case is its content, so
	'ABC' wanted over 'abc' held is a flag to write, not one already set. ]]
	local function sameFlagValue(have, wanted)
		local text = tostring(have)
		if wanted == 'true' or wanted == 'false' then
			return text:lower() == wanted
		end
		return text == wanted
	end

	--[[ State of the flag apply and its crash guard. The guard file applying.<UserId>.txt names the next
	few flags Settle seconds before they are read, and a written flag for Linger seconds, as
	getfflag and setfflag can close the client a few frames on. A file still naming flags at the
	first apply after an inject means Roblox closed mid-apply: those go to quarantine.json and are
	skipped until Clear FFlag quarantine. From a teleport's start no guard is kept, and an Uninject
	empties it. ]]
	local fflagRun = {
		Quarantine = FFLAG_FOLDER..'/quarantine.json',
		Budget = 0.004,
		Batch = 8,
		Settle = 0.1,
		Linger = 0.3,
		Named = false,
		Reader = false,
		Generation = 0,
		Checked = false,
		Leaving = false,
		Previous = {}
	}

	local function clearGuard()
		fflagRun.Previous = {}
		if fflagRun.Named then
			fflagRun.Named = false
			pcall(writefile, fflagRun.Applying, '')
		end
	end

	--[[ An apply that starts no thread still supersedes one going, and that one stops without
	touching the guard, which is no longer its own. So this lets go of it, Linger seconds on as a
	finished apply does, unless a newer apply has taken it over by then. ]]
	local function releaseGuard(generation)
		if not fflagRun.Named then return end
		task.spawn(function()
			task.wait(fflagRun.Linger)
			if fflagRun.Generation == generation then
				clearGuard()
			end
		end)
	end

	-- quarantine.json is a list of bare names; a hand-edited map of name = true reads too.
	local function readQuarantine()
		local quarantine = {}
		local data = loadJson(fflagRun.Quarantine)
		if type(data) == 'table' then
			for key, value in data do
				if type(value) == 'string' then
					quarantine[value] = true
				elseif type(key) == 'string' and value then
					quarantine[key] = true
				end
			end
		end
		return quarantine
	end

	-- What the last session left in applying.txt, moved into the quarantine: the names it added.
	local function takeLeftover(quarantine)
		local ok, text = pcall(readfile, fflagRun.Applying)
		if not (ok and type(text) == 'string') or not text:find('%S') then
			return {}
		end
		local caught = {}
		for line in text:gmatch('[^\r\n]+') do
			local name = line:match('^%s*(%S+)')
			if name and not quarantine[name] then
				quarantine[name] = true
				table.insert(caught, name)
			end
		end
		if #caught > 0 then
			local list = {}
			for name in quarantine do
				table.insert(list, name)
			end
			table.sort(list)
			writeJson(fflagRun.Quarantine, list)
			if fflags.showQuarantine then
				fflags.showQuarantine(true)
			end
		end
		pcall(writefile, fflagRun.Applying, '')
		return caught
	end

	-- A few names, then how many more: a notification has no room for thirty.
	local function someNames(names, most)
		local shown = table.move(names, 1, math.min(#names, most), 1, {})
		return table.concat(shown, ', ')..(#names > most and ' and '..(#names - most)..' more' or '')
	end

	-- What an apply left out and why, after its applied count.
	local function skipSuffix(result)
		local parts = {}
		if #result.Strings > 0 then
			table.insert(parts, #result.Strings..' FString flag'..(#result.Strings == 1 and '' or 's')..' ('..someNames(result.Strings, 3)..'), as reading or setting one in a running game closes Roblox')
		end
		if result.Unknown > 0 then
			table.insert(parts, result.Unread
				and result.Unknown.." that your executor's getfflag could not read (it read none of them, so none could be checked against this client)"
				or result.Unknown..' this client does not have')
		end
		if result.Quarantined > 0 then
			table.insert(parts, result.Quarantined..' quarantined after Roblox closed while applying them (Clear FFlag quarantine lets them in again)')
		end
		return #parts > 0 and ' Skipped '..table.concat(parts, '; ')..'.' or ''
	end

	--[[ The tail of both reports: applySuffix over the flags that were tried, then the skips. ]]
	local function resultSuffix(result)
		local attempted = result.Total - result.Skipped
		return (attempted > 0 and applySuffix(attempted, result.Failed, result.Verified, result.Verifiable) or '.')..skipSuffix(result)
	end

	--[[ Runs one apply a frame at a time in its own thread (applyFFlags spawns it); finish gets the
	counts, and an apply superseded or stopped by an Uninject never reaches it. It starts in the
	next frame, after the frame that asked for it and any a superseded apply wrote in. The walk
	keeps to the frame budget, as a shared set can run to thousands.

	A plain FString is never touched: getfflag on one closes the client (every time on Potassium). A
	DFString is not one of these. Flags are read before they are written; one getfflag does not
	know, or one already holding the value, is not written. false from the setter is a refusal
	(Real, Wave); anything else is a write. When getfflag read none of the set and no flag since
	inject, the report says it could not read them, as it may not work on this executor. The guard
	is cleared Linger seconds after the last write. ]]
	local function runFFlagApply(generation, flags, setter, getter, result, finish)
		local run = fflagRun
		local function stopped()
			if run.Generation == generation and slinky.loaded ~= nil then
				return false
			end
			if run.Generation == generation then
				clearGuard()
			end
			return true
		end

		task.wait()
		if stopped() then return end
		ensureFolder(FFLAG_FOLDER)
		local quarantine = readQuarantine()
		if not run.Checked then
			run.Checked = true
			local player = cloneref(game:GetService('Players')).LocalPlayer
			run.Applying = FFLAG_FOLDER..'/applying.'..tostring(player and player.UserId or 0)..'.txt'
			local teleport = player and player.OnTeleport
			if teleport then
				slinky:clean(teleport:Connect(function(state)
					run.Leaving = state ~= Enum.TeleportState.Failed
					if run.Leaving then
						task.defer(pcall, writefile, run.Applying, '')
					end
				end))
			end
			local caught = takeLeftover(quarantine)
			if #caught > 0 then
				slinky:notify('Pistonware', 'Roblox closed while '..(#caught == 1 and 'this flag was' or 'these flags were')..' going in last time, so '..(#caught == 1 and 'it is' or 'they are')..' quarantined and skipped from now on: '..someNames(caught, 8)..'. If that was not a crash, Clear FFlag quarantine lets '..(#caught == 1 and 'it' or 'them')..' in again.', 15, 'alert')
			end
		end

		local pending = {}
		for flag, value in flags do
			if type(flag) == 'string' then
				table.insert(pending, {flag, value})
			end
		end
		local queue = {}
		local start = os.clock()
		for index = 1, #pending do
			if os.clock() - start >= run.Budget then
				task.wait()
				if stopped() then return end
				start = os.clock()
			end
			local flag = pending[index][1]
			local name = bareFlagName(flag)
			if quarantine[name] then
				result.Quarantined += 1
			elseif flag:sub(1, #flag - #name) == 'FString' then
				table.insert(result.Strings, name)
			else
				table.insert(queue, {name, flagValue(pending[index][2])})
			end
		end
		table.sort(result.Strings)
		table.sort(queue, function(a, b)
			return a[1] < b[1]
		end)

		local cursor, readable = 1, 0
		while cursor <= #queue do
			if stopped() then return end
			local window = math.min(cursor + run.Batch - 1, #queue)
			local now, names, kept = os.clock(), {}, {}
			for _, written in run.Previous do
				if now - written[2] < run.Linger then
					table.insert(kept, written)
					table.insert(names, written[1])
				end
			end
			run.Previous = kept
			for index = cursor, window do
				table.insert(names, queue[index][1])
			end
			if not run.Leaving then
				run.Named = true
				pcall(writefile, run.Applying, table.concat(names, '\n'))
			end
			repeat
				task.wait()
				if stopped() then return end
			until os.clock() - now >= run.Settle
			start = os.clock()
			local batch = {}
			while cursor <= window and os.clock() - start < run.Budget do
				local entry = queue[cursor]
				cursor += 1
				local write = true
				if getter then
					local ok, have = pcall(getter, entry[1])
					if not ok or have == nil then
						result.Unknown += 1
						write = false
					else
						readable += 1
						run.Reader = getter
						if sameFlagValue(have, entry[2]) then
							result.Verified += 1
							write = false
						end
					end
				end
				if write then
					table.insert(batch, entry)
				end
			end

			if #batch > 0 then
				for _, entry in batch do
					table.insert(run.Previous, {entry[1], os.clock()})
				end
				for _, entry in batch do
					local ok, took = pcall(setter, entry[1], entry[2])
					if ok and took ~= false then
						if getter then
							local read, got = pcall(getter, entry[1])
							if read and got ~= nil and sameFlagValue(got, entry[2]) then
								result.Verified += 1
							end
						end
					else
						result.Failed += 1
					end
				end
			end
			task.wait()
		end

		result.Unread = getter ~= nil and readable <= 0 and result.Unknown > 0 and run.Reader ~= getter

		local lastWrite = run.Previous[#run.Previous]
		while lastWrite and os.clock() - lastWrite[2] < run.Linger do
			task.wait()
			if stopped() then return end
		end
		if stopped() then return end
		clearGuard()
		result.Skipped = result.Unknown + #result.Strings + result.Quarantined
		finish(result)
	end

	--[[ The report of an apply that was not asked to stay quiet. ]]
	local function reportApply(result)
		if result.Total - result.Skipped <= 0 then
			slinky:notify('Pistonware', 'None of the '..result.Total..' flags in <font color="'..ui.hex(theme.Accent())..'">'..result.Set..'</font> were applied.'..skipSuffix(result), 10, 'alert')
			return
		end
		slinky:notify('Pistonware', 'Applied '..(result.Total - result.Skipped - result.Failed)..' of '..result.Total..' flags from <font color="'..ui.hex(theme.Accent())..'">'..result.Set..'</font>'..resultSuffix(result), 10,
			(result.Verifiable and result.Verified <= 0) and 'alert' or nil)
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

		Applied a frame at a time, in a thread of its own, and it returns at once. Writing a set
		of two hundred in one go was a frame-long stall with no trace of which flag took the
		client down; now each frame reads within a few milliseconds and writes at most eight
		flags under the crash guard, leaving out the unknown, FString and quarantined ones. A
		newer apply -- a swap, an add -- supersedes one still going.

		quiet: no report of its own. done(result), when given, gets the counts at the end: Set,
		Total, Failed, Verified, Verifiable, Unknown, Unread, Strings (names), Quarantined and Skipped.
		flags: the set itself, when the caller has it decoded already (the import); otherwise the
		selected set's file is read. An empty one only stops an apply still going (Reset, Delete).
	]]
	function applyFFlags(quiet, done, flags)
		fflagRun.Generation += 1
		local generation = fflagRun.Generation
		local setter = setfflag or set_fflag
		local getter = getfflag or get_fflag
		flags = flags or selectedFlags()
		local result = {
			Set = selectedFFlag, Total = countFlags(flags), Failed = 0, Verified = 0, Verifiable = getter ~= nil,
			Unknown = 0, Unread = false, Strings = {}, Quarantined = 0, Skipped = 0
		}

		if result.Total <= 0 then
			releaseGuard(generation)
			if not quiet then
				slinky:notify('Pistonware', 'Switched to <font color="'..ui.hex(theme.Accent())..'">'..result.Set..'</font>, which has no flags in it yet.', 5)
			end
			if done then done(result) end
			return
		end

		if not setter then
			releaseGuard(generation)
			slinky:notify('Pistonware', 'Your executor cannot set fast flags (no setfflag), so the list here is stored but not applied.', 10, 'alert')
			result.Failed = result.Total
			if done then done(result) end
			return
		end

		task.spawn(runFFlagApply, generation, flags, setter, getter, result, function(final)
			local attempted = final.Total - final.Skipped
			if attempted > 0 and final.Failed >= attempted then
				slinky:notify('Pistonware', 'None of the '..final.Total..' flags in '..final.Set..' could be applied.'..skipSuffix(final), 10, 'alert')
			elseif not quiet then
				reportApply(final)
			end
			if done then done(final) end
		end)
	end

	local function exportFFlags()
		local flags = selectedFlags()
		local count = countFlags(flags)
		if count <= 0 then
			slinky:notify('Pistonware', 'Nothing to export -- '..selectedFFlag..' has no flags in it.', 10, 'alert')
			return
		end

		local suc, blob = pcall(httpService.JSONEncode, httpService, {
			Pistonware = 'fflags',
			Version = 1,
			Name = selectedFFlag,
			Data = flags
		})
		if not suc then
			slinky:notify('Pistonware', 'Export failed, '..tostring(blob), 10, 'alert')
			return
		end

		blob = packExport(blob)
		local filename = 'fflags-'..(sanitizeName(selectedFFlag) or 'export')
		local wrote = writeExport(filename, blob)
		if setClipboard(blob) then
			slinky:notify('Pistonware', 'Copied '..count..' flag'..(count == 1 and '' or 's')..' from <font color="'..ui.hex(theme.Accent())..'">'..selectedFFlag..'</font> to your clipboard'..(wrote and ' and to '..EXPORT_FOLDER..'/'..filename..'.txt.' or '.'), 10)
		elseif wrote then
			slinky:notify('Pistonware', 'Your executor has no clipboard access, so '..count..' flags were written to '..EXPORT_FOLDER..'/'..filename..'.txt instead.', 10)
		else
			slinky:notify('Pistonware', 'Export failed -- could not reach the clipboard or write to '..EXPORT_FOLDER..'.', 10, 'alert')
		end
	end

	--[[ Files an FFlags export pasted into the Profiles tab's Import profile box as an FFlags profile
	under its exported name, replacing one already called that. The current set stays selected; when
	it is the one replaced it is applied again. change on a listed name is the delete half of the
	list's toggle, so a listed name gets no new row. ]]
	profilescategory.importFlags = function(decoded)
		local data = type(decoded.Data) == 'table' and decoded.Data or {}
		local count = countFlags(data)
		if count <= 0 then
			slinky:notify('Pistonware', 'That FFlags export has no flags in it.', 10, 'alert')
			return
		end
		local name = sanitizeName(decoded.Name) or 'imported'
		local existed = fflags:find(name) ~= nil
		ensureFolder(FFLAG_FOLDER)
		local ok, err = writeJson(fflagPath(name), data)
		if not ok then
			slinky:notify('Pistonware', 'Import failed, '..tostring(err), 10, 'alert')
			return
		end
		if not existed then
			fflags:change(name)
		end
		if profileimportbox then
			profileimportbox:set('')
		end
		local label = '<font color="'..ui.hex(theme.Accent())..'">'..name..'</font>'
		if name == selectedFFlag then
			applyFFlags()
			slinky:notify('Pistonware', 'Replaced the FFlags profile '..label..' with the '..count..' flag'..(count == 1 and '' or 's')..' you pasted.', 10)
			return
		end
		slinky:notify('Pistonware', (existed and 'Replaced' or 'Imported')..' the FFlags profile '..label..' ('..count..' flag'..(count == 1 and '' or 's')..'). Click it in the FFlags tab to apply it.', 10)
	end

	local fflagimportbox

	--[[ Adds a pasted FFlag set to the selected FFlags profile and applies it, with one notification for
	the whole thing. A bare flag map is accepted as well as the envelope, as other fast-flag tools
	hand out that shape; the envelope's name is ignored, since the selected row is the destination.
	The flags are merged over the set, a flag in both taking the pasted value, and added and changed
	are counted apart. The apply is handed the merged set instead of reading the file back. ]]
	local function importFFlags()
		local blob = readImport(fflagimportbox, FFLAG_FOLDER..'/import.txt')
		if not blob then
			slinky:notify('Pistonware', 'Nothing to add -- paste an FFlag set into the box above, or copy one to your clipboard.', 10, 'alert')
			return
		end

		local decoded = decodeImport(blob)
		if not decoded then
			slinky:notify('Pistonware', 'That does not look like an FFlag set (it is not readable JSON).', 10, 'alert')
			return
		end

		if decoded.Pistonware == 'profile' then
			slinky:notify('Pistonware', 'That is a profile export, not FFlags. Paste it into Import profile in the Profiles tab.', 10, 'alert')
			return
		end
		local payload = decoded
		if decoded.Pistonware == 'fflags' and type(decoded.Data) == 'table' then
			payload = decoded.Data
		end

		if countFlags(payload) <= 0 then
			slinky:notify('Pistonware', 'That JSON has no flags in it.', 10, 'alert')
			return
		end

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
			slinky:notify('Pistonware', 'Could not save to '..target..', '..tostring(err), 10, 'alert')
			return
		end

		if fflagimportbox then
			fflagimportbox:set('')
		end

		applyFFlags(true, function(result)
			slinky:notify('Pistonware',
				'Added '..added..' flag'..(added == 1 and '' or 's')..
				(changed > 0 and ' and updated '..changed or '')..
				' in <font color="'..ui.hex(theme.Accent())..'">'..target..'</font> -- applied '..(result.Total - result.Skipped - result.Failed)..' of '..result.Total..
				resultSuffix(result), 10,
				(result.Verifiable and result.Verified <= 0) and 'alert' or nil)
		end, flags)
	end

	--[[ The Add FFlags box, in the list directly under the rows, as what a paste does depends on which
	row is selected. It is transient: pasted, added and emptied, never saved or restored. ]]
	fflagimportbox = fflags.inline:textbox('Add FFlags', {
		sub = true,
		order = 1001,
		placeholder = 'Paste flags to add',
		transient = true,
		changed = function(enter)
			if enter then
				importFFlags()
			end
		end,
		about = 'Paste flags here and press Enter to add them to the selected profile'
	})

	fflags.inline:button('Add pasted FFlags', {
		sub = true,
		order = 1002,
		clicked = importFFlags,
		about = 'Adds what is in the box above to the selected profile, falling back to your clipboard or '..FFLAG_FOLDER..'/import.txt'
	})

	fflags.inline:button('Export FFlags', {
		sub = true,
		order = 1003,
		clicked = exportFFlags,
		about = 'Copies the selected flag profile to your clipboard and to '..EXPORT_FOLDER
	})

	--[[ Empties the selected FFlags profile's file; the row stays and stays selected. An apply still
	going is stopped. Flags already in the running client cannot be unset, as a flag already written
	is read back from the engine, so they stay until Roblox restarts, and the message says so. ]]
	fflags.inline:button('Reset current fflag profile', {
		sub = true,
		order = 1004,
		clicked = function()
			local target = selectedFFlag
			local emptied = countFlags(selectedFlags())

			local ok, err = pcall(function()
				ensureFolder(FFLAG_FOLDER)
				return writeJson(fflagPath(target), {})
			end)
			if not ok then
				slinky:notify('Pistonware', 'Could not clear '..target..', '..tostring(err), 10, 'alert')
				return
			end
			applyFFlags(true, nil, {})

			if emptied <= 0 then
				slinky:notify('Pistonware', '<font color="'..ui.hex(theme.Accent())..'">'..target..'</font> was already empty.', 5)
				return
			end

			slinky:notify('Pistonware', 'Cleared '..emptied..' flag'..(emptied == 1 and '' or 's')..' from <font color="'..ui.hex(theme.Accent())..'">'..target..'</font>. Flags already set stay until you restart Roblox.', 10)
		end,
		about = 'Removes every flag from the selected profile, keeping the profile itself'
	})

	--[[ The way back for flags the crash guard quarantined when Roblox closed mid-apply for some
	other reason -- closed by hand, or a crash of its own -- and the only one on a phone, where
	quarantine.json is out of reach. ]]
	fflags.quarantineButton = fflags.inline:button('Clear FFlag quarantine', {
		sub = true,
		order = 1005,
		clicked = function()
			local names = {}
			for name in readQuarantine() do
				table.insert(names, name)
			end
			if #names <= 0 then
				fflags.showQuarantine(false)
				slinky:notify('Pistonware', 'No flags are quarantined.', 5)
				return
			end
			table.sort(names)
			ensureFolder(FFLAG_FOLDER)
			local ok, err = writeJson(fflagRun.Quarantine, {})
			if not ok then
				slinky:notify('Pistonware', 'Could not clear '..fflagRun.Quarantine..', '..tostring(err), 10, 'alert')
				return
			end
			fflags.showQuarantine(false)
			slinky:notify('Pistonware', 'Took '..#names..' flag'..(#names == 1 and '' or 's')..' out of quarantine: '..someNames(names, 8)..'. They go in again the next time a set holding them is applied.', 10)
		end,
		about = 'Lets flags held back after Roblox closed mid-apply go in again'
	})

	--[[ The button shows only while something is quarantined (owner, 2026-10-21). Hidden from the
	start, so nothing is read at boot; quarantine.json is read when the FFlags list opens (OnExpand),
	and the button is shown or hidden again whenever the quarantine changes. ]]
	function fflags.showQuarantine(shown)
		if shown == nil then
			shown = next(readQuarantine()) ~= nil
		end
		local button = fflags.quarantineButton
		if button and button.row then
			button.row.Visible = shown
		end
	end
	fflags.showQuarantine(false)

	
	--[[
		Targets
	]]
	local targets
	targets = slinky:categoryList('Targets', {
		size = UDim2.fromOffset(17, 16),
		placeholder = 'Roblox username',
		changed = function()
			targets.update:Fire()
		end
	})
	targets.update = Instance.new('BindableEvent')
	slinky:clean(targets.update)
end

--[[ Adds Move HUD. Overlay handles and widget outlines take a drag only while the menu is open, and on a
phone the open menu covers most of them, so it hides the window, the key footer and the dim but
leaves the menu open; the Done pill or the menu key brings the window back. A menu shut another way
(Unload, a module's hold gesture) stops it through a shut hook, run by the deferred Visible watcher,
never inside the property change. ]]
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
		if layout.FooterHolder then
			layout.FooterHolder.Visible = true
		end
		if layout.Dim then
			layout.Dim.Visible = clickgui.Visible
		end
		slinky:blurCheck()
	end
	local function start()
		if layout.MovingHud or not (clickgui.Visible and layout.Window) then return end
		layout.MovingHud = true
		layout.Window.Visible = false
		if layout.FooterHolder then
			layout.FooterHolder.Visible = false
		end
		if layout.Dim then
			layout.Dim.Visible = false
		end
		done.Position = UDim2.new(0.5, 0, 0, ui.insetUnits() + 12)
		done.Visible = true
		slinky:blurCheck()
	end
	layout.StopMovingHud = stop
	done.MouseButton1Click:Connect(stop)
	ui.whenShut(stop)

	pane:button('Move HUD', {
		clicked = start,
		about = 'Hides the menu so the overlays and widgets under it can be dragged, until you press Done'
	})
end

function build.settings()
	components.legitWindow()
	slinky.searchBar = components.searchBar()
	slinky.categories.Main:overlayBar()

	--[[
		General Settings
	]]
	
	local general = slinky.categories.Main.settings:settingsPane('General')
	local settingConnections = {}
	slinky.multiKeybind = general:toggle('Enable Multi-Keybinding', {
		about = 'Allows multiple keys to be bound to a module (eg. G + H)'
	})
	--[[ While on, every toggle option of every module gets a keybind that flips it, with a notification
	when slinky.settingToggleNotifications is on. Its badge shows while the pointer is on the row
	through ui.hover, never on a touch screen. Turning it off destroys the binds and disconnects
	their connections. ]]
	general:toggle('Allow setting keybinds', {
		changed = function(callback)
			if callback then
				for _, container in {slinky.moduleOrder, slinky.legit.order} do
					for _, module in orderedModules(container) do
						for _, component in module.options do
							if component.kind == 'toggle' then
								local bind = components.keybind({
									module = true
								}, nil, component)
								bind.row.Position = UDim2.new(1, -40, 0, 5)
	
								table.insert(settingConnections, bind.triggered:Connect(function(isDown)
									if bind.hold then
										if component.enabled ~= isDown then
											if slinky.settingToggleNotifications.enabled then
												slinky:notify(module.name, component.name..' '..(not component.enabled and "<font color='"..ui.hex(theme.Green).."'>ON</font>" or "<font color='"..ui.hex(theme.Red).."'>OFF</font>"), 1.5)
											end
	
											component:flip()
										end
									else
										if slinky.settingToggleNotifications.enabled then
											slinky:notify(module.name, component.name..' '..(not component.enabled and "<font color='"..ui.hex(theme.Green).."'>ON</font>" or "<font color='"..ui.hex(theme.Red).."'>OFF</font>"), 1.5)
										end
	
										component:flip()
									end
								end))

								table.insert(settingConnections, ui.hover(component.row, function()
									bind:setVisible(true)
								end, function()
									bind:setVisible(false)
								end))
							end
						end
					end
				end
			else
				for _, container in {slinky.moduleOrder, slinky.legit.order} do
					for _, module in orderedModules(container) do
						for _, component in module.options do
							if component.bind then
								component.bind:Destroy()
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
		about = 'Hover a toggle setting to bind it to a key'
	})
	

	--[[ Deletes the current profile's file and its old-format files (store.dropOld) with saving switched
	off, and reloads through the loader, which re-runs the key gate. A developer build runs
	loaderdev.lua from disk and is never fetched from GitHub. ]]
	general:button('Reset current profile', {
		clicked = function()
			ui.confirm("Reset the '"..slinky.profile.."' profile to the defaults? This reloads Pistonware.", function()
				slinky.save = function() end
				if isfile(store.path(slinky.profile)) and delfile then
					delfile(store.path(slinky.profile))
				end
				store.dropOld(slinky.profile)

				shared.slinkyreload = true
				if shared.PistonwareDeveloper and isfile('pistonware/loaderdev.lua') then
					runChunk(readfile('pistonware/loaderdev.lua'), 'loader')
				else
					runChunk(pistonwareHttpGet('https://raw.githubusercontent.com/themagicpiston/pistonware/main/loader.lua', true), 'loader')
				end
			end, 'Reset')
		end,
		about = 'This will set your profile to the default settings'
	})

	general:button('Self destruct', {
		clicked = function()
			ui.confirm('Unload Pistonware from this game?', function()
				slinky:unload()
			end, 'Unload')
		end,
		about = 'Removes Pistonware from the current game'
	})

	--[[ Reloads through the loader, which re-runs the key gate. A developer build runs loaderdev.lua
	from disk. ]]
	general:button('Reinject', {
		clicked = function()
			shared.slinkyreload = true
			if shared.PistonwareDeveloper and isfile('pistonware/loaderdev.lua') then
				runChunk(readfile('pistonware/loaderdev.lua'), 'loader')
			else
				runChunk(pistonwareHttpGet('https://raw.githubusercontent.com/themagicpiston/pistonware/main/loader.lua', true), 'loader')
			end
		end,
		about = 'Reloads Pistonware'
	})

	general:button('Reinstall', {
		clicked = function()
			ui.confirm('Delete the pistonware folder and download everything again?', function()
				runChunk(pistonwareHttpGet('https://raw.githubusercontent.com/themagicpiston/pistonware/refs/heads/main/reinstall.lua', true), 'reinstall')
			end, 'Reinstall')
		end,
		about = 'Uninjects, deletes the pistonware folder and downloads everything again'
	})

	--[[
		Module Settings
	]]
	
	local modules = slinky.categories.Main.settings:settingsPane('Modules')
	modules:toggle('Teams by server', {
		about = 'Ignore players on your team designated by the server',
		default = true,
		changed = function()
			if slinky.libraries.entity and slinky.libraries.entity.Running then
				slinky.libraries.entity.refresh()
			end
		end
	})
	
	modules:toggle('Use team color', {
		about = 'Uses the TeamColor property on players for render modules',
		default = true,
		changed = function()
			if slinky.libraries.entity and slinky.libraries.entity.Running then
				slinky.libraries.entity.refresh()
			end
		end
	})
	
	--[[
		GUI Settings
	]]
	
	--[[ The flat settings path slinky.categories.Main.options, now split across the settings panes, kept
	as a lazy lookup. games/universal.lua and two place files read 'Teams by server' and 'Use team
	color' there on entity and render paths, and universal.lua runs under main.lua's pcall, so a nil
	there loses every universal module. Panes and game files add options later, so nothing is
	copied; a found option is cached, as these reads run every frame. ]]
	slinky.categories.Main.options = setmetatable({}, {
		__index = function(self, key)
			for _, pane in slinky.settings do
				local ok, options = pcall(function() return pane.options end)
				if ok and type(options) == 'table' and options[key] ~= nil then
					rawset(self, key, options[key])
					return options[key]
				end
			end
			return nil
		end
	})

	local guipane = slinky.categories.Main.settings:settingsPane('GUI')
	--[[ Blur background, on by default everywhere: a phone takes the BlurEffect path in blurCheck
	instead of SetRobloxGuiFocused, the one call on menu open a client can die on. ]]
	slinky.blur = guipane:toggle('Blur background', {
		changed = function()
			slinky:blurCheck()
		end,
		default = true,
		about = 'Blur the background of the GUI'
	})
	

	guipane:toggle('GUI bind indicator', {
		default = true,
		about = "Displays a message indicating your GUI upon injecting.\nI.E. 'Press RSHIFT to open GUI'"
	})

	--[[ Tooltips are always on now (toggles and sliders only); the option keeps its save key and
	draws no row, and a profile that saved it off no longer turns them off. ]]
	guipane:toggle('Show tooltips', {
		changed = function()
			tooltip.Visible = false
		end,
		default = true,
		visible = false
	})

	guipane:toggle('Show legit mode', {
		changed = function(enabled)
			layout.ShowLegit = enabled
			layout.request('*')
		end,
		default = true,
		about = 'Shows the HUD and cosmetic modules (clock, keystrokes, FPS...) in the Visual tab'
	})

	local scaleSlider = {row = {}, value = 1}
	--[[ Auto rescale, a hidden toggle. On, the menu takes autoScaleValue at once, as a phone has no
	later resize to apply it; off, the scale slider's value. ]]
	slinky.scale = guipane:toggle('Auto rescale', {
		default = true,
		visible = false,
		changed = function(callback)
			scaleSlider.row.Visible = false
			if callback then
				scale.Scale = autoScaleValue()
			else
				scale.Scale = scaleSlider.value
			end
			local main = slinky.categories.Main
			if main and main.resize then
				main.resize()
			end
		end,
		about = 'Automatically rescales the gui using the screens resolution'
	})
	
	scaleSlider = guipane:slider('Scale', {
		min = 0.1,
		max = 2,
		decimal = 10,
		changed = function(val, final)
			if final and not slinky.scale.enabled then
				scale.Scale = val
			end
		end,
		default = 1,
		sub = true,
		visible = false
	})
	
	--[[ Hides the phone menu button by making it fully transparent rather than invisible: an invisible
	GuiObject stops hit-testing, and a phone has no keybind to open the menu, while a transparent
	button still takes the tap. ]]
	slinky.hideMenuButton = guipane:toggle('Hide Pistonware Mobile Button', {
		changed = function(callback)
			if slinky.menuButton then
				slinky.menuButton.BackgroundTransparency = callback and 1 or (slinky.menuButtonTransparency or 0)
				if slinky.menuButtonFace then
					slinky.menuButtonFace.GroupTransparency = callback and 1 or 0
				end
				if slinky.menuButtonStroke then
					slinky.menuButtonStroke.Transparency = callback and 1 or 0
				end
			end
		end,
		about = 'Makes the Pistonware button invisible on mobile\nIt still opens the GUI when tapped'
	})
	
	slinky.rainbowSpeed = guipane:slider('Rainbow speed', {
		min = 0.1,
		max = 10,
		decimal = 10,
		default = 1,
		about = 'Adjusts the speed of rainbow values'
	})
	
	slinky.rainbowUpdateSpeed = guipane:slider('Rainbow update rate', {
		min = 1,
		max = 144,
		default = 60,
		about = 'Adjusts the update rate of rainbow values',
		suffix = 'hz'
	})
	
	guipane:dropdown('Search bar style', {
		choices = {'Floating', 'None'},
		default = 'Floating',
		visible = false,
		changed = function(value)
			slinky.searchBar.row.Visible = value == 'Floating'
		end,
		about = 'Switch between search bar styles'
	})
	
	slinky.rainbowMode = guipane:dropdown('Rainbow Mode', {
		choices = {'Normal', 'Gradient', 'Retro'},
		about = 'Normal - Smooth color fade\nGradient - Gradient color fade\nRetro - Static color'
	})

	guipane:button('Edit hidden modules', {
		clicked = function()
			slinky.editing = not slinky.editing
			for _, module in orderedModules(slinky.moduleOrder) do
				if module.edit then
					module.edit.Visible = slinky.editing
				end
			end
			layout.request('*')
			slinky:notify('Pistonware', slinky.editing and 'Click a card to hide or show it, press this again when done.' or 'Done editing hidden modules.', 5)
		end,
		about = 'Shows every module so you can hide the ones you never use'
	})

	--[[ Puts every overlay and HUD widget back at its default slot. A fixed overlay (the Mod Overlay)
	keeps its own place in the top-right corner. ]]
	guipane:button('Reset GUI positions', {
		clicked = function()
			for _, category in slinky.categories do
				if category.kind == 'overlay' and category.row and not category.fixed then
					category.row.Position = ui.hudPlace('Overlay', category.hudSlot or 1)
				end
			end
			for _, module in orderedModules(slinky.legit.order) do
				if module.frame then
					module.frame.Position = ui.hudPlace('Widget', module.hudSlot or 1)
				end
			end
		end,
		about = 'Puts every overlay and on-screen widget back at the default position'
	})
	build.moveHud(guipane)

	--[[
		Notification Settings
	]]
	
	local notifpane = slinky.categories.Main.settings:settingsPane('Notifications')
	slinky.notifications = notifpane:toggle('Notifications', {
		changed = function(enabled)
			if slinky.toggleNotifications.row then
				slinky.toggleNotifications.row.Visible = enabled
			end
	
			if slinky.settingToggleNotifications.row then
				slinky.settingToggleNotifications.row.Visible = enabled
			end
		end,
		about = 'Shows notifications',
		default = true
	})
	
	slinky.toggleNotifications = notifpane:toggle('Toggle alert', {
		about = 'Notifies you if a module is enabled/disabled.',
		default = true,
		sub = true
	})
	slinky.settingToggleNotifications = notifpane:toggle('Setting toggle alert', {
		about = 'Notifies you when a bound setting is toggled.',
		default = true,
		sub = true
	})
	
	slinky.accent = slinky.categories.Main.settings:guiSlider('GUI Theme', {
		changed = function(h, s, v)
			slinky:recolor(h, s, v, true)
		end
	})
	
	slinky.menuBind = slinky.categories.Main.settings:keybind('Rebind GUI', {
		default = {'RightShift'},
		noRemove = true,
		about = 'Change the bind of the GUI'
	})

	--[[ Where notifications stack, at the top of the Notifications card: the bottom-right corner,
	or the top-left one Slinky uses. A touch screen starts on the top left, since the bottom right is
	where its jump and attack buttons are. A dropdown starts on its first entry without calling its
	Function, so the stack is told here as well. ]]
	layout.NotifyTop = isMobile()
	notifpane:dropdown('Position', {
		choices = isMobile() and {'Top left', 'Bottom right'} or {'Bottom right', 'Top left'},
		order = -1,
		changed = function(value)
			layout.NotifyTop = value == 'Top left'
			ui.restackNotifications()
		end,
		about = 'Where notifications appear on your screen'
	})

	--[[ This card's saved settings are applied as soon as it exists, before universal.lua and the
	game script, instead of with the rest of the profile. In BedWars the profile waits for the game
	script, half a minute on a cold start, and every notification before it -- Finished Loading
	among them -- used the defaults: the bottom-right corner, still showing when the profile's pair
	arrived and pushing them down the top-left stack. The profile load applies the same values
	again, which changes nothing. ]]
	pcall(function()
		if not isfile(store.settingsPath) then return end
		local settings = loadJson(store.settingsPath)
		local panes = settings and settings.settings
		local saved = type(panes) == 'table' and panes[store.snake('Notifications')]
		if type(saved) == 'table' then
			notifpane:load(saved)
		end
	end)

	--[[ Slinky's Main section: Scale, Accent color, Allow input while open. Scale drives the older
	Auto rescale toggle and Scale slider, which keep their save keys but draw no rows. ]]
	local mainPane = slinky.categories.Main.settings
	local SCALE_PRESETS = {['Small (75%)'] = 0.75, ['Medium (100%)'] = 1, ['Large (125%)'] = 1.25}
	local scalePreset
	local syncingScale = false
	scalePreset = mainPane:dropdown('Scale preset', {
		label = 'Scale',
		choices = {'Auto', 'Small (75%)', 'Medium (100%)', 'Large (125%)'},
		order = -1,
		changed = function(value)
			if syncingScale or slinky.applying then return end
			local factor = SCALE_PRESETS[value]
			local slider = slinky.settings.GUI and slinky.settings.GUI.options.Scale
			if factor then
				if slinky.scale.enabled then
					slinky.scale:flip()
				end
				if slider then
					slider:set(factor, nil, true)
				end
				scale.Scale = factor
			elseif not slinky.scale.enabled then
				slinky.scale:flip()
			end
		end
	})

	--[[ A profile saved before this dropdown existed carries only the older two settings, so after
	a load it shows what those amount to -- Auto, or the nearest preset -- instead of its default.
	Display only: the scale itself is left as loaded. ]]
	local function syncScalePreset()
		local shown = 'Auto'
		if not slinky.scale.enabled then
			local slider = slinky.settings.GUI and slinky.settings.GUI.options.Scale
			local value = slider and slider.value or scale.Scale
			local gap = math.huge
			for label, factor in SCALE_PRESETS do
				if math.abs(factor - value) < gap then
					shown, gap = label, math.abs(factor - value)
				end
			end
		end
		if scalePreset.value ~= shown then
			syncingScale = true
			pcall(scalePreset.set, scalePreset, shown)
			syncingScale = false
		end
	end
	local loadScale = slinky.load
	function slinky:load(...)
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
		if clickgui.Visible and allowInput and not allowInput.enabled then
			pcall(function()
				contextActionService:BindActionAtPriority('PistonwareMenuInput', function()
					return Enum.ContextActionResult.Sink
				end, false, Enum.ContextActionPriority.High.Value + 100,
					Enum.KeyCode.W, Enum.KeyCode.A, Enum.KeyCode.S, Enum.KeyCode.D, Enum.KeyCode.Space,
					Enum.KeyCode.Up, Enum.KeyCode.Down, Enum.KeyCode.Left, Enum.KeyCode.Right)
			end)
		end
	end
	allowInput = mainPane:toggle('Allow input while open', {
		default = true,
		order = 1,
		changed = applyInputBlock,
		about = 'Lets your character keep moving while the menu is open.'
	})
	slinky:clean(clickgui:GetPropertyChangedSignal('Visible'):Connect(applyInputBlock))
	slinky:clean(function()
		pcall(function()
			contextActionService:UnbindAction('PistonwareMenuInput')
		end)
	end)

	-- The GUI card's own badge is the menu key, as Slinky shows it. A phone has no key to press and
	-- opens the menu from the >_ button, so there the badge stays in its hidden row.
	local main = slinky.categories.Main
	if main.guiCard then
		if not isMobile() then
			slinky.menuBind:setParent(main.guiCard.NameRow)
		end
		slinky.menuBind.row.Visible = false
	end

	--[[ Slinky's Layout section: single-line cards, and a third column on a wide screen. GUI settings,
	saved in the settings file with the other panes, so every profile shares them. ]]
	local layoutPane = slinky.categories.Main.settings:settingsPane('Layout')
	layoutPane:toggle('Compact', {
		default = false,
		changed = function(enabled)
			layout.Compact = enabled
			for view in layout.CardViews do
				pcall(view.ApplyLayout, view)
			end
		end,
		about = 'One line per card: the + beside the name and no description.'
	})
	layoutPane:toggle('Wide', {
		default = false,
		changed = function(enabled)
			layout.Wide = enabled
			local main = slinky.categories.Main
			if main and main.resize then
				main.resize()
			end
		end,
		about = 'Three columns of cards when the screen is wide enough.'
	})
end

--[[ Builds the key footer: the loader-style bottom row with the time left on the key, the version and a
[discord] link, in the loader's palette rather than the menu theme. It sits in a place of its own at
the screen's foot in the window's width and zoom (components.gui), as the window scrolls and has no
foot; layout.FooterClear leaves room for it at the scroll's end.

Its text is Inter, measured with INTER_MEASURE because Potassium measures Inter at about 0.83 of its
drawn width; a window too narrow for the long line gets the short form. The countdown shows days and
hours, or hours and minutes under a day, from the expiry the loader stores; a developer run with no
expiry is a lifetime key. It refreshes when the menu opens, when the window resizes and every 30 s
while open; the open refresh is deferred so it does not run inside the write that opened the menu.

[discord] copies the invite and, on a computer, asks Discord's local RPC to open it. Only a real
answer counts as opened: some request functions return a failure on a closed port instead of
throwing. ]]
function build.keyFooter()
	local main = slinky.categories.Main
	local window = main and main.row
	local pages = window and window:FindFirstChild('Pages')
	if not (window and pages) then return end

	local CODE = Font.fromEnum(Enum.Font.Code)
	local INTER = fonts.face('Medium')
	local INTER_MEASURE = 1.2
	local ORANGE = Color3.fromRGB(240, 122, 31)
	local GREY = Color3.fromRGB(110, 110, 110)
	local LINE = Color3.fromRGB(237, 237, 237)
	local FOOTER_HEIGHT, FOOTER_GAP, TEXT_LEFT = 32, 8, 39

	local bar = ui.new('Frame', {
		Name = 'KeyFooter',
		Active = true,
		AnchorPoint = Vector2.new(0.5, 1),
		BackgroundColor3 = Color3.fromRGB(10, 10, 10),
		BackgroundTransparency = 0,
		BorderSizePixel = 0,
		Position = UDim2.new(0.5, 0, 1, 0),
		Size = UDim2.new(1, 0, 0, FOOTER_HEIGHT),
		ZIndex = 2
	}, layout.FooterHolder or window)
	ui.corner(bar, 10)
	ui.stroke(bar, Color3.fromRGB(52, 52, 52), 1, 0)
	layout.FooterClear = FOOTER_HEIGHT + FOOTER_GAP
	if layout.Scroll then
		layout.Scroll.request()
	end

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
		FontFace = INTER,
		Position = UDim2.fromOffset(TEXT_LEFT, 0),
		RichText = true,
		Size = UDim2.new(1, -200, 1, 0),
		Text = '',
		TextColor3 = GREY,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 2
	}, bar)

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
		FontFace = INTER,
		LayoutOrder = 2,
		Size = UDim2.fromOffset(0, 22),
		Text = 'v'..slinky.version,
		TextColor3 = GREY,
		TextSize = 14,
		ZIndex = 2
	}, corner)
	local discord = ui.new('TextButton', {
		Name = 'Discord',
		AutoButtonColor = false,
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundTransparency = 1,
		FontFace = INTER,
		LayoutOrder = 1,
		Size = UDim2.fromOffset(0, 22),
		Text = '[discord]',
		TextColor3 = GREY,
		TextSize = 14,
		ZIndex = 2
	}, corner)
	for _, object in {label, discord, corner:FindFirstChild('Version')} do
		fonts.Registry[object] = {Role = 'Medium'}
	end
	ui.hover(discord, function()
		discord.TextColor3 = LINE
	end, function()
		discord.TextColor3 = GREY
	end)

	local function unit(n, word)
		return n..' '..word..(n == 1 and '' or 's')
	end
	local function state()
		local expire = tonumber(shared.PistonwareKeyExpire)
		if not expire and shared.PistonwareDeveloper then
			expire = -1
		end
		local thanks = 'Thank you for choosing Pistonware.'
		if not expire then
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

	local function refresh()
		if slinky.threadFix then
			setthreadidentity(8)
		end
		local word, hex, chevron, lead, value, short = state()
		local cornerWidth = 120
		pcall(function()
			cornerWidth = (getfontbounds('v'..slinky.version, 14, INTER).X + getfontbounds('[discord]', 14, INTER).X) * INTER_MEASURE + 14
		end)
		local room = window.Size.X.Offset - TEXT_LEFT - cornerWidth - 16 - 12
		label.Size = UDim2.new(1, -(TEXT_LEFT + cornerWidth + 16 + 12), 1, 0)
		local fits = window.Size.X.Offset >= 700
		pcall(function()
			fits = getfontbounds(chevron..' '..(word and word..'  ' or '')..lead..value, 14, INTER).X * INTER_MEASURE <= room
		end)
		local body = fits and lead..(value ~= '' and '<font color="#EDEDED">'..value..'</font>' or '')
			or (value ~= '' and '<font color="#EDEDED">'..short..'</font>' or short)
		label.Text = '<font color="#9E9E9E">'..(chevron == '<' and '&lt;' or '&gt;')..'</font> '
			..(word and '<font color="'..hex..'">'..word..'</font>  ' or '')..body
	end

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
				slinky:notify('Pistonware', 'Opened the Pistonware invite in Discord.', 5, 'success')
			elseif copied and not isMobile() then
				slinky:notify('Pistonware', 'Discord is not running locally. Use the copied invite link.', 5, 'warning')
			elseif copied then
				slinky:notify('Pistonware', 'Discord invite copied to your clipboard.', 5, 'success')
			else
				slinky:notify('Pistonware', 'Join the Discord at discord.gg/pistonware', 8, 'warning')
			end
			busy = false
		end)
	end)

	slinky:clean(clickgui:GetPropertyChangedSignal('Visible'):Connect(function()
		if clickgui.Visible then
			task.defer(pcall, refresh)
		end
	end))
	slinky:clean(window:GetPropertyChangedSignal('Size'):Connect(function()
		if clickgui.Visible then
			task.defer(pcall, refresh)
		end
	end))
	slinky:clean(task.spawn(function()
		while true do
			task.wait(30)
			if clickgui.Visible then
				pcall(refresh)
			end
		end
	end))
	task.spawn(pcall, refresh)
end

--[[ Text GUI
Mod Overlay: Slinky's arraylist of active modules, fixed in the top-right corner, plus the
PISTONWARE watermark on Roblox's top bar. Each line is its own rounded dark pill, packed edge to
edge so the right edges step down like stairs, with the module's name in the accent and its
ExtraText detail in grey after it, lowercase by default and longest first. The options the old Text
GUI saved keep their names, so a saved profile still applies.

Lines come and go over Slinky's one curve, 0.2 s of Sine InOut, stepped by ui.anim as a HUD entry:
it runs with the menu shut, and only while a line is moving. At progress p a line's row is cut to (1
- p) of its height from the top, the rows under it close up in whole pixels, and its text and
backdrop slide toward the screen edge by p of the text's width and fade to 1 - p. Nothing scales and
the width never changes; a line keeps its place until it has gone, and one turned back on part way
out turns round without a jump.

One line per module is kept and updated in place: a redraw measures only text that changed and
reshapes only lines whose own or neighbouring width changed. Redraws are requests; any number in a
frame run once, after the callers' code and never on their thread. A measure can yield, and a newer
rebuild owns the list from then on (textGUIGeneration). ExtraText belongs to the game scripts and is
guarded, since a module whose state is not ready would abort the whole rebuild. Nothing is written
from a label's property signals: the custom text's shadow is set in the redraw. A profile load
recolours the whole menu; any other redraw recolours only the list.

Every line and the list's top land on whole screen pixels. Offsets are whole local units, which once
scaled end part way through a pixel and leave hairline gaps between the pills, so heights and widths
are shares of the list's size on screen, worked out from the scales rather than read back. Text is
measured at its drawn size, TextSize times the scale floored as Roblox draws it (24 at Text size 1.2
is 28.8, drawn at 28). A line is 1 em plus the padding: Slinky's lines are 26 px apart for 24 px
text at 1080p, Text size 1.2 with Padding Y 1. The em is used, not the TextSize, which is the face's
line height. The baseline sits at the row's middle plus 0.273 em (half Inter's x-height, 1118 of
2048), and Roblox draws it 0.8006 of the drawn size below a label's top (Inter's ascender over its
line height, 1984 of 2478). The screen-edge side gets one unit more padding: Slinky's text sits 4.3
px from the screen edge at 1080p. A four-per-em space separates name and detail, Slinky's 4 px gap
at 16 px text. Only a line's bottom corner on the open side is rounded, as far as it sticks out past
the line under it and no further than the radius, the last line fully; one fill per line overhangs
the row's top and screen-edge side so the row's clip squares those off. Rounding is in Slinky's
units, 1.6 px each. Text size is applied at build as well as by its slider, since a profile that
keeps the default never calls the slider's function.

The watermark is a notification's tag in a notification's capsule: PISTONWARE in Inter Medium in the
GUI colour on its tint (1/7 over the card), 24 px tall like the icons in Roblox's button pill, 9 px
either side, radius 9, text 12 em, inside a #141414 round-ended capsule as far clear as Watermark
spacing says (10 px is as tall as Roblox's pill). The piston face sits in the capsule's left end, 16
px at spacing 0 and 24 at 8, kept even so it centres on whole pixels, with a quarter of its vertical
margin moved from its right to its left, where it looks centred. It sits on the top bar 8 px right
of the game's buttons (TopbarInset's left end), centred on the 44 px buttons 2 px up from the
strip's bottom, in real pixels in the ScreenGui itself and under the menu (ZIndex 0). A client
without TopbarInset throws on its signal, so that connection is under pcall. 'Watermark text follows
GUI color' is saved under its own key because a saved value outlasts a new default. On a phone the
list keeps a little room from the screen's rounded edge and stays under Roblox's top bar and its >_
button. ]]
function build.modOverlay()
	local sort
	local fontOption
	local colorSlider
	local colorMode
	local detailsColor
	local uiScale
	local paddingX
	local paddingY
	local rounding
	local positionX
	local positionY
	local placeList
	local shadow
	local gradient
	local animations
	local watermark
	local watermarkSpacing
	local showIcon
	local syncText
	local watermarkTextColor
	local syncBackground
	local watermarkBackgroundColor
	local background
	local backgroundTransparency
	local backgroundTint
	local lowercase
	local showDetails
	local onlyBound
	local tabFilters = {}
	local hideModules
	local hideModulesList
	local hideRender
	local customText
	local customTextBox
	local customTextFont
	local customTextColor
	local customTextColorSlider
	local labels = {}
	local info = TweenInfo.new(0.2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)

	local function refresh()
		if slinky.updateOverlay then
			slinky:updateOverlay()
		end
	end
	local function recolorTextGUI()
		if slinky.loaded ~= nil and not slinky.accent.rainbow and textGUI and textGUI.switch.enabled and textGUI.updateColor then
			textGUI:updateColor(slinky.accent.hue, slinky.accent.sat, slinky.accent.value)
		end
	end

	textGUI = slinky:overlay('Text GUI', {
		label = 'Mod Overlay',
		about = 'Displays a list of all active mods.',
		categorySize = 240,
		fixed = true,
		toggled = refresh
	})
	textGUI.switch:flip()
	slinky:rebase(textGUI)

	textGUI:divider('Visible categories')
	for _, tab in TABS do
		if tab == 'FFlags' then continue end
		tabFilters[tab] = textGUI:toggle('Show '..tab, {
			label = tab,
			default = tab == 'Combat' or tab == 'Move',
			changed = refresh
		})
	end

	textGUI:divider('Customization')
	textGUI:slider('Scale', {
		label = 'Text size',
		min = 0.2,
		max = 2,
		decimal = 10,
		default = isMobile() and 0.8 or 1.2,
		changed = function(val)
			uiScale.Scale = val * ui.hudZoom()
			refresh()
		end
	})
	paddingX = textGUI:slider('Padding X', {
		min = 0,
		max = 8,
		default = 4,
		changed = refresh
	})
	paddingY = textGUI:slider('Padding Y', {
		min = 0,
		max = 5,
		default = 1,
		changed = refresh
	})
	rounding = textGUI:slider('Rounding', {
		min = 0,
		max = 8,
		default = 5,
		suffix = 'px',
		changed = refresh,
		about = '0 turns the rounding off'
	})
	local function movedList()
		if placeList then
			placeList()
		end
	end
	positionX = textGUI:slider('Position X', {
		min = 0,
		max = 1000,
		default = 0,
		suffix = 'px',
		changed = movedList,
		about = 'How far in from the right edge of the screen the list sits'
	})
	positionY = textGUI:slider('Position Y', {
		min = 0,
		max = 1000,
		default = 0,
		suffix = 'px',
		changed = movedList,
		about = 'How far down from the top of the screen the list sits'
	})
	colorSlider = textGUI:color('Text GUI color', {
		label = 'Text color',
		hue = slinky.accent.hue,
		sat = slinky.accent.sat,
		value = slinky.accent.value,
		changed = function()
			if slinky.loaded and colorMode and colorMode.value ~= 'Custom color' then
				colorMode:set('Custom color')
			end
			recolorTextGUI()
		end
	})
	detailsColor = textGUI:color('Details color', {
		hue = 0.0556,
		sat = 0,
		value = 0.7355,
		changed = refresh
	})
	lowercase = textGUI:toggle('Lowercase', {
		default = true,
		changed = refresh
	})
	showDetails = textGUI:toggle('Show details', {
		default = true,
		changed = refresh,
		about = 'Shows what a module is set to, usually its mode'
	})

	textGUI:divider('Conditions')
	onlyBound = textGUI:toggle('Only bound modules', {
		changed = refresh,
		about = 'Lists only modules that have a key bound'
	})

	textGUI:divider('Extras')
	sort = textGUI:dropdown('Sort', {
		choices = {'Length', 'Alphabetical'},
		changed = refresh
	})
	fontOption = textGUI:font('Font', {
		default = 'Inter',
		changed = refresh
	})
	colorMode = textGUI:dropdown('Color Mode', {
		choices = {'Custom color', 'Match GUI color'},
		changed = refresh,
		about = 'Follow the accent, or keep the Text color above'
	})
	background = textGUI:toggle('Render background', {
		default = true,
		changed = function(callback)
			if backgroundTransparency then
				backgroundTransparency.row.Visible = callback
			end
			if backgroundTint then
				backgroundTint.row.Visible = callback
			end
			refresh()
		end
	})
	backgroundTransparency = textGUI:slider('Transparency', {
		min = 0,
		max = 1,
		default = 0.5,
		decimal = 10,
		changed = refresh,
		sub = true,
		visible = background.enabled
	})
	backgroundTint = textGUI:toggle('Tint', {
		changed = refresh,
		sub = true,
		visible = background.enabled
	})
	shadow = textGUI:toggle('Shadow', {
		about = 'Renders shadowed text.',
		changed = refresh
	})
	gradient = textGUI:toggle('Gradient', {
		about = 'Fades the colour down the list',
		changed = refresh
	})
	animations = textGUI:toggle('Animations', {
		default = true,
		about = 'Slides lines in and out',
		changed = refresh
	})
	local function showWatermarkOptions()
		local on = watermark ~= nil and watermark.enabled
		if watermarkSpacing then
			watermarkSpacing.row.Visible = on
		end
		if showIcon then
			showIcon.row.Visible = on
		end
		if syncText then
			syncText.row.Visible = on
		end
		if watermarkTextColor then
			watermarkTextColor.row.Visible = on and not (syncText and syncText.enabled)
		end
		if syncBackground then
			syncBackground.row.Visible = on
		end
		if watermarkBackgroundColor then
			watermarkBackgroundColor.row.Visible = on and not (syncBackground and syncBackground.enabled)
		end
	end
	watermark = textGUI:toggle('Watermark', {
		default = true,
		about = 'Shows Pistonware on the top bar',
		changed = function()
			showWatermarkOptions()
			refresh()
		end
	})
	watermarkSpacing = textGUI:slider('Watermark spacing', {
		min = 0,
		max = 10,
		default = 8,
		suffix = 'px',
		sub = true,
		visible = watermark.enabled,
		about = 'How much dark background shows around the watermark',
		changed = refresh
	})
	showIcon = textGUI:toggle('Show Icon', {
		default = true,
		sub = true,
		visible = watermark.enabled,
		about = 'Shows the piston face in the watermark',
		changed = refresh
	})
	syncText = textGUI:toggle('Watermark text follows GUI color', {
		label = 'Sync text to GUI color',
		default = true,
		sub = true,
		visible = watermark.enabled,
		about = 'The watermark text follows the GUI color',
		changed = function()
			showWatermarkOptions()
			recolorTextGUI()
		end
	})
	watermarkTextColor = textGUI:color('Watermark text color', {
		hue = 0,
		sat = 0,
		value = 1,
		sub = true,
		visible = watermark.enabled and not syncText.enabled,
		changed = function()
			recolorTextGUI()
		end
	})
	syncBackground = textGUI:toggle('Sync background to GUI color', {
		default = true,
		sub = true,
		visible = watermark.enabled,
		about = 'The watermark background follows the GUI color',
		changed = function()
			showWatermarkOptions()
			recolorTextGUI()
		end
	})
	watermarkBackgroundColor = textGUI:color('Watermark background color', {
		hue = slinky.accent.hue,
		sat = slinky.accent.sat,
		value = slinky.accent.value,
		sub = true,
		visible = watermark.enabled and not syncBackground.enabled,
		changed = function()
			recolorTextGUI()
		end
	})
	hideModules = textGUI:toggle('Hide modules', {
		about = 'Allows you to blacklist certain modules from being shown.',
		changed = function(enabled)
			hideModulesList.row.Visible = enabled
			refresh()
		end
	})
	hideModulesList = textGUI:list('Blacklist', {
		about = 'Name of module to hide.',
		color = Color3.fromRGB(250, 50, 56),
		changed = refresh,
		visible = false,
		sub = true
	})
	hideRender = textGUI:toggle('Hide render', {
		default = true,
		changed = refresh,
		about = 'Hides the modules that only change what you see'
	})
	customText = textGUI:toggle('Add custom text', {
		changed = function(enabled)
			customTextBox.row.Visible = enabled
			customTextFont.row.Visible = enabled
			customTextColor.row.Visible = enabled
			customTextColorSlider.row.Visible = customTextColor.enabled and enabled
			refresh()
		end
	})
	customTextBox = textGUI:textbox('Custom text', {
		changed = refresh,
		sub = true,
		visible = false
	})
	customTextFont = textGUI:font('Custom Font', {
		default = 'Inter',
		changed = refresh,
		sub = true,
		visible = false
	})
	customTextColor = textGUI:toggle('Set custom text color', {
		changed = function(enabled)
			customTextColorSlider.row.Visible = enabled
			recolorTextGUI()
		end,
		sub = true,
		visible = false
	})
	customTextColorSlider = textGUI:color('Color of custom text', {
		changed = function()
			recolorTextGUI()
		end,
		sub = true,
		visible = false
	})

	uiScale = Instance.new('UIScale')
	uiScale.Parent = textGUI.frame
	local function applyTextSize()
		local option = textGUI.options.Scale
		uiScale.Scale = (option and option.value or (isMobile() and 0.8 or 1.2)) * ui.hudZoom()
	end
	function placeList()
		local s = math.max(scale.Scale, 0.05)
		local x = positionX and positionX.value or 0
		local top = (positionY and positionY.value or 0) / s
		if isMobile() then
			x += 8
			top = math.max(top, ui.insetUnits() + 4 / s)
			local button = slinky.menuButton
			if button and button.Parent then
				top = math.max(top, (button.AbsolutePosition.Y + button.AbsoluteSize.Y + 4) / s)
			end
		end
		textGUI.row.Position = UDim2.new(1, -math.floor(x / s), 0, math.floor(top))
	end
	applyTextSize()
	placeList()
	local placedZoom = ui.hudZoom()
	table.insert(ui.hudHooks, function(value)
		placeList()
		if value ~= placedZoom then
			placedZoom = value
			applyTextSize()
			refresh()
		end
	end)

	local MARK_GAP = 8
	local mark = ui.new('Frame', {
		Name = 'Watermark',
		AnchorPoint = Vector2.new(0, 0.5),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = theme.Bar,
		BackgroundTransparency = 0,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(208 + MARK_GAP, 34),
		Size = UDim2.fromOffset(0, 40),
		Visible = false,
		ZIndex = 0
	}, gui)
	ui.corner(mark, UDim.new(1, 0))
	local markPadding = ui.padding(mark, 10, 8, 0, 0)
	local markList = ui.list(mark, 6, true)
	local markLogo = ui.new('ImageLabel', {
		Name = 'Logo',
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Image = getslinkyasset('pistonware/assets/icons/pistonsquare.png'),
		LayoutOrder = 0,
		ResampleMode = Enum.ResamplerMode.Pixelated,
		Size = UDim2.fromOffset(24, 24)
	}, mark)
	ui.corner(markLogo, UDim.new(1, 0))
	local markTag = ui.text(mark, {Text = 'PISTONWARE', Size = 12, Weight = 'Medium', Color = theme.Accent(), AlignX = Enum.TextXAlignment.Center, Props = {
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = theme.Tint(theme.Accent(), 1 / 7),
		BackgroundTransparency = 0,
		BorderSizePixel = 0,
		LayoutOrder = 1,
		Size = UDim2.fromOffset(0, 24)
	}})
	ui.corner(markTag, 9)
	ui.padding(markTag, 9, 9, 0, 0)
	local function placeMark()
		local left, middle = 208 + MARK_GAP, 34
		pcall(function()
			local inset = guiService.TopbarInset
			if inset.Height >= 44 then
				left = inset.Min.X + MARK_GAP
				middle = inset.Max.Y - 2 - 22
			end
		end)
		local position = UDim2.fromOffset(math.floor(left), math.floor(middle))
		if mark.Position ~= position then
			mark.Position = position
		end
	end
	local function fitMark()
		local spacing = math.clamp(math.floor(watermarkSpacing and tonumber(watermarkSpacing.value) or 8), 0, 10)
		local height = 24 + spacing * 2
		local size = UDim2.fromOffset(0, height)
		if mark.Size ~= size then
			mark.Size = size
		end
		local shown = showIcon == nil or showIcon.enabled
		if markLogo.Visible ~= shown then
			markLogo.Visible = shown
		end
		local face = 16 + spacing + spacing % 2
		local faceSize = UDim2.fromOffset(face, face)
		if markLogo.Size ~= faceSize then
			markLogo.Size = faceSize
		end
		local margin = (height - face) / 2
		local nudge = math.floor(margin / 4 + 0.5)
		local before = UDim.new(0, shown and margin + nudge or spacing)
		local after = UDim.new(0, shown and margin - nudge or 0)
		local reach = UDim.new(0, spacing)
		if markPadding.PaddingLeft ~= before or markPadding.PaddingRight ~= reach then
			markPadding.PaddingLeft = before
			markPadding.PaddingRight = reach
		end
		if markList.Padding ~= after then
			markList.Padding = after
		end
		local clear = spacing > 0 and 0 or 1
		if mark.BackgroundTransparency ~= clear then
			mark.BackgroundTransparency = clear
		end
	end
	pcall(function()
		slinky:clean(guiService:GetPropertyChangedSignal('TopbarInset'):Connect(function()
			slinky:updateOverlay()
		end))
	end)

	local labelCustom = Instance.new('TextLabel')
	labelCustom.BackgroundTransparency = 1
	labelCustom.BorderSizePixel = 0
	labelCustom.FontFace = customTextFont.value
	labelCustom.Position = UDim2.fromOffset(5, 2)
	labelCustom.Text = ''
	labelCustom.TextSize = 25
	labelCustom.Visible = false
	labelCustom.RichText = true
	local labelCustomShadow = labelCustom:Clone()
	labelCustomShadow.TextColor3 = Color3.new()
	labelCustomShadow.TextTransparency = 0.65
	labelCustomShadow.Parent = textGUI.frame
	labelCustom.Parent = textGUI.frame
	local labelHolder = Instance.new('Frame')
	labelHolder.Name = 'Holder'
	labelHolder.Size = UDim2.fromScale(1, 1)
	labelHolder.Position = UDim2.fromOffset(5, 37)
	labelHolder.BackgroundTransparency = 1
	labelHolder.Parent = textGUI.frame
	local listLayout = Instance.new('UIListLayout')
	listLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	listLayout.VerticalAlignment = Enum.VerticalAlignment.Top
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Parent = labelHolder

	slinky:clean(textGUI.frame:GetPropertyChangedSignal('AbsolutePosition'):Connect(function()
		slinky:updateOverlay()
	end))

	local function escape(text)
		return (tostring(text):gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;'))
	end

	local function hexOf(colorValue)
		return '#'..colorValue:ToHex()
	end

	local textGUIGeneration = 0
	local lines = {}
	local textGUIQueued, textGUIAfterLoad = false, false
	local rebuildTextGUI
	function slinky:updateOverlay(afterload)
		if afterload then
			textGUIAfterLoad = true
		end
		if textGUIQueued then return end
		textGUIQueued = true
		task.defer(function()
			textGUIQueued = false
			local carried = textGUIAfterLoad
			textGUIAfterLoad = false
			if slinky.loaded == nil then return end
			if slinky.threadFix then
				setthreadidentity(8)
			end
			pcall(rebuildTextGUI, carried)
		end)
	end

	local function clearShape(line)
		for _, part in line.Parts do
			part:Destroy()
		end
		table.clear(line.Parts)
		table.clear(line.Fills)
		line.LastTint = nil
		line.ShapeKey = nil
		line.DrawnP = nil
	end

	local function removeLine(name)
		local line = lines[name]
		if line then
			line.Object:Destroy()
			lines[name] = nil
		end
	end

	local motion = {Duration = info.Time, ListHeight = 0, Px = 1, Right = true, Transparency = 0}

	function motion.layout()
		local listHeight, right, transparency = motion.ListHeight, motion.Right, motion.Transparency
		local y = 0
		for _, line in labels do
			local p = ui.anim.sineInOut(line.U or 0)
			local top = math.floor(y)
			y += line.Full * (1 - p)
			local h = math.floor(y) - top
			local holder = line.Object
			if holder.Visible ~= (h > 0) then
				holder.Visible = h > 0
			end
			if h > 0 then
				if line.DrawnH ~= h or line.DrawnFull ~= line.Full or line.DrawnShare ~= line.WidthShare then
					line.DrawnH, line.DrawnFull, line.DrawnShare = h, line.Full, line.WidthShare
					holder.Size = UDim2.new(line.WidthShare, listHeight > 0 and UDim.new(h / listHeight, 0) or UDim.new(0, math.floor(h / motion.Px + 0.5)))
					line.Slide.Size = UDim2.new(1, 0, line.Full / h, 0)
				end
				local x = math.floor(line.TextPx * p)
				if line.DrawnX ~= x or line.DrawnRight ~= right or line.DrawnWidth ~= line.WidthPx then
					line.DrawnX, line.DrawnRight, line.DrawnWidth = x, right, line.WidthPx
					local share = x / math.max(line.WidthPx, 1)
					line.Slide.Position = UDim2.fromScale(right and share or -share, 0)
				end
			end
			if line.DrawnP ~= p or line.DrawnT ~= transparency then
				line.DrawnP, line.DrawnT = p, transparency
				line.Text.TextTransparency = p
				line.Shadow.TextTransparency = 0.5 + 0.5 * p
				for _, fill in line.Fills do
					fill.BackgroundTransparency = 1 - (1 - transparency) * (1 - p)
				end
			end
		end
	end

	function motion.advance(dt)
		local moving, gone = false, false
		for index = #labels, 1, -1 do
			local line = labels[index]
			if line.Dir ~= 0 then
				line.U = math.clamp(line.U + line.Dir * dt / motion.Duration, 0, 1)
				if line.U == (line.Dir > 0 and 1 or 0) then
					line.Dir = 0
				else
					moving = true
				end
			end
			if line.Dir == 0 and line.U == 1 and not line.Enabled then
				table.remove(labels, index)
				removeLine(line.Name)
				gone = true
			end
		end
		motion.layout()
		if gone then
			slinky:updateOverlay()
		end
		return not moving
	end

	motion.Entry = {
		Hud = true,
		Step = function(dt)
			return motion.advance(textGUI.switch.enabled and dt or math.huge)
		end,
		Finish = function()
			motion.advance(math.huge)
		end
	}

	function rebuildTextGUI(afterload)
		if not afterload and not slinky.loaded then return end
		local markShown = textGUI.switch.enabled and watermark.enabled
		if mark.Visible ~= markShown then
			mark.Visible = markShown
		end
		if markShown then
			fitMark()
			placeMark()
		end
		if textGUI.switch.enabled then
			textGUIGeneration += 1
			local generation = textGUIGeneration
			local isRight = textGUI.frame.AbsolutePosition.X > (gui.AbsoluteSize.X / 2)

			labelCustom.Text = customTextBox.value
			labelCustom.FontFace = customTextFont.value
			labelCustom.Visible = labelCustom.Text ~= '' and customText.enabled
			labelCustomShadow.Visible = labelCustom.Visible and shadow.enabled
			labelCustomShadow.Text = contentText(labelCustom)
			labelCustomShadow.FontFace = labelCustom.FontFace
			listLayout.HorizontalAlignment = isRight and Enum.HorizontalAlignment.Right or Enum.HorizontalAlignment.Left
			labelHolder.Size = UDim2.fromScale(1 / uiScale.Scale, 1)

			if labelCustom.Visible then
				local size = getfontbounds(contentText(labelCustom), labelCustom.TextSize, labelCustom.FontFace)
				if textGUIGeneration ~= generation then return end
				labelCustom.Size = UDim2.fromOffset(size.X, size.Y)
				labelCustom.Position = UDim2.new(isRight and 1 / uiScale.Scale or 0, isRight and -size.X or 0, 0, 8)
				labelCustomShadow.Size = labelCustom.Size
				labelCustomShadow.Position = UDim2.new(labelCustom.Position.X.Scale, labelCustom.Position.X.Offset + 1, 0, labelCustom.Position.Y.Offset + 1)
			end

			local px = math.max(scale.Scale, 0.05) * math.max(uiScale.Scale, 0.05)
			local listHeight = textGUI.frame.Size.Y.Offset * px
			local drawnSize = math.max(math.floor(theme.em(theme.OverlayEm) * px + 1e-4), 1)
			local listWidth = textGUI.row.Size.X.Offset * math.max(scale.Scale, 0.05)
			local function pixelWidth(units)
				local pixels = math.max(math.floor(units * px + 0.5), 1)
				if listWidth > 0 then
					return UDim.new(pixels / listWidth, 0), pixels
				end
				return UDim.new(0, units), pixels
			end
			local function pixelHeight(units)
				local pixels = math.max(math.floor(units * px + 0.5), 1)
				if listHeight > 0 then
					return UDim.new(pixels / listHeight, 0), pixels / px, pixels
				end
				return UDim.new(0, units), units, pixels
			end
			local top = 0
			if labelCustom.Visible then
				top = labelCustom.Position.Y.Offset + labelCustom.Size.Y.Offset + 4
			end
			labelHolder.Position = top > 0 and UDim2.new(UDim.new(0, 0), (pixelHeight(top))) or UDim2.new()

			local padX, padY = paddingX.value, paddingY.value
			local _, boxHeight, boxPixels = pixelHeight(theme.OverlayEm + padY * 2)
			local baselinePx = math.floor(boxPixels / 2 + 0.273 * theme.OverlayEm * px + 0.5)
			local textX = isRight and padX or padX + 1
			local textY = math.floor((baselinePx - 0.8006 * drawnSize) / px + 0.5)
			local detailsHex = hexOf(Color3.fromHSV(detailsColor.hue, detailsColor.sat, detailsColor.value))
			local fontFace = fontOption.value
			local animate = animations.enabled
			local listed = {}
			table.clear(labels)
			for name, module in orderedModules(slinky.moduleOrder) do
				if hideModules.enabled then
					local hidden = false
					local plain, shown = name:lower(), tostring(module.label or name):lower()
					for _, entry in hideModulesList.active do
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

				if hideRender.enabled and module.category == 'Render' then
					continue
				end

				local filter = tabFilters[module.tab or 'Utility']
				if filter and not filter.enabled then
					continue
				end

				if onlyBound.enabled and not (module.bind and #module.bind.keys > 0) then
					continue
				end

				local line = lines[name]
				local wasShown = line ~= nil and line.Enabled
				local leaving = line ~= nil and not module.enabled and animate and (wasShown or line.U < 1)
				if module.enabled or leaving then
					local extra = ''
					if showDetails.enabled and module.info then
						local ok, text = pcall(module.info)
						if ok and text ~= nil and text ~= '' then
							extra = tostring(text)
						end
					end
					local shown = module.label or name
					if lowercase.enabled then
						shown = shown:lower()
						extra = extra:lower()
					end
					local text = escape(shown)..(extra ~= '' and "\u{2005}<font color='"..detailsHex.."'>"..escape(extra)..'</font>' or '')

					if not line then
						local holder = Instance.new('Frame')
						holder.BackgroundTransparency = 1
						holder.ClipsDescendants = true
						holder.Name = name
						holder.Size = UDim2.fromOffset()
						holder.Visible = false
						holder.Parent = labelHolder
						local slide = Instance.new('Frame')
						slide.BackgroundTransparency = 1
						slide.BorderSizePixel = 0
						slide.Name = 'Slide'
						slide.Size = UDim2.fromScale(1, 1)
						slide.Parent = holder

						local label = Instance.new('TextLabel')
						label.BackgroundTransparency = 1
						label.BorderSizePixel = 0
						label.FontFace = fontFace
						label.ZIndex = 2
						label.RichText = true
						label.TextSize = theme.em(theme.OverlayEm)
						label.TextXAlignment = Enum.TextXAlignment.Left
						label.TextYAlignment = Enum.TextYAlignment.Top
						local shadowlabel = label:Clone()
						shadowlabel.TextColor3 = Color3.new()
						shadowlabel.TextTransparency = 0.5
						shadowlabel.Visible = false
						shadowlabel.Parent = slide
						label.Parent = slide
						line = {Name = name, Object = holder, Slide = slide, Text = label, Shadow = shadowlabel, Fills = {}, Parts = {}, Enabled = false, U = 1, Dir = 0}
						lines[name] = line
					end
					listed[name] = true
					local label, shadowlabel = line.Text, line.Shadow

					if line.Markup ~= text or line.Font ~= fontFace or line.DrawnSize ~= drawnSize or line.Px ~= px then
						label.FontFace = fontFace
						label.Text = text
						local bounds = getfontbounds(contentText(label), drawnSize, label.FontFace)
						if textGUIGeneration ~= generation then return end
						local measured = Vector2.new(bounds.X / px, bounds.Y / px)
						label.Size = UDim2.fromOffset(math.ceil(measured.X), math.ceil(measured.Y))
						shadowlabel.FontFace = fontFace
						shadowlabel.Text = contentText(label)
						shadowlabel.Size = label.Size
						line.Markup, line.Font, line.DrawnSize, line.Px, line.Measure = text, fontFace, drawnSize, px, measured
						line.TextPixels = math.floor(bounds.X + 0.5)
					end
					local size = line.Measure

					if line.PadX ~= textX or line.TextY ~= textY then
						line.PadX, line.TextY = textX, textY
						label.Position = UDim2.fromOffset(textX, textY)
						shadowlabel.Position = UDim2.fromOffset(textX + 1, textY + 1)
					end
					if shadowlabel.Visible ~= shadow.enabled then
						shadowlabel.Visible = shadow.enabled
					end

					line.Full = boxPixels
					line.WidthShare, line.WidthPx = pixelWidth(size.X + padX * 2 + 1)
					line.TextPx = line.TextPixels
					if animate then
						if module.enabled then
							if not wasShown then
								line.Dir = line.U > 0 and -1 or 0
							end
						else
							line.Dir = line.U < 1 and 1 or 0
						end
					else
						line.U, line.Dir = module.enabled and 0 or 1, 0
					end

					line.Enabled = module.enabled
					line.Width = size.X
					line.Height = boxHeight
					line.Display = shown
					table.insert(labels, line)
				end
			end

			for name in lines do
				if not listed[name] then
					removeLine(name)
				end
			end

			if sort.value == 'Alphabetical' then
				table.sort(labels, function(a, b)
					return a.Display < b.Display
				end)
			else
				table.sort(labels, function(a, b)
					if a.Width == b.Width then return a.Display < b.Display end
					return a.Width > b.Width
				end)
			end

			for index, label in labels do
				if label.Object.LayoutOrder ~= index then
					label.Object.LayoutOrder = index
				end
			end

			local radius = math.floor(rounding.value * 1.6 + 0.5)
			local transparency = backgroundTransparency.value
			local tinted = backgroundTint.enabled
			local function shapePill(label, below)
				local corner = radius
				if below then
					local step = math.floor((label.WidthPx or label.Width * px) - (below.WidthPx or below.Width * px))
					corner = math.clamp(math.floor(step / px + 0.5), 0, radius)
				end
				corner = math.min(corner, math.floor((label.Height or 0) / 2))
				local key = table.concat({corner, isRight and 1 or 0, tinted and 1 or 0}, ':')
				if label.ShapeKey == key then return end
				clearShape(label)
				label.ShapeKey = key
				local fill = Instance.new('Frame')
				fill.BackgroundColor3 = Color3.new()
				fill.BackgroundTransparency = transparency
				fill.BorderSizePixel = 0
				fill.Position = UDim2.new(0, isRight and 0 or -corner, 0, -corner)
				fill.Size = UDim2.new(1, corner, 1, corner)
				fill.ZIndex = 1
				fill.Parent = label.Slide
				if corner > 0 then
					local round = Instance.new('UICorner')
					round.CornerRadius = UDim.new(0, corner)
					round.Parent = fill
				end
				table.insert(label.Parts, fill)
				table.insert(label.Fills, fill)
			end
			if background.enabled then
				for index, label in labels do
					shapePill(label, labels[index + 1])
				end
			else
				for _, label in labels do
					if label.ShapeKey then
						clearShape(label)
					end
				end
			end

			motion.ListHeight, motion.Px, motion.Right, motion.Transparency = listHeight, px, isRight, transparency
			motion.layout()
			for _, line in labels do
				if line.Dir ~= 0 then
					ui.anim.play(lines, motion.Entry)
					break
				end
			end
		end

		if afterload then
			slinky:recolor(slinky.accent.hue, slinky.accent.sat, slinky.accent.value, true)
		elseif slinky.loaded ~= nil and textGUI.switch.enabled then
			textGUI:updateColor(slinky.accent.hue, slinky.accent.sat, slinky.accent.value, true)
		end
	end

	function textGUI:updateColor(hue, sat, val, default)
		local base = Color3.fromHSV(hue, sat, val)
		local fade = gradient.enabled and Color3.fromHSV(slinky:colorAt((hue - 0.075) % 1)) or base
		if mark.Visible then
			local fill = syncBackground.enabled and theme.Tint(base, 1 / 7)
				or Color3.fromHSV(watermarkBackgroundColor.hue, watermarkBackgroundColor.sat, watermarkBackgroundColor.value)
			if markTag.BackgroundColor3 ~= fill then
				markTag.BackgroundColor3 = fill
			end
			local ink = syncText.enabled and base
				or Color3.fromHSV(watermarkTextColor.hue, watermarkTextColor.sat, watermarkTextColor.value)
			if markTag.TextColor3 ~= ink then
				markTag.TextColor3 = ink
			end
		end
		if labelCustom.Visible then
			labelCustom.TextColor3 = customTextColor.enabled and Color3.fromHSV(customTextColorSlider.hue, customTextColorSlider.sat, customTextColorSlider.value) or base
		end

		local isCustom = colorMode.value == 'Custom color' and Color3.fromHSV(colorSlider.hue, colorSlider.sat, colorSlider.value) or nil
		for index, label in labels do
			local textColor = isCustom
			if not textColor then
				if slinky.accent.rainbow then
					textColor = Color3.fromHSV(slinky:colorAt((hue - ((gradient.enabled and index + 2 or index) * 0.025)) % 1))
				elseif gradient.enabled then
					textColor = base:Lerp(fade, math.clamp((index - 1) / math.max(#labels - 1, 1), 0, 1))
				else
					textColor = base
				end
			end
			if label.LastColor ~= textColor then
				label.LastColor = textColor
				label.Text.TextColor3 = textColor
			end

			if backgroundTint.enabled then
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

--[[ Target Info
Shows who you are fighting: their avatar in a ring of their health colour, their name and distance,
their health and a full-width bar. The target is the entry in targetinfo.Targets with the latest
expiry. The game scripts record every hit there whether the card is on or not, so a thread drops
expired entries every 2 s while it is off.

With the background off, or made mostly see-through by Transparency, every label turns bright with a
dark outline and the bar gets a dark track and rim so it reads over anything. A hit shows on the bar
at once (a 0.12 s slide) and a heal slides slower; the number counts over 0.3 s on a hit and 0.4 s
on a heal, easing out. A new target snaps, since sliding from the last one's health would read as a
hit. The card and its parts fade in a beat apart and out bar first, and Damage Tint washes it red
when your own health drops; damage taken while it was off does not count.

Nothing on the card runs from a property-changed signal: Update, which runs every frame while the
card is on, sets everything and writes a property only when its value changed. A handler that writes
properties inside the write that fired it nests one write in another, and on Delta that nesting was
part of what corrupted memory and closed the app on the next teleport.

Follow Target puts the card a little right of the target's shoulder, level with their head, kept on
screen, and back in its window while the menu is open; off screen, dead or let go of, it fades where
it last was. A card hung under it (a child named Inventory) counts toward the bottom kept on screen.
The menu's ScreenGui ignores the top bar inset, so the projected point is in viewport pixels, while
AbsolutePosition is measured below the top bar. The name's room is estimated per character rather
than measured: Potassium reports Inter's TextBounds at 0.83x. NameHider is applied here, since
Update writes the real name every frame and an outside watcher would only fight it. ]]
function build.targetInfo()
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
	local targetInfoOverlay
	local backgroundTransparency = {
		value = 0.15,
		row = {Visible = {}}
	}
	local borderColor
	local bkgColor
	local customColor
	local displayName
	local border
	local damageTint
	local followTarget
	local localPlayer = cloneref(game:GetService('Players')).LocalPlayer
	local backgroundOn, carded = true, true

	slinky:clean(task.spawn(function()
		repeat
			task.wait(2)
			if not (targetInfoOverlay and targetInfoOverlay.switch and targetInfoOverlay.switch.enabled) then
				local now = tick()
				for target, expire in targetinfo.Targets do
					if type(expire) ~= 'number' or expire < now then
						targetinfo.Targets[target] = nil
					end
				end
			end
		until false
	end))

	targetInfoOverlay = slinky:overlay('Target Info', {
		about = 'Shows who you are fighting and their health.',
		categorySize = WIDTH,
		toggled = function(on)
			if on then
				targetInfoOverlay:clean(runService.RenderStepped:Connect(function()
					targetinfo:Update()
				end))
			end
		end
	})

	local holder = ui.new('Frame', {
		BackgroundColor3 = CARD.Window,
		BackgroundTransparency = backgroundTransparency.value,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(WIDTH, HEIGHT)
	}, targetInfoOverlay.frame)
	targetinfo.Object = holder
	ui.corner(holder, 20)
	local stroke = ui.stroke(holder, CARD.Border, 1, 0.9)
	local tint = ui.new('Frame', {
		Name = 'DamageTint',
		BackgroundColor3 = Color3.fromRGB(235, 55, 55),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1)
	}, holder)
	ui.corner(tint, 20)

	local headshot = ui.new('ImageLabel', {
		Name = 'Avatar',
		BackgroundColor3 = CARD.Tile,
		BorderSizePixel = 0,
		Image = 'rbxthumb://type=AvatarHeadShot&id=1&w=150&h=150',
		Position = UDim2.fromOffset(PAD, (HEIGHT - AVATAR) / 2),
		Size = UDim2.fromOffset(AVATAR, AVATAR)
	}, holder)
	ui.corner(headshot, UDim.new(1, 0))
	local ring = ui.stroke(headshot, CARD.Green, 2, 0)

	local left = PAD + AVATAR + 10
	local title = ui.text(holder, {Text = 'No target', TextSize = 15, Weight = 'SemiBold', Color = CARD.Name, Props = {
		Name = 'Name',
		Position = UDim2.fromOffset(left, 8),
		Size = UDim2.new(1, -(left + PAD), 0, 20),
		TextTruncate = Enum.TextTruncate.AtEnd
	}})
	local distanceLabel = ui.text(holder, {Text = '', TextSize = 13, Weight = 'Medium', Color = CARD.Muted, AlignX = Enum.TextXAlignment.Right, Props = {
		Name = 'Distance',
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -PAD, 0, 8),
		Size = UDim2.fromOffset(48, 20)
	}})
	local function fitTitle(distance)
		local reserve = distance == '' and 0 or #distance * 8 + 8
		title.Size = UDim2.new(1, -(left + PAD + reserve), 0, 20)
	end
	local healthRow = ui.new('Frame', {
		Name = 'HealthRow',
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(left, 28),
		Size = UDim2.new(1, -(left + PAD), 0, 18)
	}, holder)
	ui.list(healthRow, 5, true)
	local healthText = ui.text(healthRow, {Text = '', TextSize = 14, Weight = 'Bold', Color = CARD.Green, Props = {
		Name = 'Health',
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = 1,
		Size = UDim2.fromOffset(0, 18)
	}})
	local maxText = ui.text(healthRow, {Text = '', TextSize = 12, Weight = 'Medium', Color = CARD.Muted, Props = {
		Name = 'MaxHealth',
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = 2,
		Size = UDim2.fromOffset(0, 18)
	}})

	for _, label in {title, distanceLabel, healthText, maxText} do
		label.TextStrokeColor3 = Color3.new()
	end

	local barFrame = ui.new('Frame', {
		Name = 'HealthBar',
		BackgroundColor3 = Color3.new(1, 1, 1),
		BackgroundTransparency = 0.88,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(left, 49),
		Size = UDim2.new(1, -(left + PAD), 0, 6)
	}, holder)
	ui.corner(barFrame, UDim.new(1, 0))
	local barRim = ui.stroke(barFrame, Color3.new(), 1, 0.5)
	barRim.Enabled = false
	local fill = ui.new('Frame', {
		BackgroundColor3 = CARD.Green,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1)
	}, barFrame)
	ui.corner(fill, UDim.new(1, 0))

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
		healthText.TextColor3 = healthColor(percent)
		healthText.Text = math.floor(shownHealth + 0.5)..' \u{2665}'
		maxText.TextColor3 = carded and CARD.Muted or CARD.Bright
		maxText.Text = '/ '..math.floor(shownMax + 0.5)
	end

	local COUNT_TIME = {drop = 0.3, heal = 0.4}
	local count = {From = 20, To = 20, Time = 0, Length = 0}
	local function stepHealthCount(dt)
		if count.Time >= count.Length then return end
		count.Time = math.min(count.Time + dt, count.Length)
		local x = count.Time / count.Length
		shownHealth = count.From + (count.To - count.From) * (1 - (1 - x) ^ 3)
		paintHealthText()
	end

	local BAR_SLIDE = {
		drop = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		heal = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	}
	local function showHealth(health, maxHealth, mode)
		local length = COUNT_TIME[mode]
		if length then
			count.From, count.To, count.Time, count.Length = shownHealth, health, 0, length
		else
			count.From, count.To, count.Time, count.Length = health, health, 0, 0
			shownHealth = health
		end
		shownMax = maxHealth
		local percent = maxHealth > 0 and math.clamp(health / maxHealth, 0, 1) or 0
		local colour = healthColor(percent)
		paintHealthText()
		ring.Color = colour
		local slide = BAR_SLIDE[mode]
		if slide then
			tween:Tween(fill, slide, {
				Size = UDim2.fromScale(percent, 1),
				BackgroundColor3 = colour
			})
		else
			tween:Cancel(fill)
			fill.Size = UDim2.fromScale(percent, 1)
			fill.BackgroundColor3 = colour
		end
	end
	showHealth(20, 20, 'snap')

	local IN_TIME, OUT_TIME, HURT_TIME, HURT_STRENGTH = 0.4, 0.22, 0.45, 0.55
	local anim = {Show = 0, Hurt = 0, Clock = os.clock()}
	local ORIGIN = UDim2.new()
	local look = {Card = backgroundTransparency.value, Border = 0.9, Outline = 1, Track = 0.88, Rim = 0.5}
	local function ease(x)
		x = math.clamp(x, 0, 1)
		return 1 - (1 - x) ^ 4
	end
	local function shown(delay)
		return ease((anim.Show - delay) / (1 - 0.3))
	end
	local function fade(rest, alpha)
		return 1 - (1 - rest) * alpha
	end
	local function paint()
		local card, avatar, bar = shown(0), shown(0.08), shown(0.3)
		local name, health = shown(0.16), shown(0.24)
		holder.BackgroundTransparency = fade(look.Card, card)
		tint.BackgroundTransparency = 1 - HURT_STRENGTH * ease(anim.Hurt) * card
		stroke.Transparency = fade(look.Border, card)
		headshot.BackgroundTransparency = fade(0, avatar)
		headshot.ImageTransparency = fade(0, avatar)
		ring.Transparency = fade(0, avatar)
		title.TextTransparency = fade(0, name)
		title.TextStrokeTransparency = fade(look.Outline, name)
		distanceLabel.TextTransparency = fade(0, name)
		distanceLabel.TextStrokeTransparency = fade(look.Outline, name)
		for _, label in {healthText, maxText} do
			label.TextTransparency = fade(0, health)
			label.TextStrokeTransparency = fade(look.Outline, health)
		end
		barFrame.BackgroundTransparency = fade(look.Track, bar)
		barRim.Transparency = fade(look.Rim, bar)
		fill.BackgroundTransparency = fade(0, bar)
	end

	local function setBackground(on, transparency)
		backgroundOn = on
		carded = on and transparency < 0.5
		look.Card = on and transparency or 1
		stroke.Enabled = on and (border == nil or border.enabled)
		look.Outline = carded and 1 or 0.45
		distanceLabel.TextColor3 = carded and CARD.Muted or CARD.Bright
		barFrame.BackgroundColor3 = carded and Color3.new(1, 1, 1) or Color3.new()
		look.Track = carded and 0.88 or 0.35
		barRim.Enabled = not carded
		paintHealthText()
		paint()
	end

	targetInfoOverlay:font('Font', {
		default = 'Inter',
		changed = function() end
	})
	displayName = targetInfoOverlay:toggle('Use Displayname', {
		default = true
	})
	damageTint = targetInfoOverlay:toggle('Damage Tint', {
		default = true,
		about = 'Flashes the card red for a moment when you take damage.'
	})
	followTarget = targetInfoOverlay:toggle('Follow Target', {
		default = false,
		about = 'Shows the card beside the player you are fighting instead of in its window.\nIt returns to its window while the menu is open.'
	})
	local renderBackground
	renderBackground = targetInfoOverlay:toggle('Render Background', {
		changed = function(callback)
			setBackground(callback, backgroundTransparency.value)
			backgroundTransparency.row.Visible = callback
		end,
		default = true
	})
	backgroundTransparency = targetInfoOverlay:slider('Transparency', {
		min = 0,
		max = 1,
		default = 0.15,
		decimal = 100,
		changed = function(val)
			if renderBackground == nil or renderBackground.enabled then
				setBackground(true, val)
			end
		end,
		sub = true
	})
	customColor = targetInfoOverlay:toggle('Custom Color', {
		changed = function(callback)
			bkgColor.row.Visible = callback
			holder.BackgroundColor3 = callback and Color3.fromHSV(bkgColor.hue, bkgColor.sat, bkgColor.value) or CARD.Window
		end
	})
	bkgColor = targetInfoOverlay:color('Color', {
		value = 0.06,
		sat = 0,
		changed = function(hue, sat, val)
			if customColor.enabled then
				holder.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
			end
		end,
		sub = true,
		visible = false
	})
	border = targetInfoOverlay:toggle('Border', {
		default = true,
		changed = function(callback)
			stroke.Enabled = callback and backgroundOn
			if borderColor then
				borderColor.row.Visible = callback
			end
		end
	})
	borderColor = targetInfoOverlay:color('Border Color', {
		hue = 0,
		sat = 0,
		value = 1,
		opacity = 0.1,
		changed = function(hue, sat, val, opacity)
			stroke.Color = Color3.fromHSV(hue, sat, val)
			look.Border = 1 - opacity
			paint()
		end,
		sub = true,
		visible = border.enabled
	})

	function targetinfo:Update()
		if not slinky.libraries then return end

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

		local clock = os.clock()
		if clock - anim.Clock > 1 then
			anim.Away = false
			anim.Show = 0
			anim.MyHealth = nil
			anim.Hurt = 0
		end
		local dt = math.min(clock - anim.Clock, 0.1)
		anim.Clock = clock
		local moved = false
		local follow
		if entity and followTarget and followTarget.enabled and not clickgui.Visible then
			local root = entity.RootPart
			local camera = workspace.CurrentCamera
			follow = false
			local alive = (entity.Health or 0) > 0 and entity.Character ~= nil and entity.Character.Parent ~= nil
			if alive and root and root.Parent and camera then
				local head = entity.Head
				local headPosition = head and head.Parent and head.Position or root.Position + Vector3.new(0, (entity.HipHeight or 2) + 1.5, 0)
				local shoulder = headPosition + camera.CFrame.RightVector * 2.2
				local project = (slinky.gui and slinky.gui.IgnoreGuiInset) and camera.WorldToViewportPoint or camera.WorldToScreenPoint
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
		local character = localPlayer.Character
		if anim.Character ~= character then
			anim.Character = character
			anim.Humanoid = character and character:FindFirstChildOfClass('Humanoid')
			anim.MyHealth = nil
		end
		local myHealth = anim.Humanoid and anim.Humanoid.Parent and anim.Humanoid.Health
		if myHealth then
			if anim.MyHealth and myHealth < anim.MyHealth - 0.01 and damageTint and damageTint.enabled then
				anim.Hurt = 1
				moved = true
			end
			anim.MyHealth = myHealth
		elseif character then
			anim.Character = nil
		end
		if anim.Hurt > 0 then
			anim.Hurt = math.max(anim.Hurt - dt / HURT_TIME, 0)
			moved = true
		end
		local visible = anim.Show > 0
		if holder.Visible ~= visible then
			holder.Visible = visible
		end
		if moved then
			paint()
		end
		stepHealthCount(dt)
		local fillShown = fill.Size.X.Scale > 0.01
		if fill.Visible ~= fillShown then
			fill.Visible = fillShown
		end
		local position = ORIGIN
		local parent = holder.Parent
		local size = holder.AbsoluteSize
		if follow == false or (follow == nil and wanted == 0 and anim.Away and anim.Show > 0) then
			position = holder.Position
		elseif follow and parent and size.X > 0 then
			anim.Away = true
			local s = size.X / WIDTH
			local screen = slinky.gui and slinky.gui.AbsoluteSize or Vector2.new(1920, 1080)
			local x = math.clamp(follow.X + 10 * s, 0, math.max(screen.X - size.X, 0))
			local below = 0
			local inventory = holder:FindFirstChild('Inventory')
			if inventory and inventory:IsA('GuiObject') and inventory.Visible then
				below = math.max(inventory.AbsolutePosition.Y + inventory.AbsoluteSize.Y - (holder.AbsolutePosition.Y + size.Y), 0)
			end
			local y = math.clamp(follow.Y - size.Y / 2, 0, math.max(screen.Y - size.Y - below, 0))
			local base = parent.AbsolutePosition - (scaledgui and scaledgui.AbsolutePosition or Vector2.zero)
			position = UDim2.fromOffset(math.floor((x - base.X) / s + 0.5), math.floor((y - base.Y) / s + 0.5))
		end
		if position == ORIGIN then
			anim.Away = false
		end
		if holder.Position ~= position then
			holder.Position = position
		end
		if entity then
			local hideName = shared.PistonwareHideName
			local shown = entity.Player and (displayName.enabled and entity.Player.DisplayName or entity.Player.Name) or entity.Character and entity.Character.Name or title.Text
			if type(hideName) == 'function' then
				local ok, res = pcall(hideName, shown)
				if ok and type(res) == 'string' then shown = res end
			end
			if title.Text ~= shown then
				title.Text = shown
			end

			local thumb = 'rbxthumb://type=AvatarHeadShot&id='..(entity.Player and entity.Player.UserId or 1)..'&w=150&h=150'
			local hideThumb = shared.PistonwareHideThumb
			if type(hideThumb) == 'function' then
				local ok, res = pcall(hideThumb, thumb)
				if ok and type(res) == 'string' then thumb = res end
			end
			if headshot.Image ~= thumb then
				headshot.Image = thumb
			end

			if not entity.Character then
				entity.Health = entity.Health or 0
				entity.MaxHealth = entity.MaxHealth or 100
			end

			local root = entity.RootPart
			local camera = workspace.CurrentCamera
			local me = camera and camera.CameraSubject
			me = me and (me:IsA('Humanoid') and me.RootPart or me:IsA('BasePart') and me) or nil
			local distance = (root and root.Parent and me) and math.floor((root.Position - me.Position).Magnitude + 0.5)..'m' or ''
			if distanceLabel.Text ~= distance then
				distanceLabel.Text = distance
				fitTitle(distance)
			end

			if entity.Health ~= self.Health or entity.MaxHealth ~= self.MaxHealth then
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

	slinky.libraries.targetinfo = targetinfo
end


--[[ Starts the menu's running parts: the rainbow colour thread, the menu's own pointer, the menu's
Visible handler, the rescale on resize and rotation, the key bind input handlers and the release of
every hold on focus loss.

The rainbow thread idles at 4 Hz while no slider is on rainbow, and hue is not advanced while
parked, so switching rainbow on carries on where it stopped. Each slider is stepped under pcall; one
with nothing left to call is dropped after the pass.

Handlers that run inside a property write (the menu's Visible, the camera's ViewportSize, the
scale's Scale, CurrentCamera) only ask for their work, which runs once at the end of the frame:
anything they wrote would be a write nested in the one that fired them. Opening the menu repaints it
only when a colour pass was skipped while it was shut or something was added since
(layout.ColorDirty). On a phone the camera's ViewportSize is what changes; a ScreenGui's
AbsoluteSize is (0, 0) until it first renders.

The menu draws its own pointer only while the menu or a window is up and Roblox's pointer is hidden;
the step stops itself once Roblox's shows.

A number key pistonware pressed itself (shared.PistonwareSyntheticKeys, marked until just after its
release) fires no bind and is never held. Pressing the keys a waiting badge is already bound to
clears the bind; checkKeybinds needs every key of the bind held, so a single key never clears a
combo, and the badge capture lets go of the holds it would strand. A hold's key released while a
text box has focus still ends the hold. Losing window focus (alt-tab) can lose key releases, so it
ends every hold; not every client has that signal, so it is looked up under pcall. applyAutoScale
also runs once at the end, since the window's first resize comes before slinky.scale exists. ]]
function build.loops()
	slinky:clean(task.spawn(function()
		local hue = 0
		repeat
			if #slinky.rainbowSliders == 0 then
				task.wait(0.25)
				continue
			end

			local stale
			for _, component in slinky.rainbowSliders do
				if type(component.set) ~= 'function' then
					stale = stale or {}
					table.insert(stale, component)
				elseif component.kind == 'guiSlider' then
					pcall(component.set, component, slinky:colorAt(hue))
				else
					pcall(component.set, component, hue)
				end
			end
			if stale then
				for _, component in stale do
					removeRainbowSlider(component)
				end
			end

			local delta = task.wait(1 / slinky.rainbowUpdateSpeed.value)
			hue = (hue + (delta * (0.2 * slinky.rainbowSpeed.value))) % 1
		until false
	end))

	local cursorConnection
	local colorPassQueued = false
	local cursorShown, cursorX, cursorY = false, nil, nil
	local function cursorWake()
		if cursorConnection then return end
		cursorConnection = runService.RenderStepped:Connect(function()
			local isVisible = clickgui.Visible
			for _, window in slinky.windows do
				isVisible = isVisible or window.Visible
			end

			if not isVisible or inputService.MouseIconEnabled then
				if cursorShown then
					cursorShown = false
					slinky.cursor.Visible = false
				end
				cursorConnection:Disconnect()
				cursorConnection = nil
				return
			end

			if not cursorShown then
				cursorShown = true
				slinky.cursor.Visible = true
			end
			local mouseLocation = inputService:GetMouseLocation()
			if mouseLocation.X ~= cursorX or mouseLocation.Y ~= cursorY then
				cursorX, cursorY = mouseLocation.X, mouseLocation.Y
				slinky.cursor.Position = UDim2.fromOffset(cursorX - 31, cursorY - 32)
			end
		end)
	end
	slinky:clean(clickgui:GetPropertyChangedSignal('Visible'):Connect(function()
		slinky.menuOpen = clickgui.Visible
		if not clickgui.Visible then
			slinky.currentTooltip = nil
			if slinky.binding then
				local stale = slinky.binding
				slinky.binding = nil
				task.defer(function()
					if slinky.loaded == nil or slinky.binding == stale then return end
					if slinky.threadFix then
						setthreadidentity(8)
					end
					pcall(function() stale:set(stale.keys, true) end)
				end)
			end
		end

		if not colorPassQueued then
			colorPassQueued = true
			task.defer(function()
				colorPassQueued = false
				if slinky.loaded == nil then return end
				if slinky.threadFix then
					setthreadidentity(8)
				end
				if clickgui.Visible and (not layout or layout.ColorDirty ~= false) then
					slinky:recolor(slinky.accent.hue, slinky.accent.sat, slinky.accent.value, true)
				elseif textGUI and textGUI.switch and textGUI.switch.enabled then
					textGUI:updateColor(slinky.accent.hue, slinky.accent.sat, slinky.accent.value, true)
				end
			end)
		end

		if clickgui.Visible and inputService.MouseEnabled and not inputService.MouseIconEnabled then
			cursorWake()
		end
	end))
	slinky:clean(inputService:GetPropertyChangedSignal('MouseIconEnabled'):Connect(function()
		if clickgui.Visible and inputService.MouseEnabled and not inputService.MouseIconEnabled then
			cursorWake()
		end
	end))

	slinky:clean(function()
		if cursorConnection then
			cursorConnection:Disconnect()
		end
	end)

	local function applyAutoScale()
		if slinky.scale and slinky.scale.enabled then
			scale.Scale = autoScaleValue()
		end
		local main = slinky.categories.Main
		if main and main.resize then
			main.resize()
		end
		ui.applyHudZoom()
		ui.clampAllHud()
	end

	local autoScaleQueued, viewportConnection = false, nil
	local function queueAutoScale()
		if autoScaleQueued then return end
		autoScaleQueued = true
		task.defer(function()
			autoScaleQueued = false
			if slinky.loaded == nil then return end
			if slinky.threadFix then
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
	slinky:clean(function()
		if viewportConnection then
			viewportConnection:Disconnect()
			viewportConnection = nil
		end
	end)
	slinky:clean(workspace:GetPropertyChangedSignal('CurrentCamera'):Connect(function()
		gameCamera = workspace.CurrentCamera
		watchCamera()
		queueAutoScale()
	end))
	slinky:clean(gui:GetPropertyChangedSignal('AbsoluteSize'):Connect(queueAutoScale))

	slinky:clean(notifications.ChildRemoved:Connect(function()
		ui.restackNotifications()
	end))

	local scaleFollowQueued = false
	slinky:clean(scale:GetPropertyChangedSignal('Scale'):Connect(function()
		scaledgui.Size = UDim2.fromScale(1 / scale.Scale, 1 / scale.Scale)
		if scaleFollowQueued then return end
		scaleFollowQueued = true
		task.defer(function()
			scaleFollowQueued = false
			if slinky.loaded == nil then return end
			if slinky.threadFix then
				setthreadidentity(8)
			end
			local main = slinky.categories.Main
			if main and main.resize then
				main.resize()
			end
			ui.applyHudZoom()
			if slinky.loaded and slinky.updateOverlay then
				pcall(slinky.updateOverlay, slinky)
			end
		end)
	end))

	slinky:clean(slinky.menuBind.triggered:Connect(function()
		if slinky.threadFix then
			setthreadidentity(8)
		end
		if layout.MovingHud and layout.StopMovingHud then
			layout.StopMovingHud()
			return
		end
	
		for _, window in slinky.windows do
			window.Visible = false
		end
	
		for _, module in orderedModules(slinky.moduleOrder) do
			if module.bind.mobile then
				module.bind.mobile.Visible = clickgui.Visible
			end
		end
	
		clickgui.Visible = not clickgui.Visible
		slinky:blurCheck()
	end))
	
	slinky:clean(inputService.InputBegan:Connect(function(input)
		if slinky.currentTooltip and input.KeyCode == Enum.KeyCode.LeftShift then
			slinky.currentTooltip()
		end
	
		if not inputService:GetFocusedTextBox() and input.KeyCode ~= Enum.KeyCode.Unknown then
			local synthetic = shared.PistonwareSyntheticKeys
			if type(synthetic) == 'table' and (tonumber(synthetic[input.KeyCode]) or 0) > os.clock() then return end
			table.insert(slinky.heldKeybinds, input.KeyCode.Name)
			if slinky.binding then return end
	
			for _, bind in slinky.activeBinds do
				if checkKeybinds(slinky.heldKeybinds, bind.keys, input.KeyCode.Name) then
					bind.triggered:Fire(true)
				end
			end
		end
	end))
	
	slinky:clean(inputService.InputEnded:Connect(function(input)
		if slinky.currentTooltip and input.KeyCode == Enum.KeyCode.LeftShift then
			slinky.currentTooltip()
		end
	
		if not inputService:GetFocusedTextBox() and input.KeyCode ~= Enum.KeyCode.Unknown then
			local synthetic = shared.PistonwareSyntheticKeys
			if type(synthetic) == 'table' and (tonumber(synthetic[input.KeyCode]) or 0) > os.clock() then return end
			if slinky.binding then
				local stranded = {}
				local replaced = input.KeyCode == Enum.KeyCode.Escape or not slinky.multiKeybind.enabled
				for _, bind in slinky.activeBinds do
					if bind.hold and #bind.keys > 0 and checkKeybinds(slinky.heldKeybinds, bind.keys, replaced and bind.keys[1] or input.KeyCode.Name) then
						table.insert(stranded, bind)
					end
				end
				if not slinky.multiKeybind.enabled then
					slinky.heldKeybinds = {input.KeyCode.Name}
				end

				local binding = slinky.binding
				slinky.binding = nil
				if input.KeyCode == Enum.KeyCode.Escape then
					slinky.heldKeybinds = {}
					binding:set({}, true)
					for _, held in stranded do
						held.triggered:Fire(false)
					end
					return
				end
				local sameAsCurrent = checkKeybinds(slinky.heldKeybinds, binding.keys, input.KeyCode.Name)
				binding:set(sameAsCurrent and {} or slinky.heldKeybinds, true)
				for _, held in stranded do
					held.triggered:Fire(false)
				end
			else
				for _, bind in slinky.activeBinds do
					if bind.hold and checkKeybinds(slinky.heldKeybinds, bind.keys, input.KeyCode.Name) then
						bind.triggered:Fire(false)
					end
				end
			end
		elseif input.KeyCode ~= Enum.KeyCode.Unknown then
			local synthetic = shared.PistonwareSyntheticKeys
			if type(synthetic) == 'table' and (tonumber(synthetic[input.KeyCode]) or 0) > os.clock() then return end
			for _, bind in slinky.activeBinds do
				if bind.hold and checkKeybinds(slinky.heldKeybinds, bind.keys, input.KeyCode.Name) then
					bind.triggered:Fire(false)
				end
			end
		end
	
		local index = table.find(slinky.heldKeybinds, input.KeyCode.Name)
		if index then
			table.remove(slinky.heldKeybinds, index)
		end
	end))

	do
		local ok, connection = pcall(function()
			return inputService.WindowFocusReleased:Connect(function()
				for _, bind in slinky.activeBinds do
					if bind.hold and #bind.keys > 0 and checkKeybinds(slinky.heldKeybinds, bind.keys, bind.keys[1]) then
						bind.triggered:Fire(false)
					end
				end
				table.clear(slinky.heldKeybinds)
			end)
		end)
		if ok and connection then
			slinky:clean(connection)
		end
	end

	applyAutoScale()
end

--[[ Builds the whole menu in order. Profiles an older build left behind are converted before anything
reads a saved file; if that throws, how far it got is unknown, so no profile without a file is given
one until the script is loaded again. The phone's menu button goes up as soon as there is a menu to
open, without waiting for the profile (see slinky:ensureMenuButton). ]]
function slinky:build()
	if not pcall(store.convert) then
		store.converted = {count = 0, settings = false, failed = {'your old profiles'}, partial = {}, renamed = {}}
		store.unconverted['*'] = true
	end

	build.root()
	build.categories()
	build.lists()
	build.settings()
	build.modOverlay()
	build.targetInfo()
	build.keyFooter()
	build.loops()

	self:ensureMenuButton()
end

--[[ Takes a module, legit module or category out of the menu. It is switched off quietly first, so its
own shutdown runs and disconnects what it connected, and its rainbow sliders stop. The save order is
kept in step: the lobby strips every Combat and Minigames module on entry, and a stale entry would
have slinky:save call save on a destroyed component. ]]
function slinky:remove(obj)
	local container = (self.modules[obj] and self.modules or self.legit.modules[obj] and self.legit.modules or self.categories)
	if container and container[obj] then
		local component = container[obj]
		local isModule = component.kind == 'module'
		if self.threadFix then
			setthreadidentity(8)
		end

		if component.enabled and type(component.flip) == 'function' then
			if isModule then
				pcall(component.flip, component, nil, true)
			elseif component.kind == 'legitModule' then
				pcall(component.flip, component)
			end
		end
		if type(component.options) == 'table' then
			for _, option in component.options do
				removeRainbowSlider(option)
			end
		end

		if component.Destroy then
			component:Destroy()
		end

		for _, child in {'row', 'frame', 'flip', 'switch'} do
			child = typeof(component[child]) == 'table' and component[child].row or component[child]

			if typeof(child) == 'Instance' then
				child:Destroy()
				child:ClearAllChildren()
			end
		end

		loopClean(component)
		container[obj] = nil

		local order = container == self.legit.modules and self.legit.order or self.moduleOrder
		if order then
			local index = table.find(order, component)
			if index then
				table.remove(order, index)
			end
		end

		if isModule then
			self.moduleCount = math.max((self.moduleCount or 1) - 1, 0)
			self:sortCategories()
		end
	end
end

function slinky:canSave()
	return self.loaded
		and not self.applying
		and not self.saveBlocked
		and not shared.PistonwareBootFailed
end

function slinky:blockSaving()
	self.saveBlocked = true
	self.saveNeeded = nil
	self.saveQueued = nil
	self.saveDeadline = nil
	self.saveEpoch = (self.saveEpoch or 0) + 1
	return false
end

function slinky:allowSaving()
	if shared.PistonwareBootFailed then return self:blockSaving() end
	self.saveBlocked = nil
	if self.pendingProfileCreate and self:canSave() then
		self.pendingProfileCreate = nil
		self:requestSave()
	end
	return true
end

--[[ Writes the settings file, naming newProfile (or the current profile) as the one in use, and the
current profile's file. Both are gathered and encoded before either is written. A failure is
reported once until a save succeeds, and what each file holds after a successful write is what the
next save merges into. ]]
function slinky:save(newProfile)
	if not self:canSave() then return false end

	if self.threadFix then
		setthreadidentity(8)
	end

	local profile, settings, profileText, settingsText
	local success, err = pcall(function()
		profile, settings = store.gather(newProfile or self.profile)
		profileText = store.profileText(profile)
		settingsText = store.settingsText(settings)
	end)

	if not success then
		if not self.saveFailed then
			self.saveFailed = true
			self:notify('Pistonware', 'Failed to save your config, '..tostring(err), 10, 'alert')
		end

		return false
	end

	local settingsSuccess, settingsError = pcall(writefile, store.settingsPath, settingsText)
	local profileSuccess, profileError = pcall(writefile, store.path(self.profile), profileText)

	if settingsSuccess then
		store.settings = settings
	end
	if profileSuccess then
		store.profile = profile
	end

	if settingsSuccess and profileSuccess then
		self.saveFailed = nil
		return true
	elseif not self.saveFailed then
		self.saveFailed = true
		self:notify('Pistonware', 'Failed to save your config, '..tostring(settingsError or profileError), 10, 'alert')
	end
	return false
end

--[[ Asks for a save, coalesced: each request pushes the write 0.4 s on, but never later than 2 s after
the first request of a burst, since a slider drag or typing sends a stream of them. While a normal
boot is still loading the request is kept (saveNeeded) for slinky:flushSave to write when main.lua
opens saving; after a failed boot nothing is written, so it is dropped. slinky:blockSaving cancels a
queued write through saveEpoch. ]]
function slinky:requestSave()
	if not self:canSave() then
		if not shared.PistonwareBootFailed then
			self.saveNeeded = true
		end
		return false
	end

	local now = os.clock()
	self.saveTime = now + 0.4

	if self.saveQueued then
		return true
	end

	local epoch = self.saveEpoch or 0
	self.saveQueued = epoch
	self.saveDeadline = now + 2

	local function flush()
		if self.saveQueued ~= epoch or self.saveEpoch ~= epoch then return end
		if slinky.threadFix then
			setthreadidentity(8)
		end

		local remaining = math.min(self.saveTime, self.saveDeadline or math.huge) - os.clock()
		if remaining > 0 then
			task.delay(remaining, flush)
			return
		end

		self.saveQueued = nil
		self.saveDeadline = nil
		self.saveNeeded = nil

		if self:canSave() then
			self:save()
		end
	end

	task.delay(0.4, flush)
	return true
end

-- Called by main.lua the instant saving becomes safe, so a toggle made while the payload was
-- still loading is written then rather than waiting for a backstop tick.
function slinky:flushSave()
	if not self:canSave() then return false end
	if not self.saveNeeded then return false end

	self.saveNeeded = nil
	return self:requestSave()
end

--[[ The options of an object as its entry holds them: one key per option that saves anything. A value
the file held that the option could not take is saved as the file had it, until the option changes.
]]
function slinky:saveOptions(obj)
	local entry = {}
	local keys = store.optionKeys(obj.options)
	for name, option in obj.options do
		if keys[name] and type(option) == 'table' and type(option.save) == 'function' then
			local value = option:save()
			local kept = store.kept[option]
			if kept then
				if store.same(value, kept.shown) then
					value = kept.saved
				else
					store.kept[option] = nil
				end
			end
			entry[keys[name]] = value
		end
	end

	return entry
end

--[[
	Reassigns every module's LayoutOrder alphabetically within its category.

	The order has to be a property of the whole set, not of insertion: a module dropdown is
	positioned from its LayoutOrder, so a category whose orders are stale puts a module's
	settings panel above the module instead of below it.

	Lifted out of module creation so removal can call it too. slinky:Remove used to leave the
	surviving modules holding the indexes they had when the removed one was still there.
]]
--[[
	The public form of orderedModules, for game scripts.

	Anything outside this file that walks slinky.Modules with pairs has the same hazard the GUI
	just had -- Panic, the chat 'toggle all' command and AutoConfig all iterate every module, and
	all three can be triggered while a payload is still registering. `for name, module in
	slinky:EachModule() do` is a drop-in replacement for `for name, module in slinky.Modules do`.
]]
function slinky:eachModule()
	return orderedModules(self.moduleOrder)
end

function slinky:eachLegitModule()
	return orderedModules(self.legit and self.legit.order)
end

--[[ Numbers each category's modules alphabetically into module.index, their rainbow offset; the cards
themselves are ordered by the tab layout. A module the order still names can be gone if a removal
lands between the request and this pass. It lays nothing out: cards are placed by name, and
layout.add and layout.remove ask for their own tabs. ]]
local function sortCategoriesNow(self)
	local sorting = {}
	for _, module in orderedModules(self.moduleOrder) do
		sorting[module.category] = sorting[module.category] or {}
		table.insert(sorting[module.category], module.name)
	end

	for _, sort in sorting do
		table.sort(sort)
		for index, name in sort do
			local module = self.modules[name]
			if module then
				module.index = index
			end
		end
	end
end

--[[ Asks for one sortCategoriesNow at the next defer. Every module registration ends with a sort, and a
pass walks every module registered so far, which is quadratic over a payload of several hundred
modules in the slowest part of the load. Nothing reads the result before a frame is drawn, so one
deferred pass gives what the last call of the burst would have. It runs under pcall: an uninject's
loopClean can strip slinky to an empty table before the pass runs. ]]
function slinky:sortCategories()
	if self.sortQueued then return end
	self.sortQueued = true

	task.defer(function()
		self.sortQueued = nil
		pcall(sortCategoriesNow, self)
	end)
end

--[[ Saves, blocks further saves and takes the GUI down. The on-screen buttons go first, so a finger
still down on a hold bind's button lets go as lifting it would. Every module, legit module and
overlay is then switched off, open dropdowns are closed (each watches every press with a connection
of its own) and the connections are cleaned. The mobile blur is cleared unconditionally: blurCheck
runs only with threadFix, and the executors without it are the mobile ones that use the BlurEffect.
The holder folder in CoreGui is destroyed too, or a queued teleport that re-injects on each server
would leave one per hop. ]]
function slinky:unload()
	if self:canSave() then self:save() end
	self:blockSaving()
	self.loaded = nil

	for _, module in orderedModules(self.moduleOrder) do
		if module.bind and module.bind.mobile then
			pcall(module.bind.destroyMobileButton, module.bind)
		end
	end

	for _, module in orderedModules(self.moduleOrder) do
		if module.enabled then
			module:flip()
		end
	end

	for _, module in orderedModules(self.legit.order) do
		if module.enabled then
			module:flip()
		end
	end

	for _, category in self.categories do
		if category.kind == 'overlay' and category.switch.enabled then
			category.switch:flip()
		end
	end

	if layout and layout.OpenLists then
		for close in table.clone(layout.OpenLists) do
			pcall(close)
		end
	end

	for _, connection in self.connections do
		cleanupConnection(connection)
	end

	if self.threadFix then
		setthreadidentity(8)
		clickgui.Visible = false
		self:blurCheck()
	end

	setMobileBlur(false)

	gui:ClearAllChildren()
	gui:Destroy()
	if self.holder and self.holder ~= gui then
		pcall(function() self.holder:Destroy() end)
	end
	self.holder = nil
	table.clear(self.connections)
	table.clear(self.libraries)
	loopClean(self)

	shared.slinky = nil
	shared.slinkyreload = nil
	shared.SlinkyIndependent = nil
end

--[[ Repaints the menu in an accent colour. While rainbow is on only a default call gets through. The Mod
Overlay is repainted whenever it is on; the rest only with the menu open, and with it shut
layout.ColorDirty is set so the menu's Visible handler in build.loops paints it when it opens. A
bind badge is repainted only while bound or waiting for a key: NONE looks the same in every theme.
]]
function slinky:recolor(hue, sat, val, default)
	if slinky.loaded == nil then return end
	if not default and slinky.accent.rainbow then return end

	if textGUI and textGUI.switch and textGUI.switch.enabled then
		textGUI:updateColor(hue, sat, val, default)
	end

	if not clickgui or not clickgui.Visible then
		if layout then
			layout.ColorDirty = true
		end
		return
	end
	local isRainbow = slinky.accent.rainbow and slinky.rainbowMode ~= nil and slinky.rainbowMode.value ~= 'Retro'

	if slinky.recolorProfileCards then
		slinky.recolorProfileCards()
	end

	for name, component in slinky.categories do
		component:recolor(hue, sat, val, isRainbow)
	end

	if layout and layout.Binds then
		for bind in layout.Binds do
			if bind.repaint and (bind.binding or (bind.keys and #bind.keys > 0)) then
				bind:repaint()
			end
		end
	end

	for _, component in orderedModules(slinky.moduleOrder) do
		component:recolor(hue, sat, val, isRainbow)
	end

	if slinky.overlays then
		for _, component in slinky.overlays.options do
			if component.recolor then
				component:recolor(hue, sat, val, isRainbow)
			end
		end
	end

	for _, pane in slinky.settings do
		for _, component in pane.options do
			if component.recolor then
				component:recolor(hue, sat, val, isRainbow)
			end
		end
	end

	if slinky.legit then
		for _, component in orderedModules(slinky.legit.order) do
			component:recolor(hue, sat, val, isRainbow)
		end
	end

	if layout then
		layout.ColorDirty = false
	end
end

--[[
	Framework objects.

	Everything the library hands out -- the root, a category, a module, an option, a key bind -- is a
	plain table, and each one passes through `object` when its constructor has finished it. In a
	normal run that changes nothing: the same table comes back, with no metatable.

	In developer mode (shared.PistonwareDeveloper) the table is watched: reading or writing a key the
	object does not have is reported, with the object, the key and the line that did it. That is how
	an old `module.Enabled`, a member that was renamed or a typo shows up, instead of quietly being
	nil. Only keys that are absent reach __index and __newindex, so the members an object has cost
	nothing, and the code that made the mistake runs as it would have: the read gives nil, the write
	lands. One report per key and line.

	Not every absent key is a mistake. ABSENT lists, by kind, the members an object has only some of
	the time (a module's bind until it is given one, a list's selected row) and the fields other code
	keeps on it (the game files put targetPriority and connection on their modules); `any` is what
	shared code asks of whatever it is handed. A key the object had when it was finished, or that has
	been written since, is its own from then on. A table that already has a metatable is left as it
	is: the options tables (the settings panes' proxy, a card's watched options) and the components
	table map names to entries, and a name that is not there is an ordinary answer.
]]
local object
--[[ object(members, name, kind) finishes a component table. In a normal run it returns the table as it
is. In a developer run (shared.PistonwareDeveloper) it watches the table, and reading or writing a
string key the object did not have when built is reported once per key and place, through the
loader's buffer (getgenv().pistonware.buffer) or warn without one. ABSENT lists per kind the keys
that are asked for or set later, by the library, main.lua or the game files, and are never reported.
A table that already has a metatable is returned unwatched. ]]
if shared.PistonwareDeveloper ~= true then
	function object(members)
		return members
	end
else
	local ABSENT = {
		any = 'Disconnect disconnect Destroy Remove DoCleaning recolor save load transient',
		root = 'applying binding blur currentTooltip cursor downloader editing gui guiscale hideMenuButton holder init legit'
			..' menuBind menuButton menuButtonFace menuButtonStroke menuButtonTransparency menuOpen multiKeybind notifications'
			..' overlays pendingProfileCreate placeMenuButton profileLabel rainbowMode rainbowSpeed rainbowUpdateSpeed recolorProfileCards'
			..' saveDeadline saveFailed saveNeeded saveQueued saveTime scale searchBar sortQueued teleportHooked',
		categoryWindow = 'enabled flip frame options',
		categoryList = 'enabled flip frame cardActions colorUpdate extras grid headerRow importFlags quarantineButton'
			..' selected selectedBadge selectedStroke selectedTitle showQuarantine update view',
		gui = 'enabled flip frame switch options',
		overlay = 'enabled flip bind hudSlot updateColor',
		settingsPane = 'enabled',
		module = 'bind edit frame info startToken switch targetPriority autoWinAware autoWinClimb connection',
		legitModule = 'category frame hudSlot startToken switch visible',
		keybind = 'binding mobile',
		toggle = 'bind',
		targets = 'milo',
		font = 'kind'
	}

	local quiet = {}
	local function quietFor(kind)
		local set = quiet[kind]
		if not set then
			set = {}
			for key in (ABSENT.any..' '..(ABSENT[kind] or '')):gmatch('%S+') do
				set[key] = true
			end
			quiet[kind] = set
		end
		return set
	end

	local buffer
	pcall(function()
		local namespace = getgenv().pistonware
		buffer = type(namespace) == 'table' and namespace.buffer or nil
	end)
	local reported = {}
	local info = type(debug) == 'table' and debug.info
	local function report(kind, name, access, key, level)
		local source, line
		if info then
			source, line = info(level + 1, 'sl')
		end
		local where = tostring(source or '?')..':'..tostring(line or 0)
		local id = tostring(key)..'\0'..where
		if reported[id] then return end
		reported[id] = true
		local message = string.format('%s %s: %s of the key %q, which it does not have (%s)', tostring(kind), tostring(name),
			access, tostring(key), where)
		if type(buffer) == 'table' and type(buffer.error) == 'function' then
			pcall(buffer.error, 'object.key', message, {kind = kind, name = name, access = access, key = key, source = source, line = line})
		else
			warn('[pistonware] '..message)
		end
	end

	local function watch(members, kind, name)
		local known = quietFor(kind)
		local own = {}
		for key in members do
			own[key] = true
		end
		return setmetatable(members, {
			__index = function(_, key)
				if type(key) == 'string' and not own[key] and not known[key] then
					report(kind, name, 'read', key, 2)
				end
				return nil
			end,
			__newindex = function(self, key, value)
				if type(key) == 'string' and not own[key] then
					own[key] = true
					if not known[key] then
						report(kind, name, 'write', key, 2)
					end
				end
				rawset(self, key, value)
			end
		})
	end

	function object(members, name, kind)
		if getmetatable(members) ~= nil then
			return members
		end
		return watch(members, kind or rawget(members, 'kind') or 'object', name or rawget(members, 'name') or '?')
	end
end

--[[ Every container (category, module, legit module, overlay, window) binds the whole
components table into its own frame, and each container uses a different frame. Recorded here
so a component registered later -- slinky.components.x = f, which games do for their own
option types -- can be bound into the same frame instead of guessing at it. Weak keys: a removed
container takes its entry with it. ]]
local componentChildren = setmetatable({}, {__mode = 'k'})

--[[ What a container calls to make a component inside itself: container:toggle('Name', {...}).
Every component is bound the same way, under its key in the components table. What the new thing
saves as it comes out of here is its default, which a profile never holds (store.built). ]]
local function creator(create, children, container)
	return function(_, name, props)
		if layout then
			layout.ColorDirty = true
		end
		return store.built(create(declared(name, props), children, container))
	end
end

local function bindComponents(container, children)
	componentChildren[container] = children

	for key, create in components do
		container[key] = creator(create, children, container)
	end
end

--[[
	Tabs and the card layout.

	The menu is one window: a tab bar and, under it, a page per tab holding two (three with
	Layout > Wide) independent columns of cards. Which tab a module lands in is its own `Tab`
	setting when it gives one, and otherwise follows the category it registered in -- the
	categories themselves are unchanged, because game files and the lobby's own filters still talk
	to them by name.

	Cards are placed by one deferred pass per frame, not as they arrive: a payload registers
	hundreds of modules in a burst, and placing each one as it came would re-sort the tab every
	time. Sorted alphabetically by the name the card shows, dealt round-robin across the columns, so
	an expanded card only ever pushes its own column down.
]]
TABS = {'Combat', 'Move', 'Visual', 'Utility', 'Kits', 'FFlags'}
local TAB_OF_CATEGORY = {
	Combat = 'Combat', Blatant = 'Move', Render = 'Visual', World = 'Utility',
	Utility = 'Utility', Inventory = 'Utility', Minigames = 'Kits', Legit = 'Visual', Overlay = 'Visual'
}
--[[ The menu's layout state: the card entries, the tab pages and which tabs need placing again, the
search text, the column count, the GUI card's Wide and Compact layout choices, and weak sets of
cards, bind badges and lists that scroll by themselves. ColorDirty marks a colour pass skipped with
the menu shut (see build.loops); RecentColors is the colour pickers' shared 'Recently used' row,
newest first. ]]
layout = {
	ColorDirty = true,
	Entries = {},
	Pages = {},
	Dirty = {},
	Search = '',
	Columns = 2,
	Wide = false,
	Compact = false,
	CardViews = setmetatable({}, {__mode = 'k'}),
	Binds = setmetatable({}, {__mode = 'k'}),
	RecentColors = {},
	InnerLists = setmetatable({}, {__mode = 'k'}),
	TabShown = {}
}

--[[ Returns the tab a card goes in: the tab its props name when that tab exists, otherwise the one its
category maps to, or Utility. 'Block' is read as Utility, where the current Slinky keeps those
modules. ]]
function layout.tabOf(props, category)
	local tab = props.tab == 'Block' and 'Utility' or props.tab
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
	if layout.ViewOf then
		layout.ViewOf[card] = nil
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

--[[ Places a tab's visible cards in its columns, sorted by key and then name and dealt round-robin: one
column for FFlags, otherwise layout.Columns. While a search is typed only the Search page holds
cards. Cards that leave the page are parked in layout.Hidden. A card made before the last font pass
gets its title and badge laid out again (view:Refit), and the cards that moved are handed to a page
fade under way (ui.fade.placed). ]]
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
			or entry.Card.Parent == page.Mid or (not searching and entry.Tab == tab)) then
			entry.Card.Parent = layout.Hidden
		end
	end

	table.sort(list, function(a, b)
		if a.Key == b.Key then return a.Name < b.Name end
		return a.Key < b.Key
	end)

	local cols = columns >= 3 and {page.Left, page.Mid, page.Right}
		or columns == 2 and {page.Left, page.Right} or {page.Left}
	local n = #cols
	local moved = ui.fade.watched(page.Frame) and {} or nil
	for index, entry in list do
		local column = cols[(index - 1) % n + 1]
		local card = entry.Card
		local shifted = false
		if card.Parent ~= column then
			card.Parent = column
			shifted = true
		end
		if card.LayoutOrder ~= index then
			card.LayoutOrder = index
			shifted = true
		end
		if shifted and moved then
			local before, after = list[index - n], list[index + n]
			table.insert(moved, {card, before and before.Card, after and after.Card})
		end
		local view = layout.ViewOf and layout.ViewOf[entry.Card]
		if view and view.FitGen ~= fonts.Generation then
			view.FitGen = fonts.Generation
			pcall(view.Refit, view)
		end
	end

	for i, frame in cols do
		frame.Visible = true
		frame.Size = UDim2.new(1 / n, -theme.Gap * (n - 1) / n, 0, 0)
		frame.Position = UDim2.new((i - 1) / n, theme.Gap * (i - 1) / n, 0, 0)
	end
	page.Mid.Visible = n == 3
	page.Right.Visible = n >= 2
	if page.Empty then
		page.Empty.Visible = #list == 0
	end
	ui.fade.placed(page.Frame, moved)
end

--[[ Places every tab marked dirty, or only the Search page while a search is typed. With the menu shut
nothing is placed and the marks are kept: the menu's Visible watcher asks for this again as it
opens. The Kits tab is hidden while no card is in it, and in place 6872265039. ]]
function layout.flush()
	if slinky.threadFix then
		setthreadidentity(8)
	end
	if not (clickgui and not clickgui.Visible) then
		local dirty = layout.Dirty
		layout.Dirty = {}
		if layout.Search ~= '' then
			layout.place('Search')
			return
		end
		for _, tab in TABS do
			if dirty['*'] or dirty[tab] then
				layout.place(tab)
			end
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
		return Color3.fromHSV(slinky:colorAt(((hue or slinky.accent.hue) - ((index or 0) * (step or 0.075))) % 1))
	end
	return Color3.fromHSV(hue or slinky.accent.hue, sat or slinky.accent.sat, val or slinky.accent.value)
end

local function liveAccent(index, step)
	local isRainbow = slinky.accent.rainbow and slinky.rainbowMode ~= nil and slinky.rainbowMode.value ~= 'Retro'
	return accentFor(index, step, nil, nil, nil, isRainbow)
end

--[[ Drags along a track: calls back with the 0..1 position under the pointer until the press is
released. Only the press that started the drag moves it: a touch keeps one InputObject for its whole
life, and with input allowed while the menu is open a second finger on the thumbstick would move the
knob. ]]
local function trackDrag(input, track, onMove, onEnd)
	local isMouse = input.UserInputType == Enum.UserInputType.MouseButton1
	local last = math.clamp((input.Position.X - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1), 0, 1)
	onMove(last)
	local releaseConnection
	local moveConnection = inputService.InputChanged:Connect(function(newInput)
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

--[[ A title with badges after it in its row (ui.card, the profile cards). The row's list puts the
badge 5 px after the title's drawn text, Slinky's gap whatever the title's length. A title too long
for the row gives way -- shrunk by the list, cut with an ellipsis -- rather than push its badges on,
and the row clips, so nothing in it ever passes the row's end: 8 px short of the switch, 7 short of
the profile icons. All of it the engine's, set once here: nothing measured, nothing to keep up. ]]
function ui.fitTitle(row, label)
	label.TextTruncate = Enum.TextTruncate.AtEnd
	pcall(function()
		local flex = Instance.new('UIFlexItem')
		flex.FlexMode = Enum.UIFlexMode.Shrink
		flex.Parent = label
	end)
	row.ClipsDescendants = true
end

--[[ Developer builds: how the titles on screen fit their boxes, added to the font log once a font
pass (fonts.Generation), a second after the menu opens -- for a machine we cannot see, where a title
measured in a fallback face kept a box narrower than its text and ran into its badge. Listed: a title
the engine says does not fit (cut with an ellipsis: a long one on purpose, or one sized in an older
face), and one whose text width matches its box neither in units nor in pixels, as whether TextBounds
counts the window's zoom is not known yet. Each line gives the text width, the box in units and in
pixels, and how far after the text's end the badge starts, read both ways (units/pixels). ]]
function layout.CheckFits()
	if not (shared.PistonwareDeveloper and writefile and readfile) or layout.FitsLogged == (fonts.Generation or 0) then return end
	layout.FitsLogged = fonts.Generation or 0
	task.delay(1, function()
		if slinky.loaded == nil then return end
		if not (clickgui and clickgui.Visible) then
			layout.FitsLogged = nil
			return
		end
		local lines, checked = {}, 0
		for view in layout.CardViews do
			local title = view.Title
			local unit = view.NameRow.AbsoluteSize.Y / 20
			if title.Parent and unit > 0 and ui.anim.onScreen(title) then
				checked += 1
				pcall(function()
					local ink, boxPx = title.TextBounds.X, title.AbsoluteSize.X
					local box = boxPx / unit
					local fits = title.TextFits
					if fits == false or math.min(math.abs(ink - box), math.abs(ink - boxPx)) > 0.5 then
						local badge = view.NameRow:FindFirstChild('Bind')
						local gap = '-'
						if badge and badge.Visible then
							local after = badge.AbsolutePosition.X - title.AbsolutePosition.X
							gap = string.format('%.1f/%.1f', after / unit - ink, (after - ink) / unit)
						end
						table.insert(lines, string.format('  %s: text %.1f box %.1f (%.0f px) fits %s gap %s', title.Text, ink, box,
							boxPx, tostring(fits), gap))
					end
				end)
			end
		end
		pcall(function()
			local path = FONT_DIR..'/load-status.txt'
			local ok, body = pcall(readfile, path)
			local head = string.format('titles (font pass %d): %d on screen, %d listed', fonts.Generation or 0, checked, #lines)
			writefile(path, (ok and type(body) == 'string' and body..'\n' or '')..head..(#lines > 0 and '\n'..table.concat(lines, '\n') or ''))
		end)
	end)
end

--[[ A card: name, bind badge and switch on top, a '+' and the one-line description under them, and the
settings below when opened. Modules, legit modules, overlays and the settings-only cards (GUI,
Notifications, Friends ...) are all this. Only the + square lights under the pointer, and the
description with it, as in Slinky; the press takes the whole line. A card has no square while none
of its settings' rows is showing, counted a frame after the change that hid or showed one.

The height is Slinky's: the header, the 8 px foot and the settings while open, followed at
theme.FollowCard (23.1 a second, Exponential Out over 0.3 s) on the shared driver and drawn in whole
units. Opening shows the settings at once and the card grows over them; closing hides them and the
empty card shrinks; opening never moves the page. A card off screen, a profile load and the 0.25 s
after it (ui.anim.LoadEnded) take their heights at once. The body clips, so while the card moves the
settings show only down to 8 px above its drawn bottom. Screen pixels become GUI units off the title
row, 20 tall in every layout. A card notes the font pass it was made after (fonts.Generation),
because one laid out before its face loaded kept the fallback's narrower box and layout.place lays
it out again. Cards are 72 tall (header 64) and 44 in Compact (header 36, no description). ]]
function ui.card(props)
	local card = ui.new('Frame', {
		Name = props.Name,
		BackgroundColor3 = theme.Card,
		BackgroundTransparency = 0,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 72)
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
	ui.list(nameRow, 5, true)
	local title = ui.text(nameRow, {Text = props.Display or props.Name, Size = 16, Weight = 'Medium', Color = theme.Text, Props = {
		Name = 'Name',
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = 1,
		Size = UDim2.fromOffset(0, 20)
	}})
	ui.padding(title, 0, 0, 0, 2)
	ui.fitTitle(nameRow, title)

	local switch = props.Switch and ui.switch(header, UDim2.new(1, -theme.Inset, 0, 22)) or nil
	local description
	local hasSettings = true
	local expand, glyph, expandHover = ui.expander(header, UDim2.fromOffset(theme.Inset, 40), {
		Lit = function(lit)
			description.TextColor3 = (lit and hasSettings) and theme.SubTextLit or theme.SubText
		end,
		Region = function(point, square)
			local corner, size = square.AbsolutePosition, square.AbsoluteSize
			return point.X >= corner.X and point.X <= corner.X + size.X and point.Y >= corner.Y and point.Y <= corner.Y + size.Y
		end
	})
	description = ui.text(header, {Text = ui.firstLine(props.Tooltip), Size = 14, Color = theme.SubText, Props = {
		Name = 'Description',
		Position = UDim2.fromOffset(theme.Inset + 28, 40),
		Size = UDim2.new(1, -(theme.Inset * 2 + 28), 0, 20),
		TextTruncate = Enum.TextTruncate.AtEnd
	}})

	local body = ui.new('Frame', {
		Name = props.ChildrenName or (props.Name..'Children'),
		BackgroundColor3 = theme.Card,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		LayoutOrder = 2,
		Size = UDim2.new(1, 0, 0, 0),
		Visible = false
	}, card)
	local bodyList = ui.list(body, 0, false, Enum.HorizontalAlignment.Center)
	ui.fade.split(body)

	local view = {
		Card = card,
		Header = header,
		NameRow = nameRow,
		Title = title,
		Switch = switch,
		Expand = expand,
		Glyph = glyph,
		Description = description,
		Body = body,
		Clip = body,
		BodyList = bodyList,
		Height = 72
	}

	view.FitGen = fonts.Generation
	function view:Refit()
		for _, label in {title, nameRow:FindFirstChild('Bind'), nameRow:FindFirstChild('Hold')} do
			local text = label.Text
			label.Text = text..' '
			label.Text = text
		end
	end
	layout.ViewOf = layout.ViewOf or setmetatable({}, {__mode = 'k'})
	layout.ViewOf[card] = view

	function view.TargetHeight()
		local head = header.Size.Y.Offset
		local height = head + 8
		if body.Visible then
			local unit = nameRow.AbsoluteSize.Y / 20
			if unit > 0 then
				height += math.floor(bodyList.AbsoluteContentSize.Y / unit + 0.5)
			end
		end
		return height
	end
	local function draw(height)
		local rounded, head = math.floor(height + 0.5), header.Size.Y.Offset
		if rounded == view.Drawn and head == view.DrawnHead then return end
		view.Drawn, view.DrawnHead = rounded, head
		card.Size = UDim2.new(1, 0, 0, rounded)
		body.Size = UDim2.new(1, 0, 0, math.max(rounded - 8 - head, 0))
	end
	view.Motion = {Owner = card}
	function view.Motion.Step(dt)
		if slinky.applying or os.clock() - (ui.anim.LoadEnded or -math.huge) < 0.25 then
			view.Motion.Finish()
			return true
		end
		local target = view.TargetHeight()
		view.Height = ui.anim.follow(view.Height, target, theme.FollowCard, dt)
		if math.abs(target - view.Height) < 0.01 then
			view.Height = target
		end
		draw(view.Height)
		return view.Height == target
	end
	function view.Motion.Finish()
		view.Height = view.TargetHeight()
		draw(view.Height)
	end
	function view:Retarget(snap)
		if snap then
			ui.anim.stop(card)
			view.Motion.Finish()
		else
			ui.anim.play(card, view.Motion)
		end
	end
	bodyList:GetPropertyChangedSignal('AbsoluteContentSize'):Connect(function()
		local height = bodyList.AbsoluteContentSize.Y
		if height == view.ContentHeight then return end
		view.ContentHeight = height
		if body.Visible then
			view:Retarget()
		end
	end)

	function view:SetExpanded(open)
		view.Open = open == true
		body.Visible = open and view.HasOptions
		glyph:Set(open)
		view:Retarget(not ui.anim.onScreen(card))
	end

	view.HasOptions = true
	function view:SetHasOptions(has)
		view.HasOptions = has
		hasSettings = has
		if not has then
			expandHover.Rest()
			description.TextColor3 = theme.SubText
		end
		expand.Visible = has
		local left = has and theme.Inset + 28 or theme.Inset
		description.Position = UDim2.fromOffset(left, description.Position.Y.Offset)
		description.Size = UDim2.new(1, -(left + theme.Inset), 0, description.Size.Y.Offset)
		body.Visible = has and view.Open == true
		view:ApplyLayout()
	end

	function view:ApplyLayout()
		local compact = layout.Compact == true
		header.Size = UDim2.new(1, 0, 0, compact and 36 or 64)
		description.Visible = not compact
		local left = (compact and view.HasOptions) and theme.Inset + 28 or theme.Inset
		nameRow.Position = UDim2.fromOffset(left, 12)
		nameRow.Size = UDim2.new(1, -(left + theme.Inset + 48), 0, 20)
		if compact then
			expand.Position = UDim2.fromOffset(theme.Inset, 4)
			expand.Size = UDim2.fromOffset(28, 32)
		else
			expand.Position = UDim2.fromOffset(theme.Inset, 32)
			expand.Size = UDim2.new(1, -theme.Inset * 2, 0, 32)
		end
		view:Retarget(true)
	end

	function view:WatchOptions(options)
		local queued, watched = false, setmetatable({}, {__mode = 'k'})
		local function showing()
			for _, child in body:GetChildren() do
				if child:IsA('GuiObject') and child.Visible then return true end
			end
			return false
		end
		local function recount()
			queued = false
			if slinky.loaded == nil or not card.Parent then return end
			if slinky.threadFix then
				setthreadidentity(8)
			end
			local has = showing()
			if has ~= view.HasOptions then
				view:SetHasOptions(has)
			end
		end
		local function request()
			if queued then return end
			queued = true
			task.defer(recount)
		end
		local function watch(child)
			if child:IsA('GuiObject') and not watched[child] then
				watched[child] = true
				child:GetPropertyChangedSignal('Visible'):Connect(request)
			end
			request()
		end
		body.ChildAdded:Connect(watch)
		body.ChildRemoved:Connect(request)
		for _, child in body:GetChildren() do
			watch(child)
		end
		view:SetHasOptions(showing())
		return setmetatable(options, {
			__newindex = function(t, key, value)
				rawset(t, key, value)
				request()
			end
		})
	end

	if props.Tooltip and props.Tooltip ~= '' then
		addTooltip(description, props.Tooltip)
	end

	layout.CardViews[view] = true
	view:ApplyLayout()
	return view
end

components = {}

components.keybind = function(props, children, api)
	local component = {
		kind = 'keybind',
		hold = props.hold or false,
		keys = {},
		triggered = createSignal()
	}

	--[[ The badge: NONE when unbound, the keys in the accent once bound, PRESS A KEY... while it
	waits for one. Shift-click switches it between toggle and hold. ]]
	local alwaysShown = props.module and props.cover and not isMobile()
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
		local holdText = 'Mode: '..(component.hold and 'hold' or 'toggle')
		if inputService:IsKeyDown(Enum.KeyCode.LeftShift) then
			holdText = "<font color='"..ui.hex(theme.Red).."'>"..holdText.."</font>"
		end
		return 'Click to bind, click again to clear\nShift-click to switch toggle/hold\n'..holdText
	end)

	--[[ A module or overlay card's HOLD badge, after its key badge (props.HoldBadge): Slinky's switch
	between toggle and hold (video 10-11-25). While hold is on it shows, #999999 on #323232; while it
	is off it is drawn only with the pointer on its spot, on the key badge's #282828. Under the
	pointer its text goes #DDDDDD either way. It is there, drawn or not, whenever the bind has a key
	and is not waiting for one, so its spot takes the pointer and the click. On a touch screen, where
	nothing lights under a finger, it is drawn at rest as well and says the mode by itself: hold on,
	#DDDDDD on the #323232 pill; hold off, #999999 in a plain outline with no fill. A tap switches it
	there as a click does. A bind with an on-screen button has it with no key too: there the button is
	the bind's key. ]]
	local holdBadge, holdOutline
	local holdHovered = false
	if props.module and props.holdBadge then
		holdBadge = ui.text(nil, {Class = 'TextButton', Text = 'HOLD', Size = 12, Weight = 'Bold', Color = theme.SubText, AlignX = Enum.TextXAlignment.Center, Props = {
			Name = 'Hold',
			AutomaticSize = Enum.AutomaticSize.X,
			BackgroundColor3 = theme.Badge,
			BackgroundTransparency = 1,
			LayoutOrder = 3,
			Size = UDim2.fromOffset(0, 20),
			TextTransparency = 1,
			Visible = false
		}})
		ui.corner(holdBadge, 5)
		ui.padding(holdBadge, 6, 6, 0, 0)
	end

	--[[ Under the pointer the badge's text lights up at once, as Slinky's does: NONE, PRESS A KEY...
	and a bound key's accent all go white, on the badge's unchanged background. ]]
	local hovered = false
	local holdState
	--[[ Draws the bind badge: PRESS A KEY... while waiting, the keys in the accent when bound, NONE
	otherwise, with HOLD after them unless the card has its own HOLD badge. The HOLD badge is
	written only when its state changes, since the accent repaint can come every frame with rainbow;
	on a touch screen it also shows while the bind has an on-screen button, and gets its outline the
	first time it is drawn there. ]]
	local function paint()
		local text
		local suffix = component.hold and not holdBadge
		if component.binding then
			bind.Text = 'PRESS A KEY...'
			text = hovered and theme.Lit or theme.Text
			bind.BackgroundColor3 = theme.Badge
		elseif #component.keys > 0 then
			bind.Text = ui.keyText(component.keys)..(suffix and '  HOLD' or '')
			local accent = theme.Accent()
			text = hovered and theme.Lit or accent
			bind.BackgroundColor3 = theme.Tint(accent, 0.15)
		else
			bind.Text = suffix and 'NONE  HOLD' or 'NONE'
			text = hovered and theme.Lit or theme.SubText
			bind.BackgroundColor3 = theme.Badge
		end
		tween:Cancel(bind)
		bind.TextColor3 = text

		if holdBadge then
			local touch = isMobile()
			local shown = (#component.keys > 0 or (touch and component.mobile ~= nil)) and not component.binding
			local state = (shown and 1 or 0) + (component.hold and 2 or 0) + (holdHovered and 4 or 0) + (touch and 8 or 0)
			if state ~= holdState then
				holdState = state
				holdBadge.Visible = shown
				holdBadge.BackgroundColor3 = component.hold and theme.HoldOn or theme.Badge
				if touch then
					if not holdOutline then
						holdOutline = ui.stroke(holdBadge, theme.Outline, 1, 0)
					end
					holdOutline.Enabled = not component.hold
					holdBadge.BackgroundTransparency = component.hold and 0 or 1
					holdBadge.TextTransparency = 0
					holdBadge.TextColor3 = (component.hold or holdHovered) and theme.Text or theme.SubText
				else
					if holdOutline then
						holdOutline.Enabled = false
					end
					local drawn = component.hold or holdHovered
					holdBadge.BackgroundTransparency = drawn and 0 or 1
					holdBadge.TextTransparency = drawn and 0 or 1
					holdBadge.TextColor3 = holdHovered and theme.Text or theme.SubText
				end
			end
		end
	end
	--[[ Both through ui.hover: instant; never on a touch screen, where a tap enters and never leaves,
	nor under an open modal's backdrop; put out when the menu shows or hides under the pointer, and
	lit again when a modal closes over it (ui.rehover). ]]
	local bindHover = ui.hover(bind, function()
		hovered = true
		paint()
	end, function()
		hovered = false
		paint()
	end)
	local holdHover = holdBadge and ui.hover(holdBadge, function()
		holdHovered = true
		paint()
	end, function()
		holdHovered = false
		paint()
	end)

	if props.module then
		local parent = api.bindParent or api.row
		bind.Parent = parent
		if holdBadge then
			holdBadge.Parent = parent
		end
		component.row = bind
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
		addTooltip(holder, props.about)
		bind.Visible = true
		bind.Parent = slot
		component.row = holder
	end

	-- Lets go of a press still down on this bind's on-screen button (set while it exists).
	local mobileRelease
	--[[ Puts the bind's on-screen button at a position, hidden while the menu is open. A hold bind's
	button holds as its key does: on from the press and off when that press ends, on the button or
	off it, or when the button goes. A toggle bind's button fires on click, and a press held 1 s
	without moving 6 px removes the button and saves. ]]
	function component:createMobileButton(position)
		self:destroyMobileButton()

		local isHeld = false
		local button = Instance.new('TextButton')
		button.AnchorPoint = Vector2.new(0.5, 0.5)
		button.BackgroundColor3 = api.enabled and theme.Accent() or theme.Bar
		button.BackgroundTransparency = 0.2
		button.FontFace = uipallet.FontMedium
		button.Position = UDim2.fromOffset(position.X, position.Y)
		button.Size = UDim2.fromOffset(44, 44)
		button.Text = api.name or 'Button'
		button.TextColor3 = Color3.new(1, 1, 1)
		button.TextScaled = true
		button.Parent = gui
		button.Visible = not (clickgui and clickgui.Visible)
		local constraint = Instance.new('UITextSizeConstraint')
		constraint.MaxTextSize = 14
		constraint.Parent = button
		addCorner(button, UDim.new(1, 0))

		local press, pressEnd
		local function release()
			if pressEnd then
				pressEnd:Disconnect()
				pressEnd = nil
			end
			if press then
				press = nil
				local triggered = self.triggered
				if triggered then
					triggered:Fire(false)
				end
				button.BackgroundColor3 = api.enabled and theme.Accent() or theme.Bar
			end
		end
		mobileRelease = release
		button.InputBegan:Connect(function(input)
			local kind = input.UserInputType
			if press or not self.hold or (kind ~= Enum.UserInputType.Touch and kind ~= Enum.UserInputType.MouseButton1) then return end
			press = input
			pressEnd = inputService.InputEnded:Connect(function(ended)
				if ended == input or (kind == Enum.UserInputType.MouseButton1 and ended.UserInputType == kind) then
					release()
				end
			end)
			self.triggered:Fire(true)
			button.BackgroundColor3 = api.enabled and theme.Accent() or theme.Bar
		end)

		button.MouseButton1Down:Connect(function()
			if self.hold then return end
			isHeld = true

			local holdtime, holdPos = os.clock(), inputService:GetMouseLocation()
			repeat
				isHeld = (inputService:GetMouseLocation() - holdPos).Magnitude < 6

				task.wait()
			until (os.clock() - holdtime) > 1 or not isHeld

			if isHeld then
				self:destroyMobileButton()
				slinky:requestSave()
			end
		end)

		button.MouseButton1Up:Connect(function()
			isHeld = false
			release()
		end)

		button.MouseButton1Click:Connect(function()
			if self.hold then return end
			self.triggered:Fire(true)
			button.BackgroundColor3 = api.enabled and theme.Accent() or theme.Bar
		end)

		self.mobile = button
		paint()
	end

	function component:Destroy()
		layout.Binds[component] = nil
		bind:Destroy()
		bind:ClearAllChildren()
		if holdBadge then
			holdBadge:Destroy()
		end

		if self.row then
			self.row:Destroy()
			self.row:ClearAllChildren()
		end

		self:destroyMobileButton()

		local index = table.find(slinky.activeBinds, self)
		if index then
			table.remove(slinky.activeBinds, index)
		end
	end

	-- Removes the bind's on-screen button; a press still down on it is let go first.
	function component:destroyMobileButton()
		local letGo = mobileRelease
		mobileRelease = nil
		if letGo then
			letGo()
		end
		if self.mobile then
			self.mobile:Destroy()
			self.mobile = nil
			paint()
		end
	end

	--[[ A bind's saved value is {keys, hold, mobile}: the keys, hold when it is a hold bind, and the
	place of its on-screen button when it has one. Any part may be missing: an entry written before
	the module had a bind, or by hand, holds none of them, and loads as unbound. Without a place, a
	button left from the previous profile is removed, or it would be saved into this one. ]]
	function component:load(value)
		if type(value) ~= 'table' then
			return
		end

		self.hold = value.hold == true
		self:set(type(value.keys) == 'table' and value.keys or {})

		local x, y = store.spot(value.mobile)
		if x then
			self:createMobileButton(Vector2.new(x, y))
		else
			self:destroyMobileButton()
		end
	end

	function component:save()
		return {
			keys = table.clone(self.keys),
			hold = self.hold or nil,
			mobile = self.mobile and {
				x = self.mobile.Position.X.Offset,
				y = self.mobile.Position.Y.Offset
			} or nil
		}
	end

	--[[ Binds the keys (an empty table unbinds) and asks for a save. Callers outside this file and saved
	profiles reach it too, so anything but a table counts as no keys. A noRemove bind, such as the
	menu key, falls back to its default instead of being cleared. Bound binds are kept in
	slinky.activeBinds. ]]
	function component:set(keys, mouse)
		keys = type(keys) == 'table' and keys or {}

		if props and props.noRemove and #keys <= 0 then
			keys = type(props.default) == 'table' and props.default or keys
		end

		self.binding = nil
		self.keys = table.clone(keys)

		if #keys <= 0 then
			bind.Visible = alwaysShown or not props.module

			local index = table.find(slinky.activeBinds, component)
			if index then
				table.remove(slinky.activeBinds, index)
			end
		else
			bind.Visible = true

			if not table.find(slinky.activeBinds, component) then
				table.insert(slinky.activeBinds, component)
			end
		end
		paint()
		slinky:requestSave()
	end

	-- Kept for callers; the badge colours itself.
	function component:setColor(newColor) end

	--[[ Moves the bind badge, and the HOLD badge after it, into another row. A badge moved out from
	under a still pointer gets no leave, so its hover is reset first. ]]
	function component:setParent(parent)
		bindHover.Rest()
		bind.Parent = parent
		bind.LayoutOrder = 2
		if holdBadge then
			holdHover.Rest()
			holdBadge.Parent = parent
			holdBadge.LayoutOrder = 3
		end
	end

	function component:setVisible(visible)
		bind.Visible = alwaysShown or not props.module or #self.keys > 0 or visible
	end

	function component:repaint()
		paint()
	end
	layout.Binds[component] = true

	--[[ A click on the bind badge. A second click on the badge that is waiting for a key clears its
	bind. A click while another badge is waiting cancels that one and is handled normally: a badge
	left armed would otherwise swallow every click, and only a key press, binding it, would get out.
	Shift-click on a module's badge switches it between hold and toggle; any other click makes the
	badge wait for a key. ]]
	bind.MouseButton1Click:Connect(function()
		if slinky.binding then
			if slinky.binding == component then
				component:set({}, true)
				slinky.binding = nil
				return
			end

			local stale = slinky.binding
			slinky.binding = nil
			pcall(function() stale:set(stale.keys, true) end)
		end

		if props.module and inputService:IsKeyDown(Enum.KeyCode.LeftShift) then
			component.hold = not component.hold
			paint()
			slinky:requestSave()
			if slinky.currentTooltip then
				slinky.currentTooltip()
			end

			return
		end

		component.binding = true
		slinky.binding = component
		paint()
	end)

	--[[ A click on the HOLD badge switches the bind between hold and toggle, letting go of a badge left
	waiting for a key first, as a click on a key badge does. ]]
	if holdBadge then
		holdBadge.MouseButton1Click:Connect(function()
			if slinky.binding then
				local stale = slinky.binding
				slinky.binding = nil
				pcall(function() stale:set(stale.keys, true) end)
			end
			component.hold = not component.hold
			paint()
			slinky:requestSave()
			if slinky.currentTooltip then
				slinky.currentTooltip()
			end
		end)
	end

	if props.module then
		api.bind = component
	else
		if props.default then
			component:set(props.default)
		end

		api.options[props.name] = component
	end
	paint()

	return object(component, props.name or api.name)
end

--[[ A full-width pill button with its tooltip, lit under the pointer and never on a touch screen.
TextButton -> Frame -> TextLabel is the shape autoexec/mcp.lua looks for to find a button. ]]
components.button = function(props, children, api)
	local button = ui.new('TextButton', {
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		LayoutOrder = props.order or 0,
		Size = UDim2.new(1, 0, 0, 36),
		Text = ''
	}, children)
	addTooltip(button, props.about)
	local holder = ui.new('Frame', {
		Name = 'Pill',
		BackgroundColor3 = theme.Card,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(theme.Inset, 5),
		Size = UDim2.new(1, -theme.Inset * 2, 0, 26)
	}, button)
	ui.corner(holder, UDim.new(1, 0))
	local stroke = ui.stroke(holder, theme.Outline, 1, 0.1)
	ui.text(holder, {Text = props.label or props.name, Size = 14, Weight = 'Medium', Color = theme.Label, AlignX = Enum.TextXAlignment.Center, Props = {
		Name = 'Title',
		Size = UDim2.fromScale(1, 1)
	}})
	props.clicked = props.clicked or function() end

	ui.hover(button, function()
		holder.BackgroundColor3 = theme.Raised
		stroke.Color = theme.Muted
	end, function()
		holder.BackgroundColor3 = theme.Card
		stroke.Color = theme.Outline
	end)

	button.MouseButton1Click:Connect(props.clicked)

	return object({
		kind = 'button',
		row = button
	}, props.name)
end

--[[ A category's entry in the profile. Its modules are cards in their tab; this hidden frame only keeps
the window position, switch and open state the profile file records for each category (__on, __open,
__pos), so profile files keep the same fields. ]]
components.categoryWindow = function(props, children, api)
	local component = {
		kind = 'categoryWindow',
		name = props.name,
		expanded = false
	}

	local window = ui.new('Frame', {
		Name = props.name..'Category',
		BackgroundColor3 = theme.Card,
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(236, 60),
		Size = UDim2.fromOffset(0, 0),
		Visible = false
	}, layout.Hidden)
	component.done = ui.new('TextButton', {Name = 'Done', BackgroundTransparency = 1, Text = '', Visible = false}, window)

	function component:recolor(hue, sat, val, isRainbow) end

	function component:expand()
		self.expanded = not self.expanded
	end

	function component:load(entry)
		if type(entry.__on) == 'boolean' and self.switch.enabled ~= entry.__on then
			self.switch:flip()
		end

		if type(entry.__open) == 'boolean' and (self.expanded and true or false) ~= entry.__open then
			self:expand()
		end

		local x, y = store.spot(entry.__pos)
		if x then
			window.Position = UDim2.fromOffset(x, y)
		end
	end

	function component:save()
		return {
			__on = self.switch.enabled,
			__open = self.expanded and true or false,
			__pos = {
				x = window.Position.X.Offset,
				y = window.Position.Y.Offset
			}
		}
	end

	bindComponents(component, window)

	component.switch = slinky.categories.Main:guiButton(props.name, {window = window})

	component.row = window
	slinky.categories[props.name] = component

	return object(component)
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

components.categoryList = function(props, children, api)
	local component = {
		kind = 'categoryList',
		expanded = false,
		items = {},
		active = {},
		objects = {},
		options = {}
	}
	props.color = props.color or Color3.fromRGB(243, 93, 18)

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
	local swapStyle = (props.profiles or props.swap) and true or false
	local function currentEntry()
		if props.swap then
			return props.current and props.current() or nil
		end
		return slinky.profile
	end
	--[[ Selecting is the one thing the two shapes do differently: a config swap saves the profile it is
	leaving before it loads the next, and a Swap list only calls props.select and never touches
	profiles. The name goes to slinky:load as well: a refused save (a load still applying, or saving
	blocked) leaves the settings file naming the old profile, and the load would read that one back.
	A refused save is asked for again. ]]
	local function selectEntry(name)
		if props.swap then
			if props.select then
				props.select(name)
			end
			return
		end
		local _, profile = component:find(name)
		if profile then
			profile.used = os.time()
		end
		local saved = slinky:save(name)
		slinky:load(true, name)
		if not saved then
			slinky:requestSave()
		end
	end

	-- Holds the position the save file has always carried for this list's old window.
	local window = ui.new('Frame', {
		Name = props.name..'CategoryList',
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(240, 46),
		Size = UDim2.fromOffset(0, 0),
		Visible = false
	}, layout.Hidden)

	local view, listHolder, optionsHolder, inlineHolder, addvalue, addbutton
	--[[ Builds the list's holders. The Profiles tab gets a hidden header row kept for
	slinky.profileLabel's readers, a grid of profile cards two to a row (one on a narrow window),
	and the extras, inline and options holders under it. Any other list is a card in its tab with an
	entry box: type a name and press Enter or the +. A list with its own tab opens the first time
	that tab does. ]]
	if props.profiles then
		local page = layout.Pages.Profiles.Frame
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
		local current = ui.text(headerRow, {Text = slinky.profile or 'default', Size = 14, Weight = 'Medium', Color = theme.Text, AlignX = Enum.TextXAlignment.Center, Props = {
			BackgroundColor3 = theme.Pill, BackgroundTransparency = 0, LayoutOrder = 2, Size = UDim2.fromOffset(80, 24)
		}})
		ui.corner(current, UDim.new(1, 0))
		slinky.profileLabel = current
		component.headerRow = headerRow

		listHolder = ui.new('Frame', {
			Name = 'Children',
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			LayoutOrder = 2,
			Size = UDim2.new(1, 0, 0, 0)
		}, page)
		local grid = Instance.new('UIGridLayout')
		grid.CellPadding = UDim2.fromOffset(theme.Gap, theme.Gap)
		grid.CellSize = UDim2.new(0.5, -theme.Gap / 2, 0, 72)
		grid.SortOrder = Enum.SortOrder.LayoutOrder
		grid.Parent = listHolder
		component.grid = grid

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
		component.extras = ui.new('Frame', {
			Name = 'Extras',
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			LayoutOrder = 3,
			Size = UDim2.new(1, 0, 0, 0)
		}, page)
		ui.list(component.extras, 8, false)
		component.row = page
	else
		view = ui.card({
			Name = props.name..'Card',
			Display = props.name,
			Tooltip = props.description or CATEGORYLIST_DESCRIPTIONS[props.name] or '',
			ChildrenName = 'Children'
		})
		listHolder = view.Body
		optionsHolder = view.Body
		inlineHolder = view.Body
		component.view = view
		component.row = view.Card
		layout.add({
			Card = view.Card,
			Tab = props.tab or 'Utility',
			Name = props.name,
			Key = props.name:lower(),
			Search = {props.name:lower()}
		})
		if props.tab then
			layout.TabShown[props.tab] = function()
				if not component.expanded then
					component:expand()
				end
			end
		end

		local addrow = ui.row(listHolder, {order = -1}, 38)
		local addbkg = ui.pill(addrow, {Class = 'Frame', AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, theme.Inset, 0.5, 0), Size = UDim2.new(1, -theme.Inset * 2, 0, 28)})
		addbkg.ClipsDescendants = true
		addvalue = ui.text(addbkg, {Class = 'TextBox', Size = 14, Color = theme.Text, Props = {
			ClearTextOnFocus = false,
			PlaceholderColor3 = theme.Muted,
			PlaceholderText = props.placeholder or 'Add entry...',
			Position = UDim2.fromOffset(12, 0),
			Size = UDim2.new(1, -44, 1, 0)
		}})
		addbutton = ui.icon(addbkg, 'plus', 14, {Class = 'TextButton', Color = theme.SubText, NoMirror = true, Props = {
			AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -6, 0.5, 0)
		}})
		ui.hover(addbutton, function()
			ui.paintIcon(addbutton, theme.SubTextLit)
		end, function()
			ui.paintIcon(addbutton, theme.SubText)
		end)
	end
	props.changed = props.changed or function() end

	--[[ Adds a profile row with a key bind of its own that loads it. Names are the identity: lookups,
	changes and the profile file on disk all key off them, so a second entry with the same name is
	refused. usableProfileName is checked here as well, because the saved list is loaded through
	this: a bad name already in the settings file is dropped instead of becoming a row that crashes
	the next save. ]]
	function component:addProfile(value, data, used)
		if not usableProfileName(value) or self:find(value) then
			return
		end

		local profile = {
			name = value,
			used = type(used) == 'number' and used or nil
		}

		profile.bind = components.keybind({
			module = true,
			cover = true
		}, nil, profile)
		profile.bind.triggered:Connect(function(isPressed)
			if isPressed and currentEntry() ~= value then
				selectEntry(value)
				self:change()
			end
		end)

		if data then
			profile.bind:load(data)
		end

		table.insert(self.items, profile)
	end

	--[[ Builds a profile card: its name and bind badge, when it was last used, and the load, import,
	folder and delete icons. An icon's hint shows while the pointer is on the 20x20 round its glyph,
	Slinky's hit box, while the button keeps 26x24 for clicks; a greyed icon has no hint. Load and
	delete ask first. Delete refuses on Default and on the profile in use, greyed to a dark red:
	deleting the one in use would leave nothing selected, and the next autosave would write its file
	straight back. The cards are rebuilt whenever the profile in use changes. ]]
	local function profileCard(name, order)
		local isDefault = name.name == 'default'
		local obj = ui.new('TextButton', {
			Name = name.name,
			AutoButtonColor = false,
			BackgroundColor3 = theme.Card,
			BackgroundTransparency = 0,
			BorderSizePixel = 0,
			LayoutOrder = order,
			Text = ''
		}, listHolder)
		ui.corner(obj, 20)
		local stroke = ui.stroke(obj, theme.Accent(), 1.5, 0)
		stroke.Enabled = false
		local nameRow = ui.new('Frame', {
			Name = 'Title',
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(theme.Inset, 12),
			Size = UDim2.new(1, -150, 0, 20)
		}, obj)
		ui.list(nameRow, 5, true)
		local nameLabel = ui.text(nameRow, {Text = isDefault and 'Default' or name.name, Size = 16, Weight = 'Medium', Color = theme.Text, Props = {
			Name = 'Title', AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 1, Size = UDim2.fromOffset(0, 20), TextTruncate = Enum.TextTruncate.AtEnd
		}})
		ui.padding(nameLabel, 0, 0, 0, 2)
		ui.fitTitle(nameRow, nameLabel)
		if not isDefault or #name.bind.keys > 0 then
			name.bind:setParent(nameRow)
		end
		ui.text(obj, {Text = isDefault and 'Contains the default configuration.' or usedText(name.used), Size = 14, Color = theme.SubText, Props = {
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
		local actions = component.cardActions or {}
		local function action(iconName, tip, order2, colour, callback, greyed)
			local button = ui.icon(icons, iconName, 20, {Class = 'TextButton', Color = colour or theme.SubText, Props = {LayoutOrder = order2, Size = UDim2.fromOffset(26, 24)}})
			if not greyed then
				local spot = ui.new('Frame', {
					Name = 'TipSpot',
					AnchorPoint = Vector2.new(0.5, 0.5),
					BackgroundTransparency = 1,
					Position = UDim2.fromScale(0.5, 0.5),
					Size = UDim2.fromOffset(20, 20)
				}, button)
				addRowTooltip(button, tip, button, spot, scaledgui)
			end
			if callback then
				button.MouseButton1Click:Connect(callback)
			end
			return button
		end

		local loadButton = action('slinky-export', 'Click to load', 0, nil, function()
			ui.confirm("Load profile '"..(isDefault and 'Default' or name.name).."'?", function()
				selectEntry(name.name)
				component:change()
			end)
		end)
		ui.hover(loadButton, function()
			ui.paintIcon(loadButton, theme.SubTextLit)
		end, function()
			ui.paintIcon(loadButton, theme.SubText)
		end)
		action('slinky-save', 'Click to import', 2, nil, function()
			if actions.import then actions.import(name.name) end
		end)
		action('slinky-folder', 'Click to copy folder path', 3, nil, function()
			if actions.folder then actions.folder(name.name) end
		end)
		local refuses = isDefault or name.enabled
		action('slinky-trash', 'Click to delete', 4, refuses and theme.TrashOff or theme.Trash, function()
			if isDefault then
				slinky:notify('Pistonware', 'The default profile cannot be deleted.', 4, 'warning')
				return
			end
			if name.enabled then
				slinky:notify('Pistonware', 'Switch to another profile before deleting this one.', 4, 'warning')
				return
			end
			ui.confirm("Delete the profile '"..name.name.."'?", function()
				component:change(name.name)
			end, 'Delete')
		end, refuses)

		if name.enabled then
			component.selected = obj
			component.selectedStroke = stroke
		end

		return {
			Destroy = function()
				name.bind:setParent(nil)
				obj:Destroy()
			end
		}
	end

	--[[ The Profiles list's last card, CREATE NEW PROFILE. A click swaps the label for a name box;
	Enter, or on a phone a box with text losing focus, submits the name through component:submit.
	Under the pointer only the label goes white, and never on a touch screen (ui.hover). ]]
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
		ui.hover(obj, function()
			label.TextColor3 = theme.Lit
		end, function()
			label.TextColor3 = theme.Text
		end)
		local box = ui.text(obj, {Class = 'TextBox', Size = 15, Color = theme.Text, AlignX = Enum.TextXAlignment.Center, Props = {
			ClearTextOnFocus = false,
			PlaceholderColor3 = theme.Muted,
			PlaceholderText = props.placeholder or 'Type a name, then Enter',
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
				component:submit()
			end
			box.Text = ''
			box.Visible = false
			label.Visible = true
		end)
		return obj
	end

	--[[ A row of a Swap list (the FFlags sets): the name, in the accent for the current entry, its bind,
	and a delete for any entry but default that is not current. Its Destroy also takes the bind off
	the row. ]]
	local function swapRow(name, order)
		local obj = ui.new('TextButton', {
			Name = name.name,
			AutoButtonColor = false,
			BackgroundTransparency = 1,
			LayoutOrder = order,
			Size = UDim2.new(1, 0, 0, 32),
			Text = ''
		}, listHolder)
		local title = ui.text(obj, {Text = name.name, Size = 15, Weight = name.enabled and 'Medium' or 'Regular', Color = name.enabled and theme.Accent() or theme.Label, Props = {
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
		name.bind:setParent(right)
		if name.name ~= 'default' and not name.enabled then
			local delete = ui.icon(right, 'trash-2', 15, {Class = 'TextButton', Color = theme.Red, Props = {LayoutOrder = 3, Size = UDim2.fromOffset(24, 24)}})
			delete.MouseButton1Click:Connect(function()
				component:change(name.name)
			end)
		end
		obj.MouseButton1Click:Connect(function()
			selectEntry(name.name)
			component:change()
		end)
		if name.enabled then
			component.selected = obj
			component.selectedTitle = title
		end
		return {
			Destroy = function()
				name.bind:setParent(nil)
				obj:Destroy()
			end
		}
	end

	--[[ A row of the plain list shape (Friends, Targets): a dot that shows and switches whether the
	entry is on, its name, and an x that removes it. Both frames of the dot are named 'Dot' because
	the Friends colour picker finds the dots by that name. ]]
	local function plainRow(name, order)
		local isEnabled = table.find(component.active, name)
		local obj = ui.new('TextButton', {
			Name = name,
			AutoButtonColor = false,
			BackgroundTransparency = 1,
			LayoutOrder = order,
			Size = UDim2.new(1, 0, 0, 30),
			Text = ''
		}, listHolder)
		local dot = ui.new('Frame', {
			Name = 'Dot',
			AnchorPoint = Vector2.new(0, 0.5),
			BackgroundColor3 = isEnabled and props.color or theme.Muted,
			Position = UDim2.new(0, theme.Inset, 0.5, 0),
			Size = UDim2.fromOffset(12, 12)
		}, obj)
		ui.corner(dot, UDim.new(1, 0))
		local dotin = ui.new('Frame', {
			Name = 'Dot',
			BackgroundColor3 = isEnabled and props.color or theme.Card,
			Position = UDim2.fromOffset(2, 2),
			Size = UDim2.fromOffset(8, 8)
		}, dot)
		ui.corner(dotin, UDim.new(1, 0))
		ui.text(obj, {Text = name, Size = 15, Color = theme.Label, Props = {
			Position = UDim2.fromOffset(theme.Inset + 22, 0), Size = UDim2.new(1, -(theme.Inset * 2 + 50), 1, 0), TextTruncate = Enum.TextTruncate.AtEnd
		}})
		local close = ui.icon(obj, 'x', 14, {Class = 'TextButton', Color = theme.CloseRest, NoMirror = true, Props = {
			AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -theme.Inset + 4, 0.5, 0)
		}})
		ui.hover(close, function()
			ui.paintIcon(close, theme.Red)
		end, function()
			ui.paintIcon(close, theme.CloseRest)
		end)
		close.MouseButton1Click:Connect(function()
			component:change(name)
		end)
		obj.MouseButton1Click:Connect(function()
			local index = table.find(component.active, name)
			if index then
				table.remove(component.active, index)
				dot.BackgroundColor3 = theme.Muted
				dotin.BackgroundColor3 = theme.Card
			else
				table.insert(component.active, name)
				dot.BackgroundColor3 = props.color
				dotin.BackgroundColor3 = props.color
			end

			props.changed()
			slinky:requestSave()
		end)
		return obj
	end

	--[[ Adds or removes an entry (a name already in the list is removed, a new one added), then rebuilds
	every row. 'default' is never removed: everything falls back to it, and a list without it would
	fall back to a row that does not exist. Removing a profile deletes its file; a Swap list calls
	props.delete instead. A change with a value requests a save, like any other change. Rows are
	drawn default first, then alphabetically ignoring case; the saved order stays as it is. ]]
	function component:change(value, skipGUI)
		if value then
			if swapStyle then
				local index, profile = self:find(value)
				if index then
					if value ~= 'default' then
						profile.bind:Destroy()
						table.remove(self.items, index)

						if props.swap then
							if props.delete then
								props.delete(value)
							end
						else
							if isfile(store.path(value)) and delfile then
								delfile(store.path(value))
							end
							store.dropOld(value)
						end
					end
				else
					self:addProfile(value)
				end
			else
				local index = table.find(self.items, value)
				if index then
					table.remove(self.items, index)

					index = table.find(self.active, value)
					if index then
						table.remove(self.active, index)
					end
				else
					table.insert(self.items, value)
					table.insert(self.active, value)
				end
			end
		end

		props.changed(value, skipGUI)
		if value ~= nil then
			slinky:requestSave()
		end
		for _, obj in self.objects do
			obj:Destroy()
		end
		table.clear(self.objects)
		self.selected = nil
		self.selectedStroke = nil
		self.selectedTitle = nil
		self.selectedBadge = nil

		if slinky.threadFix then
			setthreadidentity(8)
		end

		local ordered = table.clone(self.items)
		if swapStyle then
			table.sort(ordered, function(a, b)
				if a.name == 'default' then return b.name ~= 'default' end
				if b.name == 'default' then return false end
				return a.name:lower() < b.name:lower()
			end)
		end

		for index, name in ordered do
			if swapStyle then
				name.enabled = name.name == currentEntry()
				if props.profiles then
					table.insert(self.objects, profileCard(name, index))
				else
					table.insert(self.objects, swapRow(name, index))
				end
			else
				table.insert(self.objects, plainRow(name, index))
			end
		end
		if props.profiles then
			table.insert(self.objects, createCard(#ordered + 1))
		end

		if not skipGUI then
			slinky:recolor(slinky.accent.hue, slinky.accent.sat, slinky.accent.value)
		end
		if value ~= nil and not swapStyle then
			ui.rehoverSoon()
		end
	end

	function component:recolor(hue, sat, val, isRainbow)
		for _, option in self.options do
			if option.recolor then
				option:recolor(hue, sat, val, isRainbow)
			end
		end

		local accent = isRainbow and Color3.fromHSV(slinky:colorAt(hue % 1)) or Color3.fromHSV(hue, sat, val)
		if self.selectedStroke then
			self.selectedStroke.Color = accent
		end
		if self.selectedTitle then
			self.selectedTitle.TextColor3 = accent
		end
		if self.selectedBadge then
			self.selectedBadge.TextColor3 = accent
			self.selectedBadge.BackgroundColor3 = theme.Tint(accent, 0.15)
		end
	end

	function component:expand()
		self.expanded = not self.expanded
		if view then
			view:SetExpanded(self.expanded)
		end
		if self.expanded and props.onExpand then
			pcall(props.onExpand)
		end
	end

	function component:find(name)
		for index, profile in self.items do
			if profile.name == name then
				return index, profile
			end
		end
	end

	--[[ Applies the list's entry of the settings file. __items holds rows with a name, a key and the
	last use for the one-current shape, and the names with which of them are on for the plain one.
	The one-current list is rebuilt, its old binds destroyed: appending would double it on a second
	Load in the same run (a reinject, a new server) and every save would write the doubled list
	back. Only a Swap list restores its current entry here, before the rebuild so that row comes
	back in the GUI colour; a profile list's is the settings file's `profile`, which slinky:Load
	reads. ]]
	function component:load(entry)
		slinky:loadOptions(self, entry)

		if type(entry.__on) == 'boolean' and self.switch.enabled ~= entry.__on then
			self.switch:flip()
		end

		if type(entry.__open) == 'boolean' and (self.expanded and true or false) ~= entry.__open then
			self:expand()
		end

		local items = entry.__items
		if swapStyle and type(items) == 'table' then
			for _, profile in self.items do
				if profile.bind and profile.bind.Destroy then
					pcall(function() profile.bind:Destroy() end)
				end
			end
			table.clear(self.items)

			for _, row in items do
				if type(row) == 'table' and type(row.name) == 'string' then
					self:addProfile(row.name, row, row.used)
				end
			end

			if props.swap and props.restore and usableProfileName(entry.__selected) then
				props.restore(entry.__selected)
			end

			self:change(nil, true)
		elseif not swapStyle and type(items) == 'table' then
			local names, active = store.listed(items)
			if #self.items > 0 or #names > 0 then
				self.items = names
				self.active = active
				self:change(nil, true)
			end
		end

		local x, y = store.spot(entry.__pos)
		if x then
			window.Position = UDim2.fromOffset(x, y)
		end
	end

	--[[ The list's entry for the settings file: on/off, expanded, window position, a Swap list's current
	entry, and __items. A one-current row is its bind's saved value with the name and the last use
	beside it; an empty keys list is left out. ]]
	function component:save()
		local entry = slinky:saveOptions(self)
		entry.__on = self.switch.enabled
		entry.__open = self.expanded and true or false
		entry.__pos = {
			x = window.Position.X.Offset,
			y = window.Position.Y.Offset
		}

		if swapStyle then
			if props.swap then
				entry.__selected = currentEntry()
			end

			local rows = {}
			for _, profile in self.items do
				local row = profile.bind:save()
				if #row.keys == 0 then
					row.keys = nil
				end
				row.name = profile.name
				row.used = profile.used
				table.insert(rows, row)
			end
			entry.__items = rows
		else
			entry.__items = store.list(self.items, self.active)
		end

		return entry
	end

	bindComponents(component, optionsHolder)

	--[[
		A second binding, into the list itself rather than the settings below it. Options is
		the same table, not a copy, so anything built through this still saves and loads with
		the list. Ordering is by LayoutOrder, which is why the components accept one.
	]]
	component.inline = {
		options = component.options
	}
	bindComponents(component.inline, inlineHolder)

	--[[ Submits the name box, for Enter and the add button alike. On a profile list the text becomes a
	file name, so a name usableProfileName refuses is turned away with an alert; one over 32
	characters is usually a pasted export, and the alert points to the Import profile box. Saved as
	the active profile, such a text crashes the client on every inject. A name already in the list
	is never passed to change, which would take it as a delete. ]]
	function component:submit()
		local text = addvalue and addvalue.Text or ''
		if text == '' then
			return
		end

		if swapStyle and not usableProfileName(text) then
			slinky:notify('Pistonware', #text > 32
				and 'That is too long for a profile name. To bring in an exported profile, use the Import profile box below.'
				or 'A profile name can only use letters, numbers, spaces, - and _.', 10, 'alert')
			return
		end

		local exists
		if swapStyle then
			exists = component:find(text) ~= nil
		else
			exists = table.find(component.items, text) ~= nil
		end
		if exists then
			if swapStyle then
				slinky:notify('Pistonware', "There is already a profile called '"..text.."'.", 5, 'warning')
			end
			return
		end
		component:change(text)
		addvalue.Text = ''
	end

	--[[ Wires the add button and the name box. On a phone, tapping '+' first takes focus from the box,
	which submits it already; a tap within 0.5 s of that is ignored, or a rejected name would repeat
	its alert. A phone's keyboard is usually closed by tapping away, so there a box with text
	submits on any focus loss. ]]
	if addbutton then
		local autoSubmitAt = -1
		addbutton.MouseButton1Click:Connect(function()
			if isMobile() and os.clock() - autoSubmitAt < 0.5 then
				return
			end
			component:submit()
		end)
		addvalue.FocusLost:Connect(function(enter)
			if enter or (isMobile() and addvalue.Text ~= '') then
				autoSubmitAt = os.clock()
				component:submit()
			end
		end)
	end

	--[[ Expands the list from its header and from the expander, with either button. The expander takes
	the whole description line, so a right-click there lands on it. ]]
	if view then
		view.Header.MouseButton1Click:Connect(function()
			component:expand()
		end)
		view.Header.MouseButton2Click:Connect(function()
			component:expand()
		end)
		view.Expand.MouseButton1Click:Connect(function()
			component:expand()
		end)
		view.Expand.MouseButton2Click:Connect(function()
			component:expand()
		end)
	end

	component.switch = slinky.categories.Main:guiButton(props.name, {window = window})

	slinky.categories[props.name] = component

	return object(component, props.name)
end

components.color = function(props, children, api)
	--[[ An option that names no colour starts on the menu's orange, not the old teal; one that names a
	hue keeps the full saturation and brightness it always had. ]]
	local orangeHue, orangeSat, orangeValue = Color3.fromRGB(243, 93, 18):ToHSV()
	--[[ The colour option's state: HSV, opacity and the rainbow switch, starting at the menu's orange
	unless props give a hue. rainbowOffset is where this colour sits in the rainbow's cycle, set
	from the Hue track while the rainbow runs. ]]
	local component = {
		kind = 'color',
		index = 0,
		hue = props.hue or orangeHue,
		sat = props.sat or (props.hue and 1 or orangeSat),
		value = props.value or (props.hue and 1 or orangeValue),
		opacity = props.opacity or 1,
		rainbow = false,
		rainbowOffset = 0
	}

	local colorslider = ui.new('Frame', {
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = props.order or 0,
		Size = UDim2.new(1, 0, 0, 0),
		Visible = props.visible == nil or props.visible
	}, children)
	component.row = colorslider
	ui.list(colorslider, 0)
	local line = ui.row(colorslider, {order = 1})
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
	-- Slinky's 1 px ring round the swatch.
	ui.stroke(swatch, theme.Outline, 1, 0)
	local swatchGradient = ui.new('UIGradient', {}, swatch)
	--[[ The Opacity track is for options that use it: those that name a default opacity, and those
	whose callback takes the fourth (opacity) argument. ]]
	local usesOpacity = props.opacity ~= nil
	if not usesOpacity and type(props.changed) == 'function' then
		local ok, arity = pcall(debug.info, props.changed, 'a')
		usesOpacity = ok and (tonumber(arity) or 0) >= 4
	end
	props.changed = props.changed or function() end

	-- The picker's live pieces while it is open; nil when it is closed.
	local open

	--[[ The far end of the swatch fades 73% of the way into the card, as Slinky's does. A colour
	already near black fades lighter instead, toward grey: the swatch still reads as black at its
	start, and the picker square that shares this end still shows a ramp. ]]
	local function swatchEnd(h, s, v)
		local base = Color3.fromHSV(h, s, v)
		if v < 0.3 then
			return base:Lerp(Color3.fromRGB(96, 96, 96), 0.75)
		end
		return base:Lerp(theme.Card, 0.73)
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
		if component.rainbow then
			swatchGradient.Color = rainbowSequence(component.hue, component.sat, component.value)
		else
			local base = Color3.fromHSV(component.hue, component.sat, component.value)
			swatchGradient.Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, base),
				ColorSequenceKeypoint.new(1, swatchEnd(component.hue, component.sat, component.value))
			})
		end
		swatchGradient.Transparency = NumberSequence.new(1 - component.opacity, 1 - component.opacity)
	end

	--[[ The classic tracks: Saturation and Brightness are the colour's own HSV saturation and value. The
	old Lightness track was HSL, where the far end is white for every hue -- a rainbow there stayed
	white whatever the saturation, so the colour never visibly changed. ]]
	local function paintPicker()
		if not open then return end
		local h = component.hue
		local sat, value = component.sat, component.value
		local color = Color3.fromHSV(h, sat, value)
		open.Square.BackgroundColor3 = Color3.new(1, 1, 1)
		open.SquareGradient.Color = component.rainbow and rainbowSequence(h, component.sat, component.value)
			or ColorSequence.new(color, swatchEnd(h, component.sat, component.value))
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
			open.Opacity.Knob.Position = UDim2.fromScale(component.opacity, 0.5)
		end
		if open.Rainbow and open.Rainbow.Enabled ~= component.rainbow then
			open.Rainbow:Set(component.rainbow)
		end
	end

	--[[ Saved as red, green and blue to four decimals, with `a` when it is not opaque and `rainbow`
	(and where in the cycle it sits) when it cycles. ]]
	function component:save()
		local value = store.color(self.hue, self.sat, self.value)
		if math.abs(self.opacity - 1) > 1e-9 then
			value.a = store.tidy(self.opacity)
		end
		if self.rainbow then
			value.rainbow = true
			if math.abs(self.rainbowOffset) > 1e-9 then
				value.rainbow_offset = store.tidy(self.rainbowOffset)
			end
		end
		return value
	end

	--[[ Applies a saved colour: the rainbow and its offset first, then the colour only where it differs.
	A colour read back from four decimals is the same colour, and setting it again would move the
	hue of a grey. ]]
	function component:load(value)
		if not store.isColor(value) then return end
		self.rainbowOffset = tonumber(value.rainbow_offset) or 0
		if (value.rainbow == true) ~= self.rainbow then
			self:flip()
		end

		local opacity = isFiniteNumber(value.a) and value.a or 1
		local now = store.color(self.hue, self.sat, self.value)
		if now.r ~= value.r or now.g ~= value.g or now.b ~= value.b or math.abs(self.opacity - opacity) > 1e-9 then
			local hue, sat, bright = store.hsv(value.r, value.g, value.b)
			self:set(hue, sat, bright, opacity)
		end
	end

	--[[ Sets any of hue, saturation, brightness and opacity, repaints and reports the change. The
	rainbow loop passes the hue alone every frame; that call is taken as the cycle, this colour's
	rainbowOffset is added to it, and it requests no save, since the hue a running rainbow is on is
	nobody's setting. ]]
	function component:set(h, s, v, o)
		local cycling = self.rainbow and h ~= nil and s == nil and v == nil and o == nil
		if cycling then
			h = (h + self.rainbowOffset) % 1
		end
		self.hue = h or self.hue
		self.sat = s or self.sat
		self.value = v or self.value
		self.opacity = o or self.opacity
		paintSwatch()
		paintPicker()

		props.changed(self.hue, self.sat, self.value, self.opacity)
		if not cycling then
			slinky:requestSave()
		end
	end

	function component:flip()
		self.rainbow = not self.rainbow

		if self.rainbow then
			addRainbowSlider(self)
		else
			removeRainbowSlider(self)
		end
		paintSwatch()
		paintPicker()
		slinky:requestSave()
	end

	function component:recolor() end

	-- Typing a colour or choosing a recent one ends a rainbow: that is a colour picked.
	local function pick(h, s, v, o)
		if component.rainbow then
			component:flip()
		end
		component:set(h, s, v, o)
	end

	--[[ The tracks leave a rainbow running, as the classic sliders do: saturation, brightness and opacity
	shape it, and the Hue track moves where this colour sits in the cycle -- it carries on from the
	hue it was dropped on. ]]
	local function adjust(h, s, v, o)
		if h and component.rainbow then
			h = math.min(h, 0.9999)
			local base = (component.hue - component.rainbowOffset) % 1
			component.rainbowOffset = (h - base) % 1
			component:set(base)
			slinky:requestSave()
			return
		end
		component:set(h, s, v, o)
	end

	local function remember()
		local color = Color3.fromHSV(component.hue, component.sat, component.value)
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

	--[[ Opens the colour picker modal, pinned under the tab bar at layout.Top like the confirm dialog:
	title and close, the colour and its hex box, Hue, Saturation and Brightness tracks, an Opacity
	track for options that carry an opacity, the Rainbow switch, then the eight colours used most
	recently. Opening it puts out every hint and hover light underneath, and nothing outside it
	lights while it is up (ui.modal). It takes the window's zoom but is never taller than the screen
	leaves under its top, so the tracks stay on screen on a short landscape phone.

	Typing a colour or choosing a recent one turns the rainbow off. The hex box takes #rrggbb or r,
	g, b; 'nan' and 'inf' read as numbers and are refused. Escape, in the box or not, closes it and
	leaves the menu up (ui.escape). On close the colour joins the recent ones if it changed and is
	not a running rainbow, and hints and hover come back for what the pointer rests on without
	waiting for it to move. ]]
	local function openPicker()
		if not clickgui or open then return end
		ui.hideTips()
		ui.restHovered()
		local scaleNow = math.max(scale.Scale, 0.05) * (layout.Zoom or 1)
		local blocker = ui.new('TextButton', {
			Name = 'ColorPicker',
			AutoButtonColor = false,
			BackgroundColor3 = theme.Backdrop,
			BackgroundTransparency = 0.25,
			BorderSizePixel = 0,
			Size = UDim2.fromScale(1, 1),
			Text = '',
			ZIndex = 20
		}, clickgui)
		local previousModal = ui.modal
		ui.modal = blocker
		local width = math.clamp(viewportWidth() / scaleNow - 24, 260, 576)
		local card = ui.new('TextButton', {
			AutoButtonColor = false,
			AnchorPoint = Vector2.new(0.5, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundColor3 = theme.Card,
			BorderSizePixel = 0,
			Position = UDim2.new(0.5, 0, 0, layout.Top or 12),
			Size = UDim2.fromOffset(width, 0),
			Text = '',
			ZIndex = 21
		}, blocker)
		ui.corner(card, 20)
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
		zText(header, props.label or props.name, 16, {Size = UDim2.new(1, -40, 1, 0)})
		local close = ui.icon(header, 'slinky-x', 16, {Class = 'TextButton', Color = theme.SubText, NoMirror = true, Box = UDim2.fromOffset(24, 24), Props = {
			AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 2, 0.5, 0), ZIndex = 22
		}})
		local closeEntry = fonts.Registry[close]
		if closeEntry then
			closeEntry.Size = 21
			ui.setIcon(close, 'slinky-x')
		end
		close.Glyph.ZIndex = 23
		ui.hover(close, function()
			ui.paintIcon(close, theme.RedHover)
		end, function()
			ui.paintIcon(close, theme.SubText)
		end)

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
			component:flip()
			rainbowSwitch:Set(component.rainbow)
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
			local ring = ui.stroke(box, theme.Outline, 2, 0)
			ui.hover(box, function()
				ring.Color = theme.PillHover
			end, function()
				ring.Color = theme.Outline
			end)
			if color then
				box.MouseButton1Click:Connect(function()
					local h, s, v = color:ToHSV()
					pick(h, s, v)
				end)
			end
		end

		open = {Square = square, SquareGradient = squareGradient, Hex = hex, Hue = hue, Sat = sat, Light = light, Opacity = opacity, Rainbow = rainbowSwitch}
		rainbowSwitch:Set(component.rainbow)
		paintPicker()

		local before = Color3.fromHSV(component.hue, component.sat, component.value):ToHex()
		local closed = false
		local function dismiss()
			if closed then return end
			closed = true
			if not component.rainbow and Color3.fromHSV(component.hue, component.sat, component.value):ToHex() ~= before then
				remember()
			end
			open = nil
			ui.popEscape(blocker)
			if ui.modal == blocker then
				ui.modal = previousModal and previousModal.Parent and previousModal or nil
			end
			blocker:Destroy()
			task.defer(function()
				if slinky.loaded == nil then return end
				if slinky.threadFix then
					setthreadidentity(8)
				end
				ui.refreshTooltip()
				ui.rehover()
			end)
		end
		blocker.MouseButton1Click:Connect(dismiss)
		close.MouseButton1Click:Connect(dismiss)
		ui.pushEscape(blocker, dismiss)

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

		hex.FocusLost:Connect(function(enter, input)
			local key
			pcall(function()
				key = input.KeyCode
			end)
			if key == Enum.KeyCode.Escape then
				ui.escapeLater('focus')
				return
			end
			if enter then
				local success, parsed = pcall(function()
					local commas = hex.Text:split(',')
					local r, g, b = tonumber(commas[1]), tonumber(commas[2]), tonumber(commas[3])
					if not r then
						return Color3.fromHex(hex.Text)
					end
					if math.abs(r) < math.huge and math.abs(g or 0) < math.huge and math.abs(b or 0) < math.huge then
						return Color3.fromRGB(r, g, b)
					end
					return nil
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
	api.options[props.name] = component

	return object(component, props.name)
end

--[[ A section header when given a name, grey with no rule under it as Slinky groups its settings;
otherwise a thin rule across the card. ]]
components.divider = function(props, children, api)
	if props and props.name then
		local row = ui.row(children, props, 27)
		ui.text(row, {Text = props.name, Size = 15, Color = theme.Header, Props = {
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

--[[ A choice option drawn as Slinky's dropdown box: round, its 2 px border outside, half the card less
10 wide, 11 px in from the card's right edge, its top held 3 px down the row so it opens downward.
Open, the box grows downward in place and pushes the rows under it down by as much, through a spacer
as tall as the box's extra height. Choices are 28 px apart (a 26 px band and a 2 px divider) and
placed by fractions of the box, so they ride its growth with nothing written per frame; past eight
choices the list scrolls in a box eight tall. The choice in use is in the accent.

A press anywhere off the box closes it and still reaches what it pressed; Escape (newest inner menu
first) and the menu shutting close it too. An InputObject's position and a GuiObject's
AbsolutePosition are both measured under Roblox's top bar, so the off-the-box test compares them as
they are; adding the inset makes every press below the list's first ~28 px count as outside. ]]
components.dropdown = function(props, children, api)
	local DROPDOWN_STROKE = 2
	local component = {
		kind = 'dropdown',
		index = 0,
		value = props.choices[1] or 'None'
	}

	local dropdown = ui.new('Frame', {
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = props.order or 0,
		Size = UDim2.new(1, 0, 0, 0),
		Visible = props.visible == nil or props.visible
	}, children)
	component.row = dropdown
	ui.list(dropdown, 0)
	local line = ui.row(dropdown, {order = 1})
	ui.rowLabel(line, props)
	addTooltip(line, props.about or props.name)
	local button = ui.pill(line, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -13, 0, 3 + DROPDOWN_STROKE),
		Radius = UDim.new(0, 9),
		Thickness = DROPDOWN_STROKE,
		Size = UDim2.new(0.5, -14, 0, 22 - DROPDOWN_STROKE * 2)
	})
	button.Name = 'Value'
	local title = ui.text(button, {Text = component.value, Size = 15, Color = theme.Text, AlignX = Enum.TextXAlignment.Center, Props = {
		Position = UDim2.fromOffset(12, 0),
		Size = UDim2.new(1, -24, 1, 0),
		TextTruncate = Enum.TextTruncate.AtEnd
	}})
	props.changed = props.changed or function() end

	local push = ui.new('Frame', {
		Name = 'Push',
		BackgroundTransparency = 1,
		LayoutOrder = 2,
		Size = UDim2.new(1, 0, 0, 0),
		Visible = false
	}, dropdown)
	local options = ui.new('Frame', {
		Name = 'Options',
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Visible = false
	}, button)
	local box = {Owner = button, Height = 22, Open = false}
	local function boxTarget()
		return box.Open and math.max(math.min(#props.choices, 8) * 28 + 2, 22) or 22
	end
	local function drawBox(height)
		local rounded = math.floor(height + 0.5)
		if rounded == box.Drawn then return end
		box.Drawn = rounded
		button.Size = UDim2.new(0.5, -14, 0, rounded - DROPDOWN_STROKE * 2)
		push.Size = UDim2.new(1, 0, 0, math.max(rounded - 22, 0))
		push.Visible = rounded > 22
	end
	function box.Step(dt)
		local target = boxTarget()
		box.Height = ui.anim.follow(box.Height, target, theme.FollowDrop, dt)
		if math.abs(target - box.Height) < 0.01 then
			box.Height = target
		end
		drawBox(box.Height)
		return box.Height == target
	end
	function box.Finish()
		box.Height = boxTarget()
		drawBox(box.Height)
	end
	local function animate()
		if ui.anim.onScreen(button) then
			ui.anim.play(button, box)
		else
			ui.anim.stop(button)
			box.Finish()
		end
	end

	local function buildOptions()
		options:ClearAllChildren()
		local count = #props.choices
		local scrolls = count > 8
		local holder = options
		if scrolls then
			holder = ui.new('ScrollingFrame', {
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				CanvasSize = UDim2.fromOffset(0, count * 28 - 2),
				ScrollBarThickness = 0,
				ScrollingDirection = Enum.ScrollingDirection.Y,
				Size = UDim2.fromScale(1, 1)
			}, options)
			layout.InnerLists[holder] = true
		end
		for index, v in props.choices do
			local selected = v == component.value
			local entry = ui.text(holder, {Class = 'TextButton', Text = v, Size = 15, Color = selected and theme.Accent() or theme.Text, AlignX = Enum.TextXAlignment.Center, Props = {
				Name = 'Option',
				AnchorPoint = Vector2.new(0.5, 0.5),
				LayoutOrder = index,
				Position = scrolls and UDim2.new(0.5, 0, 0, (index - 1) * 28 + 13) or UDim2.new(0.5, 0, (index - 0.5) / count, 0),
				Size = UDim2.new(1, -16, 0, 26),
				TextTruncate = Enum.TextTruncate.AtEnd
			}})
			if index < count then
				ui.new('Frame', {
					BackgroundColor3 = theme.Outline,
					BackgroundTransparency = 0.5,
					BorderSizePixel = 0,
					Position = scrolls and UDim2.new(0, 8, 0, index * 28 - 2) or UDim2.new(0, 0, index / count, -1),
					Size = UDim2.new(1, scrolls and -16 or 0, 0, 2)
				}, holder)
			end
			if not selected then
				ui.hover(entry, function()
					entry.TextColor3 = theme.Lit
				end, function()
					entry.TextColor3 = theme.Text
				end)
			end
			entry.MouseButton1Click:Connect(function()
				component:set(v, true)
			end)
		end
	end

	if not layout.OpenLists then
		layout.OpenLists = {}
		ui.whenShut(function()
			for close in table.clone(layout.OpenLists) do
				pcall(close)
			end
		end)
	end

	local closeList
	local function openList()
		if box.Open or #props.choices == 0 or not ui.anim.onScreen(button) then return end
		box.Open = true
		buildOptions()
		options.Visible = true
		title.Visible = false
		layout.OpenLists[closeList] = true
		ui.pushEscape(closeList, closeList, function()
			return box.Open == true
		end)
		box.Watch = inputService.InputBegan:Connect(function(input)
			if not (isPress(input) or input.UserInputType == Enum.UserInputType.MouseButton2) then return end
			if not ui.within(Vector2.new(input.Position.X, input.Position.Y), button.AbsolutePosition, button.AbsoluteSize) then
				closeList()
			end
		end)
		animate()
	end
	function closeList()
		if box.Watch then
			box.Watch:Disconnect()
			box.Watch = nil
		end
		layout.OpenLists[closeList] = nil
		ui.popEscape(closeList)
		if not box.Open then return end
		box.Open = false
		options.Visible = false
		options:ClearAllChildren()
		title.Visible = true
		animate()
	end

	function component:setChoices(list)
		props.choices = list or {}
		if not table.find(props.choices, self.value) then
			self:set(self.value)
		elseif box.Open then
			buildOptions()
			animate()
		end
	end

	function component:load(value)
		if self.value ~= value then
			self:set(value)
		end
	end

	function component:save()
		return self.value
	end

	function component:set(value, isClick)
		self.value = table.find(props.choices, value) and value or props.choices[1] or 'None'
		title.Text = self.value
		closeList()

		props.changed(self.value, isClick)
		slinky:requestSave()
	end

	button.MouseButton1Click:Connect(function()
		if box.Open then
			closeList()
		else
			openList()
		end
	end)

	ui.hover(button, function()
		title.TextColor3 = theme.Lit
	end, function()
		title.TextColor3 = theme.Text
	end)

	api.options[props.name] = component

	return object(component, props.name)
end

--[[ A font option that never draws a row: the menu has no font picker, so every element keeps the face
it was designed with, the menu's Inter or the caller's default (Target Info's terminal face). It
still saves and loads under its name, through a hidden dropdown and a hidden ' Asset' textbox, so
profiles keep their shape and .Value is always a real Font; a saved font is not applied. Inter
resolves to the menu's medium weight so overlays and name tags match the menu. The value is set
again when the menu's Inter arrives (fonts.Remeasure) and once on the next resume, because a profile
that saved the default never sets it. ]]
components.font = function(props, children, api)
	local fontNames = {}
	table.insert(fontNames, props.default or 'Inter')
	if not table.find(fontNames, 'Inter') then table.insert(fontNames, 'Inter') end
	table.insert(fontNames, 'Custom')
	for _, v in Enum.Font:GetEnumItems() do
		if not table.find(fontNames, v.Name) then
			table.insert(fontNames, v.Name)
		end
	end
	local designed = props.default or 'Inter'

	local function resolve(name)
		if name == 'Inter' then
			return uipallet.FontMedium or uipallet.Font
		end
		local ok, face = pcall(Font.fromEnum, Enum.Font[name])
		return ok and face or uipallet.Font
	end

	local component = {
		value = resolve(designed)
	}
	local function apply()
		component.value = resolve(designed)
		if props.changed then
			props.changed(component.value)
		end
	end

	local fontdropdown = store.built(components.dropdown({
		name = props.name,
		choices = fontNames,
		changed = apply,
		visible = false
	}, children, api))
	fontdropdown.row.Visible = false
	local fontbox = store.built(components.textbox({
		name = props.name..' Asset',
		placeholder = 'font (rbxasset)',
		visible = false
	}, children, api))
	fontbox.row.Visible = false

	component.row = ui.new('Frame', {Name = 'HiddenFont', Visible = false})

	fonts.Remeasure[component] = apply
	task.defer(function()
		pcall(apply)
	end)

	return object(component, props.name, 'font')
end
--[[ Where each settings pane is drawn: the GUI card holds the menu's own settings in sections,
the Notifications card its own. A pane a game adds lands in the GUI card under its name. ]]
local settingsHosts = {}
local PANE_HOSTS = {Notifications = 'Notifications'}
local PANE_ORDER = {Settings = 1, Layout = 2, GUI = 3, General = 4, Modules = 5, Notifications = 1}
local PANE_TITLES = {Settings = 'Main', Layout = 'Layout', GUI = 'Interface', General = 'General', Modules = 'Modules', Notifications = false}

local TAB_ORDER = {'Combat', 'Move', 'Visual', 'Utility', 'Kits', 'FFlags', 'Profiles', 'Unload'}

components.gui = function(props, children, api)
	local component = {
		kind = 'gui',
		buttons = {}
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
	-- Shown and hidden with the menu by layout.MenuShown, from the menu's deferred Visible watcher.
	-- Tabs the layout left marked while the menu was shut are placed as it opens. Only a request:
	-- nothing is written inside the property change.
	clickgui:GetPropertyChangedSignal('Visible'):Connect(function()
		local pending = next(layout.Dirty)
		if pending ~= nil and clickgui.Visible then
			layout.request(pending)
		end
	end)

	--[[ No panel, as Slinky has none: the tab bar and the cards are laid straight onto the screen from
	12 down, with no height of their own, and whatever is past the screen's foot is cut there. The
	whole of it scrolls as one piece, tab bar included (layout.Scroll below). With a mouse the tab bar
	and the page showing move inside the window, which stays put (layout.shiftShown), so nothing but
	the screen cuts them; on a touch screen the window rides in a ScrollingFrame for the engine's drag,
	as wide as the window, so the HUD either side still takes touches. ]]
	local scroller = isMobile() and ui.new('ScrollingFrame', {
		Name = 'Scroller',
		AnchorPoint = Vector2.new(0.5, 0),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		CanvasSize = UDim2.new(),
		ElasticBehavior = Enum.ElasticBehavior.Never,
		Position = UDim2.fromScale(0.5, 0),
		ScrollBarThickness = 0,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Size = UDim2.new(0, 876, 1, 0),
		ZIndex = 1
	}, clickgui) or nil
	local window = ui.new('Frame', {
		Name = 'MainWindow',
		AnchorPoint = Vector2.new(0.5, 0),
		BackgroundTransparency = 1,
		Position = UDim2.new(0.5, 0, 0, 12),
		Size = UDim2.new(0, 876, 1, -24),
		ZIndex = 1
	}, scroller or clickgui)
	component.row = window
	-- What Move HUD hides while the menu stays open: the window, or the scroller holding it.
	layout.Window, layout.Dim = scroller or window, dim
	--[[ The key footer's place (build.keyFooter): the screen's foot, under no scroll, in the window's
	width and zoom (resize), over the cards scrolling past it. It drops in with the tab bar and the page
	showing as the menu opens (layout.placeWindow, layout.shiftShown). ]]
	local footerHolder = ui.new('Frame', {
		Name = 'Footer',
		AnchorPoint = Vector2.new(0.5, 1),
		BackgroundTransparency = 1,
		Position = UDim2.new(0.5, 0, 1, -12),
		Size = UDim2.fromOffset(876, 32),
		ZIndex = 2
	}, clickgui)
	local footerZoom = ui.new('UIScale', {Scale = 1}, footerHolder)
	layout.FooterHolder = footerHolder

	-- The tab bar.
	local bar = ui.new('Frame', {
		Name = 'TabBar',
		BackgroundColor3 = theme.Bar,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 42)
	}, window)
	ui.corner(bar, UDim.new(0, 20))
	-- N equal slots across the bar: one per visible tab, and the last for the search magnifier.
	local tabsFrame = ui.new('Frame', {
		Name = 'Tabs',
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -42, 1, 0)
	}, bar)
	local activePill = ui.new('Frame', {
		Name = 'Active',
		AnchorPoint = Vector2.new(0, 0.5),
		BackgroundColor3 = theme.Pill,
		BorderSizePixel = 0,
		Position = UDim2.new(0, 6, 0.5, 0),
		Size = UDim2.new(1 / #TAB_ORDER, -12, 0, 30)
	}, tabsFrame)
	ui.corner(activePill, UDim.new(0, 14))
	local tabButtons = {}
	--[[ Builds one button per tab. A tab takes presses on its slot's pill rect only, 6 px in from the
	slot's edges, so the gaps between the pills and the bar's margins are dead; layoutTabs places
	them. ]]
	for index, name in TAB_ORDER do
		tabButtons[name] = ui.text(tabsFrame, {Class = 'TextButton', Text = name, Size = 16, Weight = 'Medium',
			Color = name == 'Unload' and theme.Red or theme.Text, AlignX = Enum.TextXAlignment.Center, Props = {
				Name = name,
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.new((index - 1) / #TAB_ORDER, 6, 0.5, -1),
				Size = UDim2.new(1 / #TAB_ORDER, -12, 0, 30)
			}})
	end

	-- The pages.
	local pagesFrame = ui.new('Frame', {
		Name = 'Pages',
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 50),
		Size = UDim2.new(1, 0, 1, -50)
	}, window)
	--[[ The page a tab switch brings in fades up as it slides (ANIM_SPEC 1), through its own cards'
	properties (ui.fade), the cards on screen only, for the third of a second it lasts. Never through a
	CanvasGroup, which drew the whole page into one texture, soft past the texture limit, and drew it
	again every frame. Not on a phone, where the page only slides, cut at the scroller's sides. Off a
	phone nothing cuts it: wherever it is more than 96 px from its place, nothing of it shows. ]]
	layout.FadePages = not isMobile()

	--[[ Scrolling, as Slinky's (measured off its recording, 2026-11-12). A notch of the wheel moves the
	whole layout, tab bar and cards together, 30 px at 1080p -- 30 of the window's units -- at once:
	no easing, no follow, nothing carried over, and notches add up. It stops hard at the top (the tab
	bar at 12) and at the foot, where the lowest card ends 8 above the screen's edge (8 above the key
	footer here, which Slinky has not), with no overscroll and no bar; a page shorter than the screen
	does not move. The foot is taken from the cards' drawn heights, so it follows a card opening or
	closing, and a page that shrinks brings the view back with it, at once. The wheel works wherever
	the pointer is while the menu is up, except over a list that scrolls by itself, and it does not
	zoom the camera meanwhile. Y is how far the layout is up, in the menu's units; on a touch screen
	the engine's drag moves it instead (its CanvasPosition), on the same stops. ]]
	-- Offsets: each page's own Y while another shows (showPages); Key: the page Y is for; Want: the
	-- offset of the page just put back, while it is still being restored (scroll.update).
	local scroll = {Y = 0, Max = 0, Offsets = {}}
	layout.Scroll = scroll
	-- How far the open still has the window's contents up (OpenMotion), in the menu's units.
	layout.Lift = 0
	-- How far what shows in the window is moved, up by the lift and the scroll: the tab bar's and the
	-- page showing's Y offset, in the window's own units (layout.shiftShown).
	layout.ShiftY = 0
	--[[ The open's lift and, with a mouse, the scroll, on what shows: the tab bar and each page showing
	move by them inside the window, which itself stays under the top margin. Not the window: every page
	is in it, the hidden ones too (some 24,000 GUI objects with every card's settings), and Roblox
	repositions each of them whenever the window moves, about 9 ms a frame at 1080p through the open's
	slide and on every wheel notch (measured live, 2026-11-20). The hidden pages stay put. The shift is
	where the window used to go less where it stays, in the window's own units: the same pixels on
	screen at the window's zoom 1, and within half a window unit at another zoom. A page put on show
	takes it at once (showPages), and a sliding page carries it (TabMotion). ]]
	function layout.shiftShown()
		local top = layout.Top or 12
		local placed = math.floor(top - (layout.Lift or 0) - (scroller and 0 or scroll.Y) + 0.5)
		local y = -math.floor((math.floor(top + 0.5) - placed) / math.max(layout.Zoom or 1, 0.05) + 0.5)
		layout.ShiftY = y
		if bar.Position.Y.Offset ~= y then
			bar.Position = UDim2.fromOffset(0, y)
		end
		for _, info in layout.Pages do
			local page = info.Frame
			if page.Visible then
				local position = page.Position
				if position.Y.Offset ~= y or position.Y.Scale ~= 0 then
					page.Position = UDim2.new(position.X.Scale, position.X.Offset, 0, y)
				end
			end
		end
	end
	--[[ The window and the key footer in their places: the window under the top margin, and the footer
	over the screen's foot and up by the open's lift, as what shows in the window is (layout.shiftShown).
	In whole units; a place already there is not written again. ]]
	function layout.placeWindow()
		local lift = layout.Lift or 0
		local y = math.floor((layout.Top or 12) + 0.5)
		local position = window.Position
		if position.Y.Offset ~= y or position.Y.Scale ~= 0 or position.X.Scale ~= 0.5 or position.X.Offset ~= 0 then
			window.Position = UDim2.new(0.5, 0, 0, y)
		end
		local foot = -math.floor((layout.Bottom or 12) + lift + 0.5)
		if footerHolder.Position.Y.Offset ~= foot then
			footerHolder.Position = UDim2.new(0.5, 0, 1, foot)
		end
		layout.shiftShown()
	end
	--[[ Rows moved under a still pointer get no enter or leave from Roblox: what is under it now lights
	and what moved away goes out, after the frame's move, and again on the pointer's first move after
	it (the wheel handler below). Hints follow their rows as well. ]]
	local function placeTips()
		scroll.TipsQueued = false
		if slinky.loaded == nil or not clickgui.Visible then return end
		if slinky.threadFix then
			setthreadidentity(8)
		end
		if ui.tooltipShown or next(ui.tooltipHovered) then
			pcall(ui.refreshTooltip)
		end
		pcall(ui.placeTips)
	end
	function scroll.moved()
		scroll.Moved = true
		ui.rehoverSoon()
		if scroll.TipsQueued then return end
		scroll.TipsQueued = true
		task.defer(placeTips)
	end
	-- The tallest of a page's columns so far, in screen pixels.
	local function tallest(height, column)
		if column and column.Visible then
			return math.max(height, column.AbsoluteSize.Y)
		end
		return height
	end
	--[[ Works out how far the menu can scroll: from the window's top (the 50 of the tab bar and its gap)
	to the showing page's lowest card, then 8 below it or the key footer's room, in the menu's units
	against the screen's height. Runs a frame after what changed it (scroll.request). A page just
	put back wants its own offset (scroll.Want), but its cards can still be on their way back, so a
	short end only holds it down for now; the offset is kept until the page is tall enough, the user
	scrolls, another page shows, or the menu has been up for half a second. ]]
	function scroll.update()
		if not window.Parent then return end
		local s = math.max(scale.Scale, 0.05)
		local factor = layout.Zoom or 1
		local height = 0
		for _, info in layout.Pages do
			if info.Frame.Visible then
				if info.List then
					height = math.max(height, info.List.AbsoluteContentSize.Y)
				else
					height = tallest(height, info.Left)
					height = tallest(height, info.Mid)
					height = tallest(height, info.Right)
					height = tallest(height, info.Empty)
				end
			end
		end
		local foot = (layout.Top or 12) + (50 + height / (s * factor)) * factor
		if layout.FooterClear then
			foot += layout.FooterClear * factor + (layout.Bottom or 12)
		else
			foot += 8 * factor
		end
		local camera = gameCamera or workspace.CurrentCamera
		local screen = (camera and camera.ViewportSize.Y or clickgui.AbsoluteSize.Y) / s
		local max = screen > 0 and math.max(foot - screen, 0) or 0
		scroll.Max = max
		local target
		local want = scroll.Want
		if want then
			local now = scroller and scroller.CanvasPosition.Y or scroll.Y
			if (want.Applied and math.abs(now - want.Applied) > 0.5) or (want.Until and os.clock() >= want.Until) then
				scroll.Want = nil
			else
				target = math.min(want.Y, max)
				want.Applied = target
				if max >= want.Y then
					scroll.Want = nil
				elseif clickgui.Visible and not want.Until then
					want.Until = os.clock() + 0.5
				end
			end
		end
		if scroller then
			local canvas = math.ceil(foot)
			if scroller.CanvasSize.Y.Offset ~= canvas then
				scroller.CanvasSize = UDim2.fromOffset(0, canvas)
			end
			if target then
				if scroller.CanvasPosition.Y ~= target then
					scroller.CanvasPosition = Vector2.new(0, target)
				end
			elseif scroller.CanvasPosition.Y > max then
				scroller.CanvasPosition = Vector2.new(0, max)
			end
		elseif target and scroll.Y ~= target then
			scroll.Y = target
			layout.placeWindow()
			scroll.moved()
		elseif scroll.Y > max then
			scroll.Y = max
			layout.placeWindow()
			scroll.moved()
		end
	end
	-- Only a request, from inside a size change or a layout pass: the end is worked out once, next.
	local function runUpdate()
		scroll.Queued = false
		if slinky.loaded == nil then return end
		if slinky.threadFix then
			setthreadidentity(8)
		end
		pcall(scroll.update)
	end
	function scroll.request()
		if scroll.Queued then return end
		scroll.Queued = true
		task.defer(runUpdate)
	end
	--[[ Moves the scroll by one wheel notch, or part of one at either end, at once with no tween. The
	user's own scroll cancels a page offset still being put back (scroll.Want). ]]
	function scroll.by(delta)
		scroll.Want = nil
		local y = math.clamp(scroll.Y + delta, 0, scroll.Max)
		if y == scroll.Y then return end
		scroll.Y = y
		layout.placeWindow()
		scroll.moved()
	end
	--[[ The camera's own wheel zoom is sunk while the menu is up, as the wheel does nothing else with a
	Minecraft screen open. Bound and unbound by layout.MenuShown, after the menu's change. ]]
	local contextActions = cloneref(game:GetService('ContextActionService'))
	function scroll.sink(on)
		pcall(function()
			contextActions:UnbindAction('PistonwareMenuWheel')
		end)
		if on then
			pcall(function()
				contextActions:BindActionAtPriority('PistonwareMenuWheel', function()
					return Enum.ContextActionResult.Sink
				end, false, Enum.ContextActionPriority.High.Value + 100, Enum.UserInputType.MouseWheel)
			end)
		end
	end
	slinky:clean(function()
		scroll.sink(false)
	end)
	--[[ With a mouse (no scroller) the wheel scrolls the menu while it is up, not under a modal or while
	the HUD is being moved; wheel down (Z below 0) shows what is further down. A list that scrolls
	by itself, such as a long dropdown, takes the wheel over it. The first mouse move after a scroll
	relights what is under the pointer (ui.rehoverSoon). ]]
	if not scroller then
		slinky:clean(inputService.InputChanged:Connect(function(input)
			local kind = input.UserInputType
			if kind == Enum.UserInputType.MouseMovement then
				if scroll.Moved then
					scroll.Moved = false
					ui.rehoverSoon()
				end
				return
			end
			if kind ~= Enum.UserInputType.MouseWheel then return end
			if not (clickgui.Visible and window.Visible) or layout.MovingHud or (ui.modal and ui.modal.Parent) then return end
			local notches = input.Position.Z
			if notches ~= notches or notches == 0 then return end
			local point = inputService:GetMouseLocation() + scaledgui.AbsolutePosition
			for list in layout.InnerLists do
				if list.Parent and ui.within(point, list.AbsolutePosition, list.AbsoluteSize) and ui.rowShowing(list, point) then
					return
				end
			end
			scroll.by(-notches * 30 * (layout.Zoom or 1))
		end))
	end

	--[[ Makes a tab's page: a plain frame as tall as its tallest column, cut by nothing but the screen.
	With a mouse the scroll moves the page itself (layout.shiftShown); on a phone the scroller moves
	the window holding it. The columns are Left, Right and, between them, Mid for Layout > Wide's
	third column; a column of the showing page changing size moves the scroll's end. The search page
	has no empty-tab text, so a search that finds nothing shows a blank page. ]]
	local function makePage(name)
		local page = ui.new('Frame', {
			Name = name,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Size = UDim2.fromScale(1, 1),
			Visible = false
		}, pagesFrame)
		local function column(frameName)
			local frame = ui.new('Frame', {
				Name = frameName,
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
				Size = UDim2.new(0.5, -theme.Gap / 2, 0, 0),
				Visible = frameName ~= 'Mid'
			}, page)
			ui.list(frame, theme.Gap)
			frame:GetPropertyChangedSignal('AbsoluteSize'):Connect(function()
				if page.Visible then
					scroll.request()
				end
			end)
			return frame
		end
		local left, mid, right = column('Left'), column('Mid'), column('Right')
		right.Position = UDim2.new(0.5, theme.Gap / 2, 0, 0)
		local empty = name ~= 'Search' and ui.text(page, {Text = 'Nothing in this tab here.', Size = 15, Color = theme.Muted, AlignX = Enum.TextXAlignment.Center, Props = {
			Size = UDim2.new(1, 0, 0, 60),
			Visible = false
		}}) or nil
		layout.Pages[name] = {Frame = page, Left = left, Mid = mid, Right = right, Empty = empty}
	end
	for _, name in TABS do
		makePage(name)
	end

	-- The Profiles page, a plain frame as the tabs' are; its list's height is the scroll's end.
	local profilesPage = ui.new('Frame', {
		Name = 'Profiles',
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Visible = false
	}, pagesFrame)
	local profilesList = ui.list(profilesPage, theme.Gap)
	profilesList:GetPropertyChangedSignal('AbsoluteContentSize'):Connect(function()
		if profilesPage.Visible then
			scroll.request()
		end
	end)
	layout.Pages.Profiles = {Frame = profilesPage, List = profilesList}

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
	--[[ Shows the current tab's page, or the search page while a search is open, blank until something
	is typed. Each tab's page keeps its own scroll offset, also while the menu is shut: leaving one
	notes where it was, and coming back puts it there again, brought within the page's end by
	scroll.update. The search page starts at the top. On a phone the offset is applied once the
	canvas has the page's size, or the engine would cut it short. ]]
	local function showPages()
		local searching = layout.Search ~= '' or layout.SearchOpen == true
		for tab, info in layout.Pages do
			info.Frame.Visible = (searching and tab == 'Search') or (not searching and tab == currentTab)
		end
		layout.shiftShown()
		local key = searching and 'Search' or currentTab
		if key ~= scroll.Key then
			if scroll.Key then
				local now = scroller and scroller.CanvasPosition.Y or scroll.Y
				local want = scroll.Want
				if want and (want.Applied == nil or math.abs(now - want.Applied) <= 0.5) then
					now = want.Y
				end
				scroll.Offsets[scroll.Key] = now
			end
			local y = key ~= 'Search' and scroll.Offsets[key] or 0
			scroll.Key = key
			scroll.Want = {Y = y, Applied = not scroller and y or nil}
			if not scroller and y ~= scroll.Y then
				scroll.Y = y
				layout.placeWindow()
				scroll.moved()
			end
		end
		scroll.request()
	end

	--[[ A tab switch, as Slinky's (ANIM_SPEC 1). The old page goes at once. The pill follows to the new
	slot at 21.9 a second, its width kept, and the new page slides in from the side the pill left:
	1.536 px for every pixel the pill still has to go, invisible until it is within 96 px (faded card
	by card, ui.fade, off a phone). The page is placed off the pill each frame, so a click mid-way
	simply carries on from where the pill is. X and Target are the pill's offset from the bar's left
	in its own units, less the 6 px inset. Unload asks first, and the pill stays. ]]
	layout.TabMotion = {Owner = activePill, X = 0, Target = 0, Index = 1, Slots = 1}
	--[[ The tab switch's motion (layout.TabMotion): the pill slides to the new slot and the new page
	slides in with it, its cards fading by the distance left. Positions are drawn in whole units,
	and a value that has not moved is not written again. At rest the pill's position is a fraction
	of the bar, which keeps it right through a resize. Finish ends a switch, or one cut short, with
	the pill, the page and every faded card at rest. ]]
	do
		local motion = layout.TabMotion
		function motion.Rest()
			activePill.Position = UDim2.new((motion.Index - 1) / math.max(motion.Slots, 1), 6, 0.5, 0)
		end
		function motion.Draw()
			local pillX = 6 + math.floor(motion.X + 0.5)
			if pillX ~= motion.PillX then
				motion.PillX = pillX
				activePill.Position = UDim2.new(0, pillX, 0.5, 0)
			end
			local page = motion.Page
			if page then
				local offset = (motion.X - motion.Target) * 1.536
				local pageX = math.floor(offset + 0.5)
				if pageX ~= motion.PageX then
					motion.PageX = pageX
					page.Position = UDim2.fromOffset(pageX, layout.ShiftY)
				end
				local parts = motion.Parts
				if parts then
					ui.fade.draw(parts, math.clamp(math.abs(offset) / 96, 0, 1))
				end
			end
		end
		function motion.Step(dt)
			motion.X = ui.anim.follow(motion.X, motion.Target, theme.FollowFast, dt)
			if math.abs(motion.Target - motion.X) < 0.01 then
				motion.Finish()
				return true
			end
			motion.Draw()
		end
		function motion.Finish()
			motion.X = motion.Target
			motion.PillX, motion.PageX = nil, nil
			motion.Rest()
			local page, parts = motion.Page, motion.Parts
			motion.Page, motion.Parts = nil, nil
			if page then
				page.Position = UDim2.fromOffset(0, layout.ShiftY)
			end
			if parts then
				ui.fade.finish(parts)
			end
			pagesFrame.ClipsDescendants = false
		end
	end
	--[[ Ends a switch still moving: before the bar is re-spaced, as the search opens or closes, and as
	the menu shuts. An open still coming in ends with it there, as the bar is about to change under it.
	A tab click (keepOpen) lets the open carry on, as Slinky's is one tween a click does not cut short. ]]
	function layout.FinishTabMotion(keepOpen)
		if not keepOpen and layout.FinishOpenMotion then
			layout.FinishOpenMotion()
		end
		ui.anim.stop(activePill, true)
	end
	ui.whenShut(layout.FinishTabMotion)

	--[[ The menu coming in, as Slinky's (measured off its recording, SPEC 3): the page, tab bar and key
	footer fully opaque from the first frame, 50 px above their place (in the window's own zoom),
	dropping into it with Quint Out over 0.30 s; the screen behind darkens with Quint Out over 0.28 s
	to the dim's usual 0.75. Nothing fades. It goes at once, window and dim in the same frame. Started
	from the menu's deferred Visible watcher (layout.MenuShown), never inside the change. The same on
	a phone. Not while the HUD is being moved. ]]
	layout.OpenMotion = {Owner = window, T = 0}
	--[[ The menu's open motion (layout.OpenMotion): the tab bar and the showing page drop the last 50 px
	into place over 0.30 s while the dim darkens over 0.28 s, both on Quint Out, to a transparency
	of 0.25. The scroll stays where it was. A hint that comes up part way rides along with its row
	as it drops. ]]
	do
		local motion = layout.OpenMotion
		local SLIDE, DARKEN = 0.30, 0.28
		function motion.Draw(t)
			local p = ui.anim.quintOut(math.min(t / SLIDE, 1))
			layout.Lift = math.floor(50 * (layout.Zoom or 1) * (1 - p) + 0.5)
			layout.placeWindow()
			local shade = 1 - 0.75 * ui.anim.quintOut(math.min(t / DARKEN, 1))
			if dim.BackgroundTransparency ~= shade then
				dim.BackgroundTransparency = shade
			end
		end
		function motion.Step(dt)
			motion.T += dt
			if motion.T >= SLIDE then
				motion.Finish()
				return true
			end
			motion.Draw(motion.T)
			motion.Tips()
		end
		function motion.Tips()
			if ui.tooltipShown then
				pcall(ui.refreshTooltip)
			end
			pcall(ui.placeTips)
		end
		function motion.Finish()
			layout.Lift = 0
			layout.placeWindow()
			dim.BackgroundTransparency = 0.25
			motion.Tips()
		end
		function motion.Start()
			ui.anim.stop(window, true)
			motion.T = 0
			motion.Draw(0)
			ui.anim.play(window, motion)
		end
	end
	function layout.FinishOpenMotion()
		ui.anim.stop(window, true)
	end
	--[[ Called when the menu opens or shuts, from its deferred Visible watcher only; owns the dim's
	Visible. The wheel belongs to the menu while it is up (layout.Scroll); a touch screen has none.
	Opening starts the open motion, shutting finishes it at once. ]]
	function layout.MenuShown(open)
		local shown = open == true and not layout.MovingHud
		dim.Visible = shown
		scroll.sink(open == true and not scroller)
		scroll.request()
		if shown then
			layout.OpenMotion.Start()
			if layout.CheckFits then
				layout.CheckFits()
			end
		else
			layout.FinishOpenMotion()
		end
	end

	--[[ Switches to a tab; Unload asks for confirmation and unloads instead. The pill and the page slide
	from where the pill is now, mid-switch or in the old tab's slot. What the tab does as it opens
	(layout.TabShown, the FFlags list expanding) starts first, so it fades in with the page. With
	the menu shut, the search open or the same tab, it goes straight there. ]]
	local function selectTab(name)
		if name == 'Unload' then
			ui.confirm('Unload Pistonware from this game?', function()
				slinky:unload()
			end, 'Unload')
			return
		end
		local motion = layout.TabMotion
		local visible = visibleTabs()
		local slot = tabsFrame.AbsoluteSize.X / (math.max(scale.Scale, 0.05) * (layout.Zoom or 1)) / math.max(#visible, 1)
		local from = ui.anim.playing(activePill) and motion.X or ((table.find(visible, currentTab) or 1) - 1) * slot
		layout.FinishTabMotion(true)
		currentTab = name
		showPages()
		if layout.TabShown[name] then
			task.spawn(layout.TabShown[name])
		end
		local index = table.find(visible, name) or 1
		local info = layout.Pages[name]
		motion.Index, motion.Slots = index, #visible
		motion.X, motion.Target = from, (index - 1) * slot
		if not (info and slot > 0 and ui.anim.onScreen(activePill)) or math.abs(motion.Target - from) < 0.5 then
			motion.Finish()
		else
			local page = info.Frame
			motion.Page = page
			if layout.FadePages then
				motion.Parts = ui.fade.new()
				ui.fade.page(motion.Parts, page)
			end
			motion.Draw()
			ui.anim.play(activePill, motion)
		end
		layout.request(name)
	end
	component.selectTab = selectTab

	--[[ Re-spaces the bar over the showing tabs and moves the pill with them; the last slot is the
	search magnifier's. A switch still moving ends first, as the slots are about to change under it.
	]]
	local function layoutTabs()
		layout.FinishTabMotion()
		local visible = visibleTabs()
		local slots = #visible + 1
		tabsFrame.Size = UDim2.new(#visible / slots, 0, 1, 0)
		for name, button in tabButtons do
			local index = table.find(visible, name)
			button.Visible = index ~= nil
			if index then
				button.Position = UDim2.new((index - 1) / #visible, 6, 0.5, -1)
				button.Size = UDim2.new(1 / #visible, -12, 0, 30)
			end
		end
		activePill.Size = UDim2.new(1 / #visible, -12, 0, 30)
		activePill.Position = UDim2.new(((table.find(visible, currentTab) or 1) - 1) / #visible, 6, 0.5, 0)
		if layout.SearchButton then
			layout.SearchButton.Position = UDim2.new((slots - 0.5) / slots, 0, 0.5, 0)
			layout.SearchButton.Size = UDim2.new(1 / slots, -12, 0, 30)
		end
		if layout.SearchField then
			layout.SearchField.Size = UDim2.new(#visible / slots, 0, 1, 0)
		end
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

	--[[ Wires each tab to selectTab. Under the pointer a tab's name goes white and Unload's red a
	lighter red (#EE5758), with nothing drawn behind it; never on a touch screen (ui.hover). ]]
	for name, button in tabButtons do
		button.MouseButton1Click:Connect(function()
			selectTab(name)
		end)
		local unload = name == 'Unload'
		ui.hover(button, function()
			button.TextColor3 = unload and theme.RedHover or theme.Lit
		end, function()
			button.TextColor3 = unload and theme.Red or theme.Text
		end)
	end

	--[[ Search: the magnifier at the right of the bar swaps the tabs for a field, and what is typed
	shows every card whose name or shown name contains it, across all the tabs, on a page of its
	own. The cross in the button's place closes it and brings the tabs back. The magnifier is the
	uploaded SEARCH_IMAGE; the cross, and the magnifier while SEARCH_IMAGE is empty, are built from
	frames on Lucide's 24-unit grid, because a phone has no icon files and these must never fall
	back to a text character.

	Closing fades on the menu's open curve, theme.ModalInfo (0.3 s Quint Out): the field and the
	cross go out as the tabs, the magnifier and the tab's page come back, the page card by card
	(ui.fade), while the search page goes at once. The field keeps its text, out of the keyboard's
	reach, until the end. On a phone (no FadePages) it closes at once.

	Opening puts the cursor in the box, timed in seconds rather than frames: with the frame rate
	unlocked a count of frames is over in a few hundredths of a second, and a box that has only just
	become visible can turn CaptureFocus down for longer. For two seconds a focus lost with no
	click, tap, Enter, Tab or Escape behind it is taken back, up to eight times, at about sixty
	tries a second whatever the frame rate; a newer open or a close ends an older run. Escape closes
	the search through the menu's Escape stack (ui.escape); typing in the box, it is caught as the
	reason the focus went. Not while a bind waits for a key, where Escape clears the bind. ]]
	do
		local SEARCH_IMAGE = 'rbxassetid://70621958076101'
		local function glyph(parent, size, cross)
			local k = size / 24
			local holder = ui.new('Frame', {
				Name = cross and 'Cross' or 'Magnifier',
				AnchorPoint = Vector2.new(0.5, 0.5),
				BackgroundTransparency = 1,
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(size, size)
			}, parent)
			local parts = {}
			local function stroke(cx, cy, length, rotation)
				local piece = ui.new('Frame', {
					AnchorPoint = Vector2.new(0.5, 0.5),
					BackgroundColor3 = theme.Text,
					BorderSizePixel = 0,
					Position = UDim2.fromOffset(cx * k, cy * k),
					Rotation = rotation,
					Size = UDim2.fromOffset(length * k, 2 * k)
				}, holder)
				ui.corner(piece, UDim.new(1, 0))
				table.insert(parts, piece)
			end
			if cross then
				stroke(12, 12, 18.97, 45)
				stroke(12, 12, 18.97, -45)
			elseif SEARCH_IMAGE ~= '' then
				table.insert(parts, ui.new('ImageLabel', {
					Name = 'Glyph',
					BackgroundTransparency = 1,
					Image = SEARCH_IMAGE,
					ImageColor3 = theme.Text,
					Size = UDim2.fromScale(1, 1)
				}, holder))
			else
				local ring = ui.new('Frame', {
					BackgroundTransparency = 1,
					Position = UDim2.fromOffset(4 * k, 4 * k),
					Size = UDim2.fromOffset(14 * k, 14 * k)
				}, holder)
				ui.corner(ring, UDim.new(1, 0))
				table.insert(parts, ui.new('UIStroke', {
					ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
					Color = theme.Text,
					Thickness = 2 * k
				}, ring))
				stroke(18.85, 18.85, 8.08, 45)
			end
			local function paint(value)
				for _, part in parts do
					if part:IsA('ImageLabel') then
						part.ImageColor3 = value
					elseif part:IsA('UIStroke') then
						part.Color = value
					else
						part.BackgroundColor3 = value
					end
				end
			end
			return holder, paint
		end

		local searchButton = ui.new('TextButton', {
			Name = 'Search',
			AnchorPoint = Vector2.new(0.5, 0.5),
			AutoButtonColor = false,
			BackgroundColor3 = theme.Pill,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Text = ''
		}, bar)
		ui.corner(searchButton, UDim.new(0, 14))
		local magnifier, paintMagnifier = glyph(searchButton, 16)
		local cross, paintCross = glyph(searchButton, 16, true)
		cross.Visible = false
		ui.hover(searchButton, function()
			paintMagnifier(theme.Lit)
			paintCross(theme.Lit)
		end, function()
			paintMagnifier(theme.Text)
			paintCross(theme.Text)
		end)
		layout.SearchButton = searchButton

		local searchField = ui.new('Frame', {
			Name = 'SearchField',
			BackgroundTransparency = 1,
			Size = UDim2.new(1, -42, 1, 0),
			Visible = false
		}, bar)
		layout.SearchField = searchField
		local fieldIcon = glyph(searchField, 16)
		fieldIcon.Position = UDim2.new(0, 21, 0.5, 0)
		local searchBox = ui.text(searchField, {Class = 'TextBox', Size = 16, Color = theme.Text, Props = {
			ClearTextOnFocus = false,
			PlaceholderColor3 = theme.Muted,
			PlaceholderText = 'Search modules',
			Position = UDim2.fromOffset(40, 0),
			Size = UDim2.new(1, -48, 1, 0)
		}})

		makePage('Search')

		local function setSearch(text)
			layout.Search = text:lower():gsub('^%s+', ''):gsub('%s+$', '')
			showPages()
			layout.request('*')
		end
		local focusToken = 0
		local focusUntil = 0
		local closeMotion = {Owner = window, T = 0}
		function closeMotion.Draw(p)
			if closeMotion.Out then
				ui.fade.draw(closeMotion.Out, p)
			end
			if closeMotion.In then
				ui.fade.draw(closeMotion.In, 1 - p)
			end
		end
		function closeMotion.Step(dt)
			closeMotion.T += dt
			local duration = theme.ModalInfo.Time
			if closeMotion.T >= duration then
				closeMotion.Finish()
				return true
			end
			closeMotion.Draw(ui.anim.quintOut(closeMotion.T / duration))
		end
		function closeMotion.Finish()
			local out, back = closeMotion.Out, closeMotion.In
			closeMotion.Out, closeMotion.In = nil, nil
			if back then
				ui.fade.finish(back)
			end
			if out then
				searchField.Visible = false
				cross.Visible = false
				ui.fade.finish(out)
				searchBox.TextEditable = true
				searchBox.Text = ''
			end
		end
		local function closeSearch()
			ui.popEscape(searchField)
			layout.FinishTabMotion()
			ui.anim.stop(searchField, true)
			focusToken += 1
			focusUntil = 0
			local fading = layout.FadePages and ui.anim.onScreen(searchField)
			if fading then
				pcall(function()
					searchBox:ReleaseFocus()
				end)
				searchBox.TextEditable = false
				closeMotion.Out = ui.fade.new()
				ui.fade.add(closeMotion.Out, searchField)
				ui.fade.add(closeMotion.Out, cross)
			else
				searchBox.Text = ''
				searchField.Visible = false
				cross.Visible = false
			end
			setSearch('')
			layout.SearchOpen = false
			showPages()
			tabsFrame.Visible = true
			magnifier.Visible = true
			if fading then
				local back = ui.fade.new()
				ui.fade.add(back, tabsFrame)
				ui.fade.add(back, magnifier)
				local info = layout.Pages[currentTab]
				if info and info.Frame.Visible then
					ui.fade.page(back, info.Frame)
				end
				closeMotion.In = back
				closeMotion.T = 0
				closeMotion.Draw(0)
				ui.anim.play(searchField, closeMotion)
			end
		end
		local function boxFocused()
			local ok, focused = pcall(function()
				return searchBox:IsFocused()
			end)
			if ok and focused == true then return true end
			local found, box = pcall(function()
				return inputService:GetFocusedTextBox()
			end)
			return found and box == searchBox
		end
		local function openSearch()
			ui.anim.stop(searchField, true)
			layout.FinishTabMotion()
			searchField.Visible = true
			layout.SearchOpen = true
			showPages()
			tabsFrame.Visible = false
			magnifier.Visible, cross.Visible = false, true
			ui.pushEscape(searchField, closeSearch, function()
				return searchField.Visible
			end)
			focusToken += 1
			local token = focusToken
			focusUntil = os.clock() + 2
			task.spawn(function()
				local focusedPasses, retakes, lastTry = 0, 0, -1
				while true do
					task.wait()
					if token ~= focusToken or os.clock() > focusUntil then return end
					if not (searchField.Visible and clickgui.Visible and window.Visible) then return end
					if boxFocused() then
						focusedPasses += 1
					else
						if focusedPasses > 0 then
							retakes += 1
							if retakes > 8 then return end
						end
						focusedPasses = 0
						if os.clock() - lastTry >= 0.015 then
							lastTry = os.clock()
							pcall(function()
								searchBox:CaptureFocus()
							end)
						end
					end
				end
			end)
		end
		searchButton.MouseButton1Click:Connect(function()
			if layout.SearchOpen then
				closeSearch()
			else
				openSearch()
			end
		end)
		searchBox:GetPropertyChangedSignal('Text'):Connect(function()
			setSearch(searchBox.Text)
		end)

		local function escapeSearch()
			if layout.SearchOpen and clickgui.Visible and not slinky.binding then
				ui.escapeLater('focus')
			end
		end
		searchBox.FocusLost:Connect(function(enterPressed, input)
			local key, kind
			pcall(function()
				key, kind = input.KeyCode, input.UserInputType
			end)
			if key == Enum.KeyCode.Escape then
				focusUntil = 0
				escapeSearch()
				return
			end
			if enterPressed or key == Enum.KeyCode.Return or key == Enum.KeyCode.KeypadEnter or key == Enum.KeyCode.Tab
				or kind == Enum.UserInputType.MouseButton1 or kind == Enum.UserInputType.MouseButton2
				or kind == Enum.UserInputType.MouseButton3 or kind == Enum.UserInputType.Touch then
				focusUntil = 0
			end
		end)
	end
	-- The search button and field exist now: into their slots.
	layoutTabs()

	--[[ Two columns when they fit, one on a narrow screen, and three with Layout > Wide on a screen
	wide enough. The window is in GUI units, which the UIScale shrinks with the screen. With Auto
	rescale on, the window also gets a zoom of its own:
	the rescale that keeps the HUD in proportion would leave the menu under half a phone wide with
	7px text. It is sized to the screen instead, up to 0.85, and never below the HUD's scale. The
	manual Scale slider is left exactly as set. ]]
	local zoom = ui.new('UIScale', {Scale = 1}, window)
	-- The window's width: Slinky's two columns, or its Wide layout's three.
	local NARROW, WIDE = 876, 1476
	--[[ Fits the menu to the screen: the window's width, its zoom (layout.Zoom), the top and bottom
	margins, the tab text size and the number of columns. Wide is used only where an Auto zoom of at
	least 0.7 keeps it readable. The ScreenGui ignores the inset, so on a phone the window starts
	below the top bar and Roblox's buttons, and the key footer keeps clear of the rounded corners
	and the home indicator; desktop keeps 12 at both ends. The confirm dialog and the colour picker
	open at layout.Top. Tab text is 16 em px at 876 and 1476 wide and 10 on the single-column bar.
	]]
	local function resize()
		if not window.Parent then return end
		local s = math.max(scale.Scale, 0.05)
		local camera = gameCamera or workspace.CurrentCamera
		local pxWidth = viewportWidth()
		local pxHeight = camera and camera.ViewportSize.Y or 0
		local avail = pxWidth - 16
		local autoOn = slinky.scale and slinky.scale.enabled and pxHeight > 0 and avail > 0
		local useWide = layout.Wide and not (autoOn and avail / WIDE < 0.7)
		local maxWidth = useWide and WIDE or NARROW
		local width, factor = math.floor(math.min(maxWidth, math.max(pxWidth / s - 16, 320))), 1
		if autoOn then
			local target = useWide and WIDE or (avail / NARROW < 0.55 and theme.CardWidth + 8 or NARROW)
			if target * s <= avail then
				width = target
				factor = math.max(s, math.min(avail / width, 0.85)) / s
			end
		end
		layout.Zoom = factor
		zoom.Scale = factor
		local top, bottom = 12, 12
		if isMobile() then
			local ok, inset, insetBottom = pcall(function()
				return guiService:GetGuiInset()
			end)
			if ok and typeof(inset) == 'Vector2' then
				top = math.max(12, (inset.Y + 6) / s)
			end
			local edge = (ok and typeof(insetBottom) == 'Vector2' and insetBottom.Y or 0) + 16
			bottom = math.max(12, edge / s)
		end
		layout.Top, layout.Bottom = top, bottom
		if factor ~= 1 or top ~= 12 or bottom ~= 12 then
			window.Size = UDim2.new(0, width, 0, math.floor((pxHeight / s - top - bottom) / factor))
		else
			window.Size = UDim2.new(0, width, 1, -24)
		end
		if scroller then
			scroller.Size = UDim2.new(0, math.ceil(width * factor), 1, 0)
		end
		footerHolder.Size = UDim2.fromOffset(width, 32)
		footerZoom.Scale = factor
		layout.placeWindow()
		scroll.request()
		local tabSize = theme.em(math.clamp(math.floor((width / (#visibleTabs() + 1) - 6) / 4.6), 10, 16))
		for _, button in tabButtons do
			button.TextSize = tabSize
		end
		local columns = width >= 1100 and 3 or (width >= 700 and 2 or 1)
		if columns ~= layout.Columns then
			layout.Columns = columns
			layout.request('*')
		end
		local profiles = slinky.categories.Profiles
		if profiles and profiles.grid then
			profiles.grid.CellSize = UDim2.new(1 / columns, -theme.Gap * (columns - 1) / columns, 0, 72)
		end
	end
	component.resize = resize

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
	component.guiCard = staticCard('GUI', 'Graphical interface for the cheat.')
	component.notificationsCard = staticCard('Notifications', 'Informs you when certain actions are performed.')
	settingsHosts.Default = component.guiCard.Body
	settingsHosts.Notifications = component.notificationsCard.Body
	ui.text(component.guiCard.Body, {Text = 'Pistonware '..slinky.version, Size = 12, Color = theme.Muted, AlignX = Enum.TextXAlignment.Right, Props = {
		LayoutOrder = 100000, Name = 'Version', Size = UDim2.new(1, -theme.Inset * 2, 0, 22)
	}})

	local settingspane = components.settingsPane({
		name = 'Settings',
		main = true
	}, hiddenChildren, component)
	component.settings = settingspane

	function component:recolor(hue, sat, val, isRainbow) end

	-- The window's own entry of the settings file. Each pane is an entry of its own (slinky.settings).
	function component:load(entry)
		local x, y = store.spot(entry.__pos)
		if x then
			legacy.Position = UDim2.fromOffset(x, y)
		end
	end

	function component:save()
		return {
			__pos = {
				x = legacy.Position.X.Offset,
				y = legacy.Position.Y.Offset
			}
		}
	end

	bindComponents(component, hiddenChildren)

	slinky.categories.Main = component
	selectTab('Combat')
	resize()

	return object(component, 'Main')
end

-- A category's on/off flag, kept because the save file records one per category; nothing is drawn.
components.guiButton = function(props, children, api)
	local component = {
		name = props.name,
		index = getTableSize(api.buttons),
		enabled = false,
		row = ui.new('Frame', {Name = props.name, BackgroundTransparency = 1, Visible = false})
	}

	function component:Destroy()
		component.row:Destroy()
	end

	function component:flip()
		if props.window then
			self.enabled = not self.enabled
		elseif props.changed then
			props.changed()
		end
	end

	api.buttons[props.name] = component

	return object(component, nil, 'guiButton')
end

components.guiSlider = function(props, children, api)
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
		kind = 'guiSlider',
		custom = false,
		hue = defaultHue,
		notch = 2,
		rainbow = false,
		sat = defaultSat,
		value = defaultValue
	}

	local slider = ui.new('Frame', {
		Name = props.name..'Slider',
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0)
	}, children)
	component.row = slider
	ui.list(slider, 0)
	local line = ui.row(slider, {order = 1})
	ui.rowLabel(line, {name = 'Accent color'}, 60)
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
	-- Slinky's 1 px ring round the swatch.
	ui.stroke(swatch, theme.Outline, 1, 0)
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
			component:set(nil, nil, nil, index)
		end)
	end
	local reset = ui.text(presets, {Class = 'TextButton', Text = 'RESET', Size = 12, Weight = 'Bold', Color = theme.SubText, AlignX = Enum.TextXAlignment.Center, Props = {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -theme.Inset, 0.5, 0), Size = UDim2.fromOffset(52, 24)
	}})
	-- RESET and COPY go white under the pointer, as a key badge's text does.
	ui.hover(reset, function()
		reset.TextColor3 = theme.Lit
	end, function()
		reset.TextColor3 = theme.SubText
	end)
	reset.MouseButton1Click:Connect(function()
		component:set(nil, nil, nil, 2)
	end)
	-- COPY puts the accent's hex code on the clipboard, and says so for a moment. A longer word (NO
	-- CLIPBOARD) widens it leftward, away from RESET.
	local copy = ui.text(presets, {Class = 'TextButton', Text = 'COPY', Size = 12, Weight = 'Bold', Color = theme.SubText, AlignX = Enum.TextXAlignment.Center, Props = {
		AnchorPoint = Vector2.new(1, 0.5), AutomaticSize = Enum.AutomaticSize.X, Position = UDim2.new(1, -theme.Inset - 56, 0.5, 0), Size = UDim2.fromOffset(52, 24)
	}})
	ui.hover(copy, function()
		copy.TextColor3 = theme.Lit
	end, function()
		copy.TextColor3 = theme.SubText
	end)
	local copyStamp = 0
	copy.MouseButton1Click:Connect(function()
		local setter = setclipboard or toclipboard or set_clipboard
		local hex = '#'..Color3.fromHSV(component.hue, component.sat, component.value):ToHex():upper()
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

	--[[ One track of the accent picker: its caption, the gradient bar with its knob from 40% of the row,
	and a hit area over the row's right 60%. ]]
	local function pickerTrack(name, gradientColor, value)
		local row = ui.row(picker, {}, 26)
		ui.text(row, {Text = name, Size = 13, Color = theme.SubText, Props = {
			Position = UDim2.fromOffset(theme.Inset + 12, 0), Size = UDim2.new(0.4, -(theme.Inset * 3 + 8), 0, 26)
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
	local colorSlider = pickerTrack('Custom color', ColorSequence.new(rainbowTable), component.hue)
	local satSlider = pickerTrack('Saturation', ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromHSV(0, 0, component.value)),
		ColorSequenceKeypoint.new(1, Color3.fromHSV(component.hue, 1, component.value))
	}), component.sat)
	local vibSlider = pickerTrack('Vibrance', ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromHSV(0, 0, 0)),
		ColorSequenceKeypoint.new(1, Color3.fromHSV(component.hue, component.sat, 1))
	}), component.value)

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
	props.changed = props.changed or function() end
	local rainbowthread

	--[[ Repaints the accent swatch, fading 73% of the way into the card as Slinky's does, the ring on
	the chosen preset, and the knobs while the picker is open. ]]
	local function paint()
		local base = Color3.fromHSV(component.hue, component.sat, component.value)
		swatchGradient.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, base),
			ColorSequenceKeypoint.new(1, base:Lerp(theme.Card, 0.73))
		})
		for index, preset in presetButtons do
			preset.Ring.Enabled = not component.rainbow and not component.custom and component.notch == index
		end
		if picker.Visible then
			colorSlider.Knob.Position = UDim2.fromScale(math.clamp(component.hue, 0, 1), 0.5)
			satSlider.Knob.Position = UDim2.fromScale(math.clamp(component.sat, 0, 1), 0.5)
			vibSlider.Knob.Position = UDim2.fromScale(math.clamp(component.value, 0, 1), 0.5)
		end
	end

	-- Saved as {preset} on one of the presets above, else as its colour, with `rainbow` when it cycles.
	function component:load(value)
		if type(value) ~= 'table' then return end
		if (self.rainbow and true or false) ~= (value.rainbow == true) then
			self:flip()
		end

		if store.isColor(value) then
			self:set(store.hsv(value.r, value.g, value.b))
		elseif isFiniteNumber(value.preset) then
			self:set(nil, nil, nil, value.preset)
		end
	end

	function component:save()
		if not self.rainbow and not self.custom and self.notch then
			return {preset = self.notch}
		end
		local value = store.color(self.hue, self.sat, self.value)
		value.rainbow = self.rainbow or nil
		return value
	end

	--[[ Sets the accent colour. A preset number picks one of the seven presets (an unknown one falls
	back to the orange, 2) and turns the rainbow off; plain values mark the colour custom. Rebuilds
	the saturation and brightness gradients and reports the change; no save while the rainbow loop
	drives it, as with the colour option. ]]
	function component:set(h, s, v, n)
		if n and not colors[n] then
			n = 2
		end
		if n then
			if self.rainbow then
				self:flip()
			end

			self.custom = false
			h, s, v = colors[n]:ToHSV()
		else
			self.custom = true
		end

		self.hue = h or self.hue
		self.sat = s or self.sat
		self.value = v or self.value
		self.notch = n

		satSlider.Gradient.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromHSV(0, 0, self.value)),
			ColorSequenceKeypoint.new(1, Color3.fromHSV(self.hue, 1, self.value))
		})

		vibSlider.Gradient.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromHSV(0, 0, 0)),
			ColorSequenceKeypoint.new(1, Color3.fromHSV(self.hue, self.sat, 1))
		})
		paint()

		props.changed(self.hue, self.sat, self.value)
		if not self.rainbow then
			slinky:requestSave()
		end
	end

	function component:flip()
		self.rainbow = not self.rainbow
		if rainbowthread then
			task.cancel(rainbowthread)
			rainbowthread = nil
		end

		if self.rainbow then
			addRainbowSlider(self)
		else
			self:set(nil, nil, nil, 2)
			removeRainbowSlider(self)
		end
		rainbowSwitch:Set(self.rainbow)
		paint()
		slinky:requestSave()
	end

	function component:recolor(hue, sat, val, isRainbow)
		if self.rainbow then
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
				component:set(
					name == 'Custom color' and value or nil,
					name == 'Saturation' and value or nil,
					name == 'Vibrance' and value or nil
				)
			end)
		end)
	end

	rainbowHit.MouseButton1Click:Connect(function()
		component:flip()
	end)

	--[[ Applies a colour typed into the accent's box on Enter, as #rrggbb or r, g, b, and turns the
	rainbow off. 'nan' and 'inf' read as numbers and leave the colour as it is. The box is emptied
	either way. ]]
	hexbox.FocusLost:Connect(function(enter)
		if enter then
			local success, parsed = pcall(function()
				local commas = hexbox.Text:split(',')
				local r, g, b = tonumber(commas[1]), tonumber(commas[2]), tonumber(commas[3])
				if not r then
					return Color3.fromHex(hexbox.Text)
				end
				if math.abs(r) < math.huge and math.abs(g or 0) < math.huge and math.abs(b or 0) < math.huge then
					return Color3.fromRGB(r, g, b)
				end
				return nil
			end)

			if success and parsed then
				if component.rainbow then
					component:flip()
				end

				component:set(parsed:ToHSV())
			end
		end
		hexbox.Text = ''
	end)

	paint()
	api.options[props.name] = component

	return object(component, props.name)
end

-- An overlay's on/off: the switch on its card.
components.imageToggle = function(props, children, api)
	local component = {
		kind = 'imageToggle',
		index = getTableSize(api.options),
		enabled = false
	}

	local switch = ui.switch(props.switchParent or children, props.switchParent and UDim2.new(1, -theme.Inset, 0, 24) or nil)
	component.row = switch.Object
	props.changed = props.changed or function() end

	function component:recolor(hue, sat, val, isRainbow)
		if self.enabled then
			switch:Color(accentFor(self.index, 0.075, hue, sat, val, isRainbow))
		end
	end

	function component:flip()
		self.enabled = not self.enabled
		switch:Set(self.enabled, liveAccent(self.index))
		props.changed(self.enabled)
		slinky:requestSave()
	end

	if props.default then
		component:flip()
	end

	api.options[props.name] = component

	return object(component, props.name)
end

--[[ The colour modal for one entry of a list, on the shared modal card: the entry's name, its colour in
a flat square with the hex beside it (typed over as #rrggbb or r, g, b), then Hue, Saturation and
Lightness tracks in HSL, Lightness running black, the colour, white. Each knob shows its own track's
value: the hue knob the pure hue, the saturation knob that hue at its saturation, the lightness knob
the grey of its lightness. Then the eight colours used most recently, an empty one black. No Rainbow
and no Opacity. The HSL triple is kept while it is open, so a grey keeps the hue its knob was on.

Enter, or a phone's keyboard put away by a tap elsewhere, takes what was typed; 'nan' and 'inf' are
refused. Escape in the box closes the modal and leaves the menu up. Closing on another colour than
it opened on adds that colour to the recent ones. opts: Title, Color, OnChange(color),
OnClose(color). Returns the modal (ui.modalCard). ]]
function ui.colorModal(opts)
	opts = opts or {}
	local start = typeof(opts.Color) == 'Color3' and opts.Color or Color3.fromRGB(255, 0, 0)
	local state = {Color = start, Before = start:ToHex()}
	state.H, state.S, state.L = ui.toHsl(start)
	local modal = ui.modalCard({Name = 'ColorModal', Title = opts.Title or 'Color', FitHeight = 290, OnClose = function()
		if state.Color:ToHex() ~= state.Before then
			ui.rememberColor(state.Color)
		end
		if opts.OnClose then
			opts.OnClose(state.Color)
		end
	end})
	if not modal then return nil end
	local card = modal.Card

	local valueRow = ui.new('Frame', {BackgroundTransparency = 1, LayoutOrder = 2, Size = UDim2.new(1, 0, 0, 34), ZIndex = 22}, card)
	local square = ui.new('Frame', {
		Name = 'Swatch',
		AnchorPoint = Vector2.new(0, 0.5),
		BorderSizePixel = 0,
		Position = UDim2.new(0, 2, 0.5, 2),
		Size = UDim2.fromOffset(22, 22),
		ZIndex = 22
	}, valueRow)
	ui.corner(square, 4)
	ui.stroke(square, theme.Outline, 2, 0)
	local hex = ui.text(valueRow, {Class = 'TextBox', Size = 16, Color = theme.SubText, Props = {
		Name = 'Hex',
		ClearTextOnFocus = false,
		Position = UDim2.fromOffset(34, 2),
		Size = UDim2.new(1, -34, 1, 0),
		ZIndex = 22
	}})

	local function track(name, order)
		local section = ui.new('Frame', {Name = name, BackgroundTransparency = 1, LayoutOrder = order, Size = UDim2.new(1, 0, 0, 50), ZIndex = 22}, card)
		ui.text(section, {Text = name, Size = 15, Color = theme.SubText, Props = {Position = UDim2.fromOffset(0, 6), Size = UDim2.new(1, 0, 0, 20), ZIndex = 22}})
		local ring = ui.new('Frame', {
			Name = 'Track',
			AnchorPoint = Vector2.new(0, 0.5),
			BackgroundTransparency = 1,
			Position = UDim2.new(0, 2, 0, 37),
			Size = UDim2.new(1, -4, 0, 12),
			ZIndex = 22
		}, section)
		ui.corner(ring, UDim.new(1, 0))
		ui.stroke(ring, theme.Outline, 2, 0)
		local fill = ui.new('Frame', {Name = 'Fill', BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), ZIndex = 22}, ring)
		ui.corner(fill, UDim.new(1, 0))
		local knob = ui.new('Frame', {
			Name = 'Knob',
			AnchorPoint = Vector2.new(0.5, 0.5),
			BorderSizePixel = 0,
			Position = UDim2.fromScale(0, 0.5),
			Size = UDim2.fromOffset(18, 18),
			ZIndex = 23
		}, ring)
		ui.corner(knob, UDim.new(1, 0))
		ui.stroke(knob, Color3.new(1, 1, 1), 2, 0)
		local hit = ui.new('TextButton', {
			AutoButtonColor = false,
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(0, 24),
			Size = UDim2.new(1, 0, 0, 26),
			Text = '',
			ZIndex = 24
		}, section)
		return {Ring = ring, Gradient = ui.new('UIGradient', {}, fill), Knob = knob, Hit = hit}
	end
	local hue = track('Hue', 3)
	local sat = track('Saturation', 4)
	local light = track('Lightness', 5)
	local rainbow = {}
	for i = 0, 10 do
		table.insert(rainbow, ColorSequenceKeypoint.new(i / 10, Color3.fromHSV(i / 10, 1, 1)))
	end
	hue.Gradient.Color = ColorSequence.new(rainbow)

	local function paint()
		local h, s, l = state.H, state.S, state.L
		state.Color = ui.hsl(h, s, l)
		square.BackgroundColor3 = state.Color
		local typing = false
		pcall(function()
			typing = hex:IsFocused()
		end)
		if not typing then
			hex.Text = '#'..state.Color:ToHex():lower()
		end
		sat.Gradient.Color = ColorSequence.new(ui.hsl(h, 0, l), ui.hsl(h, 1, l))
		light.Gradient.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.new(0, 0, 0)),
			ColorSequenceKeypoint.new(0.5, ui.hsl(h, s, 0.5)),
			ColorSequenceKeypoint.new(1, Color3.new(1, 1, 1))
		})
		hue.Knob.Position = UDim2.fromScale(h, 0.5)
		sat.Knob.Position = UDim2.fromScale(s, 0.5)
		light.Knob.Position = UDim2.fromScale(l, 0.5)
		hue.Knob.BackgroundColor3 = ui.hsl(h, 1, 0.5)
		sat.Knob.BackgroundColor3 = ui.hsl(h, s, 0.5)
		light.Knob.BackgroundColor3 = Color3.new(l, l, l)
	end
	local function set(h, s, l)
		state.H, state.S, state.L = h or state.H, s or state.S, l or state.L
		paint()
		if opts.OnChange then
			opts.OnChange(state.Color)
		end
	end
	for index, entry in {hue, sat, light} do
		entry.Hit.InputBegan:Connect(function(input)
			if not isPress(input) then return end
			trackDrag(input, entry.Ring, function(value)
				if modal.Closed then return end
				if index == 1 then
					set(value)
				elseif index == 2 then
					set(nil, value)
				else
					set(nil, nil, value)
				end
			end)
		end)
	end

	local recentSection = ui.new('Frame', {AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, LayoutOrder = 6, Size = UDim2.new(1, 0, 0, 0), ZIndex = 22}, card)
	ui.list(recentSection, 4)
	ui.text(recentSection, {Text = 'Recently used', Size = 15, Color = theme.SubText, Props = {LayoutOrder = 1, Size = UDim2.new(1, 0, 0, 26), ZIndex = 22}})
	local boxes = ui.new('Frame', {Name = 'Recent', BackgroundTransparency = 1, LayoutOrder = 2, Size = UDim2.new(1, 0, 0, 26), ZIndex = 22}, recentSection)
	ui.padding(boxes, 2, 2, 2, 2)
	local grid = Instance.new('UIGridLayout')
	grid.CellPadding = UDim2.fromOffset(10, 0)
	grid.CellSize = UDim2.new(1 / 8, -9, 0, 22)
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = boxes
	for index = 1, 8 do
		local color = layout.RecentColors[index]
		local box = ui.new('TextButton', {
			AutoButtonColor = false,
			BackgroundColor3 = color or Color3.new(0, 0, 0),
			BorderSizePixel = 0,
			LayoutOrder = index,
			Text = '',
			ZIndex = 22
		}, boxes)
		ui.corner(box, 4)
		local ring = ui.stroke(box, theme.Outline, 2, 0)
		ui.hover(box, function()
			ring.Color = theme.PillHover
		end, function()
			ring.Color = theme.Outline
		end)
		if color then
			box.MouseButton1Click:Connect(function()
				if modal.Closed then return end
				set(ui.toHsl(color))
			end)
		end
	end

	hex.FocusLost:Connect(function(_, input)
		local key
		pcall(function()
			key = input.KeyCode
		end)
		if key == Enum.KeyCode.Escape then
			ui.escapeLater('focus')
			return
		end
		if modal.Closed then return end
		local text = hex.Text
		if text ~= '#'..state.Color:ToHex():lower() then
			local ok, parsed = pcall(function()
				local parts = text:split(',')
				if #parts >= 3 then
					local r, g, b = tonumber(parts[1]), tonumber(parts[2]), tonumber(parts[3])
					if r and g and b and math.abs(r) < math.huge and math.abs(g) < math.huge and math.abs(b) < math.huge then
						return Color3.fromRGB(math.clamp(r, 0, 255), math.clamp(g, 0, 255), math.clamp(b, 0, 255))
					end
					return nil
				end
				return Color3.fromHex((text:gsub('%s', '')))
			end)
			if ok and typeof(parsed) == 'Color3' then
				set(ui.toHsl(parsed))
				return
			end
		end
		paint()
	end)

	paint()
	return modal
end

--[[ A catalog as the search lists it: {Id, Name, Key, IdKey} from props.Items -- a function that
returns {Id, Name} pairs, or the pairs themselves -- read under pcall and sorted by name. Bare ids
and an {[id] = name} map are taken too; anything else is skipped. ]]
function ui.itemCatalog(source)
	local list, seen = {}, {}
	local ok, items = pcall(function()
		if type(source) == 'function' then
			return source()
		end
		return source
	end)
	if not ok or type(items) ~= 'table' then return list end
	local function add(id, name)
		if type(id) ~= 'string' or id == '' or seen[id] then return end
		seen[id] = true
		name = type(name) == 'string' and name ~= '' and name or id
		table.insert(list, {Id = id, Name = name, Key = name:lower(), IdKey = id:lower()})
	end
	for key, entry in items do
		if type(entry) == 'table' then
			add(entry.Id, entry.Name)
		elseif type(key) == 'number' then
			add(entry, entry)
		else
			add(key, entry)
		end
	end
	table.sort(list, function(a, b)
		if a.Key ~= b.Key then
			return a.Key < b.Key
		end
		return a.Id < b.Id
	end)
	return list
end

--[[ The Search item modal, on the shared modal card: a box to type in, its text centred and the keyboard
taken into it, then the catalog's names in two columns, filled row by row 33 px apart, each its
whole half of the row and white under the pointer. What is typed matches part of a name or an id, in
any case; entries opts.Skip(id) turns down are left out. At most opts.Max (30), then '+N more...'. A
pick closes it and goes to opts.Pick(id).

The text only marks the list stale: it is rebuilt after the change, never inside it, and whatever is
under the still pointer lights straight after. As in the module search, for two seconds a focus lost
with no Enter, Tab, click or tap behind it is taken back, up to eight times. Escape in the box
closes the modal (ui.escape). opts: Title, Catalog (ui.itemCatalog), Max, Skip(id), Pick(id). ]]
function ui.itemSearch(opts)
	local max = math.max(math.floor(tonumber(opts.Max) or 30), 1)
	local modal = ui.modalCard({Name = 'ItemSearch', Title = opts.Title or 'Search item', FitHeight = 85 + math.ceil((max + 1) / 2) * 33})
	if not modal then return nil end
	local card = modal.Card
	local boxRow = ui.new('Frame', {BackgroundTransparency = 1, LayoutOrder = 2, Size = UDim2.new(1, 0, 0, 42), ZIndex = 22}, card)
	local field = ui.pill(boxRow, {
		Class = 'Frame',
		Name = 'Field',
		AnchorPoint = Vector2.new(0.5, 0),
		Background = theme.Bar,
		Position = UDim2.new(0.5, 0, 0, 10),
		Radius = UDim.new(0, 8),
		Size = UDim2.new(1, -10, 0, 28)
	})
	field.ZIndex = 22
	local input = ui.text(field, {Class = 'TextBox', Size = 15, Color = theme.Text, AlignX = Enum.TextXAlignment.Center, Props = {
		ClearTextOnFocus = false,
		PlaceholderText = '',
		Position = UDim2.fromOffset(12, 0),
		Size = UDim2.new(1, -24, 1, 0),
		ZIndex = 23
	}})
	modal.Input = input
	local results = ui.new('Frame', {Name = 'Results', AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, LayoutOrder = 3, Size = UDim2.new(1, 0, 0, 0), ZIndex = 22}, card)
	modal.Results = results
	local grid = Instance.new('UIGridLayout')
	grid.CellPadding = UDim2.fromOffset(0, 0)
	grid.CellSize = UDim2.new(0.5, 0, 0, 33)
	grid.FillDirection = Enum.FillDirection.Horizontal
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = results

	local cells = {}
	local function rebuild()
		for _, cell in cells do
			cell:Destroy()
		end
		table.clear(cells)
		local query = tostring(input.Text or ''):lower():gsub('^%s+', ''):gsub('%s+$', '')
		local shown, total = 0, 0
		for _, item in opts.Catalog or {} do
			if not (opts.Skip and opts.Skip(item.Id))
				and (query == '' or item.Key:find(query, 1, true) or item.IdKey:find(query, 1, true)) then
				total += 1
				if shown < max then
					shown += 1
					local cell = ui.text(results, {Class = 'TextButton', Text = item.Name, Size = 15, Color = theme.Text, Props = {
						Name = 'Result', LayoutOrder = shown, TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 22
					}})
					ui.padding(cell, 0, 10, 0, 0)
					ui.hover(cell, function()
						cell.TextColor3 = theme.Lit
					end, function()
						cell.TextColor3 = theme.Text
					end)
					local id = item.Id
					cell.MouseButton1Click:Connect(function()
						if modal.Closed then return end
						modal.Close()
						if opts.Pick then
							opts.Pick(id)
						end
					end)
					table.insert(cells, cell)
				end
			end
		end
		if total > shown then
			table.insert(cells, ui.text(results, {Text = '+'..(total - shown)..' more...', Size = 15, Color = theme.SubText, Props = {
				Name = 'More', LayoutOrder = shown + 1, ZIndex = 22
			}}))
		end
	end
	local queued = false
	local function settle()
		queued = false
		if slinky.loaded == nil or modal.Closed then return end
		if slinky.threadFix then
			setthreadidentity(8)
		end
		rebuild()
		task.defer(function()
			if slinky.loaded == nil or modal.Closed then return end
			if slinky.threadFix then
				setthreadidentity(8)
			end
			ui.rehover()
		end)
	end
	input:GetPropertyChangedSignal('Text'):Connect(function()
		if queued then return end
		queued = true
		task.defer(settle)
	end)

	local focusUntil = os.clock() + 2
	input.FocusLost:Connect(function(enterPressed, cause)
		local key, kind
		pcall(function()
			key, kind = cause.KeyCode, cause.UserInputType
		end)
		if key == Enum.KeyCode.Escape then
			focusUntil = 0
			ui.escapeLater('focus')
			return
		end
		if enterPressed or key == Enum.KeyCode.Return or key == Enum.KeyCode.KeypadEnter or key == Enum.KeyCode.Tab
			or kind == Enum.UserInputType.MouseButton1 or kind == Enum.UserInputType.MouseButton2
			or kind == Enum.UserInputType.Touch then
			focusUntil = 0
		end
	end)
	task.spawn(function()
		local passes, retakes, lastTry = 0, 0, -1
		while not modal.Closed and os.clock() <= focusUntil do
			local focused = false
			pcall(function()
				focused = input:IsFocused()
			end)
			if focused then
				passes += 1
			else
				if passes > 0 then
					retakes += 1
					if retakes > 8 then return end
				end
				passes = 0
				if os.clock() - lastTry >= 0.015 then
					lastTry = os.clock()
					pcall(function()
						input:CaptureFocus()
					end)
				end
			end
			task.wait()
		end
	end)
	settle()
	return modal
end

--[[
	A list of entries picked from a catalog, each with its colour: Item ESP's item types, drawn as
	the owner's Slinky video shows them. Beside the label, a box from the card's centre to 10 px off
	its right edge, a 2 px #404040 border and 2 px rules between its 28 px rows: each entry's colour
	in a rounded square (a click opens its colour), its name, centred, and an x, red under the
	pointer, that takes it away; at the foot 'Click to add', which opens the search of the catalog.
	The GUI knows no game: props.Items hands it {Id, Name} pairs, read each time the search opens.
	Adding or taking away an entry only resizes this option inside the card's body, so the card's
	height follows it as it follows any row shown or hidden. Saved as {Items = {{Id, Color =
	'rrggbb'}}}; a TextList's {List, ListEnabled} loads too. slinky:Load calls Load with no pcall, so
	Load never throws.
]]
components.itemList = function(props, children, api)
	local defaultColor = typeof(props.defaultColor) == 'Color3' and props.defaultColor or Color3.fromRGB(255, 0, 0)
	local showColors = props.colors ~= false
	local component = {
		kind = 'itemList',
		index = getTableSize(api.options),
		items = {},
		colors = {}
	}
	-- The same array: readers written for a TextList read ListEnabled.
	component.active = component.items
	props.changed = props.changed or function() end

	local itemlist = ui.new('Frame', {
		Name = 'ItemList',
		BackgroundTransparency = 1,
		LayoutOrder = props.order or 0,
		Size = UDim2.new(1, 0, 0, 37),
		Visible = props.visible == nil or props.visible
	}, children)
	component.row = itemlist
	ui.rowLabel(itemlist, {label = props.label or ui.prettify(props.name)})
	addTooltip(itemlist, props.about)
	--[[ Its border outside, as the dropdown's open box: 4 px under the row's top, (entries + 1) * 28 + 2
	tall over the border, and the next row 3 px under it. ]]
	local box = ui.pill(itemlist, {
		Class = 'Frame',
		Name = 'Box',
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 6),
		Radius = UDim.new(0, 9),
		Thickness = 2,
		Size = UDim2.new(0.5, -14, 0, 26)
	})
	component.window = box
	local add = ui.text(box, {Class = 'TextButton', Text = 'Click to add', Size = 15, Color = theme.SubText, AlignX = Enum.TextXAlignment.Center, Props = {
		Name = 'Add',
		Size = UDim2.new(1, 0, 0, 26)
	}})
	ui.hover(add, function()
		add.TextColor3 = theme.SubTextLit
	end, function()
		add.TextColor3 = theme.SubText
	end)

	-- Each entry's shown name, from the catalog; one it never named shows as its id.
	local names = {}
	local namesTried = -math.huge
	local rows, squares = {}, {}
	-- The colour modal while one is open: {Id, Modal}.
	local colorOpen

	local function learnNames()
		local catalog = ui.itemCatalog(props.items)
		local renamed = false
		for _, item in catalog do
			if names[item.Id] ~= item.Name then
				renamed = renamed or component.colors[item.Id] ~= nil
				names[item.Id] = item.Name
			end
		end
		return catalog, renamed
	end

	local function closeColor(id)
		if colorOpen and (id == nil or colorOpen.Id == id) then
			local opened = colorOpen
			colorOpen = nil
			opened.Modal.Close()
		end
	end

	local function openColor(id)
		if not showColors or component.colors[id] == nil then return end
		closeColor()
		local opened = ui.colorModal({
			Title = names[id] or id,
			Color = component.colors[id],
			OnChange = function(color)
				component:setColor(id, color)
			end,
			OnClose = function()
				if colorOpen and colorOpen.Id == id then
					colorOpen = nil
				end
			end
		})
		if opened then
			colorOpen = {Id = id, Modal = opened}
		end
	end

	--[[ Rebuilds the item list's rows, 28 px apart: the entry's colour square (when the list shows
	colours; it never lights, and a click opens the colour modal), its name or id, and an x that
	removes it, then the 'Click to add' row and the box's size. Names for entries loaded before any
	search come from the catalog, asked at most once every 2 s. ]]
	local function render()
		for _, row in rows do
			row:Destroy()
		end
		table.clear(rows)
		table.clear(squares)
		local unnamed = false
		for _, id in component.items do
			if names[id] == nil then
				unnamed = true
				break
			end
		end
		if unnamed and os.clock() - namesTried > 2 then
			namesTried = os.clock()
			learnNames()
		end
		for index, id in component.items do
			local row = ui.new('Frame', {
				Name = 'Entry',
				BackgroundTransparency = 1,
				LayoutOrder = index,
				Position = UDim2.fromOffset(0, (index - 1) * 28),
				Size = UDim2.new(1, 0, 0, 26)
			}, box)
			ui.new('Frame', {
				Name = 'Rule',
				BackgroundColor3 = theme.Outline,
				BackgroundTransparency = 0.5,
				BorderSizePixel = 0,
				Position = UDim2.fromOffset(0, 26),
				Size = UDim2.new(1, 0, 0, 2)
			}, row)
			if showColors then
				local square = ui.new('TextButton', {
					Name = 'Color',
					AnchorPoint = Vector2.new(0, 0.5),
					AutoButtonColor = false,
					BackgroundColor3 = component.colors[id] or defaultColor,
					BorderSizePixel = 0,
					Position = UDim2.new(0, 4, 0.5, 0),
					Size = UDim2.fromOffset(20, 18),
					Text = ''
				}, row)
				ui.corner(square, 5)
				squares[id] = square
				square.MouseButton1Click:Connect(function()
					openColor(id)
				end)
			end
			ui.text(row, {Text = names[id] or id, Size = 15, Color = theme.Text, AlignX = Enum.TextXAlignment.Center, Props = {
				Name = 'Title',
				Position = UDim2.fromOffset(28, 0),
				Size = UDim2.new(1, -56, 1, 0),
				TextTruncate = Enum.TextTruncate.AtEnd
			}})
			local remove = ui.icon(row, 'slinky-x', 12, {Class = 'TextButton', Color = theme.CloseRest, NoMirror = true, Box = UDim2.fromOffset(20, 20), Props = {
				Name = 'Remove',
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -2, 0.5, 0)
			}})
			local removeEntry = fonts.Registry[remove]
			if removeEntry then
				removeEntry.Size = 16
				ui.setIcon(remove, 'slinky-x')
			end
			ui.hover(remove, function()
				ui.paintIcon(remove, theme.Red)
			end, function()
				ui.paintIcon(remove, theme.CloseRest)
			end)
			remove.MouseButton1Click:Connect(function()
				component:remove(id)
			end)
			table.insert(rows, row)
		end
		local count = #component.items
		add.Position = UDim2.fromOffset(0, count * 28)
		local height = (count + 1) * 28 + 2
		box.Size = UDim2.new(0.5, -14, 0, height - 4)
		itemlist.Size = UDim2.new(1, 0, 0, height + 7)
	end

	--[[ The rows moved under a still pointer: what it rests on now lights, and what moved away from
	it goes out, after the click that moved them. ]]
	local function rehoverSoon()
		task.defer(function()
			if slinky.loaded == nil or not (clickgui and clickgui.Visible) then return end
			if slinky.threadFix then
				setthreadidentity(8)
			end
			ui.restHovered()
			ui.rehover()
		end)
	end

	local function changed()
		props.changed(component)
		slinky:requestSave()
	end

	function component:recolor() end

	function component:has(id)
		return self.colors[id] ~= nil
	end

	function component:colorOf(id)
		return self.colors[id]
	end

	function component:add(id, color)
		if type(id) ~= 'string' or id == '' or self.colors[id] ~= nil then return false end
		table.insert(self.items, id)
		self.colors[id] = typeof(color) == 'Color3' and color or defaultColor
		render()
		rehoverSoon()
		changed()
		return true
	end

	function component:remove(id)
		local index = table.find(self.items, id)
		if not index then return false end
		table.remove(self.items, index)
		self.colors[id] = nil
		closeColor(id)
		render()
		rehoverSoon()
		changed()
		return true
	end

	function component:setColor(id, color)
		if self.colors[id] == nil or typeof(color) ~= 'Color3' then return false end
		self.colors[id] = color
		if squares[id] then
			squares[id].BackgroundColor3 = color
		end
		changed()
		return true
	end

	function component:clear()
		if #self.items == 0 then return end
		table.clear(self.items)
		table.clear(self.colors)
		closeColor()
		render()
		rehoverSoon()
		changed()
	end

	function component:save()
		local items = {}
		for _, id in self.items do
			table.insert(items, {id = id, color = (self.colors[id] or defaultColor):ToHex():lower()})
		end
		return items
	end

	-- Its own rows of {id, color}, or a text list's value (the entries that are on) in DefaultColor;
	-- what does not read as an entry is skipped.
	local function parse(value)
		local entries = {}
		if type(value) ~= 'table' then return entries end
		local rows = false
		for _, entry in value do
			rows = rows or type(entry) == 'table'
		end
		if rows and value.items == nil and value.active == nil then
			for _, entry in value do
				if type(entry) == 'table' and type(entry.id) == 'string' and entry.id ~= '' then
					local color = defaultColor
					if type(entry.color) == 'string' then
						local ok, parsed = pcall(Color3.fromHex, entry.color)
						if ok and typeof(parsed) == 'Color3' then
							color = parsed
						end
					end
					table.insert(entries, {Id = entry.id, Color = color})
				end
			end
			return entries
		end
		local _, active = store.listed(value)
		for _, id in active do
			if type(id) == 'string' and id ~= '' then
				table.insert(entries, {Id = id, Color = defaultColor})
			end
		end
		return entries
	end

	--[[ Loads the saved entries with their colours, skipping duplicates, closes any open colour modal
	and redraws. props.changed runs on its own thread, so a game callback that errors does not stop
	the profile's load. ]]
	function component:load(value)
		local ok, entries = pcall(parse, value)
		table.clear(self.items)
		table.clear(self.colors)
		if ok then
			for _, entry in entries do
				if self.colors[entry.Id] == nil then
					table.insert(self.items, entry.Id)
					self.colors[entry.Id] = entry.Color
				end
			end
		end
		closeColor()
		render()
		task.spawn(props.changed, self)
	end

	--[[ Opens the Search item modal over the catalog, leaving out entries already in the list; a pick
	adds it. Names the catalog has only just supplied are drawn on the entries first. ]]
	function component:openSearch()
		local catalog, renamed = learnNames()
		namesTried = os.clock()
		if renamed then
			render()
		end
		return ui.itemSearch({
			Title = props.title or 'Search item',
			Catalog = catalog,
			Max = props.max,
			Skip = function(id)
				return component.colors[id] ~= nil
			end,
			Pick = function(id)
				component:add(id)
			end
		})
	end

	function component:openColor(id)
		openColor(id)
	end

	add.MouseButton1Click:Connect(function()
		component:openSearch()
	end)

	if type(props.default) == 'table' then
		for _, entry in props.default do
			local id = type(entry) == 'table' and entry.Id or entry
			if type(id) == 'string' and id ~= '' and component.colors[id] == nil then
				table.insert(component.items, id)
				component.colors[id] = type(entry) == 'table' and typeof(entry.Color) == 'Color3' and entry.Color or defaultColor
			end
		end
	end
	render()

	api.options[props.name] = component

	return object(component, props.name)
end

--[[ A legit module's card in the tabs, with an optional on-screen widget (props.size) that shows while
the module is on and is dragged into place while the menu is open, outlined then so it can be found.
The widget starts below Roblox's top bar, a step down from the widget before it, zoomed on a phone;
its position is saved. An entry that says nothing for this place leaves the module as it is.

While a profile is applying, a start is queued rather than spawned, since task.spawn would run the
module's setup inline inside the apply loop; only the newest queued start runs, and only while the
module is still on. Modules are also kept in api.order because slinky:Save walks the array, never
the hash. Cards sort ignoring case and spaces; 'Show legit mode' in the GUI card takes them out of
the tabs and the search. ]]
components.legitModule = function(props, children, api)
	slinky:remove(props.name)
	local component = {
		kind = 'legitModule',
		name = props.name,
		label = props.label or ui.prettify(props.name),
		tab = layout.tabOf(props, 'Legit'),
		legit = true,
		enabled = false,
		options = {}
	}

	local view = ui.card({
		Name = props.name,
		Display = component.label,
		Tooltip = props.about,
		Switch = true,
		ChildrenName = props.name..'Settings'
	})
	component.options = view:WatchOptions(component.options)
	component.row = view.Card
	local settingschildren = view.Body
	local expanded = false

	if props.size then
		local modulechildren = ui.new('Frame', {
			Name = props.name..'Widget',
			BackgroundTransparency = 1,
			Size = props.size,
			Visible = false,
			ZIndex = 2
		}, scaledgui)
		component.hudSlot = ui.hudSlot('Widget')
		modulechildren.Position = ui.hudPlace('Widget', component.hudSlot)
		ui.hudScale(modulechildren)
		addDragHandler(modulechildren, clickgui)
		local objectstroke = Instance.new('UIStroke')
		objectstroke.Color = theme.Accent()
		objectstroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		objectstroke.Thickness = 1
		objectstroke.Transparency = 0.3
		objectstroke.Enabled = false
		objectstroke.Parent = modulechildren
		component.frame = modulechildren
		ui.whenMenu(function()
			objectstroke.Enabled = clickgui.Visible
			objectstroke.Color = theme.Accent()
		end)
	end
	props.toggled = props.toggled or function() end
	addMaid(component)

	function component:recolor(hue, sat, val, isRainbow)
		if self.enabled then
			view.Switch:Color(Color3.fromHSV(hue, sat, val))
		end

		for _, option in self.options do
			if option.recolor then
				option:recolor(hue, sat, val, isRainbow)
			end
		end
	end

	function component:load(entry)
		slinky:loadOptions(self, entry)

		local on = slinky:savedOn(entry)
		if on ~= nil and self.enabled ~= on then
			self:flip()
		end

		local x, y = store.spot(entry.__pos)
		if x and self.frame then
			self.frame.Position = UDim2.fromOffset(x, y)
			ui.clampHud(self.frame, self.frame.Size.X.Offset, self.frame.Size.Y.Offset)
		end
	end

	function component:save()
		local entry = slinky:saveOptions(self)
		slinky:savedOn(entry, self.enabled)
		if self.frame then
			entry.__pos = {
				x = self.frame.Position.X.Offset,
				y = self.frame.Position.Y.Offset
			}
		end
		return entry
	end

	function component:flip()
		self.enabled = not self.enabled
		if self.frame then
			self.frame.Visible = self.enabled
		end
		view.Switch:Set(self.enabled)

		if not self.enabled then
			for _, v in self.connections do
				cleanupConnection(v)
			end
			table.clear(self.connections)
		end

		slinky:requestSave()
		if slinky.applying and self.enabled then
			local token = {}
			self.startToken = token
			queueStart(props.name, function()
				if self.enabled and self.startToken == token then
					props.toggled(true)
				end
			end)
		else
			self.startToken = nil
			task.spawn(props.toggled, self.enabled)
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
		component:flip()
	end)
	view.Header.MouseButton2Click:Connect(toggleExpand)
	view.Expand.MouseButton1Click:Connect(toggleExpand)
	view.Expand.MouseButton2Click:Connect(toggleExpand)

	api.modules[props.name] = component
	api.order = api.order or {}
	table.insert(api.order, component)

	layout.add({
		Card = view.Card,
		Tab = component.tab,
		Name = props.name,
		Key = ((props.sortKey or component.label):lower():gsub('%s', '')),
		Search = {props.name:lower(), component.label:lower()},
		Visible = function()
			return layout.ShowLegit ~= false
		end
	})

	return object(component)
end

--[[ The registry of the legit modules, whose cards live in the tabs: modules by name, and order, the
array slinky:Save walks. Shows each module's widget while the module is on, set after the menu's
change, never inside it. ]]
components.legitWindow = function(props, children, api)
	local component = {
		modules = {},
		order = {}
	}

	local window = ui.new('Frame', {
		BackgroundTransparency = 1,
		Name = 'LegitGUI',
		Size = UDim2.fromOffset(0, 0),
		Visible = false
	}, scaledgui)
	table.insert(slinky.windows, window)
	component.window = window

	bindComponents(component, window)

	component.module = creator(components.legitModule, window, component)

	local function visibleCheck()
		for _, module in orderedModules(component.order) do
			if module.frame then
				module.frame.Visible = module.enabled
			end
		end
	end

	ui.whenMenu(visibleCheck)

	slinky.legit = component

	return object(component, 'legit', 'legitWindow')
end

--[[ A module's card: its switch, options, key and HOLD badges, and the eye that hides or shows the card
while hidden modules are being edited. Resting on the name shows its help centred over the whole
card. The entry holds the on/off for this place, the bind, whether the card is hidden, and a key per
option; the lobby and matches share an entry but keep their own on/off, so an entry that says
nothing for this place leaves the module as it is. A hold bind's module is on only while its key is
down, so it loads off.

The module's function gets the state its own toggle set, even when another toggle lands before it
starts. 'Enabled X' / 'Disabled X' is notified only when the module is switched by its own key or
on-screen button, never while a profile loads or unloads; every other switch stays quiet. The
overlay list redraws once at the end of the frame however many modules changed. While a profile is
applying, a start is queued rather than spawned, since task.spawn would run the setup inline inside
the apply loop; only the newest queued start runs, and only if the module is still on.

On a touch screen, holding the title or the description line for 1 s without moving hides the menu,
and the next tap places the module's on-screen button. Cards sort ignoring case and spaces (Hitboxes
before Hit Select). ]]
components.module = function(props, children, api)
	slinky:remove(props.name)
	local component = {
		kind = 'module',
		name = props.name,
		label = props.label or ui.prettify(props.name),
		category = api.name,
		tab = layout.tabOf(props, api.name),
		index = slinky.moduleCount,
		enabled = false,
		visible = true,
		info = props.info,
		options = {}
	}

	local view = ui.card({
		Name = props.name,
		Display = component.label,
		Tooltip = props.about,
		Switch = true
	})
	component.options = view:WatchOptions(component.options)
	local card = view.Card
	component.row = card
	component.bindParent = view.NameRow
	addRowTooltip(view.Header, props.about, view.Header, view.Title, nil, true)
	local modulechildren = view.Body
	component.frame = modulechildren
	local expanded = false

	local edit = ui.icon(view.NameRow, 'eye', 15, {Class = 'TextButton', Color = theme.SubText, NoMirror = true, Props = {
		Name = 'Edit', LayoutOrder = 4, Size = UDim2.fromOffset(22, 20), Visible = false
	}})
	ui.hover(edit, function()
		ui.paintIcon(edit, theme.SubTextLit)
	end, function()
		ui.paintIcon(edit, theme.SubText)
	end)
	component.edit = edit
	props.toggled = props.toggled or function() end
	addMaid(component)

	function component:recolor(hue, sat, val, isRainbow)
		if self.enabled then
			view.Switch:Color(accentFor(self.index, 0.025, hue, sat, val, isRainbow))
		end

		for _, option in self.options do
			if option.recolor then
				option:recolor(hue, sat, val, isRainbow)
			end
		end
	end

	function component:Destroy()
		self.bind:Destroy()

		for _, option in self.options do
			if option.kind == 'keybind' then
				option:Destroy()
			end
		end
		layout.remove(card)
	end

	function component:load(entry)
		slinky:loadOptions(self, entry)
		self.bind:load(store.bindOf(entry))

		local on = slinky:savedOn(entry)
		if on ~= nil and self.enabled ~= (on and not self.bind.hold) then
			self:flip(true)
		end

		local visible = entry.__hidden ~= true
		if (self.visible ~= false) ~= visible then
			self:setVisible(visible, true)
		end
	end

	function component:save()
		local entry = slinky:saveOptions(self)
		slinky:savedOn(entry, self.enabled)
		store.bindInto(entry, self.bind)
		entry.__hidden = self.visible == false or nil
		return entry
	end

	function component:setVisible(isVisible, isLoad)
		self.visible = isVisible
		ui.setIcon(edit, isVisible == false and 'eye-off' or 'eye')
		card.BackgroundTransparency = isVisible == false and 0.45 or 0
		layout.request(self.tab)
		if not isLoad then
			slinky:requestSave()
		end
	end

	function component:flip(multiple, quiet, fromBind)
		if slinky.threadFix then
			setthreadidentity(8)
		end

		self.enabled = not self.enabled
		local enabled = self.enabled
		view.Switch:Set(self.enabled, liveAccent(self.index, 0.025))
		if self.bind and self.bind.mobile then
			self.bind.mobile.BackgroundColor3 = self.enabled and theme.Accent() or theme.Bar
		end

		if fromBind and not quiet and slinky.loaded and not slinky.applying and slinky.toggleNotifications and slinky.toggleNotifications.enabled then
			slinky:notify('Pistonware', (self.enabled and 'Enabled ' or 'Disabled ')..(self.label or props.name), 2)
		end

		if not self.enabled then
			for _, v in self.connections do
				cleanupConnection(v)
			end
			table.clear(self.connections)
		end

		if slinky.loaded ~= nil then
			slinky:updateOverlay()
		end

		slinky:requestSave()
		if slinky.applying and enabled then
			local token = {}
			self.startToken = token
			queueStart(props.name, function()
				if self.enabled and self.startToken == token then
					props.toggled(true)
				end
			end)
		else
			self.startToken = nil
			task.spawn(props.toggled, enabled)
		end
	end

	bindComponents(component, modulechildren)

	local function toggleExpand()
		expanded = not expanded
		view:SetExpanded(expanded)
	end

	view.Header.MouseButton1Click:Connect(function()
		if slinky.editing then
			component:setVisible(not component.visible)
			return
		end

		component:flip()
	end)
	view.Header.MouseButton2Click:Connect(toggleExpand)
	view.Expand.MouseButton1Click:Connect(toggleExpand)
	view.Expand.MouseButton2Click:Connect(toggleExpand)
	edit.MouseButton1Click:Connect(function()
		component:setVisible(not component.visible)
	end)

	local bind = component:keybind({
		module = true,
		cover = true,
		holdBadge = true
	})

	bind.triggered:Connect(function(isDown)
		if bind.hold then
			if component.enabled ~= isDown then
				component:flip(true, nil, true)
			end
		else
			component:flip(true, nil, true)
		end
	end)

	if inputService.TouchEnabled then
		local isHeld = false

		local function startHold()
			isHeld = true
			local holdtime, holdPos = os.clock(), inputService:GetMouseLocation()
			repeat
				isHeld = (inputService:GetMouseLocation() - holdPos).Magnitude < 3
				task.wait()
			until (os.clock() - holdtime) > 1 or not isHeld or not clickgui.Visible

			if isHeld and clickgui.Visible then
				if slinky.threadFix then
					setthreadidentity(8)
				end

				clickgui.Visible = false
				tooltip.Visible = false
				slinky:blurCheck()
				for _, module in orderedModules(slinky.moduleOrder) do
					if module.bind.mobile then
						module.bind.mobile.Visible = true
					end
				end

				local connection
				connection = inputService.InputBegan:Connect(function(input)
					if input.UserInputType == Enum.UserInputType.Touch then
						if slinky.threadFix then
							setthreadidentity(8)
						end

						bind:createMobileButton(input.Position + Vector3.new(0, guiService:GetGuiInset().Y, 0))
						slinky:requestSave()
						clickgui.Visible = true
						slinky:blurCheck()

						for _, module in orderedModules(slinky.moduleOrder) do
							if module.bind.mobile then
								module.bind.mobile.Visible = false
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

	slinky.modules[props.name] = component
	slinky.moduleCount += 1
	table.insert(slinky.moduleOrder, component)
	slinky:sortCategories()

	layout.add({
		Card = card,
		Tab = component.tab,
		Name = props.name,
		Key = ((props.sortKey or component.label):lower():gsub('%s', '')),
		Search = {props.name:lower(), component.label:lower()},
		Visible = function()
			return component.visible ~= false or slinky.editing == true
		end
	})

	return object(component)
end

--[[ Drags `target` by a press on `handle` while `enabled()` allows it: addDragHandler's own sum, for a
handle that is not the thing it moves. The press is turned into an offset in screen pixels, so the
top-bar inset is added. Only the press that started the drag moves it, never a second finger on the
thumbstick; Shift snaps to 3 px. Where it is dropped is saved, as nothing else asks for a save after
a drag. ]]
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
				slinky:requestSave()
			end
		end)
	end)
end

--[[ An overlay's card and its window on screen: a slim handle to drag it by while the menu is open,
drawn like the Target Info card with the pin at its right, and its content under that. A fixed
overlay (the Mod Overlay) has neither and stays in the top-right corner, on screen whether or not
the menu is open. A moveable overlay starts below Roblox's top bar, a step on from the overlay
before it, takes the phone zoom, and with the menu open its own content drags it as well; unpinned,
it shows only while the menu is open. A hold-mode overlay is on only while its key is down, so it
loads off. It is shown and hidden with the menu after its change (ui.whenMenu), never inside the
write to Visible. Where it starts and whether it starts pinned are its own, not a profile's. ]]
components.overlay = function(props, children, api)
	local display = props.label or (props.name == 'Text GUI' and 'Mod Overlay' or props.name)
	local view = ui.card({
		Name = props.name..'Card',
		Display = display,
		Tooltip = props.about or (props.name == 'Text GUI' and 'Displays a list of all active mods.' or 'An overlay on your screen.')
	})
	local window
	local component
	component = {
		kind = 'overlay',
		name = props.name,
		label = display,
		switch = slinky.overlays:imageToggle(props.name, {
			switchParent = view.Header,
			changed = function(callback)
				window.Visible = callback and (clickgui.Visible or component.pinned)

				if not callback then
					for _, v in component.connections do
						cleanupConnection(v)
					end
					table.clear(component.connections)
				end

				if props.toggled then
					task.spawn(props.toggled, callback)
				end
			end
		}),
		expanded = false,
		pinned = false,
		options = {}
	}

	local fixed = props.fixed == true
	component.pinned = fixed
	component.fixed = fixed
	component.hudSlot = not fixed and ui.hudSlot('Overlay') or nil
	window = ui.new('TextButton', {
		AnchorPoint = fixed and Vector2.new(1, 0) or Vector2.zero,
		AutoButtonColor = false,
		BackgroundColor3 = Color3.fromRGB(16, 16, 16),
		BackgroundTransparency = fixed and 1 or 0.15,
		BorderSizePixel = 0,
		Name = props.name..'Overlay',
		Position = fixed and UDim2.fromScale(1, 0) or ui.hudPlace('Overlay', component.hudSlot),
		Size = UDim2.fromOffset(props.categorySize or 220, fixed and 0 or 32),
		Text = '',
		Visible = false,
		ZIndex = 2
	}, scaledgui)
	component.row = window
	if not fixed then
		ui.hudScale(window)
	end
	ui.corner(window, 10)
	local PIN_ON, PIN_OFF = Color3.fromRGB(240, 122, 31), Color3.fromRGB(150, 150, 150)
	local stroke = ui.stroke(window, Color3.new(1, 1, 1), 1, 0.9)
	stroke.Enabled = not fixed
	if not fixed then
		addDragHandler(window)
	end
	local title = ui.text(window, {Text = display, TextSize = 14, Weight = 'SemiBold', Color = Color3.fromRGB(240, 240, 240), Props = {
		Position = UDim2.fromOffset(12, 0),
		Size = UDim2.new(1, -44, 0, 32),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Visible = not fixed
	}})
	local pin = ui.icon(window, 'pin', 14, {Class = 'TextButton', Color = PIN_OFF, NoMirror = true, Props = {
		AnchorPoint = Vector2.new(1, 0.5), Name = 'Pin', Position = UDim2.new(1, -8, 0, 16), Visible = not fixed
	}})
	addTooltip(pin, 'Pin: keep it on screen with the menu closed')
	local pinHovered = false
	local function paintPin()
		ui.paintIcon(pin, component.pinned and PIN_ON or (pinHovered and theme.SubTextLit or PIN_OFF))
	end
	ui.hover(pin, function()
		pinHovered = true
		paintPin()
	end, function()
		pinHovered = false
		paintPin()
	end)
	local customchildren = ui.new('Frame', {
		BackgroundTransparency = 1,
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, 200)
	}, window)
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

	function component:recolor(hue, sat, val, isRainbow)
		for _, option in self.options do
			if option.recolor then
				option:recolor(hue, sat, val, isRainbow)
			end
		end
	end

	function component:expand(visCheck)
		if visCheck and not clickgui.Visible then return end

		self.expanded = not self.expanded
		view:SetExpanded(self.expanded)
	end

	function component:load(entry)
		slinky:loadOptions(self, entry)

		local heldOnly = self.bind ~= nil and entry.__hold == true
		local on = slinky:savedOn(entry)
		if on ~= nil and self.switch.enabled ~= (on and not heldOnly) then
			self.switch:flip()
		end

		if not fixed and type(entry.__pinned) == 'boolean' and (self.pinned and true or false) ~= entry.__pinned then
			self:pin()
			self:update()
		end

		local x, y = store.spot(entry.__pos)
		if x and not fixed then
			window.Position = UDim2.fromOffset(x, y)
			ui.clampHud(window, window.Size.X.Offset, 32)
		end

		if self.bind then
			self.bind:load(store.bindOf(entry))
		end
	end

	function component:pin()
		if fixed then return end
		self.pinned = not self.pinned
		paintPin()
		slinky:requestSave()
	end

	function component:save()
		local entry = slinky:saveOptions(self)
		slinky:savedOn(entry, self.switch.enabled)
		entry.__pinned = self.pinned and true or false
		entry.__pos = {
			x = window.Position.X.Offset,
			y = window.Position.Y.Offset
		}
		if self.bind then
			store.bindInto(entry, self.bind)
		end
		return entry
	end

	function component:update()
		window.Visible = self.switch.enabled and (clickgui.Visible or self.pinned)
		if fixed then return end

		if clickgui.Visible then
			window.Size = UDim2.fromOffset(window.Size.X.Offset, 32)
			window.BackgroundTransparency = 0.15
			stroke.Enabled = true
			title.Visible = true
			pin.Visible = true
		else
			window.Size = UDim2.fromOffset(window.Size.X.Offset, 0)
			window.BackgroundTransparency = 1
			stroke.Enabled = false
			title.Visible = false
			pin.Visible = false
		end
	end

	function component:Destroy()
		layout.remove(view.Card)
		view.Card:Destroy()
	end

	bindComponents(component, view.Body)

	component.bindParent = view.NameRow
	local bind = component:keybind({
		module = true,
		cover = true,
		holdBadge = true
	})
	bind.triggered:Connect(function(isDown)
		if bind.hold then
			if component.switch.enabled ~= isDown then
				component.switch:flip()
			end
		else
			component.switch:flip()
		end
	end)

	ui.whenMenu(function()
		component:update()
	end)

	view.Header.MouseButton1Click:Connect(function()
		component.switch:flip()
	end)
	view.Header.MouseButton2Click:Connect(function()
		component:expand()
	end)
	view.Expand.MouseButton1Click:Connect(function()
		component:expand()
	end)
	view.Expand.MouseButton2Click:Connect(function()
		component:expand()
	end)
	pin.MouseButton1Click:Connect(function()
		component:pin()
	end)
	window.MouseButton2Click:Connect(function()
		component:expand(true)
	end)

	component.frame = customchildren
	slinky.categories[props.name] = component

	layout.add({
		Card = view.Card,
		Tab = layout.tabOf(props, 'Overlay'),
		Name = props.name,
		Key = (display:lower():gsub('%s', '')),
		Search = {props.name:lower(), display:lower()}
	})

	return object(store.built(component))
end

-- The registry the overlay switches are kept in; UpdateGUI recolours through it.
components.overlayBar = function(props, children, api)
	local component = {
		kind = 'overlayBar',
		options = {}
	}

	local holder = ui.new('Frame', {
		Name = 'Overlays',
		BackgroundColor3 = theme.Card,
		BackgroundTransparency = 1,
		Visible = false
	}, layout.Hidden)
	bindComponents(component, holder)

	slinky.overlays = component

	return object(component, 'overlays')
end

--[[ The 'Search bar style' option still saves, loads and writes .Object.Visible, so it gets an object
whose row is never shown. ]]
components.searchBar = function(props, children, api)
	return object({
		kind = 'searchBar',
		row = ui.new('Frame', {Name = 'NoSearch', Visible = false})
	}, 'searchBar')
end

components.settingsPane = function(props, children, api)
	local component = {
		kind = 'settingsPane',
		buttons = {},
		options = {},
		parent = api.parent or children
	}

	local host = settingsHosts[PANE_HOSTS[props.name] or 'Default'] or settingsHosts.Default or children
	local section = ui.new('Frame', {
		Name = props.name,
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = theme.Card,
		BackgroundTransparency = 1,
		LayoutOrder = PANE_ORDER[props.name] or 99,
		Size = UDim2.new(1, 0, 0, 0)
	}, host)
	ui.list(section, 0, false, Enum.HorizontalAlignment.Center)
	local title = PANE_TITLES[props.name]
	if title == nil then title = props.name end
	if title then
		local header = ui.row(section, {order = -1000}, 27)
		ui.text(header, {Text = title, Size = 15, Color = theme.Header, Props = {
			Position = UDim2.fromOffset(theme.Inset, 9), Size = UDim2.new(1, -theme.Inset * 2, 0, 21)
		}})
	end

	function component:load(entry)
		slinky:loadOptions(self, entry)
	end

	function component:save()
		return slinky:saveOptions(self)
	end

	bindComponents(component, section)

	component.row = section
	slinky.settings[props.name] = component

	return object(component, props.name)
end

--[[ A slider's value as its hint and its phone label print it: with as many decimals as its step
has, so 2.70 blocks, 100 ms or 2.0 s, as Slinky prints them. A value off its step (one typed in)
keeps all its digits. Only what is shown; the saved value is untouched. ]]
local function sliderText(value, suffix, decimal)
	local places = math.max(0, math.floor(math.log10(decimal or 1) + 0.5))
	local text = string.format('%.'..places..'f', value)
	if tonumber(text) ~= value then
		text = tostring(value)
	end
	return text..(suffix and ' '..(type(suffix) == 'function' and suffix(value) or suffix) or '')
end

--[[ A value typed into a slider's box, by a tap on its number or a Ctrl-click: the first number in the
text, so a phone keyboard's stray letters do not throw it away and a comma works as the point, on the
slider's own step and kept to its range. nil when the text holds no number: the value stays as it was. ]]
function ui.sliderTyped(text, props, low, high)
	text = tostring(text or ''):gsub(',', '.')
	local found = text:match('%-?%d*%.?%d+')
	local number = tonumber(text) or (found and tonumber(found))
	if not isFiniteNumber(number) then
		return nil
	end
	local step = props.decimal or 1
	return math.clamp(math.floor(number * step + 0.5) / step, low, high)
end

--[[ The box opens empty with the value it would replace as its placeholder: what is typed is the new
value, not more digits after the old one, and closing it untouched changes nothing. ]]
function ui.startSliderEdit(box, value)
	box.PlaceholderText = tostring(value)
	box.Text = ''
	box:CaptureFocus()
end

--[[ A number slider. No value is printed beside it: the value shows in a hint over the knob while the
track is hovered or dragged, built the first time it shows, on the menu's own layer, so a slider at
the top of a scrolled page shows it whole. On a phone the value also sits beside the name, where a
tap types one; Ctrl-click types one on a PC. The knob follows the pointer 1:1 in the frame the value
changes and never grows. The value is kept to the current range; the file keeps the value it had
until the slider is moved (slinky:loadOptions). The hint's hover zone is the track's length, 10.5 px
either side of its centre line, while the press takes the row's right half. A name too long for its
half of the row is cut with an ellipsis. ]]
components.slider = function(props, children, api)
	local component = {
		kind = 'slider',
		index = getTableSize(api.options),
		limit = props.max,
		value = props.default or props.min
	}

	local slider = ui.row(children, props)
	component.row = slider
	local left = ui.new('Frame', {
		Name = 'Left',
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(theme.Inset, 0),
		Size = UDim2.new(0.5, -theme.Inset, 1, 0)
	}, slider)
	ui.list(left, 6, true)
	ui.fitTitle(left, ui.text(left, {Text = props.label or props.name, Size = 15, Color = theme.Label, Props = {
		Name = 'Label', AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 1, Size = UDim2.fromOffset(0, theme.RowHeight)
	}}))
	local valuelabel = ui.text(left, {Class = 'TextButton', Text = sliderText(component.value, props.suffix, props.decimal), Size = 13, Color = theme.SubText, Props = {
		Name = 'Value', AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 2, Size = UDim2.fromOffset(0, theme.RowHeight), Visible = isMobile()
	}})
	local custombox = ui.text(left, {Class = 'TextBox', Size = 13, Color = theme.Text, Props = {
		ClearTextOnFocus = false, LayoutOrder = 3, Size = UDim2.fromOffset(64, theme.RowHeight), Text = tostring(component.value), Visible = false
	}})

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
		local low = props.min or 0
		return math.clamp((value - low) / math.max((props.max or 1) - low, 1e-9), 0, 1)
	end
	local fill = ui.new('Frame', {
		BackgroundColor3 = theme.Accent(),
		BorderSizePixel = 0,
		Size = UDim2.fromScale(fraction(component.value), 1)
	}, holder)
	ui.corner(fill, UDim.new(1, 0))
	local knob = ui.new('Frame', {
		Name = 'Knob',
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundTransparency = 1,
		Position = UDim2.fromScale(fraction(component.value), 0.5),
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
	local hit = ui.new('TextButton', {
		Name = 'Hit',
		AnchorPoint = Vector2.new(1, 0),
		BackgroundTransparency = 1,
		Position = UDim2.new(1, 0, 0, 0),
		Size = UDim2.new(0.5, 0, 1, 0),
		Text = ''
	}, slider)
	local tip, hoverEntry
	local hovering, dragging, where = false, false, fraction(component.value)
	local function placeTip(appearing)
		local corner, size = holder.AbsolutePosition, holder.AbsoluteSize
		local centre = Vector2.new(corner.X + where * size.X, corner.Y + size.Y / 2)
		if not ui.rowShowing(holder, centre) then
			ui.tipHide(tip)
			return
		end
		local s = math.max(scale.Scale, 0.05)
		local zoom = layout and layout.Zoom or 1
		local origin = scaledgui.AbsolutePosition
		ui.tipPlace(tip, (centre.X - origin.X) / s, (centre.Y - origin.Y) / s - (10 + 20) * zoom, 20, appearing)
	end
	local function showTip()
		if hovering or dragging then
			if not tip then
				tip = ui.newTip('SliderTip', true)
				tip.Place = function()
					if hoverEntry then
						local point = inputService:GetMouseLocation() + scaledgui.AbsolutePosition
						hoverEntry.Check(ui.within(point, hit.AbsolutePosition, hit.AbsoluteSize))
					end
					if tip.Label.Visible then
						placeTip(false)
					end
				end
				pcall(function()
					holder.Destroying:Connect(function()
						tip.Label:Destroy()
					end)
				end)
			end
			tip.Label.Text = sliderText(component.value, props.suffix, props.decimal)
			placeTip(not tip.Label.Visible)
		elseif tip then
			ui.tipHide(tip)
		end
	end
	props.changed = props.changed or function() end
	props.decimal = props.decimal or 1

	function component:recolor(hue, sat, val, isRainbow)
		fill.BackgroundColor3 = accentFor(self.index, 0.075, hue, sat, val, isRainbow)
		dot.BackgroundColor3 = fill.BackgroundColor3
	end

	function component:load(value)
		if not isFiniteNumber(value) then return end
		value = math.clamp(value, props.min or 0, self.limit)
		if self.value ~= value then
			self:set(value, nil, true)
		end
	end

	function component:save()
		return self.value
	end

	function component:set(value, position, wasReleased)
		if not isFiniteNumber(value) then
			return
		end

		where = position or fraction(value)
		fill.Size = UDim2.fromScale(where, 1)
		knob.Position = UDim2.fromScale(where, 0.5)
		if tip and tip.Label.Visible then
			placeTip(false)
		end

		if self.value ~= value or wasReleased then
			self.value = value
			valuelabel.Text = sliderText(self.value, props.suffix, props.decimal)
			if tip then
				tip.Label.Text = valuelabel.Text
			end
			props.changed(value, wasReleased)
			slinky:requestSave()
		end
	end

	local function editValue()
		custombox.Visible = true
		valuelabel.Visible = false
		ui.startSliderEdit(custombox, component.value)
	end

	hit.InputBegan:Connect(function(input)
		if not isPress(input) then return end
		if inputService:IsKeyDown(Enum.KeyCode.LeftControl) or inputService:IsKeyDown(Enum.KeyCode.RightControl) then
			editValue()
			return
		end
		dragging = true
		showTip()
		trackDrag(input, holder, function(position)
			component:set(math.floor((props.min + (props.max - props.min) * position) * props.decimal) / props.decimal, position)
		end, function(position)
			component:set(component.value, position, true)
			dragging = false
			showTip()
		end)
	end)

	hoverEntry = ui.hover(hit, function()
		hovering = true
		showTip()
	end, function()
		hovering = false
		showTip()
	end, function(point)
		local corner, size = holder.AbsolutePosition, holder.AbsoluteSize
		local middle = corner.Y + size.Y / 2
		return point.X >= corner.X and point.X <= corner.X + size.X and math.abs(point.Y - middle) <= 10.5 * size.Y / 4
	end)

	valuelabel.MouseButton1Click:Connect(editValue)

	custombox.FocusLost:Connect(function(enter)
		custombox.Visible = false
		valuelabel.Visible = isMobile()

		local typed = (enter or isMobile()) and ui.sliderTyped(custombox.Text, props, props.min or 0, component.limit)
		if typed then
			component:set(typed, nil, true)
		end
	end)

	api.options[props.name] = component

	return object(component, props.name)
end

--[[ The Targets option: Players and NPCs chips, the Ignore invisible and Ignore behind walls switches,
and Ignore Milo on a module that asks for it (props.milo): the BedWars modules skip a player Milo
has hidden as a block. The title turns red when neither chip is on. Loading sets only the keys the
saved value has; milo is saved off as well as on, or a profile that turned it off would load it back
on. ]]
components.targets = function(props, children, api)
	local component = {
		kind = 'targets',
		index = getTableSize(api.options)
	}

	local targets = ui.new('Frame', {
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = theme.Card,
		BackgroundTransparency = 1,
		LayoutOrder = props.order or 0,
		Size = UDim2.new(1, 0, 0, 0),
		Visible = props.visible == nil or props.visible
	}, children)
	component.row = targets
	component.window = targets
	ui.list(targets, 0)
	local line = ui.row(targets, {order = 1})
	local title = ui.rowLabel(line, {name = 'Targets', sub = props.sub})
	addTooltip(line, props.about)
	local chips = ui.new('Frame', {
		Name = 'Chips',
		AnchorPoint = Vector2.new(1, 0.5),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundTransparency = 1,
		Position = UDim2.new(1, -theme.Inset, 0.5, 0),
		Size = UDim2.fromOffset(0, 24)
	}, line)
	ui.list(chips, 6, true, Enum.HorizontalAlignment.Right)
	props.changed = props.changed or function() end

	function component:recolor(hue, sat, val, isRainbow)
		local accent = accentFor(self.index, 0.075, hue, sat, val, isRainbow)
		for _, chip in {self.players, self.npcs} do
			if chip.enabled then
				chip:paint(accent)
			end
		end
		self.invisible:recolor(hue, sat, val, isRainbow)
		self.walls:recolor(hue, sat, val, isRainbow)
		if self.milo then
			self.milo:recolor(hue, sat, val, isRainbow)
		end
	end

	function component:load(value)
		if type(value) ~= 'table' then return end
		for _, key in {'players', 'npcs', 'invisible', 'walls', 'milo'} do
			local switch = self[key]
			if switch and type(value[key]) == 'boolean' and switch.enabled ~= value[key] then
				switch:flip()
			end
		end
	end

	function component:save()
		return {
			players = self.players.enabled,
			npcs = self.npcs.enabled,
			invisible = self.invisible.enabled,
			walls = self.walls.enabled,
			milo = self.milo and self.milo.enabled
		}
	end

	function component:updateText()
		local any = self.players.enabled or self.npcs.enabled
		title.TextColor3 = any and (props.sub and theme.SubText or theme.Label) or theme.Red
	end

	component.players = components.targetsButton({
		text = 'Players',
		order = 1,
		targets = component,
		about = 'Target players',
		changed = props.changed
	}, chips, chips)

	component.npcs = components.targetsButton({
		text = 'NPCs',
		order = 2,
		targets = component,
		about = 'Target NPCs',
		changed = props.changed
	}, chips, chips)

	component.invisible = components.toggle({
		name = 'Ignore invisible',
		sub = true,
		order = 2,
		changed = function()
			props.changed()
		end
	}, targets, {options = {}})

	component.walls = components.toggle({
		name = 'Ignore behind walls',
		sub = true,
		order = 3,
		changed = function()
			props.changed()
		end
	}, targets, {options = {}})

	if props.milo ~= nil then
		component.milo = components.toggle({
			name = 'Ignore Milo',
			sub = true,
			order = 4,
			about = 'Players hidden as a block by Milo are not targeted.',
			changed = function()
				props.changed()
			end
		}, targets, {options = {}})
	end

	if props.players then
		component.players:flip()
	end

	if props.npcs then
		component.npcs:flip()
	end

	if props.invisible then
		component.invisible:flip()
	end

	if props.walls then
		component.walls:flip()
	end

	if props.milo then
		component.milo:flip()
	end
	component:updateText()

	api.options.Targets = component

	return object(component, 'Targets')
end

--[[ A Targets chip (Players, NPCs): on, it fills with the accent; off, its text goes from #999999 to
#BBBBBB under the pointer. ]]
components.targetsButton = function(props, children, api)
	local component = {
		kind = 'targetsButton',
		enabled = false
	}

	local targetsbutton = ui.text(children, {Class = 'TextButton', Text = props.text or 'Target', Size = 13, Weight = 'Medium', Color = theme.SubText, AlignX = Enum.TextXAlignment.Center, Props = {
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = theme.Card,
		BackgroundTransparency = 0,
		LayoutOrder = props.order or 0,
		Size = UDim2.fromOffset(0, 24),
		Visible = props.visible == nil or props.visible
	}})
	ui.corner(targetsbutton, UDim.new(1, 0))
	ui.padding(targetsbutton, 12, 12, 0, 0)
	local stroke = ui.stroke(targetsbutton, theme.Outline, 1, 0.1)
	component.row = targetsbutton
	addTooltip(targetsbutton, props.about)
	props.changed = props.changed or function() end

	local hovered = false
	function component:paint(accent)
		if self.enabled then
			targetsbutton.BackgroundColor3 = accent or theme.Accent()
			targetsbutton.TextColor3 = theme.Knob
			stroke.Enabled = false
		else
			targetsbutton.BackgroundColor3 = theme.Card
			targetsbutton.TextColor3 = hovered and theme.SubTextLit or theme.SubText
			stroke.Enabled = true
		end
	end
	ui.hover(targetsbutton, function()
		hovered = true
		if not component.enabled then
			targetsbutton.TextColor3 = theme.SubTextLit
		end
	end, function()
		hovered = false
		if not component.enabled then
			targetsbutton.TextColor3 = theme.SubText
		end
	end)

	function component:flip()
		self.enabled = not self.enabled
		self:paint()

		props.targets:updateText()
		props.changed(self.enabled)
		slinky:requestSave()
	end

	targetsbutton.MouseButton1Click:Connect(function()
		component:flip()
	end)

	return object(component, props.text)
end

--[[ A text option in a pill. The pill clips, so a pasted blob (a 20,000-character FFlag list) stays
inside it, and MultiLine and TextWrapped restate the TextBox defaults so nothing that styles the box
turns them on. The Text-changed handler only records the text: BedWars fires property-changed
handlers immediately, and writing the box back or running the callback and a save on every keystroke
or paste is the pattern that crashes clients. What is owed, one callback and one save with
FocusLost's enter, runs deferred once the signal has returned, and not at all after an unload. A
transient box (the import boxes) is never restored and is saved empty. ]]
components.textbox = function(props, children, api)
	local component = {
		kind = 'textbox',
		index = 0,
		value = props.default or ''
	}

	local textbox = ui.row(children, props)
	component.row = textbox
	ui.rowLabel(textbox, props)
	addTooltip(textbox, props.about)
	local holder = ui.pill(textbox, {Class = 'Frame'})
	holder.ClipsDescendants = true
	local inputbox = ui.text(holder, {Class = 'TextBox', Size = 14, Color = theme.Text, Props = {
		ClearTextOnFocus = false,
		MultiLine = false,
		PlaceholderColor3 = theme.Muted,
		PlaceholderText = props.placeholder or 'Click to set',
		Position = UDim2.fromOffset(12, 0),
		Size = UDim2.new(1, -24, 1, 0),
		Text = props.default or '',
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextWrapped = false
	}})
	ui.hover(holder, function()
		inputbox.TextColor3 = theme.Lit
	end, function()
		inputbox.TextColor3 = theme.Text
	end)
	props.changed = props.changed or function() end

	local owed, owedEnter = false, nil
	local function settle()
		if not owed then return end
		owed = false
		local enter = owedEnter
		owedEnter = nil
		if slinky.loaded == nil then return end
		props.changed(enter)
		slinky:requestSave()
	end
	local function owe(enter)
		if enter ~= nil then
			owedEnter = enter
		end
		if not owed then
			owed = true
			task.defer(settle)
		end
	end

	component.transient = props.transient and true or nil

	function component:load(value)
		if props.transient or type(value) ~= 'string' then return end
		if self.value ~= value then
			self:set(value)
		end
	end

	function component:save()
		return props.transient and '' or self.value
	end

	function component:set(val, enter)
		owed, owedEnter = false, nil
		self.value = val
		inputbox.Text = val
		props.changed(enter)
		slinky:requestSave()
	end

	inputbox.FocusLost:Connect(function(enter)
		component.value = inputbox.Text
		owe(enter == true)
	end)

	inputbox:GetPropertyChangedSignal('Text'):Connect(function()
		local text = inputbox.Text
		if text == component.value then return end
		component.value = text
		owe()
	end)

	api.options[props.name] = component

	return object(component, props.name)
end

--[[ A text list option: a pill with the entry count that opens an editor of rows, each with a dot that
turns it on or off and an x that removes it, and a box to add one. The default is cloned for both
items and active; shared, editing one list would edit every list built from it. Saved as the entries
alone when every one is on, else as {items, active}. A phone's keyboard is usually closed by tapping
away, so there any focus loss submits. ]]
components.list = function(props, children, api)
	local component = {
		kind = 'list',
		index = getTableSize(api.options),
		items = props.default and table.clone(props.default) or {},
		active = props.default and table.clone(props.default) or {},
		objects = {},
		window = {Visible = false}
	}

	props.color = props.color or Color3.fromRGB(243, 93, 18)
	local textlist = ui.new('Frame', {
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = props.order or 0,
		Size = UDim2.new(1, 0, 0, 0),
		Visible = props.visible == nil or props.visible
	}, children)
	component.row = textlist
	ui.list(textlist, 0)
	local line = ui.row(textlist, {order = 1})
	ui.rowLabel(line, props)
	addTooltip(line, props.about)
	local button = ui.pill(line, {})
	button.Name = 'Toggle'
	local amount = ui.text(button, {Text = '0 entries', Size = 14, Color = theme.Text, AlignX = Enum.TextXAlignment.Center, Props = {
		Position = UDim2.fromOffset(12, 0), Size = UDim2.new(1, -36, 1, 0), TextTruncate = Enum.TextTruncate.AtEnd
	}})
	local chevron = ui.icon(button, 'chevron-right', 13, {Color = theme.SubText, NoMirror = true, Props = {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -8, 0.5, 0)
	}})
	ui.hover(button, function()
		amount.TextColor3 = theme.Lit
		ui.paintIcon(chevron, theme.SubTextLit)
	end, function()
		amount.TextColor3 = theme.Text
		ui.paintIcon(chevron, theme.SubText)
	end)

	local textlistwindow = ui.new('Frame', {
		Name = 'Editor',
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = 2,
		Size = UDim2.new(1, 0, 0, 0),
		Visible = false
	}, textlist)
	component.window = textlistwindow
	ui.list(textlistwindow, 2)
	ui.padding(textlistwindow, 0, 0, 2, 6)
	local addrow = ui.row(textlistwindow, {order = -1}, 34)
	local boxholder = ui.pill(addrow, {Class = 'Frame', AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, theme.Inset + 12, 0.5, 0), Size = UDim2.new(1, -(theme.Inset * 2 + 12), 0, 26)})
	local textbox = ui.text(boxholder, {Class = 'TextBox', Size = 14, Color = theme.Text, Props = {
		ClearTextOnFocus = false,
		PlaceholderColor3 = theme.Muted,
		PlaceholderText = props.placeholder or 'Add entry...',
		Position = UDim2.fromOffset(12, 0),
		Size = UDim2.new(1, -44, 1, 0)
	}})
	local add = ui.icon(boxholder, 'plus', 14, {Class = 'TextButton', Color = theme.SubText, NoMirror = true, Props = {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -6, 0.5, 0)
	}})
	ui.hover(add, function()
		ui.paintIcon(add, theme.SubTextLit)
	end, function()
		ui.paintIcon(add, theme.SubText)
	end)
	props.changed = props.changed or function() end

	function component:recolor(hue, sat, val, isRainbow) end

	function component:change(value)
		if value then
			local index = table.find(self.items, value)
			if index then
				table.remove(self.items, index)

				index = table.find(self.active, value)
				if index then
					table.remove(self.active, index)
				end
			else
				table.insert(self.items, value)
				table.insert(self.active, value)
			end
		end

		props.changed(self.items)
		if value ~= nil then
			slinky:requestSave()
			ui.rehoverSoon()
		end
		for _, v in self.objects do
			v:Destroy()
		end
		table.clear(self.objects)
		amount.Text = #self.items..(#self.items == 1 and ' entry' or ' entries')

		for index, value in self.items do
			local isEnabled = table.find(self.active, value)
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
				BackgroundColor3 = isEnabled and props.color or theme.Muted,
				Position = UDim2.new(0, theme.Inset + 12, 0.5, 0),
				Size = UDim2.fromOffset(12, 12)
			}, obj)
			ui.corner(dot, UDim.new(1, 0))
			local dotin = ui.new('Frame', {
				BackgroundColor3 = isEnabled and props.color or theme.Card,
				Position = UDim2.fromOffset(2, 2),
				Size = UDim2.fromOffset(8, 8)
			}, dot)
			ui.corner(dotin, UDim.new(1, 0))
			ui.text(obj, {Text = value, Size = 14, Color = theme.Label, Props = {
				Position = UDim2.fromOffset(theme.Inset + 34, 0), Size = UDim2.new(1, -(theme.Inset * 2 + 60), 1, 0), TextTruncate = Enum.TextTruncate.AtEnd
			}})
			local close = ui.icon(obj, 'x', 13, {Class = 'TextButton', Color = theme.CloseRest, NoMirror = true, Props = {
				AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -theme.Inset + 4, 0.5, 0)
			}})
			ui.hover(close, function()
				ui.paintIcon(close, theme.Red)
			end, function()
				ui.paintIcon(close, theme.CloseRest)
			end)

			close.MouseButton1Click:Connect(function()
				self:change(value)
			end)

			obj.MouseButton1Click:Connect(function()
				local found = table.find(self.active, value)
				if found then
					table.remove(self.active, found)
					dot.BackgroundColor3 = theme.Muted
					dotin.BackgroundColor3 = theme.Card
				else
					table.insert(self.active, value)
					dot.BackgroundColor3 = props.color
					dotin.BackgroundColor3 = props.color
				end

				props.changed()
				slinky:requestSave()
			end)

			table.insert(self.objects, obj)
		end
	end

	function component:load(value)
		if type(value) ~= 'table' then return end
		self.items, self.active = store.listed(value)
		self:change()
	end

	function component:save()
		return store.list(self.items, self.active)
	end

	local function submit()
		if textbox.Text ~= '' and not table.find(component.items, textbox.Text) then
			component:change(textbox.Text)
			textbox.Text = ''
		end
	end

	add.MouseButton1Click:Connect(submit)

	textbox.FocusLost:Connect(function(enter)
		if enter or isMobile() then
			submit()
		end
	end)

	button.MouseButton1Click:Connect(function()
		textlistwindow.Visible = not textlistwindow.Visible
		ui.setIcon(chevron, textlistwindow.Visible and 'chevron-down' or 'chevron-right')
	end)

	if props.default then
		component:change()
	end

	api.options[props.name] = component

	return object(component, props.name)
end

--[[ An on/off option, with a slot left of the switch for a key bound to it. Saved as true or false, or
with a key bound as {__on, __bind, __hold, __mobile}; a plain true or false means no bind, so a bind
left from the profile before is cleared. ]]
components.toggle = function(props, children, api)
	local component = {
		kind = 'toggle',
		name = props.name,
		index = getTableSize(api.options),
		enabled = false
	}

	local toggle = ui.row(children, props)
	component.row = toggle
	local title = ui.rowLabel(toggle, props, 70)
	local hit = ui.new('TextButton', {
		Name = 'Hit',
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Text = ''
	}, toggle)
	local switch = ui.switch(toggle)
	addRowTooltip(hit, props.about, switch.Object, title)
	local slot = ui.new('Frame', {
		Name = 'BindSlot',
		AnchorPoint = Vector2.new(1, 0.5),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundTransparency = 1,
		Position = UDim2.new(1, -(theme.Inset + 48), 0.5, 0),
		Size = UDim2.fromOffset(0, 20)
	}, toggle)
	ui.list(slot, 0, true, Enum.HorizontalAlignment.Right)
	component.bindParent = slot
	props.changed = props.changed or function() end

	function component:recolor(hue, sat, val, isRainbow)
		if self.enabled then
			switch:Color(accentFor(self.index, 0.075, hue, sat, val, isRainbow))
		end
	end

	function component:load(value)
		local on = value
		if type(value) == 'table' then
			on = value.__on
		end
		if type(on) == 'boolean' and self.enabled ~= on then
			self:flip()
		end

		if self.bind then
			self.bind:load(store.bindOf(type(value) == 'table' and value or {}))
		end
	end

	function component:save()
		if self.bind then
			local value = {}
			store.bindInto(value, self.bind)
			if next(value) ~= nil then
				value.__on = self.enabled
				return value
			end
		end
		return self.enabled
	end

	function component:flip()
		self.enabled = not self.enabled
		switch:Set(self.enabled, liveAccent(self.index))

		props.changed(self.enabled)
		slinky:requestSave()
	end

	hit.MouseButton1Click:Connect(function()
		component:flip()
	end)

	if props.default then
		component:flip()
	end

	api.options[props.name] = component

	return object(component)
end

--[[ Builds a two-knob range slider: a min and a max on one track, saved as {min, max} and kept between
the slider's Min and max on load. A press moves whichever knob is nearer; Ctrl+click types that
knob's value instead. No min and max text at rest, as in Slinky: on a phone the two ends sit beside
the name, where a tap types one.

One hint, as Slinky's: while the track is hovered with a mouse it shows the whole range over the
middle of the fill (one value when the ends meet), and while a knob is dragged, by a finger too,
that knob's value over that knob. Its hover zone is the track's length and 10.5 px either side of
the centre line. It is built the first time it shows, and shows only while the row is open, on its
tab and inside its page.

A dragged knob glides to the pointer in 0.1 s, so a fast drag trails by as much; a change from code
moves it in the same frame. A held knob's hint follows it through a RenderStepped step, never a
handler on the knob's Position. A typed max under the min brings the min down with it, and a typed
min over the max takes the max up, instead of reversing the range. random reads component, not self,
because callers use it with and without a colon. ]]
components.range = function(props, children, api)
	local component = {
		kind = 'range',
		index = getTableSize(api.options),
		limit = props.max,
		min = props.defaultMin or props.min,
		max = props.defaultMax or 10
	}

	local twoslider = ui.row(children, props)
	component.row = twoslider
	local left = ui.new('Frame', {
		Name = 'Left',
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(theme.Inset, 0),
		Size = UDim2.new(0.5, -theme.Inset, 1, 0)
	}, twoslider)
	ui.list(left, 6, true)
	ui.fitTitle(left, ui.text(left, {Text = props.label or props.name, Size = 15, Color = theme.Label, Props = {
		Name = 'Label', AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 1, Size = UDim2.fromOffset(0, theme.RowHeight)
	}}))
	local minvalue = ui.text(left, {Class = 'TextButton', Text = tostring(component.min), Size = 13, Color = theme.SubText, Props = {
		Name = 'Min', AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 2, Size = UDim2.fromOffset(0, theme.RowHeight), Visible = isMobile()
	}})
	local maxvalue = ui.text(left, {Class = 'TextButton', Text = tostring(component.max), Size = 13, Color = theme.SubText, Props = {
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
	local function sliderFraction(value)
		local low = props.min or 0
		return math.clamp((value - low) / math.max(props.max - low, 1e-9), 0, 1)
	end
	local drawn = {Min = sliderFraction(component.min), Max = sliderFraction(component.max)}
	local fill = ui.new('Frame', {
		BackgroundColor3 = theme.Accent(),
		BorderSizePixel = 0,
		Position = UDim2.fromScale(sliderFraction(component.min), 0),
		Size = UDim2.fromScale(math.max(sliderFraction(component.max) - sliderFraction(component.min), 0), 1)
	}, holder)
	local knob = ui.new('Frame', {
		Name = 'KnobMin',
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = theme.Accent(),
		Position = UDim2.fromScale(sliderFraction(component.min), 0.5),
		Size = UDim2.fromOffset(12, 12)
	}, holder)
	ui.corner(knob, UDim.new(1, 0))
	local knobmax = ui.new('Frame', {
		Name = 'KnobMax',
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = theme.Accent(),
		Position = UDim2.fromScale(sliderFraction(component.max), 0.5),
		Size = UDim2.fromOffset(12, 12)
	}, holder)
	ui.corner(knobmax, UDim.new(1, 0))
	local hit = ui.new('TextButton', {
		Name = 'Hit',
		AnchorPoint = Vector2.new(1, 0),
		BackgroundTransparency = 1,
		Position = UDim2.new(1, 0, 0, 0),
		Size = UDim2.new(0.5, 0, 1, 0),
		Text = ''
	}, twoslider)
	local tip, hoverEntry, follow
	local hovering, dragging = false, nil
	local function tipText()
		if dragging then
			return sliderText(dragging == 'Max' and component.max or component.min, props.suffix, props.decimal)
		end
		local low, high = math.min(component.min, component.max), math.max(component.min, component.max)
		if low == high then
			return sliderText(low, props.suffix, props.decimal)
		end
		return sliderText(low, nil, props.decimal)..' - '..sliderText(high, props.suffix, props.decimal)
	end
	local function placeTip(appearing)
		local corner, size = holder.AbsolutePosition, holder.AbsoluteSize
		local low, high = knob.Position.X.Scale, knobmax.Position.X.Scale
		local where = dragging == 'Max' and high or dragging == 'Min' and low or (low + high) / 2
		local centre = Vector2.new(corner.X + where * size.X, corner.Y + size.Y / 2)
		if not ui.rowShowing(holder, centre) then
			ui.tipHide(tip)
			return
		end
		local s = math.max(scale.Scale, 0.05)
		local zoom = layout and layout.Zoom or 1
		local origin = scaledgui.AbsolutePosition
		ui.tipPlace(tip, (centre.X - origin.X) / s, (centre.Y - origin.Y) / s - (10 + 20) * zoom, 20, appearing)
	end
	local function showTips()
		if hovering or dragging then
			if not tip then
				tip = ui.newTip('SliderTip', true)
				tip.Place = function()
					if hoverEntry then
						local point = inputService:GetMouseLocation() + scaledgui.AbsolutePosition
						hoverEntry.Check(ui.within(point, hit.AbsolutePosition, hit.AbsoluteSize))
					end
					if tip.Label.Visible then
						placeTip(false)
					end
				end
				pcall(function()
					holder.Destroying:Connect(function()
						tip.Label:Destroy()
					end)
				end)
			end
			tip.Label.Text = tipText()
			placeTip(not tip.Label.Visible)
		elseif tip then
			ui.tipHide(tip)
		end
	end
	local function setFollow(on)
		if on and not follow then
			follow = runService.RenderStepped:Connect(function()
				if tip and tip.Label.Visible then
					placeTip(false)
				end
			end)
		elseif not on and follow then
			follow:Disconnect()
			follow = nil
		end
	end
	props.changed = props.changed or function() end
	props.decimal = props.decimal or 1
	local random = Random.new()

	function component:recolor(hue, sat, val, isRainbow)
		fill.BackgroundColor3 = accentFor(self.index, 0.075, hue, sat, val, isRainbow)
		knob.BackgroundColor3 = fill.BackgroundColor3
		knobmax.BackgroundColor3 = fill.BackgroundColor3
	end

	function component:random()
		local low, high = component.min, component.max
		if low > high then
			low, high = high, low
		end
		return random:NextNumber(low, high)
	end

	function component:load(value)
		if type(value) ~= 'table' then return end
		local newMin, newMax = value.min, value.max
		if isFiniteNumber(newMin) then
			newMin = math.clamp(newMin, props.min or 0, self.limit)
		end
		if isFiniteNumber(newMax) then
			newMax = math.clamp(newMax, props.min or 0, self.limit)
		end

		if self.min ~= newMin then
			self:set(false, newMin)
		end

		if self.max ~= newMax then
			self:set(true, newMax)
		end
	end

	function component:save()
		return {
			min = self.min,
			max = self.max
		}
	end

	local GLIDE = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local function drawKnob(isMax, where, glide)
		drawn[isMax and 'Max' or 'Min'] = where
		local low, high = drawn.Min, drawn.Max
		local goals = {
			[fill] = {Position = UDim2.fromScale(math.min(low, high), 0), Size = UDim2.fromScale(math.abs(high - low), 1)},
			[knob] = {Position = UDim2.fromScale(low, 0.5)},
			[knobmax] = {Position = UDim2.fromScale(high, 0.5)}
		}
		for object, goal in goals do
			if glide then
				tween:Tween(object, GLIDE, goal)
			else
				tween:Cancel(object)
				for key, value in goal do
					object[key] = value
				end
			end
		end
		if tip and tip.Label.Visible then
			showTips()
		end
	end

	function component:set(isMax, value, position)
		if not isFiniteNumber(value) then
			return
		end

		self[isMax and 'max' or 'min'] = value
		maxvalue.Text = tostring(self.max)
		minvalue.Text = tostring(self.min)

		drawKnob(isMax, type(position) == 'number' and math.clamp(position, 0, 1) or sliderFraction(value), type(position) == 'number')

		props.changed(self.min, self.max, isMax)
		slinky:requestSave()
	end

	hit.InputBegan:Connect(function(input)
		if not isPress(input) then return end
		local start = math.clamp((input.Position.X - holder.AbsolutePosition.X) / math.max(holder.AbsoluteSize.X, 1), 0, 1)
		local maxCheck = math.abs(start - sliderFraction(component.max)) <= math.abs(start - sliderFraction(component.min))
		if inputService:IsKeyDown(Enum.KeyCode.LeftControl) or inputService:IsKeyDown(Enum.KeyCode.RightControl) then
			local box = maxCheck and custommax or custommin
			box.Visible = true
			ui.startSliderEdit(box, maxCheck and component.max or component.min)
			return
		end
		dragging = maxCheck and 'Max' or 'Min'
		showTips()
		setFollow(true)
		trackDrag(input, holder, function(position)
			local value = math.floor((props.min + (props.max - props.min) * position) * props.decimal) / props.decimal
			if value ~= component[maxCheck and 'max' or 'min'] then
				component:set(maxCheck, value, position)
			else
				drawKnob(maxCheck, position, true)
			end
		end, function()
			dragging = nil
			setFollow(false)
			showTips()
			task.delay(GLIDE.Time + 0.02, function()
				if tip and tip.Label.Visible and not dragging then
					placeTip(false)
				end
			end)
		end)
	end)
	hoverEntry = ui.hover(hit, function()
		hovering = true
		showTips()
	end, function()
		hovering = false
		showTips()
	end, function(point)
		local corner, size = holder.AbsolutePosition, holder.AbsoluteSize
		local middle = corner.Y + size.Y / 2
		return point.X >= corner.X and point.X <= corner.X + size.X and math.abs(point.Y - middle) <= 10.5 * size.Y / 4
	end)

	maxvalue.MouseButton1Click:Connect(function()
		maxvalue.Visible = false
		custommax.Visible = true
		ui.startSliderEdit(custommax, component.max)
	end)

	minvalue.MouseButton1Click:Connect(function()
		minvalue.Visible = false
		custommin.Visible = true
		ui.startSliderEdit(custommin, component.min)
	end)

	custommax.FocusLost:Connect(function(enter)
		custommax.Visible = false
		maxvalue.Visible = isMobile()

		local typed = (enter or isMobile()) and ui.sliderTyped(custommax.Text, props, props.min or 0, component.limit)
		if typed then
			if typed < component.min then
				component:set(false, typed)
			end
			component:set(true, typed)
		end
	end)

	custommin.FocusLost:Connect(function(enter)
		custommin.Visible = false
		minvalue.Visible = isMobile()

		local typed = (enter or isMobile()) and ui.sliderTyped(custommin.Text, props, props.min or 0, component.limit)
		if typed then
			if typed > component.max then
				component:set(true, typed)
			end
			component:set(false, typed)
		end
	end)

	api.options[props.name] = component

	return object(component, props.name)
end

--[[ Makes a component kind added later reach every container. rawset comes first: without it the
components table never receives the entry, and every container built afterwards misses the method
(AutoHotbar is created further down the file that registers hotbarList). The creator is then bound
into every container that has already bound the table, not only modules, since a category or an
overlay can hold options too. ]]
slinky.components = setmetatable(components, {
	__newindex = function(self, key, create)
		rawset(self, key, create)

		for container, children in componentChildren do
			rawset(container, key, creator(create, children, container))
		end
	end
})

slinky:build()

return object(slinky, 'slinky', 'root')
