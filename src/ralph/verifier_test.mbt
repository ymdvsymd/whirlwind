///|
test "VerifierAgent::parse_verdict approved" {
  let v = @ralph.VerifierAgent::new()
  let verdict = v.parse_verdict("All looks good. <wave_approved>")
  inspect(verdict, content="Approved")
}

///|
test "VerifierAgent::parse_verdict needs_rework" {
  let v = @ralph.VerifierAgent::new()
  let verdict = v.parse_verdict(
    "Some issues found.\n<needs_rework>m1-t1: fix error handling\nm1-t2: add tests</needs_rework>",
  )
  match verdict {
    NeedsRework(items) => {
      assert_true(items.length() == 2)
      assert_true(items[0].contains("m1-t1"))
      assert_true(items[1].contains("m1-t2"))
    }
    _ => panic()
  }
}

///|
test "VerifierAgent::parse_verdict milestone_failed" {
  let v = @ralph.VerifierAgent::new()
  let verdict = v.parse_verdict(
    "<milestone_failed>Critical dependency missing</milestone_failed>",
  )
  match verdict {
    MilestoneFailed(reason) => assert_true(reason.contains("Critical"))
    _ => panic()
  }
}

///|
test "VerifierAgent::parse_verdict rejects unrecognized output" {
  let v = @ralph.VerifierAgent::new()
  let verdict = v.parse_verdict("Everything looks fine")
  match verdict {
    MilestoneFailed(reason) =>
      assert_true(reason.contains("expected verdict tags"))
    _ => panic()
  }
}

///|
test "VerifierAgent::parse_verdict rejects empty output" {
  let v = @ralph.VerifierAgent::new()
  let verdict = v.parse_verdict("")
  match verdict {
    MilestoneFailed(_) => ()
    _ => panic()
  }
}

///|
test "VerifierAgent::build_perspective_prompt includes code quality checklist" {
  let v = @ralph.VerifierAgent::new()
  let milestone : @types.Milestone = {
    id: "m1",
    goal: "Build auth",
    status: @types.MilestoneStatus::InProgress,
    tasks: [],
    current_wave: 0,
    summary: "",
  }
  let prompt = v.build_perspective_prompt(CodeQuality, milestone, 0, [], "")
  assert_true(
    prompt.contains("Code Quality") || prompt.contains("コード品質"),
  )
  assert_true(prompt.contains("<wave_approved>"))
}

///|
test "VerifierAgent::build_perspective_prompt includes performance checklist" {
  let v = @ralph.VerifierAgent::new()
  let milestone : @types.Milestone = {
    id: "m1",
    goal: "Build auth",
    status: @types.MilestoneStatus::InProgress,
    tasks: [],
    current_wave: 0,
    summary: "",
  }
  let prompt = v.build_perspective_prompt(Performance, milestone, 0, [], "")
  assert_true(
    prompt.contains("Performance") || prompt.contains("パフォーマンス"),
  )
  assert_true(prompt.contains("<wave_approved>"))
}

///|
test "VerifierAgent::build_perspective_prompt includes security checklist" {
  let v = @ralph.VerifierAgent::new()
  let milestone : @types.Milestone = {
    id: "m1",
    goal: "Build auth",
    status: @types.MilestoneStatus::InProgress,
    tasks: [],
    current_wave: 0,
    summary: "",
  }
  let prompt = v.build_perspective_prompt(Security, milestone, 0, [], "")
  assert_true(
    prompt.contains("Security") || prompt.contains("セキュリティ"),
  )
  assert_true(prompt.contains("<wave_approved>"))
}

///|
test "VerifierAgent::build_perspective_prompt goal alignment includes milestone goal" {
  let v = @ralph.VerifierAgent::new()
  let milestone : @types.Milestone = {
    id: "m1",
    goal: "Ship milestone goal text",
    status: @types.MilestoneStatus::InProgress,
    tasks: [],
    current_wave: 0,
    summary: "",
  }
  let prompt = v.build_perspective_prompt(GoalAlignment, milestone, 0, [], "")
  assert_true(prompt.contains("Ship milestone goal text"))
  assert_true(prompt.contains("<wave_approved>"))
}

///|
test "VerifierAgent::build_perspective_prompt includes goal alignment instructions" {
  let v = @ralph.VerifierAgent::new()
  let milestone : @types.Milestone = {
    id: "m1",
    goal: "Build auth",
    status: @types.MilestoneStatus::InProgress,
    tasks: [],
    current_wave: 0,
    summary: "",
  }
  let prompt = v.build_perspective_prompt(GoalAlignment, milestone, 0, [], "")
  assert_true(prompt.contains("## Instructions"))
  assert_true(prompt.contains("Verify ALL tasks across all waves"))
  assert_false(prompt.contains("Verify ONLY the tasks"))
  assert_false(prompt.contains("other waves"))
}

///|
test "VerifierAgent::merge_verdicts returns approved when all perspectives approve" {
  let v = @ralph.VerifierAgent::new()
  let verdict = v.merge_verdicts([
    (CodeQuality, Approved),
    (Performance, Approved),
    (Security, Approved),
    (GoalAlignment, Approved),
  ])
  inspect(verdict, content="Approved")
}

///|
test "VerifierAgent::merge_verdicts tags single rework item with perspective" {
  let v = @ralph.VerifierAgent::new()
  let verdict = v.merge_verdicts([
    (CodeQuality, Approved),
    (Performance, Approved),
    (Security, NeedsRework(["m1-t1: fix"])),
    (GoalAlignment, Approved),
  ])
  match verdict {
    NeedsRework(items) => {
      assert_true(items.length() == 1)
      inspect(items[0], content="m1-t1: [Security] fix")
    }
    _ => panic()
  }
}

///|
test "VerifierAgent::merge_verdicts returns milestone failed immediately" {
  let v = @ralph.VerifierAgent::new()
  let verdict = v.merge_verdicts([
    (CodeQuality, Approved),
    (Security, MilestoneFailed("Critical dependency missing")),
    (Performance, NeedsRework(["m1-t1: optimize"])),
  ])
  match verdict {
    MilestoneFailed(reason) => assert_true(reason.contains("Critical"))
    _ => panic()
  }
}

///|
test "VerifierAgent::merge_verdicts accumulates rework items from multiple perspectives" {
  let v = @ralph.VerifierAgent::new()
  let verdict = v.merge_verdicts([
    (Performance, NeedsRework(["m1-t1: optimize query"])),
    (Security, NeedsRework(["general issue"])),
    (GoalAlignment, Approved),
  ])
  match verdict {
    NeedsRework(items) => {
      assert_true(items.length() == 2)
      inspect(items[0], content="m1-t1: [Performance] optimize query")
      inspect(items[1], content="[Security] general issue")
    }
    _ => panic()
  }
}

///|
test "inject_perspective_tag inserts perspective after task id" {
  let tagged = @ralph.inject_perspective_tag("m1-t1: fix validation", Security)
  inspect(tagged, content="m1-t1: [Security] fix validation")
}

///|
test "inject_perspective_tag prefixes non task item" {
  let tagged = @ralph.inject_perspective_tag("general issue", Performance)
  inspect(tagged, content="[Performance] general issue")
}

///|
test "VerifierAgent::verify with mock backend approved calls all four perspectives" {
  let v = @ralph.VerifierAgent::new()
  let mock = @agent.MockBackend::new(default_response="<wave_approved>")
  let backend = mock.boxed()
  let milestone : @types.Milestone = {
    id: "m1",
    goal: "Build auth",
    status: @types.MilestoneStatus::InProgress,
    tasks: [],
    current_wave: 0,
    summary: "",
  }
  let verdict = v.verify(milestone, 0, [], backend, "")
  let history = mock.get_history()
  assert_true(history.length() == 4)
  inspect(verdict, content="Approved")
}

///|
test "VerifierAgent::verify with explicit perspectives skips goal alignment" {
  let v = @ralph.VerifierAgent::new()
  let mock = @agent.MockBackend::new(default_response="<wave_approved>")
  let backend = mock.boxed()
  let milestone : @types.Milestone = {
    id: "m1",
    goal: "Build auth",
    status: @types.MilestoneStatus::InProgress,
    tasks: [],
    current_wave: 0,
    summary: "",
  }
  let verdict = v.verify(milestone, 0, [], backend, "", perspectives=[
    CodeQuality,
    Performance,
    Security,
  ])
  let history = mock.get_history()
  assert_true(history.length() == 3)
  inspect(verdict, content="Approved")
}

///|
test "VerifierAgent::verify with goal alignment only calls backend once" {
  let v = @ralph.VerifierAgent::new()
  let mock = @agent.MockBackend::new(default_response="<wave_approved>")
  let backend = mock.boxed()
  let milestone : @types.Milestone = {
    id: "m1",
    goal: "Build auth",
    status: @types.MilestoneStatus::InProgress,
    tasks: [],
    current_wave: 0,
    summary: "",
  }
  let verdict = v.verify(milestone, 0, [], backend, "", perspectives=[
    GoalAlignment,
  ])
  let history = mock.get_history()
  assert_true(history.length() == 1)
  inspect(verdict, content="Approved")
}

///|
test "VerifierAgent::verify with failing mock backend is not approved" {
  let v = @ralph.VerifierAgent::new()
  let mock = @agent.FailingMockBackend::new(error_msg="backend failed")
  let backend = mock.boxed()
  let milestone : @types.Milestone = {
    id: "m1",
    goal: "Build auth",
    status: @types.MilestoneStatus::InProgress,
    tasks: [],
    current_wave: 0,
    summary: "",
  }
  let verdict = v.verify(milestone, 0, [], backend, "")
  match verdict {
    Approved => panic()
    NeedsRework(items) => assert_true(not(items.is_empty()))
    MilestoneFailed(_) => ()
  }
}
