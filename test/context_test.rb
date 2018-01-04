require "test_helper"

class ContextTest < BaseTest
  test "handlers have access to an observer instance, alive for the duration of all handlers" do
    ActiveRecord::Base.transaction do # Force 1 transaction
      Comment.create!
      Post.create!
    end

    assert_equal 2, StubReceiver.data[:counter_status].size
    assert_equal [1], StubReceiver.data[:counter_status][0]
    assert_equal [2], StubReceiver.data[:counter_status][1]
  end

  test "context instance is new on each after_commit" do
    Comment.create! # 2 independent transactions
    Post.create!

    assert_equal 2, StubReceiver.data[:counter_status].size
    assert_equal [1], StubReceiver.data[:counter_status][0]
    assert_equal [1], StubReceiver.data[:counter_status][1]
  end
end
