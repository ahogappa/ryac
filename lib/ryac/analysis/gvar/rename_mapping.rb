# frozen_string_literal: true

module Ryac
  class GvarRenameMapping
    # Built-in globals that must never be renamed.
    # After preprocessor (Style/SpecialGlobalVars with use_perl_names),
    # long forms like $LOAD_PATH are already converted to $: etc.
    BUILT_IN_GLOBALS = Set.new(%i[
      $stdout $stderr $stdin $DEBUG $VERBOSE $FILENAME
      $0 $: $; $, $. $/ $\\ $_ $< $> $! $@ $~ $& $` $' $+ $*
      $" $? $$ $-0 $-F $-I $-K $-W $-a $-d $-i $-l $-p $-v $-w
      $1 $2 $3 $4 $5 $6 $7 $8 $9
    ]).freeze

    def initialize
      @gvars = {}
      @excluded_names = Set.new
      @node_short_names = {}
    end

    def add_site(name, node)
      return if BUILT_IN_GLOBALS.include?(name)
      @gvars[name] ||= []
      @gvars[name] << node
    end

    def exclude_name(name)
      @excluded_names << name
    end

    def assign_short_names
      existing_names = Set.new
      @gvars.each_key do |name|
        existing_names << name.to_s if name.to_s.size <= 2
      end

      generator = NameGenerator.new([], prefix: "$")
      sorted_gvars = @gvars.sort_by do |name, nodes|
        -(name.to_s.size * nodes.size)
      end

      sorted_gvars.each do |name, nodes|
        next if @excluded_names.include?(name)
        next if name.to_s.size <= 2

        short_name = generator.next_name
        short_name = generator.next_name while existing_names.include?(short_name)
        savings = (name.to_s.size - short_name.size) * nodes.size
        next unless savings > 0

        nodes.each { |n| @node_short_names[AstUtils.location_key(n)] = short_name }
      end
    end

    def node_mapping
      @node_short_names.dup
    end
  end
end
