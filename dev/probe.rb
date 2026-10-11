# SketchUp 2026 boolean-API probe. Run in a NEW model from Ruby Console:
#   load '/Users/mengly/Documents/Qoder/wallcutter/dev/probe.rb'
puts '--- probe start ---'
v = Geom::Vector3d.new(0, 0, 1)
begin; puts "vector*float => #{(v * 2.0).to_a.inspect}"; rescue => e; puts "vector*float FAILS: #{e.class}"; end
begin; puts "vector.scale => #{v.scale(2.0).to_a.inspect}"; rescue => e; puts "vector.scale FAILS: #{e.class}"; end
model = Sketchup.active_model
puts "entities.clip? #{model.entities.respond_to?(:clip)}"
puts "SolidMunger? #{defined?(Geom::SolidMunger) ? 'yes' : 'no'}"
if defined?(Geom::SolidMunger)
  puts "munger methods: #{(Geom::SolidMunger.new.methods - Object.methods).sort.inspect}"
  def pbox(ents, x, y, z, w, d, h)
    g = ents.add_group
    f = g.entities.add_face([x, y, z], [x + w, y, z], [x + w, y + d, z], [x, y + d, z])
    f.pushpull(h)
    g
  end
  model.start_operation('probe_groups', true)
  ents = model.entities
  a = pbox(ents, 0, 0, 0, 10, 10, 10)
  b = pbox(ents, 5, 0, 0, 10, 10, 10)
  m = Geom::SolidMunger.new
  begin
    m.add(a, Geom::Transformation.new)
    m.add(b, Geom::Transformation.new)
    r = m.operate(ents, :difference)
    puts "groups operate(:difference) => #{r.inspect}"
    puts "after operate: ents=#{ents.length} a.valid?=#{a.valid?} b.valid?=#{b.valid?}"
    begin; puts "generate_geometry => #{m.generate_geometry(ents).inspect}"; rescue => e; puts "generate_geometry FAILS: #{e.class}: #{e.message}"; end
    puts "final: ents=#{ents.length} faces=#{ents.grep(Sketchup::Face).length}"
  rescue => e
    puts "groups flow FAILS: #{e.class}: #{e.message}"
  end
  model.abort_operation
  model.start_operation('probe_loose', true)
  e2 = model.entities
  f = e2.add_face([20, 0, 0], [30, 0, 0], [30, 0, 9], [20, 0, 9])
  f.reverse! unless f.normal.y > 0
  f.pushpull(1) # loose solid wall at root
  cutter = pbox(e2, 24, -1, 3, 2, 3, 2)
  faces_before = e2.grep(Sketchup::Face).length
  m2 = Geom::SolidMunger.new
  begin
    m2.add(e2, Geom::Transformation.new)
    m2.add(cutter, Geom::Transformation.new)
    rr = m2.operate(e2, :difference)
    puts "loose operate => #{rr.inspect}"
    puts "loose: faces #{faces_before} -> #{e2.grep(Sketchup::Face).length}"
  rescue => e
    puts "loose flow FAILS: #{e.class}: #{e.message}"
  end
  model.abort_operation
end
puts '--- probe end ---'
