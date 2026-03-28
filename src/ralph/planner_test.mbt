///|
test "PlannerAgent::build_plan_prompt includes milestone info and DAG format" {
  let planner = @ralph.PlannerAgent::new()
  let milestone : @types.Milestone = {
    id: "m1",
    goal: "Build authentication system",
    status: @types.MilestoneStatus::Pending,
    tasks: [],
    summary: "",
    perspectives: [],
  }
  let prompt = planner.build_plan_prompt(milestone)
  assert_true(prompt.contains("m1"))
  assert_true(prompt.contains("Build authentication system"))
  assert_true(prompt.contains("PERSPECTIVES:"))
  assert_true(
    prompt.contains("CodeQuality, Performance, Security, GoalAlignment"),
  )
  assert_true(prompt.contains("(none)"))
  // DAG format: TASKS header and DEPENDS_ON instructions
  assert_true(prompt.contains("TASKS:"))
  assert_true(prompt.contains("DEPENDS_ON:"))
  assert_true(prompt.contains("dependencies"))
  // Should NOT contain old WAVE format
  assert_false(prompt.contains("WAVE"))
}

///|
test "PlannerAgent::build_plan_prompt lang=ja" {
  let planner = @ralph.PlannerAgent::new(lang="ja")
  let milestone : @types.Milestone = {
    id: "m1",
    goal: "Build auth",
    status: @types.MilestoneStatus::Pending,
    tasks: [],
    summary: "",
    perspectives: [],
  }
  let prompt = planner.build_plan_prompt(milestone)
  assert_true(prompt.contains("Japanese"))
}

///|
test "PlannerAgent::parse_plan delegates to MilestoneManager" {
  let planner = @ralph.PlannerAgent::new()
  let mgr = @ralph.MilestoneManager::new()
  let output =
    #|TASKS:
    #|1. Set up database
    #|2. Create API routes
  let tasks = planner.parse_plan(output, "m1", mgr)
  assert_true(tasks.length() == 2)
}

///|
test "whirlwind-bqm: planner prompt warns against duplicate work across milestones" {
  let planner = @ralph.PlannerAgent::new()
  let milestone : @types.Milestone = {
    id: "m1",
    goal: "Add new struct fields\n\nAdd created_at and updated_at to the Foo struct.\nNote: Step 9 will update all existing literals to include these fields.",
    status: @types.MilestoneStatus::Pending,
    tasks: [],
    summary: "",
    perspectives: [],
  }
  let prompt = planner.build_plan_prompt(milestone)
  // The prompt must contain a scope boundary instruction telling the planner
  // to only create tasks for this milestone's own deliverables, not for work
  // that belongs to other milestones/steps referenced in the goal text.
  assert_true(prompt.contains("Scope Boundary"))
  assert_true(
    prompt.contains("other milestone") || prompt.contains("other step"),
  )
}

///|
test "PlannerAgent::plan with mock backend" {
  let planner = @ralph.PlannerAgent::new()
  let mgr = @ralph.MilestoneManager::new()
  let mock = @agent.MockBackend::new(
    default_response="TASKS:\n1. Create schema\n2. Write migrations\n3. Build handlers",
  )
  let backend = mock.boxed()
  let milestone : @types.Milestone = {
    id: "m1",
    goal: "Build auth",
    status: @types.MilestoneStatus::Pending,
    tasks: [],
    summary: "",
    perspectives: [],
  }
  let result = planner.plan(milestone, backend, "", [], mgr)
  assert_true(result.tasks.length() == 3)
  inspect(result.tasks[0].description, content="Create schema")
}
