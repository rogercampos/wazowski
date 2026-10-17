# Changelog

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
