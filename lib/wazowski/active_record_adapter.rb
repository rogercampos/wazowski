# frozen_string_literal: true

module Wazowski
  module ActiveRecordAdapter
    # What one record changed and is not handled yet, for the nodes of one
    # timing. Each change remembers the transaction (or savepoint) it was made
    # in, so that rolling one back forgets only what was made in it.
    class PendingChanges
      def initialize(record)
        @record = record
        @updates = {} # attr => [{ transaction:, old_value:, node_ids: }], one per transaction, oldest first
        @presence = [] # [transaction, change_type, node_id], each once
      end

      def update(transaction, attr, node_id, old_value)
        steps = (@updates[attr] ||= [])
        # A later save in the same transaction keeps the old value of its first
        # save, whatever it is (nil included).
        step = steps.find { |s| s[:transaction].equal?(transaction) }
        steps << (step = { transaction: transaction, old_value: old_value, node_ids: Set.new }) unless step
        step[:node_ids] << node_id
      end

      def presence(transaction, change_type, node_id)
        entry = [transaction, change_type, node_id]
        @presence << entry unless @presence.include?(entry)
      end

      # Forgets what was changed in a transaction that rolled back. True when
      # nothing is left.
      def discard(transaction)
        @updates.each_value { |steps| steps.reject! { |step| step[:transaction].equal?(transaction) } }
        @updates.reject! { |_, steps| steps.empty? }
        @presence.reject! { |t, *| t.equal?(transaction) }
        @updates.empty? && @presence.empty?
      end

      # node_id => [[change_type, class, record, changeset]]. A record inserted
      # or deleted reports only that, and one both inserted and deleted reports
      # nothing. An update's old value is the one before the oldest change left;
      # the new values are read now, when the handlers are about to run.
      def per_node
        presence = @presence.map { |_, change_type, node_id| [change_type, node_id] }.uniq
        types = presence.map(&:first)
        changes = {}

        unless types.include?(:insert) || types.include?(:delete)
          changesets = {}
          @updates.each do |attr, steps|
            change = [steps.first[:old_value], @record.send(attr)]
            steps.map { |step| step[:node_ids] }.reduce(:|).each do |node_id|
              (changesets[node_id] ||= {})[attr] = change
            end
          end

          changesets.each do |node_id, changeset|
            (changes[node_id] ||= []) << [:update, @record.class, @record, changeset]
          end
        end

        unless types.include?(:insert) && types.include?(:delete)
          presence.each do |change_type, node_id|
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
      #
      # A rollback is followed through Active Record's public
      # ActiveRecord::Transaction#after_rollback, registered on each transaction
      # or savepoint the first time something changes in it. Rails moves the
      # callback of a released savepoint to its parent, so it fires if any
      # transaction around the change rolls back, and only then.
      class StateData
        def initialize
          @pending = {}
          @transactions = {}
          Node::TIMINGS.each { |timing| reset(timing) }
        end

        def record_update(record, transaction, node_id, attr, old_value)
          pending_for(record, transaction, node_id).update(transaction, attr, node_id, old_value)
        end

        def record_presence(record, transaction, node_id, change_type)
          pending_for(record, transaction, node_id).presence(transaction, change_type, node_id)
        end

        # Inside the transaction, once all of its changes are in. Every record
        # changed in it gets the callback; the first one runs the handlers and the
        # rest find nothing left to do. Changes a before-commit handler makes
        # itself are not fed back to before-commit handlers, only to after-commit
        # ones.
        def run_before_commit_only_once!
          run!(:before_commit)
          reset(:before_commit)
        end

        def run_after_commit_only_once!
          run!(:after_commit)
        end

        private

        def reset(timing)
          # Per record by identity: two instances of the same row are equal to
          # AR, but each one carries its own changes.
          @pending[timing] = {}.compare_by_identity
          # transaction => the records changed in it, as keys.
          @transactions[timing] = {}.compare_by_identity
        end

        def pending_for(record, transaction, node_id)
          timing = Registry.find(node_id).timing

          records = (@transactions[timing][transaction] ||= begin
            transaction.after_rollback { discard(timing, transaction) }
            {}.compare_by_identity
          end)
          records[record] = true

          @pending[timing][record] ||= PendingChanges.new(record)
        end

        # A transaction or savepoint rolled back: none of what was changed in it
        # happened. What the rest of the transaction changed stays.
        def discard(timing, transaction)
          records = @transactions[timing].delete(transaction) or return
          pending = @pending[timing]
          records.each_key { |record| pending.delete(record) if pending[record]&.discard(transaction) }
        end

        def run!(timing)
          pending = @pending[timing]
          return if pending.empty?

          reset(timing)

          changes_per_node = {}
          pending.each_value do |changes|
            changes.per_node.each do |node_id, node_changes|
              (changes_per_node[node_id] ||= []).concat(node_changes)
            end
          end

          changes_per_node.each { |node_id, changes| Registry.find(node_id).run(changes) }
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
          transaction = self.class.current_transaction

          Tracking.any(self.class).each do |node_id|
            changes.each do |attr, (old_value, _new_value)|
              state.record_update(self, transaction, node_id, attr.to_sym, old_value)
            end
          end

          Tracking.attrs(self.class).each do |attr, node_ids|
            if send("#{attr}_changed?")
              node_ids.each { |node_id| state.record_update(self, transaction, node_id, attr, send("#{attr}_was")) }
            end
          end
        end

        before_destroy do
          unless new_record?
            state = TransactionState.of(self)
            transaction = self.class.current_transaction
            Tracking.all(self.class).each { |node_id| state.record_presence(self, transaction, node_id, :delete) }
          end
        end

        before_create do
          state = TransactionState.of(self)
          transaction = self.class.current_transaction
          Tracking.all(self.class).each { |node_id| state.record_presence(self, transaction, node_id, :insert) }
        end

        ActiveRecordAdapter.before_commit_hook(self) do
          TransactionState.of(self).run_before_commit_only_once!
        end

        after_commit do
          TransactionState.of(self).run_after_commit_only_once!
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