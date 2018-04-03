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

  create_table :ships, force: true do |table|
    table.column :name, :string
    table.column :value, :integer
    table.column :planet_id, :integer
    table.column :label, :string
    table.column :engine, :string
    table.column :brand, :string
  end

  create_table :planets, force: true do |t|
    t.column :name, :string
    t.column :size, :integer
    t.column :a1, :string
    t.column :a2, :string
    t.column :a3, :string
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

class Ship < ActiveRecord::Base
  belongs_to :planet
end

class Planet < ActiveRecord::Base
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

class PlanetsObserver < Wazowski::Observer
  def update!(planet)
    planet.update_attributes! size: rand(1000)
  end

  observable(:no_loop) do
    depends_on Ship, :name
    depends_on Planet, :name

    handler(Ship, only: :update) do |ship|
      update!(ship.planet)
    end

    handler(Planet, only: :update) do |planet|
      update!(planet)
    end
  end

  observable(:infinite_loop_on_ship) do
    depends_on Ship, :label
    handler(Ship, only: :update) do |ship|
      ship.update_attributes! label: SecureRandom.hex
    end
  end

  observable(:update_with_no_infinite_loop) do
    depends_on Ship, :engine
    handler(Ship, only: :update) do |ship|
      ship.update_attributes! brand: "Foo"
    end
  end

  observable(:nested_observers_a1) do
    depends_on Planet, :a1
    handler(Planet, only: :update) do |planet|
      planet.update_attributes! a2: "second step"
    end
  end

  observable(:nested_observers_a2) do
    depends_on Planet, :a2
    handler(Planet, only: :update) do |planet|
      planet.update_attributes! a3: "third step"
    end
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