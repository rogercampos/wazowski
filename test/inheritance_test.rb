require "test_helper"

class InheritanceTest < BaseTest
  test "observing a subclass does not observe its parent" do
    vehicle = Vehicle.create!(name: "a")
    vehicle.update!(name: "b")

    assert_equal 2, StubReceiver.data[:vehicle].size
    assert_nil StubReceiver.data[:car]
  end

  test "a subclass is seen by the observers of itself and of its parent" do
    car = Car.create!(name: "a")
    car.update!(name: "b")

    assert_equal [[car, :insert, {}], [car, :update, { name: %w[a b] }]], StubReceiver.data[:vehicle]
    assert_equal [[car, :insert, {}], [car, :update, { name: %w[a b] }]], StubReceiver.data[:car]
  end

  test "a subclass observed before its parent is seen once by each" do
    yacht = Yacht.create!(name: "a")
    yacht.update!(name: "b")
    yacht.destroy!

    expected = [[yacht, :insert, {}], [yacht, :update, { name: %w[a b] }], [yacht, :delete, {}]]
    assert_equal expected, StubReceiver.data[:yacht]
    assert_equal expected, StubReceiver.data[:boat]
  end

  test "a parent observed after its subclass does not see the subclass's observers" do
    Boat.create!(name: "a").update!(name: "b")

    assert_equal 2, StubReceiver.data[:boat].size
    assert_nil StubReceiver.data[:yacht]
  end
end
