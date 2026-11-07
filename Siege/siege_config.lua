-- Siege: configuration and helpers shared by server and client.
-- Edit the tables in this file to tune the mode without touching game logic.

ROLE_ATTACK = 1
ROLE_DEFEND = 2

TEAM_NAMES  = { "Blue", "Red" }
TEAM_COLORS = { {0.2, 0.55, 0.8, 1}, {0.8, 0.25, 0.2, 1} }
ROLE_NAMES  = { "Attackers", "Defenders" }

KEY_MENU  = "o"   -- open/close the Siege menu (team, spawn, host tools)
KEY_BUILD = "b"   -- enter build mode / cycle piece / exit
KEY_STATS = "k"   -- hold to show the scoreboard

-- Weapons tab defaults. The host can override each of these; the choice is saved.
-- Built-in tools are on unless listed here. Mod tools are off unless their name matches CANNON_KEYWORDS.
EXPLOSIVE_TOOLS = {
	bomb = true,
	pipebomb = true,
	rocket = true,
	explosive = true,
}
-- Everyone fights with the bow; the host can turn guns back on in the Weapons tab.
FIREARM_TOOLS = { gun = true, shotgun = true, rifle = true, pistol = true }
-- Switched off in Medieval. In Guns they go back to whatever the Weapons tab says.
MODERN_TOOLS = { blowtorch = true, extinguisher = true, spraycan = true, leafblower = true, booster = true, turbo = true, wire = true, steroid = true }
DEFAULT_OFF_TOOLS = {}
for id in pairs(EXPLOSIVE_TOOLS) do DEFAULT_OFF_TOOLS[id] = true end
for id in pairs(FIREARM_TOOLS) do DEFAULT_OFF_TOOLS[id] = true end
CANNON_KEYWORDS = { "cannon" }
CANNON_TOOL_ID = "handcannon"

-- Tool ids preferred as the active tool after spawning, first match wins.
PREFERRED_START_TOOLS = { "siegebow", "siegesword", "gun", "rifle", "shotgun", "pistol" }

-- Rounds of THE CANNON. Only the patched "THE CANNON (Siege)" copy obeys these.
CANNON_ROUNDS = {
	{ id = "physics",         label = "Traditional ball", default = true, trebDefault = true, minPower = 1, finePower = true },
	{ id = "breaker",         label = "Breaker",          default = false },
	{ id = "ricochet",        label = "Ricochet",         default = false },
	{ id = "explosive",       label = "Ultra explosion",  default = false },
	{ id = "ultraultra",      label = "Ultra ultra",      default = false },
	{ id = "normalexplosive", label = "Normal explosion", default = false },
	{ id = "eraser",          label = "Eraser",           default = false },
	{ id = "fullauto",        label = "Full auto",        default = false },
	{ id = "tetherphysics",   label = "Tether chain",     default = false },
	{ id = "giantphysics",    label = "Colossus ball",    default = false, trebDefault = true },
}

-- Power sliders for each ball, in percent of normal damage.
CANNON_POWER_MIN = 25
CANNON_POWER_MAX = 500

function siegeCannonMinPower(id)
	for i = 1, #CANNON_ROUNDS do
		if CANNON_ROUNDS[i].id == id then return CANNON_ROUNDS[i].minPower or CANNON_POWER_MIN end
	end
	return CANNON_POWER_MIN
end

-- Fortification pieces. Sizes are in voxels (10 voxels = 1 m). "brush" gives the piece its texture.
-- Depth is kept at 1.6 m on purpose: the cannon's Breaker round tunnels 1.2 m through anything,
-- including unbreakable material, so anything thinner can't stop it.
BUILD_PIECES = {
	{ name = "Stone rampart",    w = 30, h = 22, d = 16, brush = "BUILT-IN/brush/outerwall/stone_gray_light.vox", strength = 4, cost = 3 },
	{ name = "Low stone cover",  w = 24, h = 11, d = 16, brush = "BUILT-IN/brush/outerwall/stone_gray_dark.vox",  strength = 4, cost = 1 },
	{ name = "Brick wall",       w = 40, h = 30, d = 16, brush = "BUILT-IN/brush/outerwall/brick_aged.vox",       strength = 4, cost = 5 },
	{ name = "Timber barricade", w = 30, h = 18, d = 16, brush = "BUILT-IN/brush/outerwall/wood_planks_brown.vox", strength = 3, cost = 2 },
	{ name = "Iron bulwark",     w = 30, h = 22, d = 16, material = "heavymetal", color = "0.30 0.30 0.33", strength = 4, cost = 8 },
}
BUILD_RANGE = 6.0                -- metres, standard rules
BUILD_RANGE_ANARCHY = 15.0       -- metres, anarchy rules
BUILD_MAX_PIECES = 150           -- hard cap on spawned pieces per round (performance)
BUILD_OBJECTIVE_CLEARANCE = 2.0  -- standard rules: no building within objective radius + this

-- Wall section presets the host can place (metres: width, height, depth).
WALL_PRESETS = {
	{ name = "Wall",  w = 12, h = 8,  d = 4 },
	{ name = "Gate",  w = 8,  h = 8,  d = 5 },
	{ name = "Tower", w = 8,  h = 14, d = 8 },
	{ name = "Long wall", w = 24, h = 8, d = 4 },
}

LAYOUT_SLOTS = 5
NAME_MAX_LENGTH = 24

-- Host settings. Numbers are sliders; choices keep their buttons (the first option is the default).
-- slider: min/max/step are what the slider moves through. zeroLabel/zeroValue give the far-left
-- position a special meaning, such as Off or Unlimited. format picks how the value is shown.
SETTINGS = {
	{ key = "roundtime", label = "Round time", info = "Time attackers have to capture the objectives.",
	  slider = { min = 60, max = 3600, step = 30, default = 600, format = "time" } },
	{ key = "preptime", label = "Preparation time", info = "Both teams can move and build. Attackers have no weapons and can't be hurt.",
	  slider = { min = 0, max = 300, step = 5, default = 60, format = "seconds", zeroLabel = "Off", zeroValue = 0 } },
	{ key = "prepreturn", label = "Attackers at siege start", info = "Return to spawn stops attackers walking into the castle during preparation and staying there.",
	  options = { {"Return to spawn", 1}, {"Stay put", 0} } },
	{ key = "capturetime", label = "Capture time", info = "Seconds attackers must hold an objective uncontested. Off = touching it captures it.",
	  slider = { min = 0, max = 60, step = 1, default = 10, format = "seconds", zeroLabel = "Off", zeroValue = 0 } },
	{ key = "objradius", label = "Objective radius", info = "Size of each capture zone.",
	  slider = { min = 2, max = 25, step = 1, default = 5, format = "metres" } },
	{ key = "target", label = "Points to win round", info = "Objective points attackers need. Set each objective's points in the Markers tab.",
	  slider = { min = 0, max = 20, step = 1, default = 0, format = "number", zeroLabel = "All", zeroValue = 0 } },
	{ key = "floorbreak", label = "Floor destroyed", info = "An objective counts as captured once this much of the floor under it is gone.",
	  slider = { min = 0, max = 1, step = 0.05, default = 0.5, format = "gone", zeroLabel = "Off", zeroValue = 0 } },
	{ key = "respawn", label = "Respawn time", info = "Seconds before a dead player respawns.",
	  slider = { min = 1, max = 60, step = 1, default = 8, format = "seconds" } },
	{ key = "tickets", label = "Attacker reinforcements", info = "Total attacker respawns per round. When they run out and every attacker is dead, defenders win.",
	  slider = { min = 0, max = 300, step = 5, default = -1, format = "number", zeroLabel = "Unlimited", zeroValue = -1 } },
	{ key = "rounds", label = "Rounds", info = "Rounds per match. The map resets at the start of every round.",
	  slider = { min = 1, max = 10, step = 1, default = 2, format = "number" } },
	{ key = "swap", label = "Swap sides each round", info = "Teams switch between attacking and defending every round.",
	  options = { {"On", 1}, {"Off", 0} } },
	{ key = "balance", label = "Team balance", info = "Attackers can never outnumber defenders. This is how far ahead defenders can get.",
	  slider = { min = 0, max = 5, step = 1, default = 1, format = "lead", zeroLabel = "Off", zeroValue = 99 } },
	{ key = "ammo", label = "Ammo per life", info = "Multiplier on default ammo given at every spawn.",
	  slider = { min = 0, max = 10, step = 1, default = 2, format = "multiplier", zeroLabel = "Unlimited", zeroValue = 0 } },
	{ key = "primary", label = "Weapons era", info = "Medieval: bow and sword, with guns and modern tools switched off. Guns: the game's guns, with bow and sword switched off.",
	  options = { {"Medieval", 1}, {"Guns", 2} } },
	{ key = "attackdir", label = "Attacker direction", info = "Shows defenders a red marker pointing toward the attackers' spawn side.",
	  options = { {"On", 1}, {"Off", 0} } },
	{ key = "gunreload", label = "Fixed cannon reload", info = "Seconds between shots on the fixed cannons. Bot crews wait about twice as long.",
	  slider = { min = 1, max = 30, step = 1, default = 5, format = "seconds" } },
	{ key = "trebreload", label = "Trebuchet reload", info = "Seconds a trebuchet takes to wind back between throws.",
	  slider = { min = 2, max = 60, step = 1, default = 7, format = "seconds" } },
	{ key = "botarchers", label = "Bot archers per side", info = "Bots at posts on the walls and in the trenches, shooting at enemies they can see. They can be killed, and come back after a while. Off on maps without bot posts.",
	  slider = { min = 0, max = 30, step = 1, default = 6, format = "number", zeroLabel = "Off", zeroValue = 0 } },
	{ key = "botcrews", label = "Bot gun crews per side", info = "How many fixed cannons and trebuchets each side has bots on. A player can take over any gun. Needs THE CANNON (Siege).",
	  slider = { min = 0, max = 40, step = 1, default = 6, format = "number", zeroLabel = "Off", zeroValue = 0 } },
	{ key = "botskill", label = "Bot skill", info = "How well bots aim, how hard their arrows hit and how often they shoot.",
	  options = { {"Normal", 2}, {"Easy", 1}, {"Hard", 3} } },
	{ key = "firearrows", label = "Fire arrows per round", info = "How many fire arrows each player gets per round. Plain arrows are unlimited.",
	  slider = { min = 0, max = 50, step = 1, default = 8, format = "number", zeroLabel = "Off", zeroValue = 0 } },
	{ key = "laddermax", label = "Ladders per round", info = "How many ladders each attacker can put up per round, with the L key once the siege starts.",
	  slider = { min = 0, max = 20, step = 1, default = 5, format = "number", zeroLabel = "Off", zeroValue = 0 } },
	{ key = "debris", label = "Clear small rubble", info = "Removes small loose pieces once they stop moving. Helps performance in long sieges with many players.",
	  options = { {"On", 1}, {"Off", 0} } },
	{ key = "building", label = "Who can build", info = "Who can place fortification pieces with the build key.",
	  options = { {"Both teams", 2}, {"Defenders", 1}, {"Nobody", 0} } },
	{ key = "buildrules", label = "Placement rules", info = "Anarchy: place anywhere, up to 15 m away, even in mid-air. Standard: near you, not near objectives, spawns or players.",
	  options = { {"Anarchy", 1}, {"Standard", 0} } },
	{ key = "budget", label = "Build points per round", info = "Build points each builder gets per round.",
	  slider = { min = 0, max = 200, step = 5, default = 20, format = "number", zeroLabel = "Unlimited", zeroValue = -1 } },
}

SETTINGS_BY_KEY = {}
for i = 1, #SETTINGS do SETTINGS_BY_KEY[SETTINGS[i].key] = SETTINGS[i] end

-- Slider position (0 = far left on zero-label sliders) for a stored value, and back.
function siegeSliderRaw(def, value)
	local s = def.slider
	if s.zeroLabel and value == s.zeroValue then return 0 end
	return math.max(s.min, math.min(s.max, value))
end

function siegeSliderValue(def, raw)
	local s = def.slider
	local steps = math.floor((raw - s.min) / s.step + 0.5)
	local snapped = s.min + steps * s.step
	snapped = math.max(s.min, math.min(s.max, snapped))
	if s.zeroLabel and snapped == 0 then return s.zeroValue end
	return snapped
end

function siegeFormatSlider(def, value)
	local s = def.slider
	if s.zeroLabel and value == s.zeroValue then return s.zeroLabel end
	if s.format == "time" then return string.format("%d:%02d", math.floor(value / 60), value % 60) end
	if s.format == "seconds" then return value .. " s" end
	if s.format == "metres" then return value .. " m" end
	if s.format == "gone" then return math.floor(value * 100 + 0.5) .. "% gone" end
	if s.format == "lead" then return "Defenders +" .. value end
	if s.format == "multiplier" then return "x" .. value end
	return tostring(value)
end

-- Button settings keep an option index in shared.settings; sliders keep the value itself.
function siegeSettingIndex(key)
	local def = SETTINGS_BY_KEY[key]
	local idx = 1
	if shared.settings and shared.settings[key] then idx = shared.settings[key] end
	if idx < 1 or idx > #def.options then idx = 1 end
	return idx
end

function siegeSetting(key)
	local def = SETTINGS_BY_KEY[key]
	if def.slider then
		if shared.settings and shared.settings[key] ~= nil then return shared.settings[key] end
		return def.slider.default
	end
	return def.options[siegeSettingIndex(key)][2]
end

function siegeSettingLabel(key)
	local def = SETTINGS_BY_KEY[key]
	if def.slider then return siegeFormatSlider(def, siegeSetting(key)) end
	return def.options[siegeSettingIndex(key)][1]
end

-- Player/team helpers usable on both sides. All guard against shared data not being synced yet.
function siegePlayerInfo(p)
	if shared.players == nil then return nil end
	return shared.players[p]
end

function siegeTeamOf(p)
	local info = siegePlayerInfo(p)
	if info == nil then return 0 end
	return info.team or 0
end

function siegeRoleOfTeam(team)
	if team == 0 or shared.attackTeam == nil then return 0 end
	if team == shared.attackTeam then return ROLE_ATTACK end
	return ROLE_DEFEND
end

function siegeRoleOf(p)
	return siegeRoleOfTeam(siegeTeamOf(p))
end

function siegeTeamCount(team)
	local n = 0
	for p in Players() do
		if siegeTeamOf(p) == team then n = n + 1 end
	end
	return n
end

-- Team size advantage always goes to the defenders: attackers may never outnumber them.
-- The first attacker can join an empty server so solo testing still works.
function siegeJoinBlocked(team, currentTeam)
	local maxLead = siegeSetting("balance")
	if maxLead >= 99 or team == currentTeam then return false end
	local atk = shared.attackTeam or 1
	local attackers = siegeTeamCount(atk)
	local defenders = siegeTeamCount(3 - atk)
	if currentTeam == atk then attackers = attackers - 1 end
	if currentTeam == 3 - atk then defenders = defenders - 1 end
	if team == atk then
		return attackers + 1 > math.max(defenders, 1)
	end
	return defenders + 1 - attackers > maxLead
end

function siegeObjectives()
	if shared.layout == nil or shared.layout.objectives == nil then return {} end
	return shared.layout.objectives
end

function siegeObjectiveState(i)
	if shared.capture == nil then return nil end
	return shared.capture[i]
end

-- Nearest objective that hasn't been captured yet. Returns objective, distance.
function siegeNearestObjective(pos)
	local list = siegeObjectives()
	local best, bestD = nil, nil
	for i = 1, #list do
		local st = siegeObjectiveState(i)
		if not (st and st.done) then
			local d = VecLength(VecSub(list[i].pos, pos))
			if bestD == nil or d < bestD then best, bestD = list[i], d end
		end
	end
	return best, bestD
end

function siegeTotalPoints()
	local list = siegeObjectives()
	local n = 0
	for i = 1, #list do n = n + (list[i].points or 1) end
	return n
end

function siegeTargetPoints()
	local total = siegeTotalPoints()
	local t = siegeSetting("target")
	if t <= 0 or t > total then return total end
	return t
end

-- Spawn indices (into shared.layout.spawns) usable by a role.
function siegeSpawnsForRole(role)
	local list = {}
	if shared.layout == nil or shared.layout.spawns == nil then return list end
	for i = 1, #shared.layout.spawns do
		if shared.layout.spawns[i].role == role then list[#list + 1] = i end
	end
	return list
end

function siegeCompass(from, to)
	local dx = to[1] - from[1]
	local dz = to[3] - from[3]
	local ang = math.deg(math.atan2(dx, -dz))
	if ang < 0 then ang = ang + 360 end
	local names = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }
	return names[(math.floor((ang + 22.5) / 45) % 8) + 1]
end

function siegeFormatDist(d)
	if d == nil then return "-" end
	return tostring(math.floor(d + 0.5)) .. " m"
end

function siegeCleanName(name)
	name = tostring(name or "")
	name = string.gsub(name, "^%s+", "")
	name = string.gsub(name, "%s+$", "")
	if string.len(name) > NAME_MAX_LENGTH then name = string.sub(name, 1, NAME_MAX_LENGTH) end
	return name
end

function siegeCanBuild(p)
	if shared.phase == "setup" then return IsPlayerHost(p) end
	if shared.phase ~= "prep" and shared.phase ~= "live" then return false end
	local mode = siegeSetting("building")
	if mode == 0 then return false end
	local role = siegeRoleOf(p)
	if role == 0 then return false end
	if mode == 1 and role ~= ROLE_DEFEND then return false end
	return true
end

function siegeBuildAnarchy()
	return siegeSetting("buildrules") == 1
end

-- Oriented box corners for drawing: t = transform at bottom-centre, sizes in metres.
function siegeBoxCorners(t, w, h, d)
	local hw, hd = w * 0.5, d * 0.5
	local c = {}
	local pts = {
		{-hw, 0, -hd}, { hw, 0, -hd}, { hw, 0, hd}, {-hw, 0, hd},
		{-hw, h, -hd}, { hw, h, -hd}, { hw, h, hd}, {-hw, h, hd},
	}
	for i = 1, 8 do
		c[i] = TransformToParentPoint(t, Vec(pts[i][1], pts[i][2], pts[i][3]))
	end
	return c
end

function siegeDrawBox(t, w, h, d, r, g, b, a)
	local c = siegeBoxCorners(t, w, h, d)
	local edges = { {1,2},{2,3},{3,4},{4,1},{5,6},{6,7},{7,8},{8,5},{1,5},{2,6},{3,7},{4,8} }
	for i = 1, #edges do
		DrawLine(c[edges[i][1]], c[edges[i][2]], r, g, b, a)
	end
end

function siegeDrawCircle(center, radius, r, g, b, a)
	local segs = 32
	local prev = nil
	for i = 0, segs do
		local ang = (i / segs) * math.pi * 2
		local p = Vec(center[1] + math.cos(ang) * radius, center[2] + 0.2, center[3] + math.sin(ang) * radius)
		if prev then DrawLine(prev, p, r, g, b, a) end
		prev = p
	end
end
