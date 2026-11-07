-- Siege: bot archers. Figures run by the host that stand at posts marked on the map and shoot at enemies
-- they can see. They aren't players: they don't capture objectives or count toward winning a round.
-- A map marks posts with locations tagged siegebotpost=attack or siegebotpost=defend, in the order they
-- should fill up. THE CANNON (Siege) runs the crews on fixed guns, using the same tags on its figures:
--   body: siegebot  siegebotrole=attack|defend  siegebothp=<health>

BOT_RANGE = 75
BOT_HP = 100
BOT_SHOT_SPEED = 62
BOT_RESPAWN = 25
BOT_BODY_TIME = 8           -- seconds a fallen bot stays before it's cleared away
BOT_PER_TICK = 3            -- how many bots think each tick, so a lot of them stays cheap
BOT_BREAK_FRACTION = 0.6
BOT_EYE = 1.55

-- By difficulty: how far off they aim (degrees), damage per arrow, seconds between shots.
BOT_SKILL = {
	{ spread = 3.5, damage = 0.2, rest = 6 },
	{ spread = 1.8, damage = 0.3, rest = 4.5 },
	{ spread = 0.8, damage = 0.45, rest = 3 },
}

server.bots = { list = {}, started = false, at = 1, enemies = {}, enemiesAt = 0, bodies = {} }

function siegeBotRoleName(role)
	return role == ROLE_ATTACK and "attack" or "defend"
end

local function _botColour(roleName)
	local team = roleName == "attack" and shared.attackTeam or (3 - (shared.attackTeam or 1))
	local c = TEAM_COLORS[team] or { 0.5, 0.5, 0.5, 1 }
	return string.format("%.2f %.2f %.2f", c[1], c[2], c[3])
end

-- Other scripts dress their figures to match.
function server.botsPublish()
	SetBool("level.siege.bots.live", shared.phase == "live")
	SetInt("level.siege.bots.crews", siegeSetting("botcrews"))
	SetInt("level.siege.bots.skill", siegeSetting("botskill"))
	SetString("level.siege.bots.colour.attack", _botColour("attack"))
	SetString("level.siege.bots.colour.defend", _botColour("defend"))
end

function siegeBotXml(colour, roleName)
	local look = "material='plastic' color='" .. colour .. "'"
	local skin = "material='plastic' color='0.76 0.60 0.47'"
	local bow = "material='wood' color='0.36 0.25 0.15'"
	return "<group><body tags='siegebot siegebotrole=" .. roleName .. " siegebothp=" .. BOT_HP .. "' dynamic='false'>"
		.. "<voxbox pos='-0.2 0 -0.1' size='2 9 2' " .. look .. "/><voxbox pos='0 0 -0.1' size='2 9 2' " .. look .. "/>"
		.. "<voxbox pos='-0.25 0.9 -0.15' size='5 6 3' " .. look .. "/>"
		.. "<voxbox pos='-0.15 1.5 -0.15' size='3 3 3' " .. skin .. "/>"
		.. "<voxbox pos='-0.4 0.9 -0.1' size='1 6 2' " .. look .. "/><voxbox pos='0.25 0.9 -0.1' size='1 6 2' " .. look .. "/>"
		.. "<voxbox pos='0.3 0.5 -0.5' size='1 13 1' " .. bow .. "/>"
		.. "</body></group>"
end

local function _botSpawnBody(bot)
	local ents = Spawn(siegeBotXml(_botColour(bot.role), bot.role), Transform(bot.pos, bot.rot), true, true)
	for i = 1, #(ents or {}) do
		if GetEntityType(ents[i]) == "body" then
			bot.body = ents[i]
			local n = 0
			local shapes = GetBodyShapes(bot.body)
			for k = 1, #shapes do n = n + GetShapeVoxelCount(shapes[k]) end
			bot.voxels = n
			return
		end
	end
	bot.body = 0
end

local function _botsStart()
	local bots = server.bots
	bots.started = true
	bots.list = {}
	local want = siegeSetting("botarchers")
	if want <= 0 then return end
	local posts = FindLocations("siegebotpost", true)
	local count = { attack = 0, defend = 0 }
	for i = 1, #posts do
		local role = GetTagValue(posts[i], "siegebotpost")
		if count[role] and count[role] < want then
			count[role] = count[role] + 1
			local t = GetLocationTransform(posts[i])
			local bot = { role = role, pos = t.pos, rot = t.rot, cool = 1 + math.random() * 5, respawn = 0, body = 0 }
			_botSpawnBody(bot)
			bots.list[#bots.list + 1] = bot
		end
	end
end

local function _botDie(bot)
	local body = bot.body
	bot.body = 0
	bot.respawn = BOT_RESPAWN
	if IsHandleValid(body) then
		RemoveTag(body, "siegebot")
		SetBodyDynamic(body, true)
		SetBodyActive(body, true)
		local bodies = server.bots.bodies
		bodies[#bodies + 1] = { body = body, t = GetTime() + BOT_BODY_TIME }
	end
end

local function _botEnemyBodies(roleName)
	local bots = server.bots
	if GetTime() > bots.enemiesAt then
		bots.enemiesAt = GetTime() + 2
		bots.enemies = FindBodies("siegebot", true)
	end
	local list = {}
	for i = 1, #bots.enemies do
		local b = bots.enemies[i]
		if IsHandleValid(b) and HasTag(b, "siegebot") and GetTagValue(b, "siegebotrole") ~= roleName then
			list[#list + 1] = b
		end
	end
	return list
end

local function _botFindTarget(bot, eye)
	local candidates = {}
	for p in Players() do
		if GetPlayerHealth(p) > 0 and siegeBotRoleName(siegeRoleOf(p)) ~= bot.role and siegeTeamOf(p) ~= 0 then
			local at = VecAdd(GetPlayerTransform(p).pos, Vec(0, 1.1, 0))
			candidates[#candidates + 1] = { at = at, dist = VecLength(VecSub(at, eye)) }
		end
	end
	local enemies = _botEnemyBodies(bot.role)
	for i = 1, #enemies do
		local at = VecAdd(GetBodyTransform(enemies[i]).pos, Vec(0, 1.1, 0))
		candidates[#candidates + 1] = { at = at, dist = VecLength(VecSub(at, eye)) }
	end
	table.sort(candidates, function(a, b) return a.dist < b.dist end)
	for i = 1, math.min(5, #candidates) do
		local c = candidates[i]
		if c.dist > BOT_RANGE then return nil end
		QueryRejectBody(bot.body)
		local dir = VecScale(VecSub(c.at, eye), 1 / math.max(c.dist, 0.01))
		local hit, dist = QueryRaycast(eye, dir, c.dist)
		if not hit or dist > c.dist - 1.2 then return c.at end
	end
	return nil
end

local function _botShoot(bot, target, eye)
	local skill = BOT_SKILL[siegeSetting("botskill")] or BOT_SKILL[2]
	local delta = VecSub(target, eye)
	local flat = math.sqrt(delta[1] * delta[1] + delta[3] * delta[3])
	local v2 = BOT_SHOT_SPEED * BOT_SHOT_SPEED
	local inside = v2 * v2 - BOW_GRAVITY * (BOW_GRAVITY * flat * flat + 2 * delta[2] * v2)
	local lift = inside > 0 and (v2 - math.sqrt(inside)) / (BOW_GRAVITY * math.max(flat, 0.01)) or delta[2] / math.max(flat, 0.01)
	local dir = VecNormalize(Vec(delta[1] / math.max(flat, 0.01), lift, delta[3] / math.max(flat, 0.01)))
	local spread = math.rad(skill.spread)
	dir = VecNormalize(VecAdd(dir, Vec((math.random() - 0.5) * spread * 2, (math.random() - 0.5) * spread * 2, (math.random() - 0.5) * spread * 2)))
	-- turn to face the shot
	local face = Vec(delta[1], 0, delta[3])
	if VecLength(face) > 0.01 then
		SetBodyTransform(bot.body, Transform(bot.pos, QuatLookAt(bot.pos, VecAdd(bot.pos, face))))
	end
	server.bowBotLoose(VecAdd(eye, VecScale(dir, 0.6)), VecScale(dir, BOT_SHOT_SPEED), bot.role, skill.damage)
	bot.cool = skill.rest * (0.75 + math.random() * 0.5)
end

local function _botThink(bot, dt)
	if bot.body == 0 then
		bot.respawn = bot.respawn - dt
		if bot.respawn <= 0 then _botSpawnBody(bot) end
		return
	end
	if not IsHandleValid(bot.body) then
		bot.body = 0
		bot.respawn = BOT_RESPAWN
		return
	end
	local hp = tonumber(GetTagValue(bot.body, "siegebothp")) or BOT_HP
	local n = 0
	local shapes = GetBodyShapes(bot.body)
	for k = 1, #shapes do n = n + GetShapeVoxelCount(shapes[k]) end
	if hp <= 0 or n < bot.voxels * BOT_BREAK_FRACTION then
		_botDie(bot)
		return
	end
	bot.cool = bot.cool - dt
	if bot.cool > 0 then return end
	local eye = VecAdd(bot.pos, Vec(0, BOT_EYE, 0))
	local target = _botFindTarget(bot, eye)
	if target then _botShoot(bot, target, eye) else bot.cool = 1 + math.random() end
end

function server.botsTick(dt)
	local bots = server.bots
	-- once a second is plenty, and the crews need to know straight away when the siege starts
	bots.publishIn = (bots.publishIn or 0) - dt
	if bots.publishIn <= 0 or bots.lastPhase ~= shared.phase then
		bots.publishIn = 1
		bots.lastPhase = shared.phase
		server.botsPublish()
	end
	for i = #bots.bodies, 1, -1 do
		if GetTime() > bots.bodies[i].t then
			if IsHandleValid(bots.bodies[i].body) then Delete(bots.bodies[i].body) end
			table.remove(bots.bodies, i)
		end
	end
	if shared.phase ~= "live" then return end
	if not bots.started then _botsStart() end
	local n = #bots.list
	if n == 0 then return end
	-- each bot thinks in turn; it gets all the time that has passed since its last turn
	local turns = math.min(BOT_PER_TICK, n)
	local share = dt * n / turns
	for _ = 1, turns do
		if bots.at > n then bots.at = 1 end
		_botThink(bots.list[bots.at], share)
		bots.at = bots.at + 1
	end
end
