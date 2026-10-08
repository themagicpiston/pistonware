local vape = shared.vape
local loadstring = function(...)
	local res, err = loadstring(...)
	if err and vape then 
		vape:CreateNotification('Vape', 'Failed to load : '..err, 30, 'alert') 
	end
	return res
end
local function runChunk(source, name)
	local chunk = loadstring(source, name)
	if chunk then chunk() end
end
local isfile = isfile or function(file)
	local suc, res = pcall(function() 
		return readfile(file) 
	end)
	return suc and res ~= nil and res ~= ''
end
local function pistonwareHttpGet(url, nocache, attempt)
	local adapter = shared.PistonwareDevHttpGet
	if type(adapter) == 'function' then
		return adapter(url, nocache, attempt)
	end
	return game:HttpGet(url, nocache)
end
local function downloadFile(path, func)
	local devLoader = shared.PistonwareDevLoadSource
	if type(devLoader) == 'function' then
		local body = devLoader(path)
		return func and func(path) or body
	end
	if not isfile(path) then
		local suc, res = pcall(function() 
			return pistonwareHttpGet('https://raw.githubusercontent.com/themagicpiston/pistonware/main/'..select(1, path:gsub('pistonware/', '')), true)
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

vape.Place = 109983668079237
if isfile('pistonware/games/'..vape.Place..'.lua') then
	runChunk(readfile('pistonware/games/'..vape.Place..'.lua'), 'bedwars')
else
	if not shared.PistonwareDeveloper then
		local suc, res = pcall(function()
			return pistonwareHttpGet('https://raw.githubusercontent.com/themagicpiston/pistonware/main/games/'..vape.Place..'.lua', true)
		end)
		if suc and res and res ~= '' and res ~= '404: Not Found' then
			runChunk(downloadFile('pistonware/games/'..vape.Place..'.lua'), 'bedwars')
		else
			return
		end
	end
end
