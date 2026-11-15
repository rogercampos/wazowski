require "test_helper"

# Rolling back a savepoint forgets only what was changed inside it.
class SavepointTest < BaseTest
  test "a change to the same record made before the savepoint is kept" do
    comment = Comment.create!(state: "s0", post_id: 1)

    Comment.transaction do
      comment.update!(state: "s1")
      Comment.transaction(requires_new: true) do
        comment.update!(post_id: 2)
        raise ActiveRecord::Rollback
      end
    end

    assert_equal [[comment, :update, { state: %w[s0 s1] }]], StubReceiver.data[:trigger].drop(1)
  end

  test "a change made by another instance of the row before the savepoint is kept" do
    Tally.create!
    entry = Entry.create!(amount: 1)

    Entry.transaction do
      entry.update!(amount: 5)
      Entry.transaction(requires_new: true) do
        Entry.find(entry.id).update!(amount: 100)
        raise ActiveRecord::Rollback
      end
    end

    assert_equal 5, Tally.first!.total
    assert_equal [[entry, :update, false]], StubReceiver.data[:after_commit].drop(1)
  end

  test "a savepoint released inside one that rolls back is forgotten with it" do
    kept = nil

    Comment.transaction do
      kept = Comment.create!(state: "kept")
      Comment.transaction(requires_new: true) do
        Comment.transaction(requires_new: true) { Comment.create!(state: "inner") }
        raise ActiveRecord::Rollback
      end
    end

    assert_equal [[kept, :insert, {}]], StubReceiver.data[:trigger]
  end

  test "a released savepoint's changes commit with the transaction" do
    first = nil
    second = nil

    Comment.transaction do
      first = Comment.create!(state: "first")
      Comment.transaction(requires_new: true) { second = Comment.create!(state: "second") }
    end

    assert_equal [[first, :insert, {}], [second, :insert, {}]], StubReceiver.data[:trigger]
  end
end
