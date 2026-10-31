//! Native half of the `snowflaked` gem, exposed to Ruby as `Snowflaked::Native`.
//!
//! One process-wide generator lives in [`STATE`], tagged with the pid that built
//! it. After a fork the child sees a foreign pid and rebuilds on first use with
//! whatever machine id Ruby resolves for it. Ruby owns configuration; this side
//! only builds, reads, and parses.

use std::any::Any;
use std::panic;
use std::process;
use std::sync::Arc;
use std::time::{Duration, UNIX_EPOCH};

use arc_swap::ArcSwapOption;
use magnus::{function, prelude::*, Error, RHash, Ruby};
use snowflaked::sync::Generator;
use snowflaked::{Builder, Snowflake};

/// Panic messages `snowflaked` 1.0 raises when the clock steps backwards
/// (`sync.rs` in `generate` and `time.rs` in `SystemTime::elapsed`).
const CLOCK_PANIC_MESSAGES: [&str; 2] = ["Clock has moved backwards", "clock went backwards"];

static STATE: ArcSwapOption<GeneratorState> = ArcSwapOption::const_empty();

struct GeneratorState {
    generator: Generator,
    epoch_ms: u64,
    pid: u32,
}

impl GeneratorState {
    fn new(machine_id: u16, epoch_ms: u64, pid: u32) -> Self {
        let epoch = UNIX_EPOCH + Duration::from_millis(epoch_ms);
        let generator = Builder::new().instance(machine_id).epoch(epoch).build();

        Self { generator, epoch_ms, pid }
    }

    fn owned_by(&self, pid: u32) -> bool {
        self.pid == pid
    }

    fn timestamp_ms(&self, id: u64) -> u64 {
        id.timestamp().saturating_add(self.epoch_ms)
    }
}

fn is_initialized() -> bool {
    STATE.load().as_ref().is_some_and(|state| state.owned_by(process::id()))
}

fn init_generator(machine_id: u16, epoch_ms: Option<u64>) -> bool {
    if is_initialized() {
        return false;
    }

    let pid = process::id();
    let new_state = Arc::new(GeneratorState::new(machine_id, epoch_ms.unwrap_or(0), pid));

    STATE.rcu(|current| match current {
        Some(current) if current.owned_by(pid) => Arc::clone(current),
        _ => Arc::clone(&new_state),
    });

    STATE.load().as_ref().is_some_and(|state| Arc::ptr_eq(state, &new_state))
}

fn current_state(ruby: &Ruby) -> Result<Arc<GeneratorState>, Error> {
    STATE
        .load_full()
        .filter(|state| state.owned_by(process::id()))
        .ok_or_else(|| Error::new(ruby.exception_runtime_error(), "Generator not initialized"))
}

fn generate(ruby: &Ruby) -> Result<i64, Error> {
    let state = current_state(ruby)?;

    panic::catch_unwind(|| state.generator.generate::<i64>())
        .map_err(|_| Error::new(ruby.exception_runtime_error(), "Snowflaked: system clock moved backwards; cannot generate a monotonic ID"))
}

fn parse(ruby: &Ruby, id: u64) -> Result<RHash, Error> {
    let state = current_state(ruby)?;
    let hash = ruby.hash_new();

    hash.aset(ruby.to_symbol("timestamp_ms"), state.timestamp_ms(id))?;
    hash.aset(ruby.to_symbol("machine_id"), id.instance())?;
    hash.aset(ruby.to_symbol("sequence"), id.sequence())?;

    Ok(hash)
}

fn timestamp_ms(ruby: &Ruby, id: u64) -> Result<u64, Error> {
    current_state(ruby).map(|state| state.timestamp_ms(id))
}

fn machine_id(id: u64) -> u64 {
    id.instance()
}

fn sequence(id: u64) -> u64 {
    id.sequence()
}

fn is_clock_panic(payload: &(dyn Any + Send)) -> bool {
    let message = payload.downcast_ref::<&str>().copied().or_else(|| payload.downcast_ref::<String>().map(String::as_str));

    message.is_some_and(|message| CLOCK_PANIC_MESSAGES.iter().any(|needle| message.contains(needle)))
}

/// `generate` turns the clock-backwards panic into a Ruby error, but the default
/// hook would still print a message and backtrace to stderr on every call.
fn install_panic_hook() {
    let default_hook = panic::take_hook();

    panic::set_hook(Box::new(move |info| {
        if !is_clock_panic(info.payload()) {
            default_hook(info);
        }
    }));
}

#[magnus::init]
fn init(ruby: &Ruby) -> Result<(), Error> {
    // SAFETY: Ruby calls `init` exactly once while loading the extension, on the
    // main Ractor, before any method below can run. This is what `RB_EXT_RACTOR_SAFE`
    // expands to in a C extension; magnus has no safe wrapper for it.
    unsafe { rb_sys::rb_ext_ractor_safe(true) };

    install_panic_hook();

    let native = ruby.define_module("Snowflaked")?.define_module("Native")?;

    native.define_singleton_method("init_generator", function!(init_generator, 2))?;
    native.define_singleton_method("generate", function!(generate, 0))?;
    native.define_singleton_method("parse", function!(parse, 1))?;
    native.define_singleton_method("timestamp_ms", function!(timestamp_ms, 1))?;
    native.define_singleton_method("machine_id", function!(machine_id, 1))?;
    native.define_singleton_method("sequence", function!(sequence, 1))?;
    native.define_singleton_method("initialized?", function!(is_initialized, 0))?;

    Ok(())
}
