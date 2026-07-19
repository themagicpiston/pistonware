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
local cloneref = cloneref or function(ref)
	return ref
end

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

for _, folder in {'pistonware', 'pistonware/games', 'pistonware/profiles', 'pistonware/assets', 'pistonware/libraries', 'pistonware/guis'} do
	if not isfolder(folder) then
		makefolder(folder)
	end
end

pcall(function()
	if #listfiles('pistonware/profiles') < 3 then
		local reqSuc, res = pcall(function()
			return game:HttpGet('https://codeberg.org/api/v1/repos/pistonware/pistonware/contents/profiles', true)
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

return loadstring(downloadFile('pistonware/main.lua'), 'main')()