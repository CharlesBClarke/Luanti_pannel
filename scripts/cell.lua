-- Show how a drawn panel wires up: luajit scripts/cell.lua <file>
-- The file holds a drawing (sim/art.lua format), 8 lines; nested panels
-- show as "panel". Prints each wire (dust and quartz nets) with what drives
-- it, what powers each block, bulb and lamp, and where each torch's output
-- goes, so a layout can be checked by eye before testing it.
-- Run from the repo root.

package.path = "./?.lua;" .. package.path

local grid = require("sim.grid")
local static = require("sim.static")
local art = require("sim.art")

local SIDE = { [0] = "N", "E", "S", "W" }

local rows, legend = {}, {}
for line in io.lines(arg[1]) do
	if line:match("%S") then
		rows[#rows + 1] = line
		for ch in line:gmatch("[^%s%.%+qBULbl%^><v]") do legend[ch] = ch end
	end
end
local ids = {}
for ch in pairs(legend) do ids[ch] = 1 end
local cells = art.cells(rows, legend, ids)
local S = static.analyze(cells)

local function at(i)
	local x, y = grid.xy(i)
	return ("%d,%d"):format(x, y)
end
local function pin(p)
	return SIDE[math.floor(p / grid.BITS)] .. (p % grid.BITS + 1)
end
local function list(t, f)
	local o = {}
	for _, v in ipairs(t) do o[#o + 1] = f(v) end
	return table.concat(o, " ")
end
local function sources(src)
	local o = {}
	if #src.pins > 0 then o[#o + 1] = "pins " .. list(src.pins, pin) end
	if src.nets and #src.nets > 0 then o[#o + 1] = "nets " .. list(src.nets, function(n) return "#" .. n end) end
	if #src.torches > 0 then o[#o + 1] = "torches " .. list(src.torches, at) end
	if #src.switches > 0 then o[#o + 1] = "switches " .. list(src.switches, at) end
	if #src.panels > 0 then
		o[#o + 1] = "panels " .. list(src.panels, function(ps) return at(ps.cell) .. SIDE[ps.side] end)
	end
	return #o > 0 and table.concat(o, "; ") or "nothing"
end

-- Net map.
for y = 1, grid.SIZE do
	local line = {}
	for x = 1, grid.SIZE do
		local i = grid.index(x, y)
		local c = cells[i]
		local s = " ."
		if c then
			if c.kind == "dust" or c.kind == "quartz" then
				s = ("%2d"):format(S.net_of[i * 2])
			else
				s = " " .. rows[y]:gsub(" ", ""):sub(x, x)
			end
		end
		line[#line + 1] = s
	end
	print(table.concat(line, " "))
end
print()

for n = 1, S.nets do
	local members = {}
	for i = 0, grid.PAD * grid.PAD - 1 do
		if S.net_of[i * 2] == n then members[#members + 1] = at(i) end
	end
	print(("net #%d [%s] <- %s"):format(n, table.concat(members, " "), sources(S.net_src[n])))
end
for _, kind in ipairs({ "blocks", "bulbs", "lamps" }) do
	for _, b in ipairs(S[kind]) do
		print(("%s %s <- %s"):format(kind:sub(1, -2), at(b), sources(S.powered_by[b])))
	end
end

-- What a torch drives: its three free sides.
for _, t in ipairs(S.torches) do
	local base = S.torch_base[t]
	local outs = {}
	for d = 0, 3 do
		if d ~= cells[t].attach then
			local j = grid.neighbor(t, d)
			local p = j and grid.port_at(j)
			local c = j and cells[j]
			if p then
				outs[#outs + 1] = "pin " .. pin(p)
			elseif c and (c.kind == "dust" or c.kind == "quartz") then
				outs[#outs + 1] = "net #" .. S.net_of[j * 2]
			elseif c and c.kind ~= "torch" then
				outs[#outs + 1] = c.kind .. " " .. at(j)
			end
		end
	end
	print(("torch %s on %s -> %s"):format(at(t), base and (base.kind .. " " .. at(base.cell)) or "NOTHING",
		#outs > 0 and table.concat(outs, ", ") or "nothing"))
end
