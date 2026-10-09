-- Thumbnails and summaries of a panel design. Pure Lua: builds texture
-- strings but never calls the engine.
--
-- A thumbnail draws one square per cell, colored by part. Only the panel's
-- own cells are drawn: a nested panel is a plain tile, never its insides.

-- In-game, init.lua loads sim/ files with loadfile and passes its own loader.
local require = type(...) == "function" and ... or require

local grid = require("sim.grid")

local thumb = {}

thumb.CELL_PX = 2 -- texture pixels per cell side
local GAP_PX = 1 -- blank line between cells, so neighbours read as separate parts

-- Texture side in pixels for a given cell size.
function thumb.size(cell_px)
	return grid.SIZE * (cell_px + GAP_PX) + GAP_PX
end
thumb.PX = thumb.size(thumb.CELL_PX)

thumb.COLOR_BG = "#141414"
thumb.COLOR_EMPTY = "#2a2a2a"
thumb.COLOR_EDGE = "#3a352c" -- empty cells on the outer ring, which connect outside
thumb.COLORS = {
	dust = "#c01818", torch = "#ff7a20", block = "#8a8a8a", quartz = "#ece4dc",
	bulb = "#b87333", lamp = "#6a5020", button = "#5a8ac0", lever = "#a07840",
	panel = "#3a6a3a",
}

-- Live colors for the face of a placed panel: { off, on } per part.
thumb.LIVE = {
	dust = { "#4a0808", "#ff2a2a" }, torch = { "#5a2a10", "#ffb030" }, block = { "#5a5a5a", "#b0a090" },
	quartz = { "#8a8480", "#fff4ec" }, bulb = { "#5a3a1a", "#ffb060" }, lamp = { "#4a3818", "#ffd040" },
	button = { "#2a4060", "#80c0ff" }, lever = { "#4a3a20", "#e0b060" },
}

-- Texture string for a design (a cells table as in sim/grid.lua).
-- opts (all optional): cell_px, the size of one cell; colors[cell], a color
-- that replaces the part's own; inner[cell], a color drawn as a smaller
-- square inside the cell (needs cell_px of at least 4).
function thumb.texture(cells, opts)
	opts = opts or {}
	local cell_px = opts.cell_px or thumb.CELL_PX
	local colors, inner = opts.colors or {}, opts.inner or {}
	local px, stride = thumb.size(cell_px), cell_px + GAP_PX
	local inset = math.floor(cell_px / 4)
	local parts = { ("[fill:%dx%d:%s"):format(px, px, thumb.COLOR_BG) }
	for y = 1, grid.SIZE do
		for x = 1, grid.SIZE do
			local i = grid.index(x, y)
			local cell = cells[i]
			local color = colors[i] or cell and thumb.COLORS[cell.kind]
				or (grid.is_edge(x, y) and thumb.COLOR_EDGE or thumb.COLOR_EMPTY)
			local cx, cy = GAP_PX + (x - 1) * stride, GAP_PX + (y - 1) * stride
			parts[#parts + 1] = ("[fill:%dx%d:%d,%d:%s"):format(cell_px, cell_px, cx, cy, color)
			if inner[i] and inset > 0 then
				local w = cell_px - 2 * inset
				parts[#parts + 1] = ("[fill:%dx%d:%d,%d:%s"):format(w, w, cx + inset, cy + inset, inner[i])
			end
		end
	end
	return table.concat(parts, "^")
end

-- Which sides of a compiled net read and drive their edge bits:
-- edges[d] = { input = bool, output = bool } for d = 0..3.
function thumb.edges(net)
	local edges = {}
	for d = 0, 3 do edges[d] = { input = false, output = false } end
	for _, n in ipairs(net.nodes) do
		if n.op == "in" then edges[math.floor(n.pin / grid.BITS)].input = true end
	end
	for p = 0, grid.PORTS - 1 do
		local n = net.nodes[net.outs[p]]
		if not (n.op == "const" and n.v == false) then edges[math.floor(p / grid.BITS)].output = true end
	end
	return edges
end

local SIDE_NAMES = { [0] = "N", "E", "S", "W" }

-- One line like "N in, E out, W in/out", or "none".
function thumb.edges_text(edges)
	local list = {}
	for d = 0, 3 do
		local e = edges[d]
		local what = (e.input and e.output and "in/out") or (e.input and "in") or (e.output and "out")
		if what then list[#list + 1] = SIDE_NAMES[d] .. " " .. what end
	end
	return #list > 0 and table.concat(list, ", ") or "none"
end

return thumb
