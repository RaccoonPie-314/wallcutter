# frozen_string_literal: true
require 'sketchup.rb'
require 'json'

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
    # Why the last cut removed nothing. Real-world models fail for structural reasons
    # (single-surface walls, skins in separate components, openings straddling trim),
    # and 'removed nothing' on its own sends the user guessing.
    class << self
      attr_accessor :last_failure
    end

    PRIDE_IN = 1.0 # overshoot past the exit face so the hole comes out clean
    # Auto-depth stops at air gaps wider than this: a wall cavity is under a foot,
    # a room behind the wall is not — the far wall must not get the same window.
    CAVITY_MAX = 12.0


    # origin/n/u/v in world coords; path = Group/ComponentInstance chain from root to the
    # container owning the face ([] for top level). Returns false if nothing could be cut.
    # depth = nil means AUTO: cut through the clicked wall's layers, stopping at the
    # first air gap wider than CAVITY_MAX (a room behind the wall ends the cut).
    # No raytest — raytest from inside solids is unreliable in this build.
    def self.cut(origin, n, u, v, width, height, depth = nil, path: [])
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
      model.start_operation('WallCutter cut', true)
      self.last_failure = nil
      begin
        # Faces parallel to the cutter, sorted along the into-wall axis; consecutive
        # pairs are the entry/exit planes of one solid layer (layered walls included).
        planes = ents.grep(Sketchup::Face).select { |f|
          f.normal.cross(un).length < 0.001
        }.map { |f| [plane_t(f, o, un), f] }
          .select { |t, f| t >= -0.001 && t <= 12_000.0 && bounds_hold?(f.bounds, o, un, ut, vt, t, wl, hl) }
          .sort_by(&:first)
        dl = if depth
               depth * nl.length
             elsif planes.any?
               auto_depth_limit(planes) + PRIDE_IN + 1.0
             else
               24.0
             end
        planes.select! { |t, _f| t <= dl + 0.001 }
        if planes.empty?
          self.last_failure = 'no face to cut at this depth in this container — check the ' \
                              'Depth field, or which group the surface actually lives in'
        end
        cut_any = false
        layers = []
        i = 0
        while i < planes.size
          t_in = planes[i][0]
          if i + 1 >= planes.size # trailing lone face: a finish with no thickness
            if cut_skin(ents, planes[i][1], o, un, ut, vt, wl, hl, t_in)
              cut_any = true
              layers << [t_in, t_in]
            end
            break
          end
          t_out = planes[i + 1][0]
          if t_out - t_in < 0.001
            i += 1 # duplicate coplanar faces (zero-thickness pair): advance by one
            next
          end
          if cut_layer(ents, planes[i][1], o, un, ut, vt, wl, hl, t_in, t_out - t_in)
            cut_any = true
            layers << [t_in, t_out]
          end
          i += 2 # pushpull already holed the exit face; skip it as a future entry
        end
        # The sweeper cleans pushpull residue; a skin cut has none, and sweeping its
        # footprint would eat unrelated small faces sitting near the surface.
        clear_hole_debris(ents, o, un, ut, vt, wl, hl, dl) if layers.any? { |a, b| b - a > 0.001 }
        if cut_any
          # Inside the operation: model attributes undo with it, so Ctrl-Z on a cut
          # drops that cut's registry entry too.
          record_opening(origin, n, u, v, wl, hl, layers, path, model)
          model.commit_operation
          true
        else
          model.abort_operation
          self.last_failure ||= 'no layer accepted the opening — it straddles seams or trim; ' \
                                'nudge it clear or shrink it'
          false
        end
      rescue StandardError
        model.abort_operation
        raise
      end
    end

    # Auto depth must cut the wall the user clicked, not every parallel wall in the
    # model (a shed's far wall used to receive the same window). Walk the entry/exit
    # pairs front to back exactly like the cut loop and stop before an air gap wider
    # than a wall cavity. planes is non-empty (guarded by the caller).
    def self.auto_depth_limit(planes)
      dl = planes.first[0]
      prev_exit = nil
      i = 0
      while i + 1 < planes.size
        t_in  = planes[i][0]
        t_out = planes[i + 1][0]
        if t_out - t_in < 0.001
          i += 1 # duplicate coplanar faces: same skip rule as the cut loop
          next
        end
        break if prev_exit && t_in - prev_exit > CAVITY_MAX
        dl = t_out
        prev_exit = t_out
        i += 2
      end
      # A lone face left at the end is a zero-thickness skin: include it when it belongs
      # to this wall (same gap rule as layers), leave it out when it is a distant surface.
      dl = planes[i][0] if i < planes.size &&
                           (prev_exit ? planes[i][0] - prev_exit : 0.0) <= CAVITY_MAX
      dl
    end

    # --- hole registry: one entry per successful cut, kept as JSON on the model so it
    # survives save/reopen. Records are geometry-parameterised (not face references),
    # so they stay valid after undo/redo churn, moves, or a model reload.
    # ponytail: origin/n/u/v are world-space, layers are plane offsets measured along
    # the local un; identical for rigid groups, off by the group scale for scaled ones.
    # Upgrade path: store world-space plane offsets if scaled wall groups appear.
    def self.openings(model = Sketchup.active_model)
      JSON.parse(model.get_attribute('WallCutter', 'openings', '[]'))
    rescue JSON::ParserError
      []
    end

    def self.record_opening(origin, n, u, v, w, h, layers, path, model)
      list = openings(model)
      rec = {
        'id'     => (list.map { |r| r['id'].to_i }.max || 0) + 1,
        'origin' => origin.to_a, 'n' => n.to_a, 'u' => u.to_a, 'v' => v.to_a,
        'w' => w, 'h' => h,
        'depth'  => layers.map { |_t_in, t_out| t_out }.max || 0.0,
        'layers' => layers,
        'pids'   => path.map(&:persistent_id)
      }
      model.set_attribute('WallCutter', 'openings', JSON.generate(list << rec))
      rec
    end

    # Resolve a recorded hole back to its container. 2026 has no find_entity_by_pid,
    # so walk the stored persistent_ids by scanning each level's entities.
    # Returns the path array, or nil when a group in the chain is gone.
    def self.hole_path(model, rec)
      ents = model.entities
      path = []
      (rec['pids'] || []).each do |pid|
        e = ents.find { |x| x.respond_to?(:persistent_id) && x.persistent_id == pid }
        return nil unless e.respond_to?(:entities)
        path << e
        ents = e.entities
      end
      path
    end

    # Refill is the inverse of what cut_layer leaves behind: lining faces inside the
    # layer span plus a ring hole in each skin. Erase the lining, re-face both planes
    # with the recorded rect, then erase the shared boundary edges so the coplanar
    # pieces merge back into whole skins. Returns false (caller aborts) when a plane
    # can't be closed - geometry the user changed around the hole.
    def self.refill(ents, o, un, ut, vt, w, h, layers)
      done = false
      layers.each do |t_in, t_out|
        if t_out - t_in < 0.001 # zero-thickness skin: one plane, no lining to erase
          done ||= close_plane(ents, o, un, ut, vt, w, h, t_in)
          next
        end
        lining = ents.grep(Sketchup::Face).select do |f|
          d = f.bounds.center - o
          off = d % un
          next false unless off > t_in + 0.001 && off < t_out - 0.001
          pu = d - Geom::Vector3d.new(un.x * off, un.y * off, un.z * off)
          (pu % ut).abs <= w / 2.0 + 0.5 && (pu % vt).abs <= h / 2.0 + 0.5
        end
        ents.erase_entities(lining) unless lining.empty?
        a = close_plane(ents, o, un, ut, vt, w, h, t_in)
        b = close_plane(ents, o, un, ut, vt, w, h, t_out)
        done ||= (a && b)
      end
      done
    end

    # One skin: once the lining is gone the opening's 4 boundary edges belong to the
    # ring face alone, so erasing them lets that face re-span the rect and the hole
    # welds shut. (add_face is NOT the way in: on an existing inner loop it returns the
    # ring itself instead of a filler face - probe-verified, no new face, 8 edges.)
    # Any boundary edge still carrying a second face means foreign geometry borders the
    # opening, or the opening sits on the wall's own edge -> refuse rather than half-erase.
    def self.close_plane(ents, o, un, ut, vt, w, h, t)
      rim = rim_edges(ents, o, un, ut, vt, w, h, t)
      return false unless rim.size == 4 && rim.all? { |e| e.faces.size == 1 }
      ents.erase_entities(rim)
      true
    end

    # The 4 edges framing the recorded opening at plane t. They exist only while the
    # hole is open, so they double as the record's liveness test.
    # ponytail: linear edge scan per check; index by midpoint if models get huge.
    def self.rim_edges(ents, o, un, ut, vt, w, h, t)
      center = Geom::Point3d.new(o.x + un.x * t, o.y + un.y * t, o.z + un.z * t)
      pts = opening_rect(center, ut, vt, w, h)
      ents.grep(Sketchup::Edge).select do |e|
        vs = e.vertices
        next false unless vs.size == 2
        next false unless vs.all? { |v| ((v.position - center) % un).abs < 0.01 }
        vs.count { |v| pts.any? { |pt| (v.position - pt).length < 0.01 } } == 2
      end
    end

    # Is this record's hole still actually open? A refilled or hand-deleted hole must
    # stop being selectable, or a stale record eats the click meant for the wall behind
    # it (recorded holes survive a model wipe as pure numbers, so this cannot be skipped).
    def self.hole_open?(model, rec)
      return false unless rec
      path = hole_path(model, rec)
      return false unless path
      ents = path.empty? ? model.entities : path.last.entities
      inv  = world_to_local(path).inverse
      o  = Geom::Point3d.new(*rec['origin']).transform(inv)
      un = Geom::Vector3d.new(*rec['n']).transform(inv).normalize
      ut = Geom::Vector3d.new(*rec['u']).transform(inv).normalize
      vt = Geom::Vector3d.new(*rec['v']).transform(inv).normalize
      t_in = rec['layers'].map { |a| a[0].to_f }.min
      rim_edges(ents, o, un, ut, vt, rec['w'].to_f, rec['h'].to_f, t_in).size == 4
    rescue StandardError
      false
    end

    # Refill a recorded hole as one undo step and forget its registry entry.
    def self.refill_hole(model, rec)
      return false unless rec
      path = hole_path(model, rec)
      return false unless path
      ents = path.empty? ? model.entities : path.last.entities
      inv  = world_to_local(path).inverse
      o  = Geom::Point3d.new(*rec['origin']).transform(inv)
      un = Geom::Vector3d.new(*rec['n']).transform(inv).normalize
      ut = Geom::Vector3d.new(*rec['u']).transform(inv).normalize
      vt = Geom::Vector3d.new(*rec['v']).transform(inv).normalize
      layers = rec['layers'].map { |t_in, t_out| [t_in.to_f, t_out.to_f] }
      model.start_operation('WallCutter refill', true)
      begin
        ok = refill(ents, o, un, ut, vt, rec['w'].to_f, rec['h'].to_f, layers)
        if ok
          drop_opening(model, rec['id'])
          model.commit_operation
        else
          model.abort_operation # leaves no floating filler face behind
        end
        ok
      rescue StandardError
        model.abort_operation
        raise
      end
    end

    def self.drop_opening(model, id)
      list = openings(model).reject { |r| r['id'] == id }
      model.set_attribute('WallCutter', 'openings', JSON.generate(list))
    end

    def self.world_to_local(path)
      path.inject(Geom::Transformation.new) { |t, inst| t * inst.transformation }
    end

    # Plane parameter (inches along un from o) of a face parallel to un.
    def self.plane_t(face, o, un)
      (face.bounds.center - o) % un
    end

    # The opening's 4 corners, centred on +center+ in the face frame.
    def self.opening_rect(center, ut, vt, w, h)
      [[-1, -1], [1, -1], [1, 1], [-1, 1]].map do |su, sv|
        corner(center, ut, su * w / 2.0, vt, sv * h / 2.0)
      end
    end

    # Split +target+ with the opening rect and return the inner piece, or nil when the
    # rect does not really land on that face: the split only counts if the new face
    # shares an edge with the target, otherwise add_face dropped a floating rect.
    def self.split_face(ents, target, center, rect, area)
      rf = ents.add_face(rect)
      return nil unless rf
      inner  = rect_face_at(ents, center, area)
      shared = inner && target.valid? && inner.edges.any? { |e| target.edges.include?(e) }
      unless inner && shared
        rf.erase! if rf.valid?
        return nil
      end
      inner
    end

    # A finish layer with no thickness: one face, nothing behind it. Split it and delete
    # the inner piece - a hole in the skin, recorded as a zero-thickness layer so Refill
    # welds it shut through the same rim-edge path as a punched layer.
    def self.cut_skin(ents, target, o, un, ut, vt, w, h, t)
      center = Geom::Point3d.new(o.x + un.x * t, o.y + un.y * t, o.z + un.z * t)
      inner = split_face(ents, target, center, opening_rect(center, ut, vt, w, h), w * h)
      return false unless inner
      inner.erase!
      true
    end

    def self.cut_layer(ents, target, o, un, ut, vt, w, h, t, thickness)
      center = Geom::Point3d.new(o.x + un.x * t, o.y + un.y * t, o.z + un.z * t)
      area  = w * h
      rect  = opening_rect(center, ut, vt, w, h)
      inner = split_face(ents, target, center, rect, area)
      return false unless inner
      dist = thickness + PRIDE_IN
      dist = -dist if inner.normal % un < 0 # pushpull travels along the face normal
      inner.pushpull(dist)
      # API pushpull EXTRUDES: the moved face caps the hole at exit+PRIDE, and the far
      # skin may stay whole or keep a plug. Clear every rect-sized face capping the hole
      # column at/around the exit plane; if the far skin is still whole, split it with
      # the same rect first, then clear again.
      exit_center = Geom::Point3d.new(center.x + un.x * thickness,
                                      center.y + un.y * thickness,
                                      center.z + un.z * thickness)
      clear_hole_caps(ents, exit_center, un, area)
      # Unconditional exit split: clearing a membrane beyond the far skin must not hide
      # the still-whole exit face. rect2 splits it; if the hole was already open, the
      # stray face it creates is cleared by the second pass.
      rect2 = rect.map { |pt| Geom::Point3d.new(pt.x + un.x * thickness,
                                                pt.y + un.y * thickness,
                                                pt.z + un.z * thickness) }
      ents.add_face(rect2)
      clear_hole_caps(ents, exit_center, un, area)
      true
    end

    # Erase any face blocking the hole at or just past the exit plane (pushpull's moved
    # face, an exit plug, or both). Center must sit on the hole axis within 0.5".
    def self.clear_hole_caps(ents, exit_center, un, area)
      cleared = false
      ents.grep(Sketchup::Face).each do |f|
        next unless f.valid?
        next if (f.area - area).abs > area * 0.05 + 0.5
        c = f.bounds.center
        off = (c - exit_center) % un
        next unless off.abs <= PRIDE_IN + 0.5
        proj = Geom::Point3d.new(exit_center.x + un.x * off,
                                 exit_center.y + un.y * off,
                                 exit_center.z + un.z * off)
        next unless (c - proj).length < 0.5
        f.erase!
        cleared = true
      end
      cleared
    end

    # This build's pushpull sometimes leaves rim strips (1in-wide slivers) or an
    # unpushed inner plug inside the hole column, depending on face winding. Sweep the
    # opening footprint at all depths: erase faces too small to be jambs (area < min
    # edge x 1.5) or plug-sized faces; rings and full jambs always survive both tests.
    def self.clear_hole_debris(ents, o, un, ut, vt, w, h, dl)
      ents.grep(Sketchup::Face).each do |f|
        next unless f.valid?
        small  = f.area < [w, h].min * 1.5
        plug   = (f.area - w * h).abs < w * h * 0.1
        next unless small || plug
        d = f.bounds.center - o
        off = d % un
        next unless off >= -2.0 && off <= dl + 2.0
        pu = d - Geom::Vector3d.new(un.x * off, un.y * off, un.z * off)
        next unless (pu % ut).abs <= w / 2.0 + 0.5 && (pu % vt).abs <= h / 2.0 + 0.5
        f.erase!
      end
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
