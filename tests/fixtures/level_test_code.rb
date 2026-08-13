# Comprehensive Ruby feature test — covers all practical reserved words
module MathUtils
  MULTIPLIER = 2 + 3
  S = 100 * 100 * 100 * 100 * 100 * 100 * 100 * 100 * 100

  def self.double_value(number)
    number * MULTIPLIER * S
  end

  def self.clamp_value(value, min_val, max_val)
    if value < min_val then
      min_val
    elsif value > max_val
      max_val
    else
      value
    end
  end
end

class Base
  def parent_info
    "base"
  end
end

class Calculator < Base
  OFFSET = 1 << 8
  LABELS = %w[low medium high].freeze
  SYMBOLS = %i[add subtract multiply].freeze

  attr_reader :current_value
  attr_accessor :label

  def initialize(initial_value, label: "default")
    @current_value = initial_value
    @label = label
    @history = []
    @@instance_count ||= 0
    @@instance_count += 1
    $last_calculator = self
  end

  def add_number(amount, verbose: false)
    @current_value = @current_value + amount
    @history.push(amount)
    if verbose
      "added"
    else
      "silent"
    end
  end

  def subtract_number(amount)
    @current_value - amount
  end

  alias neg subtract_number

  def multiply_by_offset
    @current_value * Calculator::OFFSET
  end

  def reset_value
    @current_value = 0
    counter = 0
    counter += 1 while counter < 3
    $last_calculator = nil
    counter
  end

  def get_separator
    "x"
  end

  def describe_value
    if @current_value > 100
      "big"
    else
      "small"
    end
  end

  def check_positive
    unless @current_value > 0
      "non-positive"
    end
  end

  def process_items(items)
    items.each do |item|
      puts item
    end
  end

  def safe_divide(divisor)
    begin
      @current_value / divisor
    rescue ZeroDivisionError
      0
    ensure
      @history.push(:divide)
    end
  end

  def classify_value
    case @current_value
    when 0..10
      "low"
    when 11..100
      "medium"
    else
      "high"
    end
  end

  def value_with_label
    "#{@label}: #{@current_value}"
  end

  def to_s
    "Calculator(#{@current_value})"
  end

  def parent_info
    super
  end

  def with_yield
    yield @current_value if block_given?
  end

  def count_up(limit)
    result = []
    idx = 0
    until idx >= limit
      idx += 1
      next if idx == 2
      break if idx > 4
      result.push(idx)
    end
    result
  end

  def retry_example
    attempts = 0
    begin
      attempts += 1
      raise "fail" if attempts < 2
      attempts
    rescue
      retry if attempts < 2
      0
    end
  end

  def check_defined
    defined?(@current_value) ? "yes" : "no"
  end

  def logic_test(flag_a, flag_b)
    if flag_a and not flag_b
      "a only"
    elsif flag_a or flag_b
      "at least one"
    else
      "none"
    end
  end

  def safe_access(obj)
    obj&.to_s
  end

  def return_early(value)
    return "negative" if value < 0
    return "zero" if value == 0
    "positive"
  end

  def multi_assign
    first, *rest = [1, 2, 3, 4]
    first + rest.length
  end

  def splat_args(*args, **kwargs)
    args.length + kwargs.length
  end

  def with_block(&block)
    block ? block.call(@current_value) : nil
  end

  def use_lambda
    fn = ->(val) { val * 2 }
    fn.call(@current_value)
  end

  def heredoc_example
    text = <<~HEREDOC
      hello
      world
    HEREDOC
    text.strip
  end

  def regex_example(input)
    input =~ /^calc/i ? true : false
  end

  def for_loop
    total = 0
    for num in [10, 20, 30]
      total += num
    end
    total
  end

  def rescue_modifier_example
    Integer("abc") rescue 0
  end

  # Negated ternary: !val needs space before ? to avoid val? method parse
  def negated_ternary(val)
    if !val
      "nil"
    else
      val.to_s
    end
  end

  # Array with inline if: modifier-if invalid inside array literal
  def array_with_conditional(flag)
    [1, if flag; 2; end, 3].compact
  end

  # Regex arg: parens must be preserved to avoid /= ambiguity
  def regex_match(str)
    str.match(/=\d+/)
  end

  # Multi-assignment: can't be ternary arm (commas conflict)
  def multi_assign_conditional(flag)
    if flag
      a, b = 1, 2
    else
      a, b = 3, 4
    end
    a + b
  end

  # Block param default: true/false must NOT be shortened to !!1/!1
  # because |a=!!1| parses | as bitwise OR, not block delimiter
  def with_block_default
    [1, 2, 3].select { |val, keep = true| keep }
  end

  # Block with &block param: can't strip to numbered params
  def with_block_param
    [1, 2].map { |num, &callback| callback ? callback.call(num) : num }
  end

  # Block with *rest param: can't strip to numbered params
  def with_rest_param
    [[1, 2, 3]].map { |first, *rest| first + rest.length }
  end

  # Block with keyword param: can't strip to numbered params
  def with_keyword_param
    [{ a: 1 }].each { |val, flag: false| puts val.inspect }
  end

  # define_singleton_method with default block param (must not use numbered params)
  define_singleton_method(:dsl_method) { |verbose = true|
    verbose ? "yes" : "no"
  }

  # Destructured block params: |(sym, num), label| pattern
  def destructured_iteration
    { [:a, 1] => "x" }.each do |(sym, num), label|
      puts "#{sym}#{num}#{label}"
    end
  end

  # send/public_send with symbol argument
  def send_example
    send(:describe_value)
  end

  # Def-on-receiver: block parameter used as def receiver
  def wrap_in_enumerator(value = nil, &block)
    def block.each
      yield(call)
    end
    block
  end
end

class Formatter
  def format_number(value, prefix: "", suffix: "")
    result = "#{prefix}#{value}#{suffix}"
    result
  end

  def format_flag(flag)
    if flag == true
      "yes"
    else
      "no"
    end
  end
end

# === Latent-path hazards: sites type inference cannot see ===

# Dead-path accessor calls: nobody invokes these tuner methods, so inference
# never types `target` — the attr symbols must survive minification or the
# dead sites break the day the paths first run.
class TimeoutConfig
  attr_accessor :timeout_ms
  attr_reader :retry_limit

  def initialize
    @timeout_ms = 100
    @retry_limit = 3
  end
end

class TimeoutTuner
  def bump_timeout(target)
    target.timeout_ms = 500
  end

  def raise_timeout(target)
    target.timeout_ms += 250
  end

  def show_retries(target)
    puts target.retry_limit
  end
end

# Comparable dispatches to <=> from outside the closed world, so `other` is
# never typed and its getter call cannot be resolved.
class VersionTag
  include Comparable
  attr_reader :version_number

  def initialize(number)
    @version_number = number
  end

  def <=>(other)
    version_number <=> other.version_number
  end
end

# attr_writer's declaration never renames; the reader sharing its symbol
# must stay with it or the pair splits across two ivars.
class Payload
  attr_reader :payload_data
  attr_writer :payload_data

  def initialize
    @payload_data = 1
  end
end

# Ivars reached through another object's instance_eval and through
# reflection with a computed name.
class SecretHolder
  def initialize
    @secret_value = 42
  end

  def peek_into(other)
    other.instance_eval { @secret_value }
  end

  def fetch_by_name(name)
    instance_variable_get("@" + name)
  end
end

# define_method body reading an ivar the initializer writes.
class LabeledWidget
  def initialize
    @widget_label = "w"
  end

  define_method(:show_label) { @widget_label }
end

# One call site dispatching over classes held in data — inference can miss
# a member, and every same-named def must rename in lockstep.
class AddStep
  def self.apply_step(value)
    value + 10
  end
end

class DoubleStep
  def self.apply_step(value)
    value * 2
  end
end

PIPELINE_STEPS = [AddStep, DoubleStep].freeze

# === Grab-bag syntax from irb sessions, quines and code golf ===

# Pattern matching: array/hash patterns, alternation with guard, expression
# pin, rightward assignment, one-line `in` (parens are load-bearing: bare
# `def f =expr in pat` rebinds the match to the def itself), and find
# patterns with NAMED splats. Anonymous-splat find patterns (`[*, x, *]`)
# and `**nil` stay absent until the bundled typeprof carries
# ruby/typeprof#465 — those shapes crash 0.32.0's ingestion and the
# analyzer says so by name.
class PatternMatcher
  def classify(obj)
    case obj
    in [Integer => head, *rest] then "array head #{head} rest #{rest.size}"
    in { kind: String => kind, value: } then "hash #{kind} #{value}"
    in Integer | Float => num if num > 100 then "big #{num}"
    in ^(0..10) then "small"
    else "other"
    end
  end

  def rightward
    point = [3, 7]
    point => [x_pos, y_pos]
    x_pos * y_pos
  end

  def one_line_match?(value) = (value in { status: :ok })

  def tail_pattern(list)
    case list
    in [_, *, last_el] then last_el
    else -1
    end
  end

  def find_middle(list)
    case list
    in [*front, Symbol => marker, *back] then "#{front.size}<#{marker}>#{back.size}"
    else "none"
    end
  end
end

# Operator definitions ([], []=, +, unary -, ==), proc-call sugar `.()`,
# explicit numbered params, &:sym to_proc, and the method_missing pair.
class GolfVector
  def initialize(*coords) = @coords = coords
  def [](idx) = @coords[idx]
  def []=(idx, val)
    @coords[idx] = val
  end
  def +(other) = GolfVector.new(*@coords.zip(other.to_a).map(&:sum))
  def -@ = GolfVector.new(*@coords.map { _1 * -1 })
  def to_a = @coords
  def ==(other) = to_a == other.to_a
  def call(scale) = GolfVector.new(*@coords.map { _1 * scale })
  def method_missing(name, *args)
    name.to_s.start_with?("coord_") ? @coords[name.to_s.delete_prefix("coord_").to_i] : super
  end
  def respond_to_missing?(name, include_private = false)
    name.to_s.start_with?("coord_") || super
  end
end

# Every literal spelling the main corpus doesn't use: number bases and
# separators, rational/imaginary/exponent, %q/%Q/%r/%s/%W, quoted symbols
# with interpolation, and a non-interpolating heredoc.
class LiteralShowcase
  HEX_MASK = 0xff
  OCTAL_MODE = 0o755
  BINARY_FLAGS = 0b1010
  BIG_COUNT = 1_000_000
  A_THIRD = 1/3r
  IMAGINARY = 2i
  FLOAT_EXP = 15e2

  def string_forms(unit)
    plain = %q(single 'quoted')
    fancy = %Q(double "#{unit}")
    pattern = %r{go+lf}i
    sym = %s(percent_symbol)
    quoted_sym = :"quoted #{unit}"
    words = %W[one_#{unit} two_#{unit}]
    raw = <<-'RAW'
      no #{interpolation} here
    RAW
    [plain, fancy, pattern.source, sym, quoted_sym, words.inspect, raw.strip].join("|")
  end

  def number_report = [HEX_MASK, OCTAL_MODE, BINARY_FLAGS, BIG_COUNT, A_THIRD, IMAGINARY, FLOAT_EXP].join(",")
end

# Control-flow golf: do-while, flip-flop, loop+break value, catch/throw,
# multiple return values, next with value, begin/rescue/else, subject-less
# case, beginless/endless ranges, splatting ranges into a literal.
class ControlGolf
  def do_while_count
    n = 0
    begin
      n += 1
    end while n < 3
    n
  end

  def flip_flop_slice = (1..9).select { |i| true if (i == 3)..(i == 5) }

  def loop_with_break_value
    i = 0
    loop do
      i += 2
      break i if i > 5
    end
  end

  def throw_catch(limit)
    catch(:done) do
      (1..).each { |i| throw :done, i * 10 if i >= limit }
    end
  end

  def early_values(flag)
    return 1, 2 if flag
    [3, 4]
  end

  def block_next_break = [1, 2, 3, 4].map { |i| next 0 if i.odd?; i * i }

  def begin_else
    begin
      value = 7
    rescue StandardError
      value = -1
    else
      value += 1
    ensure
      @last_value = value
    end
    value
  end

  def case_without_subject(n)
    case
    when n < 0 then "neg"
    when n == 0 then "zero"
    else "pos"
    end
  end

  def beginless_endless(n) = [(..5).include?(n), (5..).include?(n)]

  def splat_expansion = [*'a'..'c', *1..2]
end

# Quine flavor: __method__ stays truthful because method(:whoami) pins the
# name; eval sees the original local names, so its scope must not rename;
# a regex named capture writes the local named after the group.
class ReflectionGolf
  def whoami = __method__
  def method_ref_arity = method(:whoami).arity
  def eval_with_local
    golf_score = 42
    eval("golf_score - 2")
  end
  def named_captures(input)
    /(?<num_part>\d+)-(?<word_part>\w+)/ =~ input
    "#{word_part}:#{num_part}"
  end
  def format_report(value) = format("%05d|%p|%x", value, value.to_s, value)
end

class Undeffed
  def temp_method = "gone"
  def kept_method = "kept"
  undef temp_method
end

class AliasedImpl
  def original_impl = "impl"
  alias_method :mirrored, :original_impl
end

# Argument forwarding (`...` and anonymous block) and hash shorthand. The
# shorthand can also pun on a METHOD (`describe(unit_label:)` calls
# unit_label) — that keyword must survive renaming or the pun re-resolves.
class ForwardingGolf
  def base_sum(a_val, b_val, scale: 1) = (a_val + b_val) * scale
  def forward_all(...) = base_sum(...)
  def forward_block(&) = [1, 2].sum(&)
  def shorthand_hash(width)
    height = width * 2
    { width:, height: }
  end
  def unit_label = "cm"
  def describe(unit_label:) = "unit=#{unit_label}"
  def punned_describe = describe(unit_label:)
end

# Class-body ivar behind a singleton attr_reader, Struct with a body,
# Data.define, ** power, and explicit super with arguments.
class Registry
  @entries = []
  class << self
    attr_reader :entries
    def register(name) = @entries << name
  end
end

PointStruct = Struct.new(:x_coord, :y_coord) do
  def magnitude = (x_coord**2 + y_coord**2)**0.5
end

FrozenPoint = Data.define(:col, :row)

class Origin < PointStruct
  def initialize = super(0, 0)
end

# Main execution
calc = Calculator.new(10, label: "main")
calc.add_number(5, verbose: true)
calc.add_number(3, verbose: false)
puts calc.subtract_number(2)
puts calc.neg(1)
puts calc.multiply_by_offset
puts calc.reset_value
puts Calculator::OFFSET
puts calc.get_separator
puts calc.describe_value
puts calc.check_positive
puts calc.safe_divide(0)
puts calc.classify_value
puts calc.value_with_label
puts calc.to_s
puts calc.parent_info
calc.with_yield { |v| puts v }
puts calc.count_up(5).inspect
puts calc.retry_example
puts calc.check_defined
puts calc.logic_test(true, false)
puts calc.logic_test(false, true)
puts calc.logic_test(false, false)
puts calc.safe_access("hello")
puts calc.safe_access(nil)
puts calc.return_early(-1)
puts calc.return_early(0)
puts calc.return_early(1)
puts calc.multi_assign
puts calc.splat_args(1, 2, 3, a: 4)
puts calc.with_block { |v| v + 100 }
puts calc.use_lambda
puts calc.heredoc_example
puts calc.regex_example("calculator")
puts calc.regex_example("other")
puts calc.for_loop
puts calc.rescue_modifier_example
puts calc.negated_ternary(nil)
puts calc.negated_ternary("hi")
puts calc.array_with_conditional(true).inspect
puts calc.array_with_conditional(false).inspect
puts calc.regex_match("x=42")
puts calc.regex_match("hello")
puts calc.multi_assign_conditional(true)
puts calc.multi_assign_conditional(false)
puts calc.with_block_default.inspect
puts calc.with_block_param.inspect
puts calc.with_rest_param.inspect
calc.with_keyword_param
puts Calculator.dsl_method
puts Calculator.dsl_method(false)
puts calc.send_example
calc.destructured_iteration
puts calc.wrap_in_enumerator { "hello" }.class
puts MathUtils::MULTIPLIER
puts MathUtils.double_value(7)
puts MathUtils.clamp_value(150, 0, 100)

fmt = Formatter.new
puts fmt.format_number(42, prefix: "$", suffix: "!")
puts fmt.format_flag(true)
puts fmt.format_flag(false)

doubled = MathUtils.double_value(Calculator::OFFSET)
puts doubled

puts Calculator::LABELS.inspect
puts Calculator::SYMBOLS.inspect

# External prefix aliasing: multiple references to same prefix
puts Process::Status.name
puts Process::Sys.name
puts Process::UID.name
puts Process::GID.name

# Latent-path hazards: live halves only — the tuner methods stay uncalled
config = TimeoutConfig.new
TimeoutTuner.new
puts config.timeout_ms
puts config.retry_limit
puts VersionTag.new(1) < VersionTag.new(2)
payload = Payload.new
payload.payload_data = 9
puts payload.payload_data
holder = SecretHolder.new
puts holder.peek_into(SecretHolder.new)
puts holder.fetch_by_name("secret_value")
puts LabeledWidget.new.show_label
puts PIPELINE_STEPS.reduce(5) { |acc, step| step.apply_step(acc) }

# Grab-bag syntax: live halves
pm = PatternMatcher.new
puts pm.classify([5, 1])
puts pm.classify({ kind: "gold", value: 3 })
puts pm.classify(500)
puts pm.classify(7)
puts pm.classify("x")
puts pm.rightward
puts pm.one_line_match?({ status: :ok })
puts pm.tail_pattern([:a, :b, :c])
puts pm.find_middle([1, 2, :mid, 3])
puts pm.find_middle([1, 2])
vec = GolfVector.new(3, -4)
puts vec[0]
vec[1] = 5
puts (vec + GolfVector.new(1, 1)).to_a.inspect
puts (-vec).to_a.inspect
puts vec.(2).to_a.inspect
puts vec.coord_0
puts vec == GolfVector.new(3, 5)
ls = LiteralShowcase.new
puts ls.string_forms("m")
puts ls.number_report
cg = ControlGolf.new
puts cg.do_while_count
puts cg.flip_flop_slice.inspect
puts cg.loop_with_break_value
puts cg.throw_catch(4)
p cg.early_values(true)
puts cg.block_next_break.inspect
puts cg.begin_else
puts cg.case_without_subject(0)
puts cg.beginless_endless(3).inspect
puts cg.splat_expansion.inspect
rg = ReflectionGolf.new
puts rg.whoami
puts rg.method_ref_arity
puts rg.eval_with_local
puts rg.named_captures("42-golf")
puts rg.format_report(255)
puts Undeffed.new.respond_to?(:temp_method)
puts Undeffed.new.kept_method
puts AliasedImpl.new.mirrored
fg = ForwardingGolf.new
puts fg.forward_all(2, 3, scale: 2)
puts fg.forward_block { _1 * 10 }
puts fg.shorthand_hash(4).values.inspect
puts fg.punned_describe
Registry.register("x")
puts Registry.entries.inspect
puts PointStruct.new(3, 4).magnitude
puts FrozenPoint.new(col: 1, row: 2).row
puts Origin.new.x_coord
