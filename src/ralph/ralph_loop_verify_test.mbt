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
    default_response="TASKS:\n1. Create schema",
  )
  // Builder returns different results each time to avoid no-change circuit breaker
  let builder_seq = @agent.SequenceMockBackend::new([
    "Done v1", "Done v2 reworked", "Done v3 reworked again",
  ])
  let verifier_mock = @agent.MockBackend::new(default_response="<approved>")
  verifier_mock.add_response(
    "Security", "<needs_rework>m1-t1: add validation</needs_rework>",
  )
  let backends : Map[String, @agent.BoxedBackend] = {}
  backends["planner"] = planner_mock.boxed()
  backends["builder"] = builder_seq.boxed()
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
  // Eventually reaches max rework
  assert_true(infos.iter().any(fn(m) { m.contains("Max rework attempts") }))
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
    default_response="TASKS:\n1. Create schema",
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
    role: Builder,
    model: None,
  }
  let planner_agent : @types.AgentConfig = {
    id: "planner",
    kind: Mock,
    role: Planner,
    model: None,
  }
  let config : @config.ProjectConfig = {
    agents: [planner_agent, builder_agent],
    parse_warnings: [],
    milestones_path: None,
    max_rework_attempts: 3,
  }
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
  let backends : Map[String, @agent.BoxedBackend] = {}
  backends["planner"] = planner_mock.boxed()
  backends["builder"] = builder_mock.boxed()
  let callbacks = @types.OrchestratorCallbacks::noop()
  let rl = @ralph.RalphLoop::new(config, mgr, backends, callbacks)
  rl.run()
  inspect(mgr.milestones[0].status, content="Done")
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
test "RalphLoop multi-layer full cycle verifies all 4 perspectives once at milestone completion" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1", "goal": "Ship auth flow", "status": "pending",
    #|      "tasks": [
    #|        { "id": "m1-t1", "description": "Create schema", "status": "pending" },
    #|        { "id": "m1-t2", "description": "Build handlers", "status": "pending" },
    #|        { "id": "m1-t3", "description": "Add integration tests", "status": "pending" }
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
test "RalphLoop verifies only configured milestone perspectives" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1", "goal": "Add tests", "status": "pending",
    #|      "perspectives": ["CodeQuality", "GoalAlignment"],
    #|      "tasks": [
    #|        { "id": "m1-t1", "description": "Write tests", "status": "pending" }
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
  let rl = @ralph.RalphLoop::new(
    config,
    mgr,
    backends,
    @types.OrchestratorCallbacks::noop(),
  )

  rl.run()

  inspect(mgr.milestones[0].status, content="Done")
  let history = verifier_mock.get_history()
  assert_true(history.length() == 2)
  let (first_prompt, first_system_prompt) = history[0]
  let (second_prompt, second_system_prompt) = history[1]
  assert_true(first_prompt.contains("## Review Focus: Code Quality"))
  assert_true(second_prompt.contains("## Review Focus: Goal Alignment"))
  assert_true(first_system_prompt.contains("CodeQuality"))
  assert_true(second_system_prompt.contains("GoalAlignment"))
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
    #|        { "id": "m1-t1", "description": "Create schema", "status": "pending" }
    #|      ]
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(default_response="unused")
  let builder_mock = @agent.MockBackend::new(default_response="Done")
  let verifier_mock = @agent.MockBackend::new(default_response="<approved>")
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
    #|        { "id": "m1-t1", "description": "Create schema", "status": "pending" }
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
    #|        { "id": "m1-t1", "description": "Implement login flow", "status": "pending" },
    #|        { "id": "m1-t2", "description": "Add audit logging", "status": "pending" }
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
    "### Task: m1-t1\nDone v1\n\n### Task: m1-t2\nDone v1\n\n## Review Focus: Security",
    "<needs_rework>m1-t1: fix error handling</needs_rework>",
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
    #|        { "id": "m1-t1", "description": "Implement login flow", "status": "pending" },
    #|        { "id": "m1-t2", "description": "Add audit logging", "status": "pending" }
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
    "### Task: m1-t1\nDone v1\n\n### Task: m1-t2\nDone v1\n\n## Review Focus: Security",
    "<needs_rework>general quality issues</needs_rework>",
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
    #|        { "id": "m1-t1", "description": "Implement login flow", "status": "pending" },
    #|        { "id": "m1-t2", "description": "Add audit logging", "status": "pending" }
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
  let verifier_mock = @agent.MockBackend::new(default_response="<approved>")
  verifier_mock.add_response(
    "### Task: m1-t1\nDone v1\n\n### Task: m1-t2\nDone v1\n\n## Review Focus: Code Quality",
    "<needs_rework>m1-t1: add validation</needs_rework>",
  )
  verifier_mock.add_response(
    "### Task: m1-t1\nDone v1\n\n### Task: m1-t2\nDone v1\n\n## Review Focus: Security",
    "<needs_rework>m1-t2: missing edge cases</needs_rework>",
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
    #|        { "id": "m1-t1", "description": "Implement login flow", "status": "pending" },
    #|        { "id": "m1-t2", "description": "Add audit logging", "status": "pending" }
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
    "### Task: m1-t1\nDone v1\n\n### Task: m1-t2\nDone v1\n\n## Review Focus: Security",
    "<needs_rework>m1-t1 needs better validation</needs_rework>",
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
