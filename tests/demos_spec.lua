local grid = require("sim.grid")
local ref = require("sim.ref")
local compile = require("sim.compile")
local runtime = require("sim.runtime")
local floor = require("sim.floor")
local demos = require("sim.demos")

local SIZE = grid.SIZE
local PRESS_TICKS = 20 -- a press has fully played out (button 10, plus torch delays)
local COMPARE_TICKS = 150
local COUNT_SETTLE = 400 -- the power-on ripple of the counter has finished
local COUNT_TICKS = 2048
local COUNT_BITS = 8 -- low bits checked for halving rates
local WAVE_TICKS = 120 -- a wave has crossed a board and died out
local WAVE_MIN_LIT = 8 -- each pixel stays lit at least this long

local function build()
	local lib, n = {}, 0
	local ids, shown = demos.build(function(cells, name)
		n = n + 1
		lib[n] = { cells = cells, name = name }
		return n
	end)
	return lib, ids, shown
end

local function rng(seed)
	return function()
		seed = (seed * 1103515245 + 12345) % 2147483648
		return seed / 2147483648
	end
end

-- lit[x][y] from a state's lamps (a cell is lit if any lamp in it is).
local function lamp_grid(state)
	local lit = {}
	for x = 1, SIZE do lit[x] = {} end
	for j, on in ipairs(runtime.lamp_list(state)) do
		local x, y = grid.xy(state.net.lamp_cells[j])
		lit[x][y] = lit[x][y] or on
	end
	return lit
end

local function run(state, ticks)
	for _ = 1, ticks do runtime.step(state, {}) end
end

-- The counter's bits in order: the snake from counter_cell in sim/demos.lua.
local function counter_cells()
	local list = {}
	for y = 1, SIZE do
		for k = 1, SIZE do
			local x = y % 2 == 1 and k or SIZE + 1 - k
			list[#list + 1] = { x, y }
		end
	end
	return list
end

return {
	every_demo_compiles_small = function()
		local lib, ids, shown = build()
		assert(#shown == 4, "expected 4 demos to hand out")
		for _, name in ipairs(shown) do
			local s = compile.stats(compile.from_library(lib, ids[name]))
			assert(s.nodes < 4000, name .. " compiled to " .. s.nodes .. " nodes")
		end
	end,

	clock_tower_is_billions_of_torches_in_one_register = function()
		local lib, ids = build()
		local id = ids["Clock Tower"]
		local c = demos.count(lib, id)
		assert(c.torches == 32 * 64 ^ demos.TOWER_LEVELS, "torches: " .. c.torches)
		local net = compile.from_library(lib, id)
		assert(compile.stats(net).regs == 1)
		-- Its lamps blink every tick, all together.
		local state = runtime.new(net)
		run(state, 1)
		local before = lamp_grid(state)
		run(state, 1)
		local after = lamp_grid(state)
		for y = 1, SIZE do
			assert(before[2][y] ~= after[2][y], "lamp did not blink")
			assert(after[2][y] == after[8][y] and after[2][y] == after[2][1], "lamps out of step")
		end
	end,

	lights_out_toggles_a_plus = function()
		local lib, ids = build()
		local state = runtime.from_library(lib, ids["Lights Out"])
		local want = {}
		for x = 1, SIZE do
			want[x] = {}
			for y = 1, SIZE do want[x][y] = true end
		end
		local rnd = rng(7)
		for _ = 1, 30 do
			local x, y = math.floor(rnd() * SIZE) + 1, math.floor(rnd() * SIZE) + 1
			runtime.press(state, grid.index(x, y))
			for _, d in ipairs({ { 0, 0 }, { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
				local u, v = x + d[1], y + d[2]
				if want[u] and want[u][v] ~= nil then want[u][v] = not want[u][v] end
			end
			run(state, PRESS_TICKS)
			local lit = lamp_grid(state)
			for u = 1, SIZE do
				for v = 1, SIZE do
					assert(lit[u][v] == want[u][v], ("after pressing %d,%d: cell %d,%d wrong"):format(x, y, u, v))
				end
			end
		end
	end,

	lights_out_boards_side_by_side_are_one_game = function()
		local lib, ids = build()
		local net = compile.from_library(lib, ids["Lights Out"])
		local a = { state = runtime.new(net), neighbors = {} }
		local b = { state = runtime.new(net), neighbors = {} }
		a.neighbors[1], b.neighbors[3] = b, a -- b east of a
		local list = { a, b }
		floor.relink(list)
		local function external() return false end
		local function tick()
			assert(floor.settle(list, external, 100))
			for _, P in ipairs(list) do runtime.commit(P.state) end
		end
		runtime.press(a.state, grid.index(SIZE, 4))
		for _ = 1, PRESS_TICKS do tick() end
		local la, lb = lamp_grid(a.state), lamp_grid(b.state)
		assert(not la[SIZE][4] and not la[SIZE - 1][4] and not la[SIZE][3] and not la[SIZE][5])
		assert(not lb[1][4], "the press did not cross to the next board")
		assert(lb[1][3] and lb[1][5] and lb[2][4], "the press spread too far")
	end,

	wave_spreads_once_from_a_press = function()
		local lib, ids = build()
		local state = runtime.from_library(lib, ids["Wave"])
		run(state, 1)
		local sx, sy = 3, 4
		runtime.press(state, grid.index(sx, sy))
		-- For each pixel: ticks it was lit, how many times it turned on, and when first.
		local lit_ticks, ons, first, last = {}, {}, {}, lamp_grid(state)
		for t = 1, WAVE_TICKS do
			run(state, 1)
			local lit = lamp_grid(state)
			for x = 1, SIZE do
				for y = 1, SIZE do
					local k = x * 10 + y
					if lit[x][y] then lit_ticks[k] = (lit_ticks[k] or 0) + 1 end
					if lit[x][y] and not last[x][y] then
						ons[k] = (ons[k] or 0) + 1
						first[k] = first[k] or t
					end
				end
			end
			last = lit
		end
		local at = {} -- first lit tick by distance from the press
		for x = 1, SIZE do
			for y = 1, SIZE do
				local k = x * 10 + y
				assert(ons[k] == 1, ("pixel %d,%d turned on %d times"):format(x, y, ons[k] or 0))
				assert(lit_ticks[k] >= WAVE_MIN_LIT, ("pixel %d,%d lit only %d ticks"):format(x, y, lit_ticks[k]))
				assert(not last[x][y], "the wave did not die out")
				local d = math.abs(x - sx) + math.abs(y - sy)
				assert(at[d] == nil or at[d] == first[k], "pixels at the same distance lit at different times")
				at[d] = first[k]
			end
		end
		for d = 1, #at do assert(at[d] > at[d - 1], "the wave does not move outward") end
	end,

	wave_crosses_to_the_next_board = function()
		local lib, ids = build()
		local net = compile.from_library(lib, ids["Wave"])
		local a = { state = runtime.new(net), neighbors = {} }
		local b = { state = runtime.new(net), neighbors = {} }
		a.neighbors[2], b.neighbors[0] = b, a -- b south of a
		local list = { a, b }
		floor.relink(list)
		local function external() return false end
		runtime.press(a.state, grid.index(4, 4))
		local ons = 0
		local was = false
		for _ = 1, 2 * WAVE_TICKS do
			assert(floor.settle(list, external, 100))
			for _, P in ipairs(list) do runtime.commit(P.state) end
			local on = lamp_grid(b.state)[4][SIZE]
			if on and not was then ons = ons + 1 end
			was = on
		end
		assert(ons == 1, ("the far board's pixel turned on %d times"):format(ons))
	end,

	counter_counts = function()
		local lib, ids = build()
		local state = runtime.from_library(lib, ids["64-bit counter"])
		run(state, COUNT_SETTLE)
		local cells, flips, last = counter_cells(), {}, nil
		for _ = 1, COUNT_TICKS do
			run(state, 1)
			local lit = lamp_grid(state)
			if last then
				for k = 1, COUNT_BITS do
					local x, y = cells[k][1], cells[k][2]
					if lit[x][y] ~= last[x][y] then flips[k] = (flips[k] or 0) + 1 end
				end
			end
			last = lit
		end
		-- Bit 0 flips every 2 ticks, and each bit flips half as often as the one before.
		for k = 1, COUNT_BITS do
			local want = COUNT_TICKS / 2 ^ k
			assert(math.abs((flips[k] or 0) - want) <= 1, ("bit %d flipped %d times, want %d"):format(k - 1, flips[k] or 0, want))
		end
	end,

	-- One level at a time, as in compile_spec: the reference with compiled
	-- nested panels against the fully compiled panel, with random presses.
	demos_match_the_reference = function()
		local lib, ids = build()
		local rnd = rng(11)
		for _, name in ipairs({ "lights out cell", "Lights Out", "wave pulse", "wave cell", "Wave", "counter clock bit", "counter bit W-S",
			"counter bit N-W", "64-bit counter", "tower 0", "tower 1" }) do
			local id = ids[name]
			local a = ref.from_library(lib, id, runtime.from_library)
			local b = runtime.from_library(lib, id)
			local cells = {}
			for c in pairs(lib[id].cells) do cells[#cells + 1] = c end
			table.sort(cells)
			local inputs = {}
			for t = 1, COMPARE_TICKS do
				if rnd() < 0.2 then
					local p = math.floor(rnd() * grid.PORTS)
					inputs[p] = not inputs[p]
				end
				if rnd() < 0.1 then
					local c = cells[math.floor(rnd() * #cells) + 1]
					ref.press(a, c)
					runtime.press(b, c)
				end
				local oa, ob = ref.step(a, inputs), runtime.step(b, inputs)
				for p = 0, grid.PORTS - 1 do
					assert((oa[p] == true) == (ob[p] == true), ("%s tick %d: output %d differs"):format(name, t, p))
				end
				local la, lb = ref.lamp_list(a), runtime.lamp_list(b)
				for j = 1, #la do
					assert(la[j] == lb[j], ("%s tick %d: lamp %d differs"):format(name, t, j))
				end
			end
		end
	end,
}
