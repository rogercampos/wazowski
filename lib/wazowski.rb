# frozen_string_literal: true

require 'active_support/concern'
require 'active_support/core_ext/module'
require 'active_record'

require "wazowski/version"
require 'wazowski/active_record_adapter'

module Wazowski
  NoSuchNode = Class.new(StandardError)
  ConfigurationError = Class.new(StandardError)

  module Observable
    extend ActiveSupport::Concern

    class_methods do
      # `run:` is when the handlers run: :after_commit (the default), once the
      # transaction has committed, or :before_commit, inside it, just before it
      # commits. Use :before_commit for derived data that has to be written in
      # the same transaction as the change it derives from, so that nobody can
      # read the change without it.
      def observable(name, run: :after_commit, &block)
        id = "#{self.name || object_id}/#{name}"

        node = Node.new(id, self, block, run: run)
        Config.derivations[id] = node

        ActiveRecordAdapter.register_node(id, node.dependants)
      end
    end
  end

  class Observer
    include Observable
  end

  module Config
    mattr_accessor :derivations
    self.derivations = {}
  end

  class Node
    TIMINGS = %i[after_commit before_commit].freeze
    EVENTS = %i[insert update delete].freeze

    attr_reader :name, :timing

    def initialize(name, klass, block, run: :after_commit)
      raise ConfigurationError, "run: must be one of #{TIMINGS.inspect}" unless TIMINGS.include?(run)

      @name = name
      @observer_klass = klass
      @timing = run
      @depends_on = {}
      @handlers = {}
      instance_eval(&block)
      validate!
    end

    def depends_on(klass, *attrs)
      if attrs.empty?
        raise ConfigurationError, 'Must depend on some attributes. You can also use `:none` and `:any`'
      end

      attrs = (@depends_on[klass] ||= []).concat(attrs)

      if attrs.size > 1 && attrs.intersect?(%i[none any])
        raise ConfigurationError, "`:none` and `:any` cannot be combined with other attributes of #{klass}"
      end
    end

    def handler(klass, only: nil, &block)
      raise ConfigurationError, "Already defined handler for #{klass}" if @handlers[klass]
      raise ConfigurationError, "The handler for #{klass} needs a block" unless block

      events = only.nil? ? EVENTS : Array(only)
      if events.empty? || !(events - EVENTS).empty?
        raise ConfigurationError, "only: must be one or more of #{EVENTS.inspect}, got #{only.inspect}"
      end

      @handlers[klass] = { block: block, only: events }
    end

    def dependants
      @depends_on
    end

    def inspect
      "<Wazowski::Node #{@name}>"
    end

    # The handler for klass or, failing that, for the closest class it inherits from.
    def lookup_handler(klass)
      handler_klass = klass
      handler_klass = handler_klass.superclass until handler_klass.nil? || @handlers.key?(handler_klass)

      if handler_klass.nil?
        raise(ConfigurationError, "Cannot run handler for klass #{klass}, it has been never "\
                                  'registered! Check your definitions.')
      end

      @handlers[handler_klass]
    end

    # Runs the handlers over the changes of one transaction, all with the same
    # new instance of the observer class as context. The context is local to
    # the call: the node is shared by every thread.
    def run(changes)
      context = @observer_klass.new

      changes.each do |change_type, klass, object, changeset|
        handler = lookup_handler(klass)
        next unless handler[:only].include?(change_type)

        context.instance_exec(object, change_type, changeset || {}, &handler[:block])
      end
    end

    private

    # Mistakes in the definition would otherwise only show up later, once some
    # transaction commits.
    def validate!
      raise ConfigurationError, "#{@name} must depend on something, use `depends_on`" if @depends_on.empty?

      @depends_on.each_key { |klass| lookup_handler(klass) }

      @handlers.each_key do |klass|
        next if @depends_on.each_key.any? { |dependant| dependant <= klass }

        raise ConfigurationError, "#{@name} has a handler for #{klass} but does not depend on it"
      end
    end
  end

  class << self
    def find_node(node_id)
      Config.derivations[node_id] || raise(NoSuchNode, "Node not found! #{node_id}")
    end

    # Runs the handlers of the nodes with the given timing (see Node::TIMINGS)
    # over the changes accumulated for them in one transaction.
    def run_handlers(changes_per_node, timing: :after_commit)
      changes_per_node.each do |node_id, changes|
        node = find_node(node_id)
        next unless node.timing == timing

        node.run(changes)
      end
    end
  end
end

