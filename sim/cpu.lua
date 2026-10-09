-- A small real computer built from panels: the CPU stand-in for the
-- benchmark (docs/todo.md, Optimizations item 6). Pure Lua: no core.* calls
-- allowed in sim/.
--
-- It runs one program forever, a Fibonacci-style sequence written to RAM:
--   S0  RAM[X] = A
--   S1  A = A + B
--   S2  B = RAM[X], X = X + 1
--   S3  (idle)
-- from whatever A, B and X hold at power on. Each step takes CYCLE_TICKS.
--
-- Three levels. Cells are drawn from parts (8x8). Tiles are 8x8 cells laid
-- out as bit slices: column c is bit c - 1, buses run down the columns, and
-- each row's control line comes in from the west. The computer is one panel
-- of 8x8 tiles (cpu.FLOOR), so it fits in one block:
--   row 1     the data bus, joining the RAM columns
--   rows 2-5  RAM tiles (4 bytes each), each with its address decoder to
--             the west: 64 bytes
--   row 6     the address bus (A0..A5, write, read), up into the decoders
--   rows 7-8  X counter, control (clock, step counter, decoding), ALU
--
-- Inside a tile, cells meet cell for cell, eight wires per side; a tile
-- meets a neighbouring tile the same way. A cell's side facing a single
-- cell or the outside is one wire (spec: Grid and edges), so a tile's pin
-- is its edge cell's whole side.
--
-- Wire positions inside cells: horizontal lanes on row 5 (or 4) and the
-- data bus on column 4 unless a drawing says otherwise. A cell side can
-- carry at most three wires (neighbouring edge cells would touch).
--
-- The denser cells' layouts came from scripts/solve.lua.

-- In-game, init.lua loads sim/ files with loadfile and passes its own loader.
local require = type(...) == "function" and ... or require

local grid = require("sim.grid")
local art = require("sim.art")

local cpu = {}

local SIZE = grid.SIZE
local I = grid.index

cpu.ADDRESS_BITS = 6 -- 64 bytes of RAM
cpu.RAM_TILES = 2 ^ cpu.ADDRESS_BITS / 4 -- 4 bytes per tile
cpu.WE_LANE, cpu.RE_LANE = 7, 8 -- address bus columns after A0..A5 (active low)
cpu.COUNTER_BITS = 7 -- clock divider: phases from bits 3-4, step from bits 5-6
cpu.CYCLE_TICKS = 64 -- the clock flips every tick; bit 4 of the divider has period 64

--------------------------------------------------------------------------
-- Cells
--------------------------------------------------------------------------

-- Plain wires. A star joins the arms it has at (4, 5); a cross carries a
-- west-east wire and a separate north-south one, jumping it on quartz.
local function star(arms)
	local cells = { [I(4, 5)] = { kind = "dust" } }
	local function dust(x, y) cells[I(x, y)] = { kind = "dust" } end
	if arms:find("N") then for y = 1, 4 do dust(4, y) end end
	if arms:find("S") then for y = 6, 8 do dust(4, y) end end
	if arms:find("W") then for x = 1, 3 do dust(x, 5) end end
	if arms:find("E") then for x = 5, 8 do dust(x, 5) end end
	return cells
end
local function cross(west, east)
	local cells = {}
	for x = west and 1 or 2, east and SIZE or SIZE - 1 do cells[I(x, 5)] = { kind = "dust" } end
	cells[I(4, 1)] = { kind = "quartz" }
	cells[I(4, 8)] = { kind = "quartz" }
	return cells
end
local function without_west(rows)
	local cells = art.cells(rows)
	cells[I(1, 5)] = nil
	return cells
end

-- RAM bit, in two cells stacked: storage on top, port below. Wires:
--   WS  write select, active high, west to east (storage)
--   nRS read select, active low, west to east (port)
--   D   data, both ways, north to south through both
--   Qn  the stored bit inverted, storage to port on column 7
-- The bit lives in a copper bulb. While WS is on, the bulb flips if it
-- differs from D (two gates, one per direction, so it flips once and
-- stops). While nRS is off, the port drives D with the bit. The bulb flips
-- once while powering on, so RAM starts as all ones. The lamp shows the bit.
local RAM_STORE = {
	". . . q . . . .",
	". . . B < . . .",
	". . q . + . . .",
	". . v + B + L .",
	"q + B . ^ v . q",
	". . . v U B . .",
	". . q B ^ + + .",
	". . . q . . + .",
}
local RAM_PORT = {
	". . . + . . + .",
	". . . + . . + .",
	". . . + . . + .",
	". . . + . . + .",
	"q . . + + > B q",
	". . . + . . . .",
	". . . + . . . .",
	". . . + . . . .",
}

-- Decoder cells. The vertical lane is one address (or control) bit passing
-- through; the west-east wire collects mismatches (on when some bit is
-- wrong). A "1" cell adds a mismatch when its bit is off, a "0" cell when
-- it is on; the inverter turns the mismatch wire into an active-high select.
local DEC_1 = {
	". . . q . . . .",
	". . . B . . . .",
	". . . ^ . . . .",
	". . . + . . . .",
	"+ + + + + + + +",
	". . . . . . . .",
	". . . . . . . .",
	". . . q . . . .",
}
local DEC_0 = {
	". . . q . . . .",
	". . . B . . . .",
	". . . ^ B < . .",
	". . . . . + . .",
	"+ + + + + + + +",
	". . . . . . . .",
	". . . . . . . .",
	". . . q . . . .",
}
local DEC_INV = {
	". . . q . . . .",
	". . . . . . . .",
	". . . . . . . .",
	". . . . . . . .",
	"+ + B < + + + +",
	". . . . . . . .",
	". . . . . . . .",
	". . . q . . . .",
}

-- Counter bit for the clock divider: flips when the wire from the east
-- turns on, passes its inverse west (so the next bit flips when this one
-- turns off), and shows its value north and south on column 4 and on a lamp.
local COUNT_BIT = {
	". . . q . . . .",
	". . . + . . . .",
	". . . + v L . .",
	". . . . B . . .",
	"+ + + + > U + +",
	". . . . . . . .",
	". . . . . . . .",
	". . . q . . . .",
}
-- The same counting west to east, value north only: the X counter. Its
-- first bit counts the wire from the south (column 3).
local X_BIT = {
	". . . q . . . .",
	". . . + . . . .",
	". . L v . . . .",
	". . . B . . . .",
	"+ + U < + + + +",
	". . . . . . . .",
	". . . . . . . .",
	". . . . . . . .",
}
local X_BIT0 = {
	". . . q . . . .",
	". . . + . . . .",
	". . L v . . . .",
	". . . B . . . .",
	". . U < + + + +",
	". . + . . . . .",
	". . + . . . . .",
	". . + . . . . .",
}
-- A torch reading its own block: flips every tick, out to the west.
local CLOCK = {
	". . . . . . . .",
	". . . . . . . .",
	". . . . . . . .",
	". . . . . . . .",
	"+ + + > B . . .",
	". . . + + . . .",
	". . . . . . . .",
	". . . . . . . .",
}

-- ALU cells (layouts from scripts/solve.lua). Lanes: data bus on column 4;
-- A down column 2; the master's inverted bit (column 7) to the cell below.
--   alu slave  A slave: a nor latch (set and reset gated by its line,
--              active low) copying the master (from column 7); A out on
--              column 2, lamp shows A. It may oscillate until its first copy.
--   alu drive  drives the bus with A (column 2, passing on) while its
--              west-east line is off
--   alu latch  B latch: a nor latch loading the bus while its line is off,
--              A passing on column 2, its inverted bit out on column 7
--   alu xnor   B from the latch, then n4 = xnor(A, B) out on column 2 and
--              n1 = nor(A, B) on column 6
--   alu carry  carry from the west: carry out east = nor(n1, nor(n4, carry));
--              passes carry down column 2 and n4 down column 6
--   alu sum    sum = xnor(n4, carry), onto the bus while its line is off
cpu.ALU_CELLS = {
	["alu latch"] = {
		". q . + . . . .",
		". . . q . . q .",
		". + > B . . . .",
		". + . L . . q .",
		"q B < > B > B q",
		". . + B < . . .",
		". q . . + + + .",
		". + . q . . + .",
	},
	["alu slave"] = {
		". . . q . . + .",
		". . q . + . q .",
		". > B . . . . .",
		". + . . . . q .",
		"q B < . . > B q",
		". L B + > B . .",
		". q ^ . . q . .",
		". + . q . . . .",
	},
	["alu carry"] = {
		". + . q . + . .",
		". q . . . + + .",
		". q . . q . + .",
		". . . + B < B .",
		"q + + + . . ^ +",
		". + . + . . . .",
		". + . . q + . .",
		". + . q . + . .",
	},
	["alu xnor"] = {
		". + . q . . + .",
		". + + . > B q .",
		". . + B + . . .",
		". > B ^ B < . .",
		". q . + . q . .",
		". B . + + . . .",
		". ^ q . + + . .",
		". + . q . + . .",
	},
	["alu drive"] = {
		". q . + . . . .",
		". + . q . q . .",
		". . + + . . . .",
		". v + . . . . .",
		"q B . . . . q +",
		". v . . . . . .",
		". B . q . . . .",
		". q . + . . . .",
	},
	["alu sum"] = {
		". + . q . + . .",
		". + + . + + . .",
		". . + B + . . .",
		". + B ^ B . . .",
		"q . ^ . ^ . + q",
		". q + . q . + .",
		". . . > B + + .",
		". . . q . . . .",
	},
}

--------------------------------------------------------------------------
-- Tiles
--------------------------------------------------------------------------

local function nest(ids, name)
	return { kind = "panel", id = assert(ids[name], name), speed = 1 }
end
local function fill(f)
	local cells = {}
	for y = 1, SIZE do
		for x = 1, SIZE do cells[I(x, y)] = f(x, y) end
	end
	return cells
end
local function arms(list)
	local s = {}
	for _, a in ipairs({ "N", "E", "S", "W" }) do
		if list[a] then s[#s + 1] = a end
	end
	return "wire " .. table.concat(s)
end
local function cross_name(west, east)
	return "cross" .. (west and "" or " -w") .. (east and "" or " -e")
end

-- RAM tile: 4 bytes, each a storage row over a port row. West pins: WS and
-- nRS of byte k on rows 2k + 1 and 2k + 2. North and south pins: the data bus.
local function ram_tile(ids)
	return fill(function(_, y)
		return nest(ids, y % 2 == 1 and "ram store" or "ram port")
	end)
end

-- Decoder tile for RAM tile t: north and south pins are the address bus
-- (A0..A5, nWE, nRE on columns 1..8, passing through); east pins are the
-- selects for the RAM tile to its east. Its west side stays unconnected.
local function ram_decoder(ids, t)
	return fill(function(x, y)
		local k = math.floor((y - 1) / 2)
		local write = y % 2 == 1
		local suffix = x == 1 and " -w" or ""
		if x <= cpu.ADDRESS_BITS then
			local a = 4 * t + k
			local b = math.floor(a / 2 ^ (x - 1)) % 2
			return nest(ids, (b == 1 and "dec 1" or "dec 0") .. suffix)
		elseif x == cpu.WE_LANE then
			return nest(ids, write and "dec 0" or "cross")
		else
			return nest(ids, write and "dec inv" or "dec 0")
		end
	end)
end

-- Data bus tile: eight west-east lanes; a drop tile also brings lane c down
-- column c to its south pins. `west`/`east` false keep that side closed.
local function bus_tile(ids, drop, west, east)
	return fill(function(x, y)
		local w, e = west or x > 1, east or x < SIZE
		if not drop or y < x then return nest(ids, arms({ W = w, E = e })) end
		if y == x then return nest(ids, arms({ W = w, E = e, S = true })) end
		return nest(ids, cross_name(w, e))
	end)
end

-- Address bus tile: eight west-east lanes; a drop tile also brings lane c up
-- column c to its north pins (and, with `south`, in from its south pins);
-- the other kind lets the data bus cross north to south.
local function address_tile(ids, drop, south, west, east)
	return fill(function(x, y)
		local w, e = west or x > 1, east or x < SIZE
		if not drop then return nest(ids, cross_name(w, e)) end
		if y == x then return nest(ids, arms({ W = w, E = e, N = true, S = south })) end
		if y < x or south then return nest(ids, cross_name(w, e)) end
		return nest(ids, arms({ W = w, E = e }))
	end)
end

-- Decoding rows: cells per column 1..4 (lanes c6, c5, c4, c3 of the step
-- and phase counter), then plain wire, then an inverter or plain wire.
-- want[k] is 1, 0 or nil (don't care) for lane k.
local function decode_row(ids, x, want, invert, west)
	if x <= 4 then
		local w = want[x]
		local base = w == 1 and "dec 1" or w == 0 and "dec 0" or "cross"
		return nest(ids, base .. ((x == 1 and not west) and " -w" or ""))
	end
	if x == SIZE and invert then return nest(ids, "dec inv") end
	return nest(ids, arms({ W = true, E = true }))
end

-- Control tile: the clock and counter on the bottom row (clock in column
-- 8, counter bits c0..c6 in columns 7..1), decoding rows above. East pins
-- feed the ALU's west pins; south pins pass c6..c3 on to the second
-- control tile.
-- Phases come from counter bits c4 c3: 00 settle, 01 load, 10 gap, 11
-- copy. The divider ripples from low bits up, so passing 11 -> 00 it reads
-- 10 for a moment, and 01 -> 10 reads 00; only 01 and 11 never show up by
-- accident, so only they gate anything.
local CONTROL_ROWS = {
	[1] = { want = { 0, 1, 0, 1 }, invert = true }, -- A load: load phase of S1
	[2] = { want = { nil, nil, 1, 1 } }, -- A slave copies (active low): copy phase
	[3] = { want = { 0, 0 } }, -- A drives the bus (active low): S0
	[4] = { want = { 1, 0, 0, 1 } }, -- B loads (active low): load phase of S2
	[7] = { want = { 0, 1 } }, -- sum drives the bus (active low): S1
}
local function control_tile(ids)
	return fill(function(x, y)
		if y == SIZE then return nest(ids, x == SIZE and "clock" or "count bit") end
		local row = CONTROL_ROWS[y]
		if row then return decode_row(ids, x, row.want, row.invert, false) end
		if x <= 4 then return nest(ids, arms({ N = true, S = true })) end
		return nil
	end)
end

-- Second control tile: lines out to the west, active low: write (load
-- phase of S0), X step (copy phase of S2), read (all of S2).
local CONTROL2_ROWS = {
	[1] = { 0, 0, 0, 1 },
	[2] = { 1, 0, 1, 1 },
	[3] = { 1, 0 },
}
local function control2_tile(ids)
	return fill(function(x, y)
		local want = CONTROL2_ROWS[y]
		if want and x <= 4 then return decode_row(ids, x, want, false, true) end
		return nil
	end)
end

-- Relays from the second control tile (east pins, rows 1..3) to the X tile
-- (north pins): write to column 7, X step to column 1, read to column 8.
local function relay_tile(ids, last)
	if not last then
		return fill(function(_, y)
			return y <= 3 and nest(ids, arms({ W = true, E = true })) or nil
		end)
	end
	local cells = {}
	local function at(x, y, name) cells[I(x, y)] = nest(ids, name) end
	at(8, 1, cross_name(true, true))
	at(8, 2, cross_name(true, true))
	at(8, 3, arms({ E = true, N = true }))
	at(7, 1, arms({ E = true, N = true }))
	for x = 2, 7 do at(x, 2, arms({ W = true, E = true })) end
	at(1, 2, arms({ E = true, N = true }))
	at(1, 1, arms({ N = true, S = true }))
	return cells
end

-- X tile: a 6-bit counter on the bottom row (bit 0 counts the step line
-- from the south pin of column 1), its bits up columns 1..6 to the north
-- pins; write and read pass straight up columns 7 and 8.
local function x_tile(ids)
	return fill(function(x, y)
		if x > cpu.ADDRESS_BITS then return nest(ids, arms({ N = true, S = true })) end
		if y < SIZE then return nest(ids, arms({ N = true, S = true })) end
		return nest(ids, x == 1 and "x bit 0" or "x bit")
	end)
end

-- ALU tile, rows (west pin):
--   1 A master (A load)          2 A slave (copy, active low)
--   3 A to bus (active low)      4 B latch (load, active low)
--   5 xnor of A and B            6 carry (carry in: 0)
--   7 sum to bus (active low)
local ALU_ROWS = { "ram store", "alu slave", "alu drive", "alu latch", "alu xnor", "alu carry", "alu sum" }
local function alu_tile(ids)
	return fill(function(_, y)
		return ALU_ROWS[y] and nest(ids, ALU_ROWS[y]) or nil
	end)
end

-- The computer: tile (x, y) on the 8x8 floor.
local function computer(ids)
	return fill(function(x, y)
		local ram_column = x % 2 == 0
		if y == 1 then
			return nest(ids, ram_column and (x == SIZE and "bus drop -e" or "bus drop") or (x == 1 and "bus -w" or "bus"))
		elseif y <= 5 then
			local t = (math.floor(x / 2) - (ram_column and 1 or 0)) * 4 + (y - 2)
			return nest(ids, ram_column and "ram tile" or "ram decoder " .. t)
		elseif y == 6 then
			if x == 1 then return nest(ids, "address in -w") end
			return nest(ids, ram_column and (x == SIZE and "address cross -e" or "address cross") or "address drop")
		elseif y == 7 then
			if x == 1 then return nest(ids, "x tile") end
			if x == 3 then return nest(ids, "control") end
			if x == 4 then return nest(ids, "alu") end
		elseif y == SIZE then
			if x == 1 then return nest(ids, "relay last") end
			if x == 2 then return nest(ids, "relay") end
			if x == 3 then return nest(ids, "control 2") end
		end
		return nil
	end)
end

--------------------------------------------------------------------------
-- Designs
--------------------------------------------------------------------------

-- Designs in dependency order: { name =, cells = function(ids) }.
cpu.DESIGNS = {}
local function design(name, f)
	cpu.DESIGNS[#cpu.DESIGNS + 1] = { name = name, cells = f }
end
local function drawing(rows) return function() return art.cells(rows) end end

design("ram store", drawing(RAM_STORE))
design("ram port", drawing(RAM_PORT))
design("dec 1", drawing(DEC_1))
design("dec 1 -w", function() return without_west(DEC_1) end)
design("dec 0", drawing(DEC_0))
design("dec 0 -w", function() return without_west(DEC_0) end)
design("dec inv", drawing(DEC_INV))
design("count bit", drawing(COUNT_BIT))
design("x bit", drawing(X_BIT))
design("x bit 0", drawing(X_BIT0))
design("clock", drawing(CLOCK))
for _, w in ipairs({ true, false }) do
	for _, e in ipairs({ true, false }) do
		design(cross_name(w, e), function() return cross(w, e) end)
	end
end
-- Every star.
for m = 1, 15 do
	local list = {}
	for k, a in ipairs({ "N", "E", "S", "W" }) do
		if math.floor(m / 2 ^ (k - 1)) % 2 == 1 then list[a] = true end
	end
	local name = arms(list)
	design(name, function() return star(name:sub(6)) end)
end
for _, name in ipairs({ "alu slave", "alu drive", "alu latch", "alu xnor", "alu carry", "alu sum" }) do
	local rows = cpu.ALU_CELLS[name]
	design(name, rows and drawing(rows) or function() return {} end) -- TODO: unsolved cells
end

design("ram tile", ram_tile)
for t = 0, cpu.RAM_TILES - 1 do design("ram decoder " .. t, function(ids) return ram_decoder(ids, t) end) end
design("bus", function(ids) return bus_tile(ids, false, true, true) end)
design("bus -w", function(ids) return bus_tile(ids, false, false, true) end)
design("bus drop", function(ids) return bus_tile(ids, true, true, true) end)
design("bus drop -e", function(ids) return bus_tile(ids, true, true, false) end)
design("address drop", function(ids) return address_tile(ids, true, false, true, true) end)
design("address in -w", function(ids) return address_tile(ids, true, true, false, true) end)
design("address cross", function(ids) return address_tile(ids, false, false, true, true) end)
design("address cross -e", function(ids) return address_tile(ids, false, false, true, false) end)
design("control", control_tile)
design("control 2", control2_tile)
design("relay", function(ids) return relay_tile(ids, false) end)
design("relay last", function(ids) return relay_tile(ids, true) end)
design("x tile", x_tile)
design("alu", alu_tile)
design("computer", computer)

cpu.star = star
cpu.CONTROL_ROWS = CONTROL_ROWS

-- Add the designs to `add(cells, name)`, which returns an id. Returns ids[name].
function cpu.build(add)
	local ids = {}
	for _, d in ipairs(cpu.DESIGNS) do
		ids[d.name] = add(d.cells(ids), "cpu " .. d.name)
	end
	return ids
end

return cpu
