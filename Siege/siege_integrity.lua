-- Siege: wall integrity tracker (server).
--
-- Each wall section is a box placed by the host. When a match starts the server samples a grid of
-- points inside the box and remembers which ones are inside static geometry. It then keeps
-- re-checking those points; integrity = points still solid / points solid at the start.
-- Detached rubble becomes dynamic, so it does not count. Fortification pieces that plug a hole
-- count as repair. The work is spread over frames (QUERIES_PER_TICK).

INTEGRITY_QUERIES_PER_TICK = 80
INTEGRITY_MAX_POINTS = 800       -- per section; spacing grows for big boxes
INTEGRITY_PUBLISH_INTERVAL = 1.0

server.integrity = { sections = {}, active = false, publishTimer = 0 }

function integrityReset()
	server.integrity = { sections = {}, active = false, publishTimer = 0 }
	shared.integrity = { ready = false, total = 100, sections = {} }
end

-- Start (or restart) baseline sampling for the current layout.
function integrityBegin()
	integrityReset()
	local walls = server.layout and server.layout.walls or {}
	for i = 1, #walls do
		local w = walls[i]
		local vol = w.w * w.h * w.d
		local spacing = math.max(0.5, (vol / INTEGRITY_MAX_POINTS) ^ (1 / 3))
		local nx = math.max(1, math.floor(w.w / spacing))
		local ny = math.max(1, math.floor(w.h / spacing))
		local nz = math.max(1, math.floor(w.d / spacing))
		local t = siegeYawTransform(w.pos, w.yaw)
		local pts = {}
		for ix = 0, nx - 1 do
			for iy = 0, ny - 1 do
				for iz = 0, nz - 1 do
					local lx = -w.w * 0.5 + (ix + 0.5) * (w.w / nx)
					local ly = (iy + 0.5) * (w.h / ny)
					local lz = -w.d * 0.5 + (iz + 0.5) * (w.d / nz)
					pts[#pts + 1] = TransformToParentPoint(t, Vec(lx, ly, lz))
				end
			end
		end
		server.integrity.sections[i] = {
			name = w.name,
			candidates = pts, cursor = 1,         -- baseline pass
			solid = {}, alive = {}, aliveCount = 0, -- tracked points
			checkCursor = 1,
			probe = math.min(0.35, spacing * 0.5),
			baselineDone = false,
		}
	end
	server.integrity.active = #walls > 0
	shared.integrity = { ready = false, total = 100, sections = {} }
end

local function _isSolid(p, r)
	QueryRequire("physical static")
	local hit = QueryClosestPoint(p, r)
	return hit
end

function integrityTick(dt)
	local I = server.integrity
	if not I.active then return end
	local budget = INTEGRITY_QUERIES_PER_TICK

	-- Baseline sampling first, section by section.
	local allBaseline = true
	for i = 1, #I.sections do
		local s = I.sections[i]
		if not s.baselineDone then
			allBaseline = false
			while budget > 0 and s.cursor <= #s.candidates do
				local p = s.candidates[s.cursor]
				if _isSolid(p, s.probe) then
					s.solid[#s.solid + 1] = p
					s.alive[#s.solid] = true
					s.aliveCount = s.aliveCount + 1
				end
				s.cursor = s.cursor + 1
				budget = budget - 1
			end
			if s.cursor > #s.candidates then
				s.baselineDone = true
				s.candidates = nil
			end
			if budget <= 0 then break end
		end
	end

	-- Re-check tracked points round-robin.
	if allBaseline then
		local secCount = #I.sections
		local per = math.max(10, math.floor(budget / math.max(1, secCount)))
		for i = 1, secCount do
			local s = I.sections[i]
			local n = #s.solid
			for _ = 1, math.min(per, n) do
				local idx = s.checkCursor
				local now = _isSolid(s.solid[idx], s.probe)
				if now ~= s.alive[idx] then
					s.alive[idx] = now
					s.aliveCount = s.aliveCount + (now and 1 or -1)
				end
				s.checkCursor = idx + 1
				if s.checkCursor > n then s.checkCursor = 1 end
			end
		end
	end

	I.publishTimer = I.publishTimer - dt
	if I.publishTimer <= 0 then
		I.publishTimer = INTEGRITY_PUBLISH_INTERVAL
		integrityPublish(allBaseline)
	end
end

function integrityPublish(ready)
	local I = server.integrity
	local secs = {}
	local sumBase, sumAlive = 0, 0
	for i = 1, #I.sections do
		local s = I.sections[i]
		local base = #s.solid
		local pct = 100
		if base > 0 then pct = math.floor(100 * s.aliveCount / base + 0.5) end
		secs[i] = { name = s.name, pct = pct, empty = (base == 0 and s.baselineDone) }
		sumBase = sumBase + base
		sumAlive = sumAlive + s.aliveCount
	end
	local total = 100
	if sumBase > 0 then total = math.floor(100 * sumAlive / sumBase + 0.5) end

	-- Only touch the shared table when something changed (saves bandwidth).
	local old = shared.integrity
	local changed = old == nil or old.ready ~= ready or old.total ~= total or #old.sections ~= #secs
	if not changed then
		for i = 1, #secs do
			if old.sections[i].pct ~= secs[i].pct then changed = true break end
		end
	end
	if changed then
		shared.integrity = { ready = ready, total = total, sections = secs }
	end
end
