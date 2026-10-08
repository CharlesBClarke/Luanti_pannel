-- Minimal test runner: luajit tests/run.lua
-- Loads every tests/*_spec.lua. Each spec returns a table of name -> function.

package.path = "./?.lua;" .. package.path

local failed, passed = 0, 0
local specs = io.popen("ls tests/*_spec.lua"):read("*a")

for path in specs:gmatch("[^\n]+") do
	local cases = dofile(path)
	for name, fn in pairs(cases) do
		local ok, err = pcall(fn)
		if ok then
			passed = passed + 1
		else
			failed = failed + 1
			print(("FAIL %s: %s\n  %s"):format(path, name, err))
		end
	end
end

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
