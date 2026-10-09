-- Stress designs for benchmarking. Pure Lua: no core.* calls allowed in sim/.
--
-- The compiler merges identical logic (64 copies of one clock compile to a
-- single clock), so these designs are built to stay big: chains of torch
-- stages fed from a clock, so every stage sees a different phase and is
-- busy every tick.

-- In-game, init.lua loads sim/ files with loadfile and passes its own loader.
local require = type(...) == "function" and ... or require

local grid = require("sim.grid")

local stress = {}

local I = grid.index
local SIZE = grid.SIZE

local function fill(f)
	local cells = {}
	for y = 1, SIZE do
		for x = 1, SIZE do cells[I(x, y)] = f(x, y) end
	end
	return cells
end

-- Designs in dependency order: { name =, cells = function(ids) }, where
-- ids[name] is the library id of an earlier design.
stress.DESIGNS = {
	-- A clock: a torch on a block, its dust feeding the block back, so it
	-- flips every tick. Drives the east edge and a lamp (beside the wire:
	-- a lamp in line would block it).
	{ name = "clock", cells = function()
		return {
			[I(2, 2)] = { kind = "block" }, [I(3, 2)] = { kind = "torch", attach = 3 },
			[I(3, 3)] = { kind = "dust" }, [I(2, 3)] = { kind = "dust" },
			[I(4, 2)] = { kind = "dust" }, [I(5, 2)] = { kind = "dust" }, [I(5, 1)] = { kind = "lamp" },
			[I(6, 2)] = { kind = "dust" }, [I(7, 2)] = { kind = "dust" },
			[I(8, 2)] = { kind = "dust" },
		}
	end },
	-- A stage: 8 lanes from the west edge to the east edge, each through
	-- three torches, with lamps on every other lane.
	{ name = "stage", cells = function()
		local c = {}
		for y = 1, SIZE do
			c[I(1, y)] = { kind = "dust" }
			for k = 0, 2 do
				c[I(2 + 2 * k, y)] = { kind = "block" }
				c[I(3 + 2 * k, y)] = { kind = "torch", attach = 3 }
			end
			c[I(8, y)] = { kind = y % 2 == 0 and "lamp" or "dust" }
		end
		return c
	end },
	-- 8 clocks down the west column, each driving a row of 7 stages:
	-- busy every tick, and the face changes every tick.
	{ name = "busy", cells = function(ids)
		return fill(function(x)
			return { kind = "panel", id = x == 1 and ids.clock or ids.stage, speed = 1 }
		end)
	end },
	-- Rows of stages with no clock: still once settled, so it should cost
	-- almost nothing per tick (spec: an idle survival base). The top and
	-- bottom rows stay empty: stages wire their lanes to their north and
	-- south edges, and a floor of these would link lanes into torch rings.
	{ name = "idle", cells = function(ids)
		return fill(function(_, y)
			if y == 1 or y == SIZE then return nil end
			return { kind = "panel", id = ids.stage, speed = 1 }
		end)
	end },
	-- A deeper one: rows of "busy" panels chained edge to edge.
	{ name = "heavy", cells = function(ids)
		return fill(function(x, y)
			if y > 2 then return nil end
			return { kind = "panel", id = ids.busy, speed = 1 }
		end)
	end },
}

-- Add the stress designs to `add(cells, name)`, which returns an id.
-- Returns ids[name].
function stress.build(add)
	local ids = {}
	for _, d in ipairs(stress.DESIGNS) do
		ids[d.name] = add(d.cells(ids), "stress " .. d.name)
	end
	return ids
end

return stress
