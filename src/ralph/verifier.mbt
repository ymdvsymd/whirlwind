///|
/// Verifier agent for the ralph loop
pub struct VerifierAgent {
  agent_id : String
  lang : String
}

///|
/// Create a new verifier agent
pub fn VerifierAgent::new(
  agent_id? : String = "verifier",
  lang? : String = "en",
) -> VerifierAgent {
  { agent_id, lang }
}

///|
pub fn VerifierAgent::build_perspective_prompt(
  self : VerifierAgent,
  perspective : @prompts.Perspective,
  milestone : @types.Milestone,
  wave : Int,
  wave_results : Array[(String, String)],
  project_context : String,
) -> String {
  let lang_instruction = if self.lang == "ja" {
    "Respond in Japanese."
  } else {
    "Respond in English."
  }
  let buf = StringBuilder::new()
  buf.write_string("You are a Verifier agent. ")
  buf.write_string(lang_instruction)
  buf.write_string("\n\n")
  buf.write_string("## Milestone\n")
  buf.write_string("ID: ")
  buf.write_string(milestone.id)
  buf.write_string("\nGoal: ")
  buf.write_string(milestone.goal)
  buf.write_string("\nWave: ")
  buf.write_string(wave.to_string())
  buf.write_string("\n\n")
  if not(project_context.is_empty()) {
    buf.write_string("## Project Context\n")
    buf.write_string(project_context)
    buf.write_string("\n\n")
  }
  buf.write_string("## Wave Results\n")
  for pair in wave_results {
    buf.write_string("### Task: ")
    buf.write_string(pair.0)
    buf.write_string("\n")
    buf.write_string(pair.1)
    buf.write_string("\n\n")
  }
  match perspective {
    CodeQuality => buf.write_string(@prompts.code_quality_checklist(self.lang))
    Performance => buf.write_string(@prompts.performance_checklist(self.lang))
    Security => buf.write_string(@prompts.security_checklist(self.lang))
    GoalAlignment =>
      buf.write_string(@prompts.goal_alignment_checklist(self.lang))
  }
  match perspective {
    GoalAlignment =>
      buf.write_string(
        "\n## Instructions\n" + "Verify ALL tasks across all waves.\n\n",
      )
    _ =>
      buf.write_string(
        "\n## Instructions\n" +
        "Verify ONLY the tasks listed in the Wave Results section above.\n" +
        "The milestone goal may contain supplementary context referencing work from other waves.\n" +
        "Do NOT flag incomplete implementations or missing deliverables that belong to other waves.\n" +
        "Focus your review exclusively on the current wave's output.\n\n",
      )
  }
  buf.write_string(
    "\n## Output Format\n" +
    "Use exactly one of these tags:\n" +
    "- <wave_approved> if all tasks pass verification\n" +
    "- <needs_rework>task_id: reason</needs_rework> for tasks that need fixes\n" +
    "- <milestone_failed>reason</milestone_failed> if the milestone cannot be achieved\n",
  )
  buf.to_string()
}

///|
/// Parse verifier output into a verdict
pub fn VerifierAgent::parse_verdict(
  _self : VerifierAgent,
  output : String,
) -> @types.VerifierVerdict {
  // Check for <milestone_failed>
  match @util.extract_tag_content(output, "milestone_failed") {
    Some(content) =>
      if not(content.is_empty()) {
        return MilestoneFailed(content)
      }
    None => ()
  }
  // Check for <needs_rework>
  match @util.extract_tag_content(output, "needs_rework") {
    Some(content) =>
      if not(content.is_empty()) {
        let items = split_rework_items(content)
        return NeedsRework(items)
      }
    None => ()
  }
  // Check for <wave_approved>
  if output.contains("<wave_approved>") {
    return Approved
  }
  // No recognized tags found — treat as verification failure
  MilestoneFailed("Verifier output did not contain expected verdict tags")
}

///|
/// Run the verifier agent
pub fn VerifierAgent::verify(
  self : VerifierAgent,
  milestone : @types.Milestone,
  wave : Int,
  wave_results : Array[(String, String)],
  backend : @agent.BoxedBackend,
  project_context : String,
  perspectives? : Array[@prompts.Perspective] = [
    CodeQuality,
    Performance,
    Security,
    GoalAlignment,
  ],
  on_event? : (@types.AgentEvent) -> Unit = fn(_e) {  },
) -> @types.VerifierVerdict {
  let tasks : Array[(String, String)] = []
  for perspective in perspectives {
    on_event(Info("Verifying perspective: " + perspective.to_string()))
    let prompt = self.build_perspective_prompt(
      perspective, milestone, wave, wave_results, project_context,
    )
    let system_prompt = "You are a verification agent focusing on " +
      perspective.to_string() +
      ". Be concise and actionable."
    tasks.push((prompt, system_prompt))
  }
  let results = @agent.run_parallel(backend, tasks, on_event)
  let perspective_verdicts : Array[
    (@prompts.Perspective, @types.VerifierVerdict),
  ] = []
  for i in 0..<perspectives.length() {
    let perspective = perspectives[i]
    let result = results[i]
    let verdict = match result.status {
      Failed(err) =>
        @types.VerifierVerdict::NeedsRework([
          "[" + perspective.to_string() + "] Verification failed: " + err,
        ])
      Completed => self.parse_verdict(result.content)
      _ =>
        @types.VerifierVerdict::NeedsRework([
          "[" +
          perspective.to_string() +
          "] Verification failed: unexpected verifier status",
        ])
    }
    perspective_verdicts.push((perspective, verdict))
  }
  self.merge_verdicts(perspective_verdicts)
}

///|
pub fn inject_perspective_tag(
  item : String,
  perspective : @prompts.Perspective,
) -> String {
  let tag = "[" + perspective.to_string() + "] "
  let colon_idx = @util.find_substring(item, ": ")
  if colon_idx >= 0 {
    let prefix = @util.substring(item, 0, colon_idx + 2)
    let suffix = @util.substring(item, colon_idx + 2, item.to_array().length())
    prefix + tag + suffix
  } else {
    let space_idx = @util.find_substring(item, " ")
    if space_idx > 0 {
      let prefix = @util.substring(item, 0, space_idx)
      if prefix.contains("-") {
        let suffix = @util.substring(
          item,
          space_idx + 1,
          item.to_array().length(),
        )
        prefix + " " + tag + suffix
      } else {
        tag + item
      }
    } else {
      tag + item
    }
  }
}

///|
pub fn VerifierAgent::merge_verdicts(
  _self : VerifierAgent,
  verdicts : Array[(@prompts.Perspective, @types.VerifierVerdict)],
) -> @types.VerifierVerdict {
  let items : Array[String] = []
  for verdict in verdicts {
    match verdict.1 {
      MilestoneFailed(reason) => return MilestoneFailed(reason)
      NeedsRework(rework_items) =>
        for item in rework_items {
          items.push(inject_perspective_tag(item, verdict.0))
        }
      Approved => ()
    }
  }
  if items.is_empty() {
    Approved
  } else {
    NeedsRework(items)
  }
}

// --- Internal helpers ---

///|
/// Split rework items by newline
fn split_rework_items(s : String) -> Array[String] {
  let items : Array[String] = []
  let lines = @util.split_lines(s)
  for line in lines {
    let trimmed = @util.trim(line)
    if not(trimmed.is_empty()) {
      items.push(trimmed)
    }
  }
  if items.is_empty() {
    items.push(s)
  }
  items
}
