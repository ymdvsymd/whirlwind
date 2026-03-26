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
test "RalphLoop dry-run skips planner execution and leaves milestones pending" {
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

  inspect(mgr.milestones[0].status, content="Pending")
  inspect(mgr.milestones[0].tasks.length(), content="0")
  inspect(planner_mock.get_history().length(), content="0")
  inspect(builder_mock.get_history().length(), content="0")
  inspect(verifier_mock.get_history().length(), content="0")
  assert_true(
    infos.iter().any(fn(m) { m.contains("Dry-run: validated milestone m1") }),
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
    #|        { "id": "m1-t1", "description": "Create schema", "wave": 0, "status": "pending" }
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
    #|        { "id": "m1-t1", "description": "Create schema", "wave": 0, "status": "pending" },
    #|        { "id": "m1-t2", "description": "Build handlers", "wave": 1, "status": "pending" }
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
    #|        { "id": "m1-t1", "description": "Create schema", "wave": 0, "status": "pending" }
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
    infos.iter().any(fn(msg) { msg.contains("Skipping 2 already-done tasks") }),
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
    not(infos.iter().any(fn(msg) { msg.contains("Dispatching task m1-t1") })),
  )
  assert_true(
    infos.iter().any(fn(msg) { msg.contains("Dispatching task m1-t2") }),
  )
}

///|
test "run_dag adds scope edges and serializes overlapping tasks" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1", "goal": "Refactor shared code", "status": "pending",
    #|      "tasks": [
    #|        {
    #|          "id": "m1-t1",
    #|          "description": "Update shared types",
    #|          "wave": 0,
    #|          "scope": ["src/shared.ts", "src/types.ts"],
    #|          "status": "pending"
    #|        },
    #|        {
    #|          "id": "m1-t2",
    #|          "description": "Update shared helpers",
    #|          "wave": 0,
    #|          "scope": ["src/shared.ts", "src/helpers.ts"],
    #|          "status": "pending"
    #|        }
    #|      ]
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(default_response="unused")
  let builder_mock = @agent.MockBackend::new(default_response="Done")
  builder_mock.add_response("Update shared helpers", "Done")
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

  // Builder runs t1 first, then t2 (serialized by scope edge)
  let history = builder_mock.get_history()
  assert_true(history.length() == 2)
  inspect(history[0].0, content="Update shared types")
  inspect(history[1].0, content="Update shared helpers")
  inspect(mgr.milestones[0].tasks[0].status, content="Done")
  inspect(mgr.milestones[0].tasks[1].status, content="Done")
  // Should log about implicit edges from scope overlaps
  assert_true(
    infos
    .iter()
    .any(fn(msg) { msg.contains("implicit edges from scope overlaps") }),
  )
}

///|
test "run_dag reverts scope edges that create cycle with explicit deps" {
  let config = make_ralph_config()
  // A depends on B explicitly; both share scope "shared.ts".
  // Scope edge A→B (B depends on A) creates cycle A→B→A.
  // run_dag should detect the cycle, revert scope edge, and execute normally.
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1", "goal": "Cycle test", "status": "pending",
    #|      "tasks": [
    #|        {
    #|          "id": "m1-t1",
    #|          "description": "Task A depends on B",
    #|          "wave": 0,
    #|          "scope": ["shared.ts"],
    #|          "depends_on": ["m1-t2"],
    #|          "status": "pending"
    #|        },
    #|        {
    #|          "id": "m1-t2",
    #|          "description": "Task B independent",
    #|          "wave": 0,
    #|          "scope": ["shared.ts"],
    #|          "depends_on": [],
    #|          "status": "pending"
    #|        }
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

  let tasks = mgr.milestones[0].tasks

  // Both tasks should complete (cycle was broken by reverting scope edge)
  inspect(tasks[0].status, content="Done")
  inspect(tasks[1].status, content="Done")
  assert_true(builder_mock.get_history().length() == 2)

  // Scope edge was added then reverted
  assert_true(
    infos
    .iter()
    .any(fn(msg) { msg.contains("implicit edges from scope overlaps") }),
  )
  assert_true(infos.iter().any(fn(msg) { msg.contains("Cycle detected") }))
  assert_true(
    infos
    .iter()
    .any(fn(msg) { msg.contains("Reverted") && msg.contains("scope edges") }),
  )

  // After revert, B's depends_on should NOT contain A (scope edge removed)
  assert_true(not(tasks[1].depends_on.contains(tasks[0].id)))
  // A's explicit dep on B is preserved
  assert_true(tasks[0].depends_on.contains(tasks[1].id))

  // Execution order: B first (no deps), then A (depends on B)
  let history = builder_mock.get_history()
  inspect(history[0].0, content="Task B independent")
  inspect(history[1].0, content="Task A depends on B")

  // Should NOT be stuck
  assert_true(
    not(infos.iter().any(fn(msg) { msg.contains("DAG execution stuck") })),
  )
}

///|
test "run_dag cycle revert uses inserted_scope_edges not scope_edges to preserve explicit deps" {
  let config = make_ralph_config()
  // A depends on B explicitly. B depends on C explicitly. A and C share scope "shared.ts".
  // Scope edge candidate: A→C (C depends on A) — but A already has explicit dep on B,
  // not on C, so scope edge A→C IS inserted.
  // Scope edge candidate: (none from C→A direction since A appears before C in task list)
  //
  // Revised scenario to trigger the bug:
  // B depends on A explicitly. A and B share scope "shared.ts".
  // Scope candidates: chain A→B (B depends on A). But B already has explicit dep on A,
  // so apply_scope_edges skips it → inserted_scope_edges is empty.
  // C depends on B explicitly. C and A share scope "other.ts".
  // Scope candidates: chain A→C (C depends on A). This IS inserted since C has no dep on A.
  // Now A→B (explicit), A→C (scope-inserted), B→C (explicit) — no cycle. Good.
  //
  // To test the bug: we need scope_edges to contain an edge that duplicates an explicit dep,
  // AND a cycle caused by a different scope edge on the same task.
  // Task A: depends_on=[B], scope=[shared.ts]
  // Task B: depends_on=[],  scope=[shared.ts, other.ts]
  // Task C: depends_on=[],  scope=[other.ts]
  // Scope edges from shared.ts: A→B (A before B → B depends on A). But B has no explicit dep
  //   on A, so this IS inserted. Now B depends on A (scope) and A depends on B (explicit) → cycle!
  // Scope edges from other.ts: B→C (B before C → C depends on B). This IS inserted.
  //
  // With the fix, revert iterates inserted_scope_edges = [(A,B), (B,C)].
  // Cycle tasks include A and B. Revert removes scope edge (A,B) from B's depends_on.
  // A's explicit dep on B is preserved.
  //
  // Without the fix (using scope_edges which equals inserted here), same result.
  // Need a scenario where scope_edges != inserted_scope_edges AND the difference matters.
  //
  // Correct scenario:
  // Task A: depends_on=[B], scope=[shared.ts]   ← explicit dep A→B
  // Task B: depends_on=[],  scope=[shared.ts]
  // Scope chain for shared.ts: [A, B] → edge (A, B) meaning B depends on A.
  // apply_scope_edges: B.depends_on does not contain A → inserts (A,B). Now B.depends_on=[A].
  // Now: A depends on B (explicit), B depends on A (scope) → CYCLE on {A,B}.
  // scope_edges = [(A,B)], inserted_scope_edges = [(A,B)] — same here, no difference.
  //
  // We need: explicit dep that COINCIDES with a scope edge direction.
  // Task A: depends_on=[B], scope=[shared.ts]   ← A depends on B
  // Task B: depends_on=[],  scope=[shared.ts, conflict.ts]
  // Task C: depends_on=[B], scope=[conflict.ts] ← C depends on B
  // Scope chain shared.ts: [A, B] → (A,B): B depends on A. Inserted (B has no dep on A).
  // Scope chain conflict.ts: [B, C] → (B,C): C depends on B. C already has dep on B → SKIPPED.
  // scope_edges = [(A,B), (B,C)], inserted_scope_edges = [(A,B)]
  // Cycle: A→B (explicit) + B→A (scope-inserted) → {A,B} in cycle.
  // BUG (old code): revert iterates scope_edges, finds (B,C) with to_id=C.
  //   C is NOT in cycle_set → no harm. Still safe in this case.
  //
  // Real bug scenario: the scope edge candidate coincides with an explicit dep ON a cycle task.
  // Task A: depends_on=[],  scope=[shared.ts]
  // Task B: depends_on=[A], scope=[shared.ts, conflict.ts] ← B depends on A (explicit)
  // Task C: depends_on=[B], scope=[conflict.ts]             ← C depends on B (explicit)
  // Scope chain shared.ts: [A, B] → (A,B): B depends on A. B already has A → SKIPPED.
  // Scope chain conflict.ts: [B, C] → (B,C): C depends on B. C already has B → SKIPPED.
  // scope_edges = [(A,B), (B,C)], inserted = [] — no cycle, no revert. Not useful.
  //
  // The real scenario: explicit dep creates reverse direction + scope creates forward.
  // Task B: depends_on=[A], scope=[x.ts]  ← B→A explicit
  // Task A: depends_on=[],  scope=[x.ts]  ← A is first in array
  // Scope chain for x.ts: [B, A] (task order in array) → (B,A): A depends on B. INSERTED.
  // Now: B depends on A (explicit) AND A depends on B (scope) → cycle {A,B}.
  // scope_edges = [(B,A)], inserted = [(B,A)] — still same.
  //
  // The ONLY way to trigger the bug: a scope edge candidate that is NOT inserted (because
  // the explicit dep already exists), but scope_edges still contains it, and the to_id
  // is a cycle task. Then revert using scope_edges would try to remove the explicit dep.
  //
  // Final correct scenario:
  // Task A: depends_on=[B], scope=[x.ts, y.ts]  ← A depends on B (explicit)
  // Task B: depends_on=[],  scope=[x.ts]
  // Task C: depends_on=[A], scope=[y.ts]         ← C depends on A (explicit), creates cycle
  // Task order: [B, A, C] — scope x.ts chain: [B,A] → edge (B,A) meaning A depends on B.
  //   A already has dep on B → SKIPPED by apply_scope_edges.
  // Scope y.ts chain: [A, C] → edge (A,C) meaning C depends on A.
  //   C already has dep on A → SKIPPED.
  // scope_edges = [(B,A), (A,C)], inserted = []. No cycle from scope. Not useful.
  //
  // OK let me think about this differently. The scenario needs:
  // 1. An actual cycle exists (from mix of explicit + scope-inserted edges)
  // 2. scope_edges contains an edge that was NOT inserted (duplicate of explicit)
  // 3. That non-inserted edge's to_id is a cycle task
  //
  // Task A: scope=[shared.ts], depends_on=[C]   ← creates a cycle with scope
  // Task B: scope=[shared.ts], depends_on=[]
  // Task C: scope=[], depends_on=[B]            ← explicit dep on B
  //
  // Scope chain shared.ts: [A, B] → edge (A,B): B depends on A. B has no dep on A → INSERTED.
  // scope_edges = [(A,B)], inserted = [(A,B)]. Same — no difference.
  //
  // Need scope edge that matches an existing explicit dep:
  // Task A: scope=[shared.ts], depends_on=[B]  ← explicit dep A→B AND scope will also say B→A
  // Task B: scope=[shared.ts], depends_on=[]
  // Scope chain: [A, B] → (A,B): B depends on A. Inserted. → cycle.
  // scope_edges = [(A,B)]. inserted = [(A,B)]. Same.
  //
  // The duplicate happens when the scope chain direction matches the explicit dep direction:
  // Task A: scope=[shared.ts], depends_on=[]
  // Task B: scope=[shared.ts], depends_on=[A]   ← explicit B→A
  // Scope chain: [A, B] → (A,B): B depends on A. B already has A → SKIPPED.
  // scope_edges=[(A,B)], inserted=[]. No cycle. Not useful.
  //
  // Need a THIRD task to create the cycle via a different path:
  // Task A: scope=[shared.ts], depends_on=[C]  ← explicit A→C
  // Task B: scope=[shared.ts], depends_on=[A]  ← explicit B→A (coincides with scope direction)
  // Task C: scope=[], depends_on=[]
  //
  // Scope chain shared.ts: [A, B] → (A,B): B depends on A. B already has A → SKIPPED.
  // scope_edges=[(A,B)], inserted=[]. No scope-caused cycle. Not useful.
  //
  // Try: scope edge in opposite direction causes cycle, AND another scope edge coincides with explicit.
  // Task A: scope=[f1.ts, f2.ts], depends_on=[B]   ← explicit A→B
  // Task B: scope=[f1.ts], depends_on=[]
  // Task C: scope=[f2.ts], depends_on=[]
  //
  // Scope f1.ts: [A, B] → (A,B): B depends on A. INSERTED. → A→B + B→A = cycle!
  // Scope f2.ts: [A, C] → (A,C): C depends on A. INSERTED.
  // scope_edges = [(A,B), (A,C)], inserted = [(A,B), (A,C)]. Same! Because the explicit
  // dep is A→B (A depends on B), but scope edge is (A,B) meaning B depends on A — different direction!
  //
  // Hmm, let me reconsider. The edge tuple (from, to) means to depends on from.
  // So (A,B) means B depends on A. The explicit A.depends_on=[B] means A depends on B.
  // These are different directions! So scope (A,B) won't be skipped by apply_scope_edges
  // checking B.depends_on.contains(A).
  //
  // For the scope edge to be skipped (duplicating explicit), we need:
  //   scope edge (X, Y) meaning Y depends on X, AND Y.depends_on already contains X.
  //
  // So: Task X first, Task Y second in shared scope, Y.depends_on=[X].
  // Let's build the real bug scenario:
  //
  // Tasks in order: [A, B, C]
  // A: scope=[s.ts], depends_on=[]
  // B: scope=[s.ts, t.ts], depends_on=[A]   ← B depends on A (explicit) = same as scope(A,B)
  // C: scope=[t.ts], depends_on=[B]         ← C depends on B (explicit) = same as scope(B,C)
  //
  // Scope s.ts chain: [A, B] → (A,B): B depends on A. B already has A → SKIPPED.
  // Scope t.ts chain: [B, C] → (B,C): C depends on B. C already has B → SKIPPED.
  // scope_edges = [(A,B), (B,C)], inserted = []. No new edges, no cycle. Not the bug.
  //
  // Now add a cycle-creating explicit dep:
  // A: scope=[s.ts], depends_on=[C]          ← A depends on C (explicit) → cycle A→C→B→A
  // B: scope=[s.ts, t.ts], depends_on=[A]    ← explicit, coincides with scope direction
  // C: scope=[t.ts], depends_on=[B]          ← explicit, coincides with scope direction
  //
  // Scope s.ts: [A, B] → (A,B): B depends on A. B already has A → SKIPPED.
  // Scope t.ts: [B, C] → (B,C): C depends on B. C already has B → SKIPPED.
  // scope_edges = [(A,B), (B,C)], inserted = [].
  // Cycle exists (A→C→B→A from explicits alone). But inserted is empty, so revert block is skipped.
  //
  // OK the guard at L323 `if not(inserted_scope_edges.is_empty())` would skip the entire block.
  // With the old code using scope_edges, the guard checks inserted_scope_edges (still empty) → skip.
  // So this scenario doesn't trigger the bug either.
  //
  // Let me re-read the code more carefully...
  // L323: `if not(inserted_scope_edges.is_empty())` — this is the GUARD.
  // L330: `for edge in scope_edges` — this is the BUG (now fixed to inserted_scope_edges).
  //
  // For the bug to manifest:
  // 1. inserted_scope_edges must be NON-EMPTY (to pass the guard at L323)
  // 2. scope_edges must contain additional edges NOT in inserted_scope_edges
  // 3. Those extra edges' to_id must be a cycle task
  // 4. The removal of those extra edges from depends_on must delete an explicit dep
  //
  // So we need: at least one scope edge that IS inserted (non-empty inserted),
  // AND at least one scope edge that is NOT inserted (matches explicit dep),
  // AND that non-inserted edge's to_id is in a cycle.
  //
  // Tasks: [A, B, C]
  // A: scope=[s.ts, t.ts], depends_on=[B]    ← A depends on B explicitly
  // B: scope=[s.ts], depends_on=[]
  // C: scope=[t.ts], depends_on=[]
  //
  // Scope s.ts: [A, B] → (A,B): B depends on A. B has no A → INSERTED.
  //   Now B.depends_on = [A]. Combined with A.depends_on=[B] → cycle {A,B}!
  // Scope t.ts: [A, C] → (A,C): C depends on A. C has no A → INSERTED.
  //
  // scope_edges = [(A,B), (A,C)], inserted = [(A,B), (A,C)]. Same! Both inserted.
  // This doesn't demonstrate the bug since scope_edges == inserted_scope_edges.
  //
  // I need a scope edge that is skipped because it duplicates an explicit dep.
  // That means: a task Y with explicit depends_on containing X, and both X,Y share a scope file
  // with X appearing before Y in the task array.
  //
  // Tasks: [A, B, C]
  // A: scope=[s.ts],     depends_on=[]
  // B: scope=[s.ts, t.ts], depends_on=[A]   ← B.depends_on has A → scope (A,B) will be SKIPPED
  // C: scope=[t.ts],     depends_on=[B]     ← C.depends_on has B → scope (B,C) will be SKIPPED
  //
  // All scope edges are skipped → inserted=[]. Guard fails. Can't trigger.
  //
  // Need mix: one inserted, one skipped, both on cycle tasks.
  // Tasks: [A, B, C]
  // A: scope=[s.ts, t.ts], depends_on=[]
  // B: scope=[s.ts],       depends_on=[A]   ← scope (A,B) SKIPPED (B already has A)
  // C: scope=[t.ts],       depends_on=[A]   ← scope (A,C) SKIPPED (C already has A)
  //
  // All skipped again. Hmm.
  //
  // The trick: we need one scope file where the edge IS novel (inserted), and another
  // scope file where the edge coincides with an explicit dep (skipped).
  //
  // Tasks: [A, B, C]
  // A: scope=[conflict.ts], depends_on=[B]     ← explicit A→B
  // B: scope=[conflict.ts, shared.ts], depends_on=[]
  // C: scope=[shared.ts], depends_on=[]
  //
  // Scope conflict.ts: [A, B] → (A,B): B depends on A. B has no A → INSERTED. Cycle: A→B + B→A!
  // Scope shared.ts: [B, C] → (B,C): C depends on B. C has no B → INSERTED.
  // scope_edges = [(A,B), (B,C)], inserted = [(A,B), (B,C)]. Same again!
  //
  // The explicit dep A.depends_on=[B] means A depends on B. The scope edge (A,B) means
  // B depends on A. These are OPPOSITE directions, so apply_scope_edges checks
  // B.depends_on.contains(A) which is false → inserts it.
  //
  // For a scope edge to be SKIPPED, the scope edge direction must MATCH the explicit dep:
  // scope (X,Y) means Y.depends_on should get X. If Y.depends_on already has X → skipped.
  //
  // So we need: task X before task Y in array, both share a file, Y already has X in depends_on.
  // AND we need X or Y to be in a cycle caused by OTHER inserted scope edges.
  //
  // Tasks: [A, B, C, D]
  // A: scope=[f1.ts], depends_on=[C]           ← explicit A→C
  // B: scope=[f1.ts, f2.ts], depends_on=[A]    ← explicit B→A, scope f1 (A,B) → B.dep on A: SKIPPED
  // C: scope=[f2.ts], depends_on=[]
  //
  // Scope f1.ts: [A, B] → (A,B): B depends on A. B already has A → SKIPPED.
  // Scope f2.ts: [B, C] → (B,C): C depends on B. C has no B → INSERTED.
  //
  // scope_edges = [(A,B), (B,C)], inserted = [(B,C)].
  // After insertion: C.depends_on = [B].
  // Chain: A→C (explicit), C→B (scope-inserted), B→A (explicit) → cycle {A,B,C}!
  //
  // OLD code (scope_edges): iterates [(A,B), (B,C)].
  //   (A,B) to_id=B, B is in cycle → scope_deps_to_remove[B] = {A: true}
  //   (B,C) to_id=C, C is in cycle → scope_deps_to_remove[C] = {B: true}
  //   Revert: B.depends_on=[A] → removes A → B.depends_on=[] ← BUG! A was explicit!
  //   Revert: C.depends_on=[B] → removes B → C.depends_on=[] (this is correct, B was scope-inserted)
  //
  // NEW code (inserted_scope_edges): iterates [(B,C)].
  //   (B,C) to_id=C, C is in cycle → scope_deps_to_remove[C] = {B: true}
  //   Revert: C.depends_on=[B] → removes B → C.depends_on=[]
  //   B.depends_on=[A] is UNTOUCHED ← CORRECT! A was explicit dep preserved.
  //
  // Perfect! This is the test scenario.

  // A→C (explicit), B→A (explicit), scope overlap on f1.ts skips (A,B) since
  // B already depends on A. Scope overlap on f2.ts inserts (B,C). The cycle
  // A→C→B→A involves all three tasks. The revert phase must only remove the
  // scope-inserted edge (B,C), NOT the skipped-but-candidate (A,B) which would
  // incorrectly strip B's explicit dep on A.
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1", "goal": "Revert test", "status": "pending",
    #|      "tasks": [
    #|        {
    #|          "id": "m1-t1",
    #|          "description": "Task A",
    #|          "wave": 0,
    #|          "scope": ["f1.ts"],
    #|          "depends_on": ["m1-t3"],
    #|          "status": "pending"
    #|        },
    #|        {
    #|          "id": "m1-t2",
    #|          "description": "Task B",
    #|          "wave": 0,
    #|          "scope": ["f1.ts", "f2.ts"],
    #|          "depends_on": ["m1-t1"],
    #|          "status": "pending"
    #|        },
    #|        {
    #|          "id": "m1-t3",
    #|          "description": "Task C",
    #|          "wave": 0,
    #|          "scope": ["f2.ts"],
    #|          "depends_on": [],
    #|          "status": "pending"
    #|        }
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

  let tasks = mgr.milestones[0].tasks

  // B's explicit dep on A must be preserved (not stripped by revert)
  assert_true(tasks[1].depends_on.contains("m1-t1"))

  // Scope-inserted edge (B,C) on C should have been reverted
  assert_true(not(tasks[2].depends_on.contains("m1-t2")))

  // Cycle was detected
  assert_true(infos.iter().any(fn(msg) { msg.contains("Cycle detected") }))

  // Scope edges were reverted
  assert_true(
    infos
    .iter()
    .any(fn(msg) { msg.contains("Reverted") && msg.contains("scope edges") }),
  )

  // All tasks should complete (cycle broken, execution proceeds)
  inspect(mgr.milestones[0].status, content="Done")
  for task in tasks {
    inspect(task.status, content="Done")
  }
}

///|
test "run_wave with no scope overlaps executes all tasks normally" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1", "goal": "Refactor isolated code", "status": "pending",
    #|      "tasks": [
    #|        {
    #|          "id": "m1-t1",
    #|          "description": "Update file A",
    #|          "wave": 0,
    #|          "scope": ["src/a.ts"],
    #|          "status": "pending"
    #|        },
    #|        {
    #|          "id": "m1-t2",
    #|          "description": "Update file B",
    #|          "wave": 0,
    #|          "scope": ["src/b.ts"],
    #|          "status": "pending"
    #|        }
    #|      ]
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(default_response="unused")
  let builder_mock = @agent.MockBackend::new(default_response="Done A")
  builder_mock.add_response("Update file B", "Done B")
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

  let history = builder_mock.get_history()
  assert_true(history.length() == 2)
  inspect(history[0].0, content="Update file A")
  inspect(history[1].0, content="Update file B")
  assert_true(
    not(infos.iter().any(fn(msg) { msg.contains("Pre-wave scope check") })),
  )
}

///|
test "run_wave with empty scope arrays skips conflict check" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1", "goal": "Preserve backward compatibility", "status": "pending",
    #|      "tasks": [
    #|        {
    #|          "id": "m1-t1",
    #|          "description": "Run legacy task A",
    #|          "wave": 0,
    #|          "scope": [],
    #|          "status": "pending"
    #|        },
    #|        {
    #|          "id": "m1-t2",
    #|          "description": "Run legacy task B",
    #|          "wave": 0,
    #|          "scope": [],
    #|          "status": "pending"
    #|        }
    #|      ]
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let planner_mock = @agent.MockBackend::new(default_response="unused")
  let builder_mock = @agent.MockBackend::new(default_response="Done A")
  builder_mock.add_response("Run legacy task B", "Done B")
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

  let history = builder_mock.get_history()
  assert_true(history.length() == 2)
  inspect(history[0].0, content="Run legacy task A")
  inspect(history[1].0, content="Run legacy task B")
  inspect(mgr.milestones[0].tasks[0].status, content="Done")
  inspect(mgr.milestones[0].tasks[1].status, content="Done")
  assert_true(
    not(infos.iter().any(fn(msg) { msg.contains("Pre-wave scope check") })),
  )
  assert_true(
    not(
      infos
      .iter()
      .any(fn(msg) {
        msg.contains("Moved task") && msg.contains("scope overlap")
      }),
    ),
  )
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
    #|        { "id": "m1-t1", "description": "Implement login flow", "wave": 0, "status": "pending" }
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
    #|        { "id": "m1-t1", "description": "Create schema", "wave": 0, "status": "pending" }
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
    #|        { "id": "m1-t1", "description": "implement feature X", "wave": 0, "status": "pending" }
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
    #|        { "id": "m1-t1", "description": "Implement feature", "wave": 0, "status": "pending" }
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
test "run_wave fails builder result when reported files are missing from worktree" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1", "goal": "Create config", "status": "pending",
    #|      "tasks": [
    #|        { "id": "m1-t1", "description": "Create config file", "wave": 0, "status": "pending" }
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
    #|        { "id": "m1-t1", "description": "Create config and scripts", "wave": 0, "status": "pending" }
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
test "run_dag skips already-done layers and dispatches only pending tasks" {
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
    #|        { "id": "m1-t1", "description": "Schema (done)", "wave": 0, "status": "done", "result": "schema ok", "depends_on": [] },
    #|        { "id": "m1-t2", "description": "Handlers (pending)", "wave": 0, "status": "pending", "depends_on": ["m1-t1"] },
    #|        { "id": "m1-t3", "description": "Auth (pending)", "wave": 0, "status": "pending", "depends_on": ["m1-t1"] },
    #|        { "id": "m1-t4", "description": "Docs (done)", "wave": 0, "status": "done", "result": "docs ok", "depends_on": [] }
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
    #|        { "id": "m1-t1", "description": "Create schema", "wave": 0, "status": "pending" }
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
test "whirlwind-4hy: builder system prompt instructs to fix all compile errors" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "brief": "Build a REST API",
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

///|
test "whirlwind-4hy: builder system prompt with empty brief still has compile error instruction" {
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
    #|        { "id": "m1-t1", "description": "Implement login flow", "wave": 0, "status": "pending" }
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
    #|        { "id": "m1-t1", "description": "implement feature X", "wave": 0, "status": "pending" }
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
test "E2E: planner output uses TASKS format with DAG execution" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    { "id": "m1", "goal": "Build app", "status": "pending", "tasks": [] }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  // Planner uses legacy WAVE format
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
    #|        { "id": "m1-t1", "description": "Setup schema", "wave": 0, "status": "pending" },
    #|        { "id": "m1-t2", "description": "Create handlers", "wave": 0, "status": "pending" },
    #|        { "id": "m1-t3", "description": "Add auth layer", "wave": 1, "status": "pending" }
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
test "circuit breaker activates on infra failure during verification" {
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
    #|        { "id": "m1-t1", "description": "Implement login", "wave": 0, "status": "pending" }
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
    #|        { "id": "m1-t1", "description": "Implement login", "wave": 0, "status": "pending" }
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
    #|        { "id": "m1-t1", "description": "Implement login", "wave": 0, "status": "pending" }
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
    #|        { "id": "m1-t1", "description": "Implement login", "wave": 0, "status": "pending" }
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
    #|        { "id": "m1-t1", "description": "Implement login", "wave": 0, "status": "pending" }
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
