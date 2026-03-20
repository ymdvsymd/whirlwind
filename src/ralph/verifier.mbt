///| Verifier agent for the ralph loop
pub struct VerifierAgent {
  agent_id : String
  lang : String
}

pub(all) enum VerifierPerspective {
  CodeQuality
  Performance
  Security
  GoalAlignment
} derive(Eq, Show)

///| Create a new verifier agent
pub fn VerifierAgent::new(
  agent_id~ : String = "verifier",
  lang~ : String = "en",
) -> VerifierAgent {
  { agent_id, lang }
}

fn goal_alignment_checklist(lang : String) -> String {
  let buf = StringBuilder::new()
  if lang == "ja" {
    buf.write_string("## レビュー観点: ゴール整合性\n")
    buf.write_string("以下の観点で評価してください:\n")
    buf.write_string("- 出力はマイルストーンで定義された目標を達成しているか\n")
    buf.write_string("- すべてのタスク出力に一貫性があるか\n")
    buf.write_string(
      "- 当該 Wave のタスクに不足している成果物や未完了の実装がないか（他 Wave の作業は検証対象外）\n",
    )
    buf.write_string("- 全体の方向性がプロジェクトの意図と一致しているか\n")
  } else {
    buf.write_string("## Review Focus: Goal Alignment\n")
    buf.write_string("Evaluate the following aspects:\n")
    buf.write_string("- Does the output achieve the stated milestone goal?\n")
    buf.write_string("- Are all task outputs consistent with each other?\n")
    buf.write_string(
      "- Are there missing deliverables or incomplete implementations for this wave's tasks? (Work from other waves is out of scope)\n",
    )
    buf.write_string("- Does the overall direction match the project's intent?\n")
  }
  buf.to_string()
}

pub fn VerifierAgent::build_perspective_prompt(
  self : VerifierAgent,
  perspective : VerifierPerspective,
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
    GoalAlignment => buf.write_string(goal_alignment_checklist(self.lang))
  }
  buf.write_string(
    "\n## Instructions\n" +
    "Verify ONLY the tasks listed in the Wave Results section above.\n" +
    "The milestone goal may contain supplementary context referencing work from other waves.\n" +
    "Do NOT flag incomplete implementations or missing deliverables that belong to other waves.\n" +
    "Focus your review exclusively on the current wave's output.\n\n",
  )
  buf.write_string(
    "\n## Output Format\n" +
    "Use exactly one of these tags:\n" +
    "- <wave_approved> if all tasks pass verification\n" +
    "- <needs_rework>task_id: reason</needs_rework> for tasks that need fixes\n" +
    "- <milestone_failed>reason</milestone_failed> if the milestone cannot be achieved\n",
  )
  buf.to_string()
}

///| Parse verifier output into a verdict
pub fn VerifierAgent::parse_verdict(
  _self : VerifierAgent,
  output : String,
) -> @types.VerifierVerdict {
  // Check for <milestone_failed>
  let failed_content = extract_tag(output, "milestone_failed")
  if not(failed_content.is_empty()) {
    return MilestoneFailed(failed_content)
  }
  // Check for <needs_rework>
  let rework_content = extract_tag(output, "needs_rework")
  if not(rework_content.is_empty()) {
    let items = split_rework_items(rework_content)
    return NeedsRework(items)
  }
  // Check for <wave_approved>
  if output.contains("<wave_approved>") {
    return Approved
  }
  // No recognized tags found — treat as verification failure
  MilestoneFailed("Verifier output did not contain expected verdict tags")
}

///| Run the verifier agent
pub fn VerifierAgent::verify(
  self : VerifierAgent,
  milestone : @types.Milestone,
  wave : Int,
  wave_results : Array[(String, String)],
  backend : @agent.BoxedBackend,
  project_context : String,
  on_event~ : (@types.AgentEvent) -> Unit = fn(_e) {  },
) -> @types.VerifierVerdict {
  let perspectives : Array[VerifierPerspective] = [
    CodeQuality,
    Performance,
    Security,
    GoalAlignment,
  ]
  let tasks : Array[(String, String)] = []
  for perspective in perspectives {
    on_event(Info("Verifying perspective: " + perspective.to_string()))
    let prompt = self.build_perspective_prompt(
      perspective,
      milestone,
      wave,
      wave_results,
      project_context,
    )
    let system_prompt =
      "You are a verification agent focusing on " +
      perspective.to_string() +
      ". Be concise and actionable."
    tasks.push((prompt, system_prompt))
  }
  let results = @agent.run_parallel(backend, tasks, on_event)
  let perspective_verdicts : Array[(VerifierPerspective, @types.VerifierVerdict)] = []
  for i in 0..<perspectives.length() {
    let perspective = perspectives[i]
    let result = results[i]
    let verdict = match result.status {
      Failed(err) =>
        @types.VerifierVerdict::NeedsRework(
          ["[" + perspective.to_string() + "] Verification failed: " + err],
        )
      Completed => self.parse_verdict(result.content)
      _ =>
        @types.VerifierVerdict::NeedsRework(
          [
            "[" +
            perspective.to_string() +
            "] Verification failed: unexpected verifier status",
          ],
        )
    }
    perspective_verdicts.push((perspective, verdict))
  }
  self.merge_verdicts(perspective_verdicts)
}

pub fn inject_perspective_tag(
  item : String,
  perspective : VerifierPerspective,
) -> String {
  let tag = "[" + perspective.to_string() + "] "
  let colon_idx = find_substring(item, ": ")
  if colon_idx >= 0 {
    let prefix = substring(item, 0, colon_idx + 2)
    let suffix = substring(item, colon_idx + 2, item.to_array().length())
    prefix + tag + suffix
  } else {
    let space_idx = find_substring(item, " ")
    if space_idx > 0 {
      let prefix = substring(item, 0, space_idx)
      if prefix.contains("-") {
        let suffix = substring(item, space_idx + 1, item.to_array().length())
        prefix + " " + tag + suffix
      } else {
        tag + item
      }
    } else {
      tag + item
    }
  }
}

pub fn VerifierAgent::merge_verdicts(
  _self : VerifierAgent,
  verdicts : Array[(VerifierPerspective, @types.VerifierVerdict)],
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

///| Extract content between <tag> and </tag>
fn extract_tag(s : String, tag : String) -> String {
  let open = "<" + tag + ">"
  let close = "</" + tag + ">"
  let open_idx = find_substring(s, open)
  if open_idx < 0 {
    return ""
  }
  let start = open_idx + open.length()
  let close_idx = find_substring_from(s, close, start)
  if close_idx < 0 {
    // No closing tag, take rest of string
    return trim(substring(s, start, s.to_array().length()))
  }
  trim(substring(s, start, close_idx))
}

///| Split rework items by newline
fn split_rework_items(s : String) -> Array[String] {
  let items : Array[String] = []
  let lines = split_lines(s)
  for line in lines {
    let trimmed = trim(line)
    if not(trimmed.is_empty()) {
      items.push(trimmed)
    }
  }
  if items.is_empty() {
    items.push(s)
  }
  items
}

fn find_substring(haystack : String, needle : String) -> Int {
  let h = haystack.to_array()
  let n = needle.to_array()
  if n.length() > h.length() {
    return -1
  }
  for i = 0; i <= h.length() - n.length(); i = i + 1 {
    let mut found = true
    for j = 0; j < n.length(); j = j + 1 {
      if h[i + j] != n[j] {
        found = false
        break
      }
    }
    if found {
      return i
    }
  }
  -1
}

fn find_substring_from(haystack : String, needle : String, from : Int) -> Int {
  let h = haystack.to_array()
  let n = needle.to_array()
  if from + n.length() > h.length() {
    return -1
  }
  for i = from; i <= h.length() - n.length(); i = i + 1 {
    let mut found = true
    for j = 0; j < n.length(); j = j + 1 {
      if h[i + j] != n[j] {
        found = false
        break
      }
    }
    if found {
      return i
    }
  }
  -1
}

fn substring(s : String, start : Int, end : Int) -> String {
  let chars = s.to_array()
  let actual_start = if start < 0 { 0 } else { start }
  let actual_end = if end > chars.length() { chars.length() } else { end }
  if actual_start >= actual_end {
    return ""
  }
  String::from_array(chars[actual_start:actual_end])
}
