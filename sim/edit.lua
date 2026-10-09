-- Editing a design one cell at a time: the rules the workbench grid
-- enforces. Pure Lua: no core.* calls allowed in sim/.
--
-- Cells are as in sim/grid.lua. A torch stands on a block or bulb next to
-- it; when that goes away it moves to another one next to it, or falls off.

-- In-game, init.lua loads sim/ files with loadfile and passes its own loader.
local require = type(...) == "function" and ... or require

local grid = require("sim.grid")

local edit = {}

local BASE_ORDER = { 2, 3, 1, 0 } -- prefer standing on the block below

function edit.is_base(cell)
	return cell ~= nil and (cell.kind == "block" or cell.kind == "bulb")
end

-- Directions from cell i that have a block or bulb a torch could stand on.
function edit.bases(cells, i)
	local list = {}
	for _, d in ipairs(BASE_ORDER) do
		local j = grid.neighbor(i, d)
		if j and grid.is_inner(j) and edit.is_base(cells[j]) then list[#list + 1] = d end
	end
	return list
end

-- The base a torch at i takes: the first one, or the one after `after`.
local function pick(cells, i, after)
	local list = edit.bases(cells, i)
	if #list == 0 then return nil end
	for k, d in ipairs(list) do
		if d == after then return list[k % #list + 1] end
	end
	return list[1]
end

-- Torches whose base is gone move to another one, or fall off. Returns the
-- cells of the torches that fell off.
local function settle(cells)
	local fallen = {}
	for i, cell in pairs(cells) do
		if cell.kind == "torch" then
			local j = grid.neighbor(i, cell.attach)
			if not (j and grid.is_inner(j) and edit.is_base(cells[j])) then
				local d = pick(cells, i)
				if d then
					cell.attach = d
				else
					fallen[#fallen + 1] = i
				end
			end
		end
	end
	for _, i in ipairs(fallen) do cells[i] = nil end
	table.sort(fallen)
	return fallen
end

-- Can `cell` go into empty cell i? Returns an error message, or nil.
function edit.can_place(cells, i, cell)
	if not grid.is_inner(i) then return "That is not a grid cell." end
	if cells[i] then return "That cell is taken." end
	if cell.kind == "torch" and #edit.bases(cells, i) == 0 then
		return "A torch needs a block or bulb next to it."
	end
	return nil
end

-- Put `cell` (a fresh table) into empty cell i. A torch takes the base after
-- `after` if given (so putting one back where it was picks the next base),
-- else the first. Returns an error message, or nil.
function edit.place(cells, i, cell, after)
	local err = edit.can_place(cells, i, cell)
	if err then return err end
	if cell.kind == "torch" then cell.attach = pick(cells, i, after) end
	cells[i] = cell
	return nil
end

-- Empty cell i. Returns the removed cell and the cells of torches that fell
-- off because of it.
function edit.remove(cells, i)
	local cell = cells[i]
	cells[i] = nil
	return cell, settle(cells)
end

-- Can the cell at `from` move to empty cell `to`? Returns an error message, or nil.
function edit.can_move(cells, from, to)
	local cell = cells[from]
	if not cell then return "Nothing to move." end
	if from == to then return nil end
	cells[from] = nil
	local err = edit.can_place(cells, to, cell)
	cells[from] = cell
	return err
end

-- Move the cell at `from` to empty cell `to`. A torch picks a base again.
-- Returns an error message (and changes nothing), or nil and the cells of
-- torches that fell off.
function edit.move(cells, from, to)
	local err = edit.can_move(cells, from, to)
	if err then return err end
	if from == to then return nil, {} end
	local cell = cells[from]
	cells[from] = nil
	if cell.kind == "torch" then cell.attach = pick(cells, to) end
	cells[to] = cell
	return nil, settle(cells)
end

return edit
