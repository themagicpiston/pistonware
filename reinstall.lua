if shared.vape then
	pcall(function() shared.vape:Uninject() end)
	shared.vape = nil
end

shared.VapeCustomProfile = nil
shared.vapereload = nil

task.wait(2)

local function deleteFolder(path)
	if delfolder then
		return delfolder(path)
	end
	if not listfiles or not delfile then
		error('delfolder, listfiles, and delfile are unavailable')
	end
	for _, child in listfiles(path) do
		if isfolder and isfolder(child) then
			deleteFolder(child)
		else
			delfile(child)
		end
	end
end

if isfolder and isfolder('pistonware') then
	local ok, err = pcall(deleteFolder, 'pistonware')
	if not ok then
		warn('Pistonware reinstall: failed to delete pistonware folder - '..tostring(err))
		return
	end
end

task.wait(2)
shared.VapeSmoothBoot = true

local suc, res = pcall(function()
	return game:HttpGet('https://raw.githubusercontent.com/themagicpiston/pistonware/refs/heads/main/loader.lua', true)
end)
if not suc or not res or res == '' or res == '404: Not Found' then
	error('Pistonware reinstall: failed to download loader.lua - '..tostring(res))
end
local loaderChunk = loadstring(res, 'loader')
if not loaderChunk then
	error('Pistonware reinstall: downloaded loader.lua did not compile')
end
loaderChunk()
