-- Siege: clears small rubble that has come to rest. Every loose piece of a broken wall is a body the
-- host has to simulate and keep in sync, so in a long siege these add up.
-- Only small, sleeping pieces with no tags or joints go, a few at a time, so nothing vanishes mid-air
-- and pickups, vehicles, ladders, balls and placed pieces are left alone.

CLEANUP_MAX_VOXELS = 400      -- about 0.4 cubic metres
CLEANUP_LIST_TIME = 8.0       -- seconds between fresh lists of bodies
CLEANUP_PER_TICK = 6          -- bodies looked at per tick

server.cleanup = { list = {}, at = 1, timer = 0 }

local function _cleanupWanted(b)
	if not IsHandleValid(b) or not IsBodyDynamic(b) or IsBodyActive(b) then return false end
	if GetBodyVehicle(b) ~= 0 or #ListTags(b) > 0 then return false end
	local voxels = 0
	local shapes = GetBodyShapes(b)
	for i = 1, #shapes do
		local s = shapes[i]
		if #ListTags(s) > 0 or #GetShapeJoints(s) > 0 then return false end
		voxels = voxels + GetShapeVoxelCount(s)
		if voxels > CLEANUP_MAX_VOXELS then return false end
	end
	return true
end

function server.cleanupTick(dt)
	if siegeSetting("debris") == 0 then return end
	local c = server.cleanup
	c.timer = c.timer - dt
	if c.timer <= 0 then
		c.timer = CLEANUP_LIST_TIME
		c.list = FindBodies(nil, true) or {}
		c.at = 1
	end
	for _ = 1, CLEANUP_PER_TICK do
		local b = c.list[c.at]
		if b == nil then return end
		c.at = c.at + 1
		if _cleanupWanted(b) then Delete(b) end
	end
end
