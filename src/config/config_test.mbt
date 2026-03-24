///|
test "ProjectConfig::from_json_string parses basic config" {
  let json =
    #|{
    #|  "agents": [
    #|    { "id": "dev-1", "kind": "claude-code", "role": "dev" },
    #|    { "id": "review-1", "kind": "codex", "role": "review", "model": "claude-sonnet" }
    #|  ]
    #|}
  let config = @config.ProjectConfig::from_json_string(json)
  assert_true(config.agents.length() == 2)
  inspect(config.agents[0].id, content="dev-1")
  inspect(config.agents[0].kind, content="ClaudeCode")
  inspect(config.agents[0].role, content="Builder")
  inspect(config.agents[1].id, content="review-1")
  inspect(config.agents[1].kind, content="Codex")
  inspect(config.agents[1].role, content="Review")
  inspect(config.agents[1].model, content="Some(\"claude-sonnet\")")
}

///|
test "ProjectConfig::from_json_string with defaults" {
  let json =
    #|{ "agents": [] }
  let config = @config.ProjectConfig::from_json_string(json)
  inspect(config.max_rework_attempts, content="3")
}

///|
test "ProjectConfig::default" {
  let config = @config.ProjectConfig::default()
  assert_true(config.agents.is_empty())
}

///|
test "ProjectConfig::validate detects no agents" {
  let config = @config.ProjectConfig::default()
  let errors = config.validate()
  assert_true(errors.length() > 0)
  assert_true(errors[0].contains("No agents"))
}

///|
test "ProjectConfig::validate detects duplicate ids" {
  let json =
    #|{
    #|  "agents": [
    #|    { "id": "dev-1", "kind": "claude-code", "role": "dev" },
    #|    { "id": "dev-1", "kind": "claude-code", "role": "dev" }
    #|  ]
    #|}
  let config = @config.ProjectConfig::from_json_string(json)
  let errors = config.validate()
  assert_true(errors.iter().any(fn(e) { e.contains("Duplicate") }))
}

///|
test "ProjectConfig::validate passes with valid config" {
  let json =
    #|{
    #|  "agents": [
    #|    { "id": "p1", "kind": "claude-code", "role": "planner" },
    #|    { "id": "dev-1", "kind": "claude-code", "role": "dev" }
    #|  ]
    #|}
  let config = @config.ProjectConfig::from_json_string(json)
  let errors = config.validate()
  assert_true(errors.is_empty())
}

///|
test "ProjectConfig::from_json_string invalid json" {
  let mut caught = false
  ignore(@config.ProjectConfig::from_json_string("not json")) catch {
    _ => caught = true
  }
  assert_true(caught)
}

///|
test "parse warns on unknown agent kind" {
  let json =
    #|{
    #|  "agents": [
    #|    { "id": "dev-1", "kind": "claude_code", "role": "dev" }
    #|  ]
    #|}
  let config = @config.ProjectConfig::from_json_string(json)
  // Unknown kind "claude_code" (underscore) should generate a warning
  assert_true(config.parse_warnings.length() == 1)
  assert_true(config.parse_warnings[0].contains("unknown kind"))
  assert_true(config.parse_warnings[0].contains("claude_code"))
  // Should default to Mock
  inspect(config.agents[0].kind, content="Mock")
}

///|
test "parse warns on unknown agent role" {
  let json =
    #|{
    #|  "agents": [
    #|    { "id": "dev-1", "kind": "claude-code", "role": "reviewer" }
    #|  ]
    #|}
  let config = @config.ProjectConfig::from_json_string(json)
  // Unknown role "reviewer" (should be "review") generates a warning
  assert_true(config.parse_warnings.length() == 1)
  assert_true(config.parse_warnings[0].contains("unknown role"))
  assert_true(config.parse_warnings[0].contains("reviewer"))
  // Should default to Builder
  inspect(config.agents[0].role, content="Builder")
}

///|
test "parse warns on both unknown kind and role" {
  let json =
    #|{
    #|  "agents": [
    #|    { "id": "agent-1", "kind": "openai", "role": "coder" }
    #|  ]
    #|}
  let config = @config.ProjectConfig::from_json_string(json)
  assert_true(config.parse_warnings.length() == 2)
  assert_true(config.parse_warnings[0].contains("unknown kind"))
  assert_true(config.parse_warnings[1].contains("unknown role"))
}

///|
test "validate includes parse warnings" {
  let json =
    #|{
    #|  "agents": [
    #|    { "id": "dev-1", "kind": "typo", "role": "dev" }
    #|  ]
    #|}
  let config = @config.ProjectConfig::from_json_string(json)
  let errors = config.validate()
  // Should contain the parse warning about unknown kind
  assert_true(errors.iter().any(fn(e) { e.contains("unknown kind") }))
  assert_true(errors.iter().any(fn(e) { e.contains("typo") }))
}

///|
test "valid kind and role produce no warnings" {
  let json =
    #|{
    #|  "agents": [
    #|    { "id": "dev-1", "kind": "claude-code", "role": "dev" },
    #|    { "id": "rev-1", "kind": "codex", "role": "review" },
    #|    { "id": "mock-1", "kind": "mock", "role": "planner" },
    #|    { "id": "test-1", "kind": "mock", "role": "dev" }
    #|  ]
    #|}
  let config = @config.ProjectConfig::from_json_string(json)
  assert_true(config.parse_warnings.is_empty())
}

///|
test "valid config parse_warnings is empty" {
  let json =
    #|{
    #|  "agents": [
    #|    { "id": "p1", "kind": "claude-code", "role": "planner" },
    #|    { "id": "dev-1", "kind": "claude-code", "role": "dev" }
    #|  ]
    #|}
  let config = @config.ProjectConfig::from_json_string(json)
  assert_true(config.parse_warnings.is_empty())
  let errors = config.validate()
  assert_true(errors.is_empty())
}

///|
test "parse planner and verifier roles" {
  let json =
    #|{
    #|  "agents": [
    #|    { "id": "p1", "kind": "claude-code", "role": "planner" },
    #|    { "id": "b1", "kind": "claude-code", "role": "builder" },
    #|    { "id": "v1", "kind": "codex", "role": "verifier" }
    #|  ]
    #|}
  let config = @config.ProjectConfig::from_json_string(json)
  assert_true(config.parse_warnings.is_empty())
  inspect(config.agents[0].role, content="Planner")
  inspect(config.agents[1].role, content="Builder")
  inspect(config.agents[2].role, content="Verifier")
}

///|
test "parse milestones_path and max_rework_attempts" {
  let json =
    #|{
    #|  "milestones_path": ".whirlwind/milestones.json",
    #|  "max_rework_attempts": 5,
    #|  "agents": [
    #|    { "id": "p1", "kind": "claude-code", "role": "planner" },
    #|    { "id": "b1", "kind": "claude-code", "role": "dev" }
    #|  ]
    #|}
  let config = @config.ProjectConfig::from_json_string(json)

  inspect(
    config.milestones_path,
    content="Some(\".whirlwind/milestones.json\")",
  )
  inspect(config.max_rework_attempts, content="5")
}

///|
test "milestones_path defaults to None" {
  let json =
    #|{
    #|  "agents": [
    #|    { "id": "dev-1", "kind": "claude-code", "role": "dev" }
    #|  ]
    #|}
  let config = @config.ProjectConfig::from_json_string(json)

  inspect(config.milestones_path, content="None")
  inspect(config.max_rework_attempts, content="3")
}

///|
test "validate requires planner" {
  let json =
    #|{
    #|  "agents": [
    #|    { "id": "dev-1", "kind": "claude-code", "role": "dev" }
    #|  ]
    #|}
  let config = @config.ProjectConfig::from_json_string(json)
  let errors = config.validate()
  assert_true(errors.iter().any(fn(e) { e.contains("planner") }))
}

///|
test "validate with planner and builder passes" {
  let json =
    #|{
    #|  "agents": [
    #|    { "id": "p1", "kind": "claude-code", "role": "planner" },
    #|    { "id": "b1", "kind": "claude-code", "role": "dev" }
    #|  ]
    #|}
  let config = @config.ProjectConfig::from_json_string(json)
  let errors = config.validate()
  assert_true(errors.is_empty())
}

///|
test "ProjectConfig::preset_ralph" {
  let config = @config.ProjectConfig::preset_ralph()

  assert_true(config.agents.length() == 3)
  inspect(config.agents[0].role, content="Planner")
  inspect(config.agents[1].role, content="Builder")
  inspect(config.agents[2].role, content="Verifier")
}

///|
test "apply_default_models sets defaults for ClaudeCode" {
  let config : @config.ProjectConfig = {
    agents: [
      { id: "p", kind: ClaudeCode, role: Planner, model: None },
      { id: "b", kind: ClaudeCode, role: Builder, model: None },
      { id: "v", kind: ClaudeCode, role: Verifier, model: None },
      { id: "r", kind: ClaudeCode, role: Review, model: None },
    ],
    parse_warnings: [],
    milestones_path: None,
    max_rework_attempts: 3,
  }
  let result = config.apply_default_models()
  inspect(result.agents[0].model, content="Some(\"opus\")")
  inspect(result.agents[1].model, content="Some(\"opus\")")
  inspect(result.agents[2].model, content="Some(\"sonnet\")")
  inspect(result.agents[3].model, content="Some(\"sonnet\")")
}

///|
test "apply_default_models does not override existing model" {
  let config : @config.ProjectConfig = {
    agents: [
      {
        id: "p",
        kind: ClaudeCode,
        role: Planner,
        model: Some("claude-sonnet-4-6"),
      },
    ],
    parse_warnings: [],
    milestones_path: None,
    max_rework_attempts: 3,
  }
  let result = config.apply_default_models()
  inspect(result.agents[0].model, content="Some(\"claude-sonnet-4-6\")")
}

///|
test "apply_default_models leaves Codex model as None" {
  let config : @config.ProjectConfig = {
    agents: [{ id: "b", kind: Codex, role: Builder, model: None }],
    parse_warnings: [],
    milestones_path: None,
    max_rework_attempts: 3,
  }
  let result = config.apply_default_models()
  inspect(result.agents[0].model, content="None")
}

///|
test "apply_default_models leaves Mock model as None" {
  let config : @config.ProjectConfig = {
    agents: [{ id: "m", kind: Mock, role: Planner, model: None }],
    parse_warnings: [],
    milestones_path: None,
    max_rework_attempts: 3,
  }
  let result = config.apply_default_models()
  inspect(result.agents[0].model, content="None")
}

///|
test "validate warns Mock with model" {
  let config : @config.ProjectConfig = {
    agents: [
      { id: "p", kind: Mock, role: Planner, model: Some("opus") },
      { id: "b", kind: Mock, role: Builder, model: None },
    ],
    parse_warnings: [],
    milestones_path: None,
    max_rework_attempts: 3,
  }
  let errors = config.validate()
  assert_true(
    errors.iter().any(fn(e) { e.contains("model is ignored for Mock") }),
  )
}

///|
test "validate warns ClaudeCode with codex model" {
  let config : @config.ProjectConfig = {
    agents: [
      { id: "p", kind: ClaudeCode, role: Planner, model: Some("gpt-4o") },
      { id: "b", kind: ClaudeCode, role: Builder, model: None },
    ],
    parse_warnings: [],
    milestones_path: None,
    max_rework_attempts: 3,
  }
  let errors = config.validate()
  assert_true(
    errors.iter().any(fn(e) { e.contains("may not be valid for claude-code") }),
  )
}

///|
test "validate warns Codex with claude model" {
  let config : @config.ProjectConfig = {
    agents: [
      { id: "p", kind: ClaudeCode, role: Planner, model: None },
      { id: "b", kind: Codex, role: Builder, model: Some("opus") },
    ],
    parse_warnings: [],
    milestones_path: None,
    max_rework_attempts: 3,
  }
  let errors = config.validate()
  assert_true(
    errors.iter().any(fn(e) { e.contains("may not be valid for codex") }),
  )
}

///|
test "validate no warning for valid kind+model combinations" {
  let config : @config.ProjectConfig = {
    agents: [
      { id: "p", kind: ClaudeCode, role: Planner, model: Some("opus") },
      { id: "b", kind: Codex, role: Builder, model: Some("gpt-4o") },
    ],
    parse_warnings: [],
    milestones_path: None,
    max_rework_attempts: 3,
  }
  let errors = config.validate()
  assert_true(errors.is_empty())
}
