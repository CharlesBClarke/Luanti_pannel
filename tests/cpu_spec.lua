local grid = require("sim.grid")
local static = require("sim.static")
local ref = require("sim.ref")
local runtime = require("sim.runtime")
local art = require("sim.art")
local cpu = require("sim.cpu")

local N, E, S, W = 0, 1, 2, 3
local WRITE_TICKS = 8 -- write select held this long
local SETTLE_TICKS = 8 -- enough for any part to settle
local LOOPS = 4 -- program loops the computer test checks
local FUZZ_TICKS = 80 -- random-input ticks per tile, compiled against reference
local FUZZ_TILES = { "alu", "control", "control 2", "x tile", "ram tile", "ram decoder 5", "relay last",
	"address in -w", "address cross", "bus drop" }

local function port(side, bit)
	return side * grid.BITS + bit
end

-- The CPU designs plus `extra` test panels ({ name, rows, legend }).
local function library(extra)
	local lib, n = {}, 0
	local function add(cells, name)
		n = n + 1
		lib[n] = { cells = cells, name = name }
		return n
	end
	local ids = cpu.build(add)
	for _, e in ipairs(extra or {}) do
		local names = {}
		for ch, name in pairs(e[3]) do names[ch] = name end
		ids[e[1]] = add(art.cells(e[2], names, ids), e[1])
	end
	return lib, ids
end

-- Run a panel in both the reference and compiled form, side by side.
local function both(lib, id)
	return { ref.from_library(lib, id), runtime.from_library(lib, id) }
end
local function step(states, inputs, ticks)
	local outs
	for _ = 1, ticks or 1 do
		outs = {}
		for k, st in ipairs(states) do
			local o = {}
			for p, v in pairs((st.runtime or ref).step(st, inputs)) do o[p] = v end
			outs[k] = o
		end
	end
	return outs
end
local function lamps(states)
	local o = {}
	for k, st in ipairs(states) do o[k] = (st.runtime or ref).lamp_list(st) end
	return o
end

-- Lamps of design `id` in lamp_list order (own lamps, then each nested
-- panel's in cell order), each as the path of cells leading to it.
local function lamp_paths(lib, id, path, out)
	path, out = path or {}, out or {}
	local S = static.analyze(lib[id].cells)
	for _, c in ipairs(S.lamps) do
		local p = { unpack(path) }
		p[#p + 1] = c
		out[#out + 1] = table.concat(p, "/")
	end
	for _, c in ipairs(S.panels) do
		local p = { unpack(path) }
		p[#p + 1] = c
		lamp_paths(lib, lib[id].cells[c].id, p, out)
	end
	return out
end

-- Reads a value from lamps: bit b is the lamp of the cell at path(b) (each
-- cell holding a bit has one lamp).
local function reader(lib, id)
	local where = {}
	for j, p in ipairs(lamp_paths(lib, id)) do where[p:match("^(.*)/[^/]*$")] = j end
	return function(lamps, path, bits)
		local v = 0
		for b = 0, bits - 1 do
			local j = assert(where[path(b)], path(b))
			if lamps[j] then v = v + 2 ^ b end
		end
		return v
	end
end

local function bits_of(v, n)
	local t = {}
	for b = 0, n - 1 do t[b] = math.floor(v / 2 ^ b) % 2 == 1 end
	return t
end

local I = grid.index
local function at(...)
	local t = {}
	for k, xy in ipairs({ ... }) do t[k] = I(xy[1], xy[2]) end
	return table.concat(t, "/")
end

return {
	["computer: runs the Fibonacci loop like the model"] = function()
		local lib, ids = library()
		local id = ids.computer
		local st = runtime.from_library(lib, id)
		local read = reader(lib, id)
		local function state()
			local l = runtime.lamp_list(st)
			local s = {
				A = read(l, function(b) return at({ 4, 7 }, { b + 1, 2 }) end, 8),
				B = read(l, function(b) return at({ 4, 7 }, { b + 1, 4 }) end, 8),
				X = read(l, function(b) return at({ 1, 7 }, { b + 1, 8 }) end, cpu.ADDRESS_BITS),
				count = read(l, function(b) return at({ 3, 7 }, { 7 - b, 8 }) end, cpu.COUNTER_BITS),
				ram = {},
			}
			for a = 0, 2 ^ cpu.ADDRESS_BITS - 1 do
				local t, k = math.floor(a / 4), a % 4
				local tile = { 2 * (math.floor(t / 4) + 1), t % 4 + 2 }
				s.ram[a] = read(l, function(b) return at(tile, { b + 1, 2 * k + 1 }) end, 8)
			end
			return s
		end
		-- Wait for the start of S0: the step counter at 0 (its lamps lag the
		-- bulbs a little, so wait for a stretch of zeros' end), then let S0 begin.
		local function next_loop()
			local seen_top = false
			for _ = 1, 4 * cpu.CYCLE_TICKS + 20 do
				runtime.step(st, {})
				local c = state().count
				if c >= 96 then seen_top = true end
				if seen_top and c < 32 then return end
			end
			error("the step counter never wrapped")
		end
		next_loop()
		local s = state()
		local A, B, X, ram = s.A, s.B, s.X, {}
		for a, v in pairs(s.ram) do ram[a] = v end
		for loop = 1, LOOPS do
			ram[X] = A
			A = (A + B) % 256
			B = ram[X]
			X = (X + 1) % 2 ^ cpu.ADDRESS_BITS
			next_loop()
			s = state()
			local where = ("loop %d"):format(loop)
			assert(s.A == A, ("%s: A is %d, model %d"):format(where, s.A, A))
			assert(s.B == B, ("%s: B is %d, model %d"):format(where, s.B, B))
			assert(s.X == X, ("%s: X is %d, model %d"):format(where, s.X, X))
			for a = 0, 2 ^ cpu.ADDRESS_BITS - 1 do
				assert(s.ram[a] == ram[a], ("%s: RAM[%d] is %d, model %d"):format(where, a, s.ram[a], ram[a]))
			end
		end
	end,

	["cpu tiles: compiled matches the reference tick for tick"] = function()
		local lib, ids = library()
		local seed = 4242
		local function rnd()
			seed = (seed * 1103515245 + 12345) % 2147483648
			return seed / 2147483648
		end
		for _, name in ipairs(FUZZ_TILES) do
			local st = both(lib, ids[name])
			local inputs = {}
			for t = 1, FUZZ_TICKS do
				if rnd() < 0.4 then
					local p = math.floor(rnd() * grid.PORTS)
					inputs[p] = not inputs[p]
				end
				local outs = step(st, inputs)
				local l = lamps(st)
				for p = 0, grid.PORTS - 1 do
					assert((outs[1][p] == true) == (outs[2][p] == true), ("%s tick %d: port %d differs"):format(name, t, p))
				end
				for j = 1, #l[1] do
					assert(l[1][j] == l[2][j], ("%s tick %d: lamp %d differs"):format(name, t, j))
				end
			end
		end
	end,

	["ram decoder: selects its own four bytes"] = function()
		local lib, ids = library()
		for _, t in ipairs({ 0, 5, cpu.RAM_TILES - 1 }) do
			local st = both(lib, ids["ram decoder " .. t])
			for _, a in ipairs({ 4 * t, 4 * t + 1, 4 * t + 3, (4 * t + 4) % 64, (4 * t + 17) % 64 }) do
				for _, mode in ipairs({ "we", "re", "none" }) do
					local inputs, ab = {}, bits_of(a, cpu.ADDRESS_BITS)
					for b = 0, cpu.ADDRESS_BITS - 1 do inputs[port(N, b)] = ab[b] end
					inputs[port(N, cpu.WE_LANE - 1)] = mode ~= "we" -- active low
					inputs[port(N, cpu.RE_LANE - 1)] = mode ~= "re"
					local outs = step(st, inputs, SETTLE_TICKS)
					for k = 0, 3 do
						local mine = a == 4 * t + k
						for j = 1, 2 do
							local ws, nrs = outs[j][port(E, 2 * k)], outs[j][port(E, 2 * k + 1)]
							assert(ws == (mine and mode == "we"),
								("tile %d address %d %s: WS%d is %s"):format(t, a, mode, k, tostring(ws)))
							assert(nrs == not (mine and mode == "re"),
								("tile %d address %d %s: nRS%d is %s"):format(t, a, mode, k, tostring(nrs)))
						end
					end
				end
			end
		end
	end,

	["ram tile: four bytes written and read back"] = function()
		local lib, ids = library()
		local st = both(lib, ids["ram tile"])
		local idle = {}
		for k = 0, 3 do idle[port(W, 2 * k + 1)] = true end
		local function with(base, extra)
			local t = {}
			for p, v in pairs(base) do t[p] = v end
			for p, v in pairs(extra) do t[p] = v end
			return t
		end
		local function write(k, v)
			local data = {}
			for b, on in pairs(bits_of(v, 8)) do data[port(N, b)] = on end
			step(st, with(idle, data), 2)
			step(st, with(with(idle, data), { [port(W, 2 * k)] = true }), WRITE_TICKS)
			step(st, with(idle, data), 2)
			step(st, idle, SETTLE_TICKS)
		end
		local function read(k)
			local outs = step(st, with(idle, { [port(W, 2 * k + 1)] = false }), SETTLE_TICKS)
			step(st, idle, SETTLE_TICKS)
			local v = { 0, 0 }
			for j = 1, 2 do
				for b = 0, 7 do
					if outs[j][port(S, b)] then v[j] = v[j] + 2 ^ b end
				end
			end
			assert(v[1] == v[2], "compiled and reference differ")
			return v[1]
		end
		step(st, idle, SETTLE_TICKS)
		for k = 0, 3 do assert(read(k) == 255, "powers on as all ones") end
		local values = { 0x5A, 0x00, 0xFF, 0x81 }
		for k = 0, 3 do write(k, values[k + 1]) end
		for k = 0, 3 do assert(read(k) == values[k + 1], ("byte %d reads %d"):format(k, read(k))) end
		write(2, 0x3C)
		assert(read(2) == 0x3C and read(1) == 0x00 and read(3) == 0x81)
	end,

	["ram bit: write and read back"] = function()
		-- One bit: data in from the north edge (column 2), out of the south
		-- edge; write select on the east of row 2, read select (active low)
		-- on the west of row 3.
		local lib, ids = library({ { "bit", {
			". + . . . . . .",
			". S + + + + + +",
			"+ P . . . . . .",
			". + . . . . . .",
			". + . . . . . .",
			". + . . . . . .",
			". + . . . . . .",
			". + . . . . . .",
		}, { S = "ram store", P = "ram port" } } })
		local st = both(lib, ids.bit)
		local D, WS, nRS, OUT = port(N, 1), port(E, 1), port(W, 2), port(S, 1)
		local function write(v)
			step(st, { [D] = v, [nRS] = true }, 2)
			step(st, { [D] = v, [WS] = true, [nRS] = true }, WRITE_TICKS)
			step(st, { [D] = v, [nRS] = true }, 2)
			step(st, { [nRS] = true }, SETTLE_TICKS)
		end
		local function read()
			local outs = step(st, {}, SETTLE_TICKS)
			step(st, { [nRS] = true }, SETTLE_TICKS)
			assert(outs[1][OUT] == outs[2][OUT], "compiled and reference differ")
			return outs[1][OUT] == true
		end
		local function lit()
			local l = lamps(st)
			assert(l[1][1] == l[2][1])
			return l[1][1] == true
		end
		-- The bulb flips once while powering on, so RAM starts as all ones.
		step(st, { [nRS] = true }, SETTLE_TICKS)
		assert(read() == true and lit(), "powers on as 1")
		for _, v in ipairs({ true, true, false, false, true, false }) do
			write(v)
			assert(lit() == v, "lamp shows the bit")
			assert(read() == v, "reads back what was written")
		end
	end,
}
