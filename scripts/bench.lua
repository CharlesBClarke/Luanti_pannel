-- Offline benchmark: luajit scripts/bench.lua [library.lua]
-- Compiles the stress designs (and, if given, every design in a library
-- dumped from a world's mod storage) and times runtime.step on each.
-- Run from the repo root.

package.path = "./?.lua;" .. package.path

local compile = require("sim.compile")
local runtime = require("sim.runtime")
local stress = require("sim.stress")

local MIN_SECONDS = 0.2 -- time each design for at least this long

local function time_steps(net)
	local state = runtime.new(net)
	local zero, ticks = {}, 0
	local started = os.clock()
	repeat
		for _ = 1, 100 do runtime.step(state, zero) end
		ticks = ticks + 100
	until os.clock() - started >= MIN_SECONDS
	return (os.clock() - started) / ticks * 1e6
end

local function report(lib, ids, label)
	for _, id in ipairs(ids) do
		local net = compile.from_library(lib, id)
		local s = compile.stats(net)
		local us = time_steps(net)
		print(("%-28s %7d nodes %7d gates %6d regs %9.2f us/tick %6.1f ns/node"):format(
			label(id), s.nodes, s.gates, s.regs, us, us * 1000 / math.max(1, s.nodes)))
	end
end

local lib, order = {}, {}
local names = stress.build(function(cells, name)
	lib[#lib + 1] = { cells = cells, name = name }
	order[#order + 1] = #lib
	return #lib
end)
assert(names)
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
