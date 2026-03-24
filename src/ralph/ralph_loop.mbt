///|
/// Main ralph loop state machine
pub struct RalphLoop {
  config : @config.ProjectConfig
  milestone_manager : MilestoneManager
  planner : PlannerAgent?
  verifier : VerifierAgent?
  backends : Map[String, @agent.BoxedBackend]
  callbacks : @types.OrchestratorCallbacks
  mut current_phase : @types.RalphPhase
  dry_run : Bool
  max_rework_attempts : Int
  file_checker : (String) -> Bool
}

///|
/// Create a new ralph loop
pub fn RalphLoop::new(
  config : @config.ProjectConfig,
  milestone_manager : MilestoneManager,
  backends : Map[String, @agent.BoxedBackend],
  callbacks : @types.OrchestratorCallbacks,
  dry_run? : Bool = false,
  lang? : String = "en",
  file_checker? : (String) -> Bool = path_exists,
) -> RalphLoop {
  let planner_id = find_agent_id(config, @types.AgentRole::Planner)
  let verifier_id = find_agent_id(config, @types.AgentRole::Verifier)
  let planner : PlannerAgent? = match planner_id {
    Some(id) => Some(PlannerAgent::new(agent_id=id, lang~))
    None => None
  }
  let verifier : VerifierAgent? = match verifier_id {
    Some(id) => Some(VerifierAgent::new(agent_id=id, lang~))
    None => None
  }
  {
    config,
    milestone_manager,
    planner,
    verifier,
    backends,
    callbacks,
    current_phase: @types.RalphPhase::LoadingMilestones,
    dry_run,
    max_rework_attempts: config.max_rework_attempts,
    file_checker,
  }
}

///|
/// Run the ralph loop to completion
pub fn RalphLoop::run(self : RalphLoop) -> Unit {
  self.current_phase = LoadingMilestones
  emit_info(self, "Ralph loop started")
  if self.dry_run {
    self.run_dry_run()
    return
  }
  // Reset failed milestones to pending so resume retries them
  for m in self.milestone_manager.milestones {
    match m.status {
      Failed(_) => {
        emit_info(
          self,
          "Resetting failed milestone \{m.id} to pending for retry",
        )
        m.tasks = []
        m.status = Pending
      }
      _ => ()
    }
  }
  self.save_milestones()
  while true {
    // Get next pending milestone
    let milestone = self.milestone_manager.next_pending_milestone()
    match milestone {
      None => {
        self.current_phase = AllComplete
        emit_info(self, "All milestones complete")
        return
      }
      Some(m) => {
        let success = self.run_milestone(m)
        if not(success) {
          emit_info(self, "Milestone \{m.id} failed")
        }
      }
    }
  }
}

///|
/// Dry-run validates milestone loading/output without spawning planner, builder, or verifier.
fn RalphLoop::run_dry_run(self : RalphLoop) -> Unit {
  for milestone in self.milestone_manager.milestones {
    match milestone.status {
      @types.MilestoneStatus::Done | @types.MilestoneStatus::Failed(_) => ()
      _ =>
        emit_info(
          self,
          "Dry-run: validated milestone \{milestone.id}; skipping planner, execution, and verification",
        )
    }
  }
  self.save_milestones()
  self.current_phase = AllComplete
  emit_info(self, "Dry-run complete")
}

///|
/// Run a single milestone through planning, execution, and verification
fn RalphLoop::run_milestone(
  self : RalphLoop,
  milestone : @types.Milestone,
) -> Bool {
  let planned = self.ensure_milestone_tasks(milestone)
  if not(planned) {
    return false
  }
  // Execute waves
  let completed_tasks = milestone.tasks
    .iter()
    .filter(fn(task) { task.status == Done })
    .count()
  if completed_tasks > 0 {
    emit_info(
      self,
      "Resuming milestone \{milestone.id}: \{completed_tasks} of \{milestone.tasks.length()} tasks already done",
    )
  }
  milestone.status = @types.MilestoneStatus::InProgress
  self.save_milestones()
  while milestone.has_undone_tasks() {
    let wave = milestone.next_wave_number()
    match wave {
      None => break
      Some(wave_num) => {
        let success = self.run_wave(milestone, wave_num)
        if not(success) {
          milestone.status = Failed("Wave \{wave_num} failed")
          self.save_milestones()
          return false
        }
      }
    }
  }
  let all_results = collect_all_task_results(milestone)
  let verified = self.verify_milestone(milestone, all_results, 0)
  if not(verified) {
    match milestone.status {
      Failed(_) => ()
      _ => {
        milestone.status = Failed("Milestone verification failed")
        self.save_milestones()
      }
    }
    return false
  }
  milestone.summary = generate_milestone_summary(milestone)
  milestone.status = Done
  self.current_phase = MilestoneComplete(milestone.id)
  self.save_milestones()
  emit_info(self, "Milestone \{milestone.id} complete")
  true
}

///|
/// Ensure milestone has planner-generated tasks before execution.
fn RalphLoop::ensure_milestone_tasks(
  self : RalphLoop,
  milestone : @types.Milestone,
) -> Bool {
  if not(milestone.tasks.is_empty()) {
    return true
  }
  match self.planner {
    Some(planner) => {
      self.current_phase = Planning(milestone.id)
      emit_info(self, "Planning milestone: \{milestone.id}")
      let planner_backend = find_backend(self.backends, planner.agent_id)
      match planner_backend {
        Some(backend) => {
          let tasks = planner.plan(
            milestone,
            backend,
            self.milestone_manager.brief,
            self.milestone_manager.milestones,
            self.milestone_manager,
            on_event=fn(e) { handle_event(self, planner.agent_id, e) },
          )
          if tasks.is_empty() {
            // Retry once with a fresh session (session exhaustion recovery)
            emit_info(
              self,
              "Planner produced no tasks for \{milestone.id}, retrying with new session",
            )
            backend.set_session_id("")
            let retry_tasks = planner.plan(
              milestone,
              backend,
              self.milestone_manager.brief,
              self.milestone_manager.milestones,
              self.milestone_manager,
              on_event=fn(e) { handle_event(self, planner.agent_id, e) },
            )
            if retry_tasks.is_empty() {
              emit_info(
                self,
                "Planner retry also produced no tasks for \{milestone.id}",
              )
              milestone.status = Failed("No tasks planned")
              self.save_milestones()
              return false
            }
            milestone.tasks = retry_tasks
            self.save_milestones()
            return true
          }
          milestone.tasks = tasks
          self.save_milestones()
          true
        }
        None => {
          emit_info(self, "No backend found for planner")
          milestone.status = Failed("No planner backend")
          self.save_milestones()
          false
        }
      }
    }
    None => {
      emit_info(self, "No planner configured, skipping planning")
      true
    }
  }
}

///|
/// Run a single wave: execute tasks, then verify
fn RalphLoop::run_wave(
  self : RalphLoop,
  milestone : @types.Milestone,
  wave : Int,
) -> Bool {
  self.current_phase = ExecutingWave(milestone.id, wave)
  emit_info(self, "Executing wave \{wave} of \{milestone.id}")
  let moved = self.resolve_scope_conflicts(milestone, wave)
  if moved > 0 {
    emit_info(
      self,
      "Pre-wave scope check: moved \{moved} tasks from wave \{wave}",
    )
    self.save_milestones()
  }
  let tasks = milestone.get_wave_tasks(wave)
  let pending_tasks : Array[@types.RalphTask] = []
  let mut done_count = 0
  for task in tasks {
    match task.status {
      Done => done_count += 1
      _ => pending_tasks.push(task)
    }
  }
  if done_count > 0 {
    emit_info(self, "Wave \{wave}: skipping \{done_count} already-done tasks")
  }
  if pending_tasks.is_empty() {
    emit_info(self, "Wave \{wave}: all tasks already done, skipping")
    return true
  }
  // Find builder backend (first Builder agent)
  let builder_id = find_agent_id(self.config, @types.AgentRole::Builder)
  let builder_backend = match builder_id {
    Some(id) => find_backend(self.backends, id)
    None => None
  }
  match builder_backend {
    None => {
      emit_info(self, "No builder backend found")
      return false
    }
    Some(backend) => {
      let bid = builder_id.unwrap()
      let builder_system_prompt = build_builder_system_prompt(
        self.milestone_manager.brief,
      )
      let builder_tasks : Array[(String, String)] = []
      for task in pending_tasks {
        task.status = InProgress(bid)
        emit_info(self, "Running task \{task.id}: \{task.description}")
        builder_tasks.push((task.description, builder_system_prompt))
      }
      let results = run_builder_tasks_serially(
        self,
        backend,
        bid,
        pending_tasks,
        builder_tasks,
        "wave \{wave} of \{milestone.id}",
      )
      for i in 0..<pending_tasks.length() {
        let task = pending_tasks[i]
        let result = results[i]
        match result.status {
          Completed => {
            task.status = Done
            task.result = Some(result.content)
            emit_info(self, "Task \{task.id} completed")
          }
          _ => {
            let err = result.error.unwrap_or("unknown error")
            task.status = Failed(err)
            task.result = Some(result.content)
            emit_info(self, "Task \{task.id} failed: \{err}")
          }
        }
      }
      if pending_tasks.iter().any(fn(task) { task.status is Failed(_) }) {
        emit_info(
          self,
          "Wave \{wave} failed because one or more builder tasks failed",
        )
        self.save_milestones()
        return false
      }
      // Detect file conflicts between parallel builders in this wave
      if pending_tasks.length() > 1 {
        let task_files : Array[(@types.RalphTask, Array[String])] = []
        for i in 0..<pending_tasks.length() {
          let task = pending_tasks[i]
          let result = results[i]
          let changed = extract_changed_files(result.content)
          if not(changed.is_empty()) {
            task_files.push((task, changed))
          }
        }
        let conflicts = detect_wave_file_conflicts(task_files)
        if not(conflicts.is_empty()) {
          for conflict in conflicts {
            let (file, task_ids) = conflict
            let task_list = @util.join_strings(task_ids, ", ")
            emit_info(
              self,
              "File conflict detected: \{file} was modified by tasks \{task_list}",
            )
          }
        }
      }
      self.save_milestones() // persist after wave task execution
    }
  }
  true
}

///|
/// Verify milestone after all waves are complete (all 4 perspectives)
fn RalphLoop::verify_milestone(
  self : RalphLoop,
  milestone : @types.Milestone,
  all_results : Array[(String, String)],
  attempt : Int,
) -> Bool {
  match self.verifier {
    None => true
    Some(verifier) => {
      let verification_wave = last_wave_number(milestone)
      self.current_phase = Verifying(milestone.id, verification_wave)
      emit_info(
        self,
        "Verifying milestone \{milestone.id} (attempt \{attempt + 1})",
      )
      let verifier_backend = find_backend(self.backends, verifier.agent_id)
      match verifier_backend {
        None => {
          emit_info(self, "No verifier backend found, auto-approving")
          true
        }
        Some(backend) => {
          let verdict = verifier.verify(
            milestone,
            verification_wave,
            all_results,
            backend,
            "",
            on_event=fn(e) { handle_event(self, verifier.agent_id, e) },
          )
          match verdict {
            Approved => {
              emit_info(self, "Milestone \{milestone.id} verification approved")
              true
            }
            NeedsRework(items) => {
              if attempt >= self.max_rework_attempts {
                let reason = "Max rework attempts reached with unresolved issues: " +
                  @util.join_strings(items, " | ")
                emit_info(
                  self,
                  "Max rework attempts reached for milestone verification; failing milestone: \{reason}",
                )
                milestone.status = Failed(reason)
                self.save_milestones()
                return false
              }
              self.current_phase = Reworking(milestone.id, verification_wave)
              emit_info(
                self,
                "Milestone rework needed for \{milestone.id}: \{items.length()} issues",
              )
              let reworked = self.rework_milestone_tasks(milestone, items)
              self.verify_milestone(milestone, reworked, attempt + 1)
            }
            MilestoneFailed(reason) => {
              emit_info(self, "Milestone failed: \{reason}")
              milestone.status = Failed(reason)
              self.save_milestones()
              false
            }
          }
        }
      }
    }
  }
}

///|
fn strip_task_feedback_prefix(item : String, task_id : String) -> String {
  let colon_prefix = task_id + ":"
  if item.has_prefix(colon_prefix) {
    return item
      .view(start_offset=colon_prefix.length())
      .to_string()
      .trim()
      .to_string()
  }
  let space_prefix = task_id + " "
  if item.has_prefix(space_prefix) {
    return item
      .view(start_offset=space_prefix.length())
      .to_string()
      .trim()
      .to_string()
  }
  item
}

///|
/// Re-execute milestone tasks that need rework
fn RalphLoop::rework_milestone_tasks(
  self : RalphLoop,
  milestone : @types.Milestone,
  feedback : Array[String],
) -> Array[(String, String)] {
  let tasks = milestone.tasks
  self.rework_task_list(tasks, feedback)
  collect_all_task_results(milestone)
}

///|
fn RalphLoop::rework_task_list(
  self : RalphLoop,
  tasks : Array[@types.RalphTask],
  feedback : Array[String],
) -> Unit {
  let mut matched_any = false
  for item in feedback {
    for task in tasks {
      if item.has_prefix(task.id + ":") || item.has_prefix(task.id + " ") {
        task.status = Pending
        matched_any = true
      }
    }
  }
  if not(matched_any) && not(feedback.is_empty()) {
    for task in tasks {
      match task.status {
        Done => task.status = Pending
        _ => ()
      }
    }
  }

  let builder_id = find_agent_id(self.config, @types.AgentRole::Builder)
  let builder_backend = match builder_id {
    Some(id) => find_backend(self.backends, id)
    None => None
  }
  match builder_backend {
    None => ()
    Some(backend) => {
      let bid = builder_id.unwrap()
      let builder_system_prompt = build_builder_system_prompt(
        self.milestone_manager.brief,
      )
      let rework_tasks : Array[@types.RalphTask] = []
      let builder_tasks : Array[(String, String)] = []
      for task in tasks {
        match task.status {
          Failed(_) | Pending => {
            task.status = InProgress(bid)
            let task_feedback = StringBuilder::new()
            for item in feedback {
              if item.has_prefix(task.id + ":") ||
                item.has_prefix(task.id + " ") {
                let task_feedback_item = strip_task_feedback_prefix(
                  item,
                  task.id,
                )
                task_feedback.write_string("- ")
                task_feedback.write_string(task_feedback_item)
                task_feedback.write_string("\n")
              }
            }
            let task_feedback_str = task_feedback.to_string()
            let feedback_str = if task_feedback_str.is_empty() {
              feedback
              .iter()
              .fold(init="", fn(acc, item) { acc + "- " + item + "\n" })
            } else {
              task_feedback_str
            }
            let rework_prompt = task.description +
              "\n\nFeedback from verifier:\n" +
              feedback_str
            emit_info(self, "Reworking task \{task.id}")
            rework_tasks.push(task)
            builder_tasks.push((rework_prompt, builder_system_prompt))
          }
          _ => ()
        }
      }
      let results = run_builder_tasks_serially(
        self, backend, bid, rework_tasks, builder_tasks, "task rework",
      )
      for i in 0..<rework_tasks.length() {
        let task = rework_tasks[i]
        let result = results[i]
        match result.status {
          Completed => {
            task.status = Done
            task.result = Some(result.content)
          }
          _ => {
            let err = result.error.unwrap_or("rework failed")
            task.status = Failed(err)
            task.result = Some(result.content)
          }
        }
      }
      self.save_milestones() // persist after rework execution
    }
  }
}

///|
/// Persist milestones state to disk via callback
fn RalphLoop::save_milestones(self : RalphLoop) -> Unit {
  (self.callbacks.on_save)()
}

// --- Internal helpers ---

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
    "Output your plan as plain text only using the WAVE format specified in the prompt.\n\n",
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
/// Build system prompt for Builder/Rework: brief only
fn build_builder_system_prompt(brief : String) -> String {
  if brief.is_empty() {
    return ""
  }
  "## Brief\n" + brief + "\n"
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
fn last_wave_number(milestone : @types.Milestone) -> Int {
  let mut wave = 0
  for task in milestone.tasks {
    if task.wave > wave {
      wave = task.wave
    }
  }
  wave
}

///|
fn handle_event(
  rl : RalphLoop,
  agent_id : String,
  event : @types.AgentEvent,
) -> Unit {
  match event {
    OutputLine(line) => rl.callbacks.emit(AgentOutput({ agent_id, line }))
    Info(msg) => rl.callbacks.emit(Info({ message: msg }))
    _ => ()
  }
}

///|
fn emit_info(rl : RalphLoop, msg : String) -> Unit {
  rl.callbacks.emit(Info({ message: msg }))
}

///|
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

///| Detect file conflicts between parallel tasks in a wave.

///| Takes an array of (task, changed_files) pairs and returns an array of

///|
/// (file_path, conflicting_task_ids) for files edited by multiple tasks.
pub fn detect_wave_file_conflicts(
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

///| Detect scope overlaps between planned tasks in a wave.

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
        Some(owners) => owners.push(task.id)
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

///| Resolve planned scope overlaps by moving conflicting tasks to a new wave.

///|

///| For each overlap group, the first task remains in the current wave and the

///|
/// remaining tasks are moved to the next wave after the current last wave.
pub fn RalphLoop::resolve_scope_conflicts(
  self : RalphLoop,
  milestone : @types.Milestone,
  wave : Int,
) -> Int {
  let tasks = milestone.get_wave_tasks(wave)
  let overlaps = detect_scope_overlaps(tasks)
  if overlaps.is_empty() {
    return 0
  }

  let target_wave = last_wave_number(milestone) + 1
  let moved_task_ids : Array[String] = []
  let seen_task_ids : Map[String, Bool] = {}
  for overlap in overlaps {
    let (_, task_ids) = overlap
    for i in 1..<task_ids.length() {
      let task_id = task_ids[i]
      if not(seen_task_ids.contains(task_id)) {
        seen_task_ids[task_id] = true
        moved_task_ids.push(task_id)
      }
    }
  }

  for task in milestone.tasks {
    if seen_task_ids.contains(task.id) {
      task.wave = target_wave
      emit_info(
        self,
        "Moved task \{task.id} to wave \{target_wave} due to scope overlap",
      )
    }
  }
  moved_task_ids.length()
}
