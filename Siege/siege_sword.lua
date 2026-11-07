-- Siege: the sword. Left click swings. It hits the nearest enemy in front of you, and chops into
-- whatever soft material is in the way, like wood. It has no ammo.

SWORD_TOOL_ID = "siegesword"
SWORD_REACH = 2.5
SWORD_AIM = 0.6            -- how directly you must face them (1 = dead on)
SWORD_HIT_AT = 0.18        -- seconds into the swing that the blow lands
SWORD_COOLDOWN = 0.65
SWORD_DAMAGE = 0.45        -- share of a full health bar
SWORD_SHOVE = 3.0

server.sword = { swings = {}, ready = {} }
shared.swordSwing = shared.swordSwing or {}

function server.swordInit()
	RegisterTool(SWORD_TOOL_ID, "Sword", "MOD/bow/sword.xml", 2)
	SetBool("game.tool." .. SWORD_TOOL_ID .. ".enabled", true)
	server.swordHitSound = LoadSound("clickdown.ogg")
end

local function _swordBlow(p)
	local camera = GetPlayerCameraTransform(p)
	local forward = TransformToParentVec(camera, Vec(0, 0, -1))
	local team = siegeTeamOf(p)
	local best, bestDist = nil, SWORD_REACH + 1
	for q in Players() do
		if q ~= p and GetPlayerHealth(q) > 0 and (team == 0 or siegeTeamOf(q) ~= team) then
			local chest = VecAdd(GetPlayerTransform(q).pos, Vec(0, 1.1, 0))
			local to = VecSub(chest, camera.pos)
			local dist = VecLength(to)
			if dist < SWORD_REACH + 0.6 and dist < bestDist and dist > 0.01 and VecDot(forward, VecScale(to, 1 / dist)) > SWORD_AIM then
				QueryRejectPlayer(p)
				local blocked = QueryRaycast(camera.pos, VecScale(to, 1 / dist), dist - 0.3)
				if not blocked then best, bestDist = q, dist end
			end
		end
	end
	if best then
		ApplyPlayerDamage(best, SWORD_DAMAGE, "sword", p)
		SetPlayerVelocity(VecAdd(GetPlayerVelocity(best), VecScale(forward, SWORD_SHOVE)), best)
		ClientCall(p, "client.bowHitMarker", false)
		PlaySound(server.swordHitSound, GetPlayerTransform(best).pos, 1.2)
		return
	end
	QueryRejectPlayer(p)
	local hit, dist, _, shape = QueryRaycast(camera.pos, forward, SWORD_REACH)
	if hit and shape and shape ~= 0 and HasTag(GetShapeBody(shape), "siegebot") then
		local struck = GetShapeBody(shape)
		if GetTagValue(struck, "siegebotrole") ~= siegeBotRoleName(siegeRoleOf(p)) then
			SetTag(struck, "siegebothp", tostring((tonumber(GetTagValue(struck, "siegebothp")) or 100) - SWORD_DAMAGE * 100))
			ClientCall(p, "client.bowHitMarker", false)
			PlaySound(server.swordHitSound, camera.pos, 1.2)
		end
		return
	end
	if hit then
		local point = VecAdd(camera.pos, VecScale(forward, dist))
		MakeHole(point, 0.25, 0.1, 0)
		PlaySound(server.swordHitSound, point, 0.8)
	end
end

function server.swordTick(dt)
	local sword = server.sword
	for p in Players() do
		if GetPlayerTool(p) == SWORD_TOOL_ID and GetPlayerHealth(p) > 0 then
			if InputPressed("usetool", p) and (sword.ready[p] or 0) <= GetTime() then
				sword.ready[p] = GetTime() + SWORD_COOLDOWN
				sword.swings[p] = SWORD_HIT_AT
				shared.swordSwing[p] = GetTime()
			end
		end
		if sword.swings[p] then
			sword.swings[p] = sword.swings[p] - dt
			if sword.swings[p] <= 0 then
				sword.swings[p] = nil
				if GetPlayerTool(p) == SWORD_TOOL_ID and GetPlayerHealth(p) > 0 then _swordBlow(p) end
			end
		end
	end
end

-- ---------- client ----------

client.swordSeen = {}

function client.swordTick()
	local me = GetLocalPlayer()
	for p in Players() do
		if GetPlayerTool(p) == SWORD_TOOL_ID then
			local start = shared.swordSwing and shared.swordSwing[p]
			if start and start ~= client.swordSeen[p] then
				client.swordSeen[p] = start
				if client.swordWhoosh == nil then client.swordWhoosh = LoadSound("grab0.ogg") end
				PlaySound(client.swordWhoosh, GetPlayerTransform(p).pos, 0.8, true, 0.7)
			end
			-- 0 at rest, up to 1 at the end of the swing, then back
			local k = 0
			if start then
				local t = GetTime() - start
				if t < SWORD_HIT_AT * 1.6 then k = t / (SWORD_HIT_AT * 1.6)
				elseif t < SWORD_COOLDOWN then k = 1 - (t - SWORD_HIT_AT * 1.6) / (SWORD_COOLDOWN - SWORD_HIT_AT * 1.6) end
			end
			local pitch = -15 - 75 * k
			if p == me and not GetBool("game.thirdperson") then
				SetToolTransform(Transform(Vec(0.38 - 0.25 * k, -0.5, -0.55 - 0.25 * k), QuatEuler(pitch, 15 * k, -15 + 45 * k)), 0.3)
			else
				SetToolTransform(Transform(Vec(0, -0.3, -0.1), QuatEuler(pitch, 0, 0)), 1, p)
			end
		end
	end
end
