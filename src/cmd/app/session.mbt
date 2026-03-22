// ── Session persistence ──────────────────────────────────────

///|
let session_file : String = ".whirlwind/session.json"

///|
/// Save session state to .whirlwind/session.json
fn save_session(state : @helpers.SessionState) -> Unit {
  let json = @helpers.session_to_json(state)
  ignore(exec_sync("mkdir -p .whirlwind"))
  write_file_sync(session_file, json)
}

///|
/// Load session state from disk
fn load_session() -> @helpers.SessionState? {
  let content = match read_file_result(session_file) {
    Err(_) => return None
    Ok(c) => c
  }
  @helpers.session_from_json(content)
}

///|
/// Clear saved session
fn clear_session() -> Unit {
  ignore(exec_sync("rm -f \{session_file}"))
}
