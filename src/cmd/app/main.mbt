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
      plan_path~,
      dev_kind~,
      review_kind~,
      review_interval~,
      rlm~,
      ralph~,
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
      if ralph {
        run_ralph(config_path, lang, dev_kind, review_kind)
      } else {
        let initial_task = load_plan_task(plan_path)
        run_repl(
          config_path, plan_path, rlm, initial_task, dev_kind, review_kind, review_interval,
          lang,
        )
      }
    }
    @cli.CliCommand::Validate(path) =>
      match path {
        Some(config_path) => run_validate(config_path)
        None => println("Usage: tornado validate <config.json>")
      }
    @cli.CliCommand::Help => print_usage()
    @cli.CliCommand::Version => println("tornado v__VERSION__")
  }
}

///|
fn print_usage() -> Unit {
  println("tornado - multi-agent development orchestrator")
  println("")
  println("Usage:")
  println(
    "  tornado <plan.md> [--dev=codex] [--review=claude]  # start from plan file",
  )
  println("  tornado --config=tornado.json [--dev=codex] [--review=claude]")
  println(
    "  tornado                    # start with preset (dev:claude-code, review:codex)",
  )
  println("  tornado --dev=codex --review=claude")
  println(
    "  tornado --review-interval=3          # review every 3 dev iterations",
  )
  println("  tornado --rlm TODO.md                # improvement loop mode")
  println(
    "  tornado --ralph                      # ralph loop (milestone-based autonomous dev)",
  )
  println("  tornado validate <config>  # validate config file")
  println("")
  println("Agent kind options: claude | claude-code | codex | api | mock")
  println("")
  println("Options:")
  println("  --review-interval=N  Run N dev iterations per review (default: 1)")
  println(
    "  --rlm                Enable improvement loop mode (measure→improve→verify→commit/revert)",
  )
  println("  --version, -v          Show version")
  println(
    "  --ralph              Enable ralph loop mode (milestone→plan→execute→verify)",
  )
  println(
    "  --lang=auto|ja|en    Review language (default: auto, detected from LANG env)",
  )
  println("")
  println("Autonomous heartbeat: dev runs → reviewer reviews →")
  println("dev continues with next task → forever until Ctrl+C.")
  println("Session auto-saved to .tornado/session.json for resume.")
}

///|
/// Run ralph loop mode
fn run_ralph(
  config_path : String?,
  lang : String,
  dev_kind : @types.AgentKind?,
  review_kind : @types.AgentKind?,
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
      try {
        let parsed = @config.ProjectConfig::from_json_string(content)
        // Apply ralph_enabled override
        { ..parsed, ralph_enabled: true }
      } catch {
        err => {
          log("ERROR", "Failed to parse config: \{err}")
          return
        }
      }
    }
    None => @config.ProjectConfig::preset_ralph()
  }
  // Apply kind overrides
  let config = @cli.apply_overrides(config, dev_kind~, review_kind~)
  // Ensure ralph_enabled is preserved after overrides
  let config : @config.ProjectConfig = { ..config, ralph_enabled: true }
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
    None => ".tornado/milestones.json"
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
fn load_plan_task(plan_path : String?) -> String? {
  match plan_path {
    Some(path) =>
      // Verify the file exists and is readable
      match read_file_result(path) {
        Err(err) => {
          log("WARN", "Failed to read plan file \{path}: \{err}")
          None
        }
        Ok(content) =>
          if content.trim().to_string().is_empty() {
            log("WARN", "Plan file is empty: \{path}")
            None
          } else {
            log("BOOT", "Using plan file: \{path}")
            Some(build_plan_file_task(path, ""))
          }
      }
    None => None
  }
}

///|
/// Load config from file, or use preset
fn load_config(config_path : String?) -> @config.ProjectConfig {
  match config_path {
    Some(path) => {
      let content = match read_file_result(path) {
        Err(err) => {
          log("WARN", "Failed to read \{path}: \{err}")
          log("WARN", "Falling back to preset config")
          return @config.ProjectConfig::preset_default()
        }
        Ok(c) => c
      }
      @config.ProjectConfig::from_json_string(content) catch {
        err => {
          log("WARN", "Invalid config: \{err}, using preset")
          @config.ProjectConfig::preset_default()
        }
      }
    }
    None => @config.ProjectConfig::preset_default()
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
    println("  project_dir: \{config.project_dir}")
    println("  review_dir: \{config.review_dir}")
    println("  max_review_cycles: \{config.max_review_cycles}")
    println("  review_interval: \{config.review_interval}")
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
