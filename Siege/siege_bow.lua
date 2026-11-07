-- Siege: the bow, everyone's main weapon. Hold fire to draw, let go to shoot; a longer draw flies
-- faster and flatter and hits harder. R switches between plain and fire arrows.
-- The server flies each arrow and decides what it hits. Each arrow has a small model that doesn't collide
-- with anything, moved along its flight and left sticking in what it hits for a while.

BOW_TOOL_ID = "siegebow"
BOW_DRAW_TIME = 0.9          -- seconds to full draw
BOW_MIN_DRAW = 0.15          -- let go sooner than this and nothing is fired
BOW_SPEED_MIN, BOW_SPEED_MAX = 28, 72
BOW_GRAVITY = 11
BOW_COOLDOWN = 0.35
BOW_LIFETIME = 7.0
BOW_DAMAGE_MIN, BOW_DAMAGE_MAX = 0.4, 0.95    -- share of a full health bar, by draw; a head hit counts double
BOW_FIRE_EXTRA_DAMAGE = 0.1
BOW_MAX_FIRES = 100          -- don't start more once this many fires burn on the map
BOW_STUCK_MAX = 40           -- arrows left sticking out of things
BOW_STUCK_TIME = 12.0
BOW_BLEND_TIME = 0.12        -- the model starts at the bow and joins the true flight path this quickly

server.bow = { arrows = {}, stuck = {}, drawing = {}, ready = {} }
shared.bowDrawStart = shared.bowDrawStart or {}
shared.bowFireMode = shared.bowFireMode or {}
shared.bowFireUsed = shared.bowFireUsed or {}

function server.bowInit()
	RegisterTool(BOW_TOOL_ID, "Bow", "MOD/bow/bow.xml", 1)
	SetBool("game.tool." .. BOW_TOOL_ID .. ".enabled", true)
	SetString("game.tool." .. BOW_TOOL_ID .. ".ammo.display", "")   -- plain arrows never run out, so no number
	shared.bowFireUsed = {}   -- the level restarts each round, so this counts per round
	server.bowHitSound = LoadSound("clickdown.ogg")
end

-- Called whenever a player's weapons are handed out.
function server.bowResupply(p)
	SetToolAmmo(BOW_TOOL_ID, 9999, p)
	shared.bowFireMode[p] = false
	shared.bowDrawStart[p] = nil
end

-- Fire arrows this player has left this round. No limit while setting up.
function siegeBowFireLeft(p)
	if shared.phase == "setup" then return 99 end
	local used = shared.bowFireUsed and shared.bowFireUsed[p] or 0
	return math.max(0, siegeSetting("firearrows") - used)
end

local function _bowSpawnModel(pos, fire, dir)
	local tip = fire and "material='metal' color='0.95 0.45 0.10'" or "material='metal' color='0.20 0.20 0.22'"
	local xml = "<group><body tags='siegearrow' dynamic='false'>"
		.. "<voxbox pos='-0.05 -0.05 -0.9' size='1 1 11' material='wood' color='0.45 0.33 0.18'/>"
		.. "<voxbox pos='-0.1 -0.1 -1.1' size='2 2 2' " .. tip .. "/>"
		.. "<voxbox pos='-0.15 -0.05 0.0' size='3 1 2' material='plastic' color='0.85 0.82 0.75'/>"
		.. "</body></group>"
	local ents = Spawn(xml, Transform(pos, QuatLookAt(pos, VecAdd(pos, dir))), true, true)
	for i = 1, #(ents or {}) do
		if GetEntityType(ents[i]) == "body" then
			local shapes = GetBodyShapes(ents[i])
			for k = 1, #shapes do SetShapeCollisionFilter(shapes[k], 0, 0) end
			return ents[i]
		end
	end
	return 0
end

local function _bowDeleteModel(body)
	if body and body ~= 0 and IsHandleValid(body) then Delete(body) end
end

local function _bowLoose(p, power)
	local fire = shared.bowFireMode[p] == true
	if fire then
		if siegeBowFireLeft(p) < 1 then
			fire = false
			shared.bowFireMode[p] = false
		elseif shared.phase ~= "setup" then
			shared.bowFireUsed[p] = (shared.bowFireUsed[p] or 0) + 1
			if siegeBowFireLeft(p) < 1 then shared.bowFireMode[p] = false end
		end
	end
	local camera = GetPlayerCameraTransform(p)
	local dir = TransformToParentVec(camera, Vec(0, 0, -1))
	local pos = VecAdd(camera.pos, VecScale(dir, 0.5))
	local vel = VecScale(dir, BOW_SPEED_MIN + (BOW_SPEED_MAX - BOW_SPEED_MIN) * power)
	local list = server.bow.arrows
	local bowPoint = TransformToParentPoint(camera, Vec(0.25, -0.2, -0.9))
	list[#list + 1] = { pos = pos, vel = vel, owner = p, fire = fire, power = power, t = 0,
		body = _bowSpawnModel(bowPoint, fire, dir), offset = VecSub(bowPoint, pos) }
	server.bow.ready[p] = GetTime() + BOW_COOLDOWN
	ClientCall(0, "client.bowLoosed", pos, vel, fire, p)
end

-- A bot's arrow, for siege_bots.lua. role is the side that fired it.
function server.bowBotLoose(pos, vel, role, damage)
	local list = server.bow.arrows
	list[#list + 1] = { pos = pos, vel = vel, role = role, botDamage = damage, fire = false, power = 1, t = 0,
		body = _bowSpawnModel(pos, false, VecNormalize(vel)), offset = Vec(0, 0, 0) }
	ClientCall(0, "client.bowLoosed", pos, vel, false, 0)
end

local function _bowDamage(arrow, target, head)
	if arrow.botDamage then
		ApplyPlayerDamage(target, head and arrow.botDamage * 2 or arrow.botDamage, "arrow")
		return
	end
	local amount = BOW_DAMAGE_MIN + (BOW_DAMAGE_MAX - BOW_DAMAGE_MIN) * arrow.power
	if head then amount = amount * 2 end
	if arrow.fire then amount = amount + BOW_FIRE_EXTRA_DAMAGE end
	ApplyPlayerDamage(target, amount, "arrow", arrow.owner)
	ClientCall(arrow.owner, "client.bowHitMarker", head)
end

-- Looks along the arrow's step for a player's body. Returns the player and whether it was the head.
local function _bowFindPlayer(arrow, from, step, length)
	local team = arrow.owner and siegeTeamOf(arrow.owner) or 0
	local samples = math.max(1, math.ceil(length / 0.25))
	for p in Players() do
		local friend = arrow.role and siegeBotRoleName(siegeRoleOf(p)) == arrow.role
		if p ~= arrow.owner and not friend and GetPlayerHealth(p) > 0 and (team == 0 or siegeTeamOf(p) ~= team) then
			local feet = GetPlayerTransform(p).pos
			for i = 1, samples do
				local at = VecAdd(from, VecScale(step, i / samples * length))
				local dx, dz = at[1] - feet[1], at[3] - feet[3]
				local up = at[2] - feet[2]
				if up > 0 and up < 1.85 and dx * dx + dz * dz < 0.2 then
					return p, up > 1.45, i / samples * length
				end
			end
		end
	end
	return nil
end

local function _bowArrowTick(arrow, dt)
	arrow.t = arrow.t + dt
	if arrow.t > BOW_LIFETIME then
		_bowDeleteModel(arrow.body)
		return true
	end
	arrow.vel = VecAdd(arrow.vel, Vec(0, -BOW_GRAVITY * dt, 0))
	local move = VecScale(arrow.vel, dt)
	local length = VecLength(move)
	if length < 0.001 then return true end
	local dir = VecScale(move, 1 / length)
	if arrow.owner then QueryRejectPlayer(arrow.owner) end
	if arrow.body ~= 0 then QueryRejectBody(arrow.body) end
	local hit, dist, _, shape = QueryRaycast(arrow.pos, dir, length)
	-- a bot: friends are passed by, enemies take the hit
	if hit and shape and shape ~= 0 then
		local struck = GetShapeBody(shape)
		if HasTag(struck, "siegebot") then
			local mine = arrow.role or siegeBotRoleName(siegeRoleOf(arrow.owner))
			if GetTagValue(struck, "siegebotrole") == mine then
				hit = false
			else
				local amount = arrow.botDamage or (BOW_DAMAGE_MIN + (BOW_DAMAGE_MAX - BOW_DAMAGE_MIN) * arrow.power)
				SetTag(struck, "siegebothp", tostring((tonumber(GetTagValue(struck, "siegebothp")) or 100) - amount * 100))
				if arrow.owner then ClientCall(arrow.owner, "client.bowHitMarker", false) end
				ClientCall(0, "client.bowLanded", VecAdd(arrow.pos, VecScale(dir, dist)))
				_bowDeleteModel(arrow.body)
				return true
			end
		end
	end
	local reach = hit and dist or length
	local target, head, at = _bowFindPlayer(arrow, arrow.pos, dir, reach)
	if target then
		_bowDamage(arrow, target, head)
		ClientCall(0, "client.bowLanded", VecAdd(arrow.pos, VecScale(dir, at)))
		_bowDeleteModel(arrow.body)
		return true
	end
	if hit then
		local point = VecAdd(arrow.pos, VecScale(dir, dist))
		if arrow.fire and GetFireCount() < BOW_MAX_FIRES then SpawnFire(VecAdd(point, VecScale(dir, 0.05))) end
		PlaySound(server.bowHitSound, point, 0.6)
		-- leave it sticking out of what it hit, head buried
		if arrow.body ~= 0 and IsHandleValid(arrow.body) then
			local at2 = VecAdd(point, VecScale(dir, -0.85))
			SetBodyTransform(arrow.body, Transform(at2, QuatLookAt(at2, VecAdd(at2, dir))))
			local stuck = server.bow.stuck
			stuck[#stuck + 1] = { body = arrow.body, t = GetTime() + BOW_STUCK_TIME }
			if #stuck > BOW_STUCK_MAX then
				_bowDeleteModel(stuck[1].body)
				table.remove(stuck, 1)
			end
		end
		return true
	end
	arrow.pos = VecAdd(arrow.pos, move)
	if arrow.body ~= 0 and IsHandleValid(arrow.body) then
		local blend = math.max(0, 1 - arrow.t / BOW_BLEND_TIME)
		local shown = VecAdd(arrow.pos, VecScale(arrow.offset, blend))
		SetBodyTransform(arrow.body, Transform(shown, QuatLookAt(shown, VecAdd(shown, dir))))
	end
	if IsPointInWater(arrow.pos) then
		_bowDeleteModel(arrow.body)
		return true
	end
	return false
end

function server.bowTick(dt)
	local bow = server.bow
	for p in Players() do
		if GetPlayerTool(p) == BOW_TOOL_ID and GetPlayerHealth(p) > 0 then
			if InputPressed("r", p) then
				if shared.bowFireMode[p] then shared.bowFireMode[p] = false
				elseif siegeBowFireLeft(p) > 0 then shared.bowFireMode[p] = true end
			end
			if InputDown("usetool", p) then
				if bow.drawing[p] == nil and (bow.ready[p] or 0) <= GetTime() then
					bow.drawing[p] = 0
					shared.bowDrawStart[p] = GetTime()
				elseif bow.drawing[p] then
					bow.drawing[p] = bow.drawing[p] + dt
				end
			elseif bow.drawing[p] then
				local held = bow.drawing[p]
				bow.drawing[p] = nil
				shared.bowDrawStart[p] = nil
				if held >= BOW_MIN_DRAW then _bowLoose(p, math.min(1, held / BOW_DRAW_TIME)) end
			end
		elseif bow.drawing[p] then
			bow.drawing[p] = nil
			shared.bowDrawStart[p] = nil
		end
	end
	for i = #bow.arrows, 1, -1 do
		if _bowArrowTick(bow.arrows[i], dt) then table.remove(bow.arrows, i) end
	end
	for i = #bow.stuck, 1, -1 do
		if GetTime() > bow.stuck[i].t then
			_bowDeleteModel(bow.stuck[i].body)
			table.remove(bow.stuck, i)
		end
	end
end

-- ---------- client ----------

client.bow = { flying = {}, marker = 0 }

function client.bowLoosed(pos, vel, fire, shooter)
	local c = client.bow
	c.flying[#c.flying + 1] = { pos = pos, vel = vel, fire = fire, t = 0, shooter = shooter }
	if c.twang == nil then c.twang = LoadSound("grab0.ogg") end
	PlaySound(c.twang, pos, 1, true, 1.5)
end

-- The server says this arrow hit a player: it shouldn't be left sticking in the air behind them.
function client.bowLanded(pos)
	local c = client.bow
	for i = #c.flying, 1, -1 do
		if VecLength(VecSub(c.flying[i].pos, pos)) < 3 then
			table.remove(c.flying, i)
			break
		end
	end
end

function client.bowHitMarker(head)
	client.bow.marker = head and 0.5 or 0.3
	client.bow.markerHead = head
end

local function _bowDrawArrow(pos, dir, fire)
	if fire then
		PointLight(pos, 1, 0.45, 0.12, 2.5)
		ParticleReset()
		ParticleType("smoke")
		ParticleColor(1, 0.5, 0.1, 0.4, 0.3, 0.2)
		ParticleRadius(0.06, 0.16)
		ParticleAlpha(0.9, 0)
		ParticleEmissive(4, 0)
		ParticleGravity(0.6)
		SpawnParticle(pos, Vec(0, 0.3, 0), 0.25)
	end
end

-- The arrow on the string is a real part of the bow: hidden until you draw, then slid back as you pull.
local BOW_ARROW_VOXEL = 0.05
local BOW_ARROW_HIDDEN = Transform(Vec(0, -50, 0))
local BOW_HOLD_ROT = QuatEuler(0, 0, -6)
local BOW_HOLD_GRIP = Vec(0.18, -0.14, -0.75)   -- where the grip sits, from your eye: level with the arrow

local function _bowParts(body)
	local shapes = GetBodyShapes(body)
	local arrow, bow = nil, nil
	for i = 1, #shapes do
		if HasTag(shapes[i], "bowarrow") then arrow = shapes[i] else bow = shapes[i] end
	end
	return arrow, bow
end

-- The middle of the grip, in the world. A tool shape's own axes are the model's: 3 wide, 9 deep, 28 tall.
local function _bowGripWorld(bow)
	return TransformToParentPoint(GetShapeWorldTransform(bow), Vec(1.5 * BOW_ARROW_VOXEL, 8.5 * BOW_ARROW_VOXEL, 14 * BOW_ARROW_VOXEL))
end

-- First person: where the tool must go so the grip lands in front of your eye, level with the arrow.
local function _bowHold(body)
	if client.bowGripLocal == nil then
		local _, bow = _bowParts(body)
		if bow == nil then return nil end
		client.bowGripLocal = TransformToLocalPoint(GetBodyTransform(body), _bowGripWorld(bow))
	end
	return Transform(VecSub(BOW_HOLD_GRIP, QuatRotateVec(BOW_HOLD_ROT, client.bowGripLocal)), BOW_HOLD_ROT)
end

local function _bowNockArrow(p, pull, drawing)
	local body = GetToolBody(p)
	if body == 0 then return end
	local arrow, bow = _bowParts(body)
	if arrow == nil or bow == nil then return end
	if not drawing then
		SetShapeLocalTransform(arrow, BOW_ARROW_HIDDEN)
		return
	end
	-- the arrow passes the grip, along where this player is aiming, drawn back as they pull
	local eye = GetPlayerEyeTransform(p)
	local forward = TransformToParentVec(eye, Vec(0, 0, -1))
	local right = TransformToParentVec(eye, Vec(1, 0, 0))
	local rot = QuatRotateQuat(eye.rot, QuatEuler(0, 180, 0))   -- a tool shape's own z is the model's height
	local tail = VecAdd(VecAdd(_bowGripWorld(bow), VecScale(forward, -0.25 - 0.4 * pull)), VecScale(right, 0.04))
	local centre = QuatRotateVec(rot, Vec(1.5 * BOW_ARROW_VOXEL, 1.5 * BOW_ARROW_VOXEL, 0))
	SetShapeLocalTransform(arrow, TransformToLocalTransform(GetBodyTransform(body), Transform(VecSub(tail, centre), rot)))
	if shared.bowFireMode and shared.bowFireMode[p] then
		PointLight(VecAdd(tail, VecScale(forward, 1.2)), 1, 0.45, 0.12, 1.5)
	end
end

function client.bowTick(dt)
	local c = client.bow
	for i = #c.flying, 1, -1 do
		local a = c.flying[i]
		a.t = a.t + dt
		a.vel = VecAdd(a.vel, Vec(0, -BOW_GRAVITY * dt, 0))
		local move = VecScale(a.vel, dt)
		local length = VecLength(move)
		local dir = VecScale(move, 1 / math.max(length, 0.001))
		if a.shooter ~= 0 then QueryRejectPlayer(a.shooter) end
		local hit = QueryRaycast(a.pos, dir, length)
		if hit then
			table.remove(c.flying, i)
		elseif a.t > BOW_LIFETIME or IsPointInWater(a.pos) then
			table.remove(c.flying, i)
		else
			a.pos = VecAdd(a.pos, move)
			_bowDrawArrow(a.pos, dir, a.fire)
		end
	end
	if c.marker > 0 then c.marker = c.marker - dt end

	-- how the bow is held
	local me = GetLocalPlayer()
	for p in Players() do
		if GetPlayerTool(p) == BOW_TOOL_ID then
			local start = shared.bowDrawStart and shared.bowDrawStart[p]
			local pull = start and math.min(1, (GetTime() - start) / BOW_DRAW_TIME) or 0
			if p == me and not GetBool("game.thirdperson") then
				local body = GetToolBody(me)
				local hold = body ~= 0 and _bowHold(body) or nil
				SetToolTransform(hold or Transform(Vec(0.28, -0.72, -0.72), QuatEuler(0, 0, -10)), 0.3)
			else
				SetToolTransform(Transform(Vec(0, -0.55, -0.1), QuatEuler(0, 0, -10)), 1, p)
			end
			_bowNockArrow(p, pull, start ~= nil)
		end
	end
end

function client.bowDraw()
	local me = GetLocalPlayer()
	if me == 0 then return end
	if client.bow.marker > 0 then
		UiPush()
			UiTranslate(UiCenter(), UiMiddle())
			UiAlign("center middle")
			if client.bow.markerHead then UiColor(1, 0.3, 0.2, 1) else UiColor(1, 1, 1, 0.9) end
			UiRotate(45)
			UiRect(2, 18)
			UiRect(18, 2)
		UiPop()
	end
	if GetPlayerTool(me) ~= BOW_TOOL_ID then return end
	local fire = shared.bowFireMode and shared.bowFireMode[me]
	local left = siegeBowFireLeft(me)
	local text = fire and "FIRE ARROW" or "ARROW"
	local tail
	if shared.phase == "setup" then tail = "  |  R: switch"
	elseif left > 0 then tail = "  |  R: switch  (" .. left .. " fire arrows left)"
	else tail = "  |  no fire arrows left" end
	UiPush()
		UiTranslate(UiCenter(), UiHeight() - 92)
		UiAlign("center middle")
		UiFont("bold.ttf", 20)
		UiTextShadow(0, 0, 0, 0.8, 2)
		if fire then UiColor(1, 0.6, 0.2) else UiColor(0.95, 0.9, 0.75) end
		UiText(text .. tail)
	UiPop()
end
