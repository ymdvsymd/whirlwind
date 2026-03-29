///|
/// Build system prompt for Planner: brief + completed milestone summaries
fn build_planner_system_prompt(
  brief : String,
  milestones : Array[@types.Milestone],
) -> String {
  let buf = StringBuilder::new()
  buf.write_string(
    "You are a planning agent that breaks down milestones into executable tasks.\n" +
    "IMPORTANT: Do NOT write to or modify files under .claude/plans/. " +
    "Output your plan as plain text only using the TASKS/DEPENDS_ON format specified in the prompt.\n\n",
  )
  if not(brief.is_empty()) {
    buf.write_string("## Brief\n")
    buf.write_string(brief)
    buf.write_string("\n\n")
  }
  let mut has_completed = false
  for m in milestones {
    if m.status == @types.MilestoneStatus::Done && not(m.summary.is_empty()) {
      if not(has_completed) {
        buf.write_string("## Completed Milestones\n")
        has_completed = true
      }
      buf.write_string("- ")
      buf.write_string(m.id)
      buf.write_string(": ")
      buf.write_string(m.summary)
      buf.write_string("\n")
    }
  }
  if has_completed {
    buf.write_string("\n")
  }
  buf.to_string()
}

///|
/// Build system prompt for Builder/Rework: brief + compile error policy
fn build_builder_system_prompt(brief : String) -> String {
  let buf = StringBuilder::new()
  if not(brief.is_empty()) {
    buf.write_string("## Brief\n")
    buf.write_string(brief)
    buf.write_string("\n\n")
  }
  buf.write_string(
    "## Compile Error Policy\n" +
    "If the build has compile errors, you MUST fix them — even if they appear to be pre-existing.\n" +
    "Errors introduced by prior tasks in the same run are your responsibility, not pre-existing issues.\n" +
    "Always run the build command, and if it fails, fix every compile error before reporting completion.\n",
  )
  buf.to_string()
}

///|
/// Build system prompt for rework tasks: brief + scope limitation instructions.
/// Rework builders must make minimal, targeted fixes — not broad refactors.
fn build_rework_system_prompt(brief : String) -> String {
  let base = build_builder_system_prompt(brief)
  let scope_rules = "## Rework scope constraints\n" +
    "You are fixing specific issues identified by the verifier. Keep changes minimal and focused.\n" +
    "- Only address the feedback items listed — do not fix unrelated issues.\n" +
    "- Do not restructure, rename, or reorganize existing files or code beyond what is needed for the fix.\n" +
    "- Do not add new features, refactor adjacent code, or change public APIs unless explicitly required by the feedback.\n" +
    "- Limit file changes to the smallest set necessary. Aim to modify no more than 5 files per task.\n"
  base + scope_rules
}

///|
/// Generate milestone summary from completed task descriptions
fn generate_milestone_summary(milestone : @types.Milestone) -> String {
  let parts : Array[String] = []
  for task in milestone.tasks {
    if task.status == @types.TaskStatus::Done {
      parts.push(task.description)
    }
  }
  if parts.is_empty() {
    return milestone.goal
  }
  @util.join_strings(parts, "; ")
}

///|
fn find_agent_id(
  config : @config.ProjectConfig,
  role : @types.AgentRole,
) -> String? {
  for agent in config.agents {
    if agent.role == role {
      return Some(agent.id)
    }
  }
  None
}

///|
fn find_backend(
  backends : Map[String, @agent.BoxedBackend],
  id : String,
) -> @agent.BoxedBackend? {
  backends.get(id)
}

///|
fn collect_all_task_results(
  milestone : @types.Milestone,
) -> Array[(String, String)] {
  let results : Array[(String, String)] = []
  for task in milestone.tasks {
    let content = match task.result {
      Some(r) => r
      None => "(no output)"
    }
    results.push((task.id, content))
  }
  results
}

///|
fn handle_event(
  rl : RalphLoop,
  agent_id : String,
  event : @types.AgentEvent,
) -> Unit {
  match event {
    OutputLine(line) => rl.callbacks.emit(AgentOutput({ agent_id, line }))
    Info(msg) => rl.callbacks.emit(Info({ agent_id, message: msg }))
    Usage(input_tokens~, output_tokens~, cache_read~, cache_write~, cost_usd~) => {
      let msg = "[Usage] agent=\{agent_id} input=\{input_tokens} output=\{output_tokens} cache_read=\{cache_read} cache_write=\{cache_write} cost_usd=\{cost_usd}"
      rl.callbacks.emit(Info({ agent_id, message: msg }))
    }
    SessionId(sid) => {
      let already_seen = match rl.seen_sessions.get(agent_id) {
        Some(prev) => prev == sid
        None => false
      }
      if not(already_seen) {
        rl.seen_sessions[agent_id] = sid
        let msg = "[Session] agent=\{agent_id} session_id=\{sid}"
        rl.callbacks.emit(Info({ agent_id, message: msg }))
      }
    }
    ToolCall(..) => ()
    ToolResult(..) => ()
    SubAgentStart(..) => ()
    SubAgentEnd(..) => ()
    StatusChange(_) => ()
  }
}

///|
fn emit_info(rl : RalphLoop, msg : String) -> Unit {
  rl.callbacks.emit(Info({ agent_id: "", message: msg }))
}

///|
/// Run builder tasks serially to avoid shared-worktree overwrites.
fn run_builder_tasks_serially(
  rl : RalphLoop,
  backend : @agent.BoxedBackend,
  builder_id : String,
  tasks : Array[@types.RalphTask],
  prompts : Array[(String, String)],
  context : String,
) -> Array[@types.AgentResult] {
  let results : Array[@types.AgentResult] = []
  if prompts.length() > 1 {
    emit_info(
      rl,
      "Serializing \{prompts.length()} builder tasks for \{context} to avoid shared-worktree overwrites",
    )
  }
  for i in 0..<prompts.length() {
    let (prompt, system_prompt) = prompts[i]
    let result = backend.run(prompt, system_prompt, fn(e) {
      handle_event(rl, builder_id, e)
    })
    results.push(validate_builder_result(rl, tasks[i], result))
  }
  results
}

///|
fn validate_builder_result(
  rl : RalphLoop,
  task : @types.RalphTask,
  result : @types.AgentResult,
) -> @types.AgentResult {
  match result.status {
    Completed => {
      let changed_files = extract_changed_files(result.content)
      if changed_files.is_empty() {
        return result
      }
      let missing_files = find_missing_paths(changed_files, rl.file_checker)
      if missing_files.is_empty() {
        return result
      }
      let err = "post-run file verification failed for \{task.id}; missing files: " +
        @util.join_strings(missing_files, ", ")
      emit_info(rl, err)
      {
        content: result.content,
        status: Failed(err),
        error: Some(err),
        session_id: result.session_id,
      }
    }
    _ => result
  }
}

///|
fn find_missing_paths(
  paths : Array[String],
  checker : (String) -> Bool,
) -> Array[String] {
  let missing : Array[String] = []
  for path in paths {
    if not(checker(path)) {
      missing.push(path)
    }
  }
  missing
}

///|
fn path_exists(path : String) -> Bool {
  js_path_exists(path) == "true"
}

///|
extern "js" fn js_path_exists(path : String) -> String =
  #|(path) => {
  #|  try {
  #|    const fs = require('fs');
  #|    return fs.existsSync(path) ? 'true' : 'false';
  #|  } catch (_err) {
  #|    return 'false';
  #|  }
  #|}

///| Extract changed file paths from builder output.

///| Looks for a line matching "FILES_CHANGED: file1, file2, ..." and returns

///|
/// the list of trimmed file names.
pub fn extract_changed_files(output : String) -> Array[String] {
  let files : Array[String] = []
  let prefix = "FILES_CHANGED:"
  let lines = @util.split_lines(output)
  for line in lines {
    let trimmed = @util.trim(line)
    if trimmed.has_prefix(prefix) {
      let rest = @util.trim(
        String::from_array(trimmed.to_array()[prefix.length():]),
      )
      if not(rest.is_empty()) {
        for part_view in rest.split(",") {
          let part = @util.trim(part_view.to_string())
          if not(part.is_empty()) {
            files.push(part)
          }
        }
      }
    }
  }
  files
}

///| Detect file conflicts between parallel tasks in a layer.

///| Takes an array of (task, changed_files) pairs and returns an array of

///|
/// (file_path, conflicting_task_ids) for files edited by multiple tasks.
pub fn detect_file_conflicts(
  task_files : Array[(@types.RalphTask, Array[String])],
) -> Array[(String, Array[String])] {
  // Build a map: file_path -> [task_id, ...]
  let file_owners : Map[String, Array[String]] = {}
  for pair in task_files {
    let (task, files) = pair
    for file in files {
      match file_owners.get(file) {
        Some(owners) => owners.push(task.id)
        None => file_owners[file] = [task.id]
      }
    }
  }
  // Collect files with more than one owner
  let conflicts : Array[(String, Array[String])] = []
  for entry in file_owners {
    let (file, owners) = entry
    if owners.length() > 1 {
      conflicts.push((file, owners))
    }
  }
  conflicts
}

///| Detect scope overlaps between planned tasks in a layer.

///|

///| Takes an array of tasks and returns an array of

///|
/// (file_path, conflicting_task_ids) for scoped files claimed by multiple tasks.
pub fn detect_scope_overlaps(
  tasks : Array[@types.RalphTask],
) -> Array[(String, Array[String])] {
  let file_owners : Map[String, Array[String]] = {}
  for task in tasks {
    if task.scope.is_empty() {
      continue
    }
    for file in task.scope {
      match file_owners.get(file) {
        Some(owners) =>
          if not(owners.contains(task.id)) {
            owners.push(task.id)
          }
        None => file_owners[file] = [task.id]
      }
    }
  }
  let overlaps : Array[(String, Array[String])] = []
  for entry in file_owners {
    let (file, owners) = entry
    if owners.length() > 1 {
      overlaps.push((file, owners))
    }
  }
  overlaps
}
