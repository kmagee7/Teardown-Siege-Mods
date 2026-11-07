-- Siege: working gates (server, plus the lever prompt and chains on the client).
--
-- A map can include moving gates by tagging static bodies and lever shapes:
--   body:   siegegate=<id> siegegatetype=drop|bridge siegegatetravel=<metres or degrees>
--           A drop gate is built raised and slides straight down. A bridge is built lowered, its
--           body origin on the hinge line and its deck running along local +z.
--           Add siegegatestart=closed for a gate that starts the round shut.
--   shape:  siegelever=<id>   a lever defenders use; it works every gate body with that id
-- Bodies are moved by script instead of joints, so they can't turn the wrong way or drop when
-- the script isn't running. A body that loses too much of itself falls down for real.
-- Gates start open at the start of each round, because the level restarts between rounds.
--
-- A hoist carries a defender straight to a location, through the floors:
--   shape:    siegelift=<name>     use it to go to that location; attackers can't
--   location: siegeliftto=<name>

GATE_DROP_CLOSE_SPEED = 1.4   -- metres per second
GATE_DROP_OPEN_SPEED = 0.6
GATE_BRIDGE_SPEED = 20        -- degrees per second
GATE_LEVER_COOLDOWN = 0.6
GATE_LEVER_REACH = 3.2        -- metres from the player's eye
GATE_LEVER_AIM = 0.8          -- how directly the player must look at it (1 = dead on)
GATE_BREAK_FRACTION = 0.55    -- falls when less than this share of its voxels are left
GATE_CHECK_TIME = 0.5
HOIST_TIME = 2.5              -- seconds for the ride

server.gates = {}
server.gateLevers = {}
shared.gateLabel = shared.gateLabel or {}

local function _gateText(gate, verb)
	if gate.hasBridge then
		if verb then return gate.closed and "The drawbridge is going up" or "The drawbridge is coming down" end
		if gate.dead then return "The drawbridge is destroyed" end
		return gate.closed and "Lower drawbridge" or "Raise drawbridge"
	end
	if verb then return gate.closed and "The portcullis is coming down" or "The portcullis is going up" end
	if gate.dead then return "The portcullis is destroyed" end
	return gate.closed and "Open portcullis" or "Close portcullis"
end

local function _bodyVoxels(body)
	local n = 0
	local shapes = GetBodyShapes(body)
	for i = 1, #shapes do n = n + GetShapeVoxelCount(shapes[i]) end
	return n
end

local function _gatePartPose(part)
	if part.kind == "bridge" then
		return TransformToParentTransform(part.home, Transform(Vec(0, 0, 0), QuatEuler(-part.at, 0, 0)))
	end
	return Transform(VecAdd(part.home.pos, Vec(0, -part.at, 0)), part.home.rot)
end

function server.gatesFind()
	server.gates = {}
	local bodies = FindBodies("siegegate", true)
	for i = 1, #bodies do
		local b = bodies[i]
		local id = GetTagValue(b, "siegegate")
		local gate = server.gates[id]
		if gate == nil then
			gate = { id = id, closed = HasTag(b, "siegegatestart"), cooldown = 0, hasBridge = false, parts = {} }
			server.gates[id] = gate
		end
		local kind = GetTagValue(b, "siegegatetype")
		if kind == "bridge" then gate.hasBridge = true end
		gate.parts[#gate.parts + 1] = {
			body = b, kind = kind, travel = tonumber(GetTagValue(b, "siegegatetravel")) or 1,
			home = GetBodyTransform(b), at = 0, voxels = _bodyVoxels(b), alive = true,
		}
		if gate.closed then
			local part = gate.parts[#gate.parts]
			part.at = part.travel
			SetBodyTransform(part.body, _gatePartPose(part))
		end
	end
	server.gateLevers = {}
	local levers = FindShapes("siegelever", true)
	for i = 1, #levers do
		local gate = server.gates[GetTagValue(levers[i], "siegelever")]
		if gate then
			server.gateLevers[#server.gateLevers + 1] = { shape = levers[i], gate = gate }
			shared.gateLabel[gate.id] = _gateText(gate)
		end
	end
end

function server.gatesInit()
	server.gateSound = LoadLoop("heavy_motor.ogg")
	server.gateClick = LoadSound("clickdown.ogg")
	server.gateCheck = GATE_CHECK_TIME
	server.gatesFind()
end

function server.gateToggle(gate, pos)
	gate.closed = not gate.closed
	gate.cooldown = GATE_LEVER_COOLDOWN
	shared.gateLabel[gate.id] = _gateText(gate)
	PlaySound(server.gateClick, pos)
	ClientCall(0, "client.notify", _gateText(gate, true))
end

-- Which lever a player is looking at, shared by the server (to use it) and the client (to show the prompt).
function gateLeverLookedAt(camera, shapes)
	local forward = TransformToParentVec(camera, Vec(0, 0, -1))
	local best, bestDot = nil, GATE_LEVER_AIM
	for i = 1, #shapes do
		local s = shapes[i]
		if IsHandleValid(s) and GetShapeVoxelCount(s) > 0 then
			local mn, mx = GetShapeBounds(s)
			local to = VecSub(VecLerp(mn, mx, 0.5), camera.pos)
			local d = VecLength(to)
			if d <= GATE_LEVER_REACH then
				local dot = d > 0.01 and VecDot(forward, VecScale(to, 1 / d)) or 1
				if dot > bestDot then best, bestDot = s, dot end
			end
		end
	end
	return best
end

local HOIST_LABEL = { roof = "Ride the hoist up to the keep roof", hall = "Ride the hoist down to the great hall" }
server.hoistRides = {}

-- Defenders during prep or the round; anyone while setting up, so hosts can try it.
function hoistAllowed(p)
	if shared.phase == "setup" then return true end
	return siegeRoleOf(p) == ROLE_DEFEND and (shared.phase == "prep" or shared.phase == "live")
end

local function _hoistUse(p)
	if server.hoistRides[p] then return end
	local shape = gateLeverLookedAt(GetPlayerCameraTransform(p), FindShapes("siegelift", true))
	if shape == nil then return end
	if not hoistAllowed(p) then
		ClientCall(p, "client.notify", "Only defenders can use the hoist.")
		return
	end
	local locations = FindLocations("siegeliftto", true)
	for i = 1, #locations do
		if GetTagValue(locations[i], "siegeliftto") == GetTagValue(shape, "siegelift") then
			server.hoistRides[p] = { from = GetPlayerTransform(p).pos, to = GetLocationTransform(locations[i]).pos, t = 0 }
			PlaySound(server.gateClick, GetShapeWorldTransform(shape).pos)
			return
		end
	end
end

local function _hoistTick(dt)
	for p, ride in pairs(server.hoistRides) do
		ride.t = ride.t + dt / HOIST_TIME
		if ride.t >= 1 or GetPlayerHealth(p) <= 0 then
			if GetPlayerHealth(p) > 0 then SetPlayerTransform(Transform(ride.to, GetPlayerTransform(p).rot), p) end
			SetPlayerVelocity(Vec(0, 0, 0), p)
			server.hoistRides[p] = nil
		else
			SetPlayerTransform(Transform(VecLerp(ride.from, ride.to, ride.t), GetPlayerTransform(p).rot), p)
			SetPlayerVelocity(Vec(0, 0, 0), p)
			PlayLoop(server.gateSound, VecLerp(ride.from, ride.to, ride.t), 0.5)
		end
	end
end

local function _gateLeverUse(p)
	local shapes = {}
	for i = 1, #server.gateLevers do shapes[i] = server.gateLevers[i].shape end
	local shape = gateLeverLookedAt(GetPlayerCameraTransform(p), shapes)
	if shape == nil then return end
	for i = 1, #server.gateLevers do
		local lever = server.gateLevers[i]
		if lever.shape == shape then
			if lever.gate.cooldown > 0 or lever.gate.dead then return end
			if siegeRoleOf(p) ~= ROLE_DEFEND or (shared.phase ~= "prep" and shared.phase ~= "live") then
				ClientCall(p, "client.notify", "Only defenders can work the gates during a round.")
				return
			end
			server.gateToggle(lever.gate, GetShapeWorldTransform(shape).pos)
			return
		end
	end
end

local function _gatePartTick(gate, part, dt)
	local target = gate.closed and part.travel or 0
	if part.at == target then return end
	local speed = GATE_BRIDGE_SPEED
	if part.kind ~= "bridge" then speed = gate.closed and GATE_DROP_CLOSE_SPEED or GATE_DROP_OPEN_SPEED end
	local step = speed * dt
	if math.abs(target - part.at) <= step then part.at = target
	elseif target > part.at then part.at = part.at + step
	else part.at = part.at - step end
	SetBodyTransform(part.body, _gatePartPose(part))
	PlayLoop(server.gateSound, part.home.pos, 0.5)
end

local function _gatePartCheck(gate, part)
	if not IsHandleValid(part.body) or _bodyVoxels(part.body) < part.voxels * GATE_BREAK_FRACTION then
		part.alive = false
		if IsHandleValid(part.body) then
			SetBodyDynamic(part.body, true)
			SetBodyActive(part.body, true)
		end
		if part.kind == "bridge" or not gate.hasBridge then
			gate.dead = true
			shared.gateLabel[gate.id] = _gateText(gate)
		end
	end
end

function server.gatesTick(dt)
	-- the level may finish loading after init; look again until something is found
	server.gateRetry = (server.gateRetry or 0) - dt
	if next(server.gates) == nil and GetTime() < 30 and server.gateRetry <= 0 then
		server.gateRetry = 1
		server.gatesFind()
	end
	for p in Players() do
		if InputPressed("interact", p) and GetPlayerHealth(p) > 0 then
			_gateLeverUse(p)
			_hoistUse(p)
		end
	end
	_hoistTick(dt)
	server.gateCheck = server.gateCheck - dt
	local check = server.gateCheck <= 0
	if check then server.gateCheck = GATE_CHECK_TIME end
	for _, gate in pairs(server.gates) do
		if gate.cooldown > 0 then gate.cooldown = gate.cooldown - dt end
		for i = 1, #gate.parts do
			local part = gate.parts[i]
			if part.alive then
				if check then _gatePartCheck(gate, part) end
				if part.alive then _gatePartTick(gate, part, dt) end
			end
		end
	end
end

-- ---------- client ----------

function client.gatesLevers()
	if client.leverList == nil or (#client.leverList == 0 and GetTime() < 30) then
		client.leverList = FindShapes("siegelever", true)
	end
	return client.leverList
end

function client.gatesHoists()
	if client.hoistList == nil or (#client.hoistList == 0 and GetTime() < 30) then
		client.hoistList = FindShapes("siegelift", true)
	end
	return client.hoistList
end

-- The prompt is drawn here rather than by the game's own "interact" tag, so it shows the same
-- on every kind of lever, for everybody.
function client.gatesDrawPrompt()
	local me = GetLocalPlayer()
	if me == 0 or GetPlayerHealth(me) <= 0 then return end
	local camera = GetPlayerCameraTransform(me)
	local label, allowed
	local hoist = gateLeverLookedAt(camera, client.gatesHoists())
	if hoist then
		local dest = GetTagValue(hoist, "siegelift")
		label = HOIST_LABEL[dest] or (string.find(dest, "_top", 1, true) and "Ride the hoist up to the top of the tower" or "Ride the hoist down to the ground")
		allowed = hoistAllowed(me)
	else
		local shape = gateLeverLookedAt(camera, client.gatesLevers())
		if shape == nil then return end
		label = shared.gateLabel and shared.gateLabel[GetTagValue(shape, "siegelever")]
		allowed = siegeRoleOf(me) == ROLE_DEFEND and (shared.phase == "prep" or shared.phase == "live")
	end
	if label == nil then return end
	UiPush()
		UiTranslate(UiCenter(), UiMiddle() + 70)
		UiAlign("center middle")
		UiFont("bold.ttf", 24)
		UiTextShadow(0, 0, 0, 0.8, 2)
		if allowed then
			UiColor(1, 0.92, 0.6)
			UiText("[" .. string.upper(GetString("game.input.interact")) .. "]  " .. label)
		else
			UiColor(0.8, 0.8, 0.8)
			UiText(label .. "  (defenders only)")
		end
	UiPop()
end

function client.gatesDrawWorld()
	if client.gateBridges == nil then
		client.gateBridges = {}
		local bodies = FindBodies("siegegatebody", true)
		for i = 1, #bodies do
			client.gateBridges[i] = { body = bodies[i], home = GetBodyTransform(bodies[i]),
				len = tonumber(GetTagValue(bodies[i], "siegegatebody")) or 6 }
		end
	end
	for i = 1, #client.gateBridges do
		local bridge = client.gateBridges[i]
		if IsHandleValid(bridge.body) and IsBodyDynamic(bridge.body) == false then
			local t = GetBodyTransform(bridge.body)
			for _, x in ipairs({ 0.3, 3.5 }) do
				DrawLine(TransformToParentPoint(bridge.home, Vec(x, 4.6, 0.1)), TransformToParentPoint(t, Vec(x, 0.4, bridge.len - 0.3)), 0.08, 0.08, 0.09, 1)
			end
		end
	end
end
