# To do

## State (2026-10-08)
- Steps 1-4 of the UI redesign and the flicker fix are committed (a95b711) and pushed.
- Steps 2-4 checked in game 2026-10-08 (workbench, floor faces in all turns, presses, live power).
- Placement: floor only, as in the spec. The node is a 1/8-tall nodebox
  (`PANEL_HEIGHT`, world.lua); the face is a thin flat entity on top of it.
  Needs an in-game look at the new height.

## UI redesign (agreed 2026-10-08; spec: World and gameplay > Workbench, displays)
The editor was too frustrating to use. Main complaint: nested panels on the board
don't show what they are, and a finished panel can't be inspected. Order:
1. DONE (checked in game 2026-10-08): thumbnail texture builder (one pixel per cell, colored by part) plus a tooltip
   (name, id, gates, edges used). Use it as the item's `inventory_image` meta and on
   nested cells in the editor.
2. DONE (needs an in-game check, especially dragging the panel out): workbench: one panel slot, blank panel item, loading a design, compiling on take
   (same id if unchanged, which also fixes review #6), error shown in the form,
   free Dupe behind a constant. Fold in review #4 (name lost on quit).
3. DONE (needs an in-game check of the face and presses): floor placement (spec MVP): flat on top of a block, grid facing up, turned by
   the player's facing, fixed once placed. Top edge away from the player. Edges
   and neighbour links in the horizontal plane. Wall and ceiling come later. Fold
   in review #5 (each panel evaluated twice per tick).
4. DONE (needs an in-game look): placed faces always draw the panel's own cells (no debug toggle). IO
   (lamps, buttons, levers) comes first; only one level is drawn, so a nested
   panel shows as a tile with its lamps. Live power (decided): the compiler keeps
   top-level probes for torches and dust wires, read on redraw, fuzz-checked
   against sim/ref.lua.
5. DONE (needs an in-game check: dragging, shift-click, torch arrows, the creative palette, recipes): survival building by drag and drop (spec: Building UI, decided 2026-10-08).
   The grid becomes 64 chest-like slots; parts are real items used up when
   placed and given back when taken out. Loading a compiled panel gives access
   to its parts as items. Dupe is creative-only. Torches pick a base; pick up
   and drop again to pick the next (check that a drop on a different slot is
   enough, since a drop on the same slot may never reach the server). The
   palette is creative-only.
5b. DONE in sim (no UI, by design): nested panel turns. The user is only toying with the idea. Make the
   compiler and reference handle a `turn` field (0-3) on nested panel cells,
   fuzz-tested, but no UI.
6. Speed is one server setting for all panels (spec: Speed). The MVP stays at
   1x; the editor already sets nested speed 1. Add the setting with the
   benchmark work.
## Benchmark (first run 2026-10-08, scripts/bench.sh, headless, 1x speed; superseded, see Optimizations)
Floors of linked stress panels (sim/stress.lua), every panel busy every tick:
| floor | nodes | tick avg | max | settle | commit | faces |
|---|---|---|---|---|---|---|
| busy 1 | 810 | 0.23 ms | 0.42 | 0.08 | 0.02 | 0.12 |
| busy 16 | 13k | 1.3 ms | 1.8 | 0.67 | 0.20 | 0.44 |
| busy 64 | 52k | 9.5 ms | 41 | 4.1 | 0.66 | 4.5 |
| busy 256 | 207k | 20 ms | 63 | 10.6 | 1.9 | 7.9 |
| heavy 1 | 11k | 1.4 ms | 1.9 | 0.80 | 0.37 | 0.20 |
| heavy 16 | 182k | 13 ms | 17 | 8.5 | 2.5 | 2.2 |
Findings:
- Evaluating costs about 50 ns per compiled node per tick, and every node is
  evaluated every tick: a still panel costs as much as a busy one (the spec
  assumes still panels are nearly free). Skipping panels whose inputs and
  registers did not change would fix that.
- Face redraws cost about as much as evaluating when every face changes
  every tick (headless: sending them to players is not measured yet).
- Max ticks spike to 4-6x the average with many panels (likely GC from face
  texture strings).
- The tick is 100 ms. 10 ms of panels per tick is about 200k busy nodes at 1x;
  speed multiplies cost directly.

## Optimizations needed (from the benchmark; rerun scripts/bench.sh after each)
Plan (agreed 2026-10-08), in this order:
- **First the no-regret ones, 1-3 below:** skip still panels, cheaper faces,
  less garbage. They help whatever evaluator we end up with. Start with 1.
- **Activity measured 2026-10-08** (`luajit scripts/bench.lua [lib]`, share of
  nodes whose value changes per step). The user's panels in world test3 are
  very quiet: "game" #48/#74 (~2000 nodes) 0% still, 0.3% avg and 1.3% worst
  when poked (random input flips and presses); every panel over 500 nodes is
  at most 3%. Only clocks and the artificial stress designs are high (busy
  97%, heavy 99.9%). **Decision: event-driven evaluation** (below) is the
  evaluator to build, with full evaluation as the fallback when most of a
  panel changes. Still to confirm on a CPU stand-in (item 6) once it exists.
- Benchmark fix 2026-10-08: the stress clock had a lamp in the middle of its
  output wire, which blocks it, so "busy" was in fact 0.5% active (the table
  below is from that broken design; its cost was full evaluation of still
  logic). Fixed: busy is now 97% active. Rerun on a quiet machine
  (2026-10-08, after the still-panel skip and the clock fix):
  | floor | nodes | tick avg | max | settle | commit | faces |
  |---|---|---|---|---|---|---|
  | busy 1 | 890 | 0.33 ms | 0.71 | 0.11 | 0.10 | 0.12 |
  | busy 16 | 14k | 2.5 ms | 3.7 | 1.4 | 0.49 | 0.58 |
  | busy 64 | 57k | 7.6 ms | 9.5 | 4.4 | 1.4 | 1.7 |
  | busy 256 | 228k | 33 ms | 92 | 20 | 5.4 | 7.2 |
  | idle 256 | 141k | 0.90 ms | 1.2 | 0.68 | 0.06 | 0.12 |
  | heavy 1 | 13k | 2.4 ms | 3.1 | 1.2 | 1.0 | 0.14 |
  | heavy 16 | 202k | 25 ms | 30 | 14 | 8.9 | 1.9 |
  Busy 256 is over budget (15 ms avg, 50 max) and spikes to 3x its average.
- Original plan step, **then measure activity:** add to scripts/bench.lua the share of nodes whose
  value changes per step (try the stress designs and the user's "game" panel
  #48 from world test3 now; the CPU stand-in from item 6 later).
  Dump a world's library for `luajit scripts/bench.lua <file>` (the key is a
  BLOB, hence the cast): `sqlite3 ~/.minetest/worlds/test3/mod_storage.sqlite
  "select hex(value) from entries where modname='redstone_panels' and
  cast(key as text)='library'" | xxd -r -p > lib.lua`
- **Then pick ONE evaluator, from that number:** event-driven evaluation (below)
  if a CPU changes under about 10-20% of its nodes per step, else generated
  Lua code (item 4), or a hybrid. Don't build item 4 before this: the two pull
  in opposite directions and one would be thrown away.

**Event-driven evaluation** (the candidate for big CPUs): keep each node's
value from the last step and, per node, the list of nodes that read it. Each
step, start only from what changed (input bits, presses, registers that
flipped), recompute the earliest marked node in list order, and mark its
readers only if its value changed. Cost then follows how much changes, not
circuit size: a write to one byte of a 256 B RAM touches maybe 100-200 nodes
instead of ~15k. Trade-off: each recomputed node costs maybe 2-4x more
(bookkeeping), so a panel where most nodes change every step gets slower;
fall back to full evaluation when most of a panel changed. Panel-level skip
(item 1) only helps panels whose inputs don't change, and RAM on a busy bus
never qualifies, which is why this matters for the CPU goal (spec:
Performance goals). Fuzz-test it against full evaluation tick for tick.

Items, in order of expected payoff:
1. DONE 2026-10-08: **Skip still panels.** runtime.eval returns its last result
   when inputs, registers and presses are unchanged (sim/runtime.lua); the
   settle loop moved to sim/floor.lua, where a linked group with no instant
   loop between panels starts from last tick's outputs (a group with one
   still starts from all off). Faces skip redraws when nothing ran. Fuzzed in
   tests/floor_spec.lua. Bench: idle 16x16 (256 panels, 140k nodes) 0.95 ms
   per tick, busy floors unchanged. Left: a side that both reads and drives
   redstone still evaluates twice per tick (redstone_mask's quiet eval), and
   the ~3.7 us per still panel left is gather tables and engine calls.
   Original note: runtime.eval runs every node every tick, so an idle
   panel costs as much as a busy one (about 50 ns per node). A panel whose
   inputs equal last tick's, with no press pending and no register changed
   in the last commit, would give the same result: reuse its last outputs,
   lamps and probes, and skip its face check. In world.lua the settle loop
   then only queues panels that are awake or whose neighbour's outputs
   changed. Watch out for: buttons counting down (registers change, so they
   stay awake), speeds above 1x later, and the warm-up. Fuzz-check against
   always evaluating.
2. DONE 2026-10-08 (server side): **Cheaper faces.** thumb.face prepares each
   design's face once (static cells in one string, on/off fragments for live
   cells), so a redraw only joins strings (5 us to 0.5 us offline;
   pixel-for-pixel fuzz test in tests/thumb_spec.lua). Faces with no player
   within FACE_VIEW_RANGE (48) are not redrawn until one comes near; the
   bench and smoke set world.all_faces to draw everything anyway. Bench,
   every face drawn: busy 256 faces 6.3 to 1.3 ms, tick 16 ms avg / 29 max.
   Still open: client texture memory (each distinct face state is a new
   texture the client keeps), not checked in game yet.
   **GC spikes (measured 2026-10-08):** our tick now makes little garbage
   (sim ~0 KB, faces ~15 KB per tick at 64 busy panels; commit garbage is
   mesecons when edge outputs toggle, and save_state every SAVE_TICKS). The
   remaining 30-60 ms spikes are the GC collecting VoxeLibre/engine garbage
   (MBs per tick between our ticks, even with 0 panels: likely mapgen; the
   heap reached 240 MB) while our tick runs. Not ours to fix; a server could
   tune the GC (collectgarbage setpause/setstepmul) if it matters.
   Original note: With every face changing every tick, redraws cost as
   much as the logic (busy 256: 7.9 ms of 20). Each redraw formats 64+ fill
   strings into one ~4 KB texture and sends all of it to every client. Every
   distinct live state is also a new texture the client builds and caches,
   so a busy face may grow client texture memory without limit (check in game
   with /panel_stress busy 8). Ideas: cache each cell's fill fragment and
   only rebuild changed cells; cap redraws per panel (for example at most
   every 2-3 ticks) or skip them when no player is nearby; in the long run,
   a face made of a fixed texture plus a small changing overlay, or a
   palette-colored node instead of a texture string.
3. DONE 2026-10-08: **Less garbage per tick.** runtime.eval reuses one output
   table (callers copy), floor.settle fills each panel's inputs and out in
   place and reuses its queue, faces compare live values in place instead of
   building a key string, and is_valid() replaces get_pos() (a new vector
   per call). Bench, two runs: busy 256 from 33 ms avg / 92 max to 23-26 /
   36-57; heavy 16 from 25 / 30 to 17-21 / 24-28; idle 256 0.61 ms. One run
   had a lone 67 ms spike on busy 64. What garbage is left is mostly face
   texture strings (~4 KB per changed face per tick): item 2.
   Original note: Max ticks spike to 4-6x the average with many
   panels (busy 64: 9.5 ms avg, 41 ms max), most likely GC. Allocated every
   tick per panel: gather()'s inputs table, runtime.eval's out table, P.out
   = {}, the face key and texture strings. Reuse tables per panel instead.
4. **Generate Lua for each compiled net.** eval walks a node list and
   branches on op for every node. Compiling a net once into Lua source
   (one local per node, plain and/or/not expressions) with loadstring should
   let LuaJIT run it several times faster. Check that big nets don't hit
   LuaJIT's limits (200 locals per function: use an array, or split into
   chunks), and keep the plain runtime as the reference in fuzz tests.
5. **Big nets cost more per node.** Offline, "heavy" (11k nodes) takes about
   160 ns per node against about 40 for small nets. Probably wide ORs or
   cache misses; look at fan-in after merge, and flatten nodes into arrays
   (op, args) instead of one table per node.
6. **Budget and limits: see spec "Performance goals".** Add the reference
   builds to the benchmark, above all a CHUNGUS-class CPU stand-in in
   sim/stress.lua (8-bit datapath, 256 B RAM, 4 KB ROM, 32x32 display
   buffer; estimated 40-60k nodes, to be measured). After 1-3, check that
   all reference builds fit 15 ms avg / 50 ms max together, then derive the
   size cap per panel, the default and max speed, and the layer count.
7. **Throttling (spec: over budget, slow down).** Measure each connected
   group's cost per step; when the total would go over budget, give groups
   fewer steps per second, whole groups at a time, and show it (infotext or
   /panel_bench).

## Colored pixels (2026-10-09, needs an in-game look)
Dyed lamps go in the grid as colored lamps; faces mix RGB per spec "Pixels
average" (compile.lua lamp_rgb, thumb.lua lamp_color). /panel_demo has an
RGB Cycle board. Check in game: the colors and the dim "off" look, the
4x3 creative palette, and client texture memory on a busy colored face.

Later: lamps that are on should give off light in the world.
Smaller fixes from the review that are still worth doing: undo. (Tool
selection and right-click erase went away with the item grid; the status line
and torch help are in the form.)

## Glitches
- FIXED 2026-10-08: **"3 bus" (#7 in world test3) flashed in the world.** Cause: two
  edge cells on one side (user's "this flickers", #23) echoed each other's
  redstone input back out of that same side, and the "ignore input while
  driving" rule turned that into a flicker. world.lua now works out a redstone
  side's output as if its own input were off. smoke.lua panel G covers it.
- FIXED 2026-10-08: the same echo through a linked neighbour (user's "locking
  cell" #2, world "main test": two side by side with a torch west of them
  became a clock). The neighbour handed the torch's signal back on another
  edge cell, and the "input off" check only re-evaluated the one panel with
  the neighbour's old outputs. It now settles the whole linked group with
  that input off, then settles it again for real; all masks are worked out
  before any panel commits. smoke.lua panels H1/H2 cover it. Cost: two group
  settles per redstone side that has input and drives, every tick; watch
  this on big floors fed by redstone.

## Code review findings (not fixed yet)
Planned: fix 1-4 and 7-9 now, 5 together with the floor placement work, and for 6 reuse
the existing entry when a design is identical.

1. FIXED: **Panels freeze after you walk away and come back** (world.lua ~350). The tick
   loop deactivates a panel whose block is loaded but not active. The LBM only
   fires on load, so the panel never starts again until the block unloads or
   someone right-clicks it.
2. FIXED: **Self-echo after an output turns off** (world.lua ~309). `set_mask` clears the
   output bit at once, but mesecons sends the "off" back through its action
   queue later. For a tick or more the panel reads its own old signal as input.
3. FIXED: **Saving writes a removed panel's state onto whatever replaced it** (world.lua
   ~279). `deactivate` always calls `save_state`, even when the node is gone or is
   a different panel. `world.activate` also returns the stale old panel for that
   position until the next check.
4. FIXED: **Editor: a typed name is lost when closing with Enter or Esc** (editor.lua
   ~160). The quit branch returns before `fields.name` is saved.
5. FIXED: **Each panel is evaluated twice per tick** (world.lua ~392): once in the fixpoint
   loop, then again in `runtime.step`. Commit the registers from `state.vals`
   instead.
6. FIXED: **Every Compile adds a new permanent library entry** (library.lua ~43), even for
   an identical design, and rewrites the whole library to storage each time.
7. FIXED: The editor's reach limit (`> 10`, editor.lua ~166) should be a named constant.
8. FIXED: `face_texture` hardcodes an `[fill:8x8` base; use `grid.SIZE` (world.lua ~173).
9. FIXED: The bit test `m % 2^(d+1) >= 2^d` is copied three times in world.lua; make a
   `has_bit` helper.
10. **Nested lamp colors are recomputed per instance** (sim/compile.lua ~247).
    `averaged_rgb(K)` runs again for every nested copy of the same child design
    and makes a new {r,g,b} table per lamp. Cache it per design (e.g. on K).
11. **`thumb.LIVE.lamp` is only kept for the smoke test** (sim/thumb.lua ~52).
    Faces color lamps through `thumb.lamp_color`; have smoke.lua call that
    directly and drop `LIVE.lamp`, so the check can't drift from what faces draw.
12. **One closure per lamp on each cached face** (sim/thumb.lua ~134). Faces are
    never freed; store x, y, size, off on the entry and use a shared function in
    `face_texture` instead.
