$LOAD_PATH.unshift File.expand_path("../../lib", __FILE__)

require "wazowski"

require "minitest/autorun"
require 'dotenv/load'

# Cannot use in-memory db so that we can test thread safety features with a connection pool
ActiveRecord::Base.establish_connection(
  adapter: "postgresql",
  database: ENV['WAZOWSKI_PG_DATABASE'],
  username: ENV['WAZOWSKI_PG_USERNAME'],
  password: ENV['WAZOWSKI_PG_PASSWD'],
  host: ENV['WAZOWSKI_PG_HOST'],
  port: ENV['WAZOWSKI_PG_PORT']
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

  create_table :tallies, force: true do |t|
    t.column :total, :integer, default: 0
  end

  create_table :entries, force: true do |t|
    t.column :amount, :integer
  end

  create_table :invoices, force: true do |t|
    t.column :number, :string
  end

  create_table :planets, force: true do |t|
    t.column :name, :string
    t.column :size, :integer
    t.column :a1, :string
    t.column :a2, :string
    t.column :a3, :string
    t.column :count_on_nested_observers_a1_callings, :integer, default: 0
  end

  create_table :vehicles, force: true do |t|
    t.column :type, :string
    t.column :name, :string
  end

  create_table :boats, force: true do |t|
    t.column :type, :string
    t.column :name, :string
  end

  create_table :tasks, force: true do |t|
    t.column :name, :string
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

class Vehicle < ActiveRecord::Base
end

class Car < Vehicle
end

class Boat < ActiveRecord::Base
end

class Yacht < Boat
end

class Task < ActiveRecord::Base
end

# Its own connection pool, as a model on another database would have.
class SecondaryRecord < ActiveRecord::Base
  self.abstract_class = true
  establish_connection ActiveRecord::Base.connection_db_config.configuration_hash
end

class SecondaryComment < SecondaryRecord
  self.table_name = "comments"
end

class Tally < ActiveRecord::Base
end

class Entry < ActiveRecord::Base
end

# Writes an entry from its own after-commit callback, as any model with
# after-commit work might.
class Invoice < ActiveRecord::Base
  after_commit { Entry.create!(amount: 7) }
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
    planet.update! size: rand(1000)
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
      ship.update! label: SecureRandom.hex
    end
  end

  observable(:update_with_no_infinite_loop) do
    depends_on Ship, :engine
    handler(Ship, only: :update) do |ship|
      ship.update! brand: "Foo"
    end
  end

  observable(:nested_observers_a1) do
    depends_on Planet, :a1
    handler(Planet, only: :update) do |planet|
      planet.update! a2: "second step"
      planet.increment!(:count_on_nested_observers_a1_callings)
    end
  end

  observable(:nested_observers_a2) do
    depends_on Planet, :a2
    handler(Planet, only: :update) do |planet|
      planet.update! a3: "third step"
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

  observable(:secondary_comments) do
    depends_on SecondaryComment, :state
    handler(SecondaryComment) do |obj, change_type, changes|
      StubReceiver.trigger_on_secondary(obj, change_type, changes)
    end
  end
end

# A parent class observed before its subclass, and a subclass observed before
# its parent.
class InheritanceObserver < Wazowski::Observer
  observable(:vehicles) do
    depends_on Vehicle, :name
    handler(Vehicle) { |obj, change_type, changes| StubReceiver.vehicle(obj, change_type, changes) }
  end

  observable(:cars) do
    depends_on Car, :name
    handler(Car) { |obj, change_type, changes| StubReceiver.car(obj, change_type, changes) }
  end

  observable(:yachts) do
    depends_on Yacht, :name
    handler(Yacht) { |obj, change_type, changes| StubReceiver.yacht(obj, change_type, changes) }
  end

  observable(:boats) do
    depends_on Boat, :name
    handler(Boat) { |obj, change_type, changes| StubReceiver.boat(obj, change_type, changes) }
  end
end

# Records which observer instance ran each handler. A thread can set
# :wazowski_test_pause to stop inside a handler.
class ContextIsolationObserver < Wazowski::Observer
  observable(:tasks) do
    depends_on Task, :none
    handler(Task) do |task|
      StubReceiver.context(task.name, object_id)
      Thread.current[:wazowski_test_pause]&.call
    end
  end
end


# Derived data kept in the same transaction as what it derives from.
class TallyObserver < Wazowski::Observer
  observable(:total, run: :before_commit) do
    depends_on Entry, :amount

    handler(Entry) do |entry, change_type, changes|
      StubReceiver.before_commit(entry, change_type, changes, Entry.connection.transaction_open?)

      delta = case change_type
              when :insert then entry.amount
              when :delete then -entry.amount
              when :update then changes[:amount][1] - changes[:amount][0]
              end
      Tally.where(id: Tally.first!.id).update_all(["total = total + ?", delta])
    end
  end

  observable(:after_total) do
    depends_on Entry, :amount

    handler(Entry) do |entry, change_type, _changes|
      StubReceiver.after_commit(entry, change_type, Entry.connection.transaction_open?)
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
    Entry.delete_all
    Invoice.delete_all
    Tally.delete_all
    Vehicle.delete_all
    Boat.delete_all
    Task.delete_all
  end
end