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

local sleep_and_wake

local function run()
	world.keep_loaded = true
	world.all_faces = true
	for x = -6, 6 do
		for y = -2, 4 do
			for z = -2, 6 do core.set_node(vector.offset(ORIGIN, x, y, z), { name = "air" }) end
		end
	end

	-- Workbench: drag parts in and out the way a player would, through the
	-- node's inventory callbacks, with a stand-in player.
	core.set_node(ORIGIN, { name = "redstone_panels:panel" })
	local bench = core.registered_nodes["redstone_panels:panel"]
	local inv = core.get_meta(ORIGIN):get_inventory()
	local pinv = core.create_detached_inventory("redstone_panels_smoke_player", {})
	pinv:set_size("main", 36)
	local player = {
		get_player_name = function() return "smoke" end,
		get_pos = function() return ORIGIN end,
		get_inventory = function() return pinv end,
		is_player = function() return true end,
	}
	local function put(list, k, item)
		local stack = ItemStack(item)
		local n = bench.allow_metadata_inventory_put(ORIGIN, list, k, stack, player)
		if n > 0 then
			stack:set_count(n)
			inv:set_stack(list, k, stack)
			bench.on_metadata_inventory_put(ORIGIN, list, k, stack, player)
		end
		return n
	end
	local function take(list, k)
		local stack = inv:get_stack(list, k)
		local n = bench.allow_metadata_inventory_take(ORIGIN, list, k, stack, player)
		if n == 0 then return nil end
		stack = inv:get_stack(list, k) -- taking the panel swaps in the compiled one first
		inv:set_stack(list, k, ItemStack(""))
		bench.on_metadata_inventory_take(ORIGIN, list, k, stack, player)
		return stack
	end
	local function slot(x, y) return editor.cell_slot(grid.index(x, y)) end
	local function draft() return core.deserialize(core.get_meta(ORIGIN):get_string("cells")) end
	local STONE, TORCH = "mcl_core:stone", "mesecons_torch:mesecon_torch_on"

	assert(#editor.formspec(ORIGIN) > 0)
	for _, item in ipairs({ "redstone_panels:panel", "redstone_panels:blank", "redstone_panels:bulb" }) do
		assert(core.get_all_craft_recipes(item), "no recipe for " .. item)
	end
	assert(put("grid", slot(2, 2), STONE) == 0, "the grid is locked while the slot is empty")
	assert(put("panel", 1, "redstone_panels:blank") == 1)
	assert(put("grid", slot(2, 2), STONE) == 1 and put("grid", slot(3, 3), STONE) == 1)
	assert(put("grid", slot(6, 6), TORCH) == 0, "a torch needs a base")
	assert(put("grid", slot(3, 2), TORCH) == 1)
	assert(draft()[grid.index(3, 2)].attach == 2, "torch stands on the block below")
	assert(take("grid", slot(3, 2)):get_name() == TORCH)
	assert(put("grid", slot(3, 2), TORCH) == 1)
	assert(draft()[grid.index(3, 2)].attach == 3, "putting it back picks the next block")
	take("grid", slot(3, 3))
	take("grid", slot(2, 2))
	assert(draft()[grid.index(3, 2)] == nil and inv:get_stack("grid", slot(3, 2)):is_empty(), "torch fell off")
	assert(pinv:contains_item("main", TORCH), "the fallen torch went back to the player")
	assert(put("grid", slot(1, 1), "mesecons:redstone") == 1)
	local first = take("panel", 1)
	local first_id = assert(library.item_id(first), "taking the panel compiles it")
	assert(inv:get_stack("grid", slot(1, 1)):is_empty() and next(draft()) == nil, "the parts went into the panel")

	-- A: a lever on its east edge. B: dust straight across, a lamp under it.
	local a = assert(library.add(design({ { 8, 4, { kind = "lever" } } }), "lever", "smoke"))
	local row = { { 4, 5, { kind = "lamp" } } }
	for x = 1, 8 do row[#row + 1] = { x, 4, { kind = "dust" } } end
	local b = assert(library.add(design(row), "wire", "smoke"))
	-- C nests B, to check nesting compiles in-game.
	local nest = design({ { 4, 4, { kind = "panel", id = b, speed = 1 } } })
	assert(library.add(nest, "nest", "smoke"))

	-- Items show a thumbnail and a tooltip.
	local meta = library.item(b):get_meta()
	assert(meta:get_string("inventory_image"):find("^%[fill:"), "item has a thumbnail")
	assert(meta:get_string("description"):find("Edges: E in/out, W in/out", 1, true), "item tooltip lists edges")

	-- Loading a compiled panel gives its parts as items; unchanged, it keeps its id.
	local c = library.find(nest, "nest")
	assert(put("panel", 1, library.item(c)) == 1)
	assert(library.item_id(inv:get_stack("grid", slot(4, 4))) == b, "nested panel is an item in the grid")
	assert(library.item_id(take("panel", 1)) == c, "unchanged design keeps its id")
	assert(put("panel", 1, library.item(c)) == 1)
	assert(put("grid", slot(1, 1), "mesecons:redstone") == 1)
	local edited = library.item_id(take("panel", 1))
	assert(edited and edited ~= c, "edited design gets a new id")
	assert(library.get(c), "the old entry is kept")
	-- Taking every part out leaves a blank panel.
	assert(put("panel", 1, first) == 1)
	assert(take("grid", slot(1, 1)):get_name() == ItemStack("mesecons:redstone"):get_name())
	assert(take("panel", 1):get_name() == "redstone_panels:blank", "an empty grid gives a blank")

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
	-- H1, H2: a wire touching two bits on each side ("locking cell" from
	-- world "main test"), side by side, redstone west of H1. H2 echoes H1's
	-- input back to it on the other bit; H1 must not count that as its own
	-- output and turn into a clock.
	local h = {}
	for x = 1, 8 do h[#h + 1] = { x, 4, { kind = "dust" } } end
	h[#h + 1] = { 1, 5, { kind = "dust" } }
	h[#h + 1] = { 8, 5, { kind = "dust" } }
	h = assert(library.add(design(h), "two bit wire", "smoke"))
	local ph1, ph2 = vector.offset(ORIGIN, -3, 0, 0), vector.offset(ORIGIN, -2, 0, 0)
	for _, pos in ipairs({ ph1, ph2 }) do
		core.set_node(pos, { name = "redstone_panels:compiled", param2 = 0 })
		core.get_meta(pos):set_int("panel_id", h)
		assert(world.activate(pos), "panel activates")
	end
	core.set_node(vector.offset(ph1, -1, -1, 0), { name = "mcl_core:stone" })
	core.place_node(vector.offset(ph1, -1, 0, 0), { name = "mesecons_torch:redstoneblock" })
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
		local H1 = world.panels[core.hash_node_position(ph1)]
		changes = H1.mask_changes or 0
		if not check(changes == 0, ("panel H1 flickers: its outputs changed %d times"):format(changes)) then
			return
		end
		local h2name = core.get_node(ph2).name
		if not check(h2name == "redstone_panels:compiled_2", "redstone should cross H1 and H2, H2 is " .. h2name) then
			return
		end
		local wname = core.get_node(wire).name
		if not check(wname:find("_on$") ~= nil, "wire after panel B is not powered: " .. wname) then return end
		local bench = world.bench()
		core.log("action", ("[redstone_panels] bench: %d panels, %.3f ms avg tick"):format(bench.panels, bench.avg_ms))

		-- Lever off: once B stops driving, the wire it powered must not
		-- echo back into B and light its lamp while mesecons catches up.
		sim.runtime.press(A.state, grid.index(8, 4))
		local echoed, watching = false, true
		local function watch()
			if watching and B.mask == 0 and sim.runtime.lamp_list(B.state)[1] then echoed = true end
		end
		core.register_globalstep(watch)
		core.after(SETTLE_SECONDS, function()
			watching = false
			if not check(not echoed, "panel B read its own redstone back after it stopped driving") then return end
			if not check(not sim.runtime.lamp_list(B.state)[1], "lamp on panel B stayed lit") then return end
			wname = core.get_node(wire).name
			if not check(wname:find("_off$") ~= nil, "wire after panel B stayed powered: " .. wname) then return end
			sleep_and_wake(A, pa)
		end)
	end)
end

-- Without players no block is active, so panels fall asleep once
-- keep_loaded is off, and must wake by themselves (not only on block load)
-- with their state.
sleep_and_wake = function(A, pa)
	sim.runtime.press(A.state, grid.index(8, 4)) -- lever on again, to see it survive
	core.after(SETTLE_SECONDS, function()
		world.keep_loaded = false
	end)
	core.after(2 * SETTLE_SECONDS, function()
		local hash = core.hash_node_position(pa)
		if not check(world.panels[hash] == nil, "panel A should be asleep with no players near") then return end
		world.keep_loaded = true
		core.after(SETTLE_SECONDS, function()
			local woken = world.panels[hash]
			if not check(woken ~= nil and woken ~= A, "panel A did not wake up") then return end
			if not check(sim.runtime.probes(woken.state)[1] == true, "panel A's lever lost its state while asleep") then
				return
			end
			-- A different panel in the same spot is a new panel, not the old one.
			local other = assert(library.add(design({ { 1, 1, { kind = "lever" } } }), "other", "smoke"))
			core.get_meta(pa):set_int("panel_id", other)
			local replaced = world.activate(pa)
			if not check(replaced and replaced.id == other, "activate returned the replaced panel") then return end
			core.log("action", "[redstone_panels] smoke test OK")
			core.request_shutdown("smoke test done", false, 0)
		end)
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
