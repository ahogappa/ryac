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
