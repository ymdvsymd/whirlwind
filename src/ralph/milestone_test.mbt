///|
test "MilestoneManager::new creates empty manager" {
  let mgr = @ralph.MilestoneManager::new()
  assert_true(mgr.milestones.is_empty())
  assert_true(mgr.all_milestones_done())
}

///|
test "MilestoneManager::load_from_json parses brief when present and defaults when absent" {
  let with_brief =
    #|{
    #|  "brief": "Ship auth with rate limits",
    #|  "milestones": []
    #|}
  let without_brief =
    #|{
    #|  "milestones": []
    #|}
  let mgr1 = @ralph.MilestoneManager::load_from_json(with_brief)
  let mgr2 = @ralph.MilestoneManager::load_from_json(without_brief)
  inspect(mgr1.brief, content="Ship auth with rate limits")
  inspect(mgr2.brief, content="")
}

///|
test "MilestoneManager::load_from_json roundtrip" {
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1",
    #|      "goal": "Build auth",
    #|      "status": "pending",
    #|      "tasks": [
    #|        { "id": "m1-t1", "description": "Create schema", "status": "pending" },
    #|        { "id": "m1-t2", "description": "Build handlers", "status": "pending" }
    #|      ]
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  assert_true(mgr.milestones.length() == 1)
  inspect(mgr.milestones[0].id, content="m1")
  inspect(mgr.milestones[0].goal, content="Build auth")
  assert_true(mgr.milestones[0].tasks.length() == 2)
  // Roundtrip
  let serialized = mgr.to_json()
  let mgr2 = @ralph.MilestoneManager::load_from_json(serialized)
  assert_true(mgr2.milestones.length() == 1)
  inspect(mgr2.milestones[0].id, content="m1")
  assert_true(mgr2.milestones[0].tasks.length() == 2)
}

///|
test "JSON roundtrip preserves scope" {
  let mgr = @ralph.MilestoneManager::new()
  mgr.milestones.push({
    id: "m1",
    goal: "Preserve scoped tasks",
    status: @types.MilestoneStatus::Pending,
    tasks: [
      {
        id: "m1-t1",
        description: "Update planner",
        scope: ["src/ralph/planner.mbt", "src/ralph/milestone.mbt"],
        depends_on: [],
        status: @types.TaskStatus::Pending,
        result: None,
      },
      {
        id: "m1-t2",
        description: "Update tests",
        scope: ["src/ralph/milestone_test.mbt"],
        depends_on: [],
        status: @types.TaskStatus::Done,
        result: Some("updated"),
      },
      {
        id: "m1-t3",
        description: "No declared scope",
        scope: [],
        depends_on: [],
        status: @types.TaskStatus::Pending,
        result: None,
      },
    ],
    summary: "",
    perspectives: [],
  })

  let serialized = mgr.to_json()
  assert_true(
    serialized.contains(
      "\"scope\":[\"src/ralph/planner.mbt\",\"src/ralph/milestone.mbt\"]",
    ),
  )
  assert_true(
    serialized.contains("\"scope\":[\"src/ralph/milestone_test.mbt\"]"),
  )
  assert_false(serialized.contains("\"scope\":[]"))

  let reloaded = @ralph.MilestoneManager::load_from_json(serialized)
  let tasks = reloaded.milestones[0].tasks
  assert_true(tasks.length() == 3)
  assert_true(tasks[0].scope.length() == 2)
  inspect(tasks[0].scope[0], content="src/ralph/planner.mbt")
  inspect(tasks[0].scope[1], content="src/ralph/milestone.mbt")
  assert_true(tasks[1].scope.length() == 1)
  inspect(tasks[1].scope[0], content="src/ralph/milestone_test.mbt")
  assert_true(tasks[2].scope.length() == 0)
}

///|
test "JSON roundtrip preserves depends_on" {
  let mgr = @ralph.MilestoneManager::new()
  mgr.milestones.push({
    id: "m1",
    goal: "Preserve depends_on",
    status: @types.MilestoneStatus::Pending,
    tasks: [
      {
        id: "m1-t1",
        description: "Independent task",
        scope: [],
        depends_on: [],
        status: @types.TaskStatus::Pending,
        result: None,
      },
      {
        id: "m1-t2",
        description: "Depends on t1",
        scope: [],
        depends_on: ["m1-t1"],
        status: @types.TaskStatus::Pending,
        result: None,
      },
      {
        id: "m1-t3",
        description: "Depends on t1 and t2",
        scope: ["src/api.mbt"],
        depends_on: ["m1-t1", "m1-t2"],
        status: @types.TaskStatus::Pending,
        result: None,
      },
    ],
    summary: "",
    perspectives: [],
  })

  let serialized = mgr.to_json()
  // depends_on should be serialized only when non-empty
  assert_true(serialized.contains("\"depends_on\":[\"m1-t1\"]"))
  assert_true(serialized.contains("\"depends_on\":[\"m1-t1\",\"m1-t2\"]"))
  // Empty depends_on should NOT appear in JSON (same pattern as scope)
  assert_false(serialized.contains("\"depends_on\":[]"))

  let reloaded = @ralph.MilestoneManager::load_from_json(serialized)
  let tasks = reloaded.milestones[0].tasks
  assert_true(tasks.length() == 3)
  // Task 1: no dependencies
  assert_true(tasks[0].depends_on.length() == 0)
  // Task 2: depends on t1
  assert_true(tasks[1].depends_on.length() == 1)
  inspect(tasks[1].depends_on[0], content="m1-t1")
  // Task 3: depends on t1 and t2
  assert_true(tasks[2].depends_on.length() == 2)
  inspect(tasks[2].depends_on[0], content="m1-t1")
  inspect(tasks[2].depends_on[1], content="m1-t2")
}

///|
test "MilestoneManager::load_from_json converts in-progress tasks back to pending" {
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1",
    #|      "goal": "Build auth",
    #|      "status": "in_progress",
    #|      "tasks": [
    #|        { "id": "m1-t1", "description": "Create schema", "status": "done" },
    #|        { "id": "m1-t2", "description": "Build handlers", "status": "in_progress" }
    #|      ]
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  inspect(mgr.milestones[0].status, content="InProgress")
  inspect(mgr.milestones[0].tasks[1].status, content="Pending")
}

///|
test "MilestoneManager::to_json includes brief" {
  let json =
    #|{
    #|  "brief": "Keep the API backwards compatible",
    #|  "milestones": []
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let serialized = mgr.to_json()
  assert_true(
    serialized.contains("\"brief\":\"Keep the API backwards compatible\""),
  )
}

///|
test "Milestone summary parsing and serialization" {
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1",
    #|      "goal": "Build auth",
    #|      "status": "done",
    #|      "summary": "Created schema; added handlers",
    #|      "tasks": []
    #|    },
    #|    {
    #|      "id": "m2",
    #|      "goal": "Add tests",
    #|      "status": "pending",
    #|      "tasks": []
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  inspect(mgr.milestones[0].summary, content="Created schema; added handlers")
  inspect(mgr.milestones[1].summary, content="")
  let serialized = mgr.to_json()
  assert_true(
    serialized.contains("\"summary\":\"Created schema; added handlers\""),
  )
  assert_true(serialized.contains("\"summary\":\"\""))
}

///|
test "MilestoneManager::load_from_json defaults perspectives when key is absent" {
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1",
    #|      "goal": "Build auth",
    #|      "status": "pending",
    #|      "tasks": []
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let perspectives = mgr.milestones[0].perspectives
  assert_true(perspectives.length() == 4)
  inspect(perspectives[0], content="CodeQuality")
  inspect(perspectives[1], content="Performance")
  inspect(perspectives[2], content="Security")
  inspect(perspectives[3], content="GoalAlignment")
}

///|
test "MilestoneManager::load_from_json roundtrip preserves perspectives" {
  let mgr = @ralph.MilestoneManager::new()
  mgr.milestones.push({
    id: "m1",
    goal: "Serialize perspectives",
    status: @types.MilestoneStatus::Pending,
    tasks: [],
    summary: "",
    perspectives: ["CodeQuality", "GoalAlignment"],
  })

  let serialized = mgr.to_json()
  let reloaded = @ralph.MilestoneManager::load_from_json(serialized)
  let perspectives = reloaded.milestones[0].perspectives
  assert_true(perspectives.length() == 2)
  inspect(perspectives[0], content="CodeQuality")
  inspect(perspectives[1], content="GoalAlignment")
}

///|
test "MilestoneManager::load_from_json preserves explicit empty perspectives" {
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1",
    #|      "goal": "Verification only",
    #|      "status": "pending",
    #|      "perspectives": [],
    #|      "tasks": []
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  assert_true(mgr.milestones[0].perspectives.length() == 0)
}

///|
test "parse_perspectives_line returns None when PERSPECTIVES line is absent" {
  let output =
    #|TASKS:
    #|1. Add tests
  let perspectives = @ralph.parse_perspectives_line(output)
  assert_true(perspectives is None)
}

///|
test "parse_perspectives_line returns Some([]) for PERSPECTIVES: (none)" {
  let output =
    #|PERSPECTIVES: (none)
    #|TASKS:
    #|1. Verify behavior
  let parsed = @ralph.parse_perspectives_line(output)
  assert_true(parsed is Some(_))
  let perspectives = parsed.unwrap()
  assert_true(perspectives.length() == 0)
}

///|
test "parse_perspectives_line returns Some([CodeQuality, GoalAlignment])" {
  let output =
    #|Goal: update planner
    #|PERSPECTIVES: CodeQuality, GoalAlignment
    #|TASKS:
    #|1. Update parser
  let parsed = @ralph.parse_perspectives_line(output)
  assert_true(parsed is Some(_))
  let perspectives = parsed.unwrap()
  assert_true(perspectives.length() == 2)
  inspect(perspectives[0], content="CodeQuality")
  inspect(perspectives[1], content="GoalAlignment")
}

///|
test "parse_perspectives_line returns Some(all 4 perspectives)" {
  let output =
    #|Goal: update production code
    #|PERSPECTIVES: CodeQuality, Performance, Security, GoalAlignment
    #|TASKS:
    #|1. Update verifier
  let parsed = @ralph.parse_perspectives_line(output)
  assert_true(parsed is Some(_))
  let perspectives = parsed.unwrap()
  assert_true(perspectives.length() == 4)
  inspect(perspectives[0], content="CodeQuality")
  inspect(perspectives[1], content="Performance")
  inspect(perspectives[2], content="Security")
  inspect(perspectives[3], content="GoalAlignment")
}

///|
test "to_json produces valid JSON parseable by @json.parse" {
  let json =
    #|{
    #|  "brief": "test",
    #|  "milestones": [
    #|    {
    #|      "id": "m1",
    #|      "goal": "Handle special chars: \"quotes\" and \\backslash",
    #|      "status": "done",
    #|      "summary": "Line1\nLine2\ttab",
    #|      "tasks": [
    #|        {
    #|          "id": "m1-t1",
    #|          "description": "Task with\nnewline",
    #|          "status": "done",
    #|          "result": "Result with\ttab",
    #|          "plan_doc": "Plan\nwith\nnewlines"
    #|        }
    #|      ]
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let serialized = mgr.to_json()
  // The serialized output must be valid JSON that @json.parse can handle
  let reparsed = @json.parse(serialized) catch {
    err => fail("to_json output is not valid JSON: \{err}")
  }
  // Verify the data survived the roundtrip
  let mgr2 = @ralph.MilestoneManager::load_from_json(serialized)
  inspect(
    mgr2.milestones[0].goal,
    content="Handle special chars: \"quotes\" and \\backslash",
  )
  inspect(mgr2.milestones[0].summary, content="Line1\nLine2\ttab")
  inspect(mgr2.milestones[0].tasks[0].description, content="Task with\nnewline")
  inspect(
    mgr2.milestones[0].tasks[0].result.unwrap(),
    content="Result with\ttab",
  )
  // Verify reparsed is an Object (well-formed JSON structure)
  guard reparsed is Object(_)
}

///|
test "to_json uses Json API not manual string concatenation" {
  // Verify that the serialized JSON has proper structure by checking
  // it can be parsed and has expected keys
  let mgr = @ralph.MilestoneManager::new()
  mgr.milestones.push({
    id: "m1",
    goal: "test goal",
    status: @types.MilestoneStatus::Pending,
    tasks: [
      {
        id: "m1-t1",
        description: "task desc",
        scope: [],
        depends_on: [],
        status: @types.TaskStatus::Pending,
        result: None,
      },
      {
        id: "m1-t2",
        description: "task with result",
        scope: [],
        depends_on: [],
        status: @types.TaskStatus::Done,
        result: Some("done result"),
      },
    ],
    summary: "",
    perspectives: [],
  })
  let serialized = mgr.to_json()
  // Must be valid JSON
  let parsed = @json.parse(serialized) catch {
    err => fail("to_json output is not valid JSON: \{err}")
  }
  // Verify structure through parsing
  match parsed {
    Object(map) => {
      // Must have "brief" and "milestones" keys
      assert_true(map.contains("brief"))
      assert_true(map.contains("milestones"))
      match map.get("milestones") {
        Some(Array(arr)) => {
          assert_true(arr.length() == 1)
          match arr[0] {
            Object(m_map) => {
              assert_true(m_map.contains("id"))
              assert_true(m_map.contains("goal"))
              assert_true(m_map.contains("status"))
              assert_true(m_map.contains("tasks"))
              assert_true(m_map.contains("summary"))
              // Check null result is properly represented
              match m_map.get("tasks") {
                Some(Array(tasks)) => {
                  assert_true(tasks.length() == 2)
                  match tasks[0] {
                    Object(t_map) =>
                      // result should be null for first task
                      match t_map.get("result") {
                        Some(Null) => ()
                        other => fail("Expected null result, got \{other}")
                      }
                    _ => fail("Expected task object")
                  }
                  match tasks[1] {
                    Object(t_map) =>
                      // result should be a string for second task
                      match t_map.get("result") {
                        Some(String(s)) => inspect(s, content="done result")
                        other => fail("Expected string result, got \{other}")
                      }
                    _ => fail("Expected task object")
                  }
                }
                _ => fail("Expected tasks array")
              }
            }
            _ => fail("Expected milestone object")
          }
        }
        _ => fail("Expected milestones array")
      }
    }
    _ => fail("Expected top-level object")
  }
}

///|
test "next_pending_milestone returns first pending" {
  let json =
    #|{
    #|  "milestones": [
    #|    { "id": "m1", "goal": "A", "status": "done", "tasks": [] },
    #|    { "id": "m2", "goal": "B", "status": "pending", "tasks": [] },
    #|    { "id": "m3", "goal": "C", "status": "pending", "tasks": [] }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let next = mgr.next_pending_milestone()
  assert_true(next is Some(_))
  inspect(next.unwrap().id, content="m2")
}

///|
test "next_pending_milestone returns None when all done" {
  let json =
    #|{
    #|  "milestones": [
    #|    { "id": "m1", "goal": "A", "status": "done", "tasks": [] }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  assert_true(mgr.next_pending_milestone() is None)
}

///|
test "parse_planner_output parses SCOPE lines" {
  let mgr = @ralph.MilestoneManager::new()
  let output =
    #|TASKS:
    #|1. Create database schema
    #|SCOPE: src/a.ts, src/b.ts
    #|2. Write migration scripts
    #|SCOPE: db/migrations/001.sql
    #|3. Build API handlers
    #|SCOPE: src/api.ts, src/auth.ts
    #|4. Add authentication
    #|SCOPE: src/session.ts
  let tasks = mgr.parse_planner_output(output, "m1")
  assert_true(tasks.length() == 4)
  assert_true(tasks[0].scope.length() == 2)
  inspect(tasks[0].scope[0], content="src/a.ts")
  inspect(tasks[0].scope[1], content="src/b.ts")
  assert_true(tasks[1].scope.length() == 1)
  inspect(tasks[1].scope[0], content="db/migrations/001.sql")
  assert_true(tasks[2].scope.length() == 2)
  inspect(tasks[2].scope[0], content="src/api.ts")
  inspect(tasks[2].scope[1], content="src/auth.ts")
  assert_true(tasks[3].scope.length() == 1)
  inspect(tasks[3].scope[0], content="src/session.ts")
}

///|
test "parse_planner_output without SCOPE lines defaults to empty scope" {
  let mgr = @ralph.MilestoneManager::new()
  let output =
    #|TASKS:
    #|1. Create database schema
    #|2. Write migration scripts
    #|3. Build API handlers
    #|4. Add authentication
  let tasks = mgr.parse_planner_output(output, "m1")
  assert_true(tasks.length() == 4)
  assert_true(tasks[0].scope.length() == 0)
  assert_true(tasks[1].scope.length() == 0)
  assert_true(tasks[2].scope.length() == 0)
  assert_true(tasks[3].scope.length() == 0)
}

///|
test "parse_planner_output mixed SCOPE and no-SCOPE tasks" {
  let mgr = @ralph.MilestoneManager::new()
  let output =
    #|TASKS:
    #|1. Create database schema
    #|SCOPE: src/schema.mbt, src/migrations.mbt
    #|2. Write migration scripts
    #|3. Build API handlers
    #|SCOPE: src/api.mbt
    #|4. Add authentication
  let tasks = mgr.parse_planner_output(output, "m1")
  assert_true(tasks.length() == 4)
  assert_true(tasks[0].scope.length() == 2)
  inspect(tasks[0].scope[0], content="src/schema.mbt")
  inspect(tasks[0].scope[1], content="src/migrations.mbt")
  assert_true(tasks[1].scope.length() == 0)
  assert_true(tasks[2].scope.length() == 1)
  inspect(tasks[2].scope[0], content="src/api.mbt")
  assert_true(tasks[3].scope.length() == 0)
}

///|
test "parse_planner_output with dash items" {
  let mgr = @ralph.MilestoneManager::new()
  let output =
    #|TASKS:
    #|- Set up project structure
    #|- Install dependencies
  let tasks = mgr.parse_planner_output(output, "m1")
  assert_true(tasks.length() == 2)
  inspect(tasks[0].description, content="Set up project structure")
}

///|
test "parse_planner_output stops at --- separator after tasks" {
  let mgr = @ralph.MilestoneManager::new()
  let output =
    #|TASKS:
    #|1. Create database schema
    #|
    #|---
    #|
    #|- Some notes
  let tasks = mgr.parse_planner_output(output, "m1")
  assert_true(tasks.length() == 1)
  inspect(tasks[0].description, content="Create database schema")
}

///|
test "parse_planner_output ignores --- before tasks" {
  let mgr = @ralph.MilestoneManager::new()
  let output =
    #|Some intro text
    #|
    #|---
    #|
    #|TASKS:
    #|1. Create database schema
    #|2. Build API handlers
    #|
    #|---
    #|
    #|- Note
  let tasks = mgr.parse_planner_output(output, "m1")
  assert_true(tasks.length() == 2)
}

///|
test "parse_planner_output ignores context bullets before first TASKS header" {
  let mgr = @ralph.MilestoneManager::new()
  let output =
    #|**Key context from exploration:**
    #|- libs/example.py already exists
    #|- config/app.yml is missing
    #|---
    #|TASKS:
    #|1. Create config/app.yml
    #|2. Wire the loader
  let tasks = mgr.parse_planner_output(output, "m1")
  assert_true(tasks.length() == 2)

  inspect(tasks[0].description, content="Create config/app.yml")
  inspect(tasks[1].description, content="Wire the loader")
}

///|
test "parse_planner_output parses TASKS/DEPENDS_ON format" {
  let mgr = @ralph.MilestoneManager::new()
  let output =
    #|TASKS:
    #|1. Create database schema
    #|SCOPE: src/schema.mbt
    #|DEPENDS_ON: (none)
    #|
    #|2. Write migration scripts
    #|SCOPE: db/migrations/001.sql
    #|DEPENDS_ON: 1
    #|
    #|3. Build API handlers
    #|SCOPE: src/api.mbt
    #|DEPENDS_ON: 1
    #|
    #|4. Add authentication
    #|SCOPE: src/auth.mbt
    #|DEPENDS_ON: 2, 3
  let tasks = mgr.parse_planner_output(output, "m1")
  assert_true(tasks.length() == 4)
  // Task 1: no deps
  inspect(tasks[0].id, content="m1-t1")
  inspect(tasks[0].description, content="Create database schema")
  assert_true(tasks[0].scope.length() == 1)
  inspect(tasks[0].scope[0], content="src/schema.mbt")
  assert_true(tasks[0].depends_on.is_empty())
  // Task 2: depends on task 1
  inspect(tasks[1].id, content="m1-t2")
  inspect(tasks[1].description, content="Write migration scripts")
  assert_true(tasks[1].depends_on.length() == 1)
  inspect(tasks[1].depends_on[0], content="m1-t1")
  // Task 3: depends on task 1
  inspect(tasks[2].id, content="m1-t3")
  assert_true(tasks[2].depends_on.length() == 1)
  inspect(tasks[2].depends_on[0], content="m1-t1")
  // Task 4: depends on tasks 2 and 3
  inspect(tasks[3].id, content="m1-t4")
  assert_true(tasks[3].depends_on.length() == 2)
  inspect(tasks[3].depends_on[0], content="m1-t2")
  inspect(tasks[3].depends_on[1], content="m1-t3")
}

///|
test "parse_planner_output DEPENDS_ON none produces empty depends_on" {
  let mgr = @ralph.MilestoneManager::new()
  let output =
    #|TASKS:
    #|1. Independent task A
    #|DEPENDS_ON: (none)
    #|
    #|2. Independent task B
    #|DEPENDS_ON: (none)
  let tasks = mgr.parse_planner_output(output, "m1")
  assert_true(tasks.length() == 2)
  assert_true(tasks[0].depends_on.is_empty())
  assert_true(tasks[1].depends_on.is_empty())
}

///|
test "parse_planner_output SCOPE and DEPENDS_ON in either order" {
  let mgr = @ralph.MilestoneManager::new()
  // Test DEPENDS_ON before SCOPE
  let output =
    #|TASKS:
    #|1. First task
    #|SCOPE: src/a.mbt
    #|DEPENDS_ON: (none)
    #|
    #|2. Second task with DEPENDS_ON before SCOPE
    #|DEPENDS_ON: 1
    #|SCOPE: src/b.mbt
  let tasks = mgr.parse_planner_output(output, "m1")
  assert_true(tasks.length() == 2)
  // Task 1: SCOPE then DEPENDS_ON
  assert_true(tasks[0].scope.length() == 1)
  inspect(tasks[0].scope[0], content="src/a.mbt")
  assert_true(tasks[0].depends_on.is_empty())
  // Task 2: DEPENDS_ON then SCOPE (reversed order)
  assert_true(tasks[1].depends_on.length() == 1)
  inspect(tasks[1].depends_on[0], content="m1-t1")
  assert_true(tasks[1].scope.length() == 1)
  inspect(tasks[1].scope[0], content="src/b.mbt")
}

///|
test "parse_planner_output DEPENDS_ON with multiple refs" {
  let mgr = @ralph.MilestoneManager::new()
  let output =
    #|TASKS:
    #|1. Task A
    #|2. Task B
    #|3. Task C
    #|DEPENDS_ON: 1, 3
  let tasks = mgr.parse_planner_output(output, "m1")
  assert_true(tasks.length() == 3)
  // Task C depends on tasks 1 and 3
  assert_true(tasks[2].depends_on.length() == 2)
  inspect(tasks[2].depends_on[0], content="m1-t1")
  inspect(tasks[2].depends_on[1], content="m1-t3")
}

///|
test "parse_planner_output TASKS format without DEPENDS_ON lines" {
  let mgr = @ralph.MilestoneManager::new()
  let output =
    #|TASKS:
    #|1. Task A
    #|SCOPE: src/a.mbt
    #|2. Task B
  let tasks = mgr.parse_planner_output(output, "m1")
  assert_true(tasks.length() == 2)
  inspect(tasks[0].description, content="Task A")
  assert_true(tasks[0].scope.length() == 1)
  assert_true(tasks[0].depends_on.is_empty())
  inspect(tasks[1].description, content="Task B")
  assert_true(tasks[1].depends_on.is_empty())
}

///|
test "gen_task_id generates unique ids" {
  let mgr = @ralph.MilestoneManager::new()
  let id1 = mgr.gen_task_id("m1")
  let id2 = mgr.gen_task_id("m1")
  assert_true(id1 != id2)
  inspect(id1, content="m1-t1")
  inspect(id2, content="m1-t2")
}

///|
test "all_milestones_done with mixed statuses" {
  let json =
    #|{
    #|  "milestones": [
    #|    { "id": "m1", "goal": "A", "status": "done", "tasks": [] },
    #|    { "id": "m2", "goal": "B", "status": "pending", "tasks": [] }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  assert_true(not(mgr.all_milestones_done()))
}

///|
test "load_from_json sets next_task_id correctly" {
  let json =
    #|{
    #|  "milestones": [
    #|    {
    #|      "id": "m1", "goal": "A", "status": "pending",
    #|      "tasks": [
    #|        { "id": "m1-t5", "description": "a", "status": "pending" }
    #|      ]
    #|    }
    #|  ]
    #|}
  let mgr = @ralph.MilestoneManager::load_from_json(json)
  let new_id = mgr.gen_task_id("m1")
  inspect(new_id, content="m1-t6")
}
