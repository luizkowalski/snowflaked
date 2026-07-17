# Changelog

## main

- fix: generate IDs in `before_create` instead of `before_validation`, so `save(validate: false)` gets IDs; `insert_all`/`upsert_all` still skip generation (documented). IDs are no longer available during validations
- fix: validate that `epoch` is a time-like value in the past; `epoch = nil` (Unix epoch) remains supported
- fix: silence the Rust panic output for the expected clock-backwards panic; it is still raised as a `RuntimeError`
- docs: warn that sharing a `machine_id` across processes (e.g. fixed `SNOWFLAKED_MACHINE_ID` with clustered Puma) can produce duplicate IDs; document auto-detection collision odds and clock-backwards behavior

# 0.3.0 (2026-07-17)

- feat: epoch now defaults to Jan 1st. 2024, old behavior can be maintained by setting epoch to nil in the configuration
- chore: dropped support to Rails <= 7.2 and ruby < 3.3
- fix: Ruby now owns configuration resolution and locks it before native extension initialization to prevent race conditions

## 0.2.0 (2026-02-27)

- feat: replace RwLock with arc-swap to prevent fork deadlocks and eliminate read contention (#20)
- fix: harden native extension against lock poisoning and reduce lock contention
- fix: performance improvements and consolidations (#15)

## 0.1.4 (2026-01-14)

- feat: optimize ID generation performance
- chore: added benchmarks

## 0.1.3 (2026-01-11)

- fix: memoize `table_exists?`
- fix: handle processing fork sharing the same PID

## 0.1.2 (2026-01-10)

- fix: correctly offset the epoch when configured
- chore: refresh appraisal gemfiles with latest Rails

## 0.1.1 (2026-01-09)

- Fix loading of precompiled extension for the current Ruby version

## 0.1.0 (2026-01-08)

- Initial release.
