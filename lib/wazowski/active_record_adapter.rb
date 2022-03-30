module Wazowski
  module ActiveRecordAdapter
    module TransactionState
      class StateData
        def initialize
          @changed_models = Set.new
        end

        def run_after_commit_only_once!
          return if @changed_models.empty?

          info = {}

          # even @changed_models being a Set, it's possible that the "same" model
          # have been included in the set before and after persistence (so they're different,
          # we have both in the set) and by the time this code runs, the non persisted model
          # becomes persisted and now they're identical, but still in the set.
          # So we may have duplicates. `.to_a.uniq` to remove them.
          @changed_models.to_a.uniq.each do |model|
            info.merge!(model.__wazowski_changes_per_node) do |_, old_val, new_val|
              old_val + new_val
            end
          end

          clear_after_commit_performed!

          Wazowski.run_handlers(info)
        end

        def clear_after_commit_performed!
          @changed_models.clear
        end

        def register_model_changed(model)
          @changed_models << model
        end
      end

      mattr_accessor :states
      self.states = {}

      def self.current_state
        states[ActiveRecord::Base.connection.hash] ||= StateData.new
      end
    end

    module WatchDog
      extend ActiveSupport::Concern

      included do
        cattr_accessor :__wazowski_tracked_attrs, :__wazowski_tracked_base, :__wazowski_tracked_any
        self.__wazowski_tracked_attrs = {}
        self.__wazowski_tracked_base = Set.new
        self.__wazowski_tracked_any = Set.new

        before_update do
          self.class.__wazowski_tracked_any.each do |node_id|
            changes.each do |attr, (old_value, _new_value)|
              __wazowski_store_dirty!(attr.to_sym, node_id, :update, old_value)
            end
          end

          self.class.__wazowski_tracked_attrs.each do |attr, node_ids|
            if send("#{attr}_changed?")
              node_ids.each { |node_id| __wazowski_store_dirty!(attr, node_id, :update, send("#{attr}_was")) }
            end
          end
        end

        before_destroy do
          unless self.new_record?
            self.class.__wazowski_all_nodes.each do |node_id|
              __wazowski_presence_state.push([:delete, node_id])
              TransactionState.current_state.register_model_changed(self)
            end
          end
        end

        before_create do
          self.class.__wazowski_all_nodes.each do |node_id|
            __wazowski_presence_state.push([:insert, node_id])
            TransactionState.current_state.register_model_changed(self)
          end
        end

        after_commit do
          TransactionState.current_state.run_after_commit_only_once!

          __wazowski_clean_dirty!
          __wazowski_presence_state.clear
        end

        after_rollback do
          __wazowski_clean_dirty!
          __wazowski_presence_state.clear

          TransactionState.current_state.clear_after_commit_performed!
        end

        def __wazowski_store_dirty!(attr, node_id, change_type, attr_was = nil)
          __wazowski_dirty_state[attr] ||= {}
          __wazowski_dirty_state[attr][:change_type] = change_type
          __wazowski_dirty_state[attr][:dirty] = attr_was if __wazowski_dirty_state[attr][:dirty].nil?
          __wazowski_dirty_state[attr][:node_ids] ||= Set.new
          __wazowski_dirty_state[attr][:node_ids] << node_id

          TransactionState.current_state.register_model_changed(self)
        end

        def __wazowski_changes_per_node
          info = {}

          states = __wazowski_presence_state.map(&:first)

          unless states.include?(:insert) || states.include?(:delete)
            changes_by_node = {}

            __wazowski_dirty_state.each do |attr, data|
              node_ids = data[:node_ids]
              new_data = data.except(:node_ids).merge(attr: attr)

              node_ids.each do |node_id|
                changes_by_node[node_id] ||= []
                changes_by_node[node_id] << new_data
              end
            end

            changes_by_node.each do |node_id, datas|
              list_of_changes = datas.map { |x| [x[:attr], [x[:dirty], send(x[:attr])]] }.to_h

              info[node_id] ||= []
              info[node_id] << [:update, self.class, self, list_of_changes]
            end
          end

          unless states.include?(:insert) && states.include?(:delete)
            __wazowski_presence_state.each do |type, node_id|
              info[node_id] ||= []

              case type
                when :insert
                  info[node_id] << [:insert, self.class, self]
                when :delete
                  info[node_id] << [:delete, self.class, self]
              end
            end
          end

          info
        end

        def __wazowski_clean_dirty!
          @__wazowski_dirty_state = {}
        end

        def __wazowski_dirty_state
          @__wazowski_dirty_state ||= {}
        end

        def __wazowski_presence_state
          @__wazowski_presence_state ||= []
        end
      end

      class_methods do
        def __wazowski_track_on!(attr, node_id)
          __wazowski_tracked_attrs[attr] ||= Set.new
          __wazowski_tracked_attrs[attr] << node_id
        end

        def __wazowski_track_base!(node_id)
          __wazowski_tracked_base << node_id
        end

        def __wazowski_track_any!(node_id)
          __wazowski_tracked_any << node_id
        end

        def __wazowski_all_nodes
          nodes_by_attribute = __wazowski_tracked_attrs.values

          (nodes_by_attribute.any? ? nodes_by_attribute.reduce(:+) : Set.new) +
            __wazowski_tracked_base +
            __wazowski_tracked_any
        end
      end
    end

    def self.register_node(node_id, observed_hierarchy)
      observed_hierarchy.each do |klass, attrs|
        klass.send(:include, WatchDog) unless klass.included_modules.include?(WatchDog)

        if attrs.size == 1 && attrs[0] == :none
          klass.__wazowski_track_base!(node_id)
        elsif attrs.size == 1 && attrs[0] == :any
          klass.__wazowski_track_any!(node_id)
        else
          attrs.each do |attr|
            klass.__wazowski_track_on!(attr, node_id)
          end
        end
      end
    end
  end
end