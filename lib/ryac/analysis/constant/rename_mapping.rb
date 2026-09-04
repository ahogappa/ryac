# frozen_string_literal: true

require 'set'

module Ryac
  # Represents an external library constant prefix that can be aliased
  ExternalPrefixInfo = Struct.new(
    :prefix_path,    # Array<Symbol> - Prefix path (e.g., [:TypeProf, :Core, :AST])
    :prefix_string,  # String - Full prefix string (e.g., "TypeProf::Core::AST")
    :short_name,     # String - Assigned short name (e.g., "Z")
    :usage_count,    # Integer - Number of references using this prefix
    :char_savings,   # Integer - Net character savings from aliasing
    keyword_init: true
  ) do
    def initialize(prefix_path: nil, prefix_string: nil, short_name: nil, # steep:ignore UndeclaredMethodDefinition
                   usage_count: nil, char_savings: nil)
      # @type self: ExternalPrefixInfo
      self.prefix_path = prefix_path || []
      self.prefix_string = prefix_string
      self.short_name = short_name
      self.usage_count = usage_count || 0
      self.char_savings = char_savings || 0
    end
  end

  # Represents a user-defined constant found in the source file
  ConstantInfo = Struct.new(
    :original_name,   # Symbol - Original constant name (e.g., :MyClass)
    :full_path,       # Array<Symbol> - Full namespace path (e.g., [:Foo, :Bar, :MyClass])
    :short_name,      # String - Assigned short name (e.g., "A")
    :usage_count,     # Integer - Number of references in the file
    :definition_type, # Symbol - :class, :module, or :value
    :scope_path,      # Array<Symbol> - Module/class scope where defined
    keyword_init: true
  ) do
    def initialize(original_name: nil, full_path: nil, short_name: nil, # steep:ignore UndeclaredMethodDefinition
                   usage_count: nil, definition_type: nil, scope_path: nil)
      # @type self: ConstantInfo
      self.original_name = original_name
      self.full_path = full_path || []
      self.short_name = short_name
      self.usage_count = usage_count || 0
      self.definition_type = definition_type
      self.scope_path = scope_path || []
    end
  end

  # Tracks the mapping between original and short constant names
  # Uses static_cpath (full qualified path) as key to distinguish
  # constants with same name in different modules.
  # Also tracks external prefix aliases (absorbed from ExternalPrefixAliaser).
  class ConstantRenameMapping
    attr_reader :mappings, :used_short_names

    # boot_roots: the top-level constants that exist when the minified
    # program boots (core + its own requires), used to spot reopenings of
    # classes the program didn't create. nil falls back to probing the
    # minifier's own process, which over-approximates: everything the
    # minifier has loaded — including, under self-hosting, the analyzed
    # program itself — then looks like a reopening.
    #
    # alias_surface: which renames the alias block restores — :full, every
    # one, or :skeleton, classes and modules only. See
    # generate_alias_declarations.
    def initialize(boot_roots: nil, alias_surface: :full)
      @boot_roots = boot_roots
      @alias_surface = alias_surface
      @mappings = {}           # Hash<Array<Symbol>, ConstantInfo> - key is static_cpath
      # keyed by the last path segment
      @by_name = {}
      @used_short_names = Set.new
      @external_prefixes = {}
      @prefix_counts = Hash.new(0) # Hash<Array<Symbol>, Integer> - raw prefix reference counts
      @state = :empty
    end

    def empty?
      @state == :empty
    end

    def finalized?
      @state == :frozen
    end

    # Add a constant definition using TypeProf's static_cpath
    def add_definition_with_path(static_cpath, definition_type:)
      raise "Cannot add definitions when finalized" if finalized?
      @state = :collecting if empty?

      return if @mappings.key?(static_cpath)

      name = static_cpath.last
      scope_path = static_cpath[0...-1]

      info = ConstantInfo.new(
        original_name: name,
        full_path: static_cpath,
        definition_type: definition_type,
        scope_path: scope_path
      )
      @mappings[static_cpath] = info

      # Also index by simple name for backward compatibility
      (@by_name[name] ||= []) << info
    end

    # Increment usage count for a constant by static_cpath
    def increment_usage_by_path(static_cpath)
      raise "Cannot increment usage when finalized" if finalized?
      return unless @mappings.key?(static_cpath)

      info = @mappings[static_cpath]
      info.usage_count += 1
    end

    # Increment usage count by simple name (finds first match)
    def increment_usage(name)
      raise "Cannot increment usage when finalized" if finalized?
      return unless @by_name.key?(name)

      # Increment all constants with this name
      @by_name[name].each do |info|
        info.usage_count += 1
      end
    end

    def exclude_path(static_cpath)
      raise "Cannot exclude when finalized" if finalized?
      info = @mappings.delete(static_cpath)
      return unless info
      name = static_cpath.last
      @by_name[name]&.reject! { |i| i.full_path == static_cpath }
    end

    # Freeze the mapping and assign short names.
    # Unified allocation: internal constants and external prefixes are merged
    # into a single sorted list and allocated from the same NameGenerator.
    # This follows the src.dest two-phase model: propagation (this method)
    # determines ALL short names before any application.
    def assign_short_names(name_generator, skip_class_modules: false)
      raise "Already finalized" if finalized?

      @state = :frozen
      prefix_counts = @prefix_counts
      @prefix_counts = nil

      existing_names = @mappings.each_value.with_object(Set.new) { |info, s| s << info.original_name.to_s }

      # Augment prefix counts with preamble-induced parent refs:
      # each prefix's declaration (e.g., C5=RuboCop::Cop) references its parent.
      # Adding unconditionally avoids the chicken-and-egg problem of needing to
      # know which children are aliased before counting parent refs.
      prefix_counts.keys.each do |prefix|
        next if prefix.size < 2
        prefix_counts[prefix[0...-1]] += 1
      end

      # Build unified allocation list: [gross_savings_estimate, :internal/:external, object]
      entries = [] #: Array[[Integer, Symbol, untyped]]

      @mappings.each_value do |info|
        next if skip_class_modules && info.definition_type != :value
        next if info.definition_type != :value && external_class_root?(info.full_path)
        entries << [info.original_name.to_s.size * (info.usage_count + 1), :internal, info]
      end

      prefix_counts.each do |prefix, count|
        prefix_string = prefix.map(&:to_s).join('::')
        info = ExternalPrefixInfo.new(prefix_path: prefix, prefix_string: prefix_string, usage_count: count)
        entries << [prefix_string.size * count, :external, info]
      end

      entries.sort_by! { |e| -e[0] }

      # candidate is assigned on the first iteration and only replaced after
      candidate = nil #: String?
      entries.each do |_savings, kind, info|
        if candidate.nil?
          candidate = name_generator.next_name
          candidate = name_generator.next_name while existing_names.include?(candidate)
        end
        cand = candidate #: String

        case kind
        when :internal
          # Kept names make re-minification a fixed point: the names this
          # pass assigns are themselves KEPT_NAME_MAX or shorter, and a
          # second pass must not shuffle them again.
          next if info.original_name.to_s.size <= NameGenerator::KEPT_NAME_MAX
          next unless info.original_name.to_s.size - cand.size > 0
          info.short_name = cand
          @used_short_names << cand

        when :external
          saved_per_use = info.prefix_string.size - cand.size
          next unless saved_per_use > 0
          declaration_cost = cand.size + 1 + info.prefix_string.size + 1
          net_savings = (saved_per_use * info.usage_count) - declaration_cost
          next unless net_savings > 0
          info.short_name = cand
          info.char_savings = net_savings
          existing_names << cand
          @external_prefixes[info.prefix_path] = info
        end

        candidate = nil
      end
    end

    # Generate backward-compatible alias declarations for renamed constants.
    # Returns array of strings like "OriginalName=ShortName" or
    # "ShortParent::OriginalName=ShortParent::ShortName" for nested constants.
    #
    # With the :full surface every rename stays restorable: nothing says
    # which original names code outside the analyzed world spells. A program
    # that dynamically loads files at runtime had enumerated its external
    # readers, and bundling them as lazy regions brought every one inside;
    # what remains outside is a launcher, and a launcher spells the
    # class/module skeleton (`Optcarrot::NES.new.run`), never a value
    # constant. That is the :skeleton surface.
    def generate_alias_declarations
      renamed = @mappings.values.select(&:short_name).sort_by { |info| [info.full_path.size, info.full_path] }
      renamed.reject! { |info| info.definition_type == :value } if @alias_surface == :skeleton
      renamed.filter_map { |info| build_alias_declaration(info) }
    end

    # Get short name for a constant by static_cpath. The parameter is nilable
    # for the callers that pass sliced sub-paths; a nil key simply misses.
    def short_name_for_path(static_cpath)
      info = static_cpath ? @mappings[static_cpath] : nil
      info&.short_name
    end

    # Get short name for a constant by simple name (finds first match)
    # Used when static_cpath is not available
    def short_name_for(name)
      return nil unless @by_name.key?(name)
      infos = @by_name[name]
      return nil if infos.empty?
      # Return first match (for backward compatibility)
      infos.first&.short_name
    end

    # Check if a constant is user-defined by static_cpath
    def user_defined_path?(static_cpath)
      @mappings.key?(static_cpath)
    end

    # Get usage count for a constant by static_cpath
    def usage_count_for_path(static_cpath)
      info = @mappings[static_cpath]
      info ? info.usage_count : 0
    end

    # Set usage count for a constant by static_cpath
    def set_usage_count_by_path(static_cpath, count)
      raise "Cannot set usage when finalized" if finalized?
      info = @mappings[static_cpath]
      info.usage_count = count if info
    end

    # Iterate over user-defined constant paths
    def each_user_defined_path(&block)
      @mappings.each_key(&block)
    end

    # Check if a path is a class or module definition
    def class_or_module_path?(static_cpath)
      return false unless static_cpath
      info = @mappings[static_cpath]
      info && (info.definition_type == :class || info.definition_type == :module)
    end

    # Check if any sub-prefix of the path is user-defined
    def has_user_defined_prefix?(full_path)
      (1...full_path.size).any? { |i| user_defined_path?(full_path[0...i]) }
    end

    # Add an external prefix reference count (e.g., [:TypeProf, :Core, :AST] with count 20)
    def add_external_prefix(prefix_path, usage_count:)
      raise "Cannot add external prefix when finalized" if finalized?
      @state = :collecting if empty?
      @prefix_counts[prefix_path] += usage_count
    end

    # Get short name for the prefix of a full external path
    def short_name_for_prefix(full_path)
      return nil if full_path.nil? || full_path.size < 2
      prefix = full_path[0...-1] #: Array[Symbol]
      info = @external_prefixes[prefix]
      info&.short_name
    end

    # Generate prefix declaration statements (e.g., ["Z=TypeProf::Core::AST"])
    # Uses chained aliases when a sub-prefix is also aliased
    def generate_prefix_declarations
      sorted = @external_prefixes.values.sort_by { |info| [info.prefix_path.size, -info.char_savings] }

      alias_map = {} #: Hash[Array[Symbol], String?]
      sorted.map do |info|
        decl_rhs = info.prefix_string
        (info.prefix_path.size - 1).downto(2) do |len|
          sub = info.prefix_path[0...len] #: Array[Symbol]
          if alias_map.key?(sub)
            rest = info.prefix_path[len..] #: Array[Symbol]
            decl_rhs = "#{alias_map[sub]}::#{rest.map(&:to_s).join('::')}"
            break
          end
        end
        alias_map[info.prefix_path] = info.short_name
        "#{info.short_name}=#{decl_rhs}"
      end
    end

    private

    # A class/module definition whose root the program didn't create is a
    # reopening (e.g. `class Array`, or `module Prism` adding to the gem) and
    # must not be renamed. With boot_roots the judgement is exact for the
    # program's own runtime; without it, fall back to probing this process.
    def external_class_root?(cpath)
      return runtime_constant?(cpath) if @boot_roots.nil?

      @boot_roots.include?(cpath.first)
    end

    # Check if a constant path already exists in the Ruby runtime.
    # Used to detect class/module reopenings (e.g., `class Array` adding methods
    # to a built-in class) which must not be renamed.
    def runtime_constant?(cpath)
      cpath.reduce(Object) do |mod, name|
        return false unless mod.is_a?(Module) && mod.const_defined?(name, false)
        mod.const_get(name, false)
      end
      true
    rescue
      false
    end

    # Build backward alias declaration for renamed value constants.
    # Class/module constants are never renamed (no short_name assigned).
    def build_alias_declaration(info)
      path = info.full_path
      # LHS: short parent path + original leaf name
      lhs = path.each_index.map { |i|
        if i < path.size - 1
          short_name_for_path(path[0..i]) || path[i].to_s
        else
          path[i].to_s
        end
      }.join('::')
      # RHS: full short path
      rhs = path.each_index.map { |i|
        short_name_for_path(path[0..i]) || path[i].to_s
      }.join('::')
      lhs == rhs ? nil : "#{lhs}=#{rhs}"
    end
  end

end
