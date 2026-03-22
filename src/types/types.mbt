///|
/// Agent kind - which provider/tool to use
pub(all) enum AgentKind {
  ClaudeCode
  Codex
  Mock
} derive(Eq, Show)

///|
/// Agent role in the orchestration
pub(all) enum AgentRole {
  Dev
  Review
  Planner
  Verifier
} derive(Eq, Show)

///|
/// Runtime status of an agent
pub(all) enum AgentStatus {
  Idle
  Running
  Completed
  Failed(String)
} derive(Eq, Show)

///|
/// Configuration for a single agent
pub(all) struct AgentConfig {
  id : String
  kind : AgentKind
  role : AgentRole
  model : String?
  system_prompt : String?
  working_dir : String
  max_iterations : Int
}

///|
/// Status of a task in the pipeline
pub(all) enum TaskStatus {
  Pending
  InProgress(String) // agent_id
  Done
  Failed(String)
} derive(Eq, Show)

///|
/// A unit of work assigned to an agent
pub(all) struct Task {
  id : String
  description : String
  parent_id : String?
  mut status : TaskStatus
  mut result : String?
  mut review : ReviewResult?
}

///|
/// Review verdict from the review agent
pub(all) enum ReviewVerdict {
  Approved
  NeedsChanges(Array[String])
  Rejected(String)
} derive(Eq, Show)

///|
/// Result of a code review
pub(all) struct ReviewResult {
  reviewer_id : String
  verdict : ReviewVerdict
  summary : String
  file_path : String
} derive(Show)

///|
/// Status of the overall session
pub(all) enum SessionStatus {
  Active
  Completed
  Failed(String)
} derive(Eq, Show)

///|
/// Phase of the orchestrator
pub(all) enum OrchestratorPhase {
  Decomposing
  Assigning
  Executing
  Reviewing
  Iterating
  Finalizing
} derive(Eq, Show)

///|
/// A session represents a single orchestration run
pub(all) struct Session {
  id : String
  user_task : String
  mut status : SessionStatus
  mut current_phase : OrchestratorPhase
  agents : Array[AgentConfig]
  tasks : Array[Task]
}

// --- Callback event types ---

///|
/// Event data for agent output
pub(all) struct AgentOutputEvent {
  agent_id : String
  line : String
}

///|
/// Event data for agent completion
pub(all) struct AgentCompleteEvent {
  agent_id : String
  result : String
}

///|
/// Event data for task start
pub(all) struct TaskStartEvent {
  task_id : String
  description : String
  agent_id : String
}

///|
/// Event data for task completion
pub(all) struct TaskCompleteEvent {
  task_id : String
  status : String
}

///|
/// Event data for task assignment
pub(all) struct TaskAssignEvent {
  task_id : String
  agent_id : String
}

///|
/// Event data for review start
pub(all) struct ReviewStartEvent {
  task_id : String
  reviewer_id : String
}

///|
/// Event data for review completion
pub(all) struct ReviewCompleteEvent {
  task_id : String
  verdict : ReviewVerdict
}

///|
/// Event data for phase change
pub(all) struct PhaseChangeEvent {
  session_id : String
  phase : OrchestratorPhase
}

///|
/// Event data for session completion
pub(all) struct SessionCompleteEvent {
  session_id : String
}

///|
/// Event data for info messages
pub(all) struct InfoEvent {
  message : String
}

///|
/// Unified event type for orchestrator notifications.
/// Adding a new event only requires extending this enum — no changes
/// to OrchestratorCallbacks or its construction sites.
pub(all) enum OrchestratorEvent {
  AgentOutput(AgentOutputEvent)
  AgentComplete(AgentCompleteEvent)
  TaskStart(TaskStartEvent)
  TaskComplete(TaskCompleteEvent)
  TaskAssign(TaskAssignEvent)
  ReviewStart(ReviewStartEvent)
  ReviewComplete(ReviewCompleteEvent)
  PhaseChange(PhaseChangeEvent)
  SessionComplete(SessionCompleteEvent)
  Info(InfoEvent)
}

///|
/// Callbacks for the orchestrator to notify the UI.
/// Uses a single event listener for all notification events,
/// plus a dedicated on_save callback for persistence commands.
pub(all) struct OrchestratorCallbacks {
  on_event : (OrchestratorEvent) -> Unit
  on_save : () -> Unit
}

///|
/// Create noop callbacks for testing
pub fn OrchestratorCallbacks::noop() -> OrchestratorCallbacks {
  { on_event: fn(_e) {  }, on_save: fn() {  } }
}

///|
/// Emit an event through the callbacks
pub fn OrchestratorCallbacks::emit(
  self : OrchestratorCallbacks,
  event : OrchestratorEvent,
) -> Unit {
  (self.on_event)(event)
}

///|
/// Events emitted by an agent during execution
pub(all) enum AgentEvent {
  OutputLine(String)
  Info(String)
  ToolCall(name~ : String, input~ : String)
  ToolResult(name~ : String, output~ : String)
  SubAgentStart(agent_type~ : String, task~ : String)
  SubAgentEnd(agent_type~ : String)
  StatusChange(AgentStatus)
  SessionId(String)
  Usage(
    input_tokens~ : Int,
    output_tokens~ : Int,
    cache_read~ : Int,
    cache_write~ : Int,
    cost_usd~ : Double
  )
}

///|
/// Result of an agent's execution
pub(all) struct AgentResult {
  content : String
  status : AgentStatus
  error : String?
  session_id : String
}

///|
/// Create a failed AgentResult with the given error message
pub fn AgentResult::failed(err : String) -> AgentResult {
  { content: "", status: Failed(err), error: Some(err), session_id: "" }
}

///|
/// Create a failed AgentResult with the given error message and session id
pub fn AgentResult::failed_with_session(
  err : String,
  session_id : String,
) -> AgentResult {
  { content: "", status: Failed(err), error: Some(err), session_id }
}

///|
/// Create a new session
pub fn Session::new(
  id : String,
  user_task : String,
  agents : Array[AgentConfig],
) -> Session {
  {
    id,
    user_task,
    status: Active,
    current_phase: Decomposing,
    agents,
    tasks: [],
  }
}

///|
/// Create a new task
pub fn Task::new(
  id : String,
  description : String,
  parent_id? : String? = None,
) -> Task {
  { id, description, parent_id, status: Pending, result: None, review: None }
}

///|
/// Mark task as in-progress with assigned agent
pub fn Task::assign(self : Task, agent_id : String) -> Unit {
  self.status = InProgress(agent_id)
}

///|
/// Mark task as done with result
pub fn Task::complete(self : Task, result : String) -> Unit {
  self.status = Done
  self.result = Some(result)
}

///|
/// Mark task as failed
pub fn Task::fail(self : Task, error : String) -> Unit {
  self.status = Failed(error)
}

///|
/// Check if task is pending
pub fn Task::is_pending(self : Task) -> Bool {
  self.status == Pending
}

///|
/// Check if task is done
pub fn Task::is_done(self : Task) -> Bool {
  self.status == Done
}

// --- Ralph Loop types ---

///|
/// Status of a milestone in the ralph loop
pub(all) enum MilestoneStatus {
  Pending
  InProgress
  Done
  Failed(String)
} derive(Eq, Show)

///|
/// A milestone containing grouped tasks
pub(all) struct Milestone {
  id : String
  goal : String
  mut status : MilestoneStatus
  mut tasks : Array[RalphTask]
  mut current_wave : Int
  mut summary : String
}

///|
/// A task within the ralph loop
pub(all) struct RalphTask {
  id : String
  description : String
  wave : Int
  mut status : TaskStatus
  mut result : String?
  mut plan_doc : String?
}

///|
/// Get all tasks in a specific wave
pub fn Milestone::get_wave_tasks(
  self : Milestone,
  wave : Int,
) -> Array[RalphTask] {
  let result : Array[RalphTask] = []
  for t in self.tasks {
    if t.wave == wave {
      result.push(t)
    }
  }
  result
}

///|
/// Check if milestone has undone tasks
pub fn Milestone::has_undone_tasks(self : Milestone) -> Bool {
  self.tasks
  .iter()
  .any(fn(t) {
    match t.status {
      Pending | InProgress(_) | Failed(_) => true
      _ => false
    }
  })
}

///|
/// Get the next wave number that has pending tasks
pub fn Milestone::next_wave_number(self : Milestone) -> Int? {
  let mut min_wave : Int? = None
  for t in self.tasks {
    match t.status {
      Pending | InProgress(_) | Failed(_) =>
        match min_wave {
          None => min_wave = Some(t.wave)
          Some(w) => if t.wave < w { min_wave = Some(t.wave) }
        }
      _ => ()
    }
  }
  min_wave
}

///|
/// Phase of the ralph loop state machine
pub(all) enum RalphPhase {
  LoadingMilestones
  Planning(String)
  ExecutingWave(String, Int)
  Verifying(String, Int)
  Reworking(String, Int)
  MilestoneComplete(String)
  AllComplete
} derive(Eq, Show)

///|
/// Verdict from the verifier agent
pub(all) enum VerifierVerdict {
  Approved
  NeedsRework(Array[String])
  MilestoneFailed(String)
} derive(Eq, Show)
