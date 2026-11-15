require "test_helper"

class ThreadSafetyTest < BaseTest
  test "isolates changes per active record connection" do
    a = Comment.create! state: "foo", post_id: 1
    b_id = Comment.create!(state: "foo", post_id: 1).id
    updated = Queue.new
    resume = Queue.new

    thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ActiveRecord::Base.transaction do
          Comment.find(b_id).update!(state: "bar")
          updated << true
          resume.pop
        end
      end
    end

    updated.pop # the thread's update is in, not committed
    a.update!(post_id: 2)

    assert_equal [[a, :update, { post_id: [1, 2] }]], StubReceiver.data[:trigger].drop(2)

    resume << true
    thread.join

    b, change_type, changes = StubReceiver.data[:trigger].last
    assert_equal [b_id, :update, { state: %w[foo bar] }], [b.id, change_type, changes]
  end
end

class ConnectionIsolationTest < BaseTest
  test "a commit on another connection does not run the handlers of an open transaction" do
    Tally.create!
    entry = nil

    Entry.transaction do
      entry = Entry.create!(amount: 5)
      SecondaryComment.create!(state: "secondary")
    end

    assert_equal 1, StubReceiver.data[:trigger_on_secondary].size
    # Run once, by its own commit: not from inside its transaction.
    assert_equal [[entry, :insert, false]], StubReceiver.data[:after_commit]
  end

  test "each transaction keeps its own observer instance when threads commit at once" do
    paused = Queue.new
    resume = Queue.new

    thread = Thread.new do
      Thread.current[:wazowski_test_pause] = lambda do
        Thread.current[:wazowski_test_pause] = nil
        paused << true
        resume.pop
      end

      ActiveRecord::Base.connection_pool.with_connection do
        Task.transaction do
          Task.create!(name: "first")
          Task.create!(name: "second")
        end
      end
    end

    paused.pop # the thread is between its two handlers
    Task.create!(name: "other")
    resume << true
    thread.join

    contexts = StubReceiver.data[:context].to_h
    assert_equal contexts["first"], contexts["second"]
    refute_equal contexts["first"], contexts["other"]
  end
end
