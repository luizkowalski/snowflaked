# Snowflaked

A high-performance, thread-safe Snowflake ID generator for Ruby, powered by Rust.

Snowflake IDs are 64-bit unique identifiers that encode a timestamp, machine ID, and sequence number. They're time-sortable (IDs created later are always larger), making them ideal for distributed systems where you need unique IDs without coordination between machines. Unlike UUIDs, Snowflake IDs are smaller, sortable, and index-friendly for databases.

## Installation

Add to your Gemfile:

```ruby
gem "snowflaked"
```

## Quick Start

```ruby
id = Snowflaked.id
# => 7193489234823847936
```

## Rails Integration

All models automatically generate a Snowflake ID for the `:id` attribute:

```ruby
class User < ApplicationRecord
end

User.create!
# => #<User id: 7193489234823847936>
```

You can also define additional Snowflake columns in migrations:

```ruby
class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.snowflake :external_id
    end
  end
end
```

If you want to generate Snowflake IDs for additional columns, you can do so by using the `snowflake_id` method, without having to migrate the table:

```ruby
class User < ApplicationRecord
  snowflake_id :external_id
end
```

It is also possible to disable automatic `:id` generation by passing `id: false` to the `snowflake_id` method:

```ruby
class Post < ApplicationRecord
  snowflake_id id: false
end
```

Or generate Snowflake IDs for other columns but not `:id`:

```ruby
class Post < ApplicationRecord
  snowflake_id :external_id, id: false
end
```

## Configuration

```ruby
Snowflaked.configure do |config|
  config.machine_id = 42
  config.epoch = Time.utc(2020, 1, 1)
end
```

### Machine ID Resolution

If `machine_id` is not explicitly configured, it resolves in this order:

1. `SNOWFLAKED_MACHINE_ID` environment variable
2. `MACHINE_ID` environment variable
3. Auto-detected using the following formula: `(hostname.hash ^ pid) % 1024`

For Kubernetes deployments, you can set the machine ID using an environment variable:

```yaml
env:
  - name: SNOWFLAKED_MACHINE_ID
    valueFrom:
      fieldRef:
        fieldPath: metadata.name
```

Or use a StatefulSet ordinal for guaranteed unique values:

```yaml
env:
  - name: SNOWFLAKED_MACHINE_ID
    valueFrom:
      fieldRef:
        fieldPath: metadata.annotations['apps.kubernetes.io/pod-index']
```

## API Reference

```ruby
id = Snowflaked.id

Snowflaked.parse(id)
# => {timestamp_ms: 1735123456789, machine_id: 42, sequence: 0}

Snowflaked.timestamp(id)
# => 2024-12-25 12:34:56 +0000

Snowflaked.timestamp_ms(id)
# => 1735123456789

Snowflaked.sequence(id)
# => 0

Snowflaked.machine_id(id)
# => 42
```

## Requirements

- Ruby >= 3.2
- rustc >= 1.81.0
- cargo >= 1.81.0
- Mise

## Development

```bash
mise install
bundle install
bundle exec rake
```

## License

MIT
