# frozen_string_literal: true

module Ryac
  module Pipeline
    # Represents a single source file discovered during collection
    # Immutable after creation
    FileEntry = Data.define(
      :path,                  # String: Absolute path to the file
      :content,               # String: Raw file content
      :dependencies,          # Array<String>: Absolute paths of required files (top-level requires only)
      :require_nodes,         # Array<Hash>: {type:, path:, line:, in_class:} for require/autoload nodes
      :in_class_dependencies, # Array<String>: Absolute paths of files required inside class/module bodies
      :lazy                   # Boolean: reached only through a dynamic require — bundled as a lazy region, run on demand
    ) do
      # declared on the Data class itself in the RBS
      def initialize(path:, content:, dependencies:, require_nodes:, in_class_dependencies: [], lazy: false) # steep:ignore UndeclaredMethodDefinition
        super
      end
    end

    # Represents the dependency relationships between files
    # Uses adjacency list for efficient topological sort
    class DependencyGraph
      attr_reader :files, :adjacency, :in_degrees, :rbs_files

      def initialize
        @files = {}       # Hash<String, FileEntry>: path -> entry mapping
        @adjacency = {}   # Hash<String, Array<String>>: path -> dependent paths (files that require this one)
        @in_degrees = {}  # Hash<String, Integer>: path -> number of dependencies
        @rbs_files = {}   # Hash<String, String>: path -> RBS content
      end

      # The files bundled as lazy regions, in path order.
      def lazy_paths
        @files.each_value.select(&:lazy).map(&:path).sort
      end

      # Add a file entry to the graph
      # @param entry [FileEntry] The file entry to add
      def add_file(entry)
        @files[entry.path] = entry
        @adjacency[entry.path] ||= []
        @in_degrees[entry.path] ||= 0

        # Update adjacency and in-degrees based on all dependencies
        (entry.dependencies + entry.in_class_dependencies).each do |dep_path|
          @adjacency[dep_path] ||= []
          @adjacency[dep_path] << entry.path
          @in_degrees[entry.path] += 1
        end
      end

      # Get all file paths in the graph
      # @return [Array<String>]
      def paths
        @files.keys
      end

      # Get file entry by path
      # @param path [String]
      # @return [FileEntry, nil]
      def [](path)
        @files[path]
      end

      # Number of files in the graph
      # @return [Integer]
      def size
        @files.size
      end

      # Check if graph is empty
      # @return [Boolean]
      def empty?
        @files.empty?
      end
    end

    # Source map entry for tracking file boundaries in concatenated output
    FileBoundary = Data.define(
      :path,        # String: Original file path
      :start_line,  # Integer: 1-indexed start line in concatenated output
      :end_line     # Integer: 1-indexed end line in concatenated output
    )

    # Output of Stage 2 (Concatenator), input to Stage 3 (Minifier)
    #
    # Stages that rewrite the text rebuild this with #with(content: ...):
    # original_size and file_boundaries describe the collected input, not the
    # current text, and #with is what keeps them traveling unchanged.
    ConcatenatedSource = Data.define(
      :content,          # String: All files joined with separators
      :file_boundaries,  # Array<FileBoundary>: Line ranges are true at concatenation only; the pipeline rewrites the text from compaction on
      :original_size,    # Integer: Bytes of the input the content descends from
      :stdlib_requires,  # Array<String>: Standard library requires to preserve
      :rbs_files,        # Hash<String, String>: path -> RBS content for TypeProf
      :lazy_files,       # Array<String>: paths of the files bundled as lazy regions (see LazyRegions)
      :driver            # Boolean: the loader is a driver file outside the program, which reads the registry by name (see DriverFile)
    ) do
      # A source built straight from a string (tests, sub-pipelines) has no
      # file ancestry: everything but the content defaults away, and its
      # original size is the content itself.
      def initialize(content:, file_boundaries: [], original_size: nil, stdlib_requires: [], rbs_files: {}, lazy_files: [], driver: false) # steep:ignore UndeclaredMethodDefinition
        super(content: content, file_boundaries: file_boundaries,
              original_size: original_size || content.bytesize,
              stdlib_requires: stdlib_requires, rbs_files: rbs_files,
              lazy_files: lazy_files, driver: driver)
      end
    end

    # Output of Stage 3 (Analyzer), input to Stage 4 (Minifier)
    AnalysisResult = Data.define(
      :prism_ast,                  # Prism::ProgramNode for rebuild
      :scope_mappings,             # Hash: cref_id -> variable mapping
      :constant_mapping,           # ConstantRenameMapping — short names are assigned by ConstantAliaser#collect, the only stage that reads it
      :rename_map,                 # Hash<location_key, String>: method short names + attr coordinate adjustments
      :method_alias_map,           # Hash<location_key, Symbol>: method alias replacements
      :method_transform_map,       # Hash<location_key, String>: structural transforms (e.g. .first → [0])
      :source,                     # ConcatenatedSource: original input preserved
      :attr_rename_map,            # Hash<location_key, Hash<Symbol, String>>: attr symbol renames
      :block_param_names_map,      # Hash<location_key, Hash<Symbol, String>>: pre-computed block param mangled names
      :syntax_data,                # Hash<[line,col], Hash>: Prism-derived syntax metadata
      :const_resolution_map,       # Hash<location_key, Array>: resolved constant cpaths
      :const_full_path_map,        # Hash<location_key, Array>: resolved constant paths (fallback: syntactic)
      :const_write_cpath_map,      # Hash<location_key, Array>: normalized write cpaths
      :class_cpath_map,            # Hash<location_key, Array>: class/module cpaths
      :superclass_resolution_map,  # Hash<location_key, Array>: resolved superclass paths
      :meta_node_map,              # Hash<location_key, Hash>: meta node info (attr_reader, etc.)
      :local_rename_entries,       # Hash<location_key, String>: local vars + lambda vars
      :keyword_rename_entries,     # Hash<location_key, String>: keyword arg renames
      :ivar_rename_entries,        # Hash<location_key, String>: instance variable renames
      :attr_ivar_entries,          # Hash<location_key, String>: attr-backed ivar renames (only valid when MethodRenamer runs)
      :cvar_rename_entries,        # Hash<location_key, String>: class variable renames
      :gvar_rename_entries         # Hash<location_key, String>: global variable renames
    ) do
      def initialize(local_rename_entries: {}, keyword_rename_entries: {}, ivar_rename_entries: {}, attr_ivar_entries: {}, cvar_rename_entries: {}, gvar_rename_entries: {}, **kwargs) # steep:ignore UndeclaredMethodDefinition
        super(local_rename_entries: local_rename_entries, keyword_rename_entries: keyword_rename_entries, ivar_rename_entries: ivar_rename_entries, attr_ivar_entries: attr_ivar_entries, cvar_rename_entries: cvar_rename_entries, gvar_rename_entries: gvar_rename_entries, **kwargs)
      end
    end

    # Compression statistics for the final output
    CompressionStats = Data.define(
      :original_size,     # Integer: Bytes before minification
      :minified_size,     # Integer: Bytes after minification
      :compression_ratio, # Float: 0.0-1.0 (1.0 = no compression)
      :file_count         # Integer: Number of files processed
    )

    # Internal return type of the rename stages: the parts of the program,
    # not yet assembled. code deliberately carries no requires and no
    # preamble — the Minifier joins the parts into MinifiedResult#content,
    # which is why the field is not called content.
    RenameResult = Data.define(
      :code,      # String: Minified Ruby code alone (no requires, no preamble)
      :aliases,   # String: Backward-compatible constant alias declarations (e.g. "MyClass=A;Foo=B")
      :preamble   # String: External prefix declarations (e.g. "A=Process") — must execute before code
    ) do
      def initialize(code:, aliases: '', preamble: '') # steep:ignore UndeclaredMethodDefinition
        super
      end
    end

    # Final output of the pipeline.
    #
    # content is the assembled runnable program: stdlib requires, then the
    # preamble, then the minified code. preamble is a slice of content
    # carried separately so callers that split output can identify it —
    # never something to append to content again. aliases are the one part
    # kept out: optional compatibility shims, attached by full_content or
    # written to their own file.
    MinifiedResult = Data.define(
      :content,   # String: requires + preamble + minified code
      :aliases,   # String: Backward-compatible constant alias declarations
      :preamble,  # String: External prefix declarations (already included in content)
      :stats      # CompressionStats
    ) do
      def initialize(content:, aliases: '', preamble: '', stats:) # steep:ignore UndeclaredMethodDefinition
        super
      end

      # The program with its alias shims attached — what a caller runs when
      # not splitting the aliases into a separate file.
      def full_content # steep:ignore UndeclaredMethodDefinition
        aliases.empty? ? content : "#{content};#{aliases}" # steep:ignore NoMethod
      end
    end
  end
end
