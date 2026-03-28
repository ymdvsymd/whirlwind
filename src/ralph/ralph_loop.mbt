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
  max_in_flight : Int
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
  max_in_flight? : Int = 3,
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
  // Clamp max_in_flight to >= 1 to prevent infinite loops in batch dispatch
  let safe_max_in_flight = if max_in_flight < 1 { 1 } else { max_in_flight }
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
    max_in_flight: safe_max_in_flight,
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
/// Dry-run runs the planner to populate tasks, but skips builder execution and verifier.
fn RalphLoop::run_dry_run(self : RalphLoop) -> Unit {
  for milestone in self.milestone_manager.milestones {
    match milestone.status {
      @types.MilestoneStatus::Done | @types.MilestoneStatus::Failed(_) => ()
      _ => {
        // dry-run でも planner によるタスク分割は実行。中間保存はスキップし末尾の1回に集約
        let planned = self.ensure_milestone_tasks(milestone, persist=false)
        if planned && milestone.status != @types.MilestoneStatus::Done {
          emit_info(
            self,
            "Dry-run: milestone \{milestone.id} planned \{milestone.tasks.length()} tasks; skipping execution and verification",
          )
        } else if not(planned) {
          emit_info(self, "Dry-run: milestone \{milestone.id} planning failed")
        }
      }
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
  // Planner may have marked milestone as already complete
  if milestone.status == Done {
    self.current_phase = MilestoneComplete(milestone.id)
    emit_info(self, "Milestone \{milestone.id} complete")
    return true
  }
  // Execute DAG
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
  let dag_success = self.run_dag(milestone)
  if not(dag_success) {
    match milestone.status {
      Failed(_) => ()
      _ => {
        milestone.status = Failed("DAG execution failed")
        self.save_milestones()
      }
    }
    return false
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
///
/// Delegates all retry and session-management logic to PlannerAgent::plan()
/// and uses the structural PlanResult.status to decide the outcome.
fn RalphLoop::ensure_milestone_tasks(
  self : RalphLoop,
  milestone : @types.Milestone,
  persist? : Bool = true,
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
          let plan_result = planner.plan(
            milestone,
            backend,
            self.milestone_manager.brief,
            self.milestone_manager.milestones,
            self.milestone_manager,
            on_event=fn(e) { handle_event(self, planner.agent_id, e) },
          )
          match plan_result.status {
            Planned => {
              milestone.tasks = plan_result.tasks
              let should_apply_planner_perspectives = match
                self.config.milestones_path {
                Some(_) => false
                None => true
              }
              if should_apply_planner_perspectives {
                match parse_perspectives_line(plan_result.raw_output) {
                  Some(perspectives) => milestone.perspectives = perspectives
                  None => ()
                }
              }
              if persist {
                self.save_milestones()
              }
              true
            }
            AlreadyComplete => {
              emit_info(
                self,
                "Planner reports milestone \{milestone.id} already complete",
              )
              milestone.status = Done
              milestone.summary = "Marked complete by planner (already done)"
              if persist {
                self.save_milestones()
              }
              true
            }
            PlanFailed => {
              emit_info(
                self,
                "Planner failed to produce tasks for \{milestone.id}",
              )
              milestone.status = Failed("No tasks planned")
              if persist {
                self.save_milestones()
              }
              false
            }
          }
        }
        None => {
          emit_info(self, "No backend found for planner")
          milestone.status = Failed("No planner backend")
          if persist {
            self.save_milestones()
          }
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
/// Run all milestone tasks as a DAG using Kahn's layer computation.
///
/// Adds implicit edges (wave compat + scope overlaps), computes layers,
/// then dispatches tasks via a ready-queue respecting max_in_flight.
fn RalphLoop::run_dag(self : RalphLoop, milestone : @types.Milestone) -> Bool {
  self.current_phase = ExecutingDag(milestone.id)
  emit_info(self, "Executing DAG for \{milestone.id}")

  // Add implicit scope-overlap edges into depends_on
  let scope_edges = add_scope_edges(milestone.tasks)
  // apply_scope_edges returns only actually-inserted edges (skipping
  // edges that duplicate pre-existing explicit deps). The revert phase
  // must use inserted_scope_edges — NOT scope_edges — to avoid removing
  // explicit deps that happen to coincide with a scope edge.
  let inserted_scope_edges = apply_scope_edges(milestone.tasks, scope_edges)
  if not(inserted_scope_edges.is_empty()) {
    emit_info(
      self,
      "Added \{inserted_scope_edges.length()} implicit edges from scope overlaps",
    )
    self.save_milestones()
  }

  // Compute layers for cycle detection and logging
  let (layers, cycle_tasks, dag_warnings) = compute_layers(milestone.tasks)
  for w in dag_warnings {
    emit_info(self, "DAG warning: \{w}")
  }
  // Log layer computation results
  if not(layers.is_empty()) {
    let layer_groups : Map[Int, Array[String]] = {}
    for entry in layers {
      let (tid, l) = entry
      match layer_groups.get(l) {
        Some(arr) => arr.push(tid)
        None => layer_groups[l] = [tid]
      }
    }
    let layer_nums : Array[Int] = []
    for entry in layer_groups {
      let (l, _) = entry
      layer_nums.push(l)
    }
    layer_nums.sort()
    let parts : Array[String] = []
    for l in layer_nums {
      let ids = layer_groups.get(l).unwrap()
      let id_list = @util.join_strings(ids, ", ")
      parts.push("layer \{l}: [\{id_list}]")
    }
    let summary = @util.join_strings(parts, ", ")
    emit_info(self, "DAG layers computed: \{summary}")
  }
  if not(cycle_tasks.is_empty()) {
    let cycle_list = @util.join_strings(cycle_tasks, ", ")
    emit_info(
      self,
      "Cycle detected in tasks: \{cycle_list}; falling back to layer 0",
    )
    // Revert only actually-inserted scope edges for cycle tasks
    if not(inserted_scope_edges.is_empty()) {
      let cycle_set : Map[String, Bool] = {}
      for tid in cycle_tasks {
        cycle_set[tid] = true
      }
      // Build lookup: to_id → set of scope-added from_ids to remove
      let scope_deps_to_remove : Map[String, Map[String, Bool]] = {}
      for edge in inserted_scope_edges {
        let (from_id, to_id) = edge
        if cycle_set.contains(to_id) {
          match scope_deps_to_remove.get(to_id) {
            Some(s) => s[from_id] = true
            None => {
              let s : Map[String, Bool] = {}
              s[from_id] = true
              scope_deps_to_remove[to_id] = s
            }
          }
        }
      }
      let mut reverted = 0
      for task in milestone.tasks {
        match scope_deps_to_remove.get(task.id) {
          Some(to_remove) => {
            let clean : Array[String] = task.depends_on
              .iter()
              .filter(fn(dep) { not(to_remove.contains(dep)) })
              .collect()
            let removed = task.depends_on.length() - clean.length()
            if removed > 0 {
              task.depends_on.clear()
              for d in clean {
                task.depends_on.push(d)
              }
              reverted = reverted + removed
            }
          }
          None => ()
        }
      }
      if reverted > 0 {
        emit_info(
          self,
          "Reverted \{reverted} scope edges from cycle tasks to break cycle",
        )
        self.save_milestones()
      }
    }
  }

  // Find builder backend
  let builder_id = find_agent_id(self.config, @types.AgentRole::Builder)
  let builder_backend = match builder_id {
    Some(id) => find_backend(self.backends, id)
    None => None
  }
  match builder_backend {
    None => {
      emit_info(self, "No builder backend found")
      milestone.status = Failed("No builder backend")
      self.save_milestones()
      return false
    }
    Some(backend) => {
      let bid = builder_id.unwrap()
      let builder_system_prompt = build_builder_system_prompt(
        self.milestone_manager.brief,
      )

      // Build task map (id→task) for O(1) lookups and reverse-dep map
      let task_map : Map[String, @types.RalphTask] = {}
      for t in milestone.tasks {
        task_map[t.id] = t
      }
      let deps_remaining : Map[String, Int] = {}
      let reverse_deps : Map[String, Array[String]] = {}
      for t in milestone.tasks {
        reverse_deps[t.id] = []
      }
      for t in milestone.tasks {
        let mut count = 0
        for dep in t.depends_on {
          if dep != t.id && task_map.contains(dep) {
            count = count + 1
            match reverse_deps.get(dep) {
              Some(succs) => succs.push(t.id)
              None => ()
            }
          }
        }
        deps_remaining[t.id] = count
      }

      // Propagate already-done tasks
      let mut already_done = 0
      for t in milestone.tasks {
        if t.status == Done {
          already_done += 1
          match reverse_deps.get(t.id) {
            Some(succs) =>
              for succ in succs {
                match deps_remaining.get(succ) {
                  Some(d) => deps_remaining[succ] = d - 1
                  None => ()
                }
              }
            None => ()
          }
        }
      }
      if already_done > 0 {
        emit_info(self, "Skipping \{already_done} already-done tasks")
      }
      // Seed ready queue with tasks whose deps are all satisfied
      let ready_queue : Array[@types.RalphTask] = []
      for t in milestone.tasks {
        if t.status != Done {
          match deps_remaining.get(t.id) {
            Some(0) => ready_queue.push(t)
            _ => ()
          }
        }
      }

      // Track all results for post-execution file conflict check
      let all_completed : Array[(@types.RalphTask, @types.AgentResult)] = []

      // Batch-parallel dispatch loop.
      // Collects up to max_in_flight ready tasks per batch, executes them
      // via run_parallel (true concurrency for SDK backends), then
      // propagates completions to unlock the next batch.
      let mut batch_start = 0
      while batch_start < ready_queue.length() {
        let batch_end = if batch_start + self.max_in_flight <
          ready_queue.length() {
          batch_start + self.max_in_flight
        } else {
          ready_queue.length()
        }
        let batch_size = batch_end - batch_start

        // Mark all batch tasks as InProgress and log dispatch
        for i in batch_start..<batch_end {
          let task = ready_queue[i]
          task.status = InProgress(bid)
          emit_info(
            self,
            "Dispatching task \{task.id} (batch: \{batch_size}, max: \{self.max_in_flight})",
          )
        }

        // Execute batch
        let mut failed = false
        if batch_size == 1 {
          // Single task: use run_with_retry for server error retry
          let task = ready_queue[batch_start]
          let result = self.run_with_retry(
            backend, task, builder_system_prompt, bid,
          )
          let validated = validate_builder_result(self, task, result)
          match validated.status {
            Completed => {
              task.status = Done
              task.result = Some(validated.content)
              all_completed.push((task, validated))
              emit_info(self, "Task \{task.id} completed")
            }
            _ => {
              let err = validated.error.unwrap_or("unknown error")
              task.status = Failed(err)
              task.result = Some(validated.content)
              emit_info(self, "Task \{task.id} failed: \{err}")
              self.cascade_fail(task.id, task_map, reverse_deps)
              failed = true
            }
          }
        } else {
          // Multiple tasks: use run_parallel for concurrent execution
          let prompts : Array[(String, String)] = []
          for i in batch_start..<batch_end {
            prompts.push((ready_queue[i].description, builder_system_prompt))
          }
          let results = @agent.run_parallel(backend, prompts, fn(e) {
            handle_event(self, bid, e)
          })
          for i in 0..<batch_size {
            let task = ready_queue[batch_start + i]
            let mut result = results[i]
            // Retry server errors individually
            match result.status {
              Failed(err) =>
                if is_server_error(err) {
                  emit_info(
                    self,
                    "Task \{task.id} server error in batch, retrying individually",
                  )
                  result = self.run_with_retry(
                    backend, task, builder_system_prompt, bid,
                  )
                }
              _ => ()
            }
            let validated = validate_builder_result(self, task, result)
            match validated.status {
              Completed => {
                task.status = Done
                task.result = Some(validated.content)
                all_completed.push((task, validated))
                emit_info(self, "Task \{task.id} completed")
              }
              _ => {
                let err = validated.error.unwrap_or("unknown error")
                task.status = Failed(err)
                task.result = Some(validated.content)
                emit_info(self, "Task \{task.id} failed: \{err}")
                self.cascade_fail(task.id, task_map, reverse_deps)
                failed = true
              }
            }
          }
        }

        self.save_milestones()
        if failed {
          emit_info(self, "DAG execution failed: task failure")
          return false
        }

        // Propagate completions: unblock dependents for next batch
        for i in batch_start..<batch_end {
          let task = ready_queue[i]
          if task.status == Done {
            match reverse_deps.get(task.id) {
              Some(succs) =>
                for succ in succs {
                  match deps_remaining.get(succ) {
                    Some(d) => {
                      let new_d = d - 1
                      deps_remaining[succ] = new_d
                      if new_d == 0 {
                        match task_map.get(succ) {
                          Some(t) =>
                            if not(t.status is Done) &&
                              not(t.status is Failed(_)) {
                              ready_queue.push(t)
                            }
                          None => ()
                        }
                      }
                    }
                    None => ()
                  }
                }
              None => ()
            }
          }
        }
        batch_start = batch_end
      }

      // Check for stuck tasks (pending but never became ready — cycle fallback)
      let stuck_count = milestone.tasks
        .iter()
        .filter(fn(t) { not(t.status is Done) && not(t.status is Failed(_)) })
        .count()
      if stuck_count > 0 {
        emit_info(
          self,
          "DAG execution stuck: \{stuck_count} tasks never became ready",
        )
        return false
      }

      // Post-execution file conflict detection (informational)
      if all_completed.length() > 1 {
        let task_files : Array[(@types.RalphTask, Array[String])] = []
        for pair in all_completed {
          let (task, result) = pair
          let changed = extract_changed_files(result.content)
          if not(changed.is_empty()) {
            task_files.push((task, changed))
          }
        }
        let conflicts = detect_file_conflicts(task_files)
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
    }
  }
  true
}

///|
/// Cascade failure to all transitive dependents of a failed task.
///
/// BFS through reverse_deps to find all tasks that transitively depend on
/// the failed task, marking them as Failed("blocked by failed task {id}").
fn RalphLoop::cascade_fail(
  self : RalphLoop,
  failed_id : String,
  task_map : Map[String, @types.RalphTask],
  reverse_deps : Map[String, Array[String]],
) -> Unit {
  let visited : Map[String, Bool] = {}
  visited[failed_id] = true
  let queue : Array[String] = [failed_id]
  let mut qi = 0
  while qi < queue.length() {
    let current = queue[qi]
    qi = qi + 1
    match reverse_deps.get(current) {
      Some(succs) =>
        for succ in succs {
          if not(visited.contains(succ)) {
            visited[succ] = true
            match task_map.get(succ) {
              Some(t) =>
                if not(t.status is Done) && not(t.status is Failed(_)) {
                  t.status = Failed("blocked by failed task \{failed_id}")
                  emit_info(
                    self,
                    "Task \{succ} cascade-failed: blocked by \{failed_id}",
                  )
                  queue.push(succ)
                }
              None => ()
            }
          }
        }
      None => ()
    }
  }
}

///|
/// Apply scope-overlap edges to tasks' depends_on arrays.
/// Returns only the edges that were actually inserted (skipping duplicates
/// of already-existing explicit deps). The caller must use this returned
/// set — not the original scope_edges — for any revert operations.
fn apply_scope_edges(
  tasks : Array[@types.RalphTask],
  edges : Array[(String, String)],
) -> Array[(String, String)] {
  // Build a map for quick lookup of tasks by ID
  let task_map : Map[String, @types.RalphTask] = {}
  for task in tasks {
    task_map[task.id] = task
  }
  let inserted : Array[(String, String)] = []
  // Add edges: (from_id, to_id) means to_id depends on from_id
  for edge in edges {
    let (from_id, to_id) = edge
    match task_map.get(to_id) {
      Some(task) =>
        if not(task.depends_on.contains(from_id)) {
          task.depends_on.push(from_id)
          inserted.push((from_id, to_id))
        }
      None => ()
    }
  }
  inserted
}

///|
/// Check if an error message indicates a server-side error (5xx) that should be retried
pub fn is_server_error(err : String) -> Bool {
  if err.is_empty() {
    return false
  }
  err.contains("Internal server error") ||
  err.contains("Bad gateway") ||
  err.contains("Service unavailable") ||
  err.contains("overloaded") ||
  err.contains("529") ||
  err.contains("500") ||
  err.contains("502") ||
  err.contains("503")
}

///|
/// Check if all NeedsRework items are from infrastructure failures
/// (backend errors, not actual code review verdicts)
pub fn is_infra_failure(items : Array[String]) -> Bool {
  if items.is_empty() {
    return false
  }
  items.iter().all(fn(item) { item.contains("Verification failed:") })
}

///|
/// Run a builder task with retry logic for server-side errors (5xx)
fn RalphLoop::run_with_retry(
  self : RalphLoop,
  backend : @agent.BoxedBackend,
  task : @types.RalphTask,
  system_prompt : String,
  agent_id : String,
) -> @types.AgentResult {
  let max_retries = 3
  let mut attempt = 0
  let mut result = backend.run(task.description, system_prompt, fn(e) {
    handle_event(self, agent_id, e)
  })
  while attempt < max_retries {
    match result.status {
      Failed(err) =>
        if is_server_error(err) {
          attempt = attempt + 1
          emit_info(
            self,
            "Task \{task.id} server error, retry \{attempt}/\{max_retries}: \{err}",
          )
          result = backend.run(task.description, system_prompt, fn(e) {
            handle_event(self, agent_id, e)
          })
        } else {
          break
        }
      _ => break
    }
  }
  result
}

///|
/// Check if two result arrays are equal (same task IDs and content)
fn results_equal(
  a : Array[(String, String)],
  b : Array[(String, String)],
) -> Bool {
  if a.length() != b.length() {
    return false
  }
  for i in 0..<a.length() {
    if a[i].0 != b[i].0 || a[i].1 != b[i].1 {
      return false
    }
  }
  true
}

///|
pub fn resolve_perspectives(
  names : Array[String],
) -> Array[@prompts.Perspective] {
  let resolved : Array[@prompts.Perspective] = []
  for name in names {
    match @prompts.parse_perspective(name) {
      Some(perspective) => resolved.push(perspective)
      None =>
        println("[WARN] Ignoring invalid verification perspective: \{name}")
    }
  }
  if resolved.is_empty() {
    [
      @prompts.Perspective::CodeQuality,
      @prompts.Perspective::Performance,
      @prompts.Perspective::Security,
      @prompts.Perspective::GoalAlignment,
    ]
  } else {
    resolved
  }
}

///|
/// Verify milestone after all waves are complete (all 4 perspectives)
fn RalphLoop::verify_milestone(
  self : RalphLoop,
  milestone : @types.Milestone,
  all_results : Array[(String, String)],
  attempt : Int,
  no_change_count? : Int = 0,
) -> Bool {
  match self.verifier {
    None => true
    Some(verifier) => {
      let verification_wave = 0
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
          if milestone.perspectives.is_empty() {
            emit_info(
              self,
              "No verification perspectives for milestone \{milestone.id}, auto-approving",
            )
            return true
          }
          let perspectives = resolve_perspectives(milestone.perspectives)
          let verdict = verifier.verify(
            milestone,
            verification_wave,
            all_results,
            backend,
            "",
            perspectives~,
            on_event=fn(e) { handle_event(self, verifier.agent_id, e) },
          )
          match verdict {
            Approved => {
              emit_info(self, "Milestone \{milestone.id} verification approved")
              true
            }
            NeedsRework(items) => {
              // Circuit breaker: all perspectives failed with infra errors
              if is_infra_failure(items) {
                let reason = "Infrastructure failure detected across all verification perspectives: " +
                  @util.join_strings(items, " | ")
                emit_info(
                  self,
                  "Circuit breaker: infrastructure failure detected for milestone \{milestone.id}",
                )
                milestone.status = Failed(reason)
                self.save_milestones()
                return false
              }
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
              // Circuit breaker: builder produced no effective changes
              let new_no_change = if results_equal(all_results, reworked) {
                no_change_count + 1
              } else {
                0
              }
              if new_no_change >= 2 {
                let reason = "Circuit breaker: builder produced no changes for 2 consecutive rework attempts"
                emit_info(self, reason)
                milestone.status = Failed(reason)
                self.save_milestones()
                return false
              }
              self.verify_milestone(
                milestone,
                reworked,
                attempt + 1,
                no_change_count=new_no_change,
              )
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
      // Clear session_id so rework starts a new session instead of resuming
      // the previous one with accumulated context (whirlwind-z9r)
      backend.set_session_id("")
      let rework_system_prompt = build_rework_system_prompt(
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
            builder_tasks.push((rework_prompt, rework_system_prompt))
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
    _ => ()
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

///| Detect file conflicts between parallel tasks in a wave.

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
