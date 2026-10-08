std = "luajit"
max_line_length = 120
exclude_files = { ".smoke/" }

globals = { "redstone_panels" }
read_globals = {
	"core", "vector", "ItemStack", "VoxelArea",
	"mesecon",
}

-- sim/ must stay pure Lua so it runs outside the game.
files["sim/"] = { read_globals = {} , globals = {} }
files["tests/"] = { std = "+luajit" }
