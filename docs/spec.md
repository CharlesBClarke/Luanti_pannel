# Redstone Panels: Design Spec

Oct 7, 2026 · @Charles

## Overview

A redstone panel is a block holding a small 2D redstone circuit that players design on an 8×8 grid, compile, and then use as a single item. Compiled panels can be placed inside other panels, so complex machines are built from reusable parts instead of sprawling redstone.

Three ideas carry the design:

- **Direction comes from position.** A torch's direction comes from the block it stands on, and panels connect by sitting next to each other. The one thing a player turns is a whole panel: in the world when placing it, and in the grid when nesting it.
- **Compiling never changes behavior.** A compiled panel behaves exactly like the original, tick for tick, glitches included. It only gets smaller and faster.
- **Panels behave the same everywhere.** A panel acts identically in the world, inside another panel, or next to another panel.

## Grid and edges (8×8)

Each panel is an 8×8 grid of buildable cells. There are no pins: every cell on the edge of the grid connects to the outside, one bit per cell.

- **The edge is the interface.** Whatever sits in an edge cell connects to the single bit just outside it. Two panels side by side connect edge to edge, matched cell for cell, so a wall of panels reads like one continuous grid.
- **Every connection point is one bit.** No point ever carries more than one bit. The only place many bits move at once is where two panels touch directly, where all 8 cells of a side meet their neighbor's 8 cells.
- **Plain redstone sees the OR, drives all.** Dust along an edge touches several outside bits at once, so it reads their OR and powers them together. Edge dust is either a deliberate fan-out or something to avoid.
- **A side facing world redstone is one bit.** In the world, a panel side next to plain redstone reads one signal into all 8 edge cells and drives it with their OR. Since that side is a single wire, its output never comes from its own input, even through two different edge cells.
- **4 clean bits with dust, 8 with care.** Because neighbouring edge dust merges, dust alone gives at most 4 independent bits per side (every other cell). Blocks, torches, and quartz don't merge, so a careful design gets all 8.
- **Corners touch two sides.** A corner cell connects to both edges next to it, which can carry a signal around a corner.
- **No self-echo.** An output never counts its own value fed back in, so a panel can't switch its own output off by reading it.

## Components

Six items make up a panel, and none of them is ever rotated by the player. Every direction comes from where things sit relative to each other.

| Item | Powered by | Powers | Notes |
| --- | --- | --- | --- |
| Dust | Anything touching it | Everything it touches | Instant. Touching dust cells form one wire. |
| Block | Dust, quartz, torches not on it, the edge, a neighbour panel's side | Nothing directly | Exists so torches have something to stand on and read. |
| Torch | The block or bulb it stands on | Its other three sides: dust, quartz, blocks, the edge, a neighbour panel's side | Off while its block is powered, 1 tick later. Must stand on a block or bulb; falls off if that is removed. |
| Quartz | Dust or torches at its sides | Every other quartz in its row, column, and the same spot in other layers | Wireless. Left/right signals travel the row; top/bottom signals travel the column; the two never mix. |
| Copper bulb | Anything touching it, like a block | Nothing directly | Flips on or off each time its input turns on. A torch standing on it reads it. Memory with no rotation. |
| Lamp | Anything touching it | Nothing | Lights when powered. Display only; acts as a pixel on the block face. |

**Torch placement.** When a torch touches more than one block or bulb, tapping it again moves it to the next one. Dropping it near a cell's edge picks the block on that side.

**Wireless quartz rule.** Every quartz in a row shares one horizontal link, and every quartz in a column shares one vertical link. Placing a third quartz in a row joins it to that row's link, by design.

**Considered and left out.** Edge pins (the edge itself is now the interface), the 3-bit bus (replaced by 8 one-bit edge cells per side), directional torches, rotating parts (only whole nested panels turn), crossover dust shapes, a separate via item, repeaters (two torches on blocks already give a one-way, non-inverting delay), observers (they need a facing), comparators and signal strength (panels are on/off only), and pistons (layouts must stay fixed).

## Timing

Torches are the only thing that takes time: each one changes 1 tick after its block does. Everything else settles instantly within the tick.

- **Instant:** dust, quartz links, blocks, lamps, and signals passing straight through a placed panel.
- **1 tick:** a torch. A chain of torches is one tick per torch.
- **Copper bulb:** flips 1 tick after its input turns on, and remembers which way it flipped.
- **Feedback loops are safe.** Any loop must pass through a torch, so it has at least 1 tick of delay and can't become a paradox. A torch reading its own block is a clock that flips every tick.
- **Tick rate.** In-game timing should match Minecraft redstone: 10 ticks per second (one redstone tick is 0.1 s).
- **Glitches are real.** When two paths into a gate have different lengths, the output can flicker for a tick or two before settling. Vanilla redstone does the same, and compiling preserves it. Designers remove glitches in the circuit itself, by balancing path lengths.

## Nesting and layering

Panels combine in two ways: nesting places a compiled panel inside one cell of another, and layering stacks panels front-to-back in the same block.

**Nesting**

- A nested panel connects only through its four sides, 8 one-bit edge cells per side, by the same edge rules as any panel. Its insides are a sealed black box.
- Quartz never reaches into a nested panel. Inside, its own quartz still works across its own rows, columns, and layers.
- Each placed copy keeps its own state (torches, bulbs), so memory doesn't leak between copies.
- A panel can't contain itself, directly or through other panels. Only panels compiled earlier can be placed, which rules this out automatically.
- Editing a saved panel works on a copy, compiled under a new name, so panels that already use the original keep working.

**Layering**

- A block holds 8 layers of 8×8 cells, so 512 cells of logic, all compiling into one block. Panels are thin: 8 layers stack to one cube.
- Layers share the face. A nested panel's lamps still fuse into its cell, so the face stays a single 8×8 (64-pixel) tile.
- Edges match layer by layer. Layer 1's edge connects to the neighbour block's layer 1, and so on, 8 bits per layer with no sharing, so a side carries 8 bits × 8 layers = 64 independent bits to the next block.
- Quartz is the only wiring between layers (a face press is a separate, shared input; see Face IO). Quartz at the same cell position in adjacent layers shares its links, and connects straight through the whole stack at that position, the same way a row link spans a row.
- Because of that, two independent quartz links can't sit at the same position in different layers; offset one by a cell.
- Max depth bandwidth: quartz act like non-attacking rooks (no two sharing a row or column), so up to 8 per layer, 2 bits each (row link + column link) = 16 bits through the depth of a block.
- A wall of blocks tiles in 3D: layer 1 of every block forms one continuous sheet, layer 2 another, with quartz stitching between sheets where a design needs it.
- A layer stack compiles as a 3D grid: depth is just a third axis for grouping quartz, with no new rules and cost linear in the number of layers.

## Face IO

Buttons, levers, and lamps form the panel's face: what a player sees and presses on the block in the world. Every face element shows at full cell size, however deeply it is nested.

- **IO rises to the parent cell.** A nested panel's buttons, levers, and lamps all appear in the one parent cell it occupies, and this repeats up to the block face.
- **Everything in one cell fuses.** All IO landing in the same cell, from any layer or nested panel, combines into one model: lamp plus button is a lit button, lamp plus lever a lit switch.
- **One press per cell.** Pressing a cell triggers every input at that position. A lever flips its state; a button turns on for a few ticks, then off. A button and lever in the same cell both react; the editor does not forbid it.
- **Bounded inputs.** A board has at most 64 press inputs, one per cell, and a nested panel needs only one: "my cell was pressed".
- **Pixels average.** A cell's brightness per color is the fraction of that color's lamps that are lit, averaged up through nesting. A color with no lamps contributes nothing. Red, green, and blue lamps make RGB pixels.
- **Logic is untouched.** Lamps only produce light, and presses are ordinary inputs, so face IO never changes how wiring or the compiler works.

## Speed

All panels run at the same speed, set by one server setting. It starts at 1× (10 steps per second, matching redstone) and is a slider: once benchmarks show what panels really cost, admins raise it as far as their server allows. There is no per-panel speed for now.

- **One speed, one clock.** A panel at N× runs N internal steps per game tick. Panels touching edge to edge, and panels nested inside panels, all step together, so a wall of panels behaves like one big panel and nesting never changes timing.
- **The world boundary is once per tick.** Plain redstone and the face (lamps, presses) are read and shown once per game tick, so vanilla redstone timing is untouched.
- **Effect on delay.** At 4×, a chain of 4 torches takes 1 game tick. Anything through a torch takes at least one step; plain wiring stays instant.
- **Cost.** Runtime cost is roughly active gates × speed × running panels; see the performance budget.
- **Maybe later: speed from material.** At most, a panel's speed could come from the material it is made of. The compiler already supports a nested panel running at its own speed (it unrolls the extra steps), so this stays possible without new runtime code.

## Compiler

The compiler turns a panel into a small network of torches and ORs that behaves exactly like the original, tick for tick. That works because torches are the only delays: dust, quartz, blocks, and pass-through panel wiring are all instant ORs.

**Steps, in order**

1. **Group wires.** Touching dust, plus quartz rows, columns, and layers, become single wires. Blocks become ORs of what touches them; a torch reads its block. A copper bulb becomes a few gates plus one stored tick of its input.
2. **Inline sub-panels.** Each nested panel's already-compiled network is copied in. Sped-up panels are unrolled first.
3. **Collapse instant loops.** Wires and panels that feed each other instantly all carry the same value, so each loop becomes one node.
4. **Simulate power-on.** The full network runs 80 ticks from its starting state, and that snapshot becomes the compiled panel's starting state, so clocks don't come out of phase.
5. **Simplify.**
   - Drop anything that can't reach an edge output or a lamp.
   - Fold constants, like a torch with nothing powering it.
   - Turn torch chains into delayed signals: two torches in a row become "the same signal, 2 ticks ago", stored as a short history instead of two gates.
   - Merge equivalent nodes, comparing structure and power-on history, which also merges self-feeding clocks safely.
6. **Store the result.** Gates, delays, and the power-on snapshot.

**Results from testing**

- A 393,624-torch test panel built from nested clocks that never reach an edge compiled to plain wiring: 0 gates, 10,000 ticks in about 20 ms.
- 4,681 clocks sharing one wire collapsed into 2 gates.
- Thousands of randomly generated nested panels (with blocks, quartz, bulbs, lamps, and mixed speeds) matched a plain step-by-step simulation on every tick, including every lamp.

## World and gameplay

In the world, a panel is a block with one face showing the grid, built as a Luanti mod for the VoxeLibre game. It lies flat or stands upright depending on where it is placed.

- **Orientation set at placement.** Where the player clicks decides how the panel sits, the way placing a trapdoor does. It is fixed once placed: there is no flipping or rotating afterwards. Nested panels turn the same way inside the grid (see Building UI); nothing else is ever rotated.
  - **Flat on the floor** (placed on top of a block): the grid faces up. Its top edge is the side away from the player, its bottom edge the side toward them, and left and right are as the player sees them. The panel reads like a sheet of floor redstone.
  - **Flat on a ceiling** (placed on the underside of a block): the grid faces down, laid out as seen by a player looking up at it.
  - **Upright on a wall** (placed on the side of a block): the grid faces the player like a picture frame. Its top edge connects above, its bottom edge below.
- **Edges connect in the grid's plane.** The four sides connect to the four neighbouring blocks in that plane. A floor of flat panels becomes one large circuit; a wall of upright panels becomes one large circuit and one large screen: a 2×2 wall is a 16×16 display.
- **Neighbouring panels** connect edge to edge when their grids face the same way, cell for cell along the shared edge.
- **Building UI.** Designing is Minecraft-style: the grid is 64 slots, like a chest, and players drag parts into it from their own inventory and drag them off to remove them. A free palette of parts is for creative mode only.
  - **Parts are used up** when placed in the grid; taking one out gives it back. A compiled panel holds its parts, so loading it into the workbench gives access to them as real items.
  - **Torches** pick a block or bulb next to them to stand on; picking a torch up and dropping it again picks the next one.
  - **Nested panels may turn** (an idea, not decided) in 90° steps, like panels turned in the world. Turning a nested panel turns its sides: its north edge can face any side of the parent cell, bits in order along the edge. The compiler supports it (a `turn` of 0–3 quarter turns clockwise on the nested cell); there is no UI for it yet.
- **Workbench loads a panel.** The workbench has one panel slot and holds no design of its own. A blank panel opens an empty grid; a compiled panel loads its design, so any panel can be opened to see how it works. Taking the panel out compiles it: unchanged, it comes back as the same panel; edited, it becomes a new library entry and replaces the item in the slot, while panels already using the old design keep working. If compiling fails, the panel stays in the slot and the error shows in the workbench. A **Dupe** button copies the panel in the slot, so keeping the original before editing means duping it first. Dupe is creative-only. The name carries over and can be edited.
- **Every panel shows what it is.** A compiled panel item shows a thumbnail of its 8×8 layout (one pixel per cell, colored by part) as its inventory image, and its tooltip gives the name, id, gate count, and which edges it uses. A nested panel on a workbench grid shows the same thumbnail and tooltip.
- **The face shows the circuit.** A placed panel's face always draws its own cells (dust, torches, blocks, and so on), not just its lamps. Two rules:
  - **IO comes first.** Lamps always show their real state, and buttons and levers stay pressable. The circuit drawing fills the cells that have no IO and never hides or blocks it.
  - **Live power.** Dust, quartz, torches, blocks, bulbs, buttons, and levers show whether they are on. The compiler keeps a probe for each of the panel's own parts (at most 64 per panel), so these few nodes are not merged away; everything inside nested panels still simplifies fully, since nesting drops the probes. The face redraws only when something on it changes, and fuzz tests check the probes against the step-by-step simulation.
  - **One level only.** Only the panel's own cells are drawn. A nested panel shows as a plain panel tile with its lamps on top; its insides are never drawn. Item thumbnails follow the same rule.
- **Production with molds.** A finished panel, flipped, is pressed into wet clay to make a mold. Each indent accepts only the right item, so a hopper can fill it without mistakes. Torch indents are arrow-shaped so torches go in facing the right way, and nested panels need the exact compiled panel as the item.
- **Clay states.** Wet clay could be single-use and dry out if not filled in time, while fired terracotta molds are reusable but crack after a set number of uses.
- **Self-balancing cost.** Crafting costs follow the original design (every dust and torch), while runtime cost follows the simplified one. Bloated designs are expensive to make even when they run for free.
- **Hoppers.** VoxeLibre already has hoppers, so a mold block that accepts hopper input fits existing automation.

## MVP

The first version is the smallest thing that runs in VoxeLibre and tells us what a block really costs. Its main job is to produce the measurements the performance budget needs.

**In scope**

- **One-layer 8×8 panel node** with an in-game editor (a formspec grid) for all six parts: dust, torch, block, quartz, bulb, and lamp. The engine already handles all six, so dropping any would save little.
- **Compile to an item** that can be placed in the world and nested inside another panel. Nesting is the core idea, so it has to be in from the start.
- **Workbench with thumbnails:** the load-edit-take workbench, with Dupe, and thumbnails and tooltips on panel items and nested cells. Drawing the circuit on placed faces comes after this.
- **Edge connections** between adjacent panels, one bit per edge cell.
- **Floor placement only:** a panel lies flat on top of a block, grid facing up, turned by the direction the player faces. Wall and ceiling placement come later.
- **Basic face IO:** one button or lever per cell, and lamps shown as plain on/off on the face. A button stays on for 10 ticks (1 s) after a press.
- **Fixed 1× speed** at 10 ticks per second, matching redstone timing.
- **A benchmark command** that reports server time per tick and active gate count, so the provisional numbers can be replaced with measured ones.

**Out of scope for now**

Wall and ceiling placement, layers, speeds above 1×, coloured and averaged pixels, clay molds and crafting costs, and copy protection. Each of these sits on top of the core without changing it, and their limits should come from the benchmark anyway.

**Main work and how it is checked**

The main task is building the compiler and runtime in Lua, using the JavaScript prototype as a starting point rather than a reference to match exactly. Where they differ, this spec decides. Fuzz tests in Lua compare each compiled panel against a plain step-by-step simulation tick by tick, so the rule that compiling never changes behaviour holds in the mod.

**VoxeLibre redstone (decided: in the MVP)**

Panels connect to VoxeLibre's existing redstone, so its levers and wires can drive a panel's edges and a panel can drive its lamps and wires. This makes panels useful right away; the cost is a second signal system whose timing must stay consistent with the panels' own.

## Open questions

These are deliberately left until panels are running in Luanti and can be judged in play.

**Performance budget (provisional numbers).** The widths and counts above — 64-bit edges, 8 layers, up to 64× speed — were chosen on paper, not measured. They should instead fall out of one budget: how much server time a single block may use per tick. Until a real Luanti node is benchmarked with a heavy, realistic build, treat these as targets, not commitments. The architecture degrades cleanly if the budget is tight: fewer layers, a cap on active gates per block, or a lower top speed all scale the cost down without changing how anything works, since everything compiles to torches and ORs and dead logic is dropped. The cost that matters is active gates × speed × running blocks, not wiring width; a still panel is nearly free, a sped-up clock farm is not. Measure before committing.

- [ ] Layer count: the target is 8 per block (an 8×8×8 cube of 512 cells), to be confirmed by the performance budget.
- [ ] Does the block's back face expose its quartz depth links so stacks of blocks chain front-to-back, or does depth stay sealed inside each block?
- [ ] How many brightness levels per color: Luanti node colors usually come from a palette (often 256 entries), so pixels will need rounding, e.g. 4 levels per channel for 64 colors.
- [ ] Default and maximum for the speed setting, and a per-area budget, once benchmarked.
- [ ] Can players copy any panel they hold by stamping it, or can designs be signed or protected?
- [ ] Should two neighbouring panels in the same plane but turned differently (e.g. one rotated 90° on the floor) connect, and if so in which bit order?
- [ ] Should a panel's speed come from the material it is made of, or stay one setting for all?
