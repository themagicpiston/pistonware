-- Cleanly tear down a currently-injected vape before wiping the folder out from under it --
-- leaving its modules/loops/connections running against files that are about to be deleted
-- is what caused the "attempt to index nil with 'Libraries'" error (stale threads reaching
-- into tables that no longer exist once the fresh loader run starts rebuilding them).
if shared.vape then
	pcall(function() shared.vape:Uninject() end)
	shared.vape = nil
end

-- Clear one-shot hints from any previous run so the fresh load below doesn't inherit stale
-- state from before the reinstall.
shared.VapeCustomProfile = nil
shared.vapereload = nil

task.wait(1)

-- Deleting the whole folder (profiles included) is what puts loader.lua back into its
-- first-run state, so it naturally re-asks whether to download configs from scratch.
if isfolder and isfolder('pistonware') then
	local ok, err = pcall(delfolder, 'pistonware')
	if not ok then
		warn('Pistonware reinstall: failed to delete pistonware folder - '..tostring(err))
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
loadstring(res, 'loader')()
