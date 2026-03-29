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
) -> (Array[@prompts.Perspective], Array[String]) {
  let resolved : Array[@prompts.Perspective] = []
  let warnings : Array[String] = []
  for name in names {
    match @prompts.parse_perspective(name) {
      Some(perspective) => resolved.push(perspective)
      None =>
        warnings.push(
          "[WARN] Ignoring invalid verification perspective: \{name}",
        )
    }
  }
  let perspectives = if resolved.is_empty() {
    [
      @prompts.Perspective::CodeQuality,
      @prompts.Perspective::Performance,
      @prompts.Perspective::Security,
      @prompts.Perspective::GoalAlignment,
    ]
  } else {
    resolved
  }
  (perspectives, warnings)
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
      self.current_phase = Verifying(milestone.id, 0)
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
          let (perspectives, warnings) = resolve_perspectives(
            milestone.perspectives,
          )
          for w in warnings {
            emit_info(self, w)
          }
          let verdict = verifier.verify(
            milestone,
            all_results,
            backend,
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
              self.current_phase = Reworking(milestone.id, 0)
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
