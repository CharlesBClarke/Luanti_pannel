#!/usr/bin/env bash
# Start a headless VoxeLibre server with this mod, wait for it to exit,
# and fail if the log has Lua errors or no "smoke test OK".
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
world="$root/.smoke/world"
log="$root/.smoke/debug.txt"
conf="$root/.smoke/luanti.conf"

rm -rf "$world"
mkdir -p "$world/worldmods"
ln -sfn "$root" "$world/worldmods/redstone_panels"
printf 'gameid = mineclone2\nbackend = sqlite3\n' > "$world/world.mt"
printf 'redstone_panels.smoke_test = true\n' > "$conf"
rm -f "$log"

timeout 90 luanti --server --world "$world" --gameid mineclone2 \
	--config "$conf" --logfile "$log" --port 30099 > /dev/null 2>&1 || true

if grep -qE "ERROR|error:|Runtime error" "$log"; then
	grep -nE -A5 "ERROR|error:|Runtime error" "$log" | head -40
	echo "SMOKE FAIL: errors in log ($log)"
	exit 1
fi
if ! grep -q "smoke test OK" "$log"; then
	tail -20 "$log"
	echo "SMOKE FAIL: mod did not report OK ($log)"
	exit 1
fi
echo "SMOKE OK"
