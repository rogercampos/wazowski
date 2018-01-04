$LOAD_PATH.unshift File.expand_path("../../lib", __FILE__)

require "wazowski"

require "minitest/autorun"
require 'dotenv/load'

# Cannot use in-memory db so that we can test thread safety features with a connection pool
ActiveRecord::Base.establish_connection(
  adapter: "postgresql",
  database: ENV['WAZOWSKI_PG_DATABASE'],
  username: ENV['WAZOWSKI_PG_USERNAME'],
  password: ENV['WAZOWSKI_PG_PASSWD']
)

ActiveRecord::Schema.define do
  create_table :comments, force: true do |table|
    table.column :post_id, :integer
    table.column :state, :string
    table.column :ignored, :string
  end

  create_table :posts, force: true do |table|
    table.column :title, :string
    table.column :valid_comments_count, :integer
  end

  create_table :pages, force: true do |table|
    table.column :title, :string
    table.column :body, :text
  end
end

class Comment < ActiveRecord::Base
end

class Post < ActiveRecord::Base
end

class Page < ActiveRecord::Base
end

class SubPage < Page
end

module StubReceiver
  extend self

  def data
    @data ||= {}
  end

  def clear!
    @data = {}
  end

  def method_missing(name, *args)
    data[name] ||= []
    data[name] << args
  end
end

class TestObserver < Wazowski::Observer
  def initialize
    @counter = 0
  end

  def increment_handler_counter!
    @counter += 1
  end

  observable(:valid_comments_count) do
    depends_on Comment, :post_id, :state
    depends_on Post, :none

    foo = proc do |obj, change_type, changes|
      increment_handler_counter!
      StubReceiver.trigger(obj, change_type, changes)
      StubReceiver.counter_status(@counter)
    end

    handler(Comment, &foo)
    handler(Post, &foo)
  end

  observable(:only_on_insert) do
    depends_on Post, :none
    handler(Post, only: :insert) do |obj, change_type, changes|
      StubReceiver.only_on_insert(obj, change_type, changes)
    end
  end

  observable(:pages_on_all_attributes) do
    depends_on Page, :any
    handler(Page) do |obj, change_type, changes|
      StubReceiver.trigger(obj, change_type, changes)
    end
  end

  observable(:page_subclass) do
    depends_on Page, :title
    handler(Page) do |obj, change_type, changes|
      StubReceiver.trigger_on_subclass(obj, change_type, changes)
    end
  end
end


class BaseTest < Minitest::Test
  # Separate tests from util methods
  def self.test(name, &block)
    test_name = "test_#{name.gsub(/\s+/, '_')}".to_sym
    defined = method_defined? test_name
    raise "#{test_name} is already defined in #{self}" if defined
    if block_given?
      define_method(test_name, &block)
    else
      define_method(test_name) do
        flunk "No implementation provided for #{name}"
      end
    end
  end

  def setup
    super

    StubReceiver.clear!

    Comment.delete_all
    Post.delete_all
    Page.delete_all
  end
end