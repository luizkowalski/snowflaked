use magnus::{function, prelude::*, Error, RHash, Ruby};
use snowflaked::sync::Generator;
use snowflaked::{Builder, Snowflake};
use std::sync::{Arc, RwLock};
use std::time::UNIX_EPOCH;

struct GeneratorState {
    generator: Generator,
    epoch_offset: u64,
    machine_id: u16,
    init_pid: u32,
}

static STATE: RwLock<Option<Arc<GeneratorState>>> = RwLock::new(None);

fn read_state<T>(f: impl FnOnce(Option<&GeneratorState>) -> T) -> T {
    let guard = STATE.read().unwrap_or_else(|e| e.into_inner());
    f(guard.as_ref().map(Arc::as_ref))
}

fn write_state<T>(f: impl FnOnce(&mut Option<Arc<GeneratorState>>) -> T) -> T {
    let mut guard = STATE.write().unwrap_or_else(|e| e.into_inner());
    f(&mut guard)
}

fn build_generator(machine_id: u16, epoch_offset: u64) -> Generator {
    let epoch = UNIX_EPOCH + std::time::Duration::from_millis(epoch_offset);
    Builder::new().instance(machine_id).epoch(epoch).build()
}

fn init_state(state: &mut Option<Arc<GeneratorState>>, machine_id: u16, epoch_offset: u64, pid: u32) {
    *state = Some(Arc::new(GeneratorState {
        generator: build_generator(machine_id, epoch_offset),
        epoch_offset,
        machine_id,
        init_pid: pid,
    }));
}

fn state_for_pid(pid: u32) -> Option<Arc<GeneratorState>> {
    let guard = STATE.read().unwrap_or_else(|e| e.into_inner());
    guard.as_ref().filter(|state| state.init_pid == pid).map(Arc::clone)
}

fn init_generator(machine_id: u16, epoch_ms: Option<u64>) -> bool {
    let current_pid = std::process::id();
    let epoch_offset = epoch_ms.unwrap_or(0);

    write_state(|state| {
        if state.as_ref().is_some_and(|s| s.init_pid == current_pid) {
            return false;
        }

        init_state(state, machine_id, epoch_offset, current_pid);
        true
    })
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
    let current_pid = std::process::id();
    let epoch_offset = epoch_ms.unwrap_or(0);

    if let Some(state) = state_for_pid(current_pid) {
        validate_config(ruby, &state, machine_id, epoch_offset)?;
        return Ok(state.generator.generate());
    }

    let state = {
        let mut guard = STATE.write().unwrap_or_else(|e| e.into_inner());

        if let Some(state) = guard.as_ref().filter(|state| state.init_pid == current_pid) {
            validate_config(ruby, state, machine_id, epoch_offset)?;
            Arc::clone(state)
        } else {
            init_state(&mut guard, machine_id, epoch_offset, current_pid);
            Arc::clone(guard.as_ref().unwrap())
        }
    };

    Ok(state.generator.generate())
}

fn epoch_offset() -> u64 {
    read_state(|s| s.map(|s| s.epoch_offset).unwrap_or(0))
}

fn timestamp_ms(id: u64) -> u64 {
    id.timestamp().saturating_add(epoch_offset())
}

fn parse(ruby: &Ruby, id: u64) -> Result<RHash, Error> {
    let hash = ruby.hash_new();
    let offset = epoch_offset();

    hash.aset(ruby.to_symbol("timestamp_ms"), id.timestamp().saturating_add(offset))?;
    hash.aset(ruby.to_symbol("machine_id"), id.instance())?;
    hash.aset(ruby.to_symbol("sequence"), id.sequence())?;

    Ok(hash)
}

fn machine_id_from_id(id: u64) -> u64 {
    id.instance()
}

fn sequence(id: u64) -> u64 {
    id.sequence()
}

fn is_initialized() -> bool {
    read_state(|s| s.is_some_and(|s| s.init_pid == std::process::id()))
}

fn configured_machine_id() -> Option<u16> {
    read_state(|s| s.and_then(|s| (s.init_pid == std::process::id()).then_some(s.machine_id)))
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
