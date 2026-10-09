-- Layout solver for small panels:
--   luajit scripts/solve.lua <spec.lua> [seed] [iterations] [restarts]
--
-- A spec describes a circuit as parts and what each must be powered by;
-- the solver searches (simulated annealing) for an 8x8 drawing that wires
-- up exactly that and prints it in sim/art.lua format. It judges layouts
-- with its own fast copy of the wiring rules in sim/static.lua, so check
-- the result with scripts/cell.lua and tests. Signals are names: a lane
-- (an edge port) brings its `input` signal, a torch drives its `out`.
--
-- spec = {
--   lanes   = { { port = "W2", input = "WS", want = { "WS" } }, ... },
--             -- want: the signals on the wire at that port (an output port
--             -- has no input); lanes with the same `link` must be one wire
--             -- (a signal passing through). Every other edge cell must stay empty.
--   blocks  = { name = { signals... } },   -- exactly what powers each block
--   bulbs   = { name = { signals... } },
--   lamps   = { name = { signals... } },
--   torches = { name = { on = block or bulb name, out = signal } },
--   fixed   = { ["x,y"] = char },          -- optional pinned cells (. + q)
--   start   = { rows = { drawing }, parts = { name = "x,y" } },
--             -- optional starting layout (e.g. a solved cell to adapt);
--             -- parts missing from it are placed at random
-- }
-- Run from the repo root.

local bit = require("bit")
local band, bor, bnot = bit.band, bit.bor, bit.bnot

local SIZE = 8
local N_CELLS = SIZE * SIZE
local DX = { [0] = 0, 1, 0, -1 }
local DY = { [0] = -1, 0, 1, 0 }
local SIDE = { N = 0, E = 1, S = 2, W = 3 }
local TORCH_CH = { [0] = "^", ">", "v", "<" }

local spec = dofile(arg[1])
local seed = tonumber(arg[2]) or os.time()
local ITERS = tonumber(arg[3]) or 3000000
local RESTARTS = tonumber(arg[4]) or 1
-- arg[5]: an earlier result to start from (its drawing and part list).
if arg[5] then
	local lines = {}
	for line in io.lines(arg[5]) do lines[#lines + 1] = line end
	local rows, parts = {}, {}
	for i = 2, 9 do rows[#rows + 1] = lines[i] end
	for name, at in lines[10]:gmatch("(%w+)=(%d+,%d+)") do parts[name] = at end
	spec.start = { rows = rows, parts = parts, warm = true }
end
math.randomseed(seed)

-- Cell k = (y - 1) * 8 + x, x and y in 1..8.
local function K(x, y) return (y - 1) * SIZE + x end
local function XY(k) return (k - 1) % SIZE + 1, math.floor((k - 1) / SIZE) + 1 end
local NB = {} -- NB[k][d] = neighbour cell or nil (off the grid: a port)
for k = 1, N_CELLS do
	local x, y = XY(k)
	NB[k] = {}
	for d = 0, 3 do
		local nx, ny = x + DX[d], y + DY[d]
		if nx >= 1 and nx <= SIZE and ny >= 1 and ny <= SIZE then NB[k][d] = K(nx, ny) end
	end
end
local function is_edge(k)
	local x, y = XY(k)
	return x == 1 or y == 1 or x == SIZE or y == SIZE
end

-- Signals as bits.
local sig_bit, sig_names = {}, {}
local function S(name)
	if not sig_bit[name] then
		sig_names[#sig_names + 1] = name
		sig_bit[name] = bit.lshift(1, #sig_names - 1)
	end
	return sig_bit[name]
end
local function mask(list)
	local m = 0
	for _, s in ipairs(list or {}) do m = bor(m, S(s)) end
	return m
end
local function popcount(m)
	local n = 0
	while m ~= 0 do
		m = band(m, m - 1)
		n = n + 1
	end
	return n
end

-- Lanes: lane_side[k][d] = lane for the port off cell k on side d.
local lanes, lane_side = {}, {}
for _, l in ipairs(spec.lanes) do
	local side, b = l.port:match("^(%a)(%d)$")
	local d, q = SIDE[side], tonumber(b)
	local x, y
	if d == 0 then x, y = q, 1 elseif d == 1 then x, y = SIZE, q elseif d == 2 then x, y = q, SIZE else x, y = 1, q end
	local k = K(x, y)
	local lane = { cell = k, side = d, input = l.input and S(l.input) or 0, want = mask(l.want), name = l.port,
		link = l.link }
	lanes[#lanes + 1] = lane
	lane_side[k] = lane_side[k] or {}
	lane_side[k][d] = lane
end

-- Roles: parts, each placed once.
local roles, role_of_name = {}, {}
local function add_role(name, kind, need, extra)
	local r = { name = name, kind = kind, need = mask(need) }
	for key, v in pairs(extra or {}) do r[key] = v end
	roles[#roles + 1] = r
	role_of_name[name] = r
end
local function sorted_pairs(t)
	local keys = {}
	for key in pairs(t or {}) do keys[#keys + 1] = key end
	table.sort(keys)
	local i = 0
	return function()
		i = i + 1
		if keys[i] then return keys[i], t[keys[i]] end
	end
end
for name, need in sorted_pairs(spec.blocks) do add_role(name, "block", need) end
for name, need in sorted_pairs(spec.bulbs) do add_role(name, "bulb", need) end
for name, need in sorted_pairs(spec.lamps) do add_role(name, "lamp", need) end
for name, t in sorted_pairs(spec.torches) do add_role(name, "torch", nil, { on = t.on, out = S(t.out) }) end
for _, r in ipairs(roles) do
	if r.kind == "torch" then r.base = assert(role_of_name[r.on], "no part " .. r.on) end
end

-- State. kind[k]: 0 empty, 1 dust, 2 quartz, 3 part (role[k]).
local kind, role, attach, where = {}, {}, {}, {}
local fixed, free = {}, {}
for key, ch in pairs(spec.fixed or {}) do
	local x, y = key:match("(%d+),(%d+)")
	local k = K(tonumber(x), tonumber(y))
	fixed[k] = true
	kind[k] = ch == "+" and 1 or ch == "q" and 2 or 0
end
for k = 1, N_CELLS do
	if not fixed[k] then free[#free + 1] = k end
	kind[k] = kind[k] or 0
end

local CH_ATTACH = { ["^"] = 0, [">"] = 1, ["v"] = 2, ["<"] = 3 }
local function place_randomly()
	for _, k in ipairs(free) do kind[k], role[k], attach[k] = 0, nil, nil end
	local placed = {}
	if spec.start then
		for y, row in ipairs(spec.start.rows) do
			row = row:gsub(" ", "")
			for x = 1, SIZE do
				local ch, k = row:sub(x, x), K(x, y)
				if not fixed[k] then
					if ch == "+" then kind[k] = 1 elseif ch == "q" then kind[k] = 2 end
				end
			end
		end
		for name, at in pairs(spec.start.parts or {}) do
			local r = role_of_name[name]
			if r then
				local x, y = at:match("(%d+),(%d+)")
				x, y = tonumber(x), tonumber(y)
				local k = K(x, y)
				kind[k], role[k], where[r] = 3, r, k
				if r.kind == "torch" then
					attach[k] = CH_ATTACH[spec.start.rows[y]:gsub(" ", ""):sub(x, x)] or 0
				end
				placed[r] = true
			end
		end
	end
	for _, r in ipairs(roles) do
		if not placed[r] then
			local k
			repeat k = free[math.random(#free)] until kind[k] == 0 and not is_edge(k)
			kind[k], role[k], where[r] = 3, r, k
			if r.kind == "torch" then attach[k] = math.random(0, 3) end
		end
	end
end

-- Evaluation.
local parent, netmask, wire_list = {}, {}, {}
local function find(a)
	while parent[a] ~= a do
		parent[a] = parent[parent[a]]
		a = parent[a]
	end
	return a
end
local function union(a, b)
	a, b = find(a), find(b)
	if a ~= b then parent[a] = b end
end

local W_EXTRA, W_MISS, W_DIST, W_EDGE, W_BASE, W_WIRE = 3, 2, 0.3, 4, 3, 0.002

local have = {} -- consumer cell -> signal mask
local function evaluate()
	local nw = 0
	for k = 1, N_CELLS do
		local t = kind[k]
		if t == 1 or t == 2 then
			parent[k] = k
			nw = nw + 1
			wire_list[nw] = k
		end
	end
	for i = 1, nw do
		local k = wire_list[i]
		local e, s = NB[k][1], NB[k][2]
		if e and (kind[e] == 1 or kind[e] == 2) then union(k, e) end
		if s and (kind[s] == 1 or kind[s] == 2) then union(k, s) end
	end
	-- Quartz rook links.
	for a = 1, SIZE do
		local fr, fc
		for b = 1, SIZE do
			local r, c = K(b, a), K(a, b)
			if kind[r] == 2 then if fr then union(fr, r) else fr = r end end
			if kind[c] == 2 then if fc then union(fc, c) else fc = c end end
		end
	end
	local cost = 0
	for i = 1, nw do netmask[wire_list[i]] = 0 end
	-- Pins into wires, and edge use.
	for k = 1, N_CELLS do
		if kind[k] ~= 0 and is_edge(k) then
			local ls = lane_side[k]
			local ok = false
			for d = 0, 3 do
				if not NB[k][d] then
					local l = ls and ls[d]
					if l and (kind[k] == 1 or kind[k] == 2) then
						ok = true
						local root = find(k)
						netmask[root] = bor(netmask[root], l.input)
					else
						ok = false
						break
					end
				end
			end
			if not ok then cost = cost + W_EDGE end
		end
	end
	-- Torch outputs.
	for _, r in ipairs(roles) do
		local k = where[r]
		if r.kind == "torch" then
			local a = attach[k]
			local b = NB[k][a]
			if not (b and role[b] == r.base) then cost = cost + W_BASE end
			for d = 0, 3 do
				if d ~= a then
					local j = NB[k][d]
					if j and (kind[j] == 1 or kind[j] == 2) then
						local root = find(j)
						netmask[root] = bor(netmask[root], r.out)
					end
				end
			end
		end
	end
	-- Consumers.
	for _, r in ipairs(roles) do
		if r.kind ~= "torch" then
			local k = where[r]
			local m = 0
			for d = 0, 3 do
				local j = NB[k][d]
				if j then
					local t = kind[j]
					if t == 1 or t == 2 then
						m = bor(m, netmask[find(j)])
					elseif t == 3 and role[j].kind == "torch" and attach[j] ~= (d + 2) % 4 then
						m = bor(m, role[j].out)
					end
				end
			end
			have[k] = m
			cost = cost + W_EXTRA * popcount(band(m, bnot(r.need)))
			local miss = band(r.need, bnot(m))
			if miss ~= 0 then cost = cost + W_MISS * popcount(miss) end
		end
	end
	for _, l in ipairs(lanes) do
		local t = kind[l.cell]
		if t == 1 or t == 2 then
			local m = netmask[find(l.cell)]
			cost = cost + W_EXTRA * popcount(band(m, bnot(l.want))) + W_MISS * popcount(band(l.want, bnot(m)))
		else
			cost = cost + W_EDGE
		end
	end
	local first_of = {}
	for _, l in ipairs(lanes) do
		if l.link and (kind[l.cell] == 1 or kind[l.cell] == 2) then
			local f = first_of[l.link]
			if not f then
				first_of[l.link] = l.cell
			elseif find(f) ~= find(l.cell) then
				cost = cost + W_EDGE
			end
		end
	end
	local violations = cost
	-- Gradient: missing signals pull toward their nearest source.
	if violations > 0 then
		local function dist_to(k, m)
			local x, y = XY(k)
			local best = 99
			for i = 1, nw do
				local j = wire_list[i]
				if band(netmask[find(j)], m) ~= 0 then
					local jx, jy = XY(j)
					local dd = math.abs(jx - x) + math.abs(jy - y)
					if dd < best then best = dd end
				end
			end
			for _, r in ipairs(roles) do
				if r.kind == "torch" and band(r.out, m) ~= 0 then
					local jx, jy = XY(where[r])
					local dd = math.abs(jx - x) + math.abs(jy - y)
					if dd < best then best = dd end
				end
			end
			return best == 99 and 8 or best
		end
		for _, r in ipairs(roles) do
			if r.kind ~= "torch" then
				local miss = band(r.need, bnot(have[where[r]]))
				local s = 1
				while miss ~= 0 do
					if band(miss, s) ~= 0 then
						cost = cost + W_DIST * dist_to(where[r], s)
						miss = band(miss, bnot(s))
					end
					s = bit.lshift(s, 1)
				end
			else
				local b = NB[where[r]][attach[where[r]]]
				if not (b and role[b] == r.base) then
					local x, y = XY(where[r])
					local bx, by = XY(where[r.base])
					cost = cost + W_DIST * (math.abs(bx - x) + math.abs(by - y))
				end
			end
		end
	end
	return cost + nw * W_WIRE, violations
end

-- Moves (undoable).
local undo = {}
local function save(k)
	undo[#undo + 1] = { k, kind[k], role[k], attach[k] }
end
local function put(k, t, r, a)
	kind[k], role[k], attach[k] = t, r, a
	if r then where[r] = k end
end
local function rollback()
	for i = #undo, 1, -1 do
		local u = undo[i]
		put(u[1], u[2], u[3], u[4])
	end
end
-- Route: lay a dust path through empty cells from a part missing a signal
-- to something carrying it. Needs a fresh evaluation of the current state.
local function route()
	evaluate()
	local wants = {}
	for _, r in ipairs(roles) do
		if r.kind ~= "torch" then
			local miss = band(r.need, bnot(have[where[r]]))
			local s = 1
			while miss ~= 0 do
				if band(miss, s) ~= 0 then
					wants[#wants + 1] = { where[r], s }
					miss = band(miss, bnot(s))
				end
				s = bit.lshift(s, 1)
			end
		end
	end
	if #wants == 0 then return false end
	local w = wants[math.random(#wants)]
	local from, s = w[1], w[2]
	-- Goal: an empty cell touching a wire that carries s, or facing a
	-- torch that drives s (on one of its output sides).
	local function goal(k)
		for d = 0, 3 do
			local j = NB[k][d]
			if j then
				local t = kind[j]
				if (t == 1 or t == 2) and band(netmask[find(j)], s) ~= 0 then return true end
				if t == 3 and role[j].kind == "torch" and role[j].out == s and attach[j] ~= (d + 2) % 4 then
					return true
				end
			end
		end
		return false
	end
	local prev, queue, head = {}, {}, 1
	for d = 0, 3 do
		local j = NB[from][d]
		if j and kind[j] == 0 and not fixed[j] and not is_edge(j) and not prev[j] then
			prev[j] = from
			queue[#queue + 1] = j
		end
	end
	local found
	while head <= #queue do
		local k = queue[head]
		head = head + 1
		if goal(k) then
			found = k
			break
		end
		for d = 0, 3 do
			local j = NB[k][d]
			if j and kind[j] == 0 and not fixed[j] and not is_edge(j) and not prev[j] then
				prev[j] = k
				queue[#queue + 1] = j
			end
		end
	end
	if not found then return false end
	local k = found
	while k ~= from do
		save(k)
		put(k, 1)
		k = prev[k]
	end
	return true
end

local function move()
	for i = #undo, 1, -1 do undo[i] = nil end
	local m = math.random()
	if m < 0.04 then
		return route()
	elseif m < 0.45 then
		local k = free[math.random(#free)]
		if kind[k] == 3 then return false end
		save(k)
		local r = math.random()
		put(k, r < 0.4 and 0 or r < 0.85 and 1 or 2)
	elseif m < 0.75 then
		local r = roles[math.random(#roles)]
		local a, b = where[r], free[math.random(#free)]
		if a == b then return false end
		save(a)
		save(b)
		local ta, ra, aa = kind[a], role[a], attach[a]
		put(a, kind[b], role[b], attach[b])
		put(b, ta, ra, aa)
		if r.kind == "torch" and math.random() < 0.5 then attach[b] = math.random(0, 3) end
	elseif m < 0.87 then
		local r = roles[math.random(#roles)]
		if r.kind ~= "torch" then return false end
		save(where[r])
		attach[where[r]] = math.random(0, 3)
	else
		local a, b = free[math.random(#free)], free[math.random(#free)]
		if a == b then return false end
		save(a)
		save(b)
		local ta, ra, aa = kind[a], role[a], attach[a]
		put(a, kind[b], role[b], attach[b])
		put(b, ta, ra, aa)
	end
	return true
end

local function draw()
	local rows, names = {}, {}
	for y = 1, SIZE do
		local row = {}
		for x = 1, SIZE do
			local k = K(x, y)
			local t, ch = kind[k], "."
			if t == 1 then ch = "+"
			elseif t == 2 then ch = "q"
			elseif t == 3 then
				local r = role[k]
				if r.kind == "torch" then ch = TORCH_CH[attach[k]]
				elseif r.kind == "block" then ch = "B"
				elseif r.kind == "bulb" then ch = "U"
				else ch = "L" end
				names[#names + 1] = ("%s=%d,%d"):format(r.name, x, y)
			end
			row[x] = ch
		end
		rows[y] = table.concat(row, " ")
	end
	table.sort(names)
	return rows, names
end

local overall
for restart = 1, RESTARTS do
	place_randomly()
	local cur, curv = evaluate()
	local best, bestv = cur, curv
	local bestrows, bestnames = draw()
	local T0, T1 = spec.start and (spec.start.warm and 1.2 or 0.6) or 3.0, 0.03
	for it = 1, ITERS do
		local T = T0 * (T1 / T0) ^ (it / ITERS)
		if move() then
			local new, newv = evaluate()
			if new <= cur or math.random() < math.exp((cur - new) / T) then
				cur, curv = new, newv
				if new < best then
					best, bestv = new, newv
					bestrows, bestnames = draw()
				end
			else
				rollback()
			end
		end
	end
	io.stderr:write(("restart %d: violations %.1f, score %.3f\n"):format(restart, bestv, best))
	if not overall or best < overall.best then
		overall = { best = best, v = bestv, rows = bestrows, names = bestnames }
	end
	if overall.v == 0 and restart >= 1 and RESTARTS > 1 and overall.best < 0.06 then break end
end

print(("-- seed %d: %s, score %.3f"):format(seed, overall.v == 0 and "solved" or ("%.1f violations"):format(overall.v), overall.best))
for _, row in ipairs(overall.rows) do print(row) end
print("-- " .. table.concat(overall.names, " "))
