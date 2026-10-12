# Round 2: full root face dump + wall stack + reproduce the cut on the user's wall.
puts "--- dump start ---"
Sketchup.open_file('/Users/mengly/Documents/Qoder/wallcutter/dev/debug_model.skp')
model = Sketchup.active_model
ents = model.entities
puts "root: faces=#{ents.grep(Sketchup::Face).size} groups=#{ents.grep(Sketchup::Group).size} instances=#{ents.grep(Sketchup::ComponentInstance).size}"
ents.grep(Sketchup::Face).each do |f|
  c = f.bounds.center
  puts "F c=[#{c.x.round(1)},#{c.y.round(1)},#{c.z.round(1)}] n=[#{f.normal.to_a.map { |v| v.round(2) }.join(',')}] a=#{f.area.round(0)} loop=#{f.outer_loop.vertices.size}"
end
# vertical faces (walls): |n.y|>0.9, biggest one is a wall skin
walls = ents.grep(Sketchup::Face).select { |f| f.normal.y.abs > 0.9 && f.area > 3000 }
puts "wall candidates=#{walls.size}"
walls.sort_by { |f| -f.area }.first(3).each do |w|
  n = w.normal
  o = w.bounds.center
  puts "wall-skin n=[#{n.to_a.map { |v| v.round(2) }.join(',')}] a=#{w.area.round(0)} c=[#{o.to_a.map { |v| v.round(1) }.join(',')}]"
  ents.grep(Sketchup::Face).select { |f| f.normal.cross(n).length < 0.01 }
      .map { |f| [((f.bounds.center - o) % n), f] }.sort_by(&:first)
      .each { |t, f| puts "  ystack t=#{t.round(2)} a=#{f.area.round(0)} c=[#{f.bounds.center.to_a.map { |v| v.round(1) }.join(',')}]" }
end
# reproduce the cut: front = largest wall skin, cut centered, auto depth
front = walls.max_by(&:area)
if front
  n = front.normal
  n = n.reverse if n.y < 0 # into the wall
  o = front.bounds.center
  puts "REPRO front c=[#{o.to_a.map { |v| v.round(1) }.join(',')}] n=[#{n.to_a.map { |v| v.round(2) }.join(',')}]"
  model.start_operation('repro', true)
  begin
    ok = WallCutter::CutEngine.cut(o, n, WallCutter::X_AXIS, WallCutter::Z_AXIS, 36.0, 48.0)
    puts "REPRO cut ok=#{ok}"
    ents.grep(Sketchup::Face).each do |f|
      c = f.bounds.center
      next unless (c.x - o.x).abs < 30 && (c.z - o.z).abs < 30
      puts "AFTER F c=[#{c.x.round(1)},#{c.y.round(1)},#{c.z.round(1)}] n=[#{f.normal.to_a.map { |v| v.round(2) }.join(',')}] a=#{f.area.round(0)} loop=#{f.outer_loop.vertices.size}"
    end
    probe = Geom::Point3d.new(o.x, o.y - 20, o.z)
    hit = WallCutter.ray(model, probe, n)
    puts "REPRO ray from front clears: #{hit.nil?} #{hit ? "hit_at=#{hit[0].to_a.map { |v| v.round(1) }.inspect}" : ''}"
  rescue => e
    puts "REPRO ERROR #{e.class}: #{e.message}"
    puts e.backtrace.first(5)
  end
  model.abort_operation
end
puts "--- dump end ---"
