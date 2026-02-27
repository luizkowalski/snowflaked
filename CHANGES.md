# Changelog

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
