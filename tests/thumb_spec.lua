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
	local lit = {}
	for j, on in ipairs(lamps) do
		local c = net.lamp_cells[j]
		lit[c] = lit[c] or on
	end
	for c, on in pairs(lit) do
		local color = live.lamp[on and 2 or 1]
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
							cells[grid.index(x, y)] = { kind = kind, attach = kind == "torch" and math.floor(rnd() * 4) or nil }
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
