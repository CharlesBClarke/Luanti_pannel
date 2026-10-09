-- The panel workbench: a node with one panel slot and an 8x8 formspec grid.
-- Put in a blank panel to start a design, or a compiled panel to load its
-- design. Pick a part from the palette, click cells to place it. Taking the
-- panel out compiles the design: unchanged, it comes back as the same panel;
-- edited, it becomes a new library entry. Dupe gives a copy.

local sim, library = ...
local grid = sim.grid

local editor = {}

local FORMNAME = "redstone_panels:editor"
local BLANK = "redstone_panels:blank"
local COMPILED = "redstone_panels:compiled"
local CELL = 1.0 -- formspec size of one grid cell
local GAP = 0.1
local MAX_NAME_LENGTH = 40
local MAX_REACH = 10 -- how far a player may be from the workbench and still edit
local DUPE_IS_FREE = true -- false: Dupe uses up a blank panel from the player's inventory
local KIT_BLANKS = 16 -- blank panels handed out by /rp

local TOOLS = { "dust", "block", "torch", "quartz", "bulb", "lamp", "button", "lever", "panel", "erase" }
local LABELS = {
	dust = "Dust", block = "Block", torch = "Torch", quartz = "Quartz", bulb = "Copper bulb",
	lamp = "Lamp", button = "Button", lever = "Lever", panel = "Panel (held)", erase = "Erase",
}
-- Icons: VoxeLibre items where they exist, a flat color otherwise.
local ICON_ITEMS = {
	dust = "mesecons:redstone", block = "mcl_core:stone", torch = "mesecons_torch:mesecon_torch_on",
	quartz = "mcl_nether:quartz", lamp = "mesecons_lightstone:lightstone_off",
	button = "mesecons_button:button_stone_off", lever = "mesecons_walllever:wall_lever_off",
	panel = COMPILED,
}
local ICON_COLORS = {
	dust = "#a01010", block = "#7a7a7a", torch = "#e04020", quartz = "#e8e0d8", bulb = "#b87333",
	lamp = "#c0a050", button = "#8a8a8a", lever = "#6a5030", panel = "#3a3a3a", erase = "#202020",
}
local ARROWS = { [0] = "^", ">", "v", "<" } -- which way a torch's block is
local EMPTY = "[fill:16x16:#2a2a2a"
local EDGE = "[fill:16x16:#33302a"
local LOCKED = "[fill:16x16:#1a1a1a"

local open = {} -- [player name] = { pos = , tool = , status = }

-- Workbench state ------------------------------------------------------------

-- Node meta: "cells" is the draft being edited, "design_name" its name, and
-- "loaded_id" the library entry it was loaded from (0 for a blank panel).

local function get_cells(pos)
	return core.deserialize(core.get_meta(pos):get_string("cells")) or {}
end

local function set_cells(pos, cells)
	core.get_meta(pos):set_string("cells", core.serialize(cells))
end

local function get_inv(pos)
	local inv = core.get_meta(pos):get_inventory()
	if inv:get_size("panel") ~= 1 then inv:set_size("panel", 1) end
	return inv
end

local function slot_stack(pos)
	return get_inv(pos):get_stack("panel", 1)
end

-- True if `stack` is something the slot takes: a blank or a known compiled panel.
local function is_panel(stack)
	return stack:get_name() == BLANK or library.item_id(stack) ~= nil
end

-- Load the design of the panel now in the slot into the draft.
function editor.load(pos)
	local meta = core.get_meta(pos)
	local id = library.item_id(slot_stack(pos))
	local entry = id and library.get(id)
	set_cells(pos, entry and entry.cells or {})
	meta:set_string("design_name", entry and entry.name or "")
	meta:set_int("loaded_id", id or 0)
end

local function clear_draft(pos)
	local meta = core.get_meta(pos)
	set_cells(pos, {})
	meta:set_string("design_name", "")
	meta:set_int("loaded_id", 0)
end

-- Compile the draft and put the result in the slot. Returns the slot's new
-- stack, or nil and an error message. An untouched blank stays a blank.
function editor.commit(pos, owner)
	local stack = slot_stack(pos)
	if not is_panel(stack) then return nil, "No panel in the slot." end
	local meta = core.get_meta(pos)
	local cells, name = get_cells(pos), meta:get_string("design_name")
	if stack:get_name() == BLANK and next(cells) == nil then return stack end
	local id, err = library.add(cells, name, owner)
	if not id then return nil, "Compile failed: " .. tostring(err) end
	meta:set_int("loaded_id", id)
	stack = library.item(id)
	get_inv(pos):set_stack("panel", 1, stack)
	return stack
end

-- Formspec -------------------------------------------------------------------

local function icon(x, y, kind, name, label)
	local item = ICON_ITEMS[kind]
	if item and core.registered_items[item] then
		return ("item_image_button[%f,%f;%f,%f;%s;%s;%s]"):format(x, y, CELL, CELL, item, name,
			core.formspec_escape(label))
	end
	local tex = "[fill:16x16:" .. (ICON_COLORS[kind] or "#000000")
	return ("image_button[%f,%f;%f,%f;%s;%s;%s]"):format(x, y, CELL, CELL, core.formspec_escape(tex), name,
		core.formspec_escape(label))
end

local function slot_bg(x, y, w, h)
	if core.global_exists("mcl_formspec") then return mcl_formspec.get_itemslot_bg_v4(x, y, w, h) end
	return ""
end

function editor.formspec(pos, tool, status)
	local loaded = is_panel(slot_stack(pos))
	local cells = loaded and get_cells(pos) or {}
	local inv_loc = ("nodemeta:%d,%d,%d"):format(pos.x, pos.y, pos.z)
	local fs = {
		"formspec_version[6]",
		"size[15,16]",
		"label[0.5,0.5;" .. core.formspec_escape(loaded
			and "Redstone Panel workbench: the outer ring of cells connects to neighbours"
			or "Put a blank or compiled panel in the slot to start") .. "]",
	}
	for y = 1, grid.SIZE do
		for x = 1, grid.SIZE do
			local cx, cy = 0.5 + (x - 1) * (CELL + GAP), 1 + (y - 1) * (CELL + GAP)
			local cell = cells[grid.index(x, y)]
			local name = ("c_%d_%d"):format(x, y)
			if not loaded then
				fs[#fs + 1] = ("image[%f,%f;%f,%f;%s]"):format(cx, cy, CELL, CELL, core.formspec_escape(LOCKED))
			elseif cell and cell.kind == "panel" then
				fs[#fs + 1] = ("image_button[%f,%f;%f,%f;%s;%s;]"):format(cx, cy, CELL, CELL,
					core.formspec_escape(library.thumbnail(cell.id)), name)
				fs[#fs + 1] = ("tooltip[%s;%s]"):format(name, core.formspec_escape(library.tooltip(cell.id)))
			elseif cell then
				local label = ""
				if cell.kind == "torch" then label = ARROWS[cell.attach] end
				if cell.kind == "bulb" then label = "B" end
				fs[#fs + 1] = icon(cx, cy, cell.kind, name, label)
			else
				local tex = grid.is_edge(x, y) and EDGE or EMPTY
				fs[#fs + 1] = ("image_button[%f,%f;%f,%f;%s;%s;]"):format(cx, cy, CELL, CELL,
					core.formspec_escape(tex), name)
			end
		end
	end

	local px = 0.5 + grid.SIZE * (CELL + GAP) + 0.4
	fs[#fs + 1] = slot_bg(px, 1, 1, 1)
	fs[#fs + 1] = ("list[%s;panel;%f,1;1,1;]"):format(inv_loc, px)
	fs[#fs + 1] = ("button[%f,1.1;1.8,0.8;dupe;Dupe]"):format(px + 1.3)
	fs[#fs + 1] = ("button[%f,1.1;1.8,0.8;clear;Clear]"):format(px + 3.2)
	fs[#fs + 1] = ("field[%f,2.6;5,0.8;name;Name (Enter to set);%s]"):format(px,
		core.formspec_escape(core.get_meta(pos):get_string("design_name")))
	fs[#fs + 1] = "field_close_on_enter[name;false]"
	for i, t in ipairs(TOOLS) do
		local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
		local x, y = px + col * 2.6, 3.8 + row * 1.1
		fs[#fs + 1] = icon(x, y, t, "t_" .. t, "")
		local mark = t == tool and "> " or ""
		fs[#fs + 1] = ("label[%f,%f;%s]"):format(x + CELL + 0.1, y + 0.5, core.formspec_escape(mark .. LABELS[t]))
	end
	fs[#fs + 1] = ("label[%f,9.5;%s]"):format(px, core.formspec_escape(
		"Torch: click again to move it to\nanother block or bulb next to it."))
	if status then fs[#fs + 1] = ("label[0.5,10.1;%s]"):format(core.formspec_escape(status)) end

	fs[#fs + 1] = slot_bg(0.5, 10.6, 9, 4)
	fs[#fs + 1] = "list[current_player;main;0.5,10.6;9,4;]"
	fs[#fs + 1] = ("listring[%s;panel]listring[current_player;main]"):format(inv_loc)
	return table.concat(fs)
end

local function show(player, pos)
	local name = player:get_player_name()
	open[name] = open[name] or { tool = "dust" }
	local st = open[name]
	if st.pos and not vector.equals(st.pos, pos) then st.status = nil end
	st.pos = pos
	core.show_formspec(name, FORMNAME, editor.formspec(pos, st.tool, st.status))
end

-- Show `status` to `player` if they have this workbench open.
local function refresh(player, pos, status)
	local st = player and open[player:get_player_name()]
	if not (st and st.pos and vector.equals(st.pos, pos)) then return end
	st.status = status
	show(player, pos)
end

-- Editing --------------------------------------------------------------------

local function is_base(cell)
	return cell and (cell.kind == "block" or cell.kind == "bulb")
end

-- Directions from cell i that have a block or bulb a torch could stand on.
local function bases(cells, i)
	local list = {}
	for _, d in ipairs({ 2, 3, 1, 0 }) do -- prefer standing on the block below
		local j = grid.neighbor(i, d)
		if j and grid.is_inner(j) and is_base(cells[j]) then list[#list + 1] = d end
	end
	return list
end

-- Torches fall off when the block they stand on goes away.
local function drop_loose_torches(cells)
	for i, cell in pairs(cells) do
		if cell.kind == "torch" then
			local j = grid.neighbor(i, cell.attach)
			if not (j and grid.is_inner(j) and is_base(cells[j])) then cells[i] = nil end
		end
	end
end

-- Apply `tool` to cell i. Returns an error message for the player, or nil.
function editor.apply(cells, i, tool, held_id)
	local cell = cells[i]
	if tool == "erase" then
		cells[i] = nil
	elseif tool == "torch" then
		local list = bases(cells, i)
		if #list == 0 then return "A torch needs a block or bulb next to it." end
		local attach = list[1]
		if cell and cell.kind == "torch" then
			for k, d in ipairs(list) do
				if d == cell.attach then attach = list[k % #list + 1] end
			end
		end
		cells[i] = { kind = "torch", attach = attach }
	elseif tool == "panel" then
		if not held_id then return "Hold a compiled panel to place it." end
		cells[i] = { kind = "panel", id = held_id, speed = 1 }
	else
		cells[i] = { kind = tool }
	end
	drop_loose_torches(cells)
	return nil
end

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

local function dupe(pos, player)
	local stack, err = editor.commit(pos, player:get_player_name())
	if not stack then return err end
	if not DUPE_IS_FREE then
		local inv = player:get_inventory()
		if not inv:contains_item("main", BLANK) then return "Dupe needs a blank panel in your inventory." end
		inv:remove_item("main", BLANK)
	end
	give(player, ItemStack(stack))
	return "Duped " .. stack:get_short_description() .. "."
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
	if not loaded then
		show(player, pos)
		return true
	end

	st.status = nil
	local cells = get_cells(pos)
	for key in pairs(fields) do
		local t = key:match("^t_(%a+)$")
		if t and LABELS[t] then st.tool = t end
		local x, y = key:match("^c_(%d)_(%d)$")
		if x then
			local held = library.item_id(player:get_wielded_item())
			st.status = editor.apply(cells, grid.index(tonumber(x), tonumber(y)), st.tool, held)
			set_cells(pos, cells)
		end
	end
	if fields.clear then set_cells(pos, {}) end
	if fields.dupe then st.status = dupe(pos, player) end
	show(player, pos)
	return true
end)

-- Nodes and items ------------------------------------------------------------

core.register_craftitem(BLANK, {
	description = "Blank Redstone Panel\n" .. core.colorize("#a0a0a0", "Put it in a workbench to design a panel"),
	inventory_image = sim.thumb.texture({}),
	groups = { mesecon = 1 }, -- puts it in VoxeLibre's Redstone creative tab
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
	allow_metadata_inventory_put = function(pos, _listname, _index, stack, player)
		if not can_use(pos, player) or not is_panel(stack) or not slot_stack(pos):is_empty() then return 0 end
		return 1
	end,
	on_metadata_inventory_put = function(pos, _listname, _index, _stack, player)
		editor.load(pos)
		refresh(player, pos, nil)
	end,
	-- Taking the panel compiles the draft first and swaps the result into the
	-- slot; the engine moves whatever is in the slot after this returns.
	allow_metadata_inventory_take = function(pos, _listname, _index, _stack, player)
		if not can_use(pos, player) then return 0 end
		local stack, err = editor.commit(pos, player:get_player_name())
		if not stack then
			refresh(player, pos, err)
			return 0
		end
		return 1
	end,
	on_metadata_inventory_take = function(pos, _listname, _index, _stack, player)
		clear_draft(pos)
		refresh(player, pos, nil)
	end,
	allow_metadata_inventory_move = function() return 0 end,
	-- The draft is lost when the workbench is dug; the panel comes back as it was put in.
	after_dig_node = function(pos, _oldnode, oldmeta)
		for _, item in ipairs(oldmeta.inventory and oldmeta.inventory.panel or {}) do
			local stack = ItemStack(item)
			if not stack:is_empty() then core.add_item(pos, stack) end
		end
	end,
})

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

return editor
