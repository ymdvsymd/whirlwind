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
/// Persist milestones state to disk via callback
fn RalphLoop::save_milestones(self : RalphLoop) -> Unit {
  (self.callbacks.on_save)()
}
