# frozen_string_literal: true

module Ryac
  # The seams of the split layout. The Concatenator opens every file with a
  # marker statement — a call to a method nothing defines, carrying the
  # file's index:
  #
  #   __ryac_mark__ 3
  #
  # No stage has a reason to touch it: it defines nothing, spells no name a
  # string rule could match, and has no definition a renamer could rename.
  # The analyzer reads the markers to know which file a node sits in — a
  # file a dynamic require loads is the split layout's lazy region — and
  # the splitter cuts the minified text at them.
  module FileMarks
    NAME = :__ryac_mark__

    module_function

    def statement(index)
      "#{NAME} #{index}"
    end

    # The marker's index when the node is one, else nil.
    def index(node)
      return nil unless node.is_a?(Prism::CallNode) && node.name == NAME && node.receiver.nil?

      args = node.arguments&.arguments
      return nil unless args && args.size == 1

      arg = args.fetch(0)
      arg.is_a?(Prism::IntegerNode) ? arg.value : nil
    end

    # Every marker among the top-level statements, with its index.
    def each_marker(prism_root)
      prism_root.statements.body.each do |statement|
        index = index(statement)
        yield statement, index if index
      end
    end

    # The [from, to] byte spans of the files a dynamic require loads: from
    # the marker to the next marker, or past the end of the text.
    def lazy_spans(prism_root, marks, content_size)
      markers = [] #: Array[[Prism::Node, Integer]]
      each_marker(prism_root) { |statement, index| markers << [statement, index] }
      markers.each_with_index.filter_map do |(statement, index), n|
        next unless marks.fetch(index).lazy

        following = markers[n + 1]
        to = following ? following.fetch(0).location.start_offset : content_size + 1
        [statement.location.start_offset, to]
      end
    end

    # The minified text cut at its markers: each file's absolute path to its
    # text, the marker and the separators around it gone. Every marker has
    # to be there still, in order — a stage that swallowed one (dead code
    # after a top-level return would) broke the layout.
    def split(code, marks)
      statements = Prism.parse(code).value.statements.body
      seams = [] #: Array[[Integer, Integer, Integer]]
      statements.each do |statement|
        index = index(statement)
        seams << [index, statement.location.start_offset, statement.location.end_offset] if index
      end
      unless seams.map(&:first) == (0...marks.size).to_a
        raise InternalError, "split layout lost a file marker: found #{seams.map(&:first).inspect} of #{marks.size}"
      end

      files = {} #: Hash[String, String]
      seams.each_with_index do |(index, _from, to), n|
        following = seams[n + 1]
        stop = following ? following.fetch(1) : code.bytesize
        # statement boundaries are character boundaries, so the slice is
        # valid text in the source's encoding
        body = code.byteslice(to, stop - to) #: String
        files[marks.fetch(index).path] = body.delete_prefix(';').delete_suffix(';')
      end
      files
    end
  end
end
