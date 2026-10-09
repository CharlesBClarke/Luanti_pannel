-- /panel_demo: ready-made panels (sim/demos.lua) to show others what panels
-- can do. Hands them out, or lays them out in front of the player, and
-- tells what each one holds and what it costs to run.

local sim, library, world = ...
local compile, runtime, demos = sim.compile, sim.runtime, sim.demos

local PANEL = "redstone_panels:compiled"
local OWNER = "demo"
local BOARDS = 4 -- Lights Out and Wave boards handed out: enough for a 2x2 floor each
local PLACE_OFFSET = 2 -- blocks from the player to the near edge of the layout
local TIME_WARM = 50 -- steps run before timing a design
local TIME_STEPS = 2000 -- steps timed

-- Where /panel_demo place puts each demo: { name, right, away } in blocks
-- from the near left corner, seen from the player. Gaps keep them unlinked.
local LAYOUT = {
	{ "Lights Out", 0, 0 }, { "Lights Out", 1, 0 }, { "Lights Out", 0, 1 }, { "Lights Out", 1, 1 },
	{ "64-bit counter", 3, 0 },
	{ "Clock Tower", 5, 0 },
	{ "Wave", 7, 0 }, { "Wave", 8, 0 }, { "Wave", 7, 1 }, { "Wave", 8, 1 },
	{ "RGB Cycle", 10, 0 },
}

local BLURB = {
	["Lights Out"] = "Press a cell to flip it and its neighbours; boards side by side make one game. Idle until pressed",
	["64-bit counter"] = "One nested flip-flop per cell, counting 5 times a second",
	["Wave"] = "Press a cell to send out a ring of light; it carries on across boards placed side by side",
	["RGB Cycle"] = "Each cell is a nested red, green and blue lamp on a 3-bit counter; their light mixes into one pixel",
	["Clock Tower"] = "Clocks nested " .. demos.TOWER_LEVELS .. " levels deep, merged by the compiler",
}

local ids, shown

local function demo_ids()
	if not ids then
		ids, shown = demos.build(function(cells, name)
			return assert(library.add(cells, name, OWNER))
		end)
	end
	return ids, shown
end

-- 1234567 -> "1,234,567"
local function thousands(n)
	local s = ("%d"):format(n)
	repeat
		local k
		s, k = s:gsub("^(%d+)(%d%d%d)", "%1,%2")
	until k == 0
	return s
end

-- Server time per tick of one panel on its own, eval cache included.
local function us_per_tick(net)
	local state, zero = runtime.new(net), {}
	for _ = 1, TIME_WARM do runtime.step(state, zero) end
	local started = core.get_us_time()
	for _ = 1, TIME_STEPS do runtime.step(state, zero) end
	return (core.get_us_time() - started) / TIME_STEPS
end

local lib_view = setmetatable({}, { __index = function(_, id) return library.get(id) end })

local function describe(name)
	local id = demo_ids()[name]
	local c = demos.count(lib_view, id)
	local net = assert(library.compiled(id))
	local s = compile.stats(net)
	return ("%s: %s parts, %s torches -> %s gates and %s registers, %.2f us/tick. %s."):format(
		name, thousands(c.parts), thousands(c.torches), thousands(s.gates), thousands(s.regs),
		us_per_tick(net), BLURB[name])
end

local function report(head)
	local _, names = demo_ids()
	local lines = { head }
	for _, name in ipairs(names) do lines[#lines + 1] = describe(name) end
	lines[#lines + 1] = "/panel_bench shows what the placed panels cost the server."
	return table.concat(lines, "\n")
end

local function give(player, stack)
	local left = player:get_inventory():add_item("main", stack)
	if not left:is_empty() then core.add_item(player:get_pos(), left) end
end

local function hand_out(player)
	local list, names = demo_ids()
	for _, name in ipairs(names) do
		local stack = library.item(list[name])
		if name == "Lights Out" or name == "Wave" then stack:set_count(BOARDS) end
		give(player, stack)
	end
end

-- Place LAYOUT in front of the player, all turned their way. Only into
-- empty, unprotected space. Returns true, or false and why not.
local function place(player)
	local list = demo_ids()
	local name = player:get_player_name()
	local dir = core.dir_to_fourdir(player:get_look_dir())
	local away, right = world.SIDES[dir][0], world.SIDES[dir][1]
	local corner = vector.add(vector.round(player:get_pos()), vector.multiply(away, PLACE_OFFSET))
	local spots = {}
	for k, entry in ipairs(LAYOUT) do
		local pos = vector.add(corner, vector.add(vector.multiply(right, entry[2]), vector.multiply(away, entry[3])))
		local def = core.registered_nodes[core.get_node(pos).name]
		if not (def and def.buildable_to) or core.is_protected(pos, name) then
			return false, "No room: clear a flat 11x2 area in front of you."
		end
		spots[k] = pos
	end
	for k, entry in ipairs(LAYOUT) do
		local pos, id = spots[k], list[entry[1]]
		core.set_node(pos, { name = PANEL, param2 = dir })
		local meta = core.get_meta(pos)
		meta:set_int("panel_id", id)
		meta:set_string("infotext", library.describe(id))
		world.activate(pos)
	end
	return true
end

core.register_chatcommand("panel_demo", {
	params = "[place]",
	description = "Get ready-made demo panels (Lights Out, Wave, a 64-bit counter, a clock tower, RGB colors), "
		.. "or place them in front of you",
	privs = { give = true },
	func = function(name, param)
		local player = core.get_player_by_name(name)
		if not player then return false, "You need to be in game." end
		if param == "place" then
			local ok, err = place(player)
			if not ok then return false, err end
			return true, report("Placed in front of you: a 2x2 Lights Out floor, the counter, the clock tower, "
				.. "a 2x2 Wave floor and the RGB Cycle.")
		elseif param == "" then
			hand_out(player)
			return true, report(("Here are the demo panels (%d Lights Out and %d Wave boards, for 2x2 floors):"):format(
				BOARDS, BOARDS))
		end
		return false, "Usage: /panel_demo [place]"
	end,
})

return { ids = demo_ids, report = report }
