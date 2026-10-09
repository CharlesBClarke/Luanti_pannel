local modname = core.get_current_modname()
local modpath = core.get_modpath(modname)

redstone_panels = {}

-- sim/ files are plain Lua modules (they return a table), so tests can load
-- them outside the game. They take this loader as their chunk argument,
-- since mods can't use the global `require`.
local loaded = {}
local function sim_require(name)
	if loaded[name] == nil then
		local chunk = assert(loadfile(modpath .. "/" .. name:gsub("%.", "/") .. ".lua"))
		loaded[name] = chunk(sim_require)
	end
	return loaded[name]
end

local sim = {
	grid = sim_require("sim.grid"),
	compile = sim_require("sim.compile"),
	runtime = sim_require("sim.runtime"),
	floor = sim_require("sim.floor"),
	thumb = sim_require("sim.thumb"),
	edit = sim_require("sim.edit"),
	stress = sim_require("sim.stress"),
}

local function load(file, ...)
	return assert(loadfile(modpath .. "/" .. file))(...)
end

local library = load("library.lua", sim)
local world = load("world.lua", sim, library)
local editor = load("editor.lua", sim, library)

redstone_panels.sim = sim
redstone_panels.library = library
redstone_panels.world = world
redstone_panels.editor = editor

load("bench.lua", sim, library, world)

-- Lets scripts/smoke.sh start a server, run a small scenario, and exit.
if core.settings:get_bool("redstone_panels.smoke_test", false) then
	load("smoke.lua", sim, library, world, editor)
end
