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
	bulb = "#b87333", button = "#5a8ac0", lever = "#a07840",
	panel = "#3a6a3a",
}

thumb.LAMP_LEVELS = 4 -- brightness steps per color channel on a face pixel
thumb.LAMP_OFF = 0.3 -- how bright an unlit lamp looks, as a share of its lit color
local THUMB_LAMP = 0.42 -- how bright lamps look on a thumbnail
local LAMP_LIFT = 0.4 -- gray added to dark dyes (black, brown) so they still show, scaled by how dark they are

local function hex(r, g, b)
	local function byte(v) return math.floor(math.min(math.max(v, 0), 1) * 255 + 0.5) end
	return ("#%02x%02x%02x"):format(byte(r), byte(g), byte(b))
end

-- `rgb` with gray added the darker it is; bright colors stay as they are and
-- dark ones keep their order (black stays darker than grey).
local function lifted(rgb)
	local add = LAMP_LIFT * (1 - math.max(rgb[1], rgb[2], rgb[3]))
	return { rgb[1] + add, rgb[2] + add, rgb[3] + add }
end

-- Color of a lamp pixel whose light is `full` ({ r, g, b }, 0 to 1) when
-- all its lamps are lit, with lr, lg and lb of LAMP_LEVELS steps of its
-- red, green and blue lit.
function thumb.lamp_color(full, lr, lg, lb)
	local L, off = thumb.LAMP_LEVELS, thumb.LAMP_OFF
	full = lifted(full)
	return hex(full[1] * (off + (1 - off) * lr / L), full[2] * (off + (1 - off) * lg / L),
		full[3] * (off + (1 - off) * lb / L))
end

-- Live colors for the face of a placed panel: { off, on } per part.
-- (Lamps are colored by thumb.lamp_color; this is a plain lamp.)
thumb.LIVE = {
	dust = { "#4a0808", "#ff2a2a" }, torch = { "#5a2a10", "#ffb030" }, block = { "#5a5a5a", "#b0a090" },
	quartz = { "#8a8480", "#fff4ec" }, bulb = { "#5a3a1a", "#ffb060" },
	lamp = { thumb.lamp_color(grid.PLAIN_LAMP, 0, 0, 0),
		thumb.lamp_color(grid.PLAIN_LAMP, thumb.LAMP_LEVELS, thumb.LAMP_LEVELS, thumb.LAMP_LEVELS) },
	button = { "#2a4060", "#80c0ff" }, lever = { "#4a3a20", "#e0b060" },
}

-- Thumbnail color of a part (lamps take their own color).
function thumb.cell_color(cell)
	if cell.kind == "lamp" then
		local rgb = lifted(grid.lamp_rgb(cell))
		return hex(rgb[1] * THUMB_LAMP, rgb[2] * THUMB_LAMP, rgb[3] * THUMB_LAMP)
	end
	return thumb.COLORS[cell.kind]
end

-- Quantized level (0 to LAMP_LEVELS) of a channel lit to `lit` out of `full`.
-- Any light at all shows, so one lit lamp among many never disappears.
local function level(lit, full)
	if full <= 0 or lit <= 0 then return 0 end
	return math.min(thumb.LAMP_LEVELS, math.ceil(lit / full * thumb.LAMP_LEVELS - 1e-9))
end
thumb.lamp_level = level

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
			local color = colors[i] or cell and thumb.cell_color(cell)
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

-- Live face of a placed panel, prepared once per design so a redraw only
-- joins ready-made strings. The panel's own cells show their live state,
-- one level deep: a probe colors its part; a cell with lamps shows their
-- mixed color (net.lamp_rgb), each channel as bright as the share of its
-- light that is lit (a nested panel as a smaller square inside its tile).
-- net is the compiled design (probes, lamps and their cells).
function thumb.face(cells, net, cell_px)
	local px, stride = thumb.size(cell_px), cell_px + GAP_PX
	local inset = math.floor(cell_px / 4)
	local live, sources = thumb.LIVE, {} -- sources[cell] = { lamps = {j...}, probes = {j...} }
	local function src(c)
		sources[c] = sources[c] or { lamps = {}, probes = {} }
		return sources[c]
	end
	for j, c in ipairs(net.probe_cells) do table.insert(src(c).probes, j) end
	for j, c in ipairs(net.lamp_cells) do table.insert(src(c).lamps, j) end
	local function fill(x, y, size, off, color)
		local cx, cy = GAP_PX + (x - 1) * stride + off, GAP_PX + (y - 1) * stride + off
		return ("[fill:%dx%d:%d,%d:%s"):format(size, size, cx, cy, color)
	end
	-- A lamp pixel: its lamps, what each adds when lit, and its fill
	-- fragments, made once per color as they come up.
	local function lamp_entry(list, x, y, size, off)
		local rgb, full = {}, { 0, 0, 0 }
		for k, j in ipairs(list) do
			rgb[k] = net.lamp_rgb[j]
			for ch = 1, 3 do full[ch] = full[ch] + rgb[k][ch] end
		end
		return { lamps = list, rgb = rgb, full = full, frags = {}, frag = function(lr, lg, lb)
			return fill(x, y, size, off, thumb.lamp_color(full, lr, lg, lb))
		end }
	end
	local static, entries = { ("[fill:%dx%d:%s"):format(px, px, thumb.COLOR_BG) }, {}
	for y = 1, grid.SIZE do
		for x = 1, grid.SIZE do
			local i = grid.index(x, y)
			local cell, s = cells[i], sources[i]
			local kind = cell and cell.kind
			local lamps = s and #s.lamps > 0
			if kind == "panel" and lamps then
				static[#static + 1] = fill(x, y, cell_px, 0, thumb.COLORS.panel)
				if inset > 0 then entries[#entries + 1] = lamp_entry(s.lamps, x, y, cell_px - 2 * inset, inset) end
			elseif lamps then
				entries[#entries + 1] = lamp_entry(s.lamps, x, y, cell_px, 0)
			elseif s and #s.probes > 0 then
				entries[#entries + 1] = { lamps = {}, probes = s.probes,
					fill(x, y, cell_px, 0, live[kind][1]), fill(x, y, cell_px, 0, live[kind][2]) }
			else
				local color = cell and thumb.cell_color(cell)
					or (grid.is_edge(x, y) and thumb.COLOR_EDGE or thumb.COLOR_EMPTY)
				static[#static + 1] = fill(x, y, cell_px, 0, color)
			end
		end
	end
	return { static = table.concat(static, "^"), entries = entries, buf = {} }
end

-- Texture string of a face from thumb.face, given the live lamp and probe
-- states (lists of booleans in net.lamps and net.probes order).
function thumb.face_texture(face, lamps, probes)
	local buf = face.buf
	buf[1] = face.static
	local L1 = thumb.LAMP_LEVELS + 1
	for k, e in ipairs(face.entries) do
		if e.rgb then
			local r, g, b = 0, 0, 0
			for n, j in ipairs(e.lamps) do
				if lamps[j] then
					local w = e.rgb[n]
					r, g, b = r + w[1], g + w[2], b + w[3]
				end
			end
			local full = e.full
			local lr, lg, lb = level(r, full[1]), level(g, full[2]), level(b, full[3])
			local key = (lr * L1 + lg) * L1 + lb
			local frag = e.frags[key]
			if not frag then
				frag = e.frag(lr, lg, lb)
				e.frags[key] = frag
			end
			buf[k + 1] = frag
		else
			local on = false
			for _, j in ipairs(e.probes) do on = on or probes[j] end
			buf[k + 1] = e[on and 2 or 1]
		end
	end
	return table.concat(buf, "^", 1, #face.entries + 1)
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
