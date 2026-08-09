# frozen_string_literal: true

module RubyMinify
  class CvarRenameMapping
    def initialize
      @class_cvars = {}
      @cpath_to_canonical = {}
      @excluded_cpaths = Set.new
      @node_short_names = {}
    end

    def add_read_site(cpath, cvar_name, node)
      canonical = resolve_canonical(cpath)
      entry = cvar_entry(canonical, cvar_name)
      entry[:read_nodes] << node
    end

    def add_write_site(cpath, cvar_name, node)
      canonical = resolve_canonical(cpath)
      entry = cvar_entry(canonical, cvar_name)
      entry[:write_nodes] << node
    end

    def exclude_cpath(cpath)
      @excluded_cpaths << resolve_canonical(cpath)
    end

    def each_canonical_cpath(&block)
      @class_cvars.each_key(&block)
    end

    def merge_with_ancestor(child_cpath, ancestor_cpath)
      child_canonical = resolve_canonical(child_cpath)
      ancestor_canonical = resolve_canonical(ancestor_cpath)
      return if child_canonical == ancestor_canonical
      return unless @class_cvars.key?(ancestor_canonical)

      child_entry = @class_cvars[child_canonical]
      return unless child_entry

      ancestor_entry = @class_cvars[ancestor_canonical]

      child_entry.keys.each do |cvar_name|
        child_data = child_entry.delete(cvar_name)
        next unless child_data
        if ancestor_entry.key?(cvar_name)
          anc_data = ancestor_entry[cvar_name]
          anc_data[:read_nodes].concat(child_data[:read_nodes])
          anc_data[:write_nodes].concat(child_data[:write_nodes])
        else
          ancestor_entry[cvar_name] = child_data
        end
      end

      @class_cvars.delete(child_canonical) if child_entry.empty?
    end

    def assign_short_names
      @class_cvars.each do |cpath, cvars|
        next if @excluded_cpaths.include?(cpath)

        existing_names = Set.new
        cvars.each_key do |name|
          existing_names << name.to_s if name.to_s.size <= 3
        end

        generator = NameGenerator.new([], prefix: "@@")
        sorted_cvars = cvars.sort_by do |name, data|
          total = data[:read_nodes].size + data[:write_nodes].size
          -(name.to_s.size * total)
        end

        sorted_cvars.each do |name, data|
          next if name.to_s.size <= 3

          short_name = generator.next_name
          short_name = generator.next_name while existing_names.include?(short_name)
          total = data[:read_nodes].size + data[:write_nodes].size
          savings = (name.to_s.size - short_name.size) * total
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

    def resolve_canonical(cpath)
      current = cpath
      seen = Set.new
      while @cpath_to_canonical.key?(current) && !seen.include?(current)
        seen << current
        current = @cpath_to_canonical[current]
      end
      current
    end

    def cvar_entry(cpath, cvar_name)
      @class_cvars[cpath] ||= {}
      @class_cvars[cpath][cvar_name] ||= { read_nodes: [], write_nodes: [] }
    end
  end
end
