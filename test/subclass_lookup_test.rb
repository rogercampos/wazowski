require "test_helper"


class SubclassLookupTest < BaseTest
  test "handlers are executed for subclasses on create" do
    a = SubPage.create!

    assert_equal 1, StubReceiver.data[:trigger_on_subclass].size
    assert_equal [a, :insert, {}], StubReceiver.data[:trigger_on_subclass][0]
  end

  test "handlers are executed for subclasses on delete" do
    a = SubPage.create!
    a.destroy

    assert_equal 2, StubReceiver.data[:trigger_on_subclass].size
    assert_equal [a, :delete, {}], StubReceiver.data[:trigger_on_subclass][1]
  end

  test "handlers are executed for subclasses on update" do
    a = SubPage.create! title: 'foo'
    a.update! title: 'bar'

    assert_equal 2, StubReceiver.data[:trigger_on_subclass].size
    assert_equal [a, :update, title: %w[foo bar]], StubReceiver.data[:trigger_on_subclass][1]
  end
end
