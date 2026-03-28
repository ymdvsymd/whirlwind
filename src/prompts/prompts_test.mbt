///|
test "code_quality_checklist en contains Readability" {
  let content = @prompts.code_quality_checklist("en")
  assert_true(content.contains("Readability"))
  assert_true(content.contains("static code analysis only"))
}

///|
test "code_quality_checklist ja contains 可読性" {
  let content = @prompts.code_quality_checklist("ja")
  assert_true(content.contains("可読性"))
  assert_true(content.contains("静的分析のみ"))
}

///|
test "performance_checklist en contains Algorithmic complexity" {
  let content = @prompts.performance_checklist("en")
  assert_true(content.contains("Algorithmic complexity"))
  assert_true(content.contains("static code analysis only"))
}

///|
test "performance_checklist ja contains 静的分析のみ" {
  let content = @prompts.performance_checklist("ja")
  assert_true(content.contains("静的分析のみ"))
}

///|
test "security_checklist en contains Injection vulnerabilities" {
  let content = @prompts.security_checklist("en")
  assert_true(content.contains("Injection vulnerabilities"))
  assert_true(content.contains("static code analysis only"))
}

///|
test "security_checklist ja contains 静的分析のみ" {
  let content = @prompts.security_checklist("ja")
  assert_true(content.contains("静的分析のみ"))
}

///|
test "goal_alignment_checklist en contains Goal Alignment" {
  let content = @prompts.goal_alignment_checklist("en")
  assert_true(content.contains("Goal Alignment"))
  assert_false(content.contains("static code analysis only"))
  assert_false(content.contains("静的分析のみ"))
}

///|
test "goal_alignment_checklist ja contains ゴール整合性" {
  let content = @prompts.goal_alignment_checklist("ja")
  assert_true(content.contains("ゴール整合性"))
  assert_false(content.contains("static code analysis only"))
  assert_false(content.contains("静的分析のみ"))
}

///|
test "Perspective enum has 4 variants" {
  let perspectives : Array[@prompts.Perspective] = [
    CodeQuality,
    Performance,
    Security,
    GoalAlignment,
  ]
  assert_true(perspectives.length() == 4)
}

///|
test "Perspective::to_string displays correctly" {
  let p : @prompts.Perspective = CodeQuality
  inspect(p, content="CodeQuality")
  let p2 : @prompts.Perspective = GoalAlignment
  inspect(p2, content="GoalAlignment")
}

///|
test "parse_perspective returns CodeQuality for known string" {
  inspect(
    @prompts.parse_perspective("CodeQuality"),
    content="Some(CodeQuality)",
  )
}

///|
test "parse_perspective returns Performance for known string" {
  inspect(
    @prompts.parse_perspective("Performance"),
    content="Some(Performance)",
  )
}

///|
test "parse_perspective returns Security for known string" {
  inspect(@prompts.parse_perspective("Security"), content="Some(Security)")
}

///|
test "parse_perspective returns GoalAlignment for known string" {
  inspect(
    @prompts.parse_perspective("GoalAlignment"),
    content="Some(GoalAlignment)",
  )
}

///|
test "parse_perspective returns None for unknown string" {
  inspect(@prompts.parse_perspective("Unknown"), content="None")
}
