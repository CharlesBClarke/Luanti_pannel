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
--   { kind = "lamp", color = name }          -- a colored lamp (grid.LAMP_COLORS)
--   { kind = "torch", attach = d }           -- stands on the cell in direction d
--   { kind = "panel", id = k, speed = n, turn = r }
--       a compiled panel from the library, turned r quarter turns clockwise
--       (as seen from above; nil means 0). See grid.turn_port.

local grid = {}

grid.SIZE = 8
grid.PAD = grid.SIZE + 2
grid.BITS = grid.SIZE
grid.PORTS = 4 * grid.SIZE
grid.BUTTON_TICKS = 10
-- Ticks run from the starting state before a panel counts as powered on.
grid.WARMUP_TICKS = 80

-- Light of a lit lamp, { r, g, b } from 0 to 1. A plain lamp is warm yellow;
-- colored lamps are VoxeLibre's dyed lamps. Red, green and blue are pure so
-- they mix into RGB pixels.
grid.PLAIN_LAMP = { 1, 0.82, 0.25 }
grid.LAMP_COLORS = {
	white = { 1, 1, 1 }, silver = { 0.7, 0.7, 0.7 }, grey = { 0.4, 0.4, 0.4 }, black = { 0.12, 0.12, 0.12 },
	red = { 1, 0, 0 }, green = { 0, 1, 0 }, blue = { 0, 0, 1 },
	yellow = { 1, 1, 0 }, cyan = { 0, 1, 1 }, magenta = { 1, 0, 1 },
	orange = { 1, 0.5, 0 }, lime = { 0.5, 1, 0 }, lightblue = { 0.4, 0.7, 1 },
	purple = { 0.55, 0.15, 1 }, pink = { 1, 0.55, 0.7 }, brown = { 0.5, 0.3, 0.12 },
}

-- Light of a lamp cell when lit.
function grid.lamp_rgb(cell)
	return cell.color and grid.LAMP_COLORS[cell.color] or grid.PLAIN_LAMP
end

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

local function same_cell(a, b)
	for k, v in pairs(a) do
		if b[k] ~= v then return false end
	end
	for k in pairs(b) do
		if a[k] == nil then return false end
	end
	return true
end

-- True if two cells tables hold the same design.
function grid.same_cells(a, b)
	for i, cell in pairs(a) do
		if not (b[i] and same_cell(cell, b[i])) then return false end
	end
	for i in pairs(b) do
		if not a[i] then return false end
	end
	return true
end

-- Where port p of a panel ends up when the panel is turned r quarter turns
-- clockwise. One turn takes the north edge to the east, east to south,
-- south to west and west to north. Bits run left to right or top to bottom,
-- so they keep their order leaving a north or south edge and reverse
-- leaving an east or west one (its top end becomes the right end).
function grid.turn_port(p, r)
	for _ = 1, (r or 0) % 4 do
		local d, b = math.floor(p / SIZE), p % SIZE
		if d % 2 == 1 then b = SIZE - 1 - b end
		p = (d + 1) % 4 * SIZE + b
	end
	return p
end

-- True if (x, y) is on the edge, i.e. connects to the outside.
function grid.is_edge(x, y)
	return x == 1 or y == 1 or x == SIZE or y == SIZE
end

return grid
