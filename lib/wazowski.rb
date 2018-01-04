# frozen_string_literal: true

require 'active_support/concern'
require 'active_support/core_ext/module'
require 'active_record'

require "wazowski/version"
require 'wazowski/active_record_adapter'

module Wazowski
  NoSuchNode = Class.new(StandardError)
  ConfigurationError = Class.new(StandardError)

  module Config
    mattr_accessor :derivations
    self.derivations = {}
  end

  class Node
    attr_reader :name

    def initialize(name, block)
      @name = name
      instance_eval(&block)
    end

    def depends_on(klass, *attrs)
      if attrs.empty?
        raise ConfigurationError, 'Must depend on some attributes. You can also use `:none` and `:any`'
      end

      @depends_on ||= {}
      @depends_on[klass] ||= []
      @depends_on[klass] += attrs
    end

    def handler(klass, opts = {}, &block)
      @handlers ||= {}
      raise ConfigurationError, "Already defined handler for #{klass}" if @handlers[klass]

      @handlers[klass] = { block: block, opts: opts }
    end

    def dependants
      @depends_on
    end

    def inspect
      "<Wazowski::Node #{@name}>"
    end

    def lookup_handler(klass)
      handler = if @handlers[klass]
                  @handlers[klass]
                else
                  lookup_handler(klass.superclass) unless klass.superclass == Object
                end

      if handler.nil?
        raise(ConfigurationError, "Cannot run handler for klass #{klass}, it has been never "\
                                  'registered! Check your definitions.')
      end

      handler
    end

    def wrapping(&block)
      @wrapping_block = block
    end

    def with_wrapping(&block)
      if @wrapping_block
        @wrapping_block.call(block)
      else
        yield
      end
    end

    def after_commit_on_update(klass, object, dirty_changes)
      handler = lookup_handler(klass)

      return unless handler[:opts][:only].nil? || [handler[:opts][:only]].flatten.include?(:update)
      handler[:block].call(object, :update, dirty_changes)
    end

    def after_commit_on_delete(klass, object)
      handler = lookup_handler(klass)

      return unless handler[:opts][:only].nil? || [handler[:opts][:only]].flatten.include?(:delete)
      handler[:block].call(object, :delete, {})
    end

    def after_commit_on_create(klass, object)
      handler = lookup_handler(klass)

      return unless handler[:opts][:only].nil? || [handler[:opts][:only]].flatten.include?(:insert)
      handler[:block].call(object, :insert, {})
    end
  end

  extend ActiveSupport::Concern

  class_methods do
    def observable(name, &block)
      id = "#{self.name || object_id}/#{name}"

      if Config.derivations.key?(id)
        raise(ConfigurationError, "Already defined #{name} derivation for module #{self.name}")
      end

      node = Node.new(id, block)
      Config.derivations[id] = node

      ActiveRecordAdapter.register_node(id, node.dependants)
    end
  end

  class << self
    def find_node(node_id)
      Config.derivations[node_id] || raise(NoSuchNode, "Node not found! #{node_id}")
    end

    def run_handlers
      ActiveRecordAdapter.for_changes_per_node do |node_id, changes|
        node = find_node(node_id)

        node.with_wrapping do
          changes.each do |change_type, klass, object, changeset|
            case change_type
              when :insert
                node.after_commit_on_create(klass, object)
              when :delete
                node.after_commit_on_delete(klass, object)
              when :update
                node.after_commit_on_update(klass, object, changeset)
            end
          end
        end
      end
    end
  end
end

