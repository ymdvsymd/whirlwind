///|
/// Planner agent for the ralph loop
pub struct PlannerAgent {
  agent_id : String
  lang : String
}

///|
/// Create a new planner agent
pub fn PlannerAgent::new(
  agent_id? : String = "planner",
  lang? : String = "en",
) -> PlannerAgent {
  { agent_id, lang }
}

///|
/// Build the planning prompt for a milestone
pub fn PlannerAgent::build_plan_prompt(
  self : PlannerAgent,
  milestone : @types.Milestone,
) -> String {
  let lang_instruction = if self.lang == "ja" {
    "Respond in Japanese."
  } else {
    "Respond in English."
  }
  let prompt = StringBuilder::new()
  prompt.write_string("You are a Planner agent. ")
  prompt.write_string(lang_instruction)
  prompt.write_string("\n\n")
  prompt.write_string("## Milestone\n")
  prompt.write_string("ID: ")
  prompt.write_string(milestone.id)
  prompt.write_string("\nGoal: ")
  prompt.write_string(milestone.goal)
  prompt.write_string("\n\n")
  prompt.write_string(
    "## Instructions\n" +
    "Break down this milestone into concrete tasks grouped by waves.\n" +
    "Tasks in the same wave can be executed independently.\n" +
    "Tasks in later waves depend on earlier waves.\n\n" +
    "## Output Format\n" +
    "WAVE 0:\n1. First task description\nSCOPE: src/foo.mbt, test/foo_test.mbt\n2. Second task description\nSCOPE: src/bar.mbt\n\n" +
    "WAVE 1:\n1. Task that depends on wave 0\nSCOPE: src/baz.mbt, src/qux.mbt\n\n" +
    "Add a SCOPE line (comma-separated file paths expected to be modified) under each task. Omit SCOPE if unknown.\n",
  )
  prompt.to_string()
}

///|
/// Parse the planner output into tasks
pub fn PlannerAgent::parse_plan(
  _self : PlannerAgent,
  output : String,
  milestone_id : String,
  mgr : MilestoneManager,
) -> Array[@types.RalphTask] {
  mgr.parse_planner_output(output, milestone_id)
}

///|
/// Run the planner agent to generate tasks for a milestone
pub fn PlannerAgent::plan(
  self : PlannerAgent,
  milestone : @types.Milestone,
  backend : @agent.BoxedBackend,
  brief : String,
  milestones : Array[@types.Milestone],
  mgr : MilestoneManager,
  on_event? : (@types.AgentEvent) -> Unit = fn(_e) {  },
) -> Array[@types.RalphTask] {
  let prompt = self.build_plan_prompt(milestone)
  let system_prompt = build_planner_system_prompt(brief, milestones)
  let result = backend.run(prompt, system_prompt, on_event)
  match result.status {
    Completed => self.parse_plan(result.content, milestone.id, mgr)
    _ => []
  }
}
