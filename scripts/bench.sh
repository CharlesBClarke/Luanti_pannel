#!/usr/bin/env bash
# Start a headless VoxeLibre server that places floors of stress panels
# (bench.lua) and logs the tick time of each, then print the results.
# No client is connected, so sending face textures to players is not measured.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
world="$root/.bench/world"
log="$root/.bench/debug.txt"
conf="$root/.bench/luanti.conf"

rm -rf "$world"
mkdir -p "$world/worldmods"
ln -sfn "$root" "$world/worldmods/redstone_panels"
printf 'gameid = mineclone2\nbackend = sqlite3\n' > "$world/world.mt"
# Keep the bench area's map block loaded for the whole run (default 29 s).
printf 'redstone_panels.bench = true\ndedicated_server_step = 0.1\nserver_unload_unused_data_timeout = 3600\n' > "$conf"
rm -f "$log"

timeout 300 luanti --server --world "$world" --gameid mineclone2 \
	--config "$conf" --logfile "$log" --port 30098 > /dev/null 2>&1 || true

if grep -qE "ERROR|error:|Runtime error" "$log"; then
	grep -nE -A5 "ERROR|error:|Runtime error" "$log" | head -40
	echo "BENCH FAIL: errors in log ($log)"
	exit 1
fi
grep -o 'bench: .*' "$log" | sed 's/^bench: //'
grep -q "bench done" "$log" || { echo "BENCH FAIL: did not finish ($log)"; exit 1; }
