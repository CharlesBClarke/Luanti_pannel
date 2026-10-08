-- Pure Lua: no core.* calls allowed in sim/ so it runs under plain LuaJIT.

local grid = {}

grid.SIZE = 8
grid.BUTTON_TICKS = 10

-- Cell kinds from the spec.
grid.EMPTY = 0
grid.DUST = 1
grid.BLOCK = 2
grid.TORCH = 3
grid.QUARTZ = 4
grid.BULB = 5
grid.LAMP = 6

function grid.new()
	local g = { cells = {} }
	for i = 1, grid.SIZE * grid.SIZE do
		g.cells[i] = grid.EMPTY
	end
	return g
end

local function index(x, y)
	return (y - 1) * grid.SIZE + x
end

function grid.get(g, x, y)
	return g.cells[index(x, y)]
end

function grid.set(g, x, y, kind)
	g.cells[index(x, y)] = kind
end

-- True if (x, y) is on the edge, i.e. connects to the outside.
function grid.is_edge(x, y)
	return x == 1 or y == 1 or x == grid.SIZE or y == grid.SIZE
end

return grid
