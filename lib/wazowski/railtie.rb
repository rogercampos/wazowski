# frozen_string_literal: true

module Wazowski
  # An observer observes only once its class has been loaded, and with eager
  # loading off (development, most test runs) nothing would load it until some
  # code happened to reference it. So every observer under app/observers is
  # loaded on each to_prepare: at boot, and again after every code reload, onto
  # the reloaded models.
  class Railtie < Rails::Railtie
    OBSERVERS_DIR = "app/observers"

    config.to_prepare do
      dir = Rails.root.join(OBSERVERS_DIR)
      Rails.autoloaders.main.eager_load_dir(dir) if dir.directory?
    end
  end
end
