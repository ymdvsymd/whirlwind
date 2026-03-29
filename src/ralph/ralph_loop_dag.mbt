///|
/// Run all milestone tasks as a DAG using Kahn's layer computation.
///
/// Adds implicit edges (scope overlaps), computes layers,
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
