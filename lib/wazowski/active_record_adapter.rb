# frozen_string_literal: true

module Wazowski
  module ActiveRecordAdapter
    module TransactionState
      # What has changed on one connection and not been handled yet, kept twice:
      # once for each timing (see Node::TIMINGS). Each timing's handlers use up
      # their own copy when they run, so neither depends on the other having run.
      # That matters because the two do not run as a pair: work done from one
      # transaction's after-commit callbacks starts the next transaction on the
      # same connection before that first one's after-commit handlers may have
      # run, and its changes still have to reach the before-commit handlers.
      class StateData
        TRACKS = %i[after_commit before_commit].freeze

        def initialize
          # By identity: two instances of the same row are equal to AR, but each
          # one carries its own changes.
          @changed_models = TRACKS.to_h { |track| [track, Set.new.compare_by_identity] }
        end

        # Inside the transaction, once all of its changes are in. Every record
        # changed in it gets the callback; the first one runs the handlers and the
        # rest find nothing left to do. Changes a before-commit handler makes
        # itself are not fed back to before-commit handlers, only to after-commit
        # ones.
        def run_before_commit_only_once!
          run!(:before_commit)
          discard!(:before_commit)
        end

        def run_after_commit_only_once!
          run!(:after_commit)
        end

        def register_model_changed(model)
          @changed_models.each_value { |models| models << model }
        end

        # A record whose transaction rolled back: none of what it changed happened.
        # Rails runs the rollback callbacks on only one instance of each row, so
        # the other instances of the same row are forgotten with it.
        def forget(model)
          @changed_models.each_value do |models|
            models.select { |other| other.equal?(model) || other == model }.each do |other|
              models.delete(other)
              TRACKS.each { |track| other.__wazowski_reset_track!(track) }
            end
          end
          TRACKS.each { |track| model.__wazowski_reset_track!(track) }
        end

        private

        def run!(track)
          models = @changed_models[track].to_a
          return if models.empty?

          @changed_models[track].clear

          info = {}
          models.each do |model|
            info.merge!(model.__wazowski_changes_per_node(track)) do |_, old_val, new_val|
              old_val + new_val
            end
            model.__wazowski_reset_track!(track)
          end

          Wazowski.run_handlers(info, timing: track)
        end

        def discard!(track)
          @changed_models[track].each { |model| model.__wazowski_reset_track!(track) }
          @changed_models[track].clear
        end
      end

      # One per connection: a transaction lives on one connection, and a model
      # on another database commits on its own. Weak keys, so that connections
      # the pool lets go of take their state with them. The lock is for two
      # threads registering their connections at once.
      @states = ObjectSpace::WeakKeyMap.new
      @lock = Mutex.new

      def self.for(connection)
        @lock.synchronize { @states[connection] ||= StateData.new }
      end
    end

    module WatchDog
      extend ActiveSupport::Concern

      included do
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
          unless new_record?
            self.class.__wazowski_all_nodes.each do |node_id|
              __wazowski_store_presence!(:delete, node_id)
            end
          end
        end

        before_create do
          self.class.__wazowski_all_nodes.each do |node_id|
            __wazowski_store_presence!(:insert, node_id)
          end
        end

        before_commit do
          __wazowski_transaction_state.run_before_commit_only_once!
        end

        after_commit do
          __wazowski_transaction_state.run_after_commit_only_once!
        end

        after_rollback do
          __wazowski_transaction_state.forget(self)
        end

        def __wazowski_store_dirty!(attr, node_id, change_type, attr_was = nil)
          TransactionState::StateData::TRACKS.each do |track|
            dirty = __wazowski_dirty_state(track)
            dirty[attr] ||= {}
            dirty[attr][:change_type] = change_type
            dirty[attr][:dirty] = attr_was if dirty[attr][:dirty].nil?
            dirty[attr][:node_ids] ||= Set.new
            dirty[attr][:node_ids] << node_id
          end

          __wazowski_transaction_state.register_model_changed(self)
        end

        # Idempotent, like the rest of the callbacks: a class gets them twice when
        # it is observed and so is, later, a class it inherits from.
        def __wazowski_store_presence!(change_type, node_id)
          TransactionState::StateData::TRACKS.each do |track|
            presence = __wazowski_presence_state(track)
            presence.push([change_type, node_id]) unless presence.include?([change_type, node_id])
          end

          __wazowski_transaction_state.register_model_changed(self)
        end

        def __wazowski_changes_per_node(track = :after_commit)
          info = {}

          states = __wazowski_presence_state(track).map(&:first)

          unless states.include?(:insert) || states.include?(:delete)
            changes_by_node = {}

            __wazowski_dirty_state(track).each do |attr, data|
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
            __wazowski_presence_state(track).each do |type, node_id|
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

        def __wazowski_transaction_state
          self.class.with_connection { |connection| TransactionState.for(connection) }
        end

        def __wazowski_reset_track!(track)
          __wazowski_dirty_state(track).clear
          __wazowski_presence_state(track).clear
        end

        def __wazowski_dirty_state(track = :after_commit)
          (@__wazowski_dirty_state ||= {})[track] ||= {}
        end

        def __wazowski_presence_state(track = :after_commit)
          (@__wazowski_presence_state ||= {})[track] ||= []
        end
      end

      class_methods do
        def __wazowski_track_on!(attr, node_id)
          (__wazowski_own_tracking[:attrs][attr] ||= Set.new) << node_id
        end

        def __wazowski_track_base!(node_id)
          __wazowski_own_tracking[:base] << node_id
        end

        def __wazowski_track_any!(node_id)
          __wazowski_own_tracking[:any] << node_id
        end

        def __wazowski_tracked_attrs
          __wazowski_trackings.each_with_object({}) do |tracking, attrs|
            tracking[:attrs].each { |attr, node_ids| (attrs[attr] ||= Set.new).merge(node_ids) }
          end
        end

        def __wazowski_tracked_any
          __wazowski_trackings.map { |tracking| tracking[:any] }.reduce(Set.new, :+)
        end

        def __wazowski_all_nodes
          __wazowski_trackings.reduce(Set.new) do |nodes, tracking|
            nodes + tracking[:attrs].values.reduce(Set.new, :+) + tracking[:base] + tracking[:any]
          end
        end

        # What is observed on this class itself. Kept per class, so that observing
        # a subclass does not observe its parent too.
        def __wazowski_own_tracking
          @__wazowski_own_tracking ||= { attrs: {}, base: Set.new, any: Set.new }
        end

        # What is observed on this class and on the classes it inherits from.
        def __wazowski_trackings
          trackings = []
          klass = self
          while klass && klass != ActiveRecord::Base
            tracking = klass.instance_variable_get(:@__wazowski_own_tracking)
            trackings << tracking if tracking
            klass = klass.superclass
          end
          trackings
        end
      end
    end

    def self.register_node(node_id, observed_hierarchy)
      observed_hierarchy.each do |klass, attrs|
        klass.include(WatchDog) unless klass.include?(WatchDog)

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