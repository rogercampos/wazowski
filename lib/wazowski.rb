# frozen_string_literal: true

require "wazowski/version"
require 'active_support/concern'
require 'active_support/core_ext/module'
require 'active_record'

module Wazowski
  module ActiveRecordAdapter
    module WatchDog
      extend ActiveSupport::Concern

      included do
        cattr_accessor :__wazowski_tracked_attrs, :__wazowski_tracked_base, :__wazowski_tracked_any
        self.__wazowski_tracked_attrs = {}
        self.__wazowski_tracked_base = Set.new
        self.__wazowski_tracked_any = Set.new

        before_update(append: true) do
          self.class.__wazowski_tracked_any.each do |node_id|
            __wazowski_presence_state.push([:update, node_id])
            TransactionState.current_state.register_model_changed(self)
          end

          self.class.__wazowski_tracked_attrs.each do |attr, node_ids|
            if send("#{attr}_changed?")
              node_ids.each { |node_id| __wazowski_store_dirty!(attr, node_id, :update, send("#{attr}_was")) }
            end
          end
        end

        before_destroy do
          self.class.__wazowski_all_nodes.each do |node_id|
            __wazowski_presence_state.push([:delete, node_id])
            TransactionState.current_state.register_model_changed(self)
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
              case type
                when :insert
                  info[node_id] ||= []
                  info[node_id] << [:insert, self.class, self]
                when :delete
                  info[node_id] ||= []
                  info[node_id] << [:delete, self.class, self]
                when :update
                  info[node_id] ||= []
                  info[node_id] << [:update, self.class, self, {}]
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

          (nodes_by_attribute.any? ? nodes_by_attribute.sum : Set.new) +
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

    module TransactionState
      class StateData
        attr_reader :changed_models

        def initialize
          @changed_models = Set.new
        end

        def run_after_commit_only_once!
          return if @changed_models.empty?

          Wazowski.run_handlers

          clear_after_commit_performed!
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

    def self.for_changes_per_node
      info = {}

      TransactionState.current_state.changed_models.each do |model|
        info.merge!(model.__wazowski_changes_per_node)
      end

      info.each do |node_id, changes|
        yield(node_id, changes)
      end
    end

  end

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

