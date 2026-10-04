require "json"
require "http/server"
require "../../../../../src/gcry"
server = HTTP::Server.new { |ctx| ctx.response.print JSON.parse(%({"a":[1,2]})).to_json }
{% for t in %w(Nil Bool Int64 Float64 String Array(JSON::Any) Hash(String,\ JSON::Any)) %}
  puts "{{t.id}} #{{{t.id}}.crystal_instance_type_id}"
{% end %}
