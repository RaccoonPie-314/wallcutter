# Probe 3: does add_face split a coplanar face, and does pushpull cut through?
puts '--- probe start ---'
model = Sketchup.active_model
model.start_operation('probe3', true)
begin
  ents = model.entities
  f = ents.add_face([0, 0, 0], [120, 0, 0], [120, 0, 108], [0, 0, 108])
  f.reverse! unless f.normal.y > 0
  f.pushpull(12)
  faces0 = ents.grep(Sketchup::Face).length
  rect = [[42, 0, 30], [78, 0, 30], [78, 0, 78], [42, 0, 78]].map { |a| Geom::Point3d.new(*a) }
  rf = ents.add_face(rect)
  puts "rect add_face => #{rf.class}; faces #{faces0} -> #{ents.grep(Sketchup::Face).length}"
  target = Geom::Point3d.new(60, 0, 54)
  inner = ents.grep(Sketchup::Face).find { |c| (c.center - target).length < 0.5 }
  puts "inner face found=#{!inner.nil?} normal=#{inner&.normal&.to_a.inspect}"
  inner.pushpull(-14.0) if inner
  puts "after pushpull faces=#{ents.grep(Sketchup::Face).length}"
  hole = model.raytest(Geom::Point3d.new(60, -20, 54), Geom::Vector3d.new(0, 1, 0))
  puts "ray through hole clears: #{hole.nil?}"
  # two-layer wall: second skin y=18..30
  g = ents.add_face([0, 18, 0], [120, 18, 0], [120, 18, 108], [0, 18, 108])
  g.reverse! unless g.normal.y > 0
  g.pushpull(12)
  entry2 = Geom::Point3d.new(60, 18, 54)
  f2 = ents.grep(Sketchup::Face).find { |c| c.normal.y < -0.999 && (c.center - entry2).length < 0.5 }
  puts "layer2 entry face found=#{!f2.nil?}"
  if f2
    r2 = [[42, 18, 30], [78, 18, 30], [78, 18, 78], [42, 18, 78]].map { |a| Geom::Point3d.new(*a) }
    ents.add_face(r2)
    inner2 = ents.grep(Sketchup::Face).find { |c| (c.center - entry2).length < 0.5 }
    puts "layer2 inner found=#{!inner2.nil?}"
    inner2.pushpull(-14.0) if inner2
    hole2 = model.raytest(Geom::Point3d.new(60, -20, 54), Geom::Vector3d.new(0, 1, 0))
    puts "ray through BOTH layers clears: #{hole2.nil?}"
  end
  # misc API existence checks
  puts "Sketchup::Boolean? #{defined?(Sketchup::Boolean).inspect}"
  puts "Geom::PolygonMesh? #{defined?(Geom::PolygonMesh).inspect}"
  puts "Entities#add_edges? #{ents.respond_to?(:add_edges)}"
  puts "Entities#insert_points? #{ents.respond_to?(:insert_points)}"
  puts "Face#split? #{f.respond_to?(:split)}"
  puts "Face#flip_style? #{f.respond_to?(:flip_style)}"
rescue => e
  puts "FAILS: #{e.class}: #{e.message}"
  puts e.backtrace.first(5)
end
model.abort_operation
puts '--- probe end ---'
