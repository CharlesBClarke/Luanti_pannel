-- Pure Lua: no core.* calls allowed in sim/ so it runs under plain LuaJIT.
--
-- A panel is an 8x8 grid of cells surrounded by a ring of edge ports.
-- Cells are indexed in a padded 10x10 layout: index = y * PAD + x, with
-- x, y in 1..8 for buildable cells and 0 or 9 for the port ring.
--
-- Directions: 0 = north (up), 1 = east, 2 = south, 3 = west.
-- Ports: side d, bit b (0..7, left to right or top to bottom) is port d * 8 + b.
--
-- A cell is nil (empty) or a table:
--   { kind = "dust" | "block" | "quartz" | "bulb" | "lamp" | "button" | "lever" }
--   { kind = "torch", attach = d }           -- stands on the cell in direction d
--   { kind = "panel", id = k, speed = n }    -- a compiled panel from the library

local grid = {}

grid.SIZE = 8
grid.PAD = grid.SIZE + 2
grid.BITS = grid.SIZE
grid.PORTS = 4 * grid.SIZE
grid.BUTTON_TICKS = 10
-- Ticks run from the starting state before a panel counts as powered on.
grid.WARMUP_TICKS = 80

local SIZE, PAD = grid.SIZE, grid.PAD
local STEP = { [0] = { 0, -1 }, { 1, 0 }, { 0, 1 }, { -1, 0 } } -- {dx, dy}

function grid.opposite(d)
	return (d + 2) % 4
end

function grid.index(x, y)
	return y * PAD + x
end

function grid.xy(i)
	return i % PAD, math.floor(i / PAD)
end

function grid.is_inner(i)
	local x, y = grid.xy(i)
	return x >= 1 and x <= SIZE and y >= 1 and y <= SIZE
end

-- Index of the neighbour in direction d, or nil if off the padded grid.
function grid.neighbor(i, d)
	local x, y = grid.xy(i)
	x, y = x + STEP[d][1], y + STEP[d][2]
	if x < 0 or y < 0 or x >= PAD or y >= PAD then
		return nil
	end
	return grid.index(x, y)
end

-- Padded index of the port cell for side d, bit b.
function grid.port_cell(d, b)
	local q = b + 1
	if d == 0 then return grid.index(q, 0) end
	if d == 1 then return grid.index(PAD - 1, q) end
	if d == 2 then return grid.index(q, PAD - 1) end
	return grid.index(0, q)
end

local port_at = {}
for d = 0, 3 do
	for b = 0, SIZE - 1 do
		port_at[grid.port_cell(d, b)] = d * SIZE + b
	end
end

-- Port number if padded index i is a port cell, else nil. Corners are not ports.
function grid.port_at(i)
	return port_at[i]
end

-- The buildable cell just inside port p.
function grid.port_inner(p)
	local d, b = math.floor(p / SIZE), p % SIZE
	return grid.neighbor(grid.port_cell(d, b), grid.opposite(d))
end

function grid.new()
	return { cells = {} }
end

function grid.get(g, x, y)
	return g.cells[grid.index(x, y)]
end

function grid.set(g, x, y, cell)
	g.cells[grid.index(x, y)] = cell
end

-- True if (x, y) is on the edge, i.e. connects to the outside.
function grid.is_edge(x, y)
	return x == 1 or y == 1 or x == SIZE or y == SIZE
end

return grid
