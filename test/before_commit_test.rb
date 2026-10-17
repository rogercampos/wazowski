require "test_helper"

class BeforeCommitTest < BaseTest
  def setup
    super
    @tally = Tally.create!
  end

  test "runs inside the transaction, before it commits" do
    Entry.create!(amount: 5)

    assert_equal [ true ], StubReceiver.data[:before_commit].map(&:last)
    assert_equal [ false ], StubReceiver.data[:after_commit].map(&:last)
  end

  test "what the handler writes commits with the change" do
    Entry.transaction do
      Entry.create!(amount: 5)
      Entry.create!(amount: 7)
    end
    Entry.first.update!(amount: 10)
    Entry.last.destroy!

    assert_equal 10, @tally.reload.total
  end

  test "runs once per transaction, with every change accumulated" do
    Entry.transaction do
      Entry.create!(amount: 1)
      Entry.create!(amount: 2)
      Entry.create!(amount: 3)
    end

    assert_equal [ 1, 2, 3 ], StubReceiver.data[:before_commit].map { |entry, *| entry.amount }.sort
    assert_equal 3, StubReceiver.data[:after_commit].size
  end

  test "a rolled back transaction runs nothing and leaves the next one clean" do
    Entry.transaction do
      Entry.create!(amount: 5)
      raise ActiveRecord::Rollback
    end

    assert_nil StubReceiver.data[:before_commit]

    Entry.create!(amount: 2)
    assert_equal 1, StubReceiver.data[:before_commit].size
    assert_equal 2, @tally.reload.total
  end

  test "a transaction run from the previous one's after-commit phase is counted too" do
    Entry.transaction do
      Entry.create!(amount: 5)
      Entry.connection.current_transaction.after_commit { Entry.create!(amount: 7) }
    end

    assert_equal 12, @tally.reload.total
  end

  test "changes to a record made from the previous transaction's after-commit phase are seen as changes" do
    entry = Entry.create!(amount: 1)

    Entry.transaction do
      entry.update!(amount: 2)
      Entry.connection.current_transaction.after_commit { entry.update!(amount: 10) }
    end

    assert_equal 10, @tally.reload.total
  end

  test "a transaction started from another record's after-commit callback is counted too" do
    Entry.transaction do
      Invoice.create!(number: "A-1")
      Entry.create!(amount: 5)
    end

    assert_equal 12, @tally.reload.total
  end

  test "rolling back a savepoint keeps what the rest of the transaction changed" do
    Entry.transaction do
      Entry.create!(amount: 5)
      Entry.transaction(requires_new: true) do
        Entry.create!(amount: 100)
        raise ActiveRecord::Rollback
      end
    end

    assert_equal 5, @tally.reload.total
  end

  test "an unknown timing is a configuration error" do
    assert_raises(Wazowski::ConfigurationError) do
      Class.new(Wazowski::Observer) do
        observable(:nope, run: :whenever) { depends_on Entry, :amount }
      end
    end
  end
end
