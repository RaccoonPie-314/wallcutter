# WallCutter — SketchUp Plugin Design

Date: 2026-10-11
Status: approved in brainstorming dialogue
Target: personal / in-house tool, current SketchUp (2021+), macOS. Packaged as an unsigned `.rbz`.

## Summary

One cutting engine, two thin entry points:

1. **Smart Cutout Generator** — a `Sketchup::Tool`: pick a wall face, set preset + dimensions in an
   HtmlDialog, preview the opening outline live, press Enter to cut.
2. **Component Drilling** — a menu/selection command: select exactly one component instance that
   touches a wall; the tool auto-detects the wall axis from the component's bounding box and drills
   a through-hole sized to that bbox.

Both features only ever call `CutEngine.cut(...)`. There is no second cutting path.

## Scope

In: rectangular openings only; cut along the picked face's normal through whatever geometry lies
behind it; works when target geometry lives inside groups/components (engine enters the parent
context).

Out (add only when actually asked): frames/jambs/sills, curved/arch/circular profiles, boolean
difference against arbitrary component geometry, preset editor/persistence, batch multi-component
drill, Windows-specific concerns, Extension Warehouse packaging.

## File layout

```
wall_cutter/
├── src/
│   ├── wall_cutter.rb   # loader: menu registration, requires, drill selection-command (~30 lines)
│   ├── cut_engine.rb    # the ONLY geometry code: prism builder + Entities#clip wrapper + PRESETS
│   ├── cutout_tool.rb   # Feature 1 tool + inline-HTML HtmlDialog + view.draw preview
│   └── selftest.rb      # in-SketchUp assert script (see Testing)
└── wall_cutter.rbz      # zip of src/ renamed per SketchUp rbz rules
```

Menu: `Extensions > WallCutter > Smart Cutout…` / `> Drill Selected Component`. The drill command
is also added to the right-click context menu for component selections.

## CutEngine

Single public entry:

```ruby
CutEngine.cut(origin, normal_into_wall, u, v, width, height, depth)
```

- `origin` — a point on the wall face, always in **model/world coordinates**; the engine
  internally converts it into the face's parent context (see Context handling).
- `normal_into_wall` — unit vector pointing into the wall, opposite the viewer/camera side.
- `u`, `v` — in-plane axes: `u` horizontal along the wall, `v` "up the wall".
- `width`, `height` — opening size, centered on `origin` unless callers pass offsets baked into
  `origin` (both current callers do: they compute the positioned origin themselves).
- `depth` — prism penetration distance beyond the face.

Algorithm:

1. `model.start_operation("WallCutter cut", true)`.
2. Build a temporary prism group in the **face's parent entities context**:
   8 corners from `origin ± w/2·u ± h/2·v`, extruded along `normal_into_wall` by `depth`,
   starting the prism `1″` proud of the face (outside) so the clip never starts coplanar with it.
3. `entities.clip([transform], [prism], :difference, false)` on that context.
4. Erase the prism.
5. **No-op guard**: if the context's `entities.length` is unchanged, `abort_operation` and report
   "cut removed nothing — set depth manually". (Prevents silent failed cuts / dirty undo history.)
6. `commit_operation`.

`ensure` block: any exception → `abort_operation` + erase prism. The prism cannot survive a failed
cut.

`PRESETS` — plain hash in this file, edited by hand:

```ruby
PRESETS = {
  'Window'  => { width: 36", height: 48", sill: 36" },
  'Door'    => { width: 32", height: 80", sill: 0" },
  'Opening' => { width: 48", height: 48", sill: 24" },
}
```

### Context handling

The cut is executed in `face.parent.entities` (the collection that owns the face — the model's
root entities for loose geometry, or the component/group definition when the wall is contained),
with the prism built directly in definition-local coordinates when the face lives in a
component/group (no transform needed for single-level groups; one accumulated
`instance.transformation` step per nesting level). Cutting top-level geometry and cutting inside a
wall group therefore take the same engine path.

## Feature 1 — Smart Cutout tool (`cutout_tool.rb`)

State machine (standard Tool interface):

- `onMouseMove` (no face picked yet): `model.raytest` from cursor → candidate wall face; store
  face + `inputPoint`.
- Dialog fields change → recompute geometry → `view.invalidate` (preview redraw only).
- `onReturn` / dialog "Cut" button → commit: one `CutEngine.cut` call → keep tool active for the
  next opening.
- `Escape` → deactivate cleanly; preview leaves no entities (it is `view.draw` only).

Axis derivation from the picked face:
- `v` = world-Z projected onto the face plane; degenerate when `face.normal ∥ Z` (horizontal face)
  → fall back to the face's longest outer-loop edge as `u`.
- `u = normal × v`.

Positioning: `left_offset` and `sill` measured from the face bounding corners in (u, v). Default
horizontally centered; sill from the dialog/preset. Validation: opening must fit inside the face's
u/v extent — on overflow, refuse commit and show status "opening exceeds wall (available W × H)".
No silent clamping.

Depth: `model.raytest` from opening center along `-normal_into_wall`; distance to first hit behind
the face + `1″` clearance (the first rear hit is the back side of the deepest layer — this is what
makes layered walls cut "through" for free). Manual depth field in the dialog overrides.

HtmlDialog: inline HTML string in the tool file. Fields: preset dropdown, width, height, sill,
left offset, depth (auto placeholder shows computed value), Cut button. Ruby↔JS via
`add_action_callback` + `execute_script`; one `set_params(json)` message into the page for updates.

## Feature 2 — Drill command (loader)

Preconditions: selection is exactly 1 ComponentInstance (else message, stop).

Axis auto-detection:
1. Instance world bbox (`instance.bounds` transformed).
2. Candidate axes = instance's local X/Y/Z transformed to world. From bbox center, `raytest` both
   directions per axis; record hit distances.
3. Drill axis = the axis whose two hits straddle the bbox with each gap ≤ `half-extent along that
   axis + 6″` — i.e. the component is sandwiched by geometry on both sides along that axis.
4. No qualifying axis → message "place the component so it touches a wall", stop. No fallback
   picker in v1.
5. Cutter = bbox expanded `1/32″` on the two in-plane axes (avoids coincident-face artifacts),
   extended along the drill axis from just outside the front hit to just past the back hit.
6. One `CutEngine.cut(...)` call with those parameters.

Known limit, documented in-code with a comment: `raytest` sees the topmost surface, so a component
buried inside another container may detect "the sandwich that's actually there" rather than a
conceptual wall. Escape hatch for a wrong sandwich is Feature 1's explicit face pick, not new
machinery.

## Failure modes

| Case | Behavior |
|---|---|
| Click misses a face | Status text "pick a wall face"; no preview; no error dialog. |
| Opening larger than face | Refuse commit with available size in the message. No clamping. |
| Clip no-op | Geometry-count guard → `abort_operation` + "set depth manually". |
| Exception mid-cut | `ensure` → abort + prism erased. |
| Multi-select in drill | "select exactly one component". |

## Testing

`selftest.rb`, run from Ruby Console (`load`), assert-based printout, no framework:

1. New model → draw 10′ × 9′ × 1′ box wall via API → `CutEngine.cut` centered 36″ × 48″
   through-depth.
2. Assert front-face count increased (a hole splits the skin: ≥2 faces where 1 existed).
3. Assert a straight-through `raytest` at opening center exits the far side hitting nothing within
   wall depth.
4. Drill path: drop a cube instance half-into the wall, run axis detection + cut, same asserts.
5. Prints `PASS` / `FAIL: <check>` per assertion.

Manual/viewport testing remains the primary loop for UI behavior (preview, dialog, undo).

## Success criteria

- Cutting a loose-geometry box wall, a grouped wall, and a two-layer wall each take one action
  each and are undone with a single Ctrl-Z.
- Self-test passes on current SketchUp release.
- Total implementation ≈ 400 lines of Ruby across 4 files.
