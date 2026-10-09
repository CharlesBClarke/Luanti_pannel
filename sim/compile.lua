-- Compiler: turns a panel into a small synchronous network of gates and
-- registers that behaves exactly like sim/ref.lua, tick for tick. Pure Lua.
--
-- A network ("net") is { nodes = {...}, outs = {[0..31] = node},
-- lamps = {node...}, lamp_cells = {cell...} }. Nodes are tables with an op:
--   const {v}   in {pin}   press {cell}   reg {init, d}
--   or {args}   and {args}   not {args = {a}}   xor {args = {a, b}}
-- A reg holds one tick of state: its value this tick is what d was last tick.
-- Instant logic between parts is only ever OR; and/not/xor appear inside
-- torches, bulbs and levers. So every instant loop is a loop of ORs, and
-- the reference's fixpoint (starting from all off) is plain reachability.
--
-- Lamps are listed own lamps first (S.lamps order), then each nested
-- panel's lamps (S.panels order); lamp_cells gives the cell each one lights.
-- probes[j] is the live state of the panel's own part at probe_cells[j]
-- (S.probe_cells order), for the face display. Probes are kept alive like
-- lamps, but only one level deep: inlining a nested panel drops its probes.

-- In-game, init.lua loads sim/ files with loadfile and passes its own loader.
local require = type(...) == "function" and ... or require

local grid = require("sim.grid")
local static = require("sim.static")
local runtime = require("sim.runtime")

local compile = {}

local BITS, PORTS = grid.BITS, grid.PORTS

local function new_builder()
	local B = { nodes = {} }
	function B.add(n)
		local i = #B.nodes + 1
		B.nodes[i] = n
		return i
	end
	B.FALSE = B.add({ op = "const", v = false })
	B.TRUE = B.add({ op = "const", v = true })
	return B
end

-- Copy compiled network K into B, `speed` steps per tick. kin[p] is the
-- parent node feeding K's input pin p. Returns K's outputs and lamps as
-- seen on the first step: a fast panel shows its outputs once per tick.
local function inline(B, K, kin, press_node, speed)
	local regs = {}
	for i, n in ipairs(K.nodes) do
		if n.op == "reg" then regs[i] = B.add({ op = "reg", init = n.init }) end
	end
	local cur, first = regs, nil
	for step = 1, speed do
		local m = {}
		local pressed = step == 1 and press_node or B.FALSE
		for i, n in ipairs(K.nodes) do
			local op = n.op
			if op == "reg" then
				m[i] = cur[i]
			elseif op == "in" then
				m[i] = kin[n.pin]
			elseif op == "press" then
				m[i] = pressed
			elseif op == "const" then
				m[i] = n.v and B.TRUE or B.FALSE
			else
				local args = {}
				for j, a in ipairs(n.args) do args[j] = m[a] end
				m[i] = B.add({ op = op, args = args })
			end
		end
		if step == 1 then
			first = { outs = {}, lamps = {} }
			for p = 0, PORTS - 1 do first.outs[p] = m[K.outs[p]] end
			for j, l in ipairs(K.lamps) do first.lamps[j] = m[l] end
		end
		local nxt = {}
		for i in pairs(regs) do nxt[i] = m[K.nodes[i].d] end
		cur = nxt
	end
	for i, r in pairs(regs) do B.nodes[r].d = cur[i] end
	return first
end

-- Step 1 and 2: wires, parts and inlined sub-panels as a raw network.
-- Instant loops are still present. kid_net(id) returns a compiled network.
local function build(S, kid_net)
	local B = new_builder()
	local nodes = B.nodes

	local pin_node, press_node = {}, {}
	local function pin(p)
		if not pin_node[p] then pin_node[p] = B.add({ op = "in", pin = p }) end
		return pin_node[p]
	end
	local function press(c)
		if not press_node[c] then press_node[c] = B.add({ op = "press", cell = c }) end
		return press_node[c]
	end

	-- Placeholders first: nets and nested outputs feed each other instantly.
	local net, torch, switch, kid_out = {}, {}, {}, {}
	for n = 1, S.nets do net[n] = B.add({ op = "or", args = {} }) end
	for _, t in ipairs(S.torches) do torch[t] = B.add({ op = "reg", init = true }) end
	for _, c in ipairs(S.panels) do
		kid_out[c] = {}
		for p = 0, PORTS - 1 do kid_out[c][p] = B.add({ op = "or", args = {} }) end
	end

	-- A lever flips its register on a press. A button is on while any of
	-- the last BUTTON_TICKS steps had a press.
	for _, w in ipairs(S.switches) do
		local p = press(w)
		if S.cells[w].kind == "lever" then
			local r = B.add({ op = "reg", init = false })
			switch[w] = B.add({ op = "xor", args = { r, p } })
			nodes[r].d = switch[w]
		else
			local args, prev = { p }, p
			for _ = 2, grid.BUTTON_TICKS do
				prev = B.add({ op = "reg", init = false, d = prev })
				args[#args + 1] = prev
			end
			switch[w] = B.add({ op = "or", args = args })
		end
	end

	local function side_any(c, side)
		local args = {}
		for k = 0, BITS - 1 do args[#args + 1] = kid_out[c][side * BITS + k] end
		return B.add({ op = "or", args = args })
	end

	local function powered(src, with_nets, except_pin)
		local args = {}
		for _, p in ipairs(src.pins) do
			if p ~= except_pin then args[#args + 1] = pin(p) end
		end
		if with_nets then
			for _, n in ipairs(src.nets) do args[#args + 1] = net[n] end
		end
		for _, t in ipairs(src.torches) do args[#args + 1] = torch[t] end
		for _, w in ipairs(src.switches) do args[#args + 1] = switch[w] end
		for _, ps in ipairs(src.panels) do args[#args + 1] = side_any(ps.cell, ps.side) end
		return args
	end

	for n = 1, S.nets do nodes[net[n]].args = powered(S.net_src[n], false) end
	local lit = {}
	for _, list in ipairs({ S.blocks, S.bulbs, S.lamps }) do
		for _, b in ipairs(list) do
			lit[b] = B.add({ op = "or", args = powered(S.powered_by[b], true) })
		end
	end

	-- A bulb flips when its input is on now but was off last tick.
	local bulb = {}
	for _, b in ipairs(S.bulbs) do
		local state = B.add({ op = "reg", init = false })
		local prev = B.add({ op = "reg", init = false, d = lit[b] })
		local was_off = B.add({ op = "not", args = { prev } })
		local rise = B.add({ op = "and", args = { lit[b], was_off } })
		nodes[state].d = B.add({ op = "xor", args = { state, rise } })
		bulb[b] = state
	end

	for _, t in ipairs(S.torches) do
		local base, on = S.torch_base[t], B.FALSE
		if base and base.kind == "block" then on = lit[base.cell] end
		if base and base.kind == "bulb" then on = bulb[base.cell] end
		nodes[torch[t]].d = B.add({ op = "not", args = { on } })
	end

	local function desc_node(desc, bit)
		if not desc then return B.FALSE end
		if desc.kind == "pin" then return pin(desc.pin) end
		if desc.kind == "net" then return net[desc.net] end
		if desc.kind == "torch" then return torch[desc.cell] end
		if desc.kind == "switch" then return switch[desc.cell] end
		return kid_out[desc.cell][desc.side * BITS + bit]
	end

	local probes = {}
	for j, c in ipairs(S.probe_cells) do
		local kind = S.cells[c].kind
		local v
		if kind == "dust" then
			v = net[S.net_of[c * 2]]
		elseif kind == "quartz" then
			v = B.add({ op = "or", args = { net[S.net_of[c * 2]], net[S.net_of[c * 2 + 1]] } })
		elseif kind == "torch" then
			v = torch[c]
		elseif kind == "block" then
			v = lit[c]
		elseif kind == "bulb" then
			v = bulb[c]
		else
			v = switch[c]
		end
		probes[j] = v
	end

	local lamps, lamp_cells = {}, {}
	for _, l in ipairs(S.lamps) do
		lamps[#lamps + 1] = lit[l]
		lamp_cells[#lamp_cells + 1] = l
	end

	for _, c in ipairs(S.panels) do
		local kin = {}
		for d = 0, 3 do
			for k = 0, BITS - 1 do kin[d * BITS + k] = desc_node(S.panel_side[c][d], k) end
		end
		local K = kid_net(S.cells[c].id)
		local seen = inline(B, K, kin, press(c), S.cells[c].speed or 1)
		for p = 0, PORTS - 1 do nodes[kid_out[c][p]].args = { seen.outs[p] } end
		for _, l in ipairs(seen.lamps) do
			lamps[#lamps + 1] = l
			lamp_cells[#lamp_cells + 1] = c
		end
	end

	local outs = {}
	for p = 0, PORTS - 1 do
		local d, v = S.pin_out[p], B.FALSE
		if d and d.kind == "net" then
			-- No self-echo: an edge output ignores its own input.
			v = B.add({ op = "or", args = powered(S.net_src[d.net], false, p) })
		elseif d and d.kind == "torch" then
			v = torch[d.cell]
		elseif d and d.kind == "switch" then
			v = switch[d.cell]
		elseif d and d.kind == "panel" then
			v = side_any(d.cell, d.side)
		end
		outs[p] = v
	end

	return {
		nodes = nodes, outs = outs, lamps = lamps, lamp_cells = lamp_cells,
		probes = probes, probe_cells = S.probe_cells,
	}
end

local function new_alias()
	local alias = {}
	local function find(i)
		local root = i
		while alias[root] do root = alias[root] end
		while alias[i] do
			alias[i], i = root, alias[i]
		end
		return root
	end
	return alias, find
end

-- Copy the nodes reachable from the outputs, lamps and probes, following aliases,
-- in an order where every node comes after its args (regs are leaves).
-- Drops everything else.
local function rebuild(net, find)
	local old, nodes, map = net.nodes, {}, {}
	local regs = {}
	local function emit(i)
		local n = old[i]
		local copy = { op = n.op, v = n.v, pin = n.pin, cell = n.cell, init = n.init, d = n.d }
		if n.args then
			copy.args = {}
			for j, a in ipairs(n.args) do
				local m = map[find(a)]
				assert(m, "instant loop left in network")
				copy.args[j] = m
			end
		end
		nodes[#nodes + 1] = copy
		map[i] = #nodes
		if n.op == "reg" then regs[#regs + 1] = #nodes end
	end
	local expanded = {}
	local function visit(root)
		root = find(root)
		local stack = { root }
		while #stack > 0 do
			local i = stack[#stack]
			local args = old[i].args
			if map[i] then
				stack[#stack] = nil
			elseif args and not expanded[i] then
				expanded[i] = true
				for _, a in ipairs(args) do
					a = find(a)
					if not map[a] then stack[#stack + 1] = a end
				end
			else
				stack[#stack] = nil
				emit(i)
			end
		end
		return map[root]
	end

	local outs, lamps, probes = {}, {}, {}
	for p = 0, PORTS - 1 do outs[p] = visit(net.outs[p]) end
	for j, l in ipairs(net.lamps) do lamps[j] = visit(l) end
	for j, v in ipairs(net.probes) do probes[j] = visit(v) end
	local k = 1
	while k <= #regs do
		local r = nodes[regs[k]]
		r.d = visit(r.d)
		k = k + 1
	end
	return {
		nodes = nodes, outs = outs, lamps = lamps, lamp_cells = net.lamp_cells,
		probes = probes, probe_cells = net.probe_cells,
	}
end

-- Step 3: each instant loop (a strongly connected group of ORs) becomes one
-- OR of everything feeding the loop from outside. Iterative Tarjan.
local function collapse_loops(net)
	local nodes = net.nodes
	local alias, find = new_alias()
	local index, low, on_stack, stack, count = {}, {}, {}, {}, 0
	local function open(v)
		count = count + 1
		index[v], low[v] = count, count
		stack[#stack + 1] = v
		on_stack[v] = true
	end
	for root = 1, #nodes do
		if not index[root] then
			open(root)
			local work = { { root, 1 } }
			while #work > 0 do
				local top = work[#work]
				local v, k = top[1], top[2]
				local args = nodes[v].args
				if args and k <= #args then
					top[2] = k + 1
					local w = args[k]
					if not index[w] then
						open(w)
						work[#work + 1] = { w, 1 }
					elseif on_stack[w] and index[w] < low[v] then
						low[v] = index[w]
					end
				else
					work[#work] = nil
					if #work > 0 then
						local u = work[#work][1]
						if low[v] < low[u] then low[u] = low[v] end
					end
					if low[v] == index[v] then
						local members, inside = {}, {}
						repeat
							local w = stack[#stack]
							stack[#stack] = nil
							on_stack[w] = false
							members[#members + 1] = w
							inside[w] = true
						until w == v
						local self_loop = false
						for _, a in ipairs(nodes[v].args or {}) do
							if a == v then self_loop = true end
						end
						if #members > 1 or self_loop then
							local outside, seen = {}, {}
							for _, m in ipairs(members) do
								assert(nodes[m].op == "or", "instant loop through a non-OR node")
								for _, a in ipairs(nodes[m].args) do
									if not inside[a] and not seen[a] then
										seen[a] = true
										outside[#outside + 1] = a
									end
								end
							end
							nodes[v].args = outside
							for _, m in ipairs(members) do
								if m ~= v then alias[m] = v end
							end
						end
					end
				end
			end
		end
	end
	return rebuild(net, find)
end

-- Step 5a: fold constants and trivial gates. Returns the new net and
-- whether anything changed.
local function fold(net)
	local nodes = net.nodes
	local alias, find = new_alias()
	local changed = false
	local function const(n, v)
		n.op, n.v, n.args, n.d = "const", v, nil, nil
		changed = true
	end
	local function value(i)
		local n = nodes[find(i)]
		if n.op == "const" then return n.v end
		return nil
	end
	repeat
		local again = false
		for i, n in ipairs(nodes) do
			local op = n.op
			if op == "or" or op == "and" then
				local absorb = op == "or"
				local args, seen, done = {}, {}, false
				for _, a in ipairs(n.args) do
					a = find(a)
					local c = value(a)
					if c == absorb then
						const(n, absorb)
						done = true
						break
					elseif c == nil and not seen[a] then
						seen[a] = true
						args[#args + 1] = a
					end
				end
				if not done then
					if #args == 0 then
						const(n, not absorb)
					elseif #args == 1 then
						alias[i] = args[1]
						changed = true
					else
						if #args ~= #n.args then changed = true end
						n.args = args
					end
				end
			elseif op == "not" then
				local a = find(n.args[1])
				local c = value(a)
				if c ~= nil then
					const(n, not c)
				elseif nodes[a].op == "not" then
					alias[i] = find(nodes[a].args[1])
					changed = true
				else
					n.args[1] = a
				end
			elseif op == "xor" then
				local a, b = find(n.args[1]), find(n.args[2])
				local ca, cb = value(a), value(b)
				if ca ~= nil and cb ~= nil then
					const(n, ca ~= cb)
				elseif a == b then
					const(n, false)
				elseif ca ~= nil or cb ~= nil then
					local c, other = ca, b
					if ca == nil then c, other = cb, a end
					if c then
						n.op, n.args = "not", { other }
					else
						alias[i] = other
					end
					changed = true
				else
					n.args[1], n.args[2] = a, b
				end
			elseif op == "reg" then
				local d = find(n.d)
				n.d = d
				local c = value(d)
				if d == i or c == n.init then
					const(n, n.init)
					again = true
				end
			end
		end
	until not again
	if not changed then return net, false end
	return rebuild(net, find), true
end

-- Step 5b: merge nodes that always carry the same value, by refining a
-- partition (kind, then kind of inputs, ...) until it stops splitting.
-- Registers must also match in power-on value, so clocks merge safely.
local function merge(net)
	local nodes = net.nodes
	local class, ids, count = {}, {}, 0
	for i, n in ipairs(nodes) do
		local key = n.op
		if n.op == "const" then key = "c" .. tostring(n.v) end
		if n.op == "in" then key = "i" .. n.pin end
		if n.op == "press" then key = "p" .. n.cell end
		if n.op == "reg" then key = "r" .. tostring(n.init) end
		if not ids[key] then
			count = count + 1
			ids[key] = count
		end
		class[i] = ids[key]
	end
	while true do
		local new, sigs, new_count = {}, {}, 0
		for i, n in ipairs(nodes) do
			local sig = tostring(class[i])
			if n.op == "reg" then
				sig = sig .. "|" .. class[n.d]
			elseif n.args then
				local cs, seen = {}, {}
				for _, a in ipairs(n.args) do
					local c = class[a]
					-- or/and ignore repeats; xor does not.
					if n.op == "xor" or not seen[c] then
						seen[c] = true
						cs[#cs + 1] = c
					end
				end
				table.sort(cs)
				sig = sig .. "|" .. table.concat(cs, ",")
			end
			if not sigs[sig] then
				new_count = new_count + 1
				sigs[sig] = new_count
			end
			new[i] = sigs[sig]
		end
		class = new
		if new_count == count then break end
		count = new_count
	end
	local alias, find = new_alias()
	local rep = {}
	for i = 1, #nodes do
		local c = class[i]
		if rep[c] then alias[i] = rep[c] else rep[c] = i end
	end
	return rebuild(net, find), count < #nodes
end

-- Step 4: run from the starting state and keep the snapshot as power-on state.
local function warm_up(net)
	local state = runtime.new(net)
	local zero = {}
	for _ = 1, grid.WARMUP_TICKS do runtime.step(state, zero) end
	for i, n in ipairs(net.nodes) do
		if n.op == "reg" then n.init = state.reg[i] end
	end
end

-- Compile one panel. kid_net(id) returns the compiled network of a nested panel.
function compile.panel(cells, kid_net)
	local net = collapse_loops(build(static.analyze(cells), kid_net))
	warm_up(net)
	repeat
		local folded, merged
		net, folded = fold(net)
		net, merged = merge(net)
	until not folded and not merged
	return net
end

-- Compile library entry `id` (and the panels it nests), caching results.
function compile.from_library(library, id)
	library._compiled = library._compiled or {}
	local net = library._compiled[id]
	if not net then
		net = compile.panel(library[id].cells, function(kid) return compile.from_library(library, kid) end)
		library._compiled[id] = net
	end
	return net
end

-- Counts for reports and the benchmark.
function compile.stats(net)
	local s = { nodes = #net.nodes, gates = 0, regs = 0 }
	for _, n in ipairs(net.nodes) do
		if n.op == "reg" then
			s.regs = s.regs + 1
		elseif n.args then
			s.gates = s.gates + 1
		end
	end
	return s
end

return compile
