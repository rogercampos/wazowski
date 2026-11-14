# A Rails app with eager loading off, as in development, whose observers live in
# app/observers and are referenced by nothing. Run by test/railtie_test.rb in a
# process of its own; prints what was loaded and which handlers ran, as JSON.
require "json"
require "logger"
require "rails"
require "active_record"
require "wazowski"

$loads = []
$events = []

ActiveRecord::Base.establish_connection(
  adapter: "postgresql",
  database: ENV["WAZOWSKI_PG_DATABASE"],
  username: ENV["WAZOWSKI_PG_USERNAME"],
  password: ENV["WAZOWSKI_PG_PASSWD"],
  host: ENV["WAZOWSKI_PG_HOST"],
  port: ENV["WAZOWSKI_PG_PORT"]
)
ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define { create_table(:widgets, force: true) { |t| t.string :name } }

class RailsApp < Rails::Application
  config.root = __dir__
  config.eager_load = false
  config.enable_reloading = true
  config.logger = Logger.new(nil)
  config.secret_key_base = "test"
end
Rails.application.initialize!

Widget.create!(name: "before reload")
Rails.application.reloader.reload!
Widget.create!(name: "after reload")

ActiveRecord::Schema.define { drop_table :widgets }
print JSON.dump(loads: $loads, events: $events)
