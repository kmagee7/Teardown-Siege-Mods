#version 2
#include "scripts/fixed_guns.lua"

local TOOL_ID = "handcannon"
local TOOL_NAME = "THE CANNON"
-- Register the XML prefab so its vox scale can be changed without deleting
-- detail from the original MagicaVoxel model.
local TOOL_VOX = "MOD/prefabs/cannon.xml"

local RELOAD_TIME = 2.5
local PROJECTILE_SPEED = 40.0
local PROJECTILE_GRAVITY = 10.0
local PROJECTILE_LIFETIME = 20.0
local IMPACT_POWER = 2.5
local BREAKER_IMPACT_POWER = 0.5
local BREAKER_PENETRATIONS = 1
local BREAKER_TUNNEL_DEPTH = 1.20
local BREAKER_TUNNEL_STEP = 0.20
local BREAKER_HOLE_SOFT = 0.55
local BREAKER_HOLE_MEDIUM = 0.50
local BREAKER_HOLE_HARD = 0.45
local BREAKER_SPEED_RETENTION = 0.82
local BREAKER_RICOCHET_POWER = 0.45
local BREAKER_RICOCHET_FACTOR = 0.35
local BREAKER_RICOCHET_FRICTION = 0.7
local MAX_BREAKER_RICOCHETS = 3
local ULTRA_RICOCHET_POWER = 0.3
local ULTRA_RICOCHET_FACTOR = 0.9
local ULTRA_RICOCHET_FRICTION = 0.98
local RICOCHET_INITIAL_SPEED = 65.0
local MAX_ULTRA_RICOCHETS = 30
local ULTRA_EXPLOSION_POWER = 4.0
local ULTRA_ULTRA_BLAST_COUNT = 10
local ULTRA_ULTRA_MINI_COUNT = 90
local ULTRA_ULTRA_MUZZLE_HEIGHT = 1.35
local NORMAL_EXPLOSION_POWER = 2.5
local FULL_AUTO_INTERVAL = 0.12
local FULL_AUTO_SPEED = 70.0
local FULL_AUTO_GRAVITY = 6.0
local FULL_AUTO_IMPACT_POWER = 0.6
local PHYSICS_BALL_SPEED = 80.0
local PHYSICS_BALL_MUZZLE_HEIGHT = 1.78
local PHYSICS_BALL_MUZZLE_CLEARANCE = -0.20
local PHYSICS_BALL_EXTRA_GRAVITY = 12.0
local PHYSICS_BALL_LIFETIME = 20.0
local PHYSICS_BALL_MAX = 50
local GIANT_BALL_SPEED = 45.0
local GIANT_BALL_MUZZLE_CLEARANCE = 2.2
local TETHER_BALL_SPEED = 38.0
-- A long, heavy chain: allow a wide swing but correct extension aggressively
-- once the ball reaches the end, so the tether does not feel elastic.
local TETHER_CABLE_LENGTH = 10.0
local TETHER_MAX_CORRECTION_SPEED = 150.0
local TETHER_MAX_IMPULSE = 1000000.0
local TETHER_SWING_RESPONSE = 14.0
local TETHER_SWING_MAX_ACCELERATION = 110.0
local TETHER_CHAIN_LINK_COUNT = 20
local TETHER_CHAIN_LINK_SPACING = 0.48
local TETHER_CHAIN_DEPLOY_DISTANCE = 8.0
local TETHER_CHAIN_MAX_CORRECTION_SPEED = 90.0
local TETHER_CHAIN_MAX_IMPULSE = 300000.0
local TETHER_MIN_CABLE_LENGTH = 2.5
local TETHER_MAX_CABLE_LENGTH = 14.0
local TETHER_REEL_PER_NOTCH = 1.25
local TETHER_FLICK_SPEED = 38.0
local MINI_CANNONBALL_COUNT = 180
local MINI_CANNONBALL_SPEED = 28.0
local MINI_CANNONBALL_IMPACT_POWER = 0.7
local ERASER_LAUNCH_SPEED = 48.0
local ERASER_GRAVITY = 20.0
local ERASER_LOB_LIFT = 0.01
local ERASER_MUZZLE_HEIGHT = 1.4
local BREAKER_MUZZLE_HEIGHT = 1.2
local ERASER_MUZZLE_CLEARANCE = 0.65
local ERASER_MIN_AIM_DISTANCE = 25.0
local CANNON_MINE_RISE_HEIGHT = 1.25
local CANNON_MINE_RISE_TIME = 3.0
local CANNON_MINE_LAND_PAUSE = 0.75
local MIN_RICOCHET_SPEED = 3.0
local MUZZLE_DISTANCE = 1.5

shared.cannonShotSerial = shared.cannonShotSerial or {}
shared.cannonAmmoType = shared.cannonAmmoType or {}
shared.eraserMines = shared.eraserMines or {}
shared.tetherVisuals = shared.tetherVisuals or {}
shared.tetherActive = shared.tetherActive or {}

local function players()
	local allPlayers = GetAllPlayers()
	local index = 0
	return function()
		index = index + 1
		return allPlayers[index]
	end
end

local function findSpawnedBody(entities)
	for _, entity in ipairs(entities) do
		if GetEntityType(entity) == "body" then
			return entity
		end
	end

	for _, entity in ipairs(entities) do
		if GetEntityType(entity) == "shape" then
			return GetShapeBody(entity)
		end
	end

	return 0
end

-- Spawn returns every entity created by the prefab and does not guarantee that
-- the first body is the projectile's simulated body. Physics ammunition must
-- select a genuinely dynamic body; velocity on a static body is ignored.
local function findSpawnedDynamicBody(entities)
	for _, entity in ipairs(entities) do
		if GetEntityType(entity) == "body" and IsBodyDynamic(entity) then
			return entity
		end
	end

	for _, entity in ipairs(entities) do
		if GetEntityType(entity) == "shape" then
			local body = GetShapeBody(entity)
			if body ~= 0 and IsHandleValid(body) and IsBodyDynamic(body) then
				return body
			end
		end
	end

	return 0
end

local function findSpawnedBodyWithTag(entities, tag)
	for _, entity in ipairs(entities) do
		if GetEntityType(entity) == "body" and HasTag(entity, tag) then
			return entity
		end
	end
	return 0
end

local function findSpawnedJointWithTag(entities, tag)
	for _, entity in ipairs(entities) do
		if GetEntityType(entity) == "joint" and HasTag(entity, tag) then
			return entity
		end
	end
	return 0
end

local function calculateBallisticDirection(origin, target, speed, gravity)
	local delta = VecSub(target, origin)
	local horizontal = Vec(delta[1], 0, delta[3])
	local horizontalDistance = VecLength(horizontal)
	if horizontalDistance < 0.01 or gravity <= 0 then
		return VecNormalize(delta)
	end

	local speedSquared = speed * speed
	local discriminant = speedSquared * speedSquared
		- gravity * (gravity * horizontalDistance * horizontalDistance
		+ 2 * delta[2] * speedSquared)
	if discriminant < 0 then
		-- The target is outside the exact ballistic range. Use a modest upward
		-- bias instead of aiming below it.
		return VecNormalize(VecAdd(VecNormalize(delta), Vec(0, 0.12, 0)))
	end

	local tangent = (speedSquared - math.sqrt(discriminant))
		/ (gravity * horizontalDistance)
	return VecNormalize(VecAdd(
		VecNormalize(horizontal),
		Vec(0, tangent, 0)
	))
end

local function spawnMuzzleEffect(position, direction)
	-- Fast, compact smoke puff rather than a lingering cloud.
	for i = 1, 6 do
		ParticleReset()
		ParticleType("smoke")
		ParticleColor(0.75, 0.72, 0.65)
		ParticleAlpha(0.75, 0, "easeout", 0.05, 0.25)
		ParticleRadius(0.08, 0.28)
		ParticleGravity(-0.5)
		ParticleDrag(0.12)

		local spread = Vec(
			(math.random() - 0.5) * 2.0,
			(math.random() - 0.5) * 2.0,
			(math.random() - 0.5) * 2.0
		)
		local velocity = VecAdd(VecScale(direction, 10 + math.random() * 7), spread)
		SpawnParticle(position, velocity, 0.35 + math.random() * 0.3)
	end

	-- Short, non-destructive muzzle explosion/flash.
	for i = 1, 4 do
		ParticleReset()
		ParticleType("smoke")
		ParticleColor(1.0, 0.32, 0.04)
		ParticleAlpha(1.0, 0, "easeout", 0.0, 0.08)
		ParticleRadius(0.12, 0.36)
		ParticleEmissive(8)
		ParticleGravity(0)
		ParticleDrag(0.05)
		SpawnParticle(position, VecScale(direction, 8 + math.random() * 5), 0.14)
	end

	PointLight(position, 1.0, 0.38, 0.08, 7)
end

-- Siege patch: each ball type has its own damage multiplier, chosen by the host.
-- Outside Siege it is always 1.
local function siegePower(ammoType)
	if ammoType and GetBool("level.siege.cannon.active") then
		local power = GetFloat("level.siege.cannon.power." .. ammoType)
		if power > 0 then return power end
	end
	return 1.0
end

-- Same as prefabs/physics-cannonball.xml, with the density scaled.
local function siegeTraditionalBallXml(power)
	return string.format("<group name='physics_cannonball_prefab'><body name='physics_cannonball' tags='awake physicsball' dynamic='true'>"
		.. "<vox name='physics_cannonball_shape' tags='cannonball physicsball unbreakable' pos='0 0.1 0' density='%.3f' strength='100' file='MOD/vox/cannonball.vox'/>"
		.. "</body></group>", 75 * power)
end

-- Explosion size must be 0.5 to 4.0. Below that, cut a small hole instead so weak settings stay weak.
local function siegeExplosion(position, size, ammoType)
	local scaled = size * siegePower(ammoType)
	if scaled >= 0.5 then
		Explosion(position, math.min(scaled, 4.0))
	else
		MakeHole(position, scaled, scaled * 0.8, scaled * 0.6, true)
	end
end

local function scatterExplosionDebris(position, radius, minimumSpeed, maximumSpeed, randomness)
	QueryRequire("physical dynamic")
	local bodies = QueryAabbBodies(
		VecAdd(position, Vec(-radius, -radius, -radius)),
		VecAdd(position, Vec(radius, radius, radius))
	)

	for i = 1, #bodies do
		local body = bodies[i]
		local minimum, maximum = GetBodyBounds(body)
		local center = VecLerp(minimum, maximum, 0.5)
		local offset = VecSub(center, position)
		local distance = VecLength(offset)
		if distance > 0.05 and distance < radius then
			local radialDirection = VecNormalize(offset)
			local randomDirection = GetRandomDirection()
			local direction = VecNormalize(VecAdd(
				VecScale(radialDirection, 1.0 - randomness),
				VecScale(randomDirection, randomness)
			))
			local falloff = 1.0 - distance / radius
			local speedLimit = minimumSpeed + (maximumSpeed - minimumSpeed) * falloff
			local launchSpeed = GetRandomFloat(minimumSpeed, speedLimit)
			-- Replace the explosion's irregular velocity instead of adding to it.
			-- Random variation prevents every fragment forming a uniform ring.
			SetBodyVelocity(body, VecScale(direction, launchSpeed))
			SetBodyAngularVelocity(body, GetRandomDirection(GetRandomFloat(3, 10)))
		end
	end
end

local function spawnMiniCannonballs(position, owner, now, requestedCount)
	local cannonballCount = requestedCount or MINI_CANNONBALL_COUNT
	for shot = 1, cannonballCount do
		local angle = (shot - 1) * math.pi * 2 / cannonballCount
		local elevation = 0.05 + 0.12 * ((shot - 1) % 6)
		local direction = VecNormalize(Vec(math.cos(angle), elevation, math.sin(angle)))
		-- Give all sixty balls enough separation to avoid colliding with one
		-- another immediately at the centre of the burst.
		local spawnPosition = VecAdd(position, VecScale(direction, 1.8))
		local entities = Spawn(
			"MOD/prefabs/mini-cannonball.xml",
			Transform(spawnPosition, QuatLookAt(spawnPosition, VecAdd(spawnPosition, direction)))
		)
		local body = findSpawnedBody(entities)
		if body ~= 0 and IsHandleValid(body) then
			SetBodyDynamic(body, false)
			table.insert(server.projectiles, {
				body = body,
				position = spawnPosition,
				velocity = VecScale(direction, MINI_CANNONBALL_SPEED),
				spawnTime = now,
				owner = owner,
				ammoType = "mini",
				powerType = requestedCount and "ultraultra" or "eraser",
				impactCount = 0
			})
		end
	end
	siegeExplosion(position, 0.8, requestedCount and "ultraultra" or "eraser")
end

-- Siege patch: while the Siege game mode is active, skip rounds the host turned off.
-- Outside Siege these registry keys don't exist and the cannon behaves as normal.
local SIEGE_AMMO_ORDER = { "breaker", "ricochet", "explosive", "ultraultra", "normalexplosive",
	"eraser", "fullauto", "physics", "tetherphysics", "giantphysics" }

-- A trebuchet has its own list of allowed balls.
local function siegeEnforceAmmo(player, trebuchet)
	if not GetBool("level.siege.cannon.active") then return end
	local list = "level.siege.cannon.ammo."
	if trebuchet and GetBool("level.siege.treb.active") then list = "level.siege.treb.ammo." end
	local current = shared.cannonAmmoType[player]
	if GetBool(list .. current) then return end
	local start = 1
	for i = 1, #SIEGE_AMMO_ORDER do
		if SIEGE_AMMO_ORDER[i] == current then start = i end
	end
	for step = 1, #SIEGE_AMMO_ORDER do
		local candidate = SIEGE_AMMO_ORDER[((start + step - 1) % #SIEGE_AMMO_ORDER) + 1]
		if GetBool(list .. candidate) then
			shared.cannonAmmoType[player] = candidate
			return
		end
	end
end

-- A bot crew fires the gun: one of the simpler balls, through the same flight code as everything else.
function server.gunBotShoot(gun)
	local list = (gun.kind == "treb" and GetBool("level.siege.treb.active")) and "level.siege.treb.ammo." or "level.siege.cannon.ammo."
	local ammo = nil
	for _, id in ipairs({ "physics", "giantphysics", "normalexplosive", "explosive", "breaker", "ricochet" }) do
		if GetBool(list .. id) then
			ammo = id
			break
		end
	end
	if ammo == nil then return end
	local aim = gunAimTransform(gun.cab, gun.arm, gun.kind)
	local dir = TransformToParentVec(aim, Vec(0, 0, -1))
	local velocity = VecScale(dir, gunBallSpeed(gun.kind, ammo, shared.gunRange[gun.id]))
	local now = GetTime()
	if ammo == "physics" or ammo == "giantphysics" then
		local entities
		if ammo == "physics" and siegePower("physics") ~= 1.0 then
			entities = Spawn(siegeTraditionalBallXml(siegePower("physics")), aim)
		end
		if entities == nil or #entities == 0 then
			entities = Spawn(ammo == "physics" and "MOD/prefabs/physics-cannonball.xml" or "MOD/prefabs/giant-physics-cannonball.xml", aim)
		end
		local body = findSpawnedDynamicBody(entities)
		if body == 0 or not IsHandleValid(body) then return end
		SetBodyVelocity(body, velocity)
		table.insert(server.physicsBalls, { body = body, spawnTime = now })
	else
		local body = findSpawnedBody(Spawn("MOD/prefabs/cannonball.xml", aim))
		if body == 0 or not IsHandleValid(body) then return end
		table.insert(server.projectiles, { body = body, position = GetBodyTransform(body).pos, velocity = velocity, spawnTime = now, owner = 0, ammoType = ammo, impactCount = 0 })
	end
	if gun.kind ~= "treb" then spawnMuzzleEffect(aim.pos, dir) end
	ClientCall(0, "client.gunBotBang", aim.pos, gun.kind == "treb")
end

function client.gunBotBang(pos, quiet)
	if not quiet and client.cannonBang then PlaySound(client.cannonBang[math.random(0, 3)], pos, 1.4) end
end

function server.cannonCycleAmmo(player)
	local current = shared.cannonAmmoType[player]
	for i = 1, #SIEGE_AMMO_ORDER do
		if SIEGE_AMMO_ORDER[i] == current then
			shared.cannonAmmoType[player] = SIEGE_AMMO_ORDER[(i % #SIEGE_AMMO_ORDER) + 1]
			return
		end
	end
	shared.cannonAmmoType[player] = "breaker"
end

function server.init()
	RegisterTool(TOOL_ID, TOOL_NAME, TOOL_VOX, 6)
	SetBool("game.tool." .. TOOL_ID .. ".enabled", true)
	SetBool("level.siege.cannon.patched", true)

	server.lastFireTime = {}
	server.projectiles = {}
	server.physicsBalls = {}
	server.tetherBalls = {}
	server.activeTetherByPlayer = {}
	server.cannonMines = {}
	server.nextEraserMineId = 1
	shared.cannonShotSerial = {}
	shared.cannonAmmoType = {}
	shared.eraserMines = {}
	shared.tetherVisuals = {}
	shared.tetherActive = {}
	server.gunsInit()
end

function server.tick(dt)
	local now = GetTime()
	server.gunsTick(dt)

	for player in players() do
		local mountedGun, mountedAim = server.gunMount(player)
		if server.lastFireTime[player] == nil then
			server.lastFireTime[player] = -RELOAD_TIME
		end
		if shared.cannonAmmoType[player] == nil then
			shared.cannonAmmoType[player] = "breaker"
		end

		if not mountedGun and GetPlayerTool(player) == TOOL_ID and InputPressed("r", player) then
			if shared.cannonAmmoType[player] == "breaker" then
				shared.cannonAmmoType[player] = "ricochet"
			elseif shared.cannonAmmoType[player] == "ricochet" then
				shared.cannonAmmoType[player] = "explosive"
			elseif shared.cannonAmmoType[player] == "explosive" then
				shared.cannonAmmoType[player] = "ultraultra"
			elseif shared.cannonAmmoType[player] == "ultraultra" then
				shared.cannonAmmoType[player] = "normalexplosive"
			elseif shared.cannonAmmoType[player] == "normalexplosive" then
				shared.cannonAmmoType[player] = "eraser"
			elseif shared.cannonAmmoType[player] == "eraser" then
				shared.cannonAmmoType[player] = "fullauto"
			elseif shared.cannonAmmoType[player] == "fullauto" then
				shared.cannonAmmoType[player] = "physics"
			elseif shared.cannonAmmoType[player] == "physics" then
				shared.cannonAmmoType[player] = "tetherphysics"
			elseif shared.cannonAmmoType[player] == "tetherphysics" then
				shared.cannonAmmoType[player] = "giantphysics"
			else
				shared.cannonAmmoType[player] = "breaker"
			end
		end
		siegeEnforceAmmo(player, mountedGun ~= nil and mountedGun.kind == "treb")

		local ammoType = shared.cannonAmmoType[player]
		if ammoType == "tetherphysics" then
			local activeTether = server.activeTetherByPlayer[player]
			-- The wheel normally cycles tools. Keep THE CANNON equipped for as long
			-- as a live tether needs those same wheel events for reel control.
			if not mountedGun and activeTether ~= nil and GetPlayerTool(player) ~= TOOL_ID then
				SetPlayerTool(TOOL_ID, player)
			end
			local wheel = InputValue("mousewheel", player)
			if activeTether ~= nil and wheel ~= 0 then
				activeTether.cableLength = math.max(
					TETHER_MIN_CABLE_LENGTH,
					math.min(
						TETHER_MAX_CABLE_LENGTH,
						activeTether.cableLength + wheel * TETHER_REEL_PER_NOTCH
					)
				)
				-- Scrolling away pays out the chain and throws the ball along the aim.
				if wheel > 0 and IsHandleValid(activeTether.body) then
					local camera = GetPlayerCameraTransform(player)
					local forward = VecNormalize(TransformToParentVec(camera, Vec(0, 0, -1)))
					SetBodyVelocity(activeTether.body, VecAdd(
						GetBodyVelocity(activeTether.body),
						VecScale(forward, wheel * TETHER_FLICK_SPEED)
					))
				end
			end
		end
		local wantsToFire = InputPressed("usetool", player)
		if mountedGun then
			wantsToFire = server.gunPress[player] == true
			server.gunPress[player] = false
		end
		if ammoType == "tetherphysics" and wantsToFire then
			local activeTether = server.activeTetherByPlayer[player]
			if activeTether ~= nil then
				activeTether.released = true
				server.activeTetherByPlayer[player] = nil
				shared.tetherVisuals[player] = nil
				shared.tetherActive[player] = false
				wantsToFire = false
			end
		end
		local fireInterval = RELOAD_TIME
		if ammoType == "fullauto" then
			if mountedGun then
				if mountedGun.kind ~= "treb" then wantsToFire = mountedGun.down end
			else
				wantsToFire = InputDown("usetool", player)
			end
			fireInterval = FULL_AUTO_INTERVAL
		end
		-- A trebuchet decides for itself when the ball leaves, so its reload is the swing.
		local mountedTreb = mountedGun and mountedGun.kind == "treb"
		if mountedGun and not mountedTreb then
			fireInterval = ammoType == "fullauto" and GUN_FULLAUTO_INTERVAL or gunReloadTime()
		end
		if (GetPlayerTool(player) == TOOL_ID or mountedGun) and wantsToFire then
			if mountedTreb or now - server.lastFireTime[player] >= fireInterval then
				server.lastFireTime[player] = now

				local camera = GetPlayerCameraTransform(player)
				local muzzle = GetToolLocationWorldTransform("muzzle", player)
				if mountedGun then
					camera = mountedAim
					muzzle = mountedAim
				end
				local muzzlePosition
				if muzzle then
					muzzlePosition = muzzle.pos
				else
					local fallbackDirection = TransformToParentVec(camera, Vec(0, 0, -1))
					muzzlePosition = VecAdd(camera.pos, VecScale(fallbackDirection, MUZZLE_DISTANCE))
				end
				local visualMuzzlePosition = VecCopy(muzzlePosition)
				if mountedGun then
					-- fires straight out of the barrel
				elseif shared.cannonAmmoType[player] == "eraser" then
					muzzlePosition = VecAdd(muzzlePosition, Vec(0, ERASER_MUZZLE_HEIGHT, 0))
				elseif shared.cannonAmmoType[player] == "breaker" then
					muzzlePosition = VecAdd(muzzlePosition, Vec(0, BREAKER_MUZZLE_HEIGHT, 0))
				elseif shared.cannonAmmoType[player] == "ultraultra" then
					local cameraUp = VecNormalize(TransformToParentVec(camera, Vec(0, 1, 0)))
					muzzlePosition = VecAdd(
						muzzlePosition,
						VecScale(cameraUp, ULTRA_ULTRA_MUZZLE_HEIGHT)
					)
				elseif shared.cannonAmmoType[player] == "physics"
					or shared.cannonAmmoType[player] == "tetherphysics"
					or shared.cannonAmmoType[player] == "giantphysics" then
					local cameraUp = VecNormalize(TransformToParentVec(camera, Vec(0, 1, 0)))
					muzzlePosition = VecAdd(
						muzzlePosition,
						VecScale(cameraUp, PHYSICS_BALL_MUZZLE_HEIGHT)
					)
				end

				-- Raycast from the camera to determine the exact crosshair target,
				-- then launch upward from the physical muzzle toward that point.
				local cameraDirection = VecNormalize(
					TransformToParentVec(camera, Vec(0, 0, -1))
				)
				QueryRejectPlayer(player)
				-- Do not let a recently fired cannonball become the next shot's
				-- crosshair target. For Eraser rounds, that short target distance
				-- produced an unexpectedly steep ballistic arc.
				for projectileIndex = 1, #server.projectiles do
					local projectileBody = server.projectiles[projectileIndex].body
					if IsHandleValid(projectileBody) then
						QueryRejectBody(projectileBody)
					end
				end
				for mineIndex = 1, #server.cannonMines do
					local mineBody = server.cannonMines[mineIndex].body
					if IsHandleValid(mineBody) then
						QueryRejectBody(mineBody)
					end
				end
				local aimHit, aimDistance = QueryRaycast(
					camera.pos,
					cameraDirection,
					500
				)
				local targetDistance = 100
				if aimHit then
					targetDistance = aimDistance
				end
				-- A close hit on the first frame after selecting/firing the tool can
				-- otherwise make the ballistic solver choose an extremely steep arc.
				if shared.cannonAmmoType[player] == "eraser" then
					targetDistance = math.max(targetDistance, ERASER_MIN_AIM_DISTANCE)
				end
				local targetPosition = VecAdd(
					camera.pos,
					VecScale(cameraDirection, targetDistance)
				)
				local direction = VecNormalize(VecSub(targetPosition, muzzlePosition))
				if shared.cannonAmmoType[player] == "eraser" then
					-- Use a fixed camera-relative launch angle. Solving a new ballistic
					-- arc against each raycast surface made identical-looking shots lob
					-- by noticeably different amounts.
					direction = VecNormalize(VecAdd(
						cameraDirection,
						Vec(0, ERASER_LOB_LIFT, 0)
					))
				elseif shared.cannonAmmoType[player] == "physics"
					or shared.cannonAmmoType[player] == "tetherphysics"
					or shared.cannonAmmoType[player] == "giantphysics" then
					-- Fire parallel to the crosshair with no artificial upward lob.
					direction = cameraDirection
				end
				if mountedGun then direction = cameraDirection end
				local projectileSpawnPosition = muzzlePosition
				if shared.cannonAmmoType[player] == "eraser" then
					projectileSpawnPosition = VecAdd(
						muzzlePosition,
						VecScale(direction, ERASER_MUZZLE_CLEARANCE)
					)
				elseif shared.cannonAmmoType[player] == "physics" then
					projectileSpawnPosition = VecAdd(
						muzzlePosition,
						VecScale(direction, PHYSICS_BALL_MUZZLE_CLEARANCE)
					)
				elseif shared.cannonAmmoType[player] == "tetherphysics" then
					projectileSpawnPosition = VecAdd(
						muzzlePosition,
						VecScale(direction, PHYSICS_BALL_MUZZLE_CLEARANCE)
					)
				elseif shared.cannonAmmoType[player] == "giantphysics" then
					projectileSpawnPosition = VecAdd(
						muzzlePosition,
						VecScale(direction, GIANT_BALL_MUZZLE_CLEARANCE)
					)
				end
				local projectilePrefab = "MOD/prefabs/cannonball.xml"
				if ammoType == "fullauto" then
					projectilePrefab = "MOD/prefabs/mini-cannonball.xml"
				elseif ammoType == "physics" then
					projectilePrefab = "MOD/prefabs/physics-cannonball.xml"
				elseif ammoType == "tetherphysics" then
					projectilePrefab = "MOD/prefabs/tethered-physics-cannonball.xml"
				elseif ammoType == "giantphysics" then
					projectilePrefab = "MOD/prefabs/giant-physics-cannonball.xml"
				end
				local entities = nil
				if ammoType == "physics" and siegePower("physics") ~= 1.0 then
					entities = Spawn(
						siegeTraditionalBallXml(siegePower("physics")),
						Transform(projectileSpawnPosition, camera.rot)
					)
				end
				if entities == nil or #entities == 0 then
					entities = Spawn(
						projectilePrefab,
						Transform(projectileSpawnPosition, camera.rot)
					)
				end
				local body = findSpawnedBody(entities)
				if ammoType == "physics" or ammoType == "giantphysics" then
					body = findSpawnedDynamicBody(entities)
				elseif ammoType == "tetherphysics" then
					body = findSpawnedBodyWithTag(entities, "tetherball")
				end

				if body ~= 0 and IsHandleValid(body) then
					local isEraser = shared.cannonAmmoType[player] == "eraser"
					local isPhysicsBall = shared.cannonAmmoType[player] == "physics"
						or shared.cannonAmmoType[player] == "tetherphysics"
						or shared.cannonAmmoType[player] == "giantphysics"
					local isGiantPhysicsBall = shared.cannonAmmoType[player] == "giantphysics"
					local isTetherPhysicsBall = shared.cannonAmmoType[player] == "tetherphysics"
					if isEraser then
						SetBodyDynamic(body, true)
					end
					local bodyTransform = GetBodyTransform(body)
					local launchSpeed = PROJECTILE_SPEED
					if isEraser then
						launchSpeed = ERASER_LAUNCH_SPEED
					elseif isPhysicsBall then
						if isGiantPhysicsBall then
							launchSpeed = GIANT_BALL_SPEED
						elseif isTetherPhysicsBall then
							launchSpeed = TETHER_BALL_SPEED
						else
							launchSpeed = PHYSICS_BALL_SPEED
						end
					elseif shared.cannonAmmoType[player] == "ricochet" then
						launchSpeed = RICOCHET_INITIAL_SPEED
					elseif shared.cannonAmmoType[player] == "fullauto" then
						launchSpeed = FULL_AUTO_SPEED
					end
					if mountedTreb then launchSpeed = gunBallSpeed("treb", shared.cannonAmmoType[player], shared.gunRange[mountedGun.id]) end
					local launchVelocity = VecScale(direction, launchSpeed)
					if isEraser then
						SetBodyVelocity(body, launchVelocity)
					end
					if isPhysicsBall and shared.cannonAmmoType[player] ~= "physics" and siegePower(shared.cannonAmmoType[player]) ~= 1.0 then
						-- Siege patch: a heavier ball hits harder without changing where it lands.
						local ballShapes = GetBodyShapes(body)
						for shapeIndex = 1, #ballShapes do
							SetShapeDensity(ballShapes[shapeIndex], GetProperty(ballShapes[shapeIndex], "density") * siegePower(shared.cannonAmmoType[player]))
						end
					end
					if isPhysicsBall then
						-- Match the proven physical-grenade pattern used by Workshop mods:
						-- spawn an already-dynamic body and assign velocity immediately.
						SetBodyVelocity(body, launchVelocity)
						SetBodyAngularVelocity(body, Vec(0, 0, 0))
						table.insert(server.physicsBalls, {
							body = body,
							spawnTime = now
						})
						if isTetherPhysicsBall then
							local tetherRecord = {
								body = body,
								player = player,
								spawnTime = now,
								released = false,
								links = {},
								linksSpawned = false,
								cableLength = TETHER_CABLE_LENGTH
							}
							table.insert(server.tetherBalls, tetherRecord)
							server.activeTetherByPlayer[player] = tetherRecord
							shared.tetherActive[player] = true
						end
					else
						table.insert(server.projectiles, {
							body = body,
							-- Track the body's true origin. A spawned vox body's origin is not
							-- guaranteed to be identical to the prefab transform position.
							position = bodyTransform.pos,
							velocity = launchVelocity,
							spawnTime = now,
							owner = player,
							ammoType = shared.cannonAmmoType[player],
							impactCount = 0
						})
					end
				end

				if not mountedTreb then
					shared.cannonShotSerial[player] = (shared.cannonShotSerial[player] or 0) + 1
					spawnMuzzleEffect(visualMuzzlePosition, direction)
				end
			end
		end
	end
end

function server.update(dt)
	local now = GetTime()

	local tetherIndex = 1
	while tetherIndex <= #server.tetherBalls do
		local tether = server.tetherBalls[tetherIndex]
		if tether.released or not IsHandleValid(tether.body) then
			if server.activeTetherByPlayer[tether.player] == tether then
				server.activeTetherByPlayer[tether.player] = nil
			end
			shared.tetherVisuals[tether.player] = nil
			shared.tetherActive[tether.player] = false
			for _, linkBody in ipairs(tether.links or {}) do
				if IsHandleValid(linkBody) then
					Delete(linkBody)
				end
			end
			table.remove(server.tetherBalls, tetherIndex)
		else
			local gunAnchor = GetToolLocationWorldTransform("muzzle", tether.player)
			local _, tetherGunAim = server.gunMount(tether.player)
			if tetherGunAim then gunAnchor = tetherGunAim end
			if not gunAnchor then
				gunAnchor = GetPlayerCameraTransform(tether.player)
			end
			local ballMin, ballMax = GetBodyBounds(tether.body)
			local ballCenter = VecLerp(ballMin, ballMax, 0.5)
			local cable = VecSub(ballCenter, gunAnchor.pos)
			local cableDistance = VecLength(cable)

			-- Wait until the launched ball has stretched most of the tether before
			-- inserting the physical links. Spawning all links on top of the muzzle
			-- would make their collisions kick the player and cannonball violently.
			if not tether.linksSpawned and cableDistance >= TETHER_CHAIN_DEPLOY_DISTANCE then
				for linkIndex = 1, TETHER_CHAIN_LINK_COUNT do
					local fraction = linkIndex / (TETHER_CHAIN_LINK_COUNT + 1)
					local linkPosition = VecLerp(gunAnchor.pos, ballCenter, fraction)
					local linkRotation = QuatLookAt(linkPosition, ballCenter)
					if linkIndex % 2 == 0 then
						linkRotation = QuatRotateQuat(linkRotation, QuatEuler(0, 0, 90))
					end
					local linkEntities = Spawn(
						"MOD/prefabs/tether-chain-link.xml",
						Transform(linkPosition, linkRotation)
					)
					local linkBody = findSpawnedDynamicBody(linkEntities)
					if linkBody ~= 0 and IsHandleValid(linkBody) then
						SetBodyAngularVelocity(
							linkBody,
							VecScale(GetRandomDirection(1.0), 2.0)
						)
						table.insert(tether.links, linkBody)
					end
				end
				tether.linksSpawned = #tether.links > 0
			end

			-- Build a chain of physical point constraints. Each link keeps its own
			-- rotation, velocity and collisions, which lets it strike scenery and
			-- rattle independently instead of behaving like a drawn laser line.
			if tether.linksSpawned then
				local previousBody = 0
				local previousCenter = gunAnchor.pos
				for _, linkBody in ipairs(tether.links) do
					if IsHandleValid(linkBody) then
						local linkMin, linkMax = GetBodyBounds(linkBody)
						local linkCenter = VecLerp(linkMin, linkMax, 0.5)
						local gap = VecSub(linkCenter, previousCenter)
						local gapDirection = VecNormalize(gap)
						local halfSpacing = TETHER_CHAIN_LINK_SPACING * 0.5
						ConstrainPosition(
							linkBody,
							previousBody,
							VecAdd(linkCenter, VecScale(gapDirection, -halfSpacing)),
							VecAdd(previousCenter, VecScale(gapDirection, halfSpacing)),
							TETHER_CHAIN_MAX_CORRECTION_SPEED,
							TETHER_CHAIN_MAX_IMPULSE
						)
						previousBody = linkBody
						previousCenter = linkCenter
					end
				end
				if previousBody ~= 0 then
					local finalGap = VecSub(ballCenter, previousCenter)
					local finalDirection = VecNormalize(finalGap)
					local halfSpacing = TETHER_CHAIN_LINK_SPACING * 0.5
					ConstrainPosition(
						tether.body,
						previousBody,
						VecAdd(ballCenter, VecScale(finalDirection, -halfSpacing)),
						VecAdd(previousCenter, VecScale(finalDirection, halfSpacing)),
						TETHER_CHAIN_MAX_CORRECTION_SPEED,
						TETHER_CHAIN_MAX_IMPULSE
					)
				end
			end

			-- Help the heavy ball follow changes in aim without locking it to the
			-- crosshair. The added velocity builds a controllable sideways swing,
			-- while the body's existing momentum and collisions remain physical.
			local camera = GetPlayerCameraTransform(tether.player)
			local aimDirection = VecNormalize(
				TransformToParentVec(camera, Vec(0, 0, -1))
			)
			local currentCableLength = tether.cableLength or TETHER_CABLE_LENGTH
			local swingTarget = VecAdd(
				gunAnchor.pos,
				VecScale(aimDirection, currentCableLength * 0.92)
			)
			local swingAcceleration = VecScale(
				VecSub(swingTarget, ballCenter),
				TETHER_SWING_RESPONSE
			)
			local swingAccelerationLength = VecLength(swingAcceleration)
			if swingAccelerationLength > TETHER_SWING_MAX_ACCELERATION then
				swingAcceleration = VecScale(
					VecNormalize(swingAcceleration),
					TETHER_SWING_MAX_ACCELERATION
				)
			end
			SetBodyVelocity(
				tether.body,
				VecAdd(
					GetBodyVelocity(tether.body),
					VecScale(swingAcceleration, dt)
				)
			)

			if cableDistance > currentCableLength then
				local cableDirection = VecNormalize(cable)
				local cableLimitPoint = VecAdd(
					gunAnchor.pos,
					VecScale(cableDirection, currentCableLength)
				)
				ConstrainPosition(
					tether.body,
					0,
					ballCenter,
					cableLimitPoint,
					TETHER_MAX_CORRECTION_SPEED,
					TETHER_MAX_IMPULSE
				)
			end
			if tether.linksSpawned then
				shared.tetherVisuals[tether.player] = nil
			else
				shared.tetherVisuals[tether.player] = {
					anchor = gunAnchor.pos,
					ball = ballCenter
				}
			end
			tetherIndex = tetherIndex + 1
		end
	end

	-- Native bodies already receive normal world gravity. Add a second downward
	-- acceleration to make this unusually heavy cannonball drop more decisively
	-- while retaining physical collision, rolling and bouncing.
	local physicsIndex = 1
	while physicsIndex <= #server.physicsBalls do
		local physicsBall = server.physicsBalls[physicsIndex]
		if not IsHandleValid(physicsBall.body)
			or now - physicsBall.spawnTime > PHYSICS_BALL_LIFETIME
			or (#server.physicsBalls > PHYSICS_BALL_MAX and physicsIndex == 1) then
			if IsHandleValid(physicsBall.body) and not HasTag(physicsBall.body, "tetherball") then
				Delete(physicsBall.body)
			end
			table.remove(server.physicsBalls, physicsIndex)
		else
			local velocity = GetBodyVelocity(physicsBall.body)
			SetBodyVelocity(physicsBall.body, VecAdd(
				velocity,
				Vec(0, -PHYSICS_BALL_EXTRA_GRAVITY * dt, 0)
			))
			physicsIndex = physicsIndex + 1
		end
	end

	local mineIndex = 1
	while mineIndex <= #server.cannonMines do
		local mine = server.cannonMines[mineIndex]
		if not IsHandleValid(mine.body) then
			shared.eraserMines[mine.id] = nil
			table.remove(server.cannonMines, mineIndex)
		else
			local armingElapsed = now - mine.startTime
			local riseElapsed = math.max(0, armingElapsed - CANNON_MINE_LAND_PAUSE)
			local progress = math.min(1.0, riseElapsed / CANNON_MINE_RISE_TIME)
			local smoothProgress = progress * progress * (3.0 - 2.0 * progress)
			local raisedPosition = VecAdd(mine.groundPosition, Vec(0, CANNON_MINE_RISE_HEIGHT * smoothProgress, 0))
			shared.eraserMines[mine.id] = {
				position = raisedPosition,
				startTime = mine.startTime,
				duration = CANNON_MINE_LAND_PAUSE + CANNON_MINE_RISE_TIME
			}
			SetBodyTransform(mine.body, Transform(raisedPosition, QuatEuler(0, now * 180, 0)))
			if progress >= 1.0 then
				Delete(mine.body)
				spawnMiniCannonballs(raisedPosition, mine.owner, now)
				shared.eraserMines[mine.id] = nil
				table.remove(server.cannonMines, mineIndex)
			else
				mineIndex = mineIndex + 1
			end
		end
	end

	local index = 1

	while index <= #server.projectiles do
		local projectile = server.projectiles[index]

		if not IsHandleValid(projectile.body) or now - projectile.spawnTime > PROJECTILE_LIFETIME then
			if IsHandleValid(projectile.body) then
				Delete(projectile.body)
			end
			table.remove(server.projectiles, index)
		else
			local projectileGravity = PROJECTILE_GRAVITY
			if projectile.ammoType == "eraser" then
				projectileGravity = ERASER_GRAVITY
			elseif projectile.ammoType == "fullauto" then
				projectileGravity = FULL_AUTO_GRAVITY
			end
			projectile.velocity = VecAdd(
				projectile.velocity,
				Vec(0, -projectileGravity * dt, 0)
			)

			local movement = VecScale(projectile.velocity, dt)
			local distance = VecLength(movement)
			local direction = VecNormalize(movement)

			QueryRejectBody(projectile.body)
			local hit, hitDistance, hitNormal, hitShape = QueryRaycast(
				projectile.position,
				direction,
				distance + 0.15
			)

			if hit then
				local impactPosition = VecAdd(
					projectile.position,
					VecScale(direction, hitDistance)
				)

				local incomingSpeed = VecLength(projectile.velocity)

				if projectile.ammoType == "breaker"
					and projectile.impactCount < BREAKER_PENETRATIONS then
					-- Start with the smallest supported blast, then bore a continuous
					-- cannonball-sized channel in short steps. The ball advances through
					-- the new opening instead of jumping through an intact wall.
					if projectile.penetrationRemaining == nil then
						siegeExplosion(impactPosition, BREAKER_IMPACT_POWER, projectile.powerType or projectile.ammoType)
						projectile.penetrationRemaining = BREAKER_TUNNEL_DEPTH * siegePower("breaker")
						projectile.velocity = VecScale(
							projectile.velocity,
							BREAKER_SPEED_RETENTION
						)
					end
					MakeHole(
						impactPosition,
						BREAKER_HOLE_SOFT * siegePower("breaker"),
						BREAKER_HOLE_MEDIUM * siegePower("breaker"),
						BREAKER_HOLE_HARD * siegePower("breaker"),
						true
					)
					projectile.penetrationRemaining = projectile.penetrationRemaining - BREAKER_TUNNEL_STEP
					projectile.position = VecAdd(impactPosition, VecScale(direction, BREAKER_TUNNEL_STEP))
					if projectile.penetrationRemaining <= 0 then
						projectile.penetrationRemaining = nil
						projectile.impactCount = projectile.impactCount + 1
					end
					SetBodyTransform(projectile.body, Transform(
						projectile.position,
						QuatLookAt(projectile.position, VecAdd(projectile.position, direction))
					))
					index = index + 1
				elseif projectile.ammoType == "breaker"
					and projectile.impactCount < BREAKER_PENETRATIONS + MAX_BREAKER_RICOCHETS
					and incomingSpeed >= MIN_RICOCHET_SPEED then
					local normalSpeed = VecDot(projectile.velocity, hitNormal)
					local normalVelocity = VecScale(hitNormal, normalSpeed)
					local tangentVelocity = VecSub(projectile.velocity, normalVelocity)

					projectile.velocity = VecAdd(
						VecScale(tangentVelocity, BREAKER_RICOCHET_FRICTION),
						VecScale(normalVelocity, -BREAKER_RICOCHET_FACTOR)
					)
					projectile.position = VecAdd(impactPosition, VecScale(hitNormal, 0.12))
					projectile.impactCount = projectile.impactCount + 1

					siegeExplosion(impactPosition, BREAKER_RICOCHET_POWER, projectile.powerType or projectile.ammoType)
					local ricochetDirection = VecNormalize(projectile.velocity)
					SetBodyTransform(projectile.body, Transform(
						projectile.position,
						QuatLookAt(projectile.position, VecAdd(projectile.position, ricochetDirection))
					))
					index = index + 1
				elseif projectile.ammoType == "ricochet"
					and projectile.impactCount < MAX_ULTRA_RICOCHETS
					and incomingSpeed >= MIN_RICOCHET_SPEED then
					local normalSpeed = VecDot(projectile.velocity, hitNormal)
					local normalVelocity = VecScale(hitNormal, normalSpeed)
					local tangentVelocity = VecSub(projectile.velocity, normalVelocity)

					projectile.velocity = VecAdd(
						VecScale(tangentVelocity, ULTRA_RICOCHET_FRICTION),
						VecScale(normalVelocity, -ULTRA_RICOCHET_FACTOR)
					)
					projectile.position = VecAdd(impactPosition, VecScale(hitNormal, 0.12))
					projectile.impactCount = projectile.impactCount + 1

					siegeExplosion(impactPosition, ULTRA_RICOCHET_POWER, projectile.powerType or projectile.ammoType)
					local ricochetDirection = VecNormalize(projectile.velocity)
					SetBodyTransform(projectile.body, Transform(
						projectile.position,
						QuatLookAt(projectile.position, VecAdd(projectile.position, ricochetDirection))
					))
					index = index + 1
				elseif projectile.ammoType == "explosive" then
					Delete(projectile.body)
					siegeExplosion(impactPosition, ULTRA_EXPLOSION_POWER, projectile.powerType or projectile.ammoType)
					scatterExplosionDebris(impactPosition, 12.0, 35.0, 75.0, 0.45)
				table.remove(server.projectiles, index)
			elseif projectile.ammoType == "ultraultra" then
				Delete(projectile.body)
				for blast = 1, ULTRA_ULTRA_BLAST_COUNT do
					local blastOffset = VecScale(GetRandomDirection(1.0), GetRandomFloat(0.0, 3.5))
					siegeExplosion(VecAdd(impactPosition, blastOffset), ULTRA_EXPLOSION_POWER, projectile.powerType or projectile.ammoType)
				end
				spawnMiniCannonballs(impactPosition, projectile.owner, now, ULTRA_ULTRA_MINI_COUNT)
				scatterExplosionDebris(impactPosition, 20.0, 55.0, 130.0, 0.75)
				table.remove(server.projectiles, index)
				elseif projectile.ammoType == "normalexplosive" then
					Delete(projectile.body)
					siegeExplosion(impactPosition, NORMAL_EXPLOSION_POWER, projectile.powerType or projectile.ammoType)
					scatterExplosionDebris(impactPosition, 6.0, 10.0, 24.0, 0.15)
					table.remove(server.projectiles, index)
				elseif projectile.ammoType == "eraser" then
					-- Keep the incoming body and freeze it at its actual landing pose.
					-- It remains still for a short arming pause before rising.
					local mineBody = projectile.body
					if IsHandleValid(mineBody) then
						SetBodyVelocity(mineBody, Vec(0, 0, 0))
						SetBodyAngularVelocity(mineBody, Vec(0, 0, 0))
						SetBodyDynamic(mineBody, false)
						local landingTransform = GetBodyTransform(mineBody)
						if hitNormal[2] > 0.35 then
							-- Align the lowest voxel of the actual body bounds with the
							-- ground hit point instead of guessing from the body origin.
							local boundsMin = GetBodyBounds(mineBody)
							local verticalCorrection = impactPosition[2] - boundsMin[2] + 0.02
							landingTransform.pos[2] = landingTransform.pos[2] + verticalCorrection
							SetBodyTransform(mineBody, landingTransform)
						end
						local landingPosition = landingTransform.pos
						local mineId = server.nextEraserMineId
						server.nextEraserMineId = server.nextEraserMineId + 1
						table.insert(server.cannonMines, {
							id = mineId,
							body = mineBody,
							groundPosition = landingPosition,
							startTime = now,
							owner = projectile.owner
						})
					end
					table.remove(server.projectiles, index)
				elseif projectile.ammoType == "mini" then
					Delete(projectile.body)
					siegeExplosion(impactPosition, MINI_CANNONBALL_IMPACT_POWER, projectile.powerType or projectile.ammoType)
					table.remove(server.projectiles, index)
				elseif projectile.ammoType == "fullauto" then
					Delete(projectile.body)
					siegeExplosion(impactPosition, FULL_AUTO_IMPACT_POWER, projectile.powerType or projectile.ammoType)
					table.remove(server.projectiles, index)
				else
					Delete(projectile.body)
					siegeExplosion(impactPosition, IMPACT_POWER, projectile.powerType or projectile.ammoType)
					table.remove(server.projectiles, index)
				end
			else
				-- Leaving the material completes the one allowed penetration.
				if projectile.ammoType == "breaker"
					and projectile.penetrationRemaining ~= nil then
					projectile.penetrationRemaining = nil
					projectile.impactCount = projectile.impactCount + 1
				end
				projectile.position = VecAdd(projectile.position, movement)
				SetBodyTransform(
					projectile.body,
					Transform(projectile.position, QuatLookAt(projectile.position, VecAdd(projectile.position, direction)))
				)
				if projectile.ammoType == "eraser" then
					SetBodyVelocity(projectile.body, projectile.velocity)
				end
				index = index + 1
			end
		end
	end
end

function client.init()
	client.lastShotSerial = {}
	client.recoil = 0
	client.cannonBang = {}
	client.chainPull = {}
	client.lastChainPullSound = -1
	client.eraserMineBeeps = {}
	client.eraserBeep = LoadSound("warning-beep.ogg", 20)
	client.eraserClick = LoadSound("clickdown.ogg", 20)
	for i = 0, 3 do
		client.cannonBang[i] = LoadSound("tools/tankgun" .. i .. ".ogg")
		client.chainPull[i] = LoadSound("grab" .. i .. ".ogg")
	end
end

function client.tick(dt)
	client.gunsTick(dt)
	local player = GetLocalPlayer()
	if player == 0 then
		return
	end

	local wheel = InputValue("mousewheel", player)
	if shared.tetherActive[player] and wheel ~= 0
		and GetTime() - client.lastChainPullSound >= 0.08 then
		client.lastChainPullSound = GetTime()
		local muzzle = GetToolLocationWorldTransform("muzzle", player)
		local soundPosition = GetPlayerCameraTransform(player).pos
		if muzzle then
			soundPosition = muzzle.pos
		end
		PlaySound(
			client.chainPull[math.random(0, 3)],
			soundPosition,
			0.75,
			true,
			GetRandomFloat(0.8, 1.1)
		)
	end

	for _, tetherVisual in pairs(shared.tetherVisuals) do
		DrawLine(
			tetherVisual.anchor,
			tetherVisual.ball,
			0.12, 0.10, 0.08, 1.0
		)
	end

	-- Play the bang for every synchronized shot so nearby multiplayer clients
	-- hear one another's cannons as well.
	for shotPlayer in players() do
		local shotSerial = shared.cannonShotSerial[shotPlayer] or 0
		local previousSerial = client.lastShotSerial[shotPlayer] or 0
		if shotSerial ~= previousSerial then
			client.lastShotSerial[shotPlayer] = shotSerial
			local muzzle = GetToolLocationWorldTransform("muzzle", shotPlayer)
			local soundPosition = GetPlayerTransform(shotPlayer).pos
			if muzzle then
				soundPosition = muzzle.pos
			end
			PlaySound(client.cannonBang[math.random(0, 3)], soundPosition, 1.4)
			if shotPlayer == player then
				client.recoil = 1
			end
		end
	end

	client.recoil = math.max(0, client.recoil - dt * 3.5)

	-- Networked Eraser arming feedback. New mines click and beep on landing,
	-- then flash green and beep repeatedly until the burst.
	local activeEraserMines = {}
	for mineId, mine in pairs(shared.eraserMines) do
		activeEraserMines[mineId] = true
		local elapsed = math.max(0, GetTime() - mine.startTime)
		local beepInterval = 0.55
		local beepIndex = math.floor(elapsed / beepInterval)
		if client.eraserMineBeeps[mineId] == nil then
			client.eraserMineBeeps[mineId] = -1
			PlaySound(client.eraserClick, mine.position, 1.0, true, 0.9)
		end
		if beepIndex > client.eraserMineBeeps[mineId] then
			client.eraserMineBeeps[mineId] = beepIndex
			local urgency = math.min(1.0, elapsed / mine.duration)
			PlaySound(client.eraserBeep, mine.position, 1.0, true, 0.9 + urgency * 0.7)
		end
		if elapsed % beepInterval < 0.18 then
			PointLight(mine.position, 0.05, 1.0, 0.12, 7)
		end
	end
	for mineId in pairs(client.eraserMineBeeps) do
		if not activeEraserMines[mineId] then
			client.eraserMineBeeps[mineId] = nil
		end
	end

	if GetPlayerTool(player) == TOOL_ID then
		local recoilOffset = math.sin(client.recoil * math.pi) * 0.18
		SetToolTransform(Transform(
			Vec(0.38, -0.48, -0.40 + recoilOffset),
			QuatEuler(-82 - 8 * client.recoil, 0, 180)
		))

	end

	-- Hand poses must be set for every network player on each client. Applying
	-- this only to the local player leaves remote third-person characters using
	-- Teardown's default one-handed pose.
	for toolPlayer in players() do
		if GetPlayerTool(toolPlayer) == TOOL_ID then
			-- Remote characters are always viewed in third person. The local
			-- character also receives this offset when third-person view is active.
			if toolPlayer ~= player or GetBool("game.thirdperson") then
				-- The vox model's long axis points upward in its source orientation.
				-- First person already corrects this above; multiplayer needs the
				-- same rotation applied explicitly to each remote visible tool.
				SetToolTransform(
					Transform(Vec(0, 0, 0), QuatEuler(-82, 0, 180)),
					1,
					toolPlayer
				)
				SetToolOffset(Vec(0, -0.32, 0), toolPlayer)
			else
				SetToolOffset(Vec(0, 0, 0), toolPlayer)
			end
			-- Explicit transforms avoid silently falling back to Teardown's
			-- default grip when a prefab location cannot be resolved.
			local rightHand = Transform(
				Vec(0.105, 0.10, 0.34),
				QuatEuler(0, 90, 0)
			)
			local leftHand = Transform(
				Vec(0.105, 0.60, 0.34),
				QuatEuler(90, 40, 0)
			)
			SetToolHandPoseLocalTransform(rightHand, leftHand, toolPlayer)
		end
	end
end

function client.draw()
	client.gunsDraw()
	local player = GetLocalPlayer()
	if player == 0 or (GetPlayerTool(player) ~= TOOL_ID and client.gunMine == nil) then
		return
	end

	UiPush()
		UiAlign("center middle")
		UiTranslate(UiCenter(), UiHeight() - 92)
		UiFont("regular.ttf", 22)
		UiColor(0.95, 0.9, 0.75)
		UiText(client.gunMine and (client.gunMine.kind == "treb" and "TREBUCHET" or "FIXED CANNON") or "THE CANNON")
		UiTranslate(0, 28)
		UiFont("regular.ttf", 18)
		local ammoType = shared.cannonAmmoType[player] or "breaker"
		if ammoType == "ricochet" then
			UiColor(0.35, 0.9, 1.0)
			UiText("RICOCHET  |  R to switch")
		elseif ammoType == "explosive" then
			UiColor(1.0, 0.2, 0.08)
			UiText("ULTRA EXPLOSION  |  R to switch")
		elseif ammoType == "ultraultra" then
			UiColor(1.0, 0.05, 0.8)
			UiText("ULTRA ULTRA  |  10x BLAST + BALL STORM  |  R to switch")
		elseif ammoType == "normalexplosive" then
			UiColor(1.0, 0.55, 0.12)
			UiText("NORMAL EXPLOSION  |  R to switch")
		elseif ammoType == "eraser" then
			UiColor(0.7, 1.0, 0.25)
			UiText("ERASER  |  R to switch")
		elseif ammoType == "fullauto" then
			UiColor(1.0, 0.85, 0.25)
			UiText("FULL AUTO  |  Hold fire  |  R to switch")
		elseif ammoType == "physics" then
			UiColor(0.72, 0.78, 0.85)
			UiText("TRADITIONAL BALL  |  R to switch")
		elseif ammoType == "tetherphysics" then
			UiColor(0.85, 0.68, 0.35)
			UiText("TETHER CHAIN v111  |  Wheel: reel/flick  |  Fire: release")
		elseif ammoType == "giantphysics" then
			UiColor(0.42, 0.45, 0.50)
			UiText("COLOSSUS BALL  |  R to switch")
		else
			UiColor(1.0, 0.72, 0.3)
			UiText("BREAKER  |  R to switch")
		end
	UiPop()
end
