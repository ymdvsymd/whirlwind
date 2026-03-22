// ── REPL + Autonomous heartbeat ──────────────────────────────

///|
/// Autonomous loop: task → dev → review → continue
fn run_repl(
  config_path : String?,
  plan_path : String?,
  rlm : Bool,
  initial_task : String?,
  dev_kind : @types.AgentKind?,
  review_kind : @types.AgentKind?,
  review_interval : Int?,
  lang : String,
) -> Unit {
  let loaded_config = load_config(config_path)
  let config = @cli.apply_overrides(
    loaded_config,
    dev_kind~,
    review_kind~,
    review_interval~,
  )
  println("")
  println("  tornado - autonomous development orchestrator")
  println("")
  match dev_kind {
    Some(kind) => log("BOOT", "Override: dev=\{@cli.kind_name(kind)}")
    None => ()
  }
  match review_kind {
    Some(kind) => log("BOOT", "Override: review=\{@cli.kind_name(kind)}")
    None => ()
  }
  log("BOOT", "Agents:")
  for agent in config.agents {
    log("BOOT", "  \{agent.id} (\{agent.kind}, \{agent.role})")
  }
  log("BOOT", "Max review cycles: \{config.max_review_cycles}")
  log(
    "BOOT",
    "Review interval: every \{config.review_interval} dev iteration(s)",
  )
  if rlm {
    log("BOOT", "RLM improvement loop mode: enabled")
  }
  log("BOOT", "Review language: \{lang}")
  println("")
  let backends = @agent.create_backends(config.agents)
  let dev_id = find_agent_id(config.agents, @types.AgentRole::Dev)
  let reviewer_id = find_agent_id(config.agents, @types.AgentRole::Review)
  let agent_sessions : Map[String, String] = {}
  let mut iteration = 0
  let mut next_task : String = ""
  let mut last_review_summary : String = ""
  let mut dev_since_review = 0
  let accumulated_dev_outputs : Array[String] = []
  let mut last_cycle_summary : String = ""
  // ── Token usage tracking ──
  let mut total_input_tokens = 0
  let mut total_output_tokens = 0
  let mut total_cache_read = 0
  let mut total_cache_write = 0
  let mut total_cost_usd = 0.0
  // ── Check for saved session ──
  if initial_task is None {
    match load_session() {
      Some(saved) => {
        log("RESUME", "Found saved session (iteration \{saved.iteration})")
        log("RESUME", "  Phase: \{saved.phase}")
        log("RESUME", "  Task: \{@display.truncate(saved.task, 80)}")
        for entry in saved.agent_sessions {
          log("RESUME", "  Agent \{entry.0}: session \{entry.1}")
          agent_sessions[entry.0] = entry.1
        }
        println("")
        let answer = prompt_sync("Resume this session? [Y/n] ")
        if answer == "n" || answer == "N" || answer == "no" {
          log("RESUME", "Starting fresh")
          clear_session()
        } else {
          log("RESUME", "Resuming...")
          restore_sessions(backends, agent_sessions)
          iteration = saved.iteration
          last_review_summary = saved.review_summary
          dev_since_review = saved.dev_since_review
          for output in saved.accumulated_dev_outputs {
            accumulated_dev_outputs.push(output)
          }
          match saved.phase {
            "dev" | "review" => next_task = saved.task
            _ =>
              // idle → previous iteration done, build continuation
              next_task = match plan_path {
                Some(path) => build_plan_file_task(path, saved.review_summary)
                None =>
                  build_continuation_task(saved.task, saved.review_summary)
              }
          }
        }
      }
      None => ()
    }
  } else {
    log("BOOT", "Plan file mode: skip session resume")
  }
  // ── Get initial task if needed ──
  if next_task.is_empty() {
    match initial_task {
      Some(task) => {
        next_task = task
        log("HEARTBEAT", "Starting from provided plan file")
      }
      None => {
        println("")
        next_task = prompt_sync("task> ")
        if next_task == "quit" || next_task == "exit" {
          log("EXIT", "Bye.")
          return
        }
        if next_task.is_empty() {
          // No task given → start from TODO files
          next_task = build_initial_task_from_todos()
          log(
            "HEARTBEAT", "No task specified. Starting from project TODO files.",
          )
        }
      }
    }
  }
  // ── Start stdin watcher for user interrupts ──
  start_stdin_watcher()
  log("BOOT", "Type and press Enter anytime to queue instructions.")
  println("")
  // ── Autonomous loop: runs until Ctrl+C ──
  while true {
    iteration += 1
    log("HEARTBEAT", "=== Iteration \{iteration} ===")
    log("HEARTBEAT", "Task: \{@display.truncate(next_task, 120)}")
    // ── Check for user interrupt before dev ──
    let interrupt = check_interrupt()
    if not(interrupt.is_empty()) {
      log(
        "USER",
        "Applying user instructions: \{@display.truncate(interrupt, 100)}",
      )
      next_task = next_task +
        "\n\n## Additional Instructions from User\n" +
        interrupt
    }
    // ── dev phase ──
    save_session(@helpers.SessionState::{
      iteration,
      phase: "dev",
      task: next_task,
      dev_output: "",
      review_summary: last_review_summary,
      agent_sessions,
      dev_since_review,
      accumulated_dev_outputs,
    })
    // Per-iteration usage tracking
    let mut iter_input_tokens = 0
    let mut iter_output_tokens = 0
    let mut iter_cache_read = 0
    let mut iter_cache_write = 0
    let mut iter_cost_usd = 0.0
    let on_usage : (Int, Int, Int, Int, Double) -> Unit = fn(
      it,
      ot,
      cr,
      cw,
      cost,
    ) {
      iter_input_tokens += it
      iter_output_tokens += ot
      iter_cache_read += cr
      iter_cache_write += cw
      iter_cost_usd += cost
      total_input_tokens += it
      total_output_tokens += ot
      total_cache_read += cr
      total_cache_write += cw
      total_cost_usd += cost
    }
    let dev_result = run_dev(
      dev_id,
      backends,
      next_task,
      agent_sessions,
      on_usage~,
    )
    dev_since_review += 1
    accumulated_dev_outputs.push(@display.truncate(dev_result, 5000))
    // ── Check for user interrupt after dev ──
    let post_dev_interrupt = check_interrupt()
    if not(post_dev_interrupt.is_empty()) {
      log(
        "USER",
        "User instructions for review: \{@display.truncate(post_dev_interrupt, 100)}",
      )
    }
    // ── Skip review if dev produced no output (likely failed) ──
    if dev_result.trim().is_empty() {
      log("HEARTBEAT", "Dev produced no output, skipping review")
      last_review_summary = "Dev agent produced no output - likely failed"
      save_session(@helpers.SessionState::{
        iteration,
        phase: "idle",
        task: next_task,
        dev_output: dev_result,
        review_summary: last_review_summary,
        agent_sessions,
        dev_since_review,
        accumulated_dev_outputs,
      })
      continue
    }
    // ── review_interval check: only review after N dev iterations ──
    if dev_since_review < config.review_interval {
      log(
        "HEARTBEAT",
        "Dev \{dev_since_review}/\{config.review_interval} before review",
      )
      log("SUMMARY", "Dev output: \{@display.truncate(dev_result, 300)}")
      log("HEARTBEAT", "=== Iteration \{iteration} complete (no review) ===")
      log(
        "USAGE",
        "Iter \{iteration}: \{iter_input_tokens}in/\{iter_output_tokens}out (cache: \{iter_cache_read}r/\{iter_cache_write}w), $\{iter_cost_usd}",
      )
      log(
        "USAGE",
        "Total: \{total_input_tokens}in/\{total_output_tokens}out (cache: \{total_cache_read}r/\{total_cache_write}w), $\{total_cost_usd}",
      )
      save_session(@helpers.SessionState::{
        iteration,
        phase: "idle",
        task: next_task,
        dev_output: dev_result,
        review_summary: last_review_summary,
        agent_sessions,
        dev_since_review,
        accumulated_dev_outputs,
      })
      // Build next task without review feedback
      let user_input = check_interrupt()
      if not(user_input.is_empty()) {
        log(
          "USER",
          "Using user instructions: \{@display.truncate(user_input, 100)}",
        )
        next_task = user_input
      } else {
        next_task = build_next_task(
          plan_path,
          rlm,
          "",
          dev_result,
          current_step=dev_since_review,
          total_steps=config.review_interval,
          cycle_summary=last_cycle_summary,
        )
      }
      if not(post_dev_interrupt.is_empty()) {
        next_task = next_task +
          "\n\n## Additional Instructions from User\n" +
          post_dev_interrupt
      }
      continue
    }
    // ── review phase ──
    let combined_dev_output = join_dev_outputs(accumulated_dev_outputs)
    save_session(@helpers.SessionState::{
      iteration,
      phase: "review",
      task: next_task,
      dev_output: dev_result,
      review_summary: last_review_summary,
      agent_sessions,
      dev_since_review,
      accumulated_dev_outputs,
    })
    let review_result = match reviewer_id {
      Some(rid) =>
        run_review(
          dev_id,
          rid,
          backends,
          next_task,
          combined_dev_output,
          config.max_review_cycles,
          agent_sessions,
          lang,
          on_usage~,
        )
      None => {
        log("SKIP", "No reviewer configured")
        ReviewOutcome::Approved("")
      }
    }
    // ── Build cycle summary before clearing ──
    let review_text = match review_result {
      Approved(s) => s
      Rejected(s) => s
    }
    let cycle_summary = build_cycle_summary(
      iteration, accumulated_dev_outputs, review_text,
    )
    last_cycle_summary = cycle_summary
    log("SUMMARY", @display.truncate(cycle_summary, 500))
    // Reset accumulated state after review
    dev_since_review = 0
    accumulated_dev_outputs.clear()
    // ── determine next task ──
    match review_result {
      Approved(summary) => {
        last_review_summary = summary
        save_session(@helpers.SessionState::{
          iteration,
          phase: "idle",
          task: next_task,
          dev_output: dev_result,
          review_summary: summary,
          agent_sessions,
          dev_since_review,
          accumulated_dev_outputs,
        })
        log("HEARTBEAT", "=== Iteration \{iteration} complete ===")
        log(
          "USAGE",
          "Iter \{iteration}: \{iter_input_tokens}in/\{iter_output_tokens}out (cache: \{iter_cache_read}r/\{iter_cache_write}w), $\{iter_cost_usd}",
        )
        log(
          "USAGE",
          "Total: \{total_input_tokens}in/\{total_output_tokens}out (cache: \{total_cache_read}r/\{total_cache_write}w), $\{total_cost_usd}",
        )
        // Check for user interrupt → use as next task
        let user_input = check_interrupt()
        if not(user_input.is_empty()) {
          log(
            "USER",
            "Using user instructions: \{@display.truncate(user_input, 100)}",
          )
          next_task = user_input
        } else {
          // Auto-continue: build next task for dev
          log("HEARTBEAT", "Building next task from project state...")
          next_task = build_next_task(
            plan_path,
            rlm,
            summary,
            dev_result,
            cycle_summary~,
          )
        }
        // Also apply any post-dev interrupt that wasn't consumed
        if not(post_dev_interrupt.is_empty()) {
          next_task = next_task +
            "\n\n## Additional Instructions from User\n" +
            post_dev_interrupt
        }
      }
      Rejected(reason) => {
        last_review_summary = reason
        save_session(@helpers.SessionState::{
          iteration,
          phase: "idle",
          task: next_task,
          dev_output: dev_result,
          review_summary: reason,
          agent_sessions,
          dev_since_review,
          accumulated_dev_outputs,
        })
        log("HEARTBEAT", "=== Iteration \{iteration} complete (REJECTED) ===")
        log(
          "USAGE",
          "Iter \{iteration}: \{iter_input_tokens}in/\{iter_output_tokens}out (cache: \{iter_cache_read}r/\{iter_cache_write}w), $\{iter_cost_usd}",
        )
        log(
          "USAGE",
          "Total: \{total_input_tokens}in/\{total_output_tokens}out (cache: \{total_cache_read}r/\{total_cache_write}w), $\{total_cost_usd}",
        )
        // Check for queued user input first
        let queued = check_interrupt()
        if not(queued.is_empty()) {
          log(
            "USER",
            "Using queued instructions: \{@display.truncate(queued, 100)}",
          )
          next_task = queued
        } else {
          // Wait for user input via interrupt file
          println("")
          log(
            "HEARTBEAT", "Review rejected. Type next task and press Enter (or Ctrl+C to stop).",
          )
          let mut user_input = ""
          while user_input.is_empty() {
            user_input = check_interrupt()
            if user_input.is_empty() {
              sleep_ms(500)
            }
          }
          log("USER", "Received: \{@display.truncate(user_input, 100)}")
          next_task = user_input
        }
      }
    }
  }
}

///|
/// Review outcome for the main loop
enum ReviewOutcome {
  Approved(String) // review summary
  Rejected(String) // reason
}

///|
/// Restore session IDs to backends
fn restore_sessions(
  backends : Map[String, @agent.BoxedBackend],
  agent_sessions : Map[String, String],
) -> Unit {
  for entry in agent_sessions {
    match backends.get(entry.0) {
      Some(backend) => {
        backend.set_session_id(entry.1)
        log("SESSION", "\{entry.0}: restored session \{entry.1}")
      }
      None => ()
    }
  }
}

///|
/// Find agent id by role
fn find_agent_id(
  agents : Array[@types.AgentConfig],
  role : @types.AgentRole,
) -> String? {
  for agent in agents {
    if agent.role == role {
      return Some(agent.id)
    }
  }
  None
}

///|
/// Run dev agent, return output and call on_usage for token tracking
fn run_dev(
  dev_id : String?,
  backends : Map[String, @agent.BoxedBackend],
  task : String,
  agent_sessions : Map[String, String],
  on_usage? : (Int, Int, Int, Int, Double) -> Unit = fn(_, _, _, _, _) {  },
) -> String {
  let id = dev_id.unwrap_or("dev")
  match backends.get(id) {
    Some(backend) => {
      match agent_sessions.get(id) {
        Some(sid) => log("DEV", "Starting \{id} (resume: \{sid})...")
        None => log("DEV", "Starting \{id} (new session)...")
      }
      println("")
      let result = backend.run(task, "", fn(event) {
        match event {
          @types.AgentEvent::OutputLine(text) =>
            if not(text.is_empty()) {
              println("  [\{id}] \{text}")
            }
          @types.AgentEvent::Info(msg) => log("INFO", "\{id}: \{msg}")
          @types.AgentEvent::ToolCall(name=tool_name, input=tool_input) =>
            log(
              "CALL",
              "\{id} \{@display.format_tool_call(tool_name, tool_input)}",
            )
          @types.AgentEvent::ToolResult(name=tool_name, output=tool_output) =>
            log(
              "DONE",
              "\{id} \{@display.format_tool_result(tool_name, tool_output)}",
            )
          @types.AgentEvent::SubAgentStart(agent_type~, task=desc) =>
            log(
              "AGENT",
              "\{id} spawned \{agent_type}: \{@display.truncate(desc, 80)}",
            )
          @types.AgentEvent::SubAgentEnd(agent_type~) =>
            log("AGENT", "\{id} \{agent_type} completed")
          @types.AgentEvent::StatusChange(status) =>
            log("DEV", "\{id} -> \{status}")
          @types.AgentEvent::SessionId(sid) => {
            agent_sessions[id] = sid
            log("DEV", "\{id} session: \{sid}")
          }
          @types.AgentEvent::Usage(
            input_tokens=it,
            output_tokens=ot,
            cache_read=cr,
            cache_write=cw,
            cost_usd=cost
          ) => on_usage(it, ot, cr, cw, cost)
        }
      })
      println("")
      match result.status {
        Completed => {
          log("DEV", "\{id} finished successfully")
          result.content
        }
        Failed(err) => {
          log("DEV", "\{id} failed: \{@display.truncate(err, 100)}")
          result.content
        }
        _ => {
          log("DEV", "\{id} ended with status: \{result.status}")
          result.content
        }
      }
    }
    None => {
      log("ERROR", "Backend '\{id}' not found")
      ""
    }
  }
}

///|
/// Gather git context for review
fn gather_review_context() -> String {
  let buf = StringBuilder::new()
  let git_log = exec_sync("git log --oneline -10 2>/dev/null")
  if not(git_log.is_empty()) {
    buf.write_string("### Recent Commits\n```\n")
    buf.write_string(git_log)
    buf.write_string("\n```\n\n")
  }
  let git_diff_stat = exec_sync("git diff --stat HEAD 2>/dev/null")
  if not(git_diff_stat.is_empty()) {
    buf.write_string("### Uncommitted Changes\n```\n")
    buf.write_string(git_diff_stat)
    buf.write_string("\n```\n\n")
  }
  let git_staged = exec_sync("git diff --cached --stat 2>/dev/null")
  if not(git_staged.is_empty()) {
    buf.write_string("### Staged Changes\n```\n")
    buf.write_string(git_staged)
    buf.write_string("\n```\n\n")
  }
  buf.to_string()
}

///|
/// Run review, return outcome
fn run_review(
  dev_id : String?,
  reviewer_id : String,
  backends : Map[String, @agent.BoxedBackend],
  task : String,
  dev_output : String,
  max_cycles : Int,
  agent_sessions : Map[String, String],
  lang : String,
  on_usage? : (Int, Int, Int, Int, Double) -> Unit = fn(_, _, _, _, _) {  },
) -> ReviewOutcome {
  match backends.get(reviewer_id) {
    Some(backend) => {
      let ra = @review.ReviewAgent::new(reviewer_id, lang)
      log("REVIEW", "Gathering git context...")
      let context = gather_review_context()
      let perspectives = ra.perspectives()
      for perspective in perspectives {
        log("REVIEW", "Reviewing: \{perspective}...")
      }
      let review_event_handler : (@types.AgentEvent) -> Unit = fn(event) {
        match event {
          @types.AgentEvent::Info(msg) => log("INFO", "\{reviewer_id}: \{msg}")
          @types.AgentEvent::ToolCall(name=tool_name, input=tool_input) =>
            log(
              "CALL",
              "\{reviewer_id} \{@display.format_tool_call(tool_name, tool_input)}",
            )
          @types.AgentEvent::ToolResult(name=tool_name, output=tool_output) =>
            log(
              "DONE",
              "\{reviewer_id} \{@display.format_tool_result(tool_name, tool_output)}",
            )
          @types.AgentEvent::StatusChange(status) =>
            log("REVIEW", "\{reviewer_id} -> \{status}")
          @types.AgentEvent::SessionId(sid) => {
            agent_sessions[reviewer_id] = sid
            log("REVIEW", "\{reviewer_id} session: \{sid}")
          }
          @types.AgentEvent::Usage(
            input_tokens=it,
            output_tokens=ot,
            cache_read=cr,
            cache_write=cw,
            cost_usd=cost
          ) => on_usage(it, ot, cr, cw, cost)
          _ => ()
        }
      }
      let review_task = @types.Task::new("review-target", task)
      review_task.complete(dev_output)
      let review = ra.review(
        review_task,
        backend,
        context~,
        on_event=review_event_handler,
      )
      log("REVIEW", "\{reviewer_id} finished")
      match review.verdict {
        Approved => {
          println("")
          log("REVIEW", "Verdict: APPROVED (all perspectives)")
          ReviewOutcome::Approved(review.summary)
        }
        NeedsChanges(items) => {
          println("")
          log("REVIEW", "Verdict: NEEDS CHANGES")
          for item in items {
            log("REVIEW", "  - \{item}")
          }
          // Auto-rework loop
          let mut cycle = 1
          let mut current_output = dev_output
          let mut current_items = items
          let mut latest_summary = review.summary
          while cycle < max_cycles {
            cycle += 1
            log("HEARTBEAT", "Auto-rework cycle \{cycle}/\{max_cycles}")
            let feedback = current_items
              .iter()
              .fold(init="", fn(acc, item) { acc + "- " + item + "\n" })
            let rework_task = "\{task}\n\nFeedback from review:\n\{feedback}"
            current_output = run_dev(
              dev_id,
              backends,
              rework_task,
              agent_sessions,
              on_usage~,
            )
            log("REVIEW", "Re-reviewing after rework (3 perspectives)...")
            let fresh_context = gather_review_context()
            let rework_review_task = @types.Task::new("rework-\{cycle}", task)
            rework_review_task.complete(current_output)
            let rework_review = ra.review(
              rework_review_task,
              backend,
              context=fresh_context,
              on_event=review_event_handler,
            )
            match rework_review.verdict {
              Approved => {
                log("REVIEW", "Verdict: APPROVED after \{cycle} cycles")
                return ReviewOutcome::Approved(rework_review.summary)
              }
              NeedsChanges(new_items) => {
                log("REVIEW", "Still needs changes")
                for item in new_items {
                  log("REVIEW", "  - \{item}")
                }
                current_items = new_items
                latest_summary = rework_review.summary
              }
              Rejected(reason) => {
                log("REVIEW", "REJECTED: \{reason}")
                return ReviewOutcome::Rejected(reason)
              }
            }
          }
          log("REVIEW", "Max review cycles reached, continuing anyway")
          ReviewOutcome::Approved(latest_summary)
        }
        Rejected(reason) => {
          println("")
          log("REVIEW", "Verdict: REJECTED - \{reason}")
          ReviewOutcome::Rejected(reason)
        }
      }
    }
    None => {
      log("ERROR", "Reviewer backend '\{reviewer_id}' not found")
      ReviewOutcome::Approved("")
    }
  }
}
