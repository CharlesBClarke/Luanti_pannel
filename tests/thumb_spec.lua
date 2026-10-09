local grid = require("sim.grid")
local compile = require("sim.compile")
local thumb = require("sim.thumb")

local function design(list)
	local cells = {}
	for _, e in ipairs(list) do cells[grid.index(e[1], e[2])] = e[3] end
	return cells
end

-- Paint a chain of "[fill:WxH:color" / "[fill:WxH:X,Y:color" into pixels.
local function raster(tex)
	local px = {}
	for part in (tex .. "^"):gmatch("(.-)%^") do
		local w, h, x, y, color = part:match("^%[fill:(%d+)x(%d+):(%d+),(%d+):(#%x+)$")
		if not w then
			w, h, color = part:match("^%[fill:(%d+)x(%d+):(#%x+)$")
			x, y = 0, 0
		end
		assert(w, "not a fill: " .. part)
		for j = y, y + h - 1 do
			for i = x, x + w - 1 do px[j * 1000 + i] = color end
		end
	end
	return px
end

-- The face as world.lua drew it before thumb.face: colors and inner squares
-- passed to thumb.texture.
local function plain_face(cells, net, lamps, probes, cell_px)
	local colors, inner, live = {}, {}, thumb.LIVE
	for j, c in ipairs(net.probe_cells) do colors[c] = live[cells[c].kind][probes[j] and 2 or 1] end
	local full, lit = {}, {}
	for j, on in ipairs(lamps) do
		local c, w = net.lamp_cells[j], net.lamp_rgb[j]
		full[c], lit[c] = full[c] or { 0, 0, 0 }, lit[c] or { 0, 0, 0 }
		for ch = 1, 3 do
			full[c][ch] = full[c][ch] + w[ch]
			if on then lit[c][ch] = lit[c][ch] + w[ch] end
		end
	end
	for c, f in pairs(full) do
		local l = lit[c]
		local color = thumb.lamp_color(f, thumb.lamp_level(l[1], f[1]), thumb.lamp_level(l[2], f[2]),
			thumb.lamp_level(l[3], f[3]))
		if cells[c].kind == "panel" then inner[c] = color else colors[c] = color end
	end
	return thumb.texture(cells, { cell_px = cell_px, colors = colors, inner = inner })
end

local function rng(seed)
	return function()
		seed = (seed * 1103515245 + 12345) % 2147483648
		return seed / 2147483648
	end
end

local KINDS = { "dust", "dust", "block", "bulb", "lamp", "lamp", "quartz", "torch", "button", "lever" }
local LAMP_COLORS = { false, "red", "green", "blue", "orange", "black" }

-- The face of library design `id` with lamps lit[j] lit (in net.lamps order).
local function face_of(lib, id, lit)
	local net = compile.from_library(lib, id)
	local lamps = {}
	for j = 1, #net.lamps do lamps[j] = lit[j] == true end
	return thumb.face_texture(thumb.face(lib[id].cells, net, 6), lamps, {}), net
end

-- The lamp weights of net's lamps in cell c, in order.
local function weights_in(net, c)
	local list = {}
	for j, cell in ipairs(net.lamp_cells) do
		if cell == c then list[#list + 1] = net.lamp_rgb[j] end
	end
	return list
end

local function near(a, b)
	return math.abs(a - b) < 1e-9
end

local function count(s, pattern)
	local n = 0
	for _ in s:gmatch(pattern) do n = n + 1 end
	return n
end

return {
	["texture has the background and one square per cell"] = function()
		local tex = thumb.texture({})
		assert(tex:sub(1, 6) == "[fill:", tex:sub(1, 20))
		assert(count(tex, "%^") == grid.SIZE * grid.SIZE)
	end,

	["texture colors cells by part"] = function()
		local tex = thumb.texture(design({ { 1, 1, { kind = "dust" } }, { 3, 2, { kind = "panel", id = 7 } } }))
		local px = thumb.CELL_PX
		assert(tex:find(("[fill:%dx%d:1,1:%s"):format(px, px, thumb.COLORS.dust), 1, true), "dust at 1,1")
		local stride = px + 1
		assert(tex:find(("[fill:%dx%d:%d,%d:%s"):format(px, px, 1 + 2 * stride, 1 + stride, thumb.COLORS.panel),
			1, true), "panel at 3,2")
		assert(count(tex, thumb.COLORS.dust) == 1)
	end,

	["thumbnail colors lamps by their color"] = function()
		local tex = thumb.texture(design({ { 1, 1, { kind = "lamp", color = "blue" } }, { 2, 1, { kind = "lamp" } } }))
		assert(tex:find(thumb.cell_color({ kind = "lamp", color = "blue" }), 1, true))
		assert(thumb.cell_color({ kind = "lamp", color = "blue" }):match("^#0000%x%x$"))
		assert(tex:find(thumb.cell_color({ kind = "lamp" }), 1, true))
	end,

	["own lamps add their color; plain lamps look as before"] = function()
		local net = compile.panel(design({ { 2, 2, { kind = "lamp", color = "red" } }, { 3, 2, { kind = "lamp" } } }))
		local red = weights_in(net, grid.index(2, 2))[1]
		assert(red[1] == 1 and red[2] == 0 and red[3] == 0)
		assert(weights_in(net, grid.index(3, 2))[1] == grid.PLAIN_LAMP)
	end,

	["nested pixels average each color over the cells that have it"] = function()
		-- 4 red lamps, 1 green, 1 white: red is shared 5 ways (white has red
		-- too), green 2 ways, blue only by white.
		local kid = {}
		for x = 1, 4 do kid[#kid + 1] = { x, 1, { kind = "lamp", color = "red" } } end
		kid[#kid + 1] = { 1, 2, { kind = "lamp", color = "green" } }
		kid[#kid + 1] = { 2, 2, { kind = "lamp", color = "white" } }
		local lib = { { cells = design(kid) },
			{ cells = design({ { 5, 5, { kind = "panel", id = 1, speed = 1 } } }) } }
		local net = compile.from_library(lib, 2)
		local w = weights_in(net, grid.index(5, 5))
		assert(#w == 6)
		local sum = { 0, 0, 0 }
		for _, v in ipairs(w) do
			for ch = 1, 3 do sum[ch] = sum[ch] + v[ch] end
		end
		assert(near(sum[1], 1) and near(sum[2], 1) and near(sum[3], 1), "all lit is full brightness")
		-- Own lamps in S.lamps order: cell index order, so row 1 then row 2.
		assert(near(w[1][1], 1 / 5) and w[1][2] == 0)
		assert(near(w[5][2], 1 / 2) and w[5][1] == 0)
		assert(near(w[6][1], 1 / 5) and near(w[6][2], 1 / 2) and near(w[6][3], 1))
	end,

	["averaging nests: each cell counts once, however many lamps it holds"] = function()
		-- Panel 1: 4 red lamps. Panel 2: panel 1 next to one red lamp.
		-- Panel 3 shows panel 2: panel 1's lamps are 1/8 each, the lone lamp 1/2.
		local four = {}
		for x = 1, 4 do four[#four + 1] = { x, 1, { kind = "lamp", color = "red" } } end
		local lib = {
			{ cells = design(four) },
			{ cells = design({ { 1, 1, { kind = "panel", id = 1, speed = 1 } }, { 3, 3, { kind = "lamp", color = "red" } } }) },
			{ cells = design({ { 4, 4, { kind = "panel", id = 2, speed = 1 } } }) },
		}
		local net = compile.from_library(lib, 3)
		local w = weights_in(net, grid.index(4, 4))
		assert(#w == 5)
		-- Panel 2 lists its own lamp first, then panel 1's.
		assert(near(w[1][1], 1 / 2))
		for k = 2, 5 do assert(near(w[k][1], 1 / 8)) end
	end,

	["face: one lit lamp of four shows a quarter, and red plus green is yellow"] = function()
		local kid = {}
		for x = 1, 4 do kid[#kid + 1] = { x, 1, { kind = "lamp", color = "red" } } end
		local lib = { { cells = design(kid) },
			{ cells = design({ { 5, 5, { kind = "panel", id = 1, speed = 1 } } }) },
			{ cells = design({ { 1, 1, { kind = "lamp", color = "red" } }, { 2, 1, { kind = "lamp", color = "green" } } }) },
			{ cells = design({ { 5, 5, { kind = "panel", id = 3, speed = 1 } } }) } }
		local L = thumb.LAMP_LEVELS
		local tex = face_of(lib, 2, { true })
		assert(tex:find(thumb.lamp_color({ 1, 0, 0 }, L / 4, 0, 0), 1, true), "a quarter red")
		tex = face_of(lib, 2, { true, true, true, true })
		assert(tex:find(thumb.lamp_color({ 1, 0, 0 }, L, 0, 0), 1, true), "full red")
		tex = face_of(lib, 4, { true, true })
		assert(tex:find(thumb.lamp_color({ 1, 1, 0 }, L, L, 0), 1, true), "yellow")
		assert(thumb.lamp_color({ 1, 1, 0 }, L, L, 0) == "#ffff00")
		tex = face_of(lib, 4, { true, false })
		assert(tex:find(thumb.lamp_color({ 1, 1, 0 }, L, 0, 0), 1, true), "red, green dim")
	end,

	["face: any light at all shows"] = function()
		assert(thumb.lamp_level(0, 1) == 0)
		assert(thumb.lamp_level(0.01, 1) == 1)
		assert(thumb.lamp_level(1, 1) == thumb.LAMP_LEVELS)
		assert(thumb.lamp_level(0, 0) == 0)
	end,

	["edges: dust straight across reads and drives both ends"] = function()
		local row = {}
		for x = 1, grid.SIZE do row[#row + 1] = { x, 4, { kind = "dust" } } end
		local edges = thumb.edges(compile.panel(design(row)))
		assert(thumb.edges_text(edges) == "E in/out, W in/out", thumb.edges_text(edges))
	end,

	["edges: a lever on the east edge only drives"] = function()
		local edges = thumb.edges(compile.panel(design({ { 8, 4, { kind = "lever" } } })))
		assert(thumb.edges_text(edges) == "E out", thumb.edges_text(edges))
	end,

	["edges: an inner-only design uses none"] = function()
		local edges = thumb.edges(compile.panel(design({ { 4, 4, { kind = "lamp" } } })))
		assert(thumb.edges_text(edges) == "none", thumb.edges_text(edges))
	end,

	["fuzz: prepared faces draw the same pixels as plain faces"] = function()
		for trial = 1, 30 do
			local rnd = rng(trial * 104729)
			local function random_cells(kid)
				local cells = {}
				for y = 1, grid.SIZE do
					for x = 1, grid.SIZE do
						local r = rnd()
						if kid and r < 0.1 then
							cells[grid.index(x, y)] = { kind = "panel", id = 1, speed = 1 }
						elseif r < 0.6 then
							local kind = KINDS[math.floor(rnd() * #KINDS) + 1]
							local color = kind == "lamp" and LAMP_COLORS[math.floor(rnd() * #LAMP_COLORS) + 1] or nil
							cells[grid.index(x, y)] = { kind = kind, attach = kind == "torch" and math.floor(rnd() * 4) or nil,
								color = color or nil }
						end
					end
				end
				return cells
			end
			local lib = { { cells = random_cells(false) } }
			lib[2] = { cells = random_cells(true) }
			local net = compile.from_library(lib, 2)
			for _, cell_px in ipairs({ 2, 6 }) do
				local face = thumb.face(lib[2].cells, net, cell_px)
				for _ = 1, 5 do
					local lamps, probes = {}, {}
					for j = 1, #net.lamps do lamps[j] = rnd() < 0.5 end
					for j = 1, #net.probes do probes[j] = rnd() < 0.5 end
					local a = raster(thumb.face_texture(face, lamps, probes))
					local b = raster(plain_face(lib[2].cells, net, lamps, probes, cell_px))
					for k, v in pairs(b) do
						assert(a[k] == v, ("trial %d px %d: prepared %s, plain %s"):format(trial, k, tostring(a[k]), v))
					end
					for k in pairs(a) do assert(b[k], "extra pixel " .. k) end
				end
			end
		end
	end,
}
