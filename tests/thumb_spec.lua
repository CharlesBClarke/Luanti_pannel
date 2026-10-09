local grid = require("sim.grid")
local compile = require("sim.compile")
local thumb = require("sim.thumb")

local function design(list)
	local cells = {}
	for _, e in ipairs(list) do cells[grid.index(e[1], e[2])] = e[3] end
	return cells
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
}
