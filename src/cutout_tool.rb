# frozen_string_literal: true
require 'json'

module WallCutter
  # Pure in-plane coordinate frame of a face, in WORLD coords via +tr+ (identity for
  # top-level faces; the instance chain's transform for faces inside groups/components).
  # v = world-Z projected onto the plane; degenerate for horizontal faces ->
  # u = longest outer-loop edge, v = u x n.
  class FaceFrame
    attr_reader :n, :u, :v, :ref, :min_u, :max_u, :min_v, :max_v

    def initialize(face, into_normal, tr = Geom::Transformation.new)
      @n = into_normal.normalize
      dn = Z_AXIS % @n
      vv = Geom::Vector3d.new(Z_AXIS.x - @n.x * dn, Z_AXIS.y - @n.y * dn, Z_AXIS.z - @n.z * dn)
      if vv.length < 0.001
        edge = face.outer_loop.edges.max_by(&:length)
        @u = edge.line[1].transform(tr).normalize
        @v = @n.cross(@u).normalize
      else
        @v = vv.normalize
        @u = @n.cross(@v).normalize
      end
      pts  = face.outer_loop.vertices.map { |vt| vt.position.transform(tr) }
      @ref = pts.first
      us = pts.map { |p| (p - @ref) % @u }
      vs = pts.map { |p| (p - @ref) % @v }
      @min_u, @max_u = us.minmax
      @min_v, @max_v = vs.minmax
    end

    def avail_w
      max_u - min_u
    end

    def avail_h
      max_v - min_v
    end

    def fits?(w, h)
      w <= avail_w && h <= avail_h
    end

    # In-plane coords of a world point, origin = the face's reference vertex.
    def plane_coords(pt)
      [((pt - @ref) % @u), ((pt - @ref) % @v)]
    end

    # World point at the opening's CENTER. Default horizontally centered; sill/left
    # measured from the face's bounding corners (spec positioning rules).
    def center_origin(w, h, sill = nil, left = nil)
      left ||= (avail_w - w) / 2.0
      sill ||= 0.0
      cu = min_u + left + w / 2.0
      cv = min_v + sill + h / 2.0
      CutEngine.corner(@ref, @u, cu, @v, cv)
    end
  end

  class CutoutTool
    # --- units: internal lengths are always inches -------------------------------
    UNIT_FACTORS = { 'in' => 1.0, 'cm' => 2.54, 'mm' => 25.4 }.freeze
    LEN_RE = /\A\s*(-?[\d.]+)\s*(cm|mm|inch|in|")?\s*\z/i

    # "11 cm" / "110 mm" / '4 in' / '4"' / "36" -> [inches, unit]; nil if not a length.
    def self.parse_len(str)
      m = LEN_RE.match(str.to_s)
      return nil unless m
      val = m[1].to_f
      return nil if val.negative?
      unit = case m[2].to_s.downcase
             when 'cm', 'mm' then m[2].downcase
             else 'in'
             end
      [val / UNIT_FACTORS[unit], unit]
    end

    def self.fmt_len(inches, unit)
      v = (inches * UNIT_FACTORS[unit]).round(3)
      v = v.to_i if (v - v.to_i).abs < 1e-9
      "#{v} #{unit}"
    end

    # --- drag math (pure): mouse at (mu, mv) from the face's min corner ----------
    MIN_SIZE = 1.0
    # move (center dot) is checked LAST so edge handles win overlapping grabs
    HANDLES = { nw: [-1, 1], n: [0, 1], ne: [1, 1], e: [1, 0],
                se: [1, -1], s: [0, -1], sw: [-1, -1], w: [-1, 0],
                move: [0, 0] }.freeze

    def self.clamp(v, lo, hi)
      [[v, lo].max, hi].min
    end

    def self.drag_resize(handle, mu, mv, left, sill, w, h, avail_w, avail_h)
      if handle == :move
        return [clamp(mu, 0.0, avail_w - w), clamp(mv, 0.0, avail_h - h), w, h]
      end
      r = left + w
      t = sill + h
      left = mu if %i[w nw sw].include?(handle)
      r    = mu if %i[e ne se].include?(handle)
      sill = mv if %i[s sw se].include?(handle)
      t    = mv if %i[n nw ne].include?(handle)
      left = clamp(left, 0.0, avail_w - MIN_SIZE)
      sill = clamp(sill, 0.0, avail_h - MIN_SIZE)
      r = clamp(r, left + MIN_SIZE, avail_w)
      t = clamp(t, sill + MIN_SIZE, avail_h)
      [left, sill, r - left, t - sill]
    end

    HTML = <<~HTML
      <!DOCTYPE html><html><head><meta charset="utf-8"><style>
      body{font:13px -apple-system;margin:10px}label{display:block;margin:7px 0 1px}
      input,select{width:100%;box-sizing:border-box;padding:3px}
      button{width:100%;margin-top:12px;padding:7px;font-weight:600}
      </style></head><body onload="sketchup.ready()">
      <label>Preset<select id="preset" onchange="sketchup.preset(this.value)"></select></label>
      <label>Width (in / cm / mm)<input id="w" type="text" onchange="push()"></label>
      <label>Height (in / cm / mm)<input id="h" type="text" onchange="push()"></label>
      <label>Sill from bottom<input id="sill" type="text" placeholder="0" onchange="push()"></label>
      <label>Left offset<input id="left" type="text" placeholder="centered" onchange="push()"></label>
      <label>Depth<input id="depth" type="text" placeholder="auto through wall" onchange="push()"></label>
      <button onclick="sketchup.cut()">Cut</button>
      <script>
      function setPresets(p){var s=document.getElementById('preset');
        for(var k in p){var o=document.createElement('option');o.value=k;o.textContent=k;s.appendChild(o);}}
      var IDS={width:'w',height:'h',sill:'sill',left:'left',depth:'depth'};
      function fillForm(v){for(var k in IDS){var e=document.getElementById(IDS[k]);
        if(e&&v[k]!=null)e.value=v[k];}}
      function g(id){return document.getElementById(id).value;}
      function push(){sketchup.params(JSON.stringify({width:g('w'),height:g('h'),
        sill:g('sill'),left:g('left'),depth:g('depth')}));}
      </script></body></html>
    HTML

    CURSOR = File.join(ICON_DIR, 'cursor.png')

    def self.activate
      model = Sketchup.active_model
      return unless WallCutter.top_level_ok?
      model.select_tool(new)
    end

    PROBE = '/Users/mengly/Documents/Qoder/wallcutter/dev/cursor_probe.txt'

    def onSetCursor(view, _flags, _x, _y)
      unless @cursor_probed
        @cursor_probed = true
        File.write(PROBE, "onSetCursor fired #{Time.now} try set_cursor...\n") rescue nil
      end
      try_custom_cursor(view)
    end

    def try_custom_cursor(view)
      return if @cursor_done
      @cursor_done = true
      view.set_cursor(CURSOR)
      File.write(PROBE, "set_cursor(#{CURSOR}) accepted #{Time.now}\n") rescue nil
    rescue StandardError => e
      # PNG path rejected by this build; fall back to built-in cursor IDs, log all.
      results = [0, 1, 67, 641].map do |id|
        begin
          view.set_cursor(id)
          "id #{id}: ok"
        rescue StandardError => e2
          "id #{id}: #{e2.class}"
        end
      end
      File.write(PROBE, "png raised #{e.class}; ints -> #{results.join('; ')}\n") rescue nil
    end

    def initialize
      @face   = nil
      @frame  = nil
      @params = PRESETS['Window'].merge(left: nil, depth: nil)
      @units  = { width: 'in', height: 'in', sill: 'in', left: 'in', depth: 'in' }
      @drag   = nil
      @draw_err_shown = false
    end

    def activate
      Sketchup.status_text = 'WallCutter: click a wall face, drag edges to resize, Enter to cut'
      try_custom_cursor(Sketchup.active_model.active_view)
      show_dialog
    end

    def deactivate(view)
      @dlg.close if @dlg && @dlg.visible?
      Sketchup.status_text = ''
      view.invalidate
    end

    def onCancel(_reason, view)
      Sketchup.active_model.select_tool(nil)
      view.invalidate
    end

    # Mouse pixel -> [u, v] in face coords measured from the face's min corner.
    def plane_uv(view, x, y)
      ray = view.pickray(x, y)
      return nil unless ray
      frame = current_frame(view)
      hit = Geom.intersect_line_plane(ray, [frame.ref, frame.n])
      return nil unless hit
      pu, pv = frame.plane_coords(hit)
      [pu - frame.min_u, pv - frame.min_v]
    end

    def onLButtonDown(_flags, x, y, view)
      # best_picked stops at a Group/Component wrapper, so walk the pick path to the
      # leaf face; walls inside groups must be pickable per the spec.
      @frame = nil
      @drag_off = nil
      if @face&.valid? && (@drag = hit_handle(view, x, y))
        materialize_offsets(current_frame(view))
        if @drag == :move
          uv = plane_uv(view, x, y)
          @drag_off = uv && [uv[0] - @params[:left].to_f, uv[1] - @params[:sill].to_f]
        end
        return
      end
      ph = view.pick_helper
      ph.do_pick(x, y)
      @face = (ph.path_at(0) || []).grep(Sketchup::Face).last
      best = ph.best_picked
      @face ||= best if best.is_a?(Sketchup::Face)
      @draw_err_shown = false
      view.invalidate
    end

    def onMouseMove(_flags, x, y, view)
      return unless @drag && @face&.valid?
      mu, mv = plane_uv(view, x, y)
      return unless mu
      if @drag == :move && @drag_off
        mu -= @drag_off[0]
        mv -= @drag_off[1]
      end
      frame = current_frame(view)
      w, h = @params[:width].to_f, @params[:height].to_f
      @params[:left], @params[:sill], @params[:width], @params[:height] =
        self.class.drag_resize(@drag, mu, mv,
                               @params[:left].to_f, @params[:sill].to_f, w, h,
                               frame.avail_w, frame.avail_h)
      Sketchup.status_text =
        if @drag == :move
          format('WallCutter: at left %0.1f", sill %0.1f" — Enter to cut',
                 @params[:left], @params[:sill])
        else
          format('WallCutter: %0.1f x %0.1f (in) — Enter to cut', w, h)
        end
      view.invalidate
    end

    def onLButtonUp(_flags, _x, _y, view)
      return unless @drag
      @drag = nil
      push_form
    end

    def onReturn(view)
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
      ok = CutEngine.cut(origin, frame.n, frame.u, frame.v, w, h, @params[:depth],
                         path: WallCutter.face_path(@face))
      report(ok ? 'cut done — click next face or Esc' : 'cut removed nothing — set depth manually')
      view.invalidate
    rescue StandardError => e
      report("error: #{e.message}")
    end

    def draw(view)
      return unless @face&.valid?
      frame = current_frame(view)
      w = @params[:width].to_f
      h = @params[:height].to_f
      return unless frame.fits?(w, h)
      o = frame.center_origin(w, h, @params[:sill], @params[:left])
      pts = HANDLES.keys.map { |name| handle_point(o, frame, w, h, name) }
      corners = HANDLES.values.select { |su, sv| su.abs == 1 && sv.abs == 1 }
                            .map { |su, sv| CutEngine.corner(o, frame.u, su * w / 2.0, frame.v, sv * h / 2.0) }
      color = Sketchup::Color.new(0, 180, 255)
      view.drawing_color = color
      view.draw(GL_LINE_LOOP, corners)
      view.draw_points(pts, 5, 2, color)
    rescue StandardError => e
      unless @draw_err_shown
        @draw_err_shown = true
        puts "[WallCutter] draw error: #{e.class}: #{e.message}"
        puts(e.backtrace.first(4).map { |l| "  #{l}" })
        report("draw error (see Ruby Console): #{e.class}: #{e.message}")
      end
    end

    # ponytail: rebuilt per draw frame; outer loops are tiny, cache if walls get
    # 10k-vertex profiles.
    def current_frame(view)
      @frame ||= begin
        path    = WallCutter.face_path(@face)
        tr      = CutEngine.world_to_local(path)
        n_world = @face.normal.transform(tr).normalize
        into    = (n_world % view.camera.direction < 0) ? n_world.reverse : n_world
        FaceFrame.new(@face, into, tr)
      end
    end

    def handle_point(o, frame, w, h, name)
      su, sv = HANDLES[name]
      CutEngine.corner(o, frame.u, su * w / 2.0, frame.v, sv * h / 2.0)
    end

    def hit_handle(view, x, y)
      frame = current_frame(view)
      w = @params[:width].to_f
      h = @params[:height].to_f
      return nil unless frame.fits?(w, h)
      o = frame.center_origin(w, h, @params[:sill], @params[:left])
      HANDLES.each do |name, _|
        sc = view.screen_coords(handle_point(o, frame, w, h, name))
        return name if (x - sc.x).abs <= 8 && (y - sc.y).abs <= 8
      end
      nil
    end

    # nil left/sill mean "centered / default" — pin them to real numbers before a drag
    def materialize_offsets(frame)
      @params[:left] = (frame.avail_w - @params[:width]) / 2.0 if @params[:left].nil?
      @params[:sill] ||= 0.0
    end

    def report(msg)
      Sketchup.status_text = "WallCutter: #{msg}"
      nil
    end

    # --- dialog ------------------------------------------------------------------
    def show_dialog
      @dlg = UI::HtmlDialog.new(dialog_title: 'WallCutter', preferences_name: 'wallcutter',
                                width: 260, height: 330, style: UI::HtmlDialog::STYLE_DIALOG)
      @dlg.set_html(HTML)
      @dlg.add_action_callback('ready') do |_c, _|
        @dlg.execute_script("setPresets(#{PRESETS.to_json})")
        push_form
      end
      @dlg.add_action_callback('preset') { |_c, name| apply_preset(name.to_s) }
      @dlg.add_action_callback('params') { |_c, raw| update_params(raw) }
      @dlg.add_action_callback('cut') { |_c, _| commit_cut(Sketchup.active_model.active_view) }
      @dlg.show
    end

    # Send current params to the panel, each field shown in the unit it was typed in.
    def push_form
      return unless @dlg&.visible?
      vals = {}
      %i[width height sill left depth].each do |k|
        v = @params[k]
        vals[k.to_s] = v ? self.class.fmt_len(v.to_f, @units[k]) : ''
      end
      @dlg.execute_script("fillForm(#{vals.to_json})")
    end

    def update_params(raw)
      vals = JSON.parse(raw.to_s)
      %w[width height].each { |k| assign_len(k, vals[k], min_exclusive: 0.0) }
      %w[sill left].each   { |k| assign_len(k, vals[k], min_exclusive: nil) }
      assign_len('depth', vals['depth'], min_exclusive: 0.0)
      @frame = nil
      Sketchup.active_model.active_view.invalidate
    rescue JSON::ParserError
      report('bad panel payload — ignored')
    end

    def assign_len(key, incoming, min_exclusive:)
      text = incoming.to_s.strip
      sym  = key.to_sym
      return @params[sym] = nil if text.empty? && sym != :width && sym != :height
      parsed = self.class.parse_len(text)
      unless parsed
        report("#{key}: \"#{text}\" not a length (try 36, 11 cm, 4 in)")
        return
      end
      inches = parsed[0]
      if min_exclusive && inches <= min_exclusive
        report("#{key}: must be greater than 0")
        return
      end
      @params[sym] = inches
      @units[sym]  = parsed[1]
    end

    def apply_preset(name)
      @params = (PRESETS[name] || PRESETS['Window']).merge(left: nil, depth: nil)
      @units = { width: 'in', height: 'in', sill: 'in', left: 'in', depth: 'in' }
      @frame = nil
      push_form
      Sketchup.active_model.active_view.invalidate
    end
  end
end
