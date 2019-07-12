require "test_helper"

class AccumulationPerTransactionTest < BaseTest
  test "optimized accumulated actions inside a transaction: insert + delete = noop" do
    Comment.transaction do
      a = Comment.create!
      a.destroy
    end

    assert_nil StubReceiver.data[:trigger]
  end

  test "optimized accumulated actions inside a transaction: insert + update = insert" do
    a = Comment.new state: 'foo'

    Comment.transaction do
      a.save!
      a.update!(state: 'bar')
    end

    assert_equal 1, StubReceiver.data[:trigger].size
    assert_equal [a, :insert, {}], StubReceiver.data[:trigger][0]
  end

  test "optimized accumulated actions inside a transaction: update + delete = delete" do
    a = Comment.create! state: 'foo'

    Comment.transaction do
      a.update!(state: 'bar')
      a.destroy
    end

    assert_equal 2, StubReceiver.data[:trigger].size
    assert_equal [a, :delete, {}], StubReceiver.data[:trigger][1]
  end
end
