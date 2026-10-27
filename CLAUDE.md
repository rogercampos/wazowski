# Wazowski

## About this library

- Wazowski observes changes on Active Record models (`Wazowski::Observer`, `observable`, `depends_on`, `handler`) and runs the handlers on insert, update or delete of the attributes they depend on, per transaction. `README.md` describes it.
- It is used from git `main`, so what is pushed to `main` is what users get at their next `bundle update wazowski`: a breaking change to the public API is called out in the commit.
- Layout: a plain gem at the root (`wazowski.gemspec`, `lib/`, `test/`), with its own `Gemfile` and committed `Gemfile.lock`, and the Ruby in `.ruby-version`. `gemfiles/` is the Ruby × Rails matrix GitHub Actions runs.
- The tests need Postgres (thread-safety tests use a real connection pool): the database the `WAZOWSKI_PG_*` variables in `.env` name.

## Running it

- Full verification: `bin/ci` (steps in `config/ci.rb`): the test suite.
- Tests: `bundle exec rake test`.
- Coverage: `bin/coverage` runs the suite with SimpleCov and leaves the report in `coverage/.resultset.json`.
- A second checkout for an isolated run: `bin/setup-worktree DIR --id ID [--provision]`, which gives it a database of its own (`wazowski_ID`).
