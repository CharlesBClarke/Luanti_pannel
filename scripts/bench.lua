-- Offline benchmark: luajit scripts/bench.lua [library.lua]
-- Compiles the stress designs (and, if given, every design in a library
-- dumped from a world's mod storage) and times runtime.step on each, with
-- no inputs: "us/tick" as it runs (a still design hits the eval cache), and
-- "full" and ns/node with the cache defeated, the evaluator's own speed.
-- Activity: the share of nodes whose value changes per step, average and
-- worst, left alone ("still") and played with ("poked": random input flips
-- and presses). It decides between event-driven evaluation and generated
-- code (docs/todo.md).
-- Run from the repo root.

package.path = "./?.lua;" .. package.path

local compile = require("sim.compile")
local runtime = require("sim.runtime")
local stress = require("sim.stress")
local cpu = require("sim.cpu")

local MIN_SECONDS = 0.2 -- time each design for at least this long
local ACTIVITY_WARM = 20 -- steps run before counting activity
local ACTIVITY_STEPS = 300 -- steps counted
local POKE_FLIP = 0.1 -- poked: chance per step to flip one input pin
local POKE_PRESS = 0.05 -- poked: chance per step to press one cell

-- Small deterministic generator, so runs compare.
local function rng(seed)
	return function()
		seed = (seed * 1103515245 + 12345) % 2147483648
		return seed / 2147483648
	end
end

local function time_steps(net, full)
	local state = runtime.new(net)
	local zero, ticks = {}, 0
	local started = os.clock()
	repeat
		for _ = 1, 100 do
			if full then state.last_out = nil end
			runtime.step(state, zero)
		end
		ticks = ticks + 100
	until os.clock() - started >= MIN_SECONDS
	return (os.clock() - started) / ticks * 1e6
end

-- Average and worst share of nodes whose value changed from one step to the next.
local function activity(net, cells, poked)
	local state, inputs, rnd = runtime.new(net), {}, rng(12345)
	local press_cells = {}
	for c in pairs(cells) do press_cells[#press_cells + 1] = c end
	table.sort(press_cells)
	local prev, total, worst = {}, 0, 0
	for t = 1, ACTIVITY_WARM + ACTIVITY_STEPS do
		if poked then
			if rnd() < POKE_FLIP then
				local p = math.floor(rnd() * 32)
				inputs[p] = not inputs[p]
			end
			if rnd() < POKE_PRESS and #press_cells > 0 then
				runtime.press(state, press_cells[math.floor(rnd() * #press_cells) + 1])
			end
		end
		state.last_out = nil
		runtime.step(state, inputs)
		local vals, changed = state.vals, 0
		for i = 1, #net.nodes do
			if vals[i] ~= prev[i] then changed = changed + 1 end
			prev[i] = vals[i]
		end
		if t > ACTIVITY_WARM then
			local share = changed / #net.nodes
			total, worst = total + share, math.max(worst, share)
		end
	end
	return total / ACTIVITY_STEPS * 100, worst * 100
end

local function report(lib, ids, label)
	for _, id in ipairs(ids) do
		local net = compile.from_library(lib, id)
		local s = compile.stats(net)
		local us, full = time_steps(net, false), time_steps(net, true)
		local still_avg, still_max = activity(net, lib[id].cells, false)
		local poked_avg, poked_max = activity(net, lib[id].cells, true)
		print(("%-28s %7d nodes %7d gates %6d regs %9.2f us/tick %9.2f full %6.1f ns/node"
			.. " | active%% still %5.1f (max %5.1f) poked %5.1f (max %5.1f)"):format(
			label(id), s.nodes, s.gates, s.regs, us, full, full * 1000 / math.max(1, s.nodes),
			still_avg, still_max, poked_avg, poked_max))
	end
end

local lib, order = {}, {}
local names = stress.build(function(cells, name)
	lib[#lib + 1] = { cells = cells, name = name }
	order[#order + 1] = #lib
	return #lib
end)
assert(names)
local cpu_ids = cpu.build(function(cells, name)
	lib[#lib + 1] = { cells = cells, name = name }
	return #lib
end)
order[#order + 1] = cpu_ids.computer
report(lib, order, function(id) return lib[id].name end)

if arg[1] then
	local data = dofile(arg[1])
	local wl, ids = {}, {}
	for id, e in pairs(data.panels) do
		wl[id] = e
		ids[#ids + 1] = id
	end
	table.sort(ids)
	report(wl, ids, function(id) return ("#%d %s"):format(id, wl[id].name or "") end)
end
