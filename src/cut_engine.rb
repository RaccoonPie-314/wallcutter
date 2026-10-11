# frozen_string_literal: true
require 'sketchup.rb'

module WallCutter
  # All linear values are plain Floats in INCHES (SketchUp's internal length unit).
  # Deliberately avoiding 12'/6" foot-inch literals: they are a SketchUp parser
  # extension that no other Ruby can parse, which would kill local syntax checking.
  PRESETS = {
    'Window'  => { width: 36.0, height: 48.0, sill: 36.0 },
    'Door'    => { width: 32.0, height: 80.0, sill: 0.0 },
    'Opening' => { width: 48.0, height: 48.0, sill: 24.0 }
  }.freeze

  # SketchUp's legacy global axis constants (X_AXIS/Y_AXIS/Z_AXIS) are not
  # defined in this runtime; own constants remove all dependence on them.
  X_AXIS = Geom::Vector3d.new(1, 0, 0).freeze
  Y_AXIS = Geom::Vector3d.new(0, 1, 0).freeze
  Z_AXIS = Geom::Vector3d.new(0, 0, 1).freeze

  module CutEngine
    PRIDE_IN = 1.0 # cutter starts this far outside the face so clip never starts coplanar

    # origin/n/u/v in world coords; path = Group/ComponentInstance chain from root to the
    # container owning the face ([] for top level). Returns false on an aborted no-op cut.
    # ponytail: assumes rigid or axis-scaled containers; non-uniform scale on a rotated
    # wall group is the known ceiling — upgrade path: full affine handling right here.
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
        raise 'WallCutter: could not build cutter prism' unless prism
        ents.clip([Geom::Transformation.new], [prism], :difference, false)
        prism.erase! if prism.valid?
        if ents.length == before
          model.abort_operation # no-op guard: clip removed nothing
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

    # Rectangular base centered on o (PRIDE_IN outside the face along -n), extruded d along n.
    def self.build_prism(ents, o, n, u, v, w, h, d)
      un = n.normalize
      ut = u.normalize
      vt = v.normalize
      pr = PRIDE_IN * n.length
      s  = Geom::Point3d.new(o.x - un.x * pr, o.y - un.y * pr, o.z - un.z * pr)
      pts = [[-1, -1], [1, -1], [1, 1], [-1, 1]].map do |su, sv|
        corner(s, ut, su * w / 2.0, vt, sv * h / 2.0)
      end
      g    = ents.add_group
      face = g.entities.add_face(pts)
      return nil unless face
      face.reverse! if face.normal % un < 0
      face.pushpull(d + pr)
      g
    end

    # Explicit arithmetic: Point3d#offset is destructive, so never chain it off a shared point.
    def self.corner(base, u, ud, v, vd)
      Geom::Point3d.new(base.x + u.x * ud + v.x * vd,
                        base.y + u.y * ud + v.y * vd,
                        base.z + u.z * ud + v.z * vd)
    end
  end
end
