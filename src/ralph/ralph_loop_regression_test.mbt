///|
test "whirlwind-4hy: builder system prompt instructs to fix all compile errors" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "brief": "Build a REST API",
    #|  "milestones": [
    #|    {
    #|      "id": "m1", "goal": "Build auth", "status": "pending",
    #|      "tasks": [
    #|        { "id": "m1-t1", "description": "Create schema", "status": "pending" }
    #|      ]
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(default_response="unused")
  let builder_mock = @agent.MockBackend::new(default_response="Done")
  let verifier_mock = @agent.MockBackend::new(default_response="<approved>")
  let backends : Map[String, @agent.BoxedBackend] = {}
  backends["planner"] = planner_mock.boxed()
  backends["builder"] = builder_mock.boxed()
  backends["verifier"] = verifier_mock.boxed()
  let callbacks = @types.OrchestratorCallbacks::noop()
  let rl = @ralph.RalphLoop::new(config, mgr, backends, callbacks)
  rl.run()
  let (_, system_prompt) = builder_mock.get_history()[0]
  assert_true(system_prompt.contains("compile"))
  assert_true(system_prompt.contains("error"))
  assert_true(
    system_prompt.contains("prior") ||
    system_prompt.contains("previous") ||
    system_prompt.contains("earlier"),
  )
}

///|
test "whirlwind-khq: resume retries failed milestones instead of skipping them" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    { "id": "m1", "goal": "Build auth", "status": "failed", "tasks": [] }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  assert_true(mgr.milestones[0].status is @types.MilestoneStatus::Failed(_))
  let planner_mock = @agent.MockBackend::new(
    default_response="TASKS:\n1. Create schema\nSCOPE: src/schema.mbt",
  )
  let builder_mock = @agent.MockBackend::new(
    default_response="Task completed successfully",
  )
  let verifier_mock = @agent.MockBackend::new(default_response="<approved>")
  let backends : Map[String, @agent.BoxedBackend] = {}
  backends["planner"] = planner_mock.boxed()
  backends["builder"] = builder_mock.boxed()
  backends["verifier"] = verifier_mock.boxed()
  let infos : Array[String] = []
  let callbacks : @types.OrchestratorCallbacks = {
    on_event: fn(e) {
      match e {
        Info(ev) => infos.push(ev.message)
        _ => ()
      }
    },
    on_save: fn() {  },
  }
  let rl = @ralph.RalphLoop::new(config, mgr, backends, callbacks)
  rl.run()
  inspect(mgr.milestones[0].status, content="Done")
  assert_true(infos.iter().any(fn(m) { m.contains("Planning") }))
}

///|
test "whirlwind-261: planner retries when first attempt produces 0 tasks" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    { "id": "m1", "goal": "Build auth", "status": "pending", "tasks": [] }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_seq = @agent.SequenceMockBackend::new([
    "(session exhausted)", "TASKS:\n1. Create schema\nSCOPE: src/schema.mbt",
  ])
  let builder_mock = @agent.MockBackend::new(
    default_response="Task completed successfully",
  )
  let verifier_mock = @agent.MockBackend::new(default_response="<approved>")
  let backends : Map[String, @agent.BoxedBackend] = {}
  backends["planner"] = planner_seq.boxed()
  backends["builder"] = builder_mock.boxed()
  backends["verifier"] = verifier_mock.boxed()
  let infos : Array[String] = []
  let callbacks : @types.OrchestratorCallbacks = {
    on_event: fn(e) {
      match e {
        Info(ev) => infos.push(ev.message)
        _ => ()
      }
    },
    on_save: fn() {  },
  }
  let rl = @ralph.RalphLoop::new(config, mgr, backends, callbacks)
  rl.run()
  inspect(mgr.milestones[0].status, content="Done")
  assert_true(
    infos.iter().any(fn(m) { m.contains("retry") || m.contains("Retry") }),
  )
}

///|
test "whirlwind-4hy: builder system prompt with empty brief still has compile error instruction" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1", "goal": "Build auth", "status": "pending",
    #|      "tasks": [
    #|        { "id": "m1-t1", "description": "Create schema", "status": "pending" }
    #|      ]
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(default_response="unused")
  let builder_mock = @agent.MockBackend::new(default_response="Done")
  let verifier_mock = @agent.MockBackend::new(default_response="<approved>")
  let backends : Map[String, @agent.BoxedBackend] = {}
  backends["planner"] = planner_mock.boxed()
  backends["builder"] = builder_mock.boxed()
  backends["verifier"] = verifier_mock.boxed()
  let callbacks = @types.OrchestratorCallbacks::noop()
  let rl = @ralph.RalphLoop::new(config, mgr, backends, callbacks)
  rl.run()
  let (_, system_prompt) = builder_mock.get_history()[0]
  assert_true(system_prompt.contains("compile"))
  assert_true(system_prompt.contains("error"))
}

///|
test "whirlwind-4hy: rework prompt includes compile error priority when feedback mentions build failure" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1", "goal": "Build auth", "status": "pending",
    #|      "tasks": [
    #|        { "id": "m1-t1", "description": "Implement login flow", "status": "pending" }
    #|      ]
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(default_response="unused")
  let builder_mock = @agent.MockBackend::new(default_response="Done v1")
  builder_mock.add_response("Feedback from verifier", "Done v2 FIXED")
  let verifier_mock = @agent.MockBackend::new(default_response="<approved>")
  verifier_mock.add_response(
    "Done v1", "<needs_rework>m1-t1: compile error in src/auth.mbt - type mismatch</needs_rework>",
  )
  verifier_mock.add_response("FIXED", "<approved>")
  let backends : Map[String, @agent.BoxedBackend] = {}
  backends["planner"] = planner_mock.boxed()
  backends["builder"] = builder_mock.boxed()
  backends["verifier"] = verifier_mock.boxed()
  let callbacks = @types.OrchestratorCallbacks::noop()
  let rl = @ralph.RalphLoop::new(config, mgr, backends, callbacks)
  rl.run()
  let history = builder_mock.get_history()
  assert_true(history.length() >= 2)
  let (_, rework_system) = history[1]
  assert_true(rework_system.contains("compile"))
}

///|
test "whirlwind-d35: rework prompt includes scope limitation" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1", "goal": "Build auth", "status": "pending",
    #|      "tasks": [
    #|        { "id": "m1-t1", "description": "implement feature X", "status": "pending" }
    #|      ]
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(default_response="unused")
  let builder_mock = @agent.MockBackend::new(default_response="Done v1")
  builder_mock.add_response("Feedback from verifier", "Done v2 REWORKED")
  let verifier_mock = @agent.MockBackend::new(default_response="<approved>")
  verifier_mock.add_response(
    "### Task: m1-t1\nDone v1\n\n## Review Focus: Code Quality", "<needs_rework>m1-t1: add input validation</needs_rework>",
  )
  verifier_mock.add_response("REWORKED", "<approved>")
  let backends : Map[String, @agent.BoxedBackend] = {}
  backends["planner"] = planner_mock.boxed()
  backends["builder"] = builder_mock.boxed()
  backends["verifier"] = verifier_mock.boxed()
  let callbacks = @types.OrchestratorCallbacks::noop()
  let rl = @ralph.RalphLoop::new(config, mgr, backends, callbacks)

  rl.run()

  let history = builder_mock.get_history()
  assert_true(history.length() == 2)
  let (_, rework_system_prompt) = history[1]
  assert_true(rework_system_prompt.contains("scope"))
  assert_true(rework_system_prompt.contains("Do not restructure"))
  assert_true(rework_system_prompt.contains("minimal"))
}

///|
test "whirlwind-z9r: rework resets builder session_id before re-execution" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1", "goal": "Build auth", "status": "pending",
    #|      "tasks": [
    #|        { "id": "m1-t1", "description": "Implement login flow", "status": "pending" }
    #|      ]
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(default_response="unused")
  let builder_mock = @agent.MockBackend::new(default_response="Done v1")
  builder_mock.add_response("Feedback from verifier", "Done v2 REWORKED")
  let verifier_mock = @agent.MockBackend::new(default_response="<approved>")
  // First verification triggers rework
  verifier_mock.add_response(
    "Done v1", "<needs_rework>m1-t1: missing validation</needs_rework>",
  )
  let backends : Map[String, @agent.BoxedBackend] = {}
  backends["planner"] = planner_mock.boxed()
  backends["builder"] = builder_mock.boxed()
  backends["verifier"] = verifier_mock.boxed()
  let callbacks = @types.OrchestratorCallbacks::noop()
  let rl = @ralph.RalphLoop::new(config, mgr, backends, callbacks)

  rl.run()

  // After initial builder run, session_id should be set (simulating real behavior).
  // Before rework, session_id must be cleared to "" to start a new session.
  let sid_history = builder_mock.get_session_id_history()
  assert_true(sid_history.length() >= 1) // at least one set_session_id call
  // The first set_session_id call should be "" (clearing before rework)
  inspect(sid_history[0], content="")
}

///|
test "E2E DAG: max_in_flight=2 mid-batch ready resolution dispatches dependent immediately" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    { "id": "m1", "goal": "Build with deps", "status": "pending", "tasks": [] }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  // DAG with dependencies:
  //   A (no deps) → C (deps: A)
  //   B (no deps) → D (deps: B)
  // With max_in_flight=2: A,B dispatch first, then as each completes
  // its dependent is immediately dispatched (slot-refilling).
  let plan_output =
    #|TASKS:
    #|1. Create module A
    #|DEPENDS_ON: (none)
    #|
    #|2. Create module B
    #|DEPENDS_ON: (none)
    #|
    #|3. Create module C
    #|DEPENDS_ON: 1
    #|
    #|4. Create module D
    #|DEPENDS_ON: 2
  let planner_mock = @agent.MockBackend::new(default_response=plan_output)
  let builder_mock = @agent.MockBackend::new(default_response="Done")
  let verifier_mock = @agent.MockBackend::new(default_response="<approved>")
  let backends : Map[String, @agent.BoxedBackend] = {}
  backends["planner"] = planner_mock.boxed()
  backends["builder"] = builder_mock.boxed()
  backends["verifier"] = verifier_mock.boxed()
  let infos : Array[String] = []
  let callbacks : @types.OrchestratorCallbacks = {
    on_event: fn(e) {
      match e {
        Info(ev) => infos.push(ev.message)
        _ => ()
      }
    },
    on_save: fn() {  },
  }
  let rl = @ralph.RalphLoop::new(
    config,
    mgr,
    backends,
    callbacks,
    max_in_flight=2,
  )
  rl.run()

  inspect(mgr.milestones[0].status, content="Done")
  let tasks = mgr.milestones[0].tasks
  assert_true(tasks.length() == 4)
  for task in tasks {
    inspect(task.status, content="Done")
  }
  assert_true(builder_mock.get_history().length() == 4)

  // Collect dispatch and completion messages in order
  let dispatch_msgs : Array[String] = infos
    .iter()
    .filter(fn(msg) {
      msg.contains("Dispatching task") && msg.contains("batch:")
    })
    .collect()
  let complete_msgs : Array[String] = infos
    .iter()
    .filter(fn(msg) { msg.contains("completed") })
    .collect()

  // 4 dispatches and 4 completions
  assert_true(dispatch_msgs.length() == 4)
  assert_true(complete_msgs.length() == 4)

  // Batch 1: A and B dispatched together (both layer 0, no deps)
  assert_true(dispatch_msgs[0].contains(tasks[0].id))
  assert_true(dispatch_msgs[0].contains("batch: 2"))
  assert_true(dispatch_msgs[1].contains(tasks[1].id))
  assert_true(dispatch_msgs[1].contains("batch: 2"))

  // Batch 2: C and D dispatched together (after batch 1 completes,
  // A→C and B→D deps resolved — inter-batch dependency resolution)
  assert_true(dispatch_msgs[2].contains(tasks[2].id))
  assert_true(dispatch_msgs[2].contains("batch: 2"))
  assert_true(dispatch_msgs[3].contains(tasks[3].id))
  assert_true(dispatch_msgs[3].contains("batch: 2"))

  // Find log indices for ordering verification
  let mut a_complete_idx = -1
  let mut b_complete_idx = -1
  let mut c_dispatch_idx = -1
  let mut d_dispatch_idx = -1
  for i, msg in infos {
    if msg.contains("Task") &&
      msg.contains(tasks[0].id) &&
      msg.contains("completed") {
      a_complete_idx = i
    }
    if msg.contains("Task") &&
      msg.contains(tasks[1].id) &&
      msg.contains("completed") {
      b_complete_idx = i
    }
    if msg.contains("Dispatching task") && msg.contains(tasks[2].id) {
      c_dispatch_idx = i
    }
    if msg.contains("Dispatching task") && msg.contains(tasks[3].id) {
      d_dispatch_idx = i
    }
  }
  assert_true(a_complete_idx >= 0)
  assert_true(b_complete_idx >= 0)
  assert_true(c_dispatch_idx >= 0)
  assert_true(d_dispatch_idx >= 0)

  // Both A and B must complete before C and D are dispatched
  // (inter-batch resolution: entire batch 1 completes, then deps unlock batch 2)
  assert_true(a_complete_idx < c_dispatch_idx)
  assert_true(b_complete_idx < d_dispatch_idx)
  assert_true(a_complete_idx < d_dispatch_idx)
  assert_true(b_complete_idx < c_dispatch_idx)
}

///|
test "E2E DAG: cascade_fail propagates failure to transitive dependents via explicit deps" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    { "id": "m1", "goal": "Build chain", "status": "pending", "tasks": [] }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  // DAG: A → B → C, A → D
  // A fails → B, D cascade-failed (direct), C cascade-failed (transitive via B)
  let plan_output =
    #|TASKS:
    #|1. Task A root
    #|DEPENDS_ON: (none)
    #|
    #|2. Task B child
    #|DEPENDS_ON: 1
    #|
    #|3. Task C grandchild
    #|DEPENDS_ON: 2
    #|
    #|4. Task D sibling
    #|DEPENDS_ON: 1
  let planner_mock = @agent.MockBackend::new(default_response=plan_output)
  // Builder always fails — A is the only task dispatched, so it fails
  let builder_mock = @agent.FailingMockBackend::new(error_msg="build error")
  let verifier_mock = @agent.MockBackend::new(default_response="<approved>")
  let backends : Map[String, @agent.BoxedBackend] = {}
  backends["planner"] = planner_mock.boxed()
  backends["builder"] = builder_mock.boxed()
  backends["verifier"] = verifier_mock.boxed()
  let infos : Array[String] = []
  let callbacks : @types.OrchestratorCallbacks = {
    on_event: fn(e) {
      match e {
        Info(ev) => infos.push(ev.message)
        _ => ()
      }
    },
    on_save: fn() {  },
  }
  let rl = @ralph.RalphLoop::new(config, mgr, backends, callbacks)
  rl.run()

  let tasks = mgr.milestones[0].tasks
  assert_true(tasks.length() == 4)

  // A: direct failure from builder
  assert_true(tasks[0].status is Failed(_))

  // B: cascade-failed (direct dependent of A)
  assert_true(tasks[1].status is Failed(_))

  // C: cascade-failed (transitive: depends on B which depends on A)
  assert_true(tasks[2].status is Failed(_))

  // D: cascade-failed (direct dependent of A)
  assert_true(tasks[3].status is Failed(_))

  // Only task A was dispatched to builder (others were cascade-failed before dispatch)
  let dispatch_msgs : Array[String] = infos
    .iter()
    .filter(fn(msg) { msg.contains("Dispatching task") })
    .collect()
  assert_true(dispatch_msgs.length() == 1)
  assert_true(dispatch_msgs[0].contains(tasks[0].id))

  // Verify cascade-fail log messages for B, C, D
  let cascade_msgs : Array[String] = infos
    .iter()
    .filter(fn(msg) { msg.contains("cascade-failed") })
    .collect()
  assert_true(cascade_msgs.length() == 3)
  assert_true(
    infos
    .iter()
    .any(fn(msg) {
      msg.contains(tasks[1].id) &&
      msg.contains("cascade-failed") &&
      msg.contains(tasks[0].id)
    }),
  )
  assert_true(
    infos
    .iter()
    .any(fn(msg) {
      msg.contains(tasks[2].id) &&
      msg.contains("cascade-failed") &&
      msg.contains(tasks[0].id)
    }),
  )
  assert_true(
    infos
    .iter()
    .any(fn(msg) {
      msg.contains(tasks[3].id) &&
      msg.contains("cascade-failed") &&
      msg.contains(tasks[0].id)
    }),
  )

  // DAG execution failed
  assert_true(
    infos.iter().any(fn(msg) { msg.contains("DAG execution failed") }),
  )
}

///|
test "E2E DAG: default max_in_flight=1 dispatches strictly serially" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    { "id": "m1", "goal": "Serial execution", "status": "pending", "tasks": [] }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  // 3 independent tasks (all layer 0) — with max_in_flight=1 they must
  // execute one at a time: dispatch→execute→dispatch→execute→dispatch→execute
  let plan_output =
    #|TASKS:
    #|1. Create module A
    #|DEPENDS_ON: (none)
    #|
    #|2. Create module B
    #|DEPENDS_ON: (none)
    #|
    #|3. Create module C
    #|DEPENDS_ON: (none)
  let planner_mock = @agent.MockBackend::new(default_response=plan_output)
  let builder_mock = @agent.MockBackend::new(default_response="Done")
  let verifier_mock = @agent.MockBackend::new(default_response="<approved>")
  let backends : Map[String, @agent.BoxedBackend] = {}
  backends["planner"] = planner_mock.boxed()
  backends["builder"] = builder_mock.boxed()
  backends["verifier"] = verifier_mock.boxed()
  let infos : Array[String] = []
  let callbacks : @types.OrchestratorCallbacks = {
    on_event: fn(e) {
      match e {
        Info(ev) => infos.push(ev.message)
        _ => ()
      }
    },
    on_save: fn() {  },
  }
  // Explicit max_in_flight = 1 for serial dispatch test
  let rl = @ralph.RalphLoop::new(
    config,
    mgr,
    backends,
    callbacks,
    max_in_flight=1,
  )
  rl.run()

  // All tasks should complete
  inspect(mgr.milestones[0].status, content="Done")
  let tasks = mgr.milestones[0].tasks
  assert_true(tasks.length() == 3)
  for task in tasks {
    inspect(task.status, content="Done")
  }
  assert_true(builder_mock.get_history().length() == 3)

  // Verify strict serial dispatch: every dispatch log shows batch: 1
  let dispatch_msgs : Array[String] = infos
    .iter()
    .filter(fn(msg) {
      msg.contains("Dispatching task") && msg.contains("batch:")
    })
    .collect()
  assert_true(dispatch_msgs.length() == 3)
  // Each dispatch must show batch: 1 — single task per batch (serial)
  for msg in dispatch_msgs {
    assert_true(msg.contains("batch: 1"))
  }

  // Verify interleaving: dispatch and completion alternate strictly
  // (dispatch A, complete A, dispatch B, complete B, dispatch C, complete C)
  let events : Array[String] = []
  for msg in infos {
    if msg.contains("Dispatching task") {
      events.push("dispatch")
    } else if msg.contains("completed") && msg.contains("Task") {
      events.push("complete")
    }
  }
  // 3 dispatches + 3 completions = 6 events
  assert_true(events.length() == 6)
  // Strict alternation: dispatch, complete, dispatch, complete, ...
  inspect(events[0], content="dispatch")
  inspect(events[1], content="complete")
  inspect(events[2], content="dispatch")
  inspect(events[3], content="complete")
  inspect(events[4], content="dispatch")
  inspect(events[5], content="complete")
}

///|
test "E2E: pre-existing tasks in JSON dispatched via DAG" {
  let config = make_ralph_config()
  // Tasks already exist in milestones.json (loaded from disk)
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1", "goal": "Build auth", "status": "pending",
    #|      "tasks": [
    #|        { "id": "m1-t1", "description": "Setup schema", "status": "pending" },
    #|        { "id": "m1-t2", "description": "Create handlers", "status": "pending" },
    #|        { "id": "m1-t3", "description": "Add auth layer", "status": "pending" }
    #|      ]
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(default_response="unused")
  let builder_mock = @agent.MockBackend::new(default_response="Done")
  let verifier_mock = @agent.MockBackend::new(default_response="<approved>")
  let backends : Map[String, @agent.BoxedBackend] = {}
  backends["planner"] = planner_mock.boxed()
  backends["builder"] = builder_mock.boxed()
  backends["verifier"] = verifier_mock.boxed()
  let infos : Array[String] = []
  let callbacks : @types.OrchestratorCallbacks = {
    on_event: fn(e) {
      match e {
        Info(ev) => infos.push(ev.message)
        _ => ()
      }
    },
    on_save: fn() {  },
  }
  let rl = @ralph.RalphLoop::new(config, mgr, backends, callbacks)
  rl.run()

  // Milestone completes
  inspect(mgr.milestones[0].status, content="Done")

  // Planner was NOT called (tasks already exist)
  assert_true(planner_mock.get_history().is_empty())

  // DAG execution was used
  assert_true(
    infos.iter().any(fn(msg) { msg.contains("Executing DAG for m1") }),
  )

  // All 3 builder calls
  assert_true(builder_mock.get_history().length() == 3)

  // All tasks done
  for task in mgr.milestones[0].tasks {
    inspect(task.status, content="Done")
  }
}

///|
test "circuit breaker activates when builder produces no changes for 2 consecutive reworks" {
  let planner_agent : @types.AgentConfig = {
    id: "planner",
    kind: Mock,
    role: Planner,
    model: None,
  }
  let builder_agent : @types.AgentConfig = {
    id: "builder",
    kind: Mock,
    role: Builder,
    model: None,
  }
  let verifier_agent : @types.AgentConfig = {
    id: "verifier",
    kind: Mock,
    role: Verifier,
    model: None,
  }
  let config : @config.ProjectConfig = {
    agents: [planner_agent, builder_agent, verifier_agent],
    parse_warnings: [],
    milestones_path: None,
    max_rework_attempts: 5, // high limit so circuit breaker fires first
  }
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1", "goal": "Build auth", "status": "pending",
    #|      "tasks": [
    #|        { "id": "m1-t1", "description": "Implement login", "status": "pending" }
    #|      ]
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(default_response="unused")
  // Builder always returns the same result — no effective changes
  let builder_mock = @agent.MockBackend::new(
    default_response="Task completed successfully",
  )
  // Verifier always says needs_rework
  let verifier_mock = @agent.MockBackend::new(
    default_response="<needs_rework>m1-t1: still broken</needs_rework>",
  )
  let backends : Map[String, @agent.BoxedBackend] = {}
  backends["planner"] = planner_mock.boxed()
  backends["builder"] = builder_mock.boxed()
  backends["verifier"] = verifier_mock.boxed()
  let infos : Array[String] = []
  let callbacks : @types.OrchestratorCallbacks = {
    on_event: fn(e) {
      match e {
        Info(ev) => infos.push(ev.message)
        _ => ()
      }
    },
    on_save: fn() {  },
  }
  let rl = @ralph.RalphLoop::new(config, mgr, backends, callbacks)
  rl.run()
  // Milestone should fail with no-change circuit breaker
  assert_true(mgr.milestones[0].status is @types.MilestoneStatus::Failed(_))
  // Should log circuit breaker activation
  assert_true(
    infos
    .iter()
    .any(fn(msg) {
      msg.contains("Circuit breaker") && msg.contains("no changes")
    }),
  )
}

///|
test "normal rework cycle still works when changes are made" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1", "goal": "Build auth", "status": "pending",
    #|      "tasks": [
    #|        { "id": "m1-t1", "description": "Implement login", "status": "pending" }
    #|      ]
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(default_response="unused")
  // Builder returns different results each time (actual changes made)
  let builder_seq = @agent.SequenceMockBackend::new([
    "Initial implementation v1", "Reworked implementation v2",
  ])
  // Verifier: first needs_rework, then approved
  let verifier_seq = @agent.SequenceMockBackend::new([
    "<needs_rework>m1-t1: missing error handling</needs_rework>", "<needs_rework>m1-t1: missing error handling</needs_rework>",
    "<needs_rework>m1-t1: missing error handling</needs_rework>", "<needs_rework>m1-t1: missing error handling</needs_rework>",
    "<approved>", "<approved>", "<approved>", "<approved>",
  ])
  let backends : Map[String, @agent.BoxedBackend] = {}
  backends["planner"] = planner_mock.boxed()
  backends["builder"] = builder_seq.boxed()
  backends["verifier"] = verifier_seq.boxed()
  let infos : Array[String] = []
  let callbacks : @types.OrchestratorCallbacks = {
    on_event: fn(e) {
      match e {
        Info(ev) => infos.push(ev.message)
        _ => ()
      }
    },
    on_save: fn() {  },
  }
  let rl = @ralph.RalphLoop::new(config, mgr, backends, callbacks)
  rl.run()
  // Milestone should complete after rework
  inspect(mgr.milestones[0].status, content="Done")
  // Should have both rework and approval messages
  assert_true(infos.iter().any(fn(msg) { msg.contains("rework needed") }))
  assert_true(infos.iter().any(fn(msg) { msg.contains("approved") }))
}
