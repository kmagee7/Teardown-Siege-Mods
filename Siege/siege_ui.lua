-- Siege: client side (HUD, menus, world markers).

client.menuOpen = false       -- players without a team or spawn see the menu anyway
client.page = "spawn"         -- "team" | "spawn" | "rules"
client.forceTeamPage = false
client.hostTab = "layout"     -- "layout" | "markers" | "saves" | "weapons" | "settings" | "match"
client.wallPreset = 1
client.notices = {}
client.typing = false
client.inputs = { slot = "", rename = "" }
client.renaming = nil
client.pages = { markers = 1, weapons = 1, settings = 1 }
client.weaponsView = "tools"  -- "tools" | "balls"
client.sliderDrag = {}

------------------------------------------------------------------------------------------
-- Called from the server via ClientCall

function client.notify(msg)
	client.notices[#client.notices + 1] = { text = msg, t = 4.0 }
end

function client.banner(text, team)
	local c = TEAM_COLORS[team] or { 0.25, 0.25, 0.25, 1 }
	hudShowBanner(text, { c[1], c[2], c[3], 1 })
end

------------------------------------------------------------------------------------------
-- Helpers

local function _col(c, a) UiColor(c[1], c[2], c[3], a or c[4] or 1) end

local function _text(str, size, color, font)
	UiFont(font or FONT_MEDIUM, size or FONT_SIZE_20)
	if color then _col(color) else UiColor(1, 1, 1, 1) end
	local w, h = UiText(str)
	return w, h
end

-- Closest living attacker to any objective still in play, and how many are within 25 m of one.
local function _closestAttacker()
	local best, near = nil, 0
	for p in Players() do
		if siegeRoleOf(p) == ROLE_ATTACK and GetPlayerHealth(p) > 0 then
			local info = siegePlayerInfo(p)
			if info and info.ready then
				local _, d = siegeNearestObjective(GetPlayerTransform(p).pos)
				if d then
					if best == nil or d < best then best = d end
					if d < 25 then near = near + 1 end
				end
			end
		end
	end
	return best, near
end

function client.menuShouldShow()
	local info = siegePlayerInfo(GetLocalPlayer())
	if info == nil or shared.phase == nil or shared.phase == "matchend" then return false end
	if info.team == 0 or not info.ready then return true end
	if GetPlayerHealth() <= 0 then return true end
	return client.menuOpen
end

function client.playerColorMap()
	local m = {}
	for p in Players() do
		local t = siegeTeamOf(p)
		if t > 0 then m[p] = TEAM_COLORS[t] end
	end
	return m
end

function client.explosivesAllowed()
	if shared.toolRules == nil then return false end
	for id, _ in pairs(EXPLOSIVE_TOOLS) do
		if shared.toolRules[id] then return true end
	end
	return false
end

function client.briefing()
	local ct = siegeSetting("capturetime")
	local count = #siegeObjectives()
	local s = "ATTACKERS: break into the defences and reach the objective" .. (count > 1 and "s" or "") .. ". "
	if ct > 0 then
		s = s .. "Hold one for " .. ct .. " s with no defender inside the zone to capture it. "
	else
		s = s .. "Touching one captures it. "
	end
	if siegeSetting("floorbreak") > 0 then
		s = s .. "Destroying the floor under an objective also captures it. "
	end
	if count > 1 then
		s = s .. "You need " .. siegeTargetPoints() .. " of " .. siegeTotalPoints() .. " objective points to win the round. "
	end
	s = s .. "\n\nDEFENDERS: stop them until the round timer (" .. siegeSettingLabel("roundtime") .. ") runs out"
	if siegeSetting("tickets") > 0 then
		s = s .. ", or use up all " .. siegeSetting("tickets") .. " attacker reinforcements"
	end
	s = s .. ". "
	if siegeSetting("preptime") > 0 then
		s = s .. "\n\nPREPARATION: " .. siegeSettingLabel("preptime") .. " to move around and fortify. Attackers have no weapons until the siege starts"
		if siegeSetting("prepreturn") == 1 then s = s .. ", then return to their spawn" end
		s = s .. ". "
	end
	local b = siegeSetting("building")
	if b > 0 then
		local who = b == 1 and "Defenders" or "Both teams"
		local pts = siegeSetting("budget") < 0 and "unlimited build points" or (siegeSetting("budget") .. " build points per round")
		s = s .. who .. " can place fortifications with [" .. string.upper(KEY_BUILD) .. "] (" .. pts .. "). "
	end
	s = s .. "\n\nWEAPONS: " .. (siegeSetting("primary") == 1 and "everyone has a bow and a sword. Hold fire to draw the bow and let go to shoot; R switches to fire arrows. Left click swings the sword. Explosives are " or "everyone has guns. Explosives are ") .. (client.explosivesAllowed() and "allowed" or "disabled") .. ". "
	if shared.toolRules and shared.toolRules[CANNON_TOOL_ID] then
		s = s .. "The cannon is allowed"
		s = s .. ". "
	end
	if siegeSetting("rounds") > 1 then
		s = s .. "\n\n" .. siegeSetting("rounds") .. " rounds"
		if siegeSetting("swap") == 1 then s = s .. ", teams swap sides every round" end
		s = s .. ". The map resets each round. Each objective's points go to the attackers if captured, otherwise to the defenders."
	end
	s = s .. "\n\n[" .. string.upper(KEY_MENU) .. "] Siege menu   [" .. string.upper(KEY_STATS) .. "] scoreboard"
	return s
end

------------------------------------------------------------------------------------------
-- Tick (input + 3D lines)

function client.tick(dt)
	client.bowTick(dt)
	client.swordTick()
	hudTick(dt)
	if shared.phase == nil or shared.players == nil then return end
	local me = GetLocalPlayer()
	local info = siegePlayerInfo(me)

	if PauseMenuButton("Siege menu") then
		client.menuOpen = true
	end
	if not client.typing then
		if InputPressed(KEY_MENU) then
			client.menuOpen = not client.menuOpen
			if client.menuOpen then client.page = "spawn" end
		end
		if info and info.ready and not client.menuShouldShow() and InputPressed(KEY_BUILD) then
			ServerCall("server.buildToggle", me)
		end
	end

	client.buildTick(dt)
	client.drawWorld()

	local i = 1
	while i <= #client.notices do
		client.notices[i].t = client.notices[i].t - dt
		if client.notices[i].t <= 0 then table.remove(client.notices, i) else i = i + 1 end
	end
end

function client.drawWorld()
	client.gatesDrawWorld()
	local L = shared.layout
	if L == nil then return end
	local me = GetLocalPlayer()
	local myRole = siegeRoleOf(me)
	local editing = shared.phase == "setup" and IsPlayerHost(me)
	local r = siegeSetting("objradius")

	for i = 1, #L.objectives do
		local o = L.objectives[i]
		local st = siegeObjectiveState(i) or {}
		local cr, cg, cb = 1.0, 0.85, 0.2
		if st.done then cr, cg, cb = 0.4, 0.4, 0.4
		elseif st.state == "capturing" then cr, cg, cb = 1.0, 0.35, 0.25
		elseif st.state == "contested" then cr, cg, cb = 1.0, 1.0, 1.0 end
		siegeDrawCircle(o.pos, r, cr, cg, cb, 0.9)
		if not st.done then
			DrawLine(o.pos, VecAdd(o.pos, Vec(0, 25, 0)), cr, cg, cb, 0.6)
		end
	end

	if editing or client.menuShouldShow() then
		for i = 1, #L.spawns do
			local s = L.spawns[i]
			if editing or s.role == myRole then
				local c = (s.role == ROLE_ATTACK) and { 1.0, 0.45, 0.3 } or { 0.35, 0.7, 1.0 }
				DrawLine(s.pos, VecAdd(s.pos, Vec(0, 6, 0)), c[1], c[2], c[3], 0.9)
				local f = QuatRotateVec(QuatEuler(0, s.yaw, 0), Vec(0, 0, -1))
				local base = VecAdd(s.pos, Vec(0, 0.3, 0))
				DrawLine(base, VecAdd(base, VecScale(f, 2)), c[1], c[2], c[3], 0.9)
			end
		end
	end

	if editing then
		for i = 1, #L.walls do
			local w = L.walls[i]
			siegeDrawBox(siegeYawTransform(w.pos, w.yaw), w.w, w.h, w.d, 0.9, 0.9, 0.5, 0.8)
		end
	end
end

------------------------------------------------------------------------------------------
-- Draw

function client.draw(dt)
	dt = dt or GetTimeStep()
	client.typing = false
	if shared.phase == nil or shared.players == nil then return end
	client.gatesDrawPrompt()
	client.laddersDraw()
	client.bowDraw()
	client.compassDraw()
	local me = GetLocalPlayer()
	local info = siegePlayerInfo(me)

	if shared.phase == "matchend" then
		client.drawResults()
		return
	end

	hudDrawDamageIndicators(dt)
	client.drawMarkers()
	client.drawTopHud()
	client.drawStatus()
	eventlogDraw(dt, client.playerColorMap())
	hudDrawBanner(dt)
	client.drawBuildHud()

	local menu = client.menuShouldShow()
	if info and info.ready and GetPlayerHealth(me) <= 0 then
		local left = shared.respawnLeft and shared.respawnLeft[me]
		if left == -1 then
			hudDrawInformationMessage("No reinforcements left. Wait for the next round.", 1)
		elseif left and left > 0 then
			hudDrawRespawnTimer(left)
		end
	end

	client.drawNotices()
	if menu then client.drawMenu() end
	hudDrawScoreboard(InputDown(KEY_STATS) and not menu and not client.typing, "Siege - Round " .. (shared.round or 1), client.scoreColumns(), client.scoreGroups())
end

function client.drawMarkers()
	local me = GetLocalPlayer()
	local markers = {}
	local myPos = GetPlayerTransform(me).pos
	local objectives = siegeObjectives()
	for i = 1, #objectives do
		local o = objectives[i]
		local st = siegeObjectiveState(i)
		if not (st and st.done) then
			markers[#markers + 1] = {
				pos = o.pos, offset = Vec(0, 3, 0), color = COLOR_YELLOW,
				label = string.upper(o.name) .. "  " .. siegeFormatDist(VecLength(VecSub(myPos, o.pos))),
				lineOfSightRequired = false, drawIconInView = false,
			}
		end
	end
	if client.menuShouldShow() and shared.layout then
		local role = siegeRoleOf(me)
		local editing = shared.phase == "setup" and IsPlayerHost(me)
		for i = 1, #shared.layout.spawns do
			local s = shared.layout.spawns[i]
			if editing or s.role == role then
				markers[#markers + 1] = {
					pos = s.pos, offset = Vec(0, 6.5, 0), color = COLOR_WHITE, label = s.name,
					lineOfSightRequired = false, drawIconInView = false, maxRange = 2000,
				}
			end
		end
		if editing then
			for i = 1, #shared.layout.walls do
				local w = shared.layout.walls[i]
				markers[#markers + 1] = {
					pos = w.pos, offset = Vec(0, w.h + 0.5, 0), color = { 0.9, 0.9, 0.5, 1 }, label = w.name,
					lineOfSightRequired = false, drawIconInView = false, maxRange = 500,
				}
			end
		end
	end
	hudDrawWorldMarkers(markers)

	local myTeam = siegeTeamOf(me)
	if myTeam > 0 then
		local mates = {}
		for p in Players() do
			if p ~= me and siegeTeamOf(p) == myTeam then mates[#mates + 1] = p end
		end
		hudDrawPlayerWorldMarkers(mates, false, 9999.0, TEAM_COLORS[myTeam])
	end
end

function client.drawTopHud()
	local phase = shared.phase
	if (phase == "prep" or phase == "live") and not shared.waiting then
		hudDrawTimer(shared.timer or 0)
	end
	if phase ~= "setup" and shared.score then
		hudDrawScore2Teams(TEAM_COLORS[1], shared.score[1], TEAM_COLORS[2], shared.score[2])
	end

	local atk = shared.attackTeam or 1
	local roundText = "Round " .. (shared.round or 1) .. "/" .. (shared.maxRounds or 1)
	local line
	if shared.waiting then
		line = roundText .. "  |  Waiting for everyone to load..."
	elseif phase == "setup" then
		line = "SETUP - waiting for the host to start the match"
	elseif phase == "prep" then
		line = roundText .. "  |  PREPARATION - both teams can move and build"
	elseif phase == "live" then
		line = roundText .. "  |  " .. TEAM_NAMES[atk] .. " attacking"
	elseif phase == "roundend" then
		local r = shared.result or {}
		if r.winner == 1 or r.winner == 2 then
			line = TEAM_NAMES[r.winner] .. " wins round " .. (r.round or "") .. " - " .. (r.reason or "")
		else
			line = "Round over - " .. (r.reason or "")
		end
	end
	if line then
		UiPush()
		UiAlign("center top")
		UiTranslate(UiCenter(), 100)
		UiFont(FONT_BOLD, FONT_SIZE_20)
		local w = UiGetTextSize(line)
		UiColor(0, 0, 0, 0.55)
		UiRoundedRect(w + 30, 34, 6)
		UiTranslate(0, 5)
		UiColor(1, 1, 1, 1)
		UiText(line)
		UiPop()
	end
end

function client.drawStatus()
	local me = GetLocalPlayer()
	local info = siegePlayerInfo(me)
	if info == nil or info.team == 0 then return end
	local role = siegeRoleOf(me)
	local width = 340
	local objectives = siegeObjectives()
	local objRows = math.min(5, #objectives)
	local integ = shared.integrity
	local secCount = (integ and integ.sections) and math.min(6, #integ.sections) or 0

	UiPush()
	UiAlign("left top")
	UiTranslate(40, 170)

	local height = 150 + objRows * 50
	if secCount > 0 then height = height + 28 + secCount * 26 end
	uiDrawPanel(width, height, 10)
	UiTranslate(16, 12)

	_text(TEAM_NAMES[info.team] .. " - " .. (ROLE_NAMES[role] or ""), FONT_SIZE_22, TEAM_COLORS[info.team], FONT_BOLD)
	UiTranslate(0, 34)

	local myPos = GetPlayerTransform(me).pos
	if #objectives == 0 then
		_text("No objective set yet", FONT_SIZE_20, COLOR_RED)
		UiTranslate(0, 50)
	end
	for i = 1, objRows do
		local o = objectives[i]
		local st = siegeObjectiveState(i) or { progress = 0, state = "idle" }
		local label
		if st.done then
			label = o.name .. ": CAPTURED"
		else
			local stateText = ""
			if st.state == "capturing" then stateText = "  CAPTURING " .. math.floor((st.progress or 0) * 100) .. "%"
			elseif st.state == "contested" then stateText = "  CONTESTED"
			elseif st.state == "decaying" then stateText = "  fading " .. math.floor((st.progress or 0) * 100) .. "%" end
			label = o.name .. "  " .. siegeFormatDist(VecLength(VecSub(myPos, o.pos))) .. " " .. siegeCompass(myPos, o.pos) .. stateText
		end
		UiPush()
		_text(label, FONT_SIZE_18)
		UiPop()
		UiTranslate(0, 24)
		local barColor = { 0.35, 0.7, 1.0, 1 }
		if st.done or st.state == "capturing" then barColor = { 1.0, 0.4, 0.3, 1 }
		elseif st.state == "contested" then barColor = { 1, 1, 1, 1 } end
		UiColor(1, 1, 1, 0.15)
		UiRect(width - 32 - 70, 10)
		_col(barColor)
		UiRect((width - 32 - 70) * (st.progress or 0), 10)
		UiPush()
		UiTranslate(width - 32 - 62, -6)
		local floorText = (o.points or 1) .. " pt"
		if siegeSetting("floorbreak") > 0 and st.floor and st.floor < 100 and not st.done then
			floorText = "floor " .. st.floor .. "%"
		end
		_text(floorText, FONT_SIZE_18, { 0.8, 0.8, 0.8, 1 })
		UiPop()
		UiTranslate(0, 26)
	end

	local closest, near = _closestAttacker()
	_text("Closest attacker: " .. siegeFormatDist(closest) .. "   within 25 m: " .. near, FONT_SIZE_18)
	UiTranslate(0, 24)
	if shared.tickets and shared.tickets >= 0 and (shared.phase == "prep" or shared.phase == "live") then
		_text("Attacker reinforcements: " .. shared.tickets, FONT_SIZE_18)
	else
		_text("Attacker reinforcements: unlimited", FONT_SIZE_18)
	end
	UiTranslate(0, 24)
	_text("Kills " .. statsGetKills(me) .. "   Deaths " .. statsGetDeaths(me) .. "      [" .. string.upper(KEY_STATS) .. "] scores", FONT_SIZE_18)
	UiTranslate(0, 26)

	if secCount > 0 then
		if integ.ready then
			_text("Defences: " .. integ.total .. "%", FONT_SIZE_20, COLOR_YELLOW, FONT_BOLD)
		else
			_text("Defences: surveying...", FONT_SIZE_20, COLOR_YELLOW, FONT_BOLD)
		end
		UiTranslate(0, 28)
		for i = 1, secCount do
			local s = integ.sections[i]
			UiPush()
			_text(s.name, FONT_SIZE_18)
			UiTranslate(170, 4)
			UiColor(1, 1, 1, 0.15)
			UiRect(100, 10)
			local pct = (s.pct or 100) / 100
			UiColor(1 - pct, 0.3 + 0.6 * pct, 0.3, 1)
			UiRect(100 * pct, 10)
			UiTranslate(108, -4)
			_text(s.empty and "n/a" or (s.pct .. "%"), FONT_SIZE_18)
			UiPop()
			UiTranslate(0, 26)
		end
	end
	UiPop()
end

function client.drawBuildHud()
	local me = GetLocalPlayer()
	local info = siegePlayerInfo(me)
	if info == nil then return end
	local canBuild = siegeCanBuild(me) and info.ready and GetPlayerHealth(me) > 0
	if not canBuild then return end

	UiPush()
	UiAlign("center bottom")
	UiTranslate(UiCenter(), UiHeight() - 120)
	local piece = BUILD_PIECES[info.build or 0]
	local budget
	if shared.phase == "setup" then budget = "unlimited (setup: removed when the match starts)"
	elseif siegeSetting("budget") < 0 then budget = "unlimited"
	else budget = tostring(info.budget or 0) end
	local text
	if piece then
		text = "BUILD: " .. piece.name .. " (cost " .. piece.cost .. ")   Points: " .. budget ..
			"\n[LMB] place  [RMB] rotate  [" .. string.upper(KEY_BUILD) .. "] next piece / exit"
		if client.build.reason and client.build.reason ~= "" then
			text = text .. "\n" .. client.build.reason
		end
	else
		text = "[" .. string.upper(KEY_BUILD) .. "] Build fortifications   Points: " .. budget
	end
	UiFont(FONT_MEDIUM, FONT_SIZE_18)
	local w, h = UiGetTextSize(text)
	UiColor(0, 0, 0, 0.55)
	UiRoundedRect(w + 30, h + 16, 6)
	UiTranslate(0, -8)
	UiColor(1, 1, 1, 1)
	UiText(text)
	UiPop()
end

function client.drawNotices()
	if #client.notices == 0 then return end
	UiPush()
	UiAlign("center top")
	UiTranslate(UiCenter(), 150)
	for i = 1, #client.notices do
		local n = client.notices[i]
		UiFont(FONT_MEDIUM, FONT_SIZE_20)
		local w = UiGetTextSize(n.text)
		UiColor(0.6, 0.15, 0.1, math.min(1, n.t) * 0.85)
		UiRoundedRect(w + 30, 34, 6)
		UiTranslate(0, 5)
		UiColor(1, 1, 1, math.min(1, n.t))
		UiText(n.text)
		UiTranslate(0, 36)
	end
	UiPop()
end

------------------------------------------------------------------------------------------
-- Scoreboard / results

function client.scoreColumns()
	return { { name = "Kills", width = 80, align = "center" }, { name = "Deaths", width = 80, align = "center" } }
end

function client.scoreGroups(winnerFirst)
	local groups = {}
	local order = { 1, 2 }
	if winnerFirst and shared.result and shared.result.winner == 2 then order = { 2, 1 } end
	for _, t in ipairs(order) do
		local rows = {}
		for p in Players() do
			if siegeTeamOf(p) == t then
				rows[#rows + 1] = { player = p, columns = { statsGetKills(p), statsGetDeaths(p) } }
			end
		end
		table.sort(rows, function(a, b) return a.columns[1] > b.columns[1] end)
		local roleName = ROLE_NAMES[siegeRoleOfTeam(t)] or ""
		groups[#groups + 1] = {
			name = TEAM_NAMES[t] .. " (" .. roleName .. ")  -  " .. (shared.score and shared.score[t] or 0) .. " pts",
			color = TEAM_COLORS[t], rows = rows,
		}
	end
	local rows = {}
	for p in Players() do
		if siegeTeamOf(p) == 0 then rows[#rows + 1] = { player = p, columns = { "-", "-" } } end
	end
	if #rows > 0 then
		groups[#groups + 1] = { name = "Choosing a team", color = { 0.5, 0.5, 0.5, 1 }, rows = rows, dim = true }
	end
	return groups
end

function client.drawResults()
	local r = shared.result or {}
	local label, color = "Draw!", { 0.3, 0.3, 0.3, 1 }
	if r.winner == 1 or r.winner == 2 then
		label = TEAM_NAMES[r.winner] .. " wins the siege " .. shared.score[r.winner] .. " - " .. shared.score[3 - r.winner]
		color = TEAM_COLORS[r.winner]
	end
	-- Default continue action restarts the game mode.
	hudDrawResults(label, color, "Siege results", client.scoreColumns(), client.scoreGroups(true))
end

------------------------------------------------------------------------------------------
-- Menus

local MENU_W = 560
local MENU_H = 720

function client.drawMenu()
	local me = GetLocalPlayer()
	local info = siegePlayerInfo(me)
	if info == nil then return end
	UiMakeInteractive()
	SetBool("game.disablemap", true)

	local page = client.page
	if info.team == 0 or client.forceTeamPage then page = "team" end
	if page == "team" and info.team > 0 and not client.forceTeamPage then page = "spawn" end

	UiPush()
	UiAlign("left top")
	UiTranslate(60, math.max(40, UiMiddle() - MENU_H / 2))
	uiDrawPanel(MENU_W, MENU_H, 16)
	UiTranslate(24, 20)
	if page == "team" then client.drawTeamPage(info)
	elseif page == "rules" then client.drawRulesPage(info)
	else client.drawSpawnPage(info) end
	UiPop()

	if IsPlayerHost(me) then client.drawHostPanel() end
end

function client.drawTeamPage(info)
	local inner = MENU_W - 48
	_text("SIEGE", FONT_SIZE_36, COLOR_YELLOW, FONT_BOLD)
	UiTranslate(0, 50)
	UiPush()
	UiWordWrap(inner)
	UiFont("regular.ttf", FONT_SIZE_18)
	UiColor(1, 1, 1, 0.9)
	local _, h = UiText(client.briefing())
	UiPop()
	UiTranslate(0, math.min(h, 400) + 16)

	_text("Choose your team", FONT_SIZE_25, COLOR_WHITE, FONT_BOLD)
	UiTranslate(0, 40)
	for t = 1, 2 do
		local full = siegeJoinBlocked(t, info.team)
		local roleName = ROLE_NAMES[siegeRoleOfTeam(t)] or ""
		local label = TEAM_NAMES[t] .. " - " .. roleName .. " (" .. siegeTeamCount(t) .. ")"
		if info.team == t then label = label .. "  [current]" end
		if full then label = label .. "  FULL" end
		UiPush()
		local c = TEAM_COLORS[t]
		if uiDrawButton(label, inner, { c[1], c[2], c[3], 0.6 }, COLOR_YELLOW, true, full) then
			if info.team ~= t then ServerCall("server.chooseTeam", GetLocalPlayer(), t) end
			client.forceTeamPage = false
			client.page = "spawn"
		end
		UiPop()
		UiTranslate(0, 50)
	end
	if info.team > 0 then
		if uiDrawSecondaryButton("Back", inner) then
			client.forceTeamPage = false
			client.page = "spawn"
		end
	end
end

function client.drawRulesPage(info)
	local inner = MENU_W - 48
	_text("How Siege works", FONT_SIZE_30, COLOR_YELLOW, FONT_BOLD)
	UiTranslate(0, 50)
	UiPush()
	UiWordWrap(inner)
	UiFont("regular.ttf", FONT_SIZE_18)
	UiColor(1, 1, 1, 0.9)
	UiText(client.briefing())
	UiPop()
	UiTranslate(0, MENU_H - 130)
	if uiDrawSecondaryButton("Back", inner) then client.page = "spawn" end
end

function client.drawSpawnPage(info)
	local me = GetLocalPlayer()
	local inner = MENU_W - 48
	local role = siegeRoleOf(me)
	_text("Choose a spawn", FONT_SIZE_30, COLOR_YELLOW, FONT_BOLD)
	UiTranslate(0, 44)
	_text(TEAM_NAMES[info.team] .. " - " .. (ROLE_NAMES[role] or ""), FONT_SIZE_22, TEAM_COLORS[info.team], FONT_BOLD)
	UiTranslate(0, 36)

	local dead = GetPlayerHealth(me) <= 0
	local hint
	if shared.phase == "live" and info.ready and not dead then
		hint = "Your choice applies the next time you respawn."
	elseif dead then
		hint = "You will respawn at the selected point."
	else
		hint = "Pick where you want to start. Markers show the options in the world."
	end
	UiPush()
	UiWordWrap(inner)
	_text(hint, FONT_SIZE_18, { 0.85, 0.85, 0.85, 1 }, "regular.ttf")
	UiPop()
	UiTranslate(0, 34)

	local list = siegeSpawnsForRole(role)
	local function spawnButton(idx, label)
		local selected = info.ready and info.spawn == idx
		local color = selected and { 0.56, 0.87, 0.66, 0.5 } or { 0, 0, 0, 0.25 }
		if uiDrawButton((selected and "> " or "") .. label, inner, color, COLOR_YELLOW, true, false) then
			ServerCall("server.chooseSpawn", me, idx)
			if not dead then client.menuOpen = false end
		end
		UiTranslate(0, 46)
	end

	spawnButton(0, "Any " .. string.lower(ROLE_NAMES[role] or "") .. " spawn (random)")
	local maxRows = 7
	for i = 1, math.min(#list, maxRows) do
		local s = shared.layout.spawns[list[i]]
		local label = s.name
		local obj, d = siegeNearestObjective(s.pos)
		if obj then
			label = label .. "  -  " .. siegeFormatDist(d) .. " " .. siegeCompass(obj.pos, s.pos) .. " of " .. obj.name
		end
		spawnButton(list[i], label)
	end
	if #list == 0 then
		_text("No " .. string.lower(ROLE_NAMES[role] or "") .. " spawns placed: map spawns are used.", FONT_SIZE_18, { 0.8, 0.8, 0.8, 1 }, "regular.ttf")
		UiTranslate(0, 30)
	end

	UiPush()
	local bw = (inner - 20) / 3
	if uiDrawSecondaryButton("Change team", bw) then client.forceTeamPage = true end
	UiTranslate(bw + 10, 0)
	if uiDrawSecondaryButton("Rules", bw) then client.page = "rules" end
	UiTranslate(bw + 10, 0)
	if uiDrawSecondaryButton("Close [" .. string.upper(KEY_MENU) .. "]", bw, not info.ready) then client.menuOpen = false end
	UiPop()
end

------------------------------------------------------------------------------------------
-- Host panel

local HOST_W = 560

-- Text field. Returns the current text and marks that the player is typing,
-- so hotkeys don't fire while they type a name.
local function _nameInput(key, width)
	UiPush()
	UiColor(1, 1, 1, 0.8)
	UiImageBox("ui/common/box-outline-4.png", width, 38, 12, 12)
	UiColor(1, 1, 1, 1)
	UiFont("regular.ttf", 26)
	local text, active = UiTextInput(client.inputs[key] or "", width, 38, false)
	UiPop()
	client.inputs[key] = text
	if active then client.typing = true end
	return text
end

-- Previous / next buttons for a paged list. Returns the first and last row to draw.
local function _pager(pageKey, total, perPage, inner)
	local pages = math.max(1, math.ceil(total / perPage))
	local page = client.pages[pageKey] or 1
	if page > pages then page = pages end
	client.pages[pageKey] = page
	if pages > 1 then
		UiPush()
		if uiDrawSecondaryButton("<", 40) then client.pages[pageKey] = (page - 2) % pages + 1 end
		UiTranslate(50, 8)
		_text("Page " .. page .. " of " .. pages, FONT_SIZE_18)
		UiTranslate(inner - 90 - 50, -8)
		if uiDrawSecondaryButton(">", 40) then client.pages[pageKey] = page % pages + 1 end
		UiPop()
		UiTranslate(0, 46)
	end
	local first = (page - 1) * perPage + 1
	return first, math.min(total, first + perPage - 1)
end

function client.drawHostPanel()
	UiPush()
	UiAlign("left top")
	UiTranslate(UiWidth() - HOST_W - 60, math.max(40, UiMiddle() - MENU_H / 2))
	uiDrawPanel(HOST_W, MENU_H, 16)
	UiTranslate(20, 14)
	_text("HOST", FONT_SIZE_25, COLOR_YELLOW, FONT_BOLD)
	UiTranslate(0, 38)

	local inner = HOST_W - 40
	local tw = (inner - 20) / 3
	local tabs = {
		{ "layout", "Layout" }, { "markers", "Markers" }, { "saves", "Saves" },
		{ "weapons", "Weapons" }, { "settings", "Settings" }, { "match", "Match" },
	}
	for row = 0, 1 do
		UiPush()
		for i = 1, 3 do
			local tab = tabs[row * 3 + i]
			local active = client.hostTab == tab[1]
			local color = active and { 1, 1, 0.5, 0.35 } or { 0, 0, 0, 0.2 }
			if uiDrawButton(tab[2], tw, color, COLOR_YELLOW, true, false) then client.hostTab = tab[1] end
			UiTranslate(tw + 10, 0)
		end
		UiPop()
		UiTranslate(0, 46)
	end
	UiTranslate(0, 6)

	if client.hostTab == "layout" then client.drawHostLayout(inner)
	elseif client.hostTab == "markers" then client.drawHostMarkers(inner)
	elseif client.hostTab == "saves" then client.drawHostSaves(inner)
	elseif client.hostTab == "weapons" then client.drawHostWeapons(inner)
	elseif client.hostTab == "settings" then client.drawHostSettings(inner)
	else client.drawHostMatch(inner) end
	UiPop()
end

function client.drawHostLayout(inner)
	local me = GetLocalPlayer()
	local L = shared.layout or { objectives = {}, spawns = {}, walls = {} }
	local a, d = 0, 0
	for i = 1, #L.spawns do if L.spawns[i].role == ROLE_ATTACK then a = a + 1 else d = d + 1 end end

	_text("Objectives: " .. #L.objectives .. "   Walls: " .. #L.walls, FONT_SIZE_18, #L.objectives > 0 and COLOR_WHITE or COLOR_RED)
	UiTranslate(0, 24)
	_text("Spawns: " .. a .. " attacker, " .. d .. " defender", FONT_SIZE_18)
	UiTranslate(0, 24)
	_text("Map: " .. (shared.levelKey or "?"), FONT_SIZE_18, { 0.7, 0.7, 0.7, 1 })
	UiTranslate(0, 28)
	if shared.phase ~= "setup" then
		_text("Layout can be edited in setup (Match tab).", FONT_SIZE_18, COLOR_YELLOW)
		return
	end
	UiPush()
	UiWordWrap(inner)
	_text("Markers go at your feet, facing where you look. Close the menu with [" .. string.upper(KEY_MENU) .. "] to walk.", FONT_SIZE_18, { 0.8, 0.8, 0.8, 1 }, "regular.ttf")
	UiPop()
	UiTranslate(0, 50)

	local function btn(label, action, arg)
		if uiDrawSecondaryButton(label, inner) then ServerCall("server.layoutEdit", me, action, arg) end
		UiTranslate(0, 44)
	end
	btn("Add objective here", "objective", 0)
	btn("Add attacker spawn here", "spawn", ROLE_ATTACK)
	btn("Add defender spawn here", "spawn", ROLE_DEFEND)

	UiPush()
	local preset = WALL_PRESETS[client.wallPreset]
	if uiDrawSecondaryButton("<", 40) then client.wallPreset = (client.wallPreset - 2) % #WALL_PRESETS + 1 end
	UiTranslate(50, 0)
	if uiDrawSecondaryButton("Add wall: " .. preset.name .. " " .. preset.w .. "x" .. preset.h .. "x" .. preset.d .. "m", inner - 100) then
		ServerCall("server.layoutEdit", me, "wall", client.wallPreset)
	end
	UiTranslate(inner - 90, 0)
	if uiDrawSecondaryButton(">", 40) then client.wallPreset = client.wallPreset % #WALL_PRESETS + 1 end
	UiPop()
	UiTranslate(0, 44)

	btn("Remove nearest marker", "removenearest", 0)
	btn("Load layout from map tags", "reloadtags", 0)
	btn("Clear layout", "clear", 0)
end

function client.drawHostMarkers(inner)
	local me = GetLocalPlayer()
	local L = shared.layout or { objectives = {}, spawns = {}, walls = {} }
	if shared.phase ~= "setup" then
		_text("Markers can be edited in setup (Match tab).", FONT_SIZE_18, COLOR_YELLOW)
		return
	end

	if client.renaming then
		_text("New name:", FONT_SIZE_18)
		UiTranslate(0, 26)
		local text = _nameInput("rename", inner)
		UiTranslate(0, 46)
		UiPush()
		local bw = (inner - 10) / 2
		if uiDrawPrimaryButton("Save name", bw) then
			ServerCall("server.layoutRename", me, client.renaming.kind, client.renaming.idx, text)
			client.renaming = nil
		end
		UiTranslate(bw + 10, 0)
		if uiDrawSecondaryButton("Cancel", bw) then client.renaming = nil end
		UiPop()
		return
	end

	local rows = {}
	for i = 1, #L.objectives do rows[#rows + 1] = { kind = "objectives", idx = i, item = L.objectives[i], tag = "Obj" } end
	for i = 1, #L.spawns do
		rows[#rows + 1] = { kind = "spawns", idx = i, item = L.spawns[i], tag = L.spawns[i].role == ROLE_ATTACK and "Atk" or "Def" }
	end
	for i = 1, #L.walls do rows[#rows + 1] = { kind = "walls", idx = i, item = L.walls[i], tag = "Wall" } end
	if #rows == 0 then
		_text("Nothing placed yet (Layout tab).", FONT_SIZE_18)
		return
	end

	UiPush()
	UiWordWrap(inner)
	_text("Rename markers. Give harder objectives more points to balance them.", FONT_SIZE_18, { 0.8, 0.8, 0.8, 1 }, "regular.ttf")
	UiPop()
	UiTranslate(0, 50)

	local first, last = _pager("markers", #rows, 8, inner)
	for i = first, last do
		local r = rows[i]
		UiPush()
		UiPush()
		UiTranslate(0, 9)
		_text(r.tag .. "  " .. r.item.name, FONT_SIZE_18)
		UiPop()
		if r.kind == "objectives" then
			local pts = r.item.points or 1
			UiPush()
			UiTranslate(inner - 240, 0)
			if uiDrawSecondaryButton("<", 36) then ServerCall("server.layoutObjectivePoints", me, r.idx, pts - 1) end
			UiTranslate(42, 9)
			_text(pts .. " pt", FONT_SIZE_18, COLOR_YELLOW)
			UiTranslate(48, -9)
			if uiDrawSecondaryButton(">", 36) then ServerCall("server.layoutObjectivePoints", me, r.idx, pts + 1) end
			UiPop()
		end
		UiTranslate(inner - 100, 0)
		if uiDrawSecondaryButton("Rename", 100) then
			client.renaming = { kind = r.kind, idx = r.idx }
			client.inputs.rename = r.item.name
		end
		UiPop()
		UiTranslate(0, 46)
	end
end

function client.drawHostSaves(inner)
	local me = GetLocalPlayer()
	if shared.phase ~= "setup" then
		_text("Layouts can be saved and loaded in setup (Match tab).", FONT_SIZE_18, COLOR_YELLOW)
		return
	end
	UiPush()
	UiWordWrap(inner)
	_text("The current layout saves itself. Use these slots to keep named versions for this map.", FONT_SIZE_18, { 0.8, 0.8, 0.8, 1 }, "regular.ttf")
	UiPop()
	UiTranslate(0, 50)
	_text("Name for a new save:", FONT_SIZE_18)
	UiTranslate(0, 26)
	local text = _nameInput("slot", inner)
	UiTranslate(0, 50)

	local slots = shared.layoutSlots or {}
	for i = 1, LAYOUT_SLOTS do
		local s = slots[i] or { used = false, name = "" }
		UiPush()
		UiPush()
		UiTranslate(0, 9)
		_text(i .. ". " .. (s.used and s.name or "(empty)"), FONT_SIZE_18, s.used and COLOR_WHITE or { 0.6, 0.6, 0.6, 1 })
		UiPop()
		UiTranslate(inner - 216, 0)
		if uiDrawSecondaryButton("Load", 70, not s.used) then ServerCall("server.slotLoad", me, i) end
		UiTranslate(76, 0)
		if uiDrawSecondaryButton("Save", 70) then
			local name = text
			if name == "" then name = s.name end
			ServerCall("server.slotSave", me, i, name)
			client.inputs.slot = ""
		end
		UiTranslate(76, 0)
		if uiDrawSecondaryButton("X", 64, not s.used) then ServerCall("server.slotDelete", me, i) end
		UiPop()
		UiTranslate(0, 46)
	end
end

-- Slider row used by the Settings and Cannon balls tabs. Returns the raw value to show, and
-- the raw value to send to the server when the player lets go (otherwise nil).
-- The dragged value stays on screen for a moment so the slider doesn't jump back.
local function _slider(id, serverRaw, minRaw, maxRaw, width, editable)
	local drag = client.sliderDrag[id]
	-- Shortly after release the server's copy has arrived, so it takes over again.
	if drag and drag.released and GetTime() - drag.releasedAt > 1.0 then
		client.sliderDrag[id] = nil
		drag = nil
	end
	local raw = drag and drag.raw or serverRaw
	local range = maxRaw - minRaw

	UiPush()
	UiColor(1, 1, 1, 0.2)
	UiRect(width, 8)
	UiTranslate(0, -6)
	UiColor(1, 1, 1, 1)
	UiSliderThumbSize(10, 20)
	if not editable then UiDisableInput() end
	local px = (raw - minRaw) / range * width
	local newPx, done = UiSlider("ui/common/dot.png", "x", px, 0, width)
	UiPop()

	if not editable or math.abs(newPx - px) < 0.01 and not done then return raw, nil end
	local newRaw = minRaw + newPx / width * range
	client.sliderDrag[id] = { raw = newRaw, released = done, releasedAt = GetTime() }
	if done then return newRaw, newRaw end
	return newRaw, nil
end

local POWER_SLIDER_W = 100

-- Fine sliders give the left half to 1-100% and the right half to 100-500%,
-- so low values are easy to pick. Positions run 0 to 100.
local function _finePowerToPos(pct)
	if pct <= 100 then return (pct - 1) / 99 * 50 end
	return 50 + (pct - 100) / (CANNON_POWER_MAX - 100) * 50
end

local function _finePosToPower(pos)
	local pct
	if pos <= 50 then pct = 1 + pos / 50 * 99 else pct = 100 + (pos - 50) / 50 * (CANNON_POWER_MAX - 100) end
	if pct < 30 then return math.floor(pct + 0.5) end
	return math.floor(pct / 5 + 0.5) * 5
end

local function _onOffButton(on, disabled)
	local color = on and { 0.56, 0.87, 0.66, 0.5 } or { 0, 0, 0, 0.25 }
	return uiDrawButton(on and "ON" or "OFF", 70, color, COLOR_YELLOW, true, disabled)
end

function client.drawHostWeapons(inner)
	local editable = shared.phase == "setup"
	local rules = shared.toolRules or {}
	local hasCannon = rules[CANNON_TOOL_ID] ~= nil

	if not editable then
		_text("Weapons are locked during a match.", FONT_SIZE_18, COLOR_YELLOW)
		UiTranslate(0, 26)
	end

	if hasCannon then
		UiPush()
		local bw = (inner - 10) / 2
		local views = { { "tools", "Tools" }, { "balls", "Cannon balls" } }
		for i = 1, 2 do
			local active = client.weaponsView == views[i][1]
			local color = active and { 1, 1, 0.5, 0.35 } or { 0, 0, 0, 0.2 }
			if uiDrawButton(views[i][2], bw, color, COLOR_YELLOW, true, false) then client.weaponsView = views[i][1] end
			UiTranslate(bw + 10, 0)
		end
		UiPop()
		UiTranslate(0, 48)
	end

	if hasCannon and client.weaponsView == "balls" then
		client.drawHostBalls(inner, editable)
	else
		client.drawHostTools(inner, editable)
	end
end

function client.drawHostTools(inner, editable)
	local me = GetLocalPlayer()
	local tools = shared.toolList or {}
	local rules = shared.toolRules or {}
	local first, last = _pager("weapons", #tools, 10, inner)
	for i = first, last do
		local t = tools[i]
		-- Built-in names are translation keys ("loc@..."). Translate first: adding text to a key blanks it.
		local label = t.name
		if string.sub(label, 1, 4) == "loc@" then
			label = GetTranslatedStringByKey(string.sub(label, 5), t.id)
		end
		if label == nil or label == "" then label = t.id end
		if EXPLOSIVE_TOOLS[t.id] then label = label .. " (explosive)" elseif t.custom then label = label .. " (mod)" end
		UiPush()
		UiPush()
		UiTranslate(0, 9)
		_text(label, FONT_SIZE_18)
		UiPop()
		UiTranslate(inner - 70, 0)
		if _onOffButton(rules[t.id], not editable) then
			ServerCall("server.setToolRule", me, t.id, not rules[t.id])
		end
		UiPop()
		UiTranslate(0, 44)
	end
end

function client.drawHostBalls(inner, editable)
	local me = GetLocalPlayer()
	if not shared.cannonPatched then
		UiPush()
		UiWordWrap(inner)
		_text("These only work with THE CANNON (Siege). The original cannon ignores them.", FONT_SIZE_18, COLOR_RED, "regular.ttf")
		UiPop()
		UiTranslate(0, 50)
	else
		_text("Drag to set each ball's power. 100% is normal damage.", FONT_SIZE_18, { 0.8, 0.8, 0.8, 1 }, "regular.ttf")
		UiTranslate(0, 28)
	end
	local rounds = shared.cannonRounds or {}
	local trebs = shared.trebRounds or {}
	local powers = shared.cannonPower or {}
	UiPush()
	UiTranslate(inner - 165, 0)
	_text("Trebuchet", FONT_SIZE_18, { 0.8, 0.8, 0.8, 1 }, "regular.ttf")
	UiTranslate(90, 0)
	_text("Cannon", FONT_SIZE_18, { 0.8, 0.8, 0.8, 1 }, "regular.ttf")
	UiPop()
	UiTranslate(0, 26)
	for i = 1, #CANNON_ROUNDS do
		local r = CANNON_ROUNDS[i]
		UiPush()
		UiPush()
		UiTranslate(0, 9)
		_text(r.label, FONT_SIZE_18)
		UiPop()

		UiPush()
		UiTranslate(150, 16)
		local pct
		if r.finePower then
			local rawPos, sendPos = _slider("ball_" .. r.id, _finePowerToPos(powers[r.id] or 100), 0, 100, POWER_SLIDER_W, editable)
			pct = _finePosToPower(rawPos)
			if sendPos then ServerCall("server.setCannonPower", me, r.id, pct) end
		else
			local rawPct, sendPct = _slider("ball_" .. r.id, powers[r.id] or 100, CANNON_POWER_MIN, CANNON_POWER_MAX, POWER_SLIDER_W, editable)
			pct = math.floor(rawPct / 5 + 0.5) * 5
			if sendPct then ServerCall("server.setCannonPower", me, r.id, pct) end
		end
		UiPop()

		UiPush()
		UiTranslate(150 + POWER_SLIDER_W + 10, 9)
		_text(pct .. "%", FONT_SIZE_18, COLOR_YELLOW)
		UiPop()

		UiTranslate(inner - 160, 0)
		if _onOffButton(trebs[r.id], not editable) then
			ServerCall("server.setTrebRound", me, r.id, not trebs[r.id])
		end
		UiTranslate(90, 0)
		if _onOffButton(rounds[r.id], not editable) then
			ServerCall("server.setCannonRound", me, r.id, not rounds[r.id])
		end
		UiPop()
		UiTranslate(0, 44)
	end
end

function client.drawHostSettings(inner)
	local me = GetLocalPlayer()
	local editable = shared.phase == "setup"
	if not editable then
		_text("Settings are locked during a match.", FONT_SIZE_18, COLOR_YELLOW)
		UiTranslate(0, 26)
	end
	local first, last = _pager("settings", #SETTINGS, 9, inner)
	for i = first, last do
		local def = SETTINGS[i]
		UiPush()
		UiTranslate(0, 8)
		_text(def.label, FONT_SIZE_18)
		UiPop()
		if def.slider then
			local s = def.slider
			local serverRaw = siegeSliderRaw(def, siegeSetting(def.key))
			local sliderMin = s.min
			UiPush()
			UiTranslate(inner - 250, 16)
			local raw, send = _slider("setting_" .. def.key, serverRaw, sliderMin, s.max, 130, editable)
			if send then ServerCall("server.setSliderSetting", me, def.key, send) end
			UiPop()
			UiPush()
			UiTranslate(inner - 110, 8)
			_text(siegeFormatSlider(def, siegeSliderValue(def, raw)), FONT_SIZE_18, COLOR_YELLOW)
			UiPop()
		else
			local idx = siegeSettingIndex(def.key)
			UiPush()
			UiTranslate(inner - 250, 0)
			if uiDrawSecondaryButton("<", 36, not editable) then ServerCall("server.setSetting", me, def.key, idx - 1) end
			UiTranslate(130, 8)
			UiPush()
			UiAlign("center top")
			_text(def.options[idx][1], FONT_SIZE_18, COLOR_YELLOW)
			UiPop()
			UiTranslate(84, -8)
			if uiDrawSecondaryButton(">", 36, not editable) then ServerCall("server.setSetting", me, def.key, idx + 1) end
			UiPop()
		end
		if UiIsMouseInRect(inner, 40) then client.settingInfo = def.info end
		UiTranslate(0, 42)
	end
	if client.settingInfo then
		UiTranslate(0, 6)
		UiPush()
		UiWordWrap(inner)
		_text(client.settingInfo, FONT_SIZE_18, { 0.8, 0.8, 0.8, 1 }, "regular.ttf")
		UiPop()
	end
end

function client.drawHostMatch(inner)
	local me = GetLocalPlayer()
	if shared.phase == "setup" then
		local ready = #siegeObjectives() > 0
		UiPush()
		UiWordWrap(inner)
		_text(ready and "Starting reloads the map, so any damage or test pieces from setup are removed. Late joiners can still pick a team."
			or "Add an objective in the Layout tab before starting.", FONT_SIZE_18, ready and COLOR_WHITE or COLOR_RED, "regular.ttf")
		UiPop()
		UiTranslate(0, 76)
		_text(TEAM_NAMES[1] .. ": " .. siegeTeamCount(1) .. "   " .. TEAM_NAMES[2] .. ": " .. siegeTeamCount(2) .. "   (" .. TEAM_NAMES[1] .. " attacks first)", FONT_SIZE_18)
		UiTranslate(0, 40)
		if uiDrawPrimaryButton("START MATCH", inner, not ready) then
			ServerCall("server.hostCommand", me, "start")
			client.menuOpen = false
		end
	else
		_text("Phase: " .. shared.phase .. "   Round " .. (shared.round or 1) .. "/" .. (shared.maxRounds or 1), FONT_SIZE_18)
		UiTranslate(0, 40)
		if uiDrawSecondaryButton("End round now (no points)", inner, not (shared.phase == "prep" or shared.phase == "live")) then
			ServerCall("server.hostCommand", me, "endround")
		end
		UiTranslate(0, 50)
		if uiDrawSecondaryButton("Back to setup (reloads the map)", inner) then
			ServerCall("server.hostCommand", me, "tosetup")
		end
	end
end
