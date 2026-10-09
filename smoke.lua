-- Smoke scenario, run by scripts/smoke.sh only. Builds two panels side by
-- side with redstone after them, presses a lever on the first, and checks
-- that the signal crosses both panels, lights a lamp, and powers the wire.
-- A third panel is driven by a redstone block on its west side.

local sim, library, world, editor = ...
local grid = sim.grid

local ORIGIN = vector.new(0, 100, 0)
local SETTLE_SECONDS = 2

local function fail(msg)
	core.log("error", "[redstone_panels] smoke test: " .. msg)
	core.request_shutdown("smoke test failed", false, 0)
end

local function check(ok, msg)
	if not ok then fail(msg) end
	return ok
end

local function design(list)
	local cells = {}
	for _, e in ipairs(list) do cells[grid.index(e[1], e[2])] = e[3] end
	return cells
end

local function run()
	world.keep_loaded = true
	for x = -6, 6 do
		for y = -2, 4 do
			for z = -2, 6 do core.set_node(vector.offset(ORIGIN, x, y, z), { name = "air" }) end
		end
	end

	-- Editor: place parts the way a player's clicks would.
	local cells = {}
	assert(editor.apply(cells, grid.index(2, 2), "block") == nil)
	assert(editor.apply(cells, grid.index(3, 2), "torch") == nil)
	assert(cells[grid.index(3, 2)].attach == 3, "torch stands on the block to its west")
	assert(editor.apply(cells, grid.index(2, 2), "erase") == nil)
	assert(cells[grid.index(3, 2)] == nil, "torch falls off when its block goes")
	core.set_node(ORIGIN, { name = "redstone_panels:panel" })
	assert(#editor.formspec(ORIGIN, "dust") > 0)

	-- A: a lever on its east edge. B: dust straight across, a lamp under it.
	local a = assert(library.add(design({ { 8, 4, { kind = "lever" } } }), "lever", "smoke"))
	local row = { { 4, 5, { kind = "lamp" } } }
	for x = 1, 8 do row[#row + 1] = { x, 4, { kind = "dust" } } end
	local b = assert(library.add(design(row), "wire", "smoke"))
	-- C nests B, to check nesting compiles in-game.
	local nest = design({ { 4, 4, { kind = "panel", id = b, speed = 1 } } })
	assert(library.add(nest, "nest", "smoke"))

	-- Items and nested cells show a thumbnail and a tooltip.
	local meta = library.item(b):get_meta()
	assert(meta:get_string("inventory_image"):find("^%[fill:"), "item has a thumbnail")
	assert(meta:get_string("description"):find("Edges: E in/out, W in/out", 1, true), "item tooltip lists edges")

	-- Workbench: load a compiled panel, edit, commit; unchanged commits reuse the entry.
	local inv = core.get_meta(ORIGIN):get_inventory()
	assert(inv:get_size("panel") == 1, "workbench has a panel slot")
	assert(not editor.formspec(ORIGIN, "dust"):find("c_1_1", 1, true), "grid is locked while the slot is empty")
	local c = library.find(nest, "nest")
	inv:set_stack("panel", 1, library.item(c))
	editor.load(ORIGIN)
	local fs = editor.formspec(ORIGIN, "dust")
	assert(fs:find("tooltip[c_4_4;", 1, true), "nested cell has a tooltip")
	assert(library.item_id(assert(editor.commit(ORIGIN, "smoke"))) == c, "unchanged design keeps its id")
	local draft = core.deserialize(core.get_meta(ORIGIN):get_string("cells"))
	assert(editor.apply(draft, grid.index(1, 1), "dust") == nil)
	core.get_meta(ORIGIN):set_string("cells", core.serialize(draft))
	local edited = library.item_id(assert(editor.commit(ORIGIN, "smoke")))
	assert(edited and edited ~= c, "edited design gets a new id")
	assert(library.item_id(inv:get_stack("panel", 1)) == edited, "slot holds the new panel")
	assert(library.get(c), "the old entry is kept")
	-- A blank panel with nothing drawn stays blank.
	inv:set_stack("panel", 1, ItemStack("redstone_panels:blank"))
	editor.load(ORIGIN)
	assert(assert(editor.commit(ORIGIN, "smoke")):get_name() == "redstone_panels:blank")

	-- Turned 0: grid north is +z, east is +x.
	local pa, pb = vector.offset(ORIGIN, 2, 0, 0), vector.offset(ORIGIN, 3, 0, 0)
	local wire = vector.offset(ORIGIN, 4, 0, 0)
	for _, e in ipairs({ { pa, a }, { pb, b } }) do
		core.set_node(e[1], { name = "redstone_panels:compiled", param2 = 0 })
		core.get_meta(e[1]):set_int("panel_id", e[2])
		assert(world.activate(e[1]), "panel activates")
	end
	-- Place the wire like a player would, so mesecons connects it.
	core.set_node(vector.offset(wire, 0, -1, 0), { name = "mcl_core:stone" })
	core.place_node(wire, { name = "mesecons:wire_00000000_off" })
	-- A redstone block west of panel E (another copy of B).
	local pe = vector.offset(ORIGIN, 2, 0, 3)
	core.set_node(pe, { name = "redstone_panels:compiled", param2 = 0 })
	core.get_meta(pe):set_int("panel_id", b)
	assert(world.activate(pe), "panel activates")
	core.set_node(vector.offset(pe, -1, -1, 0), { name = "mcl_core:stone" })
	core.place_node(vector.offset(pe, -1, 0, 0), { name = "mesecons_torch:redstoneblock" })
	-- F: B turned 1 (grid north is +x), so grid west is +z and east is -z.
	local pf = vector.offset(ORIGIN, 5, 0, 3)
	core.set_node(pf, { name = "redstone_panels:compiled", param2 = 1 })
	core.get_meta(pf):set_int("panel_id", b)
	assert(world.activate(pf), "panel activates")
	core.set_node(vector.offset(pf, 0, -1, 1), { name = "mcl_core:stone" })
	core.place_node(vector.offset(pf, 0, 0, 1), { name = "mesecons_torch:redstoneblock" })
	-- G: two dust cells on the north edge, redstone on the north side
	-- (design "this flickers" from world test3). It must drive nothing and
	-- stay still, not echo its own input back out and flicker.
	local g = assert(library.add(design({ { 7, 1, { kind = "dust" } }, { 8, 1, { kind = "dust" } } }), "corner", "smoke"))
	local pg = vector.offset(ORIGIN, -3, 0, 3)
	core.set_node(pg, { name = "redstone_panels:compiled", param2 = 0 })
	core.get_meta(pg):set_int("panel_id", g)
	assert(world.activate(pg), "panel activates")
	core.set_node(vector.offset(pg, 0, -1, 1), { name = "mcl_core:stone" })
	core.place_node(vector.offset(pg, 0, 0, 1), { name = "mesecons_torch:redstoneblock" })
	local A = world.panels[core.hash_node_position(pa)]
	local B = world.panels[core.hash_node_position(pb)]
	sim.runtime.press(A.state, grid.index(8, 4))

	core.after(SETTLE_SECONDS, function()
		local lamps = sim.runtime.lamp_list(B.state)
		if not check(lamps[1] == true, "lamp on panel B did not light") then return end
		local face = B.entity and B.entity:get_properties().textures[1] or ""
		local live = sim.thumb.LIVE
		if not check(face:find(live.dust[2], 1, true) and face:find(live.lamp[2], 1, true),
				"panel B's face should show lit dust and a lit lamp") then
			return
		end
		local name = core.get_node(pb).name
		if not check(name == "redstone_panels:compiled_2", "panel B should drive only its east side, is " .. name) then
			return
		end
		local ename = core.get_node(pe).name
		if not check(ename == "redstone_panels:compiled_2", "redstone should cross panel E, it is " .. ename) then
			return
		end
		local fname = core.get_node(pf).name
		if not check(fname == "redstone_panels:compiled_2", "redstone should cross turned panel F, it is " .. fname) then
			return
		end
		local G = world.panels[core.hash_node_position(pg)]
		local changes = G.mask_changes or 0
		if not check(changes <= 1, ("panel G flickers: its outputs changed %d times"):format(changes)) then
			return
		end
		local wname = core.get_node(wire).name
		if not check(wname:find("_on$") ~= nil, "wire after panel B is not powered: " .. wname) then return end
		local bench = world.bench()
		core.log("action", ("[redstone_panels] bench: %d panels, %.3f ms avg tick"):format(bench.panels, bench.avg_ms))
		core.log("action", "[redstone_panels] smoke test OK")
		core.request_shutdown("smoke test done", false, 0)
	end)
end

-- Mesecons ignores everything for its first few seconds (its "resumetime").
local START_SECONDS = 5

core.after(START_SECONDS, function()
	core.emerge_area(vector.offset(ORIGIN, -8, -8, -8), vector.offset(ORIGIN, 8, 8, 8),
		function(_, _, remaining)
			if remaining == 0 then
				local ok, err = pcall(run)
				if not ok then fail(tostring(err)) end
			end
		end)
end)
