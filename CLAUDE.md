# Redstone Panels (Luanti mod for VoxeLibre)

Spec: @docs/spec.md. It is the source of truth; if code and spec disagree, ask.

## Commands
- Unit tests: `luajit tests/run.lua` (specs are `tests/*_spec.lua`, each returns `{name = fn}`)
- Smoke test: `scripts/smoke.sh` (headless VoxeLibre server, fails on any Lua error in the log)
- Crosscheck vs JS prototype (optional, local only): `scripts/crosscheck.sh [seed] [trials] [ticks]`. Run after changing `sim/static.lua` or `sim/ref.lua`.
- Lint: `luacheck .` (not installed yet; needs luarocks)
- Run both test commands after every change; show their output.

## Targets
- Luanti 5.17, LuaJIT (Lua 5.1 syntax plus `goto`: no integer division `//`, no `<const>`, no `utf8` lib).
- VoxeLibre 0.92 (`gameid = mineclone2`), installed at `~/.minetest/games/mineclone2`.
- Use `core.*`, never the old `minetest.*` alias.

## Architecture
- `sim/`: pure Lua (grid, compiler, runtime). **IMPORTANT: no `core.*`, `mesecon`, or other globals in `sim/`** so it runs and is tested under plain LuaJIT. Each file returns a module table.
- `init.lua` and other root files: engine glue only (nodes, formspecs, mesecons).
- A JS prototype lives in `prototype/` (gitignored, never commit it). Use it for ideas, not as a reference: the spec decides behavior.
- Compiled panels must match a plain step-by-step Lua simulation tick for tick; check this with fuzz tests in `tests/`.

## API references (read these, don't guess)
- Luanti: https://github.com/luanti-org/luanti/blob/5.17.0/doc/lua_api.md
- VoxeLibre redstone is classic mesecons: `~/.minetest/games/mineclone2/mods/ITEMS/REDSTONE/mesecons/` (`init.lua` for receptor/effector API, `presets.lua` for rules). Mostly undocumented: read the source.

## Conventions
- Tunable numbers (button ticks, limits, speeds) go in named constants; pick a sensible value, don't stop to confirm.
