# frozen_string_literal: true

require 'tsort'

module Ryac
  module Pipeline
    # Stage 2: File Concatenation
    # Performs topological sort and concatenates files in dependency order
    class Concatenator
      # The registry lazy regions register into and the loader that runs
      # them: ordinary source, minified with everything else (both get short
      # names), spelled so as not to collide with the program's own names.
      # In the driver layout (DriverFile) the loader is the driver's own and
      # the registry is read by name from outside, so both names are fixed.
      REGISTRY_NAME = 'RYAC_LAZY'
      LOADER_NAME = 'ryac_require'

      # @param graph [DependencyGraph] From Stage 1
      # @param driver [Boolean] The driver layout: the registry alone, its
      #   loader left to the driver file (DriverFile)
      # @param split [Boolean] The split layout: every file as written, opened
      #   by a marker (FileMarks), its requires left to run as requires
      # @return [ConcatenatedSource] Ordered, concatenated source
      # @raise [CircularDependencyError] If cycle detected in graph
      # @raise [MinifyError] If the driver layout is asked of a program it
      #   cannot take: one with no lazy regions, or one spelling a fixed name
      def call(graph, driver: false, split: false)
        raise ArgumentError, 'the driver and split layouts exclude each other' if driver && split

        sorted_paths = topological_sort(graph)
        concatenate_files(graph, sorted_paths, driver, split)
      end

      # The directory every bundled file sits under. Region keys, the
      # respelled prefix of a dynamic require site and the split layout's
      # output paths are all relative to it, which is what makes a key and
      # the string the site builds at runtime agree.
      def self.common_root(paths)
        root = File.dirname(paths.fetch(0))
        root = File.dirname(root) until root == '/' || paths.all? { |p| p.start_with?("#{root}/") }
        root
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
      def concatenate_files(graph, sorted_paths, driver, split)
        content_parts = [] #: Array[String]
        file_boundaries = [] #: Array[FileBoundary]
        stdlib_requires = [] #: Array[String]
        marks = [] #: Array[FileMark]
        inlined = Set.new
        current_line = 1

        lazy_paths = graph.lazy_paths
        if driver && lazy_paths.empty?
          raise MinifyError, 'cannot write a driver file: the program has no lazy regions'
        end
        @root = self.class.common_root(graph.paths)
        @registry, @loader = lazy_paths.empty? || split ? [nil, nil] : bundle_names(graph, driver)

        # Pre-clean all files: resolve in-class requires by inlining. The
        # split layout keeps every file as written — its requires run as
        # requires, against the files written next to it — so nothing is
        # hoisted, inlined or pointed at a loader.
        cleaned_cache = {} #: Hash[String, String]
        sorted_paths.each do |path|
          entry = graph[path]
          next unless entry
          next cleaned_cache[path] = entry.content if split
          collect_stdlib_requires(entry, stdlib_requires) unless entry.lazy
          cleaned_cache[path] = process_require_statements(entry, graph, inlined, cleaned_cache)
        end

        if (registry = @registry) && (loader = @loader)
          prelude = driver ? registry_prelude(registry) : loader_prelude(registry, loader)
          content_parts << prelude
          current_line += prelude.count("\n") + 1
        end

        # Regions first: registering is all a region does at load, and it
        # has to be registered before any code that could ask for it runs.
        # In the split layout the dynamically loaded files come last
        # instead, after everything they subclass.
        lazy, flat = sorted_paths.partition { |path| graph[path]&.lazy }
        (split ? flat + lazy : lazy + flat).each do |path|
          next if inlined.include?(path)
          entry = graph[path]
          next unless entry

          cleaned_content = cleaned_cache.fetch(path)
          if split
            marks << FileMark.new(path: path, lazy: entry.lazy)
            cleaned_content = "#{FileMarks.statement(marks.size - 1)}\n#{cleaned_content}"
          elsif entry.lazy
            cleaned_content = lazy_registration(path, cleaned_content)
          end
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
          lazy_files: lazy_paths,
          driver: driver,
          marks: marks
        )
      end

      def relative_to_root(path)
        path.delete_prefix(@root == '/' ? '/' : "#{@root}/")
      end

      def lazy_key(path)
        relative_to_root(path).delete_suffix('.rb')
      end

      # Names the program does not spell anywhere. The driver speaks the two
      # base names and nothing else, so under the driver layout they cannot
      # move: a program that spells one cannot take that layout.
      def bundle_names(graph, driver)
        contents = graph.files.each_value.map(&:content)
        [REGISTRY_NAME, LOADER_NAME].map do |base|
          next unused_name(base, contents) unless driver
          if spelled?(base, contents)
            raise MinifyError, "cannot write a driver file: the program spells #{base}, a name the driver speaks"
          end
          base
        end
      end

      def unused_name(base, contents)
        name = base
        suffix = 0
        while spelled?(name, contents)
          suffix += 1
          name = "#{base}_#{suffix}"
        end
        name
      end

      def spelled?(name, contents)
        contents.any? { |c| c.match?(/\b#{Regexp.escape(name)}\b/) }
      end

      # The driver layout's prelude: the registry the regions fill, and no
      # loader — the driver defines it before it loads the core.
      def registry_prelude(registry)
        "#{registry} = {}\n"
      end

      # The loader keeps Ruby's require contract for the regions it owns: a
      # region runs once and answers true, a repeat answers false, a region
      # whose run raised (its `require "ffi"` had no ffi) is restored so a
      # later require can try it again, and a path no region was registered
      # under falls through to a real require_relative — relative to the
      # bundle, the one file all this code now lives in.
      def loader_prelude(registry, loader)
        <<~RUBY
          #{registry} = {}
          def #{loader}(path)
            return require_relative(path) unless #{registry}.key?(path)
            body = #{registry}[path]
            return false unless body
            #{registry}[path] = false
            begin
              body.call
            rescue Exception
              #{registry}[path] = body
              raise
            end
            true
          end
        RUBY
      end

      # The file as a region (see LazyRegions): its own line for the closing
      # brace, so a trailing comment cannot swallow it.
      def lazy_registration(path, content)
        "#{@registry}[#{lazy_key(path).dump}] = -> {\n#{content}\n}"
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
          offset_based_processing(content, nodes_with_offsets, graph, in_class_deps, inlined, cleaned_cache, entry.lazy)
        else
          line_based_processing(content, require_nodes)
        end
      end

      def offset_based_processing(content, nodes, graph, in_class_deps, inlined, cleaned_cache, lazy_entry)
        sorted_nodes = nodes.sort_by { |n| n[:start_offset] }.reverse
        # Prism offsets are byte offsets: splice on bytes, or any multibyte
        # character before a require shifts every slice after it.
        result = content.b
        sorted_nodes.each do |node|
          start_pos = node[:start_offset]
          end_pos = start_pos + node[:length]

          if node[:type] == :require_lazy
            result[start_pos...end_pos] = lazy_site_call(result, node).b
            next
          end

          dep_path = resolve_node_path(node, graph)
          # A require that names a region asks the loader for it, whether
          # the site is a static sibling require inside another region or
          # an autoload — which then loads at that point, as it does for a
          # flat file.
          if dep_path && graph[dep_path]&.lazy
            result[start_pos...end_pos] = "#{@loader}(#{lazy_key(dep_path).dump})".b
            next
          end

          if node[:in_class] && !node[:in_method] && node[:type] != :require_stdlib
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
          # it is — deleting it here would drop the require altogether. Nothing
          # in a region is hoisted: its requires run when the region does.
          next if node[:type] == :require_stdlib && (node[:in_method] || lazy_entry)

          # For removal: consume trailing semicolons and newlines
          while end_pos < result.size && (result[end_pos] == ';' || result[end_pos] == "\n")
            end_pos += 1
          end
          result[start_pos...end_pos] = ''
        end
        result.force_encoding(content.encoding)
      end

      # `require_relative "driver/#{name}_#{type}"` becomes
      # `ryac_require("optcarrot/driver/#{name}_#{type}")`: the literal keeps
      # its interpolation, its static prefix is respelled relative to the
      # bundle root — the spelling the regions were registered under — and a
      # literal ".rb" tail goes, as keys carry no extension. The bytes are
      # read before this node's own edit, so every offset is still original.
      def lazy_site_call(bytes, node)
        site = node.fetch(:lazy)
        arg = bytes[site[:arg_start_offset]...site[:arg_end_offset]] #: String
        base = site[:arg_start_offset]
        if (suffix_start = site[:suffix_start_offset])
          arg[(suffix_start - base), 3] = ''
        end
        dir = site[:dir]
        arg[(site[:prefix_start_offset] - base), site[:prefix_length]] = (dir == @root ? '' : "#{relative_to_root(dir)}/").b
        "#{@loader}(#{arg})"
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
