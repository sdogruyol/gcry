begin
  5.clamp(...3)
  puts "no-raise clamp"
rescue e
  puts "ok clamp: #{e.class}"
end
begin
  s = Bytes.new(4, read_only: true)
  s[0] = 1_u8
  puts "no-raise check_writable"
rescue e
  puts "ok check_writable: #{e.class}"
end
puts "end"
