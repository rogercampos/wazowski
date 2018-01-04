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
          Comment.find(id).update_attributes!(state: "bar")
          sleep 0.1
        end
      end
    end

    ActiveRecord::Base.transaction do
      a.update_attributes!(post_id: 2)
      sleep 0.05
    end

    assert_equal 2, StubReceiver.data[:trigger].size
    assert_equal [a, :update, post_id: [1, 2]], StubReceiver.data[:trigger][1]

    t1.join

    assert_equal 3, StubReceiver.data[:trigger].size
    assert_equal [a, :update, state: ["foo", "bar"]], StubReceiver.data[:trigger][2]
  end
end
