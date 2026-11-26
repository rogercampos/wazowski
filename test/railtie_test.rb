require "test_helper"
require "json"
require "open3"

class RailtieTest < Minitest::Test
  BOOT = File.expand_path("fixtures/rails_app/boot.rb", __dir__)

  # The app is booted once for the file: every run does the same, so the tests
  # read what the one boot printed.
  def self.app_run
    @app_run ||= Open3.capture3(RbConfig.ruby, BOOT)
  end

  def run_app
    out, err, status = self.class.app_run
    assert status.success?, err
    JSON.parse(out)
  end

  def test_loads_the_observers_in_app_observers_at_boot_and_after_every_reload
    loads = run_app["loads"]

    assert_equal [ "Widget::Audit", "Widget::Audit", "WidgetCount", "WidgetCount" ], loads.sort
  end

  def test_the_observers_reloaded_observe_the_reloaded_models
    events = run_app["events"]

    assert_equal [
      [ "Widget::Audit", "insert", "after reload" ],
      [ "Widget::Audit", "insert", "before reload" ],
      [ "WidgetCount", "insert", "after reload" ],
      [ "WidgetCount", "insert", "before reload" ]
    ], events.sort
  end
end
