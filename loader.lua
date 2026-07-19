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
		-- Fetched via the contents API (base64 JSON) instead of the raw URL: Codeberg rate-limits
		-- raw file fetches under a much stricter "git_op" bucket (250 req/10min) than the API's
		-- "baseline" bucket (2000 req/10min), and a cold install downloads dozens of files.
		-- Retried a few times: Codeberg's backend intermittently 504s (~5% of raw requests observed),
		-- returning an empty body that would otherwise get cached as a corrupt/empty file.
		local content
		for attempt = 1, 4 do
			local suc, res = pcall(function()
				return game:HttpGet('https://codeberg.org/api/v1/repos/pistonware/pistonware/contents/'..select(1, path:gsub('pistonware/', '')), true)
			end)
			if suc and res and res ~= '' and res ~= '404: Not Found' then
				local decodeSuc, body = pcall(function()
					return cloneref(game:GetService('HttpService')):JSONDecode(res)
				end)
				if decodeSuc and body and body.content then
					content = cloneref(game:GetService('HttpService')):Base64Decode(body.content)
					break
				end
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