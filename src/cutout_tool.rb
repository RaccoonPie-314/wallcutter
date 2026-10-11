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
      vv = Z_AXIS - @n * (Z_AXIS % @n)
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
    HTML = <<~HTML
      <!DOCTYPE html><html><head><meta charset="utf-8"><style>
      body{font:13px -apple-system;margin:10px}label{display:block;margin:7px 0 1px}
      input,select{width:100%;box-sizing:border-box;padding:3px}
      button{width:100%;margin-top:12px;padding:7px;font-weight:600}
      </style></head><body onload="sketchup.ready()">
      <label>Preset<select id="preset" onchange="sketchup.preset(this.value)"></select></label>
      <label>Width (in)<input id="w" type="number" onchange="push()"></label>
      <label>Height (in)<input id="h" type="number" onchange="push()"></label>
      <label>Sill from bottom (in)<input id="sill" type="number" placeholder="0" onchange="push()"></label>
      <label>Left offset (in)<input id="left" type="number" placeholder="centered" onchange="push()"></label>
      <label>Depth (in)<input id="depth" type="number" placeholder="auto through wall" onchange="push()"></label>
      <button onclick="sketchup.cut()">Cut</button>
      <script>
      function setPresets(p){var s=document.getElementById('preset');
        for(var k in p){var o=document.createElement('option');o.value=k;o.textContent=k;s.appendChild(o);}}
      function fillForm(v){document.getElementById('w').value=v.width;
        document.getElementById('h').value=v.height;
        document.getElementById('sill').value=v.sill||0;
        document.getElementById('left').value=(v.left==null?'':v.left);
        document.getElementById('depth').value=(v.depth==null?'':v.depth);}
      function g(id){return document.getElementById(id).value;}
      function push(){sketchup.params(JSON.stringify({width:g('w'),height:g('h'),
        sill:g('sill'),left:g('left'),depth:g('depth')}));}
      </script></body></html>
    HTML

    def self.activate
      model = Sketchup.active_model
      return unless WallCutter.top_level_ok?
      model.select_tool(new)
    end

    def initialize
      @face   = nil
      @frame  = nil
      @params = PRESETS['Window'].merge(left: nil, depth: nil)
    end

    def activate
      puts '[WallCutter] tool activate'
      Sketchup.status_text = 'WallCutter: click a wall face, adjust in panel, Enter to cut'
      show_dialog
    end

    def deactivate(view)
      puts '[WallCutter] tool deactivate'
      @dlg.close if @dlg && @dlg.visible?
      Sketchup.status_text = ''
      view.invalidate
    end

    def onCancel(_reason, view)
      Sketchup.active_model.select_tool(nil)
      view.invalidate
    end

    def onLButtonDown(_flags, x, y, view)
      ph = view.pick_helper
      ph.do_pick(x, y)
      # best_picked stops at a Group/Component wrapper, so walk the pick path to the
      # leaf face; walls inside groups must be pickable per the spec.
      @frame = nil
      path = (ph.path_at(0) || [])
      @face = path.grep(Sketchup::Face).last
      best = ph.best_picked
      @face ||= best if best.is_a?(Sketchup::Face)
      puts "[WallCutter] click #{x},#{y} best=#{best.class} path=#{path.map { |e| e.class }.inspect} face=#{@face.class}"
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
      view.invalidate
    rescue StandardError => e
      report("error: #{e.message}")
    end

    # Ray from just inside the face along the into-wall direction: first hit behind
    # the front skin is the back side of the deepest layer -> "through wall" for free.
    def auto_depth(origin, n)
      probe = Geom::Point3d.new(origin.x + n.x * 0.01, origin.y + n.y * 0.01,
                                origin.z + n.z * 0.01)
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
      pts = [[-1, -1], [1, -1], [1, 1], [-1, 1]].map do |su, sv|
        CutEngine.corner(o, frame.u, su * w / 2.0, frame.v, sv * h / 2.0)
      end
      color = Sketchup::Color.new(0, 180, 255)
      view.drawing_color = color
      view.draw(GL_LINE_LOOP, pts)
      view.draw_points(pts, 6, 2, color)
    rescue StandardError => e
      unless @draw_err_shown # report the full error once, then stay quiet per frame
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

    def show_dialog
      @dlg = UI::HtmlDialog.new(dialog_title: 'WallCutter', preferences_name: 'wallcutter',
                                width: 260, height: 330, style: UI::HtmlDialog::STYLE_DIALOG)
      @dlg.set_html(HTML)
      @dlg.add_action_callback('ready') do |_c, _|
        @dlg.execute_script("setPresets(#{PRESETS.to_json})")
        @dlg.execute_script("fillForm(#{@params.to_json})")
      end
      @dlg.add_action_callback('preset') { |_c, name| apply_preset(name.to_s) }
      @dlg.add_action_callback('params') { |_c, raw| update_params(raw) }
      @dlg.add_action_callback('cut') { |_c, _| commit_cut(Sketchup.active_model.active_view) }
      @dlg.show
    end

    def update_params(raw)
      vals = JSON.parse(raw.to_s)
      @params[:width]  = vals['width'].to_f  if vals['width'].to_f  > 0
      @params[:height] = vals['height'].to_f if vals['height'].to_f > 0
      @params[:sill]   = vals['sill'].to_s.empty?  ? nil : vals['sill'].to_f
      @params[:left]   = vals['left'].to_s.empty?  ? nil : vals['left'].to_f
      @params[:depth]  = vals['depth'].to_s.empty? ? nil : vals['depth'].to_f
      @frame = nil
      Sketchup.active_model.active_view.invalidate
    rescue JSON::ParserError
      report('bad panel payload — ignored')
    end

    def apply_preset(name)
      @params = (PRESETS[name] || PRESETS['Window']).merge(left: nil, depth: nil)
      @frame = nil
      @dlg.execute_script("fillForm(#{@params.to_json})") if @dlg&.visible?
      Sketchup.active_model.active_view.invalidate
    end

    def report(msg)
      Sketchup.status_text = "WallCutter: #{msg}"
      nil
    end
  end
end
