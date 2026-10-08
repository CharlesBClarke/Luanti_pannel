-- Static analysis of one panel's cells: groups dust and quartz into wires
-- ("nets") and records what powers each part. Pure Lua.
--
-- A "source list" says what powers something:
--   { pins = {p...}, nets = {n...}, torches = {cell...}, switches = {cell...},
--     panels = {{cell=, side=}...} }
-- A "desc" says what sits next to a cell in one direction:
--   { kind = "pin", pin = p } | { kind = "net", net = n }
--   { kind = "torch", cell = i } | { kind = "switch", cell = i }
--   { kind = "panel", cell = i, side = d }
-- Buttons and levers ("switches") power all four sides, like a torch with no base.

local grid = require("sim.grid")

local static = {}

local opposite, neighbor = grid.opposite, grid.neighbor
local PAD, SIZE = grid.PAD, grid.SIZE

local function sorted_keys(set)
	local list = {}
	for k in pairs(set) do
		list[#list + 1] = k
	end
	table.sort(list)
	return list
end

function static.analyze(cells)
	local function kind(i)
		if i == nil or not grid.is_inner(i) or not cells[i] then
			return nil
		end
		return cells[i].kind
	end

	-- Dust has one wire node; quartz has two: horizontal (east/west sides)
	-- and vertical (north/south sides), which never mix.
	local function wire_node(i, d)
		local k = kind(i)
		if k == "dust" then return i * 2 end
		if k == "quartz" then return (d == 1 or d == 3) and i * 2 or i * 2 + 1 end
		return nil
	end

	local parent = {}
	local function find(x)
		local root = x
		while parent[root] and parent[root] ~= root do
			root = parent[root]
		end
		parent[x] = root
		return root
	end
	local function union(a, b)
		a, b = find(a), find(b)
		if a ~= b then
			parent[a] = b
		end
	end

	-- Touching dust/quartz sides join.
	for i = 0, PAD * PAD - 1 do
		local k = kind(i)
		if k == "dust" or k == "quartz" then
			for d = 0, 3 do
				local other = wire_node(neighbor(i, d), opposite(d))
				if other then
					union(wire_node(i, d), other)
				end
			end
		end
	end

	-- Quartz links wirelessly along its row (horizontal) and column (vertical).
	for a = 1, SIZE do
		local first_row, first_col
		for b = 1, SIZE do
			local r = grid.index(b, a)
			if kind(r) == "quartz" then
				if first_row then union(first_row * 2, r * 2) else first_row = r end
			end
			local c = grid.index(a, b)
			if kind(c) == "quartz" then
				if first_col then union(first_col * 2 + 1, c * 2 + 1) else first_col = c end
			end
		end
	end

	-- Number the nets 1..n in cell order.
	local net_of, root_net, nets = {}, {}, 0
	for i = 0, PAD * PAD - 1 do
		local k = kind(i)
		local nodes = k == "dust" and { i * 2 } or k == "quartz" and { i * 2, i * 2 + 1 } or {}
		for _, node in ipairs(nodes) do
			local root = find(node)
			if not root_net[root] then
				nets = nets + 1
				root_net[root] = nets
			end
			net_of[node] = root_net[root]
		end
	end

	local function new_src()
		return { pins = {}, nets = {}, torches = {}, switches = {}, panels = {} }
	end

	-- What the neighbour of i in direction d contributes to i.
	-- Torches don't power the block they stand on; blocks, bulbs and lamps power nothing.
	local function feed(src, i, d, with_nets)
		local j = neighbor(i, d)
		if j == nil then return end
		local p = grid.port_at(j)
		if p then
			src.pins[p] = true
			return
		end
		local cell = cells[j]
		if not grid.is_inner(j) or not cell then return end
		local back = opposite(d)
		if cell.kind == "torch" and cell.attach ~= back then
			src.torches[j] = true
		elseif cell.kind == "button" or cell.kind == "lever" then
			src.switches[j] = true
		elseif cell.kind == "panel" then
			src.panels[j * 4 + back] = true
		elseif with_nets and (cell.kind == "dust" or cell.kind == "quartz") then
			src.nets[net_of[wire_node(j, back)]] = true
		end
	end

	local function finish(src)
		local panels = {}
		for _, v in ipairs(sorted_keys(src.panels)) do
			panels[#panels + 1] = { cell = math.floor(v / 4), side = v % 4 }
		end
		return {
			pins = sorted_keys(src.pins),
			nets = sorted_keys(src.nets),
			torches = sorted_keys(src.torches),
			switches = sorted_keys(src.switches),
			panels = panels,
		}
	end

	local net_src = {}
	for n = 1, nets do
		net_src[n] = new_src()
	end

	local S = {
		cells = cells, nets = nets, net_of = net_of, wire_node = wire_node,
		torches = {}, switches = {}, panels = {}, blocks = {}, bulbs = {}, lamps = {},
		powered_by = {}, torch_base = {}, panel_side = {}, pin_out = {}, in_pins = {},
	}

	for i = 0, PAD * PAD - 1 do
		local k = kind(i)
		if k == "torch" then
			table.insert(S.torches, i)
		elseif k == "button" or k == "lever" then
			table.insert(S.switches, i)
		elseif k == "panel" then
			table.insert(S.panels, i)
		elseif k == "block" or k == "bulb" or k == "lamp" then
			table.insert(S[k .. "s"], i)
			local src = new_src()
			for d = 0, 3 do
				feed(src, i, d, true)
			end
			S.powered_by[i] = finish(src)
		elseif k == "dust" or k == "quartz" then
			for d = 0, 3 do
				feed(net_src[net_of[wire_node(i, d)]], i, d, false)
			end
		end
	end

	S.net_src = {}
	for n = 1, nets do
		S.net_src[n] = finish(net_src[n])
	end

	-- What sits next to cell i in direction d, as seen from i.
	local function describe(i, d)
		local j = neighbor(i, d)
		if j == nil then return nil end
		local p = grid.port_at(j)
		if p then return { kind = "pin", pin = p } end
		local cell = cells[j]
		if not grid.is_inner(j) or not cell then return nil end
		local toward = opposite(d)
		if cell.kind == "dust" or cell.kind == "quartz" then
			return { kind = "net", net = net_of[wire_node(j, toward)] }
		elseif cell.kind == "torch" then
			return cell.attach ~= toward and { kind = "torch", cell = j } or nil
		elseif cell.kind == "button" or cell.kind == "lever" then
			return { kind = "switch", cell = j }
		elseif cell.kind == "panel" then
			return { kind = "panel", cell = j, side = toward }
		end
		return nil
	end

	for _, t in ipairs(S.torches) do
		local b = neighbor(t, cells[t].attach)
		local k = kind(b)
		if k == "block" or k == "bulb" then
			S.torch_base[t] = { kind = k, cell = b }
		end
	end

	for _, c in ipairs(S.panels) do
		local sides = {}
		for d = 0, 3 do
			sides[d] = describe(c, d)
		end
		S.panel_side[c] = sides
	end

	-- What drives each edge port from the inside.
	for p = 0, grid.PORTS - 1 do
		local q = grid.port_inner(p)
		local cell = cells[q]
		local side = math.floor(p / SIZE)
		if cell then
			table.insert(S.in_pins, p)
			if cell.kind == "dust" or cell.kind == "quartz" then
				S.pin_out[p] = { kind = "net", net = net_of[wire_node(q, side)] }
			elseif cell.kind == "torch" and cell.attach ~= side then
				S.pin_out[p] = { kind = "torch", cell = q }
			elseif cell.kind == "button" or cell.kind == "lever" then
				S.pin_out[p] = { kind = "switch", cell = q }
			elseif cell.kind == "panel" then
				S.pin_out[p] = { kind = "panel", cell = q, side = side }
			end
		end
	end

	return S
end

return static
