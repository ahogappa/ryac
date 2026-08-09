# frozen_string_literal: true

module RubyMinify
  class IvarRenameMapping
    def initialize
      @class_ivars = {}
      @cpath_to_canonical = {}
      @excluded_cpaths = Set.new
      @node_short_names = {}
      @reserved_names = {}
    end

    def add_read_site(cpath, ivar_name, node)
      canonical = resolve_canonical(cpath)
      entry = ivar_entry(canonical, ivar_name)
      entry[:read_nodes] << node
    end

    def add_write_site(cpath, ivar_name, node)
      canonical = resolve_canonical(cpath)
      entry = ivar_entry(canonical, ivar_name)
      entry[:write_nodes] << node
    end

    def exclude_cpath(cpath)
      @excluded_cpaths << resolve_canonical(cpath)
    end

    def reserve_name(cpath, short_name)
      canonical = resolve_canonical(cpath)
      @reserved_names[canonical] ||= Set.new
      @reserved_names[canonical] << short_name
    end

    def each_canonical_cpath(&block)
      @class_ivars.each_key(&block)
    end


    def merge_with_ancestor(child_cpath, ancestor_cpath)
      child_canonical = resolve_canonical(child_cpath)
      ancestor_canonical = resolve_canonical(ancestor_cpath)
      return if child_canonical == ancestor_canonical
      return unless @class_ivars.key?(ancestor_canonical)

      child_entry = @class_ivars[child_canonical]
      return unless child_entry

      ancestor_entry = @class_ivars[ancestor_canonical]

      child_entry.keys.each do |ivar_name|
        child_data = child_entry.delete(ivar_name)
        next unless child_data
        if ancestor_entry.key?(ivar_name)
          anc_data = ancestor_entry[ivar_name]
          anc_data[:read_nodes].concat(child_data[:read_nodes])
          anc_data[:write_nodes].concat(child_data[:write_nodes])
        else
          ancestor_entry[ivar_name] = child_data
        end
      end

      @class_ivars.delete(child_canonical) if child_entry.empty?
    end

    def assign_short_names
      @class_ivars.each do |cpath, ivars|
        next if @excluded_cpaths.include?(cpath)

        existing_names = Set.new
        ivars.each_key do |name|
          existing_names << name.to_s if name.to_s.size <= 2
        end
        reserved = @reserved_names[cpath]
        existing_names.merge(reserved) if reserved

        generator = NameGenerator.new([], prefix: "@")
        sorted_ivars = ivars.sort_by do |name, data|
          total = data[:read_nodes].size + data[:write_nodes].size
          -(name.to_s.size * total)
        end

        sorted_ivars.each do |name, data|
          next if name.to_s.size <= 2

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

    def ivar_entry(cpath, ivar_name)
      @class_ivars[cpath] ||= {}
      @class_ivars[cpath][ivar_name] ||= { read_nodes: [], write_nodes: [] }
    end
  end
end
