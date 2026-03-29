///|
fn make_ralph_config() -> @config.ProjectConfig {
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
  {
    agents: [planner_agent, builder_agent, verifier_agent],
    parse_warnings: [],
    milestones_path: None,
    max_rework_attempts: 3,
  }
}

///|
test "resolve_perspectives filters invalid names" {
  let perspectives = @ralph.resolve_perspectives([
    "CodeQuality", "Nope", "GoalAlignment",
  ])
  assert_true(perspectives.length() == 2)
  inspect(perspectives[0], content="CodeQuality")
  inspect(perspectives[1], content="GoalAlignment")
}

///|
test "resolve_perspectives falls back to all four when empty" {
  let perspectives = @ralph.resolve_perspectives([])
  assert_true(perspectives.length() == 4)
  inspect(perspectives[0], content="CodeQuality")
  inspect(perspectives[1], content="Performance")
  inspect(perspectives[2], content="Security")
  inspect(perspectives[3], content="GoalAlignment")
}

///|
test "RalphLoop skips verification when milestone perspectives are empty" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1", "goal": "Run checks", "status": "pending",
    #|      "perspectives": [],
    #|      "tasks": [
    #|        { "id": "m1-t1", "description": "Run command", "status": "pending" }
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

  inspect(mgr.milestones[0].status, content="Done")
  assert_true(verifier_mock.get_history().is_empty())
  assert_true(
    infos
    .iter()
    .any(fn(msg) {
      msg.contains("No verification perspectives for milestone m1")
    }),
  )
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
    default_response="TASKS:\n1. Create schema\n2. Write tests",
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
  // Milestone should be complete
  inspect(mgr.milestones[0].status, content="Done")
  // Should have info messages about progress
  assert_true(infos.iter().any(fn(m) { m.contains("Ralph loop started") }))
  assert_true(infos.iter().any(fn(m) { m.contains("Planning") }))
  assert_true(infos.iter().any(fn(m) { m.contains("Executing DAG") }))
  assert_true(infos.iter().any(fn(m) { m.contains("approved") }))
  assert_true(infos.iter().any(fn(m) { m.contains("complete") }))
  // Phase should be AllComplete
  inspect(rl.current_phase, content="AllComplete")
}

///|
test "RalphLoop stores planner perspectives from raw output" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    { "id": "m1", "goal": "Build auth", "status": "pending", "tasks": [] }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(
    default_response="PERSPECTIVES: CodeQuality, GoalAlignment\nTASKS:\n1. Create schema\n2. Write tests",
  )
  let builder_mock = @agent.MockBackend::new(
    default_response="Task completed successfully",
  )
  let verifier_mock = @agent.MockBackend::new(default_response="<approved>")
  let backends : Map[String, @agent.BoxedBackend] = {}
  backends["planner"] = planner_mock.boxed()
  backends["builder"] = builder_mock.boxed()
  backends["verifier"] = verifier_mock.boxed()
  let callbacks = @types.OrchestratorCallbacks::noop()
  let rl = @ralph.RalphLoop::new(config, mgr, backends, callbacks)
  rl.run()

  assert_true(mgr.milestones[0].perspectives.length() == 2)
  inspect(mgr.milestones[0].perspectives[0], content="CodeQuality")
  inspect(mgr.milestones[0].perspectives[1], content="GoalAlignment")
}

///|
test "RalphLoop preserves milestone perspectives loaded from file" {
  let config = {
    ..make_ralph_config(),
    milestones_path: Some("milestones.json"),
  }
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1", "goal": "Run checks", "status": "pending",
    #|      "perspectives": [],
    #|      "tasks": []
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(
    default_response="PERSPECTIVES: CodeQuality, GoalAlignment\nTASKS:\n1. Run command",
  )
  let builder_mock = @agent.MockBackend::new(default_response="Done")
  let verifier_mock = @agent.MockBackend::new(default_response="<approved>")
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

  assert_true(mgr.milestones[0].perspectives.length() == 0)
}

///|
test "RalphLoop dry-run runs planner but skips execution and verification" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "brief": "Generate tasks only.",
    #|  "milestones": [
    #|    { "id": "m1", "goal": "Build auth", "status": "pending", "tasks": [] }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(
    default_response="TASKS:\n1. Create schema\n2. Write tests",
  )
  let builder_mock = @agent.MockBackend::new(default_response="should not run")
  let verifier_mock = @agent.MockBackend::new(default_response="should not run")
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
  let rl = @ralph.RalphLoop::new(config, mgr, backends, callbacks, dry_run=true)
  rl.run()

  // planner は呼ばれるべき
  inspect(planner_mock.get_history().length(), content="1")
  // タスクが生成されているべき
  inspect(mgr.milestones[0].tasks.length(), content="2")
  // ステータスは pending のまま（実行・検証はスキップ）
  inspect(mgr.milestones[0].status, content="Pending")
  // builder・verifier は呼ばれないべき
  inspect(builder_mock.get_history().length(), content="0")
  inspect(verifier_mock.get_history().length(), content="0")
  assert_true(
    infos
    .iter()
    .any(fn(m) {
      m.contains("Dry-run: milestone m1 planned") &&
      m.contains("skipping execution and verification")
    }),
  )
  inspect(rl.current_phase, content="AllComplete")
}

///|
test "RalphLoop dry-run logs planning failed when planner returns no tasks" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "brief": "Generate tasks only.",
    #|  "milestones": [
    #|    { "id": "m1", "goal": "Build auth", "status": "pending", "tasks": [] }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  // FailingMockBackend causes planner to return a failed AgentResult → PlanFailed
  let failing_planner = @agent.FailingMockBackend::new(
    error_msg="planner error",
  )
  let builder_mock = @agent.MockBackend::new(default_response="should not run")
  let verifier_mock = @agent.MockBackend::new(default_response="should not run")
  let backends : Map[String, @agent.BoxedBackend] = {}
  backends["planner"] = failing_planner.boxed()
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
  let rl = @ralph.RalphLoop::new(config, mgr, backends, callbacks, dry_run=true)
  rl.run()

  // planner は呼ばれるべき (初回 + リトライで計2回)
  inspect(failing_planner.call_count, content="2")
  // タスクは生成されない
  inspect(mgr.milestones[0].tasks.length(), content="0")
  // マイルストーンは Failed になる
  inspect(mgr.milestones[0].status, content="Failed(\"No tasks planned\")")
  // builder・verifier は呼ばれないべき
  inspect(builder_mock.get_history().length(), content="0")
  inspect(verifier_mock.get_history().length(), content="0")
  assert_true(
    infos
    .iter()
    .any(fn(m) { m.contains("Dry-run: milestone m1 planning failed") }),
  )
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
    default_response="TASKS:\n1. Create schema",
  )
  let builder_mock = @agent.MockBackend::new(default_response="Done")
  let verifier_mock = @agent.MockBackend::new(default_response="<approved>")
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
  assert_true(system_prompt.contains("## Brief"))
  assert_true(
    system_prompt.contains(
      "Keep public APIs stable while refactoring internals.",
    ),
  )
  assert_true(system_prompt.contains("## Compile Error Policy"))
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
    #|        { "id": "m1-t1", "description": "Create schema", "status": "pending" },
    #|        { "id": "m1-t2", "description": "Build handlers", "status": "pending" }
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
    #|        { "id": "m1-t1", "description": "Create schema", "status": "pending" }
    #|      ]
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(default_response="unused")
  let builder_mock = @agent.MockBackend::new(default_response="Schema created")
  let verifier_mock = @agent.MockBackend::new(default_response="<approved>")
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
    #|        { "id": "m1-t1", "description": "Create schema", "status": "done" },
    #|        { "id": "m1-t2", "description": "Write tests", "status": "done" },
    #|        { "id": "m1-t3", "description": "Add handlers", "status": "pending" }
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
  assert_true(
    infos
    .iter()
    .any(fn(msg) {
      msg.contains("Resuming milestone m1: 2 of 3 tasks already done")
    }),
  )
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
    #|        { "id": "m1-t1", "description": "Init project", "status": "pending" }
    #|      ]
    #|    },
    #|    {
    #|      "id": "m2", "goal": "Build API", "status": "pending",
    #|      "tasks": [
    #|        { "id": "m2-t1", "description": "Create routes", "status": "pending" }
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
  inspect(mgr.milestones[0].status, content="Done")
  inspect(mgr.milestones[1].status, content="Done")
  inspect(rl.current_phase, content="AllComplete")
}

///|
test "whirlwind-cgf: planner already-complete signal marks milestone Done" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    { "id": "m1", "goal": "Build auth", "status": "pending", "tasks": [] }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(
    default_response="This milestone is already complete. All required changes were implemented in previous milestones.",
  )
  let builder_mock = @agent.MockBackend::new(default_response="should not run")
  let verifier_mock = @agent.MockBackend::new(default_response="should not run")
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
  assert_true(infos.iter().any(fn(m) { m.contains("already complete") }))
}
