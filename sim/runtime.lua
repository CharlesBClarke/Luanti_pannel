-- Runs a compiled network (see sim/compile.lua). Pure Lua.
--
-- Same interface as sim/ref.lua, so a compiled panel can stand in for a
-- reference one: eval(state, inputs), step(state, inputs), press(state, cell).
-- Presses are held until the next step; one press per cell per tick.
--
-- Still panels are nearly free: eval is a pure function of the inputs,
-- registers and presses, so when none of them changed since the last eval
-- it returns the last result without running the network. state.ran says
-- whether the last eval really ran; state.runs counts the ones that did.

-- In-game, init.lua loads sim/ files with loadfile and passes its own loader.
local require = type(...) == "function" and ... or require

local grid = require("sim.grid")

local runtime = {}

local PORTS = grid.PORTS

function runtime.new(net)
	local state = {
		runtime = runtime, net = net, reg = {}, vals = {}, pressed = {},
		last_in = {}, last_out = nil, ran = false, committed = false, runs = 0,
	}
	for i, n in ipairs(net.nodes) do
		if n.op == "reg" then state.reg[i] = n.init end
	end
	return state
end

-- Evaluate the instant part of the tick. Returns the 32 edge outputs.
function runtime.eval(state, inputs)
	local last_in = state.last_in
	if state.last_out then
		local same = true
		for p = 0, PORTS - 1 do
			if (inputs[p] == true) ~= last_in[p] then
				same = false
				break
			end
		end
		if same then
			state.ran = false
			return state.last_out
		end
	end
	for p = 0, PORTS - 1 do last_in[p] = inputs[p] == true end
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
	state.last_out, state.ran, state.committed = out, true, false
	state.runs = state.runs + 1
	return out
end

-- Finish the tick from the last eval: registers take their next values and
-- presses are released. Committing the same values twice changes nothing,
-- so that is skipped.
function runtime.commit(state)
	if state.committed then return end
	local vals, reg, changed = state.vals, state.reg, next(state.pressed) ~= nil
	for i, n in ipairs(state.net.nodes) do
		if n.op == "reg" then
			local v = vals[n.d]
			if reg[i] ~= v then
				reg[i] = v
				changed = true
			end
		end
	end
	state.committed = true
	if changed then
		state.pressed = {}
		state.last_out = nil -- the next eval must run
	end
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
	state.last_out, state.committed = nil, false
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
