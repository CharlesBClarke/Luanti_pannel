local grid = require("sim.grid")
local compile = require("sim.compile")
local runtime = require("sim.runtime")
local floor = require("sim.floor")

local FUZZ_TRIALS = 40
local FUZZ_DESIGNS = 4
local FUZZ_TICKS = 80
local FUZZ_MAX_SIDE = 3
local MAX_EVALS = 10000

local function rng(seed)
	return function()
		seed = (seed * 1103515245 + 12345) % 2147483648
		return seed / 2147483648
	end
end

-- Dust through row 4 and column 4: joins bit 3 of all four sides.
local function plus()
	local cells = {}
	for k = 1, grid.SIZE do
		cells[grid.index(k, 4)] = { kind = "dust" }
		cells[grid.index(4, k)] = { kind = "dust" }
	end
	return cells
end

-- Random design, with long dust lines so edges often connect across.
local function random_design(rnd)
	local cells, cell_list = {}, {}
	local function put(i, cell)
		if not cells[i] then cell_list[#cell_list + 1] = i end
		cells[i] = cell
	end
	for y = 1, grid.SIZE do
		for x = 1, grid.SIZE do
			local r, cell = rnd(), nil
			if r < 0.25 then cell = { kind = "dust" }
			elseif r < 0.33 then cell = { kind = "block" }
			elseif r < 0.37 then cell = { kind = "bulb" }
			elseif r < 0.41 then cell = { kind = "lamp" }
			elseif r < 0.46 then cell = { kind = "quartz" }
			elseif r < 0.56 then cell = { kind = "torch", attach = math.floor(rnd() * 4) }
			elseif r < 0.60 then cell = { kind = rnd() < 0.5 and "button" or "lever" }
			end
			if cell then put(grid.index(x, y), cell) end
		end
	end
	for _ = 1, 2 do
		local k = math.floor(rnd() * grid.SIZE) + 1
		for j = 1, grid.SIZE do
			put(rnd() < 0.5 and grid.index(j, k) or grid.index(k, j), { kind = "dust" })
		end
	end
	return cells, cell_list
end

-- A w x h floor; designs[i] = { net, cell_list }. Returns the panel list.
local function make_floor(w, h, pick)
	local at, list = {}, {}
	for y = 1, h do
		for x = 1, w do
			local design = pick()
			local P = { state = runtime.new(design.net), cells = design.cell_list, neighbors = {}, out = {}, ext = {} }
			at[y * 100 + x] = P
			list[#list + 1] = P
		end
	end
	for y = 1, h do
		for x = 1, w do
			local P = at[y * 100 + x]
			P.neighbors[0], P.neighbors[1] = at[(y - 1) * 100 + x], at[y * 100 + x + 1]
			P.neighbors[2], P.neighbors[3] = at[(y + 1) * 100 + x], at[y * 100 + x - 1]
		end
	end
	return list
end

local function external(P, d)
	return P.ext[d]
end

-- The plain way: every panel from all off, no eval cache, until nothing changes.
local function plain_settle(list)
	for _, P in ipairs(list) do P.out = {} end
	for _ = 1, MAX_EVALS do
		local changed = false
		for _, P in ipairs(list) do
			P.inputs = floor.gather(P, external)
			P.state.last_out = nil
			local out = runtime.eval(P.state, P.inputs)
			for p = 0, grid.PORTS - 1 do
				if (out[p] == true) ~= (P.out[p] == true) then changed = true end
			end
			P.out = out
		end
		if not changed then return end
	end
	error("plain settle did not converge")
end

local function snapshot(list)
	local s = {}
	for _, P in ipairs(list) do
		for p = 0, grid.PORTS - 1 do s[#s + 1] = P.out[p] and "1" or "0" end
		s[#s + 1] = "|"
		for _, on in ipairs(runtime.lamp_list(P.state)) do s[#s + 1] = on and "1" or "0" end
		s[#s + 1] = "|"
		for _, on in ipairs(runtime.probes(P.state)) do s[#s + 1] = on and "1" or "0" end
		s[#s + 1] = " "
	end
	return table.concat(s)
end

return {
	["a loop of wiring through four panels lets go when its source does"] = function()
		local net = compile.panel(plus())
		local d = { net = net, cell_list = {} }
		local list = make_floor(2, 2, function() return d end)
		floor.relink(list)
		assert(list[1].looped, "2x2 of plus panels has an instant loop")
		local A = list[1]
		A.ext[3] = true
		assert(floor.settle(list, external, MAX_EVALS))
		for _, P in ipairs(list) do runtime.commit(P.state) end
		assert(list[4].out[3] == true, "powered ring reaches the far panel")
		A.ext[3] = false
		assert(floor.settle(list, external, MAX_EVALS))
		for _, P in ipairs(list) do
			for p = 0, grid.PORTS - 1 do assert(not P.out[p], "ring must turn off with its source") end
		end
	end,

	["a row of wiring has no loop"] = function()
		local net = compile.panel(plus())
		local d = { net = net, cell_list = {} }
		local list = make_floor(3, 1, function() return d end)
		floor.relink(list)
		assert(not list[1].looped)
	end,

	["a still panel is not evaluated again"] = function()
		local net = compile.panel(plus())
		local list = make_floor(1, 1, function() return { net = net, cell_list = {} } end)
		floor.relink(list)
		local P = list[1]
		P.ext[3] = true
		floor.settle(list, external, MAX_EVALS)
		runtime.commit(P.state)
		assert(P.state.ran)
		floor.settle(list, external, MAX_EVALS)
		runtime.commit(P.state)
		assert(not P.state.ran, "same inputs, no registers: cached")
		runtime.press(P.state, grid.index(1, 1))
		floor.settle(list, external, MAX_EVALS)
		assert(P.state.ran, "a press wakes it")
	end,

	["fuzz: floors with the eval cache match plain settling tick for tick"] = function()
		for trial = 1, FUZZ_TRIALS do
			local rnd = rng(trial * 7919)
			local designs = { { net = compile.panel(plus()), cell_list = { grid.index(4, 4) } } }
			for k = 2, FUZZ_DESIGNS do
				local cells, cell_list = random_design(rnd)
				designs[k] = { net = compile.panel(cells), cell_list = cell_list }
			end
			local w = math.floor(rnd() * FUZZ_MAX_SIDE) + 1
			local h = math.floor(rnd() * FUZZ_MAX_SIDE) + 1
			local picks = {}
			-- Half the trials are mostly plus panels, which form loops between panels.
			local plus_share = trial % 2 == 0 and 0.75 or 0
			for i = 1, w * h do
				picks[i] = rnd() < plus_share and designs[1] or designs[math.floor(rnd() * #designs) + 1]
			end
			local function picker()
				local i = 0
				return function()
					i = i + 1
					return picks[i]
				end
			end
			local a, b = make_floor(w, h, picker()), make_floor(w, h, picker())
			floor.relink(a)
			for t = 1, FUZZ_TICKS do
				-- Mostly quiet, so the cache gets hits; sometimes a change.
				if rnd() < 0.2 then
					local i, d = math.floor(rnd() * #a) + 1, math.floor(rnd() * 4)
					a[i].ext[d] = not a[i].ext[d]
					b[i].ext[d] = a[i].ext[d]
				end
				-- All outside inputs off: a loop that holds itself on shows here.
				if rnd() < 0.05 then
					for i = 1, #a do a[i].ext, b[i].ext = {}, {} end
				end
				if rnd() < 0.1 then
					local i = math.floor(rnd() * #a) + 1
					local cells = a[i].cells
					if #cells > 0 then
						local c = cells[math.floor(rnd() * #cells) + 1]
						runtime.press(a[i].state, c)
						runtime.press(b[i].state, c)
					end
				end
				assert(floor.settle(a, external, MAX_EVALS), "settle gave up")
				plain_settle(b)
				local sa, sb = snapshot(a), snapshot(b)
				if sa ~= sb then
					error(("trial %d (%dx%d) tick %d\n    floor %s\n    plain %s"):format(trial, w, h, t, sa, sb))
				end
				for i = 1, #a do
					runtime.commit(a[i].state)
					runtime.commit(b[i].state)
				end
			end
		end
	end,
}
