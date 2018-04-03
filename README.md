[![Build Status](https://travis-ci.org/rogercampos/wazowski.svg?branch=master)](https://travis-ci.org/rogercampos/wazowski)


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

Add this line to your application's Gemfile:

```ruby
gem 'wazowski'
```

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install wazowski



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
    # Since you're observing User on any attribute, changes will be always empty
  end
end
```

In this case the handler callback will receive no information about changes, even in update.

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
  depends_on User, :all
  depends_on Order, :none
  depends_on BillingInfo, :all
  
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
`:update` and `:delete`. 

```ruby
observable(:user_sync_to_salesforce) do
  depends_on User, :none
  
  handler(User, only: :insert) do |obj, event|
    # Will run only on create 
  end
end
```
 
Your blocks will be executed always on `after_commit`. They will not run if the transaction is rolled back. 
Before triggering your code, the changes that happened inside the transaction will be accumulated 
(ej: insert+delete = noop, insert + update = insert, etc.).

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

The instance used as context will be newly created for every committed transaction occurred. 

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
    depends_on User, :all
    depends_on Order, :none
    depends_on BillingInfo, :all
  
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


## Internal details

This tool currently works only with ActiveRecord, but it's design accepts multiple adapters if you ever want
to write a new one. 

The public API currently supports only relational info, but it could be expanded in the future to support 
other types of data (graph, key/value, etc.) maintaining backwards compatibility.

Even tough the current public API works by specifying directly models (ej: `User`) this class is never used
internally and is only forwarded to the adapter. To use this library with a repository pattern, the same API
could be used but instead of providing AR Classes your could provide Repository classes. However, this is only
an idea, no attempt to use this with a repository pattern has been tried. 


### Adapter's API

- An adapter is the responsible to actually observe the data. It will receive the information provided by the
user about what data has to be observed (models, attributes) and it will be responsible of calling Wazowski's hooks
whenever a database commit happens.

- An adapter is a module or class.

- An adapter must implement a `register_node` class method. This method receives 1) a node_id (string) and 
2) a hash of Class => list_of_attributes (as symbols) as defined in the public DSL. The adapter must use this information to
prepare its setup. It must keep the `node_id` string to reuse it. An attribute can also be `:none` or `:any`. 
For `:none`, the observer indicates it only wants to receive creation and deletion callbacks. For `:any`, the observer
indicates it wants to receive all callbacks, including updates on any attribute, but no need to pass specific 
dirty info. 

- The adapter must call the `Wazowski.run_handlers(changes_per_node)` every time a transaction is committed, 
once and only once per transaction even if multiple models have changed inside the transaction. It must provide as
an argument the accumulated information of changes occurred per node inside the transaction. This data structure
is a hash where each key is a node_id (as provided in the `register_node` call) and each value is an array of
changes occurred on that node. A change is defined as an array of 3 elements: the change type, the class and the 
object. Example:

```ruby
{
  "TestObserver/valid_comments_count"=>[[:insert, Post, #<Post id: 1, ...>]],
  "TestObserver/only_on_insert"=>[[:insert, Post, #<Post id: 1, ...>]]}
}
```
 
- The adapter must behave in a transactional way, i.e., if a record is created and deleted inside a transaction, no
callback should be called whatsoever. 


## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake test` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and tags, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/rogercampos/wazowski.


