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
  # PathFromEntity may or may not include the leaf entity itself, so filter.
  def self.face_path(entity)
    return [] if entity.parent.is_a?(Sketchup::Model)
    chain = Sketchup::PathFromEntity.new.find(entity) || []
    chain.select { |e| e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group) }
  end

  def self.drillable?(sel)
    sel.count == 1 && (sel[0].is_a?(Sketchup::ComponentInstance) || sel[0].is_a?(Sketchup::Group))
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

  # Local X/Y/Z of the instance in world; the drill axis is the one whose BOTH raytest
  # hits straddle the bbox center within (half-extent along that axis + SANDWICH_TOL),
  # i.e. the component is sandwiched by geometry on both sides — that pair is the wall.
  def self.detect_axis(inst)
    model  = Sketchup.active_model
    bb     = world_bounds(inst)
    center = bb.center
    t      = inst.transformation
    [X_AXIS, Y_AXIS, Z_AXIS].each do |a|
      ax = a.transform(t).normalize
      half = (0..7).map { |i| ((bb.corner(i) - center) % ax).abs }.max
      f = model.raytest(center, ax.reverse)
      b = model.raytest(center, ax)
      next unless f && b
      limit = half + SANDWICH_TOL
      if (f[0] - center).length <= limit && (b[0] - center).length <= limit
        return [(b[0] - f[0]).normalize, f, b]
      end
    end
    nil
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
    n, front, back = res
    bb = world_bounds(inst)
    u, v = side_axes(inst, n)
    ext = lambda do |axis|
      cs = (0..7).map { |i| bb.corner(i) % axis }
      cs.max - cs.min
    end
    width  = ext.call(u) + 2 * PLANE_PAD
    height = ext.call(v) + 2 * PLANE_PAD
    depth  = (back[0] - front[0]).length + CutEngine::PRIDE_IN
    ok = CutEngine.cut(front[0], n, u, v, width, height, depth, path: face_path(front[2]))
    # ponytail: raytest sees the topmost surface, so a component buried inside a
    # container drills "the sandwich that is actually there", not a conceptual wall.
    # Escape hatch for a wrong sandwich: Smart Cutout's explicit face pick.
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
