///|
test "run_dag skips already-done tasks before submitting to builder" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1", "goal": "Resume auth", "status": "pending",
    #|      "tasks": [
    #|        { "id": "m1-t1", "description": "Create schema", "status": "done", "result": "already finished" },
    #|        { "id": "m1-t2", "description": "Write tests", "status": "done", "result": "already finished" },
    #|        { "id": "m1-t3", "description": "Write handlers", "status": "pending" }
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
test "run_dag does not emit running logs for already-done tasks" {
  let config = make_ralph_config()
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1", "goal": "Resume auth", "status": "pending",
    #|      "tasks": [
    #|        { "id": "m1-t1", "description": "Create schema", "status": "done", "result": "already finished" },
    #|        { "id": "m1-t2", "description": "Write handlers", "status": "pending" }
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
    #|          "scope": ["src/shared.ts", "src/types.ts"],
    #|          "status": "pending"
    #|        },
    #|        {
    #|          "id": "m1-t2",
    #|          "description": "Update shared helpers",
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
    #|          "scope": ["shared.ts"],
    #|          "depends_on": ["m1-t2"],
    #|          "status": "pending"
    #|        },
    #|        {
    #|          "id": "m1-t2",
    #|          "description": "Task B independent",
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
    #|          "scope": ["f1.ts"],
    #|          "depends_on": ["m1-t3"],
    #|          "status": "pending"
    #|        },
    #|        {
    #|          "id": "m1-t2",
    #|          "description": "Task B",
    #|          "scope": ["f1.ts", "f2.ts"],
    #|          "depends_on": ["m1-t1"],
    #|          "status": "pending"
    #|        },
    #|        {
    #|          "id": "m1-t3",
    #|          "description": "Task C",
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
test "run_dag with no scope overlaps executes all tasks normally" {
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
    #|          "scope": ["src/a.ts"],
    #|          "status": "pending"
    #|        },
    #|        {
    #|          "id": "m1-t2",
    #|          "description": "Update file B",
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
    not(infos.iter().any(fn(msg) { msg.contains("Pre-layer scope check") })),
  )
}

///|
test "run_dag with empty scope arrays skips conflict check" {
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
    #|          "scope": [],
    #|          "status": "pending"
    #|        },
    #|        {
    #|          "id": "m1-t2",
    #|          "description": "Run legacy task B",
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
    not(infos.iter().any(fn(msg) { msg.contains("Pre-layer scope check") })),
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
