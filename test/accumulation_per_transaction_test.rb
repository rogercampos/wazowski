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

class SameRowTwiceTest < BaseTest
  test "the changes of two instances of the same row are all seen" do
    comment = Comment.create!(state: "s0", post_id: 1)
    first = Comment.find(comment.id)
    second = Comment.find(comment.id)

    Comment.transaction do
      first.update!(state: "s1")
      second.update!(post_id: 2)
    end

    changes = StubReceiver.data[:trigger].drop(1).map(&:last)
    assert_equal [{ state: %w[s0 s1] }, { post_id: [1, 2] }], changes
  end

  test "rolling back forgets the changes of every instance of the row" do
    comment = Comment.create!(state: "s0", post_id: 1)
    first = Comment.find(comment.id)
    second = Comment.find(comment.id)

    Comment.transaction do
      first.update!(state: "s1")
      second.update!(post_id: 2)
      raise ActiveRecord::Rollback
    end

    second.reload.update!(state: "s3")

    assert_equal [comment, :update, { state: %w[s0 s3] }], StubReceiver.data[:trigger].last
    assert_equal 2, StubReceiver.data[:trigger].size
  end
end
