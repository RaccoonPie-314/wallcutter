# frozen_string_literal: true
# WallCutter acceptance gate — run INSIDE SketchUp (no headless runner exists).
#   1. ./package.sh && ./package.sh install_dev  (restart SketchUp once)
#   2. File > New  (scratch model! this leaves test walls behind — close without saving)
#   3. Ruby Console: load File.expand_path('~/Library/Application Support/SketchUp 2026/' \
#        'SketchUp/Plugins/wall_cutter/selftest.rb')
# Expected: only PASS lines, then "selftest done". All lengths are Floats in inches.
module WallCutter
  module SelfTest
    def self.check(name)
      ok = !!yield
      puts(ok ? "PASS #{name}" : "FAIL #{name}")
      ok
    rescue StandardError => e
      puts "FAIL #{name} (#{e.class}: #{e.message})"
      false
    end

    # Wall face in the XZ plane at y=0, extruded +Y. Returns the solid.
    def self.box_wall(ents, x0, w, h, thick)
      pts = [Geom::Point3d.new(x0, 0, 0), Geom::Point3d.new(x0 + w, 0, 0),
             Geom::Point3d.new(x0 + w, 0, h), Geom::Point3d.new(x0, 0, h)]
      f = ents.add_face(pts)
      f.reverse! unless f.normal.y > 0
      f.pushpull(thick)
      n = ents.grep(Sketchup::Face).length
      raise "box_wall at x=#{x0} extruded nothing (faces=#{n})" if n < 6
      f
    end

    # Raytest lies in this build, so verify holes by face census: no face may sit
    # inside the opening footprint at (or just outside) the front plane. A "collar"
    # rim or an unpushed inner face shows up here; rings/jambs are excluded by area.
    def self.hole_blockers(ents, center, u, v, w, h, n)
      ents.grep(Sketchup::Face).select do |f|
        next false unless f.area <= w * h * 1.1
        d = f.bounds.center - center
        off = d % n
        next false unless off >= -1.5 && off <= 1.5
        pu = (d - Geom::Vector3d.new(n.x * off, n.y * off, n.z * off))
        (pu % u).abs <= w / 2.0 + 1.0 && (pu % v).abs <= h / 2.0 + 1.0
      end
    end

    def self.run_engine
      model = Sketchup.active_model
      ents  = model.entities
      box_wall(ents, 0, 120.0, 108.0, 12.0) # 10ft x 9ft x 1ft wall at x=0
      faces_before = ents.grep(Sketchup::Face).length
      ok = CutEngine.cut(Geom::Point3d.new(60.0, 0, 54.0), Y_AXIS,
                         X_AXIS, Z_AXIS, 36.0, 48.0, 14.0)
      check('engine cut commits')           { ok }
      check('front skin split (hole made)') { ents.grep(Sketchup::Face).length > faces_before }
      check('ray through opening clears') do
        hit = WallCutter.ray(model, Geom::Point3d.new(60.0, -20.0, 54.0), Y_AXIS)
        puts("  diag: raw=#{model.raytest(Geom::Point3d.new(60.0, -20.0, 54.0), Y_AXIS).inspect[0, 120]} hit_at=#{hit ? hit[0].to_a.map { |x| x.round(1) }.inspect : 'nil'} on=#{hit ? hit[2].class : '-'}") if hit
        hit.nil?
      end
      blockers = hole_blockers(ents, Geom::Point3d.new(60.0, 0, 54.0), X_AXIS, Z_AXIS, 36.0, 48.0, Y_AXIS)
      check('no collar/blocker at front plane') { blockers.empty? }
      # debris sweeper self-check: plant a rim strip + a plug, sweep, column must be
      # clean. (The planted plug splits the jambs, so "kept" is asserted via the
      # post-sweep census, not an intact-jamb count.)
      jambs = ents.grep(Sketchup::Face).count { |f| f.area.between?(400, 2000) && (f.bounds.center - Geom::Point3d.new(60, 6, 54)).length < 30 }
      check('4 jambs present before planting debris') { jambs == 4 }
      strip = ents.add_face([42, -0.4, 30], [78, -0.4, 30], [78, -0.4, 31], [42, -0.4, 31])
      plugf = ents.add_face([42, 6, 30], [78, 6, 30], [78, 6, 78], [42, 6, 78])
      CutEngine.clear_hole_debris(ents, Geom::Point3d.new(60.0, 0, 54.0), Y_AXIS,
                                  X_AXIS, Z_AXIS, 36.0, 48.0, 14.0)
      check('debris sweeper removes strip and plug') { !strip.valid? && !plugf.valid? }
      post = hole_blockers(ents, Geom::Point3d.new(60.0, 0, 54.0), X_AXIS, Z_AXIS, 36.0, 48.0, Y_AXIS)
      check('column clean after sweep') { post.empty? }
      # AUTO depth (nil) must clear a wall thicker than the old 24in fallback...
      box_wall(ents, 130.0, 120.0, 108.0, 48.0) # 48in-thick wall at x=130..250
      auto_ok = CutEngine.cut(Geom::Point3d.new(190.0, 0, 54.0), Y_AXIS,
                              X_AXIS, Z_AXIS, 36.0, 48.0)
      check('auto depth clears 48in wall') do
        auto_ok && model.raytest(Geom::Point3d.new(190.0, -20.0, 54.0), Y_AXIS).nil?
      end
      # ...and a layered wall with a cavity (skins y=0..12 and y=20..32 at x=260..380;
      # 8in cavity - real cavities are under a foot, see CutEngine::CAVITY_MAX)
      lay = ents.add_face([260, 20, 0], [380, 20, 0], [380, 20, 108], [260, 20, 108])
      lay.reverse! unless lay.normal.y > 0
      lay.pushpull(12)
      lay_ok = CutEngine.cut(Geom::Point3d.new(320.0, 0, 54.0), Y_AXIS,
                             X_AXIS, Z_AXIS, 36.0, 48.0)
      check('auto depth clears layered wall + cavity') do
        lay_ok && model.raytest(Geom::Point3d.new(320.0, -20.0, 54.0), Y_AXIS).nil?
      end
      # deep block repro: user's model had a 227in-deep block; cuts left a 1in collar
      box_wall(ents, 900.0, 137.0, 132.0, 227.0)
      deep_ok = CutEngine.cut(Geom::Point3d.new(968.5, 0, 66.0), Y_AXIS,
                              X_AXIS, Z_AXIS, 36.0, 48.0)
      check('deep block cut commits') { deep_ok }
      deep_blockers = hole_blockers(ents, Geom::Point3d.new(968.5, 0, 66.0), X_AXIS, Z_AXIS, 36.0, 48.0, Y_AXIS)
      check('deep block: no collar at front plane') do
        deep_blockers.each { |f| puts "  blocker a=#{f.area.round(1)} c=[#{f.bounds.center.to_a.map { |x| x.round(1) }.join(',')}]" }
        deep_blockers.empty?
      end
      # shed repro: front wall + a parallel back wall 8ft behind - auto depth must
      # stop at the room air, not window the far wall too (user: "cut every corner")
      box_wall(ents, 1100.0, 120.0, 108.0, 12.0) # front wall y=0..12
      far = ents.add_face([1100, 96, 0], [1220, 96, 0], [1220, 96, 108], [1100, 96, 108])
      far.reverse! unless far.normal.y > 0
      far.pushpull(12) # back wall y=96..108
      shed_ok = CutEngine.cut(Geom::Point3d.new(1160.0, 0, 54.0), Y_AXIS,
                              X_AXIS, Z_AXIS, 36.0, 48.0)
      check('shed: front wall cut commits') { shed_ok }
      check('shed: front opening clears to the back wall') do
        hit = WallCutter.ray(model, Geom::Point3d.new(1160.0, -20.0, 54.0), Y_AXIS)
        puts("  diag: shed ray hit=#{hit ? hit[0].to_a.map { |x| x.round(1) }.inspect : 'nil'}") if hit.nil? || (hit[0].y - 96.0).abs > 0.5
        !hit.nil? && (hit[0].y - 96.0).abs < 0.5
      end
      check('shed: far wall untouched') do
        hit = WallCutter.ray(model, Geom::Point3d.new(1160.0, 200.0, 54.0), Y_AXIS.reverse)
        puts("  diag: far-wall ray hit=#{hit ? hit[0].to_a.map { |x| x.round(1) }.inspect : 'nil'}") if hit.nil? || (hit[0].y - 108.0).abs > 0.5
        !hit.nil? && (hit[0].y - 108.0).abs < 0.5
      end
      check('no-op cut returns false') do
        !CutEngine.cut(Geom::Point3d.new(60.0, -360.0, 54.0), Y_AXIS,
                       X_AXIS, Z_AXIS, 36.0, 48.0, 1.0)
      end
      check('failed cut reports why') { CutEngine.last_failure.to_s.include?('no face to cut') }
    end

    def self.run_group
      model = Sketchup.active_model
      ents  = model.entities
      grp   = ents.add_group
      box_wall(grp.entities, 240.0, 120.0, 108.0, 12.0) # wall inside a group at x=20ft
      before = grp.entities.grep(Sketchup::Face).length
      inner_front = grp.entities.grep(Sketchup::Face).find { |f| f.normal.y < -0.999 }
      path = WallCutter.face_path(inner_front)
      ok = CutEngine.cut(Geom::Point3d.new(300.0, 0, 54.0), Y_AXIS,
                         X_AXIS, Z_AXIS, 36.0, 48.0, 14.0, path: path)
      check('group wall: path is [group]') { path.size == 1 && path[0] == grp }
      # 2026 has no find_entity_by_pid on Model or Sketchup (probe-verified), so a
      # recorded path resolves by scanning entities for the stored persistent_id.
      check('group wall: persistent_id resolves by scan') do
        model.entities.find { |e| e.respond_to?(:persistent_id) && e.persistent_id == grp.persistent_id } == grp
      end
      check('group wall: cut commits')     { ok }
      check('group wall: hole made')       { grp.entities.grep(Sketchup::Face).length > before }
      dup = ents.add_instance(grp.definition,
                              Geom::Transformation.new(Geom::Vector3d.new(0, 360.0, 0)))
      check('group wall: duplicate instance survives') { dup.valid? }
      dup.erase!
    end

    def self.run_drill
      model = Sketchup.active_model
      ents  = model.entities
      box_wall(ents, 480.0, 120.0, 108.0, 12.0) # wall at x=40ft
      defn = model.definitions.add('WCtestPlug')
      fp = defn.entities.add_face(
        Geom::Point3d.new(-18.0, -12.0, 0), Geom::Point3d.new(18.0, -12.0, 0),
        Geom::Point3d.new(18.0, 12.0, 0), Geom::Point3d.new(-18.0, 12.0, 0))
      fp.pushpull(48.0)
      # 36x24x48 plug centered in the wall slab (y=6in, wall spans y=0..12) -> sandwiched on local Y
      inst = ents.add_instance(defn, Geom::Transformation.new(Geom::Vector3d.new(540.0, 6.0, 54.0)))
      model.selection.add(inst)
      before = ents.grep(Sketchup::Face).length
      ok = WallCutter.drill_selected(quiet: true)
      model.selection.clear
      check('drill: sandwich axis found + cut committed') { ok }
      check('drill: wall skin split')                     { ents.grep(Sketchup::Face).length > before }
      check('drill: component restored') { !defn.instances.first.nil? }
      restored = defn.instances.first
      restored.erase! if restored # plug blocks the verification ray while it sits in the hole
      check('drill: ray clears along axis') do
        hit = WallCutter.ray(model, Geom::Point3d.new(540.0, -20.0, 30.0), Y_AXIS)
        if hit
          puts "  diag: drill ray hit=#{hit[0].to_a.map { |x| x.round(1) }.inspect} ents=#{hit[1].inspect[0, 200]}"
          ents.grep(Sketchup::Face).each do |f|
            c = f.bounds.center
            next unless (c.x - 540).abs < 60 && (c.z - 30).abs < 60 && c.y > -30 && c.y < 25
            puts "  face c=[#{c.x.round(1)},#{c.y.round(1)},#{c.z.round(1)}] area=#{f.area.round(0)} n=#{f.normal.to_a.map { |x| x.round(1) }.inspect} loop=#{f.outer_loop.vertices.size}"
          end
        end
        hit.nil?
      end
      loose = ents.add_instance(defn, Geom::Transformation.new(Geom::Vector3d.new(1200.0, 0, 1200.0)))
      model.selection.add(loose)
      check('drill: no sandwich -> false') { !WallCutter.drill_selected(quiet: true) }
      model.selection.clear
      loose.erase!
    end

    def self.run_frame
      model = Sketchup.active_model
      box_wall(model.entities, 720.0, 120.0, 108.0, 12.0) # fresh wall at x=60ft
      front = model.entities.grep(Sketchup::Face).find do |f|
        f.normal.y < -0.999 && f.bounds.min.y.abs < 0.01 &&
          f.vertices.size == 4 && f.bounds.min.x > 708.0
      end
      frame = FaceFrame.new(front, Y_AXIS)
      check('frame: v is up')      { (frame.v % Z_AXIS) > 0.999 }
      check('frame: u is along X') { (frame.u % X_AXIS).abs > 0.999 }
      check('frame: fits hole')    { frame.fits?(36.0, 48.0) }
      check('frame: rejects oversize') { !frame.fits?(132.0, 120.0) }
      o = frame.center_origin(36.0, 48.0, 48.0, nil) # sill 48 -> center z = 48 + 24
      check('frame: sill placement') { (o.z - 72.0).abs < 0.01 }
    end

    def self.run_units
      ct = CutoutTool
      check('parse cm')      { (ct.parse_len('11 cm')[0] - 11.0 / 2.54).abs < 1e-6 && ct.parse_len('11 cm')[1] == 'cm' }
      check('parse mm')      { (ct.parse_len('110 mm')[0] - 110.0 / 25.4).abs < 1e-6 }
      check('parse in text') { (ct.parse_len('4 in')[0] - 4.0).abs < 1e-9 }
      check('parse inches mark') { (ct.parse_len(%q{4"})[0] - 4.0).abs < 1e-9 }
      check('parse plain = inches') { ct.parse_len('36') == [36.0, 'in'] }
      check('parse sill 0 allowed') { ct.parse_len('0') == [0.0, 'in'] }
      check('parse rejects junk') { ct.parse_len('abc').nil? && ct.parse_len('-5').nil? && ct.parse_len('').nil? }
      back = ct.parse_len(ct.fmt_len(36.0, 'cm'))
      check('fmt roundtrip cm') { (back[0] - 36.0).abs < 0.01 && back[1] == 'cm' }
      l, s2, w, h = ct.drag_resize(:e, 50, 40, 10, 5, 30, 20, 100, 100)
      check('drag e grows width') { l == 10 && s2 == 5 && w == 40 && h == 20 }
      l, s2, w, h = ct.drag_resize(:nw, 5, 50, 10, 5, 30, 20, 100, 100)
      check('drag nw moves left+top') { l == 5 && w == 35 && s2 == 5 && h == 45 }
      l, s2, w, h = ct.drag_resize(:ne, 999, 999, 10, 5, 30, 20, 100, 100)
      check('drag clamps to face') { w == 90 && h == 95 }
      l, s2, w, h = ct.drag_resize(:s, 20, -999, 10, 5, 30, 20, 100, 100)
      check('drag min size') { h >= ct::MIN_SIZE && s2 == 0 }
      l, s2, w, h = ct.drag_resize(:move, 50, 40, 10, 5, 30, 20, 100, 100)
      check('move repositions, size kept') { l == 50 && s2 == 40 && w == 30 && h == 20 }
      l, s2, w, h = ct.drag_resize(:move, 999, 999, 10, 5, 30, 20, 100, 100)
      check('move clamps inside face') { l == 70 && s2 == 80 && w == 30 && h == 20 }
    end

    # Hole registry + identification: the manager's whole Phase 1 surface.
    def self.run_holes
      model = Sketchup.active_model
      ents  = model.entities
      before = CutEngine.openings(model).size
      box_wall(ents, 1300.0, 120.0, 108.0, 12.0)
      box_wall(ents, 1450.0, 120.0, 108.0, 12.0)
      CutEngine.cut(Geom::Point3d.new(1360.0, 0, 54.0), Y_AXIS, X_AXIS, Z_AXIS, 36.0, 48.0, 14.0)
      CutEngine.cut(Geom::Point3d.new(1510.0, 0, 54.0), Y_AXIS, X_AXIS, Z_AXIS, 24.0, 30.0, 14.0)
      list = CutEngine.openings(model)
      r1 = list[-2]
      r2 = list[-1]
      check('registry records one entry per cut') { list.size == before + 2 }
      check('ids unique and ordered')             { r2['id'] == r1['id'] + 1 }
      check('record keeps the cut rect')           { r1['w'] == 36.0 && r1['h'] == 48.0 && r2['w'] == 24.0 }
      check('record keeps the cut layers') do
        r1['layers'].size == 1 && (r1['layers'][0][0] - 0.0).abs < 0.01 &&
          (r1['layers'][0][1] - 12.0).abs < 0.01
      end
      check('record keeps world origin + depth') do
        r1['origin'] == [1360.0, 0.0, 54.0] && (r1['depth'] - 12.0).abs < 0.01
      end
      ct = CutoutTool
      check('hover identifies the hole under the ray') do
        ct.hole_at_ray(list, [Geom::Point3d.new(1360.0, -30.0, 54.0), Y_AXIS]) == r1['id'] &&
          ct.hole_at_ray(list, [Geom::Point3d.new(1510.0, -30.0, 54.0), Y_AXIS]) == r2['id']
      end
      check('hover ignores empty space') do
        ct.hole_at_ray(list, [Geom::Point3d.new(1620.0, -30.0, 54.0), Y_AXIS]).nil?
      end
      check('hover ignores a ray pointing away') do
        ct.hole_at_ray(list, [Geom::Point3d.new(1360.0, -30.0, 54.0), Y_AXIS.reverse]).nil?
      end
      check('hole label shows size, not just a number') { ct.hole_label(r1) == "#{r1['id']} · 36 x 48 in" }
      check('registry survives a JSON roundtrip') { CutEngine.openings(model).last['id'] == r2['id'] }
    end

    # Phase 2: refill (undo one cut without touching the others) and the tweak path.
    def self.run_refill
      model = Sketchup.active_model
      ents  = model.entities
      box_wall(ents, 1700.0, 120.0, 108.0, 12.0)
      solid = ents.grep(Sketchup::Face).length
      CutEngine.cut(Geom::Point3d.new(1760.0, 0, 54.0), Y_AXIS, X_AXIS, Z_AXIS, 36.0, 48.0, 14.0)
      rec = CutEngine.openings(model).find { |r| r['origin'] == [1760.0, 0.0, 54.0] }
      check('refill: cut opened the wall first') do
        model.raytest(Geom::Point3d.new(1760.0, -20.0, 54.0), Y_AXIS).nil? &&
          ents.grep(Sketchup::Face).length > solid
      end
      check('refill: reports success') { CutEngine.refill_hole(model, rec) }
      check('refill: face count back to solid wall') { ents.grep(Sketchup::Face).length == solid }
      check('refill: front skin whole again') do
        hit = WallCutter.ray(model, Geom::Point3d.new(1760.0, -20.0, 54.0), Y_AXIS)
        puts("  diag: refill ray hit=#{hit ? hit[0].to_a.map { |x| x.round(2) }.inspect : 'nil'}") if hit.nil? || hit[0].y.abs > 0.01
        !hit.nil? && hit[0].y.abs < 0.01
      end
      check('refill: registry entry dropped') { CutEngine.openings(model).none? { |r| r['id'] == rec['id'] } }
      check('refilled hole is no longer selectable') { !CutEngine.hole_open?(model, rec) }
      check('refilling a stale hole refuses') { !CutEngine.refill_hole(model, rec) }
      # tweak: reopen smaller at the same centre — only the new rect is open again
      CutEngine.cut(Geom::Point3d.new(1760.0, 0, 54.0), Y_AXIS, X_AXIS, Z_AXIS, 36.0, 48.0, 14.0)
      r2 = CutEngine.openings(model).find { |r| r['origin'] == [1760.0, 0.0, 54.0] }
      CutEngine.refill_hole(model, r2)
      CutEngine.cut(Geom::Point3d.new(1760.0, 0, 54.0), Y_AXIS, X_AXIS, Z_AXIS, 12.0, 12.0, 14.0)
      check('fresh hole is selectable') { CutEngine.hole_open?(model, CutEngine.openings(model).last) }
      check('tweak: 12x12 re-cut opens the centre only') do
        model.raytest(Geom::Point3d.new(1760.0, -20.0, 54.0), Y_AXIS).nil? &&
          !model.raytest(Geom::Point3d.new(1744.0, -20.0, 54.0), Y_AXIS).nil?
      end
      # a cavity wall (two skins 8in apart) records two layers; refill closes all four
      a = ents.add_face([1900, 0, 0], [2020, 0, 0], [2020, 0, 108], [1900, 0, 108])
      a.reverse! unless a.normal.y > 0
      a.pushpull(12)
      b = ents.add_face([1900, 20, 0], [2020, 20, 0], [2020, 20, 108], [1900, 20, 108])
      b.reverse! unless b.normal.y > 0
      b.pushpull(12)
      cavity_solid = ents.grep(Sketchup::Face).length
      CutEngine.cut(Geom::Point3d.new(1960.0, 0, 54.0), Y_AXIS, X_AXIS, Z_AXIS, 36.0, 48.0)
      r3 = CutEngine.openings(model).find { |r| r['origin'] == [1960.0, 0.0, 54.0] }
      check('cavity wall: two layers recorded') { r3['layers'].size == 2 }
      check('cavity wall: refill closes every layer') do
        CutEngine.refill_hole(model, r3) && ents.grep(Sketchup::Face).length == cavity_solid
      end
    end

    # Finishes modelled as a single surface (no thickness) and skins behind a wall.
    def self.run_skin
      model = Sketchup.active_model
      ents  = model.entities
      lone = ents.add_face([2200, 0, 0], [2320, 0, 0], [2320, 0, 108], [2200, 0, 108])
      skin_faces = ents.grep(Sketchup::Face).length
      ok = CutEngine.cut(Geom::Point3d.new(2260.0, 0, 54.0), Y_AXIS, X_AXIS, Z_AXIS, 36.0, 48.0)
      rec = CutEngine.openings(model).last
      check('skin: cut on a lone surface commits') { ok && lone.valid? }
      check('skin: face count unchanged (ring left, inner deleted)') do
        ents.grep(Sketchup::Face).length == skin_faces
      end
      check('skin: opening is clear') do
        model.raytest(Geom::Point3d.new(2260.0, -20.0, 54.0), Y_AXIS).nil?
      end
      check('skin: recorded as a zero-thickness layer') { rec && rec['layers'] == [[0.0, 0.0]] }
      check('skin: refill welds the surface shut') do
        CutEngine.refill_hole(model, rec) &&
          !model.raytest(Geom::Point3d.new(2260.0, -20.0, 54.0), Y_AXIS).nil?
      end
      # a solid wall with a finish skin 8in behind it: layer + skin both cut
      box_wall(ents, 2400.0, 120.0, 108.0, 12.0)
      sk = ents.add_face([2400, 20, 0], [2520, 20, 0], [2520, 20, 108], [2400, 20, 108])
      both = CutEngine.cut(Geom::Point3d.new(2460.0, 0, 54.0), Y_AXIS, X_AXIS, Z_AXIS, 36.0, 48.0)
      check('wall + skin behind: both layers cut') do
        both && sk.valid? && sk.loops.size == 2 &&
          CutEngine.openings(model).last['layers'].size == 2 &&
          model.raytest(Geom::Point3d.new(2460.0, -20.0, 54.0), Y_AXIS).nil?
      end
      # a lone surface 8ft behind a WALL is a room boundary, not a skin: left alone.
      # The ray must pass the holed wall and stop ON the intact far surface, so the
      # check cannot pass vacuously by simply having nothing cut at all.
      box_wall(ents, 2600.0, 120.0, 108.0, 12.0) # structure y=0..12
      far = ents.add_face([2600, 96, 0], [2720, 96, 0], [2720, 96, 108], [2600, 96, 108])
      CutEngine.cut(Geom::Point3d.new(2660.0, 0, 54.0), Y_AXIS, X_AXIS, Z_AXIS, 36.0, 48.0)
      check('distant lone surface untouched') do
        hit = WallCutter.ray(model, Geom::Point3d.new(2660.0, -20.0, 54.0), Y_AXIS)
        if hit.nil? || (hit[0].y - 96.0).abs > 0.5 || far.loops.size != 1
          puts("  diag: ray=#{hit ? hit[0].to_a.map { |x| x.round(1) }.inspect : 'nil'} far_loops=#{far.loops.size}")
        end
        far.valid? && far.loops.size == 1 && !hit.nil? && (hit[0].y - 96.0).abs < 0.5
      end
    end

    def self.run
      # Start from a clean slate: a recovered/contaminated model (SketchUp restores
      # unsaved work after a force-quit) produces duplicate coplanar faces and lies.
      model = Sketchup.active_model
      model.entities.clear!
      # Records describe geometry that no longer exists after the wipe, and leftover
      # entries from an earlier run would tie-break hover tests against this run's cuts.
      model.set_attribute('WallCutter', 'openings', '[]')
      # Explicit transaction around everything: pushpull silently no-ops when the
      # recovered undo stack leaves an unbalanced operation open.
      model.start_operation('WallCutter selftest', true)
      %i[run_units run_engine run_group run_drill run_frame run_holes run_refill run_skin].each do |m|
        begin
          send(m)
        rescue Exception => e
          puts "FAIL #{m} crashed: #{e.class}: #{e.message} @ #{e.backtrace.first}"
        end
      end
      model.commit_operation
      puts 'selftest done'
    end
  end
end
WallCutter::SelfTest.run
