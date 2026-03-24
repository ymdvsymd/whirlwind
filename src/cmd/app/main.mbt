///|
/// Detect language from LANG environment variable
fn detect_lang() -> String {
  let env_lang = get_env("LANG")
  if env_lang.contains("ja") {
    "ja"
  } else {
    "en"
  }
}

///|
/// Resolve --lang flag: None/"auto" → detect, otherwise use as-is
fn resolve_lang(cli_lang : String?) -> String {
  @helpers.resolve_lang(cli_lang, detect_lang)
}

///|
fn main {
  let args = @sys.get_cli_args()
  let command = @cli.parse_cli_args(args, is_existing_file)
  match command {
    @cli.CliCommand::Run(
      config_path~,
      planner_kind~,
      builder_kind~,
      verifier_kind~,
      planner_model~,
      builder_model~,
      verifier_model~,
      milestones_path=cli_milestones,
      log_path~,
      lang=cli_lang,
      warnings~
    ) => {
      for w in warnings {
        log("WARN", w)
      }
      let lang = resolve_lang(cli_lang)
      match log_path {
        Some(path) => set_log_file(path)
        None => ()
      }
      run_ralph(
        config_path, lang, planner_kind, builder_kind, verifier_kind, planner_model,
        builder_model, verifier_model, cli_milestones,
      )
    }
    @cli.CliCommand::Validate(path) =>
      match path {
        Some(config_path) => run_validate(config_path)
        None => println("Usage: whirlwind validate <config.json>")
      }
    @cli.CliCommand::Help => print_usage()
    @cli.CliCommand::Version => println("whirlwind v__VERSION__")
  }
}

///|
fn print_usage() -> Unit {
  println("whirlwind - milestone-based autonomous development orchestrator")
  println("")
  println("Usage:")
  println(
    "  whirlwind [--planner=claude-code] [--builder=codex] [--verifier=claude-code]",
  )
  println("  whirlwind --config=whirlwind.json")
  println("  whirlwind validate <config>  # validate config file")
  println("")
  println("Agent kind options: claude | claude-code | codex | mock")
  println("")
  println("Options:")
  println("  --config=<path>         Config file path (default: preset)")
  println("  --planner=<kind>        Planner agent kind (default: claude-code)")
  println("  --builder=<kind>        Builder agent kind (default: claude-code)")
  println("  --verifier=<kind>       Verifier agent kind (default: codex)")
  println(
    "  --planner-model=<model>  Planner model (default: opus for claude-code)",
  )
  println(
    "  --builder-model=<model>  Builder model (default: opus for claude-code)",
  )
  println(
    "  --verifier-model=<model> Verifier model (default: sonnet for claude-code)",
  )
  println("  --milestones=<path>     Milestones file path")
  println(
    "  --lang=auto|ja|en       Review language (default: auto, detected from LANG env)",
  )
  println("  --log=<path>            Log file path")
  println("  --version, -v           Show version")
  println("")
  println(
    "Ralph loop: milestone → plan → execute → verify → next milestone.",
  )
}

///|
/// Run ralph loop mode
fn run_ralph(
  config_path : String?,
  lang : String,
  planner_kind : @types.AgentKind?,
  builder_kind : @types.AgentKind?,
  verifier_kind : @types.AgentKind?,
  planner_model : String?,
  builder_model : String?,
  verifier_model : String?,
  cli_milestones : String?,
) -> Unit {
  log("INFO", "Starting ralph loop mode...")
  // Load or create config
  let config = match config_path {
    Some(path) => {
      let content = match read_file_result(path) {
        Err(err) => {
          log("ERROR", "Failed to read config: \{err}")
          return
        }
        Ok(c) => c
      }
      @config.ProjectConfig::from_json_string(content) catch {
        err => {
          log("ERROR", "Failed to parse config: \{err}")
          return
        }
      }
    }
    None => @config.ProjectConfig::preset_ralph()
  }
  // Apply kind and model overrides
  let config = @cli.apply_overrides(
    config,
    planner_kind~,
    builder_kind~,
    verifier_kind~,
    planner_model~,
    builder_model~,
    verifier_model~,
  )
  // Apply default models for agents without explicit model
  let config = config.apply_default_models()
  // Apply CLI milestones path override
  let config : @config.ProjectConfig = match cli_milestones {
    Some(path) => { ..config, milestones_path: Some(path) }
    None => config
  }
  // Validate config
  let errors = config.validate()
  if not(errors.is_empty()) {
    for e in errors {
      log("ERROR", e)
    }
    return
  }
  // Create backends
  let backends = @agent.create_backends(config.agents)
  // Load or create milestones
  let milestones_path = match config.milestones_path {
    Some(p) => p
    None => ".whirlwind/milestones.json"
  }
  let mgr = if is_existing_file(milestones_path) {
    match read_file_result(milestones_path) {
      Err(_) => {
        log("WARN", "Could not read milestones file, starting fresh")
        @ralph.MilestoneManager::new()
      }
      Ok(content) =>
        @ralph.MilestoneManager::load_from_json(content) catch {
          err => {
            log(
              "WARN",
              "Could not parse milestones file: \{err}, starting fresh",
            )
            @ralph.MilestoneManager::new()
          }
        }
    }
  } else {
    log("INFO", "No milestones file found at \{milestones_path}")
    log("INFO", "Create \{milestones_path} with milestone definitions to start")
    @ralph.MilestoneManager::new()
  }
  if mgr.milestones.is_empty() {
    log("WARN", "No milestones defined. Create \{milestones_path} first.")
    return
  }
  // Create callbacks
  let callbacks : @types.OrchestratorCallbacks = {
    on_event: fn(e) {
      match e {
        AgentOutput(ev) => log("OUT", "[\{ev.agent_id}] \{ev.line}")
        AgentComplete(ev) => log("INFO", "Agent \{ev.agent_id} complete")
        TaskStart(ev) =>
          log(
            "INFO",
            "Task \{ev.task_id}: \{ev.description} (agent: \{ev.agent_id})",
          )
        TaskComplete(ev) => log("INFO", "Task \{ev.task_id} → \{ev.status}")
        TaskAssign(ev) =>
          log("INFO", "Assigned \{ev.task_id} → \{ev.agent_id}")
        ReviewStart(ev) =>
          log("INFO", "Review \{ev.task_id} by \{ev.reviewer_id}")
        ReviewComplete(ev) => log("INFO", "Review \{ev.task_id}: \{ev.verdict}")
        PhaseChange(ev) => log("INFO", "Phase: \{ev.phase}")
        SessionComplete(_) => log("INFO", "Session complete")
        Info(ev) => log("INFO", ev.message)
      }
    },
    on_save: fn() { write_file_sync(milestones_path, mgr.to_json()) },
  }
  // Run ralph loop
  let rl = @ralph.RalphLoop::new(config, mgr, backends, callbacks, lang~)
  rl.run()
  // Save milestones
  let json = mgr.to_json()
  write_file_sync(milestones_path, json)
  log("INFO", "Milestones saved to \{milestones_path}")
}

///|
fn read_file_result(path : String) -> Result[String, String] {
  @agent.check_ffi_error(read_file_sync(path))
}

///|
fn is_existing_file(path : String) -> Bool {
  match read_file_result(path) {
    Ok(_) => true
    Err(_) => false
  }
}

///|
fn run_validate(config_path : String) -> Unit {
  let content = match read_file_result(config_path) {
    Err(err) => {
      println("Failed to read config: \{err}")
      return
    }
    Ok(c) => c
  }
  let config = @config.ProjectConfig::from_json_string(content) catch {
    err => {
      println("Invalid config: \{err}")
      return
    }
  }
  let errors = config.validate()
  if errors.is_empty() {
    println("Config is valid.")
    println("  agents: \{config.agents.length()}")
    for agent in config.agents {
      println("    - \{agent.id} (\{agent.kind}, \{agent.role})")
    }
  } else {
    println("Config validation errors:")
    for err in errors {
      println("  - \{err}")
    }
  }
}
