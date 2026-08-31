# frozen_string_literal: true

require 'prism'

module Ryac
  module Pipeline
    # Stage 1: File Collection
    # Discovers all dependencies via static analysis of require/require_relative/autoload
    class FileCollector
      # @param entry_path [String, Array<String>] Path(s) to entry point file(s)
      # @return [DependencyGraph] Graph of all discovered files
      # @raise [FileNotFoundError] If a required file doesn't exist
      # @raise [NoFilesError] If entry_path is nil or empty
      # @raise [DynamicRequireError] If a dynamic require is detected
      def call(entry_path, project_root: nil, gem_names: [], gem_require_paths: [])
        raise NoFilesError.new if entry_path.nil?

        entry_paths = Array(entry_path) #: Array[String]
        raise NoFilesError.new if entry_paths.empty?

        @graph = DependencyGraph.new
        @visited = Set.new
        @gem_names = gem_names
        @project_roots = if project_root
          # Array() leaves only Strings whichever of the two shapes came in
          Array(project_root).map { |p| File.expand_path(p) } # steep:ignore ArgumentTypeMismatch
        else
          root = find_project_root(entry_paths)
          root ? [root] : []
        end

        ensure_load_paths(gem_require_paths)

        entry_paths.each do |path|
          expanded = File.expand_path(path)
          raise FileNotFoundError.new(expanded) unless File.exist?(expanded)
          collect_file(expanded)
        end

        collect_rbs_files(entry_paths)
        @graph
      end

      private

      # Recursively collect a file and its dependencies
      def collect_file(file_path, required_from: nil, line: nil)
        return if @visited.include?(file_path)

        unless File.exist?(file_path)
          raise FileNotFoundError.new(file_path, required_from: required_from, line: line)
        end

        @visited.add(file_path)
        # Ruby source defaults to UTF-8; reading with the ambient locale instead
        # tags non-ASCII sources US-ASCII under a POSIX locale and every later
        # String operation raises on the invalid bytes.
        content = File.read(file_path, encoding: Encoding::UTF_8)

        # Parse and extract require statements
        require_nodes = extract_require_nodes(file_path, content)
        dependencies = [] #: Array[String]
        in_class_dependencies = [] #: Array[String]

        require_nodes.each do |node_info|
          dep_path = node_info[:resolved_path]
          next unless dep_path

          if node_info[:in_class]
            in_class_dependencies << dep_path
          else
            dependencies << dep_path
          end
          collect_file(dep_path, required_from: file_path, line: node_info[:line])
        end

        entry = FileEntry.new(
          path: file_path,
          content: content,
          dependencies: dependencies,
          in_class_dependencies: in_class_dependencies,
          require_nodes: require_nodes
        )

        @graph.add_file(entry)
      end

      # Extract require/require_relative/autoload nodes from source
      def extract_require_nodes(file_path, content)
        result = Prism.parse(content)
        # Collection is the only point that still knows which file a byte
        # came from — a syntax error surfaces here with real coordinates,
        # or downstream as a nameless internal failure.
        error = result.errors[0]
        if error
          raise Ryac::SyntaxError.new(error.message, path: file_path,
                                      line: error.location.start_line,
                                      column: error.location.start_column)
        end
        nodes = [] #: Array[require_node_info]

        traverse_for_requires(result.value, nodes, file_path)

        nodes
      end

      # Traverse AST to find require statements
      # @param in_method [Boolean] true when inside a DefNode body; dynamic requires are skipped
      def traverse_for_requires(node, nodes, file_path, in_method: false, in_class: false)
        return unless node

        case node
        when Prism::CallNode
          handle_call_node(node, nodes, file_path, in_method: in_method, in_class: in_class)
        when Prism::ProgramNode
          traverse_for_requires(node.statements, nodes, file_path, in_method: in_method, in_class: in_class)
        when Prism::StatementsNode
          node.body.each { |child| traverse_for_requires(child, nodes, file_path, in_method: in_method, in_class: in_class) }
        when Prism::ClassNode, Prism::ModuleNode
          traverse_for_requires(node.body, nodes, file_path, in_method: in_method, in_class: true)
        when Prism::DefNode
          traverse_for_requires(node.body, nodes, file_path, in_method: true, in_class: in_class)
        when Prism::IfNode
          traverse_for_requires(node.statements, nodes, file_path, in_method: in_method, in_class: in_class)
          traverse_for_requires(node.subsequent, nodes, file_path, in_method: in_method, in_class: in_class)
        when Prism::UnlessNode
          traverse_for_requires(node.statements, nodes, file_path, in_method: in_method, in_class: in_class)
          traverse_for_requires(node.else_clause, nodes, file_path, in_method: in_method, in_class: in_class)
        when Prism::ElseNode
          traverse_for_requires(node.statements, nodes, file_path, in_method: in_method, in_class: in_class)
        when Prism::BeginNode
          traverse_for_requires(node.statements, nodes, file_path, in_method: in_method, in_class: in_class)
        end
      end

      def handle_call_node(node, nodes, file_path, in_method: false, in_class: false)
        method_name = node.name

        case method_name
        when :require_relative
          handle_require_relative(node, nodes, file_path, in_method: in_method, in_class: in_class)
        when :require
          handle_require(node, nodes, file_path, in_method: in_method, in_class: in_class)
        when :autoload
          handle_autoload(node, nodes, file_path, in_method: in_method, in_class: in_class)
        end

        # Continue traversing for nested calls
        node.arguments&.arguments&.each do |arg|
          traverse_for_requires(arg, nodes, file_path, in_method: in_method, in_class: in_class)
        end
        traverse_for_requires(node.block, nodes, file_path, in_method: in_method, in_class: in_class) if node.block
      end

      def handle_require_relative(node, nodes, file_path, in_method: false, in_class: false)
        arg = node.arguments&.arguments&.first
        return unless arg

        if arg.is_a?(Prism::StringNode)
          nodes << {
            type: :require_relative,
            path: arg.unescaped,
            line: node.location.start_line,
            start_offset: node.location.start_offset,
            length: node.location.length,
            in_class: in_class,
            in_method: in_method,
            resolved_path: resolve_relative_path(arg.unescaped, file_path)
          }
        else
          if in_method
            collect_lazy_candidates(arg, file_path)
            return
          end

          raise DynamicRequireError.new(
            file_path,
            line: node.location.start_line,
            expression: node.slice
          )
        end
      end

      # A dynamic require inside a method stays a runtime require, but when
      # its path starts with a static directory ("driver/#{name}"), the
      # files it can load exist on disk right now. They are not bundled —
      # the laziness survives — but they will run against the minified
      # program, calling and overriding its methods by their original
      # names, so the analyzer gets to read them.
      def collect_lazy_candidates(arg, file_path)
        return unless arg.is_a?(Prism::InterpolatedStringNode)

        head = arg.parts.first
        return unless head.is_a?(Prism::StringNode)

        slash = head.unescaped.rindex('/')
        prefix = slash && head.unescaped[0..slash]
        return unless prefix

        dir = File.expand_path(prefix, File.dirname(file_path))
        Dir.glob(File.join(dir, '*.rb')).sort.each do |path|
          next if @visited.include?(path)
          @graph.lazy_files[path] ||= File.read(path, encoding: Encoding::UTF_8)
        end
      end

      def handle_require(node, nodes, file_path, in_method: false, in_class: false)
        arg = node.arguments&.arguments&.first
        return unless arg

        if arg.is_a?(Prism::StringNode)
          path = arg.unescaped
          if path.start_with?('./', '../')
            nodes << {
              type: :require,
              path: path,
              line: node.location.start_line,
              start_offset: node.location.start_offset,
              length: node.location.length,
              in_class: in_class,
              in_method: in_method,
              resolved_path: resolve_relative_path(path, file_path)
            }
          elsif (resolved = resolve_bare_require(path))
            nodes << {
              type: :require,
              path: path,
              line: node.location.start_line,
              start_offset: node.location.start_offset,
              length: node.location.length,
              in_class: in_class,
              in_method: in_method,
              resolved_path: resolved
            }
          else
            nodes << {
              type: :require_stdlib,
              path: path,
              line: node.location.start_line,
              start_offset: node.location.start_offset,
              length: node.location.length,
              in_class: in_class,
              in_method: in_method
            }
          end
        else
          return if in_method

          raise DynamicRequireError.new(
            file_path,
            line: node.location.start_line,
            expression: node.slice
          )
        end
      end

      def handle_autoload(node, nodes, file_path, in_method: false, in_class: false)
        args = node.arguments&.arguments
        return unless args && args.size >= 2

        path_arg = args[1]
        path = if path_arg.is_a?(Prism::StringNode)
          path_arg.unescaped
        else
          dir_interpolated_path(path_arg)
        end

        if path
          # Treat autoload paths like require_relative for local files
          if path.start_with?('./', '../') || !path.include?('/')
            nodes << {
              type: :autoload,
              path: path,
              line: node.location.start_line,
              start_offset: node.location.start_offset,
              length: node.location.length,
              in_class: in_class,
              in_method: in_method,
              resolved_path: resolve_relative_path(path, file_path)
            }
          elsif (resolved = resolve_bare_require(path))
            nodes << {
              type: :autoload,
              path: path,
              line: node.location.start_line,
              start_offset: node.location.start_offset,
              length: node.location.length,
              in_class: in_class,
              in_method: in_method,
              resolved_path: resolved
            }
          end
        else
          return if in_method

          raise DynamicRequireError.new(
            file_path,
            line: node.location.start_line,
            expression: node.slice
          )
        end
      end

      # "#{__dir__}/mixin/foo" reads as dynamic but is a constant at
      # collection time: __dir__ is the directory of the file being
      # collected. Recognizes exactly that shape — a sole receiverless,
      # argument-less __dir__ interpolation, then a /-prefixed literal
      # tail — and returns it as the file-relative "./mixin/foo" so the
      # ordinary relative resolution runs; nil for every other
      # interpolation.
      def dir_interpolated_path(path_arg)
        return nil unless path_arg.is_a?(Prism::InterpolatedStringNode)

        parts = path_arg.parts
        return nil unless parts.size == 2

        interp, rest = parts
        return nil unless interp.is_a?(Prism::EmbeddedStatementsNode) && rest.is_a?(Prism::StringNode)

        call = AstUtils.unwrap_statements(interp.statements)
        return nil unless call.is_a?(Prism::CallNode) &&
                          call.name == :__dir__ && call.receiver.nil? && call.arguments.nil?

        tail = rest.unescaped
        tail.start_with?('/') ? ".#{tail}" : nil
      end

      def ensure_load_paths(require_paths)
        require_paths.each do |path|
          $LOAD_PATH.unshift(path) unless $LOAD_PATH.include?(path)
        end
      end

      def collect_rbs_files(_entry_paths)
        @project_roots.each do |root|
          load_rbs_from(File.join(root, "sig"))
        end

        collect_rbs_stdlib_files
      end

      def collect_rbs_stdlib_files
        return if @gem_names.empty?

        stdlib_root = RBS::Repository::DEFAULT_STDLIB_ROOT

        @gem_names.each do |gem_name|
          gem_rbs_dir = File.join(stdlib_root, gem_name)
          versions = Dir.children(gem_rbs_dir) rescue next
          next if versions.empty?

          latest = versions.max_by { |v| Gem::Version.new(v) } #: String
          load_rbs_from(File.join(gem_rbs_dir, latest))
        end
      end

      def load_rbs_from(dir)
        Dir.glob(File.join(dir, "**", "*.rbs")).each do |path|
          @graph.rbs_files[path] = File.read(path, encoding: Encoding::UTF_8)
        end
      end

      def find_project_root(entry_paths)
        dir = File.dirname(File.expand_path(entry_paths.first))
        until dir == "/"
          return dir if File.exist?(File.join(dir, "Gemfile")) || File.directory?(File.join(dir, ".git"))
          dir = File.dirname(dir)
        end
        nil
      end

      def resolve_relative_path(path, from_file)
        path += '.rb' unless path.end_with?('.rb')
        File.expand_path(path, File.dirname(from_file))
      end

      # Resolve a bare require path (e.g., "foo") via $LOAD_PATH.
      # Returns absolute path if the file is under any project root, nil otherwise.
      def resolve_bare_require(path)
        result = $LOAD_PATH.resolve_feature_path(path)
        return nil unless result

        type, abs_path = result
        return nil unless type == :rb
        return nil unless @project_roots.any? { |root| abs_path.start_with?("#{root}/") }

        abs_path
      end
    end
  end
end
