require "test_helper"

class ThreadSafetyTest < BaseTest
  # Synchronize concurrent actions to first update on both threads and then
  # commit on both threads, using sleep.
  test "isolates changes per active record connection" do
    a = Comment.create! state: "foo", post_id: 1
    id = a.id

    t1 = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ActiveRecord::Base.transaction do
          # update must happen in a new AR object to isolate
          # both threads
          Comment.find(id).update!(state: "bar")
          sleep 0.1
        end
      end
    end

    ActiveRecord::Base.transaction do
      a.update!(post_id: 2)
      sleep 0.05
    end

    assert_equal 2, StubReceiver.data[:trigger].size
    assert_equal [a, :update, post_id: [1, 2]], StubReceiver.data[:trigger][1]

    t1.join

    assert_equal 3, StubReceiver.data[:trigger].size
    assert_equal [a, :update, state: ["foo", "bar"]], StubReceiver.data[:trigger][2]
  end
end

class ConnectionIsolationTest < BaseTest
  test "a commit on another connection does not run the handlers of an open transaction" do
    Comment.transaction do
      Comment.create!(state: "primary")
      SecondaryComment.create!(state: "secondary")

      assert_nil StubReceiver.data[:trigger]
      assert_equal 1, StubReceiver.data[:trigger_on_secondary].size
      raise ActiveRecord::Rollback
    end

    assert_nil StubReceiver.data[:trigger]
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
