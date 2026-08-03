require "big"
require "base64"
require "json"
require "complex"

# require crystal at least 0.27.0 and older

# ./metric
# ./metric Brainfuck2
# ./metric Brainfuck,Brainfuck2
Benchmark.run(ARGV[0]?)

{% if compare_versions(Crystal::VERSION, "0.28.0") < 0 %}
  struct Time
    def self.local
      now
    end
  end
{% end %}

def checksum(v)
  hash = 5381_u32
  v.each_byte do |byte|
    hash = ((hash << 5) &+ hash) &+ byte
  end
  hash
end

abstract class Benchmark
  abstract def run
  abstract def result
  abstract def expected

  FILENAME = "#{__DIR__}/results.js"

  def self.release_results_error
    puts "ERROR\nNot found release results!\nBefore run in any other mode, you should compile and run this metric in --release mode,\nbecause all other modes compare to release."
    exit 1
  end

  def self.load_release_results
    release_results = {} of String => Float64
    {% unless flag?(:release) %}
      if File.exists?(FILENAME)
        release_results = Hash(String, Float64).from_json(File.read(FILENAME))
        {% for kl in @type.subclasses %}
          release_results_error unless release_results["{{kl.id}}"]?
        {% end %}
      else
        release_results_error
      end
    {% end %}
    release_results
  end

  def self.run(filter : String? = nil)
    release_results = load_release_results
    results = {} of String => Float64

    summary_time = 0.0
    awards = 0.0
    ok = 0
    fails = 0
    silent = ENV["SILENT"]? == "1"
    run_mark = ENV["RUN_MARK"]? == "1"
    if filter
      filter = filter.split(",").map(&.strip)
    end

    {% for kl in @type.subclasses %}
      if !filter || (filter && filter.includes?("{{kl.id}}"))
        print "{{kl}}: " unless silent

        puts "---RUN---" if run_mark
        bench = {{kl.id}}.new
        bench._run
        results["{{kl.id}}"] = bench.time_delta
        
        {% if flag?(:release) %}
          award = 1.0
        {% else %}
          award = release_results["{{kl.id}}"] / bench.time_delta
        {% end %}

        if bench.ok?
          print "ok " unless silent
          ok += 1
        else
          print "err result=#{bench.result.inspect}, but expected=#{bench.expected.inspect} " unless silent
          fails += 1
        end

        unless silent
          print "in %.3fs, award %.1f\n" % {bench.time_delta, award}
        end

        summary_time += bench.time_delta
        awards += award
      end
    {% end %}

    {% if flag?(:release) %}
      if !filter
        File.open(FILENAME, "w") { |f| results.to_json(f) }
      end
    {% end %}

    if ok + fails > 0
      puts "%.4fs, %.2f/%d, %.2f" % {summary_time, awards, ok + fails, awards / (ok + fails).to_f}
    end
    exit 1 if fails > 0
  end

  getter time_delta : Float64 = 0

  def _run
    GC.collect
    t = Time.local
    self.run
    @time_delta = (Time.local - t).to_f
    GC.collect
    sleep 0.seconds # context switch, may be needed or maybe not, to close some coroutines
    GC.collect
  end

  def ok?
    self.result == self.expected
  end
end

class Pidigits < Benchmark
  def initialize(@nn = 4500)
    @result = IO::Memory.new
  end

  def run
    start = Time.local

    i = 0
    k = 0
    ns = 0.to_big_i
    a = 0.to_big_i
    t = 0
    u = 0.to_big_i
    k1 = 1
    n = 1.to_big_i
    d = 1.to_big_i

    while true
      k += 1
      t = n << 1
      n *= k
      k1 += 2
      a = (a + t) * k1
      d *= k1
      if a >= n
        t, u = (n * 3 + a).divmod(d)
        u += n
        if d > u
          ns = ns * 10 + t
          i += 1
          if i % 10 == 0
            @result << "%010d\t:%d\n" % {ns.to_u64, i}
            ns = 0
          end
          break if i >= @nn

          a = (a - (d * t)) * 10
          n *= 10
        end
      end
    end
  end

  def result
    checksum(@result.to_s)
  end

  def expected
    519471024
  end
end

class Binarytrees < Benchmark
  getter result

  class TreeNode
    property left : TreeNode?
    property right : TreeNode?
    property item : Int32

    def self.create(item, depth) : TreeNode
      TreeNode.new item, depth - 1
    end

    def initialize(@item, depth = 0)
      if depth > 0
        self.left = TreeNode.new 2 * item - 1, depth - 1
        self.right = TreeNode.new 2 * item, depth - 1
      end
    end

    def check
      return item if (lft = left).nil?
      return item if (rgt = right).nil?
      lft.check - rgt.check + item
    end
  end

  def initialize(@n = 18)
    @result = 0
  end

  def run
    min_depth = 4
    max_depth = Math.max min_depth + 2, @n
    stretch_depth = max_depth + 1
    @result += TreeNode.create(0, stretch_depth).check

    long_lived_tree = TreeNode.create 0, max_depth
    min_depth.step(to: max_depth, by: 2) do |depth|
      iterations = 1 << (max_depth - depth + min_depth)
      1.upto(iterations) do |i|
        @result += TreeNode.create(i, depth).check
        @result += TreeNode.create(-i, depth).check
      end
    end
  end

  def expected
    -699041
  end
end

class Brainfuck < Benchmark
  getter result

  class Tape
    def initialize
      @tape = [0]
      @pos = 0
    end

    @[AlwaysInline]
    def get
      @tape[@pos]
    end

    @[AlwaysInline]
    def inc
      @tape[@pos] += 1
    end

    @[AlwaysInline]
    def dec
      @tape[@pos] -= 1
    end

    @[AlwaysInline]
    def advance
      @pos += 1
      @tape << 0 if @tape.size <= @pos
    end

    @[AlwaysInline]
    def devance
      @pos -= 1 if @pos > 0
    end
  end

  class Program
    def initialize(text)
      @chars = [] of Char
      @bracket_map = {} of Int32 => Int32
      leftstack = [] of Int32
      pc = 0
      text.each_char do |char|
        if "[]<>+-,.".includes?(char)
          @chars << char
          if char == '['
            leftstack << pc
          elsif char == ']' && !leftstack.empty?
            left = leftstack.pop
            right = pc
            @bracket_map[left] = right
            @bracket_map[right] = left
          end
          pc += 1
        end
      end
    end

    def run
      result = 0
      tape = Tape.new
      pc = 0
      while pc < @chars.size
        case @chars[pc]
        when '+'; tape.inc
        when '-'; tape.dec
        when '>'; tape.advance
        when '<'; tape.devance
        when '['; pc = @bracket_map[pc] if tape.get == 0
        when ']'; pc = @bracket_map[pc] if tape.get != 0
        when '.'; result += tape.get.chr.ord
        else
        end
        pc += 1
      end
      result
    end
  end

  def initialize
    @text = "Benchmark brainf*ck program
>++[<+++++++++++++>-]<[[>+>+<<-]>[<+>-]++++++++
[>++++++++<-]>.[-]<<>++++++++++[>++++++++++[>++
++++++++[>++++++++++[>++++++++++[>++++++++++[>+
+++++++++[-]<-]<-]<-]<-]<-]<-]<-]++++++++++."
    @result = 0
  end

  def run
    @result = Program.new(@text).run
  end

  def expected
    2025
  end
end

class Brainfuck2 < Benchmark
  getter result

  module Op
    record Inc, val : Int32
    record Move, val : Int32
    record Print
    alias T = Inc | Move | Print | Array(Op::T)
  end

  class Tape
    def initialize
      @tape = [0_u8]
      @pos = 0
    end

    @[AlwaysInline]
    def get
      @tape[@pos]
    end

    @[AlwaysInline]
    def inc(x)
      @tape[@pos] += x
    end

    @[AlwaysInline]
    def move(x)
      @pos += x
      while @pos >= @tape.size
        @tape << 0
      end
    end
  end

  class Program
    property result
    @ops : Array(Op::T)

    def initialize(code : String)
      @ops = parse(code.each_char)
      @result = 0
    end

    def run
      _run @ops, Tape.new
    end

    private def _run(program, tape)
      program.each do |op|
        case op
        when Op::Inc
          tape.inc(op.val)
        when Op::Move
          tape.move(op.val)
        when Array(Op::T)
          while tape.get != 0
            _run(op, tape)
          end
        when Op::Print
          @result += tape.get.chr.ord
        else
        end
      end
    end

    private def parse(iterator)
      res = [] of Op::T
      iterator.each do |c|
        op = case c
             when '+'; Op::Inc.new(1)
             when '-'; Op::Inc.new(-1)
             when '>'; Op::Move.new(1)
             when '<'; Op::Move.new(-1)
             when '.'; Op::Print.new
             when '['; parse(iterator)
             when ']'; break
             else
             end
        res << op if op
      end
      res
    end
  end

  def initialize
    @text = "Benchmark brainf*ck program
>++[<+++++++++++++>-]<[[>+>+<<-]>[<+>-]++++++++
[>++++++++<-]>.[-]<<>++++++++++[>++++++++++[>++
++++++++[>++++++++++[>++++++++++[>++++++++++[>+
+++++++++[-]<-]<-]<-]<-]<-]<-]<-]++++++++++."
    @result = 0
  end

  def run
    program = Program.new(@text)
    program.run
    @result = program.result
  end

  def expected
    2025
  end
end

class Fannkuchredux < Benchmark
  getter result

  def fannkuchredux(n)
    perm1 = StaticArray(Int32, 32).new { |i| i }
    perm = StaticArray(Int32, 32).new(0)
    count = StaticArray(Int32, 32).new(0)
    maxFlipsCount = permCount = checksum = 0
    r = n

    while true
      while r > 1
        count[r - 1] = r
        r -= 1
      end

      n.times { |i| perm[i] = perm1[i] } # dup
      flipsCount = 0

      while !((k = perm[0]) == 0)
        k2 = (k + 1) >> 1
        (0...k2).each do |i|
          j = k - i
          perm[i], perm[j] = perm[j], perm[i] # swap
        end
        flipsCount += 1
      end

      maxFlipsCount = flipsCount if flipsCount > maxFlipsCount
      checksum += (permCount % 2 == 0) ? flipsCount : -flipsCount

      while true
        return {checksum, maxFlipsCount} if r == n

        perm0 = perm1[0]
        (0...r).each do |i|
          j = i + 1
          perm1[i], perm1[j] = perm1[j], perm1[i] # swap
        end

        perm1[r] = perm0
        cntr = count[r] -= 1
        break if cntr > 0
        r += 1
      end
      permCount += 1
    end
  end

  def initialize(@n = 11)
    @result = {0, 0}
  end

  def run
    @result = fannkuchredux(@n)
  end

  def expected
    {556355, 51}
  end
end

class Fasta < Benchmark
  IM = 139968
  IA =   3877
  IC =  29573

  class Last
    @[AlwaysInline]
    def self.last
      @@last ||= 42
    end

    @[AlwaysInline]
    def self.last=(x)
      @@last = x
    end
  end

  def gen_random(max)
    Last.last = (Last.last * IA + IC) % IM
    max * Last.last / IM.to_f64
  end

  def make_cumulative(genelist)
    cp = 0.0_f64
    genelist.size.times do |i|
      c, p = genelist[i]
      cp += p
      genelist[i] = {c, cp}
    end
  end

  def select_random(genelist)
    r = gen_random(1)
    return genelist[0][0] if r < genelist[0][1]

    lo = 0
    hi = genelist.size - 1

    while hi > lo + 1
      i = (hi + lo) // 2
      if r < genelist[i][1]
        hi = i
      else
        lo = i
      end
    end
    genelist[hi][0]
  end

  LINE_LENGTH = 60

  def make_random_fasta(id, desc, genelist, n)
    todo = n
    @result << ">#{id} #{desc}"
    @result << "\n"

    while todo > 0
      m = (todo < LINE_LENGTH) ? todo : LINE_LENGTH
      pick = String.new(m) do |buffer|
        m.times { |i| buffer[i] = select_random(genelist).ord.to_u8 }
        {m, m}
      end
      @result << pick
      @result << "\n"
      todo -= LINE_LENGTH
    end
  end

  def make_repeat_fasta(id, desc, s, n)
    todo = n
    k = 0
    kn = s.size

    @result << ">#{id} #{desc}"
    @result << "\n"
    while todo > 0
      m = (todo < LINE_LENGTH) ? todo : LINE_LENGTH

      while m >= kn - k
        @result << s[k..-1]
        m -= kn - k
        k = 0
      end

      @result << s[k...k + m]
      @result << "\n"
      k += m

      todo -= LINE_LENGTH
    end
  end

  IUB = [
    {'a', 0.27},
    {'c', 0.12},
    {'g', 0.12},
    {'t', 0.27},

    {'B', 0.02},
    {'D', 0.02},
    {'H', 0.02},
    {'K', 0.02},
    {'M', 0.02},
    {'N', 0.02},
    {'R', 0.02},
    {'S', 0.02},
    {'V', 0.02},
    {'W', 0.02},
    {'Y', 0.02},
  ]

  HOMO = [{'a', 0.3029549426680}, {'c', 0.1979883004921}, {'g', 0.1975473066391}, {'t', 0.3015094502008}]
  ALU  = "GGCCGGGCGCGGTGGCTCACGCCTGTAATCCCAGCACTTTGGGAGGCCGAGGCGGGCGGATCACCTGAGGTCAGGAGTTCGAGACCAGCCTGGCCAACATGGTGAAACCCCGTCTCTACTAAAAATACAAAAATTAGCCGGGCGTGGTGGCGCGCGCCTGTAATCCCAGCTACTCGGGAGGCTGAGGCAGGAGAATCGCTTGAACCCGGGAGGCGGAGGTTGCAGTGAGCCGAGATCGCGCCACTGCACTCCAGCCTGGGCGACAGAGCGAGACTCCGTCTCAAAAA"

  def initialize(@n = 7000000)
    make_cumulative(IUB)
    make_cumulative(HOMO)
    @result = IO::Memory.new
  end

  def run
    make_repeat_fasta("ONE", "Homo sapiens alu", ALU, @n * 2)
    make_random_fasta("TWO", "IUB ambiguity codes", IUB, @n * 3)
    make_random_fasta("THREE", "Homo sapiens frequency", HOMO, @n * 5)
  end

  def result
    checksum(@result.to_s)
  end

  def expected
    3574419414
  end
end

class Knuckeotide < Benchmark
  @seq : String

  def frecuency(seq, length)
    n = seq.size - length + 1
    table = Hash(String, Int32).new { 0 }
    (0...n).each do |f|
      table[seq.byte_slice(f, length)] += 1
    end
    {n, table}
  end

  def sort_by_freq(seq, length)
    n, table = frecuency(seq, length)
    table.to_a.sort { |a, b| b[1] <=> a[1] }.each do |v|
      @result << "%s %.3f\n" % {v[0].upcase, ((v[1] * 100).to_f / n)}
    end
    @result << "\n"
  end

  def find_seq(seq, s)
    n, table = frecuency(seq, s.size)
    @result << "#{table[s].to_s}\t#{s.upcase}\n"
  end

  def run(seq)
  end

  def initialize
    @result = IO::Memory.new

    f = Fasta.new(600000)
    f.run
    res = f.@result.to_s

    seq = IO::Memory.new
    three = false

    res.each_line do |line|
      if line.starts_with?(">THREE")
        three = true
        next
      end
      seq << line.chomp if three
    end
    @seq = seq.to_s
  end

  def run
    (1..2).each { |i| sort_by_freq(@seq, i) }
    %w(ggt ggta ggtatt ggtattttaatt ggtattttaatttatagt).each { |s| find_seq(@seq, s) }
  end

  def result
    checksum(@result.to_s)
  end

  def expected
    1459386462
  end
end

class Mandelbrot < Benchmark
  ITER  =  50
  LIMIT = 2.0

  def initialize(@n = 3800)
    @result = IO::Memory.new
  end

  def run
    w = h = @n
    @result << "P4\n#{w} #{h}\n"

    bit_num = 0
    byte_acc = 0_u8

    h.times do |y|
      w.times do |x|
        zr = zi = tr = ti = 0.0
        cr = (2.0 * x / w - 1.5)
        ci = (2.0 * y / h - 1.0)

        i = 0
        while (i < ITER) && (tr + ti <= LIMIT * LIMIT)
          zi = 2.0 * zr * zi + ci
          zr = tr - ti + cr
          tr = zr * zr
          ti = zi * zi
          i += 1
        end

        byte_acc <<= 1
        byte_acc |= 0x01 if tr + ti <= LIMIT * LIMIT
        bit_num += 1

        if bit_num == 8
          @result.write_byte byte_acc
          byte_acc = 0_u8
          bit_num = 0
        elsif x == w - 1
          byte_acc <<= 8 - w % 8
          @result.write_byte byte_acc
          byte_acc = 0_u8
          bit_num = 0
        end
      end
    end
  end

  def result
    checksum(@result.to_s)
  end

  def expected
    58810785
  end
end

class Matmul < Benchmark
  def matmul(a, b)
    m = a.size
    n = a[0].size
    p = b[0].size
    # transpose
    b2 = Array.new(n) { Array.new(p, 0.0) }
    (0...n).each do |i|
      (0...p).each do |j|
        b2[j][i] = b[i][j]
      end
    end
    # multiplication
    c = Array.new(m) { Array.new(p, 0.0) }
    c.each_with_index do |ci, i|
      ai = a[i]
      b2.each_with_index do |b2j, j|
        s = 0.0
        b2j.each_with_index do |b2jv, k|
          s += ai[k] * b2jv
        end
        ci[j] = s
      end
    end
    c
  end

  def matgen(n)
    tmp = 1.0 / n / n
    a = Array.new(n) { Array.new(n, 0.0) }
    (0...n).each do |i|
      (0...n).each do |j|
        a[i][j] = tmp * (i - j) * (i + j)
      end
    end
    a
  end

  getter result

  def initialize(@n = 980)
    @result = 0.0
  end

  def run
    a = matgen(@n)
    b = matgen(@n)
    c = matmul(a, b)
    @result = c[@n >> 1][@n >> 1]
  end

  def expected
    -93.66692176867205
  end
end

class Nbody < Benchmark
  # Copied with little modifications from: http://benchmarksgame.alioth.debian.org/u32/program.php?test=nbody&lang=yarv&id=2
  SOLAR_MASS    = 4 * Math::PI**2
  DAYS_PER_YEAR = 365.24

  class Planet
    def_clone

    property x : Float64
    property y : Float64
    property z : Float64
    property vx : Float64
    property vy : Float64
    property vz : Float64
    property mass : Float64

    def initialize(@x, @y, @z, vx, vy, vz, mass)
      @vx, @vy, @vz = vx * DAYS_PER_YEAR, vy * DAYS_PER_YEAR, vz * DAYS_PER_YEAR
      @mass = mass * SOLAR_MASS
    end

    def move_from_i(bodies, nbodies, dt, i)
      while i < nbodies
        b2 = bodies[i]
        dx = @x - b2.x
        dy = @y - b2.y
        dz = @z - b2.z

        distance = Math.sqrt(dx * dx + dy * dy + dz * dz)
        mag = dt / (distance * distance * distance)
        b_mass_mag, b2_mass_mag = @mass * mag, b2.mass * mag

        @vx -= dx * b2_mass_mag
        @vy -= dy * b2_mass_mag
        @vz -= dz * b2_mass_mag
        b2.vx += dx * b_mass_mag
        b2.vy += dy * b_mass_mag
        b2.vz += dz * b_mass_mag
        i += 1
      end

      @x += dt * @vx
      @y += dt * @vy
      @z += dt * @vz
    end
  end

  def energy(bodies)
    e = 0.0
    nbodies = bodies.size

    0.upto(nbodies - 1) do |i|
      b = bodies[i]
      e += 0.5 * b.mass * (b.vx * b.vx + b.vy * b.vy + b.vz * b.vz)
      (i + 1).upto(nbodies - 1) do |j|
        b2 = bodies[j]
        dx = b.x - b2.x
        dy = b.y - b2.y
        dz = b.z - b2.z
        distance = Math.sqrt(dx * dx + dy * dy + dz * dz)
        e -= (b.mass * b2.mass) / distance
      end
    end
    e
  end

  def offset_momentum(bodies)
    px, py, pz = 0.0, 0.0, 0.0

    bodies.each do |b|
      m = b.mass
      px += b.vx * m
      py += b.vy * m
      pz += b.vz * m
    end

    b = bodies[0]
    b.vx = -px / SOLAR_MASS
    b.vy = -py / SOLAR_MASS
    b.vz = -pz / SOLAR_MASS
  end

  BODIES = [
    # sun
    Planet.new(0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0),

    # jupiter
    Planet.new(
      4.84143144246472090e+00,
      -1.16032004402742839e+00,
      -1.03622044471123109e-01,
      1.66007664274403694e-03,
      7.69901118419740425e-03,
      -6.90460016972063023e-05,
      9.54791938424326609e-04),

    # saturn
    Planet.new(
      8.34336671824457987e+00,
      4.12479856412430479e+00,
      -4.03523417114321381e-01,
      -2.76742510726862411e-03,
      4.99852801234917238e-03,
      2.30417297573763929e-05,
      2.85885980666130812e-04),

    # uranus
    Planet.new(
      1.28943695621391310e+01,
      -1.51111514016986312e+01,
      -2.23307578892655734e-01,
      2.96460137564761618e-03,
      2.37847173959480950e-03,
      -2.96589568540237556e-05,
      4.36624404335156298e-05),

    # neptune
    Planet.new(
      1.53796971148509165e+01,
      -2.59193146099879641e+01,
      1.79258772950371181e-01,
      2.68067772490389322e-03,
      1.62824170038242295e-03,
      -9.51592254519715870e-05,
      5.15138902046611451e-05),
  ]

  def initialize(@n = 15000000)
    @result = {0.0, 0.0}
    @body = BODIES
  end

  def run
    offset_momentum(@body)

    v1 = energy(@body)

    nbodies = @body.size
    dt = 0.01

    @n.times do
      i = 0
      while i < nbodies
        b = @body[i]
        b.move_from_i(@body, nbodies, dt, i + 1)
        i += 1
      end
    end

    v2 = energy(@body)
    @result = {v1, v2}
  end

  getter result

  def expected
    {-0.16907516382852447, -0.16905678767532126}
  end
end

class RegexDna < Benchmark
  @seq : String
  @ilen : Int32
  @clen : Int32

  def initialize
    @result = IO::Memory.new

    f = Fasta.new(6000000)
    f.run
    res = f.@result.to_s

    seq = IO::Memory.new

    @ilen = 0
    res.each_line do |line|
      @ilen += line.bytesize + 1
      seq << line.chomp unless line.starts_with? '>'
    end

    @seq = seq.to_s
    @clen = seq.bytesize
  end

  def run
    [
      /agggtaaa|tttaccct/,
      /[cgt]gggtaaa|tttaccc[acg]/,
      /a[act]ggtaaa|tttacc[agt]t/,
      /ag[act]gtaaa|tttac[agt]ct/,
      /agg[act]taaa|ttta[agt]cct/,
      /aggg[acg]aaa|ttt[cgt]ccct/,
      /agggt[cgt]aa|tt[acg]accct/,
      /agggta[cgt]a|t[acg]taccct/,
      /agggtaa[cgt]|[acg]ttaccct/,
    ].each { |f| @result << "#{f.source} #{@seq.scan(f).size}\n" }

    hash = {
      "B" => "(c|g|t)",
      "D" => "(a|g|t)",
      "H" => "(a|c|t)",
      "K" => "(g|t)",
      "M" => "(a|c)",
      "N" => "(a|c|g|t)",
      "R" => "(a|g)",
      "S" => "(c|t)",
      "V" => "(a|c|g)",
      "W" => "(a|t)",
      "Y" => "(c|t)",
    }

    t = Time.local
    @seq = @seq.gsub(/B|D|H|K|M|N|R|S|V|W|Y/, hash)

    @result << "\n"
    @result << "#{@ilen}\n"
    @result << "#{@clen}\n"
    @result << "#{@seq.size}\n"
  end

  def result
    checksum(@result.to_s)
  end

  def expected
    2813760484
  end
end

class Revcomp < Benchmark
  @input : String

  def revcomp(seq)
    seq = seq.reverse.tr("wsatugcyrkmbdhvnATUGCYRKMBDHVN", "WSTAACGRYMKVHDBNTAACGRYMKVHDBN")
    stringlen = seq.size - 1
    0.step(to: stringlen, by: 60) { |x| @result << seq[x...x + 60]; @result << "\n" }
  end

  def initialize
    @result = IO::Memory.new

    f = Fasta.new(13000000)
    f.run
    @input = f.@result.to_s
  end

  def run
    seq = IO::Memory.new

    @input.each_line do |line|
      if line.starts_with? '>'
        if !seq.empty?
          revcomp(seq.to_s)
          seq.clear
        end
        @result << line
        @result << "\n"
      else
        seq << line.chomp
      end
    end
    revcomp(seq.to_s)
  end

  def result
    checksum(@result.to_s)
  end

  def expected
    2734405216
  end
end

class Spectralnorm < Benchmark
  def eval_A(i, j)
    1.0_f64 / ((i + j) * (i + j + 1.0) / 2.0 + i + 1.0)
  end

  def eval_A_times_u(u)
    (0...u.size).map do |i|
      v = 0.0_f64
      u.each_with_index do |uu, j|
        v += eval_A(i, j) * uu
      end
      v
    end
  end

  def eval_At_times_u(u)
    (0...u.size).map do |i|
      v = 0.0_f64
      u.each_with_index do |uu, j|
        v += eval_A(j, i) * uu
      end
      v
    end
  end

  def eval_AtA_times_u(u)
    eval_At_times_u(eval_A_times_u(u))
  end

  getter result

  def initialize(@n = 4500)
    @result = 0.0
  end

  def run
    u = Array.new(@n, 1.0_f64)
    v = Array.new(@n, 1.0_f64)
    10.times do
      v = eval_AtA_times_u(u)
      u = eval_AtA_times_u(v)
    end
    vBv = vv = 0.0_f64
    (0...@n).each do |i|
      vBv += u[i] * v[i]
      vv += v[i] * v[i]
    end
    @result = Math.sqrt(vBv / vv)
  end

  def expected
    1.2742241527688491
  end
end

class Threadring < Benchmark
  THREAD_COUNT = 503

  class Receiver
    def initialize(@name : Int32, @res : Channel(Int32))
      @mailbox = Channel(Int32).new
    end

    def next=(n : Receiver)
      @next = n
    end

    def put(msg)
      @mailbox.send(msg)
    end

    def messageloop
      while true
        msg = @mailbox.receive
        if msg == 0
          @res.send(@name)
        elsif nxt = @next
          nxt.put(msg - 1)
        end
      end
    end
  end

  @receivers : Array(Receiver)

  def initialize(@n = 15000000)
    @res = Channel(Int32).new
    @receivers = Array.new(THREAD_COUNT) { |i| Receiver.new(i + 1, @res) }
    (0...THREAD_COUNT - 1).each { |i| @receivers[i].next = @receivers[i + 1] }
    @receivers[THREAD_COUNT - 1].next = @receivers[0]
    @result = 0
  end

  def run
    THREAD_COUNT.times do |i|
      spawn { @receivers[i].messageloop }
    end
    @receivers[0].put(@n)
    @result = @res.receive
  end

  getter result : Int32

  def expected
    38
  end
end

class Base64Encode < Benchmark
  TRIES = 8192

  @str : String
  @str2 : String
  @str3 : String

  def initialize(@n = 300_000)
    @str = "a" * @n
    @str2 = Base64.strict_encode(@str)
    @str3 = Base64.decode_string(@str2)
    @result = ""
  end

  def run
    s_encoded = 0_i64

    TRIES.times do |i|
      s_encoded += Base64.strict_encode(@str).bytesize
    end

    @result += "encode #{@str[0..3]}... to #{@str2[0..3]}...: #{s_encoded}\n"
  end

  getter result

  def expected
    "encode aaaa... to YWFh...: 3276800000\n"
  end
end

class Base64Decode < Benchmark
  TRIES = 8192

  @str : String
  @str2 : String
  @str3 : String

  def initialize(@n = 230_000)
    @str = "a" * @n
    @str2 = Base64.strict_encode(@str)
    @str3 = Base64.decode_string(@str2)
    @result = ""
  end

  def run
    s_decoded = 0_i64

    TRIES.times do |i|
      s_decoded += Base64.decode_string(@str2).bytesize
    end

    @result += "decode #{@str2[0..3]}... to #{@str3[0..3]}...: #{s_decoded}\n"
  end

  getter result

  def expected
    "decode YWFh... to aaaa...: 1884160000\n"
  end
end

class Primes < Benchmark
  PREFIX = 32_338

  class Node
    property :children, :terminal

    def initialize
      @children = Hash(Char, Node).new
      @terminal = false
    end
  end

  class Sieve
    def initialize(limit : Int32)
      @limit = limit
      @prime = Array(Bool).new(limit + 1, false)
    end

    def to_list
      result = [2, 3]
      (5..@limit).each do |p|
        result.push(p) if @prime[p]
      end
      result
    end

    def omit_squares
      r = 5
      while r * r < @limit
        if @prime[r]
          i = r * r
          while i < @limit
            @prime[i] = false
            i += r * r
          end
        end
        r += 1
      end

      self
    end

    def step1(x, y)
      n = (4 * x * x) + (y * y)
      @prime[n] = !@prime[n] if n <= @limit && (n % 12 == 1 || n % 12 == 5)
    end

    def step2(x, y)
      n = (3 * x * x) + (y * y)
      @prime[n] = !@prime[n] if n <= @limit && n % 12 == 7
    end

    def step3(x, y)
      n = (3 * x * x) - (y * y)
      @prime[n] = !@prime[n] if x > y && n <= @limit && n % 12 == 11
    end

    def loop_y(x)
      y = 1
      while y * y < @limit
        step1(x, y)
        step2(x, y)
        step3(x, y)
        y += 1
      end
    end

    def loop_x
      x = 1
      while x * x < @limit
        loop_y(x)
        x += 1
      end
    end

    def calc
      loop_x
      omit_squares
    end
  end

  def generate_trie(l)
    root = Node.new
    l.each do |el|
      head = root
      el.to_s.each_char do |ch|
        head.children[ch] = Node.new unless head.children[ch]?
        head = head.children[ch]
      end
      head.terminal = true
    end
    root
  end

  def find(upper_bound, prefix)
    primes = Sieve.new(upper_bound).calc
    str_prefix = prefix.to_s
    head = generate_trie(primes.to_list)
    str_prefix.each_char do |ch|
      head = head.children[ch]
      return nil if head.nil?
    end

    queue = [{head, str_prefix}]
    result = Array(Int32).new
    until queue.empty?
      top, prefix = queue.pop
      result.push(prefix.to_i) if top.terminal
      top.children.each do |ch, v|
        queue.insert(0, {v, prefix + ch})
      end
    end
    result
  end

  @results : Array(Int32)?

  def initialize(@n = 40_000_000)
    @results = Array(Int32).new
  end

  def run
    @results = find(@n, PREFIX)
  end

  def result
    @results
  end

  def expected
    [323381, 323383, 3233803, 3233809, 3233851, 3233863, 3233873, 3233887, 3233897, 32338123, 32338129, 32338147, 32338169, 32338351, 32338367, 32338387, 32338039, 32338099, 32338013, 32338027, 32338043, 32338049, 32338067, 32338517, 32338507, 32338541, 32338577, 32338633, 32338637, 32338609, 32338619, 32338643, 32338661, 32338687, 32338697, 32338699, 32338739, 32338751, 32338763, 32338871, 32338819, 32338829, 32338837, 32338843, 32338849, 32338853, 32338861, 32338907, 32338909, 32338937, 32338949, 32338993, 32338997, 32338223, 32338231, 32338249, 32338291, 32338433, 32338499]
  end
end

class JsonGenerate < Benchmark
  struct Coordinate
    include JSON::Serializable

    def initialize(@x : Float64, @y : Float64, @z : Float64, @name : String, @opts : Hash(String, Tuple(Int32, Bool)))
    end
  end

  def initialize(@n = 1_800_000)
    @result = IO::Memory.new
    @data = Array(Coordinate).new
    r = Random.new(0, 0_u64)
    letters = ('a'..'z').to_a
    @n.times do
      @data << Coordinate.new(
        r.next_float.round(10),
        r.next_float.round(10),
        r.next_float.round(10),
        "#{letters.sample(6, r).join} #{r.rand(10_000)}",
        {"1" => {1, true}},
      )
    end
  end

  def run
    {"coordinates": @data,
     "info":        "some info"}.to_json(@result)
    true
  end

  def result
    checksum(@result.to_s)
  end

  def expected
    1584466874
  end
end

class JsonParsePure < Benchmark
  struct Coordinate
    property x, y, z

    def initialize(@x : Float64, @y : Float64, @z : Float64)
    end
  end

  def calc(text)
    jobj = JSON.parse(text)
    coordinates = jobj["coordinates"].as_a
    len = coordinates.size.to_f
    x = y = z = 0.0

    coordinates.each do |coord|
      x += coord["x"].as_f
      y += coord["y"].as_f
      z += coord["z"].as_f
    end

    Coordinate.new(x / len, y / len, z / len)
  end

  getter result
  @text : String

  def initialize
    j = JsonGenerate.new(600_000)
    j.run
    @text = j.@result.to_s
    @result = Coordinate.new(0.0, 0.0, 0.0)
  end

  def run
    @result = calc(@text)
  end

  def expected
    Coordinate.new(0.4999535894712113, 0.5000557786698896, 0.5007583687182091)
  end
end

class JsonParseSerializable < Benchmark
  struct Coordinate
    include JSON::Serializable

    property x : Float64
    property y : Float64
    property z : Float64

    def initialize(@x, @y, @z)
    end
  end

  class Coordinates
    include JSON::Serializable

    property coordinates : Array(Coordinate)
  end

  def calc(text)
    coordinates = Coordinates.from_json(text).coordinates
    len = coordinates.size.to_f
    x = y = z = 0.0

    coordinates.each do |e|
      x += e.x
      y += e.y
      z += e.z
    end

    Coordinate.new(x / len, y / len, z / len)
  end

  getter result
  @text : String

  def initialize
    j = JsonGenerate.new(800_000)
    j.run
    @text = j.@result.to_s
    @result = Coordinate.new(0.0, 0.0, 0.0)
  end

  def run
    @result = calc(@text)
  end

  def expected
    Coordinate.new(0.49986260081788564, 0.5001137023627188, 0.5006048890910882)
  end
end

class JsonParsePull < Benchmark
  struct Coordinate
    property x, y, z

    def initialize(@x : Float64, @y : Float64, @z : Float64)
    end
  end

  def calc(text)
    len = 0
    x = y = z = 0.0

    pull = JSON::PullParser.new(text)
    pull.on_key!("coordinates") do
      pull.read_array do
        len += 1
        pull.read_object do |key|
          case key
          when "x" then x += pull.read_float
          when "y" then y += pull.read_float
          when "z" then z += pull.read_float
          else          pull.skip
          end
        end
      end
    end

    Coordinate.new(x / len, y / len, z / len)
  end

  getter result
  @text : String

  def initialize
    j = JsonGenerate.new(800_000)
    j.run
    @text = j.@result.to_s
    @result = Coordinate.new(0.0, 0.0, 0.0)
  end

  def run
    @result = calc(@text)
  end

  def expected
    Coordinate.new(0.49986260081788564, 0.5001137023627188, 0.5006048890910882)
  end
end

class Mandelbrot2 < Benchmark
  # from https://github.com/crystal-lang/crystal/blob/master/samples/mandelbrot2.cr
  def initialize(@n = 40)
    @res = 0_u64
  end

  def mandelbrot(a)
    Iterator.of(a).first(100).reduce(a) { |z, c| z*z + c }
  end

  def run
    res = 0_u64
    n = @n.to_f
    n.step(to: -n, by: -0.05) do |y|
      (-n).to_f.step(to: n, by: 0.0315) do |x|
        res &+= ((mandelbrot(x + y.i).abs < 2) ? '*' : ' ').ord
      end
    end
    @res = res
  end

  def result
    @res
  end

  def expected
    130139180
  end
end

class Noise < Benchmark
  # from https://github.com/crystal-lang/crystal/blob/master/samples/noise.cr
  RANDOM = Random.new(0_u64, 0_u64)

  SIZE = 256
  record Vec2, x : Float64, y : Float64

  @[AlwaysInline]
  def self.lerp(a, b, v)
    a * (1.0 - v) + b * v
  end

  @[AlwaysInline]
  def self.smooth(v)
    v * v * (3.0 - 2.0 * v)
  end

  @[AlwaysInline]
  def self.random_gradient
    v = RANDOM.next_float * Math::PI * 2.0
    Vec2.new(Math.cos(v), Math.sin(v))
  end

  @[AlwaysInline]
  def self.gradient(orig, grad, p)
    sp = Vec2.new(p.x - orig.x, p.y - orig.y)
    grad.x * sp.x + grad.y * sp.y
  end

  struct Noise2DContext
    def initialize
      @rgradients = StaticArray(Vec2, 256).new { Noise.random_gradient }
      @permutations = StaticArray(Int32, 256).new { |i| i }
      @permutations.shuffle!(RANDOM)
    end

    @[AlwaysInline]
    def get_gradient(x, y)
      idx = @permutations[x & 255] + @permutations[y & 255]
      @rgradients[idx & 255]
    end

    def get_gradients(x, y)
      x0f = x.floor
      y0f = y.floor
      x0 = x0f.to_i
      y0 = y0f.to_i
      x1 = x0 + 1
      y1 = y0 + 1

      {
        {
          get_gradient(x0, y0),
          get_gradient(x1, y0),
          get_gradient(x0, y1),
          get_gradient(x1, y1),
        },
        {
          Vec2.new(x0f + 0.0, y0f + 0.0),
          Vec2.new(x0f + 1.0, y0f + 0.0),
          Vec2.new(x0f + 0.0, y0f + 1.0),
          Vec2.new(x0f + 1.0, y0f + 1.0),
        },
      }
    end

    def get(x, y)
      p = Vec2.new(x, y)
      gradients, origins = get_gradients(x, y)
      v0 = Noise.gradient(origins[0], gradients[0], p)
      v1 = Noise.gradient(origins[1], gradients[1], p)
      v2 = Noise.gradient(origins[2], gradients[2], p)
      v3 = Noise.gradient(origins[3], gradients[3], p)
      fx = Noise.smooth(x - origins[0].x)
      vx0 = Noise.lerp(v0, v1, fx)
      vx1 = Noise.lerp(v2, v3, fx)
      fy = Noise.smooth(y - origins[0].y)
      Noise.lerp(vx0, vx1, fy)
    end
  end

  SYM = [' ', '░', '▒', '▓', '█', '█']

  def noise
    pixels = Array.new(256) { Array.new(256, 0.0) }

    n2d = Noise2DContext.new

    100.times do |i|
      256.times do |y|
        256.times do |x|
          v = n2d.get(x * 0.1, (y + (i * 128)) * 0.1) * 0.5 + 0.5
          pixels[y][x] = v
        end
      end
    end

    res = 0_u64

    256.times do |y|
      256.times do |x|
        v = pixels[y][x]
        res &+= SYM[(v / 0.2).to_i].ord
      end
    end
    res
  end

  def initialize(@n = 35)
    @res = 0_u64
  end

  def run
    @n.times do
      @res &+= noise
    end
  end

  def result
    @res
  end

  def expected
    22052067725
  end
end

class Sudoku < Benchmark
  # from https://github.com/crystal-lang/crystal/blob/master/samples/sudoku.cr

  def sd_genmat
    mr = Array.new(324) { [] of Int32 }
    mc = Array.new(729) { [] of Int32 }
    r = 0
    (0...9).each do |i|
      (0...9).each do |j|
        (0...9).each do |k|
          mc[r] = [9 * i + j, (i // 3 * 3 + j // 3) * 9 + k + 81, 9 * i + k + 162, 9 * j + k + 243]
          r += 1
        end
      end
    end
    (0...729).each do |r2|
      (0...4).each do |c2|
        mr[mc[r2][c2]].push(r2)
      end
    end
    {mr, mc}
  end

  def sd_update(mr, mc, sr, sc, r, v)
    min, min_c = 10, 0
    (0...4).each do |c2|
      if v > 0
        sc[mc[r][c2]] += 128
      else
        sc[mc[r][c2]] -= 128
      end
    end
    (0...4).each do |c2|
      c = mc[r][c2]
      if v > 0
        (0...9).each do |r2|
          rr = mr[c][r2]
          sr[rr] += +1
          if sr[rr] == 1
            p = mc[rr]
            sc[p[0]] -= 1; sc[p[1]] -= 1; sc[p[2]] -= 1; sc[p[3]] -= 1
            if sc[p[0]] < min
              min, min_c = sc[p[0]], p[0]
            end
            if sc[p[1]] < min
              min, min_c = sc[p[1]], p[1]
            end
            if sc[p[2]] < min
              min, min_c = sc[p[2]], p[2]
            end
            if sc[p[3]] < min
              min, min_c = sc[p[3]], p[3]
            end
          end
        end
      else
        (0...9).each do |r2|
          rr = mr[c][r2]
          sr[rr] -= 1
          if sr[rr] == 0
            p = mc[rr]
            sc[p[0]] += 1; sc[p[1]] += 1; sc[p[2]] += 1; sc[p[3]] += 1
          end
        end
      end
    end
    {min, min_c}
  end

  def sd_solve(mr, mc, s)
    ret = [] of Array(Int32)
    sr, sc, hints = Array.new(729, 0), Array.new(324, 9), 0
    (0...81).each do |i|
      a = ('1' <= s[i] <= '9') ? s[i].ord - 49 : -1
      if a >= 0
        sd_update(mr, mc, sr, sc, i * 9 + a, 1)
        hints += 1
      end
    end
    cr, cc = Array.new(81, -1), Array.new(81, 0)
    i, min, dir = 0, 10, 1
    loop do
      while i >= 0 && i < 81 - hints
        if dir == 1
          if min > 1
            (0...324).each do |c|
              if sc[c] < min
                min, cc[i] = sc[c], c
                break if min < 2
              end
            end
          end
          if min == 0 || min == 10
            cr[i], dir, i = -1, -1, i - 1
          end
        end
        c = cc[i]
        if dir == -1 && cr[i] >= 0
          sd_update(mr, mc, sr, sc, mr[c][cr[i]], -1)
        end
        r2_ = 9
        (cr[i] + 1...9).each do |r2|
          if sr[mr[c][r2]] == 0
            r2_ = r2
            break
          end
        end
        if r2_ < 9
          min, cc[i + 1] = sd_update(mr, mc, sr, sc, mr[c][r2_], 1)
          cr[i], dir, i = r2_, 1, i + 1
        else
          cr[i], dir, i = -1, -1, i - 1
        end
      end
      break if i < 0
      o = [] of Int32
      (0...81).each { |j| o.push((s[j].ord - 49).to_i32) }
      (0...i).each do |j|
        r = mr[cc[j]][cr[j]]
        o[r // 9] = r % 9 + 1
      end
      ret.push(o)
      i, dir = i - 1, -1
    end
    ret
  end

  SUDOKU = <<-SUDOKU
..............3.85..1.2.......5.7.....4...1...9.......5......73..2.1........4...9 # near worst case for brute-force solver (wiki)
.......12........3..23..4....18....5.6..7.8.......9.....85.....9...4.5..47...6... # gsf's sudoku q1 (Platinum Blonde)
.2..5.7..4..1....68....3...2....8..3.4..2.5.....6...1...2.9.....9......57.4...9.. # (Cheese)
........3..1..56...9..4..7......9.5.7.......8.5.4.2....8..2..9...35..1..6........ # (Fata Morgana)
12.3....435....1....4........54..2..6...7.........8.9...31..5.......9.7.....6...8 # (Red Dwarf)
1.......2.9.4...5...6...7...5.9.3.......7.......85..4.7.....6...3...9.8...2.....1 # (Easter Monster)
.......39.....1..5..3.5.8....8.9...6.7...2...1..4.......9.8..5..2....6..4..7..... # Nicolas Juillerat's Sudoku explainer 1.2.1 (top 5)
12.3.....4.....3....3.5......42..5......8...9.6...5.7...15..2......9..6......7..8
..3..6.8....1..2......7...4..9..8.6..3..4...1.7.2.....3....5.....5...6..98.....5.
1.......9..67...2..8....4......75.3...5..2....6.3......9....8..6...4...1..25...6.
..9...4...7.3...2.8...6...71..8....6....1..7.....56...3....5..1.4.....9...2...7..
....9..5..1.....3...23..7....45...7.8.....2.......64...9..1.....8..6......54....7 # dukuso's suexrat9 (top 1)
7.8...3.....2.1...5.........4.....263...8.......1...9..9.6....4....7.5...........
3.7.4...........918........4.....7.....16.......25..........38..9....5...2.6.....
........8..3...4...9..2..6.....79.......612...6.5.2.7...8...5...1.....2.4.5.....3 # dukuso's suexratt (top 1)
.......1.4.........2...........5.4.7..8...3....1.9....3..4..2...5.1........8.6... # first 2 from sudoku17
.......12....35......6...7.7.....3.....4..8..1...........12.....8.....4..5....6..
1.......2.9.4...5...6...7...5.3.4.......6........58.4...2...6...3...9.8.7.......1
.....1.2.3...4.5.....6....7..2.....1.8..9..3.4.....8..5....2....9..3.4....67.....
SUDOKU

  def solve_all(sudoku)
    mr, mc = sd_genmat()
    sudoku.split('\n').compact_map do |line|
      if line.size >= 81
        ret = sd_solve(mr, mc, line)
        ret.map(&.join)
      end
    end
  end

  def initialize(@n = 50)
    @buf = IO::Memory.new
  end

  def run
    @n.times do |i|
      res = solve_all(SUDOKU)
      res.each { |str| @buf << str }
    end
  end

  def result
    checksum(@buf.to_s)
  end

  def expected
    3422637057
  end
end

class TextRaytracer < Benchmark
  # from https://github.com/crystal-lang/crystal/blob/master/samples/text_raytracer.cr

  record Vector, x : Float64, y : Float64, z : Float64 do
    @[AlwaysInline]
    def scale(s)
      Vector.new(x * s, y * s, z * s)
    end

    @[AlwaysInline]
    def +(other)
      Vector.new(x + other.x, y + other.y, z + other.z)
    end

    @[AlwaysInline]
    def -(other)
      Vector.new(x - other.x, y - other.y, z - other.z)
    end

    @[AlwaysInline]
    def dot(other)
      x*other.x + y*other.y + z*other.z
    end

    @[AlwaysInline]
    def magnitude
      Math.sqrt self.dot(self)
    end

    @[AlwaysInline]
    def normalize
      scale(1.0 / magnitude)
    end
  end

  record Ray, orig : Vector, dir : Vector

  record Color, r : Float64, g : Float64, b : Float64 do
    @[AlwaysInline]
    def scale(s)
      Color.new(r * s, g * s, b * s)
    end

    @[AlwaysInline]
    def +(other)
      Color.new(r + other.r, g + other.g, b + other.b)
    end
  end

  record Sphere, center : Vector, radius : Float64, color : Color do
    @[AlwaysInline]
    def get_normal(pt)
      (pt - center).normalize
    end
  end

  record Light, position : Vector, color : Color

  record Hit, obj : Sphere, value : Float64

  WHITE = Color.new(1.0, 1.0, 1.0)
  RED   = Color.new(1.0, 0.0, 0.0)
  GREEN = Color.new(0.0, 1.0, 0.0)
  BLUE  = Color.new(0.0, 0.0, 1.0)

  LIGHT1 = Light.new(Vector.new(0.7, -1.0, 1.7), WHITE)

  def shade_pixel(ray, obj, tval)
    pi = ray.orig + ray.dir.scale(tval)
    color = diffuse_shading pi, obj, LIGHT1
    col = (color.r + color.g + color.b) / 3.0
    (col * 6.0).to_i
  end

  def intersect_sphere(ray, center, radius)
    l = center - ray.orig
    tca = l.dot(ray.dir)
    if tca < 0.0
      return nil
    end

    d2 = l.dot(l) - tca*tca
    r2 = radius*radius
    if d2 > r2
      return nil
    end

    thc = Math.sqrt(r2 - d2)
    t0 = tca - thc
    # t1 = tca + thc
    if t0 > 10_000
      return nil
    end

    t0
  end

  def clamp(x, a, b)
    return a if x < a
    return b if x > b
    x
  end

  def diffuse_shading(pi, obj, light)
    n = obj.get_normal(pi)
    lam1 = (light.position - pi).normalize.dot(n)
    lam2 = clamp lam1, 0.0, 1.0
    light.color.scale(lam2*0.5) + obj.color.scale(0.3)
  end

  LUT = ['.', '-', '+', '*', 'X', 'M']

  SCENE = [
    Sphere.new(Vector.new(-1.0, 0.0, 3.0), 0.3, RED),
    Sphere.new(Vector.new(0.0, 0.0, 3.0), 0.8, GREEN),
    Sphere.new(Vector.new(1.0, 0.0, 3.0), 0.4, BLUE),
  ]

  def initialize(@w : Int32 = 2500 * 4, @h : Int32 = 2200 * 4)
    @res = 0_u64
  end

  def run
    res = 0_u64
    (0...@h).each do |j|
      # puts "--"
      (0...@w).each do |i|
        fw, fi, fj, fh = @w.to_f, i.to_f, j.to_f, @h.to_f

        ray = Ray.new(
          Vector.new(0.0, 0.0, 0.0),
          Vector.new((fi - fw/2.0)/fw, (fj - fh/2.0)/fh, 1.0).normalize
        )

        hit = nil

        SCENE.each do |obj|
          ret = intersect_sphere(ray, obj.center, obj.radius)
          if ret
            hit = Hit.new obj, ret
          end
        end

        if hit
          pixel = LUT[shade_pixel(ray, hit.obj, hit.value)]
        else
          pixel = ' '
        end

        res &+= pixel.ord
      end
    end
    @res = res
  end

  def result
    @res
  end

  def expected
    3165789000
  end
end

# implement each_cartesian for older crystal
{% if compare_versions(Crystal::VERSION, "1.2.2") < 0 %}
module Indexable(T)
  def each_cartesian(other, &block)
    Indexable.each_cartesian_impl(self, other) { |v| yield v }
  end

  protected def self.each_cartesian_impl(a, b, &block) forall U
    indexables = [a, b]
    lens = indexables.map &.size
    return if lens.any? &.zero?

    n = indexables.size
    indices = Array.new(n, 0)
    indices[-1] -= 1

    while true
      i = n - 1
      indices[i] += 1

      while indices[i] >= lens[i]
        indices[i] = 0
        i -= 1
        return if i < 0
        indices[i] += 1
      end

      {% begin %}
        yield Tuple.new(
          {% for i in 0...2 %}
            indexables[{{ i }}].unsafe_fetch(indices[{{ i }}]),
          {% end %}
        )
      {% end %}
    end
  end
end
{% end %}

class NeuralNet < Benchmark
  # from https://github.com/crystal-lang/crystal/blob/master/samples/neural_net.cr

  RANDOM = Random.new(0_u64, 0_u64)

  class Synapse
    property weight : Float64
    property prev_weight : Float64
    property :source_neuron
    property :dest_neuron

    def initialize(@source_neuron : Neuron, @dest_neuron : Neuron)
      @prev_weight = @weight = RANDOM.next_float * 2 - 1
    end
  end

  class Neuron
    LEARNING_RATE = 1.0
    MOMENTUM      = 0.3

    property :synapses_in
    property :synapses_out
    property threshold : Float64
    property prev_threshold : Float64
    property :error
    property :output

    def initialize
      @prev_threshold = @threshold = RANDOM.next_float * 2 - 1
      @synapses_in = [] of Synapse
      @synapses_out = [] of Synapse
      @output = 0.0
      @error = 0.0
    end

    def calculate_output
      activation = synapses_in.reduce(0.0) do |sum, synapse|
        sum + synapse.weight * synapse.source_neuron.output
      end
      activation -= threshold

      @output = 1.0 / (1.0 + Math.exp(-activation))
    end

    def derivative
      output * (1 - output)
    end

    def output_train(rate, target)
      @error = (target - output) * derivative
      update_weights(rate)
    end

    def hidden_train(rate)
      @error = synapses_out.reduce(0.0) do |sum, synapse|
        sum + synapse.prev_weight * synapse.dest_neuron.error
      end * derivative
      update_weights(rate)
    end

    def update_weights(rate)
      synapses_in.each do |synapse|
        temp_weight = synapse.weight
        synapse.weight += (rate * LEARNING_RATE * error * synapse.source_neuron.output) + (MOMENTUM * (synapse.weight - synapse.prev_weight))
        synapse.prev_weight = temp_weight
      end
      temp_threshold = threshold
      @threshold += (rate * LEARNING_RATE * error * -1) + (MOMENTUM * (threshold - prev_threshold))
      @prev_threshold = temp_threshold
    end
  end

  class NeuralNetwork
    @input_layer : Array(Neuron)
    @hidden_layer : Array(Neuron)
    @output_layer : Array(Neuron)

    def initialize(inputs, hidden, outputs)
      @input_layer = (1..inputs).map { Neuron.new }
      @hidden_layer = (1..hidden).map { Neuron.new }
      @output_layer = (1..outputs).map { Neuron.new }

      @input_layer.each_cartesian(@hidden_layer) do |source, dest|
        synapse = Synapse.new(source, dest)
        source.synapses_out << synapse
        dest.synapses_in << synapse
      end
      @hidden_layer.each_cartesian(@output_layer) do |source, dest|
        synapse = Synapse.new(source, dest)
        source.synapses_out << synapse
        dest.synapses_in << synapse
      end
    end

    def train(inputs, targets)
      feed_forward(inputs)

      @output_layer.zip(targets) do |neuron, target|
        neuron.output_train(0.3, target)
      end
      @hidden_layer.each do |neuron|
        neuron.hidden_train(0.3)
      end
    end

    def feed_forward(inputs)
      @input_layer.zip(inputs) do |neuron, input|
        neuron.output = input.to_f64
      end
      @hidden_layer.each do |neuron|
        neuron.calculate_output if neuron
      end
      @output_layer.each do |neuron|
        neuron.calculate_output if neuron
      end
    end

    def current_outputs
      @output_layer.map do |neuron|
        neuron.output
      end
    end
  end

  def initialize(@n = 1500000)
    @res = [] of Float64
  end

  def run
    xor = NeuralNetwork.new(2, 10, 1)

    @n.times do
      xor.train([0, 0], [0])
      xor.train([1, 0], [1])
      xor.train([0, 1], [1])
      xor.train([1, 1], [0])
    end

    xor.feed_forward([0, 0])
    @res += xor.current_outputs
    xor.feed_forward([0, 1])
    @res += xor.current_outputs
    xor.feed_forward([1, 0])
    @res += xor.current_outputs
    xor.feed_forward([1, 1])
    @res += xor.current_outputs
  end

  def result
    @res.map &.round(8)
  end

  def expected
    [0.000845335077086041, 0.9990857490807116, 0.9991775011715351, 0.0008922162500023385].map &.round(8)
  end
end
