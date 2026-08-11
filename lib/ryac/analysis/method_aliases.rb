# frozen_string_literal: true

module Ryac
  # Method alias mappings: longer method name => shorter equivalent
  # TypeProf verifies at analysis time that the shorter method
  # is available on the receiver type via inheritance chain.
  #
  # SELF-HOSTING RULE: because these tables rewrite calls whenever the
  # receiver type can be proven, and inference over lib/'s own source can
  # prove a receiver on one self-hosting pass but not the other, code in
  # lib/ must not use the long side of any entry here where a short synonym
  # exists — write `size` (never `length`), `any?` (never `empty?`), `[0]`
  # (never `first`) on our own collections. Otherwise minify(minify(lib))
  # stops being a fixed point: the transform fires on one pass only.
  METHOD_ALIASES = {
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
    kind_of?:       :is_a?,
    yield_self:     :then,
    id2name:        :to_s,
    length:         :size,
    entries:        :to_a,
    append:         :push,
    include?:       :key?,
    member?:        :key?,
    object_id:      :__id__,
    raise:          :fail,
  }.freeze

  # Structural method transforms: method call → different syntax
  # Applied only when TypeProf verifies receiver type compatibility.
  # Key: [method_name, :ClassName], Value: replacement string
  METHOD_TRANSFORMS = {
    [:first, :Array] => '[0]',
    [:zero?, :Numeric] => '==0',
    [:empty?, :Array] => '==[]',
    [:empty?, :String] => '==""',
    [:empty?, :Hash] => '=={}',
  }.freeze
end
