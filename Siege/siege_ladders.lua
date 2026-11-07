-- Siege: ladders. An attacker presses KEY_LADDER and a long ladder appears in their hands. They carry it
-- to the wall, slowly, and it points where they look. Left click lets go and it drops and leans for real.
-- If it comes to rest at a sensible lean with something to lean on, it holds and can be climbed. If it's
-- too upright or too shallow, or misses the wall, it falls and that ladder is lost.
-- Teardown has no climbing of its own, so climbing is done here.

KEY_LADDER = "l"
LADDER_LENGTH = 13.0
LADDER_MAX_ACTIVE = 30     -- across everybody, for performance
LADDER_COOLDOWN = 8.0      -- seconds between picking up ladders, per player
LADDER_CARRY_SPEED = 3.0   -- walking speed while carrying one
LADDER_GRACE = 0.3         -- seconds after picking it up before a click counts
LADDER_TILT_MIN = 6        -- degrees from upright: more upright than this and it topples back
LADDER_TILT_MAX = 38       -- further over than this and the foot kicks out
LADDER_SETTLE_TIME = 0.6   -- must stay this still for this long to count as resting
LADDER_SETTLE_GIVEUP = 8.0
LADDER_GRAB = 0.9          -- how close you must be to climb
LADDER_SPEED = 3.4
LADDER_BREAK_FRACTION = 0.6
LADDER_LITTER_TIME = 15.0

server.ladders = {}
server.ladderCarry = {}
server.ladderReady = {}
server.ladderLitter = {}

function siegeLaddersOn()
	return siegeSetting("laddermax") ~= 0
end

-- How many this player has left this round, or nil while setting up, when there is no limit.
function siegeLaddersLeft(p)
	if shared.phase == "setup" then return nil end
	local used = shared.ladderUsed and shared.ladderUsed[p] or 0
	return math.max(0, siegeSetting("laddermax") - used)
end

function siegeCanLadder(p)
	if not siegeLaddersOn() then return false end
	if shared.phase == "setup" then return true end
	return shared.phase == "live" and siegeRoleOf(p) == ROLE_ATTACK
end

function server.laddersInit()
	server.ladders = {}
	server.ladderCarry = {}
	server.ladderReady = {}
	server.ladderLitter = {}
	shared.ladderUsed = {}   -- the level restarts each round, so this counts per round
	shared.ladderCarrying = {}
	server.ladderThud = LoadSound("clickdown.ogg")
	server.ladderCheck = 0.5
end

local function _ladderXml()
	local parts = {}
	local n = math.floor(LADDER_LENGTH * 10 + 0.5)
	parts[#parts + 1] = string.format("<voxbox pos='-0.3 0 0' size='1 %d 1' material='wood' color='0.42 0.30 0.18'/>", n)
	parts[#parts + 1] = string.format("<voxbox pos='0.2 0 0' size='1 %d 1' material='wood' color='0.42 0.30 0.18'/>", n)
	local y = 0.3
	while y < LADDER_LENGTH - 0.4 do
		parts[#parts + 1] = string.format("<voxbox pos='-0.2 %.1f 0' size='4 1 1' material='wood' color='0.36 0.25 0.15'/>", y)
		y = y + 0.4
	end
	parts[#parts + 1] = string.format("<voxbox tags='siegeladdertop' pos='-0.3 %.1f -0.1' size='6 1 3' material='wood' color='0.36 0.25 0.15'/>", LADDER_LENGTH - 0.3)
	return "<group><body tags='siegeladder' dynamic='false'>" .. table.concat(parts) .. "</body></group>"
end

local function _ladderVoxels(body)
	local total = 0
	local shapes = GetBodyShapes(body)
	for i = 1, #shapes do total = total + GetShapeVoxelCount(shapes[i]) end
	return total
end

local function _ladderSetSolid(body, solid)
	local shapes = GetBodyShapes(body)
	for i = 1, #shapes do
		if solid then SetShapeCollisionFilter(shapes[i], 1, 255) else SetShapeCollisionFilter(shapes[i], 0, 0) end
	end
end

-- While carried: the foot just ahead of your feet, the ladder pointing where you look.
local function _ladderCarryPose(p)
	local camera = GetPlayerCameraTransform(p)
	local forward = TransformToParentVec(camera, Vec(0, 0, -1))
	local flat = Vec(forward[1], 0, forward[3])
	if VecLength(flat) < 0.01 then
		flat = TransformToParentVec(camera, Vec(0, 1, 0))
		flat[2] = 0
	end
	flat = VecNormalize(flat)
	local elevation = math.deg(math.asin(math.max(-1, math.min(1, forward[2]))))
	elevation = math.max(25, math.min(88, elevation))
	local foot = VecAdd(VecAdd(GetPlayerTransform(p).pos, VecScale(flat, 0.7)), Vec(0, 0.2, 0))
	local rot = QuatRotateQuat(QuatLookAt(foot, VecAdd(foot, flat)), QuatEuler(elevation - 90, 0, 0))
	return Transform(foot, rot)
end

local function _ladderEndCarry(p)
	local carry = server.ladderCarry[p]
	if carry == nil then return nil end
	server.ladderCarry[p] = nil
	shared.ladderCarrying[p] = nil
	SetPlayerWalkingSpeed(carry.walk, p)
	if carry.tool and carry.tool ~= "" and carry.tool ~= "none" and IsToolEnabled(carry.tool, p) then
		SetPlayerTool(carry.tool, p)
	end
	return carry
end

local function _ladderPickUp(p)
	if not siegeCanLadder(p) then return end
	local info = shared.players[p]
	if info and info.build ~= 0 then return end
	if siegeLaddersLeft(p) == 0 then
		ClientCall(p, "client.notify", "You have no ladders left this round.")
		return
	end
	if (server.ladderReady[p] or 0) > GetTime() then
		ClientCall(p, "client.notify", "Another ladder is on its way. Give it a few seconds.")
		return
	end
	local active = #server.ladders
	for _ in pairs(server.ladderCarry) do active = active + 1 end
	if active >= LADDER_MAX_ACTIVE then
		ClientCall(p, "client.notify", "Too many ladders are up already.")
		return
	end
	local ents = Spawn(_ladderXml(), _ladderCarryPose(p), true, true)
	local body = 0
	for i = 1, #(ents or {}) do
		if GetEntityType(ents[i]) == "body" then body = ents[i] end
	end
	if body == 0 then
		ClientCall(p, "client.notify", "Could not get a ladder.")
		return
	end
	_ladderSetSolid(body, false)
	server.ladderCarry[p] = { body = body, tool = GetPlayerTool(p), walk = GetPlayerWalkingSpeed(p), grace = LADDER_GRACE }
	shared.ladderCarrying[p] = true
	SetPlayerTool("none", p)
	if shared.phase ~= "setup" then shared.ladderUsed[p] = (shared.ladderUsed[p] or 0) + 1 end
end

-- Put it back: L, or switching to a weapon. You get the ladder back.
local function _ladderPutBack(p)
	local carry = _ladderEndCarry(p)
	if carry == nil then return end
	if IsHandleValid(carry.body) then Delete(carry.body) end
	if shared.phase ~= "setup" then shared.ladderUsed[p] = math.max(0, (shared.ladderUsed[p] or 0) - 1) end
end

local function _ladderLetGo(p)
	local carry = server.ladderCarry[p]
	local body = carry.body
	SetBodyTransform(body, _ladderCarryPose(p))
	_ladderEndCarry(p)
	_ladderSetSolid(body, true)
	SetBodyDynamic(body, true)
	SetBodyActive(body, true)
	SetBodyVelocity(body, Vec(0, 0, 0))
	SetBodyAngularVelocity(body, Vec(0, 0, 0))
	server.ladders[#server.ladders + 1] = { body = body, owner = p, state = "settling", t = 0, still = 0, voxels = _ladderVoxels(body) }
	server.ladderReady[p] = GetTime() + LADDER_COOLDOWN
	PlaySound(server.ladderThud, GetBodyTransform(body).pos)
end

local function _ladderCarryTick(p, carry, dt)
	if not IsHandleValid(carry.body) then
		_ladderEndCarry(p)
		return
	end
	if GetPlayerHealth(p) <= 0 then
		-- dropped when you die; that one is gone
		_ladderEndCarry(p)
		Delete(carry.body)
		return
	end
	local tool = GetPlayerTool(p)
	if (tool ~= "none" and tool ~= "") or InputPressed(KEY_LADDER, p) then
		_ladderPutBack(p)
		return
	end
	SetPlayerWalkingSpeed(LADDER_CARRY_SPEED, p)
	SetBodyTransform(carry.body, _ladderCarryPose(p))
	carry.grace = carry.grace - dt
	if carry.grace <= 0 and (InputPressed("usetool", p) or InputPressed("lmb", p)) then
		_ladderLetGo(p)
	end
end

local function _ladderAxis(body)
	local t = GetBodyTransform(body)
	local up = TransformToParentVec(t, Vec(0, 1, 0))
	local tilt = math.deg(math.acos(math.max(-1, math.min(1, up[2]))))
	local lean = Vec(up[1], 0, up[3])
	if VecLength(lean) < 0.001 then lean = Vec(0, 0, 1) end
	return t.pos, up, tilt, VecNormalize(lean)
end

-- Is there something for the top half of the ladder to lean on?
local function _ladderHasSupport(body)
	local foot, up, _, lean = _ladderAxis(body)
	for _, along in ipairs({ 0.55, 0.7, 0.85, 1.0 }) do
		QueryRejectBody(body)
		local hit = QueryRaycast(VecAdd(foot, VecScale(up, LADDER_LENGTH * along)), lean, 1.5)
		if hit then return true end
	end
	return false
end

local function _ladderFalls(index, why)
	local ladder = server.ladders[index]
	local body = ladder.body
	if IsHandleValid(body) then
		SetBodyDynamic(body, true)
		SetBodyActive(body, true)
		local foot, up, tilt, lean = _ladderAxis(body)
		if why == "pushed" or tilt < LADDER_TILT_MIN then
			-- topples away from the wall
			ApplyBodyImpulse(body, VecAdd(foot, VecScale(up, LADDER_LENGTH)), VecScale(lean, -GetBodyMass(body) * 3))
		else
			-- the foot kicks out
			ApplyBodyImpulse(body, foot, VecScale(lean, -GetBodyMass(body) * 3))
		end
		server.ladderLitter[#server.ladderLitter + 1] = { body = body, t = GetTime() + LADDER_LITTER_TIME }
	end
	if ladder.state == "settling" and why ~= "pushed" then
		ClientCall(ladder.owner, "client.notify", "The ladder didn't hold.")
	end
	table.remove(server.ladders, index)
end

local function _ladderSettleTick(i, ladder, dt)
	ladder.t = ladder.t + dt
	local _, _, tilt = _ladderAxis(ladder.body)
	if tilt > 65 or ladder.t > LADDER_SETTLE_GIVEUP then
		_ladderFalls(i, "slipped")
		return
	end
	if VecLength(GetBodyVelocity(ladder.body)) < 0.2 and VecLength(GetBodyAngularVelocity(ladder.body)) < 0.1 then
		ladder.still = ladder.still + dt
	else
		ladder.still = 0
	end
	if ladder.still >= LADDER_SETTLE_TIME then
		if tilt < LADDER_TILT_MIN or tilt > LADDER_TILT_MAX or not _ladderHasSupport(ladder.body) then
			_ladderFalls(i, "slipped")
		else
			-- it holds: fix it in place, so it costs nothing and can't creep while being climbed
			SetBodyDynamic(ladder.body, false)
			ladder.state = "up"
			ClientCall(ladder.owner, "client.notify", "The ladder is up.")
		end
	end
end

local function _ladderClimb(p, ladder)
	local foot, up, _, lean = _ladderAxis(ladder.body)
	local at = GetPlayerTransform(p).pos
	local along = VecDot(VecSub(at, foot), up)
	if along < -0.6 or along > LADDER_LENGTH then return end
	local off = VecSub(VecAdd(foot, VecScale(up, along)), at)
	local flatOff = Vec(off[1], 0, off[3])
	if VecLength(flatOff) > LADDER_GRAB then return end
	local climbing = along > 0.5
	local camera = GetPlayerCameraTransform(p)
	local facing = VecDot(TransformToParentVec(camera, Vec(0, 0, -1)), lean) > 0.1
	local wantsUp = InputDown("up", p) and facing
	if not climbing and not wantsUp then return end
	if InputDown("jump", p) then return end   -- jump to let go
	local speed = 0
	if wantsUp then speed = LADDER_SPEED elseif InputDown("down", p) then speed = -LADDER_SPEED end
	local vel = VecAdd(VecScale(up, speed), VecScale(flatOff, 4))
	-- over the top: nothing ahead at chest height any more, so step off onto the wall
	if wantsUp then
		QueryRejectBody(ladder.body)
		QueryRejectPlayer(p)
		local wall = QueryRaycast(VecAdd(at, Vec(0, 1.0, 0)), lean, 1.6)
		if not wall then vel = VecAdd(VecScale(lean, 3.5), Vec(0, LADDER_SPEED * 0.6, 0)) end
	end
	SetPlayerVelocity(vel, p)
end

function server.laddersTick(dt)
	for p, carry in pairs(server.ladderCarry) do _ladderCarryTick(p, carry, dt) end

	for i = #server.ladders, 1, -1 do
		local ladder = server.ladders[i]
		if not IsHandleValid(ladder.body) then
			table.remove(server.ladders, i)
		elseif ladder.state == "settling" then
			_ladderSettleTick(i, ladder, dt)
		end
	end

	server.ladderCheck = server.ladderCheck - dt
	if server.ladderCheck <= 0 then
		server.ladderCheck = 0.5
		for i = #server.ladders, 1, -1 do
			local ladder = server.ladders[i]
			if ladder.state == "up" then
				-- shot to pieces, or the wall it leaned on is gone
				if _ladderVoxels(ladder.body) < ladder.voxels * LADDER_BREAK_FRACTION or not _ladderHasSupport(ladder.body) then
					_ladderFalls(i, "lost")
				end
			end
		end
		for i = #server.ladderLitter, 1, -1 do
			if GetTime() > server.ladderLitter[i].t then
				if IsHandleValid(server.ladderLitter[i].body) then Delete(server.ladderLitter[i].body) end
				table.remove(server.ladderLitter, i)
			end
		end
	end

	for p in Players() do
		if GetPlayerHealth(p) > 0 then
			if server.ladderCarry[p] == nil and InputPressed(KEY_LADDER, p) then _ladderPickUp(p) end
			for i = 1, #server.ladders do
				if server.ladders[i].state == "up" then _ladderClimb(p, server.ladders[i]) end
			end
			if InputPressed("interact", p) and siegeRoleOf(p) == ROLE_DEFEND and (shared.phase == "prep" or shared.phase == "live") then
				local shape = gateLeverLookedAt(GetPlayerCameraTransform(p), FindShapes("siegeladdertop", true))
				if shape then
					for i = #server.ladders, 1, -1 do
						if GetShapeBody(shape) == server.ladders[i].body then
							PlaySound(server.ladderThud, GetShapeWorldTransform(shape).pos)
							_ladderFalls(i, "pushed")
							break
						end
					end
				end
			end
		end
	end
end

-- ---------- client ----------

function client.laddersDraw()
	local me = GetLocalPlayer()
	if me == 0 or GetPlayerHealth(me) <= 0 then return end
	if siegeRoleOf(me) == ROLE_DEFEND and (shared.phase == "prep" or shared.phase == "live") then
		-- ladders come and go, so refresh the list every so often rather than every frame
		client.ladderListTime = client.ladderListTime or 0
		if client.ladderTops == nil or GetTime() > client.ladderListTime then
			client.ladderListTime = GetTime() + 1
			client.ladderTops = FindShapes("siegeladdertop", true)
		end
		local shape = gateLeverLookedAt(GetPlayerCameraTransform(me), client.ladderTops)
		if shape and IsHandleValid(shape) and not IsBodyDynamic(GetShapeBody(shape)) then
			UiPush()
				UiTranslate(UiCenter(), UiMiddle() + 70)
				UiAlign("center middle")
				UiFont("bold.ttf", 24)
				UiTextShadow(0, 0, 0, 0.8, 2)
				UiColor(1, 0.92, 0.6)
				UiText("[" .. string.upper(GetString("game.input.interact")) .. "]  Push the ladder off")
			UiPop()
		end
	end
	if shared.ladderCarrying and shared.ladderCarrying[me] then
		UiPush()
			UiTranslate(UiCenter(), UiHeight() - 150)
			UiAlign("center middle")
			UiFont("bold.ttf", 22)
			UiTextShadow(0, 0, 0, 0.8, 2)
			UiColor(1, 0.92, 0.6)
			UiText("Stand close to the wall and look up at the top.  [LMB] lean it  |  [" .. string.upper(KEY_LADDER) .. "] put it back")
		UiPop()
	elseif (shared.phase == "live" or shared.phase == "setup") and siegeCanLadder(me) then
		local left = siegeLaddersLeft(me)
		UiPush()
			UiTranslate(UiWidth() - 24, UiHeight() - 40)
			UiAlign("right middle")
			UiFont("regular.ttf", 18)
			UiTextShadow(0, 0, 0, 0.8, 2)
			UiColor(1, 1, 1, 0.75)
			UiText("[" .. string.upper(KEY_LADDER) .. "] Pick up a ladder" .. (left and (" (" .. tostring(left) .. " left)") or "") .. "   |   W climb, S down, Space let go")
		UiPop()
	end
end
