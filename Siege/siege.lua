#version 2

-- Siege game mode for Teardown multiplayer.
-- Flow: setup (host places objectives/spawns/walls, everyone picks a team) -> level restart ->
-- prep (both teams move and build, attackers unarmed) -> live (attackers try to capture) ->
-- roundend -> level restart for the next round, or matchend.
-- The level is restarted for every round so map damage never carries over. Match state is written
-- to the savegame just before the restart and consumed (and cleared) by server.init.

#include "mplib/mp.lua"
#include "siege_config.lua"
#include "siege_layout.lua"
#include "siege_integrity.lua"
#include "siege_build.lua"
#include "siege_gates.lua"
#include "siege_ladders.lua"
#include "siege_cleanup.lua"
#include "siege_bow.lua"
#include "siege_sword.lua"
#include "siege_compass.lua"
#include "siege_bots.lua"
#include "siege_ui.lua"

ROUND_END_TIME = 8.0
SETUP_RESPAWN_TIME = 2.0
LOAD_WAIT_MAX = 20.0
MATCH_KEY = "savegame.mod.match"

FLOOR_SPACING = 0.75
FLOOR_MAX_RADIUS = 4.0
FLOOR_MIN_POINTS = 8
FLOOR_QUERIES_PER_TICK = 40

server.deadTime = {}
server.phaseTime = 0
server.slowTimer = 0
server.colorTeam = {}
server.restore = {}
server.awaiting = false
server.captureProg = {}
server.floor = {}
server.toolCount = -1

------------------------------------------------------------------------------------------
-- Init

function server.init()
	hudInit(true)
	statsInit()

	server.levelKey = server._layoutLevelKey()
	shared.levelKey = server.levelKey

	shared.settings = {}
	for i = 1, #SETTINGS do
		local def = SETTINGS[i]
		shared.settings[def.key] = server.settingLoad(def)
	end

	shared.players = {}
	shared.respawnLeft = {}
	shared.phase = "setup"
	shared.timer = 0
	shared.round = 1
	shared.maxRounds = siegeSetting("rounds")
	shared.score = { 0, 0 }
	shared.attackTeam = 1
	shared.capture = {}
	shared.tickets = -1
	shared.result = nil
	shared.buildPieces = 0
	shared.waiting = false
	shared.toolList = {}
	shared.toolRules = {}
	shared.cannonRounds = {}
	shared.trebRounds = {}
	shared.cannonPower = {}
	shared.cannonPatched = false

	server.layout = server.layoutLoad()
	server.fallbackSpawns = utilLoadLevelPlayerSpawns()
	if #server.fallbackSpawns == 0 then
		server.fallbackSpawns = utilGenerateSpawnPoints(16)
	end
	server.layoutCommit(false)
	server.slotsPublish()
	server.cannonLoad()
	server.gatesInit()
	server.laddersInit()
	server.bowInit()
	server.swordInit()
	server.matchRestore()
end

------------------------------------------------------------------------------------------
-- Keeping the match across a level restart

function server.matchSaveAndRestart(nextPhase)
	ClearKey(MATCH_KEY)
	SetBool(MATCH_KEY .. ".pending", true)
	SetString(MATCH_KEY .. ".level", server.levelKey)
	SetString(MATCH_KEY .. ".phase", nextPhase)
	SetInt(MATCH_KEY .. ".round", shared.round)
	SetInt(MATCH_KEY .. ".score1", shared.score[1])
	SetInt(MATCH_KEY .. ".score2", shared.score[2])
	SetInt(MATCH_KEY .. ".attack", shared.attackTeam)
	local n = 0
	for p in Players() do
		local info = shared.players[p]
		if info and info.team > 0 then
			n = n + 1
			local k = MATCH_KEY .. ".players." .. n
			SetString(k .. ".name", GetPlayerName(p))
			SetInt(k .. ".team", info.team)
			SetInt(k .. ".spawn", info.spawn)
			SetInt(k .. ".kills", statsGetKills(p))
			SetInt(k .. ".deaths", statsGetDeaths(p))
		end
	end
	SetInt(MATCH_KEY .. ".players.count", n)
	Restart()
end

function server.matchRestore()
	if not GetBool(MATCH_KEY .. ".pending") then return end
	local sameLevel = GetString(MATCH_KEY .. ".level") == server.levelKey
	local phase = GetString(MATCH_KEY .. ".phase")
	local round = GetInt(MATCH_KEY .. ".round")
	local s1, s2 = GetInt(MATCH_KEY .. ".score1"), GetInt(MATCH_KEY .. ".score2")
	local attack = GetInt(MATCH_KEY .. ".attack")
	local n = GetInt(MATCH_KEY .. ".players.count")
	local restore = {}
	for i = 1, n do
		local k = MATCH_KEY .. ".players." .. i
		restore[GetString(k .. ".name")] = {
			team = GetInt(k .. ".team"), spawn = GetInt(k .. ".spawn"),
			kills = GetInt(k .. ".kills"), deaths = GetInt(k .. ".deaths"),
		}
	end
	ClearKey(MATCH_KEY)   -- consumed: a later fresh start of the mode won't resume this match
	if not sameLevel then return end

	server.restore = restore
	if attack == 1 or attack == 2 then shared.attackTeam = attack end
	if phase == "prep" then
		shared.round = math.max(1, round)
		shared.score = { s1, s2 }
		shared.phase = "prep"
		shared.waiting = true
		shared.timer = siegeSetting("preptime")
		server.awaiting = true
	end
end

function server.restoreTick()
	if next(server.restore) == nil then return end
	for p in Players() do
		local info = shared.players[p]
		if info and info.team == 0 then
			local name = GetPlayerName(p)
			local r = server.restore[name]
			if r then
				server.restore[name] = nil
				info.team = r.team
				info.spawn = r.spawn
				info.ready = true
				info.budget = siegeSetting("budget")
				if r.kills > 0 or r.deaths > 0 then
					shared._statsState[p] = { kills = r.kills, deaths = r.deaths }
				end
				if not server.awaiting then server.spawnPlayer(p, true) end
			end
		end
	end
end

------------------------------------------------------------------------------------------
-- Players joining / leaving

function server.playerJoined(p)
	shared.players[p] = { team = 0, spawn = 0, ready = false, build = 0, budget = 0 }
	server.deadTime[p] = 0
	server.applyLoadout(p, false)
end

function server.playerLeft(p)
	shared.players[p] = nil
	shared.respawnLeft[p] = nil
	server.deadTime[p] = nil
	server.colorTeam[p] = nil
end

function server.teamMap()
	local m = {}
	for p in Players() do m[p] = siegeTeamOf(p) end
	return m
end

------------------------------------------------------------------------------------------
-- Weapons: which tools are allowed (host's Weapons tab)

local function _toolKey(id)
	return "savegame.mod.tools." .. string.gsub(string.lower(id), "[^a-z0-9_]", "_")
end

-- Weapons era decides the medieval weapons, guns and modern tools, whatever else is set in the Weapons tab.
function server.toolPrimaryRule(id)
	if id == BOW_TOOL_ID or id == SWORD_TOOL_ID then return siegeSetting("primary") == 1 end
	if MODERN_TOOLS[id] and siegeSetting("primary") == 1 then return false end
	if FIREARM_TOOLS[id] then return siegeSetting("primary") == 2 end
	return nil
end

function server.toolsPrimarySync()
	local changed = false
	for id, on in pairs(shared.toolRules) do
		local rule = server.toolPrimaryRule(id)
		if rule == nil and MODERN_TOOLS[id] then
			local key = _toolKey(id)
			if HasKey(key) then rule = GetInt(key) == 1 else rule = server.toolDefault(id) end
		end
		if rule ~= nil and rule ~= on then
			shared.toolRules[id] = rule
			changed = true
		end
	end
	if changed then server.reapplyLoadouts() end
end

function server.toolDefault(id)
	if DEFAULT_OFF_TOOLS[id] then return false end
	if GetBool("game.tool." .. id .. ".custom") then
		local s = string.lower(id .. " " .. GetString("game.tool." .. id .. ".name"))
		for i = 1, #CANNON_KEYWORDS do
			if string.find(s, CANNON_KEYWORDS[i], 1, true) then return true end
		end
		return false
	end
	return true
end

-- Mods register their tools during their own init, so the list is rebuilt whenever it grows.
function server.toolsRefresh()
	local ids = ListKeys("game.tool")
	if #ids == server.toolCount then return end
	server.toolCount = #ids
	local list = {}
	for i = 1, #ids do
		local id = ids[i]
		local key = _toolKey(id)
		local on
		if HasKey(key) then on = GetInt(key) == 1 else on = server.toolDefault(id) end
		local primaryRule = server.toolPrimaryRule(id)
		if primaryRule ~= nil then on = primaryRule end
		shared.toolRules[id] = on
		local name = GetString("game.tool." .. id .. ".name")
		if name == nil or name == "" then name = id end
		list[#list + 1] = { id = id, name = name, custom = GetBool("game.tool." .. id .. ".custom") }
	end
	table.sort(list, function(a, b)
		if a.custom ~= b.custom then return b.custom end
		return a.id < b.id
	end)
	shared.toolList = list
	server.reapplyLoadouts()
end

function server.reapplyLoadouts()
	for p in Players() do
		local info = shared.players[p]
		if info and info.ready and GetPlayerHealth(p) > 0 and info.build == 0 then
			server.applyLoadout(p, server.isArmed(p))
		end
	end
end

function server.toolAllowed(id)
	local rule = shared.toolRules[id]
	if rule == nil then return server.toolDefault(id) end
	return rule
end

function server.setToolRule(p, id, on)
	if not IsPlayerHost(p) or shared.phase ~= "setup" then return end
	if not HasKey("game.tool." .. id) then return end
	if server.toolPrimaryRule(id) ~= nil then
		ClientCall(p, "client.notify", "Use Weapons era in Settings to choose between medieval weapons and guns.")
		return
	end
	shared.toolRules[id] = on and true or false
	SetInt(_toolKey(id), on and 1 or 0)
	server.reapplyLoadouts()
end

-- Cannon ball combinations. Only "THE CANNON (Siege)" reads these registry keys.
function server.cannonLoad()
	for i = 1, #CANNON_ROUNDS do
		local r = CANNON_ROUNDS[i]
		local k = "savegame.mod.cannon." .. r.id
		local on = r.default
		if HasKey(k) then on = GetInt(k) == 1 end
		shared.cannonRounds[r.id] = on
		local tk = "savegame.mod.trebball." .. r.id
		local tOn = r.trebDefault == true
		if HasKey(tk) then tOn = GetInt(tk) == 1 end
		shared.trebRounds[r.id] = tOn
		local pk = "savegame.mod.cannonpower." .. r.id
		local pct = 100
		if HasKey(pk) then pct = GetInt(pk) end
		shared.cannonPower[r.id] = math.max(siegeCannonMinPower(r.id), math.min(CANNON_POWER_MAX, pct))
	end
	server.cannonPublish()
end

function server.cannonPublish()
	SetBool("level.siege.cannon.active", true)
	SetBool("level.siege.treb.active", true)
	SetFloat("level.siege.guns.reload", siegeSetting("gunreload"))
	SetFloat("level.siege.treb.reload", siegeSetting("trebreload"))
	for i = 1, #CANNON_ROUNDS do
		local id = CANNON_ROUNDS[i].id
		SetBool("level.siege.cannon.ammo." .. id, shared.cannonRounds[id] and true or false)
		SetBool("level.siege.treb.ammo." .. id, shared.trebRounds[id] and true or false)
		SetFloat("level.siege.cannon.power." .. id, (shared.cannonPower[id] or 100) / 100)
	end
end

function server.setCannonRound(p, id, on)
	if not IsPlayerHost(p) or shared.phase ~= "setup" then return end
	if shared.cannonRounds[id] == nil then return end
	if not on then
		local others = 0
		for i = 1, #CANNON_ROUNDS do
			local other = CANNON_ROUNDS[i].id
			if other ~= id and shared.cannonRounds[other] then others = others + 1 end
		end
		if others == 0 then
			ClientCall(p, "client.notify", "At least one ball type has to stay on. Turn the cannon itself off instead.")
			return
		end
	end
	shared.cannonRounds[id] = on and true or false
	SetInt("savegame.mod.cannon." .. id, on and 1 or 0)
	server.cannonPublish()
end

function server.setTrebRound(p, id, on)
	if not IsPlayerHost(p) or shared.phase ~= "setup" then return end
	if shared.trebRounds[id] == nil then return end
	if not on then
		local others = 0
		for i = 1, #CANNON_ROUNDS do
			local other = CANNON_ROUNDS[i].id
			if other ~= id and shared.trebRounds[other] then others = others + 1 end
		end
		if others == 0 then
			ClientCall(p, "client.notify", "Trebuchets need at least one ball type.")
			return
		end
	end
	shared.trebRounds[id] = on and true or false
	SetInt("savegame.mod.trebball." .. id, on and 1 or 0)
	server.cannonPublish()
end

function server.setCannonPower(p, id, pct)
	if not IsPlayerHost(p) or shared.phase ~= "setup" then return end
	if shared.cannonPower[id] == nil or type(pct) ~= "number" then return end
	pct = math.max(siegeCannonMinPower(id), math.min(CANNON_POWER_MAX, math.floor(pct + 0.5)))
	shared.cannonPower[id] = pct
	SetInt("savegame.mod.cannonpower." .. id, pct)
	server.cannonPublish()
end

-- Whether a player should currently hold weapons.
function server.isArmed(p)
	local info = shared.players[p]
	if info == nil or info.team == 0 or not info.ready then return false end
	if shared.phase == "prep" and siegeRoleOf(p) == ROLE_ATTACK then return false end
	if shared.phase == "roundend" or shared.phase == "matchend" then return false end
	return true
end

function server.applyLoadout(p, armed)
	local tools = ListKeys("game.tool")
	local mult = siegeSetting("ammo")
	local enabled = {}
	for i = 1, #tools do
		local id = tools[i]
		local allowed = armed and server.toolAllowed(id)
		SetToolEnabled(id, allowed, p)
		if allowed then
			enabled[id] = true
			local pickup = GetToolAmmoPickupAmount(id) or 0
			if mult == 0 then
				SetToolAmmo(id, 9999, p)
			elseif pickup > 0 then
				SetToolAmmo(id, pickup * mult, p)
			elseif GetBool("game.tool." .. id .. ".custom") and GetToolAmmo(id, p) < 1 then
				SetToolAmmo(id, 5 * mult, p)
			end
		end
	end
	local first = nil
	for i = 1, #PREFERRED_START_TOOLS do
		if enabled[PREFERRED_START_TOOLS[i]] then first = PREFERRED_START_TOOLS[i] break end
	end
	if first == nil then
		for i = 1, #tools do if enabled[tools[i]] then first = tools[i] break end end
	end
	SetPlayerTool(first or "none", p)
	if enabled[BOW_TOOL_ID] then server.bowResupply(p) end
end

-- Runs once per second: removes any disallowed tool a player got hold of (pickups, other mods).
function server.enforceTools()
	local tools = ListKeys("game.tool")
	for p in Players() do
		local armed = server.isArmed(p)
		for i = 1, #tools do
			local id = tools[i]
			if IsToolEnabled(id, p) and (not armed or not server.toolAllowed(id)) then
				SetToolEnabled(id, false, p)
			end
		end
	end
end

------------------------------------------------------------------------------------------
-- Spawning

-- free = true: doesn't use up an attacker reinforcement.
function server.spawnPlayer(p, free)
	local info = shared.players[p]
	if info == nil then return end
	if not free and shared.phase == "live" and siegeRoleOf(p) == ROLE_ATTACK and shared.tickets > 0 then
		shared.tickets = shared.tickets - 1
	end
	local t = server.spawnTransformFor(p)
	if t then RespawnPlayerAtTransform(t, p) else RespawnPlayer(p) end
	server.deadTime[p] = 0
	info.build = 0
	server.applyLoadout(p, server.isArmed(p))
end

function server.respawnTick(dt)
	local rt = siegeSetting("respawn")
	if shared.phase == "setup" then rt = SETUP_RESPAWN_TIME end
	for p in Players() do
		local info = shared.players[p]
		if info then
			if GetPlayerHealth(p) <= 0 then
				server.deadTime[p] = (server.deadTime[p] or 0) + dt
				local left = math.max(0, math.ceil(rt - server.deadTime[p]))
				local canRespawn = info.team > 0 and info.ready and not server.awaiting
				if shared.phase == "roundend" or shared.phase == "matchend" then canRespawn = false end
				if shared.phase == "live" and siegeRoleOf(p) == ROLE_ATTACK and shared.tickets == 0 then
					canRespawn = false
					left = -1
				end
				if left == 0 and not info.ready then left = -2 end -- waiting for a spawn choice
				if shared.respawnLeft[p] ~= left then shared.respawnLeft[p] = left end
				if canRespawn and server.deadTime[p] >= rt then
					server.spawnPlayer(p)
				end
			else
				server.deadTime[p] = 0
				if shared.respawnLeft[p] ~= 0 then shared.respawnLeft[p] = 0 end
			end
		end
	end
end

-- Freeze a player in place, without damage (choosing a team/spawn, waiting for others to load).
function server.hold(p)
	SetPlayerWalkingSpeed(0, p)
	DisablePlayerDamage(p)
	SetPlayerParam("disableinteract", true, p)
end

------------------------------------------------------------------------------------------
-- Client requests

function server.chooseTeam(p, team)
	local info = shared.players[p]
	if info == nil or (team ~= 1 and team ~= 2) or info.team == team then return end
	if shared.phase == "matchend" then return end
	if siegeJoinBlocked(team, info.team) then
		ClientCall(p, "client.notify", TEAM_NAMES[team] .. " is full: attackers can't outnumber defenders.")
		return
	end
	local midRound = (shared.phase == "prep" or shared.phase == "live") and info.ready and GetPlayerHealth(p) > 0
	info.team = team
	info.spawn = 0
	info.ready = false
	info.build = 0
	info.budget = siegeSetting("budget")
	server.applyLoadout(p, false)
	if midRound then
		-- Switching sides mid-round costs your current life.
		SetPlayerHealth(0, p)
	end
	local c = TEAM_COLORS[team]
	eventlogPostMessage({ p, { text = "joined " .. TEAM_NAMES[team], textColor = { c[1], c[2], c[3] } } }, 4.0)
end

function server.chooseSpawn(p, idx)
	local info = shared.players[p]
	if info == nil or info.team == 0 then return end
	local role = siegeRoleOf(p)
	if idx ~= 0 then
		local s = server.layout.spawns[idx]
		if s == nil or s.role ~= role then return end
	end
	info.spawn = idx
	local wasReady = info.ready
	info.ready = true
	if GetPlayerHealth(p) > 0 and shared.phase ~= "roundend" and shared.phase ~= "matchend" then
		-- Teleport now if the player was waiting, or while nothing is at stake yet.
		if not wasReady or shared.phase == "setup" or shared.phase == "prep" then
			server.spawnPlayer(p)
		end
	end
end

-- Settings are saved by value, not list position, so reordering options can't change their meaning.
-- Older versions saved the position; those are read once and converted. "building" is skipped
-- because its options were reordered after those saves were made.
function server.settingLoad(def)
	local k = "savegame.mod.options." .. def.key
	if def.slider then
		local value = def.slider.default
		if HasKey(k) then
			local saved = tonumber(GetString(k))
			if saved then value = siegeSliderValue(def, siegeSliderRaw(def, saved)) end
		end
		return value
	end
	if HasKey(k) then
		local saved = GetString(k)
		for i = 1, #def.options do
			if tostring(def.options[i][2]) == saved then return i end
		end
		return 1
	end
	local idx = 1
	local old = "savegame.mod.settings." .. def.key
	if def.key ~= "building" and HasKey(old) then idx = GetInt(old) end
	if idx < 1 or idx > #def.options then idx = 1 end
	SetString(k, tostring(def.options[idx][2]))
	return idx
end

function server.settingChanged(key)
	if key == "rounds" then shared.maxRounds = siegeSetting("rounds") end
	if key == "objradius" or key == "floorbreak" then server.objectivesReset() end
end

-- Slider settings: raw is the slider position, snapped and converted here.
function server.setSliderSetting(p, key, raw)
	if not IsPlayerHost(p) or shared.phase ~= "setup" then return end
	local def = SETTINGS_BY_KEY[key]
	if def == nil or def.slider == nil or type(raw) ~= "number" then return end
	local value = siegeSliderValue(def, raw)
	shared.settings[key] = value
	SetString("savegame.mod.options." .. key, tostring(value))
	server.settingChanged(key)
end

function server.setSetting(p, key, idx)
	if not IsPlayerHost(p) or shared.phase ~= "setup" then return end
	local def = SETTINGS_BY_KEY[key]
	if def == nil or def.options == nil then return end
	if idx < 1 then idx = #def.options end
	if idx > #def.options then idx = 1 end
	shared.settings[key] = idx
	SetString("savegame.mod.options." .. key, tostring(def.options[idx][2]))
	server.settingChanged(key)
end

function server.hostCommand(p, cmd)
	if not IsPlayerHost(p) then return end
	if cmd == "start" and shared.phase == "setup" then
		if #server.layout.objectives == 0 then
			ClientCall(p, "client.notify", "Add an objective first (Layout tab).")
			return
		end
		server.startMatch()
	elseif cmd == "endround" and (shared.phase == "prep" or shared.phase == "live") then
		server.endRound(0, "Round ended by host", true)
	elseif cmd == "tosetup" and shared.phase ~= "setup" then
		server.matchSaveAndRestart("setup")
	end
end

------------------------------------------------------------------------------------------
-- Objectives: capture state and the floor under each one

function server.objectivesReset()
	server.captureProg = {}
	server.floor = {}
	local list = server.layout.objectives
	local cap = {}
	for i = 1, #list do
		server.captureProg[i] = 0
		cap[i] = { progress = 0, state = "idle", attackers = 0, defenders = 0, done = false, floor = 100 }
	end
	shared.capture = cap
end

-- Record the solid floor under each objective. Called at the start of a round on the fresh map.
function server.floorBegin()
	local radius = math.min(siegeSetting("objradius"), FLOOR_MAX_RADIUS)
	local list = server.layout.objectives
	for i = 1, #list do
		local pos = list[i].pos
		local pts = {}
		local x = -radius
		while x <= radius do
			local z = -radius
			while z <= radius do
				if x * x + z * z <= radius * radius then
					QueryRequire("physical static")
					local origin = VecAdd(pos, Vec(x, 0.6, z))
					local hit, dist = QueryRaycast(origin, Vec(0, -1, 0), 2.0)
					if hit then
						pts[#pts + 1] = VecAdd(origin, Vec(0, -(dist + 0.1), 0))
					end
				end
				z = z + FLOOR_SPACING
			end
			x = x + FLOOR_SPACING
		end
		server.floor[i] = { points = pts, alive = {}, aliveCount = #pts, cursor = 1 }
		for j = 1, #pts do server.floor[i].alive[j] = true end
	end
end

function server.floorTick()
	local threshold = siegeSetting("floorbreak")
	if threshold <= 0 then return end
	for i = 1, #server.layout.objectives do
		local f = server.floor[i]
		local st = shared.capture[i]
		if f and st and not st.done and #f.points >= FLOOR_MIN_POINTS then
			local n = #f.points
			for _ = 1, math.min(FLOOR_QUERIES_PER_TICK, n) do
				local j = f.cursor
				QueryRequire("physical static")
				local solid = QueryClosestPoint(f.points[j], 0.25)
				if solid ~= f.alive[j] then
					f.alive[j] = solid
					f.aliveCount = f.aliveCount + (solid and 1 or -1)
				end
				f.cursor = j + 1
				if f.cursor > n then f.cursor = 1 end
			end
			local pct = math.floor(100 * f.aliveCount / n + 0.5)
			if st.floor ~= pct then st.floor = pct end
			if (1 - f.aliveCount / n) >= threshold then
				server.captureObjective(i, "floor destroyed")
			end
		end
	end
end

function server.captureObjective(i, how)
	local st = shared.capture[i]
	if st == nil or st.done then return end
	st.done = true
	st.progress = 1
	st.state = "captured"
	local o = server.layout.objectives[i]
	ClientCall(0, "client.banner", o.name .. ": " .. how, shared.attackTeam)
end

function server.capturedPoints()
	local n = 0
	for i = 1, #server.layout.objectives do
		if shared.capture[i] and shared.capture[i].done then
			n = n + (server.layout.objectives[i].points or 1)
		end
	end
	return n
end

------------------------------------------------------------------------------------------
-- Match flow

function server.setPhase(phase)
	shared.phase = phase
	server.phaseTime = 0
end

function server.startMatch()
	shared.score = { 0, 0 }
	shared.round = 1
	shared.maxRounds = siegeSetting("rounds")
	shared.attackTeam = 1
	statsInit()
	server.matchSaveAndRestart("prep")
end

-- Attackers may never outnumber defenders, even after sides swap.
function server.rebalance()
	if siegeSetting("balance") >= 99 then return end
	local atk = shared.attackTeam
	local attackers, defenders = {}, 0
	for p in Players() do
		local t = siegeTeamOf(p)
		if t == atk then attackers[#attackers + 1] = p elseif t == 3 - atk then defenders = defenders + 1 end
	end
	while #attackers > math.max(defenders, 1) do
		local p = table.remove(attackers)
		local info = shared.players[p]
		info.team = 3 - atk
		info.spawn = 0
		defenders = defenders + 1
		ClientCall(p, "client.notify", "Moved to " .. TEAM_NAMES[3 - atk] .. ": attackers can't outnumber defenders.")
	end
end

function server.startRound()
	shared.waiting = false
	server.awaiting = false
	server.setPhase("prep")
	shared.maxRounds = siegeSetting("rounds")
	shared.result = nil
	shared.buildPieces = 0
	shared.tickets = siegeSetting("tickets")
	shared.timer = siegeSetting("preptime")
	server.objectivesReset()
	server.floorBegin()
	integrityBegin()
	server.rebalance()
	for p in Players() do
		local info = shared.players[p]
		if info and info.team > 0 then
			info.budget = siegeSetting("budget")
			info.build = 0
			local role = siegeRoleOf(p)
			local s = server.layout.spawns[info.spawn]
			if info.spawn > 0 and (s == nil or s.role ~= role) then info.spawn = 0 end
			info.ready = true   -- spawn 0 = random spawn of their role; they can change it in the menu
			server.spawnPlayer(p, true)
		end
	end
	local atk = shared.attackTeam
	ClientCall(0, "client.banner", "Round " .. shared.round .. ": " .. TEAM_NAMES[atk] .. " attacks, " .. TEAM_NAMES[3 - atk] .. " defends", atk)
	if siegeSetting("preptime") <= 0 then server.startLive() end
end

function server.startLive()
	server.setPhase("live")
	shared.timer = siegeSetting("roundtime")
	local sendBack = siegeSetting("prepreturn") == 1
	for p in Players() do
		local info = shared.players[p]
		if info and info.ready and siegeRoleOf(p) == ROLE_ATTACK and GetPlayerHealth(p) > 0 then
			if sendBack then
				server.spawnPlayer(p, true)
			else
				if info.build ~= 0 then server.buildExit(p) end
				server.applyLoadout(p, true)
			end
		end
	end
	ClientCall(0, "client.banner", "The siege has begun!", shared.attackTeam)
end

-- Each objective's points go to the attackers if captured, otherwise to the defenders.
function server.endRound(winner, reason, noPoints)
	local atk = shared.attackTeam
	local gained = { 0, 0 }
	if not noPoints then
		local captured = server.capturedPoints()
		gained[atk] = captured
		gained[3 - atk] = siegeTotalPoints() - captured
		shared.score[1] = shared.score[1] + gained[1]
		shared.score[2] = shared.score[2] + gained[2]
	end
	shared.result = { winner = winner, reason = reason, round = shared.round }
	server.setPhase("roundend")
	shared.timer = 0
	for p in Players() do
		local info = shared.players[p]
		if info and info.build ~= 0 then server.buildExit(p) end
	end
	local text = reason
	if winner == 1 or winner == 2 then
		text = TEAM_NAMES[winner] .. " wins the round: " .. reason .. " (+" .. gained[winner] .. ")"
	end
	ClientCall(0, "client.banner", text, winner)
end

function server.endMatch()
	local w = 0
	if shared.score[1] > shared.score[2] then w = 1 elseif shared.score[2] > shared.score[1] then w = 2 end
	shared.result = { winner = w, reason = "match", round = shared.round, match = true }
	server.setPhase("matchend")
end

function server.liveTick(dt)
	local list = server.layout.objectives
	if #list == 0 then return end
	local r = siegeSetting("objradius")
	local ct = siegeSetting("capturetime")
	local attackersAlive, attackersTotal = 0, 0

	for p in Players() do
		local info = shared.players[p]
		if info and info.ready and siegeRoleOf(p) == ROLE_ATTACK then
			attackersTotal = attackersTotal + 1
			if GetPlayerHealth(p) > 0 then attackersAlive = attackersAlive + 1 end
		end
	end

	for i = 1, #list do
		local st = shared.capture[i]
		if st and not st.done then
			local a, d = 0, 0
			for p in Players() do
				local info = shared.players[p]
				if info and info.ready and GetPlayerHealth(p) > 0
					and VecLength(VecSub(GetPlayerTransform(p).pos, list[i].pos)) <= r then
					local role = siegeRoleOf(p)
					if role == ROLE_ATTACK then a = a + 1 elseif role == ROLE_DEFEND then d = d + 1 end
				end
			end

			-- The unrounded value lives on the server; only a rounded copy is sent to clients.
			local prog = server.captureProg[i] or 0
			local state
			if a > 0 and d == 0 then
				state = "capturing"
				if ct <= 0 then prog = 1 else prog = prog + dt / ct * math.min(2.0, 1.0 + 0.25 * (a - 1)) end
			elseif a > 0 then
				state = "contested"
			else
				if ct > 0 then prog = math.max(0, prog - dt / ct * 0.5) end
				state = prog > 0 and "decaying" or "idle"
			end
			prog = math.min(1, prog)
			server.captureProg[i] = prog

			local rounded = math.floor(prog * 100 + 0.5) / 100
			if st.progress ~= rounded then st.progress = rounded end
			if st.state ~= state then st.state = state end
			if st.attackers ~= a then st.attackers = a end
			if st.defenders ~= d then st.defenders = d end

			if prog >= 1 then server.captureObjective(i, "captured") end
		end
	end

	server.floorTick()

	local timeLeft = siegeSetting("roundtime") - server.phaseTime
	local whole = math.max(0, math.ceil(timeLeft))
	if shared.timer ~= whole then shared.timer = whole end

	local def = 3 - shared.attackTeam
	if server.capturedPoints() >= siegeTargetPoints() then
		server.endRound(shared.attackTeam, "objectives captured")
	elseif timeLeft <= 0 then
		server.endRound(def, "held out until time ran out")
	elseif shared.tickets == 0 and attackersTotal > 0 and attackersAlive == 0 then
		server.endRound(def, "attackers ran out of reinforcements")
	end
end

------------------------------------------------------------------------------------------
-- Tick

function server.tick(dt)
	for p in PlayersAdded() do server.playerJoined(p) end
	for p in PlayersRemoved() do server.playerLeft(p) end
	server.restoreTick()
	server.gatesTick(dt)
	server.laddersTick(dt)
	server.cleanupTick(dt)
	server.bowTick(dt)
	server.swordTick(dt)
	server.botsTick(dt)

	server.slowTimer = server.slowTimer - dt
	if server.slowTimer <= 0 then
		server.slowTimer = 1.0
		server.toolsRefresh()
		server.toolsPrimarySync()
		server.enforceTools()
		server.cannonPublish()
		local patched = GetBool("level.siege.cannon.patched")
		if shared.cannonPatched ~= patched then shared.cannonPatched = patched end
		for p in Players() do
			local team = siegeTeamOf(p)
			if team > 0 and server.colorTeam[p] ~= team then
				server.colorTeam[p] = team
				local c = TEAM_COLORS[team]
				SetPlayerColor(c[1], c[2], c[3], p)
			end
		end
	end

	if shared.phase == "prep" or shared.phase == "live" then
		statsTick(server.teamMap())
	end
	eventlogTick(dt)

	server.phaseTime = server.phaseTime + dt

	-- After a level restart, wait until everyone has loaded before the round starts.
	if server.awaiting then
		local count = GetPlayerCount()
		if (count > 0 and count >= GetSessionPlayerCount()) or server.phaseTime >= LOAD_WAIT_MAX then
			server.restoreTick()
			server.startRound()
		end
	end

	-- Fixed guns on the map: attackers once the siege is on, anyone while setting up
	for p in Players() do
		local attackGuns = shared.phase == "setup" or (shared.phase == "live" and siegeRoleOf(p) == ROLE_ATTACK)
		local defendGuns = shared.phase == "setup" or (shared.phase == "live" and siegeRoleOf(p) == ROLE_DEFEND)
		if GetBool("level.siege.guns.allow." .. p) ~= attackGuns then SetBool("level.siege.guns.allow." .. p, attackGuns) end
		if GetBool("level.siege.guns.defend." .. p) ~= defendGuns then SetBool("level.siege.guns.defend." .. p, defendGuns) end
	end

	-- Hold / protect players
	for p in Players() do
		local info = shared.players[p]
		if info then
			local phase = shared.phase
			if server.awaiting or info.team == 0 or not info.ready then
				server.hold(p)
			elseif phase == "prep" and siegeRoleOf(p) == ROLE_ATTACK then
				DisablePlayerDamage(p)
			elseif phase == "setup" or phase == "roundend" or phase == "matchend" then
				DisablePlayerDamage(p)
			end
		end
	end

	if shared.phase == "prep" and not server.awaiting then
		local left = math.max(0, math.ceil(siegeSetting("preptime") - server.phaseTime))
		if shared.timer ~= left then shared.timer = left end
		if server.phaseTime >= siegeSetting("preptime") then server.startLive() end
	elseif shared.phase == "live" then
		server.liveTick(dt)
	elseif shared.phase == "roundend" then
		if server.phaseTime >= ROUND_END_TIME then
			if shared.round >= shared.maxRounds then
				server.endMatch()
			else
				shared.round = shared.round + 1
				if siegeSetting("swap") == 1 then shared.attackTeam = 3 - shared.attackTeam end
				server.matchSaveAndRestart("prep")
				return
			end
		end
	end

	server.respawnTick(dt)
	server.buildTick(dt)
	integrityTick(dt)
end
