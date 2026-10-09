local grid = require("sim.grid")

return {
	["set and get round-trip"] = function()
		local g = grid.new()
		grid.set(g, 3, 5, { kind = "torch", attach = 2 })
		assert(grid.get(g, 3, 5).kind == "torch")
		assert(grid.get(g, 5, 3) == nil)
	end,

	["same_cells compares designs, not tables"] = function()
		local a = { [grid.index(2, 2)] = { kind = "torch", attach = 3 }, [grid.index(1, 2)] = { kind = "block" } }
		local b = { [grid.index(1, 2)] = { kind = "block" }, [grid.index(2, 2)] = { kind = "torch", attach = 3 } }
		assert(grid.same_cells(a, b))
		b[grid.index(2, 2)].attach = 1
		assert(not grid.same_cells(a, b), "different attach")
		b[grid.index(2, 2)].attach = 3
		b[grid.index(5, 5)] = { kind = "dust" }
		assert(not grid.same_cells(a, b), "extra cell")
		assert(not grid.same_cells(b, a), "missing cell")
		assert(grid.same_cells({}, {}))
	end,

	["turn_port follows the corners round"] = function()
		local function port(d, b) return d * grid.SIZE + b end
		-- One clockwise turn: the top-left corner goes to the top-right.
		assert(grid.turn_port(port(0, 0), 1) == port(1, 0), "N0 -> E0")
		assert(grid.turn_port(port(0, 7), 1) == port(1, 7), "N7 -> E7")
		assert(grid.turn_port(port(1, 0), 1) == port(2, 7), "E0 -> S7")
		assert(grid.turn_port(port(2, 0), 1) == port(3, 0), "S0 -> W0")
		assert(grid.turn_port(port(3, 0), 1) == port(0, 7), "W0 -> N7")
		for p = 0, grid.PORTS - 1 do
			assert(grid.turn_port(p, 0) == p and grid.turn_port(p, nil) == p)
			assert(grid.turn_port(p, 4) == p, "four turns are none")
			assert(grid.turn_port(grid.turn_port(p, 1), 3) == p)
			assert(grid.turn_port(p, 2) == grid.turn_port(grid.turn_port(p, 1), 1))
		end
	end,

	["edge cells"] = function()
		assert(grid.is_edge(1, 4))
		assert(grid.is_edge(8, 8))
		assert(not grid.is_edge(2, 7))
	end,

	["ports sit just outside the edge cells"] = function()
		-- North bit 0 is above (1,1); east bit 7 is right of (8,8).
		assert(grid.port_at(grid.index(1, 0)) == 0)
		assert(grid.port_at(grid.index(9, 8)) == 15)
		assert(grid.port_inner(0) == grid.index(1, 1))
		assert(grid.port_inner(15) == grid.index(8, 8))
		assert(grid.port_inner(31) == grid.index(1, 8))
		assert(grid.port_at(grid.index(0, 0)) == nil, "corners are not ports")
	end,

	["neighbors"] = function()
		local i = grid.index(4, 4)
		assert(grid.neighbor(i, 0) == grid.index(4, 3))
		assert(grid.neighbor(i, 1) == grid.index(5, 4))
		assert(grid.neighbor(grid.index(0, 0), 3) == nil)
	end,
}
