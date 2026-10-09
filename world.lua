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
-- redstone input, or two sides could hold each other on.

local sim, library = ...
local grid, runtime, thumb = sim.grid, sim.runtime, sim.thumb

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

local function mask_rules(dir, mask)
	local rules = {}
	for d = 0, 3 do
		if mask % 2 ^ (d + 1) >= 2 ^ d then rules[#rules + 1] = SIDES[dir][d] end
	end
	return rules
end

local panels = {} -- [hash] = panel record
local order = {} -- panel records, stable order for ticking
local links_dirty = true
local mesecon_in = {} -- [hash][side] = bool, kept even while a panel is inactive
world.keep_loaded = false -- smoke test: tick panels even without players nearby

local function any_side(out, side)
	for k = 0, BITS - 1 do
		if out[side * BITS + k] then return true end
	end
	return false
end

-- Face display -----------------------------------------------------------

local FACE_CELL_PX = 6 -- texture pixels per cell on a placed panel's face

-- The panel's own cells with their live state, one level deep. A nested
-- panel is a plain tile with a lamp square inside if it has lamps (lit if
-- any of them is: MVP on/off, no averaging yet). Lamps, buttons and levers
-- show their real state, so IO always reads true.
local function face_texture(P, lamps, probes)
	local colors, inner, live = {}, {}, thumb.LIVE
	for j, c in ipairs(P.net.probe_cells) do
		colors[c] = live[P.cells[c].kind][probes[j] and 2 or 1]
	end
	local lit = {}
	for j, on in ipairs(lamps) do
		local c = P.net.lamp_cells[j]
		lit[c] = lit[c] or on
	end
	for c, on in pairs(lit) do
		local color = live.lamp[on and 2 or 1]
		if P.cells[c].kind == "panel" then inner[c] = color else colors[c] = color end
	end
	return thumb.texture(P.cells, { cell_px = FACE_CELL_PX, colors = colors, inner = inner })
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

local function update_face(P)
	local lamps, probes = runtime.lamp_list(P.state), runtime.probes(P.state)
	local key = {}
	for _, on in ipairs(lamps) do key[#key + 1] = on and "1" or "0" end
	key[#key + 1] = "|"
	for _, on in ipairs(probes) do key[#key + 1] = on and "1" or "0" end
	key = table.concat(key)
	if key == P.face_key and P.entity and P.entity:get_pos() then return end
	P.face_key = key
	local tex = face_texture(P, lamps, probes)
	if not (P.entity and P.entity:get_pos()) then
		local at = vector.offset(P.pos, 0, 0.5 + FACE_THICKNESS / 2 + 0.001, 0)
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

function world.activate(pos)
	pos = vector.round(pos)
	local hash = core.hash_node_position(pos)
	if panels[hash] then return panels[hash] end
	local node = core.get_node(pos)
	local id = core.get_meta(pos):get_int("panel_id")
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

local function deactivate(P, keep_input)
	save_state(P)
	if P.entity then P.entity:remove() end
	panels[P.hash] = nil
	if not keep_input then mesecon_in[P.hash] = nil end
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
	links_dirty = false
end

-- Ticking ------------------------------------------------------------------

local function gather(P)
	local inputs, mi = {}, mesecon_in[P.hash] or {}
	for d = 0, 3 do
		local Q = P.neighbors[d]
		local opp = grid.opposite(d)
		local redstone = not Q and mi[d] and P.mask % 2 ^ (d + 1) < 2 ^ d
		for k = 0, BITS - 1 do
			if Q then
				inputs[d * BITS + k] = Q.out[opp * BITS + k] == true
			else
				inputs[d * BITS + k] = redstone and true or false
			end
		end
	end
	return inputs
end

local function side_has_input(inputs, d)
	return inputs[d * BITS] == true -- a redstone side sets all 8 bits alike
end

-- Sides that drive redstone this tick. Rule (1) above: a side that both has
-- redstone input and would drive is checked again with its input off.
-- Returns the mask and whether the panel's values were overwritten.
local function redstone_mask(P)
	local mask, dirty = 0, false
	for d = 0, 3 do
		if not P.neighbors[d] and any_side(P.out, d) then
			local drives = true
			if side_has_input(P.inputs, d) then
				local quiet = {}
				for p, v in pairs(P.inputs) do quiet[p] = v end
				for k = 0, BITS - 1 do quiet[d * BITS + k] = false end
				drives = any_side(runtime.eval(P.state, quiet), d)
				dirty = true
			end
			if drives then mask = mask + 2 ^ d end
		end
	end
	return mask, dirty
end

local function set_mask(P, mask)
	if mask == P.mask then return end
	local old = P.mask
	P.mask = mask
	P.mask_changes = (P.mask_changes or 0) + 1 -- the smoke test uses this to catch flicker
	core.swap_node(P.pos, { name = variant(mask), param2 = core.get_node(P.pos).param2 })
	local on, off = {}, {}
	for d = 0, 3 do
		local was, now = old % 2 ^ (d + 1) >= 2 ^ d, mask % 2 ^ (d + 1) >= 2 ^ d
		if now and not was then on[#on + 1] = SIDES[P.dir][d] end
		if was and not now then off[#off + 1] = SIDES[P.dir][d] end
	end
	if #on > 0 then mesecon.receptor_on(P.pos, on) end
	if #off > 0 then mesecon.receptor_off(P.pos, off) end
end

local tick_count = 0
local bench = { times = {}, next = 1 }

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
	end
	if links_dirty then relink() end

	-- Settle the instant part of every wall, starting from all outputs off
	-- (the least fixpoint, as in sim/ref.lua), then advance everything.
	local queue, queued = {}, {}
	for i, P in ipairs(order) do
		P.out = {}
		queue[i] = P
		queued[P] = true
	end
	local head, budget = 1, FIXPOINT_EVALS_PER_PANEL * #order
	while head <= #queue and budget > 0 do
		local P = queue[head]
		head, budget = head + 1, budget - 1
		queued[P] = nil
		P.inputs = gather(P)
		local out = runtime.eval(P.state, P.inputs)
		for d = 0, 3 do
			local Q = P.neighbors[d]
			if Q and not queued[Q] then
				for k = 0, BITS - 1 do
					local p = d * BITS + k
					if (out[p] == true) ~= (P.out[p] == true) then
						queue[#queue + 1] = Q
						queued[Q] = true
						break
					end
				end
			end
		end
		P.out = out
	end
	if head <= #queue then
		core.log("warning", "[redstone_panels] a panel wall did not settle within one tick")
	end

	-- Each panel's last eval above used its final inputs, so commit from it
	-- instead of evaluating again (unless the redstone check overwrote it).
	for _, P in ipairs(order) do
		local mask, dirty = redstone_mask(P)
		if dirty then runtime.eval(P.state, P.inputs) end
		runtime.commit(P.state)
		set_mask(P, mask)
		update_face(P)
		if tick_count % SAVE_TICKS == 0 then save_state(P) end
	end

	bench.times[bench.next] = core.get_us_time() - started
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
	local at = core.pointed_thing_to_face_pos(clicker, pointed)
	if not at then return nil end
	local rel = vector.subtract(at, pos)
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
			local P = panels[core.hash_node_position(pos)]
			if P then deactivate(P) end
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
	local gates, regs = 0, 0
	for _, P in ipairs(order) do
		local s = sim.compile.stats(P.net)
		gates, regs = gates + s.gates, regs + s.regs
	end
	local total, worst, n = 0, 0, 0
	for _, t in pairs(bench.times) do
		total, worst, n = total + t, math.max(worst, t), n + 1
	end
	return {
		panels = #order, gates = gates, regs = regs, ticks = n,
		avg_ms = n > 0 and total / n / 1000 or 0, max_ms = worst / 1000,
	}
end

core.register_chatcommand("panel_bench", {
	description = "Server time per tick and active gate count for redstone panels",
	func = function()
		local b = world.bench()
		return true, ("%d panels, %d gates, %d registers; tick %.3f ms avg, %.3f ms max (last %d ticks)"):format(
			b.panels, b.gates, b.regs, b.avg_ms, b.max_ms, b.ticks)
	end,
})

world.panels = panels
world.SIDES = SIDES
return world
