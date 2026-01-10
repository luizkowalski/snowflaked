use magnus::{function, prelude::*, Error, RHash, Ruby};
use snowflaked::sync::Generator;
use snowflaked::{Builder, Snowflake};
use std::sync::RwLock;
use std::time::UNIX_EPOCH;

struct GeneratorState {
    generator: Generator,
    epoch_offset: u64,
    machine_id: u16,
    init_pid: u32,
}

static STATE: RwLock<Option<GeneratorState>> = RwLock::new(None);

fn init_generator(machine_id: u16, epoch_ms: Option<u64>) -> bool {
    let current_pid = std::process::id();
    let epoch_offset = epoch_ms.unwrap_or(0);

    {
        let state = STATE.read().unwrap();
        if let Some(ref s) = *state {
            if s.init_pid == current_pid {
                return false;
            }
        }
    }

    let mut state = STATE.write().unwrap();

    if let Some(ref s) = *state {
        if s.init_pid == current_pid {
            return false;
        }
    }

    let epoch = UNIX_EPOCH + std::time::Duration::from_millis(epoch_offset);
    let generator = Builder::new().instance(machine_id).epoch(epoch).build();

    *state = Some(GeneratorState {
        generator,
        epoch_offset,
        machine_id,
        init_pid: current_pid,
    });

    true
}

fn generate(ruby: &Ruby) -> Result<u64, Error> {
    let state = STATE.read().unwrap();

    let s = state.as_ref().ok_or_else(|| {
        Error::new(
            ruby.exception_runtime_error(),
            "Generator not initialized. Call Snowflaked.configure or Snowflaked.id first.",
        )
    })?;

    if s.init_pid != std::process::id() {
        return Err(Error::new(
            ruby.exception_runtime_error(),
            "Fork detected: generator was initialized in a different process. This should not happen if using Snowflaked.id - please report this bug.",
        ));
    }

    Ok(s.generator.generate())
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
    state.as_ref().and_then(|s| if s.init_pid == std::process::id() { Some(s.machine_id) } else { None })
}

#[magnus::init]
fn init(ruby: &Ruby) -> Result<(), Error> {
    let module = ruby.define_module("Snowflaked")?;
    let internal = module.define_module("Native")?;

    internal.define_singleton_method("init_generator", function!(init_generator, 2))?;
    internal.define_singleton_method("generate", function!(generate, 0))?;
    internal.define_singleton_method("parse", function!(parse, 1))?;
    internal.define_singleton_method("timestamp_ms", function!(timestamp_ms, 1))?;
    internal.define_singleton_method("machine_id", function!(machine_id_from_id, 1))?;
    internal.define_singleton_method("sequence", function!(sequence, 1))?;
    internal.define_singleton_method("initialized?", function!(is_initialized, 0))?;
    internal.define_singleton_method("configured_machine_id", function!(configured_machine_id, 0))?;

    Ok(())
}
