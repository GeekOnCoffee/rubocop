# encoding: utf-8

module RuboCop
  module Cop
    # This force provides a way to track local variables and scopes of Ruby.
    # Cops intertact with this force need to override some of the hook methods.
    #
    #     def before_entering_scope(scope, variable_table)
    #     end
    #
    #     def after_entering_scope(scope, variable_table)
    #     end
    #
    #     def before_leaving_scope(scope, variable_table)
    #     end
    #
    #     def after_leaving_scope(scope, variable_table)
    #     end
    #
    #     def before_declaring_variable(variable, variable_table)
    #     end
    #
    #     def after_declaring_variable(variable, variable_table)
    #     end
    class VariableForce < Force # rubocop:disable Style/ClassLength
      VARIABLE_ASSIGNMENT_TYPE = :lvasgn
      REGEXP_NAMED_CAPTURE_TYPE = :match_with_lvasgn
      VARIABLE_ASSIGNMENT_TYPES =
        [VARIABLE_ASSIGNMENT_TYPE, REGEXP_NAMED_CAPTURE_TYPE].freeze

      ARGUMENT_DECLARATION_TYPES = [
        :arg, :optarg, :restarg,
        :kwarg, :kwoptarg, :kwrestarg,
        :blockarg, # This doen't mean block argument, it's block-pass (&block).
        :shadowarg # This means block local variable (obj.each { |arg; this| }).
      ].freeze

      LOGICAL_OPERATOR_ASSIGNMENT_TYPES = [:or_asgn, :and_asgn].freeze
      OPERATOR_ASSIGNMENT_TYPES =
        (LOGICAL_OPERATOR_ASSIGNMENT_TYPES + [:op_asgn]).freeze

      MULTIPLE_ASSIGNMENT_TYPE = :masgn

      VARIABLE_REFERENCE_TYPE = :lvar

      POST_CONDITION_LOOP_TYPES = [:while_post, :until_post].freeze
      LOOP_TYPES = (POST_CONDITION_LOOP_TYPES + [:while, :until, :for]).freeze

      RESCUE_TYPE = :rescue

      ZERO_ARITY_SUPER_TYPE = :zsuper

      TWISTED_SCOPE_TYPES = [:block, :class, :sclass, :defs].freeze
      SCOPE_TYPES = (TWISTED_SCOPE_TYPES + [:top_level, :module, :def]).freeze

      def self.wrap_with_top_level_node(node)
        # This is a custom node type, not defined in Parser.
        Parser::AST::Node.new(:top_level, [node])
      end

      def variable_table
        @variable_table ||= VariableTable.new(self)
      end

      # Starting point.
      def investigate(processed_source)
        root_node = processed_source.ast
        return unless root_node

        # Wrap the root node with :top_level scope node.
        top_level_node = self.class.wrap_with_top_level_node(root_node)

        inspect_variables_in_scope(top_level_node)
      end

      # This is called for each scope recursively.
      def inspect_variables_in_scope(scope_node)
        variable_table.push_scope(scope_node)
        process_children(scope_node)
        variable_table.pop_scope
      end

      def process_children(origin_node)
        origin_node.children.each do |child|
          next unless child.is_a?(Parser::AST::Node)
          next if scanned_node?(child)
          process_node(child)
        end
      end

      def process_node(node)
        catch(:skip_children) do
          dispatch_node(node)
          process_children(node)
        end
      end

      def skip_children!
        throw :skip_children
      end

      # rubocop:disable Style/MethodLength, Style/CyclomaticComplexity
      def dispatch_node(node)
        case node.type
        when *ARGUMENT_DECLARATION_TYPES
          process_variable_declaration(node)
        when VARIABLE_ASSIGNMENT_TYPE
          process_variable_assignment(node)
        when REGEXP_NAMED_CAPTURE_TYPE
          process_regexp_named_captures(node)
        when *OPERATOR_ASSIGNMENT_TYPES
          process_variable_operator_assignment(node)
        when MULTIPLE_ASSIGNMENT_TYPE
          process_variable_multiple_assignment(node)
        when VARIABLE_REFERENCE_TYPE
          process_variable_referencing(node)
        when *LOOP_TYPES
          process_loop(node)
        when RESCUE_TYPE
          process_rescue(node)
        when ZERO_ARITY_SUPER_TYPE
          process_zero_arity_super(node)
        when *SCOPE_TYPES
          process_scope(node)
        end
      end
      # rubocop:enable Style/MethodLength, Style/CyclomaticComplexity

      def process_variable_declaration(node)
        # restarg would have no name:
        #
        #   def initialize(*)
        #   end
        return if node.type == :restarg && node.children.empty?

        variable_name = node.children.first
        variable_table.declare_variable(variable_name, node)
      end

      def process_variable_assignment(node)
        name = node.children.first

        unless variable_table.variable_exist?(name)
          variable_table.declare_variable(name, node)
        end

        # Need to scan rhs before assignment so that we can mark previous
        # assignments as referenced if rhs has referencing to the variable
        # itself like:
        #
        #   foo = 1
        #   foo = foo + 1
        process_children(node)

        variable_table.assign_to_variable(name, node)

        skip_children!
      end

      def process_regexp_named_captures(node)
        regexp_node, rhs_node = *node

        regexp_string = regexp_node.children[0].children[0]
        regexp = Regexp.new(regexp_string)
        variable_names = regexp.named_captures.keys

        variable_names.each do |name|
          next if variable_table.variable_exist?(name)
          variable_table.declare_variable(name, node)
        end

        process_node(rhs_node)
        process_node(regexp_node)

        variable_names.each do |name|
          variable_table.assign_to_variable(name, node)
        end

        skip_children!
      end

      def process_variable_operator_assignment(node)
        if LOGICAL_OPERATOR_ASSIGNMENT_TYPES.include?(node.type)
          asgn_node, rhs_node = *node
        else
          asgn_node, _operator, rhs_node = *node
        end

        return unless asgn_node.type == :lvasgn

        name = asgn_node.children.first

        unless variable_table.variable_exist?(name)
          variable_table.declare_variable(name, asgn_node)
        end

        # The following statements:
        #
        #   foo = 1
        #   foo += foo = 2
        #   # => 3
        #
        # are equivalent to:
        #
        #   foo = 1
        #   foo = foo + (foo = 2)
        #   # => 3
        #
        # So, at operator assignment node, we need to reference the variable
        # before processing rhs nodes.

        variable_table.reference_variable(name, node)
        process_node(rhs_node)
        variable_table.assign_to_variable(name, asgn_node)

        skip_children!
      end

      def process_variable_multiple_assignment(node)
        lhs_node, rhs_node = *node
        process_node(rhs_node)
        process_node(lhs_node)
        skip_children!
      end

      def process_variable_referencing(node)
        name = node.children.first
        variable_table.reference_variable(name, node)
      end

      def process_loop(node)
        if POST_CONDITION_LOOP_TYPES.include?(node.type)
          # See the comment at the end of file for this behavior.
          condition_node, body_node = *node
          process_node(body_node)
          process_node(condition_node)
        else
          process_children(node)
        end

        mark_assignments_as_referenced_in_loop(node)

        skip_children!
      end

      def process_rescue(node)
        resbody_nodes = node.children.select do |child|
          next false unless child.is_a?(Parser::AST::Node)
          child.type == :resbody
        end

        contain_retry = resbody_nodes.any? do |resbody_node|
          scan(resbody_node) do |node_in_resbody|
            break true if node_in_resbody.type == :retry
          end
        end

        # Treat begin..rescue..end with retry as a loop.
        process_loop(node) if contain_retry
      end

      def process_zero_arity_super(node)
        variable_table.accessible_variables.each do |variable|
          next unless variable.method_argument?
          variable.reference!(node)
        end
      end

      def process_scope(node)
        if TWISTED_SCOPE_TYPES.include?(node.type)
          # See the comment at the end of file for this behavior.
          twisted_nodes = [node.children[0]]
          twisted_nodes << node.children[1] if node.type == :class
          twisted_nodes.compact!

          twisted_nodes.each do |twisted_node|
            process_node(twisted_node)
            scanned_nodes << twisted_node
          end
        end

        inspect_variables_in_scope(node)
        skip_children!
      end

      # Mark all assignments which are referenced in the same loop
      # as referenced by ignoring AST order since they would be referenced
      # in next iteration.
      def mark_assignments_as_referenced_in_loop(node)
        referenced_variable_names_in_loop, assignment_nodes_in_loop =
          find_variables_in_loop(node)

        referenced_variable_names_in_loop.each do |name|
          variable = variable_table.find_variable(name)
          # Non related references which are catched in the above scan
          # would be skipped here.
          next unless variable
          variable.assignments.each do |assignment|
            next if assignment_nodes_in_loop.none? do |assignment_node|
                      assignment_node.equal?(assignment.node)
                    end
            assignment.reference!
          end
        end
      end

      def find_variables_in_loop(loop_node)
        referenced_variable_names_in_loop = []
        assignment_nodes_in_loop = []

        # #scan does not consider scope,
        # but we don't need to care about it here.
        scan(loop_node) do |node|
          case node.type
          when :lvar
            referenced_variable_names_in_loop << node.children.first
          when *OPERATOR_ASSIGNMENT_TYPES
            asgn_node = node.children.first
            if asgn_node.type == :lvasgn
              referenced_variable_names_in_loop << asgn_node.children.first
            end
          when :lvasgn
            assignment_nodes_in_loop << node
          end
        end

        [referenced_variable_names_in_loop, assignment_nodes_in_loop]
      end

      # Simple recursive scan
      def scan(node, &block)
        node.children.each do |child|
          next unless child.is_a?(Parser::AST::Node)
          yield child
          scan(child, &block)
        end
        nil
      end

      # Use Node#equal? for accurate check.
      def scanned_node?(node)
        scanned_nodes.any? do |scanned_node|
          scanned_node.equal?(node)
        end
      end

      def scanned_nodes
        @scanned_nodes ||= []
      end

      # Hooks invoked by VariableTable.
      [
        :before_entering_scope,
        :after_entering_scope,
        :before_leaving_scope,
        :after_leaving_scope,
        :before_declaring_variable,
        :after_declaring_variable
      ].each do |hook|
        define_method(hook) do |arg|
          # Invoke hook in cops.
          run_hook(hook, arg, variable_table)
        end
      end

      # Post condition loops
      #
      # Loop body nodes need to be scanned first.
      #
      # Ruby:
      #   begin
      #     foo = 1
      #   end while foo > 10
      #   puts foo
      #
      # AST:
      #   (begin
      #     (while-post
      #       (send
      #         (lvar :foo) :>
      #         (int 10))
      #       (kwbegin
      #         (lvasgn :foo
      #           (int 1))))
      #     (send nil :puts
      #       (lvar :foo)))

      # Twisted scope types
      #
      # The variable foo belongs to the top level scope,
      # but in AST, it's under the block node.
      #
      # Ruby:
      #   some_method(foo = 1) do
      #   end
      #   puts foo
      #
      # AST:
      #   (begin
      #     (block
      #       (send nil :some_method
      #         (lvasgn :foo
      #           (int 1)))
      #       (args) nil)
      #     (send nil :puts
      #       (lvar :foo)))
      #
      # So the the method argument nodes need to be processed
      # in current scope.
      #
      # Same thing.
      #
      # Ruby:
      #   instance = Object.new
      #   class << instance
      #     foo = 1
      #   end
      #
      # AST:
      #   (begin
      #     (lvasgn :instance
      #       (send
      #         (const nil :Object) :new))
      #     (sclass
      #       (lvar :instance)
      #       (begin
      #         (lvasgn :foo
      #           (int 1))
    end
  end
end
