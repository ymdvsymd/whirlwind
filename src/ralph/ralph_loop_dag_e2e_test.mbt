///|
test "resume skips already-done milestones" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1", "goal": "Completed milestone", "status": "done",
    #|      "tasks": [
    #|        { "id": "m1-t1", "description": "Create schema", "status": "done", "result": "already finished" }
    #|      ]
    #|    },
    #|    {
    #|      "id": "m2", "goal": "Pending milestone", "status": "pending",
    #|      "tasks": [
    #|        { "id": "m2-t1", "description": "Write handlers", "status": "pending" }
    #|      ]
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(default_response="unused")
  let builder_mock = @agent.MockBackend::new(default_response="fresh result")
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
    not(infos.iter().any(fn(msg) { msg.contains("Executing DAG for m1") })),
  )
  assert_true(
    not(infos.iter().any(fn(msg) { msg.contains("Resuming milestone m1:") })),
  )
  assert_true(
    not(infos.iter().any(fn(msg) { msg.contains("Dispatching task m1-t1") })),
  )
  assert_true(
    infos.iter().any(fn(msg) { msg.contains("Executing DAG for m2") }),
  )
}

///|
test "RalphLoop multi-task DAG execution" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    { "id": "m1", "goal": "Build", "status": "pending", "tasks": [] }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(
    default_response="TASKS:\n1. Setup\n2. Build\n3. Test",
  )
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
  assert_true(infos.iter().any(fn(m) { m.contains("Executing DAG for m1") }))
  assert_true(builder_mock.get_history().length() == 3)
}

///|
test "run_dag skips already-done layers and dispatches only pending tasks" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1", "goal": "Build auth", "status": "pending",
    #|      "tasks": [
    #|        { "id": "m1-t1", "description": "Create schema", "status": "done", "result": "already done" },
    #|        { "id": "m1-t2", "description": "Write tests", "status": "done", "result": "already done" },
    #|        { "id": "m1-t3", "description": "Add handlers", "status": "pending" }
    #|      ]
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(default_response="unused")
  let builder_mock = @agent.MockBackend::new(default_response="fresh result")
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
  // DAG should be executed (layer 0 tasks already done, only layer 1 dispatched)
  assert_true(
    infos.iter().any(fn(msg) { msg.contains("Executing DAG for m1") }),
  )
  // Layer 0 has only done tasks → silently skipped (no pending to dispatch)
  // Layer 1's pending task is dispatched
  assert_true(
    infos.iter().any(fn(msg) { msg.contains("Dispatching task m1-t3") }),
  )
  // Builder should only be called for the pending task
  let history = builder_mock.get_history()
  assert_true(history.length() == 1)
  inspect(history[0].0, content="Add handlers")
  // Milestone should complete
  inspect(mgr.milestones[0].status, content="Done")
}

///|
test "run_dag resumes with depends_on: done task propagates and unblocks pending dependents" {
  let config = make_ralph_config()
  // DAG: A (done) → B (pending), A → C (pending), independent D (done)
  // On resume, A and D are skipped; B and C are unblocked by A's done propagation.
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1", "goal": "Resume DAG", "status": "pending",
    #|      "tasks": [
    #|        { "id": "m1-t1", "description": "Schema (done)", "status": "done", "result": "schema ok", "depends_on": [] },
    #|        { "id": "m1-t2", "description": "Handlers (pending)", "status": "pending", "depends_on": ["m1-t1"] },
    #|        { "id": "m1-t3", "description": "Auth (pending)", "status": "pending", "depends_on": ["m1-t1"] },
    #|        { "id": "m1-t4", "description": "Docs (done)", "status": "done", "result": "docs ok", "depends_on": [] }
    #|      ]
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(default_response="unused")
  let builder_mock = @agent.MockBackend::new(default_response="fresh result")
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

  // All tasks should be Done
  for task in tasks {
    inspect(task.status, content="Done")
  }

  // Done tasks preserve their original results
  inspect(tasks[0].result.unwrap(), content="schema ok")
  inspect(tasks[3].result.unwrap(), content="docs ok")

  // Pending tasks got fresh results from builder
  inspect(tasks[1].result.unwrap(), content="fresh result")
  inspect(tasks[2].result.unwrap(), content="fresh result")

  // Builder only called for the 2 pending tasks (not the 2 done ones)
  let history = builder_mock.get_history()
  assert_true(history.length() == 2)

  // Skip log emitted for the 2 already-done tasks
  assert_true(
    infos.iter().any(fn(msg) { msg.contains("Skipping 2 already-done tasks") }),
  )

  // Only pending tasks were dispatched
  let dispatch_msgs : Array[String] = infos
    .iter()
    .filter(fn(msg) { msg.contains("Dispatching task") })
    .collect()
  assert_true(dispatch_msgs.length() == 2)
  // Done tasks must NOT appear in dispatch logs
  assert_true(not(dispatch_msgs.iter().any(fn(msg) { msg.contains("m1-t1") })))
  assert_true(not(dispatch_msgs.iter().any(fn(msg) { msg.contains("m1-t4") })))
  // Pending tasks must appear in dispatch logs
  assert_true(dispatch_msgs.iter().any(fn(msg) { msg.contains("m1-t2") }))
  assert_true(dispatch_msgs.iter().any(fn(msg) { msg.contains("m1-t3") }))

  // Milestone completes
  inspect(mgr.milestones[0].status, content="Done")
}

///|
test "run_dag returns false when no builder backend is available" {
  // Config has no Builder agent
  let planner_agent : @types.AgentConfig = {
    id: "planner",
    kind: Mock,
    role: Planner,
    model: None,
  }
  let verifier_agent : @types.AgentConfig = {
    id: "verifier",
    kind: Mock,
    role: Verifier,
    model: None,
  }
  let config : @config.ProjectConfig = {
    agents: [planner_agent, verifier_agent],
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
  let verifier_mock = @agent.MockBackend::new(default_response="<approved>")
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
test "tornado-1fy: detect file conflicts between parallel builders in same layer" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m2", "goal": "Fix prettier config", "status": "pending",
    #|      "tasks": [
    #|        { "id": "m2-t8", "description": "Fix prettier via package.json", "status": "pending" },
    #|        { "id": "m2-t9", "description": "Fix prettier via env variable", "status": "pending" }
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
  let rl = @ralph.RalphLoop::new(config, mgr, backends, callbacks, file_checker=fn(
    _,
  ) {
    true
  })
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
    #|        { "id": "m1-t1", "description": "Build auth module", "status": "pending" },
    #|        { "id": "m1-t2", "description": "Build logging module", "status": "pending" }
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
  let rl = @ralph.RalphLoop::new(config, mgr, backends, callbacks, file_checker=fn(
    _,
  ) {
    true
  })
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
test "run_dag with 3 parallel builders causing multi-file conflicts" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1", "goal": "Refactor config", "status": "pending",
    #|      "tasks": [
    #|        { "id": "m1-t1", "description": "Update config parser", "status": "pending" },
    #|        { "id": "m1-t2", "description": "Add config validator", "status": "pending" },
    #|        { "id": "m1-t3", "description": "Migrate config format", "status": "pending" }
    #|      ]
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(default_response="unused")
  // All three builders touch config.ts; t1 and t3 also both touch parser.ts
  let builder_mock = @agent.MockBackend::new(
    default_response="Done\nFILES_CHANGED: src/config.ts, src/parser.ts",
  )
  builder_mock.add_response(
    "Add config validator", "Done\nFILES_CHANGED: src/config.ts, src/validator.ts",
  )
  builder_mock.add_response(
    "Migrate config format", "Done\nFILES_CHANGED: src/config.ts, src/parser.ts",
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
  let rl = @ralph.RalphLoop::new(config, mgr, backends, callbacks, file_checker=fn(
    _,
  ) {
    true
  })
  rl.run()
  // config.ts is touched by all 3 tasks — must report conflict with 3 task IDs
  assert_true(
    infos
    .iter()
    .any(fn(msg) {
      msg.contains("File conflict") && msg.contains("src/config.ts")
    }),
  )
  // parser.ts is touched by t1 and t3 — must also report conflict
  assert_true(
    infos
    .iter()
    .any(fn(msg) {
      msg.contains("File conflict") && msg.contains("src/parser.ts")
    }),
  )
  // validator.ts is touched only by t2 — no conflict reported for it
  assert_true(
    not(
      infos
      .iter()
      .any(fn(msg) {
        msg.contains("File conflict") && msg.contains("src/validator.ts")
      }),
    ),
  )
  // Milestone should still complete (conflicts are informational, not blocking)
  inspect(mgr.milestones[0].status, content="Done")
}

///|
test "single task layer does not trigger conflict detection" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1", "goal": "Build feature", "status": "pending",
    #|      "tasks": [
    #|        { "id": "m1-t1", "description": "Build auth module", "status": "pending" }
    #|      ]
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(default_response="unused")
  let builder_mock = @agent.MockBackend::new(
    default_response="Done\nFILES_CHANGED: package.json, src/config.ts",
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
  let rl = @ralph.RalphLoop::new(config, mgr, backends, callbacks, file_checker=fn(
    _,
  ) {
    true
  })
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

///|
test "E2E DAG: planner outputs DEPENDS_ON format and DAG dispatches in correct layer order" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    { "id": "m1", "goal": "Build API with auth", "status": "pending", "tasks": [] }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  // Planner outputs DEPENDS_ON format: 4 tasks with diamond dependency
  //   1 (schema) → 2 (handlers), 3 (auth) → 4 (integration tests)
  let plan_output =
    #|TASKS:
    #|1. Create database schema
    #|SCOPE: src/schema.mbt
    #|DEPENDS_ON: (none)
    #|
    #|2. Build API handlers
    #|SCOPE: src/api.mbt
    #|DEPENDS_ON: 1
    #|
    #|3. Add authentication middleware
    #|SCOPE: src/auth.mbt
    #|DEPENDS_ON: 1
    #|
    #|4. Write integration tests
    #|SCOPE: tests/integration.mbt
    #|DEPENDS_ON: 2, 3
  let planner_mock = @agent.MockBackend::new(default_response=plan_output)
  let builder_mock = @agent.MockBackend::new(default_response="fallback")
  builder_mock.add_response("schema", "schema done")
  builder_mock.add_response("handlers", "handlers done")
  builder_mock.add_response("authentication", "auth done")
  builder_mock.add_response("integration", "tests done")
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

  // Milestone should complete successfully
  inspect(mgr.milestones[0].status, content="Done")
  inspect(rl.current_phase, content="AllComplete")

  // Verify 4 tasks were created with correct depends_on
  let tasks = mgr.milestones[0].tasks
  assert_true(tasks.length() == 4)
  inspect(tasks[0].description, content="Create database schema")
  assert_true(tasks[0].depends_on.is_empty())
  inspect(tasks[1].description, content="Build API handlers")
  assert_true(tasks[1].depends_on.length() == 1)
  assert_true(tasks[1].depends_on[0] == tasks[0].id)
  inspect(tasks[2].description, content="Add authentication middleware")
  assert_true(tasks[2].depends_on.length() == 1)
  assert_true(tasks[2].depends_on[0] == tasks[0].id)
  inspect(tasks[3].description, content="Write integration tests")
  assert_true(tasks[3].depends_on.length() == 2)
  assert_true(tasks[3].depends_on[0] == tasks[1].id)
  assert_true(tasks[3].depends_on[1] == tasks[2].id)

  // Verify DAG was executed
  assert_true(
    infos.iter().any(fn(msg) { msg.contains("Executing DAG for m1") }),
  )

  // Verify dispatch logs: task 1 dispatched first (layer 0),
  // then tasks 2 and 3 (layer 1), then task 4 (layer 2)
  assert_true(
    infos
    .iter()
    .any(fn(msg) {
      msg.contains("Dispatching task") && msg.contains(tasks[0].id)
    }),
  )
  assert_true(
    infos
    .iter()
    .any(fn(msg) {
      msg.contains("Dispatching task") && msg.contains(tasks[1].id)
    }),
  )
  assert_true(
    infos
    .iter()
    .any(fn(msg) {
      msg.contains("Dispatching task") && msg.contains(tasks[2].id)
    }),
  )
  assert_true(
    infos
    .iter()
    .any(fn(msg) {
      msg.contains("Dispatching task") && msg.contains(tasks[3].id)
    }),
  )

  // Builder was called 4 times
  assert_true(builder_mock.get_history().length() == 4)

  // All tasks should be done
  for task in tasks {
    inspect(task.status, content="Done")
  }

  // Verify scope was parsed correctly
  assert_true(tasks[0].scope.length() == 1)
  assert_true(tasks[0].scope[0] == "src/schema.mbt")
  assert_true(tasks[3].scope.length() == 1)
  assert_true(tasks[3].scope[0] == "tests/integration.mbt")
}

///|
test "E2E DAG: planner outputs DEPENDS_ON format with max_in_flight=2 batches dispatches" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    { "id": "m1", "goal": "Build features", "status": "pending", "tasks": [] }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  // 3 independent tasks (all layer 0), should be batched by max_in_flight=2
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
  let rl = @ralph.RalphLoop::new(
    config,
    mgr,
    backends,
    callbacks,
    max_in_flight=2,
  )
  rl.run()

  inspect(mgr.milestones[0].status, content="Done")
  assert_true(builder_mock.get_history().length() == 3)

  // max_in_flight=2: batch-parallel dispatch — first batch of 2, then batch of 1.
  let dispatch_msgs : Array[String] = infos
    .iter()
    .filter(fn(msg) {
      msg.contains("Dispatching task") && msg.contains("batch:")
    })
    .collect()
  assert_true(dispatch_msgs.length() == 3)
  // Batch 1: 2 tasks dispatched together
  assert_true(dispatch_msgs[0].contains("batch: 2"))
  assert_true(dispatch_msgs[1].contains("batch: 2"))
  // Batch 2: 1 remaining task
  assert_true(dispatch_msgs[2].contains("batch: 1"))
}

///|
test "E2E: planner output uses TASKS format with DAG execution" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    { "id": "m1", "goal": "Build app", "status": "pending", "tasks": [] }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  // Planner uses TASKS format (DAG-based)
  let planner_mock = @agent.MockBackend::new(
    default_response="TASKS:\n1. Setup database\n2. Build handlers\n3. Write tests",
  )
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

  // Milestone should complete successfully
  inspect(mgr.milestones[0].status, content="Done")
  inspect(rl.current_phase, content="AllComplete")

  // Tasks parsed correctly
  let tasks = mgr.milestones[0].tasks
  assert_true(tasks.length() == 3)
  inspect(tasks[0].description, content="Setup database")
  inspect(tasks[1].description, content="Build handlers")
  inspect(tasks[2].description, content="Write tests")

  // DAG execution was used
  assert_true(
    infos.iter().any(fn(msg) { msg.contains("Executing DAG for m1") }),
  )

  // All 3 builder calls made
  assert_true(builder_mock.get_history().length() == 3)

  // All tasks dispatched
  let dispatch_msgs : Array[String] = infos
    .iter()
    .filter(fn(msg) { msg.contains("Dispatching task") })
    .collect()
  assert_true(dispatch_msgs.length() == 3)

  // All tasks completed
  for task in tasks {
    inspect(task.status, content="Done")
  }
}
