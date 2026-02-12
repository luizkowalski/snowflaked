use magnus::{function, prelude::*, Error, RHash, Ruby};
use snowflaked::sync::Generator;
use snowflaked::{Builder, Snowflake};
use std::sync::RwLock;
use std::time::UNIX_EPOCH;

const GENERATOR_CONFIG_MISMATCH: &str = "Generator already initialized with a different machine_id or epoch for this process";

struct GeneratorState {
    generator: Generator,
    epoch_offset: u64,
    machine_id: u16,
    init_pid: u32,
}

static STATE: RwLock<Option<GeneratorState>> = RwLock::new(None);

fn build_generator(machine_id: u16, epoch_offset: u64) -> Generator {
    let epoch = UNIX_EPOCH + std::time::Duration::from_millis(epoch_offset);
    Builder::new().instance(machine_id).epoch(epoch).build()
}

fn validate_generator_config(ruby: &Ruby, state: &GeneratorState, machine_id: u16, epoch_offset: u64) -> Result<u64, Error> {
    if state.machine_id != machine_id || state.epoch_offset != epoch_offset {
        return Err(Error::new(ruby.exception_runtime_error(), GENERATOR_CONFIG_MISMATCH));
    }

    Ok(state.generator.generate())
}

fn init_generator(machine_id: u16, epoch_ms: Option<u64>) -> bool {
    let current_pid = std::process::id();
    let epoch_offset = epoch_ms.unwrap_or(0);

    let mut state = STATE.write().unwrap();

    if state.as_ref().is_some_and(|s| s.init_pid == current_pid) {
        return false;
    }

    let generator = build_generator(machine_id, epoch_offset);

    *state = Some(GeneratorState {
        generator,
        epoch_offset,
        machine_id,
        init_pid: current_pid,
    });

    true
}

fn generate(ruby: &Ruby, machine_id: u16, epoch_ms: Option<u64>) -> Result<u64, Error> {
    let current_pid = std::process::id();
    let epoch_offset = epoch_ms.unwrap_or(0);

    {
        let state = STATE.read().unwrap();
        if let Some(s) = state.as_ref() {
            if s.init_pid == current_pid {
                return validate_generator_config(ruby, s, machine_id, epoch_offset);
            }
        }
    }

    let mut state = STATE.write().unwrap();

    if let Some(s) = state.as_ref() {
        if s.init_pid == current_pid {
            return validate_generator_config(ruby, s, machine_id, epoch_offset);
        }
    }

    let generator = build_generator(machine_id, epoch_offset);
    let id = generator.generate();

    *state = Some(GeneratorState {
        generator,
        epoch_offset,
        machine_id,
        init_pid: current_pid,
    });

    Ok(id)
}

fn timestamp_ms(id: u64) -> u64 {
    let timestamp_raw = id.timestamp();
    let state = STATE.read().unwrap();
    let epoch_offset = state.as_ref().map(|s| s.epoch_offset).unwrap_or(0);
    timestamp_raw.saturating_add(epoch_offset)
}

fn parse(ruby: &Ruby, id: u64) -> Result<RHash, Error> {
    let hash = ruby.hash_new();

    hash.aset(ruby.to_symbol("timestamp_ms"), timestamp_ms(id))?;
    hash.aset(ruby.to_symbol("machine_id"), machine_id_from_id(id))?;
    hash.aset(ruby.to_symbol("sequence"), sequence(id))?;

    Ok(hash)
}

fn machine_id_from_id(id: u64) -> u64 {
    id.instance()
}

fn sequence(id: u64) -> u64 {
    id.sequence()
}

fn is_initialized() -> bool {
    let state = STATE.read().unwrap();
    state.as_ref().is_some_and(|s| s.init_pid == std::process::id())
}

fn configured_machine_id() -> Option<u16> {
    let state = STATE.read().unwrap();
    state.as_ref().and_then(|s| (s.init_pid == std::process::id()).then_some(s.machine_id))
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
