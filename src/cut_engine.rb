# frozen_string_literal: true
require 'sketchup.rb'

module WallCutter
  # All linear values are plain Floats in INCHES (SketchUp's internal length unit).
  PRESETS = {
    'Window'  => { width: 36.0, height: 48.0, sill: 36.0 },
    'Door'    => { width: 32.0, height: 80.0, sill: 0.0 },
    'Opening' => { width: 48.0, height: 48.0, sill: 24.0 }
  }.freeze

  X_AXIS = Geom::Vector3d.new(1, 0, 0)
  Y_AXIS = Geom::Vector3d.new(0, 1, 0)
  Z_AXIS = Geom::Vector3d.new(0, 0, 1)

  # SketchUp 2026 removed Entities#clip / Geom::SolidMunger and Vector3d scalar
  # multiply, so cutting uses the native editing primitives instead: add_face with a
  # coplanar rectangle splits the entry face; pushpulling that inner face slightly past
  # the layer's exit plane punches a clean through-hole — the manual workflow, scripted.
  # ponytail: planar entry faces only. Curved/organic walls are the known ceiling;
  # upgrade path is triangulated per-face clipping.
  module CutEngine
    PRIDE_IN = 1.0 # overshoot past the exit face so the hole comes out clean

    # origin/n/u/v in world coords; path = Group/ComponentInstance chain from root to the
    # container owning the face ([] for top level). Returns false if nothing could be cut.
    def self.cut(origin, n, u, v, width, height, depth, path: [])
      model = Sketchup.active_model
      ents  = path.empty? ? model.entities : path.last.entities
      inv   = world_to_local(path).inverse
      o  = origin.transform(inv)
      nl = n.transform(inv)
      ul = u.transform(inv)
      vl = v.transform(inv)
      un = Geom::Vector3d.new(nl.to_a).normalize
      ut = Geom::Vector3d.new(ul.to_a).normalize
      vt = Geom::Vector3d.new(vl.to_a).normalize
      wl = width * ul.length
      hl = height * vl.length
      dl = depth * nl.length
      model.start_operation('WallCutter cut', true)
      begin
        # Faces parallel to the cutter, sorted along the into-wall axis; consecutive
        # pairs are the entry/exit planes of one solid layer (layered walls included).
        planes = ents.grep(Sketchup::Face).select { |f|
          f.normal.cross(un).length < 0.001
        }.map { |f| [plane_t(f, o, un), f] }
          .select { |t, f| t >= -0.001 && t <= dl + 0.001 && bounds_hold?(f.bounds, o, un, ut, vt, t, wl, hl) }
          .sort_by(&:first)
        cut_any = false
        i = 0
        while i + 1 < planes.size
          t_in  = planes[i][0]
          t_out = planes[i + 1][0]
          cut_any = true if cut_layer(ents, planes[i][1], o, un, ut, vt, wl, hl, t_in, t_out - t_in)
          i += 2 # pushpull already holed the exit face; skip it as a future entry
        end
        if cut_any
          model.commit_operation
          true
        else
          model.abort_operation
          false
        end
      rescue StandardError
        model.abort_operation
        raise
      end
    end

    def self.world_to_local(path)
      path.inject(Geom::Transformation.new) { |t, inst| t * inst.transformation }
    end

    # Plane parameter (inches along un from o) of a face parallel to un.
    def self.plane_t(face, o, un)
      (face.bounds.center - o) % un
    end

    def self.cut_layer(ents, target, o, un, ut, vt, w, h, t, thickness)
      center = Geom::Point3d.new(o.x + un.x * t, o.y + un.y * t, o.z + un.z * t)
      area = w * h
      rect = [[-1, -1], [1, -1], [1, 1], [-1, 1]].map do |su, sv|
        corner(center, ut, su * w / 2.0, vt, sv * h / 2.0)
      end
      rf = ents.add_face(rect)
      return false unless rf
      # The split only really happened if the new face shares an edge with the target;
      # otherwise add_face dropped a floating rect (rect outside that face) -> erase it.
      inner = rect_face_at(ents, center, area)
      unless inner && inner.edges.any? { |e| target.edges.include?(e) }
        rf.erase! if rf.valid?
        return false
      end
      dist = thickness + PRIDE_IN
      dist = -dist if inner.normal % un < 0 # pushpull travels along the face normal
      inner.pushpull(dist)
      true
    end

    # Face centered on +center+ with area ~ +area+. Tolerance-based identity check:
    # Face#center is gone in 2026; bounds.center + area are the survivors.
    def self.rect_face_at(ents, center, area, tol = 0.5)
      ents.grep(Sketchup::Face).find do |f|
        b = f.bounds
        (b.center - center).length < tol && (f.area - area).abs < area * 0.05 + tol
      end
    end

    # Does the face's AABB hold the rect center at plane t (with half-diagonal slack)?
    # Cheap pre-filter; the edge-share check in cut_layer is the real verdict.
    def self.bounds_hold?(b, o, un, ut, vt, t, w, h)
      c = Geom::Point3d.new(o.x + un.x * t, o.y + un.y * t, o.z + un.z * t)
      r = (w + h) / 2.0 # generous circumscribed radius for rotated walls
      c.x > b.min.x - r && c.x < b.max.x + r &&
        c.y > b.min.y - r && c.y < b.max.y + r &&
        c.z > b.min.z - r && c.z < b.max.z + r
    end

    def self.corner(base, u, ud, v, vd)
      Geom::Point3d.new(base.x + u.x * ud + v.x * vd,
                        base.y + u.y * ud + v.y * vd,
                        base.z + u.z * ud + v.z * vd)
    end
  end
end
