require "active_record"

module ActiveRecord
  module Like
    module WhereChainExtensions
      def like(opts, *rest)
        opts.each do |k, v|
          if v.is_a?(Array) && v.empty?
            opts[k] = ''
          end
        end

        # Add the wildcard character (%) to the start and end of all strings in opts
        opts = opts.deep_transform_values { |v| v.empty? ? v : "%#{v}%" }

        chain_node(Arel::Nodes::Matches, opts, *rest) do |nodes|
          nodes.inject { |memo, node| Arel::Nodes::Or.new(memo, node) }
        end
      end

      # Search fields using "ILIKE %#{search_term}%". If an array of values is provided, ensure
      # that records match all of the values, rather than any of them, i.e. use AND rather than
      # OR/IN. Useful so you don't have to chain like together multiple times,
      # i.e. where.like().like().like()...
      #
      # @param opts [Object] the options of the where.like clause
      # @return [Array<AR Objects>, Array<nil>]
      #
      # @example
      # Job.where.like(title: ["Rails", "Vue", "Senior"])
      # => Any jobs which have Rails, Vue OR Senior in the title.
      #
      # Job.where.all_like(title: ["Rails", "Vue", "Senior"])
      # Job.like(title: "Rails").like(title: "Vue").like(title: "Senior") # Same as above
      # => Jobs which have Rails, Vue, AND Senior in the title.
      def all_like(opts, *rest)
        opts.each do |k, v|
          if v.is_a?(Array) && v.empty?
            opts[k] = ''
          end
        end

        # Add the wildcard character (%) to the start and end of all strings in opts
        opts = opts.deep_transform_values { |v| v.empty? ? v : "%#{v}%" }

        chain_node(Arel::Nodes::Matches, opts, *rest) { |nodes| Arel::Nodes::And.new(nodes) }
      end

      def not_like(opts, *rest)
        opts = opts.reject { |_, v| v.is_a?(Array) && v.empty? }

        # Add the wildcard character (%) to the start and end of all strings in opts
        opts = opts.deep_transform_values { |v| v.empty? ? v : "%#{v}%" }

        chain_node(Arel::Nodes::DoesNotMatch, opts, *rest) do |nodes|
          Arel::Nodes::And.new(nodes)
        end
      end

      private

      def chain_node(node_type, opts, *rest, &block)
        @scope.tap do |s|
          # Assuming `opts` to be `Hash`
          opts.each_pair do |key, value|
            # 1. Build a where clause to generate "predicates" & "binds"
            # 2. Convert "predicates" into the one that matches `node_type` (like/not like)
            # 3. Re-use binding values to create new where clause
            equal_where_clause = if s.respond_to?(:where_clause_factory, true)
              # ActiveRecord 5.0 to 6.0
              s.send(:where_clause_factory).build({key => value}, rest)
            else
              # ActiveRecord 6.1, maybe higher
              s.send(:build_where_clause, {key => value}, rest)
            end
            equal_where_clause_predicate = equal_where_clause.send(:predicates).first

            new_predicate = if equal_where_clause_predicate.right.is_a?(Array)
              nodes = equal_where_clause_predicate.right.map do |expr|
                node_type.new(equal_where_clause_predicate.left, expr)
              end
              Arel::Nodes::Grouping.new block.call(nodes)
            else
              node_type.new(equal_where_clause_predicate.left, equal_where_clause_predicate.right)
            end

            # Passing `Arel::Nodes::Node` into `where_clause_factory`
            # Will lose the binding values since 5.1
            # due to this PR
            # https://github.com/rails/rails/pull/26073
            new_where_clause = if equal_where_clause.respond_to?(:binds)
              Relation::WhereClause.new([new_predicate], equal_where_clause.binds)
            else
              Relation::WhereClause.new([new_predicate])
            end

            s.where_clause += new_where_clause
          end
        end
      end
    end
  end
end

ActiveSupport.on_load(:active_record) do
  ActiveRecord.eager_load!

  ActiveRecord::QueryMethods::WhereChain.send(:include, ::ActiveRecord::Like::WhereChainExtensions)
end
