///|
fn file_exists_mock(path : String) -> Bool {
  path == "plan.md" || path == "tasks.txt"
}

///|
test "parse_cli_args role-specific kind flags" {
  let args = [
    "whirlwind", "--planner=claude-code", "--builder=codex", "--verifier=mock",
  ]
  let parsed = @cli.parse_cli_args(args, file_exists_mock)
  match parsed {
    Run(
      config_path=config,
      planner_kind~,
      builder_kind~,
      verifier_kind~,
      milestones_path~,
      lang~,
      warnings~,
      ..
    ) => {
      inspect(config, content="None")
      inspect(planner_kind, content="Some(ClaudeCode)")
      inspect(builder_kind, content="Some(Codex)")
      inspect(verifier_kind, content="Some(Mock)")
      inspect(milestones_path, content="None")
      inspect(lang, content="None")
      assert_true(warnings.is_empty())
    }
    _ => panic()
  }
}

///|
test "parse_cli_args supports --config=value" {
  let args = ["whirlwind", "--config=config.json", "--builder=codex"]
  let parsed = @cli.parse_cli_args(args, file_exists_mock)
  match parsed {
    Run(config_path=config, builder_kind~, warnings~, ..) => {
      inspect(config, content="Some(\"config.json\")")
      inspect(builder_kind, content="Some(Codex)")
      assert_true(warnings.is_empty())
    }
    _ => panic()
  }
}

///|
test "parse_cli_args supports --config <value>" {
  let args = ["whirlwind", "--config", "config.json"]
  let parsed = @cli.parse_cli_args(args, file_exists_mock)
  match parsed {
    Run(config_path=config, warnings~, ..) => {
      inspect(config, content="Some(\"config.json\")")
      assert_true(warnings.is_empty())
    }
    _ => panic()
  }
}

///|
test "parse_cli_args --milestones=path" {
  let args = ["whirlwind", "--milestones=.whirlwind/milestones.json"]
  let parsed = @cli.parse_cli_args(args, file_exists_mock)
  match parsed {
    Run(milestones_path~, warnings~, ..) => {
      inspect(milestones_path, content="Some(\".whirlwind/milestones.json\")")
      assert_true(warnings.is_empty())
    }
    _ => panic()
  }
}

///|
test "parse_cli_args validate command" {
  let args = ["whirlwind", "validate", "config.json"]
  let parsed = @cli.parse_cli_args(args, file_exists_mock)
  match parsed {
    Validate(path) => inspect(path, content="Some(\"config.json\")")
    _ => panic()
  }
}

///|
test "parse_cli_args version command" {
  let args = ["whirlwind", "version"]
  let parsed = @cli.parse_cli_args(args, file_exists_mock)
  match parsed {
    Version => ()
    _ => panic()
  }
}

///|
test "parse_cli_args --version flag" {
  let args = ["whirlwind", "--version"]
  let parsed = @cli.parse_cli_args(args, file_exists_mock)
  match parsed {
    Version => ()
    _ => panic()
  }
}

///|
test "parse_cli_args -v flag" {
  let args = ["whirlwind", "-v"]
  let parsed = @cli.parse_cli_args(args, file_exists_mock)
  match parsed {
    Version => ()
    _ => panic()
  }
}

///|
test "parse_cli_args --log=path" {
  let args = ["whirlwind", "--log=/tmp/whirlwind.log"]
  let parsed = @cli.parse_cli_args(args, file_exists_mock)
  match parsed {
    Run(log_path~, ..) =>
      inspect(log_path, content="Some(\"/tmp/whirlwind.log\")")
    _ => panic()
  }
}

///|
test "parse_cli_args --log path" {
  let args = ["whirlwind", "--log", "/tmp/whirlwind.log"]
  let parsed = @cli.parse_cli_args(args, file_exists_mock)
  match parsed {
    Run(log_path~, ..) =>
      inspect(log_path, content="Some(\"/tmp/whirlwind.log\")")
    _ => panic()
  }
}

///|
test "parse_cli_args --log missing value warns" {
  let args = ["whirlwind", "--log"]
  let parsed = @cli.parse_cli_args(args, file_exists_mock)
  match parsed {
    Run(log_path~, warnings~, ..) => {
      inspect(log_path, content="None")
      assert_true(warnings.length() == 1)
      assert_true(warnings[0].contains("Missing value for --log"))
    }
    _ => panic()
  }
}

///|
test "parse_cli_args positional argument warns" {
  let args = ["whirlwind", "config.json"]
  let parsed = @cli.parse_cli_args(args, file_exists_mock)
  match parsed {
    Run(warnings~, ..) => {
      assert_true(warnings.length() == 1)
      assert_true(warnings[0].contains("Unexpected argument"))
    }
    _ => panic()
  }
}

///|
test "parse_cli_args --ralph flag accepted without warning" {
  let args = ["whirlwind", "--ralph"]
  let parsed = @cli.parse_cli_args(args, file_exists_mock)
  match parsed {
    Run(warnings~, ..) => assert_true(warnings.is_empty())
    _ => panic()
  }
}

///|
test "parse_cli_args --lang=ja" {
  let args = ["whirlwind", "--lang=ja"]
  let parsed = @cli.parse_cli_args(args, file_exists_mock)
  match parsed {
    Run(lang~, warnings~, ..) => {
      inspect(lang, content="Some(\"ja\")")
      assert_true(warnings.is_empty())
    }
    _ => panic()
  }
}

///|
test "parse_cli_args --lang=invalid warns" {
  let args = ["whirlwind", "--lang=fr"]
  let parsed = @cli.parse_cli_args(args, file_exists_mock)
  match parsed {
    Run(lang~, warnings~, ..) => {
      inspect(lang, content="None")
      assert_true(warnings.length() == 1)
      assert_true(warnings[0].contains("Unknown --lang"))
    }
    _ => panic()
  }
}

///|
test "apply_overrides rewrites role kinds" {
  let base = @config.ProjectConfig::preset_ralph()
  let updated = @cli.apply_overrides(
    base,
    planner_kind=Some(@types.AgentKind::Mock),
    builder_kind=Some(@types.AgentKind::Codex),
    verifier_kind=Some(@types.AgentKind::ClaudeCode),
  )

  assert_true(updated.agents.length() == 3)
  inspect(updated.agents[0].role, content="Planner")
  inspect(updated.agents[0].kind, content="Mock")
  inspect(updated.agents[1].role, content="Builder")
  inspect(updated.agents[1].kind, content="Codex")
  inspect(updated.agents[2].role, content="Verifier")
  inspect(updated.agents[2].kind, content="ClaudeCode")
}

///|
test "apply_overrides keeps kinds when not overridden" {
  let base = @config.ProjectConfig::preset_ralph()
  let updated = @cli.apply_overrides(base)
  inspect(updated.agents[0].kind, content="ClaudeCode")
  inspect(updated.agents[1].kind, content="ClaudeCode")
  inspect(updated.agents[2].kind, content="Codex")
}

///|
test "parse_cli_args --planner-model=opus" {
  let args = ["whirlwind", "--planner-model=opus"]
  let parsed = @cli.parse_cli_args(args, file_exists_mock)
  match parsed {
    Run(planner_model~, warnings~, ..) => {
      inspect(planner_model, content="Some(\"opus\")")
      assert_true(warnings.is_empty())
    }
    _ => panic()
  }
}

///|
test "parse_cli_args --builder-model=sonnet" {
  let args = ["whirlwind", "--builder-model=sonnet"]
  let parsed = @cli.parse_cli_args(args, file_exists_mock)
  match parsed {
    Run(builder_model~, warnings~, ..) => {
      inspect(builder_model, content="Some(\"sonnet\")")
      assert_true(warnings.is_empty())
    }
    _ => panic()
  }
}

///|
test "parse_cli_args --verifier-model=claude-sonnet-4-6" {
  let args = ["whirlwind", "--verifier-model=claude-sonnet-4-6"]
  let parsed = @cli.parse_cli_args(args, file_exists_mock)
  match parsed {
    Run(verifier_model~, warnings~, ..) => {
      inspect(verifier_model, content="Some(\"claude-sonnet-4-6\")")
      assert_true(warnings.is_empty())
    }
    _ => panic()
  }
}

///|
test "parse_cli_args all model flags together" {
  let args = [
    "whirlwind", "--planner-model=opus", "--builder-model=opus", "--verifier-model=sonnet",
  ]
  let parsed = @cli.parse_cli_args(args, file_exists_mock)
  match parsed {
    Run(planner_model~, builder_model~, verifier_model~, warnings~, ..) => {
      inspect(planner_model, content="Some(\"opus\")")
      inspect(builder_model, content="Some(\"opus\")")
      inspect(verifier_model, content="Some(\"sonnet\")")
      assert_true(warnings.is_empty())
    }
    _ => panic()
  }
}

///|
test "parse_cli_args --planner-model= empty warns" {
  let args = ["whirlwind", "--planner-model="]
  let parsed = @cli.parse_cli_args(args, file_exists_mock)
  match parsed {
    Run(planner_model~, warnings~, ..) => {
      inspect(planner_model, content="None")
      assert_true(warnings.length() == 1)
      assert_true(warnings[0].contains("Missing value for --planner-model"))
    }
    _ => panic()
  }
}

///|
test "apply_overrides rewrites models" {
  let base = @config.ProjectConfig::preset_ralph()
  let updated = @cli.apply_overrides(
    base,
    planner_model=Some("sonnet"),
    builder_model=Some("opus"),
    verifier_model=Some("haiku"),
  )
  inspect(updated.agents[0].model, content="Some(\"sonnet\")")
  inspect(updated.agents[1].model, content="Some(\"opus\")")
  inspect(updated.agents[2].model, content="Some(\"haiku\")")
}

///|
test "apply_overrides keeps models when not overridden" {
  let base : @config.ProjectConfig = {
    agents: [
      { id: "p", kind: ClaudeCode, role: Planner, model: Some("custom") },
      { id: "b", kind: ClaudeCode, role: Builder, model: None },
    ],
    parse_warnings: [],
    milestones_path: None,
    max_rework_attempts: 3,
  }
  let updated = @cli.apply_overrides(base)
  inspect(updated.agents[0].model, content="Some(\"custom\")")
  inspect(updated.agents[1].model, content="None")
}

///|
test "ProjectConfig::preset_ralph" {
  let config = @config.ProjectConfig::preset_ralph()
  assert_true(config.agents.length() == 3)
  inspect(config.agents[0].role, content="Planner")
  inspect(config.agents[1].role, content="Builder")
  inspect(config.agents[2].role, content="Verifier")
}
