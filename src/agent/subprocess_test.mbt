// ── SubprocessBackend construction and name tests ──────────────────────────────────

///|
test "SubprocessBackend::new creates with empty session_id" {
  let backend = @agent.SubprocessBackend::new(@types.AgentKind::ClaudeCode)
  inspect(backend.get_session_id(), content="")
}

///|
test "SubprocessBackend::new with model parameter" {
  let backend = @agent.SubprocessBackend::new(
    @types.AgentKind::ClaudeCode,
    model="claude-sonnet-4-20250514",
  )
  inspect(backend.get_session_id(), content="")
}

///|
test "SubprocessBackend name returns claude-code for ClaudeCode kind" {
  let backend = @agent.SubprocessBackend::new(@types.AgentKind::ClaudeCode)
  let boxed = backend.boxed()
  inspect(boxed.name(), content="claude-code")
}

///|
test "SubprocessBackend name returns codex for Codex kind" {
  let backend = @agent.SubprocessBackend::new(@types.AgentKind::Codex)
  let boxed = backend.boxed()
  inspect(boxed.name(), content="codex")
}

///|
test "SubprocessBackend name returns subprocess for Mock kind" {
  let backend = @agent.SubprocessBackend::new(@types.AgentKind::Mock)
  let boxed = backend.boxed()
  inspect(boxed.name(), content="subprocess")
}

// ── Session ID management ──────────────────────────────────

///|
test "SubprocessBackend set_session_id and get_session_id roundtrip" {
  let backend = @agent.SubprocessBackend::new(@types.AgentKind::ClaudeCode)
  backend.set_session_id("session-xyz-789")
  inspect(backend.get_session_id(), content="session-xyz-789")
}

///|
test "SubprocessBackend set_session_id overwrites previous value" {
  let backend = @agent.SubprocessBackend::new(@types.AgentKind::ClaudeCode)
  backend.set_session_id("first")
  backend.set_session_id("second")
  inspect(backend.get_session_id(), content="second")
}

///|
test "SubprocessBackend session_id via BoxedBackend interface" {
  let backend = @agent.SubprocessBackend::new(@types.AgentKind::Codex)
  let boxed = backend.boxed()
  boxed.set_session_id("boxed-session")
  inspect(boxed.get_session_id(), content="boxed-session")
}

// ── BoxedBackend wrapping ──────────────────────────────────

///|
test "SubprocessBackend boxed wraps correctly" {
  let backend = @agent.SubprocessBackend::new(@types.AgentKind::ClaudeCode)
  let boxed = backend.boxed()
  inspect(boxed.name(), content="claude-code")
  // Session ID should propagate through BoxedBackend
  boxed.set_session_id("test-session")
  inspect(boxed.get_session_id(), content="test-session")
}
