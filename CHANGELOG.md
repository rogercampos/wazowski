# Changelog

## Unreleased

- A Railtie loads every observer under `app/observers` at boot and after every code reload, so apps no longer list
  their observers in a `to_prepare` initializer, and an observer added there can't be left out by mistake. Observers
  elsewhere still need loading by hand.
- Active Record and Active Support are capped below 8.2. `run: :before_commit` relies on Active Record's undocumented
  model-level `before_commit` callback, so each new Rails minor is allowed only once the test suite has passed on it.
- Pending changes are kept by the adapter, per connection, instead of in instance variables of each record, and each
  change goes only to the timing of the node that observes it: a save observed only by `run: :before_commit` nodes no
  longer builds a changeset for after-commit handlers that is then thrown away. Observed models no longer get
  `__wazowski_*` methods.
- The public API is `Wazowski::Observer` (`observable`, `depends_on`, `handler`) and `Wazowski::ConfigurationError`.
  The rest is now private: `Wazowski::Node` and `Wazowski::ActiveRecordAdapter` are private constants, and
  `Wazowski::Config`, `Wazowski::Observable`, `Wazowski::NoSuchNode`, `Wazowski.find_node` and `Wazowski.run_handlers`
  are gone. The README no longer documents an adapter API.
- Fix: a record saved more than once in a transaction reports the attribute's value from before the transaction as the
  old value also when that value was `nil` (a later save used to replace it with its own old value).

## 0.4.0

- Requires Ruby 3.3+ and Rails 8.0+. Tested on Ruby 3.3, 3.4 and 4.0.
- `run: :before_commit` option on `observable`, to run handlers inside the transaction.
- Definitions are validated when loaded: observed models without a handler, handlers without an observed model,
  `:any`/`:none` mixed with attributes and unknown `only:` events raise `Wazowski::ConfigurationError`.
  `handler` takes `only:` as a keyword, so unknown options raise `ArgumentError`.
- Fix: changes are tracked per connection of the observed model. A commit on another database no longer runs the
  handlers of a transaction still open on the primary one.
- Fix: two instances of the same row changed in one transaction both report their changes, and a rollback forgets
  the changes of all of them (they used to leak into a later commit).
- Fix: observing an STI subclass no longer observes its parent (saving the parent raised `ConfigurationError`), and
  observing a parent after its subclass no longer raises a class variable error.
- Fix: handlers of concurrent transactions no longer share their observer instance across threads.
- Removed `Node#wrapping` and `Node#after_commit_on_{create,update,delete}`, replaced by `Node#run`.
