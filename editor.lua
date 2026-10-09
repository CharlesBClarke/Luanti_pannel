-- The panel workbench: a node with one panel slot and an 8x8 grid of item
-- slots. Put in a blank panel to start a design, or a compiled panel to
-- load its design: its parts come out into the grid as real items. Drag
-- parts in from your inventory and out again. Taking the panel out compiles
-- the grid into it: unchanged, it comes back as the same panel; edited, it
-- becomes a new library entry. Creative players also get Dupe and a free
-- palette of parts (see sim/edit.lua for the placement rules).

local sim, library = ...
local grid, edit = sim.grid, sim.edit

local editor = {}

local FORMNAME = "redstone_panels:editor"
local BLANK = "redstone_panels:blank"
local BULB = "redstone_panels:bulb"
local PALETTE = "redstone_panels_palette"
local SIZE = grid.SIZE
local SLOTS = SIZE * SIZE
local SLOT_STEP = 1.25 -- formspec distance between list slots (the default spacing)
local MAX_NAME_LENGTH = 40
local MAX_REACH = 10 -- how far a player may be from the workbench and still edit
local KIT_BLANKS = 16 -- blank panels handed out by /rp
local BLANKS_PER_CRAFT = 4
local BULBS_PER_CRAFT = 1

-- The item each part is made of. One item per part, so taking a part out
-- gives back exactly what went in.
local PART_ITEMS = {
	dust = "mesecons:redstone", block = "mcl_core:stone", torch = "mesecons_torch:mesecon_torch_on",
	quartz = "mcl_nether:quartz", bulb = BULB, lamp = "mesecons_lightstone:lightstone_off",
	button = "mesecons_button:button_stone_off", lever = "mesecons_walllever:wall_lever_off",
}
local PALETTE_ORDER = { "dust", "block", "torch", "quartz", "bulb", "lamp", "button", "lever" }
local PART_OF = {} -- [item name] = part; filled once aliases are known
-- Dyed lamps (VoxeLibre has one per dye) make colored lamps, grid.LAMP_COLORS.
local COLORED_LAMP = "mesecons_lightstone:lightstone_off_"
local LAMP_COLOR_OF = {} -- [item name] = color; filled once items are known
local PALETTE_LAMPS = { "red", "green", "blue" } -- colored lamps in the creative palette
local PALETTE_COLUMNS = 4
local PALETTE_SLOTS = #PALETTE_ORDER + #PALETTE_LAMPS + 1 -- parts, colored lamps, a blank panel

-- Item stacks carry the real name, not an alias (mesecons:redstone is one).
local function resolve(item)
	return core.registered_aliases[item] or item
end

local ARROWS = { [0] = "^", ">", "v", "<" } -- which way a torch's block is
local EDGE_TINT = "#c0a06030" -- marks the outer ring, which connects to neighbours

local open = {} -- [player name] = { pos = , status = }
local last_attach = {} -- [pos hash][cell] = attach of the torch last taken from there

-- Workbench state ------------------------------------------------------------

-- Node meta: "cells" is the draft being edited, "design_name" its name, and
-- "loaded_id" the library entry it was loaded from (0 for a blank panel).
-- The "grid" list always holds the draft's parts as items.

local function get_cells(pos)
	return core.deserialize(core.get_meta(pos):get_string("cells")) or {}
end

local function set_cells(pos, cells)
	core.get_meta(pos):set_string("cells", core.serialize(cells))
end

-- Grid slot k (1-based, row by row) <-> padded cell index.
local function slot_cell(k)
	return grid.index((k - 1) % SIZE + 1, math.floor((k - 1) / SIZE) + 1)
end

local function cell_slot(i)
	local x, y = grid.xy(i)
	return (y - 1) * SIZE + x
end

-- The item a cell is made of.
local function item_for(cell)
	if cell.kind == "panel" then return library.get(cell.id) and library.item(cell.id) or ItemStack("") end
	-- A color this game has no dyed lamp for (design from elsewhere) comes back as a plain lamp.
	if cell.kind == "lamp" and cell.color and core.registered_items[resolve(COLORED_LAMP .. cell.color)] then
		return ItemStack(COLORED_LAMP .. cell.color)
	end
	return ItemStack(PART_ITEMS[cell.kind])
end

-- The cell an item makes, or nil if it isn't a part.
local function cell_for(stack)
	local id = library.item_id(stack)
	if id then return { kind = "panel", id = id, speed = 1 } end
	local color = LAMP_COLOR_OF[stack:get_name()]
	if color then return { kind = "lamp", color = color } end
	local kind = PART_OF[stack:get_name()]
	return kind and { kind = kind } or nil
end

local function fill_grid(inv, cells)
	for k = 1, SLOTS do
		local cell = cells[slot_cell(k)]
		inv:set_stack("grid", k, cell and item_for(cell) or ItemStack(""))
	end
end

local function get_inv(pos)
	local inv = core.get_meta(pos):get_inventory()
	if inv:get_size("panel") ~= 1 then inv:set_size("panel", 1) end
	if inv:get_size("grid") ~= SLOTS then
		-- A workbench from before the grid held items: its draft becomes items.
		inv:set_size("grid", SLOTS)
		if not inv:is_empty("panel") then fill_grid(inv, get_cells(pos)) end
	end
	return inv
end

local function slot_stack(pos)
	return get_inv(pos):get_stack("panel", 1)
end

-- True if `stack` is something the slot takes: a blank or a known compiled panel.
local function is_panel(stack)
	return stack:get_name() == BLANK or library.item_id(stack) ~= nil
end

local function memory(pos)
	local hash = core.hash_node_position(pos)
	last_attach[hash] = last_attach[hash] or {}
	return last_attach[hash]
end

-- Load the design of the panel now in the slot into the draft and the grid.
function editor.load(pos)
	local meta = core.get_meta(pos)
	local id = library.item_id(slot_stack(pos))
	local entry = id and library.get(id)
	local cells = entry and entry.cells or {}
	set_cells(pos, cells)
	fill_grid(get_inv(pos), cells)
	meta:set_string("design_name", entry and entry.name or "")
	meta:set_int("loaded_id", id or 0)
end

-- The parts went into the panel that was taken out.
local function clear_draft(pos)
	local meta = core.get_meta(pos)
	set_cells(pos, {})
	fill_grid(get_inv(pos), {})
	meta:set_string("design_name", "")
	meta:set_int("loaded_id", 0)
end

-- Compile the draft and put the result in the slot. Returns the slot's new
-- stack, or nil and an error message. An empty grid makes a blank panel.
function editor.commit(pos, owner)
	local stack = slot_stack(pos)
	if not is_panel(stack) then return nil, "No panel in the slot." end
	local meta = core.get_meta(pos)
	local cells, name = get_cells(pos), meta:get_string("design_name")
	if next(cells) == nil then
		stack = ItemStack(BLANK)
	else
		local id, err = library.add(cells, name, owner)
		if not id then return nil, "Compile failed: " .. tostring(err) end
		meta:set_int("loaded_id", id)
		stack = library.item(id)
	end
	get_inv(pos):set_stack("panel", 1, stack)
	return stack
end

-- Formspec -------------------------------------------------------------------

local function slot_bg(x, y, w, h)
	if core.global_exists("mcl_formspec") then return mcl_formspec.get_itemslot_bg_v4(x, y, w, h) end
	return ""
end

local function is_creative(player)
	return core.is_creative_enabled(player:get_player_name())
end

local GX, GY = 0.5, 1 -- top left of the grid
local PX = GX + SIZE * SLOT_STEP + 0.5 -- the column right of the grid

function editor.formspec(pos, status, creative)
	local loaded = is_panel(slot_stack(pos))
	local cells = loaded and get_cells(pos) or {}
	local inv_loc = ("nodemeta:%d,%d,%d"):format(pos.x, pos.y, pos.z)
	local fs = {
		"formspec_version[6]",
		("size[%f,17.4]"):format(creative and 17.75 or 16.5), -- creative adds the trash slot
		"label[0.5,0.5;" .. core.formspec_escape(loaded
			and "Drag parts into the grid. The outer ring connects to neighbouring panels."
			or "Put a blank or compiled panel in the slot to start.") .. "]",
		slot_bg(GX, GY, SIZE, SIZE),
	}
	for y = 1, SIZE do
		for x = 1, SIZE do
			if grid.is_edge(x, y) then
				fs[#fs + 1] = ("box[%f,%f;1,1;%s]"):format(GX + (x - 1) * SLOT_STEP, GY + (y - 1) * SLOT_STEP, EDGE_TINT)
			end
		end
	end
	fs[#fs + 1] = ("list[%s;grid;%f,%f;%d,%d;]"):format(inv_loc, GX, GY, SIZE, SIZE)
	for i, cell in pairs(cells) do
		if cell.kind == "torch" then
			local x, y = grid.xy(i)
			fs[#fs + 1] = ("label[%f,%f;%s]"):format(GX + (x - 1) * SLOT_STEP + 0.7, GY + (y - 1) * SLOT_STEP + 0.2,
				ARROWS[cell.attach])
		end
	end

	fs[#fs + 1] = slot_bg(PX, GY, 1, 1)
	fs[#fs + 1] = ("list[%s;panel;%f,%f;1,1;]"):format(inv_loc, PX, GY)
	fs[#fs + 1] = ("button[%f,%f;1.8,0.8;clear;Clear]"):format(PX + 1.3, GY + 0.1)
	if creative then fs[#fs + 1] = ("button[%f,%f;1.8,0.8;dupe;Dupe]"):format(PX + 3.2, GY + 0.1) end
	fs[#fs + 1] = ("field[%f,%f;5,0.8;name;Name (Enter to set);%s]"):format(PX, GY + 1.6,
		core.formspec_escape(core.get_meta(pos):get_string("design_name")))
	fs[#fs + 1] = "field_close_on_enter[name;false]"
	fs[#fs + 1] = ("textarea[%f,%f;5,2.6;;;%s]"):format(PX, GY + 2.8, core.formspec_escape(
		"Taking the panel out compiles the grid into it.\n"
		.. "A torch stands on a block or bulb next to it (the arrow points to it). "
		.. "Take it out and put it back to move it to the next one."))
	if creative then
		fs[#fs + 1] = ("label[%f,%f;Parts (creative)]"):format(PX, GY + 5.8)
		local rows = math.ceil(PALETTE_SLOTS / PALETTE_COLUMNS)
		fs[#fs + 1] = slot_bg(PX, GY + 6.2, PALETTE_COLUMNS, rows)
		fs[#fs + 1] = ("list[detached:%s;parts;%f,%f;%d,%d;]"):format(PALETTE, PX, GY + 6.2, PALETTE_COLUMNS, rows)
		local tx = PX + PALETTE_COLUMNS * SLOT_STEP
		fs[#fs + 1] = ("label[%f,%f;Delete]"):format(tx, GY + 5.8)
		fs[#fs + 1] = slot_bg(tx, GY + 6.2, 1, 1)
		fs[#fs + 1] = ("list[detached:%s;trash;%f,%f;1,1;]"):format(PALETTE, tx, GY + 6.2)
	end
	if status then fs[#fs + 1] = ("label[%f,%f;%s]"):format(GX, GY + SIZE * SLOT_STEP + 0.1, core.formspec_escape(status)) end

	local iy = GY + SIZE * SLOT_STEP + 0.6
	fs[#fs + 1] = slot_bg(GX, iy, 9, 3)
	fs[#fs + 1] = ("list[current_player;main;%f,%f;9,3;9]"):format(GX, iy)
	fs[#fs + 1] = slot_bg(GX, iy + 3 * SLOT_STEP + 0.3, 9, 1)
	fs[#fs + 1] = ("list[current_player;main;%f,%f;9,1;]"):format(GX, iy + 3 * SLOT_STEP + 0.3)
	-- Shift-click goes to the next list in the ring (the first match wins):
	-- palette and grid parts go to the inventory, panels go to the slot.
	if creative then fs[#fs + 1] = ("listring[detached:%s;parts]listring[current_player;main]"):format(PALETTE) end
	fs[#fs + 1] = ("listring[%s;panel]listring[%s;grid]listring[current_player;main]"):format(inv_loc, inv_loc)
	return table.concat(fs)
end

local function show(player, pos)
	local name = player:get_player_name()
	open[name] = open[name] or {}
	local st = open[name]
	if st.pos and not vector.equals(st.pos, pos) then st.status = nil end
	st.pos = pos
	core.show_formspec(name, FORMNAME, editor.formspec(pos, st.status, is_creative(player)))
end

-- Show `status` to `player` if they have this workbench open.
local function refresh(player, pos, status)
	local st = player and open[player:get_player_name()]
	if not (st and st.pos and vector.equals(st.pos, pos)) then return end
	st.status = status
	show(player, pos)
end

-- Editing --------------------------------------------------------------------

local function can_use(pos, player)
	local name = player:get_player_name()
	if vector.distance(player:get_pos(), pos) > MAX_REACH then return false end
	if core.is_protected(pos, name) then
		core.record_protection_violation(pos, name)
		return false
	end
	return true
end

-- Give `stack` to the player, dropping what doesn't fit.
local function give(player, stack)
	local left = player:get_inventory():add_item("main", stack)
	if not left:is_empty() then core.add_item(player:get_pos(), left) end
end

-- Torches that fell off leave the grid and go back to the player.
local function return_fallen(pos, player, fallen)
	if #fallen == 0 then return nil end
	local inv = get_inv(pos)
	for _, i in ipairs(fallen) do
		inv:set_stack("grid", cell_slot(i), ItemStack(""))
		give(player, ItemStack(PART_ITEMS.torch))
	end
	return #fallen == 1 and "A torch fell off and went back to your inventory."
		or #fallen .. " torches fell off and went back to your inventory."
end

-- Error message if `stack` can't go into grid slot k, or nil.
local function check_put(pos, k, stack)
	if not is_panel(slot_stack(pos)) then return "Put a panel in the slot first." end
	local cell = cell_for(stack)
	if not cell then return stack:get_short_description() .. " is not a panel part." end
	return edit.can_place(get_cells(pos), slot_cell(k), cell)
end

local function grid_put(pos, k, stack, player)
	local cells, i = get_cells(pos), slot_cell(k)
	local cell = cell_for(stack)
	local err = cell and edit.place(cells, i, cell, cell.kind == "torch" and memory(pos)[i] or nil)
	if err or not cell then -- changed under us since the check: hand the item back
		get_inv(pos):set_stack("grid", k, ItemStack(""))
		give(player, stack)
		return err
	end
	set_cells(pos, cells)
	return nil
end

local function grid_take(pos, k, player)
	local cells, i = get_cells(pos), slot_cell(k)
	local cell, fallen = edit.remove(cells, i)
	if cell and cell.kind == "torch" then memory(pos)[i] = cell.attach end
	set_cells(pos, cells)
	return return_fallen(pos, player, fallen)
end

local function grid_move(pos, from, to, player)
	local cells = get_cells(pos)
	local err, fallen = edit.move(cells, slot_cell(from), slot_cell(to))
	if err then -- the engine already moved the item; put the grid back as the design says
		fill_grid(get_inv(pos), cells)
		return err
	end
	set_cells(pos, cells)
	return return_fallen(pos, player, fallen)
end

local function dupe(pos, player)
	if not is_creative(player) then return "Dupe is creative-only." end
	local stack, err = editor.commit(pos, player:get_player_name())
	if not stack then return err end
	give(player, ItemStack(stack))
	return "Duped " .. stack:get_short_description() .. "."
end

-- Empty the grid; in survival its parts go back to the player.
local function clear(pos, player)
	local inv = get_inv(pos)
	if not is_creative(player) then
		for k = 1, SLOTS do
			local stack = inv:get_stack("grid", k)
			if not stack:is_empty() then give(player, stack) end
		end
	end
	set_cells(pos, {})
	fill_grid(inv, {})
end

core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= FORMNAME then return false end
	local name = player:get_player_name()
	local st = open[name]
	if not st then return true end
	local pos = st.pos
	if core.get_node(pos).name ~= "redstone_panels:panel" or not can_use(pos, player) then
		if fields.quit then open[name] = nil end
		return true
	end
	local loaded = is_panel(slot_stack(pos))
	if fields.name and loaded then
		core.get_meta(pos):set_string("design_name", fields.name:sub(1, MAX_NAME_LENGTH))
	end
	if fields.quit then
		open[name] = nil
		return true
	end
	st.status = nil
	if loaded and fields.clear then clear(pos, player) end
	if loaded and fields.dupe then st.status = dupe(pos, player) end
	show(player, pos)
	return true
end)

-- Nodes and items ------------------------------------------------------------

core.register_craftitem(BLANK, {
	description = "Blank Redstone Panel\n" .. core.colorize("#a0a0a0", "Put it in a workbench to design a panel"),
	inventory_image = sim.thumb.texture({}),
	groups = { mesecon = 1 }, -- puts it in VoxeLibre's Redstone creative tab
})

core.register_craftitem(BULB, {
	description = "Copper Bulb\n" .. core.colorize("#a0a0a0", "A panel part: flips on or off each time it is powered"),
	inventory_image = "[fill:16x16:#00000000^[fill:10x10:3,3:#b87333^[fill:4x4:6,6:#ffb060",
	groups = { mesecon = 1 },
})

core.register_node("redstone_panels:panel", {
	description = "Redstone Panel Workbench",
	tiles = { "[fill:16x16:#3a3a3a", "[fill:16x16:#3a3a3a", "[fill:16x16:#3a3a3a",
		"[fill:16x16:#3a3a3a", "[fill:16x16:#3a3a3a", "[fill:16x16:#3a3a3a^[fill:14x14:1,1:#1e3a1e" },
	paramtype2 = "4dir",
	is_ground_content = false,
	groups = { pickaxey = 1, mesecon = 1 },
	_mcl_blast_resistance = 1,
	_mcl_hardness = 1,
	on_construct = function(pos) get_inv(pos) end,
	on_rightclick = function(pos, _node, clicker, itemstack)
		if clicker and clicker:is_player() then show(clicker, pos) end
		return itemstack
	end,
	-- The panel and its parts stay inside until the panel is taken out.
	can_dig = function(pos)
		return get_inv(pos):is_empty("panel")
	end,
	allow_metadata_inventory_put = function(pos, listname, index, stack, player)
		if not can_use(pos, player) then return 0 end
		if listname == "panel" then
			if not is_panel(stack) or not slot_stack(pos):is_empty() then return 0 end
			return 1
		end
		local err = check_put(pos, index, stack)
		if err then
			refresh(player, pos, err)
			return 0
		end
		return 1
	end,
	on_metadata_inventory_put = function(pos, listname, index, stack, player)
		local status
		if listname == "panel" then
			editor.load(pos)
		else
			status = grid_put(pos, index, stack, player)
		end
		refresh(player, pos, status)
	end,
	-- Taking the panel compiles the draft first and swaps the result into the
	-- slot; the engine moves whatever is in the slot after this returns.
	allow_metadata_inventory_take = function(pos, listname, _index, stack, player)
		if not can_use(pos, player) then return 0 end
		if listname == "grid" then return stack:get_count() end
		local result, err = editor.commit(pos, player:get_player_name())
		if not result then
			refresh(player, pos, err)
			return 0
		end
		return 1
	end,
	on_metadata_inventory_take = function(pos, listname, index, _stack, player)
		local status
		if listname == "panel" then
			clear_draft(pos)
		else
			status = grid_take(pos, index, player)
		end
		refresh(player, pos, status)
	end,
	allow_metadata_inventory_move = function(pos, from_list, from_index, to_list, to_index, count, player)
		if from_list ~= "grid" or to_list ~= "grid" or not can_use(pos, player) then return 0 end
		local err = edit.can_move(get_cells(pos), slot_cell(from_index), slot_cell(to_index))
		if err then
			refresh(player, pos, err)
			return 0
		end
		return count
	end,
	on_metadata_inventory_move = function(pos, _from_list, from_index, _to_list, to_index, _count, player)
		refresh(player, pos, grid_move(pos, from_index, to_index, player))
	end,
})

-- Creative players take parts from here for free, and drop items in the
-- trash slot to delete them. Parts slots refuse drops: they are full, so the
-- client would try a swap that the server rejects, leaving a ghost stack held.
local palette = core.create_detached_inventory(PALETTE, {
	allow_take = function(_inv, listname, _index, _stack, player)
		return listname == "parts" and is_creative(player) and -1 or 0
	end,
	allow_put = function(_inv, listname, _index, stack, player)
		return listname == "trash" and is_creative(player) and stack:get_count() or 0
	end,
	on_put = function(inv, listname, index)
		inv:set_stack(listname, index, ItemStack(""))
	end,
	allow_move = function() return 0 end,
})
palette:set_size("parts", PALETTE_SLOTS)
palette:set_size("trash", 1)

-- A full stack, so shift-click hands out as many as fit in one slot.
local function full_stack(item)
	local stack = ItemStack(item)
	stack:set_count(stack:get_stack_max())
	return stack
end

core.register_on_mods_loaded(function()
	for kind, item in pairs(PART_ITEMS) do PART_OF[resolve(item)] = kind end
	for color in pairs(grid.LAMP_COLORS) do
		local item = resolve(COLORED_LAMP .. color)
		if core.registered_items[item] then LAMP_COLOR_OF[item] = color end
	end
	local k = 0
	local function offer(item)
		if core.registered_items[resolve(item)] then
			k = k + 1
			palette:set_stack("parts", k, full_stack(item))
		end
	end
	for _, kind in ipairs(PALETTE_ORDER) do offer(PART_ITEMS[kind]) end
	for _, color in ipairs(PALETTE_LAMPS) do offer(COLORED_LAMP .. color) end
	palette:set_stack("parts", k + 1, full_stack(BLANK))

	-- Survival recipes, only where the ingredients exist.
	local function craft(def)
		for _, row in ipairs(def.recipe) do
			for _, item in ipairs(type(row) == "table" and row or { row }) do
				if item ~= "" and not core.registered_items[resolve(item)] then return end
			end
		end
		core.register_craft(def)
	end
	local stone, dust, slab = "mcl_core:stone", "mesecons:redstone", "mcl_stairs:slab_stone"
	craft({
		output = "redstone_panels:panel",
		recipe = { { dust, dust, dust }, { stone, "mcl_crafting_table:crafting_table", stone }, { stone, stone, stone } },
	})
	craft({ output = BLANK .. " " .. BLANKS_PER_CRAFT, recipe = { { "", dust, "" }, { slab, slab, slab } } })
	craft({ type = "shapeless", output = BULB .. " " .. BULBS_PER_CRAFT, recipe = { "mcl_copper:copper_ingot", dust } })
end)

core.register_chatcommand("rp", {
	description = "Get a Redstone Panel workbench and some blank panels",
	privs = { give = true },
	func = function(name)
		local player = core.get_player_by_name(name)
		if not player then return false, "You need to be in game." end
		give(player, ItemStack("redstone_panels:panel"))
		give(player, ItemStack(BLANK .. " " .. KIT_BLANKS))
		return true, "Here is a workbench and " .. KIT_BLANKS .. " blank panels."
	end,
})

core.register_on_leaveplayer(function(player)
	open[player:get_player_name()] = nil
end)

-- For the smoke test: the grid slot of a cell, and its inventory callbacks.
editor.cell_slot = cell_slot

return editor
