-- Benchmarking: /panel_stress places a floor of stress panels (sim/stress.lua)
-- near the player, and scripts/bench.sh runs a headless server through a
-- list of floors and logs the tick time of each.

local sim, library, world = ...

local PANEL = "redstone_panels:compiled"
local FLOOR = "mcl_core:stone"
local MAX_SIDE = 32 -- largest floor /panel_stress will place (side x side panels)
local STRESS_OFFSET = 3 -- blocks from the player to the floor's near corner
local WARM_SECONDS = 1 -- run before measuring
local MEASURE_SECONDS = 3
-- scripts/bench.sh: { design, side } floors, measured one after another.
local SCENARIO = {
	{ "busy", 1 }, { "busy", 4 }, { "busy", 8 }, { "busy", 16 },
	{ "heavy", 1 }, { "heavy", 2 }, { "heavy", 4 },
}
local BENCH_ORIGIN = vector.new(0, 100, 0)

local function stress_ids()
	return sim.stress.build(function(cells, name)
		return assert(library.add(cells, name, "stress"))
	end)
end

local placed = {} -- positions /panel_stress placed, for "/panel_stress clear"

-- A side x side floor of panel `id` from `corner` along +x and +z, all
-- turned the same way so neighbours link into one circuit.
local function place_floor(corner, id, side)
	local list = {}
	for dx = 0, side - 1 do
		for dz = 0, side - 1 do
			local pos = vector.offset(corner, dx, 0, dz)
			core.set_node(vector.offset(pos, 0, -1, 0), { name = FLOOR })
			core.set_node(pos, { name = PANEL, param2 = 0 })
			core.get_meta(pos):set_int("panel_id", id)
			world.activate(pos)
			list[#list + 1] = pos
		end
	end
	return list
end

local function clear(list)
	for _, pos in ipairs(list) do core.set_node(pos, { name = "air" }) end
end

local function report(label)
	local b = world.bench()
	return ("%-12s %4d panels %8d nodes | tick %8.3f ms avg %8.3f max | settle %8.3f commit %7.3f faces %7.3f"):format(
		label, b.panels, b.nodes, b.avg_ms, b.max_ms, b.settle_ms, b.commit_ms, b.face_ms)
end

core.register_chatcommand("panel_stress", {
	params = "<design> <side> | clear",
	description = "Place a side x side floor of a stress panel next to you (designs: "
		.. "clock, stage, busy, heavy), then see /panel_bench",
	privs = { server = true },
	func = function(name, param)
		if param == "clear" then
			clear(placed)
			local n = #placed
			placed = {}
			return true, ("Removed %d stress panels."):format(n)
		end
		local design, side = param:match("^(%a+)%s+(%d+)$")
		side = tonumber(side)
		local ids = stress_ids()
		if not (design and ids[design] and side and side >= 1 and side <= MAX_SIDE) then
			return false, "Usage: /panel_stress <clock|stage|busy|heavy> <1-" .. MAX_SIDE .. "> or /panel_stress clear"
		end
		local player = core.get_player_by_name(name)
		if not player then return false, "You need to be in game." end
		local corner = vector.offset(vector.round(player:get_pos()), STRESS_OFFSET, 0, STRESS_OFFSET)
		for _, pos in ipairs(place_floor(corner, ids[design], side)) do placed[#placed + 1] = pos end
		world.reset_bench()
		return true, ("Placed %d %s panels. Wait a few seconds, then /panel_bench."):format(side * side, design)
	end,
})

-- Headless run for scripts/bench.sh.
if core.settings:get_bool("redstone_panels.bench", false) then
	local function run()
		world.keep_loaded = true
		local ids = stress_ids()
		local lines = {}
		local function step(k)
			local entry = SCENARIO[k]
			if not entry then
				for _, line in ipairs(lines) do core.log("action", "[redstone_panels] bench: " .. line) end
				core.log("action", "[redstone_panels] bench done")
				core.request_shutdown("bench done", false, 0)
				return
			end
			local list = place_floor(BENCH_ORIGIN, ids[entry[1]], entry[2])
			core.after(WARM_SECONDS, function()
				world.reset_bench()
				core.after(MEASURE_SECONDS, function()
					lines[#lines + 1] = report(entry[1] .. " " .. entry[2] .. "x" .. entry[2])
					clear(list)
					core.after(WARM_SECONDS, function() step(k + 1) end)
				end)
			end)
		end
		step(1)
	end
	-- Mesecons ignores everything for its first few seconds.
	core.after(5, function()
		local far = 40
		core.emerge_area(vector.offset(BENCH_ORIGIN, -2, -2, -2), vector.offset(BENCH_ORIGIN, far, 4, far),
			function(_, _, remaining)
				if remaining == 0 then run() end
			end)
	end)
end
