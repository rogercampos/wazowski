require "test_helper"


class HandlerOnlyFilterTest < BaseTest
  test ":only filter on handlers called on insert" do
    Post.create!
    assert_equal 1, StubReceiver.data[:only_on_insert].size
  end

  test ":only filter on handlers not called on destroy" do
    a = Post.create!
    a.destroy
    assert_equal 1, StubReceiver.data[:only_on_insert].size
  end

  test ":only filter on handlers not called on update" do
    a = Post.create!
    a.update! title: 'New title.'
    assert_equal 1, StubReceiver.data[:only_on_insert].size
  end
end
