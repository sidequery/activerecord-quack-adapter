# activerecord-quack-adapter

Direct Quack protocol adapter for Rails / Active Record 7.2, 8.0 and 8.1,
backed by [quack-ruby](https://github.com/sidequery/quack-ruby). Connections use
HTTP(S) rather than ADBC or an embedded DuckDB database.

## Install

Add to your Gemfile:

```ruby
gem "activerecord-quack-adapter", "~> 0.1.0"
```

The adapter installs `quack-ruby` automatically. Its precompiled gems cover Ruby
3.2–3.4 on macOS and Linux glibc, on both Intel/x86-64 and ARM64. The Quack
extension needs no Cargo or compiler on those combinations. Source installs
on other platforms require the client's native build prerequisites.
A Quack server and database must already exist. Supported servers are DuckDB
1.5.5 and 2.0.0. Ruby entry points and the `adapter: quack` setting are unchanged.

## Rails configuration and usage

A Quack server must already be running. Configure `config/database.yml`:

```yaml
default: &default
  adapter: quack
  uri: <%= ENV.fetch("QUACK_URI") %>
  auth_token: <%= ENV.fetch("QUACK_TOKEN") %>
  pool: <%= ENV.fetch("RAILS_MAX_THREADS", 5) %>
  timeout: 30 # Seconds per HTTP request, not Rails' pool checkout timeout.
  # ssl_fingerprint: <%= ENV["QUACK_SSL_FINGERPRINT"] %>
  # catalog: analytics
  # schema: main

development:
  <<: *default
test:
  <<: *default
production:
  <<: *default
```

`uri` accepts `quack:host:port`, `host:port`, bracketed IPv6, or an HTTP(S) URL.
Alternatively set `host` and `port`. `database` is accepted as an endpoint alias;
use `catalog` to select a database attached on the server. Native connection
options such as `ssl`, headers and protocol-version bounds also work in YAML.

For self-signed HTTPS, configure the certificate's SHA-256 `ssl_fingerprint`.
A pin implies HTTPS and trusts that exact certificate. Without a pin, HTTPS uses
normal certificate and hostname validation.

Models and migrations use the normal Rails interfaces:

```ruby
class Event < ApplicationRecord
end

class CreateEvents < ActiveRecord::Migration[7.2]
  def change
    create_table :events do |t|
      t.string :name, null: false
      t.bigint :count
      t.decimal :amount, precision: 20, scale: 6
      t.timestamps
    end
  end
end

Event.create!(name: "signup", count: 1)
Event.where(name: "signup").count
Event.insert_all!([{name: "signup", count: 2}], returning: %w[id name])
Event.transaction { Event.where(name: "signup").update_all(count: 3) }
```

The adapter implements CRUD, bound queries, generated IDs via sequences and
`RETURNING`, SQL bulk insert/upsert, transactions, table/column/primary-key/index
inspection, ordinary table/column/index migrations and sequence-aware
`schema.rb` dumping/loading. Rails owns pooling; each adapter connection owns one
remote session. There is no second Rust connection pool beneath Active Record.

`rails db:migrate` operates on the existing remote database. `db:create` checks
that the endpoint is accessible and reports it already exists. Provision and
remove databases on the server; client-side `db:drop`, `db:purge`, `db:reset`, and
SQL structure dump/load tasks are intentionally unavailable. Use Ruby schema
format. For an analytics-only secondary connection, use Rails' multiple-database
configuration with `database_tasks: false` and an abstract model with
`connects_to`.

## Data types

| DuckDB value | Ruby value |
| --- | --- |
| Signed/unsigned integers, including 128-bit and BIGNUM | `Integer`, without precision loss |
| Decimal | `BigDecimal` |
| Boolean, floating point, text, NULL | `true`/`false`, `Float`, `String`, `nil` |
| BLOB / other byte payloads | Binary-encoded `String` |
| Date | Proleptic Gregorian `Date` |
| Timestamp | `Quack::Timestamp < Time`, retaining SQL units, timezone kind and nanoseconds |
| Time / time with offset | `Quack::TimeOfDay` (supports `24:00:00`) |
| Interval | `Quack::Interval(months, days, microseconds)` |
| Infinite date/timestamp | `Quack::InfiniteTemporal` |
| List/array, struct | `Array`, string-keyed `Hash` |
| JSON, UUID, ENUM | `String` (Rails casts JSON to Ruby objects) |
| MAP | `Quack::Map`, with `entries`, `[]`, `each`, `to_h` |
| BIT | `Quack::BitString(bits)`, a string of logical 0/1 bits |
| GEOMETRY | `Quack::Geometry(wkb, crs)`, standard WKB and optional CRS |
| UNION | `Quack::Union(tag, value, members)`; tag distinguishes a NULL member from SQL NULL |
| VARIANT | `Quack::Variant`, with a typed `node` tree and logical Ruby `value` |
| TUPLE / unnamed STRUCT | `Quack::Tuple(values)`, preserving every ordinal field |

These logical values support SQL parameters, model assignment and native v1
append, including values nested in lists, arrays and structs. BIGNUM decoding,
DuckDB 2.0 type IDs and unnamed field handling are fixed in the packaged crate;
no separate fork download is needed to build the gem.

Read timestamps retain their SQL kind when rebound. Construct one explicitly
with `Quack::Timestamp.from(time, "TIMESTAMP_NS")` or, on DuckDB 2.0,
`Quack::Timestamp.from(time, "TIMESTAMPTZ_NS")`. Plain `Time`/`DateTime` values
use TIMESTAMPTZ when microseconds suffice and TIMESTAMP_NS when nanoseconds are
needed. Connections initialize `TimeZone = 'UTC'`, including after reconnect.
Subsequent explicit timezone changes follow DuckDB's normal cast semantics.
Values beyond a destination's precision are rejected by native append rather
than silently truncated. Rails writes preserve nine fractional digits.

`Quack::Variant.new({"items" => [1, nil, "é"]})` builds a heterogeneous value.
Use `Quack::Variant.new(value, type: "UBIGINT")` to specify a scalar type.
`variant.value` returns a Ruby tree; `variant.node` preserves each nested scalar
type. Assign a new Variant to edit it. DuckDB normalizes a root VARIANT null to
SQL NULL (`nil`); nulls inside containers remain nested nodes. Geometry uses
standard WKB rather than a client geometry engine, preserving Z/M, empty values,
collections and CRS metadata.

All storable public type families are exercised on the supported server versions.
DuckDB 1.5 cannot persist unnamed STRUCT/ROW tuples (even regular SQL INSERT fails);
their query/parameter roundtrips work, and tuple persistence is tested on 2.0.
TIMESTAMPTZ_NS is a DuckDB 2.0 type and is unavailable on 1.5. Internal/binder-only
types and types supplied by optional server extensions are not universal targets.

Scalar and logical values support normal create/update/reload, bound queries
and SQL bulk writes. Lists, structs and nested maps track in-place edits.
Use explicit SQL migrations for DuckDB types without a Rails migration helper.

## Adapter limits

- DuckDB has no savepoints. Joined nested transactions work; `requires_new`
  savepoints and custom isolation levels are unsupported.
- Foreign-key/check-constraint migration helpers and expression/partial-index
  helpers are unavailable. They raise rather than silently dropping constraints.
- Schema dumps support the ordinary migration types, including generated-ID
  sequences. Comprehensive complex-type schema dumping is not implemented;
  manage those objects with explicit SQL migrations.
- Provision/drop remote databases on the server. Client db:drop, db:purge,
  db:reset and SQL structure dump/load tasks are unavailable. Use schema.rb
  for supported migration types.
- Statements are never replayed after a session/transport failure, including
  through Rails' allow_retry. Handle the failure and reconnect explicitly.
- Rails owns pooling; one adapter connection owns one remote session. Native
  network waits release the GVL. Create/check out connections after forking.

## Development

```sh
CARGO="$PWD/script/cached-cargo" bundle install
script/test
BUNDLE_GEMFILE=gemfiles/active_record_72.gemfile CARGO="$PWD/script/cached-cargo" bundle install
BUNDLE_GEMFILE=gemfiles/active_record_72.gemfile script/test
BUNDLE_GEMFILE=gemfiles/active_record_80.gemfile CARGO="$PWD/script/cached-cargo" bundle install
BUNDLE_GEMFILE=gemfiles/active_record_80.gemfile script/test
bundle exec rake package
```

Tests use uv to start real DuckDB 1.5.5/v1 and 2.0.0/v3 servers and stop them
after each run. They exercise model/result/bind roundtrips across all storable
public type families, nested mutation tracking, CRUD, bulk insert/upsert,
transactions, pooling, metadata, schema migrations/dumps and a Rails app that
boots from database.yml and serves database-backed POST/GET requests.

CI is configured for all three Active Record series on Linux/macOS. The
client's separate suite covers protocol, TLS, lifecycle and native v1 append.
The `Release` workflow builds the adapter gem and tests installed packages
against all three Rails series with Cargo and rustc blocked. Dispatch it from
main with a patch, minor or major bump to update versions and locks, commit/tag,
test, publish through RubyGems Trusted Publishing, and create a GitHub Release.
An optional `release_tag` publishes an existing matching tag without a bump.
Publish the matching client version first; update the client dependency when
moving to a new client minor series.

## License

MIT. Adapted Active Record quoting/bulk-insert code retains the upstream
notice in LICENSE-ActiveRecord. Quack's native dependency has its own licenses.
