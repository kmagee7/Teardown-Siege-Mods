-- Siege: fortification building.
-- Press KEY_BUILD to enter build mode (your tool is put away), press again to cycle pieces,
-- once more after the last piece to exit. LMB places, RMB rotates 90 degrees.
-- The client draws the preview and sends the placement; the server validates and spawns.

server.build = { prevTool = {}, grace = {} }

function siegePieceXml(piece)
	local hx = piece.w / 20  -- half width in metres (10 voxels per metre)
	local hz = piece.d / 20
	local look
	if piece.brush then
		look = "brush='" .. piece.brush .. "'"
	else
		look = "material='" .. piece.material .. "' color='" .. piece.color .. "'"
	end
	return string.format("<voxbox size='%d %d %d' pos='%.2f 0 %.2f' strength='%d' %s/>",
		piece.w, piece.h, piece.d, -hx, -hz, piece.strength or 1, look)
end

function siegeBuildRange()
	if siegeBuildAnarchy() then return BUILD_RANGE_ANARCHY end
	return BUILD_RANGE
end

-- Shared validation used by the client preview and the server. Returns ok, reason.
function siegeBuildCheck(p, pieceIdx, pos, yaw)
	local piece = BUILD_PIECES[pieceIdx]
	if piece == nil then return false, "No piece" end
	if not siegeCanBuild(p) then return false, "Building not allowed now" end
	local info = siegePlayerInfo(p)
	if info == nil then return false, "" end
	local unlimited = shared.phase == "setup" or siegeSetting("budget") < 0
	if not unlimited and (info.budget or 0) < piece.cost then return false, "Not enough build points" end
	if (shared.buildPieces or 0) >= BUILD_MAX_PIECES then return false, "Piece limit reached for this round" end

	local eye = GetPlayerEyeTransform(p).pos
	if VecLength(VecSub(pos, eye)) > siegeBuildRange() + 2.0 then return false, "Too far away" end

	if siegeBuildAnarchy() then return true, "" end

	local r = siegeSetting("objradius") + BUILD_OBJECTIVE_CLEARANCE
	local objectives = siegeObjectives()
	for i = 1, #objectives do
		if VecLength(VecSub(pos, objectives[i].pos)) < r then return false, "Too close to an objective" end
	end

	-- Reject if any player stands inside the piece (checked in the piece's local space).
	local t = siegeYawTransform(pos, yaw or 0)
	local hw, hh, hd = piece.w / 20 + 0.4, piece.h / 10 + 0.2, piece.d / 20 + 0.4
	for q in Players() do
		if GetPlayerHealth(q) > 0 then
			local lp = TransformToLocalPoint(t, GetPlayerTransform(q).pos)
			if math.abs(lp[1]) < hw and math.abs(lp[3]) < hd and lp[2] > -1.9 and lp[2] < hh then
				return false, "Blocked by a player"
			end
		end
	end

	if shared.layout and shared.layout.spawns then
		for i = 1, #shared.layout.spawns do
			if VecLength(VecSub(shared.layout.spawns[i].pos, pos)) < 4.0 then
				return false, "Too close to a spawn point"
			end
		end
	end
	return true, ""
end

-- Server: toggle / cycle build mode for a player.
function server.buildToggle(p)
	local info = shared.players[p]
	if info == nil then return end
	if not siegeCanBuild(p) or GetPlayerHealth(p) <= 0 or not info.ready then
		if info.build ~= 0 then server.buildExit(p) end
		local why = "You can't build right now."
		if (shared.phase == "prep" or shared.phase == "live") and siegeSetting("building") == 1 then
			why = "Only defenders can build. The host can change Who can build in Settings."
		elseif (shared.phase == "prep" or shared.phase == "live") and siegeSetting("building") == 0 then
			why = "Building is off. The host can change Who can build in Settings."
		end
		ClientCall(p, "client.notify", why)
		return
	end
	if info.build == 0 then
		server.build.prevTool[p] = GetPlayerTool(p)
		info.build = 1
		SetPlayerTool("none", p)
		server.build.grace[p] = 0.5
	elseif info.build < #BUILD_PIECES then
		info.build = info.build + 1
	else
		server.buildExit(p)
	end
end

function server.buildExit(p)
	local info = shared.players[p]
	if info == nil then return end
	info.build = 0
	local prev = server.build.prevTool[p]
	if prev and prev ~= "" and prev ~= "none" and IsToolEnabled(prev, p) then
		SetPlayerTool(prev, p)
	end
	server.build.prevTool[p] = nil
end

function server.buildPlace(p, pieceIdx, x, y, z, yaw)
	local info = shared.players[p]
	if info == nil or info.build ~= pieceIdx then return end
	local pos = Vec(x, y, z)
	local ok, reason = siegeBuildCheck(p, pieceIdx, pos, yaw)
	if not ok then
		ClientCall(p, "client.notify", reason)
		return
	end
	local piece = BUILD_PIECES[pieceIdx]
	local ents = Spawn(siegePieceXml(piece), siegeYawTransform(pos, yaw), true, true)
	if ents == nil or #ents == 0 then
		ClientCall(p, "client.notify", "Could not place piece here.")
		return
	end
	for i = 1, #ents do
		if GetEntityType(ents[i]) == "shape" then SetTag(ents[i], "siegefort") end
	end
	shared.buildPieces = (shared.buildPieces or 0) + 1
	if shared.phase ~= "setup" and siegeSetting("budget") >= 0 then
		info.budget = info.budget - piece.cost
	end
end

-- Server tick: leave build mode when the player switches tool or dies.
function server.buildTick(dt)
	for p in Players() do
		local info = shared.players[p]
		if info and info.build ~= 0 then
			local g = (server.build.grace[p] or 0) - dt
			server.build.grace[p] = g
			if GetPlayerHealth(p) <= 0 or not siegeCanBuild(p) then
				info.build = 0
				server.build.prevTool[p] = nil
			elseif g <= 0 then
				local tool = GetPlayerTool(p)
				if tool ~= "none" and tool ~= "" then
					-- Player selected a tool: leave build mode without overriding their choice.
					info.build = 0
					server.build.prevTool[p] = nil
				end
			end
		end
	end
end

------------------------------------------------------------------------------------------
-- Client side preview

client.build = { rot = 0, valid = false, pos = nil, yaw = 0, reason = "" }

-- Compute the placement for the local player. Returns pos, yaw or nil.
function client.buildComputePlacement(pieceIdx)
	local piece = BUILD_PIECES[pieceIdx]
	local eye = GetPlayerEyeTransform()
	local range = siegeBuildRange()
	local hit, _, endpos, _, normal = GetPlayerAimInfo(eye.pos, range)
	local yaw = siegeYawFromRot(eye.rot) + client.build.rot * 90
	if not hit then
		-- Anarchy allows placing in mid-air at full range.
		if not siegeBuildAnarchy() then return nil end
		local f = QuatRotateVec(eye.rot, Vec(0, 0, -1))
		return VecAdd(eye.pos, VecScale(f, range)), yaw
	end
	local pos = VecCopy(endpos)
	-- Aiming at a wall (mostly horizontal normal): push out so the piece sits against it,
	-- and face the piece along the wall.
	if normal and math.abs(normal[2]) < 0.5 then
		pos = VecAdd(pos, VecScale(normal, piece.d / 20 + 0.02))
		local f = Vec(-normal[1], 0, -normal[3])
		yaw = math.deg(math.atan2(-f[1], -f[3])) + client.build.rot * 90
		pos[2] = pos[2] - piece.h / 20   -- centre vertically on the aim point
	end
	return pos, yaw
end

function client.buildTick(dt)
	local me = GetLocalPlayer()
	local info = siegePlayerInfo(me)
	client.build.valid = false
	if info == nil or info.build == nil or info.build == 0 then return end
	local pieceIdx = info.build
	local piece = BUILD_PIECES[pieceIdx]
	if piece == nil then return end
	if client.menuShouldShow() then return end   -- clicks belong to the menu

	if InputPressed("rmb") then client.build.rot = (client.build.rot + 1) % 4 end

	local pos, yaw = client.buildComputePlacement(pieceIdx)
	if pos then
		local ok, reason = siegeBuildCheck(me, pieceIdx, pos, yaw)
		client.build.valid = ok
		client.build.reason = reason
		client.build.pos = pos
		client.build.yaw = yaw
		local t = siegeYawTransform(pos, yaw)
		if ok then
			siegeDrawBox(t, piece.w / 10, piece.h / 10, piece.d / 10, 0.3, 1.0, 0.4, 0.9)
		else
			siegeDrawBox(t, piece.w / 10, piece.h / 10, piece.d / 10, 1.0, 0.3, 0.3, 0.9)
		end
		if ok and InputPressed("lmb") then
			ServerCall("server.buildPlace", me, pieceIdx, pos[1], pos[2], pos[3], yaw)
		end
	else
		client.build.pos = nil
		client.build.reason = "Aim at a surface within " .. siegeBuildRange() .. " m"
	end
end
