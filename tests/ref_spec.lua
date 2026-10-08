local grid = require("sim.grid")
local ref = require("sim.ref")

local N, E, S, W = 0, 1, 2, 3

-- Build a one-panel library from {x, y, kind, attach} entries.
local function library(...)
	local lib = {}
	for id, list in ipairs({ ... }) do
		local cells = {}
		for _, e in ipairs(list) do
			local cell = { kind = e[3] }
			if e[3] == "torch" then cell.attach = e[4] end
			if e[3] == "panel" then cell.id, cell.speed = e[4], e[5] or 1 end
			cells[grid.index(e[1], e[2])] = cell
		end
		lib[id - 1] = { cells = cells }
	end
	return lib
end

local function port(side, bit)
	return side * grid.BITS + bit
end

-- Run ticks with fixed inputs, return the chosen output as a "0101" string.
local function trace(state, inputs, out_port, ticks)
	local s = {}
	for _ = 1, ticks do
		s[#s + 1] = ref.step(state, inputs)[out_port] and "1" or "0"
	end
	return table.concat(s)
end

return {
	["dust carries an edge signal across instantly"] = function()
		local cells = {}
		for x = 1, 8 do cells[#cells + 1] = { x, 4, "dust" } end
		local st = ref.from_library(library(cells), 0)
		local inputs = { [port(W, 3)] = true }
		assert(ref.eval(st, inputs)[port(E, 3)] == true)
		assert(ref.eval(st, {})[port(E, 3)] == false)
	end,

	["no self-echo: an edge output ignores its own input"] = function()
		local st = ref.from_library(library({ { 1, 4, "dust" } }), 0)
		assert(ref.eval(st, { [port(W, 3)] = true })[port(W, 3)] == false)
	end,

	["torch inverts with a 1 tick delay"] = function()
		-- edge -> dust -> block <- torch (standing on the block, west) -> east edge
		local st = ref.from_library(library({
			{ 1, 4, "dust" }, { 2, 4, "dust" }, { 3, 4, "block" },
			{ 4, 4, "torch", W }, { 5, 4, "dust" }, { 6, 4, "dust" }, { 7, 4, "dust" }, { 8, 4, "dust" },
		}), 0)
		local on = { [port(W, 3)] = true }
		assert(trace(st, {}, port(E, 3), 3) == "111")
		assert(trace(st, on, port(E, 3), 3) == "100", "turns off one tick after the block powers")
		assert(trace(st, {}, port(E, 3), 3) == "011")
	end,

	["torch reading its own block is a 1 tick clock"] = function()
		-- A torch can't power the block it stands on directly, so loop back
		-- through dust: torch (3,2) -> dust (3,3), (2,3) -> its block (2,2).
		local st = ref.from_library(library({
			{ 2, 2, "block" }, { 3, 2, "torch", W }, { 3, 3, "dust" }, { 2, 3, "dust" },
			{ 3, 1, "dust" },
		}), 0)
		local t = trace(st, {}, port(N, 2), 6)
		assert(t == "101010" or t == "010101", "got " .. t)
	end,

	["copper bulb toggles on each rising input"] = function()
		-- west edge -> dust -> bulb; torch on bulb (inverted) -> dust -> east edge
		local st = ref.from_library(library({
			{ 1, 4, "dust" }, { 2, 4, "bulb" }, { 3, 4, "torch", W },
			{ 4, 4, "dust" }, { 5, 4, "dust" }, { 6, 4, "dust" }, { 7, 4, "dust" }, { 8, 4, "dust" },
		}), 0)
		local on = { [port(W, 3)] = true }
		assert(trace(st, {}, port(E, 3), 2) == "11", "bulb starts off, torch on")
		assert(trace(st, on, port(E, 3), 4) == "1100", "bulb flips on; torch off a tick later")
		assert(trace(st, {}, port(E, 3), 2) == "00", "stays flipped when input drops")
		assert(trace(st, on, port(E, 3), 4) == "0011", "flips back on the next press")
	end,

	["lever toggles on each press and drives the edge directly"] = function()
		local st = ref.from_library(library({ { 1, 4, "lever" } }), 0)
		assert(trace(st, {}, port(W, 3), 2) == "00")
		ref.press(st, grid.index(1, 4))
		assert(trace(st, {}, port(W, 3), 2) == "11")
		ref.press(st, grid.index(1, 4))
		assert(trace(st, {}, port(W, 3), 2) == "00")
	end,

	["pressing an empty cell does nothing"] = function()
		local st = ref.from_library(library({ { 1, 4, "lever" } }), 0)
		ref.press(st, grid.index(2, 4))
		assert(trace(st, {}, port(W, 3), 2) == "00")
	end,

	["button stays on for BUTTON_TICKS ticks"] = function()
		-- button -> dust -> block; torch reads the block -> east edge
		local st = ref.from_library(library({
			{ 1, 4, "button" }, { 2, 4, "dust" }, { 3, 4, "block" }, { 4, 4, "torch", W },
			{ 5, 4, "dust" }, { 6, 4, "dust" }, { 7, 4, "dust" }, { 8, 4, "dust" },
		}), 0)
		local n = grid.BUTTON_TICKS
		ref.press(st, grid.index(1, 4))
		assert(trace(st, {}, port(W, 3), n + 2) == ("1"):rep(n) .. "00")
		ref.press(st, grid.index(1, 4))
		assert(trace(st, {}, port(E, 3), n + 3) == "1" .. ("0"):rep(n) .. "11", "torch lags by one tick")
	end,

	["pressing a nested panel's cell presses everything inside it"] = function()
		-- Kid: two levers on its east edge. Parent: kid at (2,4), dust to the east edge.
		local lib = library(
			{ { 8, 2, "lever" }, { 8, 6, "lever" } },
			{ { 2, 4, "panel", 0 }, { 3, 4, "dust" }, { 4, 4, "dust" }, { 5, 4, "dust" },
				{ 6, 4, "dust" }, { 7, 4, "dust" }, { 8, 4, "dust" } }
		)
		local st = ref.from_library(lib, 1)
		assert(trace(st, {}, port(E, 3), 1) == "0")
		ref.press(st, grid.index(2, 4))
		assert(trace(st, {}, port(E, 3), 1) == "1")
		local kid = st.kids[grid.index(2, 4)]
		assert(kid.switch[grid.index(8, 2)] and kid.switch[grid.index(8, 6)], "both levers flipped")
	end,

	["a button in a 2x panel lasts half as many ticks"] = function()
		local lib = library(
			{ { 8, 4, "button" } },
			{ { 2, 4, "panel", 0, 2 }, { 3, 4, "dust" }, { 4, 4, "dust" }, { 5, 4, "dust" },
				{ 6, 4, "dust" }, { 7, 4, "dust" }, { 8, 4, "dust" } }
		)
		local st = ref.from_library(lib, 1)
		local half = math.ceil(grid.BUTTON_TICKS / 2)
		ref.press(st, grid.index(2, 4))
		assert(trace(st, {}, port(E, 3), half + 1) == ("1"):rep(half) .. "0")
	end,

	["XOR matches the prototype's trace"] = function()
		-- Hand-built XOR from the prototype's filter_test.js ({col, row} -> x, y).
		local D, B, T = "dust", "block", "torch"
		local xor = {
			{ 4, 1, D }, { 4, 2, D }, { 3, 2, D }, { 3, 3, D }, { 2, 3, D }, { 2, 4, D }, { 3, 4, B },
			{ 4, 4, T, W }, { 2, 5, B }, { 3, 5, T, W }, { 3, 6, B }, { 4, 6, T, W }, { 2, 6, D },
			{ 2, 7, D }, { 2, 8, D }, { 5, 4, D }, { 5, 5, D }, { 6, 5, D }, { 7, 5, D }, { 8, 5, D },
			{ 5, 6, D },
		}
		local st = ref.from_library(library(xor), 0)
		local expected = {
			"00:00000000", "10:00111111", "11:10000000", "00:01000000", "01:00111111",
			"11:10000000", "00:01000000", "10:00111111", "01:11111111", "00:11000000",
		}
		local pairs_ = { { 0, 0 }, { 1, 0 }, { 1, 1 }, { 0, 0 }, { 0, 1 }, { 1, 1 }, { 0, 0 }, { 1, 0 }, { 0, 1 }, { 0, 0 } }
		for i, ab in ipairs(pairs_) do
			local inputs = { [port(N, 3)] = ab[1] == 1, [port(S, 1)] = ab[2] == 1 }
			local got = ab[1] .. ab[2] .. ":" .. trace(st, inputs, port(E, 4), 8)
			assert(got == expected[i], ("step %d: expected %s, got %s"):format(i, expected[i], got))
		end
	end,
}
