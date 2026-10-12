# X-ray the user's fresh single-box cut: every root face + the opening column census.
puts "--- dump start ---"
Sketchup.open_file('/Users/mengly/Documents/Qoder/wallcutter/dev/debug_model2.skp')
model = Sketchup.active_model
ents = model.entities
puts "faces=#{ents.grep(Sketchup::Face).size} edges=#{ents.grep(Sketchup::Edge).size} groups=#{ents.grep(Sketchup::Group).size} instances=#{ents.grep(Sketchup::ComponentInstance).size}"
ents.grep(Sketchup::Face).each do |f|
  b = f.bounds
  c = b.center
  puts "F c=[#{c.x.round(1)},#{c.y.round(1)},#{c.z.round(1)}] n=[#{f.normal.to_a.map { |v| v.round(2) }.join(',')}] a=#{f.area.round(1)} loop=#{f.outer_loop.vertices.size} inner=#{f.loops.count - 1}"
end
# biggest face = a wall skin; scan its normal axis for the opening column
big = ents.grep(Sketchup::Face).max_by(&:area)
if big
  n = big.normal
  o = big.bounds.center
  u = WallCutter::Z_AXIS.cross(n)
  u = n.cross(WallCutter::Z_AXIS) if u.length < 0.5
  next_len = u.length
  u = next_len < 0.001 ? WallCutter::X_AXIS : u.normalize
  v = n.cross(u).normalize rescue next
  puts "big n=[#{n.to_a.map { |x| x.round(2) }.join(',')}] c=[#{o.to_a.map { |x| x.round(1) }.join(',')}] a=#{big.area.round(0)}"
  ents.grep(Sketchup::Face).select { |f| f.normal.cross(n).length < 0.01 }
      .map { |f| [((f.bounds.center - o) % n), f] }.sort_by(&:first)
      .each { |t, f| puts "  col t=#{t.round(2)} a=#{f.area.round(1)} c=[#{f.bounds.center.to_a.map { |x| x.round(1) }.join(',')}] inner=#{f.loops.count - 1}" }
end
puts "--- dump end ---"
