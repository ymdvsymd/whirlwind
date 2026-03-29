///|
fn make_test_ralph_loop(
  callbacks : @types.OrchestratorCallbacks,
) -> RalphLoop raise Failure {
  let config : @config.ProjectConfig = {
    agents: [],
    parse_warnings: [],
    milestones_path: None,
    max_rework_attempts: 1,
  }
  let json =
    #|{
    #|  "milestones": [
    #|    { "id": "m1", "goal": "test", "status": "pending", "tasks": [] }
    #|  ]
    #|}
  let mgr = MilestoneManager::load_from_json(json)
  let backends : Map[String, @agent.BoxedBackend] = {}
  RalphLoop::new(config, mgr, backends, callbacks)
}

///|
test "handle_event emits Info for Usage event with token counts" {
  let info_messages : Array[String] = []
  let callbacks : @types.OrchestratorCallbacks = {
    on_event: fn(e) {
      match e {
        Info(ev) => info_messages.push(ev.message)
        _ => ()
      }
    },
    on_save: fn() {  },
  }
  let rl = make_test_ralph_loop(callbacks)
  handle_event(
    rl,
    "agent-1",
    @types.AgentEvent::Usage(
      input_tokens=100,
      output_tokens=50,
      cache_read=10,
      cache_write=5,
      cost_usd=0.003,
    ),
  )
  assert_true(
    info_messages.length() > 0,
    msg="Usage event should emit an Info event",
  )
  let msg = info_messages[0]
  assert_true(msg.contains("100"), msg="should contain input token count")
  assert_true(msg.contains("50"), msg="should contain output token count")
  assert_true(msg.contains("0.003"), msg="should contain cost")
}

///|
test "handle_event emits Info for SessionId event" {
  let info_messages : Array[String] = []
  let callbacks : @types.OrchestratorCallbacks = {
    on_event: fn(e) {
      match e {
        Info(ev) => info_messages.push(ev.message)
        _ => ()
      }
    },
    on_save: fn() {  },
  }
  let rl = make_test_ralph_loop(callbacks)
  handle_event(rl, "agent-1", @types.AgentEvent::SessionId("sess-abc123"))
  assert_true(
    info_messages.length() > 0,
    msg="SessionId event should emit an Info event",
  )
  let msg = info_messages[0]
  assert_true(msg.contains("sess-abc123"), msg="should contain session id")
}

///|
test "handle_event deduplicates repeated SessionId events for same agent" {
  let info_messages : Array[String] = []
  let callbacks : @types.OrchestratorCallbacks = {
    on_event: fn(e) {
      match e {
        Info(ev) => info_messages.push(ev.message)
        _ => ()
      }
    },
    on_save: fn() {  },
  }
  let rl = make_test_ralph_loop(callbacks)
  // Same session ID sent 3 times for same agent
  handle_event(rl, "agent-1", @types.AgentEvent::SessionId("sess-dup"))
  handle_event(rl, "agent-1", @types.AgentEvent::SessionId("sess-dup"))
  handle_event(rl, "agent-1", @types.AgentEvent::SessionId("sess-dup"))
  let session_msgs = info_messages
    .iter()
    .filter(fn(m) { m.contains("[Session]") })
    .collect()
  assert_eq(
    session_msgs.length(),
    1,
    msg="duplicate SessionId should be suppressed, got " +
      session_msgs.length().to_string(),
  )
}

///|
test "handle_event still emits AgentOutput for OutputLine" {
  let output_lines : Array[String] = []
  let callbacks : @types.OrchestratorCallbacks = {
    on_event: fn(e) {
      match e {
        AgentOutput(ev) => output_lines.push(ev.line)
        _ => ()
      }
    },
    on_save: fn() {  },
  }
  let rl = make_test_ralph_loop(callbacks)
  handle_event(rl, "agent-1", @types.AgentEvent::OutputLine("hello world"))
  assert_eq(output_lines.length(), 1)
  assert_eq(output_lines[0], "hello world")
}

///|
test "handle_event handles all AgentEvent variants without panic" {
  let callbacks = @types.OrchestratorCallbacks::noop()
  let rl = make_test_ralph_loop(callbacks)
  // All 9 variants should be handled without panic
  handle_event(rl, "a1", @types.AgentEvent::OutputLine("line"))
  handle_event(rl, "a1", @types.AgentEvent::Info("info"))
  handle_event(
    rl,
    "a1",
    @types.AgentEvent::ToolCall(name="tool", input="input"),
  )
  handle_event(
    rl,
    "a1",
    @types.AgentEvent::ToolResult(name="tool", output="output"),
  )
  handle_event(
    rl,
    "a1",
    @types.AgentEvent::SubAgentStart(agent_type="builder", task="t1"),
  )
  handle_event(rl, "a1", @types.AgentEvent::SubAgentEnd(agent_type="builder"))
  handle_event(
    rl,
    "a1",
    @types.AgentEvent::StatusChange(@types.AgentStatus::Idle),
  )
  handle_event(rl, "a1", @types.AgentEvent::SessionId("sess-123"))
  handle_event(
    rl,
    "a1",
    @types.AgentEvent::Usage(
      input_tokens=1,
      output_tokens=2,
      cache_read=0,
      cache_write=0,
      cost_usd=0.0,
    ),
  )
}
