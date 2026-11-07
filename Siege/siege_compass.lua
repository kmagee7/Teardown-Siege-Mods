-- Siege: shows defenders which side the attackers come from: one red marker around the crosshair pointing
-- at the middle of the attacker spawns, and a line naming that direction. It doesn't track any player.
-- The host can turn it off.

COMPASS_RADIUS = 120       -- pixels from the middle of the screen
local COMPASS_NAMES = { "north", "north-east", "east", "south-east", "south", "south-west", "west", "north-west" }

local function _compassSpawnCentre()
	local spawns = shared.layout and shared.layout.spawns
	if spawns == nil then return nil end
	local x, z, n = 0, 0, 0
	for i = 1, #spawns do
		if spawns[i].role == ROLE_ATTACK then
			x, z, n = x + spawns[i].pos[1], z + spawns[i].pos[3], n + 1
		end
	end
	if n == 0 then return nil end
	return x / n, z / n
end

function client.compassDraw()
	if siegeSetting("attackdir") == 0 or shared.phase ~= "live" then return end
	local me = GetLocalPlayer()
	if me == 0 or GetPlayerHealth(me) <= 0 or siegeRoleOf(me) ~= ROLE_DEFEND then return end
	local cx, cz = _compassSpawnCentre()
	if cx == nil then return end
	local here = GetPlayerTransform(me).pos
	local camera = GetPlayerCameraTransform(me)
	local forward = TransformToParentVec(camera, Vec(0, 0, -1))
	local heading = math.atan2(forward[1], -forward[3])
	local bearing = math.atan2(cx - here[1], -(cz - here[3]))
	local angle = bearing - heading
	UiPush()
		UiTranslate(UiCenter() + math.sin(angle) * COMPASS_RADIUS, UiMiddle() - math.cos(angle) * COMPASS_RADIUS)
		UiRotate(-math.deg(angle))
		UiAlign("center middle")
		UiColor(0.95, 0.15, 0.1, 0.85)
		UiPush()
			UiTranslate(-7, 4)
			UiRotate(-40)
			UiRect(22, 5)
		UiPop()
		UiPush()
			UiTranslate(7, 4)
			UiRotate(40)
			UiRect(22, 5)
		UiPop()
	UiPop()
	local index = (math.floor(bearing / (math.pi / 4) + 0.5) % 8) + 1
	UiPush()
		UiTranslate(UiCenter(), 158)
		UiAlign("center middle")
		UiFont("bold.ttf", 20)
		UiTextShadow(0, 0, 0, 0.8, 2)
		UiColor(1, 0.45, 0.35)
		UiText("Attackers come from the " .. COMPASS_NAMES[index])
	UiPop()
end
