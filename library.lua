-- The panel library: every compiled design in the world, kept in mod
-- storage. A design never changes once added; editing makes a new entry,
-- so panels that already use the old one keep working.

local sim = ...
local compile, thumb, grid = sim.compile, sim.thumb, sim.grid

local storage = core.get_mod_storage()
local library = {}

-- In the shape sim/ expects: lib[id] = { cells = {...}, name =, owner = }.
local lib, next_id = {}, 1

do
	local data = core.deserialize(storage:get_string("library")) or {}
	for id, entry in pairs(data.panels or {}) do lib[id] = entry end
	next_id = data.next_id or 1
end

local function save()
	local panels = {}
	for id, entry in pairs(lib) do
		if type(id) == "number" then
			panels[id] = { cells = entry.cells, name = entry.name, owner = entry.owner }
		end
	end
	storage:set_string("library", core.serialize({ next_id = next_id, panels = panels }))
end

function library.get(id)
	return lib[id]
end

-- Compiled network for `id`, or nil and an error message.
function library.compiled(id)
	if not lib[id] then return nil, "unknown panel #" .. tostring(id) end
	local ok, net = pcall(compile.from_library, lib, id)
	if not ok then return nil, net end
	return net
end

-- Id of an existing entry with this exact design and name, or nil.
function library.find(cells, name)
	for id, entry in pairs(lib) do
		if type(id) == "number" and entry.name == name and grid.same_cells(entry.cells, cells) then return id end
	end
	return nil
end

-- Add a design and compile it, or reuse an identical entry. Returns the id,
-- or nil and an error message.
function library.add(cells, name, owner)
	local same = library.find(cells, name)
	if same then return same end
	for _, cell in pairs(cells) do
		if cell.kind == "panel" and not lib[cell.id] then
			return nil, "nested panel #" .. tostring(cell.id) .. " no longer exists"
		end
	end
	local id = next_id
	lib[id] = { cells = cells, name = name, owner = owner }
	local net, err = library.compiled(id)
	if not net then
		lib[id] = nil
		if lib._compiled then lib._compiled[id] = nil end
		return nil, err
	end
	next_id = next_id + 1
	save()
	return id
end

function library.describe(id)
	local entry = lib[id]
	local name = entry and entry.name ~= "" and entry.name or nil
	return "Redstone Panel #" .. id .. (name and (" (" .. name .. ")") or "")
end

-- Thumbnail texture of design `id` (its own cells only, never nested insides).
function library.thumbnail(id)
	local entry = lib[id]
	if not entry then return "" end
	entry.thumb = entry.thumb or thumb.texture(entry.cells)
	return entry.thumb
end

-- Multi-line tooltip: name, then size and edge use in grey.
function library.tooltip(id)
	local net = library.compiled(id)
	if not net then return library.describe(id) end
	local s = compile.stats(net)
	local info = ("%d gates, %d registers\nEdges: %s"):format(s.gates, s.regs, thumb.edges_text(thumb.edges(net)))
	return library.describe(id) .. "\n" .. core.colorize("#a0a0a0", info)
end

-- An item stack holding compiled panel `id`.
function library.item(id)
	local stack = ItemStack("redstone_panels:compiled")
	local meta = stack:get_meta()
	meta:set_int("panel_id", id)
	meta:set_string("description", library.tooltip(id))
	meta:set_string("inventory_image", library.thumbnail(id))
	return stack
end

-- The panel id an item stack holds, or nil.
function library.item_id(stack)
	if stack:get_name() ~= "redstone_panels:compiled" then return nil end
	local id = stack:get_meta():get_int("panel_id")
	return lib[id] and id or nil
end

return library
