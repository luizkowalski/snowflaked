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

fn init_generator(machine_id: u16, epoch_ms: Option<u64>) -> bool {
    let current_pid = std::process::id();
    let epoch_offset = epoch_ms.unwrap_or(0);

    let new_state = Arc::new(GeneratorState {
        generator: build_generator(machine_id, epoch_offset),
        epoch_offset,
        machine_id,
        init_pid: current_pid,
    });

    let mut swapped = false;
    STATE.rcu(|current| {
        if let Some(c) = current {
            if c.init_pid == current_pid {
                swapped = false;
                return Arc::clone(c);
            }
        }
        swapped = true;
        Arc::clone(&new_state)
    });

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
    let current_pid = std::process::id();
    let epoch_offset = epoch_ms.unwrap_or(0);

    let state = STATE.load();
    if let Some(s) = &*state {
        if s.init_pid == current_pid {
            validate_config(ruby, s, machine_id, epoch_offset)?;
            return Ok(s.generator.generate());
        }
    }

    let new_state = Arc::new(GeneratorState {
        generator: build_generator(machine_id, epoch_offset),
        epoch_offset,
        machine_id,
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

    let final_state = STATE.load();
    if final_state.is_none() {
        return Err(Error::new(ruby.exception_runtime_error(), "final_state is none! This should be impossible!"));
    }

    let s = final_state.as_ref().unwrap();
    validate_config(ruby, s, machine_id, epoch_offset)?;
    Ok(s.generator.generate())
}

fn epoch_offset(ruby: &Ruby) -> Result<u64, Error> {
    let state = STATE.load();
    if let Some(s) = &*state {
        if s.init_pid == std::process::id() {
            return Ok(s.epoch_offset);
        }
    }

    if let Some(s) = &*state {
        return Ok(s.epoch_offset);
    }

    Err(Error::new(ruby.exception_runtime_error(), "Generator not initialized"))
}

fn parse(ruby: &Ruby, id: u64) -> Result<RHash, Error> {
    let hash = ruby.hash_new();
    let offset = epoch_offset(ruby)?;

    hash.aset(ruby.to_symbol("timestamp_ms"), id.timestamp().saturating_add(offset))?;
    hash.aset(ruby.to_symbol("machine_id"), id.instance())?;
    hash.aset(ruby.to_symbol("sequence"), id.sequence())?;

    Ok(hash)
}

fn timestamp_ms(ruby: &Ruby, id: u64) -> Result<u64, Error> {
    let offset = epoch_offset(ruby)?;
    Ok(id.timestamp().saturating_add(offset))
}

fn machine_id_from_id(id: u64) -> u64 {
    id.instance()
}

fn sequence(id: u64) -> u64 {
    id.sequence()
}

fn is_initialized() -> bool {
    let state = STATE.load();
    state.as_ref().is_some_and(|s| s.init_pid == std::process::id())
}

fn configured_machine_id() -> Option<u16> {
    let state = STATE.load();
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
