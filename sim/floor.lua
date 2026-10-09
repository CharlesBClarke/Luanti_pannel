-- Panels placed side by side (a floor or wall), settled together each tick.
-- Pure Lua: world.lua supplies the panels and the outside world.
--
-- A panel record is { state = runtime state, neighbors = {[side] = panel},
-- out = {}, inputs = {} }. Links must be symmetric: P.neighbors[d] == Q
-- exactly when Q.neighbors[opposite(d)] == P, edge cell k to edge cell k.
--
-- The instant part of a tick is the least fixpoint, starting from all
-- outputs off (as in sim/ref.lua). Instant paths between panels are ORs, so
-- a loop of them through several panels can hold itself on only if the
-- settle starts from last tick's outputs. A group of linked panels with no
-- such loop has exactly one fixpoint, so it can start from last tick's
-- outputs, and its still panels hit runtime's eval cache and cost almost
-- nothing. A group with a loop starts from all off, every tick.

-- In-game, init.lua loads sim/ files with loadfile and passes its own loader.
local require = type(...) == "function" and ... or require

local grid = require("sim.grid")
local runtime = require("sim.runtime")

local floor = {}

local BITS, PORTS = grid.BITS, grid.PORTS

-- readers[p]: the output ports that input pin p reaches instantly (not
-- through a register). Cached on the net.
function floor.readers(net)
	if net.readers then return net.readers end
	local readers = {}
	for p = 0, PORTS - 1 do readers[p] = {} end
	for q = 0, PORTS - 1 do
		local seen, stack = {}, { net.outs[q] }
		while #stack > 0 do
			local i = table.remove(stack)
			if not seen[i] then
				seen[i] = true
				local n = net.nodes[i]
				if n.op == "in" then
					local r = readers[n.pin]
					r[#r + 1] = q
				elseif n.args then
					for _, a in ipairs(n.args) do stack[#stack + 1] = a end
				end
			end
		end
	end
	net.readers = readers
	return readers
end

-- Find the linked groups: P.group is the list of panels linked to P
-- (itself included), P.looped whether that group has a loop. Call again
-- whenever links change.
function floor.relink(list)
	local group = {}
	for _, P in ipairs(list) do
		if not group[P] then
			local members, stack = {}, { P }
			group[P] = members
			while #stack > 0 do
				local Q = table.remove(stack)
				members[#members + 1] = Q
				for d = 0, 3 do
					local R = Q.neighbors[d]
					if R and not group[R] then
						group[R] = members
						stack[#stack + 1] = R
					end
				end
			end
			local looped = floor.has_loop(members)
			for _, Q in ipairs(members) do Q.looped, Q.group = looped, members end
		end
	end
end

-- Is there an instant path from some panel's output back to itself
-- through its neighbours? Depth-first over (panel, output port).
function floor.has_loop(members)
	local color = {} -- [P][q]: nil unvisited, 1 on the stack, 2 done
	for _, P in ipairs(members) do color[P] = {} end
	-- Output ports of neighbours that output q of P reaches instantly.
	local function next_ports(P, q)
		local d, k = math.floor(q / BITS), q % BITS
		local Q = P.neighbors[d]
		if not Q then return nil, {} end
		return Q, floor.readers(Q.state.net)[grid.opposite(d) * BITS + k]
	end
	for _, P in ipairs(members) do
		for q = 0, PORTS - 1 do
			if not color[P][q] then
				color[P][q] = 1
				local Q, ports = next_ports(P, q)
				local stack = { { P, q, Q, ports, 1 } }
				while #stack > 0 do
					local top = stack[#stack]
					local r = top[4][top[5]]
					if r == nil then
						color[top[1]][top[2]] = 2
						stack[#stack] = nil
					else
						top[5] = top[5] + 1
						local c = color[top[3]][r]
						if c == 1 then return true end
						if not c then
							color[top[3]][r] = 1
							local R, rp = next_ports(top[3], r)
							stack[#stack + 1] = { top[3], r, R, rp, 1 }
						end
					end
				end
			end
		end
	end
	return false
end

-- A panel's 32 input bits: a linked side reads the neighbour's facing
-- outputs; any other side asks external(P, side) and sets all its bits alike.
-- Fills `inputs` if given (no garbage), else a new table.
function floor.gather(P, external, inputs)
	inputs = inputs or {}
	for d = 0, 3 do
		local Q = P.neighbors[d]
		if Q then
			local base = grid.opposite(d) * BITS
			for k = 0, BITS - 1 do inputs[d * BITS + k] = Q.out[base + k] == true end
		else
			local v = external(P, d) and true or false
			for k = 0, BITS - 1 do inputs[d * BITS + k] = v end
		end
	end
	return inputs
end

-- Settle the instant part of the tick for every panel in `list`. Sets each
-- panel's inputs and out (its own tables, filled in place); the runtime
-- states keep the last eval, ready to commit. Gives up after max_evals
-- evaluations and returns false.
local queue, queued = {}, {} -- reused every tick
function floor.settle(list, external, max_evals)
	for i = #queue, 1, -1 do queue[i] = nil end
	for P in pairs(queued) do queued[P] = nil end
	for i, P in ipairs(list) do
		P.out, P.inputs = P.out or {}, P.inputs or {}
		if P.looped then
			for p = 0, PORTS - 1 do P.out[p] = nil end
		end
		queue[i] = P
		queued[P] = true
	end
	local head = 1
	while head <= #queue do
		if head > max_evals then return false end
		local P = queue[head]
		head = head + 1
		queued[P] = nil
		floor.gather(P, external, P.inputs)
		local out = runtime.eval(P.state, P.inputs)
		for d = 0, 3 do
			local Q = P.neighbors[d]
			if Q and not queued[Q] then
				for k = 0, BITS - 1 do
					local p = d * BITS + k
					if (out[p] == true) ~= (P.out[p] == true) then
						queue[#queue + 1] = Q
						queued[Q] = true
						break
					end
				end
			end
		end
		local own = P.out
		for p = 0, PORTS - 1 do own[p] = out[p] end
	end
	return true
end

return floor
