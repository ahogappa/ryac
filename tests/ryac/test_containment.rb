# frozen_string_literal: true

require_relative '../test_helper'

# Boundary lints: rules the code claims in comments, checked as tests so a
# violation fails the run that introduces it instead of surfacing later as
# a broken artifact.
class TestContainment < Minitest::Test
  LIB = File.expand_path('../../lib', __dir__)
  SIG = File.expand_path('../../sig', __dir__)
  ORACLE = 'ryac/analysis/type_oracle.rb'

  # Comment stripping is crude on purpose — the point is a stable,
  # self-consistent count, not a parser. The TypeProf lints accept the same
  # crudeness: the strip can cut inside a string literal, but a spelling
  # hiding in one is not a compile-time dependency anyway.
  def each_code_line(root, glob)
    Dir.glob(File.join(root, glob)).sort.each do |path|
      rel = path.delete_prefix("#{root}/")
      File.foreach(path).with_index(1) do |line, lineno|
        yield rel, lineno, line.sub(/#(?!\{).*/, '')
      end
    end
  end

  # TypeOracle is the one file allowed to touch TypeProf: constants,
  # private ivars, everything. Anything else reaching for them would break
  # somewhere other than the adapter on the next upstream change. Bare
  # spellings count too — a `send` or `const_get` smuggles the dependency
  # as surely as `TypeProf::` does.
  TYPEPROF_SPELLINGS = /\bTypeProf\b|\binstance_variable_get\b|@raw_node/

  # Non-oracle lines allowed a TypeProf-ism: the symbol table naming the
  # dynamic ivar APIs a user program might call, and the composition-error
  # message that names the engine to its user. Each exemption removes only
  # its own spelling from the line and lints whatever remains.
  ALLOWED_SPELLINGS = {
    'ryac/analysis/ivar/collection.rb' => /instance_variable_get/,
    'ryac/pipeline/stage_runner.rb' => /TypeProf runs once/,
  }.freeze

  def test_typeprof_is_confined_to_the_oracle
    offenders = [] #: Array[String]
    each_code_line(LIB, '**/*.rb') do |rel, lineno, code|
      next if rel == ORACLE
      code = code.gsub(ALLOWED_SPELLINGS[rel], '') if ALLOWED_SPELLINGS[rel]
      offenders << "#{rel}:#{lineno}" if code.match?(TYPEPROF_SPELLINGS)
    end
    assert_equal [], offenders
  end

  # The same boundary at the type level: only the oracle's signature may
  # name TypeProf types — whether spelled out or through the tp_* aliases
  # it declares — and the shims exist to declare TypeProf itself.
  def test_typeprof_is_confined_in_sig_too
    offenders = [] #: Array[String]
    each_code_line(SIG, '**/*.rbs') do |rel, lineno, code|
      next if rel == 'ryac/analysis/type_oracle.rbs' || rel.start_with?('shims/')
      offenders << "#{rel}:#{lineno}" if code.match?(/\bTypeProf\b|\btp_node\b|\btp_genv\b/)
    end
    assert_equal [], offenders
  end

  # Self-host containment ratchet: the alias tables rewrite these dotted
  # spellings wherever inference proves the receiver, and inference over
  # lib's own source can succeed on one self-hosting pass and not the
  # other — so lib prefers the spellings its own pipeline rewrites TO
  # (`size`, `[0]`, `any?`, `key?`, ...). The pattern set is derived from
  # the tables, so a new alias row arrives already ratcheted at zero.
  # Existing violations are grandfathered at these exact counts. The budget
  # is lib-wide, not per-file: new code must not raise a pin, and a sweep
  # lowers the one it touches.
  GRANDFATHERED = {
    object_id: 12, # identity bookkeeping; sweep to __id__ pending
    collect: 1,    # Stage#collect, the stage contract — not Enumerable
    length: 10,
    include?: 77,
    first: 28,
    empty?: 46,
  }.freeze

  def test_selfhost_containment_ratchet
    mids = (Ryac::METHOD_ALIASES.keys + Ryac::METHOD_TRANSFORMS.keys.map { |mid, _| mid }).uniq
    patterns = mids.to_h do |mid|
      tail = mid.to_s.end_with?('?', '!') ? '' : '(?![\w?!])'
      [mid, /\.#{Regexp.escape(mid.to_s)}#{tail}/]
    end
    counts = mids.to_h { |mid| [mid, 0] }
    each_code_line(LIB, '**/*.rb') do |_rel, _lineno, code|
      mids.each { |mid| counts[mid] += code.scan(patterns[mid]).size }
    end
    assert_equal mids.to_h { |mid| [mid, GRANDFATHERED.fetch(mid, 0)] }, counts
  end
end
