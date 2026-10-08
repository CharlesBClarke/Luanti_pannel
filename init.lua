local modname = core.get_current_modname()
local modpath = core.get_modpath(modname)

redstone_panels = {}

-- sim/ files are plain Lua modules (they return a table), so tests can
-- load them outside the game.
redstone_panels.grid = dofile(modpath .. "/sim/grid.lua")

local side = "[fill:16x16:#3a3a3a"
local face = "[fill:16x16:#3a3a3a^[fill:14x14:1,1:#1e1e1e"

core.register_node("redstone_panels:panel", {
	description = "Redstone Panel",
	tiles = { side, side, side, side, side, face },
	paramtype2 = "facedir",
	is_ground_content = false,
	groups = { pickaxey = 1, mesecon_effector_off = 1, mesecon = 2 },
	_mcl_blast_resistance = 1,
	_mcl_hardness = 1,
	on_place = core.rotate_node,
	mesecons = {
		effector = {
			rules = mesecon.rules.alldirs,
			action_change = function(pos, _node, rule, newstate)
				core.log("verbose", ("[redstone_panels] %s input %s from %s"):format(
					core.pos_to_string(pos), newstate, core.pos_to_string(rule)))
			end,
		},
	},
})

-- Lets scripts/smoke.sh start a server, load the mod, and exit cleanly.
if core.settings:get_bool("redstone_panels.smoke_test", false) then
	core.after(1, function()
		core.log("action", "[redstone_panels] smoke test OK")
		core.request_shutdown("smoke test done", false, 0)
	end)
end
