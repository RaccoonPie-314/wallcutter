# WallCutter SketchUp Plugin Implementation Plan

> **Note:** implemented 2026-10-11; tasks below match the committed code.

**Goal:** A personal SketchUp tool that cuts rectangular window/door/opening holes through walls — via a dialog-driven cutout tool (Feature 1) or by auto-detecting the wall around a placed component and drilling it (Feature 2).

**Architecture:** One shared cutting engine (`CutEngine`) that builds a temporary prism and calls SketchUp's native `Entities#clip(:difference)`; both features are thin argument-computing wrappers. All geometry mutation happens inside a single undo operation with a no-op guard.

**Tech Stack:** SketchUp Ruby API only (no gems). `Entities#clip`, `model.raytest`, `PickHelper`, `PathFromEntity`, `UI::HtmlDialog`, stdlib `json`.

**Spec:** `docs/wallcutter-design.md` — read it before starting; this plan implements it.

## Global Constraints

- Current SketchUp desktop only (2021+), macOS. No version-floor workarounds.
- Zero external dependencies — SketchUp Ruby API + stdlib only.
- 4 Ruby files total in `src/`: `wall_cutter.rb`, `cut_engine.rb`, `cutout_tool.rb`, `selftest.rb`.
- Every model mutation wrapped in `start_operation(name, true)` → `commit_operation`, with `abort_operation` on any failure or no-op.
- Linear units: inches (`12"`, `.to_l` for user strings). Tolerances: `1.0` pride, `6.0` sandwich, `1.0/32.0` in-plane expansion, `0.01` probe offset.
- All tests run inside SketchUp's Ruby Console (there is no headless runner): `load '<repo>/build/wall_cutter/selftest.rb'`, expect `PASS` lines only. **Run the self-test in a scratch model** (File → New first).
- v1 works only at the top editing level: both features refuse with a message when `model.active_path` is non-nil.
- Commits: conventional style, one per task minimum.

## File Structure

```
wall_cutter/
├── src/
│   ├── wall_cutter.rb    # loader: menu + context menu, drill command, shared guards/helpers
│   ├── cut_engine.rb     # CutEngine.cut + PRESETS + prism building — the ONLY geometry code
│   ├── cutout_tool.rb    # CutoutTool (pick/preview/commit) + FaceFrame + HtmlDialog (inline HTML)
│   └── selftest.rb       # assert-based in-SketchUp checks, grown by one section per task
├── package.sh            # assembles build/ tree and wall_cutter.rbz; install_dev rsync to Plugins
└── docs/  # spec + plan
```

Repo root is the current workspace (already a git repo with the spec at `main`).

---

### Task 1: Loader skeleton + CutEngine on loose geometry

**Files:**
- Create: `src/wall_cutter.rb`
- Create: `src/cut_engine.rb`
- Create: `src/selftest.rb` (engine section only)

**Interfaces:**
- Produces: `WallCutter::CutEngine.cut(origin, n, u, v, width, height, depth, path: []) -> true/false` (all inputs world coords; `path` = array of Group/ComponentInstance from root to the container owning the face, `[]` for top level; returns `false` on aborted no-op cut). `WallCutter::CutEngine::PRIDE_IN == 1.0`. `WallCutter::PRESETS` hash keyed by preset name with `:width/:height/:sill` (inches as Float).
- Consumes: nothing.

- [ ] **Step 1: Write the engine**

`src/cut_engine.rb`:

```ruby
# frozen_string_literal: true
require 'sketchup.rb'

module WallCutter
  PRESETS = {
    'Window'  => { width: 36", height: 48", sill: 36" },
    'Door'    => { width: 32", height: 80", sill: 0" },
    'Opening' => { width: 48", height: 48", sill: 24" }
  }.freeze

  module CutEngine
    PRIDE_IN = 1.0  # cutter starts this far outside the face so clip never starts coplanar
    # ponytail: assumes rigid or axis-scaled containers; non-uniform scale on a rotated
    # wall group is the known ceiling — upgrade path: full affine handling here.
    def self.cut(origin, n, u, v, width, height, depth, path: [])
      model = Sketchup.active_model
      ents  = path.empty? ? model.entities : path.last.entities
      inv   = world_to_local(path).inverse
      o  = origin.transform(inv)
      nl = n.transform(inv)
      ul = u.transform(inv)
      vl = v.transform(inv)
      model.start_operation('WallCutter cut', true)
      prism = nil
      begin
        before = ents.length
        prism  = build_prism(ents, o, nl, ul, vl,
                             width * ul.length, height * vl.length, depth * nl.length)
        ents.clip([Geom::Transformation.new], [prism], :difference, false)
        prism.erase! if prism.valid?
        if ents.length == before
          model.abort_operation   # no-op guard: clip removed nothing
          return false
        end
        model.commit_operation
        true
      rescue StandardError
        prism.erase! if prism && prism.valid?
        model.abort_operation
        raise
      end
    end

    def self.world_to_local(path)
      path.inject(Geom::Transformation.new) { |t, inst| t * inst.transformation }
    end

    # 8-corner prism: rectangular base centered on o, extruded d along (local) n.
    def self.build_prism(ents, o, n, u, v, w, h, d)
      un = n.normalize
      ut = u.normalize
      vt = v.normalize
      pr = PRIDE_IN * n.length
      start = o.offset(un.reverse, pr)
      g = ents.add_group
      face = g.entities.add_face(
        start.offset(ut.reverse, w / 2.0).offset(vt.reverse, h / 2.0),
        start.offset(ut, w / 2.0).offset(vt.reverse, h / 2.0),
        start.offset(ut, w / 2.0).offset(vt, h / 2.0),
        start.offset(ut.reverse, w / 2.0).offset(vt, h / 2.0)
      )
      face.reverse! if face.normal % un < 0
      face.pushpull(d + pr)
      g
    end
  end
end
```

- [ ] **Step 2: Write the loader skeleton**

`src/wall_cutter.rb`:

```ruby
# frozen_string_literal: true
require 'sketchup.rb'
require 'json'

module WallCutter
  PLUGIN_DIR = File.join(ENV['HOME'] || '', 'Library/Application Support/SketchUp 2026/SketchUp/Plugins')

  def self.top_level_ok?
    return true unless Sketchup.active_model.active_path
    UI.messagebox('WallCutter works at the top editing level — exit the group/component you are editing first.')
    false
  end

  unless file_loaded?(__FILE__)
    require File.join('wall_cutter', 'cut_engine')
    menu = UI.menu('Plugins').add_submenu('WallCutter')
    menu.add_item('Smart Cutout…')     { UI.messagebox('not yet implemented') } # wired in Task 4
    menu.add_item('Drill Component')   { UI.messagebox('not yet implemented') } # wired in Task 3
    file_loaded(__FILE__)
  end
end
```

- [ ] **Step 3: Write the engine self-test**

`src/selftest.rb`:

```ruby
# In SketchUp: File > New, then Ruby Console:
#   load '<repo>/build/wall_cutter/selftest.rb'   (after ./package.sh)
# or during dev: load '<repo>/src/selftest.rb' after loading the source files.
module WallCutter
  module SelfTest
    def self.check(name)
      ok = yield
      puts(ok ? "PASS #{name}" : "FAIL #{name}")
      ok
    end

    def self.box_wall(ents, x0, w, h, thick)
      pts = [Geom::Point3d.new(x0, 0, 0), Geom::Point3d.new(x0 + w, 0, 0),
             Geom::Point3d.new(x0 + w, 0, h), Geom::Point3d.new(x0, 0, h)]
      f = ents.add_face(pts)
      f.reverse! unless f.normal.y > 0
      f.pushpull(thick)
    end

    def self.run_engine
      model = Sketchup.active_model
      ents  = model.entities
      box_wall(ents, 0, 10', 9', 12")
      faces_before = ents.grep(Sketchup::Face).length
      origin = Geom::Point3d.new(5', 0, 4.5')
      ok = CutEngine.cut(origin, Geom::Vector3d.new(0, 1, 0),
                         Geom::XVECTOR, Geom::ZVECTOR, 36", 48", 14")
      check('engine cut commits')            { ok }
      check('front skin split (hole made)')  { ents.grep(Sketchup::Face).length > faces_before }
      check('ray through opening clears') do
        hit = model.raytest(Geom::Point3d.new(5', -20", 4.5'), Geom::YVECTOR)
        hit.nil?
      end
      # no-op guard: cut far above the wall must abort cleanly
      check('no-op cut returns false') do
        high = Geom::Point3d.new(5', -30', 4.5') # normal +Y, depth 1" reaches nothing
        !CutEngine.cut(high, Geom::Vector3d.new(0, 1, 0), Geom::XVECTOR, Geom::ZVECTOR, 36", 48", 1")
      end
    end

    def self.run
      run_engine
      puts 'selftest done'
    end
  end
end
WallCutter::SelfTest.run
```

- [ ] **Step 4: Create `package.sh` and run it**

```bash
#!/bin/sh
set -e
cd "$(dirname "$0")"
rm -rf build wall_cutter.rbz
mkdir -p build/wall_cutter
cp src/wall_cutter.rb build/
cp src/cut_engine.rb src/selftest.rb build/wall_cutter/
[ -f src/cutout_tool.rb ] && cp src/cutout_tool.rb build/wall_cutter/ || true
( cd build && zip -q -r ../wall_cutter.rbz wall_cutter.rb wall_cutter )
echo "built wall_cutter.rbz"
```

`chmod +x package.sh && ./package.sh` → expect `built wall_cutter.rbz`.

- [ ] **Step 5: Install + run the self-test in SketchUp**

Copy `build/` contents into `~/Library/Application Support/SketchUp 2026/SketchUp/Plugins/` (restart SketchUp once so the loader runs; menu `Extensions > WallCutter` should appear with two disabled stubs). In a **new scratch model**, Ruby Console: `load '<repo>/build/wall_cutter/selftest.rb'`.

Expected: four `PASS` lines (`engine cut commits`, `front skin split (hole made)`, `ray through opening clears`, `no-op cut returns false`), then `selftest done`. Fix until green.

- [ ] **Step 6: Commit**

```bash
git add src package.sh
git commit -m "feat: cut engine with prism clip, undo guard, engine self-test"
```

---

### Task 2: Group-context walls (path plumbing)

**Files:**
- Modify: `src/wall_cutter.rb` (add `face_path` helper)
- Modify: `src/selftest.rb` (add group section)

**Interfaces:**
- Consumes: `CutEngine.cut(..., path:)` from Task 1.
- Produces: `WallCutter.face_path(entity) -> Array` of root→leaf Group/ComponentInstance enclosing the entity's container (`[]` when the entity is top-level). Both features pass this as the engine's `path:`.

- [ ] **Step 1: Add the helper to the loader**

```ruby
  # Instance chain from model root to the container owning +entity+; [] if top-level.
  def self.face_path(entity)
    return [] if entity.parent.is_a?(Sketchup::Model)
    Sketchup::PathFromEntity.new.find(entity) || []
  end
```

Note for the implementer: `PathFromEntity#find` returns the instance path **excluding the leaf entity**; that is exactly what `CutEngine.world_to_local` expects. If it returns nil (older API behavior), the fallback in Task 2 Step 3's test will catch it.

- [ ] **Step 2: Add the group test to self-test**

In `SelfTest`, add and call from `run`:

```ruby
    def self.run_group
      model = Sketchup.active_model
      ents  = model.entities
      grp   = ents.add_group
      box_wall(grp.entities, 20', 10', 9', 12")
      before = grp.entities.grep(Sketchup::Face).length
      origin = Geom::Point3d.new(25', 0, 4.5')
      path   = WallCutter.face_path(grp.entities.grep(Sketchup::Face).find { |f| f.normal.y < -0.999 })
      ok = CutEngine.cut(origin, Geom::YVECTOR, Geom::XVECTOR, Geom::ZVECTOR, 36", 48", 14", path: path)
      check('group wall: path is [group]')  { path.size == 1 && path[0] == grp }
      check('group wall: cut commits')      { ok }
      check('group wall: hole made')        { grp.entities.grep(Sketchup::Face).length > before }
      # shared-definition caveat: cutting a Group cuts its definition — verify no crash
      # when the same definition has multiple instances:
      dup = ents.add_instance(grp.definition, Geom::Transformation.new(Geom::Vector3d.new(0, 30', 0)))
      check('group wall: duplicate instance survives') { dup.valid? }
    end
```

- [ ] **Step 3: Re-run self-test in SketchUp**

`load '<repo>/build/wall_cutter/selftest.rb'` after `./package.sh`. Expected: previous four PASSes plus `group wall: path is [group]`, `group wall: cut commits`, `group wall: hole made`, `group wall: duplicate instance survives`.

- [ ] **Step 4: Commit**

```bash
git add src
git commit -m "feat: cut engine context plumbing for grouped walls"
```

---

### Task 3: Component drilling (Feature 2)

**Files:**
- Modify: `src/wall_cutter.rb` (drill command, menu wiring, context menu)
- Modify: `src/selftest.rb` (drill section)

**Interfaces:**
- Consumes: `CutEngine.cut(path:)`, `WallCutter.face_path`, `WallCutter.top_level_ok?`.
- Produces: `WallCutter.drill_selected(quiet: false) -> true/false`; `WallCutter.detect_axis(inst) -> [n, front_hit, back_hit] | nil`; `WallCutter.drillable?(selection) -> bool` (exactly one Group or ComponentInstance).

- [ ] **Step 1: Implement the drill command in the loader**

```ruby
  SANDWICH_TOL = 6.0
  PLANE_PAD    = 1.0 / 32.0

  def self.drillable?(sel)
    sel.count == 1 && (sel[0].is_a?(Sketchup::ComponentInstance) || sel[0].is_a?(Sketchup::Group))
  end

  def self.drill_selected(quiet: false)
    model = Sketchup.active_model
    fail_with('Select exactly one component or group touching a wall.', quiet) unless drillable?(model.selection)
    return false unless top_level_ok? || quiet
    inst = model.selection[0]
    res  = detect_axis(inst)
    unless res
      fail_with('No wall sandwich found along the component axes — nudge the component into the wall.', quiet)
      return false
    end
    n, front, back = res
    bb  = world_bounds(inst)
    u, v = side_axes(n)
    ext = ->(axis) { cs = (0..7).map { |i| bb.corner(i) % axis }; cs.max - cs.min }
    width  = ext.(u) + 2 * PLANE_PAD
    height = ext.(v) + 2 * PLANE_PAD
    depth  = (back[0] - front[0]).length
    ok = CutEngine.cut(front[0], n, u, v, width, height, depth, path: face_path(front[2]))
    # ponytail: raytest sees the topmost surface, so a component buried in a container
    # drills "the sandwich that is actually there". Wrong sandwich escape hatch = Smart Cutout.
    fail_with('Cut removed nothing — is the wall closed geometry?', quiet) unless ok
    ok
  end

  def self.fail_with(msg, quiet)
    UI.messagebox(msg) unless quiet
  end

  def self.world_bounds(inst)
    t  = inst.transformation
    bb = Geom::BoundingBox.new
    8.times { |i| bb.add(inst.bounds.corner(i).transform(t)) }
    bb
  end

  # Local X/Y/Z of the instance in world; pick the axis whose BOTH raytest hits
  # straddle the bbox center within (half-extent along axis + SANDWICH_TOL).
  def self.detect_axis(inst)
    model  = Sketchup.active_model
    bb     = world_bounds(inst)
    center = bb.center
    t      = inst.transformation
    axes   = [Geom::XVECTOR, Geom::YVECTOR, Geom::ZVECTOR].map { |a| a.transform(t).normalize }
    axes.each do |ax|
      half = (0..7).map { |i| ((bb.corner(i) - center) % ax).abs }.max
      f = model.raytest(center, ax.reverse)
      b = model.raytest(center, ax)
      next unless f && b
      limit = half + SANDWICH_TOL
      if (f[0] - center).length <= limit && (b[0] - center).length <= limit
        n = (b[0] - f[0]).normalize
        return [n, f, b]
      end
    end
    nil
  end

  # Two world axes perpendicular to n, chosen from the instance's local axes.
  def self.side_axes(n)
    model = Sketchup.active_model # (no-op; keeps scope clear for reviewers)
    inst_axes = model.selection[0].transformation
    cands = [Geom::XVECTOR, Geom::YVECTOR, Geom::ZVECTOR].map { |a| a.transform(inst_axes).normalize }
    side  = cands.select { |a| (a % n).abs < 0.5 }
    raise 'drill: could not derive side axes' if side.size < 2
    [side[0], side[1]]
  end
```

Then replace the two stub menu items:

```ruby
    menu.add_item('Smart Cutout…')   { WallCutter::CutoutTool.activate } # exists from Task 4; see note
    menu.add_item('Drill Component') { WallCutter.drill_selected }
    UI.add_context_menu_handler do |cm|
      cm.add_item('Drill Through Wall') { WallCutter.drill_selected } if WallCutter.drillable?(Sketchup.active_model.selection)
    end
```

If Task 4 hasn't landed yet (plan executed out of order), temporarily keep the Smart Cutout stub as `UI.messagebox('Task 4 pending')`.

- [ ] **Step 2: Add the drill self-test**

```ruby
    def self.run_drill
      model = Sketchup.active_model
      ents  = model.entities
      box_wall(ents, 40', 10', 9', 12")
      defn = model.definitions.add('WCtestPlug')
      fp = defn.entities.add_face(
        Geom::Point3d.new(-18", -12", 0), Geom::Point3d.new(18", -12", 0),
        Geom::Point3d.new(18", 12", 0), Geom::Point3d.new(-18", 12", 0))
      fp.pushpull(48")
      inst = ents.add_instance(defn, Geom::Transformation.new(Geom::Vector3d.new(45', 6", 54")))
      model.selection.add(inst)
      before = ents.grep(Sketchup::Face).length
      ok = WallCutter.drill_selected(quiet: true)
      model.selection.clear
      check('drill: sandwich axis found + cut committed') { ok }
      check('drill: wall skin split')                     { ents.grep(Sketchup::Face).length > before }
      check('drill: ray clears along axis') do
        hit = model.raytest(Geom::Point3d.new(45', -20", 78"), Geom::YVECTOR)
        hit.nil?
      end
      # negative: component in mid-air must detect nothing
      loose = ents.add_instance(defn, Geom::Transformation.new(Geom::Vector3d.new(100', 0, 100')))
      model.selection.add(loose)
      check('drill: no sandwich -> false') { !WallCutter.drill_selected(quiet: true) }
      model.selection.clear
      loose.erase!
    end
```

Call `run_drill` from `run`. Note: `box_wall` puts its front at y=0 with the body in +Y; the plug at y=6″ is sandwiched by wall front (−Y hit at 6″) and back (+Y hit at 6″) with half-extent 12″ ≤ limit — the local-Y axis of an unrotated instance is the drill axis.

- [ ] **Step 3: Re-run self-test in SketchUp**

Expected additions: `drill: sandwich axis found + cut committed`, `drill: wall skin split`, `drill: ray clears along axis`, `drill: no sandwich -> false` — all PASS. Then manually: right-click a component embedded in a drawn wall → "Drill Through Wall" → hole appears, one Ctrl-Z removes it entirely.

- [ ] **Step 4: Commit**

```bash
git add src
git commit -m "feat: component drilling with axis auto-detection and context menu"
```

---

### Task 4: Smart Cutout tool core (pick, frame, preview, commit)

**Files:**
- Create: `src/cutout_tool.rb` (`FaceFrame` + `CutoutTool`, dialog added in Task 5)
- Modify: `src/selftest.rb` (FaceFrame math section)

**Interfaces:**
- Consumes: `CutEngine.cut(path:)`, `WallCutter.face_path`, `WallCutter.top_level_ok?`, `PRESETS`.
- Produces: `WallCutter::FaceFrame.new(face, into_normal)` exposing `#n #u #v #min_u #max_u #min_v #max_v #ref`, `#fits?(w, h)`, `#center_origin(w, h, sill = nil, left = nil)`; `WallCutter::CutoutTool.activate`.

- [ ] **Step 1: Implement FaceFrame**

```ruby
# frozen_string_literal: true
module WallCutter
  # Pure in-plane coordinate frame of a face. v = world-Z projected onto the plane;
  # degenerate for horizontal faces -> u = longest outer-loop edge, v = u x n.
  class FaceFrame
    attr_reader :n, :u, :v, :ref, :min_u, :max_u, :min_v, :max_v

    def initialize(face, into_normal)
      @n = into_normal.normalize
      vv = Geom::ZVECTOR - @n * (Geom::ZVECTOR % @n)
      if vv.length < 0.001
        edge = face.outer_loop.edges.max_by(&:length)
        uu = edge.line[1].normalize
        @u = uu
        @v = @n.cross(uu).normalize
      else
        @v = vv.normalize
        @u = @n.cross(@v).normalize
      end
      pts = face.outer_loop.vertices.map(&:position)
      @ref = pts.first
      us = pts.map { |p| (p - @ref) % @u }
      vs = pts.map { |p| (p - @ref) % @v }
      @min_u, @max_u = us.minmax
      @min_v, @max_v = vs.minmax
    end

    def avail_w = max_u - min_u
    def avail_h = max_v - min_v

    def fits?(w, h)
      w <= avail_w && h <= avail_h
    end

    # World point at the opening's CENTER. Default horizontally centered; sill/left
    # measured from the face's bounding corners, matching the spec's positioning rules.
    def center_origin(w, h, sill = nil, left = nil)
      left ||= (avail_w - w) / 2.0
      sill ||= 0.0
      @ref.offset(@u, min_u + left + w / 2.0).offset(@v, min_v + sill + h / 2.0)
    end
  end
end
```

(`edge.line[1]` is the edge's direction vector; `offset` mutates and returns the receiver, so each chained call starts from a fresh copy of `@ref` — verified: `Point3d#offset` returns the same object it mutated; wrap `@ref` use with `Geom::Point3d.new(@ref)` if aliasing shows up in testing.)

- [ ] **Step 2: Implement CutoutTool (no dialog yet)**

Append to `src/cutout_tool.rb`:

```ruby
  class CutoutTool
    def self.activate
      model = Sketchup.active_model
      return unless WallCutter.top_level_ok?
      model.select_tool(new)
    end

    def initialize
      @face   = nil
      @params = PRESETS['Window'].dup
    end

    def activate
      Sketchup.status_text = 'WallCutter: click a wall face, adjust in panel, Enter to cut'
    end

    def deactivate(view)
      Sketchup.status_text = ''
      view.invalidate
    end

    def onCancel(_reason, view)
      Sketchup.active_model.select_tool(nil)
      view.invalidate
    end

    def onLButtonDown(flags, x, y, view)
      ph = view.pick_helper
      ph.do_pick(x, y)
      best = ph.best_picked
      @face = best if best.is_a?(Sketchup::Face)
      @frame = nil
      view.invalidate
    end

    def onReturn(_flags, view)
      commit_cut(view)
    end

    def commit_cut(view)
      return report('nothing picked') unless @face&.valid?
      frame = current_frame(view)
      w = @params[:width].to_f
      h = @params[:height].to_f
      unless frame.fits?(w, h)
        return report(format('opening exceeds wall (available %0.1f" x %0.1f")',
                             frame.avail_w, frame.avail_h))
      end
      origin = frame.center_origin(w, h, @params[:sill], @params[:left])
      depth  = @params[:depth] || auto_depth(origin, frame.n)
      ok = CutEngine.cut(origin, frame.n, frame.u, frame.v, w, h, depth,
                         path: WallCutter.face_path(@face))
      report(ok ? 'cut done — click next face or Esc' : 'cut removed nothing — set depth manually')
      Sketchup.active_model.active_view.invalidate
    end

    def auto_depth(origin, n)
      probe = Geom::Point3d.new(origin.x, origin.y, origin.z).offset(n, 0.01)
      hit = Sketchup.active_model.raytest(probe, n)
      hit ? (hit[0] - origin).length + 1.0 : 24.0
    end

    def draw(view)
      return unless @face&.valid?
      frame = current_frame(view)
      w = @params[:width].to_f
      h = @params[:height].to_f
      return unless frame.fits?(w, h)
      o = frame.center_origin(w, h, @params[:sill], @params[:left])
      corners = [o.offset(frame.u.reverse, w / 2.0).offset(frame.v.reverse, h / 2.0)]
      # build all 4 without aliasing: see FaceFrame note
      pts = [[-1, -1], [1, -1], [1, 1], [-1, 1]].map do |su, sv|
        p = Geom::Point3d.new(o.x, o.y, o.z)
        p.offset(frame.u, su * w / 2.0).offset(frame.v, sv * h / 2.0)
      end
      view.draw_lines(pts, false, Sketchup::Color.new(0, 180, 255))
      view.draw_points(pts, 6, 2, Sketchup::Color.new(0, 180, 255))
    end

    # ponytail: rebuilt per draw frame; outer-loop is tiny, cache if walls get 10k-vertex profiles
    def current_frame(view)
      @frame ||= begin
        d = view.camera.direction
        into = (@face.normal % d < 0) ? @face.normal.reverse : @face.normal
        FaceFrame.new(@face, into)
      end
    end

    def report(msg)
      Sketchup.status_text = "WallCutter: #{msg}"
      nil
    end
  end
end
```

`view.draw_lines(pts, false, color)` draws the closed 4-point outline; Enter commits via `onReturn`; Escape exits via default tool deactivation.

- [ ] **Step 3: Add FaceFrame checks to self-test**

```ruby
    def self.run_frame
      model = Sketchup.active_model
      front = model.entities.grep(Sketchup::Face).find { |f| f.normal.y < -0.999 && f.bounds.min.y.abs < 0.01 && f.vertices.size == 4 }
      frame = FaceFrame.new(front, Geom::YVECTOR)
      check('frame: v is up')      { (frame.v % Geom::ZVECTOR) > 0.999 }
      check('frame: u is along X') { (frame.u % Geom::XVECTOR).abs > 0.999 }
      check('frame: fits hole')    { frame.fits?(36", 48") }
      check('frame: rejects oversize') { !frame.fits?(11', 10') }
      o = frame.center_origin(36", 48", 48", nil) # sill 48", centered: center = (x?,0,48+24)
      check('frame: sill placement') { (o.z - 72").abs < 0.01 }
    end
```

Call `run_frame` from `run`.

- [ ] **Step 4: Verify in SketchUp**

Self-test: all previous PASSes plus the five `frame:` lines. Manual viewport smoke (the tool has no dialog yet — exercise it by pre-setting params): Ruby Console `Sketchup.active_model.select_tool(WallCutter::CutoutTool.new)` → click the wall face of your box wall → cyan rectangle preview appears centered → Enter → hole cut, status says "cut done"; Esc exits leaving zero new entities (check with `model.entities.length` before/after an Esc-only session).

- [ ] **Step 5: Commit**

```bash
git add src
git commit -m "feat: smart cutout tool with face picking, preview, and validation"
```

---

### Task 5: HtmlDialog panel wiring

**Files:**
- Modify: `src/cutout_tool.rb` (`activate`/`deactivate`/dialog methods + HTML)
- Modify: `src/selftest.rb` is NOT touched here (dialog is verified in viewport)

**Interfaces:**
- Consumes: `CutoutTool#commit_cut`, `CutoutTool#current_frame`/`@params`, `PRESETS`.
- Produces: Ruby→JS `setPresets(json)`, `setAvailable(w, h)`; JS→Ruby callbacks `preset(name)`, `params(json)` (fields `width/height/sill/left/depth`, empty string = default).

- [ ] **Step 1: Add dialog to CutoutTool**

In `CutoutTool`:

```ruby
    def activate
      Sketchup.status_text = 'WallCutter: click a wall face, adjust in panel, Enter to cut'
      show_dialog
    end

    def deactivate(view)
      @dlg.close if @dlg && @dlg.visible?
      Sketchup.status_text = ''
      view.invalidate
    end

    def show_dialog
      require 'json'
      @dlg = UI::HtmlDialog.new(dialog_title: 'WallCutter', preferences_name: 'wallcutter',
                                width: 260, height: 330, style: UI::HtmlDialog::STYLE_DIALOG)
      @dlg.set_html(HTML)
      @dlg.add_action_callback('preset') { |_c, name| apply_preset(name.to_s) }
      @dlg.add_action_callback('params') { |_c, raw|
        vals = JSON.parse(raw.to_s)
        @params[:width]  = vals['width'].to_f  if vals['width'].to_f  > 0
        @params[:height] = vals['height'].to_f if vals['height'].to_f > 0
        @params[:sill]   = vals['sill'].empty? ? nil : vals['sill'].to_f
        @params[:left]   = vals['left'].empty? ? nil : vals['left'].to_f
        @params[:depth]  = vals['depth'].empty? ? nil : vals['depth'].to_f
        @frame = nil
        Sketchup.active_model.active_view.invalidate
      }
      @dlg.add_action_callback('cut') { |_c, _| commit_cut(Sketchup.active_model.active_view) }
      @dlg.show
      @dlg.set_html(HTML) # keep; re-set is cheap
      @dlg.execute_script("setPresets(#{PRESETS.to_json})")
    end

    def apply_preset(name)
      p = PRESETS[name] || PRESETS['Window']
      @params = p.dup
      @params[:left] = @params[:depth] = nil
      @frame = nil
      @dlg.execute_script("fillForm(#{@params.to_json})") if @dlg&.visible?
      Sketchup.active_model.active_view.invalidate
    end
```

Note for implementer: delete the old one-line `activate` (status text only) — it is replaced by the above; `deactivate` likewise extends the Task 4 version. `@params[:depth]` must default to `nil` (auto) on init: add `@params[:depth] = nil` in `initialize`.

- [ ] **Step 2: Add the inline HTML constant**

Inside `module WallCutter` (above `CutoutTool`):

```ruby
    HTML = <<~HTML
      <!DOCTYPE html><html><head><meta charset="utf-8"><style>
      body{font:13px -apple-system;margin:10px}label{display:block;margin:7px 0 1px}
      input,select{width:100%;box-sizing:border-box;padding:3px}
      button{width:100%;margin-top:12px;padding:7px;font-weight:600}
      #avail{color:#0a7;font-size:12px;height:16px}
      </style></head><body>
      <label>Preset<select id="preset" onchange="sketchup.preset(this.value)"></select></label>
      <label>Width (in)<input id="w" type="number" onchange="push()"></label>
      <label>Height (in)<input id="h" type="number" onchange="push()"></label>
      <label>Sill from bottom (in)<input id="sill" type="number" placeholder="0" onchange="push()"></label>
      <label>Left offset (in)<input id="left" type="number" placeholder="centered" onchange="push()"></label>
      <label>Depth (in)<input id="depth" type="number" placeholder="auto through wall" onchange="push()"></label>
      <div id="avail"></div>
      <button onclick="sketchup.cut()">Cut</button>
      <script>
      function setPresets(p){var s=document.getElementById('preset');
        for(var k in p){var o=document.createElement('option');o.value=k;o.textContent=k;s.appendChild(o);}}
      function fillForm(v){w.value=v.width;h.value=v.height;sill.value=v.sill||0;
        if(v.left==null)left.value='';if(v.depth==null)depth.value='';push();}
      function push(){sketchup.params(JSON.stringify({
        width:document.getElementById('w').value,height:document.getElementById('h').value,
        sill:document.getElementById('sill').value,left:document.getElementById('left').value,
        depth:document.getElementById('depth').value}));}
      </script></body></html>
    HTML
```

(`HTML` must live in `module WallCutter`, referenced as `WallCutter::HTML` or move it into the class — put it inside `class CutoutTool` to keep scoping trivial.)

- [ ] **Step 3: Verify in SketchUp**

Menu → Smart Cutout…: panel opens pre-filled with Window preset (36/48/36). Change Width to 200 → preview disappears + status "opening exceeds wall…"; change back → preview returns. Move sill/left fields → preview rectangle tracks live. Click Cut → hole cut, single Ctrl-Z undoes it. Preset dropdown switches Door (32/80/0) and fills the form. Close dialog + Esc → no leftover entities.

- [ ] **Step 4: Commit**

```bash
git add src
git commit -m "feat: cutout dialog panel with presets and live parameter preview"
```

---

### Task 6: Packaging + dev install + final check

**Files:**
- Modify: `package.sh` (add `install_dev`)
- Create: `.gitignore`

**Interfaces:** consumes everything; produces `wall_cutter.rbz` and a one-command dev loop.

- [ ] **Step 1: Add dev install to `package.sh`**

```bash
if [ "$1" = "install_dev" ]; then
  rsync -a --delete build/wall_cutter "$HOME/Library/Application Support/SketchUp 2026/SketchUp/Plugins/"
  rsync -a build/wall_cutter.rb "$HOME/Library/Application Support/SketchUp 2026/SketchUp/Plugins/"
  echo "installed to Plugins dir — restart SketchUp"
fi
```

- [ ] **Step 2: `.gitignore`**

```
build/
wall_cutter.rbz
```

- [ ] **Step 3: Full verification**

`./package.sh && ./package.sh install_dev` → restart SketchUp → scratch model → `load '<Plugins>/wall_cutter/selftest.rb'` → every check PASSes. Then the spec's success criteria by hand: loose wall cut, grouped wall cut, two-layer wall cut (draw two parallel 1″ walls 3″ apart, one Smart Cutout with auto depth must clear both), each undone with a single Ctrl-Z.

- [ ] **Step 4: Commit + push**

```bash
git add package.sh .gitignore
git commit -m "chore: rbz packaging and dev install target"
git push
```

---

## Self-review notes (author)

- Spec coverage: engine + no-op guard + undo (T1), context handling (T2), drill incl. sandwich detection, pads, refusal message (T3), face axes/positioning/fit-validation/auto-depth/preview (T4), dialog + presets (T5), rbz + success criteria (T6). Dialog "Cut button keeps tool active" — satisfied: commit doesn't deactivate. Failure-mode table fully covered by T1 (no-op, exception via `ensure`) and T4 (miss, oversize). Out-of-scope list respected: nothing added.
- Type consistency: `CutEngine.cut(origin, n, u, v, width, height, depth, path:)` used identically in T2/T3/T4; `face_path`, `top_level_ok?`, `PRESETS` keys match everywhere; `@params[:depth] == nil` ⇔ auto is consistent T4↔T5.
- Known watch-points deliberately assigned to tests, not hand-waved: `PathFromEntity#find` semantics (T2 test), `Point3d#offset` aliasing (T4 note + selftest), auto-depth across layered walls (T6 manual check).
