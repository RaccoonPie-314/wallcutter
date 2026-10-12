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

    def self.run
      # Start from a clean slate: a recovered/contaminated model (SketchUp restores
      # unsaved work after a force-quit) produces duplicate coplanar faces and lies.
      model = Sketchup.active_model
      model.entities.clear!
      # Explicit transaction around everything: pushpull silently no-ops when the
      # recovered undo stack leaves an unbalanced operation open.
      model.start_operation('WallCutter selftest', true)
      %i[run_units run_engine run_group run_drill run_frame].each do |m|
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
