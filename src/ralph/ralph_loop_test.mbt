///|
fn make_ralph_config(ralph_enabled? : Bool = true) -> @config.ProjectConfig {
  let planner_agent : @types.AgentConfig = {
    id: "planner",
    kind: Mock,
    role: Planner,
    model: None,
    system_prompt: None,
    working_dir: ".",
    max_iterations: 10,
  }
  let builder_agent : @types.AgentConfig = {
    id: "builder",
    kind: Mock,
    role: Dev,
    model: None,
    system_prompt: None,
    working_dir: ".",
    max_iterations: 10,
  }
  let verifier_agent : @types.AgentConfig = {
    id: "verifier",
    kind: Mock,
    role: Verifier,
    model: None,
    system_prompt: None,
    working_dir: ".",
    max_iterations: 10,
  }
  {
    project_dir: ".",
    review_dir: "docs/reviews",
    max_review_cycles: 3,
    review_interval: 1,
    agents: [planner_agent, builder_agent, verifier_agent],
    parse_warnings: [],
    ralph_enabled,
    milestones_path: None,
    max_rework_attempts: 3,
  }
}

///|
test "RalphLoop full cycle with single milestone" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    { "id": "m1", "goal": "Build auth", "status": "pending", "tasks": [] }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(
    default_response="WAVE 0:\n1. Create schema\n2. Write tests",
  )
  let builder_mock = @agent.MockBackend::new(
    default_response="Task completed successfully",
  )
  let verifier_mock = @agent.MockBackend::new(
    default_response="<wave_approved>",
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
  // Milestone should be complete
  inspect(mgr.milestones[0].status, content="Done")
  // Should have info messages about progress
  assert_true(infos.iter().any(fn(m) { m.contains("Ralph loop started") }))
  assert_true(infos.iter().any(fn(m) { m.contains("Planning") }))
  assert_true(infos.iter().any(fn(m) { m.contains("Executing wave") }))
  assert_true(infos.iter().any(fn(m) { m.contains("approved") }))
  assert_true(infos.iter().any(fn(m) { m.contains("complete") }))
  // Phase should be AllComplete
  inspect(rl.current_phase, content="AllComplete")
}

///|
test "planner receives system prompt with brief and completed milestone summaries" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "brief": "Ship an auth service with audit logging.",
    #|  "milestones": [
    #|    {
    #|      "id": "m1",
    #|      "goal": "Setup project",
    #|      "status": "done",
    #|      "summary": "Initialized repo; added config",
    #|      "tasks": []
    #|    },
    #|    {
    #|      "id": "m2",
    #|      "goal": "Build auth",
    #|      "status": "pending",
    #|      "tasks": []
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(
    default_response="WAVE 0:\n1. Create schema",
  )
  let builder_mock = @agent.MockBackend::new(default_response="Done")
  let verifier_mock = @agent.MockBackend::new(
    default_response="<wave_approved>",
  )
  let backends : Map[String, @agent.BoxedBackend] = {}
  backends["planner"] = planner_mock.boxed()
  backends["builder"] = builder_mock.boxed()
  backends["verifier"] = verifier_mock.boxed()
  let callbacks = @types.OrchestratorCallbacks::noop()
  let rl = @ralph.RalphLoop::new(config, mgr, backends, callbacks)
  rl.run()
  let (_, system_prompt) = planner_mock.get_history()[0]
  assert_true(
    system_prompt.contains(
      "You are a planning agent that breaks down milestones into executable tasks.\n",
    ),
  )
  assert_true(
    system_prompt.contains(
      "Do NOT write to or modify files under .claude/plans/",
    ),
  )
  assert_true(
    system_prompt.contains(
      "## Brief\nShip an auth service with audit logging.\n\n",
    ),
  )
  assert_true(
    system_prompt.contains(
      "## Completed Milestones\n- m1: Initialized repo; added config\n",
    ),
  )
}

///|
test "builder receives system prompt with brief" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "brief": "Keep public APIs stable while refactoring internals.",
    #|  "milestones": [
    #|    {
    #|      "id": "m1", "goal": "Build auth", "status": "pending",
    #|      "tasks": [
    #|        { "id": "m1-t1", "description": "Create schema", "wave": 0, "status": "pending" }
    #|      ]
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(default_response="unused")
  let builder_mock = @agent.MockBackend::new(default_response="Done")
  let verifier_mock = @agent.MockBackend::new(
    default_response="<wave_approved>",
  )
  let backends : Map[String, @agent.BoxedBackend] = {}
  backends["planner"] = planner_mock.boxed()
  backends["builder"] = builder_mock.boxed()
  backends["verifier"] = verifier_mock.boxed()
  let callbacks = @types.OrchestratorCallbacks::noop()
  let rl = @ralph.RalphLoop::new(config, mgr, backends, callbacks)
  rl.run()
  let (_, system_prompt) = builder_mock.get_history()[0]
  let expected =
    #|## Brief
    #|Keep public APIs stable while refactoring internals.
    #|
  inspect(system_prompt, content=expected)
}

///|
test "completed milestone summary concatenates completed task descriptions" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1", "goal": "Build auth", "status": "pending",
    #|      "tasks": [
    #|        { "id": "m1-t1", "description": "Create schema", "wave": 0, "status": "pending" },
    #|        { "id": "m1-t2", "description": "Build handlers", "wave": 1, "status": "pending" }
    #|      ]
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(default_response="unused")
  let builder_mock = @agent.MockBackend::new(default_response="Done")
  let verifier_mock = @agent.MockBackend::new(
    default_response="<wave_approved>",
  )
  let backends : Map[String, @agent.BoxedBackend] = {}
  backends["planner"] = planner_mock.boxed()
  backends["builder"] = builder_mock.boxed()
  backends["verifier"] = verifier_mock.boxed()
  let callbacks = @types.OrchestratorCallbacks::noop()
  let rl = @ralph.RalphLoop::new(config, mgr, backends, callbacks)
  rl.run()
  inspect(mgr.milestones[0].summary, content="Create schema; Build handlers")
}

///|
test "RalphLoop with pre-planned tasks" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1", "goal": "Build auth", "status": "pending",
    #|      "tasks": [
    #|        { "id": "m1-t1", "description": "Create schema", "wave": 0, "status": "pending" }
    #|      ]
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(default_response="unused")
  let builder_mock = @agent.MockBackend::new(default_response="Schema created")
  let verifier_mock = @agent.MockBackend::new(
    default_response="<wave_approved>",
  )
  let backends : Map[String, @agent.BoxedBackend] = {}
  backends["planner"] = planner_mock.boxed()
  backends["builder"] = builder_mock.boxed()
  backends["verifier"] = verifier_mock.boxed()
  let callbacks = @types.OrchestratorCallbacks::noop()
  let rl = @ralph.RalphLoop::new(config, mgr, backends, callbacks)
  rl.run()
  inspect(mgr.milestones[0].status, content="Done")
  // Planner should not have been called since tasks were pre-planned
  assert_true(planner_mock.get_history().is_empty())
}

///|
test "RalphLoop logs resume progress for partially completed milestone" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1", "goal": "Build auth", "status": "in_progress",
    #|      "tasks": [
    #|        { "id": "m1-t1", "description": "Create schema", "wave": 0, "status": "done" },
    #|        { "id": "m1-t2", "description": "Write tests", "wave": 0, "status": "done" },
    #|        { "id": "m1-t3", "description": "Add handlers", "wave": 1, "status": "pending" }
    #|      ]
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(default_response="unused")
  let builder_mock = @agent.MockBackend::new(default_response="Done")
  let verifier_mock = @agent.MockBackend::new(
    default_response="<wave_approved>",
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
  assert_true(
    infos
    .iter()
    .any(fn(msg) {
      msg.contains("Resuming milestone m1: 2 of 3 tasks already done")
    }),
  )
}

///|
test "run_wave skips already-done tasks before submitting to builder" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1", "goal": "Resume auth", "status": "pending",
    #|      "tasks": [
    #|        { "id": "m1-t1", "description": "Create schema", "wave": 0, "status": "done", "result": "already finished" },
    #|        { "id": "m1-t2", "description": "Write tests", "wave": 0, "status": "done", "result": "already finished" },
    #|        { "id": "m1-t3", "description": "Write handlers", "wave": 0, "status": "pending" }
    #|      ]
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(default_response="unused")
  let builder_mock = @agent.MockBackend::new(default_response="fresh result")
  let verifier_mock = @agent.MockBackend::new(
    default_response="<wave_approved>",
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

  let history = builder_mock.get_history()
  assert_true(history.length() == 1)
  inspect(history[0].0, content="Write handlers")
  inspect(
    mgr.milestones[0].tasks[0].result.unwrap(),
    content="already finished",
  )
  inspect(
    mgr.milestones[0].tasks[1].result.unwrap(),
    content="already finished",
  )
  inspect(mgr.milestones[0].tasks[2].result.unwrap(), content="fresh result")
  assert_true(
    infos
    .iter()
    .any(fn(msg) { msg.contains("Wave 0: skipping 2 already-done tasks") }),
  )
}

///|
test "run_wave does not emit running logs for already-done tasks" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1", "goal": "Resume auth", "status": "pending",
    #|      "tasks": [
    #|        { "id": "m1-t1", "description": "Create schema", "wave": 0, "status": "done", "result": "already finished" },
    #|        { "id": "m1-t2", "description": "Write handlers", "wave": 0, "status": "pending" }
    #|      ]
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(default_response="unused")
  let builder_mock = @agent.MockBackend::new(default_response="fresh result")
  let verifier_mock = @agent.MockBackend::new(
    default_response="<wave_approved>",
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

  assert_true(
    not(infos.iter().any(fn(msg) { msg.contains("Running task m1-t1") })),
  )
  assert_true(infos.iter().any(fn(msg) { msg.contains("Running task m1-t2") }))
}

///|
test "resume skips already-done milestones" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1", "goal": "Completed milestone", "status": "done",
    #|      "tasks": [
    #|        { "id": "m1-t1", "description": "Create schema", "wave": 0, "status": "done", "result": "already finished" }
    #|      ]
    #|    },
    #|    {
    #|      "id": "m2", "goal": "Pending milestone", "status": "pending",
    #|      "tasks": [
    #|        { "id": "m2-t1", "description": "Write handlers", "wave": 0, "status": "pending" }
    #|      ]
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(default_response="unused")
  let builder_mock = @agent.MockBackend::new(default_response="fresh result")
  let verifier_mock = @agent.MockBackend::new(
    default_response="<wave_approved>",
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

  assert_true(planner_mock.get_history().is_empty())
  let history = builder_mock.get_history()
  assert_true(history.length() == 1)
  inspect(history[0].0, content="Write handlers")
  inspect(
    mgr.milestones[0].tasks[0].result.unwrap(),
    content="already finished",
  )
  inspect(mgr.milestones[1].tasks[0].result.unwrap(), content="fresh result")
  assert_true(
    not(infos.iter().any(fn(msg) { msg.contains("Planning milestone: m1") })),
  )
  assert_true(
    not(infos.iter().any(fn(msg) { msg.contains("Executing wave 0 of m1") })),
  )
  assert_true(
    not(infos.iter().any(fn(msg) { msg.contains("Resuming milestone m1:") })),
  )
  assert_true(
    not(infos.iter().any(fn(msg) { msg.contains("Running task m1-t1") })),
  )
  assert_true(
    infos.iter().any(fn(msg) { msg.contains("Executing wave 0 of m2") }),
  )
}

///|
test "RalphLoop with rework cycle at milestone verification" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    { "id": "m1", "goal": "Build auth", "status": "pending", "tasks": [] }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(
    default_response="WAVE 0:\n1. Create schema",
  )
  let builder_mock = @agent.MockBackend::new(default_response="Done")
  let verifier_mock = @agent.MockBackend::new(
    default_response="<wave_approved>",
  )
  verifier_mock.add_response(
    "Security", "<needs_rework>m1-t1: add validation</needs_rework>",
  )
  verifier_mock.add_response("REWORKED", "<wave_approved>")
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
  // Should have rework info from milestone verification
  assert_true(
    infos
    .iter()
    .any(fn(m) { m.contains("Rework needed") || m.contains("rework needed") }),
  )
  // Eventually reaches max rework and accepts
  assert_true(
    infos
    .iter()
    .any(fn(m) { m.contains("Max rework attempts") || m.contains("complete") }),
  )
}

///|
test "RalphLoop milestone failure at milestone verification" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    { "id": "m1", "goal": "Build auth", "status": "pending", "tasks": [] }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(
    default_response="WAVE 0:\n1. Create schema",
  )
  let builder_mock = @agent.MockBackend::new(default_response="Done")
  let verifier_mock = @agent.MockBackend::new(
    default_response="<milestone_failed>Architecture fundamentally flawed</milestone_failed>",
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
  // Milestone should be failed
  assert_true(mgr.milestones[0].status is @types.MilestoneStatus::Failed(_))
  assert_true(infos.iter().any(fn(m) { m.contains("failed") }))
}

///|
test "RalphLoop without verifier auto-approves" {
  let builder_agent : @types.AgentConfig = {
    id: "builder",
    kind: Mock,
    role: Dev,
    model: None,
    system_prompt: None,
    working_dir: ".",
    max_iterations: 10,
  }
  let planner_agent : @types.AgentConfig = {
    id: "planner",
    kind: Mock,
    role: Planner,
    model: None,
    system_prompt: None,
    working_dir: ".",
    max_iterations: 10,
  }
  let config : @config.ProjectConfig = {
    project_dir: ".",
    review_dir: "docs/reviews",
    max_review_cycles: 3,
    review_interval: 1,
    agents: [planner_agent, builder_agent],
    parse_warnings: [],
    ralph_enabled: true,
    milestones_path: None,
    max_rework_attempts: 3,
  }
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1", "goal": "Build auth", "status": "pending",
    #|      "tasks": [
    #|        { "id": "m1-t1", "description": "Create schema", "wave": 0, "status": "pending" }
    #|      ]
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(default_response="unused")
  let builder_mock = @agent.MockBackend::new(default_response="Done")
  let backends : Map[String, @agent.BoxedBackend] = {}
  backends["planner"] = planner_mock.boxed()
  backends["builder"] = builder_mock.boxed()
  let callbacks = @types.OrchestratorCallbacks::noop()
  let rl = @ralph.RalphLoop::new(config, mgr, backends, callbacks)
  rl.run()
  inspect(mgr.milestones[0].status, content="Done")
}

///|
test "RalphLoop multiple milestones" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1", "goal": "Setup", "status": "pending",
    #|      "tasks": [
    #|        { "id": "m1-t1", "description": "Init project", "wave": 0, "status": "pending" }
    #|      ]
    #|    },
    #|    {
    #|      "id": "m2", "goal": "Build API", "status": "pending",
    #|      "tasks": [
    #|        { "id": "m2-t1", "description": "Create routes", "wave": 0, "status": "pending" }
    #|      ]
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(default_response="unused")
  let builder_mock = @agent.MockBackend::new(default_response="Done")
  let verifier_mock = @agent.MockBackend::new(
    default_response="<wave_approved>",
  )
  let backends : Map[String, @agent.BoxedBackend] = {}
  backends["planner"] = planner_mock.boxed()
  backends["builder"] = builder_mock.boxed()
  backends["verifier"] = verifier_mock.boxed()
  let callbacks = @types.OrchestratorCallbacks::noop()
  let rl = @ralph.RalphLoop::new(config, mgr, backends, callbacks)
  rl.run()
  inspect(mgr.milestones[0].status, content="Done")
  inspect(mgr.milestones[1].status, content="Done")
  inspect(rl.current_phase, content="AllComplete")
}

///|
test "RalphLoop multi-wave execution" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    { "id": "m1", "goal": "Build", "status": "pending", "tasks": [] }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(
    default_response="WAVE 0:\n1. Setup\n\nWAVE 1:\n1. Build\n2. Test",
  )
  let builder_mock = @agent.MockBackend::new(default_response="Done")
  let verifier_mock = @agent.MockBackend::new(
    default_response="<wave_approved>",
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
  inspect(mgr.milestones[0].status, content="Done")
  // Should execute wave 0 and wave 1
  assert_true(infos.iter().any(fn(m) { m.contains("Executing wave 0") }))
  assert_true(infos.iter().any(fn(m) { m.contains("Executing wave 1") }))
  // Builder should have been called 3 times (1 in wave 0 + 2 in wave 1)
  assert_true(builder_mock.get_history().length() == 3)
}

///|
test "RalphLoop verifies all 4 perspectives after waves complete" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1", "goal": "Build auth", "status": "pending",
    #|      "tasks": [
    #|        { "id": "m1-t1", "description": "Create schema", "wave": 0, "status": "pending" }
    #|      ]
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(default_response="unused")
  let builder_mock = @agent.MockBackend::new(default_response="Done")
  let verifier_mock = @agent.MockBackend::new(
    default_response="<wave_approved>",
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

  inspect(mgr.milestones[0].status, content="Done")
  assert_true(
    infos.iter().any(fn(msg) { msg.contains("Verifying milestone m1") }),
  )
  assert_true(infos.iter().any(fn(msg) { msg.contains("approved") }))
  // 4 perspectives: CodeQuality, Performance, Security, GoalAlignment
  let history = verifier_mock.get_history()
  assert_true(history.length() == 4)
}

///|
test "RalphLoop multi-wave full cycle verifies all 4 perspectives once at milestone completion" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1", "goal": "Ship auth flow", "status": "pending",
    #|      "tasks": [
    #|        { "id": "m1-t1", "description": "Create schema", "wave": 0, "status": "pending" },
    #|        { "id": "m1-t2", "description": "Build handlers", "wave": 1, "status": "pending" },
    #|        { "id": "m1-t3", "description": "Add integration tests", "wave": 2, "status": "pending" }
    #|      ]
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(default_response="unused")
  let builder_mock = @agent.MockBackend::new(default_response="Done")
  let verifier_mock = @agent.MockBackend::new(
    default_response="<wave_approved>",
  )
  let backends : Map[String, @agent.BoxedBackend] = {}
  backends["planner"] = planner_mock.boxed()
  backends["builder"] = builder_mock.boxed()
  backends["verifier"] = verifier_mock.boxed()
  let rl = @ralph.RalphLoop::new(
    config,
    mgr,
    backends,
    @types.OrchestratorCallbacks::noop(),
  )

  rl.run()

  inspect(mgr.milestones[0].status, content="Done")
  let history = verifier_mock.get_history()
  // Only 4 verifier calls: one per perspective at milestone completion
  assert_true(history.length() == 4)
  // All prompts should contain all task results (by task ID)
  let (first_prompt, _) = history[0]
  assert_true(first_prompt.contains("m1-t1"))
  assert_true(first_prompt.contains("m1-t2"))
  assert_true(first_prompt.contains("m1-t3"))
}

///|
test "RalphLoop reworks milestone tasks during milestone verification" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1", "goal": "Build auth", "status": "pending",
    #|      "tasks": [
    #|        { "id": "m1-t1", "description": "Implement login flow", "wave": 0, "status": "pending" }
    #|      ]
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(default_response="unused")
  let builder_mock = @agent.MockBackend::new(default_response="Done v1")
  builder_mock.add_response("Feedback from verifier", "Done v2 REWORKED")
  let verifier_mock = @agent.MockBackend::new(
    default_response="<wave_approved>",
  )
  // First verification: Security perspective returns needs_rework
  // "Done v1" uniquely matches the first run's result content
  verifier_mock.add_response(
    "Done v1", "<needs_rework>m1-t1: missing end-to-end behavior</needs_rework>",
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

  inspect(mgr.milestones[0].status, content="Done")
  assert_true(
    infos
    .iter()
    .any(fn(msg) {
      msg.contains("rework needed for m1") || msg.contains("Rework needed")
    }),
  )
  let builder_history = builder_mock.get_history()
  assert_true(builder_history.length() == 2)
  let (rework_task, _) = builder_history[1]
  assert_true(rework_task.contains("Implement login flow"))
  assert_true(rework_task.contains("Feedback from verifier"))
  assert_true(mgr.milestones[0].tasks[0].result.unwrap().contains("REWORKED"))
}

///|
test "RalphLoop milestone verification rework cycle retries and then completes" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1", "goal": "Ship auth flow", "status": "pending",
    #|      "tasks": [
    #|        { "id": "m1-t1", "description": "Implement login flow", "wave": 0, "status": "pending" }
    #|      ]
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(default_response="unused")
  let builder_mock = @agent.MockBackend::new(default_response="Done v1")
  builder_mock.add_response("Feedback from verifier", "Done v2 REWORKED")
  let verifier_mock = @agent.MockBackend::new(
    default_response="<wave_approved>",
  )
  // "Done v1" uniquely matches first-run results, triggers rework
  verifier_mock.add_response(
    "Done v1", "<needs_rework>m1-t1: missing end-to-end behavior</needs_rework>",
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

  inspect(mgr.milestones[0].status, content="Done")
  assert_true(
    infos
    .iter()
    .any(fn(msg) { msg.contains("Verifying milestone m1 (attempt 1)") }),
  )
  assert_true(
    infos
    .iter()
    .any(fn(msg) {
      msg.contains("rework needed for m1") || msg.contains("Rework needed")
    }),
  )
  assert_true(
    infos
    .iter()
    .any(fn(msg) { msg.contains("Verifying milestone m1 (attempt 2)") }),
  )
  assert_true(infos.iter().any(fn(msg) { msg.contains("approved") }))

  let builder_history = builder_mock.get_history()
  assert_true(builder_history.length() == 2)
  let (rework_task, _) = builder_history[1]
  assert_true(rework_task.contains("Implement login flow"))
  inspect(
    mgr.milestones[0].tasks[0].result.unwrap(),
    content="Done v2 REWORKED",
  )
}

///|
test "RalphLoop fails milestone when goal alignment verification fails" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1", "goal": "Build auth", "status": "pending",
    #|      "tasks": [
    #|        { "id": "m1-t1", "description": "Create schema", "wave": 0, "status": "pending" }
    #|      ]
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(default_response="unused")
  let builder_mock = @agent.MockBackend::new(default_response="Done")
  let verifier_mock = @agent.MockBackend::new(
    default_response="<wave_approved>",
  )
  verifier_mock.add_response(
    "## Review Focus: Goal Alignment", "<milestone_failed>Milestone goal was not achieved</milestone_failed>",
  )
  let backends : Map[String, @agent.BoxedBackend] = {}
  backends["planner"] = planner_mock.boxed()
  backends["builder"] = builder_mock.boxed()
  backends["verifier"] = verifier_mock.boxed()
  let rl = @ralph.RalphLoop::new(
    config,
    mgr,
    backends,
    @types.OrchestratorCallbacks::noop(),
  )

  rl.run()

  assert_true(mgr.milestones[0].status is @types.MilestoneStatus::Failed(_))
}

///|
test "RalphLoop marks milestone failed when milestone verification returns milestone_failed" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1", "goal": "Build auth", "status": "pending",
    #|      "tasks": [
    #|        { "id": "m1-t1", "description": "Create schema", "wave": 0, "status": "pending" }
    #|      ]
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(default_response="unused")
  let builder_mock = @agent.MockBackend::new(default_response="Done")
  let verifier_mock = @agent.MockBackend::new(
    default_response="<milestone_failed>Milestone goal was not achieved</milestone_failed>",
  )
  let backends : Map[String, @agent.BoxedBackend] = {}
  backends["planner"] = planner_mock.boxed()
  backends["builder"] = builder_mock.boxed()
  backends["verifier"] = verifier_mock.boxed()
  let rl = @ralph.RalphLoop::new(
    config,
    mgr,
    backends,
    @types.OrchestratorCallbacks::noop(),
  )

  rl.run()

  let history = verifier_mock.get_history()
  // 4 perspectives called at milestone verification
  assert_true(history.length() == 4)
  assert_true(mgr.milestones[0].status is @types.MilestoneStatus::Failed(_))
}

///|
test "rework_tasks passes targeted feedback to specific task only" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1", "goal": "Build auth", "status": "pending",
    #|      "tasks": [
    #|        { "id": "m1-t1", "description": "Implement login flow", "wave": 0, "status": "pending" },
    #|        { "id": "m1-t2", "description": "Add audit logging", "wave": 0, "status": "pending" }
    #|      ]
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(default_response="unused")
  let builder_mock = @agent.MockBackend::new(default_response="Done v1")
  builder_mock.add_response("Feedback from verifier", "Done v2 REWORKED")
  let verifier_mock = @agent.MockBackend::new(
    default_response="<wave_approved>",
  )
  verifier_mock.add_response(
    "### Task: m1-t1\nDone v1\n\n### Task: m1-t2\nDone v1\n\n## Review Focus: Security",
    "<needs_rework>m1-t1: fix error handling</needs_rework>",
  )
  verifier_mock.add_response("REWORKED", "<wave_approved>")
  let backends : Map[String, @agent.BoxedBackend] = {}
  backends["planner"] = planner_mock.boxed()
  backends["builder"] = builder_mock.boxed()
  backends["verifier"] = verifier_mock.boxed()
  let callbacks = @types.OrchestratorCallbacks::noop()
  let rl = @ralph.RalphLoop::new(config, mgr, backends, callbacks)

  rl.run()

  let history = builder_mock.get_history()
  assert_true(history.length() == 3)
  let (initial_task_1, _) = history[0]
  let (initial_task_2, _) = history[1]
  let (rework_task, _) = history[2]
  inspect(initial_task_1, content="Implement login flow")
  inspect(initial_task_2, content="Add audit logging")
  assert_true(rework_task.contains("Implement login flow"))
  assert_true(
    rework_task.contains(
      "Feedback from verifier:\n- [Security] fix error handling",
    ),
  )
  assert_true(not(rework_task.contains("Add audit logging")))
  assert_true(mgr.milestones[0].tasks[0].result.unwrap().contains("REWORKED"))
  inspect(mgr.milestones[0].tasks[1].result.unwrap(), content="Done v1")
}

///|
test "rework_tasks resets all done tasks when feedback has no task ID (fallback)" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1", "goal": "Build auth", "status": "pending",
    #|      "tasks": [
    #|        { "id": "m1-t1", "description": "Implement login flow", "wave": 0, "status": "pending" },
    #|        { "id": "m1-t2", "description": "Add audit logging", "wave": 0, "status": "pending" }
    #|      ]
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(default_response="unused")
  let builder_mock = @agent.MockBackend::new(default_response="Done v1")
  builder_mock.add_response("Feedback from verifier", "Done v2 REWORKED")
  let verifier_mock = @agent.MockBackend::new(
    default_response="<wave_approved>",
  )
  verifier_mock.add_response(
    "### Task: m1-t1\nDone v1\n\n### Task: m1-t2\nDone v1\n\n## Review Focus: Security",
    "<needs_rework>general quality issues</needs_rework>",
  )
  verifier_mock.add_response("REWORKED", "<wave_approved>")
  let backends : Map[String, @agent.BoxedBackend] = {}
  backends["planner"] = planner_mock.boxed()
  backends["builder"] = builder_mock.boxed()
  backends["verifier"] = verifier_mock.boxed()
  let callbacks = @types.OrchestratorCallbacks::noop()
  let rl = @ralph.RalphLoop::new(config, mgr, backends, callbacks)

  rl.run()

  let history = builder_mock.get_history()
  assert_true(history.length() == 4)
  let (initial_task_1, _) = history[0]
  let (initial_task_2, _) = history[1]
  let (rework_task_1, _) = history[2]
  let (rework_task_2, _) = history[3]
  inspect(initial_task_1, content="Implement login flow")
  inspect(initial_task_2, content="Add audit logging")
  assert_true(rework_task_1.contains("Implement login flow"))
  assert_true(
    rework_task_1.contains(
      "Feedback from verifier:\n- [Security] general quality issues",
    ),
  )
  assert_true(rework_task_2.contains("Add audit logging"))
  assert_true(
    rework_task_2.contains(
      "Feedback from verifier:\n- [Security] general quality issues",
    ),
  )
  assert_true(mgr.milestones[0].tasks[0].result.unwrap().contains("REWORKED"))
  assert_true(mgr.milestones[0].tasks[1].result.unwrap().contains("REWORKED"))
}

///|
test "rework_tasks distributes per-task feedback without cross-contamination" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1", "goal": "Build auth", "status": "pending",
    #|      "tasks": [
    #|        { "id": "m1-t1", "description": "Implement login flow", "wave": 0, "status": "pending" },
    #|        { "id": "m1-t2", "description": "Add audit logging", "wave": 0, "status": "pending" }
    #|      ]
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(default_response="unused")
  let builder_mock = @agent.MockBackend::new(default_response="Done v1")
  builder_mock.add_response(
    "[CodeQuality] add validation", "Done v2 REWORKED-T1",
  )
  builder_mock.add_response(
    "[Security] missing edge cases", "Done v2 REWORKED-T2",
  )
  let verifier_mock = @agent.MockBackend::new(
    default_response="<wave_approved>",
  )
  verifier_mock.add_response(
    "### Task: m1-t1\nDone v1\n\n### Task: m1-t2\nDone v1\n\n## Review Focus: Code Quality",
    "<needs_rework>m1-t1: add validation</needs_rework>",
  )
  verifier_mock.add_response(
    "### Task: m1-t1\nDone v1\n\n### Task: m1-t2\nDone v1\n\n## Review Focus: Security",
    "<needs_rework>m1-t2: missing edge cases</needs_rework>",
  )
  verifier_mock.add_response("REWORKED", "<wave_approved>")
  let backends : Map[String, @agent.BoxedBackend] = {}
  backends["planner"] = planner_mock.boxed()
  backends["builder"] = builder_mock.boxed()
  backends["verifier"] = verifier_mock.boxed()
  let callbacks = @types.OrchestratorCallbacks::noop()
  let rl = @ralph.RalphLoop::new(config, mgr, backends, callbacks)

  rl.run()

  let history = builder_mock.get_history()
  assert_true(history.length() == 4)
  let (initial_task_1, _) = history[0]
  let (initial_task_2, _) = history[1]
  let (rework_task_1, _) = history[2]
  let (rework_task_2, _) = history[3]
  inspect(initial_task_1, content="Implement login flow")
  inspect(initial_task_2, content="Add audit logging")
  assert_true(rework_task_1.contains("Implement login flow"))
  assert_true(rework_task_1.contains("[CodeQuality] add validation"))
  assert_true(not(rework_task_1.contains("missing edge cases")))
  assert_true(rework_task_2.contains("Add audit logging"))
  assert_true(rework_task_2.contains("[Security] missing edge cases"))
  assert_true(not(rework_task_2.contains("add validation")))
  inspect(
    mgr.milestones[0].tasks[0].result.unwrap(),
    content="Done v2 REWORKED-T1",
  )
  inspect(
    mgr.milestones[0].tasks[1].result.unwrap(),
    content="Done v2 REWORKED-T2",
  )
}

///|
test "rework prompt has correct format with description and feedback" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1", "goal": "Build auth", "status": "pending",
    #|      "tasks": [
    #|        { "id": "m1-t1", "description": "implement feature X", "wave": 0, "status": "pending" }
    #|      ]
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(default_response="unused")
  let builder_mock = @agent.MockBackend::new(default_response="Done v1")
  builder_mock.add_response("Feedback from verifier", "Done v2 REWORKED")
  let verifier_mock = @agent.MockBackend::new(
    default_response="<wave_approved>",
  )
  verifier_mock.add_response(
    "### Task: m1-t1\nDone v1\n\n## Review Focus: Code Quality", "<needs_rework>m1-t1: add input validation</needs_rework>",
  )
  verifier_mock.add_response("REWORKED", "<wave_approved>")
  let backends : Map[String, @agent.BoxedBackend] = {}
  backends["planner"] = planner_mock.boxed()
  backends["builder"] = builder_mock.boxed()
  backends["verifier"] = verifier_mock.boxed()
  let callbacks = @types.OrchestratorCallbacks::noop()
  let rl = @ralph.RalphLoop::new(config, mgr, backends, callbacks)

  rl.run()

  let history = builder_mock.get_history()
  assert_true(history.length() == 2)
  let (rework_task, _) = history[1]
  let expected_prompt = "implement feature X\n\nFeedback from verifier:\n- [CodeQuality] add input validation\n"
  inspect(rework_task, content=expected_prompt)
  inspect(
    mgr.milestones[0].tasks[0].result.unwrap(),
    content="Done v2 REWORKED",
  )
}

///|
test "rework_tasks matches space-delimited feedback (no colon)" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1", "goal": "Build auth", "status": "pending",
    #|      "tasks": [
    #|        { "id": "m1-t1", "description": "Implement login flow", "wave": 0, "status": "pending" },
    #|        { "id": "m1-t2", "description": "Add audit logging", "wave": 0, "status": "pending" }
    #|      ]
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(default_response="unused")
  let builder_mock = @agent.MockBackend::new(default_response="Done v1")
  builder_mock.add_response("Feedback from verifier", "Done v2 REWORKED")
  let verifier_mock = @agent.MockBackend::new(
    default_response="<wave_approved>",
  )
  verifier_mock.add_response(
    "### Task: m1-t1\nDone v1\n\n### Task: m1-t2\nDone v1\n\n## Review Focus: Security",
    "<needs_rework>m1-t1 needs better validation</needs_rework>",
  )
  verifier_mock.add_response("REWORKED", "<wave_approved>")
  let backends : Map[String, @agent.BoxedBackend] = {}
  backends["planner"] = planner_mock.boxed()
  backends["builder"] = builder_mock.boxed()
  backends["verifier"] = verifier_mock.boxed()
  let callbacks = @types.OrchestratorCallbacks::noop()
  let rl = @ralph.RalphLoop::new(config, mgr, backends, callbacks)

  rl.run()

  let history = builder_mock.get_history()
  assert_true(history.length() == 3)
  let (initial_task_1, _) = history[0]
  let (initial_task_2, _) = history[1]
  let (rework_task, _) = history[2]
  inspect(initial_task_1, content="Implement login flow")
  inspect(initial_task_2, content="Add audit logging")
  assert_true(rework_task.contains("Implement login flow"))
  assert_true(
    rework_task.contains(
      "Feedback from verifier:\n- [Security] needs better validation",
    ),
  )
  assert_true(not(rework_task.contains("Add audit logging")))
  assert_true(mgr.milestones[0].tasks[0].result.unwrap().contains("REWORKED"))
  inspect(mgr.milestones[0].tasks[1].result.unwrap(), content="Done v1")
}

///|
test "tornado-1fy: detect file conflicts between parallel builders in same wave" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m2", "goal": "Fix prettier config", "status": "pending",
    #|      "tasks": [
    #|        { "id": "m2-t8", "description": "Fix prettier via package.json", "wave": 0, "status": "pending" },
    #|        { "id": "m2-t9", "description": "Fix prettier via env variable", "wave": 0, "status": "pending" }
    #|      ]
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(default_response="unused")
  // Both builders report changing package.json — this is the conflict scenario
  let builder_mock = @agent.MockBackend::new(
    default_response="Done\nFILES_CHANGED: package.json, src/config.ts",
  )
  builder_mock.add_response(
    "Fix prettier via env variable", "Done\nFILES_CHANGED: package.json, .env",
  )
  let verifier_mock = @agent.MockBackend::new(
    default_response="<wave_approved>",
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
  // The key assertion: file conflict on package.json must be detected and reported
  assert_true(
    infos
    .iter()
    .any(fn(msg) {
      msg.contains("file conflict") || msg.contains("File conflict")
    }),
  )
  assert_true(infos.iter().any(fn(msg) { msg.contains("package.json") }))
}

///|
test "tornado-1fy: no false positive when parallel builders edit different files" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1", "goal": "Build features", "status": "pending",
    #|      "tasks": [
    #|        { "id": "m1-t1", "description": "Build auth module", "wave": 0, "status": "pending" },
    #|        { "id": "m1-t2", "description": "Build logging module", "wave": 0, "status": "pending" }
    #|      ]
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(default_response="unused")
  // Builders edit different files — no conflict
  let builder_mock = @agent.MockBackend::new(
    default_response="Done\nFILES_CHANGED: src/auth.ts",
  )
  builder_mock.add_response(
    "Build logging module", "Done\nFILES_CHANGED: src/logging.ts",
  )
  let verifier_mock = @agent.MockBackend::new(
    default_response="<wave_approved>",
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
  // No conflict should be reported
  assert_true(
    not(
      infos
      .iter()
      .any(fn(msg) {
        msg.contains("file conflict") || msg.contains("File conflict")
      }),
    ),
  )
  // Milestone should complete successfully
  inspect(mgr.milestones[0].status, content="Done")
}

///|
test "tornado-1fy: extract_changed_files parses FILES_CHANGED line correctly" {
  let result = "Task completed.\nFILES_CHANGED: package.json, src/index.ts, README.md\nDone."
  let files = @ralph.extract_changed_files(result)
  assert_true(files.length() == 3)
  assert_true(files.contains("package.json"))
  assert_true(files.contains("src/index.ts"))
  assert_true(files.contains("README.md"))
}

///|
test "tornado-1fy: extract_changed_files returns empty for no FILES_CHANGED" {
  let result = "Task completed successfully."
  let files = @ralph.extract_changed_files(result)
  assert_true(files.is_empty())
}

///|
test "tornado-1fy: detect_wave_file_conflicts finds overlapping files" {
  let results : Array[(@types.RalphTask, Array[String])] = []
  let t1 : @types.RalphTask = {
    id: "m1-t1",
    description: "task 1",
    wave: 0,
    status: Done,
    result: None,
    plan_doc: None,
  }
  let t2 : @types.RalphTask = {
    id: "m1-t2",
    description: "task 2",
    wave: 0,
    status: Done,
    result: None,
    plan_doc: None,
  }
  results.push((t1, ["package.json", "src/a.ts"]))
  results.push((t2, ["package.json", "src/b.ts"]))
  let conflicts = @ralph.detect_wave_file_conflicts(results)
  assert_true(conflicts.length() == 1)
  let (file, task_ids) = conflicts[0]
  inspect(file, content="package.json")
  assert_true(task_ids.contains("m1-t1"))
  assert_true(task_ids.contains("m1-t2"))
}

///|
test "tornado-1fy: detect_wave_file_conflicts returns empty for no overlaps" {
  let results : Array[(@types.RalphTask, Array[String])] = []
  let t1 : @types.RalphTask = {
    id: "m1-t1",
    description: "task 1",
    wave: 0,
    status: Done,
    result: None,
    plan_doc: None,
  }
  let t2 : @types.RalphTask = {
    id: "m1-t2",
    description: "task 2",
    wave: 0,
    status: Done,
    result: None,
    plan_doc: None,
  }
  results.push((t1, ["src/a.ts"]))
  results.push((t2, ["src/b.ts"]))
  let conflicts = @ralph.detect_wave_file_conflicts(results)
  assert_true(conflicts.is_empty())
}

///|
test "run_wave with 3 parallel builders causing multi-file conflicts" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1", "goal": "Refactor config", "status": "pending",
    #|      "tasks": [
    #|        { "id": "m1-t1", "description": "Update config parser", "wave": 0, "status": "pending" },
    #|        { "id": "m1-t2", "description": "Add config validator", "wave": 0, "status": "pending" },
    #|        { "id": "m1-t3", "description": "Migrate config format", "wave": 0, "status": "pending" }
    #|      ]
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(default_response="unused")
  // All three builders touch config.ts; t1 and t3 also both touch schema.ts
  let builder_mock = @agent.MockBackend::new(
    default_response="Done\nFILES_CHANGED: src/config.ts, src/parser.ts",
  )
  builder_mock.add_response(
    "Add config validator", "Done\nFILES_CHANGED: src/config.ts, src/validator.ts",
  )
  builder_mock.add_response(
    "Migrate config format", "Done\nFILES_CHANGED: src/config.ts, src/parser.ts",
  )
  let verifier_mock = @agent.MockBackend::new(
    default_response="<wave_approved>",
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
  // config.ts is touched by all 3 tasks — must report conflict with 3 task IDs
  assert_true(
    infos
    .iter()
    .any(fn(msg) { msg.contains("File conflict") && msg.contains("config.ts") }),
  )
  // parser.ts is touched by t1 and t3 — must also report conflict
  assert_true(
    infos
    .iter()
    .any(fn(msg) { msg.contains("File conflict") && msg.contains("parser.ts") }),
  )
  // validator.ts is touched only by t2 — no conflict reported for it
  assert_true(
    not(
      infos
      .iter()
      .any(fn(msg) {
        msg.contains("File conflict") && msg.contains("validator.ts")
      }),
    ),
  )
  // Milestone should still complete (conflicts are informational, not blocking)
  inspect(mgr.milestones[0].status, content="Done")
}

///|
test "verify_milestone reaches max rework attempts and accepts as-is" {
  // Use max_rework_attempts=2 to test the exact boundary
  let planner_agent : @types.AgentConfig = {
    id: "planner",
    kind: Mock,
    role: Planner,
    model: None,
    system_prompt: None,
    working_dir: ".",
    max_iterations: 10,
  }
  let builder_agent : @types.AgentConfig = {
    id: "builder",
    kind: Mock,
    role: Dev,
    model: None,
    system_prompt: None,
    working_dir: ".",
    max_iterations: 10,
  }
  let verifier_agent : @types.AgentConfig = {
    id: "verifier",
    kind: Mock,
    role: Verifier,
    model: None,
    system_prompt: None,
    working_dir: ".",
    max_iterations: 10,
  }
  let config : @config.ProjectConfig = {
    project_dir: ".",
    review_dir: "docs/reviews",
    max_review_cycles: 3,
    review_interval: 1,
    agents: [planner_agent, builder_agent, verifier_agent],
    parse_warnings: [],
    ralph_enabled: true,
    milestones_path: None,
    max_rework_attempts: 2,
  }
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1", "goal": "Build auth", "status": "pending",
    #|      "tasks": [
    #|        { "id": "m1-t1", "description": "Implement feature", "wave": 0, "status": "pending" }
    #|      ]
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(default_response="unused")
  let builder_mock = @agent.MockBackend::new(default_response="Done")
  // Verifier always returns needs_rework — never approves
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
  // Max rework should be reached and milestone accepted as-is
  assert_true(
    infos.iter().any(fn(msg) { msg.contains("Max rework attempts reached") }),
  )
  // Milestone should be Done (accepted as-is), not Failed
  inspect(mgr.milestones[0].status, content="Done")
  // Should see 3 verification attempts (attempt 0, 1, 2) where attempt 2 >= max_rework_attempts=2
  assert_true(
    infos
    .iter()
    .any(fn(msg) { msg.contains("Verifying milestone m1 (attempt 1)") }),
  )
  assert_true(
    infos
    .iter()
    .any(fn(msg) { msg.contains("Verifying milestone m1 (attempt 2)") }),
  )
  assert_true(
    infos
    .iter()
    .any(fn(msg) { msg.contains("Verifying milestone m1 (attempt 3)") }),
  )
}

///|
test "next_wave_number skips completed waves and jumps to pending wave" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1", "goal": "Build auth", "status": "pending",
    #|      "tasks": [
    #|        { "id": "m1-t1", "description": "Create schema", "wave": 0, "status": "done", "result": "already done" },
    #|        { "id": "m1-t2", "description": "Write tests", "wave": 0, "status": "done", "result": "already done" },
    #|        { "id": "m1-t3", "description": "Add handlers", "wave": 1, "status": "pending" }
    #|      ]
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(default_response="unused")
  let builder_mock = @agent.MockBackend::new(default_response="fresh result")
  let verifier_mock = @agent.MockBackend::new(
    default_response="<wave_approved>",
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
  // Wave 0 should never be executed (all tasks done, next_wave_number skips it)
  assert_true(
    not(infos.iter().any(fn(msg) { msg.contains("Executing wave 0") })),
  )
  // Wave 1 should be executed
  assert_true(infos.iter().any(fn(msg) { msg.contains("Executing wave 1") }))
  // Builder should only be called for wave 1's pending task
  let history = builder_mock.get_history()
  assert_true(history.length() == 1)
  inspect(history[0].0, content="Add handlers")
  // Milestone should complete
  inspect(mgr.milestones[0].status, content="Done")
}

///|
test "run_wave returns false when no builder backend is available" {
  // Config has no Dev agent
  let planner_agent : @types.AgentConfig = {
    id: "planner",
    kind: Mock,
    role: Planner,
    model: None,
    system_prompt: None,
    working_dir: ".",
    max_iterations: 10,
  }
  let verifier_agent : @types.AgentConfig = {
    id: "verifier",
    kind: Mock,
    role: Verifier,
    model: None,
    system_prompt: None,
    working_dir: ".",
    max_iterations: 10,
  }
  let config : @config.ProjectConfig = {
    project_dir: ".",
    review_dir: "docs/reviews",
    max_review_cycles: 3,
    review_interval: 1,
    agents: [planner_agent, verifier_agent],
    parse_warnings: [],
    ralph_enabled: true,
    milestones_path: None,
    max_rework_attempts: 3,
  }
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1", "goal": "Build auth", "status": "pending",
    #|      "tasks": [
    #|        { "id": "m1-t1", "description": "Create schema", "wave": 0, "status": "pending" }
    #|      ]
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(default_response="unused")
  let verifier_mock = @agent.MockBackend::new(
    default_response="<wave_approved>",
  )
  let backends : Map[String, @agent.BoxedBackend] = {}
  backends["planner"] = planner_mock.boxed()
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
  // Milestone should fail because no builder backend found
  assert_true(mgr.milestones[0].status is @types.MilestoneStatus::Failed(_))
  assert_true(
    infos.iter().any(fn(msg) { msg.contains("No builder backend found") }),
  )
}

///|
test "verify_milestone fails after rework when re-verify returns milestone_failed" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1", "goal": "Build auth", "status": "pending",
    #|      "tasks": [
    #|        { "id": "m1-t1", "description": "Implement login", "wave": 0, "status": "pending" }
    #|      ]
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(default_response="unused")
  let builder_mock = @agent.MockBackend::new(default_response="Done v1")
  builder_mock.add_response("Feedback from verifier", "Done v2 REWORKED")
  let verifier_mock = @agent.MockBackend::new(
    default_response="<wave_approved>",
  )
  // First verification (attempt 0): needs_rework
  verifier_mock.add_response(
    "Done v1", "<needs_rework>m1-t1: missing error handling</needs_rework>",
  )
  // Second verification (attempt 1) after rework: milestone_failed
  verifier_mock.add_response(
    "REWORKED", "<milestone_failed>Fundamental design flaw after rework</milestone_failed>",
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
  // Milestone should be Failed, not Done
  assert_true(mgr.milestones[0].status is @types.MilestoneStatus::Failed(_))
  // Should have rework and then failure info
  assert_true(
    infos
    .iter()
    .any(fn(msg) {
      msg.contains("rework needed") || msg.contains("Rework needed")
    }),
  )
  assert_true(
    infos
    .iter()
    .any(fn(msg) { msg.contains("Milestone failed") || msg.contains("failed") }),
  )
}

///|
test "detect_wave_file_conflicts with 3 tasks all sharing the same file" {
  let results : Array[(@types.RalphTask, Array[String])] = []
  let t1 : @types.RalphTask = {
    id: "m1-t1",
    description: "task 1",
    wave: 0,
    status: Done,
    result: None,
    plan_doc: None,
  }
  let t2 : @types.RalphTask = {
    id: "m1-t2",
    description: "task 2",
    wave: 0,
    status: Done,
    result: None,
    plan_doc: None,
  }
  let t3 : @types.RalphTask = {
    id: "m1-t3",
    description: "task 3",
    wave: 0,
    status: Done,
    result: None,
    plan_doc: None,
  }
  results.push((t1, ["shared.ts", "a.ts"]))
  results.push((t2, ["shared.ts", "b.ts"]))
  results.push((t3, ["shared.ts", "c.ts"]))
  let conflicts = @ralph.detect_wave_file_conflicts(results)
  // shared.ts should be the only conflict, with all 3 task IDs
  assert_true(conflicts.length() == 1)
  let (file, task_ids) = conflicts[0]
  inspect(file, content="shared.ts")
  assert_true(task_ids.length() == 3)
  assert_true(task_ids.contains("m1-t1"))
  assert_true(task_ids.contains("m1-t2"))
  assert_true(task_ids.contains("m1-t3"))
}

///|
test "extract_changed_files handles multiple FILES_CHANGED lines" {
  let result = "Step 1\nFILES_CHANGED: a.ts, b.ts\nStep 2\nFILES_CHANGED: c.ts\nDone."
  let files = @ralph.extract_changed_files(result)
  // Both lines should be parsed
  assert_true(files.length() == 3)
  assert_true(files.contains("a.ts"))
  assert_true(files.contains("b.ts"))
  assert_true(files.contains("c.ts"))
}

///|
test "extract_changed_files handles whitespace around file names" {
  let result = "FILES_CHANGED:  src/a.ts ,  src/b.ts  "
  let files = @ralph.extract_changed_files(result)
  assert_true(files.length() == 2)
  assert_true(files.contains("src/a.ts"))
  assert_true(files.contains("src/b.ts"))
}

///|
test "single task wave does not trigger conflict detection" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1", "goal": "Build feature", "status": "pending",
    #|      "tasks": [
    #|        { "id": "m1-t1", "description": "Build auth module", "wave": 0, "status": "pending" }
    #|      ]
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(default_response="unused")
  let builder_mock = @agent.MockBackend::new(
    default_response="Done\nFILES_CHANGED: package.json, src/config.ts",
  )
  let verifier_mock = @agent.MockBackend::new(
    default_response="<wave_approved>",
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
  // With only 1 task, the conflict detection block is skipped entirely
  assert_true(
    not(
      infos
      .iter()
      .any(fn(msg) {
        msg.contains("file conflict") || msg.contains("File conflict")
      }),
    ),
  )
  inspect(mgr.milestones[0].status, content="Done")
}
