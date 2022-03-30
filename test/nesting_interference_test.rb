require "test_helper"

class NestingInterferenceTest < BaseTest
  test "does not enter an infinite loop" do
    planet = Planet.create!
    ship = Ship.create! planet: planet

    ship.update! name: "Noob"
  end

  test "does enter an infinite loop if a handler triggers the observer again" do
    ship = Ship.create!
    error = assert_raises(SystemStackError) { ship.update!(label: "foo") }
    assert_equal "stack level too deep", error.message
  end

  test "does not enter infinite loop if the handler updates an unobserved attribute" do
    ship = Ship.create!
    ship.update! engine: "Warp"
    assert_equal "Warp", ship.engine
    assert_equal "Foo", ship.brand
  end

  test "observers can be chained" do
    planet = Planet.create!
    planet.update! a1: "First step"
    assert_equal "second step", planet.a2
    assert_equal "third step", planet.a3
  end

  test "chained observers don't get called multiple times" do
    planet = Planet.create!
    planet.update! a1: "First step"
    assert_equal 1, planet.count_on_nested_observers_a1_callings
  end
end
