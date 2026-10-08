#!/usr/bin/env bash
# Optional local check: run random panels through the JS prototype and the
# Lua simulator and compare every tick. Needs node and prototype/redstone-panels-fuzz.zip.
# Usage: scripts/crosscheck.sh [seed] [trials] [ticks]
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cache="$root/.cache/crosscheck"
zip="$root/prototype/redstone-panels-fuzz.zip"

mkdir -p "$cache"
if [ ! -f "$cache/redstone-panels-fuzz/engine.js" ]; then
	unzip -o -q "$zip" -d "$cache"
fi
node "$root/scripts/export_cases.js" "$cache/redstone-panels-fuzz/engine.js" "${1:-5}" "${2:-10}" "${3:-100}" \
	> "$cache/cases.lua"
cd "$root" && luajit tests/crosscheck.lua "$cache/cases.lua"
