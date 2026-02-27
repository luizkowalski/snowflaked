use arc_swap::ArcSwapOption;
use magnus::{function, prelude::*, Error, RHash, Ruby};
use snowflaked::sync::Generator;
use snowflaked::{Builder, Snowflake};
use std::sync::Arc;
use std::time::UNIX_EPOCH;

struct GeneratorState {
    generator: Generator,
    epoch_offset: u64,
    machine_id: u16,
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
        machine_id,
        init_pid: current_pid,
    });

    let prev_state = STATE.rcu(|current| {
        if let Some(c) = current {
            if c.init_pid == current_pid {
                return Arc::clone(c);
            }
        }
        Arc::clone(&new_state)
    });

    let swapped = prev_state.is_none_or(|s| s.init_pid != current_pid);
    (Arc::clone(STATE.load().as_ref().unwrap()), swapped)
}

fn init_generator(machine_id: u16, epoch_ms: Option<u64>) -> bool {
    let (_, swapped) = ensure_state(machine_id, epoch_ms.unwrap_or(0), std::process::id());
    swapped
}

fn validate_config(ruby: &Ruby, s: &GeneratorState, machine_id: u16, epoch_offset: u64) -> Result<(), Error> {
    if s.machine_id != machine_id || s.epoch_offset != epoch_offset {
        return Err(Error::new(
            ruby.exception_runtime_error(),
            "Generator already initialized with a different machine_id or epoch for this process",
        ));
    }
    Ok(())
}

fn generate(ruby: &Ruby, machine_id: u16, epoch_ms: Option<u64>) -> Result<u64, Error> {
    let epoch_offset = epoch_ms.unwrap_or(0);
    let (state, _) = ensure_state(machine_id, epoch_offset, std::process::id());

    validate_config(ruby, &state, machine_id, epoch_offset)?;
    Ok(state.generator.generate())
}

fn epoch_offset(ruby: &Ruby) -> Result<u64, Error> {
    STATE
        .load()
        .as_ref()
        .map(|s| s.epoch_offset)
        .ok_or_else(|| Error::new(ruby.exception_runtime_error(), "Generator not initialized"))
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

fn configured_machine_id() -> Option<u16> {
    STATE.load().as_ref().filter(|s| s.init_pid == std::process::id()).map(|s| s.machine_id)
}

#[magnus::init]
fn init(ruby: &Ruby) -> Result<(), Error> {
    let module = ruby.define_module("Snowflaked")?;
    let internal = module.define_module("Native")?;

    internal.define_singleton_method("init_generator", function!(init_generator, 2))?;
    internal.define_singleton_method("generate", function!(generate, 2))?;
    internal.define_singleton_method("parse", function!(parse, 1))?;
    internal.define_singleton_method("timestamp_ms", function!(timestamp_ms, 1))?;
    internal.define_singleton_method("machine_id", function!(machine_id_from_id, 1))?;
    internal.define_singleton_method("sequence", function!(sequence, 1))?;
    internal.define_singleton_method("initialized?", function!(is_initialized, 0))?;
    internal.define_singleton_method("configured_machine_id", function!(configured_machine_id, 0))?;

    Ok(())
}
