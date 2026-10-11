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
      axis_diag = WallCutter.detect_axis(inst, true)
      puts("  diag: axis=#{axis_diag.nil? ? 'nil' : axis_diag[0].to_a.map { |x| x.round(2) }.inspect} span=#{axis_diag&.last&.round(1)}")
      ok = WallCutter.drill_selected(quiet: true)
      model.selection.clear
      check('drill: sandwich axis found + cut committed') { ok }
      check('drill: wall skin split')                     { ents.grep(Sketchup::Face).length > before }
      inst.erase! # plug blocks the verification ray while it sits in the hole
      check('drill: ray clears along axis') do
        hit = WallCutter.ray(model, Geom::Point3d.new(540.0, -20.0, 78.0), Y_AXIS)
        puts("  diag: drill ray hit=#{hit ? hit[0].to_a.map { |x| x.round(1) }.inspect : 'nil'}") if hit
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

    def self.run
      # Start from a clean slate: a recovered/contaminated model (SketchUp restores
      # unsaved work after a force-quit) produces duplicate coplanar faces and lies.
      model = Sketchup.active_model
      model.entities.clear!
      # Explicit transaction around everything: pushpull silently no-ops when the
      # recovered undo stack leaves an unbalanced operation open.
      model.start_operation('WallCutter selftest', true)
      %i[run_engine run_group run_drill run_frame].each do |m|
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
