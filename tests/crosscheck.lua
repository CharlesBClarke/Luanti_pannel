-- Compares the Lua reference simulator with the JS prototype's, on cases
-- exported by scripts/crosscheck.sh. Optional: needs node and prototype/.
-- Usage: luajit tests/crosscheck.lua <cases.lua>

package.path = "./?.lua;" .. package.path
local ref = require("sim.ref")

local cases = dofile(arg[1])
local runs, failed = 0, 0

local function bits(t, first, last)
	local s = {}
	for i = first, last do
		s[#s + 1] = t[i] and "1" or "0"
	end
	return table.concat(s)
end

for _, case in ipairs(cases) do
	for _, run in ipairs(case.runs) do
		runs = runs + 1
		local state = ref.from_library(case.library, run.id)
		local inputs = {}
		for t, tog in ipairs(run.toggles) do
			if tog >= 0 then inputs[tog] = not inputs[tog] end
			local out = ref.step(state, inputs)
			ref.eval(state, inputs)
			local lamps = ref.lamps(state)
			local got = bits(out, 0, 31) .. "|" .. bits(lamps, 1, #lamps)
			if got ~= run.expect[t] then
				failed = failed + 1
				print(("MISMATCH trial %d panel %d tick %d\n  js  %s\n  lua %s"):format(
					case.trial, run.id, t, run.expect[t], got))
				break
			end
		end
	end
end

print(("crosscheck: %d of %d panels match the JS reference"):format(runs - failed, runs))
os.exit(failed == 0 and 0 or 1)
