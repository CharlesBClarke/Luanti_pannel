local grid = require("sim.grid")
local ref = require("sim.ref")
local compile = require("sim.compile")
local runtime = require("sim.runtime")

local N, E, S, W = 0, 1, 2, 3

-- Checks one level at a time: a reference panel whose nested panels are
-- compiled ones (each already checked) against the fully compiled panel.
-- The all-reference run is exponential in nesting depth, so keep it small.
local FUZZ_TRIALS = 60
local FUZZ_DEEP_TRIALS = 6
local FUZZ_PANELS = 5
local FUZZ_TICKS = 60
local SPEEDS = { 1, 1, 1, 2, 3, 4 }

local function port(side, bit)
	return side * grid.BITS + bit
end

local function lib_from(list)
	local cells = {}
	for _, e in ipairs(list) do
		local cell = { kind = e[3] }
		if e[3] == "torch" then cell.attach = e[4] end
		if e[3] == "panel" then cell.id, cell.speed = e[4], e[5] or 1 end
		cells[grid.index(e[1], e[2])] = cell
	end
	return cells
end

-- Random library in the spirit of the prototype's fuzz generator, plus switches.
local function random_library(rnd)
	local lib = {}
	for k = 0, FUZZ_PANELS - 1 do
		local cells, cell_list = {}, {}
		for y = 1, grid.SIZE do
			for x = 1, grid.SIZE do
				local r, cell = rnd(), nil
				if r < 0.28 then cell = { kind = "dust" }
				elseif r < 0.38 then cell = { kind = "block" }
				elseif r < 0.44 then cell = { kind = "bulb" }
				elseif r < 0.48 then cell = { kind = "lamp" }
				elseif r < 0.54 then cell = { kind = "quartz" }
				elseif r < 0.66 then cell = { kind = "torch", attach = math.floor(rnd() * 4) }
				elseif r < 0.69 then cell = { kind = rnd() < 0.5 and "button" or "lever" }
				elseif r < 0.74 and k > 0 then
					cell = { kind = "panel", id = math.floor(rnd() * k), speed = SPEEDS[math.floor(rnd() * #SPEEDS) + 1] }
				end
				if cell then
					local i = grid.index(x, y)
					cells[i] = cell
					cell_list[#cell_list + 1] = i
				end
			end
		end
		lib[k] = { cells = cells, cell_list = cell_list }
	end
	return lib
end

local function bits(t, first, last)
	local s = {}
	for i = first, last do s[#s + 1] = t[i] and "1" or "0" end
	return table.concat(s)
end

-- Run ref and compiled side by side; returns nil or a mismatch description.
local function compare(lib, id, rnd, ticks, make_kid)
	local a = ref.from_library(lib, id, make_kid)
	local b = runtime.from_library(lib, id)
	local inputs, cells = {}, lib[id].cell_list
	for t = 1, ticks do
		if rnd() < 0.3 then
			local p = math.floor(rnd() * grid.PORTS)
			inputs[p] = not inputs[p]
		end
		if rnd() < 0.15 and #cells > 0 then
			local c = cells[math.floor(rnd() * #cells) + 1]
			ref.press(a, c)
			runtime.press(b, c)
		end
		local oa, ob = ref.step(a, inputs), runtime.step(b, inputs)
		local la, lb = ref.lamp_list(a), runtime.lamp_list(b)
		local pa, pb = ref.probes(a), runtime.probes(b)
		local ga = bits(oa, 0, grid.PORTS - 1) .. "|" .. bits(la, 1, #la) .. "|" .. bits(pa, 1, #pa)
		local gb = bits(ob, 0, grid.PORTS - 1) .. "|" .. bits(lb, 1, #lb) .. "|" .. bits(pb, 1, #pb)
		if ga ~= gb then
			return ("panel %d tick %d\n    ref      %s\n    compiled %s"):format(id, t, ga, gb)
		end
	end
	return nil
end

-- Small deterministic generator so failures reproduce across Lua builds.
local function rng(seed)
	return function()
		seed = (seed * 1103515245 + 12345) % 2147483648
		return seed / 2147483648
	end
end

return {
	["fuzz: compiled panels match the reference tick for tick"] = function()
		for trial = 1, FUZZ_TRIALS do
			local rnd = rng(trial)
			local lib = random_library(rnd)
			for id = 0, FUZZ_PANELS - 1 do
				local err = compare(lib, id, rnd, FUZZ_TICKS, runtime.from_library)
				assert(not err, ("trial %d: %s"):format(trial, tostring(err)))
			end
		end
	end,

	["fuzz: compiled panels match an all-reference nesting"] = function()
		for trial = 1, FUZZ_DEEP_TRIALS do
			local rnd = rng(1000 + trial)
			local lib = random_library(rnd)
			for id = 0, 2 do
				local err = compare(lib, id, rnd, FUZZ_TICKS)
				assert(not err, ("trial %d: %s"):format(trial, tostring(err)))
			end
		end
	end,

	["unpowered clocks that reach nothing compile away when nested"] = function()
		local lib = {
			[1] = { cells = lib_from({
				{ 2, 2, "block" }, { 3, 2, "torch", W }, { 3, 3, "dust" }, { 2, 3, "dust" },
				{ 5, 5, "block" }, { 6, 5, "torch", W }, { 6, 6, "dust" }, { 5, 6, "dust" },
			}) },
			[2] = { cells = lib_from({ { 4, 4, "panel", 1 } }) },
		}
		-- At the top level the face shows them, so they stay, merged into one clock.
		local own = compile.stats(compile.from_library(lib, 1))
		assert(own.regs == 1, ("top level: regs %d"):format(own.regs))
		local s = compile.stats(compile.from_library(lib, 2))
		assert(s.gates == 0 and s.regs == 0, ("nested: gates %d regs %d"):format(s.gates, s.regs))
	end,

	["identical clocks on one wire merge"] = function()
		-- Two 1-tick clocks, both feeding the north edge dust.
		local cells = lib_from({
			{ 2, 3, "block" }, { 3, 3, "torch", W }, { 3, 4, "dust" }, { 2, 4, "dust" },
			{ 6, 3, "block" }, { 7, 3, "torch", W }, { 7, 4, "dust" }, { 6, 4, "dust" },
			{ 3, 2, "dust" }, { 3, 1, "dust" }, { 7, 2, "dust" }, { 7, 1, "dust" },
		})
		local s = compile.stats(compile.panel(cells))
		assert(s.regs == 1, ("expected one register, got %d"):format(s.regs))
	end,

	["dust straight across compiles to plain wiring"] = function()
		local list = {}
		for x = 1, 8 do list[#list + 1] = { x, 4, "dust" } end
		local net = compile.panel(lib_from(list))
		local s = compile.stats(net)
		assert(s.regs == 0)
		local st = runtime.new(net)
		assert(runtime.eval(st, { [port(W, 3)] = true })[port(E, 3)] == true)
		assert(runtime.eval(st, { [port(W, 3)] = true })[port(W, 3)] == false, "no self-echo")
		assert(runtime.eval(st, { [port(N, 3)] = true })[port(S, 3)] == false)
	end,
}
