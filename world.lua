-- Compiled panels placed in the world: ticking, edges between neighbouring
-- panels, VoxeLibre redstone (mesecons), face presses and the lamp display.
--
-- A panel lies flat with its grid facing up (MVP: floor placement only),
-- turned by the direction the player faced when placing it (4dir). Grid
-- north is the side away from the player, east their right, south toward
-- them, west their left. Panels turned the same way connect edge to edge,
-- cell for cell, and a floor of them settles instantly each tick, like
-- nested panels in a grid.
--
-- Mesecons: a side reads redstone as all 8 of its bits, and drives redstone
-- with the OR of its 8 output bits. Mesecons keeps output state in the node
-- name, so there is one node variant per set of driven sides.
--
-- No self-echo, world version. A redstone side is one wire, so it is one
-- bit, not 8: (1) a side's output is worked out as if its own redstone
-- input were off, or two edge cells on one side would echo each other's
-- input back out (and flicker); (2) a side can't tell its own redstone
-- output from someone else's, so while it drives redstone it ignores
-- redstone input, or two sides could hold each other on; (3) when a side
-- stops driving, mesecons turns the wire off later, from its action queue,
-- so the side ignores redstone input until that has run and it has read
-- the wire again.

local sim, library = ...
local grid, runtime, thumb, floor = sim.grid, sim.runtime, sim.thumb, sim.floor

local world = {}

local TICK_SECONDS = 0.1 -- 10 ticks per second, like Minecraft redstone
local MAX_CATCHUP_TICKS = 5 -- after a lag spike, run at most this many ticks at once
local FIXPOINT_EVALS_PER_PANEL = 64 -- cap on settling a wall within one tick
local ACTIVE_CHECK_TICKS = 10 -- how often to notice unloaded panels
local SAVE_TICKS = 100 -- how often to write running state to node meta
local BENCH_WINDOW = 100 -- ticks averaged by /panel_bench

local BITS, PORTS = grid.BITS, grid.PORTS
local BASE = "redstone_panels:compiled"

-- SIDES[dir][side]: world offset of grid side `side` for a panel turned `dir`.
-- The builtin placement sets dir from the placer toward the node, so
-- fourdir_to_dir(dir) points away from the player.
local SIDES = {}
for dir = 0, 3 do
	local away = core.fourdir_to_dir(dir)
	local right = vector.new(away.z, 0, -away.x)
	SIDES[dir] = { [0] = away, right, vector.multiply(away, -1), vector.multiply(right, -1) }
end
local UP = vector.new(0, 1, 0) -- the face, where the grid shows
local FACE_THICKNESS = 0.01
local PANEL_HEIGHT = 1 / 8 -- one layer: 8 panels stack to a full block
local PANEL_BOX = { -0.5, -0.5, -0.5, 0.5, -0.5 + PANEL_HEIGHT, 0.5 }

local function node_dir(node)
	return node.param2 % 4
end

local function side_of(dir, rule)
	for d = 0, 3 do
		if vector.equals(SIDES[dir][d], rule) then return d end
	end
	return nil
end

local function variant(mask)
	return mask == 0 and BASE or (BASE .. "_" .. mask)
end

local function has_bit(m, d)
	return m % 2 ^ (d + 1) >= 2 ^ d
end

local function mask_rules(dir, mask)
	local rules = {}
	for d = 0, 3 do
		if has_bit(mask, d) then rules[#rules + 1] = SIDES[dir][d] end
	end
	return rules
end

local panels = {} -- [hash] = panel record
local order = {} -- panel records, stable order for ticking
local links_dirty = true
local mesecon_in = {} -- [hash][side] = bool, kept even while a panel is asleep
local settling = {} -- [hash][side] = true: stopped driving, wire not read again yet
local sleeping = {} -- [hash] = pos: loaded but not active, woken when active again
world.keep_loaded = false -- smoke test: tick panels even without players nearby

local function any_side(out, side)
	for k = 0, BITS - 1 do
		if out[side * BITS + k] then return true end
	end
	return false
end

-- Face display -----------------------------------------------------------

local FACE_CELL_PX = 6 -- texture pixels per cell on a placed panel's face

local FACE_VIEW_RANGE = 48 -- faces further than this from every player are not redrawn

-- Prepared faces (thumb.face), one per compiled design.
local faces = setmetatable({}, { __mode = "k" })

-- Players' positions, read once per tick; faces out of their range wait.
local viewers = {}
world.all_faces = false -- benchmark: redraw every face, as if players were everywhere

local function in_view(pos)
	if world.all_faces then return true end
	for _, v in ipairs(viewers) do
		if vector.distance(v, pos) <= FACE_VIEW_RANGE then return true end
	end
	return false
end

-- A thin flat box lying on top of the panel. Its top texture follows the
-- node top-face convention (texture up = +z), and yaw turns it so texture
-- up points to grid north.
core.register_entity("redstone_panels:face", {
	initial_properties = {
		visual = "cube",
		visual_size = { x = 1, y = FACE_THICKNESS, z = 1 },
		textures = { "blank.png", "blank.png", "blank.png", "blank.png", "blank.png", "blank.png" },
		physical = false,
		pointable = false,
		static_save = false,
		collisionbox = { 0, 0, 0, 0, 0, 0 },
	},
})

-- Copy the live values of `nodes` into `into`; true if any differed.
local function copy_changed(vals, nodes, into)
	local changed = false
	for j, v in ipairs(nodes) do
		local on = vals[v] == true
		if into[j] ~= on then
			into[j] = on
			changed = true
		end
	end
	return changed
end

-- Redraw the face if its lamps or probes changed and a player is near
-- enough to see it. No garbage unless it does.
local function update_face(P)
	local alive = P.entity and P.entity:is_valid()
	-- Nothing evaluated since the last redraw: the face can't have changed.
	if P.face_runs == P.state.runs and alive then return end
	if alive and not in_view(P.pos) then return end
	P.face_runs = P.state.runs
	P.face_lamps, P.face_probes = P.face_lamps or {}, P.face_probes or {}
	local vals = P.state.vals
	local lamps_changed = copy_changed(vals, P.net.lamps, P.face_lamps)
	local probes_changed = copy_changed(vals, P.net.probes, P.face_probes)
	if not (lamps_changed or probes_changed) and alive then return end
	faces[P.net] = faces[P.net] or thumb.face(P.cells, P.net, FACE_CELL_PX)
	local tex = thumb.face_texture(faces[P.net], P.face_lamps, P.face_probes)
	if not alive then
		local at = vector.offset(P.pos, 0, -0.5 + PANEL_HEIGHT + FACE_THICKNESS / 2 + 0.001, 0)
		for _, obj in ipairs(core.get_objects_inside_radius(at, 0.1)) do
			local ent = obj:get_luaentity()
			if ent and ent.name == "redstone_panels:face" then obj:remove() end
		end
		P.entity = core.add_entity(at, "redstone_panels:face")
		if not P.entity then return end
		P.entity:set_yaw(core.dir_to_yaw(SIDES[P.dir][0]))
	end
	P.entity:set_properties({ textures = { tex, "blank.png", "blank.png", "blank.png", "blank.png", "blank.png" } })
end

-- Activation -------------------------------------------------------------

local function save_state(P)
	local bits = {}
	for i, n in ipairs(P.net.nodes) do
		if n.op == "reg" then bits[#bits + 1] = P.state.reg[i] and "1" or "0" end
	end
	core.get_meta(P.pos):set_string("regs", table.concat(bits))
end

local function load_state(P)
	local bits = core.get_meta(P.pos):get_string("regs")
	local k = 0
	for _, n in ipairs(P.net.nodes) do
		if n.op == "reg" then k = k + 1 end
	end
	if #bits ~= k then return end
	k = 0
	for i, n in ipairs(P.net.nodes) do
		if n.op == "reg" then
			k = k + 1
			P.state.reg[i] = bits:sub(k, k) == "1"
		end
	end
end

local deactivate

function world.activate(pos)
	pos = vector.round(pos)
	local hash = core.hash_node_position(pos)
	local node = core.get_node(pos)
	local id = core.get_meta(pos):get_int("panel_id")
	local old = panels[hash]
	if old then
		if core.get_item_group(node.name, "redstone_panel") > 0 and id == old.id then return old end
		deactivate(old) -- something else replaced it; its state is not ours
	end
	sleeping[hash] = nil
	local net, err = library.compiled(id)
	if not net then
		core.log("warning", ("[redstone_panels] panel at %s: %s"):format(core.pos_to_string(pos), err))
		return nil
	end
	local P = {
		pos = pos, hash = hash, dir = node_dir(node), id = id, net = net,
		cells = library.get(id).cells, state = runtime.new(net), out = {}, inputs = {}, neighbors = {},
		mask = core.get_item_group(node.name, "redstone_panel") - 1,
	}
	load_state(P)
	if not mesecon_in[hash] then
		mesecon_in[hash] = {}
		for d = 0, 3 do mesecon_in[hash][d] = mesecon.is_powered(pos, SIDES[P.dir][d]) and true or false end
	end
	panels[hash] = P
	order[#order + 1] = P
	links_dirty = true
	runtime.eval(P.state, {})
	update_face(P)
	return P
end

-- Forget everything kept for a position whose panel is gone.
local function forget(hash)
	mesecon_in[hash], settling[hash], sleeping[hash] = nil, nil, nil
end

-- With `asleep`, the panel is still there but its block is not active: save
-- its state and wake it when the block is active again. Otherwise the panel
-- is gone, replaced or unloaded, and its state is not saved (the position
-- may hold something else now, or nothing that can be written to).
function deactivate(P, asleep)
	if asleep then
		save_state(P)
		sleeping[P.hash] = P.pos
	else
		forget(P.hash)
	end
	if P.entity then P.entity:remove() end
	panels[P.hash] = nil
	for i, Q in ipairs(order) do
		if Q == P then
			table.remove(order, i)
			break
		end
	end
	links_dirty = true
end

local function relink()
	for _, P in ipairs(order) do
		for d = 0, 3 do
			local Q = panels[core.hash_node_position(vector.add(P.pos, SIDES[P.dir][d]))]
			P.neighbors[d] = Q and Q.dir == P.dir and Q or nil
		end
	end
	floor.relink(order)
	links_dirty = false
end

-- Ticking ------------------------------------------------------------------

-- Redstone input of a side with no linked panel (see "No self-echo" above).
local function external(P, d)
	local mi, st = mesecon_in[P.hash], settling[P.hash]
	return mi and mi[d] and not has_bit(P.mask, d) and not (st and st[d])
end

local function side_has_input(inputs, d)
	return inputs[d * BITS] == true -- a redstone side sets all 8 bits alike
end

-- Rule (1): would side d of P still drive redstone with its own redstone
-- input off? A linked neighbour can hand that input back to P on another
-- edge cell, so settle P's whole group that way, then settle it again for
-- real (only after this may the group commit).
local function quiet_drives(P, d)
	local group = P.group
	local function quiet(Q, side)
		return not (Q == P and side == d) and external(Q, side)
	end
	floor.settle(group, quiet, FIXPOINT_EVALS_PER_PANEL * #group)
	local drives = any_side(P.out, d)
	floor.settle(group, external, FIXPOINT_EVALS_PER_PANEL * #group)
	return drives
end

-- Sides that drive redstone this tick. A side that both has redstone input
-- and would drive is checked again with its input off.
local function redstone_mask(P)
	local mask = 0
	for d = 0, 3 do
		if not P.neighbors[d] and any_side(P.out, d) then
			if not side_has_input(P.inputs, d) or quiet_drives(P, d) then mask = mask + 2 ^ d end
		end
	end
	return mask
end

local function set_mask(P, mask)
	if mask == P.mask then return end
	local old = P.mask
	P.mask = mask
	P.mask_changes = (P.mask_changes or 0) + 1 -- the smoke test uses this to catch flicker
	core.swap_node(P.pos, { name = variant(mask), param2 = core.get_node(P.pos).param2 })
	local on, off = {}, {}
	for d = 0, 3 do
		local was, now = has_bit(old, d), has_bit(mask, d)
		if now and not was then on[#on + 1] = SIDES[P.dir][d] end
		if was and not now then
			off[#off + 1] = SIDES[P.dir][d]
			settling[P.hash] = settling[P.hash] or {}
			settling[P.hash][d] = true
		end
	end
	if #on > 0 then mesecon.receptor_on(P.pos, on) end
	if #off > 0 then
		mesecon.receptor_off(P.pos, off)
		-- Priority 0 runs after receptor_off (priority 1) in the same queue step.
		mesecon.queue:add_action(P.pos, "redstone_panels_settled", {}, nil, { "redstone_panels_settled" }, 0)
	end
end

-- Rule (3): mesecons has turned the wire off, unless something else still
-- powers it. Either way, the wire now tells the truth.
mesecon.queue:add_function("redstone_panels_settled", function(pos)
	local hash = core.hash_node_position(pos)
	local sides, node = settling[hash], core.get_node_or_nil(pos)
	settling[hash] = nil
	if not (sides and node and mesecon_in[hash]) then return end
	for d in pairs(sides) do
		mesecon_in[hash][d] = mesecon.is_powered(pos, SIDES[node_dir(node)][d]) and true or false
	end
end)

local tick_count = 0
-- Last BENCH_WINDOW ticks: total time, and the part spent settling (eval),
-- committing and driving redstone, and redrawing faces.
local bench = { times = {}, settle = {}, commit = {}, face = {}, next = 1 }

local function tick()
	local started = core.get_us_time()
	tick_count = tick_count + 1

	if tick_count % ACTIVE_CHECK_TICKS == 0 then
		for i = #order, 1, -1 do
			local P = order[i]
			local node = core.get_node_or_nil(P.pos)
			if not node or core.get_item_group(node.name, "redstone_panel") == 0
					or core.get_meta(P.pos):get_int("panel_id") ~= P.id then
				deactivate(P)
			elseif not world.keep_loaded and not core.compare_block_status(P.pos, "active") then
				deactivate(P, true)
			end
		end
		-- The LBM only runs when a block loads, so wake sleepers here. An
		-- unloaded one is left to the LBM.
		for hash, pos in pairs(sleeping) do
			local node = core.get_node_or_nil(pos)
			if not node or core.get_item_group(node.name, "redstone_panel") == 0 then
				forget(hash)
			elseif world.keep_loaded or core.compare_block_status(pos, "active") then
				world.activate(pos)
			end
		end
	end
	if links_dirty then relink() end
	viewers = {}
	for _, player in ipairs(core.get_connected_players()) do viewers[#viewers + 1] = player:get_pos() end
	local settle_started = core.get_us_time()

	-- Settle the instant part of every wall (sim/floor.lua), then advance everything.
	if not floor.settle(order, external, FIXPOINT_EVALS_PER_PANEL * #order) then
		core.log("warning", "[redstone_panels] a panel wall did not settle within one tick")
	end

	-- Each panel's last eval above used its final inputs, so commit from it
	-- instead of evaluating again. Masks first: the redstone check settles
	-- whole groups again, which must not see a neighbour already committed.
	local commit_started = core.get_us_time()
	local face_us = 0
	for _, P in ipairs(order) do P.next_mask = redstone_mask(P) end
	for _, P in ipairs(order) do
		runtime.commit(P.state)
		set_mask(P, P.next_mask)
		local face_started = core.get_us_time()
		update_face(P)
		face_us = face_us + core.get_us_time() - face_started
		if tick_count % SAVE_TICKS == 0 then save_state(P) end
	end

	local now = core.get_us_time()
	bench.times[bench.next] = now - started
	bench.settle[bench.next] = commit_started - settle_started
	bench.commit[bench.next] = now - commit_started - face_us
	bench.face[bench.next] = face_us
	bench.next = bench.next % BENCH_WINDOW + 1
end

local elapsed = 0
core.register_globalstep(function(dtime)
	elapsed = elapsed + dtime
	local n = 0
	while elapsed >= TICK_SECONDS and n < MAX_CATCHUP_TICKS do
		elapsed = elapsed - TICK_SECONDS
		n = n + 1
		tick()
	end
	if n == MAX_CATCHUP_TICKS then elapsed = 0 end
end)

core.register_on_shutdown(function()
	for _, P in ipairs(order) do save_state(P) end
end)

-- Nodes --------------------------------------------------------------------

-- Grid cell under the point where `clicker` is pointing on the top face.
local function pressed_cell(pos, node, clicker, pointed)
	if not (pointed and pointed.type == "node" and clicker) then return nil end
	local dir = node_dir(node)
	if not vector.equals(vector.subtract(pointed.above, pointed.under), UP) then return nil end
	-- core.pointed_thing_to_face_pos assumes a full cube, so intersect the
	-- look ray with the panel's real top instead.
	local eye = clicker:get_pos()
	eye.y = eye.y + clicker:get_properties().eye_height + clicker:get_eye_offset().y / 10
	local look = clicker:get_look_dir()
	if look.y >= 0 then return nil end
	local t = (pos.y + PANEL_BOX[5] - eye.y) / look.y
	local rel = vector.subtract(vector.add(eye, vector.multiply(look, t)), pos)
	local u = vector.dot(rel, SIDES[dir][1]) + 0.5
	local v = 0.5 - vector.dot(rel, SIDES[dir][0])
	local x = math.max(1, math.min(grid.SIZE, math.floor(u * grid.SIZE) + 1))
	local y = math.max(1, math.min(grid.SIZE, math.floor(v * grid.SIZE) + 1))
	return grid.index(x, y)
end

local side_tile = "[fill:16x16:#3a3a3a"
local front_tile = "[fill:16x16:#3a3a3a^[fill:14x14:1,1:#1e1e1e"

for mask = 0, 15 do
	core.register_node(variant(mask), {
		description = "Redstone Panel",
		tiles = { front_tile, side_tile, side_tile, side_tile, side_tile, side_tile },
		drawtype = "nodebox",
		node_box = { type = "fixed", fixed = PANEL_BOX },
		paramtype = "light",
		sunlight_propagates = true,
		paramtype2 = "4dir",
		is_ground_content = false,
		drop = "",
		groups = {
			pickaxey = 1, not_opaque = 1, mesecon_effector_off = 1, mesecon = 2,
			redstone_panel = mask + 1, not_in_creative_inventory = 1, -- only useful with a panel id
		},
		stack_max = 1,
		_mcl_blast_resistance = 1,
		_mcl_hardness = 1,
		after_place_node = function(pos, _placer, itemstack)
			local id = library.item_id(itemstack)
			if not id then
				core.remove_node(pos)
				return true
			end
			core.get_meta(pos):set_int("panel_id", id)
			core.get_meta(pos):set_string("infotext", library.describe(id))
			world.activate(pos)
		end,
		after_dig_node = function(pos, _oldnode, oldmeta, digger)
			local hash = core.hash_node_position(pos)
			if panels[hash] then deactivate(panels[hash]) end
			forget(hash)
			local id = tonumber(oldmeta.fields and oldmeta.fields.panel_id)
			if id and library.get(id) then core.handle_node_drops(pos, { library.item(id) }, digger) end
		end,
		on_rightclick = function(pos, node, clicker, itemstack, pointed)
			local cell = pressed_cell(pos, node, clicker, pointed)
			local P = panels[core.hash_node_position(pos)] or world.activate(pos)
			if cell and P then runtime.press(P.state, cell) end
			return itemstack
		end,
		mesecons = {
			receptor = {
				state = mask == 0 and mesecon.state.off or mesecon.state.on,
				rules = function(n) return mask_rules(node_dir(n), mask) end,
			},
			effector = {
				rules = function(n) return mask_rules(node_dir(n), 15) end,
				action_change = function(pos, n, rule, newstate)
					local d = side_of(node_dir(n), rule)
					if d == nil then return end
					local hash = core.hash_node_position(pos)
					mesecon_in[hash] = mesecon_in[hash] or {}
					mesecon_in[hash][d] = newstate == mesecon.state.on
				end,
			},
		},
	})
end

core.register_lbm({
	label = "Start redstone panels",
	name = "redstone_panels:activate",
	nodenames = { "group:redstone_panel" },
	run_at_every_load = true,
	action = function(pos) world.activate(pos) end,
})

-- Benchmark ----------------------------------------------------------------

function world.bench()
	local nodes, gates, regs = 0, 0, 0
	for _, P in ipairs(order) do
		local s = sim.compile.stats(P.net)
		nodes, gates, regs = nodes + s.nodes, gates + s.gates, regs + s.regs
	end
	local total, worst, n = 0, 0, 0
	for _, t in pairs(bench.times) do
		total, worst, n = total + t, math.max(worst, t), n + 1
	end
	local function avg(list)
		local sum = 0
		for _, t in pairs(list) do sum = sum + t end
		return n > 0 and sum / n / 1000 or 0
	end
	return {
		panels = #order, nodes = nodes, gates = gates, regs = regs, ticks = n,
		avg_ms = n > 0 and total / n / 1000 or 0, max_ms = worst / 1000,
		settle_ms = avg(bench.settle), commit_ms = avg(bench.commit), face_ms = avg(bench.face),
	}
end

-- Start a fresh measuring window.
function world.reset_bench()
	bench.times, bench.settle, bench.commit, bench.face, bench.next = {}, {}, {}, {}, 1
end

core.register_chatcommand("panel_bench", {
	description = "Server time per tick and active gate count for redstone panels",
	func = function()
		local b = world.bench()
		return true, ("%d panels, %d gates, %d registers; tick %.3f ms avg, %.3f ms max (last %d ticks); "
			.. "settle %.3f, commit %.3f, faces %.3f ms"):format(
			b.panels, b.gates, b.regs, b.avg_ms, b.max_ms, b.ticks, b.settle_ms, b.commit_ms, b.face_ms)
	end,
})

world.panels = panels
world.SIDES = SIDES
return world
