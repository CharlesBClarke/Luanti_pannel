local grid = require("sim.grid")

return {
	["set and get round-trip"] = function()
		local g = grid.new()
		grid.set(g, 3, 5, { kind = "torch", attach = 2 })
		assert(grid.get(g, 3, 5).kind == "torch")
		assert(grid.get(g, 5, 3) == nil)
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
