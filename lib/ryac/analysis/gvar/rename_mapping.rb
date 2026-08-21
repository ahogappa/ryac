# frozen_string_literal: true

module Ryac
  class GvarRenameMapping
    # One pairing of English name to punctuation spelling. SpellingShorten
    # rewrites reads and plain writes to the short form; both spellings also
    # join BUILT_IN_GLOBALS below, so the node kinds it does not rewrite
    # (targets, operator/or/and writes) can never be renamed either.
    PERL_SPELLINGS = {
      '$PROGRAM_NAME': '$0',
      '$LOAD_PATH': '$:',
      '$LOADED_FEATURES': '$"',
    }.freeze

    # Built-in globals that must never be renamed: Ruby defines their
    # storage, so a renamed spelling reads nil and writes into a dead cell.
    BUILT_IN_GLOBALS = (Set.new(%i[
      $stdout $stderr $stdin $DEBUG $VERBOSE $FILENAME
      $ERROR_INFO $ERROR_POSITION $FIELD_SEPARATOR $OFS $OUTPUT_FIELD_SEPARATOR
      $RS $INPUT_RECORD_SEPARATOR $ORS $OUTPUT_RECORD_SEPARATOR
      $INPUT_LINE_NUMBER $NR $LAST_READ_LINE $DEFAULT_OUTPUT $DEFAULT_INPUT
      $PID $PROCESS_ID $CHILD_STATUS $LAST_MATCH_INFO $IGNORECASE
      $ARGV $MATCH $PREMATCH $POSTMATCH $LAST_PAREN_MATCH $FS
      $0 $: $; $, $. $/ $\\ $_ $< $> $! $@ $~ $& $` $' $+ $*
      $" $? $$ $-0 $-F $-I $-K $-W $-a $-d $-i $-l $-p $-v $-w
      $1 $2 $3 $4 $5 $6 $7 $8 $9
    ]) + PERL_SPELLINGS.keys + PERL_SPELLINGS.values.map(&:to_sym)).freeze

    def initialize
      @gvars = {}
      @excluded_names = Set.new
      @written_names = Set.new
      @node_short_names = {}
    end

    def add_site(name, node, write: false)
      return if BUILT_IN_GLOBALS.include?(name)
      @written_names << name if write
      @gvars[name] ||= []
      @gvars[name] << node
    end

    def exclude_name(name)
      @excluded_names << name
    end

    PREFIX = '$'
    # Sigil + one character is already minimal — the same rule the
    # SiteBucketMapping families derive from their prefix.
    KEPT_NAME_MAX = PREFIX.size + 1

    def assign_short_names
      existing_names = Set.new
      @gvars.each_key do |name|
        existing_names << name.to_s if name.to_s.size <= KEPT_NAME_MAX
      end

      generator = NameGenerator.new(existing_names, prefix: PREFIX)
      sorted_gvars = @gvars.sort_by do |name, nodes|
        -(name.to_s.size * nodes.size)
      end

      sorted_gvars.each do |name, nodes|
        next if @excluded_names.include?(name)
        next if name.to_s.size <= KEPT_NAME_MAX
        # A global the program only reads is either a built-in this list
        # does not know or nil everywhere — renaming it can only break.
        next unless @written_names.include?(name)

        short_name = generator.next_name
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
