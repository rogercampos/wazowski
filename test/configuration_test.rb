require "test_helper"

class ConfigurationTest < BaseTest
  def define(&block)
    Class.new(Wazowski::Observer) { observable(:config_test, &block) }
  end

  def assert_configuration_error(message, &block)
    error = assert_raises(Wazowski::ConfigurationError) { define(&block) }
    assert_match message, error.message
  end

  test "a dependency without a handler is an error" do
    assert_configuration_error(/has no handler|never registered/) { depends_on Task, :name }
  end

  test "a handler without a dependency is an error" do
    assert_configuration_error(/does not depend on it/) do
      depends_on Task, :name
      handler(Task) {}
      handler(Comment) {}
    end
  end

  test "an observable that depends on nothing is an error" do
    assert_configuration_error(/must depend on something/) {}
  end

  test "a handler for a parent of the dependency is fine" do
    define do
      depends_on Car, :name
      handler(Vehicle) {}
    end
  end

  test ":any cannot be combined with attributes" do
    assert_configuration_error(/cannot be combined/) do
      depends_on Task, :any, :name
      handler(Task) {}
    end
  end

  test ":none cannot be combined with attributes over several depends_on" do
    assert_configuration_error(/cannot be combined/) do
      depends_on Task, :none
      depends_on Task, :name
      handler(Task) {}
    end
  end

  test "an unknown event in only: is an error" do
    assert_configuration_error(/only: must be/) do
      depends_on Task, :name
      handler(Task, only: :create) {}
    end
  end

  test "an unknown handler option is an error" do
    assert_raises(ArgumentError) do
      define do
        depends_on Task, :name
        handler(Task, ony: :insert) {}
      end
    end
  end

  test "a handler without a block is an error" do
    assert_configuration_error(/needs a block/) do
      depends_on Task, :name
      handler(Task)
    end
  end
end
