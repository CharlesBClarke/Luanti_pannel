-- Panels drawn as ASCII art. Pure Lua: no core.* calls allowed in sim/.
--
-- A drawing is 8 rows of 8 cells, top row first; spaces are ignored.
--   .  empty         +  dust          q  quartz        B  block
--   U  copper bulb   L  lamp          b  button        l  lever
--   ^ > v <  a torch standing on the block to its north, east, south, west
-- Any other character is a nested panel, looked up in `legend` as
-- { name = design name, turn = quarter turns } or just the name.

-- In-game, init.lua loads sim/ files with loadfile and passes its own loader.
local require = type(...) == "function" and ... or require

local grid = require("sim.grid")

local art = {}

local SIZE = grid.SIZE
local TORCH = { ["^"] = 0, [">"] = 1, ["v"] = 2, ["<"] = 3 }
local PART = { ["+"] = "dust", q = "quartz", B = "block", U = "bulb", L = "lamp", b = "button", l = "lever" }

-- Cells of a drawing. ids[name] gives the library id of a nested design.
function art.cells(rows, legend, ids)
	assert(#rows == SIZE, "a drawing has 8 rows")
	local cells = {}
	for y, row in ipairs(rows) do
		row = row:gsub(" ", "")
		assert(#row == SIZE, ("row %d has %d cells, not 8"):format(y, #row))
		for x = 1, SIZE do
			local ch = row:sub(x, x)
			local i = grid.index(x, y)
			if TORCH[ch] then
				cells[i] = { kind = "torch", attach = TORCH[ch] }
			elseif PART[ch] then
				cells[i] = { kind = PART[ch] }
			elseif ch ~= "." then
				local e = legend and legend[ch]
				assert(e, ("no legend entry for %q"):format(ch))
				if type(e) == "string" then e = { name = e } end
				local id = ids and ids[e.name]
				assert(id, ("design %q is not built yet"):format(e.name))
				cells[i] = { kind = "panel", id = id, speed = 1, turn = e.turn }
			end
		end
	end
	return cells
end

-- Mirror a drawing left to right. Torches turn with it; nested panels need
-- their own mirrored design, so legend characters are kept as they are.
function art.mirror(rows)
	local SWAP = { [">"] = "<", ["<"] = ">" }
	local out = {}
	for y, row in ipairs(rows) do
		row = row:gsub(" ", "")
		out[y] = row:reverse():gsub("[<>]", SWAP)
	end
	return out
end

return art
