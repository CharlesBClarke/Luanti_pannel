-- Ready-made panels to show what panels can do (/panel_demo). Pure Lua: no
-- core.* calls allowed in sim/.
--
--   lights out:    the Lights Out game. 64 nested light cells; pressing one
--                  toggles it and its four neighbours. Boards placed side
--                  by side join into one bigger game (2x2 = 16x16).
--   counter:       a 64-bit binary counter, one nested flip-flop per cell,
--                  each showing its bit as a lamp. Self-clocked.
--   wave:          press a cell and a ring of light spreads out from it,
--                  each pixel lit for about a second. Boards side by side
--                  carry the wave across.
--   rgb cycle:     every cell is a 3-bit counter with a red, a green and a
--                  blue lamp, so it steps through 8 colors; the order of the
--                  colors changes along the diagonals.
--   clock tower:   tens of billions of torches in nested clocks, which the
--                  compiler merges down to a couple of gates.

-- In-game, init.lua loads sim/ files with loadfile and passes its own loader.
local require = type(...) == "function" and ... or require

local grid = require("sim.grid")

local demos = {}

local I = grid.index
local SIZE = grid.SIZE
local N, E, S, W = 0, 1, 2, 3

demos.TOWER_LEVELS = 5 -- nesting depth of the clock tower (64x more torches per level)

-- { {x, y, kind, attach}, ... } -> cells
local function cells_of(list)
	local cells = {}
	for _, e in ipairs(list) do
		cells[I(e[1], e[2])] = { kind = e[3], attach = e[4] }
	end
	return cells
end

-- Mirror a part list left to right, or swap x and y (a mirror across the
-- main diagonal). Both keep bit numbers along each edge, so mirrored
-- designs still link cell for cell.
local MIRROR_X = { [N] = N, [E] = W, [S] = S, [W] = E }
local TRANSPOSE = { [N] = W, [E] = S, [S] = E, [W] = N }

local function mirror_x(list)
	local out = {}
	for k, e in ipairs(list) do
		out[k] = { SIZE + 1 - e[1], e[2], e[3], e[4] and MIRROR_X[e[4]] }
	end
	return out
end

local function transpose(list)
	local out = {}
	for k, e in ipairs(list) do
		out[k] = { e[2], e[1], e[3], e[4] and TRANSPOSE[e[4]] }
	end
	return out
end

local function mirror_y(list)
	return transpose(mirror_x(transpose(list)))
end

-- Like cells_of, with nested panels as { x, y, "panel", name } (ids[name]).
local function cells_with(ids, list)
	local cells = {}
	for _, e in ipairs(list) do
		if e[3] == "panel" then
			cells[I(e[1], e[2])] = { kind = "panel", id = assert(ids[e[4]], e[4]), speed = 1 }
		else
			cells[I(e[1], e[2])] = { kind = e[3], attach = e[4] }
		end
	end
	return cells
end

-- Color every lamp in `cells`.
local function lamps_colored(cells, color)
	for _, cell in pairs(cells) do
		if cell.kind == "lamp" then cell.color = color end
	end
	return cells
end

local function concat(...)
	local out = {}
	for _, list in ipairs({ ... }) do
		for _, e in ipairs(list) do out[#out + 1] = e end
	end
	return out
end

-- Lights Out cell. One net per side, each on the same bit both ways (west
-- and east on row 3, north and south on column 4), each touched by one of
-- the two buttons. A side's output is its net minus its own input (no
-- self-echo), so it carries only this cell's press, and its input is the
-- neighbour's press. The bulb flips when any net turns on: north and west
-- touch it, east and south reach it through a block and two torches (an OR
-- that keeps the nets apart). Its lamp starts lit (the bulb flips once
-- while powering on) and goes out when pressed an odd number of times.
local LIGHT = {
	{ 4, 1, "dust" }, { 4, 2, "dust" }, -- north net
	{ 1, 3, "dust" }, { 2, 3, "dust" }, { 3, 3, "dust" }, -- west net
	{ 8, 3, "dust" }, { 8, 4, "dust" }, { 7, 4, "dust" }, { 7, 5, "dust" }, -- east net
	{ 4, 8, "dust" }, { 4, 7, "dust" }, { 5, 7, "dust" }, { 6, 7, "dust" }, { 6, 6, "dust" }, -- south net
	{ 3, 2, "button" }, { 7, 6, "button" },
	{ 4, 3, "bulb" },
	{ 6, 5, "block" }, { 5, 5, "torch", E }, { 4, 5, "block" }, { 4, 4, "torch", S }, -- east/south OR
	{ 5, 3, "torch", W }, { 6, 3, "block" }, { 6, 2, "torch", S }, { 7, 2, "lamp" }, -- lamp = bulb
}

-- Counter bit, a T flip-flop: the bulb flips when the input turns on, and
-- the carry is the bulb inverted, so the next bit flips when this one goes
-- from 1 to 0. The lamp shows the bit. Inputs and outputs span bits 3 and 4
-- of an edge, so the mirrored variants still line up.
local BIT_CORE = {
	{ 2, 5, "bulb" }, { 3, 5, "torch", W }, -- flip-flop, torch = carry
	{ 3, 4, "block" }, { 3, 3, "torch", S }, { 3, 2, "lamp" }, -- lamp = bit
}
local BIT_IN_W = { { 1, 4, "dust" }, { 1, 5, "dust" } }
local BIT_OUT_E = { { 4, 5, "dust" }, { 5, 5, "dust" }, { 6, 5, "dust" }, { 7, 5, "dust" }, { 8, 5, "dust" }, { 8, 4, "dust" } }
local BIT_OUT_S = { { 4, 5, "dust" }, { 5, 5, "dust" }, { 5, 6, "dust" }, { 5, 7, "dust" }, { 5, 8, "dust" }, { 4, 8, "dust" } }
local BIT_EAST = concat(BIT_IN_W, BIT_CORE, BIT_OUT_E) -- in west, out east
local BIT_TURN = concat(BIT_IN_W, BIT_CORE, BIT_OUT_S) -- in west, out south

-- The first bit: a torch clock instead of an input, so the counter runs on
-- its own. The clock flips every tick; bit 0 every two.
local BIT_CLOCK = {
	{ 2, 6, "block" }, { 3, 6, "torch", W }, { 3, 7, "dust" }, { 2, 7, "dust" }, -- clock
	{ 3, 5, "bulb" }, { 4, 5, "torch", W },
	{ 4, 4, "block" }, { 4, 3, "torch", S }, { 4, 2, "lamp" },
	{ 5, 5, "dust" }, { 6, 5, "dust" }, { 7, 5, "dust" }, { 8, 5, "dust" }, { 8, 4, "dust" },
}

-- The clock tower's smallest part: a torch clock driving the east edge.
-- Every level is 64 of the one below; all the clocks tick in step, so they
-- merge, and the ones whose output reaches nothing are dropped.
local TICK = {
	{ 2, 2, "block" }, { 3, 2, "torch", W }, { 3, 3, "dust" }, { 2, 3, "dust" }, -- clock
	{ 4, 2, "dust" }, { 5, 2, "dust" }, { 6, 2, "dust" }, { 7, 2, "dust" }, { 8, 2, "dust" },
}

-- Wave parts. A diode reads one side and drives the opposite one (or a
-- neighbouring one), never the other way: blocks read, torches drive.
local DIODE2 = { -- W to E, 2 ticks
	{ 1, 4, "block" }, { 2, 4, "torch", W }, { 3, 4, "block" }, { 4, 4, "torch", W },
	{ 5, 4, "dust" }, { 6, 4, "dust" }, { 7, 4, "dust" }, { 8, 4, "dust" },
}
local DIODE4 = { -- W to E, 4 ticks
	{ 1, 4, "block" }, { 2, 4, "torch", W }, { 3, 4, "block" }, { 4, 4, "torch", W },
	{ 5, 4, "block" }, { 6, 4, "torch", W }, { 7, 4, "block" }, { 8, 4, "torch", W },
}
local TURN4 = { -- S to W, 4 ticks
	{ 4, 8, "block" }, { 4, 7, "torch", S }, { 4, 6, "block" }, { 4, 5, "torch", S },
	{ 4, 4, "block" }, { 3, 4, "torch", E }, { 2, 4, "block" }, { 1, 4, "torch", E },
}

-- Pulse: when the input X (west) turns on, the output (east) is on for
-- PULSE ticks, then stays off until X has been off again. It is
-- X(t-2) and not X(t-11): a torch NOR of X inverted (1 tick) and X run
-- through two torches and two 4-tick diodes (10 ticks).
local PULSE = {
	{ 1, 4, "dust" }, { 2, 4, "block" }, { 3, 4, "torch", W }, -- X, inverted
	{ 4, 4, "block" }, { 5, 4, "torch", W }, -- X, 2 ticks late
	{ 5, 3, "panel", "wave turn" }, { 4, 3, "panel", "wave delay E-W" }, -- 10 ticks late
	{ 3, 3, "block" }, { 3, 2, "torch", S }, -- the NOR
	{ 4, 2, "dust" }, { 5, 2, "dust" }, { 6, 2, "dust" }, { 7, 2, "dust" }, { 8, 2, "dust" },
}

-- Crossover: west-east dust on row 4; north-south jumps over it through two
-- quartz in column 4, whose rows hold no other quartz.
local CROSS = {
	{ 1, 4, "dust" }, { 2, 4, "dust" }, { 3, 4, "dust" }, { 4, 4, "dust" },
	{ 5, 4, "dust" }, { 6, 4, "dust" }, { 7, 4, "dust" }, { 8, 4, "dust" },
	{ 4, 1, "dust" }, { 4, 2, "quartz" }, { 4, 6, "quartz" }, { 4, 7, "dust" }, { 4, 8, "dust" },
}

-- Wave cell. Each side reads its neighbour through a diode (so nothing
-- passes straight through a cell) on one bit, and drives the cell's light
-- on another: west reads row 2 and drives row 6, east the other way round,
-- north reads column 2 and drives column 6, south the other way round. The
-- inputs and the button meet in one wire X (crossing the light's wire at
-- the crossover) feeding the pulse. A cell lights once per wave: it reads its
-- own light back through the neighbours it lit, which holds X on until the
-- wave has moved on.
local WAVE_CELL = {
	{ 2, 1, "panel", "wave diode N-S" }, { 1, 2, "panel", "wave diode W-E" },
	{ 8, 6, "panel", "wave diode E-W" }, { 6, 8, "panel", "wave diode S-N" },
	{ 2, 2, "dust" }, { 2, 3, "dust" }, { 2, 4, "dust" }, { 3, 4, "dust" }, -- X
	{ 4, 4, "panel", "wave cross" },
	{ 5, 4, "dust" }, { 6, 4, "dust" }, { 6, 5, "dust" }, { 6, 6, "dust" }, { 7, 6, "dust" }, { 6, 7, "dust" },
	{ 2, 5, "button" },
	{ 3, 3, "panel", "wave pulse" },
	{ 4, 3, "dust" }, { 4, 2, "dust" }, { 5, 2, "dust" }, { 6, 2, "dust" }, { 6, 1, "dust" }, -- light
	{ 7, 2, "dust" }, { 8, 2, "dust" },
	{ 4, 5, "dust" }, { 4, 6, "dust" }, { 4, 7, "dust" }, { 3, 7, "dust" }, { 2, 7, "dust" }, { 2, 8, "dust" },
	{ 1, 7, "dust" }, { 1, 6, "dust" },
	{ 3, 6, "lamp" },
}

local function fill(f)
	local cells = {}
	for y = 1, SIZE do
		for x = 1, SIZE do cells[I(x, y)] = f(x, y) end
	end
	return cells
end

local function nest(id)
	return { kind = "panel", id = id, speed = 1 }
end

-- Counter layout: bits snake through the grid, left to right on odd rows
-- and right to left on even rows, starting at the top left.
local function counter_cell(ids, x, y)
	local rightward = y % 2 == 1
	if x == 1 and y == 1 then return nest(ids["counter clock bit"]) end
	if rightward then
		if x == SIZE then return nest(ids["counter bit W-S"]) end
		if x == 1 then return nest(ids["counter bit N-E"]) end
		return nest(ids["counter bit W-E"])
	end
	if x == SIZE then return nest(ids["counter bit N-W"]) end
	if x == 1 and y < SIZE then return nest(ids["counter bit E-S"]) end
	return nest(ids["counter bit E-W"])
end

-- Designs in dependency order: { name =, cells = function(ids) }, where
-- ids[name] is the library id of an earlier design. `show` marks the ones
-- /panel_demo hands out; the rest are their parts.
demos.DESIGNS = {
	{ name = "lights out cell", cells = function() return cells_of(LIGHT) end },
	{ name = "Lights Out", show = true, cells = function(ids)
		return fill(function() return nest(ids["lights out cell"]) end)
	end },

	{ name = "wave diode W-E", cells = function() return cells_of(DIODE2) end },
	{ name = "wave diode E-W", cells = function() return cells_of(mirror_x(DIODE2)) end },
	{ name = "wave diode N-S", cells = function() return cells_of(transpose(DIODE2)) end },
	{ name = "wave diode S-N", cells = function() return cells_of(mirror_y(transpose(DIODE2))) end },
	{ name = "wave delay E-W", cells = function() return cells_of(mirror_x(DIODE4)) end },
	{ name = "wave turn", cells = function() return cells_of(TURN4) end },
	{ name = "wave cross", cells = function() return cells_of(CROSS) end },
	{ name = "wave pulse", cells = function(ids) return cells_with(ids, PULSE) end },
	{ name = "wave cell", cells = function(ids) return cells_with(ids, WAVE_CELL) end },
	{ name = "Wave", show = true, cells = function(ids)
		return fill(function() return nest(ids["wave cell"]) end)
	end },

	{ name = "counter clock bit", cells = function() return cells_of(BIT_CLOCK) end },
	{ name = "counter bit W-E", cells = function() return cells_of(BIT_EAST) end },
	{ name = "counter bit E-W", cells = function() return cells_of(mirror_x(BIT_EAST)) end },
	{ name = "counter bit W-S", cells = function() return cells_of(BIT_TURN) end },
	{ name = "counter bit E-S", cells = function() return cells_of(mirror_x(BIT_TURN)) end },
	{ name = "counter bit N-E", cells = function() return cells_of(transpose(BIT_TURN)) end },
	{ name = "counter bit N-W", cells = function() return cells_of(mirror_x(transpose(BIT_TURN))) end },
	{ name = "64-bit counter", show = true, cells = function(ids)
		return fill(function(x, y) return counter_cell(ids, x, y) end)
	end },

	{ name = "tower 0", cells = function() return cells_of(TICK) end },
}

-- RGB Cycle: a counter bit per color, then one 3-bit pixel per order of
-- the colors (the first color is the fastest bit).
local RGB = { "red", "green", "blue" }
local RGB_ORDERS = { { 1, 2, 3 }, { 2, 3, 1 }, { 3, 1, 2 }, { 1, 3, 2 }, { 3, 2, 1 }, { 2, 1, 3 } }
for _, color in ipairs(RGB) do
	local add = function(d) demos.DESIGNS[#demos.DESIGNS + 1] = d end
	add({ name = "rgb clock bit " .. color, cells = function() return lamps_colored(cells_of(BIT_CLOCK), color) end })
	add({ name = "rgb bit " .. color, cells = function() return lamps_colored(cells_of(BIT_EAST), color) end })
end
for k, order in ipairs(RGB_ORDERS) do
	demos.DESIGNS[#demos.DESIGNS + 1] = { name = "rgb pixel " .. k, cells = function(ids)
		return cells_with(ids, {
			{ 3, 4, "panel", "rgb clock bit " .. RGB[order[1]] },
			{ 4, 4, "panel", "rgb bit " .. RGB[order[2]] },
			{ 5, 4, "panel", "rgb bit " .. RGB[order[3]] },
		})
	end }
end
demos.DESIGNS[#demos.DESIGNS + 1] = { name = "RGB Cycle", show = true, cells = function(ids)
	return fill(function(x, y) return nest(ids["rgb pixel " .. ((x + y) % #RGB_ORDERS + 1)]) end)
end }
for level = 1, demos.TOWER_LEVELS do
	demos.DESIGNS[#demos.DESIGNS + 1] = { name = "tower " .. level, cells = function(ids)
		return fill(function() return nest(ids["tower " .. (level - 1)]) end)
	end }
end
-- Columns of towers, each lighting a column of lamps east of it.
demos.DESIGNS[#demos.DESIGNS + 1] = { name = "Clock Tower", show = true, cells = function(ids)
	return fill(function(x)
		if x % 2 == 1 then return nest(ids["tower " .. demos.TOWER_LEVELS]) end
		return { kind = "lamp" }
	end)
end }

-- Add the demo designs to `add(cells, name)`, which returns an id.
-- Returns ids[name] and the list of names to hand out.
function demos.build(add)
	local ids, shown = {}, {}
	for _, d in ipairs(demos.DESIGNS) do
		ids[d.name] = add(d.cells(ids), d.name)
		if d.show then shown[#shown + 1] = d.name end
	end
	return ids, shown
end

-- Parts in design `id`, counting everything inside nested panels as if it
-- were built out flat: { parts =, torches = }. lib[id].cells as in sim/.
function demos.count(lib, id, memo)
	memo = memo or {}
	if memo[id] then return memo[id] end
	local c = { parts = 0, torches = 0 }
	for _, cell in pairs(lib[id].cells) do
		if cell.kind == "panel" then
			local k = demos.count(lib, cell.id, memo)
			c.parts, c.torches = c.parts + k.parts, c.torches + k.torches
		else
			c.parts = c.parts + 1
			if cell.kind == "torch" then c.torches = c.torches + 1 end
		end
	end
	memo[id] = c
	return c
end

return demos
