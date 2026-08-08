# frozen_string_literal: true

module RubyMinify
  def build_scope_mappings(nodes, scope_mappings, kw_def_map: nil, var_hints_map: nil)
    register_top_level_scope(nodes, scope_mappings)
    nodes.body.stmts.each { |subnode| collect_scope_vars(subnode, scope_mappings, kw_def_map: kw_def_map, var_hints_map: var_hints_map) }
  end

  def register_top_level_scope(nodes, scope_mappings)
    return unless nodes.tbl && !nodes.tbl.empty?

    cref_id = get_body_cref_id(nodes.body)
    return unless cref_id && !scope_mappings[cref_id]

    is_unsafe = check_dynamic_pattern(nodes.body)
    generator = NameGenerator.new([])
    mapping = {}
    nodes.tbl.each do |var|
      mapping[var] = is_unsafe ? var.to_s : generator.next_name
    end
    scope_mappings[cref_id] = mapping
  end

  def collect_scope_vars(node, scope_mappings, kw_def_map: nil, var_hints_map: nil)
    case node
    when TypeProf::Core::AST::DefNode
      cref_id = get_body_cref_id(node.body)
      if cref_id && !scope_mappings[cref_id]
        is_unsafe = check_dynamic_pattern(node.body)
        keyword_params = Set.new((node.req_keywords || []) + (node.opt_keywords || []))

        unused_rescue = collect_unused_rescue_vars(node.body)
        kw_mapping = kw_def_map&.[](node.object_id)
        var_hints = var_hints_map&.[](cref_id) || {}
        reserved_names = var_hints.values.dup
        reserved_names.concat(kw_mapping.values) if kw_mapping
        keyword_params.each do |kw|
          final_name = kw_mapping&.[](kw) || kw.to_s
          reserved_names << final_name
        end
        generator = NameGenerator.new(reserved_names.uniq)
        mapping = {}
        # A keyword parameter's name does not depend on where it sits in tbl,
        # so settle all of them before handing any name out. Otherwise a hint
        # for an ordinary local appearing earlier in tbl can claim the name a
        # keyword takes later, emitting `def f(c, c: {})`.
        keyword_names = {}
        keyword_params.each { |kw| keyword_names[kw] = kw_mapping&.[](kw) || kw.to_s }
        claimed = Set.new(keyword_names.values)
        node.tbl.each do |var|
          next if unused_rescue.include?(var)
          if keyword_params.include?(var)
            mapping[var] = keyword_names[var]
          elsif !is_unsafe && var_hints.key?(var) && !claimed.include?(var_hints[var])
            mapping[var] = var_hints[var]
            claimed << var_hints[var]
          else
            name = is_unsafe ? var.to_s : generator.next_name
            mapping[var] = name
            claimed << name
          end
        end
        scope_mappings[cref_id] = mapping
      end
      collect_scope_vars(node.body, scope_mappings, kw_def_map: kw_def_map, var_hints_map: var_hints_map) if node.body
      return

    when TypeProf::Core::AST::CallNode
      collect_scope_vars(node.recv, scope_mappings, kw_def_map: kw_def_map, var_hints_map: var_hints_map) if node.recv
      node.positional_args.each { |arg| collect_scope_vars(arg, scope_mappings, kw_def_map: kw_def_map, var_hints_map: var_hints_map) }

      if node.block_body
        cref_id = get_body_cref_id(node.block_body)
        if cref_id && !scope_mappings[cref_id]
          is_unsafe = check_dynamic_pattern(node.block_body)

          parent_mangled_names = collect_parent_mangled_names(node.block_body, scope_mappings)

          if !is_unsafe && should_use_numbered_params?(node, parent_mangled_names)
            mapping = {}
            node.block_f_args.each_with_index do |param, idx|
              mapping[param] = "_#{idx + 1}"
            end
          else
            generator = NameGenerator.new(parent_mangled_names)
            mapping = {}
            node.block_f_args.each do |param|
              next unless param
              next if param.to_s.match?(/^_\d*$/)
              mapping[param] = is_unsafe ? param.to_s : generator.next_name
            end
            node.block_multi_targets&.each_value do |mt|
              collect_multi_target_names(mt).each do |name|
                mapping[name] = is_unsafe ? name.to_s : generator.next_name
              end
            end
          end
          # Add non-required block params (optional, rest, keyword, block) from Prism AST
          raw = AstUtils.prism_node(node)
          if raw.block.is_a?(Prism::BlockNode) &&
             raw.block.parameters.is_a?(Prism::BlockParametersNode) &&
             raw.block.parameters.parameters
            generator ||= NameGenerator.new(parent_mangled_names)
            collect_extra_block_param_names(raw.block.parameters.parameters).each do |name|
              next if mapping.key?(name)
              mapping[name] = is_unsafe ? name.to_s : generator.next_name
            end
          end
          scope_mappings[cref_id] = mapping
        end
        collect_scope_vars(node.block_body, scope_mappings, kw_def_map: kw_def_map, var_hints_map: var_hints_map)
      end
      return
    end

    node.each_subnode { |child| collect_scope_vars(child, scope_mappings, kw_def_map: kw_def_map, var_hints_map: var_hints_map) }
  end

  def collect_extra_block_param_names(prism_params)
    names = []
    prism_params.optionals&.each { |p| names << p.name }
    names << prism_params.rest.name if prism_params.rest.is_a?(Prism::RestParameterNode) && prism_params.rest.name
    prism_params.posts&.each { |p| names << p.name if p.is_a?(Prism::RequiredParameterNode) }
    prism_params.keywords&.each { |p| names << p.name }
    names << prism_params.keyword_rest.name if prism_params.keyword_rest.is_a?(Prism::KeywordRestParameterNode) && prism_params.keyword_rest.name
    names << prism_params.block.name if prism_params.block.is_a?(Prism::BlockParameterNode) && prism_params.block.name
    names
  end

  def get_body_cref_id(body)
    return nil unless body
    return nil if body.is_a?(TypeProf::Core::AST::DummyNilNode)
    body.lenv&.cref&.object_id
  end

  def collect_parent_mangled_names(body, scope_mappings)
    mangled_names = []
    return mangled_names unless body&.lenv&.cref

    current_cref = body.lenv.cref.outer
    while current_cref
      mapping = scope_mappings[current_cref.object_id]
      mangled_names.concat(mapping.values) if mapping
      current_cref = current_cref.outer
    end

    mangled_names
  end

  def should_use_numbered_params?(node, parent_mangled_names)
    return false if node.block_f_args.empty?
    return false unless node.block_body
    return false if node.block_f_args.include?(nil)
    return false if node.block_f_args.any? { |p| p.to_s.match?(/^_\d+$/) }
    return false if parent_mangled_names.any? { |n| n.match?(/^_\d+$/) }

    param_set = node.block_f_args.to_set
    ref_counts = Hash.new(0)

    node.block_body.traverse do |event, child|
      next unless event == :enter

      if (child.is_a?(TypeProf::Core::AST::CallNode) && child.block_body) ||
         child.is_a?(TypeProf::Core::AST::LambdaNode)
        return false
      end

      if child.is_a?(TypeProf::Core::AST::LocalVariableWriteNode) && param_set.include?(child.var)
        return false
      end

      if child.is_a?(TypeProf::Core::AST::LocalVariableReadNode) && param_set.include?(child.var)
        ref_counts[child.var] += 1
      end
    end

    # Don't convert if highest used param isn't the last declared param
    # — numbered param arity = highest _N referenced, so unused trailing params reduce arity
    highest_used = 0
    node.block_f_args.each_with_index do |param, idx|
      highest_used = idx + 1 if ref_counts[param] > 0
    end
    return false if highest_used < node.block_f_args.size

    generator = NameGenerator.new(parent_mangled_names)
    mangled_names = node.block_f_args.map { generator.next_name }

    pipe_overhead = 2 + mangled_names.sum(&:length) + mangled_names.size - 1
    reference_overhead = node.block_f_args.each_with_index.sum do |param, idx|
      numbered_len = "_#{idx + 1}".length
      (numbered_len - mangled_names[idx].length) * ref_counts[param]
    end

    pipe_overhead - reference_overhead > 0
  end

  def collect_unused_rescue_vars(body)
    unused = Set.new
    return unused unless body

    body.traverse do |event, n|
      next unless event == :enter
      next unless n.is_a?(TypeProf::Core::AST::BeginNode)

      n.rescue_clauses.each do |rc|
        next unless rc.respond_to?(:reference) && rc.reference
        next unless rc.reference.respond_to?(:var)

        var = rc.reference.var
        used = false
        if rc.statements
          rc.statements.traverse do |ev, child|
            next unless ev == :enter
            if child.is_a?(TypeProf::Core::AST::LocalVariableReadNode) && child.var == var
              used = true
            end
          end
        end
        unused << var unless used
      end
    end
    unused
  end

  DYNAMIC_VARIABLE_METHODS = %i[
    eval instance_eval class_eval module_eval
    binding local_variable_get local_variable_set
  ].freeze

  def check_dynamic_pattern(node)
    return false unless node

    node.traverse do |event, child|
      next unless event == :enter
      if child.is_a?(TypeProf::Core::AST::CallNode) && DYNAMIC_VARIABLE_METHODS.include?(child.mid)
        return true
      end
    end
    false
  end

  def collect_multi_target_names(multi_target_node)
    names = []
    multi_target_node.lefts.each do |p|
      if p.is_a?(Prism::RequiredParameterNode)
        names << p.name
      elsif p.is_a?(Prism::MultiTargetNode)
        names.concat(collect_multi_target_names(p))
      end
    end
    if multi_target_node.rest.is_a?(Prism::SplatNode) &&
       multi_target_node.rest.expression.is_a?(Prism::RequiredParameterNode)
      names << multi_target_node.rest.expression.name
    end
    names
  end

  def get_mangled_name(node, var, scope_mappings)
    return var.to_s if var.to_s.match?(/^_\d+$/)

    cref = node.lenv&.cref
    return var.to_s unless cref

    current_cref = cref
    while current_cref
      mapping = scope_mappings[current_cref.object_id]
      return mapping[var] if mapping&.key?(var)
      current_cref = current_cref.outer
    end

    var.to_s
  end
end
