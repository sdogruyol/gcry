def s3(n)
  helper(n)
  raise "boom" if n == 0
  n
end

def helper(n)
  s2(n + 1) if n > 100
end

def s2(n)
  s3(n)
end

s3(1)
begin
  s2(0)
  puts "not raised"
rescue
  puts "rescued"
end
