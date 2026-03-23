///|
/// Convert an FFI result string into a Result type.
/// FFI functions (JS interop) return error strings with "ERROR:" prefix.
/// This function centralizes that check so callers use Result instead of
/// raw string prefix matching.
pub fn check_ffi_error(raw : String) -> Result[String, String] {
  if raw.has_prefix("ERROR:") || raw.has_prefix("CRASH:") {
    Err(raw)
  } else {
    Ok(raw)
  }
}

///|
/// Check if an error string indicates a process crash (not a normal failure)
pub fn is_crash_error(err : String) -> Bool {
  err.has_prefix("CRASH:")
}

///|
/// Module-level flag tracking whether Codex is available.
/// Set to false after the first sandbox crash detection.
priv struct AvailabilityFlag {
  mut val : Bool
}

///|
let codex_available : AvailabilityFlag = { val: true }

///|
pub fn is_codex_available() -> Bool {
  codex_available.val
}

///|
pub fn mark_codex_unavailable() -> Unit {
  codex_available.val = false
}

///|
/// Reset Codex availability (for testing)
pub fn reset_codex_available() -> Unit {
  codex_available.val = true
}

///|
/// AgentBackend trait for executing tasks
pub(open) trait AgentBackend {
  run(
    Self,
    task : String,
    system_prompt : String,
    on_output : (@types.AgentEvent) -> Unit,
  ) -> @types.AgentResult
  name(Self) -> String
  set_session_id(Self, String) -> Unit
  get_session_id(Self) -> String
}

///|
/// BoxedBackend for dynamic dispatch
pub struct BoxedBackend {
  inner : &AgentBackend
}

///|
/// Create a new BoxedBackend
pub fn BoxedBackend::new(backend : &AgentBackend) -> BoxedBackend {
  { inner: backend }
}

///|
/// Run the backend
pub fn BoxedBackend::run(
  self : BoxedBackend,
  task : String,
  system_prompt : String,
  on_output : (@types.AgentEvent) -> Unit,
) -> @types.AgentResult {
  self.inner.run(task, system_prompt, on_output)
}

///|
/// Get the backend name
pub fn BoxedBackend::name(self : BoxedBackend) -> String {
  self.inner.name()
}

///|
/// Set session id for resume
pub fn BoxedBackend::set_session_id(
  self : BoxedBackend,
  session_id : String,
) -> Unit {
  self.inner.set_session_id(session_id)
}

///|
/// Get session id
pub fn BoxedBackend::get_session_id(self : BoxedBackend) -> String {
  self.inner.get_session_id()
}
