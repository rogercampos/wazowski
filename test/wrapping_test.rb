require "test_helper"

class WrappingTest < BaseTest
  test "#wrapping is called once per after_commit" do
    Comment.transaction do
      Comment.create!
      Post.create!
    end

    assert_equal 1, StubReceiver.data[:wrapping_called].size
  end
end
