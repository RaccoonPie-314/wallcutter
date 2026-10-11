# frozen_string_literal: true
require 'sketchup.rb'
require 'json'

module WallCutter
  SANDWICH_TOL = 6.0
  PLANE_PAD    = 1.0 / 32.0

  def self.top_level_ok?
    return true unless Sketchup.active_model.active_path
    UI.messagebox('WallCutter works at the top editing level — exit the group/component you are editing first.')
    false
  end

  # Root->leaf Group/ComponentInstance chain enclosing +entity+; [] when top-level.
  # (Sketchup::PathFromEntity does not exist in 2026 — walk definition.instances upward.)
  def self.face_path(entity)
    chain = []
    defn = entity.parent
    while defn.is_a?(Sketchup::ComponentDefinition)
      inst = defn.instances.first
      break unless inst
      chain.unshift(inst)
      defn = inst.parent
    end
    chain
  end

  def self.drillable?(sel)
    sel.count == 1 && (sel[0].is_a?(Sketchup::ComponentInstance) || sel[0].is_a?(Sketchup::Group))
  end

  def self.fail_with(msg, quiet)
    UI.messagebox(msg) unless quiet
  end

  # definition.bounds is authoritative-local; ComponentInstance#bounds turned out to be
  # world-space in SketchUp 2026 (double-transforming it put the center across the map).
  def self.world_bounds(inst)
    t  = inst.transformation
    bb = Geom::BoundingBox.new
    bb_corners(inst.definition.bounds).each { |pt| bb.add(pt.transform(t)) }
    bb
  end

  # BoundingBox#corner is gone in 2026; eight min/max combinations replace it.
  def self.bb_corners(bb)
    xs = [bb.min.x, bb.max.x]
    ys = [bb.min.y, bb.max.y]
    zs = [bb.min.z, bb.max.z]
    xs.flat_map { |x| ys.flat_map { |y| zs.map { |z| Geom::Point3d.new(x, y, z) } } }
  end

  # Local X/Y/Z of the instance in world; the drill axis is the one whose BOTH raytest
  # hits straddle the bbox center within (half-extent along that axis + SANDWICH_TOL),
  # i.e. the component is sandwiched by geometry on both sides — that pair is the wall.
  # raytest normalizer: a miss may return nil OR an empty Array depending on build;
  # callers must never trust a bare truthiness check.
  def self.ray(model, point, vector)
    r = model.raytest(point, vector)
    (r.nil? || !r.is_a?(Array) || r.empty?) ? nil : r
  end

  # Sandwich detection WITHOUT raycasting (raytest from inside solids is unreliable):
  # for each instance axis, look for root faces perpendicular to it, overlapping the
  # component footprint, on both sides within tolerance. That pair is the wall.
  # ponytail: scans root entities only; walls nested in groups are drilled via Smart
  # Cutout's explicit face pick instead.
  def self.detect_axis(inst)
    bb      = world_bounds(inst)
    center  = bb.center
    corners = bb_corners(bb)
    t       = inst.transformation
    faces   = Sketchup.active_model.entities.grep(Sketchup::Face)
    [X_AXIS, Y_AXIS, Z_AXIS].each do |a|
      ax   = a.transform(t).normalize
      half = corners.map { |pt| ((pt - center) % ax).abs }.max
      front = nil
      back  = nil
      faces.each do |f|
        next if f.normal.cross(ax).length > 0.001
        fb = f.bounds
        next unless aabb_overlap?(bb, fb)
        off = (fb.center - center) % ax
        next unless off.abs <= half + SANDWICH_TOL
        if off < 0
          front = off if front.nil? || off > front
        else
          back = off if back.nil? || off < back
        end
      end
      next if front.nil? || back.nil?
      origin = Geom::Point3d.new(center.x + ax.x * front, center.y + ax.y * front,
                                 center.z + ax.z * front)
      return [ax, origin, back - front]
    end
    nil
  end

  def self.aabb_overlap?(a, b)
    a.min.x <= b.max.x && b.min.x <= a.max.x &&
      a.min.y <= b.max.y && b.min.y <= a.max.y &&
      a.min.z <= b.max.z && b.min.z <= a.max.z
  end

  # Two world side-axes perpendicular to the drill axis, from the instance's local axes.
  def self.side_axes(inst, n)
    t = inst.transformation
    cands = [X_AXIS, Y_AXIS, Z_AXIS].map { |a| a.transform(t).normalize }
    side  = cands.select { |a| (a % n).abs < 0.5 }
    raise 'WallCutter drill: could not derive side axes' if side.size < 2
    [side[0], side[1]]
  end

  def self.drill_selected(quiet: false)
    model = Sketchup.active_model
    unless drillable?(model.selection)
      fail_with('Select exactly one component or group touching a wall.', quiet)
      return false
    end
    return false unless top_level_ok?
    inst = model.selection[0]
    res  = detect_axis(inst)
    unless res
      fail_with('No wall sandwich found along the component axes — nudge the component into the wall.', quiet)
      return false
    end
    n, origin, span = res
    bb = world_bounds(inst)
    u, v = side_axes(inst, n)
    corners = bb_corners(bb)
    ref = bb.center
    ext = lambda do |axis|
      cs = corners.map { |pt| (pt - ref) % axis } # Point3d%Vector invalid; subtract first
      cs.max - cs.min
    end
    width  = ext.call(u) + 2 * PLANE_PAD
    height = ext.call(v) + 2 * PLANE_PAD
    # The component's own faces collide with the hole walls (the pad makes the hole
    # larger than the component), and pushpull stops at them. Lift it out, cut,
    # put it back into the finished opening.
    defn = inst.definition
    tr   = inst.transformation
    inst.erase!
    ok = CutEngine.cut(origin, n, u, v, width, height, span + 2.0)
    model.entities.add_instance(defn, tr) unless model.active_path
    fail_with('Cut removed nothing — is the wall closed geometry?', quiet) unless ok
    ok
  rescue StandardError => e
    fail_with("WallCutter drill error: #{e.message}", quiet)
    false
  end

  unless file_loaded?(__FILE__)
    require 'wall_cutter/cut_engine'
    require 'wall_cutter/cutout_tool'
    menu = UI.menu('Plugins').add_submenu('WallCutter') # shows under Extensions in 2021+
    menu.add_item('Smart Cutout')     { WallCutter::CutoutTool.activate }
    menu.add_item('Drill Component')  { WallCutter.drill_selected }
    UI.add_context_menu_handler do |cm|
      cm.add_item('Drill Through Wall') { WallCutter.drill_selected } if WallCutter.drillable?(Sketchup.active_model.selection)
    end
    file_loaded(__FILE__)
  end
end
