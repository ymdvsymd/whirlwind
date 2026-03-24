///|
test "Task::new creates pending task" {
  let t = @types.Task::new("t1", "do something")
  inspect(t.status, content="Pending")
  inspect(t.result, content="None")
  inspect(t.parent_id, content="None")
}

///|
test "Task::assign sets InProgress" {
  let t = @types.Task::new("t1", "do something")
  t.assign("agent-1")
  inspect(t.status, content="InProgress(\"agent-1\")")
  assert_true(not(t.is_pending()))
  assert_true(not(t.is_done()))
}

///|
test "Task::complete sets Done" {
  let t = @types.Task::new("t1", "do something")
  t.assign("agent-1")
  t.complete("result here")
  inspect(t.status, content="Done")
  inspect(t.result, content="Some(\"result here\")")
  assert_true(t.is_done())
}

///|
test "Task::fail sets Failed" {
  let t = @types.Task::new("t1", "do something")
  t.fail("error occurred")
  inspect(t.status, content="Failed(\"error occurred\")")
}

///|
test "Session::new creates active session" {
  let s = @types.Session::new("s1", "build api", [])
  inspect(s.status, content="Active")
  inspect(s.current_phase, content="Decomposing")
  assert_true(s.tasks.is_empty())
}

///|
test "OrchestratorCallbacks::noop does not panic" {
  let cb = @types.OrchestratorCallbacks::noop()
  cb.emit(AgentOutput({ agent_id: "a1", line: "hello" }))
  cb.emit(AgentComplete({ agent_id: "a1", result: "done" }))
  cb.emit(TaskStart({ task_id: "t1", description: "do work", agent_id: "a1" }))
  cb.emit(TaskComplete({ task_id: "t1", status: "done" }))
  cb.emit(TaskAssign({ task_id: "t1", agent_id: "a1" }))
  cb.emit(ReviewStart({ task_id: "t1", reviewer_id: "r1" }))
  cb.emit(
    ReviewComplete({ task_id: "t1", verdict: @types.ReviewVerdict::Approved }),
  )
  cb.emit(
    PhaseChange({ session_id: "s1", phase: @types.OrchestratorPhase::Executing }),
  )
  cb.emit(SessionComplete({ session_id: "s1" }))
  cb.emit(Info({ message: "hello" }))
  (cb.on_save)()
}

///|
test "OrchestratorCallbacks unified event listener carries correct values" {
  let outputs : Array[String] = []
  let callbacks : @types.OrchestratorCallbacks = {
    on_event: fn(e) {
      match e {
        AgentOutput(ev) => outputs.push(ev.agent_id + ":" + ev.line)
        Info(ev) => outputs.push("info:" + ev.message)
        _ => ()
      }
    },
    on_save: fn() {  },
  }
  callbacks.emit(AgentOutput({ agent_id: "dev-1", line: "building..." }))
  callbacks.emit(Info({ message: "started" }))
  inspect(outputs[0], content="dev-1:building...")
  inspect(outputs[1], content="info:started")
}

///|
test "AgentKind show" {
  inspect(@types.AgentKind::ClaudeCode, content="ClaudeCode")
  inspect(@types.AgentKind::Codex, content="Codex")
  inspect(@types.AgentKind::Mock, content="Mock")
}

///|
test "AgentRole show" {
  inspect(@types.AgentRole::Builder, content="Builder")
  inspect(@types.AgentRole::Review, content="Review")
}

///|
test "ReviewVerdict show" {
  inspect(@types.ReviewVerdict::Approved, content="Approved")
  inspect(
    @types.ReviewVerdict::NeedsChanges(["fix typo"]),
    content="NeedsChanges([\"fix typo\"])",
  )
  inspect(
    @types.ReviewVerdict::Rejected("bad code"),
    content="Rejected(\"bad code\")",
  )
}

///|
test "Task with parent_id" {
  let t = @types.Task::new("t2", "sub-task", parent_id=Some("t1"))
  inspect(t.parent_id, content="Some(\"t1\")")
}

///|
test "AgentRole show - planner and verifier" {
  inspect(@types.AgentRole::Planner, content="Planner")
  inspect(@types.AgentRole::Verifier, content="Verifier")
}

///|
test "MilestoneStatus show" {
  inspect(@types.MilestoneStatus::Pending, content="Pending")
  inspect(@types.MilestoneStatus::InProgress, content="InProgress")
  inspect(@types.MilestoneStatus::Done, content="Done")
  inspect(
    @types.MilestoneStatus::Failed("timeout"),
    content="Failed(\"timeout\")",
  )
}

///|
test "Milestone creation and mutation" {
  let m : @types.Milestone = {
    id: "m1",
    goal: "implement feature X",
    status: @types.MilestoneStatus::Pending,
    tasks: [],
    summary: "",
  }
  inspect(m.status, content="Pending")
  m.status = @types.MilestoneStatus::InProgress
  inspect(m.status, content="InProgress")
}

///|
test "RalphTask creation and status update" {
  let t : @types.RalphTask = {
    id: "m1-t1",
    description: "write tests",
    scope: [],
    wave: 0,
    status: @types.TaskStatus::Pending,
    result: None,
  }
  inspect(t.status, content="Pending")
  inspect(t.wave, content="0")
  t.status = @types.TaskStatus::Done
  t.result = Some("all tests pass")
  inspect(t.status, content="Done")
  inspect(t.result, content="Some(\"all tests pass\")")
}

///|
test "RalphPhase show" {
  inspect(@types.RalphPhase::LoadingMilestones, content="LoadingMilestones")
  inspect(@types.RalphPhase::Planning("m1"), content="Planning(\"m1\")")
  inspect(
    @types.RalphPhase::ExecutingWave("m1", 0),
    content="ExecutingWave(\"m1\", 0)",
  )
  inspect(@types.RalphPhase::Verifying("m1", 1), content="Verifying(\"m1\", 1)")
  inspect(@types.RalphPhase::Reworking("m1", 0), content="Reworking(\"m1\", 0)")
  inspect(
    @types.RalphPhase::MilestoneComplete("m1"),
    content="MilestoneComplete(\"m1\")",
  )
  inspect(@types.RalphPhase::AllComplete, content="AllComplete")
}

///|
test "AgentResult::failed creates failure result" {
  let r = @types.AgentResult::failed("something went wrong")
  inspect(r.content, content="")
  inspect(r.status, content="Failed(\"something went wrong\")")
  inspect(r.error, content="Some(\"something went wrong\")")
  inspect(r.session_id, content="")
}

///|
test "AgentResult::failed_with_session creates failure with session" {
  let r = @types.AgentResult::failed_with_session("err", "sess-123")
  inspect(r.content, content="")
  inspect(r.status, content="Failed(\"err\")")
  inspect(r.error, content="Some(\"err\")")
  inspect(r.session_id, content="sess-123")
}

///|
test "VerifierVerdict show" {
  inspect(@types.VerifierVerdict::Approved, content="Approved")
  inspect(
    @types.VerifierVerdict::NeedsRework(["t1: fix error handling"]),
    content="NeedsRework([\"t1: fix error handling\"])",
  )
  inspect(
    @types.VerifierVerdict::MilestoneFailed("critical failure"),
    content="MilestoneFailed(\"critical failure\")",
  )
}

///|
test "Milestone::get_wave_tasks filters by wave number" {
  let m : @types.Milestone = {
    id: "m1",
    goal: "build feature",
    status: @types.MilestoneStatus::Pending,
    tasks: [
      {
        id: "m1-t1",
        description: "a",
        scope: [],
        wave: 0,
        status: @types.TaskStatus::Pending,
        result: None,
      },
      {
        id: "m1-t2",
        description: "b",
        scope: [],
        wave: 0,
        status: @types.TaskStatus::Pending,
        result: None,
      },
      {
        id: "m1-t3",
        description: "c",
        scope: [],
        wave: 1,
        status: @types.TaskStatus::Pending,
        result: None,
      },
    ],
    summary: "",
  }
  let wave0 = m.get_wave_tasks(0)
  assert_true(wave0.length() == 2)
  let wave1 = m.get_wave_tasks(1)
  assert_true(wave1.length() == 1)
  inspect(wave1[0].id, content="m1-t3")
}

///|
test "Milestone::has_undone_tasks detects pending tasks" {
  let m : @types.Milestone = {
    id: "m1",
    goal: "build feature",
    status: @types.MilestoneStatus::Pending,
    tasks: [
      {
        id: "m1-t1",
        description: "a",
        scope: [],
        wave: 0,
        status: @types.TaskStatus::Done,
        result: None,
      },
      {
        id: "m1-t2",
        description: "b",
        scope: [],
        wave: 0,
        status: @types.TaskStatus::Pending,
        result: None,
      },
    ],
    summary: "",
  }
  assert_true(m.has_undone_tasks())
}

///|
test "Milestone::has_undone_tasks returns false when all done" {
  let m : @types.Milestone = {
    id: "m1",
    goal: "build feature",
    status: @types.MilestoneStatus::Pending,
    tasks: [
      {
        id: "m1-t1",
        description: "a",
        scope: [],
        wave: 0,
        status: @types.TaskStatus::Done,
        result: None,
      },
    ],
    summary: "",
  }
  assert_true(not(m.has_undone_tasks()))
}

///|
test "Milestone::next_wave_number finds lowest pending wave" {
  let m : @types.Milestone = {
    id: "m1",
    goal: "build feature",
    status: @types.MilestoneStatus::Pending,
    tasks: [
      {
        id: "m1-t1",
        description: "a",
        scope: [],
        wave: 0,
        status: @types.TaskStatus::Done,
        result: None,
      },
      {
        id: "m1-t2",
        description: "b",
        scope: [],
        wave: 1,
        status: @types.TaskStatus::Pending,
        result: None,
      },
      {
        id: "m1-t3",
        description: "c",
        scope: [],
        wave: 2,
        status: @types.TaskStatus::Pending,
        result: None,
      },
    ],
    summary: "",
  }
  inspect(m.next_wave_number(), content="Some(1)")
}
