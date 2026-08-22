local vape = {
	ActiveBinds = {},
	Categories = {},
	GUIColor = {
		Hue = 0.46,
		Sat = 0.96,
		Value = 0.52
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
	--[[ Bumped by every vape:Load. Load yields now, so a second load can stop the older one
	while it is still walking instead of interleaving writes into the same modules. ]]
	LoadGeneration = 0,
	--[[ Modules past this index in ModuleOrder arrived after the last profile application. ]]
	LoadedCount = 0,
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

local hasUIShadow = classExists('UIShadow')
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

--[[ The old GUI's rescale, restored exactly: never below half size, never above 1:1.

The rewrite had math.max(width / 1920, 0.6) -- no upper bound at all. Phones report their
render resolution here, so a 2400-wide handset asked for a 1.25x menu on the smallest screen
in the lineup, and the window ran off the edge with no way to drag it back. ]]
local function autoScaleValue()
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
	Overridable via getgenv().PistonwareYieldBudget, because the right number depends on how fast
	the device is and how many modules the profile carries.
]]
local buildclock = os.clock()
local yieldBudget = 0.01
pcall(function()
	local override = tonumber(((getgenv and getgenv().PistonwareYieldBudget) or shared.PistonwareYieldBudget))
	if override and override > 0 then
		yieldBudget = override
	end
end)
local function yieldBuild(budget)
	if os.clock() - buildclock > (budget or yieldBudget) then
		task.wait()
		buildclock = os.clock()
	end
end

--[[
	Breadcrumbs that survive a native crash. Off unless asked for.

		getgenv().PistonwareTrace = true

	A crash that takes the client's process down leaves no error and no traceback, so the only
	record that outlives it is one already on disk. Each crumb is written BEFORE the thing it
	names runs; after a crash the last line is where it got to.

	Written to the filesystem ROOT, not under pistonware/, because reinstall.lua deletes that
	folder and would take the evidence with it.

	Where the crumbs go is deliberate. There are NONE inside the profile apply loop, because a
	file write there yields, and that yield is what made the previous trace change the very
	behaviour it was supposed to be observing -- turning it on "fixed" the crash and turning it
	off brought it back, which cost a lot of time to untangle. The per-module crumbs live in the
	start queue's drain thread instead, which already waits a whole frame per module: a write
	there cannot change the pacing, because the thread is going to yield regardless.
]]
local traceOn = false
pcall(function()
	traceOn = (((getgenv and getgenv().PistonwareTrace) or shared.PistonwareTrace) and true) or false
end)

local traceLog = shared.PistonwareTraceLines or {}
shared.PistonwareTraceLines = traceLog

local function trace(text)
	if not traceOn then
		return
	end

	table.insert(traceLog, text)
	-- Rewritten whole rather than appended: appendfile is missing on several mobile executors,
	-- and a breadcrumb that only works on desktop is no use for a crash that only happens on
	-- mobile. Capped so the string being rebuilt each time stays small.
	if #traceLog > 200 then
		table.remove(traceLog, 1)
	end
	pcall(writefile, 'pistonware_trace.txt', table.concat(traceLog, '\n'))
end

-- Lua heap in KB. gcinfo on Roblox, collectgarbage('count') as the portable fallback.
local function heapKB()
	local kb = 0
	pcall(function() kb = gcinfo and gcinfo() or collectgarbage('count') end)
	return kb
end

trace('gui chunk running')

--[[
	A paced starter for modules switched on by a profile apply.

	task.spawn resumes its function inline, on the calling thread, until that function first
	yields -- so applying a profile used to run each module's whole setup synchronously inside
	the apply loop, sixty of them nose to tail with no yield reachable in between.

	task.defer fixes only half of that. It gets the setup out of the loop, but every deferred
	function then runs back to back in the same resumption cycle: the same unbroken block of
	work, moved rather than broken up.

	So they go through a queue that yields between them, and modules come online over a second
	or two instead of all in one instant. This is what the per-module trace was doing by
	accident -- its file write yielded between one module's startup and the next -- which is why
	tracing stopped the crash and removing it brought the crash back.

	One drain thread at a time, and it exits when the queue empties, so nothing is left running
	between applies.
]]
--[[
	What happens AFTER every module has started.

	The crumbs used to stop at the last 'ok', and that turned out to be exactly where the
	interesting part begins: a log showed all sixty modules starting and finishing cleanly, then
	the client dying moments later with nothing else recorded. By then every enabled module is
	running its own per-frame loop, all of them at once for the first time, and none of the
	earlier instrumentation could see into that window.

	So this samples the frames that follow. Frame delta says whether the client is choking on
	CPU -- a number that climbs from 16ms into the hundreds is a client being killed for not
	responding, which looks nothing like the heap number climbing instead.

	Written every fifteenth frame rather than every frame, carrying the last twenty deltas with
	it. A write per frame would be a file write inside the very window being measured, which is
	the mistake the previous trace made and the reason it kept changing its own answer.
]]
local settledWatched = false
local function watchSettled()
	if not traceOn or settledWatched then
		return
	end

	settledWatched = true
	task.spawn(function()
		local deltas = {}
		local last = os.clock()
		local started = last

		for frame = 1, 900 do
			task.wait()
			local now = os.clock()
			table.insert(deltas, ('%.0f'):format((now - last) * 1000))
			if #deltas > 20 then
				table.remove(deltas, 1)
			end
			last = now

			if frame % 15 == 0 then
				trace(('settled %.1fs heap=%dKB dt=%s'):format(now - started, heapKB(), table.concat(deltas, ',')))
			end
		end

		trace('settled watch finished')
	end)
end

local startQueue = {}
local startThread
local function queueStart(name, callback)
	table.insert(startQueue, {Name = name, Start = callback})

	if startThread then
		return
	end

	startThread = task.spawn(function()
		while #startQueue > 0 do
			-- Yield BEFORE the first job, not after it. task.spawn resumes this thread inline on
			-- the caller, so taking a job first would run one module synchronously inside the
			-- apply loop -- the exact thing being fixed, just once instead of sixty times.
			task.wait()
			local job = table.remove(startQueue, 1)
			--[[
				Crumbs on both sides, and here they mean something they could not mean before.

				Startups used to overlap across sixty threads, so an unmatched 'start X' named
				nothing -- any module whose function is a loop never reaches its closing crumb.
				The queue makes them strictly serial, one per frame, so a 'start X' with no
				'ok X' after it is the module that took the client down.
			]]
			trace('start '..tostring(job.Name)..' heap='..heapKB()..'KB')
			-- spawn, not a direct call: a module that errors on startup must not take the drain
			-- thread down with it and strand every module still queued behind it.
			task.spawn(job.Start, true)
			trace('ok '..tostring(job.Name))
		end

		startThread = nil
		watchSettled()
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

local function getfontbounds(text, size, font)
	fontsize.Text = text
	fontsize.Size = size
	if typeof(font) == 'Font' then
		fontsize.Font = font
	end

	return textService:GetTextBoundsAsync(fontsize)
end

do
	local vapeAssets = {
		['pistonware/assets/new/add.png'] = 'rbxassetid://121642387707174',
		['pistonware/assets/new/aim.png'] = 'rbxassetid://122207028123421',
		['pistonware/assets/new/allowedicon.png'] = 'rbxassetid://112336790299036',
		['pistonware/assets/new/allowediconmini.png'] = 'rbxassetid://90142384730147',
		['pistonware/assets/new/back.png'] = 'rbxassetid://80523803497740',
		['pistonware/assets/new/backmini.png'] = 'rbxassetid://85859225495272',
		['pistonware/assets/new/bind.png'] = 'rbxassetid://81399857677684',
		['pistonware/assets/new/bindbkg.png'] = 'rbxassetid://101996225428926',
		['pistonware/assets/new/blatant.png'] = 'rbxassetid://126929923309265',
		['pistonware/assets/new/blur.png'] = 'rbxassetid://79246816170155',
		['pistonware/assets/new/blurnoti.png'] = 'rbxassetid://124705876663719',
		['pistonware/assets/new/close.png'] = 'rbxassetid://121816018671466',
		['pistonware/assets/new/closemini.png'] = 'rbxassetid://108320409341289',
		['pistonware/assets/new/closetiny.png'] = 'rbxassetid://71393233149714',
		['pistonware/assets/new/colorpreview.png'] = 'rbxassetid://140438628568318',
		['pistonware/assets/new/combat.png'] = 'rbxassetid://94762732349053',
		['pistonware/assets/new/customtheme.png'] = 'rbxassetid://91756736022800',
		['pistonware/assets/new/discord.png'] = 'rbxassetid://99871463341003',
		['pistonware/assets/new/downexpand.png'] = 'rbxassetid://94197751291504',
		['pistonware/assets/new/downexpandslider.png'] = 'rbxassetid://90289944682645',
		['pistonware/assets/new/edit.png'] = 'rbxassetid://105801951237137',
		['pistonware/assets/new/editlarge.png'] = 'rbxassetid://119233876755282',
		['pistonware/assets/new/expandarrow.png'] = 'rbxassetid://86360332526471',
		['pistonware/assets/new/friends.png'] = 'rbxassetid://92957214042038',
		['pistonware/assets/new/inventory.png'] = 'rbxassetid://93264756888499',
		['pistonware/assets/new/legit_mode_icon.png'] = 'rbxassetid://102858626075156',
		['pistonware/assets/new/legit_switch.png'] = 'rbxassetid://127508881124779',
		['pistonware/assets/new/min.png'] = 'rbxassetid://82175054487146',
		['pistonware/assets/new/noti_alert.png'] = 'rbxassetid://82356478726846',
		['pistonware/assets/new/noti_info.png'] = 'rbxassetid://102614825645099',
		['pistonware/assets/new/noti_warning.png'] = 'rbxassetid://119631730212167',
		['pistonware/assets/new/notification.png'] = 'rbxassetid://90300780458781',
		['pistonware/assets/new/npcs.png'] = 'rbxassetid://104434365485227',
		['pistonware/assets/new/overlaydots.png'] = 'rbxassetid://78012624671930',
		['pistonware/assets/new/overlays.png'] = 'rbxassetid://136535637407545',
		['pistonware/assets/new/overlayslarge.png'] = 'rbxassetid://127574141208160',
		['pistonware/assets/new/pin.png'] = 'rbxassetid://92459145800579',
		['pistonware/assets/new/players.png'] = 'rbxassetid://105137446428129',
		['pistonware/assets/new/profiles.png'] = 'rbxassetid://126051451865127',
		['pistonware/assets/new/radar.png'] = 'rbxassetid://97983828696086',
		['pistonware/assets/new/rainbow_1.png'] = 'rbxassetid://101329996188554',
		['pistonware/assets/new/rainbow_2.png'] = 'rbxassetid://72739074644654',
		['pistonware/assets/new/rainbow_3.png'] = 'rbxassetid://100716555253397',
		['pistonware/assets/new/rainbow_4.png'] = 'rbxassetid://133424174227092',
		['pistonware/assets/new/range.png'] = 'rbxassetid://107794917650053',
		['pistonware/assets/new/rangeindicator.png'] = 'rbxassetid://107038094175283',
		['pistonware/assets/new/render.png'] = 'rbxassetid://125472576898654',
		['pistonware/assets/new/search.png'] = 'rbxassetid://115611852955611',
		['pistonware/assets/new/settingdots.png'] = 'rbxassetid://130896840048276',
		['pistonware/assets/new/settings.png'] = 'rbxassetid://73820177347303',
		['pistonware/assets/new/settingsmini.png'] = 'rbxassetid://115732118290997',
		['pistonware/assets/new/targetinfo.png'] = 'rbxassetid://121604266095276',
		['pistonware/assets/new/textgui.png'] = 'rbxassetid://99438663817412',
		['pistonware/assets/new/theme.png'] = 'rbxassetid://111525258317113',
		['pistonware/assets/new/utility.png'] = 'rbxassetid://108303206513893',
		['pistonware/assets/new/vape.png'] = 'rbxassetid://99295797606112',
		['pistonware/assets/new/vapelogo.png'] = 'rbxassetid://126205920310261',
		['pistonware/assets/new/vapelogomini.png'] = 'rbxassetid://109041903452149',
		['pistonware/assets/new/v4.png'] = 'rbxassetid://102549752760489',
		['pistonware/assets/new/v4mini.png'] = 'rbxassetid://115213099001611',
		['pistonware/assets/new/world.png'] = 'rbxassetid://118917453153459'
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
		if not hasContent(path) then
			local relPath = select(1, path:gsub('pistonware/', ''))
			local data
			for attempt = 1, 4 do
				local success, res = pcall(function()
					return game:HttpGet('https://raw.githubusercontent.com/themagicpiston/pistonware/main/'..relPath, true)
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

		if obj.Parent and (obj:IsA('UIStroke') or obj.Visible) then
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

uipallet = {
	Main = Color3.fromRGB(26, 25, 26),
	Text = Color3.fromRGB(200, 200, 200),
	Font = Font.fromEnum(Enum.Font.Arial),
	FontSemiBold = Font.fromEnum(Enum.Font.Arial, Enum.FontWeight.SemiBold),
	Tween = TweenInfo.new(0.16, Enum.EasingStyle.Linear)
}

do
	local data = isfile('pistonware/profiles/color.txt') and loadJson('pistonware/profiles/color.txt')
	if data then
		uipallet.Main = data.Main and Color3.fromRGB(unpack(data.Main)) or uipallet.Main
		uipallet.Text = data.Text and Color3.fromRGB(unpack(data.Text)) or uipallet.Text
		uipallet.Font = data.Font and Font.new(
			data.Font:find('rbxasset') and data.Font
			or string.format('rbxasset://fonts/families/%s.json', data.Font)
		) or uipallet.Font
		uipallet.FontSemiBold = Font.new(uipallet.Font.Family, Enum.FontWeight.SemiBold)
	end

	fontsize.Font = uipallet.Font
end

vape.Libraries = {
	color = color,
	getfontbounds = getfontbounds,
	getvapeasset = getvapeasset,
	tween = tween,
	uipallet = uipallet,

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
	UIShadow is a real blur the GPU computes every frame, and there are 14 of these -- one behind
	every window, the tooltip, the search box and the target-info panel.

	Two problems on a phone. It does not exist at all on the older client mobile executors ship,
	where Instance.new('UIShadow') throws and takes the window being built with it; and where it
	does exist, a dozen live blurs is exactly the kind of per-frame GPU work that makes a mobile
	client stutter and then die on memory pressure.

	So: real blur on desktop when the client has it, and otherwise the pre-baked blur PNG the old
	GUI used for all 14 of these. It is one ImageLabel, drawn once, and it looks near enough the
	same -- callers that already asked for it by passing `old` were using it for that reason.
]]
local useRealBlur = hasUIShadow and not inputService.TouchEnabled

local function addBlur(parent, notif, old)
	local blur
	if old or not useRealBlur then
		blur = Instance.new('ImageLabel')
		blur.Name = 'Blur'
		blur.Size = UDim2.new(1, 89, 1, 52)
		blur.Position = UDim2.fromOffset(-48, -31)
		blur.BackgroundTransparency = 1
		blur.Image = getvapeasset('pistonware/assets/new/'..(notif and 'blurnoti' or 'blur')..'.png')
		blur.ScaleType = Enum.ScaleType.Slice
		blur.SliceCenter = Rect.new(52, 31, 261, 502)
		blur.Parent = parent
	else
		blur = Instance.new('UIShadow')
		blur.BlurRadius = UDim.new(0, 13)
		blur.Transparency = 0.25
		blur.Parent = parent
	end

	return blur
end

--[[
	addBlur returns either a UIShadow or an ImageLabel, and callers toggle them differently.

	A UIShadow is switched with .Enabled. The blur PNG is an ImageLabel, which has no Enabled
	property at all -- assigning one throws 'Enabled is not a valid member of ImageLabel' and
	fails the injection. Every caller that turns a blur on or off goes through these instead of
	guessing which kind it got.

	ClassName rather than IsA, so this never depends on the client knowing the UIShadow class.
]]
local function setBlurEnabled(blur, enabled)
	if not blur then return end
	if blur.ClassName == 'UIShadow' then
		blur.Enabled = enabled
	else
		blur.Visible = enabled
	end
end

local function blurEnabled(blur)
	if not blur then return false end
	if blur.ClassName == 'UIShadow' then
		return blur.Enabled
	end
	return blur.Visible
end

local function addCorner(parent, radius)
	local corner = Instance.new('UICorner')
	corner.CornerRadius = radius or UDim.new(0, 5)
	corner.Parent = parent

	return corner
end

local function addCloseButton(parent, mini, offset)
	local close = Instance.new('ImageButton')
	close.AutoButtonColor = false
	close.BackgroundColor3 = Color3.new(1, 1, 1)
	close.BackgroundTransparency = 1
	close.Image = getvapeasset('pistonware/assets/new/'..(mini and 'closemini' or 'close')..'.png')
	close.ImageColor3 = color.Light(uipallet.Text, 0.2)
	close.ImageTransparency = 0.5
	close.Name = 'Close'
	close.Position = offset or (mini and UDim2.new(1, -28, 0, 11) or UDim2.new(1, -35, 0, 9))
	close.Size = mini and UDim2.fromOffset(20, 20) or UDim2.fromOffset(24, 24)
	close.Parent = parent
	addCorner(close, UDim.new(1, 0))

	close.MouseEnter:Connect(function()
		close.ImageTransparency = 0.3
		tween:Tween(close, uipallet.Tween, {
			BackgroundTransparency = 0.6
		})
	end)

	close.MouseLeave:Connect(function()
		close.ImageTransparency = 0.5
		tween:Tween(close, uipallet.Tween, {
			BackgroundTransparency = 1
		})
	end)

	return close
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
				if newInput.UserInputType == (input.UserInputType == Enum.UserInputType.MouseButton1 and Enum.UserInputType.MouseMovement or Enum.UserInputType.Touch) then
					local position = newInput.Position
					if inputService:IsKeyDown(Enum.KeyCode.LeftShift) then
						dragPosition = (dragPosition // 3) * 3
						position = (position // 3) * 3
					end

					gui.Position = UDim2.fromOffset((position.X / scale.Scale) + dragPosition.X, (position.Y / scale.Scale) + dragPosition.Y)
				end
			end)

			releaseConnection = input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					moveConnection:Disconnect()
					releaseConnection:Disconnect()
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

local function addTooltip(gui, text, customText, visCheck)
	if not text then return end

	local function tooltipMoved(x, y)
		if visCheck and visCheck() then
			return
		end

		local isRight = x + 16 + tooltip.Size.X.Offset > (scale.Scale * 1920)
		tooltip.Position = UDim2.fromOffset(
			(isRight and x - (tooltip.Size.X.Offset * scale.Scale) - 16 or x + 16) / scale.Scale,
			((y + 11) - (tooltip.Size.Y.Offset / 2)) / scale.Scale
		)

		tooltip.Visible = blurEnabled(toolblur)
	end

	local function callback()
		local newText = customText()
		tooltip.Text = newText
		local tooltipSize = getfontbounds(contentText(tooltip), tooltip.TextSize, uipallet.Font)
		tooltip.Size = UDim2.fromOffset(tooltipSize.X + 10, tooltipSize.Y + 10)
	end

	gui.MouseEnter:Connect(function(x, y)
		if visCheck and visCheck() then
			return
		end

		tooltip.Text = text
		local tooltipSize = getfontbounds(contentText(tooltip), tooltip.TextSize, uipallet.Font)
		tooltip.Size = UDim2.fromOffset(tooltipSize.X + 10, tooltipSize.Y + 10)
		tooltipMoved(x, y)

		if customText then
			vape.CurrentTooltip = callback
			callback()
		end
	end)
	gui.MouseMoved:Connect(tooltipMoved)
	gui.MouseLeave:Connect(function()
		if visCheck and visCheck() then
			return
		end

		tooltip.Visible = false
		vape.CurrentTooltip = nil
	end)
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

	Skipped on touch devices, where the cost is highest and the benefit is only a cosmetic
	backdrop. The toggle also defaults off there, so the setting matches the behaviour
	rather than claiming a blur that is not happening.

	pcall'd on top: the method is executor- and client-version dependent, and a throw here used
	to abort whichever handler called it -- which includes the one that opens the menu.
]]
function vape:BlurCheck()
	if not self.ThreadFix then return end
	if inputService.TouchEnabled then return end

	setthreadidentity(8)
	pcall(function()
		runService:SetRobloxGuiFocused((clickgui.Visible or guiService:GetErrorType() ~= Enum.ConnectionError.OK) and self.Blur.Enabled)
	end)
end

function vape:CreateCategory(props)
	return components.Category(props)
end

function vape:CreateCategoryList(props)
	return components.CategoryList(props)
end

function vape:CreateNotification(title, text, duration, type)
	if not self.Notifications.Enabled then
		return
	end

	task.delay(0, function()
		if self.ThreadFix then
			setthreadidentity(8)
		end

		local index = #notifications:GetChildren() + 1
		local notification = Instance.new('ImageLabel')
		notification.BackgroundTransparency = 1
		notification.Position = UDim2.new(1, 0, 1, -(29 + (78 * index)))
		notification.Image = getvapeasset('pistonware/assets/new/notification.png')
		notification.ScaleType = Enum.ScaleType.Slice
		notification.SliceCenter = Rect.new(7, 7, 9, 9)
		notification.ZIndex = 5
		notification.Parent = notifications
		addBlur(notification, true, true)
		local iconshadow = Instance.new('ImageLabel')
		iconshadow.BackgroundTransparency = 1
		iconshadow.Image = getvapeasset('pistonware/assets/new/noti_'..(type or 'info')..'.png')
		iconshadow.ImageColor3 = Color3.new()
		iconshadow.ImageTransparency = 0.5
		iconshadow.Position = UDim2.fromOffset(-5, -8)
		iconshadow.Size = UDim2.fromOffset(60, 60)
		iconshadow.ZIndex = 5
		iconshadow.Parent = notification
		local icon = iconshadow:Clone()
		icon.ImageColor3 = Color3.new(1, 1, 1)
		icon.ImageTransparency = 0
		icon.Position = UDim2.fromOffset(-1, -1)
		icon.Parent = iconshadow
		local label = Instance.new('TextLabel')
		label.BackgroundTransparency = 1
		label.FontFace = uipallet.FontSemiBold
		label.Position = UDim2.fromOffset(46, 16)
		label.RichText = true
		label.Size = UDim2.new(1, -56, 0, 20)
		label.Text = "<stroke joins='round' thickness='0.3' transparency='0.5'>"..title..'</stroke>'
		label.TextColor3 = type == 'alert' and Color3.fromRGB(250, 50, 56) or Color3.new(1, 1, 1)
		label.TextSize = 14
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextYAlignment = Enum.TextYAlignment.Top
		label.ZIndex = 5
		label.Parent = notification
		local textshadow = label:Clone()
		textshadow.FontFace = uipallet.Font
		textshadow.Position = UDim2.fromOffset(47, 44)
		textshadow.RichText = false
		textshadow.Text = removeTags(text)
		textshadow.TextColor3 = Color3.new()
		textshadow.TextTransparency = 0.5
		textshadow.Parent = notification
		notification.Size = UDim2.fromOffset(math.max(getfontbounds(textshadow.Text, 14, uipallet.Font).X + 80, 266), 75)
		local textlabel = textshadow:Clone()
		textlabel.Position = UDim2.fromOffset(-1, -1)
		textlabel.RichText = true
		textlabel.Text = text
		textlabel.TextColor3 = Color3.fromRGB(170, 170, 170)
		textlabel.TextTransparency = 0
		textlabel.Parent = textshadow
		local progress = Instance.new('Frame')
		progress.BackgroundColor3 =
			type == 'alert' and Color3.fromRGB(250, 50, 56)
			or type == 'warning' and Color3.fromRGB(236, 129, 44)
			or Color3.new(1, 1, 1)
		progress.BorderSizePixel = 0
		progress.Position = UDim2.new(0, 3, 1, -4)
		progress.Size = UDim2.new(1, -13, 0, 1)
		progress.ZIndex = 5
		progress.Parent = notification

		if tween.Tween then
			tween:Tween(notification, TweenInfo.new(0.4, Enum.EasingStyle.Exponential), {
				AnchorPoint = Vector2.new(1, 0)
			}, 'tweenstwo')

			tween:Tween(progress, TweenInfo.new(duration, Enum.EasingStyle.Linear), {
				Size = UDim2.fromOffset(0, 1)
			})
		end

		task.delay(duration, function()
			if tween.Tween then
				tween:Tween(notification, TweenInfo.new(0.4, Enum.EasingStyle.Exponential), {
					AnchorPoint = Vector2.new(0, 0)
				}, 'tweenstwo')
			end

			task.wait(0.2)
			notification:ClearAllChildren()
			notification:Destroy()
		end)
	end)
end

function vape:CreateOverlay(props)
	return components.Overlay(props)
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
	trace('Load start profile='..tostring(profile or self.Profile)
		..' modules='..tostring(#self.ModuleOrder)..' heap='..heapKB()..'KB')
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

		if mainData.v ~= 1 then
			for _, data in mainData.Modules do
				data.Bind = {Keys = data.Bind}
				data.Visible = true
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

		trace('Load applying modules, heap='..heapKB()..'KB')
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
		--[[
			No file for this profile yet, so write one from the current state.

			Save() opens with `if not self.Loaded then return end`, and Loaded is not assigned
			until further down this function -- so this branch has always been a silent no-op.
			A profile selected for the first time got no file at all, and stayed unwritten until
			something else happened to save later.

			Loaded is set to exactly the same value a few lines below; this just brings it forward
			to the point where the branch actually needs it.
		]]
		self.Loaded = canSave
		self:Save()
	end

	if self.Profile ~= oldProfile and skipgui then
		self:CreateNotification('Profile swap to <font color="#FFAA00">'..self.Profile..'</font>', toggleCount..' modules enabled', 3)
	end

	if self.Downloader then
		self.Downloader:Destroy()
		self.Downloader = nil
	end

	self.Loaded = canSave
	self.Applying = nil
	trace('Load done, '..toggleCount..' enabled, '..#startQueue..' queued to start, heap='..heapKB()..'KB')
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

	if inputService.TouchEnabled and not skipgui then
		local button = Instance.new('TextButton')
		button.BackgroundColor3 = Color3.new()
		button.BackgroundTransparency = 0.2
		button.Position = UDim2.new(1, -90, 0, 4)
		button.Size = UDim2.fromOffset(32, 32)
		button.Text = ''
		button.Parent = gui
		local image = Instance.new('ImageLabel')
		image.BackgroundTransparency = 1
		image.Image = getvapeasset('pistonware/assets/new/vape.png')
		image.Position = UDim2.fromOffset(6, 6)
		image.Size = UDim2.fromOffset(20, 20)
		image.Parent = button
		addCorner(button, UDim.new(1, 0))

		self.VapeButton = button
		self.VapeButtonImage = image
		self.VapeButtonTransparency = button.BackgroundTransparency
		--[[ Options are already loaded by this point, so honour the saved setting on the
		button we just built; the toggle's own Function ran before the button existed.
		Transparency rather than Visible: see HideVapeButton. ]]
		if self.HideVapeButton and self.HideVapeButton.Enabled then
			button.BackgroundTransparency = 1
			image.ImageTransparency = 1
		end

		button.MouseButton1Click:Connect(function()
			self.GUIBind.Triggered:Fire(true)
		end)
	end

	--[[ `toggleData` was undeclared; return the module toggle count used by the notification. ]]
	return toggleCount
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
	if not self.Profile then return 0 end

	local path = 'pistonware/profiles/'..self.Profile..self.Place..'.txt'
	if not isfile(path) then return 0 end

	local mainData = loadJson(path)
	if type(mainData) ~= 'table' or type(mainData.Modules) ~= 'table' then return 0 end

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
	for name, componentData in data do
		local component = obj.Options[name]

		if component then
			component:Load(componentData)
		end
	end
end

function vape:LoadGUI()
	addMaid(vape)
	gui = Instance.new('ScreenGui')
	gui.Name = randomString()
	gui.DisplayOrder = 9999999
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Global
	gui.IgnoreGuiInset = true
	
	if vape.ThreadFix then
		local holder = Instance.new('Folder')
		holder.Parent = cloneref(game:GetService('CoreGui'))
		--[[ Recent property; older clients throw on the assignment rather than ignoring it. ]]
		pcall(function() gui.OnTopOfCoreBlur = true end)
		--[[
			CoreGui on touch devices, gethui elsewhere.

			The old GUI had gethui commented out entirely, with CoreGui forced in its place --
			deliberately, and it is the mobile executors that are the reason. Their gethui hands
			back a hidden container the client itself owns and reclaims: it gets emptied out from
			under the script, and a ScreenGui whose parent is destroyed underneath it is a
			straightforward way to take the client with it.

			Kept on desktop, where it works and is the more discreet parent of the two, and where
			nothing has been reported against it.
		]]
		local hidden = (not inputService.TouchEnabled) and gethui and select(2, pcall(gethui)) or nil
		gui.Parent = (typeof(hidden) == 'Instance' and hidden) or cloneref(game:GetService('CoreGui'))
		vape.holder = holder
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
	clickgui.Parent = scaledgui
	local scarcitybanner = Instance.new('TextLabel')
	scarcitybanner.BackgroundTransparency = 1
	scarcitybanner.FontFace = uipallet.Font
	scarcitybanner.Position = UDim2.fromScale(0, 0.97)
	scarcitybanner.Size = UDim2.fromScale(1, 0.02)
	scarcitybanner.Text = 'The discord link has been fixed, click the discord icon to join.'
	scarcitybanner.TextColor3 = Color3.new(1, 1, 1)
	scarcitybanner.TextScaled = true
	scarcitybanner.TextStrokeTransparency = 0.5
	scarcitybanner.Parent = clickgui
	local modal = Instance.new('TextButton')
	modal.BackgroundTransparency = 1
	modal.Modal = true
	modal.Text = ''
	modal.Parent = clickgui
	local cursor = Instance.new('ImageLabel')
	cursor.BackgroundTransparency = 1
	cursor.Image = 'rbxasset://textures/Cursors/KeyboardMouse/ArrowFarCursor.png'
	cursor.Size = UDim2.fromOffset(64, 64)
	cursor.Visible = false
	cursor.Parent = gui
	notifications = Instance.new('Folder')
	notifications.Name = 'Notifications'
	notifications.Parent = scaledgui
	tooltip = Instance.new('TextLabel')
	tooltip.BackgroundColor3 = color.Dark(uipallet.Main, 0.02)
	tooltip.FontFace = uipallet.Font
	tooltip.Position = UDim2.fromScale(-1, -1)
	tooltip.RichText = true
	tooltip.Text = ''
	tooltip.TextColor3 = color.Dark(uipallet.Text, 0.16)
	tooltip.TextSize = 12
	tooltip.Visible = false
	tooltip.ZIndex = 5
	tooltip.Parent = scaledgui
	toolblur = addBlur(tooltip)
	addCorner(tooltip)
	scale = Instance.new('UIScale')
	scale.Scale = autoScaleValue()
	scale.Parent = scaledgui
	scaledgui.Size = UDim2.fromScale(1 / scale.Scale, 1 / scale.Scale)
	components.GUI({})
	
	vape:CreateCategory({
		Name = 'Combat',
		Icon = getvapeasset('pistonware/assets/new/combat.png'),
		Size = UDim2.fromOffset(13, 14)
	})
	vape:CreateCategory({
		Name = 'Blatant',
		Icon = getvapeasset('pistonware/assets/new/blatant.png'),
		Size = UDim2.fromOffset(14, 14)
	})
	vape:CreateCategory({
		Name = 'Render',
		Icon = getvapeasset('pistonware/assets/new/render.png'),
		Size = UDim2.fromOffset(15, 14)
	})
	vape:CreateCategory({
		Name = 'Utility',
		Icon = getvapeasset('pistonware/assets/new/utility.png'),
		Size = UDim2.fromOffset(15, 14)
	})
	vape:CreateCategory({
		Name = 'World',
		Icon = getvapeasset('pistonware/assets/new/world.png'),
		Size = UDim2.fromOffset(14, 14)
	})
	vape:CreateCategory({
		Name = 'Inventory',
		Icon = getvapeasset('pistonware/assets/new/inventory.png'),
		Size = UDim2.fromOffset(15, 14)
	})
	--[[ Minigames is not in the upstream rewrite, but it is not optional here: bedwars.lua alone
	puts five modules in it (AutoHonor, Breaker, AutoFish, AutoHannah, AutoKaliyah) and four
	other place files add more. Without the category those CreateModule calls index nil and
	take their whole game script down.

	Uses the utility icon because the rewrite ships no minigames.png; a missing asset would
	return an unusable value from getvapeasset and throw 'ContentId formatting failed' when
	assigned to .Image. ]]
	vape:CreateCategory({
		Name = 'Minigames',
		Icon = getvapeasset('pistonware/assets/new/utility.png'),
		Size = UDim2.fromOffset(15, 14)
	})

	--[[ games/6872274481.lua sizes two scrolling frames against the GUI's UIScale and reads it as
	vape.guiscale, which the old GUI exported under that name. Same object, same field. ]]
	vape.guiscale = scale
	vape.Categories.Main:CreateDivider({
		Text = 'misc'
	})
	
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
			Icon = getvapeasset('pistonware/assets/new/friends.png'),
			Size = UDim2.fromOffset(17, 16),
			Placeholder = 'Roblox username',
			Color = Color3.fromRGB(5, 134, 105),
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
					if dot and dot.BackgroundColor3 ~= color.Light(uipallet.Main, 0.37) then
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
		Icon = getvapeasset('pistonware/assets/new/profiles.png'),
		Size = UDim2.fromOffset(17, 10),
		Position = UDim2.fromOffset(12, 16),
		Placeholder = 'Type name',
		Profiles = true
	})

	--[[
		Profile sync -- 'Sync to current profiles', plus the Blatant/Legit default picker.

		Redownloads pistonware/profiles the way loader.lua does on a first install: every file
		the repo keeps in that folder, pulled from the raw host through the same 4-attempt retry
		(raw hosts 504 intermittently, and an empty body would otherwise land as a corrupt file).

		Two things differ from loader.lua's downloadFile, both required for a sync rather than an
		install: it writes over files that already exist (downloadFile skips those, which for a
		sync would download nothing at all), and nothing is filtered out. <GameId>.gui.txt carries
		the config's GUI theme colour and window layout, so holding it back was what made a synced
		config come back looking exactly like the one it replaced.
	]]

	-- Same reinject route the buttons in Settings > General use: the developer build lives on
	-- disk under its own name and must never be fetched from GitHub, and every other path goes
	-- back through the loader so the key gate re-runs.
	local function reinjectThroughLoader()
		if shared.PistonwareDeveloper and isfile('pistonware/loaderdev.lua') then
			loadstring(readfile('pistonware/loaderdev.lua'), 'loader')()
		else
			loadstring(game:HttpGet('https://raw.githubusercontent.com/themagicpiston/pistonware/main/loader.lua', true), 'loader')()
		end
	end

	-- pistonware/profiles is stamped with the commit it was pulled from, so a sync that would
	-- change nothing can be turned away before it spends any requests finding that out.
	--
	-- loader.lua stamps the SAME file with its own 'p1-' fingerprint (a hash of the profile blob
	-- shas, so its update check costs no extra API call). The two schemes can never compare
	-- equal, which only means the short-circuit below misses after a loader-driven sync and this
	-- button downloads once more than it strictly had to. That is the safe direction to fail:
	-- syncing when nothing changed costs a few requests, skipping a sync that was needed does
	-- not do what the button says. loader.lua already migrates a 40-char sha it finds here, so
	-- writing one back does not make it prompt.
	local function localProfileCommit()
		local suc, res = pcall(readfile, 'pistonware/profiles/profilecommit.txt')
		if not (suc and type(res) == 'string') then return nil end
		res = res:gsub('%s', '')
		return res ~= '' and res or nil
	end

	local function latestProfileCommit()
		local suc, res = pcall(function()
			return game:HttpGet('https://api.github.com/repos/themagicpiston/pistonware/commits?path=profiles&sha=main&per_page=1', true)
		end)
		if not (suc and res and res ~= '' and res ~= '404: Not Found') then return nil end
		local ok, body = pcall(function()
			return httpService:JSONDecode(res)
		end)
		if not (ok and typeof(body) == 'table' and body[1] and type(body[1].sha) == 'string') then return nil end
		return body[1].sha
	end

	-- Being on the latest commit is not enough on its own: the sync exists to put both shipped
	-- configs for this place on disk, so a missing one has to let it through regardless.
	local function hasBothConfigs()
		return isfile('pistonware/profiles/blatant'..vape.Place..'.txt') and isfile('pistonware/profiles/legit'..vape.Place..'.txt')
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

	-- Pinned to the commit the check reported rather than to the branch path: raw.githubusercontent
	-- serves CDN-cached content for a few minutes after a push, so a branch-head fetch can quietly
	-- reinstall the old profiles and then get stamped with the new commit, blocking every later sync.
	local function downloadProfileFile(path, commit)
		local relPath = select(1, path:gsub('pistonware/', ''))
		local content
		for attempt = 1, 4 do
			local suc, res = pcall(function()
				return game:HttpGet('https://raw.githubusercontent.com/themagicpiston/pistonware/'..(commit or 'main')..'/'..relPath, true)
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

	local function downloadProfiles(commit)
		local reqSuc, res = pcall(function()
			-- listing pinned too, so it can never describe a different commit than the files below
			return game:HttpGet('https://api.github.com/repos/themagicpiston/pistonware/contents/profiles'..(commit and ('?ref='..commit) or ''), true)
		end)
		if not (reqSuc and res and res ~= '' and res ~= '404: Not Found') then
			return nil, 'Profile sync failed (could not reach GitHub).'
		end

		local bodySuc, body = pcall(function()
			return httpService:JSONDecode(res)
		end)
		if not (bodySuc and typeof(body) == 'table') then
			return nil, 'Profile sync failed (unreadable response).'
		end

		local files = {}
		for _, v in body do
			if type(v) == 'table' and v.type == 'file' and type(v.path) == 'string' then
				table.insert(files, v)
			end
		end
		if #files <= 0 then
			return nil, 'Profile sync failed (the repo has no profiles).'
		end

		-- Downloaded in parallel like the loader does, rather than one blocking request per file.
		local synced, failed = 0, 0
		local total = #files
		for _, v in files do
			task.spawn(function()
				-- pcall'd so a worker that throws is still counted. It used to decrement the
				-- counter only on the success path and join on a BindableEvent with no timeout, so
				-- one file that errored left the sync button spinning for the rest of the session.
				local ok, got = pcall(downloadProfileFile, 'pistonware/'..({v.path:gsub(' ', '%%20')})[1], commit)
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

		if synced <= 0 then
			return nil, 'Profile sync failed (nothing downloaded).'
		end
		return synced, 'Synced '..synced..' file'..(synced == 1 and '' or 's')..' from GitHub'..(failed > 0 and ' ('..failed..' failed).' or '.')
	end

	do
		local syncing = false
		-- Set once a download lands. From then until a config is picked the buttons below own the
		-- reinject, so syncing and choosing stay one flow rather than two reloads.
		local pending, syncmessage = false, nil
		local refreshConfigButtons
		-- Tracked because the recolour below runs on every rainbow tick and would otherwise
		-- overwrite whatever MouseEnter/MouseLeave just set.
		local synchovered = false
		local children = profilescategory.Object:FindFirstChild('Children')
		local syncbutton = Instance.new('TextButton')
		syncbutton.AutoButtonColor = false
		syncbutton.Name = 'SyncProfiles'
		-- ChangeValue rebuilds the profile entries from scratch on every add/remove, so this sits
		-- outside that list with a LayoutOrder that keeps it pinned underneath them.
		syncbutton.LayoutOrder = 999
		syncbutton.Size = UDim2.fromOffset(200, 33)
		syncbutton.BackgroundColor3 = color.Light(uipallet.Main, 0.02)
		syncbutton.Text = 'Sync to current profiles'
		-- Static black, and never touched again: the background under it is the GUI colour now,
		-- so anything that varied with the colour or with hover read as the label flickering.
		syncbutton.TextColor3 = Color3.new(0, 0, 0)
		syncbutton.TextSize = 15
		syncbutton.FontFace = uipallet.Font
		syncbutton.Parent = children
		addCorner(syncbutton)
		addTooltip(syncbutton, 'Redownloads the profiles from GitHub, then pick a config below to load one')

		-- Flag only. The tween these used to run fought recolorProfileCards, which rewrites this
		-- background every rainbow tick: leaving the button started a tween back to the flat
		-- grey while the tick kept writing the colour, and the two took turns each frame.
		-- The hover shade is applied by the tick instead, off this flag.
		syncbutton.MouseEnter:Connect(function()
			synchovered = true
		end)
		syncbutton.MouseLeave:Connect(function()
			synchovered = false
		end)
		syncbutton.MouseButton1Click:Connect(function()
			if syncing then return end
			syncing = true
			syncbutton.Text = 'Checking...'

			-- One request to compare commits, rather than a dozen to redownload files that have not
			-- moved. GitHub allows 60 unauthenticated API calls an hour and a few reinjects can spend
			-- that, so a folder that is already current is turned away before the listing request.
			local latest = latestProfileCommit()
			if latest and latest == localProfileCommit() and hasBothConfigs() then
				syncing = false
				syncbutton.Text = 'Profiles already up to date'
				vape:CreateNotification('Pistonware', 'Profiles are already on the latest commit, nothing to sync.', 10)
				return
			end

			syncbutton.Text = 'Syncing...'
			-- Flush what is in memory first so a download that only half lands cannot strand the
			-- GUI between two states -- whatever does arrive replaces this a moment later.
			pcall(function() vape:Save() end)

			local synced, message = downloadProfiles(latest)
			syncing = false
			if not synced then
				syncbutton.Text = 'Sync to current profiles'
				vape:CreateNotification('Pistonware', message, 10, 'alert')
				return
			end
			-- Stamped only once the files are down, and only when the commit was readable in the first
			-- place, so a half-finished or unverified sync still re-checks next time.
			if latest then
				pcall(writefile, 'pistonware/profiles/profilecommit.txt', latest)
			end

			-- Saving stops here rather than at the reload. A module toggled from now on would go
			-- through RequestSave and write the pre-sync state back over the files that were just
			-- downloaded -- which is exactly how a synced config came back wearing the old GUI
			-- colour. Cleared for good; the reload builds a fresh vape.
			vape.Save = function() end
			vape.SaveNeeded = nil

			-- Downloaded, but nothing is loaded yet: the files are settings on disk until something
			-- reads them. Picking a config below is what reloads onto them.
			pending, syncmessage = true, message
			syncbutton.Text = 'Synced, choose a config'
			refreshConfigButtons()
			vape:CreateNotification('Pistonware', message..' Choose Blatant or Legit below to load one.', 10)
		end)

		-- Which shipped config loads by default. There is nothing extra to persist: the default is
		-- simply the active profile, which Save already records in gui.txt, so it is what a plain
		-- reinject (and the sync above) comes back to.
		local defaultrow = Instance.new('Frame')
		defaultrow.Name = 'DefaultConfig'
		defaultrow.LayoutOrder = 1000
		defaultrow.Size = UDim2.fromOffset(200, 33)
		defaultrow.BackgroundTransparency = 1
		defaultrow.Parent = children

		local configbuttons = {}
		-- Which of the two the pointer is over. Same purpose as `synchovered` above: this
		-- function runs on every rainbow tick, and an unselected card that is mid-hover owns
		-- its own colours until the pointer leaves. Writing the flat shade over it here is the
		-- fight the sync button's flag already avoids -- the hover tween and the tick took
		-- turns each frame. (The old GUI only guarded the sync button and left these two to
		-- flicker.) Nothing about the appearance changes; the hover tween simply stops being
		-- overwritten while it is the one in charge.
		local confighovered = {}
		-- Colour only, and deliberately split from refreshConfigButtons: that one stats the
		-- profile files to decide what is offered, and this runs on every rainbow tick --
		-- at the default 60hz the combined version would be 120 isfile calls a second.
		--
		-- Registered on vape so UpdateGUI can reach it: UpdateGUI is defined at file scope,
		-- well outside this block, and is the only thing that runs per rainbow tick.
		local function recolorProfileCards()
			for name, button in configbuttons do
				local selected = vape.Profile == name and not pending
				if selected then
					button.BackgroundColor3 = Color3.fromHSV(vape.GUIColor.Hue, vape.GUIColor.Sat, vape.GUIColor.Value)
					-- Fixed black rather than vape:TextColor: that picks dark or white from the
					-- colour's brightness, and a rainbow sweeps across its threshold several
					-- times a cycle, so the label flipped between the two every few frames.
					button.TextColor3 = Color3.new(0, 0, 0)
				elseif not confighovered[name] then
					button.BackgroundColor3 = color.Light(uipallet.Main, 0.02)
					-- while a sync is waiting on a choice both read as live options, not one active one
					button.TextColor3 = pending and uipallet.Text or color.Dark(uipallet.Text, 0.4)
				end
			end
			-- The button takes the GUI colour, its label stays black. Hover is a shade of the same
			-- colour applied here rather than a tween, so there is only ever one writer.
			local synccolor = Color3.fromHSV(vape.GUIColor.Hue, vape.GUIColor.Sat, vape.GUIColor.Value)
			syncbutton.BackgroundColor3 = synchovered and color.Light(synccolor, 0.12) or synccolor
		end
		vape.RecolorProfileCards = recolorProfileCards

		function refreshConfigButtons()
			local anyvisible = false
			for name, button in configbuttons do
				-- A config can only be offered once its file is on disk: before the first sync there
				-- may be none at all, so the row hides itself rather than showing a button whose only
				-- possible answer is an error.
				button.Visible = pending or isfile('pistonware/profiles/'..name..vape.Place..'.txt')
				anyvisible = anyvisible or button.Visible
			end
			-- an invisible row is skipped by the list layout, so the gap closes with it
			defaultrow.Visible = anyvisible
			recolorProfileCards()
		end

		local function selectConfig(name)
			if not isfile('pistonware/profiles/'..name..vape.Place..'.txt') then
				vape:CreateNotification('Pistonware', 'There is no '..name..' config for this game yet, press Sync to current profiles first.', 10, 'alert')
				return
			end
			-- Always a full reload, never an in-place profile switch. The GUI theme colour, window
			-- layout and keybind live in <GameId>.gui.txt, and Load(true) -- what the profile entries
			-- use -- deliberately skips that file, so switching in place brings the config's modules
			-- across but leaves the GUI dressed as whatever it replaced.
			pending = false
			syncbutton.Text = 'Reloading...'
			-- On a plain switch this flushes anything newer than the last write into the profile
			-- being left behind. After a sync it is deliberately a no-op: Save was already neutered
			-- when the download landed, which is what keeps those files intact until they are read.
			pcall(function() vape:Save() end)
			vape.Save = function() end
			vape.SaveNeeded = nil
			-- Save is off now and the reload reads the profile list back out of gui.txt, so the chosen
			-- config has to be written in there directly. Going through Save instead would rewrite the
			-- profile file a download just refreshed.
			pcall(function()
				local guipath = 'pistonware/profiles/'..game.GameId..'.gui.txt'
				local guidata = isfile(guipath) and loadJson(guipath)
				if type(guidata) ~= 'table' then return end
				-- Categories.Profiles.List is where this GUI keeps the profile list; see the note
				-- on mergeGuiState above.
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
			reinjectThroughLoader()
		end

		for index, config in {{Key = 'blatant', Text = 'Blatant'}, {Key = 'legit', Text = 'Legit'}} do
			local name = config.Key
			local button = Instance.new('TextButton')
			button.Name = name
			-- Half of the sync button each, with a 4px gutter, so the pair lines up with it exactly.
			button.Size = UDim2.fromOffset(98, 33)
			button.Position = UDim2.fromOffset((index - 1) * 102, 0)
			button.BackgroundColor3 = color.Light(uipallet.Main, 0.02)
			button.AutoButtonColor = false
			button.Text = config.Text
			button.TextColor3 = color.Dark(uipallet.Text, 0.4)
			button.TextSize = 15
			button.FontFace = uipallet.Font
			button.Parent = defaultrow
			addCorner(button)
			addTooltip(button, 'Load the '..config.Text..' config by default')
			configbuttons[name] = button

			button.MouseEnter:Connect(function()
				-- Recorded before the early return, so the flag still tracks the pointer while
				-- this card happens to be the selected one.
				confighovered[name] = true
				if vape.Profile == name and not pending then return end
				button.TextColor3 = uipallet.Text
				tween:Tween(button, uipallet.Tween, {
					BackgroundColor3 = color.Light(uipallet.Main, 0.14)
				})
			end)
			button.MouseLeave:Connect(function()
				confighovered[name] = nil
				if vape.Profile == name and not pending then return end
				button.TextColor3 = color.Dark(uipallet.Text, 0.4)
				tween:Tween(button, uipallet.Tween, {
					BackgroundColor3 = color.Light(uipallet.Main, 0.02)
				})
			end)
			button.MouseButton1Click:Connect(function()
				selectConfig(name)
			end)
		end

		-- Load is the one place that settles which profile is active -- first inject, reinject, or a
		-- click on a profile entry -- so the highlight follows it instead of being poked from each
		-- of those callers.
		local loadprofile = vape.Load
		function vape:Load(...)
			local result = loadprofile(self, ...)
			refreshConfigButtons()
			return result
		end
		-- picks up a GUI colour change made while the tab was closed
		defaultrow.MouseEnter:Connect(refreshConfigButtons)
		refreshConfigButtons()
	end
	
	--[[
		Targets
	]]
	local targets
	targets = vape:CreateCategoryList({
		Name = 'Targets',
		Icon = getvapeasset('pistonware/assets/new/friends.png'),
		Size = UDim2.fromOffset(17, 16),
		Placeholder = 'Roblox username',
		Function = function()
			targets.Update:Fire()
		end
	})
	targets.Update = Instance.new('BindableEvent')
	vape:Clean(targets.Update)
	
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
												vape:CreateNotification(module.Name, component.Name..' '..(not component.Enabled and "<font color='#00AA00'>ON</font>" or "<font color='#FF5A5A'>OFF</font>"), 1.5)
											end
	
											component:Toggle()
										end
									else
										if vape.SettingToggleNotifications.Enabled then
											vape:CreateNotification(module.Name, component.Name..' '..(not component.Enabled and "<font color='#00AA00'>ON</font>" or "<font color='#FF5A5A'>OFF</font>"), 1.5)
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
		vape.Save = function() end
			if isfile('pistonware/profiles/'..vape.Profile..vape.Place..'.txt') and delfile then
				delfile('pistonware/profiles/'..vape.Profile..vape.Place..'.txt')
			end
	
			shared.vapereload = true
			--[[ Back through the pistonware loader, which re-runs the key gate. That is deliberate:
			shared.PistonwareAuthenticated is cleared and re-derived on every run, so a reinject
			revalidates rather than inheriting a flag. The developer build lives on disk under a
			different name and must never be fetched from GitHub -- it has the gate disabled. ]]
			if shared.PistonwareDeveloper and isfile('pistonware/loaderdev.lua') then
				runChunk(readfile('pistonware/loaderdev.lua'), 'loader')
			else
				runChunk(game:HttpGet('https://raw.githubusercontent.com/themagicpiston/pistonware/main/loader.lua', true), 'loader')
			end
		end,
		Tooltip = 'This will set your profile to the default settings of Vape'
	})
	
	general:CreateButton({
		Name = 'Self destruct',
		Function = function()
			vape:Uninject()
		end,
		Tooltip = 'Removes vape from the current game'
	})
	
	general:CreateButton({
		Name = 'Reinject',
		Function = function()
			shared.vapereload = true
			--[[ Back through the pistonware loader, which re-runs the key gate. That is deliberate:
			shared.PistonwareAuthenticated is cleared and re-derived on every run, so a reinject
			revalidates rather than inheriting a flag. The developer build lives on disk under a
			different name and must never be fetched from GitHub -- it has the gate disabled. ]]
			if shared.PistonwareDeveloper and isfile('pistonware/loaderdev.lua') then
				runChunk(readfile('pistonware/loaderdev.lua'), 'loader')
			else
				runChunk(game:HttpGet('https://raw.githubusercontent.com/themagicpiston/pistonware/main/loader.lua', true), 'loader')
			end
		end,
		Tooltip = 'Reloads vape for debugging purposes'
	})
	
	general:CreateButton({
		Name = 'Reinstall',
		Function = function()
			runChunk(game:HttpGet('https://raw.githubusercontent.com/themagicpiston/pistonware/refs/heads/main/reinstall.lua', true), 'reinstall')
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
		__index = function(_, key)
			for _, pane in vape.Settings do
				local ok, options = pcall(function() return pane.Options end)
				if ok and type(options) == 'table' and options[key] ~= nil then
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
		--[[ Off by default on a phone. See BlurCheck: this drives a full-screen GPU pass, and it
		is the only thing the menu does on open that a client can die on rather than error on. ]]
		Default = not inputService.TouchEnabled,
		Tooltip = 'Blur the background of the GUI'
	})
	
	guipane:CreateToggle({
		Name = 'GUI bind indicator',
		Default = true,
		Tooltip = "Displays a message indicating your GUI upon injecting.\nI.E. 'Press RSHIFT to open GUI'"
	})
	
	guipane:CreateToggle({
		Name = 'Show tooltips',
		Function = function(enabled)
			tooltip.Visible = false
			setBlurEnabled(toolblur, enabled)
		end,
		Default = true,
		Tooltip = 'Toggles visibility of these'
	})
	
	guipane:CreateToggle({
		Name = 'Show legit mode',
		Function = function(enabled)
			clickgui.Search.Legit.Visible = enabled
			clickgui.Search.LegitDivider.Visible = enabled
			clickgui.Search.TextBox.Size = UDim2.new(1, enabled and -50 or -10, 0, 37)
			clickgui.Search.TextBox.Position = UDim2.fromOffset(enabled and 50 or 10, 0)
		end,
		Default = true,
		Tooltip = 'Shows the button to switch to the legit mod menu'
	})
	
	local ScaleSlider = {Object = {}, Value = 1}
	vape.Scale = guipane:CreateToggle({
		Name = 'Auto rescale',
		Default = true,
		Function = function(callback)
			ScaleSlider.Object.Visible = not callback
			if callback then
				--[[ Was commented out in the rewrite, so turning Auto rescale back on did
				nothing at all until the next resize -- and on a phone there is no next
				resize. The menu just stayed at whatever the manual slider left it on. ]]
				scale.Scale = autoScaleValue()
			else
				scale.Scale = ScaleSlider.Value
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
				if vape.VapeButtonImage then
					vape.VapeButtonImage.ImageTransparency = callback and 1 or 0
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
		Name = 'Reset GUI positions',
		Function = function()
			for _, category in vape.Categories do
				category.Object.Position = UDim2.fromOffset(6, 42)
			end
		end,
		Tooltip = 'This will reset your GUI back to the default'
	})
	
	guipane:CreateButton({
		Name = 'Sort GUI',
		Function = function()
			local priority = {
				GUICategory = 1,
				CombatCategory = 2,
				BlatantCategory = 3,
				RenderCategory = 4,
				UtilityCategory = 5,
				WorldCategory = 6,
				InventoryCategory = 7,
				FriendsCategory = 8,
				ProfilesCategory = 9
			}
	
			local categories = {}
			for _, category in vape.Categories do
				if category.Type ~= 'Overlay' then
					table.insert(categories, category)
				end
			end
	
			table.sort(categories, function(a, b)
				return (priority[a.Object.Name] or 99) < (priority[b.Object.Name] or 99)
			end)
	
			local index = 0
			for _, category in categories do
				if category.Object.Visible then
					category.Object.Position = UDim2.fromOffset(6 + (index % 8 * 230), 60 + (index > 7 and 360 or 0))
					index += 1
				end
			end
		end,
		Tooltip = 'Sorts GUI by category order'
	})
	
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
	
	run(function()
		local Sort
		local FontOption
		local ColorSlider
		local ColorMode
		local Scale
		local Shadow
		local Gradient
		local GradientV4
		local Animations
		local Watermark
		local Background
		local BackgroundTransparency
		local BackgroundTint
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
		
		TextGUI = vape:CreateOverlay({
			Name = 'Text GUI',
			Icon = getvapeasset('pistonware/assets/new/textgui.png'),
			Size = UDim2.fromOffset(16, 12),
			Position = UDim2.fromOffset(12, 14),
			Function = function()
				vape:UpdateTextGUI()
			end
		})
		Sort = TextGUI:CreateDropdown({
			Name = 'Sort',
			List = {'Alphabetical', 'Length'},
			Function = function()
				vape:UpdateTextGUI()
			end
		})
		FontOption = TextGUI:CreateFont({
			Name = 'Font',
			Default = 'Arial',
			Function = function()
				vape:UpdateTextGUI()
			end
		})
		ColorMode = TextGUI:CreateDropdown({
			Name = 'Color Mode',
			List = {'Match GUI color', 'Custom color'},
			Function = function(value)
				ColorSlider.Object.Visible = value == 'Custom color'
				vape:UpdateTextGUI()
			end
		})
		ColorSlider = TextGUI:CreateColorSlider({
			Name = 'Text GUI color',
			Function = function()
				vape:UpdateGUI(vape.GUIColor.Hue, vape.GUIColor.Sat, vape.GUIColor.Value)
			end,
			Darker = true,
			Visible = false
		})
		TextGUI:CreateSlider({
			Name = 'Scale',
			Min = 0,
			Max = 2,
			Decimal = 10,
			Default = 1,
			Function = function(val)
				Scale.Scale = val
				vape:UpdateTextGUI()
			end
		})
		Shadow = TextGUI:CreateToggle({
			Name = 'Shadow',
			Tooltip = 'Renders shadowed text.',
			Function = function()
				vape:UpdateTextGUI()
			end
		})
		Gradient = TextGUI:CreateToggle({
			Name = 'Gradient',
			Tooltip = 'Renders a gradient',
			Function = function(callback)
				GradientV4.Object.Visible = callback
				vape:UpdateTextGUI()
			end
		})
		GradientV4 = TextGUI:CreateToggle({
			Name = 'V4 Gradient',
			Function = function()
				vape:UpdateTextGUI()
			end,
			Darker = true,
			Visible = false
		})
		Animations = TextGUI:CreateToggle({
			Name = 'Animations',
			Tooltip = 'Use animations on text gui',
			Function = function()
				vape:UpdateTextGUI()
			end
		})
		Watermark = TextGUI:CreateToggle({
			Name = 'Watermark',
			Tooltip = 'Renders a vape watermark',
			Function = function()
				vape:UpdateTextGUI()
			end
		})
		Background = TextGUI:CreateToggle({
			Name = 'Render background',
			Function = function(callback)
				BackgroundTransparency.Object.Visible = callback
				BackgroundTint.Object.Visible = callback
				vape:UpdateTextGUI()
			end
		})
		BackgroundTransparency = TextGUI:CreateSlider({
			Name = 'Transparency',
			Min = 0,
			Max = 1,
			Default = 0.5,
			Decimal = 10,
			Function = function()
				vape:UpdateTextGUI()
			end,
			Darker = true,
			Visible = false
		})
		BackgroundTint = TextGUI:CreateToggle({
			Name = 'Tint',
			Function = function()
				vape:UpdateTextGUI()
			end,
			Darker = true,
			Visible = false
		})
		HideModules = TextGUI:CreateToggle({
			Name = 'Hide modules',
			Tooltip = 'Allows you to blacklist certain modules from being shown.',
			Function = function(enabled)
				HideModulesList.Object.Visible = enabled
				vape:UpdateTextGUI()
			end
		})
		HideModulesList = TextGUI:CreateTextList({
			Name = 'Blacklist',
			Tooltip = 'Name of module to hide.',
			Color = Color3.fromRGB(250, 50, 56),
			Function = function()
				vape:UpdateTextGUI()
			end,
			Visible = false,
			Darker = true
		})
		HideRender = TextGUI:CreateToggle({
			Name = 'Hide render',
			Function = function()
				vape:UpdateTextGUI()
			end
		})
		CustomText = TextGUI:CreateToggle({
			Name = 'Add custom text',
			Function = function(enabled)
				CustomTextBox.Object.Visible = enabled
				CustomTextFont.Object.Visible = enabled
				CustomTextColor.Object.Visible = enabled
				CustomTextColorSlider.Object.Visible = CustomTextColor.Enabled and enabled
				vape:UpdateTextGUI()
			end
		})
		CustomTextBox = TextGUI:CreateTextBox({
			Name = 'Custom text',
			Function = function()
				vape:UpdateTextGUI()
			end,
			Darker = true,
			Visible = false
		})
		CustomTextFont = TextGUI:CreateFont({
			Name = 'Custom Font',
			Default = 'Arial',
			Function = function()
				vape:UpdateTextGUI()
			end,
			Darker = true,
			Visible = false
		})
		CustomTextColor = TextGUI:CreateToggle({
			Name = 'Set custom text color',
			Function = function(enabled)
				CustomTextColorSlider.Object.Visible = enabled
				vape:UpdateGUI(vape.GUIColor.Hue, vape.GUIColor.Sat, vape.GUIColor.Value)
			end,
			Darker = true,
			Visible = false
		})
		CustomTextColorSlider = TextGUI:CreateColorSlider({
			Name = 'Color of custom text',
			Function = function(afterload)
				vape:UpdateGUI(vape.GUIColor.Hue, vape.GUIColor.Sat, vape.GUIColor.Value)
			end,
			Darker = true,
			Visible = false
		})
		
		
		--[[
			Text GUI Objects
		]]
		
		Scale = Instance.new('UIScale')
		Scale.Parent = TextGUI.Children
		local Logo = Instance.new('ImageLabel')
		Logo.BackgroundColor3 = Color3.new()
		Logo.BackgroundTransparency = 1
		Logo.BorderSizePixel = 0
		Logo.Image = getvapeasset('pistonware/assets/new/vapelogo.png')
		Logo.Name = 'Logo'
		Logo.Position = UDim2.new(1, -142, 0, 3)
		Logo.Size = UDim2.fromOffset(81, 24)
		Logo.Visible = false
		Logo.Parent = TextGUI.Children
		local LogoV4 = Instance.new('ImageLabel')
		LogoV4.BackgroundColor3 = Color3.new()
		LogoV4.BackgroundTransparency = 1
		LogoV4.BorderSizePixel = 0
		LogoV4.Image = getvapeasset('pistonware/assets/new/v4.png')
		LogoV4.Name = 'Logo2'
		LogoV4.Position = UDim2.new(1, -1, 0, 0)
		LogoV4.Size = UDim2.fromOffset(35, 24)
		LogoV4.Parent = Logo
		local LogoShadow = Logo:Clone()
		LogoShadow.ImageColor3 = Color3.new()
		LogoShadow.ImageTransparency = 0.65
		LogoShadow.Position = UDim2.fromOffset(1, 1)
		LogoShadow.Visible = true
		LogoShadow.ZIndex = 0
		LogoShadow.Parent = Logo
		LogoShadow.Logo2.ImageColor3 = Color3.new()
		LogoShadow.Logo2.ImageTransparency = 0.65
		LogoShadow.Logo2.ZIndex = 0
		local LogoGradient = Instance.new('UIGradient')
		LogoGradient.Rotation = 90
		LogoGradient.Parent = Logo
		local LogoGradient2 = Instance.new('UIGradient')
		LogoGradient2.Rotation = 90
		LogoGradient2.Parent = LogoV4
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
		
		function vape:UpdateTextGUI(afterload)
			if not afterload and not vape.Loaded then return end
			if TextGUI.Button.Enabled then
				local isRight = TextGUI.Children.AbsolutePosition.X > (gui.AbsoluteSize.X / 2)
		
				Logo.Visible = Watermark.Enabled
				Logo.Position = isRight and UDim2.new(1 / Scale.Scale, -113, 0, 6) or UDim2.fromOffset(0, 6)
				LogoShadow.Visible = Shadow.Enabled
				LabelCustom.Text = CustomTextBox.Value
				LabelCustom.FontFace = CustomTextFont.Value
				LabelCustom.Visible = LabelCustom.Text ~= '' and CustomText.Enabled
				LabelCustomShadow.Visible = LabelCustom.Visible and Shadow.Enabled
				ListLayout.HorizontalAlignment = isRight and Enum.HorizontalAlignment.Right or Enum.HorizontalAlignment.Left
				LabelHolder.Size = UDim2.fromScale(1 / Scale.Scale, 1)
				LabelHolder.Position = UDim2.fromOffset(isRight and 3 or 0, 11 + (Logo.Visible and Logo.Size.Y.Offset or 0) + (LabelCustom.Visible and 28 or 0) + (Background.Enabled and 3 or 0))
		
				if LabelCustom.Visible then
					local size = getfontbounds(contentText(LabelCustom), LabelCustom.TextSize, LabelCustom.FontFace)
					LabelCustom.Size = UDim2.fromOffset(size.X, size.Y)
					LabelCustom.Position = UDim2.new(isRight and 1 / Scale.Scale or 0, isRight and -size.X or 0, 0, (Logo.Visible and 32 or 8))
				end
		
				local Previous = {}
				for _, label in Labels do
					if label.Enabled then
						table.insert(Previous, label.Object.Name)
					end
		
					label.Object:Destroy()
				end
				table.clear(Labels)
		
				for name, module in orderedModules(vape.ModuleOrder) do
					if HideModules.Enabled and table.find(HideModulesList.ListEnabled, name) then
						continue
					end
		
					if HideRender.Enabled and module.Category == 'Render' then
						continue
					end
		
					if module.Enabled or table.find(Previous, name) then
						local bkg, colorline
						local holder = Instance.new('Frame')
						holder.BackgroundTransparency = 1
						holder.ClipsDescendants = true
						holder.Name = name
						holder.Size = UDim2.fromOffset()
						holder.Parent = LabelHolder
		
						if Background.Enabled then
							bkg = Instance.new('Frame')
							bkg.BackgroundColor3 = color.Dark(uipallet.Main, 0.15)
							bkg.BackgroundTransparency = BackgroundTransparency.Value
							bkg.BorderSizePixel = 0
							bkg.Size = UDim2.new(1, 0, 1, 0)
							bkg.Parent = holder
							local corner = Instance.new('UICorner')
							corner.Parent = bkg
							local line = Instance.new('Frame')
							line.BackgroundColor3 = Color3.new()
							line.BackgroundTransparency = 0.928 + (0.072 * math.clamp((BackgroundTransparency.Value - 0.5) / 0.5, 0, 1))
							line.BorderSizePixel = 0
							line.Position = UDim2.new(0, 0, 1, -1)
							line.Size = UDim2.new(1, 0, 0, 1)
							line.Parent = bkg
							local line2 = line:Clone()
							line2.Position = UDim2.new()
							line2.Name = 'Line'
							line2.Parent = bkg
							colorline = Instance.new('Frame')
							colorline.BorderSizePixel = 0
							colorline.Position = isRight and UDim2.new(1, -4, 0, 0) or UDim2.new()
							colorline.Size = UDim2.new(0, 4, 1, 0)
							colorline.Parent = bkg
							local colorcorner = Instance.new('UICorner')
							colorcorner.CornerRadius = UDim.new()
							colorcorner.Parent = colorline
						end
		
						local label = Instance.new('TextLabel')
						label.BackgroundTransparency = 1
						label.BorderSizePixel = 0
						label.FontFace = FontOption.Value
						label.Position = UDim2.fromOffset(isRight and 5 or 9, 2)
						--[[ ExtraText belongs to the game script, not to this file, and it is called
						here for every enabled module on every redraw. A module whose state is
						not ready yet -- which is exactly the moment a profile switches a batch
						of them on -- would otherwise throw and abort the whole rebuild, leaving
						the Text GUI half-destroyed with its label list already cleared. ]]
						local extra = ''
						if module.ExtraText then
							local ok, text = pcall(module.ExtraText)
							if ok and text ~= nil and text ~= '' then
								extra = " <font color='#A8A8A8'>"..tostring(text)..'</font>'
							end
						end
						label.Text = name..extra
						label.TextSize = 18
						label.RichText = true
		
						local size = getfontbounds(contentText(label), label.TextSize, label.FontFace)
						label.Size = UDim2.fromOffset(size.X, size.Y)
		
						if Shadow.Enabled then
							local shadowlabel = label:Clone()
							shadowlabel.Position = UDim2.fromOffset(label.Position.X.Offset + 1, label.Position.Y.Offset + 1)
							shadowlabel.Text = contentText(label)
							shadowlabel.TextColor3 = Color3.new()
							shadowlabel.Parent = holder
						end
		
						label.Parent = holder
		
						local tweenSize = UDim2.fromOffset(size.X + 16, size.Y + 6)
						if Animations.Enabled then
							if not table.find(Previous, name) then
								tween:Tween(holder, info, {
									Size = tweenSize
								})
							else
								holder.Size = tweenSize
								if not module.Enabled then
									tween:Tween(holder, info, {
										Size = UDim2.fromOffset()
									})
								end
							end
						else
							holder.Size = module.Enabled and tweenSize or UDim2.fromOffset()
						end
		
						table.insert(Labels, {
							Background = bkg,
							Color = colorline,
							Enabled = module.Enabled,
							Object = holder,
							Text = label,
							Size = module.Enabled and tweenSize or UDim2.fromOffset()
						})
					end
				end
		
				if Sort.Value == 'Alphabetical' then
					table.sort(Labels, function(a, b)
						return a.Text.Text < b.Text.Text
					end)
				else
					table.sort(Labels, function(a, b)
						return a.Text.Size.X.Offset > b.Text.Size.X.Offset
					end)
				end
		
				for index, label in Labels do
					if label.Color then
						local top = (not Labels[index - 1] or (Labels[index - 1].Size.X.Offset < label.Size.X.Offset)) and 4 or 0
						local bottom = (not Labels[index + 1] or (Labels[index + 1].Size.X.Offset < label.Size.X.Offset)) and 4 or 0
		
						label.Color.Parent.Line.Visible = index ~= 1
		
		--[[ Per-corner radii are recent; older clients only have CornerRadius. Because
		this runs on every Text GUI redraw, unsupported clients threw on every refresh. ]]
						if hasCornerRadii then
							label.Color.UICorner.TopLeftRadius = isRight and UDim.new() or UDim.new(0, index == 1 and 4 or 0)
							label.Color.UICorner.TopRightRadius = isRight and UDim.new(0, index == 1 and 4 or 0) or UDim.new()
							label.Color.UICorner.BottomLeftRadius = isRight and UDim.new() or UDim.new(0, index == #Labels and 4 or 0)
							label.Color.UICorner.BottomRightRadius = isRight and UDim.new(0, index == #Labels and 4 or 0) or UDim.new()
		
							label.Background.UICorner.TopLeftRadius = UDim.new(0, top)
							label.Background.UICorner.TopRightRadius = UDim.new(0, top)
							label.Background.UICorner.BottomLeftRadius = UDim.new(0, bottom)
							label.Background.UICorner.BottomRightRadius = UDim.new(0, bottom)
						end
					end
		
					label.Object.LayoutOrder = index
				end
			end
		
			self:UpdateGUI(self.GUIColor.Hue, self.GUIColor.Sat, self.GUIColor.Value, true)
		end
		
		function TextGUI:UpdateColor(hue, sat, val, default)
			LogoGradient.Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.fromHSV(hue, sat, val)),
				ColorSequenceKeypoint.new(1, Gradient.Enabled and Color3.fromHSV(vape:Color((hue - 0.075) % 1)) or Color3.fromHSV(hue, sat, val))
			})
			LogoGradient2.Color = Gradient.Enabled and GradientV4.Enabled and LogoGradient.Color or ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.new(1, 1, 1)),
				ColorSequenceKeypoint.new(1, Color3.new(1, 1, 1))
			})
			LabelCustom.TextColor3 = CustomTextColor.Enabled and Color3.fromHSV(CustomTextColorSlider.Hue, CustomTextColorSlider.Sat, CustomTextColorSlider.Value) or LogoGradient.Color.Keypoints[2].Value
		
			local isCustom = ColorMode.Value == 'Custom color' and Color3.fromHSV(ColorSlider.Hue, ColorSlider.Sat, ColorSlider.Value) or nil
			for index, label in Labels do
				label.Text.TextColor3 = isCustom or (vape.GUIColor.Rainbow and Color3.fromHSV(vape:Color((hue - ((Gradient.Enabled and index + 2 or index) * 0.025)) % 1)) or LogoGradient.Color.Keypoints[2].Value)
		
				if label.Color then
					label.Color.BackgroundColor3 = label.Text.TextColor3
				end
		
				if BackgroundTint.Enabled and label.Background then
					label.Background.BackgroundColor3 = color.Dark(label.Text.TextColor3, 0.75)
				end
			end
		end
	end)
	
	run(function()
		--[[
			Target Info
		]]
		
		-- Object is filled in once Holder exists (a few dozen lines down). Setting it here
		-- read an undeclared global, so vape.Libraries.targetinfo.Object was permanently nil.
		local targetinfo = {
			Targets = {},
			Object = nil,
			Health = 0,
			MaxHealth = 0
		}
		local TargetInfoOverlay
		local BackgroundTransparency = {
			Value = 0.5,
			Object = {Visible = {}}
		}
		local BorderColor
		local BKGColor
		local CustomColor
		local DisplayName
		
		TargetInfoOverlay = vape:CreateOverlay({
			Name = 'Target Info',
			Icon = getvapeasset('pistonware/assets/new/targetinfo.png'),
			Size = UDim2.fromOffset(14, 14),
			Position = UDim2.fromOffset(12, 14),
			CategorySize = 240,
			Function = function(callback)
				if callback then
					TargetInfoOverlay:Clean(runService.RenderStepped:Connect(function()
						targetinfo:Update()
					end))
				end
			end
		})
		
		local Holder = Instance.new('Frame')
		targetinfo.Object = Holder
		Holder.Size = UDim2.fromOffset(240, 89)
		Holder.BackgroundColor3 = color.Dark(uipallet.Main, 0.1)
		Holder.BackgroundTransparency = 0.5
		Holder.Parent = TargetInfoOverlay.Children
		targetinfo.Object = Holder
		local BlurHolder = addBlur(Holder, nil, true)
		BlurHolder.Visible = false
		addCorner(Holder)
		local Headshot = Instance.new('ImageLabel')
		Headshot.Size = UDim2.fromOffset(26, 27)
		Headshot.Position = UDim2.fromOffset(19, 17)
		Headshot.BackgroundColor3 = uipallet.Main
		Headshot.Image = 'rbxthumb://type=AvatarHeadShot&id=1&w=420&h=420'
		Headshot.Parent = Holder
		addCorner(Headshot)
		local HurtFlash = Instance.new('Frame')
		HurtFlash.Size = UDim2.fromScale(1, 1)
		HurtFlash.BackgroundTransparency = 1
		HurtFlash.BackgroundColor3 = Color3.new(1, 0, 0)
		HurtFlash.Parent = Headshot
		addCorner(HurtFlash)
		local HeadshotBlur = addBlur(Headshot)
		setBlurEnabled(HeadshotBlur, false)
		local Name = Instance.new('TextLabel')
		Name.Size = UDim2.fromOffset(145, 20)
		Name.Position = UDim2.fromOffset(54, 20)
		Name.BackgroundTransparency = 1
		Name.Text = 'Target name'
		Name.TextXAlignment = Enum.TextXAlignment.Left
		Name.TextYAlignment = Enum.TextYAlignment.Top
		Name.TextScaled = true
		Name.TextColor3 = color.Light(uipallet.Text, 0.4)
		Name.TextStrokeTransparency = 1
		Name.FontFace = uipallet.Font
		local NameShadow = Name:Clone()
		NameShadow.Position = UDim2.fromOffset(55, 21)
		NameShadow.TextColor3 = Color3.new()
		NameShadow.TextTransparency = 0.65
		NameShadow.Visible = false
		NameShadow.Parent = Holder
		for _, prop in {'Size', 'Text', 'FontFace'} do
			Name:GetPropertyChangedSignal(prop):Connect(function()
				NameShadow[prop] = Name[prop]
			end)
		end
		Name.Parent = Holder
		local HealthBKG = Instance.new('Frame')
		HealthBKG.Name = 'HealthBKG'
		HealthBKG.Size = UDim2.fromOffset(200, 9)
		HealthBKG.Position = UDim2.fromOffset(20, 56)
		HealthBKG.BackgroundColor3 = uipallet.Main
		HealthBKG.BorderSizePixel = 0
		HealthBKG.Parent = Holder
		addCorner(HealthBKG, UDim.new(1, 0))
		local Health = HealthBKG:Clone()
		Health.Size = UDim2.fromScale(0.8, 1)
		Health.Position = UDim2.new()
		Health.BackgroundColor3 = Color3.fromHSV(1 / 2.5, 0.89, 0.75)
		Health.Parent = HealthBKG
		Health:GetPropertyChangedSignal('Size'):Connect(function()
			Health.Visible = Health.Size.X.Scale > 0.01
		end)
		local Armor = Health:Clone()
		Armor.Size = UDim2.new()
		Armor.Position = UDim2.fromScale(1, 0)
		Armor.AnchorPoint = Vector2.new(1, 0)
		Armor.BackgroundColor3 = Color3.fromRGB(255, 170, 0)
		Armor.Visible = false
		Armor.Parent = HealthBKG
		Armor:GetPropertyChangedSignal('Size'):Connect(function()
			Armor.Visible = Armor.Size.X.Scale > 0.01
		end)
		local HealthBlur = addBlur(HealthBKG)
		setBlurEnabled(HealthBlur, false)
		local Stroke = Instance.new('UIStroke')
		Stroke.Enabled = false
		Stroke.Color = Color3.fromHSV(0.44, 1, 1)
		Stroke.Parent = Holder
		
		TargetInfoOverlay:CreateFont({
			Name = 'Font',
			Default = 'Arial',
			Function = function(val)
				Name.FontFace = val
			end
		})
		DisplayName = TargetInfoOverlay:CreateToggle({
			Name = 'Use Displayname',
			Default = true
		})
		TargetInfoOverlay:CreateToggle({
			Name = 'Render Background',
			Function = function(callback)
				Holder.BackgroundTransparency = callback and BackgroundTransparency.Value or 1
				NameShadow.Visible = not callback
				BlurHolder.Visible = callback
				setBlurEnabled(HealthBlur, not callback)
				setBlurEnabled(HeadshotBlur, not callback)
				BackgroundTransparency.Object.Visible = callback
			end,
			Default = true
		})
		BackgroundTransparency = TargetInfoOverlay:CreateSlider({
			Name = 'Transparency',
			Min = 0,
			Max = 1,
			Default = 0.5,
			Decimal = 10,
			Function = function(val)
				Holder.BackgroundTransparency = val
			end,
			Darker = true
		})
		CustomColor = TargetInfoOverlay:CreateToggle({
			Name = 'Custom Color',
			Function = function(callback)
				BKGColor.Object.Visible = callback
				if callback then
					Holder.BackgroundColor3 = Color3.fromHSV(BKGColor.Hue, BKGColor.Sat, BKGColor.Value)
					Headshot.BackgroundColor3 = Color3.fromHSV(BKGColor.Hue, BKGColor.Sat, math.max(BKGColor.Value - 0.1, 0.075))
					HealthBKG.BackgroundColor3 = Headshot.BackgroundColor3
				else
					Holder.BackgroundColor3 = color.Dark(uipallet.Main, 0.1)
					Headshot.BackgroundColor3 = uipallet.Main
					HealthBKG.BackgroundColor3 = uipallet.Main
				end
			end
		})
		BKGColor = TargetInfoOverlay:CreateColorSlider({
			Name = 'Color',
			Function = function(hue, sat, val)
				if CustomColor.Enabled then
					Holder.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
					Headshot.BackgroundColor3 = Color3.fromHSV(hue, sat, math.max(val - 0.1, 0))
					HealthBKG.BackgroundColor3 = Headshot.BackgroundColor3
				end
			end,
			Darker = true,
			Visible = false
		})
		TargetInfoOverlay:CreateToggle({
			Name = 'Border',
			Function = function(callback)
				Stroke.Enabled = callback
				BorderColor.Object.Visible = callback
			end
		})
		BorderColor = TargetInfoOverlay:CreateColorSlider({
			Name = 'Border Color',
			Function = function(hue, sat, val, opacity)
				Stroke.Color = Color3.fromHSV(hue, sat, val)
				Stroke.Transparency = 1 - opacity
			end,
			Darker = true,
			Visible = false
		})
		
		function targetinfo:Update()
			if not vape.Libraries then return end

			--[[
				One pass, no copy.

				This runs on RenderStepped, and it used to table.clone(self.Targets) on every
				frame purely so it could clear expired entries while iterating -- a whole
				table allocated and thrown away 60-240 times a second, for a set that is
				almost always empty or holds one entity.

				Clearing a field that already exists is explicitly allowed during Luau's
				generalised iteration, so expiry and the highest-priority search fold into the
				same walk. tick() is read once instead of once per entry as well.
			]]
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


			Holder.Visible = entity ~= nil or clickgui.Visible
			if entity then
				Name.Text = entity.Player and (DisplayName.Enabled and entity.Player.DisplayName or entity.Player.Name) or entity.Character and entity.Character.Name or Name.Text
				Headshot.Image = 'rbxthumb://type=AvatarHeadShot&id='..(entity.Player and entity.Player.UserId or 1)..'&w=420&h=420'
		
				if not entity.Character then
					entity.Health = entity.Health or 0
					entity.MaxHealth = entity.MaxHealth or 100
				end
		
				if entity.Health ~= self.Health or entity.MaxHealth ~= self.MaxHealth then
					local percent = math.max(entity.Health / entity.MaxHealth, 0)
		
					tween:Tween(Health, TweenInfo.new(0.3), {
						Size = UDim2.fromScale(math.min(percent, 1), 1), BackgroundColor3 = Color3.fromHSV(math.clamp(percent / 2.5, 0, 1), 0.89, 0.75)
					})
		
					tween:Tween(Armor, TweenInfo.new(0.3), {
						Size = UDim2.fromScale(math.clamp(percent - 1, 0, 0.8), 1)
					})
		
					if self.Health > entity.Health and self.LastTarget == entity then
						tween:Cancel(HurtFlash)
						HurtFlash.BackgroundTransparency = 0.3
						tween:Tween(HurtFlash, TweenInfo.new(0.5), {
							BackgroundTransparency = 1
						})
					end
		
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
	end)
	
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

			for _, component in vape.RainbowSliders do
				if component.Type == 'GUISlider' then
					component:SetValue(vape:Color(hue))
				else
					component:SetValue(hue)
				end
			end

			local delta = task.wait(1 / vape.RainbowUpdateSpeed.Value)
			hue = (hue + (delta * (0.2 * vape.RainbowSpeed.Value))) % 1
		until false
	end))
	
	local cursorConnection
	vape:Clean(clickgui:GetPropertyChangedSignal('Visible'):Connect(function()
		vape:UpdateGUI(vape.GUIColor.Hue, vape.GUIColor.Sat, vape.GUIColor.Value, true)
	
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
					cursor.Visible = false
					cursorConnection:Disconnect()
					cursorConnection = nil
					return
				end
	
				cursor.Visible = not inputService.MouseIconEnabled
				if cursor.Visible then
					local mouseLocation = inputService:GetMouseLocation()
					cursor.Position = UDim2.fromOffset(mouseLocation.X - 31, mouseLocation.Y - 32)
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
		Rescale on a resize, and on a rotation.

		Watching the ScreenGui's AbsoluteSize alone was not enough on mobile: it is (0, 0) until
		the GUI first renders, so the initial scale above was always the floor value, and a
		device that reports the same AbsoluteSize through a rotation never fired at all. The
		camera's ViewportSize is the thing that actually changes, and it is the signal the old
		GUI watched.
	]]
	local function applyAutoScale()
		if vape.Scale and vape.Scale.Enabled then
			scale.Scale = autoScaleValue()
		end
	end

	if gameCamera then
		vape:Clean(gameCamera:GetPropertyChangedSignal('ViewportSize'):Connect(applyAutoScale))
	end
	vape:Clean(workspace:GetPropertyChangedSignal('CurrentCamera'):Connect(function()
		gameCamera = workspace.CurrentCamera
		applyAutoScale()
	end))
	vape:Clean(gui:GetPropertyChangedSignal('AbsoluteSize'):Connect(applyAutoScale))
	
	vape:Clean(notifications.ChildRemoved:Connect(function()
		for index, notif in notifications:GetChildren() do
			if tween.Tween then
				tween:Tween(notif, TweenInfo.new(0.4, Enum.EasingStyle.Exponential), {
					Position = UDim2.new(1, 0, 1, -(29 + (78 * index)))
				})
			end
		end
	end))
	
	vape:Clean(scale:GetPropertyChangedSignal('Scale'):Connect(function()
		scaledgui.Size = UDim2.fromScale(1 / scale.Scale, 1 / scale.Scale)
	
		--[[ GetDescendants, not QueryDescendants. The selector-query API is recent and
		unavailable on the mobile clients used by these executors. This runs on every scale
		change, which on a phone is every rotation, and nudges the same objects. ]]
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
	
		for _, window in self.Windows do
			window.Visible = false
		end
	
		for _, module in orderedModules(self.ModuleOrder) do
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
end

function vape:Remove(obj)
	local container = (self.Modules[obj] and self.Modules or self.Legit.Modules[obj] and self.Legit.Modules or self.Categories)
	if container and container[obj] then
		local component = container[obj]
		local isModule = component.Type == 'Module'
		if self.ThreadFix then
			setthreadidentity(8)
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

function vape:Save(newProfile)
	if not self.Loaded then
		return
	end

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

		return
	end

	trace('save '..tostring(self.Profile))
	local guiSuccess, guiError = writeJson('pistonware/profiles/'..game.GameId..'.gui.txt', guiData)
	local mainSuccess, mainError = writeJson('pistonware/profiles/'..self.Profile..self.Place..'.txt', mainData)
	trace('save done')

	if guiSuccess and mainSuccess then
		self.SaveFailed = nil
	elseif not self.SaveFailed then
		self.SaveFailed = true
		self:CreateNotification('Pistonware', 'Failed to save your config, '..tostring(guiError or mainError), 10, 'alert')
	end
end

function vape:RequestSave()
	if not self.Loaded then
		self.SaveNeeded = true
		return
	end

	self.SaveTime = os.clock() + 0.4

	if self.SaveQueued then
		return
	end

	self.SaveQueued = true

	local function flush()
		if vape.ThreadFix then
			setthreadidentity(8)
		end

		local remaining = self.SaveTime - os.clock()
		if remaining > 0 then
			task.delay(remaining, flush)
			return
		end

		self.SaveQueued = nil
		self.SaveNeeded = nil

		if self.Loaded then
			self:Save()
		end
	end

	task.delay(0.4, flush)
end

-- Called by main.lua the instant saving becomes safe, so a toggle made while the payload was
-- still loading is written then rather than waiting for a backstop tick.
function vape:FlushSave()
	if not self.SaveNeeded then
		return
	end

	self.SaveNeeded = nil
	self:RequestSave()
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
				module.Index = index
				module.Object.LayoutOrder = index
				module.Children.LayoutOrder = index
			end
		end
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
-- The public form, so main.lua's crumbs and the GUI's end up in ONE ordered log rather than
-- each overwriting the other's file. Silent unless the trace flag is set.
function vape:Trace(text)
	trace(tostring(text))
end

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
	self:Save()
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
		pcall(function()
			connection:Disconnect()
		end)
	end

	if self.ThreadFix then
		setthreadidentity(8)
		clickgui.Visible = false
		self:BlurCheck()
	end

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

	if TextGUI.Button.Enabled then
		TextGUI:UpdateColor(hue, sat, val, default)
	end

	if not clickgui.Visible and not vape.Legit.Window.Visible then return end
	local isRainbow = vape.GUIColor.Rainbow and vape.RainbowMode.Value ~= 'Retro'

	-- The Profiles cards are built inside their own do-block and are only recoloured when
	-- something pokes them (a load, or the mouse entering the row), so with the GUI colour on
	-- rainbow the sync button and the equipped-config highlight would sit frozen at whatever
	-- hue happened to be current at the time while everything around them cycled.
	if vape.RecolorProfileCards then
		vape.RecolorProfileCards()
	end

	for name, component in vape.Categories do
		component:Color(hue, sat, val, isRainbow)
	end

	for _, component in orderedModules(vape.ModuleOrder) do
		component:Color(hue, sat, val, isRainbow)
	end

	for _, component in vape.Overlays.Options do
		if component.Color then
			component:Color(hue, sat, val, isRainbow)
		end
	end

	for _, pane in vape.Settings do
		for _, component in pane.Options do
			if component.Color then
				component:Color(hue, sat, val, isRainbow)
			end
		end
	end

	if vape.Legit.Window.Visible then
		for _, component in orderedModules(vape.Legit.Order) do
			component:Color(hue, sat, val, isRainbow)
		end
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
			return comp(props, children, component)
		end
	end
end

components = {
	Bind = function(props, children, api)
		local component = {
			Hold = props.Hold or false,
			Keys = {},
			Triggered = createSignal(),
			Type = 'Bind'
		}
		
		local bind = Instance.new('TextButton')
		bind.AnchorPoint = Vector2.new(1, 0)
		bind.AutoButtonColor = false
		bind.BackgroundColor3 = Color3.new(1, 1, 1)
		bind.BackgroundTransparency = 0.92
		bind.BorderSizePixel = 0
		bind.Name = 'Bind'
		bind.Size = UDim2.fromOffset(20, 20)
		bind.Visible = false
		bind.Text = ''
		addCorner(bind, UDim.new(0, 4))
		addTooltip(bind, '', function()
			local holdText = 'Bind functionality = '..(component.Hold and 'Enable while held' or 'Toggle')
			if inputService:IsKeyDown(Enum.KeyCode.LeftShift) then
				holdText = "<font color='#FF5A5A'>"..holdText.."</font>"
			end
		
			return 'Click to bind\nShift click to modify bind functionality\n'..holdText
		end)
		local icon = Instance.new('ImageLabel')
		icon.BackgroundTransparency = 1
		icon.Image = getvapeasset('pistonware/assets/new/bind.png')
		icon.ImageColor3 = color.Dark(uipallet.Text, 0.43)
		icon.Name = 'Icon'
		icon.Position = UDim2.new(0.5, -5, 0, 5)
		icon.Size = UDim2.fromOffset(10, 10)
		icon.Parent = bind
		local label = Instance.new('TextLabel')
		label.BackgroundTransparency = 1
		label.FontFace = uipallet.Font
		label.Position = UDim2.fromOffset(-1, 0)
		label.Size = UDim2.fromScale(1, 1)
		label.Text = ''
		label.TextColor3 = color.Dark(uipallet.Text, 0.43)
		label.TextSize = 12
		label.Visible = false
		label.Parent = bind
		local cover
		local coverlabel
		
		if props.Module then
			if props.Cover then
				cover = Instance.new('ImageLabel')
				cover.BackgroundTransparency = 1
				cover.Image = getvapeasset('pistonware/assets/new/bindbkg.png')
				cover.Name = 'Cover'
				cover.ScaleType = Enum.ScaleType.Slice
				cover.SliceCenter = Rect.new(0, 0, 141, 40)
				cover.Size = UDim2.fromOffset(154, 40)
				cover.Visible = false
				cover.Parent = api.Object
				coverlabel = Instance.new('TextLabel')
				coverlabel.BackgroundTransparency = 1
				coverlabel.FontFace = uipallet.Font
				coverlabel.Name = 'Text'
				coverlabel.Size = UDim2.new(1, -10, 1, -3)
				coverlabel.Text = 'PRESS A KEY TO BIND'
				coverlabel.TextColor3 = uipallet.Text
				coverlabel.TextSize = 11
				coverlabel.Parent = cover
			end
		
			bind.Position = UDim2.new(1, -36, 0, 10)
			bind.Parent = api.Object
			component.Object = bind
		else
			local holder = Instance.new('TextButton')
			holder.AutoButtonColor = false
			holder.BackgroundColor3 = color.Dark(children.BackgroundColor3, props.Darker and 0.02 or 0)
			holder.BorderSizePixel = 0
			holder.FontFace = uipallet.Font
			holder.Size = UDim2.new(1, 0, 0, 40)
			holder.Text = '          '..props.Name
			holder.TextColor3 = color.Dark(uipallet.Text, 0.16)
			holder.TextSize = 14
			holder.TextXAlignment = Enum.TextXAlignment.Left
			holder.Visible = props.Visible == nil or props.Visible
			holder.Parent = children
			addTooltip(holder, props.Tooltip)
			bind.Position = UDim2.new(1, -10, 0, 10)
			bind.Visible = true
			bind.Parent = holder
			component.Object = holder
		end
		
		function component:CreateMobileButton(position)
			self:DestroyMobileButton()
		
			local isHeld = false
			local button = Instance.new('TextButton')
			button.AnchorPoint = Vector2.new(0.5, 0.5)
			button.BackgroundColor3 = api.Enabled and Color3.new(0, 0.7, 0) or Color3.new()
			button.BackgroundTransparency = 0.5
			button.Font = Enum.Font.Gotham
			button.Position = UDim2.fromOffset(position.X, position.Y)
			button.Size = UDim2.fromOffset(40, 40)
			button.Text = api.Name or 'Button'
			button.TextColor3 = Color3.new(1, 1, 1)
			button.TextScaled = true
			button.Parent = gui
			local constraint = Instance.new('UITextSizeConstraint')
			constraint.MaxTextSize = 16
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
				end
			end)
		
			button.MouseButton1Up:Connect(function()
				isHeld = false
			end)
		
			button.MouseButton1Click:Connect(function()
				self.Triggered:Fire(true)
				button.BackgroundColor3 = api.Enabled and Color3.new(0, 0.7, 0) or Color3.new()
			end)
		
			self.Mobile = button
		end
		
		function component:Destroy()
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
		
			if mouse then
				icon.Image = getvapeasset('pistonware/assets/new/edit.png')
		
				if cover then
					coverlabel.Text = #keys <= 0 and 'BIND REMOVED' or 'BOUND TO'
					cover.Size = UDim2.fromOffset(getfontbounds(coverlabel.Text, coverlabel.TextSize, coverlabel.FontFace).X + 20, 40)
		
					task.delay(1, function()
						cover.Visible = false
					end)
				end
			end
		
			if #keys <= 0 then
				label.Visible = false
				icon.Visible = true
				bind.Size = UDim2.fromOffset(20, 20)
		
				local index = table.find(vape.ActiveBinds, component)
				if index then
					table.remove(vape.ActiveBinds, index)
				end
			else
				bind.Visible = true
				label.Visible = true
				icon.Visible = false
				label.Text = table.concat(keys, ' + '):upper()
				bind.Size = UDim2.fromOffset(math.max(getfontbounds(label.Text, label.TextSize, label.FontFace).X + 10, 20), 20)
		
				if not table.find(vape.ActiveBinds, component) then
					table.insert(vape.ActiveBinds, component)
				end
			end
		end
		
		function component:SetColor(newColor)
			icon.ImageColor3 = newColor
			label.TextColor3 = newColor
		end
		
		function component:SetParent(parent)
			bind.Parent = parent
		
			if cover then
				cover.Parent = parent
			end
		end
		
		function component:SetVisible(visible)
			bind.Visible = #self.Keys > 0 or visible
		end
		
		bind.MouseEnter:Connect(function()
			label.Visible = false
			icon.Visible = not label.Visible
			icon.Image = getvapeasset(component.Binding and 'pistonware/assets/new/close.png' or 'pistonware/assets/new/edit.png')
		
			if not props.Cover or not api.Enabled then
				icon.ImageColor3 = color.Dark(uipallet.Text, 0.16)
			end
		end)
		
		bind.MouseLeave:Connect(function()
			label.Visible = #component.Keys > 0
			icon.Visible = not label.Visible
			icon.Image = getvapeasset(component.Binding and 'pistonware/assets/new/close.png' or 'pistonware/assets/new/bind.png')
		
			if not props.Cover or not api.Enabled then
				icon.ImageColor3 = color.Dark(uipallet.Text, 0.43)
			end
		end)
		
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
				if vape.CurrentTooltip then
					vape.CurrentTooltip()
				end
		
				return
			end
		
			if cover then
				coverlabel.Text = 'PRESS A KEY TO BIND'
				cover.Size = UDim2.fromOffset(getfontbounds(coverlabel.Text, coverlabel.TextSize, coverlabel.FontFace).X + 20, 40)
				cover.Visible = true
			end
		
			component.Binding = true
			icon.Image = getvapeasset('pistonware/assets/new/close.png')
			vape.Binding = component
		end)
		
		if props.Module then
			api.Bind = component
		else
			if props.Default then
				component:SetBind(props.Default)
			end
		
			api.Options[props.Name] = component
		end
		
		return component
	end,
	Button = function(props, children, api)
		local button = Instance.new('TextButton')
		button.AutoButtonColor = false
		button.BackgroundColor3 = color.Dark(children.BackgroundColor3, props.Darker and 0.02 or 0)
		button.BorderSizePixel = 0
		button.Size = UDim2.new(1, 0, 0, 31)
		button.Text = ''
		button.Parent = children
		addTooltip(button, props.Tooltip)
		local holder = Instance.new('Frame')
		holder.BackgroundColor3 = color.Light(uipallet.Main, 0.05)
		holder.Position = UDim2.fromOffset(10, 2)
		holder.Size = UDim2.fromOffset(200, 27)
		holder.Parent = button
		addCorner(holder)
		local title = Instance.new('TextLabel')
		title.BackgroundColor3 = uipallet.Main
		title.FontFace = uipallet.Font
		title.Position = UDim2.fromOffset(2, 2)
		title.Size = UDim2.new(1, -4, 1, -4)
		title.Text = props.Name
		title.TextColor3 = color.Dark(uipallet.Text, 0.16)
		title.TextSize = 14
		title.Parent = holder
		addCorner(title, UDim.new(0, 4))
		props.Function = props.Function or function() end
		
		button.MouseEnter:Connect(function()
			tween:Tween(holder, uipallet.Tween, {
				BackgroundColor3 = color.Light(uipallet.Main, 0.0875)
			})
		end)
		
		button.MouseLeave:Connect(function()
			tween:Tween(holder, uipallet.Tween, {
				BackgroundColor3 = color.Light(uipallet.Main, 0.05)
			})
		end)
		
		button.MouseButton1Click:Connect(props.Function)
	end,
	Category = function(props, children, api)
		local component = {
			Expanded = false,
			Name = props.Name,
			Type = 'Category'
		}
		
		local window = Instance.new('TextButton')
		window.AutoButtonColor = false
		window.BackgroundColor3 = uipallet.Main
		window.Name = props.Name..'Category'
		window.Position = UDim2.fromOffset(236, 60)
		window.Size = UDim2.fromOffset(220, 41)
		window.Text = ''
		window.Visible = false
		window.Parent = clickgui
		addBlur(window)
		addCorner(window)
		addDragHandler(window)
		local icon = Instance.new('ImageLabel')
		icon.BackgroundTransparency = 1
		icon.Image = props.Icon
		icon.ImageColor3 = uipallet.Text
		-- props.Size, not icon.Size: Size is assigned on the NEXT line, so this read the
		-- freshly-constructed default of (0, 0) every time and the branch could never be
		-- taken. CategoryList a few components down already measures props.Size here.
		icon.Position = UDim2.fromOffset(12, (props.Size.X.Offset > 20 and 14 or 13))
		icon.Size = props.Size
		icon.Parent = window
		local title = Instance.new('TextLabel')
		title.BackgroundTransparency = 1
		title.FontFace = uipallet.Font
		title.Size = UDim2.new(1, -(props.Size.X.Offset > 18 and 40 or 33), 0, 41)
		title.Position = UDim2.fromOffset(math.abs(title.Size.X.Offset), 0)
		title.Text = props.Name
		title.TextColor3 = uipallet.Text
		title.TextSize = 13
		title.TextXAlignment = Enum.TextXAlignment.Left
		title.Parent = window
		local pencilbutton = Instance.new('TextButton')
		pencilbutton.BackgroundTransparency = 1
		pencilbutton.Position = UDim2.new(1, -49, 0, 0)
		pencilbutton.Size = UDim2.fromOffset(20, 40)
		pencilbutton.Text = ''
		pencilbutton.Visible = false
		pencilbutton.Parent = window
		addTooltip(pencilbutton, 'Edit hidden modules')
		local pencil = Instance.new('ImageLabel')
		pencil.BackgroundTransparency = 1
		pencil.Image = getvapeasset('pistonware/assets/new/editlarge.png')
		pencil.ImageColor3 = Color3.fromRGB(140, 140, 140)
		pencil.Size = UDim2.fromOffset(12, 12)
		pencil.Position = UDim2.fromOffset(4, 14)
		pencil.Parent = pencilbutton
		local arrowbutton = Instance.new('TextButton')
		arrowbutton.BackgroundTransparency = 1
		arrowbutton.Position = UDim2.new(1, -29, 0, 0)
		arrowbutton.Size = UDim2.fromOffset(27, 40)
		arrowbutton.Text = ''
		arrowbutton.Parent = window
		local arrow = Instance.new('ImageLabel')
		arrow.BackgroundTransparency = 1
		arrow.Image = getvapeasset('pistonware/assets/new/downexpand.png')
		arrow.ImageColor3 = Color3.fromRGB(140, 140, 140)
		arrow.Size = UDim2.fromOffset(9, 4)
		arrow.Position = UDim2.fromOffset(9, 18)
		arrow.Rotation = 180
		arrow.Parent = arrowbutton
		local done = Instance.new('TextButton')
		done.BackgroundTransparency = 1
		done.FontFace = uipallet.Font
		done.Position = UDim2.new(1, -73, 0, 0)
		done.Size = UDim2.fromOffset(42, 40)
		done.Text = 'DONE'
		done.TextColor3 = Color3.fromRGB(140, 140, 140)
		done.TextSize = 12
		done.Visible = false
		done.Parent = window
		component.Done = done
		local children = Instance.new('ScrollingFrame')
		children.BackgroundTransparency = 1
		children.BorderSizePixel = 0
		children.CanvasSize = UDim2.new()
		children.Name = 'Children'
		children.Position = UDim2.fromOffset(0, 37)
		children.ScrollBarThickness = 2
		children.ScrollBarImageTransparency = 0.75
		children.Size = UDim2.new(1, 0, 1, -41)
		children.Visible = false
		children.Parent = window
		local divider = Instance.new('Frame')
		divider.BackgroundColor3 = Color3.new(1, 1, 1)
		divider.BackgroundTransparency = 0.928
		divider.BorderSizePixel = 0
		divider.Position = UDim2.fromOffset(0, 37)
		divider.Size = UDim2.new(1, 0, 0, 1)
		divider.Visible = false
		divider.Parent = window
		local stroke = Instance.new('UIStroke')
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.Color = Color3.fromRGB(85, 85, 85)
		stroke.Transparency = 0.8
		stroke.Parent = window
		local windowlist = Instance.new('UIListLayout')
		windowlist.HorizontalAlignment = Enum.HorizontalAlignment.Center
		windowlist.SortOrder = Enum.SortOrder.LayoutOrder
		windowlist.Parent = children
		
		function component:Color(hue, sat, val, isRainbow) end
		
		function component:Expand()
			self.Expanded = not self.Expanded
			children.Visible = self.Expanded
			arrow.Rotation = self.Expanded and 0 or 180
			window.Size = UDim2.fromOffset(220, self.Expanded and math.min(41 + windowlist.AbsoluteContentSize.Y / scale.Scale, 601) or 41)
			divider.Visible = children.CanvasPosition.Y > 10 and children.Visible
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
		
		bindComponents(component, children)
		
		arrowbutton.MouseButton1Click:Connect(function()
			component:Expand()
		end)
		
		arrowbutton.MouseButton2Click:Connect(function()
			component:Expand()
		end)
		
		arrowbutton.MouseEnter:Connect(function()
			arrow.ImageColor3 = Color3.fromRGB(220, 220, 220)
		end)
		
		arrowbutton.MouseLeave:Connect(function()
			arrow.ImageColor3 = Color3.fromRGB(140, 140, 140)
		end)
		
		done.MouseButton1Click:Connect(function()
			vape.EditGUI = false
			pencilbutton.Visible = true
		
			for _, category in vape.Categories do
				if category.Type == 'Category' then
					category.Done.Visible = false
				end
			end
		
			for _, module in orderedModules(vape.ModuleOrder) do
				module.Object.Visible = module.Visible
				module.Object.Text = string.rep(' ', 12)..module.Name
				module.Edit.Visible = false
			end
		end)
		
		done.MouseEnter:Connect(function()
			done.TextColor3 = Color3.fromRGB(220, 220, 220)
		end)
		
		done.MouseLeave:Connect(function()
			done.TextColor3 = Color3.fromRGB(140, 140, 140)
		end)
		
		pencilbutton.MouseButton1Click:Connect(function()
			vape.EditGUI = true
			pencilbutton.Visible = false
		
			for _, category in vape.Categories do
				if category.Type == 'Category' then
					category.Done.Visible = true
				end
			end
		
			for _, module in orderedModules(vape.ModuleOrder) do
				module.Object.Visible = true
				module.Object.Text = string.rep(' ', 50)..module.Name
				module.Edit.Visible = true
			end
		end)
		
		pencilbutton.MouseButton2Click:Connect(function()
			component:Expand()
		end)
		
		pencilbutton.MouseEnter:Connect(function()
			pencil.ImageColor3 = Color3.fromRGB(220, 220, 220)
		end)
		
		pencilbutton.MouseLeave:Connect(function()
			pencil.ImageColor3 = Color3.fromRGB(140, 140, 140)
		end)
		
		window.MouseEnter:Connect(function()
			pencilbutton.Visible = not vape.EditGUI
		end)
		
		window.MouseLeave:Connect(function()
			pencilbutton.Visible = false
		end)
		
		window.InputBegan:Connect(function(input)
			if input.Position.Y < window.AbsolutePosition.Y + 41 and input.UserInputType == Enum.UserInputType.MouseButton2 then
				component:Expand()
			end
		end)
		
		children:GetPropertyChangedSignal('CanvasPosition'):Connect(function()
			if vape.ThreadFix then
				setthreadidentity(8)
			end
		
			divider.Visible = children.CanvasPosition.Y > 10 and children.Visible
		end)
		
		windowlist:GetPropertyChangedSignal('AbsoluteContentSize'):Connect(function()
			if vape.ThreadFix then
				setthreadidentity(8)
			end
		
			children.CanvasSize = UDim2.fromOffset(0, windowlist.AbsoluteContentSize.Y / scale.Scale)
			if component.Expanded then
				window.Size = UDim2.fromOffset(220, math.min(41 + windowlist.AbsoluteContentSize.Y / scale.Scale, 601))
			end
		end)
		
		component.Button = vape.Categories.Main:CreateGUIButton({
			Name = props.Name,
			Icon = props.Icon,
			Size = props.Size,
			Window = window
		})
		
		component.Object = window
		vape.Categories[props.Name] = component
		
		return component
	end,
	CategoryList = function(props, children, api)
		local component = {
			Expanded = false,
			List = {},
			ListEnabled = {},
			Objects = {},
			Options = {},
			Type = 'CategoryList'
		}
		props.Color = props.Color or Color3.fromRGB(5, 134, 105)
		
		local window = Instance.new('TextButton')
		window.AutoButtonColor = false
		window.BackgroundColor3 = uipallet.Main
		window.Name = props.Name..'CategoryList'
		window.Position = UDim2.fromOffset(240, 46)
		window.Size = UDim2.fromOffset(220, 45)
		window.Text = ''
		window.Visible = false
		window.Parent = clickgui
		addBlur(window)
		addCorner(window)
		addDragHandler(window)
		local icon = Instance.new('ImageLabel')
		icon.BackgroundTransparency = 1
		icon.Image = props.Icon
		icon.ImageColor3 = uipallet.Text
		icon.Name = 'Icon'
		icon.Size = props.Size
		icon.Position = props.Position or UDim2.fromOffset(12, (props.Size.X.Offset > 20 and 13 or 12))
		icon.Parent = window
		local title = Instance.new('TextLabel')
		title.BackgroundTransparency = 1
		title.FontFace = uipallet.Font
		title.Name = 'Title'
		title.Size = UDim2.new(1, -(props.Size.X.Offset > 20 and 44 or 36), 0, 20)
		title.Position = UDim2.fromOffset(math.abs(title.Size.X.Offset), 12)
		title.Text = props.Name
		title.TextColor3 = uipallet.Text
		title.TextSize = 13
		title.TextXAlignment = Enum.TextXAlignment.Left
		title.Parent = window
		local arrowbutton = Instance.new('TextButton')
		arrowbutton.BackgroundTransparency = 1
		arrowbutton.Name = 'Arrow'
		arrowbutton.Position = UDim2.new(1, -40, 0, 0)
		arrowbutton.Size = UDim2.fromOffset(40, 40)
		arrowbutton.Text = ''
		arrowbutton.Parent = window
		local arrow = Instance.new('ImageLabel')
		arrow.Name = 'Arrow'
		arrow.Size = UDim2.fromOffset(9, 4)
		arrow.Position = UDim2.fromOffset(15, 20)
		arrow.BackgroundTransparency = 1
		arrow.Image = getvapeasset('pistonware/assets/new/downexpand.png')
		arrow.ImageColor3 = Color3.fromRGB(140, 140, 140)
		arrow.Rotation = 180
		arrow.Parent = arrowbutton
		local children = Instance.new('ScrollingFrame')
		children.Name = 'Children'
		children.Size = UDim2.new(1, 0, 1, -45)
		children.Position = UDim2.fromOffset(0, 45)
		children.BackgroundTransparency = 1
		children.BorderSizePixel = 0
		children.Visible = false
		children.ScrollBarThickness = 2
		children.ScrollBarImageTransparency = 0.75
		children.CanvasSize = UDim2.new()
		children.Parent = window
		local childrentwo = Instance.new('Frame')
		childrentwo.BackgroundTransparency = 1
		childrentwo.BackgroundColor3 = color.Dark(uipallet.Main, 0.02)
		childrentwo.Visible = false
		childrentwo.Parent = children
		local settings = Instance.new('ImageButton')
		settings.AutoButtonColor = false
		settings.BackgroundTransparency = 1
		settings.Image = getvapeasset('pistonware/assets/new/settings.png')
		settings.ImageColor3 = color.Dark(uipallet.Text, 0.43)
		settings.Name = 'Settings'
		settings.Position = UDim2.new(1, -56, 0, 15)
		settings.Size = UDim2.fromOffset(14, 14)
		settings.Parent = window
		local divider = Instance.new('Frame')
		divider.BackgroundColor3 = Color3.new(1, 1, 1)
		divider.BackgroundTransparency = 0.928
		divider.BorderSizePixel = 0
		divider.Name = 'Divider'
		divider.Position = UDim2.fromOffset(0, 41)
		divider.Size = UDim2.new(1, 0, 0, 1)
		divider.Visible = false
		divider.Parent = window
		local stroke = Instance.new('UIStroke')
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.Color = Color3.fromRGB(85, 85, 85)
		stroke.Transparency = 0.8
		stroke.Parent = window
		local windowlist = Instance.new('UIListLayout')
		windowlist.HorizontalAlignment = Enum.HorizontalAlignment.Center
		windowlist.Padding = UDim.new(0, 4)
		windowlist.SortOrder = Enum.SortOrder.LayoutOrder
		windowlist.Parent = children
		local windowlisttwo = Instance.new('UIListLayout')
		windowlisttwo.HorizontalAlignment = Enum.HorizontalAlignment.Center
		windowlisttwo.SortOrder = Enum.SortOrder.LayoutOrder
		windowlisttwo.Parent = childrentwo
		local addbkg = Instance.new('Frame')
		addbkg.BackgroundColor3 = color.Light(uipallet.Main, 0.02)
		addbkg.Position = UDim2.fromOffset(10, 45)
		addbkg.Size = UDim2.fromOffset(200, 31)
		addbkg.Parent = children
		addCorner(addbkg)
		local addbox = addbkg:Clone()
		addbox.BackgroundColor3 = color.Dark(uipallet.Main, 0.02)
		addbox.Position = UDim2.fromOffset(1, 1)
		addbox.Size = UDim2.new(1, -2, 1, -2)
		addbox.Parent = addbkg
		local addvalue = Instance.new('TextBox')
		addvalue.BackgroundTransparency = 1
		addvalue.ClearTextOnFocus = false
		addvalue.FontFace = uipallet.Font
		addvalue.PlaceholderText = props.Placeholder or 'Add entry...'
		addvalue.PlaceholderColor3 = Color3.new(0.8, 0.8, 0.8)
		addvalue.Position = UDim2.fromOffset(10, 0)
		addvalue.Size = UDim2.new(1, -35, 1, 0)
		addvalue.Text = ''
		addvalue.TextColor3 = Color3.new(1, 1, 1)
		addvalue.TextSize = 13
		addvalue.TextXAlignment = Enum.TextXAlignment.Left
		addvalue.Parent = addbkg
		local addbutton = Instance.new('ImageButton')
		addbutton.BackgroundTransparency = 1
		addbutton.Image = getvapeasset('pistonware/assets/new/add.png')
		addbutton.ImageColor3 = props.Color
		addbutton.ImageTransparency = 0.3
		addbutton.Position = UDim2.new(1, -26, 0, 8)
		addbutton.Size = UDim2.fromOffset(16, 16)
		addbutton.Parent = addbkg
		local cursedpadding = Instance.new('Frame')
		cursedpadding.BackgroundTransparency = 1
		cursedpadding.Size = UDim2.fromOffset()
		cursedpadding.Parent = children
		props.Function = props.Function or function() end
		
		function component:CreateProfile(value, data)
			--[[ Names are the identity here: GetValue, ChangeValue and the profile file on disk all
			key off them, so two entries with the same name are two rows fighting over one file. ]]
			if type(value) ~= 'string' or value == '' or self:GetValue(value) then
				return
			end
		
			local profile = {
				Name = value
			}
		
			profile.Bind = components.Bind({
				Module = true,
				Cover = true
			}, nil, profile)
			profile.Bind.Object.Position = UDim2.new(1, -30, 0, 7)
			profile.Bind.Triggered:Connect(function(isPressed)
				if isPressed and vape.Profile ~= value then
					vape:Save(value)
					vape:Load(true)
					self:ChangeValue()
				end
			end)
		
			if data then
				profile.Bind:Load(data)
			end
		
			table.insert(self.List, profile)
		end
		
		function component:ChangeValue(value, skipGUI)
			if value then
				if props.Profiles then
					local index, profile = self:GetValue(value)
					if index then
						if value ~= 'default' then
							profile.Bind:Destroy()
							table.remove(self.List, index)
		
							if isfile('pistonware/profiles/'..value..vape.Place..'.txt') and delfile then
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
		
			props.Function()
			for _, obj in self.Objects do
				obj:Destroy()
			end
			table.clear(self.Objects)
			self.Selected = nil
		
			if vape.ThreadFix then
				setthreadidentity(8)
			end
		
			for _, name in self.List do
				if props.Profiles then
					local obj = Instance.new('TextButton')
					obj.Name = name.Name
					obj.Size = UDim2.fromOffset(200, 32)
					obj.BackgroundColor3 = color.Light(uipallet.Main, 0.02)
					obj.AutoButtonColor = false
					obj.Text = ''
					obj.Parent = children
					addCorner(obj)
					local stroke = Instance.new('UIStroke')
					stroke.Color = color.Light(uipallet.Main, 0.1)
					stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
					stroke.Enabled = false
					stroke.Parent = obj
					local label = Instance.new('TextLabel')
					label.Name = 'Title'
					label.Size = UDim2.new(1, -10, 1, 0)
					label.Position = UDim2.fromOffset(10, 0)
					label.BackgroundTransparency = 1
					label.Text = name.Name
					label.TextXAlignment = Enum.TextXAlignment.Left
					label.TextColor3 = color.Dark(uipallet.Text, 0.4)
					label.TextSize = 15
					label.FontFace = uipallet.Font
					label.Parent = obj
					local dotsbutton = Instance.new('TextButton')
					dotsbutton.BackgroundTransparency = 1
					dotsbutton.Name = 'Dots'
					dotsbutton.Position = UDim2.new(1, -25, 0, 0)
					dotsbutton.Size = UDim2.fromOffset(25, 32)
					dotsbutton.Text = ''
					dotsbutton.Parent = obj
					local dots = Instance.new('ImageLabel')
					dots.BackgroundTransparency = 1
					dots.Image = getvapeasset('pistonware/assets/new/settingdots.png')
					dots.ImageColor3 = color.Light(uipallet.Main, 0.37)
					dots.Name = 'Dots'
					dots.Position = UDim2.fromOffset(11, 9)
					dots.Size = UDim2.fromOffset(3, 16)
					dots.Parent = dotsbutton
					name.Bind:SetParent(obj)
					name.Enabled = name.Name == vape.Profile
		
					dotsbutton.MouseButton1Click:Connect(function()
						if not name.Enabled then
							component:ChangeValue(name.Name)
						end
					end)
		
					dotsbutton.MouseEnter:Connect(function()
						if not name.Enabled then
							dots.ImageColor3 = uipallet.Text
						end
					end)
		
					dotsbutton.MouseLeave:Connect(function()
						if not name.Enabled then
							dots.ImageColor3 = color.Light(uipallet.Main, 0.37)
						end
					end)
		
		
					obj.MouseButton1Click:Connect(function()
						vape:Save(name.Name)
						vape:Load(true)
						self:ChangeValue()
					end)
		
					obj.MouseEnter:Connect(function()
						name.Bind:SetVisible(true)
					end)
		
					obj.MouseLeave:Connect(function()
						name.Bind:SetVisible(false)
					end)
		
					if name.Enabled then
						self.Selected = obj
					else
						name.Bind:SetColor(color.Dark(uipallet.Text, 0.43))
					end
		
					table.insert(self.Objects, {
						Destroy = function()
							name.Bind:SetParent(nil)
							obj:Destroy()
						end
					})
				else
					local isEnabled = table.find(self.ListEnabled, name)
					local obj = Instance.new('TextButton')
					obj.Name = name
					obj.Size = UDim2.fromOffset(200, 31)
					obj.BackgroundColor3 = color.Light(uipallet.Main, 0.02)
					obj.AutoButtonColor = false
					obj.Text = ''
					obj.Parent = children
					addCorner(obj)
					local bkg = Instance.new('Frame')
					bkg.BackgroundColor3 = uipallet.Main
					bkg.Position = UDim2.fromOffset(1, 1)
					bkg.Size = UDim2.new(1, -2, 1, -2)
					bkg.Visible = false
					bkg.Parent = obj
					addCorner(bkg)
					local dot = Instance.new('Frame')
					dot.BackgroundColor3 = isEnabled and props.Color or color.Light(uipallet.Main, 0.37)
					dot.Position = UDim2.fromOffset(10, 12)
					dot.Size = UDim2.fromOffset(10, 11)
					dot.Parent = obj
					addCorner(dot, UDim.new(1, 0))
					local dotin = dot:Clone()
					dotin.BackgroundColor3 = isEnabled and props.Color or color.Light(uipallet.Main, 0.02)
					dotin.Position = UDim2.fromOffset(1, 1)
					dotin.Size = UDim2.fromOffset(8, 9)
					dotin.Parent = dot
					local label = Instance.new('TextLabel')
					label.BackgroundTransparency = 1
					label.FontFace = uipallet.Font
					label.Position = UDim2.fromOffset(30, 0)
					label.Size = UDim2.new(1, -30, 1, 0)
					label.Text = name
					label.TextColor3 = color.Dark(uipallet.Text, 0.16)
					label.TextSize = 15
					label.TextXAlignment = Enum.TextXAlignment.Left
					label.Parent = obj
					local close = Instance.new('ImageButton')
					close.AutoButtonColor = false
					close.BackgroundColor3 = Color3.new(1, 1, 1)
					close.BackgroundTransparency = 1
					close.Image = getvapeasset('pistonware/assets/new/closetiny.png')
					close.ImageColor3 = color.Light(uipallet.Text, 0.2)
					close.ImageTransparency = 0.5
					close.Position = UDim2.new(1, -27, 0, 8)
					close.Size = UDim2.fromOffset(18, 17)
					close.Parent = obj
					addCorner(close, UDim.new(1, 0))
		
					close.MouseEnter:Connect(function()
						close.ImageTransparency = 0.3
						tween:Tween(close, uipallet.Tween, {
							BackgroundTransparency = 0.6
						})
					end)
		
					close.MouseLeave:Connect(function()
						close.ImageTransparency = 0.5
						tween:Tween(close, uipallet.Tween, {
							BackgroundTransparency = 1
						})
					end)
		
					close.MouseButton1Click:Connect(function()
						component:ChangeValue(name)
					end)
		
					obj.MouseEnter:Connect(function()
						bkg.Visible = true
					end)
		
					obj.MouseLeave:Connect(function()
						bkg.Visible = false
					end)
		
					obj.MouseButton1Click:Connect(function()
						local index = table.find(self.ListEnabled, name)
						if index then
							table.remove(self.ListEnabled, index)
							dot.BackgroundColor3 = color.Light(uipallet.Main, 0.37)
							dotin.BackgroundColor3 = color.Light(uipallet.Main, 0.02)
						else
							table.insert(self.ListEnabled, name)
							dot.BackgroundColor3 = props.Color
							dotin.BackgroundColor3 = props.Color
						end
		
						props.Function()
					end)
		
					table.insert(self.Objects, obj)
				end
			end
		
			if not skipGUI then
				vape:UpdateGUI(vape.GUIColor.Hue, vape.GUIColor.Sat, vape.GUIColor.Value)
			end
		end
		
		function component:Color(hue, sat, val, isRainbow)
			for _, component in self.Options do
				if component.Color then
					component:Color(hue, sat, val, isRainbow)
				end
			end
		
			addbutton.ImageColor3 = isRainbow and Color3.fromHSV(vape:Color(hue % 1)) or Color3.fromHSV(hue, sat, val)
		
			if self.Selected then
				self.Selected.BackgroundColor3 = isRainbow and Color3.fromHSV(vape:Color(hue % 1)) or Color3.fromHSV(hue, sat, val)
				self.Selected.Title.TextColor3 = vape.GUIColor.Rainbow and Color3.new(0.19, 0.19, 0.19) or vape:TextColor(hue, sat, val)
				self.Selected.Dots.Dots.ImageColor3 = self.Selected.Title.TextColor3
				self.Selected.Bind.Icon.ImageColor3 = self.Selected.Title.TextColor3
				self.Selected.Bind.TextLabel.TextColor3 = self.Selected.Title.TextColor3
			end
		end
		
		function component:Expand()
			self.Expanded = not self.Expanded
			children.Visible = self.Expanded
			arrow.Rotation = self.Expanded and 0 or 180
			window.Size = UDim2.fromOffset(220, self.Expanded and math.min(51 + windowlist.AbsoluteContentSize.Y / scale.Scale, 611) or 45)
			divider.Visible = children.CanvasPosition.Y > 10 and children.Visible
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
		
			if props.Profiles then
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
						self:CreateProfile(profile.Name, profile.Bind)
					end
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
		
			if props.Profiles then
				local newList = {}
		
				for _, profile in self.List do
					local entry = {
						Name = profile.Name
					}
		
					profile.Bind:Save(entry)
					table.insert(newList, entry)
				end
		
				data[props.Name].List = newList
			end
		end
		
		bindComponents(component, childrentwo)
		
		addbutton.MouseEnter:Connect(function()
			addbutton.ImageTransparency = 0
		end)
		
		addbutton.MouseLeave:Connect(function()
			addbutton.ImageTransparency = 0.3
		end)
		
		addbutton.MouseButton1Click:Connect(function()
			if not table.find(component.List, addvalue.Text) then
				component:ChangeValue(addvalue.Text)
				addvalue.Text = ''
			end
		end)
		
		arrowbutton.MouseEnter:Connect(function()
			arrow.ImageColor3 = Color3.fromRGB(220, 220, 220)
		end)
		
		arrowbutton.MouseLeave:Connect(function()
			arrow.ImageColor3 = Color3.fromRGB(140, 140, 140)
		end)
		
		arrowbutton.MouseButton1Click:Connect(function()
			component:Expand()
		end)
		
		arrowbutton.MouseButton2Click:Connect(function()
			component:Expand()
		end)
		
		addvalue.FocusLost:Connect(function(enter)
			if enter and not table.find(component.List, addvalue.Text) then
				component:ChangeValue(addvalue.Text)
				addvalue.Text = ''
			end
		end)
		
		addvalue.MouseEnter:Connect(function()
			tween:Tween(addbkg, uipallet.Tween, {
				BackgroundColor3 = color.Light(uipallet.Main, 0.14)
			})
		end)
		
		addvalue.MouseLeave:Connect(function()
			tween:Tween(addbkg, uipallet.Tween, {
				BackgroundColor3 = color.Light(uipallet.Main, 0.02)
			})
		end)
		
		children:GetPropertyChangedSignal('CanvasPosition'):Connect(function()
			divider.Visible = children.CanvasPosition.Y > 10 and children.Visible
		end)
		
		settings.MouseEnter:Connect(function()
			settings.ImageColor3 = uipallet.Text
		end)
		
		settings.MouseLeave:Connect(function()
			settings.ImageColor3 = color.Light(uipallet.Main, 0.37)
		end)
		
		settings.MouseButton1Click:Connect(function()
			childrentwo.Visible = not childrentwo.Visible
		end)
		
		window.InputBegan:Connect(function(input)
			if input.Position.Y < window.AbsolutePosition.Y + 41 and input.UserInputType == Enum.UserInputType.MouseButton2 then
				component:Expand()
			end
		end)
		
		windowlist:GetPropertyChangedSignal('AbsoluteContentSize'):Connect(function()
			if vape.ThreadFix then
				setthreadidentity(8)
			end
		
			children.CanvasSize = UDim2.fromOffset(0, windowlist.AbsoluteContentSize.Y / scale.Scale)
			if component.Expanded then
				window.Size = UDim2.fromOffset(220, math.min(51 + windowlist.AbsoluteContentSize.Y / scale.Scale, 611))
			end
		end)
		
		windowlisttwo:GetPropertyChangedSignal('AbsoluteContentSize'):Connect(function()
			if vape.ThreadFix then
				setthreadidentity(8)
			end
		
			childrentwo.Size = UDim2.fromOffset(220, windowlisttwo.AbsoluteContentSize.Y / scale.Scale)
		end)
		
		component.Button = vape.Categories.Main:CreateGUIButton({
			Name = props.Name,
			Icon = props.CategoryIcon,
			Size = props.CategorySize,
			Window = window
		})
		
		component.Object = window
		vape.Categories[props.Name] = component
		
		return component
	end,
	ColorSlider = function(props, children, api)
		local component = {
			Type = 'ColorSlider',
			Hue = props.DefaultHue or 0.44,
			Sat = props.DefaultSat or 1,
			Value = props.DefaultValue or 1,
			Opacity = props.DefaultOpacity or 1,
			Rainbow = false,
			Index = 0
		}
		
		local function createExtraSlider(name, gradientColor)
			local colorslidercustom = Instance.new('TextButton')
			colorslidercustom.AutoButtonColor = false
			colorslidercustom.BackgroundColor3 = color.Dark(children.BackgroundColor3, props.Darker and 0.02 or 0)
			colorslidercustom.BorderSizePixel = 0
			colorslidercustom.Size = UDim2.new(1, 0, 0, 50)
			colorslidercustom.Text = ''
			colorslidercustom.Visible = false
			colorslidercustom.Parent = children
			local title = Instance.new('TextLabel')
			title.BackgroundTransparency = 1
			title.FontFace = uipallet.Font
			title.Position = UDim2.fromOffset(10, 2)
			title.Size = UDim2.fromOffset(60, 30)
			title.Text = name
			title.TextColor3 = color.Dark(uipallet.Text, 0.16)
			title.TextSize = 11
			title.TextXAlignment = Enum.TextXAlignment.Left
			title.Parent = colorslidercustom
			local holder = Instance.new('Frame')
			holder.BackgroundColor3 = Color3.new(1, 1, 1)
			holder.BorderSizePixel = 0
			holder.Name = 'Holder'
			holder.Position = UDim2.fromOffset(10, 37)
			holder.Size = UDim2.new(1, -20, 0, 2)
			holder.Parent = colorslidercustom
			local uigradient = Instance.new('UIGradient')
			uigradient.Color = gradientColor
			uigradient.Parent = holder
			local fill = Instance.new('Frame')
			fill.BackgroundTransparency = 1
			fill.Name = 'Fill'
			fill.Size = UDim2.fromScale(math.clamp(name == 'Saturation' and component.Sat or name == 'Vibrance' and component.Value or component.Opacity, 0.04, 0.96), 1)
			fill.Parent = holder
			local knobholder = Instance.new('Frame')
			knobholder.AnchorPoint = Vector2.new(0.5, 0.5)
			knobholder.BackgroundColor3 = colorslidercustom.BackgroundColor3
			knobholder.BorderSizePixel = 0
			knobholder.Position = UDim2.fromScale(1, 0.5)
			knobholder.Size = UDim2.fromOffset(24, 4)
			knobholder.Parent = fill
			local knob = Instance.new('Frame')
			knob.AnchorPoint = Vector2.new(0.5, 0.5)
			knob.BackgroundColor3 = uipallet.Text
			knob.Position = UDim2.fromScale(0.5, 0.5)
			knob.Size = UDim2.fromOffset(14, 14)
			knob.Parent = knobholder
			addCorner(knob, UDim.new(1, 0))
		
			colorslidercustom.InputBegan:Connect(function(input)
				if
					(input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch)
					and (input.Position.Y - colorslidercustom.AbsolutePosition.Y) > (20 * scale.Scale)
				then
					local releaseConnection
					local moveConnection = inputService.InputChanged:Connect(function(newInput)
						if newInput.UserInputType == (input.UserInputType == Enum.UserInputType.MouseButton1 and Enum.UserInputType.MouseMovement or Enum.UserInputType.Touch) then
							local newValue = math.clamp((newInput.Position.X - holder.AbsolutePosition.X) / holder.AbsoluteSize.X, 0, 1)
							component:SetValue(nil, name == 'Saturation' and newValue or nil, name == 'Vibrance' and newValue or nil, name == 'Opacity' and newValue or nil)
						end
					end)
		
					releaseConnection = input.Changed:Connect(function()
						if input.UserInputState == Enum.UserInputState.End then
							moveConnection:Disconnect()
							releaseConnection:Disconnect()
						end
					end)
				end
			end)
		
			colorslidercustom.MouseEnter:Connect(function()
				tween:Tween(knob, uipallet.Tween, {
					Size = UDim2.fromOffset(16, 16)
				})
			end)
		
			colorslidercustom.MouseLeave:Connect(function()
				tween:Tween(knob, uipallet.Tween, {
					Size = UDim2.fromOffset(14, 14)
				})
			end)
		
			return colorslidercustom
		end
		
		local colorslider = Instance.new('TextButton')
		colorslider.AutoButtonColor = false
		colorslider.BackgroundColor3 = color.Dark(children.BackgroundColor3, props.Darker and 0.02 or 0)
		colorslider.BorderSizePixel = 0
		colorslider.Size = UDim2.new(1, 0, 0, 50)
		colorslider.Text = ''
		colorslider.Visible = props.Visible == nil or props.Visible
		colorslider.Parent = children
		component.Object = colorslider
		addTooltip(colorslider, props.Tooltip)
		local title = Instance.new('TextLabel')
		title.BackgroundTransparency = 1
		title.FontFace = uipallet.Font
		title.Position = UDim2.fromOffset(10, 2)
		title.Size = UDim2.fromOffset(60, 30)
		title.Text = props.Name
		title.TextColor3 = color.Dark(uipallet.Text, 0.16)
		title.TextSize = 11
		title.TextXAlignment = Enum.TextXAlignment.Left
		title.Parent = colorslider
		local custombox = Instance.new('TextBox')
		custombox.BackgroundTransparency = 1
		custombox.FontFace = uipallet.Font
		custombox.Position = UDim2.new(1, -69, 0, 9)
		custombox.Size = UDim2.fromOffset(60, 15)
		custombox.Text = ''
		custombox.TextColor3 = color.Dark(uipallet.Text, 0.16)
		custombox.TextSize = 11
		custombox.TextXAlignment = Enum.TextXAlignment.Right
		custombox.Visible = false
		custombox.Parent = colorslider
		local holder = Instance.new('Frame')
		holder.BackgroundColor3 = Color3.new(1, 1, 1)
		holder.BorderSizePixel = 0
		holder.Position = UDim2.fromOffset(10, 39)
		holder.Size = UDim2.new(1, -20, 0, 2)
		holder.Parent = colorslider
		local rainbowTable = {}
		for i = 0, 1, 0.1 do
			table.insert(rainbowTable, ColorSequenceKeypoint.new(i, Color3.fromHSV(i, 1, 1)))
		end
		local uigradient = Instance.new('UIGradient')
		uigradient.Color = ColorSequence.new(rainbowTable)
		uigradient.Parent = holder
		local fill = Instance.new('Frame')
		fill.BackgroundTransparency = 1
		fill.Size = UDim2.fromScale(math.clamp(component.Hue, 0.04, 0.96), 1)
		fill.Parent = holder
		local knobholder = Instance.new('Frame')
		knobholder.AnchorPoint = Vector2.new(0.5, 0.5)
		knobholder.BackgroundColor3 = colorslider.BackgroundColor3
		knobholder.BorderSizePixel = 0
		knobholder.Position = UDim2.fromScale(1, 0.5)
		knobholder.Size = UDim2.fromOffset(24, 4)
		knobholder.Parent = fill
		local knob = Instance.new('Frame')
		knob.AnchorPoint = Vector2.new(0.5, 0.5)
		knob.BackgroundColor3 = uipallet.Text
		knob.Position = UDim2.fromScale(0.5, 0.5)
		knob.Size = UDim2.fromOffset(14, 14)
		knob.Parent = knobholder
		addCorner(knob, UDim.new(1, 0))
		local preview = Instance.new('ImageButton')
		preview.BackgroundTransparency = 1
		preview.Image = getvapeasset('pistonware/assets/new/colorpreview.png')
		preview.ImageColor3 = Color3.fromHSV(component.Hue, component.Sat, component.Value)
		preview.ImageTransparency = 1 - component.Opacity
		preview.Position = UDim2.new(1, -22, 0, 10)
		preview.Size = UDim2.fromOffset(12, 12)
		preview.Parent = colorslider
		local expand = Instance.new('TextButton')
		expand.BackgroundTransparency = 1
		expand.Position = UDim2.fromOffset(getfontbounds(title.Text, title.TextSize, title.FontFace).X + 11, 7)
		expand.Size = UDim2.fromOffset(17, 13)
		expand.Text = ''
		expand.Parent = colorslider
		local icon = Instance.new('ImageLabel')
		icon.BackgroundTransparency = 1
		icon.Image = getvapeasset('pistonware/assets/new/downexpandslider.png')
		icon.ImageColor3 = color.Dark(uipallet.Text, 0.43)
		icon.Position = UDim2.fromOffset(4, 4)
		icon.Size = UDim2.fromOffset(10, 5)
		icon.Parent = expand
		local rainbow = Instance.new('TextButton')
		rainbow.BackgroundTransparency = 1
		rainbow.Position = UDim2.new(1, -42, 0, 10)
		rainbow.Size = UDim2.fromOffset(12, 12)
		rainbow.Text = ''
		rainbow.Parent = colorslider
		local ring1 = Instance.new('ImageLabel')
		ring1.BackgroundTransparency = 1
		ring1.Image = getvapeasset('pistonware/assets/new/rainbow_1.png')
		ring1.ImageColor3 = color.Light(uipallet.Main, 0.37)
		ring1.Size = UDim2.fromOffset(12, 12)
		ring1.Parent = rainbow
		local ring2 = Instance.fromExisting(ring1)
		ring2.Image = getvapeasset('pistonware/assets/new/rainbow_2.png')
		ring2.Parent = rainbow
		local ring3 = Instance.fromExisting(ring1)
		ring3.Image = getvapeasset('pistonware/assets/new/rainbow_3.png')
		ring3.Parent = rainbow
		local ring4 = Instance.fromExisting(ring1)
		ring4.Image = getvapeasset('pistonware/assets/new/rainbow_4.png')
		ring4.Parent = rainbow
		props.Function = props.Function or function() end
		
		local satSlider = createExtraSlider('Saturation', ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromHSV(0, 0, component.Value)),
			ColorSequenceKeypoint.new(1, Color3.fromHSV(component.Hue, 1, component.Value))
		}))
		
		local vibSlider = createExtraSlider('Vibrance', ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromHSV(0, 0, 0)),
			ColorSequenceKeypoint.new(1, Color3.fromHSV(component.Hue, component.Sat, 1))
		}))
		
		local opSlider = createExtraSlider('Opacity', ColorSequence.new({
			ColorSequenceKeypoint.new(0, color.Dark(uipallet.Main, 0.02)),
			ColorSequenceKeypoint.new(1, Color3.fromHSV(component.Hue, component.Sat, component.Value))
		}))
		
		function component:Load(data)
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
				Rainbow = self.Rainbow
			}
		end
		
		function component:SetValue(h, s, v, o)
			self.Hue = h or self.Hue
			self.Sat = s or self.Sat
			self.Value = v or self.Value
			self.Opacity = o or self.Opacity
			preview.ImageColor3 = Color3.fromHSV(self.Hue, self.Sat, self.Value)
			preview.ImageTransparency = 1 - self.Opacity
		
			satSlider.Holder.UIGradient.Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.fromHSV(0, 0, self.Value)),
				ColorSequenceKeypoint.new(1, Color3.fromHSV(self.Hue, 1, self.Value))
			})
		
			vibSlider.Holder.UIGradient.Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.fromHSV(0, 0, 0)),
				ColorSequenceKeypoint.new(1, Color3.fromHSV(self.Hue, self.Sat, 1))
			})
		
			opSlider.Holder.UIGradient.Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, color.Dark(uipallet.Main, 0.02)),
				ColorSequenceKeypoint.new(1, Color3.fromHSV(self.Hue, self.Sat, self.Value))
			})
		
			if self.Rainbow then
				fill.Size = UDim2.fromScale(math.clamp(self.Hue, 0.04, 0.96), 1)
			else
				tween:Tween(fill, uipallet.Tween, {
					Size = UDim2.fromScale(math.clamp(self.Hue, 0.04, 0.96), 1)
				})
			end
		
			if s then
				tween:Tween(satSlider.Holder.Fill, uipallet.Tween, {
					Size = UDim2.fromScale(math.clamp(self.Sat, 0.04, 0.96), 1)
				})
			end
		
			if v then
				tween:Tween(vibSlider.Holder.Fill, uipallet.Tween, {
					Size = UDim2.fromScale(math.clamp(self.Value, 0.04, 0.96), 1)
				})
			end
		
			if o then
				tween:Tween(opSlider.Holder.Fill, uipallet.Tween, {
					Size = UDim2.fromScale(math.clamp(self.Opacity, 0.04, 0.96), 1)
				})
			end
		
			props.Function(self.Hue, self.Sat, self.Value, self.Opacity)
		end
		
		function component:Toggle()
			self.Rainbow = not self.Rainbow
		
			if self.Rainbow then
				table.insert(vape.RainbowSliders, self)
		
				ring1.ImageColor3 = Color3.fromRGB(5, 127, 100)
				task.delay(0.1, function()
					if not self.Rainbow then return end
					ring2.ImageColor3 = Color3.fromRGB(228, 125, 43)
					task.delay(0.1, function()
						if not self.Rainbow then return end
						ring3.ImageColor3 = Color3.fromRGB(225, 46, 52)
					end)
				end)
			else
				local index = table.find(vape.RainbowSliders, self)
				if index then
					table.remove(vape.RainbowSliders, index)
				end
		
				ring3.ImageColor3 = color.Light(uipallet.Main, 0.37)
				task.delay(0.1, function()
					if self.Rainbow then return end
					ring2.ImageColor3 = color.Light(uipallet.Main, 0.37)
					task.delay(0.1, function()
						if self.Rainbow then return end
						ring1.ImageColor3 = color.Light(uipallet.Main, 0.37)
					end)
				end)
			end
		end
		
		preview.MouseButton1Click:Connect(function()
			preview.Visible = false
			custombox.Visible = true
			custombox:CaptureFocus()
		
			local text = Color3.fromHSV(component.Hue, component.Sat, component.Value)
			custombox.Text = math.round(text.R * 255)..', '..math.round(text.G * 255)..', '..math.round(text.B * 255)
		end)
		
		local doubleClick = os.clock()
		colorslider.InputBegan:Connect(function(input)
			if
				(input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch)
				and (input.Position.Y - colorslider.AbsolutePosition.Y) > (20 * scale.Scale)
			then
				local releaseConnection
				local moveConnection = inputService.InputChanged:Connect(function(newInput)
					if newInput.UserInputType == (input.UserInputType == Enum.UserInputType.MouseButton1 and Enum.UserInputType.MouseMovement or Enum.UserInputType.Touch) then
						component:SetValue(math.clamp((newInput.Position.X - holder.AbsolutePosition.X) / holder.AbsoluteSize.X, 0, 1))
					end
				end)
		
				releaseConnection = input.Changed:Connect(function()
					if input.UserInputState == Enum.UserInputState.End then
						moveConnection:Disconnect()
						releaseConnection:Disconnect()
					end
				end)
		
				if doubleClick > os.clock() then
					component:Toggle()
				else
					component:SetValue(math.clamp((input.Position.X - holder.AbsolutePosition.X) / holder.AbsoluteSize.X, 0, 1))
				end
		
				doubleClick = os.clock() + 0.3
			end
		end)
		
		colorslider.MouseEnter:Connect(function()
			tween:Tween(knob, uipallet.Tween, {
				Size = UDim2.fromOffset(16, 16)
			})
		end)
		
		colorslider.MouseLeave:Connect(function()
			tween:Tween(knob, uipallet.Tween, {
				Size = UDim2.fromOffset(14, 14)
			})
		end)
		
		colorslider:GetPropertyChangedSignal('Visible'):Connect(function()
			satSlider.Visible = icon.Rotation == 180 and colorslider.Visible
			vibSlider.Visible = satSlider.Visible
			opSlider.Visible = satSlider.Visible
		end)
		
		expand.MouseEnter:Connect(function()
			icon.ImageColor3 = color.Dark(uipallet.Text, 0.16)
		end)
		
		expand.MouseLeave:Connect(function()
			icon.ImageColor3 = color.Dark(uipallet.Text, 0.43)
		end)
		
		expand.MouseButton1Click:Connect(function()
			satSlider.Visible = not satSlider.Visible
			vibSlider.Visible = satSlider.Visible
			opSlider.Visible = satSlider.Visible
			icon.Rotation = satSlider.Visible and 180 or 0
		end)
		
		rainbow.MouseButton1Click:Connect(function()
			component:Toggle()
		end)
		
		custombox.FocusLost:Connect(function(enter)
			preview.Visible = true
			custombox.Visible = false
		
			if enter then
				local success, parsed = pcall(function()
					local commas = custombox.Text:split(',')
					--[[ Use custombox, not undeclared valuebox; otherwise hex color input fails silently. ]]
					return tonumber(commas[1]) and Color3.fromRGB(tonumber(commas[1]), tonumber(commas[2]), tonumber(commas[3])) or Color3.fromHex(custombox.Text)
				end)
		
				if success then
					if component.Rainbow then
						component:Toggle()
					end
		
					component:SetValue(parsed:ToHSV())
				end
			end
		end)
		
		api.Options[props.Name] = component
		
		return component
	end,
	Divider = function(props, children, api)
		local divider = Instance.new('Frame')
		divider.Size = UDim2.new(1, 0, 0, 1)
		divider.BackgroundColor3 = color.Light(uipallet.Main, 0.02)
		divider.BorderSizePixel = 0
		divider.Parent = children
		
		if props and props.Text then
			local label = Instance.new('TextLabel')
			label.Size = UDim2.fromOffset(218, 27)
			label.BackgroundTransparency = 1
			label.Text = '          '..props.Text:upper()
			label.TextXAlignment = Enum.TextXAlignment.Left
			label.TextColor3 = color.Dark(uipallet.Text, 0.43)
			label.TextSize = 9
			label.FontFace = uipallet.Font
			label.Parent = children
			divider.BackgroundTransparency = 1
			--[[ divider.Position = UDim2.fromOffset(0, 26) ]]
			divider.Parent = label
		end
	end,
	Dropdown = function(props, children, api)
		local component = {
			Index = 0,
			Type = 'Dropdown',
			Value = props.List[1] or 'None'
		}
		
		local dropdown = Instance.new('TextButton')
		dropdown.AutoButtonColor = false
		dropdown.BackgroundColor3 = color.Dark(children.BackgroundColor3, props.Darker and 0.02 or 0)
		dropdown.BorderSizePixel = 0
		dropdown.Size = UDim2.new(1, 0, 0, 40)
		dropdown.Text = ''
		dropdown.Visible = props.Visible == nil or props.Visible
		dropdown.Parent = children
		component.Object = dropdown
		addTooltip(dropdown, props.Tooltip or props.Name)
		local holder = Instance.new('Frame')
		holder.BackgroundColor3 = color.Light(uipallet.Main, 0.034)
		holder.Position = UDim2.fromOffset(10, 4)
		holder.Size = UDim2.new(1, -20, 1, -11)
		holder.Parent = dropdown
		addCorner(holder, UDim.new(0, 6))
		local button = Instance.new('TextButton')
		button.AutoButtonColor = false
		button.BackgroundColor3 = uipallet.Main
		button.Position = UDim2.fromOffset(1, 1)
		button.Size = UDim2.new(1, -2, 1, -2)
		button.Text = ''
		button.Parent = holder
		local title = Instance.new('TextLabel')
		title.BackgroundTransparency = 1
		title.FontFace = uipallet.Font
		title.Size = UDim2.new(1, 0, 0, 29)
		title.Text = '         '..props.Name..' - '..component.Value
		title.TextColor3 = color.Dark(uipallet.Text, 0.16)
		title.TextSize = 13
		title.TextTruncate = Enum.TextTruncate.AtEnd
		title.TextXAlignment = Enum.TextXAlignment.Left
		title.Parent = button
		addCorner(button, UDim.new(0, 6))
		local arrow = Instance.new('ImageLabel')
		arrow.BackgroundTransparency = 1
		arrow.Image = getvapeasset('pistonware/assets/new/expandarrow.png')
		arrow.ImageColor3 = Color3.fromRGB(140, 140, 140)
		arrow.Position = UDim2.new(1, -17, 0, 11)
		arrow.Rotation = 90
		arrow.Size = UDim2.fromOffset(4, 8)
		arrow.Parent = button
		props.Function = props.Function or function() end
		local dropdownchildren
		
		function component:Change(list)
			props.List = list or {}
			if not table.find(props.List, self.Value) then
				self:SetValue(self.Value)
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
			title.Text = '         '..props.Name..' - '..self.Value
		
			if dropdownchildren then
				arrow.Rotation = 90
				dropdownchildren:Destroy()
				dropdownchildren = nil
				dropdown.Size = UDim2.new(1, 0, 0, 40)
			end
		
			props.Function(self.Value, isClick)
		end
		
		button.MouseButton1Click:Connect(function()
			if not dropdownchildren then
				arrow.Rotation = 270
				dropdown.Size = UDim2.new(1, 0, 0, 43 + (#props.List - 1) * 26)
				dropdownchildren = Instance.new('Frame')
				dropdownchildren.BackgroundTransparency = 1
				dropdownchildren.Position = UDim2.fromOffset(0, 27)
				dropdownchildren.Size = UDim2.new(1, 0, 0, (#props.List - 1) * 26)
				dropdownchildren.Parent = button
		
				local index = 0
				for _, v in props.List do
					if v == component.Value then continue end
					local entry = Instance.new('TextButton')
					entry.AutoButtonColor = false
					entry.BackgroundColor3 = uipallet.Main
					entry.BorderSizePixel = 0
					entry.FontFace = uipallet.Font
					entry.Position = UDim2.fromOffset(0, index * 26)
					entry.Size = UDim2.new(1, 0, 0, 26)
					entry.Text = '         '..v
					entry.TextColor3 = color.Dark(uipallet.Text, 0.16)
					entry.TextSize = 13
					entry.TextTruncate = Enum.TextTruncate.AtEnd
					entry.TextXAlignment = Enum.TextXAlignment.Left
					entry.Parent = dropdownchildren
		
					entry.MouseEnter:Connect(function()
						entry.BackgroundColor3 = color.Light(uipallet.Main, 0.02)
						entry.TextColor3 = uipallet.Text
					end)
		
					entry.MouseLeave:Connect(function()
						entry.BackgroundColor3 = uipallet.Main
						entry.TextColor3 = color.Dark(uipallet.Text, 0.16)
					end)
		
					entry.MouseButton1Click:Connect(function()
						component:SetValue(v, true)
					end)
		
					index += 1
				end
			else
				component:SetValue(component.Value, true)
			end
		end)
		
		dropdown.MouseEnter:Connect(function()
			tween:Tween(holder, uipallet.Tween, {
				BackgroundColor3 = color.Light(uipallet.Main, 0.0875)
			})
		end)
		
		dropdown.MouseLeave:Connect(function()
			tween:Tween(holder, uipallet.Tween, {
				BackgroundColor3 = color.Light(uipallet.Main, 0.034)
			})
		end)
		
		api.Options[props.Name] = component
		
		return component
	end,
	Font = function(props, children, api)
		local fonts = {
			props.Default,
			'Custom'
		}
		
		for _, v in Enum.Font:GetEnumItems() do
			if not table.find(fonts, v.Name) then
				table.insert(fonts, v.Name)
			end
		end
		
		local component = {
			Value = Font.fromEnum(Enum.Font[fonts[1]])
		}
		local fontdropdown
		local fontbox
		props.Function = props.Function or function() end
		
		fontdropdown = components.Dropdown({
			Name = props.Name,
			List = fonts,
			Function = function(val)
				fontbox.Object.Visible = val == 'Custom' and fontdropdown.Object.Visible
				if val ~= 'Custom' then
					component.Value = Font.fromEnum(Enum.Font[val])
					props.Function(component.Value)
				else
					pcall(function()
						component.Value = Font.fromId(tonumber(fontbox.Value))
					end)
		
					props.Function(component.Value)
				end
			end,
			Darker = props.Darker,
			Visible = props.Visible
		}, children, api)
		component.Object = fontdropdown.Object
		
		fontbox = components.TextBox({
			Name = props.Name..' Asset',
			Placeholder = 'font (rbxasset)',
			Function = function()
				if fontdropdown.Value == 'Custom' then
					pcall(function()
						component.Value = Font.fromId(tonumber(fontbox.Value))
					end)
		
					props.Function(component.Value)
				end
			end,
			Visible = false,
			Darker = true
		}, children, api)
		
		fontdropdown.Object:GetPropertyChangedSignal('Visible'):Connect(function()
			fontbox.Object.Visible = fontdropdown.Object.Visible and fontdropdown.Value == 'Custom'
		end)
		
		return component
	end,
	GUI = function(props, children, api)
		local component = {
			Buttons = {},
			Type = 'MainWindow'
		}
		
		local window = Instance.new('TextButton')
		window.AutoButtonColor = false
		window.BackgroundColor3 = color.Dark(uipallet.Main, 0.02)
		window.Name = 'GUICategory'
		window.Position = UDim2.fromOffset(6, 60)
		window.Text = ''
		window.Parent = clickgui
		component.Object = window
		addBlur(window)
		addCorner(window)
		addDragHandler(window)
		local logo = Instance.new('ImageLabel')
		logo.BackgroundTransparency = 1
		logo.Image = getvapeasset('pistonware/assets/new/vapelogomini.png')
		logo.ImageColor3 = select(3, uipallet.Main:ToHSV()) > 0.5 and uipallet.Text or Color3.new(1, 1, 1)
		logo.Name = 'VapeLogo'
		logo.Position = UDim2.fromOffset(12, 11)
		logo.Size = UDim2.fromOffset(55, 16)
		logo.Parent = window
		local v4logo = Instance.new('ImageLabel')
		v4logo.BackgroundTransparency = 1
		v4logo.Image = getvapeasset('pistonware/assets/new/v4mini.png')
		v4logo.Name = 'V4Logo'
		v4logo.Position = UDim2.new(1, -1, 0, 0)
		v4logo.Size = UDim2.fromOffset(23, 16)
		v4logo.Parent = logo
		local children = Instance.new('Frame')
		children.BackgroundTransparency = 1
		children.Position = UDim2.fromOffset(0, 37)
		children.Size = UDim2.new(1, 0, 1, -33)
		children.Parent = window
		local windowlist = Instance.new('UIListLayout')
		windowlist.HorizontalAlignment = Enum.HorizontalAlignment.Center
		windowlist.SortOrder = Enum.SortOrder.LayoutOrder
		windowlist.Parent = children
		local settingsbutton = Instance.new('TextButton')
		settingsbutton.BackgroundTransparency = 1
		settingsbutton.Position = UDim2.new(1, -40, 0, 0)
		settingsbutton.Size = UDim2.fromOffset(40, 40)
		settingsbutton.Text = ''
		settingsbutton.Parent = window
		addTooltip(settingsbutton, 'Open settings')
		local settingsicon = Instance.new('ImageLabel')
		settingsicon.BackgroundTransparency = 1
		settingsicon.Image = getvapeasset('pistonware/assets/new/settings.png')
		settingsicon.ImageColor3 = color.Light(uipallet.Main, 0.37)
		settingsicon.Position = UDim2.fromOffset(15, 12)
		settingsicon.Size = UDim2.fromOffset(14, 14)
		settingsicon.Parent = settingsbutton
		local discord = Instance.new('ImageButton')
		discord.BackgroundTransparency = 1
		discord.Image = getvapeasset('pistonware/assets/new/discord.png', true)
		discord.Position = UDim2.new(1, -56, 0, 11)
		discord.Size = UDim2.fromOffset(16, 16)
		discord.Parent = window
		addTooltip(discord, 'Join discord')
		local stroke = Instance.new('UIStroke')
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.Color = Color3.fromRGB(85, 85, 85)
		stroke.Transparency = 0.8
		stroke.Parent = window
		local settingspane = components.SettingsPane({
			Name = 'Settings',
			Main = true
		}, window, component)
		component.Settings = settingspane
		
		function component:Color(hue, sat, val, isRainbow)
			v4logo.ImageColor3 = Color3.fromHSV(hue, sat, val)
		
			for _, button in self.Buttons do
				if button.Enabled then
					button.Object.TextColor3 = isRainbow and Color3.fromHSV(vape:Color((hue - (button.Index * 0.025)) % 1)) or Color3.fromHSV(hue, sat, val)
		
					if button.Icon then
						button.Icon.ImageColor3 = button.Object.TextColor3
					end
				end
			end
		end
		
		function component:Load(data)
			for name, paneData in data.Settings do
				local pane = vape.Settings[name]
				if pane then
					pane:Load(paneData)
				end
			end
		
			if data.Position then
				window.Position = UDim2.fromOffset(data.Position.X, data.Position.Y)
			end
		end
		
		function component:Save(data)
			data.Main = {
				Position = {
					X = window.Position.X.Offset,
					Y = window.Position.Y.Offset
				},
				Settings = {}
			}
		
			for name, pane in vape.Settings do
				pane:Save(data.Main.Settings)
			end
		end
		
		bindComponents(component, children)
		
		discord.MouseButton1Click:Connect(function()
			task.spawn(function()
				local body = httpService:JSONEncode({
					nonce = httpService:GenerateGUID(false),
					args = {
						invite = {code = 'VZEQJxMSnG'},
						code = 'VZEQJxMSnG'
					},
					cmd = 'INVITE_BROWSER'
				})
		
				for i = 1, 14 do
					task.spawn(function()
						pcall(function()
							request({
								Method = 'POST',
								Url = 'http://127.0.0.1:64'..(53 + i)..'/rpc?v=1',
								Headers = {
									['Content-Type'] = 'application/json',
									Origin = 'https://discord.com'
								},
								Body = body
							})
						end)
					end)
				end
			end)
		
			task.spawn(function()
				tooltip.Text = 'Copied!'
				setclipboard('https://discord.gg/VZEQJxMSnG')
			end)
		end)
		
		settingsbutton.MouseEnter:Connect(function()
			settingsicon.ImageColor3 = uipallet.Text
		end)
		
		settingsbutton.MouseLeave:Connect(function()
			settingsicon.ImageColor3 = color.Light(uipallet.Main, 0.37)
		end)
		
		settingsbutton.MouseButton1Click:Connect(function()
			settingspane.Object.Visible = true
		end)
		
		windowlist:GetPropertyChangedSignal('AbsoluteContentSize'):Connect(function()
			if vape.ThreadFix then
				setthreadidentity(8)
			end
		
			window.Size = UDim2.fromOffset(220, 42 + windowlist.AbsoluteContentSize.Y / scale.Scale)
			--[[
				A fixed number of hair spaces, NOT one scaled by scale.Scale.

				This is how far the label sits from the icon beside it: the row's text is indented by
				repeating U+200A, so the count IS the gap. Multiplying it by the UIScale looked like it
				was compensating for something and did the opposite -- the whole GUI already lives under
				that UIScale, so the spaces shrink along with the icon and the row on their own. Scaling
				the count as well applied it twice.

				It also truncates. string.rep takes an integer, so 39 * 0.4 is 15 spaces and not 15.6 --
				on a phone the label jumped left into the icon it was meant to clear, and moved again
				every time the viewport changed. On desktop scale is 1 and none of this showed.
			]]
			for _, button in component.Buttons do
				if button.Icon then
					button.Object.Text = string.rep(' ', 39)..button.Name
				end
			end
		end)
		
		vape.Categories.Main = component
		
		return component
	end,
	GUIButton = function(props, children, api)
		local component = {
			Enabled = false,
			Index = getTableSize(api.Buttons),
			Name = props.Name
		}
		
		local button = Instance.new('TextButton')
		button.AutoButtonColor = false
		button.BackgroundColor3 = uipallet.Main
		button.BorderSizePixel = 0
		button.FontFace = uipallet.Font
		button.Name = props.Name
		button.Size = UDim2.fromOffset(220, 40)
		button.Text = (props.Icon and string.rep(' ', 39) or props.Window and string.rep(' ', 17) or string.rep(' ', 10))..props.Name
		button.TextColor3 = color.Dark(uipallet.Text, 0.16)
		button.TextSize = 14
		button.TextXAlignment = Enum.TextXAlignment.Left
		button.Parent = children
		component.Object = button
		
		local icon
		if props.Icon then
			icon = Instance.new('ImageLabel')
			icon.BackgroundTransparency = 1
			icon.Image = props.Icon
			icon.ImageColor3 = color.Dark(uipallet.Text, 0.16)
			icon.Position = UDim2.fromOffset(16, 13)
			icon.Size = props.Size
			icon.Parent = button
			component.Icon = icon
		end
		
		if props.Name == 'Profiles' then
			local label = Instance.new('TextLabel')
			label.AnchorPoint = Vector2.new(1, 0)
			label.BackgroundColor3 = color.Light(uipallet.Main, 0.04)
			label.FontFace = uipallet.Font
			label.Position = UDim2.new(1, -36, 0, 8)
			label.Size = UDim2.fromOffset(53, 24)
			label.Text = 'default'
			label.TextColor3 = color.Dark(uipallet.Text, 0.29)
			label.TextSize = 12
			label.Parent = button
			addCorner(label)
			vape.ProfileLabel = label
		end
		
		local arrow = Instance.new('ImageLabel')
		arrow.BackgroundTransparency = 1
		arrow.Image = getvapeasset('pistonware/assets/new/expandarrow.png')
		arrow.ImageColor3 = color.Light(uipallet.Main, 0.37)
		arrow.Name = 'Arrow'
		arrow.Position = UDim2.new(1, -20, 0, 16)
		arrow.Size = UDim2.fromOffset(4, 8)
		arrow.Parent = button
		
		function component:Destroy()
			button:Destroy()
			button:ClearAllChildren()
		end
		
		function component:Toggle()
			if props.Window then
				self.Enabled = not self.Enabled
				tween:Tween(arrow, uipallet.Tween, {
					Position = UDim2.new(1, self.Enabled and -14 or -20, 0, 16)
				})
		
				button.TextColor3 = self.Enabled and Color3.fromHSV(vape.GUIColor.Hue, vape.GUIColor.Sat, vape.GUIColor.Value) or uipallet.Text
				if icon then
					icon.ImageColor3 = button.TextColor3
				end
		
				button.BackgroundColor3 = color.Light(uipallet.Main, 0.02)
				props.Window.Visible = self.Enabled
			else
				props.Function()
			end
		end
		
		-- `icon`, not `buttonicon` -- that name does not exist here, so the guard was
		-- always false and a category button's icon stayed dim while the label beside it
		-- lit up on hover. Toggle() a few lines above already uses the right local.
		button.MouseEnter:Connect(function()
			if not component.Enabled then
				button.TextColor3 = uipallet.Text
				if icon then
					icon.ImageColor3 = uipallet.Text
				end

				button.BackgroundColor3 = color.Light(uipallet.Main, 0.02)
			end
		end)

		button.MouseLeave:Connect(function()
			if not component.Enabled then
				button.TextColor3 = color.Dark(uipallet.Text, 0.16)
				if icon then
					icon.ImageColor3 = color.Dark(uipallet.Text, 0.16)
				end

				button.BackgroundColor3 = uipallet.Main
			end
		end)
		
		button.MouseButton1Click:Connect(function()
			component:Toggle()
		end)
		
		api.Buttons[props.Name] = component
		
		return component
	end,
	GUISlider = function(props, children, api)
		local component = {
			CustomColor = false,
			Hue = 0.46,
			Notch = 4,
			Rainbow = false,
			Sat = 0.96,
			Type = 'GUISlider',
			Value = 0.52
		}
		local colors = {
			Color3.fromRGB(250, 50, 56),
			Color3.fromRGB(242, 99, 33),
			Color3.fromRGB(252, 179, 22),
			Color3.fromRGB(5, 133, 104),
			Color3.fromRGB(47, 122, 229),
			Color3.fromRGB(126, 84, 217),
			Color3.fromRGB(232, 96, 152)
		}
		local colorPositions = {
			4,
			33,
			62,
			90,
			119,
			148,
			177
		}
		
		local function createSlider(name, gradientColor)
			local slider = Instance.new('TextButton')
			slider.Name = props.Name..'Slider'..name
			slider.Size = UDim2.fromOffset(220, 50)
			slider.BackgroundColor3 = color.Dark(uipallet.Main, 0.02)
			slider.BorderSizePixel = 0
			slider.AutoButtonColor = false
			slider.Visible = false
			slider.Text = ''
			slider.Parent = children
			local title = Instance.new('TextLabel')
			title.BackgroundTransparency = 1
			title.FontFace = uipallet.Font
			title.Position = UDim2.fromOffset(10, 2)
			title.Size = UDim2.fromOffset(60, 30)
			title.Text = name
			title.TextColor3 = color.Dark(uipallet.Text, 0.16)
			title.TextSize = 11
			title.TextXAlignment = Enum.TextXAlignment.Left
			title.Parent = slider
			local holder = Instance.new('Frame')
			holder.BackgroundColor3 = Color3.new(1, 1, 1)
			holder.BorderSizePixel = 0
			holder.Name = 'Holder'
			holder.Position = UDim2.fromOffset(10, 37)
			holder.Size = UDim2.new(1, -20, 0, 2)
			holder.Parent = slider
			local uigradient = Instance.new('UIGradient')
			uigradient.Color = gradientColor
			uigradient.Parent = holder
			local fill = Instance.new('Frame')
			fill.BackgroundTransparency = 1
			fill.Name = 'Fill'
			fill.Size = UDim2.fromScale(math.clamp(1, 0.04, 0.96), 1)
			fill.Parent = holder
			local knobholder = Instance.new('Frame')
			knobholder.AnchorPoint = Vector2.new(0.5, 0.5)
			knobholder.BackgroundColor3 = slider.BackgroundColor3
			knobholder.BorderSizePixel = 0
			knobholder.Position = UDim2.fromScale(1, 0.5)
			knobholder.Size = UDim2.fromOffset(24, 4)
			knobholder.Parent = fill
			local knob = Instance.new('Frame')
			knob.AnchorPoint = Vector2.new(0.5, 0.5)
			knob.BackgroundColor3 = uipallet.Text
			knob.Position = UDim2.fromScale(0.5, 0.5)
			knob.Size = UDim2.fromOffset(14, 14)
			knob.Parent = knobholder
			addCorner(knob, UDim.new(1, 0))
		
			if name == 'Custom color' then
				local reset = Instance.new('TextButton')
				reset.BackgroundTransparency = 1
				reset.FontFace = uipallet.Font
				reset.Position = UDim2.new(1, -52, 0, 5)
				reset.Size = UDim2.fromOffset(45, 20)
				reset.Text = 'RESET'
				reset.TextColor3 = color.Dark(uipallet.Text, 0.16)
				reset.TextSize = 11
				reset.Parent = slider
		
				reset.MouseButton1Click:Connect(function()
					component:SetValue(nil, nil, nil, 4)
				end)
			end
		
			slider.InputBegan:Connect(function(input)
				if
					(input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch)
					and (input.Position.Y - slider.AbsolutePosition.Y) > (20 * scale.Scale)
				then
					local releaseConnection
					local moveConnection = inputService.InputChanged:Connect(function(newInput)
						if newInput.UserInputType == (input.UserInputType == Enum.UserInputType.MouseButton1 and Enum.UserInputType.MouseMovement or Enum.UserInputType.Touch) then
							local value = math.clamp((newInput.Position.X - holder.AbsolutePosition.X) / holder.AbsoluteSize.X, 0, 1)
							component:SetValue(
								name == 'Custom color' and value or nil,
								name == 'Saturation' and value or nil,
								name == 'Vibrance' and value or nil,
								name == 'Opacity' and value or nil
							)
						end
					end)
		
					releaseConnection = input.Changed:Connect(function()
						if input.UserInputState == Enum.UserInputState.End then
							moveConnection:Disconnect()
							releaseConnection:Disconnect()
						end
					end)
				end
			end)
		
			slider.MouseEnter:Connect(function()
				tween:Tween(knob, uipallet.Tween, {
					Size = UDim2.fromOffset(16, 16)
				})
			end)
		
			slider.MouseLeave:Connect(function()
				tween:Tween(knob, uipallet.Tween, {
					Size = UDim2.fromOffset(14, 14)
				})
			end)
		
			return slider
		end
		
		local slider = Instance.new('TextButton')
		slider.AutoButtonColor = false
		slider.BackgroundTransparency = 1
		slider.Name = props.Name..'Slider'
		slider.Size = UDim2.fromOffset(220, 50)
		slider.Text = ''
		slider.Parent = children
		component.Object = slider
		local title = Instance.new('TextLabel')
		title.BackgroundTransparency = 1
		title.FontFace = uipallet.Font
		title.Name = 'Title'
		title.Position = UDim2.fromOffset(10, 2)
		title.Size = UDim2.fromOffset(60, 30)
		title.Text = props.Name
		title.TextColor3 = color.Dark(uipallet.Text, 0.16)
		title.TextSize = 11
		title.TextXAlignment = Enum.TextXAlignment.Left
		title.Parent = slider
		local holder = Instance.new('Frame')
		holder.BackgroundTransparency = 1
		holder.BorderSizePixel = 0
		holder.Name = 'Slider'
		holder.Position = UDim2.fromOffset(10, 37)
		holder.Size = UDim2.fromOffset(200, 2)
		holder.Parent = slider
		local colorXPos = 0
		for index, colorValue in colors do
			local colorframe = Instance.new('Frame')
			colorframe.BackgroundColor3 = colorValue
			colorframe.BorderSizePixel = 0
			colorframe.Position = UDim2.fromOffset(colorXPos, 0)
			colorframe.Size = UDim2.fromOffset(27 + (((index + 1) % 2) == 0 and 1 or 0), 2)
			colorframe.Parent = holder
			colorXPos += (colorframe.Size.X.Offset + 1)
		end
		local preview = Instance.new('ImageButton')
		preview.BackgroundTransparency = 1
		preview.Image = getvapeasset('pistonware/assets/new/colorpreview.png')
		preview.ImageColor3 = Color3.fromHSV(component.Hue, component.Sat, component.Value)
		preview.Position = UDim2.new(1, -22, 0, 10)
		preview.Size = UDim2.fromOffset(12, 12)
		preview.Parent = slider
		local custombox = Instance.new('TextBox')
		custombox.BackgroundTransparency = 1
		custombox.FontFace = uipallet.Font
		custombox.Position = UDim2.new(1, -69, 0, 9)
		custombox.Size = UDim2.fromOffset(60, 15)
		custombox.Text = ''
		custombox.TextColor3 = color.Dark(uipallet.Text, 0.16)
		custombox.TextSize = 11
		custombox.TextXAlignment = Enum.TextXAlignment.Right
		custombox.Visible = false
		custombox.Parent = slider
		local expand = Instance.new('TextButton')
		expand.BackgroundTransparency = 1
		expand.Position = UDim2.new(0, getfontbounds(title.Text, title.TextSize, title.Font).X + 11, 0, 7)
		expand.Size = UDim2.fromOffset(17, 13)
		expand.Text = ''
		expand.Parent = slider
		local icon = Instance.new('ImageLabel')
		icon.BackgroundTransparency = 1
		icon.Image = getvapeasset('pistonware/assets/new/downexpandslider.png')
		icon.ImageColor3 = color.Dark(uipallet.Text, 0.43)
		icon.Position = UDim2.fromOffset(4, 4)
		icon.Size = UDim2.fromOffset(10, 5)
		icon.Parent = expand
		local rainbow = Instance.new('TextButton')
		rainbow.BackgroundTransparency = 1
		rainbow.Position = UDim2.new(1, -42, 0, 10)
		rainbow.Size = UDim2.fromOffset(12, 12)
		rainbow.Text = ''
		rainbow.Parent = slider
		local ring1 = Instance.new('ImageLabel')
		ring1.BackgroundTransparency = 1
		ring1.Image = getvapeasset('pistonware/assets/new/rainbow_1.png')
		ring1.ImageColor3 = color.Light(uipallet.Main, 0.37)
		ring1.Size = UDim2.fromOffset(12, 12)
		ring1.Parent = rainbow
		local ring2 = Instance.fromExisting(ring1)
		ring2.Image = getvapeasset('pistonware/assets/new/rainbow_2.png')
		ring2.Parent = rainbow
		local ring3 = Instance.fromExisting(ring1)
		ring3.Image = getvapeasset('pistonware/assets/new/rainbow_3.png')
		ring3.Parent = rainbow
		local ring4 = Instance.fromExisting(ring1)
		ring4.Image = getvapeasset('pistonware/assets/new/rainbow_4.png')
		ring4.Parent = rainbow
		local knob = Instance.new('ImageLabel')
		knob.BackgroundTransparency = 1
		knob.Image = getvapeasset('pistonware/assets/new/theme.png')
		knob.ImageColor3 = colors[4]
		knob.Name = 'Knob'
		knob.Position = UDim2.fromOffset(colorPositions[4] - 3, -5)
		knob.Size = UDim2.fromOffset(26, 12)
		knob.Parent = holder
		props.Function = props.Function or function() end
		local rainbowTable = {}
		for i = 0, 1, 0.1 do
			table.insert(rainbowTable, ColorSequenceKeypoint.new(i, Color3.fromHSV(i, 1, 1)))
		end
		
		local colorSlider = createSlider('Custom color', ColorSequence.new(rainbowTable))
		local satSlider = createSlider('Saturation', ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromHSV(0, 0, component.Value)),
			ColorSequenceKeypoint.new(1, Color3.fromHSV(component.Hue, 1, component.Value))
		}))
		
		local vibSlider = createSlider('Vibrance', ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromHSV(0, 0, 0)),
			ColorSequenceKeypoint.new(1, Color3.fromHSV(component.Hue, component.Sat, 1))
		}))
		
		local normalknob = getvapeasset('pistonware/assets/new/theme.png')
		local rainbowknob = getvapeasset('pistonware/assets/new/customtheme.png')
		local rainbowthread
		local currentNotch
		
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
			preview.ImageColor3 = Color3.fromHSV(self.Hue, self.Sat, self.Value)
		
			satSlider.Holder.UIGradient.Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.fromHSV(0, 0, self.Value)),
				ColorSequenceKeypoint.new(1, Color3.fromHSV(self.Hue, 1, self.Value))
			})
		
			vibSlider.Holder.UIGradient.Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.fromHSV(0, 0, 0)),
				ColorSequenceKeypoint.new(1, Color3.fromHSV(self.Hue, self.Sat, 1))
			})
		
			local newNotch = (self.Rainbow or self.CustomColor) and 4 or n or currentNotch
			if self.Rainbow or self.CustomColor then
				knob.Image = rainbowknob
				knob.ImageColor3 = Color3.new(1, 1, 1)
		
				if newNotch ~= currentNotch then
					tween:Tween(knob, uipallet.Tween, {
						Position = UDim2.fromOffset(colorPositions[4] - 3, -5)
					})
				end
			else
				knob.Image = normalknob
				knob.ImageColor3 = Color3.fromHSV(self.Hue, self.Sat, self.Value)
		
				if newNotch ~= currentNotch then
					tween:Tween(knob, uipallet.Tween, {
						Position = UDim2.fromOffset(colorPositions[n or 4] - 3, -5)
					})
				end
			end
		
			currentNotch = newNotch
			if self.Rainbow then
				if h then
					colorSlider.Holder.Fill.Size = UDim2.fromScale(math.clamp(self.Hue, 0.04, 0.96), 1)
				end
		
				if s then
					satSlider.Holder.Fill.Size = UDim2.fromScale(math.clamp(self.Sat, 0.04, 0.96), 1)
				end
		
				if v then
					vibSlider.Holder.Fill.Size = UDim2.fromScale(math.clamp(self.Value, 0.04, 0.96), 1)
				end
			else
				if h then
					tween:Tween(colorSlider.Holder.Fill, uipallet.Tween, {
						Size = UDim2.fromScale(math.clamp(self.Hue, 0.04, 0.96), 1)
					})
				end
		
				if s then
					tween:Tween(satSlider.Holder.Fill, uipallet.Tween, {
						Size = UDim2.fromScale(math.clamp(self.Sat, 0.04, 0.96), 1)
					})
				end
		
				if v then
					tween:Tween(vibSlider.Holder.Fill, uipallet.Tween, {
						Size = UDim2.fromScale(math.clamp(self.Value, 0.04, 0.96), 1)
					})
				end
			end
		
			props.Function(self.Hue, self.Sat, self.Value)
		end
		
		function component:Toggle()
			self.Rainbow = not self.Rainbow
			if rainbowthread then
				task.cancel(rainbowthread)
			end
		
			if self.Rainbow then
				knob.Image = rainbowknob
				table.insert(vape.RainbowSliders, self)
		
				ring1.ImageColor3 = Color3.fromRGB(5, 127, 100)
				rainbowthread = task.delay(0.1, function()
					ring2.ImageColor3 = Color3.fromRGB(228, 125, 43)
					rainbowthread = task.delay(0.1, function()
						ring3.ImageColor3 = Color3.fromRGB(225, 46, 52)
						rainbowthread = nil
					end)
				end)
			else
				self:SetValue(nil, nil, nil, 4)
				knob.Image = normalknob
				local index = table.find(vape.RainbowSliders, self)
				if index then
					table.remove(vape.RainbowSliders, index)
				end
		
				ring3.ImageColor3 = color.Light(uipallet.Main, 0.37)
				rainbowthread = task.delay(0.1, function()
					ring2.ImageColor3 = color.Light(uipallet.Main, 0.37)
					rainbowthread = task.delay(0.1, function()
						ring1.ImageColor3 = color.Light(uipallet.Main, 0.37)
						rainbowthread = nil
					end)
				end)
			end
		end
		
		expand.MouseEnter:Connect(function()
			icon.ImageColor3 = color.Dark(uipallet.Text, 0.16)
		end)
		
		expand.MouseLeave:Connect(function()
			icon.ImageColor3 = color.Dark(uipallet.Text, 0.43)
		end)
		
		expand.MouseButton1Click:Connect(function()
			colorSlider.Visible = not colorSlider.Visible
			satSlider.Visible = colorSlider.Visible
			vibSlider.Visible = satSlider.Visible
			icon.Rotation = satSlider.Visible and 180 or 0
		end)
		
		preview.MouseButton1Click:Connect(function()
			preview.Visible = false
			custombox.Visible = true
			custombox:CaptureFocus()
			local text = Color3.fromHSV(component.Hue, component.Sat, component.Value)
			custombox.Text = math.round(text.R * 255)..', '..math.round(text.G * 255)..', '..math.round(text.B * 255)
		end)
		
		slider.InputBegan:Connect(function(input)
			if
				(input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch)
				and (input.Position.Y - slider.AbsolutePosition.Y) > (20 * scale.Scale)
			then
				local releaseConnection
				local moveConnection = inputService.InputChanged:Connect(function(newInput)
					if newInput.UserInputType == (input.UserInputType == Enum.UserInputType.MouseButton1 and Enum.UserInputType.MouseMovement or Enum.UserInputType.Touch) then
						component:SetValue(nil, nil, nil, math.clamp(math.round((newInput.Position.X - holder.AbsolutePosition.X) / scale.Scale / 27), 1, 7))
					end
				end)
		
				releaseConnection = input.Changed:Connect(function()
					if input.UserInputState == Enum.UserInputState.End then
						moveConnection:Disconnect()
						releaseConnection:Disconnect()
					end
				end)
		
				component:SetValue(nil, nil, nil, math.clamp(math.round((input.Position.X - holder.AbsolutePosition.X) / scale.Scale / 27), 1, 7))
			end
		end)
		
		rainbow.MouseButton1Click:Connect(function()
			component:Toggle()
		end)
		
		custombox.FocusLost:Connect(function(enter)
			preview.Visible = true
			custombox.Visible = false
		
			if enter then
				local success, parsed = pcall(function()
					local commas = custombox.Text:split(',')
					return tonumber(commas[1]) and Color3.fromRGB(tonumber(commas[1]), tonumber(commas[2]), tonumber(commas[3])) or Color3.fromHex(custombox.Text)
				end)
		
				if success then
					if component.Rainbow then
						component:Toggle()
					end
		
					component:SetValue(parsed:ToHSV())
				end
			end
		end)
		
		api.Options[props.Name] = component
		
		return component
	end,
	ImageToggle = function(props, children, api)
		local component = {
			Enabled = false,
			Index = getTableSize(api.Options),
			Type = 'ImageToggle'
		}
		
		local isHover = false
		local toggle = Instance.new('TextButton')
		toggle.AutoButtonColor = false
		toggle.BackgroundColor3 = color.Dark(children.BackgroundColor3, props.Darker and 0.02 or 0)
		toggle.BorderSizePixel = 0
		toggle.FontFace = uipallet.Font
		toggle.Size = UDim2.new(1, 0, 0, 40)
		toggle.Text = string.rep(' ', 33)..props.Name
		toggle.TextColor3 = color.Dark(uipallet.Text, 0.16)
		toggle.TextSize = 14
		toggle.TextXAlignment = Enum.TextXAlignment.Left
		toggle.Visible = props.Visible == nil or props.Visible
		toggle.Parent = children
		component.Object = toggle
		local icon = Instance.new('ImageLabel')
		icon.BackgroundTransparency = 1
		icon.Image = props.Icon
		icon.ImageColor3 = uipallet.Text
		icon.Name = 'Icon'
		icon.Position = props.Position
		icon.Size = props.Size
		icon.Parent = toggle
		local holder = Instance.new('Frame')
		holder.BackgroundColor3 = color.Light(uipallet.Main, 0.14)
		holder.Name = 'Knob'
		holder.Position = UDim2.new(1, -30, 0, 14)
		holder.Size = UDim2.fromOffset(22, 12)
		holder.Parent = toggle
		addCorner(holder, UDim.new(1, 0))
		local knob = Instance.new('Frame')
		knob.BackgroundColor3 = uipallet.Main
		knob.Position = UDim2.fromOffset(2, 2)
		knob.Size = UDim2.fromOffset(8, 8)
		knob.Parent = holder
		addCorner(knob, UDim.new(1, 0))
		props.Function = props.Function or function() end
		
		function component:Color(hue, sat, val, isRainbow)
			if self.Enabled then
				tween:Cancel(holder)
				holder.BackgroundColor3 = isRainbow and Color3.fromHSV(vape:Color((hue - (self.Index * 0.075)) % 1)) or Color3.fromHSV(hue, sat, val)
			end
		end
		
		function component:Toggle()
			local isRainbow = vape.GUIColor.Rainbow and vape.RainbowMode.Value ~= 'Retro'
			self.Enabled = not self.Enabled
		
			tween:Tween(holder, uipallet.Tween, {
				BackgroundColor3 = self.Enabled and (isRainbow and Color3.fromHSV(vape:Color((vape.GUIColor.Hue - (self.Index * 0.075)) % 1)) or Color3.fromHSV(vape.GUIColor.Hue, vape.GUIColor.Sat, vape.GUIColor.Value)) or (isHover and color.Light(uipallet.Main, 0.37) or color.Light(uipallet.Main, 0.14))
			})
		
			tween:Tween(knob, uipallet.Tween, {
				Position = UDim2.fromOffset(self.Enabled and 12 or 2, 2)
			})
		
			props.Function(self.Enabled)
		end
		
		-- The Scale listener that stood here is gone. It rewrote toggle.Text to the exact
		-- string it was already set to (the indent is a fixed count of hair spaces -- see the
		-- GUI component AbsoluteContentSize handler for why scaling that count is wrong), so
		-- it did no work. It was still one connection per overlay toggle, on a signal outside
		-- the GUI tree that nothing ever disconnected.
		
		toggle.MouseEnter:Connect(function()
			isHover = true
		
			if not component.Enabled then
				tween:Tween(holder, uipallet.Tween, {
					BackgroundColor3 = color.Light(uipallet.Main, 0.37)
				})
			end
		end)
		
		toggle.MouseLeave:Connect(function()
			isHover = false
		
			if not component.Enabled then
				tween:Tween(holder, uipallet.Tween, {
					BackgroundColor3 = color.Light(uipallet.Main, 0.14)
				})
			end
		end)
		
		toggle.MouseButton1Click:Connect(function()
			component:Toggle()
		end)
		
		if props.Default then
			component:Toggle()
		end
		
		api.Options[props.Name] = component
		
		return component
	end,
	LegitModule = function(props, children, api)
		vape:Remove(props.Name)
		local component = {
			Enabled = false,
			Legit = true,
			Name = props.Name,
			Options = {},
			Type = 'LegitModule'
		}
		
		local button = Instance.new('TextButton')
		button.AutoButtonColor = false
		button.BackgroundColor3 = color.Light(uipallet.Main, 0.02)
		button.Name = props.Name
		button.Text = ''
		button.Parent = children
		component.Object = button
		addTooltip(button, props.Tooltip, nil, function()
			return vape.LegitVisible
		end)
		addCorner(button)
		local title = Instance.new('TextLabel')
		title.BackgroundTransparency = 1
		title.FontFace = uipallet.Font
		title.Position = UDim2.fromOffset(16, 81)
		title.Size = UDim2.new(1, -16, 0, 20)
		title.Text = props.Name
		title.TextColor3 = color.Dark(uipallet.Text, 0.31)
		title.TextSize = 13
		title.TextXAlignment = Enum.TextXAlignment.Left
		title.Parent = button
		local holder = Instance.new('Frame')
		holder.BackgroundColor3 = color.Light(uipallet.Main, 0.14)
		holder.Position = UDim2.new(1, -57, 0, 15)
		holder.Size = UDim2.fromOffset(22, 12)
		holder.Parent = button
		addCorner(holder, UDim.new(1, 0))
		local knob = Instance.new('Frame')
		knob.BackgroundColor3 = uipallet.Main
		knob.Position = UDim2.fromOffset(2, 2)
		knob.Size = UDim2.fromOffset(8, 8)
		knob.Parent = holder
		addCorner(knob, UDim.new(1, 0))
		local dotsbutton = Instance.new('TextButton')
		dotsbutton.BackgroundTransparency = 1
		dotsbutton.Name = 'Dots'
		dotsbutton.Position = UDim2.new(1, -27, 0, 9)
		dotsbutton.Size = UDim2.fromOffset(14, 24)
		dotsbutton.Text = ''
		dotsbutton.Parent = button
		local dots = Instance.new('ImageLabel')
		dots.BackgroundTransparency = 1
		dots.Image = getvapeasset('pistonware/assets/new/overlaydots.png')
		dots.ImageColor3 = color.Light(uipallet.Main, 0.37)
		dots.Name = 'Dots'
		dots.Position = UDim2.fromOffset(6, 6)
		dots.Size = UDim2.fromOffset(2, 12)
		dots.Parent = dotsbutton
		local shadow = Instance.new('TextButton')
		shadow.Name = 'Shadow'
		shadow.Size = UDim2.new(1, 0, 1, -5)
		shadow.BackgroundColor3 = Color3.new()
		shadow.BackgroundTransparency = 1
		shadow.AutoButtonColor = false
		shadow.ClipsDescendants = true
		shadow.Visible = false
		shadow.Text = ''
		shadow.Parent = api.Window
		addCorner(shadow)
		local settingspane = Instance.new('TextButton')
		settingspane.Size = UDim2.new(0, 220, 1, 0)
		settingspane.Position = UDim2.fromScale(1, 0)
		settingspane.BackgroundColor3 = uipallet.Main
		settingspane.AutoButtonColor = false
		settingspane.Text = ''
		settingspane.Parent = shadow
		local settingstitle = Instance.new('TextLabel')
		settingstitle.Name = 'Title'
		settingstitle.Size = UDim2.new(1, -36, 0, 20)
		settingstitle.Position = UDim2.fromOffset(36, 12)
		settingstitle.BackgroundTransparency = 1
		settingstitle.Text = props.Name
		settingstitle.TextXAlignment = Enum.TextXAlignment.Left
		settingstitle.TextColor3 = color.Dark(uipallet.Text, 0.16)
		settingstitle.TextSize = 13
		settingstitle.FontFace = uipallet.Font
		settingstitle.Parent = settingspane
		local back = Instance.new('ImageButton')
		back.Name = 'Back'
		back.Size = UDim2.fromOffset(16, 16)
		back.Position = UDim2.fromOffset(11, 13)
		back.BackgroundTransparency = 1
		back.Image = getvapeasset('pistonware/assets/new/back.png')
		back.ImageColor3 = color.Light(uipallet.Main, 0.37)
		back.Parent = settingspane
		addCorner(settingspane)
		local settingschildren = Instance.new('ScrollingFrame')
		settingschildren.BackgroundColor3 = uipallet.Main
		settingschildren.BorderSizePixel = 0
		settingschildren.CanvasSize = UDim2.new()
		settingschildren.Name = 'Children'
		settingschildren.Position = UDim2.fromOffset(0, 41)
		settingschildren.ScrollBarThickness = 2
		settingschildren.ScrollBarImageTransparency = 0.75
		settingschildren.Size = UDim2.new(1, 0, 1, -45)
		settingschildren.Parent = settingspane
		local windowlist = Instance.new('UIListLayout')
		windowlist.SortOrder = Enum.SortOrder.LayoutOrder
		windowlist.HorizontalAlignment = Enum.HorizontalAlignment.Center
		windowlist.Parent = settingschildren
		if props.Size then
			local modulechildren = Instance.new('Frame')
			modulechildren.Size = props.Size
			modulechildren.BackgroundTransparency = 1
			modulechildren.Visible = false
			modulechildren.Parent = scaledgui
			addDragHandler(modulechildren, api.Window)
			local objectstroke = Instance.new('UIStroke')
			objectstroke.Color = Color3.fromRGB(5, 134, 105)
			objectstroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
			objectstroke.Thickness = 0
			objectstroke.Parent = modulechildren
			component.Children = modulechildren
		end
		props.Function = props.Function or function() end
		addMaid(component)
		
		function component:Color(hue, sat, val, isRainbow)
			if self.Enabled then
				tween:Cancel(holder)
				holder.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
			end
		
			for _, component in self.Options do
				if component.Color then
					component:Color(hue, sat, val, isRainbow)
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
		
			title.TextColor3 = self.Enabled and color.Light(uipallet.Text, 0.2) or color.Dark(uipallet.Text, 0.31)
			button.BackgroundColor3 = self.Enabled and color.Light(uipallet.Main, 0.05) or button.BackgroundColor3
		
			tween:Tween(holder, uipallet.Tween, {
				BackgroundColor3 = self.Enabled and Color3.fromHSV(vape.GUIColor.Hue, vape.GUIColor.Sat, vape.GUIColor.Value) or color.Light(uipallet.Main, 0.14)
			})
		
			tween:Tween(knob, uipallet.Tween, {
				Position = UDim2.fromOffset(self.Enabled and 12 or 2, 2)
			})
		
			if not self.Enabled then
				for _, v in self.Connections do
					v:Disconnect()
				end
				table.clear(self.Connections)
			end
		
			vape:RequestSave()
			--[[
				Deferred rather than spawned while a profile is being applied.

				task.spawn runs its function INLINE, on the calling thread, until that function
				first yields. So during an apply, module:Load switching a module on ran the whole
				front of that module's setup -- its connections, its ESP objects, its walk of the
				entity list -- synchronously inside the apply loop, before Load's next line.

				Sixty modules in, that is one unbroken block of work, and yieldBuild cannot break
				it up: the budget is only checked BETWEEN modules, never inside the one that is
				currently running. So the apply looked like it was yielding while in fact it was
				executing every enabled module nose to tail without ever reaching a yield.

				queueStart hands them to a drain thread that yields between one module and the
				next, so the apply loop keeps its own yields AND the startups are spread out
				rather than arriving in one block. See queueStart for why deferring alone is not
				enough.

				Only while applying, and only for enable. Uninject tears modules down by toggling
				them off and then destroys the GUI and empties the vape table, so a deferred
				disable would run against a table loopClean has already cleared.
			]]
			if vape.Applying and self.Enabled then
				queueStart(props.Name, props.Function)
			else
				task.spawn(props.Function, self.Enabled)
			end
		end
		
		bindComponents(component, settingschildren)
		
		back.MouseEnter:Connect(function()
			back.ImageColor3 = uipallet.Text
		end)
		
		back.MouseLeave:Connect(function()
			back.ImageColor3 = color.Light(uipallet.Main, 0.37)
		end)
		
		back.MouseButton1Click:Connect(function()
			tween:Tween(shadow, uipallet.Tween, {
				BackgroundTransparency = 1
			})
		
			tween:Tween(settingspane, uipallet.Tween, {
				Position = UDim2.fromScale(1, 0)
			})
		
			task.delay(0.2, function()
				shadow.Visible = false
			end)
		end)
		
		button.MouseEnter:Connect(function()
			if not component.Enabled then
				button.BackgroundColor3 = color.Light(uipallet.Main, 0.05)
			end
		end)
		
		button.MouseLeave:Connect(function()
			if not component.Enabled then
				button.BackgroundColor3 = color.Light(uipallet.Main, 0.02)
			end
		end)
		
		button.MouseButton1Click:Connect(function()
			component:Toggle()
		end)
		
		button.MouseButton2Click:Connect(function()
			shadow.Visible = true
		
			tween:Tween(shadow, uipallet.Tween, {
				BackgroundTransparency = 0.5
			})
		
			tween:Tween(settingspane, uipallet.Tween, {
				Position = UDim2.new(1, -220, 0, 0)
			})
		end)
		
		dotsbutton.MouseButton1Click:Connect(function()
			shadow.Visible = true
		
			tween:Tween(shadow, uipallet.Tween, {
				BackgroundTransparency = 0.5
			})
		
			tween:Tween(settingspane, uipallet.Tween, {
				Position = UDim2.new(1, -220, 0, 0)
			})
		end)
		
		dotsbutton.MouseEnter:Connect(function()
			dots.ImageColor3 = uipallet.Text
		end)
		
		dotsbutton.MouseLeave:Connect(function()
			dots.ImageColor3 = color.Light(uipallet.Main, 0.37)
		end)
		
		shadow.MouseButton1Click:Connect(function()
			tween:Tween(shadow, uipallet.Tween, {
				BackgroundTransparency = 1
			})
		
			tween:Tween(settingspane, uipallet.Tween, {
				Position = UDim2.fromScale(1, 0)
			})
		
			task.delay(0.2, function()
				shadow.Visible = false
			end)
		end)
		
		shadow:GetPropertyChangedSignal('Visible'):Connect(function()
			tooltip.Visible = false
			vape.LegitVisible = shadow.Visible
		end)
		
		windowlist:GetPropertyChangedSignal('AbsoluteContentSize'):Connect(function()
			if vape.ThreadFix then
				setthreadidentity(8)
			end
		
			settingschildren.CanvasSize = UDim2.fromOffset(0, windowlist.AbsoluteContentSize.Y / scale.Scale)
		end)
		
		api.Modules[props.Name] = component
		-- Same reasoning as vape.ModuleOrder: vape:Save walks the array, never the hash.
		api.Order = api.Order or {}
		table.insert(api.Order, component)

		local sorting = {}
		for _, mod in orderedModules(api.Order) do
			table.insert(sorting, mod.Name)
		end
		table.sort(sorting)
		
		for index, name in sorting do
			api.Modules[name].Object.LayoutOrder = index
		end
		
		return component
	end,
	LegitWindow = function(props, children, api)
		local component = {
			Modules = {},
			-- The array half of Modules, for the same reason as vape.ModuleOrder. Declared here
			-- rather than on first insert so a walk that happens before any legit module exists
			-- iterates an empty list instead of nil.
			Order = {}
		}
		
		local window = Instance.new('Frame')
		window.BackgroundColor3 = uipallet.Main
		window.Position = UDim2.new(0.5, -350, 0.5, -190)
		window.Size = UDim2.fromOffset(700, 380)
		window.Name = 'LegitGUI'
		window.Visible = false
		window.Parent = scaledgui
		table.insert(vape.Windows, window)
		component.Window = window
		addBlur(window)
		addCorner(window)
		addDragHandler(window)
		local modal = Instance.new('TextButton')
		modal.BackgroundTransparency = 1
		modal.Modal = true
		modal.Text = ''
		modal.Parent = window
		local icon = Instance.new('ImageLabel')
		icon.BackgroundTransparency = 1
		icon.Image = getvapeasset('pistonware/assets/new/legit_mode_icon.png')
		icon.ImageColor3 = uipallet.Text
		icon.Position = UDim2.fromOffset(18, 11)
		icon.Size = UDim2.fromOffset(16, 16)
		icon.Parent = window
		local close = Instance.new('ImageButton')
		close.BackgroundTransparency = 1
		close.Image = getvapeasset('pistonware/assets/new/min.png')
		close.ImageColor3 = color.Light(uipallet.Main, 0.24)
		close.Position = UDim2.new(1, -31, 0, 11)
		close.Size = UDim2.fromOffset(16, 16)
		close.Parent = window
		local holder = Instance.new('Frame')
		holder.BackgroundColor3 = color.Dark(uipallet.Main, 0.02)
		holder.Position = UDim2.new(1, -253, 0, 42)
		holder.Size = UDim2.fromOffset(242, 29)
		holder.Parent = window
		addCorner(holder, UDim.new(0, 4))
		local stroke = Instance.new('UIStroke')
		stroke.Color = color.Light(uipallet.Main, 0.02)
		stroke.Parent = holder
		local searchicon = Instance.new('ImageLabel')
		searchicon.BackgroundTransparency = 1
		searchicon.Image = getvapeasset('pistonware/assets/new/search.png')
		searchicon.ImageColor3 = color.Light(uipallet.Main, 0.42)
		searchicon.Position = UDim2.new(1, -25, 0, 9)
		searchicon.Size = UDim2.fromOffset(12, 12)
		searchicon.Parent = holder
		local box = Instance.new('TextBox')
		box.BackgroundTransparency = 1
		box.ClearTextOnFocus = false
		box.FontFace = uipallet.Font
		box.PlaceholderColor3 = color.Dark(uipallet.Text, 0.16)
		box.PlaceholderText = 'Search mods'
		box.Position = UDim2.fromOffset(8, 0)
		box.Size = UDim2.new(1, -8, 1, 0)
		box.Text = ''
		box.TextColor3 = color.Dark(uipallet.Text, 0.16)
		box.TextSize = 14
		box.TextXAlignment = Enum.TextXAlignment.Left
		box.Parent = holder
		local children = Instance.new('ScrollingFrame')
		children.BackgroundTransparency = 1
		children.BorderSizePixel = 0
		children.CanvasSize = UDim2.new()
		children.Position = UDim2.fromOffset(14, 76)
		children.ScrollBarThickness = 2
		children.ScrollBarImageTransparency = 0.75
		children.Size = UDim2.fromOffset(684, 301)
		children.Parent = window
		local windowlist = Instance.new('UIGridLayout')
		windowlist.CellSize = UDim2.fromOffset(163, 114)
		windowlist.CellPadding = UDim2.fromOffset(6, 6)
		windowlist.FillDirectionMaxCells = 4
		windowlist.SortOrder = Enum.SortOrder.LayoutOrder
		windowlist.Parent = children
		
		bindComponents(component, children)
		
		function component:CreateModule(props)
			return components.LegitModule(props, children, component)
		end
		
		local function visibleCheck()
			for _, module in orderedModules(component.Order) do
				if module.Children then
					local visible = clickgui.Visible
					--[[for _, v2 in self.Windows do
						visible = visible or v2.Visible
					end]]
		
					module.Children.Visible = (not visible or window.Visible) and module.Enabled
				end
			end
		end
		
		box:GetPropertyChangedSignal('Text'):Connect(function()
			for name, module in orderedModules(component.Order) do
				module.Object.Visible = (box.Text == '' or name:lower():find(box.Text:lower())) and true or false
			end
		end)
		
		close.MouseButton1Click:Connect(function()
			window.Visible = false
			clickgui.Visible = true
		end)
		
		close.MouseEnter:Connect(function()
			close.ImageColor3 = color.Light(uipallet.Main, 0.37)
		end)
		
		close.MouseLeave:Connect(function()
			close.ImageColor3 = color.Light(uipallet.Main, 0.24)
		end)
		
		vape:Clean(clickgui:GetPropertyChangedSignal('Visible'):Connect(visibleCheck))
		
		holder.MouseEnter:Connect(function()
			tween:Tween(stroke, uipallet.Tween, {
				Color = color.Light(uipallet.Main, 0.0875)
			})
		end)
		
		holder.MouseLeave:Connect(function()
			tween:Tween(stroke, uipallet.Tween, {
				Color = color.Light(uipallet.Main, 0.02)
			})
		end)
		
		window:GetPropertyChangedSignal('Visible'):Connect(function()
			vape:UpdateGUI(vape.GUIColor.Hue, vape.GUIColor.Sat, vape.GUIColor.Value)
			visibleCheck()
		end)
		
		windowlist:GetPropertyChangedSignal('AbsoluteContentSize'):Connect(function()
			if vape.ThreadFix then
				setthreadidentity(8)
			end
		
			children.CanvasSize = UDim2.fromOffset(0, windowlist.AbsoluteContentSize.Y / scale.Scale)
		end)
		
		vape.Legit = component
		
		return component
	end,
	Module = function(props, children, api)
		vape:Remove(props.Name)
		local component = {
			Category = api.Name,
			Enabled = false,
			ExtraText = props.ExtraText,
			-- ModuleCount, not a walk of vape.Modules. getTableSize is O(n) and this runs
			-- once per registration, so a payload with several hundred modules paid a
			-- quadratic count for a placeholder that SortCategories overwrites moments
			-- later anyway. The count is maintained on insert and remove for exactly this.
			Index = vape.ModuleCount,
			Name = props.Name,
			Options = {},
			--[[ Every other component in this table declares its Type; this one never did, so
			vape:Remove's `component.Type == 'Module'` test could not have matched and the
			resort after a removal would have been dead code. ]]
			Type = 'Module',
			Visible = true
		}
		
		local isHover = false
		local button = Instance.new('TextButton')
		button.AutoButtonColor = false
		button.BackgroundColor3 = uipallet.Main
		button.BorderSizePixel = 0
		button.FontFace = uipallet.Font
		button.Name = props.Name
		button.Size = UDim2.fromOffset(220, 40)
		button.Text = string.rep(' ', 12)..props.Name
		button.TextColor3 = color.Dark(uipallet.Text, 0.16)
		button.TextSize = 14
		button.TextXAlignment = Enum.TextXAlignment.Left
		button.Parent = children
		component.Object = button
		addTooltip(button, props.Tooltip)
		local gradient = Instance.new('UIGradient')
		gradient.Enabled = false
		gradient.Rotation = 90
		gradient.Parent = button
		local modulechildren = Instance.new('Frame')
		modulechildren.BackgroundColor3 = color.Dark(uipallet.Main, 0.02)
		modulechildren.BorderSizePixel = 0
		modulechildren.Name = props.Name..'Children'
		modulechildren.Size = UDim2.new(1, 0, 0, 0)
		modulechildren.Visible = false
		modulechildren.Parent = children
		local windowlist = Instance.new('UIListLayout')
		windowlist.HorizontalAlignment = Enum.HorizontalAlignment.Center
		windowlist.SortOrder = Enum.SortOrder.LayoutOrder
		windowlist.Parent = modulechildren
		local dotsbutton = Instance.new('TextButton')
		dotsbutton.BackgroundTransparency = 1
		dotsbutton.Name = 'Dots'
		dotsbutton.Position = UDim2.new(1, -25, 0, 0)
		dotsbutton.Size = UDim2.fromOffset(25, 40)
		dotsbutton.Text = ''
		dotsbutton.Parent = button
		local dots = Instance.new('ImageLabel')
		dots.BackgroundTransparency = 1
		dots.Image = getvapeasset('pistonware/assets/new/settingdots.png')
		dots.ImageColor3 = color.Light(uipallet.Main, 0.37)
		dots.Name = 'Dots'
		dots.Position = UDim2.fromOffset(4, 12)
		dots.Size = UDim2.fromOffset(3, 16)
		dots.Parent = dotsbutton
		local divider = Instance.new('Frame')
		divider.BackgroundColor3 = Color3.new(0.19, 0.19, 0.19)
		divider.BackgroundTransparency = 0.52
		divider.BorderSizePixel = 0
		divider.Name = 'Divider'
		divider.Position = UDim2.new(0, 0, 1, -1)
		divider.Size = UDim2.new(1, 0, 0, 1)
		divider.Visible = false
		divider.Parent = button
		local edit = Instance.new('TextButton')
		edit.AutoButtonColor = false
		edit.BackgroundColor3 = color.Dark(uipallet.Main, 0.02)
		edit.BorderSizePixel = 0
		edit.Size = UDim2.fromOffset(40, 40)
		edit.Text = ''
		edit.Visible = false
		edit.Parent = button
		local editbox = Instance.new('Frame')
		editbox.BorderSizePixel = 0
		editbox.Position = UDim2.fromOffset(16, 16)
		editbox.Size = UDim2.fromOffset(8, 8)
		editbox.Parent = edit
		local editborder = Instance.new('UIStroke')
		--[[ Cosmetic, and absent on older clients. Purely a 1px outset on the edit outline. ]]
		if hasBorderOffset then
			editborder.BorderOffset = UDim.new(0, 1)
		end
		editborder.LineJoinMode = Enum.LineJoinMode.Miter
		editborder.Parent = editbox
		props.Function = props.Function or function() end
		component.Edit = edit
		component.Children = modulechildren
		addMaid(component)
		
		function component:Color(hue, sat, val, isRainbow)
			if self.Enabled then
				button.BackgroundColor3 = isRainbow and Color3.fromHSV(vape:Color((hue - (self.Index * 0.025)) % 1)) or Color3.fromHSV(hue, sat, val)
				button.TextColor3 = vape.GUIColor.Rainbow and Color3.new(0.19, 0.19, 0.19) or vape:TextColor(hue, sat, val)
				button.UIGradient.Enabled = isRainbow and vape.RainbowMode.Value == 'Gradient'
		
				if button.UIGradient.Enabled then
					button.BackgroundColor3 = Color3.new(1, 1, 1)
					button.UIGradient.Color = ColorSequence.new({
						ColorSequenceKeypoint.new(0, Color3.fromHSV(vape:Color((hue - (self.Index * 0.025)) % 1))),
						ColorSequenceKeypoint.new(1, Color3.fromHSV(vape:Color((hue - ((self.Index + 1) * 0.025)) % 1)))
					})
				end
		
				self.Bind:SetColor(self.Object.TextColor3)
				dots.ImageColor3 = self.Object.TextColor3
			end
		
			if self.Visible then
				editbox.BackgroundColor3 = isRainbow and Color3.fromHSV(vape:Color((hue - (self.Index * 0.025)) % 1)) or Color3.fromHSV(hue, sat, val)
				editborder.Color = editbox.BackgroundColor3
			end
		
			for _, component in self.Options do
				if component.Color then
					component:Color(hue, sat, val, isRainbow)
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
			editbox.BackgroundTransparency = isVisible and 0 or 1
			editborder.Color = isVisible and editbox.BackgroundColor3 or color.Light(uipallet.Main, 0.37)
		
			if isLoad and not vape.EditGUI then
				button.Visible = isVisible
			end
		end
		
		function component:Toggle(multiple)
			if vape.ThreadFix then
				setthreadidentity(8)
			end
		
			self.Enabled = not self.Enabled
			divider.Visible = self.Enabled
			gradient.Enabled = self.Enabled
			button.TextColor3 = (isHover or modulechildren.Visible) and uipallet.Text or color.Dark(uipallet.Text, 0.16)
			button.BackgroundColor3 = (isHover or modulechildren.Visible) and color.Light(uipallet.Main, 0.02) or uipallet.Main
			dots.ImageColor3 = self.Enabled and Color3.fromRGB(50, 50, 50) or color.Light(uipallet.Main, 0.37)
			component.Bind:SetColor(color.Dark(uipallet.Text, 0.43))
		
			if not self.Enabled then
				for _, v in self.Connections do
					v:Disconnect()
				end
				table.clear(self.Connections)
			end
		
			if multiple then
				if not vape.TextGUIThread then
					vape.TextGUIThread = task.defer(function()
						if vape.Loaded ~= nil then
							vape:UpdateTextGUI()
						end
		
						vape.TextGUIThread = nil
					end)
				end
			else
				vape:UpdateTextGUI()
			end
		
			vape:RequestSave()
			-- Deferred while applying, for the reason set out at the other module toggle: with
			-- task.spawn the module's setup runs inline inside the apply loop.
			if vape.Applying and self.Enabled then
				queueStart(props.Name, props.Function)
			else
				task.spawn(props.Function, self.Enabled)
			end
		end
		
		bindComponents(component, modulechildren)
		
		button.MouseEnter:Connect(function()
			isHover = true
			if not component.Enabled and not modulechildren.Visible then
				button.TextColor3 = uipallet.Text
				button.BackgroundColor3 = color.Light(uipallet.Main, 0.02)
			end
		
			component.Bind:SetVisible(isHover or modulechildren.Visible)
		end)
		
		button.MouseLeave:Connect(function()
			isHover = false
			if not component.Enabled and not modulechildren.Visible then
				button.TextColor3 = color.Dark(uipallet.Text, 0.16)
				button.BackgroundColor3 = uipallet.Main
			end
		
			component.Bind:SetVisible(isHover or modulechildren.Visible)
		end)
		
		button.MouseButton1Click:Connect(function()
			if vape.EditGUI then
				return
			end
		
			component:Toggle()
		end)
		
		button.MouseButton2Click:Connect(function()
			modulechildren.Visible = not modulechildren.Visible
		end)
		
		dotsbutton.MouseButton1Click:Connect(function()
			modulechildren.Visible = not modulechildren.Visible
		end)
		
		dotsbutton.MouseButton2Click:Connect(function()
			modulechildren.Visible = not modulechildren.Visible
		end)
		
		dotsbutton.MouseEnter:Connect(function()
			if not component.Enabled then
				dots.ImageColor3 = uipallet.Text
			end
		end)
		
		dotsbutton.MouseLeave:Connect(function()
			if not component.Enabled then
				dots.ImageColor3 = color.Light(uipallet.Main, 0.37)
			end
		end)
		
		edit.MouseButton1Click:Connect(function()
			component:SetVisible(not component.Visible)
		end)
		
		windowlist:GetPropertyChangedSignal('AbsoluteContentSize'):Connect(function()
			if vape.ThreadFix then
				setthreadidentity(8)
			end
		
			modulechildren.Size = UDim2.new(1, 0, 0, windowlist.AbsoluteContentSize.Y / scale.Scale)
		end)
		
		local bind = component:CreateBind({
			Module = true,
			Cover = true
		})
		
		bind.Triggered:Connect(function(isDown)
			if bind.Hold then
				if component.Enabled ~= isDown then
					if vape.ToggleNotifications.Enabled then
						vape:CreateNotification(props.Name, (not component.Enabled and "<font color='#00AA00'>Enabled</font>" or "<font color='#FF5A5A'>Disabled</font>"), 1.5)
					end
		
					component:Toggle(true)
				end
			else
				if vape.ToggleNotifications.Enabled then
					vape:CreateNotification(props.Name, (not component.Enabled and "<font color='#00AA00'>Enabled</font>" or "<font color='#FF5A5A'>Disabled</font>"), 1.5)
				end
		
				component:Toggle(true)
			end
		end)
		
		if inputService.TouchEnabled then
			local isHeld = false
		
			button.MouseButton1Down:Connect(function()
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
			end)
		
			button.MouseButton1Up:Connect(function()
				isHeld = false
			end)
		end
		
		vape.Modules[props.Name] = component
		vape.ModuleCount += 1
		table.insert(vape.ModuleOrder, component)
		vape:SortCategories()
		
		return component
	end,
	Overlay = function(props, children, api)
		local window
		local component
		component = {
			Button = vape.Overlays:CreateImageToggle({
				Name = props.Name,
				Function = function(callback)
					window.Visible = callback and (clickgui.Visible or component.Pinned)
		
					if not callback then
						for _, v in component.Connections do
							v:Disconnect()
						end
						table.clear(component.Connections)
					end
		
					if props.Function then
						task.spawn(props.Function, callback)
					end
				end,
				Icon = props.Icon,
				Size = props.Size,
				Position = props.Position
			}),
			Expanded = false,
			Pinned = false,
			Options = {},
			Type = 'Overlay'
		}
		
		window = Instance.new('TextButton')
		window.AutoButtonColor = false
		window.BackgroundColor3 = uipallet.Main
		window.Name = props.Name..'Overlay'
		window.Position = UDim2.fromOffset(240, 46)
		window.Size = UDim2.fromOffset(props.CategorySize or 220, 41)
		window.Text = ''
		window.Visible = false
		window.Parent = scaledgui
		component.Object = window
		local blur = addBlur(window)
		addCorner(window)
		addDragHandler(window)
		local icon = Instance.new('ImageLabel')
		icon.BackgroundTransparency = 1
		icon.Image = props.Icon
		icon.ImageColor3 = uipallet.Text
		-- props.Size, not icon.Size: Size is assigned on the NEXT line, so this read the
		-- freshly-constructed default of (0, 0) every time and the branch could never be
		-- taken. CategoryList already measures props.Size in the same expression.
		icon.Position = UDim2.fromOffset(12, (props.Size.X.Offset > 14 and 14 or 13))
		icon.Size = props.Size
		icon.Parent = window
		local title = Instance.new('TextLabel')
		title.BackgroundTransparency = 1
		title.FontFace = uipallet.Font
		title.Size = UDim2.new(1, -32, 0, 41)
		title.Position = UDim2.fromOffset(math.abs(title.Size.X.Offset), 0)
		title.Text = props.Name
		title.TextColor3 = uipallet.Text
		title.TextSize = 13
		title.TextXAlignment = Enum.TextXAlignment.Left
		title.Parent = window
		local pin = Instance.new('ImageButton')
		pin.Name = 'Pin'
		pin.Size = UDim2.fromOffset(14, 14)
		pin.Position = UDim2.new(1, -37, 0, 14)
		pin.BackgroundTransparency = 1
		pin.AutoButtonColor = false
		pin.Image = getvapeasset('pistonware/assets/new/pin.png')
		pin.ImageColor3 = color.Dark(uipallet.Text, 0.43)
		pin.Parent = window
		local dotsbutton = Instance.new('TextButton')
		dotsbutton.Name = 'Dots'
		dotsbutton.Size = UDim2.fromOffset(17, 40)
		dotsbutton.Position = UDim2.new(1, -17, 0, 0)
		dotsbutton.BackgroundTransparency = 1
		dotsbutton.Text = ''
		dotsbutton.Parent = window
		local dots = Instance.new('ImageLabel')
		dots.BackgroundTransparency = 1
		dots.Image = getvapeasset('pistonware/assets/new/overlaydots.png')
		dots.ImageColor3 = color.Light(uipallet.Main, 0.37)
		dots.Position = UDim2.fromOffset(5, 15)
		dots.Size = UDim2.fromOffset(2, 12)
		dots.Parent = dotsbutton
		local customchildren = Instance.new('Frame')
		customchildren.BackgroundTransparency = 1
		customchildren.Position = UDim2.fromScale(0, 1)
		customchildren.Size = UDim2.new(1, 0, 0, 200)
		customchildren.Parent = window
		local children = Instance.new('ScrollingFrame')
		children.BackgroundColor3 = color.Dark(uipallet.Main, 0.02)
		children.BorderSizePixel = 0
		children.CanvasSize = UDim2.new()
		children.Position = UDim2.fromOffset(0, 37)
		children.Size = UDim2.new(1, 0, 1, -41)
		children.ScrollBarThickness = 2
		children.ScrollBarImageTransparency = 0.75
		children.Visible = false
		children.Parent = window
		local stroke = Instance.new('UIStroke')
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.Color = Color3.fromRGB(85, 85, 85)
		stroke.Transparency = 0.8
		stroke.Parent = window
		local windowlist = Instance.new('UIListLayout')
		windowlist.HorizontalAlignment = Enum.HorizontalAlignment.Center
		windowlist.SortOrder = Enum.SortOrder.LayoutOrder
		windowlist.Parent = children
		addMaid(component)
		
		function component:Color(hue, sat, val, isRainbow)
			for _, component in self.Options do
				if component.Color then
					component:Color(hue, sat, val, isRainbow)
				end
			end
		end
		
		function component:Expand(visCheck)
			if visCheck and not blurEnabled(blur) then return end
		
			self.Expanded = not self.Expanded
			children.Visible = self.Expanded
			dots.ImageColor3 = self.Expanded and uipallet.Text or color.Light(uipallet.Main, 0.37)
		
			if self.Expanded then
				window.Size = UDim2.fromOffset(window.Size.X.Offset, math.min(41 + windowlist.AbsoluteContentSize.Y / scale.Scale, 601))
			else
				window.Size = UDim2.fromOffset(window.Size.X.Offset, 41)
			end
		end
		
		function component:Load(data)
			vape:LoadOptions(self, data.Options)
		
			if self.Button.Enabled ~= (data.Enabled and true or false) then
				self.Button:Toggle()
			end
		
			if (self.Pinned and true or false) ~= (data.Pinned and true or false) then
				self:Pin()
				self:Update()
			end
		
			if data.Position then
				window.Position = UDim2.fromOffset(data.Position.X, data.Position.Y)
			end
		end
		
		function component:Pin()
			self.Pinned = not self.Pinned
			pin.ImageColor3 = self.Pinned and uipallet.Text or color.Dark(uipallet.Text, 0.43)
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
		end
		
		function component:Update()
			window.Visible = self.Button.Enabled and (clickgui.Visible or self.Pinned)
			if self.Expanded then
				self:Expand()
			end
		
			if clickgui.Visible then
				window.Size = UDim2.fromOffset(window.Size.X.Offset, 41)
				window.BackgroundTransparency = 0
				setBlurEnabled(blur, true)
				stroke.Enabled = true
				icon.Visible = true
				title.Visible = true
				pin.Visible = true
				dotsbutton.Visible = true
			else
				window.Size = UDim2.fromOffset(window.Size.X.Offset, 0)
				window.BackgroundTransparency = 1
				setBlurEnabled(blur, false)
				stroke.Enabled = false
				icon.Visible = false
				title.Visible = false
				pin.Visible = false
				dotsbutton.Visible = false
			end
		end
		
		bindComponents(component, children)
		
		vape:Clean(clickgui:GetPropertyChangedSignal('Visible'):Connect(function()
			component:Update()
		end))
		
		dotsbutton.MouseEnter:Connect(function()
			if not children.Visible then
				dots.ImageColor3 = uipallet.Text
			end
		end)
		
		dotsbutton.MouseLeave:Connect(function()
			if not children.Visible then
				dots.ImageColor3 = color.Light(uipallet.Main, 0.37)
			end
		end)
		
		dotsbutton.MouseButton1Click:Connect(function()
			component:Expand(true)
		end)
		
		dotsbutton.MouseButton2Click:Connect(function()
			component:Expand(true)
		end)
		
		pin.MouseButton1Click:Connect(function()
			component:Pin()
		end)
		
		window.MouseButton2Click:Connect(function()
			component:Expand(true)
		end)
		
		windowlist:GetPropertyChangedSignal('AbsoluteContentSize'):Connect(function()
			if vape.ThreadFix then
				setthreadidentity(8)
			end
		
			children.CanvasSize = UDim2.fromOffset(0, windowlist.AbsoluteContentSize.Y / scale.Scale)
			if component.Expanded then
				window.Size = UDim2.fromOffset(window.Size.X.Offset, math.min(41 + windowlist.AbsoluteContentSize.Y / scale.Scale, 601))
			end
		end)
		
		component.Children = customchildren
		vape.Categories[props.Name] = component
		
		return component
	end,
	OverlayBar = function(props, children, api)
		local component = {
			Options = {},
			Type = 'OverlayBar'
		}
		
		local bar = Instance.new('Frame')
		bar.Name = 'Overlays'
		bar.Size = UDim2.fromOffset(220, 36)
		bar.BackgroundColor3 = uipallet.Main
		bar.BorderSizePixel = 0
		bar.Parent = children
		components.Divider(nil, bar)
		local button = Instance.new('ImageButton')
		button.AutoButtonColor = false
		button.BackgroundTransparency = 1
		button.Image = getvapeasset('pistonware/assets/new/overlays.png')
		button.ImageColor3 = color.Light(uipallet.Main, 0.37)
		button.Position = UDim2.new(1, -34, 0, 7)
		button.Size = UDim2.fromOffset(24, 24)
		button.Parent = bar
		addCorner(button, UDim.new(1, 0))
		addTooltip(button, 'Open overlays menu')
		local shadow = Instance.new('TextButton')
		shadow.AutoButtonColor = false
		shadow.BackgroundColor3 = Color3.new()
		shadow.BackgroundTransparency = 1
		shadow.ClipsDescendants = true
		shadow.Name = 'Shadow'
		shadow.Size = UDim2.new(1, 0, 1, -5)
		shadow.Text = ''
		shadow.Visible = false
		shadow.Parent = api.Object
		addCorner(shadow)
		local window = Instance.new('Frame')
		window.BackgroundColor3 = uipallet.Main
		window.Position = UDim2.fromScale(0, 1)
		window.Size = UDim2.fromOffset(220, 42)
		window.Parent = shadow
		addCorner(window)
		local icon = Instance.new('ImageLabel')
		icon.BackgroundTransparency = 1
		icon.Image = getvapeasset('pistonware/assets/new/overlayslarge.png')
		icon.ImageColor3 = uipallet.Text
		icon.Position = UDim2.fromOffset(10, 13)
		icon.Size = UDim2.fromOffset(14, 12)
		icon.Parent = window
		local title = Instance.new('TextLabel')
		title.BackgroundTransparency = 1
		title.FontFace = uipallet.Font
		title.Position = UDim2.fromOffset(36, 0)
		title.Size = UDim2.new(1, -36, 0, 38)
		title.Text = 'Overlays'
		title.TextColor3 = uipallet.Text
		title.TextSize = 15
		title.TextXAlignment = Enum.TextXAlignment.Left
		title.Parent = window
		local close = addCloseButton(window, false, UDim2.new(1, -35, 0, 7))
		local divider = Instance.new('Frame')
		divider.BackgroundColor3 = color.Light(uipallet.Main, 0.02)
		divider.BorderSizePixel = 0
		divider.Position = UDim2.fromOffset(0, 37)
		divider.Size = UDim2.new(1, 0, 0, 1)
		divider.Parent = window
		local childrentoggle = Instance.new('Frame')
		childrentoggle.BackgroundColor3 = uipallet.Main
		childrentoggle.BackgroundTransparency = 1
		childrentoggle.Position = UDim2.fromOffset(0, 38)
		childrentoggle.Parent = window
		local windowlist = Instance.new('UIListLayout')
		windowlist.HorizontalAlignment = Enum.HorizontalAlignment.Center
		windowlist.SortOrder = Enum.SortOrder.LayoutOrder
		windowlist.Parent = childrentoggle
		
		bindComponents(component, childrentoggle)
		
		button.MouseEnter:Connect(function()
			button.ImageColor3 = uipallet.Text
			tween:Tween(button, uipallet.Tween, {
				BackgroundTransparency = 0.9
			})
		end)
		
		button.MouseLeave:Connect(function()
			button.ImageColor3 = color.Light(uipallet.Main, 0.37)
			tween:Tween(button, uipallet.Tween, {
				BackgroundTransparency = 1
			})
		end)
		
		button.MouseButton1Click:Connect(function()
			shadow.Visible = true
			tween:Tween(shadow, uipallet.Tween, {
				BackgroundTransparency = 0.5
			})
		
			tween:Tween(window, uipallet.Tween, {
				Position = UDim2.new(0, 0, 1, -(window.Size.Y.Offset))
			})
		end)
		
		close.MouseButton1Click:Connect(function()
			tween:Tween(shadow, uipallet.Tween, {
				BackgroundTransparency = 1
			})
		
			tween:Tween(window, uipallet.Tween, {
				Position = UDim2.fromScale(0, 1)
			})
		
			task.delay(0.2, function()
				shadow.Visible = false
			end)
		end)
		
		shadow.MouseButton1Click:Connect(function()
			tween:Tween(shadow, uipallet.Tween, {
				BackgroundTransparency = 1
			})
		
			tween:Tween(window, uipallet.Tween, {
				Position = UDim2.fromScale(0, 1)
			})
		
			task.delay(0.2, function()
				shadow.Visible = false
			end)
		end)
		
		windowlist:GetPropertyChangedSignal('AbsoluteContentSize'):Connect(function()
			if vape.ThreadFix then
				setthreadidentity(8)
			end
		
			window.Size = UDim2.fromOffset(220, math.min(37 + windowlist.AbsoluteContentSize.Y / scale.Scale, 605))
			childrentoggle.Size = UDim2.fromOffset(220, window.Size.Y.Offset - 5)
		end)
		
		vape.Overlays = component
		
		return component
	end,
	SearchBar = function(props, children, api)
		local component = {
			Type = 'SearchBar'
		}
		
		local function listenProperty(src, dest, prop, obj)
			dest[prop] = src[prop]
			local connection = src:GetPropertyChangedSignal(prop):Connect(function()
				dest[prop] = src[prop]
			end)
		
			obj.Destroying:Once(function()
				connection:Disconnect()
			end)
		end
		
		local search = Instance.new('Frame')
		search.AnchorPoint = Vector2.new(0.5, 0)
		search.BackgroundColor3 = color.Dark(uipallet.Main, 0.02)
		search.Name = 'Search'
		search.Position = UDim2.new(0.5, 0, 0, 13)
		search.Size = UDim2.fromOffset(220, 37)
		search.Parent = clickgui
		component.Object = search
		addBlur(search)
		addCorner(search)
		local icon = Instance.new('ImageLabel')
		icon.BackgroundTransparency = 1
		icon.Image = getvapeasset('pistonware/assets/new/search.png')
		icon.ImageColor3 = color.Light(uipallet.Main, 0.37)
		icon.Position = UDim2.new(1, -25, 0, 11)
		icon.Size = UDim2.fromOffset(14, 14)
		icon.Parent = search
		local legiticon = Instance.new('ImageButton')
		legiticon.BackgroundTransparency = 1
		legiticon.Image = getvapeasset('pistonware/assets/new/legit_switch.png')
		legiticon.Name = 'Legit'
		legiticon.Position = UDim2.fromOffset(8, 11)
		legiticon.Size = UDim2.fromOffset(29, 16)
		legiticon.Parent = search
		listenProperty(vape.Categories.Main.Object.VapeLogo.V4Logo, legiticon, 'ImageColor3', legiticon)
		local legitdivider = Instance.new('Frame')
		legitdivider.BackgroundColor3 = color.Light(uipallet.Main, 0.14)
		legitdivider.BorderSizePixel = 0
		legitdivider.Name = 'LegitDivider'
		legitdivider.Position = UDim2.fromOffset(43, 13)
		legitdivider.Size = UDim2.fromOffset(2, 12)
		legitdivider.Parent = search
		local box = Instance.new('TextBox')
		box.BackgroundTransparency = 1
		box.ClearTextOnFocus = false
		box.FontFace = uipallet.Font
		box.PlaceholderText = ''
		box.Position = UDim2.fromOffset(50, 0)
		box.Size = UDim2.new(1, -50, 0, 37)
		box.Text = ''
		box.TextColor3 = uipallet.Text
		box.TextSize = 12
		box.TextXAlignment = Enum.TextXAlignment.Left
		box.Parent = search
		local children = Instance.new('ScrollingFrame')
		children.BackgroundTransparency = 1
		children.BorderSizePixel = 0
		children.CanvasSize = UDim2.new()
		children.Position = UDim2.fromOffset(0, 34)
		children.ScrollBarThickness = 2
		children.ScrollBarImageTransparency = 0.75
		children.Size = UDim2.new(1, 0, 1, -37)
		children.Parent = search
		local divider = Instance.new('Frame')
		divider.BackgroundColor3 = Color3.new(1, 1, 1)
		divider.BackgroundTransparency = 0.928
		divider.BorderSizePixel = 0
		divider.Position = UDim2.fromOffset(0, 33)
		divider.Size = UDim2.new(1, 0, 0, 1)
		divider.Visible = false
		divider.Parent = search
		local stroke = Instance.new('UIStroke')
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.Color = Color3.fromRGB(85, 85, 85)
		stroke.Transparency = 0.8
		stroke.Parent = search
		local windowlist = Instance.new('UIListLayout')
		windowlist.HorizontalAlignment = Enum.HorizontalAlignment.Center
		windowlist.SortOrder = Enum.SortOrder.LayoutOrder
		windowlist.Parent = children
		
		--[[
			Coalesced to one rebuild per frame.

			A rebuild destroys every result row and then CLONES the module button -- with its
			whole subtree -- for each remaining match, plus six property listeners apiece. On
			a single letter that is most of the module list, and the Text signal fires once
			per keystroke, so holding a key down or pasting a word queued a full rebuild for
			every character in it.

			The result only depends on the box's final text, so a burst of keystrokes inside
			one frame needs exactly one pass. task.defer runs at the end of the current
			resumption cycle and re-reads box.Text there, which is the newest value.
		]]
		local searchQueued = false
		local function rebuildSearch()
			for _, obj in children:GetChildren() do
				if obj:IsA('TextButton') then
					obj:Destroy()
				end
			end

			if box.Text == '' then return end

			for name, module in orderedModules(vape.ModuleOrder) do
				if name:lower():find(box.Text:lower()) then
					local button = module.Object:Clone()
					button.Bind:Destroy()
		
					button.MouseButton1Click:Connect(function()
						module:Toggle()
					end)
		
					button.MouseButton2Click:Connect(function()
						module.Object.Parent.Parent.Visible = true
						local frame = module.Object.Parent
						local highlight = Instance.new('Frame')
						highlight.Size = UDim2.fromScale(1, 1)
						highlight.BackgroundColor3 = Color3.new(1, 1, 1)
						highlight.BackgroundTransparency = 0.6
						highlight.BorderSizePixel = 0
						highlight.Parent = module.Object
		
						tween:Tween(highlight, TweenInfo.new(0.5), {
							BackgroundTransparency = 1
						})
						task.delay(0.5, highlight.Destroy, highlight)
						frame.CanvasPosition = Vector2.new(0, (module.Object.LayoutOrder * 40) - (math.min(frame.CanvasSize.Y.Offset, 600) / 2))
					end)
		
					for _, prop in {'Text', 'TextColor3', 'BackgroundColor3'} do
						listenProperty(module.Object, button, prop, button)
					end
		
					listenProperty(module.Object.UIGradient, button.UIGradient, 'Color', button)
					listenProperty(module.Object.UIGradient, button.UIGradient, 'Enabled', button)
					listenProperty(module.Object.Dots.Dots, button.Dots.Dots, 'ImageColor3', button)
		
					button.Parent = children
				end
			end
		end

		box:GetPropertyChangedSignal('Text'):Connect(function()
			if searchQueued then return end
			searchQueued = true

			task.defer(function()
				searchQueued = false
				rebuildSearch()
			end)
		end)

		children:GetPropertyChangedSignal('CanvasPosition'):Connect(function()
			divider.Visible = children.CanvasPosition.Y > 10 and children.Visible
		end)
		
		legiticon.MouseButton1Click:Connect(function()
			clickgui.Visible = false
			vape.Legit.Window.Visible = true
			vape.Legit.Window.Position = UDim2.new(0.5, -350, 0.5, -194)
		end)
		
		windowlist:GetPropertyChangedSignal('AbsoluteContentSize'):Connect(function()
			if vape.ThreadFix then
				setthreadidentity(8)
			end
		
			children.CanvasSize = UDim2.fromOffset(0, windowlist.AbsoluteContentSize.Y / scale.Scale)
			search.Size = UDim2.fromOffset(220, math.min(37 + windowlist.AbsoluteContentSize.Y / scale.Scale, 437))
		end)
		
		return component
	end,
	SettingsPane = function(props, children, api)
		local component = {
			Buttons = {},
			Options = {},
			Parent = api.Parent or children,
			Type = 'SettingsPane'
		}
		
		local pane = Instance.new('TextButton')
		pane.AutoButtonColor = false
		pane.BackgroundColor3 = props.Main and color.Dark(uipallet.Main, 0.02) or uipallet.Main
		pane.Size = UDim2.fromScale(1, 1)
		pane.Text = ''
		pane.Visible = false
		pane.Parent = component.Parent
		local title = Instance.new('TextLabel')
		title.BackgroundTransparency = 1
		title.FontFace = uipallet.Font
		title.Name = 'Title'
		title.Size = UDim2.new(1, -36, 0, 20)
		title.Position = UDim2.fromOffset(math.abs(title.Size.X.Offset), 11)
		title.Text = props.Name
		title.TextColor3 = uipallet.Text
		title.TextSize = 13
		title.TextXAlignment = Enum.TextXAlignment.Left
		title.Parent = pane
		local close = addCloseButton(pane, true)
		local back = Instance.new('ImageButton')
		back.BackgroundTransparency = 1
		back.Image = getvapeasset('pistonware/assets/new/backmini.png')
		back.ImageColor3 = color.Light(uipallet.Main, 0.37)
		back.Position = UDim2.fromOffset(12, 14)
		back.Size = UDim2.fromOffset(14, 14)
		back.Parent = pane
		addCorner(pane)
		local settingschildren = Instance.new('Frame')
		settingschildren.BackgroundColor3 = uipallet.Main
		settingschildren.BorderSizePixel = 0
		settingschildren.Name = 'Children'
		settingschildren.Position = UDim2.fromOffset(0, 41)
		settingschildren.Size = UDim2.new(1, 0, 1, -57)
		settingschildren.Parent = pane
		local divider = Instance.new('Frame')
		divider.BackgroundColor3 = Color3.new(1, 1, 1)
		divider.BackgroundTransparency = 0.928
		divider.BorderSizePixel = 0
		divider.Name = 'Divider'
		divider.Size = UDim2.new(1, 0, 0, 1)
		divider.Parent = settingschildren
		local listlayout = Instance.new('UIListLayout')
		listlayout.SortOrder = Enum.SortOrder.LayoutOrder
		listlayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		listlayout.Parent = settingschildren
		if props.Main then
			local versionlabel = Instance.new('TextLabel')
			versionlabel.BackgroundTransparency = 1
			versionlabel.FontFace = uipallet.Font
			versionlabel.Name = 'Version'
			versionlabel.Position = UDim2.new(0, 0, 1, -16)
			versionlabel.Size = UDim2.new(1, 0, 0, 16)
			versionlabel.Text = 'Pistonware '..vape.Version..' '
			versionlabel.TextColor3 = color.Dark(uipallet.Text, 0.43)
			versionlabel.TextSize = 10
			versionlabel.TextXAlignment = Enum.TextXAlignment.Right
			versionlabel.Parent = pane
		else
			api:CreateGUIButton({
				Name = props.Name,
				Function = function()
					pane.Visible = true
				end
			})
		end
		
		function component:Load(data)
			vape:LoadOptions(self, data)
		end
		
		function component:Save(data)
			data[props.Name] = vape:SaveOptions(self)
		end
		
		bindComponents(component, settingschildren)
		
		back.MouseEnter:Connect(function()
			back.ImageColor3 = uipallet.Text
		end)
		
		back.MouseLeave:Connect(function()
			back.ImageColor3 = color.Light(uipallet.Main, 0.37)
		end)
		
		back.MouseButton1Click:Connect(function()
			pane.Visible = false
		end)
		
		close.MouseButton1Click:Connect(function()
			pane.Visible = false
		end)
		
		listlayout:GetPropertyChangedSignal('AbsoluteContentSize'):Connect(function()
			if vape.ThreadFix then
				setthreadidentity(8)
			end
		
			pane.Size = UDim2.new(1, 0, 0, math.max(45 + listlayout.AbsoluteContentSize.Y, component.Parent.AbsoluteSize.Y) / scale.Scale)
		end)
		
		component.Object = pane
		vape.Settings[props.Name] = component
		
		return component
	end,
	Slider = function(props, children, api)
		local component = {
			Index = getTableSize(api.Options),
			Max = props.Max,
			Type = 'Slider',
			Value = props.Default or props.Min,
		}
		
		local slider = Instance.new('TextButton')
		slider.AutoButtonColor = false
		slider.BackgroundColor3 = color.Dark(children.BackgroundColor3, props.Darker and 0.02 or 0)
		slider.BorderSizePixel = 0
		slider.Size = UDim2.new(1, 0, 0, 50)
		slider.Text = ''
		slider.Visible = props.Visible == nil or props.Visible
		slider.Parent = children
		component.Object = slider
		addTooltip(slider, props.Tooltip)
		local title = Instance.new('TextLabel')
		title.BackgroundTransparency = 1
		title.FontFace = uipallet.Font
		title.Position = UDim2.fromOffset(10, 2)
		title.Size = UDim2.fromOffset(60, 30)
		title.Text = props.Name
		title.TextColor3 = color.Dark(uipallet.Text, 0.16)
		title.TextSize = 11
		title.TextXAlignment = Enum.TextXAlignment.Left
		title.Parent = slider
		local valuelabel = Instance.new('TextButton')
		valuelabel.BackgroundTransparency = 1
		valuelabel.FontFace = uipallet.Font
		valuelabel.Position = UDim2.new(1, -69, 0, 9)
		valuelabel.Size = UDim2.fromOffset(60, 15)
		valuelabel.Text = component.Value..(props.Suffix and ' '..(type(props.Suffix) == 'function' and props.Suffix(component.Value) or props.Suffix) or '')
		valuelabel.TextColor3 = color.Dark(uipallet.Text, 0.16)
		valuelabel.TextSize = 11
		valuelabel.TextXAlignment = Enum.TextXAlignment.Right
		valuelabel.Parent = slider
		local custombox = Instance.new('TextBox')
		custombox.BackgroundTransparency = 1
		custombox.ClearTextOnFocus = false
		custombox.FontFace = uipallet.Font
		custombox.Position = valuelabel.Position
		custombox.Size = valuelabel.Size
		custombox.Text = component.Value
		custombox.TextColor3 = color.Dark(uipallet.Text, 0.16)
		custombox.TextSize = 11
		custombox.TextXAlignment = Enum.TextXAlignment.Right
		custombox.Visible = false
		custombox.Parent = slider
		local holder = Instance.new('Frame')
		holder.BackgroundColor3 = color.Light(uipallet.Main, 0.034)
		holder.BorderSizePixel = 0
		holder.Position = UDim2.fromOffset(10, 37)
		holder.Size = UDim2.new(1, -20, 0, 2)
		holder.Parent = slider
		local fill = Instance.new('Frame')
		fill.BackgroundColor3 = Color3.fromHSV(vape.GUIColor.Hue, vape.GUIColor.Sat, vape.GUIColor.Value)
		fill.BorderSizePixel = 0
		fill.Size = UDim2.fromScale(math.clamp((component.Value - props.Min) / props.Max, 0.04, 0.96), 1)
		fill.Parent = holder
		local knobholder = Instance.new('Frame')
		knobholder.AnchorPoint = Vector2.new(0.5, 0.5)
		knobholder.BackgroundColor3 = slider.BackgroundColor3
		knobholder.BorderSizePixel = 0
		knobholder.Position = UDim2.fromScale(1, 0.5)
		knobholder.Size = UDim2.fromOffset(24, 4)
		knobholder.Parent = fill
		local knob = Instance.new('Frame')
		knob.AnchorPoint = Vector2.new(0.5, 0.5)
		knob.BackgroundColor3 = Color3.fromHSV(vape.GUIColor.Hue, vape.GUIColor.Sat, vape.GUIColor.Value)
		knob.Position = UDim2.fromScale(0.5, 0.5)
		knob.Size = UDim2.fromOffset(14, 14)
		knob.Parent = knobholder
		addCorner(knob, UDim.new(1, 0))
		props.Function = props.Function or function() end
		props.Decimal = props.Decimal or 1
		
		function component:Color(hue, sat, val, isRainbow)
			fill.BackgroundColor3 = isRainbow and Color3.fromHSV(vape:Color((hue - (self.Index * 0.075)) % 1)) or Color3.fromHSV(hue, sat, val)
			knob.BackgroundColor3 = fill.BackgroundColor3
		end
		
		function component:Load(data)
			local newValue = data.Value == data.Max and data.Max ~= self.Max and self.Max or data.Value
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
		
			tween:Tween(fill, uipallet.Tween, {
				Size = UDim2.fromScale(math.clamp(position or math.clamp(value / props.Max, 0, 1), 0.04, 0.96), 1)
			})
		
			if self.Value ~= value or wasReleased then
				self.Value = value
				valuelabel.Text = self.Value..(props.Suffix and ' '..(type(props.Suffix) == 'function' and props.Suffix(self.Value) or props.Suffix) or '')
				props.Function(value, wasReleased)
			end
		end
		
		slider.InputBegan:Connect(function(input)
			if
				(input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch)
				and (input.Position.Y - slider.AbsolutePosition.Y) > (20 * scale.Scale)
			then
				local newPosition = math.clamp((input.Position.X - holder.AbsolutePosition.X) / holder.AbsoluteSize.X, 0, 1)
				local lastPosition = newPosition
		
				local releaseConnection
				local moveConnection = inputService.InputChanged:Connect(function(newInput)
					if newInput.UserInputType == (input.UserInputType == Enum.UserInputType.MouseButton1 and Enum.UserInputType.MouseMovement or Enum.UserInputType.Touch) then
						local newPosition = math.clamp((newInput.Position.X - holder.AbsolutePosition.X) / holder.AbsoluteSize.X, 0, 1)
						component:SetValue(math.floor((props.Min + (props.Max - props.Min) * newPosition) * props.Decimal) / props.Decimal, newPosition)
						lastPosition = newPosition
					end
				end)
		
				releaseConnection = input.Changed:Connect(function()
					if input.UserInputState == Enum.UserInputState.End then
						moveConnection:Disconnect()
						releaseConnection:Disconnect()
						component:SetValue(component.Value, lastPosition, true)
					end
				end)
		
				component:SetValue(math.floor((props.Min + (props.Max - props.Min) * newPosition) * props.Decimal) / props.Decimal, newPosition)
			end
		end)
		
		slider.MouseEnter:Connect(function()
			tween:Tween(knob, uipallet.Tween, {
				Size = UDim2.fromOffset(16, 16)
			})
		end)
		
		slider.MouseLeave:Connect(function()
			tween:Tween(knob, uipallet.Tween, {
				Size = UDim2.fromOffset(14, 14)
			})
		end)
		
		valuelabel.MouseButton1Click:Connect(function()
			valuelabel.Visible = false
			custombox.Visible = true
			custombox.Text = component.Value
			custombox:CaptureFocus()
		end)
		
		custombox.FocusLost:Connect(function(enter)
			valuelabel.Visible = true
			custombox.Visible = false
		
			if enter and tonumber(custombox.Text) then
				component:SetValue(tonumber(custombox.Text), nil, true)
			end
		end)
		
		api.Options[props.Name] = component
		
		return component
	end,
	Targets = function(props, children, api)
		local component = {
			Index = getTableSize(api.Options),
			Type = 'Targets'
		}
		
		local targets = Instance.new('TextButton')
		targets.AutoButtonColor = false
		targets.BackgroundColor3 = color.Dark(children.BackgroundColor3, props.Darker and 0.02 or 0)
		targets.BorderSizePixel = 0
		targets.Size = UDim2.new(1, 0, 0, 50)
		targets.Text = ''
		targets.Visible = props.Visible == nil or props.Visible
		targets.Parent = children
		component.Object = targets
		addTooltip(targets, props.Tooltip)
		local holder = Instance.new('Frame')
		holder.BackgroundColor3 = color.Light(uipallet.Main, 0.034)
		holder.Position = UDim2.fromOffset(10, 4)
		holder.Size = UDim2.new(1, -20, 1, -9)
		holder.Parent = targets
		addCorner(holder, UDim.new(0, 4))
		local button = Instance.new('TextButton')
		button.AutoButtonColor = false
		button.BackgroundColor3 = uipallet.Main
		button.Position = UDim2.fromOffset(1, 1)
		button.Size = UDim2.new(1, -2, 1, -2)
		button.Text = ''
		button.Parent = holder
		local title = Instance.new('TextLabel')
		title.BackgroundTransparency = 1
		title.FontFace = uipallet.Font
		title.Position = UDim2.fromOffset(5, 6)
		title.Size = UDim2.new(1, -5, 0, 15)
		title.Text = 'Target:'
		title.TextColor3 = color.Dark(uipallet.Text, 0.16)
		title.TextSize = 15
		title.TextTruncate = Enum.TextTruncate.AtEnd
		title.TextXAlignment = Enum.TextXAlignment.Left
		title.Parent = button
		local items = Instance.new('TextLabel')
		items.BackgroundTransparency = 1
		items.FontFace = uipallet.Font
		items.Position = UDim2.fromOffset(5, 21)
		items.Size = UDim2.new(1, -5, 0, 15)
		items.Text = 'Ignore none'
		items.TextColor3 = color.Dark(uipallet.Text, 0.16)
		items.TextSize = 11
		items.TextTruncate = Enum.TextTruncate.AtEnd
		items.TextXAlignment = Enum.TextXAlignment.Left
		items.Parent = button
		addCorner(button, UDim.new(0, 4))
		local iconholder = Instance.new('Frame')
		iconholder.BackgroundTransparency = 1
		iconholder.Position = UDim2.fromOffset(52, 8)
		iconholder.Size = UDim2.fromOffset(65, 12)
		iconholder.Parent = button
		local layout = Instance.new('UIListLayout')
		layout.FillDirection = Enum.FillDirection.Horizontal
		layout.Padding = UDim.new(0, 6)
		layout.Parent = iconholder
		local targetswindow = Instance.new('TextButton')
		targetswindow.AutoButtonColor = false
		targetswindow.BackgroundColor3 = uipallet.Main
		targetswindow.BorderSizePixel = 0
		targetswindow.Position = UDim2.fromOffset(456, 139)
		targetswindow.Size = UDim2.fromOffset(220, 145)
		targetswindow.Text = ''
		targetswindow.Visible = false
		targetswindow.Parent = clickgui
		component.Window = targetswindow
		addBlur(targetswindow)
		addCorner(targetswindow)
		local icon = Instance.new('ImageLabel')
		icon.BackgroundTransparency = 1
		icon.Image = getvapeasset('pistonware/assets/new/aim.png')
		icon.Position = UDim2.fromOffset(10, 15)
		icon.Size = UDim2.fromOffset(18, 12)
		icon.Parent = targetswindow
		local windowtitle = Instance.new('TextLabel')
		windowtitle.BackgroundTransparency = 1
		windowtitle.FontFace = uipallet.Font
		windowtitle.Size = UDim2.new(1, -36, 0, 20)
		windowtitle.Position = UDim2.fromOffset(math.abs(windowtitle.Size.X.Offset), 11)
		windowtitle.Text = 'Target settings'
		windowtitle.TextColor3 = uipallet.Text
		windowtitle.TextSize = 13
		windowtitle.TextXAlignment = Enum.TextXAlignment.Left
		windowtitle.Parent = targetswindow
		local close = addCloseButton(targetswindow)
		props.Function = props.Function or function() end
		
		function component:Color(hue, sat, val, isRainbow)
			if targetswindow.Visible then
				holder.BackgroundColor3 = isRainbow and Color3.fromHSV(vape:Color((hue - (self.Index * 0.075)) % 1)) or Color3.fromHSV(hue, sat, val)
			end
		
			if self.Players.Enabled then
				tween:Cancel(self.Players.Object.Frame)
				self.Players.Object.Frame.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
			end
		
			if self.NPCs.Enabled then
				tween:Cancel(self.NPCs.Object.Frame)
				self.NPCs.Object.Frame.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
			end
		
			if self.Invisible.Enabled then
				tween:Cancel(self.Invisible.Object.Holder)
				self.Invisible.Object.Holder.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
			end
		
			if self.Walls.Enabled then
				tween:Cancel(self.Walls.Object.Holder)
				self.Walls.Object.Holder.BackgroundColor3 = Color3.fromHSV(hue, sat, val)
			end
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
			local newText = {}
		
			if self.Players.Enabled then
				table.insert(newText, 'Players')
			end
		
			if self.NPCs.Enabled then
				table.insert(newText, 'NPCs')
			end
		
			title.Text = 'Target: '..(#newText > 0 and table.concat(newText, ', ') or 'Nothing')
			title.TextColor3 = #newText > 0 and uipallet.Text or Color3.fromRGB(255, 90, 90)
		end
		
		component.Players = components.TargetsButton({
			Position = UDim2.fromOffset(11, 45),
			Icon = getvapeasset('pistonware/assets/new/players.png'),
			IconSize = UDim2.fromOffset(16, 16),
			IconParent = iconholder,
			Targets = component,
			Tooltip = 'Target players',
			Function = props.Function
		}, targetswindow, iconholder)
		
		component.NPCs = components.TargetsButton({
			Position = UDim2.fromOffset(112, 45),
			Icon = getvapeasset('pistonware/assets/new/npcs.png'),
			IconSize = UDim2.fromOffset(12, 16),
			IconParent = iconholder,
			Targets = component,
			Tooltip = 'Target NPCs',
			Function = props.Function
		}, targetswindow, iconholder)
		
		component.Invisible = components.Toggle({
			Name = 'Ignore invisible',
			Function = function()
				local newText = {}
		
				if component.Invisible.Enabled then
					table.insert(newText, 'invisible')
				end
		
				if component.Walls.Enabled then
					table.insert(newText, 'behind walls')
				end
		
				items.Text = 'Ignore '..(#newText > 0 and table.concat(newText, ', ') or 'none')
				props.Function()
			end
		}, targetswindow, {Options = {}})
		component.Invisible.Object.Position = UDim2.fromOffset(0, 81)
		
		component.Walls = components.Toggle({
			Name = 'Ignore behind walls',
			Function = function()
				local newText = {}
		
				if component.Invisible.Enabled then
					table.insert(newText, 'invisible')
				end
		
				if component.Walls.Enabled then
					table.insert(newText, 'behind walls')
				end
		
				items.Text = 'Ignore '..(#newText > 0 and table.concat(newText, ', ') or 'none')
				props.Function()
			end
		}, targetswindow, {Options = {}})
		component.Walls.Object.Position = UDim2.fromOffset(0, 111)
		
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
		
		close.MouseButton1Click:Connect(function()
			targetswindow.Visible = false
		end)
		
		button.MouseButton1Click:Connect(function()
			targetswindow.Visible = not targetswindow.Visible
			tween:Cancel(holder)
		
			holder.BackgroundColor3 = targetswindow.Visible and Color3.fromHSV(vape.GUIColor.Hue, vape.GUIColor.Sat, vape.GUIColor.Value) or color.Light(uipallet.Main, 0.37)
		end)
		
		targets.MouseEnter:Connect(function()
			if not targetswindow.Visible then
				tween:Tween(holder, uipallet.Tween, {
					BackgroundColor3 = color.Light(uipallet.Main, 0.37)
				})
			end
		end)
		
		targets.MouseLeave:Connect(function()
			if not targetswindow.Visible then
				tween:Tween(holder, uipallet.Tween, {
					BackgroundColor3 = color.Light(uipallet.Main, 0.034)
				})
			end
		end)
		
		targets:GetPropertyChangedSignal('AbsolutePosition'):Connect(function()
			if vape.ThreadFix then
				setthreadidentity(8)
			end
		
			local actualPosition = (targets.AbsolutePosition + Vector2.new(0, 60)) / scale.Scale
			targetswindow.Position = UDim2.fromOffset(actualPosition.X + 223, actualPosition.Y)
		end)
		
		api.Options.Targets = component
		
		return component
	end,
	TargetsButton = function(props, children, api)
		local component = {
			Enabled = false,
			Type = 'TargetsButton'
		}
		
		local targetsbutton = Instance.new('TextButton')
		targetsbutton.AutoButtonColor = false
		targetsbutton.BackgroundColor3 = color.Light(uipallet.Main, 0.05)
		targetsbutton.Position = props.Position
		targetsbutton.Size = UDim2.fromOffset(98, 31)
		targetsbutton.Text = ''
		targetsbutton.Visible = props.Visible == nil or props.Visible
		targetsbutton.Parent = children
		component.Object = targetsbutton
		addCorner(targetsbutton)
		addTooltip(targetsbutton, props.Tooltip)
		local holder = Instance.new('Frame')
		holder.BackgroundColor3 = uipallet.Main
		holder.Position = UDim2.fromOffset(1, 1)
		holder.Size = UDim2.new(1, -2, 1, -2)
		holder.Parent = targetsbutton
		addCorner(holder)
		local icon = Instance.new('ImageLabel')
		icon.AnchorPoint = Vector2.new(0.5, 0.5)
		icon.BackgroundTransparency = 1
		icon.Image = props.Icon
		icon.ImageColor3 = color.Light(uipallet.Main, 0.37)
		icon.Position = UDim2.fromScale(0.5, 0.5)
		icon.Size = props.IconSize
		icon.Parent = holder
		props.Function = props.Function or function() end
		
		function component:Toggle()
			self.Enabled = not self.Enabled
		
			tween:Tween(holder, uipallet.Tween, {
				BackgroundColor3 = self.Enabled and Color3.fromHSV(vape.GUIColor.Hue, vape.GUIColor.Sat, vape.GUIColor.Value) or uipallet.Main
			})
		
			tween:Tween(icon, uipallet.Tween, {
				ImageColor3 = self.Enabled and Color3.new(1, 1, 1) or color.Light(uipallet.Main, 0.37)
			})
		
			props.Targets:UpdateText()
			props.Function(self.Enabled)
		end
		
		targetsbutton.MouseEnter:Connect(function()
			if not component.Enabled then
				tween:Tween(holder, uipallet.Tween, {
					BackgroundColor3 = Color3.fromHSV(vape.GUIColor.Hue, vape.GUIColor.Sat, vape.GUIColor.Value - 0.25)
				})
		
				tween:Tween(icon, uipallet.Tween, {
					ImageColor3 = Color3.new(1, 1, 1)
				})
			end
		end)
		
		targetsbutton.MouseLeave:Connect(function()
			if not component.Enabled then
				tween:Tween(holder, uipallet.Tween, {
					BackgroundColor3 = uipallet.Main
				})
		
				tween:Tween(icon, uipallet.Tween, {
					ImageColor3 = color.Light(uipallet.Main, 0.37)
				})
			end
		end)
		
		targetsbutton.MouseButton1Click:Connect(function()
			component:Toggle()
		end)
		
		return component
	end,
	TextBox = function(props, children, api)
		local component = {
			Index = 0,
			Type = 'TextBox',
			Value = props.Default or ''
		}
		
		local textbox = Instance.new('TextButton')
		textbox.AutoButtonColor = false
		textbox.BackgroundColor3 = color.Dark(children.BackgroundColor3, props.Darker and 0.02 or 0)
		textbox.BorderSizePixel = 0
		textbox.Size = UDim2.new(1, 0, 0, 58)
		textbox.Text = ''
		textbox.Visible = props.Visible == nil or props.Visible
		textbox.Parent = children
		component.Object = textbox
		addTooltip(textbox, props.Tooltip)
		local title = Instance.new('TextLabel')
		title.BackgroundTransparency = 1
		title.FontFace = uipallet.Font
		title.Position = UDim2.fromOffset(10, 3)
		title.Size = UDim2.new(1, -10, 0, 20)
		title.Text = props.Name
		title.TextColor3 = uipallet.Text
		title.TextSize = 12
		title.TextXAlignment = Enum.TextXAlignment.Left
		title.Parent = textbox
		local holder = Instance.new('Frame')
		holder.BackgroundColor3 = color.Light(uipallet.Main, 0.02)
		holder.Position = UDim2.fromOffset(10, 23)
		holder.Size = UDim2.new(1, -20, 0, 29)
		holder.Parent = textbox
		addCorner(holder, UDim.new(0, 4))
		local inputbox = Instance.new('TextBox')
		inputbox.BackgroundTransparency = 1
		inputbox.ClearTextOnFocus = false
		inputbox.FontFace = uipallet.Font
		inputbox.PlaceholderColor3 = color.Dark(uipallet.Text, 0.31)
		inputbox.PlaceholderText = props.Placeholder or 'Click to set'
		inputbox.Position = UDim2.fromOffset(8, 0)
		inputbox.Size = UDim2.new(1, -8, 1, 0)
		inputbox.Text = props.Default or ''
		inputbox.TextColor3 = color.Dark(uipallet.Text, 0.16)
		inputbox.TextSize = 12
		inputbox.TextXAlignment = Enum.TextXAlignment.Left
		inputbox.Parent = holder
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
		end
		
		textbox.MouseButton1Click:Connect(function()
			inputbox:CaptureFocus()
		end)
		
		inputbox.FocusLost:Connect(function(enter)
			component:SetValue(inputbox.Text, enter)
		end)
		
		inputbox:GetPropertyChangedSignal('Text'):Connect(function()
			component:SetValue(inputbox.Text)
		end)
		
		api.Options[props.Name] = component
		
		return component
	end,
	TextList = function(props, children, api)
		local component = {
			Index = getTableSize(api.Options),
			--[[ Cloned, not referenced. `props.Default` is the module's own default table, and
			assigning it directly made List, ListEnabled and the default all the SAME table --
			so editing the list in one module mutated the shared default, and every other
			TextList built from it inherited the edit. Worse, it persisted: the corrupted
			default is what got saved, so the damage survived reinjects. ]]
			List = props.Default and table.clone(props.Default) or {},
			ListEnabled = props.Default and table.clone(props.Default) or {},
			Objects = {},
			Type = 'TextList',
			Window = {Visible = false}
		}
		
		props.Color = props.Color or Color3.fromRGB(5, 134, 105)
		local textlist = Instance.new('TextButton')
		textlist.AutoButtonColor = false
		textlist.BackgroundColor3 = color.Dark(children.BackgroundColor3, props.Darker and 0.02 or 0)
		textlist.BorderSizePixel = 0
		textlist.Size = UDim2.new(1, 0, 0, 50)
		textlist.Text = ''
		textlist.Visible = props.Visible == nil or props.Visible
		textlist.Parent = children
		component.Object = textlist
		addTooltip(textlist, props.Tooltip)
		local holder = Instance.new('Frame')
		holder.BackgroundColor3 = color.Light(uipallet.Main, 0.034)
		holder.Position = UDim2.fromOffset(10, 4)
		holder.Size = UDim2.new(1, -20, 1, -9)
		holder.Parent = textlist
		addCorner(holder, UDim.new(0, 4))
		local button = Instance.new('TextButton')
		button.AutoButtonColor = false
		button.BackgroundColor3 = uipallet.Main
		button.Position = UDim2.fromOffset(1, 1)
		button.Size = UDim2.new(1, -2, 1, -2)
		button.Text = ''
		button.Parent = holder
		local icon = Instance.new('ImageLabel')
		icon.BackgroundTransparency = 1
		icon.Image = getvapeasset('pistonware/assets/new/allowediconmini.png')
		icon.Position = UDim2.fromOffset(10, 14)
		icon.Size = UDim2.fromOffset(14, 12)
		icon.Parent = button
		local title = Instance.new('TextLabel')
		title.BackgroundTransparency = 1
		title.FontFace = uipallet.Font
		title.Position = UDim2.fromOffset(35, 6)
		title.Size = UDim2.new(1, -35, 0, 15)
		title.Text = props.Name
		title.TextColor3 = color.Dark(uipallet.Text, 0.16)
		title.TextSize = 15
		title.TextTruncate = Enum.TextTruncate.AtEnd
		title.TextXAlignment = Enum.TextXAlignment.Left
		title.Parent = button
		local amount = Instance.fromExisting(title)
		amount.Position = UDim2.fromOffset(0, 6)
		amount.Size = UDim2.new(1, -13, 0, 15)
		amount.Text = '0'
		amount.TextXAlignment = Enum.TextXAlignment.Right
		amount.Parent = button
		local items = Instance.fromExisting(title)
		items.Position = UDim2.fromOffset(35, 21)
		items.Text = 'None'
		items.TextColor3 = color.Dark(uipallet.Text, 0.43)
		items.TextSize = 11
		items.Parent = button
		addCorner(button, UDim.new(0, 4))
		local textlistwindow = Instance.new('TextButton')
		textlistwindow.AutoButtonColor = false
		textlistwindow.BackgroundColor3 = uipallet.Main
		textlistwindow.BorderSizePixel = 0
		textlistwindow.Position = UDim2.fromOffset(456, 227)
		textlistwindow.Size = UDim2.fromOffset(220, 85)
		textlistwindow.Text = ''
		textlistwindow.Visible = false
		textlistwindow.Parent = api.Legit and vape.Legit.Window or clickgui
		component.Window = textlistwindow
		addBlur(textlistwindow)
		addCorner(textlistwindow)
		local icon = Instance.new('ImageLabel')
		icon.BackgroundTransparency = 1
		icon.Image = getvapeasset('pistonware/assets/new/allowedicon.png')
		icon.Position = UDim2.fromOffset(10, 13)
		icon.Size = UDim2.fromOffset(19, 16)
		icon.Parent = textlistwindow
		local title = Instance.new('TextLabel')
		title.BackgroundTransparency = 1
		title.FontFace = uipallet.Font
		title.Position = UDim2.fromOffset(36, 11)
		title.Size = UDim2.new(1, -36, 0, 20)
		title.Text = props.Name
		title.TextColor3 = uipallet.Text
		title.TextSize = 13
		title.TextXAlignment = Enum.TextXAlignment.Left
		title.Parent = textlistwindow
		local close = addCloseButton(textlistwindow)
		local boxholder = Instance.new('Frame')
		boxholder.BackgroundColor3 = color.Light(uipallet.Main, 0.02)
		boxholder.Position = UDim2.fromOffset(10, 45)
		boxholder.Size = UDim2.fromOffset(200, 31)
		boxholder.Parent = textlistwindow
		addCorner(boxholder)
		local boxinner = Instance.new('Frame')
		boxinner.BackgroundColor3 = color.Dark(uipallet.Main, 0.02)
		boxinner.Position = UDim2.fromOffset(1, 1)
		boxinner.Size = UDim2.new(1, -2, 1, -2)
		boxinner.Parent = boxholder
		addCorner(boxinner)
		local textbox = Instance.new('TextBox')
		textbox.BackgroundTransparency = 1
		textbox.ClearTextOnFocus = false
		textbox.FontFace = uipallet.Font
		textbox.PlaceholderText = props.Placeholder or 'Add entry...'
		textbox.PlaceholderColor3 = Color3.new(0.8, 0.8, 0.8)
		textbox.Position = UDim2.fromOffset(10, 0)
		textbox.Size = UDim2.new(1, -35, 1, 0)
		textbox.Text = ''
		textbox.TextColor3 = Color3.new(1, 1, 1)
		textbox.TextSize = 13
		textbox.TextXAlignment = Enum.TextXAlignment.Left
		textbox.Parent = boxholder
		local add = Instance.new('ImageButton')
		add.BackgroundTransparency = 1
		add.Image = getvapeasset('pistonware/assets/new/add.png')
		add.ImageColor3 = props.Color
		add.ImageTransparency = 0.3
		add.Position = UDim2.new(1, -26, 0, 8)
		add.Size = UDim2.fromOffset(16, 16)
		add.Parent = boxholder
		props.Function = props.Function or function() end
		
		function component:Color(hue, sat, val, isRainbow)
			if textlistwindow.Visible then
				holder.BackgroundColor3 = isRainbow and Color3.fromHSV(vape:Color((hue - (self.Index * 0.075)) % 1)) or Color3.fromHSV(hue, sat, val)
			end
		end
		
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
			for _, v in self.Objects do
				v:Destroy()
			end
			table.clear(self.Objects)
			textlistwindow.Size = UDim2.fromOffset(220, 85 + (#self.List * 35))
			amount.Text = #self.List
			items.Text = #self.ListEnabled > 0 and table.concat(self.ListEnabled, ', ') or 'None'
		
			for index, value in self.List do
				local isEnabled = table.find(self.ListEnabled, value)
				local obj = Instance.new('TextButton')
				obj.AutoButtonColor = false
				obj.BackgroundColor3 = color.Light(uipallet.Main, 0.02)
				obj.Position = UDim2.fromOffset(10, 47 + (index * 35))
				obj.Size = UDim2.fromOffset(200, 31)
				obj.Text = ''
				obj.Parent = textlistwindow
				addCorner(obj)
				local bkg = Instance.new('Frame')
				bkg.BackgroundColor3 = uipallet.Main
				bkg.Position = UDim2.fromOffset(1, 1)
				bkg.Size = UDim2.new(1, -2, 1, -2)
				bkg.Visible = false
				bkg.Parent = obj
				addCorner(bkg)
				local dot = Instance.new('Frame')
				dot.BackgroundColor3 = isEnabled and props.Color or color.Light(uipallet.Main, 0.37)
				dot.Position = UDim2.fromOffset(10, 12)
				dot.Size = UDim2.fromOffset(10, 11)
				dot.Parent = obj
				addCorner(dot, UDim.new(1, 0))
				local dotin = dot:Clone()
				dotin.BackgroundColor3 = isEnabled and props.Color or color.Light(uipallet.Main, 0.02)
				dotin.Position = UDim2.fromOffset(1, 1)
				dotin.Size = UDim2.fromOffset(8, 9)
				dotin.Parent = dot
				local label = Instance.new('TextLabel')
				label.BackgroundTransparency = 1
				label.FontFace = uipallet.Font
				label.Position = UDim2.fromOffset(30, 0)
				label.Size = UDim2.new(1, -30, 1, 0)
				label.Text = value
				label.TextColor3 = color.Dark(uipallet.Text, 0.16)
				label.TextSize = 15
				label.TextXAlignment = Enum.TextXAlignment.Left
				label.Parent = obj
				local close = Instance.new('ImageButton')
				close.AutoButtonColor = false
				close.BackgroundColor3 = Color3.new(1, 1, 1)
				close.BackgroundTransparency = 1
				close.Image = getvapeasset('pistonware/assets/new/closetiny.png')
				close.ImageColor3 = color.Light(uipallet.Text, 0.2)
				close.ImageTransparency = 0.5
				close.Position = UDim2.new(1, -27, 0, 8)
				close.Size = UDim2.fromOffset(18, 17)
				close.Parent = obj
				addCorner(close, UDim.new(1, 0))
		
				close.MouseEnter:Connect(function()
					close.ImageTransparency = 0.3
					tween:Tween(close, uipallet.Tween, {
						BackgroundTransparency = 0.6
					})
				end)
		
				close.MouseLeave:Connect(function()
					close.ImageTransparency = 0.5
					tween:Tween(close, uipallet.Tween, {
						BackgroundTransparency = 1
					})
				end)
		
				close.MouseButton1Click:Connect(function()
					self:ChangeValue(value)
				end)
		
				obj.MouseEnter:Connect(function()
					bkg.Visible = true
				end)
		
				obj.MouseLeave:Connect(function()
					bkg.Visible = false
				end)
		
				obj.MouseButton1Click:Connect(function()
					local index = table.find(self.ListEnabled, value)
					if index then
						table.remove(self.ListEnabled, index)
						dot.BackgroundColor3 = color.Light(uipallet.Main, 0.37)
						dotin.BackgroundColor3 = color.Light(uipallet.Main, 0.02)
					else
						table.insert(self.ListEnabled, value)
						dot.BackgroundColor3 = props.Color
						dotin.BackgroundColor3 = props.Color
					end
		
					items.Text = #self.ListEnabled > 0 and table.concat(self.ListEnabled, ', ') or 'None'
					props.Function()
				end)
		
				--[[ `object` was an undeclared global here (nil); the local built above is `obj`.
				table.insert with nil meant self.Objects stayed empty, so nothing could find
				or clean up the entries it was supposed to be tracking. ]]
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
		
		add.MouseEnter:Connect(function()
			add.ImageTransparency = 0
		end)
		
		add.MouseLeave:Connect(function()
			add.ImageTransparency = 0.3
		end)
		
		add.MouseButton1Click:Connect(function()
			if not table.find(component.List, textbox.Text) then
				component:ChangeValue(textbox.Text)
				textbox.Text = ''
			end
		end)
		
		textbox.FocusLost:Connect(function(enter)
			if enter and not table.find(component.List, textbox.Text) then
				component:ChangeValue(textbox.Text)
				textbox.Text = ''
			end
		end)
		
		textbox.MouseEnter:Connect(function()
			tween:Tween(boxholder, uipallet.Tween, {
				BackgroundColor3 = color.Light(uipallet.Main, 0.14)
			})
		end)
		
		textbox.MouseLeave:Connect(function()
			tween:Tween(boxholder, uipallet.Tween, {
				BackgroundColor3 = color.Light(uipallet.Main, 0.02)
			})
		end)
		
		close.MouseButton1Click:Connect(function()
			textlistwindow.Visible = false
		end)
		
		button.MouseButton1Click:Connect(function()
			textlistwindow.Visible = not textlistwindow.Visible
		
			tween:Cancel(holder)
			holder.BackgroundColor3 = textlistwindow.Visible and Color3.fromHSV(vape.GUIColor.Hue, vape.GUIColor.Sat, vape.GUIColor.Value) or color.Light(uipallet.Main, 0.37)
		end)
		
		textlist.MouseEnter:Connect(function()
			if not textlistwindow.Visible then
				tween:Tween(holder, uipallet.Tween, {
					BackgroundColor3 = color.Light(uipallet.Main, 0.37)
				})
			end
		end)
		
		textlist.MouseLeave:Connect(function()
			if not textlistwindow.Visible then
				tween:Tween(holder, uipallet.Tween, {
					BackgroundColor3 = color.Light(uipallet.Main, 0.034)
				})
			end
		end)
		
		textlist:GetPropertyChangedSignal('AbsolutePosition'):Connect(function()
			if vape.ThreadFix then
				setthreadidentity(8)
			end
		
			local actualPosition = (textlist.AbsolutePosition - (api.Legit and vape.Legit.Window.AbsolutePosition or -guiService:GetGuiInset())) / scale.Scale
			textlistwindow.Position = UDim2.fromOffset(actualPosition.X + 223, actualPosition.Y)
		end)
		
		if props.Default then
			component:ChangeValue()
		end
		
		api.Options[props.Name] = component
		
		return component
	end,
	Toggle = function(props, children, api)
		local component = {
			Enabled = false,
			Index = getTableSize(api.Options),
			Name = props.Name,
			Type = 'Toggle'
		}
		
		local isHover = false
		local toggle = Instance.new('TextButton')
		toggle.AutoButtonColor = false
		toggle.BackgroundColor3 = color.Dark(children.BackgroundColor3, props.Darker and 0.02 or 0)
		toggle.BorderSizePixel = 0
		toggle.FontFace = uipallet.Font
		toggle.Size = UDim2.new(1, 0, 0, 30)
		toggle.Text = '          '..props.Name
		toggle.TextColor3 = color.Dark(uipallet.Text, 0.16)
		toggle.TextSize = 14
		toggle.TextXAlignment = Enum.TextXAlignment.Left
		toggle.Visible = props.Visible == nil or props.Visible
		toggle.Parent = children
		component.Object = toggle
		addTooltip(toggle, props.Tooltip)
		local holder = Instance.new('Frame')
		holder.BackgroundColor3 = color.Light(uipallet.Main, 0.14)
		holder.Name = 'Holder'
		holder.Position = UDim2.new(1, -30, 0, 9)
		holder.Size = UDim2.fromOffset(22, 12)
		holder.Parent = toggle
		addCorner(holder, UDim.new(1, 0))
		local knob = Instance.new('Frame')
		knob.BackgroundColor3 = uipallet.Main
		knob.Position = UDim2.fromOffset(2, 2)
		knob.Size = UDim2.fromOffset(8, 8)
		knob.Parent = holder
		addCorner(knob, UDim.new(1, 0))
		props.Function = props.Function or function() end
		
		function component:Color(hue, sat, val, isRainbow)
			if self.Enabled then
				tween:Cancel(holder)
				holder.BackgroundColor3 = isRainbow and Color3.fromHSV(vape:Color((hue - (self.Index * 0.075)) % 1)) or Color3.fromHSV(hue, sat, val)
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
			local isRainbow = vape.GUIColor.Rainbow and vape.RainbowMode.Value ~= 'Retro'
			self.Enabled = not self.Enabled
		
			tween:Tween(holder, uipallet.Tween, {
				BackgroundColor3 = self.Enabled and (isRainbow and Color3.fromHSV(vape:Color((vape.GUIColor.Hue - (self.Index * 0.075)) % 1)) or Color3.fromHSV(vape.GUIColor.Hue, vape.GUIColor.Sat, vape.GUIColor.Value)) or (isHover and color.Light(uipallet.Main, 0.37) or color.Light(uipallet.Main, 0.14))
			})
		
			tween:Tween(knob, uipallet.Tween, {
				Position = UDim2.fromOffset(self.Enabled and 12 or 2, 2)
			})
		
			props.Function(self.Enabled)
		end
		
		toggle.MouseEnter:Connect(function()
			isHover = true
		
			if not component.Enabled then
				tween:Tween(holder, uipallet.Tween, {
					BackgroundColor3 = color.Light(uipallet.Main, 0.37)
				})
			end
		end)
		
		toggle.MouseLeave:Connect(function()
			isHover = false
		
			if not component.Enabled then
				tween:Tween(holder, uipallet.Tween, {
					BackgroundColor3 = color.Light(uipallet.Main, 0.14)
				})
			end
		end)
		
		toggle.MouseButton1Click:Connect(function()
			component:Toggle()
		end)
		
		if props.Default then
			component:Toggle()
		end
		
		api.Options[props.Name] = component
		
		return component
	end,
	TwoSlider = function(props, children, api)
		local component = {
			Index = getTableSize(api.Options),
			Max = props.Max,
			Type = 'TwoSlider',
			ValueMin = props.DefaultMin or props.Min,
			ValueMax = props.DefaultMax or 10
		}
		
		local twoslider = Instance.new('TextButton')
		twoslider.AutoButtonColor = false
		twoslider.BackgroundColor3 = color.Dark(children.BackgroundColor3, props.Darker and 0.02 or 0)
		twoslider.BorderSizePixel = 0
		twoslider.Size = UDim2.new(1, 0, 0, 50)
		twoslider.Text = ''
		twoslider.Visible = props.Visible == nil or props.Visible
		twoslider.Parent = children
		component.Object = twoslider
		addTooltip(twoslider, props.Tooltip)
		local title = Instance.new('TextLabel')
		title.BackgroundTransparency = 1
		title.FontFace = uipallet.Font
		title.Position = UDim2.fromOffset(10, 2)
		title.Size = UDim2.fromOffset(60, 30)
		title.Text = props.Name
		title.TextColor3 = color.Dark(uipallet.Text, 0.16)
		title.TextSize = 11
		title.TextXAlignment = Enum.TextXAlignment.Left
		title.Parent = twoslider
		local maxvalue = Instance.new('TextButton')
		maxvalue.BackgroundTransparency = 1
		maxvalue.FontFace = uipallet.Font
		maxvalue.Position = UDim2.new(1, -69, 0, 9)
		maxvalue.Size = UDim2.fromOffset(60, 15)
		maxvalue.Text = component.ValueMax
		maxvalue.TextColor3 = color.Dark(uipallet.Text, 0.16)
		maxvalue.TextSize = 11
		maxvalue.TextXAlignment = Enum.TextXAlignment.Right
		maxvalue.Parent = twoslider
		local minvalue = maxvalue:Clone()
		minvalue.Position = UDim2.new(1, -125, 0, 9)
		minvalue.Text = component.ValueMin
		minvalue.Parent = twoslider
		local custommax = Instance.new('TextBox')
		custommax.BackgroundTransparency = 1
		custommax.ClearTextOnFocus = false
		custommax.FontFace = uipallet.Font
		custommax.Position = maxvalue.Position
		custommax.Size = UDim2.fromOffset(60, 15)
		custommax.Text = component.ValueMax
		custommax.TextColor3 = color.Dark(uipallet.Text, 0.16)
		custommax.TextSize = 11
		custommax.TextXAlignment = Enum.TextXAlignment.Right
		custommax.Visible = false
		custommax.Parent = twoslider
		local custommin = custommax:Clone()
		custommin.Position = minvalue.Position
		custommin.Parent = twoslider
		local holder = Instance.new('Frame')
		holder.BackgroundColor3 = color.Light(uipallet.Main, 0.034)
		holder.BorderSizePixel = 0
		holder.Position = UDim2.fromOffset(10, 37)
		holder.Size = UDim2.new(1, -20, 0, 2)
		holder.Parent = twoslider
		local fill = Instance.new('Frame')
		fill.BackgroundColor3 = Color3.fromHSV(vape.GUIColor.Hue, vape.GUIColor.Sat, vape.GUIColor.Value)
		fill.BorderSizePixel = 0
		fill.Position = UDim2.fromScale(math.clamp(component.ValueMin / props.Max, 0.04, 0.96), 0)
		fill.Size = UDim2.fromScale(math.clamp(math.clamp(component.ValueMax / props.Max, 0, 1), 0.04, 0.96) - fill.Position.X.Scale, 1)
		fill.Parent = holder
		local knob = Instance.new('Frame')
		knob.AnchorPoint = Vector2.new(0.5, 0.5)
		knob.BackgroundColor3 = twoslider.BackgroundColor3
		knob.BorderSizePixel = 0
		knob.Position = UDim2.fromScale(0, 0.5)
		knob.Size = UDim2.fromOffset(16, 4)
		knob.Parent = fill
		local knobknob = Instance.new('ImageLabel')
		knobknob.AnchorPoint = Vector2.new(0.5, 0.5)
		knobknob.BackgroundTransparency = 1
		knobknob.Image = getvapeasset('pistonware/assets/new/range.png')
		knobknob.ImageColor3 = Color3.fromHSV(vape.GUIColor.Hue, vape.GUIColor.Sat, vape.GUIColor.Value)
		knobknob.Position = UDim2.fromScale(0.5, 0.5)
		knobknob.Size = UDim2.fromOffset(9, 16)
		knobknob.Parent = knob
		local knobmax = knob:Clone()
		knobmax.Position = UDim2.fromScale(1, 0.5)
		knobmax.Parent = fill
		local knobmaxknob = knobmax.ImageLabel
		knobmaxknob.Rotation = 180
		local arrow = Instance.new('ImageLabel')
		arrow.BackgroundTransparency = 1
		arrow.Image = getvapeasset('pistonware/assets/new/rangeindicator.png')
		arrow.ImageColor3 = color.Light(uipallet.Main, 0.14)
		arrow.Position = UDim2.new(1, -56, 0, 10)
		arrow.Size = UDim2.fromOffset(12, 6)
		arrow.Parent = twoslider
		props.Function = props.Function or function() end
		props.Decimal = props.Decimal or 1
		local random = Random.new()
		
		function component:Color(hue, sat, val, isRainbow)
			fill.BackgroundColor3 = isRainbow and Color3.fromHSV(vape:Color((hue - (self.Index * 0.075)) % 1)) or Color3.fromHSV(hue, sat, val)
			knobknob.ImageColor3 = fill.BackgroundColor3
			knobmaxknob.ImageColor3 = fill.BackgroundColor3
		end
		
		function component:GetRandomValue()
			return random:NextNumber(component.ValueMin, component.ValueMax)
		end
		
		function component:Load(data)
			if self.ValueMin ~= data.ValueMin then
				self:SetValue(false, data.ValueMin)
			end
		
			if self.ValueMax ~= data.ValueMax then
				self:SetValue(true, data.ValueMax)
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
			maxvalue.Text = self.ValueMax
			minvalue.Text = self.ValueMin
		
			local size = math.clamp(math.clamp(self.ValueMin / props.Max, 0, 1), 0.04, 0.96)
			tween:Tween(fill, TweenInfo.new(0.1), {
				Position = UDim2.fromScale(size, 0),
				Size = UDim2.fromScale(math.clamp(math.clamp(self.ValueMax / props.Max, 0.04, 0.96) - size, 0, 1), 1)
			})

			-- props.Function is defaulted to a no-op just above and was then never called, so
			-- a TwoSlider given a Function silently ignored it -- unlike every other component
			-- here. No shipped call site passes one today, which is why nothing broke; this
			-- makes the contract real rather than waiting for the first one that does.
			props.Function(self.ValueMin, self.ValueMax, isMax)
		end
		
		knob.MouseEnter:Connect(function()
			tween:Tween(knobknob, uipallet.Tween, {
				Size = UDim2.fromOffset(11, 18)
			})
		end)
		
		knob.MouseLeave:Connect(function()
			tween:Tween(knobknob, uipallet.Tween, {
				Size = UDim2.fromOffset(9, 16)
			})
		end)
		
		knobmax.MouseEnter:Connect(function()
			tween:Tween(knobmaxknob, uipallet.Tween, {
				Size = UDim2.fromOffset(11, 18)
			})
		end)
		
		knobmax.MouseLeave:Connect(function()
			tween:Tween(knobmaxknob, uipallet.Tween, {
				Size = UDim2.fromOffset(9, 16)
			})
		end)
		
		twoslider.InputBegan:Connect(function(input)
			if
				(input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch)
				and (input.Position.Y - twoslider.AbsolutePosition.Y) > (20 * scale.Scale)
			then
				local maxCheck = (input.Position.X - knobmax.AbsolutePosition.X) > -10
				local newPosition = math.clamp((input.Position.X - holder.AbsolutePosition.X) / holder.AbsoluteSize.X, 0, 1)
		
				local releaseConnection
				local moveConnection = inputService.InputChanged:Connect(function(newInput)
					if newInput.UserInputType == (input.UserInputType == Enum.UserInputType.MouseButton1 and Enum.UserInputType.MouseMovement or Enum.UserInputType.Touch) then
						local newPosition = math.clamp((newInput.Position.X - holder.AbsolutePosition.X) / holder.AbsoluteSize.X, 0, 1)
						component:SetValue(maxCheck, math.floor((props.Min + (props.Max - props.Min) * newPosition) * props.Decimal) / props.Decimal, newPosition)
					end
				end)
		
				releaseConnection = input.Changed:Connect(function()
					if input.UserInputState == Enum.UserInputState.End then
						moveConnection:Disconnect()
						releaseConnection:Disconnect()
					end
				end)
		
				component:SetValue(maxCheck, math.floor((props.Min + (props.Max - props.Min) * newPosition) * props.Decimal) / props.Decimal, newPosition)
			end
		end)
		
		maxvalue.MouseButton1Click:Connect(function()
			maxvalue.Visible = false
			custommax.Visible = true
			custommax.Text = component.ValueMax
			custommax:CaptureFocus()
		end)
		
		minvalue.MouseButton1Click:Connect(function()
			minvalue.Visible = false
			custommin.Visible = true
			custommin.Text = component.ValueMin
			custommin:CaptureFocus()
		end)
		
		custommax.FocusLost:Connect(function(enter)
			maxvalue.Visible = true
			custommax.Visible = false
		
			if enter and tonumber(custommax.Text) then
				component:SetValue(true, tonumber(custommax.Text))
			end
		end)
		
		custommin.FocusLost:Connect(function(enter)
			minvalue.Visible = true
			custommin.Visible = false
		
			if enter and tonumber(custommin.Text) then
				component:SetValue(false, tonumber(custommin.Text))
			end
		end)
		
		api.Options[props.Name] = component
		
		return component
	end,
}

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
				return callback(props, children, component)
			end)
		end
	end
})

vape:LoadGUI()

return vape
