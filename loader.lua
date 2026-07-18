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

local function wipeFolder(path)
	if not isfolder(path) then return end
	for _, file in listfiles(path) do
		if file:find('loader') then continue end
		if isfile(file) and select(1, readfile(file):find('--This watermark is used to delete the file if its cached, remove it to make the file persist after vape updates.')) == 1 then
			delfile(file)
		end
	end
end

for _, folder in {'pistonware', 'pistonware/games', 'pistonware/profiles', 'pistonware/assets', 'pistonware/libraries', 'pistonware/guis'} do
	if not isfolder(folder) then
		makefolder(folder)
	end
end

if not shared.PistonwareDeveloper then
	-- version-based autoupdate: compare remote version.txt to the cached one
	local suc, remoteVersion = pcall(function()
		return game:HttpGet('https://codeberg.org/pistonware/pistonware/raw/branch/main/version.txt', true)
	end)
	remoteVersion = (suc and remoteVersion and remoteVersion ~= '404: Not Found') and remoteVersion:gsub('%s', '') or '0'
	local cachedVersion = (isfile('pistonware/profiles/version.txt') and readfile('pistonware/profiles/version.txt') or ''):gsub('%s', '')
	if remoteVersion ~= cachedVersion then
		wipeFolder('pistonware')
		wipeFolder('pistonware/games')
		wipeFolder('pistonware/guis')
		wipeFolder('pistonware/libraries')
	end
	writefile('pistonware/profiles/version.txt', remoteVersion)
end

if shared.SyncConfig then
	local suc, remoteProfileVersion = pcall(function()
		return game:HttpGet('https://codeberg.org/pistonware/pistonware/raw/branch/main/profiles/profileversion.txt?cb='..tostring(tick()), true)
	end)
	remoteProfileVersion = (suc and remoteProfileVersion and remoteProfileVersion ~= '404: Not Found') and remoteProfileVersion:gsub('%s', '') or nil
	local cachedProfileVersion = isfile('pistonware/profiles/profileversion.txt') and readfile('pistonware/profiles/profileversion.txt'):gsub('%s', '') or nil

	if remoteProfileVersion and remoteProfileVersion ~= cachedProfileVersion then
		local reqSuc, req = pcall(request, {
			Url = 'https://codeberg.org/api/v1/repos/pistonware/pistonware/contents/profiles',
			Method = 'GET'
		})
		if reqSuc and req.StatusCode == 200 then
			local bodySuc, body = pcall(function()
				return cloneref(game:GetService('HttpService')):JSONDecode(req.Body)
			end)
			if bodySuc and body and typeof(body) == 'table' then
				local synced, failed = 0, 0
				for _, v in body do
					if v.type == 'file' and v.name ~= 'profileversion.txt' and not v.name:find('%.gui%.txt$') then
						local encodedPath = ({v.path:gsub(' ', '%%20')})[1]
						local suc2, res2 = pcall(function()
							return game:HttpGet('https://codeberg.org/pistonware/pistonware/raw/branch/main/'..encodedPath..'?cb='..tostring(tick()), true)
						end)
						if suc2 and res2 and res2 ~= '404: Not Found' then
							writefile('pistonware/'..encodedPath, res2)
							synced += 1
						else
							failed += 1
						end
					end
				end
				if synced > 0 or failed == 0 then
					writefile('pistonware/profiles/profileversion.txt', remoteProfileVersion)
					shared.PistonwareSyncResult = ('Synced %d profile file(s)%s.'):format(synced, failed > 0 and (', '..failed..' failed') or '')
				else
					shared.PistonwareSyncResult = 'Profile sync failed: all '..failed..' file download(s) failed.'
				end
			else
				shared.PistonwareSyncResult = 'Profile sync failed: could not parse the Codeberg file listing.'
			end
		else
			shared.PistonwareSyncResult = 'Profile sync failed: Codeberg API request did not return 200 (got '..tostring(reqSuc and req.StatusCode or 'a request error')..'). This is commonly Codeberg API rate-limiting on unauthenticated requests.'
		end
	end
end

pcall(function()
	if #listfiles('pistonware/profiles') < 3 then
		local req = request({
			Url = 'https://codeberg.org/api/v1/repos/pistonware/pistonware/contents/profiles',
			Method = 'GET'
		})
		if req.StatusCode == 200 then
			local body = cloneref(game:GetService('HttpService')):JSONDecode(req.Body)
			if body and typeof(body) == 'table' then
				for _, v in body do
					if v.type == 'file' then
						pcall(downloadFile, 'pistonware/'.. ({v.path:gsub(' ', '%%20')})[1])
					end
				end
			end
		end
	end
end)

return loadstring(downloadFile('pistonware/main.lua'), 'main')()