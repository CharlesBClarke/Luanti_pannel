local grid = require("sim.grid")
local edit = require("sim.edit")

local I = grid.index

return {
	["a torch needs a base"] = function()
		local cells = {}
		assert(edit.place(cells, I(3, 3), { kind = "torch" }), "no base: refused")
		assert(cells[I(3, 3)] == nil)
		assert(edit.place(cells, I(3, 4), { kind = "block" }) == nil)
		assert(edit.place(cells, I(3, 3), { kind = "torch" }) == nil)
		assert(cells[I(3, 3)].attach == 2, "stands on the block below")
	end,

	["a taken cell is refused"] = function()
		local cells = { [I(2, 2)] = { kind = "dust" } }
		assert(edit.place(cells, I(2, 2), { kind = "block" }))
		assert(cells[I(2, 2)].kind == "dust")
		assert(edit.place(cells, I(0, 2), { kind = "dust" }), "port ring is not a cell")
	end,

	["putting a torch back picks the next base"] = function()
		local cells = { [I(3, 4)] = { kind = "block" }, [I(2, 3)] = { kind = "bulb" }, [I(4, 3)] = { kind = "block" } }
		local seen = {}
		local after
		for _ = 1, 3 do
			assert(edit.place(cells, I(3, 3), { kind = "torch" }, after) == nil)
			after = cells[I(3, 3)].attach
			seen[#seen + 1] = after
			edit.remove(cells, I(3, 3))
		end
		assert(seen[1] == 2 and seen[2] == 3 and seen[3] == 1, table.concat(seen, ","))
		assert(edit.place(cells, I(3, 3), { kind = "torch" }, 1) == nil)
		assert(cells[I(3, 3)].attach == 2, "wraps round")
	end,

	["a torch moves to another base or falls off"] = function()
		local cells = { [I(3, 4)] = { kind = "block" }, [I(2, 3)] = { kind = "block" } }
		edit.place(cells, I(3, 3), { kind = "torch" })
		local cell, fallen = edit.remove(cells, I(3, 4))
		assert(cell.kind == "block" and #fallen == 0)
		assert(cells[I(3, 3)].attach == 3, "moved to the block on its west")
		cell, fallen = edit.remove(cells, I(2, 3))
		assert(#fallen == 1 and fallen[1] == I(3, 3) and cells[I(3, 3)] == nil, "fell off")
	end,

	["moving cells"] = function()
		local cells = { [I(1, 1)] = { kind = "block" } }
		edit.place(cells, I(2, 1), { kind = "torch" })
		assert(cells[I(2, 1)].attach == 3)
		-- Moving the torch somewhere with no base is refused and changes nothing.
		assert(edit.move(cells, I(2, 1), I(6, 6)))
		assert(cells[I(2, 1)].attach == 3 and cells[I(6, 6)] == nil)
		-- Moving the block away drops the torch.
		local err, fallen = edit.move(cells, I(1, 1), I(5, 5))
		assert(err == nil and #fallen == 1 and cells[I(2, 1)] == nil)
		assert(cells[I(5, 5)].kind == "block" and cells[I(1, 1)] == nil)
		-- A torch moved next to a block stands on it.
		edit.place(cells, I(5, 4), { kind = "torch" })
		assert(cells[I(5, 4)].attach == 2)
		err = edit.move(cells, I(5, 4), I(4, 5))
		assert(err == nil and cells[I(4, 5)].attach == 1)
		assert(edit.move(cells, I(4, 5), I(5, 5)), "can't move onto a taken cell")
	end,

	["a nested panel keeps its turn when moved"] = function()
		local cells = { [I(1, 1)] = { kind = "panel", id = 3, speed = 1, turn = 2 } }
		assert(edit.move(cells, I(1, 1), I(4, 4)) == nil)
		assert(cells[I(4, 4)].turn == 2 and cells[I(4, 4)].id == 3)
	end,
}
