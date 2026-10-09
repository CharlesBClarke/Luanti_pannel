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
