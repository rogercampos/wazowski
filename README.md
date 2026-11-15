# Wazowski

You can use this library to observe changes on data and execute your code when those changes occur.

Example:

```ruby
class Something < Wazowski::Observer
  observable(:observable_name) do
    depends_on Order, :user_id, :state
    
    handler(Order) do |order, event, changes|
      # This block will be called every time an Order is created, destroyed or updated on user_id or state
      # 'event' will be either insert, delete or update
      # changes will be a hash of changes occurred on the order instance, in the case of an update, ex:
      #   `{user_id: [1, 2], state: ["pending", "sent"]}` (pairs of old_value, new_value)    
    end
  end
end
```

## Installation

Wazowski is used from git `main`. Add this line to your application's Gemfile:

```ruby
gem "wazowski", github: "rogercampos/wazowski", branch: "main"
```

And then execute:

    $ bundle

Wazowski requires Ruby 3.3+ and Rails (Active Record) 8.0 or 8.1.

### Loading your observers in a Rails app

Put your observers in `app/observers`. An observer only observes once its class has been loaded, and with eager
loading off (development, most test runs) Zeitwerk loads a class only when something references it. So Wazowski's
Railtie loads every file under `app/observers` when the app boots, and again after every code reload, onto the
reloaded models. There's nothing to configure.

Subdirectories are namespaces as usual: `app/observers/credit_tally/tracking.rb` defines `CreditTally::Tracking`, also
when `CreditTally` is a model.

An observer anywhere else is not loaded for you. Reference it from a `to_prepare` block of your own, or it observes
nothing until some code happens to load it.


## Why this?

- Allows you to put your code in the scope it belongs, not necessarily in the model. Ex: If you're syncing a model
with third party service, you could setup the observer inside the namespace of this third party (ej `Salesforce`)
instead of using AR hooks directly in the observed model. It makes it easy to remove the integration with that
service in the future, it helps you decouple things.

- Provides an unified point of control from where to manage data observations and derived logic. Ex: If you want
to sync data to a third party service, having that source data in 3 different models that should be combined and
pushed. If all those 3 models change during a transaction, you'll be executing the
sync 3 times, when you could just do it once. This kind of control is difficult when using AR hooks directly in
models, but it can be implemented easily with Wazowski (see example use cases at the end). 

- Abstracts away the particularities about how the data is observed. You write in a declarative way what do you
want to happen (ej: run this if that changes) instead of directly using AR hooks. Helps in maintaining changes in
AR itself, or if you want to change your data management strategy (change AR for something else). 

- Because it's declarative, allows you to work transparently with different data sources (different databases, 
different ORM's, etc) while maintaining a unique view about how to declare data observations.


## Detailed usage and public API

The public API is:

- `Wazowski::Observer`, the class your observers inherit from.
- Its `observable(name, run: :after_commit)` class method, and inside its block `depends_on(Model, *attributes)` and
  `handler(Model, only: events) { |record, event, changes| ... }`.
- `Wazowski::ConfigurationError`, raised for mistakes in a definition.

Everything else in the gem is internal and private, and may change without notice.

You must start by creating a class inheriting from `Wazowski::Observer`. Then, you can declare observers with the
`observable` method and syntax described below. The organization of the observers is up to you, you can declare 
many `observable's` in the same class or create multiple different classes, depending on your code organization needs.

For every `observable` you must indicate which models and attributes of those models you want to observe. For any
observed model, then you must provide a handler. This handler will be invoked when a change on that model occurs.

You can observe changes on a model in different ways. The first one is manually specifying a list of attributes
to observe:

```ruby
observable(:name) do
  depends_on User, :name, :email
  
  handler(User) do |obj, event, changes|
    # changes will include the old a new values of name and email on update
    # on creation and deletion, changes will be an empty hash 
  end
end
```

But you can also choose to observe on any attribute:

```ruby
observable(:name) do
  depends_on User, :any
  
  handler(User) do |obj, event, changes|
    # On update, changes will include the old and new values of every attribute that changed
  end
end
```

In this case the handler callback will receive information about all the changes occurred. `:any` and `:none`
cannot be combined with a list of attributes.

You can also observe a model's "presence". Your code will be executed only on create and deletion of the dependant
model, but not on updates:

```ruby
observable(:name) do
  depends_on User, :none
  
  handler(User) do |obj, event, changes|
    # This block will not run on update of users.
  end
end
```


You can also observe more than one model in one observable, in this case you must provide a handler for each model:

```ruby
observable(:user_sync_to_salesforce) do
  depends_on User, :any
  depends_on Order, :none
  depends_on BillingInfo, :any
  
  foo = proc do |obj, event, changes|
    # reused handler
  end
  
  handler(User, &foo)
  handler(Order, &foo)
  handler(BillingInfo, &foo)
  # ...
end
```

When defining handlers, you can also specify handlers to run only on certain events. You can choose between `:insert`,
`:update` and `:delete`, or a list of them (`only: [:insert, :delete]`).

```ruby
observable(:user_sync_to_salesforce) do
  depends_on User, :none
  
  handler(User, only: :insert) do |obj, event|
    # Will run only on create 
  end
end
```
 
Observing a class also observes its subclasses (a handler for `Page` runs for a `SubPage` too, unless the observable
has a handler for `SubPage` itself), but observing a subclass does not observe its parent.

Definitions are checked when the class is loaded: every observed model needs a handler (its own or one for a class it
inherits from), every handler needs an observed model, and `only:` takes known events only. Mistakes raise
`Wazowski::ConfigurationError`.

By default your blocks run after the transaction commits (see below to run them inside it). They do not run if the
transaction is rolled back. Rolling back a savepoint (`transaction(requires_new: true)`) drops only what changed
inside it; the rest of the transaction still counts. Before your code runs, the changes that happened inside the
transaction are accumulated: an insert followed by a delete is nothing, an insert followed by updates is an insert,
and several updates are one update, with the value before the transaction as the old value.

### Running inside the transaction

By default handlers run after the transaction commits. Pass `run: :before_commit` to run them inside it instead,
just before it commits, once all of its changes are in:

```ruby
class CreditTotals < Wazowski::Observer
  observable(:spent, run: :before_commit) do
    depends_on Charge, :amount

    handler(Charge) do |charge, event, changes|
      # Written in the same transaction as the charge, so nobody can read the
      # charge without the total that includes it.
    end
  end
end
```

Use it for derived data that has to be committed together with the change it derives from, for example a counter
read under a lock that the same transaction holds. The changes are accumulated the same way, the handlers run
once per transaction, and nothing runs if it is rolled back. Changes a before-commit handler makes to observed
models are passed on to after-commit handlers only, not back to before-commit ones.

Changes are observed through Active Record callbacks, so writes that skip them are not seen: `update_column(s)`,
`update_all`, `delete`, `delete_all`, `insert_all`, `upsert_all` and the like. An exception raised from an
after-commit handler propagates to the code that committed (the data is already committed by then), and the
remaining handlers for that transaction do not run.

Each database connection keeps its own changes, so a model on another database (`connects_to`) commits and runs its
handlers on its own, independently of what's open on the primary one.

Note that if you update attributes on a model inside a handler, this can result in an infinite loop if the attributes
you're changing are also observed by the same handler. You can, however, "chain" multiple observers (i.e., one
handler can trigger an update for an attribute observed in a second handler, etc.) as long as this graph 
does not contain cycles. 

 
### Context of execution for handlers

The context in which your handlers will be executed is an instance of the class in which the `observable` 
is defined. This gives you flexibility for reusing common code across your handlers by including your own modules, ex:

```ruby
class ObserversForSomething < Wazowski::Observer
  include MyCommonObserverLogic
  
  observable(:name) do
    # ...
    handler(Model) do |_|
      # use_common_logic_here from MyCommonObserverLogic
      # 'self' == ObserversForSomething.new
    end
  end
end
```

The instance used as context will be newly created for every committed transaction occurred. It will be also
newly created for any `observable` declared.

If you're observing multiple models inside an observable, and all those models experience changes inside a transaction 
(say, i.e. 4 models), all your 4 handlers will be executed. Since all those changes occurred in a single transaction, 
the context instance will be the same for the 4 handler executions, so you can use state to implement features.

On the other hand, if those 4 models experience changes in 4 isolated transactions, your 4 handlers will be executed
every time with a newly created context instance.

Your observer classes can implement an initialization method, but it must have no arguments in order for Wazowski
to be able to instantiate them.


## Usage examples

### Execute a handler only once per transaction

If you're implementing a synchronization of data with a third party service, it's a common practice to develop
an Etl on your side, which reads information on your database and creates a new representation of that data (possibly
with manipulation logics, like re-formatting of currencies, countries, etc.) that is then pushed to the service.

The source data is scattered across multiple models, so you need to watch for all those points to re-sync when
they change. But since the Etl has only one entry point, in the case all those models are updated inside the same 
transaction you want the Etl to run only once.

To accomplish this, you can use some state inside your observer class to run the handler only on the first time:

```ruby
class MyObserver < Wazowski::Observer
  def initialize
    @counter = 0 
  end
  
  def run_only_once
    return unless @counter == 0
    yield
    @counter += 1
  end
 
  observable(:user_sync_to_salesforce) do
    depends_on User, :any
    depends_on Order, :none
    depends_on BillingInfo, :any
  
    handler(User) { |user| 
      run_only_once { Etl.run(user) } 
    }
    handler(Order) { |order| 
      run_only_once { Etl.run(order.user) }
    }
    handler(BillingInfo) { |billing_info| 
      run_only_once { Etl.run(billing_info.user) }
    }
  end
end
```


## Development

After checking out the repo, run `bin/setup` to install dependencies. The tests need a Postgres database, named by
the `WAZOWSKI_PG_*` variables in `.env`. Run `bin/ci` to run the tests on every supported Rails version, or
`bundle exec rake test` for the default one. You can also run `bin/console` for an interactive prompt.

What is pushed to `main` is what apps get at their next `bundle update wazowski`.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/rogercampos/wazowski.


