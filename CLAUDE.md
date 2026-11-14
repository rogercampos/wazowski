# Wazowski

## About this library

- Wazowski observes changes on Active Record models (`Wazowski::Observer`, `observable`, `depends_on`, `handler`) and runs the handlers on insert, update or delete of the attributes they depend on, per transaction. `README.md` describes it.
- It is used from git `main`, so what is pushed to `main` is what users get at their next `bundle update wazowski`: a breaking change to the public API is called out in the commit. The public API is `Wazowski::Observer` (`observable`, `depends_on`, `handler`) and `Wazowski::ConfigurationError`; everything else is a private constant (`private_constant` at the end of `lib/wazowski.rb`) and can change freely.
- Layout: a plain gem at the root (`wazowski.gemspec`, `lib/`, `test/`), with its own `Gemfile` and committed `Gemfile.lock`, and the Ruby in `.ruby-version`. `gemfiles/` holds a Gemfile per supported Rails version; `bin/ci` runs them all.
- The gemspec caps Active Record at the newest minor `bin/ci` has passed on (`< 8.2`), because `run: :before_commit` relies on Active Record's undocumented model-level `before_commit` callback (`Wazowski::ActiveRecordAdapter.before_commit_hook`). To support a new Rails: add its gemfile, add it to `config/ci.rb`, and raise the cap only once `bin/ci` passes.
- In a Rails app, `Wazowski::Railtie` (`lib/wazowski/railtie.rb`) loads every observer under `app/observers` on each `to_prepare`. `test/railtie_test.rb` boots the Rails app in `test/fixtures/rails_app` in a process of its own to cover it.
- The tests need Postgres (thread-safety tests use a real connection pool): the database the `WAZOWSKI_PG_*` variables in `.env` name.

## Running it

- Full verification: `bin/ci` (steps in `config/ci.rb`): the test suite on each supported Rails.
- Tests: `bundle exec rake test`.
- Coverage: `bin/coverage` runs the suite with SimpleCov and leaves the report in `coverage/.resultset.json`.
- A second checkout for an isolated run: `bin/setup-worktree DIR --id ID [--provision]`, which gives it a database of its own (`wazowski_ID`).
