local grid = require("sim.grid")

return {
	["new grid is 8x8 and empty"] = function()
		local g = grid.new()
		assert(#g.cells == 64)
		assert(grid.get(g, 8, 8) == grid.EMPTY)
	end,

	["set and get round-trip"] = function()
		local g = grid.new()
		grid.set(g, 3, 5, grid.TORCH)
		assert(grid.get(g, 3, 5) == grid.TORCH)
		assert(grid.get(g, 5, 3) == grid.EMPTY)
	end,

	["edge cells"] = function()
		assert(grid.is_edge(1, 4))
		assert(grid.is_edge(8, 8))
		assert(not grid.is_edge(2, 7))
	end,
}
