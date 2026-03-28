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
}

///|
test "goal_alignment_checklist ja contains ゴール整合性" {
  let content = @prompts.goal_alignment_checklist("ja")
  assert_true(content.contains("ゴール整合性"))
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
