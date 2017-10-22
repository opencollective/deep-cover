require_relative 'variables'
require_relative 'collections'

module DeepCover
  class Node
    class Resbody < Node
      has_tracker :entered_body
      has_child exception: [Node::Array, nil]
      has_child assignment: [Lvasgn, nil], flow_entry_count: :entered_body_tracker_hits
      has_child body: [Node, nil],
                flow_entry_count: :entered_body_tracker_hits,
                is_statement: true,
                rewrite: '((%{entered_body_tracker};%{node}))'

      def is_statement
        false
      end

      def rewrite
        return if body
        '%{node};%{entered_body_tracker};nil'
      end

      def flow_completion_count
        return body.flow_completion_count if body
        execution_count
      end

      def execution_count
        entered_body_tracker_hits
      end
    end

    class Rescue < Node
      has_child watched_body: [Node, nil],
                is_statement: true
      has_extra_children resbodies: Resbody
      has_child else: [Node, nil],
                flow_entry_count: :execution_count,
                is_statement: true
      executed_loc_keys :else

      def is_statement
        false
      end

      def flow_completion_count
        return flow_entry_count unless watched_body
        resbodies.map(&:flow_completion_count).inject(0, :+) + (self.else || watched_body).flow_completion_count
      end

      def execution_count
        watched_body ? watched_body.flow_completion_count : flow_entry_count
      end

      def resbodies_flow_entry_count(child)
        return 0 unless watched_body
        prev = child.previous_sibling

        if prev.equal? watched_body
          prev.flow_entry_count - prev.flow_completion_count
        else # RESBODIES
          # TODO is this okay?
          prev.exception.flow_completion_count - prev.execution_count
        end
      end
    end

    class Ensure < Node
      has_child body: [Node, nil],
                is_statement: true
      has_child ensure: [Node, nil],
                is_statement: true,
                flow_entry_count: -> { body.flow_entry_count }

      def execution_count
        flow_entry_count
      end

      def flow_completion_count
        return body.flow_completion_count if body
        return self.ensure.flow_completion_count if self.ensure
        execution_count
      end
    end
  end
end
