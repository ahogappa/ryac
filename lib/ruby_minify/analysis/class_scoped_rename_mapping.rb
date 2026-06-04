# frozen_string_literal: true

module RubyMinify
  # Base class for rename mappings of variables that are scoped to a class or
  # module path (instance variables and class variables).
  #
  # Both kinds collect read/write sites per canonical class path, then assign
  # short replacement names per class, skipping names that are already minimal.
  # The only differences between the concrete mappings are the sigil the short
  # names carry (+name_prefix+) and the length below which a name is already
  # considered minimal (+keep_threshold+); subclasses supply those.
  class ClassScopedRenameMapping
    def initialize
      @class_vars = {}
      @cpath_to_canonical = {}
      @excluded_cpaths = Set.new
      @node_short_names = {}
      @reserved_names = {}
    end

    def add_read_site(cpath, var_name, node)
      entry = var_entry(resolve_canonical(cpath), var_name)
      entry[:read_nodes] << node
    end

    def add_write_site(cpath, var_name, node)
      entry = var_entry(resolve_canonical(cpath), var_name)
      entry[:write_nodes] << node
    end

    def exclude_cpath(cpath)
      @excluded_cpaths << resolve_canonical(cpath)
    end

    def reserve_name(cpath, short_name)
      canonical = resolve_canonical(cpath)
      (@reserved_names[canonical] ||= Set.new) << short_name
    end

    def each_canonical_cpath(&block)
      @class_vars.each_key(&block)
    end

    def merge_with_ancestor(child_cpath, ancestor_cpath)
      child_canonical = resolve_canonical(child_cpath)
      ancestor_canonical = resolve_canonical(ancestor_cpath)
      return if child_canonical == ancestor_canonical
      return unless @class_vars.key?(ancestor_canonical)

      child_entry = @class_vars[child_canonical]
      return unless child_entry

      ancestor_entry = @class_vars[ancestor_canonical]

      child_entry.keys.each do |var_name|
        child_data = child_entry.delete(var_name)
        next unless child_data
        if ancestor_entry.key?(var_name)
          anc_data = ancestor_entry[var_name]
          anc_data[:read_nodes].concat(child_data[:read_nodes])
          anc_data[:write_nodes].concat(child_data[:write_nodes])
        else
          ancestor_entry[var_name] = child_data
        end
      end

      @class_vars.delete(child_canonical) if child_entry.empty?
    end

    def assign_short_names
      @class_vars.each do |cpath, vars|
        next if @excluded_cpaths.include?(cpath)

        existing_names = Set.new
        vars.each_key do |name|
          existing_names << name.to_s if name.to_s.length <= keep_threshold
        end
        reserved = @reserved_names[cpath]
        existing_names.merge(reserved) if reserved

        generator = NameGenerator.new([], prefix: name_prefix)
        sorted_vars = vars.sort_by do |name, data|
          total = data[:read_nodes].size + data[:write_nodes].size
          -(name.to_s.length * total)
        end

        sorted_vars.each do |name, data|
          next if name.to_s.length <= keep_threshold

          short_name = generator.next_name
          short_name = generator.next_name while existing_names.include?(short_name)
          total = data[:read_nodes].size + data[:write_nodes].size
          savings = (name.to_s.length - short_name.length) * total
          next unless savings > 0

          data[:read_nodes].each { |n| @node_short_names[AstUtils.location_key(n)] = short_name }
          data[:write_nodes].each { |n| @node_short_names[AstUtils.location_key(n)] = short_name }
        end
      end
    end

    def node_mapping
      @node_short_names.dup
    end

    private

    # Sigil that short replacement names are prefixed with, e.g. "@" or "@@".
    def name_prefix
      raise NotImplementedError, "#{self.class}#name_prefix must be implemented"
    end

    # Names this length or shorter are already minimal and are left untouched.
    def keep_threshold
      raise NotImplementedError, "#{self.class}#keep_threshold must be implemented"
    end

    def resolve_canonical(cpath)
      current = cpath
      seen = Set.new
      while @cpath_to_canonical.key?(current) && !seen.include?(current)
        seen << current
        current = @cpath_to_canonical[current]
      end
      current
    end

    def var_entry(cpath, var_name)
      @class_vars[cpath] ||= {}
      @class_vars[cpath][var_name] ||= { read_nodes: [], write_nodes: [] }
    end
  end
end
