local pistonwareBuffer
pcall(function()
	local env = getgenv()
	pistonwareBuffer = type(env.pistonware) == 'table' and env.pistonware.buffer or nil
end)

local function bufferCall(method, event, message, details)
	local callback = type(pistonwareBuffer) == 'table' and pistonwareBuffer[method] or nil
	if type(callback) == 'function' then return callback(event, message, details) end
	if shared.PistonwareDeveloper == true then warn('[pistonware] '..tostring(message)) end
end

local function bufferRaise(event, message, level)
	bufferCall('error', event, message)
	return error(message, level)
end

if shared.slinky then
	pcall(function() shared.slinky:unload() end)
	shared.slinky = nil
end

shared.SlinkyCustomProfile = nil
shared.slinkyreload = nil

task.wait(2)

local function deleteFolder(path)
	if delfolder then
		return delfolder(path)
	end
	if not listfiles or not delfile then
		bufferRaise('reinstall.filesystem', 'delfolder, listfiles, and delfile are unavailable', 0)
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
		bufferCall('warn', 'reinstall.delete', 'failed to delete pistonware folder', {error = err})
		return
	end
end

task.wait(2)
shared.SlinkySmoothBoot = true

local suc, res = pcall(function()
	return game:HttpGet('https://raw.githubusercontent.com/themagicpiston/pistonware/refs/heads/main/loader.lua', true)
end)
if not suc or not res or res == '' or res == '404: Not Found' then
	bufferRaise('reinstall.download', 'failed to download loader.lua - '..tostring(res), 0)
end
local loaderChunk = loadstring(res, 'loader')
if not loaderChunk then
	bufferRaise('reinstall.compile', 'downloaded loader.lua did not compile', 0)
end
loaderChunk()
