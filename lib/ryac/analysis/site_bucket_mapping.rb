# frozen_string_literal: true

module Ryac
  # One (cpath, name) → sites table for the sigil families: instance and
  # class variables differ only in their sigil, and a name of sigil + one
  # character is already minimal.
  #
  # Buckets merge along inheritance, and the merge records an alias so a
  # site added afterwards lands in the merged bucket instead of silently
  # resurrecting the child's. After assign_short_names the table is sealed:
  # anything arriving later would miss renaming, so the phase that got its
  # order wrong fails loudly instead.
  class SiteBucketMapping
    def initialize(prefix:)
      @prefix = prefix
      @kept_name_max = prefix.size + 1
      @buckets = {}
      @cpath_to_canonical = {}
      @excluded_cpaths = Set.new
      @reserved_names = {}
      @node_short_names = {}
      @frozen = false
    end

    def add_site(cpath, name, node)
      check_open!('site added')
      canonical = resolve_canonical(cpath)
      @buckets[canonical] ||= {}
      (@buckets[canonical][name] ||= []) << node
    end

    def exclude_cpath(cpath)
      check_open!('cpath excluded')
      @excluded_cpaths << resolve_canonical(cpath)
    end

    def reserve_name(cpath, short_name)
      check_open!('name reserved')
      canonical = resolve_canonical(cpath)
      @reserved_names[canonical] ||= Set.new
      @reserved_names[canonical] << short_name
    end

    def each_canonical_cpath(&block)
      @buckets.each_key(&block)
    end

    def merge_with_ancestor(child_cpath, ancestor_cpath)
      check_open!('merge')
      child_canonical = resolve_canonical(child_cpath)
      ancestor_canonical = resolve_canonical(ancestor_cpath)
      return if child_canonical == ancestor_canonical
      return unless @buckets.key?(ancestor_canonical)

      child_entry = @buckets[child_canonical]
      return unless child_entry

      # Recorded before the sites move: from here on, a site added for the
      # child cpath belongs to the merged bucket.
      @cpath_to_canonical[child_canonical] = ancestor_canonical

      ancestor_entry = @buckets[ancestor_canonical]
      child_entry.keys.each do |name|
        child_nodes = child_entry.delete(name)
        next unless child_nodes
        if ancestor_entry.key?(name)
          ancestor_entry[name].concat(child_nodes)
        else
          ancestor_entry[name] = child_nodes
        end
      end

      @buckets.delete(child_canonical) if child_entry.none?
    end

    def assign_short_names
      @buckets.each do |cpath, names|
        next if @excluded_cpaths.include?(cpath)

        existing_names = Set.new
        names.each_key do |name|
          existing_names << name.to_s if name.to_s.size <= @kept_name_max
        end
        reserved = @reserved_names[cpath]
        existing_names.merge(reserved) if reserved

        generator = NameGenerator.new(existing_names, prefix: @prefix)
        sorted = names.sort_by do |name, nodes|
          -(name.to_s.size * nodes.size)
        end

        sorted.each do |name, nodes|
          next if name.to_s.size <= @kept_name_max

          short_name = generator.next_name
          savings = (name.to_s.size - short_name.size) * nodes.size
          next unless savings > 0

          nodes.each { |n| @node_short_names[AstUtils.location_key(n)] = short_name }
        end
      end
      @frozen = true
    end

    def node_mapping
      @node_short_names.dup
    end

    private

    def check_open!(action)
      raise InternalError, "#{@prefix}-mapping: #{action} after assign_short_names" if @frozen
    end

    def resolve_canonical(cpath)
      return cpath unless @cpath_to_canonical.key?(cpath)

      current = cpath
      seen = Set.new
      while @cpath_to_canonical.key?(current) && !seen.include?(current)
        seen << current
        current = @cpath_to_canonical[current]
      end
      current
    end
  end
end
