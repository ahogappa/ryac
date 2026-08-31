# frozen_string_literal: true

require 'tsort'

module Ryac
  module Pipeline
    # Stage 2: File Concatenation
    # Performs topological sort and concatenates files in dependency order
    class Concatenator
      # @param graph [DependencyGraph] From Stage 1
      # @return [ConcatenatedSource] Ordered, concatenated source
      # @raise [CircularDependencyError] If cycle detected in graph
      def call(graph)
        sorted_paths = topological_sort(graph)
        concatenate_files(graph, sorted_paths)
      end

      private

      # Perform topological sort using Ruby's TSort library
      # @return [Array<String>] Paths in dependency order (dependencies first)
      def topological_sort(graph)
        sorter = GraphSorter.new(graph)
        begin
          sorter.tsort
        rescue TSort::Cyclic
          # Extract cycle from error message
          cycle = extract_cycle_from_graph(graph)
          raise CircularDependencyError.new(cycle)
        end
      end

      # Extract cycle path from graph for error reporting
      def extract_cycle_from_graph(graph)
        visited = Set.new
        rec_stack = Set.new
        path = [] #: Array[String]

        graph.paths.each do |start|
          if find_cycle_dfs(graph, start, visited, rec_stack, path)
            return path
          end
        end

        # Fallback: return all paths
        graph.paths
      end

      def find_cycle_dfs(graph, node, visited, rec_stack, path)
        return false if visited.include?(node)

        visited.add(node)
        rec_stack.add(node)
        path << node

        entry = graph[node]
        deps = entry&.dependencies
        if deps
          deps.each do |dep|
            if rec_stack.include?(dep)
              path << dep
              return true
            end

            if find_cycle_dfs(graph, dep, visited, rec_stack, path)
              return true
            end
          end
        end

        rec_stack.delete(node)
        path.pop
        false
      end

      # Helper class for TSort
      class GraphSorter
        include TSort

        def initialize(graph)
          @graph = graph
        end

        def tsort_each_node(&block)
          @graph.paths.each(&block)
        end

        def tsort_each_child(node, &block)
          entry = @graph[node]
          return unless entry

          entry.dependencies.each(&block)
          entry.in_class_dependencies.each(&block)
        end
      end

      # Concatenate files in sorted order
      def concatenate_files(graph, sorted_paths)
        content_parts = [] #: Array[String]
        file_boundaries = [] #: Array[FileBoundary]
        stdlib_requires = [] #: Array[String]
        inlined = Set.new
        current_line = 1

        # Pre-clean all files: resolve in-class requires by inlining
        cleaned_cache = {} #: Hash[String, String]
        sorted_paths.each do |path|
          entry = graph[path]
          next unless entry
          collect_stdlib_requires(entry, stdlib_requires)
          cleaned_cache[path] = process_require_statements(entry, graph, inlined, cleaned_cache)
        end

        sorted_paths.each do |path|
          next if inlined.include?(path)
          entry = graph[path]
          next unless entry

          cleaned_content = cleaned_cache[path]
          lines = cleaned_content.count("\n") + 1

          file_boundaries << FileBoundary.new(
            path: path,
            start_line: current_line,
            end_line: current_line + lines - 1
          )

          content_parts << cleaned_content
          current_line += lines
        end

        original_size = graph.files.values.sum { |f| f.content.bytesize }

        ConcatenatedSource.new(
          content: content_parts.join("\n"),
          file_boundaries: file_boundaries,
          original_size: original_size,
          stdlib_requires: stdlib_requires.uniq,
          rbs_files: graph.rbs_files,
          lazy_sources: graph.lazy_files.values
        )
      end

      # Hoisting a require to the top of the output makes it run at load time.
      # That is fine for one the file already ran at load time, but a require
      # inside a method body runs only when the method is called and is often
      # guarded — optcarrot loads stackprof only under --stackprof-mode, so
      # hoisting it turns an optional dependency into a mandatory one.
      def collect_stdlib_requires(entry, stdlib_requires)
        entry.require_nodes.each do |node|
          next unless node[:type] == :require_stdlib
          next if node[:in_method]
          stdlib_requires << node[:path]
        end
      end

      # Process require statements: remove top-level requires, inline in-class requires
      def process_require_statements(entry, graph, inlined, cleaned_cache)
        content = entry.content
        require_nodes = entry.require_nodes
        return content if require_nodes.empty?

        in_class_deps = entry.in_class_dependencies.to_set
        nodes_with_offsets = require_nodes.select { |n| n[:start_offset] }

        if nodes_with_offsets.size == require_nodes.size
          offset_based_processing(content, nodes_with_offsets, graph, in_class_deps, inlined, cleaned_cache)
        else
          line_based_processing(content, require_nodes)
        end
      end

      def offset_based_processing(content, nodes, graph, in_class_deps, inlined, cleaned_cache)
        sorted_nodes = nodes.sort_by { |n| n[:start_offset] }.reverse
        # Prism offsets are byte offsets: splice on bytes, or any multibyte
        # character before a require shifts every slice after it.
        result = content.b
        sorted_nodes.each do |node|
          start_pos = node[:start_offset]
          end_pos = start_pos + node[:length]

          if node[:in_class] && !node[:in_method] && node[:type] != :require_stdlib
            dep_path = resolve_node_path(node, graph)
            if dep_path && graph[dep_path]
              # the `graph[dep_path]` check above guarantees the entry exists
              dep_content = cleaned_cache[dep_path] || graph[dep_path].content # steep:ignore NoMethod
              stripped = strip_outer_nesting(dep_content)
              # Only consume trailing semicolons (not newlines) for inline
              while end_pos < result.size && result[end_pos] == ';'
                end_pos += 1
              end
              result[start_pos...end_pos] = stripped.b
              inlined.add(dep_path)
              next
            end
          end

          # An in-method stdlib require is not hoisted, so it has to stay where
          # it is — deleting it here would drop the require altogether.
          next if node[:type] == :require_stdlib && node[:in_method]

          # For removal: consume trailing semicolons and newlines
          while end_pos < result.size && (result[end_pos] == ';' || result[end_pos] == "\n")
            end_pos += 1
          end
          result[start_pos...end_pos] = ''
        end
        result.force_encoding(content.encoding)
      end

      def line_based_processing(content, require_nodes)
        lines = content.lines
        lines_to_remove = Set.new
        require_nodes.each { |node| lines_to_remove.add(node[:line] - 1) }
        lines.each_with_index.map do |line, idx|
          lines_to_remove.include?(idx) ? '' : line.chomp
        end.join("\n")
      end

      def resolve_node_path(node, graph)
        resolved = node[:resolved_path]
        return nil unless resolved
        graph.files.key?(resolved) ? resolved : nil
      end

      # Strip outer module/class nesting from a file so it can be inlined
      # inside the parent's class body. Peels single-child module/class layers
      # until reaching the innermost new scope definition.
      def strip_outer_nesting(content)
        ast = Prism.parse(content).value
        node = ast.statements
        while node.is_a?(Prism::StatementsNode) && node.body.size == 1
          child = node.body.first
          break unless child.is_a?(Prism::ModuleNode) || child.is_a?(Prism::ClassNode)
          inner_body = child.body
          if inner_body.is_a?(Prism::StatementsNode) && inner_body.body.size == 1
            inner_child = inner_body.body.first
            if inner_child.is_a?(Prism::ModuleNode) || inner_child.is_a?(Prism::ClassNode)
              node = inner_body
              next
            end
          end
          break
        end
        node.slice
      end
    end
  end
end
