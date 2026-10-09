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
