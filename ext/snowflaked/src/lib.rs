use magnus::{function, prelude::*, Error, RHash, Ruby};
use snowflaked::sync::Generator;
use snowflaked::{Builder, Snowflake};
use std::sync::OnceLock;
use std::time::UNIX_EPOCH;

struct GeneratorState {
    generator: Generator,
    epoch_offset: u64,
    machine_id: u16,
}

static STATE: OnceLock<GeneratorState> = OnceLock::new();

fn init_generator(machine_id: u16, epoch_ms: Option<u64>) -> bool {
    let was_empty = STATE.get().is_none();
    let epoch_offset = epoch_ms.unwrap_or(0);

    STATE.get_or_init(|| {
        let epoch = UNIX_EPOCH + std::time::Duration::from_millis(epoch_offset);

        let generator = Builder::new().instance(machine_id).epoch(epoch).build();

        GeneratorState {
            generator,
            epoch_offset,
            machine_id,
        }
    });

    was_empty
}

fn generate(ruby: &Ruby) -> Result<u64, Error> {
    let state = STATE.get().ok_or_else(|| {
        Error::new(
            ruby.exception_runtime_error(),
            "Generator not initialized. Call Snowflaked.configure or Snowflaked.id first.",
        )
    })?;

    Ok(state.generator.generate())
}

fn timestamp_ms(id: u64) -> u64 {
    let timestamp_raw = id.timestamp();
    let epoch_offset = STATE.get().map(|s| s.epoch_offset).unwrap_or(0);
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
    STATE.get().is_some()
}

fn configured_machine_id() -> Option<u16> {
    STATE.get().map(|s| s.machine_id)
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
