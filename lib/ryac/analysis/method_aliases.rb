# frozen_string_literal: true

module Ryac
  # Method alias mappings: longer method name => shorter equivalent
  # TypeProf verifies at analysis time that the shorter method
  # is available on the receiver type via inheritance chain.
  #
  # SELF-HOSTING NOTE: these rewrites fire only where inference proves
  # the receiver, and inference over lib/'s own source can shift between
  # self-hosting passes; the integration suite's fixed-point check is what
  # catches a rewrite firing on one pass only.
  # Object/Kernel aliases where both spellings name the same method on
  # EVERY receiver — the only rows safe on a receiverless call, which
  # dispatches on whatever self happens to be.
  KERNEL_ALIASES = {
    kind_of?:   :is_a?,
    yield_self: :then,
    object_id:  :__id__,
    raise:      :fail,
  }.freeze

  # Receiver-specific synonyms (Enumerable/Hash/String/...): a receiverless
  # spelling can name something else entirely (`include?` in a class body is
  # Module#include?), so these fire only when inference proves the receiver
  # responds to the short spelling.
  RECEIVER_ALIASES = {
    collect:        :map,
    collect!:       :map!,
    detect:         :find,
    find_all:       :select,
    collect_concat: :flat_map,
    each_pair:      :each,
    has_key?:       :key?,
    has_value?:     :value?,
    find_index:     :index,
    magnitude:      :abs,
    id2name:        :to_s,
    length:         :size,
    entries:        :to_a,
    append:         :push,
    include?:       :key?,
    member?:        :key?,
  }.freeze

  METHOD_ALIASES = KERNEL_ALIASES.merge(RECEIVER_ALIASES).freeze

  # The literal an emptiness rewrite compares against, per receiver type —
  # the single fact both transform tables below build on.
  EMPTY_LITERALS = { Array: '[]', String: '""', Hash: '{}' }.freeze

  # Structural method transforms: method call → different syntax
  # Applied only when TypeProf verifies receiver type compatibility.
  # Key: [method_name, :ClassName], Value: replacement string
  METHOD_TRANSFORMS = {
    [:first, :Array] => '[0]',
    [:zero?, :Numeric] => '==0',
    **EMPTY_LITERALS.to_h { |type, lit| [[:empty?, type], "==#{lit}"] },
  }.freeze

  # The comparison operators the size-comparison transforms recognize, and
  # the spelling each takes in the rewrite: `> 0` means non-empty for a
  # size, so it shares the != spelling.
  SIZE_COMPARISON_OPS = { :== => '==', :!= => '!=', :> => '!=' }.freeze

  # Whole-comparison transforms: `.size==0` and friends collapse to a
  # literal comparison under the same receiver-type gate as the empty?
  # rows, one call deeper. Key: [comparison_op, :ClassName], value: the
  # replacement for `.mid op 0`.
  SIZE_COMPARISON_TRANSFORMS = SIZE_COMPARISON_OPS.each_with_object(
    {} #: Hash[[Symbol, Symbol], String]
  ) { |(op, spelled), table|
    EMPTY_LITERALS.each { |type, lit| table[[op, type]] = "#{spelled}#{lit}" }
  }.freeze

  # The inner calls those comparisons recognize, with the types where the
  # no-argument form means size. String#count requires an argument, so a
  # bare .count is never a String size query.
  SIZE_QUERY_MIDS = {
    size: %i[Array String Hash],
    length: %i[Array String Hash],
    count: %i[Array Hash],
  }.freeze
end
