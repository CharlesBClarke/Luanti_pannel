-- Plain step-by-step simulator. Slow but simple: it is the reference that
-- compiled panels are checked against. Pure Lua.
--
-- Inputs and outputs are tables indexed by port 0..31 holding booleans.
-- One step() is one tick: evaluate everything instant, then advance torches
-- (1 tick), bulbs, and nested panels (speed steps each).

local grid = require("sim.grid")
local static = require("sim.static")

local ref = {}

local BITS, PORTS = grid.BITS, grid.PORTS
local WARMUP_TICKS = 80

local function any_side(out, side)
	for k = 0, BITS - 1 do
		if out[side * BITS + k] then return true end
	end
	return false
end

local function powered(state, src, inputs, net_lit, panel_out, except_pin)
	for _, p in ipairs(src.pins) do
		if p ~= except_pin and inputs[p] then return true end
	end
	if net_lit then
		for _, n in ipairs(src.nets) do
			if net_lit[n] then return true end
		end
	end
	for _, t in ipairs(src.torches) do
		if state.torch[t] then return true end
	end
	for _, ps in ipairs(src.panels) do
		if any_side(panel_out[ps.cell], ps.side) then return true end
	end
	return false
end

-- Value of one bit seen through a desc (all 8 bits are equal except for panels).
local function desc_bit(state, desc, bit, inputs, net_lit, panel_out)
	if not desc then return false end
	if desc.kind == "pin" then return inputs[desc.pin] == true end
	if desc.kind == "net" then return net_lit[desc.net] end
	if desc.kind == "torch" then return state.torch[desc.cell] end
	return panel_out[desc.cell][desc.side * BITS + bit] == true
end

-- library: list of { cells = {...} } indexed by panel id (0-based ids allowed).
-- Builds a fresh reference panel for library entry `id`, including its
-- nested panels, and runs the power-on warmup.
function ref.from_library(library, id)
	library._static = library._static or {}
	local S = library._static[id]
	if not S then
		S = static.analyze(library[id].cells)
		library._static[id] = S
	end
	local state = ref.new(S, function(kid_id) return ref.from_library(library, kid_id) end)
	local zero = {}
	for _ = 1, WARMUP_TICKS do
		ref.step(state, zero)
	end
	return state
end

-- S: result of static.analyze. make_kid(id): builds a nested panel's state.
function ref.new(S, make_kid)
	local state = { S = S, torch = {}, bulb = {}, bulb_prev = {}, kids = {} }
	for _, t in ipairs(S.torches) do state.torch[t] = true end
	for _, b in ipairs(S.bulbs) do
		state.bulb[b] = false
		state.bulb_prev[b] = false
	end
	for _, c in ipairs(S.panels) do state.kids[c] = make_kid(S.cells[c].id) end
	return state
end

-- Evaluate the instant part of the tick. Returns the 32 edge outputs.
function ref.eval(state, inputs)
	local S = state.S
	local panel_out, panel_in, net_lit = {}, {}, nil
	for _, c in ipairs(S.panels) do panel_out[c] = {} end

	-- Nets and nested panels can feed each other instantly; iterate to a fixpoint.
	for _ = 1, 500 do
		net_lit = {}
		for n = 1, S.nets do
			net_lit[n] = powered(state, S.net_src[n], inputs, nil, panel_out)
		end
		local changed = false
		for _, c in ipairs(S.panels) do
			local b = {}
			for d = 0, 3 do
				for k = 0, BITS - 1 do
					b[d * BITS + k] = desc_bit(state, S.panel_side[c][d], k, inputs, net_lit, panel_out)
				end
			end
			panel_in[c] = b
			local o = ref.eval_any(state.kids[c], b)
			for p = 0, PORTS - 1 do
				if (o[p] == true) ~= (panel_out[c][p] == true) then
					changed = true
					break
				end
			end
			panel_out[c] = o
		end
		if not changed then break end
	end

	local lit = {}
	for _, list in ipairs({ S.blocks, S.bulbs, S.lamps }) do
		for _, b in ipairs(list) do
			lit[b] = powered(state, S.powered_by[b], inputs, net_lit, panel_out)
		end
	end

	local out = {}
	for p = 0, PORTS - 1 do
		local d = S.pin_out[p]
		local v = false
		if d and d.kind == "net" then
			-- No self-echo: an edge output ignores its own input.
			v = powered(state, S.net_src[d.net], inputs, nil, panel_out, p)
		elseif d and d.kind == "torch" then
			v = state.torch[d.cell]
		elseif d and d.kind == "panel" then
			v = any_side(panel_out[d.cell], d.side)
		end
		out[p] = v
	end

	state.last = { net_lit = net_lit, lit = lit, panel_in = panel_in, panel_out = panel_out }
	return out
end

-- Advance one tick. Returns the edge outputs as seen at the start of the tick.
function ref.step(state, inputs)
	local out = ref.eval(state, inputs)
	local S, last = state.S, state.last

	local torch = {}
	for _, t in ipairs(S.torches) do
		local base, on = S.torch_base[t], false
		if base and base.kind == "block" then on = last.lit[base.cell] end
		if base and base.kind == "bulb" then on = state.bulb[base.cell] end
		torch[t] = not on
	end

	for _, b in ipairs(S.bulbs) do
		local input = last.lit[b]
		if input and not state.bulb_prev[b] then
			state.bulb[b] = not state.bulb[b]
		end
		state.bulb_prev[b] = input
	end

	for _, c in ipairs(S.panels) do
		for _ = 1, S.cells[c].speed or 1 do
			ref.step_any(state.kids[c], last.panel_in[c])
		end
	end

	state.torch = torch
	return out
end

-- Lamp states in S.lamps order, from the last eval.
function ref.lamps(state)
	local o = {}
	for i, b in ipairs(state.S.lamps) do
		o[i] = state.last and state.last.lit[b] or false
	end
	return o
end

-- Nested panels may be reference states or compiled ones (once the compiler
-- exists); dispatch on a `runtime` field so both can be mixed.
function ref.eval_any(state, inputs)
	return (state.runtime or ref).eval(state, inputs)
end

function ref.step_any(state, inputs)
	return (state.runtime or ref).step(state, inputs)
end

return ref
