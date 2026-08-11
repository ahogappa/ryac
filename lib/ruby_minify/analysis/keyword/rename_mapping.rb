# frozen_string_literal: true

module RubyMinify
  class KeywordRenameMapping
    include UnionFind

    def initialize
      uf_init
      @methods = {}
      @node_short_names = {}
      @keyword_maps = {}
      @frozen = false
    end

    def add_keyword_def(method_key, keyword_sym)
      init_method(method_key)
      @methods[method_key][:keywords] << keyword_sym
    end

    def add_keyword_call(method_key, keyword_sym, symbol_node, val_node)
      init_method(method_key)
      @methods[method_key][:call_entries][keyword_sym] ||= []
      @methods[method_key][:call_entries][keyword_sym] << { symbol_node: symbol_node, val_node: val_node }
    end

    def exclude_method(method_key)
      init_method(method_key)
      root = uf_root(method_key)
      @methods.each_key do |k|
        @methods[k][:excluded] = true if uf_root(k) == root
      end
    end

    def exclude_methods_by_mid(mids)
      @methods.keys.each do |key|
        exclude_method(key) if mids.include?(key[2])
      end
    end

    def merge_groups(key1, key2)
      init_method(key1)
      init_method(key2)
      super
    end

    def each_method_key(&block)
      @methods.each_key(&block)
    end

    def assign_short_names
      groups = Hash.new { |h, k| h[k] = [] }
      @methods.each_key { |key| groups[uf_root(key)] << key }

      groups.each do |_root, keys|
        next if keys.any? { |k| @methods[k][:excluded] }

        all_keywords = keys.flat_map { |k| @methods[k][:keywords].to_a }.uniq
        total_call_entries = keys.sum { |k| @methods[k][:call_entries].values.sum(&:size) }
        next if total_call_entries == 0

        generator = NameGenerator.new
        keyword_map = {}
        all_keywords.sort_by { |sym| -sym.to_s.size }.each do |sym|
          next if sym.to_s.size <= 2

          short = generator.next_name
          occurrences = count_occurrences(keys, sym)
          savings = (sym.to_s.size - short.size) * occurrences
          next unless savings > 2

          keyword_map[sym] = short
        end

        next if keyword_map.empty?

        @keyword_maps[_root] = keyword_map

        keys.each do |key|
          @methods[key][:call_entries].each do |sym, entries|
            short = keyword_map[sym]
            next unless short
            entries.each { |e| @node_short_names[AstUtils.location_key(e[:symbol_node])] = short }
          end
        end
      end

      @frozen = true
    end

    def node_mapping
      @node_short_names.dup
    end

    # Keyed by the def's location, the coordinate the scope analysis works in.
    def def_node_mapping(def_node_registry)
      result = {}
      def_node_registry.each do |method_key, def_nodes|
        root = uf_root(method_key)
        keyword_map = @keyword_maps[root]
        next unless keyword_map

        next if @methods[method_key]&.[](:excluded)

        def_nodes.each do |def_node|
          mapping = {}
          keyword_map.each do |sym, short|
            mapping[sym] = short
          end
          result[AstUtils.location_key(def_node)] = mapping unless mapping.empty?
        end
      end
      result
    end

    # A call passing a local as a keyword value — `f(code: c)` — pays nothing
    # when the local is named like the keyword, because the shorthand form
    # `f(code:)` applies. These hints suggest that name to the local's scope.
    #
    # The scope containing the call site is the caller's concern: pass a block
    # mapping a call-argument node to its scope id.
    def build_variable_hints
      hints = {}

      @methods.each do |method_key, info|
        next if info[:excluded]
        root = uf_root(method_key)
        keyword_map = @keyword_maps[root] || {}

        info[:call_entries].each do |keyword_sym, entries|
          # Use renamed name if available; for already-short keywords (≤2 chars),
          # use original name to preserve idempotency across re-minification passes
          final_name = keyword_map[keyword_sym]
          final_name ||= keyword_sym.to_s if keyword_sym.to_s.size <= 2
          next unless final_name

          entries.each do |entry|
            val_node = entry[:val_node]
            next unless val_node.is_a?(Prism::LocalVariableReadNode)

            scope_id = yield(val_node)
            next unless scope_id

            hints[scope_id] ||= {}
            hints[scope_id][val_node.name] ||= final_name
          end
        end
      end

      hints
    end

    private

    def init_method(method_key)
      return if @methods.key?(method_key)
      @methods[method_key] = { keywords: Set.new, call_entries: {}, excluded: false }
      uf_add(method_key)
    end

    def count_occurrences(keys, sym)
      count = 0
      keys.each do |key|
        info = @methods[key]
        count += 1 if info[:keywords].include?(sym)
        count += (info[:call_entries][sym]&.size || 0)
      end
      count
    end
  end
end
