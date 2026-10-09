-- Runs a compiled network (see sim/compile.lua). Pure Lua.
--
-- Same interface as sim/ref.lua, so a compiled panel can stand in for a
-- reference one: eval(state, inputs), step(state, inputs), press(state, cell).
-- Presses are held until the next step; one press per cell per tick.

-- In-game, init.lua loads sim/ files with loadfile and passes its own loader.
local require = type(...) == "function" and ... or require

local grid = require("sim.grid")

local runtime = {}

local PORTS = grid.PORTS

function runtime.new(net)
	local state = { runtime = runtime, net = net, reg = {}, vals = {}, pressed = {} }
	for i, n in ipairs(net.nodes) do
		if n.op == "reg" then state.reg[i] = n.init end
	end
	return state
end

-- Evaluate the instant part of the tick. Returns the 32 edge outputs.
function runtime.eval(state, inputs)
	local net, vals, reg, pressed = state.net, state.vals, state.reg, state.pressed
	for i, n in ipairs(net.nodes) do
		local op, v = n.op, nil
		if op == "or" then
			v = false
			for _, a in ipairs(n.args) do
				if vals[a] then
					v = true
					break
				end
			end
		elseif op == "and" then
			v = true
			for _, a in ipairs(n.args) do
				if not vals[a] then
					v = false
					break
				end
			end
		elseif op == "not" then
			v = not vals[n.args[1]]
		elseif op == "xor" then
			v = vals[n.args[1]] ~= vals[n.args[2]]
		elseif op == "reg" then
			v = reg[i]
		elseif op == "in" then
			v = inputs[n.pin] == true
		elseif op == "press" then
			v = pressed.all == true or pressed[n.cell] == true
		else
			v = n.v
		end
		vals[i] = v
	end
	local out = {}
	for p = 0, PORTS - 1 do out[p] = vals[net.outs[p]] end
	return out
end

-- Finish the tick from the last eval: registers take their next values and
-- presses are released.
function runtime.commit(state)
	local vals, reg = state.vals, state.reg
	for i, n in ipairs(state.net.nodes) do
		if n.op == "reg" then reg[i] = vals[n.d] end
	end
	state.pressed = {}
end

-- Advance one tick. Returns the edge outputs as seen at the start of the tick.
function runtime.step(state, inputs)
	local out = runtime.eval(state, inputs)
	runtime.commit(state)
	return out
end

-- Press face cell `cell` (padded index), or every cell if cell is nil.
function runtime.press(state, cell)
	state.pressed[cell == nil and "all" or cell] = true
end

-- All lamp states (own, then nested), from the last eval.
function runtime.lamp_list(state)
	local o = {}
	for j, l in ipairs(state.net.lamps) do o[j] = state.vals[l] == true end
	return o
end

-- Live state of the panel's own parts (net.probe_cells order), from the last eval.
function runtime.probes(state)
	local o = {}
	for j, v in ipairs(state.net.probes) do o[j] = state.vals[v] == true end
	return o
end

-- A compiled library entry, ready to run.
function runtime.from_library(library, id)
	local compile = require("sim.compile")
	return runtime.new(compile.from_library(library, id))
end

return runtime
