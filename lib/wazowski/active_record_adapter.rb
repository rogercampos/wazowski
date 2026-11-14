# frozen_string_literal: true

module Wazowski
  module ActiveRecordAdapter
    # What one record changed in one transaction, for the nodes of one timing,
    # not yet handled.
    class PendingChanges
      def initialize(record)
        @record = record
        @updates = {} # attr => { old_value:, node_ids: }
        @presence = [] # [change_type, node_id], each once
      end

      def update(attr, node_id, old_value)
        update = (@updates[attr] ||= { old_value: nil, node_ids: Set.new })
        update[:old_value] = old_value if update[:old_value].nil?
        update[:node_ids] << node_id
      end

      def presence(change_type, node_id)
        @presence << [change_type, node_id] unless @presence.include?([change_type, node_id])
      end

      # node_id => [[change_type, class, record, changeset]]. A record inserted
      # or deleted reports only that, and one both inserted and deleted reports
      # nothing. The new values are read now, when the handlers are about to run.
      def per_node
        types = @presence.map(&:first)
        changes = {}

        unless types.include?(:insert) || types.include?(:delete)
          changesets = {}
          @updates.each do |attr, update|
            update[:node_ids].each do |node_id|
              (changesets[node_id] ||= {})[attr] = [update[:old_value], @record.send(attr)]
            end
          end

          changesets.each do |node_id, changeset|
            (changes[node_id] ||= []) << [:update, @record.class, @record, changeset]
          end
        end

        unless types.include?(:insert) && types.include?(:delete)
          @presence.each do |change_type, node_id|
            (changes[node_id] ||= []) << [change_type, @record.class, @record]
          end
        end

        changes
      end
    end

    module TransactionState
      # What has changed on one connection and not been handled yet, per timing
      # (see Node::TIMINGS): a change goes only to the timing of the node that
      # observes it. Each timing's handlers use up their own changes when they
      # run, so neither depends on the other having run. That matters because the
      # two do not run as a pair: work done from one transaction's after-commit
      # callbacks starts the next transaction on the same connection before that
      # first one's after-commit handlers may have run, and its changes still
      # have to reach the before-commit handlers.
      class StateData
        def initialize
          # Per record by identity: two instances of the same row are equal to
          # AR, but each one carries its own changes.
          @pending = Node::TIMINGS.to_h { |timing| [timing, {}.compare_by_identity] }
        end

        def record_update(record, node_id, attr, old_value)
          pending_for(record, node_id).update(attr, node_id, old_value)
        end

        def record_presence(record, node_id, change_type)
          pending_for(record, node_id).presence(change_type, node_id)
        end

        # Inside the transaction, once all of its changes are in. Every record
        # changed in it gets the callback; the first one runs the handlers and the
        # rest find nothing left to do. Changes a before-commit handler makes
        # itself are not fed back to before-commit handlers, only to after-commit
        # ones.
        def run_before_commit_only_once!
          run!(:before_commit)
          @pending[:before_commit].clear
        end

        def run_after_commit_only_once!
          run!(:after_commit)
        end

        # A record whose transaction rolled back: none of what it changed happened.
        # Rails runs the rollback callbacks on only one instance of each row, so
        # the other instances of the same row are forgotten with it.
        def forget(record)
          @pending.each_value do |pending|
            pending.delete_if { |other, _| other.equal?(record) || other == record }
          end
        end

        private

        def pending_for(record, node_id)
          @pending[Wazowski.find_node(node_id).timing][record] ||= PendingChanges.new(record)
        end

        def run!(timing)
          pending = @pending[timing]
          return if pending.empty?

          @pending[timing] = {}.compare_by_identity

          changes_per_node = {}
          pending.each_value do |changes|
            changes_per_node.merge!(changes.per_node) { |_, old_val, new_val| old_val + new_val }
          end

          Wazowski.run_handlers(changes_per_node)
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

      def self.of(record)
        record.class.with_connection { |connection| self.for(connection) }
      end
    end

    # What each model class observes itself, set up by register_node. Kept per
    # class, so that observing a subclass does not observe its parent too. Weak
    # keys, so that classes code reloading replaces take their tracking with them.
    module Tracking
      @own = ObjectSpace::WeakKeyMap.new

      class << self
        def track_on!(klass, attr, node_id)
          (own(klass)[:attrs][attr] ||= Set.new) << node_id
        end

        def track_base!(klass, node_id)
          own(klass)[:base] << node_id
        end

        def track_any!(klass, node_id)
          own(klass)[:any] << node_id
        end

        # attr => node_ids, for the nodes observing named attributes of klass.
        def attrs(klass)
          of(klass).each_with_object({}) do |tracking, attrs|
            tracking[:attrs].each { |attr, node_ids| (attrs[attr] ||= Set.new).merge(node_ids) }
          end
        end

        # The nodes observing any attribute of klass.
        def any(klass)
          of(klass).map { |tracking| tracking[:any] }.reduce(Set.new, :+)
        end

        # Every node observing klass.
        def all(klass)
          of(klass).reduce(Set.new) do |nodes, tracking|
            nodes + tracking[:attrs].values.reduce(Set.new, :+) + tracking[:base] + tracking[:any]
          end
        end

        private

        def own(klass)
          @own[klass] ||= { attrs: {}, base: Set.new, any: Set.new }
        end

        # What is observed on klass and on the classes it inherits from.
        def of(klass)
          trackings = []
          while klass && klass != ActiveRecord::Base
            tracking = @own[klass]
            trackings << tracking if tracking
            klass = klass.superclass
          end
          trackings
        end
      end
    end

    # The callbacks added to every observed model. They report each change to
    # the connection's TransactionState, which keeps it until its handlers run;
    # the model itself keeps nothing. Idempotent, like the rest of the callbacks:
    # a class gets them twice when it is observed and so is, later, a class it
    # inherits from.
    module WatchDog
      extend ActiveSupport::Concern

      included do
        before_update do
          state = TransactionState.of(self)

          Tracking.any(self.class).each do |node_id|
            changes.each do |attr, (old_value, _new_value)|
              state.record_update(self, node_id, attr.to_sym, old_value)
            end
          end

          Tracking.attrs(self.class).each do |attr, node_ids|
            if send("#{attr}_changed?")
              node_ids.each { |node_id| state.record_update(self, node_id, attr, send("#{attr}_was")) }
            end
          end
        end

        before_destroy do
          unless new_record?
            state = TransactionState.of(self)
            Tracking.all(self.class).each { |node_id| state.record_presence(self, node_id, :delete) }
          end
        end

        before_create do
          state = TransactionState.of(self)
          Tracking.all(self.class).each { |node_id| state.record_presence(self, node_id, :insert) }
        end

        ActiveRecordAdapter.before_commit_hook(self) do
          TransactionState.of(self).run_before_commit_only_once!
        end

        after_commit do
          TransactionState.of(self).run_after_commit_only_once!
        end

        after_rollback do
          TransactionState.of(self).forget(self)
        end
      end
    end

    # The one place Wazowski uses Active Record API that is not public: the
    # model-level `before_commit` callback, marked `# :nodoc:` in
    # active_record/transactions.rb. `run: :before_commit` handlers depend on
    # it, and Active Record has no public alternative (ActiveRecord::Transaction
    # offers only after_commit and after_rollback).
    #
    # What the before-commit handlers rely on, covered by
    # test/before_commit_test.rb: it fires inside the transaction, once the
    # transaction's changes are in, for every record changed in it, including
    # those saved in savepoints; and not at all when the transaction rolls back.
    #
    # Because Active Record may change it without notice, the gemspec caps
    # Active Record at the newest minor the test suite has run on. Raise the cap
    # only after `bin/ci` passes on the new version.
    def self.before_commit_hook(model, &block)
      unless model.respond_to?(:before_commit)
        raise NotImplementedError,
          "Active Record #{ActiveRecord.version} has no model-level before_commit callback, " \
          "which Wazowski's run: :before_commit handlers need"
      end

      model.before_commit(&block)
    end

    def self.register_node(node_id, observed_hierarchy)
      observed_hierarchy.each do |klass, attrs|
        klass.include(WatchDog) unless klass.include?(WatchDog)

        if attrs.size == 1 && attrs[0] == :none
          Tracking.track_base!(klass, node_id)
        elsif attrs.size == 1 && attrs[0] == :any
          Tracking.track_any!(klass, node_id)
        else
          attrs.each { |attr| Tracking.track_on!(klass, attr, node_id) }
        end
      end
    end
  end
end