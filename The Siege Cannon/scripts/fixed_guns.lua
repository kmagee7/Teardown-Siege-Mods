-- Fixed guns: cannons and trebuchets built into a map, which players can man.
-- They fire every ball type THE CANNON has, through the same code as the hand cannon in main.lua.
--
-- A map adds one by tagging static bodies and a shape, all with the same id:
--   body:  siegegun=<id> siegegunkind=cannon|treb   the carriage, turns left and right about its origin
--          optional: siegegunyaw=<degrees>  siegegunscale=<size>  siegegunside=defend (default is attackers)
--   body:  siegegunarm=<id>                         the barrel or throwing arm, turns about its origin's x axis
--   shape: siegegunbase=<id>                        what it stands on; it falls if most of this is destroyed
-- Forward is the carriage's local -z. Parts are moved by script, so they can't fall over or turn the
-- wrong way, and a gun that is shot to bits drops for real.

GUN_USE_REACH = 3.6         -- metres from the player's eye to the gun
GUN_USE_AIM = 0.55
GUN_KEEP_REACH = 7.0        -- leave the gun if you end up further away than this
GUN_YAW_LIMIT = 55          -- degrees either side of where it was built
GUN_YAW_SPEED = 22          -- degrees per second
GUN_PITCH_MIN, GUN_PITCH_MAX = -8, 38
GUN_PITCH_SPEED = 14
GUN_BROKEN_FRACTION = 0.55
GUN_MUZZLE = -3.1           -- metres in front of the trunnion
GUN_RELOAD_TIME = 5.0       -- seconds between shots on a fixed cannon
GUN_FULLAUTO_INTERVAL = 0.3 -- full auto on a fixed cannon, slower than by hand: there can be dozens of these
GUN_BOT_REST = 11.0         -- seconds a bot crew waits between shots
GUN_BOT_RESPAWN = 30.0
GUN_BOT_MISS = { 3.0, 1.8, 0.9 }   -- how far off bot crews aim, in degrees, by bot skill
GUN_SEAT = 2.1              -- the gunner stands this far behind the pivot, behind the shield

TREB_RANGE_MIN, TREB_RANGE_MAX = 40, 170
TREB_RANGE_SPEED = 25       -- metres per second while the key is held
TREB_SWING_TIME = 0.8
TREB_SWING_ANGLE = 170      -- degrees, from cocked to follow-through
TREB_RELEASE_AT = 0.72      -- share of the swing when the ball leaves
TREB_RELOAD_TIME = 7.0
TREB_LAUNCH_HEIGHT = 9.5
TREB_LAUNCH_FORWARD = -1.5

-- Launch speed and total gravity of each ball, for the aiming arc and the trebuchet's range.
-- These match the constants at the top of main.lua.
GUN_BALLS = {
	breaker = { 40, 10 }, explosive = { 40, 10 }, ultraultra = { 40, 10 }, normalexplosive = { 40, 10 },
	ricochet = { 65, 10 }, eraser = { 48, 20 }, fullauto = { 70, 6 },
	physics = { 80, 22 }, tetherphysics = { 38, 22 }, giantphysics = { 45, 22 },
}

-- The Siege host's sliders, when there are any; otherwise the numbers at the top of this file.
function gunReloadTime()
	local t = GetFloat("level.siege.guns.reload")
	return t > 0 and t or GUN_RELOAD_TIME
end

local function trebReloadTime()
	local t = GetFloat("level.siege.treb.reload")
	return t > 0 and t or TREB_RELOAD_TIME
end

local function clampGun(v, a, b) if v < a then return a elseif v > b then return b end return v end

local function bodyVoxels(body)
	if not IsHandleValid(body) then return 0 end
	local n = 0
	local shapes = GetBodyShapes(body)
	for i = 1, #shapes do n = n + GetShapeVoxelCount(shapes[i]) end
	return n
end

-- Launch point and direction. Used on both server and client, so the arc is where the ball goes.
function gunAimTransform(cab, arm, kind)
	if kind == "treb" then
		local t = GetBodyTransform(cab)
		local size = tonumber(GetTagValue(cab, "siegegunscale")) or 1
		local forward = TransformToParentVec(t, Vec(0, 0, -1))
		local dir = VecNormalize(VecAdd(forward, Vec(0, 1, 0)))
		local pos = TransformToParentPoint(t, Vec(0, TREB_LAUNCH_HEIGHT * size, TREB_LAUNCH_FORWARD * size))
		return Transform(pos, QuatLookAt(pos, VecAdd(pos, dir)))
	end
	local t = GetBodyTransform(arm)
	return Transform(TransformToParentPoint(t, Vec(0, 0, GUN_MUZZLE)), t.rot)
end

function gunBallSpeed(kind, ammo, range)
	local ball = GUN_BALLS[ammo] or GUN_BALLS.breaker
	if kind == "treb" then return math.sqrt((range or TREB_RANGE_MIN) * ball[2]) end
	return ball[1]
end

-- ---------- server ----------

server.guns = {}
server.gunByPlayer = {}
server.gunPress = {}
shared.gunOperator = shared.gunOperator or {}
shared.gunRange = shared.gunRange or {}
shared.gunReady = shared.gunReady or {}

function server.gunsFind()
	server.guns = {}
	local arms = {}
	local armBodies = FindBodies("siegegunarm", true)
	for i = 1, #armBodies do arms[GetTagValue(armBodies[i], "siegegunarm")] = armBodies[i] end
	local bases = {}
	local baseShapes = FindShapes("siegegunbase", true)
	for i = 1, #baseShapes do bases[GetTagValue(baseShapes[i], "siegegunbase")] = baseShapes[i] end
	local cabs = FindBodies("siegegun", true)
	for i = 1, #cabs do
		local id = GetTagValue(cabs[i], "siegegun")
		if arms[id] then
			local home = GetBodyTransform(cabs[i])
			local gun = {
				id = id, cab = cabs[i], arm = arms[id], base = bases[id], home = home,
				kind = GetTagValue(cabs[i], "siegegunkind"), side = GetTagValue(cabs[i], "siegegunside"),
				armLocal = TransformToLocalTransform(home, GetBodyTransform(arms[id])),
				yawLimit = tonumber(GetTagValue(cabs[i], "siegegunyaw")) or GUN_YAW_LIMIT, yaw = 0, pitch = 0, h = 0, v = 0, down = false, alive = true,
				swing = 0, reload = 0, fired = false,
				voxels = bodyVoxels(cabs[i]) + bodyVoxels(arms[id]),
				baseVoxels = bases[id] and GetShapeVoxelCount(bases[id]) or 0,
			}
			if gun.kind == "treb" then shared.gunRange[id] = 80 end
			shared.gunReady[id] = true
			gun.size = tonumber(GetTagValue(cabs[i], "siegegunscale")) or 1
			server.guns[id] = gun
		end
	end
	for _, role in ipairs({ "attack", "defend" }) do
		local list = {}
		for _, gun in pairs(server.guns) do
			if (gun.side == "defend" and "defend" or "attack") == role then list[#list + 1] = gun end
		end
		for i = #list, 2, -1 do
			local k = math.random(1, i)
			list[i], list[k] = list[k], list[i]
		end
		for i = 1, #list do list[i].crewOrder = i end
	end
end

function server.gunsInit()
	server.gunCheckTimer = 0.5
	server.gunCreak = LoadSound("clickdown.ogg")
	server.gunsFind()
end

local function gunPose(gun)
	local cabT = TransformToParentTransform(gun.home, Transform(Vec(0, 0, 0), QuatEuler(0, gun.yaw, 0)))
	SetBodyTransform(gun.cab, cabT)
	local angle = gun.kind == "treb" and -gun.swing or gun.pitch
	local armT = Transform(gun.armLocal.pos, QuatRotateQuat(gun.armLocal.rot, QuatEuler(angle, 0, 0)))
	SetBodyTransform(gun.arm, TransformToParentTransform(cabT, armT))
end

local function gunSeatPlayer(gun, p)
	if gun.kind == "treb" then return end
	local t = GetBodyTransform(gun.cab)
	-- the carriage's origin is 0.2 m above the deck
	SetPlayerTransform(Transform(TransformToParentPoint(t, Vec(0, -0.2, GUN_SEAT)), t.rot), p)
	SetPlayerVelocity(Vec(0, 0, 0), p)
end

local function gunRelease(gun)
	if shared.gunOperator[gun.id] then
		local back = gun.heldTool
		gun.heldTool = nil
		if back and back ~= "" and back ~= "none" and IsToolEnabled(back, shared.gunOperator[gun.id]) then SetPlayerTool(back, shared.gunOperator[gun.id]) end
		server.gunByPlayer[shared.gunOperator[gun.id]] = nil
		shared.gunOperator[gun.id] = nil
	end
	gun.h, gun.v, gun.down = 0, 0, false
end

local function gunAllowed(p, gun)
	if not GetBool("level.siege.cannon.active") then return true end
	if gun.side == "defend" then return GetBool("level.siege.guns.defend." .. p) end
	return GetBool("level.siege.guns.allow." .. p)
end

local function gunCheckDamage(gun)
	local broken = bodyVoxels(gun.cab) + bodyVoxels(gun.arm) < gun.voxels * GUN_BROKEN_FRACTION
	if gun.base and (not IsHandleValid(gun.base) or GetShapeVoxelCount(gun.base) < gun.baseVoxels * GUN_BROKEN_FRACTION) then broken = true end
	if broken then
		gun.alive = false
		gunRelease(gun)
		shared.gunReady[gun.id] = false
		for _, b in ipairs({ gun.cab, gun.arm }) do
			if IsHandleValid(b) then
				SetBodyDynamic(b, true)
				SetBodyActive(b, true)
			end
		end
	end
end

-- ---------- bot crews ----------

local function gunRoleName(gun)
	return gun.side == "defend" and "defend" or "attack"
end

local function gunCrewXml(roleName)
	local colour = GetString("level.siege.bots.colour." .. roleName)
	if colour == "" then colour = "0.5 0.5 0.5" end
	local look = "material='plastic' color='" .. colour .. "'"
	local skin = "material='plastic' color='0.76 0.60 0.47'"
	return "<group><body tags='siegebot siegebotrole=" .. roleName .. " siegebothp=100' dynamic='false'>"
		.. "<voxbox pos='-0.2 0 -0.1' size='2 6 2' " .. look .. "/><voxbox pos='0 0 -0.1' size='2 6 2' " .. look .. "/>"
		.. "<voxbox pos='-0.25 0.6 -0.15' size='5 5 3' " .. look .. "/>"
		.. "<voxbox pos='-0.15 1.1 -0.15' size='3 3 3' " .. skin .. "/>"
		.. "</body></group>"
end

local function gunCrewPlace(gun)
	if gun.crew == nil or not IsHandleValid(gun.crew) then return end
	local t = GetBodyTransform(gun.cab)
	local spot = gun.kind == "treb" and Vec(3.0 * gun.size, -0.3, 1.5 * gun.size) or Vec(0, -0.2, GUN_SEAT)
	SetBodyTransform(gun.crew, Transform(TransformToParentPoint(t, spot), t.rot))
end

function server.gunCrewRemove(gun)
	if gun.crew and IsHandleValid(gun.crew) then Delete(gun.crew) end
	gun.crew = nil
	gun.crewWait = 2
end

local function gunCrewAllowed(gun)
	if not GetBool("level.siege.bots.live") then return false end
	return gun.crewOrder ~= nil and gun.crewOrder <= GetInt("level.siege.bots.crews")
end

local function gunPickBall(gun)
	local list = (gun.kind == "treb" and GetBool("level.siege.treb.active")) and "level.siege.treb.ammo." or "level.siege.cannon.ammo."
	for _, id in ipairs({ "physics", "giantphysics", "normalexplosive", "explosive", "breaker", "ricochet" }) do
		if GetBool(list .. id) then return id end
	end
	return nil
end

-- Yaw from where the gun was built, for a point in the world; nil if it can't turn that far.
local function gunYawTo(gun, point)
	local l = TransformToLocalPoint(gun.home, point)
	local yaw = math.deg(math.atan2(-l[1], -l[3]))
	if math.abs(yaw) > gun.yawLimit then return nil end
	return yaw
end

-- What a crew shoots at. Defenders go for attacking players, leading them a little, then attacker bots.
-- Attackers go for the map's strategic points: the gates, the keep and the towers with trebuchets.
local function gunCrewTarget(gun)
	local role = gunRoleName(gun)
	local cabPos = GetBodyTransform(gun.cab).pos
	local list = {}
	if role == "defend" then
		local players = GetAllPlayers()
		for i = 1, #players do
			local p = players[i]
			if GetBool("level.siege.guns.allow." .. p) and GetPlayerHealth(p) > 0 then
				local at = GetPlayerTransform(p).pos
				local dist = VecLength(VecSub(at, cabPos))
				local lead = VecScale(GetPlayerVelocity(p), math.min(2.5, dist / 60))
				local aim = VecAdd(VecAdd(at, Vec(lead[1], 0, lead[3])), Vec(0, 1, 0))
				if dist < 170 and gunYawTo(gun, aim) then list[#list + 1] = aim end
			end
		end
		if #list > 0 then return list[math.random(1, #list)] end
		local bots = FindBodies("siegebot", true)
		for i = 1, #bots do
			if IsHandleValid(bots[i]) and GetTagValue(bots[i], "siegebotrole") == "attack" then
				local at = VecAdd(GetBodyTransform(bots[i]).pos, Vec(0, 1, 0))
				if VecLength(VecSub(at, cabPos)) < 170 and gunYawTo(gun, at) then list[#list + 1] = at end
			end
		end
		if #list > 0 then return list[math.random(1, #list)] end
	end
	local spots = FindLocations("siegebottarget", true)
	for i = 1, #spots do
		if GetTagValue(spots[i], "siegebottarget") == role then
			local at = GetLocationTransform(spots[i]).pos
			if gunYawTo(gun, at) then list[#list + 1] = at end
		end
	end
	if #list > 0 then return list[math.random(1, #list)] end
	-- nothing marked within this gun's turn: whatever lies straight ahead
	return TransformToParentPoint(gun.home, Vec(0, 7, -55))
end

-- Runs a gun no player is on. Returns true if it moved.
function server.gunCrewTick(gun, dt)
	if not gunCrewAllowed(gun) then
		if gun.crew then server.gunCrewRemove(gun) end
		return false
	end
	if gun.crew == nil or not IsHandleValid(gun.crew) then
		gun.crew = nil
		gun.crewWait = (gun.crewWait or 0) - dt
		if gun.crewWait > 0 then return false end
		local ents = Spawn(gunCrewXml(gunRoleName(gun)), GetBodyTransform(gun.cab), true, true)
		for i = 1, #(ents or {}) do
			if GetEntityType(ents[i]) == "body" then gun.crew = ents[i] end
		end
		if gun.crew == nil then
			gun.crewWait = 5
			return false
		end
		gun.crewVoxels = bodyVoxels(gun.crew)
		gun.botRest = 2 + math.random() * GUN_BOT_REST
		gun.botAim = nil
		gunCrewPlace(gun)
		return false
	end
	-- hurt enough, it falls
	if (tonumber(GetTagValue(gun.crew, "siegebothp")) or 100) <= 0 or bodyVoxels(gun.crew) < gun.crewVoxels * 0.6 then
		local body = gun.crew
		gun.crew = nil
		gun.crewWait = GUN_BOT_RESPAWN
		RemoveTag(body, "siegebot")
		SetBodyDynamic(body, true)
		SetBodyActive(body, true)
		server.gunLitter = server.gunLitter or {}
		table.insert(server.gunLitter, { body = body, t = GetTime() + 8 })
		return false
	end
	if gun.firing or gun.reload > 0 then return false end
	gun.botRest = gun.botRest - dt
	if gun.botRest > 0 then return false end
	local ball = gunPickBall(gun)
	if ball == nil then
		gun.botRest = 5
		return false
	end
	-- pick something, aim, then fire when lined up
	if gun.botAim == nil then
		local target = gunCrewTarget(gun)
		if target == nil then
			gun.botRest = 4
			return false
		end
		local miss = GUN_BOT_MISS[GetInt("level.siege.bots.skill")] or GUN_BOT_MISS[2]
		local yaw = gunYawTo(gun, target)
		local pitch = 0
		local aimFrom = TransformToParentPoint(gun.home, gun.armLocal.pos)
		local delta = VecSub(target, aimFrom)
		local flat = math.sqrt(delta[1] * delta[1] + delta[3] * delta[3])
		if gun.kind == "treb" then
			shared.gunRange[gun.id] = clampGun(flat + (math.random() - 0.5) * miss * 3, TREB_RANGE_MIN, TREB_RANGE_MAX)
		else
			local info = GUN_BALLS[ball]
			local v2 = info[1] * info[1]
			local inside = v2 * v2 - info[2] * (info[2] * flat * flat + 2 * delta[2] * v2)
			if inside < 0 then
				gun.botRest = 3
				return false
			end
			pitch = math.deg(math.atan((v2 - math.sqrt(inside)) / (info[2] * math.max(flat, 0.01))))
			pitch = clampGun(pitch + (math.random() - 0.5) * miss * 2, GUN_PITCH_MIN, GUN_PITCH_MAX)
		end
		gun.botAim = { yaw = clampGun(yaw + (math.random() - 0.5) * miss * 2, -gun.yawLimit, gun.yawLimit), pitch = pitch }
	end
	local aim = gun.botAim
	local moved = false
	local dy = aim.yaw - gun.yaw
	if math.abs(dy) > 0.05 then
		gun.yaw = gun.yaw + clampGun(dy, -GUN_YAW_SPEED * dt, GUN_YAW_SPEED * dt)
		moved = true
	end
	if gun.kind ~= "treb" then
		local dp = aim.pitch - gun.pitch
		if math.abs(dp) > 0.05 then
			gun.pitch = gun.pitch + clampGun(dp, -GUN_PITCH_SPEED * dt, GUN_PITCH_SPEED * dt)
			moved = true
		end
	end
	if moved then
		gunCrewPlace(gun)
		return true
	end
	-- lined up: let fly
	gun.botAim = nil
	gun.botRest = (gun.kind == "treb" and 4 or GUN_BOT_REST * gunReloadTime() / GUN_RELOAD_TIME) * (0.8 + math.random() * 0.5)
	if gun.kind == "treb" then
		gun.firing = 0
		gun.fired = false
		shared.gunReady[gun.id] = false
		PlaySound(server.gunCreak, GetBodyTransform(gun.cab).pos, 2)
	elseif server.gunBotShoot then
		server.gunBotShoot(gun)
	end
	return false
end

function server.gunLitterTick()
	local list = server.gunLitter
	if list == nil then return end
	for i = #list, 1, -1 do
		if GetTime() > list[i].t then
			if IsHandleValid(list[i].body) then Delete(list[i].body) end
			table.remove(list, i)
		end
	end
end

-- The carriage and arm are moved here. Called every tick from main.lua.
function server.gunsTick(dt)
	server.gunRetry = (server.gunRetry or 0) - dt
	if next(server.guns) == nil and GetTime() < 30 and server.gunRetry <= 0 then
		server.gunRetry = 1
		server.gunsFind()
	 end
	local now = GetTime()
	server.gunLitterTick()
	for _, gun in pairs(server.guns) do
		if gun.alive and now >= (gun.nextCheck or 0) then
			gun.nextCheck = now + 1 + math.random()
			gunCheckDamage(gun)
		end
		if gun.alive then
			local op = shared.gunOperator[gun.id]
			if op and (GetPlayerHealth(op) <= 0 or not gunAllowed(op, gun) or VecLength(VecSub(GetPlayerPos(op), GetBodyTransform(gun.cab).pos)) > GUN_KEEP_REACH) then
				gunRelease(gun)
				op = nil
			end
			local moved = false
			if gun.h ~= 0 then
				local y = clampGun(gun.yaw - gun.h * GUN_YAW_SPEED * dt, -gun.yawLimit, gun.yawLimit)
				if y ~= gun.yaw then gun.yaw = y moved = true end
			end
			if gun.kind == "treb" then
				if gun.v ~= 0 then
					shared.gunRange[gun.id] = clampGun(shared.gunRange[gun.id] + gun.v * TREB_RANGE_SPEED * dt, TREB_RANGE_MIN, TREB_RANGE_MAX)
				end
				if gun.reload > 0 then
					-- winding back down
					gun.reload = math.max(0, gun.reload - dt)
					gun.swing = TREB_SWING_ANGLE * math.min(1, gun.reload / (gun.reloadTotal or TREB_RELOAD_TIME))
					moved = true
					if gun.reload == 0 then shared.gunReady[gun.id] = true end
				elseif gun.firing then
					gun.firing = gun.firing + dt
					local k = math.min(1, gun.firing / TREB_SWING_TIME)
					gun.swing = TREB_SWING_ANGLE * k * k
					moved = true
					if not gun.fired and k >= TREB_RELEASE_AT then
						gun.fired = true
						if op then server.gunPress[op] = true elseif gun.crew and server.gunBotShoot then server.gunBotShoot(gun) end
					end
					if k >= 1 then
						gun.firing = nil
						gun.fired = false
						gun.reloadTotal = trebReloadTime()
						gun.reload = gun.reloadTotal
					end
				end
			elseif gun.v ~= 0 then
				local a = clampGun(gun.pitch + gun.v * GUN_PITCH_SPEED * dt, GUN_PITCH_MIN, GUN_PITCH_MAX)
				if a ~= gun.pitch then gun.pitch = a moved = true end
			end
			if op == nil and server.gunCrewTick(gun, dt) then moved = true end
			if op and gun.crew then server.gunCrewRemove(gun) end
			if moved then
				gunPose(gun)
				if op then gunSeatPlayer(gun, op) end
			end
		end
	end
end

-- The Transform main.lua fires from for this player, or nil if they aren't on a gun.
function server.gunMount(player)
	local gun = server.gunByPlayer[player]
	if gun == nil or not gun.alive then return nil end
	return gun, gunAimTransform(gun.cab, gun.arm, gun.kind)
end

function server.gunEnter(p, id)
	local gun = server.guns[id]
	if gun == nil or not gun.alive or shared.gunOperator[id] or server.gunByPlayer[p] then return end
	if VecLength(VecSub(GetPlayerPos(p), GetBodyTransform(gun.cab).pos)) > GUN_KEEP_REACH then return end
	if not gunAllowed(p, gun) then
		ClientCall(p, "client.gunNotice", gun.side == "defend" and "Defenders can man this once the siege starts." or "Attackers can man the guns once the siege starts.")
		return
	end
	shared.gunOperator[id] = p
	server.gunByPlayer[p] = gun
	gun.heldTool = GetPlayerTool(p)
	SetPlayerTool("none", p)
	gunSeatPlayer(gun, p)
end

function server.gunExit(p)
	local gun = server.gunByPlayer[p]
	if gun then gunRelease(gun) end
end

function server.gunInput(p, h, v, down)
	local gun = server.gunByPlayer[p]
	if gun then gun.h, gun.v, gun.down = h, v, down end
end

function server.gunFire(p)
	local gun = server.gunByPlayer[p]
	if gun == nil then return end
	if gun.kind == "treb" then
		if not gun.firing and gun.reload == 0 then
			gun.firing = 0
			gun.fired = false
			shared.gunReady[gun.id] = false
			PlaySound(server.gunCreak, GetBodyTransform(gun.cab).pos, 2)
		end
	else
		server.gunPress[p] = true
	end
end

function server.gunCycle(p)
	if server.gunByPlayer[p] and server.cannonCycleAmmo then server.cannonCycleAmmo(p) end
end

-- ---------- client ----------

client.gunMine = nil

function client.gunNotice(text)
	client.gunNoticeText = text
	client.gunNoticeTime = 3
end

local function gunFindOwn()
	if client.gunList == nil or (#client.gunList == 0 and GetTime() < 30) then
		client.gunList = {}
		local arms = {}
		local armBodies = FindBodies("siegegunarm", true)
		for i = 1, #armBodies do arms[GetTagValue(armBodies[i], "siegegunarm")] = armBodies[i] end
		local cabs = FindBodies("siegegun", true)
		for i = 1, #cabs do
			local id = GetTagValue(cabs[i], "siegegun")
			if arms[id] then
				client.gunList[#client.gunList + 1] = { id = id, cab = cabs[i], arm = arms[id], kind = GetTagValue(cabs[i], "siegegunkind") }
			end
		end
	end
	return client.gunList
end

local function gunLookedAt(camera)
	local forward = TransformToParentVec(camera, Vec(0, 0, -1))
	local best, bestDot = nil, GUN_USE_AIM
	local list = gunFindOwn()
	for i = 1, #list do
		local g = list[i]
		if IsHandleValid(g.arm) and IsHandleValid(g.cab) and not IsBodyDynamic(g.cab) then
			local mn, mx = GetBodyBounds(g.cab)
			local to = VecSub(VecLerp(mn, mx, 0.5), camera.pos)
			local d = VecLength(to)
			if d < (g.kind == "treb" and GUN_USE_REACH * 2 or GUN_USE_REACH) then
				local dot = d > 0.01 and VecDot(forward, VecScale(to, 1 / d)) or 1
				if dot > bestDot then best, bestDot = g, dot end
			end
		end
	end
	return best
end

local function gunDrawArc(aim, speed, gravity)
	local forward = TransformToParentVec(aim, Vec(0, 0, -1))
	local pos, vel = aim.pos, VecScale(forward, speed)
	for i = 1, 90 do
		local nextVel = VecAdd(vel, Vec(0, -gravity * 0.1, 0))
		local nextPos = VecAdd(pos, VecScale(VecAdd(vel, nextVel), 0.05))
		local step = VecSub(nextPos, pos)
		local len = VecLength(step)
		local hit, dist = QueryRaycast(pos, VecNormalize(step), len)
		if hit then
			local at = VecAdd(pos, VecScale(VecNormalize(step), dist))
			DrawLine(pos, at, 1, 0.75, 0.25, 0.8)
			PointLight(at, 1, 0.3, 0.1, 2)
			DrawLine(VecAdd(at, Vec(-0.8, 0.1, 0)), VecAdd(at, Vec(0.8, 0.1, 0)), 1, 0.25, 0.1, 1)
			DrawLine(VecAdd(at, Vec(0, 0.1, -0.8)), VecAdd(at, Vec(0, 0.1, 0.8)), 1, 0.25, 0.1, 1)
			return
		end
		DrawLine(pos, nextPos, 1, 0.75, 0.25, 0.8)
		pos, vel = nextPos, nextVel
	end
end

function client.gunsTick(dt)
	local me = GetLocalPlayer()
	if client.gunNoticeTime and client.gunNoticeTime > 0 then client.gunNoticeTime = client.gunNoticeTime - dt end
	if me == 0 then return end

	local mine = nil
	local list = gunFindOwn()
	for i = 1, #list do
		if shared.gunOperator[list[i].id] == me then mine = list[i] end
	end

	if mine == nil then
		if client.gunMine then
			SetBool("game.player.disableinput", false)
			SetBool("game.disablemap", false)
			SetBool("game.disablepause", false)
			client.gunMine = nil
			client.gunCam = 0
		end
		client.gunLookTimer = (client.gunLookTimer or 0) - dt
		if client.gunLookTimer <= 0 then
			client.gunLookTimer = 0.1
			client.gunLooked = GetPlayerHealth(me) > 0 and gunLookedAt(GetPlayerCameraTransform(me)) or nil
		end
		if GetPlayerHealth(me) > 0 then
			if client.gunLooked and not shared.gunOperator[client.gunLooked.id] and InputPressed("interact") then
				ServerCall("server.gunEnter", me, client.gunLooked.id)
			end
		end
		return
	end

	client.gunMine = mine
	client.gunLooked = nil
	client.gunCam = math.min(1, (client.gunCam or 0) + dt * 2)
	SetBool("game.disablemap", true)
	SetBool("game.disablepause", true)
	SetBool("game.player.disableinput", true)
	if InputPressed("interact") or InputPressed("pause") then
		ServerCall("server.gunExit", me)
		return
	end

	local h = (InputDown("right") and 1 or 0) - (InputDown("left") and 1 or 0)
	local v = (InputDown("up") and 1 or 0) - (InputDown("down") and 1 or 0)
	local down = InputDown("usetool")
	if h ~= client.gunH or v ~= client.gunV or down ~= client.gunDown then
		client.gunH, client.gunV, client.gunDown = h, v, down
		ServerCall("server.gunInput", me, h, v, down)
	end
	if InputPressed("usetool") then ServerCall("server.gunFire", me) end
	if InputPressed("r") then ServerCall("server.gunCycle", me) end

	-- camera behind and above the breech, following the barrel or the carriage
	local base = GetBodyTransform(mine.kind == "treb" and mine.cab or mine.arm)
	local size = tonumber(GetTagValue(mine.cab, "siegegunscale")) or 1
	local offset = mine.kind == "treb" and Vec(0, 3.2 * (size < 1 and 0.8 or 1), 6.5 * size) or Vec(0, 1.3, 2.6)
	local tilt = Quat()
	local view = TransformToParentTransform(base, Transform(offset, tilt))
	if mine.kind ~= "treb" then
		-- in a pillbox the view sits further forward, so the roof can't get in the way
		local eye = HasTag(mine.cab, "siegeguncover") and Vec(0, 2.3, -0.5) or Vec(0, 2.7, 2.4)
		view = Transform(TransformToParentPoint(GetBodyTransform(mine.cab), eye), GetBodyTransform(mine.arm).rot)
	end
	local current = GetPlayerCameraTransform()
	SetCameraTransform(Transform(VecLerp(current.pos, view.pos, client.gunCam), QuatSlerp(current.rot, view.rot, client.gunCam)))

	local ammo = shared.cannonAmmoType[me] or "breaker"
	local ball = GUN_BALLS[ammo] or GUN_BALLS.breaker
	QueryRejectBody(mine.cab)
	QueryRejectBody(mine.arm)
	if mine.kind == "treb" then
		-- no arc and no distance on a trebuchet: the winch clicks as the throw gets heavier or lighter
		local range = shared.gunRange[mine.id] or 80
		if client.gunClickAt == nil then client.gunClickAt = range end
		if math.abs(range - client.gunClickAt) >= 6 then
			client.gunClickAt = range
			if client.gunClick == nil then client.gunClick = LoadSound("clickdown.ogg") end
			PlaySound(client.gunClick, GetBodyTransform(mine.cab).pos, 0.7, false, 0.6 + 0.8 * (range - TREB_RANGE_MIN) / (TREB_RANGE_MAX - TREB_RANGE_MIN))
		end
	else
		gunDrawArc(gunAimTransform(mine.cab, mine.arm, mine.kind), gunBallSpeed(mine.kind, ammo, shared.gunRange[mine.id]), ball[2])
	end
end

function client.gunsDraw()
	local me = GetLocalPlayer()
	if client.gunNoticeTime and client.gunNoticeTime > 0 and client.gunNoticeText then
		UiPush()
			UiTranslate(UiCenter(), UiMiddle() + 110)
			UiAlign("center middle")
			UiFont("bold.ttf", 22)
			UiTextShadow(0, 0, 0, 0.8, 2)
			UiColor(1, 0.7, 0.4)
			UiText(client.gunNoticeText)
		UiPop()
	end
	if client.gunLooked then
		local name = client.gunLooked.kind == "treb" and "trebuchet" or "cannon"
		local text = "[E]  Man the " .. name
		if shared.gunOperator[client.gunLooked.id] then text = "Someone is on this " .. name end
		UiPush()
			UiTranslate(UiCenter(), UiMiddle() + 70)
			UiAlign("center middle")
			UiFont("bold.ttf", 24)
			UiTextShadow(0, 0, 0, 0.8, 2)
			UiColor(1, 0.92, 0.6)
			UiText(text)
		UiPop()
	end
	if client.gunMine == nil or me == 0 then return end
	if client.gunMine.kind ~= "treb" then UiPush()
		UiTranslate(UiCenter(), UiMiddle())
		UiAlign("center middle")
		UiColor(1, 0.85, 0.25, 0.95)
		UiRect(2, 22)
		UiRect(22, 2)
	UiPop() end
	UiPush()
		UiTranslate(UiCenter(), UiHeight() - 132)
		UiAlign("center middle")
		UiFont("bold.ttf", 20)
		UiTextShadow(0, 0, 0, 0.8, 2)
		UiColor(1, 1, 1)
		if client.gunMine.kind == "treb" then
			local state = shared.gunReady[client.gunMine.id] and "READY" or "WINDING"
			UiText(state .. "  |  A/D: turn  |  W/S: heavier / lighter throw  |  LMB: release  |  R: ball type  |  E: leave")
		else
			UiText("A/D: turn  |  W/S: elevation  |  LMB: fire  |  R: ball type  |  E: leave")
		end
	UiPop()
end
