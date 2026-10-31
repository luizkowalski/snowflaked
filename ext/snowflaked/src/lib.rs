//! Native half of the `snowflaked` gem, exposed to Ruby as `Snowflaked::Native`.
//!
//! One process-wide generator lives in [`STATE`], tagged with the fork generation
//! that built it. A `pthread_atfork` child handler bumps [`FORK_GENERATION`], so a
//! forked child sees a stale tag and rebuilds on first use with whatever machine id
//! Ruby resolves for it. Ruby owns configuration; this side only builds, reads, and
//! parses.

use std::any::Any;
use std::panic;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, UNIX_EPOCH};

use arc_swap::ArcSwapOption;
use magnus::value::{Lazy, StaticSymbol};
use magnus::{function, prelude::*, Error, RHash, Ruby};
use snowflaked::sync::Generator;
use snowflaked::{Builder, Snowflake};

/// Largest instance id the 10-bit machine field can hold; `Builder::instance_checked`
/// rejects anything above it.
const MAX_MACHINE_ID: u16 = 1023;

/// Panic messages `snowflaked` 1.0 raises when the clock steps backwards
/// (`sync.rs` in `generate` and `time.rs` in `SystemTime::elapsed`).
const CLOCK_PANIC_MESSAGES: [&str; 2] = ["Clock has moved backwards", "clock went backwards"];

static STATE: ArcSwapOption<GeneratorState> = ArcSwapOption::const_empty();
static FORK_GENERATION: AtomicU64 = AtomicU64::new(0);

static TIMESTAMP_MS: Lazy<StaticSymbol> = Lazy::new(|ruby| ruby.sym_new("timestamp_ms"));
static MACHINE_ID: Lazy<StaticSymbol> = Lazy::new(|ruby| ruby.sym_new("machine_id"));
static SEQUENCE: Lazy<StaticSymbol> = Lazy::new(|ruby| ruby.sym_new("sequence"));

struct GeneratorState {
    generator: Generator,
    epoch_ms: u64,
    generation: u64,
}

impl GeneratorState {
    fn new(ruby: &Ruby, machine_id: u16, epoch_ms: u64, generation: u64) -> Result<Self, Error> {
        let builder = Builder::new()
            .instance_checked(machine_id)
            .ok_or_else(|| Error::new(ruby.exception_arg_error(), format!("machine_id must be between 0 and {MAX_MACHINE_ID}, got {machine_id}")))?;
        let epoch = UNIX_EPOCH + Duration::from_millis(epoch_ms);
        let generator = builder.epoch(epoch).build();

        Ok(Self { generator, epoch_ms, generation })
    }

    fn is_current(&self) -> bool {
        self.generation == FORK_GENERATION.load(Ordering::Relaxed)
    }

    fn timestamp_ms(&self, id: u64) -> u64 {
        id.timestamp().saturating_add(self.epoch_ms)
    }
}

extern "C" fn on_fork_child() {
    FORK_GENERATION.fetch_add(1, Ordering::Relaxed);
}

fn is_initialized() -> bool {
    STATE.load().as_deref().is_some_and(GeneratorState::is_current)
}

fn init_generator(ruby: &Ruby, machine_id: u16, epoch_ms: Option<u64>) -> Result<bool, Error> {
    if is_initialized() {
        return Ok(false);
    }

    let generation = FORK_GENERATION.load(Ordering::Relaxed);
    let new_state = Arc::new(GeneratorState::new(ruby, machine_id, epoch_ms.unwrap_or(0), generation)?);

    STATE.rcu(|current| match current {
        Some(current) if current.generation == generation => Arc::clone(current),
        _ => Arc::clone(&new_state),
    });

    Ok(STATE.load().as_ref().is_some_and(|state| Arc::ptr_eq(state, &new_state)))
}

fn with_state<T>(ruby: &Ruby, f: impl FnOnce(&GeneratorState) -> T) -> Result<T, Error> {
    let guard = STATE.load();

    match guard.as_deref() {
        Some(state) if state.is_current() => Ok(f(state)),
        _ => Err(Error::new(ruby.exception_runtime_error(), "Generator not initialized")),
    }
}

fn generate(ruby: &Ruby) -> Result<i64, Error> {
    with_state(ruby, |state| panic::catch_unwind(|| state.generator.generate::<i64>()))?
        .map_err(|_| Error::new(ruby.exception_runtime_error(), "Snowflaked: system clock moved backwards; cannot generate a monotonic ID"))
}

fn parse(ruby: &Ruby, id: u64) -> Result<RHash, Error> {
    let timestamp_ms = with_state(ruby, |state| state.timestamp_ms(id))?;
    let hash = ruby.hash_new();

    hash.aset(ruby.get_inner(&TIMESTAMP_MS), timestamp_ms)?;
    hash.aset(ruby.get_inner(&MACHINE_ID), id.instance())?;
    hash.aset(ruby.get_inner(&SEQUENCE), id.sequence())?;

    Ok(hash)
}

fn timestamp_ms(ruby: &Ruby, id: u64) -> Result<u64, Error> {
    with_state(ruby, |state| state.timestamp_ms(id))
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

    // SAFETY: the child handler only touches an atomic, which is async-signal-safe,
    // and it stays registered for the life of the process because Ruby never unloads
    // extensions.
    let registered = unsafe { libc::pthread_atfork(None, None, Some(on_fork_child)) };
    if registered != 0 {
        return Err(Error::new(ruby.exception_runtime_error(), format!("pthread_atfork failed with code {registered}")));
    }

    install_panic_hook();

    Lazy::force(&TIMESTAMP_MS, ruby);
    Lazy::force(&MACHINE_ID, ruby);
    Lazy::force(&SEQUENCE, ruby);

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
