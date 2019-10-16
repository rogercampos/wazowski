require "test_helper"

class CrudActionsTest < BaseTest
  test "CREATE / calls the trigger only once per two defined observed attributes" do
    Comment.create!
    assert_equal 1, StubReceiver.data[:trigger].size
  end

  test "CREATE / calls the trigger with no changes" do
    a = Comment.new
    a.save!

    assert_equal 1, StubReceiver.data[:trigger].size
    assert_equal [a, :insert, {}], StubReceiver.data[:trigger][0]
  end

  test "CREATE / calls the trigger when observing all attributes" do
    a = Page.new
    a.save!

    assert_equal 1, StubReceiver.data[:trigger].size
    assert_equal [a, :insert, {}], StubReceiver.data[:trigger][0]
  end

  test "CREATE / calls the trigger when observing no attrs" do
    Post.create!
    assert_equal 1, StubReceiver.data[:trigger].size
  end

  test "CREATE / calls trigger only on after commit" do
    Comment.transaction do
      Comment.create!
      raise ActiveRecord::Rollback
    end

    assert_nil StubReceiver.data[:trigger]
  end

  test "DELETE / calls the trigger" do
    a = Comment.create!
    a.destroy

    assert_equal 2, StubReceiver.data[:trigger].size
    assert_equal [a, :delete, {}], StubReceiver.data[:trigger][1]
  end

  test "DELETE / calls the trigger when observing all attributes" do
    a = Page.create!
    a.destroy

    assert_equal 2, StubReceiver.data[:trigger].size
    assert_equal [a, :delete, {}], StubReceiver.data[:trigger][1]
  end

  test "DELETE / calls the trigger when observing no attributes" do
    a = Post.create!
    a.destroy

    assert_equal 2, StubReceiver.data[:trigger].size
    assert_equal [a, :delete, {}], StubReceiver.data[:trigger][1]
  end

  test "UPDATE / calls the trigger" do
    a = Comment.create! state: 'foo'
    a.update! state: 'bar'

    assert_equal 2, StubReceiver.data[:trigger].size
    assert_equal [a, :update, state: %w[foo bar]], StubReceiver.data[:trigger][1]
  end

  test "UPDATE / doesn't call the trigger if an update occurs on a non-observed attribute" do
    a = Comment.create!
    a.update! ignored: 'foo'

    # just 1 call for the creation
    assert_equal 1, StubReceiver.data[:trigger].size
  end

  test "UPDATE / doesn't call the trigger if no observed attributes" do
    a = Post.create!
    a.update! title: 'New title'

    # just 1 call for the creation
    assert_equal 1, StubReceiver.data[:trigger].size
  end

  test "UPDATE / calls the trigger when observing any attributes, with no specific attribute info" do
    a = Page.create!
    a.update! title: 'foo', body: 'bar'

    assert_equal 2, StubReceiver.data[:trigger].size
    assert_equal [a, :update, {}], StubReceiver.data[:trigger][1]
  end

  test "UPDATE / provides the accumulated changes based on transaction on only one trigger call" do
    a = Comment.create! state: 's0'

    Comment.transaction do
      a.update! state: 's1'
      a.update! state: 's2'
    end

    assert_equal 2, StubReceiver.data[:trigger].size
    assert_equal [a, :update, state: %w[s0 s2]], StubReceiver.data[:trigger][1]
  end

  test "UPDATE / provides accumulated changes in only one call when multiple attributes are updated" do
    a = Comment.create! post_id: 1, state: 'foo'
    a.update! post_id: 2, state: 'bar'

    assert_equal 2, StubReceiver.data[:trigger].size
    assert_equal [a, :update, state: %w[foo bar], post_id: [1, 2]], StubReceiver.data[:trigger][1]
  end
end
