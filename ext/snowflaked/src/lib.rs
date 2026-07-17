use arc_swap::ArcSwapOption;
use magnus::{function, prelude::*, Error, RHash, Ruby};
use snowflaked::sync::Generator;
use snowflaked::{Builder, Snowflake};
use std::sync::Arc;
use std::time::UNIX_EPOCH;

struct GeneratorState {
    generator: Generator,
    epoch_offset: u64,
    init_pid: u32,
}

static STATE: ArcSwapOption<GeneratorState> = ArcSwapOption::const_empty();

fn build_generator(machine_id: u16, epoch_offset: u64) -> Generator {
    let epoch = UNIX_EPOCH + std::time::Duration::from_millis(epoch_offset);
    Builder::new().instance(machine_id).epoch(epoch).build()
}

fn ensure_state(machine_id: u16, epoch_offset: u64, current_pid: u32) -> (Arc<GeneratorState>, bool) {
    if let Some(s) = &*STATE.load() {
        if s.init_pid == current_pid {
            return (Arc::clone(s), false);
        }
    }

    let new_state = Arc::new(GeneratorState {
        generator: build_generator(machine_id, epoch_offset),
        epoch_offset,
        init_pid: current_pid,
    });

    STATE.rcu(|current| {
        if let Some(c) = current {
            if c.init_pid == current_pid {
                return Arc::clone(c);
            }
        }
        Arc::clone(&new_state)
    });

    let state = STATE.load_full().expect("generator state should be initialized");
    let swapped = Arc::ptr_eq(&state, &new_state);

    (state, swapped)
}

fn init_generator(machine_id: u16, epoch_ms: Option<u64>) -> bool {
    let (_, swapped) = ensure_state(machine_id, epoch_ms.unwrap_or(0), std::process::id());
    swapped
}

fn current_state(ruby: &Ruby) -> Result<Arc<GeneratorState>, Error> {
    STATE
        .load_full()
        .filter(|s| s.init_pid == std::process::id())
        .ok_or_else(|| Error::new(ruby.exception_runtime_error(), "Generator not initialized"))
}

fn generate(ruby: &Ruby) -> Result<u64, Error> {
    let state = current_state(ruby)?;

    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| state.generator.generate::<i64>()))
        .map(|id| id as u64)
        .map_err(|_| Error::new(ruby.exception_runtime_error(), "Snowflaked: system clock moved backwards; cannot generate a monotonic ID"))
}

fn epoch_offset(ruby: &Ruby) -> Result<u64, Error> {
    current_state(ruby).map(|s| s.epoch_offset)
}

fn parse(ruby: &Ruby, id: u64) -> Result<RHash, Error> {
    let offset = epoch_offset(ruby)?;
    let hash = ruby.hash_new();

    hash.aset(ruby.to_symbol("timestamp_ms"), id.timestamp().saturating_add(offset))?;
    hash.aset(ruby.to_symbol("machine_id"), id.instance())?;
    hash.aset(ruby.to_symbol("sequence"), id.sequence())?;

    Ok(hash)
}

fn timestamp_ms(ruby: &Ruby, id: u64) -> Result<u64, Error> {
    epoch_offset(ruby).map(|offset| id.timestamp().saturating_add(offset))
}

fn machine_id_from_id(id: u64) -> u64 {
    id.instance()
}

fn sequence(id: u64) -> u64 {
    id.sequence()
}

fn is_initialized() -> bool {
    STATE.load().as_ref().is_some_and(|s| s.init_pid == std::process::id())
}

// The generator panics when the clock steps backwards; generate() catches it
// and raises a Ruby error, but the default panic hook would still print a
// message and backtrace to stderr on every call. Silence only that panic.
fn install_panic_hook() {
    let prev = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let clock_panic = info
            .payload()
            .downcast_ref::<&str>()
            .copied()
            .or_else(|| info.payload().downcast_ref::<String>().map(String::as_str))
            .is_some_and(|msg| msg.contains("Clock has moved backwards") || msg.contains("clock went backwards"));

        if !clock_panic {
            prev(info);
        }
    }));
}

#[magnus::init]
fn init(ruby: &Ruby) -> Result<(), Error> {
    install_panic_hook();

    let module = ruby.define_module("Snowflaked")?;
    let internal = module.define_module("Native")?;

    internal.define_singleton_method("init_generator", function!(init_generator, 2))?;
    internal.define_singleton_method("generate", function!(generate, 0))?;
    internal.define_singleton_method("parse", function!(parse, 1))?;
    internal.define_singleton_method("timestamp_ms", function!(timestamp_ms, 1))?;
    internal.define_singleton_method("machine_id", function!(machine_id_from_id, 1))?;
    internal.define_singleton_method("sequence", function!(sequence, 1))?;
    internal.define_singleton_method("initialized?", function!(is_initialized, 0))?;

    Ok(())
}
