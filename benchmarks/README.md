# Snowflaked Benchmarks

Performance benchmarks comparing record creation with Snowflaked IDs vs database-backed IDs using PostgreSQL.

## Setup

First, ensure PostgreSQL is running and create the benchmark database:

```bash
createdb snowflaked_benchmark
```

## Running the Benchmark

```bash
cd benchmarks
ruby benchmark_record_creation.rb
```

## Cleanup

After running benchmarks, you can drop the database:

```bash
dropdb snowflaked_benchmark
```

## What's Being Measured

The benchmarks compare two approaches to record creation:

1. **Snowflake ID**: Records using Snowflaked gem with automatic ID generation
2. **Database-backed ID**: Records using Snowflaked gem with `snowflake_id id: false` to disable automatic ID generation

## Results

```log
Ruby version: 4.0.1
Rails version: 8.1.2
Snowflaked version: 0.1.4
YJIT: enabled

ruby 4.0.1 (2026-01-13 revision e04267a14b) +YJIT +PRISM [arm64-darwin25]
Warming up --------------------------------------
        Snowflake ID   652.000 i/100ms
 Database-backed ID    803.000 i/100ms
Calculating -------------------------------------
        Snowflake ID      7.923k (± 4.4%) i/s  (126.21 μs/i) -     39.772k in   5.030384s
        Database-backed ID    7.982k (± 3.3%) i/s  (125.28 μs/i) -     40.150k in   5.035898s

Comparison:
        Snowflake ID:     7923.3 i/s
 Database-backed ID :     7982.2 i/s - same-ish: difference falls within error
```
