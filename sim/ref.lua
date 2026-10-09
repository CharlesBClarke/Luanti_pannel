-- Plain step-by-step simulator. Slow but simple: it is the reference that
-- compiled panels are checked against. Pure Lua.
--
-- Inputs and outputs are tables indexed by port 0..31 holding booleans.
-- One step() is one tick: evaluate everything instant, then advance torches
-- (1 tick), bulbs, buttons, and nested panels (speed steps each).
--
-- Face presses go through ref.press() before the step they apply to.

-- In-game, init.lua loads sim/ files with loadfile and passes its own loader.
local require = type(...) == "function" and ... or require

local grid = require("sim.grid")
local static = require("sim.static")

local ref = {}

local BITS, PORTS = grid.BITS, grid.PORTS

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
	for _, w in ipairs(src.switches) do
		if state.switch[w] then return true end
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
	if desc.kind == "switch" then return state.switch[desc.cell] end
	return panel_out[desc.cell][desc.side * BITS + bit] == true
end

-- library: list of { cells = {...} } indexed by panel id (0-based ids allowed).
-- Builds a fresh reference panel for library entry `id`, including its
-- nested panels, and runs the power-on warmup. make_kid(library, id)
-- optionally builds nested panels some other way (e.g. compiled).
function ref.from_library(library, id, make_kid)
	library._static = library._static or {}
	local S = library._static[id]
	if not S then
		S = static.analyze(library[id].cells)
		library._static[id] = S
	end
	local state = ref.new(S, function(kid_id)
		if make_kid then return make_kid(library, kid_id) end
		return ref.from_library(library, kid_id)
	end)
	local zero = {}
	for _ = 1, grid.WARMUP_TICKS do
		ref.step(state, zero)
	end
	return state
end

-- S: result of static.analyze. make_kid(id): builds a nested panel's state.
function ref.new(S, make_kid)
	local state = { S = S, torch = {}, bulb = {}, bulb_prev = {}, switch = {}, button_left = {}, kids = {} }
	for _, t in ipairs(S.torches) do state.torch[t] = true end
	for _, w in ipairs(S.switches) do
		state.switch[w] = false
		state.button_left[w] = 0
	end
	for _, b in ipairs(S.bulbs) do
		state.bulb[b] = false
		state.bulb_prev[b] = false
	end
	for _, c in ipairs(S.panels) do state.kids[c] = make_kid(S.cells[c].id) end
	return state
end

-- One evaluation of the instant part of the tick, into state.last.
local function eval_once(state, inputs)
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
		-- panel_out is in the parent's frame, panel_in in the nested panel's
		-- own: its port q faces the parent at turn_port(q, turn).
		for _, c in ipairs(S.panels) do
			local turn = S.cells[c].turn
			local b = {}
			for q = 0, PORTS - 1 do
				local p = grid.turn_port(q, turn)
				b[q] = desc_bit(state, S.panel_side[c][math.floor(p / BITS)], p % BITS, inputs, net_lit, panel_out)
			end
			panel_in[c] = b
			local own = ref.eval_any(state.kids[c], b)
			local o = {}
			for q = 0, PORTS - 1 do o[grid.turn_port(q, turn)] = own[q] end
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

	-- Nested lamps as shown this tick (a fast panel's later steps don't show).
	local kid_lamps = {}
	for _, c in ipairs(S.panels) do kid_lamps[c] = ref.lamp_list_any(state.kids[c]) end

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
		elseif d and d.kind == "switch" then
			v = state.switch[d.cell]
		elseif d and d.kind == "panel" then
			v = any_side(panel_out[d.cell], d.side)
		end
		out[p] = v
	end

	-- Live state of own parts, as compiled probes see it (S.probe_cells order).
	local probes = {}
	for j, c in ipairs(S.probe_cells) do
		local kind = S.cells[c].kind
		local v
		if kind == "dust" or kind == "quartz" then
			v = net_lit[S.net_of[c * 2]]
		elseif kind == "torch" then
			v = state.torch[c]
		elseif kind == "block" then
			v = lit[c]
		elseif kind == "bulb" then
			v = state.bulb[c]
		else
			v = state.switch[c]
		end
		probes[j] = v == true
	end

	state.last = {
		net_lit = net_lit, lit = lit, panel_in = panel_in, panel_out = panel_out, kid_lamps = kid_lamps,
		probes = probes,
	}
	return out
end

-- Edge outputs that could carry their own input back: only through a
-- nested panel, so only where the wire behind the edge cell touches one.
local function echo_pins(S)
	if not S.echo_pins then
		local pins = {}
		for p = 0, PORTS - 1 do
			local d = S.pin_out[p]
			if d and (d.kind == "panel" or d.kind == "net" and #S.net_src[d.net].panels > 0) then
				pins[#pins + 1] = p
			end
		end
		S.echo_pins = pins
	end
	return S.echo_pins
end

local function copy(t)
	local o = {}
	for k, v in pairs(t) do o[k] = v end
	return o
end

-- Evaluate the instant part of the tick. Returns the 32 edge outputs.
-- No self-echo: edge output p is what it would be with input p off (a
-- signal can return to its own edge cell through a nested panel). Those
-- evals go first: the real one must be last, for step and the kids.
-- Results are remembered per input until the state changes (step, press),
-- since a parent evaluates its kids many times over with the same inputs.
function ref.eval(state, inputs)
	local key = {}
	for p = 0, PORTS - 1 do key[p + 1] = inputs[p] and "1" or "0" end
	key = table.concat(key)
	state.memo = state.memo or {}
	local m = state.memo[key]
	if m then
		state.last = m.last
		return copy(m.out)
	end
	local echo_free = {}
	for _, p in ipairs(echo_pins(state.S)) do
		if inputs[p] then
			local masked = {}
			for q = 0, PORTS - 1 do masked[q] = q ~= p and inputs[q] end
			echo_free[p] = eval_once(state, masked)[p]
		end
	end
	local out = eval_once(state, inputs)
	for p, v in pairs(echo_free) do out[p] = v end
	state.memo[key] = { out = copy(out), last = state.last }
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

	-- A button stays on for BUTTON_TICKS steps after its press.
	for _, w in ipairs(S.switches) do
		if S.cells[w].kind == "button" and state.button_left[w] > 0 then
			state.button_left[w] = state.button_left[w] - 1
			state.switch[w] = state.button_left[w] > 0
		end
	end

	for _, c in ipairs(S.panels) do
		for _ = 1, S.cells[c].speed or 1 do
			ref.step_any(state.kids[c], last.panel_in[c])
		end
	end

	state.torch = torch
	state.memo = nil
	return out
end

-- Press face cell `cell` (padded index), or every cell if cell is nil.
-- A lever flips; a button turns on for BUTTON_TICKS steps, starting with
-- the next step. Pressing a nested panel's cell presses everything in it.
function ref.press(state, cell)
	local S = state.S
	state.memo = nil
	for _, w in ipairs(S.switches) do
		if cell == nil or cell == w then
			if S.cells[w].kind == "lever" then
				state.switch[w] = not state.switch[w]
			else
				state.switch[w] = true
				state.button_left[w] = grid.BUTTON_TICKS
			end
		end
	end
	for _, c in ipairs(S.panels) do
		if cell == nil or cell == c then ref.press_any(state.kids[c], nil) end
	end
end

-- Lamp states in S.lamps order, from the last eval.
function ref.lamps(state)
	local o = {}
	for i, b in ipairs(state.S.lamps) do
		o[i] = state.last and state.last.lit[b] or false
	end
	return o
end

-- Own lamps then each nested panel's (S.panels order), from the last eval.
-- Same order as a compiled panel's lamps.
function ref.lamp_list(state)
	local o = ref.lamps(state)
	for _, c in ipairs(state.S.panels) do
		for _, v in ipairs(state.last and state.last.kid_lamps[c] or {}) do o[#o + 1] = v end
	end
	return o
end

-- Live state of own parts (S.probe_cells order), from the last eval.
function ref.probes(state)
	return state.last and state.last.probes or {}
end

-- Nested panels may be reference states or compiled ones (once the compiler
-- exists); dispatch on a `runtime` field so both can be mixed.
function ref.eval_any(state, inputs)
	return (state.runtime or ref).eval(state, inputs)
end

function ref.step_any(state, inputs)
	return (state.runtime or ref).step(state, inputs)
end

function ref.lamp_list_any(state)
	return (state.runtime or ref).lamp_list(state)
end

function ref.press_any(state, cell)
	return (state.runtime or ref).press(state, cell)
end

return ref
