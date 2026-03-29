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
test "tornado-1fy: detect_file_conflicts finds overlapping files" {
  let results : Array[(@types.RalphTask, Array[String])] = []
  let t1 : @types.RalphTask = {
    id: "m1-t1",
    description: "task 1",
    scope: [],
    depends_on: [],
    status: Done,
    result: None,
  }
  let t2 : @types.RalphTask = {
    id: "m1-t2",
    description: "task 2",
    scope: [],
    depends_on: [],
    status: Done,
    result: None,
  }
  results.push((t1, ["package.json", "src/a.ts"]))
  results.push((t2, ["package.json", "src/b.ts"]))
  let conflicts = @ralph.detect_file_conflicts(results)
  assert_true(conflicts.length() == 1)
  let (file, task_ids) = conflicts[0]
  inspect(file, content="package.json")
  assert_true(task_ids.contains("m1-t1"))
  assert_true(task_ids.contains("m1-t2"))
}

///|
test "tornado-1fy: detect_file_conflicts returns empty for no overlaps" {
  let results : Array[(@types.RalphTask, Array[String])] = []
  let t1 : @types.RalphTask = {
    id: "m1-t1",
    description: "task 1",
    scope: [],
    depends_on: [],
    status: Done,
    result: None,
  }
  let t2 : @types.RalphTask = {
    id: "m1-t2",
    description: "task 2",
    scope: [],
    depends_on: [],
    status: Done,
    result: None,
  }
  results.push((t1, ["src/a.ts"]))
  results.push((t2, ["src/b.ts"]))
  let conflicts = @ralph.detect_file_conflicts(results)
  assert_true(conflicts.is_empty())
}

///|
test "detect_scope_overlaps finds overlapping scoped files" {
  let tasks : Array[@types.RalphTask] = []
  let t1 : @types.RalphTask = {
    id: "m1-t1",
    description: "task 1",
    scope: ["src/shared.ts", "src/a.ts"],
    depends_on: [],
    status: Pending,
    result: None,
  }
  let t2 : @types.RalphTask = {
    id: "m1-t2",
    description: "task 2",
    scope: ["src/shared.ts", "src/b.ts"],
    depends_on: [],
    status: Pending,
    result: None,
  }
  tasks.push(t1)
  tasks.push(t2)
  let overlaps = @ralph.detect_scope_overlaps(tasks)
  assert_true(overlaps.length() == 1)
  let (file, task_ids) = overlaps[0]
  inspect(file, content="src/shared.ts")
  assert_true(task_ids.length() == 2)
  assert_true(task_ids.contains("m1-t1"))
  assert_true(task_ids.contains("m1-t2"))
}

///|
test "detect_scope_overlaps returns empty for no overlaps" {
  let tasks : Array[@types.RalphTask] = []
  let t1 : @types.RalphTask = {
    id: "m1-t1",
    description: "task 1",
    scope: ["src/a.ts"],
    depends_on: [],
    status: Pending,
    result: None,
  }
  let t2 : @types.RalphTask = {
    id: "m1-t2",
    description: "task 2",
    scope: ["src/b.ts"],
    depends_on: [],
    status: Pending,
    result: None,
  }
  tasks.push(t1)
  tasks.push(t2)
  let overlaps = @ralph.detect_scope_overlaps(tasks)
  assert_true(overlaps.is_empty())
}

///|
test "detect_scope_overlaps skips tasks with empty scope" {
  let tasks : Array[@types.RalphTask] = []
  let t1 : @types.RalphTask = {
    id: "m1-t1",
    description: "task 1",
    scope: [],
    depends_on: [],
    status: Pending,
    result: None,
  }
  let t2 : @types.RalphTask = {
    id: "m1-t2",
    description: "task 2",
    scope: [],
    depends_on: [],
    status: Pending,
    result: None,
  }
  tasks.push(t1)
  tasks.push(t2)
  let overlaps = @ralph.detect_scope_overlaps(tasks)
  assert_true(overlaps.is_empty())
}

///|
test "detect_file_conflicts with 3 tasks all sharing the same file" {
  let results : Array[(@types.RalphTask, Array[String])] = []
  let t1 : @types.RalphTask = {
    id: "m1-t1",
    description: "task 1",
    scope: [],
    depends_on: [],
    status: Done,
    result: None,
  }
  let t2 : @types.RalphTask = {
    id: "m1-t2",
    description: "task 2",
    scope: [],
    depends_on: [],
    status: Done,
    result: None,
  }
  let t3 : @types.RalphTask = {
    id: "m1-t3",
    description: "task 3",
    scope: [],
    depends_on: [],
    status: Done,
    result: None,
  }
  results.push((t1, ["shared.ts", "a.ts"]))
  results.push((t2, ["shared.ts", "b.ts"]))
  results.push((t3, ["shared.ts", "c.ts"]))
  let conflicts = @ralph.detect_file_conflicts(results)
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
test "run_dag fails builder result when reported files are missing from worktree" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1", "goal": "Create config", "status": "pending",
    #|      "tasks": [
    #|        { "id": "m1-t1", "description": "Create config file", "status": "pending" }
    #|      ]
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(default_response="unused")
  let builder_mock = @agent.MockBackend::new(
    default_response="Done\nFILES_CHANGED: does-not-exist.txt",
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
    false
  })
  rl.run()
  assert_true(mgr.milestones[0].status is @types.MilestoneStatus::Failed(_))
  assert_true(
    infos
    .iter()
    .any(fn(msg) { msg.contains("post-run file verification failed") }),
  )
}

///|
test "validate_builder_result fails on partial file missing (whirlwind-aps)" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1", "goal": "Create config", "status": "pending",
    #|      "tasks": [
    #|        { "id": "m1-t1", "description": "Create config and scripts", "status": "pending" }
    #|      ]
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(default_response="unused")
  // Builder reports creating two files, but config/snowflake.yml doesn't persist
  let builder_mock = @agent.MockBackend::new(
    default_response="Done\nFILES_CHANGED: scripts/query.py, config/snowflake.yml",
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
  // Only scripts/query.py exists; config/snowflake.yml is missing
  let rl = @ralph.RalphLoop::new(config, mgr, backends, callbacks, file_checker=fn(
    path,
  ) {
    path == "scripts/query.py"
  })
  rl.run()
  // Strict check: task should fail because config/snowflake.yml is missing
  assert_true(mgr.milestones[0].status is @types.MilestoneStatus::Failed(_))
  assert_true(
    infos
    .iter()
    .any(fn(msg) {
      msg.contains("post-run file verification failed") &&
      msg.contains("config/snowflake.yml")
    }),
  )
  // scripts/query.py should NOT appear in missing files
  assert_true(
    not(
      infos
      .iter()
      .any(fn(msg) {
        msg.contains("post-run file verification failed") &&
        msg.contains("scripts/query.py")
      }),
    ),
  )
}

///|
test "verify_milestone fails when max rework attempts are exhausted" {
  // Use max_rework_attempts=2 to test the exact boundary
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
    max_rework_attempts: 2,
  }
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1", "goal": "Build auth", "status": "pending",
    #|      "tasks": [
    #|        { "id": "m1-t1", "description": "Implement feature", "status": "pending" }
    #|      ]
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(default_response="unused")
  // Builder returns different results each time to avoid triggering no-change circuit breaker
  let builder_seq = @agent.SequenceMockBackend::new([
    "Done v1", "Done v2 reworked", "Done v3 reworked again",
  ])
  // Verifier always returns needs_rework — never approves
  let verifier_mock = @agent.MockBackend::new(
    default_response="<needs_rework>m1-t1: still broken</needs_rework>",
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
  // Max rework should be reached and milestone should fail.
  assert_true(
    infos.iter().any(fn(msg) { msg.contains("Max rework attempts reached") }),
  )
  assert_true(mgr.milestones[0].status is @types.MilestoneStatus::Failed(_))
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
test "verify_milestone fails after rework when re-verify returns milestone_failed" {
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
  let builder_mock = @agent.MockBackend::new(default_response="Done v1")
  builder_mock.add_response("Feedback from verifier", "Done v2 REWORKED")
  let verifier_mock = @agent.MockBackend::new(default_response="<approved>")
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
test "circuit breaker activates on infra failure during verification" {
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
  let builder_mock = @agent.MockBackend::new(
    default_response="Task completed successfully",
  )
  // Verifier backend always fails (simulates infra failure)
  let verifier_mock = @agent.FailingMockBackend::new(
    error_msg="Codex Exec exited with code 1: Reading prompt from stdin...",
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
  // Milestone should fail with infra failure
  assert_true(mgr.milestones[0].status is @types.MilestoneStatus::Failed(_))
  // Should log circuit breaker activation
  assert_true(
    infos
    .iter()
    .any(fn(msg) {
      msg.contains("Circuit breaker") && msg.contains("infrastructure")
    }),
  )
  // Rework should NOT be attempted (circuit breaker skips rework)
  assert_false(infos.iter().any(fn(msg) { msg.contains("Reworking task") }))
}

///|
test "Info events from handle_event carry agent_id" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    { "id": "m1", "goal": "Build feature", "status": "pending", "tasks": [] }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(
    default_response="TASKS:\n1. Build component",
  )
  let builder_mock = @agent.MockBackend::new(
    default_response="Task completed successfully",
  )
  let verifier_mock = @agent.MockBackend::new(default_response="<approved>")
  let backends : Map[String, @agent.BoxedBackend] = {}
  backends["planner"] = planner_mock.boxed()
  backends["builder"] = builder_mock.boxed()
  backends["verifier"] = verifier_mock.boxed()
  let info_events : Array[@types.InfoEvent] = []
  let callbacks : @types.OrchestratorCallbacks = {
    on_event: fn(e) {
      match e {
        Info(ev) => info_events.push(ev)
        _ => ()
      }
    },
    on_save: fn() {  },
  }
  let rl = @ralph.RalphLoop::new(config, mgr, backends, callbacks)
  rl.run()
  // Orchestrator-level infos have empty agent_id
  let orchestrator_infos = info_events
    .iter()
    .filter(fn(ev) { ev.agent_id == "" })
  assert_true(orchestrator_infos.count() > 0)
  // All info events should have agent_id field (either empty or populated)
  for ev in info_events {
    // agent_id is always a String -- never absent
    let _ = ev.agent_id
    let _ = ev.message
  }
}

///|
test "is_infra_failure detects all-infra-error pattern" {
  let items = [
    "[CodeQuality] Verification failed: [CodeQuality] Codex Exec exited with code 1: Reading prompt from stdin...",
    "[Performance] Verification failed: [Performance] Codex Exec exited with code 1: Reading prompt from stdin...",
    "[Security] Verification failed: [Security] Codex Exec exited with code 1: Reading prompt from stdin...",
    "[GoalAlignment] Verification failed: [GoalAlignment] Codex Exec exited with code 1: Reading prompt from stdin...",
  ]
  assert_true(@ralph.is_infra_failure(items))
}

///|
test "is_infra_failure rejects mixed real and infra errors" {
  let items = [
    "[CodeQuality] Verification failed: [CodeQuality] Codex Exec exited with code 1",
    "m1-t1: [Security] fix validation logic",
  ]
  assert_false(@ralph.is_infra_failure(items))
}

///|
test "is_infra_failure rejects real code issues" {
  let items = [
    "m1-t1: [CodeQuality] fix error handling", "m1-t2: [Security] add input validation",
  ]
  assert_false(@ralph.is_infra_failure(items))
}

///|
test "is_infra_failure rejects empty items" {
  let items : Array[String] = []
  assert_false(@ralph.is_infra_failure(items))
}

///|
test "is_server_error detects 500 Internal server error" {
  assert_true(@ralph.is_server_error("Internal server error"))
}

///|
test "is_server_error detects 529 overloaded" {
  assert_true(@ralph.is_server_error("API error: 529 overloaded"))
}

///|
test "is_server_error rejects 400 client error" {
  assert_false(@ralph.is_server_error("Bad request: invalid parameter"))
}

///|
test "is_server_error rejects 401 authentication error" {
  assert_false(@ralph.is_server_error("Authentication failed"))
}

///|
test "is_server_error rejects empty error" {
  assert_false(@ralph.is_server_error(""))
}

///|
test "builder task retries on server error and succeeds" {
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
  // Builder fails twice with server error, then succeeds
  let builder_mock = @agent.FailNTimesMockBackend::new(
    2,
    error_msg="Internal server error",
    success_response="Task completed successfully",
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
  // Milestone should complete (retry succeeded)
  inspect(mgr.milestones[0].status, content="Done")
  // Should log retry attempts
  assert_true(
    infos.iter().any(fn(msg) { msg.contains("retry") && msg.contains("1/3") }),
  )
  assert_true(
    infos.iter().any(fn(msg) { msg.contains("retry") && msg.contains("2/3") }),
  )
}

///|
test "builder task fails after max retries on persistent server error" {
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
  // Builder always fails with server error (more failures than max retries)
  let builder_mock = @agent.FailNTimesMockBackend::new(
    10,
    error_msg="Internal server error",
    success_response="never reached",
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
  // Milestone should fail after exhausting retries
  assert_true(mgr.milestones[0].status is @types.MilestoneStatus::Failed(_))
  // Should have 3 retry attempts logged
  assert_true(
    infos.iter().any(fn(msg) { msg.contains("retry") && msg.contains("3/3") }),
  )
  // Should log final failure
  assert_true(infos.iter().any(fn(msg) { msg.contains("failed") }))
}

///|
test "builder task does not retry on client error (4xx)" {
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
  // Builder fails with a client error (should not retry)
  let builder_mock = @agent.FailingMockBackend::new(
    error_msg="Bad request: invalid prompt format",
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
  // Milestone should fail immediately (no retries)
  assert_true(mgr.milestones[0].status is @types.MilestoneStatus::Failed(_))
  // No retry messages should appear
  assert_false(
    infos.iter().any(fn(msg) { msg.contains("retry") && msg.contains("/3") }),
  )
}
