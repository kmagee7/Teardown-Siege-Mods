-- Siege: map layout (objectives, spawn points, wall sections).
-- The current layout is saved automatically per level under savegame.mod.layouts.<level>.
-- The host can also store named copies in slots under savegame.mod.slots.<level>.<n>.
-- If nothing is saved, location tags placed in the level editor are used:
--   siegeobjective[=points]   capture zone centre
--   siegespawn=attack|defend  spawn point for that role (falls back to teamspawn=1 / teamspawn=2)
--   siegewall=<WxHxD>         wall section box in metres, e.g. siegewall=12x8x4 (or a preset name: wall, gate, tower)
--   siegename=Some_name       optional display name for any of these; underscores become spaces

function siegeYawFromRot(rot)
	local f = QuatRotateVec(rot, Vec(0, 0, -1))
	return math.deg(math.atan2(-f[1], -f[3]))
end

function siegeYawTransform(pos, yaw)
	return Transform(pos, QuatEuler(0, yaw, 0))
end

function server._layoutLevelKey()
	local s = GetString("game.levelid")
	if s == nil or s == "" then s = GetString("game.levelpath") end
	if s == nil or s == "" then s = "default" end
	s = string.lower(s)
	s = (string.gsub(s, "[^a-z0-9_]", "_"))
	if string.len(s) > 60 then s = string.sub(s, -60) end
	return s
end

function server._layoutBase()
	return "savegame.mod.layouts." .. server.levelKey
end

function server._slotBase(i)
	return "savegame.mod.slots." .. server.levelKey .. "." .. i
end

function server.layoutEmpty()
	return { objectives = {}, spawns = {}, walls = {}, source = "none" }
end

-- Display name from a location's siegename tag.
local function _tagLabel(loc)
	return (string.gsub(GetTagValue(loc, "siegename"), "_", " "))
end

local function _readVec(k)
	return Vec(GetFloat(k .. ".x"), GetFloat(k .. ".y"), GetFloat(k .. ".z"))
end

local function _writeVec(k, v)
	SetFloat(k .. ".x", v[1]); SetFloat(k .. ".y", v[2]); SetFloat(k .. ".z", v[3])
end

function server.layoutRead(base)
	local L = server.layoutEmpty()
	-- Layouts saved by the first version of the mod had a single objective.
	if GetBool(base .. ".objective.set") then
		L.objectives[1] = { pos = _readVec(base .. ".objective"), points = 1, label = "" }
	end
	local n = GetInt(base .. ".objectives.count")
	for i = 1, n do
		local k = base .. ".objectives." .. i
		L.objectives[#L.objectives + 1] = { pos = _readVec(k), points = math.max(1, GetInt(k .. ".points")), label = GetString(k .. ".label") }
	end
	n = GetInt(base .. ".spawns.count")
	for i = 1, n do
		local k = base .. ".spawns." .. i
		L.spawns[#L.spawns + 1] = { role = GetInt(k .. ".role"), pos = _readVec(k), yaw = GetFloat(k .. ".yaw"), label = GetString(k .. ".label") }
	end
	n = GetInt(base .. ".walls.count")
	for i = 1, n do
		local k = base .. ".walls." .. i
		L.walls[#L.walls + 1] = {
			label = GetString(k .. ".label"), pos = _readVec(k), yaw = GetFloat(k .. ".yaw"),
			w = GetFloat(k .. ".w"), h = GetFloat(k .. ".h"), d = GetFloat(k .. ".d"),
		}
	end
	return L
end

function server.layoutWrite(base, L)
	ClearKey(base)
	SetBool(base .. ".saved", true)
	SetInt(base .. ".objectives.count", #L.objectives)
	for i = 1, #L.objectives do
		local k = base .. ".objectives." .. i
		local o = L.objectives[i]
		_writeVec(k, o.pos)
		SetInt(k .. ".points", o.points or 1)
		SetString(k .. ".label", o.label or "")
	end
	SetInt(base .. ".spawns.count", #L.spawns)
	for i = 1, #L.spawns do
		local k = base .. ".spawns." .. i
		local s = L.spawns[i]
		SetInt(k .. ".role", s.role)
		_writeVec(k, s.pos)
		SetFloat(k .. ".yaw", s.yaw)
		SetString(k .. ".label", s.label or "")
	end
	SetInt(base .. ".walls.count", #L.walls)
	for i = 1, #L.walls do
		local k = base .. ".walls." .. i
		local w = L.walls[i]
		SetString(k .. ".label", w.label or "")
		_writeVec(k, w.pos)
		SetFloat(k .. ".yaw", w.yaw)
		SetFloat(k .. ".w", w.w); SetFloat(k .. ".h", w.h); SetFloat(k .. ".d", w.d)
	end
end

function server.layoutLoad()
	local base = server._layoutBase()
	if GetBool(base .. ".saved") then
		local L = server.layoutRead(base)
		L.source = "saved"
		return L
	end
	return server.layoutFromTags()
end

function server.layoutFromTags()
	local L = server.layoutEmpty()
	local locs = FindLocations("siegeobjective", true)
	for i = 1, #locs do
		local pts = tonumber(GetTagValue(locs[i], "siegeobjective")) or 1
		L.objectives[#L.objectives + 1] = { pos = GetLocationTransform(locs[i]).pos, points = math.max(1, pts), label = _tagLabel(locs[i]) }
	end

	locs = FindLocations("siegespawn", true)
	for i = 1, #locs do
		local v = string.lower(GetTagValue(locs[i], "siegespawn"))
		local role = (v == "defend" or v == "defender" or v == "defenders" or v == "2") and ROLE_DEFEND or ROLE_ATTACK
		local t = GetLocationTransform(locs[i])
		L.spawns[#L.spawns + 1] = { role = role, pos = t.pos, yaw = siegeYawFromRot(t.rot), label = _tagLabel(locs[i]) }
	end
	if #L.spawns == 0 then
		locs = FindLocations("teamspawn", true)
		for i = 1, #locs do
			local team = tonumber(GetTagValue(locs[i], "teamspawn"))
			if team == 1 or team == 2 then
				local t = GetLocationTransform(locs[i])
				L.spawns[#L.spawns + 1] = { role = team, pos = t.pos, yaw = siegeYawFromRot(t.rot), label = _tagLabel(locs[i]) }
			end
		end
	end

	locs = FindLocations("siegewall", true)
	for i = 1, #locs do
		local v = string.lower(GetTagValue(locs[i], "siegewall"))
		local w, h, d = 12, 8, 4
		local a, b, c = string.match(v, "([%d%.]+)[%sx]+([%d%.]+)[%sx]+([%d%.]+)")
		if a then
			w, h, d = tonumber(a), tonumber(b), tonumber(c)
		else
			for j = 1, #WALL_PRESETS do
				if string.lower(WALL_PRESETS[j].name) == v then
					w, h, d = WALL_PRESETS[j].w, WALL_PRESETS[j].h, WALL_PRESETS[j].d
				end
			end
		end
		local t = GetLocationTransform(locs[i])
		L.walls[#L.walls + 1] = { label = _tagLabel(locs[i]), pos = t.pos, yaw = siegeYawFromRot(t.rot), w = w, h = h, d = d }
	end

	if #L.objectives > 0 or #L.spawns > 0 or #L.walls > 0 then L.source = "map tags" end
	return L
end

-- Display names: the host's label if there is one, otherwise an automatic name.
function server.layoutFinalize(L)
	local letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
	for i = 1, #L.objectives do
		local o = L.objectives[i]
		if o.label and o.label ~= "" then
			o.name = o.label
		elseif #L.objectives == 1 then
			o.name = "Objective"
		else
			o.name = "Objective " .. string.sub(letters, ((i - 1) % 26) + 1, ((i - 1) % 26) + 1)
		end
	end
	local counts = { 0, 0 }
	for i = 1, #L.spawns do
		local s = L.spawns[i]
		counts[s.role] = counts[s.role] + 1
		local auto = (s.role == ROLE_ATTACK and "A" or "D") .. counts[s.role]
		s.name = (s.label and s.label ~= "") and s.label or auto
	end
	for i = 1, #L.walls do
		local w = L.walls[i]
		w.name = (w.label and w.label ~= "") and w.label or ("Section " .. i)
	end
	return L
end

-- Push the server copy to clients and persist it.
function server.layoutCommit(save)
	server.layout = server.layoutFinalize(server.layout)
	if save then
		server.layout.source = "saved"
		server.layoutWrite(server._layoutBase(), server.layout)
	end
	local S = { objectives = {}, spawns = {}, walls = {}, source = server.layout.source }
	for i = 1, #server.layout.objectives do
		local o = server.layout.objectives[i]
		S.objectives[i] = { pos = VecCopy(o.pos), points = o.points or 1, name = o.name }
	end
	for i = 1, #server.layout.spawns do
		local s = server.layout.spawns[i]
		S.spawns[i] = { role = s.role, pos = VecCopy(s.pos), yaw = s.yaw, name = s.name }
	end
	for i = 1, #server.layout.walls do
		local w = server.layout.walls[i]
		S.walls[i] = { name = w.name, pos = VecCopy(w.pos), yaw = w.yaw, w = w.w, h = w.h, d = w.d }
	end
	shared.layout = S
	server.objectivesReset()
	integrityBegin()
end

-- Host editing actions (called through ServerCall from the host's client).
function server.layoutEdit(playerId, action, arg)
	if not IsPlayerHost(playerId) or shared.phase ~= "setup" then return end
	local t = GetPlayerTransform(playerId)
	local yaw = siegeYawFromRot(GetPlayerCameraTransform(playerId).rot)
	local L = server.layout

	if action == "objective" then
		L.objectives[#L.objectives + 1] = { pos = VecCopy(t.pos), points = 1, label = "" }
	elseif action == "spawn" then
		L.spawns[#L.spawns + 1] = { role = arg, pos = VecCopy(t.pos), yaw = yaw, label = "" }
	elseif action == "wall" then
		local p = WALL_PRESETS[arg] or WALL_PRESETS[1]
		local fwd = QuatRotateVec(QuatEuler(0, yaw, 0), Vec(0, 0, -1))
		local pos = VecAdd(t.pos, VecScale(fwd, p.d * 0.5 + 1.0))
		pos[2] = pos[2] - 1.0
		L.walls[#L.walls + 1] = { label = p.name .. " " .. (#L.walls + 1), pos = pos, yaw = yaw, w = p.w, h = p.h, d = p.d }
	elseif action == "removenearest" then
		local best, bestKind, bestIdx = 6.0, nil, nil
		for i = 1, #L.objectives do
			local d = VecLength(VecSub(L.objectives[i].pos, t.pos))
			if d < best then best = d; bestKind = "objective"; bestIdx = i end
		end
		for i = 1, #L.spawns do
			local d = VecLength(VecSub(L.spawns[i].pos, t.pos))
			if d < best then best = d; bestKind = "spawn"; bestIdx = i end
		end
		for i = 1, #L.walls do
			local c = VecAdd(L.walls[i].pos, Vec(0, L.walls[i].h * 0.5, 0))
			local d = VecLength(VecSub(c, t.pos)) - math.max(L.walls[i].w, L.walls[i].d) * 0.5
			if d < best then best = d; bestKind = "wall"; bestIdx = i end
		end
		if bestKind == nil then
			ClientCall(playerId, "client.notify", "Nothing within 6 m to remove.")
			return
		elseif bestKind == "objective" then table.remove(L.objectives, bestIdx)
		elseif bestKind == "spawn" then table.remove(L.spawns, bestIdx)
		else table.remove(L.walls, bestIdx) end
	elseif action == "clear" then
		server.layout = server.layoutEmpty()
	elseif action == "reloadtags" then
		ClearKey(server._layoutBase())
		server.layout = server.layoutFromTags()
		server.layoutCommit(false)
		ClientCall(playerId, "client.notify", "Layout loaded from map tags (" .. server.layout.source .. ").")
		return
	end
	server.layoutCommit(true)
end

function server.layoutRename(playerId, kind, idx, name)
	if not IsPlayerHost(playerId) or shared.phase ~= "setup" then return end
	local list = server.layout[kind]
	if list == nil or list[idx] == nil then return end
	list[idx].label = siegeCleanName(name)
	server.layoutCommit(true)
end

function server.layoutObjectivePoints(playerId, idx, points)
	if not IsPlayerHost(playerId) or shared.phase ~= "setup" then return end
	local o = server.layout.objectives[idx]
	if o == nil then return end
	if points < 1 then points = 10 elseif points > 10 then points = 1 end
	o.points = points
	server.layoutCommit(true)
end

-- Named layout slots
function server.slotsPublish()
	local S = {}
	for i = 1, LAYOUT_SLOTS do
		local base = server._slotBase(i)
		if GetBool(base .. ".saved") then
			S[i] = { used = true, name = GetString(base .. ".slotname") }
		else
			S[i] = { used = false, name = "" }
		end
	end
	shared.layoutSlots = S
end

function server.slotSave(playerId, i, name)
	if not IsPlayerHost(playerId) or shared.phase ~= "setup" or i < 1 or i > LAYOUT_SLOTS then return end
	local clean = siegeCleanName(name)
	if clean == "" then clean = "Layout " .. i end
	local base = server._slotBase(i)
	server.layoutWrite(base, server.layout)
	SetString(base .. ".slotname", clean)
	server.slotsPublish()
	ClientCall(playerId, "client.notify", "Saved layout: " .. clean)
end

function server.slotLoad(playerId, i)
	if not IsPlayerHost(playerId) or shared.phase ~= "setup" or i < 1 or i > LAYOUT_SLOTS then return end
	local base = server._slotBase(i)
	if not GetBool(base .. ".saved") then return end
	server.layout = server.layoutRead(base)
	server.layoutCommit(true)
	ClientCall(playerId, "client.notify", "Loaded layout: " .. GetString(base .. ".slotname"))
end

function server.slotDelete(playerId, i)
	if not IsPlayerHost(playerId) or shared.phase ~= "setup" or i < 1 or i > LAYOUT_SLOTS then return end
	ClearKey(server._slotBase(i))
	server.slotsPublish()
end

-- Transform for spawning a player at their chosen spawn (with fallbacks).
function server.spawnTransformFor(p)
	local info = shared.players[p]
	local role = siegeRoleOf(p)
	local L = server.layout
	local offset = Vec(GetRandomFloat(-1.5, 1.5), 0.2, GetRandomFloat(-1.5, 1.5))
	if info and info.spawn and info.spawn > 0 and L.spawns[info.spawn] and L.spawns[info.spawn].role == role then
		local s = L.spawns[info.spawn]
		return siegeYawTransform(VecAdd(s.pos, offset), s.yaw)
	end
	local list = {}
	for i = 1, #L.spawns do
		if L.spawns[i].role == role then list[#list + 1] = L.spawns[i] end
	end
	if #list > 0 then
		local s = list[GetRandomInt(1, #list)]
		return siegeYawTransform(VecAdd(s.pos, offset), s.yaw)
	end
	if server.fallbackSpawns and #server.fallbackSpawns > 0 then
		return server.fallbackSpawns[GetRandomInt(1, #server.fallbackSpawns)]
	end
	return nil
end
