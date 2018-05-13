# frozen_string_literal: true

require_relative 'subset'

module DeepCover
  class Analyser::Ruby25LikeBranch < Analyser
    def self.human_name
      'Ruby25 branches'
    end
    include Analyser::Subset
    SUBSET_CLASSES = [Node::Case, Node::Csend, Node::If, Node::ShortCircuit,
                      Node::Until, Node::UntilPost, Node::While, Node::WhilePost,
                     ].freeze

    def initialize(*args)
      super
      @loc_index = 0
    end

    def node_runs(node)
      runs = super
      if node.is_a?(Node::Branch) && covered?(runs)
        worst = worst_branch_runs(node)
        runs = worst unless covered?(worst)
      end
      runs
    end

    def results
      each_node.map do |node|
        case node
        when Node::Case
          handle_case(node)
        when Node::Csend
          handle_csend(node)
        when Node::If
          handle_if(node)
        when Node::ShortCircuit
          handle_short_circuit(node)
        when Node::Until, Node::While, Node::UntilPost, Node::WhilePost
          handle_until_while(node)
        end
      end.to_h
    end

    protected

    def handle_case(node)
      cond_info = [:case, *node_loc_infos(node)]

      sub_keys = [:when] * (node.branches.size - 1) + [:else]
      empty_fallbacks = node.whens.map { |w| (w.loc_hash[:begin] || w.loc_hash[:expression]).wrap_rwhitespace_and_comments.end }
      empty_fallbacks.map!(&:begin)

      if node.loc_hash[:else]
        empty_fallbacks << node.loc_hash[:end].begin
      else
        # DeepCover manually inserts a `else` for Case when there isn't one for tracker purposes.
        # The normal behavior of ruby25's branch coverage when there is no else is to return the loc of the node
        # So we sent that fallback.
        empty_fallbacks << node.expression
      end

      branches = node.whens.map do |when_node|
        next when_node.body if when_node.body.is_a?(Node::EmptyBody)

        start_at = when_node.loc_hash[:begin]
        start_at = start_at.wrap_rwhitespace_and_comments.end if start_at
        start_at ||= when_node.body.expression.begin

        end_at = when_node.body.expression.end
        start_at.with(end_pos: end_at.end_pos)
      end

      branches << node.else
      clauses_infos = infos_for_branches(node, branches, sub_keys, empty_fallbacks, execution_counts: node.branches.map(&:execution_count))

      [cond_info, clauses_infos]
    end

    def handle_csend(node)
      cond_info = [:"&.", *node_loc_infos(node)]
      false_branch, true_branch = node.branches
      [cond_info, {[:then, *node_loc_infos(node)] => true_branch.execution_count,
                   [:else, *node_loc_infos(node)] => false_branch.execution_count,
                  },
      ]
    end

    def handle_if(node)
      key = node.style == :unless ? :unless : :if

      node_range = extend_elsif_range(node)
      cond_info = [key, *node_loc_infos(node_range)]

      sub_keys = [:then, :else]
      if node.style == :ternary
        empty_fallback_locs = [nil, nil]
      else
        else_loc = node.loc_hash[:else]

        first_clause_fallback = node.loc_hash[:begin]
        if first_clause_fallback
          first_clause_fallback = first_clause_fallback.wrap_rwhitespace_and_comments.end
        elsif else_loc
          first_clause_fallback = else_loc.begin
        end

        if else_loc
          second_clause_fallback = else_loc.wrap_rwhitespace_and_comments.end
        end
        end_loc = node.root_if_node.loc_hash[:end]
        end_loc = end_loc.begin if end_loc

        empty_fallback_locs = [first_clause_fallback || end_loc, second_clause_fallback || end_loc]
      end
      # loc can be nil if the clause can't be empty, such as ternary and modifer if/unless

      if key == :unless
        sub_keys.reverse!
        empty_fallback_locs.reverse!
      end

      branches = node.branches
      execution_counts = branches.map(&:execution_count)
      branches[1] = extend_elsif_range(branches[1])

      clauses_infos = infos_for_branches(node_range, branches, sub_keys, empty_fallback_locs, execution_counts: execution_counts)
      [cond_info, clauses_infos]
    end

    def handle_short_circuit(node)
      cond_info = [node.operator, *node_loc_infos(node)]
      branches = node.branches
      sub_keys = [:then, :else]
      sub_keys.reverse! if node.is_a?(Node::Or)

      [cond_info, infos_for_branches(node, branches, sub_keys, [nil, nil])]
    end

    def handle_until_while(node)
      key = node.is_a?(Node::While) || node.is_a?(Node::WhilePost) ? :while : :until
      base_info = [key, *node_loc_infos(node)]
      if node.is_a?(Node::WhilePost) || node.is_a?(Node::UntilPost)
        if node.body.instructions.present?
          end_pos = node.body.instructions.last.expression.end_pos
          body = node.body.instructions.first.expression.with(end_pos: end_pos)
        else
          body = node.body.loc_hash[:end].begin
        end
      elsif node.body.is_a?(Node::Begin) && node.body.expressions.present?
        end_pos = node.body.expressions.last.expression.end_pos
        body = node.body.expressions.first.expression.with(end_pos: end_pos)
      else
        body = node.body
      end

      [base_info, {[:body, *node_loc_infos(body)] => node.body.execution_count}]
    end

    private

    def infos_for_branch(node, branch, key, empty_fallback_loc, execution_count: nil)
      if !branch.is_a?(Node::EmptyBody)
        loc = branch
      elsif branch.expression
        # There is clause, but it is empty
        loc = empty_fallback_loc
      else
        # There is no clause
        loc = node
      end

      execution_count ||= branch.execution_count
      [[key, *node_loc_infos(loc)], execution_count]
    end

    def infos_for_branches(node, branches, keys, empty_fallback_locs, execution_counts: [])
      branches_infos = branches.map.with_index do |branch, i|
        infos_for_branch(node, branch, keys[i], empty_fallback_locs[i], execution_count: execution_counts[i])
      end
      branches_infos.to_h
    end

    def node_loc_infos(source_range)
      if source_range.is_a?(Node)
        source_range = source_range.expression
      end
      @loc_index += 1
      [@loc_index, source_range.line, source_range.column, source_range.last_line, source_range.last_column]
    end

    # If the actual else clause (final one) of an if...elsif...end is empty, then Ruby makes the
    # node reach the `end` in its branch coverage output
    def extend_elsif_range(node)
      if node.is_a?(Node::If) && node.style == :elsif
        deepest_if = node.deepest_elsif_node || node
        if deepest_if.false_branch.is_a?(Node::EmptyBody)
          return node.expression.with(end_pos: node.root_if_node.loc_hash[:end].begin_pos)
        end
      end
      node
    end
  end
end
